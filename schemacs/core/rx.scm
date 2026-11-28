(define-library (schemacs core rx)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/rx.el' - the whole
  ;; file, function for function, in its own order, with the two
  ;; exceptions named below.  It is the primitive `groovy-mode' stands
  ;; on (40 `(rx ...)' forms), and `rx' is where a great many of Emacs's
  ;; programming modes put their regexps.
  ;;
  ;; The translation is Emacs's own: every translator answers
  ;; `(REGEXP-LIST . PRECEDENCE)' with the precedence lattice
  ;; t > seq > {lseq, rseq} > nil that `rx--sequence' brackets by, and
  ;; the regexp strings themselves come out character for character as
  ;; Emacs 31.1 produces them (verified by a differential over the
  ;; forms `groovy-mode.el' uses plus rx's own examples).
  ;;
  ;; **Departures, each named where it bites:**
  ;;
  ;;   * `rx-let' is NOT carried.  Emacs expands it with
  ;;     `macroexpand-all' over a `macroexpand-all-environment' entry
  ;;     that carries the local definitions into nested `rx' expansions;
  ;;     Guile has no `macroexpand-all', so a local definition could not
  ;;     reach an `rx' inside BODY.  `rx-let-eval' IS carried - its
  ;;     definitions are read by `rx-to-string' at run time, which needs
  ;;     no expander.  `rx-define' IS carried, with its compile-time
  ;;     half emulated in the macro transformer (see below).
  ;;
  ;;   * `rx-define''s `eval-and-compile' half: Guile's compiler does not
  ;;     run top-level side effects, so a `(rx user-name)' later in the
  ;;     SAME file would be expanded before the `put' ran.  The macro
  ;;     transformer performs the `put' itself at expansion time, which
  ;;     is what makes a same-file use work; the emitted `(put ...)' then
  ;;     runs again - idempotently - when the library loads.
  ;;
  ;;   * **Delayed evaluation is hygienic here.**  For `(literal EXPR)'
  ;;     and `(regexp EXPR)' inside `(rx ...)', Emacs builds an
  ;;     expression with the caller's forms and a `concat'; the port
  ;;     replaces EXPR with a marker during translation and splices the
  ;;     caller's syntax back into the result, and the introduced names
  ;;     (`string-append', `regexp-quote') are emitted in THIS library's
  ;;     lexical context.  A caller therefore never imports them.
  ;;
  ;;   * **The `eval' form in the macro path** is evaluated in this
  ;;     library's module (`(current-module)' of the transformer), where
  ;;     Emacs evaluates it in the macro-expansion environment.  A form
  ;;     that refers to a caller's lexical variable does not work; one
  ;;     that builds its data itself does.  Nothing in the tree uses it.
  ;;
  ;;   * Strings are always multibyte here, so `rx--string-to-intervals'
  ;;     has no `unibyte-char-to-multibyte' arm - the identity Emacs uses
  ;;     for a multibyte string is the only one.
  ;;
  ;;   * **A regexp string here cannot hold the raw-byte characters**
  ;;     #x3FFF00..#x3FFFFF, because Guile's `integer->char' stops at
  ;;     #x10FFFF.  Emacs's `rx' can emit them - a range that spans
  ;;     #x3FFF7F takes `rx--generate-alt''s complemented-range rule,
  ;;     and a user may write `(any "\x3fff00-\x3fffff")' - and such a
  ;;     pattern raises here instead of matching.  Nothing in the tree
  ;;     asks for one: the `(not (any ...))' forms Groovy's modes use
  ;;     all take the `[^...]' branch, which carries no raw bytes.
  ;;
  ;;   * `make-obsolete-variable' on `rx-constituents' is not carried
  ;;     (this tree has no variable obsoletion), nor is the
  ;;     `rx-submatch-n' obsolete function alias (it exists for an old
  ;;     flycheck; `byte-run.scm' has the machinery, but the alias would
  ;;     pull `command.scm' into this library for a name nothing here
  ;;     calls).
  ;;
  ;;   * The obsolete `any' symbol warning is a byte-compiler warning;
  ;;     `any' translates silently to `nonl', as Emacs's evaluator does.
  ;;
  ;;   * `rx--builtin-forms' and `rx--builtin-symbols' are defined
  ;;     BEFORE `rx--normalize-char-pattern' rather than after it (Emacs
  ;;     forward-declares them with `defvar' inside the function).  Same
  ;;     values, same use; the move only avoids a compiler warning.
  ;;
  ;;   * The pcase pattern `(pcase-defmacro rx ...)' is registered
  ;;     through the `pcase-macroexpander' property (a definition named
  ;;     `rx' would collide with the `rx' macro in a Lisp-1).  Where
  ;;     Emacs's expansion names `string-match' and `match-string',
  ;;     this one names `rx--pcase-pred'/`rx--pcase-match-1'/
  ;;     `rx--pcase-match-n', because a pcase pattern is data and a
  ;;     name in it resolves at the use site: those two live in
  ;;     `(schemacs search)', while the rx names come with the library
  ;;     that registers the pattern.  **The use site must IMPORT
  ;;     `(schemacs core rx)'** - Emacs needs only the load, its
  ;;     obarray being global.  A closure carried in the pattern data
  ;;     would avoid the import but cannot be compiled: Guile refuses a
  ;;     procedure as a source constant at every optimization level, so
  ;;     `(pcase ... (rx ...))' in a compiled library would crash the
  ;;     compiler.  The names left as symbols (`string?', `and', `app',
  ;;     `pred', `quasiquote') are `(scheme base)'s.
  ;;
  ;;   * The expression `rx--to-expr' builds says `string-append'
  ;;     where Emacs's says `concat' - `string-append' is `(scheme
  ;;     base)'s and takes the strings the translator produces, so the
  ;;     expansion is portable to any library.  Anything that reads the
  ;;     macro's expansion rather than running it sees that difference.
  (import
    (scheme base)
    (only (guile) cdddr current-module datum->syntax eval format gensym
          sort quasisyntax syntax syntax->datum
          syntax-case unsyntax unsyntax-splicing with-syntax)
    (only (schemacs symbol-props) get put)
    (only (schemacs search) match-string regexp-quote string-match
          string-match-p)
    (only (schemacs fns) take mapcan nth nreverse nconc nthcdr rassq)
    (only (schemacs subr) regexp-unmatchable all any remq car-safe
          number-sequence)
    (only (schemacs character) char-to-string)
    (only (schemacs chartab) max-char)
    (only (schemacs data) natnump number-to-string)
    (only (schemacs core regexp-opt) regexp-opt))

  (export rx rx-to-string rx-let-eval rx-define
          rx--to-expr rx--translate rx--char-classes
          ;; The pcase pattern's match procedures: the expansion names
          ;; them, so an `(rx ...)' pattern resolves them in the module
          ;; it appears in.
          rx--pcase-pred rx--pcase-match-1 rx--pcase-match-n)

  (begin

    ;;------------------------------------------------------------------
    ;; Small helpers.  Emacs's characters ARE integers; here the interval
    ;; machinery works in code points, which is the representation the
    ;; C's `aref' gives (`(aref "a" 0)' is 97).
    ;;------------------------------------------------------------------

    (define (%rx-char-code c)
      (if (char? c) (char->integer c) c))

    (define (%rx-characterp x)
      ;; `characterp' (`character.c'): an exact integer in
      ;; [0, MAX_CHAR].  Raw byte characters live in the same range.
      (and (exact-integer? x) (<= 0 x max-char)))

    (define (%rx-string . parts)
      ;; Emacs's `(string C1 C2 ...)' over characters or code points.
      (list->string (map (lambda (p) (if (char? p) p (integer->char p)))
                         parts)))

    (define (%rx-concat pieces)
      ;; `(apply #'concat PIECES)' with concat's nil-in, ""-out reading.
      ;; `(string-append)' with no arguments is an error in this Guile,
      ;; which is why the empty case is spelled out.
      (cond ((null? pieces) "")
            ((null? (cdr pieces)) (car pieces))
            (else (apply string-append pieces))))

    (define (%rx-find pred lst)
      (let loop ((l lst))
        (cond ((null? l) #f)
              ((pred (car l)) (car l))
              (else (loop (cdr l))))))

    ;; Syntax walkers.  Guile does not export `syntax-car' and friends
    ;; (nor `syntax->list'); `syntax-case' destructuring gives them.
    (define (%rx-syn-pair? s)
      (syntax-case s () ((_ . _) #t) (_ #f)))
    (define (%rx-syn-car s)
      (syntax-case s () ((a . _) (syntax a)) (_ #f)))
    (define (%rx-syn-cdr s)
      (syntax-case s () ((_ . d) (syntax d)) (_ #f)))
    (define (%rx-syn-list s)
      ;; A syntax object that is a proper list, as a list of syntax
      ;; objects.
      (let loop ((s s) (out '()))
        (if (%rx-syn-pair? s)
            (loop (%rx-syn-cdr s) (cons (%rx-syn-car s) out))
            (reverse out))))

    (define (%rx-rassq key alist)
      ;; Emacs's `(rassq KEY ALIST)' over the intervals, whose keys are
      ;; code points: the first pair whose cdr is KEY.
      (%rx-find (lambda (pair) (= (cdr pair) key)) alist))

    ;;------------------------------------------------------------------
    ;; The character-class table.  `digit' is 0-9, `space' has whitespace
    ;; syntax, `word' has word syntax, and so on - the classes of
    ;; `rx--char-classes' (`rx.el:95'), in Emacs's order.
    ;;------------------------------------------------------------------

    (define rx--char-classes
      '((digit         . digit)
        (numeric       . digit)
        (num           . digit)
        (control       . cntrl)
        (cntrl         . cntrl)
        (hex-digit     . xdigit)
        (hex           . xdigit)
        (xdigit        . xdigit)
        (blank         . blank)
        (graphic       . graph)
        (graph         . graph)
        (printing      . print)
        (print         . print)
        (alphanumeric  . alnum)
        (alnum         . alnum)
        (letter        . alpha)
        (alphabetic    . alpha)
        (alpha         . alpha)
        (ascii         . ascii)
        (nonascii      . nonascii)
        (lower         . lower)
        (lower-case    . lower)
        (punctuation   . punct)
        (punct         . punct)
        (space         . space)
        (whitespace    . space)
        (white         . space)
        (upper         . upper)
        (upper-case    . upper)
        (word          . word)
        (wordchar      . word)
        (unibyte       . unibyte)
        (multibyte     . multibyte)))

    ;;------------------------------------------------------------------
    ;; The old-style rx extensions, and the definition machinery.
    ;;------------------------------------------------------------------

    (define rx-constituents '()
      ;; "Alist of old-style rx extensions, for compatibility."  Each
      ;; element is (SYMBOL . DEF); DEF is a symbol (alias), a string
      ;; (the regexp), or `(FUN MIN-ARGS MAX-ARGS PRED)'.  Empty here as
      ;; it is in an Emacs that defines none.
      )

    (define *rx--local-definitions* (make-parameter '())
      ;; "Alist of dynamic local rx definitions.  Each entry is:
      ;;  (NAME DEF)      -- NAME is an rx symbol defined as the rx form DEF.
      ;;  (NAME ARGS DEF) -- NAME is an rx form with arglist ARGS..."
      ;; Emacs `defvar's it and `rx-let-eval' `let'-binds it, so it is a
      ;; parameter.
      )

    (define (rx--lookup-def name)
      ;; "Current definition of NAME: (DEF) or (ARGS DEF), or nil if none."
      (let ((entry (assq name (*rx--local-definitions*))))
        (or (and entry (cdr entry))
            (get name 'rx-definition))))

    (define (rx--expand-def-form form)
      ;; "List FORM expanded (once) if a user-defined construct;
      ;; otherwise nil."
      (let ((op (car form)))
        (and (symbol? op)
             (let ((def (rx--lookup-def op)))
               (and def
                    (if (pair? (cdr def))
                        (rx--expand-template op (cdr form) (car def) (cadr def))
                        (error "Not an `rx' form definition: ~a" op)))))))

    (define (rx--expand-def-symbol symbol)
      ;; "SYM expanded (once) if a user-defined name; otherwise nil."
      (let ((def (rx--lookup-def symbol)))
        (and def
             (if (pair? (cdr def))
                 (error "Not an `rx' symbol definition: ~a" symbol)
                 (car def)))))

    (define (rx--translate-symbol sym)
      ;; "Translate an rx symbol.  Return (REGEXP . PRECEDENCE)."
      (cond
        ((memv sym '(nonl not-newline)) (cons (list ".") 't))
        ((memv sym '(anychar anything)) (cons (list "[^z-a]") 't))
        ((eq? sym 'unmatchable) (rx--empty))
        ((memv sym '(bol line-start)) (cons (list "^") 'lseq))
        ((memv sym '(eol line-end)) (cons (list "$") 'rseq))
        ((memv sym '(bos string-start bot buffer-start)) (cons (list "\\`") 't))
        ((memv sym '(eos string-end eot buffer-end)) (cons (list "\\'") 't))
        ((eq? sym 'point) (cons (list "\\=") 't))
        ((memv sym '(bow word-start)) (cons (list "\\<") 't))
        ((memv sym '(eow word-end)) (cons (list "\\>") 't))
        ((eq? sym 'word-boundary) (cons (list "\\b") 't))
        ((eq? sym 'not-word-boundary) (cons (list "\\B") 't))
        ((eq? sym 'symbol-start) (cons (list "\\_<") 't))
        ((eq? sym 'symbol-end) (cons (list "\\_>") 't))
        ((eq? sym 'not-wordchar) (rx--translate '(not wordchar)))
        ((eq? sym 'any)
         ;; Emacs warns when compiling; the translation is `nonl'.
         (rx--translate-symbol 'nonl))
        (else
         (cond
           ((let ((entry (assq sym rx--char-classes)))
              (and entry
                   (cons (list (string-append "[[:"
                                              (symbol->string (cdr entry))
                                              ":]]"))
                         't))))

           ((let ((expanded (rx--expand-def-symbol sym)))
              (and expanded (rx--translate expanded))))

           ;; For compatibility with old rx.
           ((let ((entry (assq sym rx-constituents)))
              (and entry (rx--translate-compat-symbol-entry entry))))

           (else (error "Unknown rx symbol `~a'" sym))))))

    (define (rx--enclose left-str rexp right-str)
      ;; "Bracket REXP by LEFT-STR and RIGHT-STR."
      (append (list left-str) rexp (list right-str)))

    (define (rx--bracket rexp)
      (rx--enclose "\\(?:" rexp "\\)"))

    (define (rx--sequence left right)
      ;; "Return the sequence (concatenation) of two translated items,
      ;; each on the form (REGEXP . PRECEDENCE), returning
      ;; (REGEXP . PRECEDENCE)."
      ;;
      ;; Concatenation rules:
      ;;  seq  ++ seq  -> seq
      ;;  lseq ++ seq  -> lseq
      ;;  seq  ++ rseq -> rseq
      ;;  lseq ++ rseq -> nil
      (cond ((null? (car left)) right)
            ((null? (car right)) left)
            (else
             (let ((l (if (memv (cdr left) (list #f 'rseq))
                          (cons (rx--bracket (car left)) 't)
                          left))
                   (r (if (memv (cdr right) (list #f 'lseq))
                          (cons (rx--bracket (car right)) 't)
                          right)))
               (cons (append (car l) (car r))
                     (if (eq? (cdr l) 'lseq)
                         (if (eq? (cdr r) 'rseq)
                             #f                       ; lseq ++ rseq
                             'lseq)                   ; lseq ++ seq
                         (if (eq? (cdr r) 'rseq)
                             'rseq                    ; seq ++ rseq
                             'seq)))))))              ; seq ++ seq

    (define (rx--translate-seq body)
      ;; "Translate a sequence of zero or more rx items.
      ;; Return (REGEXP . PRECEDENCE)."
      (if (pair? body)
          (let ((items (map rx--translate body)))
            (rx--foldl rx--sequence (car items) (cdr items)))
          (cons '() 'seq)))

    (define (rx--empty)
      ;; "Regexp that never matches anything."
      (cons (list regexp-unmatchable) 'seq))

    (define (rx--foldl f x l)
      ;; "(F (F (F X L0) L1) L2) ...  Left-fold the list L, starting
      ;; with X, by the binary function F."
      (let loop ((x x) (l l))
        (if (null? l)
            x
            (loop (f x (car l)) (cdr l)))))

    (define rx--builtin-forms
      '(seq sequence : and or #{|}# any in char not-char not intersection
        repeat = >= **
        zero-or-more #{0+}# *
        one-or-more #{1+}# +
        zero-or-one opt optional ?
        *? +? ??
        minimal-match maximal-match
        group submatch group-n submatch-n backref
        syntax not-syntax category
        literal eval regexp regex)
      ;; "List of built-in rx function-like symbols."  (`\?' and `\??'
      ;; in Emacs's list are the symbols `?' and `??', which is how this
      ;; tree's reader spells them.)
      )

    (define rx--builtin-symbols
      (append '(nonl not-newline any anychar anything unmatchable
                bol eol line-start line-end
                bos eos string-start string-end
                bow eow word-start word-end
                symbol-start symbol-end
                point word-boundary not-word-boundary not-wordchar)
              (map car rx--char-classes))
      ;; "List of built-in rx variable-like symbols."
      )

    (define rx--builtin-names
      (append rx--builtin-forms rx--builtin-symbols)
      ;; "List of built-in rx names.  These cannot be redefined by the
      ;; user."
      )

    ;;------------------------------------------------------------------
    ;; Character alternatives.
    ;;------------------------------------------------------------------

    (define (rx--normalize-char-pattern form)
      ;; "Normalize FORM as a pattern matching a single-character. ..."
      ;;
      ;; A `rx--char-alt' form is shaped (rx--char-alt INTERVALS . CLASSES)
      ;; where INTERVALS is a sorted list of disjoint nonadjacent
      ;; intervals, each a cons of characters, and CLASSES an unordered
      ;; list of unique name-normalized character classes.
      (cond
        ((pair? form)
         (let ((op (car form))
               (body (cdr form)))
           (cond ((memv op (list 'or '#{|}#))
                  ;; Normalize the constructor to `or' and the args.
                  (cons 'or (map rx--normalize-char-pattern body)))
                 ;; Convert `any' forms and char classes now so that we
                 ;; don't need to do it later on.
                 ((memv op (list 'any 'in 'char))
                  (cons 'rx--char-alt (rx--parse-any body)))
                 ((memv op (list 'not 'intersection))
                  (cons op (map rx--normalize-char-pattern body)))
                 ((eq? op 'eval)
                  (rx--normalize-char-pattern (rx--expand-eval body)))
                 ((memv op rx--builtin-forms) form)
                 ((let ((expanded (rx--expand-def-form form)))
                    (and expanded
                         (rx--normalize-char-pattern expanded))))
                 (else form))))
        ((symbol? form)
         (cond ((let ((class (assq form rx--char-classes)))
                  (and class
                       (cons 'rx--char-alt
                             (cons '() (list (cdr class)))))))
               ((memv form rx--builtin-symbols) form)
               ((let ((expanded (rx--expand-def-symbol form)))
                  (and expanded
                       (rx--normalize-char-pattern expanded))))
               (else form)))
        ((%rx-characterp form)
         (char-to-string form))
        (else form)))

    (define (rx--char-alt-union a b)
      ;; "Union of the (INTERVALS . CLASSES) pairs A and B."
      (let* ((a-cl (cdr a))
             (b-cl (cdr b))
             (classes (if (and (pair? a-cl) (pair? b-cl))
                          (let ((acc a-cl))
                            (for-each (lambda (c)
                                        (unless (memq c a-cl)
                                          (set! acc (cons c acc))))
                                      b-cl)
                            acc)
                          (if (null? a-cl) b-cl a-cl))))
        (cons (rx--interval-set-union (car a) (car b)) classes)))

    (define (rx--intersection-intervals forms)
      ;; "Intersection of the normalized FORMS, as an interval set."
      (rx--foldl rx--interval-set-intersection
                 (list (cons 0 #x3fffff))
                 (map (lambda (x)
                        (let ((char (rx--reduce-to-char-alt x)))
                          (if (and char (null? (cdr char)))
                              (car char)
                              (error "Cannot be used in rx intersection: ~s"
                                     (rx--human-readable x)))))
                      forms)))

    (define (rx--reduce-to-char-alt form)
      ;; "Transform FORM into (INTERVALS . CLASSES) or nil if not
      ;; possible.  Process `or', `intersection' and `not'.
      ;; FORM must be normalized (from `rx--normalize-char-pattern')."
      (cond
        ((string? form)
         (and (= (string-length form) 1)
              (let ((c (char->integer (string-ref form 0))))
                (list (list (cons c c))))))
        ((pair? form)
         (let ((head (car form)))
           (cond
             ((eq? head 'rx--char-alt) (cdr form))
             ((eq? head 'not)
              (unless (= (length form) 2)
                (error "rx `not' form takes exactly one argument"))
              (let ((arg (rx--reduce-to-char-alt (cadr form))))
                ;; Only interval sets without classes are closed under
                ;; complement.
                (and arg (null? (cdr arg))
                     (list (rx--interval-set-complement (car arg))))))
             ((eq? head 'or)
              (let loop ((args (cdr form)) (acc (list '())))
                (cond ((null? args) acc)
                      (else
                       (let ((char (rx--reduce-to-char-alt (car args))))
                         (if char
                             (loop (cdr args) (rx--char-alt-union acc char))
                             #f))))))
             ;; The C's `cond' answers nil here; Scheme's, with no
             ;; matching clause, answers the *unspecified* value - which
             ;; is TRUE and made every non-char form look like a char
             ;; alt from `rx--optimize-or-args'.  This is the tree's
             ;; `cond'-without-else trap, and this one is load-bearing.
             (else #f))))
        ((memv form '(nonl not-newline any))
         (list (list (cons 0 9) (cons 11 #x3fffff))))
        ((memv form '(anychar anything))
         (list (list (cons 0 #x3fffff))))
        ;; FIXME: A better handling of `unmatchable' would be: ...
        ((eq? form 'unmatchable)
         (list '()))
        (else #f)))

    (define (rx--optimize-or-args args)
      ;; "Optimize `or' arguments.  Return a new rx form.  Each element
      ;; of ARGS should have been normalized using
      ;; `rx--normalize-char-pattern'."
      (if (null? args)
          ;; No arguments.
          (cons 'rx--char-alt '())          ; FIXME: not `unmatchable'?
          ;; Join consecutive single-char branches into a char alt
          ;; where possible.  Ideally we should collect all single-char
          ;; branches but that might alter matching order in some cases.
          (let loop ((args args) (branches '()) (prev #f))
            (cond
              ((null? args)
               (let ((branches (if prev
                                   (cons (cons 'rx--char-alt prev) branches)
                                   branches)))
                 (if (pair? (cdr branches))
                     (cons 'or (reverse branches))
                     (car branches))))
              (else
               (let* ((item (car args))
                      (item-char (rx--reduce-to-char-alt item)))
                 (if item-char
                     (loop (cdr args)
                           branches
                           (if prev
                               (rx--char-alt-union prev item-char)
                               item-char))
                     (loop (cdr args)
                           (if prev
                               (cons item (cons (cons 'rx--char-alt prev) branches))
                               (cons item branches))
                           #f))))))))

    (define (rx--all-string-branches-p forms)
      ;; "Whether FORMS are all strings or `or' forms with the same
      ;; property."
      (all (lambda (x)
             (or (string? x)
                 (and (eq? (car-safe x) 'or)
                      (rx--all-string-branches-p (cdr x)))))
           forms))

    (define (rx--collect-or-strings forms)
      ;; "All strings from FORMS, which are strings or `or' forms."
      (mapcan (lambda (form)
                (if (string? form)
                    (list form)
                    ;; must be an `or' form
                    (rx--collect-or-strings (cdr form))))
              forms))

    (define (rx--translate-or body)
      ;; "Translate an or-pattern of zero or more rx items.
      ;; Return (REGEXP . PRECEDENCE)."
      (cond
        ((null? body)                   ; No items: never-matching regexp.
         (rx--empty))
        ((null? (cdr body))             ; Single item.
         (rx--translate (car body)))
        (else
         (let ((args (map rx--normalize-char-pattern body)))
           (if (rx--all-string-branches-p args)
               ;; All branches are strings: use `regexp-opt'.
               (cons (list (regexp-opt (rx--collect-or-strings args) #f))
                     't)
               (let ((form (rx--optimize-or-args args)))
                 (if (eq? (car-safe form) 'or)
                     (let ((branches (cdr form)))
                       (cons (append (car (rx--translate (car branches)))
                                     (mapcan (lambda (item)
                                               (cons "\\|" (car (rx--translate item))))
                                             (cdr branches)))
                             #f))
                     (rx--translate form))))))))

    (define (rx--string-to-intervals str)
      ;; "Decode STR as intervals: A-Z becomes (?A . ?Z), and the single
      ;; character X becomes (?X . ?X).  Return the intervals in a
      ;; list."
      ;;
      ;; Emacs decodes a unibyte string through
      ;; `unibyte-char-to-multibyte'; every string here is multibyte, so
      ;; that arm is the identity (named in the header).
      (let ((len (string-length str)))
        (let loop ((i 0) (intervals '()))
          (if (>= i len)
              intervals
              (let ((c (char->integer (string-ref str i))))
                (cond ((and (< i (- len 2))
                            (= (char->integer (string-ref str (+ i 1))) 45)) ; ?-
                       ;; Range.
                       (let ((start c)
                             (end (char->integer (string-ref str (+ i 2)))))
                         (cond ((and (<= start #x7f) (>= end #x3fff80))
                                ;; Ranges between ASCII and raw bytes are
                                ;; split to avoid having them absorb
                                ;; Unicode characters caught in-between.
                                (loop (+ i 3)
                                      (cons (cons #x3fff80 end)
                                            (cons (cons start #x7f) intervals))))
                               ((<= start end)
                                (loop (+ i 3) (cons (cons start end) intervals)))
                               (else
                                (error "Invalid rx `any' range: ~a"
                                       (substring str i (+ i 3)))))))
                      (else
                       ;; Single character.
                       (loop (+ i 1) (cons (cons c c) intervals)))))))))

    (define (rx--condense-intervals intervals)
      ;; "Merge adjacent and overlapping intervals by mutation,
      ;; preserving the order.  INTERVALS is a list of (START . END)
      ;; with START <= END, sorted by START."
      (let loop ((tail intervals))
        (let ((d (and (pair? tail) (cdr tail))))
          (cond ((null? d) intervals)
                ((>= (cdr (car tail)) (- (car (car d)) 1))
                 (set-cdr! (car tail) (max (cdr (car tail)) (cdr (car d))))
                 (set-cdr! tail (cdr d))
                 (loop tail))
                (else
                 (loop d))))))

    (define (rx--parse-any body)
      ;; "Parse arguments of an (any ...) construct.  Return
      ;; (INTERVALS . CLASSES), where INTERVALS is a sorted list of
      ;; disjoint nonadjacent intervals (each a cons of chars), and
      ;; CLASSES a list of named character classes in the order they
      ;; occur in BODY."
      (let ((classes '())
            (strings '())
            (conses '()))
        ;; Collect strings, conses and characters, and classes in
        ;; separate bins.
        (for-each
         (lambda (arg)
           (cond ((string? arg)
                  (set! strings (cons arg strings)))
                 ((and (pair? arg)
                       (%rx-characterp (car arg))
                       (%rx-characterp (cdr arg))
                       (<= (car arg) (cdr arg)))
                  ;; Copy the cons, in case we need to modify it.
                  (set! conses (cons (cons (car arg) (cdr arg)) conses)))
                 ((%rx-characterp arg)
                  (set! conses (cons (cons arg arg) conses)))
                 ((and (symbol? arg)
                       (let ((entry (assq arg rx--char-classes)))
                         (and entry
                              (let ((class (cdr entry)))
                                (or (memq class classes)
                                    (begin (set! classes (cons class classes)) #t)))))))
                 (else (error "Invalid rx `any' argument: ~s" arg))))
         body)
        (cons (rx--condense-intervals
               (sort (append conses
                             (mapcan rx--string-to-intervals strings))
                     (lambda (a b) (< (car a) (car b)))))
              (reverse classes))))

    (define (rx--generate-alt negated intervals classes)
      ;; "Generate a character alternative.  Return (REGEXP .
      ;; PRECEDENCE).  If NEGATED is non-nil, negate the result;
      ;; INTERVALS is a sorted list of disjoint intervals and CLASSES a
      ;; list of named character classes."
      ;;
      ;; No, this is not pretty code.  You try doing it in a way that is
      ;; both elegant and efficient.  Or just one of the two.  I dare
      ;; you.  (Emacs's comment, kept.)

      ;; Detect whether the interval set is better described in
      ;; complemented form.  This is not just a matter of aesthetics:
      ;; any range that straddles the char-raw boundary will be
      ;; mutilated by the regexp engine.
      (when (and (null? classes)
                 (any (lambda (iv) (<= (car iv) #x3fff7f (cdr iv)))
                      intervals))
        (set! negated (not negated))
        (set! intervals (rx--interval-set-complement intervals)))
      (cond
        ;; Single character.
        ((and (pair? intervals) (= (caar intervals) (cdar intervals))
              (null? (cdr intervals))
              (null? classes))
         (let ((ch (caar intervals)))
           (if negated
               (if (= ch 10)
                   ;; Single negated newline.
                   (rx--translate-symbol 'nonl)
                   ;; Single negated character (other than newline).
                   (cons (list (%rx-string 91 94 ch 93)) 't))
               ;; Single literal character.
               (cons (list (regexp-quote (char-to-string ch))) 't))))

        ;; Empty set (or any char).
        ((and (null? intervals) (null? classes))
         (if negated
             (rx--translate-symbol 'anychar)
             (rx--empty)))

        ;; More than one character, or at least one class.
        (else
         (let ((dash #f) (caret #f))
           ;; Move ] and range ]-x to the start.
           (let ((rbrac-l (assv 93 intervals)))
             (when rbrac-l
               (set! intervals (cons rbrac-l (remq rbrac-l intervals)))))

           ;; Split x-] and move the lone ] to the start.
           (let ((rbrac-r (%rx-rassq 93 intervals)))
             (when (and rbrac-r (not (= (car rbrac-r) 93)))
               (set-cdr! rbrac-r 92)
               (set! intervals (cons (cons 93 93) intervals))))

           ;; Split ,-- (which would end up as ,- otherwise).
           (let ((dash-r (%rx-rassq 45 intervals)))
             (when (and dash-r (= (car dash-r) 44))
               (set-cdr! dash-r 44)
               (set! dash "-")))

           ;; Remove - (lone or at start of interval).
           (let ((dash-l (assv 45 intervals)))
             (when dash-l
               (if (= (cdr dash-l) 45)
                   (set! intervals (remq dash-l intervals)) ; lone -
                   (set-car! dash-l 46))                 ; Reduce --x to .-x
               (set! dash "-")))

           ;; Deal with leading ^ and range ^-x in non-negated set.
           (when (and (pair? intervals) (= (caar intervals) 94) (not negated))
             (if (= (cdar intervals) 94)
                 ;; single leading ^
                 (if (or (pair? (cdr intervals)) (pair? classes))
                     ;; something else to put before the ^
                     (begin
                       (set! intervals (cdr intervals))  ; remove lone ^
                       (set! caret "^"))                 ; put ^ (almost) last
                     ;; nothing else but a lone -
                     (begin
                       (set! intervals (cons (cons 45 45) intervals)) ; move - first
                       (set! dash #f)))
                 ;; split ^-x to _-x^
                 (set! intervals
                       (cons (cons 95 (cdar intervals))
                             (cons (cons 94 94) (cdr intervals))))))

           (cons
            (list
             (string-append
              "["
              (if negated "^" "")
              (%rx-concat
               (map (lambda (iv)
                      (let ((beg (car iv)) (end (cdr iv)))
                        (cond ((= beg end)
                               (char-to-string beg))
                              ((= (+ beg 1) end)
                               (%rx-string beg end))
                              ;; Ranges that go between normal chars and
                              ;; raw bytes must be split.
                              ((<= beg #x3fff7f end)
                               (%rx-string beg 45 #x3fff7f
                                           #x3fff80 45 end))
                              (else
                               (%rx-string beg 45 end)))))
                    intervals))
              (%rx-concat
               (map (lambda (cls) (format #f "[:~a:]" cls)) classes))
              (if caret caret "")               ; ^ or nothing
              (if dash dash "")                 ; - or nothing
              "]"))
            't)))))

    (define (rx--translate-char-alt negated body)
      ;; "Translate a (rx--char-alt ...) construct.  Return (REGEXP .
      ;; PRECEDENCE).  If NEGATED, negate the sense."
      (rx--generate-alt negated (car body) (cdr body)))

    (define (rx--translate-any negated body)
      ;; "Translate an (any ...) construct.  Return (REGEXP .
      ;; PRECEDENCE).  If NEGATED, negate the sense."
      (let ((parsed (rx--parse-any body)))
        (rx--generate-alt negated (car parsed) (cdr parsed))))

    (define (rx--translate-not negated body)
      ;; "Translate a (not ...) construct.  Return (REGEXP .
      ;; PRECEDENCE).  If NEGATED, negate the sense (thus making it
      ;; positive)."
      (unless (and (pair? body) (null? (cdr body)))
        (error "rx `not' form takes exactly one argument"))
      (let ((arg (rx--normalize-char-pattern (car body))))
        (cond
          ((and (pair? arg) (eq? (car arg) 'not))
           (rx--translate-not (not negated) (cdr arg)))
          ((and (pair? arg) (eq? (car arg) 'syntax))
           (rx--translate-syntax (not negated) (cdr arg)))
          ((and (pair? arg) (eq? (car arg) 'category))
           (rx--translate-category (not negated) (cdr arg)))
          ((eq? arg 'word-boundary)          ; legacy syntax
           (rx--translate-symbol (if negated 'word-boundary 'not-word-boundary)))
          (else
           (let ((char (rx--reduce-to-char-alt arg)))
             (if char
                 (rx--generate-alt (not negated) (car char) (cdr char))
                 (error "Illegal argument to rx `not': ~s"
                        (rx--human-readable arg))))))))

    (define (rx--interval-set-complement ivs)
      ;; "Complement of the interval set IVS."
      (let ((compl '())
            (c 0))
        (for-each (lambda (iv)
                    (when (< c (car iv))
                      (set! compl (cons (cons c (- (car iv) 1)) compl)))
                    (set! c (+ (cdr iv) 1)))
                  ivs)
        (when (< c max-char)
          (set! compl (cons (cons c max-char) compl)))
        (reverse compl)))

    (define (rx--interval-set-intersection ivs-a ivs-b)
      ;; "Intersection of the interval sets IVS-A and IVS-B."
      (let ((isect '()))
        (let loop ((ivs-a ivs-a) (ivs-b ivs-b))
          (cond
            ((or (null? ivs-a) (null? ivs-b)) (reverse isect))
            (else
             (let ((a (car ivs-a))
                   (b (car ivs-b)))
               (cond
                 ((< (cdr a) (car b)) (loop (cdr ivs-a) ivs-b))
                 ((> (car a) (cdr b)) (loop ivs-a (cdr ivs-b)))
                 (else
                  (set! isect (cons (cons (max (car a) (car b))
                                          (min (cdr a) (cdr b)))
                                    isect))
                  (cond ((< (cdr a) (cdr b))
                         (loop (cdr ivs-a) (cons (cons (+ (cdr a) 1) (cdr b)) ivs-b)))
                        ((> (cdr a) (cdr b))
                         (loop (cons (cons (+ (cdr b) 1) (cdr a)) ivs-a) (cdr ivs-b)))
                        (else
                         (loop (cdr ivs-a) (cdr ivs-b))))))))))))

    (define (rx--interval-set-union ivs-a ivs-b)
      ;; "Union of the interval sets IVS-A and IVS-B."
      (let ((union '()))
        (let loop ((ivs-a ivs-a) (ivs-b ivs-b))
          (cond
            ((or (null? ivs-a) (null? ivs-b))
             (append (reverse union) (if (null? ivs-a) ivs-b ivs-a)))
            (else
             (let ((a (car ivs-a))
                   (b (car ivs-b)))
               (cond
                 ((< (+ (cdr a) 1) (car b))       ; a before b, not adjacent
                  (set! union (cons a union))
                  (loop (cdr ivs-a) ivs-b))
                 ((< (+ (cdr b) 1) (car a))       ; b before a, not adjacent
                  (set! union (cons b union))
                  (loop ivs-a (cdr ivs-b)))
                 (else                            ; a and b adjacent or overlap
                  (if (< (cdr a) (cdr b))
                      (loop (cdr ivs-a) (cons (cons (min (car a) (car b)) (cdr b))
                                              (cdr ivs-b)))
                      (loop (cons (cons (min (car a) (car b)) (cdr a))
                                  (cdr ivs-a))
                            (cdr ivs-b)))))))))))

    (define (rx--human-readable form)
      ;; "Turn FORM into something that is more human-readable, for
      ;; error messages."
      (define (recurse op skip)
        (cons op (append (take skip (cdr form))
                         (map rx--human-readable (nthcdr skip (cdr form))))))
      (cond
        ;; strings are more readable than numbers for single chars
        ((%rx-characterp form) (char-to-string form))
        ;; resugar `rx--char-alt'
        ((and (pair? form) (eq? (car form) 'rx--char-alt)
              (pair? (cdr form))
              (let ((ivs (cadr form)) (classes (cddr form)))
                (and (pair? ivs) (pair? (car ivs))
                     (= (car (car ivs)) (cdr (car ivs)))
                     (null? (cdr ivs))
                     (null? classes))))
         (char-to-string (car (car (cadr form)))))
        ((and (pair? form) (eq? (car form) 'rx--char-alt)
              (pair? (cdr form))
              (null? (cadr form))
              (pair? (cddr form))
              (null? (cdddr form)))
         (car (cddr form)))
        ((and (pair? form) (eq? (car form) 'rx--char-alt) (pair? (cdr form)))
         (let ((ivs (cadr form))
               (classes (cddr form)))
           (let ((strings
                  (mapcan
                   (lambda (iv)
                     (let ((beg (car iv))
                           (end (cdr iv)))
                       (cond
                         ;; single char
                         ((= beg end) (list (%rx-string beg)))
                         ;; two chars
                         ((= end (+ beg 1)) (list (%rx-string beg) (%rx-string end)))
                         ;; first char is hyphen
                         ((= beg 45)
                          (cons "-"
                                (if (= end (+ 45 2))
                                    (list (%rx-string (+ 45 1) end))
                                    (list (%rx-string (+ 45 1) 45 end)))))
                         ;; other range
                         (else (list (%rx-string beg 45 end))))))
                   ivs)))
             (cons 'any (append strings classes)))))
        ;; avoid numbers as ops
        ((and (pair? form) (eq? (car form) '?)) (recurse '? 0))
        ((and (pair? form) (eq? (car form) '??)) (recurse '?? 0))
        ;; recurse on arguments
        ((and (pair? form) (eq? (car form) 'repeat) (pair? (cdr form)) (pair? (cddr form)))
         (recurse (car form) 1))
        ((and (pair? form) (memv (car form) (list '** 'repeat)))
         (recurse (car form) 2))
        ((and (pair? form)
              (memv (car form) (list '= '>= 'group-n 'submatch-n)))
         (recurse (car form) 1))
        ((and (pair? form)
              (memv (car form) (list 'backref 'syntax 'not-syntax 'category
                                     'eval 'regex 'regexp 'literal)))
         form)
        ((pair? form) (recurse (car form) 0))
        (else form)))

    (define (rx--translate-intersection negated body)
      ;; "Translate an (intersection ...) construct.  Return (REGEXP .
      ;; PRECEDENCE).  If NEGATED, negate the sense."
      (rx--generate-alt negated (rx--intersection-intervals
                                 (map rx--normalize-char-pattern body))
                        '()))

    (define (rx--atomic-regexp item)
      ;; "ITEM is (REGEXP . PRECEDENCE); return a regexp of precedence t."
      (if (eq? (cdr item) 't)
          (car item)
          (rx--bracket (car item))))

    (define (rx--translate-counted-repetition min-count max-count body)
      (let ((operand (rx--translate-seq body)))
        (if (pair? (car operand))
            (cons (append
                   (rx--atomic-regexp operand)
                   (list (string-append "\\{"
                                        (number-to-string min-count)
                                        (cond ((not max-count) ",")
                                              ((< min-count max-count)
                                               (string-append "," (number-to-string max-count)))
                                              (else ""))
                                        "\\}")))
                  't)
            operand)))

    (define (rx--check-repeat-arg name min-args body)
      (unless (>= (length body) min-args)
        (error "rx `~a' requires at least ~a argument~a"
               name min-args (if (= min-args 1) "" "s")))
      ;; There seems to be no reason to disallow zero counts.
      (unless (natnump (car body))
        (error "rx `~a' first argument must be nonnegative" name)))

    (define (rx--translate-bounded-repetition name body)
      (let ((min-count (car body))
            (max-count (cadr body))
            (items (cddr body)))
        (unless (and (natnump min-count)
                     (natnump max-count)
                     (<= min-count max-count))
          (error "rx `~a' range error" name))
        (rx--translate-counted-repetition min-count max-count items)))

    (define (rx--translate-repeat body)
      (rx--check-repeat-arg 'repeat 2 body)
      (if (= (length body) 2)
          (rx--translate-counted-repetition (car body) (car body) (cdr body))
          (rx--translate-bounded-repetition 'repeat body)))

    (define (rx--translate-** body)
      (rx--check-repeat-arg '** 2 body)
      (rx--translate-bounded-repetition '** body))

    (define (rx--translate->= body)
      (rx--check-repeat-arg '>= 1 body)
      (rx--translate-counted-repetition (car body) #f (cdr body)))

    (define (rx--translate-= body)
      (rx--check-repeat-arg '= 1 body)
      (rx--translate-counted-repetition (car body) (car body) (cdr body)))

    (define *rx--greedy* (make-parameter #t)
      ;; Emacs `defvar's `rx--greedy' and `rx--control-greedy' `let'binds
      ;; it - the tree's test for a parameter.
      )

    (define (rx--translate-rep op-string greedy body)
      ;; "Translate a repetition; OP-STRING is one of \"*\", \"+\" or
      ;; \"?\".  GREEDY is a boolean.  Return (REGEXP . PRECEDENCE)."
      (let ((operand (rx--translate-seq body)))
        (if (pair? (car operand))
            (cons (append (rx--atomic-regexp operand)
                          (list (string-append op-string (if greedy "" "?"))))
                  ;; The result has precedence seq to avoid
                  ;; (? (* "a")) -> "a*?"
                  'seq)
            operand)))

    (define (rx--control-greedy greedy body)
      ;; "Translate the sequence BODY with greediness GREEDY.
      ;; Return (REGEXP . PRECEDENCE)."
      (parameterize ((*rx--greedy* greedy))
        (rx--translate-seq body)))

    (define (rx--translate-group body)
      ;; "Translate the `group' form.  Return (REGEXP . PRECEDENCE)."
      (cons (rx--enclose "\\("
                         (car (rx--translate-seq body))
                         "\\)")
            't))

    (define (rx--translate-group-n body)
      ;; "Translate the `group-n' form.  Return (REGEXP . PRECEDENCE)."
      (unless (and (exact-integer? (car body)) (> (car body) 0))
        (error "rx `group-n' requires a positive number as first argument"))
      (cons (rx--enclose (string-append "\\(?" (number-to-string (car body)) ":")
                         (car (rx--translate-seq (cdr body)))
                         "\\)")
            't))

    (define (rx--translate-backref body)
      ;; "Translate the `backref' form.  Return (REGEXP . PRECEDENCE)."
      (unless (and (= (length body) 1)
                   (exact-integer? (car body))
                   (<= 1 (car body) 9))
        (error "rx `backref' requires an argument in the range 1..9"))
      (cons (list "\\" (number-to-string (car body))) 't))

    (define rx--syntax-codes
      '((whitespace         . 45)           ; SPC also accepted
        (punctuation        . 46)
        (word               . 119)          ; W also accepted
        (symbol             . 95)
        (open-parenthesis   . 40)
        (close-parenthesis  . 41)
        (expression-prefix  . 39)
        (string-quote       . 34)
        (paired-delimiter   . 36)
        (escape             . 92)
        (character-quote    . 47)
        (comment-start      . 60)
        (comment-end        . 62)
        (string-delimiter   . 124)
        (comment-delimiter  . 33)))

    (define (rx--translate-syntax negated body)
      ;; "Translate the `syntax' form.  Return (REGEXP . PRECEDENCE)."
      (unless (and (pair? body) (null? (cdr body)))
        (error "rx `syntax' form takes exactly one argument"))
      (let* ((sym (car body))
             (entry (assq sym rx--syntax-codes))
             (syntax (and entry (cdr entry))))
        (unless syntax
          (cond
            ;; Syntax character directly (sregex compatibility)
            ((and (%rx-characterp sym)
                  (%rx-rassq (%rx-char-code sym) rx--syntax-codes))
             (set! syntax (%rx-char-code sym)))
            ;; Syntax character as symbol (sregex compatibility)
            ((symbol? sym)
             (let ((name (symbol->string sym)))
               (when (= (string-length name) 1)
                 (let ((char (char->integer (string-ref name 0))))
                   (when (%rx-rassq char rx--syntax-codes)
                     (set! syntax char)))))))
          (unless syntax
            (error "Unknown rx syntax name `~a'" sym)))
        ;; Produce \w and \W instead of \sw and \Sw, for smaller size.
        (cons (list (if (= syntax 119)
                        (%rx-string 92 (if negated 87 119))
                        (%rx-string 92 (if negated 83 115) syntax)))
              't)))

    (define rx--categories
      '((space-for-indent           . 32)
        (base                       . 46)
        (consonant                  . 48)
        (base-vowel                 . 49)
        (upper-diacritical-mark     . 50)
        (lower-diacritical-mark     . 51)
        (tone-mark                  . 52)
        (symbol                     . 53)
        (digit                      . 54)
        (vowel-modifying-diacritical-mark . 55)
        (vowel-sign                 . 56)
        (semivowel-lower            . 57)
        (not-at-end-of-line         . 60)
        (not-at-beginning-of-line   . 62)
        (alpha-numeric-two-byte     . 65)
        (chinese-two-byte           . 67)
        (greek-two-byte             . 71)
        (japanese-hiragana-two-byte . 72)
        (indian-two-byte            . 73)
        (japanese-katakana-two-byte . 75)
        (strong-left-to-right       . 76)
        (korean-hangul-two-byte     . 78)
        (strong-right-to-left       . 82)
        (cyrillic-two-byte          . 89)
        (combining-diacritic        . 94)
        (ascii                      . 97)
        (arabic                     . 98)
        (chinese                    . 99)
        (ethiopic                   . 101)
        (greek                      . 103)
        (korean                     . 104)
        (indian                     . 105)
        (japanese                   . 106)
        (japanese-katakana          . 107)
        (latin                      . 108)
        (lao                        . 111)
        (tibetan                    . 113)
        (japanese-roman             . 114)
        (thai                       . 116)
        (vietnamese                 . 118)
        (hebrew                     . 119)
        (cyrillic                   . 121)
        (can-break                  . 124)))

    (define (rx--translate-category negated body)
      ;; "Translate the `category' form.  Return (REGEXP . PRECEDENCE)."
      (unless (and (pair? body) (null? (cdr body)))
        (error "rx `category' form takes exactly one argument"))
      (let* ((arg (car body))
             (category
              (cond ((symbol? arg)
                     (let ((cat (assq arg rx--categories)))
                       (unless cat
                         (error "Unknown rx category `~a'" arg))
                       (cdr cat)))
                    ((%rx-characterp arg) (%rx-char-code arg))
                    (else (error "Invalid rx `category' argument `~a'" arg)))))
        (cons (list (%rx-string 92 (if negated 67 99) category))
              't)))

    (define *rx--delayed-evaluation* (make-parameter #f)
      ;; "Whether to allow certain forms to be evaluated at runtime."
      ;; Emacs `defvar's it and `rx--to-expr' `let'binds it.
      )

    (define (rx--translate-literal body)
      ;; "Translate the `literal' form.  Return (REGEXP . PRECEDENCE)."
      (unless (and (pair? body) (null? (cdr body)))
        (error "rx `literal' form takes exactly one argument"))
      (let ((arg (car body)))
        (cond ((string? arg)
               (cons (list (regexp-quote arg))
                     (if (= (string-length arg) 1) 't 'seq)))
              ((*rx--delayed-evaluation*)
               (cons (list (list 'regexp-quote arg)) 'seq))
              (else (error "rx `literal' form with non-string argument")))))

    (define (rx--expand-eval body)
      ;; "Expand `eval' arguments.  Return a new rx form."
      (unless (and (pair? body) (null? (cdr body)))
        (error "rx `eval' form takes exactly one argument"))
      (eval (car body) (current-module)))

    (define (rx--translate-eval body)
      ;; "Translate the `eval' form.  Return (REGEXP . PRECEDENCE)."
      (rx--translate (rx--expand-eval body)))

    (define rx--regexp-atomic-regexp #f)

    (define rx-to-string #f)
    ;; `rx-to-string' is defined below, after the translators it calls;
    ;; this forward binding keeps the compiler from calling the earlier
    ;; use in `rx--translate-regexp' possibly-unbound.  (The tree's
    ;; `normal-auto-fill-function' takes the same shape.)

    (define (rx--translate-regexp body)
      ;; "Translate the `regexp' form.  Return (REGEXP . PRECEDENCE)."
      (unless (and (pair? body) (null? (cdr body)))
        (error "rx `regexp' form takes exactly one argument"))
      (let ((arg (car body)))
        (cond
          ((string? arg)
           ;; Generate the regexp when needed, since rx isn't
           ;; necessarily present in the byte-compilation environment.
           (unless rx--regexp-atomic-regexp
             (set! rx--regexp-atomic-regexp
                   ;; Match atomic (precedence t) regexps: may give
                   ;; false negatives but no false positives, assuming
                   ;; the target string is syntactically correct.
                   (rx-to-string
                    '(seq
                      bos
                      (or (seq "["
                               (opt "^")
                               (opt "]")
                               (* (or (seq "[:" (+ (any "a-z")) ":]")
                                      (not "]")))
                               "]")
                          (not (any "*+?^$[\\"))
                          (seq "\\"
                               (or anychar
                                   (seq (any "sScC_") anychar)
                                   (seq "("
                                        (* (or (not "\\")
                                               (seq "\\" (not ")"))))
                                        "\\)"))))
                      eos)
                    #t)))
           (cons (list arg)
                 (if (string-match-p rx--regexp-atomic-regexp arg) 't #f)))
          ((*rx--delayed-evaluation*)
           (cons (list arg) #f))
          (else (error "rx `regexp' form with non-string argument")))))

    ;;------------------------------------------------------------------
    ;; Compatibility with old rx (`rx-constituents').
    ;;------------------------------------------------------------------

    (define (rx--translate-compat-form def form)
      ;; "Translate a compatibility form from `rx-constituents'.  DEF is
      ;; the definition tuple.  Return (REGEXP . PRECEDENCE)."
      (let* ((fn (nth 0 def))
             (min-args (nth 1 def))
             (max-args (nth 2 def))
             (predicate (nth 3 def))
             (nargs (- (length form) 1)))
        (when (< nargs min-args)
          (error "The `~a' form takes at least ~a argument(s)"
                 (car form) min-args))
        (when (and max-args (> nargs max-args))
          (error "The `~a' form takes at most ~a argument(s)"
                 (car form) max-args))
        (when (and predicate (not (all predicate (cdr form))))
          (error "The `~a' form requires arguments satisfying `~a'"
                 (car form) predicate))
        (let ((regexp (fn form)))
          (unless (string? regexp)
            (error "The `~a' form did not expand to a string" (car form)))
          (cons (list regexp) #f))))

    (define (rx--translate-compat-symbol-entry entry)
      ;; "Translate a compatibility symbol definition for ENTRY.
      ;; Return (REGEXP . PRECEDENCE) or nil if none."
      (let loop ((entry entry))
        (cond ((not entry) #f)
              ((string? (cdr entry))
               (cons (list (cdr entry)) #f))
              (else
               (loop (if (symbol? (cdr entry))
                         ;; Alias for another entry.
                         (assq (cdr entry) rx-constituents)
                         ;; Wrong type, try further down the list.
                         (assq (car entry)
                               (cdr (memq entry rx-constituents)))))))))

    (define (rx--translate-compat-form-entry orig-form entry)
      ;; "Translate a compatibility ORIG-FORM definition for ENTRY.
      ;; Return (REGEXP . PRECEDENCE) or nil if none."
      (let loop ((entry entry))
        (cond ((not entry) #f)
              ((pair? (cdr entry))
               (rx--translate-compat-form (cdr entry) orig-form))
              (else
               (loop (if (symbol? (cdr entry))
                         ;; Alias for another entry.
                         (assq (cdr entry) rx-constituents)
                         ;; Wrong type, try further down the list.
                         (assq (car entry)
                               (cdr (memq entry rx-constituents)))))))))

    ;;------------------------------------------------------------------
    ;; User-defined definitions.
    ;;------------------------------------------------------------------

    (define (rx--substitute bindings form)
      ;; "Substitute BINDINGS in FORM.  BINDINGS is an alist of
      ;; (NAME . VALUES) where VALUES is a list to splice into FORM
      ;; wherever NAME occurs.  Return the substitution result wrapped
      ;; in a list, since a single value can expand to any number of
      ;; values."
      (cond ((symbol? form)
             (let ((binding (assq form bindings)))
               (if binding
                   (cdr binding)
                   (list form))))
            ((pair? form)
             (if (list? form)
                 ;; Proper list.  We substitute variables even in the
                 ;; head position -- who knows, might be handy one day.
                 (list (mapcan (lambda (x)
                                 (list-copy (rx--substitute bindings x)))
                               form))
                 ;; Cons pair (presumably an interval).
                 (let ((first (rx--substitute bindings (car form)))
                       (second (rx--substitute bindings (cdr form))))
                   (if (and (pair? first) (null? (cdr first))
                            (pair? second) (null? (cdr second)))
                       (list (cons (car first) (car second)))
                       (error "Cannot substitute a &rest parameter into a dotted pair")))))
            (else (list form))))

    (define (rx--expand-template op values arglist template)
      ;; "Return TEMPLATE with variables in ARGLIST replaced with VALUES."
      (let loop ((bindings '()) (value-tail values) (formals arglist))
        (cond
          ((null? formals)
           (when (pair? value-tail)
             (error "Expanding rx def `~a': too many arguments (got ~a, need ~a)"
                    op (length values) (length arglist)))
           (let ((subst (rx--substitute bindings template)))
             (if (and (pair? subst) (null? (cdr subst)))
                 (car subst)
                 (error "Expanding rx def `~a': must result in a single value" op))))
          ((eq? (car formals) '&rest)
           (unless (pair? (cdr formals))
             (error "Expanding rx def `~a': missing &rest parameter name" op))
           (loop (cons (cons (cadr formals) value-tail) bindings)
                 '() '()))
          (else
           (when (null? value-tail)
             (error "Expanding rx def `~a': too few arguments (got ~a, need ~a~a)"
                    op (length values)
                    (if (memq '&rest arglist) "at least " "")
                    (- (length arglist) (length (memq '&rest arglist)))))
           (loop (cons (cons (car formals) (list (car value-tail))) bindings)
                 (cdr value-tail) (cdr formals))))))

    (define (rx--translate-form form)
      ;; "Translate an rx form (list structure).  Return (REGEXP .
      ;; PRECEDENCE)."
      (let ((body (cdr form))
            (op (car form)))
        (cond
          ((memv op (list 'seq ': 'and 'sequence)) (rx--translate-seq body))
          ((memv op (list 'or '#{|}#))             (rx--translate-or body))
          ((memv op (list 'any 'in 'char))         (rx--translate-any #f body))
          ((eq? op 'rx--char-alt)                  (rx--translate-char-alt #f body))
          ((eq? op 'not-char)                      (rx--translate-any #t body))
          ((eq? op 'not)                           (rx--translate-not #f body))
          ((eq? op 'intersection)                  (rx--translate-intersection #f body))

          ((eq? op 'repeat)                        (rx--translate-repeat body))
          ((eq? op '=)                             (rx--translate-= body))
          ((eq? op '>=)                            (rx--translate->= body))
          ((eq? op '**)                            (rx--translate-** body))

          ((memv op (list 'zero-or-more '#{0+}#))
           (rx--translate-rep "*" (*rx--greedy*) body))
          ((memv op (list 'one-or-more '#{1+}#))
           (rx--translate-rep "+" (*rx--greedy*) body))
          ((memv op (list 'zero-or-one 'opt 'optional))
           (rx--translate-rep "?" (*rx--greedy*) body))

          ((eq? op '*)                             (rx--translate-rep "*" #t body))
          ((eq? op '+)                             (rx--translate-rep "+" #t body))
          ((memv op (list '? #\space 32))          (rx--translate-rep "?" #t body))

          ((eq? op '*?)                            (rx--translate-rep "*" #f body))
          ((eq? op '+?)                            (rx--translate-rep "+" #f body))
          ((memv op (list '?? #\? 63))             (rx--translate-rep "?" #f body))

          ((eq? op 'minimal-match)                 (rx--control-greedy #f body))
          ((eq? op 'maximal-match)                 (rx--control-greedy #t body))

          ((memv op (list 'group 'submatch))       (rx--translate-group body))
          ((memv op (list 'group-n 'submatch-n))   (rx--translate-group-n body))
          ((eq? op 'backref)                       (rx--translate-backref body))

          ((eq? op 'syntax)                        (rx--translate-syntax #f body))
          ((eq? op 'not-syntax)                    (rx--translate-syntax #t body))
          ((eq? op 'category)                      (rx--translate-category #f body))

          ((eq? op 'literal)                       (rx--translate-literal body))
          ((eq? op 'eval)                          (rx--translate-eval body))
          ((memv op (list 'regexp 'regex))         (rx--translate-regexp body))

          (else
           (cond
             ((not (symbol? op)) (error "Bad rx operator `~s'" op))

             ((let ((expanded (rx--expand-def-form form)))
                (and expanded
                     (rx--translate expanded))))

             ;; For compatibility with old rx.
             ((let ((entry (assq op rx-constituents)))
                (and entry (rx--translate-compat-form-entry form entry))))

             (else (error "Unknown rx form `~a'" op)))))))

    (define (rx--translate item)
      ;; "Translate the rx-expression ITEM.  Return (REGEXP .
      ;; PRECEDENCE)."
      (cond
        ((string? item)
         (if (= (string-length item) 0)
             (cons '() 'seq)
             (cons (list (regexp-quote item))
                   (if (= (string-length item) 1) 't 'seq))))
        ((%rx-characterp item)
         (cons (list (regexp-quote (char-to-string item))) 't))
        ((symbol? item)
         (rx--translate-symbol item))
        ((pair? item)
         (rx--translate-form item))
        (else (error "Bad rx expression: ~s" item))))

    (set! rx-to-string
          (lambda (form . rest)
            ;; "Translate FORM from `rx' sexp syntax into a string
            ;; regexp.  The arguments to `literal' and `regexp' forms
            ;; inside FORM must be constant strings.  If NO-GROUP is
            ;; non-nil, don't bracket the result in a non-capturing
            ;; group."
            (let* ((no-group (and (pair? rest) (car rest)))
                   (item (rx--translate form))
                   (exprs (if no-group
                              (car item)
                              (rx--atomic-regexp item))))
              (%rx-concat exprs))))

    (define (rx--to-expr form)
      ;; "Translate the rx-expression FORM to a Lisp expression yielding
      ;; a regexp."
      ;;
      ;; Emacs retrieves the local definitions from
      ;; `macroexpand-all-environment' here because `rx-let' puts them
      ;; there; `rx-let' is not carried, so the current parameter is the
      ;; whole answer (and it is empty unless `rx-let-eval' bound it
      ;; around a macro expansion, which cannot reach here).
      (parameterize ((*rx--delayed-evaluation* #t))
        (let ((elems (car (rx--translate form))))
          ;; Merge adjacent strings.
          (let loop ((elems elems) (args '()))
            (if (null? elems)
                (let ((args (reverse args)))
                  (cond ((null? args) "")                     ; 0 args
                        ((null? (cdr args)) (car args))       ; 1 arg
                        (else (cons 'string-append args))))   ; >=2 args
                (let inner ((es elems) (strings '()))
                  (if (and (pair? es) (string? (car es)))
                      (inner (cdr es) (cons (car es) strings))
                      (let ((s (%rx-concat (reverse strings))))
                        (let ((args (if (string=? s "") args (cons s args))))
                          (if (null? es)
                              (loop '() args)
                              (loop (cdr es) (cons (car es) args))))))))))))

    ;;------------------------------------------------------------------
    ;; Delayed evaluation for the `rx' macro.  The caller's expressions
    ;; are carried as syntax objects through the translation: the datum
    ;; is translated with a marker symbol in place of each non-string
    ;; `(literal EXPR)'/`(regexp EXPR)' argument, and the result is
    ;; turned back into syntax with the markers spliced in.
    ;;------------------------------------------------------------------

    (define (rx--scan-delayed stx)
      ;; Walk STX; answer (DATUM BINDINGS), where DATUM has each
      ;; non-string delayed argument replaced by a fresh marker symbol
      ;; and BINDINGS maps the marker to the argument's syntax.
      (let ((d (syntax->datum stx)))
        (if (pair? d)
            (let ((els (%rx-syn-list stx)))
              (if (and (memv (car d) (list 'literal 'regexp))
                       (= (length d) 2)
                       (not (string? (cadr d))))
                  (let ((m (gensym "rx-expr")))
                    (values (list (car d) m)
                            (list (cons m (cadr els)))))
                  (let loop ((es els) (acc '()) (binds '()))
                    (if (null? es)
                        (values (reverse acc) binds)
                        (call-with-values
                         (lambda () (rx--scan-delayed (car es)))
                         (lambda (d1 b1)
                           (loop (cdr es)
                                 (cons d1 acc)
                                 (append b1 binds))))))))
            (values d '()))))

    (define (rx--expr->syntax datum binds here)
      ;; Turn the expression DATUM back into syntax: marker symbols
      ;; become the caller's own syntax, every other identifier carries
      ;; HERE's lexical context (which is this library's, so the
      ;; introduced `string-append' and `regexp-quote' resolve here).
      (cond ((symbol? datum)
             (let ((b (assq datum binds)))
               (if b
                   (cdr b)
                   (datum->syntax here datum))))
            ((pair? datum)
             (let ((a (rx--expr->syntax (car datum) binds here))
                   (b (rx--expr->syntax (cdr datum) binds here)))
               #`(#,a . #,b)))
            (else (datum->syntax here datum))))

    (define-syntax rx
      (lambda (stx)
        ;; "Translate regular expressions REGEXPS in sexp form to a
        ;; regexp string."
        (syntax-case stx ()
          ((_ regexp ...)
           (call-with-values
            (lambda () (rx--scan-delayed #'(regexp ...)))
            (lambda (marked binds)
              (let ((expr (rx--to-expr (cons 'seq marked))))
                (rx--expr->syntax expr binds (syntax regexp-quote)))))))))

    ;;------------------------------------------------------------------
    ;; Definitions: rx-define, rx-let-eval (and the missing rx-let).
    ;;------------------------------------------------------------------

    (define (rx--make-binding name tail)
      ;; "Make a definitions entry out of TAIL.  TAIL is on the form
      ;; ([ARGLIST] DEFINITION)."
      (unless (symbol? name)
        (error "Bad `rx' definition name: ~s" name))
      ;; FIXME: Consider using a hash table or symbol property, for
      ;; speed.
      (when (memq name rx--builtin-names)
        (error "Cannot redefine built-in rx name `~a'" name))
      (cond
        ((and (pair? tail) (null? (cdr tail)))
         (list (car tail)))
        ((and (pair? tail) (pair? (cdr tail)) (null? (cddr tail)))
         (let ((args (car tail)))
           (unless (and (list? args) (all symbol? args))
             (error "Bad argument list for `rx' definition ~a: ~s" name args))
           (list args (cadr tail))))
        (else (error "Bad `rx' definition of ~a: ~s" name tail))))

    (define (rx--make-named-binding bindspec)
      ;; "Make a definitions entry out of BINDSPEC.  BINDSPEC is on the
      ;; form (NAME [ARGLIST] DEFINITION)."
      (unless (pair? bindspec)
        (error "Bad `rx-let' binding: ~s" bindspec))
      (cons (car bindspec)
            (rx--make-binding (car bindspec) (cdr bindspec))))

    (define (rx--extend-local-defs bindspecs)
      (append (map rx--make-named-binding bindspecs)
              (*rx--local-definitions*)))

    (define-syntax rx-let-eval
      (lambda (stx)
        ;; "Evaluate BODY with local BINDINGS for `rx-to-string'."
        ;; Emacs's expansion is `(let ((rx--local-definitions
        ;; (rx--extend-local-defs ,bindings))) ,@body)'; the `let' of a
        ;; parameter is `parameterize'.
        (syntax-case stx ()
          ((_ bindings body ...)
           ;; A pattern variable cannot be unsyntaxed directly; it can
           ;; inside a `syntax' form, which is what `#,(syntax ...)'
           ;; is (the same idiom `define-minor-mode' uses).
           #`(parameterize ((*rx--local-definitions*
                             (rx--extend-local-defs #,(syntax bindings))))
               #,@(%rx-syn-list (syntax (body ...))))))))

    (define-syntax rx-define
      (lambda (stx)
        ;; "Define NAME as a global `rx' definition."
        ;;
        ;; **The `put' happens in the transformer as well as in the
        ;; expansion.**  Emacs's `eval-and-compile' makes the definition
        ;; available to a later `(rx user-name)' in the same file at
        ;; compile time; Guile's compiler does not run top-level
        ;; effects, so the transformer - which does run at expansion
        ;; time - records it.  The emitted form repeats it when the
        ;; library loads, which is idempotent.
        (syntax-case stx ()
          ((_ name definition ...)
           (let* ((nm (syntax->datum (syntax name)))
                  (body (syntax->datum (syntax (definition ...))))
                  (binding (rx--make-binding nm body)))
             (put nm 'rx-definition binding)
             (let ((nq (datum->syntax (syntax name) (list 'quote nm)))
                   (bq (datum->syntax (syntax name) (list 'quote binding))))
               #`(begin (put #,nq 'rx-definition #,bq) #,nq)))))))

    ;;------------------------------------------------------------------
    ;; The pcase pattern.
    ;;------------------------------------------------------------------

    (define *rx--pcase-vars* (make-parameter '())
      ;; "During `rx--pcase-transform', list of defined variables in
      ;; right-to-left order."
      )

    (define (rx--pcase-transform rx)
      ;; "Transform RX, an rx-expression augmented with `let' and named
      ;; `backref', into a plain rx-expression, collecting names into
      ;; `rx--pcase-vars'."
      (cond
        ((and (pair? rx) (eq? (car rx) 'let) (pair? (cdr rx)) (symbol? (cadr rx)))
         (let* ((name (cadr rx))
                (body (cddr rx))
                (index (length (or (memq name (*rx--pcase-vars*)) '()))))
           (let ((i (if (= index 0)
                        (let ((new (cons name (*rx--pcase-vars*))))
                          (*rx--pcase-vars* new)
                          (length new))
                        index)))
             (list 'group-n i (rx--pcase-transform (cons 'seq body))))))
        ((and (pair? rx) (eq? (car rx) 'backref)
              (pair? (cdr rx)) (symbol? (cadr rx)))
         (let ((index (length (or (memq (cadr rx) (*rx--pcase-vars*)) '()))))
           (when (= index 0)
             (error "rx `backref' variable must be one of: ~a"
                    (%rx-concat
                     (let loop ((vs (*rx--pcase-vars*)) (acc '()))
                       (if (null? vs)
                           (reverse acc)
                           (loop (cdr vs)
                                 (cons (symbol->string (car vs)) acc)))))))
           (list 'backref index)))
        ((and (pair? rx)
              (or (symbol? (car rx))
                  (memv (car rx) (list '? '?? #\space #\? 32 63)))
              (not (memv (car rx) (list 'literal 'regexp 'regex 'eval))))
         (cons (car rx) (map rx--pcase-transform (cdr rx))))
        (else rx)))

    (define (rx--reduce-right f l)
      ;; "Right-reduction on L by F.  L must be non-empty."
      (if (pair? (cdr l))
          (f (car l) (rx--reduce-right f (cdr l)))
          (car l)))

    ;; The match procedures the pcase pattern's expansion names.  They
    ;; are ordinary exported procedures called with the regexp, and the
    ;; call is what the pattern data holds - NOT a closure value.  A
    ;; closure would have to be compiled as a literal constant at the
    ;; use site, and Guile's compiler refuses a procedure as a
    ;; constant at every optimization level ("unhandled constant
    ;; #<procedure>" from the CPS type pass), so a pattern carrying
    ;; one cannot be used in any compiled library.
    (define (rx--pcase-pred regexp)
      (lambda (s) (string-match regexp s)))
    (define (rx--pcase-match-1 regexp)
      ;; On success the submatch value, 0 on failure: nil cannot say
      ;; "failed" because it is a valid submatch value.
      (lambda (s)
        (if (string-match regexp s)
            (match-string 1 s)
            0)))
    (define (rx--pcase-match-n regexp nvars)
      ;; Pack the submatches into a dotted list, which the pattern
      ;; then destructures into the individual variables again.
      (lambda (s)
        (and (string-match regexp s)
             (rx--reduce-right
              cons
              (map (lambda (i) (match-string i s))
                   (number-sequence 1 nvars))))))

    (define (%rx-pattern-macro . regexps)
      ;; The `(pcase-defmacro rx ...)' of rx.el, as a pattern expander
      ;; for this tree's pcase (registered below).  It receives the
      ;; pattern's arguments as data and answers the pattern data.
      ;;
      ;; **The expansion names `rx--pcase-pred'/`rx--pcase-match-1'/
      ;; `rx--pcase-match-n' rather than Emacs's `string-match' and
      ;; `match-string'**, because a pcase pattern is data and a name
      ;; in it resolves at the use site: those two live in
      ;; `(schemacs search)' here, which a use site has no reason to
      ;; import, while the rx names come with `(schemacs core rx)' -
      ;; the library whose load registers the pattern.  So a use site
      ;; needs `(schemacs core rx)' imported, not only loaded; Emacs
      ;; needs only the load, its obarray being global.  Everything
      ;; else in the data stays a symbol resolved at the use site
      ;; (`string?' and `and'/`app'/`pred'/`quasiquote' live in
      ;; `(scheme base)') or a constant (the regexp string, the var
      ;; count).
      (parameterize ((*rx--pcase-vars* '()))
        (let* ((regexp (rx--to-expr (rx--pcase-transform (cons 'seq regexps))))
               (vars (*rx--pcase-vars*))
               (nvars (length vars)))
          (cond
            ((= nvars 0)
             ;; No variables bound: a single predicate suffices.
             (list 'and
                   (list 'pred 'string?)
                   (list 'pred (list 'rx--pcase-pred regexp))))
            ((= nvars 1)
             (list 'and
                   (list 'pred 'string?)
                   (list 'app
                         (list 'rx--pcase-match-1 regexp)
                         (list 'and
                               (car vars)
                               (list 'pred
                                     (list 'lambda (list 'v)
                                           (list 'not (list 'number? 'v))))))))
            (else
             (list 'and
                   (list 'pred 'string?)
                   (list 'app
                         (list 'rx--pcase-match-n regexp nvars)
                         (list 'quasiquote
                               (rx--reduce-right
                                cons
                                (map (lambda (name) (list 'unquote name))
                                     (reverse vars)))))))))))

    ;; Register the expander.  Emacs's `(pcase-defmacro rx ...)' defines a
    ;; function named `rx', which here would collide with the `rx' macro
    ;; binding above; the property is what pcase reads
    ;; (`pcase--macroexpand' asks `(get head 'pcase-macroexpander)'), so
    ;; this is the same registration without the definition.
    (put 'rx 'pcase-macroexpander %rx-pattern-macro)

    ))
