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
          c-register-emacs-variable-reader!))

  (export c-make-font-lock-extra-types-blurb c-string-list-p
          *c-syntactic-indentation* *c-syntactic-indentation-in-macros*
          *c-warn-ids-with-dollar* *c-mark-wrong-style-of-comment*
          *c-asymmetry-fontification-flag*
          *c-font-lock-extra-types* *c++-font-lock-extra-types*
          *objc-font-lock-extra-types* *java-font-lock-extra-types*
          *idl-font-lock-extra-types* *pike-font-lock-extra-types*
          c-indentation-style
          c-current-comment-prefix set!c-current-comment-prefix
          c-macro-with-semi-re set!c-macro-with-semi-re
          *c-report-syntactic-errors*)

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
    ;; The plain and buffer-local variables
    ;;------------------------------------------------------------------
    (define c-indentation-style #f)
    ;; ^ "Name of the currently installed style." Set by `c-set-style'
    ;; (cc-styles) - a global, as in Emacs, not a parameter.

    (define (c-current-comment-prefix)
      ;; "The current comment prefix regexp. Set from
      ;; `c-comment-prefix-regexp' at mode initialization." Emacs makes
      ;; it buffer-local; here it is a buffer-local slot (the tree's
      ;; mechanism), so it is an accessor rather than a variable.
      (buffer-local-value (current-buffer) 'c-current-comment-prefix #f))

    (define (set!c-current-comment-prefix value)
      (set-buffer-local-value! (current-buffer) 'c-current-comment-prefix value))

    (define (c-macro-with-semi-re)
      ;; "Regular expression which matches a (#define'd) symbol whose
      ;; expansion ends with a semicolon." Buffer-local in Emacs; a
      ;; buffer-local slot here.
      (buffer-local-value (current-buffer) 'c-macro-with-semi-re #f))

    (define (set!c-macro-with-semi-re value)
      (set-buffer-local-value! (current-buffer) 'c-macro-with-semi-re value))

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

    ))
