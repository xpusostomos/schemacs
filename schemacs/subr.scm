(define-library (schemacs subr)
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
    (only (schemacs minibuf)
          *history-delete-duplicates* *history-length*)
    ;; `delete' is Guile's - R7RS has no list `delete' - and `logand' is
    ;; `key-parse''s control-character folding.
    ;; `logior' and `lognot' are the event model's bit arithmetic, beside
    ;; the `logand' `key-parse' already folds control characters with, and
    ;; `filter' orders a symbol event's modifiers.
    (only (guile) delete filter string-contains format catch string-index hashv-ref
          caddr cdddr)
    ;; a condition that is not an error object is read through these
    (only (ice-9 exceptions) exception-message)
    ;; `char-downcase' is `event-basic-type''s.
    (scheme char)
    ;; `string-prefix-p' compares with `compare-strings', which is
    ;; fns.c's and lives in `(schemacs fns)'. That library is
    ;; below this one - it imports none of subr - so this is not a
    ;; cycle.
    (only (schemacs fns)
          compare-strings concat copy-sequence nreverse nconc
          plist-get plist-put nthcdr nth delete)
    ;; The key event model and `kbd' live in `character.sld', the lowest
    ;; editor library - see its export note. They are re-exported from
    ;; here so that a library importing `(schemacs subr) kbd' still
    ;; finds it.
    (only (schemacs character)
          kbd char-alt char-super char-hyper char-shift char-ctl char-meta
          parse-solitary-modifier make-ctrl-char
          parse-modifiers-uncached event-symbol-elements
          event-modifiers event-basic-type apply-modifiers event-convert-list)
    ;; `ctl-x-4-map' below is `subr.el''s and it is a *keymap*, so this
    ;; library needs the keymap layer to build one. `(schemacs editor
    ;; keymap)' is a leaf - it imports `character' and nothing else of the
    ;; editor - so this is not a cycle.
    (only (schemacs keymap)
          keymap *default-keymap* define-key make-sparse-keymap
          store-in-keymap
          ;; `define-key-after' places a binding in the map's *order*, and
          ;; `keymap-canonicalize' walks a map and its parents - the
          ;; primitives `keymap.c` gives those two (`subr.el`'s side of
          ;; them).
          keymap-type? keymap-index keymap-lookup keymap-parent
          set-keymap-parent
          keymap-prompt keymap-order %set!keymap-order! keymap-bindings
          map-keymap)
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
    (only (schemacs chartab)
          make-char-table set-char-table-parent)
    (only (schemacs syntax)
          standard-syntax-table scan-error? scan-error-string
          skip-syntax-backward)
    (only (schemacs search)
          string-match string-match-p match-beginning match-end match-string
          replace-match match-data--translate save-match-data
          search-failed? search-failed-error
          re-search-forward re-search-backward)
    (only (schemacs insdel) *inhibit-modification-hooks*)
    ;; `natnump` is `data.c`'s and `forward-symbol` takes it from there.
    (only (schemacs data) natnump)
    ;; `forward-symbol` is an *interactive* command in Emacs (a defun
    ;; with `(interactive "^p")'), and a command here is a
    ;; `define-command`. `command.scm` reaches this library through no
    ;; path - its own import is `intervals.scm` - so the edge is not a
    ;; cycle.
    (only (schemacs command) define-command)
    (only (schemacs buffer)
          *run-hooks-function*
          ;; `with-temp-buffer` makes and kills one; `kill-buffer` is
          ;; the command and asks questions, so it is not this one.
          generate-new-buffer %kill-buffer with-current-buffer buffer-name
          ;; `with-silent-modifications` binds four of `buffer.c`'s
          ;; things, so the macro's template has to resolve them here -
          ;; and it does resolve them here: a `syntax-rules` template's
          ;; free identifiers are hygienic, meaning they name what they
          ;; name *in this library*, whatever the caller has imported.
          ;; ... and `inhibit-modification-hooks` is `insdel.c`'s, so
          ;; the template reads it from there.
          *inhibit-read-only* buffer-modified-p current-buffer
          restore-buffer-modified-p set!text-editor-undo-list
          text-editor-undo-list
          ;; `forward-symbol` reads the character at the match's start
          ;; with the raw read the C uses (`FETCH_CHAR`): `char-after`
          ;; is `editfns.scm`'s, above this library.
          fetch-char
          ;; `add-hook`'s LOCAL arm writes a hook's buffer-local value,
          ;; which is a buffer slot; and `hook-value` is its read side,
          ;; used by the runners (`run_hooks` here takes the merged
          ;; list). `subr.el` is where `add-hook` lives and it reaches
          ;; the buffer here, one library up - the same edge
          ;; `*run-hooks-function*` comes down.
          buffer-local-value local-variable-p set-buffer-local-value!)
    )

  (export
   user-error
   assoc-delete-all assq-delete-all delq remq remove copy-tree last
   butlast car-safe cdr-safe
   add-to-history add-to-list
   ;; string/list helpers `subr.el`'s, for the external packages and
   ;; anything else written in Emacs's idiom
   split-string replace-regexp-in-string shell-quote-argument
   string-trim string-trim-left string-trim-right
   intern intern-soft error-message-string
   merge-ordered-lists
   with-temp-buffer
   ;; `subr.el`'s keymap half: `define-key-after' places a binding in a
   ;; map's order, and `keymap-canonicalize' resolves inheritance for the
   ;; menu walk (`keyboard.c`'s `map_keymap_canonical' calls it).
   define-key-after keymap-canonicalize suppress-keymap
   ;; `subr.el`'s substitution walk, which `tty-menu-navigation-map`
   ;; (`menu-bar.el`) is built with: it copies a command's bindings from
   ;; the global map under new names.
   substitute-key-definition substitute-key-definition-key
   ;; the separator regexp `split-string` defaults to (`subr.el`'s
   ;; `split-string-default-separators`)
   *split-string-default-separators*
   ;; `minor-mode-alist' and the function that fills it. See the note on
   ;; `add-minor-mode' for why the alist lives here and not with the mode
   ;; line that reads it.
   *minor-mode-alist* *minor-mode-list* *minor-mode-map-alist*
   y-or-n-p-use-read-key y-or-n-p-history-variable
   *global-minor-modes* add-minor-mode
   regexp-unmatchable
   string-prefix-p
   make-syntax-table
   string-to-list
   minusp forward-symbol
   string-suffix-p string-equal-ignore-case member-ignore-case
   menu-bar-separator
   assoc-default
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
   run-hook-with-args-until-failure
   *after-change-major-mode-hook*
   *change-major-mode-after-body-hook*
   *delayed-after-hook-functions*
   *delayed-mode-hooks*
   *delay-mode-hooks*
   *use-dialog-box-override*
   delay-mode-hooks
   ignore
   run-hooks
   run-mode-hooks
   add-hook
   remove-hook
   apply-partially
   kbd
   with-silent-modifications
   nthcdr
   ;; `nth' and the `posn-' cluster - see the note on them below.
   nth event-start event-end
   posn-window posn-area posn-point posn-x-y posn-string posn-object
   ;; The seam `event-start`/`event-end` reach the point-position
   ;; fallback through (`xdisp.scm` installs it).
   *event--posn-at-point-function*
   )

  (begin

    (define regexp-unmatchable "\\`a\\`")
    ;; ^ GNU Emacs's `regexp-unmatchable' (subr.el:7794): "Standard regexp
    ;; guaranteed not to match any string at all." Two beginning-of-buffer
    ;; anchors, which cannot both hold.

    (define (make-syntax-table . rest)
      ;; GNU Emacs's `make-syntax-table' (subr.el:6555): "Return a new
      ;; syntax table. Create a syntax table that inherits from OLDTABLE
      ;; (if non-nil) or from `standard-syntax-table' otherwise."
      ;;
      ;; It is `subr.el`'s in Emacs 31 and not `syntax.c`'s, which is why
      ;; it is here - and it needs a char-table and the standard table,
      ;; both of which it imports.
      ;;--------------------------------------------------------------
      (let ((table (make-char-table 'syntax-table #f)))
        (set-char-table-parent table
                               (or (and (pair? rest) (car rest))
                                   (standard-syntax-table)))
        table))

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

    (define (string-suffix-p suffix string . rest)
      ;; GNU Emacs's `string-suffix-p' (subr.el:6262): "Return non-nil if
      ;; STRING ends with SUFFIX." The C is `string-prefix-p` the other
      ;; way round, and compares the same way - see it above.
      ;;--------------------------------------------------------------
      (let ((ignore-case (and (pair? rest) (car rest)))
            (start-pos (- (string-length string) (string-length suffix))))
        (and (>= start-pos 0)
             (eq? #t (compare-strings suffix 0 (string-length suffix)
                                      string start-pos (string-length string)
                                      ignore-case)))))

    (define menu-bar-separator '("--"))
    ;; `subr.el:7700': `(defconst menu-bar-separator '("--") "Separator
    ;; for menus.")'. **A one-element list, not `(menu-item "--")`** -
    ;; the old-style `(STRING . DEFN)' binding whose `--' caption is
    ;; what `parse_menu_item' sees as a separator. Moved here from
    ;; `menu-bar.scm', where it was written as `(menu-item "--")' from a
    ;; memory of an older Emacs; the easymenu differential caught it.

    (define (string-equal-ignore-case string1 string2)
      ;; GNU Emacs's `string-equal-ignore-case' (`subr.el:6240'):
      ;; "Compare STRING1 and STRING2 case-insensitively."
      ;;
      ;; The C is `(eq t (compare-strings string1 0 nil string2 0 nil t))'
      ;; - `nil' end means the string's length, and the answer is the
      ;; symbol `t' or a mismatch index.
      ;;--------------------------------------------------------------
      (eq? #t (compare-strings string1 0 (string-length string1)
                               string2 0 (string-length string2)
                               #t)))

    (define (member-ignore-case elt lst)
      ;; GNU Emacs's `member-ignore-case' (`subr.el:1054'): "Like
      ;; `member', but ignore differences in case and text
      ;; representation. ELT must be a string. ... Non-strings in LIST
      ;; are ignored."
      ;;
      ;; The answer is the TAIL whose car matches (`member''s answer),
      ;; not a boolean.
      ;;--------------------------------------------------------------
      (let loop ((tail lst))
        (cond ((not (pair? tail)) #f)
              ((and (string? (car tail))
                    (string-equal-ignore-case elt (car tail)))
               tail)
              (else (loop (cdr tail))))))

    (define (assoc-default key alist . rest)
      ;; GNU Emacs's `assoc-default' (subr.el): "Find object KEY in a
      ;; pseudo-alist ALIST. ALIST is a list of conses or objects. Each
      ;; element (or the element's car, if it is a cons) is compared with
      ;; KEY by calling TEST ... If that is non-nil, the element matches;
      ;; then `assoc-default' returns the element's cdr, if it is a cons,
      ;; or DEFAULT if the element is not a cons."
      ;;
      ;; This is the walk `set-auto-mode' makes through every mode alist,
      ;; and the reason its TEST is `string-match' rather than `equal'.
      ;;--------------------------------------------------------------
      (let ((test (if (and (pair? rest) (car rest)) (car rest) equal?))
            (default (if (and (pair? rest) (pair? (cdr rest)))
                         (cadr rest)
                         #f)))
        (let loop ((tail alist))
          (cond
           ((null? tail) #f)
           (else
            (let ((elt (car tail)))
              (if (test (if (pair? elt) (car elt) elt) key)
                  (if (pair? elt) (cdr elt) default)
                  (loop (cdr tail)))))))))

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

    (define (intern-soft name . args)
      ;; GNU Emacs's `intern-soft` (`lread.c:2874`): "Return the canonical
      ;; symbol whose name is STRING, or nil if none exists. If OBJ is
      ;; already a symbol, return it, provided it is interned in OBARRAY."
      ;;
      ;; **Every symbol is interned here.** Emacs answers nil for a name
      ;; that has never been read as a symbol, which is how
      ;; `lisp-indent-find-method` recognises a package-prefixed name
      ;; (`foo:bar`) that no obarray entry matches; a Scheme symbol made
      ;; by `string->symbol` *is* interned, so this answers the symbol and
      ;; that branch is never taken. Named in `cl-indent.scm`, which is
      ;; the only caller, rather than faked here.
      ;;--------------------------------------------------------------
      (cond ((symbol? name) name)
            ((string? name) (string->symbol name))
            (else (string->symbol (format #f "~a" name)))))

    (define (merge-ordered-lists lists . args)
      ;; GNU Emacs's `merge-ordered-lists` (`subr.el:2984`): "Merge LISTS
      ;; in a consistent order. LISTS is a list of lists of elements.
      ;; Merge them into a single list containing the same elements
      ;; (removing duplicates), obeying their relative positions in each
      ;; list."
      ;;
      ;; The algorithm is C3 linearization, and its one caller is
      ;; `derived-mode-all-parents` (`derived.scm`) merging a mode's
      ;; parents. Equality is `eql`, which is `eqv?` here.
      ;;
      ;; **The "Inconsistent hierarchy" message is not printed.** The C's
      ;; default ERROR-FUNCTION calls `message`, which lives above this
      ;; library; the answer it returns - the head of the first remaining
      ;; list - is the same, so a cycle produces the C's answer without
      ;; the C's note.
      ;;--------------------------------------------------------------
      (let ((error-function (%subr-opt args 0 #f))
            (result '()))
        ;; "(setq lists (remq nil lists))" - in Elisp nil is the empty
        ;; list, which a list of lists holds as a *list*; here the empty
        ;; thing may be `'()` or `#f`, so a list is kept whatever it is
        ;; made of and everything else goes.
        (set! lists (filter pair? lists))
        (let loop ()
          ;; "(while (cdr lists))" - `(cdr nil)` is nil in Elisp.
          (when (and (pair? lists) (pair? (cdr lists)))
            ;; "Try to find the next element of the result. This is
            ;; achieved by considering the first element of each input
            ;; list and accepting a candidate if it is consistent with the
            ;; rest of the input lists."
            (let* ((find-next
                   (lambda (lists)
                     (let walk ((tail lists) (next #f))
                       (cond ((null? tail) next)
                             (else
                              ;; "Ensure CANDIDATE is not in any position
                              ;; but the first in any of the element lists
                              ;; of LISTS."
                              (let ((candidate
                                     (let check ((other lists))
                                       (cond ((null? other)
                                              (car (car tail)))
                                             ((memv (car (car tail))
                                                    (cdr (car other)))
                                              #f)
                                             (else (check (cdr other)))))))
                                (if (not candidate)
                                    (walk (cdr tail) next)
                                    candidate)))))))
                  (next (find-next lists)))
              (if (not next)
                  ;; "The graph is inconsistent."
                  (let ((tail lists))
                    ;; "Try and reduce the \"remaining-list\" such that
                    ;; its `caar` participates in the inconsistency."
                    (let reduce ()
                      (when (and (pair? (cdr tail))
                                 (not (find-next (cdr tail))))
                        (set! tail (cdr tail))
                        (reduce)))
                    (set! next
                          (if error-function
                              (error-function tail)
                              (car (car tail))))
                    (unless (assoc next lists eqv?)
                      (error "Invalid candidate returned by error-function: ~s"
                             next))
                    ;; "Break the cycle, while keeping other dependencies."
                    (set! lists
                          (map (lambda (list)
                                 (cons (car list)
                                       (filter (lambda (x) (not (eq? x next)))
                                               (cdr list))))
                               lists)))
                  #f)
              ;; "The graph is consistent so far, add NEXT to result and
              ;; merge input lists, dropping NEXT from their heads where
              ;; applicable."
              (set! result (cons next result))
              (set! lists
                    (filter pair?
                          (map (lambda (list)
                                 (if (eqv? (car list) next)
                                     (cdr list)
                                     list))
                               lists)))
              (loop))))
        (if (null? result)
            ;; "Common case." - Emacs's `(car nil)` is nil, an empty LISTS
            ;; being the nil it started from.
            (if (pair? lists) (car lists) '())
            (append (reverse result) (car lists)))))

    (define (user-error fmt . args)
      ;; GNU Emacs's `user-error' (`subr.el'): "Signal an error of type
      ;; `user-error'." This tree has one condition type for errors, so
      ;; the condition is `error''s; the echo-area text is the same, and
      ;; nothing here catches the two apart.
      ;;--------------------------------------------------------------
      (if (null? args) (error fmt) (apply error fmt args)))

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
         ;; `xsignal3 (Qscan_error, ...)' - `syntax.scm''s record; its
         ;; message is already the rendered text.
         ((scan-error? err) (scan-error-string err))
         ;; `xsignal1 (Qsearch_failed, ...)' - `search.scm`'s record.
         ((search-failed? err) (search-failed-error err))
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
    ;; The `y-or-n-p' variables (subr.el, beside the question itself)
    ;;------------------------------------------------------------------

    (define y-or-n-p-use-read-key #f)
    (set! y-or-n-p-use-read-key y-or-n-p-use-read-key)
    ;; ^ GNU Emacs's `y-or-n-p-use-read-key' (`subr.el:4102'): "Use
    ;; `read-key' when reading answers to "y or n" questions by
    ;; `y-or-n-p'." Nil is Emacs 31's default. A plain variable, as Emacs
    ;; declares it - nothing `let`-binds it, a user `setq`s it - and the
    ;; self-assignment keeps the compiler from folding its reads (the
    ;; `*enable-disabled-menus-and-buttons*` rule).
    ;;
    ;; `map-y-or-n-p` reads it and takes the minibuffer arm when it is
    ;; nil, which is the only arm this tree carries.

    (define y-or-n-p-history-variable #f)
    (set! y-or-n-p-history-variable y-or-n-p-history-variable)
    ;; ^ GNU Emacs's `y-or-n-p-history-variable' (`subr.el:4039'):
    ;; "History list symbol to add `y-or-n-p' answers to." Nil is the
    ;; default, which `map-y-or-n-p` reads as the default history
    ;; (`(or y-or-n-p-history-variable t)`).

    ;;------------------------------------------------------------------
    ;; Minor modes
    ;;------------------------------------------------------------------

    (define *minor-mode-list* (make-parameter '()))

    (define *global-minor-modes* (make-parameter '()))
    ;; ^ GNU Emacs's `global-minor-modes' (`subr.el:3200'): "List of
    ;; minor mode variables for modes that are currently enabled
    ;; globally." `define-minor-mode`'s generated command keeps it (the
    ;; C's `(add-to-list 'global-minor-modes ...)` / `(setq
    ;; global-minor-modes (delq ...))`), and `describe-mode` reads it.
    ;; A parameter like its sibling `*minor-mode-list*`, because the
    ;; command sets it with a call and `describe-mode` reads it with a
    ;; call.
    ;; ^ GNU Emacs's `minor-mode-list' (`bindings.el`): "List of
    ;; variables of minor modes. Each element is a variable symbol, whose
    ;; value is t when the minor mode is enabled." The list is not read
    ;; by anything here yet; `add-minor-mode' keeps it because it is one
    ;; of the three things that function maintains.

    (define *minor-mode-alist*
      (make-parameter
       (list (list 'abbrev-mode " Abbrev")
             (list 'overwrite-mode 'overwrite-mode)
             (list 'auto-fill-function " Fill")
             ;; "not really a minor mode..." - the recording lighter.
             (list 'defining-kbd-macro 'mode-line-defining-kbd-macro))))
    ;; ^ GNU Emacs's `minor-mode-alist' (`bindings.el:976'): "Alist
    ;; saying how to show minor modes in the mode line. Each element
    ;; looks like (VARIABLE STRING); STRING is included in the mode line
    ;; if VARIABLE's value is non-nil. ... Actually, STRING need not be a
    ;; string; any mode-line construct is okay."
    ;;
    ;; The initial value is bindings.el's own list, all four entries.
    ;; Only `overwrite-mode` and `auto-fill-function` can ever show: the
    ;; other two name state this tree has not ported (abbrev mode and
    ;; keyboard-macro recording), and a variable with no value reads
    ;; false, which is Emacs's answer for a mode that is off. The
    ;; `mode-line-defining-kbd-macro` symbol is not evaluated unless the
    ;; mode is on, so it being unbound is invisible.
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

    (define (add-hook hook function . rest)
      ;; GNU Emacs's `add-hook' (subr.el:2295): "Add to the value of HOOK
      ;; the function FUNCTION. FUNCTION is not added if already
      ;; present."
      ;;
      ;; **HOOK is the parameter**, because that is what a hook is in
      ;; this tree (see `run-hooks'). Emacs names it with a symbol and
      ;; reads the symbol's value; there is nothing here that turns a
      ;; symbol back into a binding, so the parameter is passed.
      ;;
      ;; DEPTH is the C's `(unless (numberp depth) (setq depth (if depth
      ;; 90 0)))' and the two positions it chooses: a function is added
      ;; at the end for a positive depth and at the front otherwise. The
      ;; `hook--depth-alist' that orders functions *among themselves* by
      ;; depth is not carried - nothing here sets a depth but 0.
      ;;
      ;; LOCAL modifies the hook's buffer-local value instead, which is a
      ;; buffer slot keyed by the hook parameter (`hook-value',
      ;; `buffer.scm', merges it back). A hook with no local value yet is
      ;; made local with the list `(t)' - the marker that says "run the
      ;; global value here" (`subr.el:2330') - so an ordinary LOCAL
      ;; addition is `(FUNCTION t)' or `(t FUNCTION)' by DEPTH.
      ;;
      ;; Emacs also treats a hook whose value is already buffer-local as
      ;; LOCAL even when the argument is nil ("Detect the case where
      ;; make-local-variable was used on a hook"); that is the same test
      ;; here, `local-variable-p' on the parameter.
      ;;--------------------------------------------------------------
      (let* ((depth (if (pair? rest) (car rest) #f))
             (depth (if (number? depth) depth (if depth 90 0)))
             (local-arg (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (buffer (current-buffer))
             (local (and buffer
                         (or local-arg (local-variable-p hook buffer)))))
        (if local
            (let* ((bound (local-variable-p hook buffer))
                   (current (and bound (buffer-local-value buffer hook)))
                   (current (cond ((not current) (list #t))
                                  ((procedure? current) (list current))
                                  (else current))))
              (unless (member function current)
                (set-buffer-local-value!
                 buffer hook
                 (if (> depth 0)
                     (append current (list function))
                     (cons function current)))))
            (let* ((current (hook))
                   (current (cond ((not current) '())
                                  ((procedure? current) (list current))
                                  (else current))))
              (if (member function current)
                  (hook current)
                  (hook (if (> depth 0)
                            (append current (list function))
                            (cons function current))))))))

    (define (remove-hook hook function . rest)
      ;; GNU Emacs's `remove-hook' (subr.el:2385): "Remove FUNCTION from
      ;; HOOK's functions. ... Do nothing if HOOK does not currently
      ;; contain FUNCTION." HOOK and LOCAL as in `add-hook' above; the
      ;; `(t)' marker is left where it is, as `remove-hook' leaves it.
      ;;--------------------------------------------------------------
      (let* ((local-arg (and (pair? rest) (car rest)))
             (buffer (current-buffer))
             (local (and buffer
                         (or local-arg (local-variable-p hook buffer)))))
        (if local
            (when (and buffer (local-variable-p hook buffer))
              (let ((current (buffer-local-value buffer hook)))
                (set-buffer-local-value!
                 buffer hook
                 (cond ((not current) '())
                       ((procedure? current)
                        (if (equal? current function) '() current))
                       (else (let loop ((rest current) (acc '()))
                               (cond ((null? rest) (reverse acc))
                                     ((equal? (car rest) function)
                                      (append (reverse acc) (cdr rest)))
                                     (else (loop (cdr rest)
                                                 (cons (car rest) acc))))))))))
            (let ((current (hook)))
              (hook (cond ((not current) '())
                          ((procedure? current)
                           (if (equal? current function) '() current))
                          (else (let loop ((rest current) (acc '()))
                                  (cond ((null? rest) (reverse acc))
                                        ((equal? (car rest) function)
                                         (append (reverse acc) (cdr rest)))
                                        (else (loop (cdr rest)
                                                    (cons (car rest) acc))))))))))))

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

    (define (run-hook-with-args-until-failure hook . args)
      ;; GNU Emacs's `run-hook-with-args-until-failure' (`eval.c:2908' -
      ;; the `funcall_not` handler of `run_hook_with_args`): "Call each
      ;; function in order with arguments ARGS, stopping at the first one
      ;; that returns nil, and return nil.  Otherwise (if all functions
      ;; return non-nil, or if there are no functions to call), return
      ;; t." HOOK is the list of procedures, as its two siblings take it.
      ;;--------------------------------------------------------------
      (let loop ((rest (cond ((not hook) '())
                             ((procedure? hook) (list hook))
                             (else hook))))
        (cond ((null? rest) #t)
              ((apply (car rest) args) (loop (cdr rest)))
              (else #f))))

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

    (define *use-dialog-box-override* (make-parameter #f))
    ;; ^ GNU Emacs's `use-dialog-box-override' (`subr.el:4118'):
    ;; "Whether `use-dialog-box-p' should always return t." Emacs
    ;; `let'-binds it in `server.el' and `nsm.el', so it is a parameter;
    ;; `files.scm''s `use-dialog-box-p' is its one reader here.

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
      ;; **`inhibit-modification-hooks' is carried now** (2026-11-17):
      ;; it is `insdel.scm`'s parameter, tested where the C tests it -
      ;; in `prepare_to_modify_buffer_1` before the before-change hooks,
      ;; and at `signal_after_change`'s first line. Without it a property
      ;; write during `syntax-propertize` ran the change hooks, which
      ;; flushed the `syntax-ppss` cache in the middle of a parse.
      ;;
      ;; `autosaved' - the third value Emacs 31's `buffer-modified-p' can
      ;; answer - has no counterpart: this tree's is true or false.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((with-silent-modifications body ...)
         (let ((buffer (current-buffer)))
           (let ((modified (buffer-modified-p buffer))
                 (undo-list (text-editor-undo-list buffer)))
             (parameterize ((*inhibit-read-only* #t)
                            (*inhibit-modification-hooks* #t))
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

    ;;----------------------------------------------------------------
    ;; Keymap helpers - `subr.el`'s, beside `keymap.c`'s primitives
    ;;----------------------------------------------------------------

    (define (%keymap-order-without order event)
      ;; ORDER without EVENT, keeping the rest's sequence.
      ;;--------------------------------------------------------------
      (let loop ((rest order) (out '()))
        (cond ((null? rest) (reverse out))
              ((eqv? (car rest) event) (loop (cdr rest) out))
              (else (loop (cdr rest) (cons (car rest) out))))))

    (define (%keymap-order-with-after order event after)
      ;; EVENT placed immediately after AFTER in ORDER, or at the end
      ;; when AFTER is `t', nil, or absent - Emacs's
      ;; `define-key-after`'s three insertion points, the third being
      ;; "if we reach the end of this keymap". An inherited map cannot
      ;; stand in the order: parents are a separate field here, and
      ;; every own binding already precedes them.
      ;;--------------------------------------------------------------
      (let ((rest (%keymap-order-without order event)))
        (if (or (not after) (eq? after #t))
            (append rest (list event))
            (let loop ((tail rest) (out '()))
              (cond ((null? tail) (append (reverse out) (list event)))
                    ((eqv? (car tail) after)
                     (append (reverse (cons (car tail) out))
                             (cons event (cdr tail))))
                    (else (loop (cdr tail) (cons (car tail) out))))))))

    (define (suppress-keymap map . optional)
      ;; GNU Emacs's `suppress-keymap' (`subr.el:1316`): "Make MAP
      ;; override all normally self-inserting keys to be undefined.
      ;; Normally, as an exception, digits and minus-sign are set to make
      ;; prefix args, but optional second arg NODIGITS non-nil treats them
      ;; like other chars."
      ;;
      ;; The C's body is three statements, and the first is the whole
      ;; idea: **a single `[remap self-insert-command]`**, not a binding
      ;; for every printing character. Every key that would have run
      ;; self-insert runs `undefined` instead, which is why a letter
      ;; typed in a special-mode buffer says "x is undefined" and never
      ;; reaches the buffer's read-only check.
      ;;
      ;; The digitis are *not* suppressed by default: they keep their
      ;; prefix-argument meaning (`digit-argument`), and `-` keeps
      ;; `negative-argument`, so `M-x`-style numeric prefixes still work
      ;; in a special-mode buffer.
      ;;
      ;; This is `:suppress t` in `defvar-keymap`, which is how
      ;; `special-mode-map` asks for it (`simple.el:580`).
      ;;--------------------------------------------------------------
      (define-key map (vector 'remap 'self-insert-command) 'undefined)
      (unless (and (pair? optional) (car optional))
        (define-key map (vector (char->integer #\-)) 'negative-argument)
        (let loop ((c (char->integer #\0)))
          (when (<= c (char->integer #\9))
            (define-key map (vector c) 'digit-argument)
            (loop (+ c 1)))))
      #f)

    (define (define-key-after keymap key definition . optional)
      ;; GNU Emacs's `define-key-after' (`subr.el:1345'): "Add binding
      ;; in KEYMAP for KEY => DEFINITION, right after AFTER's binding.
      ;; ... If AFTER is t or omitted, the new binding goes at the end
      ;; of the keymap. ... The order of bindings in a keymap matters
      ;; only when it is used as a menu, so this function is not useful
      ;; for non-menu keymaps."
      ;;
      ;; A KEY longer than one event defines in the prefix map that
      ;; `lookup-key' reaches, which is what `[menu-bar file new]'
      ;; is. AFTER is one event (a character or a symbol), not a
      ;; sequence - the C's comparison is against `(car-safe (car tail))'.
      ;;--------------------------------------------------------------
      (let ((after (if (pair? optional) (car optional) #t)))
        (unless (keymap-type? keymap)
          (error "Wrong type argument: keymapp" keymap))
        (let ((events (keymap-index key)))
          (unless events
            (error "Empty key is invalid"))
          (let* ((last (car (reverse events)))
                 (prefix (if (null? (cdr events))
                             keymap
                             (keymap-lookup
                              keymap
                              (reverse (cdr (reverse events))))))
                 (target (cond ((keymap-type? prefix) prefix)
                               ;; **A missing prefix silently defines
                               ;; nothing**, which is the Elisp's own
                               ;; behaviour: `keymap' becomes nil, the
                               ;; `while' loop does not run, and the
                               ;; function answers nil. `define-key'
                               ;; creates a prefix; this one does not.
                               ((not prefix) #f)
                               (else
                                (error "Wrong type argument: keymapp"
                                       prefix))))
                 (after (cond ((or (not after) (eq? after #t)) #t)
                              ((char? after) (char->integer after))
                              ((or (integer? after) (symbol? after)) after)
                              (else (error "AFTER must be a single event"
                                           after)))))
            (when target
              (store-in-keymap target last definition)
              (%set!keymap-order!
               target
               (%keymap-order-with-after (keymap-order target) last after)))
            #f))))

    (define (keymap--menu-item-binding val)
      ;; GNU Emacs's `keymap--menu-item-binding' (`subr.el:1432'):
      ;; "Return the binding part of a menu-item."
      ;;
      ;; The four arms are the Elisp's: a plain binding, the new
      ;; `(menu-item NAME BINDING ...)' form (whose `:filter' is a
      ;; *function* here, called on the binding), and the two old
      ;; formats - `(NAME STRING . BINDING)' and `(STRING . BINDING)'.
      ;;--------------------------------------------------------------
      (cond
       ((not (pair? val)) val)
       ((eq? 'menu-item (car val))
        (let* ((binding (if (pair? (cddr val)) (caddr val) #f))
               (filter (plist-get (cdddr val) ':filter)))
          (if filter (filter binding) binding)))
       ((and (pair? (cdr val)) (string? (cadr val))) (cddr val))
       ((string? (car val)) (cdr val))
       (else val)))

    (define (keymap--menu-item-with-binding item binding)
      ;; GNU Emacs's (`subr.el:1448'): "Build a menu-item like ITEM but
      ;; with its binding changed to BINDING."
      ;;--------------------------------------------------------------
      (cond
       ((not (pair? item)) binding)
       ((eq? 'menu-item (car item))
        (let ((item (copy-sequence item)))
          (let ((tail (cddr item)))
            (set-car! tail binding)
            ;; Remove any potential filter.
            (when (plist-get (cdr tail) ':filter)
              (set-cdr! tail (plist-put (cdr tail) ':filter #f))))
          item))
       ((and (pair? (cdr item)) (string? (cadr item)))
        (cons (car item) (cons (cadr item) binding)))
       (else (cons (car item) binding))))

    (define (keymap--merge-bindings val1 val2)
      ;; GNU Emacs's (`subr.el:1464'): "Merge bindings VAL1 and VAL2."
      ;;
      ;; When both are submenus their keymaps are merged. Emacs builds
      ;; `(keymap MAP1 MAP2)', a list of layers; this tree's keymap is a
      ;; record, so the merge is a new map with MAP1's own bindings and
      ;; MAP2 as its parent - lookup order MAP1 then MAP2. **MAP1's own
      ;; parent, if it had one, is not carried** (Emacs's layered list
      ;; would search it); submenus with parents are rare, and
      ;; canonicalize does not canonicalize subkeymaps either.
      ;;--------------------------------------------------------------
      (let ((map1 (keymap--menu-item-binding val1))
            (map2 (keymap--menu-item-binding val2)))
        (if (not (and (keymap-type? map1) (keymap-type? map2)))
            val1
            (let ((map (make-sparse-keymap (keymap-prompt map1))))
              (for-each
               (lambda (event)
                 (store-in-keymap
                  map event
                  (hashv-ref (keymap-bindings map1) event #f)))
               (reverse (keymap-order map1)))
              (set-keymap-parent map map2)
              (keymap--menu-item-with-binding
               (if (keymap-type? val1)
                   (if (keymap-type? val2) #f val2)
                   val1)
               map)))))

    (define (keymap-canonicalize map)
      ;; GNU Emacs's `keymap-canonicalize' (`subr.el:1475'): "Return a
      ;; simpler equivalent keymap. This resolves inheritance and
      ;; redefinitions."
      ;;
      ;; Emacs's keymap is a list of layers and the canon is a new list
      ;; with no parent; this tree's is a record, so the resolution is a
      ;; walk over MAP and its parents in precedence order, copying the
      ;; first definition seen for each event into a new parentless map.
      ;; Where both definitions are keymaps they are merged into a list
      ;; of keymaps, the more specific first - what `keymap--merge-bindings'
      ;; builds in the Elisp, and what the menu code reads as a submenu.
      ;;
      ;; **Not carried**: Emacs's character *ranges* - a cons event,
      ;; which this tree's event table cannot key - and with them the
      ;; Elisp's two FIXMEs (nil bindings, menu ordering) are out of
      ;; reach. `map-keymap' already walks parents, so the walk here is
      ;; the Elisp's `while (keymapp map)'.
      ;;--------------------------------------------------------------
      (let* ((new (make-sparse-keymap (keymap-prompt map)))
             (seen '()))                ; alist, in encounter order
        (map-keymap
         (lambda (event def)
           (let ((old (assv event seen)))
             (cond
              ((not old)
               (set! seen (append seen (list (cons event def)))))
              ((and (keymap-type? (keymap--menu-item-binding (cdr old)))
                    (keymap-type? (keymap--menu-item-binding def)))
               (set-cdr! old (keymap--merge-bindings (cdr old) def)))
              (else #f))))
         map)
        ;; `store-in-keymap' puts each new event at the front; filling in
        ;; reverse makes the new map's order the encounter order.
        (for-each (lambda (cell)
                    (store-in-keymap new (car cell) (cdr cell)))
                  (reverse seen))
        new))

    (define *key-substitution-in-progress* (make-parameter '()))
    ;; ^ GNU Emacs's `key-substitution-in-progress` (`subr.el:1638'): the
    ;; maps a substitution walk is already inside, so that a map reached
    ;; twice - `C-x' appears under two prefixes, and a map can be its own
    ;; submap somewhere - is not scanned again. Dynamically bound, which
    ;; is why it is a parameter: the Elisp `let`-binds it around each
    ;; level of the recursion.

    (define (substitute-key-definition olddef newdef keymap
                                       oldmap prefix)
      ;; GNU Emacs's `substitute-key-definition' (`subr.el:1642'):
      ;; "Replace OLDDEF with NEWDEF for any keys in KEYMAP now defined as
      ;; OLDDEF. ... Alternatively, if optional fourth argument OLDMAP is
      ;; specified, we redefine in KEYMAP as NEWDEF those keys that are
      ;; defined as OLDDEF in OLDMAP."
      ;;
      ;; **This is how `tty-menu-navigation-map` is built**
      ;; (`menu-bar.el:3008'): the terminal's navigation map does not bind
      ;; keys of its own, it takes the global map's bindings *for those
      ;; commands* under the names `term.c` interprets (`tty-menu-exit`
      ;; for `keyboard-quit`, `tty-menu-next-item` for `next-line`, ...).
      ;; So the terminal's menu accepts whatever the user's own map has
      ;; bound to next-line, without a second table to keep in step.
      ;;
      ;; The four Emacs arguments are all passed explicitly here - the
      ;; tree's rule for optional arguments - and PREFIX is a *vector* of
      ;; events, `#()` at the top (Emacs's "").
      ;;--------------------------------------------------------------
      (let* ((scan (if oldmap oldmap keymap))
             ;; Emacs's `(vconcat prefix [nil])`: one slot more than the
             ;; prefix, and the appended nil is overwritten by the event
             ;; below, so what is passed on is the prefix *with* this
             ;; level's event - never a trailing nil.
             (prefix1 (list->vector
                       (append (vector->list prefix) (list #f)))))
        (parameterize ((*key-substitution-in-progress*
                        (cons scan (*key-substitution-in-progress*))))
          (map-keymap
           (lambda (char defn)
             (vector-set! prefix1 (vector-length prefix) char)
             (substitute-key-definition-key defn olddef newdef prefix1
                                            keymap))
           scan))))

    (define (substitute-key-definition-key defn olddef newdef prefix keymap)
      ;; GNU Emacs's `substitute-key-definition-key' (`subr.el:1675'):
      ;; find the actual command name within a binding and, when it is
      ;; OLDDEF, rebind PREFIX in KEYMAP to NEWDEF - keeping the menu
      ;; prompt, the menu-item wrapper and the rest of the binding.
      ;;
      ;; `define-key` takes a command and this tree's maps hold the
      ;; *procedure* of a `define-command`, so OLDDEF is that procedure
      ;; and `eq?` is the comparison Emacs's `eq` makes.
      ;;--------------------------------------------------------------
      (let ((menu-item #f)
            (skipped '()))
        (if (and (pair? defn) (eq? (car defn) 'menu-item))
            ;; `(nth 2 DEFN)` - which is nil for a menu item that names no
            ;; command, as `(menu-item "--")` does.
            (begin (set! menu-item defn)
                   (set! defn (and (>= (length defn) 3) (list-ref defn 2))))
            ;; Skip past a menu prompt - and past the cached
            ;; key-equivalence data of a menu item, which is the cons in
            ;; the car.
            (begin
              (let loop ()
                (when (and (pair? defn) (string? (car defn)))
                  (set! skipped (cons (car defn) skipped))
                  (set! defn (cdr defn))
                  (loop)))
              (when (and (pair? defn) (pair? (car defn)))
                (set! defn (cdr defn)))))
        (cond
         ((or (eq? defn olddef)
              ;; "Compare with `equal` if definition is a key sequence.
              ;; That is useful for operating on function-key-map."
              (and (or (string? defn) (vector? defn))
                   (equal? defn olddef)))
          (define-key keymap prefix
            (if menu-item
                (let ((copy (list-copy menu-item)))
                  (list-set! copy 2 newdef)
                  copy)
                (if (null? skipped)
                    newdef
                    (append (reverse skipped) (list newdef))))))
         (else
          ;; Look past a symbol that names a keymap. This tree's keymaps
          ;; are values rather than symbols, so that step is the identity
          ;; - named rather than dropped, because Emacs's `indirect-function`
          ;; is what makes a menu item's `:filter` symbol reachable and
          ;; nothing here sets one yet.
          (let ((inner-def defn))
            (when (and (keymap-type? inner-def)
                       ;; "Avoid recursively scanning where KEYMAP does
                       ;; not have a submap."
                       (let ((elt (keymap-lookup keymap prefix)))
                         (or (not elt) (number? elt) (keymap-type? elt)))
                       ;; "Avoid recursively rescanning keymap being
                       ;; scanned."
                       (not (memq inner-def
                                  (*key-substitution-in-progress*))))
              (substitute-key-definition olddef newdef keymap inner-def
                                         prefix)))))))

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
                        ;; **`(pair? (car rest))`, which the C's guard has
                        ;; and this did not**: `(consp (car alist))` is
                        ;; what keeps an alist whose elements are not all
                        ;; conses - a tab is `(tab (name . "x") ...)`, and
                        ;; its first element is a symbol - from being
                        ;; walked into `(car 'tab)`, which raises.
                        (if (and (pair? rest) (pair? (car rest))
                                 (test (car (car rest)) key))
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

    (define (minusp number)
      ;; GNU Emacs's `minusp' (`subr.el:643'): "Return t if NUMBER is
      ;; negative." The C's `(< NUMBER 0)' test, which a non-number
      ;; fails with a wrong-type error as it does there.
      ;;--------------------------------------------------------------
      (< number 0))

    (define (last list . n-args)
      ;; GNU Emacs's `last' (`subr.el:886'): "Return the last link of
      ;; LIST. Its car is the last element. If LIST is nil, return nil.
      ;; If N is non-nil, return the Nth-to-last link of LIST. If N is
      ;; bigger than the length of LIST, return LIST."
      ;;
      ;; Emacs computes the length with `safe-length', whose only
      ;; difference from `length' is that it stops on a circular list;
      ;; that arm is not carried - every caller here passes a proper
      ;; list.
      (let ((n (if (pair? n-args) (car n-args) #f)))
        (if (and n (not (null? n)))
            (and (>= n 0)
                 (let ((m (length list)))
                   (if (< n m) (nthcdr (- m n) list) list)))
            (and (pair? list)
                 (nthcdr (- (length list) 1) list)))))

    (define (butlast list . n-args)
      ;; GNU Emacs's `butlast' (`subr.el:900'): "Return a copy of LIST
      ;; with the last N elements removed. If N is omitted or nil, return
      ;; a copy of LIST without its last element. If N is zero or
      ;; negative, return LIST."
      ;;
      ;; Emacs's body is `(take (- (length list) n) list)', and `take' is
      ;; seq.el's; the copy is written out here rather than importing a
      ;; second library for four lines.
      (let ((n (if (pair? n-args) (car n-args) #f)))
        (unless n (set! n 1))
        (if (<= n 0)
            list
            (let ((k (- (length list) n)))
              (let loop ((l list) (k k) (acc '()))
                (if (or (<= k 0) (null? l))
                    (reverse acc)
                    (loop (cdr l) (- k 1) (cons (car l) acc))))))))

    (define (car-safe object)
      ;; GNU Emacs's `car-safe' (`data.c:670'): "Return the car of OBJECT
      ;; if it is a cons cell, or else nil." The C's `CAR_SAFE' is the
      ;; test. **The nil is `#f', not `'()`**: Emacs's callers test the
      ;; answer - `(or (car-safe X) ...)' in `c-lineup-comment'
      ;; (`cc-align.scm') is one - and `'()` is *true* in Scheme, so a
      ;; list here makes the `or' take the nil branch and answer it.
      (if (pair? object) (car object) #f))

    (define (cdr-safe object)
      ;; GNU Emacs's `cdr-safe' (`data.c:688'): "Return the cdr of
      ;; OBJECT if it is a cons cell, or else nil." (Not `cdr', which
      ;; signals for a non-list.) The nil is `#f' for the same reason as
      ;; `car-safe''s: `(or (cdr-safe X) ...)' must fall through, and
      ;; `'()` is true in Scheme. Callers that walk the result under a
      ;; `pair?' test are unaffected.
      (if (pair? object) (cdr object) #f))

    (define (copy-tree tree . rest)
      ;; GNU Emacs's `copy-tree' (`subr.el:1002'): "Make a copy of TREE.
      ;; If TREE is a cons cell, this recursively copies both its car
      ;; and its cdr. Contrast to `copy-sequence', which copies only
      ;; along the cdrs. With the second argument VECTORS-AND-RECORDS
      ;; non-nil, this traverses and copies vectors and records as well
      ;; as conses."
      ;;
      ;; The C's two loops are kept: the spine is walked with `push',
      ;; reversed and linked with `nconc', and the improper tail is
      ;; copied only when it is a vector or a record.
      ;;
      ;; **The record arm is not carried**: Emacs's `recordp' names its
      ;; own cl-defstruct records, and this tree's records are Guile's,
      ;; which `copy-sequence' has no arm for. Nothing here passes
      ;; VECTORS-AND-RECORDS for a record; a caller that does gets the
      ;; "Wrong type argument: sequencep" `copy-sequence' raises.
      ;;--------------------------------------------------------------
      (let ((vectors-and-records (if (pair? rest) (car rest) #f)))
        (if (pair? tree)
            (let loop ((tree tree) (result '()))
              (if (pair? tree)
                  (let ((newcar (car tree)))
                    (if (or (pair? (car tree))
                            (and vectors-and-records (vector? (car tree))))
                        (set! newcar (copy-tree (car tree) vectors-and-records)))
                    (loop (cdr tree) (cons newcar result)))
                  (nconc (nreverse result)
                         (if (and vectors-and-records (vector? tree))
                             (copy-tree tree vectors-and-records)
                             tree))))
            (if (and vectors-and-records (vector? tree))
                (let ((copy (copy-sequence tree)))
                  (let loop ((i (- (vector-length copy) 1)))
                    (when (>= i 0)
                      (vector-set! copy i
                                   (copy-tree (vector-ref copy i)
                                              vectors-and-records))
                      (loop (- i 1))))
                  copy)
                tree))))

    (define (remove elt seq)
      ;; GNU Emacs's `remove' (`subr.el:1145'): "Return a copy of SEQ
      ;; with all occurrences of ELT removed. SEQ must be a list,
      ;; vector, or string. The comparison is done with `equal'.
      ;; Contrary to `delete', this does not use side-effects, and the
      ;; argument SEQ is not modified."
      ;;
      ;; Emacs's `(nlistp seq)' guard means `delete' copies a non-list
      ;; itself, so only a list is copied here.
      ;;--------------------------------------------------------------
      (delete elt (if (not (list? seq))
                      seq
                      (copy-sequence seq))))

    (define (remq elt list)
      ;; GNU Emacs's `remq' (`subr.el:1157'): "Return LIST with all
      ;; occurrences of ELT removed. The comparison is done with `eq'.
      ;; Contrary to `delq', this does not use side-effects, and the
      ;; argument LIST is not modified."
      ;;--------------------------------------------------------------
      (let ((list (let skip ((list list))
                    (if (and (pair? list) (eq? elt (car list)))
                        (skip (cdr list))
                        list))))
        (if (memq elt list)
            (delq elt (copy-sequence list))
            list)))

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
    ;; `select-window' and `goto-char', and `(schemacs frame)'
    ;; imports *this* library, so a definition here could not reach
    ;; them. It lives in `mouse.sld', with the commands that call it.
    ;;------------------------------------------------------------------

    (define *event--posn-at-point-function* (make-parameter #f))
    ;; ^ The seam `event--posn-at-point' (`subr.el:1894') is reached
    ;; through. It needs a window and `posn-at-point', and both live
    ;; above this library - `posn-at-point' is `xdisp.scm`'s, with the
    ;; other geometry - so `xdisp.scm` installs it at load time, the
    ;; same edge `*get-text-property-function*` and `*message-function*`
    ;; take. `#f` until then, which is the answer this library gave
    ;; before the fallback existed.
    ;;
    ;; **The fallback is not optional: a keyboard key takes it too.**
    ;; `last_nonmenu_event = key' (`keyboard.c:12216') is the *key
    ;; event* - an integer or a symbol, not a cons - so every command
    ;; that asks an event for its position while running from a key
    ;; reads this arm. `tab-line-switch-to-next-tab' is one, bound to
    ;; `C-x <right>`, and without the arm it died with "Wrong type
    ;; argument in position 1 (expecting struct): #f" the moment the
    ;; tab line was on.

    (define (event-start event)
      ;; GNU Emacs's `event-start' (`subr.el:1911'): "Return the
      ;; starting position of EVENT. ... If EVENT is nil, the value of
      ;; `posn-at-point' is used instead."
      ;;
      ;; The touch-screen arms (`touchscreen-begin`/`-end`/`-update`)
      ;; are not carried - no touch event exists in either front end -
      ;; so what is left is the C's two: `(nth 1 event)` for a cons,
      ;; and the position of point for anything else.
      ;;--------------------------------------------------------------
      (or (and (pair? event) (nth 1 event))
          (let ((fallback (*event--posn-at-point-function*)))
            (and fallback (fallback)))
          #f))

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
      ;; The fallback for anything that is not a cons is the same one
      ;; `event-start' takes (`subr.el:1952`), so a keyboard key answers
      ;; the position of point rather than #f.
      ;;--------------------------------------------------------------
      (or (and (pair? event)
               (nth (if (pair? (nth 2 event)) 2 1) event))
          (let ((fallback (*event--posn-at-point-function*)))
            (and fallback (fallback)))
          #f))

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

    (define (posn-object position)
      ;; GNU Emacs's `posn-object` (`subr.el:2127`, a `defsubst`):
      ;; "Return the object (image or string) of POSITION. Value is a
      ;; list (image ...) for an image object, a cons cell (STRING .
      ;; STRING-POS) for a string object, and nil for a buffer
      ;; position." The definition is `(or (posn-image position)
      ;; (posn-string position))', and this tree has no images.
      ;;--------------------------------------------------------------
      (posn-string position))

    (define (posn-string position)
      ;; GNU Emacs's `posn-string' (`subr.el:2015'): "Return the string
      ;; object that POSITION refers to, or nil. POSITION should be a
      ;; list of the form returned by the `event-start' and `event-end'
      ;; functions."
      ;;
      ;; The object slot - `(nth 4 position)` - holds `(STRING . POS)`
      ;; when the click was on a display string and nil (or a buffer,
      ;; per bug#13979) when it was on text. A cons is a string.
      ;;--------------------------------------------------------------
      (let ((object (nth 4 position)))
        (and (pair? object) object)))

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

    (define (string-to-list string)
      ;; GNU Emacs's `string-to-list' (`subr.el:4739', a `defsubst'):
      ;; "Return a list of the characters in STRING." This tree's
      ;; characters are characters where the C's are integers, so this is
      ;; Scheme's `string->list' - and a caller that compares an answer
      ;; with `memq' against `char-after' compares like with like.
      ;;--------------------------------------------------------------
      (string->list string))


    (define-command (forward-symbol arg)
      ;; GNU Emacs's `forward-symbol' (`subr.el:6641'): "Move point to
      ;; the next position that is the end of a symbol. A symbol is any
      ;; sequence of characters that are in either the word constituent
      ;; or symbol constituent syntax class."
      ;;
      ;; ARG is *required*, as the C's `(defun forward-symbol (arg)'
      ;; makes it - a plain `(forward-symbol)' call is Emacs's
      ;; wrong-number-of-arguments - and the interactive form supplies
      ;; 1 when there is no prefix (`callint.c''s `"p"').
      ;;
      ;; `(char-after (match-beginning 0))' is `fetch-char': `char-after`
      ;; is `editfns.c`'s and that library is above this one, and the
      ;; raw read is the same character the C's own scan uses.
      "Move point to the next position that is the end of a symbol.
A symbol is any sequence of characters that are in either the
word constituent or symbol constituent syntax class.
With prefix argument ARG, do it ARG times if positive, or move
backwards ARG times if negative."
      (interactive "^p")
      (if (natnump arg)
          (re-search-forward "\\(\\sw\\|\\s_\\)+" #f 'move arg)
          ;; "while (minusp arg)" - and Elisp's `while` answers nil, so
          ;; the answer here is an explicit #f rather than the
          ;; unspecified value.
          (let loop ((arg arg))
            (if (< arg 0)
                (begin
                  (if (re-search-backward "\\(\\sw\\|\\s_\\)+" #f 'move)
                      (or (char=? (fetch-char (current-buffer) (match-beginning 0))
                                  #\newline)
                          (skip-syntax-backward "w_")))
                  (loop (+ arg 1)))
                #f))))

    ;;----------------------------------------------------------------
    ;; The hook runner, into the library that needs it
    ;;------------------------------------------------------------------
    (*run-hooks-function* run-hooks)

    ))
