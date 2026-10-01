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
         selection-owner? selection-exists?))

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
    ;; The last member's name holds a `;', which Scheme reads as a
    ;; comment - select.el writes it `text/plain\;charset=utf-8' and
    ;; it is pipe-quoted here for the same reason.

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
                                      |text/plain;charset=utf-8|))
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

    ))
