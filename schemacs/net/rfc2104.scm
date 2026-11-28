(define-library (schemacs net rfc2104)
  ;; GNU Emacs's `lisp/net/rfc2104.el', whole: the HMAC of RFC 2104.
  ;; `auth-source.el`'s netrc saver uses it to key its "do not ask
  ;; twice" cache without putting the password itself in the key.
  ;;
  ;; **Two departures, both forced by the tree's string model.**
  ;;
  ;;   * The hash is a procedure here. Emacs passes the symbol `md5'
  ;;     and `funcall`s it through the obarray; a Scheme symbol is not
  ;;     applicable (the departure `(schemacs eval)`'s `funcall`
  ;;     records), so a caller passes the procedure -
  ;;     `(rfc2104-hash md5 64 16 KEY TEXT)'.
  ;;
  ;;   * The hash is handed the **bytes** as a bytevector, not a
  ;;     string. Emacs's pads hold arbitrary byte values in a unibyte
  ;;     string, and `md5' hashes a unibyte string byte for byte; a
  ;;     Scheme string has no unibyte flag, so encoding the pad as
  ;;     UTF-8 would hash two bytes for every value above 127 and
  ;;     answer something that is not the RFC's HMAC. `(schemacs fns)'
  ;;     `md5' therefore accepts a bytevector as well as a string.
  ;;     KEY and TEXT are converted to bytes with ISO-8859-1, which is
  ;;     exactly Emacs's unibyte reading of their characters; a
  ;;     character above 255 signals rather than being mangled.
  ;;
  ;; The RFC 2202 test vector is `(rfc2104-hash md5 64 16 "Jefe"
  ;; "what do ya want for nothing?")' = "750c783e6ab0b503eaa86e310a5db738".
  ;;------------------------------------------------------------
  (import (scheme base)
          (only (guile) logxor)
          (only (ice-9 iconv) string->bytevector))

  (export rfc2104-ipad rfc2104-opad rfc2104-hash)

  (begin

    (define rfc2104-ipad #x36)
    ;; ^ GNU Emacs's `rfc2104-ipad' (`rfc2104.el:58'): "Magic character
    ;; for inner HMAC round. 0x36 == 54 == '6'".

    (define rfc2104-opad #x5C)
    ;; ^ GNU Emacs's `rfc2104-opad' (`rfc2104.el:61'): "Magic character
    ;; for outer HMAC round. 0x5C == 92 == '\\'".

    (define (%rfc2104-bytes string)
      ;; Emacs's `make-string'/`aset' over a unibyte string: each
      ;; character of STRING is one byte. ISO-8859-1 is that mapping,
      ;; and iconv refuses a character it cannot represent.
      ;;--------------------------------------------------------------
      (string->bytevector string "ISO-8859-1"))

    (define (%rfc2104-nybble char)
      ;; Emacs's `rfc2104-nybbles' vector (`rfc2104.el:63'): a hex digit
      ;; to its value, and an error for anything else. The vector's nil
      ;; default is what makes a bogus hex string fail, so this fails too.
      ;;--------------------------------------------------------------
      (let ((c (char->integer char)))
        (cond ((and (>= c (char->integer #\0)) (<= c (char->integer #\9)))
               (- c (char->integer #\0)))
              ((and (>= c (char->integer #\a)) (<= c (char->integer #\f)))
               (+ 10 (- c (char->integer #\a))))
              ((and (>= c (char->integer #\A)) (<= c (char->integer #\F)))
               (+ 10 (- c (char->integer #\A))))
              (else
               (error "rfc2104: ~s is not a hex digit" char)))))

    (define (rfc2104-hash hash block-length hash-length key text)
      ;; GNU Emacs's `rfc2104-hash' (`rfc2104.el:80'): the HMAC of TEXT
      ;; under KEY with HASH. HASH takes a bytevector and answers its
      ;; hexadecimal digest, as `(schemacs fns)' `md5' does; BLOCK-LENGTH
      ;; and HASH-LENGTH are the digest's parameters (64 and 16 for MD5).
      ;;--------------------------------------------------------------
      (let* ( ;; if key is longer than B, reset it to HASH(key)
             (key (if (> (string-length key) block-length)
                      (hash (%rfc2104-bytes key))
                      key))
             (key-bytes (%rfc2104-bytes key))
             (len (bytevector-length key-bytes))
             (ipad (make-bytevector block-length rfc2104-ipad))
             (opad (make-bytevector (+ block-length hash-length)
                                    rfc2104-opad)))
        ;; Prefix *pad with key, appropriately XORed.
        (do ((i 0 (+ i 1)))
            ((= len i))
          (let ((c (bytevector-u8-ref key-bytes i)))
            (bytevector-u8-set! ipad i (logxor rfc2104-ipad c))
            (bytevector-u8-set! opad i (logxor rfc2104-opad c))))
        ;; Perform inner hash.
        (let* ((text-bytes (%rfc2104-bytes text))
               (inner (make-bytevector (+ block-length
                                          (bytevector-length text-bytes)))))
          (bytevector-copy! inner 0 ipad)
          (bytevector-copy! inner block-length text-bytes)
          (let ((partial (hash inner)))
            ;; Pack latter part of opad.
            (do ((r 0 (+ 2 r))
                 (w block-length (+ w 1)))
                ((= (* 2 hash-length) r))
              (bytevector-u8-set! opad w
                                  (+ (* 16 (%rfc2104-nybble (string-ref partial r)))
                                     (%rfc2104-nybble (string-ref partial (+ r 1))))))
            ;; Perform outer hash.
            (hash opad)))))

    ))
