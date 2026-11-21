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
                  hash-clear! current-module module-name eval-when eval sort
                  syntax with-syntax syntax-case syntax->datum datum->syntax)
    (only (schemacs editor intervals) get put)
    (only (schemacs editor buffer) current-buffer buffer-local-value)
    (only (schemacs editor search) string-match)
    (only (schemacs regexp-opt) regexp-opt))

  (export
   c-lang-defconst c-lang-const c-lang-defconst-eval-immediately
   c-get-lang-constant c-find-assignment-for-mode
   c-define-lang-constant c-define-lang-constant-here
   c-lang-defconst-bindings c-lang-defconst-thunk
   c-lang-defconst-eval-now
   c-add-language c-lang-major-mode-is *c-buffer-is-cc-mode*
   c-mode-symbol c-mode-var c-concat-separated c-make-bare-char-alt
   c-make-keywords-re c-lang-constant-documentation c-literal-datum?)

  (begin


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

(define (c-mode-var suffix)
  ;; Emacs's `(symbol-value (c-mode-symbol SUFFIX))'. Its language
  ;; variables are buffer-local, and so are ours: the value is the
  ;; buffer-local slot of the current buffer (a named departure - there
  ;; is no symbol value cell here).
  (buffer-local-value (current-buffer) (c-mode-symbol suffix) #f))

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
  ;; CHARS ... If INVERTED is non-nil, a caret is prepended."
  (let ((inverted (and (pair? rest) (car rest))))
    (let loop ((cs (sort (map (lambda (c) (if (char? c) c (integer->char c)))
                              chars)
                         char<?))
               (str (if inverted "^" "")))
      (cond ((null? cs) str)
            ((memv (car cs) (list #\\ #\^ #\-))
             (loop (cdr cs)
                   (string-append str "\\" (string (car cs)))))
            (else (loop (cdr cs) (string-append str (string (car cs)))))))))

(define (%delete-nil list)
  ;; Emacs's `(remq nil LIST)' for our two nils.
  (let loop ((l list) (acc '()))
    (cond ((null? l) (reverse acc))
          ((or (not (car l)) (null? (car l))) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

(define (c-make-keywords-re adorn list . rest)
  ;; "Make a regexp that matches any string in LIST. Duplicates and nil
  ;; elements in the list are removed." The MODE argument selects the
  ;; syntax table used to tell a symbol from a non-symbol; **named
  ;; departure**: the mode's `c-<mode>-syntax-table' does not exist
  ;; here yet, so the current (or standard) syntax table classifies the
  ;; strings, which agrees with c-mode's for ordinary keyword text.
  (let ((liszt (%delete-nil list))
        (symbols '())
        (non-symbols '()))
    (for-each (lambda (elt)
                (if (string-match "\\`\\(\\sw\\|\\s_\\)*\\'" elt)
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

;;----------------------------------------------------------------------
;; The registration the macros call, and their helpers
;;----------------------------------------------------------------------
(define (c-lang-defconst-make-source-thunk val)
  ;; A thunk that evaluates VAL - source data - in the module that is
  ;; current *now* (the defining module), where every top-level
  ;; definition is in place by the time a value is requested.
  (let ((module (current-module)))
    (lambda () (eval val module))))

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
  ;; data, evaluated in the module doing the evaluation.
  (eval form (current-module)))

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
             (guard (e (#t #'(c-get-lang-constant 'n* #f 'm*)))
               (let ((v (c-get-lang-constant nm #f mode)))
                 (if (%c-literal-datum? v)
                     (with-syntax ((v* (datum->syntax (syntax name) v)))
                       #'(quote v*))
                     #'(c-get-lang-constant 'n* #f 'm*)))))))))))

;;----------------------------------------------------------------------
;; `c-lang-defconst-eval-immediately' (`cc-defs.el:2531')
;;----------------------------------------------------------------------
(define-syntax c-lang-defconst-eval-immediately
  ;; "Can be used inside a VAL in `c-lang-defconst' to evaluate FORM
  ;; immediately." Emacs evals at macro-expansion time; here a VAL is
  ;; source evaluated on demand, so this evals at that moment in the
  ;; defining module.
  (lambda (stx)
    (syntax-case stx ()
      ((_ form)
       (with-syntax ((f* (datum->syntax (syntax form)
                                        (syntax->datum (syntax form)))))
         #'(c-lang-defconst-eval-now 'f*))))))

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
                  ;; Emacs messages "Eval error in the
                  ;; `c-lang-defconst' for..." and re-signals; this
                  ;; raises a summary condition instead (a named
                  ;; departure: the tree has one error condition).
                  (let ((v (guard (e (#t
                                      (error "Eval error in the `c-lang-defconst' for `~a' in ~a"
                                             name mode)))
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
)
)
