(define-library (schemacs editor coding)
  ;; This library mirrors GNU Emacs's `src/coding.c': the coding systems,
  ;; which are the rule for turning a buffer's characters into a file's
  ;; bytes and back.
  ;;
  ;; **The codecs are Guile's, and that is the whole point of the shape
  ;; here.** `coding.c' is twelve thousand lines because it *implements*
  ;; the encodings - the UTF-8 machinery, the ISO-2022 state machines, the
  ;; composition handling. Guile has iconv, which has them all, so what is
  ;; ported is the layer Emacs has and iconv does not:
  ;;
  ;;   * a coding system as a *named thing* - `utf-8-unix' rather than
  ;;     "UTF-8" - carrying its base, its end-of-line convention and the
  ;;     encoding name the codec call takes (`coding-system-plist',
  ;;     `coding-system-base', `coding-system-eol-type');
  ;;   * `decode-coding-string' / `encode-coding-string' as the one place
  ;;     a buffer's characters meet bytes;
  ;;   * and `no-conversion' / `raw-text', which are the one case iconv
  ;;     cannot express: "do not convert" is not a charset conversion.
  ;;     They are the eight-bit representation in `character.sld'.
  ;;
  ;; This is the substitution AGENTS.md allows for a facility Guile
  ;; already has, the same way the line-break conventions lean on Guile's
  ;; ports. What is *not* substituted is the vocabulary: the names, the
  ;; EOL half of them, and which one a buffer is using are Emacs's.
  ;;
  ;; Not carried from `coding.c', each with what it would need:
  ;;
  ;;   * `utf-8-emacs', Emacs's own extended UTF-8 with a five-byte form
  ;;     for its byte characters. iconv has no such encoding, so it is the
  ;;     one case where a codec would have to be written by hand - on top
  ;;     of the eight-bit pair, which it uses.
  ;;   * The UTF-16 family. iconv has them, so they are table entries when
  ;;     something wants them; Emacs's `utf-16le-with-signature' versus
  ;;     `utf-16le' is exactly the BOM question its `:coding-type'
  ;;     distinguishes.
  ;;   * `undecided' as a *deferred* choice, which needs `set-auto-coding'
  ;;     (the `-*- coding: -*-' tag, the local-variables block, the BOM).
  ;;   * `:charset-list', `:mime-charset', `:ascii-compatible-p' and the
  ;;     rest of the plist: nothing here asks, and `charset.c' is not
  ;;     ported.
  ;;   * The ISO-2022 and CJK families, and the `utf-8-emacs-unix' style
  ;;     aliasing between a coding system and its EOL variants beyond the
  ;;     three below.

  (import
    (scheme base)
    (scheme char)
    ;; The codec. `string->bytevector' / `bytevector->string' take the
    ;; encoding *name* iconv knows, which is what a coding system carries
    ;; beside its Lisp name.
    (ice-9 iconv)
    ;; `make-typed-array' is Guile's, not R7RS's: the answer is a
    ;; `u32vector' of code points and that is how one is made.
    ;; `make-typed-array', `array-ref' and `array-set!' are Guile's, not
    ;; R7RS's - `(scheme base)' has no generic array. NOTE that
    ;; `array-set!' takes the *value before the index*, which is the
    ;; opposite of `vector-set!'. `put-u8' / `get-u8' and the three port
    ;; settings are Guile's too.
    (only (guile) array-length array-ref array-set! catch logand logior
          make-hash-table hashq-set! hashq-ref
          make-typed-array
          set-port-conversion-strategy! set-port-encoding!)
    (only (rnrs io ports) get-u8 put-u8)
    (only (schemacs editor character)
          byte8-to-char char-byte8? char-to-byte8 unibyte-to-char)
    )

  (export
   ;; Reading and writing a stream one character at a time
   coding-setup-port! coding-read-char coding-write-char
   ;; The coding systems
   coding-system? make-coding-system
   coding-system-name coding-system-base coding-system-eol-type
   coding-system-iconv-name coding-system-raw?
   coding-system-mnemonic
   coding-system-p
   ;; The registry lookup, Emacs's `CODING_SYSTEM_SPEC'. It is here for
   ;; the tests; nothing outside this file needs it, because the public
   ;; accessors take a name and do it themselves.
   find-coding-system
   coding-system-base-name coding-system-change-eol-conversion
   eol-type->line-break line-break->eol-type
   *coding-system-table*
   ;; The end-of-line half
   *max-eol-check-count* detect-eol bytes-have-null? adjust-coding-eol-type
   decode-eol encode-eol
   *last-coding-system-used*
   *coding-system-for-read* *coding-system-for-write*
   ;; Which coding system a file's bytes are in
   detect-coding-bytes detect-coding-system
   *coding-category-priority* *coding-categories-bound*
   ;; Converting
   decode-coding-string encode-coding-string
   )

  (begin

    (define-record-type <coding-system>
      ;; GNU Emacs keeps a coding system as a *symbol with a plist* -
      ;; `coding-system-plist' - so that `(coding-system-p 'utf-8-unix)'
      ;; and `buffer-file-coding-system' holding the symbol are the same
      ;; question. A record is this tree's spelling of that; the NAME it
      ;; carries is the symbol, so a coding system can be named and
      ;; compared the way Emacs's can.
      ;;
      ;;   NAME         the Lisp name, `utf-8-unix'
      ;;   BASE         the coding system this is a variant of,
      ;;                `utf-8' - Emacs's `coding-system-base'
      ;;   EOL-TYPE     `unix', `dos', `mac' or #f, the C's
      ;;                `:eol-type', which is what the `-unix' in the
      ;;                name means
      ;;   ICONV-NAME   the name iconv knows it by, or #f for the raw
      ;;                pair
      ;;   RAW?         #t for `no-conversion' and `raw-text', which are
      ;;                not a conversion at all
      ;;   MNEMONIC     the character the mode line shows for it - the
      ;;                C's `coding_attr_mnemonic', which `%z' reads
      (make-coding-system name base eol-type iconv-name raw? mnemonic)
      coding-system?
      ;; The generated accessors are `-of' because they take the *record*:
      ;; the public names above take a coding system *name*, which is what
      ;; every caller has.
      (name coding-system-name-of)
      (base coding-system-base-of)
      (eol-type coding-system-eol-type-of)
      (iconv-name coding-system-iconv-name-of)
      (raw? coding-system-raw?-of)
      (mnemonic coding-system-mnemonic-of))

    (define *coding-system-table* (make-parameter #f))
    ;; ^ The registry, coding system *name* to `<coding-system>`. A
    ;; parameter so that a test can bind an empty one -
    ;; `*command-table*''s reason.
    ;;
    ;; **A hash table keyed by the symbol, which is GNU Emacs's shape** -
    ;; its `Vcoding_system_hash_table' is keyed by the coding system
    ;; symbol and `CODING_SYSTEM_SPEC' is one `Fgethash'. It was a list
    ;; with a linear walk, which is a different thing: measured, a
    ;; `hashq-ref' on a symbol is 0.017 us against 0.19 us for the walk,
    ;; and it does not get slower as the table grows.

    (define (%table)
      (or (*coding-system-table*)
          (let ((t (make-hash-table)))
            (*coding-system-table* t)
            t)))

    (define (register-coding-system! cs)
      ;; Put one in the registry under its own name. Emacs's
      ;; `Fputhash (this_name, this_spec, Vcoding_system_hash_table)'.
      ;;--------------------------------------------------------------
      (%table)
      (hashq-set! (*coding-system-table*) (coding-system-name-of cs) cs)
      cs)

    (define (coding-system-p thing)
      ;; GNU Emacs's `coding-system-p' (`coding.c:8594'): "Return t if
      ;; OBJECT is nil or a coding-system."
      ;;
      ;; **"or nil", and ours used to answer #f for it.** The docstring
      ;; this was copied from has those words in its first line and they
      ;; were dropped on the way in. Emacs reads a nil coding system as
      ;; "none named", which passes every check it makes; see
      ;; `check-coding-system' in `coding.sld''s neighbours for what a
      ;; nil would then mean on a save, which is the `undecided' case this
      ;; tree does not carry.
      ;;--------------------------------------------------------------
      (cond ((not thing) #t)
            ((symbol? thing) (if (find-coding-system thing) #t #f))
            (else #f)))

    (define (find-coding-system name)
      ;; The `<coding-system>` NAME names, or #f.
      ;;
      ;; Emacs's `CODING_SYSTEM_SPEC (coding_system_symbol)', which is
      ;; `Fgethash' on the hash table - one lookup, no walk.
      ;;--------------------------------------------------------------
      (let ((table (*coding-system-table*)))
        (and table (hashq-ref table name))))

    (define (%coding-of name)
      ;; NAME as a `<coding-system>` record, or an error. The one place a
      ;; *record* is reached for, and it is internal: everything outside
      ;; this file names a coding system with its symbol, as Emacs does.
      ;;--------------------------------------------------------------
      (or (find-coding-system name)
          (error (string-append "Unknown coding system: "
                                (if (symbol? name)
                                    (symbol->string name)
                                    "?")))))

    ;;------------------------------------------------------------------
    ;; Reading a coding system's attributes
    ;;------------------------------------------------------------------
    ;;
    ;; **These take the *name*, which is the whole of the shape.** GNU
    ;; Emacs's `coding-system-eol-type' takes `utf-8-unix' and takes
    ;; `buffer-file-coding-system' - one shape, because a coding system in
    ;; Emacs *is* the symbol. Ours were `define-record-type' accessors
    ;; taking the record, so every caller had to know which of two things
    ;; it held, and the seven places that guessed wrong got a silent #f
    ;; followed by "expecting struct: #f" somewhere else.
    ;;
    ;; The record is now what the table *stores* and nothing more: the
    ;; lookup below is Emacs's `CODING_ATTR_*' over `CODING_SYSTEM_SPEC'.

    (define (coding-system-name cs)
      ;; The coding system's own name - the symbol it is registered under,
      ;; which is Emacs's `CODING_ID_NAME' reading the hash *key*.
      ;;--------------------------------------------------------------
      (if (find-coding-system cs)
          cs
          (error "Not a coding system:" cs)))

    (define (coding-system-base cs)
      ;; GNU Emacs's `coding-system-base': "Return the base coding system
      ;; of CODING-SYSTEM" - a *name*, and for a base it is its own:
      ;; `(coding-system-base 'utf-8)' is `utf-8'.
      ;;
      ;; The record's BASE field holds the base's *name* for a base and the
      ;; base's <coding-system> for a variant - Emacs's own shape, where a
      ;; variant's spec points at its parent - and this is the one place
      ;; that distinction is read.
      ;;--------------------------------------------------------------
      (let ((b (and cs (coding-system-base-of (%coding-of cs)))))
        (and b (if (coding-system? b) (coding-system-name-of b) b))))

    (define (coding-system-eol-type cs)
      ;; GNU Emacs's `coding-system-eol-type' (`coding.c:11657'): "Return
      ;; eol-type of CODING-SYSTEM. An eol-type is an integer 0, 1, 2, or
      ;; a vector of coding systems." Emacs answers a *number*; this tree
      ;; has always spoken the names `unix', `dos' and `mac', which is
      ;; what the C's integers are spelled with everywhere else in it.
      ;;--------------------------------------------------------------
      (coding-system-eol-type-of (%coding-of cs)))

    (define (coding-system-iconv-name cs)
      (coding-system-iconv-name-of (%coding-of cs)))

    (define (coding-system-raw? cs)
      (coding-system-raw?-of (%coding-of cs)))

    (define (coding-system-mnemonic cs)
      ;; GNU Emacs's `coding-system-mnemonic' (`mule.el:1019'): "Return
      ;; the mnemonic character of CODING-SYSTEM" - the one character the
      ;; mode line shows for it through `%z'. Emacs answers a *character*;
      ;; this answers the same, and the caller makes a string of it.
      ;;--------------------------------------------------------------
      (coding-system-mnemonic-of (%coding-of cs)))

    (define (%define-coding-system name eol-type iconv-name raw? mnemonic)
      ;; One entry, and with it the two EOL variants Emacs derives. Its
      ;; naming is the C's: the base is the bare name, and a variant is
      ;; `NAME-EOLTYPE' - so `utf-8' gives `utf-8-unix', `utf-8-dos' and
      ;; `utf-8-mac', and each is a coding system in its own right, which
      ;; is why `buffer-file-coding-system' can hold either.
      ;;--------------------------------------------------------------
      (let* ((base (make-coding-system name name eol-type iconv-name raw? mnemonic)))
        (register-coding-system! base)
        (for-each
         (lambda (eol)
           (register-coding-system!
            (make-coding-system
             (string->symbol (string-append (symbol->string name)
                                            "-" (symbol->string eol)))
             base eol iconv-name raw? mnemonic)))
         '(unix dos mac))
        base))

    ;;------------------------------------------------------------------
    ;; The coding systems
    ;;------------------------------------------------------------------
    ;;
    ;; The core of `coding.c''s list. `nil' as the EOL of the base is the
    ;; C's: the bare name is the base, and every actual use is one of its
    ;; three variants.

    ;; The mnemonic each carries is Emacs 31.1's own answer for it -
    ;; `(coding-system-mnemonic 'utf-8)' is `?U', `iso-latin-1' `?1',
    ;; `us-ascii' `?-' and `no-conversion' `?=' - and it is the character
    ;; `%z' puts in the mode line.
    (define utf-8 (%define-coding-system 'utf-8 #f "UTF-8" #f #\U))
    (define iso-latin-1 (%define-coding-system 'iso-latin-1 #f "ISO-8859-1" #f #\1))
    (define iso-8859-1 (%define-coding-system 'iso-8859-1 #f "ISO-8859-1" #f #\1))
    (define us-ascii (%define-coding-system 'us-ascii #f "US-ASCII" #f #\-))
    ;; `no-conversion' and `raw-text' are the same bytes; they differ in
    ;; what Emacs does with the *end of line* - `raw-text' converts a CRLF
    ;; that looks like a DOS line end where `no-conversion' leaves every
    ;; byte alone - and that difference is in the EOL half, not the codec.
    (define no-conversion (%define-coding-system 'no-conversion #f #f #t #\=))
    (define raw-text (%define-coding-system 'raw-text #f #f #t #\t))
    ;; The UTF-16 family, which iconv has and Emacs names by whether the
    ;; byte order mark is written: `utf-16' is
    ;; `utf-16-with-signature', and the two explicit ones are the BOM
    ;; kept as a character - measured, `(decode-coding-string #vu8(255 254
    ;; 65 0 66 0) 'utf-16)' is `(65 66)' and `utf-16le' is `(65279 65 66)'.
    (define utf-16 (%define-coding-system 'utf-16 #f "UTF-16" #f #\U))
    (define utf-16le (%define-coding-system 'utf-16le #f "UTF-16LE" #f #\U))
    (define utf-16be (%define-coding-system 'utf-16be #f "UTF-16BE" #f #\U))

    ;;------------------------------------------------------------------
    ;; Converting
    ;;------------------------------------------------------------------

    ;;------------------------------------------------------------------
    ;; A stream, one character at a time
    ;;------------------------------------------------------------------
    ;;
    ;; GNU Emacs's `coding.c' converts a *stream* with a state machine -
    ;; `decode_coding' and `encode_coding' - and the shape here is the
    ;; same walk: read or write one character, and where the coding system
    ;; cannot handle what it meets, put or take the raw byte instead.
    ;;
    ;; The mechanism is a Guile port that is both binary and encoded, and
    ;; it is worth writing down because it is not obvious: `put-u8' writes
    ;; a byte *unconverted* while `write-char' on the same port goes
    ;; through the encoding, and on the reading side `get-u8' takes a raw
    ;; byte while `read-char' decodes. Measured, both directions - a port
    ;; with "UTF-8" set wrote `61 e9 c3 a9 7a' from a char, a raw byte, a
    ;; char and a char, and read the four back as themselves.
    ;;
    ;; The one thing that has to be turned on is the *conversion
    ;; strategy*: by default a byte the encoding cannot decode is silently
    ;; replaced by U+FFFD, which is the mangling this whole layer exists
    ;; to stop, and there is then no way to tell that it happened.
    ;; `(set-port-conversion-strategy! port 'error)' makes `read-char'
    ;; signal instead, and the offending byte is still on the port - which
    ;; is what makes the recovery below exact rather than approximate.

    (define (coding-setup-port! port coding)
      ;; The port half of `setup_coding_system': what the port converts
      ;; with, and that a byte it cannot decode is an error rather than a
      ;; substitution.
      ;;
      ;; A `no-conversion' or `raw-text' port is left with no encoding at
      ;; all - nothing here calls `read-char' or `write-char' on one, so
      ;; there is nothing for an encoding to spoil.
      ;;--------------------------------------------------------------
      (if (coding-system-raw? coding)
            port
            (begin
              (set-port-encoding! port (coding-system-iconv-name coding))
              (set-port-conversion-strategy! port 'error)
              port)))

    (define (%error-port rest)
      ;; The port out of a `decoding-error''s arguments, where the byte
      ;; that could not be read still is.
      ;;--------------------------------------------------------------
      (let loop ((r rest))
        (cond ((null? r) #f)
              ((port? (car r)) (car r))
              (else (loop (cdr r))))))

    (define (coding-read-char port coding)
      ;; One character from PORT, decoded by CODING. EOF is the eof
      ;; object, as `read-char''s is.
      ;;
      ;; **A byte the coding system cannot decode becomes its byte
      ;; character**, which is Emacs's rule and not a recovery invented
      ;; here: measured on Emacs 31.1, the bytes `41 c3 28 42' read as
      ;; `utf-8' give `(65 4194243 40 66)' - `0x3FFFC3' for the C3, and
      ;; then `0x28' as an ordinary `(' because the scan *carries on from
      ;; the next byte*. The truncated `41 e2 82 42' gives
      ;; `0x3FFFE2, 0x3FFF82' - two byte characters - because 0x82 alone
      ;; is not a valid start either.
      ;;
      ;; Guile's recovery is the same, byte for byte, and that is what
      ;; makes this a port rather than an approximation: measured over the
      ;; same three files it answers `#\A (bad 195) #\( #\B',
      ;; `#\A (bad 226) (bad 130) #\B' and `#\A #\é #\B'.
      ;;--------------------------------------------------------------
      (if (coding-system-raw? coding)
            (let ((b (get-u8 port)))
              (if (eof-object? b) b (unibyte-to-char b)))
            ;; `char->integer' so that *every* answer is a code point:
            ;; `read-char' gives a character and `byte8-to-char' an
            ;; integer, and a caller walking a buffer must not have to ask
            ;; which it got - a byte character is precisely the one that
            ;; cannot be a character.
            (catch 'decoding-error
              (lambda ()
                (let ((c (read-char port)))
                  (if (eof-object? c) c (char->integer c))))
              (lambda (key . rest)
                (let ((err (%error-port rest)))
                  (if err
                      (let ((b (get-u8 err)))
                        (if (eof-object? b) b (byte8-to-char b)))
                      (error "coding-read-char: decoding error with no port")))))))

    (define (coding-write-char port c coding)
      ;; One code point to PORT, encoded by CODING - and a *byte character*
      ;; written as its raw byte instead, which is how the bytes above come
      ;; back out unchanged.
      ;;
      ;; The test is `char-byte8?' and not a caught error, because a
      ;; character the charset cannot represent is *not* an error: Emacs
      ;; answers `"?"' for `(encode-coding-string "é" 'us-ascii)' and
      ;; Guile's port does the same by the same strategy setting. The byte
      ;; characters are a different thing - a reserved range that is not a
      ;; character at all - and they take the byte branch before any
      ;; encoding sees them.
      ;;--------------------------------------------------------------
      (if (or (coding-system-raw? coding) (char-byte8? c))
          (put-u8 port (char-to-byte8 c))
          ;; `write-char' takes the *character first* and the port
          ;; second - the opposite of `put-u8'.
          (write-char (integer->char c) port))
      c)

    (define (decode-coding-string bytes coding)
      ;; GNU Emacs's `decode-coding-string' (`coding.c'): "Decode the
      ;; specified coding system... Return the decoded text as a string."
      ;;
      ;; **The answer is a `u32vector' of code points and not a Scheme
      ;; string, and it cannot be a string.** Emacs's answer is a string
      ;; because an Emacs string is a sequence of its characters, and its
      ;; characters include the eight-bit ones. Guile's do not: `(integer->
      ;; char 4194281)' is out of range, `#x3FFFE9' being far above
      ;; `#x10FFFF'. So the one value this whole layer exists to carry -
      ;; the raw byte that no charset could read - fits the *buffer* and
      ;; not a string, which is deviation #3 showing at the API rather than
      ;; in the store.
      ;;
      ;; This is also the type the buffer holds (`(schemacs editor
      ;; buffer-text)'), so `decode-coding-region' - which Emacs has and
      ;; this does not yet - is a copy rather than a conversion.
      ;;
      ;; `no-conversion' and `raw-text' are the eight-bit representation:
      ;; every byte becomes the code point `0x3FFF00 + byte', which is what
      ;; makes a file whose bytes are not valid in any charset survive a
      ;; round trip. Everything else is iconv's, by name.
      ;;--------------------------------------------------------------
      ;; CS is the *record*, because this is where the fields are read in
      ;; bulk; the `-of' accessors take it and the public ones take a name.
      (let ((cs (%coding-of coding)))
        (cond
         ((coding-system-raw?-of cs)
          (let* ((bv (if (string? bytes) (string->utf8 bytes) bytes))
                 (n (bytevector-length bv))
                 (out (make-typed-array 'u32 0 n)))
            (let loop ((i 0))
              (if (>= i n)
                  out
                  (begin
                    ;; `UNIBYTE_TO_CHAR' and not `BYTE8_TO_CHAR': ASCII
                    ;; is itself. Measured - Emacs decodes the Latin-1
                    ;; file with `no-conversion' to `(99 97 102 4194281
                    ;; ...)', the letters unchanged and only the two high
                    ;; bytes as byte characters.
                    (array-set! out (unibyte-to-char (bytevector-u8-ref bv i)) i)
                    (loop (+ i 1)))))))
         (else
          (let ((bv (if (string? bytes) (string->utf8 bytes) bytes)))
            (guard (e (#t (%decode-with-fallback bv cs)))
              (let* ((str (bytevector->string bv (coding-system-iconv-name-of cs)))
                     (n (string-length str))
                     (out (make-typed-array 'u32 0 n)))
                (let loop ((i 0))
                  (if (>= i n)
                      out
                      (begin
                        (array-set! out (char->integer (string-ref str i)) i)
                        (loop (+ i 1))))))))))))

    (define (%decode-with-fallback bv cs)
      ;; What a coding system does with a byte its charset cannot read.
      ;;
      ;; **It does not fail**, and that is Emacs's rule rather than a
      ;; leniency here: `(decode-coding-string (unibyte-string 99 97 102
      ;; 233) 'utf-8)' answers the *eight-bit* character for the 233, and
      ;; reading the same bytes from a file with `utf-8' gives the same
      ;; answer - measured, `(99 97 102 4194281 ...)' where 4194281 is
      ;; `#x3FFFE9'. The C reaches it through
      ;; `DECODE_COMPOSITION_FAILURE' (`coding.c'), which writes the raw
      ;; bytes out as byte-8 characters and carries on rather than
      ;; signalling.
      ;;
      ;; Guile's iconv is strict, so this walks the bytes *only when it
      ;; has refused the whole input*: at each position the longest
      ;; sequence that decodes on its own is taken, and a byte that
      ;; decodes as nothing is its eight-bit character. The common case
      ;; never comes here, which is why the walk can afford to ask iconv
      ;; once per character.
      ;;--------------------------------------------------------------
      (let* ((enc (coding-system-iconv-name-of cs))
             (n (bytevector-length bv))
             (acc '()))
        (let loop ((i 0) (out '()))
          (if (>= i n)
              (let* ((lst (reverse out))
                     (m (length lst))
                     (v (make-typed-array 'u32 0 m)))
                (let fill ((j 0) (l lst))
                  (if (null? l)
                      v
                      (begin (array-set! v (car l) j) (fill (+ j 1) (cdr l)))))
                (set! acc v)
                acc)
              (let try ((len (min 4 (- n i))))
                (cond
                 ((<= len 0)
                  ;; nothing here decodes: the byte is itself
                  (loop (+ i 1)
                        (cons (byte8-to-char (bytevector-u8-ref bv i)) out)))
                 (else
                  (let ((piece (guard (e (#t #f))
                                 (bytevector->string
                                  (bytevector-copy bv i (+ i len)) enc))))
                    (if (and piece (= 1 (string-length piece)))
                        (loop (+ i len)
                              (cons (char->integer (string-ref piece 0)) out))
                        (try (- len 1)))))))))))

    (define (encode-coding-string string coding)
      ;; GNU Emacs's `encode-coding-string': STRING is the buffer's
      ;; characters and the answer is the file's *bytes*. A bytevector and
      ;; not a string, because Emacs's answer is a unibyte string - a
      ;; string of bytes - and this tree has no such thing.
      ;;--------------------------------------------------------------
      (let* ((cs (%coding-of coding))
             ;; TEXT is a `u32vector' of code points, as a string's
             ;; characters are - see the note on `decode-coding-string' for
             ;; why it cannot be a Scheme string.
             (n (array-length string)))
        (cond
         ((coding-system-raw?-of cs)
          (let ((out (make-bytevector n)))
            (let loop ((i 0))
              (if (>= i n)
                  out
                  (begin
                    (bytevector-u8-set! out i (char-to-byte8 (array-ref string i)))
                    (loop (+ i 1)))))))
         (else
          (let ((s (make-string n)))
            (let loop ((i 0))
              (if (>= i n)
                  (string->bytevector s (coding-system-iconv-name-of cs))
                  (let ((c (array-ref string i)))
                    (if (> c #x10FFFF)
                        (error (string-append
                                "Character out of range for "
                                (symbol->string (coding-system-name-of cs))
                                ": " (number->string c)))
                        (begin
                          (string-set! s i (integer->char c))
                          (loop (+ i 1))))))))))))

    ;;------------------------------------------------------------------
    ;; The end-of-line half
    ;;------------------------------------------------------------------
    ;;
    ;; Emacs keeps the line-end convention *inside* the coding system -
    ;; that is what the `-unix' in `utf-8-unix' is - and so does this.
    ;; `(schemacs editor engine)''s `line-break-*' values are what the
    ;; three EOL types mean, and the two tables below are the whole of the
    ;; correspondence.

    (define (eol-type->line-break eol-type)
      ;; The `line-break-*' value an EOL type stands for, or the value
      ;; itself when it is given one already.
      ;;--------------------------------------------------------------
      (case eol-type
        ((unix) 'line-break-newline)
        ((dos) 'line-break-crlf)
        ((mac) 'line-break-return)
        (else eol-type)))

    (define (line-break->eol-type line-break)
      (case line-break
        ((line-break-newline) 'unix)
        ((line-break-crlf) 'dos)
        ((line-break-return) 'mac)
        (else #f)))

    (define coding-system-base-name coding-system-base)
    ;; ^ The same function under the name it had before `coding-system-base'
    ;; was written - Emacs's `CODING_ATTR_BASE_NAME''s spelling. Kept so
    ;; that the eol helper below and the tests read as they did.

    (define (coding-system-change-eol-conversion coding eol-type)
      ;; GNU Emacs's `coding-system-change-eol-conversion': "Return a
      ;; coding system based on CODING-SYSTEM but with a new EOL
      ;; type" - the name rebuilt, and the coding system looked up again.
      ;;--------------------------------------------------------------
      (let* ((base (and coding (coding-system-base-name coding)))
             (name (and base
                        (string->symbol
                         (string-append (symbol->string base) "-"
                                        (symbol->string eol-type))))))
        (and name (coding-system-p name) name)))

    ;;------------------------------------------------------------------
    ;; Which end of line a file uses
    ;;------------------------------------------------------------------
    ;;
    ;; GNU Emacs's `detect_eol' (`coding.c:6374') and `adjust_coding_eol_type'
    ;; (`:6470'). **The convention is detected only when the coding system
    ;; has not already named one** - the C's `(VECTORP (eol_type))', the
    ;; eol-type of an `undecided' coding system - so a file that says
    ;; `-*- coding: utf-8-unix -*-' keeps UNIX whatever its bytes look
    ;; like, and a file that says only `utf-8' gets what it turns out to
    ;; be. Measured on Emacs 31.1: a CRLF file with `-*- coding: utf-8 -*-'
    ;; is `utf-8-dos', and the same file with `-*- coding: utf-8-unix -*-'
    ;; is `utf-8-unix'.

    (define *max-eol-check-count* 3)   ;; coding.c:6371

    (define (%eol-seen seen this)
      ;; The C's inner rule: the first break sets the answer, an agreeing
      ;; one changes nothing, a stray CR in a DOS file is forgiven (CR
      ;; followed by CRLF is CRLF), and any other disagreement collapses
      ;; to LF and stops the scan.
      ;;
      ;; The C `break's on the collapse; this does not, and that is the
      ;; same answer - `'lf' can never be changed to anything else by the
      ;; rules above, so carrying on reads the same as stopping.
      ;;--------------------------------------------------------------
      (cond ((eq? seen 'none) this)
            ((eq? seen this) seen)
            ((or (and (eq? seen 'cr) (eq? this 'crlf))
                 (and (eq? seen 'crlf) (eq? this 'cr)))
             'crlf)
            (else 'lf)))

    (define (%eol-seen->eol-type seen)
      ;; The mapping `adjust_coding_eol_type' makes (`coding.c:6476'):
      ;; the C's `detect_eol' answers a bitmask - `EOL_SEEN_LF',
      ;; `EOL_SEEN_CRLF' or `EOL_SEEN_CR' - and this is the coding
      ;; system's eol type it stands for.
      ;;
      ;; Leaving it out is not a small omission: `'lf' is not a coding
      ;; system's eol type, so the name built from it is `utf-8-lf', which
      ;; no table has - and the failure surfaces as "Unknown coding
      ;; system: ?" from three functions away.
      ;;--------------------------------------------------------------
      (case seen
        ((lf) 'unix)
        ((crlf) 'dos)
        ((cr) 'mac)
        (else 'unix)))

    (define (detect-eol bytes)
      ;; GNU Emacs's `detect_eol': the end-of-line convention BYTES use,
      ;; as `'unix', `'dos' or `'mac'.
      ;;
      ;; It is not "the first break wins": up to `MAX_EOL_CHECK_COUNT'
      ;; breaks are read, and a file whose breaks disagree is a UNIX file.
      ;; Emacs reads whole *bytes* here rather than characters, and so
      ;; does this - the scan runs before anything has been decoded, which
      ;; is the point of it.
      ;;
      ;; The C's UTF-16 half is not carried: it is the same scan looking
      ;; every other byte, and it needs the coding system's byte order,
      ;; which is what `detect_coding' decided just above it.
      ;;--------------------------------------------------------------
      (let ((n (bytevector-length bytes)))
        (let loop ((i 0) (total 0) (seen 'none))
          (if (or (>= i n) (= total *max-eol-check-count*))
              (%eol-seen->eol-type seen)
              (let ((b (bytevector-u8-ref bytes i)))
                (cond
                 ((and (= b 13) (< (+ i 1) n)
                       (= (bytevector-u8-ref bytes (+ i 1)) 10))
                  (loop (+ i 2) (+ total 1) (%eol-seen seen 'crlf)))
                 ((= b 10) (loop (+ i 1) (+ total 1) (%eol-seen seen 'lf)))
                 ((= b 13) (loop (+ i 1) (+ total 1) (%eol-seen seen 'cr)))
                 (else (loop (+ i 1) total seen))))))))

    (define (bytes-have-null? bytes)
      ;; Whether a NUL byte appears - the C's `null_byte_found'
      ;; (`coding.c:8930'): "if the text contains NUL, it is binary, so
      ;; end of line is UNIX and there is nothing to convert."
      ;;--------------------------------------------------------------
      (let ((n (bytevector-length bytes)))
        (let loop ((i 0))
          (cond ((>= i n) #f)
                ((= 0 (bytevector-u8-ref bytes i)) #t)
                (else (loop (+ i 1)))))))

    (define (adjust-coding-eol-type coding eol-type)
      ;; GNU Emacs's `adjust_coding_eol_type' (`coding.c:6470'): CODING
      ;; with EOL-TYPE settled - which it does *only* when CODING has not
      ;; named one already, that being what the C's `(VECTORP
      ;; (eol_type))' test says.
      ;;--------------------------------------------------------------
      (cond ((not coding) #f)
            ;; `(coding-system-eol-type coding)' is #f when the name does
            ;; not settle the eol - which is what "undecided" is here, and
            ;; is the C's `(VECTORP (eol_type))' test.
            ((coding-system-eol-type coding) coding)
            ((eq? eol-type 'none) coding)
            (else (coding-system-change-eol-conversion coding eol-type))))

    ;;------------------------------------------------------------------
    ;; Converting the line ends of a value
    ;;------------------------------------------------------------------
    ;;
    ;; GNU Emacs's `decode_eol' and `encode_eol' (`coding.c'): the EOL
    ;; half of a coding system, run over what the codec produced - a
    ;; whole-value pass in the C too, not part of the character state
    ;; machine. Measured on Emacs 31.1, both directions:
    ;;
    ;;   decode `utf-8-dos'   "a\r\nb" -> (97 10 98)
    ;;   decode `utf-8-unix'  "a\r\nb" -> (97 13 10 98)   ; the CR stays
    ;;   decode `utf-8-mac'   "a\rb"   -> (97 10 98)
    ;;   encode `utf-8-dos'   "a\nb"   -> (97 13 10 98)
    ;;   encode `utf-8-mac'   "a\nb"   -> (97 13 98)
    ;;
    ;; The `unix' case is the C's first line - "if UNIX, return" - which
    ;; is why a UNIX coding system never touches a CR.

    (define (decode-eol points coding)
      ;; The characters the file's line ends become: every CR of a CR-LF
      ;; pair goes for `dos', every CR goes for `mac', and `unix' is left
      ;; alone. POINTS is a list of code points.
      ;;--------------------------------------------------------------
      (let ((eol (coding-system-eol-type coding)))
        (case eol
          ((mac) (map (lambda (c) (if (= c 13) 10 c)) points))
          ((dos)
           (let loop ((p points) (acc '()))
             (cond ((null? p) (reverse acc))
                   ((and (= (car p) 13) (pair? (cdr p)) (= (cadr p) 10))
                    (loop (cdr p) acc))
                   (else (loop (cdr p) (cons (car p) acc))))))
          (else points))))

    (define (encode-eol points coding)
      ;; ... and back out: every LF becomes CR-LF for `dos' and CR for
      ;; `mac'. A CR of its own is left where it is, exactly as the C
      ;; leaves it - the round trip is then the identity for a file whose
      ;; only CRs are DOS line ends.
      ;;--------------------------------------------------------------
      (let ((eol (coding-system-eol-type coding)))
        (case eol
          ((mac) (map (lambda (c) (if (= c 10) 13 c)) points))
          ((dos)
           ;; ACC is built backwards and reversed at the end, so the CR-LF
           ;; pair goes on in *reverse* - the LF first, then the CR. The
           ;; other way round reads correctly and writes `10 13'.
           (let loop ((p points) (acc '()))
             (cond ((null? p) (reverse acc))
                   ((= (car p) 10) (loop (cdr p) (cons 10 (cons 13 acc))))
                   (else (loop (cdr p) (cons (car p) acc))))))
          (else points))))

    ;;------------------------------------------------------------------
    ;; Which coding system a file's bytes are in
    ;;------------------------------------------------------------------
    ;;
    ;; GNU Emacs's `detect_coding_system' (`coding.c:8686'): the bytes in,
    ;; the coding system that could have produced them out. This is the
    ;; *statistical* detector, which `set-auto-coding' is not: a
    ;; declaration a file makes is used as given and this is never
    ;; consulted, so a file saying `-*- coding: latin-1 -*-' is right even
    ;; when its bytes would score as UTF-8.
    ;;
    ;; **It is a walk over *categories*, each with a detector**, and each
    ;; detector is asked only what the ones before it have not settled.
    ;; The three masks are the C's own: `checked' (this detector has run),
    ;; `rejected' (this category cannot be it) and `found' (it can).
    ;;
    ;; **What is not carried, and why that is a configuration rather than
    ;; a hole.** `detect_coding_iso_2022', `sjis', `big5', `ccl',
    ;; `emacs-mule' and `detect_coding_utf_16' are not ported, and nor are
    ;; the coding systems they detect. The C already has a branch for a
    ;; category with nothing bound to it -
    ;;
    ;;     if (this->id < 0)
    ;;       /* No coding system of this category is defined.  */
    ;;       detect_info.rejected |= (1 << category);
    ;;
    ;; - so the walk below is the C's with those categories unbound. The
    ;; difference it makes is measurable and narrow: Emacs answers
    ;; `japanese-shift-jis-unix' for a file holding a C1 control byte,
    ;; `emacs-mule-unix' for another, `iso-2022-7bit-unix' for an escape
    ;; sequence (all measured); here those fall through to
    ;; `no-conversion', in which the *bytes* survive. The cases that
    ;; matter - UTF-8, ISO-8859-1 and plain ASCII - are exact.

    (define *coding-categories*
      ;; The categories in the C's enum order (`coding.c:476'), because a
      ;; mask is a bit position and the order has to be the C's.
      '(iso-7 iso-7-tight iso-8-1 iso-8-2 iso-7-else iso-8-else
        utf-8-auto utf-8-nosig utf-8-sig
        utf-16-auto utf-16-be utf-16-le utf-16-be-nosig utf-16-le-nosig
        charset sjis big5 ccl emacs-mule
        raw-text undecided))

    (define (%category-index category)
      (let loop ((cs *coding-categories*) (i 0))
        (cond ((null? cs) #f)
              ((eq? (car cs) category) i)
              (else (loop (cdr cs) (+ i 1))))))

    (define (%mask category)
      (expt 2 (%category-index category)))

    (define (%category-mask-through last)
      ;; The C's masks-as-a-union idiom: the OR of every category up to
      ;; and including LAST in the enum order.
      (let loop ((cs *coding-categories*) (m 0))
        (cond ((null? cs) m)
              (else (let ((m (logior m (%mask (car cs)))))
                      (if (eq? (car cs) last) m (loop (cdr cs) m)))))))

    (define *category-mask-utf-8*
      ;; `CATEGORY_MASK_UTF_8': the three UTF-8 categories are one
      ;; question - a detector rejects or accepts all three at once.
      (%category-mask-through 'utf-8-sig))

    (define *category-mask-any*
      ;; `CATEGORY_MASK_ANY': every category that *has* a detector.
      ;; `raw-text''s is NULL (`coding.c:5856'), which is why the walk
      ;; stops before it and why it is not in here.
      (%category-mask-through 'emacs-mule))

    (define *category-mask-charset* (%mask 'charset))
    (define *category-mask-raw-text* (%mask 'raw-text))

    (define *coding-category-priority*
      ;; `coding-category-list' as Emacs 31.1 answers it, measured rather
      ;; than taken from the C - the list is Emacs's to change, and this
      ;; is the order every answer below was checked against.
      '(utf-8-nosig iso-7 charset iso-7-else iso-8-else emacs-mule
        raw-text iso-7-tight iso-8-1 iso-8-2
        utf-8-auto utf-8-sig
        utf-16-auto utf-16-be utf-16-le utf-16-be-nosig utf-16-le-nosig
        sjis big5 ccl))

    (define *coding-categories-bound*
      ;; Which coding system each category has, which is Emacs's
      ;; `(coding-system-priority-list)' - `utf-8 iso-2022-7bit
      ;; iso-latin-1 ...' - narrowed to the coding systems this tree
      ;; carries. A category not here has *nothing* bound to it, which is
      ;; the C's `this->id < 0' case.
      '((utf-8-nosig . utf-8)
        (charset     . iso-latin-1)
        (raw-text    . raw-text)))

    (define-record-type <detection-info>
      ;; GNU Emacs's `struct coding_detection_info': the three masks a
      ;; walk carries between its detectors.
      (make-detection-info checked rejected found)
      detection-info?
      (checked detection-info-checked set!detection-info-checked)
      (rejected detection-info-rejected set!detection-info-rejected)
      (found detection-info-found set!detection-info-found))

    (define (%reject! info mask)
      ;; **`logior', not `+`.** The C's masks are bit sets and it writes
      ;; them with `|=`. Summed, a bit that is set twice carries into the
      ;; one above it - and the utf-8 detector's mask overlaps the
      ;; per-category bits the walk sets beside it, so the carries land
      ;; immediately. The symptoms are not subtle and not near the cause:
      ;; `(logand rejected CATEGORY_MASK_ANY) == CATEGORY_MASK_ANY' then
      ;; never holds, so a file no detector accepted was *not* reported as
      ;; `no-conversion'.
      ;;--------------------------------------------------------------
      (set!detection-info-rejected info
        (logior (detection-info-rejected info) mask)))

    (define (%found! info mask)
      (set!detection-info-found info
        (logior (detection-info-found info) mask)))

    (define (%utf-8-bom? bytes)
      ;; The three bytes of a UTF-8 byte order mark, which the C requires
      ;; to be at the head of the source (`coding.c:5818').
      (and (<= 3 (bytevector-length bytes))
           (= (bytevector-u8-ref bytes 0) #xEF)
           (= (bytevector-u8-ref bytes 1) #xBB)
           (= (bytevector-u8-ref bytes 2) #xBF)))

    (define (%utf-8-sequence-length c)
      ;; How many bytes the sequence C leads, or 0 when C cannot lead one.
      ;;
      ;; The C's five-octet case (`UTF_8_5_OCTET_LEADING_P (c) && c <
      ;; MAX_MULTIBYTE_LEADING_CODE') can never be taken - a five-octet
      ;; lead has bit 3 of the top nibble set, and `MAX_MULTIBYTE_LEADING_CODE'
      ;; is `0xF8' (`character.h:65') - so a five-byte form is refused,
      ;; exactly as the C refuses it.
      ;;--------------------------------------------------------------
      (cond ((= (logand c #xE0) #xC0) 2)
            ((= (logand c #xF0) #xE0) 3)
            ((= (logand c #xF8) #xF0) 4)
            (else 0)))

    (define (detect-coding-utf-8 bytes head-ascii info)
      ;; GNU Emacs's `detect_coding_utf_8' (`coding.c:5811'): whether BYTES
      ;; could be UTF-8. It sets the masks on INFO and answers whether the
      ;; source ran out before anything invalid was found.
      ;;
      ;; A *valid* sequence is not the question - whether one can be read
      ;; from the start to the end is, which is why a truncated sequence at
      ;; the end rejects (`if (src_base < src && LAST_BLOCK)').
      ;;--------------------------------------------------------------
      (set!detection-info-checked info
        (logior (detection-info-checked info) *category-mask-utf-8*))
      (let* ((n (bytevector-length bytes))
             (bom? (and (= head-ascii 0) (< (+ 3 0) n) (%utf-8-bom? bytes)))
             (start (if bom? 3 head-ascii)))
        (let loop ((i start) (nchars (if bom? (+ head-ascii 1) head-ascii)))
          (cond
           ((>= i n)
            (cond
             (bom?
              ;; "The first character 0xFFFE doesn't necessarily mean a
              ;; BOM." - with one, all three categories are possible.
              (%found! info *category-mask-utf-8*))
             (else
              (%reject! info (%mask 'utf-8-sig))
              (when (< nchars n)
                ;; The characters found are fewer than the source bytes,
                ;; which means a valid non-ASCII character was read.
                (%found! info (+ (%mask 'utf-8-auto) (%mask 'utf-8-nosig))))))
            #t)
           (else
            (let ((c (bytevector-u8-ref bytes i)))
              (if (< c #x80)
                  ;; ASCII. A CR-LF pair is two bytes and one character,
                  ;; which is the C's own bookkeeping.
                  (loop (if (and (= c 13) (< (+ i 1) n)
                                 (= (bytevector-u8-ref bytes (+ i 1)) 10))
                            (+ i 2)
                            (+ i 1))
                        (+ nchars 1))
                  (let ((len (%utf-8-sequence-length c)))
                    (cond
                     ((or (= len 0) (> (+ i len) n))
                      ;; Not a lead byte, or the source ran out inside the
                      ;; sequence.
                      (%reject! info *category-mask-utf-8*)
                      #f)
                     ((let bad ((j (+ i 1)))
                        ;; Every other byte is `10xxxxxx'.
                        (cond ((= j (+ i len)) #f)
                              ((= (logand (bytevector-u8-ref bytes j) #xC0) #x80)
                               (bad (+ j 1)))
                              (else #t)))
                      (%reject! info *category-mask-utf-8*)
                      #f)
                     (else (loop (+ i len) (+ nchars 1))))))))))))

    (define (%latin-extra-code? byte)
      ;; GNU Emacs's `latin-extra-code-table' (`charset.c'), which is nil
      ;; for every byte in this Emacs - measured, 0x80, 0x85, 0x9F and
      ;; 0xA0 all answer nil. It is what makes `check_latin_extra' reject
      ;; the C1 range for an `iso-8859-*' coding system, and it is why a
      ;; file holding one is *not* read as Latin-1: Emacs answers
      ;; `japanese-shift-jis-unix' for `a\205b', measured.
      ;;--------------------------------------------------------------
      #f)

    (define (%iso-8859-start-byte? byte)
      ;; Whether BYTE can begin a character of the charset this coding
      ;; system uses. Emacs asks the charset's `code_space'
      ;; (`charset->code_space', `charset.c'); `charset.c' is not ported,
      ;; so what this asks is the question for the one charset family
      ;; this tree has a coding system for - `iso-8859-1', whose code
      ;; space is `0x00-0xFF' and whose dimension is 1. Every byte can
      ;; begin a character, so the answer is always yes and the C1 rule
      ;; below is what actually decides.
      ;;--------------------------------------------------------------
      #t)

    (define (detect-coding-charset bytes head-ascii info)
      ;; GNU Emacs's `detect_coding_charset' (`coding.c:5900'): whether
      ;; BYTES could be text in the charset the `charset' category's
      ;; coding system uses.
      ;;
      ;; A byte in the C1 range (0x80-0x9F) is *rejected* for an
      ;; `iso-8859-*' or `iso-latin-*' coding system unless
      ;; `latin-extra-code-table' allows it - the C's `check_latin_extra',
      ;; whose test is that the coding system's name begins `iso-8859-' or
      ;; `iso-latin-'.
      ;;
      ;; `found' is 0 until a byte with the high bit set is seen, so an
      ;; all-ASCII input is *accepted* (the source ran out cleanly) while
      ;; claiming nothing - which is what the C does, and is why the walk
      ;; does not stop at `charset' for an ASCII file.
      ;;--------------------------------------------------------------
      (set!detection-info-checked info
        (logior (detection-info-checked info) *category-mask-charset*))
      (let* ((name (symbol->string 'iso-latin-1))
             (check-latin-extra
              (or (and (<= 9 (string-length name))
                       (string=? "iso-8859-" (substring name 0 9)))
                  (and (<= 10 (string-length name))
                       (string=? "iso-latin-" (substring name 0 10)))))
             (n (bytevector-length bytes)))
        (let loop ((i head-ascii) (found 0))
          (cond
           ((>= i n)
            (%found! info found)
            #t)
           (else
            (let ((c (bytevector-u8-ref bytes i)))
              (cond
               ((not (%iso-8859-start-byte? c))
                (%reject! info *category-mask-charset*)
                #f)
               ((and (>= c #x80) (< c #xA0)
                     check-latin-extra (not (%latin-extra-code? c)))
                ;; **The `(>= c #x80)' is the C's and it is easy to drop**:
                ;; the whole test sits inside the C's `if (c >= 0x80)', so
                ;; what it says is 0x80-0x9F and nothing else. Written as a
                ;; bare `(< c #xA0)' it also rejects every ASCII control
                ;; byte, and then *no* Latin-1 file is ever detected -
                ;; every one of them holds a line feed.
                (%reject! info *category-mask-charset*)
                #f)
               (else (loop (+ i 1)
                           (if (>= c #x80) *category-mask-charset* found))))))))))

    (define (%scan-head bytes)
      ;; The C's opening `for (; src < src_end; src++)' in
      ;; `detect_coding_system' (`coding.c:8712'). Three answers: the
      ;; count of leading ASCII bytes, whether a NUL byte was seen, and
      ;; whether an eight-bit byte was.
      ;;
      ;; **The ISO-2022 half is not carried.** The C asks
      ;; `detect_coding_iso_2022' about an ESC, SI or SO byte and can stop
      ;; the scan there; here those are ordinary control bytes. The
      ;; difference shows on a file holding an escape sequence - Emacs
      ;; says `iso-2022-7bit-unix', this says whatever the rest of the
      ;; bytes say - and the bytes survive either way.
      ;;--------------------------------------------------------------
      (let ((n (bytevector-length bytes)))
        (let loop ((i 0) (head 0) (null? #f) (eight-bit? #f))
          (cond
           ((>= i n) (values head null? eight-bit?))
           (else
            (let ((c (bytevector-u8-ref bytes i)))
              (cond
               ((>= c #x80)
                (if (and null? (not eight-bit?))
                    (values head null? #t)      ; the C breaks out here
                    (loop (+ i 1) head null? #t)))
               ((and (= c 0) (not null?))
                (if eight-bit?
                    (values head #t eight-bit?)
                    (loop (+ i 1) head #t eight-bit?)))
               ((not eight-bit?)
                ;; Both of the C's remaining arms are this: a byte that is
                ;; neither eight-bit nor already behind one counts as head,
                ;; whether it is a control or is printable.
                (loop (+ i 1) (+ head 1) null? eight-bit?))
               (else (loop (+ i 1) head null? eight-bit?)))))))))

    (define (%finish-detection category info null-byte-found)

      ;; The C's closing `if' chain (`coding.c:8834'), which turns the
      ;; masks into coding systems.
      ;;
      ;; `undecided' is not carried here, so the "nothing rejected and
      ;; nothing found" case answers #f - which every caller reads as "the
      ;; file declares nothing", the same thing `undecided' means to them.
      ;;--------------------------------------------------------------
      (cond
       ((or (= (logand (detection-info-rejected info) *category-mask-any*)
               *category-mask-any*)
            null-byte-found)
        (list 'no-conversion))
       ((and (= 0 (detection-info-rejected info))
             (= 0 (detection-info-found info)))
        #f)
       (category
        ;; `found' is non-zero: the category the walk stopped at.
        (let ((bound (assq category *coding-categories-bound*)))
          (and bound (list (cdr bound)))))
       (else
        ;; Nothing stopped the walk and nothing was found: the first
        ;; category in priority order that was not rejected.
        (let loop ((ps *coding-category-priority*))
          (cond ((null? ps) #f)
                ((= 0 (logand (detection-info-rejected info) (%mask (car ps))))
                 (let ((bound (assq (car ps) *coding-categories-bound*)))
                   (and bound (list (cdr bound)))))
                (else (loop (cdr ps))))))))

    (define (%detector-for category)
      (case category
        ((utf-8-nosig) detect-coding-utf-8)
        ((charset) detect-coding-charset)
        (else #f)))

    (define (detect-coding-system bytes highest)
      ;; GNU Emacs's `detect_coding_system': "Detect a coding system for
      ;; the text SRC of length SRC_BYTES ... If HIGHEST is nonzero, it
      ;; returns the coding system of the highest priority."
      ;;
      ;; The answer is a list of coding system *names*, or #f for the
      ;; C's `undecided'. With HIGHEST the walk stops at the first
      ;; category that accepts, which is the answer a file read wants and
      ;; is what Emacs's own file path takes.
      ;;--------------------------------------------------------------
      (let ((info (make-detection-info 0 0 0))
            (n (bytevector-length bytes)))
        (call-with-values (lambda () (%scan-head bytes))
          (lambda (head-ascii null-byte-found eight-bit-found)
            (if (and (not null-byte-found) (not eight-bit-found)
                     (>= head-ascii n)
                     (= 0 (detection-info-found info)))
                ;; Every byte was 7-bit and nothing was found: the C's
                ;; `undecided'. It skips the whole walk for this case.
                #f
                (let walk ((ps *coding-category-priority*))
                  (cond
                   ((null? ps)
                    (%finish-detection #f info null-byte-found))
                   ((eq? (car ps) 'raw-text)
                    ;; `raw_text' is where the C's loop *stops*
                    ;; (`i < coding_category_raw_text'), so it is skipped
                    ;; rather than rejected.
                    (walk (cdr ps)))
                   (else
                    (let* ((category (car ps))
                           (bound (assq category *coding-categories-bound*))
                           (bit (%mask category)))
                      (cond
                       ((not bound)
                        ;; A category with nothing bound to it is rejected
                        ;; outright - the C's own branch, and the one this
                        ;; tree's unbound families take.
                        (%reject! info bit)
                        (walk (cdr ps)))
                       ((not (= 0 (logand (detection-info-checked info) bit)))
                        ;; This detector has already run; the C asks only
                        ;; whether it found anything.
                        (if (and highest
                                 (not (= 0 (logand (detection-info-found info) bit))))
                            (%finish-detection category info null-byte-found)
                            (walk (cdr ps))))
                       (else
                        (let ((detector (%detector-for category)))
                          (let ((accepted (and detector
                                               (detector bytes head-ascii info))))
                            (if (and accepted highest
                                     (not (= 0 (logand (detection-info-found info) bit))))
                                (%finish-detection category info null-byte-found)
                                (walk (cdr ps))))))))))))))))

    (define (detect-coding-bytes bytes highest)
      ;; `detect-coding-system' under the name the file layer calls it by.
      ;; `detect-coding-region' is the C's name for the public function and
      ;; it takes a *buffer region*; nothing here has one, so the bytes are
      ;; the argument and the algorithm is the same one. The answer is
      ;; settled against the line ends, as `detect_coding_system''s own
      ;; closing loop does, so what comes back is `iso-latin-1-unix' and
      ;; not `iso-latin-1'.
      ;;--------------------------------------------------------------
      (let* ((found (detect-coding-system bytes highest))
             (eol (if (bytes-have-null? bytes) 'unix (detect-eol bytes))))
        (and found
             (map (lambda (name) (or (adjust-coding-eol-type name eol) name))
                  found))))

    (define *coding-system-for-read* (make-parameter #f))
    (define *coding-system-for-write* (make-parameter #f))
    ;; ^ GNU Emacs's `coding-system-for-read' and
    ;; `coding-system-for-write' (`coding.c'): the coding system to use
    ;; for the *next* read or write whatever the buffer's own says. They
    ;; are what `universal-coding-system-argument' (C-x RET c) and
    ;; `revert-buffer-with-coding-system' (C-x RET r) bind, and
    ;; `insert-file-contents' checks the first of them before the `coding:'
    ;; tag and before detection (`fileio.c:4317') - it is the outermost
    ;; word on the subject.

    (define *last-coding-system-used* (make-parameter #f))

    ;; ^ GNU Emacs's `last-coding-system-used' (`coding.c'): "Coding system
    ;; used for last file I/O operation." Emacs's answer can be the
    ;; *undecided* coding system it started with, when the file turned out
    ;; to need no conversion at all - measured, a pure ASCII file leaves
    ;; it `undecided' while `buffer-file-coding-system' is `utf-8-unix'.
    ;; There is no `undecided' here (the deferred choice is not carried),
    ;; so it is always the coding system actually used.

    ))
