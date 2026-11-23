(define-library (schemacs progmodes cc-mode)
  ;; `lisp/progmodes/cc-mode.el' - the mode itself. This first pass
  ;; carries the change machinery's found-type half, in the file's
  ;; order: the two buffer-local flags, `c-unfind-enclosing-token',
  ;; `c-unfind-coalesced-tokens', `c-before-change-de-typedef',
  ;; `c-after-change-de-typedef' and `c-update-new-id'.
  ;;
  ;; **Not carried yet**, and the reason this library is partial:
  ;;
  ;;   * `c-before-change' and `c-after-change' themselves, which call
  ;;     every entry of `c-get-state-before-change-functions' and
  ;;     `c-before-font-lock-functions'. Every entry must resolve, and
  ;;     the string-fence machinery those lists name - `c-put-syn-tab',
  ;;     `c-clear-syn-tab', `c-restore-string-fences',
  ;;     `c-clear-string-fences', `c-before-change-check-unbalanced-strings',
  ;;     `c-after-change-mark-abnormal-strings',
  ;;     `c-after-change-escape-NL-in-string', the `c-min-syn-tab-mkr'/
  ;;     `c-max-syn-tab-mkr' pair and the ml-string functions - is the
  ;;     layer they stand on. `c-with-string-fences' in cc-defs is
  ;;     ported with its two functions as seams until this lands.
  ;;   * `c-depropertize-CPP', `c-neutralize-syntax-in-CPP',
  ;;     `c-before/after-change-fix-comment-escapes',
  ;;     `c-parse-quotes-after-change',
  ;;     `c-extend-font-lock-region-for-macros',
  ;;     `c-change-expand-fl-region', and `c-called-from-text-property-change-p'.
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
    (only (schemacs core syntax-macros) when-e while-e setq)
    (only (schemacs buffer) current-buffer buffer-local-value
          set-buffer-local-value!)
    (only (schemacs editfns) point goto-char point-min point-max
          bobp eobp char-before char-after buffer-substring-no-properties
          save-excursion)
    (only (schemacs search) looking-at match-end match-beginning
          re-search-forward)
    (only (schemacs syntax) skip-syntax-backward skip-chars-backward)
    (only (schemacs cmds) backward-char forward-char)
    (only (schemacs progmodes cc-defs)
          c-search-forward-non-nil-char-property
          c-clear-char-property c-get-char-property)
    (only (schemacs progmodes cc-engine)
          c-beginning-of-current-token c-end-of-current-token
          c-simple-skip-symbol-backward
          c-backward-syntactic-ws c-forward-syntactic-ws
          c-determine-limit c-determine-+ve-limit
          c-unfind-type c-on-identifier c-forward-token-2 c-backward-token-2
          c-beginning-of-macro %c-langvar
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
   c-update-new-id)

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

    ))
