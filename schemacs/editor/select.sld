(define-library (schemacs editor select)
  ;; This library mirrors GNU Emacs's `select.el': "the lisp portion of
  ;; standard selection support". The selection is how a window system
  ;; moves text between programs - `PRIMARY' (what is selected),
  ;; `SECONDARY' and `CLIPBOARD' - and what this holds is two layers of
  ;; it, in select.el's own division:
  ;;
  ;; - Low-level: `gui-set-selection' and `gui-get-selection', which
  ;;   hand the work to a backend through `gui-backend-*' - here the
  ;;   display generics of `dispnew' (`get-selection' and friends,
  ;;   whose default methods answer #f, which is what a text terminal's
  ;;   selections are). Emacs's `window-system' dispatch is those
  ;;   generics' dispatch on the display.
  ;; - Higher-level: `gui-select-text' and `gui-selection-value', the
  ;;   default values of simple.el's `interprogram-cut-function' and
  ;;   `interprogram-paste-function', which are how the kill ring and
  ;;   the selections meet. `select-enable-clipboard' (t) and
  ;;   `select-enable-primary' (nil) say which selections they use.
  ;;
  ;; A text terminal gets the whole lisp layer with #f answers under
  ;; it, which is exactly what `emacs -nw' does - the selection
  ;; functions are no-ops there, and killing and yanking stay inside
  ;; the kill ring. `pgtk.sld' answers the generics with Gtk's
  ;; clipboard, which is what `pgtkselect.c' is under pgtk-win.el.

  (import
   (scheme base)
   (scheme cxr)
   ;; `window-system' is what `gui-select-text' and the rest dispatch
   ;; on, the way Emacs's methods dispatch on it.
   (only (schemacs editor faces) *window-system*)
   (only (schemacs editor dispnew)
         current-display get-selection set-selection!
         selection-owner? selection-exists?)
   ;; The selection *converters* at the bottom of this file walk a
   ;; string's characters and encode it - `xselect--encode-string' is
   ;; `encode-coding-string' when TYPE names a coding system. Emacs has
   ;; `coding.c' compiled in below this file, so nothing about the
   ;; order is visible there; here it is an import.
   ;;
   ;; The base-name test in `xselect--encode-string' stands where the
   ;; C's `:coding-type' does: this tree's coding systems carry no
   ;; `:coding-type' field (see `coding.sld''s record), so "is this
   ;; already a utf-8 coding system" is asked of the base *name*.
   (only (schemacs editor coding)
         encode-coding-string coding-system-base find-coding-system)
   ;; `(only (guile) ...)': `string-split'/`string-join' for the NUL
   ;; escaping, `ash'/`logand' for `xselect--int-to-cons',
   ;; `list->u32vector' for the code points `encode-coding-string' takes.
   (only (guile) ash logand string-split string-join list->u32vector)
   ;; `u8-list->bytevector': the NUL escaping has to walk the *bytes*
   ;; `encode-coding-string' answered with, which are a bytevector here
   ;; where Emacs's are a unibyte string.
   (only (rnrs bytevectors) u8-list->bytevector))

  (export
   select-enable-clipboard select-enable-primary
   *select-enable-clipboard* *select-enable-primary*
   gui-select-text gui-selection-value
   gui-get-primary-selection
   gui-set-selection gui-get-selection
   gui-backend-get-selection gui-backend-set-selection
   gui-backend-selection-owner-p gui-backend-selection-exists-p
   gui--last-selected-text-clipboard gui--last-selected-text-primary
   *gui--last-selected-text-clipboard* *gui--last-selected-text-primary*
   *saved-region-selection* *x-select-request-type*
   *gui-last-cut-in-clipboard* *gui-last-cut-in-primary*
   x-get-clipboard
   ;; The Lisp half of a read of our *own* selection: the target table
   ;; `pgtk.sld''s `pgtk-get-local-selection' looks a requested target up
   ;; in, and the coding system selection text is encoded with.
   *selection-converter-alist* *selection-coding-system*
   *next-selection-coding-system*
   xselect--encode-string xselect--int-to-cons
   xselect-convert-to-string xselect-convert-to-length
   xselect-convert-to-targets xselect-convert-to-delete
   xselect-convert-to-atom xselect-convert-to-integer
   xselect-convert-to-identity xselect-convert-to-save-targets
   xselect-convert-to-class xselect-convert-to-name
   )

  (begin

    ;; `(defcustom select-enable-clipboard t)' (`select.el:91').
    (define *select-enable-clipboard* (make-parameter #t))
    ;; ^ Non-nil means cutting and pasting uses the clipboard. This can
    ;; be in addition to, but in preference to, the primary selection,
    ;; if applicable (i.e. under X11).

    ;; `(defcustom select-enable-primary nil)' (`select.el:102').
    (define *select-enable-primary* (make-parameter #f))
    ;; ^ Non-nil means cutting and pasting uses the primary selection.
    ;; The existence of a primary selection depends on the underlying
    ;; GUI you use. E.g. it doesn't exist under MS-Windows.

    ;; We keep track of the last selection here, so we can check the
    ;; current selection against it, and avoid passing back with
    ;; gui-selection-value the same text we previously killed or
    ;; yanked. We track both separately in case another application
    ;; only sets one of them we aren't fooled by the PRIMARY or
    ;; CLIPBOARD selection staying the same.
    (define *gui--last-selected-text-clipboard* (make-parameter #f))
    ;; ^ The value of the CLIPBOARD selection last seen.
    (define *gui--last-selected-text-primary* (make-parameter #f))
    ;; ^ The value of the PRIMARY selection last seen.

    (define *gui--last-selection-timestamp-clipboard* (make-parameter #f))
    ;; ^ The timestamp of the CLIPBOARD selection last seen. X keeps a
    ;; timestamp with every selection; Gtk's clipboard does not offer
    ;; one, and `window-system' is `pgtk' here rather than `x', so the
    ;; reads these guard never fire - they are kept because
    ;; select.el's own comparisons are written around them.
    (define *gui--last-selection-timestamp-primary* (make-parameter #f))
    ;; ^ The timestamp of the PRIMARY selection last seen.

    (define *gui-last-cut-in-clipboard* (make-parameter #f))
    ;; ^ Whether or not the last call to `interprogram-cut-function'
    ;; owned CLIPBOARD.
    (define *gui-last-cut-in-primary* (make-parameter #f))
    ;; ^ Whether or not the last call to `interprogram-cut-function'
    ;; owned PRIMARY.

    (define *saved-region-selection* (make-parameter #f))
    ;; ^ Contents of active region prior to buffer modification. If
    ;; `select-active-regions' is non-nil, Emacs sets this to the text
    ;; in the region before modifying the buffer. The next call to the
    ;; function `deactivate-mark' uses this to set the window
    ;; selection. Emacs declares it in `keyboard.c'
    ;; (`keyboard.c:14363'); it is here because `gui-select-text' is
    ;; what sets it - the Bug#16382 line - and the command-loop half
    ;; that reads it is keyboard.sld's to come.

    (define *x-select-request-type* (make-parameter #f))
    ;; ^ Data type request for X selection: one data type, a list of
    ;; them, or nil - nil meaning the list
    ;; (UTF8_STRING COMPOUND_TEXT STRING text/plain;charset=utf-8),
    ;; which `gui--selection-value-internal' walks until one answers.
    ;; The last member's name holds a `;', which a reader reads as the
    ;; start of a comment unless it is told otherwise. **Every Lisp
    ;; spells this the same way and every reader spells the escape
    ;; differently**, so the spelling is worth naming:
    ;;
    ;;   select.el   `text/plain\;charset=utf-8'   a backslash escapes it
    ;;   R7RS        `|text/plain;charset=utf-8|'  pipe quoting
    ;;   Guile       `#{text/plain;charset=utf-8}#' the reader's own form
    ;;
    ;; **Guile's reader has no backslash escape inside a symbol** -
    ;; `'a\;b' is "unexpected end of input while searching for: )" in
    ;; both of its readers (measured) - so Emacs's own spelling cannot be
    ;; transcribed. It is written in `#{...}#' instead, which is Guile's
    ;; answer to the same problem: it is exactly how Guile's printer
    ;; writes this symbol, and it is the one spelling that reads under
    ;; the default reader *and* under `--r7rs'. That matters more than it
    ;; sounds - it was the only thing in the tree that made `--r7rs'
    ;; compulsory, so `tools/syntax-check.scm' had to re-exec itself with
    ;; it (`select.sld:17' in the pre-2026-10-09 tree).
    ;;
    ;; The *value* stays a symbol, as Emacs's is, for the reason the
    ;; backend gives: `pgtk_get_selection_internal' does `CHECK_SYMBOL'
    ;; on it, `symbol_to_gdk_atom' interns its NAME as a GDK atom, and
    ;; `pgtk_get_local_selection' looks it up with `Fassq' in
    ;; `selection-converter-alist' - an `eq?' lookup keyed by these
    ;; symbols. A string answers none of those. `display-*''s tty method
    ;; already leans on the shape one layer down: it compares against the
    ;; symbol `STRING' and errors on anything else.

    ;;----------------------------------------------------------------
    ;; The backend face of the low level
    ;;
    ;; Emacs's `gui-backend-*' cl-defgenerics dispatch on the window
    ;; system; here the display is the dispatch key, through the
    ;; selection generics of `dispnew'. A display that has not opened
    ;; - a script, a unit test - answers #f, which is the same no-op a
    ;; text terminal gets.
    ;;------------------------------------------------------------------

    (define (gui-backend-get-selection selection target-type)
      ;; Return selected text. SELECTION-SYMBOL is typically `PRIMARY',
      ;; `SECONDARY', or `CLIPBOARD'. (Those are literal upper-case
      ;; symbol names, since that's what X expects.) TARGET-TYPE is the
      ;; type of data desired, typically `STRING'.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (and display (get-selection display selection target-type))))

    (define (gui-backend-set-selection selection value)
      ;; Method to assert a selection of type SELECTION and value
      ;; VALUE. SELECTION is a symbol, typically `PRIMARY', `SECONDARY',
      ;; or `CLIPBOARD'. If VALUE is nil and we own the selection
      ;; SELECTION, disown it instead. Disowning it means there is no
      ;; such selection. VALUE is typically a string, or a cons of two
      ;; markers, but may be anything that the functions on
      ;; `selection-converter-alist' know about.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (and display (set-selection! display selection value))))

    (define (gui-backend-selection-owner-p selection)
      ;; Whether the current Emacs process owns the given X Selection.
      ;; The arg should be the name of the selection in question,
      ;; typically one of the symbols `PRIMARY', `SECONDARY', or
      ;; `CLIPBOARD'.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (and display (selection-owner? display selection))))

    (define (gui-backend-selection-exists-p selection)
      ;; Whether there is an owner for the given X Selection. The arg
      ;; should be the name of the selection in question, typically one
      ;; of the symbols `PRIMARY', `SECONDARY', or `CLIPBOARD'.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (and display (selection-exists? display selection))))

    ;;----------------------------------------------------------------
    ;; The bookkeeping the higher level is written around
    ;;------------------------------------------------------------------

    (define (gui--set-last-clipboard-selection text)
      ;; Save last clipboard selection. Save the selected text, passed
      ;; as argument, and for window systems that support it, save the
      ;; selection timestamp too.
      ;;--------------------------------------------------------------
      (*gui--last-selected-text-clipboard* text)
      (when (eq? (*window-system*) 'x)
        (*gui--last-selection-timestamp-clipboard*
         (gui-backend-get-selection 'CLIPBOARD 'TIMESTAMP))))

    (define (gui--set-last-primary-selection text)
      ;; Save last primary selection. Save the selected text, passed as
      ;; argument, and for window systems that support it, save the
      ;; selection timestamp too.
      ;;--------------------------------------------------------------
      (*gui--last-selected-text-primary* text)
      (when (eq? (*window-system*) 'x)
        (*gui--last-selection-timestamp-primary*
         (gui-backend-get-selection 'PRIMARY 'TIMESTAMP))))

    (define (gui--clipboard-selection-unchanged-p text)
      ;; Check whether the clipboard selection has changed. Compare the
      ;; selection text, passed as argument, with the text from the
      ;; last saved selection. For window systems that support it,
      ;; compare the selection timestamp too.
      ;;--------------------------------------------------------------
      (and
       (equal? text (*gui--last-selected-text-clipboard*))
       (or (not (eq? (*window-system*) 'x))
           (eq? (*gui--last-selection-timestamp-clipboard*)
                (gui-backend-get-selection 'CLIPBOARD 'TIMESTAMP)))))

    (define (gui--primary-selection-unchanged-p text)
      ;; Check whether the primary selection has changed. Compare the
      ;; selection text, passed as argument, with the text from the
      ;; last saved selection. For window systems that support it,
      ;; compare the selection timestamp too.
      ;;--------------------------------------------------------------
      (and
       (equal? text (*gui--last-selected-text-primary*))
       (or (not (eq? (*window-system*) 'x))
           (eq? (*gui--last-selection-timestamp-primary*)
                (gui-backend-get-selection 'PRIMARY 'TIMESTAMP)))))

    ;;----------------------------------------------------------------
    ;; The cut and paste functions
    ;;------------------------------------------------------------------

    (define (gui-select-text text)
      ;; Select TEXT, a string, according to the window system. If
      ;; `select-enable-clipboard' is non-nil, copy TEXT to the
      ;; system's clipboard. If `select-enable-primary' is non-nil,
      ;; put TEXT in the primary selection. MS-Windows does not have a
      ;; "primary" selection.
      ;;--------------------------------------------------------------
      (when (*select-enable-primary*)
        (gui-set-selection 'PRIMARY text)
        (gui--set-last-primary-selection text))
      (when (*select-enable-clipboard*)
        ;; When cutting, the selection is cleared and PRIMARY set to
        ;; the empty string.  Prevent that, PRIMARY should not be
        ;; reset by cut (Bug#16382).
        (*saved-region-selection* text)
        (gui-set-selection 'CLIPBOARD text)
        (gui--set-last-clipboard-selection text))
      ;; Record which selections we now have ownership over.
      (*gui-last-cut-in-clipboard* (*select-enable-clipboard*))
      (*gui-last-cut-in-primary* (*select-enable-primary*)))

    (define (gui--selection-value-internal type)
      ;; Get a selection value of type TYPE. Call `gui-get-selection'
      ;; with an appropriate DATA-TYPE argument decided by
      ;; `x-select-request-type'. The return value is already decoded.
      ;; If `gui-get-selection' signals an error, return nil.
      ;;
      ;; The doc string of `interprogram-paste-function' says to return
      ;; nil if no other program has provided text to paste.
      ;;
      ;; Emacs's `(unless (and ...) ...)' is a *value* here - when the
      ;; guard holds it answers nil - and Scheme's `unless' answers
      ;; unspecified, which is not nil: it would flow out of
      ;; `gui-selection-value' and into the kill ring. The guard is an
      ;; if, then, which answers #f where Elisp's unless answers nil.
      ;;--------------------------------------------------------------
      (if (and (*gui-last-cut-in-clipboard*)
                   ;; `gui-backend-selection-owner-p' might be
                   ;; unreliable on some other window systems.
                   (memq (*window-system*) '(x haiku))
                   (eq? type 'CLIPBOARD)
                   ;; Should we unify this with
                   ;; gui--clipboard-selection-unchanged-p?
                   (gui-backend-selection-owner-p type))
          #f
        (let ((request-type (if (memq (*window-system*) '(x pgtk haiku))
                                (or (*x-select-request-type*)
                                    '(UTF8_STRING
                                      COMPOUND_TEXT
                                      STRING
                                      #{text/plain;charset=utf-8}#))
                                'STRING)))
          (let loop ((types (if (pair? request-type)
                                request-type
                                (list request-type)))
                     (text #f))
            ;; `with-demoted-errors' around the read: a selection the
            ;; backend cannot answer is nil, not an error.
            ;;
            ;; The end-of-list test is `(pair? types)' and not Elisp's
            ;; `(and request-type ...)' - an exhausted list is nil in
            ;; Elisp and *true* in Scheme, and the cdr of it is what
            ;; "Wrong type argument (expecting pair)" was about.
            (if (and (pair? types) (not text))
                (loop (cdr types)
                      (guard (ex (else #f))
                        (gui-get-selection type (car types))))
                (and text (remove-text-properties text)))))))

    (define (remove-text-properties text)
      ;; The strip `gui--selection-value-internal' does on what it
      ;; read: "(if text (remove-text-properties 0 (length text)
      ;; '(foreign-selection nil) text))". The `foreign-selection'
      ;; property says the string still needs decoding; there are no
      ;; text properties on a selection string here - the backend
      ;; answers decoded text - so this is the same string.
      ;;--------------------------------------------------------------
      text)

    (define (gui-selection-value)
      ;; The paste half of the cut/paste pair, and the default of
      ;; simple.el's `interprogram-paste-function'.
      ;;
      ;; `clip-text' and `primary-text' are Elisp `when's used as
      ;; values - #f when the enable is off - and Scheme's `when'
      ;; answers unspecified, which `(or clip-text primary-text)' would
      ;; hand back as a truthy paste: they are ifs. The `unless's
      ;; inside them are the same story.
      ;;--------------------------------------------------------------
      (let ((clip-text
             (if (*select-enable-clipboard*)
                 (let ((text (gui--selection-value-internal 'CLIPBOARD)))
                   ;; `(when (string= text "") (setq text nil))' in
                   ;; Emacs: Elisp's `string=' answers nil for a nil
                   ;; argument, so the empty check does not fire -
                   ;; Guile's signals, and the guard is what says the
                   ;; same.
                   (when (and text (string=? text "")) (set! text #f))
                   ;; Check the CLIPBOARD selection for 'newness', i.e.,
                   ;; whether it is different from the last time we did a
                   ;; yank operation or whether it was set by Emacs
                   ;; itself with a kill operation, since in both cases
                   ;; the text will already be in the kill ring. See
                   ;; (bug#27442) and (bug#53894) for further discussion
                   ;; about this DWIM action, and possible ways to make
                   ;; this check less fragile, if so desired.

                   ;; Don't check the "newness" of CLIPBOARD if the last
                   ;; call to `gui-select-text' didn't cause us to become
                   ;; its owner.  This lets the user yank text killed by
                   ;; `clipboard-kill-region' with `clipboard-yank'
                   ;; without interference from text killed by other
                   ;; means when `select-enable-clipboard' is nil.
                   (if (and (*gui-last-cut-in-clipboard*)
                            (gui--clipboard-selection-unchanged-p text))
                       #f
                       (begin
                         (gui--set-last-clipboard-selection text)
                         text)))
                 #f))
            (primary-text
             (if (*select-enable-primary*)
                 (let ((text (gui--selection-value-internal 'PRIMARY)))
                   (if (and text (string=? text "")) (set! text #f))
                   ;; Check the PRIMARY selection for 'newness', is it
                   ;; different from what we remembered them to be last
                   ;; time we did a cut/paste operation.
                   (if (and (*gui-last-cut-in-primary*)
                            (gui--primary-selection-unchanged-p text))
                       #f
                       (begin
                         (gui--set-last-primary-selection text)
                         text)))
                 #f)))
        ;; As we have done one selection, clear this now -
        ;; `next-selection-coding-system', which is nil already here:
        ;; it is the coding system the *next* selection read decodes
        ;; with, and nothing in this tree sets one.
        ;; At this point we have recorded the current values for the
        ;; selection from clipboard (if we are supposed to) and
        ;; primary. So return the first one that has changed (which is
        ;; the first non-null one).
        ;;
        ;; NOTE: There will be cases where more than one of these has
        ;; changed and the new values differ.  This indicates that
        ;; something like the following has happened since the last
        ;; time we looked at the selections: Application X set all the
        ;; selections, then Application Y set only one of them. In this
        ;; case, for systems that support selection timestamps, we
        ;; could return the newer.  For systems that don't, there is no
        ;; way to know what the 'correct' value to return is. The nice
        ;; thing to do would be to tell the user we saw multiple
        ;; possible selections and ask the user which was the one they
        ;; wanted.
        (or clip-text primary-text)))

    (define (x-get-clipboard)
      ;; Return text pasted to the clipboard. (`select.el:312'; the
      ;; obsolete spelling, kept because it is there.)
      ;;--------------------------------------------------------------
      (gui-backend-get-selection 'CLIPBOARD 'STRING))

    (define (gui-get-primary-selection)
      ;; Return the PRIMARY selection, or the best emulation thereof.
      ;; The MS-Windows emulation branch of the or is not ported -
      ;; there is no w32 here.
      ;;--------------------------------------------------------------
      (or (gui--selection-value-internal 'PRIMARY)
          (error "No selection is available")))

    ;;----------------------------------------------------------------
    ;; The low level itself
    ;;------------------------------------------------------------------

    (define (gui-get-selection . args)
      ;; Return the value of an X Windows selection. The argument TYPE
      ;; (default `PRIMARY') says which selection, and the argument
      ;; DATA-TYPE (default `STRING') says how to convert the data.
      ;; TYPE may be any symbol (but nil stands for `PRIMARY').
      ;; DATA-TYPE is usually `STRING'.
      ;;--------------------------------------------------------------
      (let* ((type (if (pair? args) (car args) 'PRIMARY))
             (type (or type 'PRIMARY))
             (data-type (if (and (pair? args) (pair? (cdr args)))
                            (cadr args)
                            'STRING))
             (data (gui-backend-get-selection type data-type)))
        ;; What follows in select.el is the decoding of a string still
        ;; carrying the `foreign-selection' text property - the C
        ;; answered bytes and select.el decodes them by DATA-TYPE. The
        ;; backend here answers decoded text (Gtk's clipboard is
        ;; UTF-8), there are no text properties on it, and the decode
        ;; is the identity.
        data))

    (define (gui-set-selection type data)
      ;; Make an X selection of type TYPE and value DATA. The argument
      ;; TYPE (nil means `PRIMARY') says which selection, and DATA
      ;; specifies the contents. TYPE must be a symbol. DATA may be a
      ;; string, a symbol, or an integer.
      ;;
      ;; The selection may also be a cons of two markers pointing to
      ;; the same buffer, or an overlay - the selection being the text
      ;; between them *at whatever time it is examined*. Only the
      ;; simple values reach a backend here: a selection of markers is
      ;; what the command loop passes on GUI frames, and keyboard.sld
      ;; extracts its text first, as `region-extract-function' does in
      ;; the C.
      ;;--------------------------------------------------------------
      (or (gui--valid-simple-selection-p data)
          (error "invalid selection" data))
      (let ((selection (or type 'PRIMARY)))
        (gui-backend-set-selection selection data))
      data)

    (define (gui--valid-simple-selection-p data)
      ;; Whether DATA is a selection a backend can be handed. Emacs's
      ;; also takes a buffer and conses of markers - the marker case is
      ;; what `gui-set-selection''s docstring describes, and it is
      ;; extracted by the caller here, so strings, symbols and
      ;; integers are what remains.
      ;;--------------------------------------------------------------
      (or (string? data)
          (symbol? data)
          (integer? data)))

    ;;----------------------------------------------------------------
    ;; Converting our own selection to another target
    ;;
    ;; This is the Lisp half of a read - `selection-converter-alist' and
    ;; the handlers on it. The C half is `pgtk_get_local_selection'
    ;; (`pgtkselect.c:236', and `pgtk.sld' here), which looks the
    ;; requested target up in *this table* with `Fassq' - an `eq?' lookup
    ;; keyed by the target *symbol* - and calls the handler with
    ;;
    ;;     (SELECTION TYPE VALUE)
    ;;
    ;; where TYPE is **nil**, because the request is local: the C passes
    ;; `(local_request ? Qnil : target_type)'. That nil is what makes a
    ;; local read cheap - `xselect--encode-string' answers the string as
    ;; it stands and no coding system is involved at all.
    ;;
    ;; Emacs declares the variable in the C - `DEFVAR_LISP
    ;; (\"selection-converter-alist\", ..., Qnil)' at `pgtkselect.c:1915'
    ;; - and fills it here, with one `setq' at the end of this file
    ;; (`select.el:903'). The same shape: the table is built at the
    ;; bottom of this library, once the handlers are defined.
    ;;
    ;; **Which handlers are not here, and why** - each is a leaf whose
    ;; *input* is what is missing, and all of one kind are missing for
    ;; one reason:
    ;;
    ;;   * `xselect--selection-bounds' (`select.el:552') and the four
    ;;     converters that exist to walk it - `-to-filename',
    ;;     `-to-charpos', `-to-lineno', `-to-colno' - and the non-string
    ;;     arm of `-to-string'. They convert a selection whose VALUE is a
    ;;     buffer, a cons of two markers or an overlay, and
    ;;     `gui--valid-simple-selection-p' above admits only a string, a
    ;;     symbol and an integer - it has to, because the backend here
    ;;     hands Gtk the *text* (`set-selection!') and Gtk answers
    ;;     foreign requests with it, so a value that is not text has
    ;;     nowhere to live. Widening that predicate is the one change
    ;;     that lights all five up, and it needs a backend that can hold
    ;;     a non-text selection.
    ;;   * `-to-os', `-to-host', `-to-user', which answer
    ;;     `(symbol-name system-type)', `(system-name)' and
    ;;     `(user-full-name)'. None of those three variables exists in
    ;;     this tree: their Emacs homes are `emacs.c' (no `emacs.sld'
    ;;     here), `sysdep.c' (no `sysdep.sld') and `editfns.c'. Four
    ;;     one-line primitives, and three legacy ICCCM targets that no
    ;;     program this editor talks to asks for - left rather than
    ;;     given a home in a pass about the read path.
    ;;   * the eleven `XdndSelection' entries (`text/uri-list', `FILE',
    ;;     `_DT_NETFILE', the two `XmTRANSFER_*', `text/x-xdnd-username')
    ;;     and the four "available-p" predicates that guard them. Every
    ;;     one of them opens `(eq selection 'XdndSelection)' and there is
    ;;     no drag-and-drop here (`x-dnd.el' is not ported, and
    ;;     `pgtk_register_dnd_targets' with it).
    ;;   * `ATOM' and `INTEGER' *are* here - `-to-atom' and
    ;;     `-to-integer'; `SAVE_TARGETS' and `_EMACS_INTERNAL' are here -
    ;;     `-to-save-targets' and `-to-identity'.
    ;;------------------------------------------------------------------

    (define *selection-coding-system* (make-parameter #f))
    ;; ^ `selection-coding-system' (`select.el:42'): "Coding system for
    ;; communicating with other programs." The workspace's whole default
    ;; is nil - Emacs's is too, on X - and its only effect here is on
    ;; `xselect--encode-string''s choice for a *foreign* request, which
    ;; this tree does not answer (Gtk does). Named, not used.
    ;;
    ;; Emacs's `:set' also runs `set-selection-coding-system', which
    ;; resolves the value through `coding-system-base' and warns about a
    ;; name that is not one; a parameter has no setter hook here, so the
    ;; base is taken at use time instead (`xselect--encode-string').

    (define *next-selection-coding-system* (make-parameter #f))
    ;; ^ `next-selection-coding-system' (`select.el:82'): "Coding system
    ;; for the next communication with other programs... After the
    ;; communication, this variable is set to nil." Read first and
    ;; cleared by `gui-get-selection', which is the write half of the
    ;; read that is ported.

    (define (xselect--int-to-cons n)
      ;; GNU Emacs's `xselect--int-to-cons' (`select.el:576'): a number
      ;; as the `(HIGH . LOW)' pair the X protocol carries a 32-bit value
      ;; in - two 16-bit halves.
      ;;--------------------------------------------------------------
      (cons (ash n -16) (logand n 65535)))

    (define (xselect--encode-string type str can-modify prefer-string-to-c-string)
      ;; GNU Emacs's `xselect--encode-string' (`select.el:579'): the
      ;; string a *foreign* request for target TYPE is answered with, as
      ;; `(TYPE . BYTES)'.
      ;;
      ;; **The first thing it does is the whole of the local path**: a
      ;; nil TYPE means the request came from this process - the C's
      ;; `(local_request ? Qnil : target_type)' - and then STR is
      ;; answered as it stands, with no encoding at all. Every call this
      ;; tree can make today arrives here, because the backend hands Gtk
      ;; the text and never asks a converter on another program's behalf.
      ;;
      ;; The rest is Emacs's: `TEXT' is *polymorphic* - the encoding is
      ;; chosen from the string's own characters, UTF8_STRING for
      ;; anything past Latin-1, C_STRING for an eight-bit byte - and each
      ;; other type names its coding system. The final `\\0' escaping is
      ;; Emacs's too ("Most programs are unable to handle NUL bytes in
      ;; strings").
      ;;
      ;; Three substitutions this tree's data model forces, all of them
      ;; the coding layer's known shape rather than this file's:
      ;;
      ;;   * `multibyte-string-p' is always true here (`mule.sld' says
      ;;     why: every buffer is multibyte), so Emacs's
      ;;     `(not (multibyte-string-p str))' branch - "a unibyte string
      ;;     is C_STRING" - never fires.
      ;;   * the answer is a *bytevector* where Emacs's is a unibyte
      ;;     string; see `encode-coding-string' in `coding.sld'. The
      ;;     `\\0' escaping therefore walks bytes, below.
      ;;   * Emacs's compatibility tests ask `(coding-system-type
      ;;     coding)'; this tree's coding systems carry no `:coding-type'
      ;;     field, so the same question is asked of the base *name*.
      ;;     `selection-coding-system' is nil and nothing sets it, so no
      ;;     test fires today.
      ;;
      ;; The coding system names are Emacs's, and one of them -
      ;; `compound-text-with-extensions' - is not carried here (there is
      ;; no ISO-2022 in this tree), so a COMPOUND_TEXT conversion of our
      ;; own selection signals "Unknown coding system", which is what
      ;; Emacs does with a coding system it does not have.
      ;;--------------------------------------------------------------
      (if (not str)
          #f
          (if (not type)
              str
              (let* ((coding (or (*next-selection-coding-system*)
                                 (*selection-coding-system*)))
                     (coding (if coding (coding-system-base coding) #f)))
                ;; "Suppress producing escape sequences for
                ;; compositions" - there are no compositions here, so
                ;; Emacs's `remove-text-properties' after that line is
                ;; the same string; `can-modify' and the `substring' it
                ;; guards are about *mutating* the caller's string, which
                ;; a Scheme string makes unnecessary.
                (when (eq? type 'TEXT)
                  (set! type (xselect--text-target str #f)))
                (let ((bytes
                       (cond
                        ((or (eq? type 'UTF8_STRING)
                             (eq? type '#{text/plain;charset=utf-8}#))
                         (unless (and coding (eq? coding 'utf-8))
                           (set! coding 'utf-8))
                         (encode-coding-string (xselect--code-points str) coding))
                        ((eq? type 'STRING)
                         (unless coding (set! coding 'iso-latin-1))
                         (encode-coding-string (xselect--code-points str) coding))
                        ((eq? type 'text/plain)
                         (unless coding (set! coding 'us-ascii))
                         (encode-coding-string (xselect--code-points str) coding))
                        ((eq? type 'COMPOUND_TEXT)
                         (unless coding
                           (set! coding 'compound-text-with-extensions))
                         (encode-coding-string (xselect--code-points str) coding))
                        ((eq? type 'C_STRING)
                         ;; "a zero-terminated sequence of raw bytes that
                         ;; shouldn't be interpreted as text in any
                         ;; encoding" - the eight-bit characters are
                         ;; written out as their single bytes and
                         ;; nothing else is touched.
                         (encode-coding-string (xselect--code-points str)
                                               'raw-text-unix))
                        (else
                         (error (string-append "Unknown selection type: "
                                               (symbol->string type)))))))
                  (*next-selection-coding-system* #f)
                  (cons (if (and prefer-string-to-c-string (eq? type 'C_STRING))
                            'STRING
                            type)
                        (xselect--escape-nuls bytes)))))))

    (define (xselect--code-points str)
      ;; A Scheme string as the tree's code points, which is what
      ;; `encode-coding-string' takes: its `string' argument is "the
      ;; buffer's characters" and in this tree those are a `u32vector'
      ;; (`coding.sld''s note says why they cannot be a Scheme string).
      ;; It is the string-to-code-points direction of
      ;; `buffer-text-substring'.
      ;;--------------------------------------------------------------
      (list->u32vector (map char->integer (string->list str))))

    (define (xselect--escape-nuls str)
      ;; Emacs's `(string-replace \"\\0\" \"\\\\0\" str)' - "Most programs
      ;; are unable to handle NUL bytes in strings" (`select.el:672').
      ;;
      ;; STR is a *string* when `xselect--encode-string' returned it as it
      ;; stood (the local path) and the encoded *bytes* when it did not,
      ;; so this walks either. `\\\\0' is the two characters backslash and
      ;; `0', which is what the replacement is.
      ;;--------------------------------------------------------------
      (if (string? str)
          (string-join (string-split str (integer->char 0)) "\\0")
          (let ((n (bytevector-length str)))
            (let loop ((i 0) (out '()))
              (if (= i n)
                  (u8-list->bytevector (reverse out))
                  (if (= 0 (bytevector-u8-ref str i))
                      ;; push the `0' before the backslash: OUT is built
                      ;; backwards and reversed at the end
                      (loop (+ i 1) (cons 48 (cons 92 out)))
                      (loop (+ i 1) (cons (bytevector-u8-ref str i) out))))))))

    (define (xselect--text-target str coding)
      ;; The type `TEXT' stands for, chosen from STR's own characters -
      ;; `xselect--encode-string''s `(when (eq type 'TEXT) ...)'.
      ;;
      ;; Emacs walks the characters with `mapc' and three flags: one
      ;; character at or above #x100 that is *under* #x110000 makes it
      ;; UTF8_STRING, one at or above #x110000 but under #x3FFF80 makes
      ;; it COMPOUND_TEXT, and one at or above #x3FFF80 - an eight-bit
      ;; byte, `character.sld''s representation - makes it C_STRING. A
      ;; string with nothing above #x100 stays STRING, which is Latin-1.
      ;; The flags are sticky: one of each anywhere in the string is
      ;; enough, because the whole string is answered in one type.
      ;;
      ;; The `coding' argument is Emacs's one extra: with a coding
      ;; system given *and* its `:mime-charset' equal to `x-ctext',
      ;; COMPOUND_TEXT is preferred over UTF8_STRING. This tree has no
      ;; `:mime-charset' and no x-ctext, so that arm cannot fire and is
      ;; not written - named here rather than left to look like an
      ;; oversight.
      ;;--------------------------------------------------------------
      (let loop ((rest (string->list str))
                 (non-latin-1 #f) (non-unicode #f) (eight-bit #f))
        (cond ((null? rest)
               (cond ((or non-unicode (and non-latin-1 coding)) 'COMPOUND_TEXT)
                     (non-latin-1 'UTF8_STRING)
                     (eight-bit 'C_STRING)
                     (else 'STRING)))
              (else
               (let ((code (char->integer (car rest))))
                 (when (>= code #x100)
                   (cond ((< code #x110000) (set! non-latin-1 #t))
                         ((< code #x3FFF80) (set! non-unicode #t))
                         (else (set! eight-bit #t)))))
               (loop (cdr rest) non-latin-1 non-unicode eight-bit)))))

    (define (xselect-convert-to-string selection type value)
      ;; GNU Emacs's `xselect-convert-to-string' (`select.el:648'): the
      ;; text targets - `TEXT', `STRING', `UTF8_STRING', `COMPOUND_TEXT',
      ;; `text/plain' and `text/plain;charset=utf-8' all come here.
      ;;
      ;; Emacs's other arm takes a buffer, a cons of two markers or an
      ;; overlay and takes the text between its bounds; see the note on
      ;; this file's converter table for why that arm is not here.
      ;;--------------------------------------------------------------
      (let ((str (and (string? value) value)))
        (and str (xselect--encode-string type str #t #f))))

    (define (xselect-convert-to-length selection type value)
      ;; GNU Emacs's `xselect-convert-to-length' (`select.el:657'): how
      ;; long the selection is, as the `(HIGH . LOW)' pair the protocol
      ;; carries a 32-bit number in.
      ;;--------------------------------------------------------------
      (let ((len (and (string? value) (string-length value))))
        (and len (xselect--int-to-cons len))))

    (define (xselect-convert-to-targets selection type value)
      ;; GNU Emacs's `xselect-convert-to-targets' (`select.el:673'):
      ;; "Return a vector of atoms, but remove duplicates first."
      ;;
      ;; Every entry of the converter table is asked whether it can
      ;; answer for this selection and value, and the ones that say no
      ;; become the marker `_EMACS_INTERNAL', which is removed - so the
      ;; vector is exactly the targets worth asking for. TIMESTAMP and
      ;; MULTIPLE are at the front because they are not converters:
      ;; TIMESTAMP is the C's special case and MULTIPLE is the C's, and
      ;; `pgtk_get_selection_internal' errors on MULTIPLE ("Retrieving
      ;; MULTIPLE selections is currently unimplemented") - Emacs
      ;; advertises it anyway.
      ;;
      ;; An entry's cdr is either a handler or the `(PREDICATE . HANDLER)'
      ;; pair a DnD target needs; only the first kind is in the table
      ;; here, so the predicate half is not walked - named in the note
      ;; above. Emacs's test is `(consp (cdr conv))': "is the cdr a
      ;; cons", because a handler there is a *symbol* or such a pair.
      ;; Handlers here are procedures, so the same question is `pair?'.
      ;;
      ;; `delete-dups' keeps the *first* of a run of duplicates; SRFI-1's
      ;; `delete-duplicates' keeps the last, so this is written out.
      ;;--------------------------------------------------------------
      (let ((names
             (let loop ((rest (*selection-converter-alist*)) (acc '()))
               (cond ((null? rest) (reverse acc))
                     ((pair? (cdr (car rest))) (loop (cdr rest) acc))
                     (else (loop (cdr rest) (cons (car (car rest)) acc)))))))
        (let dedup ((rest (append '(TIMESTAMP MULTIPLE) names))
                    (seen '())
                    (acc '()))
          (cond ((null? rest) (list->vector (reverse acc)))
                ((memq (car rest) seen) (dedup (cdr rest) seen acc))
                (else (dedup (cdr rest)
                             (cons (car rest) seen)
                             (cons (car rest) acc)))))))

    (define (xselect-convert-to-delete selection type value)
      ;; GNU Emacs's `xselect-convert-to-delete' (`select.el:721'): "A
      ;; return value of nil means that we do not know how to do this
      ;; conversion, and replies with an error. A return value of NULL
      ;; means that we have done the conversion (and any side-effects)
      ;; but have no value to return."
      ;;
      ;; So this one *acts*: it gives the selection up and answers NULL.
      ;;--------------------------------------------------------------
      (gui-backend-set-selection selection #f)
      'NULL)

    (define (xselect-convert-to-atom selection type value)
      ;; `xselect-convert-to-atom' (`select.el:824'): a symbol answers
      ;; itself, anything else cannot be converted.
      ;;--------------------------------------------------------------
      (and (symbol? value) value))

    (define (xselect-convert-to-integer selection type value)
      ;; `xselect-convert-to-integer' (`select.el:820').
      ;;--------------------------------------------------------------
      (and (integer? value) (xselect--int-to-cons value)))

    (define (xselect-convert-to-identity selection type value)
      ;; `xselect-convert-to-identity' (`select.el:826'), "used
      ;; internally": the value as a one-element vector, which is how the
      ;; C's own round trip through `clean_local_selection_data' - it
      ;; answers a vector's single element - comes back unchanged.
      ;;--------------------------------------------------------------
      (vector value))

    (define (xselect-convert-to-save-targets selection type value)
      ;; `xselect-convert-to-save-targets' (`select.el:829'): "Null
      ;; target that tells clipboard managers we support SAVE_TARGETS
      ;; (see freedesktop.org Clipboard Manager spec)."
      ;;--------------------------------------------------------------
      (and (eq? selection 'CLIPBOARD) 'NULL))

    (define (xselect-convert-to-class selection type value)
      ;; `xselect-convert-to-class' (`select.el:802'): "This function
      ;; returns the string \"Emacs\"." The name is this tree's own,
      ;; which is the one departure - `xselect-convert-to-name' is
      ;; Emacs's "emacs" and is *deliberately* not `(downcase ...)' of
      ;; this, because "We do not try to determine the name Emacs was
      ;; invoked with".
      ;;--------------------------------------------------------------
      "Schemacs")

    (define (xselect-convert-to-name selection type value)
      ;; `xselect-convert-to-name' (`select.el:813').
      ;;--------------------------------------------------------------
      "schemacs")

    (define *selection-converter-alist* (make-parameter '()))
    ;; ^ The table itself, built once the handlers above exist - Emacs's
    ;; `setq' at the end of `select.el', in Scheme.
    ;;
    ;; The keys are target *symbols* and the values are the handlers,
    ;; because that is the shape the C reads: `pgtk_get_local_selection'
    ;; does `(CDR (ASSQ target_type Vselection_converter_alist))' and
    ;; only unwraps a `(PREDICATE . HANDLER)' cons, which none of these
    ;; is. `TIMESTAMP' is absent on purpose: it is the C's special case
    ;; and never reaches a converter.

    (*selection-converter-alist*
     (list (cons 'TEXT xselect-convert-to-string)
           (cons 'COMPOUND_TEXT xselect-convert-to-string)
           (cons 'STRING xselect-convert-to-string)
           (cons 'UTF8_STRING xselect-convert-to-string)
           (cons 'text/plain xselect-convert-to-string)
           (cons '#{text/plain;charset=utf-8}# xselect-convert-to-string)
           (cons 'TARGETS xselect-convert-to-targets)
           (cons 'LENGTH xselect-convert-to-length)
           (cons 'DELETE xselect-convert-to-delete)
           (cons 'ATOM xselect-convert-to-atom)
           (cons 'INTEGER xselect-convert-to-integer)
           (cons 'SAVE_TARGETS xselect-convert-to-save-targets)
           (cons 'CLASS xselect-convert-to-class)
           (cons 'NAME xselect-convert-to-name)
           (cons '_EMACS_INTERNAL xselect-convert-to-identity)))

    ))
