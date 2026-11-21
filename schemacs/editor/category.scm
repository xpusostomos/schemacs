(define-library (schemacs editor category)
  ;; A port of GNU Emacs's `src/category.c' and `src/category.h': the
  ;; category, the category set and the category table.
  ;;
  ;; **A category** is a mnemonic character in ` ' (32) .. `~' (126),
  ;; so there are 95 of them. **A category set** is a bool vector of
  ;; length 128 with a `t' at the indexes of the categories in it; the
  ;; C's `MAKE_CATEGORY_SET'. **A category table** is a char-table
  ;; whose purpose is `category-table', whose default is an empty set,
  ;; whose extra slot 0 is a vector of 95 docstrings, and whose extra
  ;; slot 1 is - once a set has to be interned - a hash table of the
  ;; sets already made. This is the shape `category.h' describes, and
  ;; it is what the regexp engine reads for `\c'.
  ;;
  ;; The tree's char-tables are `chartab.sld''s, its bool vectors
  ;; `data.sld''s, and a buffer's category table is a buffer-local value
  ;; like every other per-buffer variable here (Emacs has a real
  ;; `category_table' field; this tree's buffer slots are one table, so
  ;; the field is the symbol `category-table' in that table).
  ;;
  ;; **Not carried**: the C's `hash_get_category_set` interning is
  ;; carried, but the C also makes the sets structurally shared so that
  ;; `eq` comparisons are cheap; this tree's interning does the same job
  ;; for the one thing the C uses it for - `modify-category-entry`
  ;; stores equal sets as one object. `map_char_table`'s recursion is
  ;; not ported; `copy-category-table` walks the table's runs with
  ;; `char-table-ref-and-range` instead, which is the same set of runs.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    (only (guile) make-hash-table hash-table? hash-ref hash-set! hashq-ref hashq-set!)
    ;; The char-table - `chartab.c''s.
    (only (schemacs editor chartab)
          make-char-table char-table-p char-table-subtype
          char-table-ref char-table-set
          char-table-ref-and-range char-table-set-range set-char-table-range
          char-table-default char-table-extra-slot
          set-char-table-extra-slot copy-char-table max-char)
    ;; The category set - `data.sld''s bool vectors.
    (only (schemacs editor data)
          make-bool-vector bool-vector? bool-vector-ref bool-vector-set!
          %bool-vector-copy %bool-vector-length)
    ;; A buffer's category table is a buffer-local value.
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!)
    ;; `put` is `fns.c`'s symbol property, which `make-char-table` reads
    ;; back through `get` for the extra-slot count; `copy-sequence` is
    ;; `fns.c`'s and copies the docstring vector.
    (only (schemacs editor intervals) put)
    (only (schemacs editor fns) copy-sequence)
    )

  (export
   make-category-set
   define-category category-docstring get-unused-category
   category-table-p category-table standard-category-table
   copy-category-table make-category-table set-category-table
   char-category-set category-set-mnemonics modify-category-entry
   ;; the C's `word_boundary_p', which the regexp engine's `\b' and
   ;; `\B' call for two word-constituent characters
   word-boundary-p
   ;; the two user options `syms_of_category' defines
   *word-combining-categories* *word-separating-categories*
   ;; the script table `word_boundary_p' reads; `characters.el` fills
   ;; it, and until that file is ported it has one script for everything
   char-script-table)

  (begin

    ;;----------------------------------------------------------------
    ;; Category set staff
    ;;----------------------------------------------------------------

    (define (%nil? object)
      ;; Elisp's nil as this tree spells it: `#f' or `()`. Scheme's
      ;; `()` is *true*, so the C's `NILP` is this and not `null?`.
      ;;--------------------------------------------------------------
      (or (not object) (null? object)))

    (define (%char-code object who)
      ;; A character argument: Emacs's DEFUNs take an integer code
      ;; point (`?a' is 97), and a Scheme caller may hand the character
      ;; itself. Both answer the code point; anything else is the C's
      ;; `CHECK_CHARACTER' failure.
      ;;--------------------------------------------------------------
      (cond ((char? object) (char->integer object))
            ((and (exact-integer? object)
                  (>= object 0)
                  (<= object max-char))
             object)
            (else (error "Wrong type argument: characterp" object))))

    (define (%check-category category)
      ;; `CHECK_CATEGORY` (`category.h`): a category is a printable
      ;; ASCII character, 32 through 126.
      ;;--------------------------------------------------------------
      (let ((code (%char-code category 'category)))
        (unless (<= 32 code 126)
          (error "Wrong type argument: categoryp" category))
        code))

    (define (%check-category-set set)
      ;; `CHECK_CATEGORY_SET` (`category.h`): a bool vector of length
      ;; 128. The C checks the size because a category set is exactly
      ;; one 128-bit set; so does this.
      ;;--------------------------------------------------------------
      (unless (and (bool-vector? set) (= 128 (%bool-vector-length set)))
        (error "Wrong type argument: categorysetp" set))
      set)

    (define (make-category-set categories)
      ;; GNU Emacs's `make-category-set` (`category.c:72`): "Return a
      ;; newly created category-set which contains CATEGORIES.
      ;; CATEGORIES is a string of category mnemonics. The value is a
      ;; bool-vector which has t at the indices corresponding to those
      ;; categories."
      ;;
      ;; The C refuses a multibyte string outright. A Scheme string is
      ;; always made of characters, so the equivalent test is on the
      ;; contents: a mnemonic outside ASCII makes it the multibyte case
      ;; the C refuses, with the C's message.
      ;;--------------------------------------------------------------
      (unless (string? categories)
        (error "Wrong type argument: stringp" categories))
      (let ((set (make-bool-vector 128 #f)))
        (let loop ((i 0))
          (when (< i (string-length categories))
            (let ((c (char->integer (string-ref categories i))))
              (when (> c 127)
                (error "Multibyte string in `make-category-set'"))
              (bool-vector-set! set (%check-category c) #t))
            (loop (+ i 1))))
        set))

    (define (set-category-set! category-set category value)
      ;; `set_category_set` (`category.c:66`): "Make CATEGORY_SET
      ;; include (if VAL) or exclude (if !VAL) CATEGORY."
      ;;--------------------------------------------------------------
      (bool-vector-set! category-set category value))

    (define (hash-get-category-set table category-set)
      ;; `hash_get_category_set` (`category.c:48`): intern CATEGORY-SET
      ;; in TABLE's extra slot 1, answering the set already there when
      ;; one is equal to it. The C's table is `equal`-keyed; Guile's
      ;; default hash table is too, and a bool-vector's `equal?` is its
      ;; two fields.
      ;;--------------------------------------------------------------
      (let ((h (char-table-extra-slot table 1)))
        (unless (hash-table? h)
          (set! h (make-hash-table 32))
          (set-char-table-extra-slot table 1 h))
        (let ((seen (hash-ref h category-set #f)))
          (if seen
              seen
              (begin (hash-set! h category-set category-set)
                     category-set)))))

    ;;----------------------------------------------------------------
    ;; Category staff
    ;;----------------------------------------------------------------

    (define (check-category-table table)
      ;; `check_category_table` (`category.c:176`): nil means the
      ;; current buffer's table; anything else must be one.
      ;;--------------------------------------------------------------
      (cond
       ((%nil? table) (category-table))
       ((category-table-p table) table)
       (else (error "Wrong type argument: category-table-p" table))))

    (define (define-category category docstring . rest)
      ;; GNU Emacs's `define-category` (`category.c:105`): "Define
      ;; CATEGORY as a category which is described by DOCSTRING. ...
      ;; The category is defined only in category table TABLE, which
      ;; defaults to the current buffer's category table."
      ;;--------------------------------------------------------------
      (let* ((code (%check-category category))
             (table (check-category-table (if (pair? rest) (car rest) #f)))
             (docs (char-table-extra-slot table 0)))
        (unless (string? docstring)
          (error "Wrong type argument: stringp" docstring))
        (unless (%nil? (vector-ref docs (- code 32)))
          (error "Category `~a' is already defined" (integer->char code)))
        (vector-set! docs (- code 32) docstring)
        #f))

    (define (category-docstring category . rest)
      ;; GNU Emacs's `category-docstring` (`category.c:126`): "Return
      ;; the documentation string of CATEGORY, as defined in TABLE."
      ;;--------------------------------------------------------------
      (let* ((code (%check-category category))
             (table (check-category-table (if (pair? rest) (car rest) #f))))
        (vector-ref (char-table-extra-slot table 0) (- code 32))))

    (define (get-unused-category . rest)
      ;; GNU Emacs's `get-unused-category` (`category.c:138`): "Return
      ;; a category which is not yet defined in TABLE. If no category
      ;; remains available, return nil."
      ;;--------------------------------------------------------------
      (let* ((table (check-category-table (if (pair? rest) (car rest) #f)))
             (docs (char-table-extra-slot table 0)))
        (let loop ((code 32))
          (cond ((> code 126) #f)
                ((%nil? (vector-ref docs (- code 32))) code)
                (else (loop (+ code 1)))))))

    ;;----------------------------------------------------------------
    ;; Category-table staff
    ;;----------------------------------------------------------------

    (define (category-table-p object)
      ;; GNU Emacs's `category-table-p` (`category.c:160`): "Return t if
      ;; ARG is a category table." The C's test is a char-table whose
      ;; purpose is `category-table`.
      ;;--------------------------------------------------------------
      (and (char-table-p object)
           (eq? (char-table-subtype object) 'category-table)))

    (define (category-table)
      ;; GNU Emacs's `category-table` (`category.c:184`): "Return the
      ;; current category table. This is the one specified by the
      ;; current buffer." - a per-buffer slot whose default is the
      ;; standard table.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'category-table
                          *standard-category-table*))

    (define (standard-category-table)
      ;; GNU Emacs's `standard-category-table` (`category.c:192`):
      ;; "Return the standard category table. This is the one used for
      ;; new buffers."
      ;;--------------------------------------------------------------
      *standard-category-table*)

    (define (copy-category-entry table c val)
      ;; `copy_category_entry` (`category.c:202`): copy one value (a
      ;; category set) and store it over the range C, which is a cons
      ;; of two character codes or one character.
      ;;--------------------------------------------------------------
      (let ((val (copy-sequence val)))
        (if (pair? c)
            (char-table-set-range table (car c) (cdr c) val)
            (char-table-set table c val))))

    (define (copy-category-table . rest)
      ;; GNU Emacs's `copy-category-table` (`category.c:217` and the
      ;; DEFUN at `:232`): "Construct a new category table and return
      ;; it. It is a copy of the TABLE, which defaults to the standard
      ;; category table." No contents are shared: every category set is
      ;; copied.
      ;;
      ;; The C walks the table with `map_char_table`; this walks its
      ;; runs with `char-table-ref-and-range`, which visits the same
      ;; runs in the same order.
      ;;--------------------------------------------------------------
      (let* ((table (if (pair? rest)
                        (check-category-table (car rest))
                        *standard-category-table*))
             (new (copy-char-table table)))
        (when (bool-vector? (char-table-default table))
          (set-char-table-range new #f
                                (%bool-vector-copy (char-table-default table))))
        (when (vector? (char-table-extra-slot table 0))
          (set-char-table-extra-slot
           new 0 (copy-sequence (char-table-extra-slot table 0))))
        (let loop ((c 0))
          (if (> c max-char)
              new
              (let* ((from (list c))
                     (to (list c))
                     (val (char-table-ref-and-range new c from to)))
                (when (bool-vector? val)
                  (char-table-set-range new (car from) (car to)
                                        (%bool-vector-copy val)))
                (loop (+ (car to) 1)))))))

    (define (make-category-table)
      ;; GNU Emacs's `make-category-table` (`category.c:246`):
      ;; "Construct a new and empty category table and return it." The
      ;; C fills the default and every top-level slot with distinct
      ;; empty sets; this makes them with one empty set, which is
      ;; observably the same because `modify-category-entry` copies a
      ;; set before changing it.
      ;;--------------------------------------------------------------
      (let ((table (make-char-table 'category-table
                                    (make-category-set ""))))
        (set-char-table-extra-slot table 0 (make-vector 95 #f))
        table))

    (define (set-category-table table)
      ;; GNU Emacs's `set-category-table` (`category.c:262`): "Specify
      ;; TABLE as the category table for the current buffer. Return
      ;; TABLE."
      ;;--------------------------------------------------------------
      (set! table (check-category-table table))
      (set-buffer-local-value! (current-buffer) 'category-table table)
      table)

    (define (char-category-set character)
      ;; GNU Emacs's `char-category-set` (`category.c:283`): "Return
      ;; the category set of CHAR." The C's `CATEGORY_SET` reads the
      ;; current buffer's table; a character with no stored value gets
      ;; the table's default, which `make-category-table` makes an
      ;; empty set.
      ;;--------------------------------------------------------------
      (let ((code (%char-code character 'char-category-set)))
        (char-table-ref (category-table) code)))

    (define (category-set-mnemonics category-set)
      ;; GNU Emacs's `category-set-mnemonics` (`category.c:292`):
      ;; "Return a string containing mnemonics of the categories in
      ;; CATEGORY-SET. ... The return value is a string containing
      ;; those same categories."
      ;;--------------------------------------------------------------
      (%check-category-set category-set)
      (let loop ((code 32) (acc '()))
        (if (> code 126)
            (list->string (reverse acc))
            (loop (+ code 1)
                  (if (bool-vector-ref category-set code)
                      (cons (integer->char code) acc)
                      acc)))))

    (define (modify-category-entry character category . rest)
      ;; GNU Emacs's `modify-category-entry` (`category.c:314`):
      ;; "Modify the category set of CHARACTER by adding CATEGORY to
      ;; it. ... If optional fourth argument RESET is non-nil, then
      ;; delete CATEGORY from the category set instead of adding it."
      ;;
      ;; CHARACTER is a character code or a cons of two - an inclusive
      ;; range. The C's loop walks the table's runs
      ;; (`char_table_ref_and_range`) and copies only a set that
      ;; changes.
      ;;--------------------------------------------------------------
      (let* ((start (if (pair? character)
                        (%char-code (car character) 'modify-category-entry)
                        (%char-code character 'modify-category-entry)))
             (end (if (pair? character)
                      (%char-code (cdr character) 'modify-category-entry)
                      start))
             (code (%check-category category))
             (table (check-category-table
                     (if (pair? rest) (car rest) #f)))
             (reset-arg (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest)
                            #f))
             ;; `set_value = NILP (reset)` (`category.c:352'): nil
             ;; RESET means add, non-nil means remove.
             (set-value (%nil? reset-arg)))
        (when (%nil? (vector-ref (char-table-extra-slot table 0)
                                 (- code 32)))
          (error "Undefined category: ~a" (integer->char code)))
        (let loop ((from start))
          (when (<= from end)
            (let* ((from-box (list from))
                   (to-box (list end))
                   (category-set (char-table-ref-and-range
                                  table from from-box to-box))
                   (to (car to-box)))
              ;; The C: change when `CATEGORY_MEMBER (...) != NILP
              ;; (reset)` - that is, when membership differs from the
              ;; value about to be stored.
              (when (not (eq? (bool-vector-ref category-set code)
                              set-value))
                (let ((copy (%bool-vector-copy category-set)))
                  (set-category-set! copy code set-value)
                  (char-table-set-range
                   table from to
                   (hash-get-category-set table copy))))
              (loop (+ to 1)))))
        #f))

    ;;----------------------------------------------------------------
    ;; Word boundaries
    ;;----------------------------------------------------------------

    (define (word-boundary-p c1 c2)
      ;; GNU Emacs's `word_boundary_p` (`category.c:376`): "Return true
      ;; if there is a word boundary between two word-constituent
      ;; characters C1 and C2 if they appear in this order."
      ;;
      ;; Two characters in the same script have no boundary unless
      ;; `word-separating-categories` names their categories; two in
      ;; different scripts have one unless
      ;; `word-combining-categories` does. The script table is
      ;; `characters.el`'s; until that file is ported every character
      ;; answers the same script, which is Emacs's answer for ASCII.
      ;;--------------------------------------------------------------
      (let* ((same-script?
              (eq? (char-table-ref char-script-table c1)
                   (char-table-ref char-script-table c2)))
             (tail (if same-script?
                       *word-separating-categories*
                       *word-combining-categories*))
             (default-result (if same-script? #f #t))
             (set1 (char-category-set c1))
             (set2 (char-category-set c2)))
        (if (or (%nil? set1) (%nil? set2))
            default-result
            (let loop ((rest tail))
              (cond
               ((%nil? rest) default-result)
               (else
                (let* ((elt (car rest))
                       (cat1 (and (pair? elt) (car elt)))
                       (cat2 (and (pair? elt) (cdr elt)))
                       (ok1 (or (%nil? cat1)
                                (and (<= 32 (%char-code cat1 'word-boundary) 126)
                                     (bool-vector-ref set1 (%char-code cat1 'word-boundary))
                                     (not (bool-vector-ref set2 (%char-code cat1 'word-boundary))))))
                       (ok2 (or (%nil? cat2)
                                (and (<= 32 (%char-code cat2 'word-boundary) 126)
                                     (not (bool-vector-ref set1 (%char-code cat2 'word-boundary)))
                                     (bool-vector-ref set2 (%char-code cat2 'word-boundary))))))
                  (if (and ok1 ok2)
                      (not default-result)
                      (loop (cdr rest))))))))))

    ;;----------------------------------------------------------------
    ;; `init_category_once` and `syms_of_category`
    ;;----------------------------------------------------------------

    (put 'category-table 'char-table-extra-slots 2)

    (define *standard-category-table*
      ;; `init_category_once` (`category.c:421`): the standard table,
      ;; whose default is an empty set and whose extra slot 0 is 95
      ;; docstrings (all nil).
      (let ((table (make-char-table 'category-table (make-category-set ""))))
        (set-char-table-extra-slot table 0 (make-vector 95 #f))
        table))

    (define char-script-table
      ;; `Vchar_script_table` (`category.c:383`, `characters.el`): a
      ;; char-table mapping each character to its script symbol. Not
      ;; filled until characters.el is ported; its default nil makes
      ;; every character the same script, which is what Emacs answers
      ;; for the ASCII repertoire the C mode uses.
      (make-char-table 'char-script-table #f))

    (define *word-combining-categories* #f)
    ;; ^ `word-combining-categories` (`category.c:442`): "List of pairs
    ;; (cons cells) of categories to determine word boundary." A
    ;; `defvar` - nothing `let`-binds it - so a plain variable, and the
    ;; self-assignment keeps a compiled read from folding it.
    (set! *word-combining-categories* *word-combining-categories*)

    (define *word-separating-categories* #f)
    ;; ^ `word-separating-categories` (`category.c:487`). As above.
    (set! *word-separating-categories* *word-separating-categories*)

    ))
