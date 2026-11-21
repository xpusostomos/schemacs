(define-library (schemacs editor regex-emacs)
  ;; A port of GNU Emacs's `src/regex-emacs.c' - the Emacs regular
  ;; expression compiler and matcher.
  ;;
  ;; **Status.** This library is the port in progress: it currently
  ;; holds the opcode set, the pattern buffer, the registers, the text
  ;; and matching context, the character classes and the charset
  ;; object. The compiler (`regex_compile`), the fastmap, the searches
  ;; and the matcher are added below in the C's order; the library is
  ;; not imported by the editor until they are complete. The header
  ;; describes the whole port, which is what the sections below build.
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
    (only (guile) ash logand logior lognot logxor logcount u32vector-ref cadddr)
    (only (schemacs editor category) char-category-set category-table)
    (only (schemacs editor syntax) syntax-table syntax-class-to-char)
    (only (schemacs editor chartab)
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
      (make-re-pattern-buffer buffer fastmap translate nsub can-be-null?
                              fastmap-accurate? used-syntax?)
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
                    set-re-pattern-buffer-used-syntax!))

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
      (make-re-text length ref)
      re-text?
      (length re-text-length)
      (ref re-text-ref))

    (define (string->re-text string)
      ;; A Scheme string as matcher text. Code points, so it cannot
      ;; hold an eight-bit character - the same limit `string-match'
      ;; has everywhere above the store.
      ;;----------------------------------------------------------
      (let ((len (string-length string)))
        (make-re-text len (lambda (i) (char->integer (string-ref string i))))))

    (define (buffer->re-text store gpt gap base z)
      ;; A buffer-text's store as matcher text. STORE index I is code
      ;; point I; the gap of GAP elements begins at GPT; the matcher's
      ;; position 0 is store index BASE; the text ends at store index Z.
      ;; The four values are hoisted by the caller once, as the tree's
      ;; other scans hoist them, because the inner loop must not ask a
      ;; record.
      ;;----------------------------------------------------------
      (make-re-text (- z base)
                    (lambda (i)
                      (let ((p (+ base i)))
                        (if (< p gpt)
                            (u32vector-ref store p)
                            (u32vector-ref store (+ p gap)))))))

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
      (make-re-charset map ranges classes)
      re-charset?
      (map re-charset-map)          ; integer bitmask, bits 0..255
      (ranges re-charset-ranges)    ; vector of (FROM . TO), inclusive
      (classes re-charset-classes)) ; integer `RECC' bitmask

    (define (%re-charset-class-bit cc)
      ;; `re_wctype_to_bit` (`regex-emacs.c:1652'): the range-table bit
      ;; for class CC; the classes that fit in the ASCII bitmap answer
      ;; 0.
      ;;----------------------------------------------------------
      (cond ((or (= cc recc-multibyte) (= cc recc-nonascii)) 1)
            ((= cc recc-alpha) 2)
            ((= cc recc-alnum) 4)
            ((= cc recc-word) 8)
            ((= cc recc-lower) 16)
            ((= cc recc-upper) 32)
            ((= cc recc-punct) 64)
            ((= cc recc-space) 128)
            ((= cc recc-graph) 256)
            ((= cc recc-print) 512)
            ((= cc recc-blank) 1024)
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
      (let ((bits (re-charset-classes cs)))
        (or (and (not (zero? (logand bits 1))) (> ch 127))
            (and (not (zero? (logand bits 2))) (%char-alphabetic? ch))
            (and (not (zero? (logand bits 4))) (%char-alphanumeric? ch))
            (and (not (zero? (logand bits 8)))
                 (char=? (syntax-class-to-char
                          (logand (char-table-ref (syntax-table) ch) #xff))
                         #\w))
            (and (not (zero? (logand bits 16))) (%char-lower-case? ch))
            (and (not (zero? (logand bits 32))) (%char-upper-case? ch))
            (and (not (zero? (logand bits 64))) (%char-punctuation? ch))
            (and (not (zero? (logand bits 128))) (%char-whitespace? ch))
            (and (not (zero? (logand bits 256))) (%char-graphic? ch))
            (and (not (zero? (logand bits 512))) (%char-printable? ch))
            (and (not (zero? (logand bits 1024))) (%char-blank? ch)))))

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
        ;; The addresses the instruction stream already holds.
        (let loop ((i 0))
          (when (< i (+ used 1))
            (let ((ins (vector-ref buffer i)))
              (when (and ins (%address-op? (vector-ref ins 0)))
                (let ((a (vector-ref ins 1)))
                  (when (and (integer? a) (>= a at))
                    (vector-set! ins 1 (+ a 1))))))
            (loop (+ i 1))))
        ;; The compiler's own indexes.
        (set-compile-state-laststart!
         st (%shift-index (compile-state-laststart st) at))
        (set-compile-state-begalt!
         st (%shift-index (compile-state-begalt st) at))
        (set-compile-state-fixup-alt-jump!
         st (%shift-index (compile-state-fixup-alt-jump st) at))
        (set-compile-state-pending-exact!
         st (%shift-index (compile-state-pending-exact st) at))
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

    ))
