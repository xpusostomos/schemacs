(define-library (schemacs editor cc-engine)
  ;; `lisp/progmodes/cc-engine.el' - the parser. The file is 16,747
  ;; lines and this library is the part of it ported so far, in the C's
  ;; own order:
  ;;
  ;;   * the internal state variables (`c-hungry-delete-key',
  ;;     `c-electric-flag', `c-auto-newline') and `c-calculate-state';
  ;;   * the preprocessor-directive machinery: the `c-macro-cache'
  ;;     family, `c-query-and-set-macro-start', `c-query-macro-start',
  ;;     `c-invalidate-macro-cache', `c-macro-is-genuine-p',
  ;;     `c-beginning-of-macro', `c-end-of-macro',
  ;;     `c-syntactic-end-of-macro', `c-no-comment-end-of-macro',
  ;;     `c-forward-over-cpp-define-id', `c-forward-to-cpp-define-body';
  ;;   * `c-forward-comment-minus-1' and `c-backward-single-comment'
  ;;     (`:1685', `:1704'), which `c-beginning-of-macro' stands on;
  ;;   * the comment and whitespace tools (`:1631'-`:1790'), the
  ;;     `c-is-sws'/`c-in-sws' property helpers and the literal-position
  ;;     machinery (`:2700'-`:3270');
  ;;   * the syntactic-whitespace engine (`:1947'-`:2694':
  ;;     `c-forward-sws', `c-backward-sws', the change hooks,
  ;;     `c-looking-at-c++-attribute', `c-forward-syntactic-ws'/
  ;;     `c-backward-syntactic-ws');
  ;;   * **the state cache (`:3250'-`:4850')**: `c-parse-state' and
  ;;     everything it stands on - the caches (`c-state-cache' and its
  ;;     good/invalid positions, the non-literal cache, the brace-pair
  ;;     desert), `c-remove-stale-state-cache' and its backwards twin,
  ;;     `c-append-to-state-cache', `c-append-lower-brace-pair-to-state-
  ;;     cache', the narrowing adjustment, `c-invalidate-state-cache'
  ;;     and the enclosing-brace queries;
  ;;   * the basic utilities: `c-delq-from-dotted-list',
  ;;     `c-shift-line-indentation', `c-keyword-sym'/`c-keyword-member',
  ;;     the string-syntax constants, `c-parsing-error' and
  ;;     `c-echo-parsing-error', `c-put-c-type-property' and
  ;;     `c-clear-c-type-property';
  ;;   * `c-looking-at-c++-attribute', `c-syntactic-content', the token
  ;;     boundaries and movement (`:4852'-`:5581'), the `c-determine-
  ;;     limit' family (`:5864'-`:6012'), the statement barriers, the
  ;;     statement-start predicates, `c-looking-at-special-brace-list',
  ;;     `c-in-method-def-p' and `c-looking-at-inexpr-block';
  ;;   * `c-beginning-of-statement-1' (`:793') and its automaton, and
  ;;     the virtual-semicolon macros (`:14184'-`:14243').
  ;;   * **the found-type table (`:6880'-`:6955')** and **the
  ;;     declaration engine's forward direction (`:8424'-`:9860'`)**:
  ;;     `c-forward-keyword-clause' and its two helpers,
  ;;     `c-forward-<>-arglist' (+ recur and `c-backward-<>-arglist'),
  ;;     `c-forward-name', `c-forward-type', `c-forward-annotation' and
  ;;     the compound-identifier walkers. `c-fontify-new-found-type' is
  ;;     `cc-fonts.el''s and arrives through
  ;;     `*c-fontify-new-found-type-function*', which does nothing until
  ;;     that library lands.
  ;;   * **the declarator (`:9855'-`:10310')**:
  ;;     `c-back-over-member-initializer-braces', `c-forward-class-decl',
  ;;     the C++20 constraint machinery (`c-forward-primary-expression',
  ;;     `c-forward-constraint-clause',
  ;;     `c-forward-c++-requires-clause'), `c-in-id-arglist',
  ;;     `c-forward-decl-arglist' and `c-forward-declarator'.
  ;;   * `c-back-over-member-initializers' (`:9911'), with Emacs's
  ;;     `c-back-over-list-of-member-inits' macro (`:9885') as a local
  ;;     procedure.
  ;;   * **the declaration decision (`:10379'-`:14250')**:
  ;;     `c-do-declarators', `c-forward-decl-or-cast-1' (with the two
  ;;     `c-fdoc-' helpers as local procedures), `c-forward-objc-
  ;;     directive', `c-at-toplevel-p', `c-just-after-func-arglist-p',
  ;;     `c-looking-at-decl-block', `c-directly-in-class-called-p',
  ;;     `c-search-uplist-for-classkey', the statement-block walkers
  ;;     (`c-looking-at-statement-block-1', `c-looking-at-statement-
  ;;     block') and the C++ lambda machinery
  ;;     (`c-looking-at-c++-lambda-expression',
  ;;     `c-backward-over-lambda-expression').
  ;;
  ;;   * **the label scan and the K&R/declaration-header cluster
  ;;     (`:11817'-`:12741')**: `c-forward-label', `c-in-knr-argdecl',
  ;;     `c-skip-conditional', `c-after-conditional',
  ;;     `c-after-special-operator-id', the two anchors,
  ;;     `c-search-decl-header-end', `c-beginning-of-decl-1' and
  ;;     `c-end-of-decl-1'.
  ;;
  ;;   * **the `<'-`>' pair properties and their change functions
  ;;     (`:7035'-`:7537')**: `c-clear-<-pair-props' and its siblings,
  ;;     `c-end-of-literal', `c-unmark-<>-around-region',
  ;;     `c-before-change-check-<>-operators',
  ;;     `c-after-change-check-<>-operators', `c-<>-get-restricted',
  ;;     `c-restore-<>-properties', and the two ml-string helpers
  ;;     `c-end-of-literal' stands on. `cc-mode.el''s change hooks are
  ;;     not ported: `c-common-init''s "Starting a mode is a sort of
  ;;     change" block is what runs `c-restore-<>-properties' over the
  ;;     buffer in Emacs, and the tests replay that by hand.
  ;;
  ;; Still to come, in the file's order: the multi-line-string change
  ;; machinery (`c-before-change-check-ml-strings' and the ~700 lines
  ;; after it, `:7863'-`:8386'); the Objective-C, GCC-asm and concept
  ;; helpers between it and the indent engine; the debug overlay helpers
  ;; (they need the overlay API this library does not want); and the
  ;; whole indentation-analysis section at the file's end
  ;; (`c-add-syntax', `c-guess-basic-syntax', `c-evaluate-offset',
  ;; `c-get-syntactic-indentation'), which comes with cc-align/cc-cmds.
  ;;
  ;; **Placement departures**, all forced by the import graph and named
  ;; where each function is defined:
  ;;
  ;;   * `c-point' and `c-is-escaped' are `cc-defs.el''s, but their
  ;;     BODY/EOD/BOSWS/EOSWS arms call `cc-engine''s own functions, and
  ;;     Emacs reaches them through the obarray. `(schemacs editor
  ;;     cc-defs)' sits below this library and cannot call up to it, so
  ;;     both live here. Their BOL/BOLL/EOL/EOLL/BOI/IOPL/IONL/BOPL/
  ;;     BONL/EOPL/EONL arms are complete; BOD/EOD/BOSWS/EOSWS signal
  ;;     until `c-beginning-of-defun-1', `c-end-of-defun-1' and the
  ;;     syntactic-whitespace engine land, and each error names what it
  ;;     waits for.
  ;;   * `c-benign-error' is `cc-defs.el''s macro; it needs `message',
  ;;     which is `editfns.scm''s here - above `cc-defs' - so it lives
  ;;     in this library. Emacs's second half, `(ding)', is not ported
  ;;     anywhere in this tree yet, so the echo-area message is the whole
  ;;     of it (named departure, the same one `novice.scm' carries).
  ;;
  ;; **Representation departures**, the tree's usual ones:
  ;;
  ;;   * a buffer-local variable is a buffer-local slot behind an
  ;;     accessor of the variable's name and a `set!'-prefixed setter
  ;;     (`c-macro-cache', `set!c-macro-cache'), as in `cc-vars.scm';
  ;;   * `c-macro-start' is a `defvar' that callers `let'-bind, so it is
  ;;     a parameter, `*c-macro-start*' - including the self-rebind in
  ;;     `c-shift-line-indentation', which is `parameterize';
  ;;   * a language variable is read with `%c-langvar', the buffer-local
  ;;     slot `c-init-language-vars' fills (keyed by the Emacs symbol).
  ;;
  ;; **`c-keyword-sym'/`c-keyword-member' and the obarray.** Emacs builds
  ;; `c-keywords-obarray' per language - `(cc-langs.el:3663')'s
  ;; `c-lang-defvar' makes an obarray whose symbols carry the `*-kwds'
  ;; membership on their plists - and `intern-soft'/`get' are the whole
  ;; of the two functions. This tree has neither an obarray nor symbol
  ;; values, so the pair builds one hash table from the *current
  ;; buffer's* `c-keyword-member-alist' on first use, keyed by the
  ;; keyword string, and `c-keyword-member' looks the language constant
  ;; up there. The answers are the same; what differs is that the symbol
  ;; `c-keyword-sym' answers is an ordinary interned symbol rather than
  ;; one private to the language's obarray, so two languages' symbols for
  ;; the same keyword are `eq?' here and are not in Emacs. The table is
  ;; cached on the identity of the alist it was built from, which is the
  ;; per-language value, so switching languages rebuilds it.
  (import
    (scheme base)
    (only (guile) most-positive-fixnum make-hash-table hash-ref hash-set!
                  hash-for-each hash-remove! 1- 1+ logand caddr cdddr cadddr
                  cddddr while sort string<? hash-map->list)
    (only (schemacs editor subr) regexp-unmatchable)
    (only (schemacs editor buffer) current-buffer buffer-local-value
          set-buffer-local-value! *case-fold-search*)
    (only (schemacs editor command) prefix-numeric-value quit-condition?)
    (only (schemacs editor cmds) beginning-of-line end-of-line forward-char
          backward-char delete-char)
    (only (schemacs editor editfns) point point-min point-max goto-char
          char-before char-after bobp eobp bolp eolp
          line-beginning-position line-end-position forward-line
          save-excursion save-restriction narrow-to-region widen
          insert delete-region message format-message buffer-size
          buffer-substring buffer-substring-no-properties)
    (only (schemacs editor fns) nth nthcdr %substring %count-lines nconc
          concat)
    (only (schemacs editor eval) funcall)
    (only (schemacs editor indent) back-to-indentation)
    (only (schemacs editor indentc) current-indentation indent-to
          current-column)
    ;; `c-literal-faces' asks `facep' of the comment-delimiter face.
    (only (schemacs editor faces) facep)
    ;; The Emacs macros the find-decl machinery is written with: the
    ;; `-e' forms are used only where Emacs's answer is observable.
    (only (schemacs syntax) setq push prog1 when-e dolist)
    (only (schemacs editor search) re-search-forward re-search-backward
          search-forward looking-at string-match regexp-quote
          match-beginning match-end match-string match-string-no-properties
          save-match-data)
    (only (schemacs editor textprop) get-text-property put-text-property
          remove-text-properties text-property-any)
    (only (schemacs editor syntax) skip-chars-backward skip-chars-forward
          skip-syntax-backward skip-syntax-forward forward-comment
          parse-partial-sexp scan-sexps scan-lists char-syntax
          *open-paren-in-column-0-is-defun-start*)
    (only (schemacs editor subr) regexp-unmatchable last delq copy-tree
          intern with-silent-modifications remq butlast)
    (only (schemacs editor cc-defs) c-emacs-features c-save-buffer-state
          c-put-char-property c-clear-char-property c-get-char-property
          c-put-char-properties c-clear-char-properties
          c-put-string-fence c-search-forward-non-nil-char-property
          c-<-as-paren-syntax c->-as-paren-syntax
          c-next-single-property-change c-previous-single-property-change
          c-got-face-at
          %c-true %c-false c-get-lang-constant *c-buffer-is-cc-mode*
          c-major-mode-is c-safe c-forward-sexp c-backward-sexp
          c-go-list-forward c-go-list-backward c-down-list-backward
          c-up-list-forward c-down-list-forward c-go-up-list-forward
          c-go-up-list-backward
          c-skip-ws-chars-forward
          c-skip-ws-chars-backward c-skip-ws-forward c-skip-ws-backward
          c-with-syntax-table
          c-mark-<-as-paren c-mark->-as-paren c-unmark-<-or->-as-paren
          c-suppress-<->-as-parens c-restore-<->-as-parens
          c-make-keywords-re
          *c-lang-var-overrides*)
    (only (schemacs editor marker)
          make-marker set-marker marker-position markerp)
    (only (schemacs editor lisp) beginning-of-defun forward-sexp
          *defun-prompt-regexp* *beginning-of-defun-function*
          *end-of-defun-function*)
    (only (schemacs editor intervals) get)
    (only (schemacs editor cc-vars) *c-report-syntactic-errors*
          c-macro-with-semi-re
          c-noise-macro-name-re c-noise-macro-with-parens-name-re))

  (export
   ;; `cc-engine.el:6880'-`:6955': the found-type table
   c-found-types set!c-found-types
   c-new-id-start set!c-new-id-start c-new-id-end set!c-new-id-end
   c-new-id-is-type set!c-new-id-is-type
   c-clear-found-types c-add-type-1 c-add-type c-unfind-type c-check-type
   *c-fontify-new-found-type-function*
   c-list-found-types c-maybe-stale-found-type set!c-maybe-stale-found-type
   c-trim-found-types
   ;; `cc-engine.el:7035'-`:7660': the `<'-`>' pair properties, the
   ;; change functions that keep them, and the two ml-string helpers
   ;; `c-end-of-literal' stands on
   c-clear-<-pair-props c-clear->-pair-props c-clear-<>-pair-props
   c-clear-<-pair-props-if-match-after c-clear->-pair-props-if-match-before
   c-new-BEG set!c-new-BEG c-new-END set!c-new-END
   c-end-of-literal c-unmark-<>-around-region
   c-before-change-check-<>-operators c-after-change-check-<>-operators
   c-<>-get-restricted c-restore-<>-properties
   c-ml-string-make-closer-re c-c++-make-ml-string-closer-re
   c-ml-string-opener-at-or-around-point
   ;; `cc-engine.el:5805'-`:7000': the find-decl machinery and the
   ;; brace stack
   c-literal-faces c-collect-line-comments
   c-literal-start c-determine-limit c-beginning-of-decl-1
   %c-langvar
   c-get-ml-closer c-ml-string-opener-around-point
   c-find-decl-syntactic-pos set!c-find-decl-syntactic-pos
   c-find-decl-match-pos set!c-find-decl-match-pos
   c-invalidate-find-decl-cache c-debug-put-decl-spot-faces
   c-bs-cache set!c-bs-cache c-bs-cache-limit set!c-bs-cache-limit
   c-bs-prev-pos set!c-bs-prev-pos c-bs-prev-stack set!c-bs-prev-stack
   c-init-bs-cache c-truncate-bs-cache c-update-brace-stack
   c-brace-stack-at c-bs-at-toplevel-p
   c-find-decl-prefix-search
   *cfd-limit* *cfd-prop-match* *cfd-re-match* *cfd-re-match-end*
   *cfd-match-pos* *cfd-continue-pos* *cfd-top-level*
   c-find-decl-spots
   ;; the declaration engine's dynamic variables (`cc-engine.el:8424')
   *c-promote-possible-types* *c-parse-and-markup-<>-arglists*
   *c-restricted-<>-arglists* *c-record-type-identifiers*
   *c-record-ref-identifiers* *c-record-found-types*
   *c-last-identifier-range* c-record-type-id c-record-ref-id
   ;; `cc-engine.el:8646'-`:9860': the declaration engine
   c-forward-align-clause-throw-if-invalid c-forward-keyword-clause
   c-forward-keyword-prefixed-id c-forward-id-comma-list
   c-forward-<>-arglist c-forward-<>-arglist-recur c-backward-<>-arglist
   c-forward-name c-forward-type c-forward-annotation
   c-forward-over-compound-identifier c-back-over-compound-identifier
   c-check-qualified-type
   ;; `cc-engine.el:9855'-`:10310': the member-initializer brace walk,
   ;; the C++20 constraint machinery and the declarator
   c-back-over-member-initializer-braces c-forward-class-decl
   c-forward-primary-expression c-forward-constraint-clause
   c-forward-c++-requires-clause c-in-id-arglist
   c-forward-decl-arglist c-forward-declarator
   ;; state variables and the mode-line sub-state calculation
   c-hungry-delete-key set!c-hungry-delete-key
   c-electric-flag set!c-electric-flag
   c-auto-newline set!c-auto-newline
   c-calculate-state
   ;; the preprocessor-directive machinery
   *c-macro-start* c-query-and-set-macro-start c-query-macro-start
   c-macro-cache set!c-macro-cache
   c-macro-cache-start-pos set!c-macro-cache-start-pos
   c-macro-cache-syntactic set!c-macro-cache-syntactic
   c-macro-cache-no-comment set!c-macro-cache-no-comment
   c-invalidate-macro-cache c-macro-is-genuine-p
   c-beginning-of-macro c-end-of-macro
   c-syntactic-end-of-macro c-no-comment-end-of-macro
   c-forward-over-cpp-define-id c-forward-to-cpp-define-body
   c-forward-single-comment c-forward-comments
   c-forward-comment-minus-1 c-backward-single-comment c-backward-comments
   ;; basic utilities
   c-delq-from-dotted-list c-syntactic-content c-shift-line-indentation
   c-keyword-sym c-keyword-member
   c-string-syntax c-string-limit-regexp c-ws*-string-limit-regexp
   c-parsing-error set!c-parsing-error c-echo-parsing-error
   c-put-c-type-property c-clear-c-type-property
   c-simple-skip-symbol-backward c-beginning-of-current-token
   c-put-is-sws c-put-in-sws c-remove-is-sws c-remove-in-sws
   c-remove-is-and-in-sws c-debug-sws-msg
   c-sws-lit-type c-sws-lit-limits c-enclosing-c++-attribute
   c-looking-at-c++-attribute
   c-invalidate-sws-region-before c-invalidate-sws-region-after
   c-invalidate-sws-region-after-del c-invalidate-sws-region-after-ins
   c-forward-sws c-backward-sws c-partial-ws-p
   c-forward-syntactic-ws c-backward-syntactic-ws
   c-doc-line-join-re set!c-doc-line-join-re
   c-doc-bright-comment-start-re set!c-doc-bright-comment-start-re
   c-doc-line-join-end-ch set!c-doc-line-join-end-ch
   c-state-nonlit-pos-interval
   c-lit-pos-cache set!c-lit-pos-cache
   c-lit-pos-cache-limit set!c-lit-pos-cache-limit
   c-semi-lit-near-cache set!c-semi-lit-near-cache
   c-semi-near-cache-limit set!c-semi-near-cache-limit
   c-full-lit-near-cache set!c-full-lit-near-cache
   c-full-near-cache-limit set!c-full-near-cache-limit
   c-cache-to-parse-ps-state c-parse-ps-state-to-cache
   c-ps-state-cache-pos c-trim-lit-pos-cache c-parse-ps-state-below
   c-semi-trim-near-cache c-semi-get-near-cache-entry
   c-semi-put-near-cache-entry c-semi-pp-to-literal
   c-full-trim-near-cache c-full-get-near-cache-entry
   c-full-put-near-cache-entry c-full-pp-to-literal
   c-truncate-lit-pos-cache
   c-literal-limits c-literal-start c-literal-type c-in-literal
   %c-car %c-cdr %c-cadr %c-cddr %c-caddr
   ;; cc-defs.el's, placed here because they call down from Emacs' obarray
   c-point c-is-escaped c-benign-error
   ;; statement barriers (`cc-engine.el:1457')
   *c-maybe-labelp* *c-commas-bound-stmts* c-punctuation-in
   c-crosses-statement-barrier-p c-beginning-of-statement-1
   ;; `cc-engine.el:12171' and `:13917'
   c-in-method-def-p c-looking-at-inexpr-block
   ;; token movement (`cc-engine.el:4947')
   c-jump-syntax-balanced c-jump-syntax-unbalanced
   c-end-of-token c-end-of-current-token c-forward-over-token
   c-forward-over-token-and-ws c-forward-token-2 c-backward-token-2
   c-forward-token-1 c-backward-token-1
   ;; the statement-start predicates (`cc-engine.el:1562')
   c-at-statement-start-p c-at-expression-start-p
   ;; syntactic searches and scans (`cc-engine.el:4852'-`:6012')
   c-on-identifier c-syntactic-re-search-forward c-syntactic-skip-backward
   c-determine-limit c-determine-limit-no-macro c-determine-limit-get-base
   c-determine-+ve-limit
   ;; `cc-engine.el:13584'
   c-looking-at-special-brace-list
   ;; `cc-engine.el:8567'-`:8644'
   c-forward-noise-clause c-forward-noise-clause-not-macro-decl
   c-forward-over-colon-type-list
   ;; `cc-engine.el:14101'
   c-looking-at-c++-lambda-capture-list
   ;; virtual semicolons (`cc-engine.el:14184')
   c-at-vsemi-p c-vsemi-status-unknown-p
   c-c++-vsemi-p c-at-macro-vsemi-p c-macro-vsemi-status-unknown-p
   ;; the state cache (`cc-engine.el:3250'-`:4850')
   c-state-cache set!c-state-cache
   c-state-cache-good-pos set!c-state-cache-good-pos
   c-state-cache-invalid-pos set!c-state-cache-invalid-pos
   c-state-nonlit-pos-cache set!c-state-nonlit-pos-cache
   c-state-nonlit-pos-cache-limit set!c-state-nonlit-pos-cache-limit
   c-state-point-min set!c-state-point-min
   c-state-point-min-lit-type set!c-state-point-min-lit-type
   c-state-point-min-lit-start set!c-state-point-min-lit-start
   c-state-min-scan-pos set!c-state-min-scan-pos
   c-state-brace-pair-desert set!c-state-brace-pair-desert
   c-state-old-cpp-beg set!c-state-old-cpp-beg
   c-state-old-cpp-end set!c-state-old-cpp-end
   c-state-old-cpp-beg-marker set!c-state-old-cpp-beg-marker
   c-state-old-cpp-end-marker set!c-state-old-cpp-end-marker
   c-debug-parse-state set!c-debug-parse-state
   c-state-cache-too-far
   c-state-pp-to-literal c-state-safe-place c-state-literal-at c-state-lit-beg
   c-state-cache-lower-good-pos c-state-get-min-scan-pos
   c-state-mark-point-min-literal
   c-state-cache-top-lparen c-state-cache-top-paren
   c-state-cache-after-top-paren
   c-get-cache-scan-pos c-beginning-of-defun-1 c-get-fallback-scan-pos
   c-state-balance-parens-backwards c-parse-state-get-strategy
   c-renarrow-state-cache c-append-lower-brace-pair-to-state-cache
   c-state-push-any-brace-pair c-append-to-state-cache
   c-remove-stale-state-cache c-remove-stale-state-cache-backwards
   c-state-cache-init c-truncate-lit-pos/state-cache
   c-foreign-truncate-lit-pos-cache c-foreign-init-lit-pos-cache
   c-invalidate-state-cache-1 c-parse-state-1
   c-invalidate-state-cache c-parse-state
   c-whack-state-before c-whack-state-after
   c-most-enclosing-brace c-least-enclosing-brace c-safe-position
   c-beginning-of-syntax
   ;; `cc-engine.el:10379'-`:14250': the declarator list, the
   ;; declaration-or-cast decision, the declaration block, the
   ;; statement-block walkers and the C++ lambda machinery
   c-back-over-member-initializers
   c-do-declarators c-forward-decl-or-cast-1 c-forward-objc-directive
   c-at-toplevel-p c-just-after-func-arglist-p c-pull-open-brace
   c-looking-at-decl-block c-directly-in-class-called-p
   c-search-uplist-for-classkey
   c-looking-at-statement-block-1 c-looking-at-statement-block
   c-looking-at-c++-lambda-expression c-backward-over-lambda-expression
   ;; `cc-engine.el:11817'-`:12741': the label scan, the K&R argument
   ;; declarations and the declaration header
   c-forward-label c-in-knr-argdecl c-skip-conditional
   c-after-conditional c-after-special-operator-id
   c-backward-to-block-anchor c-backward-to-decl-anchor
   c-search-decl-header-end c-beginning-of-decl-1 c-end-of-decl-1
   ;; `cc-engine.el:12966'-`:13582': the declaration-block queries and
   ;; the brace list
   c-most-enclosing-decl-block c-cheap-inside-bracelist-p
   c-backward-typed-enum-colon c-backward-over-enum-header
   c-at-enum-brace c-laomib-loop
   c-laomib-cache set!c-laomib-cache
   c-laomib-get-cache c-laomib-put-cache c-laomib-fix-elt
   c-laomib-invalidate-cache
   c-looking-at-or-maybe-in-bracelist
   c-no-bracelist-cache set!c-no-bracelist-cache
   c-strip-conses c-at-bracelist-p)

  (begin

    ;;------------------------------------------------------------------
    ;; Internal state variables (`cc-engine.el:204')
    ;;------------------------------------------------------------------
    ;; A buffer-local variable is a slot behind these, as `cc-vars.scm'
    ;; does it. The accessors answer the variable's *default* when the
    ;; buffer has no slot of its own, which is what Emacs's
    ;; `make-variable-buffer-local' means by the buffer-local variable
    ;; sharing the global's value until it is set.
    (define (c-hungry-delete-key)
      (buffer-local-value (current-buffer) 'c-hungry-delete-key #f))
    (define (set!c-hungry-delete-key value)
      (set-buffer-local-value! (current-buffer) 'c-hungry-delete-key value))

    (define (c-electric-flag)
      (buffer-local-value (current-buffer) 'c-electric-flag #t))
    (define (set!c-electric-flag value)
      (set-buffer-local-value! (current-buffer) 'c-electric-flag value))

    (define (c-auto-newline)
      (buffer-local-value (current-buffer) 'c-auto-newline #f))
    (define (set!c-auto-newline value)
      (set-buffer-local-value! (current-buffer) 'c-auto-newline value))

    (define (%c-langvar symbol)
      ;; A language variable's value in the current buffer: the
      ;; buffer-local slot `c-init-language-vars' fills, keyed by the
      ;; Emacs symbol (see `cc-langs.scm''s representation note). #f
      ;; when the mode has not initialised this buffer, where Emacs's
      ;; `symbol-value' would say "Void variable". An Emacs `let' of a
      ;; language variable is `*c-lang-var-overrides*' - the slot has no
      ;; symbol value for a `let' to bind - so the override comes first,
      ;; which is where Emacs's dynamic binding would be read too.
      (let ((override (assq symbol (*c-lang-var-overrides*))))
        (if override
            (cdr override)
            (buffer-local-value (current-buffer) symbol #f))))

    (define (c-calculate-state arg prevstate)
      ;; "Calculate the new state of PREVSTATE, t or nil, based on arg.
      ;; If arg is nil or zero, toggle the state. If arg is negative,
      ;; turn the state off, and if arg is positive, turn the state on"
      ;; (`cc-engine.el:223').
      ;;
      ;; Emacs's `(setq arg (prefix-numeric-value arg))' inside the test
      ;; is a `set!' there was no value to read here, so the computed
      ;; number is a `let'.
      (if (%c-false arg)
          (not prevstate)
          (let ((n (prefix-numeric-value arg)))
            (if (zero? n)
                (not prevstate)
                (> n 0)))))

    ;;------------------------------------------------------------------
    ;; Basic handling of preprocessor directives (`cc-engine.el:238')
    ;;------------------------------------------------------------------
    ;; "A dynamically bound cache used together with `c-query-macro-start'
    ;; and `c-query-and-set-macro-start'. It only works as long as point
    ;; doesn't cross a macro boundary." Emacs `let'-binds it, so it is a
    ;; parameter (the tree's rule for a dynamically bound variable).
    (define *c-macro-start* (make-parameter 'unknown))

    (define (c-query-and-set-macro-start)
      ;; `cc-engine.el:247'.
      (if (symbol? (*c-macro-start*))
          (*c-macro-start*
           (save-excursion
             (c-save-buffer-state ()
               (if (c-beginning-of-macro) (point) #f))))
          (*c-macro-start*)))

    (define (c-query-macro-start)
      ;; `cc-engine.el:255'.
      (if (symbol? (*c-macro-start*))
          (save-excursion
            (c-save-buffer-state ()
              (if (c-beginning-of-macro) (point) #f)))
          (*c-macro-start*)))

    ;; "One element macro cache to cope with continual movement within
    ;; very large CPP macros." Nil or a cons of the bounds of the most
    ;; recent CPP form probed by `c-beginning-of-macro', `c-end-of-macro'
    ;; or `c-syntactic-end-of-macro'; the cdr is nil when only the start
    ;; is known. When the cache is `(START . nil)' the cdr is the empty
    ;; list here, as Emacs's nil is.
    (define (c-macro-cache)
      (buffer-local-value (current-buffer) 'c-macro-cache #f))
    (define (set!c-macro-cache value)
      (set-buffer-local-value! (current-buffer) 'c-macro-cache value))

    (define (c-macro-cache-start-pos)
      (buffer-local-value (current-buffer) 'c-macro-cache-start-pos #f))
    (define (set!c-macro-cache-start-pos value)
      (set-buffer-local-value! (current-buffer) 'c-macro-cache-start-pos value))

    ;; "Either nil, or the syntactic end of the macro currently
    ;; represented by `c-macro-cache'."
    (define (c-macro-cache-syntactic)
      (buffer-local-value (current-buffer) 'c-macro-cache-syntactic #f))
    (define (set!c-macro-cache-syntactic value)
      (set-buffer-local-value! (current-buffer) 'c-macro-cache-syntactic value))

    ;; "Either nil, or the position of a comment which is open at the
    ;; end of the macro represented by `c-macro-cache'."
    (define (c-macro-cache-no-comment)
      (buffer-local-value (current-buffer) 'c-macro-cache-no-comment #f))
    (define (set!c-macro-cache-no-comment value)
      (set-buffer-local-value! (current-buffer) 'c-macro-cache-no-comment value))

    (define (c-invalidate-macro-cache beg end)
      ;; "Called from a before-change function. If the change region is
      ;; before or in the macro characterized by `c-macro-cache' etc.,
      ;; nullify it appropriately. BEG and END are the standard
      ;; before-change-functions parameters. END isn't used."
      (let ((cache (c-macro-cache)))
        (cond
         ((not cache) #f)
         ((<= beg (car cache))
          (set!c-macro-cache #f)
          (set!c-macro-cache-start-pos #f)
          (set!c-macro-cache-syntactic #f)
          (set!c-macro-cache-no-comment #f))
         ((and (cdr cache) (< beg (cdr cache)))
          (set-cdr! cache '())
          (set!c-macro-cache-start-pos beg)
          (set!c-macro-cache-syntactic #f)
          (set!c-macro-cache-no-comment #f))
         ((and (c-macro-cache-start-pos)
               (< beg (c-macro-cache-start-pos)))
          (set!c-macro-cache-start-pos beg)
          (set!c-macro-cache-syntactic #f)
          (set!c-macro-cache-no-comment #f)))))

    (define (c-macro-is-genuine-p)
      ;; "Check that the ostensible CPP construct at point is a real one.
      ;; In particular, if point is on the first line of a narrowed
      ;; buffer, make sure that the \"#\" isn't, say, the second
      ;; character of a \"##\" operator. Return t when the macro is real,
      ;; nil otherwise."
      (let ((here (point)))
        (beginning-of-line)
        (let ((answer
               (if (and (= (point) (point-min)) (not (= (point) 1)))
                   (save-restriction
                     (widen)
                     (beginning-of-line)
                     (if (and (looking-at (%c-langvar 'c-anchored-cpp-prefix))
                              (= (match-beginning 1) here))
                         #t
                         #f))
                   #t)))
          (goto-char here)
          answer)))

    (define (c-beginning-of-macro . lim-args)
      ;; "Go to the beginning of a preprocessor directive. Leave point at
      ;; the beginning of the directive and return t if in one, otherwise
      ;; return nil and leave point unchanged."
      ;;
      ;; LIM is Emacs's `&optional'; the tree's spelling is a rest
      ;; parameter, as every optional argument here is.
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (let ((here (point))
              (pause (line-end-position)))
          (if (not (%c-langvar 'c-opt-cpp-prefix))
              #f
              (let ((cache (c-macro-cache)))
                (if (and (pair? cache)
                         (car cache)
                         (>= (point) (car cache))
                         (or (and (%c-true (cdr cache))
                                  (<= (point) (cdr cache)))
                             (<= (point) (c-macro-cache-start-pos))))
                    (if (< (car cache) (or lim (point-min)))
                        #f
                        (begin
                          (goto-char (max (or lim (point-min)) (car cache)))
                          (set!c-macro-cache-start-pos
                           (max (c-macro-cache-start-pos) here))
                          #t))
                    (begin
                      (set!c-macro-cache #f)
                      (set!c-macro-cache-start-pos #f)
                      (set!c-macro-cache-syntactic #f)
                      (set!c-macro-cache-no-comment #f)

                      (save-restriction
                        (if lim (narrow-to-region lim (point-max)))
                        (beginning-of-line)
                        (when (or (not lim) (>= here lim))
                          (save-match-data
                            ;; "Note the similarity of the code here to
                            ;; some in `c-backward-sws'."
                            (let loop ()
                              (let ((more
                                     (begin
                                       (let cont ()
                                         (if (eq? (char-before (1- (point)))
                                                  #\\)
                                             (begin (forward-line -1) (cont))
                                             #f))
                                       (let ((re (%c-langvar
                                                  'c-last-c-comment-end-on-line-re)))
                                         (if (and re
                                                  (re-search-forward re pause #t))
                                             (begin
                                               (goto-char (match-end 1))
                                               (if (c-backward-single-comment)
                                                   (begin
                                                     (beginning-of-line)
                                                     (set! pause (point))
                                                     #t)
                                                   (begin
                                                     (goto-char pause)
                                                     #f)))
                                             #f)))))
                                (if more (loop) #f)))))

                        (back-to-indentation)
                        (if (and (<= (point) here)
                                 (save-match-data
                                   (looking-at (%c-langvar 'c-opt-cpp-start)))
                                 (c-macro-is-genuine-p))
                            (begin
                              (set!c-macro-cache (cons (point) '()))
                              (set!c-macro-cache-start-pos here)
                              (set!c-macro-cache-syntactic #f)
                              #t)
                            (begin
                              (goto-char here)
                              #f))))))))))

    (define (c-end-of-macro . lim-args)
      ;; "Go to the end of a preprocessor directive. More accurately,
      ;; move the point to the end of the closest following line that
      ;; doesn't end with a line continuation backslash - no check is
      ;; done that the point is inside a cpp directive to begin with,
      ;; although it is assumed that point isn't inside a comment or
      ;; string. If LIM is provided, it is a limit position at which
      ;; point is left if the end of the macro doesn't occur earlier."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (save-restriction
          (if lim (narrow-to-region (point-min) lim))
          (let ((cache (c-macro-cache)))
            (if (and (pair? cache) (%c-true (cdr cache))
                     (<= (point) (cdr cache))
                     (>= (point) (car cache)))
                (goto-char (cdr cache))
                (begin
                  (unless (and (pair? cache) (car cache)
                               (<= (point) (c-macro-cache-start-pos))
                               (>= (point) (car cache)))
                    (set!c-macro-cache #f)
                    (set!c-macro-cache-start-pos #f)
                    (set!c-macro-cache-syntactic #f)
                    (set!c-macro-cache-no-comment #f))
                  (save-match-data
                    ;; "Move over stuff followed by a multiline block
                    ;; comment lacking escaped newlines each time around
                    ;; this loop."
                    (let ((safe-pos (point))) ; a point outside any literal
                      (let loop ()
                        (let ((more
                               (begin
                                 ;; the line-continuation walk
                                 (let cont ()
                                   (end-of-line)
                                   (if (and (eq? (char-before) #\\)
                                            (not (eobp)))
                                       (begin (forward-char) (cont))
                                       #f))
                                 (let ((s (parse-partial-sexp safe-pos (point))))
                                   (if (and (%c-true (nth 4 s))
                                            (%c-false (nth 7 s)))
                                       (begin
                                         ;; "Move to after the block
                                         ;; comment."
                                         (parse-partial-sexp
                                          (point) (point-max) #f #f s
                                          'syntax-table)
                                         (set! safe-pos (point))
                                         #t)
                                       #f)))))
                          (if more (loop) #f)))

                      (when (and (pair? (c-macro-cache))
                                 (car (c-macro-cache))
                                 (> (point) (car (c-macro-cache)))
                                 (not lim))
                        (set-cdr! (c-macro-cache) (point))
                        (set!c-macro-cache-syntactic #f))))))))))

    (define (c-syntactic-end-of-macro)
      ;; "Go to the end of a CPP directive, or a \"safe\" pos just
      ;; before. This is normally the end of the next non-escaped line. A
      ;; \"safe\" position is one not within a string or comment. (The
      ;; EOL on a line comment is NOT \"safe\"). This function must only
      ;; be called from the beginning of a CPP construct."
      (let* ((here (point))
             (there (begin (c-end-of-macro) (point))))
        (if (c-macro-cache-syntactic)
            (goto-char (c-macro-cache-syntactic))
            (let ((s (parse-partial-sexp here there)))
              (let loop ()
                (if (and (or (%c-true (nth 3 s))
                             (and (%c-true (nth 4 s))
                                  (not (eq? (nth 7 s) 'syntax-table))))
                         (> there here))
                    (begin
                      (set! there (- (nth 8 s) 1))
                      (set! s (parse-partial-sexp here there))
                      (loop))
                    #f))
              (set!c-macro-cache-syntactic (point))))
        (point)))

    (define (c-no-comment-end-of-macro)
      ;; "Go to the start of the comment which is open at the end of the
      ;; current CPP directive, or to the end of that directive. For
      ;; this purpose, open strings are ignored. This function must only
      ;; be called from the beginning of a CPP construct."
      (let* ((here (point))
             (there (begin (c-end-of-macro) (point))))
        (if (c-macro-cache-no-comment)
            (goto-char (c-macro-cache-no-comment))
            (let ((s (parse-partial-sexp here there)))
              (let loop ()
                (if (and (%c-true (nth 3 s))
                         (> there here))
                    (begin
                      (set! here (+ (nth 8 s) 1))
                      (set! s (parse-partial-sexp here there))
                      (loop))
                    #f))
              (when (and (%c-true (nth 4 s))
                         (not (eq? (nth 7 s) 'syntax-table)))
                (goto-char (nth 8 s)))
              (set!c-macro-cache-no-comment (point))))
        (point)))

    (define (c-forward-over-cpp-define-id)
      ;; "Assuming point is at the \"#\" that introduces a preprocessor
      ;; directive, it's moved forward to the end of the identifier which
      ;; is \"#define\"d (or whatever `c-opt-cpp-macro-define'
      ;; specifies). Non-nil is returned in this case, in all other cases
      ;; nil is returned and point isn't moved."
      (let ((re (%c-langvar 'c-opt-cpp-macro-define-id)))
        (if (and re (looking-at re))
            (goto-char (match-end 0))
            #f)))

    (define (c-forward-to-cpp-define-body)
      ;; "Assuming point is at the \"#\" that introduces a preprocessor
      ;; directive, it's moved forward to the start of the definition
      ;; body if it's a \"#define\" (or whatever `c-opt-cpp-macro-define'
      ;; specifies). Non-nil is returned in this case, in all other
      ;; cases nil is returned and point isn't moved."
      (let ((re (%c-langvar 'c-opt-cpp-macro-define-start)))
        (if (and re
                 (looking-at re)
                 (not (= (match-end 0) (line-end-position))))
            (goto-char (match-end 0))
            #f)))

    ;;------------------------------------------------------------------
    ;; `c-forward-single-comment', `c-forward-comments',
    ;; `c-forward-comment-minus-1', `c-backward-single-comment' and
    ;; `c-backward-comments' (`cc-engine.el:1631'-`:1790')
    ;;------------------------------------------------------------------
    ;; This block is moved up from its place in the file: these are
    ;; what `c-beginning-of-macro' above stands on, and what the
    ;; syntactic-whitespace engine below stands on too.
    (define (c-forward-single-comment)
      ;; "Move forward past whitespace and the closest following
      ;; comment, if any. Return t if a comment was found, nil
      ;; otherwise. In either case, the point is moved past the
      ;; following whitespace. Line continuations, i.e. a backslashes
      ;; followed by line breaks, are treated as whitespace. The line
      ;; breaks that end line comments are considered to be the comment
      ;; enders, so the point will be put on the beginning of the next
      ;; line if it moved past a line comment."
      (let ((start (point)))
        (when (looking-at "\\([ \t\n\r\f\v]\\|\\\\[\n\r]\\)+")
          (goto-char (match-end 0)))
        (if (forward-comment 1)
            (if (eobp)
                ;; "Some emacsen (e.g. XEmacs 21) return t when moving
                ;; forwards at eob."
                #f
                (begin
                  ;; "Emacs includes the ending newline in a b-style
                  ;; (c++) comment, but XEmacs doesn't. We depend on
                  ;; the Emacs behavior (which also is symmetric)."
                  (if (and (eolp)
                           (%c-true (nth 7 (parse-partial-sexp start (point)))))
                      (forward-char 1))
                  #t))
            #f)))

    (define (c-forward-comments . lim-args)
      ;; "Move forward past all following whitespace and comments. Line
      ;; continuations, i.e. backslashes followed by line breaks, are
      ;; treated as whitespace. LIM, if non-nil, is a forward search
      ;; limit. If LIM is inside a comment, point may be left at LIM."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (save-restriction
          (if lim (narrow-to-region (point-min) lim))
          (let loop ()
            (let ((more (if (and (forward-comment 5) (not (eobp)))
                            #t
                            (if (looking-at "\\\\[\n\r]")
                                (begin (forward-char 2) #t)
                                #f))))
              (if more (loop) #f))))))

    (define (c-forward-comment-minus-1)
      ;; "Call (forward-comment -1), taking care of escaped newlines.
      ;; Return the result of `forward-comment' if it gets called, nil
      ;; otherwise."
      ;; Emacs's macro is two statements: the `if' and then the `cond'.
      (if (%c-false (%c-langvar 'comment-end-can-be-escaped))
          (forward-comment -1)
          (let ((dist (skip-syntax-backward " >")))
            (when (and (< dist 0)
                       (begin
                         (skip-syntax-forward " " (- (point) dist 1))
                         (eq? (char-after (point)) #\newline)))
              (forward-char))))
      (cond
       ((and (eq? (char-before) #\newline)
             (eq? (char-before (1- (point))) #\\))
        (backward-char)
        #f)
       (else (forward-comment -1))))

    (define (c-backward-single-comment)
      ;; "Move backward past whitespace and the closest preceding
      ;; comment, if any. Return t if a comment was found, nil otherwise.
      ;; In either case, the point is moved past the preceding
      ;; whitespace. Line continuations, i.e. a backslashes followed by
      ;; line breaks, are treated as whitespace. The line breaks that end
      ;; line comments are considered to be the comment enders, so the
      ;; point cannot be at the end of the same line to move over a line
      ;; comment."
      (let ((start (point)))
        ;; "When we got newline terminated comments, forward-comment in
        ;; all supported emacsen so far will stop at eol of each line not
        ;; ending with a comment when moving backwards. This corrects
        ;; for that, and at the same time handles line continuations."
        (let loop ()
          (when (begin
                  (skip-chars-backward " \t\n\r\f\v")
                  (and (looking-at "[\n\r]")
                       (eq? (char-before) #\\)))
            (backward-char)
            (loop)))
        (if (bobp)
            ;; "Some emacsen (e.g. Emacs 19.34) return t when moving
            ;; backwards at bob."
            #f
            (begin
              ;; "Leave point after the closest following newline if
              ;; we've backed up over any above, since forward-comment
              ;; won't move backward over a line comment if point is at
              ;; the end of the same line."
              (re-search-forward "\\=\\s *[\n\r]" start #t)

              (if (if (c-forward-comment-minus-1)
                      (if (eolp)
                          ;; "If forward-comment above succeeded and
                          ;; we're at eol then the newline we moved over
                          ;; above didn't end a line comment, so we give
                          ;; it another go."
                          (c-forward-comment-minus-1)
                          #t)
                      #f)
                  ;; "Emacs <= 20 and XEmacs move back over the closer
                  ;; of a block comment that lacks an opener."
                  (if (looking-at "\\*/")
                      (begin (forward-char 2) #f)
                      #t)
                  #f)))))

    (define (c-backward-comments)
      ;; "Move backward past all preceding whitespace and comments. Line
      ;; continuations, i.e. a backslashes followed by line breaks, are
      ;; treated as whitespace. The line breaks that end line comments
      ;; are considered to be the comment enders, so the point cannot be
      ;; at the end of the same line to move over a line comment.
      ;; Unlike `c-backward-syntactic-ws', this function doesn't move
      ;; back over preprocessor directives."
      (let ((start (point)))
        (let loop ()
          (if (and
               ;; "`forward-comment' in some emacsen (e.g. XEmacs
               ;; 21.4) return t when moving backwards at bob."
               (not (bobp))
               (if (let ((moved-comment #f))
                     ;; "Cope specifically with ^M^J here - forward-
                     ;; comment sometimes gets stuck after ^Ms,
                     ;; sometimes after ^M^J."
                     (let scan ()
                       (set! moved-comment (c-forward-comment-minus-1))
                       (if (and (not moved-comment)
                                (or (if (eq? (char-before) #\return)
                                        (begin (backward-char) #t)
                                        #f)
                                    (if (and (eq? (char-before) #\newline)
                                             (eq? (char-before (1- (point)))
                                                  #\return))
                                        (begin (backward-char 2) #t)
                                        #f)))
                           (scan)
                           #f))
                     moved-comment)
                   (if (looking-at "\\*/")
                       ;; "Emacs <= 20 and XEmacs move back over the
                       ;; closer of a block comment that lacks an
                       ;; opener."
                       (begin (forward-char 2) #f)
                       #t)
                   ;; "XEmacs treats line continuations as whitespace
                   ;; but only in the backward direction, which seems a
                   ;; bit odd. Anyway, this is necessary for Emacs."
                   (if (and (looking-at "[\n\r]")
                            (eq? (char-before) #\\)
                            (< (point) start))
                       (begin (backward-char) #t)
                       #f)))
              (loop)
              #f))))

    ;;------------------------------------------------------------------
    ;; Tools for skipping over syntactic whitespace (`cc-engine.el:1770')
    ;;------------------------------------------------------------------
    ;; The `c-is-sws'/`c-in-sws' property scheme, which `c-forward-sws'
    ;; and `c-backward-sws' (to come, at their place in the file) share:
    ;;
    ;;   * where a syntactic-whitespace region holds anything but simple
    ;;     whitespace, `c-in-sws' is put over it, and at the places the
    ;;     scan has stopped there is also `c-is-sws' - "a ladder where
    ;;     `c-in-sws' marks the bars and `c-is-sws' the rungs";
    ;;   * on buffer changes both are removed in the changed region
    ;;     (the `c-invalidate-sws-region-*' hooks, which arrive with
    ;;     `c-literal-limits'), so a later scan uses the parts either
    ;;     side and repairs the gap with an ordinary search.
    ;;
    ;; Emacs's macros put the properties under `with-silent-modifications'
    ;; at the call sites - the sws functions do that themselves - and
    ;; their optional debug faces are not carried (`facep' is not ported,
    ;; and no debug face is defined). `c-debug-sws-msg' is Emacs's
    ;; no-op-by-default message macro.
    (define (c-debug-sws-msg . args) #f)

    (define (c-put-is-sws beg end)
      (put-text-property beg end 'c-is-sws #t))
    (define (c-put-in-sws beg end)
      (put-text-property beg end 'c-in-sws #t))
    (define (c-remove-is-sws beg end)
      (remove-text-properties beg end (list 'c-is-sws #f)))
    (define (c-remove-in-sws beg end)
      (remove-text-properties beg end (list 'c-in-sws #f)))
    (define (c-remove-is-and-in-sws beg end)
      (remove-text-properties beg end (list 'c-is-sws #f 'c-in-sws #f)))

    ;; The three doc-comment variables are `cc-mode.el:136'-`:147''s,
    ;; "really belonging to cc-fonts.el" but declared by cc-engine for
    ;; its own use there too. There is no cc-mode.scm yet, so they are
    ;; defined here - a placement departure, named.
    ;;
    ;; Emacs `defvar's each with a global default, and cc-fonts'
    ;; `c-set-doc-comment-re-element' gives the current *buffer* its own
    ;; value with `make-local-variable'; a read then sees the buffer's
    ;; value. A plain definition cannot be buffer-local, so each is a
    ;; buffer-local slot behind an accessor pair, falling back on the
    ;; defvar's default - the shape `c-current-comment-prefix' takes in
    ;; cc-vars. cc-fonts writes them through the setters.
    (define (c-doc-line-join-re)
      (buffer-local-value (current-buffer) 'c-doc-line-join-re
                          regexp-unmatchable))
    (define (set!c-doc-line-join-re value)
      (set-buffer-local-value! (current-buffer) 'c-doc-line-join-re value))
    (define (c-doc-bright-comment-start-re)
      (buffer-local-value (current-buffer) 'c-doc-bright-comment-start-re
                          regexp-unmatchable))
    (define (set!c-doc-bright-comment-start-re value)
      (set-buffer-local-value! (current-buffer) 'c-doc-bright-comment-start-re
                               value))
    (define (c-doc-line-join-end-ch)
      (buffer-local-value (current-buffer) 'c-doc-line-join-end-ch #f))
    (define (set!c-doc-line-join-end-ch value)
      (set-buffer-local-value! (current-buffer) 'c-doc-line-join-end-ch value))


    ;;------------------------------------------------------------------
    ;; Literal positions (`cc-engine.el:2700'-`:3270')
    ;;------------------------------------------------------------------
    ;; "We maintain a sophisticated cache of positions which are in a
    ;; literal, disregarding macros." Three parts: two near caches of at
    ;; most six (position . state) entries, and a far cache of compressed
    ;; states one every `c-state-nonlit-pos-interval' characters back to
    ;; the buffer's start. `c-semi-pp-to-literal' answers the state and
    ;; the literal's start; `c-full-pp-to-literal' adds its end.
    ;;
    ;; **`c-block-comment-awkward-chars' holds *code points*** - the
    ;; language data was generated from Emacs, where a character is an
    ;; integer - while this tree's `char-before' answers a character.
    ;; The comparison converts, once, where the C compares the C `int'
    ;; `c' directly.
    (define c-state-nonlit-pos-interval 3000)

    ;; Emacs's `car'/`cdr' of nil are nil, and the two literal functions
    ;; answer one-element lists when point is not in a literal - so their
    ;; callers ask `(cadr ...)' of a one-element list and Emacs answers
    ;; nil. A Scheme `cadr' of one element is an error, so the accesses
    ;; that can see such an answer use these. (They are exported for
    ;; cc-fonts, which reads the same answers.)
    (define (%c-car x) (and (pair? x) (car x)))
    (define (%c-cdr x) (if (pair? x) (cdr x) '()))
    (define (%c-cadr x) (%c-car (%c-cdr x)))
    (define (%c-cddr x) (%c-cdr (%c-cdr x)))
    (define (%c-caddr x) (%c-car (%c-cddr x)))

    (define (c-lit-pos-cache)
      (buffer-local-value (current-buffer) 'c-lit-pos-cache '()))
    (define (set!c-lit-pos-cache value)
      (set-buffer-local-value! (current-buffer) 'c-lit-pos-cache value))
    (define (c-lit-pos-cache-limit)
      (buffer-local-value (current-buffer) 'c-lit-pos-cache-limit 1))
    (define (set!c-lit-pos-cache-limit value)
      (set-buffer-local-value! (current-buffer) 'c-lit-pos-cache-limit value))

    (define (c-cache-to-parse-ps-state elt)
      ;; "Create a list suitable to use as the old-state parameter to
      ;; `parse-partial-sexp', out of ELT, a member of
      ;; `c-lit-pos-cache'. ... POINT is left at the position for which
      ;; the returned state is valid."
      (if (and (pair? elt) (>= (length elt) 3))
          ;; Inside a string or comment.
          (let* ((depth 0) (containing #f)
                 (in-string #f) (in-comment #f)
                 (min-depth 0) (com-style #f) (com-str-start #f)
                 (char-1 (nth 3 elt))   ; first char of poss. 2-char construct
                 (pos (car elt))
                 (type (cadr elt)))
            (set! com-str-start (car (cddr elt)))
            (cond
             ((or (number? type) (eq? type #t)) ; A string
              (set! in-string type))
             ((memq type '(c c++))              ; A comment
              (set! in-comment #t)
              (set! com-style (if (eq? type 'c++) 1 #f)))
             (else (c-benign-error "Invalid type ~a in c-cache-to-parse-ps-state"
                                   elt)))
            (goto-char (if char-1 (- pos 1) pos))
            (list depth containing #f
                  in-string in-comment #f
                  min-depth com-style com-str-start
                  #f #f))
          ;; Not in a string or comment.
          (begin
            (goto-char (if (pair? elt) (car elt) elt))
            (list 0 #f #f #f #f
                  ;; "9 is syntax code for escape."
                  (and (pair? elt) (eqv? (nth 1 elt) 9))
                  0 #f #f #f
                  (and (pair? elt) (nth 1 elt))))))

    (define (c-parse-ps-state-to-cache state)
      ;; "Convert STATE, a `parse-partial-sexp' state valid at POINT, to
      ;; an element for the `c-lit-pos-cache' cache."
      (let ((basic
             (cond
              ((%c-true (nth 3 state))  ; A string
               (list (point) (nth 3 state) (nth 8 state)))
              ((and (%c-true (nth 4 state))                ; A comment
                    (not (eq? (nth 7 state) 'syntax-table))) ; but not a pseudo comment.
               (list (point)
                     (if (eqv? (nth 7 state) 1) 'c++ 'c)
                     (nth 8 state)))
              (else                     ; Neither string nor comment.
               (point)))))
        (if (%c-true (nth 10 state))
            (append (if (pair? basic) basic (list basic))
                    (list (nth 10 state)))
            basic)))

    (define (c-ps-state-cache-pos elt)
      ;; "Get the buffer position from ELT, an element from the cache
      ;; `c-lit-pos-cache'."
      (if (pair? elt) (car elt) elt))

    (define (c-trim-lit-pos-cache)
      ;; "Trim the `c-lit-pos-cache' to take account of buffer changes,
      ;; indicated by `c-lit-pos-cache-limit'."
      (let loop ()
        (when (and (pair? (c-lit-pos-cache))
                   (> (c-ps-state-cache-pos (car (c-lit-pos-cache)))
                      (c-lit-pos-cache-limit)))
          (set!c-lit-pos-cache (cdr (c-lit-pos-cache)))
          (loop))))

    (define (c-parse-ps-state-below here)
      ;; "Given a buffer position HERE, Return a cons (CACHE-POS .
      ;; STATE), where CACHE-POS is a position not very far before HERE
      ;; for which the parse-partial-sexp STATE is valid. ..."
      (save-excursion
        (save-restriction
          (widen)
          (c-trim-lit-pos-cache)
          (let ((c (c-lit-pos-cache))
                (elt #f) (state #f) (npos 0) (high-elt #f))
            (let loop ()
              (when (and (pair? c) (> (c-ps-state-cache-pos (car c)) here))
                (set! high-elt (car c))
                (set! c (cdr c))
                (loop)))
            (goto-char (or (and (pair? c) (c-ps-state-cache-pos (car c)))
                           (point-min)))
            (set! state
                  (if (pair? c)
                      (c-cache-to-parse-ps-state (car c))
                      (list 0 #f #f #f #f #f 0 #f #f #f)))

            (when (not high-elt)
              ;; "We need to extend the cache. Add an element to
              ;; `c-lit-pos-cache' each iteration of the following."
              (let loop ()
                (set! npos (+ (point) c-state-nonlit-pos-interval))
                (when (<= npos here)
                  (set! state (parse-partial-sexp (point) npos #f #f state))
                  ;; "If we're after a \ or a / or * which might be a
                  ;; comment delimiter half, move back a character."
                  (when (or (%c-true (nth 5 state)) ; After a quote character
                            (%c-true (nth 10 state))) ; in the middle of a 2-char seq.
                    (set! npos (- npos 1))
                    (backward-char)
                    (when (%c-true (nth 10 state))
                      (set-car! (nthcdr 10 state) #f))
                    (when (%c-true (nth 5 state))
                      (set-car! (nthcdr 5 state) #f)))
                  (set! elt (c-parse-ps-state-to-cache state))
                  (set!c-lit-pos-cache (cons elt (c-lit-pos-cache)))
                  (loop))))

            (if (> (point) (c-lit-pos-cache-limit))
                (set!c-lit-pos-cache-limit (point)))
            (cons (point) state)))))

    ;; "A list of up to six recent results from `c-semi-pp-to-literal'."
    (define (c-semi-lit-near-cache)
      (buffer-local-value (current-buffer) 'c-semi-lit-near-cache '()))
    (define (set!c-semi-lit-near-cache value)
      (set-buffer-local-value! (current-buffer) 'c-semi-lit-near-cache value))
    (define (c-semi-near-cache-limit)
      (buffer-local-value (current-buffer) 'c-semi-near-cache-limit 1))
    (define (set!c-semi-near-cache-limit value)
      (set-buffer-local-value! (current-buffer) 'c-semi-near-cache-limit value))

    (define (c-semi-trim-near-cache)
      ;; "Remove stale entries in `c-semi-lit-near-cache', i.e. those
      ;; whose positions are above `c-lit-pos-cache-limit'."
      (let ((nc-list (c-semi-lit-near-cache)))
        (let loop ()
          (when (pair? nc-list)
            (if (> (car (car nc-list)) (c-semi-near-cache-limit))
                (begin
                  (set!c-semi-lit-near-cache (delq (car nc-list)
                                                   (c-semi-lit-near-cache)))
                  ;; "start again in case of list breakage."
                  (set! nc-list (c-semi-lit-near-cache)))
                (set! nc-list (cdr nc-list)))
            (loop)))))

    (define (c-semi-get-near-cache-entry here)
      ;; "Return the near cache entry at the highest position before
      ;; HERE, if any, or nil."
      (let ((nc-pos-state
             (or (assq here (c-semi-lit-near-cache))
                 (let ((nc-list (c-semi-lit-near-cache))
                       (pos #f) (nc-pos 0) (cand-pos-state #f))
                   (let loop ()
                     (when (pair? nc-list)
                       (set! pos (car (car nc-list)))
                       (when (>= here pos)
                         (cond
                          ((and (pair? (cdr (car nc-list)))
                                (%c-true (nth 8 (cdr (car nc-list))))
                                (< here (nth 8 (cdr (car nc-list)))))
                           (set! cand-pos-state (car nc-list)))
                          ((> pos nc-pos)
                           (set! nc-pos pos)
                           (set! cand-pos-state (car nc-list)))))
                       (when (not (and (pair? (cdr (car nc-list)))
                                       (%c-true (nth 8 (cdr (car nc-list))))
                                       (< here (nth 8 (cdr (car nc-list))))))
                         (set! nc-list (cdr nc-list))
                         (loop))
                       ;; The C's `throw 'found` breaks out of the walk:
                       ;; the entry found by the first arm wins at once.
                       #f))
                   cand-pos-state))))
        (when (and nc-pos-state
                   (not (eq? nc-pos-state (car (c-semi-lit-near-cache)))))
          ;; "Move the found cache entry to the front of the list."
          (set!c-semi-lit-near-cache (delq nc-pos-state (c-semi-lit-near-cache)))
          (set!c-semi-lit-near-cache (cons nc-pos-state (c-semi-lit-near-cache))))
        (%c-copy-tree nc-pos-state)))

    (define (%c-copy-tree x)
      ;; `copy-tree' for the cache entries, where Emacs's nil is #f.
      (if (pair? x) (copy-tree x) x))

    (define (c-semi-put-near-cache-entry here state)
      ;; "Put a new near cache entry into the near cache."
      (let loop ()
        (when (>= (length (c-semi-lit-near-cache)) 6)
          (set!c-semi-lit-near-cache
           (delq (car (last (c-semi-lit-near-cache))) (c-semi-lit-near-cache)))
          (loop)))
      (set!c-semi-lit-near-cache (cons (cons here state) (c-semi-lit-near-cache)))
      (set!c-semi-near-cache-limit (max (c-semi-near-cache-limit) here)))

    (define (%c-char-before-in? here charlist)
      ;; Emacs's `(memq (char-before HERE) CHARLIST)' where CHARLIST may
      ;; hold code points (the language data) rather than characters.
      (let ((cb (char-before here)))
        (and cb
             (let ((n (char->integer cb)))
               (let loop ((l charlist))
                 (cond ((null? l) #f)
                       ((eqv? (if (char? (car l)) (char->integer (car l))
                                  (car l))
                              n)
                        l)
                       (else (loop (cdr l)))))))))

    (define (c-semi-pp-to-literal here . args)
      ;; "Do a parse-partial-sexp from a position in the buffer before
      ;; HERE which isn't in a literal, and return information about
      ;; HERE, either: (STATE TYPE BEG) if HERE is in a literal; or
      ;; (STATE) otherwise ..."
      ;;
      ;; HERE's NOT-IN-DELIMITER is the optional argument.
      (let ((not-in-delimiter (if (pair? args) (car args) #f)))
        (save-excursion
          (save-restriction
            (widen)
            (c-trim-lit-pos-cache)
            (c-semi-trim-near-cache)
            (save-match-data
              (let* ((pos-and-state (c-semi-get-near-cache-entry here))
                     (pos (%c-car pos-and-state))
                     (near-pos pos)
                     (s (%c-cdr pos-and-state))
                     (far-pos-and-state #f) (far-pos #f) (far-s #f)
                     (ty #f))
                (if (or (not pos)
                        (< pos (- here 100)))
                    (begin
                      (set! far-pos-and-state (c-parse-ps-state-below here))
                      (set! far-pos (car far-pos-and-state))
                      (set! far-s (cdr far-pos-and-state))
                      (when (or (not pos) (> far-pos pos))
                        (set! pos far-pos)
                        (set! s far-s))))
                (when
                 (or
                  (> here pos)
                  (%c-false (nth 8 s))
                  (< here (nth 8 s))       ; "Can't happen, can it?"
                  (not
                   (or
                    (and (%c-true (nth 3 s))          ; string
                         (not (eq? (char-before here) #\\)))
                    (and (%c-true (nth 4 s)) (%c-false (nth 7 s)) ; Block comment
                         (not (%c-char-before-in? here
                                                  (%c-langvar 'c-block-comment-awkward-chars))))
                    (and (%c-true (nth 4 s)) (%c-true (nth 7 s)) ; Line comment
                         (not (memv (char-before here) (list #\\ #\newline)))))))
                  (set! s (parse-partial-sexp pos here #f #f s)))
                (when (not (eqv? near-pos here))
                  (c-semi-put-near-cache-entry here s))
                (cond
                 ((or (%c-true (nth 3 s))
                      (and (%c-true (nth 4 s))
                           (not (eq? (nth 7 s) 'syntax-table)))) ; in a string or comment
                  (set! ty (cond
                            ((%c-true (nth 3 s)) 'string)
                            ((%c-true (nth 7 s)) 'c++)
                            (else 'c)))
                  (list s ty (nth 8 s)))

                 ((and (not (%c-true not-in-delimiter)) ; inside a comment starter
                       (not (bobp))
                       (begin
                         (backward-char)
                         (and (not (and (memq 'category-properties c-emacs-features)
                                        (looking-at "\\s!")))
                              (looking-at (%c-langvar 'c-comment-start-regexp)))))
                  (set! ty (if (looking-at (%c-langvar 'c-block-comment-start-regexp))
                               'c 'c++))
                  (list s ty (point)))

                 (else (list s)))))))))

    ;; "A list of up to six recent results from `c-full-pp-to-literal'."
    (define (c-full-lit-near-cache)
      (buffer-local-value (current-buffer) 'c-full-lit-near-cache '()))
    (define (set!c-full-lit-near-cache value)
      (set-buffer-local-value! (current-buffer) 'c-full-lit-near-cache value))
    (define (c-full-near-cache-limit)
      (buffer-local-value (current-buffer) 'c-full-near-cache-limit 1))
    (define (set!c-full-near-cache-limit value)
      (set-buffer-local-value! (current-buffer) 'c-full-near-cache-limit value))

    (define (c-full-trim-near-cache)
      ;; "Remove stale entries in `c-full-lit-near-cache', i.e. those
      ;; whose END entries, or positions, are above
      ;; `c-full-near-cache-limit'."
      (let ((nc-list (c-full-lit-near-cache)))
        (let loop ()
          (when (pair? nc-list)
            (let ((elt (car nc-list)))
              (if (if (car (cddr elt))
                      (< (c-full-near-cache-limit) (car (cddr elt)))
                      (< (c-full-near-cache-limit) (car elt)))
                  (begin
                    (set!c-full-lit-near-cache (delq elt (c-full-lit-near-cache)))
                    ;; "start again in case of list breakage."
                    (set! nc-list (c-full-lit-near-cache)))
                  (set! nc-list (cdr nc-list))))
            (loop)))))

    (define (c-full-get-near-cache-entry here)
      ;; "Return a near cache entry which either represents a literal
      ;; which encloses HERE, or is at the highest position before HERE."
      (let ((nc-pos-state
             (or (assq here (c-full-lit-near-cache))
                 (let ((nc-list (c-full-lit-near-cache))
                       (elt #f) (nc-pos 0) (cand-pos-state #f))
                   (let loop ()
                     (when (pair? nc-list)
                       (set! elt (car nc-list))
                       (cond
                        ((and (car (cddr elt))
                              (> here (nth 8 (cadr elt)))
                              (< here (car (cddr elt))))
                         (set! cand-pos-state elt))
                        ((and (< (car elt) here)
                              (> (car elt) nc-pos))
                         (set! nc-pos (car elt))
                         (set! cand-pos-state elt)))
                       (when (not (and (car (cddr elt))
                                       (> here (nth 8 (cadr elt)))
                                       (< here (car (cddr elt)))))
                         (set! nc-list (cdr nc-list))
                         (loop))))
                   cand-pos-state))))
        ;; "Move the found cache entry, if any, to the front of the list."
        (when (and nc-pos-state
                   (not (eq? nc-pos-state (car (c-full-lit-near-cache)))))
          (set!c-full-lit-near-cache (delq nc-pos-state (c-full-lit-near-cache)))
          (set!c-full-lit-near-cache (cons nc-pos-state (c-full-lit-near-cache))))
        (%c-copy-tree nc-pos-state)))

    (define (c-full-put-near-cache-entry here state end)
      ;; "Put a new near cache entry into the near cache."
      (let loop ()
        (when (>= (length (c-full-lit-near-cache)) 6)
          (set!c-full-lit-near-cache
           (delq (car (last (c-full-lit-near-cache))) (c-full-lit-near-cache)))
          (loop)))
      (set!c-full-lit-near-cache (cons (list here state end) (c-full-lit-near-cache)))
      (set!c-full-near-cache-limit
       (max (c-full-near-cache-limit) (if end end here))))

    (define (c-full-pp-to-literal here . args)
      ;; "Do a parse-partial-sexp from a position in the buffer before
      ;; HERE which isn't in a literal, and return information about
      ;; HERE, either: (STATE TYPE (BEG . END)) if HERE is in a literal;
      ;; or (STATE) otherwise ..."
      (let ((not-in-delimiter (if (pair? args) (car args) #f)))
        (save-excursion
          (save-restriction
            (widen)
            (c-trim-lit-pos-cache)
            (c-full-trim-near-cache)
            (save-match-data
              (let* ((elt (c-full-get-near-cache-entry here))
                     (base (%c-car elt))
                     (near-base base)
                     (s (%c-cadr elt))
                     (s1 #f)
                     (end (%c-car (%c-cddr elt)))
                     (far-base-and-state #f) (far-base #f) (far-s #f)
                     (ty #f) (start #f))
                (if (or
                     (not base)
                     (not end)
                     (>= here end))
                    (begin
                      (set! far-base-and-state (c-parse-ps-state-below here))
                      (set! far-base (car far-base-and-state))
                      (set! far-s (cdr far-base-and-state))
                      (when (or (not base) (> far-base base))
                        (set! base far-base)
                        (set! s far-s)
                        (set! end #f))))
                (cond
                 ((or (and (> here base) (%c-false end))
                      (%c-false (nth 8 s))
                      (and end (>= here end)))
                  (set! s (parse-partial-sexp base here #f #f s)))
                 ((or (and (%c-true (nth 3 s))         ; string
                           (eq? (char-before here) #\\))
                      (and (%c-true (nth 4 s)) (%c-false (nth 7 s)) ; block comment
                           (%c-char-before-in? here
                                               (%c-langvar 'c-block-comment-awkward-chars)))
                      (and (%c-true (nth 4 s)) (%c-true (nth 7 s)) ; line comment
                           (memv (char-before here) (list #\\ #\newline))))
                  (set! s
                        (if (>= here base)
                            (parse-partial-sexp base here #f #f s)
                            (parse-partial-sexp (nth 8 s) here)))))
                (cond
                 ((or (%c-true (nth 3 s))
                      (and (%c-true (nth 4 s))
                           (not (eq? (nth 7 s) 'syntax-table)))) ; in a string or comment
                  (set! ty (cond
                            ((%c-true (nth 3 s)) 'string)
                            ((%c-true (nth 7 s)) 'c++)
                            (else 'c)))
                  (set! start (nth 8 s))
                  (unless (and end (>= end here))
                    (set! s1 (parse-partial-sexp here (point-max)
                                                 #f ; TARGETDEPTH
                                                 #f ; STOPBEFORE
                                                 s  ; OLDSTATE
                                                 'syntax-table)) ; stop at EO literal
                    (unless (or (%c-true (nth 3 s1)) ; still in a string
                                (and (%c-true (nth 4 s1))
                                     (not (eq? (nth 7 s1) 'syntax-table)))) ; still in a comment
                      (set! end (point))))
                  (unless (eqv? near-base here)
                    (c-full-put-near-cache-entry here s end))
                  (list s ty (cons start end)))

                 ((and (not (%c-true not-in-delimiter)) ; inside a comment starter
                       (not (bobp))
                       (begin
                         (backward-char)
                         (and (not (and (memq 'category-properties c-emacs-features)
                                        (looking-at "\\s!")))
                              (looking-at (%c-langvar 'c-comment-start-regexp)))))
                  (set! ty (if (looking-at (%c-langvar 'c-block-comment-start-regexp))
                               'c 'c++))
                  (set! start (point))
                  (forward-comment 1)
                  (list s ty (cons start (point))))

                 (else
                  (unless (eqv? near-base here)
                    (c-full-put-near-cache-entry here s #f))
                  (list s)))))))))

    (define (c-truncate-lit-pos-cache pos)
      ;; "Truncate the upper bound of each of the three caches to POS, if
      ;; it is higher than that position."
      (set!c-lit-pos-cache-limit (min (c-lit-pos-cache-limit) pos))
      (set!c-semi-near-cache-limit (min (c-semi-near-cache-limit) pos))
      (set!c-full-near-cache-limit (min (c-full-near-cache-limit) pos)))

    (define (c-literal-limits . args)
      ;; "Return a cons of the beginning and end positions of the comment
      ;; or string surrounding point (including both delimiters), or nil
      ;; if point isn't in one. ..."
      (let ((lim (if (pair? args) (car args) #f))
            (near (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
            (not-in-delimiter
             (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args)))
                 (car (cddr args)) #f)))
        (save-excursion
          (let* ((pos (point))
                 (lit-limits
                  (if lim
                      (let ((s (parse-partial-sexp lim (point))))
                        (if (or (%c-true (nth 3 s))
                                (and (%c-true (nth 4 s))
                                     (not (eq? (nth 7 s) 'syntax-table))))
                            (cons (nth 8 s)
                                  (begin
                                    (parse-partial-sexp (point) (point-max)
                                                        #f #f
                                                        s
                                                        'syntax-table)
                                    (point)))
                            #f))
                      (let* ((pp-to-lit (c-full-pp-to-literal pos not-in-delimiter))
                             (limits (%c-car (%c-cddr pp-to-lit))))
                        (if (and (%c-true limits) (%c-false (cdr limits)))
                            (cons (car limits) (point-max))
                            limits)))))
            (cond
             ((%c-true lit-limits) lit-limits)

             (near
              (goto-char pos)
              ;; "Search forward for a literal."
              (skip-chars-forward " \t")
              (cond
               ((looking-at c-string-limit-regexp) ; String.
                (cons (point)
                      (or (c-safe (c-forward-sexp 1) (point)) (point-max))))

               ((looking-at (%c-langvar 'c-comment-start-regexp)) ; Line or block comment.
                (cons (point) (begin (c-forward-single-comment) (point))))

               (else
                ;; "Search backward."
                (skip-chars-backward " \t")

                (let ((end (point)) (beg #f))
                  (cond
                   ((save-excursion
                      (< (skip-syntax-backward c-string-syntax) 0)) ; String.
                    (set! beg (or (c-safe (c-backward-sexp 1) (point)) (point-max))))

                   ((and (c-safe (forward-char -2) #t)
                         (looking-at "\\*/"))
                    ;; "Block comment. Due to the nature of line
                    ;; comments, they will always be covered by the
                    ;; normal case above."
                    (goto-char end)
                    (c-backward-single-comment)
                    ;; "If LIM is bogus, beg will be bogus."
                    (set! beg (point))))

                  (if beg (cons beg end) #f)))))

             (else #f))))))

    (define (c-literal-start . safe-pos-args)
      ;; "Return the start of the string or comment surrounding point, or
      ;; nil if point isn't in one. SAFE-POS, if non-nil, is a position
      ;; before point which is a known \"safe position\", i.e. outside of
      ;; any string or comment."
      (let ((safe-pos (if (pair? safe-pos-args) (car safe-pos-args) #f)))
        (if safe-pos
            (let ((s (parse-partial-sexp safe-pos (point))))
              (if (or (%c-true (nth 3 s))
                      (and (%c-true (nth 4 s))
                           (not (eq? (nth 7 s) 'syntax-table))))
                  (nth 8 s)
                  #f))
            (%c-car (%c-cddr (c-semi-pp-to-literal (point)))))))

    (define (c-literal-type range)
      ;; "Convenience function that given the result of
      ;; `c-literal-limits', returns nil or the type of literal that the
      ;; range surrounds, one of the symbols `c', `c++' or `string'."
      (if (pair? range)
          (save-excursion
            (goto-char (car range))
            (cond ((looking-at c-string-limit-regexp) 'string)
                  ((or (looking-at "//") ; c++ line comment
                       (and (looking-at "\\s<") ; comment starter
                            (looking-at "#"))) ; awk comment.
                   'c++)
                  (else 'c)))   ; "Assuming the range is valid."
          range))

    (define (c-in-literal . args)
      ;; "Return the type of literal point is in, if any. ... Optional
      ;; LIM is used as the backward limit of the search. ..."
      (let ((lim (if (pair? args) (car args) #f))
            (detect-cpp (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (save-restriction
          (widen)
          (let ((lit (c-semi-pp-to-literal (point))))
            (or (%c-cadr lit)
                (and (%c-true detect-cpp)
                     (save-excursion (c-beginning-of-macro))
                     'pound))))))

    ;;------------------------------------------------------------------
    ;; The state cache (`cc-engine.el:3250'-`:4850')
    ;;------------------------------------------------------------------
    ;; `c-parse-state' records every noteworthy unclosed paren/brace
    ;; between a "good position" earlier in the buffer and point, plus
    ;; the last closed brace pair before each of them. The cache is
    ;; `c-state-cache', a list of numbers (open paren positions) and
    ;; conses (a closed brace pair `(OPEN . AFTER-CLOSE)').
    ;;
    ;; A buffer-local variable here is a slot behind an accessor, as
    ;; `c-lit-pos-cache' is, and `#f' is nil. An empty cache is `#f',
    ;; never `'()' - every emptiness test in the C is a nil test, and
    ;; `'()' would make `(and c-state-cache ...)' true.
    ;;
    ;; **`c-with-<->-as-parens-suppressed' is not carried.** It exists
    ;; to suppress the `category' syntax properties on `<' and `>'
    ;; that `cc-mode.el' propertizes; this tree has no such properties
    ;; (they are stripped from the Emacs side of every differential for
    ;; the same reason), so the wrapper is the identity and the two
    ;; entry points call the `-1' functions directly.
    ;;
    ;; **The debug/replay helpers are not carried** (`c-record-parse-
    ;; state-state', `c-replay-parse-state-state', `c-debug-parse-
    ;; state', `c-toggle-parse-state-debug'): they exist for cc-mode's
    ;; own test suite, which drives them through `c-real-parse-state'
    ;; and `fset'. `c-debug-parse-state' is a variable here so a port
    ;; of that suite can find it.
    (define (c-state-cache)
      (buffer-local-value (current-buffer) 'c-state-cache '()))
    (define (set!c-state-cache value)
      (set-buffer-local-value! (current-buffer) 'c-state-cache value))
    (define (c-state-cache-good-pos)
      (buffer-local-value (current-buffer) 'c-state-cache-good-pos 1))
    (define (set!c-state-cache-good-pos value)
      (set-buffer-local-value! (current-buffer) 'c-state-cache-good-pos value))
    (define (c-state-cache-invalid-pos)
      (buffer-local-value (current-buffer) 'c-state-cache-invalid-pos 1))
    (define (set!c-state-cache-invalid-pos value)
      (set-buffer-local-value! (current-buffer) 'c-state-cache-invalid-pos value))
    (define (c-state-nonlit-pos-cache)
      (buffer-local-value (current-buffer) 'c-state-nonlit-pos-cache '()))
    (define (set!c-state-nonlit-pos-cache value)
      (set-buffer-local-value! (current-buffer) 'c-state-nonlit-pos-cache value))
    (define (c-state-nonlit-pos-cache-limit)
      (buffer-local-value (current-buffer) 'c-state-nonlit-pos-cache-limit 1))
    (define (set!c-state-nonlit-pos-cache-limit value)
      (set-buffer-local-value! (current-buffer) 'c-state-nonlit-pos-cache-limit value))
    (define (c-state-point-min)
      (buffer-local-value (current-buffer) 'c-state-point-min 1))
    (define (set!c-state-point-min value)
      (set-buffer-local-value! (current-buffer) 'c-state-point-min value))
    (define (c-state-point-min-lit-type)
      (buffer-local-value (current-buffer) 'c-state-point-min-lit-type #f))
    (define (set!c-state-point-min-lit-type value)
      (set-buffer-local-value! (current-buffer) 'c-state-point-min-lit-type value))
    (define (c-state-point-min-lit-start)
      (buffer-local-value (current-buffer) 'c-state-point-min-lit-start #f))
    (define (set!c-state-point-min-lit-start value)
      (set-buffer-local-value! (current-buffer) 'c-state-point-min-lit-start value))
    (define (c-state-min-scan-pos)
      (buffer-local-value (current-buffer) 'c-state-min-scan-pos 1))
    (define (set!c-state-min-scan-pos value)
      (set-buffer-local-value! (current-buffer) 'c-state-min-scan-pos value))
    (define (c-state-brace-pair-desert)
      (buffer-local-value (current-buffer) 'c-state-brace-pair-desert #f))
    (define (set!c-state-brace-pair-desert value)
      (set-buffer-local-value! (current-buffer) 'c-state-brace-pair-desert value))
    (define (c-state-old-cpp-beg)
      (buffer-local-value (current-buffer) 'c-state-old-cpp-beg #f))
    (define (set!c-state-old-cpp-beg value)
      (set-buffer-local-value! (current-buffer) 'c-state-old-cpp-beg value))
    (define (c-state-old-cpp-end)
      (buffer-local-value (current-buffer) 'c-state-old-cpp-end #f))
    (define (set!c-state-old-cpp-end value)
      (set-buffer-local-value! (current-buffer) 'c-state-old-cpp-end value))
    (define (c-state-old-cpp-beg-marker)
      (buffer-local-value (current-buffer) 'c-state-old-cpp-beg-marker #f))
    (define (set!c-state-old-cpp-beg-marker value)
      (set-buffer-local-value! (current-buffer) 'c-state-old-cpp-beg-marker value))
    (define (c-state-old-cpp-end-marker)
      (buffer-local-value (current-buffer) 'c-state-old-cpp-end-marker #f))
    (define (set!c-state-old-cpp-end-marker value)
      (set-buffer-local-value! (current-buffer) 'c-state-old-cpp-end-marker value))
    (define (c-debug-parse-state)
      (buffer-local-value (current-buffer) 'c-debug-parse-state #f))
    (define (set!c-debug-parse-state value)
      (set-buffer-local-value! (current-buffer) 'c-debug-parse-state value))

    (define c-state-cache-too-far 5000)

    ;; "If PLACE is non-nil, return a marker marking it, otherwise
    ;; nil. We (re)use MARKER." The C's macro `setq's the marker into
    ;; the caller's variable; here the caller stores the answer.
    (define (c-state-maybe-marker place marker)
      (and place
           (let ((m (or marker (make-marker))))
             (set-marker m place)
             m)))

    ;; A marker is a number to the C's arithmetic (`=`, `<`, `>` coerce
    ;; it); this tree's markers do no arithmetic, so the coercion is
    ;; explicit wherever `c-state-old-cpp-beg'/`-end' are compared.
    (define (c-state-pos-of thing)
      (if (markerp thing) (marker-position thing) thing))

    (define (c--cdr x) (if (pair? x) (cdr x) '()))
    (define (c--copy-list lst)
      (if (pair? lst) (cons (car lst) (c--copy-list (cdr lst))) '()))

    ;; "Do a parse-partial-sexp from FROM to TO, returning either
    ;; (STATE TYPE (BEG . END)) if TO is in a literal; or (STATE)
    ;; otherwise ..."
    (define (c-state-pp-to-literal from to . args)
      (let ((not-in-delimiter (if (pair? args) (car args) #f)))
        (save-excursion
          (save-match-data
            (let ((s (parse-partial-sexp from to)) (ty #f) (co-st #f))
              (cond
               ((or (nth 3 s)
                    (and (nth 4 s) (not (eq? (nth 7 s) 'syntax-table))))
                (set! ty (cond ((nth 3 s) 'string)
                               ((nth 7 s) 'c++)
                               (else 'c)))
                (parse-partial-sexp (point) (point-max) #f #f s 'syntax-table)
                (list s ty (cons (nth 8 s) (point))))
               ((and (not not-in-delimiter)
                     (not (bobp))
                     (begin
                       (backward-char)
                       (and (not (looking-at "\\s!"))
                            (looking-at (%c-langvar 'c-comment-start-regexp)))))
                (set! ty (if (looking-at (%c-langvar 'c-block-comment-start-regexp))
                             'c
                             'c++))
                (set! co-st (point))
                (forward-comment 1)
                (list s ty (cons co-st (point))))
               (else (list s))))))))

    ;; "Return a buffer position before HERE which is 'safe', i.e.
    ;; outside any string, comment, or macro."
    (define (c-state-safe-place here)
      (save-restriction
        (widen)
        (save-excursion
          (let ((c (c-state-nonlit-pos-cache))
                (pos #f) (npos #f) (high-pos #f) (lit #f)
                (macro-beg #f) (macro-end #f))
            ;; Trim the cache to take account of buffer changes.
            (let loop () (when (and (pair? c) (> (car c) (c-state-nonlit-pos-cache-limit)))
              (set! c (cdr c)) (loop)))
            (set!c-state-nonlit-pos-cache c)

            (let loop () (when (and (pair? c) (> (car c) here))
              (set! high-pos (car c))
              (set! c (cdr c)) (loop)))
            (set! pos (or (and (pair? c) (car c)) (point-min)))

            (unless high-pos
              (let loop ()
                (set! npos
                      (and (<= (+ pos c-state-nonlit-pos-interval) here)
                           (+ pos c-state-nonlit-pos-interval)))
                (when npos
                  (set! lit (%c-caddr (c-state-pp-to-literal pos npos)))
                  (when (if lit
                            (begin (set! npos (cdr lit))
                                   (<= (cdr lit) here))
                            #t)
                    (goto-char npos)
                    (set! macro-beg
                          (and (c-beginning-of-macro) (not (= (point) npos)) (point)))
                    (when macro-beg
                      (c-syntactic-end-of-macro)
                      (or (eobp) (forward-char))
                      (set! macro-end (point)))
                    (when (if macro-beg
                              (begin (set! npos macro-end)
                                     (<= macro-end here))
                              #t)
                      (set! pos npos)
                      (set!c-state-nonlit-pos-cache
                       (cons pos (c-state-nonlit-pos-cache)))
                      (loop)))))
              ;; "Add one extra element above HERE so as to avoid the
              ;; previous expensive calculation when the next call is
              ;; close to the current one."
              (when npos
                (set!c-state-nonlit-pos-cache
                 (cons npos (c-state-nonlit-pos-cache)))))

            (if (> pos (c-state-nonlit-pos-cache-limit))
                (set!c-state-nonlit-pos-cache-limit pos))
            pos))))

    (define (c-state-literal-at here)
      (save-restriction
        (widen)
        (save-excursion
          (let ((pos (c-state-safe-place here)))
            (%c-caddr (c-state-pp-to-literal pos here))))))

    (define (c-state-lit-beg pos)
      (or (%c-car (c-state-literal-at pos)) pos))

    (define (c-state-cache-lower-good-pos here pos state)
      (let ((s #f))
        (save-excursion
          (goto-char pos)
          (when (nth 8 state)		; POS in a comment or string.
            (set! s (parse-partial-sexp pos here #f #f state 'syntax-table))
            (when (< (point) here)
              (set! pos (point))
              (set! state s)))
          (if (eq? (point) here)
              (nth 8 state)		; A valid good pos cannot be in a literal.
              (begin
                (set! s (parse-partial-sexp pos here (+ 1 (car state)) #f state #f))
                (cond
                 ((> (car s) (car state)) here)
                 ((not (eq? (nth 6 s) (car state))) here)
                 (else pos)))))))

    (define (c-state-get-min-scan-pos)
      (or (c-state-min-scan-pos)
          (save-restriction
            (save-excursion
              (widen)
              (goto-char (c-state-point-min-lit-start))
              (if (eq? (c-state-point-min-lit-type) 'string)
                  (forward-sexp)
                  (forward-comment 1))
              (set!c-state-min-scan-pos (point))
              (c-state-min-scan-pos)))))

    (define (c-state-mark-point-min-literal)
      (let ((p-min (point-min)))
        (save-restriction
          (widen)
          (let ((lit (c-state-literal-at p-min)))
            (if lit
                (begin
                  (set!c-state-point-min-lit-type
                   (save-excursion
                     (goto-char (car lit))
                     (cond ((looking-at (%c-langvar 'c-block-comment-start-regexp)) 'c)
                           ((looking-at (%c-langvar 'c-line-comment-starter)) 'c++)
                           (else 'string))))
                  (set!c-state-point-min-lit-start (car lit))
                  (set!c-state-min-scan-pos (cdr lit)))
                (begin
                  (set!c-state-point-min-lit-type #f)
                  (set!c-state-point-min-lit-start #f)
                  (set!c-state-min-scan-pos p-min)))))))

    ;; "Return the address of the top left brace/bracket/paren recorded
    ;; in CACHE (default `c-state-cache') (or nil)."
    (define (c-state-cache-top-lparen . args)
      (let* ((cache (if (pair? args) (car args) (c-state-cache)))
             (elt (and (pair? cache) (car cache))))
        (if (pair? elt) (car elt) elt)))

    (define (c-state-cache-top-paren . args)
      (let* ((cache (if (pair? args) (car args) (c-state-cache)))
             (elt (and (pair? cache) (car cache))))
        (if (pair? elt) (cdr elt) elt)))

    (define (c-state-cache-after-top-paren . args)
      (let* ((cache (if (pair? args) (car args) (c-state-cache)))
             (elt (and (pair? cache) (car cache))))
        (if (pair? elt)
            (cdr elt)
            (and elt (+ 1 elt)))))

    (define (c-get-cache-scan-pos here)
      (let ((c (c-state-cache)) (elt #f))
        (let loop () (when (and (pair? c) (>= (c-state-cache-top-lparen c) here))
          (set! c (c--cdr c)) (loop)))
        (set! elt (and (pair? c) (car c)))
        (cond
         ((pair? elt)
          (if (> (cdr elt) here)
              (+ 1 (car elt))
              (cdr elt)))
         (elt (+ 1 elt))
         ((<= (c-state-get-min-scan-pos) here)
          (c-state-get-min-scan-pos))
         (else #f))))

    ;; "Wrapper around `beginning-of-defun'. Note that the return value
    ;; from this macro has no significance." The XEmacs
    ;; `buffer-syntactic-context-depth' half is not carried (this is
    ;; GNU Emacs's branch).
    (define (c-beginning-of-defun-1)
      (let loop ()
        (parameterize ((*beginning-of-defun-function* #f)
                       (*end-of-defun-function* #f))
          (beginning-of-defun))
        (when (and (not (bobp))
                   (*defun-prompt-regexp*)
                   (looking-at (string-append (*defun-prompt-regexp*) "\\s(")))
          (if (eq? (char-before (match-end 0)) #\{)
              (goto-char (- (match-end 0) 1))
              (loop)))))

    ;; "Return a start position for building `c-state-cache' from
    ;; scratch. This will be at the top level, 2 defuns back."
    (define (c-get-fallback-scan-pos here)
      (save-excursion
        (save-restriction
          (when (> here (* 10 c-state-cache-too-far))
            (narrow-to-region (- here (* 10 c-state-cache-too-far)) here))
          (goto-char here)
          (let ((cnt 2))
            (let loop () (when (not (or (bobp) (= cnt 0)))
              (c-beginning-of-defun-1)	; Pure elisp BOD.
              (if (eq? (char-after (point)) #\{)
                  (set! cnt (- cnt 1))) (loop))))
          (and (not (bobp)) (point)))))

    ;; `c-sc-scan-lists' and `c-sc-parse-partial-sexp' compile to the
    ;; category versions in GNU Emacs (`c-use-category'), and the
    ;; no-category variants exist for XEmacs's angle brackets. This
    ;; tree has no category properties, so the plain primitives are
    ;; what the C's Emacs build does.
    (define (c-sc-scan-lists from count depth)
      (scan-lists from count depth))
    (define (c-sc-parse-partial-sexp from to . rest)
      (apply parse-partial-sexp from to rest))

    (define (c-state-balance-parens-backwards here- here+ top)
      (let ((pos #f) (pa #f) (ren+1 #f) (lonely-rens '()))
        (save-excursion
          (save-restriction
            (narrow-to-region (point-min) top) ; This can move point, sometimes.
            (set! pos here+)
            (c-safe
             (let loop ()
               (set! ren+1 (c-sc-scan-lists pos 1 1)) ; might signal
               (set! lonely-rens (cons ren+1 lonely-rens))
               (set! pos ren+1)
               (loop)))))

        ;; "PART 2: Scan back before `here-' searching for the '('s
        ;; matching/mismatching the ')'s found above."
        (set! pos here-)
        (when (pair? lonely-rens)
          (c-safe
           (let loop ()
             (when (and (pair? lonely-rens)
                        (begin (set! pa (c-sc-scan-lists pos -1 1)) pa))
               (set! pos pa)
               (set! lonely-rens (cdr lonely-rens))
               (loop)))))
        pos))

    (define (c-parse-state-get-strategy here good-pos)
      (let* ((in-macro-start
              (save-excursion
                (goto-char here)
                (and (c-beginning-of-macro)
                     (point))))
             (changed-macro-start
              (and in-macro-start
                   (not (and (c-state-old-cpp-beg)
                             (= in-macro-start
                                (c-state-pos-of (c-state-old-cpp-beg)))))
                   in-macro-start))
             (cache-pos (c-get-cache-scan-pos
                         (if changed-macro-start
                             (min changed-macro-start here)
                             here)))
             (BOD-pos #f) (strategy #f) (start-point #f) (how-far #f))
        (set! good-pos (or good-pos (c-state-get-min-scan-pos)))
        (cond
         ((< here (c-state-get-min-scan-pos))
          (set! strategy 'IN-LIT)
          (set! start-point #f)
          (set! cache-pos #f)
          (set! how-far 0))
         ((<= good-pos here)
          (set! strategy 'forward)
          (set! start-point (max good-pos cache-pos))
          (set! how-far (- here start-point)))
         ((< (- good-pos here) (- here cache-pos))
          (set! strategy 'backward)
          (set! how-far (- good-pos here)))
         (else
          (set! strategy 'back-and-forward)
          (set! start-point cache-pos)
          (set! how-far (- here start-point))))

        (when (and (or (not (memq 'col-0-paren c-emacs-features))
                       (*open-paren-in-column-0-is-defun-start*))
                   (> how-far c-state-cache-too-far))
          (set! BOD-pos (c-get-fallback-scan-pos here)) ; somewhat EXPENSIVE!!!
          (if (and BOD-pos (< (- here BOD-pos) how-far))
              (begin
                (set! strategy 'BOD)
                (set! start-point BOD-pos))))

        (list strategy start-point)))

    (define (c-renarrow-state-cache)
      (if (< (point-min) (c-state-point-min))
          ;; If point-min has MOVED BACKWARDS then we drop the state
          ;; completely.
          (begin
            (c-state-mark-point-min-literal)
            (set!c-state-cache '())
            (set!c-state-cache-good-pos (c-state-min-scan-pos))
            (set!c-state-cache-invalid-pos (c-state-cache-good-pos))
            (set!c-state-brace-pair-desert #f))

          ;; point-min has MOVED FORWARD.
          (begin
          ;; Is the new point-min inside a (different) literal?
          (unless (and (c-state-point-min-lit-start)
                       (< (point-min) (c-state-get-min-scan-pos)))
            (c-state-mark-point-min-literal))

          ;; Cut off a bit of the tail from `c-state-cache'.
          (let ((ptr (cons #f (c-state-cache))) (pa #f))
            (let loop () (when (and (begin (set! pa (c-state-cache-top-lparen (cdr ptr))) pa)
                        (>= pa (point-min)))
              (set! ptr (cdr ptr)) (loop)))

            (when (pair? ptr)
              (if (or (eq? (cdr ptr) (c-state-cache))
                      (and (pair? (cdr ptr))
                           (pair? (car (cdr ptr)))
                           (> (cdr (car (cdr ptr))) (point-min))))
                  ;; Our new point-min is inside a recorded brace pair.
                  (begin
                    (set!c-state-cache '())
                    (set!c-state-cache-good-pos (c-state-min-scan-pos))
                    (set!c-state-cache-invalid-pos (c-state-cache-good-pos)))
                  ;; Do not alter the original `c-state-cache'
                  ;; structure, since there may be a loop suspended
                  ;; which is looping through that structure. (This may
                  ;; have been the cause of bug #37910.)
                  (begin
                    (let ((cdr-ptr (cdr ptr)))
                      (set-cdr! ptr #f)
                      (set!c-state-cache (c--copy-list (c-state-cache)))
                      (set-cdr! ptr cdr-ptr))
                    (set!c-state-cache-good-pos
                     (+ 1 (c-state-cache-top-lparen)))
                    (set!c-state-cache-invalid-pos (c-state-cache-good-pos))))))))

      (set!c-state-point-min (point-min)))

    (define (c-append-lower-brace-pair-to-state-cache from here . args)
      (let ((upper-lim (if (pair? args) (car args) #f)))
        (save-excursion
          (save-restriction
            (let* ((new-cons #f)
                   (cache-pos (c-state-cache-top-lparen)) ; might be nil.
                   (macro-start-or-from
                    (begin (goto-char from)
                           (c-beginning-of-macro)
                           (point)))
                   (bra			; Position of "{".
                    (if (and (not (eq? macro-start-or-from from))
                             (< macro-start-or-from here)
                             (begin (goto-char macro-start-or-from)
                                    (c-end-of-macro)
                                    (>= (point) here)))
                        from
                        macro-start-or-from))
                   (ce #f))		; Position of "}".
              (or upper-lim (set! upper-lim from))

              ;; If we're essentially repeating a fruitless search,
              ;; just give up.
              (unless (and (c-state-brace-pair-desert)
                           (eq? cache-pos (car (c-state-brace-pair-desert)))
                           (or (not (car (c-state-brace-pair-desert)))
                               (> from (car (c-state-brace-pair-desert))))
                           (<= from (cdr (c-state-brace-pair-desert))))
                ;; DESERT-LIM. Avoid repeated searching through the
                ;; cached desert.
                (let ((desert-lim
                       (and (c-state-brace-pair-desert)
                            (eq? cache-pos (car (c-state-brace-pair-desert)))
                            (>= from (cdr (c-state-brace-pair-desert)))
                            (cdr (c-state-brace-pair-desert))))
                      ;; CACHE-LIM. ...
                      (cache-lim (and cache-pos (< cache-pos from) cache-pos)))
                  (narrow-to-region
                   (cond
                    ((and desert-lim cache-lim) (max desert-lim cache-lim))
                    (desert-lim)
                    (cache-lim)
                    (else (point-min)))
                   ;; The top limit is EOB to ensure that `bra' is
                   ;; inside the accessible part of the buffer at the
                   ;; next scan operation.
                   (+ 1 (buffer-size)))

                  ;; In the next pair of nested loops, the inner one
                  ;; moves back past a pair of (mis-)matching parens or
                  ;; brackets; the outer one moves back over a sequence
                  ;; of unmatched close brace/paren/bracket each time
                  ;; round.
(let loop ()
  (when (begin
          (c-safe
           (let inner ()
             (set! ce (c-sc-scan-lists bra -1 -1)) ; back past )/]/}; might signal
             (when ce
               (set! bra (c-sc-scan-lists ce -1 1)) ; back past (/[/{; might signal
               (when (or (> bra here) ;(> ce here)
                         (and (< ce here)
                              (or (not (eq? (char-after bra) #\{))
                                  (and (goto-char bra)
                                       (c-beginning-of-macro)
                                       (< (point) macro-start-or-from)))))
                 (inner))))
           #f)
          (and ce (< ce bra)))
    (set! bra ce)		; If we just backed over an unbalanced
				; closing brace, ignore it.
    (loop)))

                  (if (and ce (< ce here) (< bra ce) (eq? (char-after bra) #\{))
                      ;; We've found the desired brace-pair.
                      (begin
                        (set! new-cons (cons bra (+ 1 ce)))
                        (let ((top (and (pair? (c-state-cache)) (car (c-state-cache)))))
                          (cond
                           ((pair? top)
                            (set!c-state-cache (cons new-cons (c--cdr (c-state-cache)))))
                           ((and (number? top)
                                 (< ce top))
                            (set!c-state-cache
                             (cons top
                                   (cons new-cons (c--cdr (c-state-cache))))))
                           (else (set!c-state-cache (cons new-cons (c-state-cache)))))))

                    ;; We haven't found a brace pair. Record this in the cache.
                    (set!c-state-brace-pair-desert
                     (cons (if (and ce (< bra ce) (> ce here)) ; {..} straddling HERE?
                               bra
                               (point-min))
                           (begin
                             (goto-char (min here from))
                             (c-beginning-of-macro)
                             (point))))))))))))

    (define (c-state-push-any-brace-pair bra+1 macro-start-or-here)
      (when bra+1
        (if (or (> bra+1 macro-start-or-here)
                (begin (goto-char bra+1)
                       (not (c-beginning-of-macro))))
            (let ((top (and (pair? (c-state-cache)) (car (c-state-cache)))))
              (set!c-state-cache
               (cons (cons (- bra+1 1)
                           (c-sc-scan-lists bra+1 1 1))
                     (if (pair? top)
                         (c--cdr (c-state-cache))
                         (c-state-cache)))))
            ;; N.B. This defsubst codes one method for the simple,
            ;; normal case, and a more sophisticated, slower way for the
            ;; general case.
            (c-append-lower-brace-pair-to-state-cache (- bra+1 1) (point-max)))))

    (define (c-append-to-state-cache from here)
      (let ((here-bol (c-point 'bol here))
            (macro-start-or-here
             (save-excursion (goto-char here)
                             (if (c-beginning-of-macro)
                                 (point)
                                 here)))
            (pa+1 #f)			; pos just after an opening PAren (or brace).
            (ren+1 from)		; usually a pos just after a closing paREN etc.
            (paren+1 #f)		; Pos after some opening or closing paren.
            (paren+1s '())		; A list of `paren+1's.
            (bra+1 #f)			; just after L bra-ce.
            (mstart #f))		; start of a macro.

        (save-excursion
          (save-restriction
            (narrow-to-region (point-min) here)
            ;; Each time round the following loop, we enter a
            ;; successively deeper level of brace/paren nesting.
(let loop ()
  (when (begin
          ;; Each time round the next loop moves forward over an
          ;; opening then a closing brace/bracket/paren. It
          ;; terminates when a call of `scan-lists' signals an
          ;; error.
          (c-safe
           (let inner ()
             (set! pa+1 (c-sc-scan-lists ren+1 1 -1)) ; Into (/{/[; might signal
             (set! paren+1s (cons pa+1 paren+1s))
             (set! ren+1 (c-sc-scan-lists pa+1 1 1)) ; Out of )/}/]; might signal
             (if (eq? (char-before pa+1) #\{) ; Check for a macro later.
                 (set! bra+1 pa+1))
             (set-car! paren+1s ren+1)
             (inner)))
          (if (and pa+1 (> pa+1 ren+1))
              ;; We've just entered a deeper nesting level.
              (begin
                ;; Insert the brace pair (if present) and the single
                ;; open paren/brace/bracket into `c-state-cache'.
                (c-state-push-any-brace-pair bra+1 macro-start-or-here)
                ;; Insert the opening brace/bracket/paren position.
                (set!c-state-cache (cons (- pa+1 1) (c-state-cache)))
                ;; Clear admin stuff for the next more nested part of
                ;; the scan.
                (set! ren+1 pa+1)
                (set! pa+1 #f)
                (set! bra+1 #f)
                #t)			; Carry on the loop
              ;; All open p/b/b's at this nesting level, if any, have
              ;; probably been closed by matching/mismatching ones.
              ;; We're probably finished - we just need to check for
              ;; having found an unmatched )/}/], which we ignore.
              (c-safe (begin
                        (set! ren+1 (c-sc-scan-lists ren+1 1 1))
                        ren+1))))	; acts as loop control.
    (loop)))

            ;; Record the final, innermost, brace-pair if there is one.
            (c-state-push-any-brace-pair bra+1 macro-start-or-here)

            ;; Determine a good pos
            (let loop ()
              (set! paren+1 (and (pair? paren+1s) (car paren+1s)))
              (when (and paren+1
                         (> (if (> paren+1 macro-start-or-here)
                                paren+1
                                (begin
                                  (goto-char paren+1)
                                  (set! mstart (and (c-beginning-of-macro) (point)))
                                  (or mstart paren+1)))
                            here-bol))
                (set! paren+1s (cdr paren+1s))
                (loop)))
            (cond
             ((and paren+1 mstart)
              (min paren+1 mstart))
             (paren+1)
             (else from))))))

    (define (c-remove-stale-state-cache start-point here pps-point)
      (save-excursion
        (save-restriction
          (narrow-to-region 1 (point-max))
          (let* ((in-macro-start   ; start of macro containing HERE or nil.
                  (save-excursion
                    (goto-char here)
                    (and (c-beginning-of-macro)
                         (point))))
                 (start-point-actual-macro-start
                  (and (< start-point here)
                       (save-excursion
                         (goto-char start-point)
                         (and (c-beginning-of-macro)
                              (point)))))
                 (start-point-actual-macro-end
                  (and start-point-actual-macro-start
                       (save-excursion
                         (goto-char start-point-actual-macro-start)
                         (c-end-of-macro)
                         (point))))
                 (pps-state #f)		; Will be 9 or 10 elements long.
                 (pos #f)
                 (upper-lim #f)		; beyond which `c-state-cache' entries are removed
                 (scan-back-pos #f)
                 (cons-separated #f)
                 (pair-beg #f) (target-depth #f))

            ;; Remove entries beyond HERE. Also remove any entries
            ;; inside a macro, unless HERE is in the same macro.
            (set! upper-lim
                  (if (or (not (c-state-old-cpp-beg))
                          (and (> here (c-state-pos-of (c-state-old-cpp-beg)))
                               (< here (c-state-pos-of (c-state-old-cpp-end)))))
                      here
                      (min here (c-state-pos-of (c-state-old-cpp-beg)))))
            (let loop () (when (and (pair? (c-state-cache))
                        (>= (c-state-cache-top-lparen) upper-lim))
              (set! scan-back-pos (%c-car (car (c-state-cache))))
              (set!c-state-cache (c--cdr (c-state-cache))) (loop)))

            ;; If `upper-lim' is inside the last recorded brace pair,
            ;; remove its RBrace and indicate we'll need to search
            ;; backwards for a previous brace pair.
            (when (and (pair? (c-state-cache))
                       (pair? (car (c-state-cache)))
                       (> (cdr (car (c-state-cache))) upper-lim))
              (set!c-state-cache (cons (car (car (c-state-cache)))
                                       (c--cdr (c-state-cache))))
              (set! scan-back-pos (car (c-state-cache)))
              (set! cons-separated #t))

            (set! pos (if (and start-point-actual-macro-end
                               (not (eq? start-point-actual-macro-start
                                         in-macro-start)))
                          (+ 1 start-point-actual-macro-end) ; get outside the macro as
					; marked by a `category' text property.
                          start-point))
            (goto-char pos)
            (let loop () (when (and (pair? (c-state-cache))
                        (or (number? (car (c-state-cache))) ; Have we a { at all?
                            (pair? (c--cdr (c-state-cache))))
                        (< (point) here))
              (cond
               ((not pps-state)		; first time through
                (set! target-depth -1))
               ((eq? (car pps-state) target-depth) ; found closing ),},]
                (set! target-depth (- (car pps-state) 1))))
              ;; Do nothing when we've merely reached pps-point.

              ;; Scan!
              (set! pps-state
                    (c-sc-parse-partial-sexp
                     (point) (if (< (point) pps-point) pps-point here)
                     target-depth
                     #f pps-state))

              (when (eq? (car pps-state) target-depth)
                (set! pos (point))	; POS is now just after an R-paren/brace.
                (cond
                 ((and (pair? (car (c-state-cache)))
                       (eq? (point) (cdr (car (c-state-cache)))))
                  ;; We've just moved out of the paren pair containing
                  ;; the brace-pair at (car c-state-cache).
                  (set! pair-beg (%c-car (c--cdr (c-state-cache))))
                  (set!c-state-cache (c--cdr (c--cdr (c-state-cache)))))
                 ((number? (car (c-state-cache)))
                  (set! pair-beg (car (c-state-cache)))
                  (set!c-state-cache (c--cdr (c-state-cache))))
                 ((number? (cadr (c-state-cache)))
                  (set! pair-beg (cadr (c-state-cache)))
                  (set!c-state-cache (c--cdr (c--cdr (c-state-cache))))))) (loop)))

            (if (< (point) pps-point)
                (set! pps-state (c-sc-parse-partial-sexp
                                 (point) pps-point
                                 #f #f	; TARGETDEPTH, STOPBEFORE
                                 pps-state)))

            ;; If the last paren pair we moved out of was actually a
            ;; brace pair, insert it into `c-state-cache'.
            (when (and pair-beg (eq? (char-after pair-beg) #\{))
              (if (pair? (%c-car (c-state-cache)))
                  (set!c-state-cache (c--cdr (c-state-cache))))
              (set!c-state-cache (cons (cons pair-beg pos)
                                       (c-state-cache))))

            (list pos scan-back-pos cons-separated pps-state)))))

    (define (c-remove-stale-state-cache-backwards here)
      (let ((cache-pos (c-get-cache-scan-pos here)) ; highest position below HERE in cache (or 1)
            (pos (c-state-cache-good-pos))
            (pa #f) (ren #f)		; positions of "(" and ")"
            (dropped-cons #f)		; whether the last element dropped
					; from `c-state-cache' was a cons.
            (good-pos #f)		; see above.
            (lit #f)			; (START . END) of a literal containing some point.
            (here-lit-start #f) (here-lit-end #f) ; bounds of literal containing `here'
            (here- #f) (here+ #f)	; start/end of macro around HERE, or HERE
            (here-bol (c-point 'bol here))
            (too-far-back (max (- here c-state-cache-too-far) (point-min))))

        ;; Remove completely irrelevant entries from `c-state-cache'.
        (let loop () (when (and (pair? (c-state-cache))
                    (>= (begin (set! pa (c-state-cache-top-lparen)) pa) here))
          (set! dropped-cons (pair? (car (c-state-cache))))
          (set!c-state-cache (c--cdr (c-state-cache)))
          (set! pos pa) (loop)))
        ;; At this stage, (>= pos here);
        ;; (< (c-state-cache-top-lparen) here)  (or is nil).

        (cond
         ((and (pair? (c-state-cache))
               (pair? (car (c-state-cache)))
               (> (cdr (car (c-state-cache))) here))
          ;; CASE 1: The top of the cache is a brace pair which now
          ;; encloses `here'.
          (set! pos (car (car (c-state-cache))))
          (set!c-state-cache (cons pos (c--cdr (c-state-cache))))
          (list (+ 1 pos) pos #t))	; We've just converted a brace pair
					; entry into a { entry.

         ;; `here' might be inside a literal. Check for this.
         ((begin
            (set! lit (c-state-literal-at here))
            (set! here-lit-start (or (and lit (car lit)) here))
            (set! here-lit-end (or (and lit (cdr lit)) here))
            ;; Has `here' just "newly entered" a macro?
            (save-excursion
              (goto-char here-lit-start)
              (if (and (c-beginning-of-macro)
                       (or (not (c-state-old-cpp-beg))
                           (not (= (point) (c-state-pos-of (c-state-old-cpp-beg))))))
                  (begin
                    (set! here- (point))
                    (c-end-of-macro)
                    (set! here+ (point)))
                  (begin
                    (set! here- here-lit-start)
                    (set! here+ here-lit-end))))

            ;; `here' might be nested inside any depth of parens (or
            ;; brackets but not braces). Scan backwards to find the
            ;; outermost such opening paren, if there is one.
            (save-restriction
              (narrow-to-region cache-pos (point-max))
              (set! pos (c-state-balance-parens-backwards here- here+ pos)))
            #f))			; for the cond

         ((< pos here-lit-start)
          ;; CASE 2: Address of outermost ( or [ which now encloses
          ;; `here', but didn't enclose the (previous)
          ;; `c-state-cache-good-pos'.
          (list pos (and dropped-cons pos) #t))

         ;; `here' isn't enclosed in a (previously unrecorded)
         ;; bracket/paren. Further forward scanning isn't needed, but we
         ;; still need to find a GOOD-POS. Step out of all enclosing "("s
         ;; on HERE's line.
         ((begin
            (save-restriction
              (narrow-to-region here-bol (point-max))
              (set! pos here-lit-start)
              (c-safe (let loop ()
                        (set! pa (c-sc-scan-lists pos -1 1)) ; might signal
                        (when pa
                          (set! pos pa)
                          (loop)))))
            #f))			; for the cond

         ((begin
            ;; The C's clause test is `(setq ren ...)' and its value is
            ;; what decides the clause. Guile's `set!' answers the
            ;; unspecified value, which is TRUE, so the clause below was
            ;; taken even when there was no unmatched close paren and
            ;; `ren' was #f - and `(+ 1 #f)' raised "Wrong type
            ;; argument" from inside `c-parse-state'. Answer `ren'.
            (save-restriction
              (narrow-to-region too-far-back (point-max))
              (set! ren (c-safe (c-sc-scan-lists pos -1 -1))))
            ren)
          ;; CASE 3: After a }/)/] before `here''s BOL.
          (list (+ 1 ren) (and dropped-cons pos) #f))

         ((begin
            (set! good-pos (c-state-lit-beg (c-point 'bopl here-bol)))
            (>= cache-pos good-pos))
          ;; CASE 3.5: Just after an existing entry in `c-state-cache'
          ;; on `here''s line or the previous line.
          (list cache-pos #f #f))

         (else
          ;; CASE 4; Best of a bad job: BOL before `here-bol', or
          ;; beginning of literal containing it.
          (list good-pos (and dropped-cons good-pos) #f)))))

    (define (c-state-cache-init)
      (set!c-state-cache '())
      (set!c-state-cache-good-pos 1)
      (set!c-state-cache-invalid-pos 1)
      (set!c-state-nonlit-pos-cache #f)
      (set!c-state-nonlit-pos-cache-limit 1)
      (set!c-state-brace-pair-desert #f)
      (set!c-state-point-min 1)
      (set!c-state-point-min-lit-type #f)
      (set!c-state-point-min-lit-start #f)
      (set!c-state-min-scan-pos 1)
      (set!c-state-old-cpp-beg #f)
      (set!c-state-old-cpp-end #f)
      (c-state-mark-point-min-literal))

    (define (c-truncate-lit-pos/state-cache pos)
      ;; "Truncate the upper bound of each of the four caches to POS, if
      ;; it is higher than that position."
      (c-truncate-lit-pos-cache pos)
      (set!c-state-cache-invalid-pos (min (c-state-cache-invalid-pos) pos)))

    (define (c-foreign-truncate-lit-pos-cache beg end)
      (c-truncate-lit-pos/state-cache beg))

    (define (c-foreign-init-lit-pos-cache)
      (c-truncate-lit-pos/state-cache 1))

    (define (c-invalidate-state-cache-1 here)
      ;; The caches of non-literals: note that we use "<=" for the
      ;; possibility of the second char of a two-char comment opener
      ;; being typed.
      (if (<= here (c-state-nonlit-pos-cache-limit))
          (set!c-state-nonlit-pos-cache-limit (- here 1)))

      (cond
       ;; Case 1: if `here' is in a literal containing point-min,
       ;; everything becomes (or is already) nil.
       ((or (not (c-state-cache-good-pos))
            (< here (c-state-get-min-scan-pos)))
        (set!c-state-cache '())
        (set!c-state-cache-good-pos #f)
        (set!c-state-cache-invalid-pos (c-state-get-min-scan-pos))
        (set!c-state-min-scan-pos #f))

       ;; Case 2: `here' is below `c-state-cache-good-pos', so we need
       ;; to amend the entire `c-state-cache' data.
       ((< here (c-state-cache-good-pos))
        (let* ((res (c-remove-stale-state-cache-backwards here))
               (good-pos (car res))
               (scan-backward-pos (cadr res))
               (scan-forward-p (car (cddr res))))
          (if scan-backward-pos
              (c-append-lower-brace-pair-to-state-cache scan-backward-pos here))
          (set!c-state-cache-good-pos
               (if scan-forward-p
                   (c-append-to-state-cache good-pos here)
                   good-pos))
          (set!c-state-cache-invalid-pos
               (or (c-state-cache-good-pos) (c-state-get-min-scan-pos))))))

      ;; The brace-pair desert marker:
      (let ((desert (c-state-brace-pair-desert)))
        (when (and desert (car desert))
          (if (< here (car desert))
              (set!c-state-brace-pair-desert #f)
              (if (< here (cdr desert))
                  (set-cdr! (c-state-brace-pair-desert) here))))))

    (define (c-parse-state-1)
      (let* ((here (point))
             (here-bopl (c-point 'bopl))
             (strategy #f)		; 'forward, 'backward etc..
             (cache-pos #f)		; highest position below HERE already
					; existing in cache (or 1).
             (good-pos #f)
             (start-point #f)		; (when scanning forward) a place below
					; HERE where there are no open
					; parens/braces between it and HERE.
             (bopl-state #f)
             (res #f)
             (cons-separated #f)
             (scan-backward-pos #f) (scan-forward-p #f)) ; used for 'backward.
        ;; If POINT-MIN has changed, adjust the cache
        (unless (= (point-min) (c-state-point-min))
          (c-renarrow-state-cache))

        ;; Strategy?
        (set! res (c-parse-state-get-strategy here (c-state-cache-good-pos)))
        (set! strategy (car res))
        (set! start-point (cadr res))

        (when (eq? strategy 'BOD)
          (set!c-state-cache '())
          (set!c-state-cache-good-pos start-point))

        ;; SCAN!
        (cond
         ((memq strategy '(forward back-and-forward BOD))
          (set! res (c-remove-stale-state-cache start-point here here-bopl))
          (set! cache-pos (car res))
          (set! scan-backward-pos (cadr res))
          (set! cons-separated (car (cddr res)))
          (set! bopl-state (cadr (cddr res))) ; will be nil if (< here-bopl
					; start-point)
          (if (and scan-backward-pos
                   (or cons-separated (eq? strategy 'forward))) ;scan-backward-pos
              (c-append-lower-brace-pair-to-state-cache scan-backward-pos here))
          (set! good-pos
                (c-append-to-state-cache cache-pos here))
          (set!c-state-cache-good-pos
               (if (and bopl-state
                        (< good-pos (- here c-state-cache-too-far)))
                   (c-state-cache-lower-good-pos here here-bopl bopl-state)
                   good-pos))
          (set!c-state-cache-invalid-pos (c-state-cache-good-pos)))

         ((eq? strategy 'backward)
          (set! res (c-remove-stale-state-cache-backwards here))
          (set! good-pos (car res))
          (set! scan-backward-pos (cadr res))
          (set! scan-forward-p (car (cddr res)))
          (if scan-backward-pos
              (c-append-lower-brace-pair-to-state-cache scan-backward-pos here))
          (set!c-state-cache-good-pos
               (if scan-forward-p
                   (c-append-to-state-cache good-pos here)
                   good-pos))
          (set!c-state-cache-invalid-pos (c-state-cache-good-pos)))

         (else				; (eq strategy 'IN-LIT)
          (set!c-state-cache '())
          (set!c-state-cache-good-pos #f))))

      (c-state-cache))

    (define (c-invalidate-state-cache)
      ;; "This is a wrapper over `c-invalidate-state-cache-1'. It
      ;; suppresses the syntactic effect of the < and > (template)
      ;; brackets and of all parens in preprocessor constructs, except
      ;; for any such construct containing point."
      ;;
      ;; The suppression is `c-with-<->-as-parens-suppressed'
      ;; (`cc-engine.el:4540'): the template brackets are marked through
      ;; the `category' text property, so their syntactic effect can be
      ;; turned off by clearing the category symbols' `syntax-table'
      ;; property - which is what lets `c-parse-state' ignore `<>' pairs
      ;; entirely. A comment here used to say there were no category
      ;; properties and nothing to suppress; that was true of the tree
      ;; before the `<>' marking landed, and it left an angle bracket in
      ;; the parse state where Emacs has none.
      (dynamic-wind c-suppress-<->-as-parens
                    (lambda ()
                      (c-invalidate-state-cache-1
                       (c-state-cache-invalid-pos)))
                    c-restore-<->-as-parens))

    (define (c-parse-state)
      (let ((here-cpp-beg #f) (here-cpp-end #f))
        (save-excursion
          (when (c-beginning-of-macro)
            (set! here-cpp-beg (point))
            (unless (> (begin (set! here-cpp-end (c-syntactic-end-of-macro))
                              here-cpp-end)
                       here-cpp-beg)
              (set! here-cpp-beg #f)
              (set! here-cpp-end #f))))
        (let ((result
               (dynamic-wind
                c-suppress-<->-as-parens
                (lambda ()
                  (when (< (c-state-cache-invalid-pos)
                           (or (c-state-cache-good-pos)
                               (c-state-get-min-scan-pos)))
                    (c-invalidate-state-cache-1 (c-state-cache-invalid-pos)))
                  (c-parse-state-1))
                c-restore-<->-as-parens)))
          (let ((m (c-state-maybe-marker here-cpp-beg
                                         (c-state-old-cpp-beg-marker))))
            (when m (set!c-state-old-cpp-beg-marker m))
            (set!c-state-old-cpp-beg m))
          (let ((m (c-state-maybe-marker here-cpp-end
                                         (c-state-old-cpp-end-marker))))
            (when m (set!c-state-old-cpp-end-marker m))
            (set!c-state-old-cpp-end m))
          result)))

    (define (c-whack-state-before bufpos paren-state)
      ;; "Whack off any state information from PAREN-STATE which lies
      ;; before BUFPOS. Not destructive on PAREN-STATE."
      (let loop ((ps paren-state) (acc '()))
        (if (not (pair? ps))
            (reverse acc)
            (let ((car* (car ps)))
              (if (< (if (pair? car*) (car car*) car*) bufpos)
                  (reverse acc)
                  (loop (cdr ps) (cons car* acc)))))))

    (define (c-whack-state-after bufpos paren-state)
      ;; "Whack off any state information from PAREN-STATE which lies at
      ;; or after BUFPOS. Not destructive on PAREN-STATE."
      (let loop ((ps paren-state))
        (if (not (pair? ps))
            '()
            (let ((elt (car ps)))
              (cond
               ((pair? elt)
                ;; "just check the car, because in a balanced brace
                ;; expression, it must be impossible for the
                ;; corresponding close brace to be before point, but the
                ;; open brace to be after."
                (cond ((<= bufpos (car elt)) (loop (cdr ps))) ; whack it off
                      ((< bufpos (cdr elt))
                       ;; its possible that the open brace is before
                       ;; bufpos, but the close brace is after. In that
                       ;; case, convert this to a non-cons element.
                       (cons (car elt) (cdr ps)))
                      (else ps)))
               ((<= bufpos elt) (loop (cdr ps))) ; whack it off
               (else ps))))))

    (define (c-most-enclosing-brace paren-state . args)
      ;; "Return the bufpos of the innermost enclosing open paren before
      ;; bufpos, or nil if none was found."
      (let ((bufpos (if (pair? args) (car args) #f))
            (enclosingp #f))
        (or bufpos (set! bufpos 134217727))
        (let loop ((ps paren-state))
          (if (not (pair? ps))
              enclosingp
              (let ((e (car ps)))
                (if (or (pair? e) (>= e bufpos))
                    (begin
                      (set! enclosingp #f)
                      (loop (cdr ps)))
                    e))))))

    (define (c-least-enclosing-brace paren-state)
      ;; "Return the bufpos of the outermost enclosing open paren, or
      ;; nil if none was found."
      (let ((pos #f))
        (let loop ((ps paren-state))
          (when (pair? ps)
            (let ((elem (car ps)))
              (if (integer? elem)
                  (set! pos elem)))
            (loop (cdr ps))))
        pos))

    (define (c-safe-position bufpos paren-state)
      ;; "Return the closest "safe" position recorded on PAREN-STATE
      ;; that is higher up than BUFPOS. Return nil if PAREN-STATE
      ;; doesn't contain any. Return nil if BUFPOS is nil."
      (and bufpos
           (let ((answer #f))
             (let loop ((ps paren-state))
               (when (and (pair? ps) (not answer))
                 (let ((elem (car ps)))
                   (if (pair? elem)
                       (cond ((< (cdr elem) bufpos)
                              (set! answer (cdr elem)))
                             ((< (car elem) bufpos)
                              (set! answer (min (+ 1 (car elem)) bufpos))))
                       (if (< elem bufpos)
                           (set! answer (min (+ 1 elem) bufpos)))))
                 (loop (cdr ps))))
             answer)))

    (define (c-beginning-of-syntax)
      ;; "This is used for `font-lock-beginning-of-syntax-function'. It
      ;; goes to the closest previous point that is known to be outside
      ;; any string literal or comment."
      (let* ((paren-state (c-state-cache))
             (elem #f)
             (pos (let loop ((ps paren-state))
                    (cond
                     ((not (pair? ps)) (point-min))
                     (else
                      (set! elem (car ps))
                      (cond
                       ((pair? elem)
                        (cond ((<= (cdr elem) (point)) (cdr elem))
                              ((<= (car elem) (point)) (car elem))
                              (else (loop (cdr ps)))))
                       ((<= elem (point)) elem)
                       (else (loop (cdr ps)))))))))
        (if (> pos (- (point) 4000))
            (goto-char pos)
            ;; The position is far back. Try `c-beginning-of-defun-1'
            ;; (although we can't be entirely sure it will go to a
            ;; position outside a comment or string in current
            ;; emacsen). FIXME: Consult `syntax-ppss' here.
            (begin
              (c-beginning-of-defun-1)
              (if (< (point) pos)
                  (goto-char pos))))))


    ;;------------------------------------------------------------------
    ;; Basic utility functions (`cc-engine.el:520')
    ;;------------------------------------------------------------------
    (define (c-delq-from-dotted-list elt dlist)
      ;; "If ELT is a member of the (possibly dotted) list DLIST, remove
      ;; all occurrences of it (except for any in the last cdr of
      ;; DLIST)."
      (let ((tail dlist) (prev #f))
        (let loop ()
          (when (pair? tail)
            (if (eq? (car tail) elt)
                (if prev
                    (set-cdr! prev (cdr tail))
                    (set! dlist (cdr dlist)))
                (set! prev tail))
            (set! tail (cdr tail))
            (loop)))
        dlist))

    (define (c-syntactic-content from to paren-level)
      ;; "Return the given region as a string where all syntactic
      ;; whitespace is removed or, where necessary, replaced with a
      ;; single space. If PAREN-LEVEL is given then all parens in the
      ;; region are collapsed to "()", "[]" etc.
      ;;
      ;; This function might do hidden buffer changes."
      (save-excursion
        (save-restriction
          (narrow-to-region from to)
          (goto-char from)
          (let* ((parts (list #f))
                 (tail parts)
                 (pos #f)
                 (in-paren #f))
            (let ((ws-start (%c-langvar 'c-syntactic-ws-start)))
              (let loop ()
                (if (and ws-start (re-search-forward ws-start to #t))
                    (begin
                      (goto-char (begin (set! pos (match-beginning 0)) pos))
                      (c-forward-syntactic-ws)
                      (if (= (point) pos)
                          (forward-char)
                          (begin
                            (when paren-level
                              (save-excursion
                                (set! in-paren
                                      (= (car (parse-partial-sexp from pos 1)) 1))
                                (set! pos (point))))
                            (if (and (> pos from)
                                     (< (point) to)
                                     (looking-at "\\w\\|\\s_")
                                     (save-excursion
                                       (goto-char (- pos 1))
                                       (looking-at "\\w\\|\\s_")))
                                (begin
                                  (set-cdr! tail
                                            (list (buffer-substring-no-properties
                                                   from pos)
                                                  " "))
                                  (set! tail (cddr tail)))
                                (begin
                                  (set-cdr! tail
                                            (list (buffer-substring-no-properties
                                                   from pos)))
                                  (set! tail (cdr tail))))
                            (when in-paren
                              (when (= (car (parse-partial-sexp pos to -1)) -1)
                                (set-cdr! tail
                                          (list (buffer-substring-no-properties
                                                 (- (point) 1) (point))))
                                (set! tail (cdr tail))))
                            (set! from (point))))
                      (loop))
                    #f)))
            (set-cdr! tail (list (buffer-substring-no-properties from to)))
            ;; Emacs's `(apply 'concat (cdr parts))' answers "" with no
            ;; parts; `string-append' with no arguments is an error, so
            ;; the empty prefix is given explicitly.
            (apply string-append "" (cdr parts))))))

    (define (c-shift-line-indentation shift-amt)
      ;; "Shift the indentation of the current line with the specified
      ;; amount (positive inwards). The buffer is modified only if
      ;; SHIFT-AMT isn't equal to zero."
      ;;
      ;; Emacs's `(let ((c-macro-start c-macro-start)) ...)' rebinds a
      ;; `defvar' that `let''s extent is the body: a `parameterize' here.
      (parameterize ((*c-macro-start* (*c-macro-start*)))
        (let ((pos (- (point-max) (point)))
              (tmp-char-inserted #f))
          (if (zero? shift-amt)
              #f
              (begin
                ;; "If we're on an empty line inside a macro, we take the
                ;; point to be at the current indentation and shift it to
                ;; the appropriate column. This way we don't treat the
                ;; extra whitespace out to the line continuation as
                ;; indentation."
                (when (and (c-query-and-set-macro-start)
                           (looking-at "[ \t]*\\\\$")
                           (save-excursion
                             (skip-chars-backward " \t")
                             (bolp)))
                  (insert #\x)
                  (backward-char)
                  (set! tmp-char-inserted #t))
                (dynamic-wind
                 (lambda () #f)
                 (lambda ()
                   (let ((col (current-indentation)))
                     (delete-region (c-point 'bol) (c-point 'boi))
                     (beginning-of-line)
                     (indent-to (+ col shift-amt))))
                 (lambda ()
                   (when tmp-char-inserted
                     (delete-char 1))))))
          ;; "If initial point was within line's indentation and we're
          ;; not on a line with a line continuation in a macro, position
          ;; after the indentation. Else stay at same point in text."
          (if (and (< (point) (c-point 'boi))
                   (not tmp-char-inserted))
              (back-to-indentation)
              (if (> (- (point-max) pos) (point))
                  (goto-char (- (point-max) pos)))))))

    ;;------------------------------------------------------------------
    ;; `c-keyword-sym' and `c-keyword-member' (`cc-engine.el:616')
    ;;------------------------------------------------------------------
    ;; `c-keywords-obarray' is a *language variable* here
    ;; (`cc-langs.scm`'s `c-lang-defvar`, `cc-langs.el:3663'), set by
    ;; `c-init-language-vars` - so a keyword lookup is a pure table read
    ;; and never evaluates language data in the caller's match-data
    ;; context. Emacs's obarray holds a symbol per keyword whose plist
    ;; lists the `*-kwds' memberships; this tree's hasher is keyed by the
    ;; keyword *string* with that same membership list as its value.
    (define (%c-keywords-table)
      (buffer-local-value (current-buffer) 'c-keywords-obarray #f))

    (define (c-keyword-sym keyword)
      ;; "Return non-nil if the string KEYWORD is a known keyword. More
      ;; precisely, the value is the symbol for the keyword in
      ;; `c-keywords-obarray'." (`intern-soft' into the per-language
      ;; table here - see the header.)
      (let ((table (%c-keywords-table)))
        (and table (hash-ref table keyword)
             (string->symbol keyword))))

    (define (c-keyword-member keyword-sym lang-constant)
      ;; "Return non-nil if the symbol KEYWORD-SYM, as returned by
      ;; `c-keyword-sym', is a member of LANG-CONSTANT, which is the name
      ;; of a language constant that ends with \"-kwds\". If KEYWORD-SYM
      ;; is nil then the result is nil."
      (and keyword-sym
           (let ((table (%c-keywords-table)))
             (and table
                  (let ((members (hash-ref table
                                           (symbol->string keyword-sym))))
                    (and (memq lang-constant members) #t))))))

    ;; "String syntax chars, suitable for skip-syntax-(forward|backward)."
    (define c-string-syntax
      (if (memq 'gen-string-delim c-emacs-features) "\"|" "\""))

    ;; "Regexp matching string limit syntax."
    (define c-string-limit-regexp
      (if (memq 'gen-string-delim c-emacs-features) "\\s\"\\|\\s|" "\\s\""))

    ;; "Regexp matching WS followed by string limit syntax."
    (define c-ws*-string-limit-regexp
      (string-append "[ \t]*\\(" c-string-limit-regexp "\\)"))

    ;; "Holds formatted error strings for the few cases where parse
    ;; errors are reported." Buffer-local in Emacs; a slot here.
    (define (c-parsing-error)
      (buffer-local-value (current-buffer) 'c-parsing-error #f))
    (define (set!c-parsing-error value)
      (set-buffer-local-value! (current-buffer) 'c-parsing-error value))

    (define (c-benign-error format-string . args)
      ;; `cc-defs.el:241': "Formats an error message for the echo area
      ;; and dings, i.e. like `error' but doesn't abort." `ding' is not
      ;; ported anywhere in this tree, so the echo-area half is the whole
      ;; of it here (named departure; `novice.scm' carries the same one).
      (apply message format-string args))

    (define (c-echo-parsing-error . quiet-args)
      ;; `cc-engine.el:637'.
      (let ((quiet (if (pair? quiet-args) (car quiet-args) #f)))
        (when (and (%c-true (*c-report-syntactic-errors*))
                   (c-parsing-error)
                   (%c-false quiet))
          ;; Emacs formats with "%s"; the message here is `editfns.scm''s
          ;; Guile-format one, whose directive for a string is `~a'.
          (c-benign-error "~a" (c-parsing-error)))
        (c-parsing-error)))

    (define (c-put-c-type-property pos value)
      ;; "Put a c-type property with the given value at POS."
      (c-put-char-property pos 'c-type value))

    (define (c-clear-c-type-property from to value)
      ;; "Remove all occurrences of the c-type property that has the
      ;; given value in the region between FROM and TO. VALUE is assumed
      ;; to not be nil. Note: This assumes that c-type is put on single
      ;; chars only; it's very inefficient if matching properties cover
      ;; large regions."
      (save-excursion
        (goto-char from)
        (let loop ()
          (when (eq? (get-text-property (point) 'c-type) value)
            (c-clear-char-property (point) 'c-type))
          (goto-char (c-next-single-property-change (point) 'c-type #f to))
          (if (< (point) to) (loop) #f))))

    ;;------------------------------------------------------------------
    ;; Token boundaries (`cc-engine.el:4911'-`:4938', moved up)
    ;;------------------------------------------------------------------
    ;; Moved up from their place in the file: `c-backward-sws' below
    ;; reads `c-beginning-of-current-token'. `c-end-of-token' and
    ;; `c-end-of-current-token' stay at their file position, which
    ;; nothing here reaches yet.
    (define (c-simple-skip-symbol-backward)
      ;; "If the point is at the end of a symbol then skip backward to
      ;; the beginning of it. Don't move otherwise. Return non-nil if
      ;; point moved."
      (or (< (skip-syntax-backward "w_") 0)
          (and (c-major-mode-is 'pike-mode)
               ;; "Handle the `<operator> syntax in Pike."
               (let ((pos (point)))
                 (if (and (< (skip-chars-backward "-!%&*+/<=>^|~[]()") 0)
                          (< (skip-chars-backward "`") 0)
                          (let ((re (%c-langvar 'c-symbol-key)))
                            (and re (looking-at re)))
                          (>= (match-end 0) pos))
                     #t
                     (begin (goto-char pos) #f))))))

    (define (c-beginning-of-current-token . back-limit-args)
      ;; "Move to the beginning of the current token. Do not move if not
      ;; in the middle of one. BACK-LIMIT may be used to bound the
      ;; backward search; if given it's assumed to be at the boundary
      ;; between two tokens. Return non-nil if the point is moved, nil
      ;; otherwise."
      (let ((back-limit (if (pair? back-limit-args) (car back-limit-args) #f))
            (start (point)))
        (if (looking-at "\\w\\|\\s_")
            (skip-syntax-backward "w_" back-limit)
            (when (< (skip-syntax-backward ".()" back-limit) 0)
              (let loop ()
                (let ((pos (or (and (let ((re (%c-langvar 'c-nonsymbol-token-regexp)))
                                      (and re (looking-at re)))
                                    (match-end 0))
                               ;; "`c-nonsymbol-token-regexp' should
                               ;; always match since we've skipped
                               ;; backward over punctuation or paren
                               ;; syntax, but consume one char in case it
                               ;; doesn't so that we don't leave point
                               ;; before some earlier incorrect token."
                               (+ (point) 1))))
                  (if (<= pos start)
                      (begin (goto-char pos) (loop))
                      #f)))))
        (< (point) start)))

    ;;------------------------------------------------------------------
    ;; `c-point' and `c-is-escaped' (`cc-defs.el:249', `:431')
    ;;------------------------------------------------------------------
    ;; See this library's header for why they live here. Emacs's macro
    ;; evaluates POSITION at expansion time and splices one of a set of
    ;; forms; the procedure takes the same symbol and answers the same
    ;; position. POINT is Emacs's `&optional', a rest parameter here.
    (define (c-point position . point-args)
      ;; "Return the value of certain commonly referenced POSITIONs
      ;; relative to POINT. The current point is used if POINT isn't
      ;; specified. ... If the referenced position doesn't exist, the
      ;; closest accessible point to it is returned. This function does
      ;; not modify the point or the mark."
      (if (pair? point-args)
          ;; `(save-excursion (goto-char POINT) ... (point))' - the
          ;; macro's non-fast expansion.
          (save-excursion
            (goto-char (car point-args))
            (c-point position))
          (case position
            ((bol)
             ;; Emacs's fast path: `(line-beginning-position)'.
             (line-beginning-position))
            ((boll)
             (save-excursion
               (let loop ()
                 (beginning-of-line)
                 (when (and (not (bobp))
                            (eq? (char-before (1- (point))) #\\))
                   (backward-char)
                   (loop)))
               (point)))
            ((eol)
             (line-end-position))
            ((eoll)
             (save-excursion
               (let loop ()
                 (when (and (not (eobp))
                            (begin
                              (end-of-line)
                              (c-is-escaped (point))))
                   (forward-line 1)
                   (loop)))
               (end-of-line)
               (point)))
            ((boi)
             (save-excursion
               (back-to-indentation)
               (point)))
            ((bod)
             (error "c-point 'bod' waits on `c-beginning-of-defun-1', which is not ported yet"))
            ((eod)
             (error "c-point 'eod' waits on `c-end-of-defun-1', which is not ported yet"))
            ((bopl)
             (line-beginning-position 0))
            ((bonl)
             (line-beginning-position 2))
            ((eopl)
             (line-end-position 0))
            ((eonl)
             (line-end-position 2))
            ((iopl)
             (save-excursion
               (forward-line -1)
               (back-to-indentation)
               (point)))
            ((ionl)
             (save-excursion
               (forward-line 1)
               (back-to-indentation)
               (point)))
            ((bosws)
             (save-excursion (c-backward-syntactic-ws) (point)))
            ((eosws)
             (save-excursion (c-forward-syntactic-ws) (point)))
            (else
             (error "Unknown buffer position requested: ~a" position)))))

    (define (c-is-escaped pos)
      ;; "Is the character following POS escaped?" (`cc-defs.el:431'.)
      (save-excursion
        (goto-char pos)
        (if (and (%c-true (%c-langvar 'c-escaped-newline-takes-precedence))
                 (memv (char-after (point)) (list #\newline #\return)))
            (eq? (char-before) #\\)
            (not (zero? (logand (skip-chars-backward "\\\\") 1))))))
    ;;------------------------------------------------------------------
    ;; `c-looking-at-c++-attribute' (`cc-engine.el:721')
    ;;------------------------------------------------------------------
    ;; Emacs's macro is all expression, so it is a procedure here. It
    ;; answers the position just after the attribute's closing `]]', or
    ;; #f; point is left where it was, as the macro's `save-excursion'
    ;; leaves it.
    (define (c-looking-at-c++-attribute)
      ;; "If we're in C or C++ Mode, and point is at the [[ introducing
      ;; an attribute, return the position of the end of the attribute,
      ;; otherwise return nil.  The match data are NOT preserved over
      ;; this macro."
      (and (c-major-mode-is '(c-mode c++-mode))
           (looking-at "\\[\\[")
           (save-excursion
             (and (c-go-list-forward)
                  (eq? (char-before) #\])
                  (eq? (char-before (1- (point))) #\])
                  (point)))))

    ;;------------------------------------------------------------------
    ;; `c-beginning-of-statement-1' and its automaton
    ;; (`cc-engine.el:736'-`:1455')
    ;;------------------------------------------------------------------
    ;; "KLUDGE ALERT: c-maybe-labelp is used to pass information between
    ;; `c-crosses-statement-barrier-p' and `c-beginning-of-statement-1'."
    ;; Both are `defvar's that this code `let'-binds, so both are
    ;; parameters (their definitions are Emacs's own position, ahead of
    ;; the functions that use them).
    (define *c-maybe-labelp* (make-parameter #f))
    (define *c-commas-bound-stmts* (make-parameter #f))

    ;; The C's `c-bos-*' macros close over the automaton's lexical
    ;; variables and the `catch' tag. Scheme macros are hygienic, so
    ;; they are a `let-syntax' *inside* the function's `let' - which is
    ;; where the variables they name are in scope - and the two that
    ;; throw take the escape continuation as their first argument.
    (define (c-beginning-of-statement-1 . args)
      ;; "Move to the start of the current statement or declaration, or
      ;; to the previous one if already at the beginning of one. ..."
      ;;
      ;; "The bulk of this function is a pushdown automaton ..."
      (let ((lim (if (pair? args) (car args) #f))
            (ignore-labels (if (and (pair? args) (pair? (cdr args)))
                               (cadr args) #f))
            (noerror (if (and (pair? args) (pair? (cdr args))
                              (pair? (cddr args)))
                         (caddr args) #f))
            (comma-delim (if (and (pair? args) (pair? (cdr args))
                                  (pair? (cddr args)) (pair? (cdddr args)))
                             (cadddr args) #f))
            (hit-lim (if (and (pair? args) (pair? (cdr args))
                              (pair? (cddr args)) (pair? (cdddr args))
                              (pair? (cddddr args)))
                         (car (cddddr args)) #f)))
        (parameterize ((*case-fold-search* #f)
                       (*c-commas-bound-stmts*
                        (or (*c-commas-bound-stmts*) comma-delim))
                       (*c-maybe-labelp* #f))
          (let* ((start (point))
                 (macro-start #f)
                 (delims (if comma-delim (list #\; #\,) (list #\;)))
                 (after-case:-pos #f) ; `after-case:-pos' in the C.
                 (saved #f)
                 ;; "Current position."
                 (pos #f)
                 ;; "Position of last stmt boundary character (e.g. ;)."
                 (boundary-pos #f)
                 ;; "Non-nil when a construct has been found which
                 ;; delimits the search for a statement start, e.g. an
                 ;; opening brace or a macro start, or a keyword like
                 ;; `if' when the PDA stack is empty."
                 (pre-stmt-found #f)
                 ;; "The position of the last sexp or bound that follows
                 ;; the first found colon, i.e. the start of the nonlabel
                 ;; part of the statement."
                 (after-labels-pos #f)
                 ;; "Like `after-labels-pos', but the first such
                 ;; position inside a label."
                 (last-label-pos #f)
                 ;; "The last position where a label is possible ..."
                 (label-good-pos #f)
                 ;; "Putative positions of the components of a bitfield
                 ;; declaration, e.g. \"int foo : NUM_FOO_BITS ;\"."
                 (bitfield-type-pos #f)
                 (bitfield-id-pos #f)
                 (bitfield-size-pos #f)
                 ;; "Symbol just scanned back over (e.g. 'while or
                 ;; 'boundary)."
                 (sym #f)
                 ;; "Current state in the automaton."
                 (state #f)
                 ;; "Current saved positions."
                 (saved-pos #f)
                 ;; "Stack of conses (state . saved-pos)."
                 (stack '())
                 ;; "Regexp which matches \"for\", \"if\", etc."
                 (cond-key (or (%c-langvar 'c-opt-block-stmt-key)
                               regexp-unmatchable))
                 ;; "Return value."
                 (ret 'same)
                 ;; "Positions of the last three sexps or bounds we've
                 ;; stopped at."
                 (tok #f)
                 (ptok #f)
                 (pptok #f))
            (letrec-syntax
                ((c-bos-push-state
                  (syntax-rules ()
                    ((_) (set! stack (cons (cons state saved-pos) stack)))))
                 (c-bos-pop-state
                  (syntax-rules ()
                    ((_ done) (c-bos-pop-state done #f))
                    ((_ done do)
                     (begin
                       (set! state (car (car stack)))
                       (set! saved-pos (cdr (car stack)))
                       (set! stack (cdr stack))
                       ;; The C's condition is the value of the last
                       ;; `setq' - the new stack. `'()' is true in
                       ;; Scheme, so the C's `(if stack ...)' is a
                       ;; `pair?' test.
                       (if (pair? stack)
                           #t
                           (begin
                             do
                             (set! pre-stmt-found #t)
                             (done #f)))))))
                 (c-bos-pop-state-and-retry
                  (syntax-rules ()
                    ((_ done)
                     (done
                      (begin
                        (set! state (car (car stack)))
                        (set! saved-pos (cdr (car stack)))
                        (set! pre-stmt-found (not (pair? (cdr stack))))
                        ;; "Throw nil if stack is empty, else throw
                        ;; non-nil." The thrown value is the *new*
                        ;; stack, and an empty Scheme list is true -
                        ;; so it has to be #f when the stack empties, or
                        ;; the driver's loop never ends.
                        (set! stack (cdr stack))
                        (if (pair? stack) stack #f))))))
                 (c-bos-save-pos
                  (syntax-rules ()
                    ((_) (set! saved-pos (vector pos tok ptok pptok)))))
                 (c-bos-restore-pos
                  (syntax-rules ()
                    ((_)
                     (if (not (eq? (vector-ref saved-pos 0) start))
                         (begin
                           (set! pos (vector-ref saved-pos 0))
                           (set! tok (vector-ref saved-pos 1))
                           (set! ptok (vector-ref saved-pos 2))
                           (set! pptok (vector-ref saved-pos 3))
                           (goto-char pos)
                           (set! sym #f))))))
                 (c-bos-save-error-info
                  (syntax-rules ()
                    ((_ missing got)
                     (set! saved-pos (vector pos missing got)))))
                 (c-bos-report-error
                  (syntax-rules ()
                    ((_)
                     (if (not (%c-true noerror))
                         (set!c-parsing-error
                          (format-message
                           "No matching `%s' found for `%s' on line %d"
                           (vector-ref saved-pos 1)
                           (vector-ref saved-pos 2)
                           (+ 1 (%count-lines
                                 (current-buffer) (point-min)
                                 (c-point 'bol
                                          (vector-ref saved-pos 0)))))))))))
              (save-restriction
                (set! lim (if lim (max lim (point-min)) (point-min)))
                (widen)

                (save-excursion
                  (if (and (c-beginning-of-macro) (not (= (point) start)))
                      (set! macro-start (point))))

                  ;; "Try to skip back over unary operator characters, to
                  ;; register that we've moved."
                  (let skip ()
                    (set! pos (point))
                    (c-backward-syntactic-ws lim)
                    ;; "Protect post-++/-- operators just before a
                    ;; virtual semicolon."
                    (when (and (not (c-at-vsemi-p))
                               (not (= (skip-chars-backward "-+!*&~@`#") 0)))
                      (skip)))

                  ;; "Skip back over any semicolon here. If it was a bare
                  ;; semicolon, we're done. ..."
                  (if (and (memv (char-before) delims)
                           (begin
                             (forward-char -1)
                             (set! saved (point))
                             (c-backward-syntactic-ws lim)
                             (or (memv (char-before) delims)
                                 (eq? (char-before) #\:)
                                 (not (char-before))
                                 (eq? (char-syntax (char-before)) #\()
                                 (c-at-vsemi-p))))
                      (begin
                        (set! ret 'previous)
                        (set! pos saved))

                      ;; "Begin at start and not pos to detect macros if
                      ;; we stand directly after the #."
                      (begin
                        (goto-char start)
                        (if (let ((re (%c-langvar 'c-symbol-start)))
                              ;; Emacs's regexp is "\\_<\\|\\W"; the
                              ;; language's c-symbol-start is the same
                              ;; test for the modes here.
                              (and re (looking-at "\\_<\\|\\W")))
                            ;; "Record this as the first token if not
                            ;; starting inside it."
                            (set! tok start))

                        ;; "The following while loop goes back one sexp
                        ;; ... each iteration."
                        (let automaton ()
                          (when (call-with-current-continuation
                                 (lambda (done)
                                   ;; "Are we in a macro, just after the
                                   ;; opening #?"
                                   (cond
                                    ((save-excursion
                                       (and macro-start ; "Always NIL for AWK."
                                            (begin
                                              (skip-chars-backward " \t")
                                              (eq? (char-before) #\#))
                                            (begin
                                              (set! saved (- (point) 1))
                                              (beginning-of-line)
                                              (not (eq? (char-before
                                                         (- (point) 1))
                                                        #\\)))
                                            (let ((re (%c-langvar
                                                       'c-opt-cpp-start)))
                                              (and re (looking-at re)))
                                            (begin
                                              (skip-chars-forward " \t")
                                              (eq? (point) saved))))
                                     (goto-char saved)
                                     (if (and (c-forward-to-cpp-define-body)
                                              (begin
                                                (c-forward-syntactic-ws start)
                                                (< (point) start)))
                                         ;; "Stop at the first token in the
                                         ;; content of the macro."
                                         (begin
                                           (set! pos (point))
                                           (set! ignore-labels #t))
                                         (begin
                                           (set! pos saved)
                                           (set! ret 'macro)
                                           (set! ignore-labels #t)))
                                     (set! pre-stmt-found #t)
                                     (done #f)) ; 1. Start of macro.

                                    ;; "Do a round through the automaton if
                                    ;; we've just passed a statement
                                    ;; boundary or passed a "while"-like
                                    ;; token."
                                    ((or sym
                                         (begin
                                           (if (looking-at cond-key)
                                               (set! sym (intern (match-string 1)))
                                               #f)))
                                     (when (and (< pos start) (null? stack))
                                       (set! pre-stmt-found #t)
                                       (done #f)) ; 2. Statement boundary.

                                     ;; "The PDA state handling."
                                     (or (cond
                                          ((eq? state 'else)
                                           (if (eq? sym 'boundary)
                                               (set! state 'else-boundary)
                                               (begin
                                                 (c-bos-report-error)
                                                 (c-bos-pop-state-and-retry done) #t)))
                                          ((eq? state 'else-boundary)
                                           (cond ((eq? sym 'if)
                                                  (c-bos-pop-state
                                                   done (set! ret 'beginning)))
                                                 ((eq? sym 'boundary)
                                                  (c-bos-report-error)
                                                  (c-bos-pop-state done))
                                                 (else #f)))
                                          ((eq? state 'while)
                                           (if (and (eq? sym 'boundary)
                                                    ;; "Since this can cause
                                                    ;; backtracking we do a
                                                    ;; little more careful
                                                    ;; analysis to avoid it:
                                                    ;; If there's a label in
                                                    ;; front of the while it
                                                    ;; can't be part of a
                                                    ;; do-while."
                                                    (not after-labels-pos))
                                               (begin
                                                 (c-bos-save-pos)
                                                 (set! state 'while-boundary)
                                                 #t)
                                               (begin
                                                 (c-bos-pop-state-and-retry done)
                                                 #t)))
                                          ((eq? state 'while-boundary)
                                           (cond ((eq? sym 'do)
                                                  (c-bos-pop-state
                                                   done (set! ret 'beginning)))
                                                 ((eq? sym 'boundary) ; "isn't a do-while"
                                                  (c-bos-restore-pos) ; "the position of the while"
                                                  (c-bos-pop-state done))
                                                 (else #f)))
                                          ((eq? state 'catch)
                                           (if (eq? sym 'boundary)
                                               (set! state 'catch-boundary)
                                               (begin
                                                 (c-bos-report-error)
                                                 (c-bos-pop-state-and-retry done) #t)))
                                          ((eq? state 'catch-boundary)
                                           (cond
                                            ((eq? sym 'try)
                                             (c-bos-pop-state
                                              done (set! ret 'beginning)))
                                            ((eq? sym 'catch)
                                             (set! state 'catch))
                                            ((eq? sym 'boundary)
                                             (c-bos-report-error)
                                             (c-bos-pop-state done))
                                            (else #f)))
                                           (else #f))
                                         ;; "This is state common. ..."
                                         (cond ((eq? sym 'boundary)
                                                ;; "If we have a boundary at
                                                ;; the start position we push
                                                ;; a frame to go to the
                                                ;; previous statement."
                                                (if (>= pos start)
                                                    (c-bos-push-state)
                                                    (c-bos-pop-state done)))
                                               ((eq? sym 'else)
                                                (c-bos-push-state)
                                                (c-bos-save-error-info 'if 'else)
                                                (set! state 'else))
                                               ((eq? sym 'while)
                                                ;; "Is this a real while, or a
                                                ;; do-while? ..."
                                                (when (or (not pptok)
                                                          (memv (char-after pptok)
                                                                delims)
                                                          ;; "The following
                                                          ;; kludge is to
                                                          ;; prevent infinite
                                                          ;; recursion ..."
                                                          (and (eq? (point) start)
                                                               (c-vsemi-status-unknown-p))
                                                          (c-at-vsemi-p pptok))
                                                  (c-bos-push-state)
                                                  (set! state 'while)))
                                               ((memq sym '(catch finally))
                                                (c-bos-push-state)
                                                (c-bos-save-error-info 'try sym)
                                                (set! state 'catch))))

                                     (when (*c-maybe-labelp*)
                                       ;; "We're either past a statement
                                       ;; boundary or at the start of a
                                       ;; statement, so throw away any label
                                       ;; data for the previous one."
                                       (set! after-labels-pos #f)
                                       (set! last-label-pos #f)
                                       (*c-maybe-labelp* #f))))

                                   ;; "Step to the previous sexp, but not if
                                   ;; we crossed a boundary, since that
                                   ;; doesn't consume an sexp."
                                   (if (eq? sym 'boundary)
                                       (when (>= (point) lim)
                                         (set! ret 'previous))

                                       ;; "HERE IS THE SINGLE PLACE INSIDE
                                       ;; THE PDA LOOP WHERE WE MOVE
                                       ;; BACKWARDS THROUGH THE SOURCE."
                                       (begin
                                         (c-backward-syntactic-ws lim)
                                         (let ((before-sws-pos (point))
                                               ;; "The end position of the
                                               ;; area to search for statement
                                               ;; barriers in this round."
                                               (maybe-after-boundary-pos pos)
                                               (comma-delimited #f))

                                           ;; "Go back over exactly one
                                           ;; logical sexp, taking proper
                                           ;; account of macros and escaped
                                           ;; EOLs."
                                           (let sexp-step ()
                                             (when (and
                                                    (begin
                                                      (set! comma-delimited
                                                            (and (not comma-delim)
                                                                 (eq? (char-before) #\,)))
                                                      (if (not (c-safe (c-backward-sexp) #t))
                                                          (begin
                                                            ;; "Give up if we
                                                            ;; hit an unbalanced
                                                            ;; block. ..."
                                                            (set! pre-stmt-found #t)
                                                            (done #f))
                                                          #t)
                                                      ;; "Handle C++'s
                                                      ;; `constexpr', etc."
                                                      (if (save-excursion
                                                            (and (let ((re (%c-langvar
                                                                            'c-block-stmt-hangon-key)))
                                                                   (and re (looking-at re)))
                                                                 (begin
                                                                   (c-backward-syntactic-ws lim)
                                                                   (c-safe (c-backward-sexp) #t))
                                                                 (let ((re (%c-langvar
                                                                            'c-block-stmt-2-key)))
                                                                   (and re (looking-at re)))
                                                                 (begin
                                                                   (set! pos (point))
                                                                   pos)))
                                                          (goto-char pos)
                                                          #f)
                                                      (cond
                                                       ;; "Have we moved into
                                                       ;; a macro?"
                                                       ((and (not macro-start)
                                                             (c-beginning-of-macro))
                                                        (save-excursion
                                                          (c-backward-syntactic-ws lim)
                                                          (set! before-sws-pos (point)))
                                                        ;; "Have we crossed a
                                                        ;; statement boundary?
                                                        ;; If not, keep going
                                                        ;; back until we find
                                                        ;; one or a "real"
                                                        ;; sexp."
                                                        (if (save-excursion
                                                              (c-end-of-macro)
                                                              (not (c-crosses-statement-barrier-p
                                                                    (point)
                                                                    maybe-after-boundary-pos)))
                                                            (begin
                                                              (set! maybe-after-boundary-pos (point))
                                                              maybe-after-boundary-pos)
                                                            #f))
                                                       ;; "Have we just gone
                                                       ;; back over an escaped
                                                       ;; NL? This doesn't
                                                       ;; count as a sexp."
                                                       ((looking-at "\\\\$"))
                                                       (else #f)))
                                                      (>= (point) lim))
                                               (sexp-step)))

                                           ;; "Have we crossed a statement
                                           ;; boundary?"
                                           (set! boundary-pos
                                                 (cond
                                                  ;; "Are we at a macro
                                                  ;; beginning?"
                                                  ((and (not macro-start)
                                                        (%c-langvar 'c-opt-cpp-prefix)
                                                        (let ((re (%c-langvar
                                                                   'c-opt-cpp-prefix)))
                                                          (and re (looking-at re))))
                                                   (save-excursion
                                                     (c-end-of-macro)
                                                     (c-crosses-statement-barrier-p
                                                      (point) maybe-after-boundary-pos)))
                                                  ;; "Just gone back over a
                                                  ;; brace block?"
                                                  ((and (eq? (char-after (point)) #\{)
                                                        (not comma-delimited)
                                                        (not (c-looking-at-inexpr-block lim #f #t))
                                                        (save-excursion
                                                          (c-backward-token-2 1 #t #f) ; "Don't test the value"
                                                          (not (let ((re "=\\([^=]\\|$\\)"))
                                                                 (looking-at re))))
                                                        (or
                                                         (not (%c-langvar 'c-opt-block-decls-with-vars-key))
                                                         (save-excursion
                                                           (c-backward-token-2 1 #t #f)
                                                           (if (and (let ((re (%c-langvar 'c-symbol-start)))
                                                                      (and re (looking-at re)))
                                                                    (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                                                           (and re (looking-at re)))))
                                                               (c-backward-token-2 1 #t #f)
                                                               #f)
                                                           (and
                                                            (not (let ((re (%c-langvar
                                                                            'c-opt-block-decls-with-vars-key)))
                                                                   (and re (looking-at re))))
                                                            (or comma-delim
                                                                (not (eq? (char-after (point)) #\,))))))
                                                        ;; "Is the {..} followed
                                                        ;; by an operator which
                                                        ;; prevents it being a
                                                        ;; statement in its own
                                                        ;; right?"
                                                        (save-excursion
                                                          (and
                                                           (c-go-list-forward)
                                                           (begin
                                                             (c-forward-syntactic-ws)
                                                             (or
                                                              (not (let ((re (%c-langvar
                                                                              '#{c-non-after-{}-ops-re}#)))
                                                                     (and re (looking-at re))))
                                                              (let ((bad-op-len
                                                                     (- (match-end 0)
                                                                        (match-beginning 0))))
                                                                (and
                                                                 (let ((re (%c-langvar 'c-operator-re)))
                                                                   (and re (looking-at re)))
                                                                 (> (- (match-end 0)
                                                                       (match-beginning 0))
                                                                    bad-op-len))))))))
                                                   (save-excursion
                                                     (c-forward-sexp) (point)))
                                                  ;; "Just gone back over some
                                                  ;; paren block?"
                                                  ((looking-at "\\s(")
                                                   (save-excursion
                                                     (goto-char (+ 1 (c-down-list-backward
                                                                     before-sws-pos)))
                                                     (c-crosses-statement-barrier-p
                                                      (point) maybe-after-boundary-pos)))
                                                  ;; "Just gone back over an
                                                  ;; ordinary symbol of some
                                                  ;; sort?"
                                                  (else (c-crosses-statement-barrier-p
                                                         (point) maybe-after-boundary-pos))))
                                           (when boundary-pos
                                             (set! pptok ptok)
                                             (set! ptok tok)
                                             (set! tok boundary-pos)
                                             (set! sym 'boundary)
                                             ;; "Like a C "continue". Analyze
                                             ;; the next sexp."
                                             (done #t)))))

                                   ;; "Have we gone past the limit?"
                                   (when (< (point) lim)
                                     (done #f)) ; 3. Gone back over the limit.

                                   ;; "ObjC method def?"
                                   (when (and (%c-langvar 'c-opt-method-key)
                                              (begin
                                                (set! saved (c-in-method-def-p))
                                                saved))
                                     (set! pos saved)
                                     (set! pre-stmt-found #t)
                                     (set! ignore-labels #t) ; "Avoid the label check on exit."
                                     (done #f)) ; 4. ObjC method def.

                                   ;; "Might we have a bitfield
                                   ;; declaration, \"<type> <id> : <size>\"?"
                                   (if (%c-langvar 'c-has-bitfields)
                                       (cond
                                        ;; "The : <size> and <id> fields?"
                                        ((and (number? (*c-maybe-labelp*))
                                              (not bitfield-size-pos)
                                              (save-excursion
                                                (goto-char (or tok start))
                                                (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                                       (and re (looking-at re)))))
                                              (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                                     (and re (looking-at re))))
                                              (not (c-punctuation-in (point)
                                                                     (*c-maybe-labelp*))))
                                         (set! bitfield-size-pos (or tok start))
                                         (set! bitfield-id-pos (point)))
                                        ;; "The <type> field?"
                                        ((and bitfield-id-pos
                                              (not bitfield-type-pos))
                                         (if (and (let ((re (%c-langvar 'c-symbol-key)))
                                                    (and re (looking-at re))) ; "Can only be an integer type. :-)"
                                                  (not (let ((re (%c-langvar
                                                                  'c-not-primitive-type-keywords-regexp)))
                                                         (and re (looking-at re))))
                                                  (not (c-punctuation-in (point) tok)))
                                             (set! bitfield-type-pos (point))
                                             (begin
                                               (set! bitfield-size-pos #f)
                                               (set! bitfield-id-pos #f))))))

                                   ;; "Handle labels."
                                   (if (not (eq? ignore-labels #t))
                                       (begin
                                         (when (number? (*c-maybe-labelp*))
                                           ;; "`c-crosses-statement-barrier-p'
                                           ;; has found a colon, so we might
                                           ;; be in a label now. ..."
                                           (set! after-case:-pos (or tok start))
                                           (if (or (let ((re (%c-langvar 'c-nonlabel-nonparen-token-key)))
                                                     (and re (looking-at re))) ; "e.g. \"while\" or \"'a'\""
                                                   ;; "Catch C++'s inheritance
                                                   ;; construct \"class foo :
                                                   ;; bar\"."
                                                   (save-excursion
                                                     (and
                                                      (c-safe (c-backward-sexp) #t)
                                                      (let ((re (%c-langvar 'c-nonlabel-token-2-key)))
                                                        (and re (looking-at re)))))
                                                   ;; "Catch C++'s \"case a(1):\""
                                                   (and (c-major-mode-is 'c++-mode)
                                                        (eq? (char-after (point)) #\()
                                                        (save-excursion
                                                          (not (and
                                                                (= (c-backward-token-2 2) 0)
                                                                (let ((re (%c-langvar 'c-case-kwds-regexp)))
                                                                  (and re (looking-at re))))))))
                                               (*c-maybe-labelp* #f)
                                               (begin
                                                 (if after-labels-pos ; "Have we already encountered a label?"
                                                     (if (not last-label-pos)
                                                         (set! last-label-pos (or tok start)))
                                                     (set! after-labels-pos (or tok start)))
                                                 (*c-maybe-labelp* #t)
                                                 (set! label-good-pos #f)))) ; "bogus \"label\""

                                         (when (and (not label-good-pos) ; "i.e. no invalid \"label\"'s yet"
                                                    (let ((re (%c-langvar 'c-nonlabel-token-key)))
                                                      (and re (looking-at re)))) ; "e.g. \"while :\""
                                           ;; "We're in a potential label and
                                           ;; it's the first time we've found
                                           ;; something that isn't allowed in
                                           ;; one."
                                           (set! label-good-pos (or tok start)))))

                                   ;; "We've moved back by a sexp, so update
                                   ;; the token positions."
                                   (set! sym #f)
                                   (set! pptok ptok)
                                   (set! ptok tok)
                                   (set! tok (point))
                                   (set! pos tok) ; "always non-nil"
                                   pos))
                            (automaton)))

                        (when (and hit-lim
                                   (or (not pre-stmt-found)
                                       (< pos lim)
                                       (>= pos start)))
                          (set! ret #f))

                        ;; "If the stack isn't empty there might be errors
                        ;; to report."
                        (let drain ()
                          (when (pair? stack)
                            (if (and (vector? saved-pos)
                                     (= (vector-length saved-pos) 3))
                                (c-bos-report-error))
                            (set! saved-pos (cdr (car stack)))
                            (set! stack (cdr stack))
                            (drain)))

                        (when (and (eq? ret 'same)
                                   (not (memq sym '(boundary ignore #f))))
                          ;; "Need to investigate closer whether we've
                          ;; crossed between a substatement and its
                          ;; containing statement."
                          (let ((saved2
                                 (cond ((and (let ((re (%c-langvar 'c-block-stmt-1-2-key)))
                                               (and re (looking-at re)))
                                             (eq? (char-after ptok) #\())
                                        pptok)
                                       ((let ((re (%c-langvar 'c-block-stmt-1-key)))
                                          (and re (looking-at re)))
                                        ptok)
                                       (else pptok))))
                            (set! saved saved2)
                            (when saved
                              (cond ((> start saved) (set! pos saved))
                                    ((= start saved) (set! ret 'up))))))

                        (when (and (not ignore-labels)
                                   (eq? (*c-maybe-labelp*) #t)
                                   (not (eq? ret 'beginning))
                                   after-labels-pos
                                   (not bitfield-type-pos) ; "Bitfields take precedence over labels."
                                   (or (not label-good-pos)
                                       (<= label-good-pos pos)
                                       (begin
                                         (goto-char (if (and last-label-pos
                                                             (< last-label-pos start))
                                                        last-label-pos
                                                        pos))
                                         (let ((re (%c-langvar 'c-label-kwds-regexp)))
                                           (and re (looking-at re))))))
                          ;; "We're in a label. Maybe we should step to the
                          ;; statement after it."
                          (if (< after-labels-pos start)
                              (set! pos after-labels-pos)
                              (begin
                                (set! ret 'label)
                                (if (and last-label-pos (< last-label-pos start))
                                    ;; "Might have jumped over several
                                    ;; labels. Go to the last one."
                                    (set! pos last-label-pos)))))))

                        ;; "Have we got \"case <expression>:\"?"
                        (goto-char pos)
                        (when (and after-case:-pos
                                   (not (eq? ret 'beginning))
                                   (let ((re (%c-langvar 'c-case-kwds-regexp)))
                                     (and re (looking-at re))))
                          (if (< after-case:-pos start)
                              (set! pos after-case:-pos))
                          (if (eq? ret 'same)
                              (set! ret 'label)))

                        ;; "Skip over the unary operators that can start
                        ;; the statement."
                        (let trailing ()
                          (when (and (> (point) lim)
                                     (begin
                                       (c-backward-syntactic-ws lim)
                                       ;; "protect AWK post-inc/decrement
                                       ;; operators, etc."
                                       (and (not (c-at-vsemi-p (point)))
                                            (not (= (skip-chars-backward
                                                     "-.+!*&~@`#")
                                                    0)))))
                            (set! pos (point))
                            (trailing)))

                        (goto-char pos)
                        ret))))))

    ;;------------------------------------------------------------------
    ;; Statement barriers (`cc-engine.el:1457'-`:1560')
    ;;------------------------------------------------------------------
    ;; `*c-maybe-labelp*' and `*c-commas-bound-stmts*' are defined above,
    ;; at their `cc-engine.el:742' position.
    (define (c-punctuation-in from to)
      ;; "Return non-nil if there is a non-comment non-macro punctuation
      ;; character between FROM and TO. FROM must not be in a string or
      ;; comment. The returned value is the position of the first such
      ;; character."
      (save-excursion
        (goto-char from)
        (let ((pos (point)))
          (let loop ()
            (when (begin
                    (let ((chars (%c-langvar 'c-symbol-chars)))
                      (skip-chars-forward (if chars chars "") to))
                    (c-forward-syntactic-ws to)
                    (> (point) pos))
              (set! pos (point))
              (loop)))
          (and (< (point) to) (point)))))

    (define (c-crosses-statement-barrier-p from to)
      ;; "Return non-nil if buffer positions FROM to TO cross one or more
      ;; statement or declaration boundaries. The returned value is
      ;; actually the position of the earliest boundary char. FROM must
      ;; not be within a string or comment.
      ;;
      ;; The variable `c-maybe-labelp' is set to the position of the
      ;; first `:' that might start a label (i.e. not part of `::' and not
      ;; preceded by `?'). If a single `?' is found, then
      ;; `c-maybe-labelp' is cleared.
      ;;
      ;; For AWK, a statement which is terminated by an EOL (not a ; or
      ;; a }) is regarded as having a \"virtual semicolon\" immediately
      ;; after the last token on the line. If this virtual semicolon is
      ;; _at_ from, the function recognizes it.
      ;;
      ;; Note that this function might do hidden buffer changes."
      (let* ((skip-chars (if (*c-commas-bound-stmts*)
                             (%c-langvar
                              'c-stmt-boundary-skip-chars-with-comma)
                             (%c-langvar 'c-stmt-boundary-skip-chars))) ; "e.g. \"^#;{}?:\""
             (non-skip-list (if (*c-commas-bound-stmts*)
                                (%c-langvar
                                 'c-stmt-boundary-skip-list-with-comma)
                                (%c-langvar 'c-stmt-boundary-skip-list))) ; "e.g. (?# ?\; ?{ ?} ?? ?:)"
             (lit-range #f)
             (lit-start #f)
             (vsemi-pos #f)
             (attr-end #f))
        (save-restriction
          (widen)
          (save-excursion
            (call-with-current-continuation
             (lambda (done)
               (goto-char from)
               (let loop ()
                 (when (begin
                         (skip-chars-forward (if skip-chars skip-chars "")
                                             (min to (c-point 'bonl)))
                         (< (point) to))
                   (cond
                    ;; "Virtual semicolon?"
                    ((and (bolp)
                          (save-excursion
                            (begin
                              ;; "Have we landed in a string/comment?"
                              (if (begin
                                    (set! lit-start (c-literal-start from))
                                    lit-start)
                                  (goto-char lit-start))
                              (c-backward-syntactic-ws (c-point 'bopl))
                              (set! vsemi-pos (point))
                              (c-at-vsemi-p))))
                     (done vsemi-pos))
                    ;; "Optimize for large blocks of comments."
                    ((begin (c-forward-syntactic-ws to) (>= (point) to))
                     (done #f))
                    ;; "In a string/comment?"
                    ((begin (set! lit-range (c-literal-limits from)) lit-range)
                     (goto-char (cdr lit-range)))
                    ;; "Skip over a C or C++ attribute?"
                    ((eq? (char-after (point)) #\[)
                     (if (begin (set! attr-end (c-looking-at-c++-attribute))
                                attr-end)
                         (goto-char attr-end)
                         (forward-char)))
                    ((eq? (char-after (point)) #\:)
                     (forward-char)
                     (if (and (eq? (char-after (point)) #\:)
                              (< (point) to))
                         ;; "Ignore scope operators."
                         (forward-char)
                         (*c-maybe-labelp* (- (point) 1))))
                    ((eq? (char-after (point)) #\?)
                     ;; "A question mark. Can't be a label, so stop
                     ;; looking for more : and ?."
                     (*c-maybe-labelp* #f)
                     (set! skip-chars
                           (%substring (if (*c-commas-bound-stmts*)
                                           (%c-langvar
                                            'c-stmt-delim-chars-with-comma)
                                           (%c-langvar 'c-stmt-delim-chars))
                                       0 -2)))
                    ;; "At a CPP construct or a \"#\" or \"##\" operator?"
                    ((let ((re (%c-langvar 'c-opt-cpp-symbol)))
                       (and re (looking-at re)))
                     (if (save-excursion
                           (skip-chars-backward " \t")
                           (and (bolp)
                                (or (bobp)
                                    (not (eq? (char-before (- (point) 1))
                                              #\\)))))
                         (c-end-of-macro)
                         (let ((re (%c-langvar 'c-opt-cpp-symbol)))
                           (skip-chars-forward (if re re "")))))
                    ((memq (char-after (point)) non-skip-list)
                     (done (point))))
                   (loop)))
               ;; "In trailing space after an as yet undetected virtual
               ;; semicolon?"
               (c-backward-syntactic-ws from)
               (when (and (bolp) (not (bobp))) ; "Can happen in AWK Mode with an
                                               ; unterminated string/regexp."
                 (backward-char))
               (if (and (< (point) to)
                        (c-at-vsemi-p))
                   (point)
                   #f)))))))

    ;;------------------------------------------------------------------
    ;; `c-at-statement-start-p' and `c-at-expression-start-p'
    ;; (`cc-engine.el:1562'-`:1617')
    ;;------------------------------------------------------------------
    ;; They reach forward to `c-syntactic-skip-backward' and
    ;; `c-looking-at-special-brace-list', which are ported later in the
    ;; file - Emacs's own file has the same forward references.
    (define (c-at-statement-start-p)
      ;; "Return non-nil if point is at the first token in a statement or
      ;; somewhere in the syntactic whitespace before it. ..."
      ;;
      ;; "Note that this function might do hidden buffer changes."
      (save-excursion
        (let ((end (point)))
          (parameterize ((*c-maybe-labelp* #f))
            (c-syntactic-skip-backward
             (%substring
              (if (*c-commas-bound-stmts*)
                  (%c-langvar 'c-stmt-delim-chars-with-comma)
                  (%c-langvar 'c-stmt-delim-chars))
              1)
             #f #t)
            (or (bobp)
                (eq? (char-before) #\})
                (and (eq? (char-before) #\{)
                     (not (and (%c-langvar 'c-special-brace-lists)
                               (begin (backward-char)
                                      (c-looking-at-special-brace-list)))))
                (c-crosses-statement-barrier-p (point) end))))))

    (define (c-at-expression-start-p)
      ;; "Return non-nil if point is at the first token in an expression or
      ;; statement, or somewhere in the syntactic whitespace before it.
      ;; ..."
      ;;
      ;; "Note that this function might do hidden buffer changes."
      (save-excursion
        (let ((end (point)))
          (parameterize ((*c-commas-bound-stmts* #t)
                         (*c-maybe-labelp* #f))
            (c-syntactic-skip-backward
             (%substring (%c-langvar 'c-stmt-delim-chars-with-comma) 1)
             #f #t)
            (or (bobp)
                (memv (char-before) (list #\{ #\}))
                (save-excursion
                  (backward-char)
                  (looking-at "\\s("))
                (c-crosses-statement-barrier-p (point) end))))))
    ;; `(make-obsolete 'c-at-expression-start-p nil "CC mode 5.35")' -
    ;; there is no byte-compiler to tell, so the marking is not carried.

    ;;------------------------------------------------------------------
    ;; The syntactic-whitespace change hooks (`cc-engine.el:1947'-`:2125')
    ;;------------------------------------------------------------------
    ;; "The type of literal position `end' is in a `before-change-functions'
    ;; function - one of `c', `c++', `pound', `noise', `attribute' or nil
    ;; (but NOT `string')." Emacs declares both with a plain `defvar'
    ;; and nothing makes them buffer-local, so they are plain variables.
    (define c-sws-lit-type #f)
    ;; "A cons (START . STOP) of the bounds of the comment or CPP
    ;; construct, etc., enclosing END, if any, else nil."
    (define c-sws-lit-limits #f)

    (define (c-enclosing-c++-attribute)
      ;; "If we're in C or C++ Mode, and point is within a correctly
      ;; balanced [[ ... ]] attribute structure, return a cons of its
      ;; starting and ending positions. Otherwise, return nil."
      (and (c-major-mode-is '(c-mode c++-mode))
           (save-excursion
             (let ((lim (max (- (point) 200) (point-min)))
                   (cand #f))
               (let loop ()
                 (when (and (begin
                              (skip-chars-backward "^[;{}" lim)
                              (eq? (char-before) #\[))
                            (not (eq? (char-before (1- (point))) #\[))
                            (> (point) lim))
                   (backward-char)
                   (loop)))
               (and (eq? (char-before) #\[)
                    (eq? (char-before (1- (point))) #\[)
                    (begin (backward-char 2) #t)
                    (begin (set! cand (point)) #t)
                    (c-go-list-forward #f (min (+ (point) 200) (point-max)))
                    (eq? (char-before) #\])
                    (eq? (char-before (1- (point))) #\])
                    (not (c-literal-limits))
                    (cons cand (point)))))))

    (define (c-invalidate-sws-region-before beg end)
      ;; "Called from `c-before-change'. BEG and END are the bounds of
      ;; the change region, the standard parameters given to all
      ;; before-change-functions.
      ;;
      ;; Note whether END is inside a comment, CPP construct, or noise
      ;; macro, and if so note its bounds in `c-sws-lit-limits' and type
      ;; in `c-sws-lit-type'."
      (set! c-sws-lit-type #f)
      (set! c-sws-lit-limits #f)
      (save-match-data
        (save-excursion
          (goto-char end)
          (let* ((limits (c-literal-limits))
                 (lit-type (c-literal-type limits)))
            (cond
             ((memq lit-type '(c c++))
              (set! c-sws-lit-type lit-type)
              (set! c-sws-lit-limits limits))
             ((c-beginning-of-macro)
              (set! c-sws-lit-type 'pound)
              (set! c-sws-lit-limits (cons (point)
                                           (begin (c-end-of-macro) (point)))))
             ((eq? lit-type 'string)
              #f)
             ((begin (set! c-sws-lit-limits (c-enclosing-c++-attribute))
                     c-sws-lit-limits)
              (set! c-sws-lit-type 'attribute))
             ((begin (skip-syntax-backward "w_")
                     (looking-at (c-noise-macro-name-re)))
              (set! c-sws-lit-type 'noise)
              (set! c-sws-lit-limits (cons (match-beginning 1) (match-end 1))))
             (else #f))))
        (save-excursion
          (goto-char beg)
          (let ((attr-limits (c-enclosing-c++-attribute)))
            (if attr-limits
                (if (pair? c-sws-lit-limits)
                    (set-car! c-sws-lit-limits (car attr-limits))
                    (set! c-sws-lit-limits attr-limits))
                (begin
                  (skip-syntax-backward "w_")
                  (when (looking-at (c-noise-macro-name-re))
                    (set! c-sws-lit-type 'noise)
                    (if (pair? c-sws-lit-limits)
                        (set-car! c-sws-lit-limits (match-beginning 1))
                        (set! c-sws-lit-limits (cons (match-beginning 1)
                                                     (match-end 1)))))))))))

    (define (c-invalidate-sws-region-after-del beg end old-len)
      ;; "Text has been deleted, OLD-LEN characters of it starting from
      ;; position BEG. END is typically eq to BEG. Should there have
      ;; been a comment or CPP construct open at END before the
      ;; deletion, check whether this deletion deleted or "damaged" its
      ;; opening delimiter. If so, return the current position of where
      ;; the construct ended, otherwise return nil."
      (when c-sws-lit-limits
        (if (and (< beg (+ (car c-sws-lit-limits) 2))
                 ;; "A lazy assumption that comment delimiters are 2
                 ;; chars long."
                 (or (get-text-property end 'c-in-sws)
                     (c-next-single-property-change end 'c-in-sws #f
                                                    (cdr c-sws-lit-limits))
                     (get-text-property end 'c-is-sws)
                     (c-next-single-property-change end 'c-is-sws #f
                                                    (cdr c-sws-lit-limits))))
            (cdr c-sws-lit-limits)
            #f)))

    (define (c-invalidate-sws-region-after-ins end)
      ;; "Text has been inserted, ending at buffer position END. Should
      ;; there be a literal or CPP construct open at END, check whether
      ;; there are `c-in-sws' or `c-is-sws' text properties inside this
      ;; literal. If there are, return the buffer position of the end
      ;; of the literal, else return nil."
      (save-excursion
        (goto-char end)
        (let* ((limits (c-literal-limits))
               (lit-type (c-literal-type limits)))
          (when (and (not (memq lit-type '(c c++)))
                     (c-beginning-of-macro))
            (set! lit-type 'pound)
            (set! limits (cons (point)
                               (begin (c-end-of-macro) (point)))))
          (when (memq lit-type '(c c++ pound))
            (let ((next-in (c-next-single-property-change (car limits) 'c-in-sws
                                                          #f (cdr limits)))
                  (next-is (c-next-single-property-change (car limits) 'c-is-sws
                                                          #f (cdr limits))))
              (and (or next-in next-is)
                   (cdr limits)))))))

    (define (c-invalidate-sws-region-after beg end old-len)
      ;; "Called from `after-change-functions'. Remove any stale
      ;; `c-in-sws' or `c-is-sws' text properties from the vicinity of
      ;; the change. BEG, END, and OLD-LEN are the standard arguments
      ;; given to after-change functions.
      ;;
      ;; Note that if `c-forward-sws' or `c-backward-sws' are used
      ;; outside `c-save-buffer-state' or similar then this will remove
      ;; the cache properties right after they're added.
      ;;
      ;; This function does hidden buffer changes."
      (when c-sws-lit-limits
        (set-car! c-sws-lit-limits (min beg (car c-sws-lit-limits)))
        (set-cdr! c-sws-lit-limits
                  (max end (- (+ (cdr c-sws-lit-limits) (- end beg)) old-len))))
      (let ((del-end (and (> old-len 0)
                          (c-invalidate-sws-region-after-del beg end old-len)))
            (ins-end (and (> end beg)
                          (c-invalidate-sws-region-after-ins end))))
        (begin
          (save-excursion
            ;; "Adjust the end to remove the properties in any following
            ;; simple ws up to and including the next line break, if
            ;; there is any after the changed region. This is necessary
            ;; e.g. when a rung marked empty line is converted to a
            ;; line comment by inserting "//" before the line break. In
            ;; that case the line break would keep the rung mark which
            ;; could make a later `c-backward-sws' move into the line
            ;; comment instead of over it."
            (goto-char end)
            (skip-chars-forward " \t\f\v")
            (when (and (eolp) (not (eobp)))
              (set! end (+ (point) 1))))

          (when (memq c-sws-lit-type '(noise attribute))
            (set! beg (car c-sws-lit-limits))
            (set! end (cdr c-sws-lit-limits))) ; "This last setting may be redundant."

          (when (and (= beg end)
                     (get-text-property beg 'c-in-sws)
                     (> beg (point-min))
                     (get-text-property (- beg 1) 'c-in-sws))
            ;; "Ensure that an `c-in-sws' range gets broken. Note that
            ;; it isn't safe to keep a range that was continuous before
            ;; the change. E.g:
            ;;
            ;;    #define foo
            ;;         \
            ;;    bar
            ;;
            ;; There can be a "ladder" between "#" and "b". Now, if
            ;; the newline after "foo" is removed then "bar" will
            ;; become part of the cpp directive instead of a
            ;; syntactically relevant token. In that case there's no
            ;; longer syntactic ws from "#" to "b"."
            (set! beg (- beg 1)))

          (set! end (max (or del-end end)
                         (or ins-end end)
                         (or (if c-sws-lit-limits (cdr c-sws-lit-limits) #f) end)
                         end))

          (c-debug-sws-msg "c-invalidate-sws-region-after [~a..~a]" beg end)
          (c-remove-is-and-in-sws beg end))))
    ;;------------------------------------------------------------------
    ;; `c-forward-sws' (`cc-engine.el:2127')
    ;;------------------------------------------------------------------
    ;; The syntactic-whitespace engine's four whitespace sets. Emacs
    ;; writes them inline in the source, each ending in a literal
    ;; no-break space (U+00A0); the names here say which is which.
    (define %c-sws-any " \t\n\r\f\v\xa0")
    (define %c-sws-horiz " \t\f\v\xa0")
    (define %c-sws-back-horiz " \t\f\xa0")
    (define %c-sws-bol " \t\xa0")

    (define (c-forward-sws)
      ;; "Used by `c-forward-syntactic-ws' to implement the unbounded
      ;; search.
      ;;
      ;; This function might do hidden buffer changes."
      (let ((rung-pos (point))
            (next-rung-pos #f)
            (rung-end-pos #f)
            (last-put-in-sws-pos #f)
            (rung-is-marked #f)
            (next-rung-is-marked #f)
            (simple-ws-end #f)
            (macro-start #f)
            (macro-end #f)
            (safe-start #f))
        ;; "Skip simple ws and do a quick check on the following
        ;; character to see if it's anything that can't start syntactic
        ;; ws, so we can bail out early in the majority of cases when
        ;; there just are a few ws chars."
        (c-skip-ws-chars-forward %c-sws-any)
        (when (or (let ((re (%c-langvar 'c-syntactic-ws-start)))
                    (and re (looking-at re)))
                  (and (%c-langvar 'c-opt-cpp-prefix)
                       (looking-at (c-noise-macro-name-re)))
                  (and (c-major-mode-is '(c-mode c++-mode))
                       (looking-at "\\[\\["))
                  (looking-at (c-doc-line-join-re)))

          (set! rung-end-pos (min (+ (point) 1) (point-max)))
          (if (begin
                (set! rung-is-marked
                      (text-property-any rung-pos rung-end-pos 'c-is-sws #t))
                rung-is-marked)
              ;; "Find the last rung position to avoid setting properties
              ;; in all the cases when the marked rung is complete.
              ;; (`c-next-single-property-change' is certain to move at
              ;; least one step forward.)"
              (set! rung-pos
                    (- (c-next-single-property-change rung-is-marked 'c-is-sws
                                                      #f rung-end-pos)
                       1))
              ;; "Got no marked rung here. Since the simple ws might have
              ;; started inside a line comment or cpp directive we must
              ;; set `rung-pos' as high as possible."
              (set! rung-pos (point)))

          (with-silent-modifications
            (define (ladder-step)
              (if (and rung-is-marked
                       (get-text-property (point) 'c-in-sws))
                  (begin
                    ;; "The following search is the main reason that
                    ;; `c-in-sws' and `c-is-sws' aren't combined to one
                    ;; property."
                    (goto-char (c-next-single-property-change
                                (point) 'c-in-sws #f (point-max)))
                    (unless (get-text-property (point) 'c-is-sws)
                      ;; "If the `c-in-sws' region extended past the last
                      ;; `c-is-sws' char we have to go back a bit."
                      (or (get-text-property (- (point) 1) 'c-is-sws)
                          (goto-char (c-previous-single-property-change
                                      (point) 'c-is-sws #f #f)))
                      (backward-char))
                    (c-debug-sws-msg
                     "c-forward-sws cached move ~a -> ~a (max ~a)"
                     rung-pos (point) (point-max))
                    (set! rung-pos (point))
                    (and (> (c-skip-ws-chars-forward %c-sws-any) 0)
                         (not (eobp))))
                  #f))

            (define (ladder)
              ;; Emacs's `(while (when TEST BODY...))': the test has the
              ;; side effects, and the loop runs its body while the test
              ;; is true.
              (when (ladder-step)
                ;; "We'll loop here if there is simple ws after the last
                ;; rung. That means that there's been some change in it
                ;; and it's possible that we've stepped into another
                ;; ladder, so extend the previous one to join with it if
                ;; there is one, and try to use the cache again."
                (c-debug-sws-msg
                 "c-forward-sws extending rung with [~a..~a] (max ~a)"
                 (+ rung-pos 1) (+ (point) 1) (point-max))
                (unless (get-text-property (point) 'c-is-sws)
                  ;; "Remove any `c-in-sws' property from the last char of
                  ;; the rung before we mark it with `c-is-sws', so that
                  ;; we won't connect with the remains of a broken
                  ;; "ladder"."
                  (c-remove-in-sws (point) (+ (point) 1)))
                (c-put-is-sws (+ rung-pos 1) (+ (point) 1))
                (c-put-in-sws rung-pos (point))
                (set! rung-pos (point))
                (set! last-put-in-sws-pos rung-pos)
                (ladder)))

            (define (advance)
              (ladder)
              ;; "Now move over any comments (x)or a CPP construct."
              (set! simple-ws-end (point))
              (set! safe-start #t)
              ;; "Take elaborate precautions to detect an open block
              ;; comment at the end of a macro. If we find one, we set
              ;; `safe-start' to nil and break off any further scanning of
              ;; comments."
              ;;
              ;; "(2019-05-02): `c-end-of-macro' now moves completely over
              ;; block comments, even multiline ones lacking \s at their
              ;; EOLs. So a lot of the following is probably redundant
              ;; now."
              (let ((com-begin (point))
                    (com-end #f)
                    (in-macro #f))
                (when (and (c-forward-single-comment)
                           (begin (set! com-end (point)) #t)
                           (save-excursion
                             (goto-char com-begin)
                             (c-beginning-of-macro)))
                  (set! in-macro #t)
                  (goto-char com-begin)
                  (if (begin (c-end-of-macro com-end)
                             (< (point) com-end))
                      (set! safe-start #f)
                      #f))
                (if in-macro
                    (let loop ()
                      (when (and safe-start
                                 com-end (> com-end com-begin)
                                 (begin (set! com-begin (point)) #t)
                                 (if (and (c-forward-single-comment)
                                          (begin (set! com-end (point)) #t))
                                     (begin
                                       (goto-char com-begin)
                                       (if (begin (c-end-of-macro com-end)
                                                  (< (point) com-end))
                                           (set! safe-start #f)
                                           #f)
                                       safe-start)
                                     #f))
                        (loop)))
                    (c-forward-comments)))
              (cond
               ((not (= (point) simple-ws-end))
                ;; "Skipped over comments. Don't cache at eob in case the
                ;; buffer is narrowed."
                (not (eobp)))

               ((save-excursion
                  (let ((cpp-start (%c-langvar 'c-opt-cpp-start)))
                    (and (%c-langvar 'c-opt-cpp-prefix)
                         (and cpp-start (looking-at cpp-start))
                         (begin (set! macro-start (point)) #t)
                         (begin (c-skip-ws-chars-backward %c-sws-bol) (bolp))
                         (or (bobp)
                             (begin (backward-char)
                                    (not (eq? (char-before) #\\)))))))
                ;; "Skip a preprocessor directive."
                (end-of-line)
                (let loop ()
                  (if (and (eq? (char-before) #\\)
                           (= (forward-line 1) 0))
                      (begin (end-of-line) (loop))
                      #f))
                (set! macro-end (point))
                ;; "Check for an open block comment at the end of the
                ;; macro."
                (let ((s (parse-partial-sexp macro-start macro-end)))
                  (if (and (%c-true (nth 4 s))     ; "in a comment"
                           (%c-false (nth 7 s)))   ; "a block comment"
                      (set! safe-start #f)
                      #f))
                (forward-line 1)
                ;; "Don't cache at eob in case the buffer is narrowed."
                (not (eobp)))

               ((and (%c-langvar 'c-opt-cpp-prefix)
                     (looking-at (c-noise-macro-name-re)))
                ;; "Skip over a noise macro without parens."
                (goto-char (match-end 1))
                (not (eobp)))

               ((begin (set! next-rung-pos (c-looking-at-c++-attribute))
                       next-rung-pos)
                (goto-char next-rung-pos)
                (not (eobp)))

               ((looking-at (c-doc-line-join-re))
                ;; "Skip over a line join in (e.g.) Pike autodoc."
                (goto-char (match-end 0))
                (set! safe-start #f) ; "Never cache this; the doc style
                                     ; could be changed at any time."
                (not (eobp)))

               ;; Emacs's `cond' answers nil when nothing matches and
               ;; the outer loop then ends; a Scheme `cond' answers the
               ;; *unspecified* value, which is true, so the arm is
               ;; written out.
               (else #f)))

            (let outer ()
              (when (advance)
                ;; "We've searched over a piece of non-white syntactic ws.
                ;; See if this can be cached."
                (set! next-rung-pos (point))
                (c-skip-ws-chars-forward %c-sws-any)
                (set! rung-end-pos (min (+ (point) 1) (point-max)))

                (if (or
                     ;; "Cache if we haven't skipped comments only, and
                     ;; if we started either from a marked rung or from a
                     ;; completely uncached position."
                     (and safe-start
                          (or rung-is-marked
                              (not (get-text-property simple-ws-end 'c-in-sws))))

                     ;; "See if there's a marked rung in the encountered
                     ;; simple ws. If so then we can cache, unless
                     ;; `safe-start' is nil. Even then we need to do this
                     ;; to check if the cache can be used for the next
                     ;; step."
                     (and (begin
                            (set! next-rung-is-marked
                                  (text-property-any next-rung-pos rung-end-pos
                                                     'c-is-sws #t))
                            next-rung-is-marked)
                          safe-start))

                    (begin
                      (c-debug-sws-msg
                       "c-forward-sws caching [~a..~a] - [~a..~a] (max ~a)"
                       rung-pos (+ simple-ws-end 1) next-rung-pos rung-end-pos
                       (point-max))

                      ;; "Remove the properties for any nested ws that
                      ;; might be cached. Only necessary for `c-is-sws'
                      ;; since `c-in-sws' will be set anyway."
                      (c-remove-is-sws (+ simple-ws-end 1) next-rung-pos)
                      (unless (and rung-is-marked (= rung-pos simple-ws-end))
                        (c-put-is-sws rung-pos (+ simple-ws-end 1))
                        (set! rung-is-marked #t))
                      (c-put-in-sws rung-pos
                                    (begin (set! rung-pos (point))
                                           (set! last-put-in-sws-pos rung-pos)
                                           rung-pos))
                      (unless (get-text-property (- rung-end-pos 1) 'c-is-sws)
                        ;; "Remove any `c-in-sws' property from the last
                        ;; char of the rung before we mark it with
                        ;; `c-is-sws', so that we won't connect with the
                        ;; remains of a broken "ladder"."
                        (c-remove-in-sws (- rung-end-pos 1) rung-end-pos))
                      (c-put-is-sws next-rung-pos rung-end-pos))

                    (begin
                      (c-debug-sws-msg
                       "c-forward-sws not caching [~a..~a] - [~a..~a] (max ~a)"
                       rung-pos (+ simple-ws-end 1) next-rung-pos rung-end-pos
                       (point-max))

                      ;; "Set `rung-pos' for the next rung. It's the same
                      ;; thing here as initially, except that the rung
                      ;; position is set as early as possible since we
                      ;; can't be in the ending ws of a line comment or
                      ;; cpp directive now."
                      (if (begin (set! rung-is-marked next-rung-is-marked)
                                 rung-is-marked)
                          (set! rung-pos
                                (- (c-next-single-property-change
                                    rung-is-marked 'c-is-sws #f rung-end-pos)
                                   1))
                          (set! rung-pos next-rung-pos))))
                (outer)))

            ;; "Make sure that the newly marked `c-in-sws' region doesn't
            ;; connect to another one after the point (which might occur
            ;; when editing inside a comment or macro)."
            ;;
            ;; Emacs's `(when TEST (cond ...))' is the value of this
            ;; function, and nil when TEST fails; the `if' answers #f
            ;; there, and the removal calls answer nil in Emacs where
            ;; ours answer #t.
            (if (eq? last-put-in-sws-pos (point))
              (begin
              (cond ((< last-put-in-sws-pos (point-max))
                     (c-debug-sws-msg
                      "c-forward-sws clearing at ~a for cache separation"
                      last-put-in-sws-pos)
                     (c-remove-in-sws last-put-in-sws-pos
                                      (+ last-put-in-sws-pos 1)))
                    (else
                     ;; "If at eob we have to clear the last character
                     ;; before the end instead since the buffer might be
                     ;; narrowed and there might be a `c-in-sws' after
                     ;; (point-max). In this case it's necessary to clear
                     ;; both properties."
                     (c-debug-sws-msg
                      "c-forward-sws clearing thoroughly at ~a for cache separation"
                      (- last-put-in-sws-pos 1))
                     (c-remove-is-and-in-sws (- last-put-in-sws-pos 1)
                                             last-put-in-sws-pos)))
              #f))
            ;; Emacs's `when's answer nil, and a Scheme `when' answers
            ;; the unspecified value, which is true - callers read this
            ;; answer (`c-forward-primary-expression' tests it in a loop
            ;; condition). Emacs's answer is nil on every path, so the
            ;; values here and after the outer `when' are spelled out.
            #f))
            #f))
    ;;------------------------------------------------------------------
    ;; `c-backward-sws' (`cc-engine.el:2381')
    ;;------------------------------------------------------------------
    (define (c-backward-sws)
      ;; "Used by `c-backward-syntactic-ws' to implement the unbounded
      ;; search.
      ;;
      ;; This function might do hidden buffer changes."
      (let ((rung-pos (point))
            (next-rung-pos #f)
            (last-put-in-sws-pos #f)
            (rung-is-marked #f)
            (simple-ws-beg #f)
            (cmt-skip-pos #f)
            (doc-line-join-here (string-append (c-doc-line-join-re) "\\="))
            (attr-end #f))
        ;; "Skip simple horizontal ws and do a quick check on the
        ;; preceding character to see if it's anything that can't end
        ;; syntactic ws, so we can bail out early in the majority of cases
        ;; when there just are a few ws chars. Newlines are complicated in
        ;; the backward direction, so we can't skip over them."
        (c-skip-ws-chars-backward %c-sws-back-horiz)
        (when (and (not (bobp))
                   (save-excursion
                     (or (and (c-doc-line-join-end-ch)
                              (memq (char-before) (c-doc-line-join-end-ch)) ; "For speed."
                              (re-search-backward doc-line-join-here
                                                  (c-point 'bopl) #t))
                         (and (c-major-mode-is '(c-mode c++-mode))
                              (eq? (char-before) #\])
                              (eq? (char-before (- (point) 1)) #\])
                              (save-excursion
                                (and (c-go-list-backward)
                                     (looking-at "\\[\\[")))
                              (begin (set! attr-end (point)) attr-end))
                         (begin
                           (backward-char)
                           (or (let ((re (%c-langvar 'c-syntactic-ws-end)))
                                 (and re (looking-at re)))
                               (and (%c-langvar 'c-opt-cpp-prefix)
                                    (let ((re (%c-langvar 'c-symbol-char-key)))
                                      (and re (looking-at re)))
                                    (begin
                                      (c-beginning-of-current-token)
                                      (looking-at (c-noise-macro-name-re)))))))))
          ;; "Try to find a rung position in the simple ws preceding point,
          ;; so that we can get a cache hit even if the last bit of the
          ;; simple ws has changed recently."
          (set! simple-ws-beg (or attr-end (match-end 1) (match-end 0)))
          (c-skip-ws-chars-backward %c-sws-any)
          (if (begin
                (set! rung-is-marked
                      (text-property-any (point) (min (+ rung-pos 1) (point-max))
                                         'c-is-sws #t))
                rung-is-marked)
              ;; "`rung-pos' will be the earliest marked position, which
              ;; means that there might be later unmarked parts in the
              ;; simple ws region. It's not worth the effort to fix that;
              ;; the last part of the simple ws is also typically edited
              ;; often, so it could be wasted."
              (goto-char (begin (set! rung-pos rung-is-marked) rung-pos))
              (goto-char simple-ws-beg))

          (with-silent-modifications
            (define (ladder-step)
              (if (and rung-is-marked
                       (not (bobp))
                       (get-text-property (- (point) 1) 'c-in-sws))
                  (begin
                    ;; "The following search is the main reason that
                    ;; `c-in-sws' and `c-is-sws' aren't combined to one
                    ;; property."
                    (goto-char (c-previous-single-property-change
                                (point) 'c-in-sws #f (point-min)))
                    (unless (get-text-property (point) 'c-is-sws)
                      ;; "If the `c-in-sws' region extended past the first
                      ;; `c-is-sws' char we have to go forward a bit."
                      (goto-char (c-next-single-property-change
                                  (point) 'c-is-sws #f #f)))
                    (c-debug-sws-msg
                     "c-backward-sws cached move ~a <- ~a (min ~a)"
                     (point) rung-pos (point-min))
                    (set! rung-pos (point))
                    (if (and (< (min (c-skip-ws-chars-backward %c-sws-horiz)
                                     (begin (set! simple-ws-beg (point))
                                            (c-skip-ws-chars-backward %c-sws-any)))
                                0)
                             (begin
                               (set! rung-is-marked
                                     (text-property-any (point) rung-pos
                                                        'c-is-sws #t))
                               rung-is-marked))
                        #t
                        (begin (goto-char simple-ws-beg) #f)))
                  #f))

            (define (ladder)
              (when (ladder-step)
                ;; "We'll loop here if there is simple ws before the first
                ;; rung. That means that there's been some change in it
                ;; and it's possible that we've stepped into another
                ;; ladder, so extend the previous one to join with it if
                ;; there is one, and try to use the cache again."
                (c-debug-sws-msg
                 "c-backward-sws extending rung with [~a..~a] (min ~a)"
                 rung-is-marked rung-pos (point-min))
                (unless (get-text-property (- rung-pos 1) 'c-is-sws)
                  ;; "Remove any `c-in-sws' property from the last char of
                  ;; the rung before we mark it with `c-is-sws', so that
                  ;; we won't connect with the remains of a broken
                  ;; "ladder"."
                  (c-remove-in-sws (- rung-pos 1) rung-pos))
                (c-put-is-sws rung-is-marked rung-pos)
                (c-put-in-sws rung-is-marked (- rung-pos 1))
                (set! rung-pos rung-is-marked)
                (set! last-put-in-sws-pos rung-pos)
                (ladder)))

            (define (advance)
              (ladder)
              (c-backward-comments)
              (set! cmt-skip-pos (point))
              (cond
               ((and (%c-langvar 'c-opt-cpp-prefix)
                     (not (= cmt-skip-pos simple-ws-beg))
                     (c-beginning-of-macro))
                ;; "Inside a cpp directive. See if it should be skipped
                ;; over."
                (let ((cpp-beg (point))
                      (pause #f)
                      (pos #f))
                  ;; "Move back over all line continuations and block
                  ;; comments in the region skipped over by
                  ;; `c-backward-comments'. If we go past it then we
                  ;; started inside the cpp directive."
                  (goto-char simple-ws-beg)
                  (beginning-of-line)
                  ;; "Note the similarity of the code here to some in
                  ;; `c-beginning-of-macro'."
                  (set! pause (point))
                  (let loop ()
                    (when (begin
                            (let cont ()
                              (if (and (> (point) cmt-skip-pos)
                                       (begin (backward-char)
                                              (eq? (char-before) #\\)))
                                  (begin (beginning-of-line) (cont))
                                  #f))
                            (set! pos (point))
                            (let ((re (%c-langvar
                                       'c-last-c-comment-end-on-line-re)))
                              (if (and re (re-search-forward re pause #t))
                                  (begin
                                    (goto-char (match-end 1))
                                    (if (c-backward-single-comment)
                                        (begin (beginning-of-line)
                                               (set! pause (point))
                                               #t)
                                        (begin (goto-char pos) #f)))
                                  #f)))
                      (loop)))
                  (if (< (point) cmt-skip-pos)
                      ;; "Don't move past the cpp directive if we began
                      ;; inside it. Note that the position at the end of
                      ;; the last line of the macro is also considered to
                      ;; be within it."
                      (begin (goto-char cmt-skip-pos) #f)
                      ;; "It's worthwhile to spend a little bit of effort
                      ;; on finding the end of the macro, to get a good
                      ;; `simple-ws-beg' position for the cache. Note that
                      ;; `c-backward-comments' could have stepped over some
                      ;; comments before going into the macro, and then
                      ;; `simple-ws-beg' must be kept on the same side of
                      ;; those comments."
                      (begin
                        (goto-char simple-ws-beg)
                        (c-skip-ws-chars-backward %c-sws-any)
                        (if (eq? (char-before) #\\) (forward-char))
                        (forward-line 1)
                        (if (< (point) simple-ws-beg)
                            (set! simple-ws-beg (point)))
                        (goto-char cpp-beg)
                        #t))))

               ((not (= (save-excursion
                          (c-skip-ws-chars-forward %c-sws-any simple-ws-beg)
                          (set! next-rung-pos (point))
                          next-rung-pos)
                        simple-ws-beg))
                ;; "Skipped over comments. Must put point at the end of
                ;; the simple ws at point since we might be after a line
                ;; comment or cpp directive that's been partially narrowed
                ;; out, and we can't risk marking the simple ws at the end
                ;; of it."
                (goto-char next-rung-pos)
                #t)

               ((and (%c-langvar 'c-opt-cpp-prefix)
                     (save-excursion
                       (and (< (skip-syntax-backward "w_") 0)
                            (begin (set! next-rung-pos (point)) #t)
                            (looking-at (c-noise-macro-name-re)))))
                ;; "Skipped over a noise macro"
                (goto-char next-rung-pos)
                #t)

               ((and (c-major-mode-is '(c-mode c++-mode))
                     (eq? (char-before) #\])
                     (eq? (char-before (- (point) 1)) #\])
                     (save-excursion
                       (and (c-go-list-backward)
                            (begin (set! next-rung-pos (point)) #t)
                            (looking-at "\\[\\["))))
                (goto-char next-rung-pos)
                #t)

               ((and (c-doc-line-join-end-ch)
                     (memq (char-before) (c-doc-line-join-end-ch)) ; "For speed."
                     (re-search-backward doc-line-join-here (c-point 'bopl) #t))
                #t)

               ;; See the note on the forward engine's `cond'.
               (else #f)))

            (let outer ()
              (when (advance)
                ;; "We've searched over a piece of non-white syntactic ws.
                ;; See if this can be cached."
                (set! next-rung-pos (point))
                (c-skip-ws-chars-backward %c-sws-back-horiz)

                (if (or
                     ;; "Cache if we started either from a marked rung or
                     ;; from a completely uncached position."
                     rung-is-marked
                     (not (get-text-property (- simple-ws-beg 1) 'c-in-sws))

                     ;; "Cache if there's a marked rung in the encountered
                     ;; simple ws."
                     (save-excursion
                       (c-skip-ws-chars-backward %c-sws-any)
                       (text-property-any (point) (min (+ next-rung-pos 1)
                                                       (point-max))
                                          'c-is-sws #t)))

                    (begin
                      (c-debug-sws-msg
                       "c-backward-sws caching [~a..~a] - [~a..~a] (min ~a)"
                       (point) (+ next-rung-pos 1)
                       simple-ws-beg (min (+ rung-pos 1) (point-max))
                       (point-min))

                      ;; "Remove the properties for any nested ws that
                      ;; might be cached. Only necessary for `c-is-sws'
                      ;; since `c-in-sws' will be set anyway."
                      (c-remove-is-sws (+ next-rung-pos 1) simple-ws-beg)
                      (unless (and rung-is-marked (= simple-ws-beg rung-pos))
                        (let ((rung-end-pos (min (+ rung-pos 1) (point-max))))
                          (unless (get-text-property (- rung-end-pos 1) 'c-is-sws)
                            ;; "Remove any `c-in-sws' property from the
                            ;; last char of the rung before we mark it with
                            ;; `c-is-sws', so that we won't connect with
                            ;; the remains of a broken "ladder"."
                            (c-remove-in-sws (- rung-end-pos 1) rung-end-pos))
                          (c-put-is-sws simple-ws-beg rung-end-pos)
                          (set! rung-is-marked #t)))
                      (c-put-in-sws (begin (set! simple-ws-beg (point))
                                           (set! last-put-in-sws-pos simple-ws-beg)
                                           simple-ws-beg)
                                    rung-pos)
                      (c-put-is-sws (begin (set! rung-pos simple-ws-beg)
                                           rung-pos)
                                    (+ next-rung-pos 1)))

                    (begin
                      (c-debug-sws-msg
                       "c-backward-sws not caching [~a..~a] - [~a..~a] (min ~a)"
                       (point) (+ next-rung-pos 1)
                       simple-ws-beg (min (+ rung-pos 1) (point-max))
                       (point-min))
                      (set! rung-pos next-rung-pos)
                      (set! simple-ws-beg (point))))
                (outer)))

            ;; "Make sure that the newly marked `c-in-sws' region doesn't
            ;; connect to another one before the point (which might occur
            ;; when editing inside a comment or macro)."
            (if (eq? last-put-in-sws-pos (point))
              (begin
              (cond ((< (point-min) last-put-in-sws-pos)
                     (c-debug-sws-msg
                      "c-backward-sws clearing at ~a for cache separation"
                      (- last-put-in-sws-pos 1))
                     (c-remove-in-sws (- last-put-in-sws-pos 1)
                                      last-put-in-sws-pos))
                    ((> (point-min) 1)
                     ;; "If at bob and the buffer is narrowed, we have to
                     ;; clear the character we're standing on instead
                     ;; since there might be a `c-in-sws' before
                     ;; (point-min). In this case it's necessary to clear
                     ;; both properties."
                     (c-debug-sws-msg
                      "c-backward-sws clearing thoroughly at ~a for cache separation"
                      last-put-in-sws-pos)
                     (c-remove-is-and-in-sws last-put-in-sws-pos
                                             (+ last-put-in-sws-pos 1))))
              #f))
            ;; As `c-forward-sws': Emacs's answer is nil on every path.
            #f))
            #f))

    ;;------------------------------------------------------------------
    ;; `c-partial-ws-p' (`cc-engine.el:2678')
    ;;------------------------------------------------------------------
    (define (c-partial-ws-p beg end)
      ;; "Is the region (beg end) WS, and is there WS (or BOB/EOB) next
      ;; to the region? This is a "heuristic" function. .....
      ;;
      ;; The motivation for the second bit is to check whether removing
      ;; this region would coalesce two symbols."
      ;;
      ;; "FIXME!!! This function doesn't check virtual semicolons in any
      ;; way. Be careful about using this function for, e.g. AWK.
      ;; (2007/3/7)"
      (save-excursion
        (let ((end+1 (min (+ end 1) (point-max))))
          (or (begin
                (goto-char (max (point-min) (- beg 1)))
                (c-skip-ws-forward end)
                (= (point) end))
              (begin
                (goto-char beg)
                (c-skip-ws-forward end+1)
                (= (point) end+1))))))

    ;;------------------------------------------------------------------
    ;; `c-forward-syntactic-ws'/`c-backward-syntactic-ws'
    ;; (`cc-defs.el:739', `:762' - a placement departure)
    ;;------------------------------------------------------------------
    ;; Emacs's macros decide at *expansion* time whether the caller
    ;; passed a LIMIT; as procedures the question is asked at run time.
    ;; An explicit nil LIMIT and no argument then take the same branch -
    ;; the limiting one with `(or limit (point-max))' - which is what
    ;; Emacs's expansion of an explicit nil does too.
    (define (c-forward-syntactic-ws . limit-args)
      ;; "Forward skip over syntactic whitespace. ..."
      ;;
      ;; Emacs's macro (`cc-defs.el:739') expands a call with no LIMIT
      ;; to a bare `(c-forward-sws)', and a call with a LIMIT to the
      ;; `when' form - whose value is nil when its test fails, where
      ;; this port answered the unspecified value. That matters where
      ;; the value is a loop condition (`c-forward-primary-expression'
      ;; tests it).
      (let ((limit (if (pair? limit-args) (car limit-args) #f)))
        (if (not (pair? limit-args))
            (c-forward-sws)
            (if (< (point) (or limit (point-max)))
                (save-restriction
                  (narrow-to-region (point-min) (or limit (point-max)))
                  (c-forward-sws))
                #f))))

    (define (c-backward-syntactic-ws . limit-args)
      ;; "Backward skip over syntactic whitespace. ..." (`cc-defs.el:761'
      ;; has the same macro shape as the forward one.)
      (let ((limit (if (pair? limit-args) (car limit-args) #f)))
        (if (not (pair? limit-args))
            (c-backward-sws)
            (if (> (point) (or limit (point-min)))
                (save-restriction
                  (narrow-to-region (or limit (point-min)) (point-max))
                  (c-backward-sws))
                #f))))

    ;;------------------------------------------------------------------
    ;; `c-on-identifier' (`cc-engine.el:4852'-`:4903')
    ;;------------------------------------------------------------------
    (define (c-on-identifier)
      ;; "Return non-nil if the point is on or directly after an
      ;; identifier. Keywords are recognized and not considered
      ;; identifiers. ..."
      ;;
      ;; "FIXME: Shouldn't this function handle "operator" in C++?"
      (save-excursion
        (skip-syntax-backward "w_")
        (or
         ;; "Check for a normal (non-keyword) identifier."
         (and (let ((re (%c-langvar 'c-symbol-start)))
                (and re (looking-at re)))
              (not (let ((re (%c-langvar 'c-keywords-regexp)))
                     (and re (looking-at re))))
              (point))

         (if (c-major-mode-is 'pike-mode)
             ;; "Handle the `<operator> syntax in Pike."
             (let ((pos (point)))
               (skip-chars-backward "-!%&*+/<=>^|~[]()")
               (and (if (< (skip-chars-backward "`") 0)
                        #t
                        (begin (goto-char pos)
                               (eq? (char-after (point)) #\`)))
                    (let ((re (%c-langvar 'c-symbol-key)))
                      (and re (looking-at re)))
                    (>= (match-end 0) pos)
                    (point)))
             #f)

         ;; "Handle the "operator +" syntax in C++."
         (let ((op-re (%c-langvar 'c-overloadable-operators-regexp)))
           (if (and op-re
                    (= (c-backward-token-2
                        0 #f (c-determine-limit 500))
                       0))
               (cond ((and (let ((re (%c-langvar
                                      'c-overloadable-operators-regexp)))
                             (and re (looking-at re)))
                           (or (not (%c-langvar 'c-opt-op-identifier-prefix))
                               (and (= (c-backward-token-2 1) 0)
                                    (let ((re (%c-langvar
                                               'c-opt-op-identifier-prefix)))
                                      (and re (looking-at re))))))
                      (point))

                     ((save-excursion
                        (and (let ((re (%c-langvar
                                        'c-opt-op-identifier-prefix)))
                               (and re (looking-at re)))
                             (= (c-forward-token-2 1) 0)
                             (let ((re (%c-langvar
                                        'c-overloadable-operators-regexp)))
                               (and re (looking-at re)))))
                      (point))
                     ;; Emacs's `cond' is nil when no clause matches;
                     ;; Scheme's is the unspecified value, which is
                     ;; true - and this answer decides `c-on-identifier'.
                     (else #f))
               #f)))))

    ;;------------------------------------------------------------------
    ;; Token movement (`cc-engine.el:4911'-`:5183')
    ;;------------------------------------------------------------------
    ;; `c-simple-skip-symbol-backward' and `c-beginning-of-current-token'
    ;; were ported in an earlier pass and sit above, moved up for
    ;; `c-backward-sws'. `c-jump-syntax-*' are `defconst's whose XEmacs
    ;; arm depends on `gen-string-delim', which this Emacs's
    ;; `c-emacs-features' has.
    (define c-jump-syntax-balanced "\\w\\|\\s_\\|\\s(\\|\\s)\\|\\s\"\\|\\s|")
    (define c-jump-syntax-unbalanced "\\w\\|\\s_\\|\\s\"\\|\\s|")

    (define (c-end-of-token . back-limit-args)
      ;; "Move to the end of the token we're just before or in the middle
      ;; of. BACK-LIMIT may be used to bound the backward search; if
      ;; given it's assumed to be at the boundary between two tokens.
      ;; Return non-nil if the point is moved, nil otherwise."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((back-limit (if (pair? back-limit-args) (car back-limit-args) #f))
            (start (point)))
        (cond ((> (skip-syntax-forward "w_") 0) #t)
              ((< (skip-syntax-backward ".()" back-limit) 0)
               (let loop ()
                 (when (< (point) start)
                   (let ((re (%c-langvar 'c-nonsymbol-token-regexp)))
                     (if (and re (looking-at re))
                         (goto-char (match-end 0))
                         ;; "`c-nonsymbol-token-regexp' should always
                         ;; match since we've skipped backward over
                         ;; punctuation or paren syntax, but move forward
                         ;; in case it doesn't so that we don't leave
                         ;; point earlier than we started with."
                         (forward-char)))
                   (loop))))
              (else
               (let ((re (%c-langvar 'c-nonsymbol-token-regexp)))
                 (when (and re (looking-at re))
                   (goto-char (match-end 0))))))
        (> (point) start)))

    (define (c-end-of-current-token . back-limit-args)
      ;; "Move to the end of the current token. Do not move if not in the
      ;; middle of one. BACK-LIMIT may be used to bound the backward
      ;; search; if given it's assumed to be at the boundary between two
      ;; tokens. Return non-nil if the point is moved, nil otherwise."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((back-limit (if (pair? back-limit-args) (car back-limit-args) #f))
            (start (point)))
        (cond ((< (skip-syntax-backward "w_" (- start 1)) 0)
               (skip-syntax-forward "w_"))
              ((< (skip-syntax-backward ".()" back-limit) 0)
               (let loop ()
                 (when (begin
                         (let ((re (%c-langvar 'c-nonsymbol-token-regexp)))
                           (if (and re (looking-at re))
                               (goto-char (match-end 0))
                               (forward-char)))
                         (< (point) start))
                   (loop)))))
        (> (point) start)))

    (define (c-forward-over-token . args)
      ;; "Move forward over a token. Return t if we moved, nil otherwise
      ;; (i.e. we were at EOB, or a non-token or BALANCED is non-nil and
      ;; we can't move). If we are at syntactic whitespace, move over this
      ;; in place of a token.
      ;;
      ;; If BALANCED is non-nil move over any balanced parens we are at,
      ;; and never move out of an enclosing paren. LIMIT is the limit to
      ;; where we might move to."
      (let* ((balanced (if (pair? args) (car args) #f))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (jump-syntax (if balanced
                              c-jump-syntax-balanced
                              c-jump-syntax-unbalanced))
             (here (point))
             (limit (if limit limit (point-max))))
        (guard (e ((quit-condition? e) (raise e))
                  (else (goto-char here) #f))
          (cond
           ((not (= (point)
                    (begin (c-forward-syntactic-ws limit) (point))))
            ;; "If we're at whitespace, count this as the token."
            #t)
           ((eobp) #f)
           ((looking-at jump-syntax)
            (goto-char (min limit (scan-sexps (point) 1)))
            #t)
           ((let ((re (%c-langvar 'c-nonsymbol-token-regexp)))
              (and re (looking-at re)))
            (goto-char (min (match-end 0) limit))
            #t)
           ((save-restriction
              (widen)
              (let ((re (%c-langvar 'c-nonsymbol-token-regexp)))
                (and re (looking-at re))))
            #f)
           (else (forward-char) #t)))))

    (define (c-forward-over-token-and-ws . args)
      ;; "Move forward over a token and any following whitespace. Return t
      ;; if we moved, nil otherwise ... This function differs from
      ;; `c-forward-token-2' in that it will move forward over the final
      ;; token in a buffer, up to EOB."
      (let ((balanced (if (pair? args) (car args) #f)))
        (let ((r (c-forward-over-token balanced)))
          (c-forward-syntactic-ws)
          r)))

    (define (c-forward-token-2 . args)
      ;; "Move forward by tokens. ... Return the number of tokens left to
      ;; move (positive or negative). ..."
      ;;
      ;; "Note that this function might do hidden buffer changes."
      (let* ((count (if (pair? args) (car args) #f))
             (balanced (if (and (pair? args) (pair? (cdr args)))
                           (cadr args) #f))
             (limit (if (and (pair? args) (pair? (cdr args))
                             (pair? (cddr args)))
                        (caddr args) #f))
             (count (if count count 1)))
        (if (< count 0)
            (- (c-backward-token-2 (- count) balanced limit))

            (let ((here (point))
                  (last (point)))
              (when (= count 0)
                ;; "If count is zero we should jump if in the middle of a
                ;; token."
                (c-end-of-current-token))

              (save-restriction
                (if limit (narrow-to-region (point-min) limit))
                (if (not (= (point)
                            (begin (c-forward-syntactic-ws) (point))))
                    ;; "Skip whitespace. Count this as a move if we did in
                    ;; fact move."
                    (set! count (max (- count 1) 0)))

                (if (eobp)
                    ;; "Moved out of bounds. Make sure the returned count
                    ;; isn't zero."
                    (begin
                      (if (= count 0) (set! count 1))
                      (goto-char here))
                    (begin
                      (let loop ()
                        (when (and (> count 0)
                                   (c-forward-over-token-and-ws balanced)
                                   (not (eobp)))
                          (set! last (point))
                          (set! count (- count 1))
                          (loop)))
                      (if (eobp)
                          (goto-char last)))))
              count))))

    (define (c-backward-token-2 . args)
      ;; "Move backward by tokens. See `c-forward-token-2' for details."
      (let* ((count (if (pair? args) (car args) #f))
             (balanced (if (and (pair? args) (pair? (cdr args)))
                           (cadr args) #f))
             (limit (if (and (pair? args) (pair? (cdr args))
                             (pair? (cddr args)))
                        (caddr args) #f))
             (count (if count count 1)))
        (if (< count 0)
            (- (c-forward-token-2 (- count) balanced limit))

            (begin
              (if (not limit) (set! limit (point-min)))
              (let ((jump-syntax (if balanced
                                     c-jump-syntax-balanced
                                     c-jump-syntax-unbalanced))
                    (last (point)))

                (if (= count 0)
                    ;; "The count is zero so try to skip to the beginning
                    ;; of the current token."
                    (if (> (point)
                           (begin (c-beginning-of-current-token) (point)))
                        (if (< (point) limit)
                            ;; "The limit is inside the same token, so
                            ;; return 1."
                            (set! count 1)
                            #f)
                        ;; "We're not in the middle of a token. If there's
                        ;; whitespace after the point then we must move
                        ;; backward, so set count to 1 in that case."
                        (and (let ((re (%c-langvar 'c-syntactic-ws-start)))
                               (and re (looking-at re)))
                             ;; "If we're looking at a '#' that might
                             ;; start a cpp directive then we have to do a
                             ;; more elaborate check."
                             (or (not (char=? (char-after (point)) #\#))
                                 (not (%c-langvar 'c-opt-cpp-prefix))
                                 (save-excursion
                                   (and (= (point)
                                           (begin
                                             (beginning-of-line)
                                             (looking-at "[ \t]*")
                                             (match-end 0)))
                                        (or (bobp)
                                            (begin
                                              (backward-char)
                                              (not (eq? (char-before) #\\)))))))
                             (begin (set! count 1) count))))

                ;; "Use `condition-case' to avoid having to check for
                ;; buffer limits in `backward-char', `scan-sexps' and
                ;; `goto-char' below."
                (guard (e ((quit-condition? e) (raise e))
                          (else (goto-char last)))
                  (let loop ()
                    (when (and (> count 0)
                               (begin
                                 (c-backward-syntactic-ws limit)
                                 (backward-char)
                                 (if (looking-at jump-syntax)
                                     (goto-char (scan-sexps (+ (point) 1) -1))
                                     ;; "This can be very inefficient if
                                     ;; there's a long sequence of operator
                                     ;; tokens without any separation. That
                                     ;; doesn't happen in practice, anyway."
                                     (c-beginning-of-current-token))
                                 (>= (point) limit)))
                      (set! last (point))
                      (set! count (- count 1))
                      (loop))))

                (if (< (point) limit)
                    (goto-char last))

                count)))))

    (define (c-forward-token-1 . args)
      ;; "Like `c-forward-token-2' but doesn't treat multicharacter
      ;; operator tokens like \"==\" as single tokens, i.e. all sequences
      ;; of symbol characters are jumped over character by character.
      ;; This function is for compatibility only; it's only a wrapper
      ;; over `c-forward-token-2'."
      (parameterize ((*c-lang-var-overrides*
                      (cons (cons 'c-nonsymbol-token-regexp "\\s.")
                            (*c-lang-var-overrides*))))
        (apply c-forward-token-2 args)))

    (define (c-backward-token-1 . args)
      ;; "Like `c-backward-token-2' but doesn't treat multicharacter
      ;; operator tokens like \"==\" as single tokens, i.e. all sequences
      ;; of symbol characters are jumped over character by character.
      ;; This function is for compatibility only; it's only a wrapper
      ;; over `c-backward-token-2'."
      (parameterize ((*c-lang-var-overrides*
                      (cons (cons 'c-nonsymbol-token-regexp "\\s.")
                            (*c-lang-var-overrides*))))
        (apply c-backward-token-2 args)))

    ;;------------------------------------------------------------------
    ;; `c-syntactic-re-search-forward' (`cc-engine.el:5196'-`:5450')
    ;;------------------------------------------------------------------
    ;; The token and barrier code above and everything below reads it.
    (define (c-syntactic-re-search-forward regexp . args)
      ;; "Like `re-search-forward', but only report matches that are found
      ;; in syntactically significant text. ..."
      (let ((bound (if (pair? args) (car args) #f))
            (noerror (if (and (pair? args) (pair? (cdr args)))
                         (cadr args) #f))
            (paren-level (if (and (pair? args) (pair? (cdr args))
                                  (pair? (cddr args)))
                             (caddr args) #f))
            (not-inside-token (if (and (pair? args) (pair? (cdr args))
                                       (pair? (cddr args))
                                       (pair? (cdddr args)))
                                  (cadddr args) #f))
            (lookbehind-submatch (if (and (pair? args) (pair? (cdr args))
                                          (pair? (cddr args))
                                          (pair? (cdddr args))
                                          (pair? (cddddr args)))
                                     (car (cddddr args)) #f)))
        (set! bound (or bound (point-max)))
        (if paren-level (set! paren-level -1))

        (let ((start (point))
              (tmp #f)
              ;; "Start position for the last search."
              (search-pos #f)
              ;; "The `parse-partial-sexp' state between the start
              ;; position and the point."
              (state #f)
              ;; "The current position after the last state update. ..."
              (state-pos (point))
              ;; "The position at which to check the state and the state
              ;; there. ..."
              (check-pos #f)
              (check-state #f)
              ;; "Last position known to end a token."
              (last-token-end-pos (point-min))
              ;; "Set when a valid match is found."
              (found #f))

          (guard (e ((quit-condition? e) (raise e))
                    (else (goto-char start) (raise e)))
            (let loop ()
              (when (and
                     (begin
                       (set! search-pos (point))
                       (if (re-search-forward regexp bound noerror)
                           #t
                           ;; "Without the following, when PAREN-LEVEL is
                           ;; non-nil, and NOERROR is not nil or t, and
                           ;; the very first search above has just
                           ;; failed, point would end up at BOUND rather
                           ;; than just before the next close paren."
                           (begin
                             (when (and (eq? search-pos start)
                                        paren-level
                                        (not (or (not noerror)
                                                 (eq? noerror #t))))
                               (set! state (parse-partial-sexp start bound -1))
                               (if (eq? (car state) -1)
                                   (set! bound (- (point) 1))))
                             #f)))

                     (begin
                       (set! state (parse-partial-sexp
                                    state-pos (match-beginning 0)
                                    paren-level #f state))
                       (set! state-pos (point))
                       (let ((cp (and lookbehind-submatch
                                      (or (not paren-level)
                                          (>= (car state) 0))
                                      (match-end lookbehind-submatch))))
                         (set! check-pos cp)
                         (if cp
                             (set! check-state (parse-partial-sexp
                                                state-pos check-pos
                                                paren-level #f state))
                             (begin
                               (set! check-pos state-pos)
                               (set! check-state state))))

                       (cond
                        ;; "Match inside a line comment. Skip to eol.
                        ;; Use `re-search-forward' instead of
                        ;; `skip-chars-forward' to get the right bound
                        ;; behavior."
                        ((nth 7 check-state)
                         (re-search-forward "[\n\r]" bound noerror))

                        ;; "Match inside a block comment. Skip to the
                        ;; '*/'."
                        ((nth 4 check-state)
                         (search-forward "*/" bound noerror))

                        ;; "Match in the middle of the opener of a block
                        ;; or line comment."
                        ((and (not (nth 5 check-state))
                              (eq? (char-before check-pos) #\/)
                              (not (c-get-char-property (1- check-pos)
                                                        'syntax-table))
                              (memv (char-after check-pos) (list #\/ #\*)))
                         (if (eq? (char-after check-pos) #\/)
                             (re-search-forward "[\n\r]" bound noerror)
                             (search-forward "*/" bound noerror)))

                        ;; "The last `parse-partial-sexp' above might have
                        ;; stopped short of the real check position if the
                        ;; end of the current sexp was encountered in
                        ;; paren-level mode. ..."
                        ((begin (set! tmp (car check-state))
                                (and paren-level (not (zero? tmp))))
                         (if (> tmp 0)
                             ;; "Inside a nested paren sexp."
                             (if lookbehind-submatch
                                 ;; "See the NOTE above."
                                 (begin (goto-char state-pos) #t)
                                 ;; "Skip out of the paren quickly."
                                 (begin
                                   (set! state (parse-partial-sexp
                                                state-pos bound 0 #f state))
                                   (set! state-pos (point))
                                   #t))
                             ;; "Have exited the current paren sexp."
                             (if noerror
                                 (begin
                                   ;; "The last `parse-partial-sexp' call
                                   ;; above has left us just after the
                                   ;; closing paren in this case, so we
                                   ;; can modify the bound to leave the
                                   ;; point at the right position upon
                                   ;; return."
                                   (set! bound (- (point) 1))
                                   #f)
                                 (error "Search failed" regexp))))

                        ;; "Match inside a string."
                        ((begin (set! tmp (nth 3 check-state)) tmp)
                         (if (or lookbehind-submatch
                                 (not (integer? tmp)))
                             ;; "See the NOTE above."
                             (begin (goto-char state-pos) #t)
                             ;; "Skip to the end of the string before
                             ;; continuing."
                             (let ((ender (string (integer->char tmp)))
                                   (continue #t))
                               (let skiploop ()
                                 (when continue
                                   (if (search-forward ender bound noerror)
                                       (begin
                                         (set! state (parse-partial-sexp
                                                      state-pos (point)
                                                      #f #f state))
                                         (set! state-pos (point))
                                         (set! continue (nth 3 state)))
                                       (set! continue #f))))
                               continue)))

                        ;; "Match inside a macro. Skip to the end of it."
                        ((save-excursion
                           (save-match-data
                             (c-beginning-of-macro start)))
                         (c-end-of-macro)
                         (cond ((<= (point) bound) #t)
                               (noerror #f)
                               (else (error "Search failed" regexp))))

                        ;; "Inside a token."
                        ((and not-inside-token
                              (or (< check-pos last-token-end-pos)
                                  (< check-pos
                                     (save-excursion
                                       (goto-char check-pos)
                                       (save-match-data
                                         (c-end-of-current-token
                                          last-token-end-pos))
                                       (set! last-token-end-pos (point))
                                       last-token-end-pos))))
                         (if lookbehind-submatch
                             ;; "See the NOTE above."
                             (goto-char state-pos)
                             (goto-char (min last-token-end-pos bound)))
                         #t)

                        ;; "A real match."
                        (else
                         (set! found #t)
                         #f)))

                     ;; "Should loop to search again, but take care to
                     ;; avoid looping on the same spot."
                     (or (not (= search-pos (point)))
                         (if (= (point) bound)
                             (if noerror
                                 #f
                                 (error "Search failed" regexp))
                             (begin (forward-char) #t))))
                (loop)))

            (if found
                (begin
                  (goto-char (match-end 0))
                  (match-end 0))

                ;; "Search failed. Set point as appropriate."
                (begin
                  (cond
                   ((eq? noerror #t)
                    (goto-char start))
                   ((not (memq noerror '(before-literal after-literal)))
                    (goto-char bound))
                   (else
                    (set! state (parse-partial-sexp state-pos bound #f #f state))
                    (if (or (nth 3 state) (nth 4 state))
                        (if (eq? noerror 'before-literal)
                            (goto-char (nth 8 state))
                            (parse-partial-sexp bound (point-max) #f #f
                                                state 'syntax-table))
                        (goto-char bound))))
                  #f))))))

    ;;------------------------------------------------------------------
    ;; `c-syntactic-skip-backward' (`cc-engine.el:5454'-`:5581')
    ;;------------------------------------------------------------------
    (define (c-syntactic-skip-backward skip-chars . args)
      ;; "Like `skip-chars-backward' but only look at syntactically
      ;; relevant chars. ..."
      (let* ((limit (if (pair? args) (car args) #f))
             (paren-level (if (and (pair? args) (pair? (cdr args)))
                              (cadr args) #f))
             (start (point))
             ;; "The result from `c-beginning-of-macro' at the start
             ;; position or the start position itself if it isn't within
             ;; a macro."
             (start-macro-beg
              (save-excursion
                (goto-char start)
                (c-beginning-of-macro limit)
                (point)))
             (lit-beg #f)
             ;; "The earliest position after the current one with the same
             ;; paren level. Used only when `paren-level' is set."
             (paren-level-pos (point))
             ;; "Whether we can optimize with an early
             ;; `c-backward-syntactic-ws'."
             (opt-ws (string-match "^\\^[^ \t\n\r]+$" skip-chars)))

        ;; "In the next while form, we only loop when `skip-chars' is
        ;; something like "^/" and we've stopped at the end of a block
        ;; comment."
        (let outer ()
          (when (begin
                  ;; "The next loop "tries" to find the end point each
                  ;; time round, loops when it's ended up at the wrong
                  ;; level of nesting."
                  (let inner ()
                    (when (and
                           ;; "Optimize for, in particular, large blocks of
                           ;; comments from `comment-region'."
                           (begin
                             (when opt-ws
                               (let ((opt-pos (point)))
                                 (c-backward-syntactic-ws limit)
                                 (if (or (not limit)
                                         (> (point) limit))
                                     (set! paren-level-pos (point))
                                     (goto-char opt-pos))))
                             #t)
                           ;; "Move back to a candidate end point which
                           ;; isn't in a literal or in a macro we didn't
                           ;; start in."
                           (let ((pos (point))
                                 (macro-start #f))
                             (let mover ()
                               (when (and (< (skip-chars-backward
                                              skip-chars limit)
                                             0)
                                          (or
                                           (begin
                                             (set! lit-beg (c-literal-start))
                                             (if lit-beg
                                                 (begin (goto-char lit-beg)
                                                        #t)
                                                 #f))
                                           ;; "Don't stop inside a macro we
                                           ;; didn't start in."
                                           (if (save-excursion
                                                 (and (c-beginning-of-macro
                                                       limit)
                                                      (< (point)
                                                         start-macro-beg)
                                                      (begin
                                                        (set! macro-start
                                                              (point))
                                                        (point))))
                                               (goto-char macro-start)
                                               #f)))
                                 (when opt-ws
                                   (let ((opt-pos (point)))
                                     (c-backward-syntactic-ws limit)
                                     (if (and limit (<= (point) limit))
                                         (goto-char opt-pos))))
                                 (mover)))
                             (< (point) pos))
                           ;; "Check whether we're at the wrong level of
                           ;; nesting (when `paren-level' is non-nil)."
                           (let ((pos (point))
                                 (state-2 #f)
                                 (pps-end-pos #f))
                             (if (and paren-level
                                      (save-excursion
                                        (set! state-2
                                              (parse-partial-sexp
                                               pos paren-level-pos -1))
                                        (set! pps-end-pos (point))
                                        (not (= (car state-2) 0))))
                                 ;; "Not at the right level."
                                 (if (and (< (car state-2) 0)
                                          ;; "We stop above if we go out of
                                          ;; a paren. Now check whether it
                                          ;; precedes or is nested in the
                                          ;; starting sexp."
                                          (save-excursion
                                            (set! state-2
                                                  (parse-partial-sexp
                                                   pps-end-pos
                                                   paren-level-pos
                                                   #f #f state-2))
                                            (< (car state-2) 0)))
                                     ;; "We've stopped short of the starting
                                     ;; position so the hit was inside a
                                     ;; nested list. Go up until we are at
                                     ;; the right level."
                                     (guard (e ((quit-condition? e)
                                                (raise e))
                                               (else
                                                (goto-char (or limit
                                                               (point-min)))
                                                #f))
                                       (goto-char (scan-lists
                                                   pos -1 (- (car state-2))))
                                       (set! paren-level-pos (point))
                                       (if (and limit
                                                (>= limit paren-level-pos))
                                           (begin (goto-char limit) #f)
                                           #t))
                                     ;; "The hit was outside the list at
                                     ;; the start position. Go to the start
                                     ;; of the list and exit."
                                     (begin
                                       (goto-char (+ 1 (nth 1 state-2)))
                                       #f))
                                 #f)))
                      (inner)))

                  ;; "Skip syntactic ws afterwards so that we don't stop
                  ;; at the end of a comment if `skip-chars' is something
                  ;; like "^/"."
                  ;; "Skip syntactic ws afterwards..." The C reads
                  ;; POINT before the skip; Scheme argument order is
                  ;; unspecified (Guile's compiler took the second one
                  ;; first here), so the read is sequenced explicitly.
                  (let ((before (point)))
                    (c-backward-syntactic-ws limit)
                    (> before (point))))
            (outer)))

        ;; "We might want to extend this with more useful return values in
        ;; the future."
        (not (= (point) start))))

    ;;------------------------------------------------------------------
    ;; `c-determine-limit' (`cc-engine.el:5864'-`:6012')
    ;;------------------------------------------------------------------
    ;; Moved up from its file position: `c-on-identifier' reads it, and
    ;; so does much of the declaration machinery to come.
    (define (c-determine-limit-no-macro here org-start)
      ;; "If HERE is inside a macro, and ORG-START is not also in the same
      ;; macro, return the beginning of the macro. Otherwise return HERE.
      ;; Point is not preserved by this function."
      (goto-char here)
      (let ((here-BOM (and (c-beginning-of-macro) (point))))
        (if (and here-BOM
                 (not (eq? (begin (goto-char org-start)
                                  (and (c-beginning-of-macro) (point)))
                           here-BOM)))
            here-BOM
            here)))

    (define (c-determine-limit-get-base start try-size)
      ;; "Get a "safe place" approximately TRY-SIZE characters before
      ;; START. This defsubst doesn't preserve point."
      (goto-char start)
      (let* ((pos (max (- start try-size) (point-min)))
             (s (c-semi-pp-to-literal pos))
             (cand (or (%c-caddr s) pos)))
        (if (>= cand (point-min))
            cand
            (begin
              (parse-partial-sexp pos start #f #f (car s) 'syntax-table)
              (point)))))

    (define (c-determine-limit how-far-back . args)
      ;; "Return a buffer position approximately HOW-FAR-BACK non-literal
      ;; characters from START (default point). ..."
      (let ((start (if (pair? args) (car args) #f))
            (try-size (if (and (pair? args) (pair? (cdr args)))
                          (cadr args) #f))
            (org-start (if (and (pair? args) (pair? (cdr args))
                                (pair? (cddr args)))
                           (caddr args) #f)))
        (save-excursion
          (let* ((start (or start (point)))
                 (org-start (or org-start start))
                 (try-size (or try-size (* 2 how-far-back)))
                 (base (c-determine-limit-get-base start try-size))
                 (pos base)
                 (s (parse-partial-sexp pos pos)) ; "null state."
                 (stack '())
                 (elt #f)
                 (count 0))
            ;; "Optimization for large blocks of comments, particularly
            ;; those being created by `comment-region'."
            (goto-char pos)
            (forward-comment try-size)
            (set! pos (point))

            (let loop ()
              (when (< pos start)
                ;; "Move forward one literal each time round this loop.
                ;; Move forward to the start of a comment or string."
                (set! s (parse-partial-sexp pos start #f #f s 'syntax-table))

                ;; "Gather details of the non-literal-bit - starting pos
                ;; and size."
                (let ((size (- (if (or (and (nth 4 s)
                                            (not (eq? (nth 7 s) 'syntax-table)))
                                       (nth 3 s))
                                   (nth 8 s)
                                   (point))
                               pos)))
                  (if (> size 0)
                      (set! stack (cons (cons pos size) stack))))

                ;; "Move forward to the end of the comment/string."
                (if (or (and (nth 4 s) (not (eq? (nth 7 s) 'syntax-table)))
                        (nth 3 s))
                    (set! s (parse-partial-sexp (point) start #f #f s 'syntax-table)))
                (set! pos (point))
                (loop)))

            ;; "Now try and find enough non-literal characters recorded on
            ;; the stack. Go back one recorded literal each time round this
            ;; loop."
            (let loop ()
              (when (and (< count how-far-back) (pair? stack))
                (set! elt (car stack))
                (set! stack (cdr stack))
                (set! count (+ count (cdr elt)))
                (loop)))
            (cond
             ((not elt)                 ; "No non-literal characters found."
              (cond
               ((> pos start)           ; "Nothing but literals"
                base)
               ((and (> base (point-min))
                     (> (- base try-size) (point-min))) ; "prevent infinite recursion."
                (c-determine-limit how-far-back base (* 2 try-size) org-start))
               (else base)))
             ((>= count how-far-back)
              (c-determine-limit-no-macro
               (+ (car elt) (- count how-far-back))
               org-start))
             ((= base (point-min))
              (point-min))
             ((> base (- start try-size)) ; "Can only happen if we hit point-min."
              (c-determine-limit-no-macro (car elt) org-start))
             (else
              (c-determine-limit (- how-far-back count) base (* 2 try-size)
                                 org-start)))))))

    (define (c-determine-+ve-limit how-far . args)
      ;; "Return a buffer position about HOW-FAR non-literal characters
      ;; forward from START-POS (default point), which must not be inside
      ;; a literal."
      (let ((start-pos (if (pair? args) (car args) #f)))
        (save-excursion
          (let ((pos (or start-pos (point)))
                (count how-far)
                (s (parse-partial-sexp (point) (point)))) ; "null state"
            (goto-char pos)
            (let loop ()
              (when (and (not (eobp)) (> count 0))
                ;; "Scan over counted characters."
                (set! s (parse-partial-sexp
                         pos (min (+ pos count) (point-max))
                         #f #f s 'syntax-table))
                (set! count (- count (- (point) pos) 1))
                (set! pos (point))
                ;; "Scan over literal characters."
                (when (nth 8 s)
                  (set! s (parse-partial-sexp
                           pos (point-max) #f #f s 'syntax-table))
                  (set! pos (point)))
                (loop)))
            (point)))))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:8567'-`:8644': the helpers the keyword clauses (and
    ;; the declaration engine) stand on. `c-forward-noise-clause',
    ;; `c-forward-noise-clause-not-macro-decl' and
    ;; `c-forward-over-colon-type-list' need nothing unported.
    ;;
    ;; Between this region and `c-forward-keyword-clause' (`:8667')
    ;; Emacs has `c-neutralize-*', `c-depropertize-ml-string' and
    ;; `c-before-after-change-check-c++-modules', which are not ported
    ;; (they need cc-mode's `syntax-table' property machinery);
    ;; `c-forward-keyword-clause' and its two macros need
    ;; `c-forward-type' and `c-forward-name', the declaration engine.
    ;;------------------------------------------------------------------
    (define (c-forward-noise-clause . args)
      ;; "Point is at a `c-noise-macro-with-parens-names' macro
      ;; identifier. Go forward over this name, any parenthesis
      ;; expression which follows it, and any syntactic WS, ending up
      ;; either at the next token or EOB or (when STOP-AT-END is
      ;; non-nil) directly after the clause. If there is an unbalanced
      ;; paren expression, leave point at it. Always Return t."
      (let ((stop-at-end (if (pair? args) (car args) #f))
            (pos #f))
        (or (c-forward-over-token)
            (goto-char (point-max)))
        (set! pos (point))
        (c-forward-syntactic-ws)
        (when (and (eq? (char-after (point)) #\()
                   (c-go-list-forward))
          (set! pos (point)))
        (goto-char pos)
        (unless stop-at-end
          (c-forward-syntactic-ws))
        #t))

    (define (c-forward-noise-clause-not-macro-decl maybe-parens)
      ;; "Point is at a noise macro identifier, which, when MAYBE-PARENS
      ;; is non-nil, optionally takes paren arguments. Go forward over
      ;; this name, and when there may be optional parens, any
      ;; parenthesis expression which follows it, but DO NOT go over any
      ;; macro declaration which may come between them. Always return
      ;; t."
      (c-end-of-token)
      (when maybe-parens
        (let ((here (point)))
          (c-forward-comments)
          (if (not (and (eq? (char-after (point)) #\()
                        (c-go-list-forward)))
              (goto-char here))))
      #t)

    (define (c-forward-over-colon-type-list)
      ;; "If we're at a sequence of characters which can extend from,
      ;; e.g., a class name up to a colon introducing an inheritance
      ;; list, move forward over them, including the colon, and return
      ;; non-nil. Otherwise return nil, leaving point unmoved."
      (let ((here (point)) (pos #f))
        (let loop ()
          (when (and (let ((re (%c-langvar 'c-sub-colon-type-list-re)))
                       (and re (re-search-forward re #f #t)))
                     (not (eq? (char-after (point)) #\:))
                     (c-major-mode-is 'c++-mode)
                     (begin (set! pos (c-looking-at-c++-attribute)) pos))
            (goto-char pos)
            (loop)))
        (if (eq? (char-after (point)) #\:)
            (begin (forward-char) #t)
            (begin (goto-char here) #f))))

    ;;------------------------------------------------------------------
    ;; `c-in-method-def-p' (`cc-engine.el:12171')
    ;;------------------------------------------------------------------
    (define (c-in-method-def-p)
      ;; "Return nil if we aren't in a method definition, otherwise the
      ;; position of the initial [+-]."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (beginning-of-line)
        (let ((re (%c-langvar 'c-opt-method-key)))
          (and re (looking-at re) (point)))))

    ;;------------------------------------------------------------------
    ;; `c-looking-at-special-brace-list' (`cc-engine.el:13584'-`:13645')
    ;;------------------------------------------------------------------
    ;; Moved up from its file position: `c-at-statement-start-p' reads it.
    (define (c-looking-at-special-brace-list)
      ;; "If we're looking at the start of a pike-style list, i.e., `({
      ;; })', `([ ])', `(< >)', etc., a cons of a cons of its starting and
      ;; ending positions and its entry in `c-special-brace-lists' is
      ;; returned, nil otherwise. ..."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((sbl (%c-langvar 'c-special-brace-lists)))
        (if sbl
            (guard (e ((quit-condition? e) (raise e))
                      (else #f))
              (save-excursion
                (let ((beg (point))
                      (inner-beg #f)
                      (end #f)
                      (type #f))
                  (c-forward-syntactic-ws)
                  (if (eq? (char-after (point)) #\()
                      (begin
                        (forward-char 1)
                        (c-forward-syntactic-ws)
                        (set! inner-beg (point))
                        (set! type (assq (char-after (point)) sbl)))
                      (if (begin (set! type (assq (char-after (point)) sbl)) type)
                          (begin
                            (set! inner-beg (point))
                            (c-backward-syntactic-ws)
                            (forward-char -1)
                            (set! beg (if (eq? (char-after (point)) #\()
                                          (point)
                                          #f)))))
                  (if (and beg type)
                      (if (and (c-safe
                                (goto-char beg)
                                (c-forward-sexp 1)
                                (set! end (point))
                                (eq? (char-before) #\)))
                               (c-safe
                                (goto-char inner-beg)
                                (if (looking-at "\\s(")
                                    ;; "Check balancing of the inner paren
                                    ;; below."
                                    (begin (c-forward-sexp 1) #t)
                                    ;; "If the inner char isn't a paren
                                    ;; then we can't check balancing, so
                                    ;; just check the char before the outer
                                    ;; closing paren."
                                    (begin
                                      (goto-char end)
                                      (backward-char)
                                      (c-backward-syntactic-ws)
                                      (char=? (char-before) (cdr type))))))
                          (if (or (not (eq? (char-syntax (char-before)) #\)))
                                  (= (begin (c-forward-syntactic-ws) (point))
                                     (- end 1)))
                              (cons (cons beg end) type))
                          (cons (list beg) type))
                      #f))))
            #f)))

    ;;------------------------------------------------------------------
    ;; `c-looking-at-inexpr-block' (`cc-engine.el:13917')
    ;;------------------------------------------------------------------
    (define (c-looking-at-inexpr-block lim containing-sexp . args)
      ;; "Return non-nil if we're looking at the beginning of a block
      ;; inside an expression. The value returned is actually a cons of
      ;; either 'inlambda, 'inexpr-statement or 'inexpr-class and the
      ;; position of the beginning of the construct. ..."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((check-at-end (if (pair? args) (car args) #f)))
        (save-excursion
          (let ((res 'maybe)
                (passed-bracket-pairs 0)
                (bracket-pos #f)
                (passed-paren #f)
                (haskell-op-pos #f)
                (closest-lim (or containing-sexp lim (point-min)))
                ;; "Look at the character after point only as a last
                ;; resort when we can't disambiguate."
                (block-follows (and (eq? (char-after (point)) #\{)
                                    (point))))

            ;; "Search for a C++11 "->" which suggests a lambda
            ;; declaration."
            (set! haskell-op-pos
                  (if (c-major-mode-is 'c++-mode)
                      (save-excursion
                        (let search ()
                          (when (begin
                                  (c-syntactic-skip-backward "^;=,}>" closest-lim #t)
                                  (and (eq? (char-before) #\>)
                                       (c-backward-token-2)
                                       (not (let ((re (%c-langvar 'c-haskell-op-re)))
                                              (and re (looking-at re))))))
                            (search)))
                        (let ((re (%c-langvar 'c-haskell-op-re)))
                          (and re (looking-at re) (point))))
                      #f))
            (when haskell-op-pos
              (goto-char haskell-op-pos))

            (let loop ()
              (when (and (eq? res 'maybe)
                         (begin (c-backward-syntactic-ws lim)
                                (> (point) closest-lim))
                         (not (bobp))
                         (begin (backward-char)
                                (looking-at "[]).]\\|\\w\\|\\s_"))
                         (c-safe (forward-char)
                                 (goto-char (scan-sexps (point) -1))))
                (set! res
                      (if (let ((re (%c-langvar 'c-keywords-regexp)))
                            (and re (looking-at re)))
                          (let ((kw-sym (c-keyword-sym (match-string 1))))
                            (cond
                             ((and block-follows
                                   (c-keyword-member kw-sym 'c-inexpr-class-kwds))
                              (and (not (eq? passed-paren #\[))
                                   (or (not (let ((re (%c-langvar 'c-class-key)))
                                              (and re (looking-at re))))
                                       ;; "If the class definition is at
                                       ;; the start of a statement, we
                                       ;; don't consider it an
                                       ;; in-expression class."
                                       (let ((prev (point)))
                                         (let back ()
                                           (when (and (= (c-backward-token-2
                                                          1 #f closest-lim)
                                                         0)
                                                      (eq? (char-syntax
                                                            (char-after (point)))
                                                           #\w))
                                             (set! prev (point))
                                             (back)))
                                         (goto-char prev)
                                         (not (c-at-statement-start-p)))
                                       ;; "Also, in Pike we treat it as an
                                       ;; in-expression class if it's used
                                       ;; in an object clone expression."
                                       (save-excursion
                                         (and check-at-end
                                              (c-major-mode-is 'pike-mode)
                                              (begin
                                                (goto-char block-follows)
                                                (= (c-forward-token-2 1 #t) 0))
                                              (eq? (char-after (point)) #\()))))
                                   (cons 'inexpr-class (point)))
                             ((c-keyword-member kw-sym 'c-paren-any-kwds) ; "e.g. C++11 "throw" or "noexcept""
                              (set! passed-paren #f)
                              (set! passed-bracket-pairs 0)
                              (set! bracket-pos #f)
                              'maybe)
                             ((c-keyword-member kw-sym 'c-inexpr-block-kwds)
                              (if (not passed-paren)
                                  (cons 'inexpr-statement (point))
                                  #f))
                             ((c-keyword-member kw-sym 'c-lambda-kwds)
                              (if (or (not passed-paren)
                                      (eq? passed-paren #\())
                                  (cons 'inlambda (point))
                                  #f))
                             ((c-keyword-member kw-sym 'c-block-stmt-kwds)
                              #f)
                             (else 'maybe)))
                          (if (looking-at "\\s(")
                              (if passed-paren
                                  (cond
                                   ((and (eq? passed-paren #\[)
                                         (eq? (char-after (point)) #\[)
                                         (not (eq? (char-after (+ 1 (point))) #\[))) ; "C++ attribute."
                                    ;; "Accept several square bracket sexps
                                    ;; for Java array initializations."
                                    (set! passed-bracket-pairs
                                          (+ passed-bracket-pairs 1))
                                    'maybe)
                                   ((and (eq? passed-paren #\()
                                         (eq? (char-after (point)) #\[)
                                         (not (eq? (char-after (+ 1 (point))) #\[))
                                         (= passed-bracket-pairs 0))
                                    ;; "C++11 lambda function declaration"
                                    (set! passed-bracket-pairs 1)
                                    (set! bracket-pos (point))
                                    'maybe)
                                   (else #f))
                                  (begin
                                    (when (not (looking-at "\\[\\["))
                                      (set! passed-paren (char-after (point)))
                                      (when (eq? passed-paren #\[)
                                        (set! passed-bracket-pairs 1)
                                        (set! bracket-pos (point))))
                                    'maybe))
                              'maybe)))
                (loop)))

            (if (eq? res 'maybe)
                (cond
                 ((and (c-major-mode-is 'c++-mode)
                       block-follows
                       (= passed-bracket-pairs 1)
                       (save-excursion
                         (goto-char bracket-pos)
                         (or (<= (point) (or lim (point-min)))
                             (begin
                               (c-backward-token-2 1 #f lim)
                               (and
                                (not (and (c-on-identifier)
                                          (let ((re (%c-langvar 'c-symbol-char-key)))
                                            (and re (looking-at re)))))
                                (not (let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                                       (and re (looking-at re)))))))))
                  (cons 'inlambda bracket-pos))
                 ((and (%c-langvar 'c-recognize-paren-inexpr-blocks)
                       block-follows
                       containing-sexp
                       (eq? (char-after containing-sexp) #\())
                  (goto-char containing-sexp)
                  (if (or (save-excursion
                            (c-backward-syntactic-ws lim)
                            (let skip ()
                              (when (and (eq? (char-before) #\>)
                                         (c-get-char-property (- (point) 1)
                                                              'syntax-table)
                                         (c-go-list-backward #f lim))
                                (c-backward-syntactic-ws lim)
                                (skip)))
                            (and (> (point) (or lim (point-min)))
                                 (c-on-identifier)))
                          (and (%c-langvar 'c-special-brace-lists)
                               (c-looking-at-special-brace-list))
                          ;; The third arm of the C's `or' is
                          ;;   (and c-has-compound-literals
                          ;;        (save-excursion
                          ;;          (goto-char block-follows)
                          ;;          (not (c-looking-at-statement-block))))
                          ;; `c-looking-at-statement-block' is not
                          ;; ported (it needs the C++ declaration
                          ;; engine); an explicit error, and no ported
                          ;; caller reaches it - `c-beginning-of-
                          ;; statement-1' passes a nil CONTAINING-SEXP.
                          (and (%c-langvar 'c-has-compound-literals)
                               (error "c-looking-at-inexpr-block: the compound-literal branch waits on `c-looking-at-statement-block', which is not ported")))
                      #f
                      (cons 'inexpr-statement (point))))
                 (else #f))
                res)))))

    ;;------------------------------------------------------------------
    ;; `c-looking-at-c++-lambda-capture-list' (`cc-engine.el:14101')
    ;;------------------------------------------------------------------
    ;; `c-looking-at-c++-lambda-expression' (`:14113') and
    ;; `c-backward-over-lambda-expression' (`:14171') are not ported yet:
    ;; they need `c-forward-<>-arglist', `c-forward-keyword-clause' and
    ;; `c-forward-type' - the C++ declaration engine.
    (define (c-looking-at-c++-lambda-capture-list)
      ;; "Return non-nil if we're at the opening \"[\" of the capture
      ;; list of a C++ lambda function, nil otherwise."
      (and (eq? (char-after (point)) #\[)
           (not (eq? (char-before) #\[))
           (not (eq? (char-after (+ 1 (point))) #\[))
           (save-excursion
             (or (= (c-backward-token-2 1) 1)
                 (let ((re (%c-langvar 'c-pre-lambda-tokens-re)))
                   (and re (looking-at re)))))
           (not (c-in-literal))))

    ;;------------------------------------------------------------------
    ;; Virtual semicolons (`cc-engine.el:14184'-`:14243')
    ;;------------------------------------------------------------------
    ;; `c-at-vsemi-p' and `c-vsemi-status-unknown-p' are `cc-defs.el'
    ;; macros that `funcall' a language variable. A language constant
    ;; here holds the *symbol* (the data was generated from Emacs), and
    ;; there is no function obarray, so the symbol is resolved through a
    ;; registry filled as each function is defined - the tree's stand-in.
    ;; A name whose function is not ported (awk's two) answers #f where
    ;; Emacs would signal a void function; awk has no mode here.
    (define %c-lang-functions (make-hash-table))

    (define (c-register-lang-function! sym proc)
      ;; Emacs resolves a language's `c-at-vsemi-p-fn' through the
      ;; obarray; this is the same fact, kept by hand.
      (hash-set! %c-lang-functions sym proc))

    (define (%c-lang-function sym)
      (hash-ref %c-lang-functions sym #f))

    (define (c-at-vsemi-p . pos-args)
      ;; "Is there a virtual semicolon (not a real one or a }) at POS
      ;; (defaults to point)? Always returns nil for languages which don't
      ;; have Virtual semicolons."
      ;;
      ;; "This macro might do hidden buffer changes."
      (let* ((fn-sym (%c-langvar 'c-at-vsemi-p-fn))
             (fn (and fn-sym (%c-lang-function fn-sym))))
        (if fn
            (if (pair? pos-args) (fn (car pos-args)) (fn))
            #f)))

    (define (c-vsemi-status-unknown-p)
      ;; "Return NIL only if it can be guaranteed that an immediate
      ;; `(c-at-vsemi-p)' will NOT call `c-beginning-of-statement-1'.
      ;; Otherwise, return non-nil. (See comments above). The function
      ;; invoked by this macro MUST NOT UNDER ANY CIRCUMSTANCES itself
      ;; call `c-beginning-of-statement-1'."
      (let* ((fn-sym (%c-langvar 'c-vsemi-status-unknown-p-fn))
             (fn (and fn-sym (%c-lang-function fn-sym))))
        (if fn (fn) #f)))

    (define (c-c++-vsemi-p . pos-args)
      ;; "C++ Only - Is there a \"virtual semicolon\" at POS or point?
      ;; (See cc-defs.el for full details of \"virtual semicolons\".)
      ;;
      ;; This is true when point is at the last non syntactic WS position
      ;; on the line, and there is a \"macro with semicolon\" just before
      ;; it (see `c-at-macro-vsemi-p')."
      (apply c-at-macro-vsemi-p pos-args))

    (define (c-at-macro-vsemi-p . pos-args)
      ;; "Is there a \"virtual semicolon\" at POS or point?
      ;; (See cc-defs.el for full details of \"virtual semicolons\".)
      ;;
      ;; This is true when point is at the last non syntactic WS position
      ;; on the line, there is a macro call last on the line, and this
      ;; particular macro's name is defined by the regexp
      ;; `c-macro-with-semi-re' as not needing a semicolon."
      (let ((pos (if (pair? pos-args) (car pos-args) #f)))
        (save-excursion
          (save-restriction
            (widen)
            (if pos
                (goto-char pos)
                (set! pos (point)))
            (and (c-macro-with-semi-re)
                 (= (skip-chars-backward " \t") 0)

                 ;; "Check we've got nothing after this except comments
                 ;; and empty lines joined by escaped EOLs."
                 (skip-chars-forward " \t") ; "always returns non-nil."
                 (begin
                   (let loop ()
                     (when (and (looking-at "\\(\\\\[\n\r][ \t]*\\)*")
                                (begin (goto-char (match-end 0)) #t)
                                (cond
                                 ((let ((re (%c-langvar
                                             'c-block-comment-start-regexp)))
                                    (and re (looking-at re)))
                                  (and (forward-comment 1)
                                       (skip-chars-forward " \t"))) ; "always returns non-nil"
                                 ((let ((re (%c-langvar
                                             'c-line-comment-start-regexp)))
                                    (and re (looking-at re)))
                                  (end-of-line)
                                  #f)
                                 (else #f)))
                       (loop)))
                   (eolp))

                 (goto-char pos)
                 (begin (c-backward-syntactic-ws)
                        (= (point) pos))

                 ;; "Check for one of the listed macros being before
                 ;; point."
                 (or (not (eq? (char-before) #\)))
                     (when (c-go-list-backward)
                       (c-backward-syntactic-ws)
                       #t))
                 (c-simple-skip-symbol-backward)
                 (let ((re (c-macro-with-semi-re)))
                   (and re (looking-at re)))
                 (goto-char pos)
                 (not (c-in-literal))))))) ; "The most expensive check last."

    (define (c-macro-vsemi-status-unknown-p)
      ;; "See cc-defs.el."
      #t)

    ;; The three language functions Emacs's constants name, registered
    ;; where they are defined (the registry is above).
    (c-register-lang-function! 'c-at-macro-vsemi-p c-at-macro-vsemi-p)
    (c-register-lang-function! 'c-c++-vsemi-p c-c++-vsemi-p)
    (c-register-lang-function!
     'c-macro-vsemi-status-unknown-p c-macro-vsemi-status-unknown-p)
    
    ;;------------------------------------------------------------------
    ;; The found-type table (`cc-engine.el:6880'-`:6955')
    ;;------------------------------------------------------------------
    ;; `c-found-types' is a hash of the type names seen in this buffer.
    ;; A template's arglist is cut to "<>" by `c-syntactic-content', so
    ;; "Foo<A,B>::Bar<C>" is stored as "Foo<>::Bar<" - a type is
    ;; recognised by its opening, not by its arguments. The C's
    ;; `make-variable-buffer-local' is the tree's buffer-local slot.
    (define (c-found-types)
      (buffer-local-value (current-buffer) 'c-found-types #f))
    (define (set!c-found-types value)
      (set-buffer-local-value! (current-buffer) 'c-found-types value))

    ;; `cc-engine.el:6970': set by `cc-mode.el''s before-change function
    ;; (not ported) and read by `c-add-type' to hold back a type that is
    ;; still being typed; `c-new-id-is-type' records the answer for the
    ;; after-change side.
    (define (c-new-id-start)
      (buffer-local-value (current-buffer) 'c-new-id-start #f))
    (define (set!c-new-id-start value)
      (set-buffer-local-value! (current-buffer) 'c-new-id-start value))
    (define (c-new-id-end)
      (buffer-local-value (current-buffer) 'c-new-id-end #f))
    (define (set!c-new-id-end value)
      (set-buffer-local-value! (current-buffer) 'c-new-id-end value))
    (define (c-new-id-is-type)
      (buffer-local-value (current-buffer) 'c-new-id-is-type #f))
    (define (set!c-new-id-is-type value)
      (set-buffer-local-value! (current-buffer) 'c-new-id-is-type value))

    (define (c-clear-found-types)
      ;; "Clears `c-found-types'." Emacs's `:test #'equal' is Guile's
      ;; default.
      (set!c-found-types (make-hash-table)))

    ;; `c-fontify-new-found-type' is `cc-fonts.el''s (`:2643'), and
    ;; cc-fonts is not ported. It is called whenever a new type that
    ;; looks like a plain symbol is added, and its job is to put a
    ;; `c-found-type' property on the occurrences so later font-lock
    ;; passes colour them. Nothing in the parser depends on the answer,
    ;; so this is a seam with a do-nothing default that cc-fonts
    ;; replaces when it lands - not a guess at the fontification.
    (define *c-fontify-new-found-type-function* (make-parameter (lambda (type) #f)))

    (define (c-add-type-1 from to)
      ;; "Add the given region as a type in `c-found-types'. Prepare
      ;; occurrences of this new type for fontification throughout the
      ;; buffer."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((type (c-syntactic-content
                   from to (%c-langvar 'c-recognize-<>-arglists))))
        (unless (hash-ref (c-found-types) type #f)
          (hash-set! (c-found-types) type #t)
          (when (and (not (%c-true (*c-record-found-types*)))
                     (let ((m (string-match (or (%c-langvar 'c-symbol-key) "")
                                            type)))
                       (and m (= m 0)
                            (= (match-end 0) (string-length type)))))
            ((*c-fontify-new-found-type-function*) type)))))

    (define (c-add-type from to)
      ;; "Add the given region as a type in `c-found-types'. Also perform
      ;; the actions of `c-add-type-1'. If the region is or overlaps an
      ;; identifier which might be being typed in, don't record it. ..."
      ;;
      ;; "This function might do hidden buffer changes."
      (if (and (c-new-id-start) (c-new-id-end)
               (<= from (c-new-id-end)) (>= to (c-new-id-start)))
          (set!c-new-id-is-type #t)
          (c-add-type-1 from to)))

    (define (c-unfind-type name)
      ;; "Remove the \"NAME\" from c-found-types, if present."
      (hash-remove! (c-found-types) name))

    (define (c-check-type from to)
      ;; "Return non-nil if the given region contains a type in
      ;; `c-found-types'."
      ;;
      ;; "This function might do hidden buffer changes."
      (hash-ref (c-found-types)
                (c-syntactic-content from to (%c-langvar 'c-recognize-<>-arglists))
                #f))

    ;;------------------------------------------------------------------
    ;; The declaration engine's dynamic variables (`cc-engine.el:8424'-`:8492')
    ;;------------------------------------------------------------------
    ;; Emacs `let'-binds all of these around the parser, so they are
    ;; parameters (`*name*'), as the convention says.
    ;;
    ;; "Dynamically bound variable that instructs `c-forward-type' to also
    ;; treat possible types (i.e. those that it normally returns 'maybe or
    ;; 'found for) as actual types (and always return 'found for them)."
    (define *c-promote-possible-types* (make-parameter #f))

    ;; "Dynamically bound variable that instructs `c-forward-<>-arglist' to
    ;; mark up successfully parsed arglists with paren syntax properties on
    ;; the surrounding angle brackets and with `c-<>-arg-sep' in the
    ;; `c-type' property of each argument separating comma."
    (define *c-parse-and-markup-<>-arglists* (make-parameter #f))

    ;; "Dynamically bound variable that instructs `c-forward-<>-arglist' to
    ;; not accept arglists that contain binary operators."
    (define *c-restricted-<>-arglists* (make-parameter #f))

    ;; The recording lists: a cons of the buffer positions surrounding
    ;; each type/reference identifier. "This recording is only activated
    ;; when `c-record-type-identifiers' is non-nil."
    (define *c-record-type-identifiers* (make-parameter #f))
    (define *c-record-ref-identifiers* (make-parameter #f))

    ;; "Dynamically bound variable that instructs `c-forward-type' to
    ;; record the ranges of types that only are found. ..."
    (define *c-record-found-types* (make-parameter #f))

    ;; "This variable will receive a cons cell of the range of the last
    ;; single identifier symbol stepped over by `c-forward-name' if it's
    ;; successful."
    (define *c-last-identifier-range* (make-parameter #f))

    (define (c-record-type-id range)
      ;; `cc-defs.el' has this as a macro whose expansion is chosen by
      ;; whether RANGE is literally a `(cons ...)' form; the two branches
      ;; take the same action here, so it is one procedure.
      (when (%c-true range)
        (*c-record-type-identifiers*
         (cons range (*c-record-type-identifiers*)))))

    (define (c-record-ref-id range)
      ;; "See `c-record-type-id'."
      (when (%c-true range)
        (*c-record-ref-identifiers*
         (cons range (*c-record-ref-identifiers*)))))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:8646'-`:8665': `c-forward-align-clause-throw-if-invalid'
    ;;------------------------------------------------------------------
    ;; Emacs's macro ends with `(throw 'type-error nil)' after moving
    ;; point back to START. Here ESCAPE - the continuation
    ;; `c-forward-type''s `catch 'type-error' installs - is an argument,
    ;; and the answer is the clause's end position on success, #f when
    ;; the keyword is not one of `c-type-modifier-with-parens-kwds'.
    (define (c-forward-align-clause-throw-if-invalid start escape)
      (if (save-match-data
            (let ((re (%c-langvar 'c-type-modifier-with-parens-key)))
              (and re (looking-at re))))
          (let ((pos #f))
            (if (and (= (c-forward-token-2) 0)
                     (eq? (char-after (point)) #\()
                     (c-safe (c-go-list-forward))
                     (eq? (char-before) #\))
                     (begin (set! pos (point)) #t)
                     (begin (c-forward-syntactic-ws) #t))
                pos
                (begin
                  (goto-char start)
                  (escape #f))))
          #f))

    ;;------------------------------------------------------------------
    ;; `c-forward-keyword-clause' and its two helpers (`cc-engine.el:8516'-`:8801')
    ;;------------------------------------------------------------------
    ;; Emacs's `c-forward-keyword-prefixed-id' and `c-forward-id-comma-list'
    ;; are macros whose TYPE and STOP-AT-END arguments are constants at
    ;; expansion time; here they are arguments, which is the same
    ;; contract. `c-forward-id-comma-list' answers the value its
    ;; UPDATE-SAFE-POS arm would have written into the caller's
    ;; `safe-pos', and the caller stores it.
    (define (c-forward-keyword-prefixed-id type stop-at-end)
      ;; "Move forward over a type (if TYPE is 'type) or a name
      ;; (otherwise) which possibly is prefixed by keywords and their
      ;; associated clauses. ..."
      ;;
      ;; "Try with a type/name first to not trip up on those that begin
      ;; with a keyword. Return t if a known or found type is moved
      ;; over. The point is clobbered if nil is returned."
      ;;
      ;; "This macro might do hidden buffer changes."
      (let ((res #f) (pos #f))
        (*c-last-identifier-range* #f)
        (let loop ()
          (when (begin
                  (set! res (if (eq? type 'type)
                                (c-forward-type #f stop-at-end)
                                (c-forward-name stop-at-end)))
                  (if (%c-true res)
                      (begin (set! pos (point)) #f)
                      (and (cond
                            ((let ((re (%c-langvar 'c-keywords-regexp)))
                               (and re (looking-at re)))
                             (c-forward-keyword-clause 1 #t))
                            ((and (%c-langvar 'c-opt-cpp-prefix)
                                  (let ((re (c-noise-macro-with-parens-name-re)))
                                    (and re (looking-at re))))
                             (c-forward-noise-clause #t))
                            (else #f))
                           (begin
                             (set! pos (point))
                             (c-forward-syntactic-ws)
                             #t))))
            (loop)))
        (if (memv res (list #t 'known 'found 'prefix 'maybe))
            (begin
              (when (%c-true (*c-record-type-identifiers*))
                (if (eq? type 'type)
                    (c-record-type-id (*c-last-identifier-range*))
                    (c-record-ref-id (*c-last-identifier-range*))))
              (when pos
                (goto-char pos)
                (unless stop-at-end
                  (c-forward-syntactic-ws)))
              #t)
            ;; Emacs's `(when ...)' is nil here; a Scheme `when' would
            ;; answer the *unspecified* value, which is true, and every
            ;; caller tests this as a boolean.
            #f)))

    (define (c-forward-id-comma-list type update-safe-pos stop-at-end safe-pos)
      ;; "Move forward over a comma separated list of types or names
      ;; using `c-forward-keyword-prefixed-id'. ... The return value is
      ;; without significance."
      ;;
      ;; "This macro might do hidden buffer changes."
      (let ((pos (point)))
        (let loop ()
          (when (and (begin
                       (when update-safe-pos
                         (set! safe-pos (point)))
                       (set! pos (point))
                       (c-forward-syntactic-ws)
                       (eq? (char-after (point)) #\,))
                     (begin
                       (forward-char)
                       (set! pos (point))
                       (c-forward-syntactic-ws)
                       (c-forward-keyword-prefixed-id type #t)))
            (loop)))
        (goto-char pos)
        (unless stop-at-end
          (c-forward-syntactic-ws))
        safe-pos))

    (define (c-forward-keyword-clause match . args)
      ;; "Submatch MATCH in the current match data is assumed to surround
      ;; a token. If it's a keyword, move over it and, if present, over
      ;; any immediately following clauses associated with it, stopping
      ;; either at the start of the next token, or (when STOP-AT-END is
      ;; non-nil) at the end of the clause. t is returned in that case,
      ;; otherwise the point stays and nil is returned. ..."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((stop-at-end (if (pair? args) (car args) #f)))
        (let ((kwd-sym (c-keyword-sym (match-string match)))
              (safe-pos #f)
              (pos #f))
          ;; "The call to `c-forward-<>-arglist' below is made after
          ;; `c-<>-sexp-kwds' keywords, so we're certain they actually
          ;; are angle bracket arglists and `c-restricted-<>-arglists'
          ;; should therefore be nil."
          (parameterize ((*c-parse-and-markup-<>-arglists* #t)
                         (*c-restricted-<>-arglists* #f))
            (if kwd-sym
                (begin
              (goto-char (match-end match))
              (set! safe-pos (point))
              (c-forward-syntactic-ws)

              (cond
               ((and (c-keyword-member kwd-sym 'c-type-list-kwds)
                     (c-forward-keyword-prefixed-id 'type #t))
                ;; "There's a type directly after a keyword in
                ;; `c-type-list-kwds'."
                (set! safe-pos (point))
                (c-forward-syntactic-ws)
                (set! safe-pos
                      (c-forward-id-comma-list 'type #t #t safe-pos)))

               ((and (c-keyword-member kwd-sym 'c-ref-list-kwds)
                     (c-forward-keyword-prefixed-id 'ref #t))
                ;; "There's a name directly after a keyword in
                ;; `c-ref-list-kwds'."
                (set! safe-pos (point))
                (c-forward-syntactic-ws)
                (set! safe-pos
                      (c-forward-id-comma-list 'ref #t #t safe-pos)))

               ((and (c-keyword-member kwd-sym 'c-paren-type-kwds)
                     (eq? (char-after (point)) #\())
                ;; "There's an open paren after a keyword in
                ;; `c-paren-any-kwds'."
                (forward-char)
                (let ((up (c-up-list-forward)))
                  (when (and up (eq? (char-before up) #\)))
                    (when (and (%c-true (*c-record-type-identifiers*))
                               (c-keyword-member kwd-sym 'c-paren-type-kwds))
                      ;; "Use `c-forward-type' on every identifier we can
                      ;; find inside the paren, to record the types."
                      (let ((re (%c-langvar 'c-symbol-start)))
                        (let record ()
                          (when (c-syntactic-re-search-forward re up #t)
                            (goto-char (match-beginning 0))
                            (unless (c-forward-type)
                              ;; "Always matches."
                              (let ((sre (%c-langvar 'c-symbol-key)))
                                (and sre (looking-at sre)))
                              (goto-char (match-end 0)))
                            (record)))))
                    (goto-char up)
                    (set! safe-pos (point))))
                (c-forward-syntactic-ws))

               ((c-keyword-member kwd-sym 'c-paren-nontype-kwds)
                (when (and (eq? (char-after (point)) #\()
                           (c-go-list-forward))
                  (set! safe-pos (point))
                  (c-forward-syntactic-ws)))

               ((and (c-keyword-member kwd-sym 'c-<>-sexp-kwds)
                     (eq? (char-after (point)) #\<)
                     (c-forward-<>-arglist
                      (c-keyword-member kwd-sym 'c-<>-type-kwds)))
                (set! safe-pos (point))
                (c-forward-syntactic-ws))

               ((and (c-keyword-member kwd-sym 'c-nonsymbol-sexp-kwds)
                     (not (let ((re (%c-langvar 'c-symbol-start)))
                            (and re (looking-at re))))
                     (c-safe (c-forward-sexp) #t))
                (set! safe-pos (point))
                (c-forward-syntactic-ws))

               ((and (c-keyword-member kwd-sym 'c-protection-kwds)
                     (let ((pp (%c-langvar 'c-post-protection-token)))
                       (or (not (%c-true pp))
                           (and (looking-at pp)
                                (save-excursion
                                  (goto-char (match-end 0))
                                  (not (c-end-of-current-token)))))))
                (let ((pp (%c-langvar 'c-post-protection-token)))
                  (when (%c-true pp)
                    (goto-char (match-end 0))))
                (set! safe-pos (point))
                (c-forward-syntactic-ws)))

              (when (c-keyword-member kwd-sym 'c-colon-type-list-kwds)
                (if (eq? (char-after (point)) #\:)
                    ;; "If we are at the colon already, we move over the
                    ;; type list after it."
                    (begin
                      (forward-char)
                      (c-forward-syntactic-ws)
                      (when (c-forward-keyword-prefixed-id 'type #t)
                        (set! safe-pos (point))
                        (c-forward-syntactic-ws)
                        (set! safe-pos
                              (c-forward-id-comma-list 'type #t #t safe-pos))))
                    ;; "Not at the colon, so stop here. But the
                    ;; identifier ranges in the type list later on should
                    ;; still be recorded."
                    (and (%c-true (*c-record-type-identifiers*))
                         (begin
                           ;; "If a keyword matched both one of the types
                           ;; above and this one, we move forward to the
                           ;; colon following the clause matched above."
                           (goto-char safe-pos)
                           (c-forward-syntactic-ws)
                           (c-forward-over-colon-type-list))
                         (begin
                           (c-forward-syntactic-ws)
                           (c-forward-keyword-prefixed-id 'type #t))
                         ;; "There's a type after the
                         ;; `c-colon-type-list-re' match after a keyword
                         ;; in `c-colon-type-list-kwds'."
                         (c-forward-id-comma-list 'type #f #f safe-pos))))

              (goto-char safe-pos)
              (unless stop-at-end
                (c-forward-syntactic-ws))
              #t)
                ;; Emacs's nil when KWD-SYM is nil; a `when' would answer
                ;; the unspecified value, which is true.
                #f)))))

    ;;------------------------------------------------------------------
    ;; `c-forward-<>-arglist' (`cc-engine.el:8806'-`:9137')
    ;;------------------------------------------------------------------
    ;; `copy-hash-table' (`fns.c:4639') is not in this Guile's `(guile)'
    ;; module, which has the iteration but not the copy.
    (define (%c-hash-copy table)
      (let ((new (make-hash-table)))
        (hash-for-each (lambda (k v) (hash-set! new k v)) table)
        new))

    (define (c-forward-<>-arglist all-types)
      ;; "The point is assumed to be at a \"<\". Try to treat it as the
      ;; open paren of an angle bracket arglist and move forward to the
      ;; corresponding \">\". If successful, the point is left after the
      ;; \">\" and t is returned, otherwise the point isn't moved and nil
      ;; is returned. If ALL-TYPES is t then all encountered arguments in
      ;; the arglist that might be types are treated as found types."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((start (point))
            (old-record-type-identifiers (*c-record-type-identifiers*))
            (old-found-types (%c-hash-copy (c-found-types))))
        ;; "If `c-record-type-identifiers' is set then activate recording
        ;; of any found types that constitute an argument in the arglist."
        (parameterize ((*c-record-found-types*
                        (if (%c-true (*c-record-type-identifiers*)) #t #f)))
          ;; "Special handling for C++20's \"import <...>\" operator."
          (if (and (c-major-mode-is 'c++-mode)
                   (save-excursion
                     (and (= (c-backward-token-2) 0)
                          (looking-at "import\\_>"))))
              (when (looking-at "<\\(?:\\\\.\\|[^\\\n\r\t>]\\)*\\(>\\)?")
                (if (match-beginning 1) ; "A terminated <..>"
                    (begin
                      (when (%c-true (*c-parse-and-markup-<>-arglists*))
                        (c-mark-<-as-paren (point))
                        (c-mark->-as-paren (match-beginning 1))
                        (c-truncate-lit-pos/state-cache (point)))
                      (goto-char (match-end 1))
                      #t)
                    #f))
              ;; Emacs's `(catch ... (setq c-record-found-types
              ;; (c-forward-<>-arglist-recur ...)))' is the recur's
              ;; value; a parameter's setter does not answer it, so the
              ;; value is held first.
              (let ((recur
                     (call-with-current-continuation
                      (lambda (escape)
                        (c-forward-<>-arglist-recur all-types escape)))))
                (*c-record-found-types* recur)
                (if recur
                  (begin
                    (when (pair? (*c-record-found-types*))
                      (let ((cur (*c-record-found-types*)))
                        (let fontify ()
                          (when (and (pair? cur) (pair? (car cur)))
                            ((*c-fontify-new-found-type-function*)
                             (buffer-substring-no-properties (caar cur) (cdar cur)))
                            (set! cur (cdr cur))
                            (fontify))))
                      ;; "`nconc' doesn't mind that the tail of
                      ;; `c-record-found-types' is t."
                      (*c-record-type-identifiers*
                       (nconc (*c-record-found-types*)
                              (*c-record-type-identifiers*))))
                    #t)
                  (begin
                    (*c-record-type-identifiers* old-record-type-identifiers)
                    (set!c-found-types old-found-types)
                    (goto-char start)
                    #f)))))))

    (define (c-forward-<>-arglist-recur all-types escape)
      ;; "Recursive part of `c-forward-<>-arglist'."
      ;;
      ;; "This function might do hidden buffer changes."
      ;;
      ;; ESCAPE is Emacs's `(catch 'angle-bracket-arglist-escape ...)':
      ;; the single `throw' in this function escapes through it, and the
      ;; recursive calls pass the same one, so a nested arglist that
      ;; fails abandons the whole outermost parse as Emacs's does.
      (let ((start (point))
            (res #f)
            (pos #f)
            ;; "Cover this so that any recorded found type ranges are
            ;; automatically lost if it turns out to not be an angle
            ;; bracket arglist. It's propagated through the return value
            ;; on successful completion."
            (syntax-table-prop-on-< (c-get-char-property (point) 'syntax-table))
            ;; "List that collects the positions after the argument
            ;; separating ',' in the arglist."
            (arg-start-pos '()))
        (parameterize ((*c-record-found-types* (*c-record-found-types*)))
          (if (and (not (%c-true (*c-parse-and-markup-<>-arglists*)))
                   syntax-table-prop-on-<)
              (begin
                (forward-char)
                (if (and (c-go-up-list-forward)
                         (eq? (char-before) #\>))
                    #t
                    ;; "Got unmatched paren angle brackets. ..."
                    (begin
                      (goto-char start)
                      #f)))
              (begin
                (forward-char) ; "Forward over the opening '<'."
                (unless (and (let ((re (%c-langvar 'c-<-op-cont-regexp)))
                               (and re (looking-at re)))
                             (not (let ((re (%c-langvar 'c-<-pseudo-digraph-cont-regexp)))
                                    (and re (looking-at re)))))
                  ;; "go forward one non-alphanumeric character (group) per
                  ;; iteration of this loop."
                  (let loop ()
                    (when (and
                           (begin
                             (c-forward-syntactic-ws)
                             (when (or (and (%c-true (*c-record-type-identifiers*))
                                            all-types)
                                       (not (let ((k (%c-langvar 'c-inside-<>-type-key)))
                                              (and k
                                                   (string=? k (string-append
                                                                "\\("
                                                                regexp-unmatchable
                                                                "\\)"))))))
                               (c-forward-syntactic-ws)
                               (cond
                                ((eq? (char-after (point)) #\?)
                                 (forward-char))
                                ((and (let ((re (%c-langvar 'c-identifier-start)))
                                        (and re (looking-at re)))
                                      (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                             (and re (looking-at re)))))
                                 (if (or (and all-types
                                              (%c-true (*c-record-type-identifiers*)))
                                         (c-major-mode-is 'java-mode))
                                     ;; "All encountered identifiers are
                                     ;; types, so set the promote flag
                                     ;; and parse the type."
                                     (parameterize ((*c-promote-possible-types* #t)
                                                    (*c-record-found-types* #t))
                                       (c-forward-type))
                                     (c-forward-over-token-and-ws)))
                                (else #f))
                               (c-forward-syntactic-ws)
                               (when (let ((re (%c-langvar 'c-inside-<>-type-key)))
                                       (and re (looking-at re)))
                                 (goto-char (match-end 1))
                                 (c-forward-syntactic-ws)
                                 (parameterize ((*c-promote-possible-types* #t)
                                                (*c-record-found-types* #t))
                                   (c-forward-type))
                                 (c-forward-syntactic-ws)))
                             (set! pos (point)) ; "e.g. first token inside the '<'"
                             ;; "Note: These regexps exploit the match
                             ;; order in \\| so that \"<>\" is matched by
                             ;; \"<\" rather than \"[^>:-]>\"."
                             (c-syntactic-re-search-forward
                              (%c-langvar 'c-<>-notable-chars-re)
                              #f #t #t))
                           (cond
                            ((eq? (char-before) #\>)
                             ;; "Either an operator starting with '>' or
                             ;; the end of the angle bracket arglist."
                             (if (save-excursion
                                   (c-backward-token-2)
                                   (let ((re (%c-langvar 'c-multichar->-op-not->>->>>-regexp)))
                                     (and re (looking-at re))))
                                 (begin
                                   (goto-char (match-end 0))
                                   #t) ; "Continue the loop."
                                 ;; "The angle bracket arglist is finished."
                                 (begin
                                   (when (%c-true (*c-parse-and-markup-<>-arglists*))
                                     (let flush ()
                                       (when (pair? arg-start-pos)
                                         (c-put-c-type-property
                                          (- (car arg-start-pos) 1)
                                          'c-<>-arg-sep)
                                         (set! arg-start-pos (cdr arg-start-pos))
                                         (flush)))
                                     (when (and (not syntax-table-prop-on-<)
                                                (c-get-char-property
                                                 (- (point) 1) 'syntax-table))
                                       ;; "Clear the now spuriously
                                       ;; matching < of its syntax-table
                                       ;; property. ..."
                                       (save-excursion
                                         (and (c-go-list-backward)
                                              (eq? (char-after (point)) #\<)
                                              (c-truncate-lit-pos/state-cache (point))
                                              (c-unmark-<-or->-as-paren (point)))))
                                     (c-mark-<-as-paren start)
                                     (c-mark->-as-paren (- (point) 1))
                                     (c-truncate-lit-pos/state-cache start))
                                   (set! res #t)
                                   #f))) ; "Exit the loop."

                            ((eq? (char-before) #\<)
                             ;; "Either an operator starting with '<' or a
                             ;; nested arglist."
                             (set! pos (point))
                             (let ((id-start #f) (id-end #f) (subres #f)
                                   (keyword-match #f))
                               (cond
                                ;; "The '<' begins a multi-char operator."
                                ((and (let ((re (%c-langvar 'c-<-op-cont-regexp)))
                                        (and re (looking-at re)))
                                      (not (let ((re (%c-langvar 'c-<-pseudo-digraph-cont-regexp)))
                                             (and re (looking-at re)))))
                                 (goto-char (match-end 0)))
                                ;; "We're at a nested <.....>"
                                ((begin
                                   (backward-char) ; "to the '<'"
                                   (and
                                    (save-excursion
                                      ;; "There's always an identifier
                                      ;; before an angle bracket arglist,
                                      ;; or a keyword in `c-<>-type-kwds'
                                      ;; or `c-<>-arglist-kwds'."
                                      (c-backward-syntactic-ws)
                                      (set! id-end (point))
                                      (c-simple-skip-symbol-backward)
                                      (when (or (begin
                                                  (set! keyword-match
                                                        (let ((re (%c-langvar 'c-opt-<>-sexp-key)))
                                                          (and re (looking-at re))))
                                                  keyword-match)
                                                (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                                       (and re (looking-at re)))))
                                        (set! id-start (point))
                                        ;; Emacs's `(setq ...)' answers the
                                        ;; value; a Scheme `set!' answers no
                                        ;; values, and this `when' is the
                                        ;; `save-excursion''s value.
                                        #t))
                                    (begin
                                      (set! subres
                                            (parameterize ((*c-promote-possible-types* #t)
                                                           (*c-record-found-types* #t))
                                              (c-forward-<>-arglist-recur
                                               (and keyword-match
                                                    (c-keyword-member
                                                     (c-keyword-sym (match-string 1))
                                                     'c-<>-type-kwds))
                                               escape)))
                                      subres)
                                    (or subres (goto-char pos))
                                    subres)
                                 ;; "It was an angle bracket arglist."
                                 (*c-record-found-types* subres)
                                 ;; "Record the identifier before the
                                 ;; template as a type or reference
                                 ;; depending on whether the arglist is
                                 ;; last in a qualified identifier."
                                 (when (and (%c-true (*c-record-type-identifiers*))
                                            (not keyword-match))
                                   (if (and (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                                            (begin
                                              (c-forward-syntactic-ws)
                                              (let ((re (%c-langvar 'c-opt-identifier-concat-key)))
                                                (and re (looking-at re)))))
                                       (c-record-ref-id (cons id-start id-end))
                                       (c-record-type-id (cons id-start id-end))))))
                                ;; "At a \"less than\" operator."
                                (else #f)))
                               #t) ; "carry on looping."

                            ((and (eq? (char-before) #\()
                                  (c-go-up-list-forward)
                                  (eq? (char-before) #\))))

                            ((and (not (%c-true (*c-restricted-<>-arglists*)))
                                  (or (and (eq? (char-before) #\&)
                                           (not (eq? (char-after (point)) #\&)))
                                      (eq? (char-before) #\,)))
                             ;; "Just another argument. Record the
                             ;; position. ..."
                             (set! arg-start-pos (cons (point) arg-start-pos)))

                            (else
                             ;; "Got a character that can't be in an
                             ;; angle bracket arglist argument. Abort
                             ;; using `throw', since it's useless to try
                             ;; to find a surrounding arglist if we're
                             ;; nested."
                             (escape #f))))
                    (loop))))
                (if res
                    (if (%c-true (*c-record-found-types*))
                        (*c-record-found-types*)
                        #t)))))))

    (define (c-backward-<>-arglist all-types . args)
      ;; "The point is assumed to be directly after a \">\". Try to treat
      ;; it as the close paren of an angle bracket arglist and move back
      ;; to the corresponding \"<\". ..."
      ;;
      ;; "This is a wrapper around `c-forward-<>-arglist'. See that
      ;; function for more details."
      (let ((limit (if (pair? args) (car args) #f))
            (restricted-function (if (and (pair? args) (pair? (cdr args)))
                                     (cadr args) #f))
            (start (point)))
        (backward-char)
        (if (and (not (%c-true (*c-parse-and-markup-<>-arglists*)))
                 (c-get-char-property (point) 'syntax-table))
            (if (and (c-go-up-list-backward)
                     (eq? (char-after (point)) #\<))
                #t
                ;; "See corresponding note in `c-forward-<>-arglist'."
                (begin (goto-char start) #f))
            (begin
             (let loop ()
              (when (begin
                      (c-syntactic-skip-backward "^<;{}" limit #t)
                      (and
                       (if (eq? (char-before) #\<)
                           #t
                           ;; "Stopped at bob or a char that isn't
                           ;; allowed in an arglist, so we've failed."
                           (begin (goto-char start) #f))
                       (if (> (point)
                              (begin (c-beginning-of-current-token) (point)))
                           ;; "If we moved then the \"<\" was part of
                           ;; some multicharacter token."
                           #t
                           (begin
                             (backward-char)
                             (let ((beg-pos (point)))
                               (parameterize ((*c-restricted-<>-arglists*
                                               (if restricted-function
                                                   (restricted-function)
                                                   (*c-restricted-<>-arglists*))))
                                 (if (c-forward-<>-arglist all-types)
                                     (cond ((= (point) start)
                                            ;; "Matched the arglist. Break
                                            ;; the while."
                                            (goto-char beg-pos)
                                            #f)
                                           ((> (point) start)
                                            ;; "We started from a
                                            ;; non-paren \">\" inside an
                                            ;; arglist."
                                            (goto-char start)
                                            #f)
                                           (else
                                            ;; "Matched a shorter
                                            ;; arglist. Can be a nested
                                            ;; one so continue looking."
                                            (goto-char beg-pos)
                                            #t))
                                     #t)))))))
               (loop)))
             (not (= (point) start))))))

    ;;------------------------------------------------------------------
    ;; `c-forward-name' (`cc-engine.el:9139'-`:9338')
    ;;------------------------------------------------------------------
    ;; Emacs builds the "operator"/"template" tag regexp at compile time
    ;; from `c-nonsymbol-key' for c++ ("(cc-eval-when-compile (concat
    ;; ...))"). Here it is built on first use, because cc-langs'
    ;; registry is only complete once that library has loaded.
    (define %c++-operator-template-re #f)
    (define (%c-operator-template-re)
      (or %c++-operator-template-re
          (begin
            (set! %c++-operator-template-re
                  (string-append
                   "\\(operator\\|\\(template\\)\\)\\("
                   (or (c-get-lang-constant 'c-nonsymbol-key #f 'c++-mode) "")
                   "\\|$\\)"))
            %c++-operator-template-re)))

    (define (c-forward-name . args)
      ;; "Move forward over a complete name if at the beginning of one,
      ;; stopping either at the next following token or (when STOP-AT-END
      ;; is non-nil) at the end of the name. A keyword, as such, doesn't
      ;; count as a name. ..."
      ;;
      ;; Return nil if no name is found; 'template if it's an identifier
      ;; ending with an angle bracket arglist; 'operator if it's an
      ;; operator identifier; t if it's some other kind of name.
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((stop-at-end (if (pair? args) (car args) #f)))
        ;; "Turn off `c-promote-possible-types' here since we might call
        ;; `c-forward-<>-arglist' and we don't want it to promote every
        ;; suspect thing in the arglist to a type. ..."
        (parameterize ((*c-promote-possible-types* #f))
          (let ((pos (point)) (pos2 #f) (pos3 #f)
                (start (point)) (res #f) (id-start #f) (id-end #f)
                (lim+ (c-determine-+ve-limit 500)))
            (let loop ()
              (when (and
                     (< (point) lim+)
                     (let ((re (%c-langvar 'c-identifier-key)))
                       (and re (looking-at re)))
                     (begin
                       ;; "Check for keyword. We go to the last symbol in
                       ;; `c-identifier-key' first."
                       (goto-char (begin (set! id-end (match-end 0)) id-end))
                       (c-simple-skip-symbol-backward)
                       (set! id-start (point))

                       (if (let ((re (%c-langvar 'c-keywords-regexp)))
                             (and re (looking-at re)))
                           ;; Emacs's `(when ...)' is nil when the test
                           ;; fails; the value is this `if''s result,
                           ;; which is the enclosing `and''s, so a
                           ;; Scheme `when' - the unspecified value - on
                           ;; a keyword in C mode would keep the loop
                           ;; going for ever.
                           (if (and (c-major-mode-is 'c++-mode)
                                    (looking-at (%c-operator-template-re))
                                      (if (match-beginning 2)
                                          ;; "\"template\" is only valid
                                          ;; inside an identifier if
                                          ;; preceded by \"::\"."
                                          (save-excursion
                                            (c-backward-syntactic-ws)
                                            (and (c-safe (backward-char 2) #t)
                                                 (looking-at "::")))
                                          #t))
                                (begin
                             ;; "Handle a C++ operator or template
                             ;; identifier."
                             (goto-char id-end)
                             (c-forward-syntactic-ws lim+)
                             (cond
                              ((eq? (char-before id-end) #\e)
                               ;; "Got \"... ::template\"."
                               (let ((subres (c-forward-name #t)))
                                 (when subres
                                   (set! pos (point))
                                   (set! res subres))))

                              ((and (let ((re (%c-langvar 'c-identifier-start)))
                                      (and re (looking-at re)))
                                    (or (not (let ((re (%c-langvar
                                                        'c-ambiguous-overloadable-or-identifier-prefix-re)))
                                               (and re (looking-at re))))
                                        (save-excursion
                                          (and (= (c-forward-token-2) 0)
                                               (not (eq? (char-after (point)) #\())))) )
                               ;; "Got a cast operator."
                               (when (c-forward-type #f #t)
                                 (set! pos (point))
                                 (set! res 'operator)
                                 ;; "Now we should match a sequence of
                                 ;; either '*', '&' or a name followed by
                                 ;; \":: *\", where each can be followed
                                 ;; by a sequence of
                                 ;; `c-opt-type-modifier-key'."
                                 (let scan ()
                                   (when (and (< (point) lim+)
                                              (cond ((looking-at "[*&]")
                                                     (goto-char (match-end 0))
                                                     #t)
                                                    ((let ((re (%c-langvar 'c-identifier-start)))
                                                       (and re (looking-at re)))
                                                     (and (c-forward-name)
                                                          (looking-at "::")
                                                          (begin
                                                            (goto-char (match-end 0))
                                                            (c-forward-syntactic-ws lim+)
                                                            (eq? (char-after (point)) #\*))
                                                          (begin
                                                            (forward-char)
                                                            #t)))))
                                     (scan)))
                                 (let mods ()
                                   (when (begin
                                          (set! pos (point))
                                          (c-forward-syntactic-ws lim+)
                                          (and (<= (point) lim+)
                                               (let ((re (%c-langvar 'c-opt-type-modifier-key)))
                                                 (and re (looking-at re)))))
                                     (goto-char (match-end 1))
                                     (mods)))))

                              ((let ((re (%c-langvar 'c-overloadable-operators-regexp)))
                                 (and re (looking-at re)))
                               ;; "Got some other operator."
                               (*c-last-identifier-range*
                                (cons (point) (match-end 0)))
                               (if (and (eq? (char-after (point)) #\")
                                        (eq? (char-after (+ 1 (point))) #\"))
                                   ;; "operator\"\" has an (?)optional tag
                                   ;; after it."
                                   (begin
                                     (goto-char (match-end 0))
                                     (set! pos2 (point))
                                     (c-forward-syntactic-ws lim+)
                                     (when (c-on-identifier)
                                       (c-forward-over-token #f lim+)))
                                   (begin
                                     (goto-char (match-end 0))
                                     (set! pos2 (point))
                                     (c-forward-syntactic-ws lim+)))
                               (set! pos pos2)
                               (set! res 'operator))
                                   (else #f))
                                  #f)
                                #f)
                           (begin
                             ;; "`id-start' is equal to `id-end' if we've
                             ;; jumped over an identifier that doesn't end
                             ;; with a symbol token. ..."
                             (when (and id-start (not (= id-start id-end)))
                               (*c-last-identifier-range*
                                (cons id-start id-end)))
                             (goto-char id-end)
                             (set! pos (point))
                             (c-forward-syntactic-ws lim+)
                             (set! res #t))))
                     (begin
                       (goto-char pos)
                       (c-forward-syntactic-ws lim+)
                       (set! pos3 (point))
                       ;; Emacs's `(when ...)' is nil when neither is
                       ;; set - which is C and every language without
                       ;; template arglists - and that nil is this
                       ;; `progn''s value, the enclosing `and''s last
                       ;; test. A Scheme `when' answers the unspecified
                       ;; value, so the loop would run on and take the
                       ;; next token for part of the name.
                       (if (or (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                               (%c-true (%c-langvar 'c-recognize-<>-arglists)))
                         (cond
                          ((and (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                                (let ((re (%c-langvar 'c-opt-identifier-concat-key)))
                                  (and re (looking-at re))))
                           ;; "Got a concatenated identifier. This handles
                           ;; the cases with tricky syntactic whitespace
                           ;; that aren't covered in `c-identifier-key'."
                           (goto-char (match-end 0))
                           #t)

                          ((and (%c-true (%c-langvar 'c-recognize-<>-arglists))
                                (eq? (char-after (point)) #\<))
                           ;; "Maybe an angle bracket arglist."
                           (when (parameterize ((*c-last-identifier-range* #f))
                                   (c-forward-<>-arglist #f))
                             ;; "<> arglists can legitimately be very
                             ;; long, so recalculate `lim+'."
                             (set! lim+ (c-determine-+ve-limit 500))

                             (set! pos2 (point))
                             (c-forward-syntactic-ws lim+)
                             (unless (eq? (char-after (point)) #\()
                               (*c-last-identifier-range* #f)
                               (c-add-type start (+ 1 pos3)))
                             (set! pos pos2)

                             (if (and (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                                      (let ((re (%c-langvar 'c-opt-identifier-concat-key)))
                                        (and re (looking-at re))))

                                 ;; "Continue if there's an identifier
                                 ;; concatenation operator after the
                                 ;; template argument."
                                 (begin
                                   (when (and (%c-true (*c-record-type-identifiers*))
                                              id-start)
                                     (c-record-ref-id (cons id-start id-end)))
                                   (goto-char (match-end 0))
                                   (c-forward-syntactic-ws lim+)
                                   #t)

                                 (begin
                                   (when (and (%c-true (*c-record-type-identifiers*))
                                              id-start
                                              (not (eq? (char-after (point)) #\()))
                                     (c-record-type-id (cons id-start id-end)))
                                   (set! res 'template)
                                   #f))))
                          (else #f))
                         #f)))
              (loop)))
            (goto-char pos)
            (unless stop-at-end
              (c-forward-syntactic-ws lim+))
            res))))

    ;;------------------------------------------------------------------
    ;; `c-forward-type' (`cc-engine.el:9340'-`:9748')
    ;;------------------------------------------------------------------
    (define (c-forward-type . args)
      ;; "Move forward over a type spec if at the beginning of one,
      ;; stopping at the next following token (if STOP-AT-END is nil) or
      ;; at the end of the type spec (otherwise). The keyword \"typedef\"
      ;; isn't part of a type spec here."
      ;;
      ;; Return t if it's a known type that can't be a name or other
      ;; expression; 'known if it's an otherwise known type; 'prefix if
      ;; it's a known prefix of a type; 'found if it matches one in
      ;; `c-found-types'; 'maybe if it's an identifier that might be a
      ;; type; 'decltype if it's a decltype(variable) declaration;
      ;; 'no-id if "auto" precluded parsing a type identifier or the
      ;; type int was implicit; nil if it can't be a type.
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((brace-block-too (if (pair? args) (car args) #f))
            (stop-at-end (if (and (pair? args) (pair? (cdr args)))
                             (cadr args) #f)))
        (when (and (%c-true (%c-langvar 'c-recognize-<>-arglists))
                   (looking-at "<"))
          (c-forward-<>-arglist #t)
          (c-forward-syntactic-ws))

        (let ((start (point)) (pos #f) (res #f) (name-res #f) (id-start #f)
              (id-end #f) (id-range #f) (post-prefix-pos #f)
              (prefix-end-pos #f) (equals-makes-type #f))
          ;; Emacs's `(catch 'type-error ...)': the escape is handed to
          ;; `c-forward-align-clause-throw-if-invalid', which abandons
          ;; the whole parse after restoring point.
          (call-with-current-continuation
           (lambda (type-error)
             ;; "Skip leading type modifiers. If any are found we know
             ;; it's a prefix of a type."
             (when (%c-true (%c-langvar 'c-maybe-typeless-specifier-re))
               (let loop ()
                 (when (let ((re (%c-langvar 'c-maybe-typeless-specifier-re)))
                         (and re (looking-at re)))
                   (save-match-data
                     (when (let ((re (%c-langvar 'c-no-type-key)))
                             (and re (looking-at re)))
                       (set! res 'no-id))
                     (when (let ((re (%c-langvar 'c-no-type-with-equals-key)))
                             (and re (looking-at re)))
                       (set! equals-makes-type #t)))
                   (let ((r (c-forward-align-clause-throw-if-invalid start type-error)))
                     (if r
                         (set! prefix-end-pos r)
                         (begin
                           (goto-char (match-end 1))
                           (set! prefix-end-pos (point))
                           (set! pos (point))
                           (c-forward-syntactic-ws)
                           (or (eq? res 'no-id)
                               (set! res 'prefix)))))
                   (loop))))
             (set! post-prefix-pos (point))

             (cond
              ;; e.g. C++'s "decltype".
              ((let ((re (%c-langvar 'c-typeof-key)))
                 (and re (looking-at re)))
               (goto-char (match-end 1))
               (set! pos (point))
               (c-forward-syntactic-ws)
               (set! res (and (eq? (char-after (point)) #\()
                              (c-safe (c-forward-sexp))
                              'decltype))
               (if res
                   (begin
                     (set! pos (point))
                     (c-forward-syntactic-ws))
                   (goto-char start)))

              ;; e.g. "struct", "class", but NOT "typedef".
              ((let ((re (%c-langvar 'c-type-prefix-key)))
                 (and re (looking-at re)))
               (goto-char (match-end 1))
               (set! pos (point))
               (c-forward-syntactic-ws)

               (let skip ()
                 (when (cond
                        ((let ((re (%c-langvar 'c-decl-hangon-key)))
                           (and re (looking-at re)))
                         (c-forward-keyword-clause 1 #t)
                         (set! pos (point))
                         (c-forward-syntactic-ws))
                        ((let ((re (%c-langvar 'c-pack-key)))
                           (and re (looking-at re)))
                         (goto-char (match-end 1))
                         (set! pos (point))
                         (c-forward-syntactic-ws))
                        ((and (%c-langvar 'c-opt-cpp-prefix)
                              (let ((re (c-noise-macro-with-parens-name-re)))
                                (and re (looking-at re))))
                         (c-forward-noise-clause #t)
                         (set! pos (point))
                         (c-forward-syntactic-ws))
                        (else #f))
                   (skip)))

               (set! id-start (point))
               (set! name-res (c-forward-name #t))
               (set! pos (point))
               (set! res (not (%c-false name-res)))
               (when (eq? name-res #t)
                 ;; "With some keywords the name can be used without the
                 ;; prefix, so we add the name to `c-found-types' when
                 ;; this is the case."
                 (when (save-excursion
                         (goto-char post-prefix-pos)
                         (let ((re (%c-langvar 'c-self-contained-typename-key)))
                           (and re (looking-at re))))
                   (c-add-type id-start (point)))
                 (when (and (%c-true (*c-record-type-identifiers*))
                            (*c-last-identifier-range*))
                   (c-record-type-id (*c-last-identifier-range*))))
               (c-forward-syntactic-ws)
               (when (and brace-block-too
                          ;; Emacs's `(memq res '(t nil))' is true for
                          ;; both values RES can hold here.
                          (memv res (list #t #f))
                          (eq? (char-after (point)) #\{)
                          (save-excursion
                            (c-safe
                             (begin (c-forward-sexp) (set! pos (point)) #t))))
                 (goto-char pos)
                 (c-forward-syntactic-ws)
                 (set! res #t))
               (unless res (goto-char start))) ; "invalid syntax"

              ;; C's "_BitInt".
              ((let ((re (%c-langvar 'c-type-with-paren-key)))
                 (and re (looking-at re)))
               (goto-char (match-end 1))
               (c-forward-syntactic-ws)
               (if (and (eq? (char-after (point)) #\()
                        (c-go-list-forward #f (min (+ (point) 500) (point-max)))
                        (eq? (char-before) #\)))
                   (begin
                     (set! pos (point))
                     (c-forward-syntactic-ws)
                     (set! res #t))
                   (begin
                     (goto-char start)
                     (set! res #f)))) ; "invalid syntax."

              ((and
                (not (eq? res 'no-id))
                (not (and equals-makes-type
                          (save-excursion
                            (and (= (c-forward-token-2) 0)
                                 (looking-at "=\\([^=]\\|$\\)")))
                          (begin (set! res 'no-id) res)))
                (begin
                  (set! pos #f)
                  (let skip ()
                    (when (and (%c-langvar 'c-opt-cpp-prefix)
                               (let ((re (c-noise-macro-with-parens-name-re)))
                                 (and re (looking-at re))))
                      (c-forward-noise-clause)
                      (skip)))
                  (if (let ((re (%c-langvar 'c-identifier-start)))
                        (and re (looking-at re)))
                      (save-excursion
                        (set! id-start (point))
                        (set! name-res (c-forward-name #t))
                        (when name-res
                          (set! id-end (point))
                          (set! id-range (*c-last-identifier-range*)))))
                  (and (cond ((let ((re (%c-langvar 'c-primitive-type-key)))
                                (and re (looking-at re)))
                              (set! res #t))
                             ((c-with-syntax-table
                                  (%c-langvar 'c-identifier-syntax-table)
                                (lambda ()
                                  (let ((re (%c-langvar 'c-known-type-key)))
                                    (and re (looking-at re)))))
                              (set! res 'known))
                             (else #f))
                       (or (not id-end)
                           (>= (save-excursion
                                 (save-match-data
                                   (goto-char (match-end 1))
                                   (set! pos (point))
                                   (c-forward-syntactic-ws)
                                   pos))
                               id-end)
                           (begin (set! res #f) res)))))
               ;; "Looking at a primitive or known type identifier.
               ;; We've checked for a name first so that we don't go
               ;; here if the known type match only is a prefix of
               ;; another name."
               (set! id-end (match-end 1))

               (when (and (%c-true (*c-record-type-identifiers*))
                          (or (%c-true (*c-promote-possible-types*))
                              (eq? res #t)))
                 (c-record-type-id (cons (match-beginning 1) (match-end 1))))

               (cond
                ((and (%c-true (%c-langvar 'c-opt-type-component-key))
                      (save-match-data
                        (let ((re (%c-langvar 'c-opt-type-component-key)))
                          (and re (looking-at re)))))
                 ;; "There might be more keywords for the type."
                 (let ((safe-pos #f))
                   (c-forward-keyword-clause 1 #t)
                   (let comps ()
                     (when (begin
                            (set! safe-pos (point))
                            (c-forward-syntactic-ws)
                            (let ((re (%c-langvar 'c-opt-type-component-key)))
                              (and re (looking-at re))))
                       (when (and (%c-true (*c-record-type-identifiers*))
                                  (let ((re (%c-langvar 'c-primitive-type-key)))
                                    (and re (looking-at re))))
                         (c-record-type-id (cons (match-beginning 1)
                                                 (match-end 1))))
                       (or (c-forward-align-clause-throw-if-invalid start type-error)
                           (c-forward-keyword-clause 1 #t))
                       (comps)))
                   (if (let ((re (%c-langvar 'c-primitive-type-key)))
                         (and re (looking-at re)))
                       (begin
                         (when (%c-true (*c-record-type-identifiers*))
                           (c-record-type-id (cons (match-beginning 1)
                                                   (match-end 1))))
                         (c-forward-keyword-clause 1 #t)
                         (set! res #t)
                         (let comps2 ()
                           (when (begin
                                  (set! safe-pos (point))
                                  (c-forward-syntactic-ws)
                                  (let ((re (%c-langvar 'c-opt-type-component-key)))
                                    (and re (looking-at re))))
                             (c-forward-keyword-clause 1 #t)
                             (comps2))))
                       (begin
                         (goto-char safe-pos)
                         (set! res 'prefix)))
                   (set! pos (point))))
                ((save-match-data (c-forward-keyword-clause 1 #t))
                 (let comps ()
                   (when (begin
                          (set! pos (point))
                          (c-forward-syntactic-ws)
                          (and (%c-true (%c-langvar 'c-opt-type-component-key))
                               (let ((re (%c-langvar 'c-opt-type-component-key)))
                                 (and re (looking-at re)))))
                     (or (c-forward-align-clause-throw-if-invalid start type-error)
                         (c-forward-keyword-clause 1 #t))
                     (comps))))
                (pos (goto-char pos))
                (else
                 (goto-char (match-end 1))
                 (set! pos (point))))
               (c-forward-syntactic-ws))

              ;; "A C specifier followed by an implicit int, e.g.
              ;; \"register count;\"."
              ((and (eq? name-res #t)
                    (eq? res 'prefix)
                    (c-major-mode-is 'c-mode)
                    (save-excursion
                      (goto-char id-end)
                      (set! pos (point))
                      (c-forward-syntactic-ws)
                      (and (not (let ((re (%c-langvar 'c-symbol-start)))
                                  (and re (looking-at re))))
                           (or (not (let ((re (%c-langvar 'c-type-decl-prefix-key)))
                                      (and re (looking-at re))))
                               (and (eq? (char-after (point)) #\()
                                    (not (save-excursion
                                           ;; `c-forward-declarator'
                                           ;; (`:10161') is not ported.
                                           (error "c-forward-type: the C implicit-int branch waits on `c-forward-declarator', which is not ported"))))))))
               (goto-char prefix-end-pos)
               (set! pos (point))
               (unless stop-at-end
                 (c-forward-syntactic-ws))
               (set! res 'no-id))

              (name-res
               (cond ((eq? name-res #t)
                      ;; "A normal identifier."
                      (goto-char id-end)
                      (set! pos (point))
                      (c-forward-syntactic-ws)
                      (if (or (%c-true res)
                              (%c-true (*c-promote-possible-types*)))
                          (begin
                            (when (not (eq? (*c-promote-possible-types*)
                                            'just-one))
                              (c-add-type id-start id-end))
                            (when (and (%c-true (*c-record-type-identifiers*))
                                       id-range)
                              (c-record-type-id id-range))
                            (unless (%c-true res)
                              (set! res 'found))
                            (when (eq? res 'prefix)
                              (set! res #t)))
                          (set! res (if (c-check-qualified-type id-start)
                                        ;; "It's an identifier that has
                                        ;; been used as a type somewhere
                                        ;; else."
                                        'found
                                        ;; "It's an identifier that might
                                        ;; be a type."
                                        'maybe))))
                     ((eq? name-res 'template)
                      ;; "A template is sometimes a type."
                      (goto-char id-end)
                      (set! pos (point))
                      (c-forward-syntactic-ws)
                      (set! res
                            (if (eq? (char-after (point)) #\()
                                (if (c-check-qualified-type id-start)
                                    'found
                                    'maybe)
                                #t)))
                     (else
                      ;; "Otherwise it's an operator identifier, which
                      ;; is not a type."
                      (goto-char start)
                      (set! res #f))))

              ;; "Deal with \"extern \"C\" foo_t my_foo;\""
              ((eq? res 'prefix)
               (set! res #f))

              (else #f))

             (when (not (memv res (list #f 'no-id)))
               ;; "Skip trailing type modifiers. If any are found we know
               ;; it's a type."
               (when (%c-true (%c-langvar 'c-opt-type-modifier-key))
                 (let mods ()
                   (when (let ((re (%c-langvar 'c-opt-type-modifier-key)))
                           (and re (looking-at re)))
                     (unless (c-forward-align-clause-throw-if-invalid start type-error)
                       (goto-char (match-end 1))
                       (set! pos (point))
                       (c-forward-syntactic-ws)
                       (set! res #t))
                     (mods))))

               ;; "Step over any type suffix operator. Do not let the
               ;; existence of these alter the classification of the
               ;; found type, since these operators typically are allowed
               ;; in normal expressions too."
               (when (%c-true (%c-langvar 'c-opt-type-suffix-key))
                 (let sufs ()
                   (when (let ((re (%c-langvar 'c-opt-type-suffix-key)))
                           (and re (looking-at re)))
                     (goto-char (match-end 1))
                     (set! pos (point))
                     (c-forward-syntactic-ws)
                     (sufs))))

               ;; "Skip any \"WS\" identifiers (e.g. \"final\" or
               ;; \"override\" in C++)"
               (let wsis ()
                 (when (let ((re (%c-langvar 'c-type-decl-suffix-ws-ids-key)))
                         (and re (looking-at re)))
                   (goto-char (match-end 1))
                   (set! pos (point))
                   (c-forward-syntactic-ws)
                   (set! res #t)
                   (wsis)))

               (when (%c-true (%c-langvar 'c-opt-type-concat-key))
                 ;; "Look for a trailing operator that concatenates the
                 ;; type with a following one, and if so step past that
                 ;; one through a recursive call. ..."
                 (set! pos (point))
                 (parameterize ((*c-promote-possible-types*
                                (or (memv res (list #t 'known))
                                    (*c-promote-possible-types*)))
                                (*c-record-found-types*
                                 (and (%c-true (*c-record-type-identifiers*))
                                      (not (%c-true (*c-promote-possible-types*))))))
                   (let ((subres #f))
                     (if (and (let ((re (%c-langvar 'c-opt-type-concat-key)))
                                (and re (looking-at re)))
                              (begin
                                (goto-char (match-end 1))
                                (c-forward-syntactic-ws)
                                (set! subres (c-forward-type #f #t))
                                (set! pos (point))
                                #t))
                         (begin
                           ;; "If either operand certainly is a type then
                           ;; both are, but we don't let the existence of
                           ;; the operator itself promote two uncertain
                           ;; types to a certain one."
                           (cond ((eq? res #t) #f)
                                 ((eq? subres #t)
                                  (unless (eq? name-res 'template)
                                    (c-add-type id-start id-end))
                                  (when (and (%c-true (*c-record-type-identifiers*))
                                             id-range)
                                    (c-record-type-id id-range))
                                  (set! res #t))
                                 ((eq? res 'known) #f)
                                 ((eq? subres 'known)
                                  (set! res 'known))
                                 ((eq? res 'found) #f)
                                 ((eq? subres 'found)
                                  (set! res 'found))
                                 (else
                                  (set! res 'maybe)))

                           (when (and (eq? res #t)
                                      (pair? (*c-record-found-types*)))
                             ;; "Cause the confirmed types to get
                             ;; fontified."
                             (let ((cur (*c-record-found-types*)))
                               (let fontify ()
                                 (when (and (pair? cur) (pair? (car cur)))
                                   ((*c-fontify-new-found-type-function*)
                                    (buffer-substring-no-properties
                                     (caar cur) (cdar cur)))
                                   (set! cur (cdr cur))
                                   (fontify))))
                             ;; "Merge in the ranges of any types found by
                             ;; the second `c-forward-type'."
                             (*c-record-type-identifiers*
                              (nconc (*c-record-found-types*)
                                     (*c-record-type-identifiers*)))))))))

               (goto-char pos)
               (unless stop-at-end
                 (c-forward-syntactic-ws))

               (when (and (%c-true (*c-record-found-types*))
                          (memv res (list 'known 'found))
                          id-range)
                 (*c-record-found-types*
                  (cons id-range (*c-record-found-types*)))))
             #f))

          res)))

    ;;------------------------------------------------------------------
    ;; `c-forward-annotation' and the compound-identifier walkers
    ;; (`cc-engine.el:9750'-`:9853')
    ;;------------------------------------------------------------------
    (define (c-forward-annotation)
      ;; "Used for Java code only at the moment. Assumes point is on the
      ;; @, moves forward an annotation and returns t. Leaves point
      ;; unmoved and returns nil if there is no annotation at point."
      (let ((pos (point)))
        (or (and (looking-at "@")
                 (not (let ((re (%c-langvar 'c-keywords-regexp)))
                        (and re (looking-at re))))
                 (begin (forward-char) #t)
                 (let ((re (%c-langvar 'c-symbol-key)))
                   (and re (looking-at re)))
                 (begin
                   (goto-char (match-end 0))
                   (c-forward-syntactic-ws)
                   #t)
                 (if (looking-at "(")
                     (c-go-list-forward)
                     #t))
            (begin (goto-char pos) #f))))

    (define (c-forward-over-compound-identifier)
      ;; "Go over a possibly compound identifier (but not any following
      ;; whitespace), such as C++'s Foo::Bar::Baz, returning that
      ;; identifier (with any syntactic WS removed). Return nil if we're
      ;; not at an identifier, in which case point is not moved."
      (if (eq? (c-on-identifier) (point))
        (let ((consolidated "") (consolidated-:: "") (here (point))
              (start #f) (end #f) (end-token #f))
          (let loop ()
            (when (begin
                    (set! start (point))
                    (c-forward-over-token)
                    (set! consolidated
                          (string-append consolidated-::
                                         (buffer-substring-no-properties
                                          start (point))))
                    (set! end-token (point))
                    (c-forward-syntactic-ws)
                    (and (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                         (let ((re (%c-langvar 'c-opt-identifier-concat-key)))
                           (and re (looking-at re)))
                         (begin
                           (set! start (point))
                           (c-forward-over-token)
                           (set! end (point))
                           (c-forward-syntactic-ws)
                           (and (c-on-identifier)
                                (begin
                                  (set! consolidated-::
                                        (string-append
                                         consolidated
                                         (buffer-substring-no-properties
                                          start end)))
                                  consolidated-::)))))
              (loop)))
          (if (equal? consolidated "")
              (begin (goto-char here) #f)
              (begin
                (goto-char end-token)
                consolidated)))
        #f))

    (define (c-back-over-compound-identifier)
      ;; "Point is putatively just after a \"compound identifier\", i.e.
      ;; something looking (in C++) like this \"FQN::of::base::Class\".
      ;; Move to the start of this construct and return t. If the
      ;; parsing fails, return nil, leaving point unchanged."
      (let ((end #f))
        (if (not (c-on-identifier))
            #f
            (begin
              (c-simple-skip-symbol-backward)
              (let loop ()
                (when (begin
                        (set! end (point))
                        (c-backward-syntactic-ws)
                        (c-backward-token-2)
                        (and (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                             (let ((re (%c-langvar 'c-opt-identifier-concat-key)))
                               (and re (looking-at re)))
                             (begin
                               (c-backward-syntactic-ws)
                               (c-simple-skip-symbol-backward))))
                  (set! end (point))
                  (loop)))
              (goto-char end)
              #t))))

    (define (c-check-qualified-type from)
      ;; "Look up successive tails of a (possibly) qualified type in
      ;; `c-found-types'. If one of them matches, return it, else return
      ;; nil."
      (save-excursion
        (goto-char from)
        (let ((compound (c-forward-over-compound-identifier)))
          (if (%c-true compound)
              (begin
                (let loop ()
                  (when (and (%c-true (%c-langvar 'c-opt-identifier-concat-key))
                             (> (string-length compound) 0)
                             (not (hash-ref (c-found-types) compound #f))
                             (string-match (%c-langvar 'c-opt-identifier-concat-key)
                                           compound))
                    (set! compound (substring compound (match-end 0)))
                    (loop)))
                (and (hash-ref (c-found-types) compound #f)
                     compound))
              #f))))

    ;;------------------------------------------------------------------
    ;; `c-back-over-member-initializer-braces' (`cc-engine.el:9855'),
    ;; `c-forward-class-decl' (`:9964'), the C++20 constraint machinery
    ;; (`:9986'-`:10078') and the declarator (`:10107'-`:10310')
    ;;------------------------------------------------------------------
    ;; `c-back-over-member-initializers' (`:9911') follows, then
    ;; `c-forward-class-decl'. `c-do-declarators' (`:10379') itself is
    ;; in the section at the end of this file, after
    ;; `c-looking-at-statement-block' it reads.

    (define (c-back-over-member-initializer-braces)
      ;; "Point is just after a closing brace/parenthesis. Try to parse
      ;; this as a C++ member initializer list, going back to just after
      ;; the introducing \":\" and returning t. Otherwise return nil,
      ;; leaving point unchanged."
      (let ((here (point)))
        (let ((res (call-with-current-continuation
                    (lambda (done)
                      (unless (c-go-list-backward) (done #f))
                      (c-backward-syntactic-ws)
                      (unless (c-back-over-compound-identifier) (done #f))
                      (c-backward-syntactic-ws)

                      (let loop ()
                        (when (eq? (char-before) #\,)
                          (backward-char)
                          (c-backward-syntactic-ws)
                          (unless (memv (char-before) (list #\) #\}))
                            (done #f))
                          (unless (c-go-list-backward) (done #f))
                          (c-backward-syntactic-ws)
                          (unless (c-back-over-compound-identifier) (done #f))
                          (c-backward-syntactic-ws)
                          (loop)))

                      (eq? (char-before) #\:)))))
          (unless res (goto-char here))
          res)))

    (define (c-back-over-member-initializers . limit-args)
      ;; "Test whether we are in a C++ member initializer list, and if
      ;; so, go back to the introducing \":\", returning the position of
      ;; the opening paren of the function's arglist. Otherwise return
      ;; nil, leaving point unchanged. LIMIT, if non-nil, is a limit for
      ;; the backward search." (`cc-engine.el:9911')
      ;;
      ;; Emacs's `c-back-over-list-of-member-inits' macro (`:9885')
      ;; expands inline here because its two `throw's unwind through the
      ;; enclosing catches; it is the local procedure below, taking the
      ;; two escape procedures.
      (let ((limit (if (pair? limit-args) (car limit-args) #f)))
        (save-restriction
          (let ((here (point))
                ;; "Do this outside the narrowing for performance
                ;; reasons."
                (paren-state (c-parse-state))
                (pos #f) (level-plausible #f) (at-top-level #f) (res #f))
            (when limit (narrow-to-region limit (point)))
            (define (back-over-list-of-member-inits limit level done)
              ;; "Go back over a list of elements, each looking like:
              ;; <symbol> (<expression>) , or <symbol> {<expression>} ,
              ;; (with possibly a <....> expressions following the
              ;; <symbol>). when we are putatively immediately after a
              ;; comma. Stop when we don't see a comma. If either of
              ;; <symbol> or bracketed <expression> is missing, throw
              ;; nil to 'level. If the terminating } or ) is unmatched,
              ;; throw nil to 'done. This is not a general purpose
              ;; macro!"
              (let loop ()
                (when (eqv? (char-before (point)) #\,)
                  (backward-char)
                  (c-backward-syntactic-ws limit)
                  (unless (memv (char-before (point)) (list #\) #\}))
                    (level #f))
                  (unless (c-go-list-backward)
                    (done #f))
                  (c-backward-syntactic-ws limit)
                  (let loop2 ()
                    (when (eqv? (char-before (point)) #\>)
                      (unless (c-backward-<>-arglist #f)
                        (done #f))
                      (c-backward-syntactic-ws limit)
                      (loop2)))
                  (unless (c-back-over-compound-identifier)
                    (level #f))
                  (c-backward-syntactic-ws limit)
                  (loop))))
            ;; "Assume tentatively that we're at the top level. Try to
            ;; go back to the colon we seek."
            (set! res
                  (call-with-current-continuation
                   (lambda (done)
                     (set! level-plausible
                           (call-with-current-continuation
                            (lambda (level)
                              (c-backward-syntactic-ws limit)
                              (when (memv (char-before (point))
                                          (list #\) #\}))
                                (unless (c-go-list-backward)
                                  (done #f))
                                (c-backward-syntactic-ws limit))
                              (when (c-back-over-compound-identifier)
                                (c-backward-syntactic-ws limit))
                              (back-over-list-of-member-inits limit level done)
                              (and (eqv? (char-before (point)) #\:)
                                   (save-excursion
                                     (c-backward-token-2)
                                     (not (looking-at
                                           (%c-langvar
                                            'c-:$-multichar-token-regexp))))
                                   (c-just-after-func-arglist-p)))))

                     (let loop ()
                       (when (and (not (and level-plausible
                                            (begin
                                              (set! at-top-level
                                                    (c-at-toplevel-p))
                                              at-top-level)))
                                  (begin
                                    (let ((pull (c-pull-open-brace
                                                 paren-state)))
                                      (set! pos (car pull))
                                      (set! paren-state (cdr pull)))
                                    pos) ; "might be a paren."
                                  (or (not limit) (>= pos limit)))
                         (set! level-plausible
                               (call-with-current-continuation
                                (lambda (level)
                                  (goto-char pos)
                                  (c-backward-syntactic-ws limit)
                                  (unless (c-back-over-compound-identifier)
                                    (level #f))
                                  (c-backward-syntactic-ws limit)
                                  (back-over-list-of-member-inits
                                   limit level done)
                                  (and (eqv? (char-before (point)) #\:)
                                       (save-excursion
                                         (c-backward-token-2 #f #f limit)
                                         (not (looking-at
                                               (%c-langvar
                                                'c-:$-multichar-token-regexp))))
                                       (c-just-after-func-arglist-p)))))
                         (loop)))

                     (and at-top-level level-plausible))))
            (or res (goto-char here))
            res))))

    (define (c-forward-class-decl)
      ;; "From the beginning of a struct/union, etc. move forward to
      ;; after the brace block which defines it, leaving point at the
      ;; start of the next token and returning point. On failure leave
      ;; point unchanged and return nil." (`cc-engine.el:9964')
      (let ((here (point))
            (class-key (%c-langvar 'c-class-key)))
        (if (and (and class-key (looking-at class-key))
                 (= (c-forward-token-2) 0)
                 (c-on-identifier)
                 (= (c-forward-token-2) 0)
                 (eq? (char-after (point)) #\{)
                 (c-go-list-forward))
            (begin
              (c-forward-syntactic-ws)
              (point))
            (begin (goto-char here) #f))))

    (define (c-forward-primary-expression . args)
      ;; "Go over the primary expression (if any) at point, and unless
      ;; STOP-AT-END is non-nil, move to the next token then return
      ;; non-nil. If we're not at a primary expression leave point
      ;; unchanged and return nil." (`cc-engine.el:9986')
      ;;
      ;; "Note that this function is incomplete, handling only those
      ;; cases expected to be common in a C++20 requires clause."
      ;;
      ;; The C's `(let ((c-restricted-<>-arglists t)
      ;; (c-parse-and-markup-<>-arglists nil)) ...)' is a `parameterize'
      ;; here, the tree's rule for a dynamically bound variable.
      (let ((limit (if (pair? args) (car args) #f))
            (stop-at-end (if (and (pair? args) (pair? (cdr args)))
                             (cadr args) #f)))
        (let ((here (point)))
          (parameterize ((*c-restricted-<>-arglists* #t)
                         (*c-parse-and-markup-<>-arglists* #f))
            (if (cond
                 ((let ((re (%c-langvar 'c-constant-key)))
                    (and re (looking-at re)))
                  (goto-char (match-end 1))
                  (unless stop-at-end (c-forward-syntactic-ws limit))
                  #t)
                 ((eq? (char-after (point)) #\()
                  (and (c-go-list-forward (point) limit)
                       (eq? (char-before) #\))
                       (begin
                         (unless stop-at-end
                           (c-forward-syntactic-ws limit))
                         #t)))
                 ((c-forward-over-compound-identifier)
                  (let ((after-id (point)))
                    (c-forward-syntactic-ws limit)
                    ;; `(while (cond ...))' - the cond's value is the
                    ;; loop's test, and its first clause answers nil
                    ;; once the arglist has been skipped, which is the
                    ;; C's own way of stopping after one such round.
                    (let loop ()
                      (when (cond
                             ((and (looking-at "<")
                                   (and (c-forward-<>-arglist #f)
                                        (begin
                                          (set! after-id (point))
                                          after-id)))
                              (c-forward-syntactic-ws limit))
                             ;; Emacs's clause is a bare `(looking-at
                             ;; c-opt-identifier-concat-key)', which signals
                             ;; in a mode whose constant is nil (C mode);
                             ;; kept bare so that callers see Emacs's answer.
                             ((looking-at (%c-langvar
                                           'c-opt-identifier-concat-key))
                              (and (zero? (c-forward-token-2 1 #f limit))
                                   (let ((id (c-forward-over-compound-identifier)))
                                     (c-forward-syntactic-ws limit)
                                     id)))
                             (else #f))
                        (loop)))
                    (goto-char after-id)))
                 ((let ((re (%c-langvar 'c-fun-name-substitute-key)))
                    (and re (looking-at re))) ; "requires"
                  (goto-char (match-end 1))
                  (c-forward-syntactic-ws limit)
                  (and
                   (or (not (eq? (char-after (point)) #\())
                       (let ((ok (and (c-go-list-forward (point) limit)
                                      (eq? (char-before) #\)))))
                         (c-forward-syntactic-ws)
                         ok))
                   (eq? (char-after (point)) #\{)
                   (and (c-go-list-forward (point) limit)
                        (eq? (char-before) #\}))
                   (begin
                     (unless stop-at-end (c-forward-syntactic-ws limit))
                     #t)))
                 (else #f))
                #t
                (begin (goto-char here) #f))))))

    (define (c-forward-constraint-clause . args)
      ;; "Point is at the putative start of a constraint clause. Move to
      ;; its end (when STOP-AT-END is non-zero) or the token after that
      ;; (otherwise) and return non-nil. Return nil without moving if we
      ;; fail to find a constraint." (`cc-engine.el:10046')
      (let ((limit (if (pair? args) (car args) #f))
            (stop-at-end (if (and (pair? args) (pair? (cdr args)))
                             (cadr args) #f)))
        (let ((here (point))
              (final-point #f))
          (set! limit (or limit (point-max)))
          (if (c-forward-primary-expression limit #t)
              (begin
                (set! final-point (point))
                (c-forward-syntactic-ws limit)
                (let loop ()
                  (when (and (looking-at "\\(?:&&\\|||\\)")
                             (<= (match-end 0) limit)
                             (begin
                               (goto-char (match-end 0))
                               (c-forward-syntactic-ws limit)
                               (<= (point) limit))
                             (c-forward-primary-expression limit #t)
                             (begin (set! final-point (point)) final-point))
                    (loop)))
                (goto-char final-point)
                (unless stop-at-end (c-forward-syntactic-ws limit))
                #t)
              (begin (goto-char here) #f)))))

    (define (c-forward-c++-requires-clause . args)
      ;; "Point is at the keyword \"requires\". Move forward over the
      ;; requires clause to its end (if STOP-AT-END is non-nil) or the
      ;; next token after it (otherwise) and return non-nil. If there is
      ;; no valid requires clause at point, leave point unmoved and
      ;; return nil." (`cc-engine.el:10072')
      (let ((limit (if (pair? args) (car args) #f))
            (stop-at-end (if (and (pair? args) (pair? (cdr args)))
                             (cadr args) #f)))
        (set! limit (or limit (point-max)))
        (and (zero? (c-forward-token-2)) ; over "requires".
             (c-forward-constraint-clause limit stop-at-end))))

    (define (c-in-id-arglist)
      ;; "If point is inside a paren delimited non-empty arglist, all of
      ;; whose arguments are identifiers, return a cons of the start and
      ;; (after) the end of the arglist. Otherwise return nil."
      ;; (`cc-engine.el:10081')
      (let* ((paren-state (c-parse-state))
             (enclosing-paren-pos (c-most-enclosing-brace paren-state)))
        (save-excursion
          (and
           enclosing-paren-pos
           (eq? (char-after enclosing-paren-pos) #\()
           (begin
             (goto-char (+ enclosing-paren-pos 1))
             (c-forward-syntactic-ws)
             (call-with-current-continuation
              (lambda (in-arglist)
                (let loop ()
                  (when (and
                         (c-on-identifier)
                         (zero? (c-forward-token-2))
                         (begin
                           (when (eq? (char-after (point)) #\))
                             (in-arglist
                              (cons enclosing-paren-pos (+ (point) 1))))
                           (eq? (char-after (point)) #\,))
                         (zero? (c-forward-token-2)))
                    (loop)))
                #f)))))))

    (define (c-forward-decl-arglist not-top id-in-parens . limit-args)
      ;; "Point is at an open parenthesis, assumed to be the arglist of a
      ;; function declaration. Move over this arglist and following
      ;; syntactic whitespace, and return non-nil. If the construct
      ;; isn't such an arglist, leave point unmoved and return nil."
      ;;
      ;; "Note that point is assumed to be at a place where an arglist is
      ;; expected. Only for C++, where there are other possibilities, is
      ;; any actual processing done. Otherwise, t is simply returned."
      ;; (`cc-engine.el:10107')
      (let ((limit (if (pair? limit-args) (car limit-args) #f)))
        (let ((here (point))
              (got-type #f))
          (if (or
               (not (c-major-mode-is 'c++-mode))
               (and
                (or (not not-top)
                    id-in-parens        ; Id is in parens, etc.
                    (save-excursion
                      (forward-char)
                      (c-forward-syntactic-ws limit)
                      (looking-at "[*&]")))
                (save-excursion
                  ;; Emacs `let'-binds `c-last-identifier-range' here;
                  ;; it is a parameter.
                  (parameterize ((*c-last-identifier-range* #f))
                    (forward-char)
                    (c-forward-syntactic-ws limit)
                    (call-with-current-continuation
                     (lambda (is-function)
                       (let loop ()
                         (when
                          (begin
                            ;; Go forward one argument at each iteration.
                            (let skip ()
                              (when (cond
                                     ((let ((re (%c-langvar 'c-decl-hangon-key)))
                                        (and re (looking-at re)))
                                      (c-forward-keyword-clause 1))
                                     ((looking-at
                                       (c-noise-macro-with-parens-name-re))
                                      (c-forward-noise-clause))
                                     (else #f))
                                (skip)))
                            (when (eq? (char-after (point)) #\))
                              (forward-char)
                              (c-forward-syntactic-ws limit)
                              (is-function #t))
                            (set! got-type (c-forward-type))
                            (cond
                             ((not (%c-true got-type))
                              (is-function #f))
                             ((not (eq? got-type 'maybe))
                              (is-function #t))
                             (else #f))
                            (c-forward-declarator limit #t #t)
                            (eq? (char-after (point)) #\,))
                           (forward-char)
                           (c-forward-syntactic-ws)
                           (loop)))
                       #t))))))
               (and (c-go-list-forward (point) limit)
                    (begin (c-forward-syntactic-ws limit) #t))
              (begin (goto-char here) #f)))))

    (define (c-forward-declarator . args)
      ;; "Assuming point is at the start of a declarator, move forward
      ;; over it, leaving point at the next token after it (e.g. a ) or a
      ;; ; or a ,), or at LIMIT (or end of buffer) if that comes first."
      ;; (`cc-engine.el:10161')
      ;;
      ;; "Return a list (ID-START ID-END BRACKETS-AFTER-ID GOT-INIT
      ;; DECORATED ARGLIST), where ID-START and ID-END are the bounds of
      ;; the declarator's identifier, BRACKETS-AFTER-ID is non-nil if a
      ;; [...] pair is present after the id, and ARGLIST is non-nil
      ;; either when an arglist has been moved over, or when we have
      ;; stopped at an unbalanced open-paren. GOT-INIT is non-nil when
      ;; the declarator is followed by \"=\" or \"(\", DECORATED is
      ;; non-nil when the identifier is embellished by an operator, like
      ;; \"*x\", or \"(*x)\"."
      ;;
      ;; "If ACCEPT-ANON is non-nil, move forward over any \"anonymous
      ;; declarator\", i.e. something like the (*) in int (*), such as
      ;; might be found in a declaration. In such a case ID-START and
      ;; ID-END in the return value are both set to nil. A \"null\"
      ;; \"anonymous declarator\" gives a non-nil result."
      ;;
      ;; "If no declarator is found, leave point unmoved and return nil.
      ;; LIMIT is an optional limit for forward searching."
      ;;
      ;; "Note that the global variable `c-last-identifier-range' is
      ;; written to, so the caller should bind it if necessary."
      (let ((limit (if (pair? args) (car args) #f))
            (accept-anon (if (and (pair? args) (pair? (cdr args)))
                             (cadr args) #f))
            (not-top (if (and (pair? args) (pair? (cdr args))
                              (pair? (cddr args)))
                         (caddr args) #f)))
        (let ((here (point))
              (id-start #f) (id-end #f) (brackets-after-id #f) (paren-depth 0)
              (decorated #f) (got-init #f) (arglist #f) (double-double-quote #f)
              (pos #f))
          (set! limit (or limit (point-max)))
          (if (and
               (< (point) limit)

               ;; "The following form moves forward over the
               ;; declarator's identifier (and what precedes it),
               ;; returning t. If there wasn't one, it returns nil."
               (let ((got-identifier #f))
                 (set! paren-depth 0)
                 ;; "Skip over type decl prefix operators, one for each
                 ;; iteration of the while."
                 (let loop ()
                   (when (cond
                          ((let ((re (%c-langvar 'c-decl-hangon-key)))
                             (and re (looking-at re)))
                           (c-forward-keyword-clause 1))
                          ((and (%c-true (%c-langvar 'c-opt-cpp-prefix))
                                (looking-at
                                 (c-noise-macro-with-parens-name-re)))
                           (c-forward-noise-clause))
                          ;; "Special handling for operator<op>."
                          ((let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                             (and re (looking-at re)))
                           (goto-char (match-end 1))
                           (c-forward-syntactic-ws limit)
                           (set! id-start (point))
                           (if (let ((re (%c-langvar
                                          'c-overloadable-operators-regexp)))
                                 (and re (looking-at re)))
                               (begin
                                 (when (and (c-major-mode-is 'c++-mode)
                                            (eq? (char-after (point)) #\")
                                            (eq? (char-after (+ (point) 1)) #\"))
                                   (set! double-double-quote #t))
                                 (goto-char (match-end 0))
                                 (set! pos (point))
                                 (c-forward-syntactic-ws limit)
                                 (set! got-identifier #t)
                                 #f)
                               #t))
                          ((and (let ((re (%c-langvar
                                           'c-type-decl-prefix-key)))
                                  (and re (looking-at re)))
                                (if (and (c-major-mode-is 'c++-mode)
                                         (match-beginning 4))
                                    ;; "If the fourth submatch matches in
                                    ;; C++ then we're looking at an
                                    ;; identifier that's a prefix only if
                                    ;; it specifies a member pointer."
                                    (begin
                                      (set! id-start (point))
                                      (if (c-forward-name #t)
                                          (begin
                                            (set! pos (point))
                                            (c-forward-syntactic-ws limit)
                                            (if (save-match-data
                                                  (looking-at "\\(::\\)"))
                                                ;; "We only check for a
                                                ;; trailing \"::\" and let
                                                ;; the \"*\" that should
                                                ;; follow be matched in the
                                                ;; next round."
                                                #t
                                                ;; "It turned out to be the
                                                ;; real identifier, so flag
                                                ;; that and stop."
                                                (begin
                                                  (set! got-identifier #t)
                                                  #f)))
                                          #f))
                                    #t))
                           (when (save-match-data
                                   (let ((re (%c-langvar
                                              'c-type-decl-operator-prefix-key)))
                                     (and re (looking-at re))))
                             (set! decorated #t))
                           (if (eq? (char-after (point)) #\()
                               (begin
                                 (set! paren-depth (+ paren-depth 1))
                                 (forward-char))
                               (goto-char (or (match-end 1)
                                              (match-end 2))))
                           (c-forward-syntactic-ws)
                           #t)
                          (else #f))
                     (loop)))

                 ;; "If we haven't passed the identifier already, do it
                 ;; now."
                 (unless got-identifier
                   (set! id-start (point)))
                 (cond
                  ((or got-identifier
                       (c-forward-name #t))
                   (set! id-end
                         (or pos
                             (point)))
                   (c-forward-syntactic-ws limit)
                   #t)
                  (accept-anon
                   (set! id-start #f)
                   (set! id-end #f)
                   #t)
                  (else #f)))

               (begin
                 (c-forward-syntactic-ws limit)
                 (when (and double-double-quote ; C++'s operator"" _tag
                            (c-on-identifier))
                   (c-forward-token-2 1 #f limit))
                 #t)

               ;; "Skip out of the parens surrounding the identifier. If
               ;; closing parens are missing, this form returns nil."
               (or (= paren-depth 0)
                   (begin
                     (let ((ok (c-safe
                                (goto-char (scan-lists (point) 1 paren-depth)))))
                       (c-forward-syntactic-ws)
                       ok)))

               ;; "Skip over any trailing bit, such as
               ;; \"__attribute__\"."
               (begin
                 (let loop ()
                   (when (cond
                          ((let ((re (%c-langvar 'c-decl-hangon-key)))
                             (and re (looking-at re)))
                           (c-forward-keyword-clause 1))
                          ((let ((re (%c-langvar 'c-type-decl-suffix-key)))
                             (and re (looking-at re)))
                           (cond
                            ((save-match-data
                               (let ((re (%c-langvar 'c-requires-clause-key)))
                                 (and re (looking-at re))))
                             (c-forward-c++-requires-clause))
                            ((eq? (char-after (point)) #\()
                             (if (c-forward-decl-arglist not-top decorated limit)
                                 (begin
                                   (set! arglist #t)
                                   (set! got-init #f)
                                   #t)
                                 (if (c-go-list-forward (point) limit)
                                     #t
                                     (begin
                                       ;; For unbalanced (.
                                       (set! arglist #t)
                                       #f))))
                            (else (c-forward-keyword-clause 1))))
                          ((and (%c-true (%c-langvar 'c-opt-cpp-prefix))
                                (looking-at
                                 (c-noise-macro-with-parens-name-re)))
                           (c-forward-noise-clause))
                          (else #f))
                     (loop)))
                 (<= (point) limit))

               ;; "Search syntactically to the end of the declarator
               ;; (\";\", \",\", a closing paren, eob etc) or to the
               ;; beginning of an initializer or function prototype
               ;; (\"=\" or \"\\s(\"). Note that square brackets are now
               ;; not also treated as initializers, since this broke when
               ;; there were also initializing brace lists."
               (or (eq? (char-after (point)) #\() ; Not an arglist.
                   (let ((found #f))
                     (let loop ()
                       (when (and (< (point) limit)
                                  (begin
                                    ;; "In the next loop, we keep searching
                                    ;; forward whilst we find \":\"s which
                                    ;; aren't single colons inside C++
                                    ;; \"for\" statements."
                                    (let inner ()
                                      (when (and
                                             (< (point) limit)
                                             (begin
                                               (set! found
                                                     (c-syntactic-re-search-forward
                                                      (if (c-major-mode-is 'objc-mode)
                                                          "\\(?:@end\\)\\|[;:,]\\|\\(=\\|[[(]\\)"
                                                          "[;:,]\\|\\(=\\|\\s(\\)")
                                                      limit 'limit #t))
                                               (set! got-init
                                                     (and found
                                                          (match-beginning 1)))
                                               found)
                                             (eq? (char-before) #\:)
                                             (not
                                              (and (c-major-mode-is
                                                    '(c++-mode java-mode))
                                                   (save-excursion
                                                     (and
                                                      (c-go-up-list-backward)
                                                      (eq? (char-after (point)) #\()
                                                      (begin
                                                        (c-backward-syntactic-ws)
                                                        (c-simple-skip-symbol-backward))
                                                      (let ((re (%c-langvar
                                                                 'c-paren-stmt-key)))
                                                        (and re (looking-at re)))))))
                                             (let ((re (%c-langvar
                                                        'c-:-op-cont-regexp)))
                                               (if (and re (looking-at re))
                                                   (begin
                                                     (goto-char (match-end 0))
                                                     #t)
                                                   ;; "Does this : introduce the
                                                   ;; class initialization list,
                                                   ;; or a bitfield?"
                                                   (not arglist))))
                                        (inner)))
                                    found)
                                  (if (eq? (char-before) #\[)
                                        (begin
                                          (set! brackets-after-id #t)
                                          ;; `(prog1 (c-go-up-list-forward)
                                          ;; (c-forward-syntactic-ws))'.
                                          (let ((up (c-go-up-list-forward)))
                                            (c-forward-syntactic-ws)
                                            up))
                                      #f))
                         (loop)))
                     (when (and found
                                (memv (char-before)
                                      (list #\; #\: #\, #\= #\( #\[ #\{)))
                       (backward-char))
                     (<= (point) limit))))
              (list id-start id-end brackets-after-id got-init decorated arglist)
              (begin (goto-char here) #f)))))

    ;;------------------------------------------------------------------
    ;; `c-do-declarators' (`cc-engine.el:10379')
    ;;------------------------------------------------------------------
    (define (c-do-declarators cdd-limit cdd-list cdd-not-top cdd-comma-prop
                              cdd-function . accept-anon-args)
      ;; "Assuming point is at the start of a comma separated list of
      ;; declarators, apply CDD-FUNCTION to each declarator (when
      ;; CDD-LIST is non-nil) or just the first declarator (when
      ;; CDD-LIST is nil). When CDD-FUNCTION is nil, no function is
      ;; applied."
      ;;
      ;; "CDD-FUNCTION is supplied with 6 arguments:
      ;; 0. The start position of the declarator's identifier;
      ;; 1. The end position of this identifier;
      ;; [Note: if there is no identifier, as in int (*);, both of these
      ;; are nil.]
      ;; 2. The position of the next token after the declarator
      ;; (CLARIFY!!!).
      ;; 3. CDD-NOT-TOP;
      ;; 4. Non-nil if the identifier is of a function.
      ;; 5. When there is an initialization following the declarator
      ;; (such as \"= ....\" or \"( ....\".), the character which
      ;; introduces this initialization, otherwise nil."
      ;;
      ;; "Additionally, if CDD-COMMA-PROP is non-nil, mark the
      ;; separating commas with this value of the c-type property, when
      ;; CDD-LIST is non-nil."
      ;;
      ;; "Stop at or before CDD-LIMIT (which may NOT be nil)."
      ;;
      ;; "If CDD-NOT-TOP is non-nil, we are not at the top-level
      ;; (\"top-level\" includes being directly inside a class or
      ;; namespace, etc.)."
      ;;
      ;; "If CDD-ACCEPT-ANON is non-nil, we also process declarators
      ;; without names, e.g. \"int (*)(int)\" in a function prototype."
      ;;
      ;; "Return non-nil if we've reached the token after the last
      ;; declarator (often a semicolon, or a comma when CDD-LIST is
      ;; nil); otherwise (when we hit CDD-LIMIT, or fail otherwise)
      ;; return nil, leaving point at the beginning of the putative
      ;; declarator that could not be processed."
      (let ((cdd-accept-anon (if (pair? accept-anon-args)
                                 (car accept-anon-args) #f)))
        ;; Emacs's `let' binds `c-last-identifier-range' to nil;
        ;; `c-forward-declarator' writes it, so the caller binds it.
        (parameterize ((*c-last-identifier-range* #f))
          (let ((cdd-pos (point)) (cdd-next-pos #f) (cdd-id-start #f)
                (cdd-id-end #f) (cdd-decl-res #f) (cdd-got-func #f)
                (cdd-got-init #f) (cdd-exhausted #f) (cdd-after-block #f))
            ;; "The following `while' applies `cdd-function' to a single
            ;; declarator id each time round. It loops only when
            ;; CDD-LIST is non-nil."
            (let loop ()
              (when (and (not cdd-exhausted)
                         (begin
                           (set! cdd-decl-res
                                 (c-forward-declarator cdd-limit
                                                       cdd-accept-anon
                                                       cdd-not-top))
                           cdd-decl-res))
                (set! cdd-next-pos (point))
                (set! cdd-id-start (car cdd-decl-res))
                (set! cdd-id-end (cadr cdd-decl-res))
                (set! cdd-got-func (cadddr (cddr cdd-decl-res)))
                (set! cdd-got-init (and (cadddr cdd-decl-res)
                                        (char-after (point))))

                ;; "Jump past any initializer or function prototype to
                ;; see if there's a ',' to continue at."
                (cond
                 (cdd-got-init
                  ;; "Skip an initializer expression in braces, whether
                  ;; or not (in C++ Mode) preceded by an \"=\". Be
                  ;; careful that the brace list isn't a code block or a
                  ;; struct (etc.) block."
                  (cond
                   ((and (eqv? cdd-got-init #\=)
                         (zero? (c-forward-token-2 1 #f cdd-limit))
                         (eqv? (char-after (point)) #\{)
                         (c-go-list-forward (point) cdd-limit)))
                   ((and (eqv? cdd-got-init #\{)
                         (%c-true (%c-langvar 'c-recognize-bare-brace-inits))
                         (begin
                           (set! cdd-after-block
                                 (save-excursion
                                   (c-go-list-forward (point) cdd-limit)))
                           cdd-after-block)
                         (not (c-looking-at-statement-block)))
                    (goto-char cdd-after-block)))
                  (if (c-syntactic-re-search-forward "[;,{]" cdd-limit
                                                     'move #t)
                      (backward-char)
                      (set! cdd-exhausted #t)))
                 (else (c-forward-syntactic-ws cdd-limit)))

                (if cdd-function
                    (save-excursion
                      (funcall cdd-function cdd-id-start cdd-id-end
                               cdd-next-pos cdd-not-top cdd-got-func
                               cdd-got-init)))

                ;; "If a ',' is found we set cdd-pos to the next
                ;; declarator and iterate."
                (if (and cdd-list (< (point) cdd-limit) (looking-at ","))
                    (begin
                      (when cdd-comma-prop
                        (c-put-char-property (point) 'c-type cdd-comma-prop))
                      (forward-char)
                      (c-forward-syntactic-ws cdd-limit)
                      (set! cdd-pos (point)))
                    (set! cdd-exhausted #t))
                (loop)))

            (if (> (point) cdd-pos)
                #t
                (begin (goto-char cdd-pos) #f))))))

    ;;------------------------------------------------------------------
    ;; `c-forward-decl-or-cast-1' (`cc-engine.el:10541')
    ;;------------------------------------------------------------------
    ;; Emacs's two private macros over the function's own variables
    ;; (`c-fdoc-shift-type-backward', `c-fdoc-assymetric-space-about-
    ;; asterisk') are procedures here, defined where the variables they
    ;; write are in scope: the inner `let' of the type-decl-expression
    ;; block is hoisted to the outer `let' (its initial values are set
    ;; at the same place) so one closure can serve every call site,
    ;; including the SHORT one after the inner block.


    (define (c-forward-decl-or-cast-1 preceding-token-end context
                                      last-cast-end . inside-macro-args)
      ;; "Move forward over a declaration or a cast if at the start of
      ;; one. The point is assumed to be at the start of some token. Nil
      ;; is returned if no declaration or cast is recognized, and the
      ;; point is clobbered in that case."
      ;;
      ;; (The long docstring's description of the answer: a declaration
      ;; answers a 5-element list (ID-START, TYPE-DECL-INFO,
      ;; MAYBE-EXPRESSION, TYPE-START, TOP); a cast answers `cast'.)
      ;;
      ;; "This function records identifier ranges on
      ;; `c-record-type-identifiers' and `c-record-ref-identifiers' if
      ;; `c-record-type-identifiers' is non-nil."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((inside-macro (if (pair? inside-macro-args)
                              (car inside-macro-args) #f)))
        (let (;; "`start-pos' is used below to point to the start of the
              ;; first type, i.e. after any leading specifiers. It might
              ;; also point at the beginning of the preceding syntactic
              ;; whitespace."
              (start-pos (point))
              ;; "Set to the result of `c-forward-type'."
              (at-type #f)
              ;; "The position of the first token in what we currently
              ;; believe is the type in the declaration or cast, after
              ;; any specifiers and their associated clauses."
              (type-start #f)
              ;; "The position of the first token in what we currently
              ;; believe is the declarator for the first identifier. Set
              ;; when the type is found, and moved forward over any
              ;; `c-decl-hangon-kwds' and their associated clauses that
              ;; occurs after the type."
              (id-start #f)
              ;; "The earlier value of `type-start' if we've shifted the
              ;; type backwards."
              (identifier-start #f)
              ;; "These store `at-type', `type-start' and `id-start' of
              ;; the identifier before the one in those variables. ..."
              (backup-at-type #f) (backup-type-start #f) (backup-id-start #f)
              ;; "Set if we've found a specifier (apart from "typedef")
              ;; that makes the defined identifier(s) types."
              (at-type-decl #f)
              ;; "If we've a "typedef" keyword (?or similar), the buffer
              ;; position of its first character."
              (at-typedef #f)
              ;; "Set if `context' is '<> and the identifier is
              ;; definitely a type, or has already been recorded as a
              ;; found type."
              (at-<>-type #f)
              ;; "Set if we've found a specifier that can start a
              ;; declaration where there's no type."
              (maybe-typeless #f)
              ;; "If a specifier is found that also can be a type
              ;; prefix, these flags are set instead of those above. ..."
              (backup-at-type-decl #f) (backup-maybe-typeless #f)
              ;; "Whether we've found a declaration or a cast. ..."
              (at-decl-or-cast #f)
              ;; "Set when we need to back up to parse this as a
              ;; declaration but not as a cast."
              (backup-if-not-cast #f)
              ;; "For casts, the return position."
              (cast-end #f)
              ;; "Have we got a new-style C++11 "auto"?"
              (new-style-auto #f)
              ;; "Set when the symbol before `preceding-token-end' is
              ;; known to terminate the previous construct, or when
              ;; we're at point-min."
              (at-decl-start #f)
              ;; "Set when we have encountered a keyword (e.g. "extern")
              ;; which causes the following declaration to be treated as
              ;; though top-level."
              (make-top #f)
              ;; "A list of found types in this declaration. ..."
              (found-type-list '())
              ;; "Save `c-record-type-identifiers' and
              ;; `c-record-ref-identifiers' since ranges are recorded
              ;; speculatively and should be thrown away if it turns out
              ;; that it isn't a declaration or cast."
              (save-rec-type-ids (*c-record-type-identifiers*))
              (save-rec-ref-ids (*c-record-ref-identifiers*))
              ;; "Set when we parse a declaration which might also be an
              ;; expression, such as "a *b". ..."
              (maybe-expression #f)
              ;; "Set for the type when `c-forward-type' returned
              ;; `maybe', and we want to fontify it as a type, but
              ;; aren't confident enough to enter it into
              ;; `c-found-types'."
              (unsafe-maybe #f)
              ;; The type-decl-expression block's own variables
              ;; (`cc-engine.el:10962'), hoisted so that
              ;; `c-fdoc-shift-type-backward' can see them; their
              ;; initial values are given where the C's `let' is.
              (start #f) (paren-depth 0) (pos #f)
              (got-prefix #f) (got-parens #f) (got-arglist #f)
              (got-stmt-block #f) (got-identifier #f) (got-number #f)
              (got-suffix #f) (got-prefix-before-parens #f)
              (got-function-name-prefix #f) (got-suffix-after-parens #f)
              (at-decl-end #f) (identifier-type #f)
              (name-start #f) (after-paren-pos #f))

          ;; "`c-fdoc-shift-type-backward'." (`cc-engine.el:10421')
          (define (c-fdoc-shift-type-backward! . short-args)
            ;; "`c-forward-decl-or-cast-1' can consume an arbitrary
            ;; length list of types when parsing a declaration, which
            ;; means that it sometimes consumes the identifier in the
            ;; declaration as a type. This is used to \"backtrack\" and
            ;; make the last type be treated as an identifier instead."
            (let ((short (and (pair? short-args) (car short-args))))
              (set! identifier-start type-start)
              (unless short
                ;; "These identifiers are bound only in the inner let."
                (set! identifier-type at-type)
                (set! got-parens #f)
                (set! got-identifier #t)
                (set! got-suffix #t)
                (set! got-suffix-after-parens id-start)
                (set! paren-depth 0))
              (set! at-type (if (eq? backup-at-type 'prefix)
                                #t
                                backup-at-type))
              (if (not (memq at-type (list #f 'no-id)))
                  (begin
                    (set! type-start backup-type-start)
                    (set! id-start backup-id-start))
                  (begin
                    (set! type-start start-pos)
                    (set! id-start start-pos)))
              ;; "When these flags already are set we've found
              ;; specifiers that unconditionally signal these
              ;; attributes - backtracking doesn't change that. So keep
              ;; them set in that case."
              (unless at-type-decl
                (set! at-type-decl backup-at-type-decl))
              (unless maybe-typeless
                (set! maybe-typeless backup-maybe-typeless))
              (unless short
                ;; "This identifier is bound only in the inner let."
                (set! start id-start))))

          ;; "`c-fdoc-assymetric-space-about-asterisk'."
          ;; (`cc-engine.el:10451') "We've got a \"*\" at `id-start'
          ;; between two identifiers, the first at `type-start'. Return
          ;; non-nil when there is either whitespace between the first
          ;; id and the \"*\" or between the \"*\" and the second id,
          ;; but not both."
          (define (c-fdoc-assymetric-space-about-asterisk?)
            (let ((space-before-id
                   (save-excursion
                     (goto-char id-start) ; "Position of \"*\"."
                     (and (> (skip-chars-forward "* \t\n\r") 0)
                          (memv (char-before (point))
                                (list #\space #\tab #\newline #\return)))))
                  (space-after-type
                   (save-excursion
                     (goto-char type-start)
                     (and (c-forward-type #f #t)
                          (or (eolp)
                              (memv (char-after (point))
                                    (list #\space #\tab)))))))
              (not (eq? (not space-before-id)
                        (not space-after-type)))))

          (save-excursion
            (goto-char preceding-token-end)
            (set! at-decl-start
                  (or (bobp)
                      (let ((tok-end (point)))
                        (c-backward-token-2)
                        (member (buffer-substring-no-properties
                                 (point) tok-end)
                                (%c-langvar 'c-pre-start-tokens))))))

          (let loop ()
            (when (c-forward-annotation)
              (c-forward-syntactic-ws)
              (loop)))

          ;; "Check for a type. Unknown symbols are treated as possible
          ;; types, but they could also be specifiers disguised through
          ;; macros like __INLINE__, so we recognize both types and
          ;; known specifiers after them too."
          (let loop ()
            (when
             (let* ((start (point)) (kwd-sym #f) (kwd-clause-end #f)
                    (found-type #f) (noise-start #f))
               (cond
                ;; "Look for a specifier keyword clause."
                ((or (and (looking-at (%c-langvar 'c-make-top-level-key))
                          (begin (set! make-top #t) #t))
                     (looking-at (%c-langvar 'c-prefix-spec-kwds-re))
                     (and (c-major-mode-is 'java-mode)
                          (looking-at "@[A-Za-z0-9]+")))
                 (save-match-data
                   (if (looking-at (%c-langvar 'c-typedef-key))
                       (set! at-typedef (point))))
                 (set! kwd-sym (c-keyword-sym (match-string 1)))
                 (save-excursion
                   (c-forward-keyword-clause 1)
                   (when (and (c-major-mode-is 'c++-mode)
                              (c-keyword-member kwd-sym 'c-<>-sexp-kwds)
                              (save-match-data
                                (looking-at (%c-langvar
                                             'c-requires-clause-key))))
                     (c-forward-c++-requires-clause))
                   (set! kwd-clause-end (point))))
                ((and (%c-langvar 'c-opt-cpp-prefix)
                      (looking-at (c-noise-macro-with-parens-name-re)))
                 (set! noise-start (point))
                 (let loop2 ()
                   (when (and (c-forward-noise-clause)
                              (looking-at
                               (c-noise-macro-with-parens-name-re)))
                     (loop2)))
                 (set! kwd-clause-end (point)))
                (else #f))

               (when (begin (set! found-type (c-forward-type #t)) found-type)
                 ;; "Found a known or possible type or a prefix of a
                 ;; known type."
                 (when (and (eq? found-type 'no-id)
                            (save-excursion
                              (and (c-forward-name) ; "over the identifier"
                                   (looking-at "[=(]"))))
                   (set! new-style-auto #t)) ; "position of foo in auto foo"

                 (when at-type
                   ;; "Got two identifiers with nothing but whitespace
                   ;; between them. That can only happen in
                   ;; declarations."
                   (set! at-decl-or-cast 'ids)

                   (when (eq? at-type 'found)
                     ;; "If the previous identifier is a found type we
                     ;; record it as a real one; it might be some sort
                     ;; of alias for a prefix like "unsigned". We
                     ;; postpone entering the new found type into
                     ;; c-found-types until we are sure of it, thus
                     ;; preventing rapid alternation of the
                     ;; fontification of the token throughout the
                     ;; buffer."
                     (set! found-type-list
                           (cons (cons type-start
                                       (buffer-substring-no-properties
                                        type-start
                                        (save-excursion
                                          (goto-char type-start)
                                          (c-end-of-token)
                                          (point))))
                                 found-type-list)))

                   ;; "Might we have a C++20 concept? i.e.
                   ;; template<foo bar>?"
                   (set! at-<>-type
                         (and (eq? context '<>)
                              (memq found-type (list #t 'known 'prefix
                                                     'found))))

                   ;; "Signal a type declaration for "struct foo {"."
                   (when (and backup-at-type-decl
                              (eqv? (char-after (point)) #\{))
                     (set! at-type-decl #t)))

                 (set! backup-at-type at-type)
                 (set! backup-type-start type-start)
                 (set! backup-id-start id-start)
                 (set! at-type found-type)
                 (set! type-start start)
                 (set! id-start (point))
                 ;; "The previous ambiguous specifier/type turned out to
                 ;; be a type since we've parsed another one after it, so
                 ;; clear these backup flags."
                 (set! backup-at-type-decl #f)
                 (set! backup-maybe-typeless #f))

               ;; The C's `if' has the `and' as its ELSE arm, so a
               ;; round that found a keyword answers this branch's
               ;; value - truthy when it moved - and the `and' is
               ;; reached only when no keyword matched.
               (if (or kwd-sym noise-start)
                   (if (or (c-keyword-member kwd-sym 'c-decl-hangon-kwds)
                           noise-start)
                       ;; "It's a hang-on keyword or noise clause that
                       ;; can occur anywhere."
                       (begin
                         (if at-type
                             ;; "Move the identifier start position if
                             ;; we've passed a type."
                             (set! id-start kwd-clause-end)
                             ;; "Otherwise treat this as a specifier
                             ;; and move the fallback position."
                             (set! start-pos kwd-clause-end))
                         (goto-char kwd-clause-end))
                       ;; "It's an ordinary specifier so we know that
                       ;; anything before this can't be the type."
                       (begin
                         (set! backup-at-type #f)
                         (set! start-pos kwd-clause-end)
                         (if found-type
                             ;; "It's ambiguous whether this keyword is
                             ;; a specifier or a type prefix, so set the
                             ;; backup flags. (It's assumed that
                             ;; `c-forward-type' moved further than
                             ;; `c-forward-keyword-clause'.)"
                             ;; The C's `progn' of two `when's answers
                             ;; the last one's value.
                             (let ((a (if (c-keyword-member
                                           kwd-sym 'c-typedef-decl-kwds)
                                          (begin
                                            (set! backup-at-type-decl #t)
                                            #t)
                                          #f)))
                               (if (c-keyword-member
                                    kwd-sym 'c-typeless-decl-kwds)
                                   (begin
                                     (set! backup-maybe-typeless #t)
                                     #t)
                                   a))
                             (begin
                               (when (c-keyword-member
                                      kwd-sym 'c-typedef-decl-kwds)
                                 ;; "This test only happens after we've
                                 ;; scanned a type. So, with valid
                                 ;; syntax, kwd-sym can't be 'typedef."
                                 (set! at-type-decl #t))
                               (when (c-keyword-member
                                      kwd-sym 'c-typeless-decl-kwds)
                                 (set! maybe-typeless #t))
                               ;; "Haven't matched a type so it's an
                               ;; unambiguous specifier keyword and we
                               ;; know we're in a declaration."
                               (set! at-decl-or-cast #t)
                               (goto-char kwd-clause-end)))))
                   ;; "If the type isn't known we continue so that
                   ;; we'll jump over all specifiers and type
                   ;; identifiers. The reason to do this for a known
                   ;; type prefix is to make things like "unsigned
                   ;; INT16" work."
                   (and found-type (not (memq found-type (list #t 'no-id))))))

             (loop)))

          (cond
           ((eq? at-type #t)
            ;; "If a known type was found, we still need to skip over
            ;; any hangon keyword clauses after it. Otherwise it has
            ;; already been done in the loop above."
            (let loop ()
              (when (cond
                     ((looking-at (%c-langvar 'c-decl-hangon-key))
                      (c-forward-keyword-clause 1))
                     ((and (%c-langvar 'c-opt-cpp-prefix)
                           (looking-at
                            (c-noise-macro-with-parens-name-re)))
                      (c-forward-noise-clause))
                     (else #f))
                (loop)))
            (set! id-start (point)))

           ((eq? at-type 'prefix)
            ;; "A prefix type is itself a primitive type when it's not
            ;; followed by another type."
            (set! at-type #t))

           ((eq? at-type 'no-id)
            ;; "For an auto type, we assume we definitely have a type
            ;; construct."
            (set! at-type #t))

           ((not at-type)
            ;; "Got no type but set things up to continue anyway to
            ;; handle the various cases when a declaration doesn't start
            ;; with a type."
            (set! id-start start-pos))

           ((and (eq? at-type 'maybe) (c-major-mode-is 'c++-mode))
            ;; "If it's C++ then check if the last \"type\" ends on the
            ;; form \"foo::foo\" or \"foo::~foo\", i.e. if it's the name
            ;; of a (con|de)structor."
            (save-excursion
              (let ((name #f) (end-2 #f) (end-1 #f))
                (goto-char id-start)
                (c-backward-syntactic-ws)
                (set! end-2 (point))
                (when (and
                       (c-simple-skip-symbol-backward)
                       (begin
                         (set! name
                               (buffer-substring-no-properties
                                (point) end-2))
                         ;; "Cheating in the handling of syntactic ws
                         ;; below."
                         (< (skip-chars-backward ":~ \t\n\r\v\f") 0))
                       (begin
                         (set! end-1 (point))
                         (c-simple-skip-symbol-backward)
                         #t)
                       (>= (point) type-start)
                       (equal? (buffer-substring-no-properties
                                (point) end-1)
                               name)
                       (goto-char end-2)
                       (begin
                         (c-forward-syntactic-ws)
                         (eqv? (char-after (point)) #\()))
                  ;; "It is a (con|de)structor name. In that case the
                  ;; declaration is typeless so zap out any preceding
                  ;; identifier(s) that we might have taken as types."
                  (goto-char type-start)
                  (set! at-type #f)
                  (set! backup-at-type #f)
                  (set! id-start type-start))))))

          ;; "Check for and step over a type decl expression after the
          ;; thing that is or might be a type. This can't be skipped
          ;; since we need the correct end position of the declarator
          ;; for `max-type-decl-end-*'."
          (set! start (point))
          (set! paren-depth 0)
          (set! pos #f)
          (set! got-prefix #f)
          (set! got-parens #f)
          (set! got-arglist #f)
          (set! got-stmt-block #f)
          (set! got-identifier #f)
          (set! got-number #f)
          (set! got-suffix #f)
          (set! got-prefix-before-parens #f)
          (set! got-function-name-prefix #f)
          (set! got-suffix-after-parens #f)
          (set! at-decl-end #f)
          (set! identifier-type #f)
          (set! name-start #f)
          (set! after-paren-pos #f)
          ;; "If `c-parse-and-markup-<>-arglists' is set we need to turn
          ;; it off during the name skipping below to avoid getting
          ;; `c-type' properties that might be bogus. ..."
          (parameterize ((*c-parse-and-markup-<>-arglists* #f))
            (goto-char id-start)

            ;; "Skip over type decl prefix operators. (Note similar code
            ;; in `c-forward-declarator'.)"
            (if (and (%c-true (%c-langvar 'c-recognize-typeless-decls))
                     (equal? (%c-langvar 'c-type-decl-prefix-key)
                             regexp-unmatchable))
                (when (eqv? (char-after (point)) #\()
                  (set! paren-depth (+ paren-depth 1))
                  (forward-char)
                  (set! after-paren-pos (point)))
                (let loop ()
                  (when (and
                         (looking-at (%c-langvar 'c-type-decl-prefix-key))
                         (if (and (c-major-mode-is 'c++-mode)
                                  (match-beginning 4))
                             ;; "If the fourth submatch matches in C++
                             ;; then we're looking at an identifier
                             ;; that's a prefix only if it specifies a
                             ;; member pointer."
                             (when (begin
                                     (set! pos (point))
                                     (set! got-identifier
                                           (c-forward-name)))
                               (set! name-start pos)
                               (if (save-match-data (looking-at "\\(::\\)"))
                                   ;; "We only check for a trailing \"::\"
                                   ;; and let the \"*\" that should follow
                                   ;; be matched in the next round."
                                   (begin (set! got-identifier #f) #t)
                                   ;; "It turned out to be the real
                                   ;; identifier, so stop."
                                   (begin
                                     (save-excursion
                                       (c-backward-syntactic-ws)
                                       (c-simple-skip-symbol-backward)
                                       (set! identifier-start (point)))
                                     #f)))
                             #t))
                    (if (eqv? (char-after (point)) #\()
                        (begin
                          (set! paren-depth (+ paren-depth 1))
                          (forward-char)
                          (set! after-paren-pos (point)))
                        (begin
                          (unless got-prefix-before-parens
                            (set! got-prefix-before-parens
                                  (zero? paren-depth)))
                          (set! got-prefix #t)
                          (when (save-match-data
                                  (looking-at (%c-langvar
                                               'c-type-decl-operator-prefix-key)))
                            (set! got-function-name-prefix #t))
                          (goto-char (or (match-end 1) (match-end 2)))))
                    (c-forward-syntactic-ws)
                    (loop))))

            (set! got-parens (> paren-depth 0))

            ;; "Try to skip over an identifier."
            (or got-identifier
                (and (looking-at (%c-langvar 'c-identifier-start))
                     (begin (set! pos (point)) #t)
                     (begin (set! got-identifier (c-forward-name #t))
                            got-identifier)
                     (save-excursion
                       (c-simple-skip-symbol-backward)
                       (set! identifier-start (point)))
                     (begin (c-forward-syntactic-ws) #t)
                     (begin (set! name-start pos) #t))
                (if (looking-at "[0-9]")
                    (begin (set! got-number #t) #t)
                    #f)
                (and maybe-typeless
                     (or (eq? at-type 'maybe)
                         ;; Emacs's `when' answers nil when AT-TYPE is
                         ;; not `found'; a Scheme `when' answers the
                         ;; unspecified value, which is true, and that
                         ;; made this branch fire for every type.
                         (if (eq? at-type 'found)
                             (begin
                               ;; "Remove the ostensible type from the
                               ;; found types list."
                               (when type-start
                                 (let ((discard-t (assq type-start
                                                        found-type-list)))
                                   (when discard-t
                                     (set! found-type-list
                                           (remq discard-t found-type-list)))))
                               #t)
                             #f))
                     ;; "The token which we assumed to be a type is
                     ;; actually the identifier, and we have no explicit
                     ;; type."
                     (begin
                       (set! at-type #f)
                       (set! name-start type-start)
                       (set! id-start type-start)
                       (set! got-identifier #t)
                       (set! identifier-start type-start)
                       #t)))

            ;; "Skip over type decl suffix operators and trailing noise
            ;; macros."
            (let loop ()
              (when (cond
                     ((and (%c-langvar 'c-opt-cpp-prefix)
                           (looking-at
                            (c-noise-macro-with-parens-name-re)))
                      (c-forward-noise-clause))

                     ((and (looking-at (%c-langvar 'c-type-decl-suffix-key))
                           ;; "We avoid recognizing foo(bar) or foo() at
                           ;; top level as a construct here in C, since
                           ;; we want to recognize this as a typeless
                           ;; function declaration."
                           (not (and (c-major-mode-is 'c-mode)
                                     (not got-prefix)
                                     (or (eq? context 'top) make-top)
                                     (eqv? (char-after (point)) #\))
                                     after-paren-pos
                                     (or (memq at-type (list #f 'maybe))
                                         (not got-identifier)
                                         (save-excursion
                                           (goto-char after-paren-pos)
                                           (c-forward-syntactic-ws)
                                           ;; "Prevent the symbol being
                                           ;; recorded as a type."
                                           (parameterize
                                               ((*c-record-type-identifiers*
                                                 #f))
                                             (not (memq (c-forward-type)
                                                        (list #f
                                                              'maybe)))))))))
                      (if (eqv? (char-after (point)) #\))
                          (if (> paren-depth 0)
                              (begin
                                (set! paren-depth (- paren-depth 1))
                                (forward-char)
                                (when (and (not got-parens)
                                           (zero? paren-depth))
                                  (set! got-arglist #t))
                                #t)
                              #f)
                          (if (cond
                                 ((and (eqv? (char-after (point)) #\()
                                       (c-safe (c-forward-sexp 1) #t))
                                  (when (eqv? (char-before (point)) #\))
                                    (set! got-arglist #t)))
                                 ((save-match-data (looking-at "\\s("))
                                  (c-safe (c-forward-sexp 1) #t))
                                 ((save-match-data
                                   (looking-at (%c-langvar
                                                'c-requires-clause-key)))
                                  (c-forward-c++-requires-clause))
                                 (else (goto-char (match-end 1)) #t))
                              (begin
                                (when (and (not got-suffix-after-parens)
                                           (zero? paren-depth))
                                  (set! got-suffix-after-parens
                                        (match-beginning 0)))
                                (set! got-suffix #t)
                                #t)
                            #f)))

                     ((and got-arglist (eqv? (char-after (point)) #\{))
                      (set! got-stmt-block #t)
                      #f)

                     (else
                      ;; "No suffix matched. We might have matched the
                      ;; identifier as a type and the open paren of a
                      ;; function arglist as a type decl prefix. In that
                      ;; case we should \"backtrack\": Reinterpret the
                      ;; last type as the identifier, move out of the
                      ;; arglist and continue searching for suffix
                      ;; operators."
                      ;;
                      ;; "Do this even if there's no preceding type, to
                      ;; cope with old style function declarations in
                      ;; K&R C, (con|de)structors in C++ and
                      ;; `c-typeless-decl-kwds' style declarations. That
                      ;; isn't applicable in an arglist context, though."
                      ;;
                      ;; The C's `when' answers nil when its test fails,
                      ;; which is what the loop reads.
                      (if (and (> paren-depth 0) ; "ensures `after-paren-pos' is non-nil"
                               (not got-prefix-before-parens)
                               (not (eq? at-type #t))
                               (or backup-at-type
                                   maybe-typeless
                                   backup-maybe-typeless
                                   (when (%c-true (%c-langvar
                                                   'c-recognize-typeless-decls))
                                     (and (memq context (list #f 'top))
                                          ;; "Deal with C++11's
                                          ;; copy-initialization where we
                                          ;; have <type>(<constant>), by
                                          ;; contrasting with a typeless
                                          ;; <name>(<type><parameter>,
                                          ;; ...)."
                                          (save-excursion
                                            (goto-char after-paren-pos)
                                            (c-forward-syntactic-ws)
                                            (begin
                                              (let cleanup ()
                                                (when (cond
                                                       ((and (%c-langvar
                                                              'c-opt-cpp-prefix)
                                                             (looking-at
                                                              (c-noise-macro-with-parens-name-re)))
                                                        (c-forward-noise-clause))
                                                       ((looking-at
                                                         (%c-langvar
                                                          'c-decl-hangon-key))
                                                        (c-forward-keyword-clause 1))
                                                       (else #f))
                                                  (cleanup)))
                                              #t)
                                            (or (c-forward-type)
                                                ;; "Recognize a top-level
                                                ;; typeless function
                                                ;; declaration in C."
                                                (and (c-major-mode-is 'c-mode)
                                                     (or (eq? context 'top)
                                                         make-top)
                                                     (eqv? (char-after (point))
                                                           #\))))))))
                               (let ((pd paren-depth))
                                 (set! pos (point))
                                 (call-with-current-continuation
                                  (lambda (throw-pd)
                                    (let pd-loop ()
                                      (when (> pd 0)
                                        (set! pos (c-up-list-forward pos))
                                        (when (or (not pos)
                                                  (not (eqv? (char-before pos)
                                                             #\))))
                                          (throw-pd #f))
                                        (goto-char pos)
                                        (set! pd (- pd 1))
                                        (pd-loop)))
                                    #t))))
                          (begin
                            (c-fdoc-shift-type-backward!)
                            (when (and (not got-parens)
                                       (zero? paren-depth))
                              (set! got-arglist #t))
                            #t)
                          #f)))
                (c-forward-syntactic-ws)
                (loop)))

            (when (and (not got-identifier)
                       (or backup-at-type
                           (not (memq context (list 'arglist 'decl))))
                       (or (and new-style-auto
                                (looking-at (%c-langvar 'c-auto-ops-re)))
                           (and (not got-prefix)
                                at-type
                                (or maybe-typeless
                                    backup-maybe-typeless
                                    ;; "Do we have a (typeless) constructor?"
                                    (and got-stmt-block
                                         (save-excursion
                                           (goto-char type-start)
                                           (and (looking-at
                                                 (%c-langvar
                                                  'c-identifier-key))
                                                (c-directly-in-class-called-p
                                                 (match-string 0)))))))))
              ;; "Have found no identifier but `c-typeless-decl-kwds' has
              ;; matched so we know we're inside a declaration. The
              ;; preceding type must be the identifier instead."
              (c-fdoc-shift-type-backward!))

            ;; "Prepare the "-> type;" for fontification later on."
            (when (and new-style-auto
                       (looking-at (%c-langvar 'c-haskell-op-re)))
              (save-excursion
                (goto-char (match-end 0))
                (c-forward-syntactic-ws)
                (set! type-start (point))
                (set! at-type (c-forward-type #f #t))))

            ;; "Move forward over any "WS" ids (like "final" or
            ;; "override" in C++)"
            (let loop ()
              (when (looking-at (%c-langvar 'c-type-decl-suffix-ws-ids-key))
                (goto-char (match-end 1))
                (c-forward-syntactic-ws)
                (loop)))

            (set! at-decl-or-cast
                  (call-with-current-continuation
                   (lambda (throw-at-decl-or-cast)

                     ;; CASE 1
                     (when (> paren-depth 0)
                       ;; "Encountered something inside parens that
                       ;; isn't matched by the `c-type-decl-*' regexps,
                       ;; so it's not a type decl expression. Try to
                       ;; skip out to the same paren depth to not
                       ;; confuse the cast check below. If we don't
                       ;; manage this and `at-decl-or-cast' is 'ids we
                       ;; might have an expression like "foo bar ({ ..."
                       ;; which is a valid C++11 initialization."
                       (if (and (not (c-safe (goto-char (scan-lists
                                                        (point) 1
                                                        paren-depth))))
                                (eq? at-decl-or-cast 'ids))
                           (c-fdoc-shift-type-backward!))
                       ;; "If we've found a specifier keyword then it's
                       ;; a declaration regardless."
                       (throw-at-decl-or-cast
                        (memq at-decl-or-cast (list #t 'ids))))

                     (set! at-decl-end
                           (looking-at (cond ((eq? context '<>) "[,>]")
                                             ((not (memq context (list #f 'top)))
                                              "[,)]")
                                             (else "[,;]"))))

                     ;; "Now we've collected info about various
                     ;; characteristics of the construct we're looking
                     ;; at. Below follows a decision tree based on that.
                     ;; It's ordered to check more certain signs before
                     ;; less certain ones."
                     (if got-identifier
                         (begin
                           ;; CASE 2
                           (when (and (or at-type maybe-typeless)
                                      (not (or got-prefix got-parens)))
                             ;; "Got another identifier directly after
                             ;; the type, so it's a declaration."
                             (when (and got-arglist (eq? at-type 'maybe))
                               (set! unsafe-maybe #t))
                             (throw-at-decl-or-cast #t))

                           (when (and got-parens
                                      (or (not got-function-name-prefix)
                                          (and (not got-suffix-after-parens)
                                               at-decl-end))
                                      (or backup-at-type
                                          maybe-typeless
                                          backup-maybe-typeless
                                          (eq? at-decl-or-cast #t)
                                          ;; "Check whether we have
                                          ;; \"bar (gnu);\" where we are
                                          ;; directly inside a class
                                          ;; (etc.) called \"bar\"."
                                          (save-excursion
                                            (and type-start
                                                 (begin
                                                   (goto-char name-start)
                                                   (not (memq (c-forward-type)
                                                              (list #f
                                                                    'maybe))))
                                                 (begin
                                                   (goto-char id-start)
                                                   (c-directly-in-class-called-p
                                                    (buffer-substring
                                                     type-start
                                                     (begin
                                                       (goto-char type-start)
                                                       (c-forward-type #f #t)
                                                       (point)))))))))
                             ;; "Got a declaration of the form "foo bar
                             ;; (gnu);" or "bar (gnu);" ... In this case
                             ;; it's however more likely that "bar" is
                             ;; the declarator and "gnu" a function
                             ;; argument or initializer (if
                             ;; `c-recognize-paren-inits' is set), since
                             ;; the parens around "gnu" would be
                             ;; superfluous if it's a declarator. Shift
                             ;; the type one step backward."
                             (c-fdoc-shift-type-backward!)))
                         ;; "Found no identifier."
                         (begin
                           (if backup-at-type
                               (begin
                                 ;; CASE 3
                                 (when (= (point) start)
                                   ;; "Got a plain list of identifiers. If
                                   ;; a colon follows it's a valid label,
                                   ;; or maybe a bitfield. Otherwise the
                                   ;; last one probably is the declared
                                   ;; identifier and we should back up to
                                   ;; the previous type, providing it
                                   ;; isn't a cast."
                                   (if (and (eqv? (char-after (point)) #\:)
                                            (not (c-major-mode-is
                                                  'java-mode)))
                                       (cond
                                        ;; "If we've found a specifier
                                        ;; keyword then it's a declaration
                                        ;; regardless."
                                        ((eq? at-decl-or-cast #t)
                                         (throw-at-decl-or-cast #t))
                                        ((and (%c-true
                                               (%c-langvar 'c-has-bitfields))
                                              ;; "Check for a bitfield."
                                              (eq? at-decl-or-cast 'ids)
                                              (save-excursion
                                                (forward-char) ; "Over the :"
                                                (c-forward-syntactic-ws)
                                                (and (looking-at "[[:alnum:]]")
                                                     (begin
                                                       (c-forward-token-2)
                                                       (c-forward-syntactic-ws)
                                                       (memv (char-after (point))
                                                             (list #\; #\,))))))
                                         (set! backup-if-not-cast #t)
                                         (throw-at-decl-or-cast #t))
                                        (else #f))
                                       ;; "If we're in declaration or
                                       ;; template delimiters, or one of a
                                       ;; certain set of characters
                                       ;; follows, we've got a type and
                                       ;; variable."
                                       (if (or (memq context (list 'decl '<>))
                                               (memv (char-after (point))
                                                     (list #\; #\, #\= #\(
                                                           #\{ #\:)))
                                           (begin
                                             (set! backup-if-not-cast #t)
                                             (throw-at-decl-or-cast #t))
                                           ;; "We're probably just typing a
                                           ;; statement."
                                           (throw-at-decl-or-cast #f))))
                                 ;; CASE 4
                                 (when (and got-suffix
                                            (not got-prefix)
                                            (not got-parens))
                                   ;; "Got a plain list of identifiers
                                   ;; followed by some suffix. If this
                                   ;; isn't a cast then the last
                                   ;; identifier probably is the declared
                                   ;; one and we should back up to the
                                   ;; previous type."
                                   (set! backup-if-not-cast #t)
                                   (throw-at-decl-or-cast #t)))
                               (begin
                                 ;; CASE 5
                                 (when (eq? at-type #t)
                                   ;; "If the type is known we know that
                                   ;; there can't be any identifier
                                   ;; somewhere else, and it's only in
                                   ;; declarations in e.g. function
                                   ;; prototypes and in casts that the
                                   ;; identifier may be left out."
                                   (throw-at-decl-or-cast #t))
                                 (when (= (point) start)
                                   ;; "Only got a single identifier
                                   ;; (parsed as a type so far)."
                                   ;; CASE 6
                                   (if (and
                                        ;; "Check that the identifier
                                        ;; isn't at the start of an
                                        ;; expression."
                                        at-decl-end
                                        (cond
                                         ((eq? context 'decl)
                                          ;; "Inside an arglist that
                                          ;; contains declarations. ..."
                                          (or (and (not (%c-true
                                                         (%c-langvar
                                                          'c-recognize-knr-p)))
                                                   (not (%c-true
                                                         (%c-langvar
                                                          'c-recognize-paren-inits))))
                                              (memq at-type (list 'known 'found))
                                              (and (%c-true
                                                    (%c-langvar
                                                     'c-recognize-nameless-type-decls))
                                                   (eq? at-type 'maybe))))
                                         ((eq? context '<>)
                                          ;; "Inside a template arglist.
                                          ;; Accept known and found types;
                                          ;; other identifiers could just
                                          ;; as well be constants in C++."
                                          (memq at-type (list 'known 'found)))
                                         (else #f)))
                                       (begin
                                         ;; "The user may be part way
                                         ;; through typing a statement
                                         ;; beginning with an identifier.
                                         ;; This makes a 'maybe type in the
                                         ;; following "declarator"'s
                                         ;; arglist suspect."
                                         (when (eq? at-type 'maybe)
                                           (set! unsafe-maybe #t))
                                         (throw-at-decl-or-cast #t))
                                       ;; CASE 7
                                       ;; "Can't be a valid declaration or
                                       ;; cast, but if we've found a
                                       ;; specifier it can't be anything
                                       ;; else either, so treat it as an
                                       ;; invalid/unfinished declaration
                                       ;; or cast."
                                       (throw-at-decl-or-cast
                                        at-decl-or-cast)))))
                           ;; CASE 8/CASE 9.
                           (if (and got-parens
                                    (not got-prefix)
                                    (memq context (list #f 'top))
                                    (not (eq? at-type #t))
                                    (or backup-at-type
                                        maybe-typeless
                                        backup-maybe-typeless
                                        (when (%c-true
                                               (%c-langvar
                                                'c-recognize-typeless-decls))
                                          (or (not got-suffix)
                                              (looking-at
                                               (%c-langvar
                                                'c-after-suffixed-type-maybe-decl-key))))))
                               ;; "Got an empty paren pair and a preceding
                               ;; type that probably really is the
                               ;; identifier. Shift the type backwards
                               ;; to make the last one the identifier.
                               ;; This is analogous to the
                               ;; \"backtracking\" done inside the
                               ;; `c-type-decl-suffix-key' loop above."
                               (c-fdoc-shift-type-backward!)
                               (begin
                                 ;; "Still no identifier."
                                 ;; CASE 8
                                 (when (and got-prefix
                                            (or got-parens got-suffix))
                                   ;; "Require `got-prefix' together with
                                   ;; either `got-parens' or `got-suffix'
                                   ;; to recognize it as an abstract
                                   ;; declarator: ..."
                                   (throw-at-decl-or-cast #t))
                                 ;; CASE 9
                                 (when (and at-type
                                            (not got-prefix)
                                            (not got-parens)
                                            got-suffix-after-parens
                                            (eqv? (char-after
                                                   got-suffix-after-parens)
                                                  #\())
                                   ;; "Got a type, no declarator but a paren
                                   ;; suffix. I.e. it's a normal function
                                   ;; call after all (or perhaps a C++
                                   ;; style object instantiation
                                   ;; expression)."
                                   (throw-at-decl-or-cast #f))))))

                     ;; CASE 9.5
                     (when (and (not context) ; "i.e. not at top level."
                                (c-major-mode-is 'c++-mode)
                                (eq? at-decl-or-cast 'ids)
                                after-paren-pos)
                       ;; "We've got something like "foo bar (...)" in
                       ;; C++ which isn't at the top level. This is
                       ;; probably a uniform initialization of bar to the
                       ;; contents of the parens. In this case the
                       ;; declarator ends at the open paren."
                       (goto-char (- after-paren-pos 1))
                       (throw-at-decl-or-cast #t))

                     ;; CASE 10
                     (when at-decl-or-cast
                       ;; "By now we've located the type in the
                       ;; declaration that we think we're in. Do we have
                       ;; enough evidence to promote the putative type to
                       ;; a found type? The user may be halfway through
                       ;; typing a statement beginning with an
                       ;; identifier."
                       (when (and (eq? at-type 'maybe)
                                  (not (eq? context 'top)))
                         (set! unsafe-maybe #t))
                       (throw-at-decl-or-cast #t))

                     ;; CASE 11
                     (when (and got-identifier
                                (looking-at
                                 (%c-langvar 'c-after-suffixed-type-decl-key))
                                (or (eq? context 'top)
                                    make-top
                                    (and (not context)
                                         (match-beginning 1)))
                                (if (and got-parens
                                         (not got-prefix)
                                         (not got-suffix)
                                         (not (eq? at-type #t)))
                                    ;; "Shift the type backward in the
                                    ;; case that there's a single
                                    ;; identifier inside parens. That can
                                    ;; only occur in K&R style function
                                    ;; declarations so it's more likely
                                    ;; that it really is a function call.
                                    ;; Therefore we only do this after
                                    ;; `c-after-suffixed-type-decl-key'
                                    ;; has matched."
                                    (begin
                                      (c-fdoc-shift-type-backward!)
                                      #t)
                                    got-suffix-after-parens))
                       ;; "A declaration according to
                       ;; `c-after-suffixed-type-decl-key'."
                       (throw-at-decl-or-cast #t))

                     ;; CASE 12
                     (when (and (or got-prefix (not got-parens))
                                (memq at-type (list #t 'known)))
                       ;; "It's a declaration if a known type precedes
                       ;; it and it can't be a function call."
                       (throw-at-decl-or-cast #t))

                     ;; (CASE 13 is commented out in the C.)
                     ;;
                     ;; "Below are tests that only should be applied
                     ;; when we're certain to not have parsed halfway
                     ;; through an expression."

                     ;; CASE 14
                     (when (memq at-type (list #t 'known))
                       ;; "The expression starts with a known type so
                       ;; treat it as a declaration."
                       (throw-at-decl-or-cast #t))

                     ;; CASE 15
                     (when (and (c-major-mode-is 'c++-mode)
                                ;; "In C++ we check if the identifier is a
                                ;; known type, since (con|de)structors use
                                ;; the class name as identifier. We've
                                ;; always shifted over the identifier as a
                                ;; type and then backed up again in this
                                ;; case."
                                identifier-type
                                (or (memq identifier-type '(found known))
                                    (and (eqv? (char-after identifier-start)
                                               #\~)
                                         ;; "`at-type' probably won't be
                                         ;; 'found for destructors since the
                                         ;; "~" is then part of the type
                                         ;; name being checked against the
                                         ;; list of known types, so do a
                                         ;; check without that operator."
                                         (or (save-excursion
                                               (goto-char
                                                (+ identifier-start 1))
                                               (c-forward-syntactic-ws)
                                               (c-with-syntax-table
                                                (%c-langvar
                                                 'c-identifier-syntax-table)
                                                (lambda ()
                                                  (let ((re (%c-langvar
                                                             'c-known-type-key)))
                                                    (and re (looking-at re))))))
                                             (save-excursion
                                               (goto-char
                                                (+ identifier-start 1))
                                               ;; "We have already parsed
                                               ;; the type earlier, so it'd
                                               ;; be possible to cache the
                                               ;; end position instead of
                                               ;; redoing it here, but then
                                               ;; we'd need to keep track of
                                               ;; another position
                                               ;; everywhere."
                                               (c-check-type
                                                (point)
                                                (begin
                                                  (c-forward-type)
                                                  (point))))))))
                       (throw-at-decl-or-cast #t))

                     (if got-identifier
                         (begin
                           ;; CASE 16
                           (when (and got-prefix-before-parens
                                      at-type
                                      (memq context (list #f 'top))
                                      (or (not got-suffix)
                                          at-decl-start))
                             ;; "Got something like "foo * bar;". Since
                             ;; we're not inside an arglist it would be a
                             ;; meaningless expression because the result
                             ;; isn't used. We therefore choose to
                             ;; recognize it as a declaration when
                             ;; there's "symmetrical WS" around the "*"
                             ;; or the flag `c-asymmetry-fontification-flag'
                             ;; is not set. We only allow a suffix (which
                             ;; makes the construct look like a function
                             ;; call) when `at-decl-start' provides
                             ;; additional evidence that we do have a
                             ;; declaration."
                             (set! maybe-expression #t)
                             (when (or (not (%c-true
                                             (%c-langvar
                                              'c-asymmetry-fontification-flag)))
                                       (looking-at "=\\([^=]\\|$\\)\\|;")
                                       (c-fdoc-assymetric-space-about-asterisk?))
                               (when (eq? at-type 'maybe)
                                 (set! unsafe-maybe #t))
                               (throw-at-decl-or-cast #t)))

                           ;; CASE 17
                           (when (and (or got-suffix-after-parens
                                          (looking-at "=[^=]"))
                                      (eq? at-type 'found)
                                      (not (eq? context 'arglist)))
                             ;; "Got something like "a (*b) (c);" or "a
                             ;; (b) = c;". It could be an odd expression
                             ;; or it could be a declaration. Treat it
                             ;; as a declaration if "a" has been used as
                             ;; a type somewhere else (if it's a known
                             ;; type we won't get here)."
                             (set! maybe-expression #t)
                             (throw-at-decl-or-cast #t))

                           ;; CASE 17.5
                           (when (and (%c-true
                                       (%c-langvar
                                        'c-asymmetry-fontification-flag))
                                      got-prefix-before-parens
                                      at-type
                                      (or (not got-suffix)
                                          at-decl-start)
                                      (c-fdoc-assymetric-space-about-asterisk?))
                             (when (eq? at-type 'maybe)
                               (set! unsafe-maybe #t))
                             (set! maybe-expression #t)
                             (throw-at-decl-or-cast #t)))
                         ;; CASE 18
                         (when (and at-decl-end
                                    (not (memq context (list #f 'top)))
                                    (or (and got-prefix (not got-number))
                                        (and (eq? context 'decl)
                                             (not (%c-true
                                                   (%c-langvar
                                                    'c-recognize-paren-inits)))
                                             (or got-parens got-suffix))))
                           ;; "Got a type followed by an abstract
                           ;; declarator. If `got-prefix' is set it's
                           ;; something like "a *" without anything after
                           ;; it. If `got-parens' or `got-suffix' is set
                           ;; it's "a()", "a[]", "a()[]", or similar,
                           ;; which we accept only if the context rules
                           ;; out expressions."
                           ;;
                           ;; "If we've got at-type 'maybe, we cannot
                           ;; confidently promote the possible type to a
                           ;; found type."
                           (when (eq? at-type 'maybe)
                             (set! unsafe-maybe #t))
                           (throw-at-decl-or-cast #t)))

                     ;; "If we had a complete symbol table here (which
                     ;; rules out `c-found-types') we should return t due
                     ;; to the disambiguation rule (in at least C++) that
                     ;; anything that can be parsed as a declaration is a
                     ;; declaration. Now we're being more defensive and
                     ;; prefer to highlight things like "foo (bar);" as a
                     ;; declaration only if we're inside an arglist that
                     ;; contains declarations. Update (2017-09): We now
                     ;; recognize a top-level "foo(bar);" as a
                     ;; declaration in C."
                     ;; CASE 19
                     ;;
                     ;; This is the catch body's last form, so its
                     ;; value IS `at-decl-or-cast' when nothing threw.
                     ;; A Scheme `when' whose test fails answers the
                     ;; *unspecified* value, which is true, where
                     ;; Elisp's answers nil - so written as a `when'
                     ;; every C++ construct that reached here without a
                     ;; decision was taken for a declaration. It is an
                     ;; `if' with an explicit #f.
                     (if (or (eq? context 'decl)
                             (and (c-major-mode-is 'c-mode)
                                  (or (eq? context 'top) make-top)))
                         (begin
                           (when (and (eq? at-type 'maybe)
                                      got-parens)
                             ;; "If we've got "foo d(bar () ...)", the d
                             ;; could be a typing mistake, so we don't promote
                             ;; the 'maybe type "bar" to a 'found type."
                             (set! unsafe-maybe #t))
                           #t)
                         #f)))))
            ;; (The `parameterize' above closes the C's inner `let'
            ;; of the type-decl-expression block, which ends just
            ;; after this `setq' - the final `cond' is outside it.)

            ;; "The point is now after the type decl expression."
            (cond
             ;; "Check for a cast."
             ((save-excursion
                (and
                 (%c-langvar 'c-cast-parens)

                 ;; "Should be the first type/identifier in a cast
                 ;; paren."
                 (> preceding-token-end (point-min))
                 ;; `c-cast-parens' holds the C's characters as
                 ;; integers (Elisp's `?(\()'), and a character here is
                 ;; not a number - so convert before comparing. A char
                 ;; is guaranteed: PRECEDING-TOKEN-END is past
                 ;; `point-min'.
                 (memv (char->integer (char-before preceding-token-end))
                       (%c-langvar 'c-cast-parens))

                 ;; "The closing paren should follow."
                 (begin
                   (c-forward-syntactic-ws)
                   (looking-at "\\s)"))

                 ;; "There should be a primary expression after it."
                 (let ((pos-cast #f))
                   (forward-char)
                   (c-forward-syntactic-ws)
                   (set! cast-end (point))
                   (or
                    (and (looking-at (%c-langvar 'c-primary-expr-regexp))
                         (begin
                           (set! pos-cast (match-end 0))
                           (or
                            ;; "Check if the expression begins with a
                            ;; prefix keyword."
                            (match-beginning 2)
                            (if (match-beginning 1)
                                ;; "Expression begins with an ambiguous
                                ;; operator."
                                (cond
                                 ((match-beginning
                                   (%c-langvar 'c-per-&*+--match))
                                  (memq at-type (list #t 'known 'found)))
                                 ((match-beginning
                                   (%c-langvar 'c-per-++---match))
                                  #t)
                                 ((match-beginning
                                   (%c-langvar '#{c-per-(-match}#))
                                  (or (memq at-type (list #t 'known 'found))
                                      (not inside-macro)))
                                 (else #f))
                                ;; "Unless it's a keyword, it's the
                                ;; beginning of a primary expression."
                                (not (looking-at
                                      (%c-langvar 'c-keywords-regexp))))))
                         ;; "If `c-primary-expr-regexp' matched a
                         ;; nonsymbol token, check that it matched a
                         ;; whole one so that we don't e.g. confuse the
                         ;; operator '-' with '->'. It's ok if it matches
                         ;; further, though, since it e.g. can match the
                         ;; float '.5' while the operator regexp only
                         ;; matches '.'."
                         (or (not (looking-at
                                   (%c-langvar 'c-nonsymbol-token-regexp)))
                             (<= (match-end 0) pos-cast)))
                    (and (eqv? (char-after (point)) #\{)
                         (not (eq? (c-looking-at-statement-block-1) #t)))))

                 ;; "There should either be a cast before it or
                 ;; something that isn't an identifier or close paren."
                 (> preceding-token-end (point-min))
                 (begin
                   (goto-char (- preceding-token-end 1))
                   (or (eqv? (point) last-cast-end)
                       (begin
                         (c-backward-syntactic-ws)
                         (if (< (skip-syntax-backward "w_") 0)
                             ;; "It's a symbol. Accept it only if it's one
                             ;; of the keywords that can precede an
                             ;; expression (without surrounding parens)."
                             (looking-at (%c-langvar 'c-simple-stmt-key))
                             (and
                              ;; "Check that it isn't a close paren (block
                              ;; close, or a macro arglist is ok,
                              ;; though)."
                              (or
                               (not (memv (char-before (point))
                                          (list #\) #\])))
                               ;; "Have we moved back to a macro
                               ;; arglist?"
                               (and (%c-langvar 'c-opt-cpp-prefix)
                                    (eqv? (char-before (point)) #\))
                                    (save-excursion
                                      (and
                                       (c-go-list-backward)
                                       (let ((pos-macro #f))
                                         (c-backward-syntactic-ws)
                                         (and
                                          (set! pos-macro (c-on-identifier))
                                          (goto-char pos-macro)))
                                       (zero? (c-backward-token-2 2))
                                       (looking-at
                                        (%c-langvar
                                         'c-opt-cpp-macro-define-start))))))

                              ;; "Check that it isn't a nonsymbol
                              ;; identifier."
                              (not (c-on-identifier)))))))))

              ;; "Handle the cast."
              (when (and (%c-true (*c-record-type-identifiers*))
                         at-type
                         (not (eq? at-type #t)))
                (parameterize ((*c-promote-possible-types*
                                (if (eq? at-type 'maybe) 'just-one #t)))
                  (goto-char type-start)
                  (c-forward-type)))
              (goto-char cast-end)
              'cast)

             (at-decl-or-cast
              ;; "We're at a declaration. Highlight the type and the
              ;; following declarators."
              (when backup-if-not-cast
                (c-fdoc-shift-type-backward! #t))

              (when (and (eq? context 'decl) (looking-at ","))
                ;; "Make sure to propagate the `c-decl-arg-start'
                ;; property to the next argument if it's set in this one,
                ;; to cope with interactive refontification."
                (c-put-c-type-property (point) 'c-decl-arg-start))

              ;; "Enter all the found types into `c-found-types'."
              (when (pair? found-type-list)
                (save-excursion
                  (parameterize ((*c-promote-possible-types* #t))
                    (for-each (lambda (ft)
                                (goto-char (car ft))
                                (c-forward-type))
                              found-type-list))))

              ;; "Record the type's coordinates in
              ;; `c-record-type-identifiers' for later fontification."
              (when (and (%c-true (*c-record-type-identifiers*))
                         (not (memq at-type (list #f 'no-id))))
                (parameterize ((*c-promote-possible-types*
                                (if unsafe-maybe 'just-one #t)))
                  (save-excursion
                    (goto-char type-start)
                    (c-forward-type))))

              (list id-start
                    (and (or at-type-decl at-typedef at-<>-type)
                         (list at-type-decl at-typedef at-<>-type))
                    maybe-expression
                    type-start
                    (or (eq? context 'top) make-top)))

             (else
              ;; "False alarm. Restore the recorded ranges."
              (*c-record-type-identifiers* save-rec-type-ids)
              (*c-record-ref-identifiers* save-rec-ref-ids)
              #f)))))

    ;;------------------------------------------------------------------
    ;; `c-forward-objc-directive' (`cc-engine.el:12069')
    ;;------------------------------------------------------------------
    (define (c-forward-objc-directive)
      ;; "Assuming the point is at the beginning of a token, try to move
      ;; forward to the end of the Objective-C directive that starts
      ;; there. Return t if a directive was fully recognized, otherwise
      ;; the point is moved as far as one could be successfully parsed
      ;; and nil is returned."
      ;;
      ;; "This function records identifier ranges on
      ;; `c-record-type-identifiers' and `c-record-ref-identifiers' if
      ;; `c-record-type-identifiers' is non-nil."
      ;;
      ;; "This function might do hidden buffer changes."
      ;;
      ;; Emacs builds the two regexps with `eval-when-compile'; they are
      ;; computed per call here, which gives the same strings.
      (let ((start (point))
            (start-char #f)
            (lim #f)
            (protection-re (c-make-keywords-re
                            #t
                            (append (or (c-get-lang-constant
                                         'c-protection-kwds #f 'objc-mode)
                                        '())
                                    (list "@end"))
                            'objc-mode))
            (directive-re (c-make-keywords-re
                           #t
                           (list "@interface" "@implementation" "@protocol")
                           'objc-mode)))
        ;; "Turn off recognition of angle bracket arglists while parsing
        ;; types here since the protocol reference list might then be
        ;; considered part of the preceding name or superclass-name."
        (parameterize ((*c-promote-possible-types* #t)
                       (*c-lang-var-overrides*
                        (cons (cons 'c-recognize-<>-arglists #f)
                              (*c-lang-var-overrides*))))
          (if (or
               (if (looking-at protection-re)
                   (begin
                     (goto-char (match-end 1))
                     #t)
                   #f)

               (and
                (looking-at directive-re)

                ;; "Handle the name of the class itself."
                (begin
                  (goto-char (match-end 0))
                  (set! lim (point))
                  (c-skip-ws-forward)
                  (c-forward-type))

                (call-with-current-continuation
                 (lambda (brk)
                   ;; "Look for ": superclass-name" or "( category-name
                   ;; )"."
                   (when (looking-at "[:(]")
                     (set! start-char (char-after (point)))
                     (forward-char)
                     (c-forward-syntactic-ws)
                     (unless (c-forward-type) (brk #f))
                     (when (eqv? start-char #\()
                       (unless (eqv? (char-after (point)) #\)) (brk #f))
                       (forward-char)
                       (c-forward-syntactic-ws)))

                   ;; "Look for a protocol reference list."
                   (if (eqv? (char-after (point)) #\<)
                       (parameterize ((*c-parse-and-markup-<>-arglists* #t)
                                      (*c-restricted-<>-arglists* #f)
                                      (*c-lang-var-overrides*
                                       (cons (cons 'c-recognize-<>-arglists
                                                   #t)
                                             (*c-lang-var-overrides*))))
                         (c-forward-<>-arglist #t))
                       #t)))))

              (begin
                (c-backward-syntactic-ws lim)
                (c-clear-c-type-property start (- (point) 1) 'c-decl-end)
                (c-put-c-type-property (- (point) 1) 'c-decl-end)
                #t)
              (begin
                (c-clear-c-type-property start (point) 'c-decl-end)
                #f)))))

    ;;------------------------------------------------------------------
    ;; `c-at-toplevel-p' (`cc-engine.el:12202'),
    ;; `c-just-after-func-arglist-p' (`:12229')
    ;;------------------------------------------------------------------
    (define (c-at-toplevel-p)
      ;; "Return a determination as to whether point is \"at the top
      ;; level\". ..." (The docstring describes the answers: nil, t, or
      ;; a 2-vector.)
      ;;
      ;; "Note to maintainers: this function consumes a great mass of
      ;; CPU cycles. Its use should thus be minimized as far as
      ;; possible. Consider instead using `c-bs-at-toplevel-p'."
      (let ((paren-state (c-parse-state)))
        (or (not (c-most-enclosing-brace paren-state))
            (c-search-uplist-for-classkey paren-state))))

    (define (c-just-after-func-arglist-p . limit-args)
      ;; "Return non-nil if the point is in the region after the
      ;; argument list of a function and its opening brace (or semicolon
      ;; in case it got no body). If there are K&R style argument
      ;; declarations in that region, the point has to be inside the
      ;; first one for this function to recognize it."
      ;;
      ;; "If successful, the point is moved to the first token after the
      ;; function header (see `c-forward-decl-or-cast-1' for details)
      ;; and the position of the opening paren of the function arglist
      ;; is returned."
      ;;
      ;; "The point is clobbered if not successful."
      ;;
      ;; "LIM is used as bound for backward buffer searches."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? limit-args) (car limit-args) #f)))
        (let ((beg (point)) (id-start #f))
          (and
           (eq? (c-beginning-of-statement-1 lim #f #f #f #t) 'same)

           (not (and (c-major-mode-is 'objc-mode)
                     (c-forward-objc-directive)))

           ;; "Don't confuse #if .... defined(foo) for a function
           ;; arglist."
           (not (and (looking-at (%c-langvar 'c-cpp-expr-functions-key))
                     (save-excursion
                       (save-restriction
                         (widen)
                         (c-beginning-of-macro lim)))))
           (begin
             (if (looking-at (%c-langvar 'c-protection-key))
                 (c-forward-token-2))
             #t)
           (begin
             (set! id-start
                   (%c-car (c-forward-decl-or-cast-1 (c-point 'bosws) 'top
                                                    #f)))
             id-start)
           (number? id-start)
           (< id-start beg)

           ;; "There should not be a '=' or ',' between beg and the
           ;; start of the declaration since that means we were in the
           ;; \"expression part\" of the declaration."
           (or (> (point) beg)
               (not (looking-at "[=,]")))

           (save-excursion
             ;; "Check that there's an arglist paren in the
             ;; declaration."
             (goto-char id-start)
             (cond ((eqv? (char-after (point)) #\()
                    ;; "The declarator is a paren expression, so skip
                    ;; past it so that we don't get stuck on that
                    ;; instead of the function arglist."
                    (c-forward-sexp))
                   ((and (%c-langvar 'c-opt-op-identifier-prefix)
                         (looking-at
                          (%c-langvar 'c-opt-op-identifier-prefix)))
                    ;; "Don't trip up on "operator ()"."
                    (c-forward-token-2 2 #t)))
             (and (< (point) beg)
                  (c-syntactic-re-search-forward "(" beg #t #t)
                  (- (point) 1)))))))

    ;;------------------------------------------------------------------
    ;; `c-looking-at-decl-block' (`cc-engine.el:12742')
    ;;------------------------------------------------------------------
    ;; Emacs's `c-pull-open-brace' macro (`:9768') destructively
    ;; advances PS; here it answers `(BRACE . REST)' so the caller can
    ;; rebind. A nil BRACE answers like Emacs's nil PS.
    (define (c-pull-open-brace ps)
      ;; "Pull the next open brace from PS (which has the form of
      ;; paren-state), skipping over any brace pairs. Returns NIL when
      ;; PS is exhausted."
      (let loop ((ps ps))
        (cond ((not (pair? ps)) (cons #f '()))
              ((pair? (car ps)) (loop (cdr ps)))
              (else (cons (car ps) (cdr ps))))))

    (define (c-looking-at-decl-block goto-start . limit-args)
      ;; "Assuming the point is at an open brace, check if it starts a
      ;; block that contains another declaration level, i.e. that isn't
      ;; a statement block or a brace list, and if so return non-nil."
      ;;
      ;; "If the check is successful, the return value is the start of
      ;; the keyword that tells what kind of construct it is, i.e.
      ;; typically what `c-decl-block-key' matched. Also, if GOTO-START
      ;; is set then point will be left at the start of the construct.
      ;; ..."
      ;;
      ;; "The point is clobbered if the check is unsuccessful."
      ;;
      ;; "The optional LIMIT limits the backward search for the start of
      ;; the construct. It's assumed to be at a syntactically relevant
      ;; position."
      ;;
      ;; "If any template arglists are found in the searched region
      ;; before the open brace, they get marked with paren syntax."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((limit (if (pair? limit-args) (car limit-args) #f))
            (open-brace (point)) (kwd-start #f) (first-specifier-pos #f))
        (c-syntactic-skip-backward (%c-langvar 'c-block-prefix-charset)
                                   limit #t)

        (let loop ()
          (when (or
                 ;; "Could be after a template arglist...."
                 (and (%c-true (%c-langvar 'c-recognize-<>-arglists))
                      (eqv? (char-before (point)) #\>)
                      (parameterize ((*c-parse-and-markup-<>-arglists* #t))
                        (c-backward-<>-arglist #f limit)))
                 ;; ".... or after a noise clause with parens."
                 (and (%c-langvar 'c-opt-cpp-prefix)
                      (let ((after-paren (point)))
                        (if (eqv? (char-before (point)) #\))
                            (and
                             (c-go-list-backward)
                             (eqv? (char-after (point)) #\()
                             (begin
                               (c-backward-syntactic-ws)
                               (c-simple-skip-symbol-backward)
                               #t)
                             (or (looking-at
                                  (%c-langvar 'c-paren-nontype-key))
                                 (looking-at
                                  (c-noise-macro-with-parens-name-re))))
                            (begin (goto-char after-paren) #f)))))
            (c-syntactic-skip-backward (%c-langvar 'c-block-prefix-charset)
                                       limit #t)
            (loop)))

        ;; "Note: Can't get bogus hits inside template arglists below
        ;; since they have gotten paren syntax above."
        (if (and
             ;; "If `goto-start' is set we begin by searching for the
             ;; first possible position of a leading specifier list.
             ;; The `c-decl-block-key' search continues from there
             ;; since we know it can't match earlier."
             (if goto-start
                 (begin
                   (let loop ()
                     (when (and
                            (c-syntactic-re-search-forward
                             (%c-langvar 'c-symbol-start) open-brace #t #t)
                            (goto-char (match-beginning 0))
                            (if (or (looking-at
                                     (c-noise-macro-name-re))
                                    (looking-at
                                     (c-noise-macro-with-parens-name-re)))
                                (c-forward-noise-clause)
                                (begin
                                  (set! first-specifier-pos
                                        (match-beginning 0))
                                  #f)))
                       (loop)))
                   first-specifier-pos)
                 #t)

             (cond
              ((c-syntactic-re-search-forward
                (%c-langvar 'c-decl-block-key) open-brace #t #t #t)
               (goto-char (begin (set! kwd-start (match-beginning 0))
                                 kwd-start))
               (and
                ;; "Exclude cases where we matched what would
                ;; ordinarily be an enum declaration keyword, except
                ;; where it's not legal because it's part of a
                ;; \"compound keyword\" like \"enum class\". Of course,
                ;; if c-after-enum-list-key is nil, we can skip the
                ;; test."
                (or (equal? (%c-langvar 'c-after-enum-list-key)
                            regexp-unmatchable)
                    (save-match-data
                      (save-excursion
                        (not
                         (and
                          (looking-at (%c-langvar 'c-after-enum-list-key))
                          (= (c-backward-token-2 1 #t) 0)
                          (looking-at (%c-langvar 'c-enum-list-key)))))))
                (or
                 ;; "Found a keyword that can't be a type?"
                 (match-beginning 1)

                 ;; "Can be a type too, in which case it's the return
                 ;; type of a function (under the assumption that no
                 ;; declaration level block construct starts with a
                 ;; type)."
                 (not (c-forward-type))

                 ;; "Jumped over a type, but it could be a declaration
                 ;; keyword followed by the declared identifier that
                 ;; we've jumped over instead (e.g. in "class Foo
                 ;; {"). If it indeed is a type then we should be at
                 ;; the declarator now, so check for a valid
                 ;; declarator start."
                 ;;
                 ;; "Note: This doesn't cope with the case when a
                 ;; declared identifier is followed by e.g. '(' in a
                 ;; language where '(' also might be part of a
                 ;; declarator expression. Currently there's no such
                 ;; language."
                 (not (or (looking-at (%c-langvar 'c-symbol-start))
                          (looking-at
                           (%c-langvar 'c-type-decl-prefix-key))
                          (and (eqv? (char-after (point)) #\{)
                               (not (c-looking-at-statement-block))))))))

              ;; "In Pike a list of modifiers may be followed by a brace
              ;; to make them apply to many identifiers. Note that the
              ;; match data will be empty on return in this case."
              ((and (c-major-mode-is 'pike-mode)
                    (begin
                      (goto-char open-brace)
                      (= (c-backward-token-2) 0))
                    (looking-at (%c-langvar 'c-specifier-key))
                    ;; "Use this variant to avoid yet another special
                    ;; regexp."
                    (c-keyword-member (c-keyword-sym (match-string 1))
                                      'c-modifier-kwds))
               (set! kwd-start (point))
               #t)
              (else #f)))

            ;; "Got a match."
            (begin
              (if goto-start
                  ;; "Back up over any preceding specifiers and their
                  ;; clauses by going forward from
                  ;; `first-specifier-pos', which is the earliest
                  ;; possible position where the specifier list can
                  ;; start."
                  (begin
                    (goto-char first-specifier-pos)

                    (let loop ()
                      (when (< (point) kwd-start)
                        (cond
                         ((or (looking-at (c-noise-macro-name-re))
                              (looking-at
                               (c-noise-macro-with-parens-name-re)))
                          (c-forward-noise-clause))
                         ((looking-at (%c-langvar 'c-symbol-key))
                          ;; "Accept any plain symbol token on the ground
                          ;; that it's a specifier masked through a macro
                          ;; (just like `c-forward-decl-or-cast-1' skips
                          ;; forward over such tokens)."
                          ;;
                          ;; "Could be more restrictive wrt invalid
                          ;; keywords, but that'd only occur in invalid
                          ;; code so there's no use spending effort on
                          ;; it."
                          (let ((end (match-end 0))
                                (kwd-sym (c-keyword-sym (match-string 0)))
                                (annotation
                                 (and (%c-langvar 'c-annotation-re)
                                      (looking-at
                                       (%c-langvar 'c-annotation-re)))))
                            (unless
                                (and kwd-sym
                                     ;; "Moving over a protection kwd and
                                     ;; the following ":" (in C++ Mode)
                                     ;; to the next token could take us
                                     ;; all the way up to `kwd-start',
                                     ;; leaving us no chance to update
                                     ;; `first-specifier-pos'."
                                     (not (c-keyword-member
                                           kwd-sym 'c-protection-kwds))
                                     (c-forward-keyword-clause 0))
                              (goto-char end)
                              (c-forward-syntactic-ws)
                              (when annotation
                                (set! first-specifier-pos
                                      (match-beginning 0))
                                (when (and (eqv? (char-after (point)) #\()
                                           (c-go-list-forward (point)
                                                              kwd-start))
                                  (c-forward-syntactic-ws))))))

                         ((c-syntactic-re-search-forward
                           (%c-langvar 'c-symbol-start) kwd-start 'move #t)
                          ;; "Can't parse a declaration preamble and is
                          ;; still before `kwd-start'. That means
                          ;; `first-specifier-pos' was in some earlier
                          ;; construct. Search again."
                          (goto-char (begin
                                       (set! first-specifier-pos
                                             (match-beginning 0))
                                       first-specifier-pos)))

                         (else
                          ;; "Got no preamble before the block declaration
                          ;; keyword."
                          (set! first-specifier-pos kwd-start)))
                        (loop)))

                    (goto-char first-specifier-pos))
                  (goto-char kwd-start))
              kwd-start)
            #f)))
    (define (c-directly-in-class-called-p name)
      ;; "Check whether point is directly inside a brace block which is
      ;; the brace block of a class, struct, or union which is called
      ;; NAME, a string."
      (let* ((paren-state (c-parse-state))
             (pull (c-pull-open-brace paren-state))
             (brace-pos (car pull)))
        (if (eqv? (char-after brace-pos) #\{)
            (begin
              (goto-char brace-pos)
              (save-excursion
                (if (and (c-looking-at-decl-block #f)
                         (looking-at (%c-langvar 'c-class-key)))
                    (begin
                      (goto-char (match-end 1))
                      (c-forward-syntactic-ws)
                      (and (looking-at (%c-langvar 'c-identifier-key))
                           (string=? (match-string 0) name)))
                    #f)))
            #f)))

    (define (c-search-uplist-for-classkey paren-state)
      ;; "Check if the closest containing paren sexp is a declaration
      ;; block, returning a 2 element vector in that case. Aref 0
      ;; contains the bufpos at boi of the class key line, and aref 1
      ;; contains the bufpos of the open brace. This function is an
      ;; obsolete wrapper for `c-looking-at-decl-block'."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((open-paren-pos (c-most-enclosing-brace paren-state)))
        (if open-paren-pos
            (save-excursion
              (goto-char open-paren-pos)
              (if (and (eqv? (char-after (point)) #\{)
                       (c-looking-at-decl-block #f))
                  (begin
                    (back-to-indentation)
                    (vector (point) open-paren-pos))
                  #f))
            #f)))

    ;;------------------------------------------------------------------
    ;; `c-looking-at-statement-block-1' (`cc-engine.el:13647'),
    ;; `c-looking-at-statement-block' (`:13736')
    ;;------------------------------------------------------------------
    (define (c-looking-at-statement-block-1)
      ;; "Point is at an opening brace. Try to determine whether it
      ;; starts a statement block. For example, if there are elements in
      ;; the block terminated by semicolons, or the block contains a
      ;; characteristic keyword, or a nested brace block is a statement
      ;; block, return t. If we determine the block cannot be a
      ;; statement block, return nil. Otherwise return the symbol
      ;; `maybe'."
      ;;
      ;; "The calculations are based solely on the contents of the
      ;; block, not on its context. There is special handling for C++
      ;; lambda expressions, which sometimes occur in brace blocks."
      (let ((here (point)))
        (let ((res
               (if (c-go-list-forward)
                   (let ((there (point)))
                     (backward-char)
                     (c-syntactic-skip-backward "^;" here #t)
                     (cond
                      ((eqv? (char-before (point)) #\;))
                      ((begin
                         (c-forward-syntactic-ws)
                         (eqv? (point) (- there 1)))
                       'maybe)
                      ((c-syntactic-re-search-forward
                        (%c-langvar 'c-stmt-block-only-keywords-regexp)
                        there #t #t)
                       #t)
                      ((c-major-mode-is 'c++-mode)
                       (call-with-current-continuation
                        (lambda (statement)
                          (let loop ()
                            (when (and
                                   (c-syntactic-re-search-forward
                                    "[[{]" there 'bound #t)
                                   (begin
                                     (backward-char)
                                     (cond
                                      ((eqv? (char-after (point)) #\[)
                                       (let ((bb (c-looking-at-c++-lambda-expression)))
                                         (if bb
                                             (c-go-list-forward bb there)
                                             (begin (forward-char) #t))))
                                      ((eq? (c-looking-at-statement-block-1)
                                            #t)
                                       (statement #t))
                                      (else
                                       (c-go-list-forward)
                                       #t))))
                              (loop)))
                          'maybe)))
                      (else
                       (call-with-current-continuation
                        (lambda (statement2)
                          (let loop ()
                            (when (and
                                   (c-syntactic-re-search-forward
                                    "{" there #t #t)
                                   (begin
                                     (backward-char)
                                     (if (eq? (c-looking-at-statement-block-1)
                                              #t)
                                         (statement2 #t)
                                         (c-go-list-forward))))
                              (loop)))
                          'maybe)))))
                   (begin
                     (forward-char)
                     (cond
                      ((c-syntactic-re-search-forward ";" #f #t #t))
                      ((begin (c-forward-syntactic-ws) (eobp))
                       'maybe)
                      ((c-syntactic-re-search-forward
                        (%c-langvar 'c-stmt-block-only-keywords-regexp)
                        #f #t #t)
                       #t)
                      ((c-major-mode-is 'c++-mode)
                       (call-with-current-continuation
                        (lambda (statement1)
                          (let loop ()
                            (when (and
                                   (c-syntactic-re-search-forward
                                    "[[}]" #f 'bound #t)
                                   (begin
                                     (backward-char)
                                     (cond
                                      ((eqv? (char-after (point)) #\[)
                                       (let ((bb (c-looking-at-c++-lambda-expression)))
                                         (cond ((and bb (c-go-list-forward bb)))
                                               (bb (statement1 'maybe))
                                               (else (forward-char) #t))))
                                      ((eq? (c-looking-at-statement-block-1)
                                            #t)
                                       (statement1 #t))
                                      ((c-go-list-forward))
                                      (else (statement1 'maybe)))))
                              (loop)))
                          #f)))
                      (else
                       (call-with-current-continuation
                        (lambda (statement3)
                          (let loop ()
                            (when (and
                                   (c-syntactic-re-search-forward
                                    "{" #f #t #t)
                                   (begin
                                     (backward-char)
                                     (if (eq? (c-looking-at-statement-block-1)
                                              #t)
                                         (statement3 #t)
                                         (c-go-list-forward))))
                              (loop)))
                          'maybe))))))))
          (goto-char here)
          res)))

    (define (c-looking-at-statement-block)
      ;; "Point is at an opening brace. If this brace starts a statement
      ;; block, return t. Otherwise return nil."
      ;;
      ;; "This function first examines the contents of the block
      ;; beginning at the brace, and if this fails to give a definite
      ;; result, it examines the context of the block."
      (save-excursion
        (let ((res (c-looking-at-statement-block-1)) (prev-tok #f))
          (cond
           ((memq res (list #f #t)) res)
           ((zero? (c-backward-token-2))
            (set! prev-tok (point))
            (cond
             ((looking-at "={]") #f)
             ((begin
                (if (looking-at
                     (%c-langvar 'c-type-decl-suffix-ws-ids-key))
                    (c-backward-token-2))
                (if (and (%c-true (%c-langvar 'c-recognize-<>-arglists))
                         (eqv? (char-after (point)) #\>)
                         (c-go-up-list-backward))
                    (c-backward-token-2))
                (and (%c-langvar 'c-opt-block-decls-with-vars-key)
                     (or (looking-at
                          (%c-langvar 'c-opt-block-decls-with-vars-key))
                         (save-excursion
                           (and (c-on-identifier)
                                (zero? (c-backward-token-2))
                                (looking-at
                                 (%c-langvar
                                  'c-opt-block-decls-with-vars-key))))))))
             ((eqv? (char-after (point)) #\})) ; "Statement block following another one."
             ((eqv? (char-after (point)) #\:) ; "Case label or ordinary label."
              (save-excursion
                (forward-char)
                (eq? (c-beginning-of-statement-1 #f #f #t) 'label)))
             ((save-excursion ; "Between function arglist and block."
                (c-just-after-func-arglist-p))
              #t)
             ((save-excursion ; "Just after C++ class member initializations."
                (and (eqv? (char-after (point)) #\))
                     (begin
                       (forward-char)
                       (c-back-over-member-initializer-braces)))))
             ((and (eqv? (char-after (point)) #\))
                   (c-go-up-list-backward))
              (let ((v
                     (cond
                      ((save-excursion
                         (and (zero? (c-backward-token-2)) ; "Parens of an `if', etc.?"
                              (looking-at (%c-langvar 'c-block-stmt-2-key)))))
                      ((save-excursion ; "Between function arglist and block."
                         (c-just-after-func-arglist-p))
                       #t)
                      ((begin ; "A function call or declaration."
                         (c-backward-syntactic-ws)
                         (c-on-identifier))
                       #t)
                      (else #f))))
                (goto-char prev-tok)
                v))
             ((eqv? (char-after (point)) #\;)) ; "Bare statement block."
             ((looking-at (%c-langvar 'c-block-stmt-1-key))) ; e.g. "do", "else".
             ((eqv? (char-after (point)) #\()
              (and (zero? (c-backward-token-2))
                   (or (looking-at (%c-langvar 'c-operator-re)) ; "Statement expression."
                       (looking-at (%c-langvar
                                    'c-block-stmt-2-key))))) ; e.g. "if", "catch".
             (else #f)))
           (else #f)))))

    ;;------------------------------------------------------------------
    ;; `c-looking-at-c++-lambda-expression' (`cc-engine.el:14113'),
    ;; `c-backward-over-lambda-expression' (`:14169')
    ;;------------------------------------------------------------------
    (define (c-looking-at-c++-lambda-expression . lim-args)
      ;; "If point is at the [ opening a C++ lambda expressions's
      ;; capture list, and the lambda expression is complete, return the
      ;; position of the { which opens the body form, otherwise return
      ;; nil. LIM is the limit for forward searching for the {."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (let ((here (point))
              (lim-or-max (or lim (point-max)))
              (got-params #f))
          (if (and (c-looking-at-c++-lambda-capture-list)
                   (c-go-list-forward #f lim))
            (begin
            (c-forward-syntactic-ws lim)
            (when (and (eqv? (char-after (point)) #\<)
                       (c-forward-<>-arglist #t))
              (c-forward-syntactic-ws lim)
              (when (looking-at (%c-langvar 'c-requires-clause-key))
                (c-forward-c++-requires-clause lim #f)))
            (when (looking-at "\\_<\\(alignas\\)\\_>")
              (c-forward-keyword-clause 1))
            (when (and (eqv? (char-after (point)) #\()
                       (c-go-list-forward #f lim))
              (set! got-params #t)
              (c-forward-syntactic-ws lim))
            (let loop ()
              (when (and (%c-langvar 'c-lambda-spec-key)
                         (looking-at (%c-langvar 'c-lambda-spec-key)))
                (goto-char (match-end 1))
                (c-forward-syntactic-ws lim)
                (loop)))
            (let ((after-except-pos #f))
              (let loop ()
                (when (and (<= (point) lim-or-max)
                           (cond
                            ((save-excursion
                               (and (looking-at "\\_<throw\\_>")
                                    (begin
                                      (goto-char (match-beginning 1))
                                      (c-forward-syntactic-ws lim)
                                      (eqv? (char-after (point)) #\())
                                    (c-go-list-forward #f lim)
                                    (begin
                                      (c-forward-syntactic-ws lim)
                                      (set! after-except-pos (point))
                                      after-except-pos)))
                             (goto-char after-except-pos)
                             (c-forward-syntactic-ws lim)
                             #t)
                            ;; "noexcept" or "alignas"
                            ((looking-at (%c-langvar 'c-paren-nontype-key))
                             (c-forward-keyword-clause 1))
                            (else #f)))
                  (loop))))
            (and (<= (point) lim-or-max)
                 (looking-at (%c-langvar 'c-haskell-op-re))
                 (goto-char (match-end 0))
                 (begin
                   (c-forward-syntactic-ws lim)
                   (c-forward-type #t))) ; "t is BRACE-BLOCK-TOO."
            (and got-params
                 (<= (point) lim-or-max)
                 (looking-at (%c-langvar 'c-requires-clause-key))
                 (c-forward-c++-requires-clause lim #f))
            (let ((res (and (<= (point) lim-or-max)
                            (eqv? (char-after (point)) #\{)
                            (point))))
              (goto-char here)
              res))
            #f))))

    (define (c-backward-over-lambda-expression . lim-args)
      ;; "Point is at a {. Move back over the lambda expression this is
      ;; a part of, stopping at the [ of the capture list, if this is
      ;; the case, returning the position of that opening bracket. If
      ;; we're not at such a list, leave point unchanged and return
      ;; nil."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (let ((here (point)))
          (c-syntactic-skip-backward "^;}]" lim #t)
          (if (and (eqv? (char-before (point)) #\])
                   (c-go-list-backward #f lim)
                   (eqv? (c-looking-at-c++-lambda-expression (+ here 1))
                         here))
              (point)
              (begin (goto-char here) #f)))))
    ;;------------------------------------------------------------------
    ;; The label scan, the K&R argument declarations and the declaration
    ;; header (`cc-engine.el:11817'-`:12741')
    ;;------------------------------------------------------------------
    ;; Emacs's file has these between the declaration decision and the
    ;; language-independent declaration machinery; they are appended
    ;; here as the tranche that completes it.
    ;;
    ;; The truthiness rules are the tree's usual ones and each is
    ;; load-bearing here: every `cond' whose value is tested ends in
    ;; `(else #f)', and Elisp's `when' used as a value is an `if' with
    ;; an explicit `#f' - `c-forward-label''s third clause tests one.

    (define (c-forward-label . args)
      ;; "Assuming that point is at the beginning of a token, check if it
      ;; starts a label and if so move over it and return non-nil (t in
      ;; default situations, specific symbols (see below) for interesting
      ;; situations), otherwise don't move and return nil.  \"Label\"
      ;; here means \"most things with a colon\"."
      ;;
      ;; "More precisely, a \"label\" is regarded as one of:
      ;; (i) a goto target like \"foo:\" - returns the symbol `goto-target';
      ;; (ii) A case label - either the entire construct \"case FOO:\", or
      ;;   just the bare \"case\", should the colon be missing.  We return t;
      ;; (iii) a keyword which needs a colon, like \"default:\" or
      ;;   \"private:\";  We return t;
      ;; (iv) One of QT's \"extended\" C++ variants of
      ;;   \"private:\"/\"protected:\"/\"public:\"/\"more:\" looking like
      ;;   \"public slots:\".  Returns the symbol `qt-2kwds-colon'.
      ;; (v) QT's construct \"signals:\".  Returns the symbol
      ;;   `qt-1kwd-colon'.
      ;; (vi) One of the keywords matched by `c-opt-extra-label-key'
      ;;   (without any colon). ..."
      ;;
      ;; "This function records the ranges of the label symbols on
      ;; `c-record-ref-identifiers' if `c-record-type-identifiers' (!) is
      ;; non-nil."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((assume-markup (if (pair? args) (car args) #f))
            (preceding-token-end (if (and (pair? args) (pair? (cdr args)))
                                     (cadr args) #f))
            (limit (if (and (pair? args) (pair? (cdr args))
                            (pair? (cddr args)))
                       (caddr args) #f)))
        (let ((start (point))
              (label-end #f)
              (qt-symbol-idx #f)
              (macro-start #f)          ; "if we're in one."
              (label-type #f)
              (kwd #f))
          (cond
           ;; "case" or "default" (Doesn't apply to AWK).
           ((let ((re (%c-langvar 'c-label-kwds-regexp)))
              (and re (looking-at re)))
            (let ((kwd-end (match-end 1)))
              ;; "Record only the keyword itself for fontification, since
              ;; in case labels the following is a constant expression and
              ;; not a label."
              (when (%c-true (*c-record-type-identifiers*))
                (c-record-ref-id (cons (match-beginning 1) kwd-end)))

              ;; "Find the label end."
              (goto-char kwd-end)
              (set! label-type
                    (if (and (c-syntactic-re-search-forward
                              ;; "Stop on chars that aren't allowed in
                              ;; expressions, and on operator chars that
                              ;; would be meaningless there.  FIXME: This
                              ;; doesn't cope with ?: operators."
                              "[;{=,@]\\|\\(\\=\\|[^:]\\):\\([^:]\\|\\'\\)"
                              limit #t #t #f 1)
                             (match-beginning 2))
                        (begin          ; "there's a proper :"
                          (goto-char (match-beginning 2)) ; "just after the :"
                          (c-put-c-type-property (1- (point)) 'c-decl-end)
                          #t)

                        ;; "It's an unfinished label.  We consider the
                        ;; keyword enough to recognize it as a label, so
                        ;; that it gets fontified.  Leave the point at the
                        ;; end of it, but don't put any `c-decl-end'
                        ;; marker."
                        (begin (goto-char kwd-end) #t)))))

           ;; "@private", "@protected", "@public", in Objective C, or similar.
           ((let ((re (%c-langvar 'c-opt-extra-label-key)))
              (and re (looking-at re)))
            ;; "For a `c-opt-extra-label-key' match, we record the whole
            ;; thing for fontification.  That's to get the leading '@' in
            ;; Objective-C protection labels fontified."
            (goto-char (match-end 1))
            (when (%c-true (*c-record-type-identifiers*))
              (c-record-ref-id (cons (match-beginning 1) (point))))
            (c-put-c-type-property (1- (point)) 'c-decl-end)
            (set! label-type #t))

           ;; "All other cases of labels."
           ((and (%c-langvar 'c-recognize-colon-labels) ; "nil for AWK and IDL, otherwise t."

                 ;; "A colon label must have something before the colon."
                 (not (eqv? (char-after (point)) #\:))

                 ;; "Check that we're not after a token that can't precede
                 ;; a label."
                 (or
                  ;; "Trivially succeeds when there's no preceding token.
                  ;; Succeeds when we're at a virtual semicolon."
                  (if preceding-token-end
                      (<= preceding-token-end (point-min))
                      (save-excursion
                        (c-backward-syntactic-ws)
                        (set! preceding-token-end (point))
                        (or (bobp)
                            (c-at-vsemi-p))))

                  ;; "Check if we're after a label, if we're after a
                  ;; closing paren that belong to statement, and with
                  ;; `c-label-prefix-re'.  It's done in different order
                  ;; depending on `assume-markup' since the checks have
                  ;; different expensiveness."
                  (if assume-markup
                      (or
                       (eq? (c-get-char-property (1- preceding-token-end)
                                                 'c-type)
                            'c-decl-end)

                       (save-excursion
                         (goto-char (1- preceding-token-end))
                         (c-beginning-of-current-token)
                         (or (let ((re (%c-langvar 'c-label-prefix-re)))
                               (and re (looking-at re)))
                             (let ((re (%c-langvar 'c-block-stmt-1-key)))
                               (and re (looking-at re)))))

                       (and (eqv? (char-before preceding-token-end) #\))
                            (c-after-conditional)))

                      (or
                       (save-excursion
                         (goto-char (1- preceding-token-end))
                         (c-beginning-of-current-token)
                         (or (let ((re (%c-langvar 'c-label-prefix-re)))
                               (and re (looking-at re)))
                             (let ((re (%c-langvar 'c-block-stmt-1-key)))
                               (and re (looking-at re)))))

                       (cond
                        ((eqv? (char-before preceding-token-end) #\))
                         (c-after-conditional))

                        ((eqv? (char-before preceding-token-end) #\:)
                         ;; "Might be after another label, so check it
                         ;; recursively."
                         (save-restriction
                           (save-excursion
                             (goto-char (1- preceding-token-end))
                             ;; "Essentially the same as the
                             ;; `c-syntactic-re-search-forward' regexp below."
                             (set! macro-start
                                   (save-excursion
                                     (and (c-beginning-of-macro)
                                          (point))))
                             (if macro-start
                                 (narrow-to-region macro-start (point-max)))
                             (c-syntactic-skip-backward "^-]:?;}=*/%&|,<>!@+"
                                                        #f #t)
                             ;; "Note: the following should work instead of
                             ;; the narrow-to-region above.  Investigate why
                             ;; not, sometime.  ACM, 2006-03-31."
                             (let ((pte (point)))
                               ;; "If the caller turned on recording for us,
                               ;; it shouldn't apply when we check the
                               ;; preceding label."
                               (parameterize ((*c-record-type-identifiers* #f))
                                 ;; "A label can't start at a cpp directive.
                                 ;; Check for this, since
                                 ;; c-forward-syntactic-ws would foul up on
                                 ;; it."
                                 (unless (let ((re (%c-langvar 'c-opt-cpp-prefix)))
                                           (and re (looking-at re)))
                                   (c-forward-syntactic-ws)
                                   (c-forward-label #f pte start)))))))

                        (else #f)))))

                 ;; "Point is still at the beginning of the possible label
                 ;; construct."
                 ;;
                 ;; "Check that the next nonsymbol token is \":\", or that
                 ;; we're in one of QT's \"slots\" declarations.  Allow '('
                 ;; for the sake of macro arguments.  FIXME: Should build
                 ;; this regexp from the language constants."
                 (cond
                  ;; "public: protected: private:"
                  ((and
                    (c-major-mode-is 'c++-mode)
                    (re-search-forward
                     "\\=p\\(r\\(ivate\\|otected\\)\\|ublic\\)\\_>" #f #t)
                    (begin (c-forward-syntactic-ws limit)
                           (looking-at ":\\([^:]\\|\\'\\)"))) ; "A single colon."
                   (forward-char)
                   (set! label-type #t))
                  ;; "QT double keyword like \"protected slots:\" or goto
                  ;; target."
                  ((begin (goto-char start) #f))
                  ((if (c-syntactic-re-search-forward
                        "[ \t\n[:?;{=*/%&|,<>!@+-]" limit #t #t) ; "not at EOB"
                       (begin
                         (backward-char)
                         (set! label-end (point))
                         (set! qt-symbol-idx
                               (and (c-major-mode-is 'c++-mode)
                                    (string-match
                                     "\\(p\\(r\\(ivate\\|otected\\)\\|ublic\\)\\|more\\)\\_>"
                                     (buffer-substring start (point)))))
                         (c-forward-syntactic-ws limit)
                         (cond
                          ((looking-at ":\\([^:]\\|\\'\\)") ; "A single colon."
                           (forward-char)
                           (set! label-type
                                 (if (or (string=? "signals" ; "Special QT macro"
                                                   (begin
                                                     (set! kwd (buffer-substring-no-properties
                                                                start label-end))
                                                     kwd))
                                         (string=? "Q_SIGNALS" kwd))
                                     'qt-1kwd-colon
                                     'goto-target)))
                          ((and qt-symbol-idx
                                (re-search-forward "\\=\\(slots\\|Q_SLOTS\\)\\_>"
                                                   limit #t)
                                (begin (c-forward-syntactic-ws limit)
                                       (looking-at ":\\([^:]\\|\\'\\)"))) ; "A single colon"
                           (forward-char)
                           (set! label-type 'qt-2kwds-colon))
                          ;; Emacs's `cond' answers nil with no matching
                          ;; clause, and the `when' that wraps this cond
                          ;; has its value tested by the enclosing cond -
                          ;; the unspecified value would be true.
                          (else #f)))
                       #f))
                       ;; Emacs's `cond' answers nil with no matching
                       ;; clause, and this one's value is the last operand
                       ;; of the enclosing `and'.
                       (else #f)))

                 (save-restriction
                   (narrow-to-region start (point))

                   ;; "Check that `c-nonlabel-token-key' doesn't match
                   ;; anywhere."
                   (call-with-current-continuation
                    (lambda (check-label)
                      (goto-char start)
                      (let loop ()
                        (when (begin
                                (let ((re (%c-langvar 'c-nonlabel-token-key)))
                                  (when (and re (looking-at re))
                                    (goto-char start)
                                    (set! label-type #f)
                                    (check-label #f)))
                                (and (c-safe (c-forward-sexp)
                                             (c-forward-syntactic-ws)
                                             #t)
                                     (not (eobp))))
                          (loop)))

                      ;; "Record the identifiers in the label for
                      ;; fontification, unless it begins with
                      ;; `c-label-kwds' in which case the following
                      ;; identifiers are part of a (constant) expression
                      ;; that shouldn't be fontified."
                      (when (and (%c-true (*c-record-type-identifiers*))
                                 (begin
                                   (goto-char start)
                                   (not (let ((re (%c-langvar 'c-label-kwds-regexp)))
                                          (and re (looking-at re))))))
                        (let loop ()
                          (when (c-syntactic-re-search-forward
                                 (%c-langvar 'c-symbol-key) #f #t)
                            (c-record-ref-id (cons (match-beginning 0)
                                                   (match-end 0)))
                            (loop))))

                      (c-put-c-type-property (1- (point-max)) 'c-decl-end)
                      (goto-char (point-max))))))

           (else
            ;; "Not a label."
            (goto-char start)))
          label-type)))

    (define (c-in-knr-argdecl . lim-args)
      ;; "Return the position of the first argument declaration if point
      ;; is inside a K&R style argument declaration list, nil otherwise.
      ;; `c-recognize-knr-p' is not checked.  If LIM is non-nil, it's a
      ;; position that bounds the backward search for the argument list.
      ;; This function doesn't move point."
      ;;
      ;; "Point must be within a possible K&R region, e.g. just before a
      ;; top-level \"{\".  It must be outside of parens and brackets.  The
      ;; test can return false positives otherwise."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (save-excursion
          (save-restriction
            ;; "If we're in a macro, our search range is restricted to it.
            ;; Narrow to the searchable range."
            (let* ((macro-start (save-excursion
                                  (and (c-beginning-of-macro) (point))))
                   (macro-end (save-excursion
                                (and macro-start (c-end-of-macro) (point))))
                   (low-lim (max (or lim (point-min))
                                 (or macro-start (point-min))))
                   (before-lparen #f)
                   (after-rparen #f)
                   (here (point))
                   (pp-count-out 20)  ; "Max number of paren/brace constructs
                                      ; before we give up"
                   (ids '())          ; "List of identifiers in the
                                      ; parenthesized list."
                   (id-start #f)
                   (after-prec-token #f)
                   (decl-or-cast #f)
                   (semi-position+1 #f))
              (narrow-to-region low-lim (or macro-end (point-max)))

              ;; "Search backwards for the defun's argument list.  We give
              ;; up if we encounter a \"}\" (end of a previous defun) an
              ;; \"=\" (which can't be in a knr region) or BOB."
              ;;
              ;; "The criterion for a paren structure being the arg list
              ;; is: ..."
              (call-with-current-continuation
               (lambda (knr)
                 (let loop ()
                   (when (> pp-count-out 0) ; "go back one paren/bracket pair each time."
                     (set! pp-count-out (1- pp-count-out))
                     (c-syntactic-skip-backward "^)]}=")
                     (cond ((eqv? (char-before) #\))
                            (set! after-rparen (point)))
                           ((eqv? (char-before) #\])
                            (set! after-rparen #f))
                           (else ; "either } (hit previous defun) or = or no
                                 ; more parens/brackets."
                            (knr #f)))

                     (if after-rparen
                         ;; "We're inside a paren.  Could it be our argument
                         ;; list....?"
                         (if (and
                              (begin
                                (goto-char after-rparen)
                                (unless (c-go-list-backward) (knr #f))
                                ;; "FIXME!!!  What about macros between the
                                ;; parens?  2007/01/20"
                                (set! before-lparen (point))
                                #t)

                              ;; "It can't be the arg list if next token is ;
                              ;; or {"
                              (begin (goto-char after-rparen)
                                     (c-forward-syntactic-ws)
                                     (not (memv (char-after (point))
                                                (list #\; #\{ #\=))))

                              ;; "Is the thing preceding the list an
                              ;; identifier (the function name), or a macro
                              ;; expansion?"
                              (begin
                                (goto-char before-lparen)
                                (= (c-backward-token-2) 0)
                                (or (eq? (c-on-identifier) (point))
                                    (and (eqv? (char-after (point)) #\))
                                         (c-go-up-list-backward)
                                         (= (c-backward-token-2) 0)
                                         (eq? (c-on-identifier) (point)))))

                              ;; "Have we got a non-empty list of
                              ;; comma-separated identifiers?"
                              (begin
                                (goto-char before-lparen)
                                (and
                                 (c-forward-over-token-and-ws) ; "to first token inside parens"
                                 (begin (set! id-start (c-on-identifier))
                                        id-start) ; "Must be at least one."
                                 (call-with-current-continuation
                                  (lambda (id-list)
                                    (let loop ()
                                      (when (begin
                                              (forward-char)
                                              (c-end-of-current-token)
                                              (set! ids
                                                    (cons (buffer-substring-no-properties
                                                           id-start (point))
                                                          ids))
                                              (c-forward-syntactic-ws)
                                              (eqv? (char-after (point)) #\,))
                                        (c-forward-over-token-and-ws)
                                        (unless (begin
                                                  (set! id-start (c-on-identifier))
                                                  id-start)
                                          (id-list #f))
                                        (loop)))
                                    (eqv? (char-after (point)) #\))))))

                              ;; "Are all the identifiers in the k&r list up
                              ;; to the current one also in the argument
                              ;; list?"
                              (begin
                                (forward-char) ; "over the )"
                                (set! after-prec-token after-rparen)
                                (c-forward-syntactic-ws)
                                ;; "Each time around the following checks one
                                ;; declaration (which may contain several
                                ;; identifiers)."
                                (let loop ()
                                  (when (and
                                          (not (eqv? (char-after (point)) #\{))
                                          (or
                                           (begin
                                             (set! decl-or-cast
                                                   (c-forward-decl-or-cast-1
                                                    after-prec-token
                                                    #f ; "Or 'arglist ???"
                                                    #f))
                                             (pair? decl-or-cast))
                                           (knr #f))
                                          (memv (char-after (point)) (list #\; #\,))
                                          (begin (goto-char (car decl-or-cast)) #t)
                                          (save-excursion
                                            (set! semi-position+1
                                                  (c-syntactic-re-search-forward
                                                   ";" (+ (point) 1000) #t)))
                                          (c-do-declarators
                                           semi-position+1 #t #f #f
                                           (lambda (id-start id-end _next _not-top
                                                    _func _init)
                                             (if (not (member
                                                       (buffer-substring-no-properties
                                                        id-start id-end)
                                                       ids))
                                                 (knr #f))))
                                          (begin (forward-char)
                                                 (<= (point) here))
                                          (begin (c-forward-syntactic-ws) #t))
                                    (loop)))
                                #t))
                              ;; "Yes.  We've identified the function's
                              ;; argument list."
                              (knr (begin (goto-char after-rparen)
                                          (c-forward-syntactic-ws)
                                          (point)))
                           ;; "No.  The current parens aren't the function's
                           ;; arg list."
                           (goto-char before-lparen))

                       (or (c-go-list-backward) ; "backwards over [ .... ]"
                           (knr #f)))
                     (loop)))
                 ;; "The catch's value when it falls out of the loop."
                 #f)))))))

    (define (c-skip-conditional)
      ;; "skip forward over conditional at point, including any predicate
      ;; statements in parentheses. No error checking is performed."
      ;;
      ;; "This function might do hidden buffer changes."
      (c-forward-sexp (cond
                       ;; "else if()"
                       ((looking-at (concat "\\_<else\\_>"
                                            "\\([ \t\n]\\|\\\\\n\\)+"
                                            "\\_<if\\_>"))
                        3)
                       ;; "do, else, try, finally"
                       ((looking-at (concat "\\_<\\("
                                            "do\\|else\\|try\\|finally"
                                            "\\)\\_>"))
                        1)
                       ;; "for, if, while, switch, catch, synchronized, foreach"
                       (else 2))))

    (define (c-after-conditional . lim-args)
      ;; "If looking at the token after a conditional then return the
      ;; position of its start, otherwise return nil."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (save-excursion
          (and (= (c-backward-token-2 1 #t lim) 0)
               (if (let ((re (%c-langvar 'c-block-stmt-hangon-key)))
                     (and re (looking-at re)))
                   (= (c-backward-token-2 1 #t lim) 0)
                   #t)
               (or (let ((re (%c-langvar 'c-block-stmt-1-key)))
                     (and re (looking-at re)))
                   (or
                    (and
                     (eqv? (char-after (point)) #\()
                     (= (c-backward-token-2 1 #t lim) 0)
                     (if (let ((re (%c-langvar 'c-block-stmt-hangon-key)))
                           (and re (looking-at re)))
                         (= (c-backward-token-2 1 #t lim) 0)
                         #t)
                     (or (let ((re (%c-langvar 'c-block-stmt-2-key)))
                           (and re (looking-at re)))
                         (let ((re (%c-langvar 'c-block-stmt-1-2-key)))
                           (and re (looking-at re)))))
                    (and (let ((re (%c-langvar 'c-paren-clause-key)))
                           (and re (looking-at re)))
                         (= (c-backward-token-2 1 #t lim) 0)
                         (if (let ((re (%c-langvar 'c-negation-op-re)))
                               (and re (looking-at re)))
                             (= (c-backward-token-2 1 #t lim) 0)
                             #t)
                         (let ((re (%c-langvar 'c-block-stmt-with-key)))
                           (and re (looking-at re))))))
               (point)))))

    (define (c-after-special-operator-id . lim-args)
      ;; "If the point is after an operator identifier that isn't handled
      ;; like an ordinary symbol (i.e. like \"operator =\" in C++) then the
      ;; position of the start of that identifier is returned.  nil is
      ;; returned otherwise.  The point may be anywhere in the syntactic
      ;; whitespace after the last token of the operator identifier."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (save-excursion
          (and (%c-langvar 'c-overloadable-operators-regexp)
               (= (c-backward-token-2 1 #f lim) 0)
               (let ((re (%c-langvar 'c-overloadable-operators-regexp)))
                 (and re (looking-at re)))
               (or (not (%c-langvar 'c-opt-op-identifier-prefix))
                   (and (= (c-backward-token-2 1 #f lim) 0)
                        (let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                          (and re (looking-at re)))))
               (point)))))

    (define (c-backward-to-block-anchor . lim-args)
      ;; "Assuming point is at a brace that opens a statement block of
      ;; some kind, move to the proper anchor point for that block.  It
      ;; might need to be adjusted further by c-add-stmt-syntax, but the
      ;; position at return is suitable as start position for that
      ;; function."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (unless (= (point) (c-point 'boi))
          (let ((start (c-after-conditional lim)))
            (if start
                (goto-char start))))))

    (define (c-backward-to-decl-anchor . lim-args)
      ;; "Assuming point is at a brace that opens the block of a top level
      ;; declaration of some kind, move to the proper anchor point for
      ;; that block."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (unless (= (point) (c-point 'boi))
          (c-beginning-of-statement-1 lim))))

    (define (c-search-decl-header-end)
      ;; "Search forward for the end of the \"header\" of the current
      ;; declaration.  That's the position where the definition body
      ;; starts, or the first variable initializer, or the ending
      ;; semicolon.  I.e. search forward for the closest following
      ;; (syntactically relevant) '{', '=' or ';' token.  Point is left
      ;; _after_ the first found token, or at point-max if none is found."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((base (point)))
        (if (c-major-mode-is 'c++-mode)

            ;; "In C++ we need to take special care to handle operator
            ;; tokens and those pesky template brackets."
            (let loop ()
              (when (and
                     (c-syntactic-re-search-forward "[;{<=]" #f 'move #t #t)
                     (or
                      (c-end-of-current-token base)
                      ;; "Handle operator identifiers, i.e. ignore any
                      ;; operator token preceded by \"operator\"."
                      (save-excursion
                        (and (c-safe (c-backward-sexp) #t)
                             (let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                               (and re (looking-at re)))))
                      (and (eqv? (char-before) #\<)
                           (if (c-safe (goto-char (c-up-list-forward (point))))
                               #t
                               (begin (goto-char (point-max))
                                      #f)))))
                (set! base (point))
                (loop)))

            (let loop ()
              (when (and
                     (c-syntactic-re-search-forward "[;{=]" #f 'move #t #t)
                     (c-end-of-current-token base))
                (set! base (point))
                (loop))))))

    (define (c-beginning-of-decl-1 . lim-args)
      ;; "Go to the beginning of the current declaration, or the beginning
      ;; of the previous one if already at the start of it.  Point won't
      ;; be moved out of any surrounding paren.  Return a cons cell of the
      ;; form (MOVE . KNR-POS).  MOVE is like the return value from
      ;; `c-beginning-of-statement-1'.  If point skipped over some K&R
      ;; style argument declarations (and they are to be recognized) then
      ;; KNR-POS is set to the start of the first such argument
      ;; declaration, otherwise KNR-POS is nil.  If LIM is non-nil, it's a
      ;; position that bounds the backward search."
      ;;
      ;; "NB: Cases where the declaration continues after the block, as in
      ;; \"struct foo { ... } bar;\", are currently recognized as two
      ;; declarations, e.g. \"struct foo { ... }\" and \"bar;\" in this
      ;; case."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f)))
        (call-with-current-continuation
         (lambda (return)
           (let* ((start (point))
                  (last-stmt-start (point))
                  (move (c-beginning-of-statement-1 lim #f #t))
                  (beg #f)
                  (tentative-move #f))

             ;; "`c-beginning-of-statement-1' stops at a block start, but we
             ;; want to continue if the block doesn't begin a top level
             ;; construct, i.e. if it isn't preceded by ';', '}', ':', bob,
             ;; or an open paren."
             (begin
               (set! beg (point))
               ;; "Go back one \"statement\" each time round the loop until
               ;; we're just after a ;, }, or :, or at BOB or the start of
               ;; a macro or start of an ObjC method.  This will move over
               ;; a multiple declaration whose components are comma
               ;; separated."
               (let loop ()
                 (when (and
                        ;; "Must check with c-opt-method-key in ObjC mode."
                        (not (let ((re (%c-langvar 'c-opt-method-key)))
                               (and re (looking-at re))))
                        (not (= last-stmt-start (point)))
                        (begin
                          (c-backward-syntactic-ws lim)
                          (not (or (memv (char-before)
                                         (list #\; #\} #\: #f))
                                   (c-at-vsemi-p))))
                        (not (and lim (<= (point) lim)))
                        (save-excursion
                          (backward-char)
                          (not (looking-at "\\s(")))
                        ;; "Check that we don't move from the first thing
                        ;; in a macro to its header."
                        (not (eq? (begin
                                    (set! tentative-move
                                          (c-beginning-of-statement-1 lim #f #t))
                                    tentative-move)
                                  'macro)))
                   (set! last-stmt-start beg)
                   (set! beg (point))
                   (set! move tentative-move)
                   (loop)))
               (goto-char beg))

             (when (%c-langvar 'c-recognize-knr-p)
               (let ((fallback-pos (point))
                     (knr-argdecl-start #f))
                 ;; "Handle K&R argdecls.  Back up after the \"statement\"
                 ;; jumped over by `c-beginning-of-statement-1', unless it
                 ;; was the function body, in which case we're sitting on
                 ;; the opening brace now.  Then test if we're in a K&R
                 ;; argdecl region and that we started at the other side of
                 ;; the first argdecl in it."
                 (unless (eqv? (char-after (point)) #\{)
                   (goto-char last-stmt-start))
                 (if (and (begin
                            (set! knr-argdecl-start (c-in-knr-argdecl lim))
                            knr-argdecl-start)
                          (< knr-argdecl-start start)
                          (begin
                            (goto-char knr-argdecl-start)
                            (not (eq? (c-beginning-of-statement-1 lim #f #t)
                                      'macro))))
                     (return (cons (if (eqv? (char-after fallback-pos) #\{)
                                       'previous
                                       'same)
                                   knr-argdecl-start))
                     (goto-char fallback-pos))))

             ;; "`c-beginning-of-statement-1' counts each brace block as a
             ;; separate statement, so the result will be 'previous if
             ;; we've moved over any.  So change our result back to 'same
             ;; if necessary."
             ;;
             ;; "If they were brace list initializers we might not have
             ;; moved over a declaration boundary though, so change it to
             ;; 'same if we've moved past a '=' before '{', but not ';'.
             ;; (This ought to be integrated into
             ;; `c-beginning-of-statement-1', so we avoid this extra pass
             ;; which potentially can search over a large amount of text.).
             ;; Take special pains not to get mislead by C++'s
             ;; \"operator=\", and the like."
             (if (and (eq? move 'previous)
                      (save-excursion
                        (and
                         (begin
                           ;; "keep going back to \"[;={\"s until we either
                           ;; find no more, or get to one which isn't an
                           ;; \"operator =\""
                           (let loop ()
                             (when (and (c-syntactic-re-search-forward
                                         "[;={]" start #t #t #t)
                                        (eqv? (char-before) #\=)
                                        (%c-langvar 'c-overloadable-operators-regexp)
                                        (%c-langvar 'c-opt-op-identifier-prefix)
                                        (save-excursion
                                          (= (c-backward-token-2) 0)
                                          (let ((re (%c-langvar 'c-overloadable-operators-regexp)))
                                            (and re (looking-at re)))
                                          (= (c-backward-token-2) 0)
                                          (let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                                            (and re (looking-at re)))))
                               (loop)))
                           (eqv? (char-before) #\=))
                         (c-syntactic-re-search-forward "[;{]" start #t #t)
                         (eqv? (char-before) #\{)
                         (c-safe (goto-char (c-up-list-forward (point))) #t)
                         (not (c-syntactic-re-search-forward
                               ";" start #t #t)))))
                 (cons 'same #f)
                 (cons move #f)))))))

    (define (c-end-of-decl-1)
      ;; "Assuming point is at the start of a declaration (as detected by
      ;; e.g. `c-beginning-of-decl-1'), go to the end of it.  Unlike
      ;; `c-beginning-of-decl-1', this function handles the case when a
      ;; block is followed by identifiers in e.g. struct declarations in C
      ;; or C++.  If a proper end was found then t is returned, otherwise
      ;; point is moved as far as possible within the current sexp and nil
      ;; is returned.  This function doesn't handle macros; use
      ;; `c-end-of-macro' instead in those cases."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((start (point)))
        (call-with-current-continuation
         (lambda (return)
           (c-search-decl-header-end)

           (when (and (%c-langvar 'c-recognize-knr-p)
                      (eqv? (char-before) #\;)
                      (c-in-knr-argdecl start))
             ;; "Stopped at the ';' in a K&R argdecl section which is
             ;; detected using the same criteria as in
             ;; `c-beginning-of-decl-1'.  Move to the following block
             ;; start."
             (c-syntactic-re-search-forward "{" #f 'move #t))

           (when (eqv? (char-before) #\{)
             ;; "Encountered a block in the declaration.  Jump over it."
             (guard (e (else (goto-char (point-max))
                             (return #f)))
               (goto-char (c-up-list-forward (point))))
             (if (or (not (%c-langvar 'c-opt-block-decls-with-vars-key))
                     (save-excursion
                       (let ((lim (point)))
                         (goto-char start)
                         (not (and
                               ;; "Check for
                               ;; `c-opt-block-decls-with-vars-key' before
                               ;; the first paren."
                               (c-syntactic-re-search-forward
                                (concat "[;=([{]\\|\\("
                                        (%c-langvar 'c-opt-block-decls-with-vars-key)
                                        "\\)")
                                lim #t #t #t)
                               (match-beginning 1)
                               (not (eqv? (char-before) #\_))
                               ;; "Check that the first following paren is
                               ;; the block."
                               (c-syntactic-re-search-forward
                                "[;=([{]" lim #t #t #t)
                               (eqv? (char-before) #\{))))))
                 ;; "The declaration doesn't have any of the
                 ;; `c-opt-block-decls-with-vars' keywords in the
                 ;; beginning, so it ends here at the end of the block."
                 (return #t)))

           (let loop ()
             (if (eqv? (char-before) #\;)
                 (return #t))
             (when (c-syntactic-re-search-forward ";" #f 'move #t)
               (loop)))
           #f))))
    ;;------------------------------------------------------------------
    ;; The declaration-block queries and the brace list
    ;; (`cc-engine.el:12966'-`:13582')
    ;;------------------------------------------------------------------
    ;; Emacs's file has these just before `c-looking-at-special-brace-list'
    ;; (`:13584'), which is already ported; they are appended here as the
    ;; tranche that follows it.
    ;;
    ;; The value-position rules apply throughout: every `when'/`unless'
    ;; whose value is read ends in an explicit `#f', and the two buffer
    ;; variables are slots behind accessors.

    (define (c-most-enclosing-decl-block paren-state)
      ;; "Return the buffer position of the most enclosing decl-block
      ;; brace (in the sense of c-looking-at-decl-block) in the
      ;; PAREN-STATE structure, or nil if none was found."
      ;; "Emacs's `c-pull-open-brace' is a macro that advances PS; this
      ;; tree's procedure answers (BRACE . REST), so each pull rebinds."
      (let* ((pull1 (c-pull-open-brace paren-state))
             (open-brace (car pull1))
             (ps1 (cdr pull1))
             (pull2 (c-pull-open-brace ps1))
             (next-open-brace (car pull2))
             (ps2 (cdr pull2)))
        (let loop ()
          (when (and open-brace
                     (save-excursion
                       (goto-char open-brace)
                       (not (c-looking-at-decl-block #f))))
            (set! open-brace next-open-brace)
            (let ((pull (c-pull-open-brace ps2)))
              (set! next-open-brace (car pull))
              (set! ps2 (cdr pull)))
            (loop)))
        open-brace))

    (define (c-cheap-inside-bracelist-p paren-state)
      ;; "Return the position of the L-brace if point is inside a brace
      ;; list initialization of an array, etc.  This is an approximate
      ;; function, designed for speed over accuracy. ... We simply search
      ;; for \"= {\" (naturally with syntactic whitespace allowed).
      ;; PAREN-STATE is the normal thing that it is everywhere else."
      (let ((b-pos #f)
            (ps paren-state))
        (save-excursion
          (let loop ()
            (when (begin
                    (let ((pull (c-pull-open-brace ps)))
                      (set! b-pos (car pull))
                      (set! ps (cdr pull)))
                    (and b-pos
                         (begin
                           (goto-char b-pos)
                           (c-backward-sws)
                           (c-backward-token-2)
                           (not (looking-at "=")))))
              (loop)))
          b-pos)))

    (define (c-backward-typed-enum-colon)
      ;; "We're at a \"{\" which might be the opening brace of an enum
      ;; which is strongly typed (by a \":\" followed by a type).  If this
      ;; is the case, leave point before the colon and return t.
      ;; Otherwise leave point unchanged and return nil.  Match data will
      ;; be clobbered."
      (let ((here (point))
            (colon-pos #f))
        (save-excursion
          (let loop ()
            (when (and (= (c-backward-token-2) 0)
                       (or (not (looking-at "\\s)"))
                           (c-go-up-list-backward))
                       (cond
                        ((looking-at "::")
                         #t)
                        ((and (eqv? (char-after (point)) #\:)
                              (save-excursion
                                (c-backward-syntactic-ws)
                                (or (c-on-identifier)
                                    (begin
                                      (c-backward-token-2)
                                      (let ((re (%c-langvar 'c-enum-list-key)))
                                        (and re (looking-at re)))))))
                         (set! colon-pos (point))
                         (forward-char)
                         (c-forward-syntactic-ws)
                         (or (and (c-forward-type)
                                  (begin (c-forward-syntactic-ws)
                                         (eqv? (point) here)))
                             (set! colon-pos #f))
                         #f)
                        ((eqv? (char-after (point)) #\()
                         #t)
                        ((let ((re (%c-langvar 'c-symbol-key)))
                           (and re (looking-at re)))
                         #t)
                        (else #f)))
              (loop))))
        ;; Emacs's `(when colon-pos (goto-char colon-pos) t)' is outside
        ;; the `save-excursion' - the move to the colon is the function's
        ;; point movement, and putting it inside made the `goto-char' be
        ;; undone on the way out.
        (if colon-pos
            (begin (goto-char colon-pos) #t)
            #f)))

    (define (c-backward-over-enum-header)
      ;; "We're at a \"{\".  Move back to the enum-like keyword that starts
      ;; this declaration and return t, otherwise don't move and return
      ;; nil."
      (let ((here (point))
            (before-identifier #f))
        (when (%c-langvar 'c-recognize-post-brace-list-type-p)
          (c-backward-typed-enum-colon))
        (let loop ()
          (when (and
                 (= (c-backward-token-2) 0)
                 (or (not (looking-at "\\s)"))
                     (c-go-up-list-backward))
                 (cond
                  ((and (let ((re (%c-langvar 'c-symbol-key)))
                          (and re (looking-at re)))
                        (c-on-identifier)
                        (not before-identifier))
                   (set! before-identifier #t))
                  ((and before-identifier
                        (or (eqv? (char-after (point)) #\,)
                            (let ((re (%c-langvar 'c-postfix-decl-spec-key)))
                              (and re (looking-at re)))))
                   (set! before-identifier #f)
                   #t)
                  ((let ((re (%c-langvar 'c-after-enum-list-key)))
                     (and re (looking-at re)))
                   #t)
                  ((let ((re (%c-langvar 'c-enum-list-key)))
                     (and re (looking-at re)))
                   #f)
                  ((eqv? (char-after (point)) #\()
                   (and (= (c-backward-token-2) 0)
                        (or (let ((re (%c-langvar 'c-decl-hangon-key)))
                              (and re (looking-at re)))
                            (and (%c-langvar 'c-opt-cpp-prefix)
                                 (let ((re (c-noise-macro-with-parens-name-re)))
                                   (and re (looking-at re)))))))
                  ((and (%c-langvar 'c-recognize-<>-arglists)
                        (eqv? (char-after (point)) #\<)
                        (looking-at "\\s("))
                   #t)
                  (else #f)))
            (loop)))
        (or (let ((re (%c-langvar 'c-enum-list-key)))
              (and re (looking-at re)))
            (begin (goto-char here) #f))))

    (define (c-at-enum-brace . pos-args)
      ;; "Return the position of the enum-like keyword introducing the
      ;; brace at POS (default point), or nil if we're not at such a
      ;; construct."
      (let ((pos (if (pair? pos-args) (car pos-args) #f)))
        (save-excursion
          (if pos
              (goto-char pos)
              (set! pos (point)))
          (and (c-backward-over-enum-header)
               (point)))))

    (define (c-laomib-loop lim)
      ;; "The \"expensive\" loop from `c-looking-at-or-maybe-in-bracelist'.
      ;; Move backwards over comma separated sexps as far as possible, but
      ;; no further than LIM, which may be nil, meaning no limit.  Return
      ;; the final value of `braceassignp', which is t if we encountered
      ;; \"= {\", usually nil otherwise."
      (let ((braceassignp 'dontknow)
            (class-key
             ;; "Pike can have class definitions anywhere, so we must check
             ;; for the class key here."
             (and (c-major-mode-is 'pike-mode)
                  (%c-langvar 'c-decl-block-key))))
        (let loop ()
          (when (eq? braceassignp 'dontknow)
            (cond
             ((or (eqv? (char-after (point)) #\;)
                  (save-excursion
                    (c-backward-syntactic-ws)
                    (c-at-vsemi-p)))
              (set! braceassignp #f))
             ((and class-key
                   (let ((re class-key)) (and re (looking-at re))))
              (set! braceassignp #f))
             ((and (%c-langvar 'c-has-compound-literals)
                   (let ((re (%c-langvar 'c-return-key)))
                     (and re (looking-at re))))
              (set! braceassignp #t))
             ((eqv? (char-after (point)) #\=)
              ;; "We've seen a =, but must check earlier tokens so that it
              ;; isn't something that should be ignored."
              (set! braceassignp 'maybe)
              (let inner ()
                (when (and (eq? braceassignp 'maybe)
                           (= (c-backward-token-2 1 #t lim) 0))
                  (set! braceassignp
                        (cond
                         ;; "Check for operator ="
                         ((and (%c-langvar 'c-opt-op-identifier-prefix)
                               (let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                                 (and re (looking-at re))))
                          #f)
                         ;; "Check for `<opchar>= in Pike."
                         ((and (c-major-mode-is 'pike-mode)
                               (or (eqv? (char-after (point)) #\`)
                                   ;; "Special case for Pikes `[]=, since '['
                                   ;; is not in the punctuation class."
                                   (and (eqv? (char-after (point)) #\[)
                                        (eqv? (char-before) #\`))))
                          #f)
                         ((looking-at "\\s.") 'maybe)
                         ;; "make sure we're not in a C++ template argument
                         ;; assignment"
                         ((and
                           (c-major-mode-is 'c++-mode)
                           (save-excursion
                             (let ((here (point))
                                   (pos< (begin
                                           (skip-chars-backward "^<>")
                                           (point))))
                               (and (eqv? (char-before) #\<)
                                    (not (c-crosses-statement-barrier-p
                                          pos< here))
                                    (not (c-in-literal))))))
                          #f)
                         (else #t)))
                  (inner))))
             ((and
               (c-major-mode-is 'c++-mode)
               (eqv? (char-after (point)) #\[)
               ;; "Be careful of \"operator []\""
               (not (save-excursion
                      (c-backward-token-2 1 #f lim)
                      (let ((re (%c-langvar 'c-opt-op-identifier-prefix)))
                        (and re (looking-at re))))))
              (set! braceassignp #t)))
            (when (eq? braceassignp 'dontknow)
              (cond ((and
                      (not (eqv? (char-after (point)) #\,))
                      (save-excursion
                        (c-backward-syntactic-ws)
                        (eqv? (char-before) #\})))
                     (set! braceassignp #f))
                    ((not (= (c-backward-token-2 1 #t lim) 0))
                     (if (save-excursion
                           (and (%c-langvar 'c-has-compound-literals)
                                (= (c-backward-token-2 1 #f lim) 0)
                                (eqv? (char-after (point)) #\()))
                         (set! braceassignp #t)
                         (set! braceassignp #f)))))
            (loop)))
        braceassignp))

    ;; "The following variable is a cache of up to four entries, each entry
    ;; of which is a list representing a call to c-laomib-loop."
    (define (c-laomib-cache)
      (buffer-local-value (current-buffer) 'c-laomib-cache '()))
    (define (set!c-laomib-cache value)
      (set-buffer-local-value! (current-buffer) 'c-laomib-cache value))

    (define (c-laomib-get-cache containing-sexp start)
      ;; "Get an element from `c-laomib-cache' matching CONTAINING-SEXP,
      ;; and which is suitable for start position START.  Return that
      ;; element or nil if one wasn't found."
      (let ((ptr (c-laomib-cache))
            (elt #f))
        (let loop ()
          (when (and (begin (set! elt (assv containing-sexp ptr)) elt)
                     (< start (car (cddr elt))))
            (set! ptr (cdr (memv elt ptr)))
            (loop)))
        (if elt
            (begin
              ;; "Move the fetched `elt' to the front of the cache."
              (set!c-laomib-cache (remq elt (c-laomib-cache)))
              (set!c-laomib-cache (cons elt (c-laomib-cache)))
              elt)
            #f)))

    (define (c-laomib-put-cache lim start end result)
      ;; "Insert a new element into `c-laomib-cache', removing another
      ;; element to make room, if necessary. ..."
      (if lim
          (begin
            (let ((old-elt #f)
                  (new-elt (list lim start end result))
                  (cur-ptr (c-laomib-cache))
                  (size 0))
              ;; "If there is an elt which overlaps with the new element,
              ;; remove it."
              (let loop ()
                (when (begin
                        (set! old-elt (assv lim cur-ptr))
                        (and old-elt
                             (not (and (> start (car (cddr old-elt)))
                                       (<= start (cadr old-elt))))))
                  (set! cur-ptr (cdr (memv old-elt cur-ptr)))
                  (loop)))
              (when (and cur-ptr old-elt)
                (set!c-laomib-cache (remq old-elt (c-laomib-cache))))

              ;; "Don't let the cache grow indefinitely." Emacs prefers
              ;; `ntake' (>= 29.1) and falls back on `butlast'; this tree
              ;; has no `ntake', so the fallback is the one path.
              (set! size (length (c-laomib-cache)))
              (when (>= size 50)
                (set!c-laomib-cache (butlast (c-laomib-cache) (- size 49))))
              (set!c-laomib-cache (cons new-elt (c-laomib-cache)))
              (c-laomib-cache))
          #f)))

    (define (c-laomib-fix-elt lwm elt paren-state)
      ;; "Correct a c-laomib-cache entry ELT with respect to buffer
      ;; changes, either doing nothing, signaling it is to be deleted, or
      ;; replacing its start point with one lower in the buffer than LWM.
      ;; PAREN-STATE is the paren state at LWM.  Return the corrected
      ;; entry, or nil (if it needs deleting). ..."
      (cond
       ((or (not lwm) (> lwm (cadr elt)))
        elt)
       ((<= lwm (nth 2 elt))
        #f)
       (else
        ;; "Search for the last brace in `paren-state' before (car
        ;; `lim').  This brace will become our new 2nd element of `elt'."
        (let loop ()
          ;; "Search one brace level per iteration."
          (when (and paren-state
                     (begin
                       ;; "Go past non-brace levels, one per iteration."
                       (let inner ()
                         (when (and paren-state
                                    (not (eqv? (char-after
                                                (c-state-cache-top-lparen paren-state))
                                               #\{)))
                           (set! paren-state (cdr paren-state))
                           (inner)))
                       (cadr paren-state))
                     (> (c-state-cache-top-lparen (cdr paren-state))
                        (car elt)))
            (set! paren-state (cdr paren-state))
            (loop)))
        (if (cadr paren-state)
            (begin
              (set-car! (cdr elt) (c-state-cache-top-lparen paren-state))
              elt)
            #f))))

    (define (c-laomib-invalidate-cache beg _end)
      ;; "Called from late in c-before-change.  Amend `c-laomib-cache' to
      ;; remove details pertaining to the buffer after position BEG."
      (save-excursion
        (goto-char beg)
        (let ((paren-state (c-parse-state)))
          (for-each (lambda (elt)
                      (when (not (c-laomib-fix-elt beg elt paren-state))
                        (set!c-laomib-cache (remq elt (c-laomib-cache)))))
                    (c-laomib-cache)))))

    (define (c-looking-at-or-maybe-in-bracelist . args)
      ;; "Point is at an open brace.  If this starts a brace list, return
      ;; a cons whose car is the buffer position of the start of the
      ;; construct which introduces the list, and whose cdr is the symbol
      ;; `in-paren' if the brace is directly enclosed in a parenthesis
      ;; form (i.e. an arglist), t if we have parsed a keyword matching
      ;; `c-opt-inexpr-brace-list-key' (e.g. Java's \"new\"), nil
      ;; otherwise.  Otherwise, if point might be inside an enclosing
      ;; brace list, return t.  If point is definitely neither at nor in
      ;; a brace list, return nil.
      ;;
      ;; CONTAINING-SEXP is the position of the brace/paren/bracket
      ;; enclosing POINT, or nil if there is no such position, or we do
      ;; not know it.  LIM is a backward search limit.
      ;;
      ;; Here, \"brace list\" does not include the body of an enum."
      (let ((containing-sexp (if (pair? args) (car args) #f))
            (lim (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (save-excursion
          (if (and (c-major-mode-is 'c++-mode)
                   (c-backward-over-lambda-expression lim))
              #f
              (let ((start (point))
                    (braceassignp 'dontknow)
                    (inexpr-brace-list #f)
                    (bufpos #f)
                    (macro-start #f)
                    (res #f)
                    (pos #f)
                    (after-type-id-pos #f)
                    (pos2 #f)
                    (in-paren #f)
                    (paren-state #f)
                    (paren-pos #f))
                ;; Elisp's `(char-after POS)' with POS nil means the
                ;; character at point; the tree's `char-after' wants a
                ;; position, so spell the nil case out.
                (define (char-at p)
                  (if p (char-after p) (char-after (point))))

                (set! res
                      (or (begin (c-backward-syntactic-ws)
                                 (c-back-over-compound-identifier))
                          (c-backward-token-2 1 #t lim)))
                ;; "Checks to do only on the first sexp before the brace.
                ;; Have we a C++ initialization, without an \"=\"?"
                (if (and (c-major-mode-is 'c++-mode)
                         (cond
                          ((and (or (not (memv res (list #t 0)))
                                    (eqv? (char-after (point)) #\,))
                                (begin (set! paren-state (c-parse-state))
                                       (pair? paren-state))
                                (begin
                                  (let ((pull (c-pull-open-brace paren-state)))
                                    (set! paren-pos (car pull))
                                    (set! paren-state (cdr pull)))
                                  paren-pos)
                                (eqv? (char-at paren-pos) #\())
                           (when paren-pos (goto-char paren-pos))
                           (set! braceassignp 'c++-noassign)
                           (set! in-paren 'in-paren))
                          ((let ((re (%c-langvar 'c-pre-brace-non-bracelist-key)))
                             (and re (looking-at re)))
                           (set! braceassignp #f)
                           #f)
                          ((let ((re (%c-langvar 'c-fun-name-substitute-key)))
                             (and re (looking-at re)))
                           (set! braceassignp #f)
                           #f)
                          ((let ((re (%c-langvar 'c-return-key)))
                             (and re (looking-at re))))
                          ((and (let ((re (%c-langvar 'c-symbol-start)))
                                  (and re (looking-at re)))
                                (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                       (and re (looking-at re)))))
                           (if (save-excursion
                                 (and (= (c-backward-token-2 1 #t lim) 0)
                                      (let ((re (%c-langvar 'c-pre-id-bracelist-key)))
                                        (and re (looking-at re)))))
                               (set! braceassignp 'c++-noassign)
                               (set! after-type-id-pos (point))))
                          ((eqv? (char-after (point)) #\()
                           ;; "Have we a requires with a parenthesis list?"
                           (when (save-excursion
                                   (and (= (c-backward-token-2 1 #f lim) 0)
                                        (let ((re (%c-langvar 'c-fun-name-substitute-key)))
                                          (and re (looking-at re)))))
                             (set! braceassignp #f))
                           #f)
                          (else #f))
                         (save-excursion
                           (cond
                            ((or (not (memv res (list #t 0)))
                                 (eqv? (char-after (point)) #\,))
                             (begin (set! paren-state (c-parse-state))
                                    (pair? paren-state))
                             (begin
                               (let ((pull (c-pull-open-brace paren-state)))
                                 (set! paren-pos (car pull))
                                 (set! paren-state (cdr pull)))
                               paren-pos)
                             (eqv? (char-at paren-pos) #\()
                             (set! in-paren 'in-paren)
                             (when paren-pos (goto-char paren-pos))
                             #t)
                            ((let ((re (%c-langvar 'c-pre-brace-non-bracelist-key)))
                               (and re (looking-at re))))
                            ((let ((re (%c-langvar 'c-return-key)))
                               (and re (looking-at re))))
                            ((and (let ((re (%c-langvar 'c-symbol-start)))
                                    (and re (looking-at re)))
                                  (not (let ((re (%c-langvar 'c-keywords-regexp)))
                                         (and re (looking-at re))))
                                  (save-excursion
                                    (and (= (c-backward-token-2 1 #t lim) 0)
                                         (let ((re (%c-langvar 'c-pre-id-bracelist-key)))
                                           (and re (looking-at re)))))))
                            (else (set! after-type-id-pos (point))
                                  #f))))
                    (set! braceassignp 'c++-noassign))

                (when (and (%c-langvar 'c-opt-inexpr-brace-list-key)
                           (eqv? (char-after (point)) #\[))
                  ;; "In Java, an initialization brace list may follow
                  ;; directly after \"new Foo[]\", so check for a \"new\"
                  ;; earlier."
                  (let loop ()
                    (when (eq? braceassignp 'dontknow)
                      (set! braceassignp
                            (cond ((not (= (c-backward-token-2 1 #t lim) 0)) #f)
                                  ((let ((re (%c-langvar 'c-opt-inexpr-brace-list-key)))
                                     (and re (looking-at re)))
                                   (set! inexpr-brace-list #t)
                                   #t)
                                  ((looking-at "\\sw\\|\\s_\\|[.[]")
                                   ;; "Carry on looking if this is an
                                   ;; identifier (may contain \".\" in Java)
                                   ;; or another \"[]\" sexp."
                                   'dontknow)
                                  (else #f)))
                      (loop))))

                (set! pos (point))
                (cond
                 ((not braceassignp)
                  #f)
                 ((and after-type-id-pos
                       (begin (goto-char after-type-id-pos) #t)
                       (begin (set! res (c-back-over-member-initializers)) res)
                       (begin (goto-char res) #t)
                       (eq? (car (c-beginning-of-decl-1 lim)) 'same))
                  (cons (point) #f)) ; "Return value."
                 ((and after-type-id-pos
                       (begin
                         (c-backward-syntactic-ws)
                         (eqv? (char-before) #\()))
                  ;; "Single identifier between '(' and '{'.  We have a
                  ;; bracelist."
                  (cons after-type-id-pos 'in-paren))
                 (else
                  (goto-char pos)
                  (when (eq? braceassignp 'dontknow)
                    (let* ((cache-entry (and containing-sexp
                                             (c-laomib-get-cache containing-sexp pos)))
                           (lim2 (or (and cache-entry (cadr cache-entry)) lim))
                           (sub-bassign-p #f))
                      (if cache-entry
                          (cond
                           ((<= (point) (cadr cache-entry))
                            ;; "We're inside the region we've already scanned
                            ;; over, so just go to that scan's end position."
                            (goto-char (nth 2 cache-entry))
                            (set! braceassignp (nth 3 cache-entry)))
                           ((> (point) (cadr cache-entry))
                            ;; "We're beyond the previous scan region, so just
                            ;; scan as far as the end of that region."
                            (set! sub-bassign-p (c-laomib-loop lim2))
                            (if (<= (point) (cadr cache-entry))
                                (begin
                                  (set-car! (cdr cache-entry) start)
                                  (set! braceassignp (nth 3 cache-entry))
                                  (goto-char (nth 2 cache-entry)))
                                (begin
                                  (c-laomib-put-cache containing-sexp
                                                       start (point) sub-bassign-p)
                                  (set! braceassignp sub-bassign-p))))
                           (else #f))
                          (begin
                            (set! braceassignp (c-laomib-loop lim))
                            (when lim
                              (c-laomib-put-cache lim start (point)
                                                  braceassignp))))))

                  (cond
                   (braceassignp
                    ;; "We've hit the beginning of the aggregate list."
                    (set! pos2 (point))
                    (cons
                     (if (eq? (c-beginning-of-statement-1 containing-sexp) 'same)
                         (point)
                         pos2)
                     (or in-paren inexpr-brace-list)))
                   ((and after-type-id-pos
                         (save-excursion
                           (when (eqv? (char-after (point)) #\;)
                             (c-forward-over-token-and-ws #t))
                           (set! bufpos (point))
                           (when (let ((re (%c-langvar 'c-opt-<>-sexp-key)))
                                   (and re (looking-at re)))
                             (c-forward-over-token-and-ws)
                             (when (and (eqv? (char-after (point)) #\<)
                                        (c-get-char-property (point) 'syntax-table))
                               (c-go-list-forward #f after-type-id-pos)
                               (c-forward-syntactic-ws)))
                           (if (and (not (eqv? (point) after-type-id-pos))
                                    (or (not (let ((re (%c-langvar 'c-class-key)))
                                               (and re (looking-at re))))
                                        (save-excursion
                                          (goto-char (match-end 1))
                                          (c-forward-syntactic-ws)
                                          (not (eqv? (point) after-type-id-pos)))))
                               (begin
                                 (set! res
                                       (c-forward-decl-or-cast-1 (c-point 'bosws)
                                                                 #f #f))
                                 (and (pair? res)
                                      (cond
                                       ((eqv? (car res) after-type-id-pos)
                                        #t)
                                       ((> (car res) after-type-id-pos)
                                        #f)
                                       (else
                                        (call-with-current-continuation
                                         (lambda (find-decl)
                                           (save-excursion
                                             (goto-char (car res))
                                             (c-do-declarators
                                              (point-max) #t #f #f
                                              (lambda (id-start _id-end _tok
                                                       _not-top _func _init)
                                                (cond
                                                 ((> id-start after-type-id-pos)
                                                  (find-decl #f))
                                                 ((eqv? id-start after-type-id-pos)
                                                  (find-decl #t)))))
                                           #f)))))))
                               (save-excursion
                                 (goto-char start)
                                 (not (c-looking-at-statement-block))))))
                    (cons bufpos (or in-paren inexpr-brace-list)))
                   ((or (eqv? (char-after (point)) #\;)
                        ;; "Brace lists can't contain a semicolon, so we're
                        ;; done."
                        (save-excursion
                          (c-backward-syntactic-ws)
                          (eqv? (char-before) #\})))
                    ;; "They also can't contain a bare }, which is probably
                    ;; the end of a function."
                    #f)
                   ((and (begin (set! macro-start (point)) macro-start)
                         (c-forward-to-cpp-define-body)
                         (eqv? (point) start))
                    ;; "We've a macro whose expansion starts with the '{'.
                    ;; Heuristically, if we have a ';' in it we've not got a
                    ;; brace list, otherwise we have."
                    (let ((macro-end (begin (c-end-of-macro) (point))))
                      (goto-char start)
                      (forward-char)
                      (if (and (c-syntactic-re-search-forward "[;,]" macro-end #t #t)
                               (eqv? (char-before) #\;))
                          #f
                          (cons macro-start #f))))
                   (else #t)))))))))


    ;; "A list of the form returned by `c-parse-state', but without conses.
    ;; Each opening brace in it is not the brace of a brace list."
    (define (c-no-bracelist-cache)
      (buffer-local-value (current-buffer) 'c-no-bracelist-cache '()))
    (define (set!c-no-bracelist-cache value)
      (set-buffer-local-value! (current-buffer) 'c-no-bracelist-cache value))

    (define (c-strip-conses liszt)
      ;; "Make a copy of the list LISZT, removing conses from the copy.
      ;; Return the result."
      (let ((ptr liszt)
            (new '()))
        (let loop ()
          (when (pair? ptr)
            (when (not (pair? (car ptr)))
              (set! new (cons (car ptr) new)))
            (set! ptr (cdr ptr))
            (loop)))
        (reverse new)))

    (define (c-at-bracelist-p containing-sexp paren-state)
      ;; "Try to return the buffer position of the beginning of the brace
      ;; list statement whose brace block begins at CONTAINING-SEXP,
      ;; otherwise return nil.  If the code cannot determine whether we're
      ;; at a brace block, return nil. ..."
      (save-excursion
        (let ((bufpos #t)
              (next-containing #f)
              (non-brace-pos #f)
              (whole-paren-state (cons containing-sexp paren-state))
              (current-brace containing-sexp))
          (let loop ()
            (when (and (eq? bufpos #t)
                       current-brace
                       (not (memv current-brace (c-no-bracelist-cache))))
              (set! next-containing
                    (and paren-state
                         (let ((pull (c-pull-open-brace paren-state)))
                           (set! paren-state (cdr pull))
                           (car pull))))
              (goto-char current-brace)
              (cond
               ((c-looking-at-inexpr-block next-containing next-containing)
                ;; "We're in an in-expression block of some kind.  Do not
                ;; check nesting. ..."
                (set! bufpos #f))
               ((not (eqv? (char-after (point)) #\{))
                (set! non-brace-pos (point))
                (set! bufpos #f))
               ((eq? (begin
                       (set! bufpos (c-looking-at-or-maybe-in-bracelist
                                     next-containing next-containing))
                       bufpos)
                     #t)
                (set! current-brace next-containing)))
              (loop)))
          (cond
           ((pair? bufpos)
            (and (not (eq? (cdr bufpos) 'in-paren))
                 (car bufpos)))
           (non-brace-pos
            ;; "We've encountered a ( or a [.  Remove the \"middle part\"
            ;; of paren-state, the part that isn't non-brace-list braces,
            ;; to get the new value of `c-no-bracelist-cache'."
            (set! whole-paren-state
                  ;; "`c-whack-state-before' makes a copy of
                  ;; `whole-paren-state'."
                  (c-whack-state-before (1+ non-brace-pos) whole-paren-state))
            (let loop ()
              (when (and next-containing
                         (not (memv next-containing (c-no-bracelist-cache))))
                (let ((pull (c-pull-open-brace paren-state)))
                  (set! next-containing (car pull))
                  (set! paren-state (cdr pull)))
                (loop)))
            (set!c-no-bracelist-cache
             (nconc (c-strip-conses whole-paren-state)
                    (and next-containing (list next-containing))
                    paren-state))
            #f)
           ((not (memv containing-sexp (c-no-bracelist-cache)))
            ;; "Update `c-no-bracelist-cache'"
            (set!c-no-bracelist-cache (c-strip-conses whole-paren-state))
            #f)
           ;; Emacs's `cond' answers nil with no matching clause.
           (else #f)))))
    ;;------------------------------------------------------------------
    ;; `cc-engine.el:657': `c-literal-faces'
    ;;------------------------------------------------------------------
    ;; "Faces given to comments and string literals.  This is used in
    ;; some situations to speed up recognition; it isn't mandatory that
    ;; font locking is in use.  This variable is extended with the face in
    ;; `c-doc-face-name' when fontification is activated in cc-fonts.el."
    ;;
    ;; A plain variable: Emacs `defvar's it and nothing `let'-binds it.
    ;; cc-fonts `setq's it, which is why the self-assignment marks it
    ;; mutable against the compiler's constant folding.
    (define c-literal-faces
      (append (list 'font-lock-comment-face 'font-lock-string-face)
              (if (facep 'font-lock-comment-delimiter-face)
                  (list 'font-lock-comment-delimiter-face)
                  '())))
    (set! c-literal-faces c-literal-faces)

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:5805': `c-collect-line-comments'
    ;;------------------------------------------------------------------
    (define (c-collect-line-comments range)
      ;; "If the argument is a cons of two buffer positions (such as
      ;; returned by `c-literal-limits'), and that range contains a C++
      ;; style line comment, then an extended range is returned that
      ;; contains all adjacent line comments (i.e. all comments that
      ;; starts in the same column with no empty lines or non-whitespace
      ;; characters between them).  Otherwise the argument is returned."
      ;;
      ;; "Note that this function might do hidden buffer changes."
      ;;
      ;; Emacs's `condition-case nil ... (error range)': `guard' is this
      ;; tree's, and a quit is re-raised because `condition-case' with an
      ;; `error' handler does not catch one.
      (save-excursion
        (guard (e ((quit-condition? e) (raise e))
                  (else range))
          (if (and (pair? range)
                   (begin
                     (goto-char (car range))
                     (let ((re (%c-langvar 'c-line-comment-starter)))
                       (and re (looking-at re)))))
              (let ((col (current-column))
                    (beg (point))
                    (bopl (c-point 'bopl))
                    (end (cdr range)))
                ;; "Got to take care in the backward direction to handle
                ;; comments which are preceded by code."
                (while (and (c-backward-single-comment)
                            (>= (point) bopl)
                            (let ((re (%c-langvar 'c-line-comment-starter)))
                              (and re (looking-at re)))
                            (= col (current-column)))
                  (setq beg (point)
                        bopl (c-point 'bopl)))
                (goto-char end)
                (while (and (begin
                              (skip-chars-forward " \t")
                              (let ((re (%c-langvar 'c-line-comment-starter)))
                                (and re (looking-at re))))
                            (= col (current-column))
                            (prog1 (zero? (forward-line 1))
                              (setq end (point)))))
                (cons beg end))
              range))))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:6027'-`:6042': the find-decl cache
    ;;------------------------------------------------------------------
    ;; "`c-find-decl-syntactic-pos' is a syntactically relevant position in
    ;; the syntactic whitespace less or equal to some start position.
    ;; There's no cached value if it's nil."
    (define (c-find-decl-syntactic-pos)
      (buffer-local-value (current-buffer) 'c-find-decl-syntactic-pos #f))
    (define (set!c-find-decl-syntactic-pos value)
      (set-buffer-local-value! (current-buffer)
                               'c-find-decl-syntactic-pos value))
    ;; "`c-find-decl-match-pos' is the match position if
    ;; `c-find-decl-prefix-search' matched before the syntactic whitespace
    ;; at `c-find-decl-syntactic-pos', or nil if there's no such match."
    (define (c-find-decl-match-pos)
      (buffer-local-value (current-buffer) 'c-find-decl-match-pos #f))
    (define (set!c-find-decl-match-pos value)
      (set-buffer-local-value! (current-buffer) 'c-find-decl-match-pos value))

    (define (c-invalidate-find-decl-cache change-min-pos)
      (and (c-find-decl-syntactic-pos)
           (< change-min-pos (c-find-decl-syntactic-pos))
           (begin (set!c-find-decl-syntactic-pos #f) #f)))

    ;; `cc-engine.el:6052': a debug macro whose body is
    ;; `(when (facep 'c-debug-decl-spot-face) ...)`.  The defface is
    ;; commented out in Emacs itself, so the macro expands to nil there
    ;; too; this is the same answer, written out.
    (define-syntax c-debug-put-decl-spot-faces
      (syntax-rules ()
        ((_ match-pos decl-pos) #f)))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:6111'-`:6285': the brace-stack cache
    ;;------------------------------------------------------------------
    ;; "Machinery for determining when we're at top level (this including
    ;; being directly inside a class or namespace, etc.)."
    ;;
    ;; "We maintain a stack of brace depths in structures like classes and
    ;; namespaces.  The car of this structure, when non-nil, indicates
    ;; that the associated position is within a template (etc.) structure,
    ;; and the value is the position where the (outermost) template ends.
    ;; The other elements in the structure are stacked elements, one each
    ;; for each enclosing \"top level\" structure."
    ;;
    ;; "At the very outermost level, the value of the stack would be (nil
    ;; 1), the \"1\" indicating an enclosure in a notional all-enclosing
    ;; block.  After passing a keyword such as \"namespace\", the value
    ;; would become (nil 0 1).  At this point, passing a semicolon would
    ;; cause the 0 to be dropped from the stack ... There is a special
    ;; stack value -1 which means the C++ colon operator introducing a
    ;; list of inherited classes has just been parsed."
    ;;
    ;; "The values of this stack throughout a buffer are cached in a
    ;; simple linear cache, every 5000 characters."  (Emacs's comment says
    ;; 5000; `c-bs-interval' is 2000 - the constant is the code.)
    (define c-bs-interval 2000)

    (define (c-bs-cache)
      (buffer-local-value (current-buffer) 'c-bs-cache '()))
    (define (set!c-bs-cache value)
      (set-buffer-local-value! (current-buffer) 'c-bs-cache value))
    (define (c-bs-cache-limit)
      (buffer-local-value (current-buffer) 'c-bs-cache-limit 1))
    (define (set!c-bs-cache-limit value)
      (set-buffer-local-value! (current-buffer) 'c-bs-cache-limit value))
    (define (c-bs-prev-pos)
      (buffer-local-value (current-buffer) 'c-bs-prev-pos
                          most-positive-fixnum))
    (define (set!c-bs-prev-pos value)
      (set-buffer-local-value! (current-buffer) 'c-bs-prev-pos value))
    (define (c-bs-prev-stack)
      (buffer-local-value (current-buffer) 'c-bs-prev-stack #f))
    (define (set!c-bs-prev-stack value)
      (set-buffer-local-value! (current-buffer) 'c-bs-prev-stack value))

    (define (c-init-bs-cache)
      ;; "Initialize the cache in `c-bs-cache' and related variables."
      (set!c-bs-cache '())
      (set!c-bs-cache-limit 1)
      (set!c-bs-prev-pos most-positive-fixnum)
      (set!c-bs-prev-stack #f))

    (define (c-truncate-bs-cache pos . ignore)
      ;; "Truncate the upper bound of the cache `c-bs-cache' to POS, if it
      ;; is higher than that position.  This is called as either a before-
      ;; or after-change-function."
      (set!c-bs-cache-limit (min (c-bs-cache-limit) pos)))

    (define (c-update-brace-stack stack from to)
      ;; "Given a brace-stack which has the value STACK at position FROM,
      ;; update it to its value at position TO, where TO is after (or
      ;; equal to) FROM.  Return a cons of either TO (if it is outside a
      ;; literal) and this new value, or of the next position after TO
      ;; outside a literal and the new value."
      (let ((match #f) (kwd-sym #f) (prev-match-pos 1)
            (s (cdr stack))
            (bound-<> (car stack)))
        (save-excursion
          (cond
           ((and bound-<> (<= to bound-<>))
            (goto-char to))                     ; "Nothing to do."
           (bound-<>
            (goto-char bound-<>)
            (setq bound-<> #f))
           (else (goto-char from)))
          (while (and (< (point) to)
                      (c-syntactic-re-search-forward
                       (if (<= (car s) 0)
                           (%c-langvar 'c-brace-stack-thing-key)
                           (%c-langvar 'c-brace-stack-no-semi-key))
                       to 'after-literal)
                      (> (point) prev-match-pos)) ; "prevent infinite loop."
            (setq prev-match-pos (point))
            (setq match (match-string-no-properties 1))
            (setq kwd-sym (c-keyword-sym match))
            (cond
             ((and (equal? match "{")
                   (begin (backward-char)
                          (prog1 (looking-at "\\s(")
                            (forward-char))))
              (setq s (if (pair? s)
                          (cons (if (<= (car s) 0)
                                    1
                                    (+ 1 (car s)))
                                (cdr s))
                          (list 1))))
             ((and (equal? match "}")
                   (begin (backward-char)
                          (prog1 (looking-at "\\s)")
                            (forward-char))))
              (setq s
                    (cond
                     ((and (pair? s) (> (car s) 1))
                      (cons (- (car s) 1) (cdr s)))
                     ((and (pair? (cdr s)) (eqv? (car s) 1))
                      (cdr s))
                     (else s))))
             ((and (equal? match "<")
                   (begin (backward-char)
                          (prog1 (looking-at "\\s(")
                            (forward-char))))
              (backward-char)
              (if (parameterize ((*c-parse-and-markup-<>-arglists* #t)
                                 (*c-restricted-<>-arglists* #f))
                    (c-forward-<>-arglist #f)) ; "Should always work."
                  (when (> (point) to)
                    (setq bound-<> (point)))
                  (forward-char)))
             ((and (equal? match ":")
                   (pair? s)
                   (eqv? (car s) 0))
              (setq s (cons -1 (cdr s))))
             ((and (equal? match ",")
                   (eqv? (car s) -1))
              #f)                               ; "at \",\" in \"class foo : bar, ...\""
             ((member match (list ";" "*" "," ")"))
              (when (and (pair? s) (pair? (cdr s)) (<= (car s) 0))
                (setq s (cdr s))))
             ((c-keyword-member kwd-sym 'c-flat-decl-block-kwds)
              (push 0 s))))
          (when (> prev-match-pos 1)            ; "Has the search matched at least once?"
            ;; "The failing `c-syntactic-re-search-forward' may have left
            ;; us in the middle of a token, which might be a significant
            ;; token.  Fix this!"
            (c-beginning-of-current-token))
          (cons (point)
                (cons bound-<> s)))))

    (define (c-brace-stack-at here)
      ;; "Given a buffer position HERE, Return the value of the brace
      ;; stack there."
      (save-excursion
        (save-restriction
          (widen)
          ;; Emacs `let'-binds `c-record-type-identifiers' so
          ;; `c-forward-<>-arglist' does not record identifiers outside
          ;; the restriction in force before this function.
          (parameterize ((*c-record-type-identifiers* #f))
            (let ((c (c-bs-cache))
                  (can-use-prev (<= (c-bs-prev-pos) (c-bs-cache-limit)))
                  (elt #f) (stack #f) (pos #f) (npos #f) (high-elt #f))
              ;; "Trim the cache to take account of buffer changes."
              (while (and (pair? c)
                          (> (car (car c)) (c-bs-cache-limit)))
                (setq c (cdr c)))
              (set!c-bs-cache c)

              (while (and (pair? c)
                          (> (car (car c)) here))
                (setq high-elt (car c))
                (setq c (cdr c)))
              (setq pos (or (and (pair? c) (car (car c)))
                            (point-min)))

              (setq elt (if (pair? c)
                            (car c)
                            (cons (point-min)
                                  (cons #f (list 1)))))
              (unless high-elt
                (setq stack (cdr elt))
                (while
                    ;; "Add an element to `c-bs-cache' each iteration."
                    (<= (setq npos (+ pos c-bs-interval)) here)
                  (setq elt (c-update-brace-stack stack pos npos))
                  (setq npos (car elt))
                  (setq stack (cdr elt))
                  (unless (eqv? npos (point-max)) ; "NPOS could be in a literal at EOB."
                    (set!c-bs-cache (cons elt (c-bs-cache))))
                  (setq pos npos)))

              (when (> pos (c-bs-cache-limit))
                (set!c-bs-cache-limit pos))

              ;; "Can we just use the previous value?"
              (if (and can-use-prev
                       (<= (c-bs-prev-pos) here)
                       (> (c-bs-prev-pos) (car elt)))
                  (setq pos (c-bs-prev-pos)
                        stack (c-bs-prev-stack))
                  (setq pos (car elt)
                        stack (cdr elt)))
              (when (> here (c-bs-cache-limit))
                (set!c-bs-cache-limit here))
              ;; Emacs's one `setq' sets a buffer-local variable
              ;; directly; here each is behind its accessor's setter.
              (setq elt (c-update-brace-stack stack pos here))
              (set!c-bs-prev-pos (car elt))
              (set!c-bs-prev-stack (cdr elt)))))))

    (define (c-bs-at-toplevel-p here)
      ;; "Is position HERE at the top level, as indicated by the brace
      ;; stack?"
      (let ((stack (c-brace-stack-at here)))
        (or (null? stack)                       ; "Probably unnecessary."
            (<= (car (cdr stack)) 1))))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:6286': `c-find-decl-prefix-search'
    ;;------------------------------------------------------------------
    ;; This is a macro in Emacs for the same reason it is one here: it
    ;; sets and reads variables that `c-find-decl-spots' binds around it.
    ;; Those are Emacs `let' variables, so they are parameters in this
    ;; tree, and the macro reads and sets them with `setq'.
    (define *cfd-limit* (make-parameter #f))
    (define *cfd-prop-match* (make-parameter #f))
    (define *cfd-re-match* (make-parameter #f))
    (define *cfd-re-match-end* (make-parameter #f))
    (define *cfd-match-pos* (make-parameter #f))
    (define *cfd-continue-pos* (make-parameter #f))
    (define *cfd-top-level* (make-parameter #f))

    (define-syntax c-find-decl-prefix-search
      ;; "The macro moves point forward to the next putative start of a
      ;; declaration or cfd-limit.  This decl start is the next token
      ;; after a \"declaration prefix\".  The declaration prefix is the
      ;; earlier of `cfd-prop-match' and `cfd-re-match'.  `cfd-match-pos'
      ;; is set to the decl prefix."
      ;;
      ;; "The variables which this macro should set for
      ;; `c-find-decl-spots' are `cfd-match-pos' and `cfd-continue-pos'."
      ;;
      ;; "This macro might do hidden buffer changes."
      (syntax-rules ()
        ((_)
         (begin
           ;; "Find the next property match position if we haven't got one
           ;; already."
           (unless (*cfd-prop-match*)
             (save-excursion
               (while (begin
                        (goto-char (c-next-single-property-change
                                    (point) 'c-type #f (*cfd-limit*)))
                        (and (< (point) (*cfd-limit*))
                             (not (eqv? (c-get-char-property
                                         (- (point) 1) 'c-type)
                                        'c-decl-end)))))
               (setq *cfd-prop-match* (point))))

           ;; "Find the next `c-decl-prefix-or-start-re' match if we
           ;; haven't got one already."
           (unless (*cfd-re-match*)

             (if (> (*cfd-re-match-end*) (point))
                 (goto-char (*cfd-re-match-end*)))

             ;; "Each time round, the next `while' moves forward over a
             ;; pseudo match of `c-decl-prefix-or-start-re' which is
             ;; either inside a literal, or is a \":\" not preceded by
             ;; \"public\", etc..  `cfd-re-match' and `cfd-re-match-end'
             ;; get set."
             (while
                 (begin
                   (setq *cfd-re-match-end*
                         (re-search-forward
                          (%c-langvar 'c-decl-prefix-or-start-re)
                          (*cfd-limit*) 'move))
                   (cond
                    ((not (*cfd-re-match-end*))
                     ;; "No match.  Finish up and exit the loop."
                     (setq *cfd-re-match* (*cfd-limit*))
                     #f)
                    ((c-got-face-at
                      (if (setq *cfd-re-match*
                                (or (match-end 1)
                                    (and (let ((d (%c-langvar
                                                   'c-dposr-cpp-macro-depth)))
                                           (and d (match-end (+ 1 d)))))))
                          ;; "Matched the end of a token preceding a decl
                          ;; spot."
                          (begin (goto-char (*cfd-re-match*))
                                 (- (*cfd-re-match*) 1))
                          ;; "Matched a token that start a decl spot."
                          (begin
                            (goto-char (match-beginning 0))
                            (point)))
                      c-literal-faces)
                     ;; "Pseudo match inside a comment or string literal.
                     ;; Skip out of comments and string literals."
                     (while
                         (begin
                           (unless
                               (and
                                (or (match-end 1)
                                    (and (let ((d (%c-langvar
                                                   'c-dposr-cpp-macro-depth)))
                                           (and d (match-end (+ 1 d)))))
                                (c-got-face-at (- (point) 1)
                                               c-literal-faces)
                                (not (c-got-face-at (point)
                                                    c-literal-faces)))
                             (goto-char
                              (c-next-single-property-change
                               (point) 'face #f (*cfd-limit*))))
                           (and (< (point) (*cfd-limit*))
                                (c-got-face-at (point)
                                               c-literal-faces)))))
                     #t)    ; "Continue the loop over pseudo matches."
                    ((and (%c-langvar 'c-opt-identifier-concat-key)
                          (match-string 1)
                          (save-excursion
                            (goto-char (match-beginning 1))
                            (save-match-data
                              (let ((re (%c-langvar
                                         'c-opt-identifier-concat-key)))
                                (and re (looking-at re))))))
                     ;; "Found, e.g., \"::\" in C++"
                     #t)
                    ((and (match-string 1)
                          (string=? (match-string 1) ":")
                          (save-excursion
                            (or (not (= (c-backward-token-2 2) 0)) ; "no search limit.  :-("
                                (not (let ((re (%c-langvar
                                                'c-decl-start-colon-kwd-re)))
                                       (and re (looking-at re)))))))
                     ;; "Found a \":\" which isn't part of \"public:\",
                     ;; etc."
                     #t)
                    (else #f))))    ; "Found a real match."

             ;; "If our match was at the decl start, we have to back up
             ;; over the preceding syntactic ws to set `cfd-match-pos' and
             ;; to catch any decl spots in the syntactic ws."
             (unless (*cfd-re-match*)
               (let ((cfd-cbsw-lim (max (- (point) 1000)
                                        (point-min))))
                 (c-backward-syntactic-ws cfd-cbsw-lim)
                 (setq *cfd-re-match*
                       (if (or (bobp) (> (point) cfd-cbsw-lim))
                           (point)
                           (point-min)))))) ; "Set BOB case if the token's too far back."

           ;; "Choose whichever match is closer to the start."
           (if (< (*cfd-re-match*) (*cfd-prop-match*))
               (begin (setq *cfd-match-pos* (*cfd-re-match*))
                      (setq *cfd-re-match* #f))
               (begin (setq *cfd-match-pos* (*cfd-prop-match*))
                      (setq *cfd-prop-match* #f)))
           (setq *cfd-top-level* (c-bs-at-toplevel-p (*cfd-match-pos*)))
           (goto-char (*cfd-match-pos*))
           (when (< (*cfd-match-pos*) (*cfd-limit*))
             ;; "Skip forward past comments only so we don't skip macros."
             (while
                 (begin
                   (c-forward-comments)
                   ;; "The following is of use within a doc comment when a
                   ;; doc comment style has removed face properties from a
                   ;; construct, and is relying on
                   ;; `c-font-lock-declarations' to add them again."
                   (cond
                    ((let ((re (%c-langvar 'c-noise-macro-name-re)))
                       (and re (looking-at re)))
                     (c-forward-noise-clause-not-macro-decl #f)) ; "Returns t."
                    ((let ((re (c-noise-macro-with-parens-name-re)))
                       (and re (looking-at re)))
                     (c-forward-noise-clause-not-macro-decl #t)) ; "Always returns t."
                    ((and (< (point) (*cfd-limit*))
                          (let ((re (c-doc-line-join-re)))
                            (and re (looking-at re))))
                     (goto-char (match-end 0)))
                    (else #f))))
             ;; "Set the position to continue at.  We can avoid going over
             ;; the comments skipped above a second time, but it's
             ;; possible that the comment skipping has taken us past
             ;; `cfd-prop-match' since the property might be used inside
             ;; comments."
             (setq *cfd-continue-pos* (if (*cfd-prop-match*)
                                          (min (*cfd-prop-match*) (point))
                                          (point))))))))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:6428': `c-find-decl-spots'
    ;;------------------------------------------------------------------
    (define (c-find-decl-spots cfd-limit cfd-decl-re cfd-face-checklist cfd-fun)
      ;; "Call CFD-FUN for each possible spot for a declaration, cast or
      ;; label from the point to CFD-LIMIT."
      ;;
      ;; "CFD-FUN is called with point at the start of the spot.  It's
      ;; passed three arguments: The first is the end position of the
      ;; token preceding the spot, or 0 for the implicit match at bob.
      ;; The second is a flag that is t when the match is inside a macro.
      ;; The third is a flag that is t when the match is at \"top level\",
      ;; i.e. outside any brace block, or directly inside a class or
      ;; namespace, etc.  Point should be moved forward by at least one
      ;; token."
      ;;
      ;; "If CFD-FUN adds `c-decl-end' properties somewhere below the
      ;; current spot, it should return non-nil to ensure that the next
      ;; search will find them."
      ;;
      ;; "Such a spot is: ..."
      ;;
      ;; "Only a spot that match CFD-DECL-RE and whose face is in the
      ;; CFD-FACE-CHECKLIST list causes CFD-FUN to be called.  The face
      ;; check is disabled if CFD-FACE-CHECKLIST is nil."
      ;;
      ;; "This is mainly used in fontification, and so has an elaborate
      ;; cache to handle repeated calls from the same start position; see
      ;; the variables above."
      ;;
      ;; "All variables in this function begin with `cfd-' to avoid name
      ;; collision with the (dynamically bound) variables used in CFD-FUN."
      ;;
      ;; "This function might do hidden buffer changes."
      ;;
      ;; Emacs's `let' of the cfd variables is `parameterize' here;
      ;; `cfd-start-pos', `cfd-buffer-end', `cfd-token-pos' and
      ;; `cfd-macro-end' are not read by the macro, so they are ordinary
      ;; Scheme locals.
      (parameterize ((*cfd-limit* cfd-limit)
                     (*cfd-re-match* #f)
                     (*cfd-re-match-end* (point-min))
                     (*cfd-prop-match* (if (%c-langvar 'c-type-decl-end-used)
                                            #f
                                            cfd-limit))
                     (*cfd-match-pos* cfd-limit)
                     (*cfd-continue-pos* #f)
                     (*cfd-top-level* (c-bs-at-toplevel-p (point))))
        (let ((cfd-start-pos (point))       ; "never changed"
              (cfd-buffer-end (point-max))
              (cfd-token-pos 0)
              (cfd-macro-end 0))
          ;; "Initialize by finding a syntactically relevant start
          ;; position before the point, and do the first
          ;; `c-decl-prefix-or-start-re' search unless we're at bob."
          (let ((start-in-literal #f) (start-in-macro #f)
                (syntactic-pos #f) (hash-define-pos #f))
            ;; "Must back up a bit since we look for the end of the
            ;; previous statement or declaration, which is earlier than
            ;; the first returned match."
            ;;
            ;; "This `cond' moves back over any literals or macros.  It
            ;; has special handling for when the region being searched is
            ;; entirely within a macro.  It sets `cfd-continue-pos'
            ;; (unless we've reached `cfd-limit')."
            (cond
             ;; "First we need to move to a syntactically relevant
             ;; position.  Begin by backing out of comment or string
             ;; literals."
             ;;
             ;; "This arm of the cond actually triggers if we're in a
             ;; literal, and cfd-limit is at most at BONL."
             ((and
               ;; "This arm of the `and' moves backwards out of a literal
               ;; when the face at point is a literal face.  In this case,
               ;; its value is always non-nil."
               (when-e (c-got-face-at (point) c-literal-faces)
                 ;; "Try to use the faces to back up to the start of the
                 ;; literal.  FIXME: What if the point is on a declaration
                 ;; inside a comment?"
                 (while (and (not (bobp))
                             (c-got-face-at (- (point) 1) c-literal-faces))
                   (goto-char (c-previous-single-property-change
                               (point) 'face #f (point-min)))) ; "No limit.  FIXME, perhaps?  2020-12-07."

                 ;; "Don't trust the literal to contain only literal faces
                 ;; (the font lock package might not have fontified the
                 ;; start of it at all, for instance) so check that we
                 ;; have arrived at something that looks like a start or
                 ;; else resort to `c-literal-limits'."
                 (unless (let ((re (%c-langvar 'c-literal-start-regexp)))
                           (and re (looking-at re)))
                   (let ((lit-start (c-literal-start)))
                     (if lit-start (goto-char lit-start))))

                 (setq start-in-literal (point))) ; "end of `and' arm."

               ;; "The start is in a literal.  If the limit is in the same
               ;; one we don't have to find a syntactic position etc.  We
               ;; only check that if the limit is at or before bonl to
               ;; save time; it covers the by far most common case when
               ;; font-lock refontifies the current line only."
               (<= (*cfd-limit*) (c-point 'bonl cfd-start-pos))
               (save-excursion
                 (goto-char cfd-start-pos)
                 (while (begin
                          (goto-char (c-next-single-property-change
                                      (point) 'face #f (*cfd-limit*)))
                          (and (< (point) (*cfd-limit*))
                               (c-got-face-at (point) c-literal-faces))))
                 (= (point) (*cfd-limit*)))) ; "end of `cond' arm condition"

              ;; "Completely inside a literal.  Set up variables to trig
              ;; the (< cfd-continue-pos cfd-start-pos) case below and
              ;; it'll find a suitable start position."
              (setq *cfd-continue-pos* start-in-literal)) ; "end of `cond' arm"

             ;; "Check if the region might be completely inside a macro,
             ;; to optimize that like the completely-inside-literal above."
             ((save-excursion
                (and (= (forward-line 1) 0)
                     (bolp)             ; "forward-line has funny behavior at eob."
                     (>= (point) (*cfd-limit*))
                     (begin (backward-char)
                            (char=? (char-before) #\\))))
              ;; "(Maybe) completely inside a macro.  Only need to trig
              ;; the (< cfd-continue-pos cfd-start-pos) case below to make
              ;; it set things up."
              (setq *cfd-continue-pos* (- cfd-start-pos 1)
                    start-in-macro #t))

             ;; "The default arm of the `cond' moves back over any macro
             ;; we're in and over any syntactic WS.  It sets
             ;; `c-find-decl-syntactic-pos'."
             (else
              ;; "Back out of any macro so we don't miss any declaration
              ;; that could follow after it."
              (when (c-beginning-of-macro)
                (setq start-in-macro #t))

              ;; "Now we're at a proper syntactically relevant position so
              ;; we can use the cache.  But first clear it if it applied
              ;; further down."
              (c-invalidate-find-decl-cache cfd-start-pos)

              (setq syntactic-pos (point))
              (unless (eqv? syntactic-pos (c-find-decl-syntactic-pos))
                ;; "Don't have to do this if the cache is relevant here,
                ;; typically if the same line is refontified again.  If
                ;; we're just some syntactic whitespace further down we
                ;; can still use the cache to limit the skipping."
                (c-backward-syntactic-ws
                 (max (or (c-find-decl-syntactic-pos) (point-min))
                      (point-min))))

              ;; "If we hit `c-find-decl-syntactic-pos' and
              ;; `c-find-decl-match-pos' is set then we install the cached
              ;; values.  If we hit `c-find-decl-syntactic-pos' and
              ;; `c-find-decl-match-pos' is nil then we know there's no
              ;; decl prefix in the whitespace before
              ;; `c-find-decl-syntactic-pos' and so we can continue the
              ;; search from this point.  If we didn't hit
              ;; `c-find-decl-syntactic-pos' then we're now in the right
              ;; spot to begin searching anyway."
              (cond
               ((and (eqv? (point) (c-find-decl-syntactic-pos))
                     (c-find-decl-match-pos))
                (setq *cfd-match-pos* (c-find-decl-match-pos)
                      *cfd-continue-pos* syntactic-pos))
               ((save-excursion (c-beginning-of-macro))
                ;; "The `c-backward-syntactic-ws' ~40 lines up failed to
                ;; find non syntactic-ws and hit its limit, leaving us in
                ;; a macro."
                (setq *cfd-match-pos* cfd-start-pos
                      *cfd-continue-pos* cfd-start-pos))
               (else
                (set!c-find-decl-syntactic-pos syntactic-pos)

                (when (if (bobp)
                          ;; "Always consider bob a match to get the first
                          ;; declaration in the file.  Do this separately
                          ;; instead of letting
                          ;; `c-decl-prefix-or-start-re' match bob, so that
                          ;; regexp always can consume at least one
                          ;; character to ensure that we won't get stuck in
                          ;; an infinite loop."
                          (setq *cfd-re-match* 0)
                          (begin
                            (backward-char)
                            (c-beginning-of-current-token)
                            (< (point) (*cfd-limit*))))
                  ;; "Do an initial search now.  In the bob case above
                  ;; it's only done to search for a `c-decl-end' spot."
                  (c-find-decl-prefix-search)) ; "sets cfd-continue-pos"

                (set!c-find-decl-match-pos
                 (and (< (*cfd-match-pos*) cfd-start-pos)
                      (*cfd-match-pos*))))))) ; "end of `cond'"

            ;; "Advance `cfd-continue-pos' if it's before the start
            ;; position.  The closest continue position that might have
            ;; effect at or after the start depends on what we started in.
            ;; This also finds a suitable start position in the special
            ;; cases when the region is completely within a literal or
            ;; macro."
            (when (and (*cfd-continue-pos*)
                       (< (*cfd-continue-pos*) cfd-start-pos))

              (cond
               (start-in-macro
                ;; "If we're in a macro then it's the closest preceding
                ;; token in the macro.  Check this before
                ;; `start-in-literal', since if we're inside a literal in
                ;; a macro, the preceding token is earlier than any
                ;; `c-decl-end' spot inside the literal (comment)."
                (goto-char (or start-in-literal cfd-start-pos))
                ;; "The only syntactic ws in macros are comments."
                (c-backward-comments)
                (or (bobp) (backward-char))
                (c-beginning-of-current-token)
                ;; "If we're in a macro without argument parentheses, we
                ;; could have now ended up at the macro's identifier.  We
                ;; need to be at #define for
                ;; `c-find-decl-prefix-search' to find the first token of
                ;; the macro's expansion."
                (when (and (c-on-identifier)
                           (setq hash-define-pos
                                 (save-excursion
                                   (and
                                    (zero? (c-backward-token-2 2)) ; "over define, #"
                                    (save-excursion
                                      (beginning-of-line)
                                      (let ((re (%c-langvar
                                                 'c-opt-cpp-macro-define-id)))
                                        (and re (looking-at re))))
                                    (point)))))
                  (goto-char hash-define-pos)))

               (start-in-literal
                ;; "If we're in a comment it can only be the closest
                ;; preceding `c-decl-end' position within that comment, if
                ;; any.  Go back to the beginning of such a property so
                ;; that `c-find-decl-prefix-search' will find the end of
                ;; it.  (Can't stop at the end and install it directly on
                ;; `cfd-prop-match' since that variable might be cleared
                ;; after `cfd-fun' below.)"
                ;;
                ;; "Note that if the literal is a string then the property
                ;; search will simply skip to the beginning of it right
                ;; away."
                (if (not (%c-langvar 'c-type-decl-end-used))
                    (goto-char start-in-literal)
                    (begin
                      (goto-char cfd-start-pos)
                      (while (begin
                               (goto-char (c-previous-single-property-change
                                           (point) 'c-type #f start-in-literal))
                               (and (> (point) start-in-literal)
                                    (not (eqv? (c-get-char-property
                                                (point) 'c-type)
                                               'c-decl-end)))))))

                (when (and (eqv? (point) start-in-literal)
                           (not (let ((re (c-doc-bright-comment-start-re)))
                                  (and re (looking-at re)))))
                  ;; "Didn't find any property inside the comment, so we
                  ;; can skip it entirely.  (This won't skip past a string,
                  ;; but that'll be handled quickly by the next
                  ;; `c-find-decl-prefix-search' anyway.)"
                  (c-forward-single-comment)
                  (if (> (point) (*cfd-limit*))
                      (goto-char (*cfd-limit*)))))

               (else
                ;; "If we started in normal code, the only match that
                ;; might apply before the start is what we already got in
                ;; `cfd-match-pos' so we can continue at the start
                ;; position.  (Note that we don't get here if the first
                ;; match is below it.)"
                (goto-char cfd-start-pos))) ; "end of `cond'"

              ;; "Delete found matches if they are before our new continue
              ;; position, so that `c-find-decl-prefix-search' won't back
              ;; up to them later on."
              (setq *cfd-continue-pos* (point))
              (when (and (*cfd-re-match*)
                         (< (*cfd-re-match*) (*cfd-continue-pos*)))
                (setq *cfd-re-match* #f))
              (when (and (*cfd-prop-match*)
                         (< (*cfd-prop-match*) (*cfd-continue-pos*)))
                (setq *cfd-prop-match* #f))) ; "end of `when'"

            (if syntactic-pos
                ;; "This is the normal case and we got a proper syntactic
                ;; position.  If there's a match then it's always outside
                ;; macros and comments, so advance to the next token and
                ;; set `cfd-token-pos'.  The loop below will later go back
                ;; using `cfd-continue-pos' to fix declarations inside the
                ;; syntactic ws."
                (when (and (*cfd-match-pos*)
                           (< (*cfd-match-pos*) syntactic-pos))
                  (goto-char syntactic-pos)
                  (c-forward-syntactic-ws (*cfd-limit*))
                  (and (*cfd-continue-pos*)
                       (< (*cfd-continue-pos*) (point))
                       (setq cfd-token-pos (point))))

                ;; "Have one of the special cases when the region is
                ;; completely within a literal or macro.
                ;; `cfd-continue-pos' is set to a good start position for
                ;; the search, so do it."
                (c-find-decl-prefix-search)))

          ;; "Now loop, one decl spot per iteration.  We already have the
          ;; first match in `cfd-match-pos'."
          (while (begin
                   ;; "Go forward over \"false matches\", one per
                   ;; iteration."
                   (while (and
                           (< (*cfd-match-pos*) (*cfd-limit*))

                           (or
                            ;; "Kludge to filter out matches on the \"<\"
                            ;; that aren't open parens, for the sake of
                            ;; languages that got
                            ;; `c-recognize-<>-arglists' set."
                            (and (eqv? (char-before (*cfd-match-pos*)) #\<)
                                 (not (c-get-char-property
                                       (- (*cfd-match-pos*) 1)
                                       'syntax-table)))

                            ;; "If `cfd-continue-pos' is less or equal to
                            ;; `cfd-token-pos', we've got a hit inside a
                            ;; macro that's in the syntactic whitespace
                            ;; before the last \"real\" declaration we've
                            ;; checked.  If they're equal we've arrived at
                            ;; the declaration a second time, so there's
                            ;; nothing to do."
                            (= (*cfd-continue-pos*) cfd-token-pos)

                            (begin
                              ;; "If `cfd-continue-pos' is less than
                              ;; `cfd-token-pos' we're still searching for
                              ;; declarations embedded in the syntactic
                              ;; whitespace.  In that case we need only to
                              ;; skip comments and not macros, since they
                              ;; can't be nested, and that's already been
                              ;; done in `c-find-decl-prefix-search'."
                              (when (> (*cfd-continue-pos*) cfd-token-pos)
                                (c-forward-syntactic-ws (*cfd-limit*))
                                (setq cfd-token-pos (point)))

                              ;; "Continue if the following token fails the
                              ;; CFD-DECL-RE and CFD-FACE-CHECKLIST
                              ;; checks."
                              ;;
                              ;; The value is the `or' arm's, so this is a
                              ;; `when-e': Emacs's `when' answers nil when
                              ;; the test fails, and that nil is what
                              ;; stops the \"false matches\" loop.
                              (when-e (or (>= (point) (*cfd-limit*))
                                          (not (looking-at cfd-decl-re))
                                          (and cfd-face-checklist
                                               (not (c-got-face-at
                                                     (point)
                                                     cfd-face-checklist))))
                                (goto-char (*cfd-continue-pos*))
                                #t)))

                           (< (point) (*cfd-limit*))) ; "end of \"false matches\" condition"
                     (c-find-decl-prefix-search)) ; "end of \"false matches\" loop"

                   (< (point) (*cfd-limit*))) ; "end of condition for \"decl-spot\" while"

            (when (and
                   (>= (point) cfd-start-pos)

                   (begin
                     ;; "Narrow to the end of the macro if we got a hit
                     ;; inside one, to avoid recognizing things that start
                     ;; inside the macro and end outside it."
                     (when (> (*cfd-match-pos*) cfd-macro-end)
                       ;; "Not in the same macro as in the previous round."
                       (save-excursion
                         (goto-char (*cfd-match-pos*))
                         (setq cfd-macro-end
                               (if (save-excursion
                                     (and (c-beginning-of-macro)
                                          (< (point) (*cfd-match-pos*))))
                                   (begin (c-end-of-macro)
                                          (point))
                                   0))))

                     (if (zero? cfd-macro-end)
                         #t
                         (if (> cfd-macro-end (point))
                             (begin
                               (narrow-to-region (point-min) cfd-macro-end)
                               #t)
                             ;; "The matched token was the last thing in
                             ;; the macro, so the whole match is bogus."
                             (begin (setq cfd-macro-end 0)
                                    #f))))) ; "end of when condition"

              (when (> cfd-macro-end 0)
                (setq *cfd-top-level* #f)) ; "In a macro is \"never\" at top level."
              (c-debug-put-decl-spot-faces (*cfd-match-pos*) (point))
              (if (funcall cfd-fun (*cfd-match-pos*)
                           (not (= cfd-macro-end 0))
                           (*cfd-top-level*))
                  (setq *cfd-prop-match* #f))

              (when (not (= cfd-macro-end 0))
                ;; "Restore limits if we did macro narrowing above."
                (narrow-to-region (point-min) cfd-buffer-end)))

            (goto-char (*cfd-continue-pos*))
            (if (= (*cfd-continue-pos*) (*cfd-limit*))
                (setq *cfd-match-pos* (*cfd-limit*))
                (c-find-decl-prefix-search)))))) ; "Moves point, sets cfd-continue-pos, cfd-match-pos, etc."

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:6947'-`:7000': the found-type helpers
    ;;------------------------------------------------------------------
    (define (c-list-found-types)
      ;; "Return all the types in `c-found-types' as a sorted list of
      ;; strings."
      (sort (hash-map->list (lambda (type value) type) (c-found-types))
            string<?))

    ;; `cc-engine.el:6957': "Shut up the byte compiler." `cc-mode.el:569'
    ;; defines it (buffer-local), and cc-mode is not ported yet; the slot
    ;; and its accessors are here, and the setter is what cc-mode's
    ;; before-change function will call.
    (define (c-maybe-stale-found-type)
      (buffer-local-value (current-buffer) 'c-maybe-stale-found-type #f))
    (define (set!c-maybe-stale-found-type value)
      (set-buffer-local-value! (current-buffer)
                               'c-maybe-stale-found-type value))

    (define (c-trim-found-types beg end old-len)
      ;; "An after change function which, in conjunction with the info in
      ;; `c-maybe-stale-found-type' (set in `c-before-change'), removes a
      ;; type from `c-found-types', should this type have become stale.
      ;; For example, this happens to \"foo\" when \"foo \\n bar();\"
      ;; becomes \"foo(); \\n bar();\".  Such stale types, if not removed,
      ;; foul up the fontification."
      ;;
      ;; "Have we, perhaps, added non-ws characters to the front/back of a
      ;; found type?"
      (when (> end beg)
        (save-excursion
          (when (< end (point-max))
            (goto-char end)
            (if (and (c-beginning-of-current-token) ; "only moves when we started in the middle"
                     (begin (goto-char end)
                            (c-end-of-current-token)))
                (c-unfind-type (buffer-substring-no-properties
                                end (point)))))
          (when (> beg (point-min))
            (goto-char beg)
            (if (and (c-end-of-current-token) ; "only moves when we started in the middle"
                     (begin (goto-char beg)
                            (c-beginning-of-current-token)))
                (c-unfind-type (buffer-substring-no-properties
                                (point) beg))))))

      (let ((stale (c-maybe-stale-found-type))) ; "e.g. (c-decl-id-start \"foo\" 97 107 \" (* ooka) \" \"o\")"
        (if stale
            (cond
             ;; "Changing the amount of (already existing) whitespace -
             ;; don't do anything."
             ((and (c-partial-ws-p beg end)
                   (or (= beg end)      ; "removal of WS"
                       (string-match "^[ \t\n\r\f\v]*$" (nth 5 stale)))))

             ;; "The syntactic relationship which defined a \"found type\"
             ;; has been destroyed."
             ((eqv? (car stale) 'c-decl-id-start)
              (c-unfind-type (cadr stale))))
            #f)))

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:7035'-`:7511': the `<'-`>' pair properties and their
    ;; change functions
    ;;------------------------------------------------------------------
    ;; "The strategy now (2010-01) adopted is to mark and unmark < and >
    ;; IN MATCHING PAIRS ONLY. [Previously, they were marked individually
    ;; when their context so indicated. This gave rise to intractable
    ;; problems when one of a matching pair was deleted, or pulled into a
    ;; literal.]
    ;;
    ;; At each buffer change, the syntax-table properties are removed in
    ;; a before-change function and reapplied, when needed, in an
    ;; after-change function. It is far more important that the
    ;; properties get removed when they are spurious than that they be
    ;; present when wanted."

    (define (c-clear-<-pair-props . args)
      ;; "POS (default point) is at a < character. If it is marked with
      ;; open paren syntax-table text property, remove the property,
      ;; together with the close paren property on the matching > (if
      ;; any)."
      (let ((pos (if (pair? args) (car args) #f)))
        (save-excursion
          (if pos
              (goto-char pos)
              (setq pos (point)))
          (when-e (equal? (c-get-char-property (point) 'syntax-table)
                          c-<-as-paren-syntax)
            ;; "ignore unbalanced [,{,(,.."
            (c-with-syntax-table (%c-langvar 'c-no-parens-syntax-table)
                                 (lambda () (c-go-list-forward)))
            (when-e (equal? (c-get-char-property (- (point) 1) 'syntax-table)
                            c->-as-paren-syntax) ; "should always be true."
              (c-unmark-<-or->-as-paren (- (point) 1))
              (c-truncate-lit-pos/state-cache (- (point) 1)))
            (c-unmark-<-or->-as-paren pos)
            (c-truncate-lit-pos/state-cache pos)))))

    (define (c-clear->-pair-props . args)
      ;; "POS (default point) is at a > character. If it is marked with
      ;; close paren syntax-table property, remove the property,
      ;; together with the open paren property on the matching < (if
      ;; any)."
      (let ((pos (if (pair? args) (car args) #f)))
        (save-excursion
          (if pos
              (goto-char pos)
              (setq pos (point)))
          (when-e (equal? (c-get-char-property (point) 'syntax-table)
                          c->-as-paren-syntax)
            ;; "ignore unbalanced [,{,(,.."
            (c-with-syntax-table (%c-langvar 'c-no-parens-syntax-table)
                                 (lambda () (c-go-up-list-backward)))
            (when-e (equal? (c-get-char-property (point) 'syntax-table)
                            c-<-as-paren-syntax) ; "should always be true."
              (c-unmark-<-or->-as-paren (point))
              (c-truncate-lit-pos/state-cache (point)))
            (c-unmark-<-or->-as-paren pos)
            (c-truncate-lit-pos/state-cache pos)))))

    (define (c-clear-<>-pair-props . args)
      ;; "POS (default point) is at a < or > character. If it has an
      ;; open/close paren syntax-table property, remove this property
      ;; both from the current character and its partner (which will also
      ;; be thusly marked)."
      (let ((pos (if (pair? args) (car args) #f)))
        (cond
         ((eqv? (char-after) #\<)
          (c-clear-<-pair-props pos))
         ((eqv? (char-after) #\>)
          (c-clear->-pair-props pos))
         (else (c-benign-error
                "c-clear-<>-pair-props called from wrong position")))))

    (define (c-clear-<-pair-props-if-match-after lim . args)
      ;; "POS (default point) is at a < character. If it is both marked
      ;; with open/close paren syntax-table property, and has a matching
      ;; > (also marked) which is after LIM, remove the property both
      ;; from the current > and its partner. Return the position after
      ;; the > when this happens, nil when it doesn't."
      (let ((pos (if (pair? args) (car args) #f)))
        (save-excursion
          (if pos
              (goto-char pos)
              (setq pos (point)))
          (when-e (equal? (c-get-char-property (point) 'syntax-table)
                          c-<-as-paren-syntax)
            ;; "ignore unbalanced [,{,(,.."
            (c-with-syntax-table (%c-langvar 'c-no-parens-syntax-table)
                                 (lambda () (c-go-list-forward)))
            (when (and (>= (point) lim)
                       (equal? (c-get-char-property (- (point) 1) 'syntax-table)
                               c->-as-paren-syntax)) ; "should always be true."
              (c-unmark-<-or->-as-paren (- (point) 1))
              (c-unmark-<-or->-as-paren pos)
              (c-truncate-lit-pos/state-cache pos)
              (point))))))

    (define (c-clear->-pair-props-if-match-before lim . args)
      ;; "POS (default point) is at a > character. If it is both marked
      ;; with open/close paren syntax-table property, and has a matching
      ;; < (also marked) which is before LIM, remove the property both
      ;; from the current < and its partner. Return the position of the <
      ;; when this happens, nil when it doesn't."
      (let ((pos (if (pair? args) (car args) #f)))
        (save-excursion
          (if pos
              (goto-char pos)
              (setq pos (point)))
          (when-e (equal? (c-get-char-property (point) 'syntax-table)
                          c->-as-paren-syntax)
            ;; "ignore unbalanced [,{,(,.."
            (c-with-syntax-table (%c-langvar 'c-no-parens-syntax-table)
                                 (lambda () (c-go-up-list-backward)))
            (when (and (<= (point) lim)
                       (equal? (c-get-char-property (point) 'syntax-table)
                               c-<-as-paren-syntax)) ; "should always be true."
              (c-unmark-<-or->-as-paren (point))
              (c-truncate-lit-pos/state-cache (point))
              (c-unmark-<-or->-as-paren pos)
              (point))))))

    ;; "Set by c-common-init in cc-mode.el." Emacs makes them
    ;; buffer-local; the slot and its accessors stand in (cc-mode.el's
    ;; change hooks are not ported yet - `c-restore-<>-properties' and
    ;; its siblings are what read them until they are).
    (define (c-new-BEG)
      (buffer-local-value (current-buffer) 'c-new-BEG 0))
    (define (set!c-new-BEG value)
      (set-buffer-local-value! (current-buffer) 'c-new-BEG value))
    (define (c-new-END)
      (buffer-local-value (current-buffer) 'c-new-END 0))
    (define (set!c-new-END value)
      (set-buffer-local-value! (current-buffer) 'c-new-END value))

    (define (c-end-of-literal pt-s pt-search)
      ;; "If a literal is open in the `c-semi-pp-to-literal' state PT-S,
      ;; return the end point of this literal (or point-max) assuming PT-S
      ;; is valid at PT-SEARCH. Otherwise, return nil."
      (when-e (%c-car (%c-cddr pt-s))           ; "Literal start"
        (let ((lit-type (%c-cadr pt-s))
              (lit-beg (%c-car (%c-cddr pt-s)))
              (ml-end-re #f))
          (save-excursion
            (cond
             ((eq? lit-type 'string)
              (if (and (%c-true (%c-langvar 'c-ml-string-opener-re))
                       (c-ml-string-opener-at-or-around-point lit-beg))
                  (begin
                    (setq ml-end-re
                          (funcall
                           (%c-lang-function
                            (%c-langvar 'c-make-ml-string-closer-re-function))
                           (match-string 1)))
                    (goto-char (max (- pt-search (- (string-length ml-end-re) 1))
                                    (point-min)))
                    (re-search-forward ml-end-re #f 'stay))
                  ;; "For an ordinary string, we can't use
                  ;; `parse-partial-sexp' since not all syntax-table
                  ;; properties have yet been set."
                  (begin
                    (goto-char pt-search)
                    (re-search-forward
                     "\\(?:\\\\\\(?:.\\|\n\\)\\|[^\"\n\\]\\)*[\"\n]" #f 'stay))))
             ((memq lit-type '(c c++))
              ;; "To work around a bug in parse-partial-sexp, where effect
              ;; is given to the syntax of a backslash, even the scan
              ;; starts with point just after it."
              (if (and (eqv? (char-before pt-search) #\\)
                       (eqv? (char-after pt-search) #\newline))
                  (begin
                    (c-put-char-property (- pt-search 1) 'syntax-table '(1))
                    (parse-partial-sexp pt-search (point-max) #f #f (car pt-s)
                                        'syntax-table)
                    (c-clear-char-property (- pt-search 1) 'syntax-table))
                  (parse-partial-sexp pt-search (point-max) #f #f (car pt-s)
                                      'syntax-table)))
             (else #f))
            (point)))))

    (define (c-unmark-<>-around-region beg end . args)
      ;; "Unmark certain pairs of \"< .... >\" which are currently marked
      ;; as template/generic delimiters. (This marking is via syntax-table
      ;; text properties), and expand the (c-new-BEG c-new-END) region to
      ;; include all unmarked < and > operators within the certain bounds
      ;; (see below)."
      ;;
      ;; "These pairs are those which are in the current \"statement\"
      ;; (i.e., the region between the {, }, or ; before BEG and the one
      ;; after END), and which enclose any part of the interval (BEG
      ;; END)."
      ;;
      ;; "Note that in C++ (?and Java), template/generic parens cannot
      ;; enclose a brace or semicolon, so we use these as bounds on the
      ;; region we must work on."
      ;;
      ;; "The buffer is widened, and point is undefined, both at entry and
      ;; exit."
      ;;
      ;; "FIXME!!! This routine ignores the possibility of macros
      ;; entirely. 2010-01-29."
      (let ((old-len (if (pair? args) (car args) #f)))
        (when-e (or old-len (> end beg))
          ;; "Extend the region (BEG END) to deal with any complicating
          ;; literals."
          (let* ((lit-search-beg (if (memv (char-before beg) (list #\/ #\*))
                                     (- beg 1) beg))
                 (lit-search-end (if (memv (char-after end) (list #\/ #\*))
                                     (+ end 1) end))
                 ;; "Note we can't use c-full-pp-to-literal here, since we
                 ;; haven't yet applied syntax-table properties to ends of
                 ;; lines, etc."
                 (lit-search-beg-s (c-semi-pp-to-literal lit-search-beg))
                 (beg-literal-beg (%c-car (%c-cddr lit-search-beg-s)))
                 (lit-search-end-s (c-semi-pp-to-literal lit-search-end))
                 (end-literal-beg (%c-car (%c-cddr lit-search-end-s)))
                 (beg-literal-end (c-end-of-literal lit-search-beg-s
                                                    lit-search-beg))
                 (end-literal-end (c-end-of-literal lit-search-end-s
                                                    lit-search-end))
                 (new-beg #f) (new-end #f) (search-region #f))

            ;; "Determine any new end of literal resulting from the
            ;; insertion/deletion."
            (setq search-region
                  (if (and (eqv? beg-literal-beg end-literal-beg)
                           (eqv? beg-literal-end end-literal-end))
                      (if beg-literal-beg
                          #f
                          (cons beg
                                (max end
                                     (or beg-literal-end (point-min))
                                     (or end-literal-end (point-min)))))
                      (cons (or beg-literal-beg beg)
                            (max end
                                 (or beg-literal-end (point-min))
                                 (or end-literal-end (point-min))))))

            (when-e search-region
              ;; "If we've just inserted text, mask its syntaxes
              ;; temporarily so that they won't interfere with the undoing
              ;; of the properties on the <s and >s."
              (c-save-buffer-state ((syn-tab-settings '())
                                    (syn-tab-value #f)
                                    (swap-open-string-ends #f))
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (when old-len
                      ;; "Special case: If a \ has just been inserted into
                      ;; a string, escaping or unescaping a LF,
                      ;; temporarily swap the LF's syntax-table text
                      ;; property with that of the former end of the open
                      ;; string."
                      (goto-char end)
                      (when (and (eq? (%c-cadr lit-search-beg-s) 'string)
                                 (not (eqv? beg-literal-end end-literal-end))
                                 (skip-chars-forward "\\\\")
                                 (eqv? (char-after) #\newline)
                                 (not (= (skip-chars-backward "\\\\") 0))
                                 (< (point) end))
                        (setq swap-open-string-ends #t)
                        (if (c-get-char-property (- beg-literal-end 1)
                                                  'syntax-table)
                            (begin
                              (c-clear-char-property (- beg-literal-end 1)
                                                     'syntax-table)
                              (c-put-string-fence (- end-literal-end 1)))
                            (begin
                              (c-put-string-fence (- beg-literal-end 1))
                              (c-clear-char-property (- end-literal-end 1)
                                                     'syntax-table))))

                      ;; "Save current settings of the 'syntax-table
                      ;; property in (BEG END), then splat these with the
                      ;; punctuation value."
                      (goto-char beg)
                      (while (setq syn-tab-value
                                   (c-search-forward-non-nil-char-property
                                    'syntax-table end))
                        (when (not (c-get-char-property (- (point) 1)
                                                        'category))
                          (push (cons (- (point) 1) syn-tab-value)
                                syn-tab-settings)))

                      (c-put-char-properties beg end 'syntax-table '(1))
                      ;; "If an open string's opener has just been
                      ;; neutralized, do the same to the terminating LF."
                      (when (and (> end beg)
                                 end-literal-end
                                 (eqv? (char-before end-literal-end) #\newline)
                                 (equal? (c-get-char-property
                                          (- end-literal-end 1)
                                          'syntax-table)
                                         '(15)))
                        (push (cons (- end-literal-end 1) '(15))
                              syn-tab-settings)
                        (c-put-char-property (- end-literal-end 1)
                                             'syntax-table '(1))))

                    (let ((beg-lit-start (begin (goto-char beg)
                                                (c-literal-start)))
                          (beg-limit #f) (end-limit #f) (<>-pos #f))
                      ;; "Locate the earliest < after the barrier before
                      ;; the changed region, which isn't already marked
                      ;; as a paren."
                      (goto-char (or beg-lit-start beg))
                      (setq beg-limit (c-determine-limit 5000))

                      ;; "Remove the syntax-table/category properties from
                      ;; each pertinent <...> pair. Firstly, the ones with
                      ;; the < before beg and > after beg...."
                      (goto-char (cdr search-region))
                      (while (begin
                               (c-syntactic-skip-backward "^;{}<" beg-limit)
                               (eqv? (char-before) #\<))
                        (c-backward-token-2)
                        (when (eqv? (char-after) #\<)
                          (when (setq <>-pos
                                      (c-clear-<-pair-props-if-match-after
                                       (car search-region)))
                            (setq new-end <>-pos))
                          (setq new-beg (point))))

                      ;; "...Then the ones with < before end and > after
                      ;; end."
                      (goto-char (car search-region))
                      (setq end-limit (c-determine-+ve-limit 5000))
                      (while (and (c-syntactic-re-search-forward
                                   "[;{}>]" end-limit 'end)
                                  (eqv? (char-before) #\>))
                        (when (eqv? (char-before) #\>)
                          (let ((re (%c-langvar 'c->-op-cont-regexp)))
                            (if (and re
                                     (looking-at re)
                                     (not (eqv? (char-after) #\>)))
                                (goto-char (match-end 0))
                                (begin
                                  (when
                                      (and (setq <>-pos
                                                 (c-clear->-pair-props-if-match-before
                                                  (cdr search-region)
                                                  (- (point) 1)))
                                           (or (not new-beg)
                                               (< <>-pos new-beg)))
                                    (setq new-beg <>-pos))
                                  (when (or (not new-end)
                                            (> (point) new-end))
                                    (setq new-end (point))))))))))
                    ;; "Cleanup."
                    (lambda ()
                      (when old-len
                        (c-clear-char-properties beg end 'syntax-table)
                        (dolist (elt syn-tab-settings)
                          (if (cdr elt)
                              (c-put-char-property (car elt) 'syntax-table
                                                   (cdr elt)))))
                      ;; "Swap the '(15) syntax-table property on open
                      ;; string LFs back again."
                      (when swap-open-string-ends
                        (if (c-get-char-property (- beg-literal-end 1)
                                                  'syntax-table)
                            (begin
                              (c-clear-char-property (- beg-literal-end 1)
                                                     'syntax-table)
                              (c-put-string-fence (- end-literal-end 1)))
                            (begin
                              (c-put-string-fence (- beg-literal-end 1))
                              (c-clear-char-property (- end-literal-end 1)
                                                     'syntax-table))))))
                ;; "Extend the fontification region, if needed."
                (when (and new-beg (< new-beg (c-new-BEG)))
                  (set!c-new-BEG new-beg))
                (when (and new-end (> new-end (c-new-END)))
                  (set!c-new-END new-end))))))))

    (define (c-before-change-check-<>-operators beg end)
      ;; "When we're deleting text, unmark certain pairs of \"< .... >\"
      ;; which are currently marked as template/generic delimiters. (This
      ;; marking is via syntax-table text properties), and expand the
      ;; (c-new-BEG c-new-END) region to include all unmarked < and >
      ;; operators within the certain bounds (see below)."
      ;;
      ;; "These pairs are those which are in the current \"statement\"
      ;; (i.e., the region between the {, }, or ; before BEG and the one
      ;; after END), and which enclose any part of the interval (BEG
      ;; END). Also unmark a < or > which is about to become part of a
      ;; multi-character operator, e.g. <=."
      ;;
      ;; "Note that in C++ (?and Java), template/generic parens cannot
      ;; enclose a brace or semicolon, so we use these as bounds on the
      ;; region we must work on."
      ;;
      ;; "This function is called from before-change-functions (via
      ;; c-get-state-before-change-functions). Thus the buffer is widened,
      ;; and point is undefined, both at entry and exit."
      ;;
      ;; "FIXME!!! This routine ignores the possibility of macros
      ;; entirely. 2010-01-29."
      (when (> end beg)
        ;; "Cope with removing (beg end) coalescing a < or > with, say,
        ;; an = sign."
        (goto-char beg)
        (let ((ch (char-before)))
          (if (and (memv ch (list #\< #\>))
                   (c-get-char-property (- (point) 1) 'syntax-table)
                   (begin
                     (goto-char end)
                     (let ((re (%c-langvar (if (eqv? ch #\<)
                                               'c-<-op-cont-regexp
                                               'c->-op-cont-regexp))))
                       (and re (looking-at re))))
                   (or (eqv? ch #\<)
                       (not (eqv? (char-after) #\>))))
              (c-unmark-<>-around-region (- beg 1) beg)
              #f))))

    (define (c-after-change-check-<>-operators beg end)
      ;; "This is called from `after-change-functions' when
      ;; c-recognize-<>-arglists' is set. It ensures that no \"<\" or
      ;; \">\" chars with paren syntax become part of another operator
      ;; like \"<<\" or \">=\"."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (goto-char beg)
        (when (or (looking-at "[<>]")
                  (< (skip-chars-backward "<>") 0))

          (goto-char beg)
          (c-beginning-of-current-token)
          (when (and (< (point) beg)
                     (let ((re (%c-langvar 'c-<>-multichar-token-regexp)))
                       (and re (looking-at re)))
                     (< beg (begin (setq beg (match-end 0)) beg)))
            (while (begin
                     (skip-chars-forward "^<>" beg)
                     (< (point) beg))
              (c-clear-<>-pair-props)
              (forward-char))))

        (when (< beg end)
          (goto-char end)
          (when (or (looking-at "[<>]")
                    (< (skip-chars-backward "<>") 0))

            (goto-char end)
            (c-beginning-of-current-token)
            (when (and (< (point) end)
                       (let ((re (%c-langvar 'c-<>-multichar-token-regexp)))
                         (and re (looking-at re)))
                       (< end (begin (setq end (match-end 0)) end)))
              (while (begin
                       (skip-chars-forward "^<>" end)
                       (< (point) end))
                (c-clear-<>-pair-props)
                (forward-char)))))))

    (define (c-<>-get-restricted)
      ;; "With point at the < at the start of the purported <>-arglist,
      ;; determine the value of `c-restricted-<>-arglists' to use for the
      ;; call of `c-forward-<>-arglist' starting there."
      (save-excursion
        (c-backward-token-2)
        (and (not (let ((re (%c-langvar 'c-opt-<>-sexp-key)))
                    (and re (looking-at re))))
             (begin (c-backward-syntactic-ws)   ; "to ( or ,"
                    (and (memv (char-before) (list #\( #\,)) ; "what about <?"
                         (not (eq? (c-get-char-property (point) 'c-type)
                                   'c-decl-arg-start)))))))

    (define (c-restore-<>-properties beg end old-len)
      ;; "This function is called as an after-change function. It restores
      ;; the category/syntax-table properties on template/generic <..>
      ;; pairs between c-new-BEG and c-new-END. It may do hidden buffer
      ;; changes."
      ;;
      ;; Emacs `let'-binds `c-parse-and-markup-<>-arglists' and
      ;; `c-restricted-<>-arglists' here; both are parameters, so the
      ;; tree `parameterize's them.
      (c-save-buffer-state ((lit-limits #f))
        (parameterize ((*c-parse-and-markup-<>-arglists* #t))
          (goto-char (c-new-BEG))
          (if (setq lit-limits (c-literal-limits))
              (goto-char (cdr lit-limits)))
          (while (and (< (point) (c-new-END))
                      (c-syntactic-re-search-forward "[<>]" (c-new-END)
                                                     'bound))
            (if (eqv? (char-before) #\<)
                (begin
                  (backward-char)
                  (parameterize ((*c-restricted-<>-arglists*
                                  (c-<>-get-restricted)))
                    (or (c-forward-<>-arglist #f)
                        (c-forward-over-token-and-ws)
                        (goto-char (c-new-END)))))
                (save-excursion
                  (when (c-backward-<>-arglist #f #f c-<>-get-restricted)
                    (set!c-new-BEG (min (c-new-BEG) (point))))))))))

    ;; "Handling of CC Mode multi-line strings": the two small helpers
    ;; `c-end-of-literal' stands on (`cc-engine.el:7511'-`:7537').
    (define (c-ml-string-make-closer-re opener)
      ;; "Return `c-ml-string-any-closer-re'. This is a suitable language
      ;; specific value of `c-make-ml-string-closer-re-function' for most
      ;; languages with multi-line strings (but not C++, for example)."
      (%c-langvar 'c-ml-string-any-closer-re))

    (define (c-c++-make-ml-string-closer-re opener)
      ;; "Construct a regexp for a C++ raw string closer matching OPENER."
      (concat "\\()" (regexp-quote (%substring opener 2 -1)) "\\(\"\\)\\)"))

    ;; The language's value is the function's symbol; Emacs resolves it
    ;; through the obarray, and this registry is the tree's stand-in (see
    ;; `c-register-lang-function!').
    (c-register-lang-function! 'c-ml-string-make-closer-re
                               c-ml-string-make-closer-re)
    (c-register-lang-function! 'c-c++-make-ml-string-closer-re
                               c-c++-make-ml-string-closer-re)

    ;;------------------------------------------------------------------
    ;; `cc-engine.el:7559', `:7575': the multi-line string helpers
    ;;------------------------------------------------------------------
    ;; The `<>' bracket-property machinery (`:7000'-`:7553') is ported
    ;; above, in the C's own order. This section keeps the two ml-string
    ;; helpers `cc-fonts.el''s `c-font-lock-ml-strings' calls; the rest of
    ;; the multi-line string section (the delim walks, `c-before-change-
    ;; check-ml-strings' and `c-after-change-unmark-ml-strings') waits on
    ;; `cc-mode.el''s change hooks, which are not ported.

    (define (c-get-ml-closer open-delim)
      ;; "Return the closer, a three element dotted list of the closer's
      ;; start, its end and the position of the double quote, matching the
      ;; given multi-line string OPENER, also such a three element dotted
      ;; list. Otherwise return nil. All pertinent syntax-table text
      ;; properties must be in place."
      (save-excursion
        (goto-char (cadr open-delim))
        (and (not (equal? (c-get-char-property (1- (point)) 'syntax-table)
                          '(15)))
             (re-search-forward ((%c-langvar 'c-make-ml-string-closer-re-function)
                                 (buffer-substring-no-properties
                                  (car open-delim) (cadr open-delim)))
                                #f #t)
             (cons (match-beginning 1)
                   (cons (match-end 1) (match-beginning 2))))))

    (define (c-ml-string-opener-around-point)
      ;; "If point is inside an ml string opener, return a dotted list of
      ;; the start and end of that opener, and the position of its
      ;; double-quote. That list will not include any \"context characters\"
      ;; before or after the opener. If an opener is found, the match-data
      ;; will indicate it, with (match-string 1) being the entire delimiter,
      ;; and (match-string 2) the \"main\" double quote. Otherwise the
      ;; match-data is undefined."
      (let ((here (point))
            (found #f))
        (goto-char (max (- here (- (%c-langvar 'c-ml-string-max-opener-len) 1))
                        (point-min)))
        (while (and (setq found
                          (re-search-forward
                           (%c-langvar 'c-ml-string-opener-re)
                           (min (+ here
                                   (- (%c-langvar 'c-ml-string-max-opener-len) 1))
                                (point-max))
                           'bound))
                    (<= (match-end 1) here)))
        (prog1
            (and found
                 (< (match-beginning 1) here)
                 (cons (match-beginning 1)
                       (cons (match-end 1) (match-beginning 2))))
          (goto-char here))))

    (define (c-ml-string-opener-at-or-around-point . args)
      ;; "If POSITION (default point) is at or inside an ml string opener,
      ;; return a dotted list of the start and end of that opener, and the
      ;; position of the double-quote in it. That list will not include
      ;; any \"context characters\" before or after the opener. If an
      ;; opener is found, the match-data will indicate it, with
      ;; (match-string 1) being the entire delimiter, and (match-string 2)
      ;; the \"main\" \" it contains. Otherwise, the match-data is
      ;; undefined."
      (let ((position (if (pair? args) (car args) #f))
            (here (point)) (found #f))
        (or position (setq position (point)))
        (goto-char (max (- position
                           (- (%c-langvar 'c-ml-string-max-opener-len) 1))
                        (point-min)))
        (while (and (setq found
                          (re-search-forward
                           (%c-langvar 'c-ml-string-opener-re)
                           (min (+ position
                                   (%c-langvar 'c-ml-string-max-opener-len))
                                (point-max))
                           'bound))
                    (< (match-end 1) position)))
        (prog1
            (and found
                 (<= (match-beginning 1) position)
                 (cons (match-beginning 1)
                       (cons (match-end 1) (match-beginning 2))))
          (goto-char here))))

))
