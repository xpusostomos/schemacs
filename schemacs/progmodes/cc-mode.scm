(define-library (schemacs progmodes cc-mode)
  ;; `lisp/progmodes/cc-mode.el' - the mode itself. This pass carries
  ;; the change machinery's found-type half, in the file's order - the
  ;; two buffer-local flags, `c-unfind-enclosing-token',
  ;; `c-unfind-coalesced-tokens', `c-before-change-de-typedef',
  ;; `c-after-change-de-typedef' and `c-update-new-id' - the
  ;; string-fence layer those functions and the change hooks stand on
  ;; (the `c-min-syn-tab-mkr'/`c-max-syn-tab-mkr' pair, `c-put-syn-tab',
  ;; `c-clear-syn-tab', `c-clear-string-fences',
  ;; `c-restore-string-fences', `c-multiline-string-check-final-quote'
  ;; and `c-remove-string-fences', with `c-with-string-fences'' two
  ;; seams installed as this library loads), and the three string
  ;; change functions of `:1472'-`:1771':
  ;; `c-before-change-check-unbalanced-strings',
  ;; `c-after-change-mark-abnormal-strings' and
  ;; `c-after-change-escape-NL-in-string', with the helpers they use
  ;; (`c-unescaped-nls-in-string-p',
  ;; `c-multiline-string-start-is-being-detached',
  ;; `c-pps-to-string-delim', `c-bc-changed-stringiness' and
  ;; `c-open-string-opener'), the `#include' bracket and comment-escape
  ;; pairs, and the quote parsing (`c-quoted-number-*' and
  ;; `c-parse-quotes-before/after-change').
  ;;
  ;; **Not carried yet**, and the reason this library is partial:
  ;;
  ;;   * the ml-string change machinery (`c-before-change-check-ml-strings'
  ;;     and `c-after-change-unmark-ml-strings' and the
  ;;     `c-depropertize-ml-string' family). The propertization itself
  ;;     (`c-maybe-re-mark-ml-string') is in cc-engine and is what
  ;;     `c-after-change-mark-abnormal-strings' calls for C++;
  ;;   * `c-depropertize-CPP', `c-neutralize-syntax-in-CPP',
  ;;     `c-extend-font-lock-region-for-macros',
  ;;     `c-change-expand-fl-region', and `c-called-from-text-property-change-p';
  ;;   * `c-before-change' and `c-after-change' themselves, which call
  ;;     every entry of `c-get-state-before-change-functions' and
  ;;     `c-before-font-lock-functions';
  ;;   * the mode definitions (`c-basic-common-init', `c-common-init',
  ;;     `c-mode' and its siblings), which install the two change
  ;;     functions on `before-change-functions' and
  ;;     `after-change-functions' and set `indent-line-function' and
  ;;     the rest.
  ;;
  ;; **The buffer-local variables** are accessor pairs over the
  ;; buffer's slot, the tree's spelling (`c-current-comment-prefix` in
  ;; cc-vars is the same shape). Emacs's `setq` becomes the
  ;; `set!`-prefixed setter.
  (import
    (scheme base)
    (only (guile) logand caddr while)
    (only (schemacs core syntax-macros) when-e while-e setq prog1)
    (only (schemacs buffer) current-buffer buffer-local-value
          set-buffer-local-value! *case-fold-search*)
    (only (schemacs marker) copy-marker set-marker marker-position)
    (only (schemacs editfns) point point-max point-min goto-char
          bobp eobp char-before char-after buffer-substring-no-properties
          save-excursion forward-line narrow-to-region save-restriction
          widen)
    (only (schemacs search) looking-at match-end match-beginning
          re-search-forward search-forward save-match-data)
    (only (schemacs syntax) skip-syntax-backward skip-chars-backward skip-chars-forward
          parse-partial-sexp)
    (only (schemacs cmds) backward-char forward-char end-of-line beginning-of-line)
    (only (schemacs textprop) *in-property-change-p*)
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
          c-save-buffer-state
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
          *c-clear-syn-tab-properties-function*
          *c-remove-string-fences-function*
          c-truncate-lit-pos/state-cache
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
          c-new-id-is-type set!c-new-id-is-type)
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
   %c-clear-syn-tab-properties-full)

  (begin

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
    ;; property, as markers. They live beside their only readers below
    ;; rather than at their Emacs position (before
    ;; `c-basic-common-init'), which is not ported yet.
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
    ;; The second is buffer-local.
    (define (c-open-string-opener)
      (buffer-local-value (current-buffer) 'c-open-string-opener #f))
    (define (set!c-open-string-opener value)
      (set-buffer-local-value! (current-buffer) 'c-open-string-opener value))

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
        (when (memv (cadr end-state) '(c c++))
          (goto-char (max (- beg 2) (point-min)))
          (if (eq? (cadr end-state) 'c)
              (when (search-forward "\\*/"
                                    (or (cdr (caddr end-state)) (point-max)) #t)
                (c-clear-syntax-table-trim-caches (match-beginning 0)))
              (let loop ()
                (when (search-forward "\\\\\n"
                                      (or (cdr (caddr end-state)) (point-max))
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
        (goto-char (if (memv (cadr state) '(c c++))
                       (caddr state)
                       (max (- beg 2) (point-min))))
        (while-e (re-search-forward "\\\\\\(\\(\\\\\n\\)\\|\\(\\*/\\)\\)"
                                  (min (+ end 2) (point-max)) #t)
          (set! state (c-semi-pp-to-literal (match-beginning 0)))
          (when (cond
                 ((eq? (cadr state) 'c)
                  (match-beginning 3))
                 ((eq? (cadr state) 'c++)
                  (match-beginning 2)))
            (c-put-syntax-table-trim-caches (match-beginning 0) '(1))))

        (goto-char end)
        (set! state (c-semi-pp-to-literal (point)))
        (cond
         ((eq? (cadr state) 'c)
          (when (search-forward "*/" #f #t)
            (when (eqv? (char-before (match-beginning 0)) #\\)
              (c-put-syntax-table-trim-caches
               (- (match-beginning 0) 1) '(1)))))
         ((eq? (cadr state) 'c++)
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

    ))
