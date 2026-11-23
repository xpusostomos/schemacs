;;----------------------------------------------------------------------
;; cc-styles.scm - a port of `cc-styles.el'
;;
;; The style system: the named sets of variable values in `c-style-alist',
;; resolving inheritance between them, applying a style to the current
;; buffer, and the two commands that change one variable or add a style.
;;
;; Ported after cc-vars, whose `defcustom-c-stylevar' work this file
;; completes: `c-style-variables', `c-fallback-style' and the
;; `c-stylevar-fallback' property are there, and each style variable
;; registers its readers there through `c-style-variable-register!' so
;; that the style system can reach `(symbol-value VAR)' and `(set VAR
;; VALUE)' without a Lisp obarray.
;;
;; Named departures, each at its own definition below:
;;   * `c-read-offset' and `c-set-offset' complete against no obarray - a
;;     Scheme name is not enumerable - so the offset is typed out;
;;   * `c-set-offset''s interactive initial contents need
;;     `c-guess-basic-syntax' (cc-engine's, not ported) and arrive through
;;     a seam that is #f until it is;
;;   * `ding' is not ported, so a rejected input reports by message alone;
;;   * `c-indentation-style' is the buffer-local slot cc-vars keeps, so
;;     `c-make-styles-buffer-local' has no per-variable work to do;
;;   * the `c-paragraph-start'/`-separate' this file appends to
;;     `paragraph-start' are cc-langs' language variables (`%c-langvar'),
;;     as they are in Emacs, not the custom variables an earlier pass had
;;     declared for them.
;;----------------------------------------------------------------------
(define-library (schemacs progmodes cc-styles)
  (import
    (scheme base)
    (only (guile) format last-pair)
    (only (schemacs buffer)
          current-buffer buffer-name buffer-local-value
          set-buffer-local-value! kill-local-variable local-variable-p
          major-mode buffer-fill-column set!buffer-fill-column)
    (only (schemacs editfns) message)
    (only (schemacs minibuffer)
          make<history>
          completing-read read-from-minibuffer eval-minibuffer)
    ;; `completion-ignore-case` is `minibuf.c`'s, and that file is
    ;; `minibuf.scm` here, beside the minibuffer rather than in it.
    (only (schemacs minibuf) *completion-ignore-case*)
    (only (schemacs files) y-or-n-p)
    (only (schemacs command) define-command current-prefix-arg)
    (only (schemacs subr) intern car-safe cdr-safe)
    (only (schemacs fns) copy-alist concat nconc nreverse)
    (only (schemacs search) string-match)
    (only (schemacs casefiddle) downcase upcase)
    (only (schemacs symbol-props) get put)
    (only (schemacs indentc) *indent-tabs-mode*)
    (only (schemacs textmodes paragraphs)
          paragraph-start set!paragraph-start
          paragraph-separate set!paragraph-separate
          paragraph-ignore-fill-prefix set!paragraph-ignore-fill-prefix
          *page-delimiter*)
    (only (schemacs textmodes fill)
          fill-column
          adaptive-fill-mode set!adaptive-fill-mode
          adaptive-fill-regexp set!adaptive-fill-regexp
          *adaptive-fill-regexp*
          adaptive-fill-first-line-regexp
          set!adaptive-fill-first-line-regexp)
    (only (schemacs progmodes cc-defs) c-keep-region-active *c-buffer-is-cc-mode*)
    (only (schemacs progmodes cc-engine) c-benign-error %c-langvar %c-cdr)
    (only (schemacs progmodes cc-vars)
          c-style-variables c-fallback-style
          c-set-stylevar-fallback c-stylevar-fallback
          c-style-variable-register! c-style-variable-value
          c-style-variable-set! c-style-variable-default
          c-valid-offset c-string-or-string-list-p
          *c-style-variables-are-local-p* *c-old-style-variable-behavior*
          *c-default-style*
          c-indentation-style set!c-indentation-style
          c-basic-offset set!c-basic-offset
          c-comment-only-line-offset set!c-comment-only-line-offset
          c-indent-comment-alist set!c-indent-comment-alist
          c-indent-comments-syntactically-p set!c-indent-comments-syntactically-p
          c-block-comment-prefix set!c-block-comment-prefix
          c-comment-prefix-regexp set!c-comment-prefix-regexp
          c-doc-comment-style set!c-doc-comment-style
          c-cleanup-list set!c-cleanup-list
          c-hanging-braces-alist set!c-hanging-braces-alist
          c-hanging-colons-alist set!c-hanging-colons-alist
          c-hanging-semi&comma-criteria set!c-hanging-semi&comma-criteria
          c-backslash-column set!c-backslash-column
          c-backslash-max-column set!c-backslash-max-column
          c-special-indent-hook set!c-special-indent-hook
          c-label-minimum-indentation set!c-label-minimum-indentation
          c-offsets-alist set!c-offsets-alist
          c-current-comment-prefix set!c-current-comment-prefix
          c-string-par-start c-string-par-separate
          c-sentence-end-with-esc-eol c-default-value-sentence-end))

  (export
   c-style-alist
   c-set-style-1 c-get-style-variables c-set-style
   c-add-style c-read-offset c-set-offset
   c-setup-paragraph-variables c-setup-filladapt
   c-initialize-builtin-style c-make-styles-buffer-local
   cc-choose-style-for-mode
   c-set-style-history c-read-offset-history
   *c-guess-basic-syntax-function*
   filladapt-token-table filladapt-token-match-table
   filladapt-token-conversion-table)

  (begin

;; `c-style-alist' (`cc-styles.el:54'): the ten built-in styles, emitted
;; from GNU Emacs 31.1's own value by a script and compared against
;; GITE's `cc-styles.el' - they are equal, so this is the source's data.
;; (`tools/gen-imports.scm' regenerates only the import list; the data is
;; a transcription like the chartab and charset tables.)
(define c-style-alist
  '(( "gnu" (c-basic-offset . 2) (c-comment-only-line-offset . (0 . 0)) (c-hanging-braces-alist (substatement-open before after) (arglist-cont-nonempty)) (c-offsets-alist (statement-block-intro . +) (knr-argdecl-intro . 5) (substatement-open . +) (substatement-label . 0) (label . 0) (statement-case-open . +) (statement-cont . +) (arglist-intro . c-lineup-arglist-intro-after-paren) (arglist-close . c-lineup-arglist-close-under-paren) (inline-open . 0) (brace-list-open . +) (brace-list-intro first c-lineup-2nd-brace-entry-in-arglist c-lineup-class-decl-init-+ +) (topmost-intro-cont first c-lineup-topmost-intro-cont c-lineup-gnu-DEFUN-intro-cont)) (c-special-indent-hook . c-gnu-impose-minimum) (c-block-comment-prefix . "")) ("k&r" (c-basic-offset . 5) (c-comment-only-line-offset . 0) (c-offsets-alist (statement-block-intro . +) (knr-argdecl-intro . 0) (substatement-open . 0) (substatement-label . 0) (label . 0) (statement-cont . +))) ("bsd" (c-basic-offset . 8) (c-comment-only-line-offset . 0) (c-offsets-alist (statement-block-intro . +) (knr-argdecl-intro . +) (substatement-open . 0) (substatement-label . 0) (label . 0) (statement-cont . +) (inline-open . 0) (brace-list-intro first c-lineup-2nd-brace-entry-in-arglist c-lineup-class-decl-init-+ +) (inexpr-class . 0))) ("stroustrup" (c-basic-offset . 4) (c-comment-only-line-offset . 0) (c-offsets-alist (statement-block-intro . +) (substatement-open . 0) (substatement-label . 0) (label . 0) (brace-list-intro first c-lineup-2nd-brace-entry-in-arglist c-lineup-class-decl-init-+ +) (statement-cont . +))) ("whitesmith" (c-basic-offset . 4) (c-comment-only-line-offset . 0) (c-offsets-alist (defun-open . +) (defun-close . c-lineup-whitesmith-in-block) (defun-block-intro add c-lineup-whitesmith-in-block c-indent-multi-line-block) (class-open . +) (class-close . +) (inline-open . +) (inline-close . c-lineup-whitesmith-in-block) (knr-argdecl-intro . +) (block-open . 0) (block-close . c-lineup-whitesmith-in-block) (brace-list-open . +) (brace-list-close . c-lineup-whitesmith-in-block) (brace-list-intro add c-lineup-whitesmith-in-block c-indent-multi-line-block) (brace-list-entry add c-lineup-after-whitesmith-blocks c-indent-multi-line-block) (brace-entry-open add c-lineup-after-whitesmith-blocks c-indent-multi-line-block) (statement add c-lineup-after-whitesmith-blocks c-indent-multi-line-block) (statement-block-intro add c-lineup-whitesmith-in-block c-indent-multi-line-block) (substatement-open . +) (substatement-label . +) (label . 0) (arglist-intro add c-lineup-whitesmith-in-block c-indent-multi-line-block) (arglist-cont add c-lineup-after-whitesmith-blocks c-indent-multi-line-block) (arglist-cont-nonempty add c-lineup-whitesmith-in-block c-indent-multi-line-block) (arglist-close . c-lineup-whitesmith-in-block) (inclass . c-lineup-whitesmith-in-block) (extern-lang-open . +) (namespace-open . +) (module-open . +) (composition-open . +) (extern-lang-close . +) (namespace-close . +) (module-close . +) (composition-close . +) (inextern-lang . c-lineup-whitesmith-in-block) (innamespace . c-lineup-whitesmith-in-block) (inmodule . c-lineup-whitesmith-in-block) (incomposition . c-lineup-whitesmith-in-block) (inexpr-class . 0))) ("ellemtel" (c-basic-offset . 3) (c-comment-only-line-offset . 0) (c-hanging-braces-alist (substatement-open before after) (arglist-cont-nonempty)) (c-offsets-alist (topmost-intro . 0) (substatement . +) (substatement-open . 0) (case-label . +) (access-label . -) (inclass . +) (inline-open . 0))) ("linux" (indent-tabs-mode . #t) (c-basic-offset . 8) (c-comment-only-line-offset . 0) (c-hanging-braces-alist (brace-list-open) (brace-entry-open) (substatement-open after) (block-close . c-snug-do-while) (arglist-cont-nonempty)) (c-cleanup-list brace-else-brace) (c-offsets-alist (statement-block-intro . +) (knr-argdecl-intro . 0) (substatement-open . 0) (substatement-label . 0) (label . 0) (statement-cont . +))) ("python" (indent-tabs-mode . #t) (fill-column . 78) (c-basic-offset . 8) (c-offsets-alist (substatement-open . 0) (inextern-lang . 0) (arglist-intro . +) (brace-list-intro first c-lineup-2nd-brace-entry-in-arglist c-lineup-class-decl-init-+ +) (knr-argdecl-intro . +)) (c-hanging-braces-alist (brace-list-open) (brace-list-intro) (brace-list-close) (brace-entry-open) (substatement-open after) (block-close . c-snug-do-while) (arglist-cont-nonempty)) (c-block-comment-prefix . "")) ("java" (c-basic-offset . 4) (c-comment-only-line-offset . (0 . 0)) (c-offsets-alist (inline-open . 0) (topmost-intro-cont . +) (statement-block-intro . +) (knr-argdecl-intro . 5) (substatement-open . +) (substatement-label . +) (label . +) (statement-case-open . +) (statement-cont . +) (arglist-intro . c-lineup-arglist-intro-after-paren) (arglist-close . c-lineup-arglist-close-under-paren) (brace-list-intro first c-lineup-2nd-brace-entry-in-arglist c-lineup-class-decl-init-+ +) (access-label . 0) (inher-cont . c-lineup-java-inher) (func-decl-cont . c-lineup-java-throws))) ("awk" (c-basic-offset . 4) (c-comment-only-line-offset . 0) (c-hanging-braces-alist (defun-open after) (defun-close . c-snug-1line-defun-close) (substatement-open after) (block-close . c-snug-do-while) (arglist-cont-nonempty)) (c-hanging-semi&comma-criteria) (c-cleanup-list) (c-offsets-alist (statement-block-intro . +) (substatement-open . 0) (statement-cont . +)))))

;; **Two of the styles name variables that are not style variables.**
;; `linux' sets `indent-tabs-mode' and `python' sets `fill-column';
;; Emacs's `c-set-style-1' reaches any symbol with `set', and the two
;; readers below are this tree's way to do the same for them. The global
;; `*indent-tabs-mode*' is where `indent-tabs-mode' lives here (indentc),
;; and `fill-column' is the current buffer's slot.
(c-style-variable-register! 'indent-tabs-mode
  (lambda () (*indent-tabs-mode*))
  (lambda (value) (*indent-tabs-mode* value))
  (lambda () (*indent-tabs-mode*)))
(c-style-variable-register! 'fill-column
  (lambda () (fill-column))
  (lambda (value) (set!buffer-fill-column (current-buffer) value))
  (lambda () (buffer-fill-column (current-buffer))))

(define (c-set-style-1 conscell dont-override)
  ;; "Set the style for one variable."
  ;;
  ;; The C reaches the variable through `symbol-value' and `set'; the
  ;; registrations in cc-vars are this tree's version of that. The two
  ;; special variables, `c-offsets-alist' and `c-special-indent-hook',
  ;; are set through their own commands and a local hook addition.
  (let ((attr (car conscell))
        (val (cdr conscell)))
    (cond
     ;; first special variable
     ((eq? attr 'c-offsets-alist)
      (let ((offsets (cond ((eq? dont-override #t) (c-offsets-alist))
                           (dont-override
                            (c-style-variable-default 'c-offsets-alist))
                           (else '()))))
        (for-each
         (lambda (langentry)
           (let ((langelem (car langentry))
                 (offset (cdr langentry)))
             (unless (assq langelem offsets)
               (c-set-offset langelem offset))))
         val)))
     ;; second special variable
     ((eq? attr 'c-special-indent-hook)
      ;; "Maybe we should ignore dont-override here and always add new
      ;; hooks?" - the C's own comment, kept.
      (unless (let ((hook (cond ((eq? dont-override #t)
                                 (c-special-indent-hook))
                                (dont-override
                                 (c-style-variable-default
                                  'c-special-indent-hook))
                                (else '()))))
                (and (pair? hook) hook))
        (if (list? val)
            (for-each (lambda (function) (c-add-local-hook function)) val)
            (c-add-local-hook val))))
     ;; all other variables
     (else
      (when (or (not dont-override)
                (not (memq attr c-style-variables))
                (eq? (if (eq? dont-override #t)
                         (c-style-variable-value attr)
                         (c-style-variable-default attr))
                     'set-from-style))
        (c-style-variable-set! attr val)
        ;; "Must update a number of other variables if
        ;; `c-comment-prefix-regexp' is set."
        (when (eq? attr 'c-comment-prefix-regexp)
          (c-setup-paragraph-variables)))))))

(define (c-add-local-hook function)
  ;; The local half of `add-hook' (`subr.el'), for
  ;; `c-special-indent-hook' - the one hook this file adds to with LOCAL.
  ;; The tree's `add-hook' has no LOCAL arm: its HOOK is a parameter, and
  ;; a buffer-local variable is a slot, so the addition is made to the
  ;; buffer's own value. DEPTH is t in both calls, which is the end of
  ;; the list, and a function already there is not added twice.
  ;; `add-hook' with LOCAL (`subr.el:2330'): a hook with no buffer-local
  ;; value yet is made local with the list `(t)' - "run the global value
  ;; as well" - and FUNCTION is appended unless it is already there. That
  ;; is why Emacs's buffer value after the gnu style is
  ;; `(t c-gnu-impose-minimum)' and not a bare list.
  (unless (local-variable-p 'c-special-indent-hook)
    (set!c-special-indent-hook (list #t)))
  ;; "If the hook value is a single function, turn it into a list."
  (let ((hook (c-special-indent-hook)))
    (unless (or (null? hook) (pair? hook))
      (set!c-special-indent-hook (list hook))))
  (unless (memq function (c-special-indent-hook))
    (set!c-special-indent-hook
     (append (c-special-indent-hook) (list function)))))

(define (c-get-style-variables style basestyles)
  ;; "Return all variables in a style by resolving inheritances."
  (if (not style)
      (copy-alist c-fallback-style)
      ;; `(cdr nil)' is nil in Emacs, and an undefined style leaves VARS
      ;; nil so that the fallback still merges in - `%c-cdr' is that cdr.
      (let ((vars (%c-cdr (or (assoc (downcase style) c-style-alist)
                              (assoc (upcase style) c-style-alist)
                              (assoc style c-style-alist)
                              (begin
                                (c-benign-error "Undefined style: ~a" style)
                                #f)))))
        (let ((base (and (pair? vars) (string? (car vars))
                         (downcase (car vars)))))
          (when base
            (set! vars (cdr vars)))
          ;; The C's `memq' over strings: only ever equal by identity, so
          ;; the loop check cannot fire - kept as the C has it.
          (if (memq base basestyles)
              (c-benign-error "Style loop detected: ~a in ~a" base basestyles)
              (nconc (c-get-style-variables base (cons base basestyles))
                     (copy-alist vars)))))))

(define c-set-style-history (make<history> '()))
;; ^ "History list for `c-set-style'." A `<history>' record and not the
;; symbol Emacs names, because this tree's minibuffer takes the record.

(define-command (c-set-style stylename . rest)
  "Set the current buffer to use the style STYLENAME.
STYLENAME, a string, must be an existing CC Mode style - These are contained
in the variable `c-style-alist'.

The variable `c-indentation-style' will get set to STYLENAME.

\"Setting the style\" is done by setting CC Mode's \"style variables\" to the
values indicated by the pertinent entry in `c-style-alist'.  Other variables
might get set too.

If DONT-OVERRIDE is neither nil nor t, style variables whose default values
have been set (more precisely, whose default values are not the symbol
`set-from-style') will not be changed.  This avoids overriding global settings
done in your init file.  It is useful to call c-set-style from a mode hook
in this way.

If DONT-OVERRIDE is t, style variables that already have values (i.e., whose
values are not the symbol `set-from-style') will not be overridden.  CC Mode
calls c-set-style internally in this way whilst initializing a buffer; if
c-set-style is called like this from anywhere else, it will usually behave as
a null operation."
  (interactive
   (list (let ((prompt (format #f "Which ~a indentation style? "
                               (mode-name))))
           (parameterize ((*completion-ignore-case* #t))
             (completing-read prompt c-style-alist #f #t #f
                              c-set-style-history
                              (c-indentation-style))))))
  (let ((dont-override (if (pair? rest) (car rest) #f)))
    (or (*c-buffer-is-cc-mode*)
        (error "Buffer ~a is not a CC Mode buffer (c-set-style)"
               (buffer-name (current-buffer))))
    (or (string? stylename)
        (error "Argument to c-set-style was not a string"))
    (c-initialize-builtin-style)
    (let ((vars (c-get-style-variables stylename '())))
      (unless dont-override
        ;; "Since we always add to `c-special-indent-hook' we must reset
        ;; it first, or else the hooks from the preceding style will
        ;; remain."
        (kill-local-variable 'c-special-indent-hook))
      (for-each
       (lambda (elem) (c-set-style-1 elem dont-override))
       ;; "Need to go through the variables backwards when we don't
       ;; override any settings."
       (if (eq? dont-override #t) (nreverse vars) vars)))
    (set!c-indentation-style stylename)
    (c-keep-region-active)))

(define-command (c-add-style style description . rest)
  "Add a style to `c-style-alist', or update an existing one.
STYLE is a string identifying the style to add or update.  DESCRIPTION
is an association list describing the style and must be of the form:

  ([BASESTYLE] (VARIABLE . VALUE) [(VARIABLE . VALUE) ...])

See the variable `c-style-alist' for the semantics of BASESTYLE,
VARIABLE and VALUE.  This function also sets the current style to
STYLE using `c-set-style' if the optional SET-P flag is non-nil."
  (interactive
   (let ((stylename (completing-read "Style to add: " c-style-alist
                                     #f #f #f c-set-style-history))
         (descr (eval-minibuffer "Style description: ")))
     (list stylename descr
           (y-or-n-p "Set the style too? "))))
  (let ((set-p (if (pair? rest) (car rest) #f)))
    (set! style (downcase style))
    (let ((s (assoc style c-style-alist)))
      (if s
          (set-cdr! s (copy-alist description)) ; replace
          (set! c-style-alist (cons (cons style description) c-style-alist))))
    (and set-p (c-set-style style))))

(define c-read-offset-history (make<history> '()))
;; ^ "History list for `c-read-offset'."

(define (c-read-offset langelem)
  ;; "Read new offset value for LANGELEM from minibuffer. Return a valid
  ;; value only."
  ;;
  ;; **The completion table is not carried.** Emacs sets
  ;; `minibuffer-completion-table' to `obarray' with `fboundp' as the
  ;; predicate, so an offset naming a function completes; there is no
  ;; obarray here and nothing enumerates the bindings. The value is typed
  ;; out (the `a' interactive code carries the same departure).
  (let* ((entry (or (assq langelem (c-offsets-alist))
                    (assq langelem (c-stylevar-fallback 'c-offsets-alist))))
         (oldoff (and entry (cdr entry)))
         (symname (symbol->string langelem))
         (defstr (format #f "(default ~a): "
                         (if oldoff oldoff "nil")))
         (errmsg (string-append "Offset must be int, func, var, vector, list, "
                                "a syntactic symbol, or [+,-,++,--,*,/] "
                                defstr))
         (prompt (string-append symname " offset " defstr))
         (offset #f))
    (let loop ()
      (unless offset
        (let ((input (read-from-minibuffer
                      prompt #f #f c-read-offset-history
                      (format #f "~a" (if oldoff oldoff "nil")))))
          (if (c-valid-offset input)
              (set! offset input)
              ;; "error, but don't signal one, keep trying to read an
              ;; input value" - `ding' is not ported, so the message is
              ;; the whole report and the prompt becomes the error text.
              (set! prompt errmsg)))
        (loop)))
    offset))

(define *c-guess-basic-syntax-function* (make-parameter #f))
;; ^ The seam for `c-guess-basic-syntax' (`cc-engine.el'), which the
;; cc-engine port has not reached (it is in the indentation-analysis
;; section at that file's end). What the seam buys is `c-set-offset''s
;; initial input naming the current line's syntactic element.

(define-command (c-set-offset symbol offset . ignored)
  "Change the value of a syntactic element symbol in `c-offsets-alist'.
SYMBOL is the syntactic element symbol to change and OFFSET is the new
offset for that syntactic element.  The optional argument is not used
and exists only for compatibility reasons."
  (interactive
   (let* ((langelem
           (intern (completing-read
                    (string-append "Syntactic symbol to change"
                                   (if (current-prefix-arg) " or add" "")
                                   ": ")
                    (map (lambda (entry)
                           (cons (format #f "~a" (car entry)) #f))
                         (c-stylevar-fallback 'c-offsets-alist))
                    #f (not (current-prefix-arg))
                    ;; "initial contents tries to be the last element on
                    ;; the syntactic analysis list for the current line".
                    ;; **`c-guess-basic-syntax' is cc-engine's and is not
                    ;; ported**, so the seam answers #f and the prompt has
                    ;; no initial contents until it is.
                    (and (*c-buffer-is-cc-mode*)
                         (*c-guess-basic-syntax-function*)
                         (let ((syntax (*c-guess-basic-syntax-function*)))
                           (and (pair? syntax)
                                (cons (format #f "~a"
                                              (car (last-pair syntax)))
                                      0)))))))
          (offset (c-read-offset langelem)))
     (list langelem offset (current-prefix-arg))))
  ;; sanity check offset
  (if (c-valid-offset offset)
      (let ((entry (assq symbol (c-offsets-alist))))
        (if entry
            (set-cdr! entry offset)
            (if (assq symbol (c-stylevar-fallback 'c-offsets-alist))
                ;; Emacs's `setq' writes the style variable, which is the
                ;; buffer's own value (`set'), not the global default.
                (set!c-offsets-alist (cons (cons symbol offset)
                                           (c-offsets-alist)))
                (c-benign-error "~a is not a valid syntactic symbol" symbol))))
      (c-benign-error "Invalid indentation setting for symbol ~a: ~s"
                      symbol offset))
  (c-keep-region-active))

(define-command (c-setup-paragraph-variables)
  "Fix things up for paragraph recognition and filling inside comments and
strings by incorporating the values of `c-comment-prefix-regexp',
`sentence-end', `paragraph-start' and `paragraph-separate' in the relevant
variables."
  (interactive)
  (or (*c-buffer-is-cc-mode*)
      (error "Buffer ~a is not a CC Mode buffer (c-setup-paragraph-variables)"
             (buffer-name (current-buffer))))
  ;; Set up the values for use in comments.
  (set!c-current-comment-prefix
   (if (list? (c-comment-prefix-regexp))
       (let ((entry (or (assoc (major-mode) (c-comment-prefix-regexp))
                        (assoc 'other (c-comment-prefix-regexp)))))
         (and entry (cdr entry)))
       (c-comment-prefix-regexp)))
  (let* ((prefix (c-current-comment-prefix))
         (empty-is-prefix (string-match prefix ""))
         (nonws-comment-line-prefix (concat "\\(" prefix "\\)[ \t]*"))
         (comment-line-prefix (concat "[ \t]*" nonws-comment-line-prefix))
         (blank-or-comment-line-prefix
          (concat "[ \t]*"
                  (if empty-is-prefix "" "\\(")
                  nonws-comment-line-prefix
                  (if empty-is-prefix "" "\\)?"))))
    (set!paragraph-start
     (concat blank-or-comment-line-prefix
             (%c-langvar 'c-paragraph-start)
             "\\|" (*page-delimiter*)))
    (set!paragraph-separate
     (concat blank-or-comment-line-prefix
             (%c-langvar 'c-paragraph-separate)
             "\\|" (*page-delimiter*)))
    (set!paragraph-ignore-fill-prefix #t)
    (set!adaptive-fill-mode #t)
    (set!adaptive-fill-regexp
     (concat comment-line-prefix
             (if (*adaptive-fill-regexp*)
                 (concat "\\(" (*adaptive-fill-regexp*) "\\)")
                 "")))
    ;; "XEmacs adaptive fill mode doesn't have this" - and neither has
    ;; this tree a `boundp' to ask, since fill.scm always defines it.
    (set!adaptive-fill-first-line-regexp
     (concat "\\`" comment-line-prefix "\\'")))
  ;; Set up the values for use in strings.
  (set! c-string-par-start
        ;; The C's commented-out concat, kept as the value it settled on:
        ;; a formfeed, or whitespace and an optional backslash at the end
        ;; of a line.
        "\f\\|[ \t]*\\\\?$")
  (set! c-string-par-separate
        "[ \t\f]*\\\\?$")
  (set! c-sentence-end-with-esc-eol
        (concat "\\(\\(" (c-default-value-sentence-end) "\\)"
                ;; "N.B.: `$' would be invalid when not enclosed like
                ;; `\\($\\)'."
                "\\|" "[.?!][]\"')}]* ?\\\\\\($\\)[ \t\n]*"
                "\\)"))
  #f)

;; Helper for setting up Filladapt mode. It's not used by CC Mode itself.
(define filladapt-token-table '())
(define filladapt-token-match-table '())
(define filladapt-token-conversion-table '())
;; ^ The three variables `filladapt.el' defines. The package is not
;; ported and is not part of Emacs, so they start empty with the shape
;; `c-setup-filladapt' appends to (named departure: with filladapt loaded
;; its defaults would be filled in).

(define (c-setup-filladapt)
  "Convenience function to configure Kyle E. Jones' Filladapt mode for
CC Mode by making sure the proper entries are present on
`filladapt-token-table', `filladapt-token-match-table', and
`filladapt-token-conversion-table'.  This is intended to be used on
`c-mode-common-hook' or similar."
  ;; "The default configuration already handles C++ comments, but we need
  ;; to add handling of C block comments. A new filladapt token
  ;; `c-comment' is added for that."
  (let loop ((p filladapt-token-table))
    (unless (or (not (pair? p))
                (eq? (car-safe (cdr-safe (car-safe p))) 'c-comment))
      (loop (cdr-safe p)))
    (if (pair? p)
        (set-car! (car p) (c-current-comment-prefix))
        (set! filladapt-token-table
              (append (list (car-safe filladapt-token-table)
                            (list (c-current-comment-prefix) 'c-comment))
                      (cdr-safe filladapt-token-table)))))
  (unless (assq 'c-comment filladapt-token-match-table)
    (set! filladapt-token-match-table
          (append (list (list 'c-comment 'c-comment))
                  filladapt-token-match-table)))
  (unless (assq 'c-comment filladapt-token-conversion-table)
    (set! filladapt-token-conversion-table
          (append (list (cons 'c-comment 'exact))
                  filladapt-token-conversion-table)))
  #f)

(define (c-initialize-builtin-style)
  ;; "Dynamically append the default value of most variables. This is
  ;; crucial because future `c-set-style' calls will always reset the
  ;; variables first to the `cc-mode' style before instituting the new
  ;; style. Only do this once!"
  (unless (get 'c-initialize-builtin-style 'is-run)
    (put 'c-initialize-builtin-style 'is-run #t)
    (unless (assoc "user" c-style-alist)
      (let ((uservars '()))
        (for-each
         (lambda (var)
           (let ((val (c-style-variable-value var)))
             (cond ((eq? var 'c-offsets-alist)
                    ;; `(or (null val) (setq uservars ...))' - an empty
                    ;; `c-offsets-alist' contributes nothing.
                    (unless (null? val)
                      (set! uservars (cons (cons 'c-offsets-alist val)
                                           uservars))))
                   ((not (eq? val 'set-from-style))
                    (set! uservars (cons (cons var val) uservars))))))
         c-style-variables)
        (c-add-style "user" uservars #f)))
    (unless (assoc "cc-mode" c-style-alist)
      (c-add-style "cc-mode" '("user") #f))
    (if (*c-style-variables-are-local-p*)
        (c-make-styles-buffer-local #f)))
  #f)

(define (c-make-styles-buffer-local . args)
  "Make all CC Mode style variables buffer local.
If THIS-BUF-ONLY-P is non-nil, the style variables will be made
buffer local only in the current buffer.  Otherwise they'll be made
permanently buffer local in any buffer that changes their values.

The buffer localness of the style variables are normally controlled
with the variable `c-style-variables-are-local-p', so there's seldom
any reason to call this function directly."
  (let ((this-buf-only-p (if (pair? args) (car args) #f)))
    ;; **The per-variable loop is not carried**: every style variable is
    ;; already a buffer-local slot in this tree (cc-vars' accessor pairs),
    ;; and `c-indentation-style' with them, so `make-local-variable' and
    ;; `make-variable-buffer-local' have nothing to do. What is left is
    ;; the permanent flag the C sets when the call is not buffer-only.
    (if this-buf-only-p
        #f
        (begin (*c-style-variables-are-local-p* #t) #t))))

(define (cc-choose-style-for-mode mode default-style)
  "Return suitable style for MODE from DEFAULT-STYLE.
DEFAULT-STYLE has the same format as `c-default-style'."
  (if (string? default-style)
      default-style
      (or (let ((entry (assq mode default-style)))
            (and entry (cdr entry)))
          (let ((entry (assq 'other default-style)))
            (and entry (cdr entry)))
          "gnu")))

))
