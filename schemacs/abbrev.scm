(define-library (schemacs abbrev)
  ;; This library mirrors GNU Emacs's `lisp/abbrev.el': abbreviation
  ;; tables, abbreviation expansion, and Abbrev mode.
  ;;
  ;; **The table is a record, not an obarray.** Emacs 31's abbrev tables
  ;; are obarrays (`obarray-make', `obarray-get'), whose symbols are
  ;; per-table so that the same abbreviation can expand differently in two
  ;; tables. Guile's symbols are interned globally and cannot be, so an
  ;; abbreviation is a record held in the table's own hash, and its
  ;; expansion, hook and properties are fields of that record where Emacs
  ;; keeps them in the symbol's value, function cell and plist.
  ;; `abbrev-symbol' answers the record rather than a symbol - a named
  ;; departure, and the one thing a caller must know.
  ;;
  ;; What is here is the whole mechanism cc-mode and `insert-tab' need: the
  ;; table type, `define-abbrev', `define-abbrev-table', `abbrev-expansion',
  ;; `expand-abbrev' and its helpers, Abbrev mode and `local-abbrev-table'.
  ;; **Not carried**, each because it needs a subsystem this tree does not
  ;; have or is a user command that only prompts: the abbrev-file commands
  ;; (`read-abbrev-file', `write-abbrev-file', `list-abbrevs',
  ;; `edit-abbrevs', `insert-abbrev-table-description'), the suggestion
  ;; machinery (`abbrev-suggest'), and the defining commands that read from
  ;; the minibuffer (`add-mode-abbrev', `add-global-abbrev', ...).
  ;; `abbrev-minor-mode-table-alist' reads a minor mode's variable through
  ;; the buffer-local slot this tree keeps it in.
  ;;
  ;; A hook is a procedure here where Emacs holds a function symbol, so the
  ;; `no-self-insert' property lookup on the hook symbol has no
  ;; counterpart; it is named at its site.

  (import
    (scheme base)
    (scheme char)
    (only (scheme cxr) caddr)
    (only (guile) make-hash-table hash-ref hash-set! hash-map->list)
    (only (schemacs buffer) current-buffer buffer-local-value set-buffer-local-value!
          *case-fold-search*)
    (only (schemacs data) default-value)
    (only (schemacs editfns)
          point point-min point-max goto-char insert delete-region
          buffer-substring-no-properties char-after line-beginning-position
          save-excursion)
    (only (schemacs syntax)
          forward-word skip-syntax-backward skip-syntax-forward)
    (only (schemacs search) looking-back string-match match-beginning match-end)
    (only (schemacs marker) copy-marker marker-position)
    (only (schemacs undo) text-editor-undo-boundary!)
    (only (schemacs casefiddle) casify-region)
    (only (schemacs frame) *minibuffer*)
    (only (schemacs custom) define-custom)
    (only (schemacs core syntax-macros) when-e)
    (only (schemacs core easy-mmode) define-minor-mode))

  (export
   abbrev-table-p make-abbrev-table define-abbrev-table define-abbrev
   clear-abbrev-table copy-abbrev-table
   abbrev-table-get abbrev-table-put
   ;; The table's own abbrev hash. Emacs's tables are obarrays, so
   ;; `(intern-soft NAME TABLE)' is a member test; this hash is that
   ;; obarray, and the accessor is exported for the one caller that
   ;; needs the same test (`c-populate-abbrev-table').
   abbrev-table-abbrevs
   abbrev--symbol abbrev-symbol abbrev-expansion abbrev-get abbrev-put
   abbrev-table-named abbrev-table-name-list
   global-abbrev-table fundamental-mode-abbrev-table
   local-abbrev-table set!local-abbrev-table
   abbrev-mode abbrev-mode-variable set!abbrev-mode-variable!
   expand-abbrev abbrev--default-expand abbrev-insert unexpand-abbrev
   *abbrev-all-caps* abbrevs-changed abbrev-expand-function
   abbrev-minor-mode-table-alist
   abbrev-start-location abbrev-start-location-buffer
   last-abbrev last-abbrev-text last-abbrev-location)

  (begin

    ;;----------------------------------------------------------------
    ;; The table type
    ;;----------------------------------------------------------------

    (define-record-type <abbrev-table>
      (%make-abbrev-table name abbrevs props parents)
      %abbrev-table?
      (name abbrev-table-name)
      (abbrevs abbrev-table-abbrevs set!abbrev-table-abbrevs!)
      (props abbrev-table-props set!abbrev-table-props!)
      (parents abbrev-table-parents set!abbrev-table-parents!))

    ;; An abbreviation: Emacs keeps EXPANSION in the symbol's value, HOOK
    ;; in its function cell, and the rest in its plist.
    (define-record-type <abbrev>
      (%make-abbrev name expansion hook props)
      abbrev?
      (name abbrev-name)
      (expansion abbrev-expansion-value set!abbrev-expansion-value!)
      (hook abbrev-hook set!abbrev-hook!)
      (props abbrev-props set!abbrev-props!))

    (define (abbrev-table-p object)
      ;; GNU Emacs's `abbrev-table-p' (`abbrev.el:534'): "Return non-nil
      ;; if OBJECT is an abbrev table." Emacs tests for an obarray carrying
      ;; `:abbrev-table-modiff'; this tests for the record.
      ;;--------------------------------------------------------------
      (%abbrev-table? object))

    (define (abbrev-get abbrev prop)
      ;; GNU Emacs's `abbrev-get' (`abbrev.el:526', a `defalias' of `get'):
      ;; "Get the property PROP of abbrev ABBREV."
      ;;--------------------------------------------------------------
      (let ((entry (assq prop (abbrev-props abbrev))))
        (and entry (cdr entry))))

    (define (abbrev-put abbrev prop val)
      ;; GNU Emacs's `abbrev-put' (`abbrev.el:531'): "Set the property PROP
      ;; of abbrev ABBREV to value VAL."
      ;;--------------------------------------------------------------
      (let ((entry (assq prop (abbrev-props abbrev))))
        (if entry
            (set-cdr! entry val)
            (set!abbrev-props! abbrev
                               (cons (cons prop val) (abbrev-props abbrev)))))
      val)

    (define (abbrev-table-get table prop)
      ;; GNU Emacs's `abbrev-table-get' (`abbrev.el:511'): "Get the
      ;; property PROP of abbrev table TABLE." Emacs stores it on the
      ;; table's "" symbol; here it is the table's own property alist.
      ;;--------------------------------------------------------------
      (let ((entry (assq prop (abbrev-table-props table))))
        (and entry (cdr entry))))

    (define (abbrev-table-put table prop val)
      ;; GNU Emacs's `abbrev-table-put' (`abbrev.el:517'): "Set the property
      ;; PROP of abbrev table TABLE to VAL."
      ;;--------------------------------------------------------------
      (let ((entry (assq prop (abbrev-table-props table))))
        (if entry
            (set-cdr! entry val)
            (set!abbrev-table-props!
             table (cons (cons prop val) (abbrev-table-props table)))))
      val)

    (define (make-abbrev-table . props)
      ;; GNU Emacs's `make-abbrev-table' (`abbrev.el:540'): "Create a new,
      ;; empty abbrev table object. PROPS is a list of properties." The
      ;; `:abbrev-table-modiff' entry is the tag `abbrev-table-p' looks for
      ;; in Emacs; the record's type is the tag here, but the counter is
      ;; kept because `define-abbrev' records the value it saw.
      ;;--------------------------------------------------------------
      (let ((table (%make-abbrev-table #f (make-hash-table) '() '())))
        (abbrev-table-put table ':abbrev-table-modiff 0)
        (let loop ((rest (if (pair? props) (car props) '())))
          (cond ((null? rest) #f)
                ((null? (cdr rest))
                 (error "Missing value for property" (car rest)))
                (else (abbrev-table-put table (car rest) (cadr rest))
                      (loop (cddr rest)))))
        table))

    (define (clear-abbrev-table table)
      ;; GNU Emacs's `clear-abbrev-table' (`abbrev.el:618'): "Undefine all
      ;; abbrevs in abbrev table TABLE, leaving TABLE empty." The table's
      ;; properties are preserved and its modification counter raised - the
      ;; C keeps them on the table's own symbol while its obarray is
      ;; cleared.
      ;;--------------------------------------------------------------
      (set! abbrevs-changed #t)
      (set!abbrev-table-abbrevs! table (make-hash-table))
      (abbrev-table-put table ':abbrev-table-modiff
                        (+ 1 (abbrev-table-get table ':abbrev-table-modiff)))
      #f)

    (define (copy-abbrev-table table)
      ;; GNU Emacs's `copy-abbrev-table' (`abbrev.el:82'): "Make a new
      ;; abbrev table with the same abbrevs as TABLE. This function does
      ;; not copy property lists of the abbrevs."
      ;;--------------------------------------------------------------
      (let ((new (make-abbrev-table)))
        ;; Emacs's `obarray-map' calls `define-abbrev' with the name,
        ;; the expansion and the function, and not the plist - "does not
        ;; copy property lists of the abbrevs".
        (hash-map->list
         (lambda (name abbrev)
           (unless (string=? name "")
             (define-abbrev new name
                            (abbrev-expansion-value abbrev)
                            (abbrev-hook abbrev))))
         (abbrev-table-abbrevs table))
        new))

    ;;----------------------------------------------------------------
    ;; The named tables
    ;;
    ;; Emacs keeps a table under a symbol and reads it with `symbol-value';
    ;; there is no symbol-value here, so the registry is what
    ;; `define-abbrev-table' fills and `abbrev-table-named' reads.
    ;;----------------------------------------------------------------

    (define abbrev-table-name-list '())
    (define %abbrev-tables (make-hash-table))

    (define (abbrev-table-named name)
      ;; Emacs's `(symbol-value NAME)' for an abbrev-table name.
      ;;--------------------------------------------------------------
      (hash-ref %abbrev-tables name #f))

    (define (define-abbrev-table tablename definitions . rest)
      ;; GNU Emacs's `define-abbrev-table' (`abbrev.el:1192'): "Define
      ;; TABLENAME (a symbol) as an abbrev table name." The docstring is not
      ;; carried (this tree's variables have no docstring slot); PROPS is a
      ;; keyword plist as in `make-abbrev-table'.
      ;;--------------------------------------------------------------
      (let* ((doc (and (pair? rest) (string? (car rest)) (car rest)))
             (props (if doc (cdr rest) rest))
             (table (or (abbrev-table-named tablename)
                        (let ((new (make-abbrev-table)))
                          (hash-set! %abbrev-tables tablename new)
                          (unless (memq tablename abbrev-table-name-list)
                            (set! abbrev-table-name-list
                                  (cons tablename abbrev-table-name-list)))
                          new))))
        (let loop ((rest props))
          (cond ((null? rest) #f)
                ((null? (cdr rest))
                 (error "Missing value for property" (car rest)))
                (else
                 (abbrev-table-put table (car rest) (cadr rest))
                 (loop (cddr rest)))))
        (for-each (lambda (definition)
                    (apply define-abbrev table definition))
                  definitions)
        table))

    (define global-abbrev-table (make-abbrev-table))
    ;; ^ GNU Emacs's `global-abbrev-table' (`abbrev.el:568'): "The abbrev
    ;; table whose abbrevs affect all buffers."

    (define %local-abbrev-table-default #f)
    ;; ^ The `local-abbrev-table' default, which Emacs sets to
    ;; `fundamental-mode-abbrev-table' as that table is made.

    (define fundamental-mode-abbrev-table
      (let ((table (make-abbrev-table)))
        (set! %local-abbrev-table-default table)
        table))
    ;; ^ GNU Emacs's `fundamental-mode-abbrev-table' (`abbrev.el:565').

    (define (local-abbrev-table)
      ;; GNU Emacs's buffer-local `local-abbrev-table': "Local
      ;; (mode-specific) abbrev table of current buffer." A buffer-local
      ;; slot here, whose default is `fundamental-mode-abbrev-table'.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'local-abbrev-table
                          %local-abbrev-table-default))

    (define (set!local-abbrev-table table)
      (set-buffer-local-value! (current-buffer) 'local-abbrev-table table))

    (define-custom *abbrev-all-caps* #f
      "Non-nil means expand multi-word abbrevs in all caps if the abbrev was so."
      :type 'boolean
      :group 'abbrev)

    (define abbrevs-changed #f)
    ;; ^ GNU Emacs's `abbrevs-changed' (`abbrev.el:571'): "Non-nil if any
    ;; word abbrevs were defined or altered." A plain variable (a `defvar'
    ;; that is only `setq'-ed).
    (set! abbrevs-changed abbrevs-changed)   ; mutable to the compiler

    (define abbrev-minor-mode-table-alist '())
    ;; ^ GNU Emacs's `abbrev-minor-mode-table-alist' (`abbrev.el:560'):
    ;; "Alist of abbrev tables to use for minor modes." Each element is
    ;; `(VARIABLE . TABLE)`; VARIABLE is a minor-mode variable, read
    ;; through the buffer's slot or its default.

    (define abbrev-start-location #f)
    (define abbrev-start-location-buffer #f)
    (define last-abbrev #f)
    (define last-abbrev-text #f)
    (define last-abbrev-location 0)
    ;; ^ `abbrev.el:580`-`:597`, the defvars around `abbrev-start-location'
    ;; and the last expansion. Plain variables: nothing `let`-binds them.

    ;;----------------------------------------------------------------
    ;; Looking an abbreviation up
    ;;----------------------------------------------------------------

    (define (abbrev--active-tables . tables)
      ;; GNU Emacs's `abbrev--active-tables' (`abbrev.el:711'): "Return the
      ;; list of abbrev tables that are currently active." TABLES, if
      ;; non-nil, overrides the usual rules and may hold a table or a list
      ;; of tables.
      ;;--------------------------------------------------------------
      (let ((tables (and (pair? tables) (car tables))))
        (cond
         ((and tables (pair? tables) (abbrev-table-p (car tables))) tables)
         ((abbrev-table-p tables) (list tables))
         (else
          (let ((tables (let ((local (local-abbrev-table)))
                          (if (list? local)
                              (append local (list global-abbrev-table))
                              (list local global-abbrev-table)))))
            ;; "Add the minor-mode abbrev tables." Emacs reads VARIABLE
            ;; with `symbol-value'; the slot, then its default.
            (for-each
             (lambda (entry)
               (let ((variable (car entry)))
                 (when (or (buffer-local-value (current-buffer) variable #f)
                           (default-value variable #f))
                   (set! tables
                         (if (list? (cdr entry))
                             (append (cdr entry) tables)
                             (cons (cdr entry) tables))))))
             abbrev-minor-mode-table-alist)
            tables)))))

    (define (abbrev--symbol abbrev table)
      ;; GNU Emacs's `abbrev--symbol' (`abbrev.el:735'): "Return the symbol
      ;; representing abbrev named ABBREV in TABLE." Answers the
      ;; abbreviation record only when it has an expansion, which is what
      ;; Emacs's `(symbol-value sym)' test means.
      ;;--------------------------------------------------------------
      (let* ((case-fold (not (abbrev-table-get table ':case-fixed)))
             (cell (or (hash-ref (abbrev-table-abbrevs table) abbrev #f)
                       (and case-fold
                            (let ((cell (hash-ref (abbrev-table-abbrevs table)
                                                  (string-downcase abbrev) #f)))
                              (and cell
                                   (not (abbrev-get cell ':case-fixed))
                                   cell))))))
        (and cell (abbrev-expansion-value cell) cell)))

    (define (abbrev-symbol abbrev . table)
      ;; GNU Emacs's `abbrev-symbol' (`abbrev.el:750'): "Return the symbol
      ;; representing the abbrev named ABBREV in TABLE." The optional TABLE
      ;; defaults to the buffer's mode-specific table, then the global one,
      ;; with each table's parents after it.
      ;;--------------------------------------------------------------
      (let loop ((tables (abbrev--active-tables (and (pair? table) (car table))))
                 (sym #f))
        (cond ((or (null? tables) sym) sym)
              (else
               (let* ((table (car tables))
                      (sym (abbrev--symbol abbrev table)))
                 (loop (append (or (abbrev-table-parents table) '())
                               (cdr tables))
                       sym))))))

    (define (abbrev-expansion abbrev . table)
      ;; GNU Emacs's `abbrev-expansion' (`abbrev.el:772'): "Return the
      ;; string that ABBREV expands into in the current buffer."
      ;;--------------------------------------------------------------
      (let ((cell (apply abbrev-symbol abbrev table)))
        (and cell (abbrev-expansion-value cell))))

    ;;----------------------------------------------------------------
    ;; Expansion
    ;;----------------------------------------------------------------

    (define (abbrev--before-point)
      ;; GNU Emacs's `abbrev--before-point' (`abbrev.el:783'): "Try and
      ;; find an abbrev before point. Return it if found, nil otherwise."
      ;; The answer is `(ABBREV NAME START END)`, or #f.
      ;;--------------------------------------------------------------
      (unless (eq? abbrev-start-location-buffer (current-buffer))
        (set! abbrev-start-location #f))
      (let ((tables (abbrev--active-tables))
            (pos (point))
            (start #f) (end #f) (name #f) (res #f))
        (if abbrev-start-location
            (begin
              (set! start abbrev-start-location)
              (set! abbrev-start-location #f)
              ;; "Remove the hyphen inserted by `abbrev-prefix-mark'."
              (when (and (< start (point-max))
                         (eqv? (char->integer (char-after start))
                               (char->integer #\-)))
                (delete-region start (+ start 1))
                (set! pos (- pos 1)))
              (skip-syntax-backward " ")
              (set! end (point))
              ;; **`when-e`, not `when`.** This `when` is the value of
              ;; the `if`'s consequent (`abbrev.el:800`), and Elisp's
              ;; `when` answers nil when the test fails; Scheme's
              ;; answers the unspecified value, which is *true*, so a
              ;; caller's `(when found ...)` would act on it. See
              ;; `abbrev--default-expand` below - the reported bug was
              ;; "Wrong type argument in position 1: #<unspecified>"
              ;; when typing a space in a C buffer (`c-mode` sets
              ;; `abbrev-mode` t, as Emacs's does) with no abbrev
              ;; before point.
              (when-e (> end start)
                (set! name (buffer-substring-no-properties start end))
                (goto-char pos)              ; restore point
                (list (abbrev-symbol name tables) name start end)))
            (begin
              ;; "We used to default `re' to \"\\\\<\\\\(\\\\w+\\\\)\\\\W*\" but
              ;; when words-include-escapes is set, that is not right." The
              ;; default is the word before point, walked with the syntax
              ;; table's word motion.
              (let loop ((ts tables))
                (cond
                 ((or (null? ts) (pair? res))
                  (goto-char pos)            ; restore point
                  res)
                 (else
                  (let* ((table (car ts))
                         (enable-fun (abbrev-table-get table ':enable-function))
                         (ts (append (or (abbrev-table-parents table) '())
                                     (cdr ts))))
                    (set! res
                          (and (or (not enable-fun) (enable-fun))
                               (let ((re (abbrev-table-get table ':regexp)))
                                 (if (not re)
                                     (let ((lim (point)))
                                       (forward-word -1)
                                       (set! start (point))
                                       (forward-word 1)
                                       (set! end (min (point) lim)))
                                     ;; `when-e`: this is an operand of
                                     ;; the `and`, and Elisp's `when`
                                     ;; answers nil when there is no
                                     ;; match. A Scheme `when` answers
                                     ;; the unspecified value, which is
                                     ;; true, so the `and` would go on
                                     ;; to read `start`/`end` from a
                                     ;; previous table's attempt.
                                     (when-e (looking-back re
                                                           (line-beginning-position))
                                       (set! start (match-beginning 1))
                                       (set! end (match-end 1)))))
                               (set! name (buffer-substring-no-properties start end))
                               (let ((abbrev (abbrev--symbol name table)))
                                 ;; `when-e` again: this is the last
                                 ;; operand of the `and`, so Elisp's
                                 ;; `when` answers nil here and makes
                                 ;; `res` nil when the word is not an
                                 ;; abbrev. A Scheme `when` leaves the
                                 ;; unspecified value in `res`, which
                                 ;; is true, and `abbrev--before-point`
                                 ;; then answers it instead of nil.
                                 (when-e abbrev
                                   (let ((enable-fun
                                          (abbrev-get abbrev ':enable-function)))
                                     (and (or (not enable-fun) (enable-fun))
                                          (list abbrev name start end)))))))
                    (loop ts)))))))))

    (define (abbrev-insert abbrev . args)
      ;; GNU Emacs's `abbrev-insert' (`abbrev.el:839'): "Insert abbrev
      ;; ABBREV at point. ... Return ABBREV if the expansion should be
      ;; considered as having taken place."
      ;;--------------------------------------------------------------
      (let* ((name (or (and (pair? args) (car args)) (abbrev-name abbrev)))
             (wordstart (or (and (pair? args) (pair? (cdr args)) (cadr args))
                            (point)))
             (wordend (or (and (pair? args) (pair? (cdr args))
                               (pair? (cddr args)) (caddr args))
                          wordstart))
             (expansion (abbrev-expansion-value abbrev))
             (value abbrev))
        ;; "Increment use count."
        (abbrev-put abbrev ':count
                    (+ 1 (or (abbrev-get abbrev ':count) 0)))
        ;; "If this abbrev has an expansion, delete the abbrev and insert
        ;; the expansion." Insert at the beginning so that markers at the
        ;; end (e.g. point) are preserved.
        (when (string? expansion)
          (goto-char wordstart)
          (insert expansion)
          (delete-region (point) (+ (point) (- wordend wordstart)))
          ;; "If the abbrev's name is different from the buffer text (the
          ;; only difference should be capitalization), then we may want to
          ;; adjust the capitalization of the expansion." Emacs binds
          ;; `case-fold-search` to nil around it, so the two class tests
          ;; below see the case they name.
          (parameterize ((*case-fold-search* #f))
          (when (and (not (string=? name (abbrev-name abbrev)))
                     (string-match "[[:upper:]]" name))
            (if (not (string-match "[[:lower:]]" name))
                ;; "Abbrev was all caps. If expansion is multiple words,
                ;; normally capitalize each word."
                (if (and (not (*abbrev-all-caps*))
                         (save-excursion
                           (> (begin (forward-word -1) (point))
                              (begin (goto-char wordstart)
                                     (forward-word 1) (point)))))
                    (casify-region 'capitalize-up wordstart (point))
                    (casify-region 'upcase wordstart (point)))
                ;; "Abbrev included some caps. Cap first initial of
                ;; expansion."
                (let ((end (point)))
                  (goto-char wordstart)
                  (skip-syntax-forward "^w" (- end 1))
                  (casify-region 'capitalize-up (point) (+ (point) 1))
                  (goto-char end))))))
        ;; "If the abbrev has a hook function, run it." Emacs's hook is a
        ;; function symbol and its `no-self-insert' property can say the
        ;; expansion did not happen; a procedure here has no property, so
        ;; the property arm is not carried.
        (let ((hook (abbrev-hook abbrev)))
          (when hook (hook)))
        value))

    (define abbrev-expand-function #f)
    ;; ^ GNU Emacs's `abbrev-expand-function' (`abbrev.el:905'):
    ;; "Function that `abbrev-expand-function' uses"... the defvar's
    ;; value is the *symbol* `abbrev--default-expand', which needs
    ;; nothing to exist yet; here it is the procedure, so it is set after
    ;; that definition below. #f until then, as this tree's
    ;; `normal-auto-fill-function' does for the same reason.

    (define (expand-abbrev)
      ;; GNU Emacs's `expand-abbrev' (`abbrev.el:1053'): "Expand the abbrev
      ;; before point, if there is an abbrev there."
      ;;--------------------------------------------------------------
      (abbrev-expand-function))

    (define (abbrev--default-expand)
      ;; GNU Emacs's `abbrev--default-expand' (`abbrev.el:1065'): "Default
      ;; function to use for `abbrev-expand-function'."
      ;;--------------------------------------------------------------
      (let ((found (abbrev--before-point)))
        ;; `when-e`: Emacs's `abbrev--default-expand` answers nil when
        ;; there is no abbrev before point ("Return it if found, nil
        ;; otherwise"), and `internal_self_insert`/`insert-tab` read
        ;; `expand-abbrev`'s answer as a test. A Scheme `when` would
        ;; answer the unspecified value, which is true.
        (when-e found
          (let ((sym (list-ref found 0))
                (name (list-ref found 1))
                (wordstart (list-ref found 2))
                (wordend (list-ref found 3)))
            (let ((startpos (copy-marker (point) #t))
                  (endmark (copy-marker wordend #t)))
              ;; "Add an undo boundary, in case we are doing this for a
              ;; self-inserting command which has avoided making one so
              ;; far." Emacs's guard is `(window-minibuffer-p)' on the
              ;; selected window; a minibuffer read here is `*minibuffer*'.
              (unless (*minibuffer*)
                (text-editor-undo-boundary! (current-buffer)))
              (set! last-abbrev-text name)
              (set! last-abbrev sym)
              (set! last-abbrev-location wordstart)
              (let ((answer (abbrev-insert sym name wordstart wordend)))
                ;; "Yuck!! If expand-abbrev is called with point slightly
                ;; further than the end of the abbrev, move point back to
                ;; where it started."
                (if (and (> (marker-position startpos)
                            (marker-position endmark))
                         (= (point) (marker-position endmark)))
                    (goto-char (marker-position startpos)))
                answer))))))

    (set! abbrev-expand-function abbrev--default-expand)
    ;; ^ The value of the defvar, once the function exists - and the
    ;; assignment marks the binding mutable to the compiler.

    (define (unexpand-abbrev)
      ;; GNU Emacs's `unexpand-abbrev' (`abbrev.el:1093'): "Undo the
      ;; expansion of the last abbrev that expanded."
      ;;--------------------------------------------------------------
      (save-excursion
        (when (and (<= (point-min) last-abbrev-location)
                   (<= last-abbrev-location (point-max)))
          (goto-char last-abbrev-location)
          (when (string? last-abbrev-text)
            (let ((val (and last-abbrev
                            (abbrev-expansion-value last-abbrev))))
              (unless (string? val)
                (error "Value of abbrev-symbol must be a string"))
              ;; "Don't inherit properties here; just copy from old
              ;; contents." `replace-region-contents' replaces the text and
              ;; nothing else; the two calls here are the same edit.
              (delete-region (point) (+ (point) (string-length val)))
              (insert last-abbrev-text)
              (goto-char (+ (point) (string-length last-abbrev-text)))
              (set! last-abbrev-text #f))))))

    ;;----------------------------------------------------------------
    ;; Abbrev mode
    ;;----------------------------------------------------------------

    (define (abbrev-mode-variable)
      ;; GNU Emacs's buffer-local `abbrev-mode' variable, which `abbrev.c'
      ;; declares (`DEFVAR_BOOL`): the mode's state is the variable.
      ;;--------------------------------------------------------------
      (and (buffer-local-value (current-buffer) 'abbrev-mode #f) #t))

    (define (set!abbrev-mode-variable! value)
      (set-buffer-local-value! (current-buffer) 'abbrev-mode
                               (and value #t)))

    (define-minor-mode abbrev-mode
      "Toggle Abbrev mode in the current buffer.

In Abbrev mode, inserting an abbreviation causes it to expand and
be replaced by its expansion."
      :variable (lambda () (abbrev-mode-variable))
      (lambda (v) (set!abbrev-mode-variable! v)))

    ;; Emacs's lighter entry lives in `bindings.el`'s alist
    ;; (`(abbrev-mode " Abbrev")`, `bindings.el:980`); this tree's alist
    ;; has it too (`subr.scm`'s `*minor-mode-alist*` default).

    ;;----------------------------------------------------------------
    ;; define-abbrev
    ;;----------------------------------------------------------------

    (define (define-abbrev table abbrev expansion . rest)
      ;; GNU Emacs's `define-abbrev' (`abbrev.el:618'): "Define ABBREV in
      ;; TABLE, to expand into EXPANSION and optionally call HOOK." REST is
      ;; HOOK and a property plist. An EXPANSION of nil undefines the
      ;; abbreviation (its record stays, with no expansion).
      ;;--------------------------------------------------------------
      (let* ((hook (and (pair? rest) (car rest)))
             (props (if (pair? rest) (cdr rest) '()))
             ;; "Old-style calling convention": the first prop is a number
             ;; (the count) rather than a keyword.
             (props (if (and (pair? props)
                             (or (not (car props)) (number? (car props))))
                        (append (list ':count (car props))
                                (if (and (pair? (cdr props)) (cadr props))
                                    (list ':system (cadr props))
                                    '()))
                        props))
             (props (if (let loop ((ps props) (found #f))
                          (cond ((or found (null? ps)) found)
                                ((null? (cdr ps)) found)
                                ((eq? (car ps) ':count) #t)
                                (else (loop (cddr ps) #f))))
                        props
                        (append props (list ':count 0))))
             (modiff (abbrev-table-get table ':abbrev-table-modiff))
             (props (append props (list ':abbrev-table-modiff modiff)))
             (system-flag (let ((e (memq ':system props))) (and e (cadr e))))
             (existing (hash-ref (abbrev-table-abbrevs table) abbrev #f)))
        ;; "Don't override a prior user-defined abbrev with a system abbrev,
        ;; unless system-flag is `force'."
        (unless (and system-flag
                     (not (eq? system-flag 'force))
                     existing
                     (abbrev-expansion-value existing)
                     (not (abbrev-get existing ':system)))
          (unless (or system-flag
                      (and existing
                           (equal? (abbrev-expansion-value existing) expansion)
                           (equal? (abbrev-hook existing) hook)))
            (set! abbrevs-changed #t))
          (let ((cell (or existing (%make-abbrev abbrev #f #f '())))
                (new-props '()))
            ;; The plist becomes the record's alist. `force' is stored as
            ;; `t', as Emacs stores it.
            (let loop ((ps props))
              (cond ((or (null? ps) (null? (cdr ps))) #f)
                    (else
                     (set! new-props
                           (cons (cons (car ps)
                                       (if (eq? (car ps) ':system)
                                           (if (eq? (cadr ps) 'force) #t (cadr ps))
                                           (cadr ps)))
                                 new-props))
                     (loop (cddr ps)))))
            (set!abbrev-expansion-value! cell expansion)
            (set!abbrev-hook! cell hook)
            (set!abbrev-props! cell new-props)
            (hash-set! (abbrev-table-abbrevs table) abbrev cell)
            (abbrev-table-put table ':abbrev-table-modiff (+ 1 modiff)))
          abbrev)))))
