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
    (only (schemacs editor buffer) current-buffer buffer-local-value
          set-buffer-local-value!)
    (only (schemacs editor command) prefix-numeric-value)
    (only (schemacs editor cmds) beginning-of-line end-of-line forward-char
          backward-char delete-char)
    (only (schemacs editor editfns) point point-min point-max goto-char
          char-before char-after bobp eobp bolp eolp
          line-beginning-position line-end-position forward-line
          save-excursion save-restriction narrow-to-region widen
          insert delete-region message)
    (only (schemacs editor fns) nth)
    (only (schemacs editor indent) back-to-indentation)
    (only (schemacs editor indentc) current-indentation indent-to)
    (only (schemacs editor search) re-search-forward looking-at
          match-beginning match-end save-match-data)
    (only (schemacs editor textprop) get-text-property)
    (only (schemacs editor syntax) skip-chars-backward skip-chars-forward
          skip-syntax-backward skip-syntax-forward forward-comment
          parse-partial-sexp)
    (only (schemacs editor cc-defs) c-emacs-features c-save-buffer-state
          c-put-char-property c-clear-char-property c-get-char-property
          c-next-single-property-change %c-true %c-false
          c-get-lang-constant *c-buffer-is-cc-mode*)
    (only (schemacs editor intervals) get)
    (only (schemacs editor cc-vars) *c-report-syntactic-errors*))

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
   c-forward-comment-minus-1 c-backward-single-comment
   ;; basic utilities
   c-delq-from-dotted-list c-shift-line-indentation
   c-keyword-sym c-keyword-member
   c-string-syntax c-string-limit-regexp c-ws*-string-limit-regexp
   c-parsing-error set!c-parsing-error c-echo-parsing-error
   c-put-c-type-property c-clear-c-type-property
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
    ;; `c-forward-comment-minus-1' and `c-backward-single-comment'
    ;; (`cc-engine.el:1685', `:1704')
    ;;------------------------------------------------------------------
    ;; Moved up from their place in the file: both are what
    ;; `c-beginning-of-macro' above stands on, and a library's own
    ;; procedures may be defined after their callers but read better
    ;; beside them. Emacs's `c-forward-comments' (`:1660') is not
    ;; carried yet - nothing in this tranche calls it.
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
             (error "c-point 'bosws' waits on `c-backward-syntactic-ws', which is not ported yet"))
            ((eosws)
             (error "c-point 'eosws' waits on `c-forward-syntactic-ws', which is not ported yet"))
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
    ))
