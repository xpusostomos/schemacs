(define-library (schemacs editor cc-fonts)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/cc-fonts.el'.
  ;;
  ;; What is here, in Emacs's file order: the face-name constants and
  ;; `c-make-inverse-face' (`:112'-`:205'), the font-lock helpers and the
  ;; matcher constructors (`:207'-`:525'), `c-font-lock-cpp-messages'
  ;; (`:525'`), `c-font-lock-invalid-single-quotes' and
  ;; `c-maybe-font-lock-wrong-style-comments' (`:706'`, `:735'`),
  ;; `c-cpp-matchers' (`:550'`) and `c-basic-matchers-before'
  ;; (`:790'`), `c-font-lock-complex-decl-prepare' and
  ;; `c-font-lock-<>-arglists' (`:947'`, `:1005'`),
  ;; `c-font-lock-declarators' (`:1099'`), `c-get-fontification-context'
  ;; (`:1206'`), `c-font-lock-declarations' (`:1421'`) with
  ;; `c-font-lock-single-decl' and `c-font-lock-c11-generic-clause', the
  ;; enum, cut-off-declarator, enclosing-decl and dollar-identifier
  ;; fontifiers (`:1772'`-`:1941'`), the multi-line string fontifier
  ;; (`:1941'`), `c-font-lock-c++-lambda-captures' (`:2027'`), the C++20
  ;; module fontifier with its two helpers (`:2119'-`:2280'`), the
  ;; matcher data (`:2274'-`:2567'`: `c-simple-decl-matchers',
  ;; `c-complex-decl-matchers', `c-basic-matchers-after' and
  ;; `c-matchers-1'-`3'), `c-font-lock-labels' (`:2431'`), and the
  ;; C++-`using'/`new' and Objective-C fontifiers
  ;; (`:2713'-`:2985'`); `c-get-doc-comment-style',
  ;; `c-compose-keywords-list', `c-override-default-keywords',
  ;; `c-re-redisplay-timer', `c-force-redisplay' and
  ;; `c-fontify-new-found-type' (`:2567'-`:2677'`); the six
  ;; `*-font-lock-keywords' variable sets (`:2679'-`:3121'`); and the
  ;; whole doc-comment machinery (`c-set-doc-comment-res',
  ;; `c-font-lock-doc-comments', `c-find-invalid-doc-markup' and the
  ;; gtkdoc/javadoc/autodoc/doxygen tables, `:3126'-`:3593'`). **The
  ;; file is whole** except `c-make-inverse-face`'s XEmacs arm.
  ;;
  ;; **How the keyword variables and the doc machinery are represented**
  ;; is in DEPARTURES.md's 2026-11-23 section: the variables keep their
  ;; names and their function halves are registered in
  ;; `*font-lock-keyword-variables*`; the doc styles' symbol lookups are
  ;; two alists filled at the end of the file; the three doc variables
  ;; are buffer-local slots in cc-engine; and the two
  ;; `c-set-doc-comment-*` macros are procedures.
  ;;
  ;; **Still to come**: `cc-mode.el`'s `c-font-lock-init`, which installs
  ;; `*c-font-lock-fontify-region-function*` and the mode's
  ;; `font-lock-defaults`; until it lands a test replays its block by
  ;; hand.
  ;;
  ;; **The matchers are procedures.** Emacs's `c-make-font-lock-search-form'
  ;; returns a Lisp *form* which `c-make-font-lock-search-function' splices
  ;; into a `byte-compile'd lambda. Scheme has no lexical `eval', so the
  ;; form is the procedure it would have been: the search-form constructor
  ;; returns a procedure of LIMIT, and the search-function constructor
  ;; wraps it in the `parse-sexp-lookup-properties' binding. The tree's
  ;; font-lock calls a keyword's matcher with `end' when it is not a
  ;; string (`font-lock-fontify-keywords-region'), which is the same
  ;; protocol.
  ;;
  ;; The consequence for an "anchored highlighter" - Emacs's
  ;; `(ANCHORED-MATCHER PRE-FORM POST-FORM ...)', whose three parts are
  ;; *code* spliced into the generated lambda with `limit' in scope - is
  ;; a representation departure: the port's data is
  ;;
  ;;     (MATCHER-FN PRE-FN POST-FN SUBEXP-HIGHLIGHTERS...)
  ;;
  ;; where each of the three is a procedure of one argument, LIMIT, and
  ;; they are called in Emacs's order. Emacs splices the three slots as
  ;; *forms* into the generated lambda, which is what puts `limit' in
  ;; their scope (e.g. the data writes `(c-font-lock-declarators limit
  ;; t)'); a Scheme procedure cannot close over a variable that only
  ;; exists when the matcher runs, so LIMIT is passed to each of them.
  ;; Building them as plain thunks is wrong - `limit' is then unbound.
  ;;
  ;; **The multi-line string fontifier needs its propertization.**
  ;; `c-font-lock-ml-strings' is ported whole, but the `'(15)'
  ;; `syntax-table' properties on the delimiters come from
  ;; `c-ml-string-propertize' and cc-mode's change hooks, which are not;
  ;; until they are, it acts only on delimiters that already carry them.
  ;; Named in DEPARTURES.md; C and Java are unaffected
  ;; (`c-ml-string-opener-re' is nil for them).
  ;;
  ;; **Departures taken here**, each in place:
  ;;   - The `boundp'/alias tests in the face-name constants are dropped:
  ;;     a face name in this tree is the face, and `c-face-name-p' asks
  ;;     `face-list'. The `font-lock-reference-face'/'font-lock-label-face'
  ;;     branches stay as Emacs writes them; those faces do not exist here,
  ;;     so they are false and the later branches are taken.
  ;;   - `c-annotation-face's spec is `((#t :inherit ...))' where Emacs
  ;;     writes `((default :inherit ...))'; `#t' is this tree's spelling of
  ;;     the display spec that always matches.
  ;;   - `c-put-font-lock-face' and friends are procedures, not macros:
  ;;     Emacs's choose between the Emacs and XEmacs font-lock packages,
  ;;     and only the `put-text-property' arm applies here.

  (import
    (scheme base)
    (only (scheme cxr) cadar caddr)
    ;; Emacs's `while', and the list accessors the matcher code uses.
    (only (guile) while 1+ 1-)
    (only (schemacs editor fns) nth concat delete mapconcat identity)
    (only (schemacs regexp-opt) regexp-opt)
    (only (schemacs editor cc-defs)
          c-face-name-p c-got-face-at c-next-single-property-change
          c-put-char-property c-get-char-property
          c-clear-char-properties c-put-char-properties
          c-search-forward-char-property
          c-search-forward-char-property-with-value-on-char
          c-lang-defconst c-lang-const c-major-mode-is %c-true
          *c-lang-var-overrides*
          c-make-keywords-re c-safe c-forward-sexp c-go-list-forward
          c-go-list-backward c-go-up-list-backward c-go-up-list-forward
          c-up-list-forward
          c-upper c--set-difference c--delete-duplicates
          c--mapcan c-save-buffer-state *c-buffer-is-cc-mode*)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          with-current-buffer kill-local-variable)
    (only (schemacs editor editfns) point point-min point-max goto-char
          char-after char-before save-excursion save-restriction
          narrow-to-region widen buffer-substring-no-properties bobp eobp)
    (only (schemacs editor cmds) forward-char backward-char end-of-line)
    (only (schemacs editor search) re-search-forward re-search-backward
          search-forward set-match-data
          match-beginning match-end match-string
          looking-at regexp-opt-depth match-string-no-properties
          save-match-data)
    (only (schemacs editor textprop) put-text-property remove-text-properties
          get-text-property)
    (only (schemacs editor syntax) *parse-sexp-lookup-properties*
          parse-partial-sexp skip-chars-forward skip-chars-backward
          skip-syntax-forward scan-sexps scan-error?)
    (only (schemacs editor faces) defface copy-face invert-face
          face-inverse-video-p)
    ;; The face-name constants are computed when this library loads, and
    ;; the `font-lock-*' faces they test for are defined by font-lock.
    ;; Emacs has font-lock preloaded; the import is this tree's way of
    ;; placing the load in the same order.
    (only (schemacs editor font-lock) font-lock-fontify-region
          font-lock-apply-highlight font-lock-mode-on?
          *font-lock-support-mode* *font-lock-keyword-variables*
          font-lock-register-keyword-variable!)
    (only (schemacs editor cc-engine)
          c-literal-faces c-literal-start c-literal-limits
          c-semi-pp-to-literal %c-cadr %c-caddr %c-cdr %c-langvar
          c-determine-limit
          c-get-ml-closer c-ml-string-opener-around-point c-benign-error
          c-looking-at-c++-attribute c-end-of-decl-1
          c-do-declarators c-forward-type c-forward-token-2
          c-forward-over-token c-on-identifier c-unfind-type
          c-in-id-arglist c-forward-decl-or-cast-1 c-forward-<>-arglist
          c-forward-label c-point c-find-decl-spots
          c-syntactic-re-search-forward *c-parse-and-markup-<>-arglists*
          *c-restricted-<>-arglists* c-delq-from-dotted-list
          c-simple-skip-symbol-backward
          %c-car %c-cddr
          c-at-enum-brace c-at-bracelist-p c-parse-state
          c-looking-at-c++-lambda-capture-list
          c-bs-at-toplevel-p c-beginning-of-macro
          c-keyword-member c-keyword-sym
          c-at-toplevel-p c-most-enclosing-brace
          c-syntactic-skip-backward c-forward-over-token-and-ws
          c-end-of-current-token c-after-conditional
          c-forward-name c-forward-keyword-clause
          c-backward-token-2 c-backward-syntactic-ws
          c-forward-single-comment
          c-back-over-member-initializers c-back-over-compound-identifier
          c-forward-objc-directive *c-promote-possible-types*
          c-forward-syntactic-ws c-end-of-macro
          c-beginning-of-decl-1
          *c-record-type-identifiers* *c-record-ref-identifiers*
          c-in-literal *c-fontify-new-found-type-function*)
    (only (schemacs editor cc-vars)
          *c-mark-wrong-style-of-comment* c-block-comment-flag
          c-macro-with-semi-re *c-warn-ids-with-dollar*
          c-current-comment-prefix c-doc-comment-style
          *c-doc-comment-style*)
    (only (schemacs editor cc-langs) c-lang-set-local!)
    (only (schemacs editor jit-lock) jit-lock-force-redisplay)
    (only (schemacs editor timer) run-with-timer)
    (only (schemacs editor marker) copy-marker)
    (only (schemacs editor window) get-buffer-window-list)
    (only (schemacs editor frame) window-start)
    (only (schemacs editor xdisp) window-end)
    (only (schemacs editor subr) delq)
    ;; `when-e' is Emacs's `when' for the one place its nil answer is
    ;; returned from a function.
    (only (schemacs syntax) setq when-e cond-e prog1 push dolist))

  (export
   c-preprocessor-face-name c-label-face-name c-constant-face-name
   c-reference-face-name c-doc-face-name c-doc-markup-face-name
   c-negation-char-face-name
   c-font-lock-context set!c-font-lock-context
   c-put-font-lock-face c-remove-font-lock-face c-put-font-lock-string-face
   c-fontify-types-and-refs
   c-skip-comments-and-strings
   c-make-syntactic-matcher
   c-make-font-lock-search-form c-make-font-lock-search-function
   c-make-font-lock-BO-decl-search-function
   c-make-font-lock-context-search-function
   c-fontify-recorded-types-and-refs
   c-font-lock-cpp-messages
   c-make-inverse-face c-annotation-face
   c-font-lock-invalid-single-quotes c-maybe-font-lock-wrong-style-comments
   c-cpp-matchers
   c-font-lock-ml-strings
   c-forward-c++-module-name c-forward-c++-module-partition-name
   c-font-lock-c++-modules
   c-font-lock-complex-decl-prepare c-font-lock-<>-arglists
   c-font-lock-enum-body c-font-lock-enum-tail
   c-font-lock-cut-off-declarators c-font-lock-enclosing-decls
   c-font-lock-ids-with-dollar c-font-lock-c++-lambda-captures
   c-font-lock-labels
   c-simple-decl-matchers c-complex-decl-matchers
   c-basic-matchers-after c-matchers-1 c-matchers-2 c-matchers-3
   c-font-lock-c++-using c-font-lock-c++-new
   c-font-lock-objc-method c-font-lock-objc-methods
   c-basic-matchers-before
   c-font-lock-declarators c-get-fontification-context
   c-font-lock-single-decl c-font-lock-declarations
   c-font-lock-c11-generic-clause
   c-get-doc-comment-style c-compose-keywords-list
   c-override-default-keywords c-re-redisplay-timer
   *c-font-lock-fontify-region-function* c-force-redisplay
   c-fontify-new-found-type
   c-font-lock-keywords c-font-lock-keywords-1
   c-font-lock-keywords-2 c-font-lock-keywords-3
   c++-font-lock-keywords c++-font-lock-keywords-1
   c++-font-lock-keywords-2 c++-font-lock-keywords-3
   objc-font-lock-keywords objc-font-lock-keywords-1
   objc-font-lock-keywords-2 objc-font-lock-keywords-3
   java-font-lock-keywords java-font-lock-keywords-1
   java-font-lock-keywords-2 java-font-lock-keywords-3
   idl-font-lock-keywords idl-font-lock-keywords-1
   idl-font-lock-keywords-2 idl-font-lock-keywords-3
   pike-font-lock-keywords pike-font-lock-keywords-1
   pike-font-lock-keywords-2 pike-font-lock-keywords-3
   c-set-doc-comment-re-element c-set-doc-comment-char-list
   c-set-doc-comment-res c-doc-style-property
   c-font-lock-doc-comments c-find-invalid-doc-markup
   gtkdoc-font-lock-doc-comments gtkdoc-font-lock-doc-protection
   gtkdoc-font-lock-keywords
   javadoc-font-lock-doc-comments javadoc-font-lock-keywords
   autodoc-decl-keywords autodoc-decl-type-keywords
   autodoc-font-lock-line-markup autodoc-font-lock-doc-comments
   autodoc-line-join-re autodoc-bright-comment-start-re
   autodoc-line-join-end-ch autodoc-font-lock-keywords
   doxygen-font-lock-doc-comments doxygen-font-lock-keywords)

  (begin

    ;;------------------------------------------------------------------
    ;; The face names (`cc-fonts.el:112'-`:188')
    ;;------------------------------------------------------------------
    ;;
    ;; "Note that font-lock in XEmacs doesn't expand face names as
    ;; variables, so we have to use the (eval . FORM) in the font lock
    ;; matchers wherever we use these alias variables."

    (define c-preprocessor-face-name
      (cond ((c-face-name-p 'font-lock-preprocessor-face)
             ;; XEmacs has a font-lock-preprocessor-face.
             'font-lock-preprocessor-face)
            ((c-face-name-p 'font-lock-builtin-face)
             ;; In Emacs font-lock-builtin-face has traditionally been
             ;; used for preprocessor directives.
             'font-lock-builtin-face)
            (else 'font-lock-constant-face)))

    (define c-label-face-name
      (cond ((c-face-name-p 'font-lock-label-face)
             ;; If it happens to occur in the future.  (Well, the more
             ;; pragmatic reason is to get unique faces for the test
             ;; suite.)
             'font-lock-label-face)
            ((c-face-name-p 'font-lock-constant-face)
             'font-lock-constant-face)
            (else
             'font-lock-reference-face)))

    (define c-constant-face-name
      (if (c-face-name-p 'font-lock-constant-face)
          'font-lock-constant-face
          c-label-face-name))

    (define c-reference-face-name
      (cond
       ((c-face-name-p 'font-lock-reference-face)
        'font-lock-reference-face)
       ((c-face-name-p 'font-lock-constant-face)
        'font-lock-constant-face)
       (else c-label-face-name)))

    ;; "This should not mapped to a face that also is used to fontify things
    ;; that aren't comments or string literals."
    (define c-doc-face-name
      (cond ((c-face-name-p 'font-lock-doc-string-face)
             ;; XEmacs.
             'font-lock-doc-string-face)
            ((c-face-name-p 'font-lock-doc-face)
             ;; Emacs 21 and later.
             'font-lock-doc-face)
            (else
             'font-lock-comment-face)))

    (define c-doc-markup-face-name
      (if (c-face-name-p 'font-lock-doc-markup-face)
          'font-lock-doc-markup-face
          c-label-face-name))

    (define c-negation-char-face-name
      (if (c-face-name-p 'font-lock-negation-char-face)
          ;; Emacs 22 has a special face for negation chars.
          'font-lock-negation-char-face
          #f))

    (define (c-make-inverse-face oldface newface)
      ;; "Emacs and XEmacs have completely different face manipulation
      ;; routines. :P"
      (copy-face oldface newface)
      ;; "Emacs. This only looks at the inverse flag in the current frame.
      ;; Other display configurations might be different, but it can only
      ;; show if the same Emacs has frames on e.g. a color and a monochrome
      ;; display simultaneously." The XEmacs `face-property-instance' arm is
      ;; not carried.
      (unless (face-inverse-video-p oldface)
        (invert-face newface)))

    (define c-annotation-face 'c-annotation-face)

    (defface 'c-annotation-face
      '((#t :inherit font-lock-constant-face))
      "Face for highlighting annotations in Java mode and similar modes.")

    ;;------------------------------------------------------------------
    ;; The font-lock helpers (`cc-fonts.el:207'-`:525')
    ;;------------------------------------------------------------------

    ;; "This indicates the \"font locking context\", and is set just before
    ;; fontification is done. If non-nil, it says, e.g., point starts from
    ;; within a #if preprocessor construct."
    (define (c-font-lock-context)
      (buffer-local-value (current-buffer) 'c-font-lock-context #f))
    (define (set!c-font-lock-context value)
      (set-buffer-local-value! (current-buffer) 'c-font-lock-context value))

    (define (c-put-font-lock-face from to face)
      ;; "Put a face on a region (overriding any existing face) in the
      ;; way font-lock would do it."
      ;;
      ;; "This function does a hidden buffer change."
      (put-text-property from to 'face face))

    (define (c-remove-font-lock-face from to)
      ;; "This is the inverse of `c-put-font-lock-face'."
      ;;
      ;; "This function does a hidden buffer change."
      (remove-text-properties from to (list 'face #f)))

    (define (c-put-font-lock-string-face from to)
      ;; "Put `font-lock-string-face' on a string. The surrounding quotes
      ;; are included in Emacs but not in XEmacs. The passed region should
      ;; include them."
      ;;
      ;; "This function does a hidden buffer change."
      (c-put-font-lock-face from to 'font-lock-string-face))

    (define-syntax c-fontify-types-and-refs
      ;; "Like `let*', but additionally activates
      ;; `c-record-type-identifiers' and `c-record-ref-identifiers', and
      ;; fontifies the recorded ranges accordingly on exit."
      ;;
      ;; "This function does hidden buffer changes."
      (syntax-rules ()
        ((_ ((var value) ...) body ...)
         (parameterize ((*c-record-type-identifiers* #t)
                        (*c-record-ref-identifiers* #f))
           (let* ((var value) ...)
             (begin body ...)
             (c-fontify-recorded-types-and-refs))))))

    (define (c-skip-comments-and-strings limit)
      ;; "If the point is within a region fontified as a comment or
      ;; string literal skip to the end of it or to LIMIT, whichever
      ;; comes first, and return t. Otherwise return nil. The match
      ;; data is not clobbered."
      ;;
      ;; "This function might do hidden buffer changes."
      (when-e (c-got-face-at (point) c-literal-faces)
        (while (begin
                 (goto-char (c-next-single-property-change
                             (point) 'face #f limit))
                 (and (< (point) limit)
                      (c-got-face-at (point) c-literal-faces))))
        #t))

    (define (c-make-syntactic-matcher regexp)
      ;; "Returns a ... function suitable for use in place of a regexp
      ;; string in a `font-lock-keywords' matcher, except that only matches
      ;; outside comments and string literals count."
      ;;
      ;; "This function does not do any hidden buffer changes, but the
      ;; generated functions will."
      (lambda (limit)
        (let ((res #f))
          (c-skip-comments-and-strings limit)
          (while (and (setq res (re-search-forward regexp limit #t))
                      (begin
                        (goto-char (match-beginning 0))
                        (or (c-skip-comments-and-strings limit)
                            (begin
                              (goto-char (match-end 0))
                              #f))))
          res))))

    (define (c-make-font-lock-search-form regexp highlights . check-point-args)
      ;; "Return a ... form which will fontify every occurrence of REGEXP
      ;; (a regular expression, NOT a function) between POINT and `limit'
      ;; with HIGHLIGHTS, a list of highlighters as specified on page
      ;; \"Search-based Fontification\" in the elisp manual. If CHECK-POINT
      ;; is non-nil, we will check (< (point) limit) in the main loop."
      ;;
      ;; The form is the procedure it would have been compiled to; see
      ;; the header for the anchored-highlighter representation.
      (let ((check-point (and (pair? check-point-args) (car check-point-args))))
        (lambda (limit)
          ;; REGEXP is a string, or a thunk returning one: Emacs splices
          ;; the REGEXP *expression* into the generated lambda, so a
          ;; variable read there (`c-known-type-key' in
          ;; `c-simple-decl-matchers') happens at match time. A thunk is
          ;; that deferral here.
          (let ((regexp (if (procedure? regexp) (regexp) regexp)))
            (c-skip-comments-and-strings limit)
            (while (if check-point
                     (and (< (point) limit)
                          (re-search-forward regexp limit #t))
                     (re-search-forward regexp limit #t))
            (unless (begin
                      (goto-char (match-beginning 0))
                      (c-skip-comments-and-strings limit))
              (goto-char (match-end 0))
              (for-each
               (lambda (highlight)
                 (if (integer? (car highlight))
                     ;; "e.g. highlight is (1 font-lock-type-face t)"
                     (begin
                       (unless (eq? (nth 2 highlight) #t)
                         (error "The override flag must currently be t in ~a"
                                highlight))
                       (when (nth 3 highlight)
                         (error "The laxmatch flag may currently not be set in ~a"
                                highlight))
                       (save-match-data
                        (c-put-font-lock-face
                         (match-beginning (car highlight))
                         (match-end (car highlight))
                         (nth 1 highlight))))
                     ;; "highlight is an \"ANCHORED HIGHLIGHTER\" of the
                     ;; form (ANCHORED-MATCHER PRE-FORM POST-FORM
                     ;; SUBEXP-HIGHLIGHTERS...)"; the three code slots are
                     ;; thunks here (see the header).
                     (begin
                       (when (nth 3 highlight)
                         (error "Match highlights currently not supported in ~a"
                                highlight))
                       (when (nth 1 highlight) ((nth 1 highlight) limit))   ; PRE
                       (save-match-data ((car highlight) limit))            ; MATCHER
                       (when (nth 2 highlight) ((nth 2 highlight) limit))))) ; POST
               highlights)))))))

    (define (c-make-font-lock-search-function regexp . highlights)
      ;; "This function makes a ... function that works much like a
      ;; matcher element in `font-lock-keywords'. ... REGEXP is the
      ;; matcher, which must be a regexp. Only matches where the
      ;; beginning is outside any comment or string literal are
      ;; significant."
      ;;
      ;; "Note: Replace `byte-compile' with `eval' to debug the generated
      ;; lambda more easily."
      (let ((search (c-make-font-lock-search-form regexp highlights #t)))
        (lambda (limit)
          ;; "The font-lock package in Emacs is known to clobber
          ;; `parse-sexp-lookup-properties' (when it exists)."
          (parameterize ((*parse-sexp-lookup-properties* #t))
            (search limit))
          #f)))

    (define (c-make-font-lock-BO-decl-search-function regexp . highlights)
      ;; "This function makes a ... function that first moves back to the
      ;; beginning of the current declaration (if any), then searches
      ;; forward for matcher elements (as in `font-lock-keywords') and
      ;; fontifies them."
      (let ((search (c-make-font-lock-search-form regexp highlights)))
        (lambda (limit)
          (let ((lit-start (c-literal-start)))
            (when lit-start (goto-char lit-start)))
          (parameterize ((*parse-sexp-lookup-properties* #t))
            (let ((bod-limit (c-determine-limit 1000)))
              (goto-char
               (let ((here (point)))
                 (if (eq? (car (c-beginning-of-decl-1 bod-limit)) 'same)
                     (point)
                     here)))
              (search limit)))
          #f)))

    (define (c-make-font-lock-context-search-function normal . state-stanzas)
      ;; "This function makes a ... function that works much like a matcher
      ;; element in `font-lock-keywords', with the following enhancement:
      ;; the generated function will test for particular \"font lock
      ;; contexts\" at the start of the region ..."
      ;;
      ;; "NORMAL is a list of the form (REGEXP HIGHLIGHTS .....), and is
      ;; used to fontify the \"regular\" bit of the region. STATE-STANZAS
      ;; is list of elements of the form (STATE LIM REGEXP HIGHLIGHTS),
      ;; each element coding one possible font lock context."
      ;;
      ;; LIM is a thunk here: Emacs splices it as a form that is
      ;; evaluated with `limit' in scope, and Scheme has no lexical eval.
      (let ((normal-search
             (c-make-font-lock-search-form (car normal) (cdr normal) #t)))
        (lambda (limit)
          (parameterize ((*parse-sexp-lookup-properties* #t))
            (for-each
             (lambda (stanza)
               (let ((state (car stanza))
                     (lim (nth 1 stanza))
                     (regexp (nth 2 stanza))
                     (highlights (cddr stanza)))
                 (when (eq? (c-font-lock-context) state)
                   (let ((limit (lim)))
                     ((c-make-font-lock-search-form regexp highlights)
                      limit)))))
             state-stanzas)
            ;; "In the next form, check that point hasn't been moved beyond
            ;; `limit' in any of the above stanzas."
            (normal-search limit))
          #f)))

    (define (c-fontify-recorded-types-and-refs)
      ;; "Convert the ranges recorded on `c-record-type-identifiers' and
      ;; `c-record-ref-identifiers' to fontification."
      ;;
      ;; "This function does hidden buffer changes."
      (let ((elem #f))
        (while (pair? (*c-record-type-identifiers*))
          (setq elem (car (*c-record-type-identifiers*)))
          (setq *c-record-type-identifiers*
                (cdr (*c-record-type-identifiers*)))
          (c-put-font-lock-face (car elem) (cdr elem)
                                'font-lock-type-face))
        ;; `'()` is true in Scheme; Emacs's `(while c-record-ref-identifiers)'
        ;; is a test for the list being non-empty.
        (while (pair? (*c-record-ref-identifiers*))
          (setq elem (car (*c-record-ref-identifiers*)))
          (setq *c-record-ref-identifiers*
                (cdr (*c-record-ref-identifiers*)))
          ;; "Note that the reference face is a variable that is
          ;; dereferenced, since it's an alias in Emacs."
          (c-put-font-lock-face (car elem) (cdr elem)
                                c-reference-face-name))))

    (define (c-font-lock-cpp-messages limit)
      ;; "Font lock #error and #warning messages between point and LIMIT.
      ;; Always return nil to prevent a further call to this function. The
      ;; position of point at the end of this function is random."
      ;;
      ;; `c-cpp-messages-re' and `c-cpp-message-match-no' are
      ;; `c-lang-defvar's, which are buffer-local slots here; `c-mode-var'
      ;; is Emacs's `symbol-value' of them (named departure, see
      ;; `cc-defs.scm').
      (while (and (< (point) limit)
                  (re-search-forward (%c-langvar 'c-cpp-messages-re) limit #t))
        (let ((beg (match-beginning (%c-langvar 'c-cpp-message-match-no)))
              (end (match-end (%c-langvar 'c-cpp-message-match-no))))
          ;; "Don't use `c-put-font-lock-string-face' here, since in XEmacs
          ;; that would fail to fontify the first and last characters - We
          ;; don't have any string delimiters in this construction."
          (c-put-font-lock-face beg end 'font-lock-string-face)
          ;; "We replace '(1) (punctuation) syntax-table text properties on
          ;; ' by '(3) (symbol), so that these characters won't later get the
          ;; warning face."
          (goto-char beg)
          (while (and (< (point) end)
                      (c-search-forward-char-property-with-value-on-char
                       'syntax-table '(1) #\' end))
            (c-put-char-property (1- (point)) 'syntax-table '(3)))
          (goto-char end)))
      #f)

    (define (c-font-lock-invalid-single-quotes limit)
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. See elisp/lispref page
      ;; \"Search-based Fontification\"."
      ;;
      ;; "This function fontifies invalid single quotes with
      ;; `font-lock-warning-face'. These are the single quotes which
      ;; o - aren't inside a literal;
      ;; o - are marked with a syntax-table text property value '(1); and
      ;; o - are NOT marked with a non-null c-digit-separator property."
      (let ((limits (c-literal-limits))
            (state #f) (beg #f) (end #f))
        (if limits
            (goto-char (cdr limits)))         ; "Even for being in a ' '"
        (while (< (point) limit)
          (setq beg (point))
          (setq state (parse-partial-sexp (point) limit #f #f #f 'syntax-table))
          (setq end (point))
          (goto-char beg)
          (while (begin
                   (skip-chars-forward "^'" end)
                   (< (point) end))
            (if (and (equal? (c-get-char-property (point) 'syntax-table) '(1))
                     (not (c-get-char-property (point) 'c-digit-separator)))
                (c-put-font-lock-face (point) (1+ (point))
                                      'font-lock-warning-face))
            (forward-char 1))
          (parse-partial-sexp end limit #f #f state 'syntax-table))
        #f))

    (define (c-maybe-font-lock-wrong-style-comments limit)
      ;; "This function will be called from font-lock-for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. See elisp/lispref page
      ;; \"Search-based Fontification\"."
      ;;
      ;; "This function fontifies \"invalid\" comment delimiters with
      ;; `font-lock-warning-face'. A delimiter is \"invalid\" when
      ;; `c-mark-wrong-style-of-comment' is non-nil, and the delimiter style
      ;; is not the default specified by `c-block-comment-flag'."
      (when (*c-mark-wrong-style-of-comment*)
        (let* ((lit (c-semi-pp-to-literal (point)))
               (s (car lit)))                   ; "parse-partial-sexp state."
          ;; "First, deal with and move out of any literal we start in."
          (cond
           ((not (%c-cadr lit)))                ; "Not in a literal"
           ((eq? (%c-cadr lit) 'string)
            (setq s (parse-partial-sexp (point) limit #f #f s 'syntax-table)))
           ((and (not (c-block-comment-flag))   ; "In an \"invalid\" block comment"
                 (eq? (%c-cadr lit) 'c))
            (setq s (parse-partial-sexp (point) limit #f #f s 'syntax-table))
            ;; "Font lock the block comment ender with warning face."
            (when (not (nth 4 s))
              (c-put-font-lock-face (- (point) (length (%c-langvar 'c-block-comment-ender)))
                                    (point) 'font-lock-warning-face)))
           (else                                ; "In a line comment, or a \"valid\" block comment"
            (setq s (parse-partial-sexp (point) limit #f #f s 'syntax-table))))

          (while (< (point) limit)
            (setq s (parse-partial-sexp (point) limit #f #f s 'syntax-table))
            (cond
             ((or (nth 3 s)                     ; "In a string"
                  (and (nth 4 s)                ; "In a comment"
                       (eq? (nth 7 s)           ; "Comment style"
                            (if (c-block-comment-flag)
                                #f                  ; "Block comment"
                                1))))               ; "Line comment"
              ;; "Move over a \"valid\" literal."
              (setq s (parse-partial-sexp (point) limit #f #f s 'syntax-table)))
             ((nth 4 s)                         ; "In an invalid comment"
              ;; "Fontify the invalid comment opener."
              (c-put-font-lock-face (nth 8 s) (point) 'font-lock-warning-face)
              ;; "Move to end of comment or LIMIT."
              (setq s (parse-partial-sexp (point) limit #f #f s 'syntax-table))
              ;; "Fontify an invalid block comment ender, if that's what we have."
              (when (and (not (c-block-comment-flag))
                         (not (nth 4 s)))       ; "We're outside the comment"
                (c-put-font-lock-face
                 (- (point) (length (%c-langvar 'c-block-comment-ender)))
                 (point) 'font-lock-warning-face)))))))
      #f)

    (c-lang-defconst c-cpp-matchers
      "Font lock matchers for preprocessor directives and purely lexical
stuff.  Used on level 1 and higher."

      ;; "Note: `c-font-lock-declarations' assumes that no matcher here
      ;; sets `font-lock-type-face' in languages where
      ;; `c-recognize-<>-arglists' is set."
      t (append
         ;; "Fontify \"invalid\" comment delimiters"
         (if (and (%c-true (c-lang-const c-block-comment-starter))
                  (%c-true (c-lang-const c-line-comment-starter)))
             (list c-maybe-font-lock-wrong-style-comments)
             '())
         (if (%c-true (c-lang-const c-opt-cpp-prefix))
             (let* ((noncontinued-line-end "\\(\\=\\|\\(\\=\\|[^\\]\\)[\n\r]\\)")
                    (ncle-depth (regexp-opt-depth noncontinued-line-end))
                    (sws-depth (c-lang-const c-syntactic-ws-depth))
                    (nsws-depth (c-lang-const c-nonempty-syntactic-ws-depth)))
               (append
                ;; "The stuff after #error and #warning is a message, so
                ;; fontify it as a string."
                (if (%c-true (c-lang-const c-cpp-message-directives))
                    (list c-font-lock-cpp-messages)
                    '())
                ;; "Fontify filenames in #include <...> as strings."
                ;;
                ;; "We used to use a font-lock \"anchored matcher\" here for
                ;; the paren syntax. This failed when the \">\" was at EOL,
                ;; since `font-lock-fontify-anchored-keywords' terminated its
                ;; loop at EOL without executing our lambda form at all.
                ;; (2024-10): The paren syntax is now handled in
                ;; before/after-change functions."
                (if (%c-true (c-lang-const c-cpp-include-directives))
                    (list (list (concat noncontinued-line-end
                                        "\\("  ; "To make the next ^ special."
                                        (c-lang-const c-cpp-include-key)
                                        "\\)"
                                        (c-lang-const c-syntactic-ws)
                                        "\\(<\\([^>\n\r]*\\)>?\\)")
                                (+ ncle-depth 1
                                   (regexp-opt-depth (c-lang-const c-cpp-include-key))
                                   sws-depth
                                   1)     ; "(if (featurep 'xemacs) 2 1)"
                                'font-lock-string-face #t))
                    '())
                ;; "#define."
                (if (%c-true (c-lang-const c-opt-cpp-macro-define))
                    (list
                     (c-make-font-lock-search-function
                      (concat
                       noncontinued-line-end
                       (c-lang-const c-opt-cpp-prefix)
                       (c-lang-const c-opt-cpp-macro-define)
                       (c-lang-const c-nonempty-syntactic-ws)
                       "\\(" (c-lang-const c-symbol-key)  ; "1 + ncle + nsws"
                       "\\)"
                       (concat "\\("  ; "2 + ncle + nsws + c-sym-key"
                               ;; "Macro with arguments - a \"function\"."
                               "\\((\\)"  ; "3 + ncle + nsws + c-sym-key"
                               "\\|"
                               ;; "Macro without arguments - a \"variable\"."
                               "\\([^(]\\|$\\)"
                               "\\)"))
                      (list
                       (lambda (limit)
                          (if (match-beginning
                               (+ 3 ncle-depth nsws-depth
                                  (c-lang-const c-symbol-key-depth)))
                              ;; "\"Function\". Fontify the name and the arguments."
                              (save-restriction
                                (c-put-font-lock-face
                                 (match-beginning (+ 1 ncle-depth nsws-depth))
                                 (match-end (+ 1 ncle-depth nsws-depth))
                                 'font-lock-function-name-face)
                                (goto-char
                                 (match-end
                                  (+ 3 ncle-depth nsws-depth
                                     (c-lang-const c-symbol-key-depth))))
                                (narrow-to-region (point-min) limit)
                                (while (and
                                        (begin
                                          (c-forward-syntactic-ws)
                                          (looking-at (c-lang-const c-symbol-key)))
                                        (begin
                                          (c-put-font-lock-face
                                           (match-beginning 0) (match-end 0)
                                           'font-lock-variable-name-face)
                                          (goto-char (match-end 0))
                                          (c-forward-syntactic-ws)
                                          (eq? (char-after) #\,)))
                                  (forward-char 1)))
                              ;; "\"Variable\"."
                              (c-put-font-lock-face
                               (match-beginning (+ 1 ncle-depth nsws-depth))
                               (match-end (+ 1 ncle-depth nsws-depth))
                               'font-lock-variable-name-face))))))
                    '())
                ;; "Fontify cpp function names in preprocessor
                ;; expressions in #if and #elif."
                (if (and (%c-true (c-lang-const c-cpp-expr-directives))
                         (%c-true (c-lang-const c-cpp-expr-functions)))
                    (let ((ced-re (c-make-keywords-re #f
                                                      (c-lang-const c-cpp-expr-directives)))
                          (cef-re (c-make-keywords-re #f
                                                      (c-lang-const c-cpp-expr-functions))))
                      (list
                       (c-make-font-lock-context-search-function
                        (cons (concat noncontinued-line-end
                                      (c-lang-const c-opt-cpp-prefix)
                                      ced-re  ; "1 + ncle-depth"
                                      ;; "Match the whole logical line to look
                                      ;; for the functions in."
                                      "\\(\\\\\\(.\\|[\n\r]\\)\\|[^\n\r]\\)*")
                              (list
                               (list
                                (lambda (limit)
                                  (let ((limit (match-end 0)))
                                    (while (re-search-forward cef-re limit 'move)
                                      (c-put-font-lock-face
                                       (match-beginning 1) (match-end 1)
                                       c-preprocessor-face-name))))
                                (lambda (limit)
                                  (goto-char (match-end (1+ ncle-depth)))))))
                        (list 'in-cpp-expr
                              (lambda ()
                                (save-excursion (c-end-of-macro) (point)))
                              cef-re
                              (list 1 c-preprocessor-face-name #t)))))
                    '())
                ;; "Fontify the directive names."
                (list
                 (c-make-font-lock-search-function
                  (concat noncontinued-line-end
                          "\\("
                          (c-lang-const c-opt-cpp-prefix)
                          "[" (c-lang-const c-symbol-chars) "]+"
                          "\\)")
                  (list (1+ ncle-depth) c-preprocessor-face-name #t)))
                ;; `(eval . (list MATCHER (+ ncle-depth 1)
                ;;               c-negation-char-face-name 'append))', with the
                ;; element it evaluates to written out.
                (list (list (c-make-syntactic-matcher
                             (concat noncontinued-line-end
                                     (c-lang-const c-opt-cpp-prefix)
                                     "if\\(n\\)def\\_>"))
                            (+ ncle-depth 1)
                            c-negation-char-face-name
                            'append))))
             '())
         ;; "Recognize hashbangs in Pike."
         (if (c-major-mode-is 'pike-mode)
             (list (list "\\`#![^\n\r]*" 0 c-preprocessor-face-name))
             '())
         ;; "Make hard spaces visible through an inverted
         ;; `font-lock-warning-face'."
         ;;
         ;; `(eval . (list "\240" 0 (progn ... ''c-nonbreakable-space-face)))'
         ;; with the element it evaluates to written out.
         (list (list (string (integer->char #xA0))
                     0
                     (begin
                       (unless (c-face-name-p 'c-nonbreakable-space-face)
                         (c-make-inverse-face 'font-lock-warning-face
                                              'c-nonbreakable-space-face))
                       'c-nonbreakable-space-face)))))

    (define (c-font-lock-complex-decl-prepare limit)
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. ..."
      ;;
      ;; "Called before any of the matchers in `c-complex-decl-matchers'."
      ;;
      ;; "This function does hidden buffer changes."
      (c-skip-comments-and-strings limit)
      (when-e (< (point) limit)

        ;; "Clear the c-type char properties which mark the region, to
        ;; recalculate them properly. The most interesting properties are
        ;; those put on the closest token before the region."
        (save-excursion
          (let ((pos (point)))
            (c-backward-syntactic-ws (max (- (point) 500) (point-min)))
            (when (and (not (bobp))
                       (memv (c-get-char-property (- (point) 1) 'c-type)
                             '(c-decl-arg-start
                               c-decl-end
                               c-decl-id-start
                               c-decl-type-start
                               c-not-decl)))
              (setq pos (- (point) 1)))
            (c-clear-char-properties pos limit 'c-type)
            (c-clear-char-properties pos limit 'c-<>-c-types-set)))

        ;; "Update `c-state-cache' to the beginning of the region. This
        ;; will make `c-beginning-of-syntax' go faster when it's used later
        ;; on, and it's near the point most of the time."
        (c-parse-state)

        ;; "Check if the fontified region starts inside a declarator list
        ;; so that `c-font-lock-declarators' should be called at the start.
        ;; The declared identifiers are font-locked correctly as types, if
        ;; that is what they are."
        (let ((prop (save-excursion
                      (c-backward-syntactic-ws (max (- (point) 500)
                                                    (point-min)))
                      (unless (bobp)
                        (c-get-char-property (- (point) 1) 'c-type)))))
          (when (memv prop '(c-decl-id-start c-decl-type-start))
            (c-forward-syntactic-ws limit)
            (c-font-lock-declarators limit #t (eq? prop 'c-decl-type-start)
                                     (not (c-bs-at-toplevel-p (point))))))

        ;; "This indicates the \"font locking context\", and is set just
        ;; before fontification is done. If non-nil, it says, e.g., point
        ;; starts from within a #if preprocessor construct."
        (set!c-font-lock-context
         (save-excursion
           (let ((re (%c-langvar 'c-cpp-expr-intro-re)))
             (if (and re
                      (c-beginning-of-macro)
                      (looking-at re))
                 'in-cpp-expr
                 #f))))
        #f))

    (define (c-font-lock-<>-arglists limit)
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. ..."
      ;;
      ;; "Fontify types and references in names containing angle bracket
      ;; arglists from the point to LIMIT. Note that
      ;; `c-font-lock-declarations' has already handled many of them."
      ;;
      ;; "This function might do hidden buffer changes."
      (c-skip-comments-and-strings limit)
      (when-e (< (point) limit)
        ;; Emacs `let'-binds `parse-sexp-lookup-properties',
        ;; `c-parse-and-markup-<>-arglists' and `c-restricted-<>-arglists'
        ;; here; the three are parameters, so this is a `parameterize'.
        (parameterize ((*parse-sexp-lookup-properties* #t)
                       (*c-parse-and-markup-<>-arglists* #t)
                       (*c-restricted-<>-arglists* #f))
          (let ((id-start #f) (id-end #f) (id-face #f)
                (pos #f) (kwd-sym #f) (old-pos #f))
            (while (and (< (point) limit)
                        (setq old-pos (point))
                        (c-syntactic-re-search-forward "<" limit #t #f #t))
              (setq pos (point))
              (save-excursion
                (backward-char)
                (c-backward-syntactic-ws old-pos)
                (let ((re (concat "\\(\\`\\|"
                                  (%c-langvar 'c-nonsymbol-key) "\\)\\("
                                  (%c-langvar 'c-symbol-key) "\\)\\=")))
                  (if (re-search-backward re old-pos #t)
                      (begin
                        (setq id-start (match-beginning 2))
                        (setq id-end (match-end 2)))
                      (begin
                        (setq id-start #f)
                        (setq id-end #f)))))

              (when id-start
                (goto-char id-start)
                (unless (c-skip-comments-and-strings limit)
                  (setq kwd-sym #f)
                  (*c-restricted-<>-arglists* #f)
                  (setq id-face (get-text-property id-start 'face))

                  (if (cond
                       ((eq? id-face 'font-lock-type-face)
                        ;; "The identifier got the type face so it has
                        ;; already been handled in
                        ;; `c-font-lock-declarations'."
                        #f)

                       ((eq? id-face 'font-lock-keyword-face)
                        (when-e
                            (let ((re (%c-langvar 'c-opt-<>-sexp-key)))
                              (and re (looking-at re)))
                          ;; "There's a special keyword before the \"<\"
                          ;; that tells that it's an angle bracket arglist."
                          (setq kwd-sym (c-keyword-sym (match-string 2)))
                          #t))

                       (else
                        ;; "There's a normal identifier before the \"<\".
                        ;; If we're not in a declaration context then we
                        ;; set `c-restricted-<>-arglists' to avoid
                        ;; recognizing templates in function calls like
                        ;; \"foo (a < b, c > d)\"."
                        (c-backward-syntactic-ws)
                        (when (and (memv (char-before) (list #\( #\,))
                                   (not (eq? (get-text-property
                                              (- (point) 1) 'c-type)
                                             'c-decl-arg-start)))
                          (*c-restricted-<>-arglists* #t))
                        #t))

                      (begin
                        (goto-char (- pos 1))
                        ;; "Check for comment/string both at the
                        ;; identifier and at the \"<\"."
                        (unless (c-skip-comments-and-strings limit)

                          (c-fontify-types-and-refs
                              ()
                            (when (c-forward-<>-arglist
                                   (c-keyword-member kwd-sym 'c-<>-type-kwds))
                              (when (and (%c-langvar 'c-opt-identifier-concat-key)
                                         (not (get-text-property
                                               id-start 'face)))
                                (c-forward-syntactic-ws)
                                (let ((re (%c-langvar
                                           'c-opt-identifier-concat-key)))
                                  (cond
                                   ((and re (looking-at re))
                                    (c-put-font-lock-face id-start id-end
                                                          c-reference-face-name))
                                   ((eqv? (char-after) #\())
                                   (else
                                    (c-put-font-lock-face
                                     id-start id-end
                                     'font-lock-type-face)))))))

                          (goto-char pos)))
                      (goto-char pos))))))))
      #f)

    (define (c-font-lock-declarators limit list types not-top . rest)
      ;; "Assuming the point is at the start of a declarator in a
      ;; declaration, fontify the identifier it declares. (If TYPES is t,
      ;; it does this via the macro `c-fontify-types-and-refs'.)"
      ;;
      ;; "If LIST is non-nil, also fontify the ids in any following
      ;; declarators in a comma separated list (e.g. \"foo\" and \"*bar\"
      ;; in \"int foo = 17, *bar;\"); additionally, mark the commas with
      ;; c-type property 'c-decl-id-start or 'c-decl-type-start (according
      ;; to TYPES). Stop at LIMIT."
      ;;
      ;; "If TYPES is t, fontify all identifiers as types; if it is a
      ;; number, a buffer position, additionally set the `c-typedef' text
      ;; property on the keyword at that position; if it is nil fontify as
      ;; either variables or functions, otherwise TYPES is a face to use.
      ;; If NOT-TOP is non-nil, we are not at the top-level (\"top-level\"
      ;; includes being directly inside a class or namespace, etc.)."
      ;;
      ;; "TEMPLATE-CLASS is non-nil when the declaration is in template
      ;; delimiters and was introduced by, e.g. \"typename\" or \"class\",
      ;; such that if there is a default (introduced by \"=\"), it will be
      ;; fontified as a type. E.g. \"<class X = Y>\"."
      ;;
      ;; "ACCEPT-ANON is non-nil when we accept anonymous declarators."
      ;;
      ;; "Nil is always returned. The function leaves point at the
      ;; delimiter after the last declarator it processes."
      (let ((template-class (if (pair? rest) (car rest) #f))
            (accept-anon (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f)))
        (c-fontify-types-and-refs
            ()
          ;; "If we're altering the declarators in a typedef, we need to
          ;; scan ALL of them because of the way we check for changes."
          (let ((c-do-decl-limit (if (number? types) (point-max) limit))
                (decl-ids '()))
            (c-do-declarators
             c-do-decl-limit
             list not-top
             (cond ((or (number? types) (eq? types #t))
                    'c-decl-type-start)
                   ((not types) 'c-decl-id-start)
                   (else #f))
             (lambda (id-start id-end end-pos not-top* is-function init-char)
               (if (or (number? types) (eq? types #t))
                   (when id-start
                     ;; "Register and fontify the identifier as a type."
                     (parameterize ((*c-promote-possible-types* #t))
                       (goto-char id-start)
                       (c-forward-type))
                     (when (number? types)
                       (push (buffer-substring-no-properties id-start id-end)
                             decl-ids)))
                   (when id-start
                     (goto-char id-start)
                     (when (%c-langvar 'c-opt-identifier-prefix-key)
                       (unless (and (looking-at (%c-langvar 'c-opt-identifier-prefix-key)) ; "For operator~"
                                    (eq? (match-end 1) id-end))
                         (while (and (< (point) id-end)
                                     (re-search-forward
                                      (%c-langvar 'c-opt-identifier-prefix-key)
                                      id-end #t))
                           (c-forward-syntactic-ws c-do-decl-limit))))
                     ;; "Only apply the face when the text doesn't have one
                     ;; yet. Exception: The \"\" in C++'s operator\"\" will
                     ;; already wrongly have string face."
                     (let ((face (get-text-property (point) 'face)))
                       (when (or (not face)
                                 (eq? face 'font-lock-string-face))
                         (c-put-font-lock-face
                          (point) id-end
                          (cond
                           ((not (or (not types) (eq? types #t))) types)
                           (is-function 'font-lock-function-name-face)
                           (else 'font-lock-variable-name-face)))))
                     ;; "Fontify any _tag in C++'s operator\"\" _tag."
                     (when (and (c-major-mode-is 'c++-mode)
                                (equal? (buffer-substring-no-properties
                                         id-start id-end)
                                        "\"\""))
                       (goto-char id-end)
                       (c-forward-syntactic-ws c-do-decl-limit)
                       (when (c-on-identifier)
                         (c-put-font-lock-face
                          (point)
                          (begin (c-forward-over-token) (point))
                          'font-lock-function-name-face)))))
               (and template-class
                    (eqv? init-char #\=)          ; "C++ \"<class X = Y>\"?"
                    (begin
                      (goto-char end-pos)
                      (c-forward-token-2 1 #f c-do-decl-limit) ; "Over \"=\""
                      (parameterize ((*c-promote-possible-types* #t))
                        (c-forward-type #t)))))
             accept-anon)                          ; "Last argument to `c-do-declarators'."
            ;; "If we've changed types declared by a \"typedef\", update the
            ;; `c-typedef' text property."
            (when (number? types)
              (let* ((old-decl-ids (c-get-char-property types 'c-typedef))
                     (old-types (c--set-difference old-decl-ids decl-ids
                                                   ':test equal?))
                     (new-types (c--set-difference decl-ids old-decl-ids
                                                   ':test equal?)))
                (dolist (type old-types)
                  (c-unfind-type type))
                ;; "The new types have already been added to
                ;; `c-found-types', as needed."
                (when (or old-types new-types)
                  (c-put-char-property types 'c-typedef decl-ids)))))
          #f)))

    (define (c-get-fontification-context match-pos not-front-decl . rest)
      ;; "Return a cons (CONTEXT . RESTRICTED-<>-ARGLISTS) for MATCH-POS.
      ;; NOT-FRONT-DECL is non-nil when a declaration later in the buffer
      ;; than MATCH-POS has already been parsed. TOPLEV is non-nil when
      ;; MATCH-POS is known to be at \"top level\", i.e. outside any braces,
      ;; or directly inside a namespace, class, etc."
      ;;
      ;; "CONTEXT is the fontification context of MATCH-POS, and is one of
      ;; 'decl, '<>, 'arglist, 'generic, 'top, nil or 'not-decl; see
      ;; `cc-fonts.el' for the whole description."
      ;;
      ;; `cond-e' is Emacs's `cond': where nothing matches it answers nil,
      ;; and every one of these tests feeds an `and' or an `or'. A plain
      ;; Scheme `cond' would answer the unspecified value, which is true.
      (let ((toplev (if (pair? rest) (car rest) #f))
            (type (and (> match-pos (point-min))
                       (c-get-char-property (1- match-pos) 'c-type)))
            (id-pos #f)
            (tok-end-pos #f))
        (cond-e
         ;; "Are we just after something like \"(foo((bar))\" ?"
         ((and (eqv? (char-before match-pos) #\))
               (c-go-list-backward match-pos)
               (begin
                 (c-backward-syntactic-ws)
                 (setq tok-end-pos (point))
                 (cond-e
                  ((and (setq id-pos (c-on-identifier))
                        (goto-char id-pos)
                        (begin
                          (c-backward-syntactic-ws)
                          (eqv? (char-before) #\()))
                   (c-get-fontification-context (point) not-front-decl toplev))
                  ((begin
                     (goto-char tok-end-pos)
                     (and (= (c-backward-token-2) 0)
                          (looking-at (%c-langvar 'c-type-internal-paren-key))))
                   (list 'not-decl))))))
         ((not (memv (char-before match-pos) (list #\( #\, #\[ #\< #\{)))
          (list (and toplev 'top)))
         ;; "A control flow expression or a decltype, etc."
         ((and (eqv? (char-before match-pos) #\()
               (save-excursion
                 (goto-char match-pos)
                 (backward-char 1)
                 (c-backward-token-2)
                 (cond-e
                  ((looking-at (%c-langvar 'c-paren-stmt-key))
                   ;; "Allow comma separated <> arglists in for statements."
                   (list #f))
                  ((or (looking-at (%c-langvar 'c-block-stmt-2-key))
                       (looking-at (%c-langvar 'c-block-stmt-1-2-key))
                       (looking-at (%c-langvar 'c-typeof-key))
                       (looking-at (%c-langvar 'c-type-internal-paren-key)))
                   (cons #f #t))
                  (else #f)))))
         ;; "Near BOB."
         ((<= match-pos (point-min))
          (cons 'arglist #t))
         ;; "Got a cached hit in a declaration arglist."
         ((eq? type 'c-decl-arg-start)
          (list 'decl))
         ;; "We're inside (probably) a brace list."
         ((eq? type 'c-not-decl)
          (list 'not-decl))
         ;; "Inside a C++11 lambda function arglist."
         ((and (c-major-mode-is 'c++-mode)
               (eqv? (char-before match-pos) #\()
               (save-excursion
                 (goto-char match-pos)
                 (c-backward-token-2)
                 (and
                  (c-safe (goto-char (scan-sexps (point) -1)))
                  (c-looking-at-c++-lambda-capture-list))))
          (c-put-char-property (1- match-pos) 'c-type 'c-decl-arg-start)
          (list 'decl))
         ;; "We're inside a brace list/enum list."
         ((and (eqv? (char-before match-pos) #\{)
               (or (c-at-enum-brace (1- match-pos))
                   (c-at-bracelist-p (1- match-pos) (%c-cdr (c-parse-state)))))
          (c-put-char-property (1- match-pos) 'c-type 'c-not-decl)
          (list 'not-decl))
         ;; "We're inside an \"ordinary\" open brace."
         ((eqv? (char-before match-pos) #\{)
          (list (and toplev 'top)))
         ;; "Inside an angle bracket arglist."
         ((or (eq? type 'c-<>-arg-sep)
              (eqv? (char-before match-pos) #\<))
          (list '<>))
         ;; "Got a cached hit in some other type of arglist."
         (type
          (cons 'arglist #t))
         ;; "We're at a C++ uniform initialization."
         ((and (c-major-mode-is 'c++-mode)
               (eqv? (char-before match-pos) #\()
               (save-excursion
                 (goto-char match-pos)
                 (and
                  (= (c-backward-token-2 2) 0)
                  (looking-at (%c-langvar 'c-identifier-start))
                  (c-got-face-at (point) '(font-lock-variable-name-face)))))
          (list 'not-decl))
         ((and not-front-decl
               ;; "The point is within the range of a previously encountered
               ;; type decl expression, so the arglist is probably one that
               ;; contains declarations. However, if `c-recognize-paren-inits'
               ;; is set it might also be an initializer arglist."
               (or (not (%c-langvar 'c-recognize-paren-inits))
                   (save-excursion
                     (goto-char match-pos)
                     (not (c-back-over-member-initializers)))))
          ;; "The result of this check is cached with a char property on the
          ;; match token, so that we can look it up again when refontifying
          ;; single lines in a multiline declaration."
          (c-put-char-property (1- match-pos) 'c-type 'c-decl-arg-start)
          (list 'decl))
         ;; "Got (an) open paren(s) preceded by an arith operator."
         ((and (eqv? (char-before match-pos) #\()
               (save-excursion
                 (goto-char match-pos)
                 (while (and (= (c-backward-token-2) 0)
                             (eqv? (char-after) #\()))
                 (looking-at (%c-langvar 'c-arithmetic-op-regexp))))
          (list #f))
         ;; "In a C++ member initialization list."
         ((and (eqv? (char-before match-pos) #\,)
               (c-major-mode-is 'c++-mode)
               (save-excursion
                 (goto-char match-pos)
                 (c-back-over-member-initializers)))
          (c-put-char-property (1- match-pos) 'c-type 'c-not-decl)
          (list 'not-decl))
         ;; "In a C11 _Generic construct."
         ((and (%c-langvar 'c-generic-key)
               (eqv? (char-before match-pos) #\,)
               (save-excursion
                 (and (c-go-up-list-backward match-pos
                                             (max (- (point) 2000)
                                                  (point-min)))
                      (= (c-backward-token-2) 0)
                      (looking-at (%c-langvar 'c-generic-key)))))
          (list 'generic))
         ;; "At start of a declaration inside a declaration paren."
         ((save-excursion
            (goto-char match-pos)
            (and (memv (char-before match-pos) (list #\( #\,))
                 (c-go-up-list-backward match-pos
                                        ; "c-determine-limit is too slow, here."
                                        (max (- (point) 2000) (point-min)))
                 (eqv? (char-after) #\()
                 (let ((type (c-get-char-property (point) 'c-type)))
                   (or (memv type '(c-decl-arg-start c-decl-type-start))
                       (begin
                         (c-backward-syntactic-ws)
                         (cond-e
                          ((and toplev
                                (eqv? (char-before) #\)))
                           (save-excursion
                             (and (c-go-list-backward #f (max (- (point) 2000)
                                                              (point-min)))
                                  (eqv? (char-after) #\()
                                  (begin
                                    (c-backward-syntactic-ws)
                                    (c-back-over-compound-identifier)))))
                          ((save-excursion
                             (and
                              (c-back-over-compound-identifier)
                              (begin
                                (c-backward-syntactic-ws)
                                (or (bobp)
                                    (begin
                                      (setq type (c-get-char-property (1- (point))
                                                                      'c-type))
                                      (memv type '(c-decl-arg-start
                                                   c-decl-type-start))))))))
                          ((and (= (c-backward-token-2) 0)
                                (looking-at (%c-langvar 'c-fun-name-substitute-key))))))))))
          ;; "Cache the result of this test for next time around."
          (c-put-char-property (1- match-pos) 'c-type 'c-decl-arg-start)
          (list 'decl))
         (else (cons 'arglist #t)))))

    (define (c-font-lock-single-decl limit decl-or-cast match-pos context toplev)
      ;; "Try to fontify a single declaration, together with all its
      ;; declarators. Return nil if we're successful, non-nil if we fail.
      ;; POINT should be positioned at the start of the putative declaration
      ;; before calling. POINT is left undefined by this function."
      ;;
      ;; "LIMIT sets a maximum position we'll fontify out to. DECL-OR-CAST
      ;; has the form of a result from `c-forward-decl-or-cast-1', and must
      ;; indicate a declaration (i.e. not be nil or 'cast). MATCH-POS is the
      ;; position after the last symbol before the decl. CONTEXT is the
      ;; context of the current decl., as determined by
      ;; c-get-fontification-context. TOPLEV is non-nil if the decl. is at
      ;; the top level (i.e. outside any braces, or directly inside a class,
      ;; namespace, etc.)"
      (if (save-excursion
            (and
             (%c-caddr decl-or-cast)            ; "maybe-expression flag."
             (c-go-up-list-backward #f (c-determine-limit 500))
             (eqv? (char-after) #\()
             (begin (c-backward-syntactic-ws)
                    (c-simple-skip-symbol-backward))
             (looking-at (%c-langvar 'c-paren-stmt-key))
             (begin
               (goto-char match-pos)
               (while (and (eqv? (char-before) #\))
                           (c-go-list-backward))
                 (c-backward-syntactic-ws))
               (eqv? (char-before) #\;))))
          ;; "We've got an expression in \"for\" parens. Remove the \"type\"
          ;; that would spuriously get fontified."
          (let ((elt (and (pair? (*c-record-type-identifiers*))
                          (assq (%c-car (%c-cdr (%c-cddr decl-or-cast)))
                                (*c-record-type-identifiers*)))))
            (when elt
              (*c-record-type-identifiers*
               (c-delq-from-dotted-list elt (*c-record-type-identifiers*))))
            #t)
          ;; "Back up to the type to fontify the declarator(s)."
          (begin
            (goto-char (car decl-or-cast))
            (let ((decl-list
                   (if (not (or (not context) (eq? context 'top)))
                       ;; "Should normally not fontify a list of declarators
                       ;; inside an arglist, but the first argument in the ';'
                       ;; separated list of a \"for\" statement is an
                       ;; exception."
                       (when (eqv? (char-before match-pos) #\()
                         (save-excursion
                           (goto-char (- match-pos 1))
                           (c-backward-syntactic-ws)
                           (and (c-simple-skip-symbol-backward)
                                (looking-at (%c-langvar 'c-paren-stmt-key)))))
                       #t))
                  (template-class (and (eq? context '<>)
                                       (save-excursion
                                         (goto-char match-pos)
                                         (c-forward-syntactic-ws)
                                         (looking-at (%c-langvar 'c-template-typename-key))))))
              ;; "Fix the `c-decl-id-start' or `c-decl-type-start' property
              ;; before the first declarator if it's a list.
              ;; `c-font-lock-declarators' handles the rest."
              (when decl-list
                (save-excursion
                  (c-backward-syntactic-ws)
                  (unless (bobp)
                    (c-put-char-property (- (point) 1) 'c-type
                                         (if (%c-cadr decl-or-cast)
                                             'c-decl-type-start
                                             'c-decl-id-start)))))
              (c-font-lock-declarators
               (min limit (point-max))
               decl-list
               (cond-e ((not (%c-cadr decl-or-cast)) #f)
                       ((%c-cadr (%c-cadr decl-or-cast)))
                       (else #t))
               (not toplev)
               template-class
               (or (eq? context 'decl) (eq? context '<>)))
              ;; "A declaration has been successfully identified, so do all
              ;; the fontification of types and refs that've been recorded."
              (c-fontify-recorded-types-and-refs)
              #f))))

    (define (c-font-lock-declarations limit)
      ;; "Fontify all the declarations, casts and labels from the point to
      ;; LIMIT. Assumes that strings and comments have been fontified
      ;; already."
      ;;
      ;; "This function will be called from font-lock for a region bounded by
      ;; POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. See elisp/lispref page
      ;; \"Search-based Fontification\"."
      (c-skip-comments-and-strings limit)
      (when (< (point) limit)
        (save-restriction
          ;; The variables Emacs `let'-binds here are the tree's parameters
          ;; when they are dynamically bound: `c-restricted-<>-arglists' is
          ;; read several calls down in `c-forward-type', and the three
          ;; recording flags are read by `c-fontify-types-and-refs'.
          (parameterize ((*c-restricted-<>-arglists* #f)
                         (*c-record-type-identifiers* #t)
                         (*c-record-ref-identifiers* '())
                         (*c-parse-and-markup-<>-arglists* #t)
                         (*parse-sexp-lookup-properties* #t))
            (let ((start-pos #f)
                  (context #f)
                  (last-cast-end #f)
                  (decl-or-cast #f)
                  (max-type-decl-end 0)
                  (max-type-decl-end-before-token 0)
                  (max-<>-end 0)
                  (label-type #f)
                  (list-bounds #f))
              ;; "Below we fontify a whole declaration even when it crosses the
              ;; limit, to avoid gaps when jit/lazy-lock fontifies the file a
              ;; block at a time. ... To avoid that we narrow to the limit if
              ;; the region to fontify is a single line."
              (if (<= limit (c-point 'bonl))
                  (narrow-to-region
                   (point-min)
                   (save-excursion
                     ;; "Narrow after any operator chars following the limit
                     ;; though, since those characters can be useful in
                     ;; recognizing a declaration (in particular the '{' that
                     ;; opens a function body after the header)."
                     (goto-char limit)
                     (skip-chars-forward (%c-langvar 'c-nonsymbol-chars))
                     (point))))
              (c-find-decl-spots
               limit
               (%c-langvar 'c-decl-start-re)
               (c-lang-const c-maybe-decl-faces)

               (lambda (match-pos inside-macro . toplev-args)
                 ;; "Note to maintainers: don't use `limit' inside this
                 ;; lambda form; c-find-decl-spots sometimes narrows to less
                 ;; than `limit'."
                 (let ((toplev (if (pair? toplev-args) (car toplev-args) #f)))
                   (setq start-pos (point))
                   (when-e
                       ;; "The result of the form below is true when we don't
                       ;; recognize a declaration or cast, and we don't
                       ;; recognize a \"non-decl\", typically a brace list."
                       (if (or (and (eq? (get-text-property (point) 'face)
                                        'font-lock-keyword-face)
                                    (looking-at (%c-langvar 'c-not-decl-init-keywords)))
                               (and (c-macro-with-semi-re)
                                    (looking-at (c-macro-with-semi-re)))) ; 2008-11-04
                           ;; "Don't do anything more if we're looking at a
                           ;; keyword that can't start a declaration."
                           #t

                           ;; "Set `context' and `c-restricted-<>-arglists'.
                           ;; Look for \"<\" for the sake of C++-style template
                           ;; arglists. Ignore \"(\" when it's part of a
                           ;; control flow construct (e.g. \"for (\")."
                           (begin
                             (let ((got-context
                                    (c-get-fontification-context
                                     match-pos
                                     (< match-pos (if inside-macro
                                                      max-type-decl-end-before-token
                                                      max-type-decl-end))
                                     toplev)))
                               (setq context (car got-context))
                               (*c-restricted-<>-arglists* (cdr got-context)))

                             ;; "Check we haven't missed a preceding
                             ;; \"typedef\"."
                             (when (not (looking-at (%c-langvar 'c-typedef-key)))
                               (c-backward-syntactic-ws
                                (max (- (point) 1000) (point-min)))
                               (c-backward-token-2)
                               (or (looking-at (%c-langvar 'c-typedef-key))
                                   (goto-char start-pos)))

                             ;; "In QT, \"more\" is an irritating keyword that
                             ;; expands to nothing. We skip over it to prevent
                             ;; recognition of \"more slots: <symbol>\" as a
                             ;; bitfield declaration."
                             (when (and (c-major-mode-is 'c++-mode)
                                        (looking-at "\\_<\\(more\\)\\_>"))
                               (goto-char (match-end 1))
                               (c-forward-syntactic-ws))

                             ;; "Now analyze the construct."
                             (cond-e
                              ((eq? context 'not-decl)
                               (setq decl-or-cast #f)
                               (if (c-syntactic-re-search-forward
                                    "," (min limit (point-max)) 'at-limit #t)
                                   (c-put-char-property (- (point) 1) 'c-type
                                                        'c-not-decl))
                               #f)
                              ((eq? context 'generic)
                               (c-font-lock-c11-generic-clause))

                              ;; "K&R parameters."
                              ((and
                                (%c-langvar 'c-recognize-knr-p)
                                (or toplev inside-macro)
                                (eq? context 'decl)
                                (setq list-bounds (c-in-id-arglist))
                                (save-excursion
                                  (goto-char (car list-bounds))
                                  (and (= (c-backward-token-2) 0)
                                       (eq? (point) (c-on-identifier))))
                                (save-excursion
                                  (goto-char (cdr list-bounds))
                                  (c-forward-syntactic-ws)
                                  (not (memv (char-after) (list #\; #\{ #\? #\: #\,)))))
                               ;; "Nothing to fontify."
                               (goto-char (cdr list-bounds)))

                              (else
                               (setq decl-or-cast
                                     (c-forward-decl-or-cast-1
                                      match-pos context last-cast-end inside-macro))

                               ;; "Ensure that c-<>-arg-sep c-type properties
                               ;; are in place on the commas separating the
                               ;; arguments inside template/generic <..>s."
                               (when (and (eqv? (char-before match-pos) #\<)
                                          (> match-pos max-<>-end))
                                 (save-excursion
                                   (goto-char match-pos)
                                   (c-backward-token-2)
                                   (if (and
                                        (eqv? (char-after) #\<)
                                        (parameterize
                                            ((*c-restricted-<>-arglists*
                                              (save-excursion
                                                (c-backward-token-2)
                                                (and
                                                 (not (looking-at
                                                       (%c-langvar 'c-opt-<>-sexp-key)))
                                                 (begin
                                                   (c-backward-syntactic-ws
                                                    (max (- (point) 1000) (point-min)))
                                                   (memv (char-before) (list #\( #\,)))
                                                 (not (eq? (c-get-char-property
                                                            (- (point) 1) 'c-type)
                                                           'c-decl-arg-start))))))
                                          (c-forward-<>-arglist #f)))
                                       (setq max-<>-end (point)))))

                               (cond-e
                                ((eq? decl-or-cast 'cast)
                                 ;; "Save the position after the previous cast
                                 ;; so we can feed it to
                                 ;; `c-forward-decl-or-cast-1' in the next
                                 ;; round. That helps it discover cast chains
                                 ;; like \"(a) (b) c\"."
                                 (setq last-cast-end (point))
                                 (c-fontify-recorded-types-and-refs)
                                 #f)

                                (decl-or-cast
                                 ;; "We've found a declaration."
                                 ;;
                                 ;; "Set `max-type-decl-end' or
                                 ;; `max-type-decl-end-before-token' under the
                                 ;; assumption that we're after the first type
                                 ;; decl expression in the declaration now. ..."
                                 (if inside-macro
                                     (when (> (point) max-type-decl-end-before-token)
                                       (setq max-type-decl-end-before-token (point)))
                                     (when (> (point) max-type-decl-end)
                                       (setq max-type-decl-end (point))))
                                 (goto-char start-pos)
                                 (c-font-lock-single-decl limit decl-or-cast match-pos
                                                          context
                                                          (or toplev (nth 4 decl-or-cast))))

                                (else #t))))))
                     ;; "It was a false alarm. Check if we're in a label (or
                     ;; other construct with `:' except bitfield) instead."
                     (goto-char start-pos)
                     ;; Its value is the callback's value - what
                     ;; `c-find-decl-spots' reads to decide how to
                     ;; continue - so Emacs's nil is the answer when no
                     ;; label is found.
                     (when-e (setq label-type (c-forward-label #t match-pos #f))
                       ;; "Can't use `c-fontify-types-and-refs' here since we
                       ;; use the label face at times."
                       (cond-e
                        ((eq? label-type 'goto-target)
                         (c-put-font-lock-face (caar (*c-record-ref-identifiers*))
                                               (cdar (*c-record-ref-identifiers*))
                                               c-label-face-name))
                        ((eq? label-type 'qt-1kwd-colon)
                         (c-put-font-lock-face (caar (*c-record-ref-identifiers*))
                                               (cdar (*c-record-ref-identifiers*))
                                               'font-lock-keyword-face))
                        ((eq? label-type 'qt-2kwds-colon)
                         (for-each
                          (lambda (kwd)
                            (c-put-font-lock-face (car kwd) (cdr kwd)
                                                  'font-lock-keyword-face))
                          (*c-record-ref-identifiers*))))
                       (*c-record-ref-identifiers* '())
                       ;; "`c-forward-label' has probably added a `c-decl-end'
                       ;; marker, so return t to `c-find-decl-spots' to signal
                       ;; that."
                       #t)))))
              )                          ; let
            #f))))

    (define (c-font-lock-c11-generic-clause)
      ;; "Fontify a type inside the C11 _Generic clause. Point will be at
      ;; the type and will be left at the next comma of the clause (if any) or
      ;; the closing parenthesis, if any, or at the end of the type,
      ;; otherwise. The return value is always nil."
      (c-fontify-types-and-refs
          ()
        (let* ((here (point))
               (type-type (c-forward-type #t)))
          ;; Emacs binds `c-promote-possible-types' after `type-type' is
          ;; computed, and it affects only the second `c-forward-type'
          ;; below, so the binding is a `parameterize' around the rest.
          (parameterize ((*c-promote-possible-types*
                          (if (eq? type-type 'maybe) 'just-one #t)))
            (let ((pos (point))
                  (pos1 #f))
              (when (and type-type (eqv? (char-after) #\:))
                (goto-char here)
                (c-forward-type #t))     ; "Fontify the type."
              (cond-e
               ((c-syntactic-re-search-forward "," #f #t #t #t)
                (backward-char 1))
               ((and (setq pos1 (c-up-list-forward))
                     (eqv? (char-before pos1) #\)))
                (goto-char (- pos1 1)))
               (else (goto-char pos))))))
        #f))

    (define (c-font-lock-enum-body limit)
      ;; "Fontify the identifiers of each enum we find by searching
      ;; forward."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. ..."
      (while (and (< (point) limit)
                  (let ((re (%c-langvar 'c-enum-clause-introduction-re)))
                    (and re (re-search-forward re limit #t))))
        (when (c-at-enum-brace (- (point) 1))
          (c-forward-syntactic-ws)
          (c-font-lock-declarators limit #t #f #t)))
      #f)

    (define (c-font-lock-enum-tail limit)
      ;; "Fontify an enum's identifiers when POINT is within the enum's
      ;; brace block."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. ..."
      ;;
      ;; "Note that this function won't attempt to fontify beyond the end
      ;; of the current enum block, if any."
      (c-skip-comments-and-strings limit)
      (when-e (< (point) limit)
        (let* ((paren-state (c-parse-state))
               (encl-pos (c-most-enclosing-brace paren-state)))
          (when (and encl-pos
                     (eqv? (char-after encl-pos) #\{)
                     (c-at-enum-brace encl-pos))
            (c-syntactic-skip-backward "^{," #f #t)
            (c-put-char-property (- (point) 1) 'c-type 'c-decl-id-start)

            (c-forward-syntactic-ws)
            (c-font-lock-declarators limit #t #f #t))))
      #f)

    (define (c-font-lock-cut-off-declarators limit)
      ;; "Fontify any declarators \"cut off\" from their declaring type at
      ;; the start of the region being fontified."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, ... It always returns NIL ..."
      (c-skip-comments-and-strings limit)
      (when-e (< (point) limit)
        (let ((here (point))
              (decl-search-lim (c-determine-limit 1000))
              (paren-state #f) (encl-pos #f) (token-end #f) (context #f)
              (decl-or-cast #f) (start-pos #f) (top-level #f))
          ;; Emacs `let'-binds `c-restricted-<>-arglists' (a parameter)
          ;; and `c-recognize-knr-p' (a language variable, which is read
          ;; through `*c-lang-var-overrides*'). Its comment says the
          ;; second is "Strictly speaking, bogus, but it speeds up lisp.h
          ;; tremendously."
          (parameterize ((*c-lang-var-overrides*
                          (cons (cons 'c-recognize-knr-p #f)
                                (*c-lang-var-overrides*)))
                         (*c-restricted-<>-arglists* #f))
            (save-excursion
              (when (not (c-back-over-member-initializers decl-search-lim))
                (setq paren-state (c-parse-state))
                (unless (or (eobp)
                            (looking-at "\\s(\\|\\s)"))
                  (forward-char))
                (c-syntactic-skip-backward "^;{}" decl-search-lim #t)
                ;; "Do we have the brace block of a struct, etc.?"
                ;; `(car paren-state)' of an empty parse state is nil in
                ;; Emacs and an error here; `%c-car' is Emacs's car.
                (when (cond
                       ((and (pair? (%c-car paren-state))
                             (eqv? (char-before) #\}))
                        (goto-char (car (%c-car paren-state)))
                        #t)
                       ((and (number? (%c-car paren-state))
                             (eqv? (char-after (%c-car paren-state)) #\{))
                        (goto-char (%c-car paren-state))
                        #t)
                       (else #f))
                  (c-syntactic-skip-backward "^;{}" decl-search-lim #t))
                (when (or (bobp)
                          (memv (char-before) (list #\; #\{ #\})))
                  (setq token-end (point))
                  (c-forward-syntactic-ws here)
                  (when (< (point) here)
                    ;; "We're now putatively at the declaration."
                    (setq start-pos (point))
                    (setq paren-state (c-parse-state))
                    ;; "At top level or inside a \"{\"?"
                    (if (or (not (setq encl-pos
                                       (c-most-enclosing-brace paren-state)))
                            (eqv? (char-after encl-pos) #\{))
                        (begin
                          (setq top-level (c-at-toplevel-p))
                          (let ((got-context (c-get-fontification-context
                                              token-end #f top-level)))
                            (setq context (car got-context))
                            (*c-restricted-<>-arglists* (cdr got-context)))
                          (setq decl-or-cast
                                (c-forward-decl-or-cast-1 token-end context #f))
                          (when (pair? decl-or-cast)
                            (goto-char start-pos)
                            (c-font-lock-single-decl limit decl-or-cast
                                                     token-end context
                                                     top-level)))))))))
        #f)))

    (define (c-font-lock-enclosing-decls limit)
      ;; "Fontify the declarators of (nested) declarations we're in the
      ;; middle of. This is mainly for when a jit-lock etc. chunk starts
      ;; inside the brace block of a struct/union/class, etc."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, ... It always returns NIL ..."
      (c-skip-comments-and-strings limit)
      (when-e (< (point) limit)
        (let* ((paren-state (c-parse-state))
               (decl-search-lim (c-determine-limit 1000))
               (in-typedef #f) (ps-elt #f))
          ;; "Are we in any nested struct/union/class/etc. braces?"
          (while (pair? paren-state)
            (setq ps-elt (car paren-state)
                  paren-state (cdr paren-state))
            (when (and (not (pair? ps-elt))
                       (eqv? (char-after ps-elt) #\{))
              (goto-char ps-elt)
              (c-syntactic-skip-backward "^;{}" decl-search-lim)
              (c-forward-syntactic-ws)
              (setq in-typedef
                    (let ((re (%c-langvar 'c-typedef-key)))
                      (and re (looking-at re))))
              (if in-typedef (c-forward-over-token-and-ws))
              (when (let ((re (%c-langvar
                               'c-opt-block-decls-with-vars-key)))
                      (and re (looking-at re)))
                (goto-char ps-elt)
                (when (c-safe (c-forward-sexp))
                  (c-forward-syntactic-ws)
                  (c-font-lock-declarators
                   limit #t in-typedef
                   (not (c-bs-at-toplevel-p (point))))))))))
      #f)

    (define (c-font-lock-ids-with-dollar limit)
      ;; "Maybe fontify identifiers with a dollar using
      ;; `font-lock-warning-face'. This is done only for languages which
      ;; tolerate a $ in ids, and only when the flag variable
      ;; `c-warn-ids-with-dollar' is set to non-nil. This function only
      ;; works after functions such as `c-font-lock-declarations' have
      ;; already been run."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, ... It always returns NIL ..."
      (when-e (*c-warn-ids-with-dollar*)
        (let ((id-start #f))
          (while (and (< (point) limit)
                      (skip-chars-forward "^$" limit)
                      (< (point) limit)
                      (eqv? (char-after) #\$))
            (if (and (memv (c-get-char-property (point) 'face)
                           '(font-lock-variable-name-face
                             font-lock-function-name-face
                             font-lock-type-face))
                     (setq id-start (c-on-identifier)))
                (begin
                  (goto-char id-start)
                  (let ((re (%c-langvar 'c-identifier-key)))
                    (and re (looking-at re)))
                  (c-put-font-lock-face (match-beginning 0) (match-end 0)
                                        'font-lock-warning-face)
                  (goto-char (match-end 0)))
                (forward-char)))
          #f)))

    (define (c-font-lock-ml-strings limit)
      ;; "Fontify multi-line strings."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, as though it were to identify a keyword for
      ;; font-lock-keyword-face. It always returns NIL to inhibit this and
      ;; prevent a repeat invocation. See elisp/lispref page
      ;; \"Search-based Fontification\"."
      (let* ((state (c-semi-pp-to-literal (point)))
             (string-start (and (eq? (%c-cadr state) 'string)
                                (%c-caddr state)))
             (open-delim (and string-start
                              (save-excursion
                                (goto-char (1+ string-start))
                                (c-ml-string-opener-around-point))))
             (string-delims (and open-delim
                                 (cons open-delim (c-get-ml-closer open-delim))))
             (found #f))
        ;; "We go round the next loop twice per raw string, once for each
        ;; "end"."
        (while (< (point) limit)
          (cond
           ;; "Point is not in an ml string"
           ((not string-delims)
            (while (and (setq found (re-search-forward
                                     (%c-langvar 'c-ml-string-opener-re)
                                     limit 'limit))
                        (> (match-beginning 0) (point-min))
                        (memq (c-get-char-property (1- (match-beginning 0)) 'face)
                              '(font-lock-comment-face font-lock-string-face
                                font-lock-comment-delimiter-face))))
            (when found
              (setq open-delim (cons (match-beginning 1)
                                     (cons (match-end 1) (match-beginning 2))))
              (setq string-delims (cons open-delim (c-get-ml-closer open-delim)))
              (goto-char (caar string-delims))))

           ;; "Point is in the body of an ml string."
           ((and string-delims
                 (>= (point) (cadar string-delims))
                 (or (not (cdr string-delims))
                     (< (point) (cadr string-delims))))
            (cond
             ((cdr string-delims)
              (goto-char (cadr string-delims)))
             ((equal? (c-get-char-property (1- (cadar string-delims))
                                           'syntax-table)
                      '(15))                    ; "'Always' the case."
              ;; "The next search should be successful for an unterminated
              ;; ml string inside a macro, but not for any other
              ;; unterminated string."
              (or (c-search-forward-char-property 'syntax-table '(15) limit)
                  (goto-char limit))
              (setq string-delims #f))
             (else
              (c-benign-error "Messing '(15) syntax-table property at ~a"
                              (1- (cadar string-delims)))
              (setq string-delims #f))))

           ;; "Point is at or in a closing delimiter"
           ((and string-delims
                 (cdr string-delims)
                 (>= (point) (cadr string-delims)))
            ;; Emacs puts the two calls below inside `(unless (featurep
            ;; 'xemacs) ...)'; there are no extents here, so the branch is
            ;; taken as written.
            (c-put-font-lock-face (cadr string-delims)
                                  (1+ (cadr string-delims))
                                  'font-lock-string-face)
            (c-remove-font-lock-face
             (1+ (cadr string-delims))          ; "(if (featurep 'xemacs) ...)"
             (caddr string-delims))
            (goto-char (caddr string-delims))
            (setq string-delims #f))

           ;; "point is at or in an opening delimiter."
           (else
            (if (cdr string-delims)
                (begin
                  (c-remove-font-lock-face (caar string-delims)
                                           (cadar string-delims))
                  (c-put-font-lock-face (1- (cadar string-delims))
                                        (cadar string-delims)
                                        'font-lock-string-face))
                (c-put-font-lock-face (caar string-delims)
                                      (cadar string-delims)
                                      'font-lock-warning-face))
            (goto-char (cadar string-delims)))))
          #f))

    (define (c-font-lock-c++-lambda-captures limit)
      ;; "Fontify the lambda capture component of C++ lambda
      ;; declarations."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, ... It always returns NIL ..."
      (let ((mode #f) (capture-default #f) (id-start #f) (id-end #f)
            (declaration #f) (sub-begin #f) (sub-end #f) (tem #f))
        (while (and (< (point) limit)
                    (search-forward "[" limit #t))
          (when (begin
                  (backward-char)
                  (prog1 (c-looking-at-c++-lambda-capture-list)
                    (forward-char)))
            (c-forward-syntactic-ws)
            (setq mode (and (memv (char-after) (list #\= #\&))
                            (char-after)))
            ;; "Is the first element of the list a bare \"=\" or \"&\"?"
            (when mode
              (setq tem #f)
              (save-excursion
                (forward-char)
                (c-forward-syntactic-ws)
                (if (memv (char-after) (list #\, #\]))
                    (begin
                      (setq capture-default mode)
                      (when (eqv? (char-after) #\,)
                        (forward-char)
                        (c-forward-syntactic-ws))
                      (setq tem (point)))))
              (if tem (goto-char tem)))

            ;; "Go round the following loop once per captured item. We use
            ;; \"\\\\)\" rather than \"\\]\" here to avoid infinite
            ;; looping in this situation: \"unsigned items [] { [ }\".
            ;; The second \"[\" triggers this function, but if we don't
            ;; match the \"}\" with an \"\\\\)\", the
            ;; `c-syntactic-re-search-forward' at the end of the loop
            ;; fails to move forward over it, leaving point stuck at the
            ;; \"}\"."
            (while (and (not (looking-at "\\s)"))
                        (< (point) limit))
              (if (eqv? (char-after) #\&)
                  (begin (setq mode #\&)
                         (forward-char)
                         (c-forward-syntactic-ws))
                  (setq mode #\=))
              (if (c-on-identifier)
                  (begin
                    (setq id-start (point))
                    (forward-char)
                    (c-end-of-current-token)
                    (setq id-end (point))
                    (c-forward-syntactic-ws)

                    (setq declaration (eqv? (char-after) #\=))
                    (when declaration
                      (forward-char)                ; "over \"=\""
                      (c-forward-syntactic-ws)
                      (setq sub-begin (point)))
                    (if (or (and (< (point) limit)
                                 (c-syntactic-re-search-forward "," limit #t #t))
                            (and (c-go-up-list-forward #f limit)
                                 (eqv? (char-before) #\])))
                        (backward-char)
                        (goto-char limit))
                    (when declaration
                      (save-excursion
                        (setq sub-end (point))
                        (goto-char sub-begin)
                        (c-font-lock-c++-lambda-captures sub-end)))

                    (c-put-font-lock-face
                     id-start id-end
                     (cond
                      (declaration
                       'font-lock-variable-name-face)
                      ((and capture-default
                            (eqv? mode capture-default))
                       'font-lock-warning-face)
                      ((eqv? mode #\=) 'font-lock-constant-face)
                      (else 'font-lock-variable-name-face))))
                  (c-syntactic-re-search-forward "," limit 'bound #t))

              (c-forward-syntactic-ws)
              (when (eqv? (char-after) #\,)
                (forward-char)
                (c-forward-syntactic-ws)))

            (setq capture-default #f)
            (if (< (point) limit)
                (forward-char))))    ; "over the terminating \"]\" or other close paren."
        #f))

    (define (c-forward-c++-module-name limit)
      ;; "Is there a C++20 module name at point? If so, return a cons of the
      ;; start and end of that name, in which case point will be moved over
      ;; the name and following whitespace. Otherwise nil will be returned
      ;; and point will be unmoved. This function doesn't regard a partition
      ;; as part of the name. The entire construct must end not after LIMIT."
      (when-e (and (looking-at (%c-langvar 'c-module-name-re))
                   (<= (match-end 0) limit)
                   (not (looking-at (%c-langvar 'c-keywords-regexp))))
        (goto-char (match-end 0))
        (prog1 (cons (match-beginning 0) (match-end 0))
          (c-forward-syntactic-ws limit))))

    (define (c-forward-c++-module-partition-name limit)
      ;; "Is there a C++20 module partition name (starting with its colon) at
      ;; point? If so return a cons of the start and end of the name, not
      ;; including the colon, in which case point will be move to after the
      ;; name and following whitespace. Otherwise nil will be returned and
      ;; point not moved. The entire construct must end not after LIMIT."
      (when-e (and (eqv? (char-after) #\:)
                   (begin
                     (forward-char 1)
                     (c-forward-syntactic-ws limit)
                     (looking-at (%c-langvar 'c-module-name-re)))
                   (<= (match-end 0) limit)
                   (not (looking-at (%c-langvar 'c-keywords-regexp))))
        (goto-char (match-end 0))
        (prog1 (cons (match-beginning 0) (match-end 0))
          (c-forward-syntactic-ws limit))))

    (define (c-font-lock-c++-modules limit)
      ;; "Fontify the C++20 module stanzas, characterized by the keywords
      ;; `module', `export' and `import'. Note that this has to be done by a
      ;; function (as opposed to regexps) due to the presence of optional C++
      ;; attributes."
      (while (and (< (point) limit)
                  (re-search-forward "\\_<\\(module\\|export\\|import\\)\\_>"
                                     limit #t))
        (goto-char (match-end 1))
        ;; "A list of conses of start and end of pertinent module names"
        (let ((name-bounds #f) (pos #f) (beg #f) (end #f) (module-names '()))
          (unless (c-skip-comments-and-strings limit)
            (when
                (cond
                 ;; "module foo...; Note we don't handle module; or module
                 ;; :private; here, since they don't really need handling."
                 ((save-excursion
                    (when (equal? (match-string-no-properties 1) "export")
                      (c-forward-syntactic-ws limit)
                      (re-search-forward "\\=\\_<\\(module\\)\\_>" limit #t))
                    (and (equal? (match-string-no-properties 1) "module")
                         (< (point) limit)
                         (begin
                           (c-forward-syntactic-ws limit)
                           (setq name-bounds (c-forward-c++-module-name limit)))
                         (setq pos (point))))
                  (push name-bounds module-names)
                  (goto-char pos)
                  ;; "Is there a partition name?"
                  (when (setq name-bounds (c-forward-c++-module-partition-name limit))
                    (push name-bounds module-names))
                  #t)

                 ;; "import"
                 ((save-excursion
                    (when (equal? (match-string-no-properties 1) "export")
                      (c-forward-syntactic-ws limit)
                      (re-search-forward "\\=\\_<\\(import\\)\\_>" limit #t))
                    (and (equal? (match-string-no-properties 1) "import")
                         (< (point) limit)
                         (begin
                           (c-forward-syntactic-ws limit)
                           (setq pos (point)))))
                  (goto-char pos)
                  (cond
                   ;; "import foo;"
                   ((setq name-bounds (c-forward-c++-module-name limit))
                    (push name-bounds module-names)
                    #t)
                   ;; "import :foo;"
                   ((setq name-bounds (c-forward-c++-module-partition-name limit))
                    (push name-bounds module-names)
                    #t)
                   ;; "import \"foo\";"
                   ((and (eqv? (char-after) #\")
                         (setq pos (point))
                         (c-safe (c-forward-sexp) #t)) ; "Should already have string face."
                    (when (eqv? (char-before) #\")
                      (setq beg pos)
                      (setq end (point)))
                    (c-forward-syntactic-ws limit)
                    #t)
                   ;; "import <foo>;"
                   ((and (looking-at "<\\(?:\\\\.\\|[^\\\n\r\t>]\\)*\\(>\\)?")
                         (< (match-end 0) limit))
                    (setq beg (point))
                    (goto-char (match-end 0))
                    (when (match-end 1)
                      (setq end (point)))
                    ;; "(if (featurep 'xemacs) ...)"; there are no extents.
                    (c-put-font-lock-face beg (if end end (point))
                                          'font-lock-string-face)
                    (c-forward-syntactic-ws limit)
                    #t)
                   (else #f)))

                 ;; "export"
                 ;; "There is no fontification to be done here, but we need to
                 ;; skip over the declaration or declaration sequence."
                 ((save-excursion
                    (when (equal? (match-string-no-properties 0) "export")
                      (c-forward-syntactic-ws limit)
                      (setq pos (point))))
                  (goto-char pos)
                  (if (eqv? (char-after) #\{)
                      ;; "Declaration sequence."
                      (if (and (c-go-list-forward #f limit)
                               (eqv? (char-before) #\}))
                          #t
                          (begin (goto-char limit) #f))
                      ;; "Single declaration"
                      (if (c-end-of-decl-1)
                          #t
                          (begin (goto-char limit) #f)))))

              ;; "Optional attributes?"
              (while (and (c-looking-at-c++-attribute)
                          (< (match-end 0) limit))
                (goto-char (match-end 0))
                (c-forward-syntactic-ws limit))
              ;; "Finally, there must be a semicolon."
              (if (and (< (point) limit)
                       (eqv? (char-after) #\;))
                  (begin
                    (forward-char 1)
                    ;; "Fontify any module names we've encountered."
                    (dolist (name module-names)
                      (c-put-font-lock-face (car name) (cdr name)
                                            c-reference-face-name)))
                  ;; "No semicolon, so put warning faces on any delimiters."
                  (begin
                    (when beg
                      (c-put-font-lock-face beg (1+ beg) 'font-lock-warning-face))
                    (when end
                      (c-put-font-lock-face (1- end) end 'font-lock-warning-face))))))))
      #f)

    (c-lang-defconst c-basic-matchers-before
      "Font lock matchers for basic keywords, labels, references and various
other easily recognizable things that should be fontified before generic
casts and declarations are fontified.  Used on level 2 and higher."

      ;; "Note: `c-font-lock-declarations' assumes that no matcher here
      ;; sets `font-lock-type-face' in languages where
      ;; `c-recognize-<>-arglists' is set."
      t (append
         ;; "Put a warning face on the opener of unclosed strings that can't
         ;; span lines and on the \"terminating\" newlines. Later font lock
         ;; packages have a `font-lock-syntactic-face-function' for this, but
         ;; it doesn't give the control we want since any fontification done
         ;; inside the function will be unconditionally overridden."
         (list (list "\\s|" 0 'font-lock-warning-face #t #f))

         ;; "Invalid single quotes."
         (list c-font-lock-invalid-single-quotes)

         ;; "Fontify multiline strings."
         (if (%c-true (c-lang-const c-ml-string-opener-re))
             (list c-font-lock-ml-strings)
             '())

         ;; "Fontify keyword constants."
         (if (%c-true (c-lang-const c-constant-kwds))
             (let ((re (c-make-keywords-re #f (c-lang-const c-constant-kwds))))
               (if (c-major-mode-is 'pike-mode)
                   ;; "No symbol is a keyword after \"->\" in Pike."
                   (list (list (concat "\\(\\=.?\\|[^>]\\|[^-]>\\)"
                                       "\\_<\\(" re "\\)\\_>")
                               2 c-constant-face-name))
                   (list (list (concat "\\_<\\(" re "\\)\\_>")
                               1 c-constant-face-name))))
             '())

         ;; "Fontify all keywords except the primitive types."
         (list
          (if (c-major-mode-is 'pike-mode)
              ;; "No symbol is a keyword after \"->\" in Pike."
              (list (concat "\\(\\=.?\\|[^>]\\|[^-]>\\)"
                            "\\_<" (c-lang-const c-regular-keywords-regexp))
                    2 'font-lock-keyword-face)
              (list (concat "\\_<" (c-lang-const c-regular-keywords-regexp))
                    1 'font-lock-keyword-face)))

         ;; "Fontify leading identifiers in fully qualified names like
         ;; \"foo::bar\" in languages that supports such things."
         (if (%c-true (c-lang-const c-opt-identifier-concat-key))
             (if (c-major-mode-is 'java-mode)
                 ;; "Java needs special treatment since \".\" is used both to
                 ;; qualify names and in normal indexing. Here we look for
                 ;; capital characters at the beginning of an identifier to
                 ;; recognize the class. \"*\" is also recognized to cover
                 ;; wildcard import declarations. All preceding dot separated
                 ;; identifiers are taken as package names and therefore
                 ;; fontified as references."
                 (list
                  (c-make-font-lock-search-function
                   ;; "Search for class identifiers preceded by \".\". The
                   ;; anchored matcher takes it from there."
                   (concat (c-lang-const c-opt-identifier-concat-key)
                           (c-lang-const c-simple-ws) "*"
                           (concat "\\("
                                   "[" c-upper "]"
                                   "[" (c-lang-const c-symbol-chars) "]*"
                                   "\\|"
                                   "\\*"
                                   "\\)"))
                   (list
                    (list
                     (lambda (limit)
                       (let ((id-end #f))
                         (goto-char (1+ (match-beginning 0)))
                         (while (and (eqv? (char-before) #\.)
                                     (begin
                                       (backward-char 1)
                                       (c-backward-syntactic-ws)
                                       (setq id-end (point))
                                       (< (skip-chars-backward
                                           (c-lang-const c-symbol-chars))
                                          0))
                                     (not (get-text-property (point) 'face)))
                           (c-put-font-lock-face (point) id-end
                                                 c-reference-face-name)
                           (c-backward-syntactic-ws))))
                     #f
                     (lambda (limit)
                       (goto-char (match-end 0)))))))
                 (list
                  (lambda (limit)
                     ;; "Must use a function here since we match longer than we
                     ;; want to move before doing a new search. ..."
                     (while (re-search-forward
                             (concat "\\(\\_<"
                                     "\\(" (c-lang-const c-symbol-key) "\\)" ; 2
                                     (c-lang-const c-simple-ws) "*"
                                     (c-lang-const c-opt-identifier-concat-key)
                                     (c-lang-const c-simple-ws) "*"
                                     "\\)"
                                     "\\("
                                     (c-lang-const c-opt-after-id-concat-key)
                                     "\\)")
                             limit #t)
                       (unless (begin
                                 (goto-char (match-beginning 0))
                                 (c-skip-comments-and-strings limit))
                         (or (get-text-property (match-beginning 2) 'face)
                             (c-put-font-lock-face (match-beginning 2)
                                                   (match-end 2)
                                                   c-reference-face-name))
                         (goto-char (match-end 1)))))))
             '())

         ;; "Module declarations (e.g. in C++20)."
         (if (c-major-mode-is 'c++-mode)
             (list c-font-lock-c++-modules)
             '())

         (if (%c-true (c-lang-const c-equals-nontype-decl-kwds))
             (list (list (concat (c-lang-const c-equals-nontype-decl-key)
                                 (c-lang-const c-simple-ws) "+\\("
                                 (c-lang-const c-symbol-key) "\\)")
                         (list (+ 1 (regexp-opt-depth
                                     (c-lang-const c-equals-nontype-decl-key))
                                  (c-lang-const c-simple-ws-depth))
                               'font-lock-type-face #t)))
             '())

         ;; "Fontify the special declarations in Objective-C."
         (if (c-major-mode-is 'objc-mode)
             (list
              ;; "Fontify class names in the beginning of message
              ;; expressions."
              (c-make-font-lock-search-function
               "\\["
               (list
                (lambda (limit)
                  (c-fontify-types-and-refs ()
                    (c-forward-syntactic-ws limit)
                    (let ((start (point)))
                      ;; "In this case we accept both primitive and known
                      ;; types."
                      (when (eq? (c-forward-type) 'known)
                        (goto-char start)
                        (parameterize ((*c-promote-possible-types* #t))
                          (c-forward-type))))
                    (if (> (point) limit) (goto-char limit))))))
              ;; "The @interface/@implementation/@protocol directives."
              (c-make-font-lock-search-function
               (regexp-opt (list "@interface" "@implementation" "@protocol")
                           'symbols)
               (list
                (list
                 (lambda (limit)
                   ;; "The font-lock package in Emacs is known to clobber
                   ;; `parse-sexp-lookup-properties' (when it exists)." The
                   ;; binding Emacs writes is a dynamic one, which is a
                   ;; `parameterize' here.
                   (parameterize ((*parse-sexp-lookup-properties* #t))
                     (c-fontify-types-and-refs ()
                       (c-forward-objc-directive)
                       #f))))
                (list (lambda (limit)
                        (goto-char (match-beginning 0)))))))
             '())

         ;; `(eval . (list "\\(!\\)[^=]" 1 c-negation-char-face-name))' with
         ;; the element it evaluates to written out.
         (list (list "\\(!\\)[^=]" 1 c-negation-char-face-name))))
    ;;------------------------------------------------------------------
    ;; The declaration matcher data (`cc-fonts.el:2274'-`:2346')
    ;;------------------------------------------------------------------
    ;; Emacs's `(eval . FORM)' entries are written as the value they
    ;; evaluate to, as in `c-cpp-matchers' above: our language data is
    ;; evaluated at `c-init-language-vars' time, so a form font-lock
    ;; would evaluate at setup can be evaluated here. The one thing that
    ;; cannot is `c-known-type-key': Emacs splices the *variable* into
    ;; the generated matcher and reads it at match time, so the regexp
    ;; slot is a thunk here (see `c-make-font-lock-search-form').

    (c-lang-defconst c-simple-decl-matchers
      "Simple font lock matchers for types and declarations.  These are used
on level 2 only and so aren't combined with `c-complex-decl-matchers'."
      t
      (append
       ;; "Objective-C methods."
       (if (c-major-mode-is 'objc-mode)
           (list (list (c-lang-const c-opt-method-key)
                       (list (lambda (limit)
                               ;; "The font-lock package in Emacs is known
                               ;; to clobber `parse-sexp-lookup-
                               ;; properties' (when it exists)."
                               (parameterize
                                   ((*parse-sexp-lookup-properties* #t))
                                 (save-restriction
                                   (narrow-to-region (point-min) limit)
                                   (c-font-lock-objc-method))))
                             #f
                             (lambda (limit)
                               (goto-char (match-end 1))))))
           '())

       ;; "Fontify all type names and the identifiers in the declarations
       ;; they might start. Use eval here since `c-known-type-key' gets
       ;; its value from `*-font-lock-extra-types' on mode init."
       ;;
       ;; `(eval . (list ,(c-make-font-lock-search-function
       ;;                'c-known-type-key ...)))' with the element it
       ;; evaluates to written out. The regexp is the thunk
       ;; `(lambda () (%c-langvar 'c-known-type-key))': Emacs splices the
       ;; variable reference into the generated matcher and reads it at
       ;; match time.
       (list
        (c-make-font-lock-search-function
         (lambda () (%c-langvar 'c-known-type-key))
         (list 1 'font-lock-type-face #t)
         (list (lambda (limit) (c-font-lock-declarators limit #t #f #f))
               (lambda (limit)
                 (save-match-data
                   (goto-char (match-end 1))
                   (c-forward-syntactic-ws)))
               (lambda (limit)
                 (goto-char (match-end 1))))))

       ;; "Fontify types preceded by `c-type-prefix-kwds' and the
       ;; identifiers in the declarations they might start."
       (if (%c-true (c-lang-const c-type-prefix-kwds))
           (let* ((prefix-re (c-make-keywords-re
                              #f (c-lang-const c-type-prefix-kwds)))
                  (type-match (+ 2
                                 (regexp-opt-depth prefix-re)
                                 (c-lang-const c-simple-ws-depth))))
             (list
              (c-make-font-lock-search-function
               (concat "\\_<\\(" prefix-re "\\)"     ; 1
                       (c-lang-const c-simple-ws) "+"
                       (concat "\\("                 ; "2 + prefix-re + c-simple-ws"
                               (c-lang-const c-symbol-key)
                               "\\)"))
               (list type-match 'font-lock-type-face #t)
               (list (lambda (limit)
                       (c-font-lock-declarators limit #t #f #f))
                     (lambda (limit)
                       (save-match-data
                         (goto-char (match-end type-match))
                         (c-forward-syntactic-ws)))
                     (lambda (limit)
                       (goto-char (match-end type-match)))))))
           '())

       ;; "Fontify special declarations that lack a type."
       (if (%c-true (c-lang-const c-typeless-decl-kwds))
           (list
            (c-make-font-lock-search-function
             (regexp-opt (c-lang-const c-typeless-decl-kwds) 'symbols)
             (list (lambda (limit)
                     (c-font-lock-declarators limit #t #f #f))
                   (lambda (limit)
                     (save-match-data
                       (goto-char (match-end 1))
                       (c-forward-syntactic-ws)))
                   (lambda (limit)
                     (goto-char (match-end 1))))))
           '())

       ;; "Fontify generic colon labels in languages that support them."
       (if (%c-true (c-lang-const c-recognize-colon-labels))
           (list c-font-lock-labels)
           '())

       ;; "Maybe fontify identifiers containing a dollar sign with
       ;; `font-lock-warning-face'."
       (if (%c-true (c-lang-const c-dollar-in-ids))
           (list c-font-lock-ids-with-dollar)
           '())))

    (c-lang-defconst c-complex-decl-matchers
      "Complex font lock matchers for types and declarations.  Used on level
3 and higher."
      ;;
      ;; "Note: This code in this form dumps a number of functions into the
      ;; resulting constant, `c-matchers-3'. At run time, font lock will
      ;; call each of them as a \"FUNCTION\" (see Elisp page
      ;; \"Search-based Fontification\"). The font lock region is
      ;; delimited by POINT and the single parameter, LIMIT. Each of
      ;; these functions returns NIL (thus inhibiting spurious
      ;; font-lock-keyword-face highlighting and another call)."
      t
      (append
       ;; "Initialize some things before the search functions below."
       (list c-font-lock-complex-decl-prepare)

       ;; objc method declarations
       (if (c-major-mode-is 'objc-mode)
           (list
            (c-make-font-lock-search-function
             (c-make-keywords-re
              #t
              ;; "Exclude \"@class\" since that directive ends with a
              ;; semicolon anyway."
              ;; The language data answers nil (this tree's `#f') for
              ;; a list a language does not have; `append' needs a list.
              (delete "@class"
                      (append (or (c-lang-const c-protection-kwds) '())
                              (or (c-lang-const c-other-decl-kwds) '())
                              '())))
             (list (lambda (limit)
                     (c-put-char-property (- (match-end 1))
                                          'c-type 'c-decl-end))))
            c-font-lock-objc-methods)
           '())

       ;; "Fontify declarators which have been cut off from their
       ;; declaring types at the start of the region."
       (list c-font-lock-cut-off-declarators)

       ;; "Fontify all declarations, casts and normal labels."
       (list c-font-lock-declarations)

       ;; "Fontify declarators when POINT is within their declaration."
       (list c-font-lock-enclosing-decls)

       ;; "Fontify angle bracket arglists like templates in C++."
       (if (%c-true (c-lang-const c-recognize-<>-arglists))
           (list c-font-lock-<>-arglists)
           '())

       (if (c-major-mode-is 'c++-mode)
           (list c-font-lock-c++-lambda-captures)
           '())

       (if (%c-true (c-lang-const c-using-key))
           (list c-font-lock-c++-using)
           '())

       ;; "The first two rules here mostly find occurrences that
       ;; `c-font-lock-declarations' has found already, but not
       ;; declarations containing blocks in the type (see note below).
       ;; It's also useful to fontify these everywhere to show e.g. when
       ;; a type keyword is accidentally used as an identifier."
       ;;
       ;; "Fontify basic types."
       (let ((re (c-make-keywords-re
                  #f
                  (c--delete-duplicates
                   (append (or (c-lang-const c-primitive-type-kwds) '())
                           (or (c-lang-const c-type-with-paren-kwds) '()))
                   ':test equal?))))
         (if (c-major-mode-is 'pike-mode)
             ;; "No symbol is a keyword after \"->\" in Pike."
             (list (list (concat "\\(\\=.?\\|[^>]\\|[^-]>\\)"
                                 "\\_<\\(" re "\\)\\_>")
                         2 'font-lock-type-face))
             (list (list (concat "\\_<\\(" re "\\)\\_>")
                         1 'font-lock-type-face))))

       ;; "Fontify the type in C++ \"new\" expressions."
       (if (c-major-mode-is 'c++-mode)
           ;; "This pattern is a probably a \"(MATCHER .
           ;; ANCHORED-HIGHLIGHTER)\" (see Elisp page \"Search-based
           ;; Fontification\")."
           (list (list "\\_<new\\_>"
                       (list c-font-lock-c++-new)))
           '())

       ;; "Maybe fontify identifiers containing a dollar sign with
       ;; `font-lock-warning-face'."
       (if (%c-true (c-lang-const c-dollar-in-ids))
           (list c-font-lock-ids-with-dollar)
           '())))

    (define (c-font-lock-labels limit)
      ;; "Fontify all statement labels from the point to LIMIT. Assumes
      ;; that strings and comments have been fontified already. Nil is
      ;; always returned."
      ;;
      ;; "Note: This function is only used on decoration level 2; this is
      ;; taken care of directly by the gargantuan
      ;; `c-font-lock-declarations' on higher levels."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((continue-pos #f) (id-start #f))
        ;; Emacs `let'-binds `parse-sexp-lookup-properties' here; it is a
        ;; parameter.
        (parameterize ((*parse-sexp-lookup-properties* #t))
          (while (re-search-forward ":[^:]" limit #t)
            (setq continue-pos (point))
            (goto-char (match-beginning 0))
            (unless (c-skip-comments-and-strings limit)

              (c-backward-syntactic-ws)
              (and (setq id-start (c-on-identifier))

                   (not (get-text-property id-start 'face))

                   (begin
                     (goto-char id-start)
                     (c-backward-syntactic-ws)
                     (or
                      ;; "Check for a char that precedes a statement."
                      (memv (char-before) (list #\} #\{ #\;))
                      ;; "Check for a preceding label. We exploit the font
                      ;; locking made earlier by this function."
                      (and (eqv? (char-before) #\:)
                           (begin
                             (backward-char)
                             (c-backward-syntactic-ws)
                             (not (bobp)))
                           (eq? (get-text-property (- (point) 1) 'face)
                                c-label-face-name))
                      ;; "Check for a keyword that precedes a statement."
                      (c-after-conditional)))

                   (begin
                     ;; "Got a label."
                     (goto-char id-start)
                     (let ((re (%c-langvar 'c-symbol-key)))
                       (and re (looking-at re)))
                     (c-put-font-lock-face (match-beginning 0) (match-end 0)
                                           c-label-face-name)))

              (goto-char continue-pos))))
        #f))

    (c-lang-defconst c-basic-matchers-after
      "Font lock matchers for various things that should be fontified after
generic casts and declarations are fontified.  Used on level 2 and
higher."
      t
      (append
       (if (%c-true (c-lang-const c-enum-list-kwds))
           (list c-font-lock-enum-tail
                 ;; "Fontify the identifiers inside enum lists. (The enum
                 ;; type name is handled by `c-simple-decl-matchers' or
                 ;; `c-complex-decl-matchers' below."
                 c-font-lock-enum-body)
           '())

       ;; "Fontify labels after goto etc."
       (if (%c-true (c-lang-const c-before-label-kwds))
           (let* ((c-before-label-re
                   (c-make-keywords-re
                    #f (c-lang-const c-before-label-kwds))))
             ;; "(Got three different interpretation levels here, which
             ;; makes it a bit complicated: 1) The backquote stuff is
             ;; expanded when compiled or loaded, 2) the eval form is
             ;; evaluated at font-lock setup (to substitute
             ;; c-label-face-name correctly), and 3) the resulting
             ;; structure is interpreted during fontification.)" The
             ;; `(eval . ...)' element is written as the element it
             ;; evaluates to, as above.
             (list (list (concat "\\_<\\(" c-before-label-re "\\)\\_>"
                                 "\\s *"
                                 "\\("        ; "identifier-offset"
                                 (c-lang-const c-symbol-key)
                                 "\\)")
                         (list (+ (regexp-opt-depth c-before-label-re) 2)
                               c-label-face-name #f #t))))
           '())

       ;; "Fontify the clauses after various keywords."
       (if (or (%c-true (c-lang-const c-type-list-kwds))
               (%c-true (c-lang-const c-ref-list-kwds))
               (%c-true (c-lang-const c-colon-type-list-kwds)))
           (list
            (c-make-font-lock-BO-decl-search-function
             (concat "\\_<\\("
                     (c-make-keywords-re
                      #f
                      (append (or (c-lang-const c-type-list-kwds) '())
                              (or (c-lang-const c-ref-list-kwds) '())
                              (or (c-lang-const c-colon-type-list-kwds) '())))
                     "\\)\\_>")
             ;; The varlist binding of `c-promote-possible-types' is a
             ;; `parameterize' here: the variable is a parameter.
             (list (lambda (limit)
                     (parameterize ((*c-promote-possible-types* #t))
                       (c-fontify-types-and-refs
                           ()
                         (c-forward-keyword-clause 1)
                         (if (> (point) limit) (goto-char limit))))))))
           '())

       (if (%c-true (c-lang-const c-paren-type-kwds))
           (list
            (c-make-font-lock-search-function
             (concat "\\_<\\("
                     (c-make-keywords-re
                      #f (c-lang-const c-paren-type-kwds))
                     "\\)\\_>")
             (list (lambda (limit)
                     (parameterize ((*c-promote-possible-types* #t))
                       (c-fontify-types-and-refs
                           ()
                         (c-forward-keyword-clause 1)
                         (if (> (point) limit) (goto-char limit))))))))
           '())

       (if (c-major-mode-is 'java-mode)
           (list (list "\\_<\\(@[a-zA-Z0-9]+\\)\\_>" 1 c-annotation-face))
           '())))

    (c-lang-defconst c-matchers-1
      t (c-lang-const c-cpp-matchers))

    (c-lang-defconst c-matchers-2
      t (append (c-lang-const c-matchers-1)
                (c-lang-const c-basic-matchers-before)
                (c-lang-const c-simple-decl-matchers)
                (c-lang-const c-basic-matchers-after)))

    (c-lang-defconst c-matchers-3
      t (append (c-lang-const c-matchers-1)
                (c-lang-const c-basic-matchers-before)
                (c-lang-const c-complex-decl-matchers)
                (c-lang-const c-basic-matchers-after)))

    ;;------------------------------------------------------------------
    ;; `cc-fonts.el:2567'-`:2677': the doc-comment styles, the composed
    ;; keyword lists, and the found-type refresh
    ;;------------------------------------------------------------------

    (define (c-get-doc-comment-style)
      ;; "Get the symbol (or list of symbols) constituting the document
      ;; style. Return nil if there is no such, otherwise something like
      ;; `autodoc'."
      ;;
      ;; Emacs reads the variable, which the style system makes
      ;; buffer-local; `*c-doc-comment-style*` is the parameter holding
      ;; the standard alist (see cc-vars), and the language in force is
      ;; the `c-buffer-is-cc-mode' stand-in.
      (let ((style (c-doc-comment-style)))
        (if (and (pair? style) (pair? (car style)))
            (let ((hit (or (assq (*c-buffer-is-cc-mode*) style)
                           (assq 'other style))))
              (and hit (cdr hit)))
            style)))

    ;; Emacs finds a doc style's keyword list with
    ;; `(intern-soft (concat (symbol-name style) "-font-lock-keywords"))'
    ;; and then asks `fboundp' before `boundp'. There is no obarray
    ;; here, so each doc-comment table registers itself in this alist
    ;; when it is defined at the end of the file; a procedure entry is
    ;; Emacs's `fboundp' arm and a list is its `boundp' arm.
    (define %c-doc-font-lock-keywords '())

    (define (c-compose-keywords-list base-list)
      ;; "Incorporate the font lock keyword lists according to
      ;; `c-doc-comment-style' on the given keyword list and return it.
      ;; This is used in the function bindings of the
      ;; `*-font-lock-keywords-*' symbols since we have to build the list
      ;; when font-lock is initialized."
      (unless (memq c-doc-face-name c-literal-faces)
        (set! c-literal-faces (cons c-doc-face-name c-literal-faces)))
      (let* ((doc-keywords (c-get-doc-comment-style))
             (styles (if (pair? doc-keywords) doc-keywords (list doc-keywords)))
             (list (append
                    (c--mapcan
                     (lambda (doc-style)
                       (let ((entry (assq doc-style %c-doc-font-lock-keywords)))
                         (cond ((not entry) '())
                               ((procedure? (cdr entry)) ((cdr entry)))
                               (else (append (cdr entry) '())))))
                     styles)
                    base-list)))
        ;; "Kludge: If `c-font-lock-complex-decl-prepare' is on the list
        ;; we move it first since the doc comment font lockers might add
        ;; `c-type' text properties, so they have to be cleared before
        ;; that."
        (when (memq c-font-lock-complex-decl-prepare list)
          (setq list (cons c-font-lock-complex-decl-prepare
                           (delq c-font-lock-complex-decl-prepare
                                 (append list '())))))
        list))

    (define (c-override-default-keywords def-var)
      ;; "This is used to override the value on a `*-font-lock-keywords'
      ;; variable only if it's nil or has the same value as one of the
      ;; `*-font-lock-keywords-*' variables. Older font-lock packages
      ;; define a default value for `*-font-lock-keywords' which we want
      ;; to override, but we should otoh avoid clobbering a user setting.
      ;; This heuristic for that isn't perfect, but I can't think of any
      ;; better. /mast"
      ;;
      ;; Emacs does it with `boundp', `symbol-value' and `makunbound'
      ;; over the obarray. The obarray stand-in here is the keyword table
      ;; `font-lock-eval-keywords' reads: a value registered for DEF-VAR
      ;; is what "bound" means to font-lock, and removing the entry is
      ;; `makunbound' - which leaves the later
      ;; `font-lock-register-keyword-variable!' to install the default,
      ;; as Emacs's later `defvar' installs its own. Every call in this
      ;; file comes before its variable is registered, which is Emacs's
      ;; state too (its `defvar' comes after the call).
      (let* ((entry (assq def-var (*font-lock-keyword-variables*)))
             (level-values
              (map (lambda (suffix)
                     (let ((e (assq (string->symbol
                                     (string-append (symbol->string def-var)
                                                    suffix))
                                    (*font-lock-keyword-variables*))))
                       (and e (cdr e))))
                   '("-1" "-2" "-3"))))
        (when-e (and entry
                     (memq (cdr entry)
                           (cons #f (append level-values '()))))
          ;; "The overriding is done by unbinding the variable so that the
          ;; normal defvar will install its default value later on."
          (*font-lock-keyword-variables*
           (delq entry (*font-lock-keyword-variables*))))))

    ;; "`c-re-redisplay-timer' is a timer which, when triggered, causes a
    ;; redisplay."
    (define c-re-redisplay-timer #f)

    ;; `c-font-lock-fontify-region' is `cc-mode.el`'s (`:2690') and this
    ;; library is below that one, so the call in `c-force-redisplay' is a
    ;; seam: cc-mode installs the real function as it loads, and the
    ;; default is honest about the state before that - Emacs would signal
    ;; a void function.
    (define *c-font-lock-fontify-region-function*
      (make-parameter
       (lambda (beg end)
         (error "`c-font-lock-fontify-region' is not yet initialised"))))

    (define (c-force-redisplay buffer start end)
      ;; "Force redisplay immediately.  This assumes
      ;; `font-lock-support-mode' is 'jit-lock-mode.  Set the variable
      ;; `c-re-redisplay-timer' to nil."
      (with-current-buffer buffer
        (save-excursion ((*c-font-lock-fontify-region-function*) start end))
        (jit-lock-force-redisplay (copy-marker start) (copy-marker end))
        (setq c-re-redisplay-timer #f)))

    (define (c-fontify-new-found-type type)
      ;; "Cause the fontification of TYPE, a string, wherever it occurs in
      ;; the buffer.  If TYPE is currently displayed in a window, cause
      ;; redisplay to happen \"instantaneously\".  These actions are done
      ;; only when jit-lock-mode is active."
      ;;
      ;; Emacs's `(boundp 'font-lock-support-mode)' guard is always true
      ;; here - font-lock is this tree's own library and always loaded -
      ;; so it is not written.
      (when-e (and (font-lock-mode-on?)
                   (eq? (*font-lock-support-mode*) 'jit-lock-mode))
        (c-save-buffer-state
            ((window-boundaries
              (map (lambda (win)
                     (cons (window-start win) (window-end win)))
                   (get-buffer-window-list (current-buffer) 'no-mini #t)))
             (target-re (concat "\\_<" type "\\_>")))
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (while (re-search-forward target-re #f #t)
                (when (and
                       (get-text-property (match-beginning 0) 'fontified)
                       (not (memq (c-get-char-property (match-beginning 0) 'face)
                                  c-literal-faces)))
                  (put-text-property (match-beginning 0) (match-end 0)
                                     'fontified #f))
                (dolist (win-boundary window-boundaries)
                  (when (and (< (match-beginning 0) (cdr win-boundary))
                             (> (match-end 0) (car win-boundary))
                             (not c-re-redisplay-timer))
                    (setq c-re-redisplay-timer
                          (run-with-timer 0 #f c-force-redisplay
                                          (current-buffer)
                                          (match-beginning 0) (match-end 0)))))))))
        #f))

    ;; cc-engine calls `c-fontify-new-found-type' through this seam; this
    ;; is the library that defines it.
    (*c-fontify-new-found-type-function* c-fontify-new-found-type)

    ;;------------------------------------------------------------------
    ;; C++'s two fontifiers (`cc-fonts.el:2713'-`:2878')
    ;;------------------------------------------------------------------
    ;;
    ;; **Placement departure**: Emacs puts these after the C keyword
    ;; defconsts and ours puts them before, because Emacs's matcher
    ;; data holds the *symbol* `c-font-lock-c++-using' and evaluates
    ;; to a procedure only when font-lock runs, while this tree's data
    ;; holds the procedure itself - so `c-matchers-3' cannot be
    ;; evaluated until both exist. (`c-using-key' is a never-matching
    ;; regexp in C as well as C++, so the C list does reference
    ;; `c-font-lock-c++-using'.)


    (define (c-font-lock-c++-using limit)
      ;; "Fontify any clauses starting with the keyword `using'."
      ;;
      ;; "This function will be called from font-lock for a region bounded
      ;; by POINT and LIMIT, ... It always returns NIL ..."
      (let ((pos #f))
        (while
            (and (< (point) limit)
                 (let ((re (%c-langvar 'c-using-key)))
                   (and re (c-syntactic-re-search-forward re limit 'end))))
          (while      ; "Do one declarator of a comma separated list, each time around."
              (begin
                (c-forward-syntactic-ws)
                (setq pos (point))        ; "token after \"using\"."
                (when (and (c-on-identifier)
                           (c-forward-name))
                  (cond
                   ((eqv? (char-after) #\=)     ; "using foo = <type-id>;"
                    (goto-char pos)
                    (c-font-lock-declarators limit #f #t #f))
                   ((save-excursion
                      (and (let ((re (%c-langvar 'c-colon-type-list-re)))
                             (and re #t))
                           (c-go-up-list-backward)
                           (eqv? (char-after) #\{)
                           (eq? (car (c-beginning-of-decl-1
                                      (c-determine-limit 1000)))
                                'same)
                           (let ((re (%c-langvar 'c-colon-type-list-re)))
                             (and re (looking-at re)))))
                    ;; "Inherited protected member: leave unfontified"
                    ))
                (eqv? (char-after) #\,))
            (forward-char))))   ; "over the comma."
        #f))

    (define (c-font-lock-c++-new limit)
      ;; "Assuming point is after a \"new\" word, check that it isn't
      ;; inside a string or comment, and if so try to fontify the type in
      ;; the allocation expression. Nil is always returned."
      ;;
      ;; "This function might do hidden buffer changes."
      (unless (c-skip-comments-and-strings limit)
        (save-excursion
          ;; Emacs's `(catch 'false-alarm ...)' around the body; the two
          ;; `throw's are the continuation.
          (call-with-current-continuation
           (lambda (false-alarm)
             ;; "A \"new\" keyword is followed by one to three
             ;; expressions, where the type is the middle one, and the
             ;; only required part."
             (let ((expr1-pos #f) (expr2-pos #f))
               ;; Emacs `let'-binds `c-record-type-identifiers',
               ;; `c-record-ref-identifiers' and
               ;; `parse-sexp-lookup-properties'; the first two are
               ;; parameters.
               (parameterize ((*c-record-type-identifiers* #t)
                              (*c-record-ref-identifiers* #f)
                              (*parse-sexp-lookup-properties* #t))
                 (c-forward-syntactic-ws)

                 ;; "The first placement arglist is always parenthesized,
                 ;; if it exists."
                 (when (eqv? (char-after) #\()
                   (setq expr1-pos (+ 1 (point)))
                   (guard (e ((scan-error? e) (false-alarm #t)))
                     (c-forward-sexp))
                   (c-forward-syntactic-ws))

                 ;; "The second expression is either a type followed by
                 ;; some \"*\" or \"[...]\" or similar, or a parenthesized
                 ;; type followed by a full identifierless declarator."
                 (setq expr2-pos (+ 1 (point)))
                 (cond ((eqv? (char-after) #\())
                       ((parameterize ((*c-promote-possible-types* #t))
                          (c-forward-type)))
                       (else (setq expr2-pos #f)))

                 (when expr1-pos
                   (cond
                    ((not expr2-pos)
                     ;; "No second expression, so the first has to be a
                     ;; parenthesized type."
                     (goto-char expr1-pos)
                     (parameterize ((*c-promote-possible-types* #t))
                       (c-forward-type)))

                    ((eqv? (char-before expr2-pos) #\()
                     ;; "Got two parenthesized expressions, so we have to
                     ;; look closer at them to decide which is the type.
                     ;; No need to handle `c-record-ref-identifiers' since
                     ;; all references have already been handled by other
                     ;; fontification rules."
                     (let ((expr1-res #f) (expr2-res #f))

                       (goto-char expr1-pos)
                       (when (setq expr1-res (c-forward-type))
                         (unless (looking-at
                                  (concat (c-lang-const c-symbol-start c++)
                                          "\\|[*:)[]"))
                           ;; "There's something after the would-be type
                           ;; that can't be there, so this is a placement
                           ;; arglist."
                           (setq expr1-res #f)))

                       (goto-char expr2-pos)
                       (when (setq expr2-res (c-forward-type))
                         (unless (looking-at
                                  (concat (c-lang-const c-symbol-start c++)
                                          "\\|[*:)[]"))
                           ;; "There's something after the would-be type
                           ;; that can't be there, so this is an
                           ;; initialization expression."
                           (setq expr2-res #f))
                         (when (and (c-go-up-list-forward)
                                    (begin
                                      (c-forward-syntactic-ws)
                                      (eqv? (char-after) #\()))
                           ;; "If there's a third initialization expression
                           ;; then the second one is the type, so demote
                           ;; the first match."
                           (setq expr1-res #f)))

                       ;; "We fontify the most likely type, with a
                       ;; preference for the first argument since a
                       ;; placement arglist is more unusual than an
                       ;; initializer."
                       (cond
                        ((memv expr1-res (list #t 'known 'prefix)))
                        ((memv expr2-res (list #t 'known 'prefix)))
                        ;; "Presumably 'decltype's will be fontified
                        ;; elsewhere."
                        ((eq? expr1-res 'decltype))
                        ((eq? expr2-res 'decltype))
                        ((eq? expr1-res 'found)
                         (parameterize ((*c-promote-possible-types* #t))
                           (goto-char expr1-pos)
                           (c-forward-type)))
                        ((eq? expr2-res 'found)
                         (parameterize ((*c-promote-possible-types* #t))
                           (goto-char expr2-pos)
                           (c-forward-type)))
                        ((and (eq? expr1-res 'maybe) (not expr2-res))
                         (parameterize ((*c-promote-possible-types* #t))
                           (goto-char expr1-pos)
                           (c-forward-type)))
                        ((and (not expr1-res) (eq? expr2-res 'maybe))
                         (parameterize ((*c-promote-possible-types* #t))
                           (goto-char expr2-pos)
                           (c-forward-type)))
                        ;; "If both type matches are 'maybe then we're
                        ;; too uncertain to promote either of them."
                        (else #f))))))

                 ;; "Fontify the type that now is recorded in
                 ;; `c-record-type-identifiers', if any."
                 (c-fontify-recorded-types-and-refs)))))))
        #f)

    ;;------------------------------------------------------------------
    ;; C. (`cc-fonts.el:2679'-`:2710')
    ;;------------------------------------------------------------------

    (c-override-default-keywords 'c-font-lock-keywords)

    ;; "Minimal font locking for C mode.
    ;; Fontifies only preprocessor directives (in addition to the syntactic
    ;; fontification of strings and comments)."
    (define c-font-lock-keywords-1 (c-lang-const c-matchers-1 c))

    ;; "Fast normal font locking for C mode.
    ;; In addition to `c-font-lock-keywords-1', this adds fontification of
    ;; keywords, simple types, declarations that are easy to recognize, the
    ;; user defined types on `c-font-lock-extra-types', and the doc comment
    ;; styles specified by `c-doc-comment-style'."
    (define c-font-lock-keywords-2 (c-lang-const c-matchers-2 c))

    ;; "Accurate normal font locking for C mode.
    ;; Like the variable `c-font-lock-keywords-2' but detects declarations in a more
    ;; accurate way that works in most cases for arbitrary types without the
    ;; need for `c-font-lock-extra-types'."
    (define c-font-lock-keywords-3 (c-lang-const c-matchers-3 c))

    ;; "Default expressions to highlight in C mode."
    (define c-font-lock-keywords c-font-lock-keywords-3)

    ;; `c-font-lock-keywords-2' and its siblings are Emacs *functions* as
    ;; well as variables - `font-lock-eval-keywords' calls the function
    ;; when one exists, which is how the doc-comment keywords get
    ;; composed at setup. A Scheme name cannot be both, so the function
    ;; half of each is registered here as the keyword table's value for
    ;; the symbol; the variable half is the `define' above (and the two
    ;; below), which is what a user reads and sets.
    (font-lock-register-keyword-variable! 'c-font-lock-keywords-1
                                          c-font-lock-keywords-1)
    (font-lock-register-keyword-variable!
     'c-font-lock-keywords-2
     (lambda () (c-compose-keywords-list c-font-lock-keywords-2)))
    (font-lock-register-keyword-variable!
     'c-font-lock-keywords-3
     (lambda () (c-compose-keywords-list c-font-lock-keywords-3)))
    (font-lock-register-keyword-variable!
     'c-font-lock-keywords
     (lambda () (c-compose-keywords-list c-font-lock-keywords)))

    ;;------------------------------------------------------------------
    ;; C++. (`cc-fonts.el:2879'-`:2906')
    ;;------------------------------------------------------------------

    (c-override-default-keywords 'c++-font-lock-keywords)

    ;; "Minimal font locking for C++ mode.
    ;; Fontifies only preprocessor directives (in addition to the syntactic
    ;; fontification of strings and comments)."
    (define c++-font-lock-keywords-1 (c-lang-const c-matchers-1 c++))

    ;; "Fast normal font locking for C++ mode.
    ;; In addition to `c++-font-lock-keywords-1', this adds fontification of
    ;; keywords, simple types, declarations that are easy to recognize, the
    ;; user defined types on `c++-font-lock-extra-types', and the doc comment
    ;; styles specified by `c-doc-comment-style'."
    (define c++-font-lock-keywords-2 (c-lang-const c-matchers-2 c++))

    ;; "Accurate normal font locking for C++ mode.
    ;; Like the variable `c++-font-lock-keywords-2' but detects declarations in a more
    ;; accurate way that works in most cases for arbitrary types without the
    ;; need for `c++-font-lock-extra-types'."
    (define c++-font-lock-keywords-3 (c-lang-const c-matchers-3 c++))

    ;; "Default expressions to highlight in C++ mode."
    (define c++-font-lock-keywords c++-font-lock-keywords-3)

    ;; The function halves - see the note on the C ones above.
    (font-lock-register-keyword-variable! 'c++-font-lock-keywords-1
                                          c++-font-lock-keywords-1)
    (font-lock-register-keyword-variable!
     'c++-font-lock-keywords-2
     (lambda () (c-compose-keywords-list c++-font-lock-keywords-2)))
    (font-lock-register-keyword-variable!
     'c++-font-lock-keywords-3
     (lambda () (c-compose-keywords-list c++-font-lock-keywords-3)))
    (font-lock-register-keyword-variable!
     'c++-font-lock-keywords
     (lambda () (c-compose-keywords-list c++-font-lock-keywords)))

    (define (c-font-lock-objc-method)
      ;; "Assuming the point is after the + or - that starts an
      ;; Objective-C method declaration, fontify it. This must be done
      ;; before normal casts, declarations and labels are fontified since
      ;; they will get false matches in these things."
      ;;
      ;; "This function might do hidden buffer changes."
      (parameterize ((*c-promote-possible-types* #t))
        (c-fontify-types-and-refs ()
          (let ((first #t))
            (while (and
                    (begin
                      (c-forward-syntactic-ws)

                      ;; "An optional method type."
                      (if (eqv? (char-after) #\()
                          (begin
                            (forward-char)
                            (c-forward-syntactic-ws)
                            (c-forward-type)
                            (prog1 (c-go-up-list-forward)
                              (c-forward-syntactic-ws)))
                          #t))

                    ;; "The name. The first time it's the first part of
                    ;; the function name, the rest of the time it's an
                    ;; argument name."
                    (let ((re (%c-langvar 'c-symbol-key)))
                      (and re (looking-at re)))
                    (begin
                      (goto-char (match-end 0))
                      (c-put-font-lock-face (match-beginning 0)
                                            (point)
                                            (if first
                                                'font-lock-function-name-face
                                                'font-lock-variable-name-face))
                      (c-forward-syntactic-ws)

                      ;; "Another optional part of the function name."
                      (let ((re (%c-langvar 'c-symbol-key)))
                        (when (and re (looking-at re))
                          (goto-char (match-end 0))
                          (c-put-font-lock-face (match-beginning 0)
                                                (point)
                                                'font-lock-function-name-face)
                          (c-forward-syntactic-ws)))

                      ;; "There's another argument if a colon follows."
                      (eqv? (char-after) #\:)))
              (forward-char)
              (setq first #f))))))

    (define (c-font-lock-objc-methods limit)
      ;; "Fontify method declarations in Objective-C. Nil is always
      ;; returned."
      ;;
      ;; "This function might do hidden buffer changes."
      (parameterize ((*parse-sexp-lookup-properties* #t))
        (c-find-decl-spots
         limit
         "[-+]"
         #f
         (lambda (match-pos inside-macro . toplev-args)
           (forward-char)
           (c-font-lock-objc-method)))
        #f))

    ;;------------------------------------------------------------------
    ;; Objective-C. (`cc-fonts.el:2985'-`:3010')
    ;;------------------------------------------------------------------

    (c-override-default-keywords 'objc-font-lock-keywords)

    ;; "Minimal font locking for Objective-C mode.
    ;; Fontifies only preprocessor directives (in addition to the syntactic
    ;; fontification of strings and comments)."
    (define objc-font-lock-keywords-1 (c-lang-const c-matchers-1 objc))

    ;; "Fast normal font locking for Objective-C mode.
    ;; In addition to `objc-font-lock-keywords-1', this adds fontification of
    ;; keywords, simple types, declarations that are easy to recognize, the
    ;; user defined types on `objc-font-lock-extra-types', and the doc comment
    ;; styles specified by `c-doc-comment-style'."
    (define objc-font-lock-keywords-2 (c-lang-const c-matchers-2 objc))

    ;; "Accurate normal font locking for Objective-C mode.
    ;; Like the variable `objc-font-lock-keywords-2' but detects declarations in a more
    ;; accurate way that works in most cases for arbitrary types without the
    ;; need for `objc-font-lock-extra-types'."
    (define objc-font-lock-keywords-3 (c-lang-const c-matchers-3 objc))

    ;; "Default expressions to highlight in Objective-C mode."
    (define objc-font-lock-keywords objc-font-lock-keywords-3)

    (font-lock-register-keyword-variable! 'objc-font-lock-keywords-1
                                          objc-font-lock-keywords-1)
    (font-lock-register-keyword-variable!
     'objc-font-lock-keywords-2
     (lambda () (c-compose-keywords-list objc-font-lock-keywords-2)))
    (font-lock-register-keyword-variable!
     'objc-font-lock-keywords-3
     (lambda () (c-compose-keywords-list objc-font-lock-keywords-3)))
    (font-lock-register-keyword-variable!
     'objc-font-lock-keywords
     (lambda () (c-compose-keywords-list objc-font-lock-keywords)))

    ;;------------------------------------------------------------------
    ;; Java. (`cc-fonts.el:3024'-`:3053')
    ;;------------------------------------------------------------------

    (c-override-default-keywords 'java-font-lock-keywords)

    ;; "Minimal font locking for Java mode.
    ;; Fontifies nothing except the syntactic fontification of strings and
    ;; comments."
    (define java-font-lock-keywords-1 (c-lang-const c-matchers-1 java))

    ;; "Fast normal font locking for Java mode.
    ;; In addition to `java-font-lock-keywords-1', this adds fontification of
    ;; keywords, simple types, declarations that are easy to recognize, the
    ;; user defined types on `java-font-lock-extra-types', and the doc
    ;; comment styles specified by `c-doc-comment-style'."
    (define java-font-lock-keywords-2 (c-lang-const c-matchers-2 java))

    ;; "Accurate normal font locking for Java mode.
    ;; Like variable `java-font-lock-keywords-2' but detects declarations in a more
    ;; accurate way that works in most cases for arbitrary types without the
    ;; need for `java-font-lock-extra-types'."
    (define java-font-lock-keywords-3 (c-lang-const c-matchers-3 java))

    ;; "Default expressions to highlight in Java mode."
    (define java-font-lock-keywords java-font-lock-keywords-3)

    (font-lock-register-keyword-variable! 'java-font-lock-keywords-1
                                          java-font-lock-keywords-1)
    (font-lock-register-keyword-variable!
     'java-font-lock-keywords-2
     (lambda () (c-compose-keywords-list java-font-lock-keywords-2)))
    (font-lock-register-keyword-variable!
     'java-font-lock-keywords-3
     (lambda () (c-compose-keywords-list java-font-lock-keywords-3)))
    (font-lock-register-keyword-variable!
     'java-font-lock-keywords
     (lambda () (c-compose-keywords-list java-font-lock-keywords)))

    ;;------------------------------------------------------------------
    ;; CORBA IDL. (`cc-fonts.el:3057'-`:3086')
    ;;------------------------------------------------------------------

    (c-override-default-keywords 'idl-font-lock-keywords)

    ;; "Minimal font locking for CORBA IDL mode.
    ;; Fontifies nothing except the syntactic fontification of strings and
    ;; comments."
    (define idl-font-lock-keywords-1 (c-lang-const c-matchers-1 idl))

    ;; "Fast normal font locking for CORBA IDL mode.
    ;; In addition to `idl-font-lock-keywords-1', this adds fontification of
    ;; keywords, simple types, declarations that are easy to recognize, the
    ;; user defined types on `idl-font-lock-extra-types', and the doc comment
    ;; styles specified by `c-doc-comment-style'."
    (define idl-font-lock-keywords-2 (c-lang-const c-matchers-2 idl))

    ;; "Accurate normal font locking for CORBA IDL mode.
    ;; Like the variable `idl-font-lock-keywords-2' but detects declarations in a more
    ;; accurate way that works in most cases for arbitrary types without the
    ;; need for `idl-font-lock-extra-types'."
    (define idl-font-lock-keywords-3 (c-lang-const c-matchers-3 idl))

    ;; "Default expressions to highlight in CORBA IDL mode."
    (define idl-font-lock-keywords idl-font-lock-keywords-3)

    (font-lock-register-keyword-variable! 'idl-font-lock-keywords-1
                                          idl-font-lock-keywords-1)
    (font-lock-register-keyword-variable!
     'idl-font-lock-keywords-2
     (lambda () (c-compose-keywords-list idl-font-lock-keywords-2)))
    (font-lock-register-keyword-variable!
     'idl-font-lock-keywords-3
     (lambda () (c-compose-keywords-list idl-font-lock-keywords-3)))
    (font-lock-register-keyword-variable!
     'idl-font-lock-keywords
     (lambda () (c-compose-keywords-list idl-font-lock-keywords)))

    ;;------------------------------------------------------------------
    ;; Pike. (`cc-fonts.el:3090'-`:3121')
    ;;------------------------------------------------------------------

    (c-override-default-keywords 'pike-font-lock-keywords)

    ;; "Minimal font locking for Pike mode.
    ;; Fontifies only preprocessor directives (in addition to the syntactic
    ;; fontification of strings and comments)."
    (define pike-font-lock-keywords-1 (c-lang-const c-matchers-1 pike))

    ;; "Fast normal font locking for Pike mode.
    ;; In addition to `pike-font-lock-keywords-1', this adds fontification of
    ;; keywords, simple types, declarations that are easy to recognize, the
    ;; user defined types on `pike-font-lock-extra-types', and the doc
    ;; comment styles specified by `c-doc-comment-style'."
    (define pike-font-lock-keywords-2 (c-lang-const c-matchers-2 pike))

    ;; "Accurate normal font locking for Pike mode.
    ;; Like the variable `pike-font-lock-keywords-2' but detects declarations in a more
    ;; accurate way that works in most cases for arbitrary types without the
    ;; need for `pike-font-lock-extra-types'."
    (define pike-font-lock-keywords-3 (c-lang-const c-matchers-3 pike))

    ;; "Default expressions to highlight in Pike mode."
    (define pike-font-lock-keywords pike-font-lock-keywords-3)

    ;; Pike's three also set the doc-comment regexps before composing, as
    ;; Emacs's functions do.
    (font-lock-register-keyword-variable! 'pike-font-lock-keywords-1
                                          pike-font-lock-keywords-1)
    (font-lock-register-keyword-variable!
     'pike-font-lock-keywords-2
     (lambda ()
       (c-set-doc-comment-res)
       (c-compose-keywords-list pike-font-lock-keywords-2)))
    (font-lock-register-keyword-variable!
     'pike-font-lock-keywords-3
     (lambda ()
       (c-set-doc-comment-res)
       (c-compose-keywords-list pike-font-lock-keywords-3)))
    (font-lock-register-keyword-variable!
     'pike-font-lock-keywords
     (lambda ()
       (c-set-doc-comment-res)
       (c-compose-keywords-list pike-font-lock-keywords)))

    ;;------------------------------------------------------------------
    ;; Doc comments. (`cc-fonts.el:3126'-`:3322')
    ;;------------------------------------------------------------------
    ;;
    ;; `c-doc-line-join-re', `c-doc-bright-comment-start-re' and
    ;; `c-doc-line-join-end-ch' are `cc-mode.el:136'-`:147''s defvars;
    ;; they live in cc-engine as buffer-local slots behind accessors (see
    ;; there), which is what the two `c-set-doc-comment-*' macros below
    ;; fill for the current buffer.

    ;; Emacs finds a doc style's per-style variables with
    ;; `(intern-soft (concat (symbol-name style) SUFFIX))', `boundp' and
    ;; `symbol-value'. There is no obarray here, so the style-specific
    ;; variables register themselves in this alist as they are defined
    ;; (autodoc is the only style that has any), and the macros look the
    ;; name up. Emacs's nil answer for a name that is not bound is #f.
    (define %c-doc-comment-properties '())

    (define (c-doc-style-property style suffix)
      ;; The value of the variable `<STYLE><SUFFIX>', or #f when the doc
      ;; style has no such variable.
      (let ((entry (assq (string->symbol (string-append (symbol->string style)
                                                        suffix))
                         %c-doc-comment-properties)))
        (and entry (cdr entry))))

    (define (c-set-doc-comment-re-element suffix)
      ;; Emacs writes this as a macro because its body computes the
      ;; variable's name from the literal SUFFIX with
      ;; `(intern (concat "c-doc" suffix))' and then needs that name as a
      ;; *binding* for `(set (make-local-variable ',var) elts)'. The name
      ;; here is data - a buffer-local slot's key - so a procedure is the
      ;; same computation and not a departure in behaviour; the macro
      ;; spelling would have to build the datum with `datum->syntax' and
      ;; buy nothing. The three call sites pass literals.
      ;;
      ;; "Set the variable `c-doc-line-join-re' to a buffer local value
      ;; suitable for the current doc comment style, or kill the local
      ;; value."
      (let* ((styles (c-get-doc-comment-style))
             (styles (if (pair? styles) styles (list styles)))
             (elts (delq #f
                         (map (lambda (style)
                                (c-doc-style-property style suffix))
                              styles)))
             ;; Emacs's `(and elts (concat ...))': an empty list is nil
             ;; there and true here, so the test is for a non-empty one.
             (joined (and (pair? elts)
                          (concat "\\(" (mapconcat identity elts "\\|")
                                  "\\)")))
             (var (string->symbol (string-append "c-doc" suffix))))
        (if joined
            (set-buffer-local-value! (current-buffer) var joined)
            (kill-local-variable var))))

    (define (c-set-doc-comment-char-list suffix)
      ;; The char-list half of `c-set-doc-comment-re-element' - Emacs has
      ;; two macros for the one difference (no `concat' here); see the
      ;; comment there.
      ;;
      ;; "Set the variable 'c-doc-<suffix>' to the list of *-<suffix>,
      ;; which must be characters, and * represents the doc comment
      ;; style."
      (let* ((styles (c-get-doc-comment-style))
             (styles (if (pair? styles) styles (list styles)))
             (elts (delq #f
                         (map (lambda (style)
                                (c-doc-style-property style suffix))
                              styles)))
             (var (string->symbol (string-append "c-doc" suffix))))
        (if (pair? elts)
            (set-buffer-local-value! (current-buffer) var (append elts '()))
            (kill-local-variable var))))

    (define (c-set-doc-comment-res)
      ;; "Set the variables `c-doc-line-join-re' and
      ;; `c-doc-bright-comment-start-re' from the current doc comment
      ;; style(s)."
      (c-set-doc-comment-re-element "-line-join-re")
      (c-set-doc-comment-re-element "-bright-comment-start-re")
      (c-set-doc-comment-char-list "-line-join-end-ch"))

    (define (c-font-lock-doc-comments prefix limit keywords)
      ;; "Fontify the comments between the point and LIMIT whose start
      ;; matches PREFIX with `c-doc-face-name'.  Assumes comments have
      ;; been fontified with `font-lock-comment-face' already.  nil is
      ;; always returned."
      ;;
      ;; "After the fontification of a matching comment, fontification
      ;; according to KEYWORDS is applied inside it.  It's a list like
      ;; `font-lock-keywords' except that anchored matches and eval
      ;; clauses aren't supported and that some abbreviated forms can't be
      ;; used.  The buffer is narrowed to the comment while KEYWORDS is
      ;; applied; leading comment starters are included but trailing
      ;; comment enders for block comment are not."
      ;;
      ;; "Note that faces added through KEYWORDS should never replace the
      ;; existing `c-doc-face-name' face since the existence of that face
      ;; is used as a flag in other code to skip comments."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((comment-beg #f) (region-beg #f) (comment-mid #f))
        (if (memq (get-text-property (point) 'face)
                  '(font-lock-comment-face font-lock-comment-delimiter-face))
            ;; "Handle the case when the fontified region starts inside a
            ;; comment."
            (let ((start (c-literal-start)))
              (setq region-beg (point)
                    comment-mid (point))
              (when start
                (goto-char start))
              (when (looking-at prefix)
                (setq comment-beg (point))))
            #f)

        (while (or
                comment-beg

                ;; "Search for the prefix until a match is found at the
                ;; start of a comment."
                (begin
                  (while (when-e (re-search-forward prefix limit #t)
                           (setq comment-beg (match-beginning 0))
                           (or (not (c-got-face-at comment-beg c-literal-faces))
                               (and (not (= comment-beg (point-min)))
                                    ;; "Cheap check which is unreliable (the
                                    ;; previous character could be the end
                                    ;; of a previous comment)."
                                    (c-got-face-at (1- comment-beg)
                                                   c-literal-faces)
                                    ;; "Expensive reliable check."
                                    (save-excursion
                                      (goto-char comment-beg)
                                      (c-in-literal)))))
                    (setq comment-beg #f))
                  #f)
                (setq region-beg comment-beg
                      comment-mid comment-beg))

          ;; Emacs's `(elt (parse-partial-sexp ...) 7)' - the comment
          ;; style, which is non-nil for a line comment (measured on
          ;; Emacs 31.1: 1 for `//', nil for `/*').
          (if (nth 7 (parse-partial-sexp comment-beg (+ comment-beg 2)))
              ;; "Collect a sequence of doc style line comments."
              (begin
                (goto-char comment-beg)
                (while (and (begin
                              (c-forward-single-comment)
                              (c-put-font-lock-face comment-mid (point)
                                                    c-doc-face-name)
                              (skip-syntax-forward " ")
                              (setq comment-beg (point)
                                    comment-mid (point))
                              (< (point) limit))
                            (looking-at prefix))))
              (begin
                (goto-char comment-beg)
                (c-forward-single-comment)
                (c-put-font-lock-face region-beg (point) c-doc-face-name)))
          (if (> (point) limit) (goto-char limit) #f)
          (setq comment-beg #f)

          (let ((region-end (point))
                (keylist keywords)
                ;; Emacs's `let' has bare bindings; Guile's needs a value.
                (keyword #f) (matcher #f) (highlights #f))
            (save-restriction
              ;; "Narrow to the doc comment.  Among other things, this
              ;; helps by making \"^\" match at the start of the comment.
              ;; Do not include a trailing block comment ender, though."
              (and (> region-end (1+ region-beg))
                   (begin (goto-char region-end)
                          (backward-char 2)
                          (looking-at "\\*/"))
                   (setq region-end (point)))
              (narrow-to-region region-beg region-end)

              (while (pair? keylist)
                (setq keyword (car keylist)
                      keylist (cdr keylist)
                      matcher (car keyword))
                (goto-char region-beg)
                (while (if (string? matcher)
                           (re-search-forward matcher region-end #t)
                           (matcher region-end))
                  (setq highlights (cdr keyword))
                  (if (pair? (%c-car highlights))
                      (while (pair? highlights)
                        (font-lock-apply-highlight (car highlights))
                        (setq highlights (cdr highlights)))
                      ;; A keyword with no highlighter - a plain matcher
                      ;; such as `(autodoc-font-lock-line-markup)' - has
                      ;; nothing to apply; Emacs calls
                      ;; `font-lock-apply-highlight' with nil, which does
                      ;; nothing there and is an error here.
                      (if (pair? highlights)
                          (font-lock-apply-highlight highlights)
                          #f))))

              (goto-char region-end)))))
      #f)

    (define (c-find-invalid-doc-markup regexp limit)
      ;; "Used to fontify invalid markup in doc comments after the correct
      ;; ones have been fontified: Find the first occurrence of REGEXP
      ;; between the point and LIMIT that only is fontified with
      ;; `c-doc-face-name'.  If a match is found then submatch 0 surrounds
      ;; the first char and t is returned, otherwise nil is returned."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((start #f))
        (while (if (re-search-forward regexp limit #t)
                   (not (eq? (get-text-property
                              (setq start (match-beginning 0)) 'face)
                             c-doc-face-name))
                   (setq start #f)))
        (when-e start
          ;; Emacs's `store-match-data' is `set-match-data''s alias.
          (set-match-data (list (copy-marker start)
                                (copy-marker (1+ start))))
          #t)))

    ;; "GtkDoc patterns contributed by Masatake YAMATO
    ;; <yamato@redhat.com>."

    (define gtkdoc-font-lock-doc-comments
      (let ((symbol "[a-zA-Z0-9_]+")
            (header "^ \\* "))
        (list
         (list (concat header "\\("     symbol "\\):[ \t]*$")
               1 c-doc-markup-face-name 'prepend #f)
         (list (concat                  symbol     "()")
               0 c-doc-markup-face-name 'prepend #f)
         (list (concat header "\\(" "@" symbol "\\):")
               1 c-doc-markup-face-name 'prepend #f)
         (list (concat "[#%@]" symbol)
               0 c-doc-markup-face-name 'prepend #f))))

    (define gtkdoc-font-lock-doc-protection
      (list (list "< \\(public\\|private\\|protected\\) >"
                  1 c-doc-markup-face-name 'prepend #f)))

    (define gtkdoc-font-lock-keywords
      (list
       (list (lambda (limit)
               (c-font-lock-doc-comments "/\\*\\*\\([^*/\n\r].*\\)?$" limit
                                         gtkdoc-font-lock-doc-comments)
               (c-font-lock-doc-comments "/\\*< " limit
                                         gtkdoc-font-lock-doc-protection)))))

    ;; Javadoc.

    (define javadoc-font-lock-doc-comments
      (list
       (list "{@[a-z]+[^}\n\r]*}"              ; "{@foo ...}" markup.
             0 c-doc-markup-face-name 'prepend #f)
       (list "^\\(/\\*\\)?\\(\\s \\|\\*\\)*\\(@[a-z]+\\)" ; "@foo ..." markup.
             3 c-doc-markup-face-name 'prepend #f)
       (list (concat "</?\\sw"                  ; HTML tags.
                     "\\("
                     (concat "\\sw\\|\\s \\|[=\n\r*.:]\\|"
                             "\"[^\"]*\"\\|'[^']*'")
                     "\\)*>")
             0 c-doc-markup-face-name 'prepend #f)
       (list "&\\(\\sw\\|[.:]\\)+;"             ; HTML entities.
             0 c-doc-markup-face-name 'prepend #f)
       ;; "Fontify remaining markup characters as invalid.  Note that the
       ;; Javadoc spec is hazy about when \"@\" is allowed in non-markup
       ;; use."
       (list (lambda (limit)
               (c-find-invalid-doc-markup "[<>&]\\|{@" limit))
             0 'font-lock-warning-face 'prepend #f)))

    (define javadoc-font-lock-keywords
      (list
       (list (lambda (limit)
               (c-font-lock-doc-comments "/\\*\\*" limit
                                         javadoc-font-lock-doc-comments)))))

    ;; Pike autodoc.

    ;; "Adorned regexp matching the keywords that introduce declarations
    ;; in Pike Autodoc."
    (define autodoc-decl-keywords
      (c-make-keywords-re #t '("@decl" "@elem" "@index" "@member") 'pike-mode))

    ;; "Adorned regexp matching the keywords that are followed by a type."
    (define autodoc-decl-type-keywords
      (c-make-keywords-re #t '("@elem" "@member") 'pike-mode))

    (define (autodoc-font-lock-line-markup limit)
      ;; "Fontify all line oriented keywords between the point and LIMIT.
      ;; Nil is always returned."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((line-re (concat "^\\(\\(/\\*!\\|\\s *\\("
                             (c-current-comment-prefix)
                             "\\)\\)\\s *\\)@[A-Za-z_-]+\\(\\s \\|$\\)"))
            (markup-faces (list c-doc-markup-face-name c-doc-face-name)))
        (while (and (< (point) limit)
                    (re-search-forward line-re limit #t))
          (goto-char (match-end 1))

          (if (looking-at autodoc-decl-keywords)
              (let* ((kwd-pos (point))
                     (start (match-end 1))
                     (pos start)
                     (end #f))
                (c-put-font-lock-face (point) pos markup-faces)

                ;; "Put a declaration end mark at the markup keyword and
                ;; remove the faces from the rest of the line so that it
                ;; gets refontified as a declaration later on by
                ;; `c-font-lock-declarations'."
                (c-put-char-property (1- pos) 'c-type 'c-decl-end)
                (goto-char pos)
                (while (begin
                         (end-of-line)
                         (setq end (point))
                         (and (eqv? (char-before) #\@)
                              (not (eobp))
                              (begin (forward-char)
                                     (skip-syntax-forward " ")
                                     (looking-at (c-current-comment-prefix)))))
                  (goto-char (match-end 0))
                  (c-remove-font-lock-face pos (1- end))
                  (c-put-font-lock-face (1- end) end markup-faces)
                  (setq pos (point)))

                ;; "Include the final newline in the removed area.  This
                ;; has no visual effect but it avoids some tricky special
                ;; cases in the testsuite wrt the differences in string
                ;; fontification in Emacs vs XEmacs."
                (c-remove-font-lock-face pos (min (1+ (point)) (point-max)))

                ;; "Must handle string literals explicitly inside the
                ;; declaration."
                (goto-char start)
                (while (re-search-forward
                        "\"\\([^\\\"]\\|\\\\.\\)*\"\\|'\\([^\\']\\|\\\\.\\)*'"
                        end #t)
                  (c-put-font-lock-string-face (match-beginning 0) (point)))

                ;; "Fontify types after keywords that always are followed
                ;; by them."
                (goto-char kwd-pos)
                (when (looking-at autodoc-decl-type-keywords)
                  ;; Emacs's `(c-fontify-types-and-refs
                  ;; ((c-promote-possible-types t)) ...)': the varlist
                  ;; binding is a `parameterize' here.
                  (parameterize ((*c-promote-possible-types* #t))
                    (c-fontify-types-and-refs ()
                      (goto-char start)
                      (c-forward-syntactic-ws)
                      (c-forward-type)))))

              ;; "Mark each whole line as markup, as long as the logical
              ;; line continues."
              (while (begin
                       ;; The C evaluates `(point)' before the `end-of-line'
                       ;; in its second argument; argument order is
                       ;; unspecified here, so the two are sequenced.
                       (let ((line-start (point)))
                         (end-of-line)
                         (c-put-font-lock-face line-start (point)
                                               markup-faces))
                       (and (eqv? (char-before) #\@)
                            (not (eobp))
                            (begin (forward-char)
                                   (skip-syntax-forward " ")
                                   (looking-at (c-current-comment-prefix)))))
                (goto-char (match-end 0))))))
      #f)

    (define autodoc-font-lock-doc-comments
      (list
       (list "@\\(\\w+{\\|\\[\\([^]@\n\r]\\|@@\\)*\\]\\|[@}]\\|$\\)"
             ;; "In-text markup."
             0 c-doc-markup-face-name 'prepend #f)
       (list autodoc-font-lock-line-markup)
       ;; "Fontify remaining markup characters as invalid."
       (list (lambda (limit)
               (c-find-invalid-doc-markup "@" limit))
             0 'font-lock-warning-face 'prepend #f)))

    ;; "Matches a line continuation in autodoc comment style."
    (define autodoc-line-join-re "@[\n\r][ \t]*/[/*]!")
    ;; "Matches an autodoc comment opener."
    (define autodoc-bright-comment-start-re "/[/*]!")
    ;; "The final character of `autodoc-line-join-re'."
    (define autodoc-line-join-end-ch #\!)

    (define (autodoc-font-lock-keywords)
      ;; "Note that we depend on that `c-current-comment-prefix' has got
      ;; its proper value here."
      ;;
      ;; "This function might do hidden buffer changes."
      ;;
      ;; "The `c-type' text property with `c-decl-end' is used to mark the
      ;; end of the `autodoc-decl-keywords' occurrences to fontify the
      ;; following declarations."
      ;;
      ;; Emacs's `(setq c-type-decl-end-used t)' is a write to a language
      ;; variable, which is a buffer-local slot here.
      (c-lang-set-local! 'c-type-decl-end-used #t)
      (list
       (list (lambda (limit)
               (c-font-lock-doc-comments "/[*/]!" limit
                                         autodoc-font-lock-doc-comments)))))

    ;; Doxygen

    (define doxygen-font-lock-doc-comments
      ;; "TODO: Handle @code, @verbatim, @dot, @f etc. better by not
      ;; highlighting text inside of those commands.  Something smarter
      ;; than just regexes may be needed to do that efficiently."
      (list
       (list (concat
              ;; "Make sure that the special character has not been
              ;; escaped.  E.g. in `\@foo' only `\@' is a command
              ;; (similarly for other characters like `\\foo', `\<foo'
              ;; and `\&foo').  The downside now is that we don't match
              ;; command started just after an escaped character, e.g. in
              ;; `\@\foo' we should match `\@' as well as `\foo' but only
              ;; the former is matched."
              "\\(?:^\\|[^\\@]\\)\\("
              ;; "Doxygen commands start with backslash or an at sign.
              ;; Note that for brevity in the comments only `\' will be
              ;; mentioned."
              "[\\@]\\(?:"
              ;; "Doxygen commands except those starting with `f'"
              "[a-eg-z][a-z]*"
              ;; "Doxygen command starting with `f':"
              "\\|f\\(?:"
              "[][$}]"                         ; "\f$ \f} \f[ \f]"
              "\\|{\\(?:[a-zA-Z]+\\*?}{?\\)?"  ; "\f{ \f{env} \f{env}{"
              "\\|[a-z]+"                      ; "\foo"
              "\\)"
              "\\|~[a-zA-Z]*"             ; "\~  \~language"
              "\\|[$@&~<=>#%\".|\\\\]"    ; "single-character escapes"
              "\\|::\\|---?"              ; "\:: \-- \---"
              "\\)"
              ;; "HTML tags and entities:"
              "\\|</?\\sw\\(?:\\sw\\|\\s \\|[=\n\r*.:]\\|\"[^\"]*\"\\|'[^']*'\\)*>"
              "\\|&\\(?:\\sw+\\|#[0-9]+\\|#x[0-9a-fA-F]+\\);"
              "\\)")
             1 c-doc-markup-face-name 'prepend #f)
       ;; "Commands inside of strings are not commands so override
       ;; highlighting with string face.  This also affects HTML attribute
       ;; values if they are surrounded with double quotes which may or may
       ;; not be considered a good thing."
       (list "\\(?:^\\|[^\\@]\\)\\(\"[^\"[:cntrl:]]+\"\\)"
             1 'font-lock-string-face 'prepend #f)
       ;; "HTML comments inside of the Doxygen comments."
       (list "\\(?:^\\|[^\\@]\\)\\(<!--.*?-->\\)"
             1 'font-lock-comment-face 'prepend #f)
       ;; "Autolinking. Doxygen auto-links anything that is a class name
       ;; but we have no hope of matching those.  We are, however, able to
       ;; match functions and members using explicit scoped syntax.  For
       ;; functions, we can also find them by noticing argument-list.  Note
       ;; that Doxygen accepts `::' as well as `#' as scope operators."
       (let* ((ref "[\\@]ref\\s-+")
              (ref-opt (concat "\\(?:" ref "\\)?"))
              (id "[a-zA-Z_][a-zA-Z_0-9]*")
              (args "\\(?:()\\|([^()]*)\\)")
              (scope "\\(?:#\\|::\\)"))
         (list (concat
                "\\(?:^\\|[^\\@/%:]\\)\\(?:"
                ref-opt "\\(?1:" scope "?" "\\(?:" id scope "\\)+" "~?" id "\\)"
                "\\|" ref-opt "\\(?1:" scope     "~?" id "\\)"
                "\\|" ref-opt "\\(?1:" scope "?" "~?" id "\\)" args
                "\\|" ref     "\\(?1:" "~?" id "\\)"
                "\\|" ref-opt "\\(?1:~[A-Z][a-zA-Z0-9_]+\\)"
                "\\)")
               1 'font-lock-function-name-face 'prepend #f))
       ;; "Match URLs and emails.  This has two purposes.  First of all,
       ;; Doxygen autolinks URLs.  Second of all, `@bar' in `foo@bar.baz'
       ;; has been matched above as a command; try and overwrite it."
       (let* ((host "[A-Za-z0-9]\\(?:[A-Za-z0-9-]\\{0,61\\}[A-Za-z0-9]\\)")
              (fqdn (concat "\\(?:" host "\\.\\)+" host))
              (comp "[!-(*--/-=?-~]+")
              (path (concat "/\\(?:" comp "[.]+" "\\)*" comp)))
         (list (concat "\\(?:mailto:\\)?[a-zA-0_.]+@" fqdn
                       "\\|https?://" fqdn "\\(?:" path "\\)?")
               0 'font-lock-keyword-face 'prepend #f))))

    (define doxygen-font-lock-keywords
      (list
       (list (lambda (limit)
               (c-font-lock-doc-comments "/\\(?:/[/!]\\|\\*[\\*!]\\)"
                                         limit doxygen-font-lock-doc-comments)))))

    ;;------------------------------------------------------------------
    ;; The doc styles' registries
    ;;------------------------------------------------------------------
    ;; Filled here, after everything they name is defined. Emacs finds
    ;; these with the obarray; these alists are the obarray stand-ins
    ;; (see `c-compose-keywords-list' and `c-doc-style-property').
    (set! %c-doc-font-lock-keywords
          (list (cons 'gtkdoc gtkdoc-font-lock-keywords)
                (cons 'javadoc javadoc-font-lock-keywords)
                (cons 'doxygen doxygen-font-lock-keywords)
                (cons 'autodoc autodoc-font-lock-keywords)))
    (set! %c-doc-comment-properties
          (list (cons 'autodoc-line-join-re autodoc-line-join-re)
                (cons 'autodoc-bright-comment-start-re
                      autodoc-bright-comment-start-re)
                (cons 'autodoc-line-join-end-ch autodoc-line-join-end-ch)))

))
