(define-library (schemacs progmodes cc-mode)
  ;; `lisp/progmodes/cc-mode.el' - the mode itself. This pass carries
  ;; the change machinery's found-type half, in the file's order - the
  ;; two buffer-local flags, `c-unfind-enclosing-token',
  ;; `c-unfind-coalesced-tokens', `c-before-change-de-typedef',
  ;; `c-after-change-de-typedef' and `c-update-new-id' - and then the
  ;; string-fence layer those functions and the change hooks stand on:
  ;; the `c-min-syn-tab-mkr'/`c-max-syn-tab-mkr' pair, `c-put-syn-tab',
  ;; `c-clear-syn-tab', `c-clear-string-fences',
  ;; `c-restore-string-fences', `c-multiline-string-check-final-quote'
  ;; and `c-remove-string-fences', with `c-with-string-fences'' two
  ;; seams installed as this library loads.
  ;;
  ;; **Not carried yet**, and the reason this library is partial:
  ;;
  ;;   * the string change functions
  ;;     (`c-before-change-check-unbalanced-strings',
  ;;     `c-after-change-mark-abnormal-strings',
  ;;     `c-after-change-escape-NL-in-string', `c-pps-to-string-delim',
  ;;     the ml-string fence machinery and the `c-open-string-opener'
  ;;     variable they maintain);
  ;;   * `c-depropertize-CPP', `c-neutralize-syntax-in-CPP',
  ;;     `c-before/after-change-fix-comment-escapes',
  ;;     `c-parse-quotes-after-change',
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
    (only (schemacs core syntax-macros) when-e while-e setq)
    (only (schemacs buffer) current-buffer buffer-local-value
          set-buffer-local-value!)
    (only (schemacs marker) copy-marker set-marker marker-position)
    (only (schemacs editfns) point point-max point-min goto-char
          bobp eobp char-before char-after buffer-substring-no-properties
          save-excursion)
    (only (schemacs search) looking-at match-end match-beginning
          re-search-forward save-match-data)
    (only (schemacs syntax) skip-syntax-backward skip-chars-backward
          parse-partial-sexp)
    (only (schemacs cmds) backward-char forward-char)
    (only (schemacs progmodes cc-defs)
          c-search-forward-non-nil-char-property
          c-search-forward-char-property c-search-backward-char-property
          c-search-backward-char-property-with-value-on-char
          c-clear-char-property c-get-char-property c-put-char-property
          c-clear-char-properties c-clear-char-property-with-value
          c-min-property-position c-next-single-property-change
          c-previous-single-property-change
          c-<-as-paren-syntax c->-as-paren-syntax
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
          c-point c-is-escaped c-benign-error
          c-literal-limits c-literal-type
          c-truncate-lit-pos/state-cache
          c-put-syntax-table-trim-caches c-clear-syntax-table-trim-caches
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
   c-clear-string-fences c-restore-string-fences c-remove-string-fences)

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
    ;; `c-with-string-fences'` seams (`cc-defs.el:1774')
    ;; ---------------------------------------------------------------
    ;; `cc-defs' is below this library and cannot reach these two, so it
    ;; reads them through parameters; install them as this library loads,
    ;; as `keyboard.scm' installs its seam.
    (*c-restore-string-fences-function* c-restore-string-fences)
    (*c-clear-string-fences-function* c-clear-string-fences)

    ))
