(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf u32vector->list)
 (only (schemacs editor coding)
       coding-system-p coding-system-name coding-system-base
       coding-system-change-eol-conversion
       decode-coding-string encode-coding-string
       coding-setup-port! coding-read-char coding-write-char
       detect-eol bytes-have-null? adjust-coding-eol-type
       decode-eol encode-eol coding-system?
       detect-coding-bytes detect-coding-system
       find-operation-coding-system *file-coding-system-alist*
       coding-system-bom check-coding-system coding-system-eol-type)
 (only (schemacs editor search) string-match)
 (scheme file)
 (rnrs io ports)
 (only (schemacs editor character)
       char-byte8? byte8-to-char char-to-byte8 char-to-byte-safe
       unibyte-to-char *max-5-byte-char*))

(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor coding)', which mirrors GNU
;; Emacs's `src/coding.c' - the rule that turns a buffer's characters into
;; a file's bytes and back.
;;
;; **Every expectation was measured on GNU Emacs 31.1 first**, by reading
;; the same files with `coding-system-for-read` bound. The two files are
;; the ones the port was written against: `café naïve` in Latin-1, and a
;; UTF-16LE file with a byte order mark.
;;
;; The one thing these tests cannot do is use a Scheme *string* for the
;; answer. Emacs's `decode-coding-string' returns a string because an
;; Emacs string holds its byte characters; Guile's stop at `#x10FFFF`, so
;; the answer here is a `u32vector' of code points - deviation #3 showing
;; at the API rather than in the store.

(test-begin "schemacs_editor_coding")

;; ------------------------------------------------------------------
;; the eight-bit representation - `character.h:104'

(test-equal "MAX_5_BYTE_CHAR is the five-byte ceiling"
  '(#f #t #t)
  (list (char-byte8? *max-5-byte-char*)
        (char-byte8? (+ *max-5-byte-char* 1))
        (char-byte8? (byte8-to-char #xff))))

(test-equal "a byte character is its byte, both ways"
  '(4194176 4194303)
  (list (byte8-to-char #x80) (byte8-to-char #xff)))

(test-equal "a byte character gives its byte back"
  '(128 255)
  (list (char-to-byte8 (byte8-to-char #x80))
        (char-to-byte8 (byte8-to-char #xff))))

;; `CHAR_TO_BYTE_SAFE' is -1 for a character that has no byte - where
;; `CHAR_TO_BYTE8''s mask would quietly invent one.
(test-equal "a character with no byte answers -1, not a made-up byte"
  '(65 128 -1)
  (list (char-to-byte-safe 65)
        (char-to-byte-safe (byte8-to-char #x80))
        (char-to-byte-safe 233)))

(test-equal "UNIBYTE_TO_CHAR leaves ASCII alone"
  '(99 4194281)
  (list (unibyte-to-char 99) (unibyte-to-char 233)))

;; ------------------------------------------------------------------
;; the coding systems

(test-equal "a variant is a coding system, and its bare name is its base"
  '(#t utf-8 utf-8)
  ;; the coding system *is* the name, as in Emacs: there is nothing to
  ;; look up before asking it a question
  (list (coding-system-p 'utf-8-dos)
        (coding-system-base 'utf-8-dos)
        (coding-system-base 'utf-8)))

(test-equal "the EOL variants of a base are all there"
  '(utf-8-unix utf-8-dos utf-8-mac)
  (map coding-system-name '(utf-8-unix utf-8-dos utf-8-mac)))

(test-equal "changing the EOL conversion gives the named variant"
  'utf-8-dos
  (coding-system-change-eol-conversion 'utf-8-unix 'dos))

(test-equal "an unknown name is not a coding system"
  '(#f #f)
  (list (coding-system-p 'no-such-coding-system)
        (coding-system-p "utf-8")))   ; a *string* is not a name

;; ------------------------------------------------------------------
;; decoding, against Emacs's answers for the same bytes

(define (bytes-of bv)
  (let loop ((i 0) (acc '()))
    (if (>= i (bytevector-length bv))
        (reverse acc)
        (loop (+ i 1) (cons (bytevector-u8-ref bv i) acc)))))

(define latin-1-bytes #vu8(99 97 102 233 32 110 97 239 118 101 10))
;; ^ "café naïve\n" with the two accented letters as single Latin-1 bytes.

(define utf-16-bytes #vu8(255 254 65 0 66 0))
;; ^ "AB" in UTF-16LE with a byte order mark.

(test-equal "iso-latin-1 reads the accented letters as their own characters"
  '(99 97 102 233 32 110 97 239 118 101 10)
  (u32vector->list (decode-coding-string latin-1-bytes 'iso-latin-1-unix)))

;; `no-conversion' is the eight-bit representation: the ASCII stays
;; ASCII and the two high bytes become byte characters.
(test-equal "no-conversion keeps the bytes, as byte characters"
  '(99 97 102 4194281 32 110 97 4194287 118 101 10)
  (u32vector->list (decode-coding-string latin-1-bytes 'no-conversion)))

;; **UTF-8 does not fail on them.** Emacs's decoder writes the raw bytes
;; out as byte characters and carries on - `DECODE_COMPOSITION_FAILURE' in
;; the C - which is why this is the same answer as `no-conversion''s and
;; not an error. Guile's iconv refuses the input, so the port falls back.
(test-equal "utf-8 on undecodable bytes falls back rather than failing"
  '(99 97 102 4194281 32 110 97 4194287 118 101 10)
  (u32vector->list (decode-coding-string latin-1-bytes 'utf-8-unix)))

(test-equal "utf-8 reads what it can"
  '(99 97 102 233 10)
  (u32vector->list
   (decode-coding-string #vu8(99 97 102 195 169 10) 'utf-8-unix)))

(test-equal "utf-16 handles the byte order mark"
  '(65 66)
  (u32vector->list (decode-coding-string utf-16-bytes 'utf-16)))

;; ------------------------------------------------------------------
;; and back out again - the round trip that makes saving safe

(test-equal "iso-latin-1 writes the same bytes it read"
  '(99 97 102 233 32 110 97 239 118 101 10)
  (bytes-of (encode-coding-string
             (decode-coding-string latin-1-bytes 'iso-latin-1-unix)
             'iso-latin-1-unix)))

;; **This is what makes a file we cannot classify safe**: read it with
;; `no-conversion' and write it with `no-conversion' and every byte comes
;; back, whatever the bytes were.
(test-equal "no-conversion round-trips every byte"
  '(99 97 102 233 32 110 97 239 118 101 10)
  (bytes-of (encode-coding-string
             (decode-coding-string latin-1-bytes 'no-conversion)
             'no-conversion)))

;; ------------------------------------------------------------------
;; a stream, one character at a time - which is how a file is really read
;;
;; The mechanism is a port that is both binary and encoded: `put-u8'
;; writes a byte unconverted while `write-char' on the same port goes
;; through the encoding, and `get-u8' / `read-char' mirror that. The one
;; thing that must be turned on is `(set-port-conversion-strategy! port
;; 'error)' - by default a byte the encoding cannot decode is silently
;; replaced by U+FFFD, which is the mangling this layer exists to stop and
;; is invisible when it happens.

(define (read-stream bytes coding)
  (call-with-port (open-input-bytevector bytes)
    (lambda (p)
      (coding-setup-port! p coding)
      (let loop ((acc '()))
        (let ((c (coding-read-char p coding)))
          (if (eof-object? c) (reverse acc) (loop (cons c acc))))))))

(define (write-stream cps coding)
  (call-with-port (open-output-bytevector)
    (lambda (p)
      (coding-setup-port! p coding)
      (for-each (lambda (c) (coding-write-char p c coding)) cps)
      (get-output-bytevector p))))

(define (bytes-of bv)
  (let loop ((i 0) (acc '()))
    (if (>= i (bytevector-length bv)) (reverse acc)
        (loop (+ i 1) (cons (bytevector-u8-ref bv i) acc)))))

;; **A byte the coding system cannot decode becomes its byte character**,
;; and the scan carries on from the *next* byte. Both are Emacs 31.1's,
;; measured over the same bytes: `41 c3 28 42' read as utf-8 gives
;; `(65 4194243 40 66)' - one byte character for the C3, and then `0x28'
;; as an ordinary `(' - and the truncated `41 e2 82 42' gives two of them,
;; because 0x82 is not a valid start either.
(test-equal "a bad continuation gives one byte character, then rescans"
  '(65 4194243 40 66)
  (read-stream #vu8(65 195 40 66) 'utf-8-unix))

(test-equal "a truncated sequence gives a byte character per byte"
  '(65 4194274 4194178 66)
  (read-stream #vu8(65 226 130 66) 'utf-8-unix))

(test-equal "a valid sequence is decoded"
  '(65 233 66)
  (read-stream #vu8(65 195 169 66) 'utf-8-unix))

;; and writing is the same rule backwards: `char-byte8?' takes the byte
;; branch, everything else goes through the encoding.
(test-equal "byte characters write back as their own byte"
  '(65 195 40 66)
  (bytes-of (write-stream '(65 4194243 40 66) 'utf-8-unix)))

(test-equal "so a file we cannot classify survives a round trip"
  '(99 97 102 233 32 110 97 239 118 101 10)
  (bytes-of (write-stream (read-stream #vu8(99 97 102 233 32 110 97 239 118 101 10)
                                       'no-conversion)
                          'no-conversion)))

;; ------------------------------------------------------------------
;; which end of line a file uses - `detect_eol', `decode_eol' and
;; `encode_eol'
;;
;; The EOL convention is the *second half* of a coding system: `utf-8-unix'
;; and `utf-8-dos' are different coding systems with the same codec, and
;; every expectation below was measured on Emacs 31.1 first.

(test-equal "an LF file is unix, a CRLF file is dos, a CR file is mac"
  '(unix dos mac)
  (list (detect-eol #vu8(97 10 98))
        (detect-eol #vu8(97 13 10 98))
        (detect-eol #vu8(97 13 98))))

(test-equal "a file with no line break at all is unix"
  'unix
  (detect-eol #vu8(97 98 99)))

;; It is not "the first break wins": up to `MAX_EOL_CHECK_COUNT' (3) breaks
;; are read and a file whose breaks disagree is a UNIX file - except that a
;; stray CR in a DOS file is forgiven, which is what the C's own comment
;; calls out.
;; Both of these are measured on Emacs 31.1, which answers
;; `undecided-unix' and `undecided-dos' for the two files.
(test-equal '(unix dos)
  (list (detect-eol #vu8(97 10 98 13 10 99))         ; LF then CRLF -> unix
        (detect-eol #vu8(97 13 10 98 13 99 13 10 100)))) ; CRLF, stray CR, CRLF

(test-equal "a NUL byte means binary, so the line ends are not converted"
  '(#t #f)
  (list (bytes-have-null? #vu8(97 0 98)) (bytes-have-null? #vu8(97 98))))

;; The detected convention only settles a coding system that has not named
;; one - the C's `(VECTORP (eol_type))' test. This is the difference
;; between a file saying `-*- coding: utf-8 -*-' (which gets what its bytes
;; turn out to be) and one saying `utf-8-unix' (which keeps UNIX).
(test-equal '(utf-8-dos utf-8-unix)
  (list (adjust-coding-eol-type 'utf-8 'dos)
        (adjust-coding-eol-type 'utf-8-unix 'dos)))

;; decoding, both directions - Emacs's own numbers, measured
(test-equal '(dos-decodes (97 10 98) unix-keeps-the-cr (97 13 10 98))
  (list 'dos-decodes
        (decode-eol (list 97 13 10 98) 'utf-8-dos)
        'unix-keeps-the-cr
        (decode-eol (list 97 13 10 98) 'utf-8-unix)))

(test-equal "mac decoding turns every CR into a line feed"
  '(97 10 98)
  (decode-eol (list 97 13 98) 'utf-8-mac))

(test-equal '(dos (97 13 10 98) unix (97 10 98) mac (97 13 98))
  (list 'dos (encode-eol (list 97 10 98) 'utf-8-dos)
        'unix (encode-eol (list 97 10 98) 'utf-8-unix)
        'mac (encode-eol (list 97 10 98) 'utf-8-mac)))

;; **A coding system *is* the name**, so `(coding-system-eol-type
;; 'utf-8-unix)' is the same call `(coding-system-eol-type
;; buffer-file-coding-system)' is - which is Emacs's shape. This tree used
;; to hand out a record instead, and then the two were different types:
;; looking a record up answered #f and the next accessor died with
;; "expecting struct: #f". The mode line said `:' for every buffer.
(test-equal '(utf-8 unix #f)
  ;; `coding-system-base' answers a *name* even for a variant, whose
  ;; record points at its parent's record rather than at its name
  (list (coding-system-base 'utf-8-unix)
        (coding-system-eol-type 'utf-8-unix)
        (coding-system-eol-type 'utf-8)))

;; ------------------------------------------------------------------
;; the statistical detector
;;
;; **Every expectation here is Emacs 31.1's own answer** for the same
;; bytes, measured by writing them to a file and asking Emacs what
;; `buffer-file-coding-system' became. The four that differ are named on
;; `detect-coding-utf-8' in `coding.sld': they are the files whose bytes
;; Emacs reads as a coding system family this tree does not carry
;; (`japanese-shift-jis', `emacs-mule', `iso-2022-7bit'), and in every one
;; of them the *bytes* still survive a round trip.

(define (detected . bytes)
  (let ((found (detect-coding-bytes (list->u8vector bytes) #t)))
    (if found (car found) 'undecided)))

(test-equal "a file that declares nothing and is 7-bit is undecided"
  '(undecided undecided)
  (list (detected 104 101 108 108 111 10)
        (detected 97 98 99)))

(test-equal "valid UTF-8, with and without non-ASCII"
  '(undecided utf-8-unix utf-8-unix)
  (list (detected 97 98 99 10)                        ; pure ASCII
        (detected 99 97 102 195 169 10)               ; cafe-acute
        (detected 239 187 191 65 10)))                ; a BOM and "A"

;; The one the whole detector is here for: `caf\xe9' is not valid UTF-8,
;; and Emacs reads it as Latin-1 rather than leaving it undecoded.
(test-equal "Latin-1 is recognised by its bytes"
  '(iso-latin-1-unix iso-latin-1-unix)
  (list (detected 99 97 102 233 10)                   ; 233 is e-acute
        (detected 97 195 40 98 10)))                  ; a truncated UTF-8 lead

(test-equal "the line ends are settled on top of the character set"
  '(iso-latin-1-dos utf-8-dos)
  (list (detected 99 97 102 233 13 10)
        (detected 99 97 102 195 169 13 10)))

;; **The C1 rule, which is the one that is easy to get wrong.** A byte in
;; 0x80-0x9F rejects the `charset' category unless `latin-extra-code-table'
;; allows it - and it allows nothing - so such a file is *not* Latin-1.
;; Emacs then reaches `japanese-shift-jis', which matches - measured,
;; `(find-file "/tmp/c1.txt")` on `a\x85b' answers
;; `japanese-shift-jis-unix' - and so does this now that the sjis detector
;; is ported. 0xA0 is Latin-1 in both.
(test-equal '(japanese-shift-jis-unix iso-latin-1-unix)
  (list (detected 97 133 98 10)                       ; 0x85, a C1 byte
        (detected 97 160 98 10)))                     ; 0xA0, a Latin-1 byte

(test-equal "a NUL byte means binary, which is no-conversion"
  ;; The *bare* name: `no-conversion' is Emacs's one coding system whose
  ;; `:eol-type' is an integer and not a vector of three, so there is no
  ;; `no-conversion-unix' for the eol adjustment to name. Measured -
  ;; `(coding-system-eol-type 'no-conversion)' is 0 and
  ;; `(coding-system-p 'no-conversion-unix)' is nil.
  'no-conversion
  (detected 97 0 98 10))

(test-equal "an ASCII control byte does not stop a Latin-1 file"
  'iso-latin-1-unix
  ;; the line feed and the tab are below 0xA0 and above 0x80-free, and the
  ;; C1 rule must not touch them - written as a bare `(< c 0xA0)' it
  ;; rejects every one of them and *no* Latin-1 file is ever detected
  (detected 9 99 97 102 233 10))

;; ------------------------------------------------------------------
;; The `encoding-test-files' fixtures
;;
;; The bytes of <https://github.com/.../encoding-test-files> - six files
;; holding the same four lines in six encodings, and the fourth line is
;; the interesting one: `\U00010400' (Deseret) is in the supplementary
;; plane, so a coding system that mangles it is visible in one line rather
;; than in a whole file. The bytes are *here* rather than read from the
;; directory, so the suite is self-contained.
;;
;; **The expectations are Emacs 31.1's own answers**, asked with
;; `find-file' on each of the six - and all six match, including `cp865',
;; whose `\x8a' is a C1 byte: the `charset' category rejects it and
;; `japanese-shift-jis' is the next category that matches.

(define encoding-fixture-bytes
  (list
   (list "ascii"
         #vu8(112 114 101 109 105 63 114 101 32 105 115 32 102 105 114 115 116 10 112 114 101 109 105 101 63 114 101 32 105 115 32 115 108 105 103 104 116 108 121 32 100 105 102 102 101 114 101 110 116 10 63 63 63 63 63 63 63 63 63 32 105 115 32 67 121 114 105 108 108 105 99 10 63 32 97 109 32 68 101 115 101 114 101 116 10))
   (list "latin1"
         #vu8(112 114 101 109 105 232 114 101 32 105 115 32 102 105 114 115 116 10 112 114 101 109 105 101 63 114 101 32 105 115 32 115 108 105 103 104 116 108 121 32 100 105 102 102 101 114 101 110 116 10 63 63 63 63 63 63 63 63 63 32 105 115 32 67 121 114 105 108 108 105 99 10 63 32 97 109 32 68 101 115 101 114 101 116 10))
   (list "koi8_r"
         #vu8(112 114 101 109 105 63 114 101 32 105 115 32 102 105 114 115 116 10 112 114 101 109 105 101 63 114 101 32 105 115 32 115 108 105 103 104 116 108 121 32 100 105 102 102 101 114 101 110 116 10 235 201 210 201 204 204 201 195 193 32 105 115 32 67 121 114 105 108 108 105 99 10 63 32 97 109 32 68 101 115 101 114 101 116 10))
   (list "cp865"
         #vu8(112 114 101 109 105 138 114 101 32 105 115 32 102 105 114 115 116 10 112 114 101 109 105 101 63 114 101 32 105 115 32 115 108 105 103 104 116 108 121 32 100 105 102 102 101 114 101 110 116 10 63 63 63 63 63 63 63 63 63 32 105 115 32 67 121 114 105 108 108 105 99 10 63 32 97 109 32 68 101 115 101 114 101 116 10))
   (list "utf8"
         #vu8(112 114 101 109 105 195 168 114 101 32 105 115 32 102 105 114 115 116 10 112 114 101 109 105 101 204 128 114 101 32 105 115 32 115 108 105 103 104 116 108 121 32 100 105 102 102 101 114 101 110 116 10 208 154 208 184 209 128 208 184 208 187 208 187 208 184 209 134 208 176 32 105 115 32 67 121 114 105 108 108 105 99 10 240 144 144 128 32 97 109 32 68 101 115 101 114 101 116 10))
   (list "utf16"
         #vu8(255 254 112 0 114 0 101 0 109 0 105 0 232 0 114 0 101 0 32 0 105 0 115 0 32 0 102 0 105 0 114 0 115 0 116 0 10 0 112 0 114 0 101 0 109 0 105 0 101 0 0 3 114 0 101 0 32 0 105 0 115 0 32 0 115 0 108 0 105 0 103 0 104 0 116 0 108 0 121 0 32 0 100 0 105 0 102 0 102 0 101 0 114 0 101 0 110 0 116 0 10 0 26 4 56 4 64 4 56 4 59 4 59 4 56 4 70 4 48 4 32 0 105 0 115 0 32 0 67 0 121 0 114 0 105 0 108 0 108 0 105 0 99 0 10 0 1 216 0 220 32 0 97 0 109 0 32 0 68 0 101 0 115 0 101 0 114 0 101 0 116 0 10 0))
   ))

(define (encoding-fixture name)
  (let ((entry (assoc name encoding-fixture-bytes)))
    (and entry (cadr entry))))

(test-equal "what the detector makes of the six fixtures"
  ;; **These are Emacs 31.1's own answers, all six of them.** The BOM is a
  ;; *declaration*, so it is
  ;; `set-auto-coding' that names the last one and the detector is never
  ;; asked - which is the order the file layer uses.
  '(undecided iso-latin-1-unix iso-latin-1-unix japanese-shift-jis-unix
    utf-8-unix no-conversion)
  (map (lambda (e)
         (let ((found (detect-coding-bytes (cadr e) #t)))
           (if found (car found) 'undecided)))
       encoding-fixture-bytes))

;; **The property that matters for every one of them**: whatever the
;; detector decided, the bytes on disk come back. This is what the coding
;; work exists for - a file whose bytes no charset can read is read as
;; eight-bit characters and written back as itself.
(test-equal "every fixture survives being decoded and encoded again"
  (map cadr encoding-fixture-bytes)
  (map (lambda (e)
         (let ((coding (or (let ((found (detect-coding-bytes (cadr e) #t)))
                             (and found (car found)))
                           'utf-8)))
           (encode-coding-string (decode-coding-string (cadr e) coding) coding)))
       encoding-fixture-bytes))

;; and the text is *right*, not merely round-tripped: the four lines the
;; fixtures hold, read from the UTF-8 one.
(test-equal "the UTF-8 fixture decodes to the four lines"
  (list 112 114 101 109 105 232 114 101 32 105 115 32 102 105 114 115 116 10)
  (let ((v (decode-coding-string (encoding-fixture "utf8") 'utf-8-unix)))
    (let loop ((i 0) (out '()))
      (if (= i 18) (reverse out) (loop (+ i 1) (cons (u32vector-ref v i) out))))))

;; ------------------------------------------------------------------
;; UTF-16, and the NUL rule that shadows it
;;
;; The UTF-16 detector is ported and is exercised by the UTF-16 fixture
;; only through the *declaration* path, because a UTF-16 file of ASCII
;; text is half NUL bytes - and a NUL byte makes the walk answer
;; `no-conversion', in Emacs as here. These four cases are what Emacs's
;; `detect-coding-region' answers for the same bytes, all measured.

(test-equal "a NUL byte rules the whole walk out, UTF-16 included"
  ;; `detect-coding-region' on the UTF-16 fixture's bytes answers
  ;; `(no-conversion)' in Emacs too - the *file* path is what names it
  ;; `utf-16le-with-signature', from the BOM, before the walk is reached.
  '(no-conversion no-conversion)
  (list (detected 97 0 98 10)
        (detected 255 254 112 0 114 0 101 0)))

(test-equal "BOM-less UTF-16 of CJK text is Shift-JIS in both"
  ;; measured: Emacs answers `japanese-shift-jis-unix' for these bytes -
  ;; the C1 byte 0x87 is what takes it past the `charset' category, and
  ;; `sjis' is reached before any of the UTF-16 categories.
  '(japanese-shift-jis-unix japanese-shift-jis-unix)
  (list (detected 45 78 135 101 45 78)
        (detected 78 45 101 135 78 45)))

(test-equal "an odd byte count cannot be UTF-16, and raw-text is the fallback"
  ;; The detector's first test - `(coding->src_chars & 1)' with the whole
  ;; block present - rejects the five UTF-16 categories outright. What
  ;; comes back is `raw-text' and not `no-conversion', and that is the
  ;; *other* thing this case pins: the walk is bounded by a priority
  ;; *position* compared against raw_text's *index* - the C's
  ;; `for (i = 0; i < coding_category_raw_text; i++)' - so the last two
  ;; entries are never tested at all, and raw_text, never rejected, is
  ;; what the last-resort branch finds. Emacs's `detect-coding-region' on
  ;; these bytes answers `(raw-text)', measured.
  '(raw-text-unix raw-text)
  (list (detected 45 78 135)
        (car (detect-coding-system (list->u8vector (list 45 78 135)) #f))))

;; ------------------------------------------------------------------
;; choosing a coding system by file name
;;
;; `find-operation-coding-system' and `file-coding-system-alist'. **Every
;; expectation here is Emacs 31.1's own answer** for the same name:
;;
;;   /tmp/x.txt     (undecided)
;;   /tmp/x.gz      (no-conversion . no-conversion)
;;   /tmp/x.utf-8   (utf-8 . utf-8)
;;   /tmp/x.el      (prefer-utf-8 . prefer-utf-8)
;;   /tmp/loaddefs.el (prefer-utf-8 . prefer-utf-8)
;;
;; The last two differ here, and both for a reason this tree can state:
;; `prefer-utf-8` is an *undecided*-type coding system (`(coding-system-get
;; 'prefer-utf-8 :coding-type)` is `undecided`, measured), so it is the
;; detection machinery with a preference rather than a codec - it needs the
;; `prefer_utf-8` branch of `detect_coding`, which is not ported. And
;; `loaddefs.el` answers the same as `.el` in *Emacs too*: the `.el` entry
;; comes first and the walk returns on the first match, so the
;; `loaddefs.el` entry never gets a chance.

(test-equal "the file name decides, the way Emacs's alist does"
  '((undecided . undecided)
    (no-conversion . no-conversion)
    (no-conversion . no-conversion)
    (no-conversion . no-conversion)
    (utf-8 . utf-8)
    #f #f)
  (map (lambda (name)
         (find-operation-coding-system 'insert-file-contents name))
       (list "/tmp/x.txt" "/tmp/x.gz" "/tmp/x.tgz" "/tmp/x.tar"
             "/tmp/x.utf-8" "/tmp/x.el" "/tmp/loaddefs.el")))

(test-equal "a catch-all entry is what makes an ordinary file undecided"
  '(0 (undecided . undecided))
  (list (string-match (caar (reverse (*file-coding-system-alist*))) "/tmp/x.txt")
        (find-operation-coding-system 'insert-file-contents "/tmp/x.txt")))

(test-equal "... and an operation with no alist answers #f"
  '(#f #f)
  (list (find-operation-coding-system 'call-process "/tmp/x.txt")
        (find-operation-coding-system 'open-network-stream "example.com")))

;; ------------------------------------------------------------------
;; the byte order mark a coding system carries
;;
;; Emacs's `:bom'. **The three entries and their bytes are Emacs 31.1's
;; own** (`mule-conf.el:1388-1456'): `utf-8-with-signature' is `:bom t'
;; over the plain UTF-8 codec, and the two UTF-16 ones are `:bom t' over
;; the *little* and *big* codecs. The bytes are spelled out here because
;; iconv cannot be asked for a codec's signature, and each is the mark the
;; save writes and the read consumes.

(test-equal "a -with-signature coding system carries its mark; nothing else does"
  ;; **The strings and not symbols**: the hex comes out of `number->string`,
  ;; and `test-equal` is `equal?` - `'(ef)` and `'("ef")` print the same and
  ;; are not the same.
  '(("ef" "bb" "bf") ("ff" "fe") ("fe" "ff") #f #f #f #f)
  (map (lambda (n)
         (let ((bom (coding-system-bom n)))
           (if bom
               (let loop ((i 0) (acc '()))
                 (if (>= i (bytevector-length bom))
                     (reverse acc)
                     (loop (+ i 1)
                           (cons (number->string (bytevector-u8-ref bom i) 16)
                                 acc))))
               #f)))
       '(utf-8-with-signature utf-16le-with-signature
         utf-16be-with-signature utf-8 utf-16 utf-16le utf-16be)))

(test-equal "... and each of the three is a variant in its own right"
  '(3 2 2)
  (map (lambda (n)
         (bytevector-length (coding-system-bom n)))
       '(utf-8-with-signature-unix
         utf-16le-with-signature-unix
         utf-16be-with-signature-unix)))

;; `no-conversion' is the *one* coding system whose `:eol-type' is an
;; integer and not a vector of three, so it has no `-unix'/`-dos'/`-mac'
;; variants. Measured on Emacs 31.1: `(coding-system-eol-type
;; 'no-conversion)' is `0', `(coding-system-p 'no-conversion-unix)' is nil,
;; and `find-file' on a NUL file answers the bare `no-conversion'.
(test-equal "no-conversion has a fixed eol and no variants"
  ;; The last is `no-conversion' and not `#f': a *fixed* eol means the
  ;; detected one is ignored rather than followed, so the name stands.
  '(unix #f no-conversion)
  (list (coding-system-eol-type 'no-conversion)
        (coding-system-p 'no-conversion-unix)
        (adjust-coding-eol-type 'no-conversion 'dos)))

(test-equal "... where raw-text, its near neighbour, has all three"
  '(#t #t #t)
  (map (lambda (n) (coding-system-p n))
       '(raw-text-unix raw-text-dos raw-text-mac)))


;; ------------------------------------------------------------------
;; the end of line in the coding-string API
;;
;; **`decode-coding-string' and `encode-coding-string' convert the line
;; ends**, which is where the C puts it: `decode_coding' runs the codec over
;; the bytes and then `decode_eol' over what it produced, and `encode_coding'
;; the other way round. It is easy to leave out because the *file* path in
;; `files.sld' applies the eol itself - so every file that was read and
;; written came out right while this API did not, and
;; `(decode-coding-string "a\r\nb" 'utf-8-dos)' answered the CR as well as
;; the LF.
;;
;; Every row below is Emacs 31.1's own answer for the same input.

(define (bv->ints bv)
  (let loop ((i 0) (acc '()))
    (if (>= i (bytevector-length bv))
        (reverse acc)
        (loop (+ i 1) (cons (bytevector-u8-ref bv i) acc)))))

(test-equal "decode-coding-string converts the line ends"
  ;; utf-8-dos / utf-8-unix / utf-8-mac, raw-text / raw-text-dos /
  ;; no-conversion, and a bare `utf-8' whose eol is undecided.
  '((97 10 98) (97 13 10 98) (97 10 10 98)
    (97 10 98) (97 10 98) (97 13 10 98)
    (97 10 98))
  (map (lambda (cs)
         (u32vector->list (decode-coding-string #vu8(97 13 10 98) cs)))
       '(utf-8-dos utf-8-unix utf-8-mac raw-text raw-text-dos
         no-conversion utf-8)))

(test-equal "... and one that has not named one takes it from the text"
  ;; The C's `detect_eol' inside the decoder: every line ending comes back
  ;; as LF, whichever of the three it was.
  '((97 10 98) (97 10 98) (97 10 98))
  (map (lambda (bv) (u32vector->list (decode-coding-string bv 'utf-8)))
       (list #vu8(97 13 10 98) #vu8(97 10 98) #vu8(97 13 98))))

(test-equal "... and a NUL does not stop it, unlike on the file path"
  ;; `coding-system-for-file' turns a NUL into `unix' - a binary file's
  ;; line ends are left alone - but this function still converts. Measured:
  ;; Emacs answers `(97 0 10 98)' here for `"a\0\r\nb"' read as `utf-8'.
  '(97 0 10 98)
  (u32vector->list (decode-coding-string #vu8(97 0 13 10 98) 'utf-8)))

(test-equal "encode-coding-string converts them too, the other way"
  ;; The undefined-eol ones - `raw-text' and `no-conversion' - insert
  ;; nothing: there is nothing in the text to detect a convention from.
  '((97 13 10 98) (97 10 98) (97 10 98) (97 10 98))
  (map (lambda (cs)
         (bv->ints (encode-coding-string (u32vector 97 10 98) cs)))
       '(utf-8-dos utf-8-unix raw-text no-conversion)))


;; ------------------------------------------------------------------
;; check-coding-system
;;
;; Emacs 31.1's own answers: nil passes and is returned; a symbol that
;; names a coding system is returned; a symbol that names nothing signals
;; "Invalid coding system: X"; and anything that is not a symbol at all is
;; a type error *before* the lookup - which is why a string is an error
;; here where `coding-system-p' merely answers nil.

(define (signals? thunk)
  (guard (e (#t #t)) (thunk) #f))

(define (message-of thunk)
  (guard (e ((error-object? e) (error-object-message e)) (else #f)) (thunk) #f))

(test-equal "check-coding-system returns what it is given, when it names one"
  '(utf-8 iso-latin-1 #f)
  (list (check-coding-system 'utf-8)
        (check-coding-system 'iso-latin-1)
        (check-coding-system #f)))

(test-equal "... and signals otherwise, with Emacs's message"
  '(#t "Invalid coding system: nonsense" #t #f)
  (list (signals? (lambda () (check-coding-system 'nonsense)))
        (message-of (lambda () (check-coding-system 'nonsense)))
        (signals? (lambda () (check-coding-system "utf-8")))
        ;; a string is a type error but a *symbol* is not: `coding-system-p'
        ;; answers nil for it, and this goes on to the lookup
        (message-of (lambda () (check-coding-system 'utf-8)))))

(test-end "schemacs_editor_coding")
