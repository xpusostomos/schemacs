(define-library (schemacs regex-emacs)
  ;; A port of GNU Emacs's `src/regex-emacs.c' - the Emacs regular
  ;; expression compiler and matcher.
  ;;
  ;; **Status.** The engine is complete and in use: the compiler
  ;; (`regex_compile`), the fastmap, `re_search` and the matcher,
  ;; including Emacs 31's memoization. `(schemacs search)`
  ;; imports it and is `search.c` around it - the `regexp_cache`,
  ;; `search_regs` and the DEFUNs; nothing else in the editor calls
  ;; the engine directly. It is **not** in the user environment
  ;; (`imports.scm`): the C engine has no Lisp-visible functions, so
  ;; these names are the internals `string-match' is built on, not an
  ;; API.
  ;;
  ;; **One representation departure worth knowing before profiling**:
  ;; a search builds `make-match-attempt' once and runs it at each
  ;; start position. The C's `re_match_2' is a stack frame per
  ;; attempt; a Scheme `re-match-2' with its helpers as internal
  ;; procedures would allocate a closure for every helper on every
  ;; call, so the attempt object holds them and the reusable vectors,
  ;; and each start position only resets it. The algorithm inside is
  ;; the C's `re_match_2_internal' unchanged.
  ;;
  ;; **The pattern is a vector of instructions.** The C compiles into a
  ;; byte string whose operands are bytes and whose jumps are relative
  ;; byte offsets. Here an instruction is a mutable vector
  ;; `#(OPCODE ARG1 ARG2)`, a jump's argument is an *absolute*
  ;; instruction index, and an instruction whose counter the matcher
  ;; mutates (`succeed_n`, `jump_n`) keeps that counter in a field of
  ;; its own vector. That is a representation departure, not an
  ;; algorithmic one: every opcode, every compiler decision and every
  ;; matcher case is the C's. It exists because Scheme has no byte
  ;; array to patch and because an absolute index cannot be corrupted
  ;; by an insertion the way a relative offset can.
  ;;
  ;; **The text is a sequence of code points, not bytes.** Emacs's
  ;; engine decodes multibyte text inside the match loop (STRING_CHAR,
  ;; GET_CHAR_AFTER, the charset's three-byte characters). This tree's
  ;; buffer store already holds one code point per position, so the
  ;; inner loop reads a code point and the entire UTF-8 decode layer of
  ;; `regex-emacs.c` is absent. A `<re-text>` is its LENGTH plus a REF
  ;; procedure; a string's REF is `string-ref` and a buffer's is the
  ;; gap-aware store reader `buffer->re-text` builds.
  ;;
  ;; **Character sets are an object, not the C's bitmap+range-table
  ;; byte layout.** A `<re-charset>` keeps a 256-bit ASCII map, a
  ;; vector of inclusive code-point ranges, and the `RECC_*` class
  ;; bits. `execute_charset` is a membership test over those three, in
  ;; the same order the C uses (bitmap, ranges, classes). The compiler
  ;; still performs every test the C performs, including case folding
  ;; through `set_image_of_range`; only the storage differs.
  ;;
  ;; **What the port carries**: the compiler's entire switch
  ;; (`regex_compile`, `regex-emacs.c:1742'-`:2743'), including shy and
  ;; numbered groups, back references, intervals, non-greedy
  ;; operators, the syntax, category and word/symbol assertions,
  ;; `\=`, and the buffer anchors; `re_compile_fastmap` and
  ;; `analyze_first`; `re_search`/`re_search_2` with its fastmap and
  ;; `can_be_null` rules; and the matcher
  ;; (`re_match_2_internal') including the failure stack, the "keep
  ;; string" and "loop" variants, and the memoization of failure
  ;; points that Emacs 31 added (`on_failure_jump_memo`,
  ;; `on_failure_jump_prememo`, `memo_*`).
  ;;
  ;; **Errors** are the C's `reg_errcode_t` names as Scheme symbols,
  ;; raised with the C's message, so an `invalid-regexp` caller sees
  ;; what it sees in Emacs.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    (scheme char)
    (only (guile) ash logand logior lognot logxor logcount logbit? u32vector-ref caddr cadddr)
    (only (schemacs category) char-category-set category-table
          word-boundary-p)
    (only (schemacs data) bool-vector-p bool-vector-ref)
    (only (schemacs syntax) syntax-table syntax-class-to-char
          sword ssymbol %spec-code %class-in %setup-syntax-table)
    (only (schemacs buffer) current-buffer)
    (only (schemacs chartab)
          char-table? char-table-ref char-table-extra-slot))

  (export
   ;; `struct re_pattern_buffer' (`regex-emacs.h:64')
   make-re-pattern-buffer re-pattern-buffer?
   re-pattern-buffer-buffer set-re-pattern-buffer-buffer!
   re-pattern-buffer-fastmap set-re-pattern-buffer-fastmap!
   re-pattern-buffer-translate set-re-pattern-buffer-translate!
   re-pattern-buffer-nsub set-re-pattern-buffer-nsub!
   re-pattern-buffer-can-be-null? set-re-pattern-buffer-can-be-null!
   re-pattern-buffer-fastmap-accurate? set-re-pattern-buffer-fastmap-accurate!
   re-pattern-buffer-used-syntax? set-re-pattern-buffer-used-syntax!
   ;; `struct re_registers' (`regex-emacs.h:27')
   make-re-registers re-registers? re-registers-num
   re-registers-start re-registers-end
   ;; the text and the context
   make-re-text re-text? re-text-length re-text-ref
   string->re-text buffer->re-text
   make-re-context re-context? re-context-text re-context-syntax-table
   re-context-category-table re-context-translate re-context-point
   re-context-buffer? re-context-position
   ;; character classes (`regex-emacs.h:182')
   re-wctype-parse re-iswctype
   ;; the charset object
   <re-charset> make-re-charset re-charset?
   re-charset-map re-charset-ranges re-charset-classes
   re-charset-member? re-charset-member-full?
   ;; the compiler and its fastmap
   re-compile-pattern re-compile-fastmap
   ;; the matcher and the search
   re-match-2 re-search
   make-re-fastmap re-fastmap? re-fastmap-ref
   ;; opcodes, for the disassembler and the tests
   re-opcode-name)

  (begin

    ;;----------------------------------------------------------------
    ;; The opcodes (`regex-emacs.c:202'-`:345')
    ;;----------------------------------------------------------------
    (define op-no-op 0)
    (define op-succeed 1)
    (define op-exactn 2)
    (define op-anychar 3)
    (define op-charset 4)
    (define op-charset-not 5)
    (define op-start-memory 6)
    (define op-stop-memory 7)
    (define op-duplicate 8)
    (define op-begline 9)
    (define op-endline 10)
    (define op-begbuf 11)
    (define op-endbuf 12)
    (define op-jump 13)
    (define op-on-failure-jump-memo 14)
    (define op-on-failure-jump-nomemo 15)
    (define op-on-failure-jump-prememo 16)
    (define op-on-failure-keep-string-jump 17)
    (define op-on-failure-jump-loop 18)
    (define op-on-failure-jump-nastyloop 19)
    (define op-on-failure-jump-smart 20)
    (define op-succeed-n 21)
    (define op-jump-n 22)
    (define op-set-number-at 23)
    (define op-wordbeg 24)
    (define op-wordend 25)
    (define op-wordbound 26)
    (define op-notwordbound 27)
    (define op-symbeg 28)
    (define op-symend 29)
    (define op-syntaxspec 30)
    (define op-notsyntaxspec 31)
    (define op-at-dot 32)
    (define op-categoryspec 33)
    (define op-notcategoryspec 34)

    (define %opcode-names
      (vector 'no_op 'succeed 'exactn 'anychar 'charset 'charset_not
              'start_memory 'stop_memory 'duplicate 'begline 'endline
              'begbuf 'endbuf 'jump 'on_failure_jump_memo
              'on_failure_jump_nomemo 'on_failure_jump_prememo
              'on_failure_keep_string_jump 'on_failure_jump_loop
              'on_failure_jump_nastyloop 'on_failure_jump_smart
              'succeed_n 'jump_n 'set_number_at 'wordbeg 'wordend
              'wordbound 'notwordbound 'symbeg 'symend 'syntaxspec
              'notsyntaxspec 'at_dot 'categoryspec 'notcategoryspec))

    (define (re-opcode-name op)
      (and (integer? op) (>= op 0) (< op (vector-length %opcode-names))
           (vector-ref %opcode-names op)))

    ;;----------------------------------------------------------------
    ;; `struct re_pattern_buffer' (`regex-emacs.h:64')
    ;;----------------------------------------------------------------
    (define-record-type <re-pattern-buffer>
      (%make-re-pattern-buffer buffer fastmap translate nsub can-be-null?
                               fastmap-accurate? used-syntax? translate-vec)
      re-pattern-buffer?
      (buffer re-pattern-buffer-buffer set-re-pattern-buffer-buffer!)
      (fastmap re-pattern-buffer-fastmap set-re-pattern-buffer-fastmap!)
      (translate re-pattern-buffer-translate set-re-pattern-buffer-translate!)
      (nsub re-pattern-buffer-nsub set-re-pattern-buffer-nsub!)
      (can-be-null? re-pattern-buffer-can-be-null?
                    set-re-pattern-buffer-can-be-null!)
      (fastmap-accurate? re-pattern-buffer-fastmap-accurate?
                         set-re-pattern-buffer-fastmap-accurate!)
      (used-syntax? re-pattern-buffer-used-syntax?
                    set-re-pattern-buffer-used-syntax!)
      ;; TRANSLATE-VEC is the TRANSLATE table's answers for characters
      ;; 0..255, filled lazily by `re-translate-vector'. **No C
      ;; counterpart**: the C's `TRANSLATE' is a C-level
      ;; `char_table_translate' tree walk, while `char-table-ref' here
      ;; costs 64 ns against a vector's 11 ns, and folded matching
      ;; asks it once per character. A host-compensation, recorded as
      ;; a representation departure in DEPARTURES.md; the answers are
      ;; `%translate-code''s exactly, and characters above 255 still
      ;; go through the table.
      (translate-vec re-pattern-buffer-translate-vec
                     set-re-pattern-buffer-translate-vec!))

    (define (make-re-pattern-buffer buffer fastmap translate nsub can-be-null?
                                    fastmap-accurate? used-syntax?)
      (%make-re-pattern-buffer buffer fastmap translate nsub can-be-null?
                               fastmap-accurate? used-syntax? #f))

    ;;----------------------------------------------------------------
    ;; `struct re_registers' (`regex-emacs.h:27')
    ;;----------------------------------------------------------------
    (define-record-type <re-registers>
      (make-re-registers num start end)
      re-registers?
      (num re-registers-num)
      (start re-registers-start)
      (end re-registers-end))

    ;;----------------------------------------------------------------
    ;; The text being matched
    ;;----------------------------------------------------------------
    (define-record-type <re-text>
      (%make-re-text length ref string buffer)
      re-text?
      (length re-text-length)
      (ref re-text-ref)
      ;; The direct-reading form: STRING for a string-backed text, or
      ;; BUFFER = `#(STORE GPT GAP BASE)' for a buffer-backed one. The
      ;; closure is what `make-re-text' (the exported two-argument
      ;; constructor) still is, but the two constructors below also
      ;; record the substrate, so the inner loops read a code point
      ;; without a closure call per character.
      (string re-text-string)
      (buffer re-text-buffer))

    (define (make-re-text length ref)
      ;; The exported constructor: a text of LENGTH code points read
      ;; by REF. Callers with a string or a buffer should use the two
      ;; constructors below, which record the substrate as well.
      ;;----------------------------------------------------------
      (%make-re-text length ref #f #f))

    (define (string->re-text string)
      ;; A Scheme string as matcher text. Code points, so it cannot
      ;; hold an eight-bit character - the same limit `string-match'
      ;; has everywhere above the store.
      ;;----------------------------------------------------------
      (let ((len (string-length string)))
        (%make-re-text len
                       (lambda (i) (char->integer (string-ref string i)))
                       string #f)))

    (define (buffer->re-text store gpt gap base z)
      ;; A buffer-text's store as matcher text. STORE index I is code
      ;; point I; the gap of GAP elements begins at GPT; the matcher's
      ;; position 0 is store index BASE; the text ends at store index Z.
      ;; The four values are hoisted by the caller once, as the tree's
      ;; other scans hoist them, because the inner loop must not ask a
      ;; record.
      ;;----------------------------------------------------------
      (%make-re-text (- z base)
                     (lambda (i)
                       (let ((p (+ base i)))
                         (if (< p gpt)
                             (u32vector-ref store p)
                             (u32vector-ref store (+ p gap)))))
                     #f (vector store gpt gap base)))

    ;;----------------------------------------------------------------
    ;; The matching context
    ;;----------------------------------------------------------------
    ;;
    ;; Emacs reads the syntax, category and case tables of the current
    ;; buffer while matching (`re_match_object' decides only whether
    ;; the text is a buffer or a string). The context carries those
    ;; three, POINT (the buffer position `\=' compares with) and
    ;; POSITION (the buffer position of the text's first character,
    ;; used for the syntax cache). BUFFER? is true when the text is a
    ;; buffer, so `` \` `` and `\'` mean BEGV/ZV rather than the start
    ;; and end of the matched string.
    ;;--------------------------------------------------------------
    (define-record-type <re-context>
      (make-re-context text syntax-table category-table translate point
                       buffer? position)
      re-context?
      (text re-context-text)
      (syntax-table re-context-syntax-table)
      (category-table re-context-category-table)
      (translate re-context-translate)
      (point re-context-point)
      (buffer? re-context-buffer?)
      (position re-context-position))

    ;;----------------------------------------------------------------
    ;; Character classes
    ;;----------------------------------------------------------------
    (define recc-error 0)
    (define recc-alnum 1)
    (define recc-alpha 2)
    (define recc-word 3)
    (define recc-graph 4)
    (define recc-print 5)
    (define recc-lower 6)
    (define recc-upper 7)
    (define recc-punct 8)
    (define recc-cntrl 9)
    (define recc-digit 10)
    (define recc-xdigit 11)
    (define recc-blank 12)
    (define recc-space 13)
    (define recc-multibyte 14)
    (define recc-nonascii 15)
    (define recc-ascii 16)
    (define recc-unibyte 17)

    (define (re-wctype-parse string start limit)
      ;; `re_wctype_parse` (`regex-emacs.c:1543'): parse `[:NAME:]` at
      ;; START, answering the class and the index just past `:]`, or
      ;; `#f` and START when it is not one.
      ;;----------------------------------------------------------
      (if (or (< (- limit start) 4)
              (not (char=? (string-ref string start) #\[))
              (not (char=? (string-ref string (+ start 1)) #\:)))
          (values #f start)
          (let ((beg (+ start 2)))
            (let loop ((i beg))
              (cond
               ((>= (+ i 1) limit) (values #f start))
               ((and (char=? (string-ref string i) #\:)
                     (char=? (string-ref string (+ i 1)) #\]))
                (let ((name (substring string beg i)))
                  (values (cond
                           ((string=? name "word") recc-word)
                           ((string=? name "alnum") recc-alnum)
                           ((string=? name "alpha") recc-alpha)
                           ((string=? name "space") recc-space)
                           ((string=? name "digit") recc-digit)
                           ((string=? name "blank") recc-blank)
                           ((string=? name "upper") recc-upper)
                           ((string=? name "lower") recc-lower)
                           ((string=? name "punct") recc-punct)
                           ((string=? name "ascii") recc-ascii)
                           ((string=? name "graph") recc-graph)
                           ((string=? name "print") recc-print)
                           ((string=? name "cntrl") recc-cntrl)
                           ((string=? name "xdigit") recc-xdigit)
                           ((string=? name "unibyte") recc-unibyte)
                           ((string=? name "nonascii") recc-nonascii)
                           ((string=? name "multibyte") recc-multibyte)
                           (else recc-error))
                          (+ i 2))))
               (else (loop (+ i 1))))))))

    (define (%char-alphabetic? ch) (char-alphabetic? (integer->char ch)))
    (define (%char-numeric? ch) (char-numeric? (integer->char ch)))
    (define (%char-lower-case? ch) (char-lower-case? (integer->char ch)))
    (define (%char-upper-case? ch) (char-upper-case? (integer->char ch)))
    (define (%char-whitespace? ch) (char-whitespace? (integer->char ch)))
    (define (%char-alphanumeric? ch)
      (or (%char-alphabetic? ch) (%char-numeric? ch)))
    (define (%char-graphic? ch)
      (and (> ch 32) (not (%char-control? ch))))
    (define (%char-printable? ch)
      (or (= ch 32) (%char-graphic? ch)))
    (define (%char-punctuation? ch)
      (and (%char-graphic? ch) (not (%char-alphanumeric? ch))))
    (define (%char-control? ch)
      (or (< ch 32) (= ch 127) (and (>= ch 128) (< ch 160))))
    (define (%char-xdigit? ch)
      (or (%char-numeric? ch)
          (and (>= ch (char->integer #\a)) (<= ch (char->integer #\f)))
          (and (>= ch (char->integer #\A)) (<= ch (char->integer #\F)))))
    (define (%char-blank? ch)
      (or (= ch 32) (= ch 9)))

    (define (re-iswctype ch cc)
      ;; `re_iswctype` (`regex-emacs.c:1622'): "True if CH is in the
      ;; char class CC." The classes are Unicode's, which is what the
      ;; code-point store makes natural; `word` is the *standard*
      ;; syntax table's word class here (the C's `ISWORD` is the
      ;; current buffer's syntax table, supplied by the caller when it
      ;; matters).
      ;;----------------------------------------------------------
      (cond
       ((= cc recc-alnum) (%char-alphanumeric? ch))
       ((= cc recc-alpha) (%char-alphabetic? ch))
       ((= cc recc-word) (char=? (syntax-class-to-char
                                  (logand (char-table-ref (syntax-table) ch)
                                          #xff))
                                 #\w))
       ((= cc recc-graph) (%char-graphic? ch))
       ((= cc recc-print) (%char-printable? ch))
       ((= cc recc-lower) (%char-lower-case? ch))
       ((= cc recc-upper) (%char-upper-case? ch))
       ((= cc recc-punct) (%char-punctuation? ch))
       ((= cc recc-cntrl) (%char-control? ch))
       ((= cc recc-digit) (%char-numeric? ch))
       ((= cc recc-xdigit) (%char-xdigit? ch))
       ((= cc recc-blank) (%char-blank? ch))
       ((= cc recc-space) (%char-whitespace? ch))
       ((= cc recc-multibyte) (> ch 255))
       ((= cc recc-nonascii) (> ch 127))
       ((= cc recc-ascii) (<= ch 127))
       ((= cc recc-unibyte) (<= ch 255))
       (else #f)))

    ;;----------------------------------------------------------------
    ;; The charset object
    ;;----------------------------------------------------------------
    (define-record-type <re-charset>
      (%make-re-charset map ranges classes table simple?)
      re-charset?
      (map re-charset-map)          ; integer bitmask, bits 0..255
      (ranges re-charset-ranges)    ; vector of (FROM . TO), inclusive
      (classes re-charset-classes)  ; integer `RECC' bitmask
      ;; TABLE is the bitmap as a 256-entry boolean vector, built once
      ;; when the charset is: the matcher asks it of every character
      ;; it tests, and `vector-ref' on a small fixnum index is about
      ;; half the cost of `logbit?' on a 256-bit integer (measured
      ;; 11 ns against 20 ns compiled). The integer stays because
      ;; `mutually_exclusive_p' compares two charsets with `logand'.
      (table re-charset-table)
      ;; SIMPLE? is "the bitmap is the whole set" - no ranges and no
      ;; class bits - which lets the matcher skip `%execute-charset'
      ;; entirely on a miss. **This has no counterpart in the C**:
      ;; `execute_charset' always runs the (empty) range and class
      ;; tests there, and recovers the cost by being a `static'
      ;; function the C compiler inlines. A Scheme procedure call is
      ;; not inlined, so a bitmap-only set is answered without one:
      ;; a host-compensation, recorded as a representation departure
      ;; in DEPARTURES.md, not an Emacs algorithm. It is decided once
      ;; and changes no answer.
      (simple? re-charset-simple?))

    (define (make-re-charset map ranges classes)
      (let ((table (make-vector 256 #f)))
        (do ((j 0 (+ j 1))) ((= j 256))
          (when (logbit? j map)
            (vector-set! table j #t)))
        (%make-re-charset map ranges classes table
                          (and (zero? (vector-length ranges))
                               (zero? classes)))))

    (define (%re-charset-class-bit cc)
      ;; `re_wctype_to_bit` (`regex-emacs.c:1652'): the range-table bit
      ;; for class CC; the classes that fit in the ASCII bitmap answer
      ;; 0. The values are `regex-emacs.c:1387'-`:1397`'s `BIT_*`.
      ;;
      ;; The layout used to be an older Emacs's (multibyte at bit 0,
      ;; alpha at bit 1, ... lower at bit 4, upper at bit 5), while
      ;; `%re-charset-class-member/canon` tested the upper and lower
      ;; arms on the opposite bits - so the compiler wrote "lower"
      ;; where the class test read "upper". The
      ;; two disagreeing was invisible while case folding was on (both
      ;; arms matched either case) and wrong when it was off, which is
      ;; how c-mode's fontification runs: `[[:upper:]]` matched `p`
      ;; through `looking-at`, where a search's fastmap had masked it.
      ;;----------------------------------------------------------
      (cond ((= cc recc-word) #x1)
            ((= cc recc-lower) #x2)
            ((= cc recc-punct) #x4)
            ((= cc recc-space) #x8)
            ((= cc recc-upper) #x10)
            ((or (= cc recc-multibyte) (= cc recc-nonascii)) #x20)
            ((= cc recc-alpha) #x40)
            ((= cc recc-alnum) #x80)
            ((= cc recc-graph) #x100)
            ((= cc recc-print) #x200)
            ((= cc recc-blank) #x400)
            (else 0)))

    (define (re-charset-member? cs ch)
      ;; `execute_charset`'s bitmap and range halves
      ;; (`regex-emacs.c:3803'): characters below 256 use the map, the
      ;; rest the inclusive ranges.
      ;;----------------------------------------------------------
      (cond
       ((< ch 256)
        (not (zero? (logand (re-charset-map cs) (ash 1 ch)))))
       (else
        (let ((ranges (re-charset-ranges cs)))
          (let loop ((i 0))
            (cond
             ((>= i (vector-length ranges)) #f)
             ((and (>= ch (car (vector-ref ranges i)))
                   (<= ch (cdr (vector-ref ranges i))))
              #t)
             (else (loop (+ i 1)))))))))

    (define (%re-charset-class-member? cs ch)
      ;; `execute_charset`'s class half (`regex-emacs.c:3837`) with no
      ;; canonicalisation table: CORIG is CH and CANON is nil. The
      ;; tests are the C's, in the C's order. `BIT_MULTIBYTE` is
      ;; spelled `(> ch 127)` rather than the C's unconditional test,
      ;; because this matcher reads the class half for a character
      ;; below 256 whose bitmap missed, where the C's unibyte
      ;; characters never reach it.
      (let ((bits (re-charset-classes cs)))
        (or (and (not (zero? (logand bits #x20))) (> ch 127))
            (and (not (zero? (logand bits #x80))) (%char-alphanumeric? ch))
            (and (not (zero? (logand bits #x40))) (%char-alphabetic? ch))
            (and (not (zero? (logand bits #x8))) (%char-whitespace? ch))
            (and (not (zero? (logand bits #x400))) (%char-blank? ch))
            (and (not (zero? (logand bits #x1)))
                 (char=? (syntax-class-to-char
                          (logand (char-table-ref (syntax-table) ch) #xff))
                         #\w))
            (and (not (zero? (logand bits #x10))) (%char-upper-case? ch))
            (and (not (zero? (logand bits #x2))) (%char-lower-case? ch))
            (and (not (zero? (logand bits #x4))) (%char-punctuation? ch))
            (and (not (zero? (logand bits #x100))) (%char-graphic? ch))
            (and (not (zero? (logand bits #x200))) (%char-printable? ch)))))

    (define (re-charset-member-full? cs ch)
      (or (re-charset-member? cs ch)
          (%re-charset-class-member? cs ch)))


    ;;----------------------------------------------------------------
    ;; The compiler's instruction buffer and its helpers
    ;;----------------------------------------------------------------
    ;;
    ;; The C's `bufp->buffer' and `b' are a byte array and a pointer; an
    ;; insertion (`INSERT_JUMP') opens three bytes at a location and
    ;; every jump, being a *relative* offset, is unaffected. Here the
    ;; buffer is a vector of instruction vectors and the jumps are
    ;; absolute indexes, so a helper that inserts an instruction must
    ;; shift every address at or after the insertion point - and the
    ;; compiler's own saved indexes with it. `<compile-state>' is those
    ;; saved indexes, so an insertion can keep them right in one place,
    ;; the way the C's offsets keep themselves right.
    ;;--------------------------------------------------------------
    (define-record-type <compile-state>
      (%make-compile-state bufp translate buffer used laststart begalt
                           fixup-alt-jump pending-exact nsub stack)
      compile-state?
      (bufp compile-state-bufp)
      (translate compile-state-translate)
      (buffer compile-state-buffer set-compile-state-buffer!)
      (used compile-state-used set-compile-state-used!)
      (laststart compile-state-laststart set-compile-state-laststart!)
      (begalt compile-state-begalt set-compile-state-begalt!)
      (fixup-alt-jump compile-state-fixup-alt-jump
                      set-compile-state-fixup-alt-jump!)
      (pending-exact compile-state-pending-exact
                     set-compile-state-pending-exact!)
      (nsub compile-state-nsub set-compile-state-nsub!)
      (stack compile-state-stack set-compile-state-stack!))

    (define (%address-op? op)
      ;; The opcodes whose ARG1 is an instruction index.
      ;;----------------------------------------------------------
      (memv op (list op-jump op-on-failure-jump-memo
                     op-on-failure-jump-nomemo op-on-failure-jump-prememo
                     op-on-failure-keep-string-jump op-on-failure-jump-loop
                     op-on-failure-jump-nastyloop op-on-failure-jump-smart
                     op-succeed-n op-jump-n op-set-number-at)))

    (define (%emit! st op a b)
      ;; `BUF_PUSH' / `BUF_PUSH_2' / `STORE_JUMP' / `INSERT_JUMP''s
      ;; effect: append an instruction and answer its index. A jump's
      ;; ARG1 is filled in later, so 0 is a valid "no target yet".
      ;;----------------------------------------------------------
      (let* ((buffer (compile-state-buffer st))
             (used (compile-state-used st)))
        (when (>= used (vector-length buffer))
          (let ((new (make-vector (* 2 (max 1 (vector-length buffer))) #f)))
            (let loop ((i 0))
              (when (< i used)
                (vector-set! new i (vector-ref buffer i))
                (loop (+ i 1))))
            (set-compile-state-buffer! st new)
            (set! buffer new)))
        (vector-set! buffer used (vector op a b))
        (set-compile-state-used! st (+ used 1))
        used))

    (define (%shift-index index at)
      ;; A compiler index equal to AT designates the insertion point
      ;; itself (the C's pointer stays there); only one beyond it has
      ;; moved. An *instruction address*, by contrast, designates an
      ;; instruction and shifts when it is at or after the insertion -
      ;; see `%insert-at!`.
      (if (and index (> index at)) (+ index 1) index))

    (define (%insert-at! st at ins)
      ;; Insert INS at index AT, shifting the instructions after it and
      ;; every address argument at or after it (the C's `insert_op1'/
      ;; `insert_op2' plus the relative-offset arithmetic it does not
      ;; need). The compiler's saved indexes are shifted with it.
      ;;----------------------------------------------------------
      (let* ((buffer (compile-state-buffer st))
             (used (compile-state-used st)))
        (when (>= used (vector-length buffer))
          (let ((new (make-vector (* 2 (max 1 (vector-length buffer))) #f)))
            (let loop ((i 0))
              (when (< i used)
                (vector-set! new i (vector-ref buffer i))
                (loop (+ i 1))))
            (set-compile-state-buffer! st new)
            (set! buffer new)))
        (let loop ((i used))
          (when (> i at)
            (vector-set! buffer i (vector-ref buffer (- i 1)))
            (loop (- i 1))))
        (vector-set! buffer at ins)
        (set-compile-state-used! st (+ used 1))
        ;; The instructions the insertion moved hold *relative* targets
        ;; in the C. An instruction that moves by one slot has its target
        ;; move by one slot too - whatever the target was - so every
        ;; instruction after AT has its address argument raised by one.
        ;; The instruction AT was moved to AT+1 and is shifted with
        ;; them; the new instruction at AT is not.
        ;;
        ;; The compiler's own indexes are C pointers and are not
        ;; adjusted by an insertion; the C never relies on one across
        ;; an insert, and the macros reset them where they could.
        (let loop ((i 0))
          (when (< i (+ used 1))
            (unless (= i at)
              (let ((ins (vector-ref buffer i)))
                (when (and ins (%address-op? (vector-ref ins 0)))
                  (let ((a (vector-ref ins 1)))
                    (when (and (integer? a) (> i at))
                      (vector-set! ins 1 (+ a 1)))))))
            (loop (+ i 1))))
        at))

    (define (%store-jump! st at target)
      ;; `STORE_JUMP': point the instruction at AT at TARGET.
      ;;----------------------------------------------------------
      (vector-set! (vector-ref (compile-state-buffer st) at) 1 target))

    (define (%store-number-at! st at target n)
      ;; `store_op2': the `succeed_n'/'jump_n' pair - target and count.
      ;;----------------------------------------------------------
      (let ((ins (vector-ref (compile-state-buffer st) at)))
        (vector-set! ins 1 target)
        (vector-set! ins 2 n)))

    (define (%skip-one-char st p)
      ;; `skip_one_char` (`regex-emacs.c:3758'): the index just after
      ;; the one-character instruction at P, or #f when P is not one.
      ;; The C's byte-length arithmetic is unnecessary: an instruction
      ;; vector already spans exactly one opcode.
      ;;----------------------------------------------------------
      (let ((op (vector-ref (vector-ref (compile-state-buffer st) p) 0)))
        (cond ((memv op (list op-anychar op-exactn op-charset op-charset-not
                              op-syntaxspec op-notsyntaxspec
                              op-categoryspec op-notcategoryspec))
               (+ p 1))
              (else #f))))

    (define (%at-begline-loc? pattern p)
      ;; `at_begline_loc_p` (`regex-emacs.c:2798'): is the `^` at P
      ;; (P is one past it) after a group opening or an alternative?
      ;; PATTERN and P are indexes into the pattern string; the C's
      ;; pointer arithmetic becomes index arithmetic.
      ;;----------------------------------------------------------
      (let ((prev (- p 2)))
        (cond
         ((or (char=? (string-ref pattern prev) #\()
              (char=? (string-ref pattern prev) #\|))
          #t)
         ((char=? (string-ref pattern prev) #\:)
          ;; Skip over an optional regnum.
          (let skip ((q prev))
            (if (and (> q 0)
                     (char-numeric? (string-ref pattern (- q 1))))
                (skip (- q 1))
                (if (and (> q 1)
                         (char=? (string-ref pattern (- q 1)) #\?)
                         (char=? (string-ref pattern (- q 2)) #\())
                    (let ((q2 (- q 2)))
                      ;; Count the preceding backslashes.
                      (let count ((r q2) (n 0))
                        (if (and (> r 0)
                                 (char=? (string-ref pattern (- r 1)) #\\))
                            (count (- r 1) (+ n 1))
                            (odd? n))))
                    #f))))
         (else #f))))

    (define (%at-endline-loc? pattern p pend)
      ;; `at_endline_loc_p` (`regex-emacs.c:2834'): is the `$` at P
      ;; before a subexpression or an alternative?
      ;;----------------------------------------------------------
      (and (< p pend)
           (char=? (string-ref pattern p) #\\)
           (< (+ p 1) pend)
           (or (char=? (string-ref pattern (+ p 1)) #\))
               (char=? (string-ref pattern (+ p 1)) #\|))))

    (define (%group-in-compile-stack st regnum)
      ;; `group_in_compile_stack` (`regex-emacs.c:2845').
      ;;----------------------------------------------------------
      (let loop ((frames (compile-state-stack st)))
        (cond ((null? frames) #f)
              ((= (cadddr (car frames)) regnum) #t)
              (else (loop (cdr frames))))))

    (define (%exactn-append! st at code)
      ;; Add CODE to the `exactn` instruction at AT. The C appends a
      ;; byte after the count; this appends to the instruction's
      ;; character vector.
      ;;----------------------------------------------------------
      (let* ((ins (vector-ref (compile-state-buffer st) at))
             (chars (vector-ref ins 1)))
        (vector-set! ins 1 (append chars (list code)))
        #t))


    ;;----------------------------------------------------------------
    ;; `forall_firstchar' and `analyze_first'
    ;; (`regex-emacs.c:2858'-`:3350')
    ;;----------------------------------------------------------------
    ;;
    ;; `forall_firstchar' walks every character-matching operation
    ;; reachable from a program point without crossing an exit from the
    ;; current loop block. It answers #t when the block is "safe"
    ;; (its end cannot be reached directly and every callback answered
    ;; true) and #f otherwise.
    ;;
    ;; The C's pointer arithmetic maps instruction by instruction. An
    ;; `on_failure_jump` occupies one instruction here, where the C
    ;; spends three bytes, so its second destination is the *next
    ;; instruction* rather than P+3; `succeed_n`'s is likewise the next
    ;; instruction rather than P+5. `set_number_at`'s target is stored
    ;; as an absolute instruction index, so the C's "offset == 5 and
    ;; P[5] == succeed_n" test becomes "the target is the immediately
    ;; following instruction and that instruction is `succeed_n'".
    ;;--------------------------------------------------------------
    (define (%ins-at buf used i)
      (and (integer? i) (>= i 0) (< i used) (vector-ref buf i)))

    (define (%on-failure-op? op)
      (memv op (list op-on-failure-jump-memo op-on-failure-jump-nomemo
                     op-on-failure-jump-prememo
                     op-on-failure-keep-string-jump
                     op-on-failure-jump-nastyloop op-on-failure-jump-loop
                     op-on-failure-jump-smart)))

    (define (%forall-firstchar-1 buf used p pend loop-beg loop-end f arg)
      ;; The C's `forall_firstchar_1'. P/PEND/LOOP-BEG/LOOP-END are
      ;; instruction indexes; PEND is the index one past the last
      ;; instruction under construction, or USED after compilation.
      ;;----------------------------------------------------------
      (define (jump-dest newp1 newp2 p-orig loop-beg loop-end)
        ;; The C's `do_jump' arm, answering 'fail, 'safe (the function
        ;; returns true) or (NEWP1 LOOP-BEG LOOP-END).
        (if (<= newp1 p-orig)
            (cond ((< newp1 loop-beg) 'fail)
                  ((= newp1 loop-beg) 'safe)
                  ;; Backward into a new loop nested in this one: P gets
                  ;; smaller but LOOP-BEG gets bigger.
                  (else (list newp1 newp1 newp2)))
            (list newp1 loop-beg loop-end)))
      (define (twoway newp1 newp2 p-orig loop-beg loop-end)
        ;; The C's `do_twoway_jump': both destinations must be safe;
        ;; explore the larger first, then the smaller as a one-way
        ;; jump.
        (let ((small (min newp1 newp2))
              (big (max newp1 newp2)))
          (if (<= big p-orig)
              'fail
              (if (step big loop-beg loop-end)
                  (jump-dest small big p-orig loop-beg loop-end)
                  'fail))))
      (define (finish outcome)
        (cond ((eq? outcome 'fail) #f)
              ((eq? outcome 'safe) #t)
              (else (step (car outcome) (cadr outcome) (caddr outcome)))))
      (define (step p loop-beg loop-end)
        (let ((p-orig p))
          (cond
           ((= p pend) #f)
           ((= p loop-end) #t)
           ((> p loop-end) #f)
           (else
            (let* ((ins (%ins-at buf used p))
                   (op (and ins (vector-ref ins 0))))
              (cond
               ((not ins) #f)
               ((= op op-no-op) (step (+ p 1) loop-beg loop-end))

               ;; The cases which stop the iteration.
               ((memv op (list op-succeed op-exactn op-charset
                               op-charset-not op-anychar op-syntaxspec
                               op-notsyntaxspec op-categoryspec
                               op-notcategoryspec))
                (f p arg))

               ;; The cases which may match the empty string.
               ((memv op (list op-at-dot op-begbuf op-wordbound
                               op-notwordbound op-begline op-endline
                               op-endbuf op-wordbeg op-wordend op-symbeg
                               op-symend))
                (if (f p arg) #t (step (+ p 1) loop-beg loop-end)))

               ((memv op (list op-jump op-jump-n))
                (let ((newp1 (vector-ref ins 1)))
                  (if (> newp1 p)
                      ;; Forward jump, boring.
                      (step newp1 loop-beg loop-end)
                      (let ((target (%ins-at buf used newp1)))
                        (if (and target
                                 (or (%on-failure-op? (vector-ref target 0))
                                     (= (vector-ref target 0) op-succeed-n)))
                            (finish (twoway newp1 (vector-ref target 1)
                                            p-orig loop-beg loop-end))
                            ;; "Safe" choice.
                            (finish (jump-dest newp1 loop-end p-orig
                                               loop-beg loop-end)))))))

               ((%on-failure-op? op)
                (let* ((newp1 (vector-ref ins 1))
                       (newp2 (+ p 1))
                       (next (%ins-at buf used newp2)))
                  ;; For `+' loops, the on-failure-jump often skips
                  ;; forward over a following `jump'; recognize that
                  ;; pattern, as the C does, when one of the two
                  ;; destinations goes forward.
                  (when (and next (= (vector-ref next 0) op-jump))
                    (let ((p3 (vector-ref next 1)))
                      (if (or (> p3 p-orig) (> newp1 p-orig))
                          (set! newp2 p3))))
                  (finish (twoway newp1 newp2 p-orig loop-beg loop-end))))

               ((= op op-succeed-n)
                (finish (twoway (vector-ref ins 1) (+ p 1) p-orig
                                loop-beg loop-end)))

               ((= op op-set-number-at)
                ;; If the counter being set belongs to an immediately
                ;; following `succeed_n', that next execution only
                ;; decrements the counter and falls through, so skip
                ;; both instructions (the C's `offset == 5 && P[5] ==
                ;; succeed_n' test).
                (let ((target (vector-ref ins 1)))
                  (if (and (= target (+ p 1))
                           (< (+ p 1) used)
                           (= (vector-ref (vector-ref buf (+ p 1)) 0)
                              op-succeed-n))
                      (step (+ p 2) loop-beg loop-end)
                      (step (+ p 1) loop-beg loop-end))))

               ((or (= op op-start-memory) (= op op-stop-memory))
                (step (+ p 1) loop-beg loop-end))

               ((= op op-duplicate)
                ;; Either it matches something non-empty, or it matches
                ;; the empty string and the rest of the path matters.
                (if (f p arg) (step (+ p 1) loop-beg loop-end) #f))

               (else #f)))))))
      (step p loop-beg loop-end))

    (define (%forall-firstchar buf used p pend f arg)
      ;; `forall_firstchar` with an explicit block: P..PEND is the code
      ;; under construction, so a jump can point past PEND only by
      ;; mistake and `p == pend' answers unsafe.
      ;;----------------------------------------------------------
      (%forall-firstchar-1 buf used p pend p pend f arg))

    (define (%forall-firstchar-all buf used p f arg)
      ;; `forall_firstchar` over a completed pattern: the C's
      ;; `bufp->buffer - 1' .. `bufp->buffer + bufp->used + 1' - here
      ;; index -1 .. USED, with PEND = USED, so the one-past-the-end
      ;; check fires first.
      ;;----------------------------------------------------------
      (%forall-firstchar-1 buf used p used -1 used f arg))

    ;;----------------------------------------------------------------
    ;; The fastmap (`regex-emacs.c:3102'-`:3382')
    ;;----------------------------------------------------------------
    ;;
    ;; The C's fastmap is a 256-byte table over *bytes*: a character
    ;; above 255 is represented by its leading byte. This engine reads
    ;; code points, so the map is 256 bits for code points 0..255 plus
    ;; one flag for "some code point above 255 may start a match". The
    ;; flag over-approximates the C's leading-byte set, which is sound:
    ;; the fastmap only skips start positions, so a wider map costs
    ;; time and never an answer. The map is consulted only when
    ;; `can_be_null' is false, as in Emacs.
    ;;--------------------------------------------------------------
    (define-record-type <re-fastmap>
      (%make-re-fastmap bits any-nonascii? table)
      re-fastmap?
      (bits re-fastmap-bits set-re-fastmap-bits!)
      (any-nonascii? re-fastmap-any-nonascii?
                     set-re-fastmap-any-nonascii!)
      ;; TABLE is BITS as a 256-entry boolean vector, built at the end
      ;; of `re-compile-fastmap'. The skip loop consults it once per
      ;; skipped character and `vector-ref' is about half the cost of
      ;; `logbit?' on the 256-bit integer (measured 11 ns against
      ;; 20 ns compiled). BITS stays as the accumulator because
      ;; `%fastmap-set!' can add a bit at any time during the compile.
      (table re-fastmap-table set-re-fastmap-table!))

    (define (make-re-fastmap bits any-nonascii?)
      (%make-re-fastmap bits any-nonascii? #f))

    (define (%fastmap-clear! fm)
      (set-re-fastmap-bits! fm 0)
      (set-re-fastmap-any-nonascii! fm #f)
      (set-re-fastmap-table! fm #f))

    (define (%fastmap-set! fm ch)
      (if (< ch 256)
          (set-re-fastmap-bits! fm (logior (re-fastmap-bits fm) (ash 1 ch)))
          (set-re-fastmap-any-nonascii! fm #t)))

    (define (re-fastmap-ref fm ch)
      ;; "Can a match start with CH?"
      ;;
      ;; **`logbit?' and not `(logand BITS (ash 1 CH))`.** The map is a
      ;; 256-bit integer, so `ash' allocates a fresh bignum for every
      ;; character consulted - and this is consulted once per skipped
      ;; character of every search. `logbit?' tests the limb in place.
      ;; The C's fastmap is a byte array; this is the nearest Scheme
      ;; spelling with the same cost.
      ;;----------------------------------------------------------
      (if (< ch 256)
          (logbit? ch (re-fastmap-bits fm))
          (re-fastmap-any-nonascii? fm)))

    (define (%char-has-category? ch category)
      ;; `CHAR_HAS_CATEGORY(c, k)' (`category.h'): the current table's
      ;; set for CH has K. `char-category-set' reads the current
      ;; buffer's table, which is the C's BVAR read.
      ;;----------------------------------------------------------
      (let ((set (char-category-set ch)))
        (and (bool-vector-p set) (bool-vector-ref set category))))

    (define (%analyze-first-fastmap buf fm p)
      ;; `analyze_first_fastmap' (`regex-emacs.c:3108'). Answers
      ;; whether the operation at P matches a character (true) or the
      ;; analysis has to continue (false) - or, for an unresolvable
      ;; case, false, which makes the whole analysis unsafe and
      ;; disables the fastmap.
      ;;----------------------------------------------------------
      (let* ((ins (vector-ref buf p))
             (op (vector-ref ins 0)))
        (cond
         ((= op op-succeed) #f)

         ((= op op-duplicate)
          ;; The backreference matched the empty string; build the map
          ;; from the rest of the path.
          #t)

         ;; The cases which match a character.
         ((= op op-exactn)
          (%fastmap-set! fm (car (vector-ref ins 1)))
          #t)

         ((= op op-anychar)
          ;; All the chars except \n could be added, but the C does
          ;; not bother and neither does this.
          #f)

         ((or (= op op-charset) (= op op-charset-not))
          (let ((cs (vector-ref ins 1))
                (not? (= op op-charset-not)))
            (let loop ((j 0))
              (when (< j 256)
                (let ((member? (re-charset-member-full? cs j)))
                  (if (if not? (not member?) member?)
                      (%fastmap-set! fm j)))
                (loop (+ j 1))))
            ;; Every code point above 255 is possible: for
            ;; `charset_not' because the set is finite, for `charset'
            ;; when it has ranges or classes.
            (when (or not?
                      (> (vector-length (re-charset-ranges cs)) 0)
                      (not (zero? (re-charset-classes cs))))
              (set-re-fastmap-any-nonascii! fm #t))
            #t))

         ((or (= op op-syntaxspec) (= op op-notsyntaxspec))
          ;; Depends on text properties: abort the optimizations.
          #f)

         ((or (= op op-categoryspec) (= op op-notcategoryspec))
          (let ((category (vector-ref ins 1))
                (not? (= op op-notcategoryspec)))
            (let loop ((j 0))
              (when (< j 256)
                (let ((has? (%char-has-category? j category)))
                  (if (if not? (not has?) has?)
                      (%fastmap-set! fm j)))
                (loop (+ j 1))))
            ;; Any code point above 255 may have the category or not.
            (set-re-fastmap-any-nonascii! fm #t)
            #t))

         ;; The empty-matching assertions: "not succeeded yet".
         (else #f))))

    (define (%analyze-first-null buf p)
      ;; `analyze_first_null' (`regex-emacs.c:3280').
      ;;----------------------------------------------------------
      (let ((op (vector-ref (vector-ref buf p) 0)))
        (cond
         ((= op op-succeed) #t)
         ((= op op-duplicate) #t)
         ((memv op (list op-exactn op-anychar op-charset-not op-charset
                         op-syntaxspec op-notsyntaxspec op-categoryspec
                         op-notcategoryspec))
          #t)
         (else #f))))

    (define (%analyze-first buf used p pend fastmap)
      ;; `analyze_first' (`regex-emacs.c:3338'): with a FASTMAP, fill it
      ;; and answer whether the block may match the empty string; with
      ;; #f, answer only the latter. PEND #f means the pattern is
      ;; complete, whose block is the whole buffer.
      ;;----------------------------------------------------------
      (let* ((f (if fastmap
                    (lambda (pos arg) (%analyze-first-fastmap buf arg pos))
                    (lambda (pos arg) (%analyze-first-null buf pos))))
             (safe (if pend
                       (%forall-firstchar buf used p pend f fastmap)
                       (%forall-firstchar-all buf used p f fastmap))))
        (not safe)))

    (define (re-compile-fastmap bufp)
      ;; `re_compile_fastmap' (`regex-emacs.c:3368'): fill BUFP's
      ;; fastmap, and set `fastmap_accurate' and `can_be_null'.
      ;;----------------------------------------------------------
      (let ((fm (re-pattern-buffer-fastmap bufp))
            (buf (re-pattern-buffer-buffer bufp)))
        (if (not fm)
            (error "re-compile-fastmap: no fastmap")
            (let ((used (vector-length buf)))
              (%fastmap-clear! fm)
              (set-re-pattern-buffer-fastmap-accurate! bufp #t)
              (set-re-pattern-buffer-can-be-null!
               bufp (%analyze-first buf used 0 #f fm))
              ;; The boolean table, from the bits just accumulated.
              ;; Emacs reads its fastmap as a byte array; this is the
              ;; nearest Scheme spelling of that array. It is built
              ;; even when no bit is set, because `any-nonascii?'
              ;; alone is a usable map and the loop indexes it for
              ;; every character below 256.
              (let ((bits (re-fastmap-bits fm))
                    (table (make-vector 256 #f)))
                (do ((j 0 (+ j 1))) ((= j 256))
                  (when (logbit? j bits)
                    (vector-set! table j #t)))
                (set-re-fastmap-table! fm table))))))

    ;;----------------------------------------------------------------
    ;; `regex_compile' (`regex-emacs.c:1742'-`:2736')
    ;;----------------------------------------------------------------
    ;;
    ;; The C compiles into a byte array with a moving pointer B and
    ;; relative jump offsets; here B is the instruction buffer's fill
    ;; count and every jump target is an absolute instruction index.
    ;; The C's `INSERT_JUMP` computes a relative offset from two old
    ;; pointers, which comes to the same thing as supplying the new
    ;; instruction's target in the post-insertion numbering (see
    ;; `%insert-at!').
    ;;
    ;; **The charset's work area** is the C's `range_table_work': a
    ;; set of inclusive code-point ranges plus the class bits, with
    ;; the C's "extend an adjacent range when the translated character
    ;; lands beside one" rule (the continuity mechanism
    ;; `SETUP_*_RANGE' exist for). The bitmap is a 256-bit integer,
    ;; the same 256 characters the C's bitmap covers.
    ;;
    ;; **Nothing here compiles a unibyte pattern.** The C's
    ;; `!multibyte` branches and its `CHAR_BYTE8_P` arms exist for a
    ;; unibyte regexp string; this tree's patterns are Scheme strings
    ;; of code points, so `multibyte' is always true. Those arms are
    ;; marked where the C has them.
    ;;--------------------------------------------------------------

    (define %re-dup-max 65535)
    (define %max-regnum 255)

    (define-record-type <regexp-compile-error>
      (make-regexp-compile-error code)
      regexp-compile-error?
      (code regexp-compile-error-code))

    (define (%regexp-error-message code)
      ;; The C's `re_error_msgid' (`regex-emacs.c:857').
      ;;----------------------------------------------------------
      (case code
        ((noerror) "Success")
        ((nomatch) "No match")
        ((badpat) "Invalid regular expression")
        ((ecollate) "Invalid collation character")
        ((ectype) "Invalid character class name")
        ((eescape) "Trailing backslash")
        ((esubreg) "Invalid back reference")
        ((ebrack) "Unmatched [ or [^")
        ((eparen) "Unmatched ( or \\(")
        ((ebrace) "Unmatched \\{")
        ((badbr) "Invalid content of \\{\\}")
        ((erange) "Invalid range end")
        ((espace) "Memory exhausted")
        ((badrpt) "Invalid preceding regular expression")
        ((eend) "Premature end of regular expression")
        ((esize) "Regular expression too big")
        ((erparen) "Unmatched ) or \\)")
        ((erangex) "Range striding over charsets")
        ((esizebr) "Invalid content of \\{\\}")
        (else "Invalid regular expression")))

    (define (%translate-code translate c)
      ;; `char_table_translate' (`character.h:592') through the C's
      ;; `TRANSLATE' macro: a value that is not a character means C
      ;; itself.
      ;;----------------------------------------------------------
      (if translate
          (let ((v (char-table-ref translate c)))
            (if (integer? v) v c))
          c))

    (define (re-translate-vector bufp)
      ;; The compiled pattern's translate table for characters 0..255,
      ;; built once and kept on the buffer. **A host-compensation, not
      ;; an Emacs algorithm**: the C's `TRANSLATE' inlines a C tree
      ;; walk, while `char-table-ref' here is a 64 ns procedure call
      ;; (measured) against a vector's 11 ns, and folded matching
      ;; asks it once per character. The values are exactly what
      ;; `%translate-code' answers for those characters; a character
      ;; above 255 still goes through the table.
      ;;----------------------------------------------------------
      (or (re-pattern-buffer-translate-vec bufp)
          (let ((table (re-pattern-buffer-translate bufp)))
            (and table
                 (let ((v (make-vector 256 #f)))
                   (do ((i 0 (+ i 1))) ((= i 256))
                     (vector-set! v i (%translate-code table i)))
                   (set-re-pattern-buffer-translate-vec! bufp v)
                   v)))))

    ;;----------------------------------------------------------------
    ;; The charset work area (`range_table_work')
    ;;----------------------------------------------------------------
    (define-record-type <charset-work>
      (%make-charset-work map ranges used bits)
      charset-work?
      (map charset-work-map set-charset-work-map!)
      ;; Ranges in reverse insertion order, each a pair (FROM . TO).
      (ranges charset-work-ranges set-charset-work-ranges!)
      (used charset-work-used set-charset-work-used!)
      (bits charset-work-bits set-charset-work-bits!))

    (define (%new-charset-work)
      (%make-charset-work 0 '() 0 0))

    (define (%work-clear! w)
      (set-charset-work-map! w 0)
      (set-charset-work-ranges! w '())
      (set-charset-work-used! w 0)
      (set-charset-work-bits! w 0))

    (define (%work-set-bit! w c)
      ;; `SET_LIST_BIT'. A code point past the bitmap belongs in the
      ;; range table; the C never calls it with one, and adding a
      ;; singleton range keeps this sound if one ever arrives.
      ;;----------------------------------------------------------
      (if (< c 256)
          (set-charset-work-map! w (logior (charset-work-map w) (ash 1 c)))
          (%work-add-range! w c c)))

    (define (%work-add-range! w from to)
      ;; `SET_RANGE_TABLE_WORK_AREA': a new pair at the end.
      ;;----------------------------------------------------------
      (set-charset-work-ranges! w (cons (cons from to)
                                        (charset-work-ranges w)))
      (set-charset-work-used! w (+ (charset-work-used w) 1)))

    (define (%work-absorb! w c since)
      ;; The C's "extend an adjacent range" loop in `SETUP_UNIBYTE_RANGE'
      ;; and `SETUP_MULTIBYTE_RANGE': scan the pairs added since SINCE,
      ;; newest first, and extend the first one C sits beside; if none,
      ;; add (C . C). The C walks its table from the newest entry
      ;; backwards, which is this list's order.
      ;;----------------------------------------------------------
      (let loop ((rest (charset-work-ranges w))
                 (i (- (charset-work-used w) 1)))
        (cond
         ((< i since) (%work-add-range! w c c))
         (else
          (let ((pair (car rest)))
            (cond ((= c (- (car pair) 1)) (set-car! pair c))
                  ((= c (+ (cdr pair) 1)) (set-cdr! pair c))
                  (else (loop (cdr rest) (- i 1)))))))))

    (define (%work-setup-ascii-range! w from to translate)
      ;; `SETUP_ASCII_RANGE' (`regex-emacs.c:1415').
      ;;----------------------------------------------------------
      (let loop ((c0 from))
        (when (<= c0 to)
          (let ((c1 (%translate-code translate c0)))
            (if (>= c1 128)
                (begin
                  (%work-add-range! w c1 c1)
                  ;; `RE_CHAR_TO_UNIBYTE' is the character itself in
                  ;; 128..255 and -1 beyond.
                  (when (> c1 255) (set! c1 c0))))
            (%work-set-bit! w c1))
          (loop (+ c0 1)))))

    (define (%work-setup-multibyte-range! w from to translate)
      ;; `SETUP_MULTIBYTE_RANGE' (`regex-emacs.c:1475').
      ;;----------------------------------------------------------
      (let ((since (charset-work-used w)))
        (%work-add-range! w from to)
        (let loop ((c0 from))
          (when (<= c0 to)
            (let* ((c1 (%translate-code translate c0))
                   (c2 (if (<= c1 255) c1 #f)))
              (when (and (not c2) (not (= c1 c0)) (<= c0 255))
                (set! c2 c0))
              (when c2 (%work-set-bit! w c2))
              (unless (and (>= c1 from) (<= c1 to))
                (%work-absorb! w c1 since)))
            (loop (+ c0 1))))))

    (define (%work->charset w)
      ;; The finished `<re-charset>': the bitmap, the ranges in the
      ;; order they were added, and the class bits.
      ;;----------------------------------------------------------
      (make-re-charset (charset-work-map w)
                       (list->vector (reverse (charset-work-ranges w)))
                       (charset-work-bits w)))

    ;;----------------------------------------------------------------
    ;; The compiler
    ;;----------------------------------------------------------------
    (define (regex-compile pattern size posix-backtracking
                           whitespace-regexp bufp)
      ;; `regex_compile'. Answers #t on success, raising a
      ;; `<regexp-compile-error>' at every `FREE_STACK_RETURN' the C
      ;; has (the stack and work area need no freeing here).
      ;;----------------------------------------------------------
      (let ((st (%make-compile-state bufp
                                     (re-pattern-buffer-translate bufp)
                                     (make-vector 64 #f) 0
                                     #f #f #f #f 0 '())))
        ;; The C keeps P, PATTERN, PEND and the subpattern trio in
        ;; locals it mutates; so does this, for the same reason - the
        ;; whitespace-regexp substitution swaps the pattern out and
        ;; back.
        (define p 0)
        (define pend size)
        (define cur-pattern pattern)
        (define in-subpattern #f)
        (define main-p 0)
        (define main-pattern pattern)
        (define main-pend size)
        (define beg-interval #f)

        (define (buf) (compile-state-buffer st))
        (define (used) (compile-state-used st))

        (define (free-stack-return! code)
          (raise (make-regexp-compile-error code)))

        (define (patfetch)
          ;; `PATFETCH': the next code point of the current pattern,
          ;; or `REG_EEND' at the end.
          ;;----------------------------------------------------
          (if (= p pend) (free-stack-return! 'eend))
          (let ((ch (string-ref cur-pattern p)))
            (set! p (+ p 1))
            (char->integer ch)))

        (define (fixup-alt-jump!)
          ;; `FIXUP_ALT_JUMP'.
          ;;----------------------------------------------------
          (let ((fixup (compile-state-fixup-alt-jump st)))
            (when fixup
              (%store-jump! st fixup (used)))))

        (define (normal-char c)
          ;; The C's `normal_char:' label.
          ;;----------------------------------------------------
          (let ((pending (compile-state-pending-exact st)))
            (when (or (not pending)
                      ;; Last exactn not at the current position.
                      (not (= (+ pending 1) (used)))
                      ;; The count's room: the C's byte count against
                      ;; MAX_MULTIBYTE_LENGTH becomes a character count
                      ;; here, one slot per character.
                      (>= (length (vector-ref (vector-ref (buf) pending) 1))
                          255)
                      ;; Followed by a repetition operator.
                      (and (< p pend)
                           (let ((next (string-ref cur-pattern p)))
                             (or (char=? next #\*) (char=? next #\+)
                                 (char=? next #\?))))
                      (and (< (+ p 1) pend)
                           (char=? (string-ref cur-pattern p) #\\)
                           (char=? (string-ref cur-pattern (+ p 1)) #\{)))
              (set-compile-state-laststart! st (used))
              (let ((ins (%emit! st op-exactn '() #f)))
                (set-compile-state-pending-exact! st ins)))
            (%exactn-append! st (compile-state-pending-exact st)
                             (%translate-code (compile-state-translate st) c))))

        (define (quantifier c)
          ;; The `+', `?' and `*' case: collapse the repetition
          ;; characters, then emit the loop opcodes the C chooses.
          ;;----------------------------------------------------
          (let ((laststart (compile-state-laststart st)))
            (if (not laststart)
                (begin (set-compile-state-pending-exact! st #f)
                       (normal-char c))
                (let ((zero-times? #f) (many-times? #f) (greedy? #t))
                  (let collapse ()
                    (if (and (char=? (integer->char c) #\?)
                             (or zero-times? many-times?))
                        (set! greedy? #f)
                        (begin
                          (when (not (char=? (integer->char c) #\+))
                            (set! zero-times? #t))
                          (when (not (char=? (integer->char c) #\?))
                            (set! many-times? #t))))
                    (let ((next (and (< p pend)
                                     (string-ref cur-pattern p))))
                      (when (and next (memv next (list #\* #\+ #\?)))
                        (set! c (char->integer next))
                        (set! p (+ p 1))
                        (collapse))))
                  ;; Applied to an empty pattern: nothing to do.
                  (if (= laststart (used))
                      #t
                      (begin
                        (if greedy?
                            (if many-times?
                                (let* ((N (used))
                                       (simple (let ((skip (%skip-one-char
                                                            st laststart)))
                                                 (and skip (= skip N))))
                                       ;; `regex-emacs.c:1963': a
                                       ;; loop that can match the
                                       ;; empty string and is not
                                       ;; `simple' gets the cycle
                                       ;; check (`on_failure_jump_loop');
                                       ;; the truthiness of
                                       ;; `analyze_first' is the
                                       ;; other way round - it
                                       ;; answers "can be null" - so
                                       ;; the C's `!analyze_first'
                                       ;; is a `not' here.
                                       (ofj (if (or simple
                                                    (not (%analyze-first
                                                          (buf) N laststart N #f)))
                                                op-on-failure-jump-prememo
                                                op-on-failure-jump-loop))
                                       (startoffset 0))
                                  (when (and (not zero-times?) simple)
                                    ;; Turn `P+' into `PP*': copy the
                                    ;; one-character operand, and let
                                    ;; the inserted on-failure jump
                                    ;; guard the copy.
                                    (set! startoffset (- (used) laststart))
                                    (let ((source laststart)
                                          (n (used)))
                                      (let copy ((i source))
                                        (when (< i n)
                                          (let ((ins (vector-ref (buf) i)))
                                            (%emit! st (vector-ref ins 0)
                                                    (vector-ref ins 1)
                                                    (vector-ref ins 2)))
                                          (copy (+ i 1)))))
                                    (set! zero-times? #t))
                                  (if (not zero-times?)
                                      ;; A `+' loop.
                                      (begin
                                        (%emit! st ofj (+ (used) 2) #f)
                                        (%emit! st op-jump laststart #f))
                                      (let* ((N2 (used))
                                             (at (+ laststart startoffset)))
                                        (%insert-at!
                                         st at
                                         (vector (if simple
                                                     op-on-failure-jump-smart
                                                     ofj)
                                                 (+ N2 2) #f))
                                        (%emit! st op-jump at #f))))
                                ;; A simple `?' pattern.
                                (let ((N (used)))
                                  (%insert-at! st laststart
                                               (vector op-on-failure-jump-nomemo
                                                       (+ N 1) #f))))
                            ;; Not greedy.
                            (if many-times?
                                (let* ((emptyp (%analyze-first
                                                (buf) (used) laststart (used) #f))
                                       (target-laststart laststart))
                                  (when emptyp (%emit! st op-no-op #f #f))
                                  (%emit! st (if emptyp
                                                 op-on-failure-jump-nastyloop
                                                 op-on-failure-jump-prememo)
                                          laststart #f)
                                  (when zero-times?
                                    ;; Jump to the end of the loop, which
                                    ;; after the insertion is the
                                    ;; conditional jump itself.
                                    (let ((N (used)))
                                      (%insert-at! st laststart
                                                   (vector op-jump N #f)))))
                                (let ((N (used)))
                                  ;; non-greedy a??
                                  (%insert-at! st laststart
                                               (vector op-jump (+ N 1) #f))
                                  (%insert-at! st laststart
                                               (vector op-on-failure-jump-nomemo
                                                       (+ laststart 2) #f)))))
                        (set-compile-state-pending-exact! st #f)
                        #t))))))

        (define (bracket)
          ;; The `[' case.
          ;;----------------------------------------------------
          (let ((w (%new-charset-work)))
            (if (= p pend) (free-stack-return! 'ebrack))
            (let ((not? (char=? (string-ref cur-pattern p) #\^)))
              (when not? (set! p (+ p 1)))
              (let ((p1 p))
                (let parse ()
                  (if (= p pend) (free-stack-return! 'ebrack))
                  (let* ((p2 p)
                         (cc (call-with-values
                                 (lambda ()
                                   (re-wctype-parse cur-pattern p pend))
                               (lambda (cc newp) (set! p newp) cc))))
                    (cond
                     ((and cc (not (= cc recc-error)))
                      (if (= p pend) (free-stack-return! 'ebrack))
                      (let loop ((ch 0))
                        (when (< ch 128)
                          (when (re-iswctype ch cc)
                            (%work-set-bit! w ch)
                            (let ((c1 (%translate-code
                                       (compile-state-translate st) ch)))
                              (unless (= c1 ch)
                                ;; `ASCII_CHAR_P' then
                                ;; `RE_CHAR_TO_UNIBYTE'.
                                (when (<= c1 255)
                                  (%work-set-bit! w c1)))))
                          (loop (+ ch 1))))
                      (set-charset-work-bits!
                       w (logior (charset-work-bits w)
                                 (%re-charset-class-bit cc)))
                      (when (or (= cc recc-space) (= cc recc-word))
                        (set-re-pattern-buffer-used-syntax! bufp #t))
                      (parse))
                     ((and cc (= cc recc-error))
                      (free-stack-return! 'ectype))
                     (else
                      (let ((c (patfetch)))
                        ;; Could be the end of the bracket expression.
                        ;; `[]' so far has p2 == p1.
                        (if (and (char=? (integer->char c) #\])
                                 (not (= p2 p1)))
                            #f
                            (begin
                              (let ((c1 (if (and (< (+ p 1) pend)
                                                 (char=? (string-ref cur-pattern p) #\-)
                                                 (not (char=? (string-ref cur-pattern (+ p 1)) #\])))
                                            (begin
                                              ;; Discard the '-'.
                                              (patfetch)
                                              ;; Fetch the range's end.
                                              (patfetch))
                                            c)))
                                (when (<= c c1)
                                  (when (< c 128)
                                    (let* ((ch (min 127 c1))
                                           (translate
                                            (compile-state-translate st)))
                                      (%work-setup-ascii-range! w c ch translate)
                                      (set! c (+ ch 1))))
                                  (when (<= c c1)
                                    ;; The C's `CHAR_BYTE8_P' arms are
                                    ;; for unibyte patterns, which this
                                    ;; engine has none of.
                                    (%work-setup-multibyte-range!
                                     w c c1 (compile-state-translate st)))))
                              (parse)))))))))
              ;; Build the real charset from the work area.
              (let ((cs (%work->charset w)))
                (set-compile-state-laststart! st (used))
                (%emit! st (if not? op-charset-not op-charset) cs #f))
              (set-compile-state-pending-exact! st #f))))

        (define (escape c)
          ;; The `\\' case: C is the character after the backslash,
          ;; already fetched by the caller (`PATFETCH' follows the
          ;; `p == pend' test there).
          ;;----------------------------------------------------
          (let ()
            (case (integer->char c)
             ((#\()
              (let ((shy? #f) (regnum 0))
                (when (< (+ p 1) pend)
                  (when (char=? (string-ref cur-pattern p) #\?)
                    (patfetch)           ; gobble the '?'
                    (let parse-regnum ()
                      (unless shy?
                        (let ((ch (patfetch)))
                          (case (integer->char ch)
                           ((#\:) (set! shy? #t))
                           ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
                            (when (and (= ch (char->integer #\0))
                                       (= regnum 0))
                              (free-stack-return! 'badpat))
                            (let ((next (+ (* regnum 10)
                                           (- ch (char->integer #\0)))))
                              (when (> next 65535)
                                (free-stack-return! 'esize))
                              (set! regnum next)))
                           (else (free-stack-return! 'badpat)))
                          (parse-regnum))))))
                (if (not shy?)
                    (begin
                      (set-compile-state-nsub! st (+ (compile-state-nsub st) 1))
                      (set! regnum (compile-state-nsub st)))
                    (if (> regnum 0)
                        ;; Explicitly numbered, not shy.
                        ;;
                        ;; **`(> regnum 0)' and not `(if regnum ...)'**:
                        ;; the C's test is an integer's, and Scheme's 0
                        ;; is true. A shy group at `re_nsub' 0 gets
                        ;; regnum 0, which took this branch, and a
                        ;; *nested* shy group then found the outer
                        ;; frame's 0 in the compile stack and raised
                        ;; `badpat' - so every nested `\(?:...\)' was
                        ;; "Invalid regular expression".
                        (begin
                          (set! shy? #f)
                          (if (> regnum (compile-state-nsub st))
                              (set-compile-state-nsub! st regnum)
                              (when (%group-in-compile-stack st regnum)
                                (free-stack-return! 'badpat))))
                        (set! regnum (- (compile-state-nsub st)))))
                ;; Push the values to restore at `\)'.
                (set-compile-state-stack! st (cons (list (compile-state-begalt st)
                                  (compile-state-fixup-alt-jump st)
                                  ;; The C saves `b' here: the group's own
                                  ;; start, before its `start_memory', which
                                  ;; is what a following quantifier wraps.
                                  (used)
                                  regnum)
                            (compile-state-stack st)))
                (when (and (<= regnum %max-regnum) (> regnum 0))
                  (%emit! st op-start-memory regnum #f))
                (set-compile-state-fixup-alt-jump! st #f)
                (set-compile-state-laststart! st #f)
                (set-compile-state-begalt! st (used))
                (set-compile-state-pending-exact! st #f)))

             ((#\))
              (if (null? (compile-state-stack st))
                  (free-stack-return! 'erparen))
              (fixup-alt-jump!)
              (if (null? (compile-state-stack st))
                  (free-stack-return! 'erparen))
              (let ((frame (car (compile-state-stack st))))
                (set-compile-state-stack! st (cdr (compile-state-stack st)))
                (set-compile-state-begalt! st (car frame))
                (set-compile-state-fixup-alt-jump! st (cadr frame))
                (set-compile-state-laststart! st (caddr frame))
                (let ((regnum (cadddr frame)))
                  (set-compile-state-pending-exact! st #f)
                  (when (and (<= regnum %max-regnum) (> regnum 0))
                    (%emit! st op-stop-memory regnum #f)))))

             ((#\|)
              ;; Insert before the previous alternative a jump to this
              ;; one if the former fails.
              (let ((N (used)))
                (%insert-at! st (compile-state-begalt st)
                             (vector op-on-failure-jump-nomemo (+ N 2) #f)))
              (set-compile-state-pending-exact! st #f)
              (fixup-alt-jump!)
              ;; Reserve the jump that ends this alternative; the next
              ;; alternative or the group's end fills it in.
              (set-compile-state-fixup-alt-jump! st (used))
              (%emit! st op-jump #f #f)
              (set-compile-state-laststart! st #f)
              (set-compile-state-begalt! st (used)))

             ((#\{)
              (let ((lower 0) (upper -1))
                (set! beg-interval p)
                (let-values (((value terminator) (get-interval-count lower)))
                  (set! lower value)
                  (set! c-cache terminator))
                (if (char=? (integer->char c-cache) #\,)
                    (let-values (((value terminator)
                                  (get-interval-count upper)))
                      (set! upper value)
                      (set! c-cache terminator))
                    (set! upper lower))
                (if (or (< lower 0)
                        (and (>= upper 0) (< upper lower))
                        (not (char=? (integer->char c-cache) #\\)))
                    (free-stack-return! 'badbr))
                (if (= p pend) (free-stack-return! 'eescape))
                (if (not (char=? (string-ref cur-pattern p) #\}))
                    (free-stack-return! 'badbr))
                (set! p (+ p 1))
                (let ((laststart (compile-state-laststart st)))
                  (cond
                   ((not laststart)
                    ;; Invalid as an interval: the `{' is a literal.
                    (set! p beg-interval)
                    (set! beg-interval #f)
                    (normal-char (char->integer #\{)))
                   ((= upper 0)
                    ;; Drop the subpattern altogether.
                    (set-compile-state-used! st laststart)
                    (set-compile-state-pending-exact! st #f)
                    (set! beg-interval #f))
                   ((and (= lower 1) (= upper 1))
                    (set-compile-state-pending-exact! st #f)
                    (set! beg-interval #f))
                   (else
                    (interval lower upper laststart)
                    (set-compile-state-pending-exact! st #f)
                    (set! beg-interval #f))))))

             ((#\=)
              (set-compile-state-laststart! st (used))
              (%emit! st op-at-dot #f #f))

             ((#\s)
              (set-compile-state-laststart! st (used))
              (let* ((ch (patfetch))
                     (code (%spec-code (integer->char ch))))
                (%emit! st op-syntaxspec code #f)))

             ((#\S)
              (set-compile-state-laststart! st (used))
              (let* ((ch (patfetch))
                     (code (%spec-code (integer->char ch))))
                (%emit! st op-notsyntaxspec code #f)))

             ((#\c)
              (set-compile-state-laststart! st (used))
              (%emit! st op-categoryspec (patfetch) #f))

             ((#\C)
              (set-compile-state-laststart! st (used))
              (%emit! st op-notcategoryspec (patfetch) #f))

             ((#\w)
              (set-compile-state-laststart! st (used))
              (%emit! st op-syntaxspec sword #f))

             ((#\W)
              (set-compile-state-laststart! st (used))
              (%emit! st op-notsyntaxspec sword #f))

             ((#\<)
              (set-compile-state-laststart! st (used))
              (%emit! st op-wordbeg #f #f))

             ((#\>)
              (set-compile-state-laststart! st (used))
              (%emit! st op-wordend #f #f))

             ((#\_)
              (set-compile-state-laststart! st (used))
              (let ((ch (patfetch)))
                (cond ((char=? (integer->char ch) #\<)
                       (%emit! st op-symbeg #f #f))
                      ((char=? (integer->char ch) #\>)
                       (%emit! st op-symend #f #f))
                      (else (free-stack-return! 'badpat)))))

             ((#\b)
              (set-compile-state-laststart! st (used))
              (%emit! st op-wordbound #f #f))

             ((#\B)
              (set-compile-state-laststart! st (used))
              (%emit! st op-notwordbound #f #f))

             ((#\`)
              ;; Postfix ops after \` become literals, as for ^.
              (set-compile-state-laststart! st #f)
              (%emit! st op-begbuf #f #f))

             ((#\')
              (set-compile-state-laststart! st (used))
              (%emit! st op-endbuf #f #f))

             ((#\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
              (let ((reg (- c (char->integer #\0))))
                (if (or (> reg (compile-state-nsub st))
                        (< reg 1)
                        (%group-in-compile-stack st reg))
                    (free-stack-return! 'esubreg))
                (set-compile-state-laststart! st (used))
                (%emit! st op-duplicate reg #f)))

             (else
              ;; "You might think it would be useful for \ to mean not
              ;; to translate; but if we don't translate it it will
              ;; never match anything."
              (normal-char c)))))

        (define (interval lower upper laststart)
          ;; The nontrivial `\{n,m\}' code, after `laststart' is known
          ;; to exist and `{0}' and `{1}' are handled.
          ;;----------------------------------------------------
          (let* ((nbytes (cond ((< upper 0) 1) ((> upper 1) 1) (else 0)))
                 (startoffset 0))
            (if (= lower 0)
                (let ((N (used)))
                  (%insert-at! st laststart
                               (vector op-on-failure-jump-loop
                                       (+ N 1 nbytes) #f)))
                (let ((N (used)))
                  ;; Initialize the lower bound, and jump to the
                  ;; `jump_n' we might insert below.
                  (%insert-at! st laststart
                               (vector op-succeed-n (+ N 1 nbytes) lower))
                  ;; The initializer goes before the `succeed_n', which
                  ;; the insertion pushes to LASTSTART+1.
                  (%insert-at! st laststart
                               (vector op-set-number-at (+ laststart 1)
                                       lower))
                  (set! startoffset 1)))
            (if (< upper 0)
                ;; A negative upper bound is infinity: a plain jump.
                (%emit! st op-jump (+ laststart startoffset) #f)
                (when (> upper 1)
                  ;; More than one repetition: jump back to the
                  ;; `succeed_n' `upper - 1' times.
                  (let ((jump-at (used)))
                    (%emit! st op-jump-n (+ laststart startoffset)
                            (- upper 1))
                    ;; Reinitialize the bounds at the top of the loop.
                    ;; The insertion pushes the `jump_n' to JUMP-AT+1.
                    (%insert-at! st laststart
                                 (vector op-set-number-at (+ jump-at 1)
                                         (- upper 1))))))))

        ;; GET_INTERVAL_COUNT leaves its terminating character for the
        ;; caller's `c != '\\'' test.
        (define c-cache 0)
        (define (get-interval-count current)
          ;; `GET_INTERVAL_COUNT' (`regex-emacs.c:1508'): the digits at
          ;; P into NUM, answering the number and the first non-digit.
          ;;----------------------------------------------------
          (if (= p pend) (free-stack-return! 'ebrace))
          (let ((ch (patfetch)))
            (let loop ((num current) (ch ch))
              (if (and (>= ch (char->integer #\0))
                       (<= ch (char->integer #\9)))
                  (let ((digit (- ch (char->integer #\0))))
                    (when (< num 0) (set! num 0))
                    ;; The C's `RE_DUP_MAX / 10 - (RE_DUP_MAX % 10 < D) < num'.
                    (when (> num
                             (- (quotient %re-dup-max 10)
                                (if (< (remainder %re-dup-max 10) digit)
                                    1 0)))
                      (free-stack-return! 'esizebr))
                    (set! num (+ (* num 10) digit))
                    (if (= p pend) (free-stack-return! 'ebrace))
                    (loop num (patfetch)))
                  (values num ch)))))

        (define (main-loop)
          (cond
           ((= p pend)
            (if in-subpattern
                (begin
                  ;; Pop back to the main regexp.
                  (set! in-subpattern #f)
                  (set! cur-pattern main-pattern)
                  (set! p main-p)
                  (set! pend main-pend)
                  (main-loop))
                (finish)))
           (else
            (let ((c (patfetch)))
              (case (integer->char c)
               ((#\space)
                (if (or (not whitespace-regexp) in-subpattern)
                    (normal-char c)
                    ;; Peek past following spaces.
                    (let scan ((p1 p))
                      (cond
                       ((and (< p1 pend)
                             (char=? (string-ref cur-pattern p1) #\space))
                        (scan (+ p1 1)))
                       (else
                        ;; If the spaces are followed by a repetition
                        ;; op, treat them normally.
                        (if (and (< p1 pend)
                                 (let ((ch (string-ref cur-pattern p1)))
                                   (or (char=? ch #\*) (char=? ch #\+)
                                       (char=? ch #\?)))
                                 )
                            (normal-char c)
                            (if (and (< (+ p1 1) pend)
                                     (char=? (string-ref cur-pattern p1) #\\)
                                     (char=? (string-ref cur-pattern (+ p1 1)) #\{))
                                (normal-char c)
                                ;; Replace the spaces with the
                                ;; whitespace regexp.
                                (begin
                                  (set! in-subpattern #t)
                                  (set! main-p p1)
                                  (set! main-pend pend)
                                  (set! main-pattern cur-pattern)
                                  (set! cur-pattern whitespace-regexp)
                                  (set! p 0)
                                  (set! pend (string-length whitespace-regexp))))))))))

               ((#\^)
                (if (or (= p 1) (%at-begline-loc? cur-pattern p))
                    (begin
                      ;; Postfix ops after ^ become literals.
                      (set-compile-state-laststart! st #f)
                      (%emit! st op-begline #f #f))
                    (normal-char c)))

               ((#\$)
                (if (or (= p pend) (%at-endline-loc? cur-pattern p pend))
                    (begin
                      (set-compile-state-laststart! st (used))
                      (%emit! st op-endline #f #f))
                    (normal-char c)))

               ((#\+ #\? #\*)
                (quantifier c))

               ((#\.)
                (set-compile-state-laststart! st (used))
                (%emit! st op-anychar #f #f))

               ((#\[)
                (bracket))

               ((#\\)
                (if (= p pend)
                    (free-stack-return! 'eescape)
                    (escape (patfetch))))

               (else
                (normal-char c)))
              (main-loop)))))

        (define (finish)
          (fixup-alt-jump!)
          (if (not (null? (compile-state-stack st)))
              (free-stack-return! 'eparen))
          (if (not posix-backtracking)
              (%emit! st op-succeed #f #f))
          ;; Trim the buffer to what is used: the fastmap and the
          ;; matcher take the vector's length as `bufp->used'.
          (set-re-pattern-buffer-buffer!
           bufp (vector-copy (buf) 0 (used)))
          (set-re-pattern-buffer-nsub! bufp (compile-state-nsub st))
          #t)

        ;; `regex_compile''s prologue.
        (set-re-pattern-buffer-fastmap-accurate! bufp #f)
        (set-re-pattern-buffer-used-syntax! bufp #f)
        (set-re-pattern-buffer-nsub! bufp 0)
        (set-compile-state-begalt! st 0)
        ;; **Guile 3.0.11 miscompiles `main-loop` when the binding is a
        ;; constant local procedure**: the compiled `regex-compile`
        ;; segfaults on its first call - at O0, O1 and O2 alike, so it
        ;; is not the inliner. The module loads; the crash is inside
        ;; `scm_call_n` running the compiled procedure. Marking the
        ;; binding as assigned (Scheme's "the variable may change") is
        ;; what avoids it, and **only `main-loop` needs it**: removing
        ;; any of the other seven self-assignments this used to carry
        ;; changes nothing, and adding an unrelated one does not help.
        ;; The C has `main_loop` as a label in one function and no such
        ;; distinction to make. Reducing this to one line cost no
        ;; measurable compile time.
        (set! main-loop main-loop)
        (main-loop)))

    (define (re-compile-pattern pattern size posix-backtracking
                                whitespace-regexp bufp)
      ;; `re_compile_pattern' (`regex-emacs.c:5774'): #f on success,
      ;; else the C's message - which the caller signals as
      ;; `invalid-regexp'.
      ;;----------------------------------------------------------
      (guard (e ((regexp-compile-error? e)
                 (%regexp-error-message (regexp-compile-error-code e))))
        (regex-compile pattern size posix-backtracking whitespace-regexp bufp)
        #f))

    ;;----------------------------------------------------------------
    ;; The matcher (`regex-emacs.c:4081'-`:5761')
    ;;----------------------------------------------------------------
    ;;
    ;; The C matches against one or two strings; this engine matches a
    ;; single `<re-text>', so STRING1/SIZE1/END1 and the PREFETCH
    ;; switch between segments collapse into one text and STOP. The
    ;; failure stack, the register save/restore, the memoization
    ;; counters and the infinite-loop check are the C's.
    ;;
    ;; **Departures, named**: the memoization table is indexed by
    ;; instruction index (the C divides a byte offset by three), which
    ;; changes only how finely the failure counts are kept; and the
    ;; `nchars` redisplay-tick accounting is not carried because
    ;; nothing here is the redisplay.
    ;;--------------------------------------------------------------
    (define (%re-text-ref text i)
      ;; A code point, through the substrate the constructor recorded:
      ;; a string reads `string-ref', a buffer reads its store through
      ;; the gap, and only an arbitrary `make-re-text' pays the closure
      ;; call. This is the matcher's and the fastmap's per-character
      ;; read; the C's `FETCH_CHAR' is the buffer branch.
      ;;----------------------------------------------------------
      (let ((s (re-text-string text)))
        (if s
            (char->integer (string-ref s i))
            (let ((b (re-text-buffer text)))
              (if b
                  (let* ((store (vector-ref b 0))
                         (gpt (vector-ref b 1))
                         (gap (vector-ref b 2))
                         (base (vector-ref b 3))
                         (p (+ base i)))
                    (if (< p gpt)
                        (u32vector-ref store p)
                        (u32vector-ref store (+ p gap))))
                  ((re-text-ref text) i))))))

    (define (re-text-at text i)
      (if (and (>= i 0) (< i (re-text-length text)))
          (%re-text-ref text i)
          #f))

    ;;----------------------------------------------------------------
    ;; The failure stack
    ;;----------------------------------------------------------------
    ;;
    ;; Each element is tagged: `pat' an instruction index, `pos' a text
    ;; position, `int' an integer, `nil' the C's NULL string (a
    ;; keep-string jump), `cptr' a counter's location (an instruction
    ;; whose ARG2 is the counter).
    ;;--------------------------------------------------------------
    (define-record-type <failure-stack>
      (make-failure-stack entries avail frame pop-str)
      failure-stack?
      ;; **Two slots per entry, tag then value**, in one flat vector -
      ;; the C's `fail_stack.stack' is likewise one flat array of
      ;; unions, not a list. The entries used to be `(tag . value)'
      ;; pairs, so every push consed: a failing search pushes on every
      ;; attempt and pops on every backtrack, and the conses were the
      ;; last allocation left in the matcher after the vectors and
      ;; closures were made per search. `entries' holds
      ;; `TAG VALUE TAG VALUE ...'.
      ;;----------------------------------------------------------
      (entries failure-stack-entries set-failure-stack-entries!)
      (avail failure-stack-avail set-failure-stack-avail!)
      (frame failure-stack-frame set-failure-stack-frame!)
      ;; POP-STR is the saved text position of the last popped failure
      ;; point. `%pop-failure-point!' used to answer it with the
      ;; pattern index through `values', and `fail!' paid a
      ;; multiple-values box on every backtrack; the C passes both to
      ;; POP_FAILURE_POINT by address.
      (pop-str failure-stack-pop-str set-failure-stack-pop-str!))

    (define (%new-failure-stack)
      ;; `INIT_FAIL_STACK' (`regex-emacs.c:934'): "INIT_FAILURE_ALLOC"
      ;; entries (`:900') - **20**, not the 800 this started at. The
      ;; stack grows by doubling when a pattern needs more
      ;; (`GROW_FAIL_STACK'), and the C's is `SAFE_ALLOCA' - freed with
      ;; the frame. A Scheme vector is GC-allocated, so an oversized
      ;; starting vector is paid for on *every* match attempt: 800
      ;; entries, times one attempt per start position, was 190 KB of
      ;; a 284 KB failing search.
      ;;
      ;; 40 slots is 20 entries, two slots each.
      ;;----------------------------------------------------------
      (make-failure-stack (make-vector 40 #f) 0 0 #f))

    (define (%fail-stack-empty? fs)
      (zero? (failure-stack-frame fs)))

    (define (%fail-stack-reset! fs)
      ;; `INIT_FAIL_STACK' (`regex-emacs.c:934') without the
      ;; allocation: the storage is kept, the counters start over.
      ;; This is what lets one match attempt after another reuse the
      ;; same stack - and the C's `SAFE_ALLOCA' stack is likewise
      ;; reuse without GC.
      ;;----------------------------------------------------------
      (set-failure-stack-avail! fs 0)
      (set-failure-stack-frame! fs 0))

    (define (%fail-stack-ensure! fs extra)
      ;; `GROW_FAIL_STACK' (`regex-emacs.c:1003') for EXTRA more
      ;; entries, answering the entries vector - which moves. The
      ;; caller writes its entries straight into it, as the C's
      ;; PUSH_FAILURE_ITEM macro does; there is no per-entry
      ;; procedure call left.
      ;;----------------------------------------------------------
      (let* ((entries (failure-stack-entries fs))
             (avail (failure-stack-avail fs))
             (need (* 2 (+ avail extra)))
             (n (vector-length entries)))
        (if (<= need n)
            entries
            (let ((new (make-vector (max need (* 2 n)) #f)))
              (let loop ((i 0))
                (when (< i n)
                  (vector-set! new i (vector-ref entries i))
                  (loop (+ i 1))))
              (set-failure-stack-entries! fs new)
              new))))

    (define (%entry-tag fs i)
      (vector-ref (failure-stack-entries fs) (* 2 i)))

    (define (%entry-value fs i)
      (vector-ref (failure-stack-entries fs) (+ (* 2 i) 1)))

    (define (%push-failure-point! fs pat-index str)
      ;; PUSH_FAILURE_POINT: the frame index, the string (or the NULL
      ;; marker), and the pattern. The three entries go into the
      ;; vector in one step, as the C's PUSH_FAILURE_ITEM macro does -
      ;; this is the hottest push in the matcher, and calling a
      ;; per-entry procedure here was 20% of a failing search.
      ;;----------------------------------------------------------
      ;; The capacity check is inline so the usual push - there is
      ;; room - does not call `%fail-stack-ensure!'; the growth path
      ;; still does.
      (let* ((entries (failure-stack-entries fs))
             (avail (failure-stack-avail fs)))
        (when (>= (* 2 (+ avail 3)) (vector-length entries))
          (set! entries (%fail-stack-ensure! fs 3)))
        (let ((i (* 2 avail)))
          (vector-set! entries i 'int)
          (vector-set! entries (+ i 1) (failure-stack-frame fs))
          (vector-set! entries (+ i 2) (if str 'pos 'nil))
          (vector-set! entries (+ i 3) str)
          (vector-set! entries (+ i 4) 'pat)
          (vector-set! entries (+ i 5) pat-index)
          (set-failure-stack-avail! fs (+ avail 3))
          (set-failure-stack-frame! fs (+ avail 3)))))

    (define (%push-failure-reg! fs regstart regend num)
      ;; PUSH_FAILURE_REG.
      ;;----------------------------------------------------------
      (let* ((entries (failure-stack-entries fs))
             (avail (failure-stack-avail fs)))
        (when (>= (* 2 (+ avail 3)) (vector-length entries))
          (set! entries (%fail-stack-ensure! fs 3)))
        (let ((i (* 2 avail)))
          (vector-set! entries i 'pos)
        (vector-set! entries (+ i 1) (vector-ref regstart num))
        (vector-set! entries (+ i 2) 'pos)
        (vector-set! entries (+ i 3) (vector-ref regend num))
          (vector-set! entries (+ i 4) 'int)
          (vector-set! entries (+ i 5) num)
          (set-failure-stack-avail! fs (+ avail 3)))))

    (define (%push-number! fs pat counter)
      ;; PUSH_NUMBER: the old value, the counter's location, and -1.
      ;;----------------------------------------------------------
      (let* ((entries (failure-stack-entries fs))
             (avail (failure-stack-avail fs)))
        (when (>= (* 2 (+ avail 3)) (vector-length entries))
          (set! entries (%fail-stack-ensure! fs 3)))
        (let ((i (* 2 avail)))
          (vector-set! entries i 'int)
          (vector-set! entries (+ i 1) counter)
        (vector-set! entries (+ i 2) 'cptr)
        (vector-set! entries (+ i 3) pat)
          (vector-set! entries (+ i 4) 'int)
          (vector-set! entries (+ i 5) -1)
          (set-failure-stack-avail! fs (+ avail 3)))))

    (define (%pop-failure-point! fs pat regstart regend)
      ;; POP_FAILURE_POINT: undo the registers and counters, then
      ;; answer the popped pattern index and leave the saved text
      ;; position in the stack's POP-STR. Inline entry reads for
      ;; the same reason the pushes are inline: this walks the stack
      ;; on every backtrack. -1 means the stack had no failure point
      ;; (`fail!' asks `%fail-stack-empty?' first, so it does not see
      ;; that answer).
      ;;----------------------------------------------------------
      (let loop ((avail (failure-stack-avail fs)))
        (if (< (failure-stack-frame fs) avail)
            (let* ((entries (failure-stack-entries fs))
                   (a1 (- avail 1))
                   (value (vector-ref entries (+ (* 2 a1) 1))))
              (if (= value -1)
                  (let* ((a2 (- a1 1))
                         (loc (vector-ref entries (+ (* 2 a2) 1)))
                         (a3 (- a2 1))
                         (old (vector-ref entries (+ (* 2 a3) 1))))
                    (vector-set! (vector-ref pat loc) 2 old)
                    (set-failure-stack-avail! fs a3)
                    (loop a3))
                  (let* ((a2 (- a1 1))
                         (ev (vector-ref entries (+ (* 2 a2) 1)))
                         (a3 (- a2 1))
                         (sv (vector-ref entries (+ (* 2 a3) 1))))
                    (vector-set! regend value ev)
                    (vector-set! regstart value sv)
                    (set-failure-stack-avail! fs a3)
                    (loop a3))))
            (let* ((entries (failure-stack-entries fs))
                   (a1 (- avail 1))
                   (pat-index (vector-ref entries (+ (* 2 a1) 1)))
                   (a2 (- a1 1))
                   (str-tag (vector-ref entries (* 2 a2)))
                   (str (vector-ref entries (+ (* 2 a2) 1)))
                   (a3 (- a2 1))
                   (frame (vector-ref entries (+ (* 2 a3) 1))))
              (set-failure-stack-avail! fs a3)
              (set-failure-stack-frame! fs frame)
              (set-failure-stack-pop-str! fs (if (eq? str-tag 'nil) #f str))
              pat-index))))

    (define (%check-infinite-loop fs pat pat-cur str-place)
      ;; CHECK_INFINITE_LOOP: walk the frames above the current one
      ;; whose saved string is STR-PLACE or NULL.
      ;;
      ;; PAT is the instruction vector (unused - it is here only because
      ;; the two callers have it to hand); PAT-CUR is the instruction
      ;; index the `on_failure_jump' at the top of the walk came from,
      ;; and the comparison is against a *saved index*. Comparing the
      ;; saved index with the vector instead - which is what this did
      ;; before `c-forward-name''s `c-identifier-key' found it - raised
      ;; `=' on a vector the moment a starred group nested a starred
      ;; alternation, e.g. `\\(\\(a\\)*\\|\\(c\\)\\)*'.
      ;;----------------------------------------------------------
      (let loop ((failure (failure-stack-frame fs)))
        (cond
         ((<= failure 0) #f)
         (else
          (let ((str-tag (%entry-tag fs (- failure 2)))
                (str (%entry-value fs (- failure 2)))
                (pat-saved (%entry-value fs (- failure 1))))
            (if (or (eq? str-tag 'nil)
                    (and (eq? str-tag 'pos)
                         (= str str-place)))
                (if (= pat-saved pat-cur)
                    #t
                    (loop (%entry-value fs (- failure 3))))
                #f))))))

    ;;----------------------------------------------------------------
    ;; Memoization (`regex-emacs.c:4118'-`:4432')
    ;;----------------------------------------------------------------
    ;; `regex-emacs.c:4232''s `struct memo_bits' is `{ unsigned char
    ;; *bytes; int count; }', and `count' has **two meanings**: while
    ;; `bytes' is still NULL it counts the failures seen at this state
    ;; (`:4382'), and once `memo_bits ()' allocates, it is the
    ;; bitset's capacity. The overloading is Emacs's, and so it is
    ;; kept: `bits' is `bytes' (here one element per text position,
    ;; not one bit) and `count' means both.
    (define-record-type <memo-bits>
      (make-memo-bits bits count)
      memo-bits?
      (bits memo-bits-bits set-memo-bits-bits!)
      (count memo-bits-count set-memo-bits-count!))

    (define-record-type <memo>
      (make-memo total-failures max-offset state-failures nb-counters inhibit)
      memo?
      (total-failures memo-total-failures set-memo-total-failures!)
      (max-offset memo-max-offset set-memo-max-offset!)
      (state-failures memo-state-failures set-memo-state-failures!)
      (nb-counters memo-nb-counters set-memo-nb-counters!)
      (inhibit memo-inhibit set-memo-inhibit!))

    (define (%memo-bits-get bs bit)
      (let ((bits (memo-bits-bits bs)))
        (and bits (< bit (memo-bits-count bs))
             (vector-ref bits bit))))

    (define (%memo-bits-set! bs bit)
      ;; `memo_bits_set' (`:4271'): grow the store, then set the bit. A
      ;; `#f' store is the phase-one state - `memo_bits (first)'
      ;; (`:4288') allocating and seeding in one go.
      (if (not (memo-bits-bits bs))
          (let* ((new-count (max (+ bit 1) 16))
                 (new (make-vector new-count #f)))
            (vector-set! new bit #t)
            (set-memo-bits-bits! bs new)
            (set-memo-bits-count! bs new-count))
          (let ((bits (memo-bits-bits bs))
                (count (memo-bits-count bs)))
            (when (>= bit count)
              (let* ((new-count (max (+ bit 1) (* 2 count) 16))
                     (new (make-vector new-count #f)))
                (let loop ((i 0))
                  (when (< i count)
                    (vector-set! new i (vector-ref bits i))
                    (loop (+ i 1))))
                (set-memo-bits-bits! bs new)
                (set-memo-bits-count! bs new-count)
                (set! bits new)))
            (vector-set! (memo-bits-bits bs) bit #t))))

    (define (%new-memo)
      (make-memo 0 0 #f 0 #f))

    (define (%memo-init-failures! memo bufp)
      (let ((n (vector-length (re-pattern-buffer-buffer bufp))))
        (set-memo-nb-counters! memo n)
        (set-memo-state-failures! memo (make-vector n #f))))

    (define (%memo-record-failure! memo pat buf strpos)
      ;; MEMO_BYTES_PER_COUNTER is 3 bytes in the C; an instruction
      ;; index is the equivalent key here.
      ;;----------------------------------------------------------
      (when (<= (memo-max-offset memo) strpos)
        (set-memo-max-offset! memo (+ strpos 1)))
      (if (not (memo-state-failures memo))
          (begin
            (set-memo-total-failures! memo (+ (memo-total-failures memo) 1))
            (when (> (ash (memo-total-failures memo) -1)
                     (memo-max-offset memo))
              (%memo-init-failures! memo buf)))
          (unless (memo-inhibit memo)
            ;; `memo_record_failure' (`:4372'): two phases. A state
            ;; only counts its failures until it has failed more times
            ;; than the furthest string position reached so far; then
            ;; it allocates its bitset, seeds it with this failure and
            ;; promotes a `prememo' opcode, so later visits consult it.
            ;; That threshold is Emacs's ("an arbitrary threshold of 2
            ;; failures per byte before deciding memoization might be
            ;; worthwhile", `:4381').
            (let* ((states (memo-state-failures memo))
                   (failures (vector-ref states pat)))
              (if (and failures (memo-bits-bits failures))
                  (%memo-bits-set! failures strpos)
                  (let ((bs failures))
                    (if (not bs)
                        (begin
                          (set! bs (make-memo-bits #f 0))
                          (vector-set! states pat bs))
                        #f)
                    (set-memo-bits-count! bs (+ (memo-bits-count bs) 1))
                    (when (> (memo-bits-count bs) (memo-max-offset memo))
                      (%memo-bits-set! bs strpos)
                      (when (= (vector-ref (vector-ref (re-pattern-buffer-buffer buf)
                                                       pat)
                                           0)
                               op-on-failure-jump-prememo)
                        (vector-set! (vector-ref (re-pattern-buffer-buffer buf)
                                                 pat)
                                     0 op-on-failure-jump-memo)))))))))

    (define (%memo-has-failed? memo pat str)
      (if (memo-state-failures memo)
          (let ((bs (vector-ref (memo-state-failures memo) pat)))
            (and bs (%memo-bits-get bs str) (not (memo-inhibit memo))))
          #f))

    ;;----------------------------------------------------------------
    ;; `execute_charset' (`regex-emacs.c:3802')
    ;;----------------------------------------------------------------
    (define (%execute-charset cs c corig canon not? class-at pos)
      ;; The bitmap first for a character it can hold, then the class
      ;; bits, then the ranges - the C's order. CLASS-AT reads the
      ;; syntax table at text position POS for the WORD class.
      ;;----------------------------------------------------------
      (cond
       ;; **`logbit?' and not `(logand MAP (ash 1 C))`.** The bitmap
       ;; is a 256-bit integer and `ash' allocates a bignum for every
       ;; character tested; `execute_charset' runs once per character
       ;; per attempt, so that allocation was the dominant cost of a
       ;; failing scan. `logbit?' reads the limb in place. The C tests
       ;; a word of its bitmap; this is the same test at the same
       ;; cost.
       ;;
       ;; The bitmap is tested before the class bits are even read:
       ;; a hit is decisive, and most characters of most patterns are
       ;; ASCII hits.
       ((and (< c 256) (vector-ref (re-charset-table cs) c))
        (not not?))
       (else
        (let ((classes (re-charset-classes cs)))
          (if (and (not (zero? classes))
                   (%re-charset-class-member/canon classes c corig canon
                                                    class-at pos))
              (not not?)
              (let ((ranges (re-charset-ranges cs)))
                (let loop ((i 0))
                  (cond
                   ((>= i (vector-length ranges)) not?)
                   ((and (>= c (car (vector-ref ranges i)))
                         (<= c (cdr (vector-ref ranges i))))
                    (not not?))
                   (else (loop (+ i 1)))))))))))

    (define (%re-charset-class-member/canon bits c corig canon class-at pos)
      ;; The C's class tests and their order (`regex-emacs.c:3837'-
      ;; `:3852'): the case classes read CORIG and consult CANON, every
      ;; other class reads the translated C. `BIT_MULTIBYTE` is
      ;; `(> c 127)` here for the reason
      ;; `%re-charset-class-member?` gives.
      ;;----------------------------------------------------------
      (or (and (not (zero? (logand bits #x20))) (> c 127))
          (and (not (zero? (logand bits #x80))) (%char-alphanumeric? c))
          (and (not (zero? (logand bits #x40))) (%char-alphabetic? c))
          (and (not (zero? (logand bits #x8))) (%char-whitespace? c))
          (and (not (zero? (logand bits #x400))) (%char-blank? c))
          (and (not (zero? (logand bits #x1)))
               (char=? (syntax-class-to-char (logand (class-at c pos) #xff))
                       #\w))
          (and (not (zero? (logand bits #x10)))
               (or (%char-upper-case? corig)
                   (and canon (%char-lower-case? corig))))
          (and (not (zero? (logand bits #x2)))
               (or (%char-lower-case? corig)
                   (and canon (%char-upper-case? corig))))
          (and (not (zero? (logand bits #x4))) (%char-punctuation? c))
          (and (not (zero? (logand bits #x100))) (%char-graphic? c))
          (and (not (zero? (logand bits #x200))) (%char-printable? c))))

    ;;----------------------------------------------------------------
    ;; Mutual exclusion (`regex-emacs.c:3864'-`:4079')
    ;;----------------------------------------------------------------
    (define (%mutually-exclusive-exactn pat p1 p2 class-at)
      (let* ((op1 (vector-ref (vector-ref pat p1) 0))
             (ins2 (vector-ref pat p2))
             (c (if (= (vector-ref ins2 0) op-endline)
                    10
                    (car (vector-ref ins2 1)))))
        (cond
         ((= op1 op-exactn)
          (not (= c (car (vector-ref (vector-ref pat p1) 1)))))
         ((or (= op1 op-charset) (= op1 op-charset-not))
          (not (%execute-charset (vector-ref (vector-ref pat p1) 1)
                                 c c #f (= op1 op-charset-not)
                                 class-at 0)))
         ((and (= op1 op-anychar) (= c 10)) #t)
         (else #f))))

    (define (%mutually-exclusive-charset pat p1 p2)
      (let ((cs1 (vector-ref (vector-ref pat p1) 1))
            (cs2 (vector-ref (vector-ref pat p2) 1)))
        (if (or (> (vector-length (re-charset-ranges cs2)) 0)
                (not (zero? (re-charset-classes cs2))))
            #f
            (let ((op1 (vector-ref (vector-ref pat p1) 0)))
              (cond
               ((= op1 op-charset)
                (zero? (logand (re-charset-map cs1) (re-charset-map cs2))))
               ((= op1 op-charset-not)
                (zero? (logand (re-charset-map cs2)
                               (logand #xffffffffffffffffffffffffffffffff
                                       (lognot (re-charset-map cs1))))))
               (else #f))))))

    (define (%mutually-exclusive-one pat p1 p2 class-at pair)
      ;; `mutually_exclusive_one'. PAIR is (P1 . UNCONSTRAINED), the
      ;; C's `mutexcl_data'.
      ;;----------------------------------------------------------
      (let* ((unconstrained (cdr pair))
             (ins2 (vector-ref pat p2))
             (op2 (vector-ref ins2 0))
             (ins1 (vector-ref pat p1))
             (op1 (vector-ref ins1 0)))
        (define (constrain v)
          (unless v (set-cdr! pair #f))
          v)
        (cond
         ((= op2 op-succeed) unconstrained)
         ((= op2 op-endline)
          (constrain (%mutually-exclusive-exactn pat p1 p2 class-at)))
         ((= op2 op-exactn)
          (%mutually-exclusive-exactn pat p1 p2 class-at))
         ((= op2 op-charset)
          (if (= op1 op-exactn)
              (%mutually-exclusive-exactn pat p2 p1 class-at)
              (%mutually-exclusive-charset pat p1 p2)))
         ((= op2 op-charset-not)
          (cond ((= op1 op-exactn)
                 (%mutually-exclusive-exactn pat p2 p1 class-at))
                ((= op1 op-charset)
                 (%mutually-exclusive-charset pat p2 p1))
                (else #f)))
         ((= op2 op-anychar) #f)
         ((= op2 op-syntaxspec)
          (and (= op1 op-notsyntaxspec)
               (equal? (vector-ref ins1 1) (vector-ref ins2 1))))
         ((= op2 op-notsyntaxspec)
          (and (= op1 op-syntaxspec)
               (equal? (vector-ref ins1 1) (vector-ref ins2 1))))
         ((= op2 op-categoryspec)
          (and (= op1 op-notcategoryspec)
               (equal? (vector-ref ins1 1) (vector-ref ins2 1))))
         ((= op2 op-notcategoryspec)
          (and (= op1 op-categoryspec)
               (equal? (vector-ref ins1 1) (vector-ref ins2 1))))
         ((= op2 op-endbuf) #t)
         ((= op2 op-wordbeg)
          (constrain (and (= op1 op-notsyntaxspec)
                          (equal? (vector-ref ins1 1) sword))))
         ((= op2 op-wordend)
          (constrain (and (= op1 op-syntaxspec)
                          (equal? (vector-ref ins1 1) sword))))
         ((= op2 op-symbeg)
          (constrain (and (= op1 op-notsyntaxspec)
                          (memv (vector-ref ins1 1) (list sword ssymbol)))))
         ((= op2 op-symend)
          (constrain (and (= op1 op-syntaxspec)
                          (memv (vector-ref ins1 1) (list sword ssymbol)))))
         ((memv op2 (list op-at-dot op-begbuf op-wordbound
                          op-notwordbound op-begline))
          (constrain #f))
         ((= op2 op-duplicate) #f)
         (else #f))))

    (define (%mutually-exclusive? bufp p1 p2 class-at)
      ;; `mutually_exclusive_p' (`regex-emacs.c:4071'): "True if 'p1
      ;; matches something' implies 'p2 fails'."
      ;;----------------------------------------------------------
      (let* ((pat (re-pattern-buffer-buffer bufp))
             (n (vector-length pat))
             (pair (cons p1 #t)))
        (if (%forall-firstchar-all
             pat n p2
             (lambda (pos arg)
               (%mutually-exclusive-one pat p1 pos class-at pair))
             #f)
            (cdr pair)
            #f)))

    ;;----------------------------------------------------------------
    ;; `re_match_2_internal' (`regex-emacs.c:4437')
    ;;----------------------------------------------------------------
    (define %match-done (list 'match-done))
    ;; ^ The "the matcher has finished" answer of a branch procedure:
    ;; a unique object, so no match result (an exact integer) can be
    ;; mistaken for it. It replaces the `<match-result>' record and
    ;; the `raise'/`guard' that carried the answer out of the loop.

    (define (%make-class-reader ctx)
      ;; `SYNTAX (c)' at text position POS: through the syntax-table
      ;; property cache for a buffer, the context's table for a string.
      ;;----------------------------------------------------------
      (let ((table (re-context-syntax-table ctx))
            (buffer? (re-context-buffer? ctx))
            (base (re-context-position ctx)))
        (lambda (c pos)
          (if buffer?
              (%class-in (current-buffer) (+ base pos) c)
              (let ((ent (char-table-ref table c)))
                (logand (if (pair? ent) (car ent) ent) #xff))))))

    (define (make-match-attempt bufp text stop ctx)
      ;; One matcher, ready to be run at any number of start
      ;; positions: `re_search_2''s loop calls `re_match_2' once per
      ;; position, and the C pays nothing for the call - it is one
      ;; stack frame. A Scheme `re-match-2' with its helpers as
      ;; internal procedures pays a closure for every helper on every
      ;; call, and the register vectors and failure stack as well.
      ;;
      ;; So everything that depends only on the pattern, the text and
      ;; the context - including the helper closures and the reusable
      ;; vectors - is built once here. The returned procedure takes
      ;; `(POS RE GS)' and resets the mutable attempt state, which is
      ;; the C's `re_match_2_internal' prologue.
      ;;----------------------------------------------------------
      (let* ((pat (re-pattern-buffer-buffer bufp))
             (pend (vector-length pat))
             (translate (re-pattern-buffer-translate bufp))
             ;; The ASCII answers of TRANSLATE, for the arms below that
             ;; translate a character per test; #f when folding is off.
             (translate-vec (if translate (re-translate-vector bufp) #f))
             (len (re-text-length text))
             (num-regs (+ (re-pattern-buffer-nsub bufp) 1))
             (regstart (make-vector num-regs #f))
             (regend (make-vector num-regs #f))
             (best-regstart (make-vector num-regs #f))
             (best-regend (make-vector num-regs #f))
             (fs (%new-failure-stack))
             (memo (%new-memo))
             (best-regs-set? #f)
             (match-end #f)
             ;; The match length, set by `done!' - the C's `return'
             ;; value from `re_match_2_internal'.
             (result #f)
             (class-at (%make-class-reader ctx))
             (p 0)
             (d 0)
             ;; The attempt's own arguments, set by the reset.
             (pos 0)
             (regs #f))

        (define (reset-match-attempt! new-pos new-regs)
          ;; `re_match_2_internal''s prologue: the position, the
          ;; registers, the pattern pointer, the text pointer, and
          ;; every mutable piece the previous attempt left.
          ;;------------------------------------------------------
          (set! pos new-pos)
          (set! regs new-regs)
          (set! p 0)
          (set! d new-pos)
          (set! best-regs-set? #f)
          (set! match-end #f)
          (set! result #f)
          (vector-fill! regstart #f)
          (vector-fill! regend #f)
          (%fail-stack-reset! fs)
          ;; The memo's counters and bits belong to one attempt; its
          ;; storage is re-made lazily by `%memo-init-failures!' if
          ;; the pattern uses memo opcodes.
          (set-memo-total-failures! memo 0)
          (set-memo-max-offset! memo 0)
          (set-memo-state-failures! memo #f)
          (set-memo-nb-counters! memo 0)
          (set-memo-inhibit! memo #f))

        (define (done! value)
          ;; The C's `return dcnt' (`regex-emacs.c:4763'), and the
          ;; reason the old port raised an exception per attempt: the
          ;; callers unwind through several internal procedures, so a
          ;; value had to escape. It is threaded back instead - set
          ;; the result, answer the sentinel, and let each frame
          ;; return it. `guard'/`raise' here was 20% of a failing
          ;; search and allocated prompt and fluid state on every
          ;; start position.
          ;;------------------------------------------------------
          (set! result value)
          %match-done)

        (define (save-best-regs!)
          (set! best-regs-set? #t)
          (set! match-end d)
          (let loop ((r 1))
            (when (< r num-regs)
              (vector-set! best-regstart r (vector-ref regstart r))
              (vector-set! best-regend r (vector-ref regend r))
              (loop (+ r 1)))))

        (define (restore-best-regs!)
          (set! d match-end)
          (let loop ((r 1))
            (when (< r num-regs)
              (vector-set! regstart r (vector-ref best-regstart r))
              (vector-set! regend r (vector-ref best-regend r))
              (loop (+ r 1)))))

        (define (succeed!)
          ;; The C's `succeed_label'.
          ;;----------------------------------------------------
          (when regs
            (let ((starts (re-registers-start regs))
                  (ends (re-registers-end regs)))
              (vector-set! starts 0 pos)
              (vector-set! ends 0 d)
              (let loop ((r 1))
                (when (< r num-regs)
                  (if (not (vector-ref regend r))
                      (begin (vector-set! starts r -1)
                             (vector-set! ends r -1))
                      (begin
                        (vector-set! starts r (vector-ref regstart r))
                        (vector-set! ends r (vector-ref regend r))))
                  (loop (+ r 1))))
              (let loop ((r num-regs))
                (when (< r (re-registers-num regs))
                  (vector-set! starts r -1)
                  (vector-set! ends r -1)
                  (loop (+ r 1))))))
          (done! (- d pos)))

        (define (restore-best-and-succeed!)
          (restore-best-regs!)
          (succeed!))

        ;; The `fail:' label: answer #t if a failure point was restored
        ;; (P and D set), #f when the stack is empty.
        ;;
        ;; The pop leaves the saved text position in the stack's
        ;; `pop-str' - answering two values cost a box on every
        ;; backtrack - and the three-entry test is written out
        ;; rather than `memv' over a fresh list, which allocated one
        ;; per failure.
        (define (fail!)
          (if (%fail-stack-empty? fs)
              #f
              (let ((pat-index (%pop-failure-point! fs pat regstart regend)))
                (let* ((str (failure-stack-pop-str fs))
                       (ins (vector-ref pat pat-index))
                       (op (vector-ref ins 0)))
                (cond
                 ((= op op-on-failure-keep-string-jump)
                  (set! p (vector-ref ins 1))
                  #t)
                 ((= op op-on-failure-jump-prememo)
                  ;; `regex-emacs.c:5664': the prememo fastpath. Only
                  ;; one failure in eight is handed to
                  ;; `memo_record_failure'; the rest just count, so the
                  ;; count still rises once per failure while the
                  ;; per-state accounting is sampled.
                  (if (not (zero? (logand (memo-total-failures memo) 7)))
                      (set-memo-total-failures!
                       memo (+ (memo-total-failures memo) 1))
                      (%memo-record-failure! memo pat-index bufp (- str pos)))
                  (set! d str)
                  (set! p (vector-ref ins 1))
                  #t)
                 ((= op op-on-failure-jump-nastyloop)
                  ;; The special no_op frame that marks the iteration.
                  (%push-failure-point! fs (- pat-index 1) str)
                  (%memo-record-failure! memo pat-index bufp (- str pos))
                  (set! d str)
                  (set! p (vector-ref ins 1))
                  #t)
                 ((or (= op op-on-failure-jump-loop)
                      (= op op-on-failure-jump-memo)
                      (= op op-succeed-n))
                  (%memo-record-failure! memo pat-index bufp (- str pos))
                  (set! d str)
                  (set! p (vector-ref ins 1))
                  #t)
                 ((= op op-on-failure-jump-nomemo)
                  (set! d str)
                  (set! p (vector-ref ins 1))
                  #t)
                 ((= op op-no-op)
                  ;; A nasty-loop frame: fail again.
                  (fail!))
                 (else #f))))))

        ;; A branch procedure answers #t to continue the loop or #f to
        ;; fail.
        (define (end-of-pattern)
          ;; The C's `p == pend' and `succeed_label' block.
          ;;
          ;; Every branch answers the match length: `succeed!' and
          ;; `restore-best-and-succeed!' set RESULT and answer
          ;; `%match-done', and `(match-loop)' already answers the
          ;; length. The explicit `result' after them is the return
          ;; the C's `return dcnt' does.
          ;;----------------------------------------------------
          (if (not (= d stop))
              (let* ((best-match? (or (not best-regs-set?)
                                      (> d match-end))))
                (cond
                 ((not (%fail-stack-empty? fs))
                  (if (or (not best-regs-set?) best-match?)
                      (save-best-regs!))
                  (if (fail!)
                      (match-loop)
                      (begin
                        ;; From the C: with no failure points the match
                        ;; at D is the answer when it is the best.
                        (if (and best-regs-set? (not best-match?))
                            (restore-best-and-succeed!)
                            (succeed!))
                        result)))
                 ((and best-regs-set? (not best-match?))
                  (restore-best-and-succeed!)
                  result)
                 (else
                  (succeed!)
                  result)))
              (begin
                (succeed!)
                result)))

        (define (on-failure-loop pat-index str)
          ;; The shared `on_failure_jump_loop' / `on_failure' code.
          ;;----------------------------------------------------
          (let ((cycle (%check-infinite-loop fs pat pat-index str)))
            (if cycle
                ;; Get out of the loop and keep matching after it.
                (begin (set! p (vector-ref (vector-ref pat pat-index) 1)) #t)
                (begin (%push-failure-point! fs pat-index str) #t))))

        (define (match-loop)
          (if (= p pend)
              (end-of-pattern)
              (let* ((ins (vector-ref pat p))
                     (op (vector-ref ins 0)))
                (set! p (+ p 1))
                (let ((ok
                       (cond
                        ;; The hottest opcodes first: `jump' is in every
                        ;; loop and was 23 comparisons down the chain,
                        ;; where the C's switch is one branch. The rest
                        ;; stay in the C's opcode order.
                        ((= op op-jump)
                         (set! p (vector-ref ins 1))
                         #t)

                        ((= op op-no-op) #t)

                        ((= op op-succeed) (succeed!))

                        ((= op op-exactn)
                         (let* ((chars (vector-ref ins 1))
                                (dfail d)
                                (ok? #t))
                           (let loop ((cs chars))
                             (cond
                              ((null? cs) #t)
                              ((>= d stop) (set! d dfail) #f)
                              (else
                               (let ((c (%re-text-ref text d)))
                                 (if (= (if translate
                                            (if (< c 256)
                                                (vector-ref translate-vec c)
                                                (%translate-code translate c))
                                            c)
                                        (car cs))
                                     (begin (set! d (+ d 1)) (loop (cdr cs)))
                                     (begin (set! d dfail) #f))))))))

                        ((= op op-anychar)
                         (if (>= d stop)
                             #f
                             (let ((c (%re-text-ref text d)))
                               (if (= (if translate
                                          (if (< c 256)
                                              (vector-ref translate-vec c)
                                              (%translate-code translate c))
                                          c)
                                      10)
                                   #f
                                   (begin (set! d (+ d 1)) #t)))))

                        ((or (= op op-charset) (= op op-charset-not))
                         (if (>= d stop)
                             #f
                             (let* ((cs (vector-ref ins 1))
                                    (corig (%re-text-ref text d))
                                    (c (if translate
                                           (if (< corig 256)
                                               (vector-ref translate-vec corig)
                                               (%translate-code translate corig))
                                           corig))
                                    (not? (= op op-charset-not))
                                    (hit? (and (< c 256)
                                               (vector-ref (re-charset-table cs)
                                                           c))))
                               ;; The C calls `execute_charset' per
                               ;; character; its first test is the
                               ;; bitmap, and a hit is decisive. Doing
                               ;; that test here keeps the common case
                               ;; - an ASCII character the set holds -
                               ;; out of a procedure call, and a
                               ;; bitmap-only set does not need the
                               ;; call on a miss either.
                               (if (if hit?
                                       (not not?)
                                       (if (re-charset-simple? cs)
                                           not?
                                           (%execute-charset cs c corig
                                                             translate not?
                                                             class-at d)))
                                   (begin (set! d (+ d 1)) #t)
                                   #f))))

                        ((= op op-start-memory)
                         (let ((reg (vector-ref ins 1)))
                           (%push-failure-reg! fs regstart regend reg)
                           (vector-set! regstart reg d)
                           #t))

                        ((= op op-stop-memory)
                         (vector-set! regend (vector-ref ins 1) d)
                         #t)

                        ((= op op-duplicate)
                         (let ((reg (vector-ref ins 1)))
                           (set-memo-inhibit! memo #t)
                           (let ((start (vector-ref regstart reg))
                                 (end (vector-ref regend reg)))
                             (if (not end)
                                 #f
                                 (let ((dfail d)
                                       (ok? #t))
                                   (let loop ((i start))
                                     (cond
                                      ((= i end) #t)
                                      ((>= d stop) (set! d dfail) #f)
                                      (else
                                       (let ((c (%re-text-ref text d))
                                             (ci (%re-text-ref text i)))
                                         (if (= (if translate
                                                    (if (< c 256)
                                                        (vector-ref translate-vec c)
                                                        (%translate-code translate c))
                                                    c)
                                                (if translate
                                                    (if (< ci 256)
                                                        (vector-ref translate-vec ci)
                                                        (%translate-code translate ci))
                                                    ci))
                                             (begin (set! d (+ d 1)) (loop (+ i 1)))
                                             (begin (set! d dfail) #f)))))))))))

                        ((= op op-begline)
                         (if (= d 0)
                             #t
                             (if (= (%re-text-ref text (- d 1)) 10) #t #f)))

                        ((= op op-endline)
                         (if (= d len)
                             #t
                             (if (= (%re-text-ref text d) 10) #t #f)))

                        ((= op op-begbuf) (= d 0))
                        ((= op op-endbuf) (= d len))

                        ((= op op-on-failure-keep-string-jump)
                         (%push-failure-point! fs (- p 1) #f) #t)

                        ((= op op-on-failure-jump-nastyloop)
                         (let ((pat-index (- p 1)))
                           (if (%memo-has-failed? memo pat-index (- d pos))
                               #f
                               (let ((cycle (%check-infinite-loop fs pat (- pat-index 1) d)))
                                 (unless cycle
                                   (%push-failure-point! fs pat-index d))
                                 #t))))

                        ((= op op-on-failure-jump-loop)
                         (if (%memo-has-failed? memo (- p 1) (- d pos))
                             #f
                             (on-failure-loop (- p 1) d)))

                        ((= op op-on-failure-jump-memo)
                         (if (%memo-has-failed? memo (- p 1) (- d pos))
                             #f
                             (begin (%push-failure-point! fs (- p 1) d) #t)))

                        ((or (= op op-on-failure-jump-prememo)
                             (= op op-on-failure-jump-nomemo))
                         (%push-failure-point! fs (- p 1) d) #t)

                        ((= op op-on-failure-jump-smart)
                         ;; Decide between the keep-string and the
                         ;; ordinary loop, as `mutually_exclusive_p'
                         ;; does, then re-execute the instruction.
                         (let* ((pat-index (- p 1))
                                (target (vector-ref ins 1)))
                           (if (%mutually-exclusive? bufp p target class-at)
                               (begin
                                 (vector-set! ins 0 op-on-failure-keep-string-jump)
                                 ;; The trailing `jump' is at TARGET-1
                                 ;; (our jump answers point at the
                                 ;; instruction after the jump, as the
                                 ;; C's addresses do). It now goes to the
                                 ;; instruction after the on_failure
                                 ;; instruction, so the keep-string
                                 ;; failure point exits the loop.
                                 (vector-set! (vector-ref pat (- target 1)) 1
                                              (+ pat-index 1))
                                 (set! p pat-index)
                                 #t)
                               (begin
                                 (vector-set! ins 0 op-on-failure-jump-prememo)
                                 (set! p pat-index)
                                 #t))))

                        ((= op op-succeed-n)
                         (let ((mcnt (vector-ref ins 2)))
                           (if (not (zero? mcnt))
                               (begin
                                 (vector-set! ins 2 (- mcnt 1))
                                 (%push-number! fs (- p 1) mcnt)
                                 ;; Falls through to the instruction
                                 ;; after the succeed_n.
                                 #t)
                               ;; mcnt == 0: like on_failure_jump_loop.
                               (on-failure-loop (- p 1) d))))

                        ((= op op-jump-n)
                         (let ((mcnt (vector-ref ins 2)))
                           (if (not (zero? mcnt))
                               (begin
                                 (vector-set! ins 2 (- mcnt 1))
                                 (%push-number! fs (- p 1) mcnt)
                                 (set! p (vector-ref ins 1))
                                 #t)
                               #t)))

                        ((= op op-set-number-at)
                         (let ((target (vector-ref ins 1))
                               (value (vector-ref ins 2)))
                           (set-memo-inhibit! memo #t)
                           (let ((counter (vector-ref (vector-ref pat target) 2)))
                             (%push-number! fs target counter)
                             (vector-set! (vector-ref pat target) 2 value)
                             #t)))

                        ((or (= op op-wordbound) (= op op-notwordbound))
                         (let ((not? (= op op-notwordbound)))
                           (if (or (= d 0) (= d len))
                               (set! not? (not not?))
                               (let* ((c1 (%re-text-ref text (- d 1)))
                                      (c2 (%re-text-ref text d))
                                      (s1 (class-at c1 (- d 1)))
                                      (s2 (class-at c2 d)))
                                 (when (or (not (= (if (= s1 sword) 1 0)
                                                   (if (= s2 sword) 1 0)))
                                           (and (= s1 sword)
                                                (and (not (and (<= c1 255) (<= c2 255)))
                                                     (word-boundary-p c1 c2))))
                                   (set! not? (not not?)))))
                           (if not? #t #f)))

                        ((= op op-wordbeg)
                         (if (= d len)
                             #f
                             (let* ((c2 (%re-text-ref text d))
                                    (s2 (class-at c2 d)))
                               (if (not (= s2 sword))
                                   #f
                                   (if (= d 0)
                                       #t
                                       (let* ((c1 (%re-text-ref text (- d 1)))
                                              (s1 (class-at c1 (- d 1))))
                                         (not (and (= s1 sword)
                                                   (and (not (and (<= c1 255) (<= c2 255)))
                                                        (word-boundary-p c1 c2))))))))))

                        ((= op op-wordend)
                         (if (= d 0)
                             #f
                             (let* ((c1 (%re-text-ref text (- d 1)))
                                    (s1 (class-at c1 (- d 1))))
                               (if (not (= s1 sword))
                                   #f
                                   (if (= d len)
                                       #t
                                       (let* ((c2 (%re-text-ref text d))
                                              (s2 (class-at c2 d)))
                                         (not (and (= s2 sword)
                                                   (and (not (and (<= c1 255) (<= c2 255)))
                                                        (word-boundary-p c1 c2))))))))))

                        ((= op op-symbeg)
                         (if (= d len)
                             #f
                             (let* ((c2 (%re-text-ref text d))
                                    (s2 (class-at c2 d)))
                               (if (not (or (= s2 sword) (= s2 ssymbol)))
                                   #f
                                   (if (= d 0)
                                       #t
                                       (let* ((c1 (%re-text-ref text (- d 1)))
                                              (s1 (class-at c1 (- d 1))))
                                         (not (or (= s1 sword) (= s1 ssymbol)))))))))

                        ((= op op-symend)
                         (if (= d 0)
                             #f
                             (let* ((c1 (%re-text-ref text (- d 1)))
                                    (s1 (class-at c1 (- d 1))))
                               (if (not (or (= s1 sword) (= s1 ssymbol)))
                                   #f
                                   (if (= d len)
                                       #t
                                       (let* ((c2 (%re-text-ref text d))
                                              (s2 (class-at c2 d)))
                                         (not (or (= s2 sword) (= s2 ssymbol)))))))))

                        ((or (= op op-syntaxspec) (= op op-notsyntaxspec))
                         (if (>= d stop)
                             #f
                             (let* ((c (%re-text-ref text d))
                                    (spec (vector-ref ins 1))
                                    (actual (class-at c d)))
                               (if (if (not (integer? spec))
                                       #f
                                       (let ((same? (= actual spec)))
                                         (if (= op op-notsyntaxspec)
                                             (not same?)
                                             same?)))
                                   (begin (set! d (+ d 1)) #t)
                                   #f))))

                        ((= op op-at-dot)
                         (and (re-context-buffer? ctx)
                              (re-context-point ctx)
                              (= (+ (re-context-position ctx) d)
                                 (re-context-point ctx))))

                        ((or (= op op-categoryspec) (= op op-notcategoryspec))
                         (if (>= d stop)
                             #f
                             (let* ((c (%re-text-ref text d))
                                    (cat (vector-ref ins 1))
                                    (has (let ((set (char-category-set c)))
                                           (and (bool-vector-p set)
                                                (bool-vector-ref set cat)))))
                               (if (if (= op op-notcategoryspec)
                                       (not has)
                                       has)
                                   (begin (set! d (+ d 1)) #t)
                                   #f))))

                        (else #f))))
                  (cond
                   ;; A handler that matched answered the sentinel;
                   ;; `result' is the C's return value.
                   ((eq? ok %match-done) result)
                   (ok (match-loop))
                   ((fail!) (match-loop))
                   (best-regs-set?
                    (restore-best-and-succeed!)
                    result)
                   (else
                    (done! -1)
                    result))))))

        (lambda (new-pos new-regs)
          (reset-match-attempt! new-pos new-regs)
          ;; `match-loop' both loops and answers the match length, so
          ;; there is no exception to catch.
          (match-loop))))

    (define (re-match-2 bufp text pos regs stop ctx)
      ;; Answers the length of the match at POS, -1 for no match, or
      ;; -2 for failure-stack exhaustion (never, here).
      ;;
      ;; One attempt: `make-match-attempt' is for a search that will
      ;; try many start positions, which is `re_search_2''s loop.
      ;----------------------------------------------------------
      ;; `RE_SETUP_SYNTAX_TABLE_FOR_OBJECT' (`syntax.c:276', called at
      ;; `regex-emacs.c:4103'): the syntax cache is primed for THIS
      ;; object and position before any `SYNTAX(c)' is read. Without it
      ;; the cache inherits whatever interval the last scan left, and a
      ;; scan in the other direction then says "Error in syntax_table
      ;; logic for to-the-end intervals".
      (when (re-context-buffer? ctx) (%setup-syntax-table))
      ((make-match-attempt bufp text stop ctx) pos regs))

    ;;----------------------------------------------------------------
    ;; `re_search_2' (`regex-emacs.c:3454'), over one text
    ;;----------------------------------------------------------------
    (define (re-search bufp text startpos range regs stop ctx)
      ;; The position of the match, -1 for none, or -2 for an internal
      ;; failure. The C's two-string concatenation is one `<re-text>'
      ;; here, so its `POS_ADDR_VSTRING' and multibyte advance lengths
      ;; are single positions.
      ;;----------------------------------------------------------
      (let* ((pat (re-pattern-buffer-buffer bufp))
             (len (re-text-length text))
             (translate (re-pattern-buffer-translate bufp))
             (fastmap (re-pattern-buffer-fastmap bufp))
             ;; One matcher for every start position this search
             ;; tries: the helper closures, register vectors and
             ;; failure stack are built once, not once per attempt.
             (attempt (make-match-attempt bufp text stop ctx))
             (total len))
        ;; `RE_SETUP_SYNTAX_TABLE_FOR_OBJECT' (`syntax.c:276', called at
        ;; `regex-emacs.c:3509'): see `re-match-2'.
        (when (re-context-buffer? ctx) (%setup-syntax-table))
        (if (or (< startpos 0) (> startpos total))
            -1
            (begin
              (let ((endpos (+ startpos range)))
                (when (< endpos 0) (set! range (- startpos)))
                (when (> endpos total) (set! range (- total startpos))))
              (let ((begbuf-anchored?
                     (and (> (vector-length pat) 0)
                          (= (vector-ref (vector-ref pat 0) 0) op-begbuf)
                          (> range 0)))
                    (at-dot-stop #f))
                (when begbuf-anchored?
                  (if (> startpos 0)
                      (set! range 'none)
                      (set! range 0)))
                (when (and (not (eq? range 'none))
                           (> (vector-length pat) 0)
                           (= (vector-ref (vector-ref pat 0) 0) op-at-dot)
                           (> range 0)
                           (re-context-point ctx)
                           (let ((r (- (re-context-point ctx)
                                       (re-context-position ctx)
                                       startpos)))
                             (if (< r 0) #t (begin (set! range r) #f))))
                  (set! at-dot-stop #t))
                (if (or at-dot-stop (eq? range 'none))
                    -1
                    (begin
                      (when (and fastmap
                                 (not (re-pattern-buffer-fastmap-accurate?
                                       bufp)))
                        (re-compile-fastmap bufp))
                      (let ()
                      (define (advance!)
                        (cond ((= range 0) #f)
                              ((> range 0)
                               (set! range (- range 1))
                               (set! startpos (+ startpos 1))
                               #t)
                              (else
                               (set! range (+ range 1))
                               (set! startpos (- startpos 1))
                               #t)))
                      (define skip? #f)
                      (define (skip-fastmap!)
                        ;; The C's fastmap loop: forward, consume the
                        ;; characters that cannot start a match; a
                        ;; backward search tries only the one position.
                        ;;
                        ;; The map is read once and the fetch is
                        ;; specialized by substrate: a string reads
                        ;; `string-ref', a buffer its store through the
                        ;; gap, and only a `make-re-text' text pays the
                        ;; closure. This loop runs once per skipped
                        ;; character - a 200-character skip was 46x
                        ;; Emacs's byte-table scan, and a procedure call
                        ;; per character was most of it.
                        (set! skip? #f)
                        (when (and fastmap (< startpos total)
                                   (not (re-pattern-buffer-can-be-null? bufp)))
                          (let ((tbl (re-fastmap-table fastmap))
                                (any (re-fastmap-any-nonascii? fastmap)))
                            (if (<= range 0)
                                ;; A backward search tries only the one
                                ;; position.
                                (let* ((c0 (%re-text-ref text startpos))
                                       (c (if translate
                                              (%translate-code translate c0)
                                              c0))
                                       (hit? (if (< c 256)
                                                 (vector-ref tbl c)
                                                 any)))
                                  (unless hit?
                                    (set! skip? #t)))
                                (let ((s (re-text-string text)))
                                  (if s
                                      (let ff ()
                                        (when (> range 0)
                                          (let* ((c0 (char->integer
                                                      (string-ref s startpos)))
                                                 (c (if translate
                                                        (%translate-code translate c0)
                                                        c0))
                                                 (hit? (if (< c 256)
                                                           (vector-ref tbl c)
                                                           any)))
                                            (if hit?
                                                #t
                                                (begin
                                                  (set! startpos (+ startpos 1))
                                                  (set! range (- range 1))
                                                  (ff))))))
                                      (let ((b (re-text-buffer text)))
                                        (if b
                                            (let* ((store (vector-ref b 0))
                                                   (gpt (vector-ref b 1))
                                                   (gap (vector-ref b 2))
                                                   (base (vector-ref b 3)))
                                              (let ff ()
                                                (when (> range 0)
                                                  (let* ((p (+ base startpos))
                                                         (c0 (if (< p gpt)
                                                                 (u32vector-ref store p)
                                                                 (u32vector-ref
                                                                  store (+ p gap))))
                                                         (c (if translate
                                                                (%translate-code translate c0)
                                                                c0))
                                                         (hit? (if (< c 256)
                                                                   (vector-ref tbl c)
                                                                   any)))
                                                    (if hit?
                                                        #t
                                                        (begin
                                                          (set! startpos (+ startpos 1))
                                                          (set! range (- range 1))
                                                          (ff)))))))
                                            (let ff ()
                                              (when (> range 0)
                                                (let* ((c0 (%re-text-ref text startpos))
                                                       (c (if translate
                                                              (%translate-code translate c0)
                                                              c0))
                                                       (hit? (if (< c 256)
                                                                 (vector-ref tbl c)
                                                                 any)))
                                                  (if hit?
                                                      #t
                                                      (begin
                                                        (set! startpos (+ startpos 1))
                                                        (set! range (- range 1))
                                                        (ff))))))))))))))
                      (define (anchored-skip?)
                        (and (> (vector-length pat) 0)
                             (= (vector-ref (vector-ref pat 0) 0) op-begline)
                             (> startpos 0)
                             (not (= (%re-text-ref text (- startpos 1)) 10))))
                      (define (search-loop)
                        (if (anchored-skip?)
                            (if (advance!) (search-loop) -1)
                            (begin
                              (skip-fastmap!)
                              (cond
                               (skip?
                                (if (advance!) (search-loop) -1))
                               ((and (= range 0) fastmap
                                     (= startpos total)
                                     (not (re-pattern-buffer-can-be-null?
                                           bufp)))
                                -1)
                               (else
                                (let ((val (attempt startpos regs)))
                                  (if (>= val 0)
                                      startpos
                                      (if (= val -2)
                                          -2
                                          (if (advance!) (search-loop)
                                              -1)))))))))
                      (search-loop)))))))))
    ))
