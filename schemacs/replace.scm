(define-library (schemacs replace)
  ;; This library mirrors GNU Emacs's `replace.el': `query-replace'
  ;; (M-%), `query-replace-regexp', `replace-string', `replace-regexp',
  ;; and everything they are built on - `query-replace-read-args' and
  ;; the reading of FROM and TO, `perform-replace', whose loop is the
  ;; one key at a time question, `replace-search', the highlight
  ;; pair, and `query-replace-map', the keymap of answers.
  ;;
  ;; The other half of the file is Occur - `occur' (M-x, and the `Show
  ;; hits' tool bar button through `isearch-occur'), `occur-1',
  ;; `occur-engine' and the mode - and `replace-string-in-region' /
  ;; `replace-regexp-in-region', which `editfns.c`'s
  ;; `replace-region-contents' backs. Occur's line numbers are drawn in
  ;; `list-matching-lines-prefix-face` through the `font-lock-face`
  ;; alias, its header in `list-matching-lines-buffer-name-face` (the
  ;; `underline` face), and its lines are `follow-link` text, so a
  ;; mouse-1 click is translated to mouse-2 and goes to the occurrence.
  ;;
  ;; The regexp variants run on `(schemacs search)' - the
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
 (only (schemacs undo) text-editor-undo-boundary!)
    (scheme base)
    (scheme char)
    (only (schemacs marker) copy-marker markerp marker-position)
    
    ;; `*case-fold-search*' is the case folding `perform-replace'
    ;; parameterizes around its loop (the C's
    ;; `(let* ((case-fold-search ...)))').
    (only (schemacs buffer)
          *case-fold-search* current-buffer
          erase-buffer get-buffer get-buffer-create
          with-current-buffer buffer-z
          ;; `occur` and `occur-1`: the buffer values, the buffer-local
          ;; slots `occur-revert-arguments` and the source buffer's
          ;; coding system, the read-only bracket, and the overlays a
          ;; region search runs over.
          bufferp buffer-name buffer-live-p major-mode
          default-directory set!buffer-default-directory
          *inhibit-read-only* set!buffer-read-only set-buffer-modified-p
          buffer-local-value set-buffer-local-value! local-variable-p
          kill-local-variable
          make-overlay delete-overlay overlay-put overlay-get
          overlayp overlay-buffer overlay-start overlay-end
          rename-buffer %kill-buffer
          *kill-buffer-hook*)
    (only (schemacs frame)
          *current-frame* frame-selected-window recenter set!frame-message
          set-message!
          ;; `occur-1`'s "longer than window-width" test, and the
          ;; selected window its mode maps select.
          selected-window select-window window-body-width set-window-point!
          window-buffer *pre-command-hook*)
    (only (schemacs editfns)
          bobp char-after
          eobp goto-char insert message point point-min point-max
          save-excursion
          ;; `occur-engine` copies the matching lines out with these, and
          ;; `occur-1` messages with `ngettext`.
          buffer-substring buffer-substring-no-properties
          line-beginning-position line-end-position forward-line
          propertize ngettext bolp eolp *inhibit-field-text-motion*
          ;; `replace-region-contents` and the narrowing the three
          ;; `subr.el` functions below open around their loops.
          replace-region-contents save-restriction narrow-to-region)
    ;; GNU Emacs's `format` - the `%d`-and-`%s` one `occur-engine` builds
    ;; its lines with, under a rename so the Guile `format` the rest of
    ;; this file already uses stays.
    (rename (only (schemacs editfns) format) (format %format))
    ;; `barf-if-buffer-read-only' is `buffer.c`'s and lives in
    ;; `buffer.scm' now - see the note in `keyboard.scm'.
    (only (schemacs buffer) barf-if-buffer-read-only)
    ;; `transient-mark-mode' is `buffer.c''s variable here, beside
    ;; `mark-active'.
    (only (schemacs simple)
          deactivate-mark push-mark scroll-up-command
          scroll-down-command use-region-p use-region-beginning
          use-region-end mark word-char?
          ;; Occur: the two modes, the region's bounds, the line count,
          ;; and the highlighting options `occur--highlight-occurrences`
          ;; reads.
          special-mode fundamental-mode region-bounds count-lines
          next-error-found
          *next-error-highlight* *next-error-highlight-no-select*
          next-error-highlight-timer next-error-overlay-arrow-position
          next-error-last-buffer)
    ;; `transient-mark-mode` and `mark-active` are `buffer.c`'s
    ;; buffer-locals; `isearch-query-replace`'s point placement reads
    ;; both.
    (only (schemacs buffer) transient-mark-mode mark-active)
    ;; The search primitives: the searches that find the occurrences
    ;; and the match data and `replace-match' that make the edits.
    (only (schemacs search)
          looking-at looking-back match-beginning match-data
          match-end
          match-substitute-replacement re-search-backward
          re-search-forward regexp-quote replace-match
          search-backward search-forward set-match-data)
    ;; The key reads: the loop reads one key at a time, exactly the
    ;; command loop's own read, and pushes a key it does not know back
    ;; onto `*unread-command-events*'. `read-key-event' answers the key
    ;; *event* - the display's own form is normalised away at the read -
    ;; so what is pushed back is an event, which is what the command
    ;; loop reads next and what `dispatch-input-event' takes.
    (only (schemacs keyboard)
          *unread-command-events* read-key-event recursive-edit
          signal-quit
          ;; `occur-mode-goto-occurrence`'s interactive argument.
          *last-nonmenu-event*)
    (only (schemacs minibuffer)
          *minibuffer-setup-hook*
          format-prompt history-entries list-ref-or make<history>
          read-from-minibuffer set!history-entries)
    ;; `history-add-new-input' is `minibuf.c''s; the two reads below turn
    ;; it off and file each answer themselves, as the C does.
    (only (schemacs minibuf) *history-add-new-input*)
    ;; `char-displayable-p' is `international/mule.el''s: it decides
    ;; whether the terminal can draw the separator between FROM and TO.
    (only (schemacs international mule) char-displayable-p)
    ;; the redraw
    (only (schemacs xdisp) render!)
    ;; `search-upper-case' decides the search's folding, which the
    ;; `isearch-no-upper-case-p' of isearch.el reads; the highlighting is
    ;; isearch's, as it is in Emacs - `replace-highlight' makes its own
    ;; overlay and hands the other matches to the lazy highlighter.
    (only (schemacs isearch)
          *search-upper-case* isearch-no-upper-case-p
          ;; The search's published state (`isearch-query-replace`).
          isearch-string isearch-case-fold-search isearch-regexp
          isearch-other-end isearch-string-propertize
          *lazy-highlight-cleanup*
          isearch-lazy-highlight-update lazy-highlight-cleanup
          minibuffer-lazy-highlight-setup)
    ;; `replace-highlight''s overlay, and the `query-replace' face it
    ;; carries - `(defface query-replace '((t (:inherit isearch))))'
    ;; (replace.el:165), which is why the match point is on looks the way
    ;; an isearch match does.
    (only (schemacs buffer)
          current-buffer delete-overlay make-overlay move-overlay overlay-put)
    (only (schemacs faces) defface face-differs-from-default-p)
    (only (schemacs command)
          current-prefix-arg define-command define-alias
          prefix-numeric-value)
    (only (schemacs custom) define-custom)
    (only (schemacs keymap) define-key *default-keymap* *current-keymap*)
    (prefix (schemacs keymap) km:)
    (only (schemacs window)
          display-buffer pop-to-buffer switch-to-buffer-other-window
          get-buffer-window save-selected-window)
    (only (schemacs subr)
          kbd add-to-history nth nthcdr delq string-replace
          run-hooks add-hook remove-hook
          user-error event-end posn-window posn-point)
    ;; The text-property walk `occur-engine` builds its lines with.
    (only (schemacs textprop)
          add-face-text-property add-text-properties get-text-property
          next-single-property-change previous-single-property-change
          remove-list-of-text-properties)
    (only (schemacs marker)
          make-marker set-marker copy-marker marker-position marker-buffer)
    ;; `put` is `fns.c`'s symbol property, in the interval library.
    (only (schemacs intervals) put)
    (only (schemacs core derived) define-derived-mode)
    ;; `string-equal` is not needed here, but `concat` and `mapconcat` are:
    ;; `occur-engine`'s cell strings and `occur-rename-buffer`'s name.
    (only (schemacs fns)
          concat mapconcat line-number-at-pos)
    (only (schemacs indentc) current-column)
    ;; `occur-engine-line` asks the fontification engine whether it is on.
    (only (schemacs font-lock) font-lock-ensure font-lock-mode-on?)
    (only (schemacs font-core) turn-on-font-lock)
    (only (schemacs core timer) run-at-time cancel-timer timer?)
    (only (schemacs core seq) seq-some seq-take)
    (only (schemacs xdisp)
          overlay-arrow-position overlay-arrow-string)
    (only (schemacs search)
          regexp-opt-depth string-match string-match-p)
    (only (guile) cadr caddr cddr cdddr cadddr cddddr format string-contains)
    )

  (export
   *case-replace*
   *query-replace-defaults*
   *query-replace-from-to-separator*
   *query-replace-history*
   *query-replace-lazy-highlight*
   *query-replace-map*
   *rename-uniquely-function*
   *query-replace-read-from-default*
   *query-replace-read-from-regexp-default*
   perform-replace
   isearch-query-replace
   query-replace
   query-replace-descr
   query-replace-read-args
   query-replace-read-from
   query-replace-read-to
   query-replace-regexp
   replace-regexp
   replace-string
   ;; `subr.el`'s three, placed here - see the note at their definitions.
   replace-buffer-contents replace-string-in-region
   replace-regexp-in-region
   ;; Occur - `replace.el`'s second half.
   regexp-history occur-collect-regexp-history
   occur-highlight-overlays *read-regexp-defaults-function*
   read-regexp
   *list-matching-lines-default-context-lines*
   *list-matching-lines-face* *list-matching-lines-buffer-name-face*
   *list-matching-lines-current-line-face*
   *list-matching-lines-jump-to-current-line*
   *list-matching-lines-prefix-face* *occur-excluded-properties*
   occur-read-primary-args occur-rename-buffer occur-revert-arguments
   *occur--final-pos*
   occur occur-regexp-descr occur-1 occur-engine
   occur-engine-line occur-engine-add-prefix occur-accumulate-lines
   occur-context-lines
   occur--garbage-collect-revert-args occur-revert-function
   occur-mode--find-occurrences occur-mode-find-occurrence
   occur--targets-start occur--set-arrow
   occur-mode occur-mode-map
   occur-mode-goto-occurrence occur-mode-mouse-goto
   occur-mode-goto-occurrence-other-window
   occur-goto-locus-delete-o occur--highlight-occurrences
   occur-mode-display-occurrence occur-find-match
   occur-next occur-prev occur-next-error
   occur-mode-hook *occur-hook* *occur-mode-find-occurrence-hook*
   list-matching-lines
   ;; isearch.el's command, for the same placement reason as
   ;; `isearch-query-replace` above.
   isearch-occur
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The variables
    ;;------------------------------------------------------------------

    (define-custom *case-replace*
      ;; GNU Emacs's `case-replace' (replace.el:35): "Non-nil means
      ;; `query-replace' should preserve case in replacements."
      ;;--------------------------------------------------------------
       #t
      "Non-nil means `query-replace' should preserve case in replacements."
      :type 'boolean :group 'matching)

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

    (define-custom *query-replace-from-to-separator*
      ;; GNU Emacs's `query-replace-from-to-separator' (replace.el:73):
      ;; "String that separates FROM and TO in the history of replacement
      ;; pairs. When nil, the pair will not be added to the history".
      ;; Emacs draws it in the `minibuffer-prompt' face and marks it with
      ;; a `separator' text property so it can be found again; there are
      ;; no text properties on a minibuffer answer here, so it is found
      ;; as a substring (`query-replace--split-string').
      ;;--------------------------------------------------------------
      " → "
      "String that separates FROM and TO in the history of replacement pairs.
When nil, the pair will not be added to the history (same behavior
as in Emacs 24.5)."
      :type '(choice (const :tag "Disabled" nil) string) :group 'matching :version "25.1")

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

    (define-custom *query-replace-show-replacement*
      ;; GNU Emacs's `query-replace-show-replacement' (replace.el): show
      ;; the CASED replacement in the prompt - what the match would
      ;; become - rather than the raw replacement string.
      ;;--------------------------------------------------------------
       #t
      "Non-nil means show substituted replacement text in the minibuffer.
This variable affects only `query-replace-regexp'."
      :type 'boolean :group 'matching :version "23.1")

    (define-custom *query-replace-lazy-highlight*
      ;; GNU Emacs's `query-replace-lazy-highlight' (replace.el:153):
      ;; "Controls the lazy-highlighting during query replacements. When
      ;; non-nil, all text matching the current match that is currently
      ;; visible in the window is highlighted lazily using isearch lazy
      ;; highlighting." `replace-highlight' reads it to decide whether to
      ;; run the lazy loop, exactly as the C does.
      ;;--------------------------------------------------------------
       #t
      "Controls the lazy-highlighting during query replacements.
When non-nil, all text matching the current match that is
currently visible in the window is highlighted lazily using
isearch lazy highlighting (see `lazy-highlight-initial-delay'
and `lazy-highlight-interval').  Uses the `lazy-highlight' face
to highlight matching text."
      :type 'boolean :group 'lazy-highlight :version "22.1")

    (define-custom *query-replace-highlight*
      ;; GNU Emacs's `query-replace-highlight' (replace.el:130): "Non-nil
      ;; means to highlight matches during query replacement."
      ;;--------------------------------------------------------------
       #t
      "Non-nil means to highlight matches during query replacement."
      :type 'boolean :group 'matching)

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
      ;; answers." The keys and the answers are the C's, DEL included:
      ;; `"\d"' (127) is skip and `"\C-h"' (8) is help, two different
      ;; answers to two different bytes.
      ;;--------------------------------------------------------------
      (km:keymap '*query-replace-map*))

    (define (fill-query-replace-map!)
      ;; The bindings, in the C's order.
      ;;--------------------------------------------------------------
      (define-key *query-replace-map* (kbd "SPC") 'act)
      ;; Emacs binds all three spellings of the erase key: the byte
      ;; (`"\d"'), and the two named keys a window system sends.
      (define-key *query-replace-map* (kbd "DEL") 'skip)
      (define-key *query-replace-map* (kbd "<delete>") 'skip)
      (define-key *query-replace-map* (kbd "<backspace>") 'skip)
      (define-key *query-replace-map* (kbd "y") 'act)
      (define-key *query-replace-map* (kbd "n") 'skip)
      (define-key *query-replace-map* (kbd "Y") 'act)
      (define-key *query-replace-map* (kbd "N") 'skip)
      (define-key *query-replace-map* (kbd "e") 'edit-replacement)
      (define-key *query-replace-map* (kbd "E") 'edit-replacement-exact-case)
      (define-key *query-replace-map* (kbd ",") 'act-and-show)
      (define-key *query-replace-map* (kbd "q") 'exit)
      (define-key *query-replace-map* (kbd "C-m") 'exit)
      (define-key *query-replace-map* (kbd ".") 'act-and-exit)
      (define-key *query-replace-map* (kbd "C-r") 'edit)
      (define-key *query-replace-map* (kbd "C-w") 'delete-and-edit)
      (define-key *query-replace-map* (kbd "C-l") 'recenter)
      (define-key *query-replace-map* (kbd "!") 'automatic)
      (define-key *query-replace-map* (kbd "^") 'backup)
      (define-key *query-replace-map* (kbd "u") 'undo)
      (define-key *query-replace-map* (kbd "U") 'undo-all)
      (define-key *query-replace-map* (kbd "d") 'diff)
      (define-key *query-replace-map* (kbd "C-h") 'help)
      (define-key *query-replace-map* (kbd "?") 'help)
      (define-key *query-replace-map* (kbd "C-g") 'quit)
      (define-key *query-replace-map* (kbd "C-]") 'quit)
      (define-key *query-replace-map* (kbd "C-v") 'scroll-up)
      (define-key *query-replace-map* (kbd "M-v") 'scroll-down)
      (define-key *query-replace-map* (kbd "C-[") 'exit-prefix))

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
      (let ((separator (*query-replace-from-to-separator*)))
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
                       (after (and (< found (buffer-z ed))
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
                  (set! limit (copy-marker (min start end)))
                  (goto-char (max start end))
                  (deactivate-mark))
                (when start
                  (set! limit (copy-marker (max start end)))
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
                                           (marker-position limit))
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
                                                 (marker-position limit))
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
                                                   (and (not (= (if (markerp (car match))
                                                                   (marker-position (car match))
                                                                   (car match))
                                                                (if (markerp (cadr match))
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
                                             (let* ((key (read-key-event -1))
                                                    (def (km:keymap-lookup
                                                          map key)))
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
                                                  (cons key
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
            ;; The message the C's ends with, and it is `(message ...)'
            ;; there (`replace.el:3712') - so it logs. **The prompt
            ;; above is the other half and stays `set!frame-message'**:
            ;; it is displayed by the C's `read-key`/`read-char` prompt,
            ;; which is `message_with_string (..., 0)` - `log' false
            ;; (`keyboard.c:10741`), and logging a line per keystroke of
            ;; a query-replace is not what Emacs does.
            (message "%s"
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

    (define-command (isearch-query-replace arg regexp-flag)
      ;; GNU Emacs's `isearch-query-replace` (`isearch.el:2399`): "Start
      ;; `query-replace' with string to replace from last search
      ;; string. The ARG (prefix arg if interactive), if non-nil, means
      ;; replace only matches surrounded by word boundaries. A negative
      ;; prefix arg means replace backward."
      ;;
      ;; **It is isearch.el's command in replace.el's file**, because
      ;; `perform-replace` and `query-replace-read-to` are here and
      ;; `replace.scm` is the library that *imports* `isearch.scm` - the
      ;; other way round would be a cycle. The search's own loop runs it
      ;; through the command table once it has exited (`isearch.scm`,
      ;; the Replace button), and the search's `isearch-done` and
      ;; highlight cleanup have already run by then, as Emacs's own
      ;; first act here is `(isearch-done nil t)`.
      ;;
      ;; Not carried: the `(if regexp-flag (setq isearch-regexp t))`
      ;; arm and `isearch-query-replace-regexp`, since this tree's
      ;; search is literal-only; `search-invisible` and its
      ;; `isearch-invisible` source (nothing here makes text invisible);
      ;; `replace-lax-whitespace`/`replace-regexp-lax-whitespace` (lax
      ;; whitespace is not ported); and `isearch-recursive-edit` - the
      ;; search is a loop, not a recursive edit, so there is no
      ;; `exit-recursive-edit` tail.
      "Start `query-replace' with string to replace from last search string."
      (interactive (list (current-prefix-arg) #f))
      (barf-if-buffer-read-only)
      (let* ((delimited (and arg (not (eq? arg '-))))
             (backward (and arg (eq? arg '-)))
             (from (isearch-string-propertize isearch-string
                                              isearch-case-fold-search)))
        ;; `(let ((case-fold-search isearch-case-fold-search)
        ;;        (search-upper-case nil)) ...)': the folding the search
        ;; was using, and no re-inference of it in the TO prompt's
        ;; lazy highlight.
        (parameterize ((*case-fold-search* isearch-case-fold-search)
                       (*search-upper-case* #f))
          (if (and isearch-other-end
                   (if backward
                       (> isearch-other-end (point))
                       (< isearch-other-end (point)))
                   (not (and (transient-mark-mode) (mark-active)
                             (if backward
                                 (> (marker-position (mark)) (point))
                                 (< (marker-position (mark)) (point))))))
              (goto-char isearch-other-end))
          ;; `(set query-replace-from-history-variable (cons
          ;; isearch-string-propertized (symbol-value ...)))' - the
          ;; FROM string goes onto the history FIRST, so M-p at the TO
          ;; prompt brings it back.
          (set!history-entries
           *query-replace-history*
           (cons from (history-entries *query-replace-history*)))
          (perform-replace
           from
           (query-replace-read-to
            from
            (string-append
             "Query replace"
             (if backward " backward" "")
             (if (use-region-p) " in region" ""))
            isearch-regexp)
           #t isearch-regexp delimited
           1 *query-replace-map*
           (use-region-beginning) (use-region-end) backward))))

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

    (define-key *default-keymap* (kbd "M-%") query-replace)
    (define-key *default-keymap* (kbd "M-C-%")
      query-replace-regexp)

    ;;----------------------------------------------------------------
    ;; `replace-buffer-contents', `replace-string-in-region' and
    ;; `replace-regexp-in-region' - `subr.el:4948', `:4961', `:4990'.
    ;;
    ;; **A placement departure**: these are `subr.el`'s, and all three
    ;; call `replace-region-contents' (`editfns.c`'s), so they cannot
    ;; live in `subr.scm`, which is below it. They sit in `replace.scm'
    ;; with the rest of the replace commands.
    ;;----------------------------------------------------------------

    (define (replace-buffer-contents source . rest)
      ;; GNU Emacs's `replace-buffer-contents' (`subr.el:4948'): "Replace
      ;; accessible portion of current buffer with that of SOURCE. ...
      ;; The replacement is performed using `replace-region-contents'
      ;; which also describes the MAX-SECS and MAX-COSTS arguments and
      ;; the return value."
      ;;
      ;; `(declare (obsolete replace-region-contents "31.1"))' - it is
      ;; kept, as Emacs keeps it, for callers written against 30.
      ;;--------------------------------------------------------------
      (replace-region-contents (point-min) (point-max) (get-buffer source)
                               (and (pair? rest) (car rest))
                               (and (pair? rest) (pair? (cdr rest))
                                    (cadr rest))))

    (define (replace-string-in-region string replacement . rest)
      ;; GNU Emacs's `replace-string-in-region' (`subr.el:4961'):
      ;; "Replace STRING with REPLACEMENT in the region from START to
      ;; END. The number of replaced occurrences are returned, or nil if
      ;; STRING doesn't exist in the region."
      ;;
      ;; Each occurrence is replaced by `replace-region-contents' with a
      ;; MAX-SECS of 0 - the C's "disables the comparison step, so this
      ;; function immediately falls back to a plain delete/insert" - and
      ;; "Comparisons and replacements are done with fixed case."
      ;;--------------------------------------------------------------
      (let ((start (and (pair? rest) (car rest)))
            (end (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (when start
          (when (< start (point-min))
            (error "Start before start of buffer")))
        (unless start (set! start (point)))
        (when end
          (when (> end (point-max))
            (error "End after end of buffer")))
        (unless end (set! end (point-max)))
        (save-excursion
          (goto-char start)
          (save-restriction
            (narrow-to-region start end)
            (parameterize ((*case-fold-search* #f))
              (let ((matches 0))
                (let loop ()
                  (when (search-forward string #f #t)
                    (replace-region-contents (match-beginning 0)
                                             (match-end 0)
                                             replacement 0)
                    (set! matches (+ matches 1))
                    (loop)))
                (and (not (zero? matches)) matches)))))))

    (define (replace-regexp-in-region regexp replacement . rest)
      ;; GNU Emacs's `replace-regexp-in-region' (`subr.el:4990'):
      ;; "Replace REGEXP with REPLACEMENT in the region from START to
      ;; END. The number of replaced occurrences are returned, or nil if
      ;; REGEXP doesn't exist in the region. ... Comparisons and
      ;; replacements are done with fixed case."
      ;;--------------------------------------------------------------
      (let ((start (and (pair? rest) (car rest)))
            (end (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (when start
          (when (< start (point-min))
            (error "Start before start of buffer")))
        (unless start (set! start (point)))
        (when end
          (when (> end (point-max))
            (error "End after end of buffer")))
        (unless end (set! end (point-max)))
        (save-excursion
          (goto-char start)
          (save-restriction
            (narrow-to-region start end)
            (parameterize ((*case-fold-search* #f))
              (let ((matches 0))
                (let loop ()
                  (when (re-search-forward regexp #f #t)
                    (replace-match replacement #t)
                    (set! matches (+ matches 1))
                    (loop)))
                (and (not (zero? matches)) matches)))))))

    ;;----------------------------------------------------------------
    ;; Occur - `occur', `occur-mode' and the engine under them
    ;;
    ;; GNU Emacs's `replace.el:1085-2736': `regexp-history',
    ;; `read-regexp', the `match' face and the `list-matching-lines-*'
    ;; options, `occur-mode' with its map, and `occur' over
    ;; `occur-1`/`occur-engine` and their helpers.
    ;;
    ;; **What is not carried, and what each waits for**: `occur-edit-mode`
    ;; and `occur-after-change-function` (writing an edited occurrence
    ;; back into its source buffer); `multi-occur` and
    ;; `multi-occur-in-matching-buffers`; `occur-word-at-mouse`,
    ;; `occur-symbol-at-mouse` and `occur-context-menu` (they need
    ;; `thing-at-mouse` and a context-menu engine); and the
    ;; `occur-menu-map` `easy-menu-define`, which needs `easy-menu`.
    ;; `occur-mode-map`'s `n`/`p` (`next-error-no-select`/
    ;; `previous-error-no-select`), `l` (`recenter-current-error`) and
    ;; `C-c C-f` (`next-error-follow-minor-mode`) wait on the
    ;; `next-error` command itself, which is not ported; `c`
    ;; (`clone-buffer`) waits on `clone-buffer`.
    ;;----------------------------------------------------------------

    (define regexp-history (make<history> '()))
    ;; ^ GNU Emacs's `regexp-history' (`replace.el:1085'): "History list
    ;; for some commands that read regular expressions." A history
    ;; *record* here, because that is what `read-from-minibuffer' takes.

    (define occur-highlight-overlays '())
    ;; ^ GNU Emacs's `occur-highlight-overlays' (`replace.el:1090'):
    ;; "Overlays used to temporarily highlight occur matches."

    (define occur-collect-regexp-history (make<history> '("\\1")))
    ;; ^ GNU Emacs's `occur-collect-regexp-history' (`replace.el:1094'):
    ;; "History of regexp for occur's collect operation." Emacs keeps a
    ;; list and names it to `read-regexp` as a history symbol; here the
    ;; history is the record.

    (define-custom *read-regexp-defaults-function* #f
      "Function that provides default regexp(s) for `read-regexp'.
This function should take no arguments and return one of: nil, a
regexp, or a list of regexps.  Interactively, `read-regexp' uses
the return value of this function for its DEFAULT argument."
      :type 'function
      :group 'matching)

    (define (read-regexp prompt . args)
      ;; GNU Emacs's `read-regexp' (`replace.el:1165'): "Read and return
      ;; a regular expression as a string. ..."
      ;;
      ;; **What is not carried**: `read-regexp-map` and its `M-s c`
      ;; case-folding toggle (so the answer carries no `case-fold'
      ;; property and `read-regexp-case-fold-search` is not here);
      ;; `read-regexp-suggestions` and the `M-n` list of standard
      ;; suggestions, because this tree's `read-from-minibuffer` takes
      ;; one DEFAULT rather than an Emacs default *list*; and the
      ;; `history-add-new-input` binding is spelled `parameterize` over
      ;; the variable it names.
      ;;--------------------------------------------------------------
      (let* ((defaults-arg (if (pair? args) (car args) #f))
             (history (or (and (pair? args) (pair? (cdr args)) (cadr args))
                          regexp-history))
             (defaults
              (if (and defaults-arg (symbol? defaults-arg))
                  (let ((fn (or (*read-regexp-defaults-function*)
                                defaults-arg)))
                    (cond ((eq? fn 'regexp-history-last)
                           (let ((entries (history-entries history)))
                             (and (pair? entries) (car entries))))
                          ((procedure? fn) (fn))
                          (else #f)))
                  defaults-arg))
             (default (if (pair? defaults) (car defaults) defaults))
             (input
              (parameterize ((*history-add-new-input* #f))
                (read-from-minibuffer
                 (if (string-match-p ":[ \t]*\\'" prompt)
                     prompt
                     (format-prompt
                      prompt
                      (and (string? default)
                           (< 0 (string-length default))
                           (query-replace-descr default))))
                 #f #f history default)))
             (result (if (equal? input "") default input)))
        (when result
          (set!history-entries
           history
           (add-to-history (history-entries history) result)))
        (or result input)))

    (defface 'match
      '((((class color) (min-colors 88) (background light))
         :background "khaki1")
        (((class color) (min-colors 88) (background dark))
         :background "RoyalBlue3")
        (((class color) (min-colors 8) (background light))
         :background "yellow" :foreground "black")
        (((class color) (min-colors 8) (background dark))
         :background "blue" :foreground "white")
        (((type tty) (class mono))
         :inverse-video #t)
        (#t :background "gray"))
      "Face used to highlight matches permanently.")

    (define-custom *list-matching-lines-default-context-lines* 0
      "Default number of context lines included around `list-matching-lines' matches.
A negative number means to include that many lines before the match.
A positive number means to include that many lines both before and after."
      :type 'integer
      :group 'matching)

    (define-custom *list-matching-lines-face* 'match
      "Face used by \\[list-matching-lines] to show the text that matches.
If the value is nil, don't highlight the matching portions specially."
      :type 'face
      :group 'matching)

    (define-custom *list-matching-lines-buffer-name-face* 'underline
      "Face used by \\[list-matching-lines] to show the names of buffers.
If the value is nil, don't highlight the buffer names specially."
      :type 'face
      :group 'matching)

    (define-custom *list-matching-lines-current-line-face* 'lazy-highlight
      "Face used by \\[list-matching-lines] to highlight the current line."
      :type 'face
      :group 'matching)

    (define-custom *list-matching-lines-jump-to-current-line* #f
      "If non-nil, \\[list-matching-lines] shows the current line highlighted.
The current line for this purpose is the line of the original buffer
which was current when \\[list-matching-lines] was invoked.
Point in the `*Occur*' buffer will be set right after such line when
there are matches after it."
      :type 'boolean
      :group 'matching)

    (define-custom *list-matching-lines-prefix-face* 'shadow
      "Face used by \\[list-matching-lines] to show the prefix column.
The prefix column is the part of display that precedes the actual
contents of the line; it normally shows the line number.  \\(For
multiline matches, the prefix column shows the line number for the
first line and whitespace for the rest of the lines.\\)
If this face will display the same as the default face, the prefix
column will not be highlighted specially."
      :type 'face
      :group 'matching)

    (define-custom *occur-excluded-properties*
      '(read-only invisible intangible field mouse-face help-echo local-map
                   keymap yank-handler follow-link)
      "Text properties to discard when copying lines to the *Occur* buffer.
The value should be a list of text properties to discard or t,
which means to discard all text properties."
      :type 'list
      :group 'matching)

    (define (occur-read-primary-args)
      ;; GNU Emacs's `occur-read-primary-args' (`replace.el:2026').
      ;;--------------------------------------------------------------
      (let* ((perform-collect (pair? (current-prefix-arg)))
             (regexp (read-regexp (if perform-collect
                                      "Collect strings matching regexp"
                                      "List lines matching regexp")
                                  'regexp-history-last)))
        (list regexp
              (if perform-collect
                  ;; Perform collect operation
                  (if (zero? (regexp-opt-depth regexp))
                      ;; No subexpression so collect the entire match.
                      "\\&"
                      ;; Get the regexp for collection pattern.
                      (let ((default (let ((entries (history-entries
                                                     occur-collect-regexp-history)))
                                       (and (pair? entries) (car entries)))))
                        (read-regexp
                         (format-prompt "Regexp to collect" default)
                         default occur-collect-regexp-history)))
                  ;; Otherwise normal occur takes numerical prefix argument.
                  (let ((arg (current-prefix-arg)))
                    (if arg (prefix-numeric-value arg) #f))))))

    (define (occur-revert-arguments)
      ;; GNU Emacs's `occur-revert-arguments' (`replace.el:1636'), a
      ;; `defvar-local` holding `(REGEXP NLINES BUFS)` - what `g` hands
      ;; back to `occur-1`. A buffer-local slot here, so it is read and
      ;; written through the slot functions.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'occur-revert-arguments #f))

    (define-command (occur-rename-buffer unique-p interactive-p)
      ;; GNU Emacs's `occur-rename-buffer' (`replace.el:2061'): "Rename
      ;; the current *Occur* buffer to *Occur: original-buffer-name*."
      ;;
      ;; `occur-revert-arguments` is a `defvar-local` in Emacs; here it is
      ;; a buffer-local slot, read through `occur-revert-arguments` and
      ;; destroyed with `kill-local-variable`.
      ;;--------------------------------------------------------------
      "Rename the current *Occur* buffer to *Occur: original-buffer-name*.
Here `original-buffer-name' is the buffer name where Occur was originally run.
If UNIQUE-P is non-nil (interactively, the prefix argument), or called
non-interactively with INTERACTIVE-P nil, the renaming will not clobber
the existing buffer(s) of that name, but will use `generate-new-buffer-name'
instead.
You can add this to `occur-hook' if you always want a separate
*Occur* buffer for each buffer where you invoke `occur'."
      (interactive "P\np")
      (with-current-buffer
          (if (eq? (major-mode) 'occur-mode)
              (current-buffer)
              (get-buffer "*Occur*"))
        (rename-buffer (concat "*Occur: "
                               (mapconcat
                                (lambda (boo)
                                  (buffer-name (if (overlayp boo)
                                                   (overlay-buffer boo)
                                                   boo)))
                                (car (cddr (occur-revert-arguments))) "/")
                               "*")
                       (or unique-p (not interactive-p)))))

    (define *rename-uniquely-function* (make-parameter #f))
    ;; ^ A seam for `rename-uniquely` (`files.el:6747`), which
    ;; `occur-rename-buffer` calls where Emacs does. The *function* is
    ;; `files.scm`'s, and this library cannot import that one: `files`
    ;; loads `(schemacs core map-ynp)` for `save-some-buffers`, `map-ynp`
    ;; imports `*query-replace-map*` from here, and an import back into
    ;; `files` would close the cycle. `files.scm` installs this as it
    ;; loads, as it does the other seams it owns.

    (define *occur--final-pos* (make-parameter #f))
    ;; ^ GNU Emacs's `occur--final-pos' (`replace.el:2076'), a dynamic
    ;; variable `occur-1` `let`-binds and `occur-engine` sets - a
    ;; parameter under this tree's convention for that reason.

    (define-command (occur regexp nlines . rest)
      ;; GNU Emacs's `occur' (`replace.el:2078'): "Show all lines in the
      ;; current buffer containing a match for REGEXP. ..."
      ;;
      ;; REGION is `(START . END)` in a one-element list, as
      ;; `region-bounds` answers it; Emacs makes an overlay for the
      ;; search when the command runs on a region, and so does this.
      ;;--------------------------------------------------------------
      "Show all lines in the current buffer containing a match for REGEXP.
If a match spreads across multiple lines, all those lines are shown."
      (interactive
       (append (occur-read-primary-args)
               (if (use-region-p) (list (region-bounds)) '())))
      ;; REGION is optional in Emacs, and the interactive expression above
      ;; supplies it only when a region is active - so it arrives in the
      ;; rest list, as `occur-next-error`'s RESET does.
      (let* ((region (if (pair? rest) (car rest) #f))
             (first (and (pair? region) (pair? (car region))
                         (car (car region))))
             (start (and first (max first (point-min))))
             (end (and first (min (cdr (car region)) (point-max))))
             (in-region (or start end))
             (bufs (if (not in-region)
                       (list (current-buffer))
                       (let ((ol (make-overlay (or start (point-min))
                                               (or end (point-max)))))
                         (overlay-put ol 'occur--orig-point (point))
                         (list ol)))))
        (occur-1 regexp nlines bufs)))

    (define (occur-regexp-descr regexp)
      ;; GNU Emacs's `occur-regexp-descr' (`replace.el:2233').
      ;;--------------------------------------------------------------
      (%format " for %s\"%s\""
               (or (get-text-property 0 'isearch-regexp-function-descr regexp)
                   "")
               (if (get-text-property 0 'isearch-string regexp)
                   (propertize
                    (query-replace-descr
                     (get-text-property 0 'isearch-string regexp))
                    'help-echo regexp)
                   (query-replace-descr regexp))))

    (define (occur-1 regexp nlines bufs . args)
      ;; GNU Emacs's `occur-1' (`replace.el:2242').
      ;;
      ;; BUFS is a list of buffers or overlays. The `buffer-undo-list`
      ;; binding of Emacs's `let` is not carried - there is no
      ;; per-buffer undo list *variable* to bind here - and the occur
      ;; buffer is read-only and regenerated, so its inserts are not
      ;; meant to be undoable.
      ;;--------------------------------------------------------------
      (let ((buf-name (if (pair? args) (car args) #f)))
        (unless (and regexp (not (equal? regexp "")))
          (error "Occur doesn't work with the empty regexp"))
        (unless buf-name (set! buf-name "*Occur*"))
        (let* ((active-bufs
                (delq #f (map (lambda (boo)
                               (if (or (buffer-live-p boo)
                                       (and (overlayp boo) (overlay-buffer boo)))
                                   boo
                                   #f))
                             bufs)))
               (source-buffer-default-directory (default-directory)))
          ;; Handle the case where one of the buffers we're searching is
          ;; the output buffer.  Just rename it.
          (when (seq-some (lambda (boo)
                            (equal? buf-name
                                    (buffer-name (if (overlayp boo)
                                                     (overlay-buffer boo)
                                                     boo))))
                          active-bufs)
            (with-current-buffer buf-name
              ((*rename-uniquely-function*))))
          ;; Now find or create the output buffer.
          (let ((occur-buf (get-buffer-create buf-name)))
            (with-current-buffer occur-buf
              ;; Make the default-directory of the *Occur* buffer match
              ;; that of the buffer where the occurrences come from.
              (set!buffer-default-directory occur-buf
                                            source-buffer-default-directory)
              (set! overlay-arrow-position #f)
              (if (string? nlines)
                  (fundamental-mode) ;; This is for collect operation.
                  (occur-mode))
              ;; The C's `let` binds these three for the *whole* body
              ;; (`replace.el:2289`), and `occur--final-pos` must stay
              ;; bound across the read below - the engine sets it while
              ;; the list is built and `occur-1` reads it to put the
              ;; window's point there.
              (parameterize ((*inhibit-read-only* #t)
                             (*occur--final-pos* #f))
                (erase-buffer)
                (let ((count
                       (if (string? nlines)
                           ;; Treat nlines as a regexp to collect.
                           (let ((count 0))
                             (for-each
                              (lambda (boo)
                                (with-current-buffer
                                    (if (overlayp boo) (overlay-buffer boo) boo)
                                  (save-excursion
                                    (goto-char (if (overlayp boo)
                                                   (overlay-start boo)
                                                   (point-min)))
                                    (let ((end (if (overlayp boo)
                                                   (overlay-end boo)
                                                   #f)))
                                      (let loop ()
                                        (when (re-search-forward regexp end #t)
                                          ;; Insert the replacement regexp.
                                          (let ((str (match-substitute-replacement
                                                      nlines)))
                                            (if str
                                                (with-current-buffer occur-buf
                                                  (insert str)
                                                  (set! count (+ count 1))
                                                  (or (zero? (current-column))
                                                      (insert "\n")))))
                                          (loop)))))))
                              active-bufs)
                             count)
                           ;; Perform normal occur.
                           (occur-engine
                            regexp active-bufs occur-buf
                            (or nlines
                                (*list-matching-lines-default-context-lines*))
                            (if (and (*case-fold-search*) (*search-upper-case*))
                                (isearch-no-upper-case-p regexp #t)
                                (*case-fold-search*))
                            (*list-matching-lines-buffer-name-face*)
                            (if (face-differs-from-default-p
                                 (*list-matching-lines-prefix-face*))
                                (*list-matching-lines-prefix-face*)
                                #f)
                            (*list-matching-lines-face*)
                            (not (eq? (*occur-excluded-properties*) #t))))))
                  (let* ((bufcount (length active-bufs))
                       (diff (- (length bufs) bufcount)))
                  (message "%s"
                           (%format "Searched %d %s%s; %s %s%s"
                                    bufcount
                                    (ngettext "buffer" "buffers" bufcount)
                                    (if (zero? diff)
                                        ""
                                        (%format " (%d killed)" diff))
                                    (if (zero? count) "no" (%format "%d" count))
                                    (ngettext "match" "matches" count)
                                    ;; Don't display regexp if with remaining
                                    ;; text it is longer than window-width.
                                    (if (> (+ (string-length
                                               (or (get-text-property
                                                    0 'isearch-string regexp)
                                                   regexp))
                                              42)
                                           (window-body-width (selected-window)))
                                        ""
                                        (occur-regexp-descr regexp)))))
                (unless (eq? bufs (let ((old (occur-revert-arguments)))
                                    (and old (list-ref-or old 2 #f))))
                  (occur--garbage-collect-revert-args))
                (set-buffer-local-value! (current-buffer) 'occur-revert-arguments
                                         (list regexp nlines bufs))
                (if (= count 0)
                    (%kill-buffer occur-buf)
                    (begin
                      (display-buffer occur-buf '(nil (category . occur)))
                      (when (*occur--final-pos*)
                        (set-window-point!
                         (get-buffer-window occur-buf 'all-frames)
                         (*occur--final-pos*)))
                      (set! next-error-last-buffer occur-buf)
                      (set!buffer-read-only occur-buf #t)
                      (with-current-buffer occur-buf
                        (set-buffer-modified-p #f))
                      (run-hooks (*occur-hook*)))))))))))

    (define (occur-engine regexp buffers out-buf nlines case-fold
                          title-face prefix-face match-face keep-props)
      ;; GNU Emacs's `occur-engine' (`replace.el:2325').
      ;;
      ;; `case-fold-search` is a parameter here, so Emacs's second,
      ;; per-buffer binding of it is the one `parameterize` around the
      ;; whole walk rather than a `let` inside the `dolist`; there are no
      ;; buffer-local values of it for the inner binding to matter to.
      ;; The coding system of the source buffer travels to the output
      ;; buffer through the buffer-local slot rather than
      ;; `set-buffer-file-coding-system` (that is `mule-cmds`, a
      ;; front-end library this one cannot import); the C sets the same
      ;; slot.
      ;;--------------------------------------------------------------
      (with-current-buffer out-buf
        (let ((global-lines 0)    ;; total count of matching lines
              (global-matches 0)  ;; total count of matches
              (coding #f)
              (multi-occur-p (pair? (cdr buffers))))
          (parameterize ((*case-fold-search* case-fold))
            (for-each
             (lambda (boo)
               (when (if (overlayp boo) (overlay-buffer boo) (buffer-live-p boo))
                 (with-current-buffer (if (overlayp boo) (overlay-buffer boo) boo)
                   (parameterize ((*inhibit-field-text-motion* #t))
                     (let ((lines 0)               ; count of matching lines
                           (matches 0)             ; count of matches
                           (headerpt (with-current-buffer out-buf (point)))
                           (orig-line (if (not (overlayp boo))
                                          (line-number-at-pos)
                                          (line-number-at-pos
                                           (overlay-get boo 'occur--orig-point)))))
                       (save-excursion
                         ;; begin searching in the buffer
                         (goto-char (if (overlayp boo)
                                        (overlay-start boo)
                                        (point-min)))
                         (forward-line 0)
                         (let* ((limit (if (overlayp boo)
                                           (overlay-end boo)
                                           (point-max)))
                                (start-line (line-number-at-pos))
                                (curr-line start-line) ; line count
                                (orig-line-shown-p #f)
                                (prev-line #f)         ; line number of prev match endpt
                                (prev-after-lines #f)  ; context lines of prev match
                                (matchbeg 0)
                                (origpt #f)
                                (begpt #f)
                                (endpt #f)
                                (markers '())  ; list of (BEG-MARKER . END-MARKER)
                                (curstring ""))
                           (unless (or coding
                                       (not (local-variable-p
                                             'buffer-file-coding-system)))
                             (set! coding
                                   (buffer-local-value (current-buffer)
                                                       'buffer-file-coding-system
                                                       #f)))
                           (let loop ()
                             (when (< (point) limit)
                             (set! origpt (point))
                             (set! endpt (re-search-forward regexp limit #t))
                             (when endpt
                               (set! lines (+ lines 1)) ; increment matching lines count
                               (set! matchbeg (match-beginning 0))
                               ;; Get beginning of first match line and end of the last.
                               (save-excursion
                                 (goto-char matchbeg)
                                 (set! begpt (line-beginning-position))
                                 (goto-char endpt)
                                 (set! endpt (line-end-position)))
                               ;; Sum line numbers up to the first match line.
                               (set! curr-line (+ curr-line
                                                  (count-lines origpt begpt)))
                               (set! markers '())
                               (set! curstring
                                     (occur-engine-line begpt endpt keep-props))
                               ;; Highlight the matches
                               (let ((len (string-length curstring))
                                     (start 0))
                                 ;; Count empty lines that don't use next loop.
                                 (when (zero? len)
                                   (set! matches (+ matches 1)))
                                 (when (and (*list-matching-lines-jump-to-current-line*)
                                            (not multi-occur-p))
                                   (or orig-line (set! orig-line 1))
                                   (or nlines (set! nlines
                                                   (line-number-at-pos (point-max))))
                                   (when (= curr-line orig-line)
                                     (add-face-text-property
                                      0 len
                                      (*list-matching-lines-current-line-face*)
                                      #f curstring)
                                     (add-text-properties
                                      0 len '(current-line t) curstring))
                                   (when (and (>= orig-line (- curr-line nlines))
                                              (<= orig-line (+ curr-line nlines)))
                                     ;; Shown either here or will be shown
                                     ;; by occur-context-lines
                                     (set! orig-line-shown-p #t)))
                                 (let loop ((start start))
                                   (when (and (< start len)
                                              (string-match regexp curstring start))
                                     (set! markers
                                           (cons (cons (set-marker
                                                        (make-marker)
                                                        (+ begpt (match-beginning 0)))
                                                       (set-marker
                                                        (make-marker)
                                                        (+ begpt (match-end 0))))
                                                 markers))
                                     (set! matches (+ matches 1))
                                     (add-text-properties
                                      (match-beginning 0) (match-end 0)
                                      '(occur-match t) curstring)
                                     (when match-face
                                       ;; Add `match-face' to faces copied
                                       ;; from the buffer.
                                       (add-face-text-property
                                        (match-beginning 0) (match-end 0)
                                        match-face #f curstring))
                                     ;; Avoid infloop.
                                     (let ((end (match-end 0)))
                                       (loop (if (= start end)
                                                 (+ start 1)
                                                 end))))))
                               (set! markers (reverse markers))
                               ;; Generate the string to insert for this match
                               (let* ((match-prefix
                                       ;; Using 7 digits aligns tabs properly.
                                       (apply propertize
                                              (%format "%7d:" curr-line)
                                              (append
                                               (if prefix-face
                                                   (list 'font-lock-face prefix-face)
                                                   '())
                                               (list
                                                'occur-prefix #t
                                                ;; Allow insertion of text
                                                ;; at the end of the prefix
                                                ;; (for Occur Edit mode).
                                                'front-sticky #t
                                                'rear-nonsticky #t
                                                'read-only #t
                                                'occur-target markers
                                                'follow-link #t
                                                'help-echo "mouse-2: go to this occurrence"))))
                                      (match-str
                                       ;; We don't put `mouse-face' on the newline,
                                       ;; because that loses.  And don't put it
                                       ;; on context lines to reduce flicker.
                                       (propertize curstring
                                                   'occur-target markers
                                                   'follow-link #t
                                                   'help-echo
                                                   "mouse-2: go to this occurrence"))
                                      (out-line
                                       ;; Add non-numeric prefix to all non-first
                                       ;; lines of multi-line matches.
                                       (concat
                                        (string-replace
                                         "\n"
                                         (if prefix-face
                                             (propertize
                                              "\n       :"
                                              'font-lock-face prefix-face
                                              'occur-target markers)
                                             (propertize
                                              "\n       :"
                                              'occur-target markers))
                                         ;; Add mouse face in one section to
                                         ;; ensure the prefix and the string
                                         ;; get a contiguous highlight.
                                         (propertize (concat match-prefix match-str)
                                                     'mouse-face 'highlight))
                                        ;; Add markers at eol, but no mouse props.
                                        (propertize "\n" 'occur-target markers)))
                                      (ret (and (not (= nlines 0))
                                                (occur-context-lines
                                                 out-line nlines keep-props begpt
                                                 endpt curr-line prev-line
                                                 prev-after-lines prefix-face
                                                 orig-line multi-occur-p)))
                                      (data
                                       (if (= nlines 0)
                                           ;; The simple display style
                                           out-line
                                           ;; The complex multi-line display style.
                                           (begin
                                             ;; Set first elem of the returned list
                                             ;; to `data', and the second elem to
                                             ;; `prev-after-lines'.
                                             (set! prev-after-lines (cadr ret))
                                             (car ret))))
                                      (orig-line-str
                                       (if (and (*list-matching-lines-jump-to-current-line*)
                                                (not orig-line-shown-p)
                                                (> curr-line orig-line))
                                           (begin
                                             (set! orig-line-shown-p #t)
                                             (save-excursion
                                               (goto-char (point-min))
                                               (forward-line (- orig-line 1))
                                               (occur-engine-line
                                                (line-beginning-position)
                                                (line-end-position)
                                                keep-props)))
                                           #f)))
                                 ;; Actually insert the match display data
                                 (with-current-buffer out-buf
                                   (when orig-line-str
                                     (add-face-text-property
                                      0 (string-length orig-line-str)
                                      (*list-matching-lines-current-line-face*)
                                      #f orig-line-str)
                                     (add-text-properties
                                      0 (string-length orig-line-str)
                                      '(current-line t) orig-line-str)
                                     (insert (car (occur-engine-add-prefix
                                                   (list orig-line-str)
                                                   prefix-face))))
                                   (insert data)))
                               (goto-char endpt))
                             (if endpt
                                 (begin
                                   ;; Sum line numbers between first and last
                                   ;; match lines.
                                   (set! curr-line
                                         (+ curr-line
                                            (count-lines begpt endpt)
                                            ;; Add 1 for empty last match line
                                            ;; since count-lines returns one
                                            ;; line less.
                                            (if (and (bolp) (eolp)) 1 0)))
                                   ;; On to the next match...
                                   (forward-line 1))
                                 (goto-char (point-max)))
                             (set! prev-line (- curr-line 1))
                             (loop)))
                           ;; Flush remaining context after-lines.
                           (when prev-after-lines
                             (with-current-buffer out-buf
                               (insert (apply concat
                                              (occur-engine-add-prefix
                                               prev-after-lines prefix-face)))))
                           (when (and (*list-matching-lines-jump-to-current-line*)
                                      (not orig-line-shown-p))
                             (set! orig-line-shown-p #t)
                             (let ((orig-line-str
                                    (save-excursion
                                      (goto-char (point-min))
                                      (forward-line (- orig-line 1))
                                      (occur-engine-line
                                       (line-beginning-position)
                                       (line-end-position)
                                       keep-props))))
                               (add-face-text-property
                                0 (string-length orig-line-str)
                                (*list-matching-lines-current-line-face*)
                                #f orig-line-str)
                               (add-text-properties
                                0 (string-length orig-line-str)
                                '(current-line t) orig-line-str)
                               (with-current-buffer out-buf
                                 (insert
                                  (car (occur-engine-add-prefix
                                        (list orig-line-str) prefix-face)))))))
                       (when (not (zero? lines)) ; is the count zero?
                         (set! global-lines (+ global-lines lines))
                         (set! global-matches (+ global-matches matches))
                         (with-current-buffer out-buf
                           (goto-char headerpt)
                           (let ((beg (point))
                                 (end #f))
                             (insert
                              (propertize
                               (%format "%d %s%s%s in buffer: %s%s\n"
                                        matches
                                        (ngettext "match" "matches" matches)
                                        ;; Don't display the same number of
                                        ;; lines and matches in case of 1
                                        ;; match per line.
                                        (if (= lines matches)
                                            ""
                                            (%format " in %d %s"
                                                     lines
                                                     (ngettext "line" "lines"
                                                               lines)))
                                        ;; Don't display regexp for multi-buffer.
                                        (if (> (length buffers) 1)
                                            ""
                                            (occur-regexp-descr regexp))
                                        (buffer-name (if (overlayp boo)
                                                         (overlay-buffer boo)
                                                         boo))
                                        (if (overlayp boo)
                                            (%format " within region: %d-%d"
                                                     (overlay-start boo)
                                                     (overlay-end boo))
                                            ""))
                               'read-only #t))
                             (set! end (point))
                             (when title-face
                               (add-face-text-property beg end title-face))
                             (goto-char
                              (if (and (*list-matching-lines-jump-to-current-line*)
                                       (not multi-occur-p))
                                  (begin
                                    (goto-char (point-max))
                                    ;; `(setq occur--final-pos (and
                                    ;; (goto-char (point-max)) (or ...)))'
                                    ;; - the value the C's `if` answers is
                                    ;; the position, and this `goto-char`
                                    ;; reads it, so the setter's own
                                    ;; answer (unspecified) cannot be it.
                                    (let ((pos (or (previous-single-property-change
                                                    (point) 'current-line)
                                                   (point-max))))
                                      (*occur--final-pos* pos)
                                      pos))
                                  (point-min))))))))))))
             buffers))
          ;; Display total match count and regexp for multi-buffer.
          (when (and (not (zero? global-lines)) (> (length buffers) 1))
            (goto-char (point-min))
            (let ((beg (point))
                  (end #f))
              (insert (%format "%d %s%s total%s:\n"
                               global-matches
                               (ngettext "match" "matches" global-matches)
                               ;; Don't display the same number of lines and
                               ;; matches in case of 1 match per line.
                               (if (= global-lines global-matches)
                                   ""
                                   (%format " in %d %s"
                                            global-lines
                                            (ngettext "line" "lines"
                                                      global-lines)))
                               (occur-regexp-descr regexp)))
              (set! end (point))
              (when title-face
                (add-face-text-property beg end title-face)))
            (goto-char (point-min)))
          (if coding
              ;; CODING is buffer-file-coding-system of the first buffer
              ;; that locally binds it.  Let's use it also for the output
              ;; buffer.
              (set-buffer-local-value! out-buf 'buffer-file-coding-system coding))
          ;; Return the number of matches
          global-matches)))

    (define (occur-engine-line beg end . args)
      ;; GNU Emacs's `occur-engine-line' (`replace.el:2572').
      ;;--------------------------------------------------------------
      (let ((keep-props (if (pair? args) (car args) #f)))
        (if (and keep-props (font-lock-mode-on?))
            (font-lock-ensure beg end))
        (if (and keep-props (not (eq? (*occur-excluded-properties*) #t)))
            (let ((str (buffer-substring beg end)))
              (remove-list-of-text-properties
               0 (string-length str) (*occur-excluded-properties*) str)
              str)
            (buffer-substring-no-properties beg end))))

    (define (occur-engine-add-prefix lines . args)
      ;; GNU Emacs's `occur-engine-add-prefix' (`replace.el:2583').
      ;;--------------------------------------------------------------
      (let ((prefix-face (if (pair? args) (car args) #f)))
        (map (lambda (line)
               (concat (if prefix-face
                           (propertize "       :" 'font-lock-face prefix-face)
                           "       :")
                       line "\n"))
             lines)))

    (define (occur-accumulate-lines count . args)
      ;; GNU Emacs's `occur-accumulate-lines' (`replace.el:2595').
      ;;--------------------------------------------------------------
      (let ((keep-props (if (pair? args) (car args) #f))
            (pt (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (save-excursion
          (when pt
            (goto-char pt))
          (let ((forwardp (> count 0))
                (result '())
                (moved #f))
            (let loop ()
              (unless (or (zero? count)
                          (if forwardp
                              (eobp)
                              (and (bobp) (not moved))))
                (set! count (+ count (if forwardp -1 1)))
                (let ((beg (line-beginning-position))
                      (end (line-end-position)))
                  (set! result
                        (cons (occur-engine-line beg end keep-props) result)))
                (set! moved (= 0 (forward-line (if forwardp 1 -1))))
                (loop)))
            (reverse result)))))

    (define (occur-context-lines out-line nlines keep-props begpt endpt
                                 curr-line prev-line prev-after-lines
                                 . args)
      ;; GNU Emacs's `occur-context-lines' (`replace.el:2618'): "Generate
      ;; context display for occur."
      ;;--------------------------------------------------------------
      (let ((prefix-face (if (pair? args) (car args) #f))
            (orig-line (if (and (pair? args) (pair? (cdr args)))
                           (cadr args) #f))
            (multi-occur-p (if (and (pair? args) (pair? (cdr args))
                                    (pair? (cddr args)))
                               (caddr args) #f)))
        ;; Find after- and before-context lines of the current match.
        (let ((before-lines
               (reverse (cdr (occur-accumulate-lines
                              (- (+ 1 (abs nlines))) keep-props begpt))))
              (after-lines
               (cdr (occur-accumulate-lines
                     (+ 1 nlines) keep-props endpt)))
              (separator #f))
          (when (and (*list-matching-lines-jump-to-current-line*)
                     (not multi-occur-p))
            (when (and (>= orig-line (- curr-line nlines))
                       (< orig-line curr-line))
              (let ((curstring
                     (list-ref before-lines
                               (- (length before-lines)
                                  (- curr-line orig-line)))))
                (add-face-text-property
                 0 (string-length curstring)
                 (*list-matching-lines-current-line-face*) #f curstring)
                (add-text-properties 0 (string-length curstring)
                                     '(current-line t) curstring)))
            (when (and (<= orig-line (+ curr-line nlines))
                       (> orig-line curr-line))
              (let ((curstring
                     (list-ref after-lines (- orig-line curr-line 1))))
                (add-face-text-property
                 0 (string-length curstring)
                 (*list-matching-lines-current-line-face*) #f curstring)
                (add-text-properties 0 (string-length curstring)
                                     '(current-line t) curstring))))
          ;; Combine after-lines of the previous match
          ;; with before-lines of the current match.
          (when prev-after-lines
            ;; Don't overlap prev after-lines with current before-lines.
            (if (>= (+ prev-line (length prev-after-lines))
                    (- curr-line (length before-lines)))
                (set! prev-after-lines
                      (seq-take prev-after-lines
                                (- curr-line prev-line
                                   (length before-lines) 1)))
                ;; Separate non-overlapping context lines with a dashed line.
                (set! separator "-------\n")))
          (when prev-line
            ;; Don't overlap current before-lines with previous match line.
            (if (<= (- curr-line (length before-lines)) prev-line)
                (set! before-lines
                      (nthcdr (- (length before-lines)
                                 (- curr-line prev-line 1))
                              before-lines))
                ;; Separate non-overlapping before-context lines.
                (unless (> nlines 0)
                  (set! separator "-------\n"))))
          (list
           ;; Return a list where the first element is the output line.
           (apply concat
                  (append
                   (if prev-after-lines
                       (occur-engine-add-prefix prev-after-lines prefix-face)
                       '())
                   (if separator
                       (list (if prefix-face
                                 (propertize separator
                                             'font-lock-face prefix-face)
                                 separator))
                       '())
                   (occur-engine-add-prefix before-lines prefix-face)
                   (list out-line)))
           ;; And the second element is the list of context after-lines.
           (if (> nlines 0) after-lines #f)))))

    (define (occur--garbage-collect-revert-args)
      ;; GNU Emacs's `occur--garbage-collect-revert-args'
      ;; (`replace.el:1660').
      ;;--------------------------------------------------------------
      (let ((args (occur-revert-arguments)))
        (when (pair? args)
          (for-each (lambda (boo)
                      (when (overlayp boo) (delete-overlay boo)))
                    (list-ref-or args 2 '()))))
      (kill-local-variable 'occur-revert-arguments))

    (define (occur-revert-function ignore1 ignore2)
      ;; GNU Emacs's `occur-revert-function' (`replace.el:1712'):
      ;; "Handle `revert-buffer' for Occur mode buffers."
      ;;--------------------------------------------------------------
      (apply occur-1 (append (occur-revert-arguments)
                             (list (buffer-name)))))

    (define (occur-mode--find-occurrences)
      ;; GNU Emacs's `occur-mode--find-occurrences' (`replace.el:1723').
      ;;--------------------------------------------------------------
      (let* ((targets (get-text-property (point) 'occur-target))
             (start (occur--targets-start targets)))
        (unless targets
          (error "No occurrence on this line"))
        (unless (buffer-live-p (marker-buffer start))
          (error "Buffer for this occurrence was killed"))
        targets))

    (define (occur-mode-find-occurrence)
      ;; GNU Emacs's `occur-mode-find-occurrence' (`replace.el:1717'):
      ;; "Return a marker to the first match of the line at point."
      ;; Retained for compatibility.
      ;;--------------------------------------------------------------
      (occur--targets-start (occur-mode--find-occurrences)))

    (define (occur--targets-start targets)
      ;; GNU Emacs's `occur--targets-start' (`replace.el:1707'): "First
      ;; marker of the `occur-target' property value TARGETS."
      ;;--------------------------------------------------------------
      (if (pair? targets)
          (car (car targets))
          ;; Tolerate an `occur-target' value that is a single marker for
          ;; compatibility.
          targets))

    (define (occur--set-arrow)
      ;; GNU Emacs's `occur--set-arrow' (`replace.el:1737'): "Set the
      ;; overlay arrow at the first line of the occur match at point."
      ;;
      ;; The renderer draws no overlay arrows (`xdisp.scm` says so where
      ;; the variable lives), so what this sets is the marker and its
      ;; position.
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((target (get-text-property (point) 'occur-target))
              ;; Find the start of the occur match, in case it's multi-line.
              (prev (previous-single-property-change (point) 'occur-target)))
          (when (and prev (eq? (get-text-property prev 'occur-target) target))
            (goto-char prev))
          (set! overlay-arrow-position
                (set-marker (or overlay-arrow-position (make-marker))
                            (line-beginning-position))))))

    (define-command (occur-mode-goto-occurrence event)
      ;; GNU Emacs's `occur-mode-goto-occurrence' (`replace.el:1759'):
      ;; "Go to the occurrence specified by EVENT, a mouse click. If not
      ;; invoked by a mouse click, go to occurrence on the current line."
      ;;--------------------------------------------------------------
      "Go to the occurrence the current line describes."
      (interactive (list (*last-nonmenu-event*)))
      (let* ((buffer (if event (current-buffer) #f))
             (targets
              (if (not event)
                  ;; Actually `event-end' works correctly with a nil
                  ;; argument as well, so we could dispense with this test,
                  ;; but let's not rely on this undocumented behavior.
                  (occur-mode--find-occurrences)
                  (with-current-buffer
                      (window-buffer (posn-window (event-end event)))
                    (save-excursion
                      (goto-char (posn-point (event-end event)))
                      (occur-mode--find-occurrences)))))
             (pos (occur--targets-start targets)))
        (occur--set-arrow)
        (pop-to-buffer (marker-buffer pos))
        (goto-char pos)
        (occur--highlight-occurrences targets)
        (when buffer (next-error-found buffer (current-buffer)))
        (run-hooks (*occur-mode-find-occurrence-hook*))))

    (define-alias occur-mode-mouse-goto occur-mode-goto-occurrence)

    (define-command (occur-mode-goto-occurrence-other-window)
      ;; GNU Emacs's `occur-mode-goto-occurrence-other-window'
      ;; (`replace.el:1789'): "Go to the occurrence the current line
      ;; describes, in another window."
      ;;--------------------------------------------------------------
      "Go to the occurrence the current line describes, in another window."
      (interactive)
      (let ((buffer (current-buffer))
            (pos (occur--targets-start (occur-mode--find-occurrences))))
        (occur--set-arrow)
        (switch-to-buffer-other-window (marker-buffer pos))
        (goto-char pos)
        (next-error-found buffer (current-buffer))
        (run-hooks (*occur-mode-find-occurrence-hook*))))

    (define (occur-goto-locus-delete-o)
      ;; GNU Emacs's `occur-goto-locus-delete-o' (`replace.el:1800').
      ;;--------------------------------------------------------------
      (for-each delete-overlay occur-highlight-overlays)
      (set! occur-highlight-overlays '())
      ;; Get rid of timer and hook that would try to do this again.
      (if (timer? next-error-highlight-timer)
          (cancel-timer next-error-highlight-timer))
      (remove-hook *pre-command-hook* occur-goto-locus-delete-o))

    ;; Highlight the current visited occurrence.
    (define (occur--highlight-occurrences targets)
      ;; GNU Emacs's `occur--highlight-occurrences' (`replace.el:1810').
      ;;--------------------------------------------------------------
      (let ((start-marker (occur--targets-start targets)))
        (occur-goto-locus-delete-o)
        (with-current-buffer (marker-buffer start-marker)
          (when (or (eq? (*next-error-highlight*) #t)
                    (number? (*next-error-highlight*)))
            (set! occur-highlight-overlays
                  (map (lambda (target)
                         (let ((o (make-overlay (car target) (cdr target))))
                           (overlay-put o 'face 'next-error)
                           o))
                       (if (list? targets)
                           targets
                           ;; `occur-target' compatibility: when we only
                           ;; have a single starting point, highlight the
                           ;; rest of the line.
                           (let ((end-pos (save-excursion
                                            (goto-char start-marker)
                                            (line-end-position))))
                             (list (cons start-marker end-pos))))))
            (add-hook *pre-command-hook* occur-goto-locus-delete-o)
            (when (number? (*next-error-highlight*))
              ;; We want highlighting for a limited time: set up a timer
              ;; to delete it.
              (set! next-error-highlight-timer
                    (run-at-time (*next-error-highlight*) #f
                                 occur-goto-locus-delete-o))))
          (when (eq? (*next-error-highlight*) 'fringe-arrow)
            ;; We want a fringe arrow (instead of highlighting).
            (set! next-error-overlay-arrow-position
                  (copy-marker (line-beginning-position)))))))

    (define-command (occur-mode-display-occurrence)
      ;; GNU Emacs's `occur-mode-display-occurrence' (`replace.el:1837').
      ;;
      ;; Emacs binds `display-buffer-overriding-action` around the
      ;; display; this tree's `display-buffer` takes the action as its
      ;; argument, so it is passed there directly.
      ;;--------------------------------------------------------------
      "Display in another window the occurrence the current line describes."
      (interactive)
      (let* ((buffer (current-buffer))
             (targets (occur-mode--find-occurrences))
             (pos (occur--targets-start targets)))
        (parameterize ((*next-error-highlight*
                        (*next-error-highlight-no-select*)))
          (let ((window (display-buffer
                         (marker-buffer pos)
                         '(nil (inhibit-same-window . t)))))
            (occur--set-arrow)
            ;; This is the way to set point in the proper window.
            (save-selected-window
              (select-window window)
              (goto-char pos)
              (occur--highlight-occurrences targets)
              (next-error-found buffer (current-buffer))
              (run-hooks (*occur-mode-find-occurrence-hook*)))))))

    (define (occur-find-match n search-command message-string)
      ;; GNU Emacs's `occur-find-match' (`replace.el:1855').
      ;;--------------------------------------------------------------
      (let ((n (or n 1)))
        (let loop ((n n))
          (when (> n 0)
            (let ((r (search-command (point) 'occur-match)))
              (if (and r (get-text-property r 'occur-match))
                  (set! r (search-command r 'occur-match)))
              (if r
                  (goto-char r)
                  (user-error message-string))
              (loop (- n 1)))))))

    (define-command (occur-next n)
      ;; GNU Emacs's `occur-next' (`replace.el:1867`): "Move to the Nth
      ;; (default 1) next match in an Occur mode buffer."
      ;;--------------------------------------------------------------
      "Move to the Nth (default 1) next match in an Occur mode buffer."
      (interactive "p")
      (occur-find-match n next-single-property-change "No more matches"))

    (define-command (occur-prev n)
      ;; GNU Emacs's `occur-prev' (`replace.el:1873`): "Move to the Nth
      ;; (default 1) previous match in an Occur mode buffer."
      ;;--------------------------------------------------------------
      "Move to the Nth (default 1) previous match in an Occur mode buffer."
      (interactive "p")
      (occur-find-match n previous-single-property-change "No earlier matches"))

    (define-command (occur-next-error argp . rest)
      ;; GNU Emacs's `occur-next-error' (`replace.el:1879`): "Move to the
      ;; ARGPth (default 1) next match in an Occur mode buffer. RESET
      ;; non-nil means rewind to the first match."
      ;;
      ;; It is the buffer's `next-error-function`; the command
      ;; `next-error` that would call it is not ported.
      ;;--------------------------------------------------------------
      "Move to the ARGPth (default 1) next match in an Occur mode buffer.
RESET non-nil means rewind to the first match."
      (interactive "p")
      (let ((reset (if (pair? rest) (car rest) #f)))
      (goto-char (cond (reset (point-min))
                       ((< argp 0) (line-beginning-position))
                       ((> argp 0) (line-end-position))
                       (else (point))))
      (occur-find-match
       (abs argp)
       (if (> 0 argp) previous-single-property-change
           next-single-property-change)
       "No more matches")
      ;; In case the *Occur* buffer is visible in a nonselected window.
      (let ((win (get-buffer-window (current-buffer) #t)))
        (if win (set-window-point! win (point))))
      (occur-mode-goto-occurrence #f)))

    (define-custom occur-mode-hook '()
      "Hook run when entering Occur mode."
      :type 'hook :group 'matching)
    ;; ^ GNU Emacs's `occur-mode-hook' (`replace.el:1643'), a defcustom
    ;; whose default is `(turn-on-font-lock)`. A `define-custom` like
    ;; every Emacs mode-hook defcustom here; `define-derived-mode` hands
    ;; the parameter to `run-mode-hooks`, and `run-hooks` dereferences it.
    ;; Its default is set at the bottom of this section.

    (define-custom *occur-hook* '()
      "Hook run by Occur when there are any matches."
      :type 'hook
      :group 'matching)

    (define-custom *occur-mode-find-occurrence-hook* '()
      "Hook run by Occur after locating an occurrence.
This will be called with the cursor position at the occurrence.  An application
for this is to reveal context in an outline mode when the occurrence is hidden."
      :type 'hook
      :group 'matching)

    (define occur-mode-map (km:keymap '*occur-mode-map*))

    ;; `occur-mode` is `define-derived-mode occur-mode special-mode
    ;; "Occur" occur-mode-map occur-mode-hook` (`replace.el:1666`).
    ;; **It is defined after the commands its body names**, where Emacs
    ;; has it before them, for the reason `define-key`s come after their
    ;; commands: a Scheme binding is looked up when the body runs and a
    ;; definition later in the library is not there yet for a compiled
    ;; caller that runs before the load finishes. `(put 'occur-mode
    ;; 'mode-class 'special)` is Emacs's and is set below.
    (define-derived-mode (occur-mode special-mode "Occur"
                                     occur-mode-map occur-mode-hook)
      "Major mode for output from \\[occur].
\\<occur-mode-map>Move point to one of the items in this buffer, then use
\\[occur-mode-goto-occurrence] to go to the occurrence that the item refers to.
Alternatively, click \\[occur-mode-mouse-goto] on an item to go to it.

\\{occur-mode-map}"
      (set-buffer-local-value! (current-buffer) 'revert-buffer-function
                               occur-revert-function)
      (set-buffer-local-value! (current-buffer) 'next-error-function
                               occur-next-error))

    (put 'occur-mode 'mode-class 'special)

    (define-alias list-matching-lines occur)

    ;; Emacs's default `occur-mode-hook` runs `turn-on-font-lock`
    ;; (`replace.el:1643`), which is why the occurrences' faces are
    ;; there when the buffer is first shown.
    (occur-mode-hook (list turn-on-font-lock))

    ;; The map's bindings, at the end because a binding holds the
    ;; command's value. What Emacs's map also binds and this does not:
    ;; `e` (`occur-edit-mode`), `n`/`p` (`next-error-no-select`/
    ;; `previous-error-no-select`), `l` (`recenter-current-error`),
    ;; `C-c C-f` (`next-error-follow-minor-mode`), `c` (`clone-buffer`),
    ;; and the `[menu-bar occur]` entry.
    (define-key occur-mode-map (vector 'mouse-2) occur-mode-mouse-goto)
    (define-key occur-mode-map (kbd "C-c C-c") occur-mode-goto-occurrence)
    (define-key occur-mode-map (kbd "RET") occur-mode-goto-occurrence)
    (define-key occur-mode-map (kbd "o")
      occur-mode-goto-occurrence-other-window)
    (define-key occur-mode-map (kbd "C-o") occur-mode-display-occurrence)
    (define-key occur-mode-map (kbd "M-n") occur-next)
    (define-key occur-mode-map (kbd "M-p") occur-prev)
    (define-key occur-mode-map (kbd "r") occur-rename-buffer)

    ;; `occur-mode`'s `(add-hook 'kill-buffer-hook
    ;; #'occur--garbage-collect-revert-args nil t)` (`replace.el:1674`).
    ;; **The LOCAL argument is not carried** (`add-hook` here is one
    ;; global list, `subr.scm` says why), so the function goes on the
    ;; global hook and guards itself: `%kill-buffer` runs the hook with
    ;; the dying buffer current, so `occur-revert-arguments` is that
    ;; buffer's own, and a buffer that never ran `occur` answers #f.
    (add-hook *kill-buffer-hook* occur--garbage-collect-revert-args)

    ;;----------------------------------------------------------------
    ;; `isearch-occur' - isearch.el's command, here for the reason
    ;; `isearch-query-replace' is: it calls `occur' and `region-bounds',
    ;; both of this library, and `replace.scm` imports `isearch.scm`, so
    ;; the other way round would be a cycle. The search's loop runs it
    ;; through `call-interactively` when the tool bar's "Show hits"
    ;; button (or `M-s o`) names it.
    ;;
    ;; Emacs's `(when (and (symbolp this-command) (get this-command
    ;; 'isearch-exit)) (isearch-done nil t) (isearch-clean-overlays))`
    ;; is not carried, because Emacs 31.1 never puts that symbol property
    ;; on the command (`emacs -Q --batch` answers nil) - so the search is
    ;; still running when `occur' displays its buffer, and the search's
    ;; own loop here does the same thing: it does not exit first.
    ;;----------------------------------------------------------------
    (define-command (isearch-occur regexp nlines)
      ;; GNU Emacs's `isearch-occur' (`isearch.el:2475`): "Run `occur'
      ;; using the last search string as the regexp. ..."
      ;;
      ;; The regexp conversion's two `isearch-regexp-function` arms are
      ;; not carried - this tree's search is literal, and
      ;; `isearch-regexp-function` does not exist - so the cond's last
      ;; two arms are what is here. `with-isearch-suspended` around the
      ;; collect prompt is not carried: the prompt is an ordinary
      ;; minibuffer read while the search's loop waits.
      ;;--------------------------------------------------------------
      "Run `occur' using the last search string as the regexp."
      (interactive
       (let* ((perform-collect (pair? (current-prefix-arg)))
              (regexp (if isearch-regexp
                          isearch-string
                          (regexp-quote isearch-string))))
         (list regexp
               (if perform-collect
                   ;; Perform collect operation
                   (if (zero? (regexp-opt-depth regexp))
                       ;; No subexpression so collect the entire match.
                       "\\&"
                       ;; Get the regexp for collection pattern.
                       (let ((default (let ((entries (history-entries
                                                      occur-collect-regexp-history)))
                                        (and (pair? entries) (car entries)))))
                         (read-regexp
                          (format-prompt "Regexp to collect" default)
                          default occur-collect-regexp-history)))
                   ;; Otherwise normal occur takes numerical prefix argument.
                   (let ((arg (current-prefix-arg)))
                     (if arg (prefix-numeric-value arg) #f))))))
      (parameterize ((*case-fold-search* isearch-case-fold-search)
                     ;; Set `search-upper-case' to nil to not call
                     ;; `isearch-no-upper-case-p' in `occur-1'.
                     (*search-upper-case* #f))
        (occur regexp nlines (if (use-region-p) (region-bounds) #f))))

    ))
