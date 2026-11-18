(define-library (schemacs editor help)
  ;; This library mirrors GNU Emacs's `lisp/help.el' - the help system.
  ;; What is here is the string-substitution half, which the
  ;; disabled-command prompt and every `:help' string stand on:
  ;; `substitute-command-keys', `substitute-quotes', `key-valid-p' (with
  ;; a placement note - it is `keymap.el`'s) and the fontified key
  ;; description.
  ;;
  ;; **Not carried, and what each waits for**:
  ;;
  ;;   * `\{MAPVAR}' and `\<MAPVAR>' - the keymap summary and the
  ;;     "use this map" form. The summary is `help--describe-map-tree',
  ;;     the describe-bindings machinery (it is also what `C-h b' would
  ;;     need), which this tree has not. The forms are left standing in
  ;;     the text, as an unrecognised `\`...`` form is: the walk moves
  ;;     past them and the next character is processed normally.
  ;;   * `help-link-key-to-documentation' / `help-mode--add-function-link'
  ;;     - both are gated on `help-buffer-under-preparation`, which
  ;;     nothing here sets, so the fallback (the plain fontified key) is
  ;;     what Emacs takes too.
  ;;   * The *Help* buffer itself, `describe-*', `help-fns'.
  ;;
  ;; The walk runs over a temporary buffer as Emacs's does, because
  ;; every branch edits in place - a `\=` deletes two characters, a
  ;; failed `\`KEY'' substitution leaves the backtick for the quote
  ;; rule on the next pass - and a string accumulator would have to
  ;; re-implement that bookkeeping.

  (import
    (scheme base)
    (scheme char)
    ;; `key-valid-p` and the walk are string matchers.
    (only (schemacs editor search)
          string-match string-match-p match-end match-beginning save-match-data)
    ;; `split-string`, `kbd`-free - the strokes come as text.
    ;; `sort` for `describe-map`'s sorted sparse entries; `format` is
    ;; Guile's (`~a`, destination first); `procedure-name` is how a
    ;; definition that is not a command is still named.
    (only (guile) sort procedure-name hashv-ref caddr string-join)
    (only (schemacs editor subr) split-string keymap-canonicalize
          *minor-mode-map-alist*)
    ;; the temporary buffer the walk edits in place
    ;; `with-current-buffer` is `save-current-buffer` with a
    ;; `set-buffer`, and the rest is what a help buffer is made of.
    (only (schemacs editor buffer)
          allocate-buffer *current-buffer* current-buffer buffer-name
          get-buffer-create erase-buffer delete-all-overlays
          with-current-buffer buffer-local-value buffer-local-keymap
          buffer-pt *inhibit-read-only* set!buffer-read-only
          set-buffer-modified-p)
    (only (schemacs editor editfns)
          buffer-string buffer-substring-no-properties insert goto-char point
          point-min point-max char-after propertize save-excursion
          text-quoting-style)
    ;; the movement and deletion the walk spells the Elisp way
    (only (schemacs editor cmds) forward-char self-insert-command)
    (only (schemacs editor editfns) delete-region get-local-map eolp
          insert-char)
    ;; `search-forward` is the tree's, from `search.c`.
    (only (schemacs editor search) search-forward)
    ;; `where-is-internal` is `keymap.c`'s, and `key-description` with it.
    (only (schemacs editor keyboard)
          where-is-internal command-remapping key-binding read-key-sequence
          lookup-keymaps undefined
          *overriding-terminal-local-map* *overriding-local-map*)
    (only (schemacs editor keymap)
          key-description keymapp lookup-key keymap-order keymap-bindings
          keymap-index get-keyelt make-sparse-keymap define-key
          keymap-by-name *default-keymap*)
    ;; a command's name for `help-fns-function-name`, and the
    ;; "was this called from a key?" test `describe-bindings` records.
    (only (schemacs editor command)
          define-command command-type? command-name command-record-of
          called-interactively? current-prefix-arg)
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor derived) derived-mode-p)
    (only (schemacs editor fns) string-version-lessp)
    ;; the window a description is laid out in, and the separator line
    (only (schemacs editor frame) selected-window window-body-width)
    (only (schemacs editor window) display-buffer set-window-hscroll!)
    (only (schemacs editor simple) make-separator-line)
    (only (schemacs editor character) kbd *tab-width* event-modifiers)
    (only (schemacs editor indentc) current-column)
    ;; `describe-key`'s mouse coordinates and the key it runs.
    (only (schemacs editor subr) event-start event-end)
    (only (schemacs editor mouse) posn-set-point)
    ;; `where-is`'s interactive expression is evaluated in *this*
    ;; library's module, so the reader it names must be imported here.
    (only (schemacs editor minibuffer) read-command)
    ;; `format` is `editfns.scm`'s Emacs `format`, not Guile's.
    (only (schemacs editor editfns) message format)
    ;; the face and the property store
    (only (schemacs editor textprop) add-text-properties)
    ;; `get` is the `suppress-keymap` property test, `accessible-keymaps`
    ;; is where a description starts, and `*tab-width*` is the unit
    ;; `describe-map--fill-columns` pads in.
    (only (schemacs editor intervals) get)
    (only (schemacs editor keymap) accessible-keymaps))

  (export substitute-quotes substitute-command-keys key-valid-p
          help--key-description-fontified
          help-buffer help-setup-xref help--window-setup with-help-window
          help-fns-function-name help--describe-command
          help--describe-map-compare help--shadow-lookup
          describe-map describe-map--align-section
          describe-map--fill-columns help--describe-map-tree
          describe-buffer-bindings describe-bindings
          help-map *help-mode-function* *help-xref-following*
          *help-xref-stack-item* *describe-bindings-show-prefix-commands*
          *describe-function-1-function*
          describe-key describe-key-briefly where-is
          help--analyze-key help--filter-info-list
          help--binding-undefined-p help-key-description)

  (begin

    ;;----------------------------------------------------------------
    ;; `substitute-quotes' (help.el:1578)
    ;;----------------------------------------------------------------

    (define (substitute-quotes string)
      ;; GNU Emacs's `substitute-quotes' (`help.el:1578'):
      ;; "Substitute quote characters in STRING for display. Each grave
      ;; accent \\=` is replaced by left quote, and each apostrophe
      ;; \\=' is replaced by right quote. Which left and right quote
      ;; characters to use is determined by the variable
      ;; `text-quoting-style'."
      ;;--------------------------------------------------------------
      (case (text-quoting-style)
        ((curve)
         (list->string
          (map (lambda (c)
                 (case c ((#\`) #\‘) ((#\') #\’) (else c)))
               (string->list string))))
        ((straight)
         (list->string
          (map (lambda (c) (case c ((#\`) #\') (else c)))
               (string->list string))))
        (else string)))

    ;;----------------------------------------------------------------
    ;; `key-valid-p' (keymap.el:328)
    ;;
    ;; **A placement departure**: it is `keymap.el`'s, but it is a
    ;; string matcher (`string-match-p`, `split-string`), and both live
    ;; above `keymap.scm` - `search.scm` and `subr.scm` respectively.
    ;; This library is the first thing that wants it.
    ;;----------------------------------------------------------------

    (define (key-valid-p keys)
      ;; GNU Emacs's `key-valid-p' (`keymap.el:328'): "Return non-nil if
      ;; KEYS, a string, is a valid key sequence. ... Each key stroke is
      ;; either a single character, or the name of an event, surrounded
      ;; by angle brackets <like-this>. ... Modifiers have to be
      ;; specified in this order: A-C-H-M-S-s."
      ;;--------------------------------------------------------------
      (define prefixes
        ;; "\\(A-\\)?\\(C-\\)?\\(H-\\)?\\(M-\\)?\\(S-\\)?\\(s-\\)?"
        "\\(A-\\)?\\(C-\\)?\\(H-\\)?\\(M-\\)?\\(S-\\)?\\(s-\\)?")
      (and (string? keys)
           (string-match-p "\\`[^ ]+\\( [^ ]+\\)*\\'" keys)
           (save-match-data
            (let loop ((strokes (split-string keys " ")))
              (cond
               ((null? strokes) #t)
               (else
                (let* ((stroke (car strokes))
                       (key (if (string-match (string-append "\\`" prefixes)
                                              stroke)
                                (substring stroke (match-end 0))
                                stroke)))
                  (if (or
                       ;; a single character that is not a control
                       ;; character, and not a raw byte in [127,255] -
                       ;; every string here is multibyte, so the C's
                       ;; `multibyte-string-p` test is always true.
                       (and (= (string-length key) 1)
                            (not (< (char->integer (string-ref key 0)) 32)))
                       ;; a named event: <name> with the modifiers in
                       ;; front, and the name itself not starting a
                       ;; second modifier run ("Don't allow <M-C-down>").
                       (and (string-match-p "\\`<[-_A-Za-z0-9]+>\\'" key)
                            (= (if (string-match (string-append "\\`<" prefixes)
                                                 key)
                                   (match-end 0)
                                   0)
                               1))
                       ;; the seven shorthand names.
                       (string-match-p
                        "\\`\\(NUL\\|RET\\|TAB\\|LFD\\|ESC\\|SPC\\|DEL\\)\\'"
                        key))
                      (loop (cdr strokes))
                      #f))))))))

    ;;----------------------------------------------------------------
    ;; `help--key-description-fontified' (help.el:808)
    ;;----------------------------------------------------------------

    (define (help--key-description-fontified keys . rest)
      ;; GNU Emacs's `help--key-description-fontified' (`help.el:808'):
      ;; "Like `key-description' but add face for \"*Help*\" buffers. ...
      ;; Return nil if KEYS is nil." Both properties, as the C's comment
      ;; says - "the only way to get this to work reliably in any
      ;; buffer".
      ;;--------------------------------------------------------------
      (and keys
           (propertize (key-description keys (and (pair? rest) (car rest)))
                       'font-lock-face 'help-key-binding
                       'face 'help-key-binding)))

    ;;----------------------------------------------------------------
    ;; `substitute-command-keys' (help.el:1435)
    ;;----------------------------------------------------------------

    (define (substitute-command-keys string . rest)
      ;; GNU Emacs's `substitute-command-keys' (`help.el:1435'):
      ;; "Substitute key descriptions for command names in STRING. Each
      ;; substring of the form \\[COMMAND] is replaced by either a
      ;; keystroke sequence that invokes COMMAND, or \"M-x COMMAND\" if
      ;; COMMAND is not on any keys. ... Each grave accent \\=` is
      ;; replaced by left quote, and each apostrophe \\=' is replaced by
      ;; right quote. ... \\== quotes the following character and is
      ;; discarded."
      ;;
      ;; The C's cases, in its order: 1A `\=` at end, 1B `\=` quoting
      ;; the next character, 1C `\`KEY'', 1D `\[COMMAND]', 1E `\{MAP}'
      ;; and `\<MAP>' (not carried - see the header), then the two
      ;; quote rules and the ordinary step. The buffer the C edits is
      ;; made here, with the user's buffer remembered for
      ;; `where-is-internal`'s benefit.
      ;;--------------------------------------------------------------
      (let ((no-face (and (pair? rest) (car rest)))
            (include-menus (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            ;; Emacs's `(let ((keymap overriding-local-map)) ...)`.
            (keymap (*overriding-local-map*)))
        (if (not string)
            string
            (let ((orig-buf (current-buffer)))
              (parameterize ((*current-buffer* (allocate-buffer)))
                (insert string)
                (goto-char (point-min))
                (let loop ()
                  (when (< (point) (point-max))
                    (let ((orig-point (point))
                          (end-point #f))
                      (cond
                       ;; 1. A backslash: 1A-1E.
                       ((char=? (char-after (point)) #\\)
                        (forward-char 1)
                        (let ((c (char-after (point))))
                          (cond
                           ;; 1A. `\=` at end of string.
                           ((and c (char=? c #\=)
                                 (= (+ (point) 1) (point-max)))
                            (forward-char 1))
                           ;; 1B. `\=` quotes the next character.
                           ((and c (char=? c #\=))
                            (goto-char orig-point)
                            (delete-region (point) (+ (point) 2))
                            (forward-char 1))
                           ;; 1C. `\`KEY'' is replaced by the fontified
                           ;; KEY, when KEY names a key; otherwise the
                           ;; backtick is left for the quote rule.
                           ((and c (char=? c #\`)
                                 (save-match-data
                                   (let ((at (save-excursion
                                               (search-forward "'" #f #t))))
                                     (when at
                                       (set! end-point (- at 1))
                                       #t))))
                            (let ((k (buffer-substring-no-properties
                                      (+ orig-point 2) end-point)))
                              (when (or (key-valid-p k)
                                        (string-match-p "\\`mouse-[1-9]" k)
                                        (string-match-p "\\`M-x " k))
                                (goto-char orig-point)
                                (delete-region (point) (+ (point) 2))
                                (goto-char (- end-point 2))
                                (delete-region (point) (+ (point) 1))
                                (unless no-face
                                  (add-text-properties
                                   orig-point (point)
                                   (list 'face 'help-key-binding
                                         'font-lock-face 'help-key-binding))))))
                           ;; 1D. `\[COMMAND]' is replaced by its key
                           ;; description, or "M-x COMMAND".
                           ((and c (char=? c #\[)
                                 (save-match-data
                                   (let ((at (save-excursion
                                               (search-forward "]" #f #t))))
                                     (when at
                                       (set! end-point (- at 2))
                                       #t))))
                            (goto-char orig-point)
                            (delete-region (point) (+ (point) 2))
                            (let* ((fun (string->symbol
                                         (buffer-substring-no-properties
                                          (point) (- end-point 1))))
                                   (key (parameterize ((*current-buffer* orig-buf))
                                          (where-is-internal
                                           fun (and keymap (list keymap))
                                           #t #f #f))))
                              ;; "If we're looking in a particular keymap
                              ;; which has no binding, then we need to
                              ;; redo the lookup, with the global map as
                              ;; well this time."
                              (when (and (not key) keymap)
                                (set! key (parameterize ((*current-buffer* orig-buf))
                                            (where-is-internal fun keymap #t #f #f))))
                              (if (not key)
                                  ;; "Function is not on any key."
                                  (let ((op (point)))
                                    (insert "M-x ")
                                    (goto-char (+ end-point 3))
                                    (unless no-face
                                      (add-text-properties
                                       op (point)
                                       (list 'face 'help-key-binding
                                             'font-lock-face 'help-key-binding)))
                                    (delete-region (point) (+ (point) 1)))
                                  (begin
                                    (delete-region (point) end-point)
                                    (insert
                                     (if no-face
                                         (key-description key)
                                         (help--key-description-fontified key)))))))
                           ;; 1E. `\{NAME}' is replaced with a
                           ;; summary of the keymap NAME, and `\<NAME>'
                           ;; sets the keymap `\[COMMAND]' is looked up
                           ;; in.
                           ;;
                           ;; **The name is resolved from the keymap's
                           ;; label**, because a Scheme binding cannot be
                           ;; reached from a symbol; `keymap-by-name`'s
                           ;; note says what that means and which
                           ;; spellings work.
                           ((and c (or (char=? c #\{) (char=? c #\<))
                                 (save-match-data
                                   (let ((at (save-excursion
                                               (search-forward
                                                (if (char=? c #\{) "}" ">")
                                                #f #t))))
                                     (when at
                                       (set! end-point (- at 2))
                                       #t))))
                            (goto-char orig-point)
                            (delete-region (point) (+ (point) 2))
                            (let* ((name (string->symbol
                                          (buffer-substring-no-properties
                                           (point) (- end-point 1))))
                                   (this-keymap (keymap-by-name name)))
                              (delete-region (point) end-point)
                              (cond
                               ((not this-keymap)
                                (insert "\nUses keymap ")
                                (insert (substitute-quotes "`"))
                                (insert (symbol->string name))
                                (insert (substitute-quotes "'"))
                                (insert ", which is not currently defined.\n")
                                (when (char=? c #\<)
                                  (set! keymap #f)))
                               ((char=? c #\<)
                                (set! keymap this-keymap))
                               (else
                                ;; "Get the list of active keymaps that
                                ;; precede this one. If this one's not
                                ;; active, get nil."
                                (let ((r (memq this-keymap
                                               (reverse (lookup-keymaps)))))
                                  (help--describe-map-tree
                                   this-keymap #t
                                   (and r (reverse (cdr r)))
                                   #f #f (not include-menus) #f #f #t))))))
                           (else #f))))
                       ;; 2. Quotes, under `curve' and `straight'.
                       ((and (eq? (text-quoting-style) 'curve)
                             (or (and (char=? (char-after (point)) #\`)
                                      (begin (insert "‘") #t))
                                 (and (char=? (char-after (point)) #\')
                                      (begin (insert "’") #t))))
                        ;; `insert` leaves point after the quote; the
                        ;; backtick/apostrophe is now the character at
                        ;; point, and that is the `(delete-char 1)`.
                        (delete-region (point) (+ (point) 1)))
                       ((and (eq? (text-quoting-style) 'straight)
                             (char=? (char-after (point)) #\`))
                        (insert "'")
                        (delete-region (point) (+ (point) 1)))
                       ;; 3. Nothing to do - next character.
                       (else (forward-char 1))))
                    (loop)))
                (buffer-string))))))
    ;;----------------------------------------------------------------
    ;; The help buffer - `help-buffer', `help-setup-xref',
    ;; `help--window-setup' (help-mode.el and help.el)
    ;;----------------------------------------------------------------

    (define *help-mode-function* (make-parameter #f))
    ;; ^ `help-mode' is `help-mode.el`'s, and help-mode.el requires
    ;; help.el - so the mode is *above* this library and arrives through
    ;; a seam, exactly as Emacs reaches it through an autoload.
    ;; `help-mode.scm' installs it as it loads.

    (define *help-xref-stack-item* #f)
    ;; ^ `help-xref-stack-item' (`help-mode.el:496`). The xref stacks
    ;; themselves are not carried - there are no buttons and no
    ;; `help-follow' - so what `help-setup-xref' can do here is the part
    ;; that re-enables the major mode and records the item.

    (define *help-xref-following* #f)
    ;; ^ `help-xref-following': whether the *Help* buffer is being
    ;; reused by a following command. Nothing here sets it (that is the
    ;; xref machinery's), but `help-buffer' reads it, as the Lisp does.

    (define (%help-arg args n)
      ;; The Nth optional argument of an Emacs DEFUN spelled as a rest
      ;; list, or #f. Every reader below takes its optional arguments
      ;; explicitly, which is this tree's convention.
      ;;--------------------------------------------------------------
      (let loop ((rest args) (i 0))
        (cond ((null? rest) #f)
              ((= i n) (car rest))
              (else (loop (cdr rest) (+ i 1))))))

    (define (help-buffer)
      ;; GNU Emacs's `help-buffer' (`help-mode.el:527`): "Return the
      ;; name of a buffer for inserting help. If `help-xref-following'
      ;; is non-nil and the current buffer is derived from `help-mode',
      ;; this is the name of the current buffer. Otherwise, return
      ;; \"*Help*\", creating a buffer with that name if it does not
      ;; already exist."
      ;;--------------------------------------------------------------
      (buffer-name
       ;; `help-xref-following` is a plain variable here - Emacs
       ;; `setq`s it, nothing `let`-binds it - so it is read, not called.
       (if (and *help-xref-following* (derived-mode-p 'help-mode))
           (current-buffer)
           (get-buffer-create "*Help*"))))

    (define (help-setup-xref item interactive-p)
      ;; GNU Emacs's `help-setup-xref' (`help-mode.el:496`): "Invoked
      ;; from commands using the \"*Help*\" buffer to install some xref
      ;; info. ... This function also re-enables the major mode of the
      ;; buffer, thus resetting local variables to the values set by the
      ;; mode and running the mode hooks."
      ;;
      ;; The stack half is the xref machinery's and is not carried.
      ;;--------------------------------------------------------------
      (with-current-buffer (help-buffer)
        (when (*help-mode-function*)
          ((*help-mode-function*)))
        (set! *help-xref-stack-item* item))
      #f)

    (define (help--window-setup buffer-or-name callback)
      ;; GNU Emacs's `help--window-setup' (`help.el:2254`), which
      ;; `with-help-window` expands to: make the help buffer, put it in
      ;; help mode, empty it, run the body with it current, and show it
      ;; in a window.
      ;;
      ;; **Not carried**: `help-window-point-marker`,
      ;; `temp-buffer-window-setup-hook`, `help-make-xrefs` (no buttons
      ;; here), `buffer-disable-undo` (undo is not on in a fresh buffer
      ;; here) and `help-window-setup`'s reselection rules. The display
      ;; is `display-buffer`, which is where `temp-buffer-window-show`
      ;; ends, and it does not select the window.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer-create buffer-or-name)))
        (with-current-buffer buffer
          (unless (derived-mode-p 'help-mode)
            (when (*help-mode-function*)
              ((*help-mode-function*))))
          (set!buffer-read-only buffer #t)
          ;; "`(let ((inhibit-read-only t)) (erase-buffer) ...)`: the
          ;; binding wraps the *body* too - Emacs's own nesting - so a
          ;; help command inserts into a read-only help buffer.
          (parameterize ((*inhibit-read-only* #t))
            (erase-buffer)
            (delete-all-overlays buffer)
            (callback)))
        ;; `temp-buffer-window-show`'s tail (`window.el:113`), which is
        ;; what `help-window-setup` ends at: the buffer unmodified and
        ;; read-only, point at the top *before* the display (so the new
        ;; window's own point is the top), then the display and the
        ;; window's hscroll reset.
        (with-current-buffer buffer
          (set-buffer-modified-p #f)
          (goto-char (point-min)))
        (let ((window (display-buffer buffer)))
          (when window
            (set-window-hscroll! window 0)))
        #f))

    (define-syntax with-help-window
      ;; GNU Emacs's `with-help-window' (`help.el:2230`).
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ buffer-or-name body ...)
         (help--window-setup buffer-or-name
                             (lambda () body ...)))))

    ;;----------------------------------------------------------------
    ;; Describing keymaps - `describe-map' and the tree above it
    ;;----------------------------------------------------------------

    (define *help--keymaps-seen* '())
    ;; ^ `help--keymaps-seen' (`help.el:1632`): the maps the tree walk
    ;; has already listed, so a map reached twice is described once.

    (define-custom *describe-bindings-show-prefix-commands* #f
      "Non-nil means show prefix commands in the output of `describe-bindings'."
      :type 'boolean
      :group 'help)

    (define (help-fns-function-name function)
      ;; GNU Emacs's `help-fns-function-name' (`help-fns.el:2553`):
      ;; "Return a short buttonized string representing FUNCTION."
      ;;
      ;; **The button is not carried** - there is no xref machinery - so
      ;; the answer is the plain name. The arms are this tree's shapes: a
      ;; keymap's binding is a procedure or a command record, never a
      ;; subr, so the name comes from the command's record and otherwise
      ;; from Guile's `procedure-name'.
      ;;--------------------------------------------------------------
      (cond
       ((symbol? function) (symbol->string function))
       ((command-type? function) (command-name function))
       ((procedure? function)
        (let ((record (command-record-of function)))
          (if record
              (command-name record)
              (let ((name (procedure-name function)))
                (if name
                    (string-append "#<procedure " (symbol->string name) ">")
                    "#<procedure>")))))
       (else (format "%s" function))))

    (define (help--describe-command definition transl)
      ;; GNU Emacs's `help--describe-command' (`help.el:1742`).
      ;;
      ;; `char-to-name` - `mule-cmds.el`'s, which needs the Unicode name
      ;; table - is not carried, so the translation branch prints the
      ;; key description alone where Emacs adds a tab and the name.
      ;;--------------------------------------------------------------
      (cond ((or (string? definition) (vector? definition))
             (if transl
                 (begin
                   (insert (key-description definition '()))
                   (insert "\n"))
                 ;; "These should be rare nowadays, replaced by
                 ;; `kmacro's."
                 (insert "Keyboard Macro\n")))
            ((keymapp definition)
             (insert "Prefix Command\n"))
            (else
             (insert (help-fns-function-name definition))
             (insert "\n"))))

    (define (help--describe-map-compare a b)
      ;; GNU Emacs's `help--describe-map-compare' (`help.el:1758`):
      ;; "Sort the keystroke names in the \"natural\" way, with (for
      ;; instance) \"<f2>\" coming between \"<f1>\" and \"<f11>\"."
      ;;--------------------------------------------------------------
      (let ((a (car a))
            (b (car b)))
        (cond ((and (integer? a) (integer? b)) (< a b))
              ((and (integer? a) (not (integer? b))) #t)
              ((and (symbol? a) (symbol? b))
               (string-version-lessp (symbol->string a) (symbol->string b)))
              (else #f))))

    (define (help--shadow-lookup keymap key accept-default remap)
      ;; GNU Emacs's `help--shadow-lookup' (`help.el:1725`): "Like
      ;; `lookup-key', but with command remapping."
      ;;
      ;; The remap arm is Emacs's for a *symbol* definition; this
      ;; tree's definitions are procedures and command records, so the
      ;; arm is as dead here as it is for a lambda in Emacs. It is
      ;; carried because `where-is' and `describe-key' are the callers
      ;; that set REMAP.
      ;;--------------------------------------------------------------
      (let ((value (lookup-key keymap key accept-default)))
        (cond ((and (integer? value) (>= value 0)) value)
              ((and value remap (symbol? value))
               (or (command-remapping value) value))
              (else value))))

    (define (describe-map map . rest)
      ;; GNU Emacs's `describe-map' (`help.el:1770`): "Describe the
      ;; contents of keymap MAP. Assume that this keymap itself is
      ;; reached by the sequence of prefix keys PREFIX (a string or
      ;; vector). TRANSL, PARTIAL, SHADOW, NOMENU, MENTION-SHADOW and
      ;; BUFFER are as in `help--describe-map-tree'."
      ;;
      ;; **The C's vector half has no counterpart here**: Emacs keeps
      ;; ordinary characters in a map's char-table or vector and walks
      ;; them with `help--describe-vector' (`keymap.c:3074'); every
      ;; binding, characters included, is a sparse entry in this tree's
      ;; keymap record, so the sparse walk below covers all of them. The
      ;; vector half's shadow and `entire-map` tests are the same two
      ;; rules this walk applies.
      ;;--------------------------------------------------------------
      (let* ((prefix (%help-arg rest 0))
             (transl (%help-arg rest 1))
             (partial (%help-arg rest 2))
             (shadow (%help-arg rest 3))
             (nomenu (%help-arg rest 4))
             (mention-shadow (%help-arg rest 5))
             (buffer (%help-arg rest 6))
             (map (keymap-canonicalize map))
             (vect '())
             (columns '()))
        ;; "Ignore bindings whose \"prefix\" are not really valid events.
        ;; (We get these in the frames and buffers menu.)"
        (let walk ((events (keymap-order map)))
          (unless (null? events)
            (let* ((event (car events))
                   (definition (get-keyelt
                                (hashv-ref (keymap-bindings map) event #f) #f))
                   (this-shadowed #f))
              (when (or (symbol? event) (integer? event))
                (unless (and nomenu (eq? event 'menu-bar))
                  (when (or (not (symbol? definition))
                            (not (get definition 'suppress-keymap)))
                    (when (or (not shadow) (null? shadow)
                              (let ((tem (help--shadow-lookup
                                          shadow (vector event) #t #f)))
                                (cond ((not tem) #t)
                                      ((and (keymapp definition) (keymapp tem)) #t)
                                      ((and mention-shadow
                                            (not (eq? tem definition)))
                                       (set! this-shadowed #t)
                                       #t)
                                      (else #f))))
                      (when (eq? definition
                                 (lookup-key map (vector event) #t))
                        (set! vect (cons (list event definition this-shadowed)
                                         vect))))))))
            (walk (cdr events))))
        ;; "If we found some sparse map events, sort them."
        (let ((vect (sort vect help--describe-map-compare))
              (line-start #f)
              (key-end #f)
              (column #f))
          (let loop ((vect vect) (first #t))
            (unless (null? vect)
              (let* ((elem (car vect))
                     (start (list-ref elem 0))
                     (definition (list-ref elem 1))
                     (shadowed (list-ref elem 2))
                     (end start)
                     (remapped #f))
                ;; "Find consecutive chars that are identically defined."
                (when (integer? start)
                  (let merge ()
                    (when (and (pair? (cdr vect))
                               (let ((this (car vect))
                                     (next (cadr vect)))
                                 (and (eqv? (car next) (+ (car this) 1))
                                      (equal? (cadr next) (cadr this))
                                      (eq? (caddr next) (caddr this)))))
                      (set! vect (cdr vect))
                      (set! end (car (car vect)))
                      (merge))))
                (when (or (not (eqv? start end))
                          (*describe-bindings-show-prefix-commands*)
                          ;; "Don't output keymap prefixes."
                          (not (keymapp definition)))
                  (when first
                    (insert "\n")
                    (set! first #f))
                  (set! line-start (point))
                  ;; "If we're in a <remap> section of the output, then
                  ;; also display the bindings of the keys that we've
                  ;; remapped from."
                  (set! remapped
                        (and (equal? prefix (vector 'remap))
                             (not (eq? definition self-insert-command))
                             (let ((keys (where-is-internal definition #f #f #f #f)))
                               (and (pair? keys) (car keys)))))
                  (if remapped
                      (insert (help--key-description-fontified
                               (vector (list-ref remapped
                                                 (- (length remapped) 1)))
                               (list->vector
                                (reverse (cdr (reverse
                                               (if (vector? remapped)
                                                   (vector->list remapped)
                                                   remapped)))))))
                      (insert (help--key-description-fontified
                               (vector start) prefix)))
                  (when (not (eqv? start end))
                    (insert " .. ")
                    (insert (help--key-description-fontified (vector end)
                                                             prefix)))
                  (set! key-end (point))
                  (set! column (current-column))
                  ;; "Print a description of the definition of this
                  ;; character."
                  (help--describe-command definition transl)
                  (set! columns
                        (cons (list column line-start key-end (- (point) 1))
                              columns))
                  (when (or shadowed remapped)
                    (goto-char (max (- (point) 1) (point-min)))
                    (when shadowed
                      (insert "\n  (this binding is currently shadowed)"))
                    (when remapped
                      (insert "\n  (Remapped via ")
                      (insert (help--key-description-fontified
                               (vector start) prefix))
                      (insert ")"))
                    (goto-char (min (+ (point) 1) (point-max)))))
                (loop (cdr vect) first))))
          (when (pair? columns)
            (describe-map--align-section columns)))))

    (define (describe-map--fill-columns columns width)
      ;; GNU Emacs's `describe-map--fill-columns' (`help.el:1948`): pad
      ;; each key column out to WIDTH with tabs and spaces, in tab-width
      ;; units.
      ;;--------------------------------------------------------------
      (for-each
       (lambda (elem)
         (goto-char (list-ref elem 2))
         (let ((tabs (- (/ width (*tab-width*))
                        (/ (car elem) (*tab-width*)))))
           (insert-char #\tab tabs)
           (insert-char #\space
                        (if (zero? tabs)
                            (- width (car elem))
                            (modulo width (*tab-width*))))))
       columns))

    (define (describe-map--align-section columns)
      ;; GNU Emacs's `describe-map--align-section' (`help.el:1919`):
      ;; pick the column block width for this section, or fall back to
      ;; continuation lines when a definition is too wide for the window.
      ;;
      ;; `(window-width)` in the Lisp is the *body* width in columns;
      ;; this tree's `window-width` is the window record's slot
      ;; accessor, so the call is `window-body-width` here.
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((max-key (apply max (map car columns))))
          (cond
           ((< max-key 16) (describe-map--fill-columns columns 16))
           ((< max-key 24) (describe-map--fill-columns columns 24))
           ((< max-key 32) (describe-map--fill-columns columns 32))
           (else
            ;; "We have some really wide ones in this block."
            (let ((window-width (window-body-width (selected-window)))
                  (max-def (apply max
                                  (map (lambda (elem)
                                         (- (list-ref elem 3)
                                            (list-ref elem 2)))
                                       columns))))
              (if (< (+ max-def (max 16 max-key)) window-width)
                  ;; "Can we do the block without continuation lines?
                  ;; Then do that."
                  (describe-map--fill-columns columns (+ 1 (max 16 max-key)))
                  ;; "No, do continuation lines for some definitions."
                  (for-each
                   (lambda (elem)
                     (goto-char (list-ref elem 2))
                     (if (< (+ (car elem)
                               (- (list-ref elem 3) (list-ref elem 2)))
                            window-width)
                         (insert-char #\space (- (+ 1 max-key) (car elem)))
                         ;; "Continuation."
                         (begin
                           (insert "\n")
                           (insert-char #\tab 2))))
                   columns))))))))

    (define (%help--menu-bar-prefix? prefix)
      ;; `help--describe-map-tree`'s "element that is for the menu bar":
      ;; a prefix whose first event is `menu-bar`.
      ;;--------------------------------------------------------------
      (and (vector? prefix)
           (>= (vector-length prefix) 1)
           (eq? (vector-ref prefix 0) 'menu-bar)))

    (define (help--describe-map-tree startmap . rest)
      ;; GNU Emacs's `help--describe-map-tree' (`help.el:1638`):
      ;; "Insert a description of the key bindings in STARTMAP. ...
      ;; PARTIAL omits certain uninteresting commands ... SHADOW is a
      ;; list of maps ... PREFIX ... TITLE ... NO-MENU ... TRANSL ...
      ;; ALWAYS-TITLE ... MENTION-SHADOW ... BUFFER."
      ;;--------------------------------------------------------------
      (let* ((partial (%help-arg rest 0))
             (shadow (%help-arg rest 1))
             (prefix (%help-arg rest 2))
             (title (%help-arg rest 3))
             (no-menu (%help-arg rest 4))
             (transl (%help-arg rest 5))
             (always-title (%help-arg rest 6))
             (mention-shadow (%help-arg rest 7))
             (buffer (%help-arg rest 8))
             (amaps (accessible-keymaps startmap prefix))
             (orig-maps
              (if no-menu
                  ;; "Delete from MAPS each element that is for the menu
                  ;; bar."
                  (let collect ((tail amaps) (result '()))
                    (cond ((null? tail) (reverse result))
                          ((%help--menu-bar-prefix? (car (car tail)))
                           (collect (cdr tail) result))
                          (else (collect (cdr tail) (cons (car tail) result)))))
                  amaps))
             (maps orig-maps)
             (print-title (or (pair? maps) always-title))
             (start-point (point)))
        ;; "Describe key bindings."
        (set! *help--keymaps-seen* '())
        (let loop ((maps maps))
          (unless (null? maps)
            (let* ((elt (car maps))
                   (elt-prefix (car elt))
                   (sub-shadows (lookup-key shadow elt-prefix #t)))
              (when (if (and (integer? sub-shadows) (>= sub-shadows 0))
                        (begin (set! sub-shadows #f) #t)
                        ;; "Describe this map iff ELT_PREFIX is bound to
                        ;; a keymap, since otherwise it completely
                        ;; shadows this map."
                        (or (keymapp sub-shadows)
                            (null? sub-shadows)
                            (not sub-shadows)
                            (and (pair? sub-shadows)
                                 (keymapp (car sub-shadows)))))
                ;; "Maps we have already listed in this loop shadow this
                ;; map."
                (let scan ((tail orig-maps))
                  (unless (eq? tail maps)
                    (when (equal? (car (car tail)) elt-prefix)
                      (set! sub-shadows
                            (cons (cdr (car tail)) sub-shadows)))
                    (scan (cdr tail))))
                (describe-map (cdr elt) elt-prefix transl partial
                              sub-shadows no-menu mention-shadow
                              buffer)))
            (loop (cdr maps))))
        ;; "Print title... unless the keymap was empty."
        (when (and print-title (not (= (point) start-point)))
          (save-excursion
            (goto-char start-point)
            (when (eolp)
              (delete-region (point) (+ (point) 1)))
            (insert
             (string-append
              (if title
                  (string-append title
                                 (if prefix
                                     (string-append
                                      " Starting With "
                                      (help--key-description-fontified prefix))
                                     "")
                                 ":\n")
                  "")
              "\nKey             Binding\n"
              (make-separator-line)))))
        #f))

    (define (describe-buffer-bindings buffer . rest)
      ;; GNU Emacs's `describe-buffer-bindings' (`keymap.c:2834'):
      ;; "Insert the list of all defined keys and their definitions. The
      ;; list is inserted in the current buffer, while the bindings are
      ;; looked up in BUFFER."
      ;;
      ;; **A placement departure**: the C has this in keymap.c, but its
      ;; whole body is calls to `help--describe-map-tree` plus the buffer
      ;; state each section shows, so it lives here beside that
      ;; function.
      ;;
      ;; **Not carried**: the keyboard-translate-table report (there is
      ;; no such table here) and the `key-translation-map` /
      ;; `input-decode-map` sections - the first is not ported, and the
      ;; second belongs to the *terminal* library, which no editor
      ;; library may import. `local-function-key-map` is an alist of
      ;; translations here (`*function-key-map*`), not a keymap, so it
      ;; has nothing `help--describe-map-tree` can walk.
      ;;--------------------------------------------------------------
      (let* ((prefix (%help-arg rest 0))
             (menus (%help-arg rest 1))
             (nomenu (not menus))
             (shadow '()))
        (define (section! title map partial transl always-title)
          (help--describe-map-tree map partial shadow prefix title nomenu
                                   transl always-title #f buffer)
          (set! shadow (cons map shadow)))
        ;; `*overriding-terminal-local-map*` is a plain variable here -
        ;; its comment says why (a kboard slot with no dynamic binding of
        ;; its own) - and `*overriding-local-map*` is a parameter.
        (let ((overriding *overriding-terminal-local-map*))
          (cond
           (overriding
            (section! "\f\nOverriding Bindings" overriding #t #f #f))
           ((*overriding-local-map*)
            (section! "\f\nOverriding Bindings" (*overriding-local-map*)
                      #t #f #f))
           (else
            ;; "Print the `keymap' property bindings."
            (let ((prop (get-local-map (buffer-pt buffer) buffer 'keymap)))
              (when prop
                (section! "\f\n`keymap' Property Bindings" prop #t #f #f)))
            ;; "Print the minor mode maps."
            (for-each
             (lambda (entry)
               (let ((mode (car entry))
                     (map (cdr entry)))
                 (when (and map (buffer-local-value buffer mode #f))
                   (section! (string-append "\f\n`"
                                            (symbol->string mode)
                                            "' Minor Mode Bindings")
                             map #t #f #f))))
             (*minor-mode-map-alist*))
            ;; "Print the (major mode) local map."
            (let ((map (get-local-map (buffer-pt buffer) buffer 'local-map)))
              (when map
                (if (eq? map (buffer-local-keymap buffer))
                    (section! (string-append
                               "\f\n`"
                               (symbol->string
                                (buffer-local-value buffer 'major-mode
                                                    'fundamental-mode))
                               "' Major Mode Bindings")
                              map #t #f #f)
                    (section! "\f\n`local-map' Property Bindings"
                              map #t #f #f)))))))
        (section! "\f\nGlobal Bindings" *default-keymap* #t #f #t)
        #f))

    (define-command (describe-bindings . rest)
      ;; GNU Emacs's `describe-bindings' (`help.el:849`): "Display a
      ;; buffer showing a list of all defined keys, and their
      ;; definitions. The keys are displayed in order of precedence."
      ;;--------------------------------------------------------------
      "Display a buffer showing a list of all defined keys, and their definitions.
The keys are displayed in order of precedence.

The optional argument PREFIX, if non-nil, should be a key sequence;
then we display only bindings that start with that prefix.
The optional argument BUFFER specifies which buffer's bindings
to display (default, the current buffer).  BUFFER can be a buffer
or a buffer name."
      (interactive)
      (let ((prefix (%help-arg rest 0))
            (buffer (%help-arg rest 1)))
        (unless buffer (set! buffer (current-buffer)))
        (help-setup-xref (list describe-bindings prefix buffer)
                         (called-interactively? describe-bindings))
        (with-help-window (help-buffer)
          (with-current-buffer (help-buffer)
            (describe-buffer-bindings buffer prefix)
            ;; `describe-bindings-outline` and its outline-mode setup
            ;; are not carried - this tree has no outline-mode - and
            ;; with them the hiding of the ^L section separators.
            #f))
        #f))

    ;; `help-map` (`help.el:62`) and the keys this tree can back. Emacs
    ;; hangs it off `C-h` as a prefix map; this tree's lookup takes the
    ;; flat spellings, which is the standing departure `narrow-map` and
    ;; `mule-keymap` record. The rest of `help-map`'s entries name
    ;; commands this tree does not have yet; each belongs here when it
    ;; lands.
    (define help-map (make-sparse-keymap "Help"))
    (define-key help-map (kbd "b") describe-bindings)
    (define-key *default-keymap* (kbd "C-h b") describe-bindings)

    ;;----------------------------------------------------------------
    ;; `describe-key' and the analysis under it (`help.el:952-1188')
    ;;----------------------------------------------------------------

    (define *describe-function-1-function* (make-parameter #f))
    ;; ^ `describe-function-1' is `help-fns.el`'s and that library is
    ;; *above* this one, so `describe-key` reaches it through a seam -
    ;; Emacs reaches it the same way, through help-fns's autoload.
    ;; `help-fns.scm` installs it as it loads.

    (define (help--binding-undefined-p defn)
      ;; GNU Emacs's `help--binding-undefined-p' (`help.el:963`):
      ;; "A key's definition is undefined when it is nil, a number (the
      ;; `lookup-key' 'too long' answer) or `undefined' itself."
      ;;--------------------------------------------------------------
      (or (not defn) (integer? defn) (eq? defn undefined)))

    (define (help-key-description key untranslated)
      ;; GNU Emacs's `help-key-description' (`help.el:952`): the key's
      ;; description, and "(translated from ...)" when the untranslated
      ;; sequence differs.
      ;;
      ;; `char-to-name` - the branch that names a single translated
      ;; character - is not carried: it needs the Unicode name table
      ;; (`mule-cmds.el`).
      ;;--------------------------------------------------------------
      (let ((string (help--key-description-fontified key)))
        (if (or (not untranslated)
                (let ((u (keymap-index untranslated))
                      (k (keymap-index key)))
                  (and u k
                       (eqv? (car u) #\escape)
                       (not (eqv? (car k) #\escape)))))
            string
            (let ((otherstring (help--key-description-fontified untranslated)))
              (if (equal? string otherstring)
                  string
                  (format "%s (translated from %s)" string otherstring))))))

    (define (help--analyze-key key untranslated buffer)
      ;; GNU Emacs's `help--analyze-key' (`help.el:966`): "Get
      ;; information about KEY its corresponding UNTRANSLATED events.
      ;; Returns a list of the form (BRIEF-DESC DEFN EVENT MOUSE-MSG)."
      ;;
      ;; The C's surgery on the last event - a string event replaced by
      ;; "(any string)" so the user is not shown a pasted menu entry's
      ;; text - is not carried: this tree's menus have no such entries.
      ;;--------------------------------------------------------------
      (let* ((events (keymap-index key))
             (event (and (pair? events)
                         (if (and (symbol? (car events))
                                  (pair? (cdr events))
                                  (pair? (cadr events)))
                             ;; "Look at the second event when the first
                             ;; is a pseudo-event like `mode-line' or
                             ;; `left-fringe'."
                             (cadr events)
                             (car events))))
             (modifiers (if event (event-modifiers event) '()))
             (mouse-msg (if (or (memq 'click modifiers) (memq 'down modifiers)
                                (memq 'drag modifiers))
                            " at that spot"
                            ""))
             (click-pos (and event (event-end event)))
             (defn (if (or buffer (not (pair? click-pos)))
                       (key-binding key #t)
                       (save-excursion
                         (posn-set-point click-pos)
                         (key-binding key #t))))
             (key-desc (help-key-description key untranslated)))
        (list
         (if (help--binding-undefined-p defn)
             (format "%s%s is undefined" key-desc mouse-msg)
             (format "%s%s runs the command %s" key-desc mouse-msg
                     (help-fns-function-name defn)))
         defn event mouse-msg)))

    (define (help--filter-info-list info-list i)
      ;; GNU Emacs's `help--filter-info-list' (`help.el:1015`): "Drop
      ;; the undefined keys." Answers the last one when that leaves
      ;; nothing, so the caller still has something to report.
      ;;--------------------------------------------------------------
      (let ((kept (let loop ((rest info-list) (acc '()))
                    (cond ((null? rest) (reverse acc))
                          ((help--binding-undefined-p (list-ref (car rest) i))
                           (loop (cdr rest) acc))
                          (else (loop (cdr rest) (cons (car rest) acc)))))))
        (if (pair? kept) kept (list (car (reverse info-list))))))

    (define-command (describe-key key-list . rest)
      ;; GNU Emacs's `describe-key' (`help.el:1197`): "Display
      ;; documentation of the function invoked by KEY-LIST."
      ;;
      ;; KEY-LIST is a list of `(SEQ . RAW-SEQ)'. The interactive spec
      ;; reads one sequence with `read-key-sequence` - Emacs's
      ;; `help--read-key-sequence` also reads menus and mouse events
      ;; with the disabled ones enabled; that half is not carried.
      ;;--------------------------------------------------------------
      "Display documentation of the function invoked by KEY-LIST.
KEY-LIST can be any kind of a key sequence; it can include keyboard events,
mouse events, and/or menu events.  When calling from a program,
pass KEY-LIST as a list of elements (SEQ . RAW-SEQ) where SEQ is
a key-sequence and RAW-SEQ is its untranslated form.

BUFFER is the buffer in which to lookup those keys; it defaults to
the current buffer."
      (interactive (list (list (cons (read-key-sequence
                                     "Describe the following key, mouse click, or menu item: ")
                                     #f))))
      (let* ((buffer (or (%help-arg rest 0) (current-buffer)))
             (info-list
              (help--filter-info-list
               (map (lambda (x)
                      (let* ((seq (if (pair? x) (car x) x))
                             (raw (if (pair? x) (cdr x) #f))
                             (analysis (help--analyze-key seq raw buffer)))
                        (list seq (list-ref analysis 0) (list-ref analysis 1) #f)))
                    key-list)
               2)))
        (help-setup-xref (list describe-key key-list buffer)
                         (called-interactively? describe-key))
        (if (and (<= (length info-list) 1)
                 (help--binding-undefined-p (list-ref (car info-list) 2)))
            (message "%s" (list-ref (car info-list) 1))
            (with-help-window (help-buffer)
              (when (> (length info-list) 1)
                (insert "There were several key-sequences:\n\n")
                (let loop ((rest info-list))
                  (unless (null? rest)
                    (insert "  ")
                    (insert (list-ref (car rest) 1))
                    (insert "\n")
                    (loop (cdr rest))))
                (insert "\n\nThey're all described below.\n"))
              (for-each
               (lambda (info)
                 (let ((brief-desc (list-ref info 1))
                       (defn (list-ref info 2)))
                   (when defn
                     (when (> (length info-list) 1)
                       (with-current-buffer (help-buffer)
                         (insert (make-separator-line))))
                     (insert brief-desc)
                     (insert ", which is ")
                     ((*describe-function-1-function*) defn))))
               info-list)
              #f))
        #f))

    (define-key help-map (kbd "k") describe-key)
    (define-key *default-keymap* (kbd "C-h k") describe-key)

    (define-command (describe-key-briefly key-list insert-flag . rest)
      ;; GNU Emacs's `describe-key-briefly' (`help.el:1029'): "Print the
      ;; name of the functions KEY-LIST invokes."
      ;;
      ;; The prompt is `help--read-key-sequence`'s own sentence, which
      ;; `describe-key` uses too; the C's mouse-movement filtering is
      ;; not carried (there are no mouse-movement events without
      ;; `track-mouse`, and the read never returns one).
      ;;--------------------------------------------------------------
      "Print the name of the functions KEY-LIST invokes.
KEY-LIST is a list of pairs (SEQ . RAW-SEQ) of key sequences, where
RAW-SEQ is the untranslated form of the key sequence SEQ.
If INSERT (the prefix arg) is non-nil, insert the message in the buffer."
      (interactive (list (list (cons (read-key-sequence
                                      "Describe the following key, mouse click, or menu item: ")
                                     #f))
                         (current-prefix-arg)))
      ;; **The C's INSERT is `insert-flag` here**: a parameter named
      ;; `insert` would shadow `editfns.scm`'s `insert` in this Lisp-1,
      ;; which is the same renaming `minibuffer-message`'s TEXT took.
      (let ((buffer (%help-arg rest 0)))
        (with-current-buffer (if buffer buffer (current-buffer))
          (let* ((info-list (map (lambda (kr)
                                   (help--analyze-key (car kr) (cdr kr) buffer))
                                 key-list))
                 (msg (string-join
                       (map car (help--filter-info-list info-list 1))
                       "\n")))
            (if insert-flag (insert msg) (message "%s" msg))
            #f))))

    (define-command (where-is definition insert-flag)
      ;; GNU Emacs's `where-is' (`help.el:897'): "Print message listing
      ;; key sequences that invoke the command DEFINITION."
      ;;
      ;; **The alias scan is not carried**: Emacs walks the obarray for
      ;; symbols whose function is DEFINITION's; there is no obarray
      ;; here, and the command table's second names share the same
      ;; record - the day an alias list is exposed this loop comes back.
      ;; The remapping sentence is carried, through
      ;; `command-remapping`.
      ;;--------------------------------------------------------------
      "Print message listing key sequences that invoke the command DEFINITION.
Argument is a command definition, usually a symbol with a function definition.
If INSERT (the prefix arg) is non-nil, insert the message in the buffer."
      (interactive (list (read-command "Where is command: ") (current-prefix-arg)))
      (unless definition (error "No command"))
      (let* ((remapped (and (symbol? definition)
                            (command-remapping definition)))
             (keys (where-is-internal (or remapped definition)
                                      (*overriding-local-map*) #f #f #f))
             (keys-string (string-join
                           (map help--key-description-fontified (or keys '()))
                           ", "))
             (string
              (cond
               ((> (length (or keys '())) 0)
                (if remapped
                    (format "%s is remapped to %s, which is on %s"
                            definition remapped keys-string)
                    (format "%s (%s)" definition keys-string)))
               (else
                (format "M-x %s RET" definition)))))
        (if insert-flag (insert string) (message "%s" string))
        #f))

    (define-key help-map (kbd "c") describe-key-briefly)
    (define-key *default-keymap* (kbd "C-h c") describe-key-briefly)
    (define-key help-map (kbd "w") where-is)
    (define-key *default-keymap* (kbd "C-h w") where-is)

))
