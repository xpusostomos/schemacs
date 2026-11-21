(define-library (schemacs editor data)
  ;; This library mirrors GNU Emacs's `src/data.c', of which the piece
  ;; the mode machinery needs is `make-local-variable'.
  ;;
  ;; One thing about the model here has to be said, because it is what
  ;; the function means in this tree: Emacs keeps a *default* value for
  ;; a variable beside the buffer-local one, and `make-local-variable'
  ;; copies the default into the buffer so that later changes to the
  ;; default stop reaching it. A buffer's slots here hold only the local
  ;; values, and the default is the caller's - `buffer-local-value'
  ;; takes it as its third argument. So "the value it previously had" is
  ;; the default the caller names, and that is what is copied in.

  (import
    (scheme base)
    ;; The global value table is a Guile hash table, as the coding system
    ;; registry is - `hashq-get-handle` is the one that tells a stored
    ;; nil from an absent entry, which `hashq-ref` cannot.
    (only (guile) ash logand logior lognot logxor logcount
          hashq-get-handle hashq-set! make-hash-table)
    (only (schemacs editor buffer)
          buffer-local-value set-buffer-local-value! current-buffer)
    ;; `aref`'s char-table arm - `CHAR_TABLE_REF` (`char_table_ref`).
    (only (schemacs editor chartab) char-table? char-table-ref)
    )

  (export
   make-local-variable
   default-value set-default default-boundp
   keywordp
   aref
   ;; `alloc.c''s `make-bool-vector' and `bool-vector', and `data.c''s
   ;; predicates and bitwise operations. See "Bool vectors" below.
   make-bool-vector bool-vector bool-vector-p bool-vector?
   bool-vector-ref bool-vector-set!
   %bool-vector-length %bool-vector-bits %bool-vector-copy
   bool-vector-exclusive-or bool-vector-union bool-vector-intersection
   bool-vector-set-difference bool-vector-subsetp bool-vector-not
   bool-vector-count-population bool-vector-count-consecutive
   )

  (begin

    (define (keywordp object)
      ;; GNU Emacs's `keywordp' (`data.c:207'): "Return t if OBJECT is a
      ;; keyword. Keywords are symbols whose names start with `:' and do
      ;; not start with `::'."
      ;;
      ;; **This is how the tree spells `:version', `:type' and the other
      ;; keywords `define-icon' and `define-custom' read as data** - a
      ;; Scheme symbol whose name starts with a colon.
      ;;--------------------------------------------------------------
      (and (symbol? object)
           (let ((name (symbol->string object)))
             (and (> (string-length name) 1)
                  (char=? #\: (string-ref name 0))
                  (not (char=? #\: (string-ref name 1)))))))

    (define (make-local-variable key . args)
      ;; GNU Emacs's `make-local-variable' (`data.c':2245): "Make
      ;; VARIABLE have a separate value in the current buffer. Other
      ;; buffers will continue to share a common default value. (The
      ;; buffer-local value of VARIABLE starts out as the same value
      ;; VARIABLE previously had.) ... Return VARIABLE."
      ;;
      ;; KEY is the variable - a symbol for a ported Elisp variable, as
      ;; everything else in this tree's buffer-local store is. The
      ;; optional argument after it is the default to copy in, and the
      ;; one after that the buffer, which is the current one by default.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? args) (car args) #f))
             (buffer (if (and (pair? args) (pair? (cdr args)))
                         (cadr args)
                         (current-buffer))))
        (set-buffer-local-value! buffer key
                                 (buffer-local-value buffer key default))
        key))

    (define *default-values* (make-hash-table 64))
    ;; ^ The global value of every variable a ported Elisp gives one - GNU
    ;; Emacs's symbol value cell, as much of it as a tree with no obarray
    ;; can have. A *symbol* keys it, because that is what Emacs's `setq`
    ;; on an undeclared variable keys the same cell by, and the
    ;; process-global table is a plain define by the convention (a
    ;; registry, not a dynamically bound value).
    ;;
    ;; It exists because a *global* minor mode's variable is not
    ;; per-buffer: `define-minor-mode`'s `:global` sets the default and
    ;; reads `default-value`, which is what tells one shared value from
    ;; a slot in each buffer's own table (`buffer-local-value`).

    (define (default-value symbol . args)
      ;; GNU Emacs's `default-value` (`data.c:2198`): "Return the default
      ;; value of SYMBOL. This is the value that is seen in buffers that
      ;; do not have their own values for this variable."
      ;;
      ;; **The optional argument is this tree's**, and it is the same one
      ;; `buffer-local-value` takes: the answer for a symbol that has no
      ;; default yet. Emacs signals `void-variable` there, which needs a
      ;; variable registry to name the symbol in the message; a caller
      ;; that has a default to offer - which is every caller here - gets
      ;; it, and the difference is named rather than faked.
      ;;--------------------------------------------------------------
      (let ((entry (hashq-get-handle *default-values* symbol)))
        (cond (entry (cdr entry))
              ((pair? args) (car args))
              (else #f))))

    (define (set-default symbol value)
      ;; GNU Emacs's `set-default` (`data.c:2213`): "Set the default
      ;; value of SYMBOL to be VALUE. ... This is the value seen in
      ;; buffers that do not have their own values for this variable."
      ;; It answers VALUE.
      ;;
      ;; A buffer's own value is left alone, as the C leaves it - the
      ;; default is what a buffer without a local value reads
      ;; (`buffer-local-value`'s third argument, at every call site).
      ;;--------------------------------------------------------------
      (hashq-set! *default-values* symbol value))

    (define (default-boundp symbol)
      ;; GNU Emacs's `default-boundp` (`data.c:2232`): "Return t if
      ;; SYMBOL has a non-void default value. ... A variable may have a
      ;; buffer-local value in a buffer, and a different default value."
      ;;--------------------------------------------------------------
      (and (hashq-get-handle *default-values* symbol) #t))

    (define (aref array idx)
      ;; GNU Emacs's `aref' (`data.c:2568`): "Return the element of
      ;; ARRAY at index IDX. ARRAY may be a vector, a string, a
      ;; char-table, a bool-vector, a record, or a byte-code object.
      ;; IDX starts at 0."
      ;;
      ;; A string's element is its *character code* (`make_fixnum (c)'
      ;; in the C), not a Scheme character. Not carried: the record and
      ;; byte-code arms, because nothing here indexes a record with it -
      ;; they signal rather than returning a wrong slot.
      ;;--------------------------------------------------------------
      (cond
       ((string? array)
        (if (or (< idx 0) (>= idx (string-length array)))
            (error "Args out of range: ~s, ~s" array idx)
            (char->integer (string-ref array idx))))
       ((bool-vector? array)
        (if (or (< idx 0) (>= idx (%bool-vector-length array)))
            (error "Args out of range: ~s, ~s" array idx)
            (bool-vector-ref array idx)))
       ((char-table? array)
        (char-table-ref array idx))
       ((vector? array)
        (if (or (< idx 0) (>= idx (vector-length array)))
            (error "Args out of range: ~s, ~s" array idx)
            (vector-ref array idx)))
       (else
        (error "Wrong type argument: arrayp, ~s" array))))

    ;;----------------------------------------------------------------
    ;; Bool vectors
    ;;
    ;; `make-bool-vector' and `bool-vector' are `alloc.c''s
    ;; (`:2080', `:2093'); the predicate and the bitwise operations are
    ;; `data.c''s (`:454', `:3824'-`:3995'). They live here because the
    ;; tree has no `alloc.sld', the same placement `locate-file-internal'
    ;; takes in `fileio.sld'.
    ;;
    ;; Emacs's bool vector is a distinct Lisp object - a bit array with
    ;; `t' and `nil' elements - because `aref'/`aset'/`length' and a
    ;; dozen C callers (category sets among them) treat it as a
    ;; sequence. This is the same object: a record holding the bits as
    ;; one exact integer, bit I being element I, and the length. The
    ;; integer is a bignum once it passes the fixnum range, so the
    ;; representation does not bound the vector's size; the C's
    ;; `bits_word' machinery is an optimization this does not carry.
    ;;--------------------------------------------------------------
    (define-record-type <bool-vector>
      (make-bool-vector-raw bits length)
      bool-vector?
      (bits bool-vector-bits set-bool-vector-bits!)
      (length %bool-vector-length set-bool-vector-length!))

    (define (%nil? object)
      ;; Elisp's `nil' as this tree spells it: `#f' or the empty list.
      ;; Scheme's `'()` is *true*, so the C's `NILP` is this and not
      ;; `null?` - the file's oldest hazard.
      ;;--------------------------------------------------------------
      (or (not object) (null? object)))

    (define (bool-vector-p object)
      ;; GNU Emacs's `bool-vector-p' (`data.c:454'): "Return t if OBJECT
      ;; is a bool-vector." - `BOOL_VECTOR_P', which is the record
      ;; predicate. The Emacs name has the `-p'; the record's own
      ;; predicate keeps Scheme's `?'.
      ;;--------------------------------------------------------------
      (bool-vector? object))

    (define (make-bool-vector length init)
      ;; GNU Emacs's `make-bool-vector' (`alloc.c:2080'): "Return a new
      ;; bool-vector of length LENGTH, using INIT for each element.
      ;; LENGTH must be a number. INIT matters only in whether it is t
      ;; or nil."
      ;;--------------------------------------------------------------
      (unless (and (exact-integer? length) (>= length 0))
        (error "Wrong type argument: wholenump" length))
      (make-bool-vector-raw (if (%nil? init) 0 (- (ash 1 length) 1)) length))

    (define (bool-vector . objects)
      ;; GNU Emacs's `bool-vector' (`alloc.c:2093'): "Return a new
      ;; bool-vector with specified arguments as elements."
      ;;--------------------------------------------------------------
      (make-bool-vector (length objects) #t))

    (define (%bool-vector-check bv who)
      (unless (bool-vector? bv)
        (error "Wrong type argument: bool-vector-p" bv))
      bv)

    (define (bool-vector-ref bv index)
      ;; `bool_vector_ref' (`data.c'): element INDEX as `t' or `nil'.
      ;; The C's `aref' calls it; the range check is `aref''s
      ;; (`data.c:2594').
      ;;--------------------------------------------------------------
      (%bool-vector-check bv 'aref)
      (unless (and (exact-integer? index)
                   (>= index 0)
                   (< index (%bool-vector-length bv)))
        (error "Args out of range" bv index))
      (not (zero? (logand (bool-vector-bits bv) (ash 1 index)))))

    (define (bool-vector-set! bv index value)
      ;; `bool_vector_set' (`data.c'): store whether VALUE is non-nil.
      ;; Answers VALUE, as `aset' does.
      ;;--------------------------------------------------------------
      (%bool-vector-check bv 'aset)
      (unless (and (exact-integer? index)
                   (>= index 0)
                   (< index (%bool-vector-length bv)))
        (error "Args out of range" bv index))
      (let ((bit (ash 1 index)))
        (set-bool-vector-bits!
         bv (if (%nil? value)
                (logand (bool-vector-bits bv) (lognot bit))
                (logior (bool-vector-bits bv) bit))))
      value)

    (define (%bool-vector-copy bv)
      ;; `Fcopy_sequence''s bool-vector arm (`fns.c'): a new vector with
      ;; the same elements. `copy-sequence` uses this.
      ;;--------------------------------------------------------------
      (%bool-vector-check bv 'copy-sequence)
      (make-bool-vector-raw (bool-vector-bits bv)
                            (%bool-vector-length bv)))

    (define (%bool-vector-check-compatible a b dest)
      (%bool-vector-check a 'bool-vector)
      (%bool-vector-check b 'bool-vector)
      (unless (= (%bool-vector-length a) (%bool-vector-length b))
        (error "Wrong length argument" a b))
      (when dest
        (%bool-vector-check dest 'bool-vector)
        (unless (= (%bool-vector-length dest) (%bool-vector-length a))
          (error "Wrong length argument" a b dest))))

    (define (bool-vector-binop a b dest op)
      ;; `bool_vector_binop_driver' (`data.c:3719'), for the four
      ;; operations that take an optional destination: the result is
      ;; computed, stored into DEST when one is given, and the answer is
      ;; DEST if it had to change and nil otherwise; with no DEST a new
      ;; vector is made and answered.
      ;;
      ;; The C walks machine words and tests each before writing; an
      ;; integer operation cannot be tested word by word, but "changed"
      ;; is the same comparison of the whole bit pattern.
      ;;--------------------------------------------------------------
      (%bool-vector-check-compatible a b dest)
      (let* ((result (op (bool-vector-bits a) (bool-vector-bits b)
                         (%bool-vector-length a))))
        (if dest
            (if (= result (bool-vector-bits dest))
                #f
                (begin (set-bool-vector-bits! dest result) dest))
            (make-bool-vector-raw result (%bool-vector-length a)))))

    (define (bool-vector-exclusive-or a b . rest)
      ;; GNU Emacs's `bool-vector-exclusive-or' (`data.c:3824'):
      ;; "Return A ^ B, bitwise exclusive or. If optional third argument
      ;; C is given, store result into C. ..."
      ;;--------------------------------------------------------------
      (bool-vector-binop a b (if (pair? rest) (car rest) #f)
                         (lambda (x y n) (logxor x y))))

    (define (bool-vector-union a b . rest)
      ;; GNU Emacs's `bool-vector-union' (`data.c:3835').
      ;;--------------------------------------------------------------
      (bool-vector-binop a b (if (pair? rest) (car rest) #f)
                         (lambda (x y n) (logior x y))))

    (define (bool-vector-intersection a b . rest)
      ;; GNU Emacs's `bool-vector-intersection' (`data.c:3846').
      ;;--------------------------------------------------------------
      (bool-vector-binop a b (if (pair? rest) (car rest) #f)
                         (lambda (x y n) (logand x y))))

    (define (bool-vector-set-difference a b . rest)
      ;; GNU Emacs's `bool-vector-set-difference' (`data.c:3857'):
      ;; "Return A &~ B, set difference. ..."
      ;;--------------------------------------------------------------
      (bool-vector-binop a b (if (pair? rest) (car rest) #f)
                         (lambda (x y n) (logand x (lognot y)))))

    (define (bool-vector-subsetp a b)
      ;; GNU Emacs's `bool-vector-subsetp' (`data.c:3868'): "Return t if
      ;; every t value in A is also t in B, nil otherwise."
      ;;--------------------------------------------------------------
      (%bool-vector-check-compatible a b #f)
      (zero? (logand (bool-vector-bits a)
                     (lognot (bool-vector-bits b)))))

    (define (bool-vector-not a . rest)
      ;; GNU Emacs's `bool-vector-not' (`data.c:3877'): "Compute ~A,
      ;; set complement. If optional second argument B is given, store
      ;; result into B." The mask drops the bits past LENGTH, which the
      ;; C's spare mask does.
      ;;--------------------------------------------------------------
      (%bool-vector-check a 'bool-vector-not)
      (let* ((len (%bool-vector-length a))
             (mask (- (ash 1 len) 1))
             (result (logand mask (lognot (bool-vector-bits a)))))
        (if (pair? rest)
            (let ((b (car rest)))
              (%bool-vector-check b 'bool-vector-not)
              (unless (= (%bool-vector-length b) len)
                (error "Wrong length argument" a b))
              (set-bool-vector-bits! b result)
              b)
            (make-bool-vector-raw result len))))

    (define (bool-vector-count-population a)
      ;; GNU Emacs's `bool-vector-count-population' (`data.c:3918'):
      ;; "Count how many elements in A are t."
      ;;--------------------------------------------------------------
      (%bool-vector-check a 'bool-vector-count-population)
      (logcount (bool-vector-bits a)))

    (define (bool-vector-count-consecutive a b i)
      ;; GNU Emacs's `bool-vector-count-consecutive' (`data.c:3943'):
      ;; "Count how many consecutive elements in A equal B starting at
      ;; I." B non-nil counts t elements, nil counts nil elements. I may
      ;; be one past the end ("Allow one past the end for convenience").
      ;;--------------------------------------------------------------
      (%bool-vector-check a 'bool-vector-count-consecutive)
      (unless (and (exact-integer? i) (>= i 0)
                   (<= i (%bool-vector-length a)))
        (error "Args out of range" a i))
      (let ((wanted (not (%nil? b)))
            (len (%bool-vector-length a)))
        (let loop ((pos i) (count 0))
          (if (or (>= pos len)
                  (eq? (bool-vector-ref a pos) wanted))
              (if (>= pos len) count (loop (+ pos 1) (+ count 1)))
              count))))

    ))