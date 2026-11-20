(define-library (schemacs editor help-fns)
  ;; This library mirrors GNU Emacs's `lisp/help-fns.el' - the
  ;; `describe-function' and `describe-variable' half of the help
  ;; system, which `describe-key' (help.el) is written on top of.
  ;;
  ;; **The data model shapes this port more than any other.** Emacs
  ;; describes *symbols*: a function's arglist, its file, whether it is
  ;; an alias, autoload, macro or subr, and a variable's value and
  ;; buffer-local bindings are all readable from the symbol and its
  ;; function cell. Here a command is a Scheme procedure (or its
  ;; `define-command' record) and a custom variable is a parameter whose
  ;; reader and writer `custom-declare-variable' keeps on the symbol.
  ;; So:
  ;;
  ;;  * **No usage line.** Emacs's `help-fns--signature' prints
  ;;    "(forward-char &optional N)" from the function's arglist, which
  ;;    is in the docstring's own usage section for a Lisp function and
  ;;    in the C for a subr. A Scheme procedure carries neither - Guile's
  ;;    `procedure-name' is a name and nothing else - so the line is
  ;;    omitted. `help-function-arglist' and `help--make-usage-docstring'
  ;;    are not carried for the same reason.
  ;;  * **No file or line.** `find-lisp-object-file-name' and the
  ;;    source-link xref have no counterpart; the header says what kind
  ;;    of object the definition is and nothing about where it is.
  ;;  * **No aliases, autoloads, macros, advised functions, C subrs** -
  ;;    this tree has none of those shapes. The header's arms are its
  ;;    own: a keymap, a keyboard macro, an interactive command, a plain
  ;;    function.
  ;;  * **`describe-variable' describes custom variables.** A variable
  ;;    here is a Scheme binding, and a symbol reaches only the ones
  ;;    `custom-declare-variable' recorded - with their docstring, their
  ;;    standard value and their own reader. A non-custom name gets
  ;;    "Not documented as a variable." and no value.
  ;;  * **Buttons and xrefs are not carried**, so names are plain text.
  ;;
  ;; What *is* carried whole: `help-fns--key-bindings' - the "It is
  ;; bound to ..." paragraph, including the "and many ordinary text
  ;; characters" rule and the `self-insert-command` special case - and
  ;; `ensure-empty-lines' (`subr.el:7914', placed here because the
  ;; `re-search-backward' it needs is above `subr.scm').

  (import
    (scheme base)
    (only (guile) caddr sort string<? logand most-positive-fixnum
          string-join hashv-ref)
    (only (schemacs editor editfns)
          insert point point-min eolp bolp delete-region save-excursion goto-char
          char-before line-beginning-position buffer-string format forward-line
          point-max propertize)
    (only (schemacs editor search) re-search-backward re-search-forward)
    (only (schemacs editor fill) fill-region-as-paragraph fill-paragraph)
    (only (schemacs editor paragraphs) forward-paragraph)
    (only (schemacs editor buffer) buffer-local-value current-buffer
          *current-buffer* with-current-buffer *inhibit-read-only*)
    (only (schemacs editor subr) *minor-mode-alist* *global-minor-modes*
          *minor-mode-list* replace-regexp-in-string
          ;; `mode-line-minor-mode-help` reads the clicked posn's string.
          posn-object event-start intern)
    ;; The `describe-minor-mode` family's three dependencies: the
    ;; indicator lookup and its completion table are `mouse.scm`'s (placed
    ;; there because they are what the mode line evaluates), and the seam
    ;; below is how the generated "Help" menu item reaches
    ;; `describe-function`.
    (only (schemacs editor mouse)
          lookup-minor-mode-from-indicator
          describe-minor-mode-completion-table-for-indicator
          *describe-function-function*)
    (only (schemacs editor casefiddle) capitalize)
    ;; the two steps of a minor mode's indicator, `xdisp.scm`'s
    (only (schemacs editor xdisp) minor-mode-indicator-value
          minor-mode-lighter)
    (only (schemacs editor command)
          define-command command-type? command-name command-record-named
          command-record-of command-procedure called-interactively?
          *command-table*)
    ;; the readers the commands' interactive expressions name - evaluated
    ;; in *this* library's module, so they must be imported here
    (only (schemacs editor minibuffer) read-command read-variable
          completing-read)
    (only (schemacs editor help)
          with-help-window help-buffer help-setup-xref
          help--key-description-fontified help-fns-function-name
          *describe-function-1-function*
          help-map %help-arg *help-xref-stack-item*)
    (only (schemacs editor keyboard)
          where-is-internal command-remapping *overriding-local-map* undefined)
    (only (schemacs editor keymap) keymapp keymap-type? keymap-index
          keymap-bindings lookup-key define-key *default-keymap*)
    (only (schemacs editor character) kbd)
    (only (schemacs editor character) event-modifiers)
    (only (schemacs editor intervals) get)
    (only (schemacs editor doc) documentation documentation-property)
    (only (schemacs editor custom)
          custom-variable-p custom-variable-names custom--standard-value
          define-custom)
    (only (schemacs editor textprop) put-text-property)
    ;; `internal-describe-syntax-value` and `describe-syntax`
    (only (schemacs editor syntax)
          syntax-table syntax-class-to-char
          swhitespace spunct sword ssymbol sopen sclose squote sstring
          smath sescape scharquote scomment sendcomment sinherit
          scomment-fence sstring-fence smax
          %comstart-first? %comstart-second? %comend-first? %comend-second?
          %prefix-flag? %styleb-bit %stylec2 %nested?)
    (only (schemacs editor chartab) char-table? char-table-parent)
    ;; the arrow a menu separator uses when the display can draw it
    (only (schemacs editor mule) char-displayable-p)
    (only (schemacs editor help) substitute-command-keys describe-vector)
    (only (schemacs editor cmds) self-insert-command beginning-of-line)
    (only (schemacs editor simple) make-separator-line))

  (export *describe-mode-outline*
          describe-mode describe-mode--minor-modes
          describe-minor-mode describe-minor-mode-from-symbol
          describe-minor-mode-from-indicator
          describe-minor-mode-completion-table-for-symbol
          mode-line-minor-mode-help
          describe-syntax internal-describe-syntax-value describe-symbol
          describe-function describe-function-1 help-fns--key-bindings
          help-fns--insert-bindings help-fns--insert-menu-bindings
          help-fns--obsolete
          help-fns--ensure-empty-line ensure-empty-lines
          describe-variable)

  (begin

    (define (ensure-empty-lines . rest)
      ;; GNU Emacs's `ensure-empty-lines' (`subr.el:7914'): "Ensure that
      ;; there are LINES number of empty lines before point. ... If point
      ;; is not at the beginning of a line, a newline character is
      ;; inserted before adjusting the number of empty lines."
      ;;
      ;; **A placement departure**: it is `subr.el`'s, but its
      ;; `re-search-backward' is `search.scm`'s and `search.scm` is
      ;; above `subr.scm`.
      ;;--------------------------------------------------------------
      (let ((lines (or (and (pair? rest) (car rest)) 1)))
        (unless (bolp)
          (insert "\n"))
        (let ((start (save-excursion
                       (if (re-search-backward "[^\n]" #f #t)
                           (+ (point) 2)
                           (point-min)))))
          (cond
           ((> (- (point) start) lines)
            (delete-region (point) (- (point) (- (point) start lines))))
           ((< (- (point) start) lines)
            (insert (make-string (- lines (- (point) start)) #\newline)))))
        #f))

    (define (help-fns--ensure-empty-line)
      ;; GNU Emacs's `help-fns--ensure-empty-line' (`help-fns.el:1223`).
      ;;--------------------------------------------------------------
      (unless (eolp) (insert "\n"))
      (unless (eq? #\newline (char-before (- (point) 1))) (insert "\n"))
      #f)

    (define (help-fns--insert-bindings keys)
      ;; GNU Emacs's `help-fns--insert-bindings' (`help-fns.el:577`):
      ;; "C-f, C-b and C-n", with `help-key-binding` on each key.
      ;;--------------------------------------------------------------
      (let ((n (length keys)))
        (let loop ((rest keys) (i 0))
          (unless (null? rest)
            (insert (cond ((zero? i) "")
                          ((= i (- n 1)) " and ")
                          (else ", ")))
            (insert (help--key-description-fontified (car rest)))
            (loop (cdr rest) (+ i 1)))))
      #f)

    (define (%help-fns-split-menu-keys keys)
      ;; `seq-group-by` on `(and (vectorp key) (eq (elt key 0)
      ;; 'menu-bar))` - answers (KEYS . MENUS).
      ;;--------------------------------------------------------------
      (let loop ((rest keys) (keys '()) (menus '()))
        (cond ((null? rest) (cons (reverse keys) (reverse menus)))
              ((and (vector? (car rest))
                    (>= (vector-length (car rest)) 1)
                    (eq? (vector-ref (car rest) 0) 'menu-bar))
               (loop (cdr rest) keys (cons (car rest) menus)))
              (else (loop (cdr rest) (cons (car rest) keys) menus)))))

    (define (%help-fns-modified-key? key)
      ;; The Elisp's `(member (event-modifiers (aref key 0)) '(nil
      ;; (shift)))` - control, meta and the rest count as modified.
      ;;--------------------------------------------------------------
      (let ((mods (if (and (vector? key) (>= (vector-length key) 1))
                      (event-modifiers (vector-ref key 0))
                      '())))
        (not (or (null? mods) (equal? mods '(shift))))))

    (define (%help-fns-menu-binding map entry)
      ;; The raw binding of one menu ENTRY in MAP, or #f - Emacs's
      ;; `(assq entry (cdr map))'. A keymap here is a record whose
      ;; bindings are in a hash, so the *raw* value is read directly:
      ;; `access-keymap' would coerce a `menu-item' to the command it
      ;; runs, and the label this walk prints lives in the list.
      ;;--------------------------------------------------------------
      (let ((events (and (keymap-type? map) (keymap-index entry))))
        (and events
             (hashv-ref (keymap-bindings map) (car events) #f))))

    (define (help-fns--insert-menu-bindings menus heading)
      ;; GNU Emacs's `help-fns--insert-menu-bindings'
      ;; (`help-fns.el:663'): "It can also be invoked from the menu:
      ;; File → Save", one clause per menu, joined by " and ".
      ;;
      ;; **The walk is Emacs's, over this tree's keymap**: `(assq entry
      ;; (cdr map))' is `%help-fns-menu-binding', because the bindings
      ;; are a hash and the label is in the raw binding. An entry is
      ;; either a new-format `(menu-item NAME DEF ...)' list or the old
      ;; `(STRING . SUBMAP)' cons, which is how `menu-bar.scm' binds
      ;; `[menu-bar file]'; Emacs's `proper-list-p' guard is replaced by
      ;; the two shapes' own tests, since the old spelling is improper
      ;; here (its cdr is a keymap record).
      ;;
      ;; **Not carried**: Emacs's `(symbolp map)' arm, which resolves a
      ;; menu bound by a *symbol* through `symbol-function' - a menu
      ;; value here is a keymap record or a command, never a symbol
      ;; naming a keymap.
      ;;--------------------------------------------------------------
      (let ((strings '()))
        ;; "First collect all the printed representations of menus."
        (for-each
         (lambda (menu)
           (let ((map (lookup-key *default-keymap* (vector-ref menu 0)))
                 (string '())
                 (sep (if (char-displayable-p #\→) " → " " => ")))
             (let loop ((entries (cdr (vector->list menu))) (level 0)
                        (map map))
               (unless (null? entries)
                 (let* ((entry (car entries))
                        (raw (%help-fns-menu-binding map entry)))
                   (when (pair? raw)
                     (when (> level 0)
                       (set! string (cons sep string)))
                     (cond
                      ;; `(menu-item NAME DEF ...)' - NAME is RAW's
                      ;; cadr and DEF its caddr (Emacs reads them as
                      ;; `(nth 2 elem)' and `(cadddr elem)', where ELEM is
                      ;; `(entry . raw)').
                      ((and (eq? (car raw) 'menu-item)
                            (pair? (cddr raw)))
                       (set! string
                             (cons (propertize (cadr raw) 'face
                                               'help-key-binding)
                                   string))
                       (set! map (caddr raw)))
                      ;; `("Name" . SUBMAP)' - the old spelling.
                      ((string? (car raw))
                       (set! string
                             (cons (propertize (car raw) 'face
                                               'help-key-binding)
                                   string))
                       (set! map (cdr raw)))
                      (else (set! map #f)))))
                 (loop (cdr entries) (+ level 1) map)))
             (when (pair? string)
               (set! strings (cons string strings)))))
         menus)
        ;; "Then output them." - `strings' is a stack, so the menus come
        ;; out in reverse, which is Emacs's own order (measured: file
        ;; then edit prints "Edit and File → Save").
        (when (pair? strings)
          (when heading
            (insert heading))
          (let ((n (length menus)))
            (let loop ((rest strings) (i 0))
              (unless (null? rest)
                (insert (cond ((zero? i) "")
                              ((= i (- n 1)) " and ")
                              (else ", ")))
                (insert (string-join (reverse (car rest)) ""))
                (loop (cdr rest) (+ i 1))))))
        #f))

    (define (help-fns--key-bindings function)
      ;; GNU Emacs's `help-fns--key-bindings' (`help-fns.el:577`):
      ;; "It is bound to ...", plus the remapping sentence when a
      ;; `[remap ...]` binding is in force for the command.
      ;;
      ;; **The menu half is not carried**: `help-fns--insert-menu-bindings`
      ;; walks the menu-bar keymaps by name, which is `menu-bar.el`'s
      ;; business and this tree's menus are built at display time; the
      ;; menu sequences are still counted with the other keys.
      ;;--------------------------------------------------------------
      (when (or (command-type? function)
                (procedure? function)
                (and (symbol? function) (command-record-named function)))
        (let* ((pt2 (point))
               (record (if (command-type? function)
                           function
                           (command-record-of function)))
               (name (and record (command-name record)))
               (remapped (and name
                              (let ((m (command-remapping
                                        (string->symbol name))))
                                (and m
                                     (not (eq? m undefined))
                                     m))))
               (target (or remapped function))
               (all-keys (or (where-is-internal target
                                                (*overriding-local-map*)
                                                #f #f #f)
                             '()))
               (split (%help-fns-split-menu-keys all-keys))
               (keys (car split))
               (menus (cdr split))
               (non-modified-keys
                (let loop ((rest keys) (acc '()))
                  (cond ((null? rest) (reverse acc))
                        ((%help-fns-modified-key? (car rest))
                         (loop (cdr rest) acc))
                        (else (loop (cdr rest) (cons (car rest) acc)))))))
          (if (and (eq? function self-insert-command)
                   (pair? keys)
                   (vector? (car keys))
                   (pair? (vector-ref (car keys) 0)))
              (insert "It is bound to many ordinary text characters.\n")
              (begin
                ;; **The C prints the *symbol*; ours is the binding
                ;; `command-remapping' answered**, so the name comes from
                ;; `help-fns-function-name' - Emacs's "an anonymous
                ;; command" arm is a lambda no keymap here holds.
                (when remapped
                  (insert "Its keys are remapped to `"
                          (help-fns-function-name remapped) "'.\n"))
                (when (pair? keys)
                  (insert (if remapped
                              "Without this remapping, it would be bound to "
                              "It is bound to "))
                  (if (< (length non-modified-keys) 10)
                      (help-fns--insert-bindings keys)
                      (let ((left (let loop ((rest keys) (acc '()))
                                    (cond ((null? rest) (reverse acc))
                                          ((member (car rest) non-modified-keys)
                                           (loop (cdr rest) acc))
                                          (else (loop (cdr rest)
                                                      (cons (car rest) acc)))))))
                        (if (pair? left)
                            (begin
                              (help-fns--insert-bindings left)
                              (insert ", and many ordinary text characters"))
                            (insert "many ordinary text characters.")))))
                (when (or remapped (pair? keys) (pair? non-modified-keys))
                  (insert ".")
                  (insert "\n"))))
          (fill-region-as-paragraph pt2 (point))
          (unless (bolp)
            (insert "\n"))
          (when (pair? menus)
            (let ((start (point)))
              (help-fns--insert-menu-bindings
               menus
               (string-append "It " (if remapped "could " "can ")
                              (if (pair? keys) "also " "")
                              "be invoked from the menu: "))
              (when remapped
                (insert ", but that was remapped to `"
                        (help-fns-function-name remapped)
                        "' as well.\n"))
              ;; "The (= (point) start) condition tests whether
              ;; 'help-fns--insert-menu-bindings' inserted anything; if it
              ;; didn't, we already have a period from the previous
              ;; 'princ' call."
              (unless (or remapped (= (point) start))
                (insert "."))
              (fill-region-as-paragraph start (point))))
          (ensure-empty-lines))
        #f))

    (define (help-fns--obsolete function)
      ;; GNU Emacs's `help-fns--obsolete' (`help-fns.el`): the
      ;; "This function is obsolete ..." paragraph, read from the
      ;; `byte-obsolete-info` property. Nothing here sets one yet; the
      ;; section is carried so that the first port that does shows it
      ;; the way Emacs does.
      ;;--------------------------------------------------------------
      (let* ((obsolete (and (symbol? function)
                            (get function 'byte-obsolete-info)))
             (use (and obsolete (car obsolete)))
             (start (point)))
        (when obsolete
          (insert "This function is obsolete")
          (when (and (pair? obsolete) (pair? (cdr obsolete))
                     (pair? (cddr obsolete)) (caddr obsolete))
            (insert (format " since %s" (caddr obsolete))))
          (insert (cond ((string? use) (string-append "; " use))
                        (use (format "; use `%s' instead." use))
                        (else ".")))
          (insert "\n")
          (fill-region-as-paragraph start (point))
          (ensure-empty-lines))
        #f))

    (define (%help-fns-analyze-function function)
      ;; The tree's `help-fns--analyze-function' (`help-fns.el:1080`):
      ;; the definition FUNCTION names or is. Emacs answers
      ;; (REAL-FUNCTION DEF ALIASED REAL-DEF); this tree has no aliases,
      ;; advise or autoloads, so it answers the definition alone.
      ;;--------------------------------------------------------------
      (cond
       ((command-type? function) (command-procedure function))
       ((procedure? function) function)
       ((symbol? function)
        (let ((record (command-record-named function)))
          (if record
              (command-procedure record)
              (error "Void function" function))))
       (else function)))

    (define (help-fns-function-description-header function)
      ;; GNU Emacs's `help-fns-function-description-header'
      ;; (`help-fns.el:1126`): the first line, "NAME is a ...".
      ;;
      ;; Emacs's arms name kinds this tree does not have (autoload,
      ;; alias, Lisp macro, advised, subr) and its "defined in FILE"
      ;; clause has no counterpart; the arms here are the shapes a
      ;; definition can have.
      ;;--------------------------------------------------------------
      ;; The line this prints is the part *after* "NAME is ":
      ;; `describe-function` writes the name and the copula, exactly as
      ;; the Elisp pair does.
      (let* ((def (%help-fns-analyze-function function))
             (command? (or (command-type? function)
                           (and (symbol? function)
                                (command-record-named function))
                           (and (procedure? function)
                                (command-record-of function)))))
        (insert
         (cond ((keymapp def) "a keymap")
               ((or (string? def) (vector? def)) "a keyboard macro")
               (command? "an interactive command")
               (else "a function")))
        (insert ".")
        (ensure-empty-lines)))

    (define (describe-function-1 function)
      ;; GNU Emacs's `describe-function-1' (`help-fns.el:1228`): the
      ;; body of `describe-function`, after "NAME is ".
      ;;
      ;; The C's order is kept: the header (filled), the obsolete note,
      ;; the key bindings, the docstring. The signature/usage line, the
      ;; `help-fns-describe-function-functions` hook and the type
      ;; inference are not carried - see the library header.
      ;;--------------------------------------------------------------
      (let ((pt1 (point)))
        (help-fns-function-description-header function)
        (fill-region-as-paragraph
         (save-excursion
           (goto-char pt1)
           (line-beginning-position))
         (point)
         #f #t)
        (ensure-empty-lines))
      (help-fns--obsolete function)
      (let ((doc-raw (guard (e (#t #f)) (documentation function #t))))
        (help-fns--key-bindings function)
        (help-fns--ensure-empty-line)
        (insert (or doc-raw "Not documented."))
        #f))

    (define-custom *describe-mode-outline* #t
      "Non-nil enables outlines in the output buffer of `describe-mode'."
      :type 'boolean
      :group 'help)

    (define (describe-mode--minor-modes modes global? buffer)
      ;; GNU Emacs's `describe-mode--minor-modes' (`help-fns.el:2312`):
      ;; one line naming the mode, then its full documentation under a
      ;; form-feed page break. The pretty name drops a trailing
      ;; `-minor-mode'/`-mode' (`(capitalize (replace-regexp-in-string
      ;; "\\(\\(-minor\\)?-mode\\)?\\'" "" ...))').
      ;;
      ;; Emacs's file-sorted `seq-sort #'string<' is a sort on the
      ;; *symbol names*, as ours is.
      ;;--------------------------------------------------------------
      (for-each
       (lambda (mode)
         (let ((pretty (capitalize
                        (replace-regexp-in-string
                         "\\(\\(-minor\\)?-mode\\)?\\'"
                         ""
                         (symbol->string mode)))))
           (if (not (*describe-mode-outline*))
               (insert " " pretty)
               (begin
                 (goto-char (point-max))
                 (put-text-property
                  (point)
                  (begin
                    (insert (if global? "Global" "Local")
                            (format " minor mode %s" mode))
                    (point))
                  'outline-level
                  1)
                 (insert "\n\n")))
           (save-excursion
             (unless (*describe-mode-outline*)
               (goto-char (point-max))
               (insert "\n\n\f\n"))
             (insert pretty)
             (let* ((entry (assq mode (*minor-mode-alist*)))
                    (indicator (if entry
                                   (minor-mode-lighter
                                    (minor-mode-indicator-value
                                     buffer (cdr entry)))
                                   "")))
               (insert (format " minor mode (%s):\n"
                               (if (zero? (string-length indicator))
                                   "no indicator"
                                   (format "indicator%s" indicator))))
               (insert (or (parameterize ((*current-buffer* buffer))
                             (documentation mode))
                           "No docstring"))
               (when (*describe-mode-outline*)
                 (insert "\n\n"))))))
       (sort (append modes '())
             (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))
      (unless (*describe-mode-outline*)
        (forward-line -1)
        (fill-paragraph #f)
        (forward-paragraph 1)
        (ensure-empty-lines 1))
      #f)

    (define-command (describe-mode . rest)
      ;; GNU Emacs's `describe-mode' (`help-fns.el:2223'): "Display
      ;; documentation of current major mode and minor modes. A brief
      ;; summary of the minor modes comes first, followed by the major
      ;; mode description. This is followed by detailed descriptions of
      ;; the minor modes, each on a separate page."
      ;;
      ;; **`local-minor-modes` and `global-minor-modes` are the lists
      ;; `define-minor-mode`'s generated command now keeps** - before
      ;; this, nothing in the tree tracked them.
      ;;
      ;; **Not carried**: `describe-mode-outline`, the file/line
      ;; clause, `help-fns--list-local-commands` (it needs `mapatoms`
      ;; and `command-modes`), buttons, and `help-split-fundoc` (no
      ;; usage lines here).
      ;;--------------------------------------------------------------
      "Display documentation of current major mode and minor modes.
A brief summary of the minor modes comes first, followed by the
major mode description.  This is followed by detailed
descriptions of the minor modes, each on a separate page.

For this to work correctly for a minor mode, the mode's indicator
variable \(listed in `minor-mode-alist') must also be a function
whose documentation describes the minor mode.

If called from Lisp with a non-nil BUFFER argument, display
documentation for the major and minor modes of that buffer."
      (interactive)
      (let* ((buffer (or (%help-arg rest 0) (current-buffer)))
             (local-minors (buffer-local-value buffer 'local-minor-modes '())))
        (help-setup-xref (list describe-mode buffer)
                         (called-interactively? describe-mode))
        (with-help-window (help-buffer)
          (with-current-buffer (help-buffer)
            ;; "Add the local minor modes at the start."
            (when (pair? local-minors)
              (unless (*describe-mode-outline*)
                (insert (format "Minor mode%s enabled in this buffer:"
                                (if (> (length local-minors) 1) "s" ""))))
              (describe-mode--minor-modes local-minors #f buffer))
            ;; "Document the major mode."
            (let ((major (buffer-local-value buffer 'major-mode
                                             'fundamental-mode)))
              (when (*describe-mode-outline*)
                (goto-char (point-min))
                (put-text-property
                 (point)
                 (begin
                   (insert (format "Major mode %s" major))
                   (point))
                 'outline-level
                 1)
                (insert "\n\n"))
              (insert "The major mode is ")
              (insert (buffer-local-value buffer 'mode-name "Fundamental"))
              (insert " mode:\n\n")
              (insert (or (parameterize ((*current-buffer* buffer))
                            (documentation major))
                          "Not documented.")))
            (ensure-empty-lines 1)
            ;; "Insert the global minor modes after the major mode."
            (when (pair? (*global-minor-modes*))
              (unless (*describe-mode-outline*)
                (insert (format "Global minor mode%s enabled:"
                                (if (> (length (*global-minor-modes*)) 1)
                                    "s"
                                    ""))))
              (describe-mode--minor-modes (*global-minor-modes*) #t buffer)
              (unless (*describe-mode-outline*)
                (when (re-search-forward "^\f" #f #t)
                  (beginning-of-line)
                  (ensure-empty-lines 1))))
            #f))))

    (define (internal-describe-syntax-value syntax)
      ;; GNU Emacs's `internal-describe-syntax-value' (`syntax.c:1305'):
      ;; "Insert a description of the internal syntax description
      ;; SYNTAX at point."
      ;;
      ;; **A placement departure**: the C keeps this in syntax.c, but it
      ;; inserts into the current buffer and its last line calls
      ;; `substitute-command-keys` - both above `syntax.scm`; the flag
      ;; readers it needs are exported from there.
      ;;--------------------------------------------------------------
      (let ((value syntax))
        (cond
         ((not value) (insert "default"))
         ((char-table? value) (insert "deeper char-table ..."))
         ((not (pair? value)) (insert "invalid"))
         (else
          (let* ((first (car value))
                 (match (cdr value)))
            (if (not (integer? first))
                (insert "invalid")
                (let* ((syntax-code (logand first most-positive-fixnum))
                       (code (logand syntax-code 255))
                       (start1 (%comstart-first? syntax-code))
                       (start2 (%comstart-second? syntax-code))
                       (end1 (%comend-first? syntax-code))
                       (end2 (%comend-second? syntax-code))
                       (prefix (%prefix-flag? syntax-code))
                       (comstyleb (not (zero? (%styleb-bit syntax-code))))
                       (comstylec (not (zero? (%stylec2 syntax-code))))
                       (comnested (%nested? syntax-code)))
                  (if (>= code smax)
                      (insert "invalid")
                      (begin
                        (insert (string (syntax-class-to-char code)))
                        (if (not match)
                            (insert " ")
                            (insert (string (if (char? match)
                                                match
                                                (integer->char match)))))
                        (when start1 (insert "1"))
                        (when start2 (insert "2"))
                        (when end1 (insert "3"))
                        (when end2 (insert "4"))
                        (when prefix (insert "p"))
                        (when comstyleb (insert "b"))
                        (when comstylec (insert "c"))
                        (when comnested (insert "n"))
                        (insert "\twhich means: ")
                        (insert
                         (cond ((= code swhitespace) "whitespace")
                               ((= code spunct) "punctuation")
                               ((= code sword) "word")
                               ((= code ssymbol) "symbol")
                               ((= code sopen) "open")
                               ((= code sclose) "close")
                               ((= code squote) "prefix")
                               ((= code sstring) "string")
                               ((= code smath) "math")
                               ((= code sescape) "escape")
                               ((= code scharquote) "charquote")
                               ((= code scomment) "comment")
                               ((= code sendcomment) "endcomment")
                               ((= code sinherit) "inherit")
                               ((= code scomment-fence) "comment fence")
                               ((= code sstring-fence) "string fence")
                               (else "invalid")))
                        (when match
                          (insert ", matches ")
                          (insert (string (if (char? match)
                                              match
                                              (integer->char match)))))
                        (when start1
                          (insert ",\n\t  is the first character of a comment-start sequence"))
                        (when start2
                          (insert ",\n\t  is the second character of a comment-start sequence"))
                        (when end1
                          (insert ",\n\t  is the first character of a comment-end sequence"))
                        (when end2
                          (insert ",\n\t  is the second character of a comment-end sequence"))
                        (when comstyleb (insert " (comment style b)"))
                        (when comstylec (insert " (comment style c)"))
                        (when comnested (insert " (nestable)"))
                        (when prefix
                          (insert (substitute-command-keys
                                   ",\n\t  is a prefix character for `backward-prefix-chars'"))))))))))
        syntax))

    ;;----------------------------------------------------------------
    ;; `describe-minor-mode` and its two directions - `help.el:1293-1400'
    ;;----------------------------------------------------------------
    ;;
    ;; **Placement departure**: these are `help.el`'s, and this library
    ;; is above `help.scm` - the mirror order would put them there, and
    ;; `describe-minor-mode-from-symbol` calls `describe-function` and
    ;; `describe-variable`, which are defined *here*. Emacs gets away
    ;; with it because a name resolves through one obarray; here the
    ;; dependency decides the file.

    (define (describe-minor-mode-completion-table-for-symbol)
      ;; GNU Emacs's `describe-minor-mode-completion-table-for-symbol`
      ;; (`help.el:1316`): "In order to list up all minor modes,
      ;; minor-mode-list is used here instead of minor-mode-alist."
      (let loop ((modes (*minor-mode-list*)) (acc '()))
        (if (null? modes)
            (reverse acc)
            (loop (cdr modes)
                  (if (symbol? (car modes))
                      (cons (symbol->string (car modes)) acc)
                      acc)))))

    (define-command (describe-minor-mode-from-symbol symbol)
      "Display documentation of a minor mode given as a symbol, SYMBOL."
      (interactive
       (list (intern (completing-read
                      "Minor mode symbol: "
                      (describe-minor-mode-completion-table-for-symbol)))))
      ;; "`(if (fboundp symbol) (describe-function symbol)
      ;; (describe-variable symbol))`" (`help.el:1321'). The command
      ;; table is this tree's `fboundp`.
      (if (command-record-named (symbol->string symbol))
          (describe-function symbol)
          (describe-variable symbol)))

    (define-command (describe-minor-mode-from-indicator indicator . rest)
      "Display documentation of a minor mode specified by INDICATOR.
If you call this function interactively, you can give indicator which
is currently activated with completion.

If non-nil, EVENT is a mouse event used to establish which minor
mode lighter was clicked."
      (interactive
       (list (completing-read
              "Minor mode indicator: "
              (describe-minor-mode-completion-table-for-indicator))))
      ;; EVENT is `rest`'s first element and is not read: Emacs uses it
      ;; only for the `mode-line-compact` disambiguation arm, which is
      ;; not carried - that option is not ported, and without it Emacs's
      ;; own answer is the whole-lighter comparison
      ;; `lookup-minor-mode-from-indicator` makes.
      (when (pair? indicator)
        (set! indicator (car indicator)))
      (let ((minor-mode (if (symbol? indicator)
                            indicator
                            (lookup-minor-mode-from-indicator indicator))))
        (if minor-mode
            (describe-minor-mode-from-symbol minor-mode)
            (error "Cannot find minor mode for `~a'" indicator))))

    (define-command (describe-minor-mode minor-mode)
      "Display documentation of a minor mode given as MINOR-MODE.
MINOR-MODE can be a minor mode symbol or a minor mode indicator string
appeared on the mode-line."
      (interactive
       (list (completing-read
              "Minor mode: "
              (append (describe-minor-mode-completion-table-for-symbol)
                      (describe-minor-mode-completion-table-for-indicator)))))
      (if (symbol? minor-mode)
          (set! minor-mode (symbol->string minor-mode)))
      (let ((symbols (describe-minor-mode-completion-table-for-symbol))
            (indicators (describe-minor-mode-completion-table-for-indicator)))
        (cond
         ((member minor-mode symbols)
          (describe-minor-mode-from-symbol (intern minor-mode)))
         ((member minor-mode indicators)
          (describe-minor-mode-from-indicator minor-mode))
         (else
          (error "No such minor mode: ~a" minor-mode)))))

    (define-command (mode-line-minor-mode-help event)
      "Describe minor mode for EVENT on minor modes area of the mode line."
      (interactive "@e")
      ;; Emacs: "`(let ((indicator (car (nth 4 (car (cdr event))))))
      ;; (describe-minor-mode-from-indicator indicator event))`"
      ;; (`bindings.el:956'). The fourth slot of a posn is its object -
      ;; `posn-object` - and the car of that pair is the drawn string.
      (let ((object (posn-object (event-start event))))
        (describe-minor-mode-from-indicator
         (and (pair? object) (car object))
         event)))

    (define-command (describe-syntax . rest)
      ;; GNU Emacs's `describe-syntax' (`help-fns.el:2027'): "Describe
      ;; the syntax specifications in the syntax table of BUFFER. The
      ;; descriptions are inserted in a help buffer, which is then
      ;; displayed."
      ;;--------------------------------------------------------------
      "Describe the syntax specifications in the syntax table of BUFFER.
The descriptions are inserted in a help buffer, which is then displayed.
BUFFER defaults to the current buffer."
      (interactive)
      (let* ((buffer (or (%help-arg rest 0) (current-buffer)))
             (table (parameterize ((*current-buffer* buffer))
                      (syntax-table))))
        (help-setup-xref (list describe-syntax buffer)
                         (called-interactively? describe-syntax))
        (with-help-window (help-buffer)
          (with-current-buffer (help-buffer)
            (describe-vector table internal-describe-syntax-value)
            (let loop ((parent (char-table-parent table)))
              (when parent
                (insert "\nThe parent syntax table is:")
                (describe-vector parent internal-describe-syntax-value)
                (loop (char-table-parent parent))))
            #f))))

    (define (%describe-symbol-backends)
      ;; `describe-symbol-backends' (`help-mode.el:540`) - the pairs of
      ;; "is this symbol one" and "describe it". Emacs has four arms
      ;; (function, variable, face, cl type); this tree has the two its
      ;; data model can answer, and their NAME column is nil, as the
      ;; function and variable arms' is in Emacs.
      ;;--------------------------------------------------------------
      (list (list #f
                  (lambda (sym) (and (symbol? sym) (command-record-named sym)))
                  (lambda (sym . args) (describe-function sym)))
            (list #f
                  (lambda (sym) (and (symbol? sym) (custom-variable-p sym)))
                  (lambda (sym . args) (describe-variable sym)))))

    (define-command (describe-symbol symbol . rest)
      ;; GNU Emacs's `describe-symbol' (`help-fns.el:1957'): "Display
      ;; the full documentation of SYMBOL. Will show the info of SYMBOL
      ;; as a function, variable, and/or face."
      ;;
      ;; **The multi-backend assembly is carried but unreachable here**:
      ;; Emacs's two docs for one symbol exist because a symbol has a
      ;; function cell and a value cell; in this tree a command is a
      ;; procedure binding and a custom is a parameter binding, so a
      ;; name is one or the other, never both. The separator-and-"also"
      ;; loop stays so the day a name can be both it behaves.
      ;;
      ;; **The prompt completes over this tree's two indexes** - the
      ;; command table and `custom-variable-names` - where Emacs filters
      ;; its one obarray through the backends. **It must not use
      ;; `read-string`**: `(scheme base)` exports Guile's port reader of
      ;; that name, which wins the import over minibuffer's prompt
      ;; reader without a word (measured: the call reached
      ;; `(make-string "Describe symbol: " ...)` and raised "Wrong type
      ;; (expecting exact integer)").
      ;;--------------------------------------------------------------
      "Display the full documentation of SYMBOL.
Will show the info of SYMBOL as a function, variable, and/or face."
      (interactive
       (list
        (let ((names (append (map car (*command-table*))
                             (map symbol->string custom-variable-names))))
          (string->symbol (completing-read "Describe symbol: " names
                                           #f #t #f #f)))))
      (unless (symbol? symbol)
        (error "You didn't specify a function or variable"))
      (with-current-buffer (help-buffer)
        ;; "Push the previous item on the stack before clobbering the
        ;; output buffer."
        (help-setup-xref #f #f)
        (let ((docs '()))
          ;; Each backend's describer opens the help buffer itself
          ;; (`with-help-window` empties it), so each doc is captured
          ;; from the buffer right after its run - the C's `(funcall
          ;; descfn symbol buffer frame)` + `(buffer-string)`.
          (for-each
           (lambda (backend)
             (when ((cadr backend) symbol)
               (set! *help-xref-stack-item* #f)
               ((caddr backend) symbol)
               (set! docs
                     (cons (cons (car backend)
                                 (with-current-buffer (help-buffer)
                                   (buffer-string)))
                           docs))))
           (%describe-symbol-backends))
          (when (null? docs)
            (error (format "Unknown symbol: %s" symbol)))
          ;; The captures come back most-recent-first, and the buffer
          ;; holds the most recent one; the rest go in at the top.
          (let loop ((docs (reverse docs)))
            (when (pair? (cdr docs))
              (goto-char (point-min))
              (let ((name (car (car docs)))
                    (doc (cdr (cadr docs))))
                (parameterize ((*inhibit-read-only* #t))
                  (when doc
                    (insert doc)
                    (insert "\n")
                    (insert (make-separator-line))
                    (when name
                      (insert (symbol->string symbol)
                              " is also a " name ".\n\n")))))
              (loop (cdr docs))))
          ;; "Don't record the `describe-variable' item in the stack."
          (when (pair? (cdr (reverse docs)))
            (set! *help-xref-stack-item* #f)
            (help-setup-xref (list describe-symbol symbol) #f))
          (goto-char (point-max))
          #f)))

    (define-command (describe-function function)
      ;; GNU Emacs's `describe-function' (`help-fns.el:298`): "Display
      ;; the full documentation of FUNCTION (a symbol)."
      ;;
      ;; The interactive prompt is `read-command`'s - Emacs completes
      ;; over its obarray with `fboundp`; the command table is the only
      ;; list of functions this tree has (`read-command`'s note).
      ;;--------------------------------------------------------------
      "Display the full documentation of FUNCTION (a symbol).
When called from Lisp, FUNCTION may also be a function object."
      (interactive "CDescribe function: ")
      (let ((name (cond ((symbol? function) function)
                        ((command-type? function)
                         (string->symbol (command-name function)))
                        ((procedure? function)
                         (let ((record (command-record-of function)))
                           (and record
                                (string->symbol (command-name record)))))
                        (else #f))))
        (unless name
          (error "Invalid function" function))
        (help-setup-xref (list describe-function-1 name)
                         (called-interactively? describe-function))
        (save-excursion
          (with-help-window (help-buffer)
            (insert (symbol->string name))
            (insert " is ")
            (describe-function-1 name)
            (buffer-string)))))

    (define-command (describe-variable variable)
      ;; GNU Emacs's `describe-variable' (`help-fns.el:1356`): "Display
      ;; the full documentation of VARIABLE (a symbol)."
      ;;
      ;; **Only custom variables can be described** - see the library
      ;; header: a symbol reaches a binding here only if
      ;; `custom-declare-variable` recorded one, with its docstring, its
      ;; standard value and its reader.
      ;;--------------------------------------------------------------
      "Display the full documentation of VARIABLE (a symbol).
Returns the documentation as a string, also."
      (interactive "vDescribe variable: ")
      (unless (symbol? variable)
        (error "You didn't specify a variable"))
      (help-setup-xref (list describe-variable variable)
                       (called-interactively? describe-variable))
      (let ((doc (documentation-property variable 'variable-documentation)))
        (save-excursion
          (with-help-window (help-buffer)
            (insert (symbol->string variable))
            (if (custom-variable-p variable)
                (let* ((reader (get variable 'custom-reader))
                       (value (and reader (reader variable)))
                       (standard (custom--standard-value variable)))
                  (insert "'s value is ")
                  (insert (format "%S" value))
                  (insert "\n")
                  (ensure-empty-lines)
                  (unless (equal? value standard)
                    (insert "The standard value is ")
                    (insert (format "%S" standard))
                    (insert ".\n")
                    (ensure-empty-lines)))
                (begin
                  (insert " is a variable.\n")
                  (ensure-empty-lines)))
            (insert "Documentation:\n")
            (insert (or doc "Not documented as a variable."))
            (when (custom-variable-p variable)
              (ensure-empty-lines)
              (insert "You can customize this variable."))
            (buffer-string)))))

    ;; `describe-function-1` is what `describe-key` (help.scm) calls for
    ;; the command a key runs; help.scm is below this library, so the two
    ;; meet at the seam help.scm declares.
    (*describe-function-1-function* describe-function-1)

    ;; `mouse.el`'s generated minor-mode menu's "Help" item.
    (*describe-function-function* describe-function)

    ;; `help-map`'s `f` and `v`, and the flat keys this tree's lookup
    ;; takes (see the note beside `C-h b` in help.scm).
    (define-key help-map (kbd "f") describe-function)
    (define-key help-map (kbd "v") describe-variable)
    (define-key *default-keymap* (kbd "C-h f") describe-function)
    (define-key *default-keymap* (kbd "C-h v") describe-variable)
    (define-key help-map (kbd "m") describe-mode)
    (define-key *default-keymap* (kbd "C-h m") describe-mode)
    (define-key help-map (kbd "s") describe-syntax)
    (define-key *default-keymap* (kbd "C-h s") describe-syntax)
    (define-key help-map (kbd "o") describe-symbol)
    (define-key *default-keymap* (kbd "C-h o") describe-symbol)))
