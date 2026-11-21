(define-library (schemacs editor casetab)
  ;; A port of GNU Emacs's `src/casetab.c': case tables.
  ;;
  ;; **A case table** is a char-table whose purpose is `case-table'. It
  ;; maps each character to its lower-case equivalent, and has three
  ;; extra slots:
  ;;
  ;;   extra 0  UPCASE   - each non-upper-case character's upper case,
  ;;                       or nil (then deduced from the table);
  ;;   extra 1  CANON    - each character's canonical equivalent, or nil
  ;;                       (then deduced from the two tables);
  ;;   extra 2  EQV      - a cyclic permutation of each equivalence
  ;;                       class, or nil (then deduced from CANON).
  ;;
  ;; The regexp engine's `translate` is the buffer's CANON table
  ;; (`search.c` passes `BVAR (current_buffer, case_canon_table)` when
  ;; `case-fold-search` is non-nil), and CANON's extra slot 2 must be
  ;; the EQV table because `set_image_of_range` reads it from there
  ;; (`regex-emacs.c`).
  ;;
  ;; **Departures, both named**: `map_char_table` is not ported, so the
  ;; three builders walk the table's runs with
  ;; `char-table-ref-and-range` instead of `map_char_table` (the same
  ;; runs, the same order - `category.sld` does the same); and a
  ;; buffer's four slots are buffer-local values here, where Emacs has
  ;; four real `struct buffer` fields. `characters.el`'s extension of
  ;; the standard table beyond ASCII is not ported yet, so the table is
  ;; `init_casetab_once`'s ASCII table: a character with no entry
  ;; translates to itself, which is `char_table_translate`'s rule.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    (only (schemacs editor chartab)
          make-char-table char-table-p char-table-subtype
          char-table-ref char-table-set char-table-set-range
          char-table-ref-and-range
          char-table-extra-slot set-char-table-extra-slot
          copy-char-table max-char)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!)
    (only (schemacs editor intervals) put)
    (only (schemacs editor fns) copy-sequence)
    )

  (export
   case-table-p current-case-table standard-case-table
   set-case-table set-standard-case-table
   case-canon-table case-eqv-table upcase-table
   *ascii-downcase-table* *ascii-upcase-table*
   *ascii-canon-table* *ascii-eqv-table*)

  (begin

    (define (%nil? object)
      ;; Elisp's nil: `#f' or `()`. Scheme's `()` is true.
      ;;--------------------------------------------------------------
      (or (not object) (null? object)))

    (define (case-table-p object)
      ;; GNU Emacs's `case-table-p` (`casetab.c:35`): "Return t if
      ;; OBJECT is a case table." The C also checks the types of the
      ;; three extra slots; so does this.
      ;;--------------------------------------------------------------
      (and (char-table-p object)
           (eq? (char-table-subtype object) 'case-table)
           (let ((up (char-table-extra-slot object 0))
                 (canon (char-table-extra-slot object 1))
                 (eqv (char-table-extra-slot object 2)))
             (and (or (%nil? up) (char-table-p up))
                  (or (and (%nil? canon) (%nil? eqv))
                      (and (char-table-p canon)
                           (or (%nil? eqv) (char-table-p eqv))))))))

    (define (check-case-table object)
      ;; `check_case_table` (`casetab.c:58`).
      ;;--------------------------------------------------------------
      (if (case-table-p object)
          object
          (error "Wrong type argument: case-table-p" object)))

    (define (current-case-table)
      ;; GNU Emacs's `current-case-table` (`casetab.c:65`): "Return the
      ;; case table of the current buffer." - its DOWNCASE slot, whose
      ;; default is the standard table.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'downcase-table
                          *ascii-downcase-table*))

    (define (standard-case-table)
      ;; GNU Emacs's `standard-case-table` (`casetab.c:72`): "Return the
      ;; standard case table. This is the one used for new buffers."
      ;;--------------------------------------------------------------
      *ascii-downcase-table*)

    (define (case-canon-table)
      ;; The buffer's CANON slot - what `search.c` passes to the regexp
      ;; compiler as `translate` when `case-fold-search` is non-nil.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'case-canon-table
                          *ascii-canon-table*))

    (define (case-eqv-table)
      ;; The buffer's EQV slot. The engine reads it from CANON's extra
      ;; slot 2, where `%set-case-table` puts it.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'case-eqv-table
                          *ascii-eqv-table*))

    (define (upcase-table)
      ;; The buffer's UPCASE slot.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'upcase-table
                          *ascii-upcase-table*))

    (define (walk-table table proc)
      ;; Call PROC with (C . ELT) for every run of TABLE, C being a
      ;; character code or a cons of two - the arguments
      ;; `map_char_table` gives its function. The C's `map_char_table`
      ;; also consults the parent; a case table has none, so the runs
      ;; are the table's own.
      ;;--------------------------------------------------------------
      (let loop ((c 0))
        (when (<= c max-char)
          (let* ((from (list c))
                 (to (list c))
                 (val (char-table-ref-and-range table c from to)))
            (proc (if (= (car from) (car to))
                      (car from)
                      (cons (car from) (car to)))
                  val)
            (loop (+ (car to) 1))))))

    (define (range-bounds c)
      ;; C is a character code or a cons of two; answer the two.
      ;;--------------------------------------------------------------
      (if (pair? c) (values (car c) (cdr c)) (values c c)))

    (define (set-identity! table c elt)
      ;; `set_identity` (`casetab.c:191`): set TABLE's elements for C to
      ;; themselves, when ELT is a character.
      ;;--------------------------------------------------------------
      (when (integer? elt)
        (call-with-values (lambda () (range-bounds c))
          (lambda (from to)
            (let loop ((i from))
              (when (<= i to)
                (char-table-set table i i)
                (loop (+ i 1))))))))

    (define (shuffle! table c elt)
      ;; `shuffle` (`casetab.c:217`): permute TABLE (an identity
      ;; mapping) so that it has one cycle per equivalence class.
      ;;--------------------------------------------------------------
      (when (integer? elt)
        (call-with-values (lambda () (range-bounds c))
          (lambda (from to)
            (let loop ((i from))
              (when (<= i to)
                (let ((tem (char-table-ref table elt)))
                  (char-table-set table elt i)
                  (char-table-set table i tem))
                (loop (+ i 1))))))))

    (define (set-canon! case-table c elt)
      ;; `set_canon` (`casetab.c:176`): CANON's elements for C are
      ;; `DOWNCASE (UPCASE ELT)`, when ELT is a character.
      ;;--------------------------------------------------------------
      (when (integer? elt)
        (let ((up (char-table-extra-slot case-table 0))
              (canon (char-table-extra-slot case-table 1)))
          (let ((translated (char-table-ref case-table
                                            (char-table-ref up elt))))
            (call-with-values (lambda () (range-bounds c))
              (lambda (from to)
                (char-table-set-range canon from to translated)))))))

    (define (%set-case-table table standard)
      ;; `set_case_table` (`casetab.c:113`): check TABLE, fill in the
      ;; three extra slots that are nil, hang EQV from CANON's extra
      ;; slot 2, and make the table the current (or standard) one.
      ;;--------------------------------------------------------------
      (check-case-table table)
      (let* ((up (char-table-extra-slot table 0))
             (canon (char-table-extra-slot table 1))
             (eqv (char-table-extra-slot table 2)))
        (when (%nil? up)
          (set! up (make-char-table 'case-table #f))
          (walk-table table (lambda (c elt) (set-identity! up c elt)))
          (walk-table table (lambda (c elt) (shuffle! up c elt)))
          (set-char-table-extra-slot table 0 up))
        (when (%nil? canon)
          (set! canon (make-char-table 'case-table #f))
          (set-char-table-extra-slot table 1 canon)
          (walk-table table (lambda (c elt) (set-canon! table c elt))))
        (when (%nil? eqv)
          (set! eqv (make-char-table 'case-table #f))
          (walk-table canon (lambda (c elt) (set-identity! eqv c elt)))
          (walk-table canon (lambda (c elt) (shuffle! eqv c elt)))
          (set-char-table-extra-slot table 2 eqv))
        ;; "This is so set_image_of_range_1 in regex-emacs.c can find
        ;; the EQV table." (`casetab.c:147')
        (set-char-table-extra-slot canon 2 eqv)
        (if standard
            (begin
              (set! *ascii-downcase-table* table)
              (set! *ascii-upcase-table* up)
              (set! *ascii-canon-table* canon)
              (set! *ascii-eqv-table* eqv))
            (let ((buffer (current-buffer)))
              (set-buffer-local-value! buffer 'downcase-table table)
              (set-buffer-local-value! buffer 'upcase-table up)
              (set-buffer-local-value! buffer 'case-canon-table canon)
              (set-buffer-local-value! buffer 'case-eqv-table eqv)))
        table))

    (define (set-case-table table)
      ;; GNU Emacs's `set-case-table` (`casetab.c:82`): "Select a new
      ;; case table for the current buffer. ..."
      ;;--------------------------------------------------------------
      (%set-case-table table #f))

    (define (set-standard-case-table table)
      ;; GNU Emacs's `set-standard-case-table` (`casetab.c:104`):
      ;; "Select a new standard case table for new buffers."
      ;;--------------------------------------------------------------
      (%set-case-table table #t))

    ;;----------------------------------------------------------------
    ;; `init_casetab_once` (`casetab.c:242`)
    ;;----------------------------------------------------------------

    (put 'case-table 'char-table-extra-slots 3)

    (define *ascii-downcase-table* #f)
    (define *ascii-upcase-table* #f)
    (define *ascii-canon-table* #f)
    (define *ascii-eqv-table* #f)

    (let* ((down (make-char-table 'case-table #f))
           (up (make-char-table 'case-table #f))
           (eqv (make-char-table 'case-table #f)))
      (let loop ((i 0))
        (when (< i 128)
          (char-table-set down i (if (<= (char->integer #\A) i)
                                     (if (<= i (char->integer #\Z))
                                         (+ i 32)
                                         i)
                                     i))
          (loop (+ i 1))))
      (set-char-table-extra-slot down 1 (copy-sequence down))
      (let loop ((i 0))
        (when (< i 128)
          (char-table-set up i (if (and (<= (char->integer #\a) i)
                                        (<= i (char->integer #\z)))
                                   (- i 32)
                                   i))
          (loop (+ i 1))))
      (set-char-table-extra-slot down 0 up)
      (let loop ((i 0))
        (when (< i 128)
          (char-table-set eqv i
                          (cond ((and (<= (char->integer #\A) i)
                                      (<= i (char->integer #\Z)))
                                 (+ i 32))
                                ((and (<= (char->integer #\a) i)
                                      (<= i (char->integer #\z)))
                                 (- i 32))
                                (else i)))
          (loop (+ i 1))))
      (set-char-table-extra-slot down 2 eqv)
      ;; "Fill in what isn't filled in." (`casetab.c:284')
      (%set-case-table down #t))

    ))
