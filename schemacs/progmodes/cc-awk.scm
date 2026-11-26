(define-library (schemacs progmodes cc-awk)
  ;; `lisp/progmodes/cc-awk.el' - AWK Mode's adaptation of CC Mode,
  ;; whole: the syntax table, the regexp set, the `c-awk-NL-prop'
  ;; virtual-semicolon analysis, the syntax-table-property machinery
  ;; and font-lock keywords, the before/after-change functions and the
  ;; movement commands. The keymap, abbrev table and mode function are
  ;; `cc-mode.el''s and live in `cc-mode.scm', as Emacs has them.
  ;;
  ;; The file's `defconst' regexps are its own values, transcribed
  ;; from a running Emacs 31.1 (`print-escape-newlines' and
  ;; `print-escape-control-characters' on, then the octal escapes
  ;; converted): the source strings carry line continuations and
  ;; doubled escapes, and the *value* is what the engine must be given.
  ;;
  ;; **`c-open-string-opener`** is `cc-mode.el`'s variable
  ;; (`cc-mode.el:1465'), but this library sets it, and a library
  ;; below `cc-mode` cannot import it - so its accessor pair lives in
  ;; `cc-engine.scm` now and `cc-mode.scm` re-exports it, the same
  ;; move `*current-buffer*` made. Named in DEPARTURES.md.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    (only (guile) while)
    (only (schemacs core syntax-macros) setq)
    (only (schemacs data) /=)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          local-variable-p)
    (only (schemacs intervals) *text-property-default-nonsticky*)
    (only (schemacs editfns)
          point goto-char point-min point-max char-after char-before
          insert-char save-restriction widen bolp eobp bobp eolp
          forward-line save-excursion)
    (only (schemacs cmds)
          forward-char backward-char delete-char beginning-of-line
          end-of-line)
    (only (schemacs syntax)
          modify-syntax-entry scan-lists scan-sexps)
    (only (schemacs subr) make-syntax-table)
    (only (schemacs search)
          looking-at re-search-forward re-search-backward search-forward
          match-beginning match-end save-match-data)
    (only (schemacs fns) concat)
    (only (schemacs core lisp) forward-sexp)
    (only (schemacs command) define-command quit-condition?)
    (only (schemacs font-lock) font-lock-register-keyword-variable!)
    (only (schemacs progmodes cc-defs)
          c-alpha c-alnum c-lang-const c-put-char-property
          c-get-char-property c-clear-char-properties c-put-string-fence
          c-save-buffer-state c-with-string-fences c-safe-scan-lists)
    (only (schemacs progmodes cc-engine)
          c-backward-token-1 c-beginning-of-statement-1
          c-backward-syntactic-ws c-forward-syntactic-ws
          c-syntactic-re-search-forward c-point
          c-put-syntax-table-trim-caches
          c-clear-syntax-table-properties-trim-caches
          c-put-string-fence-trim-caches
          c-register-lang-function! c-new-BEG set!c-new-BEG
          c-new-END set!c-new-END
          c-open-string-opener set!c-open-string-opener)
    (only (schemacs progmodes cc-fonts)
          c-make-font-lock-search-function c-put-font-lock-face
          c-preprocessor-face-name))

  (export
   awk-mode-syntax-table
   ;; the NL-prop analysis
   c-awk-after-if-for-while-condition-p
   c-awk-after-function-decl-param-list
   c-awk-after-continue-token
   c-awk-after-rbrace-or-statement-semicolon
   c-awk-back-to-contentful-text-or-NL-prop
   c-awk-calculate-NL-prop-prev-line
   c-awk-get-NL-prop-prev-line
   c-awk-get-NL-prop-cur-line
   c-awk-prev-line-incomplete-p
   c-awk-cur-line-incomplete-p
   c-awk-at-vsemi-p
   c-awk-vsemi-status-unknown-p
   c-awk-clear-NL-props
   c-awk-unstick-NL-prop
   ;; the syntax-table property and font-lock machinery
   c-awk-font-lock-invalid-namespace-separators
   c-awk-beginning-of-logical-line
   c-awk-beyond-logical-line
   c-awk-set-string-regexp-syntax-table-properties
   c-awk-syntax-tablify-string
   c-awk-syntax-tablify-/
   c-awk-set-syntax-table-properties
   awk-font-lock-keywords
   ;; the change functions
   c-awk-old-ByLL set!c-awk-old-ByLL
   c-awk-record-region-clear-NL
   c-awk-end-of-change-region
   c-awk-extend-and-syntax-tablify-region
   c-awk-context-expand-fl-region
   ;; the movement commands
   c-awk-at-statement-end-p
   c-awk-beginning-of-defun
   c-awk-forward-awk-pattern
   c-awk-end-of-defun1
   c-awk-beginning-of-defun-p
   c-awk-end-of-defun)

  (begin
    ;; ---------------------------------------------------------------
    ;; 1. The AWK Mode syntax table (`cc-awk.el:71'-`:91')
    ;; ---------------------------------------------------------------
    (define awk-mode-syntax-table
      (let ((st (make-syntax-table)))
        (modify-syntax-entry #\\ "\\" st)
        (modify-syntax-entry #\newline ">   " st)
        (modify-syntax-entry #\return ">   " st)
        (modify-syntax-entry #\page ">   " st)
        (modify-syntax-entry #\# "<   " st)
        ;; "/ can delimit regexes or be a division operator. By default
        ;; we assume that it is a division sign, and fix the regexp
        ;; operator cases with `c-awk-set-syntax-table-properties'."
        (modify-syntax-entry #\/ "." st)
        (modify-syntax-entry #\* "." st)
        (modify-syntax-entry #\+ "." st)
        (modify-syntax-entry #\- "." st)
        (modify-syntax-entry #\= "." st)
        (modify-syntax-entry #\% "." st)
        (modify-syntax-entry #\< "." st)
        (modify-syntax-entry #\> "." st)
        (modify-syntax-entry #\& "." st)
        (modify-syntax-entry #\| "." st)
        (modify-syntax-entry #\_ "_" st)
        (modify-syntax-entry #\' "." st)
        st))

    ;; ---------------------------------------------------------------
    ;; 2. Regular expressions for analyzing AWK code
    ;;    (`cc-awk.el:96'-`:273')
    ;; ---------------------------------------------------------------
    (define c-awk-esc-pair-re "\\\\\\(.\\|\n\\|\\'\\)")
    (define c-awk-non-eol-esc-pair-re "\\\\\\(.\\|\\'\\)")
    (define c-awk-comment-without-nl "#.*")
    (define c-awk-nl-or-eob "\\(\n\\|\r\\|\\'\\)")
    (define c-awk-escaped-nl "\\\\[\n\r]")
    (define c-awk-escaped-nls* "\\(\\\\[\n\r]\\)*")
    (define c-awk-escaped-nls*-with-space* "\\(\\\\[\n\r]\\|[ \t]\\)*")
    (define c-awk-blank-or-comment-line-re "[ \t]*\\(#\\|\\\\?$\\)")
    (define c-awk-harmless-_ "_\\([^\"]\\|\\'\\)")
    (define c-awk-harmless-char-re "[^_#/\"{}();\\\n\r]")
    (define c-awk-harmless-string*-re "\\([^_#/\"{}();\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\|_\\([^\"]\\|\\'\\)\\)*")
    (define c-awk-harmless-string*-here-re "\\=\\([^_#/\"{}();\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\|_\\([^\"]\\|\\'\\)\\)*")
    (define c-awk-harmless-line-char-re "[^_#/\"\\\n\r]")
    (define c-awk-harmless-line-string*-re "\\([^_#/\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\|_\\([^\"]\\|\\'\\)\\)*")
    (define c-awk-harmless-line-re "\\([^_#/\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\|_\\([^\"]\\|\\'\\)\\)*\\(#.*\\)?\\(\n\\|\r\\|\\'\\)")
    (define c-awk-harmless-lines+-here-re "\\=\\(\\([^_#/\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\|_\\([^\"]\\|\\'\\)\\)*\\(#.*\\)?\\(\n\\|\r\\|\\'\\)\\)+")
    (define c-awk-string-ch-re "[^\"\\\n\r]")
    (define c-awk-string-innards-re "\\([^\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\)*")
    (define c-awk-string-without-end-here-re "\\=_?\"\\([^\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\)*")
    (define c-awk-possibly-open-string-re "\"\\([^\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\)*\\(\"\\|$\\|\\'\\)")
    (define c-awk-regexp-normal-re "[^[/\\\n\r]")
    (define c-awk-escaped-newlines*-re "\\(\\\\[\n\r]\\)*")
    (define c-awk-regexp-char-class-re "\\[:[a-z]+:\\]")
    (define c-awk-regexp-char-list-re "\\[\\(\\(\\\\[\n\r]\\)*\\^\\)?\\(\\\\[\n\r]\\)*]?\\(\\\\\\(.\\|\n\\|\\'\\)\\|\\[:[a-z]+:\\]\\|[^]\n\r]\\)*\\(]\\|$\\)")
    (define c-awk-regexp-innards-re "\\(\\\\\\(.\\|\n\\|\\'\\)\\|\\[\\(\\(\\\\[\n\r]\\)*\\^\\)?\\(\\\\[\n\r]\\)*]?\\(\\\\\\(.\\|\n\\|\\'\\)\\|\\[:[a-z]+:\\]\\|[^]\n\r]\\)*\\(]\\|$\\)\\|[^[/\\\n\r]\\)*")
    (define c-awk-regexp-without-end-re "/\\(\\\\\\(.\\|\n\\|\\'\\)\\|\\[\\(\\(\\\\[\n\r]\\)*\\^\\)?\\(\\\\[\n\r]\\)*]?\\(\\\\\\(.\\|\n\\|\\'\\)\\|\\[:[a-z]+:\\]\\|[^]\n\r]\\)*\\(]\\|$\\)\\|[^[/\\\n\r]\\)*")
    (define c-awk-neutral-re "\\([}@` \t]\\|\\+\\+\\|--\\|\\\\\\(.\\|[\n\r]\\)\\)")
    (define c-awk-neutrals*-re "\\(\\([}@` \t]\\|\\+\\+\\|--\\|\\\\\\(.\\|[\n\r]\\)\\)\\)*")
    (define c-awk-var-num-ket-re "[])0-9a-zA-Z_$.]+")
    (define c-awk-div-sign-re "[])0-9a-zA-Z_$.]+\\(\\([}@` \t]\\|\\+\\+\\|--\\|\\\\\\(.\\|[\n\r]\\)\\)\\)*/")
    (define c-awk-non-arith-op-bra-re "[[({&=:!><,?;'~|]")
    (define c-awk-regexp-sign-re "[[({&=:!><,?;'~|]\\(\\([}@` \t]\\|\\+\\+\\|--\\|\\\\\\(.\\|[\n\r]\\)\\)\\)*/")
    (define c-awk-pre-exp-alphanum-kwd-re "\\_<\\(case\\|print\\|return\\)\\_>")
    (define c-awk-kwd-regexp-sign-re "\\_<\\(case\\|print\\|return\\)\\_>\\(\\\\[\n\r]\\|[ \t]\\)*/")
    (define c-awk-_-harmless-nonws-char-re "[^#/\"\\\n\r \t]")
    (define c-awk-non-/-syn-ws*-re "\\(\\(\\\\[\n\r]\\|[ \t]\\)*\\([^#/\"\\\n\r \t]\\|\\\\\\(.\\|\\'\\)\\|\"\\([^\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\)*\\(\"\\|$\\|\\'\\)\\)\\)*")
    (define c-awk-space*-/-re "\\(\\\\[\n\r]\\|[ \t]\\)*/")
    (define c-awk-space*-regexp-/-re "\\(\\\\[\n\r]\\|[ \t]\\)*\\s\"")
    (define c-awk-space*-unclosed-regexp-/-re "\\(\\\\[\n\r]\\|[ \t]\\)*\\s|")
    (define c-awk-terminated-regexp-or-string-here-re "\\=\\s\"\\S\"*\\s\"")
    (define c-awk-unterminated-regexp-or-string-here-re "\\=\\s|\\S|*$")
    (define c-awk-harmless-pattern-characters* "\\([^{;#/\"\\\n\r]\\|\\\\\\(.\\|\n\\|\\'\\)\\)*")

    ;; ---------------------------------------------------------------
    ;; 3. The `c-awk-NL-prop' virtual-semicolon analysis
    ;;    (`cc-awk.el:328'-`:654')
    ;; ---------------------------------------------------------------
    (define (c-awk-after-if-for-while-condition-p . args)
      ;; "Are we just after the ) in \"if/for/while (<condition>)\"? ...
      ;; The end of the ) in a do .... while (<condition>) doesn't
      ;; count, since the purpose of this routine is essentially to
      ;; decide whether to indent the next line. DO-LIM sets a limit on
      ;; how far back we search for the \"do\" of a possible do-while."
      ;;----------------------------------------------------------
      (let ((do-lim (if (pair? args) (car args) #f)))
        (and (eqv? (char-before) #\))
             (save-excursion
               (let ((par-pos (c-safe-scan-lists (point) -1 0)))
                 (when par-pos
                   (goto-char par-pos)          ; back over "(...)"
                   (c-backward-token-1)         ; BOB isn't a problem.
                   (or (looking-at "\\(if\\|for\\)\\_>")
                       (and (looking-at "while\\_>") ; not a do-while
                            (not (eqv? (c-beginning-of-statement-1 do-lim)
                                       'beginning))))))))))

    (define (c-awk-after-function-decl-param-list)
      ;; "Are we just after the ) in \"function foo (bar)\"?"
      ;;----------------------------------------------------------
      (and (eqv? (char-before) #\))
           (save-excursion
             (let ((par-pos (c-safe-scan-lists (point) -1 0)))
               (when par-pos
                 (goto-char par-pos)    ; back over "(...)"
                 (c-backward-token-1)   ; BOB isn't a problem
                 (and (looking-at "[_a-zA-Z][_a-zA-Z0-9]*\\_>")
                      (begin
                        (c-backward-token-1)
                        (looking-at "func\\(tion\\)?\\_>"))))))))

    (define (c-awk-after-continue-token)
      ;; "Are we just after a token which can be continued onto the next
      ;; line without a backslash?"
      ;;----------------------------------------------------------
      (save-excursion
        (c-backward-token-1)
        (when (and (looking-at "[&|]") (not (bobp)))
          (backward-char)) ; c-backward-token-1 doesn't do this :-(
        (looking-at "[,{?:]\\|&&\\|||\\|do\\_>\\|else\\_>")))

    (define (c-awk-after-rbrace-or-statement-semicolon)
      ;; "Are we just after a } or a ; which closes a statement? Be
      ;; careful about ;s in for loop control bits. They don't count!"
      ;;----------------------------------------------------------
      (or (eqv? (char-before) #\})
          (and (eqv? (char-before) #\;)
               (save-excursion
                 (let ((par-pos (c-safe-scan-lists (point) -1 1)))
                   (when par-pos
                     (goto-char par-pos) ; go back to containing (
                     (not (and (looking-at "(")
                               (c-backward-token-1) ; BOB isn't a problem
                               (looking-at "for\\_>")))))))))

    (define (c-awk-back-to-contentful-text-or-NL-prop)
      ;; "Move back to just after the first found of either (i) an EOL
      ;; which has the c-awk-NL-prop text-property set; or (ii) non-ws
      ;; text; or (iii) BOB. We return either the value of
      ;; c-awk-NL-prop (in case (i)) or nil. ... Point must be at the
      ;; start of a line when calling this function."
      ;;----------------------------------------------------------
      (let ((nl-prop #f) (bol-pos #f) (bsws-pos #f))
        (while
            (and (not (bobp))
                 (not (setq nl-prop (c-get-char-property
                                     (- (point) 1) 'c-awk-NL-prop)))
                 (begin
                   (set! bol-pos (c-point 'bopl))
                   (set! bsws-pos (point))
                   ;; "The following function will not go back past an
                   ;; EOL if there is an open string (without \) on the
                   ;; previous line. If we find such, set the
                   ;; c-awk-NL-prop on it, too (2004/3/29)."
                   (c-backward-syntactic-ws bol-pos)
                   (or (/= (point) bsws-pos)
                       (begin
                         (setq nl-prop #\$)
                         (c-put-char-property (- (point) 1)
                                              'c-awk-NL-prop nl-prop)
                         #f)))
                 (begin
                   ;; "If we had a backslash at EOL,
                   ;; c-backward-syntactic-ws will have gone backwards
                   ;; over it. Check the backslash was \"real\"."
                   (if (looking-at "[ \t]*\\\\+$")
                       ;; "Emacs does `(end-of-line)' before the search:
                       ;; the regexp's match ends at the line's end, so a
                       ;; search started above it can never find it."
                       (if (begin
                             (end-of-line)
                             (re-search-backward
                              ;; "ODD number of \s at EOL :-)"
                              "\\(^\\|[^\\]\\)\\(\\\\\\\\\\)*\\\\$"
                              bol-pos #t))
                           (begin (end-of-line) ; escaped EOL
                                  (backward-char)
                                  (c-backward-syntactic-ws bol-pos))
                           (end-of-line)))      ; the \ at eol is fake
                   (bolp))))
        nl-prop))

    (define (c-awk-calculate-NL-prop-prev-line . args)
      ;; "Calculate and set the value of the c-awk-NL-prop on the
      ;; immediately preceding EOL. ... Return the property which got
      ;; set (or was already set) on the previous line. Return nil if
      ;; we hit BOB."
      ;;----------------------------------------------------------
      (let ((do-lim (if (pair? args) (car args) #f)))
        (save-excursion
          (save-match-data
            (beginning-of-line)
            (let* ((pos (point))
                   (nl-prop (c-awk-back-to-contentful-text-or-NL-prop)))
              ;; "We are either (1) at a BOL (with nl-prop containing
              ;; the previous line's c-awk-NL-prop) or (2) after
              ;; contentful text on a line."
              (when (not (bolp))
                (set! nl-prop
                      (cond
                       ;; "Incomplete statement which doesn't require
                       ;; escaped EOL?"
                       ((or (c-awk-after-if-for-while-condition-p do-lim)
                            (c-awk-after-function-decl-param-list)
                            (c-awk-after-continue-token))
                        #\{)
                       ;; "Escaped EOL (where there's also something to
                       ;; continue)?"
                       ((and (looking-at "[ \t]*\\\\$")
                             (not (c-awk-after-rbrace-or-statement-semicolon)))
                        #\\)
                       ;; "A statement was completed on this line. How?"
                       ((memv (char-before) (list #\; #\})) #\}) ; Real ; or }
                       (else #\$)))                ; A virtual semicolon.
                (end-of-line)
                (c-put-char-property (point) 'c-awk-NL-prop nl-prop)
                (forward-line))
              ;; "We are now at a (possibly empty) sequence of
              ;; content-free lines. Set c-awk-NL-prop on each of these
              ;; lines's EOL."
              (while (< (point) pos) ; one content-free line each iteration
                (cond ; recalculate nl-prop from previous line's value
                 ((memv nl-prop (list #\} #\$ #f)) (set! nl-prop #\#))
                 ((eqv? nl-prop #\\)
                  (if (not (looking-at "[ \t]*\\\\$")) (set! nl-prop #\$))))
                ;; "?# (empty line) and ?{ (open stmt) don't change."
                (forward-line)
                (c-put-char-property (- (point) 1) 'c-awk-NL-prop nl-prop))
              nl-prop)))))

    (define (c-awk-get-NL-prop-prev-line . args)
      ;; "Get the c-awk-NL-prop text-property from the previous line,
      ;; calculating it if necessary. Return nil if we're already at
      ;; BOB."
      ;;----------------------------------------------------------
      (let ((do-lim (if (pair? args) (car args) #f)))
        (if (bobp)
            #f
            (or (c-get-char-property (c-point 'eopl) 'c-awk-NL-prop)
                (c-awk-calculate-NL-prop-prev-line do-lim)))))

    (define (c-awk-get-NL-prop-cur-line . args)
      ;; "Get the c-awk-NL-prop text-property from the current line,
      ;; calculating it if necessary. (As a special case, the property
      ;; doesn't get set on an empty line at EOB ...)"
      ;;----------------------------------------------------------
      (let ((do-lim (if (pair? args) (car args) #f)))
        (save-excursion
          (let ((extra-nl #f))
            (end-of-line) ; necessary for the following test to work
            (when (= (forward-line) 1) ; if we were on the last line....
              (insert-char #\newline 1) ; ...artificial eol for comment detection
              (set! extra-nl #t))
            (let ((res (c-awk-get-NL-prop-prev-line do-lim)))
              (when extra-nl (delete-char -1))
              res)))))

    (define (c-awk-prev-line-incomplete-p . args)
      ;; "Is there an incomplete statement at the end of the previous
      ;; line?"
      ;;----------------------------------------------------------
      (let ((do-lim (if (pair? args) (car args) #f)))
        (memv (c-awk-get-NL-prop-prev-line do-lim) (list #\\ #\{))))

    (define (c-awk-cur-line-incomplete-p . args)
      ;; "Is there an incomplete statement at the end of the current
      ;; line?"
      ;;----------------------------------------------------------
      (let ((do-lim (if (pair? args) (car args) #f)))
        (memv (c-awk-get-NL-prop-cur-line do-lim) (list #\\ #\{))))

    (define (c-awk-at-vsemi-p . args)
      ;; "Is there a virtual semicolon at POS (or POINT)?"
      ;;----------------------------------------------------------
      (let ((pos (if (pair? args) (car args) #f)))
        (save-excursion
          (let* ((nl-prop #f)
                 (pos-or-point (begin (when pos (goto-char pos)) (point)))
                 (bol (c-point 'bol)) (eol (c-point 'eol)))
            (c-awk-beginning-of-logical-line)
            ;; "Next `while' goes round one logical line (ending in,
            ;; e.g. \"\\\\\") per iteration. Such a line is rare, and
            ;; can only be an open string ending in an escaped \."
            (while
                (begin
                  ;; "Next `while' goes over a division sign or
                  ;; /regexp/ per iteration."
                  (while (and (< (point) eol)
                              (begin
                                (re-search-forward c-awk-non-/-syn-ws*-re eol #t)
                                (looking-at c-awk-space*-/-re)))
                    (cond
                     ((looking-at c-awk-space*-regexp-/-re) ; /regexp/
                      (forward-sexp))
                     ((looking-at c-awk-space*-unclosed-regexp-/-re) ; Unclosed
                      (guard (e ((quit-condition? e) (raise e))
                                (else (end-of-line))) ; happens at EOB
                        (forward-sexp)
                        (backward-char))) ; move to end of (logical) line
                     (else ; division sign
                      (c-forward-syntactic-ws)
                      (forward-char))))
                  (< (point) bol))
              (forward-line))
            (and (= (point) pos-or-point)
                 (begin
                   (while (and (eqv? (setq nl-prop
                                          (c-awk-get-NL-prop-cur-line))
                                     #\\)
                               (eqv? (forward-line) 0)
                               (looking-at c-awk-blank-or-comment-line-re)))
                   (eqv? nl-prop #\$)))))))

    (define (c-awk-vsemi-status-unknown-p)
      ;; "Are we unsure whether there is a virtual semicolon on the
      ;; current line? DO NOT under any circumstances attempt to
      ;; calculate this; that would defeat the purpose of this
      ;; function, which is to prevent an infinite recursion in
      ;; c-beginning-of-statement-1 when point starts at a `while'
      ;; token."
      ;;----------------------------------------------------------
      (not (c-get-char-property (c-point 'eol) 'c-awk-NL-prop)))

    (define (c-awk-clear-NL-props beg _end)
      ;; "This function is run from before-change-hooks. It clears the
      ;; c-awk-NL-prop text property from beg to the end of the buffer
      ;; (the END parameter is ignored)."
      ;;----------------------------------------------------------
      (save-restriction
        (widen)
        (c-clear-char-properties beg (point-max) 'c-awk-NL-prop)))

    (define (c-awk-unstick-NL-prop)
      ;; "Ensure that the text property c-awk-NL-prop is
      ;; \"non-sticky\". ... This function's action is required by
      ;; c-put-char-property."
      ;;
      ;; Emacs `setq's `text-property-default-nonsticky', which writes the
      ;; current buffer's local binding when it has one -
      ;; `c-basic-common-init' makes one in every CC Mode buffer - and the
      ;; global otherwise. Here the local is the buffer slot and the
      ;; global is the parameter. Emacs's `boundp' test is the XEmacs
      ;; check, and the variable always exists here.
      ;;----------------------------------------------------------
      (let* ((local? (local-variable-p 'text-property-default-nonsticky
                                       (current-buffer)))
             (current (if local?
                          (buffer-local-value (current-buffer)
                                              'text-property-default-nonsticky
                                              #f)
                          (*text-property-default-nonsticky*))))
        (unless (assq 'c-awk-NL-prop current)
          (let ((new (cons (cons 'c-awk-NL-prop #t) current)))
            (if local?
                (set-buffer-local-value!
                 (current-buffer) 'text-property-default-nonsticky new)
                (*text-property-default-nonsticky* new))))))

    ;; ---------------------------------------------------------------
    ;; 4. Syntax-table properties and font-locking
    ;;    (`cc-awk.el:656'-`:1077')
    ;; ---------------------------------------------------------------
    (define (c-awk-font-lock-invalid-namespace-separators limit)
      ;; "This function will be called from font-lock for a region
      ;; bounded by POINT and LIMIT ... It always returns NIL ... This
      ;; function gives invalid GAWK namespace separators (::)
      ;; font-lock-warning-face."
      ;;----------------------------------------------------------
      (while (and
              (< (point) limit)
              (c-syntactic-re-search-forward
               (concat "\\([^" (c-lang-const c-symbol-chars awk) "]::\\)"
                       "\\|"
                       "\\(::[^" c-alpha "_" "]\\)"
                       "\\|"
                       "\\(::[" (c-lang-const c-symbol-chars awk) "]*::\\)")
               limit 'bound))
        (cond
         ((match-beginning 1)           ; " ::"
          (c-put-font-lock-face (+ 1 (match-beginning 1)) (match-end 1)
                                'font-lock-warning-face)
          (goto-char (- (match-end 1) 2)))
         ((match-beginning 2)           ; ":: "
          (c-put-font-lock-face (match-beginning 2) (- (match-end 2) 1)
                                'font-lock-warning-face)
          (goto-char (- (match-end 2) 1)))
         (else                          ; "::foo::"
          (c-put-font-lock-face (match-beginning 3)
                                (+ 2 (match-beginning 3))
                                'font-lock-warning-face)
          (c-put-font-lock-face (- (match-end 3) 2) (match-end 3)
                                'font-lock-warning-face)
          (goto-char (- (match-end 3) 2)))))
      #f)

    (define (c-awk-beginning-of-logical-line . args)
      ;; "Go back to the start of the (apparent) current line (or the
      ;; start of the line containing POS), returning the buffer
      ;; position of that point. I.e., go back to the last line which
      ;; doesn't have an escaped EOL before it."
      ;;----------------------------------------------------------
      (let ((pos (if (pair? args) (car args) #f)))
        (when pos (goto-char pos))
        (forward-line 0)
        (while (and (> (point) (point-min))
                    (eqv? (char-before (- (point) 1)) #\\))
          (forward-line -1))
        (point)))

    (define (c-awk-beyond-logical-line . args)
      ;; "Return the position just beyond the (apparent) current
      ;; logical line, or the one containing POS. ... Point is
      ;; unchanged."
      ;;----------------------------------------------------------
      (let ((pos (if (pair? args) (car args) #f)))
        (save-excursion
          (when pos (goto-char pos))
          (end-of-line)
          (while (and (< (point) (point-max))
                      (eqv? (char-before) #\\))
            (end-of-line 2))
          (if (< (point) (point-max))
              (+ (point) 1)
              (point)))))

    (define (c-awk-set-string-regexp-syntax-table-properties beg end)
      ;; "BEG and END bracket a (possibly unterminated) string or
      ;; regexp. The opening delimiter is after BEG, and the closing
      ;; delimiter, IF ANY, is AFTER END. Set the appropriate
      ;; syntax-table properties on the delimiters and contents of this
      ;; string/regex."
      ;;----------------------------------------------------------
      (if (eqv? (char-after beg) #\_) (set! beg (+ beg 1)))
      ;; "First put the properties on the delimiters."
      (cond
       ((= end (point-max))             ; string/regexp terminated by EOB
        (c-put-string-fence-trim-caches beg))
       ((not (eqv? (char-after beg) (char-after end))) ; missing end delimiter
        (c-put-string-fence-trim-caches beg)
        (c-put-string-fence end))
       ((eqv? (char-after beg) #\/)     ; properly bracketed regexp
        (c-put-syntax-table-trim-caches beg '(7)) ; (7) = "string"
        (c-put-char-property end 'syntax-table '(7))))
      ;; "Now change the properties of any escaped \"s in the string to
      ;; punctuation."
      (save-excursion
        (goto-char (+ beg 1))
        (unless (eobp)
          (while (search-forward "\"" end #t)
            (c-put-syntax-table-trim-caches (- (point) 1) '(1))))))

    (define (c-awk-syntax-tablify-string)
      ;; "Point is at the opening \" or _\" of a string. ... The result
      ;; is nil if a / immediately after the string would be a regexp
      ;; opener, t if it would be a division sign."
      ;;----------------------------------------------------------
      (let ((string-start (if (eqv? (char-after) #\_) (+ (point) 1) (point))))
        (re-search-forward c-awk-string-without-end-here-re #f #t) ; possibly unterminated
        (c-awk-set-string-regexp-syntax-table-properties
         (match-beginning 0) (match-end 0))
        (cond
         ((looking-at "\"")
          (forward-char)
          #t)                            ; In AWK, ("15" / 5) gives 3 ;-)
         ((looking-at "[\n\r]")          ; unterminated string with EOL
          (set!c-open-string-opener string-start)
          (forward-char)
          #f)                            ; / on next line would start a regexp
         (else                           ; unterminated string at EOB
          (set!c-open-string-opener string-start)
          #f))))

    (define (c-awk-syntax-tablify-/ anchor anchor-state-/div)
      ;; "Point is at a /. Determine whether this is a division sign or
      ;; a regexp opener, and if the latter, apply syntax-table
      ;; properties to the entire regexp. ... ANCHOR-STATE-/DIV
      ;; identifies whether a / at ANCHOR would have been a division
      ;; sign (value t) or a regexp opener (value nil)."
      ;;----------------------------------------------------------
      (let ((/point (point)))
        (goto-char anchor)
        ;; "Analyze the line to find out what the / is."
        (if (if anchor-state-/div
                (not (re-search-forward c-awk-regexp-sign-re (+ /point 1) #t))
                (and (not (re-search-forward c-awk-kwd-regexp-sign-re
                                             (+ /point 1) #t))
                     (re-search-forward c-awk-div-sign-re (+ /point 1) #t)))
            ;; "A division sign."
            (begin (goto-char (+ /point 1)) #f)
            ;; "A regexp opener."
            (begin
              (goto-char /point)
              (re-search-forward c-awk-regexp-without-end-re)
              (c-awk-set-string-regexp-syntax-table-properties
               (match-beginning 0) (match-end 0))
              (cond
               ((looking-at "/")        ; terminating /
                (forward-char)
                #t)
               ((looking-at "[\n\r]")   ; incomplete regexp terminated by EOL
                (forward-char)
                #f)                     ; / on next line starts another regexp
               (else #f))))))           ; unterminated regexp at EOB

    (define (c-awk-set-syntax-table-properties lim)
      ;; "Scan the buffer text between point and LIM, setting (and
      ;; clearing) the syntax-table property where necessary. ... Point
      ;; is left \"undefined\" after this function exits. The buffer
      ;; should have been widened, and any precious match-data saved
      ;; before calling this routine."
      ;;----------------------------------------------------------
      (let ((anchor #f) (anchor-state-/div #f))
        (c-awk-beginning-of-logical-line) ; probably redundant
        (c-clear-syntax-table-properties-trim-caches (point) lim)
        ;; "Once round the next loop for each string, regexp, or div sign."
        (while (begin
                 ;; "Skip any \"harmless\" lines before the next tricky one."
                 (if (re-search-forward c-awk-harmless-lines+-here-re #f #t)
                     (set! anchor-state-/div #f))
                 (< (point) lim))
          (set! anchor (point))
          (re-search-forward c-awk-harmless-string*-here-re #f #t)
          ;; "We are now looking at either a \" or a / or a
          ;; brace/paren/semicolon. Do our thing on the string, regexp
          ;; or division sign or update our state."
          (set! anchor-state-/div
                (cond
                 ((looking-at "_?\"") (c-awk-syntax-tablify-string))
                 ((eqv? (char-after) #\/)
                  (c-awk-syntax-tablify-/ anchor anchor-state-/div))
                 ((memv (char-after) (list #\{ #\} #\( #\;))
                  (forward-char)
                  #f)
                 (else                    ; ?\)
                  (forward-char)
                  #t))))
        #f))

    (define awk-font-lock-keywords
      ;; "Default expressions to highlight in AWK mode."
      ;;
      ;; The C's `(eval . FORM)' entries are written as the values they
      ;; evaluate to, as elsewhere in this tree; the anchored
      ;; highlighters' slots are procedures of LIMIT.
      ;;----------------------------------------------------------
      (list
       ;; "Function declarations."
       (c-make-font-lock-search-function
        "^\\s *\\(func\\(tion\\)?\\)\\s +\\(\\(\\sw+\\(::\\sw+\\)?\\)\\s *\\)?\\(([^()]*)\\)?"
        (list 1 'font-lock-keyword-face #t)
        (list (lambda (limit)
                (when (match-beginning 4)
                  (c-put-font-lock-face (match-beginning 4) (match-end 4)
                                        'font-lock-function-name-face)
                  #f)))
        (list (lambda (limit)
                ;; "Put warning face on any use of :: inside the parens."
                (when (match-beginning 6)
                  (goto-char (+ 1 (match-beginning 6)))
                  (let ((end (- (match-end 6) 1)))
                    (while (and (< (point) end)
                                (c-syntactic-re-search-forward "::" end #t))
                      (c-put-font-lock-face (- (point) 2) (point)
                                            'font-lock-warning-face)))
                  #f))))
       ;; "Variable names."
       (cons "\\_<\\(ARG\\(?:IND\\|[CV]\\)\\|BINMODE\\|CONVFMT\\|E\\(?:NVIRON\\|RRNO\\)\\|F\\(?:I\\(?:ELDWIDTHS\\|LENAME\\)\\|NR\\|PAT\\|S\\|UNCTAB\\)\\|IGNORECASE\\|LINT\\|N[FR]\\|O\\(?:F\\(?:MT\\|S\\)\\|RS\\)\\|PR\\(?:EC\\|OCINFO\\)\\|R\\(?:LENGTH\\|OUNDMODE\\|START\\|[ST]\\)\\|S\\(?:UBSEP\\|YNTAB\\)\\|TEXTDOMAIN\\)\\_>"
             'font-lock-variable-name-face)
       ;; "Special file names. (acm, 2002/7/22)"
       (list "\\(\"/dev/\\(fd/[0-9]+\\|p\\(\\(\\(gr\\)?p\\)?id\\)\\|std\\(err\\|in\\|out\\)\\|user\\)\\)\\_>\\(\\(\"\\)\\|\\([^\"/\n\r][^\"\n\r]*\\)?$\\)"
             (list 1 'font-lock-variable-name-face #t)
             (list 8 'font-lock-variable-name-face #t #t))
       (list "\\(\"/inet[46]?/\\(\\(raw\\|\\(tc\\|ud\\)p\\)/[[:alnum:]]+/[[:alnum:]]+/[[:alnum:]]+\\)\\)\\_>\\(\\(\"\\)\\|\\([^\"/\n\r][^\"\n\r]*\\)?$\\)"
             (list 1 'font-lock-variable-name-face #t)
             (list 6 'font-lock-variable-name-face #t #t))
       ;; "Keywords."
       "\\_<\\(BEGIN\\(?:FILE\\)?\\|END\\(?:FILE\\)?\\|break\\|c\\(?:\\(?:as\\|ontinu\\)e\\)\\|d\\(?:e\\(?:fault\\|lete\\)\\|o\\)\\|e\\(?:lse\\|xit\\)\\|for\\|getline\\|i[fn]\\|next\\(?:file\\)?\\|return\\|switch\\|while\\)\\_>"
       ;; "Builtins."
       (list "\\_<\\(a\\(?:dump\\|nd\\|sorti?\\|tan2\\)\\|bindtextdomain\\|c\\(?:lose\\|o\\(?:mpl\\|s\\)\\)\\|dc\\(?:n?gettext\\)\\|ex\\(?:p\\|tension\\)\\|fflush\\|g\\(?:\\(?:en\\)?sub\\)\\|i\\(?:n\\(?:dex\\|t\\)\\|sarray\\)\\|l\\(?:ength\\|og\\|shift\\)\\|m\\(?:atch\\|k\\(?:bool\\|time\\)\\)\\|or\\|p\\(?:atsplit\\|rintf?\\)\\|r\\(?:and\\|shift\\)\\|s\\(?:in\\|p\\(?:lit\\|rintf\\)\\|qrt\\|rand\\|t\\(?:opme\\|r\\(?:ftime\\|tonum\\)\\)\\|ub\\(?:str\\)?\\|yst\\(?:em\\|ime\\)\\)\\|t\\(?:o\\(?:\\(?:low\\|upp\\)er\\)\\|ypeof\\)\\|xor\\)\\_>"
             0 c-preprocessor-face-name)
       ;; "Directives"
       (list "@\\(include\\|load\\|namespace\\)\\_>" 0 c-preprocessor-face-name)
       ;; "User defined functions with an apparent spurious space before
       ;; the opening parenthesis."
       (list "\\(\\w\\|_\\)\\(\\\\[\n\r]\\)*\\s \\(\\\\[\n\r]\\|[ \t]\\)*("
             (list 0 'font-lock-warning-face))
       ;; "Double :: tokens, or the same with space(s) around them."
       c-awk-font-lock-invalid-namespace-separators
       ;; "Space after \ in what looks like an escaped newline."
       (list "\\\\\\s +$" 0 'font-lock-warning-face #t)
       ;; "Unbalanced string (\") or regexp (/) delimiters."
       (list "\\s|" 0 'font-lock-warning-face #t #f)
       ;; "gawk 3.1 localizable strings ( _\"translate me!\")."
       (list "\\(_\\)\\s|" 1 'font-lock-warning-face)
       (list "\\(_\\)\\s\"" 1 'font-lock-string-face)))

    ;; ---------------------------------------------------------------
    ;; 5. The AWK Mode before/after-change functions
    ;;    (`cc-awk.el:893'-`:960')
    ;; ---------------------------------------------------------------
    (define (c-awk-old-ByLL)
      ;; `c-awk-old-ByLL' (`cc-awk.el:893'): "Just beyond logical line
      ;; following the region which is about to be changed."
      ;;----------------------------------------------------------
      (buffer-local-value (current-buffer) 'c-awk-old-ByLL 0))
    (define (set!c-awk-old-ByLL value)
      (set-buffer-local-value! (current-buffer) 'c-awk-old-ByLL value))

    (define (c-awk-record-region-clear-NL _beg end)
      ;; "This function is called exclusively from the
      ;; before-change-functions hook. It does two things: Finds the end
      ;; of the (logical) line on which END lies, and clears
      ;; c-awk-NL-prop text properties from this point onwards."
      ;;----------------------------------------------------------
      (c-save-buffer-state ()
        (set!c-awk-old-ByLL (c-awk-beyond-logical-line end))
        (c-save-buffer-state ()
          (c-awk-clear-NL-props end (point-max)))))

    (define (c-awk-end-of-change-region beg end old-len)
      ;; "Find the end of the region which needs to be font-locked after
      ;; a change. This is the end of the logical line on which the
      ;; change happened, either as it was before the change, or as it
      ;; is now, whichever is later."
      ;;----------------------------------------------------------
      (max (+ (- (c-awk-old-ByLL) old-len) (- end beg))
           (c-awk-beyond-logical-line end)))

    (define (c-awk-extend-and-syntax-tablify-region beg end old-len)
      ;; "Expand the region (BEG END) as needed to (c-new-BEG
      ;; c-new-END) then put `syntax-table' properties on this region."
      ;;----------------------------------------------------------
      (c-save-buffer-state ()
        (set!c-new-END (c-awk-end-of-change-region beg end old-len))
        (set!c-new-BEG (c-awk-beginning-of-logical-line beg))
        (goto-char (c-new-BEG))
        (c-awk-set-syntax-table-properties (c-new-END))))

    (define (c-awk-context-expand-fl-region beg end)
      ;; "Return a cons (NEW-BEG . NEW-END), where NEW-BEG is the
      ;; beginning of the logical line BEG is on, and NEW-END is the
      ;; beginning of the line after the end of the logical line that
      ;; END is on."
      ;;----------------------------------------------------------
      (cons (save-excursion (c-awk-beginning-of-logical-line beg))
            (c-awk-beyond-logical-line end)))

    ;; ---------------------------------------------------------------
    ;; 6. Movement commands (`cc-awk.el:1078'-`:1239')
    ;; ---------------------------------------------------------------
    (define (c-awk-at-statement-end-p)
      ;; "Point is not inside a comment or string. Is it AT the end of a
      ;; statement? This means immediately after the last non-ws
      ;; character of the statement."
      ;;----------------------------------------------------------
      (and (not (bobp))
           (save-excursion
             (backward-char)
             (or (looking-at "[};]")
                 (and (memv (c-awk-get-NL-prop-cur-line) (list #\$ #\\))
                      (looking-at
                       (concat "[^ \t\n\r\\]"
                               c-awk-escaped-nls*-with-space*
                               "[#\n\r]")))))))

    (define-command (c-awk-beginning-of-defun . rest)
      "Move backward to the beginning of an AWK \"defun\".
With ARG, do it that many times.  Negative arg -N means move
forward to Nth following beginning of defun.  Returns t unless
search stops due to beginning or end of buffer.

By a \"defun\" is meant either a pattern-action pair or a function.  The start
of a defun is recognized as code starting at column zero which is neither a
closing brace nor a comment nor a continuation of the previous line.  Unlike
in some other modes, having an opening brace at column 0 is neither necessary
nor helpful.

Note that this function might do hidden buffer changes.  See the
comment at the start of cc-engine.el for more info."
      (interactive "p")
      (let ((arg (if (pair? rest) (car rest) #f)))
        (unless arg (set! arg 1))
        (c-with-string-fences
         (save-match-data
           (c-save-buffer-state ()
             (let ((found #t))
               (if (>= arg 0)
                   ;; "Go back one defun each time round the following
                   ;; loop. (For +ve arg)"
                   (while (and found (> arg 0) (not (= (point) (point-min))))
                     ;; "Go back one \"candidate\" each time round the
                     ;; next loop until one is genuinely a
                     ;; beginning-of-defun."
                     (while (and (setq found
                                       (re-search-backward
                                        "^[^#} \t\n\r]" (point-min)
                                        'stop-at-limit))
                                 (not (memv (c-awk-get-NL-prop-prev-line)
                                            (list #\$ #\} #\#)))))
                     (set! arg (- arg 1)))
                   ;; "The same for a -ve arg."
                   (begin
                     (if (not (= (point) (point-max))) (forward-char 1))
                     (while (and found (< arg 0) (not (= (point) (point-max))))
                       (while (and (setq found
                                         (re-search-forward
                                          "^[^#} \t\n\r]" (point-max)
                                          'stop-at-limit))
                                   (not (memv (c-awk-get-NL-prop-prev-line)
                                              (list #\$ #\} #\#)))))
                       (set! arg (+ arg 1)))
                     (if found (goto-char (match-beginning 0)))))
               (eqv? arg 0)))))))

    (define (c-awk-forward-awk-pattern)
      ;; "Point is at the start of an AWK pattern (which may be null) or
      ;; function declaration. Move to the pattern's end, and past any
      ;; trailing space or comment. ..."
      ;;----------------------------------------------------------
      (while
          (begin
            (re-search-forward c-awk-harmless-pattern-characters*)
            (if (looking-at "#") (end-of-line))
            (cond
             ((eobp) #f)
             ((looking-at "[{;]") #f)   ; "We've finished!"
             ((eolp)
              (if (c-awk-cur-line-incomplete-p)
                  (begin (forward-line) #t) ; returns non-nil
                  #f))
             ((re-search-forward c-awk-terminated-regexp-or-string-here-re
                                 #f #t))
             ((re-search-forward c-awk-unterminated-regexp-or-string-here-re
                                 #f #t))
             ((looking-at "/") (forward-char) #t) ; division sign
             (else #f)))))

    (define (c-awk-end-of-defun1)
      ;; "Point is at the start of a \"defun\". Move to its end. Return
      ;; end position."
      ;;----------------------------------------------------------
      (c-awk-forward-awk-pattern)
      (cond
       ((looking-at "{") (goto-char (scan-sexps (point) 1)))
       ((looking-at ";") (forward-char))
       ((eolp) #t)
       (else (error "c-awk-end-of-defun1:  Failure of c-awk-forward-awk-pattern")))
      (point))

    (define (c-awk-beginning-of-defun-p)
      ;; "Are we already at the beginning of a defun? (i.e. at code in
      ;; column 0 which isn't a }, and isn't a continuation line of any
      ;; sort.)"
      ;;----------------------------------------------------------
      (and (looking-at "^[^#} \t\n\r]")
           (not (c-awk-prev-line-incomplete-p))))

    (define-command (c-awk-end-of-defun . rest)
      "Move forward to next end of defun.  With argument, do it that many times.
Negative argument -N means move back to Nth preceding end of defun.

An end of a defun occurs right after the closing brace that matches the
opening brace at its start, or immediately after the AWK pattern when there is
no explicit action; see function `c-awk-beginning-of-defun'.

Note that this function might do hidden buffer changes.  See the
comment at the start of cc-engine.el for more info."
      (interactive "p")
      (let ((arg (if (pair? rest) (car rest) #f)))
        (unless arg (set! arg 1))
        (c-with-string-fences
         (save-match-data
           (c-save-buffer-state ()
             (let ((start-point (point)) (end-point #f))
               ;; "Strategy: (For +ve ARG): If we're not already at a
               ;; beginning-of-defun, move backwards to one."
               (when (> arg 0)
                 ;; "Try to move back to a beginning-of-defun, if not
                 ;; already at one."
                 (if (not (c-awk-beginning-of-defun-p))
                     (when (not (c-awk-beginning-of-defun 1)) ; no bo-defun before point
                       (goto-char start-point)
                       (c-awk-beginning-of-defun -1))) ; at EOB, tough!
                 ;; "Now count forward, one defun at a time"
                 (while (and (not (eobp))
                             (c-awk-end-of-defun1)
                             (if (> (point) start-point)
                                 (begin (set! arg (- arg 1)) arg)
                                 #t)
                             (> arg 0)
                             (c-awk-beginning-of-defun -1))))
               ;; Emacs's body value is its *last* `when`'s: nil for
               ;; ARG >= 0 (both `when`s' tests fail or the positive
               ;; one ends in a `while`), and, for ARG < 0, the value of
               ;; its final `goto-char` - which is the position (the C's
               ;; "Return POSITION"). Scheme's `when` and `while` answer
               ;; the unspecified value, which M-x would echo, so the
               ;; else arm is explicit.
               (if (< arg 0)
                   (begin
                     (set! end-point start-point)
                     (while (and (not (bobp))
                                 (c-awk-beginning-of-defun 1)
                                 (if (< (setq end-point
                                              (if (bobp)
                                                  (point)
                                                  (save-excursion (c-awk-end-of-defun1))))
                                        start-point)
                                     (begin (set! arg (+ arg 1)) arg)
                                     #t)
                                 (< arg 0)))
                     (goto-char (min start-point end-point)))
                   #f)))))))

    ;; ---------------------------------------------------------------
    ;; The language functions awk's language variables name, and the
    ;; font-lock keyword variable, registered at load: a symbol-valued
    ;; language function is resolved through the registry here (there
    ;; is no function obarray), and font-lock finds a keyword variable
    ;; through `*font-lock-keyword-variables*'.
    ;; ---------------------------------------------------------------
    (c-register-lang-function! 'c-awk-record-region-clear-NL
                               c-awk-record-region-clear-NL)
    (c-register-lang-function! 'c-awk-extend-and-syntax-tablify-region
                               c-awk-extend-and-syntax-tablify-region)
    (c-register-lang-function! 'c-awk-context-expand-fl-region
                               c-awk-context-expand-fl-region)
    (c-register-lang-function! 'c-awk-at-vsemi-p c-awk-at-vsemi-p)
    (c-register-lang-function! 'c-awk-vsemi-status-unknown-p
                               c-awk-vsemi-status-unknown-p)

    (font-lock-register-keyword-variable! 'awk-font-lock-keywords
                                          awk-font-lock-keywords)

    ))
