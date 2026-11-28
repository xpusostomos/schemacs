(define-library (schemacs core cl-indent)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/cl-indent.el' - the
  ;; enhanced Lisp indentation engine, `common-lisp-indent-function', and
  ;; the table of per-symbol indentation methods it reads.
  ;;
  ;; It is what `lisp-mode' installs as `lisp-indent-function'
  ;; (`lisp-mode.el:866'): an elisp file indents with
  ;; `lisp-indent-function''s simpler rules, a Common Lisp one with these.
  ;; `emacs-lisp-mode' also uses parts of it - `common-lisp-indent-function'
  ;; is "a suitable function for indenting Emacs Lisp code" - which is why
  ;; two entries at the bottom are `common-lisp-indent-function-for-elisp'.
  ;;
  ;; **The one thing this tree spells differently** is what a "function"
  ;; in a method is. Elisp stores the *symbol* of the function to call and
  ;; `funcall's it; a Scheme symbol is not callable, so a method that is a
  ;; function holds the procedure itself. Everything else - the specform
  ;; lists, the integers, the `defun' symbol, `&lambda', `&body', `&rest'
  ;; and `&whole' - is the same data the C builds.
  ;;
  ;; **`intern-soft' always answers a symbol here** (see `subr.scm'), so
  ;; the pleblisp branch in `common-lisp-indent-function-1' - the one that
  ;; strips a `package:' prefix from a name no obarray entry matches -
  ;; never fires. It is carried as the C has it, because the condition is
  ;; the C's condition and a Scheme symbol *is* interned.
  ;;
  ;; Not carried, each because nothing here produces it:
  ;; `lisp-indent-local-overrides'' file/dir-local setting, and the
  ;; `:safe'/:version' cookies on the defcustoms.

  (import
    (scheme base)
    ;; `catch' and `throw' are Guile's, and they are `lisp-indent-259''s
    ;; control structure - the C's `(catch 'exit ... (throw 'exit V))'.
    (only (guile) catch throw)
    ;; `beginning-of-line', `end-of-line' and `forward-char' - `cmds.c''s
    ;; commands, which the C calls as functions from here too.
    (only (schemacs cmds)
          backward-char beginning-of-line end-of-line forward-char)
    ;; `downcase' (`casefiddle.c') for the function name read out of the
    ;; buffer, and `buffer-substring-no-properties' (`editfns.c') for the
    ;; name itself. `save-excursion' is a macro over the same file.
    (only (schemacs casefiddle) downcase)
    (only (schemacs editfns)
          buffer-substring-no-properties char-after char-before eolp
          forward-line goto-char point point-min point-max save-excursion)
    ;; `derived-mode-p' - `subr.el''s, placed in `derived.scm' because it
    ;; reads a buffer's `major-mode'. It is the `emacs-lisp-mode' test
    ;; that picks the `cl-' prefix heuristic and the elisp `if' rule.
    (only (schemacs core derived) derived-mode-p)
    (only (schemacs indentc) current-column)
    ;; `get' and `put' - the symbol properties the method table is.
    (only (schemacs intervals) get put)
    ;; `lisp-body-indent' and `lisp-indent-local-overrides' are
    ;; `lisp-mode.el''s, and this library is above `lisp-mode.scm' - the
    ;; reverse edge (lisp-mode asking for `common-lisp-indent-function')
    ;; is a `resolve-module' seam there, the same one
    ;; `files.sld''s `%mode-autoloads' uses.
    (only (schemacs core lisp-mode)
          lisp-body-indent lisp-indent-local-overrides)
    (only (schemacs core lisp)
          backward-sexp backward-up-list beginning-of-defun forward-sexp)
    ;; `looking-at', `re-search-forward' and `re-search-backward' are
    ;; `search.c''s; `save-match-data' is the macro beside them.
    (only (schemacs search)
          looking-at match-beginning match-end re-search-backward
          re-search-forward save-match-data string-match)
    ;; `parse-partial-sexp' (`syntax.c') and `skip-chars-forward'
    ;; (`syntax.c''s `skip_chars').
    (only (schemacs syntax) parse-partial-sexp skip-chars-forward)
    (only (schemacs subr) intern-soft)
    (only (schemacs custom) define-custom)
    (only (schemacs core regexp-opt) regexp-opt)
    )

  (export
   ;; the entry point `lisp-mode' installs
   common-lisp-indent-function
   ;; the rest of the engine, in the C's order
   lisp-extended-loop-p
   lisp-indent-find-method
   common-lisp-loop-part-indentation
   common-lisp-indent-function-1
   *lisp-indent-error-function*
   common-lisp-indent-call-method
   lisp-indent-report-bad-format
   lisp-indent-lambda-list-keywords-regexp
   lisp-indent-lambda-list
   lisp-indent-259
   lisp-indent-tagbody
   lisp-indent-do
   lisp-indent-defmethod
   lisp-indent-function-lambda-hack
   lisp-indent-defun-method
   ;; the options
   *lisp-indent-maximum-backtracking*
   *lisp-tag-indentation*
   *lisp-tag-body-indentation*
   *lisp-backquote-indentation*
   *lisp-loop-keyword-indentation*
   *lisp-loop-forms-indentation*
   *lisp-simple-loop-indentation*
   *lisp-lambda-list-keyword-alignment*
   *lisp-lambda-list-keyword-parameter-indentation*
   *lisp-lambda-list-keyword-parameter-alignment*
   *lisp-indent-backquote-substitution-mode*
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The options (`cl-indent.el:45-144')
    ;;----------------------------------------------------------------

    (define-custom *lisp-indent-maximum-backtracking* 3
      "Maximum depth to backtrack out from a sublist for structured
indentation.
If this variable is 0, no backtracking will occur and forms such as
`flet' may not be correctly indented."
      :type 'integer)

    (define-custom *lisp-tag-indentation* 1
      "Indentation of tags relative to containing list.
This variable is used by the function `lisp-indent-tagbody'."
      :type 'integer)

    (define-custom *lisp-tag-body-indentation* 3
      "Indentation of non-tagged lines relative to containing list.
This variable is used by the function `lisp-indent-tagbody' to indent
normal lines (lines without tags).
The indentation is relative to the indentation of the parenthesis
enclosing the special form.  If the value is t, the body of tags will be
indented as a block at the same indentation as the first s-expression
following the tag.  In this case, any forms before the first tag are
indented by `lisp-body-indent'."
      :type 'integer)

    (define-custom *lisp-backquote-indentation* #t
      "Whether or not to indent backquoted lists as code.
If nil, indent backquoted lists as data, i.e., like quoted lists."
      :type 'boolean)

    (define-custom *lisp-loop-keyword-indentation* 6
      "Indentation of loop keywords in extended loop forms."
      :type 'integer)

    (define-custom *lisp-loop-forms-indentation* 6
      "Indentation of forms in extended loop forms."
      :type 'integer)

    (define-custom *lisp-simple-loop-indentation* 1
      "Indentation of forms in simple loop forms."
      :type 'integer)

    (define-custom *lisp-lambda-list-keyword-alignment* #f
      "Whether to vertically align lambda-list keywords together.
If nil (the default), keyworded lambda-list parts are aligned with the
initial mandatory arguments; if non-nil, alignment is done with the
first keyword (or falls back to the previous case)."
      :type 'boolean)

    (define-custom *lisp-lambda-list-keyword-parameter-indentation* 2
      "Indentation of lambda list keyword parameters.
See `lisp-lambda-list-keyword-parameter-alignment' for more
information."
      :type 'integer)

    (define-custom *lisp-lambda-list-keyword-parameter-alignment* #f
      "Whether to vertically align lambda-list keyword parameters together.
If nil (the default), the parameters are aligned with their
corresponding keyword, plus the value of
`lisp-lambda-list-keyword-parameter-indentation'; if non-nil,
alignment is done with the first parameter (or falls back to the
previous case)."
      :type 'boolean)

    (define-custom *lisp-indent-backquote-substitution-mode* #t
      "How to indent substitutions in backquotes.
If t, the default, indent substituted forms normally.
If nil, do not apply special indentation rule to substituted forms.
If `corrected', subtract the `,' or `,@' from the form column,
indenting as if this character sequence were not present.
In any case, do not backtrack beyond a backquote substitution."
      :type '(choice (const corrected) (const nil) (const t)))

    ;;----------------------------------------------------------------

    (define lisp-indent-defun-method '(4 &lambda &body))
    ;; ^ `lisp-indent-defun-method' (`cl-indent.el:147'): "Defun-like
    ;; indentation method. This applies when the value of the
    ;; `common-lisp-indent-function' property is set to `defun'."

    (define (lisp-extended-loop-p loop-start)
      ;; GNU Emacs's `lisp-extended-loop-p' (`cl-indent.el:153'): "True if
      ;; an extended loop form starts at LOOP-START."
      ;;--------------------------------------------------------------
      (guard (e (#t #t))
        (save-excursion
          (goto-char loop-start)
          (forward-char 1)
          (forward-sexp 2)
          (backward-sexp 1)
          (looking-at "\\(:\\|\\sw\\)"))))

    (define (lisp-indent-find-method symbol . args)
      ;; GNU Emacs's `lisp-indent-find-method' (`cl-indent.el:164'): "Find
      ;; the Lisp indentation function for SYMBOL. If NO-COMPAT is
      ;; non-nil, do not retrieve indenters intended for the standard Lisp
      ;; indent package."
      ;;
      ;; The third arm is the compatibility one: a symbol with no
      ;; `common-lisp-indent-function' property is indented by whatever
      ;; `lisp-indent-function' says, which is the table `lisp-mode.el'
      ;; fills. That is what makes `(progn ...)' behave the same in
      ;; `lisp-mode' as in `emacs-lisp-mode'.
      ;;--------------------------------------------------------------
      (let ((no-compat (if (pair? args) (car args) #f)))
        (or (and (derived-mode-p 'emacs-lisp-mode)
                 (get symbol 'common-lisp-indent-function-for-elisp))
            (get symbol 'common-lisp-indent-function)
            (and (not no-compat)
                 (let ((local (assq symbol lisp-indent-local-overrides)))
                   (if local
                       (cdr local)
                       (get symbol 'lisp-indent-function)))))))

    (define (common-lisp-loop-part-indentation indent-point state)
      ;; GNU Emacs's `common-lisp-loop-part-indentation'
      ;; (`cl-indent.el:177'): "Compute the indentation of loop form
      ;; constituents."
      ;;--------------------------------------------------------------
      (let* ((loop-indentation
              (save-excursion
                (goto-char (list-ref state 1))
                (current-column))))
        (when (eq? (*lisp-indent-backquote-substitution-mode*) 'corrected)
          (save-excursion
            (goto-char (list-ref state 1))
            (set! loop-indentation
                  (+ loop-indentation
                     (cond ((eqv? (char-before) #\,) -1)
                           ((and (eqv? (char-before) #\@)
                                 (begin (backward-char) (eqv? (char-before) #\,)))
                            -2)
                           (else 0))))))
        (goto-char indent-point)
        (beginning-of-line)
        (list
         (cond ((not (lisp-extended-loop-p (list-ref state 1)))
                (+ loop-indentation (*lisp-simple-loop-indentation*)))
               ((looking-at "^\\s-*\\(?::?\\sw+\\|;\\)")
                (+ loop-indentation (*lisp-loop-keyword-indentation*)))
               (else
                (+ loop-indentation (*lisp-loop-forms-indentation*))))
         ;; "Tell the caller that the next line needs recomputation, even
         ;; though it doesn't start a sexp."
         loop-indentation)))

    (define (common-lisp-indent-function indent-point state)
      ;; GNU Emacs's `common-lisp-indent-function' (`cl-indent.el:209'):
      ;; "Function to indent the arguments of a Lisp function call. This is
      ;; suitable for use as the value of the variable
      ;; `lisp-indent-function'. INDENT-POINT is the point at which the
      ;; indentation function is called, and STATE is the
      ;; `parse-partial-sexp' state at that position."
      ;;
      ;; The docstring's specification list - `defun', a function, an
      ;; integer N, or a list of the `&lambda' / `&rest' / `&body' /
      ;; `&whole' forms - is what `lisp-indent-259' below implements.
      ;;--------------------------------------------------------------
      (if (save-excursion
            (goto-char (list-ref state 1))
            (and (looking-at (if (derived-mode-p 'emacs-lisp-mode)
                                 "(\\(cl-\\)?loop"
                                 "([Ll][Oo][Oo][Pp]"))
                 (or (*lisp-indent-backquote-substitution-mode*)
                     (not (or (and (eqv? (char-before) #\@)
                                   (begin (backward-char)
                                          (eqv? (char-before) #\,)))
                              (eqv? (char-before) #\,))))))
          (common-lisp-loop-part-indentation indent-point state)
          (common-lisp-indent-function-1 indent-point state)))

    (define (common-lisp-indent-function-1 indent-point state)
      ;; GNU Emacs's `common-lisp-indent-function-1' (`cl-indent.el:299'):
      ;; "Walk up list levels until we see something which does special
      ;; things with subforms."
      ;;--------------------------------------------------------------
      (let ((normal-indent (current-column)))
        (let ((depth 0)
              ;; "Path describes the position of point in terms of
              ;; list-structure with respect to containing lists. `foo'
              ;; has a path of (0 3 1) in `((a b c (d foo) f) g)'."
              (path '())
              ;; "set non-nil when somebody works out the indentation to
              ;; use"
              (calculated #f)
              ;; "If non-nil, this is an indentation to use if nothing
              ;; else specifies it more firmly."
              (tentative-calculated #f)
              ;; "the position of the open-paren of the innermost
              ;; containing list"
              (containing-form-start (list-ref state 1))
              ;; "the column of the above"
              (sexp-column #f))
          ;; "Move to start of innermost containing list"
          (goto-char containing-form-start)
          (set! sexp-column (current-column))

          ;; "Look over successively less-deep containing forms"
          (let backtrack ()
            (when (and (not calculated)
                       (< depth (*lisp-indent-maximum-backtracking*)))
              (let ((containing-sexp (point)))
                (forward-char 1)
                (parse-partial-sexp (point) indent-point 1 #t)
                ;; "Move to the car of the relevant containing form"
                (let ((tem #f) (function #f) (method #f) (tentative-defun #f))
                  (if (not (looking-at "\\sw\\|\\s_"))
                      ;; "This form doesn't seem to start with a symbol"
                      (begin (set! function #f) (set! method #f))
                      (begin
                        (set! tem (point))
                        (forward-sexp 1)
                        (set! function
                              (downcase (buffer-substring-no-properties
                                         tem (point))))
                        (goto-char tem)
                        ;; "Elisp generally provides CL functionality with
                        ;; a CL prefix, so if we have a special indenter
                        ;; for the unprefixed version, prefer it over
                        ;; whatever's defined for the cl- version. Users
                        ;; can override this heuristic by defining a
                        ;; `common-lisp-indent-function-for-elisp'
                        ;; property on the cl- version."
                        (if (and (derived-mode-p 'emacs-lisp-mode)
                                 (not (lisp-indent-find-method
                                       (intern-soft function) #t))
                                 (string-match "\\`cl-" function))
                            (let ((stripped (intern-soft
                                             (substring function
                                                        (match-end 0)))))
                              (if (and stripped
                                       (lisp-indent-find-method stripped #t))
                                  (begin
                                    (set! tem stripped)
                                    (set! function (symbol->string stripped)))
                                  #f))
                            #f)
                        (set! tem (intern-soft function))
                        (set! method (lisp-indent-find-method tem))
                        ;; "The pleblisp package feature." The C's test is
                        ;; `(null tem)', and `intern-soft' here always
                        ;; answers a symbol (see the header), so this
                        ;; branch never fires. Carried because the
                        ;; condition is the C's.
                        (when (and (not tem)
                                   (string-match ":[^:]+" function))
                          (set! function (substring function
                                                    (+ 1 (match-beginning 0))))
                          (set! tem (intern-soft function))
                          (set! method (lisp-indent-find-method tem)))))
                  (let ((n 0))
                    ;; "How far into the containing form is the current
                    ;; form?"
                    (if (< (point) indent-point)
                        (let advance ()
                          (when (guard (e (#t #f))
                                  (forward-sexp 1)
                                  (if (>= (point) indent-point)
                                      #f
                                      (begin
                                        (parse-partial-sexp (point)
                                                            indent-point 1 #t)
                                        (set! n (+ n 1))
                                        #t)))
                            (advance))))
                    (set! path (cons n path)))

                  ;; "backwards compatibility."
                  (cond ((not function) #f)
                        ((not method)
                         (when (null? (cdr path))
                           ;; "(package prefix was stripped off above)"
                           (cond ((string-match "\\`def" function)
                                  (set! tentative-defun #t))
                                 ((string-match
                                   (string-append "\\`\\("
                                                  (regexp-opt
                                                   '("with" "without" "do"))
                                                  "\\)-")
                                   function)
                                  (set! method '(&lambda &body))))))
                        ;; "backwards compatibility. Bletch."
                        ((eq? method 'defun)
                         (set! method lisp-indent-defun-method)))

                  (cond
                   ;; "No indentation for "'(...)" elements"
                   ((and (or (eqv? (char-after (- containing-sexp 1)) #\')
                             (and (not (*lisp-backquote-indentation*))
                                  (eqv? (char-after (- containing-sexp 1))
                                        #\`)))
                         (not (eqv? (char-after (- containing-sexp 2)) #\#)))
                    (set! calculated (+ 1 sexp-column)))
                   ;; ",\"(...)\" or \",@(...)\""
                   ((if (or (eqv? (char-after (- containing-sexp 1)) #\,)
                            (and (eqv? (char-after (- containing-sexp 1)) #\@)
                                 (eqv? (char-after (- containing-sexp 2))
                                       #\,)))
                        (begin
                          (when (eq? (*lisp-indent-backquote-substitution-mode*)
                                     'corrected)
                            (set! sexp-column (- sexp-column 1))
                            (when (eqv? (char-after (- containing-sexp 1))
                                        #\@)
                              (set! sexp-column (- sexp-column 1))))
                          (cond ((*lisp-indent-backquote-substitution-mode*)
                                 (set! tentative-calculated normal-indent)
                                 (set! depth
                                       (*lisp-indent-maximum-backtracking*))
                                 #f)
                                (else
                                 (set! calculated normal-indent)
                                 #t)))
                        #f)
                    #f)
                   ;; "\"#(...)\""
                   ((eqv? (char-after (- containing-sexp 1)) #\#)
                    (set! calculated (+ 1 sexp-column)))
                   ((not method)
                    ;; "If this looks like a call to a `def...' form,
                    ;; think about indenting it as one, but do it
                    ;; tentatively for cases like
                    ;; (flet ((defunp () nil)))"
                    (if tentative-defun
                        (begin
                          (set! tentative-calculated
                                (common-lisp-indent-call-method
                                 function lisp-indent-defun-method
                                 path state indent-point
                                 sexp-column normal-indent))
                          (set! normal-indent tentative-calculated))
                        #f))
                   ((integer? method)
                    ;; "convenient top-level hack. (also compatible with
                    ;; `lisp-indent-function') The number specifies how
                    ;; many `distinguished' forms there are before the
                    ;; body starts. Equivalent to (4 4 ... &body)"
                    (set! calculated
                          ;; "((cdr path) normal-indent)" - the C tests
                          ;; the *cdr*: a one-element path is not
                          ;; "in subforms".
                          (cond ((pair? (cdr path)) normal-indent)
                                ((<= (car path) method)
                                 ;; "`distinguished' form"
                                 (list (+ sexp-column 4)
                                       containing-form-start))
                                ((= (car path) (+ method 1))
                                 ;; "first body form."
                                 (+ sexp-column (lisp-body-indent)))
                                (else
                                 ;; "other body form"
                                 normal-indent))))
                   (else
                    (set! calculated
                          (common-lisp-indent-call-method
                           function method path state indent-point
                           sexp-column normal-indent)))))
                (goto-char containing-sexp)
                (if (not calculated)
                    (guard (e (#t (set! depth
                                        (*lisp-indent-maximum-backtracking*))))
                      (backward-up-list 1)
                      (set! depth (+ depth 1)))
                    #f))
              (backtrack)))
          (or calculated tentative-calculated))))

    ;; "Dynamically bound in `common-lisp-indent-call-method'."
    (define *lisp-indent-error-function* (make-parameter #f))
    ;; ^ `lisp-indent-error-function' (`cl-indent.el:470'): the malformed
    ;; method `lisp-indent-report-bad-format' names in its error. A
    ;; `defvar' the C `let'-binds, so a parameter here.

    (define (common-lisp-indent-call-method function method path state
                                            indent-point sexp-column
                                            normal-indent)
      ;; GNU Emacs's `common-lisp-indent-call-method'
      ;; (`cl-indent.el:472').
      ;;
      ;; The C's `(if (symbolp method) (funcall method ...) ...)': a
      ;; function-valued method is a procedure here, and everything else
      ;; is a specform list `lisp-indent-259' walks.
      ;;--------------------------------------------------------------
      (parameterize ((*lisp-indent-error-function* function))
        (if (procedure? method)
            (method path state indent-point sexp-column normal-indent)
            (lisp-indent-259 method path state indent-point
                             sexp-column normal-indent))))

    (define (lisp-indent-report-bad-format m)
      ;; GNU Emacs's `lisp-indent-report-bad-format' (`cl-indent.el:482').
      ;;--------------------------------------------------------------
      (error "~a has a badly-formed ~a property: ~a"
             ;; "Love those free variable references!!"
             (*lisp-indent-error-function*) 'common-lisp-indent-function m))

    ;; "Lambda-list indentation is now done in LISP-INDENT-LAMBDA-LIST."
    ;; "See also `lisp-lambda-list-keyword-alignment',
    ;; `lisp-lambda-list-keyword-parameter-alignment' and
    ;; `lisp-lambda-list-keyword-parameter-indentation' -- dvl"

    (define lisp-indent-lambda-list-keywords-regexp
      ;; `lisp-indent-lambda-list-keywords-regexp' (`cl-indent.el:493'):
      ;; "Regular expression matching lambda-list keywords." The C
      ;; splits the literal across three lines with backslash-newline
      ;; continuations; this is the one string they make.
      ;;--------------------------------------------------------------
      "&\\(optional\\|rest\\|key\\|allow-other-keys\\|aux\\|whole\\|body\\|environment\\)\\([ \t]\\|$\\)")

    (define (lisp-indent-lambda-list indent-point sexp-column
                                     containing-form-start)
      ;; GNU Emacs's `lisp-indent-lambda-list' (`cl-indent.el:499').
      ;;--------------------------------------------------------------
      (let ((limit #f))
        (cond
         ((save-excursion
            (goto-char indent-point)
            (beginning-of-line)
            (skip-chars-forward " \t")
            (set! limit (point))
            (looking-at lisp-indent-lambda-list-keywords-regexp))
          ;; "We're facing a lambda-list keyword."
          (if (*lisp-lambda-list-keyword-alignment*)
              ;; "Align to the first keyword if any, or to the beginning
              ;; of the lambda-list."
              (save-excursion
                (goto-char containing-form-start)
                (save-match-data
                  (if (re-search-forward lisp-indent-lambda-list-keywords-regexp
                                         limit #t)
                      (begin
                        (goto-char (match-beginning 0))
                        (current-column))
                      (+ 1 sexp-column))))
              ;; "Align to the beginning of the lambda-list."
              (+ 1 sexp-column)))
         (else
          ;; "Otherwise, align to the first argument of the last
          ;; lambda-list keyword, the keyword itself, or the beginning of
          ;; the lambda-list."
          (save-excursion
            (goto-char indent-point)
            (forward-line -1)
            (end-of-line)
            (save-match-data
              (if (re-search-backward lisp-indent-lambda-list-keywords-regexp
                                      containing-form-start #t)
                  (let* ((keyword-posn
                          (begin
                            (goto-char (match-beginning 0))
                            (current-column)))
                         (indented-keyword-posn
                          (+ keyword-posn
                             (*lisp-lambda-list-keyword-parameter-indentation*))))
                    (goto-char (match-end 0))
                    (skip-chars-forward " \t")
                    (if (eolp)
                        indented-keyword-posn
                        (if (*lisp-lambda-list-keyword-parameter-alignment*)
                            (current-column)
                            indented-keyword-posn)))
                  (+ 1 sexp-column))))))))

    (define (%cdr x)
      ;; Elisp's `(cdr nil)' is nil; Scheme's is an error. `lisp-indent-259'
      ;; walks a specform to its end on purpose - `(null (cdr method))'
      ;; being true when the pattern has run out is how the C stops - so
      ;; its `cdr's go through here.
      ;;--------------------------------------------------------------
      (if (pair? x) (cdr x) '()))

    ;; "Blame the crufty control structure on dynamic scoping -- not on
    ;; me!"
    (define (lisp-indent-259 method path state indent-point sexp-column
                             normal-indent)
      ;; GNU Emacs's `lisp-indent-259' (`cl-indent.el:553'): the specform
      ;; walk. `catch'/`throw' is the C's, and the key is the same symbol
      ;; in nested calls - the innermost `catch' wins, as in Elisp.
      ;;--------------------------------------------------------------
      (catch 'exit
        (lambda ()
          (let ((p path)
                (containing-form-start (list-ref state 1))
                (n #f) (tem #f) (tail #f))
            ;; "Isn't tail-recursion wonderful?"
            (let outer ()
              (when (pair? p)
                ;; "This while loop is for destructuring. p is set to
                ;; (cdr p) each iteration."
                (if (not (pair? method)) (lisp-indent-report-bad-format method))
                (set! n (- (car p) 1))
                (set! p (cdr p))
                (set! tail #f)
                ;; "This while loop is for advancing along a method until
                ;; the relevant (possibly &rest/&body) pattern is
                ;; reached."
                (let inner ()
                  (when n
                    ;; "(setq tem (car method))" - `(car nil)` is nil in
                    ;; Elisp, and the validation below reads that nil as
                    ;; the `nil' method entry ("default indentation")
                    ;; that ends the walk. A pattern can run out here,
                    ;; which is exactly how the C stops.
                    (set! tem (if (pair? method) (car method) 'nil))
                    (or (eq? tem 'nil)             ; "default indentation"
                        (eq? tem '&lambda)         ; "lambda list"
                        (and (eq? tem '&body) (null? (%cdr method)))
                        (and (eq? tem '&rest)
                             (pair? (%cdr method))
                             (null? (%cdr (%cdr method))))
                        (integer? tem)            ; "explicit indentation specified"
                        (and (pair? tem)          ; "destructuring"
                             (eq? (car tem) '&whole)
                             (or (symbol? (list-ref tem 1))
                                 (integer? (list-ref tem 1))))
                        ;; "a function to call to do the work" - a
                        ;; procedure here, see the header.
                        (and (or (procedure? tem) (symbol? tem))
                             (null? (%cdr method)))
                        (lisp-indent-report-bad-format method))
                    (cond
                     ((and tail
                           (not (or (pair? tem) (procedure? tem)
                                    (symbol? tem))))
                      ;; "indent tail of &rest in same way as first elt
                      ;; of rest"
                      (throw 'exit normal-indent))
                     ((eq? tem '&body)
                      ;; "&body means (&rest <lisp-body-indent>)"
                      (throw 'exit
                             (if (and (= n 0)        ; "first body form"
                                      (null? p))     ; "not in subforms"
                                 (+ sexp-column (lisp-body-indent))
                                 normal-indent)))
                     ((eq? tem '&rest)
                      ;; "this pattern holds for all remaining forms"
                      (set! tail (> n 0))
                      (set! n 0)
                      (set! method (%cdr method))
                      (inner))
                     ((> n 0)
                      ;; "try next element of pattern"
                      (set! n (- n 1))
                      (set! method (%cdr method))
                      (if (< n 0)
                          ;; "Too few elements in pattern."
                          (throw 'exit normal-indent)
                          (inner)))
                     ((eq? tem 'nil)
                      (throw 'exit (if (pair? normal-indent)
                                       normal-indent
                                       (list normal-indent
                                             containing-form-start))))
                     ((eq? tem '&lambda)
                      (throw 'exit
                             (cond ((null? p)
                                    (list (+ sexp-column 4)
                                          containing-form-start))
                                   ((null? (%cdr p))
                                    ;; "Indentation within a lambda-list."
                                    (list (lisp-indent-lambda-list
                                           indent-point
                                           sexp-column
                                           containing-form-start)
                                          containing-form-start))
                                   (else
                                    normal-indent))))
                     ((integer? tem)
                      (throw 'exit
                             (if (null? p)         ; "not in subforms"
                                 (list (+ sexp-column tem)
                                       containing-form-start)
                                 normal-indent)))
                     ((procedure? tem)          ; "a function to call"
                      (throw 'exit
                             (tem path state indent-point
                                  sexp-column normal-indent)))
                     (else
                      ;; "must be a destructing frob"
                      (if (pair? p)
                          ;; "descend"
                          (begin
                            (set! method (%cdr (%cdr tem)))
                            (set! n #f)
                            (inner))
                          (begin
                            (set! tem (list-ref tem 1))
                            (throw 'exit
                                   (cond (tail
                                          normal-indent)
                                         ((eq? tem 'nil)
                                          (list normal-indent
                                                containing-form-start))
                                         ((integer? tem)
                                          (list (+ sexp-column tem)
                                                containing-form-start))
                                         (else
                                          (tem path state indent-point
                                               sexp-column
                                               normal-indent))))))))))
                (outer)))))
        (lambda (key . args) (car args))))

    (define (lisp-indent-tagbody path state indent-point sexp-column
                                 normal-indent)
      ;; GNU Emacs's `lisp-indent-tagbody' (`cl-indent.el:659').
      ;;--------------------------------------------------------------
      (if (not (null? (cdr path)))
          normal-indent
          (save-excursion
            (goto-char indent-point)
            (beginning-of-line)
            (skip-chars-forward " \t")
            (list (cond ((looking-at "\\sw\\|\\s_")
                         ;; "a tagbody tag"
                         (+ sexp-column (*lisp-tag-indentation*)))
                        ((integer? (*lisp-tag-body-indentation*))
                         (+ sexp-column (*lisp-tag-body-indentation*)))
                        ((eq? (*lisp-tag-body-indentation*) #t)
                         (guard (e (#t (+ 1 sexp-column)))
                           (backward-sexp 1)
                           (current-column)))
                        (else (+ sexp-column (lisp-body-indent))))
                  (list-ref state 1)))))

    (define (lisp-indent-do path state indent-point sexp-column
                            normal-indent)
      ;; GNU Emacs's `lisp-indent-do' (`cl-indent.el:685').
      ;;--------------------------------------------------------------
      (if (>= (car path) 3)
          (parameterize ((*lisp-tag-body-indentation* (lisp-body-indent)))
            (lisp-indent-tagbody path state indent-point sexp-column
                                 normal-indent))
          (lisp-indent-259
           '((&whole nil &rest
                      ;; "the following causes weird indentation"
                      ;; (&whole 1 1 2 nil)
                      )
             (&whole nil &rest 1))
           path state indent-point sexp-column normal-indent)))

    ;; "LISP-INDENT-DEFMETHOD now supports the presence of more than one
    ;; method qualifier and indents the method's lambda list properly."
    (define (lisp-indent-defmethod path state indent-point sexp-column
                                   normal-indent)
      ;; GNU Emacs's `lisp-indent-defmethod' (`cl-indent.el:701').
      ;;--------------------------------------------------------------
      (lisp-indent-259
       (let ((nqual 0))
         (if (and (>= (car path) 3)
                  (save-excursion
                    (beginning-of-defun)
                    (forward-char 1)
                    (forward-sexp 2)
                    (skip-chars-forward " \t\n")
                    (let count ()
                      (when (looking-at "\\sw\\|\\s_")
                        (set! nqual (+ nqual 1))
                        (forward-sexp)
                        (skip-chars-forward " \t\n")
                        (count)))
                    (> nqual 0)))
             (append '(4) (make-list nqual 4) '(&lambda &body))
             (get 'defun 'common-lisp-indent-function)))
       path state indent-point sexp-column normal-indent))

    (define (lisp-indent-function-lambda-hack path state indent-point
                                              sexp-column normal-indent)
      ;; GNU Emacs's `lisp-indent-function-lambda-hack'
      ;; (`cl-indent.el:721'): "indent (function (lambda () <newline>
      ;; <body-forms>)) kludgily."
      ;;--------------------------------------------------------------
      (if (or (pair? (cdr path))              ; "wtf?"
              (> (car path) 3))
          ;; "line up under previous body form"
          normal-indent
          ;; "line up under function rather than under lambda in order to
          ;; conserve horizontal space. (Which is what #' is for.)"
          (guard (e (#t (+ sexp-column (lisp-body-indent))))
            (save-excursion
              (backward-up-list 2)
              (forward-char 1)
              (if (looking-at "\\(lisp:+\\)?function\\(\\Sw\\|\\S_\\)")
                  (+ (lisp-body-indent) -1 (current-column))
                  (+ sexp-column (lisp-body-indent)))))))

    ;;----------------------------------------------------------------
    ;; The table (`cl-indent.el:741-829')
    ;;----------------------------------------------------------------
    ;;
    ;; **The entries that name a function hold the *procedure***, which
    ;; is the tree's spelling for Elisp's symbol-in-a-property (see the
    ;; header); every other entry is the C's data verbatim.

    (define %common-lisp-indent-methods
      `((block 1)
        (case        (4 &rest (&whole 2 &rest 1)))
        (ccase . case)
        (ecase . case)
        (typecase . case)
        (etypecase . case)
        (ctypecase . case)
        (catch 1)
        (cond        (&rest (&whole 2 &rest 1)))
        (defvar      (4 2 2))
        (defclass    (6 4 (&whole 2 &rest 1) (&whole 2 &rest 1)))
        (defconstant . defvar)
        (defcustom   (4 2 2 2))
        (defparameter . defvar)
        (defconst     . defcustom)
        (define-condition  . defclass)
        (define-modify-macro (4 &lambda &body))
        (defsetf     (4 &lambda 4 &body))
        (defun       (4 &lambda &body))
        (defgeneric  (4 &lambda &body))
        (define-setf-method . defun)
        (define-setf-expander . defun)
        (defmacro . defun)
        (defsubst . defun)
        (deftype . defun)
        (defmethod   ,lisp-indent-defmethod)
        (defpackage  (4 2))
        (defstruct   ((&whole 4 &rest (&whole 2 &rest 1))
                      &rest (&whole 2 &rest 1)))
        (destructuring-bind
                     ((&whole 6 &rest 1) 4 &body))
        (do          ,lisp-indent-do)
        (do* . do)
        (dolist      ((&whole 4 2 1) &body))
        (dotimes . dolist)
        (eval-when   1)
        (flet        ((&whole 4 &rest (&whole 1 &lambda &body)) &body))
        (labels . flet)
        (macrolet . flet)
        (generic-flet . flet)
        (generic-labels . flet)
        (handler-case (4 &rest (&whole 2 &lambda &body)))
        (restart-case . handler-case)
        ;; "`else-body' style"
        (if          (nil nil &body))
        ;; "single-else style (then and else equally indented)"
        (if          (&rest nil))
        (lambda      (&lambda &rest ,lisp-indent-function-lambda-hack))
        (let         ((&whole 4 &rest (&whole 1 1 2)) &body))
        (let* . let)
        (compiler-let . let) ; "barf"
        (handler-bind . let)
        (restart-bind . let)
        (locally 1)
        ;;(loop         lisp-indent-loop)
        (:method (&lambda &body)) ; "in `defgeneric'"
        (multiple-value-bind ((&whole 6 &rest 1) 4 &body))
        (multiple-value-call (4 &body))
        (multiple-value-prog1 1)
        (multiple-value-setq (4 2))
        (multiple-value-setf . multiple-value-setq)
        (pprint-logical-block (4 2))
        (print-unreadable-object ((&whole 4 1 &rest 1) &body))
        ;; "Combines the worst features of BLOCK, LET and TAGBODY"
        (prog        (&lambda &rest ,lisp-indent-tagbody))
        (prog* . prog)
        (prog1 1)
        (prog2 2)
        (progn 0)
        (progv       (4 4 &body))
        (return 0)
        (return-from (nil &body))
        (symbol-macrolet . let)
        (tagbody     ,lisp-indent-tagbody)
        (throw 1)
        (unless 1)
        (unwind-protect (5 &body))
        (when 1)
        (with-accessors . multiple-value-bind)
        (with-condition-restarts . multiple-value-bind)
        (with-compilation-unit (&lambda &body))
        (with-output-to-string (4 2))
        (with-slots . multiple-value-bind)
        (with-standard-io-syntax (2))))

    ;; "(dolist (el l) (put (car el) 'common-lisp-indent-function (if
    ;; (symbolp (cdr el)) (get (cdr el) 'common-lisp-indent-function)
    ;; (car (cdr el)))))"
    (for-each
     (lambda (el)
       (put (car el) 'common-lisp-indent-function
            (if (symbol? (cdr el))
                (get (cdr el) 'common-lisp-indent-function)
                (car (cdr el)))))
     %common-lisp-indent-methods)

    ;; "In elisp, the else part of `if' is in an implicit progn, so indent
    ;; it more."
    (put 'if 'common-lisp-indent-function-for-elisp 2)
    (put 'with-output-to-string 'common-lisp-indent-function-for-elisp 0)

    ))
