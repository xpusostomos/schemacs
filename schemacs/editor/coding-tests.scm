(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf u32vector->list)
 (only (schemacs editor coding)
       coding-system-p find-coding-system coding-system-name
       coding-system-base-name coding-system-change-eol-conversion
       decode-coding-string encode-coding-string)
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

(test-end "schemacs_editor_coding")
