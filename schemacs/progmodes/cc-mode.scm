(define-library (schemacs progmodes cc-mode)
  ;; `lisp/progmodes/cc-mode.el' - the mode itself. **The file is
  ;; carried in two passes** and the sections are in Emacs's order among
  ;; themselves, not between the passes: the change machinery came
  ;; first (`:503' onwards - the found-type helpers, the string-fence
  ;; layer with its seams, the three string change functions and their
  ;; helpers, the `#include' bracket and comment-escape pairs, the quote
  ;; parsing, the CPP propertizers, `c-before-change'/`c-after-change'
  ;; and the fl-decl region expanders), and the setup half is at the end
  ;; (`:170'-`:930', `:2211', `:2752': `c-initialize-cc-mode',
  ;; `c-basic-common-init', `c-common-init', `c-font-lock-init',
  ;; `c-extend-after-change-region', the context fontification, the
  ;; electric-indent hook pair, `c-electric-pair-inhibit-predicate',
  ;; `c-post-command'), followed by the C and C++ modes
  ;; (`:2860'-`:3040') and the autoload wiring in `files.scm'.
  ;;
  ;; **Not carried yet**:
  ;;
  ;;   * `c-bind-special-erase-keys' (`normal-erase-is-backspace` is
  ;;     not ported), `c-submit-bug-report' (reporter.el),
  ;;     `c-subword-mode' (subword.el), `cc-guess.el' (its
  ;;     `c-guess-region-max` is carried for `c-or-c++-mode`),
  ;;     `flymake-cc`, `editorconfig-indent-size-vars`,
  ;;     `yank-handled-properties`, `post-text-conversion-hook`, and
  ;;     hideshow (its three variables are stored, so a ported hideshow
  ;;     reads them).
  ;;
  ;; **The buffer-local variables** are accessor pairs over the
  ;; buffer's slot, the tree's spelling (`c-current-comment-prefix` in
  ;; cc-vars is the same shape). Emacs's `setq` becomes the
  ;; `set!`-prefixed setter.
  (import
    (scheme base)
    (only (guile) logand caddr while most-positive-fixnum hash-ref)
    (only (schemacs core syntax-macros) when-e unless-e while-e setq prog1)
    (only (schemacs buffer) current-buffer buffer-local-value major-mode
          set-buffer-local-value! *case-fold-search*)
    (only (schemacs abbrev) define-abbrev define-abbrev-table
          abbrev-table-named abbrev-table-p abbrev-table-abbrevs
          set!local-abbrev-table)
    (only (schemacs marker) copy-marker set-marker marker-position)
    (only (schemacs data) /=)
    (only (schemacs subr) regexp-unmatchable)
    (only (schemacs indent) back-to-indentation)
    (only (schemacs font-lock) font-lock-mode-on?)
    (only (schemacs editfns) point point-max point-min goto-char
          bobp eobp char-before char-after buffer-substring-no-properties
          save-excursion forward-line narrow-to-region save-restriction
          widen
          ;; The two menu items whose command is an Emacs *form* rather
          ;; than a symbol - "Uncomment Region" and "Show Current Style
          ;; Name" - are evaluated in this library (`easy-menu-make-
          ;; symbol`'s thunk), so the names they use must be imported
          ;; here, as the tree's rule always says.
          message region-beginning region-end)
    (only (schemacs search) looking-at match-end match-beginning
          re-search-forward re-search-backward search-forward save-match-data)
    (only (schemacs syntax) skip-syntax-backward skip-chars-backward skip-chars-forward
          parse-partial-sexp syntax-ppss-flush-cache)
    (only (schemacs cmds) backward-char forward-char end-of-line beginning-of-line
          self-insert-command)
    (only (schemacs syntax) set-syntax-table)
    (only (schemacs keyboard) undefined)
    (only (schemacs textprop) *in-property-change-p* get-text-property)
    (only (schemacs progmodes cc-defs)
          c-search-forward-non-nil-char-property
          c-search-forward-char-property c-search-backward-char-property
          c-search-forward-char-property-with-value-on-char
          %c-true
          c-search-backward-char-property-with-value-on-char
          c-clear-char-property c-get-char-property c-put-char-property
          c-clear-char-properties c-clear-char-property-with-value
          c-clear-char-property-with-value-on-char
          c-put-char-properties-on-char
          c-min-property-position c-next-single-property-change
          c-previous-single-property-change
          c-<-as-paren-syntax c->-as-paren-syntax
          c-characterp
          c-mark-<-as-paren c-mark->-as-paren c-unmark-<-or->-as-paren
          c-save-buffer-state c-with-string-fences
          c-syntax-table-hwm set!c-syntax-table-hwm c-major-mode-is
          c-go-up-list-backward c-go-list-forward c-go-list-backward
          c-set-keymap-parent *c-buffer-is-cc-mode*
          *c-restore-string-fences-function*
          *c-clear-string-fences-function*)
    (only (schemacs progmodes cc-engine)
          c-beginning-of-current-token c-end-of-current-token
          c-simple-skip-symbol-backward
          c-backward-syntactic-ws c-forward-syntactic-ws
          c-determine-limit c-determine-+ve-limit
          c-unfind-type c-on-identifier c-forward-token-2 c-backward-token-2
          c-beginning-of-macro %c-langvar
          c-new-BEG set!c-new-BEG c-new-END set!c-new-END
          c-point c-is-escaped c-will-be-escaped c-will-be-unescaped
          c-benign-error
          c-syntactic-re-search-forward
          c-literal-limits c-literal-start c-literal-type
          c-semi-pp-to-literal c-full-pp-to-literal
          c-forward-comments
          c-end-of-macro c-in-literal
          c-ml-string-opener-at-or-around-point
          c-maybe-re-mark-ml-string
          c-depropertize-ml-strings-in-region
          c-clear->-pair-props c-clear-<-pair-props
          c-no-comment-end-of-macro
          c-cheap-inside-bracelist-p c-parse-state c-pull-open-brace
          c-looking-at-or-maybe-in-bracelist c-syntactic-skip-backward
          c-forward-keyword-clause c-forward-type c-forward-declarator
          c-forward-over-token c-enclosing-c++-attribute
          c-ml-string-opener-around-point
          c-looking-at-c++-lambda-capture-list
          c-doc-line-join-re c-beginning-of-objc-method-header
          %c-car %c-cdr %c-cadr %c-cddr %c-caddr
          c-invalidate-sws-region-before c-invalidate-sws-region-after
          c-invalidate-find-decl-cache c-after-change-check-<>-operators
          c-trim-found-types
          c-laomib-invalidate-cache
          c-invalidate-macro-cache c-whack-state-after
          c-no-bracelist-cache set!c-no-bracelist-cache
          c-register-lang-function! %c-lang-function
          c-clear-found-types c-invalidate-state-cache
          c-guess-basic-syntax
          *c-clear-syn-tab-properties-function*
          *c-remove-string-fences-function*
          c-truncate-lit-pos/state-cache
          c-open-string-opener set!c-open-string-opener
          c-put-syntax-table-trim-caches c-clear-syntax-table-trim-caches
          c-clear-syntax-table-with-value-trim-caches
          c-clear-syntax-table-with-value-on-char-trim-caches
          c-put-syntax-table-properties-on-char-trim-caches
          c-put-string-fence-trim-caches
          ;; The buffer-local flags already live in cc-engine (a named
          ;; placement there, because the found-type table reads them).
          c-maybe-stale-found-type set!c-maybe-stale-found-type
          c-new-id-start set!c-new-id-start
          c-new-id-end set!c-new-id-end
          c-new-id-is-type set!c-new-id-is-type
          ;; the mode setup's own reaches
          c-state-cache-init c-init-bs-cache
          c-laomib-cache set!c-laomib-cache
          c-electric-flag set!c-electric-flag
          c-add-type-1 c-beginning-of-syntax)
    (only (guile) delq)
    (only (schemacs buffer)
          with-current-buffer buffer-list hook-value
          *change-major-mode-hook*)
    (only (schemacs frame) *post-command-hook*)
    (only (schemacs insdel) *before-change-functions* *after-change-functions*)
    (only (schemacs subr) run-hooks add-hook remove-hook run-mode-hooks kbd
          substitute-key-definition)
    (only (schemacs intervals) put get *text-property-default-nonsticky*)
    (only (schemacs fns) copy-alist string-equal)
    (only (schemacs newcomment)
          comment-start comment-end comment-start-skip
          comment-multi-line set!comment-multi-line comment-region)
    (only (schemacs textmodes fill)
          set!fill-paragraph-function set!fill-paragraph-handle-comment
          fill-paragraph indent-new-comment-line comment-indent-new-line)
    (only (schemacs font-lock)
          set!font-lock-defaults! set!font-lock-fontify-region-function!
          set!font-lock-extend-after-change-region-function!
          font-lock-extend-region-wholelines
          font-lock-extend-region-functions
          set!font-lock-extend-region-functions!
          *font-lock-support-mode*
          *font-lock-fontify-region-function*)
    (only (schemacs font-core) font-lock-mode font-lock-mode-hook)
    (only (schemacs files) *mode-require-final-newline* major-mode-remap
          %mode-function)
    (only (schemacs keymap) make-sparse-keymap *default-keymap* define-key)
    (only (schemacs command) define-command)
    (only (schemacs custom) define-custom)
    (only (schemacs core derived) define-derived-mode)
    (only (schemacs electric)
          electric-indent-mode-value set!electric-indent-inhibit
          electric-indent-mode-hook electric-indent-local-mode-hook)
    (only (schemacs elec-pair) *electric-pair-inhibit-predicate*)
    (only (schemacs textprop) put-text-property)
    (only (schemacs core regexp-opt) regexp-opt)
    (only (schemacs progmodes prog-mode) prog-mode prog-mode-map)
    (only (schemacs textmodes paragraphs) backward-sentence forward-sentence)
    (only (schemacs indent) indent-for-tab-command)
    (only (schemacs progmodes cc-defs) c-lang-const c-mode-symbol)
    (only (schemacs progmodes cc-langs)
          c-init-language-vars c-lang-set-local! c-lang-var-value)
    (only (schemacs progmodes cc-vars)
          *c-default-style* *c-old-style-variable-behavior*
          *c-style-variables-are-local-p* c-indentation-style
          c-offsets-alist set!c-offsets-alist
          c-block-comment-flag set!c-block-comment-flag
          *c-require-final-newline*
          *c-mode-common-hook* *c-initialization-hook*
          c-make-noise-macro-regexps c-make-macro-with-semi-re)
    (only (schemacs progmodes cc-styles)
          c-initialize-builtin-style c-set-style cc-choose-style-for-mode
          c-setup-paragraph-variables c-set-offset
          *c-guess-basic-syntax-function*)
    (only (schemacs progmodes cc-cmds)
          c-indent-line c-indent-region c-do-auto-fill
          c-indent-new-comment-line c-fill-paragraph c-update-modeline
          c-beginning-of-statement c-end-of-statement
          c-indent-exp c-mark-function c-beginning-of-defun c-end-of-defun
          c-forward-conditional c-backward-conditional c-up-conditional
          c-backslash-region c-toggle-auto-newline c-toggle-electric-state
          c-toggle-hungry-state c-show-syntactic-information c-indent-defun
          c-indent-line-or-region c-electric-delete-forward
          c-electric-backspace c-hungry-delete-forward
          c-hungry-delete-backwards c-electric-pound c-electric-brace
          c-electric-slash c-electric-star c-electric-semi&comma
          c-electric-colon c-electric-lt-gt c-electric-paren
          c-electric-continued-statement
          c-scope-operator c-toggle-comment-style c-display-defun-name
          c-defun-name-and-limits c-cpp-define-name c-comment-indent
          c-outline-level)
    ;; **Imported for their load-time effects**, as Emacs's
    ;; `(require 'cc-fonts)`/`(cc-require 'cc-align)` are: cc-fonts
    ;; registers the `c-font-lock-keywords' variables in font-lock's
    ;; keyword table (which is how `font-lock-eval-keywords` finds the
    ;; symbols `c-font-lock-init` puts in `font-lock-defaults`), and
    ;; cc-align's line-up functions register themselves by symbol.
    ;; cc-guess.el (`cc-require 'cc-guess`) is not ported.
    (schemacs progmodes cc-fonts)
    (schemacs progmodes cc-align)
    (only (schemacs core easymenu) easy-menu-define)
    (only (schemacs progmodes cc-menus)
          cc-imenu-init cc-imenu-c-generic-expression
          cc-imenu-c++-generic-expression cc-imenu-java-generic-expression
          cc-imenu-objc-function)
    (only (schemacs progmodes cc-awk)
          awk-mode-syntax-table c-awk-unstick-NL-prop
          c-awk-beginning-of-defun c-awk-end-of-defun)
    )

  (export
   c-just-done-before-change set!c-just-done-before-change
   c-unfind-enclosing-token c-unfind-coalesced-tokens
   c-before-change-de-typedef c-after-change-de-typedef
   c-update-new-id
   ;; the string-fence layer (`cc-mode.el:586', `:1258'-`:1465')
   c-min-syn-tab-mkr set!c-min-syn-tab-mkr
   c-max-syn-tab-mkr set!c-max-syn-tab-mkr
   c-multiline-string-check-final-quote
   c-put-syn-tab c-clear-syn-tab
   c-clear-string-fences c-restore-string-fences c-remove-string-fences
   c-unescaped-nls-in-string-p c-multiline-string-start-is-being-detached
   c-pps-to-string-delim
   c-before-change-check-unbalanced-strings
   c-after-change-mark-abnormal-strings
   c-after-change-escape-NL-in-string
   c-before-change-include-<> c-after-change-include-<>
   c-before-change-fix-comment-escapes c-after-change-fix-comment-escapes
   c-quoted-number-head-before-point c-quoted-number-tail-after-point
   c-quoted-number-straddling-point
   c-parse-quotes-before-change c-parse-quotes-after-change
   c-bc-changed-stringiness set!c-bc-changed-stringiness
   c-open-string-opener set!c-open-string-opener
   ;; `cc-mode.el:997'-`:1260': the property-change test and the CPP
   ;; propertizers
   c-called-from-text-property-change-p
   c-locate-first-punctuation-prop
   c-depropertize-CPP c-extend-region-for-CPP c-depropertize-new-text
   c-extend-font-lock-region-for-macros
   c-neutralize-CPP-line c-neutralize-syntax-in-CPP
   ;; `cc-mode.el:2224': the before-change function
   c-before-change
   ;; `cc-mode.el:2448'-`:2665': the font-lock region expanders
   c-doc-fl-decl-start c-doc-fl-decl-end
   c-fl-decl-start c-fl-decl-end c-change-expand-fl-region
   ;; `cc-mode.el:2364': the after-change function and its flag
   c-after-change
   c-in-after-change-fontification set!c-in-after-change-fontification
   %c-clear-syn-tab-properties-full
   ;; the mode setup (`cc-mode.el:170'-`:930', `:2211', `:2752')
   c-leave-cc-mode-mode c-init-language-vars-for c-initialize-cc-mode
   c-mode-base-map c-make-inherited-keymap
   c-define-abbrev-table c-populate-abbrev-table
   c-basic-common-init c-setup-doc-comment-style c-common-init
   c-font-lock-init c-after-font-lock-init c-extend-after-change-region
   c-context-expand-fl-region c-before-context-fl-expand-region
   c-font-lock-fontify-region
   c-electric-indent-mode-hook c-electric-indent-local-mode-hook
   c-electric-pair-inhibit-predicate c-post-command
   ;; the modes (`cc-mode.el:2860'-`:3040')
   *c-guess-region-max* c-mode-syntax-table c-mode-map c-mode-hook c-mode
   c-or-c++-mode--regexp c-or-c++-mode
   c++-mode-syntax-table c++-mode-map c++-mode-hook c++-mode
   ;; the other language modes (`cc-mode.el:3040'-`:3300')
   objc-mode-syntax-table objc-mode-map objc-mode-hook objc-mode
   java-mode-syntax-table java-mode-map java-mode-hook java-mode
   c-Java-defun-prompt-regexp
   idl-mode-syntax-table idl-mode-map idl-mode-hook idl-mode
   pike-mode-syntax-table pike-mode-map pike-mode-hook pike-mode
   awk-mode-syntax-table awk-mode-map awk-mode-hook awk-mode
   ;; the menus' variables (Emacs's `c-c-menu' and the rest, which
   ;; `easy-menu-define' makes)
   c-c-menu c-c++-menu c-objc-menu c-java-menu c-idl-menu c-pike-menu
   c-awk-menu
   c-run-mode-hooks)

  (begin

    (define (setq-local name value)
      ;; What `(setq-local NAME VALUE)' does - the same two-line helper
      ;; `scheme.scm` and `text-mode.scm` carry (Emacs has it in
      ;; `subr.el`; this tree's `set-buffer-local-value!` lives in
      ;; `buffer.scm`, which those libraries cannot reach without a
      ;; second spelling, so each mode library has its own copy).
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer) name value))

    ;; ---------------------------------------------------------------
    ;; `c-unfind-enclosing-token' and `c-unfind-coalesced-tokens'
    ;; (`cc-mode.el:503', `:516')
    ;;--------------------------------------------------------------
    (define (c-unfind-enclosing-token pos)
      ;; "If POS is wholly inside a token, remove that id from
      ;; `c-found-types', should it be present. Return t if we were in
      ;; an id, else nil."
      (save-excursion
        (let ((tok-beg (begin (goto-char pos)
                              (and (c-beginning-of-current-token) (point))))
              (tok-end (begin (goto-char pos)
                              (and (c-end-of-current-token) (point)))))
          (when-e (and tok-beg tok-end)
                   (c-unfind-type
                    (buffer-substring-no-properties tok-beg tok-end))
                   #t))))

    (define (c-unfind-coalesced-tokens beg end)
      ;; "If removing the region (beg end) would coalesce an identifier
      ;; ending at beg with an identifier (fragment) beginning at end,
      ;; or an identifier fragment ending at beg with an identifier
      ;; beginning at end, remove the pertinent identifier(s) from
      ;; `c-found-types'."
      (save-excursion
        (when-e (< beg end)
                 (goto-char beg)
                 (let ((lim (c-determine-limit 1000))
                       (lim+ (c-determine-+ve-limit 1000 end)))
                   (when-e
                    (and (not (bobp))
                         (begin (c-backward-syntactic-ws lim) (eq? (point) beg))
                         (not (= (skip-chars-backward
                                  (%c-langvar 'c-symbol-chars)
                                  (- (point) 1))
                                 0))
                         (begin (goto-char beg)
                                (c-forward-syntactic-ws lim+)
                                (<= (point) end))
                         (> (point) beg)
                         (begin (goto-char end)
                                (looking-at (%c-langvar 'c-symbol-char-key))))
                    (goto-char beg)
                    (c-simple-skip-symbol-backward)
                    (c-unfind-type
                     (buffer-substring-no-properties (point) beg)))

                   (goto-char end)
                   (when-e
                    (and (not (eobp))
                         (begin (c-forward-syntactic-ws lim+) (eq? (point) end))
                         (looking-at (%c-langvar 'c-symbol-char-key))
                         (begin (c-backward-syntactic-ws lim) (>= (point) beg))
                         (< (point) end)
                         (not (= (skip-chars-backward
                                  (%c-langvar 'c-symbol-chars)
                                  (- (point) 1))
                                 0)))
                    (goto-char (+ end 1))
                    (c-end-of-current-token)
                    (c-unfind-type
                     (buffer-substring-no-properties end (point))))))))

    ;; ---------------------------------------------------------------
    ;; `c-just-done-before-change' (`cc-mode.el:572').
    ;; `c-maybe-stale-found-type' (`:569') and the `c-new-id-*' pair are
    ;; already in cc-engine - a named placement there, because the
    ;; found-type table reads them.
    ;;--------------------------------------------------------------
    (define (c-just-done-before-change)
      ;; "This variable is set to t by `c-before-change' and to nil by
      ;; `c-after-change'. It is used for two purposes: (i) to detect a
      ;; spurious invocation of `before-change-functions' directly
      ;; following on from a correct one; (ii) to detect when Emacs
      ;; fails to invoke `before-change-functions'."
      (buffer-local-value (current-buffer) 'c-just-done-before-change #f))
    (define (set!c-just-done-before-change value)
      (set-buffer-local-value! (current-buffer) 'c-just-done-before-change value))

    ;; ---------------------------------------------------------------
    ;; `c-new-id-start', `c-new-id-end', `c-new-id-is-type'
    ;; (`cc-mode.el:2186'), and the two functions that read them
    ;;--------------------------------------------------------------
    ;; ---------------------------------------------------------------
    ;; `c-before-change-de-typedef' and `c-after-change-de-typedef'
    ;; (`cc-mode.el:2166', `:2178')
    ;;--------------------------------------------------------------
    (define (c-before-change-de-typedef beg end)
      ;; "For each \"typedef\" starting in (BEG END), remove the defined
      ;; types from c-found-types."
      (let ((prop #f))
        (save-excursion
          (goto-char beg)
          (while-e (and (< (point) end)
                        (begin
                          (set! prop (c-search-forward-non-nil-char-property
                                      'c-typedef))
                          prop))
                   (for-each (lambda (type) (c-unfind-type type)) prop)))))

    (define (c-after-change-de-typedef beg end old-len)
      ;; "For each former \"typedef\" in (BEG END), remove the defined
      ;; types from those which are no longer typedefs."
      (let ((prop #f))
        (save-excursion
          (goto-char beg)
          (c-backward-token-2 1 #f (- (point) 20))
          (while-e (and (< (point) end)
                        (begin
                          (set! prop (c-search-forward-non-nil-char-property
                                      'c-typedef end))
                          prop))
                   (backward-char 1)
                   (when-e (or (not (looking-at (%c-langvar 'c-typedef-key)))
                               (<= (match-end 1) beg))
                            (for-each (lambda (type) (c-unfind-type type))
                                      prop)
                            (c-clear-char-property (point) 'c-typedef))
                   (forward-char 1)))))

    ;; ---------------------------------------------------------------
    ;; `c-update-new-id' (`cc-mode.el:2197')
    ;;--------------------------------------------------------------
    (define (c-update-new-id end)
      ;; "Note the bounds of any identifier that END is in or just
      ;; after, in `c-new-id-start' and `c-new-id-end'. Otherwise set
      ;; these variables to nil. Set `c-new-id-is-type'
      ;; unconditionally to nil."
      (save-excursion
        (goto-char end)
        (let ((id-beg (c-on-identifier)))
          (set!c-new-id-start id-beg)
          (set!c-new-id-end
           (and id-beg
                (begin (goto-char id-beg)
                       (c-forward-token-2)
                       (point))))
          (set!c-new-id-is-type #f))))

    ;; ---------------------------------------------------------------
    ;; `c-min-syn-tab-mkr' and `c-max-syn-tab-mkr' (`cc-mode.el:586',
    ;; `:592'): the range of the buffer that carries a `c-fl-syn-tab'
    ;; property, as markers. They live beside their only readers here,
    ;; in the change-machinery half, rather than at their Emacs
    ;; position before `c-basic-common-init' - that half is later in
    ;; this file (the two passes are noted in the header).
    ;;--------------------------------------------------------------
    (define (c-min-syn-tab-mkr)
      (buffer-local-value (current-buffer) 'c-min-syn-tab-mkr #f))
    (define (set!c-min-syn-tab-mkr value)
      (set-buffer-local-value! (current-buffer) 'c-min-syn-tab-mkr value))
    (define (c-max-syn-tab-mkr)
      (buffer-local-value (current-buffer) 'c-max-syn-tab-mkr #f))
    (define (set!c-max-syn-tab-mkr value)
      (set-buffer-local-value! (current-buffer) 'c-max-syn-tab-mkr value))

    ;; ---------------------------------------------------------------
    ;; `c-put-syn-tab' and `c-clear-syn-tab' (`cc-mode.el:1298', `:1318')
    ;;--------------------------------------------------------------
    (define (c-put-syn-tab pos value)
      ;; "Set both the syntax-table and the c-fl-syn-tab text properties
      ;; at POS to VALUE (which should not be nil)."
      (if (equal? value '(15))
          (c-put-string-fence-trim-caches pos)
          (c-put-syntax-table-trim-caches pos value))
      (c-put-char-property pos 'c-fl-syn-tab value)
      (cond
       ((not (c-min-syn-tab-mkr))
        (set!c-min-syn-tab-mkr (copy-marker pos #t)))
       ((< pos (marker-position (c-min-syn-tab-mkr)))
        (set-marker (c-min-syn-tab-mkr) pos)))
      (cond
       ((not (c-max-syn-tab-mkr))
        (set!c-max-syn-tab-mkr (copy-marker (+ pos 1) #f)))
       ((>= pos (marker-position (c-max-syn-tab-mkr)))
        (set-marker (c-max-syn-tab-mkr) (+ pos 1)))))

    (define (c-clear-syn-tab pos)
      ;; "Remove both the 'syntax-table and `c-fl-syn-tab properties at
      ;; POS."
      (c-clear-syntax-table-trim-caches pos)
      (c-clear-char-property pos 'c-fl-syn-tab)
      (when (c-min-syn-tab-mkr)
        (if (and (eqv? pos (marker-position (c-min-syn-tab-mkr)))
                 (eqv? (+ pos 1) (marker-position (c-max-syn-tab-mkr))))
            (begin
              (set-marker (c-min-syn-tab-mkr) #f)
              (set-marker (c-max-syn-tab-mkr) #f)
              (set!c-min-syn-tab-mkr #f)
              (set!c-max-syn-tab-mkr #f))
            (begin
              (when (eqv? pos (marker-position (c-min-syn-tab-mkr)))
                (set-marker
                 (c-min-syn-tab-mkr)
                 (if (c-get-char-property (+ pos 1) 'c-fl-syn-tab)
                     (+ pos 1)
                     (c-next-single-property-change
                      (+ pos 1) 'c-fl-syn-tab #f
                      (marker-position (c-max-syn-tab-mkr))))))
              (when (eqv? (+ pos 1) (marker-position (c-max-syn-tab-mkr)))
                (set-marker
                 (c-max-syn-tab-mkr)
                 (if (c-get-char-property (- pos 1) 'c-fl-syn-tab)
                     pos
                     (c-previous-single-property-change
                      pos 'c-fl-syn-tab #f
                      (+ (marker-position (c-min-syn-tab-mkr)) 1))))))))
      (c-truncate-lit-pos/state-cache pos))

    (define (%c-clear-syn-tab-properties-full from to)
      ;; "Remove all occurrences of the `syntax-table' and `c-fl-syn-tab'
      ;; text properties between FROM and TO." (`cc-defs.el:1444'; the
      ;; body lives here because the fence state does, but the *name*
      ;; belongs to cc-engine, which exports the wrapper that reaches
      ;; this through `*c-clear-syn-tab-properties-function*'. Two
      ;; exports of one name would be two bindings, which loadup-tests
      ;; refuses.)
      (let ((min-mkr (c-min-syn-tab-mkr)) (max-mkr (c-max-syn-tab-mkr)))
        (when (and min-mkr max-mkr
                   (< from (marker-position max-mkr))
                   (> to (marker-position min-mkr)))
          (let ((pos from))
            (let loop ()
              (when (and (< pos to)
                         (begin
                           (set! pos (c-min-property-position pos to 'c-fl-syn-tab))
                           pos)
                         (< pos to))
                (c-clear-syn-tab pos)
                (set! pos (+ pos 1))
                (loop))))))
      (c-clear-char-properties from to 'syntax-table))

    ;; ---------------------------------------------------------------
    ;; `c-clear-string-fences' and `c-restore-string-fences'
    ;; (`cc-mode.el:1343', `:1411')
    ;;--------------------------------------------------------------
    ;; The two markers are numbers in these bodies: no buffer edit
    ;; happens inside them, so a marker cannot move, and Emacs's use of
    ;; the markers' positions is the same number.
    (define (c-clear-string-fences)
      ;; "Clear syntax-table text properties which are \"mirrored\" by
      ;; c-fl-syn-tab text properties. However, any such \" character
      ;; which ends up not being balanced by another \" is left with a
      ;; '(1) syntax-table property."
      (when (and (c-min-syn-tab-mkr) (c-max-syn-tab-mkr))
        (c-save-buffer-state ((s #f) (pos #f))
          (let ((min-pos (marker-position (c-min-syn-tab-mkr)))
                (max-pos (marker-position (c-max-syn-tab-mkr))))
            (set! pos min-pos)
            (let clear ()
              (when (and (< pos max-pos)
                         (begin
                           (set! pos (c-min-property-position
                                      pos max-pos 'c-fl-syn-tab))
                           pos)
                         (< pos max-pos))
                (c-clear-char-property pos 'syntax-table)
                (set! pos (+ pos 1))
                (clear)))
            (save-excursion
              (set! pos min-pos)
              ;; "Is there already an unbalanced \" before BEG?"
              (set! pos (c-min-property-position pos max-pos 'c-fl-syn-tab))
              (when (< pos max-pos)
                (goto-char pos)
                (when (and (save-match-data
                             (c-search-backward-char-property-with-value-on-char
                              'c-fl-syn-tab '(15) #\" (max (- (point) 500)
                                                           (point-min))))
                           (not (equal? (c-get-char-property (point) 'syntax-table)
                                        '(1))))
                  (set! pos (+ pos 1))))
              (let walk ()
                (when (< pos max-pos)
                  (set! pos (c-min-property-position pos max-pos 'c-fl-syn-tab))
                  (when (< pos max-pos)
                    (if (memv (char-after pos) (%c-langvar 'c-string-delims))
                        (begin
                          ;; "Step over the \"."
                          (set! s (parse-partial-sexp
                                   pos max-pos #f #f #f 'syntax-table))
                          ;; "Seek a (bogus) matching \"."
                          (set! s (parse-partial-sexp
                                   (point) max-pos #f #f s 'syntax-table))
                          ;; "When a bogus matching \" is found, do
                          ;; nothing. Otherwise mark the \" with
                          ;; 'syntax-table '(1)."
                          (unless (and (not (list-ref s 3))
                                       (c-get-char-property
                                        (- (point) 1) 'c-fl-syn-tab))
                            (c-put-char-property pos 'syntax-table '(1))
                            ;; "Remove syntax-table text properties from
                            ;; template delimiters."
                            (c-clear-char-property-with-value
                             (+ pos 1) (c-point 'eol pos)
                             'syntax-table c-<-as-paren-syntax)
                            (c-clear-char-property-with-value
                             (+ pos 1) (c-point 'eol pos)
                             'syntax-table c->-as-paren-syntax))
                          (set! pos (point)))
                        (set! pos (+ pos 1))))
                    (walk))))))))

    (define (c-restore-string-fences)
      ;; "Restore any syntax-table text properties which are \"mirrored\"
      ;; by c-fl-syn-tab text properties."
      (when (and (c-min-syn-tab-mkr) (c-max-syn-tab-mkr))
        (c-save-buffer-state ((pos (marker-position (c-min-syn-tab-mkr))))
          (let ((max-pos (marker-position (c-max-syn-tab-mkr))))
            (let loop ()
              (when (and (< pos max-pos)
                         (begin
                           (set! pos (c-min-property-position
                                      pos max-pos 'c-fl-syn-tab))
                           pos)
                         (< pos max-pos))
                (when (and (equal? (c-get-char-property pos 'syntax-table) '(1))
                           (equal? (c-get-char-property pos 'c-fl-syn-tab) '(15)))
                  (c-clear-char-properties (+ pos 1) (c-point 'eol pos)
                                           'syntax-table))
                (c-put-char-property pos 'syntax-table
                                     (c-get-char-property pos 'c-fl-syn-tab))
                (set! pos (+ pos 1))
                (loop)))))))

    ;; ---------------------------------------------------------------
    ;; `c-unescaped-nls-in-string-p' (`cc-mode.el:1213'),
    ;; `c-multiline-string-start-is-being-detached' (`:1229') and
    ;; `c-pps-to-string-delim' (`:1237')
    ;;--------------------------------------------------------------
    (define (c-unescaped-nls-in-string-p . quote-pos-args)
      ;; "Return whether unescaped newlines can be inside strings. If the
      ;; current language handles multi-line strings, the value of this
      ;; function is always nil."
      (let ((quote-pos (if (pair? quote-pos-args) (car quote-pos-args) #f)))
        (cond
         ((%c-langvar 'c-ml-string-opener-re) #f)
         ((not (%c-langvar 'c-multiline-string-start-char)) #f)
         ((c-characterp (%c-langvar 'c-multiline-string-start-char))
          (and quote-pos
               (eqv? (char-before quote-pos)
                     (%c-langvar 'c-multiline-string-start-char))))
         (else #t))))

    (define (c-multiline-string-start-is-being-detached end)
      ;; "If (e.g.), the # character in Pike is being detached from the
      ;; string opener it applies to, return t. Else return nil. END is
      ;; the argument supplied to every before-change function."
      (and (memv (char-after end) (%c-langvar 'c-string-delims))
           (c-characterp (%c-langvar 'c-multiline-string-start-char))
           (eqv? (char-before end)
                 (%c-langvar 'c-multiline-string-start-char))))

    (define (c-pps-to-string-delim end)
      ;; "parse-partial-sexp forward to the next string quote, which is
      ;; deemed to be a closing quote. Return nil.
      ;;
      ;; We remove string-fence syntax-table text properties from
      ;; characters we pass over."
      (let* ((start (point))
             (no-st-s (list 0 #f #f #\" #f #f 0 #f start #f #f))
             (st-s (list 0 #f #f #t #f #f 0 #f start #f #f))
             (no-st-pos #f)
             (st-pos #f))
        (parse-partial-sexp start end #f #f no-st-s 'syntax-table)
        (set! no-st-pos (point))
        (goto-char start)
        (let loop ()
          (when (begin
                  (parse-partial-sexp (point) end #f #f st-s 'syntax-table)
                  (unless (bobp)
                    (c-clear-syn-tab (- (point) 1)))
                  (set! st-pos (point))
                  (and (< (point) end)
                       (not (eqv? (char-before) #\"))))
            (loop)))
        (goto-char (min no-st-pos st-pos))
        #f))

    ;; ---------------------------------------------------------------
    ;; `c-multiline-string-check-final-quote' (`cc-mode.el:1258')
    ;;--------------------------------------------------------------
    (define (c-multiline-string-check-final-quote)
      ;; "Check that the final quote in the buffer is correctly marked or
      ;; not with a string-fence syntax-table text property."
      (let ((pos-ll #f) (pos-lt #f))
        (save-excursion
          (goto-char (point-max))
          (skip-chars-backward "^\"")

          (let loop ()
            (when (and (not (bobp))
                       (cond
                        ((begin
                           (set! pos-ll (c-literal-limits))
                           (set! pos-lt (c-literal-type pos-ll))
                           (memv pos-lt '(c c++)))
                         ;; In a comment.
                         (goto-char (car pos-ll)))
                        ((save-excursion
                           (backward-char)      ; over "
                           (c-is-escaped (point)))
                         ;; At an escaped string.
                         (backward-char)
                         #t)
                        (else
                         ;; At a significant "
                         (c-clear-syn-tab (- (point) 1))
                         (set! pos-ll (c-literal-limits))
                         (set! pos-lt (c-literal-type pos-ll))
                         #f)))
              (skip-chars-backward "^\"")))
          (cond
           ((bobp) #f)
           ((eq? pos-lt 'string)
            (c-put-syn-tab (- (point) 1) '(15)))
           (else #f)))))

    ;; ---------------------------------------------------------------
    ;; `c-remove-string-fences' (`cc-mode.el:1439')
    ;;--------------------------------------------------------------
    (define (c-remove-string-fences . here-args)
      ;; "The character after HERE (default point) is either a string
      ;; delimiter or a newline, which is marked with a string fence text
      ;; property for both syntax-table and c-fl-syn-tab. Remove these
      ;; properties from that character and its matching newline or
      ;; string delimiter, if any (there may not be one if there is a
      ;; missing newline at EOB)."
      (let ((here (and (pair? here-args) (car here-args))))
        (save-excursion
          (if here
              (goto-char here)
              (set! here (point)))
          (cond
           ((memv (char-after) (%c-langvar 'c-string-delims))
            (save-excursion
              (save-match-data
                (forward-char)
                (if (and (c-search-forward-char-property 'syntax-table '(15) #f)
                         (memv (char-before) (list #\newline #\return)))
                    (c-clear-syn-tab (- (point) 1)))))
            (c-clear-syn-tab (point)))
           ((memv (char-after) (list #\newline #\return))
            (save-excursion
              (save-match-data
                (when (and (c-search-backward-char-property
                            'syntax-table '(15) #f)
                           (memv (char-after) (%c-langvar 'c-string-delims)))
                  (c-clear-syn-tab (point)))))
            (c-clear-syn-tab (point)))
           (else
            (c-benign-error "c-remove-string-fences: Wrong position"))))))

    ;; ---------------------------------------------------------------
    ;; `c-bc-changed-stringiness' (`cc-mode.el:1432') and
    ;; `c-open-string-opener' (`:1466')
    ;;--------------------------------------------------------------
    ;; Emacs `defvar's the first without `make-variable-buffer-local', so
    ;; it is a plain variable here - a global that the change functions
    ;; set and read across the two halves of one change.
    (define c-bc-changed-stringiness #f)
    (define (set!c-bc-changed-stringiness value)
      (set! c-bc-changed-stringiness value))
    ;; `c-open-string-opener' is buffer-local, and its accessor pair has
    ;; moved down to `cc-engine.scm' so `cc-awk.scm' can reach it; it is
    ;; imported from there and re-exported here, as it was defined here
    ;; before.

    ;; ---------------------------------------------------------------
    ;; `c-before-change-check-unbalanced-strings' (`cc-mode.el:1472')
    ;;--------------------------------------------------------------
    (define (c-before-change-check-unbalanced-strings beg end)
      ;; "If BEG or END is inside an unbalanced string, remove the
      ;; syntax-table text property from respectively the start or end of
      ;; the string. Also extend the region (c-new-BEG c-new-END) as
      ;; necessary to cope with the coming change involving the insertion
      ;; or deletion of an odd number of quotes."
      (c-save-buffer-state
          ((end-limits
            (begin
              (goto-char (if (c-multiline-string-start-is-being-detached end)
                             (+ end 1)
                             end))
              (c-literal-limits)))
           (end-literal-type (and end-limits (c-literal-type end-limits)))
           (beg-limits
            (begin
              (goto-char beg)
              (c-literal-limits)))
           (beg-literal-type (and beg-limits (c-literal-type beg-limits))))

        (cond
         ;; "The text about to be inserted might contain a multiline
         ;; string opener. Set c-new-END after anything which might be
         ;; affected. Go to the end of the putative multiline string."
         ((and (not (%c-langvar 'c-ml-string-opener-re))
               (c-characterp (%c-langvar 'c-multiline-string-start-char)))
          (goto-char end)
          (c-pps-to-string-delim (point-max))
          (when (< (point) (point-max))
            (let again ()
              (when (and
                     (begin
                       (let skip ()
                         (when (and
                                (c-syntactic-re-search-forward
                                 (if (%c-true (%c-langvar 'c-single-quotes-quote-strings))
                                     "[\"']\\|\\s|"
                                     "\"\\|\\s|")
                                 (point-max) #t #t)
                                (begin
                                  (c-clear-syn-tab (- (point) 1))
                                  (not (memv (char-before)
                                             (%c-langvar 'c-string-delims)))))
                           (skip)))
                       (memv (char-before) (%c-langvar 'c-string-delims)))
                     (begin
                       (c-pps-to-string-delim (point-max))
                       (< (point) (point-max))))
                (again))))
          (set!c-new-END (max (point) (c-new-END))))

         ((and (not (%c-langvar 'c-ml-string-opener-re))
               (%c-langvar 'c-multiline-string-start-char))
          (set!c-bc-changed-stringiness
           (not (eq? (eq? end-literal-type 'string)
                     (eq? beg-literal-type 'string))))
          ;; "Deal with deletion of backslashes before "s."
          (goto-char end)
          (if (and (looking-at (if (%c-true (%c-langvar 'c-single-quotes-quote-strings))
                                   "\\\\*[\"']"
                                   "\\\\*\""))
                   (c-is-escaped (point)))
              (set!c-bc-changed-stringiness (not (c-bc-changed-stringiness))))
          (if (eq? beg-literal-type 'string)
              (set!c-new-BEG (min (car beg-limits) (c-new-BEG)))))

         ((< end (point-max))
          ;; "Have we just escaped a newline by deleting characters?"
          (if (and (eq? end-literal-type 'string)
                   (memv (char-after end) (list #\newline #\return)))
              (cond
               ;; "Are we escaping a newline by deleting stuff between \
               ;; and \n?"
               ((and (> end beg)
                     (c-will-be-escaped end beg end))
                (c-remove-string-fences end)
                (goto-char (+ end 1)))
               ;; "Are we unescaping a newline ..."
               ((and (c-is-escaped end)
                     (or (= beg end)      ; "by inserting stuff between \ and \n?"
                         (c-will-be-unescaped beg))) ; "by removing an odd number of \s?"
                (goto-char (+ end 1)))  ; "To after the NL which is being unescaped."
               (else
                (goto-char end)))
              (goto-char end))

          ;; "Move to end of logical line (as it will be after the change,
          ;; or as it was before unescaping a NL.)"
          (let lines ()
            (when (begin
                    (end-of-line)
                    (and (eqv? (char-before) #\\) (not (eobp))))
              (forward-line)
              (lines)))
          ;; "We're at an EOLL or point-max."
          (if (equal? (c-get-char-property (point) 'syntax-table) '(15))
              (if (memv (char-after) (list #\newline #\return))
                  ;; "Normally terminated invalid string."
                  (c-remove-string-fences)
                  ;; "Opening " at EOB."
                  (c-clear-syn-tab (- (point) 1)))
              (when (and (c-search-backward-char-property
                          'syntax-table '(15) (c-new-BEG))
                         (memv (char-after) (%c-langvar 'c-string-delims)))
                ;; "Opening " on last line of text (without EOL)."
                (c-remove-string-fences)
                (set!c-new-BEG (min (c-new-BEG) (point))))))

         (else
          (goto-char end)               ; point-max
          (when (and (c-search-backward-char-property
                      'syntax-table '(15) (c-new-BEG))
                     (memv (char-after) (%c-langvar 'c-string-delims)))
            (c-remove-string-fences))))

        (unless
            (or (and
                 ;; "Don't set c-new-BEG/END if we're in an ml string."
                 (%c-langvar 'c-ml-string-opener-re)
                 (eq? beg-literal-type 'string)
                 (c-ml-string-opener-at-or-around-point (car beg-limits)))
                (and (%c-langvar 'c-multiline-string-start-char)
                     (not (%c-langvar 'c-ml-string-opener-re))
                     (not (c-characterp (%c-langvar 'c-multiline-string-start-char)))))
          (when (and (eq? end-literal-type 'string)
                     (or (memv (char-before (cdr end-limits))
                               (%c-langvar 'c-string-delims))
                         (memv (char-before (cdr end-limits))
                               (list #\newline #\return)))
                     (memv (char-after (car end-limits))
                           (%c-langvar 'c-string-delims)))
            (set!c-new-END (max (c-new-END) (cdr end-limits)))
            (when (equal? (c-get-char-property (car end-limits) 'syntax-table)
                          '(15))
              (c-remove-string-fences (car end-limits)))
            (set!c-new-END (max (c-new-END) (cdr end-limits))))

          (when (and (eq? beg-literal-type 'string)
                     (memv (char-after (car beg-limits))
                           (%c-langvar 'c-string-delims)))
            (c-remove-string-fences (car beg-limits))
            (set!c-new-BEG (min (c-new-BEG) (car beg-limits)))))))

    ;; ---------------------------------------------------------------
    ;; `c-after-change-mark-abnormal-strings' (`cc-mode.el:1619')
    ;;--------------------------------------------------------------
    (define (c-after-change-mark-abnormal-strings beg end old-len)
      ;; "Mark any unbalanced strings in the region (c-new-BEG c-new-END)
      ;; with string fence syntax-table text properties."
      (if (and (%c-langvar 'c-multiline-string-start-char)
               (not (%c-langvar 'c-ml-string-opener-re))
               (not (c-characterp (%c-langvar 'c-multiline-string-start-char))))
          ;; "Only the last " might need to be marked."
          (c-save-buffer-state
              ((beg-literal-limits
                (begin (goto-char beg) (c-literal-limits)))
               (beg-literal-type (c-literal-type beg-literal-limits))
               (end-literal-limits #f) (end-literal-type #f))
            (when (and (eq? beg-literal-type 'string)
                       (c-get-char-property (car beg-literal-limits) 'syntax-table))
              (c-clear-syn-tab (car beg-literal-limits))
              (set!c-bc-changed-stringiness (not (c-bc-changed-stringiness))))
            (set! end-literal-limits (begin (goto-char end) (c-literal-limits)))
            (set! end-literal-type (c-literal-type end-literal-limits))
            ;; "Deal with the insertion of backslashes before a "."
            (goto-char end)
            (if (and (looking-at "\\\\*\"")
                     (eqv? (logand (skip-chars-backward "\\\\" beg) 1) 1))
                (set!c-bc-changed-stringiness (not (c-bc-changed-stringiness))))
            (when (eq? (eq? (eq? beg-literal-type 'string)
                            (eq? end-literal-type 'string))
                       (c-bc-changed-stringiness))
              (c-multiline-string-check-final-quote)))
          ;; "There could be several "s needing marking."
          (c-save-buffer-state
              ((cll (begin (goto-char (c-new-BEG)) (c-literal-limits)))
               (beg-literal-type (and cll (c-literal-type cll)))
               (beg-limits
                (cond
                 ((and (eq? beg-literal-type 'string)
                       (c-unescaped-nls-in-string-p (car cll)))
                  (cons (car cll)
                        (begin
                          (goto-char (+ (car cll) 1))
                          (re-search-forward
                           (cdr (assq (char-after (car cll))
                                      (%c-langvar 'c-string-innards-re-alist)))
                           #f #t)
                          (min (+ (point) 1) (point-max)))))
                 ((and (not beg-literal-type)
                       (begin
                         (goto-char beg)
                         (and (not (bobp))
                              (not (%c-langvar 'c-ml-string-opener-re))
                              (eqv? (char-before)
                                    (%c-langvar 'c-multiline-string-start-char))))
                       (memv (char-after) (%c-langvar 'c-string-delims)))
                  (cons (point)
                        (begin
                          (forward-char)
                          (re-search-forward
                           (cdr (assq (char-before)
                                      (%c-langvar 'c-string-innards-re-alist)))
                           #f #t)
                          (+ (point) 1))))
                 (else cll)))
               (end-hwm
                (max
                 (begin
                   (goto-char
                    (if (and (memv (char-after end) (list #\newline #\return))
                             (c-is-escaped end))
                        (min (+ end 1) (point-max))
                        end))
                   (let lines ()
                     (when (begin
                             (end-of-line)
                             (and (eqv? (char-before) #\\) (not (eobp))))
                       (forward-line)
                       (lines)))
                   (point))
                 (c-new-END)))
               (s #f))
            (goto-char
             (cond ((not beg-literal-type) (c-new-BEG))
                   ((eq? beg-literal-type 'string) (car beg-limits))
                   (else (cdr beg-limits)))) ; comment
            ;; "Handle one string each time around the next while loop."
            (let strings ()
              (when (and
                     (< (point) end-hwm)
                     (begin
                       ;; "Skip over any comments before the next string."
                       (let comments ()
                         (when (begin
                                 (set! s (parse-partial-sexp
                                          (point) end-hwm #f #f s 'syntax-table))
                                 (and (< (point) end-hwm)
                                      (or (not (list-ref s 3))
                                          (not (memv (char-before)
                                                     (%c-langvar 'c-string-delims))))))
                           (comments)))
                       ;; "We're at the start of a string."
                       (and (memv (char-before) (%c-langvar 'c-string-delims))
                            (not (list-ref s 4))))) ; "out of the comment"
                (unless
                    (and (%c-langvar 'c-ml-string-opener-re)
                         (c-maybe-re-mark-ml-string))
                  (if (c-unescaped-nls-in-string-p (- (point) 1))
                      (looking-at "\\(\\\\\\(.\\|\n\\)\\|[^\"]\\)*")
                      (looking-at
                       (cdr (assq (char-before)
                                  (%c-langvar 'c-string-innards-re-alist)))))
                  (cond
                   ((memv (char-after (match-end 0)) (list #\newline #\return))
                    (c-put-syn-tab (- (point) 1) '(15))
                    (c-put-syn-tab (match-end 0) '(15))
                    (set!c-new-BEG (min (c-new-BEG) (point)))
                    (set!c-new-END (max (c-new-END) (match-end 0)))
                    (set!c-open-string-opener (- (point) 1)))
                   ((or (eqv? (match-end 0) (point-max))
                        (eqv? (char-after (match-end 0)) #\\)) ; "\ at EOB"
                    (c-put-syn-tab (- (point) 1) '(15))
                    (set!c-new-BEG (min (c-new-BEG) (point)))
                    (set!c-new-END (max (c-new-END) (match-end 0)))
                    (set!c-open-string-opener (- (point) 1))))
                  (goto-char (min (+ (match-end 0) 1) (point-max))))
                (set! s #f)
                (strings))))))

    ;; ---------------------------------------------------------------
    ;; `c-after-change-escape-NL-in-string' (`cc-mode.el:1740')
    ;;--------------------------------------------------------------
    (define (c-after-change-escape-NL-in-string beg end old-len)
      ;; "If a backslash has just been inserted into a string, and this
      ;; quotes an existing newline, remove the string fence syntax-table
      ;; text properties on what has become the tail of the string."
      (let ((lit-start #f) (lim #f))
        (when
            (and (> end beg)
                 (memv (char-after end) (list #\newline #\return))
                 (c-is-escaped end)
                 (begin (goto-char end)
                        (set! lit-start (c-literal-start))
                        lit-start)
                 (memv (char-after (or lit-start (point)))
                       (%c-langvar 'c-string-delims))
                 (or (not (%c-langvar 'c-ml-string-opener-re))
                     (begin
                       (goto-char lit-start)
                       (not (c-ml-string-opener-at-or-around-point)))
                     (save-excursion
                       (c-beginning-of-macro))))
          (goto-char (+ end 1))         ; "After the \"
          (set! lim (c-point 'eoll))
          (goto-char (+ end 1))
          (when (c-search-forward-char-property-with-value-on-char
                 'syntax-table '(15) #\" lim)
            (c-remove-string-fences end)
            (c-remove-string-fences (- (point) 1))))))

    ;; ---------------------------------------------------------------
    ;; The quote parsing (`cc-mode.el:1785'-`:2020')
    ;;--------------------------------------------------------------
    ;; "Valid digit separators in numbers will get the syntax-table
    ;; "punctuation" property, '(1), and also the text property
    ;; `c-digit-separator' value t." The three regexps are `defconst's in
    ;; Emacs - plain variables here.
    (define c-maybe-quoted-number-head
      "\\(0\\([Xx]\\([[:xdigit:]]\\('?[[:xdigit:]]\\)*\\)?\\|[Bb]\\([01]\\('?[01]\\)*\\)?\\|\\('?[0-7]\\)*\\)\\|[1-9]\\('?[0-9]\\)*\\)")

    (define (c-quoted-number-head-before-point)
      ;; "Return non-nil when the head of a possibly quoted number is
      ;; found immediately before point. The value returned in this case
      ;; is the buffer position of the start of the head. That position
      ;; is also in (match-beginning 0)."
      (when-e (%c-true (%c-langvar 'c-has-quoted-numbers))
        (save-excursion
          (let ((here (point))
                (found #f))
            (skip-chars-backward "[:xdigit:]'")
            (if (and (memv (char-before) (list #\x #\X))
                     (eqv? (char-before (- (point) 1)) #\0))
                (backward-char 2))
            (let loop ()
              (when (begin
                      (set! found
                            (re-search-forward c-maybe-quoted-number-head here #t))
                      (and found (< found here)))
                (loop)))
            (and (eqv? found here) (match-beginning 0))))))

    (define c-maybe-quoted-number-tail
      "\\(\\([xX']?[[:xdigit:]]\\('?[[:xdigit:]]\\)*\\)\\|\\([bB']?[01]\\('?[01]\\)*\\)\\|\\('?[0-9]\\)+\\)")

    (define (c-quoted-number-tail-after-point)
      ;; "Return non-nil when a proper tail of a possibly quoted number
      ;; is found immediately after point. The value returned in this
      ;; case is the buffer position of the end of the tail. That
      ;; position is also in (match-end 0)."
      (when-e (%c-true (%c-langvar 'c-has-quoted-numbers))
        (and (looking-at c-maybe-quoted-number-tail)
             (match-end 0))))

    (define c-maybe-quoted-number
      "\\(0\\(\\([Xx][[:xdigit:]]\\('?[[:xdigit:]]\\)*\\)\\|\\([Bb][01]\\('?[01]\\)*\\)\\|\\('?[0-7]\\)*\\)\\|[1-9]\\('?[0-9]\\)*\\)")

    (define (c-quoted-number-straddling-point)
      ;; "Return non-nil if a definitely quoted number starts before
      ;; point and ends after point. In this case the number is bounded
      ;; by (match-beginning 0) and (match-end 0)."
      (when-e (%c-true (%c-langvar 'c-has-quoted-numbers))
        (save-excursion
          (let ((here (point))
                (bound (begin (skip-chars-forward "[:xdigit:]'") (point))))
            (goto-char here)
            (when-e (< (skip-chars-backward "[:xdigit:]'") 0)
              (if (and (memv (char-before) (list #\x #\X))
                       (eqv? (char-before (- (point) 1)) #\0))
                  (backward-char 2))
              (let loop ()
                (when (and (re-search-forward c-maybe-quoted-number bound #t)
                           (<= (match-end 0) here))
                  (loop)))
              (and (< (match-beginning 0) here)
                   (> (match-end 0) here)
                   (save-match-data
                     (goto-char (match-beginning 0))
                     (save-excursion
                       (search-forward "'" (match-end 0) #t)))))))))

    (define (c-parse-quotes-before-change beg end)
      ;; "This function analyzes 's near the region (c-new-BEG
      ;; c-new-END), amending those two variables as needed to include
      ;; 's into that region when they might be syntactically relevant to
      ;; the change in progress.
      ;;
      ;; Having amended that region, the function removes pertinent text
      ;; properties (syntax-table properties with value '(1) and
      ;; c-digit-separator props with value t) from 's in it. This
      ;; operation is performed even within strings and comments."
      ;;
      ;; BEG and END are unused, as in Emacs.
      (parameterize ((*case-fold-search* #f))
        (c-save-buffer-state ()
          (goto-char (c-new-BEG))
          ;; "We need to scan for 's from the BO (logical) line."
          (beginning-of-line)
          (let lines ()
            (when (eqv? (char-before (- (point) 1)) #\\)
              (beginning-of-line 0)
              (lines)))
          (while (and (< (point) (c-new-BEG))
                      (search-forward "'" (c-new-BEG) #t))
            (cond
             ((c-quoted-number-straddling-point)
              (goto-char (match-end 0))
              (if (> (match-end 0) (c-new-BEG))
                  (set!c-new-BEG (match-beginning 0))))
             ((c-quoted-number-head-before-point)
              (if (>= (point) (c-new-BEG))
                  (set!c-new-BEG (match-beginning 0))))
             ((looking-at "\\([^'\\]\\|\\\\\\([0-7]\\{1,3\\}\\|[xuU][[:xdigit:]]+\\|.\\)\\)'")
              (goto-char (match-end 0))
              (if (> (match-end 0) (c-new-BEG))
                  (set!c-new-BEG (- (match-beginning 0) 1))))
             ((looking-at "\\\\'")
              (set!c-new-BEG (min (c-new-BEG) (- (point) 1)))
              (goto-char (match-end 0)))
             ((save-excursion
                (not (search-forward "'" (c-new-BEG) #t)))
              (set!c-new-BEG (min (c-new-BEG) (- (point) 1))))
             (else #f)))

          (goto-char (c-new-END))
          ;; "We will scan from the BO (logical) line."
          (beginning-of-line)
          (let lines ()
            (when (eqv? (char-before (- (point) 1)) #\\)
              (beginning-of-line 0)
              (lines)))
          (while (and (< (point) (c-new-END))
                      (search-forward "'" (c-new-END) #t))
            (cond
             ((c-quoted-number-straddling-point)
              (goto-char (match-end 0))
              (if (> (match-end 0) (c-new-END))
                  (set!c-new-END (match-end 0))))
             ((c-quoted-number-tail-after-point)
              (goto-char (match-end 0))
              (if (> (match-end 0) (c-new-END))
                  (set!c-new-END (match-end 0))))
             ((looking-at "\\([^'\\]\\|\\\\\\([0-7]\\{1,3\\}\\|[xuU][[:xdigit:]]+\\|.\\)\\)'")
              (goto-char (match-end 0))
              (if (> (match-end 0) (c-new-END))
                  (set!c-new-END (match-end 0))))
             ((looking-at "\\\\'")
              (goto-char (match-end 0))
              (set!c-new-END (max (c-new-END) (point))))
             ((equal? (c-get-char-property (- (point) 1) 'syntax-table) '(1))
              (when (c-search-forward-char-property-with-value-on-char
                     'syntax-table '(1) #\' (c-point 'eoll))
                (set!c-new-END (max (point) (c-new-END)))))
             (else #f)))

          ;; "Having reached c-new-END, handle any 's after it whose
          ;; context may be changed by the current buffer change. The
          ;; idea is to catch monstrosities like ',',',',',' changing
          ;; "polarity"."
          (goto-char (c-new-END))
          (cond
           ((c-quoted-number-tail-after-point)
            (set!c-new-END (match-end 0)))
           ((looking-at "\\(\\\\\\([0-7]\\{1,3\\}\\|[xuU][[:xdigit:]]+\\|.\\)\\|.\\)?\\('\\([^'\\]\\|\\\\\\([0-7]\\{1,3\\}\\|[xuU][[:xdigit:]]+\\|.\\)\\)\\)*'")
            (set!c-new-END (match-end 0))))

          ;; "Remove the '(1) syntax-table property from any \"'\"s
          ;; within (c-new-BEG c-new-END)."
          (goto-char (c-new-BEG))
          (when (c-search-forward-char-property-with-value-on-char
                 'syntax-table '(1) #\' (c-new-END))
            (c-clear-syntax-table-with-value-on-char-trim-caches
             (- (point) 1) (c-new-END) '(1) #\')
            ;; "Remove the c-digit-separator text property from the same
            ;; \"'\"s."
            (when (%c-true (%c-langvar 'c-has-quoted-numbers))
              (c-clear-char-property-with-value-on-char
               (- (point) 1) (c-new-END)
               'c-digit-separator #t #\'))))))

    (define (c-parse-quotes-after-change beg end old-len)
      ;; "This function applies syntax-table properties (value '(1)) and
      ;; c-digit-separator properties as needed to 's within the range
      ;; (c-new-BEG c-new-END). This operation is performed even within
      ;; strings and comments."
      (parameterize ((*case-fold-search* #f))
        (c-save-buffer-state
            ((num-beg #f) (num-end #f))
          ;; "Apply the needed syntax-table and c-digit-separator text
          ;; properties to quotes."
          (save-restriction
            (goto-char (c-new-BEG))
            (while (and (< (point) (c-new-END))
                        (search-forward "'" (c-new-END) 'limit))
              (cond
               ((c-is-escaped (- (point) 1))
                #t)                         ; "not a real '."
               ((c-quoted-number-straddling-point)
                (set! num-beg (match-beginning 0))
                (set! num-end (match-end 0))
                (c-put-syntax-table-properties-on-char-trim-caches
                 num-beg num-end '(1) #\')
                (c-put-char-properties-on-char num-beg num-end
                                               'c-digit-separator #t #\')
                (goto-char num-end))
               ((looking-at "\\([^\\']\\|\\\\\\([0-7]\\{1,3\\}\\|[xuU][[:xdigit:]]+\\|.\\)\\)'")         ; "balanced quoted expression"
                (goto-char (match-end 0)))
               ((looking-at "\\\\'")        ; "Anomalous construct"
                (c-truncate-lit-pos/state-cache (- (point) 1))
                (c-put-syntax-table-properties-on-char-trim-caches
                 (- (point) 1) (+ (point) 2) '(1) #\'))
               (else
                (c-put-syntax-table-trim-caches (- (point) 1) '(1))))
              ;; "Prevent the next `c-quoted-number-straddling-point'
              ;; getting confused by already processed single quotes."
              (narrow-to-region (point) (point-max)))))))

    ;; ---------------------------------------------------------------
    ;; `c-before-change-include-<>' and `c-after-change-include-<>'
    ;; (`cc-mode.el:2029', `:2064')
    ;;--------------------------------------------------------------
    (define (c-before-change-include-<> beg end)
      ;; "Remove category/syntax-table properties from each #include
      ;; <..>. In particular, from the < and > characters which have been
      ;; marked as parens using these properties. This is done on every
      ;; such #include <..> with a portion between BEG and END."
      (c-save-buffer-state
          ((search-end (begin (goto-char end)
                              (c-end-of-macro)
                              (point)))
           (hash-pos #f))
        (goto-char beg)
        (c-beginning-of-macro)
        (while (and (< (point) search-end)
                    (re-search-forward (%c-langvar 'c-cpp-include-key)
                                       search-end 'bound)
                    (begin (set! hash-pos (match-beginning 0)) hash-pos))
          (c-forward-comments (c-point 'eoll))
          (when (and (< (point) search-end)
                     (looking-at "\\s(")
                     (looking-at "\\(<\\)[^>\n\r]*\\(>\\)?")
                     (null? (cdr (c-semi-pp-to-literal hash-pos))))
            (c-unmark-<-or->-as-paren (match-beginning 1))
            (when (< hash-pos (c-new-BEG))
              (set!c-new-BEG hash-pos))
            (when (match-beginning 2)
              (c-unmark-<-or->-as-paren (match-beginning 2))
              (when (> (match-end 2) (c-new-END))
                (set!c-new-END (match-end 2))))))))

    (define (c-after-change-include-<> beg end old-len)
      ;; "Apply category/syntax-table properties to each #include <..>.
      ;; In particular, to the < and > characters to mark them as
      ;; matching parens using these properties. This is done on every
      ;; such #include <..> with a portion between BEG and END."
      (c-save-buffer-state
          ((search-end (begin (goto-char end)
                              (c-end-of-macro)
                              (point)))
           (hash-pos #f))
        (goto-char beg)
        (c-beginning-of-macro)
        (while (and (< (point) search-end)
                    (re-search-forward (%c-langvar 'c-cpp-include-key)
                                       search-end 'bound)
                    (begin (set! hash-pos (match-beginning 0)) hash-pos))
          (c-forward-comments (c-point 'eoll))
          (when (and (< (point) search-end)
                     (looking-at "\\(<\\)[^>\n\r]*\\(>\\)")
                     (null? (cdr (c-semi-pp-to-literal (match-beginning 0)))))
            (c-mark-<-as-paren (match-beginning 1))
            (when (< hash-pos (c-new-BEG)) (set!c-new-BEG hash-pos))
            (c-mark->-as-paren (match-beginning 2))
            (when (> (match-end 2) (c-new-END))
              (set!c-new-END (match-end 2)))))))

    ;; ---------------------------------------------------------------
    ;; `c-before-change-fix-comment-escapes' and
    ;; `c-after-change-fix-comment-escapes' (`cc-mode.el:2093', `:2112')
    ;;--------------------------------------------------------------
    (define (c-before-change-fix-comment-escapes beg end)
      ;; "Remove punctuation syntax-table text properties from C/C++
      ;; comment markers. This is to handle the rare case of two or more
      ;; backslashes at an end of line in a // comment or the equally
      ;; rare case of a backslash preceding the terminator of a /*
      ;; comment, as \\*/."
      (c-save-buffer-state
          ((end-state #f))
        (set! end-state (c-full-pp-to-literal end))
        (when (memv (%c-cadr end-state) '(c c++))
          (goto-char (max (- beg 2) (point-min)))
          (if (eq? (%c-cadr end-state) 'c)
              (when (search-forward "\\*/"
                                    (or (%c-cdr (%c-caddr end-state)) (point-max)) #t)
                (c-clear-syntax-table-trim-caches (match-beginning 0)))
              (let loop ()
                (when (search-forward "\\\\\n"
                                      (or (%c-cdr (%c-caddr end-state)) (point-max))
                                      #t)
                  (c-clear-syntax-table-trim-caches (match-beginning 0))
                  (loop)))))))

    (define (c-after-change-fix-comment-escapes beg end old-len)
      ;; "Apply punctuation syntax-table text properties to C/C++ comment
      ;; markers. ... Note that the function currently only handles
      ;; comments beginning with // and /*, not more generic line and
      ;; block comments."
      (c-save-buffer-state
          ((state #f))
        ;; "We cannot use `c-full-pp-to-literal' in this function, since
        ;; the `syntax-table' text properties after point are not yet in
        ;; a consistent state."
        (set! state (c-semi-pp-to-literal beg))
        (goto-char (if (memv (%c-cadr state) '(c c++))
                       (%c-caddr state)
                       (max (- beg 2) (point-min))))
        (while-e (re-search-forward "\\\\\\(\\(\\\\\n\\)\\|\\(\\*/\\)\\)"
                                  (min (+ end 2) (point-max)) #t)
          (set! state (c-semi-pp-to-literal (match-beginning 0)))
          (when (cond
                 ((eq? (%c-cadr state) 'c)
                  (match-beginning 3))
                 ((eq? (%c-cadr state) 'c++)
                  (match-beginning 2)))
            (c-put-syntax-table-trim-caches (match-beginning 0) '(1))))

        (goto-char end)
        (set! state (c-semi-pp-to-literal (point)))
        (cond
         ((eq? (%c-cadr state) 'c)
          (when (search-forward "*/" #f #t)
            (when (eqv? (char-before (match-beginning 0)) #\\)
              (c-put-syntax-table-trim-caches
               (- (match-beginning 0) 1) '(1)))))
         ((eq? (%c-cadr state) 'c++)
          (let loop ()
            (when (begin
                    (end-of-line)
                    (and (eqv? (char-before) #\\)
                         (begin
                           (when (eqv? (char-before (- (point) 1)) #\\)
                             (c-put-syntax-table-trim-caches
                              (- (point) 2) '(1)))
                           #t)
                         (not (eobp))))
              (forward-char)
              (loop)))))))

    ;; ---------------------------------------------------------------
    ;; The property-change test and the CPP propertizers
    ;; (`cc-mode.el:997'-`:1260')
    ;;--------------------------------------------------------------
    (define (c-called-from-text-property-change-p)
      ;; "Is the primitive which invoked `before-change-functions' or
      ;; `after-change-functions' one which merely changes text
      ;; properties? This function must be called directly from a member
      ;; of one of the above hooks."
      ;;
      ;; Emacs asks `(cadr (backtrace-frame 3))'. Guile has no
      ;; `backtrace-frame', so `textprop.scm''s `modify-text-properties'
      ;; binds `*in-property-change-p*' around the
      ;; `prepare_to_modify_buffer_1' that raises the change hooks - the
      ;; one place the property primitives reach them.
      (*in-property-change-p*))

    (define (c-locate-first-punctuation-prop beg)
      ;; "Scan the region (BEG (point)) for `syntax-table' punctuation
      ;; text properties, returning the position of the first found, or
      ;; nil. Point is unchanged."
      (let ((end (point)))
        (goto-char beg)
        (prog1
            (if (c-search-forward-char-property 'syntax-table '(1) end)
                (match-beginning 0)
                #f)
          (goto-char end))))

    (define (c-depropertize-CPP beg end)
      ;; "Remove the punctuation syntax-table text property from the CPP
      ;; parts of (c-new-BEG c-new-END), and remove all syntax-table
      ;; properties from any raw strings within these CPP parts.
      ;;
      ;; This function is in the C/C++/ObjC values of
      ;; `c-get-state-before-change-functions' and is called exclusively
      ;; as a before change function."
      (c-save-buffer-state
       ((m-beg #f) (ss-found #f))
       (goto-char (c-new-BEG))
       (while (and (< (point) beg)
                   (re-search-forward (%c-langvar 'c-anchored-cpp-prefix)
                                      beg 'bound))
         (goto-char (match-beginning 1))
         (set! m-beg (point))
         (c-end-of-macro)
         (when (%c-langvar 'c-ml-string-opener-re)
           (save-excursion
             (c-depropertize-ml-strings-in-region m-beg (point))))
         (c-clear-syntax-table-with-value-trim-caches m-beg (point) '(1)))

       (while (and (< (point) end)
                   (begin
                     (set! ss-found
                           (re-search-forward (%c-langvar 'c-anchored-cpp-prefix)
                                              end 'bound))
                     ss-found))
         (goto-char (match-beginning 1))
         (set! m-beg (point))
         (c-end-of-macro)
         (c-truncate-lit-pos/state-cache
          (or (c-locate-first-punctuation-prop m-beg) (point-max))))

       (when (and ss-found (> (point) end))
         (when (%c-langvar 'c-ml-string-opener-re)
           (save-excursion
             (c-depropertize-ml-strings-in-region m-beg (point))))
         (c-clear-syntax-table-with-value-trim-caches m-beg (point) '(1)))

       (while (and (< (point) (c-new-END))
                   (re-search-forward (%c-langvar 'c-anchored-cpp-prefix)
                                      (c-new-END) 'bound))
         (goto-char (match-beginning 1))
         (set! m-beg (point))
         (c-end-of-macro)
         (c-truncate-lit-pos/state-cache
          (or (c-locate-first-punctuation-prop m-beg) (point-max)))
         (when (%c-langvar 'c-ml-string-opener-re)
           (save-excursion
             (c-depropertize-ml-strings-in-region m-beg (point))))
         (c-clear-syntax-table-with-value-trim-caches m-beg (point) '(1)))))

    (define (c-extend-region-for-CPP beg end)
      ;; "Adjust `c-new-BEG', `c-new-END' respectively to the beginning
      ;; and end of any preprocessor construct they may be in.
      ;;
      ;; Point is undefined both before and after this function call; the
      ;; buffer has already been widened, and match-data saved. The
      ;; return value is meaningless.
      ;;
      ;; This function is in the C/C++/ObjC values of
      ;; `c-get-state-before-change-functions' and is called exclusively
      ;; as a before change function."
      (goto-char (c-new-BEG))
      (c-beginning-of-macro)
      (when (< (point) (c-new-BEG))
        (set!c-new-BEG (max (point) (c-determine-limit 500 (c-new-BEG)))))

      (goto-char (c-new-END))
      (when (c-beginning-of-macro)
        (c-end-of-macro)
        (or (eobp) (forward-char)))     ; "Over the terminating NL which may be
                                        ; marked with a c-cpp-delimiter
                                        ; category property"
      (when (> (point) (c-new-END))
        (set!c-new-END
         (min (point) (c-determine-+ve-limit 500 (c-new-END))))))

    (define (c-depropertize-new-text beg end old-len)
      ;; "Remove from the new text in (BEG END) any and all text
      ;; properties which might interfere with CC Mode's proper working.
      ;;
      ;; This function is called exclusively as an after-change function.
      ;; It appears in the value (for all languages) of
      ;; `c-before-font-lock-functions'. ..."
      (c-save-buffer-state
       ()
       (when (> end beg)
         (c-clear-char-properties beg end 'syntax-table)
         (c-clear-char-properties beg end 'c-fl-syn-tab)
         (c-clear-char-properties beg end 'category)
         (c-clear-char-properties beg end 'c-is-sws)
         (c-clear-char-properties beg end 'c-in-sws)
         (c-clear-char-properties beg end 'c-type)
         (c-clear-char-properties beg end 'c-awk-NL-prop))))

    (define (c-extend-font-lock-region-for-macros begg endd old-len)
      ;; "Extend the region (c-new-BEG c-new-END) to cover all (possibly
      ;; changed) preprocessor macros; The return value has no
      ;; significance.
      ;;
      ;; Point is undefined on both entry and exit to this function. The
      ;; buffer will have been widened on entry.
      ;;
      ;; c-new-BEG has already been extended in `c-extend-region-for-CPP'
      ;; so we don't need to repeat the exercise here.
      ;;
      ;; This function is in the C/C++/ObjC value of
      ;; `c-before-font-lock-functions'."
      (goto-char endd)
      (when (c-beginning-of-macro)
        (c-end-of-macro)
        ;; "Determine the region, (c-new-BEG c-new-END), which will get
        ;; font locked. This restricts the region should there be long
        ;; macros."
        (set!c-new-END
         (min (max (c-new-END) (point))
              (c-determine-+ve-limit 500 (c-new-END))))))

    (define (c-neutralize-CPP-line beg end)
      ;; "BEG and END bound a region, typically a preprocessor line. Put
      ;; a \"punctuation\" syntax-table property on syntactically
      ;; obtrusive characters, ones which would interact syntactically
      ;; with stuff outside this region.
      ;;
      ;; These are unmatched parens/brackets/braces. An unclosed comment
      ;; is regarded as valid, NOT obtrusive. Unbalanced strings are
      ;; handled elsewhere."
      (save-excursion
        (let ((s #f))
          (while
              (begin
                (set! s (parse-partial-sexp beg end -1))
                (cond
                 ((< (list-ref s 0) 0)  ; "found an unmated ),},],>"
                  (if (eqv? (char-before) #\>)
                      (c-clear->-pair-props (- (point) 1))
                      (c-put-syntax-table-trim-caches (- (point) 1) '(1)))
                  #t)
                 ;; "Unbalanced strings are now handled by
                 ;; `c-before-change-check-unbalanced-strings', etc."
                 ((> (list-ref s 0) 0)  ; "In a (,{,[,<"
                  (if (eqv? (char-after (list-ref s 1)) #\<)
                      (c-clear-<-pair-props (list-ref s 1))
                      (c-put-syntax-table-trim-caches (list-ref s 1) '(1)))
                  #t)
                 (else #f)))))))

    (define (c-neutralize-syntax-in-CPP begg endd old-len)
      ;; "\"Neutralize\" every preprocessor line wholly or partially in
      ;; the changed region. \"Restore\" lines which were CPP lines
      ;; before the change and are no longer so.
      ;;
      ;; That is, set syntax-table properties on characters that would
      ;; otherwise interact syntactically with those outside the CPP
      ;; line(s).
      ;;
      ;; This function is called from an after-change function, BEGG ENDD
      ;; and OLD-LEN being the standard parameters. It prepares the
      ;; buffer for font locking, hence must get called before
      ;; `font-lock-after-change-function'.
      ;;
      ;; Point is undefined both before and after this function call, the
      ;; buffer will have been widened, and match-data saved. The return
      ;; value is ignored. ..."
      ;;
      ;; "Note: SPEED _MATTERS_ IN THIS FUNCTION!!!"
      (c-save-buffer-state
       ((limits #f))
       ;; "Add needed properties to each CPP construct in the region."
       (goto-char (c-new-BEG))
       (if (begin (set! limits (c-literal-limits)) limits)
           (goto-char (cdr limits)))    ; "Go past any literal."
       (skip-chars-backward " \t")
       (let ((pps-position (point)) (pps-state #f) (mbeg #f))
         (while (and (< (point) (c-new-END))
                     (re-search-forward (%c-langvar 'c-anchored-cpp-prefix)
                                        (c-new-END) #t))
           ;; "If we've found a \"#\" inside a macro/string/comment,
           ;; ignore it."
           (unless
               (or (save-excursion
                     (goto-char (match-beginning 0))
                     (let ((here (point)))
                       (and (save-match-data (c-beginning-of-macro))
                            (< (point) here))))
                   (begin
                     (set! pps-state
                           (parse-partial-sexp pps-position (point)
                                               #f #f pps-state))
                     (set! pps-position (point))
                     (or (list-ref pps-state 3) ; "in a string?"
                         (and (list-ref pps-state 4)
                              (not (eq? (list-ref pps-state 7)
                                        'syntax-table)))))) ; "in a comment?"
             (goto-char (match-beginning 1))
             (set! mbeg (point))
             (if (> (c-no-comment-end-of-macro) mbeg)
                 (c-neutralize-CPP-line mbeg (point)) ; "\"punctuation\""
                 (forward-line))))))                 ; "no infinite loop with, e.g., \"#//\""
)

    (define (c-before-change beg end)
      ;; "Function to be put on `before-change-functions'. Primarily,
      ;; this calls the language dependent
      ;; `c-get-state-before-change-functions'. It is otherwise used
      ;; only to remove stale entries from the `c-found-types' cache,
      ;; and to record entries which a `c-after-change' function might
      ;; confirm as stale.
      ;;
      ;; Note that this function must be FAST rather than accurate. Note
      ;; also that it only has any effect when font locking is enabled.
      ;; We exploit this by checking for font-lock-*-face instead of
      ;; doing rigorous syntactic analysis."
      ;;
      ;; "If either change boundary is wholly inside an identifier,
      ;; delete it/them from the cache. Don't worry about being inside a
      ;; string or a comment - \"wrongly\" removing a symbol from
      ;; `c-found-types' isn't critical."
      (unless (c-called-from-text-property-change-p)
        (c-with-string-fences
         (save-restriction
           (widen)
           ;; "Clear the list of found types if we make a change at the
           ;; start of the buffer, to make it easier to get rid of
           ;; misspelled types and variables that have gotten recognized
           ;; as types in malformed code."
           (when (= beg (point-min))
             (c-clear-found-types))
           (if (c-just-done-before-change)
               ;; "We have two consecutive calls to
               ;; `before-change-functions' without an intervening
               ;; `after-change-functions'. ... To protect CC Mode,
               ;; assume that the entire buffer has changed."
               (begin
                 (set! beg (point-min))
                 (set! end (point-max))
                 (set!c-just-done-before-change 'whole-buffer))
               (set!c-just-done-before-change #t))
           ;; "`(c-new-BEG c-new-END)' will be the region to fontify."
           (set!c-new-BEG beg) (set!c-new-END end)
           (set!c-maybe-stale-found-type #f)
           (set!c-open-string-opener #f)
           ;; "A workaround for syntax-ppss's failure to notice
           ;; syntax-table text property changes."
           (set!c-syntax-table-hwm most-positive-fixnum)
           (save-match-data
            (save-excursion
              ;; "Are we inserting/deleting stuff in the middle of an
              ;; identifier?"
              (c-unfind-enclosing-token beg)
              (c-unfind-enclosing-token end)
              ;; "Are we coalescing two tokens together, e.g. \"fo o\"
              ;; -> \"foo\"?"
              (when (< beg end)
                (c-unfind-coalesced-tokens beg end))
              (c-invalidate-sws-region-before beg end)
              ;; "Are we (potentially) disrupting the syntactic context
              ;; which makes a type a type? ..."
              (let ((lim #f) (lim-2 #f) (type #f) (type-pos #f)
                    (marked-id #f) (term-pos #f)
                    (end1
                     (or (and (eq? (get-text-property end 'face)
                                   'font-lock-comment-face)
                              (c-previous-single-property-change end 'face))
                         end)))
                (when (>= end1 beg) ; "Don't hassle about changes entirely
                                    ; in comments."
                  ;; "Find a limit for the search for a `c-type'
                  ;; property. Point is currently undefined. A
                  ;; `goto-char' somewhere is needed. (2020-12-06)."
                  (set! lim-2 (c-determine-limit 1000 (point)))
                  (while
                   (and (/= (skip-chars-backward "^;{}" lim-2) 0)
                        (> (point) (point-min))
                        (memv (c-get-char-property (- (point) 1) 'face)
                              (list 'font-lock-comment-face
                                    'font-lock-string-face))))
                  (set! lim (max (point-min) (- (point) 1)))

                  ;; "Look for the latest `c-type' property before end1"
                  (when (and (> end1 (point-min))
                             (begin
                               (set! type-pos
                                     (if (get-text-property (- end1 1) 'c-type)
                                         end1
                                         (c-previous-single-property-change
                                          end1 'c-type #f lim)))
                               type-pos))
                    (set! type
                          (get-text-property (max (- type-pos 1) lim) 'c-type))

                    (when (memv type '(c-decl-id-start c-decl-type-start))
                      ;; "Get the identifier, if any, that the property
                      ;; is on."
                      (goto-char (- type-pos 1))
                      (set! marked-id
                            (when-e (looking-at "\\(\\sw\\|\\s_\\)")
                              (c-beginning-of-current-token)
                              (buffer-substring-no-properties (point)
                                                              type-pos)))

                      (goto-char end1)
                      (set! lim-2 (c-determine-+ve-limit 1000))
                      (skip-chars-forward "^;{}" lim-2) ; "FIXME!!! loop for
                                                        ; comment, maybe"
                      (set! lim (point))
                      (set! term-pos
                            (or (c-next-single-property-change end 'c-type
                                                               #f lim)
                                lim))
                      (set!c-maybe-stale-found-type
                       (list type marked-id type-pos term-pos
                             (buffer-substring-no-properties type-pos term-pos)
                             (buffer-substring-no-properties beg end)))))))

              ;; "If we're about to delete \"typedef\"s, clear the
              ;; identifiers from `c-found-types'."
              (c-before-change-de-typedef beg end)

              (let ((fns (%c-langvar 'c-get-state-before-change-functions)))
                (when (pair? fns)
                  (for-each (lambda (fn)
                              ((%c-lang-function fn) beg end))
                            fns)))

              (c-laomib-invalidate-cache beg end))))
         (c-truncate-lit-pos/state-cache beg)
         ;; "The following must be done here rather than in
         ;; `c-after-change' because newly inserted parens would foul up
         ;; the invalidation algorithm."
         (c-invalidate-state-cache)
         ;; "The following must happen after the previous, which likely
         ;; alters the macro cache."
         (when (%c-langvar 'c-opt-cpp-symbol)
           (c-invalidate-macro-cache beg end))
         (set!c-no-bracelist-cache
          (c-whack-state-after beg (c-no-bracelist-cache))))))

    ;; ---------------------------------------------------------------
    ;; `c-doc-fl-decl-start'/`-end', `c-fl-decl-start'/`-end' and
    ;; `c-change-expand-fl-region' (`cc-mode.el:2448'-`:2665')
    ;;--------------------------------------------------------------
    (define (c-doc-fl-decl-start pos)
      ;; "If the line containing POS is in a doc comment continued line
      ;; (as defined by `c-doc-line-join-re'), return the position of the
      ;; first line of the sequence. Otherwise, return nil. Point has no
      ;; significance at entry to and exit from this function."
      (when-e (not (equal? (c-doc-line-join-re) regexp-unmatchable))
        (goto-char pos)
        (back-to-indentation)
        (and (or (looking-at (%c-langvar 'c-comment-start-regexp))
                 (memv (c-literal-type (c-literal-limits)) (list 'c 'c++)))
             (begin
               (end-of-line)
               (let ((here (point)))
                 (let loop ()
                   (when (re-search-backward (c-doc-line-join-re)
                                             (c-point 'bopl) #t)
                     (loop)))
                 (and (not (eqv? (point) here))
                      (c-point 'bol)))))))

    (define (c-doc-fl-decl-end pos)
      ;; "If the line containing POS is continued by a doc comment
      ;; continuation marker (as defined by `c-doc-line-join-re'), return
      ;; the position of the BOL at the end of the sequence. Otherwise,
      ;; return nil. Point has no significance at entry to and exit from
      ;; this function."
      (when-e (not (equal? (c-doc-line-join-re) regexp-unmatchable))
        (goto-char pos)
        (back-to-indentation)
        (let ((here (point)))
          (let loop ()
            (when (re-search-forward (c-doc-line-join-re) (c-point 'eonl) #t)
              (loop)))
          (and (not (eqv? (point) here))
               (c-point 'bonl)))))

    (define (c-fl-decl-start pos)
      ;; "If the beginning of the line containing POS is in the middle of
      ;; a \"local\" declaration, return the beginning of that
      ;; declaration. Otherwise return nil. Note that declarations, in
      ;; this sense, can be nested. (A local declaration is one which does
      ;; not start outside of struct braces (and similar) enclosing POS.
      ;; Brace list braces here are not \"similar\".
      ;;
      ;; POS being in a literal does not count as being in a declaration
      ;; (on pragmatic grounds).
      ;;
      ;; This function is called indirectly from font locking stuff -
      ;; either from c-after-change (to prepare for after-change
      ;; font-locking) or from font lock context (etc.) fontification."
      (goto-char pos)
      (or (and (c-major-mode-is 'objc-mode)
               (c-beginning-of-objc-method-header)
               (point))
          (let ((lit-start (c-literal-start))
                (old-pos #f)
                (new-pos pos)
                (capture-opener #f)
                (bod-lim #f) (bo-decl #f)
                (paren-state #f) (containing-brace #f))
            (goto-char (c-point 'bol new-pos))
            (unless-e lit-start
              (set! bod-lim (c-determine-limit 500))

              ;; "In C++ Mode, first check if we are within a (possibly
              ;; nested) lambda form capture list."
              (when (c-major-mode-is 'c++-mode)
                (save-excursion
                  (while (and (c-go-up-list-backward #f bod-lim)
                              (c-looking-at-c++-lambda-capture-list))
                    (set! capture-opener (point)))))

              (let loop ()
                (when
                    (and
                     (begin (set! old-pos (point)) old-pos)
                     ;; "The following form tries to move to the end of
                     ;; the previous declaration without moving outside of
                     ;; an enclosing {."
                     (let ((pseudo #f))
                       (let inner ()
                         (when (and
                                ;; "N.B. `c-syntactic-skip-backward'
                                ;; doesn't check (> (point) lim) and can
                                ;; loop if that's not the case."
                                (> (point) bod-lim)
                                (begin
                                  (c-syntactic-skip-backward "^;{}" bod-lim #t)
                                  (and (eqv? (char-before) #\})
                                       (save-excursion
                                         (backward-char)
                                         (begin
                                           (set! pseudo
                                                 (c-cheap-inside-bracelist-p
                                                  (c-parse-state)))
                                           pseudo)))))
                           (goto-char pseudo)
                           (inner)))
                       (or pseudo (bobp) (> (point) bod-lim)))
                     ;; "Move forward to the start of the next
                     ;; declaration."
                     (begin
                       (c-forward-syntactic-ws)
                       ;; "Have we got stuck in a comment at EOB?"
                       (not (and (eobp) (c-literal-start))))
                     (< (point) old-pos)
                     (begin
                       (set! bo-decl (point))
                       (or (not (looking-at (%c-langvar 'c-protection-key)))
                           (c-forward-keyword-clause 1)))
                     (begin
                       ;; "Are we looking at a keyword such as \"template\"
                       ;; or \"typedef\" which can decorate a type, or the
                       ;; type itself?"
                       (when (or (looking-at (%c-langvar 'c-prefix-spec-kwds-re))
                                 (c-forward-type #t))
                         ;; "We've found another candidate position."
                         (set! new-pos (min new-pos bo-decl))
                         (goto-char bo-decl))
                       #t)
                     ;; "Try and go out a level to search again."
                     (begin
                       (c-backward-syntactic-ws bod-lim)
                       (and (> (point) bod-lim)
                            (or (memv (char-before) (list #\( #\[))
                                (and (eqv? (char-before) #\<)
                                     (equal? (c-get-char-property
                                              (- (point) 1) 'syntax-table)
                                             c-<-as-paren-syntax))
                                (and (eqv? (char-before) #\{)
                                     (save-excursion
                                       (backward-char)
                                       (set! paren-state (c-parse-state))
                                       (let inner2 ()
                                         (when (and
                                                (begin
                                                  (set! containing-brace
                                                        (c-pull-open-brace
                                                         paren-state))
                                                  containing-brace)
                                                (not (eqv? (char-after
                                                            containing-brace)
                                                           #\{)))
                                           (inner2)))
                                       (pair? (c-looking-at-or-maybe-in-bracelist
                                               containing-brace
                                               containing-brace)))))))
                     (not (bobp)))
                  (backward-char)       ; "back over (, [, <."
                  (loop)))

              (when (and capture-opener (< capture-opener new-pos))
                (set! new-pos capture-opener))
              (and (/= new-pos pos) new-pos)))))

    (define (c-fl-decl-end pos)
      ;; "If POS is inside a declarator, return the position of the end
      ;; of the paren pair that terminates it, or of the end of the token
      ;; that follows the declarator, otherwise return nil. If there is
      ;; no such token, the end of the last token in the buffer is used.
      ;; POS being in a literal is now (2022-07) handled correctly. POINT
      ;; is not preserved."
      (goto-char pos)
      (let ((lit-start (c-literal-start))
            (lim (c-determine-limit 1000))
            (enclosing-attribute #f) (pos1 #f) (ml-delim #f))
        (if lit-start
            (goto-char lit-start))
        (when (and lit-start (%c-langvar 'c-ml-string-opener-re)
                   (begin
                     (set! ml-delim (c-ml-string-opener-around-point))
                     ml-delim))
          (goto-char (car ml-delim)))
        (c-backward-syntactic-ws lim)
        (when (begin
                (set! enclosing-attribute (c-enclosing-c++-attribute))
                enclosing-attribute)
          (goto-char (car enclosing-attribute))
          ;; "Only happens in C or C++ Mode."
          (c-backward-syntactic-ws lim))
        (while (and (> (point) lim)
                    (memv (char-before) (list #\[ #\()))
          (backward-char)
          (c-backward-syntactic-ws lim))
        (when-e (begin (set! pos1 (c-on-identifier)) pos1)
          (goto-char pos1)
          (let* ((lim1 (save-excursion
                         (and (c-beginning-of-macro)
                              (begin (c-end-of-macro) (point)))))
                 (lim+ (c-determine-+ve-limit 200))
                 (decl-res (c-forward-declarator lim+)))
            ;; The `(and (>= (point) pos) (point))' is the let*'s last
            ;; form in Emacs - a sibling of this `if', not its third arm.
            (begin
             (if (or (%c-cadr (%c-cddr (%c-cddr decl-res))) ; "We scanned an
                                                             ; arglist."
                     (and (eqv? (char-after) #\() ; "Move over a non arglist
                                                   ; (...)."
                          (prog1 (c-go-list-forward)
                            (c-forward-syntactic-ws))))
                 (if (looking-at (%c-langvar 'c-symbol-char-key))
                    ;; "Deal with baz (foo((bar)) type var), where `pos'
                    ;; was inside foo, but foo((bar)) is not semantically
                    ;; valid. The result must be after var)."
                    (and
                     (goto-char pos)
                     (begin (set! pos1 (c-on-identifier)) pos1)
                     (goto-char pos1)
                     (begin
                       (c-backward-syntactic-ws lim1)
                       (eqv? (char-before) #\())
                     (c-fl-decl-end (- (point) 1)))
                    (begin
                      (c-forward-over-token #f lim+) ; "The , or ) after
                                                     ; the declarator."
                      (point)))
                (if (begin (c-forward-syntactic-ws)
                           (not (eobp)))
                    (begin
                      (c-forward-over-token)
                      ;; "Cope with having POS within a syntactically
                      ;; invalid (...), by moving backward out of the
                      ;; parens and trying again."
                      (when (and (eqv? (char-before) #\))
                                 (c-go-list-backward (point) lim1))
                        (c-fl-decl-end (point))))
                    (let ((lit-start (c-literal-start)))
                      (when lit-start
                        (goto-char lit-start))
                      (c-backward-syntactic-ws))))
             (and (>= (point) pos) (point)))))))

    (define (c-change-expand-fl-region beg end old-len)
      ;; "Expand the region (c-new-BEG c-new-END) to an after-change
      ;; font-lock region. This will usually be the smallest sequence of
      ;; whole lines containing `c-new-BEG' and `c-new-END', but if
      ;; `c-new-BEG' is in a \"local\" declaration (see
      ;; `c-fl-decl-start') the beginning of this is used as the lower
      ;; bound.
      ;;
      ;; This is called from an after-change-function, but the
      ;; parameters BEG END and OLD-LEN are not used."
      (if (font-lock-mode-on?)
          (begin
            (set!c-new-BEG
             (or (c-fl-decl-start (c-new-BEG))
                 (c-doc-fl-decl-start (c-new-BEG))
                 (c-point 'bol (c-new-BEG))))
            (set!c-new-END
             (or (c-fl-decl-end (c-new-END))
                 (c-doc-fl-decl-end (c-new-END))
                 (c-point 'bonl (c-new-END)))))
          #f))

    ;; ---------------------------------------------------------------
    ;; `c-after-change' (`cc-mode.el:2364')
    ;;--------------------------------------------------------------
    ;; `c-in-after-change-fontification' is a `defvar'
    ;; + `make-variable-buffer-local' in Emacs - a buffer-local flag, so
    ;; the tree's accessor pair.
    (define (c-in-after-change-fontification)
      (buffer-local-value (current-buffer) 'c-in-after-change-fontification #f))
    (define (set!c-in-after-change-fontification value)
      (set-buffer-local-value! (current-buffer)
                               'c-in-after-change-fontification value))

    (define (c-after-change beg end old-len)
      ;; "Function put on `after-change-functions' to adjust various
      ;; caches etc. Prefer speed to finesse here, since there will be an
      ;; order of magnitude more calls to this function than any of the
      ;; functions that use the caches.
      ;;
      ;; Note that care must be taken so that this is called before any
      ;; font-lock callbacks since we might get calls to functions using
      ;; these caches from inside them, and we must thus be sure that this
      ;; has already been executed.
      ;;
      ;; This calls the language variable
      ;; c-before-font-lock-functions, if non-nil. This typically sets
      ;; `syntax-table' properties."
      ;;
      ;; "We can sometimes get two consecutive calls to
      ;; `after-change-functions' without an intervening call to
      ;; `before-change-functions' when reverting the buffer (see bug
      ;; #24094). Whatever the cause, assume that the entire buffer has
      ;; changed."
      ;;
      ;; "Note: c-just-done-before-change is nil, t, or 'whole-buffer."
      (unless (c-called-from-text-property-change-p)
        (unless (eq? (c-just-done-before-change) #t)
          (save-restriction
            (widen)
            (when (not (c-just-done-before-change))
              (c-before-change (point-min) (point-max)))
            (set! beg (point-min))
            (set! end (point-max))
            (set! old-len (- end beg))
            (set!c-new-BEG (point-min))
            (set!c-new-END (point-max)))))

      ;; "`(c-new-BEG c-new-END)' will be the region to fontify. It may
      ;; become larger than (beg end)."
      (set!c-new-END (- (+ (c-new-END) (- end beg)) old-len))

      (unless (c-called-from-text-property-change-p)
        (set!c-just-done-before-change #f)
        (c-save-buffer-state
         ()
         (parameterize ((*case-fold-search* #f))
          (save-restriction
            (save-match-data  ; "c-recognize-<>-arglists changes
                              ; match-data"
             (widen)
             (c-with-string-fences
              (when (> end (point-max))
                ;; "Some emacsen might return positions past the end. ...
                ;; Emacs 21.3 appears to work."
                (set! end (point-max))
                (when (> beg end)
                  (set! beg end)))

              ;; "C-y is capable of spuriously converting category
              ;; properties c-</>-as-paren-syntax and c-cpp-delimiter
              ;; into hard syntax-table properties. Remove these when it
              ;; happens."
              (c-save-buffer-state
               ()
               (c-clear-char-property-with-value beg end 'syntax-table
                                                 c-<-as-paren-syntax)
               (c-clear-char-property-with-value beg end 'syntax-table
                                                 c->-as-paren-syntax)
               (c-clear-char-property-with-value beg end 'syntax-table #f))

              (c-update-new-id end)
              (c-trim-found-types beg end old-len) ; "maybe we don't
                                                   ; need all of these."
              (c-after-change-de-typedef beg end old-len)
              (c-invalidate-sws-region-after beg end old-len)
              ;; "(c-invalidate-state-cache beg) ; moved to
              ;; `c-before-change'."
              (c-invalidate-find-decl-cache beg)

              (when (%c-langvar 'c-recognize-<>-arglists)
                (c-after-change-check-<>-operators beg end))

              (set!c-in-after-change-fontification #t)
              (save-excursion
                (let ((fns (%c-langvar 'c-before-font-lock-functions)))
                  (when (pair? fns)
                    (for-each (lambda (fn)
                                ((%c-lang-function fn) beg end old-len))
                              fns)))))))
          ;; "A workaround for syntax-ppss's failure to notice
          ;; syntax-table text property changes."
          ;; `c-syntax-table-hwm' is a plain variable (a `defvar' Emacs
          ;; never `let'-binds), not a parameter: passing `(c-syntax-table-hwm)'
          ;; would *apply* a number.
          (syntax-ppss-flush-cache c-syntax-table-hwm)))))

    ;; ---------------------------------------------------------------
    ;; `c-with-string-fences'` seams (`cc-defs.el:1774')
    ;; ---------------------------------------------------------------
    ;; `cc-defs' is below this library and cannot reach these two, so it
    ;; reads them through parameters; install them as this library loads,
    ;; as `keyboard.scm' installs its seam.
    (*c-restore-string-fences-function* c-restore-string-fences)
    (*c-clear-syn-tab-properties-function* %c-clear-syn-tab-properties-full)
    (*c-clear-string-fences-function* c-clear-string-fences)
    ;; `c-before-change-check-ml-strings' /
    ;; `c-after-change-unmark-ml-strings' are cc-engine's and reach this
    ;; library's remover through the parameter.
    (*c-remove-string-fences-function* c-remove-string-fences)

    ;; The `cc-mode' members of `c-get-state-before-change-functions'
    ;; and `c-before-font-lock-functions' (see
    ;; `c-register-lang-function!').
    (c-register-lang-function! 'c-before-change-include-<>
                               c-before-change-include-<>)
    (c-register-lang-function! 'c-before-change-check-unbalanced-strings
                               c-before-change-check-unbalanced-strings)
    (c-register-lang-function! 'c-parse-quotes-before-change
                               c-parse-quotes-before-change)
    (c-register-lang-function! 'c-before-change-fix-comment-escapes
                               c-before-change-fix-comment-escapes)
    (c-register-lang-function! 'c-depropertize-new-text
                               c-depropertize-new-text)
    (c-register-lang-function! 'c-after-change-mark-abnormal-strings
                               c-after-change-mark-abnormal-strings)
    (c-register-lang-function! 'c-after-change-escape-NL-in-string
                               c-after-change-escape-NL-in-string)
    (c-register-lang-function! 'c-after-change-include-<>
                               c-after-change-include-<>)
    (c-register-lang-function! 'c-after-change-fix-comment-escapes
                               c-after-change-fix-comment-escapes)
    (c-register-lang-function! 'c-parse-quotes-after-change
                               c-parse-quotes-after-change)
    (c-register-lang-function! 'c-extend-region-for-CPP
                               c-extend-region-for-CPP)
    (c-register-lang-function! 'c-depropertize-CPP c-depropertize-CPP)
    (c-register-lang-function! 'c-extend-font-lock-region-for-macros
                               c-extend-font-lock-region-for-macros)
    (c-register-lang-function! 'c-neutralize-syntax-in-CPP
                               c-neutralize-syntax-in-CPP)
    (c-register-lang-function! 'c-change-expand-fl-region
                               c-change-expand-fl-region)

        ;;==================================================================
    ;; The mode setup (`cc-mode.el:170'-`:930', `:2211', `:2752').
    ;;
    ;; This file was ported change-machinery first (the sections above
    ;; are `cc-mode.el:503' onwards); the setup half is here, at the
    ;; end, in Emacs's own order among itself. The pieces Emacs's
    ;; `c-initialize-cc-mode' and `c-basic-common-init' name but this
    ;; tree has not got are called out at their sites:
    ;; `normal-erase-is-backspace' (no such variable here),
    ;; `editorconfig-indent-size-vars', `yank-handled-properties',
    ;; hideshow's three regexp variables (set anyway - they are data a
    ;; ported hideshow can read), `cc-subword.el''s `c-subword-mode'
    ;; (subword.el here; its `c-subword-mode' is that file's obsolete
    ;; alias, so nothing in cc-mode calls it) and `reporter.el''s
    ;; `c-submit-bug-report'. `c-macro-expand' IS carried now - the
    ;; bindings name it as a symbol and `command.scm`'s autoload table
    ;; loads `cmacexp' at the first lookup.
    ;;==================================================================

    ;;------------------------------------------------------------------
    ;; `c-leave-cc-mode-mode' (`cc-mode.el:178')
    ;;------------------------------------------------------------------
    (define (c-leave-cc-mode-mode)
      (when (*c-buffer-is-cc-mode*)
        (save-restriction
          (widen)
          (let ((lst (buffer-list)))
            (call-with-current-continuation
             (lambda (found)
               (for-each
                (lambda (b)
                  (if (and (not (eq? b (current-buffer)))
                           (with-current-buffer b (*c-buffer-is-cc-mode*)))
                      (found #f)))
                lst)
               (remove-hook *post-command-hook* c-post-command #t))))
          (c-save-buffer-state
           ()
           (c-clear-char-properties (point-min) (point-max) 'category)
           (c-clear-char-properties (point-min) (point-max) 'syntax-table)
           (c-clear-char-properties (point-min) (point-max) 'c-fl-syn-tab)
           (c-clear-char-properties (point-min) (point-max) 'c-is-sws)
           (c-clear-char-properties (point-min) (point-max) 'c-in-sws)
           (c-clear-char-properties (point-min) (point-max) 'c-type)
           (if (%c-true (%c-langvar 'c-has-quoted-numbers))
               (c-clear-char-properties (point-min) (point-max)
                                        'c-digit-separator))
           (if (c-major-mode-is 'awk-mode)
               (c-clear-char-properties (point-min) (point-max)
                                        'c-awk-NL-prop))))
        (*c-buffer-is-cc-mode* #f)))

    ;;------------------------------------------------------------------
    ;; `c-init-language-vars-for' (`cc-mode.el:201')
    ;;------------------------------------------------------------------
    (define (c-init-language-vars-for mode)
      (cond ((eq? mode 'c-mode) (c-init-language-vars c-mode))
            ((eq? mode 'c++-mode) (c-init-language-vars c++-mode))
            ((eq? mode 'objc-mode) (c-init-language-vars objc-mode))
            ((eq? mode 'java-mode) (c-init-language-vars java-mode))
            ((eq? mode 'idl-mode) (c-init-language-vars idl-mode))
            ((eq? mode 'pike-mode) (c-init-language-vars pike-mode))
            ((eq? mode 'awk-mode) (c-init-language-vars awk-mode))
            (else (error "Unsupported mode ~a" mode))))

    ;;------------------------------------------------------------------
    ;; `c-initialize-cc-mode' (`cc-mode.el:219')
    ;;------------------------------------------------------------------
    (define (c-initialize-cc-mode . rest)
      "Initialize CC Mode for use in the current buffer.
If the optional NEW-STYLE-INIT is nil or left out then all necessary
initialization to run CC Mode for the C language is done.  Otherwise
only some basic setup is done, and a call to `c-init-language-vars' or
`c-init-language-vars-for' is necessary too (which gives more
control).  See \"cc-mode.el\" for more info."
      (let ((new-style-init (and (pair? rest) (car rest))))
        (*c-buffer-is-cc-mode* #t)
        (let ((initprop 'cc-mode-is-initialized)
              (c-initialization-ok #f))
          (unless (get 'c-initialize-cc-mode initprop)
            (dynamic-wind
             (lambda () #f)
             (lambda ()
               (put 'c-initialize-cc-mode initprop #t)
               (c-initialize-builtin-style)
               (run-hooks (*c-initialization-hook*))
               ;; "Fix obsolete variables." `c-comment-continuation-stars'
               ;; is not carried; there is nothing to fix.
               (add-hook *change-major-mode-hook* c-leave-cc-mode-mode)
               ;; "Connect up with Emacs's electric-pair-mode." Emacs does
               ;; this from an `eval-after-load'; `elec-pair.el''s file is
               ;; this library here, so the body runs now. **The check is
               ;; the *global* `c-buffer-is-cc-mode'**, which was just set
               ;; t - Emacs's own quirk, ported as it stands.
               (for-each
                (lambda (buf)
                  (with-current-buffer
                   buf
                   (when (*c-buffer-is-cc-mode*)
                     (set-buffer-local-value! (current-buffer)
                                              'electric-pair-inhibit-predicate
                                              c-electric-pair-inhibit-predicate))))
                (buffer-list))
               (set! c-initialization-ok #t)
               ;; "Connect up with Emacs's electric-indent-mode":
               ;; `electric.scm' is ported, so both hooks are real.
               (add-hook electric-indent-mode-hook c-electric-indent-mode-hook)
               (add-hook electric-indent-local-mode-hook
                         c-electric-indent-local-mode-hook)
               ;; "Setup hideshow variables": hideshow.el is not ported;
               ;; the three are stored as Emacs stores them, so a ported
               ;; hideshow reads the buffer's own values.
               (set-buffer-local-value! (current-buffer) 'hs-block-start-regexp
                                        "\\s(\\|{\\|\"")
               (set-buffer-local-value! (current-buffer) 'hs-block-end-regexp
                                        "\\s)\\|}\\|\"")
               (set-buffer-local-value! (current-buffer) 'hs-c-start-regexp
                                        "/[*/]"))
             ;; "Will try initialization hooks again if they failed."
             (lambda ()
               (put 'c-initialize-cc-mode initprop c-initialization-ok))))
          ;; "Set up text conversion": `post-text-conversion-hook' is not
          ;; ported (there is no text-conversion input path); the
          ;; function it would carry, `c-post-text-conversion', is.
          (unless new-style-init
            (c-init-language-vars-for 'c-mode)))))

    ;;------------------------------------------------------------------
    ;; Common routines: the maps (`cc-mode.el:276'-`:472')
    ;;------------------------------------------------------------------
    (define c-mode-base-map #f)
    ;; ^ "Keymap shared by all CC Mode related modes."

    (define (c-make-inherited-keymap)
      (let ((map (make-sparse-keymap)))
        (c-set-keymap-parent map c-mode-base-map)
        map))

    ;; ---------------------------------------------------------------
    ;; `c-define-abbrev-table' (`cc-mode.el:284') and
    ;; `c-populate-abbrev-table' (`:303')
    ;; ---------------------------------------------------------------
    (define (c-define-abbrev-table name defs . doc)
      ;; "Compatibility wrapper for `define-abbrev' which passes a
      ;; non-nil sixth argument for SYSTEM-FLAG in emacsen that support
      ;; it (currently only Emacs >= 21.2)."
      ;;
      ;; NAME is the table's symbol and DEFS a list of
      ;; `(ABBREV EXPANSION HOOK COUNT)' lists; the T appended to each is
      ;; SYSTEM-FLAG, which our `define-abbrev' takes as the old-style
      ;; second property (`0 T' = `:count 0 :system t').
      (let ((table (or (abbrev-table-named name)
                       (begin
                         (define-abbrev-table name '())
                         (abbrev-table-named name)))))
        (for-each
         (lambda (definition)
           (apply define-abbrev table (append definition (list #t))))
         defs)
        table))

    (define (c-populate-abbrev-table)
      ;; "Insert the standard keywords which may need electric
      ;; indentation into the current mode's abbreviation table."
      ;;
      ;; Emacs names the table `(intern (concat (symbol-name major-mode)
      ;; "-abbrev-table"))'; `abbrev-table-named' is `(symbol-value
      ;; TABLE)' here. `(intern-soft ABBREV TABLE)' is the table's
      ;; abbrev hash - Emacs's obarray - and the membership test is what
      ;; keeps the lookup from resetting an abbrev's use count every
      ;; time a mode starts.
      (let ((name (string->symbol
                   (string-append (symbol->string (major-mode))
                                  "-abbrev-table")))
            (defs (%c-langvar 'c-std-abbrev-keywords)))
        (unless (and (abbrev-table-named name)
                     (abbrev-table-p (abbrev-table-named name)))
          (define-abbrev-table name '()))
        (set!local-abbrev-table (abbrev-table-named name))
        (for-each
         (lambda (abbrev)
           ;; "Don't overwrite the abbrev's use count."
           (unless (hash-ref (abbrev-table-abbrevs (abbrev-table-named name))
                             abbrev #f)
             (define-abbrev (abbrev-table-named name)
                            abbrev abbrev 'c-electric-continued-statement
                            0 #t)))
         ;; IDL is the language Emacs gives no keywords (`cc-langs.el`'s
         ;; `idl nil'), and the C's `while defs' walks nil - `#f' here -
         ;; without complaint; a `for-each' over it would raise.
         (or defs '()))))

    ;; `c-bind-special-erase-keys' (`cc-mode.el:319') waits on
    ;; `normal-erase-is-backspace', which is not ported; the two
    ;; C-c <delete> bindings it chooses between are below, bound the
    ;; Emacs-on-tty way.

    (if c-mode-base-map
        #f
        (begin
          (set! c-mode-base-map (make-sparse-keymap))
          (c-set-keymap-parent c-mode-base-map prog-mode-map)

          ;; "Separate M-BS from C-M-h. The former should remain
          ;; backward-kill-word."
          (define-key c-mode-base-map (kbd "C-M-h") c-mark-function)
          (define-key c-mode-base-map (kbd "M-C-q") c-indent-exp)
          (substitute-key-definition backward-sentence
                                     c-beginning-of-statement
                                     c-mode-base-map *default-keymap* (vector))
          (substitute-key-definition forward-sentence
                                     c-end-of-statement
                                     c-mode-base-map *default-keymap* (vector))
          (substitute-key-definition indent-new-comment-line
                                     c-indent-new-comment-line
                                     c-mode-base-map *default-keymap* (vector))
          (substitute-key-definition indent-for-tab-command
                                     c-indent-line-or-region
                                     c-mode-base-map *default-keymap* (vector))
          ;; "indent-new-comment-line has changed name to
          ;; comment-indent-new-line in Emacs 21."
          (substitute-key-definition comment-indent-new-line
                                     c-indent-new-comment-line
                                     c-mode-base-map *default-keymap* (vector))

          (define-key c-mode-base-map (kbd "M-C-a") c-beginning-of-defun)
          (define-key c-mode-base-map (kbd "M-C-e") c-end-of-defun)

          (define-key c-mode-base-map (kbd "C-c C-n") c-forward-conditional)
          (define-key c-mode-base-map (kbd "C-c C-p") c-backward-conditional)
          (define-key c-mode-base-map (kbd "C-c C-u") c-up-conditional)

          (substitute-key-definition fill-paragraph c-fill-paragraph
                                     c-mode-base-map *default-keymap* (vector))

          ;; "Bind the electric deletion functions to C-d and DEL."
          (define-key c-mode-base-map (kbd "C-d") c-electric-delete-forward)
          (define-key c-mode-base-map (kbd "DEL") c-electric-backspace)
          (define-key c-mode-base-map (kbd "C-c C-d") c-hungry-delete-forward)
          ;; Emacs also writes `[?\C-c ?\d]' and `[?\C-c ?\C-\d]' to
          ;; `c-hungry-delete-backwards', and the **measured** answer is
          ;; that they do not win: `(key-binding (kbd "C-c C-d"))' in a
          ;; real `c-mode' buffer is `c-hungry-delete-forward', and C-c d
          ;; is nil. The observable bindings are what is carried; the two
          ;; `<delete>' forms are the tty's own key events, in this
          ;; keymap currency event symbols, and Emacs answers the same
          ;; command for `C-c C-<delete>' as for `C-c C-d'.
          (define-key c-mode-base-map (vector 3 'deletechar)
                      c-hungry-delete-forward)
          (define-key c-mode-base-map (vector 3 '(control deletechar))
                      c-hungry-delete-forward)

          (define-key c-mode-base-map (kbd "#") c-electric-pound)
          (define-key c-mode-base-map (kbd "{") c-electric-brace)
          (define-key c-mode-base-map (kbd "}") c-electric-brace)
          (define-key c-mode-base-map (kbd "/") c-electric-slash)
          (define-key c-mode-base-map (kbd "*") c-electric-star)
          (define-key c-mode-base-map (kbd ";") c-electric-semi&comma)
          (define-key c-mode-base-map (kbd ",") c-electric-semi&comma)
          (define-key c-mode-base-map (kbd ":") c-electric-colon)
          (define-key c-mode-base-map (kbd "(") c-electric-paren)
          (define-key c-mode-base-map (kbd ")") c-electric-paren)

          (define-key c-mode-base-map (kbd "C-c C-\\") c-backslash-region)
          (define-key c-mode-base-map (kbd "C-c C-a") c-toggle-auto-newline)
          ;; C-c C-b: `c-submit-bug-report' (reporter.el) is not ported.
          (define-key c-mode-base-map (kbd "C-c C-c") comment-region)
          (define-key c-mode-base-map (kbd "C-c C-l") c-toggle-electric-state)
          (define-key c-mode-base-map (kbd "C-c C-o") c-set-offset)
          (define-key c-mode-base-map (kbd "C-c C-q") c-indent-defun)
          (define-key c-mode-base-map (kbd "C-c C-s")
                      c-show-syntactic-information)
          (define-key c-mode-base-map (kbd "C-c .") c-set-style)
          ;; `C-c C-w' is `c-subword-mode' (`cc-mode.el:467'), which is
          ;; `subword.el`'s obsolete alias of `subword-mode'. The
          ;; binding is the *symbol*, as Emacs writes it: `subword.scm`
          ;; reaches this library through `cc-cmds.scm`, and
          ;; `dispatch-action` resolves the name in the command table
          ;; when the key is pressed.
          (define-key c-mode-base-map (kbd "C-c C-w") 'c-subword-mode)
          (define-key c-mode-base-map (kbd "C-c C-k") c-toggle-comment-style)
          (define-key c-mode-base-map (kbd "C-c C-z") c-display-defun-name)))

    ;;------------------------------------------------------------------
    ;; `c-basic-common-init' (`cc-mode.el:598')
    ;;------------------------------------------------------------------
    (define (c-basic-common-init mode default-style)
      "Initialize the syntax handling routines and the line breaking/filling code.
Intended to be used by other packages that embed CC Mode.

MODE is the CC Mode flavor to set up, e.g. `c-mode' or `java-mode'.
DEFAULT-STYLE tells which indentation style to install.  It has the
same format as `c-default-style'.

Note that `c-init-language-vars' must be called before this function.
This function cannot do that since `c-init-language-vars' is a macro
that requires a literal mode spec at compile time."
      (*c-buffer-is-cc-mode* mode)

      (c-populate-abbrev-table)

      ;; "these variables should always be buffer local; they do not
      ;; affect indentation style." The four comment variables are the
      ;; language's (`c-lang-defvar' set them buffer-locally already),
      ;; and the paragraph ones are `paragraphs.scm''s accessor pairs,
      ;; which are buffer-local by construction.
      (set-buffer-local-value! (current-buffer) 'comment-start
                               (comment-start))
      (set-buffer-local-value! (current-buffer) 'comment-end
                               (comment-end))
      (set-buffer-local-value! (current-buffer) 'comment-start-skip
                               (comment-start-skip))

      ;; "Prepare for the use of `electric-pair-mode'."
      (set-buffer-local-value! (current-buffer)
                               'electric-pair-inhibit-predicate
                               c-electric-pair-inhibit-predicate)

      (set-buffer-local-value! (current-buffer)
                               'parse-sexp-ignore-comments #t)
      (setq-local 'indent-line-function c-indent-line)
      (setq-local 'indent-region-function c-indent-region)
      (setq-local 'normal-auto-fill-function c-do-auto-fill)
      (set!comment-multi-line #t)
      (setq-local 'comment-line-break-function c-indent-new-comment-line)
      ;; `editorconfig-indent-size-vars': editorconfig is not ported.

      ;; "Prevent time-wasting activity on C-y." `yank-handled-properties'
      ;; is not ported (there is no such variable to filter).

      ;; "For the benefit of adaptive fill, which otherwise mis-fills."
      (set!fill-paragraph-handle-comment #f)

      ;; "Install `c-fill-paragraph' on `fill-paragraph-function'."
      (set!fill-paragraph-function c-fill-paragraph)

      ;; "Initialize the cache for `c-looking-at-or-maybe-in-bracelist'."
      ;; **Emacs's nil is the empty list here**: both caches are searched
      ;; with `memv', and `(memv x #f)' is an error.
      (set!c-laomib-cache '())
      ;; "Initialize the cache for non brace-list braces."
      (set!c-no-bracelist-cache '())
      ;; "Initialize the three literal sub-caches."
      (c-truncate-lit-pos/state-cache 1)
      ;; "Initialize the cache of brace pairs, and opening
      ;; braces/brackets/parens."
      (c-state-cache-init)
      ;; "Initialize the "brace stack" cache."
      (c-init-bs-cache)

      ;; "Keep track of where `c-fl-syn-tab' text properties are set."
      (set!c-min-syn-tab-mkr #f)
      (set!c-max-syn-tab-mkr #f)

      ;; "We use the syntax-table text property to change the syntax of
      ;; some chars, potentially in every language, so set this up."
      (set-buffer-local-value! (current-buffer)
                               'parse-sexp-lookup-properties #t)

      ;; "Use this in Emacs 21+ to avoid meddling with the
      ;; rear-nonsticky property on each character." The buffer's own
      ;; list is Emacs's: the global value with the four properties
      ;; consed on where they are absent (`textprop.scm' reads it).
      (set-buffer-local-value!
       (current-buffer) 'text-property-default-nonsticky
       (let loop ((props '(syntax-table c-fl-syn-tab category c-type))
                  (lst (*text-property-default-nonsticky*)))
         (if (null? props)
             lst
             (loop (cdr props)
                   (if (assq (car props) lst)
                       lst
                       (cons (cons (car props) #t) lst))))))

      (c-clear-found-types)

      ;; "now set the mode style based on default-style"
      (let* ((style (cc-choose-style-for-mode mode default-style)))
        ;; "Override style variables if `c-old-style-variable-behavior'
        ;; is set. Also override if we are using global style variables,
        ;; have already initialized a style once, and are switching to a
        ;; different style."
        (c-set-style
         style
         (not (or (*c-old-style-variable-behavior*)
                  (and (not (*c-style-variables-are-local-p*))
                       (c-indentation-style)
                       (not (string-equal (c-indentation-style) style)))))))
      (c-setup-paragraph-variables)

      ;; "we have to do something special for c-offsets-alist so that the
      ;; buffer local value has its own alist structure."
      (set!c-offsets-alist (copy-alist (c-offsets-alist)))

      ;; "setup the comment indent variable in an Emacs version portable
      ;; way"
      (setq-local 'comment-indent-function c-comment-indent)
      ;; "What sort of comments are default for M-;?"
      (set!c-block-comment-flag (%c-langvar 'c-block-comment-is-default))

      ;; "In Emacs 24.4 onwards, prevent Emacs's built in electric
      ;; indentation from messing up CC Mode's, and set
      ;; `c-electric-flag' if `electric-indent-mode' has been called by
      ;; the user."
      (set!electric-indent-inhibit #t)
      (set!c-electric-flag (electric-indent-mode-value))

      (c-update-modeline)

      ;; "Install the functions that ensure that various internal caches
      ;; don't become invalid due to buffer changes."
      (add-hook *before-change-functions* c-before-change #f #t)
      (set!c-just-done-before-change #f)
      (add-hook *after-change-functions* c-after-change #f #t)
      (add-hook *post-command-hook* c-post-command #f #t)

      (set!font-lock-extend-after-change-region-function!
       c-extend-after-change-region))

    (define (c-setup-doc-comment-style)
      "Initialize the variables that depend on the value of `c-doc-comment-style'."
      (when (font-lock-mode-on?)
        ;; "Force font lock mode to reinitialize itself."
        (font-lock-mode -1)
        (font-lock-mode 1)))

    ;;------------------------------------------------------------------
    ;; `c-common-init' (`cc-mode.el:797')
    ;;------------------------------------------------------------------
    (define (c-common-init . rest)
      "Common initialization for all CC Mode modes.
In addition to the work done by `c-basic-common-init' and
`c-font-lock-init', this function sets up various other things as
customary in CC Mode modes but which aren't strictly necessary for CC
Mode to operate correctly.

MODE is the symbol for the mode to initialize, like `c-mode'.  See
`c-basic-common-init' for details.  It's only optional to be
compatible with old code; callers should always specify it."
      (let ((mode (and (pair? rest) (car rest))))
        (parameterize ((*case-fold-search* #f))
          (unless mode
            ;; "Called from an old third party package. The fallback is
            ;; to initialize for C."
            (c-init-language-vars-for 'c-mode))

          (c-basic-common-init mode (*c-default-style*))
          (when mode
            ;; "Only initialize font locking if we aren't called from an
            ;; old package."
            (c-font-lock-init))

          ;; "Starting a mode is a sort of "change". So call the change
          ;; functions..."
          (save-restriction
            (widen)
            (set!c-new-BEG (point-min))
            (set!c-new-END (point-max))
            (save-excursion
              (let ((before-change-functions '())
                    (after-change-functions '()))
                (parameterize ((*before-change-functions*
                                before-change-functions)
                               (*after-change-functions*
                                after-change-functions))
                  ;; Emacs `funcall`s each *symbol*; here the symbol is
                  ;; resolved through the language-function registry
                  ;; (`c-register-lang-function!'), as the change hooks
                  ;; do.
                  (for-each (lambda (fn)
                              ((%c-lang-function fn) (point-min) (point-max)))
                            (%c-langvar 'c-get-state-before-change-functions))
                  (for-each (lambda (fn)
                              ((%c-lang-function fn)
                               (point-min) (point-max)
                               (- (point-max) (point-min))))
                            (%c-langvar 'c-before-font-lock-functions))))))

          (setq-local 'outline-regexp "[^#\n\r]")
          (setq-local 'outline-level c-outline-level)
          (setq-local 'add-log-current-defun-function
                      (lambda ()
                        (or (c-cpp-define-name)
                            (car (c-defun-name-and-limits #f)))))
          (let ((rfn (assq mode (*c-require-final-newline*))))
            (when rfn
              ;; `mode-require-final-newline' is `files.scm''s
              ;; parameter; Emacs's `(boundp ...)' arm is the one taken.
              (and (cdr rfn)
                   (set-buffer-local-value! (current-buffer)
                                            'require-final-newline
                                            (*mode-require-final-newline*))))))))

    ;;------------------------------------------------------------------
    ;; `c-font-lock-init' (`cc-mode.el:2752'), `c-after-font-lock-init'
    ;; and `c-extend-after-change-region'
    ;;------------------------------------------------------------------
    (define (c-font-lock-init)
      "Set up the font-lock variables for using the font-lock support in CC Mode.
This does not load the font-lock package.  Use after
`c-basic-common-init' and after cc-fonts has been loaded.
This function is called from `c-common-init', once per mode initialization."
      (set!font-lock-defaults!
       (list (if (c-major-mode-is 'awk-mode)
                 ;; "awk-mode currently has only one font lock level."
                 'awk-font-lock-keywords
                 (map c-mode-symbol
                      (list "font-lock-keywords" "font-lock-keywords-1"
                            "font-lock-keywords-2" "font-lock-keywords-3")))
             #f #f
             (%c-langvar 'c-identifier-syntax-modifications)
             c-beginning-of-syntax
             (cons 'font-lock-mark-block-function c-mark-function)))

      ;; "Prevent `font-lock-default-fontify-region' extending the region
      ;; it will fontify to whole lines by removing
      ;; `font-lock-extend-region-wholelines' from
      ;; `font-lock-extend-region-functions'. (Emacs only). This fixes
      ;; Emacs bug #19669." The variable is `defvar-local` in Emacs, so
      ;; the `delq` is this buffer's alone; here it is the buffer-local
      ;; accessor pair, not the global parameter.
      (set!font-lock-extend-region-functions!
       (delq font-lock-extend-region-wholelines
             (font-lock-extend-region-functions)))

      (set!font-lock-fontify-region-function! c-font-lock-fontify-region)

      (add-hook font-lock-mode-hook c-after-font-lock-init #f #t))

    (define (c-after-font-lock-init)
      ;; "Put on `font-lock-mode-hook'. This function ensures our
      ;; after-change function will get executed before the font-lock
      ;; one."
      (when (memq c-after-change (hook-value *after-change-functions*))
        (remove-hook *after-change-functions* c-after-change #t)
        (add-hook *after-change-functions* c-after-change #f #t)))

    ;; "Emacs 22 and later."
    (define (c-extend-after-change-region beg end old-len)
      "Extend the region to be fontified, if necessary."
      ;; "Note: the parameter OLD-LEN is ignored here."
      (when (eq? (*font-lock-support-mode*) 'jit-lock-mode)
        (save-restriction
          (widen)
          (c-save-buffer-state
           () ;; "Protect the undo-list from put-text-property."
           (if (< (c-new-BEG) beg)
               (put-text-property (c-new-BEG) beg 'fontified #f))
           (if (> (c-new-END) end)
               (put-text-property end (c-new-END) 'fontified #f)))))
      (cons (c-new-BEG) (c-new-END)))

    ;;------------------------------------------------------------------
    ;; `c-change-expand-fl-region's context half (`cc-mode.el:2669')
    ;;------------------------------------------------------------------
    (define (c-context-expand-fl-region beg end)
      ;; "Return a cons (NEW-BEG . NEW-END), where NEW-BEG is the
      ;; beginning of a "local" declaration containing BEG (see
      ;; `c-fl-decl-start') or BOL BEG is in.  NEW-END is beginning of
      ;; the line after the one END is in."
      (c-save-buffer-state
       ()
       (cons (or (c-fl-decl-start beg) (c-doc-fl-decl-start beg)
                 (c-point 'bol beg))
             (or (c-fl-decl-end end) (c-doc-fl-decl-end end)
                 (c-point 'bonl (- end 1))))))

    ;; `c-context-expand-fl-region' (`cc-mode.el:2669') is named by the
    ;; `c-before-context-fontification-functions' language constant
    ;; (`cc-langs.el:589'), which `c-before-context-fl-expand-region'
    ;; holds as symbols and resolves through this registry (Emacs
    ;; funcalls the symbol through its obarray). The registration has to
    ;; follow both definitions - a registration is a procedure value,
    ;; and a Scheme forward reference is unbound.
    (c-register-lang-function! 'c-context-expand-fl-region
                               c-context-expand-fl-region)

    (define (c-before-context-fl-expand-region beg end)
      ;; "Expand the region (BEG END) as specified by
      ;; `c-before-context-fontification-functions'.  Return a cons of
      ;; the bounds of the new region."
      (save-restriction
        (widen)
        (save-excursion
          (let ((new-beg beg) (new-end end)
                (new-region (cons beg end)))
            ;; Emacs `funcall's each SYMBOL through the obarray; this
            ;; tree's language-function registry is what stands in for
            ;; it (`c-register-lang-function!'), so the symbol has to be
            ;; resolved before it is applied. Applying it raw raised
            ;; "Wrong type to apply: c-context-expand-fl-region" from
            ;; the redisplay the first time a C buffer's region was
            ;; context-expanded (2026-11-25).
            (for-each (lambda (fn)
                        (set! new-region ((%c-lang-function fn) new-beg new-end))
                        (set! new-beg (car new-region))
                        (set! new-end (cdr new-region)))
                      (%c-langvar 'c-before-context-fontification-functions))
            new-region))))

    (define (c-font-lock-fontify-region beg end . rest)
      ;; "Effectively advice around `font-lock-fontify-region' which
      ;; extends the region (BEG END), for example, to avoid context
      ;; fontification chopping off the start of the context.  Do not
      ;; extend the region if it's already been done (i.e. from an
      ;; after-change fontification)."
      (let ((verbose (and (pair? rest) (car rest))))
        (save-restriction
          (widen)
          (let ((new-beg #f) (new-end #f) (new-region #f))
            (c-save-buffer-state
             ()
             (c-with-string-fences
              (parameterize ((*case-fold-search* #f))
                (if (and (c-in-after-change-fontification)
                         (< beg (c-new-END)) (> end (c-new-BEG)))
                    ;; "Region and the latest after-change fontification
                    ;; region overlap. Determine the upper and lower
                    ;; bounds of our adjusted region separately."
                    (begin
                      (if (<= beg (c-new-BEG))
                          (set!c-in-after-change-fontification #f))
                      (set! new-beg
                            (if (and (>= beg (c-point 'bol (c-new-BEG)))
                                     (<= beg (c-new-BEG)))
                                ;; "Either jit-lock has accepted
                                ;; `c-new-BEG', or has (probably)
                                ;; extended the change region spuriously
                                ;; to BOL..."
                                (c-new-BEG)
                                (begin
                                  (set! new-region
                                        (c-before-context-fl-expand-region
                                         beg end))
                                  (set! new-end (cdr new-region))
                                  (car new-region))))
                      (set! new-end
                            (if (and (>= end (c-point 'bol (c-new-END)))
                                     (<= end (c-new-END)))
                                (c-new-END)
                                (or new-end
                                    (cdr (c-before-context-fl-expand-region
                                          beg end))))))
                    ;; "Context (etc.) fontification."
                    (begin
                      (set! new-region
                            (c-before-context-fl-expand-region beg end))
                      (set! new-beg (car new-region))
                      (set! new-end (cdr new-region))))
                ;; "Finally invoke font lock's functionality."
                ((*font-lock-fontify-region-function*)
                 new-beg new-end verbose))))))))

    ;; `c-force-redisplay' (`cc-fonts.scm') calls this function through
    ;; a seam because cc-fonts sits below this library; the seam's
    ;; default raises "not yet initialised", so cc-mode has to install
    ;; the real function as it loads - Emacs needs no such line because
    ;; its `c-force-redisplay' calls the (forward-referenced) function
    ;; directly. Without this, a new type found during fontification
    ;; (`c-fontify-new-found-type') raised that error in the redisplay
    ;; (2026-11-25).
    (*c-font-lock-fontify-region-function* c-font-lock-fontify-region)

    ;;------------------------------------------------------------------
    ;; The electric-indent hook pair (`cc-mode.el:2824')
    ;;------------------------------------------------------------------
    (define (c-electric-indent-mode-hook)
      ;; "Emacs has en/disabled `electric-indent-mode'. Propagate this
      ;; through to each CC Mode buffer."
      (for-each
       (lambda (buf)
         (with-current-buffer
          buf
          (when (*c-buffer-is-cc-mode*)
            ;; "Don't use `c-toggle-electric-state' here due to
            ;; recursion."
            (set!c-electric-flag (electric-indent-mode-value))
            (c-update-modeline))))
       (buffer-list)))

    (define (c-electric-indent-local-mode-hook)
      ;; "Emacs has en/disabled `electric-indent-local-mode' for this
      ;; buffer. Propagate this through to this buffer's value of
      ;; `c-electric-flag'."
      (when (*c-buffer-is-cc-mode*)
        (set!c-electric-flag (electric-indent-mode-value))
        (c-update-modeline)))

    ;;------------------------------------------------------------------
    ;; "Connection with Emacs's electric-pair-mode"
    ;;------------------------------------------------------------------
    (define (c-electric-pair-inhibit-predicate char)
      "Return t to inhibit the insertion of a second copy of CHAR.

At the time of call, point is just after the newly inserted CHAR.

When CHAR is \" and not within a comment, t will be returned if
the quotes on the current line are already balanced.  For other
cases, the default value of `electric-pair-inhibit-predicate' is
called and its value returned.

This function is the appropriate value of
`electric-pair-inhibit-predicate' for CC Mode modes, which mark
invalid strings with such a syntax table text property on the
opening \" and the next unescaped end of line."
      ;; Emacs's CHAR is `last-command-event', an integer there; a
      ;; character here.
      (let ((ch (if (char? char) char (integer->char char))))
        (if (and (char=? ch #\")
                 (not (memq (%c-cadr (c-semi-pp-to-literal (- (point) 1)))
                            '(c c++))))
            (not (c-open-string-opener))
            ((*electric-pair-inhibit-predicate*) ch))))

    ;;------------------------------------------------------------------
    ;; `c-post-command' (`cc-mode.el:2211')
    ;;------------------------------------------------------------------
    (define (c-post-command)
      ;; "If point was inside of a new identifier and no longer is,
      ;; record that fact."
      (when (and (*c-buffer-is-cc-mode*)
                 (c-new-id-start) (c-new-id-end)
                 (or (> (point) (c-new-id-end))
                     (< (point) (c-new-id-start))))
        (when (c-new-id-is-type)
          (c-add-type-1 (c-new-id-start) (c-new-id-end)))
        (set!c-new-id-start #f)
        (set!c-new-id-end #f)
        (set!c-new-id-is-type #f)))

    (define-syntax c-run-mode-hooks
      ;; `(defmacro c-run-mode-hooks (&rest hooks) ... (if
      ;; (cc-bytecomp-fboundp 'run-mode-hooks) `(run-mode-hooks ,@hooks)
      ;; ...))' (`cc-mode.el:987'). `run-mode-hooks' is `subr.scm`'s, so
      ;; the first arm is the only one.
      (syntax-rules ()
        ((_ hook ...) (run-mode-hooks hook ...))))

    ;;==================================================================
    ;; Support for C (`cc-mode.el:2860'-`:2960')
    ;;==================================================================

    ;; `c-guess-region-max' is `cc-guess.el:93''s defcustom - cc-guess
    ;; is not ported - carried here because `c-or-c++-mode' is its one
    ;; reader in this file.
    (define-custom *c-guess-region-max* 50000
      "The maximum region size for examining indent information with `c-guess'.
It takes a long time to examine indent information from a large region;
this option helps you limit that time.  nil means no limit."
      :version "24.1"
      :type 'integer
      :group 'c)

    (define c-mode-syntax-table
      ((c-lang-const c-make-mode-syntax-table c)))
    ;; ^ "Syntax table used in `c-mode' buffers." Emacs calls the
    ;; constant's *function* for a table of this mode's own; the language
    ;; constant `c-mode-syntax-table' is the evaluated table used while
    ;; the constants themselves are computed.

    (define c-mode-map
      (let ((map (c-make-inherited-keymap)))
        map))
    ;; ^ "Keymap used in `c-mode' buffers."
    ;; "Add bindings which are only useful for C." The command is named
    ;; as Emacs names it - a *symbol*, not the procedure - because
    ;; `cmacexp.el' requires `cc-mode' and so cannot be imported here;
    ;; `command.scm`'s autoload table loads it at the first lookup, as
    ;; Emacs's `;;;###autoload' does.
    (define-key c-mode-map (kbd "C-c C-e") 'c-macro-expand)

    (define-custom c-mode-hook '()
      "Hook called by `c-mode'."
      :type 'hook :group 'c)
    ;; ^ `c-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (c-mode prog-mode "C" c-mode-map c-mode-hook
                                 c-mode-syntax-table)
      "Major mode for editing C code.

To submit a problem report, enter `\\[c-submit-bug-report]' from a
`c-mode' buffer.  This automatically sets up a mail buffer with version
information already added.  You just need to add a description of the
problem, including a reproducible test case, and send the message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `c-mode-hook'.

Key bindings:
\\{c-mode-map}"
      :after-hook (begin (c-make-noise-macro-regexps)
                         (c-make-macro-with-semi-re)
                         (c-update-modeline))
      (c-initialize-cc-mode #t)
      ;; `(setq abbrev-mode t)' - the variable is `abbrev.scm''s
      ;; buffer-local slot, which its reader consults.
      (set-buffer-local-value! (current-buffer) 'abbrev-mode #t)
      (c-init-language-vars-for 'c-mode)
      (c-common-init 'c-mode)
      (cc-imenu-init cc-imenu-c-generic-expression)
      ;; `flymake-diagnostic-functions': flymake is not ported.
      (c-run-mode-hooks (*c-mode-common-hook*)))

    (easy-menu-define c-c-menu c-mode-map "C Mode Commands."
                      (cons "C" (c-lang-const c-mode-menu c)))

    (define c-or-c++-mode--regexp
      ;; "A regexp applied to C header files to check if they are really
      ;; C++." The body is Emacs's `eval-when-compile' expression, run
      ;; at load: a `let` of the two pieces with the header list spliced
      ;; into `regexp-opt`.
      (let ((id "[a-zA-Z_][a-zA-Z0-9_]*") (ws "[ \t]+") (ws-maybe "[ \t]*")
            (headers '("string" "string_view" "iostream" "map" "unordered_map"
                       "set" "unordered_set" "vector" "tuple")))
        (string-append
         "^" ws-maybe "\\(?:"
         "using" ws "\\(?:namespace" ws
         "\\|" id "::"
         "\\|" id ws-maybe "=\\)"
         "\\|" "\\(?:inline" ws "\\)?namespace"
         "\\(?:" ws "\\(?:" id "::\\)*" id "\\)?" ws-maybe "{"
         "\\|" "class" ws id
         "\\(?:" ws "final" "\\)?" ws-maybe "[:{;\n]"
         "\\|" "struct" ws id "\\(?:" ws "final" ws-maybe "[:{\n]"
         "\\|" ws-maybe ":\\)"
         "\\|" "template" ws-maybe "<.*?>"
         "\\|" "#include" ws-maybe "<" (regexp-opt headers) ">"
         "\\)")))

    (define-command (c-or-c++-mode)
      "Analyze buffer and enable either C or C++ mode.

Some people and projects use .h extension for C++ header files
which is also the one used for C header files.  This makes
matching on file name insufficient for detecting major mode that
should be used.

This function attempts to use file contents to determine whether
the code is C or C++ and based on that chooses whether to enable
`c-mode' or `c++-mode'."
      (interactive)
      (let ((mode
             (if (save-excursion
                   (save-restriction
                     (save-match-data
                       (widen)
                       (goto-char (point-min))
                       (re-search-forward c-or-c++-mode--regexp
                                          (+ (point) (*c-guess-region-max*))
                                          #t))))
                 'c++-mode
                 'c-mode)))
        ;; Emacs's `(funcall (if (fboundp 'major-mode-remap)
        ;; (major-mode-remap mode) mode))'. `major-mode-remap` answers a
        ;; *symbol*, which `funcall` resolves through the obarray; this
        ;; tree's `%mode-function` is that resolution (and its autoload).
        ((%mode-function (major-mode-remap mode)))))

    ;;==================================================================
    ;; Support for C++ (`cc-mode.el:2990'-`:3040')
    ;;==================================================================

    (define c++-mode-syntax-table
      ((c-lang-const c-make-mode-syntax-table c++)))
    ;; ^ "Syntax table used in c++-mode buffers."

    (define c++-mode-map
      (let ((map (c-make-inherited-keymap)))
        map))
    ;; ^ "Keymap used in c++-mode buffers."
    (define-key c++-mode-map (kbd "C-c C-e") 'c-macro-expand)
    (define-key c++-mode-map (kbd "C-c :") c-scope-operator)
    (define-key c++-mode-map "<" c-electric-lt-gt)
    (define-key c++-mode-map ">" c-electric-lt-gt)

    (easy-menu-define c-c++-menu c++-mode-map "C++ Mode Commands."
                      (cons "C++" (c-lang-const c-mode-menu c++)))

    (define-custom c++-mode-hook '()
      "Hook called by `c++-mode'."
      :type 'hook :group 'c)
    ;; ^ `c++-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (c++-mode prog-mode "C++" c++-mode-map c++-mode-hook
                                   c++-mode-syntax-table)
      "Major mode for editing C++ code.
To submit a problem report, enter `\\[c-submit-bug-report]' from a
c++-mode buffer.  This automatically sets up a mail buffer with
version information already added.  You just need to add a description
of the problem, including a reproducible test case, and send the
message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `c++-mode-hook'.

Key bindings:
\\{c++-mode-map}"
      :after-hook (begin (c-make-noise-macro-regexps)
                         (c-make-macro-with-semi-re)
                         (c-update-modeline))
      (c-initialize-cc-mode #t)
      (set-buffer-local-value! (current-buffer) 'abbrev-mode #t)
      (c-init-language-vars-for 'c++-mode)
      (c-common-init 'c++-mode)
      (cc-imenu-init cc-imenu-c++-generic-expression)
      (c-run-mode-hooks (*c-mode-common-hook*)))

    ;;==================================================================
    ;; Support for Objective-C (`cc-mode.el:3040'-`:3083')
    ;;==================================================================

    (define objc-mode-syntax-table
      ((c-lang-const c-make-mode-syntax-table objc)))
    ;; ^ "Syntax table used in `objc-mode' buffers."

    (define objc-mode-map
      (let ((map (c-make-inherited-keymap)))
        map))
    ;; ^ "Keymap used in `objc-mode' buffers." Emacs also binds C-c C-e
    ;; here (`c-macro-expand'), as it does for pike.
    (define-key objc-mode-map (kbd "C-c C-e") 'c-macro-expand)

    (easy-menu-define c-objc-menu objc-mode-map "ObjC Mode Commands."
                      (cons "ObjC" (c-lang-const c-mode-menu objc)))

    (define-custom objc-mode-hook '()
      "Hook called by `objc-mode'."
      :type 'hook :group 'c)
    ;; ^ `objc-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (objc-mode prog-mode "ObjC" objc-mode-map
                                   objc-mode-hook objc-mode-syntax-table)
      "Major mode for editing Objective C code.
To submit a problem report, enter `\\[c-submit-bug-report]' from an
`objc-mode' buffer.  This automatically sets up a mail buffer with
version information already added.  You just need to add a description
of the problem, including a reproducible test case, and send the
message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `objc-mode-hook'.

Key bindings:
\\{objc-mode-map}"
      ;; Emacs's `:after-hook' has the two macro-regexp builders that
      ;; only objc-mode has; the other modes' bodies do not.
      :after-hook (begin (c-make-noise-macro-regexps)
                         (c-make-macro-with-semi-re)
                         (c-update-modeline))
      (c-initialize-cc-mode #t)
      (set-buffer-local-value! (current-buffer) 'abbrev-mode #t)
      (c-init-language-vars-for 'objc-mode)
      (c-common-init 'objc-mode)
      ;; Emacs passes nil and the *symbol* `cc-imenu-objc-function';
      ;; there is no function obarray here, so the procedure.
      (cc-imenu-init #f cc-imenu-objc-function)
      (c-run-mode-hooks (*c-mode-common-hook*)))

    ;;==================================================================
    ;; Support for Java (`cc-mode.el:3099'-`:3172')
    ;;==================================================================

    (define java-mode-syntax-table
      ((c-lang-const c-make-mode-syntax-table java)))
    ;; ^ "Syntax table used in `java-mode' buffers."

    (define java-mode-map
      (let ((map (c-make-inherited-keymap)))
        map))
    ;; ^ "Keymap used in `java-mode' buffers." Java adds no bindings of
    ;; its own in `cc-mode.el'.

    (define c-Java-defun-prompt-regexp
      ;; "Regexp trying to describe the beginning of a Java top-level
      ;; definition. This is not used by CC Mode, nor is it maintained
      ;; since it's practically impossible to write a regexp that
      ;; reliably matches such a construct. Other tools are necessary."
      ;; The value is Emacs 31.1's, character for character.
      "^[ \t]*\\(\\(\\(public\\|protected\\|private\\|const\\|abstract\\|synchronized\\|final\\|static\\|threadsafe\\|transient\\|native\\|volatile\\)\\s-+\\)*\\(\\(\\([[a-zA-Z][][_$.a-zA-Z0-9]+\\|[[a-zA-Z]\\)\\s-*\\)\\s-+\\)\\)?\\(\\([[a-zA-Z][][_$.a-zA-Z0-9]*\\s-+\\)\\s-*\\)?\\([_a-zA-Z][^][ \t:;.,{}()\x7f=]*\\|\\([_$a-zA-Z][_$.a-zA-Z0-9]*\\)\\)\\s-*\\(([^);{}]*)\\)?\\([] \t]*\\)\\(\\s-*\\<throws\\>\\s-*\\(\\([_$a-zA-Z][_$.a-zA-Z0-9]*\\)[, \t\n\r\x0c\x0b]*\\)+\\)?\\s-*")

    (easy-menu-define c-java-menu java-mode-map "Java Mode Commands."
                      (cons "Java" (c-lang-const c-mode-menu java)))

    (define-custom java-mode-hook '()
      "Hook called by `java-mode'."
      :type 'hook :group 'c)
    ;; ^ `java-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (java-mode prog-mode "Java" java-mode-map
                                   java-mode-hook java-mode-syntax-table)
      "Major mode for editing Java code.
To submit a problem report, enter `\\[c-submit-bug-report]' from a
`java-mode' buffer.  This automatically sets up a mail buffer with
version information already added.  You just need to add a description
of the problem, including a reproducible test case, and send the
message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `java-mode-hook'.

Key bindings:
\\{java-mode-map}"
      :after-hook (c-update-modeline)
      (c-initialize-cc-mode #t)
      (set-buffer-local-value! (current-buffer) 'abbrev-mode #t)
      (c-init-language-vars-for 'java-mode)
      (c-common-init 'java-mode)
      (cc-imenu-init cc-imenu-java-generic-expression)
      (c-run-mode-hooks (*c-mode-common-hook*)))

    ;;==================================================================
    ;; Support for CORBA's IDL (`cc-mode.el:3174'-`:3230')
    ;;==================================================================

    (define idl-mode-syntax-table
      ((c-lang-const c-make-mode-syntax-table idl)))
    ;; ^ "Syntax table used in `idl-mode' buffers."

    (define idl-mode-map
      (let ((map (c-make-inherited-keymap)))
        map))
    ;; ^ "Keymap used in `idl-mode' buffers." IDL adds no bindings.

    (easy-menu-define c-idl-menu idl-mode-map "IDL Mode Commands."
                      (cons "IDL" (c-lang-const c-mode-menu idl)))

    (define-custom idl-mode-hook '()
      "Hook called by `idl-mode'."
      :type 'hook :group 'c)
    ;; ^ `idl-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (idl-mode prog-mode "IDL" idl-mode-map
                                  idl-mode-hook idl-mode-syntax-table)
      "Major mode for editing CORBA's IDL, PSDL and CIDL code.
To submit a problem report, enter `\\[c-submit-bug-report]' from an
`idl-mode' buffer.  This automatically sets up a mail buffer with
version information already added.  You just need to add a description
of the problem, including a reproducible test case, and send the
message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `idl-mode-hook'.

Key bindings:
\\{idl-mode-map}"
      :after-hook (c-update-modeline)
      (c-initialize-cc-mode #t)
      (c-init-language-vars-for 'idl-mode)
      (c-common-init 'idl-mode)
      ;; `;;TODO' in Emacs: no imenu generic expression for IDL.
      (c-run-mode-hooks (*c-mode-common-hook*)))

    ;;==================================================================
    ;; Support for Pike (`cc-mode.el:3232'-`:3300')
    ;;==================================================================

    (define pike-mode-syntax-table
      ((c-lang-const c-make-mode-syntax-table pike)))
    ;; ^ "Syntax table used in `pike-mode' buffers."

    (define pike-mode-map
      (let ((map (c-make-inherited-keymap)))
        map))
    ;; ^ "Keymap used in `pike-mode' buffers." Emacs also binds C-c C-e
    ;; here (`c-macro-expand').
    (define-key pike-mode-map (kbd "C-c C-e") 'c-macro-expand)

    (easy-menu-define c-pike-menu pike-mode-map "Pike Mode Commands."
                      (cons "Pike" (c-lang-const c-mode-menu pike)))

    (define-custom pike-mode-hook '()
      "Hook called by `pike-mode'."
      :type 'hook :group 'c)
    ;; ^ `pike-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (pike-mode prog-mode "Pike" pike-mode-map
                                   pike-mode-hook pike-mode-syntax-table)
      "Major mode for editing Pike code.
To submit a problem report, enter `\\[c-submit-bug-report]' from a
`pike-mode' buffer.  This automatically sets up a mail buffer with
version information already added.  You just need to add a description
of the problem, including a reproducible test case, and send the
message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `pike-mode-hook'.

Key bindings:
\\{pike-mode-map}"
      :after-hook (c-update-modeline)
      (c-initialize-cc-mode #t)
      (set-buffer-local-value! (current-buffer) 'abbrev-mode #t)
      (c-init-language-vars-for 'pike-mode)
      (c-common-init 'pike-mode)
      ;; `;;TODO' in Emacs: no imenu generic expression for Pike.
      (c-run-mode-hooks (*c-mode-common-hook*)))


    ;;==================================================================
    ;; Support for AWK (`cc-mode.el:3226'-`:3300')
    ;;==================================================================

    (define awk-mode-map
      (c-make-inherited-keymap))
    ;; ^ "Keymap used in `awk-mode' buffers." The syntax table is
    ;; `cc-awk.scm''s, and `define-derived-mode' takes it as its sixth
    ;; element here, so the mode does not define one of its own - the
    ;; reason Emacs's definition passes `:syntax-table nil'.
    ;; "Add bindings which are only useful for awk."
    (define-key awk-mode-map (kbd "#") self-insert-command) ; "Overrides electric parent binding."
    (define-key awk-mode-map (kbd "/") self-insert-command)
    (define-key awk-mode-map (kbd "*") self-insert-command)
    (define-key awk-mode-map (kbd "C-c C-n") undefined) ; "#if doesn't exist in awk."
    (define-key awk-mode-map (kbd "C-c C-p") undefined)
    (define-key awk-mode-map (kbd "C-c C-u") undefined)
    (define-key awk-mode-map (kbd "M-a") c-beginning-of-statement) ; 2003/10/7
    (define-key awk-mode-map (kbd "M-e") c-end-of-statement)       ; 2003/10/7
    (define-key awk-mode-map (kbd "C-M-a") c-awk-beginning-of-defun)
    (define-key awk-mode-map (kbd "C-M-e") c-awk-end-of-defun)

    (easy-menu-define c-awk-menu awk-mode-map "AWK Mode Commands."
                      (cons "AWK" (c-lang-const c-mode-menu awk)))

    (define-custom awk-mode-hook '()
      "Hook called by `awk-mode'."
      :type 'hook :group 'c)
    ;; ^ `awk-mode-hook', made by `define-derived-mode' in Emacs.

    (define-derived-mode (awk-mode prog-mode "AWK" awk-mode-map
                                   awk-mode-hook awk-mode-syntax-table)
      "Major mode for editing AWK code.
To submit a problem report, enter `\\[c-submit-bug-report]' from an
`awk-mode' buffer.  This automatically sets up a mail buffer with version
information already added.  You just need to add a description of the
problem, including a reproducible test case, and send the message.

To see what version of CC Mode you are running, enter `\\[c-version]'.

The hook `c-mode-common-hook' is run with no args at mode
initialization, then `awk-mode-hook'.

Key bindings:
\\{awk-mode-map}"
      :after-hook (c-update-modeline)
      ;; "We need the next line to stop the macro defining
      ;; `awk-mode-syntax-table'. This would mask the real table which
      ;; is declared in cc-awk.el and hasn't yet been loaded." - the
      ;; macro here takes the table as its sixth element instead.
      (c-initialize-cc-mode #t)
      (set-syntax-table awk-mode-syntax-table)
      (set-buffer-local-value! (current-buffer) 'abbrev-mode #t)
      (c-init-language-vars-for 'awk-mode)
      (c-common-init 'awk-mode)
      (c-awk-unstick-NL-prop)
      (c-run-mode-hooks (*c-mode-common-hook*)))

    ;;------------------------------------------------------------------
    ;; The `c-guess-basic-syntax' seam (`cc-styles.el' reaches it)
    ;;------------------------------------------------------------------
    ;; `cc-styles.scm's `c-set-offset' builds its prompt's initial
    ;; contents from `c-guess-basic-syntax', which is `cc-engine'`s and
    ;; not importable from below. The seam answered #f while the engine
    ;; was unported; this is where the two libraries meet, so it is
    ;; installed here, at load. A consumer assembling its own libraries
    ;; without cc-mode must do the same.
    (*c-guess-basic-syntax-function* c-guess-basic-syntax)

    ))
