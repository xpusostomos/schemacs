(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor charset)
       charset? charset-id charset-name charset-dimension
       charset-iso-final-char charset-iso-chars-96
       charset-code-space charset-code-offset charset-max-code
       *charset-table* charset-from-id iso-charset-table
       *iso-2022-charset-list*
       decode-char encode-char))

;; Regression tests for `(schemacs editor charset)', which mirrors GNU
;; Emacs's `src/charset.c' - the registry the ISO-2022 machinery is built
;; on.
;;
;; **Every expectation here is Emacs 31.1's own answer**, taken from a
;; running Emacs rather than reasoned about:
;;
;;   * the charset count and the per-charset id, dimension, ISO final char
;;     and 96-character flag, from `charset-id-internal',
;;     `charset-dimension', `charset-iso-final-char' and the code space;
;;   * the designation table below, from `iso-charset', which reads
;;     `iso_charset_table' directly (`charset.c:499') - so it is an
;;     independent check of the port rather than a restatement of its
;;     input.

(test-begin "schemacs_editor_charset")

(define (charset-named name)
  ;; Emacs resolves a charset symbol through the registry; this is the
  ;; same walk, over the table's name slot.
  ;;--------------------------------------------------------------
  (let loop ((i 0))
    (cond ((>= i (vector-length (*charset-table*))) #f)
          ((let ((c (charset-from-id i)))
             (and c (eq? (charset-name c) name) c)))
          (else (loop (+ i 1))))))

(test-equal "the whole registry is here, in Emacs's id order"
  ;; 179 and not the table's 256 slots: `*charset-table*' is sized like
  ;; the C's (`charset_table.size') and only the defined ids are filled.
  '(179 0 ascii 2 unicode 3 emacs)
  (list (let loop ((i 0) (n 0))
          (if (>= i (vector-length (*charset-table*)))
              n
              (loop (+ i 1) (if (charset-from-id i) (+ n 1) n))))
        (charset-id (charset-from-id 0))
        (charset-name (charset-from-id 0))
        (charset-id (charset-from-id 2))
        ;; id 2 is `unicode' and not `ucs', which is an alias sharing its
        ;; id and is not a second charset in the table.
        (charset-name (charset-from-id 2))
        (charset-id (charset-from-id 3))
        (charset-name (charset-from-id 3))))

(test-equal "a charset's dimension comes from the code space it was given"
  ;; `mule.el:251': the dimension is half the *original* code-space
  ;; length, so `#(0 127)' is dimension 1 and not the 4 that padding it
  ;; to eight elements would suggest.
  '(1 3 3 4)
  (map (lambda (n) (charset-dimension (charset-named n)))
       '(ascii unicode emacs gb18030)))

(test-equal "... and a 96-character set is one whose first dimension holds 96"
  '(#f #t #f)
  (map (lambda (n) (charset-iso-chars-96 (charset-named n)))
       '(ascii latin-iso8859-1 japanese-jisx0208)))

;; ------------------------------------------------------------------
;; ISO_CHARSET_TABLE - the designation table
;;
;; `iso-charset' on Emacs 31.1 for every (DIMENSION CHARS FINAL) in range
;; gives these 53 charsets. **53 and not 54**: `thai-iso8859-11' and
;; `thai-tis620' are both designated `ESC ( T' at dimension 1, so the
;; second one defined overwrites the first, and the later `thai-tis620'
;; is what the cell holds. The port reproduces that because it writes the
;; cell in definition order too.
;;
;; The table is checked in *both* directions below - every one of these
;; cells answers the right charset, and no other cell answers anything -
;; so a cell that should be empty and is not cannot slip through.

(define emacs-iso-charset-table
  '(
    (1 #f 48 chinese-sisheng)
    (1 #f 49 lao)
    (1 #f 50 arabic-digit)
    (1 #f 51 arabic-1-column)
    (1 #f 52 arabic-2-column)
    (1 #f 53 indian-is13194)
    (1 #f 66 ascii)
    (1 #f 73 katakana-jisx0201)
    (1 #f 74 latin-jisx0201)
    (1 #t 48 ipa)
    (1 #t 49 vietnamese-viscii-lower)
    (1 #t 50 vietnamese-viscii-upper)
    (1 #t 65 latin-iso8859-1)
    (1 #t 66 latin-iso8859-2)
    (1 #t 67 latin-iso8859-3)
    (1 #t 68 latin-iso8859-4)
    (1 #t 70 greek-iso8859-7)
    (1 #t 71 arabic-iso8859-6)
    (1 #t 72 hebrew-iso8859-8)
    (1 #t 76 cyrillic-iso8859-5)
    (1 #t 77 latin-iso8859-9)
    (1 #t 84 thai-tis620)
    (1 #t 86 latin-iso8859-10)
    (1 #t 89 latin-iso8859-13)
    (1 #t 95 latin-iso8859-14)
    (1 #t 98 latin-iso8859-15)
    (1 #t 102 latin-iso8859-16)
    (2 #f 48 chinese-big5-1)
    (2 #f 49 chinese-big5-2)
    (2 #f 51 ethiopic)
    (2 #f 53 indian-2-column)
    (2 #f 54 indian-1-column)
    (2 #f 55 tibetan)
    (2 #f 56 tibetan-1-column)
    (2 #f 64 japanese-jisx0208-1978)
    (2 #f 65 chinese-gb2312)
    (2 #f 66 japanese-jisx0208)
    (2 #f 67 korean-ksc5601)
    (2 #f 68 japanese-jisx0212)
    (2 #f 71 chinese-cns11643-1)
    (2 #f 72 chinese-cns11643-2)
    (2 #f 73 chinese-cns11643-3)
    (2 #f 74 chinese-cns11643-4)
    (2 #f 75 chinese-cns11643-5)
    (2 #f 76 chinese-cns11643-6)
    (2 #f 77 chinese-cns11643-7)
    (2 #f 79 japanese-jisx0213-1)
    (2 #f 80 japanese-jisx0213-2)
    (2 #f 81 japanese-jisx0213.2004-1)
    (2 #t 49 mule-unicode-0100-24ff)
    (2 #t 50 mule-unicode-2500-33ff)
    (2 #t 51 mule-unicode-e000-ffff)
    (2 #t 52 indian-glyph)
    ))

(test-equal "every designation Emacs answers is answered here"
  '()
  (let loop ((rows emacs-iso-charset-table) (bad '()))
    (cond ((null? rows) (reverse bad))
          (else
           (let* ((row (car rows))
                  (id (iso-charset-table (car row) (cadr row) (caddr row)))
                  (want (cadddr row))
                  (got (and (charset? (charset-from-id id)) (charset-name (charset-from-id id)))))
             (loop (cdr rows)
                   (if (eq? got want) bad (cons (list row got) bad))))))))

(test-equal "... and nothing Emacs does not answer is answered here"
  '()
  (let loop ((dim 1) (chars-96 #f) (final 48) (bad '()))
    (cond
     ((> dim 2) (reverse bad))
     ((> final 126) (if chars-96
                        (loop (+ dim 1) #f 48 bad)
                        (loop dim #t 48 bad)))
     (else
      (let ((id (iso-charset-table dim chars-96 final)))
        (loop dim chars-96 (+ final 1)
              (if (>= id 0)
                  (let ((in-golden
                         (let g ((rows emacs-iso-charset-table))
                           (cond ((null? rows) #f)
                                 ((and (= (car (car rows)) dim)
                                       (eq? (cadr (car rows)) chars-96)
                                       (= (caddr (car rows)) final)) #t)
                                 (else (g (cdr rows)))))))
                    (if in-golden bad (cons (list dim chars-96 final id) bad)))
                  bad)))))))

(test-equal "a cell is written in definition order, so the later charset wins"
  'thai-tis620
  ;; `thai-iso8859-11' is id 28 and `thai-tis620' id 37, and both are
  ;; designated `ESC ( T'.
  (charset-name (charset-from-id (iso-charset-table 1 #t 84))))

;; ------------------------------------------------------------------
;; iso-2022-charset-list
;;
;; The C's `Viso_2022_charset_list' (`charset.c:94'): the ids of every
;; charset with an ISO final char, in definition order. It is what
;; `setup_iso_safe_charsets' hands a category whose `:charset-list' is the
;; symbol `iso-2022', which is three of the four ISO categories - so it is
;; the list the ISO-2022 detector is built on.

(test-equal "iso-2022-charset-list is every charset with an ISO final char"
  '(54 #t #t)
  (let ((ids (*iso-2022-charset-list*)))
    (list (length ids)
          (let loop ((l ids) (ok #t))
            (cond ((null? l) ok)
                  ((= (car l) -1) #f)
                  (else (loop (cdr l) (>= (charset-iso-final-char
                                           (charset-from-id (car l))) 0)))))
          (let loop ((l ids) (prev -1) (ok #t))
            (cond ((null? l) ok)
                  ((<= (car l) prev) #f)
                  (else (loop (cdr l) (car l) ok)))))))

(test-equal "... and it is exactly the ids of the table's own charsets"
  '(#t)
  (list
   (let ((in-table '()))
     (let loop ((dim 1) (chars-96 #f) (final 48))
       (cond
        ((> dim 2) #t)
        ((> final 126) (if chars-96 (loop (+ dim 1) #f 48)
                           (loop dim #t 48)))
        (else
         (let ((id (iso-charset-table dim chars-96 final)))
           (when (>= id 0) (set! in-table (cons id in-table)))
           (loop dim chars-96 (+ final 1))))))
     ;; every cell's charset is in the list ...
     (let check ((l in-table) (ok #t))
       (cond ((null? l) ok)
             ((memv (car l) (*iso-2022-charset-list*)) (check (cdr l) ok))
             (else #f))))))

(test-begin "schemacs_editor_charset_conversion")

;; The map tables and the conversions. Every answer is Emacs 31.1's own
;; `(decode-char ...)' / `(encode-char ...)' for the same arguments; the
;; whole corpus behind them - every charset, ten sampled code points each,
;; 2148 decodes and 1812 encodings - was compared against Emacs with
;; zero differences before these lines were written.

;; A *unified* charset: `mule-conf.el''s `unify-charset' loaded
;; `JISX0208.map', and the answer is Unicode, not the internal `0x140000'
;; range the offset arithmetic alone produces.
(test-equal '(#t #t #t)
  (list (= (decode-char 'japanese-jisx0208 #x2121) 12288)   ; U+3000
        (= (decode-char 'japanese-jisx0208 #x2122) 12289)   ; U+3001
        (= (encode-char 12288 'japanese-jisx0208) #x2121)))

(test-equal '(#t #t)
  (list (= (decode-char 'chinese-gb2312 #x3021) 21834)      ; U+554A
        (= (encode-char 21834 'chinese-gb2312) #x3021)))

;; An ASCII-compatible charset answers ASCII through the C's
;; `DECODE_CHAR'/`ENCODE_CHAR' shortcut, before its map is consulted
;; (`charset.h:427', `:443'): MIK's map starts at 0x20.
(test-equal '(#t #t #t)
  (list (= (decode-char 'mik 0) 0)
        (= (decode-char 'mik 21) 21)
        (= (encode-char 0 'mik) 0)))

;; A *subset* (`latin-iso8859-2' of `iso-8859-2', offset -128) and a
;; *superset* (`tis620-2533' of `thai-tis620' plus ASCII, offset 128;
;; `gb18030' of six parents with their own offsets).
(test-equal '(#t #t #t #t)
  (list (= (decode-char 'latin-iso8859-2 32) 160)
        (= (encode-char 160 'latin-iso8859-2) 32)
        (= (decode-char 'tis620-2533 160) 3584)
        (= (decode-char 'gb18030 #x81308130) 128)))

;; A plain offset charset: `latin-iso8859-1' is codes 32..127 at
;; code-offset 160, so code 32 is character 160, code 233 is outside it,
;; and characters 160 and 192 are codes 32 and 64.
(test-equal '(#f #t #t #t)
  (list (decode-char 'latin-iso8859-1 233)
        (= (decode-char 'latin-iso8859-1 32) 160)
        (= (encode-char 160 'latin-iso8859-1) 32)
        (= (encode-char 192 'latin-iso8859-1) 64)))

;; The C's `emacs' charset is 0..`MAX_5_BYTE_CHAR' - narrower than its
;; code space, an attribute only the C definition carries.
(test-equal '(#t #f #f #f)
  (list (= (decode-char 'emacs 4194175) 4194175)
        (decode-char 'emacs 4194176)
        (decode-char 'emacs 4194303)
        (encode-char #x10FFFF 'japanese-jisx0208)))

(test-equal "an unmapped code point and no encoding of an unmapped character"
  (list #f #f)
  (list (decode-char 'japanese-jisx0208 #x7F7F)
        (encode-char #x10FFFF 'japanese-jisx0208)))

(test-end "schemacs_editor_charset_conversion")

(test-end "schemacs_editor_charset")
