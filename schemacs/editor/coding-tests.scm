(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf u32vector->list)
 (only (schemacs editor coding)
       coding-system-p find-coding-system coding-system-name
       coding-system-base-name coding-system-change-eol-conversion
       decode-coding-string encode-coding-string
       coding-setup-port! coding-read-char coding-write-char
       detect-eol bytes-have-null? adjust-coding-eol-type
       decode-eol encode-eol as-coding-system coding-system?
       coding-system-eol-type)
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
  (list (coding-system-p 'utf-8-dos)
        (coding-system-base-name (find-coding-system 'utf-8-dos))
        (coding-system-base-name (find-coding-system 'utf-8))))

(test-equal "the EOL variants of a base are all there"
  '(utf-8-unix utf-8-dos utf-8-mac)
  (map (lambda (n) (coding-system-name (find-coding-system n)))
       '(utf-8-unix utf-8-dos utf-8-mac)))

(test-equal "changing the EOL conversion gives the named variant"
  'utf-8-dos
  (coding-system-name
   (coding-system-change-eol-conversion (find-coding-system 'utf-8-unix) 'dos)))

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
  (list (coding-system-name (adjust-coding-eol-type 'utf-8 'dos))
        (coding-system-name (adjust-coding-eol-type 'utf-8-unix 'dos))))

;; decoding, both directions - Emacs's own numbers, measured
(test-equal '(dos-decodes (97 10 98) unix-keeps-the-cr (97 13 10 98))
  (list 'dos-decodes
        (decode-eol (list 97 13 10 98) (find-coding-system 'utf-8-dos))
        'unix-keeps-the-cr
        (decode-eol (list 97 13 10 98) (find-coding-system 'utf-8-unix))))

(test-equal "mac decoding turns every CR into a line feed"
  '(97 10 98)
  (decode-eol (list 97 13 98) (find-coding-system 'utf-8-mac)))

(test-equal '(dos (97 13 10 98) unix (97 10 98) mac (97 13 98))
  (list 'dos (encode-eol (list 97 10 98) (find-coding-system 'utf-8-dos))
        'unix (encode-eol (list 97 10 98) (find-coding-system 'utf-8-unix))
        'mac (encode-eol (list 97 10 98) (find-coding-system 'utf-8-mac))))

;; `as-coding-system' takes a name or a coding system already, which is the
;; split Emacs has no equivalent of: `(coding-system-eol-type
;; buffer-file-coding-system)' works there because a coding system is a
;; symbol. Missing it is not subtle - the mode line said `:' for every
;; buffer, because a lookup on a record answers #f.
(test-equal '(#t unix)
  (let ((cs (as-coding-system 'utf-8-unix)))
    (list (coding-system? (as-coding-system cs))
          (coding-system-eol-type (as-coding-system cs)))))

(test-end "schemacs_editor_coding")
