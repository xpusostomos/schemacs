(define-library (schemacs external groovy-modes groovy-mode)
  ;; A port of `groovy-mode.el' from Groovy-Emacs-Modes
  ;; (https://github.com/Groovy-Emacs-Modes/groovy-emacs-modes, version
  ;; 2.2) - the major mode for Groovy source files, kept under
  ;; `schemacs/external' because it is not part of GNU Emacs.  Every
  ;; function is the upstream one, in the file's order, with its
  ;; docstring; the translations are the mechanical elisp-to-scheme
  ;; ones (`setq' is `set!', `when' whose value is used is an `if',
  ;; `dolist'/`while' are named lets) unless a comment says otherwise.
  ;;
  ;; Its dependencies are the package's own (`s' and `dash', ported
  ;; as the subsets `(schemacs external s)' and `(schemacs external
  ;; dash)' carry), and GNU Emacs's `rx' and `find-cmd' - all ported.
  ;;
  ;; **Departures, each named where it is:**
  ;;
  ;;   * `defgroup groovy' is carried now that `defgroup` is
  ;;     (`custom.scm`'s group half). The Customize *UI* is the part
  ;;     still missing; the group, its documentation and its membership
  ;;     are recorded the way Emacs records them.
  ;;   * `groovy-parent-mode` is a plain alias binding (the C's
  ;;     `defalias` with its `fboundp` dance is for Emacsen without
  ;;     `prog-mode`; this tree has one).
  ;;   * **`groovy-font-lock-keywords` is defined *after* the search
  ;;     functions it names**, where Emacs's `defvar` holds their
  ;;     symbols and lets the obarray resolve them.  A Scheme keyword
  ;;     list holds the *procedures*, so they must exist when the list
  ;;     is built; the two inline `lambda` matchers are Emacs's own and
  ;;     only name functions already defined above them.
  ;;   * The two `eval-when-compile` regexp `defconst`s are plain
  ;;     `define`s: this tree has no compile-time evaluation, and the
  ;;     values are needed when the syntax-propertize rules are built at
  ;;     load.
  ;;   * `imenu-generic-expression` and `electric-indent-chars` are both
  ;;     set now that `(schemacs imenu)` and `(schemacs electric)` carry
  ;;     the machines behind them; both are buffer-local in Emacs, so the
  ;;     tree's setter pairs are called (`set!imenu-generic-expression`,
  ;;     `set!electric-indent-chars`) where Emacs `setq-local`s.
  ;;   * `cl-incf`/`cl-decf`/`cl-oddp` from `cl-lib` are written as
  ;;     their expansions (`(+ x 1)`, `(odd? x)`), which is what the
  ;;     macros produce.
  ;;   * `syntax-propertize-rules` is a PROCEDURE here (see its own
  ;;     header in `search.scm`): a rule's action is a descriptor
  ;;     string or a `(ignore THUNK)`/`(prog1 X THUNK...)` list, so the
  ;;     rules below are `list` calls where Emacs has a macro.
  (import
    (scheme base)
    (only (guile) 1+ 1- catch format throw)
    (only (schemacs external s)
          s-trim s-starts-with-p s-ends-with-p s-split s-blank-str-p
          s-matches-p)
    (only (schemacs external dash) ->>)
    (only (schemacs core rx) rx rx-to-string)
    (only (schemacs core regexp-opt) regexp-opt)
    ;; `when-e` is Emacs's `when` value for the matchers below: a
    ;; font-lock matcher's false answer must be `#f`, and an unadorned
    ;; `when` answers the unspecified value, which is true - the
    ;; keyword loop then never advances past a failed match.
    (only (schemacs core syntax-macros) when-e unless-e)
    (only (schemacs custom) define-custom defgroup)
    (only (schemacs imenu) set!imenu-generic-expression)
    (only (schemacs electric)
          electric-indent-chars set!electric-indent-chars)
    (only (schemacs faces) defface)
    (only (schemacs font-lock) set!font-lock-defaults!
          font-lock-register-keyword-variable!)
    (only (schemacs keymap) make-sparse-keymap)
    (only (schemacs core derived) define-derived-mode)
    (only (schemacs data) natnump)
    (only (schemacs command) define-command)
    (only (schemacs buffer)
          current-buffer get-buffer bufferp buffer-name buffer-file-name
          set-buffer-local-value! buffer-local-value)
    (only (schemacs subr) add-to-list make-syntax-table
          with-silent-modifications replace-regexp-in-string)
    (only (schemacs files) *auto-mode-alist* *interpreter-mode-alist*)
    (only (schemacs core byte-run) defsubst)
    (only (schemacs syntax)
          modify-syntax-entry syntax-ppss
          parse-partial-sexp string-to-syntax skip-chars-backward
          scan-error?)
    (only (schemacs search)
          re-search-forward re-search-backward search-forward looking-back
          string-match string-match-p match-beginning match-end match-string
          match-data set-match-data save-match-data syntax-propertize-rules)
    (only (schemacs textprop)
          put-text-property remove-text-properties get-text-property
          text-properties-at next-single-property-change)
    (only (schemacs editfns)
          point point-min point-max goto-char buffer-substring
          buffer-substring-no-properties line-beginning-position
          line-end-position char-after char-before save-excursion
          forward-line bolp eolp)
    (only (schemacs cmds) backward-char forward-char end-of-line)
    (only (schemacs indent) indent-line-to)
    (only (schemacs indentc) current-column current-indentation
          move-to-column)
    (only (schemacs core lisp) backward-sexp backward-list)
    (only (schemacs fns) line-number-at-pos nth)
    (only (schemacs subr) last car-safe)
    (only (schemacs progmodes prog-mode) prog-mode))

  (export groovy-mode groovy-mode-map *groovy-mode-hook*
          groovy-mode-syntax-table groovy-parent-mode
          *groovy-indent-offset* *groovy-highlight-assignments*
          groovy-annotation-face
          groovy-type-regexp groovy-declaration-keyword-regex
          groovy-declaration-regexp groovy-symbol-regexp
          groovy-variable-assignment-regexp groovy-class-regexp
          groovy-interface-regexp groovy-annotation-regexp
          groovy-imenu-regexp groovy-font-lock-keywords
          groovy-shebang-regex groovy-triple-double-quoted-string-regex
          groovy-triple-single-quoted-string-regex groovy-slashy-open-regex
          groovy-dollar-slashy-open-regex groovy-dollar-slashy-close-regex
          groovy-postfix-operator-regex groovy-syntax-propertize-function
          groovy-special-variable-search groovy-function-name-search
          groovy-special-prop-search groovy-variable-assignment-search
          groovy-declaration-search groovy-stringify-triple-quote
          groovy-stringify-slashy-string
          groovy-stringify-dollar-slashy-open
          groovy-stringify-dollar-slashy-close
          groovy-indent-line groovy--case-regexp groovy--ends-with-infix-p
          groovy--remove-comments)

  (begin

    (define (setq-local name value)
      ;; What `(setq-local NAME VALUE)' does - see `scheme.scm`'s copy.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer) name value))

    (define groovy-mode-syntax-table
      (let ((table (make-syntax-table)))
        ;; Operators
        ;; http://docs.groovy-lang.org/latest/html/documentation/#groovy-operators
        (for-each (lambda (i)
                    (modify-syntax-entry i "." table))
                  '(#\+ #\- #\* #\/ #\% #\& #\| #\^ #\! #\< #\> #\~ #\@ #\=))
        ;; Strings
        (modify-syntax-entry #\" "\"" table)
        (modify-syntax-entry #\\ "\\" table)
        (modify-syntax-entry #\' "\"" table)
        ;; Comments
        (modify-syntax-entry #\/ ". 124b" table)
        (modify-syntax-entry #\* ". 23" table)
        (modify-syntax-entry #\newline "> b" table)
        (modify-syntax-entry (integer->char 13) "> b" table)
        table)
      ;; "Syntax table used in Groovy mode buffers."
      )

    (add-to-list *auto-mode-alist*
                 (cons "\\.g\\(?:ant\\|roovy\\|radle\\)\\'" 'groovy-mode))
    (add-to-list *auto-mode-alist*
                 (cons "/Jenkinsfile\\'" 'groovy-mode))
    (add-to-list *interpreter-mode-alist* (cons "groovy" 'groovy-mode))

    ;; Regexp Constants
    (define groovy-type-regexp
      (rx symbol-start
          (group
           (or
            ;; Treat Foo, FooBar and FFoo as type names, but not FOO.
            (seq (+ upper) lower (0+ (or (syntax symbol) (syntax word))))
            "byte"
            "short"
            "int"
            "long"
            "float"
            "double"
            "boolean"
            "char"
            "void"))
          symbol-end
          (? "[]"))
      ;; "Matches types, where the name is first group."
      )

    (define groovy-declaration-keyword-regex
      (rx
       (* space)
       symbol-start
       (group (*
               (seq
                (+ (or "def" "public" "private" "protected" "final" "static"
                       "abstract" "synchronized" "native")
                   (+ space))))))
      ;; "Matches declaration keywords."
      )

    (define groovy-declaration-regexp
      (rx-to-string
       `(seq
         (or bol "(" ";" "," "{")
         (regexp ,groovy-declaration-keyword-regex)
         (seq
          (* space)
          symbol-start
          (group
           (or
            ;; Treat Foo, FooBar and FFoo as type names, but not FOO.
            ;; also Foo<Bar>
            (seq (+ upper) lower (* (syntax word)) (or " " "<"))
            (seq (or
                  "def"
                  "byte"
                  "short"
                  "int"
                  "long"
                  "float"
                  "double"
                  "boolean"
                  "char"
                  "void")
                 symbol-end
                 (? "[]")))))))
      ;; "Matches declarations of the type `def FooBar<?>'."
      )

    (define groovy-symbol-regexp
      (rx
       symbol-start
       (group (+ (or (syntax word) (syntax symbol))))
       symbol-end)
      ;; "A variable name or a type name."
      )

    (define groovy-variable-assignment-regexp
      (rx-to-string
       `(seq
         (regexp ,groovy-symbol-regexp)
         (* space)
         "="
         (not (any "~" "="))))
      ;; "Matches variable assignments of the type `a = 1'."
      )

    (define groovy-class-regexp
      "^[ \t\n\r]*\\(final\\|abstract\\|public\\|[ \t\n\r]\\)*class[ \t\n\r]+\\([a-zA-Z0-9_$]+\\)[^;{]*{"
      ;; "Matches class names in groovy code, select match 2."
      )

    (define groovy-interface-regexp
      (rx-to-string
       `(seq
         line-start (0+ space)
         (0+ (or "abstract" "public") (+ space))
         "interface" (+ space)
         (group (regexp ,groovy-symbol-regexp))))
      ;; "Matches interface names in groovy code."
      )

    (define groovy-annotation-regexp
      (rx "@" symbol-start (+ (or (syntax word) (syntax symbol))) symbol-end)
      ;; "Match annotation names."
      )

    ;; vars
    (define groovy-imenu-regexp
      (list ;; FIXME: removed `groovy-function-regexp', now is using a function.
       ;; (list "Functions" groovy-function-regexp 2)
       (list "Classes" groovy-class-regexp 2)
       (list "Interfaces" groovy-interface-regexp 1)
       (list "Closures" "def[ \t]+\\([a-zA-Z_][a-zA-Z0-9_]*\\)[ \t]*=[ \t]*{" 1))
      ;; "Imenu expression for Groovy."
      ;;
      ;; **Recorded but not installed**: see the header.
      )

    ;; For compatibility with Emacs < 24 - the `fboundp' dance is for
    ;; Emacsen without `prog-mode`, and this tree has one.
    (define groovy-parent-mode prog-mode)

    (defsubst groovy--in-string-p ()
      ;; "Return t if (point) is in a string."
      (nth 3 (syntax-ppss)))

    (defsubst groovy--in-string-at-p (pos)
      ;; "Return t if POS is in a string."
      (save-excursion
        (nth 3 (syntax-ppss pos))))

    (define (groovy--preceded-by-odd-number-of-backslashes)
      ;; "Return non-nil if point is preceded by an odd number of
      ;; backslashes."
      (let ((point (- (point) 2))
            (slashes 0))
        (let loop ()
          (when (eq? (char-before point) #\\)
            (set! slashes (+ slashes 1))       ; cl-incf
            (set! point (- point 1))           ; cl-decf
            (loop)))
        (odd? slashes)))                       ; cl-oddp

    (define (groovy-special-variable-search limit)
      ;; "Search for text marked with `groovy-special-variable' up to
      ;; LIMIT."
      (groovy-special-prop-search limit 'groovy-special-variable))

    (define (groovy-function-name-search limit)
      ;; "Search for text marked with `groovy-special-variable' up to
      ;; LIMIT."
      (groovy-special-prop-search limit 'groovy-function-name))

    (define (groovy-special-prop-search limit prop-name)
      ;; "Search up to LIMIT for text property PROP-NAME."
      (let* ((pos (point))
             (chg (next-single-property-change pos prop-name #f limit)))
        (when-e (and chg (> chg pos))
          (goto-char chg)
          (let ((v (get-text-property chg prop-name)))
            (set-match-data v)
            (or v (groovy-special-prop-search limit prop-name))))))

    ;; `font-lock-defaults` names the keyword variable by SYMBOL, and a
    ;; symbol has no value here (see `*font-lock-keyword-variables*`);
    ;; registering a THUNK keeps the mode's own mutation - the
    ;; `groovy-highlight-assignments` append - visible, where Emacs's
    ;; `(eval keywords)` re-reads the variable each setup.
    (font-lock-register-keyword-variable! 'groovy-font-lock-keywords
      (lambda () groovy-font-lock-keywords))

    (define groovy-shebang-regex
      ;; http://groovy-lang.org/syntax.html#_shebang_line
      (rx buffer-start "#"))

    (define groovy-triple-double-quoted-string-regex
      (rx "\"\"\""))

    (define groovy-triple-single-quoted-string-regex
      (rx "'''"))

    (define groovy-slashy-open-regex
      ;; /foo/ is a slashy-string, but // or /* are not.
      (rx "/" (not (any "/" "*"))))

    (define groovy-dollar-slashy-open-regex
      (rx "$/"))

    (define groovy-dollar-slashy-close-regex
      (rx "/$"))

    (define groovy-postfix-operator-regex
      (rx (or "++" "--")))

    ;; `guard-ignore-scan-error` is `(ignore-errors (backward-list 1))`
    ;; from the C's `${}` matcher: Emacs's `ignore-errors` catches any
    ;; error; here a `scan-error` is caught, which is the one
    ;; `backward-list` raises.
    (define (guard-ignore-scan-error thunk)
      (guard (e ((scan-error? e) #f))
        (thunk)))

    (define (groovy--travel-parameterized-types)
      ;; "Pass over <Foo<Bar>> when searching declarations."
      (let ((count 1)
            (found #t))
        (let loop ()
          (when (and (> count 0) found)
            (set! found (re-search-forward (rx (or ">" "<")) (line-end-position) #t))
            (when found
              (set! count (if (equal? (match-string 0) ">")
                              (- count 1)
                              (+ count 1))))
            (loop)))))

    (define (groovy-variable-assignment-search limit)
      ;; "Highlight variable assignments up to LIMIT."
      (let ((*case-fold-search* #f))
        (let ((pos (point))
              (match (re-search-forward groovy-variable-assignment-regexp limit #t)))
          (when-e (and match (> match pos))
            (or (save-excursion
                  (save-match-data
                    (not (string-match
                          (rx-to-string
                           `(seq
                             (regexp ,groovy-annotation-regexp)
                             (* space)
                             (zero-or-one (seq "(" (* (not (any ")")))))
                             eol))
                          (buffer-substring-no-properties (line-beginning-position)
                                                          (match-beginning 0))))))
                (groovy-variable-assignment-search limit))))))

    (define (groovy-declaration-search limit)
      ;; "Find variable declarations up to LIMIT."
      (remove-text-properties (point)
                              (or limit (point-max))
                              '(groovy-special-variable nil
                                                        groovy-function-name nil))
      (let ((pos (point))
            (match (let ((*case-fold-search* #f))
                     (re-search-forward groovy-declaration-regexp limit #t))))
        (when-e (and match (> match pos))
          (or (and
               (not (groovy--in-string-p))
               (not (groovy--comment-p (point)))
               (let ((match-s (s-trim (match-string 0))))
                 (when (s-ends-with-p "<" match-s)
                   (groovy--travel-parameterized-types))
                 (let ((var-match
                        (re-search-forward
                         (rx-to-string `(seq point (* space)
                                             (regexp ,groovy-symbol-regexp)))
                         (line-end-position) #t)))
                   ;; matches initial regexp, now look at special cases
                   (if var-match
                       ;; if the var ends in a '(' it's a method name
                       (let ((md (match-data)))
                         (if (let ((*case-fold-search* #f))
                               (re-search-forward (rx point (* space) "(") #f #t))
                             (begin
                               (backward-char 1)
                               (set-match-data md)
                               (with-silent-modifications
                                 (put-text-property (match-beginning 1) (match-end 1)
                                                    'groovy-function-name (match-data)))
                               #f)
                             ;; else if declaration followed by ',' then
                             ;; it's of form `String a, b,c'
                             ;;
                             ;; Elisp's `if' takes several ELSE forms and
                             ;; the C's inner `if' uses that: the `unless'
                             ;; runs and then the `let' answers `t'.
                             (begin
                               (unless (or (s-starts-with-p "(" match-s)
                                           (s-starts-with-p "{" match-s)
                                           (s-starts-with-p "," match-s))

                                 (with-silent-modifications
                                   (let loop ()
                                     (when (re-search-forward
                                            (rx-to-string
                                             `(seq point (* space) "," (* space)
                                                   (regexp ,groovy-symbol-regexp)))
                                            limit #t)
                                       (put-text-property (match-beginning 1) (match-end 1)
                                                          'groovy-special-variable (match-data))
                                       (loop))))
                                 (set-match-data md))
                               #t)))
                       ;; didn't match regexp, check if it's of form
                       ;; `def (a, b, c) = [1, 2, 3]'
                       (when-e (re-search-forward
                              (rx-to-string
                               `(seq point (* space) "(" (* space)
                                     (group (+ (seq
                                                (regexp ,groovy-symbol-regexp)
                                                (* space)
                                                (opt ",")
                                                (* space))))
                                     (* space) ")" (* space) "="))
                              limit #t)
                         (let ((s (match-string 1))
                               (beg (match-beginning 0))
                               (end (match-end 0)))
                           (when-e (save-excursion
                                   (string-match
                                    (rx-to-string
                                     `(seq
                                       bol
                                       (+ (seq
                                           (* space)
                                           (regexp ,groovy-symbol-regexp)
                                           (* space)
                                           (or "," eol)))
                                       eol))
                                    s))
                             (with-silent-modifications
                               (save-excursion
                                 (goto-char beg)
                                 (let loop ()
                                   (when (re-search-forward groovy-symbol-regexp end #t)
                                     ;; mark list for later search
                                     (put-text-property (match-beginning 1) (match-end 1)
                                                        'groovy-special-variable
                                                        (match-data))
                                     (loop)))))
                             #f)))))))
              (groovy-declaration-search limit)))))

    ;; `groovy-font-lock-keywords` is here, below the search functions
    ;; its entries name as values - see the header.
    (define groovy-font-lock-keywords
      (list
       ;; Annotations are defined with the @interface, which is a
       ;; keyword, but it's nicer to use annotation highlighting.
       (cons "@interface" 'groovy-annotation-face)
       (cons (regexp-opt
              ;; http://docs.groovy-lang.org/latest/html/documentation/#_keywords
              '("as"
                "assert"
                "break"
                "case"
                "catch"
                "class"
                "const"
                "continue"
                "def"
                "default"
                "do"
                "else"
                "enum"
                "extends"
                "finally"
                "for"
                "goto"
                "if"
                "implements"
                "import"
                "in"
                "instanceof"
                "interface"
                "new"
                "package"
                "return"
                "super"
                "switch"
                "this"
                "throw"
                "throws"
                "trait"
                "try"
                "while"
                ;; Other strings that we want to highlight as keywords.
                "abstract"
                "final"
                "native"
                "private"
                "protected"
                "public"
                "static"
                "synchronized"
                )
              'symbols)
             'font-lock-keyword-face)
       ;; Highlight println as a keyword, but don't highlight foo.println.
       (cons (rx (or line-start space)
                 symbol-start (or "print" "printf" "println") symbol-end)
             'font-lock-keyword-face)
       ;; Constants
       (cons (regexp-opt '("false" "null" "true") 'symbols)
             'font-lock-constant-face)
       (cons (rx symbol-start "it" symbol-end)
             'font-lock-variable-name-face)
       ;; Annotations
       (cons groovy-annotation-regexp 'groovy-annotation-face)
       ;; highlight types 'Foo', 'char'
       (list groovy-type-regexp 1 'font-lock-type-face)
       ;; Highlight declarations of the form 'def foo' and
       ;; 'public void fooBar()'.
       (list groovy-declaration-search 1 'font-lock-variable-name-face)
       ;; Highlight $foo and $foo.bar string interpolation, but not
       ;; \$foo.
       (list
        (lambda (limit)
          (let ((pattern
                 (rx (not (any "\\"))
                     (group
                      "$" (+ (or (syntax word) (syntax symbol))) symbol-end
                      (? "." (+ (or (syntax word) (syntax symbol))) symbol-end))))
                (res #f)
                (match-data #f))
            (save-match-data
              ;; Search forward for $foo and terminate on the first
              ;; instance we find that's inside a string.
              (let loop ()
                (when (and (not res)
                           (re-search-forward pattern limit #t))
                  (let* ((string-delimiter-pos (nth 8 (syntax-ppss)))
                         (string-delimiter (char-after string-delimiter-pos)))
                    (when (and (groovy--in-string-p)
                               ;; Interpolation does not apply in
                               ;; single-quoted strings.
                               (not (eq? string-delimiter #\')))
                      (set! res (point))
                      ;; Set match data to the group we matched.
                      (set! match-data (list (match-beginning 1)
                                             (match-end 1)))))
                  (loop))))
            ;; Set match data and return point so we highlight this
            ;; instance.
            (when-e res
              (set-match-data match-data)
              res)))
        (list 0 'font-lock-variable-name-face #t))
       ;; Highlight ${foo} string interpolation.
       (list
        (lambda (limit)
          (let ((res #f) (start #f))
            (let loop ()
              (when (and (not res)
                         (search-forward "${" limit #t))
                (let* ((string-delimiter-pos (nth 8 (syntax-ppss)))
                       (string-delimiter (char-after string-delimiter-pos))
                       (escaped-p (and (not (eq? string-delimiter #\/))
                                       (groovy--preceded-by-odd-number-of-backslashes))))
                  (when (and (groovy--in-string-p)
                             ;; Interpolation does not apply in
                             ;; single-quoted strings.
                             (not (eq? string-delimiter #\'))
                             (not escaped-p))
                    (set! start (match-beginning 0))
                    (let ((restart-pos (match-end 0)))
                      ;; Search forward for the } that matches the
                      ;; opening {.
                      (let inner ()
                        (when (and (not res) (search-forward "}" limit #t))
                          (let ((end-pos (point)))
                            (save-excursion
                              (when (and (guard-ignore-scan-error
                                          (lambda () (backward-list 1)))
                                         (= start (- (point) 1)))
                                (set! res end-pos))))
                          (inner)))
                      (unless res
                        (goto-char restart-pos)))))
                (loop)))
            ;; Set match data and return point so we highlight this
            ;; instance.
            (when-e res
              (set-match-data (list start res))
              res)))
        (list 0 'font-lock-variable-name-face #t))
       (list groovy-special-variable-search 1 'font-lock-variable-name-face)
       (list groovy-function-name-search 1 'font-lock-function-name-face)))

    (define (groovy-stringify-triple-quote)
      ;; "Put `syntax-table' property on triple-quoted strings."
      ;; This applies to both ''' and """
      (let* ((delim-end-pos (point))
             (delim-start-pos (- delim-end-pos 3))
             (ppss (begin
                     (backward-char 3)
                     (let ((s (syntax-ppss)))
                       (forward-char 3)
                       s)))
             (in-comment (nth 4 ppss))
             (string-start-pos (nth 8 ppss)))
        (unless in-comment
          (if string-start-pos
              (let ((open-delimiter (char-after string-start-pos))
                    (current-delimiter (char-after delim-start-pos)))
                ;; Ensure that we're closing with the same triple-quote
                ;; type as we opened with, because '''""""''' is a legal
                ;; string literal.
                (when (equal? open-delimiter current-delimiter)
                  ;; We're in a string, so this must be the closing
                  ;; triple-quote.  Put | on the last ' or " character.
                  (put-text-property (1- delim-end-pos) delim-end-pos
                                     'syntax-table (string-to-syntax "|"))))
              ;; We're not in a string, so this is the opening
              ;; triple-quote.  Put | on the first ' or " character.
              (put-text-property delim-start-pos (1+ delim-start-pos)
                                 'syntax-table (string-to-syntax "|"))))))

    (define (groovy--comment-p pos)
      ;; "Return t if POS is in a comment."
      (save-excursion
        (nth 4 (syntax-ppss pos))))

    (define (groovy-stringify-slashy-string)
      ;; "Put `syntax-table' property on slashy-quoted strings (strings
      ;; of the form /foo/)."
      (let* ((final-pos (point))
             ;; We matched two characters starting with "/", e.g. "/x".
             ;; Point is currently after the "x".  Calculate the position
             ;; just after the "/".
             (slash-pos (1- (point)))
             (prev-char (char-before (- slash-pos 1)))
             (prev-prev-char (char-before (- slash-pos 2)))
             ;; Look at the previous char: // is a comment, not an empty
             ;; slashy-string.  /foo\// does not contain a comment
             ;; though.
             (singleline-comment (and (eq? prev-char #\/)
                                      (not (eq? prev-prev-char #\\))))
             ;; Look at this syntax on the previous char: if we're on a
             ;; /* or a */ this isn't a slashy-string.
             (multiline-comment (save-excursion
                                  (goto-char (1- slash-pos))
                                  (groovy--comment-p (point))))
             (string-open-pos (nth 8 (syntax-ppss slash-pos))))

        (unless (or singleline-comment multiline-comment)
          (if string-open-pos
              ;; If we're in a string, that was opened with /, then this
              ;; is the closing /.  This prevents confusion with """
              ;; /* """
              (if (eq? (char-after string-open-pos) #\/)
                  (put-text-property (1- slash-pos) slash-pos
                                     'syntax-table (string-to-syntax "|"))
                  ;; We're in a string, but not a slashy string.
                  ;; Ensure we don't put point beyond the /, to avoid
                  ;; confusion with """foo/""".
                  (set! final-pos (1- final-pos)))
              ;; We're not in a string, so this is the opening / or
              ;; division.
              (let ((str (buffer-substring-no-properties (line-beginning-position)
                                                         slash-pos)))
                ;; Test if an operator precedes this slash.  if so,
                ;; slashy-string, otherwise it's division so ignore.
                (when (string-match
                       (rx
                        (or bol
                            (or "+" "-" "=" "+=" "-=" "==" "!="
                                "<" "<=" ">" ">=" "&&" "||" "?" "?:" ":"
                                "=~" "==~" "<=>" "(" "~" ","))
                        (0+ whitespace)
                        "/"
                        eol)
                       str)
                  (put-text-property (1- slash-pos) slash-pos
                                     'syntax-table (string-to-syntax "|"))))))
        (goto-char final-pos)))

    (define (groovy-stringify-dollar-slashy-open)
      ;; "Put `syntax-table' property on the opening $/ of
      ;; dollar-slashy-quoted strings."
      (let ((delimiter-end-pos (point)))
        (if (or (groovy--comment-p delimiter-end-pos) (groovy--in-string-p))
            ;; if not $/ open comment then go back a char so we can test
            ;; if it's a closing slashy-string /
            (backward-char 1)
            ;; Mark the $ in $/ as a generic string delimiter.
            (put-text-property (- delimiter-end-pos 2) (- delimiter-end-pos 1)
                               'syntax-table (string-to-syntax "|")))))

    (define (groovy-stringify-dollar-slashy-close)
      ;; "Put `syntax-table' property on the closing /$ of
      ;; dollar-slashy-quoted strings."
      (let* ((delimiter-end-pos (point))
             ;; We can't use `syntax-ppss' here as the state may not be
             ;; set yet.  Using `parse-partial-sexp' ensures that the
             ;; highlighting is correct even when the mode is started
             ;; initially.
             (ppss (parse-partial-sexp (point-min) delimiter-end-pos))
             (in-string (nth 3 ppss))
             (string-start-pos (nth 8 ppss)))
        (cond
         ((groovy--comment-p delimiter-end-pos)
          ;; Do nothing inside comments.
          #f)
         ((not in-string)
          ;; If we're not in a string, then /$ is the start of a normal
          ;; slashy-string, e.g. /$ foo/.
          ;;
          ;; Note that both `groovy-stringify-dollar-slashy-close' and
          ;; `groovy-stringify-slashy-string' expect to be two
          ;; characters after the /, so we don't need to move point
          ;; before calling.
          (groovy-stringify-slashy-string))
         ((looking-back (rx "$/$") 3)
          ;; Ignore $/$ as it's escaped and not a /$ close delimiter.
          #f)
         (else
          ;; Otherwise, we're in a string.
          (when (eq? (char-after string-start-pos) #\$)
            ;; If this string opened with $, this is a string of the
            ;; form $/foo/$.  Mark the final $ as a generic string
            ;; delimiter.
            (put-text-property (- delimiter-end-pos 1) delimiter-end-pos
                               'syntax-table (string-to-syntax "|")))))))

    (define groovy-syntax-propertize-function
      ;; Emacs's `syntax-propertize-rules` is a macro over the same
      ;; rules; here the rules are data (see the header and
      ;; `search.scm`'s note).
      ;;
      ;; WARNING: These are a pain to refactor.  Emacs tries each one of
      ;; these regexps in order.  It resumes parsing from wherever point
      ;; is left at the end of the function call.
      ;;
      ;; As a result, it's important that these functions move point
      ;; backwards if they may have moved over another delimiter (e.g.
      ;; /$ and /).  However, they must all move point by a non-zero
      ;; amount, or you get an infinite loop during fontification.
      (syntax-propertize-rules
       (list
        ;; Treat the shebang as a comment.  We reuse comment sequence b
        ;; (which is the // comment) so Emacs treats \n as the end of
        ;; the comment.
        (list groovy-shebang-regex (list 0 "< b"))
        (list groovy-triple-double-quoted-string-regex
              (list 0 (list 'ignore (lambda () (groovy-stringify-triple-quote)))))
        (list groovy-triple-single-quoted-string-regex
              (list 0 (list 'ignore (lambda () (groovy-stringify-triple-quote)))))
        ;; http://groovy-lang.org/syntax.html#_dollar_slashy_string
        (list groovy-dollar-slashy-open-regex
              (list 0 (list 'ignore (lambda () (groovy-stringify-dollar-slashy-open)))))
        (list groovy-dollar-slashy-close-regex
              (list 0 (list 'ignore (lambda () (groovy-stringify-dollar-slashy-close)))))
        ;; http://groovy-lang.org/syntax.html#_slashy_string
        (list groovy-slashy-open-regex
              (list 0 (list 'ignore (lambda () (groovy-stringify-slashy-string))))))))

    (defgroup groovy ()
      "A Groovy major mode."
      :group 'languages)

    (define-custom *groovy-indent-offset* 4
      "Indentation amount for Groovy."
      :type 'natnum
      :safe natnump
      :group 'groovy)

    (define-custom *groovy-highlight-assignments* #f
      "Highlight variable assignments after declaration."
      :type 'boolean
      :group 'groovy)

    (define groovy-annotation-face 'groovy-annotation-face)
    (defface 'groovy-annotation-face
      '((default :inherit font-lock-constant-face))
      ;; Emacs's `:group 'groovy` argument is not carried: this tree's
      ;; `defface` is the function Emacs's macro expands to and takes
      ;; exactly (FACE SPEC DOCSTRING).
      "Face for highlighting annotations in Groovy mode.")

    (define groovy-expression-end-regexp
      (rx-to-string
       `(or symbol-end
            space
            (syntax string-quote)
            (syntax string-delimiter)
            (syntax close-parenthesis)
            (regexp ,groovy-postfix-operator-regex))))

    (define (groovy--ends-with-token-p token-list str)
      ;; "Return t if STR ends with one of the tokens in TOKEN-LIST."
      (string-match-p
       (rx-to-string
        `(seq
          (regexp ,groovy-expression-end-regexp)
          (or ,@token-list)
          (0+ space)
          line-end))
       str))

    (define (groovy--ends-with-infix-p str)
      ;; "Does STR end with an infix operator?"
      (groovy--ends-with-token-p
       ;; http://docs.groovy-lang.org/next/html/documentation/core-operators.html
       '("+" "-" "*" "/" "%" "**"
         "=" "+=" "-=" "*=" "/=" "%=" "**="
         "==" "!=" "<" "<=" ">" ">=" "<<=" ">>=" ">>>=" "&=" "^=" "|="
         "&&" "||"
         "&" "|" "^" "<<" "<<<" ">>" ">>>"
         "?" "?:"
         ;; Kludge: require a space before :.  This enables us to
         ;; distinguish labels from ternary calls.  Strictly speaking,
         ;; Groovy does not require a space before :, instead it seems
         ;; to look for a preceding ?.
         " :"
         "=~" "==~"
         "<=>" "<>"
         "in" "as")
       str))

    (define (groovy--ends-with-comma-p str)
      ;; "Does STR end with a comma?"
      (groovy--ends-with-token-p
       '(",")
       str))

    (define (groovy--current-line)
      ;; "The current line enclosing point."
      (buffer-substring-no-properties
       (line-beginning-position) (line-end-position)))

    (define (groovy--enclosing-blocks)
      ;; "Return a list of the block keywords that enclose point. ...
      ;; Then this function returns (\"def\" \"if\" \"switch\")."
      (let ((enclosing-paren-pos #f) (blocks '()))
        (save-excursion
          (set! enclosing-paren-pos (nth 1 (syntax-ppss)))
          (let loop ()
            (when enclosing-paren-pos
              (goto-char enclosing-paren-pos)
              (let* ((line (s-trim (groovy--current-line)))
                     (symbols (s-split (rx symbol-end) line #t))
                     (symbol (car-safe symbols)))
                (set! blocks (cons symbol blocks)))
              (set! enclosing-paren-pos (nth 1 (syntax-ppss)))
              (loop))))
        blocks))

    (define groovy--case-regexp
      (rx (or
           (seq "case" symbol-end (+ any))
           (seq "default" symbol-end))
          ":"))

    (define (groovy--remove-comments src)
      ;; "Remove all comments from a string SRC of groovy source code."
      (->> src
           (replace-regexp-in-string (rx "/*" (*? anything) "*/") "")
           (replace-regexp-in-string (rx "//" (* not-newline)) "")))

    (define (groovy--effective-paren-depth pos)
      ;; "Return the indentation paren depth of position POS.  Only one
      ;; opening paren per source code line is counted."
      (let ((paren-depth 0)
            (syntax (syntax-ppss pos))
            (current-line (line-number-at-pos pos)))
        (save-excursion
          ;; Keep going whilst we're inside parens.
          (let loop ()
            (when (> (nth 0 syntax) 0)
              ;; Go to the most recent enclosing open paren.
              (goto-char (nth 1 syntax))
              ;; Count this paren, but only if it was on another line.
              (let ((new-line (line-number-at-pos (point))))
                (unless (= new-line current-line)
                  (set! paren-depth (+ paren-depth 1))
                  (set! current-line new-line)))
              (set! syntax (syntax-ppss (point)))
              (loop))))
        paren-depth))

    (define (groovy--extract-line-without-comments)
      ;; "Extracts the part of the current line that is not a comment."
      (let ((code-text #f)
            (start-pos (line-beginning-position))
            (end-pos (line-end-position)))
        ;; Unless this line is already inside a multiline comment, use
        ;; parse-partial-sexp to get the part of the line not a part of
        ;; a comment.
        (unless (groovy--comment-p start-pos)
          (save-excursion
            (parse-partial-sexp start-pos end-pos #f #f #f #t)
            (set! code-text (buffer-substring start-pos (point)))

            ;; Unless we went all the way to the end of the line, we
            ;; encountered a comment delimiter //, /* or #.  Remove this
            ;; delimiter.
            (unless (= (point) end-pos)
              (let ((delims '("//" "/*" "#")))
                (set! code-text (replace-regexp-in-string
                                 (rx-to-string `(seq (or ,@delims) line-end))
                                 ""
                                 code-text))))))

        ;; Return the part of the line that isn't a comment (may be nil).
        code-text))

    (define (groovy--backwards-to-prev-code-line)
      ;; "Move point to the previous non-comment line, and return its
      ;; contents."
      (catch 'done
        (lambda ()
          (let ((code-text #f))
            (let loop ()
              ;; Move backwards one line, or throw 'done if we're at the
              ;; beginning of the buffer.
              (unless (zero? (forward-line -1))
                (throw 'done #f))

              ;; Get the part of the line that isn't in a comment.  If
              ;; this isn't just white space, return it as a code line.
              (set! code-text (groovy--extract-line-without-comments))
              (unless (s-blank-str-p code-text)
                (throw 'done code-text))
              (loop))))
        ;; Guile's `catch' requires a handler, and it is called with
        ;; `(KEY . THROWN-VALUES)` - a one-argument handler here raised
        ;; "Wrong number of arguments" on the first `(throw 'done ...)`.
        ;; Emacs's answers the THROW's value (or the body's last value -
        ;; which `groovy--backwards-to-prev-code-line` never reaches, its
        ;; body always throwing), so the value is the handler's second
        ;; argument.
        (lambda (key value) value)))

    (define (groovy--line-ends-with-incomplete-block-statement-p)
      ;; "Return t if the current line ends with an incomplete block
      ;; statement, without an open curly brace."
      ;;
      ;; **Its value is a *test*** (the indent loop's `and` reads it), so
      ;; every no-answer path is `#f` - `when-e`/`unless-e`, not
      ;; `when`/`unless`. An unspecified value is true and every line
      ;; was "incomplete", which indented every following line one
      ;; level deeper than Emacs.
      ;;
      ;; The C's `(condition-case nil (progn (backward-sexp) t)
      ;; (scan-error nil))` answers `t` on success - the `t` is the whole
      ;; point, because `backward-sexp` itself answers nil. It is the
      ;; thunk's last form here.
      (unless-e (groovy--in-string-p)
        (save-excursion
          (end-of-line)
          ;; Search backwards until we are no longer in a comment.
          (let loop ()
            (when (and (not (bolp)) (groovy--comment-p (point)))
              (re-search-backward "/[/*]" (line-beginning-position) #t)
              (loop)))
          (unless-e (groovy--comment-p (point))
            (skip-chars-backward (rx blank))
            ;; We should be at the end of the actual code line.  We are
            ;; looking for a line that ends with either if|while|for
            ;; followed by (condition), or a lone else.
            (if (eq? (char-before) #\))
                (when-e (guard-ignore-scan-error
                         (lambda () (backward-sexp) #t))
                  (skip-chars-backward (rx blank))
                  (string-match (rx symbol-start (group (or "if" "for" "while"))
                                    line-end)
                                (buffer-substring-no-properties
                                 (line-beginning-position) (point))))
                (string-match (rx symbol-start "else" line-end)
                              (buffer-substring-no-properties
                               (line-beginning-position) (point))))))))

    (define (groovy--trim-current-line)
      ;; "Return the current code line trimmed and without comments."
      (s-trim (groovy--remove-comments (groovy--current-line))))

    (define-command (groovy-indent-line)
      "Indent the current line according to the number of parentheses."
      (interactive)
      (let* ((point-offset (- (current-column) (current-indentation)))
             (syntax-bol (syntax-ppss (line-beginning-position)))
             (multiline-string-p (nth 3 syntax-bol))
             (multiline-comment-p (nth 4 syntax-bol))
             (current-paren-depth (groovy--effective-paren-depth
                                   (line-beginning-position)))
             (current-paren-pos (nth 1 syntax-bol))
             ;; **`when-e`, not `when`**: Emacs's `when` answers nil
             ;; when it does not fire, and `text-after-paren` is handed
             ;; to `s-blank-str-p` - an unspecified value is true and
             ;; reached `(string=? "" #<unspecified>)`.
             (current-paren-character
              (when-e (nth 1 syntax-bol) (char-after (nth 1 syntax-bol))))
             (text-after-paren
              (when-e current-paren-pos
                (save-excursion
                  (goto-char current-paren-pos)
                  (s-trim
                   (groovy--remove-comments
                    (buffer-substring
                     (1+ current-paren-pos)
                     (line-end-position)))))))
             (current-line (s-trim (groovy--current-line)))
             (has-closing-paren #f))
        ;; If this line starts with a closing paren, unindent by one
        ;; level.
        ;;   if {
        ;;   } <- this should not be indented.
        (when (or (s-starts-with-p "}" current-line)
                  (s-starts-with-p ")" current-line)
                  (s-starts-with-p "]" current-line))
          (set! has-closing-paren #t)
          (set! current-paren-depth (1- current-paren-depth)))

        ;; `current-paren-depth' should never be negative, unless the
        ;; code contains unbalanced parens.  Ensure we handle that
        ;; robustly.
        (when (< current-paren-depth 0)
          (set! current-paren-depth 0))

        (cond
         ;; Don't try to indent the line if we're in a multiline
         ;; string.
         (multiline-string-p 'noindent)
         ;; Ensure we indent
         ;; /*
         ;;  * foo
         ;;  */
         ;;  correctly.
         (multiline-comment-p
          (indent-line-to (1+ (* (*groovy-indent-offset*) current-paren-depth))))

         ;; Ensure we indent
         ;; def x = [1,
         ;;          2,
         ;; ]
         ;; correctly.
         ((and (not (s-blank-str-p text-after-paren))
               (not has-closing-paren)
               ;; ensure we don't indent closures
               (not (string-match (rx "->" eol) text-after-paren)))
          (let ((open-paren-column #f))
            (save-excursion
              (goto-char current-paren-pos)
              (set! open-paren-column (current-column)))
            (indent-line-to (1+ open-paren-column))))

         ;; Indent according to the number of parens.
         (else
          (let ((indent-level current-paren-depth))
            ;; If the previous line ended with an arithmetic operator
            ;; like `foo +`, then this line should be indented one more
            ;; level.
            (save-excursion
              (let* ((prev-line (groovy--backwards-to-prev-code-line))
                     (line-end (line-end-position))
                     ;; Check if the last thing is a slashy-string end,
                     ;; so we distinguish a string `/foo bar/` from
                     ;; arithmetic `x /`.
                     (end-slashy-string (and
                                         prev-line
                                         (eq? (char-before line-end) #\/)
                                         (groovy--in-string-at-p (- line-end 1)))))
                (when (and
                       prev-line
                       (not end-slashy-string)
                       (not (s-matches-p groovy--case-regexp prev-line))
                       (or (groovy--ends-with-infix-p prev-line)
                           (and (groovy--ends-with-comma-p prev-line)
                                (not (memq current-paren-character (list #\[ #\()))
                                (not has-closing-paren))))
                  (set! indent-level (+ indent-level 1)))))

            ;; If the previous lines are block statements (if, for,
            ;; while, else) without the optional curly brace and without
            ;; a body, then indent for each block.
            (save-excursion
              (let ((next-line #f) (line-after #f))
                (let loop ()
                  (when
                      (and
                       (let ((l (groovy--trim-current-line)))
                         (set! line-after l)
                         l)
                       (groovy--backwards-to-prev-code-line)

                       ;; Handle the special case of a chain of if-else
                       ;; statements, e.g.
                       ;;   if (x) foo()
                       ;;   else if (y) bar()
                       ;;   else baz()
                       (begin
                         (let inner ()
                           (let ((cur-line (groovy--trim-current-line)))
                             (when (and (s-starts-with-p "else" line-after)
                                        (string-match
                                         (rx line-start (optional "else" (+ blank))
                                             "if" symbol-end)
                                         cur-line)
                                        (groovy--backwards-to-prev-code-line)
                                        (begin (set! line-after cur-line) #t))
                               (inner))))
                         #t)

                       (groovy--line-ends-with-incomplete-block-statement-p))
                    (set! indent-level (+ indent-level 1))
                    (loop)))))

            ;; If this line is .methodCall() then we should indent one
            ;; more level.
            (when (s-starts-with-p "." current-line)
              (set! indent-level (+ indent-level 1)))

            ;; If we're inside a switch statement, we should indent
            ;; another level after case labels, e.g.
            ;; case foo:
            ;;     bar // <- extra indent
            (let ((blocks (groovy--enclosing-blocks))
                  (switch-count 0))
              (for-each (lambda (block-symbol)
                          (when (equal? block-symbol "switch")
                            (set! switch-count (+ switch-count 1)))
                          ;; Ensure we indent closures by one extra
                          ;; level.
                          ;;
                          ;; [1, 2, 3]
                          ;;     .findAll { // <- indented
                          (when (s-starts-with-p "." block-symbol)
                            (set! indent-level (+ indent-level 1))))
                        blocks)

              (when (> switch-count 0)
                (set! indent-level (+ indent-level switch-count))
                ;; The `case foo:' line should be indented less than
                ;; the body.
                (when (s-matches-p groovy--case-regexp current-line)
                  (set! indent-level (1- indent-level)))
                ;; The extra indent does not apply to the } closing the
                ;; switch block.
                (when (and
                       (equal? (car (last blocks)) "switch")
                       (equal? current-line "}"))
                  (set! indent-level (1- indent-level)))))

            (indent-line-to (* (*groovy-indent-offset*) indent-level)))))
        ;; Point is now at the beginning of indentation, restore it to
        ;; its original position (relative to indentation).
        (when (>= point-offset 0)
          (move-to-column (+ (current-indentation) point-offset)))))

    (define groovy-mode-map (make-sparse-keymap))
    ;; **The hook is a parameter**, the tree's representation for a hook
    ;; a user or another library adds to with `add-hook` (`add-hook`
    ;; takes the hook object).  The mode gets its value through the
    ;; getter, as `compilation-mode` does with
    ;; `(*compilation-mode-hook*)` - a bare parameter passed to
    ;; `run-mode-hooks` would be called as a function and its list
    ;; discarded.  inf-groovy's `eval-after-load` hook addition is the
    ;; caller that needs this.
    (define *groovy-mode-hook* (make-parameter '()))

    (define-derived-mode (groovy-mode groovy-parent-mode "Groovy"
                                      groovy-mode-map (*groovy-mode-hook*)
                                      groovy-mode-syntax-table)
      "Major mode for editing Groovy code.

The hook `groovy-mode-hook' is run with no args at mode
initialization.

Key bindings:
\\{groovy-mode-map}"
      ;; if `groovy-highlight-assignments' add to keyword search.
      (when (*groovy-highlight-assignments*)
        ;; Emacs's `(add-to-list 'groovy-font-lock-keywords ENTRY t)':
        ;; the variable is a plain list, so the append-and-dedupe is
        ;; written out.
        ;; Emacs quotes the *symbol* and the obarray resolves it when
        ;; font-lock runs the keyword; a keyword list here holds the
        ;; procedure, so the entry holds the procedure itself. Quoted,
        ;; font-lock applied the symbol: "Wrong type to apply:
        ;; groovy-variable-assignment-search".
        (let ((entry (list groovy-variable-assignment-search 1
                           'font-lock-variable-name-face)))
          (unless (member entry groovy-font-lock-keywords)
            (set! groovy-font-lock-keywords
                  (append groovy-font-lock-keywords (list entry))))))
      (set!font-lock-defaults!
       (list (list 'groovy-font-lock-keywords)))

      ;; set electric characters
      ;; `(setq-local electric-indent-chars (append "{}():;,[]"
      ;; electric-indent-chars))' (`groovy-mode.el:1006'). Emacs's
      ;; `append` of a string and a list yields the character codes, and
      ;; the tree's buffer-local setter is what `setq-local` is here.
      (set!electric-indent-chars
       (append (map char->integer (string->list "{}():;,[]"))
               (electric-indent-chars)))

      (setq-local 'syntax-propertize-function
                  groovy-syntax-propertize-function)
      ;; `(setq imenu-generic-expression groovy-imenu-regexp)'
      ;; (`groovy-mode.el:1010').
      (set!imenu-generic-expression groovy-imenu-regexp)
      (setq-local 'indent-line-function groovy-indent-line)
      (setq-local 'comment-start "//")
      (setq-local 'comment-start-skip
                  (rx (or "//" "/*" "/**" "/**@") (zero-or-more space))))

    ;; A trailing expression: `define-derived-mode` expands to
    ;; definitions, and a body (here the library's `begin`) must end
    ;; with an expression.
    #t

    ))
