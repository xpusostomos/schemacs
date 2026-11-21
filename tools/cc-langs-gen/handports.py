C_FILTER_OPS = r'''
    ;;------------------------------------------------------------------
    ;; `c-filter-ops' (`cc-langs.el:214')
    ;;------------------------------------------------------------------
    ;; "Extract a subset of the operators in the list OPS in a DWIM:ey
    ;; way.  The return value is a plain list of operators". Emacs's
    ;; `setq' of a lambda is written as a second binding; the
    ;; `c-with-syntax-table' takes a thunk here.
    (define (c-filter-ops ops opgroup-filter op-filter . rest)
      (let ((xlate (and (pair? rest) (car rest))))
        ;; Emacs's nil is both spellings here; `c-filter-ops' is called
        ;; with a constant that a language does not set.
        (unless ops (set! ops '()))
        (unless (list? (if (pair? ops) (car ops) '()))
          (set! ops (list ops)))
        (cond ((eq? opgroup-filter #t)
               (set! opgroup-filter (lambda (opgroup) #t)))
              ((not (procedure? opgroup-filter))
               (let ((wanted opgroup-filter))
                 (set! opgroup-filter
                       (lambda (opgroup) (memq opgroup wanted))))))
        (cond ((eq? op-filter #t)
               (set! op-filter (lambda (op) #t)))
              ((string? op-filter)
               (let ((regexp op-filter))
                 (set! op-filter
                       (lambda (op) (string-match regexp op))))))
        (unless xlate
          (set! xlate identity))
        (c-with-syntax-table
         (c-lang-const c-mode-syntax-table)
         (lambda ()
           (c--delete-duplicates
            (c--mapcan
             (lambda (opgroup)
               ;; Emacs's `(symbolp (car opgroup))' is *true for nil* -
               ;; nil is a symbol there - so a group whose head is nil
               ;; (`(cons nil c-after-id-concat-ops)`) is a group like
               ;; any other. `#f` is this tree's nil.
               (if (if (or (symbol? (car opgroup)) (not (car opgroup)))
                       (if (funcall opgroup-filter (car opgroup))
                           (begin (set! opgroup (cdr opgroup)) #t)
                           #f)
                       #t)
                   (c--mapcan
                    (lambda (op)
                      (if (funcall op-filter op)
                          ;; Emacs's `(if (listp res) res (list res))':
                          ;; a nil result is spliced as nothing, which is
                          ;; `#f` here.
                          (let ((res (funcall xlate op)))
                            (cond ((list? res) res)
                                  ((not res) '())
                                  (else (list res))))
                          #f))
                    opgroup)
                   #f))
             ops)
            ':test equal?)))))
'''

C_KWDS = r'''
    ;;------------------------------------------------------------------
    ;; `c-kwds-lang-consts' (`cc-langs.el:3581')
    ;;------------------------------------------------------------------
    ;; "List of all the language constants that contain keyword lists."
    ;; Emacs walks the `c-lang-constants' obarray with `mapatoms'; the
    ;; registry answers its names instead, *sorted by name* where
    ;; `mapatoms' has obarray order - a named departure, and the only
    ;; order-sensitive one: the membership is what reaches the keyword
    ;; lists, and every regexp built from them is `regexp-opt''s order.
    ;; Like Emacs, this is computed where it stands: a `*-kwds' constant
    ;; defined later in the file (there is one, `c-pre-id-bracelist-kwds')
    ;; is not in it, and that was measured on Emacs 31.1.
    (define c-kwds-lang-consts
      (let loop ((names (c-lang-constant-names)) (out '()))
        (cond ((null? names) (reverse out))
              ((string-suffix-p "-kwds" (symbol->string (car names)))
               (loop (cdr names) (cons (car names) out)))
              (else (loop (cdr names) out)))))
'''

NO_PARENS = r'''
(c-lang-defconst c-make-no-parens-syntax-table
  ;; "A variant of the standard syntax table which is used to find
  ;; matching \"<\"s and \">\"s which have been marked as parens using
  ;; syntax table properties. ... This variable is nil for languages
  ;; which don't have template stuff."
  ;;
  ;; Emacs's value is a quasiquoted lambda with the syntax-table maker
  ;; spliced in by `funcall' and `eval'; a procedure is a value here, so
  ;; the maker is simply closed over.
  t
  (if (c-lang-const c-recognize-<>-arglists)
         (let ((make (c-lang-const c-make-mode-syntax-table)))
           (lambda ()
             (let ((table (make)))
               (modify-syntax-entry #\( "." table)
               (modify-syntax-entry #\) "." table)
               (modify-syntax-entry #\[ "." table)
               (modify-syntax-entry #\] "." table)
               (modify-syntax-entry #\{ "." table)
               (modify-syntax-entry #\} "." table)
               table)))
         #f))
(c-lang-defvar c-no-parens-syntax-table
  ;; Emacs: "(and (c-lang-const c-make-no-parens-syntax-table)
  ;; (funcall (eval (c-lang-const ...))))" - the `eval' is for the
  ;; byte-compiled quasiquote's benefit and has no counterpart.
  (let ((make (c-lang-const c-make-no-parens-syntax-table)))
    (if make (make) #f)))
'''

NONSYMBOL = r'''
(c-lang-defconst c-nonsymbol-token-char-list
  ;; "List containing all chars not in the word, symbol or syntactically
  ;; irrelevant syntax classes, i.e. all punctuation, parenthesis and
  ;; string delimiter chars."
  ;;
  ;; Emacs's `char' is an integer, so `char-syntax' takes it directly and
  ;; `c-int-to-char' wraps it for the list; here the character functions
  ;; take characters, so the conversion moves to those calls.
  t
  (c-with-syntax-table
      (c-lang-const c-mode-syntax-table)
      (lambda ()
        ;; "Only go through the chars in the printable ASCII range."
        (let ((list '()) (char 32))
          (let loop ()
            (if (< char 127)
                (begin
                  ;; Emacs's `'(?w ?_ ?< ?> ?\ )' is a *literal* here
                  ;; too: `list' is a bound variable in this `let' and a
                  ;; Lisp-1 would call it (the tree's oldest trap).
                  (or (memv (char-syntax (c-int-to-char char))
                            '(#\w #\_ #\< #\> #\space))
                      (set! list (cons (c-int-to-char char) list)))
                  (set! char (+ char 1))
                  (loop))
                #f))
          list))))
(c-lang-defvar c-nonsymbol-token-char-list
  (c-lang-const c-nonsymbol-token-char-list))
'''

ENUM = r'''
(c-lang-defconst c-enum-list-key
  ;; "Regexp matching the start of declarations where the following block
  ;; is a brace list."
  ;;
  ;; The `condition-case' is a compatibility fallback for derived modes
  ;; still setting the pre-2024 name; `guard' catches this tree's error,
  ;; which is what the "got no prior value" failure is.
  t
  (let ((liszt (guard (e (#t (c-lang-const c-enum-list-kwds)))
                  (c-lang-const c-brace-list-decl-kwds))))
    (c-make-keywords-re #t liszt)))
(c-lang-defvar c-enum-list-key (c-lang-const c-enum-list-key))
'''

AFTER_ENUM = r'''
(c-lang-defconst c-after-enum-list-key
  ;; "Regexp matching keywords that can fall between an enum-list keyword
  ;; and the associated brace list."
  t
  (let ((liszt (guard (e (#t (c-lang-const c-after-enum-list-kwds)))
                  (c-lang-const c-after-brace-list-decl-kwds))))
    (c-make-keywords-re #t liszt)))
(c-lang-defvar c-after-enum-list-key (c-lang-const c-after-enum-list-key))
'''

KW_OBA = r'''
;;; `c-lang-defvar c-keywords-obarray' is not carried: it is an Emacs
;;; *obarray* whose symbols' property lists say which `*-kwds' lists each
;;; keyword is on, and this tree has no obarray (the command table and
;;; the coding-system table are the pattern - an index kept beside the
;;; data). Its readers are `c-keyword-sym' and `c-keyword-member' in
;;; cc-engine, and they are deferred until cc-engine is ported, when the
;;; same membership information `c-keyword-member-alist' already carries
;;; can be indexed a second way.
'''

KEYWORDS = r'''
(c-lang-defconst c-keywords
  ;; "All keywords as a list."
  ;;
  ;; `(or (c-lang-const ,k) '())': Emacs's `append' ignores a nil
  ;; argument; a constant here may be `#f', which `append' would refuse.
  t
  (c--delete-duplicates
   (c-lang-defconst-eval-immediately
    `(append ,@(or (mapcar (lambda (kwds-lang-const)
                             `(or (c-lang-const ,kwds-lang-const) '()))
                          c-kwds-lang-consts)
                   '())
             (quote ())))
   ':test string-equal))
'''

STMT_BOUNDARY = r'''
;; Emacs's `(append (substring STR 1) nil)' - `append' over a *string*
;; spreads its characters, as Emacs's `append` does and Scheme's does
;; not. The characters are this port's character objects (the consumers
;; compare them with `char-after'), where Emacs holds code points.
(c-lang-defconst c-stmt-boundary-skip-list
  t
  (string->list (or (%substring (c-lang-const c-stmt-boundary-skip-chars) 1)
                    "")))
(c-lang-defvar c-stmt-boundary-skip-list
  (c-lang-const c-stmt-boundary-skip-list))

(c-lang-defconst c-stmt-boundary-skip-list-with-comma
  t
  (string->list (or (%substring (c-lang-const c-stmt-boundary-skip-chars-with-comma)
                                1)
                    "")))
(c-lang-defvar c-stmt-boundary-skip-list-with-comma
  (c-lang-const c-stmt-boundary-skip-list-with-comma))
'''

MEMBER_ALIST = r'''
(c-lang-defconst c-keyword-member-alist
  ;; "An alist with all the keywords in the cars. The cdr for each
  ;; keyword is a list of the symbols for the `*-kwds' lists that
  ;; contains it."
  ;;
  ;; Emacs's imperative loop with its `setcdr'; ported step for step.
  t
  (let ((kwd-list-alist
            (c-lang-defconst-eval-immediately
             `(list ,@(mapcar (lambda (kwds-lang-const)
                                `(cons ',kwds-lang-const
                                       (or (c-lang-const ,kwds-lang-const)
                                           '())))
                              c-kwds-lang-consts))))
           (result-alist '()))
       (let loop ((rest kwd-list-alist))
         (if (null? rest)
             result-alist
             (begin
               (let ((lang-const (caar rest))
                     (kwd-list (cdar rest)))
                 (let inner ((ks kwd-list))
                   (if (null? ks)
                       #f
                       (begin
                         (let* ((kwd (car ks))
                                (elem (assoc kwd result-alist)))
                           (unless elem
                             (set! elem (list kwd))
                             (set! result-alist (cons elem result-alist)))
                           (unless (memq lang-const (cdr elem))
                             (set-cdr! elem (cons lang-const (cdr elem)))))
                         (inner (cdr ks))))))
               (loop (cdr rest)))))))
'''

BLOCK_PREFIX = r'''
(c-lang-defconst c-block-prefix-disallowed-chars
  "List of characters which are disallowed in a syntactic symbol
when placed directly after a brace list starter in a block prefix."
  ;; The default derivation, with the `xlate' lambda written out: it
  ;; collects the characters of OP that have punctuation or paren syntax
  ;; (Emacs's `c-int-to-char' is the identity; here `aref' answers a code
  ;; point and the char is what the list below holds).
  t
  (c--set-difference
      (c-lang-const c-nonsymbol-token-char-list)
      (c-filter-ops
       (append (or (c-lang-const c-identifier-ops) '())
               (list (cons #f (or (c-lang-const c-after-id-concat-ops)
                                  '()))))
       #t #t
       (lambda (op)
         (let ((pos 0) (res '()))
           (let loop ()
             (if (string-match "\\(\\s.\\|\\s(\\|\\s)\\)" op pos)
                 (begin
                   (set! res (cons (c-int-to-char (aref op (match-beginning 1)))
                                   res))
                   (set! pos (match-end 0))
                   (loop))
                 #f))
           res)))
      ':test equal?)
  t
  (if (c-lang-const c-opt-cpp-prefix)
         (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                            '(#\#))
         (c-lang-const c-block-prefix-disallowed-chars))
  (c++ objc idl)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\:))
  (c++ java)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\,))
  (java pike)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\( #\)))
  (c c++ objc)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\" #\')))
'''

KNOWN_TYPE = r'''
(c-lang-defvar c-known-type-key
  ;; "Regexp matching the known type identifiers."
  ;;
  ;; Emacs's `(boundp (c-mode-symbol "font-lock-extra-types"))' guard is
  ;; cc-vars' registration of the variable's reader (see cc-defs'
  ;; `c-register-emacs-variable-reader!'); the `mapcar'/`delq nil' pairs
  ;; are written as the two collection loops they are.
  (let* ((extra-types (c-mode-var "font-lock-extra-types"))
         (regexp-strings
          (let loop ((rest extra-types) (out '()))
            (cond ((null? rest) (reverse out))
                  ((and (stringp (car rest))
                        (string-match "[][.*+?^$\\\\]" (car rest)))
                   (loop (cdr rest) (cons (car rest) out)))
                  (else (loop (cdr rest) out)))))
         (plain-strings
          (let loop ((rest extra-types) (out '()))
            (cond ((null? rest) (reverse out))
                  ((and (stringp (car rest))
                        (not (string-match "[][.*+?^$\\\\]" (car rest))))
                   (loop (cdr rest) (cons (car rest) out)))
                  (else (loop (cdr rest) out))))))
    (concat "\\_<\\("
            (c-concat-separated
             (append (list (c-make-keywords-re #f
                             (append (c-lang-const c-primitive-type-kwds)
                                     plain-strings)))
                     regexp-strings)
             "\\|")
            "\\)\\_>")))
'''

MODE_MENU = r'''
;;; `c-mode-menu' is not carried yet: its value is a menu definition that
;;; `easy-menu-define' (cc-mode.el's 8 uses) turns into a keymap, and
;;; that primitive is not ported. The constant lands with it.
'''

# name -> (text, names consumed by that text)
HAND_REPLACE = {
    'c-keywords': (KEYWORDS, {'c-keywords'}),
    'c-make-no-parens-syntax-table': (NO_PARENS,
                                      {'c-make-no-parens-syntax-table',
                                       'c-no-parens-syntax-table'}),
    'c-nonsymbol-token-char-list': (NONSYMBOL,
                                    {'c-nonsymbol-token-char-list'}),
    'c-enum-list-key': (ENUM, {'c-enum-list-key'}),
    'c-after-enum-list-key': (AFTER_ENUM, {'c-after-enum-list-key'}),
    'c-keyword-member-alist': (MEMBER_ALIST, {'c-keyword-member-alist'}),
    'c-block-prefix-disallowed-chars': (BLOCK_PREFIX,
                                        {'c-block-prefix-disallowed-chars'}),
    'c-known-type-key': (KNOWN_TYPE, {'c-known-type-key'}),
    'c-stmt-boundary-skip-list': (STMT_BOUNDARY,
                                  {'c-stmt-boundary-skip-list',
                                   'c-stmt-boundary-skip-list-with-comma'}),
}

SKIP = {
    'c-mode-menu': MODE_MENU,
    'c-keywords-obarray': KW_OBA,
    'c-make-mode-syntax-table': None,  # already in cc-langs.scm
    'c-mode-syntax-table': None,       # already in cc-langs.scm
}
