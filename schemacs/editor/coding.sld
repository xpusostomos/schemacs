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
    ;; opposite of `vector-set!'.
    (only (guile) array-length array-ref array-set! logand make-typed-array)
    (only (schemacs editor character)
          byte8-to-char char-byte8? char-to-byte8 unibyte-to-char)
    )

  (export
   ;; The coding systems
   coding-system? make-coding-system
   coding-system-name coding-system-base coding-system-eol-type
   coding-system-iconv-name coding-system-raw?
   coding-system-p find-coding-system
   coding-system-base-name coding-system-change-eol-conversion
   eol-type->line-break line-break->eol-type
   *coding-system-table*
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
      (make-coding-system name base eol-type iconv-name raw?)
      coding-system?
      (name coding-system-name)
      (base coding-system-base)
      (eol-type coding-system-eol-type)
      (iconv-name coding-system-iconv-name)
      (raw? coding-system-raw?))

    (define *coding-system-table* (make-parameter #f))
    ;; ^ The registry, name symbol to coding system. A parameter so that a
    ;; test can bind an empty one - `*command-table*''s reason.

    (define (%table)
      (or (*coding-system-table*)
          (let ((t (list)))
            (*coding-system-table* t)
            t)))

    (define (register-coding-system! cs)
      (%table)
      (*coding-system-table* (cons cs (*coding-system-table*)))
      cs)

    (define (coding-system-p thing)
      ;; GNU Emacs's `coding-system-p': "Return t if OBJECT is a coding
      ;; system." A *name* counts, which is why this asks the table rather
      ;; than the record.
      ;;--------------------------------------------------------------
      (cond ((coding-system? thing) #t)
            ((symbol? thing) (if (find-coding-system thing) #t #f))
            (else #f)))

    (define (find-coding-system name)
      ;; The coding system NAME, or #f. Emacs interns coding systems in
      ;; `Vcoding_system_hash_table' and this is the lookup.
      ;;--------------------------------------------------------------
      (let loop ((cs (*coding-system-table*)))
        ;; `null?' and not `not': an empty list is *true* in Scheme where
        ;; Elisp's `nil' is false, so `(not cs)' never fires and the walk
        ;; runs off the end into `(car '())'. That is the class AGENTS.md
        ;; has a section on, and it is how a *string* argument - which has
        ;; no name in the table - became an assertion failure rather than
        ;; the #f this answers.
        (cond ((null? cs) #f)
              ((eq? (coding-system-name (car cs)) name) (car cs))
              (else (loop (cdr cs))))))

    (define (%define-coding-system name eol-type iconv-name raw?)
      ;; One entry, and with it the two EOL variants Emacs derives. Its
      ;; naming is the C's: the base is the bare name, and a variant is
      ;; `NAME-EOLTYPE' - so `utf-8' gives `utf-8-unix', `utf-8-dos' and
      ;; `utf-8-mac', and each is a coding system in its own right, which
      ;; is why `buffer-file-coding-system' can hold either.
      ;;--------------------------------------------------------------
      (let* ((base (make-coding-system name name eol-type iconv-name raw?)))
        (register-coding-system! base)
        (for-each
         (lambda (eol)
           (register-coding-system!
            (make-coding-system
             (string->symbol (string-append (symbol->string name)
                                            "-" (symbol->string eol)))
             base eol iconv-name raw?)))
         '(unix dos mac))
        base))

    ;;------------------------------------------------------------------
    ;; The coding systems
    ;;------------------------------------------------------------------
    ;;
    ;; The core of `coding.c''s list. `nil' as the EOL of the base is the
    ;; C's: the bare name is the base, and every actual use is one of its
    ;; three variants.

    (define utf-8 (%define-coding-system 'utf-8 #f "UTF-8" #f))
    (define iso-latin-1 (%define-coding-system 'iso-latin-1 #f "ISO-8859-1" #f))
    (define iso-8859-1 (%define-coding-system 'iso-8859-1 #f "ISO-8859-1" #f))
    (define us-ascii (%define-coding-system 'us-ascii #f "US-ASCII" #f))
    ;; `no-conversion' and `raw-text' are the same bytes; they differ in
    ;; what Emacs does with the *end of line* - `raw-text' converts a CRLF
    ;; that looks like a DOS line end where `no-conversion' leaves every
    ;; byte alone - and that difference is in the EOL half, not the codec.
    (define no-conversion (%define-coding-system 'no-conversion #f #f #t))
    (define raw-text (%define-coding-system 'raw-text #f #f #t))
    ;; The UTF-16 family, which iconv has and Emacs names by whether the
    ;; byte order mark is written: `utf-16' is
    ;; `utf-16-with-signature', and the two explicit ones are the BOM
    ;; kept as a character - measured, `(decode-coding-string #vu8(255 254
    ;; 65 0 66 0) 'utf-16)' is `(65 66)' and `utf-16le' is `(65279 65 66)'.
    (define utf-16 (%define-coding-system 'utf-16 #f "UTF-16" #f))
    (define utf-16le (%define-coding-system 'utf-16le #f "UTF-16LE" #f))
    (define utf-16be (%define-coding-system 'utf-16be #f "UTF-16BE" #f))

    ;;------------------------------------------------------------------
    ;; Converting
    ;;------------------------------------------------------------------

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
      (let ((cs (if (coding-system? coding) coding (find-coding-system coding))))
        (cond
         ((not cs)
          (error (string-append "Unknown coding system: "
                                (if (symbol? coding)
                                    (symbol->string coding)
                                    "?"))))
         ((coding-system-raw? cs)
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
              (let* ((str (bytevector->string bv (coding-system-iconv-name cs)))
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
      (let* ((enc (coding-system-iconv-name cs))
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
      (let* ((cs (if (coding-system? coding) coding (find-coding-system coding)))
             ;; TEXT is a `u32vector' of code points, as a string's
             ;; characters are - see the note on `decode-coding-string' for
             ;; why it cannot be a Scheme string.
             (n (array-length string)))
        (cond
         ((not cs)
          (error (string-append "Unknown coding system: "
                                (if (symbol? coding)
                                    (symbol->string coding)
                                    "?"))))
         ((coding-system-raw? cs)
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
                  (string->bytevector s (coding-system-iconv-name cs))
                  (let ((c (array-ref string i)))
                    (if (> c #x10FFFF)
                        (error (string-append
                                "Character out of range for "
                                (symbol->string (coding-system-name cs))
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

    (define (coding-system-base-name cs)
      ;; GNU Emacs's `coding-system-base': "Return the base coding system
      ;; of CODING-SYSTEM" - a *name*, and for a base it is its own. The
      ;; BASE field is the name for a base and the record for a variant,
      ;; which is Emacs's shape: `(coding-system-base 'utf-8)' is `utf-8'.
      ;;--------------------------------------------------------------
      (let ((found (cond ((not cs) #f)
                         ((coding-system? cs) cs)
                         (else (find-coding-system cs)))))
        (and found
             (let ((b (coding-system-base found)))
               (if (coding-system? b) (coding-system-name b) b)))))

    (define (coding-system-change-eol-conversion coding eol-type)
      ;; GNU Emacs's `coding-system-change-eol-conversion': "Return a
      ;; coding system based on CODING-SYSTEM but with a new EOL
      ;; type" - the name rebuilt, and the coding system looked up again.
      ;;--------------------------------------------------------------
      (let* ((cs (if (coding-system? coding) coding (find-coding-system coding)))
             (base (and cs (coding-system-base-name cs))))
        (and base
             (find-coding-system
              (string->symbol
               (string-append (symbol->string base) "-"
                              (symbol->string eol-type)))))))

    ))
