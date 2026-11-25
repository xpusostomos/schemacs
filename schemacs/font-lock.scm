(define-library (schemacs font-lock)
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
  ;; supplies. Both are here: the syntactic half stands on
  ;; `parse-partial-sexp` (syntax.c), which the syntax engine pass ported.
  ;; **The one piece not carried is the
  ;; `font-lock-keywords-alist'/`-removed-keywords-alist' walk** in
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
  ;; And `with-silent-modifications', which wraps Emacs's fontification,
  ;; **is needed after all, and is ported** - `font-lock.el:1044' and
  ;; `:1196', which are `font-lock-unfontify-region' and
  ;; `font-lock-default-fontify-region'. This header used to say it was
  ;; not needed, on the reasoning that "a text-property change in this
  ;; tree does neither" the undo list nor the modified flag. That stopped
  ;; being true on 2026-10-12, when `textprop.scm`'s
  ;; `modify_text_properties' was made faithful: a property write now runs
  ;; `prepare_to_modify_buffer_1', which means it consults the read-only
  ;; flag and it records undo and raises the counter. `inhibit-read-only'
  ;; is the binding that matters most - font-lock fontifies *read-only*
  ;; buffers, dired's among them - and Emacs has always bound it here.

  (import
 (only (schemacs insdel) *after-change-functions*)
    ;; the just-in-time fontification `font-lock-mode` uses by default -
    ;; `jit-lock.el`, which is below this library.
    (only (schemacs jit-lock)
          jit-lock-register jit-lock-unregister jit-lock-refontify
          jit-lock-fontify-now jit-lock-mode-on? *jit-lock-start* *jit-lock-end*
          *jit-lock-after-change-extend-region-functions*)
    (scheme base)
    (scheme char)
    ;; `cdddr' is `(scheme cxr)''s, not `(scheme base)''s - the
    ;; distinction that has bitten this tree before
    ;; `delq' is Guile's list `delete' - R7RS has no destructive one -
    ;; and `/=', which `(scheme base)' has not got. `last' is SRFI 1's,
    ;; which `font-lock-choose-keywords' takes the last element of a
    ;; keyword list with.
    (only (guile) delq)
    (only (srfi 1) last)
    ;; the `face' property, and the removals font-lock makes
    (only (schemacs textprop)
          get-text-property put-text-property add-text-properties keyword?
          next-single-property-change previous-single-property-change
          remove-list-of-text-properties text-property-any
          text-property-not-all)
    ;; the region: its ends, and the search that walks it
    (only (schemacs editfns)
          forward-line goto-char line-beginning-position
          line-end-position point point-marker point-max point-min bolp
          save-excursion)
    (only (schemacs search)
          match-beginning match-end re-search-forward save-match-data
          looking-at looking-back)
    ;; the comment delimiters the syntactic pass paints with
    ;; `font-lock-comment-delimiter-face' (`newcomment.el'''s)
    (only (schemacs newcomment) comment-start-skip comment-end-skip)
    ;; `font-lock-mode''s buffer, and the `defvar-local' variables it
    ;; keeps on it
    (only (schemacs buffer)
          *case-fold-search*
          buffer-local-value current-buffer
          major-mode set-buffer-local-value!)
    ;; `with-silent-modifications` is `subr.el`'s, and font-lock wraps its
    ;; two fontifying entry points in it as `font-lock.el` does - see the
    ;; note in this library's header for why it is not optional.
    (only (schemacs subr) with-silent-modifications)
    ;; the hook `font-lock-mode' hangs its incremental fontification on:
    ;; `after-change-functions' is `buffer.c''s, and the engine holds it
    
    ;; the markers, from marker.c's own library
    (only (schemacs marker) marker-position set-marker)
    ;; the syntactic half: `parse-partial-sexp' and `syntax-ppss' are
    ;; `syntax.c' and `syntax.el' and live in `(schemacs syntax)'
    (only (schemacs syntax)
          parse-partial-sexp syntax-ppss syntax-table syntax-propertize
          syntax-propertize-wholelines
          with-syntax-table copy-syntax-table modify-syntax-entry)
    ;; the faces above are `defface''d here, as font-lock.el deffaces them
    (only (schemacs faces) defface))

  (export
   *font-lock-defaults*
   *font-lock-extra-managed-props*
   *font-lock-fontify-region-function* font-lock-fontify-region-function
   *font-lock-extend-region-functions* *font-lock-support-mode*
   set!font-lock-fontify-region-function!
   *font-lock-fontified*
   *font-lock-keywords*
   *font-lock-keywords-only*
   *font-lock-keywords-case-fold-search*
   *font-lock-syntax-table*
   *font-lock-syntactic-face-function*
   *font-lock-fontify-syntactically-function*
   *font-lock-comment-start-skip*
   *font-lock-comment-end-skip*
   font-lock-comment-start-skip-value font-lock-comment-end-skip-value
   *font-lock-maximum-decoration*
   *font-lock-mode*
   *font-lock-multiline*
   *font-lock-set-defaults*
   *font-lock-major-mode*
   *font-lock-support-mode*
   *font-lock-unfontify-region-function* font-lock-unfontify-region-function
   set!font-lock-unfontify-region-function!
   font-lock-add-keywords
   font-lock-after-change-function
   font-lock-append-text-property
   font-lock-apply-highlight
   font-lock-choose-keywords
   font-lock-compile-keyword
   font-lock-compile-keywords
   font-lock-default-fontify-buffer
   font-lock-defaults
   font-lock-register-keyword-variable!
   *font-lock-keyword-variables*
   font-lock-default-fontify-region
   font-lock-default-unfontify-buffer
   font-lock-default-unfontify-region
   font-lock-ensure
   font-lock-eval-keywords
   font-lock-extend-region-multiline
   font-lock-fillin-text-property
   font-lock-turn-on-thing-lock
   font-lock-turn-off-thing-lock
   font-lock-extend-jit-lock-region-after-change
   font-lock-flush-function font-lock-ensure-function
   font-lock-fontify-buffer-function
   font-lock-extend-after-change-region-function
   font-lock-flush
   font-lock-fontify-anchored-keywords
   font-lock-fontify-buffer
   font-lock-fontify-keywords-region
   font-lock-fontify-syntactically-region
   font-lock-default-fontify-syntactically
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
   font-lock-extend-region-wholelines font-lock-extend-region-multiline
   font-lock-unfontify-buffer
   font-lock-unfontify-region
   font-lock-value-in-major-mode
   set!font-lock-defaults!
   set!font-lock-extend-after-change-region-function!
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
    ;; buffer, the shape `(schemacs dired)' uses for
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

    (define *font-lock-keywords-only* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-keywords-only', the second element of
    ;; `font-lock-defaults': "Non-nil means Font Lock should not fontify
    ;; comments or strings." Dired sets it, because its keywords do the
    ;; whole job and the syntactic pass would paint its listing.

    (define *font-lock-syntax-table* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-syntax-table', the fifth element of
    ;; `font-lock-defaults': "Non-nil means use this syntax table for
    ;; fontifying."  When false the buffer's own table is used.

    (define *font-lock-syntactic-face-function*
      (make-parameter (lambda (state)
                        (if (list-ref state 3)
                            'font-lock-string-face
                            'font-lock-comment-face))))
    ;; ^ GNU Emacs's `font-lock-syntactic-face-function': "Function to
    ;; determine which face to use when fontifying syntactically."

    (define *font-lock-fontify-syntactically-function* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-fontify-syntactically-function', filled
    ;; by `font-lock-set-defaults' with
    ;; `font-lock-default-fontify-syntactically'.

    (define *font-lock-comment-start-skip* (make-parameter #f))
    (define *font-lock-comment-end-skip* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-comment-start-skip' and `-end-skip'. The
    ;; delimiter-face branch of the syntactic pass reads them, with
    ;; `comment-start-skip'/`comment-end-skip' after them.
    ;;
    ;; **A language sets them through `c-lang-setvar', which here is a
    ;; buffer-local slot.** Emacs's variable would be buffer-local too
    ;; (`c-make-emacs-variables-local'), and its reader sees the
    ;; buffer-local value; a parameter alone cannot, so the readers below
    ;; take the parameter first - a `let' binding still wins, as in Emacs
    ;; - and the buffer's slot second.

    (define (font-lock-comment-start-skip-value)
      (or (*font-lock-comment-start-skip*)
          (buffer-local-value (current-buffer)
                              'font-lock-comment-start-skip #f)))

    (define (font-lock-comment-end-skip-value)
      (or (*font-lock-comment-end-skip*)
          (buffer-local-value (current-buffer)
                              'font-lock-comment-end-skip #f)))

    (define *font-lock-major-mode* (make-parameter #f))

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

    (define *font-lock-support-mode* (make-parameter 'jit-lock-mode))
    ;; ^ GNU Emacs's `font-lock-support-mode`, default `jit-lock-mode`.
    ;; `font-lock-turn-on-thing-lock` registers with jit-lock when this
    ;; says so - which is what makes a change *mark* text for
    ;; fontification instead of fontifying it in `after-change`.

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

    (define %font-lock-alist-variables
      ;; The `font-lock-defaults' alist names its variables as symbols;
      ;; the ones that also exist here as parameters are listed, so the
      ;; walk below can store where `font-lock-buffer-local' reads.
      (list (cons 'font-lock-keywords-only *font-lock-keywords-only*)
            (cons 'font-lock-keywords-case-fold-search
                  *font-lock-keywords-case-fold-search*)
            (cons 'font-lock-syntax-table *font-lock-syntax-table*)
            (cons 'font-lock-syntactic-face-function
                  *font-lock-syntactic-face-function*)
            (cons 'font-lock-multiline *font-lock-multiline*)
            (cons 'font-lock-comment-start-skip *font-lock-comment-start-skip*)
            (cons 'font-lock-comment-end-skip *font-lock-comment-end-skip*)))

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

    (define (font-lock-keywords-only)
      (font-lock-buffer-local *font-lock-keywords-only*))
    (define (font-lock-keywords-case-fold-search)
      (font-lock-buffer-local *font-lock-keywords-case-fold-search*))
    (define (font-lock-syntax-table)
      (font-lock-buffer-local *font-lock-syntax-table*))
    (define (font-lock-syntactic-face-function)
      (font-lock-buffer-local *font-lock-syntactic-face-function*))
    ;; ^ The four are `defvar-local' in Emacs (`font-lock-keywords-only',
    ;; `font-lock-keywords-case-fold-search', `font-lock-syntax-table' and
    ;; `font-lock-syntactic-face-function'): `font-lock-set-defaults' sets
    ;; them with `setq-local' for the mode it is setting up. Read through
    ;; the buffer, they follow the mode of the buffer being fontified;
    ;; read through the parameter, the last buffer's mode leaked into the
    ;; next one's fontification.

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

    ;; The four function variables of `font-lock.el:1033-1095` and
    ;; `:1000`. Each is a `defvar-local`, so each is a parameter whose
    ;; *buffer-local* entry wins (`font-lock-buffer-local`), as the four
    ;; above are.
    (define *font-lock-flush-function* (make-parameter #f))
    (define *font-lock-ensure-function* (make-parameter #f))
    (define *font-lock-fontify-buffer-function* (make-parameter #f))
    (define *font-lock-extend-after-change-region-function* (make-parameter #f))
    ;; `font-lock-fontify-region-function' and
    ;; `font-lock-unfontify-region-function' are `defvar's with the
    ;; default function as their value, and `font-lock-set-defaults' sets
    ;; them *buffer-locally* (`font-lock.el:958`, `:964`: "major modes can
    ;; modify the values of, e.g., font-lock-fontify-region-function").
    ;; The parameters are the global default and the slot wins - which is
    ;; what lets cc-mode's `c-font-lock-fontify-region` be one buffer's.
    (define (font-lock-fontify-region-function)
      (font-lock-buffer-local *font-lock-fontify-region-function*))
    (define (set!font-lock-fontify-region-function! value)
      (set!font-lock-buffer-local! *font-lock-fontify-region-function* value))
    (define (font-lock-unfontify-region-function)
      (font-lock-buffer-local *font-lock-unfontify-region-function*))
    (define (set!font-lock-unfontify-region-function! value)
      (set!font-lock-buffer-local! *font-lock-unfontify-region-function* value))

    (define (font-lock-flush-function)
      (font-lock-buffer-local *font-lock-flush-function*))
    (define (font-lock-ensure-function)
      (font-lock-buffer-local *font-lock-ensure-function*))
    (define (font-lock-fontify-buffer-function)
      (font-lock-buffer-local *font-lock-fontify-buffer-function*))
    (define (font-lock-extend-after-change-region-function)
      (font-lock-buffer-local *font-lock-extend-after-change-region-function*))
    (define (set!font-lock-extend-after-change-region-function! value)
      (set!font-lock-buffer-local!
       *font-lock-extend-after-change-region-function* value))

    (define (font-lock-major-mode)
      (font-lock-buffer-local *font-lock-major-mode*))
    (define (set!font-lock-major-mode! value)
      (set!font-lock-buffer-local! *font-lock-major-mode* value))
    ;; ^ GNU Emacs's `font-lock-major-mode' (`font-lock.el:1914'), a
    ;; `defvar-local': "Major mode for which the font-lock settings have
    ;; been setup."

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
      ;; START and END are the buffer's own positions, which is what the
      ;; interval layer speaks too - the C's `find_interval' subtracts
      ;; `BUF_BEG' and BEG is 1, the tree's origin here. There used to be
      ;; a `(- ... 1)' on each; it belonged to the tree's old zero-based
      ;; numbering and moved every property one character left.
      (let ((val (if (and (pair? value) (not (keyword? (car value))))
                     value
                     (list value))))
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
      (let ((object (if (pair? args) (car args) #f)))
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
             ;; `match-beginning'/`match-end' are the buffer's own
             ;; positions, which is what the property functions take.
             (start (match-beginning match))
             (end (match-end match))
             (beg start)
             (end end)
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
          ;; "this is a multiline anchored match" - the C's
          ;; `(put-text-property (if (= limit (line-beginning-position 2))
          ;; (1- limit) (min lead-start (point))) limit
          ;; 'font-lock-multiline t)'. The end is LIMIT, not one below
          ;; it: that extra `(- ... 1)' was the tree's old numbering.
          (put-text-property (if (= limit (line-beginning-position 2))
                                 (- limit 1)
                                 (min lead-start (point)))
                             limit
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
          (set-marker pos #f)          ; `(make-marker)': nowhere yet
          ;; "`case-fold-search' is bound by the C from
          ;; `font-lock-keywords-case-fold-search'"; the regexp engine
          ;; here takes its folding from `*case-fold-search*', so that is
          ;; the variable bound around the whole walk. Scheme's
          ;; `lisp-data-mode' asks for folding, `emacs-lisp-mode' does
          ;; not, and the two now differ.
          (parameterize ((*case-fold-search*
                          (font-lock-keywords-case-fold-search)))
          (for-each
         (lambda (keyword)
           (let ((matcher (car keyword)))
             (goto-char start)
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
                     ;; the C's `(if (= (point) next-line-start)
                     ;; (1- (point)) (match-beginning 0))' to `(point)'
                     (put-text-property
                      (if (= (point) next-line-start)
                          (- (point) 1)
                          (match-beginning 0))
                      (point)
                      'font-lock-multiline #t
                      (current-buffer))))
                 (for-each
                  (lambda (highlight)
                    (if (number? (car highlight))
                        (font-lock-apply-highlight highlight)
                        (begin
                          (set-marker pos (point) (current-buffer))
                          (font-lock-fontify-anchored-keywords highlight end)
                          (when (< (point) (marker-position pos))
                            (goto-char (marker-position pos))))))
                  (if (pair? (cdr keyword)) (cdr keyword) '()))
                 (loop)))))
         (if (pair? (cddr keywords)) (cddr keywords) '())))
          ;; `(set-marker pos nil)'
          (set-marker pos #f)
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
            ;; `list-ref-safe' is this library's `(nth N LIST)', and the
            ;; test is Emacs's `(nlistp (nth 1 keyword))' - true for a
            ;; one-element list too, the `((lambda (limit) ...))' form
            ;; the doc-comment keywords use, where Scheme's `cadr' of one
            ;; is an error.
            ((not (pair? (list-ref-safe keyword 1)))          ; (MATCHER . HIGHLIGHT)
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
      ;; only so that `font-lock-compile-keywords' reads as the C does.
      ;; "`mapcar' on nil is nil": the list may be the tree's `#f', which
      ;; is Elisp's nil (`(map ...)' is an error on it).
      ;;--------------------------------------------------------------
      (map font-lock-compile-keyword (if (pair? keywords) keywords '())))

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
       beg end
       (append (*font-lock-extra-managed-props*) (list 'face 'font-lock-multiline))
       (current-buffer)))

    (define (font-lock-unfontify-region beg end)
      ;; GNU Emacs's `font-lock-unfontify-region' (font-lock.el:1041),
      ;; which wraps its call in `with-silent-modifications' (`:1044') -
      ;; the unfontifying *is* a property change, and the buffer may be
      ;; read-only.
      ;;--------------------------------------------------------------
      (with-silent-modifications
       ((font-lock-unfontify-region-function) beg end)))

    (define (font-lock-extend-region-wholelines)
      ;; GNU Emacs's `font-lock-extend-region-wholelines'
      ;; (font-lock.el:1186): "Move fontification boundaries to beginning
      ;; of lines."
      ;;
      ;; The answer is `syntax-propertize-wholelines`' (syntax.el:152),
      ;; which this tree has had since the syntax engine pass; the note
      ;; that said it was missing was stale.
      ;;--------------------------------------------------------------
      (let ((new (syntax-propertize-wholelines (*font-lock-beg*) (*font-lock-end*))))
        (when new
          (*font-lock-beg* (car new))
          (*font-lock-end* (cdr new))
          #t)))

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
        ;; the C's `(get-text-property (1- font-lock-beg) ...)': the
        ;; `1-' is Emacs's own, not the tree's old numbering
        (when (and (> (*font-lock-beg*) (point-min))
                   (get-text-property (- (*font-lock-beg*) 1)
                                      'font-lock-multiline (current-buffer)))
          (set! changed #t)
          ;; the property walk answers buffer positions, as
          ;; `font-lock-beg' is
          (*font-lock-beg*
           (or (previous-single-property-change
                (*font-lock-beg*) 'font-lock-multiline
                (current-buffer))
               (point-min))))
        ;; "If `font-lock-multiline' starts at `font-lock-end', do not
        ;; extend the region."
        ;; The C's `(setq new-end ...)' inside a `when': the answer has to
        ;; be #f and not "whatever `when' produced", because a Scheme
        ;; `when' whose test fails answers an *unspecified* value, and an
        ;; unspecified value is true - so `(and new-end ...)' below would
        ;; run and `=' would be handed one.
        ;; the C's `(max (point-min) (1- font-lock-end))'
        (let* ((before-end (max (point-min) (- (*font-lock-end*) 1)))
               (new-end (if (get-text-property before-end
                                               'font-lock-multiline
                                               (current-buffer))
                            (or (text-property-any
                                 before-end (point-max)
                                 'font-lock-multiline #f
                                 (current-buffer))
                                (point-max))
                            #f)))
          (when (and new-end (not (= new-end (*font-lock-end*))))
            (set! changed #t)
            (*font-lock-end* new-end)))
        changed))

    ;;----------------------------------------------------------------
    ;; The syntactic pass - `font-lock.el:1577-1629'.  It is the half
    ;; that paints comments and strings, from the syntax table rather
    ;; than from the mode's regexps, and it is what makes the parser in
    ;; `(schemacs syntax)' a font-lock dependency.
    ;;------------------------------------------------------------------

    (define (font-lock-fontify-syntactically-region beg end . rest)
      ;; GNU Emacs's `font-lock-fontify-syntactically-region'
      ;; (font-lock.el:1577): "Syntactically fontify the text between BEG
      ;; and END. ... This works by calling
      ;; `font-lock-fontify-syntactically-function'."
      ;;--------------------------------------------------------------
      ((*font-lock-fontify-syntactically-function*) beg end
                                                    (if (pair? rest) (car rest) #f)))

    (define (font-lock-default-fontify-syntactically start end . rest)
      ;; GNU Emacs's `font-lock-default-fontify-syntactically'
      ;; (font-lock.el:1583): "Put proper face on each string and comment
      ;; between START and END. START should be at the beginning of a
      ;; line."
      ;;
      ;; The C's `(or syntax-ppss-table (syntax-table))' is
      ;; `font-lock-syntax-table' here: this tree has no
      ;; `syntax-ppss-table', and the table the pass *should* use is the
      ;; one the mode named for it.
      ;;
      ;; The delimiter-face branch reads `font-lock-comment-start-skip'
      ;; and `-end-skip' first and `comment-start-skip'/`comment-end-skip'
      ;; - newcomment.el's, which the indentation pass brought - after
      ;; them, exactly as the C does.
      ;;--------------------------------------------------------------
      (syntax-propertize end)
      (with-syntax-table (or (font-lock-syntax-table) (syntax-table))
        (lambda ()
          (let ((state (syntax-ppss start)))
            (let loop ((state state))
              (if (or (list-ref state 3) (list-ref state 4))
                  (let* ((face ((font-lock-syntactic-face-function) state))
                         (beg (max (list-ref state 8) start))
                         (state (parse-partial-sexp (point) end #f #f state
                                                    'syntax-table)))
                    (when face (put-text-property beg (point) 'face face))
                    ;; "Find the comment delimiters and use
                    ;; `font-lock-comment-delimiter-face' for them."
                    ;; Only a comment gets them, not a doc-string.
                    (when (and face (eq? face 'font-lock-comment-face)
                               (or (font-lock-comment-start-skip-value)
                                   (comment-start-skip)))
                      (save-excursion
                        (goto-char beg)
                        (if (looking-at (or (font-lock-comment-start-skip-value)
                                            (comment-start-skip)))
                            (put-text-property beg (match-end 0) 'face
                                               'font-lock-comment-delimiter-face)))
                      (if (looking-back (or (font-lock-comment-end-skip-value)
                                            (comment-end-skip))
                                        (line-beginning-position) #t)
                          (put-text-property (match-beginning 0) (point) 'face
                                             'font-lock-comment-delimiter-face)))
                    (if (< (point) end)
                        (loop (parse-partial-sexp (point) end #f #f state
                                                  'syntax-table))
                        state))
                  (if (< (point) end)
                      (loop (parse-partial-sexp (point) end #f #f state
                                                'syntax-table))
                      state)))))))

    (define (font-lock-default-fontify-region beg end . args)
      ;; GNU Emacs's `font-lock-default-fontify-region'
      ;; (font-lock.el:1190): "Fontify the text between BEG and END. ...
      ;; This function is the default `font-lock-fontify-region-function'."
      ;;
      ;; The `with-syntax-table' the C wraps everything in is not here -
      ;; there is no syntax table - and the syntactic pass with it; what
      ;; is left is the extend-region walk and the keyword pass. The
      ;; `with-silent-modifications' it wraps the same body in (`:1196')
      ;; *is* here, and has to be: fontification is a property write, and
      ;; font-lock fontifies read-only buffers.
      ;;
      ;; The C's answer is `(jit-lock-bounds BEG . END)', which is
      ;; jit-lock's bookkeeping and belongs with jit-lock.
      ;;--------------------------------------------------------------
      (let ((end (if (> end (point-max)) (point-max) end))
            (loudly (if (pair? args) (car args) #f)))
        (with-silent-modifications
         ;; "Use the fontification syntax table, if any." (`:1202')
         (with-syntax-table (or (font-lock-syntax-table) (syntax-table))
          (lambda ()
            (parameterize ((*font-lock-beg* beg)
                           (*font-lock-end* end))
              ;; "If there's been a change, we should go through the list
              ;; again since this new position may warrant a different
              ;; answer from one of the fun we've already seen."
              ;;
              ;; **The `(eq funs font-lock-extend-region-functions)'
              ;; guard is load-bearing**: `font-lock-extend-region-wholelines`
              ;; answers non-nil on every call (its
              ;; `syntax-propertize-wholelines` always conses), so without
              ;; the guard - which stops the restart when a function
              ;; returned true at the *start* of a pass - the loop never
              ;; ends. Measured: the dired suite hung on it.
              (let ((whole (*font-lock-extend-region-functions*)))
                (let loop ((funs whole))
                  (when (pair? funs)
                    (let ((next (if (or (not ((car funs)))
                                        (eq? funs whole))
                                    (cdr funs)
                                    whole)))
                      (loop next)))))
              (let ((beg (*font-lock-beg*))
                    (end (*font-lock-end*)))
                (font-lock-unfontify-region beg end)
                ;; "unless font-lock-keywords-only" (`:1228')
                (unless (font-lock-keywords-only)
                  (font-lock-fontify-syntactically-region beg end loudly))
                (font-lock-fontify-keywords-region beg end loudly))))))
        #f))

    ;; The global values the two `defvar`s have in Emacs
    ;; (`font-lock.el:649`): a buffer gets the buffer-local entry
    ;; `font-lock-set-defaults` sets, and a buffer that never ran it gets
    ;; these.
    (*font-lock-fontify-region-function* font-lock-default-fontify-region)
    (*font-lock-unfontify-region-function* font-lock-default-unfontify-region)

    (define (font-lock-fontify-region beg end . args)
      ;; GNU Emacs's `font-lock-fontify-region' (font-lock.el:1032):
      ;; "Fontify the text between BEG and END."
      ;;--------------------------------------------------------------
      ((font-lock-fontify-region-function) beg end
                                          (if (pair? args) (car args) #f)))

    (define (font-lock-default-unfontify-buffer)
      ;; GNU Emacs's `font-lock-default-unfontify-buffer'
      ;; (font-lock.el:1122).
      ;;--------------------------------------------------------------
      (font-lock-default-unfontify-region (point-min) (point-max)))

    (define (font-lock-unfontify-buffer)
      ;; GNU Emacs's `font-lock-unfontify-buffer' (font-lock.el:1029).
      ;;--------------------------------------------------------------
      ((font-lock-unfontify-region-function) (point-min) (point-max))
      (set!font-lock-fontified! #f))

    (define (font-lock-default-fontify-buffer)
      ;; GNU Emacs's `font-lock-default-fontify-buffer'
      ;; (font-lock.el:1103).
      ;;--------------------------------------------------------------
      (font-lock-default-fontify-region (point-min) (point-max)))

    (define (font-lock-fontify-buffer . args)
      ;; GNU Emacs's `font-lock-fontify-buffer' (font-lock.el:1010):
      ;; "Fontify the current buffer the way the function `font-lock-mode'
      ;; would" - through `font-lock-fontify-buffer-function', which is
      ;; `jit-lock-refontify` in a jit-locked buffer (`:930-934`).
      ;;--------------------------------------------------------------
      (font-lock-set-defaults)
      ((font-lock-fontify-buffer-function)))

    (define (font-lock-ensure . args)
      ;; GNU Emacs's `font-lock-ensure' (font-lock.el:1082): "Make sure
      ;; the region BEG...END has been fontified."
      ;;--------------------------------------------------------------
      (when (font-lock-specified-p #t)
        (font-lock-set-defaults)
        ((font-lock-ensure-function)
         (if (pair? args) (car args) (point-min))
         (if (and (pair? args) (pair? (cdr args))) (cadr args) (point-max)))))

    (define (font-lock-flush . args)
      ;; GNU Emacs's `font-lock-flush' (font-lock.el:1051): "Declare the
      ;; region BEG...END's fontification as out-of-date."
      ;;--------------------------------------------------------------
      (when (and (font-lock-mode-on?) (font-lock-fontified))
        ((font-lock-flush-function)
         (if (pair? args) (car args) (point-min))
         (if (and (pair? args) (pair? (cdr args))) (cadr args) (point-max)))))

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
      ;; **This is the eager path, and with the default
      ;; `*font-lock-support-mode*` it is not on any hook**: jit-lock's
      ;; `jit-lock-after-change` marks the change instead, and the
      ;; fontification happens at display time. This function is what
      ;; `font-lock-flush-function` defaults to, and what a support mode
      ;; of nil would use.
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

    (define (font-lock-add-keywords mode keywords . rest)
      ;; GNU Emacs's `font-lock-add-keywords' (font-lock.el:720): "Add
      ;; highlighting KEYWORDS for MODE. ... If optional argument HOW is
      ;; `set', they are used to replace the current highlighting list.
      ;; If HOW is any other non-nil value, they are added at the end of
      ;; the current highlighting list."
      ;;
      ;; **The C calls `font-lock-set-defaults' first**, and that is what
      ;; keeps a keyword list added before the mode comes on: the setup
      ;; is marked done, so turning the mode on does not derive the list
      ;; again and throw the addition away. This port used to skip that
      ;; step, and a keyword added before `font-lock-mode' was lost.
      ;;
      ;; MODE is not carried: it indexes `font-lock-keywords-alist', and
      ;; nothing here needs that yet, so it must be false - "added for
      ;; the current buffer", which the C also allows.
      ;;--------------------------------------------------------------
      (let ((how (if (pair? rest) (car rest) #f)))
        (if mode
            (error "font-lock-add-keywords for a mode is not ported")
            (begin
              ;; "(when (and font-lock-mode
              ;;            (not (or font-lock-keywords font-lock-defaults)))
              ;;    (font-lock-mode -1)
              ;;    (setq-local font-lock-defaults '(nil t))
              ;;    (font-lock-mode 1))"
              (when (and (font-lock-mode-on?)
                         (not (or (font-lock-keywords)
                                  (font-lock-defaults))))
                (set!font-lock-mode! #f)
                (font-lock-mode-internal #f)
                (set!font-lock-defaults! (list #f #t))
                (set!font-lock-mode! #t)
                (font-lock-mode-internal #t))
              (font-lock-set-defaults)
              (let ((was-compiled (eq? (car-safe (font-lock-keywords)) #t)))
                ;; "Bring back the user-level (uncompiled) keywords."
                (when was-compiled
                  (set!font-lock-keywords!
                   (cadr (font-lock-keywords))))
                (if (eq? how 'set)
                    (set!font-lock-keywords! keywords)
                    (begin
                      (font-lock-remove-keywords #f keywords)
                      (let ((old (if (eq? (car-safe (font-lock-keywords)) #t)
                                     (cdr (font-lock-keywords))
                                     (font-lock-keywords))))
                        (set!font-lock-keywords!
                         (if how
                             (append old keywords)
                             (append keywords old))))))
                (when was-compiled
                  (set!font-lock-keywords!
                   (font-lock-compile-keywords (font-lock-keywords))))
                #t)))))

    (define (font-lock-remove-keywords mode keywords)
      ;; GNU Emacs's `font-lock-remove-keywords' (font-lock.el:841):
      ;; "Remove highlighting KEYWORDS from the current buffer."
      ;;
      ;; Like `font-lock-add-keywords', it sets the defaults up first and
      ;; puts the list back in its uncompiled form before editing it.
      ;;--------------------------------------------------------------
      (if mode
          (error "font-lock-remove-keywords for a mode is not ported")
          (begin
            (font-lock-set-defaults)
            (let ((was-compiled (eq? (car-safe (font-lock-keywords)) #t)))
              (when was-compiled
                (set!font-lock-keywords! (cadr (font-lock-keywords))))
              (let ((kept (let loop ((rest (font-lock-keywords)) (acc '()))
                            (cond ((null? rest) (reverse acc))
                                  ((member (car rest) keywords)
                                   (loop (cdr rest) acc))
                                  (else (loop (cdr rest)
                                              (cons (car rest) acc)))))))
                (set!font-lock-keywords! kept)
                (when was-compiled
                  (set!font-lock-keywords!
                   (font-lock-compile-keywords kept))))
              #t))))

    ;;----------------------------------------------------------------
    ;; Setting up from the mode's defaults
    ;;------------------------------------------------------------------

    (define *font-lock-keyword-variables* (make-parameter '()))
    ;; ^ The keyword variables, by name, because **a symbol has no value
    ;; here**: Emacs's `font-lock-defaults' names its three levels with
    ;; symbols and `symbol-value' resolves them. This tree's names are
    ;; library bindings, and the library that defines a keyword variable
    ;; registers its value here with `font-lock-register-keyword-variable!'
    ;; - the same seam, one table.

    (define (font-lock-register-keyword-variable! name value)
      ;; Put NAME's VALUE in the table `font-lock-eval-keywords' reads.
      ;;--------------------------------------------------------------
      (*font-lock-keyword-variables*
       (cons (cons name value) (*font-lock-keyword-variables*))))

    (define (font-lock-eval-keywords keywords)
      ;; GNU Emacs's `font-lock-eval-keywords' (font-lock.el:1822):
      ;; "Evaluate KEYWORDS if a function (funcall) or variable (eval)
      ;; name." A symbol is looked up in the keyword-variable table, and
      ;; a procedure is called; the C's recursion is the walk here.
      ;;
      ;; The symbol branch *recurses*, because the C is a `while` loop:
      ;; `(setq keywords (if (fboundp keywords) (funcall keywords) (eval
      ;; keywords)))` and round again. A mode whose table entry is a
      ;; *procedure* - cc-mode's `c-font-lock-keywords`, which composes
      ;; the doc-comment keywords at setup - relies on the second turn;
      ;; answering the procedure itself handed `font-lock-compile-keywords`
      ;; a procedure where it wanted a list.
      ;;--------------------------------------------------------------
      (cond ((procedure? keywords)
             (font-lock-eval-keywords (keywords)))
            ((symbol? keywords)
             (let ((entry (assq keywords (*font-lock-keyword-variables*))))
               (if entry (font-lock-eval-keywords (cdr entry)) #f)))
            (else keywords)))

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
      ;; [SYNTAX-ALIST [SYNTAX-TABLE [LOCAL ...]]]])' followed by an
      ;; alist of variables to set. **Every one of them is buffer-local
      ;; in Emacs** (`setq-local'), and each is stored that way here -
      ;; the parameters are the *global* value the rest of the tree
      ;; reads, and the buffer's own value wins.
      ;;
      ;; What the C does that is *not* here is named in the library
      ;; comment; the largest piece is the
      ;; `font-lock-keywords-alist'/`-removed-keywords-alist' walk, which
      ;; needs `font-lock-add-keywords' with a MODE to have anything to
      ;; walk.
      ;;--------------------------------------------------------------
      ;; "(when (or (not font-lock-set-defaults)
      ;;            (not font-lock-major-mode)
      ;;            (not (derived-mode-p font-lock-major-mode)))
      ;;    (setq font-lock-major-mode major-mode)
      ;;    (setq font-lock-set-defaults t) ...)"
      ;;
      ;; **The guard is what keeps a keyword list added before the mode
      ;; came on**: `font-lock-add-keywords' runs this setup, marks it
      ;; done, and a later turn-on then leaves the list alone. A derived
      ;; mode is not told from its parent here - a mode's parent is not
      ;; recorded in this tree - so the test is the mode being the same.
      (unless (and (font-lock-set-defaults-done?)
                   (eq? (font-lock-major-mode) (major-mode)))
      (set!font-lock-major-mode! (major-mode))
      (set!font-lock-set-defaults-done! #t)
      (let* ((defaults (font-lock-defaults))
             (nth (lambda (i)
                    (let loop ((l defaults) (n i))
                      (cond ((not (pair? l)) #f)
                            ((= n 0) (car l))
                            (else (loop (cdr l) (- n 1)))))))
             ;; "`font-lock-choose-keywords' ... (nth 0 defaults)" - the
             ;; C chooses the level from the *names* first and evaluates
             ;; the chosen one after; doing it the other way round
             ;; handed the chooser a keyword list and the compiler a
             ;; symbol.
             (keywords (font-lock-choose-keywords
                        (and (pair? defaults) (car defaults))
                        (font-lock-value-in-major-mode
                         (*font-lock-maximum-decoration*))))
             (keywords-only (nth 1))
             (case-fold (nth 2))
             (syntax-alist (nth 3)))
        ;; "Syntactic fontification?"
        (set-buffer-local-value! (current-buffer) *font-lock-keywords-only*
                                 (and keywords-only #t))
        ;; "Case fold during regexp fontification?"
        (set-buffer-local-value! (current-buffer)
                                 *font-lock-keywords-case-fold-search*
                                 case-fold)
        ;; "Syntax table for regexp and syntactic fontification?" - the
        ;; alist's entries are (CHAR-OR-STRING . SYNTAX-DESCRIPTOR), and
        ;; the copy keeps the mode's own table untouched.
        (if (not syntax-alist)
            (set-buffer-local-value! (current-buffer)
                                     *font-lock-syntax-table* #f)
            (let ((table (copy-syntax-table (syntax-table))))
              (for-each
               (lambda (selem)
                 (let ((chars (car selem))
                       (syntax (cdr selem)))
                   (for-each
                    (lambda (ch) (modify-syntax-entry ch syntax table))
                    ;; Emacs's `(if (numberp (car selem)) (list ...)
                    ;; (mapcar #'identity ...))': a single character or
                    ;; a string of them. A character is a character here,
                    ;; not a number.
                    (if (string? chars) (string->list chars) (list chars)))))
               syntax-alist)
              (set-buffer-local-value! (current-buffer)
                                       *font-lock-syntax-table* table)))
        ;; "Variable alist?" - each `(VARIABLE . VALUE)' is made local.
        ;; `(nth 4 defaults)' used to hold
        ;; `font-lock-beginning-of-syntax-function'; if it is a cons it
        ;; is part of the alist, which is Emacs's own test.
        (let loop ((vars (let skip ((l defaults) (n (if (pair? (nth 4))
                                                        4 5)))
                           (cond ((not (pair? l)) '())
                                 ((= n 0) l)
                                 (else (skip (cdr l) (- n 1)))))))
          (when (pair? vars)
            ;; **Keyed the way the accessor reads it.** The alist is
            ;; Elisp data and names its variables by *symbol*; this
            ;; library's own state is keyed by *parameter object* (see
            ;; `font-lock-buffer-local`), and Emacs has one namespace
            ;; where this tree has two. Without the mapping a mode's
            ;; `font-lock-syntactic-face-function' - or its
            ;; `font-lock-keywords-only' - was stored where nothing
            ;; looked: measured, the docstring face never appeared.
            (let* ((name (car (car vars)))
                   (val (cdr (car vars)))
                   (param (let ((cell (assq name %font-lock-alist-variables)))
                            (and cell (cdr cell)))))
              (set-buffer-local-value! (current-buffer)
                                       (or param name) val))
            (loop (cdr vars))))
        ;; "Set up `font-lock-keywords' last because its value might
        ;; depend on other settings."
        (set!font-lock-keywords! (font-lock-eval-keywords keywords))
        (unless (eq? (car-safe (font-lock-keywords)) #t)
          (set!font-lock-keywords!
           (font-lock-compile-keywords (font-lock-keywords))))
        (*font-lock-fontify-syntactically-function*
         font-lock-default-fontify-syntactically)
        (set!font-lock-fontify-region-function!
         font-lock-default-fontify-region)
        (set!font-lock-unfontify-region-function!
         font-lock-default-unfontify-region)
        #t)))

    ;;----------------------------------------------------------------
    ;; The mode
    ;;------------------------------------------------------------------

    (define (font-lock-mode-internal arg)
      ;; GNU Emacs's `font-lock-mode-internal' (font-lock.el:703): what
      ;; turning the mode on and off consists of.
      ;;
      ;; **The jit-lock branch is the whole of it now.** Emacs's body adds
      ;; `font-lock-after-change-function` to `after-change-functions` and
      ;; then calls `font-lock-turn-on-thing-lock`, whose first act (with
      ;; the default `font-lock-support-mode`) is to *remove* it again and
      ;; register with jit-lock - so a normal buffer ends with jit-lock
      ;; and no eager fontification. This tree's `after-change-functions`
      ;; is one global list, so that removal is a `delq` from it.
      ;;--------------------------------------------------------------
      (if arg
          (begin
            (*after-change-functions*
             (delq font-lock-after-change-function (*after-change-functions*)))
            (font-lock-set-defaults)
            (font-lock-turn-on-thing-lock))
          (begin
            (font-lock-unfontify-buffer)
            (font-lock-turn-off-thing-lock)))
      #t)

    ;;----------------------------------------------------------------
    ;; The support mode (`font-lock.el:915-947')
    ;;----------------------------------------------------------------
    (define (font-lock-turn-on-thing-lock)
      ;; GNU Emacs's `font-lock-turn-on-thing-lock' (`font-lock.el:924'),
      ;; the `jit-lock-mode` arm - the only support mode this tree has,
      ;; and the one `*font-lock-support-mode*` names by default.
      ;;
      ;; The four `setq-local`s are the same buffer-local entries with
      ;; this library's accessor names, and the `add-hook ... nil t` for
      ;; `jit-lock-after-change-extend-region-functions` is one global
      ;; parameter with the function gated on `font-lock-mode` inside it
      ;; (see `font-lock-extend-jit-lock-region-after-change`).
      ;;--------------------------------------------------------------
      (when (eq? (font-lock-value-in-major-mode (*font-lock-support-mode*))
                 'jit-lock-mode)
      ;; "Prepare for jit-lock"
      (*after-change-functions*
       (delq font-lock-after-change-function (*after-change-functions*)))
      (set!font-lock-buffer-local! *font-lock-flush-function* jit-lock-refontify)
      (set!font-lock-buffer-local! *font-lock-ensure-function*
                                   jit-lock-fontify-now)
      (set!font-lock-buffer-local! *font-lock-fontify-buffer-function*
                                   jit-lock-refontify)
      ;; "Don't fontify eagerly (and don't abort if the buffer is large)."
      (set!font-lock-fontified! #t)
      ;; "Use jit-lock."
      (jit-lock-register font-lock-fontify-region
                         (not (font-lock-keywords-only)))
      ;; "Tell jit-lock how we extend the region to refontify."
      (unless (memq font-lock-extend-jit-lock-region-after-change
                    (*jit-lock-after-change-extend-region-functions*))
        (*jit-lock-after-change-extend-region-functions*
         (cons font-lock-extend-jit-lock-region-after-change
               (*jit-lock-after-change-extend-region-functions*)))))
      #t)

    (define (font-lock-extend-jit-lock-region-after-change beg end old-len)
      ;; GNU Emacs's `font-lock-extend-jit-lock-region-after-change'
      ;; (`font-lock.el:1282'), the member
      ;; `font-lock-turn-on-thing-lock` hangs on
      ;; `jit-lock-after-change-extend-region-functions`.
      ;;
      ;; **Gated on the buffer's `font-lock-mode` here**: Emacs adds it to
      ;; a buffer-local hook list, and this tree's hook is one global
      ;; parameter.
      ;;
      ;; **Not carried**: the pre-enlarge to whole lines (`:1326-1339'),
      ;; which tests for `font-lock-extend-region-wholelines` - a function
      ;; this tree's `font-lock-extend-region-functions` does not have.
      ;;--------------------------------------------------------------
      (when (font-lock-mode-on?)
        (save-excursion
          (let ((region (let ((f (font-lock-extend-after-change-region-function)))
                          (and f (f beg end old-len)))))
            (when region
              (set! beg (min (*jit-lock-start*) (car region)))
              (set! end (max (*jit-lock-end*) (cdr region)))))
          ;; "Then extend the region obeying `font-lock-multiline`
          ;; properties."
          (when (and (> beg (point-min))
                     (get-text-property (- beg 1) 'font-lock-multiline))
            (set! beg (or (previous-single-property-change
                           beg 'font-lock-multiline)
                          (point-min))))
          (when (< end (point-max))
            (set! end
                  (cond
                   ((get-text-property end 'font-lock-multiline)
                    (or (text-property-any end (point-max)
                                           'font-lock-multiline #f)
                        (point-max)))
                   ;; "If `end' has been set by the function above, don't
                   ;; corrupt it." - the C's test is a *call* of the
                   ;; variable (`(font-lock-extend-after-change-region-function
                   ;; end)`), kept as it stands.
                   ((font-lock-extend-after-change-region-function) (+ end 1))
                   (else (+ end 1)))))
          ;; "Finally, pre-enlarge the region to a whole number of
          ;; lines, to try and anticipate what
          ;; `font-lock-default-fontify-region` will do, so as to avoid
          ;; double-redisplay."
          (when (memq font-lock-extend-region-wholelines
                      (*font-lock-extend-region-functions*))
            (goto-char beg)
            (set! beg (min (*jit-lock-start*) (line-beginning-position)))
            (goto-char end)
            (set! end (max (*jit-lock-end*)
                           (if (bolp) (point) (line-beginning-position 2)))))
          (*jit-lock-start* beg)
          (*jit-lock-end* end)
          #t)))

    (define (font-lock-turn-off-thing-lock)
      ;; GNU Emacs's `font-lock-turn-off-thing-lock' (`font-lock.el:947').
      ;;--------------------------------------------------------------
      (when (jit-lock-mode-on?)
        (jit-lock-unregister font-lock-fontify-region))
      #t)

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

    ;; The four function variables' *defaults* (`font-lock.el:1033-1095`),
    ;; set here because the functions they name are defined above - a
    ;; parameter has to be made with a value, so the variable starts #f
    ;; and is given its value where the value exists.
    (*font-lock-flush-function* font-lock-after-change-function)
    (*font-lock-ensure-function*
     (lambda (beg end)
       ;; `(unless font-lock-fontified (save-excursion
       ;; (font-lock-fontify-region beg end)))'
       (unless (font-lock-fontified)
         (save-excursion (font-lock-fontify-region beg end)))))
    (*font-lock-fontify-buffer-function* font-lock-default-fontify-buffer)

    ;; `font-lock-extend-region-functions`' *default* (`font-lock.el:1075`),
    ;; set here for the same reason as the four above: the functions it
    ;; names are defined above, and Emacs's `defvar` value is assigned
    ;; once at load, **not re-set on every `font-lock-set-defaults`** -
    ;; that reset was this port's, and it undid
    ;; `c-font-lock-init`'s global `delq` of
    ;; `font-lock-extend-region-wholelines` (`cc-mode.el:2809`), which
    ;; Emacs applies to this one list for every buffer.
    (*font-lock-extend-region-functions*
     (list font-lock-extend-region-wholelines
           font-lock-extend-region-multiline))

    ))
