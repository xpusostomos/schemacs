(define-library (schemacs editor font-lock)
  ;; This library mirrors GNU Emacs's `lisp/font-lock.el' - the keyword
  ;; fontification engine that `(require 'font-lock)' and `(font-lock-mode 1)'
  ;; turn on, and which every major mode asks for by setting
  ;; `font-lock-defaults' to a `font-lock-keywords' list.
  ;;
  ;; **What is here is the keyword half.** `font-lock.el' fontifies a
  ;; region in two passes: `font-lock-fontify-syntactically-region',
  ;; which finds comments and strings from the *syntax table* and gives
  ;; them `font-lock-comment-face' and `font-lock-string-face', and
  ;; `font-lock-fontify-keywords-region', which runs the regexps the mode
  ;; supplies. The second is ported here; the first is six lines in Emacs
  ;; standing on `parse-partial-sexp', which is `syntax.c''s and is *not*
  ;; ported - `syntax.sld' has `skip-chars-forward' and
  ;; `skip-chars-backward' and nothing else. So a mode's own patterns
  ;; fontify and its comments do not. Named rather than faked, and with
  ;; it: `font-lock-fontify-syntactically-region',
  ;; `font-lock-keywords-only', `font-lock-syntactic-keywords',
  ;; `font-lock-syntactic-face-function', `font-lock-syntax-table',
  ;; `font-lock-comment-start-skip'/`-end-skip', `syntax-propertize' (so
  ;; `font-lock-extend-region-wholelines' with it), and the
  ;; `font-lock-keywords-alist'/`-removed-keywords-alist' walk in
  ;; `font-lock-set-defaults'.
  ;;
  ;; **The channel is the `face' text property**, as it is in Emacs -
  ;; `font-lock-apply-highlight' ends in a `put-text-property ... 'face',
  ;; checked in the source rather than assumed - and `xdisp.sld' already
  ;; draws those, so nothing new is needed of the display.
  ;;
  ;; One departure is worth stating. In Emacs a FACENAME in a keyword is
  ;; an *expression*, evaluated when the keyword is first used, so
  ;; `'(".+" (dired-move-to-filename) nil (0 dired-marked-face))' names
  ;; the *variable* `dired-marked-face' and `eval' reads it. There is no
  ;; `eval' of that kind here - a keyword list is Scheme source, so it
  ;; holds the value it means - and a value that is a procedure is
  ;; called, which is the same door `(eval . FORM)' and
  ;; `font-lock-eval-keywords' come in by.
  ;;
  ;; `define-minor-mode' does not exist in this tree yet, so
  ;; `font-lock-mode' is a command that toggles a variable, as
  ;; `blink-cursor-mode' is; what it would add - the mode-line lighter,
  ;; the customize group, `font-lock-mode-hook' - is named on it rather
  ;; than faked.
  ;;
  ;; And `with-silent-modifications', which wraps Emacs's fontification
  ;; to keep it out of the undo list and off the modified flag, is *not*
  ;; needed here and so is not written: a text-property change in this
  ;; tree does neither (`insert' and `delete' are what touch the undo
  ;; list and the modified flag, and the engine's, not the property
  ;; layer's). Named, not faked.

  (import
    (scheme base)
    (scheme char)
    ;; `cdddr' is `(scheme cxr)''s, not `(scheme base)''s - the
    ;; distinction that has bitten this tree before
    (only (scheme cxr) cdddr)
    ;; `delq' is Guile's list `delete' - R7RS has no destructive one -
    ;; and `/=', which `(scheme base)' has not got. `last' is SRFI 1's,
    ;; which `font-lock-choose-keywords' takes the last element of a
    ;; keyword list with.
    (only (guile) delq)
    (only (srfi 1) last)
    ;; the `face' property, and the removals font-lock makes
    (only (schemacs editor textprop)
          get-text-property put-text-property add-text-properties keyword?
          next-single-property-change previous-single-property-change
          remove-list-of-text-properties text-property-any
          text-property-not-all)
    ;; the region: its ends, and the search that walks it
    (only (schemacs editor editfns)
          buffer-substring forward-line goto-char line-beginning-position
          line-end-position point point-marker point-max point-min
          save-excursion)
    (only (schemacs editor search)
          match-beginning match-end re-search-forward save-match-data)
    ;; `font-lock-mode''s buffer, and the `defvar-local' variables it
    ;; keeps on it
    (only (schemacs editor buffer)
          *current-buffer* buffer-local-value buffer-name current-buffer
          major-mode set-buffer-local-value! set-buffer-modified-p)
    ;; the hook `font-lock-mode' hangs its incremental fontification on:
    ;; `after-change-functions' is `buffer.c''s, and the engine holds it
    (only (schemacs editor engine)
          *after-change-functions* marker-position set-marker!)
    (only (schemacs editor command) current-prefix-arg define-command)
    (only (schemacs editor frame) *current-frame* set!frame-message)
    ;; the faces above are `defface''d here, as font-lock.el deffaces them
    (only (schemacs editor faces) defface))

  (export
   *font-lock-defaults*
   *font-lock-extra-managed-props*
   *font-lock-fontify-region-function*
   *font-lock-fontified*
   *font-lock-keywords*
   *font-lock-keywords-case-fold-search*
   *font-lock-maximum-decoration*
   *font-lock-mode*
   *font-lock-multiline*
   *font-lock-set-defaults*
   *font-lock-support-mode*
   *font-lock-unfontify-region-function*
   font-lock-add-keywords
   font-lock-after-change-function
   font-lock-append-text-property
   font-lock-apply-highlight
   font-lock-choose-keywords
   font-lock-compile-keyword
   font-lock-compile-keywords
   font-lock-default-fontify-buffer
   font-lock-defaults
   font-lock-default-fontify-region
   font-lock-default-unfontify-buffer
   font-lock-default-unfontify-region
   font-lock-ensure
   font-lock-eval-keywords
   font-lock-extend-region-multiline
   font-lock-fillin-text-property
   font-lock-flush
   font-lock-fontify-anchored-keywords
   font-lock-fontify-buffer
   font-lock-fontify-keywords-region
   font-lock-fontified
   font-lock-fontify-region
   font-lock-initial-fontify
   font-lock-keywords
   font-lock-mode-internal
   font-lock-mode-on?
   font-lock-prepend-text-property
   font-lock-remove-keywords
   font-lock-set-defaults
   font-lock-set-defaults-done?
   font-lock-specified-p
   font-lock-unfontify-buffer
   font-lock-unfontify-region
   font-lock-value-in-major-mode
   set!font-lock-defaults!
   set!font-lock-mode!
   set!font-lock-keywords!)

  (begin

    ;;----------------------------------------------------------------
    ;; The faces
    ;;
    ;; GNU Emacs's "Color etc. support" section (font-lock.el:1984): the
    ;; faces a mode's keywords name. They are `font-lock.el''s own
    ;; `defface's and not `faces.el''s, which is why they are here.
    ;;
    ;; Emacs 31 marks the `font-lock-*-face' *variables* obsolete - "use
    ;; the quoted symbol instead" - so what a keyword names here is the
    ;; symbol, as in `'(".+" (dired-move-to-filename) nil (0
    ;; font-lock-comment-face))'. Nothing in this tree has the variables,
    ;; so there is nothing to mark obsolete.
    ;;
    ;; Each spec is Emacs's, character for character, including the
    ;; 8-colour rows - this tree draws on a terminal, and `(min-colors 8)'
    ;; is the row that one takes.
    ;;------------------------------------------------------------------

    (defface 'font-lock-comment-face
          '((((class grayscale) (background light))
             :foreground "DimGray" :weight bold :slant italic)
            (((class grayscale) (background dark))
             :foreground "LightGray" :weight bold :slant italic)
            (((class color) (min-colors 88) (background light))
             :foreground "Firebrick")
            (((class color) (min-colors 88) (background dark))
             :foreground "chocolate1")
            (((class color) (min-colors 16) (background light))
             :foreground "red")
            (((class color) (min-colors 16) (background dark))
             :foreground "red1")
            (((class color) (min-colors 8) (background light))
             :foreground "red")
            (((class color) (min-colors 8) (background dark))
             :foreground "yellow")
            (#t :weight bold :slant italic))
          "Font Lock mode face used to highlight comments.")

    (defface 'font-lock-comment-delimiter-face
          '((default :inherit font-lock-comment-face))
          "Font Lock mode face used to highlight comment delimiters.")

    (defface 'font-lock-string-face
          '((((class grayscale) (background light)) :foreground "DimGray" :slant italic)
            (((class grayscale) (background dark))  :foreground "LightGray" :slant italic)
            (((class color) (min-colors 88) (background light)) :foreground "VioletRed4")
            (((class color) (min-colors 88) (background dark))  :foreground "LightSalmon")
            (((class color) (min-colors 16) (background light)) :foreground "RosyBrown")
            (((class color) (min-colors 16) (background dark))  :foreground "LightSalmon")
            (((class color) (min-colors 8)) :foreground "green")
            (#t :slant italic))
          "Font Lock mode face used to highlight strings.")

    (defface 'font-lock-doc-face
          '((#t :inherit font-lock-string-face))
          "Font Lock mode face used to highlight documentation embedded in program code.")

    (defface 'font-lock-doc-markup-face
          '((#t :inherit font-lock-constant-face))
          "Font Lock mode face used to highlight embedded documentation mark-up.")

    (defface 'font-lock-keyword-face
          '((((class grayscale) (background light)) :foreground "LightGray" :weight bold)
            (((class grayscale) (background dark))  :foreground "DimGray" :weight bold)
            (((class color) (min-colors 88) (background light)) :foreground "Purple")
            (((class color) (min-colors 88) (background dark))  :foreground "Cyan1")
            (((class color) (min-colors 16) (background light)) :foreground "Purple")
            (((class color) (min-colors 16) (background dark))  :foreground "Cyan")
            (((class color) (min-colors 8)) :foreground "cyan" :weight bold)
            (#t :weight bold))
          "Font Lock mode face used to highlight keywords.")

    (defface 'font-lock-builtin-face
          '((((class grayscale) (background light)) :foreground "LightGray" :weight bold)
            (((class grayscale) (background dark))  :foreground "DimGray" :weight bold)
            (((class color) (min-colors 88) (background light)) :foreground "dark slate blue")
            (((class color) (min-colors 88) (background dark))  :foreground "LightSteelBlue")
            (((class color) (min-colors 16) (background light)) :foreground "Orchid")
            (((class color) (min-colors 16) (background dark))  :foreground "LightSteelBlue")
            (((class color) (min-colors 8)) :foreground "blue" :weight bold)
            (#t :weight bold))
          "Font Lock mode face used to highlight builtins.")

    (defface 'font-lock-function-name-face
          '((((class color) (min-colors 88) (background light)) :foreground "Blue1")
            (((class color) (min-colors 88) (background dark))  :foreground "LightSkyBlue")
            (((class color) (min-colors 16) (background light)) :foreground "Blue")
            (((class color) (min-colors 16) (background dark))  :foreground "LightSkyBlue")
            (((class color) (min-colors 8)) :foreground "blue" :weight bold)
            (#t :inverse-video #t :weight bold))
          "Font Lock mode face used to highlight function names.")

    (defface 'font-lock-function-call-face
          '((#t :inherit font-lock-function-name-face))
          "Font Lock mode face used to highlight function calls.")

    (defface 'font-lock-variable-name-face
          '((((class grayscale) (background light))
             :foreground "Gray90" :weight bold :slant italic)
            (((class grayscale) (background dark))
             :foreground "DimGray" :weight bold :slant italic)
            (((class color) (min-colors 88) (background light)) :foreground "sienna")
            (((class color) (min-colors 88) (background dark))  :foreground "LightGoldenrod")
            (((class color) (min-colors 16) (background light)) :foreground "DarkGoldenrod")
            (((class color) (min-colors 16) (background dark))  :foreground "LightGoldenrod")
            (((class color) (min-colors 8)) :foreground "yellow" :weight light)
            (#t :weight bold :slant italic))
          "Font Lock mode face used to highlight variable names.")

    (defface 'font-lock-variable-use-face
          '((#t :inherit font-lock-variable-name-face))
          "Font Lock mode face used to highlight variable references.")

    (defface 'font-lock-type-face
          '((((class grayscale) (background light)) :foreground "Gray90" :weight bold)
            (((class grayscale) (background dark))  :foreground "DimGray" :weight bold)
            (((class color) (min-colors 88) (background light)) :foreground "ForestGreen")
            (((class color) (min-colors 88) (background dark))  :foreground "PaleGreen")
            (((class color) (min-colors 16) (background light)) :foreground "ForestGreen")
            (((class color) (min-colors 16) (background dark))  :foreground "PaleGreen")
            (((class color) (min-colors 8)) :foreground "green")
            (#t :weight bold :underline #t))
          "Font Lock mode face used to highlight type and class names.")

    (defface 'font-lock-constant-face
          '((((class grayscale) (background light))
             :foreground "LightGray" :weight bold :underline #t)
            (((class grayscale) (background dark))
             :foreground "Gray50" :weight bold :underline #t)
            (((class color) (min-colors 88) (background light)) :foreground "dark cyan")
            (((class color) (min-colors 88) (background dark))  :foreground "Aquamarine")
            (((class color) (min-colors 16) (background light)) :foreground "CadetBlue")
            (((class color) (min-colors 16) (background dark))  :foreground "Aquamarine")
            (((class color) (min-colors 8)) :foreground "magenta")
            (#t :weight bold :underline #t))
          "Font Lock mode face used to highlight constants and labels.")

    (defface 'font-lock-warning-face
          '((#t :inherit error))
          "Font Lock mode face used to highlight warnings.")

    (defface 'font-lock-negation-char-face
          '((#t #f))
          "Font Lock mode face used to highlight easy to overlook negation.")

    (defface 'font-lock-preprocessor-face
          '((#t :inherit font-lock-builtin-face))
          "Font Lock mode face used to highlight preprocessor directives.")

    (defface 'font-lock-regexp-face
          '((#t :inherit font-lock-string-face))
          "Font Lock mode face used to highlight regexp literals.")

    (defface 'font-lock-regexp-grouping-backslash
          '((#t :inherit bold))
          "Font Lock mode face for backslashes in Lisp regexp grouping constructs.")

    (defface 'font-lock-regexp-grouping-construct
          '((#t :inherit bold))
          "Font Lock mode face used to highlight grouping constructs in Lisp regexps.")

    (defface 'font-lock-escape-face
          '((#t :inherit font-lock-regexp-grouping-backslash))
          "Font Lock mode face used to highlight escape sequences in strings.")

    (defface 'font-lock-number-face
          '((#t #f))
          "Font Lock mode face used to highlight numbers.")

    (defface 'font-lock-operator-face
          '((#t #f))
          "Font Lock mode face used to highlight operators.")

    (defface 'font-lock-property-name-face
          '((#t :inherit font-lock-variable-name-face))
          "Font Lock mode face used to highlight properties of an object.")

    (defface 'font-lock-property-use-face
          '((#t :inherit font-lock-property-name-face))
          "Font Lock mode face used to highlight property references.")

    (defface 'font-lock-punctuation-face
          '((#t #f))
          "Font Lock mode face used to highlight punctuation characters.")

    (defface 'font-lock-bracket-face
          '((#t :inherit font-lock-punctuation-face))
          "Font Lock mode face used to highlight brackets, braces, and parens.")

    (defface 'font-lock-delimiter-face
          '((#t :inherit font-lock-punctuation-face))
          "Font Lock mode face used to highlight delimiters.")

    (defface 'font-lock-misc-punctuation-face
          '((#t :inherit font-lock-punctuation-face))
          "Font Lock mode face used to highlight miscellaneous punctuation.")

    ;;----------------------------------------------------------------
    ;; The variables
    ;;
    ;; Emacs marks these `defvar-local': one value per buffer. A
    ;; buffer-local variable of this tree is read and written through the
    ;; buffer, the shape `(schemacs editor dired)' uses for
    ;; `dired-directory'.
    ;;------------------------------------------------------------------

    (define *font-lock-defaults* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-defaults': the major mode's own
    ;; specification of what to fontify - "Its value should be of the
    ;; form (KEYWORDS [KEYWORDS-ONLY [CASE-FOLD [SYNTAX-ALIST
    ;; [SYNTAX-TABLE [LOCAL [JIT-LOCK [OTHER-VARS]]]]]]]])". Only the
    ;; first and third elements are read here; see the library comment.

    (define *font-lock-keywords* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-keywords'. Its value is a user-level
    ;; keyword list, or the compiled `(t KEYWORDS COMPILED ...)' form
    ;; after `font-lock-compile-keywords' has run over it.

    (define *font-lock-keywords-case-fold-search* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-keywords-case-fold-search': "Non-nil
    ;; means the `font-lock-keywords' are case-insensitive."

    (define *font-lock-set-defaults* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-set-defaults', a `defvar-local' as well:
    ;; "Whether we have set up defaults." Read through
    ;; `font-lock-set-defaults-done?'.

    (define *font-lock-fontified* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-fontified', which is a `defvar-local' -
    ;; "Whether we have fontified the buffer" - and read through
    ;; `font-lock-fontified' below. General rather than buffer-local, a
    ;; *second* turn-on of the mode in another buffer skipped its first
    ;; fontification, since the flag was still set from the first.

    (define *font-lock-mode* (make-parameter #f))
    ;; ^ The mode's own switch. GNU Emacs's `font-lock-mode' is a
    ;; `define-minor-mode', and its variable is buffer-local; this tree
    ;; has not got `define-minor-mode' yet, so the mode is a command that
    ;; toggles a variable as `blink-cursor-mode' is - see the library
    ;; comment - and the variable is the one there is.

    (define *font-lock-multiline* (make-parameter 'undecided))
    ;; ^ GNU Emacs's `font-lock-multiline': "If nil, don't try to handle
    ;; multiline patterns. If t, always handle multiline patterns. If
    ;; `undecided', don't try to handle multiline patterns until you see
    ;; one."

    (define *font-lock-extra-managed-props* (make-parameter '()))
    ;; ^ GNU Emacs's `font-lock-extra-managed-props': "Additional text
    ;; properties managed by font-lock."

    (define *font-lock-maximum-decoration* (make-parameter #t))
    ;; ^ GNU Emacs's `font-lock-maximum-decoration', whose default is `t'
    ;; - "the maximum decoration" - read by
    ;; `font-lock-value-in-major-mode' and `font-lock-choose-keywords'.

    (define *font-lock-fontify-region-function* (make-parameter #f))
    (define *font-lock-unfontify-region-function* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-fontify-region-function' and
    ;; `font-lock-unfontify-region-function', whose values are those two
    ;; functions. They start false and `font-lock-set-defaults' fills
    ;; them, because the functions they name are defined below.

    (define *font-lock-support-mode* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-support-mode', whose default is
    ;; `jit-lock-mode'. jit-lock is not ported, so the default here is
    ;; false and `font-lock-after-change-function' fontifies the change
    ;; itself. This is the one place "no jit-lock" shows.

    (define *font-lock-beg* (make-parameter 0))
    (define *font-lock-end* (make-parameter 0))
    ;; ^ GNU Emacs's `(defvar font-lock-beg)' and `font-lock-end': "The
    ;; region to fontify, for `font-lock-extend-region-functions' to
    ;; move". Emacs binds them dynamically in
    ;; `font-lock-default-fontify-region' and the extend functions read
    ;; them - which is a `parameterize' here, and the reason these two are
    ;; parameters rather than plain variables.

    (define *font-lock-extend-region-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `font-lock-extend-region-functions', whose default
    ;; is `(font-lock-extend-region-wholelines
    ;; font-lock-extend-region-multiline)'. The wholelines half needs
    ;; `syntax-propertize-wholelines' and is not ported, so the default
    ;; here is the multiline half alone.

    (define (font-lock-buffer-local param)
      ;; a buffer-local variable, read the way dired.sld reads its own
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) param (param)))

    (define (set!font-lock-buffer-local! param value)
      (set-buffer-local-value! (current-buffer) param value))

    (define (font-lock-defaults)
      (font-lock-buffer-local *font-lock-defaults*))
    (define (set!font-lock-defaults! value)
      (set!font-lock-buffer-local! *font-lock-defaults* value))
    ;; ^ GNU Emacs's `font-lock-defaults' is a `defvar-local' too: a major
    ;; mode sets it for its own buffers, which is exactly what
    ;; `dired-mode' does.

    (define (font-lock-keywords) (font-lock-buffer-local *font-lock-keywords*))
    (define (set!font-lock-keywords! value)
      (set!font-lock-buffer-local! *font-lock-keywords* value))

    (define (font-lock-mode-on?) (font-lock-buffer-local *font-lock-mode*))
    (define (set!font-lock-mode! value)
      (set!font-lock-buffer-local! *font-lock-mode* value))
    ;; ^ GNU Emacs's `font-lock-mode' variable, which `define-minor-mode'
    ;; makes a `defvar-local' - one answer per buffer. It has to be, and
    ;; not for tidiness: `font-lock-mode-internal' puts the change hook on
    ;; `after-change-functions', and in Emacs it does so *buffer-locally*
    ;; ("(add-hook 'after-change-functions #'f t t)" - the last T is
    ;; LOCAL). This tree's hooks are one global list, so the hook runs in
    ;; every buffer; a general flag meant every other buffer's edits ran
    ;; the engine too, and a buffer with no defaults died on it. Per
    ;; buffer, the flag is the guard the hook needs.

    (define (font-lock-fontified)
      (font-lock-buffer-local *font-lock-fontified*))
    (define (set!font-lock-fontified! value)
      (set!font-lock-buffer-local! *font-lock-fontified* value))

    (define (font-lock-set-defaults-done?)
      (font-lock-buffer-local *font-lock-set-defaults*))
    (define (set!font-lock-set-defaults-done! value)
      (set!font-lock-buffer-local! *font-lock-set-defaults* value))

    ;;----------------------------------------------------------------
    ;; Adding to a property
    ;;
    ;; GNU Emacs's "Additional text property functions" (font-lock.el:
    ;; 1367), which the C has not got and which font-lock defines in Lisp
    ;; for want of them.
    ;;------------------------------------------------------------------

    (define (font-lock--add-text-property start end prop value object append?)
      ;; GNU Emacs's `font-lock--add-text-property': "Add an element to a
      ;; property of the text from START to END. ... The resulting
      ;; property values are always lists."
      ;;
      ;; The value is a *list* of faces when it is one already, and a
      ;; single face otherwise - which is why an anonymous face (a plist
      ;; beginning with a keyword) is wrapped rather than taken apart.
      ;;
      ;; The C's last argument is named APPEND, and so is the function it
      ;; calls; Elisp's separate namespaces let the two be spelled the
      ;; same, and Scheme's do not - a parameter named `append` *shadows*
      ;; `append`, so the call was to #f and the first prepend died with
      ;; "Wrong type to apply: #f". The question mark keeps the name and
      ;; loses the collision.
      ;;--------------------------------------------------------------
      ;; START and END arrive as one-based positions of the Emacs-named
      ;; layer, and the interval layer's are zero-based: they lose one
      ;; here, and the walk below runs in the interval layer's own
      ;; numbering. This is the seam dired.sld converts at too.
      (let ((val (if (and (pair? value) (not (keyword? (car value))))
                     value
                     (list value)))
            (start (- start 1))
            (end (- end 1)))
        (let loop ((start start))
          (when (< start end)
            (let* ((next (next-single-property-change start prop object end))
                   (prev (get-text-property start prop object))
                   ;; "Canonicalize old forms of face property": an
                   ;; anonymous face, or the old
                   ;; `foreground-color'/`background-color' spellings,
                   ;; is one face rather than a list of them.
                   (prev (if (and (memq prop '(face font-lock-face))
                                  (pair? prev)
                                  (or (keyword? (car prev))
                                      (memq (car prev)
                                            '(foreground-color
                                              background-color))))
                             (list prev)
                             prev))
                   ;; Elisp's `(listp prev)': nil counts as a list, and a
                   ;; single face does not - it is wrapped, which is what
                   ;; keeps the old face when the new one is prepended or
                   ;; appended. Reading `(pair? prev)' alone dropped it.
                   ;; `(not prev)' and not `(null? prev)': this tree's
                   ;; text-property functions answer `#f' for "no
                   ;; property", and `(null? #f)' is false - which is how
                   ;; an empty face became the one-element list `(#f)' and
                   ;; a prepending keyword drew nothing.
                   (list-prev (cond ((not prev) '())
                                    ((pair? prev) prev)
                                    (else (list prev))))
                   (new-value (if append?
                                  (append list-prev val)
                                  (append val list-prev))))
              (put-text-property start next prop new-value object)
              (loop next))))))

    (define (font-lock-prepend-text-property start end prop value . args)
      ;; GNU Emacs's `font-lock-prepend-text-property'.
      ;;--------------------------------------------------------------
      (font-lock--add-text-property start end prop value
                                    (if (pair? args) (car args) #f) #f))

    (define (font-lock-append-text-property start end prop value . args)
      ;; GNU Emacs's `font-lock-append-text-property'.
      ;;--------------------------------------------------------------
      (font-lock--add-text-property start end prop value
                                    (if (pair? args) (car args) #f) #t))

    (define (font-lock-fillin-text-property start end prop value . args)
      ;; GNU Emacs's `font-lock-fillin-text-property': "PROP and VALUE
      ;; specify the property and value to put where none are already in
      ;; place. Therefore existing property values are not overwritten."
      ;;--------------------------------------------------------------
      ;; the positions are the Emacs-named layer's; the interval layer's
      ;; are zero-based, so they lose one here and the walk stays in it
      (let ((object (if (pair? args) (car args) #f))
            (start (- start 1))
            (end (- end 1)))
        (let loop ((start (text-property-any start end prop #f object)))
          (when start
            (let ((next (next-single-property-change start prop object end)))
              (put-text-property start next prop value object)
              (loop (text-property-any next end prop #f object)))))))

    ;;----------------------------------------------------------------
    ;; Applying a highlight
    ;;------------------------------------------------------------------

    (define (font-lock-apply-highlight highlight)
      ;; GNU Emacs's `font-lock-apply-highlight' (font-lock.el:1631):
      ;; "Apply HIGHLIGHT following a match. HIGHLIGHT should be of the
      ;; form MATCH-HIGHLIGHT, see `font-lock-keywords'."
      ;;
      ;; MATCH-HIGHLIGHT is `(SUBEXP FACENAME [OVERRIDE [LAXMATCH]])',
      ;; and the arms below are the C's: no override means "do not touch
      ;; what is already there", `t' overwrites, `prepend' and `append'
      ;; merge into a list of faces, and `keep' fills in only what has
      ;; nothing.
      ;;
      ;; FACENAME is *evaluated* in Emacs; here it is the value the
      ;; keyword list holds, and a procedure is called - see the library
      ;; comment.
      ;;--------------------------------------------------------------
      (let* ((match (car highlight))
             ;; one-based, as every `match-beginning' of the Emacs-named
             ;; layer is; `beg' and `end' below are the interval layer's
             ;; zero-based pair for the same characters.
             (start (match-beginning match))
             (end (match-end match))
             (beg (if start (- start 1) #f))
             (end (if end (- end 1) #f))
             ;; Elisp's `(nth 2 highlight)' and `(nth 3 highlight)':
             ;; a highlight list is `(SUBEXP FACENAME [OVERRIDE
             ;; [LAXMATCH]])' and may stop short, where `cdddr' of a
             ;; two-element list is an error rather than nil.
             (override (list-ref-safe highlight 2))
             (laxmatch (list-ref-safe highlight 3)))
        (if (not start)
            ;; "No match but we might not signal an error."
            (or laxmatch
                (error "No match %s in highlight" match))
            (let* ((val (cadr highlight))
                   (val (if (procedure? val) (val) val))
                   ;; "Instead of a face, FACENAME can evaluate to a
                   ;; property list of the form (face FACE PROP1 VAL1
                   ;; ...) in which case all the listed text-properties
                   ;; will be set rather than just FACE."
                   (val (if (and (pair? val) (eq? (car val) 'face))
                            (begin (add-text-properties beg end (cddr val)
                                                        (current-buffer))
                                   (cadr val))
                            val)))
              (cond
               ((not (or val (eq? override #t)))
                ;; "If `val' is nil, don't do anything" - adding nil
                ;; would turn a face into a one-element list of nil.
                #f)
               ((not override)
                (or (text-property-not-all beg end 'face #f (current-buffer))
                    (put-text-property beg end 'face val (current-buffer))))
               ((eq? override #t)
                (put-text-property beg end 'face val (current-buffer)))
               ((eq? override 'prepend)
                (font-lock-prepend-text-property start end 'face val
                                                 (current-buffer)))
               ((eq? override 'append)
                (font-lock-append-text-property start end 'face val
                                                (current-buffer)))
               ((eq? override 'keep)
                (font-lock-fillin-text-property start end 'face val
                                                (current-buffer)))
               (else #f))))))

    (define (font-lock-fontify-anchored-keywords keywords limit)
      ;; GNU Emacs's `font-lock-fontify-anchored-keywords'
      ;; (font-lock.el:1669): "Fontify according to KEYWORDS until LIMIT.
      ;; KEYWORDS should be of the form MATCH-ANCHORED."
      ;;
      ;; MATCH-ANCHORED is `(MATCHER PRE-MATCH-FORM POST-MATCH-FORM
      ;; MATCH-HIGHLIGHT ...)'. The pre-match form is evaluated and its
      ;; *value*, when it is a position past point, becomes the limit -
      ;; which is what makes Dired's
      ;;
      ;;   '(".+" (dired-move-to-filename) nil (0 dired-marked-face))
      ;;
      ;; fontify the file *name*: `(dired-move-to-filename)' moves point
      ;; to the name and answers where it landed, and the `.+`' then
      ;; matches from there. Otherwise the limit is the end of the line.
      ;;--------------------------------------------------------------
      (let* ((matcher (car keywords))
             ;; `(nthcdr 3 keywords)': the highlights after
             ;; MATCHER/PRE-MATCH-FORM/POST-MATCH-FORM
             (lowdarks (let loop ((rest keywords) (n 3))
                         (if (or (= n 0) (not (pair? rest)))
                             rest
                             (loop (cdr rest) (- n 1)))))
             (lead-start (match-beginning 0))
             (pre-match-value
              (let ((form (list-ref-safe keywords 1)))
                (if (procedure? form) (form) form)))
             (limit (if (and (number? pre-match-value)
                             (> pre-match-value (point)))
                        pre-match-value
                        (line-end-position))))
        (save-match-data
          (let loop ()
            (when (and (< (point) limit)
                       (if (string? matcher)
                           (re-search-forward matcher limit #t)
                           (matcher limit)))
              (for-each font-lock-apply-highlight lowdarks)
              (loop))))
        ;; "Evaluate POST-MATCH-FORM."
        (let ((form (list-ref-safe keywords 2)))
          (when (procedure? form) (form)))
        (when (and *font-lock-multiline*
                   (>= limit (line-beginning-position 2)))
          ;; "this is a multiline anchored match"
          ;; `limit', `lead-start' and `point' are the Emacs-named
          ;; layer's one-based positions; the property goes on the
          ;; interval layer's zero-based pair for the same text.
          (put-text-property (if (= limit (line-beginning-position 2))
                                 (- limit 1)
                                 (- (min lead-start (point)) 1))
                             (- limit 1)
                             'font-lock-multiline #t
                             (current-buffer)))
        #f))

    (define (font-lock-fontify-keywords-region start end . args)
      ;; GNU Emacs's `font-lock-fontify-keywords-region' (font-lock.el:
      ;; 1703): "Fontify according to `font-lock-keywords' between START
      ;; and END. START should be at the beginning of a line."
      ;;
      ;; Per keyword: find an occurrence of the matcher from START to
      ;; END, then apply each of its highlights - a plain MATCH-HIGHLIGHT,
      ;; or a MATCH-ANCHORED list, told apart by its first element not
      ;; being a number, exactly as the C tells them apart.
      ;;
      ;; LOUDLY, the C's optional third argument, would print
      ;; "Fontifying %s... (regexps..%s)" between keywords; nothing here
      ;; passes it, and `*font-lock-verbose*' is the variable waiting.
      ;;--------------------------------------------------------------
      (let* ((current (font-lock-keywords))
             (keywords (if (eq? (car-safe current) #t)
                           current
                           (font-lock-compile-keywords current))))
        ;; "Ensure forward progress. `pos' is a marker because anchored
        ;; keyword may add/delete text (this happens e.g. in grep.el)." A
        ;; plain position is not enough and this port used one.
        (let ((pos (point-marker)))
          (set-marker! pos #f)          ; `(make-marker)': nowhere yet
          (for-each
         (lambda (keyword)
           (let ((matcher (car keyword)))
             (goto-char start)
             ;; `case-fold-search' is bound by the C from
             ;; `font-lock-keywords-case-fold-search'; the regexp engine
             ;; here takes its folding from `*case-fold-search*', so that
             ;; variable would have to be the one bound - and no mode
             ;; here sets it yet. Named.
             (let loop ()
               (when (and (< (point) end)
                          (if (string? matcher)
                              (re-search-forward matcher end #t)
                              (matcher end))
                          ;; "Beware empty string matches since they will
                          ;; loop indefinitely."
                          (or (> (point) (match-beginning 0))
                              (begin (goto-char (min (point-max) (+ (point) 1)))
                                     #t)))
                 ;; The C's multiline block, which this port did not have
                 ;; at all - and which is the only place *this* function
                 ;; calls `save-excursion'. Both calls are the same
                 ;; computation: the position of the start of the line
                 ;; *after* the match's line, worked out without leaving
                 ;; point where the search left it, since the `while'
                 ;; carries on from point.
                 (when (and *font-lock-multiline*
                            (>= (point)
                                (save-excursion (goto-char (match-beginning 0))
                                                (forward-line 1)
                                                (point))))
                   ;; "this is a multiline regexp match"
                   ;;
                   ;; A match that *ends* flush with the next line's start
                   ;; means the regexp consumed the newline itself, so the
                   ;; property starts at the last character of the match;
                   ;; otherwise it starts at the match's beginning.
                   (let ((next-line-start
                          (save-excursion (goto-char (match-beginning 0))
                                          (forward-line 1)
                                          (point))))
                     (put-text-property
                      (if (= (point) next-line-start)
                          (- (point) 1)
                          (- (match-beginning 0) 1))
                      (- (point) 1)
                      'font-lock-multiline #t
                      (current-buffer))))
                 (for-each
                  (lambda (highlight)
                    (if (number? (car highlight))
                        (font-lock-apply-highlight highlight)
                        (begin
                          (set-marker! pos (point) (current-buffer))
                          (font-lock-fontify-anchored-keywords highlight end)
                          (when (< (point) (marker-position pos))
                            (goto-char (marker-position pos))))))
                  (if (pair? (cdr keyword)) (cdr keyword) '()))
                 (loop)))))
         (if (pair? (cddr keywords)) (cddr keywords) '()))
          ;; `(set-marker pos nil)'
          (set-marker! pos #f)
          #f)))

    (define (car-safe x) (if (pair? x) (car x) #f))
    (define (cdr-safe x) (if (pair? x) (cdr x) '()))
    ;; ^ Elisp's `car-safe' and `cdr-safe', which the keyword model reads
    ;; the compiled marker and the highlight list with. They are
    ;; `subr.el''s and are one line each; they come here with the first
    ;; caller.

    (define (font-lock-compile-keyword keyword)
      ;; GNU Emacs's `font-lock-compile-keyword' (font-lock.el:1803):
      ;; the forms of a user-level keyword element (see
      ;; `font-lock-keywords') turned into the one form
      ;; `(MATCHER HIGHLIGHT ...)'.
      ;;
      ;; The `(eval . FORM)' and `(MATCHER . 'FORM)' arms are Emacs's two
      ;; doors to evaluating a FACENAME; a FORM that is a procedure is
      ;; called here, and a quoted face name is taken as the name, since
      ;; a Scheme keyword list holds values rather than forms.
      ;;--------------------------------------------------------------
      (cond ((or (procedure? keyword) (not (pair? keyword)))  ; MATCHER
             (list keyword (list 0 'font-lock-keyword-face)))
            ((eq? (car keyword) 'eval)                        ; (eval . FORM)
             (font-lock-compile-keyword (cdr keyword)))
            ((and (pair? (cdr keyword))                       ; (MATCHER . 'FORM)
                  (pair? (cdr (cdr keyword)))
                  (eq? (car (cdr keyword)) 'quote))
             (list (car keyword) (list 0 (cadr (cdr keyword)))))
            ((number? (cdr keyword))                          ; (MATCHER . SUBEXP)
             (list (car keyword)
                   (list (cdr keyword) 'font-lock-keyword-face)))
            ((symbol? (cdr keyword))                          ; (MATCHER . FACENAME)
             (list (car keyword) (list 0 (cdr keyword))))
            ((not (pair? (cadr keyword)))                     ; (MATCHER . HIGHLIGHT)
             (list (car keyword) (cdr keyword)))
            (else                                             ; (MATCHER HIGHLIGHT ...)
             keyword)))

    (define (font-lock-compile-keywords keywords . args)
      ;; GNU Emacs's `font-lock-compile-keywords' (font-lock.el:1765):
      ;; "Compile KEYWORDS into the form (t KEYWORDS COMPILED...)".
      ;;
      ;; The C's tail - the `font-lock-syntax-paren-check' regexp it may
      ;; tack on for modes whose defun motion could confuse the syntactic
      ;; pass - is not here: it exists to keep a string or comment from
      ;; being taken for a defun, and there is no syntactic pass yet.
      ;; `font-lock--filter-keywords' (the `font-lock-ignore' rule
      ;; language, off by default) is named in the library comment rather
      ;; than written.
      ;;--------------------------------------------------------------
      (if (eq? (car-safe keywords) #t)
          keywords
          (cons #t (cons keywords (%compile-each keywords)))))

    (define (%compile-each keywords)
      ;; the `mapcar' the C compiles the user-level list with, kept apart
      ;; only so that `font-lock-compile-keywords' reads as the C does
      ;;--------------------------------------------------------------
      (map font-lock-compile-keyword keywords))

    ;;----------------------------------------------------------------
    ;; Fontifying a region
    ;;------------------------------------------------------------------

    (define (font-lock-default-unfontify-region beg end)
      ;; GNU Emacs's `font-lock-default-unfontify-region'
      ;; (font-lock.el:1242): "Unfontify the text between BEG and END."
      ;;
      ;; The C's `(if font-lock-syntactic-keywords '(syntax-table face
      ;; font-lock-multiline) '(face font-lock-multiline))' drops its
      ;; first element here for the reason the syntactic half is not
      ;; ported.
      ;;--------------------------------------------------------------
      (remove-list-of-text-properties
       (- beg 1) (- end 1)
       (append (*font-lock-extra-managed-props*) (list 'face 'font-lock-multiline))
       (current-buffer)))

    (define (font-lock-unfontify-region beg end)
      ;; GNU Emacs's `font-lock-unfontify-region' (font-lock.el:1041).
      ;;--------------------------------------------------------------
      ((*font-lock-unfontify-region-function*) beg end))

    (define (font-lock-extend-region-multiline)
      ;; GNU Emacs's `font-lock-extend-region-multiline'
      ;; (font-lock.el:1160): "Move fontification boundaries away from any
      ;; `font-lock-multiline' property."
      ;;
      ;; It reads and writes `font-lock-beg'/`font-lock-end', which
      ;; `font-lock-default-fontify-region' has bound: that is a
      ;; `parameterize' here, which is why these are parameters.
      ;;--------------------------------------------------------------
      (let ((changed #f))
        (when (and (> (*font-lock-beg*) (point-min))
                   (get-text-property (- (*font-lock-beg*) 1)
                                      'font-lock-multiline (current-buffer)))
          (set! changed #t)
          ;; the property walk answers the interval layer's zero-based
          ;; index; `font-lock-beg' is one-based
          (*font-lock-beg*
           (let ((found (previous-single-property-change
                         (- (*font-lock-beg*) 1) 'font-lock-multiline
                         (current-buffer))))
             (if found (+ found 1) (point-min)))))
        ;; "If `font-lock-multiline' starts at `font-lock-end', do not
        ;; extend the region."
        ;; The C's `(setq new-end ...)' inside a `when': the answer has to
        ;; be #f and not "whatever `when' produced", because a Scheme
        ;; `when' whose test fails answers an *unspecified* value, and an
        ;; unspecified value is true - so `(and new-end ...)' below would
        ;; run and `=' would be handed one.
        (let* ((before-end (max (point-min) (- (*font-lock-end*) 1)))
               (new-end (if (get-text-property (- before-end 1)
                                               'font-lock-multiline
                                               (current-buffer))
                            (or (let ((found (text-property-any
                                              (- before-end 1) (- (point-max) 1)
                                              'font-lock-multiline #f
                                              (current-buffer))))
                                  (if found (+ found 1) #f))
                                (point-max))
                            #f)))
          (when (and new-end (not (= new-end (*font-lock-end*))))
            (set! changed #t)
            (*font-lock-end* new-end)))
        changed))

    (define (font-lock-default-fontify-region beg end . args)
      ;; GNU Emacs's `font-lock-default-fontify-region'
      ;; (font-lock.el:1190): "Fontify the text between BEG and END. ...
      ;; This function is the default `font-lock-fontify-region-function'."
      ;;
      ;; The `with-syntax-table' the C wraps everything in is not here -
      ;; there is no syntax table - and the syntactic pass with it; what
      ;; is left is the extend-region walk and the keyword pass.
      ;;
      ;; The C's answer is `(jit-lock-bounds BEG . END)', which is
      ;; jit-lock's bookkeeping and belongs with jit-lock.
      ;;--------------------------------------------------------------
      (let ((end (if (> end (point-max)) (point-max) end)))
        (parameterize ((*font-lock-beg* beg)
                       (*font-lock-end* end))
          ;; "If there's been a change, we should go through the list
          ;; again since this new position may warrant a different answer
          ;; from one of the fun we've already seen."
          (let loop ((funs (*font-lock-extend-region-functions*)))
            (when (pair? funs)
              (if ((car funs))
                  (loop (*font-lock-extend-region-functions*))
                  (loop (cdr funs)))))
          (let ((beg (*font-lock-beg*))
                (end (*font-lock-end*)))
            (font-lock-unfontify-region beg end)
            (font-lock-fontify-keywords-region beg end)))
        #f))

    (define (font-lock-fontify-region beg end . args)
      ;; GNU Emacs's `font-lock-fontify-region' (font-lock.el:1032):
      ;; "Fontify the text between BEG and END."
      ;;--------------------------------------------------------------
      ((*font-lock-fontify-region-function*) beg end
                                             (if (pair? args) (car args) #f)))

    (define (font-lock-default-unfontify-buffer)
      ;; GNU Emacs's `font-lock-default-unfontify-buffer'
      ;; (font-lock.el:1122).
      ;;--------------------------------------------------------------
      (font-lock-default-unfontify-region (point-min) (point-max)))

    (define (font-lock-unfontify-buffer)
      ;; GNU Emacs's `font-lock-unfontify-buffer' (font-lock.el:1029).
      ;;--------------------------------------------------------------
      ((*font-lock-unfontify-region-function*) (point-min) (point-max))
      (set!font-lock-fontified! #f))

    (define (font-lock-default-fontify-buffer)
      ;; GNU Emacs's `font-lock-default-fontify-buffer'
      ;; (font-lock.el:1103).
      ;;--------------------------------------------------------------
      (font-lock-default-fontify-region (point-min) (point-max)))

    (define (font-lock-fontify-buffer . args)
      ;; GNU Emacs's `font-lock-fontify-buffer' (font-lock.el:1010):
      ;; "Fontify the whole buffer."
      ;;--------------------------------------------------------------
      (font-lock-fontify-region (point-min) (point-max))
      (set!font-lock-fontified! #t))

    (define (font-lock-ensure . args)
      ;; GNU Emacs's `font-lock-ensure' (font-lock.el:1082): "Make sure
      ;; the region is fontified."
      ;;--------------------------------------------------------------
      (font-lock-fontify-region (if (pair? args) (car args) (point-min))
                                (if (and (pair? args) (pair? (cdr args)))
                                    (cadr args)
                                    (point-max))))

    (define (font-lock-flush . args)
      ;; GNU Emacs's `font-lock-flush' (font-lock.el:1051): "Declare the
      ;; region between BEG and END as not being fontified. ... This
      ;; causes the region to be fontified next time it is displayed."
      ;;
      ;; There is no deferred fontification here (jit-lock is not
      ;; ported), so the region is unfontified now and fontified again at
      ;; the next `font-lock-ensure' - which is what "declare" comes to in
      ;; an editor with no idle pass.
      ;;--------------------------------------------------------------
      (font-lock-unfontify-region (if (pair? args) (car args) (point-min))
                                  (if (and (pair? args) (pair? (cdr args)))
                                      (cadr args)
                                      (point-max))))

    ;;----------------------------------------------------------------
    ;; The change hook
    ;;------------------------------------------------------------------

    (define (font-lock-after-change-function beg end . args)
      ;; GNU Emacs's `font-lock-after-change-function' (font-lock.el:
      ;; 1253): "Called when any modification is made to buffer text."
      ;;
      ;; The whole lines enclosing the change are fontified, and END is
      ;; pushed one past so that "the line right after `end'" is included
      ;; - "typical case: the first char of the line was deleted. Or a \n
      ;; was inserted in the middle of a line."
      ;;
      ;; The C's `font-lock-extend-after-change-region-function' is not
      ;; ported (nothing sets it), and neither is the jit-lock branch it
      ;; ends with: the region is fontified here and now.
      ;;--------------------------------------------------------------
      (when (font-lock-mode-on?)
        (save-excursion
          (let* ((beg (begin (goto-char beg) (line-beginning-position)))
                 (end (if (= end (point-max)) end (+ end 1))))
            (font-lock-fontify-region
             beg
             (begin (goto-char (min end (point-max))) (line-end-position)))))))

    ;;----------------------------------------------------------------
    ;; The keywords a mode adds
    ;;------------------------------------------------------------------

    (define (font-lock-add-keywords mode keywords . args)
      ;; GNU Emacs's `font-lock-add-keywords' (font-lock.el:715): "Add
      ;; highlighting KEYWORDS for MODE. ... If optional argument HOW is
      ;; `set', they are used to replace the current highlighting list.
      ;; If HOW is any other non-nil value, they are added at the end of
      ;; the current highlighting list."
      ;;
      ;; The C's MODE argument indexes `font-lock-keywords-alist', for
      ;; keywords that belong to a major mode rather than to one buffer;
      ;; that machinery is not here (nothing needs it yet), so MODE must
      ;; be false - which the C also allows, and calls "added for the
      ;; current buffer".
      ;;--------------------------------------------------------------
      (if mode
          (error "font-lock-add-keywords for a mode is not ported")
          (let* ((how (if (pair? args) (car args) #f))
                 (current (let ((c (font-lock-keywords)))
                            (if (eq? (car-safe c) #t) (cadr c) c)))
                 (new (cond ((eq? how 'set) keywords)
                            (how (append current keywords))
                            (else (append keywords current)))))
            (set!font-lock-keywords! (font-lock-compile-keywords new))
            (when (font-lock-mode-on?) (font-lock-fontify-buffer)))))

    (define (font-lock-remove-keywords mode keywords)
      ;; GNU Emacs's `font-lock-remove-keywords' (font-lock.el:841):
      ;; "Remove highlighting KEYWORDS from the current buffer."
      ;;--------------------------------------------------------------
      (if mode
          (error "font-lock-remove-keywords for a mode is not ported")
          (let* ((current (font-lock-keywords))
                 (user (if (eq? (car-safe current) #t) (cadr current) current))
                 (kept (let loop ((rest user) (acc '()))
                         (cond ((null? rest) (reverse acc))
                               ((member (car rest) keywords) (loop (cdr rest) acc))
                               (else (loop (cdr rest)
                                           (cons (car rest) acc)))))))
            (set!font-lock-keywords! (font-lock-compile-keywords kept)))))

    ;;----------------------------------------------------------------
    ;; Setting up from the mode's defaults
    ;;------------------------------------------------------------------

    (define (font-lock-eval-keywords keywords)
      ;; GNU Emacs's `font-lock-eval-keywords' (font-lock.el:1822):
      ;; "Evaluate KEYWORDS if a function (funcall) or variable (eval)
      ;; name." A procedure is called and its answer looked at again,
      ;; which is the C's recursion.
      ;;--------------------------------------------------------------
      (if (procedure? keywords)
          (font-lock-eval-keywords (keywords))
          keywords))

    (define (font-lock-value-in-major-mode values)
      ;; GNU Emacs's `font-lock-value-in-major-mode' (font-lock.el:1830):
      ;; "If VALUES is a list, use `major-mode' as a key and return the
      ;; `assq' value. ... If VALUES isn't a list, return VALUES."
      ;;--------------------------------------------------------------
      (if (pair? values)
          (let ((entry (assq (major-mode) values))
                (any (assq #t values)))
            (cond (entry (cdr entry))
                  (any (cdr any))
                  (else #f)))
          values))

    (define (font-lock-choose-keywords keywords level)
      ;; GNU Emacs's `font-lock-choose-keywords' (font-lock.el:1839):
      ;; "Return LEVELth element of KEYWORDS. A LEVEL of nil is equal to a
      ;; LEVEL of 0, a LEVEL of t is equal to (1- (length KEYWORDS))."
      ;;--------------------------------------------------------------
      (cond ((not (and (pair? keywords) (symbol? (car keywords)))) keywords)
            ((integer? level) (or (list-ref-safe keywords level) (last keywords)))
            ((eq? level #t) (last keywords))
            (else (car keywords))))

    (define (list-ref-safe list n)
      ;; Elisp's `(nth N LIST)', which answers nil past the end where
      ;; Scheme's `list-ref' is an error
      ;;--------------------------------------------------------------
      (cond ((or (< n 0) (not (pair? list))) #f)
            ((= n 0) (car list))
            (else (list-ref-safe (cdr list) (- n 1)))))

    (define (font-lock-set-defaults)
      ;; GNU Emacs's `font-lock-set-defaults' (font-lock.el:1914): "Set
      ;; fontification variables from `font-lock-defaults'."
      ;;
      ;; `font-lock-defaults' is `(KEYWORDS [KEYWORDS-ONLY [CASE-FOLD
      ;; [SYNTAX-ALIST ...]]])'; the first and the third are read here,
      ;; and the second is the syntactic half, which is not ported.
      ;;
      ;; What the C does that is *not* here is named in the library
      ;; comment; the largest piece is the
      ;; `font-lock-keywords-alist'/`-removed-keywords-alist' walk, which
      ;; needs `font-lock-add-keywords' with a MODE to have anything to
      ;; walk.
      ;;--------------------------------------------------------------
      (let* ((defaults (font-lock-defaults))
             (keywords (if (pair? defaults) (car defaults) #f))
             (case-fold (if (and (pair? defaults)
                                 (pair? (cdr defaults))
                                 (pair? (cddr defaults)))
                            (car (cddr defaults))
                            #f)))
        (when keywords
          (set!font-lock-keywords!
           (font-lock-compile-keywords
            (font-lock-choose-keywords
             (font-lock-eval-keywords keywords)
             (font-lock-value-in-major-mode (*font-lock-maximum-decoration*)))))
          (*font-lock-keywords-case-fold-search* case-fold)
          (*font-lock-fontify-region-function* font-lock-default-fontify-region)
          (*font-lock-unfontify-region-function* font-lock-default-unfontify-region)
          (*font-lock-extend-region-functions*
           (list font-lock-extend-region-multiline))
          (set!font-lock-set-defaults-done! #t)
          #t)))

    ;;----------------------------------------------------------------
    ;; The mode
    ;;------------------------------------------------------------------

    (define (font-lock-mode-internal arg)
      ;; GNU Emacs's `font-lock-mode-internal' (font-lock.el:703): what
      ;; turning the mode on and off consists of.
      ;;
      ;; The C's `(add-hook 'after-change-functions #'f t t)' and its
      ;; removal are here a `cons' and a filter over the engine's hook
      ;; list, which this tree keeps as a list of procedures in a
      ;; parameter - the shape isearch.sld uses for the same hook.
      ;;--------------------------------------------------------------
      (if arg
          (begin
            (*after-change-functions*
             (cons font-lock-after-change-function
                   (delq font-lock-after-change-function
                         (*after-change-functions*))))
            (font-lock-set-defaults))
          (begin
            (*after-change-functions*
             (delq font-lock-after-change-function (*after-change-functions*)))
            (font-lock-unfontify-buffer))))

    (define (font-lock-initial-fontify)
      ;; GNU Emacs's `font-lock-initial-fontify' (font-lock.el:695): "The
      ;; first fontification after turning the mode on. This must only be
      ;; called after the mode hooks have been run."
      ;;--------------------------------------------------------------
      (when (and (font-lock-mode-on?)
                 (font-lock-specified-p #t)
                 (not (font-lock-fontified)))
        (font-lock-fontify-buffer)))

    (define (font-lock-specified-p mode)
      ;; GNU Emacs's `font-lock-specified-p' (font-lock.el:683): "Return
      ;; non-nil if the current buffer is ready for fontification."
      ;;--------------------------------------------------------------
      (or (font-lock-defaults)
          (and (font-lock-keywords) #t)
          (and mode (font-lock-set-defaults-done?) #t)))

    ))
