(define-library (schemacs progmodes cc-align)
  ;; A port of GNU Emacs's `lisp/progmodes/cc-align.el': the standard
  ;; line-up functions, used as offsets in `c-offsets-alist' and as the
  ;; actions of `c-hanging-braces-alist', plus the semi&comma criteria.
  ;;
  ;; Every function is in `cc-align.el''s own order, with its docstring
  ;; and its shape. The two conventions that differ from Scheme idiom
  ;; are the tree's: `when-e'/`unless-e'/`cond-e' wherever Emacs's
  ;; `when'/`unless'/`cond' answer (nil) is observable, and `setq' for
  ;; Elisp's - because a plain Scheme `cond' answers the unspecified
  ;; value, which is *true*, and a `set!' in value position loses the
  ;; new value.
  ;;
  ;; **The registry.** Emacs calls a line-up function through the
  ;; function cell of a symbol (`c-evaluate-offset''s `functionp'
  ;; arm); a Lisp-1 has no such indirection, so the functions are
  ;; registered by symbol in `(schemacs progmodes cc-engine)''s
  ;; `c-register-lineup-function!', and by name in `(schemacs editor
  ;; cc-vars)''s `%c-offset-function-names' via
  ;; `c-register-offset-function-name!' (which is what `c-valid-offset'
  ;; asks). The registrations are at the end of the file; nothing here
  ;; may be defined after them.
  ;;
  ;; **`catch'/`throw'.** Guile's `(catch 'tag thunk handler)' is
  ;; Emacs's `(catch 'tag BODY)' for the three functions that use one
  ;; (`c-lineup-java-throws', `c-lineup-ternary-bodies',
  ;; `c-lineup-ObjC-method-call-colons'); the body is a thunk, and the
  ;; no-throw answer is the body's last value - so a `while' in tail
  ;; position needs an explicit `#f' after it, since Elisp's `while'
  ;; answers nil and Scheme's answers the unspecified value.
  ;;
  ;; **`c-last-command-char'** is `cc-defs.scm''s (the last key event,
  ;; a character for a keypress). The semi&comma criteria compare it
  ;; with `eqv?' against `#\;' rather than Emacs's `eq' against `?\;'.
  (import
    (scheme base)
    (only (guile) 1- 1+ catch throw while)
    (only (schemacs core syntax-macros) setq when-e unless-e cond-e)
    (only (schemacs subr) car-safe cdr-safe)
    (only (schemacs buffer) current-buffer *case-fold-search*)
    (only (schemacs command) quit-condition?)
    (only (schemacs data) /=)
    (only (schemacs cmds) beginning-of-line end-of-line
          forward-char backward-char)
    (only (schemacs editfns) point point-min point-max goto-char
          char-before char-after bobp eobp bolp eolp
          forward-line save-excursion save-restriction narrow-to-region widen)
    (only (schemacs fns) concat delete)
    (only (schemacs indent) back-to-indentation)
    (only (schemacs indentc) current-column current-indentation)
    (only (schemacs core lisp) backward-up-list up-list)
    (only (schemacs newcomment) comment-start-skip)
    (only (schemacs search) re-search-forward re-search-backward
          search-forward looking-at string-match regexp-quote
          match-beginning match-end match-string)
    (only (schemacs syntax) char-syntax forward-word-strictly
          skip-chars-forward skip-chars-backward)
    (only (schemacs progmodes cc-defs)
          c-langelem-pos c-langelem-sym c-langelem-col c-langelem-2nd-pos
          c-safe c-forward-sexp c-backward-sexp
          c-go-up-list-backward c-up-list-backward
          c-intersect-lists c-last-command-char)
    (only (schemacs progmodes cc-vars)
          *c-syntactic-context* *c-syntactic-element*
          c-basic-offset c-comment-only-line-offset
          c-current-comment-prefix
          c-label-minimum-indentation c-inside-block-syms
          *c-syntactic-indentation-in-macros*
          *c-objc-method-arg-min-delta-to-bracket*
          *c-objc-method-arg-unfinished-offset*
          *c-objc-method-parameter-offset*
          c-register-offset-function-name!)
    (only (schemacs progmodes cc-engine)
          %c-langvar c-point c-state-cache
          c-backward-syntactic-ws c-forward-syntactic-ws c-forward-comments
          c-syntactic-re-search-forward c-syntactic-skip-backward
          c-forward-token-2 c-backward-token-2
          c-parse-state c-most-enclosing-brace c-safe-position
          c-looking-at-special-brace-list c-looking-at-inexpr-block
          c-in-gcc-asm-p c-in-requires-or-at-end-of-clause
          c-after-special-operator-id
          c-backward-single-comment
          c-beginning-of-macro c-query-macro-start
          c-beginning-of-statement-1 c-forward-class-decl c-do-declarators
          c-guess-basic-syntax c-get-syntactic-indentation
          c-shift-line-indentation
          c-register-lineup-function!))

  (export
   c-lineup-topmost-intro-cont c-lineup-class-field-cont
   c-lineup-gnu-DEFUN-intro-cont c-block-in-arglist-dwim
   c-lineup-arglist
   c-lineup-argcont-1 c-lineup-argcont-scan c-lineup-argcont
   c-lineup-argcont-+
   c-lineup-arglist-intro-after-paren c-lineup-item-after-paren-at-boi
   c-lineup-arglist-close-under-paren c-lineup-arglist-operators
   c-lineup-close-paren
   c-lineup-streamop c-lineup-multi-inher
   c-lineup-java-inher c-lineup-java-throws
   c-indent-one-line-block c-indent-multi-line-block
   c-lineup-C-comments c-lineup-comment c-lineup-knr-region-comment
   c-lineup-runin-statements c-lineup-assignments c-lineup-math
   c-lineup-ternary-bodies c-lineup-cascaded-calls c-lineup-string-cont
   c-lineup-template-args c-lineup-template-args-indented-from-margin
   c-lineup-ObjC-method-call c-lineup-ObjC-method-call-colons
   c-lineup-ObjC-method-args c-lineup-ObjC-method-args-2
   c-lineup-inexpr-block c-lineup-whitesmith-in-block
   c-lineup-after-whitesmith-blocks
   c-lineup-2nd-brace-entry-in-arglist
   c-lineup-class-decl-init-+ c-lineup-class-decl-init-after-brace
   c-lineup-cpp-define c-lineup-gcc-asm-reg
   c-lineup-under-anchor c-lineup-dont-change c-lineup-respect-col-0
   c-snug-do-while c-snug-1line-defun-close c-gnu-impose-minimum
   c-semi&comma-inside-parenlist
   c-semi&comma-no-newlines-before-nonblanks
   c-semi&comma-no-newlines-for-oneline-inliners)

  (begin

    ;;--------------------------------------------------------------
    ;; Standard line-up functions
    ;;--------------------------------------------------------------

    (define (c-lineup-topmost-intro-cont langelem)
      "Line up declaration continuation lines zero or one indentation step.
For lines in the \"header\" of a definition, zero is used.  For other
lines, `c-basic-offset' is added to the indentation.  E.g.:

int
neg (int i)           <- c-lineup-topmost-intro-cont
{
    return -i;
}

struct
larch                 <- c-lineup-topmost-intro-cont
{
    double height;
}
    the_larch,        <- c-lineup-topmost-intro-cont
    another_larch;    <- c-lineup-topmost-intro-cont
<--> c-basic-offset

struct larch
the_larch,            <- c-lineup-topmost-intro-cont
    another_larch;    <- c-lineup-topmost-intro-cont

Works with: topmost-intro-cont."
      (save-excursion
        (beginning-of-line)
        (unless-e (re-search-forward (%c-langvar 'c-fun-name-substitute-key)
                                     (c-point 'eol) #t)
          (beginning-of-line)
          (c-backward-syntactic-ws (c-langelem-pos langelem))
          (if (and (memv (char-before) (list #\} #\,))
                   (not (and (%c-langvar 'c-overloadable-operators-regexp)
                             (c-after-special-operator-id)))
                   (or (not (eqv? (char-before) #\}))
                       (not (eqv? (cdr-safe
                                   (c-in-requires-or-at-end-of-clause))
                                  #t))))
              (c-basic-offset)
              #f))))

    (define (c-lineup-class-field-cont langelem)
      "Line up continuation lines in a class zero or one indentation steps.
For a declaration following a template specification, zero steps are
used.  Other constructs are indented one step."
      (save-excursion
        (beginning-of-line)
        (c-backward-syntactic-ws (c-langelem-pos langelem))
        (unless-e (eqv? (char-before) #\>)
          (c-basic-offset))))

    (define (c-lineup-gnu-DEFUN-intro-cont langelem)
      "Line up the continuation lines of a DEFUN macro in the Emacs C source.
These lines are indented `c-basic-offset' columns, usually from column 0.
Return nil when we're not in such a construct.

Works with: topmost-intro-cont."
      (save-excursion
        (parameterize ((*case-fold-search* #f))
          (goto-char (c-langelem-pos langelem))
          (if (looking-at "\\_<DEFUN\\_>")
              (c-basic-offset)
              #f))))

    (define (c-block-in-arglist-dwim arglist-start)
      ;; "This function implements the DWIM to avoid far indentation of
      ;; brace block constructs in arguments in `c-lineup-arglist' etc.
      ;; Return non-nil if a brace block construct is detected within the
      ;; arglist starting at ARGLIST-START."
      (or
       ;; "Check if the syntactic context contains any of the symbols
       ;; for in-expression constructs."
       (assq 'inexpr-class (*c-syntactic-context*))
       (assq 'inexpr-statement (*c-syntactic-context*))
       (assq 'inlambda (*c-syntactic-context*))

       (save-restriction
         ;; "Search for open braces from the arglist start to the end of
         ;; the line."
         (narrow-to-region arglist-start (c-point 'eol arglist-start))
         (goto-char arglist-start)
         (let loop ()
           (when (and (c-syntactic-re-search-forward "{" #f #t)
                      (begin
                        (backward-char)
                        (or
                         ;; "Ignore starts of special brace lists."
                         (and (%c-langvar 'c-special-brace-lists)
                              (save-restriction
                                (widen)
                                (c-looking-at-special-brace-list)))
                         ;; "Ignore complete blocks."
                         (c-safe (c-forward-sexp) #t))))
             (forward-char)
             (loop)))
         (looking-at "{"))

       (let ((containing-sexp #f))
         (goto-char arglist-start)
         ;; "`c-syntactic-eol' always matches somewhere on the line."
         (re-search-forward (%c-langvar 'c-syntactic-eol))
         (goto-char (match-beginning 0))
         (c-forward-syntactic-ws)
         (setq containing-sexp (c-most-enclosing-brace (c-parse-state)))
         (c-looking-at-inexpr-block
          (c-safe-position (or containing-sexp (point)) (c-state-cache))
          containing-sexp))))

    (define (c-lineup-arglist _langelem)
      "Line up the current argument line under the first argument.

As a special case, if the indented line is inside a brace block
construct, the indentation is `c-basic-offset' only.  This is intended
as a \"DWIM\" measure in cases like macros that contains statement
blocks, e.g.:

A_VERY_LONG_MACRO_NAME ({
        some (code, with + long, lines * in[it]);
    });
<--> c-basic-offset

Works with: arglist-cont-nonempty, arglist-close."
      (save-excursion
        (let ((indent-pos (point))
              (ws-length (save-excursion
                           (back-to-indentation)
                           (let ((ind-col (current-column)))
                             (c-forward-comments (c-point 'eol))
                             (- (current-column) ind-col)))))
          (if (c-block-in-arglist-dwim
               (c-langelem-2nd-pos (*c-syntactic-element*)))
              (c-basic-offset)              ; DWIM case.
              ;; "Normal case. Indent to the token after the arglist
              ;; open paren." Emacs's `if' takes any number of ELSE
              ;; forms; Scheme's takes one, so they are a `begin'.
              (begin
                (goto-char (c-langelem-2nd-pos (*c-syntactic-element*)))
                (if (and (%c-langvar 'c-special-brace-lists)
                         (c-looking-at-special-brace-list))
                    ;; "Skip a special brace list opener like \"({\"."
                    (begin (c-forward-token-2)
                           (forward-char))
                    (forward-char))
                (let ((arglist-content-start (point)))
                  (c-forward-syntactic-ws)
                  (when (< (point) indent-pos)
                    (goto-char arglist-content-start)
                    (c-forward-comments (c-point 'eol))
                    (if (eolp)
                        (goto-char arglist-content-start)))
                  (vector (- (current-column) ws-length))))))))

    (define (c-lineup-argcont-1 elem)
      ;; "Move to the start of the current arg and return non-nil,
      ;; otherwise return nil."
      (beginning-of-line)

      (when (eq? (car elem) 'arglist-cont-nonempty)
        ;; "Our argument list might not be the innermost one. If it
        ;; isn't, go back to the first position in it. We do this by
        ;; stepping back over open parens until we get to the open paren
        ;; of our argument list."
        (let ((open-paren (c-langelem-2nd-pos (*c-syntactic-element*)))
              (paren-state (c-parse-state)))
          (while (not (eq? (car paren-state) open-paren))
            (unless (pair? (car paren-state)) ; "ignore matched braces"
              (goto-char (car paren-state)))
            (setq paren-state (cdr paren-state)))))

      (let ((start (point)) (c #f))

        (when (bolp)
          ;; "Previous line ending in a comma means we're the start of
          ;; an argument. This should quickly catch most cases not for
          ;; us. This case is only applicable if we're the innermost
          ;; arglist."
          (c-backward-syntactic-ws)
          (setq c (char-before)))

        (unless (eqv? c #\,)
          ;; "In a gcc asm, \":\" on the previous line means the start
          ;; of an argument. And lines starting with \":\" are not for
          ;; us, don't want them to indent to the preceding operand."
          (let ((gcc-asm (save-excursion
                           (goto-char start)
                           (c-in-gcc-asm-p))))
            (unless-e (and gcc-asm
                           (or (eqv? c #\:)
                               (save-excursion
                                 (goto-char start)
                                 (looking-at "[ \t]*:"))))
              (c-lineup-argcont-scan (if gcc-asm #\: #f))
              #t)))))

    (define (c-lineup-argcont-scan . rest)
      ;; "Find the start of an argument, for `c-lineup-argcont'."
      (let ((other-match (if (pair? rest) (car rest) #f)))
        (when-e (= 0 (c-backward-token-2 1 #t))
          (let ((c (char-after)))
            (if (or (eqv? c #\,) (eqv? c other-match))
                (begin
                  (forward-char)
                  (c-forward-syntactic-ws))
                (c-lineup-argcont-scan other-match))))))

    ;; "Contributed by Kevin Ryde <user42@zip.com.au>."
    (define (c-lineup-argcont elem)
      "Line up a continued argument.

foo (xyz, aaa + bbb + ccc
          + ddd + eee + fff);    <- c-lineup-argcont

Only continuation lines like this are touched, nil is returned on lines
which are the start of an argument.

Within a gcc asm block, \":\" is recognized as an argument separator,
but of course only between operand specifications, not in the expressions
for the operands.

Works with: arglist-cont, arglist-cont-nonempty."
      (save-excursion
        (when-e (c-lineup-argcont-1 elem)
          (vector (current-column)))))

    (define (c-lineup-argcont-+ langelem)
      "Indent an argument continuation `c-basic-offset' in from the first argument.

This first argument is that on a previous line at the same level of nesting.

foo (xyz, uvw, aaa + bbb + ccc
         + ddd + eee + fff);    <- c-lineup-argcont-+
     <-->                          c-basic-offset

Only continuation lines like this are touched, nil being returned
on lines which are the start of an argument.

Works with: arglist-cont, arglist-cont-nonempty."
      (save-excursion
        (when-e (c-lineup-argcont-1 langelem) ; "Check we've got a continued argument..."
          ;; "... but ignore the position found."
          (goto-char (c-langelem-2nd-pos (*c-syntactic-element*)))
          (forward-char)
          (c-forward-syntactic-ws)
          (vector (+ (current-column) (c-basic-offset))))))

    (define (c-lineup-arglist-intro-after-paren _langelem)
      "Line up a line to just after the open paren of the surrounding paren
or brace block.

Works with: defun-block-intro, brace-list-intro, enum-intro
statement-block-intro, statement-case-intro, arglist-intro."
      (save-excursion
        (let ((ws-length (save-excursion
                           (back-to-indentation)
                           (let ((ind-col (current-column)))
                             (c-forward-comments (c-point 'eol))
                             (- (current-column) ind-col)))))
          (beginning-of-line)
          (backward-up-list 1)
          (forward-char)
          (let ((after-paren-pos (point)))
            (c-forward-comments (c-point 'eol))
            (if (eolp)
                (goto-char after-paren-pos)))
          (vector (- (current-column) ws-length)))))

    (define (c-lineup-item-after-paren-at-boi _langelem)
      "Line up to just after the surrounding open paren at boi.
This also works when there are only open parens between the surrounding
paren and boi.  \"paren\" here can also mean \"brace\", etc.  We line up
under the first non-whitespace text after the paren.  If there is no
such paren, or no such text, return nil, allowing another function to
handle the construct.

Works with: brace-list-intro, enum-intro, constraint-cont."
      (save-excursion
        (beginning-of-line)
        (and
         (if (c-langelem-2nd-pos (*c-syntactic-element*))
             ;; "brace-list-intro, enum-intro."
             (begin (goto-char (c-langelem-2nd-pos (*c-syntactic-element*)))
                    #t)
             ;; "constraint-cont."
             (c-go-up-list-backward #f (c-langelem-pos (*c-syntactic-element*))))
         (looking-at "\\s(")
         (save-excursion
           (skip-chars-backward " \t([{" (c-point 'boi))
           (eq? (point) (c-point 'boi)))
         (begin (forward-char)
                (c-forward-syntactic-ws (c-point 'eol))
                (unless-e (eolp)
                  (vector (current-column)))))))

    (define (c-lineup-arglist-close-under-paren langelem)
      "Line up a line under the enclosing open paren.
Normally used to line up a closing paren in the same column as its
corresponding open paren, but can also be used with arglist-cont and
arglist-cont-nonempty to line up all lines inside a parenthesis under
the open paren.

As a special case, if a brace block construct starts at the same line
as the open parenthesis of the argument list, the indentation is
`c-basic-offset' only.  See `c-lineup-arglist' for further discussion
of this \"DWIM\" measure.

Works with: Almost all symbols, but are typically most useful on
arglist-close, brace-list-close, enum-close, arglist-cont and
arglist-cont-nonempty."
      (save-excursion
        (if (memv (c-langelem-sym langelem)
                  '(arglist-cont-nonempty arglist-close))
            (goto-char (c-langelem-2nd-pos (*c-syntactic-element*)))
            (begin
              (beginning-of-line)
              (c-go-up-list-backward)))

        (if (save-excursion (c-block-in-arglist-dwim (point)))
            (c-basic-offset)            ; DWIM case.
            ;; "Normal case. Indent to the arglist open paren."
            (let ((special-list #f))
              (if (and (%c-langvar 'c-special-brace-lists)
                       (begin
                         (setq special-list (c-looking-at-special-brace-list))
                         special-list))
                  ;; "Cope if we're in the middle of a special brace
                  ;; list opener like \"({\"."
                  (goto-char (car (car special-list))))
              (vector (current-column))))))

    (define (c-lineup-arglist-operators langelem)
      "Line up lines starting with an infix operator under the open paren.
Return nil on lines that don't start with an operator, to leave those
cases to other line-up functions.  Example:

if (  x < 10
   || at_limit (x,       <- c-lineup-arglist-operators
                list)    <- c-lineup-arglist-operators returns nil
   )

Since this function doesn't do anything for lines without an infix
operator you typically want to use it together with some other line-up
settings, e.g. as follows (the arglist-close setting is just a
suggestion to get a consistent style):

\\(c-set-offset \\='arglist-cont \\='(c-lineup-arglist-operators 0))
\\(c-set-offset \\='arglist-cont-nonempty \\='(c-lineup-arglist-operators
                                        c-lineup-arglist))
\\(c-set-offset \\='arglist-close \\='(c-lineup-arglist-close-under-paren))

Works with: arglist-cont, arglist-cont-nonempty."
      (save-excursion
        (back-to-indentation)
        (when-e (looking-at "[-+|&*%<>=]\\|\\(/[^/*]\\)")
          ;; "'-' can be both an infix and a prefix operator, but I'm
          ;; lazy now.."
          (c-lineup-arglist-close-under-paren langelem))))

    (define (c-lineup-close-paren langelem)
      "Line up the closing paren under its corresponding open paren if the
open paren is followed by code.  If the open paren ends its line, no
indentation is added.  E.g.:

main (int,              main (
      char **               int, char **
     )           <->    )                 <- c-lineup-close-paren

As a special case, if a brace block construct starts at the same line
as the open parenthesis of the argument list, the indentation is
`c-basic-offset' instead of the open paren column.  See
`c-lineup-arglist' for further discussion of this \"DWIM\" measure.

Works with: All *-close symbols."
      (save-excursion
        (if (memv (c-langelem-sym langelem)
                  '(arglist-cont-nonempty arglist-close))
            (goto-char (c-langelem-2nd-pos (*c-syntactic-element*)))
            (begin
              (beginning-of-line)
              (c-go-up-list-backward)))

        (let ((special-list #f) (arglist-start #f))
          (if (and (%c-langvar 'c-special-brace-lists)
                   (begin
                     (setq special-list (c-looking-at-special-brace-list))
                     special-list))
              ;; "Cope if we're in the middle of a special brace list
              ;; opener like \"({\"."
              (begin
                (goto-char (setq arglist-start (car (car special-list))))
                (c-forward-token-2)
                (forward-char))
              (begin
                (setq arglist-start (point))
                (forward-char)))

          (cond-e
           ((looking-at (%c-langvar 'c-syntactic-eol))
            0)                          ; "The arglist is \"empty\"."
           ((c-block-in-arglist-dwim (point))
            (c-basic-offset))           ; DWIM case.
           (else
            ;; "Normal case. Indent to the arglist open paren."
            (goto-char arglist-start)
            (vector (current-column)))))))

    (define (c-lineup-streamop langelem)
      "Line up C++ stream operators under each other.

Works with: stream-op."
      (save-excursion
        (goto-char (c-langelem-pos langelem))
        (re-search-forward "<<\\|>>" (c-point 'eol) 'move)
        (goto-char (match-beginning 0))
        (vector (current-column))))

    (define (c-lineup-multi-inher langelem)
      "Line up the classes in C++ multiple inheritance clauses and member
initializers under each other.  E.g.:

class Foo:                Foo::Foo (int a, int b):
    public Cyphr,             Cyphr (a),
    public Bar       <->      Bar (b)               <- c-lineup-multi-inher

class Foo                 Foo::Foo (int a, int b)
    : public Cyphr,           : Cyphr (a),
      public Bar     <->        Bar (b)             <- c-lineup-multi-inher

class Foo                 Foo::Foo (int a, int b)
    : public Cyphr            : Cyphr (a)
    , public Bar     <->      , Bar (b)             <- c-lineup-multi-inher

Works with: inher-cont, member-init-cont."
      (save-excursion
        (back-to-indentation)
        (let* ((eol (c-point 'eol))
               (here (point))
               (char-after-ip (char-after)))
          (if (c-langelem-pos langelem)
              (goto-char (c-langelem-pos langelem)))

          ;; "This kludge is necessary to support both inher-cont and
          ;; member-init-cont, since they have different anchor
          ;; positions."
          (c-backward-syntactic-ws)
          (when (eqv? (char-before) #\:)
            (backward-char)
            (c-backward-syntactic-ws))

          (c-syntactic-re-search-forward ":" eol 'move)
          (cond
           ((looking-at (%c-langvar 'c-syntactic-eol))
            (c-forward-syntactic-ws here))
           ((eqv? char-after-ip #\,)
            (backward-char))
           (else (c-forward-comments eol)))
          (if (< (point) here)
              (vector (current-column))
              #f))))

    (define (c-lineup-java-inher langelem)
      "Line up Java implements and extends declarations.
If class names follow on the same line as the implements/extends
keyword, they are lined up under each other.  Otherwise, they are
indented by adding `c-basic-offset' to the column of the keyword.
E.g.:

class Foo             class Foo
    extends               extends Cyphr,
        Bar    <->                Bar     <- c-lineup-java-inher
    <--> c-basic-offset

Works with: inher-cont."
      (save-excursion
        (goto-char (c-langelem-pos langelem))
        (forward-word-strictly 1)
        (if (looking-at "[ \t]*$")
            (c-basic-offset)
            (begin
              (c-forward-syntactic-ws)
              (vector (current-column))))))

    (define (c-lineup-java-throws langelem)
      "Line up Java throws declarations.
If exception names follow on the same line as the throws keyword,
they are lined up under each other.  Otherwise, they are indented by
adding `c-basic-offset' to the column of the throws keyword.  The
throws keyword itself is also indented by `c-basic-offset' from the
function declaration start if it doesn't hang.  E.g.:

int foo()           int foo() throws Cyphr,
    throws     <->                   Bar,    <- c-lineup-java-throws
        Bar    <->                   Vlod    <- c-lineup-java-throws
<--><--> c-basic-offset

Works with: func-decl-cont."
      (save-excursion
        (let* ((lim (1- (c-point 'bol)))
               (throws (catch 'done
                         (lambda ()
                           (goto-char (c-langelem-pos langelem))
                           (while (= 0 (c-forward-token-2 1 #f lim))
                             (if (looking-at "throws\\_>")
                                 (throw 'done #t)))
                           #f)
                         (lambda (key . args) (car args)))))
          (if throws
              (if (= 0 (c-forward-token-2 1 #f (c-point 'eol)))
                  (vector (current-column))
                  (begin
                    (back-to-indentation)
                    (vector (+ (current-column) (c-basic-offset)))))
              (c-basic-offset)))))

    (define (c-indent-one-line-block _langelem)
      "Indent a one line block `c-basic-offset' extra.
E.g.:

if (n > 0)                 if (n > 0)
    {m+=n; n=0;}    <->    {               <- c-indent-one-line-block
<--> c-basic-offset            m+=n; n=0;
                           }

The block may use any kind of parenthesis character.  nil is returned
if the line doesn't start with a one line block, which makes the
function usable in list expressions.

Work with: Almost all syntactic symbols, but most useful on *-open."
      (save-excursion
        (let ((eol (c-point 'eol)))
          (back-to-indentation)
          (if (and (eqv? (char-syntax (char-after)) #\()
                   (c-safe (c-forward-sexp) #t)
                   (<= (point) eol))
              (c-basic-offset)
              #f))))

    (define (c-indent-multi-line-block _langelem)
      "Indent a multi line block `c-basic-offset' extra.
E.g.:

int *foo[] = {           int *foo[] = {
    NULL,                    NULL,
    {17},         <->            {       <- c-indent-multi-line-block
                                 17
                                 }
                             <--> c-basic-offset

The block may use any kind of parenthesis character.  nil is returned
if the line doesn't start with a multi line block, which makes the
function usable in list expressions.

Work with: Almost all syntactic symbols, but most useful on *-open."
      (save-excursion
        (let ((eol (c-point 'eol)))
          (back-to-indentation)
          (if (and (eqv? (char-syntax (char-after)) #\()
                   (or (not (c-safe (c-forward-sexp) #t))
                       (> (point) eol)))
              (c-basic-offset)
              #f))))

    (define (c-lineup-C-comments langelem)
      "Line up C block comment continuation lines.
Various heuristics are used to handle many of the common comment
styles.  Some examples:

/*          /**         /*         /* text      /*          /**
 * text      * text       text        text      ** text      ** text
 */          */         */         */           */           */

/*********************************************************************
 * text
 ********************************************************************/

The variable `c-comment-prefix-regexp' is used to recognize the
comment line prefix, e.g. the `*' that usually starts every line
inside a comment.

Works with: The `c' syntactic symbol."
      (save-excursion
        (let* ((here (point))
               (prefixlen (begin
                            (back-to-indentation)
                            (if (looking-at (c-current-comment-prefix))
                                (- (match-end 0) (point))
                                0)))
               (starterlen
                ;; "Get the length of the comment starter, not including
                ;; the first \"/\". We check if the comment prefix
                ;; matched on the current line matches the starter or
                ;; if it matches comment-start-skip, and choose whichever
                ;; is longest."
                (max (save-excursion
                       (goto-char (1+ (c-langelem-pos langelem)))
                       (if (and (match-string 0)
                                (looking-at (regexp-quote (match-string 0))))
                           (- (match-end 0) (match-beginning 0))
                           0))
                     (save-excursion
                       (goto-char (c-langelem-pos langelem))
                       (looking-at (comment-start-skip))
                       (- (or (match-end 1)
                              (save-excursion
                                (goto-char (match-end 0))
                                (skip-chars-backward " \t")
                                (point)))
                          (point)
                          1)))))
          (if (and (> starterlen 10) (= prefixlen 0))
              ;; "The comment has a long starter and the line doesn't
              ;; have a nonempty comment prefix. Treat it as free form
              ;; text and don't change the indentation."
              (vector (current-column))
              (begin
                ;; "Go back to the previous non-blank line, if any."
                (while
                    (begin
                      (forward-line -1)
                      (back-to-indentation)
                      (and (> (point) (c-langelem-pos langelem))
                           (looking-at "[ \t]*$"))))
                ;; "Is the starting line the first continuation line
                ;; with content?"
                (if (>= (c-langelem-pos langelem) (point))
                    (if (= prefixlen 0)
                        ;; "No nonempty comment prefix. Align after
                        ;; comment starter."
                        (begin
                          (looking-at (comment-start-skip))
                          (goto-char (match-end 0))
                          (vector (current-column)))
                        ;; "How long is the comment starter? if greater
                        ;; than the length of the comment prefix, align
                        ;; left. if less than or equal, align right.
                        ;; this should also pick up Javadoc style
                        ;; comments."
                        (if (> starterlen prefixlen)
                            (begin
                              (goto-char (c-langelem-pos langelem))
                              (vector (1+ (current-column))))
                            (begin
                              (goto-char (+ (c-langelem-pos langelem)
                                            starterlen 1))
                              (vector (- (current-column) prefixlen)))))
                    ;; "We didn't start on the first non-blank
                    ;; continuation line. If the previous line has a
                    ;; nonempty comment prefix, align with it.
                    ;; Otherwise, align with the previous nonempty line,
                    ;; but align the comment ender with the starter."
                    (begin
                      (when-e (or (not (looking-at (c-current-comment-prefix)))
                                  (eqv? (match-beginning 0) (match-end 0)))
                        (goto-char here)
                        (back-to-indentation)
                        (if (looking-at (concat "\\("
                                                (c-current-comment-prefix)
                                                "\\)\\*/"))
                            (goto-char (c-langelem-pos langelem))
                            (begin
                              (while (and (= 0 (forward-line -1))
                                          (looking-at "^[ \t]*$")))
                              (back-to-indentation)
                              (if (< (point) (c-langelem-pos langelem))
                                  ;; "Align with the comment starter
                                  ;; rather than with the code before
                                  ;; it."
                                  (goto-char (c-langelem-pos langelem))))))
                      (vector (current-column)))))))))

    (define (c-lineup-comment _langelem)
      "Line up a comment start according to `c-comment-only-line-offset'.
If the comment is lined up with a comment starter on the previous
line, that alignment is preserved.

Works with: comment-intro."
      (save-excursion
        (back-to-indentation)
        (let ((col (current-column)))
          (cond
           ;; "CASE 1: preserve aligned comments"
           ((save-excursion
              (and (c-backward-single-comment)
                   (= col (current-column))))
            (vector col))               ; "Return an absolute column."
           ;; "indent as specified by c-comment-only-line-offset"
           ((not (bolp))
            (or (car-safe (c-comment-only-line-offset))
                (c-comment-only-line-offset)))
           (else
            (or (cdr-safe (c-comment-only-line-offset))
                (car-safe (c-comment-only-line-offset))
                -1000))))))             ; "jam it against the left side"

    (define (c-lineup-knr-region-comment _langelem)
      "Line up a comment in the \"K&R region\" with the declaration.
That is the region between the function or class header and the
beginning of the block.  E.g.:

int main()
/* This is the main function. */  <- c-lineup-knr-region-comment
{
  return 0;
}

Return nil if called in any other situation, to be useful in list
expressions.

Works with: comment-intro."
      (when-e (or (assq 'topmost-intro-cont (*c-syntactic-context*))
                  (assq 'func-decl-cont (*c-syntactic-context*))
                  (assq 'knr-argdecl-intro (*c-syntactic-context*))
                  (assq 'lambda-intro-cont (*c-syntactic-context*)))
        (save-excursion
          (beginning-of-line)
          (c-beginning-of-statement-1)
          (vector (current-column)))))

    (define (c-lineup-runin-statements langelem)
      "Line up statements when the first statement is on the same line as
the block opening brace.  E.g.:

int main()
{ puts (\"Hello world!\");
  return 0;                 <- c-lineup-runin-statements
}

If there is no statement after the opening brace to align with, nil is
returned.  This makes the function usable in list expressions.

Works with: The `statement' syntactic symbol."
      (if (eqv? (char-after (c-langelem-pos langelem)) #\{)
          (save-excursion
            (if (c-langelem-pos langelem)
                (goto-char (c-langelem-pos langelem)))
            (forward-char 1)
            (c-forward-comments (c-point 'eol))
            (unless-e (eolp)
              (vector (current-column))))
          #f))

    (define (c-lineup-assignments langelem)
      "Line up the current line after the assignment operator on the first
line in the statement.  If there isn't any, return nil to allow
stacking with other line-up functions.  If the current line contains
an assignment operator too, try to align it with the first one.

Works with: topmost-intro-cont, statement-cont, arglist-cont,
arglist-cont-nonempty."
      (let ((startpos #f) (endpos #f) (equalp #f))

        (if (eq? (c-langelem-sym langelem) 'arglist-cont-nonempty)
            ;; "If it's an arglist-cont-nonempty then we're only
            ;; interested in equal signs outside it. We don't search
            ;; for a \"=\" on the current line since that'd have a
            ;; different nesting compared to the one we should align
            ;; with."
            (save-excursion
              (save-restriction
                (setq endpos (c-langelem-2nd-pos (*c-syntactic-element*)))
                (narrow-to-region (c-langelem-pos langelem) endpos)
                (if (begin (setq startpos (c-up-list-backward endpos))
                           startpos)
                    (setq startpos (+ 1 startpos))
                    (setq startpos (c-langelem-pos langelem)))))

            (setq startpos (c-langelem-pos langelem)
                  endpos (c-point 'bol)))

        ;; "Find a syntactically relevant and unnested \"=\" token on
        ;; the current line. equalp is in that case set to the number
        ;; of columns to left shift the current line to align it with
        ;; the goal column."
        (save-excursion
          (beginning-of-line)
          (when (c-syntactic-re-search-forward
                 (%c-langvar 'c-assignment-op-regexp)
                 (c-point 'eol) #t #t #t)
            (setq equalp (- (or (match-beginning 1)
                                (match-end 0))
                            (c-point 'boi)))))

        (save-excursion
          (goto-char startpos)
          (if (or (if (c-syntactic-re-search-forward
                       (%c-langvar 'c-assignment-op-regexp)
                       (min endpos (c-point 'eol)) #t #t #t)
                      (begin
                        (goto-char (or (match-beginning 1)
                                       (match-end 0)))
                        #f)
                      #t)
                  (save-excursion
                    (c-forward-syntactic-ws (c-point 'eol))
                    (eolp)))
              ;; "There's no equal sign on the line, or there is one but
              ;; nothing follows it."
              #f

              ;; "calculate indentation column after equals and ws,
              ;; unless our line contains an equals sign"
              (begin
                (if (not equalp)
                    (begin
                      (skip-chars-forward " \t")
                      (setq equalp 0)))
                (vector (- (current-column) equalp)))))))

    (define (c-lineup-math langelem)
      "Like `c-lineup-assignments' but indent with `c-basic-offset' if no
assignment operator was found on the first line.  I.e. this function
is the same as specifying a list (c-lineup-assignments +).  It's
provided for compatibility with old configurations.

Works with: topmost-intro-cont, statement-cont, arglist-cont,
arglist-cont-nonempty."
      (or (c-lineup-assignments langelem)
          (c-basic-offset)))

    (define (c-lineup-ternary-bodies langelem)
      "Line up true and false branches of a ternary operator (i.e. `?:').
More precisely, if the line starts with a colon which is a part of
a said operator, align it with corresponding question mark; otherwise
return nil.  For example:

    return arg % 2 == 0 ? arg / 2
                        : (3 * arg + 1);    <- c-lineup-ternary-bodies

Works with: arglist-cont, arglist-cont-nonempty and statement-cont."
      (save-excursion
        (back-to-indentation)
        (when (and (eqv? #\: (char-after))
                   (not (eqv? #\: (char-after (1+ (point))))))
          (let ((limit (c-langelem-pos langelem)) (depth 1))
            (catch 'done
              (lambda ()
                (while (and (c-syntactic-skip-backward "^?:" limit #t)
                            (not (bobp)))
                  (backward-char)
                  (cond ((eqv? (char-after) #\?)
                         ;; "If we've found a question mark, decrease
                         ;; depth. If we've reached zero, we've found
                         ;; the one we were looking for."
                         (when (= 0 (setq depth (1- depth)))
                           (throw 'done (vector (current-column)))))
                        ((or (eqv? #\: (char-before))
                             (eqv? #\? (char-before)))
                         ;; "Step over `::' and `?:' operators. We don't
                         ;; have to handle `?:' here but doing so saves
                         ;; an iteration."
                         (if (eqv? (point) limit)
                             (throw 'done #f)
                             (goto-char (1- (point)))))
                        (else (setq depth (1+ depth))))) ; "Otherwise increase depth."
                #f)
              (lambda (key . args) (car args)))))))

    (define (c-lineup-cascaded-calls langelem)
      "Line up \"cascaded calls\" under each other.
If the line begins with \"->\" or \".\" and the preceding line ends
with one or more function calls preceded by the same token, then the
arrow is lined up with the first of those tokens.  E.g.:

result = proc->add(17)->add(18)
             ->add(19) +           <- c-lineup-cascaded-calls
  offset;                          <- c-lineup-cascaded-calls (inactive)

In any other situation nil is returned to allow use in list
expressions.

Works with: topmost-intro-cont, statement-cont, arglist-cont,
arglist-cont-nonempty."
      (if (and (eq? (c-langelem-sym langelem) 'arglist-cont-nonempty)
               (not (eq? (c-langelem-2nd-pos (*c-syntactic-element*))
                         (c-most-enclosing-brace (c-parse-state)))))
          ;; "The innermost open paren is not our one, so don't do
          ;; anything. This can occur for arglist-cont-nonempty with
          ;; nested arglist starts on the same line."
          #f

          (save-excursion
            (back-to-indentation)
            (let ((operator (and (looking-at "->\\|\\.")
                                 (regexp-quote (match-string 0))))
                  (stmt-start (c-langelem-pos langelem)) (col #f))

              (when-e (and operator
                           (looking-at operator)
                           (= 0 (c-backward-token-2 1 #t stmt-start))
                           (eqv? (char-after) #\()
                           (= 0 (c-backward-token-2 2 #t stmt-start))
                           (looking-at operator))
                (setq col (current-column))

                (while (and (= 0 (c-backward-token-2 1 #t stmt-start))
                            (eqv? (char-after) #\()
                            (= 0 (c-backward-token-2 2 #t stmt-start))
                            (looking-at operator))
                  (setq col (current-column)))

                (vector col))))))

    (define (c-lineup-string-cont _langelem)
      "Line up a continued string under the one it continues.
A continued string in this sense is where a string literal follows
directly after another one.  E.g.:

result = prefix + \"A message \"
                  \"string.\";      <- c-lineup-string-cont

In other situations, returns nil, to allow stacking with other
line-up functions.

Works with: topmost-intro-cont, statement-cont, arglist-cont,
arglist-cont-nonempty."
      (save-excursion
        (back-to-indentation)
        (and (looking-at "\\s\"")
             ;; Emacs calls the local `quote'; here that name would shadow
             ;; the reader's `'` syntax inside the `let', and `(c-point
             ;; 'boi)' would read as a call of the variable - so it is
             ;; `quote-char' (the `list'/'vector' local-name rule).
             (let ((quote-char (char-after)) (pos #f))
               (while (and (begin
                             (c-backward-syntactic-ws)
                             (eqv? (char-before) quote-char))
                           (c-safe (c-backward-sexp) #t)
                           (/= (begin (setq pos (point)) pos)
                               (c-point 'boi))))
               (when pos
                 (goto-char pos)
                 (vector (current-column)))))))

    (define (c-lineup-template-args _langelem)
      "Line up template argument lines under the first argument.
To allow this function to be used in a list expression, nil is
returned if there's no template argument on the first line.

Works with: template-args-cont."
      (save-excursion
        (beginning-of-line)
        (backward-up-list 1)
        (if (and (eqv? (char-after) #\<)
                 (= 0 (c-forward-token-2 1 #f (c-point 'eol))))
            (vector (current-column))
            #f)))

    (define (c-lineup-template-args-indented-from-margin _langelem)
      "Indent a template argument line `c-basic-offset' from the margin
of the line with the containing <.

Works with: template-args-cont."
      (save-excursion
        (goto-char (c-langelem-2nd-pos (*c-syntactic-element*)))
        (back-to-indentation)
        (vector (+ (current-column) (c-basic-offset)))))

    (define (c-lineup-ObjC-method-call langelem)
      "Line up selector args as Emacs Lisp mode does with function args:
Go to the position right after the message receiver, and if you are at
the end of the line, indent the current line `c-basic-offset' columns
from the opening bracket; otherwise you are looking at the first
character of the first method call argument, so line up the current
line with it.

Works with: objc-method-call-cont."
      (save-excursion
        (let* ((extra (save-excursion
                        (back-to-indentation)
                        (c-backward-syntactic-ws (c-langelem-pos langelem))
                        (if (eqv? (char-before) #\:)
                            (- (c-basic-offset))
                            0)))
               (open-bracket-pos (c-langelem-pos langelem))
               (open-bracket-col (begin
                                   (goto-char open-bracket-pos)
                                   (current-column)))
               (target-col (begin
                             (forward-char)
                             (c-forward-sexp)
                             (c-forward-comments (c-point 'eol))
                             (if (eolp)
                                 (+ open-bracket-col (c-basic-offset))
                                 (current-column)))))
          (- target-col open-bracket-col extra))))

    (define (c-lineup-ObjC-method-call-colons langelem)
      "Line up selector args as Project Builder / XCode: colons of first
selector portions on successive lines are aligned.  If no decision can
be made return NIL, so that other lineup methods can be tried.  This is
typically chained with `c-lineup-ObjC-method-call'.

Works with: objc-method-call-cont."
      (save-excursion
        (catch 'no-idea
          (lambda ()
          (let* ((method-arg-len (begin
                                   (back-to-indentation)
                                   (if (search-forward ":" (c-point 'eol) 'move)
                                       (- (point) (c-point 'boi))
                                       ;; "no complete argument to indent yet"
                                       (throw 'no-idea #f))))

                 (extra (save-excursion
                          ;; "indent parameter to argument if needed"
                          (back-to-indentation)
                          (c-backward-syntactic-ws (c-langelem-pos langelem))
                          (if (eqv? #\: (char-before))
                              (*c-objc-method-parameter-offset*) 0)))

                 (open-bracket-col (c-langelem-col langelem))

                 (arg-ralign-colon-ofs (begin
                                         (forward-char) ; "skip over '['"
                                         ;; "skip over object/class name and
                                         ;; first argument"
                                         (c-forward-sexp 2)
                                         (if (search-forward ":" (c-point 'eol) 'move)
                                             (- (current-column) open-bracket-col
                                                method-arg-len extra)
                                             ;; "previous arg has no param"
                                             (*c-objc-method-arg-unfinished-offset*)))))

            (if (>= arg-ralign-colon-ofs
                    (*c-objc-method-arg-min-delta-to-bracket*))
                (+ arg-ralign-colon-ofs extra)
                (throw 'no-idea #f))))
          (lambda (key . args) (car args)))))

    (define (c-lineup-ObjC-method-args langelem)
      "Line up the colons that separate args in a method declaration.
The colon on the current line is aligned with the one on the first
line.

Works with: objc-method-args-cont."
      (save-excursion
        (let* ((here (c-point 'boi))
               (curcol (begin (goto-char here) (current-column)))
               (eol (c-point 'eol))
               (relpos (c-langelem-pos langelem))
               (first-col-column (begin
                                   (goto-char relpos)
                                   (skip-chars-forward "^:" eol)
                                   (and (eqv? (char-after) #\:)
                                        (current-column)))))
          (if (not first-col-column)
              (c-basic-offset)
              (begin
                (goto-char here)
                (skip-chars-forward "^:" eol)
                (if (eqv? (char-after) #\:)
                    (+ curcol (- first-col-column (current-column)))
                    (c-basic-offset)))))))

    (define (c-lineup-ObjC-method-args-2 langelem)
      "Line up the colons that separate args in a method declaration.
The colon on the current line is aligned with the one on the previous
line.

Works with: objc-method-args-cont."
      (save-excursion
        (let* ((here (c-point 'boi))
               (curcol (begin (goto-char here) (current-column)))
               (eol (c-point 'eol))
               (relpos (c-langelem-pos langelem))
               (prev-col-column (begin
                                  (skip-chars-backward "^:" relpos)
                                  (and (eqv? (char-before) #\:)
                                       (- (current-column) 1)))))
          (if (not prev-col-column)
              (c-basic-offset)
              (begin
                (goto-char here)
                (skip-chars-forward "^:" eol)
                (if (eqv? (char-after) #\:)
                    (+ curcol (- prev-col-column (current-column)))
                    (c-basic-offset)))))))

    (define (c-lineup-inexpr-block _langelem)
      "Line up the block for constructs that use a block inside an expression,
e.g. anonymous classes in Java and lambda functions in Pike.  The body
is aligned with the start of the header, e.g. with the \"new\" or
\"lambda\" keyword.  Returns nil if the block isn't part of such a
construct.

Works with: inlambda, inexpr-statement, inexpr-class."
      (save-excursion
        (back-to-indentation)
        (let* ((paren-state (c-parse-state))
               (containing-sexp (c-most-enclosing-brace paren-state))
               (res (or (c-looking-at-inexpr-block
                         (c-safe-position containing-sexp paren-state)
                         containing-sexp)
                        (and containing-sexp
                             (begin (goto-char containing-sexp)
                                    (eqv? (char-after) #\{))
                             (begin (setq containing-sexp
                                          (c-most-enclosing-brace paren-state
                                                                  (point)))
                                    (c-looking-at-inexpr-block
                                     (c-safe-position containing-sexp
                                                      paren-state)
                                     containing-sexp))))))
          (when-e res
            (goto-char (cdr res))
            (vector (current-column))))))

    (define (c-lineup-whitesmith-in-block _langelem)
      "Line up lines inside a block in Whitesmith style.
It's done in a way that works both when the opening brace hangs and
when it doesn't.  E.g.:

something
    {                something {
    foo;     <->         foo;     <- c-lineup-whitesmith-in-block
    }                    }
                     <--> c-basic-offset

In the first case the indentation is kept unchanged, in the
second `c-basic-offset' is added.

Works with: defun-close, defun-block-intro, inline-close, block-close,
brace-list-close, brace-list-intro, enum-close, enum-intro,
statement-block-intro, arglist-intro, arglist-cont-nonempty,
arglist-close, and all in* symbols, e.g. inclass and inextern-lang."
      (save-excursion
        (beginning-of-line)
        (if (and (c-go-up-list-backward)
                 (= (point) (c-point 'boi)))
            #f
            (c-basic-offset))))

    (define (c-lineup-after-whitesmith-blocks langelem)
      "Compensate for Whitesmith style indentation of blocks.
Due to the way CC Mode calculates anchor positions for normal lines
inside blocks, this function is necessary for those lines to get
correct Whitesmith style indentation.

This lineup function corrects for this situation by detecting if the
anchor position is at an open paren character.  In that case, it
instead indents relative to the surrounding block just like
`c-lineup-whitesmith-in-block'.

Works with: brace-list-entry, brace-entry-open, enum-entry,
statement, arglist-cont."
      (save-excursion
        (goto-char (c-langelem-pos langelem))
        (when-e (looking-at "\\s(")
          (if (c-go-up-list-backward)
              (let ((pos (point)))
                (back-to-indentation)
                (if (= pos (point))
                    (vector (current-column))
                    (vector (+ (current-column) (c-basic-offset)))))
              (vector 0)))))

    (define (c-lineup-2nd-brace-entry-in-arglist _langelem)
      "Lineup the second entry of a brace block under the first, when the first
line is also contained in an arglist or an enclosing brace ON THAT LINE.

This function is intended for use in a list.  If the construct
being analyzed isn't like the preceding, the function returns nil.
Otherwise it returns the function `c-lineup-arglist-intro-after-paren', which
the caller then uses to perform indentation.

Works with brace-list-intro."
      ;; "brace-list-intro and brace-list-entry are both present for the
      ;; second entry of the list when the first entry is on the same
      ;; line as the opening brace."
      (and (assq 'brace-list-intro (*c-syntactic-context*))
           (assq 'brace-list-entry (*c-syntactic-context*))
           (or (assq 'arglist-cont-nonempty (*c-syntactic-context*))
               ;; "\"(\" earlier on the line."
               (save-excursion   ; "\"{\" earlier on the line"
                 (goto-char (c-langelem-pos
                             (assq 'brace-list-entry
                                   (*c-syntactic-context*))))
                 (and
                  (eqv? (c-backward-token-2
                         1 #f
                         (c-point 'bol (c-langelem-pos
                                        (assq 'brace-list-entry
                                              (*c-syntactic-context*)))))
                        0)
                  (eqv? (char-after) #\{))))
           'c-lineup-arglist-intro-after-paren))

    (define (c-lineup-class-decl-init-+ _langelem)
      "Line up the second entry of a class (etc.) initializer c-basic-offset
characters in from the identifier when:
\\(i) The type is a class, struct, union, etc. (but not an enum);
\\(ii) There is a brace block in the type declaration, specifying it; and
\\(iii) The first element of the initializer is on the same line as its opening
brace.

Note that the syntactic context of the brace-list-intro line also has a
syntactic element with the symbol brace-list-entry.

This function is intended for use in a list.  If the above structure isn't
present, this function returns nil, allowing a different offset specification
to indent the line.

Works with: brace-list-intro."
      (and (assq 'brace-list-intro (*c-syntactic-context*))
           (assq 'brace-list-entry (*c-syntactic-context*))
           (let ((init-pos (c-point 'boi (c-langelem-pos
                                          (assq 'brace-list-entry
                                                (*c-syntactic-context*))))))
             (save-excursion
               (goto-char (c-langelem-pos (assq 'brace-list-intro
                                                (*c-syntactic-context*))))
               (and
                (c-forward-class-decl)
                (not (c-do-declarators init-pos #t #f #f #f))
                (eqv? (point) init-pos)
                (vector (+ (current-column) (c-basic-offset))))))))

    (define (c-lineup-class-decl-init-after-brace _langelem)
      "Line up the second entry of a class (etc.) initializer after its opening
brace when:
\\(i) The type is a class, struct, union, etc. (but not an enum);
\\(ii) There is a brace block in the type declaration, specifying it; and
\\(iii) The first element of the initializer is on the same line as its opening
brace.

Note that the syntactic context of the brace-list-intro line also has a
syntactic element with the symbol brace-list-entry.  Also note that this
function works by returning the symbol `c-lineup-arglist-intro-after-paren',
which the caller then uses to perform the indentation.

This function is intended for use in a list.  If the above structure isn't
present, this function returns nil, allowing a different offset specification
to indent the line.

Works with: brace-list-intro."
      (and (assq 'brace-list-intro (*c-syntactic-context*))
           (assq 'brace-list-entry (*c-syntactic-context*))
           (let ((init-pos (c-point 'boi (c-langelem-pos
                                          (assq 'brace-list-entry
                                                (*c-syntactic-context*))))))
             (save-excursion
               (goto-char (c-langelem-pos (assq 'brace-list-intro
                                                (*c-syntactic-context*))))
               (and
                (c-forward-class-decl)
                (not (c-do-declarators init-pos #t #f #f #f))
                (eqv? (point) init-pos)
                'c-lineup-arglist-intro-after-paren)))))

    (define (c-lineup-cpp-define _langelem)
      "Line up macro continuation lines according to the indentation of
the construct preceding the macro.

If `c-syntactic-indentation-in-macros' is non-nil, the function
returns the relative indentation to the macro start line to allow
accumulation with other offsets.

If the relative indentation is zero, then nil is returned instead.
That is useful in a list expression to specify the default indentation
on the top level.

If `c-syntactic-indentation-in-macros' is nil then this function keeps
the current indentation, except for empty lines (ignoring the ending
backslash) where it takes the indentation from the closest preceding
nonempty line in the macro.  If there's no such line in the macro then
the indentation is taken from the construct preceding it, as described
above.

Works with: cpp-define-intro."
      (let ((offset #f))
        (if (*c-syntactic-indentation-in-macros*)
            ;; "Go to the macro start and do a syntactic analysis of it.
            ;; Then remove the cpp-macro element it should contain and
            ;; calculate the indentation it then would get."
            (save-excursion
              (c-beginning-of-macro)
              (setq offset (- (c-get-syntactic-indentation
                               (delete '(cpp-macro) (c-guess-basic-syntax)))
                              (save-excursion
                                (back-to-indentation)
                                (current-column))))
              (if (= offset 0)
                  #f
                  offset))
            ;; "Do not indent syntactically inside the macro."
            (save-excursion
              (let ((macro-start-line (save-excursion
                                        (goto-char (c-query-macro-start))
                                        (beginning-of-line)
                                        (point))))
                (beginning-of-line)
                ;; "Check every line while inside the macro."
                (while (and (> (point) macro-start-line)
                            (looking-at "[ \t]*\\\\?$")
                            (= (forward-line -1) 0)))
                (if (<= (point) macro-start-line)
                    ;; "If we've stepped out of the macro we take the
                    ;; syntactic offset."
                    (setq offset (c-get-syntactic-indentation
                                  (delete '(cpp-macro) (c-guess-basic-syntax))))
                    (setq offset (current-indentation)))
                (if (= offset 0)
                    #f
                    (vector offset)))))))

    ;; "Contributed by Kevin Ryde <user42@zip.com.au>."
    (define (c-lineup-gcc-asm-reg elem)
      "Line up a gcc asm register under one on a previous line.

    asm (\"foo %1, %0\\n\"
         \"bar %0, %1\"
         : \"=r\" (w),
           \"=r\" (x)
         :  \"0\" (y),
            \"1\" (z));

The \"x\" line is aligned to the text after the \":\" on the \"w\" line, and
similarly \"z\" under \"y\".

This is done only in an \"asm\" or \"__asm__\" block, and only to
those lines mentioned.  Anywhere else nil is returned.

Works with: arglist-cont, arglist-cont-nonempty."
      (let ((orig-pos (point)) (alignto #f))
        (save-excursion
          (beginning-of-line)
          (and
           (%c-langvar 'c-opt-asm-stmt-key)

           ;; "Don't do anything if the innermost open paren isn't our
           ;; one. This can occur for arglist-cont-nonempty with nested
           ;; arglist starts on the same line."
           (or (not (eq? (car elem) 'arglist-cont-nonempty))
               (eq? (c-langelem-2nd-pos (*c-syntactic-element*))
                    (c-most-enclosing-brace (c-parse-state))))

           ;; "Find the \":\" to align to. Look for this first so as to
           ;; quickly eliminate pretty much all cases which are not for
           ;; us."
           (re-search-backward "^[ \t]*:[ \t]*\\(.\\)?"
                               (if (pair? (cdr elem)) (cdr elem) #f) #t)

           ;; "Must have something after the \":\"."
           (setq alignto (match-beginning 1))

           ;; "Don't touch \":\" lines themselves."
           (begin (goto-char orig-pos)
                  (beginning-of-line)
                  (not (looking-at "^[ \t]*:")))

           ;; "Only operate in an asm statement."
           (begin (goto-char orig-pos)
                  (c-in-gcc-asm-p))

           (vector (begin (goto-char alignto) (current-column)))))))

    (define (c-lineup-under-anchor langelem)
      "Line up the current line directly under the anchor position in LANGELEM.

This is like 0, except it supersedes any indentation already calculated for
previous syntactic elements in the syntactic context.

Works with: Any syntactic symbol which has an anchor position."
      (save-excursion
        (goto-char (c-langelem-pos langelem))
        (vector (current-column))))

    (define (c-lineup-dont-change _langelem)
      "Do not change the indentation of the current line.

Works with: Any syntactic symbol."
      (save-excursion
        (back-to-indentation)
        (vector (current-column))))

    (define (c-lineup-respect-col-0 _langelem)
      "If the current line starts at column 0, return [0]. Otherwise return nil.

This can be used for comments (in conjunction with, say,
`c-lineup-comment'), to keep comments already at column 0
anchored there, but reindent other comments."
      (save-excursion
        (back-to-indentation)
        (if (= (current-column) 0)
            (vector 0)
            #f)))

    (define (c-snug-do-while syntax _pos)
      "Dynamically calculate brace hanginess for do-while statements.
Using this function, `while' clauses that end a `do-while' block will
remain on the same line as the brace that closes that block.

See `c-hanging-braces-alist' for how to utilize this function as an
ACTION associated with `block-close' syntax."
      (save-excursion
        (let ((langelem #f))
          (if (and (eq? syntax 'block-close)
                   (begin
                     (setq langelem (assq 'block-close
                                          (*c-syntactic-context*)))
                     langelem)
                   (begin (goto-char (c-langelem-pos langelem))
                          (if (eqv? (char-after) #\{)
                              (c-safe (c-forward-sexp -1)))
                          (looking-at "\\_<do\\_>")))
              '(before)
              '(before after)))))

    (define (c-snug-1line-defun-close _syntax pos)
      "Determine the brace hanginess for an AWK defun-close.
If the action/function being closed is a one-liner, keep it so.  Otherwise put
the closing brace on its own line."
      (save-excursion
        (goto-char pos)
        (if (> (c-point 'bol)
               (begin (up-list -1) (point)))
            '(before after)
            '(after))))

    (define (c-gnu-impose-minimum)
      "Imposes a minimum indentation for lines inside code blocks.
The variable `c-label-minimum-indentation' specifies the minimum
indentation amount."
      (when-e (and (not
                    ;; "Don't adjust macro or comment-only lines."
                    (or (assq 'cpp-macro (*c-syntactic-context*))
                        (assq 'comment-intro (*c-syntactic-context*))))
                   (c-intersect-lists c-inside-block-syms
                                      (*c-syntactic-context*))
                   (save-excursion
                     (back-to-indentation)
                     (< (current-column) (c-label-minimum-indentation))))
        (c-shift-line-indentation (- (c-label-minimum-indentation)
                                     (current-indentation)))))

    ;;--------------------------------------------------------------
    ;; Useful for c-hanging-semi&comma-criteria
    ;;--------------------------------------------------------------
    ;; **`c-last-command-char' answers an event, and an event is an
    ;; integer** (`keyboard.c:8301': a character key is its byte code).
    ;; Emacs's `?\;\' is that same integer; Guile's `#\;' is a character
    ;; object and never `eqv?' to it, so the comparisons spell the
    ;; conversion out (`char->integer').

    (define (c-semi&comma-inside-parenlist)
      "Controls newline insertion after semicolons in parenthesis lists.
If a comma was inserted, no determination is made.  If a semicolon was
inserted inside a parenthesis list, no newline is added otherwise a
newline is added.  In either case, checking is stopped.  This supports
exactly the old newline insertion behavior."
      ;; "newline only after semicolon, but only if that semicolon is
      ;; not inside a parenthesis list (e.g. a for loop statement)"
      (if (not (eqv? (c-last-command-char) (char->integer #\;)))
          #f                            ; "continue checking"
          (if (guard (e ((quit-condition? e) (raise e))
                        (else #t))              ; "error t"
                (save-excursion
                  (up-list -1)
                  (not (eqv? (char-after) #\())))
              #t
              'stop)))

    ;; "Suppresses newlines before non-blank lines"
    (define (c-semi&comma-no-newlines-before-nonblanks)
      "Controls newline insertion after semicolons.
If a comma was inserted, no determination is made.  If a semicolon was
inserted, and the following line is not blank, no newline is inserted.
Otherwise, no determination is made."
      (save-excursion
        (if (and (eqv? (c-last-command-char) (char->integer #\;))
                 (= (forward-line 1) 0)
                 (bolp)                 ; "forward-line has funny behavior at eob."
                 (not (looking-at "^[ \t]*$")))
            'stop
            #f)))

    ;; "Suppresses new lines after semicolons in one-liners methods"
    (define (c-semi&comma-no-newlines-for-oneline-inliners)
      "Controls newline insertion after semicolons for some one-line methods.
If a comma was inserted, no determination is made.  Newlines are
suppressed in one-liners, if the line is an in-class inline function.
For other semicolon contexts, no determination is made."
      (let ((syntax (c-guess-basic-syntax))
            (bol (save-excursion
                   (if (c-safe (up-list -1) #t)
                       (c-point 'bol)
                       -1))))
        (if (and (eqv? (c-last-command-char) (char->integer #\;))
                 (eq? (car-safe (car-safe syntax)) 'inclass)
                 (eq? (car-safe (car-safe (cdr-safe syntax))) 'topmost-intro)
                 (= (c-point 'bol) bol))
            'stop
            #f)))

    ;;--------------------------------------------------------------
    ;; The registrations: Emacs's function obarray, as this tree
    ;; spells it (`c-evaluate-offset''s `functionp' arm and
    ;; `c-valid-offset''s name test). Nothing may be defined after
    ;; this point without a registration of its own.
    ;;--------------------------------------------------------------
    (define %lineup-functions
      (list
       (cons 'c-lineup-topmost-intro-cont c-lineup-topmost-intro-cont)
       (cons 'c-lineup-class-field-cont c-lineup-class-field-cont)
       (cons 'c-lineup-gnu-DEFUN-intro-cont c-lineup-gnu-DEFUN-intro-cont)
       (cons 'c-block-in-arglist-dwim c-block-in-arglist-dwim)
       (cons 'c-lineup-arglist c-lineup-arglist)
       (cons 'c-lineup-argcont-1 c-lineup-argcont-1)
       (cons 'c-lineup-argcont-scan c-lineup-argcont-scan)
       (cons 'c-lineup-argcont c-lineup-argcont)
       (cons 'c-lineup-argcont-+ c-lineup-argcont-+)
       (cons 'c-lineup-arglist-intro-after-paren c-lineup-arglist-intro-after-paren)
       (cons 'c-lineup-item-after-paren-at-boi c-lineup-item-after-paren-at-boi)
       (cons 'c-lineup-arglist-close-under-paren c-lineup-arglist-close-under-paren)
       (cons 'c-lineup-arglist-operators c-lineup-arglist-operators)
       (cons 'c-lineup-close-paren c-lineup-close-paren)
       (cons 'c-lineup-streamop c-lineup-streamop)
       (cons 'c-lineup-multi-inher c-lineup-multi-inher)
       (cons 'c-lineup-java-inher c-lineup-java-inher)
       (cons 'c-lineup-java-throws c-lineup-java-throws)
       (cons 'c-indent-one-line-block c-indent-one-line-block)
       (cons 'c-indent-multi-line-block c-indent-multi-line-block)
       (cons 'c-lineup-C-comments c-lineup-C-comments)
       (cons 'c-lineup-comment c-lineup-comment)
       (cons 'c-lineup-knr-region-comment c-lineup-knr-region-comment)
       (cons 'c-lineup-runin-statements c-lineup-runin-statements)
       (cons 'c-lineup-assignments c-lineup-assignments)
       (cons 'c-lineup-math c-lineup-math)
       (cons 'c-lineup-ternary-bodies c-lineup-ternary-bodies)
       (cons 'c-lineup-cascaded-calls c-lineup-cascaded-calls)
       (cons 'c-lineup-string-cont c-lineup-string-cont)
       (cons 'c-lineup-template-args c-lineup-template-args)
       (cons 'c-lineup-template-args-indented-from-margin
             c-lineup-template-args-indented-from-margin)
       (cons 'c-lineup-ObjC-method-call c-lineup-ObjC-method-call)
       (cons 'c-lineup-ObjC-method-call-colons c-lineup-ObjC-method-call-colons)
       (cons 'c-lineup-ObjC-method-args c-lineup-ObjC-method-args)
       (cons 'c-lineup-ObjC-method-args-2 c-lineup-ObjC-method-args-2)
       (cons 'c-lineup-inexpr-block c-lineup-inexpr-block)
       (cons 'c-lineup-whitesmith-in-block c-lineup-whitesmith-in-block)
       (cons 'c-lineup-after-whitesmith-blocks c-lineup-after-whitesmith-blocks)
       (cons 'c-lineup-2nd-brace-entry-in-arglist c-lineup-2nd-brace-entry-in-arglist)
       (cons 'c-lineup-class-decl-init-+ c-lineup-class-decl-init-+)
       (cons 'c-lineup-class-decl-init-after-brace c-lineup-class-decl-init-after-brace)
       (cons 'c-lineup-cpp-define c-lineup-cpp-define)
       (cons 'c-lineup-gcc-asm-reg c-lineup-gcc-asm-reg)
       (cons 'c-lineup-under-anchor c-lineup-under-anchor)
       (cons 'c-lineup-dont-change c-lineup-dont-change)
       (cons 'c-lineup-respect-col-0 c-lineup-respect-col-0)
       (cons 'c-snug-do-while c-snug-do-while)
       (cons 'c-snug-1line-defun-close c-snug-1line-defun-close)
       (cons 'c-gnu-impose-minimum c-gnu-impose-minimum)
       (cons 'c-semi&comma-inside-parenlist c-semi&comma-inside-parenlist)
       (cons 'c-semi&comma-no-newlines-before-nonblanks c-semi&comma-no-newlines-before-nonblanks)
       (cons 'c-semi&comma-no-newlines-for-oneline-inliners c-semi&comma-no-newlines-for-oneline-inliners)))

    (for-each
     (lambda (entry)
       (c-register-lineup-function! (car entry) (cdr entry))
       (c-register-offset-function-name! (car entry)))
     %lineup-functions)

    ))
