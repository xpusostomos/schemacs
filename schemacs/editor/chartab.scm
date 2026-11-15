(define-library (schemacs editor chartab)
  ;; This library mirrors GNU Emacs's `src/chartab.c': char-tables.
  ;; A char-table is a vector-like object that maps every character code
  ;; - 0 to `MAX-CHAR' (`#x3FFFFF', 22 bits) - to a Lisp value, in a
  ;; four-level tree that only materialises the parts that differ.
  ;;
  ;; The tree is Emacs's shape exactly. `chartab-size' is the number of
  ;; slots in a table of each depth (64/16/32/128), `chartab-chars' the
  ;; number of characters each slot of that depth covers, and
  ;; `chartab-bits' the shift that finds the slot for a character. A
  ;; slot either holds a value for the whole block or a *sub-table* of
  ;; the next depth; `MAKE-SUB-CHAR-TABLE' fills a new one with the value
  ;; the slot held, so splitting a block never changes its answers.
  ;;
  ;; **Where the C has a `struct Lisp_Char_Table' and macros, this has
  ;; records whose fields are those slots in the C's order**: `parent',
  ;; `purpose', `ascii', `default', `contents[64]' and the extra slots.
  ;; `ascii' is not a field of the Lisp-visible object at all - it is
  ;; the C's cache of the value for characters 0..127, which
  ;; `char_table_ascii' reads out of the three first-slots and
  ;; `char_table_set' refreshes whenever an ASCII character is set. It
  ;; is kept because `char_table_ref' uses it on every ASCII lookup,
  ;; which for a syntax table is nearly every lookup.
  ;;
  ;; **nil.** The C's `NILP (val)' - "no value stored here, ask the
  ;; parent" - is `%nil?' here: `#f' or the empty list, which are the
  ;; two things Elisp's nil is in this tree.
  ;;
  ;; Not carried, each named rather than faked:
  ;;
  ;;   * **Unicode property tables** - `unicode-property-table-internal',
  ;;     `get-unicode-property-internal', `put-unicode-property-internal',
  ;;     the compressed-string form (`UNIPROP_COMPRESSED_FORM_P') and the
  ;;     decoder/encoder tables. They are how `char-code-property-table'
  ;;     and the `unicore' data are loaded, and nothing here reads a
  ;;     Unicode property yet.
  ;;   * **`map-char-table'** - it needs `map_char_table''s recursion
  ;;     plus the charset-valued callback half, and its callers are the
  ;;     `describe-*' commands and the uniprop loader.
  ;;   * **`optimize-char-table'** is here, because it is small and is
  ;;     the one remaining DEFUN that only walks the tree.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    ;; `(get purpose 'char-table-extra-slots)' - `fns.c''s `Fget', which
    ;; lives in `intervals.sld' until the elisp layer has an `fns.sld' of
    ;; its own (see its comment).
    (only (schemacs editor intervals) get)
    ;; `ash', which `(scheme base)' does not export - it is `(guile)''s,
    ;; and `charset.sld' imports it the same way.
    (only (guile) ash))

  (export
   ;; the C's DEFUNs
   make-char-table char-table-p char-table-subtype
   char-table-parent set-char-table-parent
   char-table-extra-slot set-char-table-extra-slot
   char-table-range set-char-table-range
   optimize-char-table
   ;; the C's internal functions, which `syntax.sld' is the caller of
   char-table-ref char-table-set
   char-table-ref-and-range char-table-set-range
   ;; the tree's own names, for code that has to walk it
   char-table-default
   ;; constants
   max-char)

  (begin

    ;; `MAX_CHAR' (`character.h'): the largest character code a
    ;; char-table can hold - `(1- (ash 1 22))'.
    (define max-char #x3FFFFF)

    ;; `chartab_size' / `chartab_chars' / `chartab_bits'
    ;; (`chartab.c:31-51'). The shifts follow from the sizes the C
    ;; states in its first comment: "64/16/32/128".
    (define %chartab-size (vector 64 16 32 128))
    (define %chartab-chars (vector 65536 4096 128 1))
    (define %chartab-bits (vector 16 12 7 0))

    (define (%chartab-idx c depth min-char)
      ;; `CHARTAB_IDX' (`chartab.c:53'): the slot of a table of DEPTH
      ;; that holds character C, whose blocks start at MIN-CHAR.
      ;;--------------------------------------------------------------
      (ash (- c min-char) (- (vector-ref %chartab-bits depth))))

    ;; `struct Lisp_Sub_Char_Table' (`lisp.h').
    (define-record-type <sub-char-table>
      (%make-sub-char-table depth min-char contents)
      sub-char-table?
      (depth sub-char-table-depth)
      (min-char sub-char-table-min-char)
      (contents sub-char-table-contents))

    ;; `struct Lisp_Char_Table' (`lisp.h'), fields in the C's order.
    (define-record-type <char-table>
      (%make-char-table parent purpose ascii default contents extras)
      char-table?
      (parent %char-table-parent set!%char-table-parent!)
      (purpose %char-table-purpose)
      (ascii %char-table-ascii set!%char-table-ascii!)
      (default %char-table-default set!%char-table-default!)
      (contents %char-table-contents)
      (extras %char-table-extras))

    (define (%nil? v)
      ;; The C's `NILP': no value stored here. Elisp's nil is `#f' or the
      ;; empty list in this tree, so both answer true.
      ;;--------------------------------------------------------------
      (or (not v) (null? v)))

    (define (char-table-p obj)
      ;; GNU Emacs's `char-table-p' (`chartab.c', via
      ;; `CHAR_TABLE_P'): "Return t if OBJECT is a char-table."
      ;;--------------------------------------------------------------
      (char-table? obj))

    (define (make-char-table purpose . rest)
      ;; GNU Emacs's `make-char-table' (`chartab.c:104'): "Return a newly
      ;; created char-table, with purpose PURPOSE. Each element is
      ;; initialized to INIT, which defaults to nil."
      ;;
      ;; The C makes a vector of `CHAR_TABLE_STANDARD_SLOTS + n_extras'
      ;; filled with INIT - so *every* slot, including the default and
      ;; the contents, starts as INIT - then sets only parent and
      ;; purpose. It is copied as it stands.
      ;;--------------------------------------------------------------
      (if (not (symbol? purpose))
          (error "Wrong type argument: symbolp" purpose))
      (let* ((init (if (pair? rest) (car rest) #f))
             (n (get purpose 'char-table-extra-slots))
             (n-extras (cond ((not n) 0)
                             ((integer? n) n)
                             (else (error "Wrong type argument: fixnatnump" n)))))
        (%make-char-table #f purpose init init
                          (make-vector (vector-ref %chartab-size 0) init)
                          (make-vector n-extras init))))

    (define (char-table-subtype char-table)
      ;; GNU Emacs's `char-table-subtype' (`chartab.c:499'): "Return the
      ;; subtype of char-table CHAR-TABLE. The value is a symbol."
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (%char-table-purpose char-table))

    (define (char-table-parent char-table)
      ;; GNU Emacs's `char-table-parent' (`chartab.c:510'): "Return the
      ;; parent char-table of CHAR-TABLE." A nil value for a character
      ;; is inherited from the parent, and from its parent in turn.
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (%char-table-parent char-table))

    (define (set-char-table-parent char-table parent)
      ;; GNU Emacs's `set-char-table-parent' (`chartab.c:524'): "Set the
      ;; parent char-table of CHAR-TABLE to PARENT. Return PARENT."
      ;;
      ;; The walk that refuses a cycle is the C's, message and all
      ;; (including its spelling of "chartable").
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (when parent
        (if (not (char-table? parent))
            (error "Wrong type argument: char-table-p" parent))
        (let loop ((t parent))
          (when t
            (if (eq? t char-table)
                (error "Attempt to make a chartable be its own parent"))
            (loop (%char-table-parent t)))))
      (set!%char-table-parent! char-table parent)
      parent)

    (define (char-table-extra-slot char-table n)
      ;; GNU Emacs's `char-table-extra-slot' (`chartab.c:548'): "Return
      ;; the value of CHAR-TABLE's extra-slot number N."
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (let ((extras (%char-table-extras char-table)))
        (if (or (not (integer? n)) (< n 0) (>= n (vector-length extras)))
            (error "Args out of range" char-table n))
        (vector-ref extras n)))

    (define (set-char-table-extra-slot char-table n value)
      ;; GNU Emacs's `set-char-table-extra-slot' (`chartab.c:562'):
      ;; "Set CHAR-TABLE's extra-slot number N to VALUE."
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (let ((extras (%char-table-extras char-table)))
        (if (or (not (integer? n)) (< n 0) (>= n (vector-length extras)))
            (error "Args out of range" char-table n))
        (vector-set! extras n value)
        value))

    (define (char-table-default char-table)
      ;; The C's `XCHAR_TABLE (table)->defalt' - the value `nil' falls
      ;; back to. It has no Lisp name; `char-table-range' with a nil
      ;; RANGE is how Elisp reads it. Exported for the syntax table's
      ;; own fast paths, which read it directly as the C's macros do.
      ;;--------------------------------------------------------------
      (%char-table-default char-table))

    (define (make-sub-char-table depth min-char default)
      ;; `make_sub_char_table' (`chartab.c:138'): a table of DEPTH whose
      ;; every slot holds DEFAULT.
      ;;--------------------------------------------------------------
      (%make-sub-char-table depth min-char
                            (make-vector (vector-ref %chartab-size depth)
                                         default)))

    (define (char-table-ascii table)
      ;; `char_table_ascii' (`chartab.c:149'): the cached value for the
      ;; ASCII block, found by following the first slot down to the
      ;; depth-2 table that covers 0..127 exactly.
      ;;--------------------------------------------------------------
      (let ((sub (vector-ref (%char-table-contents table) 0)))
        (if (not (sub-char-table? sub))
            sub
            (let ((sub2 (vector-ref (sub-char-table-contents sub) 0)))
              (if (not (sub-char-table? sub2))
                  sub2
                  (vector-ref (sub-char-table-contents sub2) 0))))))

    (define (sub-char-table-ref table c)
      ;; `sub_char_table_ref' (`chartab.c:210').
      ;;--------------------------------------------------------------
      (let* ((depth (sub-char-table-depth table))
             (idx (%chartab-idx c depth (sub-char-table-min-char table)))
             (val (vector-ref (sub-char-table-contents table) idx)))
        (if (sub-char-table? val)
            (sub-char-table-ref val c)
            val)))

    (define (char-table-ref table c)
      ;; `char_table_ref' (`chartab.c:225'). A nil value falls through to
      ;; the table's default, and then to its parent's answer.
      ;;--------------------------------------------------------------
      (let ((val
             (if (< c 128)
                 (let ((v (%char-table-ascii table)))
                   (if (sub-char-table? v)
                       (vector-ref (sub-char-table-contents v) c)
                       v))
                 (let ((v (vector-ref (%char-table-contents table)
                                      (%chartab-idx c 0 0))))
                   (if (sub-char-table? v)
                       (sub-char-table-ref v c)
                       v)))))
        (if (%nil? val)
            (let ((default (%char-table-default table)))
              (if (and (%nil? default) (%char-table-parent table))
                  (char-table-ref (%char-table-parent table) c)
                  default))
            val)))

    (define (char-table-ref-simple table idx c from to default is-subtable)
      ;; `char_table_ref_simple' (`chartab.c:252'). FROM and TO are a
      ;; cons cell the caller owns: the answer narrows it to the run of
      ;; characters around C with the same value.
      ;;--------------------------------------------------------------
      (let* ((val (if is-subtable
                      (vector-ref (sub-char-table-contents table) idx)
                      (vector-ref (%char-table-contents table) idx)))
             (val (if (sub-char-table? val)
                      (sub-char-table-ref-and-range val c from to default)
                      (if (%nil? val) default val))))
        val))

    (define (sub-char-table-ref-and-range table c from to default)
      ;; `sub_char_table_ref_and_range' (`chartab.c:269'). FROM and TO
      ;; are cells holding the range's endpoints, as the C's int* are;
      ;; the walks below narrow them to the run around C that shares the
      ;; value.
      ;;--------------------------------------------------------------
      (let* ((depth (sub-char-table-depth table))
             (min-char (sub-char-table-min-char table))
             (chartab-idx (%chartab-idx c depth min-char))
             (chars (vector-ref %chartab-chars depth))
             (val (char-table-ref-simple table chartab-idx c from to
                                         default #t)))
        (let loop ((idx chartab-idx))
          (when (and (> idx 0)
                     (< (car from) (+ min-char (* idx chars))))
            (let* ((c2 (- (+ min-char (* idx chars)) 1))
                   (this (char-table-ref-simple table (- idx 1) c2 from to
                                                default #t)))
              (if (not (eq? this val))
                  (set-car! from (+ c2 1))
                  (loop (- idx 1))))))
        (let loop ((idx chartab-idx))
          (let ((c2 (+ (* (+ idx 1) chars) min-char)))
            (when (and (< (* (+ idx 1) chars)
                          (vector-ref %chartab-chars (- depth 1)))
                       (<= c2 (car to)))
              (let ((this (char-table-ref-simple table (+ idx 1) c2
                                                 from to default #t)))
                (if (not (eq? this val))
                    (set-car! to (- c2 1))
                    (loop (+ idx 1)))))))
        val))

    (define (char-table-ref-and-range table c from to)
      ;; `char_table_ref_and_range' (`chartab.c:320'): the value for C,
      ;; with FROM and TO narrowed to the run around it that shares the
      ;; value. Note it consults the *default* and not the parent: that
      ;; is the C's shape, and the parent is only asked by
      ;; `char-table-ref'.
      ;;--------------------------------------------------------------
      (when (< (car from) 0) (set-car! from 0))
      (when (< (car to) 0) (set-car! to max-char))
      (let* ((chartab-idx (%chartab-idx c 0 0))
             (chars (vector-ref %chartab-chars 0))
             (val (char-table-ref-simple table chartab-idx c from to
                                         (%char-table-default table) #f)))
        (let loop ((idx chartab-idx))
          (when (< (car from) (* idx chars))
            (let* ((c2 (- (* idx chars) 1))
                   (this (char-table-ref-simple table (- idx 1) c2 from to
                                                (%char-table-default table) #f)))
              (if (not (eq? this val))
                  (set-car! from (+ c2 1))
                  (loop (- idx 1))))))
        (let loop ((idx chartab-idx))
          (when (>= (car to) (* (+ idx 1) chars))
            (let* ((c2 (* (+ idx 1) chars))
                   (this (char-table-ref-simple table (+ idx 1) c2 from to
                                                (%char-table-default table) #f)))
              (if (not (eq? this val))
                  (set-car! to (- c2 1))
                  (loop (+ idx 1))))))
        val))

    (define (sub-char-table-set table c val)
      ;; `sub_char_table_set' (`chartab.c:370'). The C splits a slot
      ;; into a sub-table when a write goes through it, the sub-table
      ;; starting with the value the slot had - so no other character's
      ;; answer moves.
      ;;--------------------------------------------------------------
      (let* ((depth (sub-char-table-depth table))
             (min-char (sub-char-table-min-char table))
             (i (%chartab-idx c depth min-char))
             (contents (sub-char-table-contents table)))
        (if (= depth 3)
            (vector-set! contents i val)
            (let ((sub (vector-ref contents i)))
              (if (not (sub-char-table? sub))
                  (begin
                    (set! sub (make-sub-char-table
                               (+ depth 1)
                               (+ min-char (* i (vector-ref %chartab-chars depth)))
                               sub))
                    (vector-set! contents i sub)))
              (sub-char-table-set sub c val)))))

    (define (char-table-set table c val)
      ;; `char_table_set' (`chartab.c:399').
      ;;--------------------------------------------------------------
      (let ((ascii (%char-table-ascii table)))
        (if (and (< c 128) (sub-char-table? ascii))
            (vector-set! (sub-char-table-contents ascii) c val)
            (let* ((i (%chartab-idx c 0 0))
                   (contents (%char-table-contents table))
                   (sub (vector-ref contents i)))
              (if (not (sub-char-table? sub))
                  (begin
                    (set! sub (make-sub-char-table
                               1 (* i (vector-ref %chartab-chars 0)) sub))
                    (vector-set! contents i sub)))
              (sub-char-table-set sub c val)
              (when (< c 128)
                (set!%char-table-ascii! table (char-table-ascii table)))))))

    (define (sub-char-table-set-range table from to val)
      ;; `sub_char_table_set_range' (`chartab.c:424').
      ;;--------------------------------------------------------------
      (let* ((depth (sub-char-table-depth table))
             (min-char (sub-char-table-min-char table))
             (chars-in-block (vector-ref %chartab-chars depth))
             (lim (vector-ref %chartab-size depth))
             (from (if (< from min-char) min-char from))
             (contents (sub-char-table-contents table)))
        (let loop ((i (%chartab-idx from depth min-char))
                   (c (+ min-char (* chars-in-block
                                     (%chartab-idx from depth min-char)))))
          (when (and (< i lim) (<= c to))
            (if (and (<= from c) (<= (+ c chars-in-block -1) to))
                (vector-set! contents i val)
                (let ((sub (vector-ref contents i)))
                  (if (not (sub-char-table? sub))
                      (begin
                        (set! sub (make-sub-char-table (+ depth 1) c sub))
                        (vector-set! contents i sub)))
                  (sub-char-table-set-range sub from to val)))
            (loop (+ i 1) (+ c chars-in-block))))))

    (define (char-table-set-range table from to val)
      ;; `char_table_set_range' (`chartab.c:462').
      ;;--------------------------------------------------------------
      (if (= from to)
          (char-table-set table from val)
          (let* ((chars (vector-ref %chartab-chars 0))
                 (lim (%chartab-idx to 0 0))
                 (contents (%char-table-contents table)))
            (let loop ((i (%chartab-idx from 0 0)) (c (* (%chartab-idx from 0 0)
                                                        chars)))
              (when (and (<= i lim) (<= c to))
                (if (and (<= from c) (<= (+ c chars -1) to))
                    (vector-set! contents i val)
                    (let ((sub (vector-ref contents i)))
                      (if (not (sub-char-table? sub))
                          (begin
                            (set! sub (make-sub-char-table 1 (* i chars) sub))
                            (vector-set! contents i sub)))
                      (sub-char-table-set-range sub from to val)))
                (loop (+ i 1) (+ c chars))))
            (when (< from 128)
              (set!%char-table-ascii! table (char-table-ascii table))))))

    (define (char-table-range char-table range)
      ;; GNU Emacs's `char-table-range' (`chartab.c:578'): "Return the
      ;; value in CHAR-TABLE for a range of characters RANGE. RANGE
      ;; should be nil (for the default value), a cons of character
      ;; codes (for characters in the range), or a character code."
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (cond
       ((%nil? range) (%char-table-default char-table))
       ((integer? range) (char-table-ref char-table range))
       ((pair? range)
        (let ((from (car range)) (to (cdr range)))
          (if (or (not (integer? from)) (not (integer? to)))
              (error "Wrong type argument: characterp" range))
          ;; "If RANGE is a cons (FROM . TO), the function returns the
          ;; value for FROM" - the whole run is not needed here, so the
          ;; two cells start where the C's do and the walk's narrowing is
          ;; discarded.
          (char-table-ref-and-range char-table from
                                    (cons from #f) (cons to #f))))
       (else (error "Invalid RANGE argument to `char-table-range'"))))

    (define (set-char-table-range char-table range value)
      ;; GNU Emacs's `set-char-table-range' (`chartab.c:609'): "Set the
      ;; value in CHAR-TABLE for a range of characters RANGE to VALUE."
      ;; RANGE may also be t, which sets every character.
      ;;--------------------------------------------------------------
      (if (not (char-table? char-table))
          (error "Wrong type argument: char-table-p" char-table))
      (cond
       ((eq? range #t)
        (set!%char-table-ascii! char-table value)
        (let ((contents (%char-table-contents char-table)))
          (let loop ((i 0))
            (when (< i (vector-length contents))
              (vector-set! contents i value)
              (loop (+ i 1))))))
       ((%nil? range) (set!%char-table-default! char-table value))
       ((integer? range) (char-table-set char-table range value))
       ((pair? range)
        (let ((from (car range)) (to (cdr range)))
          (if (or (not (integer? from)) (not (integer? to)))
              (error "Wrong type argument: characterp" range))
          (char-table-set-range char-table from to value)))
       (else (error "Invalid RANGE argument to `set-char-table-range'")))
      value)

    (define (optimize-sub-char-table table test)
      ;; `optimize_sub_char_table' (`chartab.c:643'): a slot whose whole
      ;; block has one value is collapsed from a sub-table back to the
      ;; value. TEST is the comparison: nil is `equal', `eq' is the
      ;; identity test, anything else is called.
      ;;--------------------------------------------------------------
      (let* ((depth (sub-char-table-depth table))
             (contents (sub-char-table-contents table))
             (elt (vector-ref contents 0)))
        (when (sub-char-table? elt)
          (set! elt (optimize-sub-char-table elt test))
          (vector-set! contents 0 elt))
        (let loop ((i 1) (optimizable (not (sub-char-table? elt))))
          (if (or (not optimizable) (>= i (vector-ref %chartab-size depth)))
              (if optimizable elt table)
              (let ((this (vector-ref contents i)))
                (when (sub-char-table? this)
                  (set! this (optimize-sub-char-table this test))
                  (vector-set! contents i this))
                (loop (+ i 1)
                      (and optimizable
                           (cond ((%nil? test) (equal? this elt))
                                 ((eq? test 'eq) (eq? this elt))
                                 (else (test this elt))))))))))

    (define (optimize-char-table char-table . rest)
      ;; GNU Emacs's `optimize-char-table' (`chartab.c:676'):
      ;; "Optimize CHAR-TABLE. TEST is the comparison function used to
      ;; decide whether two entries are equivalent and can be merged."
      ;;--------------------------------------------------------------
      (let ((test (if (pair? rest) (car rest) #f)))
        (if (not (char-table? char-table))
            (error "Wrong type argument: char-table-p" char-table))
        (let ((contents (%char-table-contents char-table)))
          (let loop ((i 0))
            (when (< i (vector-length contents))
              (let ((elt (vector-ref contents i)))
                (when (sub-char-table? elt)
                  (vector-set! contents i (optimize-sub-char-table elt test))))
              (loop (+ i 1)))))
        (set!%char-table-ascii! char-table (char-table-ascii char-table))
        #f))

    ))
