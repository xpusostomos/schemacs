(define-library (schemacs editor cc-vars)
  ;; `lisp/progmodes/cc-vars.el', the variables the rest of the cc-mode
  ;; port has needed first: the syntactic-indentation switches, the
  ;; font-lock extra-type lists, and the plain-variable/buffer-local-bit
  ;; ones. The file is deliberately partial: the style system
  ;; (`c-offsets-alist', `c-hanging-braces-alist', `defcustom-c-stylevar'
  ;; and the rest) arrives with `cc-styles' and `cc-engine', which are
  ;; what read it.
  ;;
  ;; Every default here was measured on Emacs 31.1 (`emacs -Q --batch'
  ;; printing `(symbol-value V)') and is pinned in
  ;; `cc-vars-tests.scm'. The docstrings are Emacs's, and the
  ;; extra-type ones are built by the ported
  ;; `c-make-font-lock-extra-types-blurb'.
  ;;
  ;; **Representation departures**, the tree's usual ones: a
  ;; `defcustom' is a parameter whose name carries stars
  ;; (`*c-syntactic-indentation*'), and the two buffer-local `defvar's
  ;; are buffer-local slots behind accessors of the variable's name
  ;; (`c-current-comment-prefix') and a `set!'-prefixed setter.
  (import
    (scheme base)
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor buffer) current-buffer buffer-local-value
          set-buffer-local-value!)
    (only (schemacs editor cc-defs) c-upper c-lower
          c-register-emacs-variable-reader!)
    (only (schemacs editor fns) concat)
    ;; The defaults of the three function-valued defcustoms added for
    ;; cc-cmds: a function is a procedure here, so the defcustom holds
    ;; the procedure rather than Emacs's symbol (`insert-tab' is
    ;; `indent.el`'s, `backward-delete-char-untabify' is `simple.el`'s,
    ;; `delete-char' is `cmds.c`'s).
    (only (schemacs editor indent) insert-tab)
    (only (schemacs editor simple) backward-delete-char-untabify)
    (only (schemacs editor cmds) delete-char)
    (only (schemacs editor subr) regexp-unmatchable)
    (only (schemacs editor symbol-props) put get)
    ;; `c-default-value-sentence-end' (`cc-defs.el:580') calls
    ;; `(sentence-end)' with the variable bound to nil; the macro is in
    ;; cc-defs, and these are what its expansion needs.
    (only (schemacs editor paragraphs) sentence-end *sentence-end*)
    (only (schemacs regexp-opt) regexp-opt))

  (export c-make-font-lock-extra-types-blurb c-string-list-p
          *c-syntactic-indentation* *c-syntactic-indentation-in-macros*
          c-syntactic-indentation set!c-syntactic-indentation
          *c-tab-always-indent* *c-insert-tab-function*
          *c-ignore-auto-fill* *c-defun-tactic*
          *c-echo-syntactic-information-p*
          *c-auto-align-backslashes* *c-backspace-function*
          *c-delete-function* *c-require-final-newline*
          *c-electric-pound-behavior* *c-progress-interval*
          *c-max-one-liner-length* *c-cpp-indent-to-body-directives*
          *c-warn-ids-with-dollar* *c-mark-wrong-style-of-comment*
          *c-asymmetry-fontification-flag*
          *c-font-lock-extra-types* *c++-font-lock-extra-types*
          *objc-font-lock-extra-types* *java-font-lock-extra-types*
          *idl-font-lock-extra-types* *pike-font-lock-extra-types*
          c-style-variables c-fallback-style
          c-set-stylevar-fallback c-stylevar-fallback
          c-style-variable-register! c-style-variable-value
          c-style-variable-bound?
          c-style-variable-set! c-style-variable-default
          *c-basic-offset* c-basic-offset set!c-basic-offset
          *c-comment-only-line-offset* c-comment-only-line-offset
          set!c-comment-only-line-offset
          *c-indent-comment-alist* c-indent-comment-alist
          set!c-indent-comment-alist
          *c-indent-comments-syntactically-p*
          c-indent-comments-syntactically-p
          set!c-indent-comments-syntactically-p
          *c-block-comment-prefix* c-block-comment-prefix
          set!c-block-comment-prefix
          *c-comment-prefix-regexp* c-comment-prefix-regexp
          set!c-comment-prefix-regexp
          *c-doc-comment-style* c-doc-comment-style set!c-doc-comment-style
          *c-cleanup-list* c-cleanup-list set!c-cleanup-list
          *c-hanging-braces-alist* c-hanging-braces-alist
          set!c-hanging-braces-alist
          *c-hanging-colons-alist* c-hanging-colons-alist
          set!c-hanging-colons-alist
          *c-hanging-semi&comma-criteria* c-hanging-semi&comma-criteria
          set!c-hanging-semi&comma-criteria
          *c-backslash-column* c-backslash-column set!c-backslash-column
          *c-backslash-max-column* c-backslash-max-column
          set!c-backslash-max-column
          *c-special-indent-hook* c-special-indent-hook
          set!c-special-indent-hook
          *c-label-minimum-indentation* c-label-minimum-indentation
          set!c-label-minimum-indentation
          *c-offsets-alist* c-offsets-alist set!c-offsets-alist
          *c-style-variables-are-local-p* *c-old-style-variable-behavior*
          *c-default-style*
          c-string-par-start c-string-par-separate
          c-sentence-end-with-esc-eol c-default-value-sentence-end
          c-valid-offset c-string-or-string-list-p
          *c-syntactic-context* *c-syntactic-element*
          *c-strict-syntax-p*
          c-indentation-style set!c-indentation-style
          c-current-comment-prefix set!c-current-comment-prefix
          c-block-comment-flag set!c-block-comment-flag
          c-macro-with-semi-re set!c-macro-with-semi-re
          c-macro-names-with-semicolon set!c-macro-names-with-semicolon
          c-make-macro-with-semi-re
          *c-report-syntactic-errors*
          c-noise-macro-name-re set!c-noise-macro-name-re
          c-noise-macro-with-parens-name-re set!c-noise-macro-with-parens-name-re
          *c-noise-macro-names* *c-noise-macro-with-parens-names*
          c-make-noise-macro-regexps
          c-inside-block-syms
          *c-objc-method-arg-min-delta-to-bracket*
          *c-objc-method-arg-unfinished-offset*
          *c-objc-method-parameter-offset*
          c-register-offset-function-name!)

  (begin

    (define (c-make-font-lock-extra-types-blurb mode1 mode2 example)
      ;; `cc-vars.el:1571': the shared text every
      ;; `*-font-lock-extra-types' docstring is built from.
      (string-append
       "List of extra types (aside from the type keywords) to recognize in "
       mode1 " mode.
Each list item should be a regexp matching a single identifier.
" example "

Note that items on this list that don't include any regexp special
characters are automatically optimized using `regexp-opt', so you
should not use `regexp-opt' explicitly to build regexps here.

On decoration level 3 (and higher, where applicable), a method is used
that finds most types and declarations by syntax alone.  This variable
is still used as a first step, but other types are recognized
correctly anyway in most cases.  Therefore this variable should be
fairly restrictive and not contain patterns that are uncertain.

Note that this variable is only consulted when the major mode is
initialized.  If you change it later you have to reinitialize CC Mode
by doing \\[" mode2 "].

Despite the name, this variable is not only used for font locking but
also elsewhere in CC Mode to tell types from other identifiers."))

    (define (c-string-list-p val)
      ;; "Return non-nil if VAL is a list of strings."
      (and (list? val)
           (let loop ((l val))
             (or (null? l)
                 (and (string? (car l)) (loop (cdr l)))))))

    ;;------------------------------------------------------------------
    ;; The defcustoms (parameters, per the tree's convention)
    ;;------------------------------------------------------------------
    ;; `cc-vars.el:490' and `:512' - the two options TAB's behaviour
    ;; stands on. `c-insert-tab-function' holds a procedure here (a
    ;; symbol is not callable in Scheme); Emacs holds `'insert-tab'.
    (define-custom *c-tab-always-indent* #t
      "Controls the operation of the TAB key.
If t, hitting TAB always just indents the current line.  If nil, hitting
TAB indents the current line if point is at the left margin or in the
line's indentation, otherwise it inserts a `real' tab character (see
note).  If some other value (not nil or t), then tab is inserted only
within literals (comments and strings), but the line is always
reindented."
      :type '(radio
              (const :tag "TAB key always indents, never inserts TAB" t)
              (const :tag "TAB key indents in left margin, otherwise inserts TAB" nil)
              (other :tag "TAB key inserts TAB in literals, otherwise indents" other))
      :group 'c)

    (define-custom *c-insert-tab-function* insert-tab
      "Function used when inserting a tab for \\[c-indent-command].
Only used when `c-tab-always-indent' indicates a `real' tab character
should be inserted.  Value must be a function taking no arguments.
The default, `insert-tab', inserts either a tab or the equivalent
number of spaces depending on the value of `indent-tabs-mode'."
      :type 'function
      :group 'c)

    (define-custom *c-syntactic-indentation* #t
      "Whether the indentation should be controlled by the syntactic context.

If t, the indentation functions indent according to the syntactic
context, using the style settings specified by `c-offsets-alist'.

If nil, every line is just indented to the same level as the previous
one, and the \\[c-indent-command] command adjusts the indentation in
steps specified by `c-basic-offset'.  The indentation style has no
effect in this mode, nor any of the indentation associated variables,
e.g. `c-special-indent-hook'."
      :type 'boolean
      :group 'c)

    ;; `(make-variable-buffer-local 'c-syntactic-indentation)'
    ;; (`cc-vars.el:530'): the buffer-local entry wins over the
    ;; parameter, the pattern the style variables use.
    (define (c-syntactic-indentation)
      (buffer-local-value (current-buffer) 'c-syntactic-indentation
                          (*c-syntactic-indentation*)))
    (define (set!c-syntactic-indentation value)
      (set-buffer-local-value! (current-buffer) 'c-syntactic-indentation value))

    (define-custom *c-syntactic-indentation-in-macros* #t
      "Enable syntactic analysis inside macros.
If this is nil, all lines inside macro definitions are analyzed as
`cpp-macro-cont'.  Otherwise they are analyzed syntactically, just
like normal code, and `cpp-define-intro' is used to create the
additional indentation of the bodies of \"#define\" macros.

Having this enabled simplifies editing of large multiline macros, but
it might complicate editing if CC Mode doesn't recognize the context
of the macro content.  The default context inside the macro is the
same as the top level, so if it contains \"bare\" statements they
might be indented wrongly, although there are special cases that
handle this in most cases.  If this problem occurs, it's usually
countered easily by surrounding the statements by a block (or even
better with the \"do { ... } while (0)\" trick)."
      :type 'boolean
      :group 'c)

    (define-custom *c-defun-tactic* 'go-outward
      "Whether functions are recognized inside, e.g., a class.
This is used by `c-beginning-of-defun' and like functions.

Its value is one of:
 t           -- Functions are recognized only at the top level.
 go-outward  -- Nested functions are also recognized.  Should a function
                command hit the beginning/end of a nested scope, it will
                carry on at the less nested level."
      :version "24.1"
      :type '(radio
              (const :tag "Functions are at the top-level" t)
              (const :tag "Functions are also recognized inside declaration scopes" go-outward))
      :group 'c)

    (define-custom *c-ignore-auto-fill* '(string cpp code)
      "List of contexts in which automatic filling never occurs.
If Auto Fill mode is active, it will be temporarily disabled if point
is in any context on this list.  It's e.g. useful to enable Auto Fill
in comments only, but not in strings or normal code.  The valid
contexts are:

 string  -- inside a string or character literal
 c       -- inside a C style block comment
 c++     -- inside a C++ style line comment
 cpp     -- inside a preprocessor directive
 code    -- anywhere else, i.e. in normal code"
      :type '(set
              (const :tag "String literals" string)
              (const :tag "C style block comments" c)
              (const :tag "C++ style line comments" c++)
              (const :tag "Preprocessor directives" cpp)
              (const :tag "Normal code" code))
      :group 'c)

    ;; The three Objective-C line-up parameters (`cc-vars.el:1169'-`:1215').
    ;; `c-lineup-ObjC-method-call-colons' reads them.
    (define-custom *c-objc-method-arg-min-delta-to-bracket* 2
      "Minimum number of chars to the opening bracket.

Consider this ObjC snippet:

	[foo blahBlah: fred
	|<-x->|barBaz: barney

If `x' is less than this number then `c-lineup-ObjC-method-call-colons'
will defer the indentation decision to the next function.  By default
this is `c-lineup-ObjC-method-call', which would align it like:

	[foo blahBlahBlah: fred
	     thisIsTooDamnLong: barney

This behavior can be overridden by customizing the indentation of
`objc-method-call-cont' in the \"objc\" style."
      :type 'integer
      :group 'c)

    (define-custom *c-objc-method-arg-unfinished-offset* 4
      "Offset relative to bracket if first selector is on a new line.

    [aaaaaaaaa
    |<-x->|bbbbbbb:  cccccc
             ddddd: eeee];"
      :type 'integer
      :group 'c)

    (define-custom *c-objc-method-parameter-offset* 4
      "Offset for selector parameter on a new line (relative to first selector.

    [aaaaaaa bbbbbbbbbb:
	     |<-x->|cccccccc
                    ddd: eeee
                   ffff: ggg];"
      :type 'integer
      :group 'c)

    (define-custom *c-warn-ids-with-dollar* #f
      "Fontify identifiers with a dollar character in font-lock-warn-face.
This has effect only for languages in which `c-dollar-in-ids' is
non-nil, e.g.  C, C++, Objective C.  It covers languages where
\"$\" is permitted in ids \"informally\", but only by some compilers."
      :type 'boolean
      :version "30.1"
      :group 'c)

    (define-custom *c-mark-wrong-style-of-comment* #f
      "Fontify \"invalid\" comment delims with `font-lock-warning-face' if non-nil.
\"Invalid\" means a line comment when the default comment style (set by
`c-toggle-comment-style') is block, or a block comment otherwise."
      :type 'boolean
      :version "27.1"
      :group 'c)

    (define-custom *c-asymmetry-fontification-flag* #t
      "Whether to fontify certain ambiguous constructs by white space asymmetry.

In the fontification engine, it is sometimes impossible to determine
whether a construct is a declaration or an expression.  This happens
particularly in C++, due to ambiguities in the language.  When such a
construct is like \"foo * bar\" or \"foo &bar\", and this variable is non-nil
(the default), the construct will be fontified as a declaration if there is
white space either before or after the operator, but not both."
      :version "26.1"
      :type 'boolean
      :group 'c)

    (define-custom *c-font-lock-extra-types*
      '("\\sw+_t" "bool" "complex" "imaginary"
        "FILE" "lconv" "tm" "va_list" "jmp_buf"
        "Lisp_Object")
      (c-make-font-lock-extra-types-blurb "C" "c-mode"
        "For example, a value of (\"FILE\" \"\\\\sw+_t\") means the word \"FILE\"
and words ending in \"_t\" are treated as type names.")
      :type 'c-extra-types-widget
      :group 'c)

    (define-custom *c++-font-lock-extra-types*
      '("\\sw+_t"
        "FILE" "lconv" "tm" "va_list" "jmp_buf"
        "istream" "istreambuf"
        "ostream" "ostreambuf"
        "ifstream" "ofstream" "fstream"
        "strstream" "strstreambuf" "istrstream" "ostrstream"
        "ios"
        "string" "rope"
        "list" "slist"
        "deque" "vector" "bit_vector"
        "set" "multiset"
        "map" "multimap"
        "hash"
        "hash_set" "hash_multiset"
        "hash_map" "hash_multimap"
        "stack" "queue" "priority_queue"
        "type_info"
        "iterator" "const_iterator" "reverse_iterator" "const_reverse_iterator"
        "reference" "const_reference")
      (c-make-font-lock-extra-types-blurb "C++" "c++-mode"
        "For example, a value of (\"string\") means the word \"string\" is treated
as a type name.")
      :type 'c-extra-types-widget
      :group 'c)

    (define-custom *objc-font-lock-extra-types* '()
      (c-make-font-lock-extra-types-blurb "ObjC" "objc-mode"
        (string-append
         "For example, a value of (\"[" c-upper "]\\\\sw*[" c-lower "]\\\\sw*\") means
capitalized words are treated as type names (the requirement for a
lower case char is to avoid recognizing all-caps macro and constant
names)."))
      :type 'c-extra-types-widget
      :group 'c)

    (define-custom *java-font-lock-extra-types*
      (list (string-append "[" c-upper "]\\sw*[" c-lower "]\\sw"))
      (c-make-font-lock-extra-types-blurb "Java" "java-mode"
        (string-append
         "For example, a value of (\"[" c-upper "]\\\\sw*[" c-lower "]\\\\sw*\") means
capitalized words are treated as type names (the requirement for a
lower case char is to avoid recognizing all-caps constant names)."))
      :type 'c-extra-types-widget
      :group 'c)

    (define-custom *idl-font-lock-extra-types* '()
      (c-make-font-lock-extra-types-blurb "IDL" "idl-mode" "")
      :type 'c-extra-types-widget
      :group 'c)

    (define-custom *pike-font-lock-extra-types*
      (list (string-append "[" c-upper "]\\sw*[" c-lower "]\\sw*"))
      (c-make-font-lock-extra-types-blurb "Pike" "pike-mode"
        (string-append
         "For example, a value of (\"[" c-upper "]\\\\sw*[" c-lower "]\\\\sw*\") means
capitalized words are treated as type names (the requirement for a
lower case char is to avoid recognizing all-caps macro and constant
names)."))
      :type 'c-extra-types-widget
      :group 'c)

    ;;------------------------------------------------------------------
    ;; The style system's machinery (`cc-vars.el:155'-`:208')
    ;;------------------------------------------------------------------
    ;; `c-style-variables' is the list the style system sets;
    ;; `c-fallback-style` is what a style with no base resolves to, and
    ;; each variable's *standard* value is kept on its symbol's
    ;; `c-stylevar-fallback' property (`cc-defs.el' declares the
    ;; variables, `cc-styles.el' applies them).

    (define c-style-variables
      '(c-basic-offset c-comment-only-line-offset c-indent-comment-alist
        c-indent-comments-syntactically-p c-block-comment-prefix
        c-comment-prefix-regexp c-doc-comment-style c-cleanup-list
        c-hanging-braces-alist c-hanging-colons-alist
        c-hanging-semi&comma-criteria c-backslash-column
        c-backslash-max-column c-special-indent-hook
        c-label-minimum-indentation c-offsets-alist))

    (define c-fallback-style '())

    (define (c-set-stylevar-fallback name val)
      ;; "Arrange for the fallback value of NAME to be VAL" - the
      ;; property `c-get-style-variables' reads for a style-less
      ;; resolution, plus the accumulated alist.
      (put name 'c-stylevar-fallback val)
      (set! c-fallback-style (cons (cons name val) c-fallback-style)))

    (define (c-stylevar-fallback name)
      ;; The fallback registered for NAME, or #f.
      (get name 'c-stylevar-fallback))

    ;; Emacs reaches a style variable through `symbol-value' and sets it
    ;; with `set' - the style system's whole interface (`c-set-style-1',
    ;; `c-initialize-builtin-style'). There is no such reflection on a
    ;; Scheme binding, so each style variable registers the readers and
    ;; writer it is made of: the buffer's value (the `symbol-value' the
    ;; accessors give), the setter, and the global default (`default-value'
    ;; - the parameter behind the buffer-local slot). `c-set-style-1' and
    ;; its callers dispatch on the symbol through these three.
    (define %c-style-variable-table '())

    (define (c-style-variable-register! name reader writer default-reader)
      (set! %c-style-variable-table
            (cons (cons name (vector reader writer default-reader))
                  %c-style-variable-table)))

    (define (c-style-variable-value name)
      (let ((entry (assq name %c-style-variable-table)))
        (and entry ((vector-ref (cdr entry) 0)))))

    (define (c-style-variable-bound? name)
      ;; Emacs's `(boundp name)' for the style variables: registered here
      ;; means bound, whatever its value. `c-evaluate-offset''s
      ;; `symbol-value' arm needs the distinction a value of #f loses.
      (and (assq name %c-style-variable-table) #t))

    (define (c-style-variable-set! name value)
      (let ((entry (assq name %c-style-variable-table)))
        (and entry ((vector-ref (cdr entry) 1) value))))

    (define (c-style-variable-default name)
      (let ((entry (assq name %c-style-variable-table)))
        (and entry ((vector-ref (cdr entry) 2)))))

    ;;------------------------------------------------------------------
    ;; The style variables (`cc-vars.el:481'-`:1340')
    ;;------------------------------------------------------------------
    ;; Emacs declares each of these with `defcustom-c-stylevar', whose
    ;; expansion does two things this tree spells out per variable:
    ;;
    ;;   * the variable's *value* is the symbol `set-from-style', and its
    ;;     standard value is registered with `c-set-stylevar-fallback' -
    ;;     that is what `c-default-style' and `c-style-alist' override;
    ;;   * it is *buffer-local* by default (`c-style-variables-are-local-p'),
    ;;     so a style set in one buffer does not leak into another.
    ;;
    ;; A `define-custom' here is a parameter (the global), and each
    ;; variable has the accessor pair the tree uses for a buffer-local
    ;; Emacs variable: `(c-basic-offset)' is the buffer's value falling
    ;; back on the parameter, and `(set!c-basic-offset v)' writes the
    ;; buffer's slot - which is what `c-set-style-1''s `set' is. Emacs's
    ;; `(symbol-value var)' is the accessor and `(default-value var)' is
    ;; the parameter. (`c-offsets-alist''s value is nil, not
    ;; `set-from-style': Emacs's own `defcustom' - see its docstring's
    ;; neighbour at `cc-vars.el:1258' - and the standard entries are only
    ;; its fallback.)
    ;;
    ;; The docstrings, types and values below are Emacs 31.1's, emitted
    ;; from a running Emacs.

(define-custom *c-basic-offset* 'set-from-style
  "Amount of basic offset used by + and - symbols in ‘c-offsets-alist’.
Also used as the indentation step when ‘c-syntactic-indentation’ is
nil.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'integer
  :group 'c)

(c-set-stylevar-fallback 'c-basic-offset
  4)

(define (c-basic-offset)
  (buffer-local-value (current-buffer) 'c-basic-offset (*c-basic-offset*)))
(define (set!c-basic-offset value)
  (set-buffer-local-value! (current-buffer) 'c-basic-offset value))

(c-style-variable-register! 'c-basic-offset c-basic-offset set!c-basic-offset *c-basic-offset*)

(define-custom *c-comment-only-line-offset* 'set-from-style
  "Extra offset for line which contains only the start of a comment.
Can contain an integer or a cons cell of the form:

 (NON-ANCHORED-OFFSET . ANCHORED-OFFSET)

Where NON-ANCHORED-OFFSET is the amount of offset given to
non-column-zero anchored comment-only lines, and ANCHORED-OFFSET is
the amount of offset to give column-zero anchored comment-only lines.
Just an integer as value is equivalent to (<val> . -1000).

Note that this variable only has effect when the ‘c-lineup-comment’
lineup function is used on the ‘comment-intro’ syntactic symbol (the
default).

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'choice
  :group 'c)

(c-set-stylevar-fallback 'c-comment-only-line-offset
  0)

(define (c-comment-only-line-offset)
  (buffer-local-value (current-buffer) 'c-comment-only-line-offset (*c-comment-only-line-offset*)))
(define (set!c-comment-only-line-offset value)
  (set-buffer-local-value! (current-buffer) 'c-comment-only-line-offset value))

(c-style-variable-register! 'c-comment-only-line-offset c-comment-only-line-offset set!c-comment-only-line-offset *c-comment-only-line-offset*)

(define-custom *c-indent-comment-alist* 'set-from-style
  #("Specifies how M-x indent-for-comment calculates the comment start column.
This is an association list that contains entries of the form:

 (LINE-TYPE . INDENT-SPEC)

LINE-TYPE specifies a type of line as described below, and INDENT-SPEC
says what M-x indent-for-comment should do when used on that type of line.

The recognized values for LINE-TYPE are:

 empty-line        -- The line is empty.
 anchored-comment  -- The line contains a comment that starts in column 0.
 end-block         -- The line contains a solitary block closing brace.
 cpp-end-block     -- The line contains a preprocessor directive that
                      closes a block, i.e. either \"#endif\" or \"#else\".
 other             -- The line does not match any other entry
                      currently on the list.

An INDENT-SPEC is a cons cell of the form:

 (ACTION . VALUE)

ACTION says how M-x indent-for-comment should align the comment, and
VALUE is interpreted depending on ACTION.  ACTION can be any of the
following:

 space   -- Put VALUE spaces between the end of the line and the start
            of the comment.
 column  -- Start the comment at the column VALUE.  If the line is
            longer than that, the comment is preceded by a single
            space.  If VALUE is nil, ‘comment-column’ is used.
 align   -- Align the comment with one on the previous line, if there
            is any.  If the line is too long, the comment is preceded
            by a single space.  If there isn’t a comment start on the
            previous line, the behavior is specified by VALUE, which
            in turn is interpreted as an INDENT-SPEC.

If a LINE-TYPE is missing, then M-x indent-for-comment indents the comment
according to ‘comment-column’.

Note that a non-nil value on ‘c-indent-comments-syntactically-p’
overrides this variable, so empty lines are indented syntactically
in that case, i.e. as if M-x c-indent-command was used instead.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)." 14 36 (font-lock-face help-key-binding face help-key-binding) 247 251 (font-lock-face help-key-binding face help-key-binding) 251 269 (font-lock-face help-key-binding face help-key-binding) 871 875 (font-lock-face help-key-binding face help-key-binding) 875 893 (font-lock-face help-key-binding face help-key-binding) 1665 1669 (font-lock-face help-key-binding face help-key-binding) 1669 1687 (font-lock-face help-key-binding face help-key-binding) 1897 1901 (font-lock-face help-key-binding face help-key-binding) 1901 1917 (font-lock-face help-key-binding face help-key-binding))
  :type 'set
  :group 'c)

(c-set-stylevar-fallback 'c-indent-comment-alist
  (cons (cons 'anchored-comment (cons 'column 0)) (cons (cons 'end-block (cons 'space 1)) (cons (cons 'cpp-end-block (cons 'space 2)) '()))))

(define (c-indent-comment-alist)
  (buffer-local-value (current-buffer) 'c-indent-comment-alist (*c-indent-comment-alist*)))
(define (set!c-indent-comment-alist value)
  (set-buffer-local-value! (current-buffer) 'c-indent-comment-alist value))

(c-style-variable-register! 'c-indent-comment-alist c-indent-comment-alist set!c-indent-comment-alist *c-indent-comment-alist*)

(define-custom *c-indent-comments-syntactically-p* 'set-from-style
  #("Specifies how M-x indent-for-comment should handle comment-only lines.
When this variable is non-nil, comment-only lines are indented
according to syntactic analysis via ‘c-offsets-alist’.  Otherwise, the
comment is indented as if it was preceded by code.  Note that this
variable does not affect how the normal line indentation treats
comment-only lines.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)." 14 36 (font-lock-face help-key-binding face help-key-binding))
  :type 'boolean
  :group 'c)

(c-set-stylevar-fallback 'c-indent-comments-syntactically-p
  '())

(define (c-indent-comments-syntactically-p)
  (buffer-local-value (current-buffer) 'c-indent-comments-syntactically-p (*c-indent-comments-syntactically-p*)))
(define (set!c-indent-comments-syntactically-p value)
  (set-buffer-local-value! (current-buffer) 'c-indent-comments-syntactically-p value))

(c-style-variable-register! 'c-indent-comments-syntactically-p c-indent-comments-syntactically-p set!c-indent-comments-syntactically-p *c-indent-comments-syntactically-p*)

(define-custom *c-block-comment-prefix* 'set-from-style
  "Specifies the line prefix of continued C-style block comments.
You should set this variable to the literal string that gets inserted
at the front of continued block style comment lines.  This should
either be the empty string, or some characters without preceding
spaces.  To adjust the alignment under the comment starter, put an
appropriate value on the ‘c’ syntactic symbol (see the
‘c-offsets-alist’ variable).

It’s only used when a one-line block comment is broken into two or
more lines for the first time; otherwise the appropriate prefix is
adapted from the comment.  This variable is not used for C++ line
style comments.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'string
  :group 'c)

(c-set-stylevar-fallback 'c-block-comment-prefix
  "* ")

(define (c-block-comment-prefix)
  (buffer-local-value (current-buffer) 'c-block-comment-prefix (*c-block-comment-prefix*)))
(define (set!c-block-comment-prefix value)
  (set-buffer-local-value! (current-buffer) 'c-block-comment-prefix value))

(c-style-variable-register! 'c-block-comment-prefix c-block-comment-prefix set!c-block-comment-prefix *c-block-comment-prefix*)

(define-custom *c-comment-prefix-regexp* 'set-from-style
  #("Regexp to match the line prefix inside comments.
This regexp is used to recognize the fill prefix inside comments for
correct paragraph filling and other things.

If this variable is a string, it will be used in all CC Mode major
modes.  It can also be an association list, to associate specific
regexps to specific major modes.  The symbol for the major mode is
looked up in the association list, and its value is used as the line
prefix regexp.  If it’s not found, then the symbol ‘other’ is looked
up and its value is used instead.

The regexp should match the prefix used in both C++ style line
comments and C style block comments, but it does not need to match a
block comment starter.  In other words, it should at least match
\"//\" for line comments and the string in ‘c-block-comment-prefix’,
which is sometimes inserted by CC Mode inside block comments.  It
should not match any surrounding whitespace.

Note that CC Mode uses this variable to set many other variables that
handle the paragraph filling.  That’s done at mode initialization or
when you switch to a style which sets this variable.  Thus, if you
change it in some other way, e.g. interactively in a CC Mode buffer,
you will need to do M-x c-setup-paragraph-variables afterwards so that
the other variables are updated with the new value.

Note also that when CC Mode starts up, all variables are initialized
before the mode hooks are run.  It’s therefore necessary to make a
call to ‘c-setup-paragraph-variables’ explicitly if you change this
variable in a mode hook.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)." 1207 1238 (font-lock-face help-key-binding face help-key-binding))
  :type 'radio
  :group 'c)

(c-set-stylevar-fallback 'c-comment-prefix-regexp
  (cons (cons 'pike-mode "//+!?\\|\\**") (cons (cons 'awk-mode "#+") (cons (cons 'other "//+\\|\\**") '()))))

(define (c-comment-prefix-regexp)
  (buffer-local-value (current-buffer) 'c-comment-prefix-regexp (*c-comment-prefix-regexp*)))
(define (set!c-comment-prefix-regexp value)
  (set-buffer-local-value! (current-buffer) 'c-comment-prefix-regexp value))

(c-style-variable-register! 'c-comment-prefix-regexp c-comment-prefix-regexp set!c-comment-prefix-regexp *c-comment-prefix-regexp*)

(define-custom *c-doc-comment-style* 'set-from-style
  #("Specifies documentation comment style(s) to recognize.
This is primarily used to fontify doc comments and the markup within
them, e.g. Javadoc comments.

The value can be any of the following symbols for various known doc
comment styles:

 javadoc -- Javadoc style for \"/** ... */\" comments (default in Java mode).
 autodoc -- Pike autodoc style for \"//! ...\" comments (default in Pike mode).
 gtkdoc  -- GtkDoc style for \"/** ... **/\" comments
						   (default in C and C++ modes).
 doxygen -- Doxygen style.

The value may also be a list of doc comment styles, in which case all
of them are recognized simultaneously (presumably with markup cues
that don’t conflict).

The value may also be an association list to specify different doc
comment styles for different languages.  The symbol for the major mode
is then looked up in the alist, and the value of that element is
interpreted as above if found.  If it isn’t found then the symbol
‘other’ is looked up and its value is used instead.

Note that CC Mode uses this variable to set other variables that
handle fontification etc.  That’s done at mode initialization or when
you switch to a style which sets this variable.  Thus, if you change
it in some other way, e.g. interactively in a CC Mode buffer, you will
need to do M-x java-mode (or whatever mode you’re currently using) to
reinitialize.

Note also that when CC Mode starts up, the other variables are
modified before the mode hooks are run.  If you change this variable
in a mode hook, you have to call ‘c-setup-doc-comment-style’
afterwards to redo that work.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)." 1280 1293 (font-lock-face help-key-binding face help-key-binding))
  :type 'radio
  :group 'c)

(c-set-stylevar-fallback 'c-doc-comment-style
  (cons (cons 'java-mode 'javadoc) (cons (cons 'pike-mode 'autodoc) (cons (cons 'c-mode 'gtkdoc) (cons (cons 'c++-mode 'gtkdoc) '())))))

(define (c-doc-comment-style)
  (buffer-local-value (current-buffer) 'c-doc-comment-style (*c-doc-comment-style*)))
(define (set!c-doc-comment-style value)
  (set-buffer-local-value! (current-buffer) 'c-doc-comment-style value))

(c-style-variable-register! 'c-doc-comment-style c-doc-comment-style set!c-doc-comment-style *c-doc-comment-style*)

(define-custom *c-cleanup-list* 'set-from-style
  "List of various C/C++/ObjC constructs to \"clean up\".
The following clean ups only take place when the auto-newline feature
is turned on, as evidenced by the ‘/la’ appearing next to the mode
name:

 brace-else-brace    -- Clean up \"} else {\" constructs by placing
                        entire construct on a single line.  This clean
                        up only takes place when there is nothing but
                        white space between the braces and the ‘else’.
                        Clean up occurs when the open brace after the
                        ‘else’ is typed.
 brace-elseif-brace  -- Similar to brace-else-brace, but clean up
                        \"} else if (...) {\" constructs.  Clean up
                        occurs after the open parenthesis and the open
                        brace.
 brace-catch-brace   -- Similar to brace-elseif-brace, but clean up
                        \"} catch (...) {\" constructs.
 empty-defun-braces  -- Clean up empty defun braces by placing the
                        braces on the same line.  Clean up occurs when
                        the defun closing brace is typed.
 one-liner-defun     -- If the code inside a function body can fit in
                        a single line, then remove any newlines
                        between that line and the defun braces so that
                        the whole body becomes a single line.
                        ‘c-max-one-liner-length’ gives the maximum
                        length allowed for the resulting line.  Clean
                        up occurs when the closing brace is typed.
 defun-close-semi    -- Clean up the terminating semi-colon on defuns
                        by placing the semi-colon on the same line as
                        the closing brace.  Clean up occurs when the
                        semi-colon is typed.
 list-close-comma    -- Clean up commas following braces in array
                        and aggregate initializers.  Clean up occurs
                        when the comma is typed.
 scope-operator      -- Clean up double colons which may designate
                        a C++ scope operator split across multiple
                        lines.  Note that certain C++ constructs can
                        generate ambiguous situations.  This clean up
                        only takes place when there is nothing but
                        whitespace between colons.  Clean up occurs
                        when the second colon is typed.

The following clean ups always take place when they are on this list,
regardless of the auto-newline feature, since they typically don’t
involve auto-newline inserted newlines:

 space-before-funcall -- Insert exactly one space before the opening
                        parenthesis of a function call.  Clean up
                        occurs when the opening parenthesis is typed.
 compact-empty-funcall -- Clean up any space before the function call
                        opening parenthesis if and only if the
                        argument list is empty.  This is typically
                        useful together with ‘space-before-funcall’ to
                        get the style \"foo (bar)\" and \"foo()\".
                        Clean up occurs when the closing parenthesis
                        is typed.
 comment-close-slash -- When a slash is typed after the comment prefix
                        on a bare line in a c-style comment, the comment
                        is closed by cleaning up preceding space and
                        inserting a star if needed.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'set
  :group 'c)

(c-set-stylevar-fallback 'c-cleanup-list
  (cons 'scope-operator '()))

(define (c-cleanup-list)
  (buffer-local-value (current-buffer) 'c-cleanup-list (*c-cleanup-list*)))
(define (set!c-cleanup-list value)
  (set-buffer-local-value! (current-buffer) 'c-cleanup-list value))

(c-style-variable-register! 'c-cleanup-list c-cleanup-list set!c-cleanup-list *c-cleanup-list*)

(define-custom *c-hanging-braces-alist* 'set-from-style
  "Controls the insertion of newlines before and after braces
when the auto-newline feature is active.  This variable contains an
association list with elements of the following form:
(SYNTACTIC-SYMBOL . ACTION).

When a brace (either opening or closing) is inserted, the syntactic
context it defines is looked up in this list, and if found, the
associated ACTION is used to determine where newlines are inserted.
If the context is not found, the default is to insert a newline both
before and after the brace.

SYNTACTIC-SYMBOL can be statement-cont, brace-list-intro,
inexpr-class-open, inexpr-class-close, and any of the *-open and
*-close symbols.  See ‘c-offsets-alist’ for details, except for
inexpr-class-open and inexpr-class-close, which doesn’t have any
corresponding symbols there.  Those two symbols are used for the
opening and closing braces, respectively, of anonymous inner classes
in Java.

ACTION can be either a function symbol or a list containing any
combination of the symbols ‘before’ or ‘after’.  If the list is empty,
no newlines are inserted either before or after the brace.

When ACTION is a function symbol, the function is called with a two
arguments: the syntactic symbol for the brace and the buffer position
at which the brace was inserted.  The function must return a list as
described in the preceding paragraph.  Note that during the call to
the function, the variable ‘c-syntactic-context’ is set to the entire
syntactic context for the brace line.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'set
  :group 'c)

(c-set-stylevar-fallback 'c-hanging-braces-alist
  (cons (cons 'brace-list-open '()) (cons (cons 'brace-entry-open '()) (cons (cons 'statement-cont '()) (cons (cons 'substatement-open (cons 'after '())) (cons (cons 'block-close 'c-snug-do-while) (cons (cons 'extern-lang-open (cons 'after '())) (cons (cons 'namespace-open (cons 'after '())) (cons (cons 'module-open (cons 'after '())) (cons (cons 'composition-open (cons 'after '())) (cons (cons 'inexpr-class-open (cons 'after '())) (cons (cons 'inexpr-class-close (cons 'before '())) (cons (cons 'arglist-cont-nonempty '()) '())))))))))))))

(define (c-hanging-braces-alist)
  (buffer-local-value (current-buffer) 'c-hanging-braces-alist (*c-hanging-braces-alist*)))
(define (set!c-hanging-braces-alist value)
  (set-buffer-local-value! (current-buffer) 'c-hanging-braces-alist value))

(c-style-variable-register! 'c-hanging-braces-alist c-hanging-braces-alist set!c-hanging-braces-alist *c-hanging-braces-alist*)

(define-custom *c-hanging-colons-alist* 'set-from-style
  "Controls the insertion of newlines before and after certain colons.
This variable contains an association list with elements of the
following form: (SYNTACTIC-SYMBOL . ACTION).

SYNTACTIC-SYMBOL can be any of: case-label, label, access-label,
member-init-intro, or inher-intro.

See the variable ‘c-hanging-braces-alist’ for the semantics of this
variable.  Note however that making ACTION a function symbol is
currently not supported for this variable.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'set
  :group 'c)

(c-set-stylevar-fallback 'c-hanging-colons-alist
  '())

(define (c-hanging-colons-alist)
  (buffer-local-value (current-buffer) 'c-hanging-colons-alist (*c-hanging-colons-alist*)))
(define (set!c-hanging-colons-alist value)
  (set-buffer-local-value! (current-buffer) 'c-hanging-colons-alist value))

(c-style-variable-register! 'c-hanging-colons-alist c-hanging-colons-alist set!c-hanging-colons-alist *c-hanging-colons-alist*)

(define-custom *c-hanging-semi&comma-criteria* 'set-from-style
  "List of functions that decide whether to insert a newline or not.
The functions in this list are called, in order, whenever the
auto-newline minor mode is activated (as evidenced by a ‘/a’ or ‘/ah’
string in the mode line), and a semicolon or comma is typed (see
‘c-electric-semi&comma’).  Each function in this list is called with
no arguments, and should return one of the following values:

  nil             -- no determination made, continue checking
  ‘stop’          -- do not insert a newline, and stop checking
  (anything else) -- insert a newline, and stop checking

If every function in the list is called with no determination made,
then no newline is inserted.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'sexp
  :group 'c)

(c-set-stylevar-fallback 'c-hanging-semi&comma-criteria
  (cons 'c-semi&comma-inside-parenlist '()))

(define (c-hanging-semi&comma-criteria)
  (buffer-local-value (current-buffer) 'c-hanging-semi&comma-criteria (*c-hanging-semi&comma-criteria*)))
(define (set!c-hanging-semi&comma-criteria value)
  (set-buffer-local-value! (current-buffer) 'c-hanging-semi&comma-criteria value))

(c-style-variable-register! 'c-hanging-semi&comma-criteria c-hanging-semi&comma-criteria set!c-hanging-semi&comma-criteria *c-hanging-semi&comma-criteria*)

(define-custom *c-backslash-column* 'set-from-style
  "Minimum alignment column for line continuation backslashes.
This is used by the functions that automatically insert or align the
line continuation backslashes in multiline macros.  If any line in the
macro exceeds this column then the next tab stop from that line is
used as alignment column instead.  See also ‘c-backslash-max-column’.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'integer
  :group 'c)

(c-set-stylevar-fallback 'c-backslash-column
  48)

(define (c-backslash-column)
  (buffer-local-value (current-buffer) 'c-backslash-column (*c-backslash-column*)))
(define (set!c-backslash-column value)
  (set-buffer-local-value! (current-buffer) 'c-backslash-column value))

(c-style-variable-register! 'c-backslash-column c-backslash-column set!c-backslash-column *c-backslash-column*)

(define-custom *c-backslash-max-column* 'set-from-style
  "Maximum alignment column for line continuation backslashes.
This is used by the functions that automatically insert or align the
line continuation backslashes in multiline macros.  If any line in the
macro exceeds this column then the backslashes for the other lines
will be aligned at this column.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'integer
  :group 'c)

(c-set-stylevar-fallback 'c-backslash-max-column
  72)

(define (c-backslash-max-column)
  (buffer-local-value (current-buffer) 'c-backslash-max-column (*c-backslash-max-column*)))
(define (set!c-backslash-max-column value)
  (set-buffer-local-value! (current-buffer) 'c-backslash-max-column value))

(c-style-variable-register! 'c-backslash-max-column c-backslash-max-column set!c-backslash-max-column *c-backslash-max-column*)

(define-custom *c-auto-align-backslashes* #t
  "Align automatically inserted line continuation backslashes.
When line continuation backslashes are inserted automatically for line
breaks in multiline macros, e.g. by \\[c-context-line-break], they are
aligned with the other backslashes in the same macro if this flag is
set.  Otherwise the inserted backslashes are preceded by a single
space."
  :type 'boolean
  :group 'c)

(define-custom *c-backspace-function* backward-delete-char-untabify
  "Function called by `c-electric-backspace' when deleting backwards."
  :type 'function
  :group 'c)

(define-custom *c-delete-function* delete-char
  "Function called by `c-electric-delete-forward' when deleting forwards."
  :type 'function
  :group 'c)

(define-custom *c-require-final-newline*
  '((c-mode . #t) (c++-mode . #t) (objc-mode . #t))
  "Controls whether a final newline is ensured when the file is saved.
The value is an association list that for each language mode specifies
the value to give to `require-final-newline' at mode initialization;
see that variable for details about the value.  If a language isn't
present on the association list, CC Mode won't touch
`require-final-newline' in buffers for that language."
  :type 'sexp
  :group 'c)

(define-custom *c-electric-pound-behavior* #f
  "List of behaviors for electric pound insertion.
Only currently supported behavior is `alignleft'."
  :type '(set (const alignleft))
  :group 'c)

(define-custom *c-progress-interval* 5
  "Interval used to update progress status during long re-indentation.
If a number, percentage complete gets updated after each interval of
that many seconds.  To inhibit all messages during indentation, set
this variable to nil."
  :type 'integer
  :group 'c)

(define-custom *c-max-one-liner-length* 80
  "Maximum length of line that clean-up \"one-liner-defun\" will compact to.
Zero or nil means no limit."
  :type 'integer
  :group 'c)

(define-custom *c-cpp-indent-to-body-directives* '("pragma")
  "Preprocessor directives which will be indented as statements.

A list of Preprocessor directives which when reindented, or newly
typed in, will cause the \"#\" introducing the directive to be
indented as a statement."
  :type '(repeat string)
  :group 'c)

(define-custom *c-strict-syntax-p* #f
  "If non-nil, all syntactic symbols must be found in `c-offsets-alist'.
If the syntactic symbol for a particular line does not match a symbol
in the offsets alist, or if no non-nil offset value can be determined
for a symbol, an error is generated, otherwise no error is reported
and the syntactic symbol is ignored.

This variable is considered obsolete; it doesn't work well with lineup
functions that return nil to support the feature of using lists on
syntactic elements in `c-offsets-alist'."
  :type 'boolean
  :group 'c)

(define-custom *c-echo-syntactic-information-p* #f
  "If non-nil, syntactic info is echoed when the line is indented."
  :type 'boolean
  :group 'c)

(define-custom *c-special-indent-hook* '()
  "Hook for user defined special indentation adjustments.
This hook gets called after each line is indented by the mode.  It is only
called when ‘c-syntactic-indentation’ is non-nil."
  :type 'hook
  :group 'c)
;; ^ A plain `defcustom' (`cc-vars.el:1145'), not a `defcustom-c-stylevar':
;; it is in `c-style-variables' so `c-set-style-1' treats it specially, but
;; it has no `c-stylevar-fallback' property and no `c-fallback-style' entry
;; (measured: both are nil in Emacs 31.1).

(define (c-special-indent-hook)
  (buffer-local-value (current-buffer) 'c-special-indent-hook (*c-special-indent-hook*)))
(define (set!c-special-indent-hook value)
  (set-buffer-local-value! (current-buffer) 'c-special-indent-hook value))

(c-style-variable-register! 'c-special-indent-hook c-special-indent-hook set!c-special-indent-hook *c-special-indent-hook*)

(define-custom *c-label-minimum-indentation* 'set-from-style
  "Minimum indentation for lines inside code blocks.
This variable typically only affects code using the ‘gnu’ style, which
mandates a minimum of one space in front of every line inside code
blocks.  Specifically, the function ‘c-gnu-impose-minimum’ on your
‘c-special-indent-hook’ is what enforces this.

This is a style variable.  Apart from the valid values described
above, it can be set to the symbol ‘set-from-style’.  In that case,
it takes its value from the style system (see ‘c-default-style’ and
‘c-style-alist’) when a CC Mode buffer is initialized.  Otherwise,
the value set here overrides the style system (there is a variable
‘c-old-style-variable-behavior’ that changes this, though)."
  :type 'integer
  :group 'c)

(c-set-stylevar-fallback 'c-label-minimum-indentation
  1)

(define (c-label-minimum-indentation)
  (buffer-local-value (current-buffer) 'c-label-minimum-indentation (*c-label-minimum-indentation*)))
(define (set!c-label-minimum-indentation value)
  (set-buffer-local-value! (current-buffer) 'c-label-minimum-indentation value))

(c-style-variable-register! 'c-label-minimum-indentation c-label-minimum-indentation set!c-label-minimum-indentation *c-label-minimum-indentation*)

(define-custom *c-offsets-alist* '()
  "Alist of syntactic element symbols and indentation offsets.
As described below, each cons cell in this list has the form:

    (SYNTACTIC-SYMBOL . OFFSET)

When a line is indented, CC Mode first determines the syntactic
context of it by generating a list of symbols called syntactic
elements.  The global variable ‘c-syntactic-context’ is bound to that
list.  Each element in the list is in turn a list where the first
element is a syntactic symbol which tells what kind of construct the
indentation point is located within.  More elements in the syntactic
element lists are optional.  If there is one more and it isn’t nil,
then it’s the anchor position for that construct.

After generating the syntactic context for the line, CC Mode
calculates the absolute indentation: First the base indentation is
found by using the anchor position for the first syntactic element
that provides one.  If none does, zero is used as base indentation.
Then CC Mode looks at each syntactic element in the context in turn.
It compares the car of the syntactic element against the
SYNTACTIC-SYMBOL’s in ‘c-offsets-alist’.  When it finds a match, it
adds OFFSET to the base indentation.  The sum of this calculation is
the absolute offset for line being indented.

If the syntactic element does not match any in the ‘c-offsets-alist’,
the element is ignored.

OFFSET can specify an offset in several different ways:

  If OFFSET is nil then it’s ignored.

  If OFFSET is an integer then it’s used as relative offset, i.e. it’s
  added to the base indentation.

  If OFFSET is one of the symbols ‘+’, ‘-’, ‘++’, ‘--’, ‘*’, or ‘/’
  then a positive or negative multiple of ‘c-basic-offset’ is added to
  the base indentation; 1, -1, 2, -2, 0.5, and -0.5, respectively.

  If OFFSET is a symbol with a value binding then that value, which
  must be an integer, is used as relative offset.

  If OFFSET is a vector then its first element, which must be an
  integer, is used as an absolute indentation column.  This overrides
  the previous base indentation and the relative offsets applied to
  it, and it becomes the new base indentation.

  If OFFSET is a function or a lambda expression then it’s called with
  a single argument containing the cons of the syntactic symbol and
  the anchor position (or nil if there is none).  The return value
  from the function is then reinterpreted as an offset specification.

  If OFFSET is a list then its elements are evaluated recursively as
  offset specifications.  If the first element is any of the symbols
  below then it isn’t evaluated but instead specifies how the
  remaining offsets in the list should be combined.  If it’s something
  else then the list is combined according the method ‘first’.	The
  valid combination methods are:

  ‘first’ -- Use the first offset (that doesn’t evaluate to nil).
  ‘min’	  -- Use the minimum of all the offsets.  All must be either
	     relative or absolute - they can’t be mixed.
  ‘max’	  -- Use the maximum of all the offsets.  All must be either
	     relative or absolute - they can’t be mixed.
  ‘add’	  -- Add all the evaluated offsets together.  Exactly one of
	     them may be absolute, in which case the result is
	     absolute.	Any relative offsets that preceded the
	     absolute one in the list will be ignored in that case.

‘c-offsets-alist’ is a style variable.	This means that the offsets on
this variable are normally taken from the style system in CC Mode
(see ‘c-default-style’ and ‘c-style-alist’).  However, any offsets
put explicitly on this list will override the style system when a CC
Mode buffer is initialized (there is a variable
‘c-old-style-variable-behavior’ that changes this, though).

Here is the current list of valid syntactic element symbols:

 string			-- Inside multi-line string.
 c			-- Inside a multi-line C style block comment.
 defun-open		-- Brace that opens a function definition.
 defun-close		-- Brace that closes a function definition.
 defun-block-intro	-- The first line in a top-level defun.
 class-open		-- Brace that opens a class definition.
 class-close		-- Brace that closes a class definition.
 class-field-cont	-- Continuation of first line inside a class.
 inline-open		-- Brace that opens an in-class inline method.
 inline-close		-- Brace that closes an in-class inline method.
 func-decl-cont		-- The region between a function definition’s
			   argument list and the function opening brace
			   (excluding K&R argument declarations).  In C, you
			   cannot put anything but whitespace and comments
			   between them; in C++ and Java, throws declarations
			   and other things can appear in this context.
 knr-argdecl-intro	-- First line of a K&R C argument declaration.
 knr-argdecl		-- Subsequent lines in a K&R C argument declaration.
 topmost-intro		-- The first line in a topmost construct definition.
 topmost-intro-cont	-- Topmost definition continuation lines.
 constraint-cont	-- Continuation line of a C++ requires clause (not
			   to be confused with a \"requires expression\") or
			   concept.
 annotation-top-cont	-- Topmost definition continuation line where only
			   annotations are on previous lines.
 annotation-var-cont	-- A continuation of a C (or like) statement where
			   only annotations are on previous lines.
 member-init-intro	-- First line in a member initialization list.
 member-init-cont	-- Subsequent member initialization list lines.
 inher-intro		-- First line of a multiple inheritance list.
 inher-cont		-- Subsequent multiple inheritance lines.
 block-open		-- Statement block open brace.
 block-close		-- Statement block close brace.
 brace-list-open	-- Open brace of an enum or static array list.
 brace-list-close	-- Close brace of an enum or static array list.
 brace-list-intro	-- First line in an enum or static array list.
 brace-list-entry	-- Subsequent lines in an enum or static array list.
 brace-entry-open	-- Subsequent lines in an enum or static array
			   list that start with an open brace.
 statement		-- A C (or like) statement.
 statement-cont		-- A continuation of a C (or like) statement.
 statement-block-intro	-- The first line in a new statement block.
 statement-case-intro	-- The first line in a case \"block\".
 statement-case-open	-- The first line in a case block starting with brace.
 substatement		-- The first line after an if/while/for/do/else.
 substatement-open	-- The brace that opens a substatement block.
 substatement-label	-- Labeled line after an if/while/for/do/else.
 case-label		-- A \"case\" or \"default\" label.
 access-label		-- C++ private/protected/public access label.
 label			-- Any ordinary label.
 do-while-closure	-- The \"while\" that ends a do/while construct.
 else-clause		-- The \"else\" of an if/else construct.
 catch-clause		-- The \"catch\" or \"finally\" of a try/catch construct.
 comment-intro		-- A line containing only a comment introduction.
 arglist-intro		-- The first line in an argument list.
 arglist-cont		-- Subsequent argument list lines when no
			   arguments follow on the same line as the
			   arglist opening paren.
 arglist-cont-nonempty	-- Subsequent argument list lines when at
			   least one argument follows on the same
			   line as the arglist opening paren.
 arglist-close		-- The solo close paren of an argument list.
 stream-op		-- Lines continuing a stream operator construct.
 inclass		-- The construct is nested inside a class definition.
			   Used together with e.g. ‘topmost-intro’.
 cpp-macro		-- The start of a C preprocessor macro definition.
 cpp-macro-cont		-- Inside a multi-line C preprocessor macro definition.
 friend			-- A C++ friend declaration.
 objc-method-intro	-- The first line of an Objective-C method definition.
 objc-method-args-cont	-- Lines continuing an Objective-C method definition.
 objc-method-call-cont	-- Lines continuing an Objective-C method call.
 extern-lang-open	-- Brace that opens an \"extern\" block.
 extern-lang-close	-- Brace that closes an \"extern\" block.
 inextern-lang		-- Analogous to the ‘inclass’ syntactic symbol,
			   but used inside \"extern\" blocks.
 namespace-open, namespace-close, innamespace
			-- Similar to the three ‘extern-lang’ symbols, but for
			   C++ \"namespace\" blocks.
 module-open, module-close, inmodule
			-- Similar to the three ‘extern-lang’ symbols, but for
			   CORBA IDL \"module\" blocks.
 composition-open, composition-close, incomposition
			-- Similar to the three ‘extern-lang’ symbols, but for
			   CORBA CIDL \"composition\" blocks.
 template-args-cont	-- C++ template argument list continuations.
 inlambda		-- In the header or body of a lambda function.
 lambda-intro-cont	-- Continuation of the header of a lambda function.
 inexpr-statement	-- The statement is inside an expression.
 inexpr-class		-- The class is inside an expression.  Used e.g. for
			   Java anonymous classes."
  :type 'sexp
  :group 'c)

(c-set-stylevar-fallback 'c-offsets-alist
  (cons (cons 'string 'c-lineup-dont-change) (cons (cons 'c 'c-lineup-C-comments) (cons (cons 'defun-open 0) (cons (cons 'defun-close 0) (cons (cons 'defun-block-intro '+) (cons (cons 'class-open 0) (cons (cons 'class-close 0) (cons (cons 'inline-open '+) (cons (cons 'inline-close 0) (cons (cons 'func-decl-cont '+) (cons (cons 'knr-argdecl-intro '+) (cons (cons 'knr-argdecl 0) (cons (cons 'topmost-intro 0) (cons (cons 'topmost-intro-cont 'c-lineup-topmost-intro-cont) (cons (cons 'constraint-cont (cons 'c-lineup-item-after-paren-at-boi (cons '+ '()))) (cons (cons 'annotation-top-cont 0) (cons (cons 'annotation-var-cont '+) (cons (cons 'member-init-intro '+) (cons (cons 'member-init-cont 'c-lineup-multi-inher) (cons (cons 'class-field-cont 'c-lineup-class-field-cont) (cons (cons 'inher-intro '+) (cons (cons 'inher-cont 'c-lineup-multi-inher) (cons (cons 'block-open 0) (cons (cons 'block-close 0) (cons (cons 'brace-list-open 0) (cons (cons 'brace-list-close 0) (cons (cons 'brace-list-intro (cons 'c-lineup-item-after-paren-at-boi (cons '+ '()))) (cons (cons 'brace-list-entry 0) (cons (cons 'brace-entry-open 0) (cons (cons 'enum-open 'class-open) (cons (cons 'enum-close 0) (cons (cons 'enum-intro (cons 'c-lineup-item-after-paren-at-boi (cons '+ '()))) (cons (cons 'enum-entry 0) (cons (cons 'statement 0) (cons (cons 'statement-cont '+) (cons (cons 'statement-block-intro '+) (cons (cons 'statement-case-intro '+) (cons (cons 'statement-case-open 0) (cons (cons 'substatement '+) (cons (cons 'substatement-open '+) (cons (cons 'substatement-label 2) (cons (cons 'case-label 0) (cons (cons 'access-label '-) (cons (cons 'label 2) (cons (cons 'do-while-closure 0) (cons (cons 'else-clause 0) (cons (cons 'catch-clause 0) (cons (cons 'comment-intro (cons 'c-lineup-knr-region-comment (cons 'c-lineup-comment '()))) (cons (cons 'arglist-intro '+) (cons (cons 'arglist-cont (cons 'c-lineup-gcc-asm-reg (cons 0 '()))) (cons (cons 'arglist-cont-nonempty (cons 'c-lineup-gcc-asm-reg (cons 'c-lineup-arglist '()))) (cons (cons 'arglist-close '+) (cons (cons 'stream-op 'c-lineup-streamop) (cons (cons 'inclass '+) (cons (cons 'cpp-macro (vector 0)) (cons (cons 'cpp-macro-cont '+) (cons (cons 'cpp-define-intro (cons 'c-lineup-cpp-define (cons '+ '()))) (cons (cons 'friend 0) (cons (cons 'objc-method-intro (vector 0)) (cons (cons 'objc-method-args-cont 'c-lineup-ObjC-method-args) (cons (cons 'objc-method-call-cont (cons 'c-lineup-ObjC-method-call-colons (cons 'c-lineup-ObjC-method-call (cons '+ '())))) (cons (cons 'extern-lang-open 0) (cons (cons 'namespace-open 0) (cons (cons 'module-open 0) (cons (cons 'composition-open 0) (cons (cons 'extern-lang-close 0) (cons (cons 'namespace-close 0) (cons (cons 'module-close 0) (cons (cons 'composition-close 0) (cons (cons 'inextern-lang '+) (cons (cons 'innamespace '+) (cons (cons 'inmodule '+) (cons (cons 'incomposition '+) (cons (cons 'template-args-cont (cons 'c-lineup-template-args (cons 'c-lineup-template-args-indented-from-margin '()))) (cons (cons 'inlambda 0) (cons (cons 'lambda-intro-cont '+) (cons (cons 'inexpr-statement '+) (cons (cons 'inexpr-class '+) '())))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))

(define (c-offsets-alist)
  (buffer-local-value (current-buffer) 'c-offsets-alist (*c-offsets-alist*)))
(define (set!c-offsets-alist value)
  (set-buffer-local-value! (current-buffer) 'c-offsets-alist value))

(c-style-variable-register! 'c-offsets-alist c-offsets-alist set!c-offsets-alist *c-offsets-alist*)

;; The syntactic symbols that can occur inside code blocks. Used by
;; `c-gnu-impose-minimum' (`cc-vars.el:1453'). A defconst, so a plain
;; definition, as the tree's convention says.
(define c-inside-block-syms
  '(defun-block-intro block-open block-close statement statement-cont
    statement-block-intro statement-case-intro statement-case-open
    substatement substatement-open substatement-label case-label label
    do-while-closure else-clause catch-clause inlambda annotation-var-cont))

(define-custom *c-style-variables-are-local-p* #t
  "Whether style variables should be buffer local by default.
If non-nil, then all indentation style related variables will be made
buffer local by default.  If nil, they will remain global.  Variables
are made buffer local when this file is loaded, and once buffer
localized, they cannot be made global again.

This variable must be set appropriately before CC Mode is loaded.

The list of variables to buffer localize are:
    ‘c-basic-offset’
    ‘c-comment-only-line-offset’
    ‘c-indent-comment-alist’
    ‘c-indent-comments-syntactically-p’
    ‘c-block-comment-prefix’
    ‘c-comment-prefix-regexp’
    ‘c-doc-comment-style’
    ‘c-cleanup-list’
    ‘c-hanging-braces-alist’
    ‘c-hanging-colons-alist’
    ‘c-hanging-semi&comma-criteria’
    ‘c-backslash-column’
    ‘c-backslash-max-column’
    ‘c-label-minimum-indentation’
    ‘c-offsets-alist’
    ‘c-special-indent-hook’
    ‘c-indentation-style’"
  :type 'boolean
  :group 'c)

(define-custom *c-old-style-variable-behavior* '()
  "Enables the old style variable behavior when non-nil.

Normally the values of the style variables will override the style
settings specified by the variables ‘c-default-style’ and
‘c-style-alist’.  However, in CC Mode 5.25 and earlier, it was the
other way around, meaning that changes made to the style variables
from e.g. Customize would not take effect unless special precautions
were taken.  That was confusing, especially for novice users.

It’s believed that despite this change, the new behavior will still
produce the same results for most old CC Mode configurations, since
all style variables are per default set in a special non-override
state.  Set this variable only if your configuration has stopped
working due to this change."
  :type 'boolean
  :group 'c)

(define-custom *c-default-style* (cons (cons 'java-mode "java") (cons (cons 'awk-mode "awk") (cons (cons 'other "gnu") '())))
  "Style which gets installed by default when a file is visited.

The value of this variable can be any style defined in
‘c-style-alist’, including styles you add.  The value can also be an
association list of major mode symbols to style names.

When the value is a string, all CC Mode major modes will install this
style by default.

When the value is an alist, the major mode symbol is looked up in it
and the associated style is installed.  If the major mode is not
listed in the alist, then the symbol ‘other’ is looked up in it, and
if found, the style in that entry is used.  If ‘other’ is not found in
the alist, then \"gnu\" style is used.

The default style gets installed before your mode hooks run, so you
can always override the use of ‘c-default-style’ by making calls to
‘c-set-style’ in the appropriate mode hook."
  :type 'radio
  :group 'c)


    ;;------------------------------------------------------------------
    ;; The plain and buffer-local variables
    ;;------------------------------------------------------------------
    (define (c-indentation-style)
      ;; "Name of the currently installed style." Set by `c-set-style'
      ;; (cc-styles). **A buffer-local slot, not a global**: Emacs's
      ;; `c-make-styles-buffer-local' puts it on its list and every CC
      ;; buffer chooses its own style, so one buffer's `c-set-style' must
      ;; not rename the style of another.
      (buffer-local-value (current-buffer) 'c-indentation-style #f))

    (define (set!c-indentation-style value)
      (set-buffer-local-value! (current-buffer) 'c-indentation-style value))

    (define (c-default-value-sentence-end)
  ;; "Get the default value of the variable sentence end" -
  ;; `cc-defs.el:580''s macro, the Emacs 22+ arm `(let (sentence-end)
  ;; (sentence-end))'. **A placement departure**: it is cc-defs.el's, but
  ;; cc-defs sits below `paragraphs.scm' and this is one call to
  ;; `sentence-end' - the same value this file's
  ;; `c-sentence-end-with-esc-eol' is built from, so it lives beside it.
  ;; The C's `let' of a variable is this tree's `parameterize'.
  (parameterize ((*sentence-end* #f)) (sentence-end)))

(define (c-valid-offset offset)
      ;; "Return non-nil if OFFSET is a valid offset for a syntactic
      ;; symbol. See `c-offsets-alist'."
      ;;
      ;; Emacs's `(functionp offset)' arm accepts a symbol that names a
      ;; function; a symbol naming a function is not a thing here
      ;; (functions are procedures, not bindings), so the arm consults
      ;; `%c-offset-function-names' instead - the line-up function names
      ;; the shipped styles use, which the cc-align port will extend as
      ;; it defines them. A *procedure* is accepted too, which is what a
      ;; direct `(lambda ...)' offset becomes here.
      (or (eq? offset '+)
          (eq? offset '-)
          (eq? offset '++)
          (eq? offset '--)
          (eq? offset '*)
          (eq? offset '/)
          (integer? offset)
          (procedure? offset)
          (and (symbol? offset)
               (or (memq offset %c-offset-function-names)
                   (assq offset (c-offsets-alist))))
          ;; `vector-length', not `length': Guile's `length' is lists
          ;; only, and the C's `(length offset)' is `Flength' over a
          ;; vector, which answers its size.
          (and (vector? offset)
               (= (vector-length offset) 1)
               (integer? (vector-ref offset 0)))
          (and (pair? offset)
               (not (eq? (car offset) 'quote)) ; "Detect misquoted lists."
               (begin
                 (when (memq (car offset) '(first min max add))
                   (set! offset (cdr offset)))
                 (let loop ((offset offset))
                   (cond ((not (pair? offset)) (null? offset))
                         ((c-valid-offset (car offset)) (loop (cdr offset)))
                         (else #f)))))))

    (define %c-offset-function-names '())
    ;; ^ The symbols that name line-up functions: Emacs's `functionp'
    ;;   arm, as a registry, because a symbol has no function binding
    ;;   here. Filled at the end of this library with the names the
    ;;   shipped styles use; cc-align extends it as it lands.

    ;; The shipped styles' and the standard offsets' function names -
    ;; the set `c-valid-offset' accepts as Emacs's `functionp' does
    ;; (emitted from Emacs 31.1's `c-style-alist' and fallback).
(set! %c-offset-function-names '(
   c-indent-multi-line-block
   c-lineup-2nd-brace-entry-in-arglist
   c-lineup-C-comments
   c-lineup-ObjC-method-args
   c-lineup-ObjC-method-call
   c-lineup-ObjC-method-call-colons
   c-lineup-after-whitesmith-blocks
   c-lineup-arglist
   c-lineup-arglist-close-under-paren
   c-lineup-arglist-intro-after-paren
   c-lineup-class-decl-init-+
   c-lineup-class-field-cont
   c-lineup-comment
   c-lineup-cpp-define
   c-lineup-dont-change
   c-lineup-gcc-asm-reg
   c-lineup-gnu-DEFUN-intro-cont
   c-lineup-item-after-paren-at-boi
   c-lineup-java-inher
   c-lineup-java-throws
   c-lineup-knr-region-comment
   c-lineup-multi-inher
   c-lineup-streamop
   c-lineup-template-args
   c-lineup-template-args-indented-from-margin
   c-lineup-topmost-intro-cont
   c-lineup-whitesmith-in-block
   ))

    (define (c-register-offset-function-name! symbol)
      ;; Emacs's `(functionp offset)' arm of `c-valid-offset' accepts
      ;; any symbol that names a function; a symbol has no function
      ;; binding here, so the accepted names are kept in
      ;; `%c-offset-function-names' and this is how a library adds one.
      ;; `cc-align.scm' calls it as it defines each line-up function.
      (unless (memq symbol %c-offset-function-names)
        (set! %c-offset-function-names
              (cons symbol %c-offset-function-names))))

    (define (c-string-or-string-list-p val)
      ;; "Return non-nil if VAL is a string or a list of strings."
      (or (string? val)
          (c-string-list-p val)))

    (define c-string-par-start
      ;; "Value of `paragraph-start' used when scanning strings.
      ;; It treats escaped EOLs as whitespace."
      "\f\|[ \t]*\\\\?$")

    (define c-string-par-separate
      ;; "Value of `paragraph-separate' used when scanning strings.
      ;; It treats escaped EOLs as whitespace."
      "[ \t\f]*\\\\?$")

    (define c-sentence-end-with-esc-eol
      ;; "Value used like `sentence-end' used when scanning strings.
      ;; It treats escaped EOLs as whitespace." Computed at load from
      ;; the default sentence end, as Emacs computes it.
      (concat "\\(\\(" (parameterize ((*sentence-end* #f)) (sentence-end)) "\\)"
              ;; "N.B.:  \"$\" would be illegal when not enclosed like
              ;; \"\\($\\)\"."
              "\\|" "[.?!][]\"')}]* ?\\\\\\($\\)[ \t\n]*"
              "\\)"))

    (define (c-current-comment-prefix)
      ;; "The current comment prefix regexp. Set from
      ;; `c-comment-prefix-regexp' at mode initialization." Emacs makes
      ;; it buffer-local; here it is a buffer-local slot (the tree's
      ;; mechanism), so it is an accessor rather than a variable.
      (buffer-local-value (current-buffer) 'c-current-comment-prefix #f))

    (define (set!c-current-comment-prefix value)
      (set-buffer-local-value! (current-buffer) 'c-current-comment-prefix value))

    (define (c-block-comment-flag)
      ;; "`c-block-comment-flag' gets initialized to the current mode's
      ;; default in `c-basic-common-init'." (`cc-cmds.el:259'): non-nil
      ;; when the default comment style is block, nil when it is line.
      ;;
      ;; **Placement departure**: `cc-cmds.el' is the file it belongs to
      ;; and that file is not ported; the variable comes with the mode's
      ;; comment commands, so it lives here until they arrive. It is
      ;; buffer-local in Emacs (`make-variable-buffer-local'), so it is a
      ;; buffer-local slot and an accessor pair here.
      (buffer-local-value (current-buffer) 'c-block-comment-flag #f))

    (define (set!c-block-comment-flag value)
      (set-buffer-local-value! (current-buffer) 'c-block-comment-flag value))

    (define (c-macro-with-semi-re)
      ;; "Regular expression which matches a (#define'd) symbol whose
      ;; expansion ends with a semicolon." Buffer-local in Emacs; a
      ;; buffer-local slot here.
      (buffer-local-value (current-buffer) 'c-macro-with-semi-re #f))

    (define (set!c-macro-with-semi-re value)
      (set-buffer-local-value! (current-buffer) 'c-macro-with-semi-re value))

    (define (c-macro-names-with-semicolon)
      ;; "List of #defined symbols whose expansion ends with a semicolon.
      ;; Alternatively it can be a string, a regular expression which
      ;; matches all such symbols." Buffer-local in Emacs (and readable
      ;; from a file's local variables), so a buffer-local slot here with
      ;; the defvar's default.
      (buffer-local-value (current-buffer) 'c-macro-names-with-semicolon
                          '("Q_OBJECT" "Q_PROPERTY" "Q_DECLARE" "Q_ENUMS")))

    (define (set!c-macro-names-with-semicolon value)
      (set-buffer-local-value! (current-buffer) 'c-macro-names-with-semicolon
                               value))

    (define (c-make-macro-with-semi-re)
      ;; "Convert `c-macro-names-with-semicolon' into the regexp
      ;; `c-macro-with-semi-re' (or just copy it if it's already a re)."
      ;;
      ;; Emacs guards on `(boundp 'c-opt-cpp-macro-define)' - the
      ;; language variable is set by `c-init-language-vars' - and here a
      ;; language variable is a buffer-local slot, so the guard is the
      ;; slot's presence.
      (set!c-macro-with-semi-re
       (let ((define-re (buffer-local-value (current-buffer)
                                            'c-opt-cpp-macro-define #f))
             (names (c-macro-names-with-semicolon)))
         (and define-re
              (cond ((string? names) (string-copy names))
                    ((pair? names) (regexp-opt names 'symbols))
                    ((or (not names) (null? names)) #f)
                    (else
                     (error "c-make-macro-with-semi-re: Invalid c-macro-names-with-semicolon: ~a"
                            names)))))))

    ;;------------------------------------------------------------------
    ;; Parsing errors (`cc-vars.el:460')
    ;;------------------------------------------------------------------
    (define-custom *c-report-syntactic-errors* #f
      "If non-nil, certain syntactic errors are reported with a ding
and a message, for example when an \"else\" is indented for which
there's no corresponding \"if\".

Note however that CC Mode doesn't make any special effort to check for
syntactic errors; that's the job of the compiler.  The reason it can
report cases like the one above is that it can't find the correct
anchoring position to indent the line in that case."
      :type 'boolean
      :group 'c)

    ;;------------------------------------------------------------------
    ;; The noise macros (`cc-vars.el:1712'-`:1784')
    ;;------------------------------------------------------------------
    ;; "Initialize the next two to a regexp which never matches." Emacs
    ;; makes both buffer-local and computes them from the two options
    ;; with `c-make-noise-macro-regexps'; they are buffer-local slots
    ;; here, as every cc buffer-local variable is.
    (define (c-noise-macro-with-parens-name-re)
      (buffer-local-value (current-buffer) 'c-noise-macro-with-parens-name-re
                          regexp-unmatchable))
    (define (set!c-noise-macro-with-parens-name-re value)
      (set-buffer-local-value! (current-buffer) 'c-noise-macro-with-parens-name-re
                               value))
    (define (c-noise-macro-name-re)
      (buffer-local-value (current-buffer) 'c-noise-macro-name-re
                          regexp-unmatchable))
    (define (set!c-noise-macro-name-re value)
      (set-buffer-local-value! (current-buffer) 'c-noise-macro-name-re value))

    (define-custom *c-noise-macro-names* '()
      "A list of names of macros which expand to nothing, or compiler extensions
like \"INLINE\" which are syntactic noise.  Such a macro/extension is complete
in itself, never having parentheses.  All these names must be syntactically
valid identifiers.  Alternatively, this variable may be a regular expression
which matches the names of such macros, in which case it must have a submatch
1 which matches the actual noise macro name.

If you change this variable's value, call the function
`c-make-noise-macro-regexps' to set the necessary internal variables (or do
this implicitly by reinitializing C/C++/Objc Mode on any buffer)."
      :type '(choice (repeat string) regexp)
      :group 'c)

    (define-custom *c-noise-macro-with-parens-names* '()
      "A list of names of macros (or compiler extensions like \"__attribute__\")
which optionally take a parenthesized argument list.  All these names must be
syntactically valid identifiers.  Alternatively, this variable may be a regular
expression which matches the names of such macros, in which case it must have a
submatch 1 which matches the actual noise macro name.

If you change this variable's value, call the function
`c-make-noise-macro-regexps' to set the necessary internal variables (or do
this implicitly by reinitializing C/C++/Objc Mode on any buffer)."
      :type '(choice (repeat string) regexp)
      :group 'c)

    (define (c-make-noise-macro-regexps)
      ;; "Convert `c-noise-macro-names' and
      ;; `c-noise-macro-with-parens-names' into `c-noise-macro-name-re'
      ;; and `c-noise-macro-with-parens-name-re'."
      (set!c-noise-macro-with-parens-name-re
       (let ((names (*c-noise-macro-with-parens-names*)))
         (cond ((or (not names) (null? names)) regexp-unmatchable)
               ((pair? names) (regexp-opt names 'symbols))
               ((string? names) (string-copy names))
               (else (error "c-make-noise-macro-regexps: c-noise-macro-with-parens-names is invalid: ~a"
                            names)))))
      (set!c-noise-macro-name-re
       (let ((names (*c-noise-macro-names*)))
         (cond ((or (not names) (null? names)) regexp-unmatchable)
               ((pair? names) (regexp-opt names 'symbols))
               ((string? names) (string-copy names))
               (else (error "c-make-noise-macro-regexps: c-noise-macro-names is invalid: ~a"
                            names))))))

    ;;------------------------------------------------------------------
    ;; The bridge into `c-mode-var'
    ;;------------------------------------------------------------------
    ;; `c-mode-var' reads a buffer-local slot for a language variable; a
    ;; defcustom here is a parameter, so each one registers a reader under
    ;; its *Emacs* name. `c-known-type-key' (cc-langs) asks for
    ;; "font-lock-extra-types" through it, which is Emacs's
    ;; `(symbol-value (c-mode-symbol ...))'.
    (c-register-emacs-variable-reader!
     'c-font-lock-extra-types (lambda () (*c-font-lock-extra-types*)))
    (c-register-emacs-variable-reader!
     'c++-font-lock-extra-types (lambda () (*c++-font-lock-extra-types*)))
    (c-register-emacs-variable-reader!
     'objc-font-lock-extra-types (lambda () (*objc-font-lock-extra-types*)))
    (c-register-emacs-variable-reader!
     'java-font-lock-extra-types (lambda () (*java-font-lock-extra-types*)))
    (c-register-emacs-variable-reader!
     'idl-font-lock-extra-types (lambda () (*idl-font-lock-extra-types*)))
    (c-register-emacs-variable-reader!
     'pike-font-lock-extra-types (lambda () (*pike-font-lock-extra-types*)))

    ;;------------------------------------------------------------------
    ;; The two always-dynamically-bound analysis variables
    ;; (`cc-vars.el:1869'-`:1904')
    ;;------------------------------------------------------------------
    ;; Emacs declares both with a bare `defvar' (void) and gives them a
    ;; `variable-documentation' property; a parameter needs a default, and
    ;; #f is "not bound". They are `let'-bound by their readers, so the
    ;; convention makes them parameters.
    (define-custom *c-syntactic-context* #f
      "Variable containing the syntactic analysis list for a line of code.

It is a list with one element for each syntactic symbol pertinent to the
line, for example \"((defun-block-intro 1) (comment-intro))\".

It is dynamically bound when calling (i) a brace hanging \"action
function\"; (ii) a semicolon/comma hanging \"criteria function\"; (iii) a
\"line-up function\"; (iv) a c-special-indent-hook function.  It is also
used internally by CC Mode.

c-syntactic-context is always bound dynamically.  It must NEVER be set
statically (e.g. with `setq')."
      :type 'sexp
      :group 'c)

    (define-custom *c-syntactic-element* #f
      "Variable containing the current syntactic element during calls to
the lineup functions.  The value is one of the elements in the list in
`c-syntactic-context' and is a list with the symbol name in the first
position, followed by zero or more elements containing any additional
info associated with the syntactic symbol.  There are accessor functions
`c-langelem-sym', `c-langelem-pos', `c-langelem-col', and
`c-langelem-2nd-pos' to access the list.

Specifically, the element returned by `c-langelem-pos' is the anchor
position, or nil if there isn't any.  See the comments in the
`c-offsets-alist' variable and the CC Mode manual for more detailed info
about the data each syntactic symbol provides.

This is always bound dynamically.  It should never be set
statically (e.g. with `setq')."
      :type 'sexp
      :group 'c)

    ))
