(define-library (schemacs editor cc-defs)
  ;; `lisp/progmodes/cc-defs.el', the language-constant system only so
  ;; far. The rest of cc-defs (the `c-*-at-toplevel' macros, the
  ;; `c-save-buffer-state' family, `c-macroexpand-all') comes with the
  ;; cc-engine pass that needs it.
  ;;
  ;; Ported here: `c-add-language', the language declarations
  ;; (`cc-defs.el:2098'), the constant registry, `c-lang-defconst',
  ;; `c-lang-const', `c-get-lang-constant',
  ;; `c-find-assignment-for-mode', `c-lang-defconst-eval-immediately'
  ;; and `c-lang-major-mode-is' (`:2427'-`:2990').
  ;;
  ;; **The design departure, and why.** Emacs stores each VAL as a
  ;; source form, byte-compiles it into the `.elc' where it stands, and
  ;; expands `c-lang-const' at compile time to the value; at run time
  ;; `cc-langs' need not be loaded at all - measured, an installed
  ;; Emacs's cc-mode has `(featurep 'cc-langs)' nil and a 9-entry
  ;; obarray. Guile's compiler does not evaluate top-level `define's as
  ;; it goes, so a VAL evaluated at expansion time could call a
  ;; function that does not exist in the compiler process yet. So:
  ;;
  ;;   - `c-lang-defconst' registers each VAL as *source data* with the
  ;;     module that defines it, at expand, load and eval time
  ;;     (`eval-when (expand load eval)');
  ;;   - the first request evaluates that source with `eval' in the
  ;;     defining module, where every top-level definition is in place;
  ;;   - `c-lang-const' with an explicit LANG expands to the value when
  ;;     it resolves at expansion time (for a consumer of `cc-langs' it
  ;;     does: the library is imported and loaded), and to a runtime
  ;;     call otherwise - a forward reference, or no LANG, where the
  ;;     value depends on the buffer's language.
  ;;
  ;; So compiled consumers get the values baked in, as Emacs's do, and
  ;; forward references and the setq-like self-extension still work.
  ;; The cost: a consumer's compiled file needs the defining library
  ;; loaded when it is *compiled*, not when it runs.
  ;;
  ;; A "source file" here is a module name, not a file name; the
  ;; `pre-files' argument of `c-define-lang-constant' and Emacs's
  ;; load-the-file-to-get-its-sources step have no counterpart because
  ;; imports are explicit. Both are named departures.
  ;;
  ;; **A porting hazard**: every datum the macros emit is built with
  ;; `datum->syntax', or Guile reports "raw symbol in macro output";
  ;; the fixed identifiers come from templates, so they resolve in this
  ;; library and a caller need not import `eval-when' or `quote'.
  (import
    (scheme base)
    (only (guile) make-hash-table hashq-ref hashq-set! hashq-get-handle
                  hash-clear! hash-map->list current-module module-name
                  eval-when eval sort string<? most-positive-fixnum
                  syntax with-syntax syntax-case syntax->datum datum->syntax
                  while)
    ;; `c-got-face-at' is written with Emacs's `while' and `setq'; the
    ;; `-e' forms are for the places where Emacs's answer is observable.
    (only (schemacs syntax) setq when-e)
    (only (schemacs editor intervals) get put)
    (only (schemacs editor buffer) current-buffer buffer-local-value)
    (only (schemacs editor cl-seq)
          cl-set-difference cl-intersection cl-delete-duplicates)
    (only (schemacs editor fns) mapcan)
    (only (schemacs editor syntax) char-syntax-in with-syntax-table
          skip-chars-forward skip-chars-backward
          skip-syntax-forward skip-syntax-backward)
    ;; `c-skip-ws-chars-*' and the scan-lists wrappers move point and
    ;; narrow.
    (only (schemacs editor editfns) point goto-char point-min point-max
          save-restriction narrow-to-region char-after char-before eolp)
    (only (schemacs editor cmds) forward-char backward-char)
    (only (schemacs editor syntax) scan-lists scan-sexps)
    ;; `c-safe' re-raises a quit; this tree's quit is command.scm's
    ;; record, and Emacs's `condition-case ... (error nil)' does not
    ;; catch one.
    (only (schemacs editor command) quit-condition?)
    ;; `c-save-buffer-state' is `with-silent-modifications' since Emacs
    ;; 24 (see below), which is `subr.el''s.
    (only (schemacs editor subr) with-silent-modifications)
    ;; `c-face-name-p' asks whether a face exists.
    (only (schemacs editor faces) face-list)
    ;; The property API `c-put-char-property' and friends stand on
    ;; (`textprop.c''s), which `cc-defs.el' reaches directly in Emacs.
    (only (schemacs editor textprop) put-text-property get-text-property
          remove-text-properties next-single-property-change
          previous-single-property-change)
    ;; The `c-search-*-char-property-with-value-on-char' helpers move one
    ;; character at a time and set the match data on it, as the C's
    ;; `search-forward-regexp' does.
    (only (schemacs editor search) re-search-forward re-search-backward)
    (only (schemacs regexp-opt) regexp-opt))

  (export
   c-lang-defconst c-lang-const c-lang-defconst-eval-immediately
   c-get-lang-constant c-find-assignment-for-mode
   c-define-lang-constant c-define-lang-constant-here
   c-lang-defconst-bindings c-lang-defconst-thunk
   c-lang-defconst-eval-now c-lang-constant-names
   c--mapcan c--set-difference c--intersection c--delete-duplicates
   %c-true %c-false
   c-emacs-features c-with-syntax-table c-int-to-char c-characterp
   c-keep-region-active
   c-register-emacs-variable-reader!
   c-add-language c-lang-major-mode-is *c-buffer-is-cc-mode*
   *c-lang-var-overrides*
   c-alpha c-alnum c-digit c-upper c-lower
   c-mode-symbol c-mode-var c-mode-var-boundp c-got-face-at c-face-name-p
   c-concat-separated c-make-bare-char-alt
   c-make-keywords-re c-lang-constant-documentation c-literal-datum?
   c-major-mode-is *c-langs-are-parametric* *c-lang-const-expansion*
   c-save-buffer-state
   c-syntax-table-hwm
   c-put-char-property c-get-char-property c-clear-char-property
   c-put-char-properties c-clear-char-properties c-min-property-position
   c-put-string-fence
   c-search-forward-char-property c-search-forward-non-nil-char-property
   c-search-backward-char-property
   c-search-forward-char-property-with-value-on-char
   c-search-backward-char-property-with-value-on-char
   c-search-forward-char-property-without-value-on-char
   c-next-single-property-change c-previous-single-property-change
   c-<-as-paren-syntax c->-as-paren-syntax c-use-category
   c-mark-<-as-paren c-mark->-as-paren c-unmark-<-or->-as-paren
   c-suppress-<->-as-parens c-restore-<->-as-parens
   c-skip-ws-chars-forward c-skip-ws-chars-backward
   c-skip-ws-forward c-skip-ws-backward
   c-safe c-forward-sexp c-backward-sexp c-safe-scan-lists
   c-go-list-forward c-go-list-backward
   c-up-list-forward c-up-list-backward
   c-down-list-forward c-down-list-backward
   c-go-up-list-forward c-go-up-list-backward
   c-go-down-list-forward c-go-down-list-backward)

  (begin


;;----------------------------------------------------------------------
;; "Some helper constants" (`cc-defs.el:2427')
;;----------------------------------------------------------------------
;; Emacs's `c-emacs-features' has `posix-char-classes' (measured), so
;; the character-class spelling is the one taken.
(define c-alpha "[:alpha:]")
(define c-alnum "[:alnum:]")
(define c-digit "[:digit:]")
(define c-upper "[:upper:]")
(define c-lower "[:lower:]")

;;----------------------------------------------------------------------
;; `c-emacs-features' (`cc-defs.el:2236')
;;----------------------------------------------------------------------
;; Emacs probes the running Emacs at load for these flags; there is one
;; Emacs here and it is this tree, so the answer is a measured constant
;; (Emacs 31.1's own value). The `1-bit' entry is the syntax-table flag
;; width `c-populate-syntax-table' was written against.
(define c-emacs-features
  '(pps-extended-state col-0-paren posix-char-classes gen-string-delim
    gen-comment-delim syntax-properties category-properties 1-bit))

;;----------------------------------------------------------------------
;; `c-with-syntax-table' (`cc-defs.el:1063'), `c-int-to-char' (`:548')
;; and `c-characterp' (`:558')
;;----------------------------------------------------------------------
;; Emacs's `c-with-syntax-table' is a macro over `unwind-protect'; the
;; thunk-taking `with-syntax-table' here is the same binding, and the
;; callers are the constant VALs and `c-filter-ops', which are
;; expressions.
(define (c-with-syntax-table table thunk)
  (with-syntax-table table thunk))

(define (c-int-to-char integer)
  ;; Emacs's is the identity - "In Emacs, a character is an integer."
  ;; In this tree a character is a Scheme character, so it converts; the
  ;; places the C wraps a code point this tree must too.
  (integer->char integer))

(define (c-characterp arg)
  (char? arg))

(define (c-keep-region-active)
  ;; `cc-defs.el:2092': "Do whatever is necessary to keep the region
  ;; active in XEmacs. This is not needed for Emacs." The C's whole body
  ;; is `(and (boundp 'zmacs-region-stays) (setq zmacs-region-stays t))'
  ;; - a variable only XEmacs has, so in Emacs the function is a no-op
  ;; that answers nil. It is called from `c-set-style', `c-set-offset'
  ;; and the cc-cmds commands, and answers #f here for the same reason.
  #f)

;;----------------------------------------------------------------------
;; `c-add-language' (`cc-defs.el:2477') and the language declarations
;; (`:2098')
;;----------------------------------------------------------------------
(define (c-add-language mode base-mode)
  ;; "Declare a new language in the language dependent variable system."
  ;; MODE must end with "-mode"; its prefix is the part before it, and
  ;; BASE-MODE makes constants the new language does not set fall back
  ;; to the base's.
  (let ((name (symbol->string mode)))
    (unless (and (> (string-length name) 5)
                 (string=? (substring name (- (string-length name) 5)
                                      (string-length name))
                           "-mode"))
      (error "The mode name symbol `~a' must end with \"-mode\"" mode))
    (put mode 'c-mode-prefix (substring name 0 (- (string-length name) 4)))
    (unless (get base-mode 'c-mode-prefix)
      (error "Unknown base mode `~a'" base-mode))
    (put mode 'c-fallback-mode base-mode)
    mode))

(put 'c-mode    'c-mode-prefix "c-")
(put 'c++-mode  'c-mode-prefix "c++-")
(put 'objc-mode 'c-mode-prefix "objc-")
(put 'java-mode 'c-mode-prefix "java-")
(put 'idl-mode  'c-mode-prefix "idl-")
(put 'pike-mode 'c-mode-prefix "pike-")
(put 'awk-mode  'c-mode-prefix "awk-")

;;----------------------------------------------------------------------
;; `c--mapcan' and the three `c--' set helpers (`cc-defs.el:169'-`:204')
;;----------------------------------------------------------------------
;; Emacs's are macros whose whole body chooses between two spellings -
;; `mapcan' or `cl-mapcan', `set-difference' or `cl-set-difference' -
;; depending on which the running Emacs has. Here the choice is fixed at
;; the `cl-' spelling (measured: `(fboundp 'set-difference)' is nil on
;; Emacs 31.1 with `cl-lib' loaded, so that is the branch Emacs takes
;; too) and a macro becomes a procedure, because the only thing its
;; expansion did was apply the `cl-' function to the same arguments.
;; `:test` and friends pass straight through, as `&rest other-args` does.
(define (%c-true x)
  ;; Emacs's truth test, for the values a ported `c-lang-defconst' VAL
  ;; computes: Emacs has one nil, and this tree has two - `#f` and the
  ;; empty list - and Scheme treats `'()' as true. `(if X ...)' over a
  ;; constant a language does not set is the common case: the constant
  ;; is `#f`, but a *derived* value such as `c-filter-ops`'s empty
  ;; answer is `'()', which Scheme would take for true. This is the
  ;; test the translated VALs use wherever Emacs tests a value.
  (not (or (eq? x #f) (null? x))))

(define (%c-false x)
  ;; `(not X)' in Emacs: true exactly for nil.
  (or (eq? x #f) (null? x)))

(define (c--mapcan fun liszt)
  ;; "CC Mode equivalent of `mapcan'".
  (mapcan fun liszt))

(define (c--set-difference liszt1 liszt2 . other-args)
  (apply cl-set-difference liszt1 liszt2 other-args))

(define (c--intersection liszt1 liszt2 . other-args)
  (apply cl-intersection liszt1 liszt2 other-args))

(define (c--delete-duplicates cl-seq . cl-keys)
  (apply cl-delete-duplicates cl-seq cl-keys))

;;----------------------------------------------------------------------
;; `c-lang-constant-names'
;;----------------------------------------------------------------------
;; Emacs has no such function: `c-kwds-lang-consts' walks the
;; `c-lang-constants' obarray with `mapatoms' (`cc-langs.el:3581').
;; There is no obarray here, so the registry answers its keys, sorted by
;; name - a deterministic order where `mapatoms` has obarray order (a
;; named departure; only the *membership* of this list reaches a
;; keyword list's value, never its order).
(define (c-lang-constant-names)
  (sort (hash-map->list (lambda (k v) k) %c-lang-constants)
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

;;----------------------------------------------------------------------
;; `c-mode-symbol' and `c-mode-var' (`cc-defs.el:2106', `:2119')
;;----------------------------------------------------------------------
(define (c-mode-symbol suffix)
  ;; "Prefix the current mode prefix (e.g. \"c-\") to SUFFIX and return
  ;; the corresponding symbol."
  (or (*c-buffer-is-cc-mode*)
      (error "Not inside a CC Mode based mode"))
  (let ((mode-prefix (get (*c-buffer-is-cc-mode*) 'c-mode-prefix)))
    (or mode-prefix
        (error "~a has no mode prefix known to `c-mode-symbol'"
               (*c-buffer-is-cc-mode*)))
    (string->symbol (string-append mode-prefix suffix))))

(define %c-mode-var--absent (list 'c-mode-var-absent))

(define %c-emacs-variable-readers (make-hash-table))

(define (c-register-emacs-variable-reader! symbol reader)
  ;; The bridge from an Emacs variable name to this tree's spelling of
  ;; it. `c-mode-var' reads a buffer-local slot for the language
  ;; variables; an ordinary Emacs variable (`defcustom') is a parameter
  ;; here, whose name carries the stars the convention gives it
  ;; (`c-font-lock-extra-types' is `*c-font-lock-extra-types*'), and a
  ;; name cannot be reached from a value cell. The library that defines
  ;; such a variable registers a reader under the *plain* Emacs name, and
  ;; `c-mode-var' answers it when the buffer has no slot. Emacs's
  ;; `(boundp (c-mode-symbol "font-lock-extra-types"))' test is this
  ;; registration's existence.
  (hashq-set! %c-emacs-variable-readers symbol reader)
  symbol)

(define (c-mode-var-boundp suffix)
  ;; Emacs's `(boundp (c-mode-symbol SUFFIX))' - the test `cc-langs.el'
  ;; makes around the `*-font-lock-extra-types' variables, one of which
  ;; (`awk-font-lock-extra-types') no Emacs defines at all, so awk's
  ;; `c-known-type-key' is built from its primitive types alone.
  (let ((symbol (c-mode-symbol suffix)))
    (cond ((assq symbol (*c-lang-var-overrides*)) #t)
          ((not (eq? (buffer-local-value (current-buffer) symbol
                                         %c-mode-var--absent)
                     %c-mode-var--absent))
           #t)
          (else (and (hashq-ref %c-emacs-variable-readers symbol) #t)))))

(define (c-mode-var suffix)
  ;; Emacs's `(symbol-value (c-mode-symbol SUFFIX))'. Its language
  ;; variables are buffer-local, and so are ours: the value is the
  ;; buffer-local slot of the current buffer (a named departure - there
  ;; is no symbol value cell here). A variable with no slot falls back
  ;; to the registered Emacs-variable reader (see above), and with
  ;; neither the variable is void, as Emacs's `symbol-value' says.
  (let ((symbol (c-mode-symbol suffix)))
    (let ((override (assq symbol (*c-lang-var-overrides*))))
      (if override
          (cdr override)
          (let ((value (buffer-local-value (current-buffer) symbol
                                           %c-mode-var--absent)))
            (cond
             ((not (eq? value %c-mode-var--absent)) value)
             ((hashq-ref %c-emacs-variable-readers symbol)
              => (lambda (reader) (reader)))
             (else (error "Void variable ~a" symbol))))))))

(define (c-got-face-at pos faces)
  ;; "Return non-nil if position POS in the current buffer has any of
  ;; the faces in the list FACES."
  (let ((pos-faces (get-text-property pos 'face)))
    (if (pair? pos-faces)
        (begin
          ;; `'()` is true in Scheme, so the walk's end is a `pair?'
          ;; test; and the answer is Emacs's nil, not the empty list.
          (while (and (pair? pos-faces)
                      (not (memq (car pos-faces) faces)))
            (setq pos-faces (cdr pos-faces)))
          (and (pair? pos-faces) pos-faces))
        (memq pos-faces faces))))

(define (c-face-name-p facename)
  ;; "Return t if FACENAME is the name of a face.  This method is
  ;; necessary since facep in XEmacs only returns t for the actual face
  ;; objects (while it's only their names that are used just about
  ;; anywhere else) without providing a predicate that tests face names."
  (memq facename (face-list)))

;;----------------------------------------------------------------------
;; `c-concat-separated', `c-make-bare-char-alt' and `c-make-keywords-re'
;; (`cc-defs.el:2145'-`:2214')
;;----------------------------------------------------------------------
(define (c-concat-separated list separator)
  ;; "Like `concat' on LIST, but separate each element with SEPARATOR.
  ;; Notably, null elements in LIST are ignored."
  (let loop ((l list) (acc #f))
    (cond ((null? l) (or acc ""))
          ((or (not (car l)) (null? (car l))) (loop (cdr l) acc))
          (else (loop (cdr l)
                      (if acc
                          (string-append acc separator (car l))
                          (car l)))))))

(define (c-make-bare-char-alt chars . rest)
  ;; "Make a character alternative string from the list of characters
  ;; CHARS. The returned string is of the type that can be used with
  ;; `skip-chars-forward' and `skip-chars-backward'.  If INVERTED is
  ;; non-nil, a caret is prepended to invert the set."
  ;;
  ;; Emacs's run-compressing algorithm, step for step: a run of three or
  ;; more characters becomes `a-z', a run of two is written out. The
  ;; arithmetic is done on code points as Emacs's is, and the list may
  ;; hold characters or integers.
  ;;--------------------------------------------------------------
  (let* ((inverted (and (pair? rest) (car rest)))
         (str (if inverted "^" ""))
         (codes (sort (map (lambda (c) (if (char? c) (char->integer c) c))
                           (or chars '()))
                      <)))
    ;; The C's `char' and `char2' are integers, so the walk is too; a
    ;; character object is made only to write the string.
    (let loop ((chars codes) (str str))
      (if (null? chars)
          str
          (let* ((char (car chars))
                 (chars (cdr chars))
                 (str (if (memv char (list 92 94 45))   ; \ ^ -
                          (string-append str "\\"
                                         (string (integer->char char)))
                          (string-append str (string (integer->char char)))))
                 ;; "Check for range."
                 (res (let inner ((cs chars) (char2 char))
                        (if (and (pair? cs) (>= (+ char2 1) (car cs)))
                            (inner (cdr cs) (car cs))
                            (cons char2 cs))))
                 (char2 (car res))
                 (cs (cdr res)))
            (cond ((= char char2) (loop cs str))
                  ((< (+ char 1) char2)
                   (loop cs (string-append str "-"
                                           (string (integer->char char2)))))
                  (else (loop (cons char2 cs) str))))))))

(define (%delete-nil list)
  ;; Emacs's `(remq nil LIST)' for our two nils.
  (let loop ((l list) (acc '()))
    (cond ((null? l) (reverse acc))
          ((or (not (car l)) (null? (car l))) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

(define (%c-symbol-token? table elt)
  ;; Emacs's `(string-match "\\`\\(\\sw\\|\\s_\\)*\\'" ELT)' with
  ;; TABLE current: that regexp is exactly "every character's class is
  ;; word or symbol", which this walks.
  (let loop ((i 0))
    (or (>= i (string-length elt))
        (let ((s (char-syntax-in table (string-ref elt i))))
          (and (or (char=? s #\w) (char=? s #\_))
               (loop (+ i 1)))))))

(define (c-make-keywords-re adorn list . rest)
  ;; "Make a regexp that matches any string in LIST. Duplicates and nil
  ;; elements in the list are removed." The strings are classified with
  ;; the language's syntax table, Emacs's
  ;; `(c-get-lang-constant 'c-make-mode-syntax-table nil mode)'
  ;; fallback path (the `c-<mode>-syntax-table' variable is not
  ;; consulted; see DEPARTURES.md).
  (let* ((mode (or (and (pair? rest) (car rest))
                   (*c-buffer-is-cc-mode*)
                   (error "No current language")))
         (table ((c-get-lang-constant 'c-make-mode-syntax-table #f mode)))
         (liszt (%delete-nil (or list '())))
         (symbols '())
         (non-symbols '()))
    (for-each (lambda (elt)
                (if (%c-symbol-token? table elt)
                    (set! symbols (cons elt symbols))
                    (set! non-symbols (cons elt non-symbols))))
              liszt)
    (cond ((null? liszt)
           (if adorn "\\(\\`a\\`\\)" "\\`a\\`"))
          ((and (pair? symbols) (pair? non-symbols))
           (string-append "\\(" (regexp-opt symbols 'symbols) "\\|"
                          (regexp-opt non-symbols #t) "\\)"))
          ((pair? symbols) (regexp-opt symbols 'symbols))
          (adorn (regexp-opt non-symbols #t))
          (else (regexp-opt non-symbols)))))

;;----------------------------------------------------------------------
;; The registry (`c-lang-constants', `cc-defs.el:2491')
;;----------------------------------------------------------------------
;;
;; Emacs interns the constants in an obarray and keeps the evaluated
;; values in the symbol's value cell (an alist keyed by mode), the
;; source definitions on its `source' property and the reverse
;; dependencies on `dependents'. The same four pieces live in a record
;; here.
;;----------------------------------------------------------------------
(define-record-type <c-lang-constant>
  (%make-c-lang-constant name source values dependents doc)
  c-lang-constant?
  (name c-lang-constant-name)
  ;; SOURCE is `((MODULE . BINDINGS) ...)', where BINDINGS is
  ;; `((MODES . THUNK) ...)' and MODES is `t' or a list of mode
  ;; symbols.
  (source c-lang-constant-source set-c-lang-constant-source!)
  ;; VALUES is a hash of mode symbol -> evaluated value.
  (values c-lang-constant-values)
  (dependents c-lang-constant-dependents set-c-lang-constant-dependents!)
  (doc c-lang-constant-doc set-c-lang-constant-doc!))

(define %c-lang-constants (make-hash-table))

(define (%filter pred list)
  ;; `filter', which Guile's `(scheme base)' does not export (checked);
  ;; this is the one use in the library.
  (let loop ((l list) (acc '()))
    (cond ((null? l) (reverse acc))
          ((pred (car l)) (loop (cdr l) (cons (car l) acc)))
          (else (loop (cdr l) acc)))))

(define (c-lang-constant-documentation name)
  ;; The docstring a `c-lang-defconst' carried, or #f.
  (let ((entry (hashq-ref %c-lang-constants name)))
    (and entry (c-lang-constant-doc entry))))

(define (c-lang-constant-entry name)
  ;; The record for NAME, made on first mention (Emacs's `intern' in
  ;; the obarray does the same).
  (or (hashq-ref %c-lang-constants name)
      (let ((entry (%make-c-lang-constant name '() (make-hash-table) '() #f)))
        (hashq-set! %c-lang-constants name entry)
        entry)))

(define %c-lang--novalue (list 'novalue))
;; ^ `c-lang--novalue' (`cc-defs.el:2804'): "no assignment found".

;; `c-lang-constants-under-evaluation' (`:2796'): alist of
;; `(SYMBOL . SOURCE-POS)' while a value is computed. SOURCE-POS is a
;; vector `#(SOURCE-TAIL ASSIGNMENT-TAIL)' whose contents are mutated
;; as the walk advances, which is what makes a self-reference continue
;; with the assignment *before* the one being evaluated.
(define *c-lang-constants-under-evaluation* (make-parameter '()))

;; `c-buffer-is-cc-mode': the language in force. Emacs sets it
;; buffer-locally in every mode's init; a parameter until `c-mode'
;; exists here (the tree's naming convention for a dynamically bound
;; variable).
(define *c-buffer-is-cc-mode* (make-parameter #f))

;; `c-langs-are-parametric' (`cc-defs.el:2540'): true while a
;; `c-lang-defconst' VAL is being evaluated, which is when
;; `c-major-mode-is' must expand to `c-lang-major-mode-is' - matching
;; fallback modes - rather than to the `memq' of ordinary code. Emacs
;; binds it around its own recursive expansion of the VAL; here the
;; VAL is source evaluated on demand, and the expansion happens inside
;; that `eval', so the parameter is seen.
(define *c-langs-are-parametric* (make-parameter #f))

;; `c-lang-const-expansion' (`cc-defs.el:2716'): Emacs's switch between
;; baking a constant's value into compiled code (nil), expanding to a
;; `c-get-lang-constant' *call* ('call), and 'immediate. `c-lang-defconst'
;; binds it to 'call around the macroexpansion of a VAL - "To make
;; `c-lang-const' expand to a straightforward call to
;; `c-get-lang-constant' in `c--macroexpand-all'" - so a VAL's references
;; to other constants are resolved when the VAL runs, which is what makes
;; forward references and self-references work. This port's VAL is
;; `eval'ed source, so the same binding has to be visible to the macro
;; expander inside that `eval'. (`immediate' is not carried: nothing
;; here asks for it.)
(define *c-lang-const-expansion* (make-parameter 'bake))

;; The dynamic binding of a language variable, which Emacs spells `let'.
;; A language variable here is a buffer-local slot rather than a symbol
;; value (`c-mode-var''s note), so Emacs's
;;
;;     (let ((c-nonsymbol-token-regexp "\\s."))
;;       (c-forward-token-2 ...))
;;
;; has nothing to bind. This alist of `(SYMBOL . VALUE)' is what those
;; `let's become; every reader of a language variable consults it first
;; - `c-mode-var' here and `%c-langvar' in cc-engine. A parameter, per
;; the convention's rule for a dynamically bound variable.
(define *c-lang-var-overrides* (make-parameter '()))

;;----------------------------------------------------------------------
;; The registration the macros call, and their helpers
;;----------------------------------------------------------------------
(define (c-lang-defconst-make-source-thunk val)
  ;; A thunk that evaluates VAL - source data - in the module that is
  ;; current *now* (the defining module), where every top-level
  ;; definition is in place by the time a value is requested.
  (let ((module (current-module)))
    (lambda ()
      (parameterize ((*c-langs-are-parametric* #t)
                     (*c-lang-const-expansion* 'call))
        (eval val module)))))

(define (c-lang-defconst-bindings pairs)
  ;; PAIRS is `((MODES . VAL-SOURCE) ...)'; the bindings list Emacs's
  ;; `c-lang-defconst' builds, with each VAL turned into its thunk.
  (map (lambda (pair)
         (cons (car pair) (c-lang-defconst-make-source-thunk (cdr pair))))
       pairs))

(define (c-define-lang-constant-here name doc bindings)
  ;; What the macro emits: register under the defining module's name.
  (when (string? doc)
    (set-c-lang-constant-doc! (c-lang-constant-entry name) doc))
  (c-define-lang-constant name (module-name (current-module)) bindings))

(define (c-lang-defconst-eval-now form)
  ;; `c-lang-defconst-eval-immediately''s runtime half: FORM is source
  ;; data, evaluated in the module doing the evaluation - with the
  ;; expansion switch at 'call, as inside any VAL.
  (parameterize ((*c-lang-const-expansion* 'call))
    (eval form (current-module))))

;;----------------------------------------------------------------------
;; `c-define-lang-constant' (`cc-defs.el:2664')
;;----------------------------------------------------------------------
(define (c-define-lang-constant name module-name bindings)
  ;; BINDINGS is `((MODES . THUNK) ...)' for one defining module,
  ;; in the order `c-lang-defconst' built (last assignment first).
  (let* ((entry (c-lang-constant-entry name))
         (source (c-lang-constant-source entry))
         (elem (assoc module-name source)))
    ;; "the order in the source alist is relevant. Like how
    ;; `c-lang-defconst' reverses the bindings, this reverses the order
    ;; between files so that the last to evaluate comes first."
    (unless elem
      (set! elem (list module-name))
      (set! source (cons elem source))
      (set-c-lang-constant-source! entry source))
    (set-cdr! elem bindings)
    ;; Bind the constant as a variable, or clear any earlier evaluated
    ;; value it has.
    (hash-clear! (c-lang-constant-values entry))
    ;; Clear the evaluated values that depend on this source,
    ;; transitively.
    (let loop ((agenda (c-lang-constant-dependents entry))
               (visited (make-hash-table)))
      (unless (null? agenda)
        (let ((sym (car agenda)))
          (if (hashq-ref visited sym)
              (loop (cdr agenda) visited)
              (begin
                (hashq-set! visited sym #t)
                (let* ((dep (c-lang-constant-entry sym))
                       (new (%filter (lambda (d) (not (hashq-ref visited d)))
                                     (c-lang-constant-dependents dep))))
                  (hash-clear! (c-lang-constant-values dep))
                  (loop (append new (cdr agenda)) visited)))))))
    name))

;;----------------------------------------------------------------------
;; `c-lang-defconst' (`cc-defs.el:2540')
;;----------------------------------------------------------------------
;;
;;   (c-lang-defconst NAME [DOC] LANG VAL ...)
;;
;; Neither NAME, LANG nor VAL is evaluated; LANG is a language symbol,
;; a list of them, or t for every language. Nothing is evaluated now:
;; a VAL is source data, evaluated when `c-lang-const' asks for it.
;;----------------------------------------------------------------------
(define (%c-language->mode lang)
  (cond ((eq? lang 't) 't)
        ((symbol? lang) (list (string->symbol (string-append
                                               (symbol->string lang)
                                               "-mode"))))
        ((list? lang) (map (lambda (l)
                             (unless (symbol? l)
                               (error "Not a list of symbols: ~s" lang))
                             (car (%c-language->mode l)))
                           lang))
        (else (error "Not a symbol or a list of symbols: ~s" lang))))

(define-syntax c-lang-defconst
  (lambda (stx)
    (syntax-case stx ()
      ((_ name rest ...)
       (let* ((nm (syntax->datum (syntax name)))
              (args (syntax->datum (syntax (rest ...)))))
         (unless (symbol? nm)
           (error "Not a symbol: ~s" nm))
         (let* ((doc? (and (pair? args) (string? (car args))))
                (doc (if doc? (car args) #f))
                (args (if doc? (cdr args) args)))
           (unless (pair? args)
             (error "No assignments in `c-lang-defconst' for ~s" nm))
           (let build ((a args) (pairs '()))
             (if (null? a)
                 (with-syntax ((n* (datum->syntax (syntax name) nm))
                               (d* (datum->syntax (syntax name) doc))
                               (p* (datum->syntax (syntax name) pairs)))
                   #'(eval-when (expand load eval)
                       (c-define-lang-constant-here 'n* d*
                         (c-lang-defconst-bindings 'p*))))
                 (let ((lang (car a)))
                   (unless (pair? (cdr a))
                     (error "No value for ~s" lang))
                   (build (cddr a)
                          (cons (cons (%c-language->mode lang) (cadr a))
                                pairs)))))))))))

;;----------------------------------------------------------------------
;; `c-lang-const' (`cc-defs.el:2717')
;;----------------------------------------------------------------------
(define (%c-literal-datum? x)
  ;; Can X be written into compiled code as a literal? Functions,
  ;; records and the like cannot, and go through the runtime lookup.
  (cond ((or (string? x) (number? x) (char? x) (boolean? x) (symbol? x)) #t)
        ((null? x) #t)
        ((pair? x) (and (%c-literal-datum? (car x)) (%c-literal-datum? (cdr x))))
        ((vector? x) (let loop ((i 0))
                       (or (>= i (vector-length x))
                           (and (%c-literal-datum? (vector-ref x i))
                                (loop (+ i 1))))))
        (else #f)))

(define (c-literal-datum? x)
  ;; The literal test the language-variable system uses to decide
  ;; whether a value can be baked into generated code.
  (%c-literal-datum? x))

(define-syntax c-lang-const
  (lambda (stx)
    (syntax-case stx ()
      ((_ name)
       ;; No LANG: the value depends on the buffer's language, so it is
       ;; always a runtime call (`c-buffer-is-cc-mode').
       (let ((nm (syntax->datum (syntax name))))
         (unless (symbol? nm) (error "Not a symbol: ~s" nm))
         (with-syntax ((n* (datum->syntax (syntax name) nm)))
           #'(c-get-lang-constant 'n*))))
      ((_ name lang)
       (let ((nm (syntax->datum (syntax name)))
             (l (syntax->datum (syntax lang))))
         (unless (symbol? nm) (error "Not a symbol: ~s" nm))
         (unless (symbol? l) (error "Not a symbol: ~s" l))
         (let ((mode (car (%c-language->mode l))))
           (unless (get mode 'c-mode-prefix)
             (error "Unknown language ~s: no `c-mode-prefix' property" l))
           (with-syntax ((n* (datum->syntax (syntax name) nm))
                         (m* (datum->syntax (syntax lang) mode)))
             (if (eq? (*c-lang-const-expansion*) 'call)
                 #'(c-get-lang-constant 'n* #f 'm*)
                 (guard (e (#t #'(c-get-lang-constant 'n* #f 'm*)))
                   (let ((v (c-get-lang-constant nm #f mode)))
                     (if (%c-literal-datum? v)
                         (with-syntax ((v* (datum->syntax (syntax name) v)))
                           #'(quote v*))
                         #'(c-get-lang-constant 'n* #f 'm*))))))))))))

;;----------------------------------------------------------------------
;; `c-lang-defconst-eval-immediately' (`cc-defs.el:2531')
;;----------------------------------------------------------------------
(define-syntax c-lang-defconst-eval-immediately
  ;; "Can be used inside a VAL in `c-lang-defconst' to evaluate FORM
  ;; immediately."
  ;;
  ;; **The expansion is the evaluated form itself**, as Emacs's is:
  ;; `(defmacro c-lang-defconst-eval-immediately (form) (eval form))'
  ;; evaluates the argument at macro-expansion time and *returns that
  ;; value as the expansion*, so what the quasiquote built - a call form
  ;; like `(append (c-lang-const a) ...)' - is then evaluated as code.
  ;; (Expanding to `(eval ...)` instead returns the call form as a
  ;; value, which is how the first port of this was wrong: the keyword
  ;; list came out as the symbol `append' and a list of unevaluated
  ;; `c-lang-const' forms.)
  ;;
  ;; Emacs evals at macro-expansion time; here a VAL is source evaluated
  ;; on demand, so this evals at that moment, in the defining module.
  (lambda (stx)
    (syntax-case stx ()
      ((_ form)
       (datum->syntax (syntax form)
                      (c-lang-defconst-eval-now
                       (syntax->datum (syntax form))))))))

;;----------------------------------------------------------------------
;; `c-get-lang-constant' (`cc-defs.el:2815')
;;----------------------------------------------------------------------
(define (c-get-lang-constant name . rest)
  ;; `(c-get-lang-constant NAME [SOURCE-FILES [MODE]])'. MODE defaults
  ;; to `c-buffer-is-cc-mode'.
  (let ((source-files (and (pair? rest) (car rest)))
        (mode (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
    (or mode
        (set! mode (*c-buffer-is-cc-mode*))
        (error "No current language"))
    (let* ((entry (c-lang-constant-entry name))
           (source (c-lang-constant-source entry)))
      ;; "Record the dependencies between this symbol and the one we're
      ;; being evaluated in."
      (when (pair? (*c-lang-constants-under-evaluation*))
        (let ((eval-in-sym (car (car (*c-lang-constants-under-evaluation*)))))
          (unless (memq eval-in-sym (c-lang-constant-dependents entry))
            (set-c-lang-constant-dependents!
             entry (cons eval-in-sym (c-lang-constant-dependents entry))))))
      ;; "Make sure the source files have entries on the `source'
      ;; property so that loading will take place when necessary."
      ;; A source file is a module here; it is already loaded (an
      ;; explicit import), so only the entry is ensured.
      (let loop ((files source-files))
        (when (pair? files)
          (unless (assoc (car files) source)
            (set! source (cons (list (car files)) source))
            (set-c-lang-constant-source! entry source)
            (hash-clear! (c-lang-constant-values entry)))
          (loop (cdr files))))
      (let ((handle (hashq-get-handle (c-lang-constant-values entry) mode)))
        (if handle
            (cdr handle)
            (let ((source-pos (or (assq name (*c-lang-constants-under-evaluation*))
                                  (cons name (vector source #f)))))
              ;; The entry is appended even when an earlier one is
              ;; found: the dependency recording above needs the whole
              ;; stack.
              (parameterize ((*c-buffer-is-cc-mode* mode)
                             (*c-lang-constants-under-evaluation*
                              (cons source-pos
                                    (*c-lang-constants-under-evaluation*))))
                (let* ((fallback (get mode 'c-fallback-mode))
                       (value
                        (if fallback
                            ;; "First try the original mode but don't
                            ;; accept an entry matching all languages
                            ;; since the fallback mode might have an
                            ;; explicit entry before that. Try again
                            ;; with the fallback mode from the original
                            ;; position."
                            (let ((backup (vector-copy (cdr source-pos))))
                              (let ((v (c-find-assignment-for-mode
                                        (cdr source-pos) mode #f name)))
                                (if (eq? v %c-lang--novalue)
                                    (begin
                                      (set-cdr! source-pos backup)
                                      (c-find-assignment-for-mode
                                       (cdr source-pos) fallback #t name))
                                    v)))
                            (c-find-assignment-for-mode
                             (cdr source-pos) mode #t name))))
                  (when (eq? value %c-lang--novalue)
                    (error "`~a' got no (prior) value in ~a (might be a cyclic reference)"
                           name mode))
                  ;; Emacs "first messages 'Eval error in the
                  ;; `c-lang-defconst' for `%S' in %s:' and then
                  ;; re-signals the original condition" (`cc-defs.el'),
                  ;; which is what this does - the original error reaches
                  ;; the caller, so its own message is the one seen.
                  ;; Emacs first *messages* "Eval error in the
                  ;; `c-lang-defconst' for `%S' in %s:" and then
                  ;; re-signals the original condition; this re-signals
                  ;; it without the message (a named departure: the
                  ;; message would be written to stderr, which the
                  ;; editor owns), so the caller sees the real error.
                  (let ((v (guard (e (#t (raise e)))
                             (value))))
                    (hashq-set! (c-lang-constant-values entry) mode v)
                    v)))))))))

;;----------------------------------------------------------------------
;; `c-find-assignment-for-mode' (`cc-defs.el:2898')
;;----------------------------------------------------------------------
(define (c-find-assignment-for-mode source-pos mode match-any-lang name)
  ;; Find the first assignment entry that applies to MODE at or after
  ;; SOURCE-POS, advancing SOURCE-POS past it. SOURCE-POS is
  ;; `#(SOURCE-TAIL ASSIGNMENT-TAIL)'; the first element is the tail of
  ;; the source alist (each element `(MODULE . BINDINGS)') and the
  ;; second the tail of a bindings list. Answers
  ;; `%c-lang--novalue' when none is found.
  ;;
  ;; Emacs loads a file whose bindings are missing; a module that was
  ;; never loaded has no entry here, so there is nothing to load - a
  ;; named departure.
  (let loop ((file-entry (vector-ref source-pos 0))
             (assignment-entry (vector-ref source-pos 1)))
    (cond
     ((pair? assignment-entry)
      (let ((assignment (car assignment-entry)))
        (vector-set! source-pos 1 (cdr assignment-entry))
        (if (if (pair? (car assignment))
                (memq mode (car assignment))
                match-any-lang)
            (cdr assignment)
            (loop file-entry (cdr assignment-entry)))))
     ((pair? file-entry)
      ;; "Handled the last assignment from one file, begin on the next."
      (let ((bindings (cdr (car file-entry))))
        (vector-set! source-pos 1 bindings)
        (vector-set! source-pos 0 (cdr file-entry))
        (if (pair? bindings)
            (loop (cdr file-entry) bindings)
            %c-lang--novalue)))
     (else %c-lang--novalue))))

;;----------------------------------------------------------------------
;; `c-major-mode-is' (`cc-defs.el:1153')
;;----------------------------------------------------------------------
(define-syntax c-major-mode-is
  (lambda (stx)
    (syntax-case stx ()
      ((_ mode)
       (if (*c-langs-are-parametric*)
           ;; Inside a `c-lang-defconst' VAL: match fallback modes too.
           (with-syntax ((m* (datum->syntax (syntax mode)
                                            (syntax->datum (syntax mode)))))
             #'(c-lang-major-mode-is m*))
           ;; `cc-defs.el:1162'-`:1171': a quoted *mode symbol* is an
           ;; `eq' test, a quoted *list* of them a `memq', and a
           ;; non-literal MODE is evaluated once and then tested the
           ;; same way. Emitting `memq' for a single symbol (`(memq m
           ;; (quote pike-mode))') is a run-time error - `c-backward-sws'
           ;; is the first caller outside a `c-lang-defconst' to find
           ;; out.
           (let ((d (syntax->datum (syntax mode))))
             (if (and (pair? d) (eq? (car d) 'quote))
                 (let ((m (cadr d)))
                   (with-syntax ((ms (datum->syntax (syntax mode) m)))
                     (if (list? m)
                         #'(memq (*c-buffer-is-cc-mode*) 'ms)
                         #'(eq? (*c-buffer-is-cc-mode*) 'ms))))
                 (with-syntax ((m* (datum->syntax (syntax mode) d)))
                   #'(let ((mode m*))
                       (if (list? mode)
                           (memq (*c-buffer-is-cc-mode*) mode)
                           (eq? (*c-buffer-is-cc-mode*) mode)))))))))))

;;----------------------------------------------------------------------
;; `c-lang-major-mode-is' (`cc-defs.el:2967')
;;----------------------------------------------------------------------
(define (c-lang-major-mode-is mode)
  ;; "`c-major-mode-is' expands to a call to this function inside
  ;; `c-lang-defconst'. Here we also match the mode(s) against any
  ;; fallback modes for the one in `c-buffer-is-cc-mode'."
  (let ((modes (if (list? mode) mode (list mode))))
    (let loop ((buf-mode (*c-buffer-is-cc-mode*)))
      (cond ((memq buf-mode modes) #t)
            ((get buf-mode 'c-fallback-mode)
             (loop (get buf-mode 'c-fallback-mode)))
            (else #f)))))


;;----------------------------------------------------------------------
;; `c-save-buffer-state' (`cc-defs.el:616')
;;----------------------------------------------------------------------
;; "Bind variables according to VARLIST (in `let*' style) and eval BODY,
;; then restore the buffer state under the assumption that no
;; significant modification has been made in BODY." Since Emacs 24 the
;; macro is one call to `with-silent-modifications', which is the branch
;; ported; the pre-24 fallback - a `let*' of `buffer-undo-list',
;; `inhibit-read-only', `deactivate-mark' and the two change-hook lists
;; around an `unwind-protect' - is not carried, because the primitive it
;; exists to stand in for is here.
(define-syntax c-save-buffer-state
  (syntax-rules ()
    ((_ (bindings ...) body ...)
     (with-silent-modifications (let* (bindings ...) body ...)))))


;;----------------------------------------------------------------------
;; The character-property helpers (`cc-defs.el:1230'-`:1478')
;;----------------------------------------------------------------------
;; Emacs's are macros that `eval' PROPERTY at expansion time and pick an
;; Emacs-version branch; here they are procedures and PROPERTY is an
;; argument, which is the same contract with the constant supplied at run
;; time. The XEmacs (`c-use-extents') arms and the Emacs < 21 arms are
;; not carried: this tree has no extents and `text-property-default-
;; nonsticky' is `intervals.scm''s, so the Emacs >= 21 arm - which
;; assumes `rear-nonsticky' is already covered by that variable - is the
;; one that applies. A `syntax-table' write moves `c-syntax-table-hwm'
;; down, as the C's arm does for the state cache (`cc-engine.el''s
;; `c-invalidate-state-cache' reads it); nothing reads it yet.
;;
;; `c-min-property-position' is Emacs's own answer for "no such
;; position": `most-positive-fixnum', not nil.
(define c-syntax-table-hwm most-positive-fixnum)

(define (c-put-char-property pos property value)
  ;; "Put the given property with the given value on the character at
  ;; POS." This macro does a hidden buffer change.
  (when (eq? property 'syntax-table)
    (set! c-syntax-table-hwm (min c-syntax-table-hwm pos)))
  (put-text-property pos (+ pos 1) property value))

(define (c-get-char-property pos property)
  ;; "Get the value of the given property on the character at POS if
  ;; it's been put there by `c-put-char-property'."
  (get-text-property pos property))

(define (c-clear-char-property pos property)
  ;; "Remove the given property on the character at POS if it's been put
  ;; there by `c-put-char-property'." This macro does a hidden buffer
  ;; change.
  (when (eq? property 'syntax-table)
    (set! c-syntax-table-hwm (min c-syntax-table-hwm pos)))
  (remove-text-properties pos (+ pos 1) (list property #f)))

(define (c-next-single-property-change position prop object limit)
  ;; `cc-defs.el:477': Emacs's `next-single-property-change', with the
  ;; XEmacs `next-single-char-property-change' arm not carried.
  (next-single-property-change position prop object limit))

(define (c-min-property-position from to property)
  ;; "Return the first position in the range [FROM TO) where the text
  ;; property PROPERTY is set, or `most-positive-fixnum' if there is no
  ;; such position."
  (cond ((and (< from to) (get-text-property from property)) from)
        (else (let ((pos (c-next-single-property-change from property #f to)))
                (if (< pos to) pos most-positive-fixnum)))))

(define (c-put-char-properties from to property value)
  ;; "Put the given PROPERTY with the given VALUE on the characters
  ;; between FROM and TO." This macro does hidden buffer changes.
  (when (eq? property 'syntax-table)
    (set! c-syntax-table-hwm (min c-syntax-table-hwm from)))
  (put-text-property from to property value))

(define (c-clear-char-properties from to property)
  ;; "Remove all the occurrences of the given property in the given
  ;; region that has been put with `c-put-char-property'. The returned
  ;; value is the buffer position of the lowest character whose PROPERTY
  ;; was removed, or nil if there was none."
  (let ((ret (c-min-property-position from to property)))
    (if (< ret to)
        (begin
          (when (eq? property 'syntax-table)
            (set! c-syntax-table-hwm (min c-syntax-table-hwm ret)))
          (remove-text-properties ret to (list property #f))
          ret)
        #f)))

(define (c-put-string-fence pos)
  ;; "Put the string-fence syntax-table text property at POS. Since the
  ;; character there cannot then count as syntactic whitespace, clear the
  ;; properties `c-is-sws' and `c-in-sws' (see the functions
  ;; `c-forward-sws' and `c-backward-sws' in cc-engine.el for details)."
  ;; Emacs's macro also wraps POS in `-pos-'; as a procedure the argument
  ;; is evaluated once by the caller.
  (c-put-char-property pos 'syntax-table '(15))
  (c-clear-char-property pos 'c-is-sws)
  (c-clear-char-property pos 'c-in-sws))

;;----------------------------------------------------------------------
;; The three searches for a char with a property value (`cc-defs.el:1595'-`:1695')
;;----------------------------------------------------------------------
;; Emacs's are macros whose CHAR is spliced into `(char-to-string ,char)'
;; and whose LIMIT is optional; here they are procedures with LIMIT the
;; last argument and `#f' meaning absent, the tree's spelling for an
;; optional argument. The value comparison is `equal', as the docstrings
;; say. `(search-forward-regexp "\\(\n\\|.\\)")' is `re-search-forward'
;; (they are the same function in Emacs) with the regexp's newline a real
;; newline character, which is what Emacs's string literal holds.
;;
;; "Leave point just after the character, and set the match data on this
;; character, and return point. If the search fails, return nil; point is
;; then left undefined."
;;
;; Not carried yet: the `c-clear-char-property-with-value*' family
;; (`cc-defs.el:1555'-`:1590', `:1697'-`:1760'), which the mode's change
;; hooks (`cc-mode.el') use; they come with those hooks.

(define (c-search-forward-char-property-with-value-on-char property value char limit)
  ;; "Search forward for a text-property PROPERTY having value VALUE on a
  ;; character with value CHAR. LIMIT bounds the search."
  (let ((char-skip (string-append "^" (string char)))
        (limit (or limit (point-max))))
    (while (and (begin
                  (skip-chars-forward char-skip limit)
                  (< (point) limit))
                (not (equal? (c-get-char-property (point) property) value)))
      (forward-char 1))
    (when (< (point) limit)
      (re-search-forward "\\(\n\\|.\\)")    ; to set the match-data.
      (point))))

(define (c-search-backward-char-property-with-value-on-char property value char limit)
  ;; "Search backward for a text-property PROPERTY having value VALUE on a
  ;; character with value CHAR. LIMIT bounds the search."
  ;;
  ;; "Leave point just before the character, ..."
  (let ((char-skip (string-append "^" (string char)))
        (limit (or limit (point-min))))
    (while (and (begin
                  (skip-chars-backward char-skip limit)
                  (> (point) limit))
                (not (equal? (c-get-char-property (- (point) 1) property)
                             value)))
      (backward-char 1))
    (when (> (point) limit)
      (re-search-backward "\\(\n\\|.\\)")   ; to set the match-data.
      (point))))

(define (c-search-forward-char-property property value limit)
  ;; "Search forward for a text-property PROPERTY having value VALUE.
  ;; LIMIT bounds the search. The comparison is done with `equal'."
  ;;
  ;; "Leave point just after the character, and set the match data on this
  ;; character, and return point. If VALUE isn't found, Return nil; point is
  ;; then left undefined."
  (let ((place (point))
        (limit (or limit (point-max))))
    (while (and (< place limit)
                (not (equal? (c-get-char-property place property) value)))
      (setq place (c-next-single-property-change place property #f limit)))
    (when (< place limit)
      (goto-char place)
      (re-search-forward "\\(\n\\|.\\)")   ; to set the match-data.
      (point))))

(define (c-search-forward-non-nil-char-property property limit)
  ;; "Search forward for a text-property PROPERTY value non-nil. LIMIT
  ;; bounds the search."
  ;;
  ;; "Leave point just after the character. The match data remain
  ;; unchanged. Return the value of PROPERTY. If a non-nil value isn't
  ;; found, return nil; point is then left undefined."
  (let* ((limit (or limit (point-max)))
         (value (c-get-char-property (point) property)))
    (cond
     ((>= (point) limit)
      #f)
     (value
      (forward-char)
      value)
     (else
      ;; Emacs's `when' answers nil when the test fails, and the value is
      ;; this procedure's answer - `c-unmark-<>-around-region' loops on
      ;; it, so it must be `#f' and not the unspecified value.
      (let ((place (c-next-single-property-change (point) property #f limit)))
        (if (and place (< place limit))
            (begin
              (goto-char (+ place 1))
              (c-get-char-property place property))
            #f))))))

(define (c-search-backward-char-property property value limit)
  ;; "Search backward for a text-property PROPERTY having value VALUE.
  ;; LIMIT bounds the search. The comparison is done with `equal'."
  ;;
  ;; "Leave point just before the character, set the match data on this
  ;; character, and return point. If VALUE isn't found, Return nil; point is
  ;; then left undefined."
  (let ((place (point))
        (limit (or limit (point-min))))
    (while (and (> place limit)
                (not (equal? (c-get-char-property (- place 1) property) value)))
      (setq place (previous-single-property-change place property #f limit)))
    (when (> place limit)
      (goto-char place)
      (re-search-backward "\\(\n\\|.\\)")  ; to set the match-data.
      (point))))

(define (c-search-forward-char-property-without-value-on-char property value char limit)
  ;; "Search forward for a character CHAR without text property PROPERTY
  ;; having a value CHAR. LIMIT bounds the search."
  (let ((char-skip (string-append "^" (string char)))
        (limit (or limit (point-max))))
    (while (and (begin
                  (skip-chars-forward char-skip limit)
                  (< (point) limit))
                (equal? (c-get-char-property (point) property) value))
      (forward-char 1))
    (when (< (point) limit)
      (re-search-forward "\\(\n\\|.\\)")    ; to set the match-data.
      (point))))

;;----------------------------------------------------------------------
;; The `<'/`>' paren syntax categories (`cc-defs.el:1190'-`:1205')
;;----------------------------------------------------------------------
;; On GNU Emacs a marked template bracket's `syntax-table' property is
;; *indirect*: the character carries a `category' property naming one of
;; these two symbols, and the symbol's own `syntax-table' property is
;; the descriptor. That is what lets
;; `c-suppress-<->-as-parens' toggle every template bracket in every
;; buffer at once. `intervals.scm''s `lookup-char-property' walks the
;; same path for `get-text-property', so a category-marked bracket reads
;; back its descriptor here as it does in Emacs. The values are the C's:
;; `(4 . ?>)' and `(5 . ?<)'.
(define c-<-as-paren-syntax '(4 . 62))
(put 'c-<-as-paren-syntax 'syntax-table c-<-as-paren-syntax)
(define c->-as-paren-syntax '(5 . 60))
(put 'c->-as-paren-syntax 'syntax-table c->-as-paren-syntax)

;; "Constant to decide at compilation time whether to use category
;; properties. Currently (2010-03) they're available only on GNU Emacs."
;; Emacs probes the running Emacs; here the answer is known.
(define c-use-category #t)

;; `c-mark-<-as-paren' and its two siblings are macros in `cc-defs.el'
;; (`:1846'-`:1878') that `eval-when-compile' `c-use-category'; here
;; they are procedures and the flag is read at run time.
(define (c-mark-<-as-paren pos)
  ;; "Mark the \"<\" character at POS as a template opener using the
  ;; `syntax-table' property either directly (XEmacs) or via a
  ;; `category' property (GNU Emacs)."
  ;;
  ;; "This function does a hidden buffer change. ..."
  (c-put-char-property pos 'category 'c-<-as-paren-syntax))

(define (c-mark->-as-paren pos)
  ;; "Mark the \">\" character at POS as an sexp list closer using the
  ;; `syntax-table' property either directly (XEmacs) or via a
  ;; `category' property (GNU Emacs)."
  (c-put-char-property pos 'category 'c->-as-paren-syntax))

(define (c-unmark-<-or->-as-paren pos)
  ;; "Unmark the \"<\" or \">\" character at POS as an sexp list opener
  ;; using the `syntax-table' property either directly or indirectly
  ;; through a `category' text property."
  ;;
  ;; "This function does a hidden buffer change. ..."
  (c-clear-char-property pos 'category))

(define (c-suppress-<->-as-parens)
  ;; "Suppress the syntactic effect of all marked < and > as parens.
  ;; Note that this effect is NOT buffer local. ..."
  (put 'c-<-as-paren-syntax 'syntax-table #f)
  (put 'c->-as-paren-syntax 'syntax-table #f))

(define (c-restore-<->-as-parens)
  ;; "Restore the syntactic effect of all marked <s and >s as parens.
  ;; This has no effect on unmarked <s and >s"
  (put 'c-<-as-paren-syntax 'syntax-table c-<-as-paren-syntax)
  (put 'c->-as-paren-syntax 'syntax-table c->-as-paren-syntax))


;;----------------------------------------------------------------------
;; `c-skip-ws-chars-forward'/`-backward' (`cc-defs.el:1118', `:1134')
;;----------------------------------------------------------------------
;; Emacs's are macros; here they are procedures with LIM as the
;; optional argument. "Note that \n usually has comment-end syntax."
(define (c-skip-ws-chars-forward string . lim-args)
  ;; "Move point forward, stopping before a char which isn't in STRING,
  ;; or a char whose syntax isn't whitespace or comment-end, or at pos
  ;; LIM. ... Returns the distance traveled, either zero or positive."
  (let* ((lim (if (pair? lim-args) (car lim-args) #f))
         (here (point))
         (count (skip-chars-forward string lim)))
    (if (> count 0)
        (begin
          (goto-char here)
          (skip-syntax-forward " >" (+ here count)))
        count)))

(define (c-skip-ws-chars-backward string . lim-args)
  ;; "Move point backward, stopping after a char which isn't in STRING,
  ;; or a char whose syntax isn't whitespace or comment-end, or at pos
  ;; LIM. ... Returns the distance traveled, either zero or negative."
  (let* ((lim (if (pair? lim-args) (car lim-args) #f))
         (here (point))
         (count (skip-chars-backward string lim)))
    (if (< count 0)
        (begin
          (goto-char here)
          (skip-syntax-backward " >" (+ here count)))
        count)))

(define (c-skip-ws-forward . limit-args)
  ;; "Skip over any whitespace following point. This function skips
  ;; over horizontal and vertical whitespace and line continuations."
  ;; Emacs's macro; a procedure with LIMIT as the optional argument.
  (let ((limit (if (pair? limit-args) (car limit-args) #f)))
    (if limit
        (let loop ()
          (when (begin
                  ;; "skip-syntax-* doesn't count \n as whitespace.."
                  (skip-chars-forward " \t\n\r\f\v" limit)
                  (and (eq? (char-after (point)) #\\)
                       (< (point) limit)
                       (begin
                         (forward-char)
                         (or (eolp)
                             (begin (backward-char) #f)))))
            (loop)))
        (let loop ()
          (when (begin
                  (skip-chars-forward " \t\n\r\f\v")
                  (and (eq? (char-after (point)) #\\)
                       (begin
                         (forward-char)
                         (or (eolp)
                             (begin (backward-char) #f)))))
            (loop))))))

(define (c-skip-ws-backward . limit-args)
  ;; "Skip over any whitespace preceding point. This function skips
  ;; over horizontal and vertical whitespace and line continuations."
  (let ((limit (if (pair? limit-args) (car limit-args) #f)))
    (if limit
        (let loop ()
          (when (begin
                  ;; "skip-syntax-* doesn't count \n as whitespace.."
                  (skip-chars-backward " \t\n\r\f\v" limit)
                  (and (eolp)
                       (eq? (char-before) #\\)
                       (> (point) limit)))
            (backward-char)
            (loop)))
        (let loop ()
          (when (begin
                  (skip-chars-backward " \t\n\r\f\v")
                  (and (eolp)
                       (eq? (char-before) #\\)))
            (backward-char)
            (loop))))))

(define (c-previous-single-property-change position prop object limit)
  ;; `cc-defs.el:487': Emacs's `previous-single-property-change', with
  ;; the XEmacs `previous-single-char-property-change' arm not carried.
  (previous-single-property-change position prop object limit))

;;----------------------------------------------------------------------
;; The `scan-lists' wrappers (`cc-defs.el:541', `:780'-`:930')
;;----------------------------------------------------------------------
;; Emacs's `c-safe' catches `error' only, so a C-g passes through; this
;; tree's quit is the `<quit-condition>' record `command.scm' raises, so
;; it is re-raised by hand and everything else answers #f.
(define-syntax c-safe
  (syntax-rules ()
    ((_ body ...)
     (guard (e ((quit-condition? e) (raise e))
               (else #f))
       body ...))))

(define (c-forward-sexp . count-args)
  ;; "Move forward across COUNT balanced expressions. A negative COUNT
  ;; means move backward. Signal an error if the move fails for any
  ;; reason. This is like `forward-sexp' except that it isn't
  ;; interactive ... and that it isn't susceptible to user
  ;; configurations such as disabling of signals in certain
  ;; situations."
  (goto-char (scan-sexps (point) (if (pair? count-args) (car count-args) 1))))

(define (c-backward-sexp . count-args)
  ;; "See `c-forward-sexp' and reverse directions."
  (c-forward-sexp (- (if (pair? count-args) (car count-args) 1))))

(define (c-safe-scan-lists from count depth . limit-args)
  ;; "Like `scan-lists' but returns nil instead of signaling errors for
  ;; unbalanced parens. A limit for the search may be given. FROM is
  ;; assumed to be on the right side of it."
  (let ((limit (if (pair? limit-args) (car limit-args) #f)))
    (if limit
        (save-restriction
          (if (< count 0)
              (narrow-to-region limit (point-max))
              (narrow-to-region (point-min) limit))
          (c-safe (scan-lists from count depth)))
        (c-safe (scan-lists from count depth)))))

(define (c-go-list-forward . args)
  ;; "Move forward across one balanced group of parentheses starting at
  ;; POS or point. Return POINT when we succeed, NIL when we fail. In
  ;; the latter case, leave point unmoved. A LIMIT for the search may
  ;; be given. The start position is assumed to be before it."
  (let* ((pos (if (pair? args) (car args) #f))
         (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
         (dest (c-safe-scan-lists (if pos pos (point)) 1 0 limit)))
    (if dest (begin (goto-char dest) dest) #f)))

(define (c-go-list-backward . args)
  ;; "Move backward across one balanced group of parentheses starting
  ;; at POS or point. ... The start position is assumed to be after
  ;; it."
  (let* ((pos (if (pair? args) (car args) #f))
         (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
         (dest (c-safe-scan-lists (if pos pos (point)) -1 0 limit)))
    (if dest (begin (goto-char dest) dest) #f)))

(define (c-up-list-forward . args)
  ;; "Return the first position after the list sexp containing POS, or
  ;; nil if no such position exists. The point is used if POS is left
  ;; out."
  (let ((pos (if (pair? args) (car args) #f))
        (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
    (c-safe-scan-lists (if pos pos (point)) 1 1 limit)))

(define (c-up-list-backward . args)
  ;; "Return the position of the start of the list sexp containing POS,
  ;; or nil if no such position exists."
  (let ((pos (if (pair? args) (car args) #f))
        (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
    (c-safe-scan-lists (if pos pos (point)) -1 1 limit)))

(define (c-down-list-forward . args)
  ;; "Return the first position inside the first list sexp after POS, or
  ;; nil if no such position exists."
  (let ((pos (if (pair? args) (car args) #f))
        (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
    (c-safe-scan-lists (if pos pos (point)) 1 -1 limit)))

(define (c-down-list-backward . args)
  ;; "Return the last position inside the last list sexp before POS, or
  ;; nil if no such position exists."
  (let ((pos (if (pair? args) (car args) #f))
        (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
    (c-safe-scan-lists (if pos pos (point)) -1 -1 limit)))

(define (c-go-up-list-forward . args)
  ;; "Move the point to the first position after the list sexp
  ;; containing POS, or containing the point if POS is left out. Return
  ;; t if such a position exists, otherwise nil is returned and the
  ;; point isn't moved."
  (let ((dest (apply c-up-list-forward args)))
    (if dest (begin (goto-char dest) #t) #f)))

(define (c-go-up-list-backward . args)
  ;; "Move the point to the position of the start of the list sexp
  ;; containing POS, or containing the point if POS is left out."
  (let ((dest (apply c-up-list-backward args)))
    (if dest (begin (goto-char dest) #t) #f)))

(define (c-go-down-list-forward . args)
  ;; "Move the point to the first position inside the first list sexp
  ;; after POS, or before the point if POS is left out."
  (let ((dest (apply c-down-list-forward args)))
    (if dest (begin (goto-char dest) #t) #f)))

(define (c-go-down-list-backward . args)
  ;; "Move the point to the last position inside the last list sexp
  ;; before POS, or before the point if POS is left out."
  (let ((dest (apply c-down-list-backward args)))
    (if dest (begin (goto-char dest) #t) #f)))

)
)
