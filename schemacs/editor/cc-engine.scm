(define-library (schemacs editor cc-engine)
  ;; `lisp/progmodes/cc-engine.el' - the parser. The file is 16,747
  ;; lines and this library is its first tranche, in the C's own order:
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
  ;;   * the basic utilities: `c-delq-from-dotted-list',
  ;;     `c-shift-line-indentation', `c-keyword-sym'/`c-keyword-member',
  ;;     the string-syntax constants, `c-parsing-error' and
  ;;     `c-echo-parsing-error', `c-put-c-type-property' and
  ;;     `c-clear-c-type-property'.
  ;;
  ;; Still to come, in the file's order: `c-syntactic-content' (it needs
  ;; `c-forward-syntactic-ws', which is the `c-forward-sws' engine below
  ;; it), the debug overlay helpers (`c-debug-add-face'/`-remove-face',
  ;; which need the overlay API this library does not want), the
  ;; syntactic-whitespace engine (`c-forward-sws'/`c-backward-sws'), and
  ;; then `c-beginning-of-statement-1' and the rest of the parser.
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
                  1- logand)
    (only (schemacs editor subr) regexp-unmatchable)
    (only (schemacs editor buffer) current-buffer buffer-local-value
          set-buffer-local-value!)
    (only (schemacs editor command) prefix-numeric-value)
    (only (schemacs editor cmds) beginning-of-line end-of-line forward-char
          backward-char delete-char)
    (only (schemacs editor editfns) point point-min point-max goto-char
          char-before char-after bobp eobp bolp eolp
          line-beginning-position line-end-position forward-line
          save-excursion save-restriction narrow-to-region widen
          insert delete-region message buffer-substring-no-properties)
    (only (schemacs editor fns) nth nthcdr)
    (only (schemacs editor indent) back-to-indentation)
    (only (schemacs editor indentc) current-indentation indent-to)
    (only (schemacs editor search) re-search-forward re-search-backward
          looking-at match-beginning match-end save-match-data)
    (only (schemacs editor textprop) get-text-property put-text-property
          remove-text-properties text-property-any)
    (only (schemacs editor syntax) skip-chars-backward skip-chars-forward
          skip-syntax-backward skip-syntax-forward forward-comment
          parse-partial-sexp)
    (only (schemacs editor subr) regexp-unmatchable last delq copy-tree
          with-silent-modifications)
    (only (schemacs editor cc-defs) c-emacs-features c-save-buffer-state
          c-put-char-property c-clear-char-property c-get-char-property
          c-next-single-property-change c-previous-single-property-change
          %c-true %c-false c-get-lang-constant *c-buffer-is-cc-mode*
          c-major-mode-is c-safe c-forward-sexp c-backward-sexp
          c-go-list-forward c-go-list-backward c-skip-ws-chars-forward
          c-skip-ws-chars-backward c-skip-ws-forward c-skip-ws-backward)
    (only (schemacs editor intervals) get)
    (only (schemacs editor cc-vars) *c-report-syntactic-errors*
          c-noise-macro-name-re c-noise-macro-with-parens-name-re))

  (export
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
   c-doc-line-join-re c-doc-bright-comment-start-re c-doc-line-join-end-ch
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
   c-point c-is-escaped c-benign-error)

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
      ;; `symbol-value' would say "Void variable".
      (buffer-local-value (current-buffer) symbol #f))

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
    (define c-doc-line-join-re regexp-unmatchable)
    (define c-doc-bright-comment-start-re regexp-unmatchable)
    (define c-doc-line-join-end-ch #f)


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
    ;; See this library's header for the obarray replacement. The cache
    ;; is `(ALIST . TABLE)' - keyed on the *identity* of the alist the
    ;; table was built from, which is the per-language value, so a mode
    ;; change rebuilds it and nothing else does.
    (define %c-keywords-table-cache #f)

    (define (%c-keywords-language)
      ;; The buffer's language, for the lazy `c-keywords-obarray'
      ;; replacement below: its major mode when that is a cc-mode
      ;; language, else the parameter `c-buffer-is-cc-mode' (which a
      ;; mode binds around its own init and a test can parameterize).
      (let ((m (buffer-local-value (current-buffer) 'major-mode #f))
            (p (*c-buffer-is-cc-mode*)))
        (cond ((and (symbol? m) (get m 'c-mode-prefix)) m)
              ((and (symbol? p) (get p 'c-mode-prefix)) p)
              (else (error "No current language")))))

    (define (%c-keywords-table)
      (let ((alist (c-get-lang-constant 'c-keyword-member-alist #f
                                        (%c-keywords-language))))
        (if (and %c-keywords-table-cache
                 (eq? (car %c-keywords-table-cache) alist))
            (cdr %c-keywords-table-cache)
            (let ((table (make-hash-table)))
              (for-each (lambda (entry)
                          (hash-set! table (car entry) (cdr entry)))
                        (or alist '()))
              (set! %c-keywords-table-cache (cons alist table))
              table))))

    (define (c-keyword-sym keyword)
      ;; "Return non-nil if the string KEYWORD is a known keyword. More
      ;; precisely, the value is the symbol for the keyword in
      ;; `c-keywords-obarray'." (`intern-soft' into a per-language table
      ;; here - see the header.)
      (and (hash-ref (%c-keywords-table) keyword)
           (string->symbol keyword)))

    (define (c-keyword-member keyword-sym lang-constant)
      ;; "Return non-nil if the symbol KEYWORD-SYM, as returned by
      ;; `c-keyword-sym', is a member of LANG-CONSTANT, which is the name
      ;; of a language constant that ends with \"-kwds\". If KEYWORD-SYM
      ;; is nil then the result is nil."
      (and keyword-sym
           (let ((members (hash-ref (%c-keywords-table)
                                    (symbol->string keyword-sym))))
             (and (memq lang-constant members) #t))))

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
                  (looking-at c-doc-line-join-re))

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

               ((looking-at c-doc-line-join-re)
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
            (when (eq? last-put-in-sws-pos (point))
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
                                             last-put-in-sws-pos))))))))
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
            (doc-line-join-here (string-append c-doc-line-join-re "\\="))
            (attr-end #f))
        ;; "Skip simple horizontal ws and do a quick check on the
        ;; preceding character to see if it's anything that can't end
        ;; syntactic ws, so we can bail out early in the majority of cases
        ;; when there just are a few ws chars. Newlines are complicated in
        ;; the backward direction, so we can't skip over them."
        (c-skip-ws-chars-backward %c-sws-back-horiz)
        (when (and (not (bobp))
                   (save-excursion
                     (or (and c-doc-line-join-end-ch
                              (memq (char-before) c-doc-line-join-end-ch) ; "For speed."
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

               ((and c-doc-line-join-end-ch
                     (memq (char-before) c-doc-line-join-end-ch) ; "For speed."
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
            (when (eq? last-put-in-sws-pos (point))
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
                                             (+ last-put-in-sws-pos 1)))))))))

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
      (let ((limit (if (pair? limit-args) (car limit-args) #f)))
        (when (< (point) (or limit (point-max)))
          (save-restriction
            (narrow-to-region (point-min) (or limit (point-max)))
            (c-forward-sws)))))

    (define (c-backward-syntactic-ws . limit-args)
      ;; "Backward skip over syntactic whitespace. ..."
      (let ((limit (if (pair? limit-args) (car limit-args) #f)))
        (when (> (point) (or limit (point-min)))
          (save-restriction
            (narrow-to-region (or limit (point-min)) (point-max))
            (c-backward-sws)))))
    ))
