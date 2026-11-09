(define-library (schemacs editor subr)
  ;; This library mirrors GNU Emacs's `subr.el': the small general
  ;; functions the rest of Emacs is written in terms of.
  ;;
  ;; What is here so far is one of them, `add-to-history', which the kill
  ;; ring and the mark ring both push onto. Subr is enormous and mostly
  ;; elisp-layer; it grows as the things that need it arrive.

  (import
    (scheme base)
    ;; `history-length' and `history-delete-duplicates' are `minibuf.c''s
    ;; variables, and `add-to-history' reads them for the maximum length
    ;; when the caller does not give one.
    (only (schemacs editor minibuf)
          *history-delete-duplicates* *history-length*)
    ;; `delete' is Guile's - R7RS has no list `delete' - and `logand' is
    ;; `key-parse''s control-character folding.
    ;; `logior' and `lognot' are the event model's bit arithmetic, beside
    ;; the `logand' `key-parse' already folds control characters with, and
    ;; `filter' orders a symbol event's modifiers.
    (only (guile) delete string-contains format catch string-index)
    ;; a condition that is not an error object is read through these
    (only (ice-9 exceptions) exception-message)
    ;; `char-downcase' is `event-basic-type''s.
    (scheme char)
    ;; `string-prefix-p' compares with `compare-strings', which is
    ;; fns.c's and lives in `(schemacs editor fns)'. That library is
    ;; below this one - it imports none of subr - so this is not a
    ;; cycle.
    (only (schemacs editor fns) compare-strings concat)
    ;; The key event model and `kbd' live in `character.sld', the lowest
    ;; editor library - see its export note. They are re-exported from
    ;; here so that a library importing `(schemacs editor subr) kbd' still
    ;; finds it.
    (only (schemacs editor character)
          kbd char-alt char-super char-hyper char-shift char-ctl char-meta
          parse-solitary-modifier make-ctrl-char
          parse-modifiers-uncached event-symbol-elements
          event-modifiers event-basic-type apply-modifiers event-convert-list)
    ;; `ctl-x-4-map' below is `subr.el''s and it is a *keymap*, so this
    ;; library needs the keymap layer to build one. `(schemacs editor
    ;; keymap)' is a leaf - it imports `character' and nothing else of the
    ;; editor - so this is not a cycle.
    (only (schemacs editor keymap) keymap *default-keymap* define-key)
    ;; `kill-all-local-variables' (`buffer.c') runs `change-major-mode-hook'
    ;; through `run-hooks', and the buffer library cannot import this one -
    ;; this library reaches the engine through `fns.sld' and
    ;; `intervals.sld', and the engine is built on the buffer library. So
    ;; the hook runner arrives there through a seam, and this is where it
    ;; is installed.
    ;; `replace-regexp-in-string` and `split-string` are `subr.el`'s and
    ;; are built on `search.c`'s primitives, which are above this
    ;; library - nothing `search` imports reaches back here, so the edge
    ;; is not a cycle.
    (only (schemacs editor search)
          string-match string-match-p match-beginning match-end match-string
          replace-match match-data--translate save-match-data)
    (only (schemacs editor buffer)
          *run-hooks-function*
          ;; `with-temp-buffer` makes and kills one; `kill-buffer` is
          ;; the command and asks questions, so it is not this one.
          generate-new-buffer %kill-buffer with-current-buffer buffer-name
          ;; `with-silent-modifications` binds four of `buffer.c`'s
          ;; things, so the macro's template has to resolve them here -
          ;; and it does resolve them here: a `syntax-rules` template's
          ;; free identifiers are hygienic, meaning they name what they
          ;; name *in this library*, whatever the caller has imported.
          ;; The one of the four this tree has not got is
          ;; `inhibit-modification-hooks`.
          *inhibit-read-only* buffer-modified-p current-buffer
          restore-buffer-modified-p set!text-editor-undo-list
          text-editor-undo-list)
    )

  (export
   assoc-delete-all assq-delete-all delq
   add-to-history add-to-list
   ;; string/list helpers `subr.el`'s, for the external packages and
   ;; anything else written in Emacs's idiom
   split-string replace-regexp-in-string shell-quote-argument
   string-trim string-trim-left string-trim-right
   intern error-message-string
   with-temp-buffer
   ;; the separator regexp `split-string` defaults to (`subr.el`'s
   ;; `split-string-default-separators`)
   *split-string-default-separators*
   ;; `minor-mode-alist' and the function that fills it. See the note on
   ;; `add-minor-mode' for why the alist lives here and not with the mode
   ;; line that reads it.
   *minor-mode-alist* *minor-mode-list* *minor-mode-map-alist* add-minor-mode
   regexp-unmatchable
   string-prefix-p
   string-replace
   ctl-x-4-map
   ;; The key event model. `char-alt' and the five beside it are the C's
   ;; `CHAR_*'; the rest are `subr.el''s two decomposition functions,
   ;; `keyboard.c''s way back, and the three C functions that way back
   ;; rests on.
   char-alt char-super char-hyper char-shift char-ctl char-meta
   parse-solitary-modifier make-ctrl-char
   parse-modifiers-uncached event-symbol-elements
   event-modifiers event-basic-type apply-modifiers event-convert-list
   run-hook-with-args
   run-hook-with-args-until-success
   *after-change-major-mode-hook*
   *change-major-mode-after-body-hook*
   *delayed-after-hook-functions*
   *delayed-mode-hooks*
   *delay-mode-hooks*
   delay-mode-hooks
   ignore
   run-hooks
   run-mode-hooks
   apply-partially
   kbd
   with-silent-modifications
   nthcdr
   ;; `nth' and the `posn-' cluster - see the note on them below.
   nth event-start event-end
   posn-window posn-area posn-point posn-x-y
   )

  (begin

    (define regexp-unmatchable "\\`a\\`")
    ;; ^ GNU Emacs's `regexp-unmatchable' (subr.el:7794): "Standard regexp
    ;; guaranteed not to match any string at all." Two beginning-of-buffer
    ;; anchors, which cannot both hold.

    (define (string-prefix-p prefix string . rest)
      ;; GNU Emacs's `string-prefix-p' (subr.el:6246): "Return non-nil if
      ;; STRING begins with PREFIX. PREFIX should be a string; the
      ;; function returns non-nil if the characters at the beginning of
      ;; STRING compare equal with PREFIX. If IGNORE-CASE is non-nil, the
      ;; comparison is done without paying attention to letter-case
      ;; differences."
      ;;
      ;; The answer is the C's `(eq t (compare-strings ...))' - against
      ;; the symbol `t', not against a true value: `compare-strings'
      ;; answers the index of the first difference when they differ, so
      ;; `eq t' is the whole test.
      ;;
      ;; `string-length' and not `length': Emacs's `length' takes a
      ;; string and Guile's does not.
      ;;--------------------------------------------------------------
      (let ((ignore-case (and (pair? rest) (car rest)))
            (prefix-length (string-length prefix)))
        (if (> prefix-length (string-length string))
            #f
            (eq? #t (compare-strings prefix 0 prefix-length
                                     string 0 prefix-length
                                     ignore-case)))))

    (define (string-replace from-string to-string in-string)
      ;; GNU Emacs's `string-replace' (subr.el:6157): "Replace FROM-STRING
      ;; with TO-STRING in IN-STRING each time it occurs."
      ;;
      ;; The C searches with `string-search', which is `string-contains'
      ;; here and answers an index rather than the C's position or nil -
      ;; the two are the same question. An empty FROM-STRING is the C's
      ;; `wrong-length-argument', which is an error here too.
      ;;--------------------------------------------------------------
      (when (string=? from-string "")
        (error "Wrong length argument: 0"))
      (let loop ((start 0) (result '()))
        (let ((pos (string-contains in-string from-string start)))
          (cond
           ((not pos)
            ;; "No replacements were done, so just return the original
            ;; string" - the C's answer when RESULT is still nil
            (if (null? result)
                in-string
                (begin
                  (unless (= start (string-length in-string))
                    (set! result (cons (substring in-string start) result)))
                  (apply string-append (reverse result)))))
           (else
            (loop (+ pos (string-length from-string))
                  (cons to-string
                        (if (= start pos)
                            result
                            (cons (substring in-string start pos) result)))))))))




    ;;----------------------------------------------------------------
    ;; The string and list helpers, and the temp buffer
    ;;
    ;; These are `subr.el`'s under their Emacs names. Where Guile has a
    ;; function with the same object it is called rather than copied:
    ;; `intern` is `string->symbol` (this tree has no obarray, which is
    ;; the second argument's purpose), and `concat` is used to rebuild a
    ;; string so that text properties survive as they do in the C.
    ;;------------------------------------------------------------------

    (define (%subr-opt args n default)
      (let loop ((rest args) (k n))
        (cond ((null? rest) default)
              ((= k 0) (car rest))
              (else (loop (cdr rest) (- k 1))))))

    (define *split-string-default-separators*
      ;; `subr.el`'s `split-string-default-separators`, "[ \f\t\n\r\v]+" -
      ;; written as the characters themselves, because a regexp engine's
      ;; opinion of `\f` and `\v` is not the string's.
      (string-append "[" (string (integer->char 32) (integer->char 12)
                                 (integer->char 9) (integer->char 10)
                                 (integer->char 13) (integer->char 11))
                     "]+"))

    (define (split-string string . args)
      ;; GNU Emacs's `split-string` (`subr.el`): "Split STRING into
      ;; substrings bounded by matches for SEPARATORS." The beginning and
      ;; end of STRING and each match are split points; a match that
      ;; leaves nothing between the last split and this one is dropped
      ;; unless OMIT-EMPTY is nil, and with no SEPARATORS the whitespace
      ;; default forces OMIT-EMPTY.
      ;;--------------------------------------------------------------
      (let* ((separators (%subr-opt args 0 #f))
             (omit-empty (%subr-opt args 1 #f))
             (trim (%subr-opt args 2 #f))
             (keep-empty (and separators (not omit-empty)))
             (len (string-length string))
             (trim-left-re (and trim (string-append "\\`\\(?:" trim "\\)")))
             (trim-right-re (and trim (string-append "\\(?:" trim "\\)\\'")))
             (sep-re (or separators *split-string-default-separators*)))
        (save-match-data
          (let loop ((next 0) (start 0) (acc '()))
            (let ((sep (string-match sep-re string next)))
              (if (and sep
                       (let ((sep-end (match-end 0)))
                         (when (or keep-empty (< start sep))
                           (let ((item (substring string start sep)))
                             (if trim
                                 (let* ((item-beg
                                         (if (string-match trim-left-re item 0)
                                             (match-end 0)
                                             0))
                                        (item-len (string-length item))
                                        (item-end
                                         (or (string-match-p trim-right-re item
                                                             item-beg)
                                             item-len)))
                                   (when (or (> item-beg 0)
                                             (< item-end item-len))
                                     (set! item (substring item item-beg
                                                           item-end)))
                                   (when (or keep-empty (< item-beg item-end))
                                     (set! acc (cons item acc))))
                                 (set! acc (cons item acc)))))
                         (set! next (max (+ 1 next) sep-end))
                         (set! start sep-end)
                         (< start len)))
                  (loop next start acc)
                  (let ((item (if (= start 0) string (substring string start))))
                    (when trim
                      (let* ((item-beg
                              (if (string-match trim-left-re item 0)
                                  (match-end 0)
                                  0))
                             (item-len (string-length item))
                             (item-end
                              (or (string-match-p trim-right-re item item-beg)
                                  item-len)))
                        (when (or (> item-beg 0) (< item-end item-len))
                          (set! item (substring item item-beg item-end)))))
                    (if (or keep-empty (not (string=? item "")))
                        (reverse (cons item acc))
                        (reverse acc)))))))))

    (define (replace-regexp-in-string regexp rep string . args)
      ;; GNU Emacs's `replace-regexp-in-string` (`subr.el`): "Replace all
      ;; matches for REGEXP with REP in STRING." REP is a replacement
      ;; string for `replace-match` or a function of the matched text.
      ;; The walk builds the answer reversed and joins it with `concat`,
      ;; which is how the C keeps text properties; `matched empty string`
      ;; advances one character so a zero-width regexp terminates.
      ;;--------------------------------------------------------------
      (let ((fixedcase (%subr-opt args 0 #f))
            (literal (%subr-opt args 1 #f))
            (subexp (%subr-opt args 2 #f))
            (start (or (%subr-opt args 3 #f) 0))
            (l (string-length string)))
        (save-match-data
          (let loop ((start start) (matches '()))
            (if (and (< start l) (string-match regexp string start))
                (let* ((mb (match-beginning 0))
                       (me (match-end 0))
                       (me (if (= me mb) (min l (+ mb 1)) me)))
                  (match-data--translate (- mb))
                  (let* ((str (substring string mb me))
                         (replacement
                          (replace-match
                           (if (string? rep) rep (rep (match-string 0 str)))
                           fixedcase literal str subexp)))
                    (loop me (cons replacement
                                   (cons (substring string start mb)
                                         matches)))))
                (apply concat
                       (reverse (cons (substring string start l) matches))))))))

    (define (string-trim-left string . args)
      ;; GNU Emacs's `string-trim-left` (`subr.el:7745`): "Trim STRING of
      ;; leading string matching REGEXP." REGEXP defaults to
      ;; "[ \t\n\r]+", anchored to the string's beginning.
      ;;--------------------------------------------------------------
      (let ((regexp (%subr-opt args 0 #f)))
        (if (string-match (if regexp
                              (string-append "\\`\\(?:" regexp "\\)")
                              "\\`[ \t\n\r]+")
                          string)
            (substring string (match-end 0))
            string)))

    (define (string-trim-right string . args)
      ;; GNU Emacs's `string-trim-right` (`subr.el:7757`): "Trim STRING
      ;; of trailing string matching REGEXP." Anchored at the end, and
      ;; `string-match-p` so the match data is left alone.
      ;;--------------------------------------------------------------
      (let* ((regexp (%subr-opt args 0 #f))
             (i (string-match-p (if regexp
                                    (string-append "\\(?:" regexp "\\)\\'")
                                    "[ \t\n\r]+\\'")
                                string)))
        (if i (substring string 0 i) string)))

    (define (string-trim string . args)
      ;; GNU Emacs's `string-trim` (`subr.el:7768`): "Trim STRING of
      ;; leading and trailing strings matching TRIM-LEFT and TRIM-RIGHT."
      ;;--------------------------------------------------------------
      (let* ((trim-left (%subr-opt args 0 #f))
             (trim-right (%subr-opt args 1 #f))
             (beg (and (string-match
                        (if trim-left
                            (string-append "\\`\\(?:" trim-left "\\)")
                            "\\`[ \t\n\r]+")
                        string)
                       (match-end 0)))
             (end (string-match-p
                   (if trim-right
                       (string-append "\\(?:" trim-right "\\)\\'")
                       "[ \t\n\r]+\\'")
                   string beg)))
        (if (or beg end)
            ;; Emacs's `substring' treats a nil START as 0
            ;; (`validate_substring_args'), and BEG is nil whenever the
            ;; leading trim did not match. Guile's `substring' has no
            ;; such rule, so the nil is resolved here.
            (substring string (or beg 0) (or end (string-length string)))
            string)))

    (define (shell-quote-argument argument . args)
      ;; GNU Emacs's `shell-quote-argument` (`subr.el`): "Quote ARGUMENT
      ;; for passing as argument to an inferior shell." **The POSIX arm
      ;; only**: the MS-DOS and Windows arms are selected by `system-type`
      ;; values this tree cannot have, and it is 'gnu/linux (see
      ;; `startup.sld`). The replacement prefixes every character that is
      ;; not a POSIX filename character with a backslash, and a newline
      ;; is quoted in single quotes so the whole argument stays one word.
      ;;--------------------------------------------------------------
      (if (string=? argument "")
          "''"
          (string-replace
           (string #\newline)
           (string #\' #\newline #\')
           (replace-regexp-in-string
            "[^-0-9a-zA-Z_./\n]"
            ;; `\` then `\&` - a literal backslash followed by the whole
            ;; match, which is the replacement `replace-match` reads from
            ;; Emacs's `"\\\\\\&"`.
            (string (integer->char 92) (integer->char 92)
                    (integer->char 92) #\&)
            argument))))

    (define (add-to-list list-var element . args)
      ;; GNU Emacs's `add-to-list` (`subr.el`): "Add ELEMENT to the value
      ;; of LIST-VAR if it isn't there yet."
      ;;
      ;; **LIST-VAR is the *parameter* and not its name.** A Scheme
      ;; binding has no `symbol-value`/`set`, so the two halves Emacs
      ;; reaches through the symbol are the parameter's read and its
      ;; call - the tree's convention for what Elisp does with `set`.
      ;;--------------------------------------------------------------
      (let* ((append? (%subr-opt args 0 #f))
             (compare-fn (or (%subr-opt args 1 #f) equal?))
             (value (list-var)))
        (if (let loop ((rest value))
              (cond ((null? rest) #f)
                    ((compare-fn element (car rest)) #t)
                    (else (loop (cdr rest)))))
            value
            (list-var (if append?
                          (append value (list element))
                          (cons element value))))))

    (define (intern name . args)
      ;; GNU Emacs's `intern` (`print.c`): "Return the canonical symbol
      ;; whose name is STRING." Emacs's second argument names the obarray
      ;; to intern in; this tree has no obarray and one namespace, so the
      ;; answer is `string->symbol` - the same symbol for the same name.
      ;;--------------------------------------------------------------
      (string->symbol name))

    (define (error-message-string err)
      ;; GNU Emacs's `error-message-string` (`print.c:1037`): "Return a
      ;; string describing an error." A Guile condition carries a *format
      ;; template* and its values in the irritants, so the two are put
      ;; back together here the way `schemacs/main.scm`'s
      ;; `condition-text` and the command loop's reporter do it.
      ;;--------------------------------------------------------------
      (let ((message (catch #t
                       (lambda () (%condition-message err))
                       (lambda a #f)))
            (irritants (catch #t
                         (lambda () (error-object-irritants err))
                         (lambda a '()))))
        (cond
         ((not (string? message)) (format #f "~a" err))
         ((and (pair? irritants) (string-index message #\~))
          (catch #t
            (lambda () (apply format #f message irritants))
            (lambda a message)))
         (else message))))

    (define (%condition-message err)
      ;; `error-object-message` when the condition is an error object,
      ;; and `exception-message` otherwise - the two Guile spellings.
      (if (error-object? err)
          (error-object-message err)
          (exception-message err)))

    (define-syntax with-temp-buffer
      ;; GNU Emacs's `with-temp-buffer` (`subr.el`): "Create a temporary
      ;; buffer, and evaluate BODY there like `progn'." The buffer is
      ;; made with `generate-new-buffer` and killed afterwards whatever
      ;; BODY does - `dynamic-wind` is the `unwind-protect`.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ body ...)
         (let ((temp-buffer (generate-new-buffer " *temp*")))
           ;; `kill-buffer` can change current-buffer in some odd cases.
           (with-current-buffer temp-buffer
             (dynamic-wind
               (lambda () #t)
               (lambda () body ...)
               (lambda ()
                 (and (buffer-name temp-buffer)
                      (%kill-buffer temp-buffer)))))))))

    ;;------------------------------------------------------------------
    ;; Minor modes
    ;;------------------------------------------------------------------

    (define *minor-mode-list* (make-parameter '()))
    ;; ^ GNU Emacs's `minor-mode-list' (`bindings.el`): "List of
    ;; variables of minor modes. Each element is a variable symbol, whose
    ;; value is t when the minor mode is enabled." The list is not read
    ;; by anything here yet; `add-minor-mode' keeps it because it is one
    ;; of the three things that function maintains.

    (define *minor-mode-alist* (make-parameter (list (list 'overwrite-mode 'overwrite-mode))))
    ;; ^ GNU Emacs's `minor-mode-alist' (`bindings.el:976'): "Alist
    ;; saying how to show minor modes in the mode line. Each element
    ;; looks like (VARIABLE STRING); STRING is included in the mode line
    ;; if VARIABLE's value is non-nil. ... Actually, STRING need not be a
    ;; string; any mode-line construct is okay."
    ;;
    ;; The initial value is bindings.el's own list, of which only the
    ;; `overwrite-mode' entry is carried - `abbrev-mode',
    ;; `auto-fill-function' and `defining-kbd-macro' are not ported.
    ;;
    ;; **Placement, a departure.** Emacs declares this in `bindings.el',
    ;; and this tree declares the other mode-line variables there too
    ;; (`*mode-line-format*' is in `xdisp.sld'). The alist is here
    ;; instead, beside the one function that writes it, because of the
    ;; import graph: `xdisp.sld' imports `simple.sld', which imports this
    ;; library, so an alist that `simple.sld' had to reach could not live
    ;; in `xdisp.sld' - and `define-minor-mode', which is expanded in
    ;; libraries at and below `simple.sld', generates a call to
    ;; `add-minor-mode'.
    ;;
    ;; `overwrite-mode`'s indicator is the *symbol* of the same name and
    ;; not a string, which is the "need not be a string" clause doing
    ;; real work: the construct is evaluated, so what is shown is the
    ;; variable's value - `overwrite-mode-textual` or
    ;; `overwrite-mode-binary` - and then *that* symbol's value, which is
    ;; the string. The mode line does both steps.

    (define *minor-mode-map-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `minor-mode-map-alist' (`keymap.c', `Vminor_mode_map_alist'):
    ;; "Alist of keymaps to use for minor modes. Each element looks like
    ;; (VARIABLE . KEYMAP); KEYMAP is used if VARIABLE's value is non-nil."
    ;;
    ;; **It is read before the buffer's own map**, as `current_active_maps'
    ;; (`keymap.c:...)` places it: a minor mode's key shadows the buffer's,
    ;; and an entry added later shadows one added earlier. `keyboard.sld''s
    ;; `lookup-keymaps' is where it is consulted.
    ;;
    ;; A variable is buffer-local in this tree - `define-minor-mode'
    ;; writes it with `set-buffer-local-value!' - so "is this mode on in
    ;; this buffer" is `buffer-local-value', which is what the lookup does.

    (define (add-minor-mode toggle name . rest)
      ;; GNU Emacs's `add-minor-mode' (`subr.el:3201'): "Register a new
      ;; minor mode. ... TOGGLE is a symbol that is the name of a
      ;; buffer-local variable that is toggled on or off to say whether
      ;; the minor mode is active or not. NAME specifies what will appear
      ;; in the mode line when the minor mode is active. NAME should be
      ;; either a string starting with a space, or a symbol whose value
      ;; is such a string."
      ;;
      ;; "This function shouldn't be used directly -- use
      ;; `define-minor-mode' instead (which will then call this
      ;; function)."
      ;;
      ;; What it maintains: the list above, and the alist entry. A NAME
      ;; of nil adds nothing to the alist - the entry it would add is
      ;; already there, which is how `overwrite-mode' gets its lighter
      ;; from bindings.el rather than from its own definition.
      ;;
      ;; The two lists it maintains: the mode line's (`minor-mode-alist')
      ;; and the key lookup's (`minor-mode-map-alist'). A NAME of nil adds
      ;; nothing to the first - the entry it would add is already there,
      ;; which is how `overwrite-mode' gets its lighter from bindings.el
      ;; rather than from its own definition.
      ;;
      ;; **KEYMAP is the third argument** and is registered when it is
      ;; non-nil, as `subr.el''s `(when keymap ... (push (cons toggle map)
      ;; minor-mode-map-alist))' does. It was named as not carried until
      ;; 2026-11-07, which is why no minor mode here had keys of its own.
      ;;
      ;; Not carried: the `:included'/`:menu-tag' menu entry, which needs
      ;; a symbol plist and the mode-line menu.
      ;;--------------------------------------------------------------
      (let ((keymap (if (pair? rest) (car rest) #f))
            (after (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
            (toggle-fun (if (and (pair? rest) (pair? (cdr rest))
                                 (pair? (cddr rest)))
                            (car (cddr rest))
                            #f)))
        (unless (memq toggle (*minor-mode-list*))
          (*minor-mode-list* (cons toggle (*minor-mode-list*))))
        (when name
          (let ((alist (*minor-mode-alist*)))
            (let ((existing (assq toggle alist)))
              (if existing
                  (set-cdr! existing (list name))
                  (*minor-mode-alist*
                   (cons (list toggle name) alist))))))
        ;; "KEYMAP is used if VARIABLE's value is non-nil": the entry is
        ;; `(TOGGLE . KEYMAP)', and a KEYMAP that is itself a list of maps
        ;; is registered as its first, which is `subr.el''s `(if (consp
        ;; keymap) (car keymap) keymap)'.
        (when keymap
          (let ((map (if (pair? keymap) (car keymap) keymap)))
            (*minor-mode-map-alist*
             (cons (cons toggle map) (*minor-mode-map-alist*)))))
        keymap after toggle-fun
        #f))

    (define (run-hooks . hooks)
      ;; GNU Emacs's `run-hooks' (subr.el): run each hook in turn. A hook
      ;; is named by a *variable* in Emacs and read by this; here a hook
      ;; is the list of procedures itself - the tree keeps one as a
      ;; `make-parameter' holding a list - so the list is what is passed.
      ;; An argument that is a procedure rather than a list is a single
      ;; function, which is what `run-hooks' does with a non-list value.
      ;;--------------------------------------------------------------
      (for-each (lambda (hook)
                  (cond ((not hook) #f)
                        ((procedure? hook) (hook))
                        (else (for-each (lambda (f) (f)) hook))))
                hooks))

    (define (run-hook-with-args hook . args)
      ;; GNU Emacs's `run-hook-with-args' (`eval.c:2908'): "Run HOOK with
      ;; the specified arguments ARGS. ... Call each function in order
      ;; with arguments ARGS. The final return value is unspecified."
      ;;
      ;; The C is `run_hook_with_args (nargs, args, funcall_nil)'
      ;; (`:2921') - the same walk as the `-until-success' form below,
      ;; with a handler that always answers nil, so every function runs
      ;; and no answer is used. HOOK is the list of procedures rather than
      ;; a symbol naming one, for `run-hooks'' reason.
      ;;--------------------------------------------------------------
      (let loop ((rest (cond ((not hook) '())
                             ((procedure? hook) (list hook))
                             (else hook))))
        (cond ((null? rest) #f)
              (else
               (apply (car rest) args)
               (loop (cdr rest))))))

    (define (run-hook-with-args-until-success hook . args)
      ;; GNU Emacs's `run-hook-with-args-until-success' (`eval.c:2927'):
      ;; "Run HOOK with the specified arguments ARGS. ... Call each
      ;; function in order with arguments ARGS, stopping at the first one
      ;; that returns non-nil, and return that value. Otherwise (if all
      ;; functions return nil, or if there are no functions to call),
      ;; return nil."
      ;;
      ;; HOOK is the list of procedures rather than a symbol naming one,
      ;; as `run-hooks' above takes it, and for the same reason: a hook is
      ;; a parameter here, so its value is what is to hand.
      ;;
      ;; The C's `t' marker in a hook's value - "this hook has a local
      ;; binding; it means to run the global binding too" - is not here.
      ;; A buffer-local half of a hook is not ported, so a hook's value is
      ;; the whole value.
      ;;--------------------------------------------------------------
      (let loop ((rest (cond ((not hook) '())
                             ((procedure? hook) (list hook))
                             (else hook))))
        (cond ((null? rest) #f)
              (else
               (let ((value (apply (car rest) args)))
                 (if value value (loop (cdr rest))))))))

    (define *change-major-mode-after-body-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `change-major-mode-after-body-hook' (`subr.el'):
    ;; "Normal hook run after running the body of `define-derived-mode'."

    (define *after-change-major-mode-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `after-change-major-mode-hook' (`subr.el'): "Normal
    ;; hook run at the end of `run-mode-hooks', which see. ... every
    ;; major mode runs it, whether it is defined with `define-derived-mode'
    ;; or not."

    (define *delay-mode-hooks* (make-parameter #f))
    ;; ^ GNU Emacs's `delay-mode-hooks' (`subr.el'): "Non-nil means
    ;; `run-mode-hooks' should delay running the hooks." A buffer-local
    ;; variable in Emacs and a parameter here, as this tree keeps
    ;; buffer-local flags.

    (define *delayed-mode-hooks* (make-parameter '()))
    ;; ^ GNU Emacs's `delayed-mode-hooks': the hooks a mode asked for
    ;; while the running was delayed, newest first.

    (define *delayed-after-hook-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `delayed-after-hook-functions': what a derived
    ;; mode's `:after-hook' pushed, run at the very end of
    ;; `run-mode-hooks'.

    (define (delay-mode-hooks thunk)
      ;; GNU Emacs's `delay-mode-hooks' (`subr.el':2795): "Execute BODY,
      ;; but delay any `run-mode-hooks'. These hooks will be executed by
      ;; the first following call to `run-mode-hooks' that occurs outside
      ;; any `delay-mode-hooks' form."
      ;;
      ;; A macro in Emacs; a procedure taking the body as a thunk here,
      ;; which is how this tree spells a body-taking form that has no
      ;; syntax of its own to keep.
      ;;--------------------------------------------------------------
      (parameterize ((*delay-mode-hooks* #t)) (thunk)))

    (define (run-mode-hooks . hooks)
      ;; GNU Emacs's `run-mode-hooks' (subr.el:2756): "Run mode hooks
      ;; `delayed-mode-hooks' and HOOKS, or delay HOOKS. ... Otherwise,
      ;; runs hooks in the sequence: `change-major-mode-after-body-hook',
      ;; `delayed-mode-hooks' (in reverse order), HOOKS, then runs
      ;; `hack-local-variables' (if the buffer is visiting a file), runs
      ;; the hook `after-change-major-mode-hook', and finally evaluates
      ;; the functions in `delayed-after-hook-functions'."
      ;;
      ;; Not ported: `hack-local-variables', there being no file-local
      ;; variable machinery here yet. The C's other errand in that gap -
      ;; turning on `parse-sexp-lookup-properties' when
      ;; `syntax-propertize-function' is set - waits for
      ;; `syntax-propertize' too.
      ;;--------------------------------------------------------------
      (if (*delay-mode-hooks*)
          ;; "just adds the HOOKS to the list"
          (*delayed-mode-hooks* (append hooks (*delayed-mode-hooks*)))
          (begin
            (set! hooks (append (reverse (*delayed-mode-hooks*)) hooks))
            (*delayed-mode-hooks* '())
            (apply run-hooks
                   (cons (*change-major-mode-after-body-hook*) hooks))
            (run-hooks (*after-change-major-mode-hook*))
            (let ((after (reverse (*delayed-after-hook-functions*))))
              (*delayed-after-hook-functions* '())
              (for-each (lambda (f) (f)) after)))))

    (define-syntax with-silent-modifications
      ;; GNU Emacs's `with-silent-modifications' (`subr.el:5473'):
      ;; "Execute BODY, pretending it does not modify the buffer. This
      ;; macro is typically used around modifications of text properties
      ;; that do not really affect the buffer's content. ... This macro
      ;; will run BODY normally, but doesn't count its buffer
      ;; modifications as being buffer modifications. This affects things
      ;; like `buffer-modified-p', checking whether the file is locked by
      ;; someone else, running buffer modification hooks, and other things
      ;; of that nature."
      ;;
      ;; The C's body is a `let*' of four bindings around an
      ;; `unwind-protect':
      ;;
      ;;     (let* ((modified (buffer-modified-p))
      ;;            (buffer-undo-list t)
      ;;            (inhibit-read-only t)
      ;;            (inhibit-modification-hooks t))
      ;;       (unwind-protect (progn ,@body)
      ;;         (when (memq modified '(nil autosaved))
      ;;           (restore-buffer-modified-p modified))))
      ;;
      ;; **`inhibit-read-only' is the binding that earns this macro its
      ;; keep**, and it is the one that is easy to miss. Font-lock
      ;; fontifies a *read-only* buffer - dired's, `*Completions*', any
      ;; `special-mode' buffer - and `put-text-property' on a read-only
      ;; buffer signals `buffer-read-only', as it does in Emacs
      ;; (measured). Emacs's answer is this binding, and `font-lock.el'
      ;; has it at `:1044' and `:1196'; before the property section
      ;; below was made faithful, a property write here did not consult
      ;; the read-only flag at all, and this tree's `font-lock' said in
      ;; its header that this macro was not needed. It was needed all
      ;; along, and the note is corrected there.
      ;;
      ;; `buffer-undo-list' bound to `t' is Emacs's "do not record"
      ;; value; this tree's spelling of the same state is false - that is
      ;; what `text-editor-undo-disable!' writes - so the binding is `#f'
      ;; and the saved value is put back on the way out, which the C's
      ;; `let' does too.
      ;;
      ;; **`inhibit-modification-hooks' is not carried**, there being no
      ;; such switch here; it is what stops the change hooks running, and
      ;; nothing in this tree reads it. With it, `signal-before-change'
      ;; and `signal-after-change' still run inside BODY here where Emacs
      ;; suppresses them. Named, not faked.
      ;;
      ;; `autosaved' - the third value Emacs 31's `buffer-modified-p' can
      ;; answer - has no counterpart: this tree's is true or false.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((with-silent-modifications body ...)
         (let ((buffer (current-buffer)))
           (let ((modified (buffer-modified-p buffer))
                 (undo-list (text-editor-undo-list buffer)))
             (parameterize ((*inhibit-read-only* #t))
               (dynamic-wind
                 ;; `(let ((buffer-undo-list t)) ...)' - Emacs's `t', which
                 ;; is `#t' here and not `#f' (see `buffer.scm`'s note on
                 ;; the slot).
                 (lambda () (set!text-editor-undo-list buffer #t))
                 (lambda () body ...)
                 (lambda ()
                   (set!text-editor-undo-list buffer undo-list)
                   (unless modified
                     (restore-buffer-modified-p #f))))))))))

    (define (apply-partially function . args)
      ;; GNU Emacs's `apply-partially' (`subr.el:129'): "Return a function
      ;; that is a partial application of FUN to ARGS. ARGS is a list of
      ;; the first N arguments to pass to FUN. The result is a new
      ;; function which does the same as FUN, except that the first N
      ;; arguments are fixed at the values with which this function was
      ;; called."
      ;;
      ;; `read-buffer-to-switch' reaches it the way Emacs does:
      ;; `internal-complete-buffer-except' returns a *completion table*,
      ;; and Emacs builds that table with this over
      ;; `completion-table-with-predicate' - the arguments it fixes are
      ;; the table, the predicate and STRICT, and what is left to be given
      ;; is what a table is called with, `(STRING PREDICATE ACTION)'.
      ;;--------------------------------------------------------------
      (lambda args1 (apply function (append args args1))))

    (define (ignore . _arguments)
      ;; GNU Emacs's `ignore' (`subr.el:501'): accept any arguments, do
      ;; nothing, and answer nil. It is what Emacs binds keys that must be
      ;; received but not acted on to - `[sigusr1]' in
      ;; `special-event-map' - and it is what this tree's resize event is
      ;; bound to: a frame resize is handled by redisplay re-framing, and
      ;; the event only has to be dispatched for the loop to redraw.
      ;;
      ;; Emacs answers nil here, which this tree's `#f' is - and writing
      ;; the word `nil' was an error, not a spelling, and is what the
      ;; "unbound variable: nil" the echo area showed was.
      ;;--------------------------------------------------------------
      #f)

    (define (assoc-delete-all key alist . rest)
      ;; GNU Emacs's `assoc-delete-all' (`subr.el:1066'): "Delete from
      ;; ALIST all elements whose car is KEY. Compare keys with TEST.
      ;; Defaults to `equal'. Return the modified alist." The C's walk is
      ;; destructive: `setcdr' unlinks each match from the element before
      ;; it, and the head matches are skipped by advancing the start.
      ;;--------------------------------------------------------------
      (let ((test (if (and (pair? rest) (car rest)) (car rest) equal?)))
        ;; Emacs's `while' skips the head matches by rebinding ALIST,
        ;; which is the list everything below then walks - which is why
        ;; this is a `let*' and not a `let': the splice and the answer
        ;; both see the advanced list. A first version that skipped with
        ;; a discarded `(skip ...)' walked the original and never
        ;; unlinked anything.
        (let* ((alist (let skip ((rest alist))
                        (if (and (pair? rest) (test (car (car rest)) key))
                            (skip (cdr rest))
                            rest))))
          ;; The splice is guarded on `pair?' and not on truth: the cdr
          ;; of the last pair is '(), and '() is true in Scheme - the
          ;; elisp-nil trap. It is also guarded at the head, because the
          ;; skip can leave an empty list - every element matched - and
          ;; the C's `while (setq tail-cdr (cdr tail))' never runs there.
          (when (pair? alist)
            (let splice ((tail alist))
              (let ((next (cdr tail)))
                (when (pair? next)
                  (if (and (pair? (car next)) (test (car (car next)) key))
                      (set-cdr! tail (cdr next))
                      (splice next))))))
        ;; the answer is the let*-bound ALIST, which is why this form
        ;; is the let*'s body and not a form after it.
        alist)))

    (define (delq elt list)
      ;; GNU Emacs's `delq' (`fns.c:2081'): "Delete members of LIST which
      ;; are `eq' to ELT, and return the result. More precisely, this
      ;; function skips any members `eq' to ELT at the front of LIST,
      ;; then removes members `eq' to ELT from the remaining sublist by
      ;; modifying its list structure, then returns the resulting list."
      ;; The shape is `assoc-delete-all''s, with the elements themselves
      ;; in place of their cars; the same two guards apply.
      ;;--------------------------------------------------------------
      (let* ((list (let skip ((rest list))
                     (if (and (pair? rest) (eq? (car rest) elt))
                         (skip (cdr rest))
                         rest))))
        (when (pair? list)
          (let splice ((prev list) (tail (cdr list)))
            (when (pair? tail)
              (if (eq? (car tail) elt)
                  (begin
                    (set-cdr! prev (cdr tail))
                    (splice prev (cdr tail)))
                  (splice tail (cdr tail))))))
        list))

    (define (assq-delete-all key alist)
      ;; GNU Emacs's `assq-delete-all' (`subr.el:1084'): "Delete from
      ;; ALIST all elements whose car is `eq' to KEY" - `assoc-delete-all'
      ;; with the test `eq'.
      ;;--------------------------------------------------------------
      (assoc-delete-all key alist eq?))

    (define (nthcdr n list)
      ;; GNU Emacs's `nthcdr': the tail of LIST after the first N
      ;; elements - and nil when the list is shorter than that, which is
      ;; the whole point of having it: Scheme's `list-tail' is an error
      ;; there, and Elisp's sloppiness is what the callers rely on.
      ;;--------------------------------------------------------------
      (let loop ((n n) (rest list))
        (if (or (<= n 0) (not (pair? rest)))
            rest
            (loop (- n 1) (cdr rest)))))

    (define (add-to-history history-list newelt . args)
      ;; GNU Emacs's `add-to-history': HISTORY-LIST with NEWELT on the
      ;; front, duplicates of it removed when
      ;; `history-delete-duplicates' says so, and the list cut back to
      ;; MAXELT - which answers with `history-length' when the caller
      ;; does not give one.
      ;;
      ;; It takes the list and answers a new one, rather than taking a
      ;; variable's name as Emacs's does: a Scheme procedure cannot set a
      ;; variable the caller names, so the setting is the caller's.
      ;;--------------------------------------------------------------
      (let* ((maxelt (if (pair? args) (car args) #f))
             (keep-all (if (and (pair? args) (pair? (cdr args)))
                           (cadr args)
                           #f))
             (maxelt (or maxelt (*history-length*))))
        (if (and (list? history-list)
                 (or keep-all
                     (not (string? newelt))
                     (< 0 (string-length newelt)))
                 ;; Elisp's `(car nil)' is nil, so Emacs's test is
                 ;; true for an empty list; Scheme's is an error, so
                 ;; the emptiness is tested for.
                 (or keep-all
                     (not (and (pair? history-list)
                               (equal? (car history-list) newelt)))))
            (let* ((history (if (*history-delete-duplicates*)
                                (delete newelt history-list)
                                history-list))
                   (history (cons newelt history)))
              (cond
               ((not (integer? maxelt)) history)
               ((<= maxelt 0) '())
               (else
                (let ((tail (nthcdr (- maxelt 1) history)))
                  (if (pair? tail) (set-cdr! tail '()))
                  history))))
            history-list)))

    (define (nth n list)
      ;; GNU Emacs's `nth': the Nth element of LIST, or nil - this tree's
      ;; #f - when the list is shorter than that. Built on `nthcdr'
      ;; above, which is the half that exists in a Scheme without
      ;; Elisp's tolerance for running off the end.
      ;;--------------------------------------------------------------
      (let ((tail (nthcdr n list)))
        (and (pair? tail) (car tail))))

    ;;----------------------------------------------------------------
    ;; Positions: the value a mouse event carries
    ;;
    ;; `subr.el''s `posn-' cluster, which is what a command bound to a
    ;; mouse event reads. A mouse event's value is
    ;;
    ;;   (SYMBOL (WINDOW POS-OR-AREA (X . Y) TIMESTAMP))
    ;;
    ;; - SYMBOL is `down-mouse-1' for the press and `mouse-1' for the
    ;; click that follows it - and everything below is a walk of that
    ;; list, as `subr.el''s are.
    ;;
    ;; **`posn-set-point' is not here**, though `subr.el' is where Emacs
    ;; keeps it, for a reason this tree has and Emacs does not: it needs
    ;; `select-window' and `goto-char', and `(schemacs editor frame)'
    ;; imports *this* library, so a definition here could not reach
    ;; them. It lives in `mouse.sld', with the commands that call it.
    ;;------------------------------------------------------------------

    (define (event-start event)
      ;; GNU Emacs's `event-start': where EVENT begins.
      ;;
      ;; Emacs's differs from `event-end' only after a drag, and asks
      ;; `posn-at-point' when handed nil; this asks nothing and answers
      ;; #f for something that is not an event at all, which is the
      ;; shape every caller in this tree wants.
      ;;--------------------------------------------------------------
      (and (pair? event) (nth 1 event)))

    (define (event-end event)
      ;; GNU Emacs's `event-end' (`subr.el:1952'): "Return the ending
      ;; position of EVENT. EVENT should be a click, drag, or key press
      ;; event."
      ;;
      ;; **A drag event carries two positions and a click carries one**,
      ;; which is the whole of the difference from `event-start':
      ;;
      ;;   (mouse-1      POSN)             a click
      ;;   (drag-mouse-1 START-POSN END-POSN)
      ;;
      ;; and Emacs tells them apart by asking whether the *third*
      ;; element is a position: `(nth (if (consp (nth 2 event)) 2 1)
      ;; event)'. A drag that ran off the end of a line and back has a
      ;; third element that is not a position, because Emacs puts the
      ;; click count there instead - `(drag-mouse-1 POSN 2)' - so the
      ;; test is what it is and not "is there a third element".
      ;;
      ;; The `posn-at-point' fallback for a nil event is not carried:
      ;; nothing here asks for the end of an event it does not have.
      ;;--------------------------------------------------------------
      (and (pair? event)
           (nth (if (pair? (nth 2 event)) 2 1) event)))

    (define (posn-window position)
      ;; GNU Emacs's `posn-window': the window the event happened in, or
      ;; the frame when it happened outside every window.
      ;;--------------------------------------------------------------
      (nth 0 position))

    (define (posn-area position)
      ;; GNU Emacs's `posn-area': the symbol naming the part of the
      ;; window - `mode-line', `vertical-border' - or nil (this tree's
      ;; #f) for the text area. The second element is a *position* in
      ;; the text area and a symbol elsewhere, which is what the cons
      ;; test is for.
      ;;--------------------------------------------------------------
      (let ((area (nth 1 position)))
        (let ((area (if (pair? area) (car area) area)))
          (and (symbol? area) area))))

    (define (posn-point position)
      ;; GNU Emacs's `posn-point' (`keyboard.c:13099'): the buffer
      ;; position of POSITION, or nil when it names no buffer location -
      ;; a click on a mode line or a scroll bar. The C answers the
      ;; position as it stands, falls back to the first element of a
      ;; cons, and gives up.
      ;;--------------------------------------------------------------
      (let ((posn (nth 1 position)))
        (cond ((integer? posn) posn)
              ((pair? posn) (car posn))
              (else #f))))

    (define (posn-x-y position)
      ;; GNU Emacs's `posn-x-y': the pixel coordinates, as a pair.
      ;;--------------------------------------------------------------
      (nth 2 position))

    (define ctl-x-4-map (keymap '*ctl-x-4-map*))
    ;; ^ GNU Emacs's `ctl-x-4-map' (`subr.el:1808'): "Keymap for
    ;; subcommands of C-x 4."
    ;;
    ;; **It is a *submap*, which is the point of it.** Emacs binds it with
    ;; `(define-key ctl-x-map "4" 'ctl-x-4-map)' - the key is `C-x 4' and
    ;; its value is the map, so the event after it is looked up inside.
    ;; This tree has no `ctl-x-map' (every `C-x' binding goes straight into
    ;; `*default-keymap*', as this tree's rule has it), so the same binding
    ;; is made against the global map.
    ;;
    ;; What goes *in* it is added where each command is, like every other
    ;; binding here: `find-file-other-window' is `files.sld''s and binds
    ;; its own `f'. Emacs fills the map in this same file with `0'
    ;; (`kill-buffer-and-window'), `C-o' (`display-buffer') and the rest,
    ;; none of which this tree has.
    (define-key *default-keymap* (kbd "C-x 4") ctl-x-4-map)

    ;;----------------------------------------------------------------
    ;; The hook runner, into the library that needs it
    ;;------------------------------------------------------------------
    (*run-hooks-function* run-hooks)

    ))
