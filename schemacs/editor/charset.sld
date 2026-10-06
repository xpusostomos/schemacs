(define-library (schemacs editor charset)
  ;; This library mirrors GNU Emacs's `src/charset.c' - the charset
  ;; *registry*, which is what the ISO-2022 machinery reads.
  ;;
  ;; **What is here is the registry's metadata and not its code maps.** A
  ;; charset in Emacs is two things: who it is (an id, a dimension, an ISO
  ;; designation, a code space, an offset) and the code-to-character map
  ;; that its `:map' names (`charsets/JISX0208.map' and its like). The
  ;; second is a great deal of data and is only needed to *convert*
  ;; characters; the first is what `iso_charset_table' and
  ;; `setup_iso_safe_charsets' are built from, and it is what is ported
  ;; here. `define-charset' therefore records `:map' - so the maps have
  ;; their pointer when they come - and does not load it.
  ;;
  ;; The definition path is Emacs's two functions in their own files:
  ;; `mule.el''s `define-charset', which pads `:code-space' to eight
  ;; elements (`mule.el:270') and settles `:dimension' from the
  ;; *original* length (`:251'), and `charset.c''s
  ;; `define_charset_internal', whose code-space walk is ports of
  ;; `charset.c:866-904'.
  ;;
  ;; The data at the bottom is **Emacs 31.1's own charset set for every
  ;; charset that carries an ISO final char** - the same set that is
  ;; `iso-2022-charset-list', fifty-four of them - emitted by a script
  ;; that read a running Emacs's registry, in id order. It is a
  ;; transcription of Emacs's data and nothing else; `charset-tests.scm'
  ;; checks the table it produces against Emacs's own answers cell by
  ;; cell.

  (import (scheme base))

  (export
   charset? define-charset
   charset-id charset-name charset-dimension
   charset-iso-final-char charset-iso-chars-96
   charset-code-space charset-code-offset
   charset-max-code
   *charset-table* charset-from-id
   iso-charset-table
   *iso-2022-charset-list*)

  (begin

    (define-record-type <charset>
      ;; GNU Emacs's `struct charset' (`charset.h:150') as the fields the
      ;; ISO-2022 machinery reads. The C entry is here under the same name
      ;; and the same shape:
      ;;
      ;;   ID           `id', the index into `charset_table'
      ;;   NAME         the symbol it was defined as
      ;;   CODE-SPACE   `int code_space[15]', described below
      ;;   DIMENSION    `dimension', 1..4
      ;;   ISO-FINAL    `iso_final', 48..127, or -1 for a charset that is
      ;;                not ISO-2022 conformant
      ;;   ISO-CHARS-96 `iso_chars_96', true for a 96-character set
      ;;   CODE-OFFSET  `code_offset', the Emacs character a code point
      ;;                maps to
      ;;   MAP          the `:map' file name, recorded and not loaded
      ;;
      ;; CODE-SPACE is the C's fifteen ints: for dimension N,
      ;; `[4N]' is its least byte, `[4N+1]' its greatest, `[4N+2]' the
      ;; count of them, and `[4N+3]' the number of code points in
      ;; dimensions 0 through N - with no `[15]', so that last slot is
      ;; only written for N of 0, 1 and 2.
      (make-charset id name code-space dimension iso-final iso-chars-96
                    code-offset map)
      charset?
      (id charset-id)
      (name charset-name)
      (code-space charset-code-space)
      (dimension charset-dimension)
      (iso-final charset-iso-final-char)
      (iso-chars-96 charset-iso-chars-96)
      (code-offset charset-code-offset)
      (map charset-map))

    (define (charset-max-code charset)
      ;; The C's `charset.max_code' (`charset.c:910'): the greatest code
      ;; point, one byte of each dimension.
      ;;--------------------------------------------------------------
      (let ((cs (charset-code-space charset)))
        (logior (vector-ref cs 1)
                (ash (vector-ref cs 5) 8)
                (ash (vector-ref cs 9) 16)
                (ash (vector-ref cs 13) 24))))

    (define *charset-table* (make-parameter (make-vector 256 #f)))
    ;; ^ The C's `charset_table.start' (`charset.c:100'), a vector indexed
    ;; by charset id. A parameter because it is a *registry* that a test
    ;; may want to build up from nothing, the same reason
    ;; `*coding-system-table*' is one.

    (define (charset-from-id id)
      (and (exact-integer? id) (<= 0 id) (< id (vector-length (*charset-table*)))
           (vector-ref (*charset-table*) id)))

    (define *iso-2022-charset-list* (make-parameter '()))
    ;; ^ The C's `Viso_2022_charset_list' (`charset.c:94'): the ids of
    ;; every charset with an ISO final char, in the order they were
    ;; defined. `setup_iso_safe_charsets' hands this list to a category
    ;; whose `:charset-list' is the symbol `iso-2022' - "every charset
    ;; ISO-2022 can designate" - which is three of the four ISO
    ;; categories.

    ;;------------------------------------------------------------------
    ;; ISO_CHARSET_TABLE - the designation lookup
    ;;------------------------------------------------------------------
    ;;
    ;; GNU Emacs's `ISO_CHARSET_TABLE (dimension, chars_96, final)'
    ;; (`charset.h:499'), a three-dimensional table
    ;; `[ISO_MAX_DIMENSION][ISO_MAX_CHARS][ISO_MAX_FINAL]' - [3][2][128] -
    ;; whose cells are charset ids or -1. A designation sequence names one
    ;; by its dimension, whether it is the 96-character form, and its
    ;; final byte.
    ;;
    ;; The C has it as one array initialised to -1 in `init_charset_once'
    ;; and written by `define_charset_internal' (`charset.c:1155'). It is
    ;; a vector of vectors here, read through `iso-charset-table' the way
    ;; the C reads it through the macro.

    (define %iso-charset-table
      (list->vector
       (map (lambda (dimension)
              (list->vector
               (map (lambda (chars-96)
                      (make-vector 128 -1))
                    '(0 1))))
            '(0 1 2))))

    (define (iso-charset-table dimension chars-96 final)
      ;; GNU Emacs's `ISO_CHARSET_TABLE': the charset id designated by
      ;; FINAL in DIMENSION, or -1. CHARS-96 is true for the 96-character
      ;; form of the designation.
      ;;--------------------------------------------------------------
      (vector-ref
       (vector-ref (vector-ref %iso-charset-table (- dimension 1))
                   (if chars-96 1 0))
       final))

    (define (%set-iso-charset-table! dimension chars-96 final id)
      (vector-set! (vector-ref (vector-ref %iso-charset-table (- dimension 1))
                               (if chars-96 1 0))
                   final id))

    ;;------------------------------------------------------------------
    ;; define-charset
    ;;------------------------------------------------------------------

    (define (%plist-ref rest key default)
      ;; The value of KEY in the plist REST, or DEFAULT. `pair?' and not
      ;; `not' - an empty list is true in Scheme, which is the mistake
      ;; this tree has a section about.
      ;;--------------------------------------------------------------
      (let loop ((r rest))
        (cond ((or (null? r) (null? (cdr r))) default)
              ((eq? (car r) key) (cadr r))
              (else (loop (cddr r))))))

    (define (define-charset name code-space iso-final . rest)
      ;; GNU Emacs's `define-charset' (`mule.el:93') and
      ;; `define_charset_internal' (`charset.c:840'), as the registry
      ;; needs them.
      ;;
      ;; REST is the C's attribute list as a plist: `#:dimension',
      ;; `#:code-offset', `#:map'.
      ;;
      ;; **Two normalisations happen before the C is reached and both are
      ;; ported**, because both change the answer. `:code-space' is
      ;; padded to eight elements (`mule.el:270') - the C's walk reads
      ;; four pairs whatever the caller gave - and `:dimension' is
      ;; settled from the *original* length of `:code-space'
      ;; (`mule.el:251'), not the padded one, so a two-element
      ;; `#(0 127)' is dimension 1 and not 4.
      ;;--------------------------------------------------------------
      (let* ((dimension (or (%plist-ref rest #:dimension #f)
                            (quotient (vector-length code-space) 2)))
             (padded (if (< (vector-length code-space) 8)
                         (let ((v (make-vector 8 0)))
                           (let loop ((i 0))
                             (if (>= i (vector-length code-space))
                                 v
                                 (begin (vector-set! v i (vector-ref code-space i))
                                        (loop (+ i 1))))))
                         code-space))
             (cs (make-vector 15 0)))
        ;; `charset.c:866-881' - the code-space walk.
        (let ((derived 0) (nchars 1))
          (let loop ((i 0))
            (let* ((min-byte (vector-ref padded (* i 2)))
                   (max-byte (vector-ref padded (+ (* i 2) 1))))
              (vector-set! cs (* i 4) min-byte)
              (vector-set! cs (+ (* i 4) 1) max-byte)
              (vector-set! cs (+ (* i 4) 2) (- max-byte min-byte -1))
              (if (> max-byte 0) (set! derived (+ i 1)))
              (if (< i 3)
                  (begin
                    (set! nchars (* nchars (vector-ref cs (+ (* i 4) 2))))
                    (vector-set! cs (+ (* i 4) 3) nchars)
                    (loop (+ i 1))))))
          (set! dimension (if dimension dimension derived)))
        ;; `charset.c:904' - a 96-character set is one whose *first*
        ;; dimension holds 96 of them.
        (let ((table (*charset-table*))
              (id (%next-charset-id)))
          (let ((charset (make-charset id name cs dimension iso-final
                                       (= 96 (vector-ref cs 2))
                                       (%plist-ref rest #:code-offset 0)
                                       (%plist-ref rest #:map #f))))
            (if (>= id (vector-length table))
                (error "No room in the charset table for" name))
            (vector-set! table id charset)
            ;; `charset.c:1155-1160' - a charset with an ISO final char
            ;; takes its cell in the designation table and joins
            ;; `iso-2022-charset-list'.
            (if (>= iso-final 0)
                (begin
                  (%set-iso-charset-table! dimension
                                           (= 96 (vector-ref cs 2))
                                           iso-final id)
                  (*iso-2022-charset-list*
                   (append (*iso-2022-charset-list*) (list id)))))
            charset))))

    (define %next-charset-id
      ;; The C's `charset_table.next' (`charset.c:1145'): ids are handed
      ;; out in definition order, which is what makes
      ;; `iso-2022-charset-list' come out in id order.
      ;;--------------------------------------------------------------
      (let ((n 0))
        (lambda () (let ((id n)) (set! n (+ n 1)) id))))

    ;;------------------------------------------------------------------
    ;; Emacs 31.1's charsets with an ISO-2022 designation
    ;;------------------------------------------------------------------
    ;;
    ;; From a running Emacs's registry, in id order. Each is the code
    ;; space, the ISO final char (-1 for a charset that has none) and the
    ;; dimension the C is handed, plus the code offset and map name where
    ;; they are not the defaults. `:code-space' is the *unpadded* vector -
    ;; `define-charset' above pads it, as `mule.el' does.
    ;;
    ;; `iso-8859-1' (id 1) and `latin-iso8859-1' (id 5) are both here and
    ;; are different charsets: the first is the whole 8-bit set, with no
    ;; ISO final char, and the second is the right-hand part of it, which
    ;; is what `ESC ( A' designates.

;; 179 charsets
    (define-charset 'ascii #(0 127) 66 #:dimension 1)
    (define-charset 'iso-8859-1 #(0 255) -1 #:dimension 1)
    (define-charset 'unicode #(0 255 0 255 0 16) -1 #:dimension 3)
    (define-charset 'emacs #(0 255 0 255 0 63) -1 #:dimension 3)
    (define-charset 'eight-bit #(128 255) -1 #:dimension 1 #:code-offset 4194176)
    (define-charset 'latin-iso8859-1 #(32 127) 65 #:dimension 1 #:code-offset 160)
    (define-charset 'control-1 #(128 159) -1 #:dimension 1 #:code-offset 128)
    (define-charset 'eight-bit-control #(128 159) -1 #:dimension 1 #:code-offset 4194176)
    (define-charset 'eight-bit-graphic #(160 255) -1 #:dimension 1 #:code-offset 4194208)
    (define-charset 'iso-8859-2 #(0 255) -1 #:dimension 1 #:map "8859-2")
    (define-charset 'latin-iso8859-2 #(32 127) 66 #:dimension 1)
    (define-charset 'iso-8859-3 #(0 255) -1 #:dimension 1 #:map "8859-3")
    (define-charset 'latin-iso8859-3 #(32 127) 67 #:dimension 1)
    (define-charset 'iso-8859-4 #(0 255) -1 #:dimension 1 #:map "8859-4")
    (define-charset 'latin-iso8859-4 #(32 127) 68 #:dimension 1)
    (define-charset 'iso-8859-5 #(0 255) -1 #:dimension 1 #:map "8859-5")
    (define-charset 'cyrillic-iso8859-5 #(32 127) 76 #:dimension 1)
    (define-charset 'iso-8859-6 #(0 255) -1 #:dimension 1 #:map "8859-6")
    (define-charset 'arabic-iso8859-6 #(32 127) 71 #:dimension 1)
    (define-charset 'iso-8859-7 #(0 255) -1 #:dimension 1 #:map "8859-7")
    (define-charset 'greek-iso8859-7 #(32 127) 70 #:dimension 1)
    (define-charset 'iso-8859-8 #(0 255) -1 #:dimension 1 #:map "8859-8")
    (define-charset 'hebrew-iso8859-8 #(32 127) 72 #:dimension 1)
    (define-charset 'iso-8859-9 #(0 255) -1 #:dimension 1 #:map "8859-9")
    (define-charset 'latin-iso8859-9 #(32 127) 77 #:dimension 1)
    (define-charset 'iso-8859-10 #(0 255) -1 #:dimension 1 #:map "8859-10")
    (define-charset 'latin-iso8859-10 #(32 127) 86 #:dimension 1)
    (define-charset 'iso-8859-11 #(0 255) -1 #:dimension 1 #:map "8859-11")
    (define-charset 'thai-iso8859-11 #(32 127) 84 #:dimension 1)
    (define-charset 'iso-8859-13 #(0 255) -1 #:dimension 1 #:map "8859-13")
    (define-charset 'latin-iso8859-13 #(32 127) 89 #:dimension 1)
    (define-charset 'iso-8859-14 #(0 255) -1 #:dimension 1 #:map "8859-14")
    (define-charset 'latin-iso8859-14 #(32 127) 95 #:dimension 1)
    (define-charset 'iso-8859-15 #(0 255) -1 #:dimension 1 #:map "8859-15")
    (define-charset 'latin-iso8859-15 #(32 127) 98 #:dimension 1)
    (define-charset 'iso-8859-16 #(0 255) -1 #:dimension 1 #:map "8859-16")
    (define-charset 'latin-iso8859-16 #(32 127) 102 #:dimension 1)
    (define-charset 'thai-tis620 #(32 127) 84 #:dimension 1 #:code-offset 3584)
    (define-charset 'tis620-2533 #(0 255) -1 #:dimension 1)
    (define-charset 'jisx0201 #(0 223) -1 #:dimension 1 #:map "JISX0201")
    (define-charset 'latin-jisx0201 #(33 126) 74 #:dimension 1)
    (define-charset 'katakana-jisx0201 #(33 126) 73 #:dimension 1)
    (define-charset 'chinese-gb2312 #(33 126 33 126) 65 #:dimension 2 #:code-offset 1114112)
    (define-charset 'chinese-gbk #(64 254 129 254) -1 #:dimension 2 #:code-offset 1441792)
    (define-charset 'chinese-cns11643-1 #(33 126 33 126) 71 #:dimension 2 #:code-offset 1130496)
    (define-charset 'chinese-cns11643-2 #(33 126 33 126) 72 #:dimension 2 #:code-offset 1146880)
    (define-charset 'chinese-cns11643-3 #(33 126 33 126) 73 #:dimension 2 #:code-offset 1163264)
    (define-charset 'chinese-cns11643-4 #(33 126 33 126) 74 #:dimension 2 #:code-offset 1179648)
    (define-charset 'chinese-cns11643-5 #(33 126 33 126) 75 #:dimension 2 #:code-offset 1196032)
    (define-charset 'chinese-cns11643-6 #(33 126 33 126) 76 #:dimension 2 #:code-offset 1212416)
    (define-charset 'chinese-cns11643-7 #(33 126 33 126) 77 #:dimension 2 #:code-offset 1228800)
    (define-charset 'big5 #(64 254 161 254) -1 #:dimension 2 #:code-offset 1245184)
    (define-charset 'chinese-big5-1 #(33 126 33 126) 48 #:dimension 2 #:code-offset 1265664)
    (define-charset 'chinese-big5-2 #(33 126 33 126) 49 #:dimension 2 #:code-offset 1275904)
    (define-charset 'japanese-jisx0208 #(33 126 33 126) 66 #:dimension 2 #:code-offset 1310720)
    (define-charset 'japanese-jisx0208-1978 #(33 126 33 126) 64 #:dimension 2 #:code-offset 1327104)
    (define-charset 'japanese-jisx0212 #(33 126 33 126) 68 #:dimension 2 #:code-offset 1343488)
    (define-charset 'japanese-jisx0213-1 #(33 126 33 126) 79 #:dimension 2 #:code-offset 1359872)
    (define-charset 'japanese-jisx0213-2 #(33 126 33 126) 80 #:dimension 2 #:code-offset 1376256)
    (define-charset 'japanese-jisx0213-a #(33 126 33 126) -1 #:dimension 2 #:map "JISX213A")
    (define-charset 'japanese-jisx0213.2004-1 #(33 126 33 126) 81 #:dimension 2)
    (define-charset 'katakana-sjis #(161 223) -1 #:dimension 1)
    (define-charset 'cp932-2-byte #(64 252 129 252) -1 #:dimension 2 #:map "CP932-2BYTE")
    (define-charset 'cp932 #(0 255 0 254) -1 #:dimension 2)
    (define-charset 'korean-ksc5601 #(33 126 33 126) 67 #:dimension 2 #:code-offset 2596756)
    (define-charset 'big5-hkscs #(64 254 161 254) -1 #:dimension 2 #:code-offset 2605592)
    (define-charset 'cp949-2-byte #(65 254 129 253) -1 #:dimension 2 #:map "CP949-2BYTE")
    (define-charset 'cp949 #(0 254 0 253) -1 #:dimension 2)
    (define-charset 'chinese-sisheng #(33 126) 48 #:dimension 1 #:code-offset 2097152)
    (define-charset 'ipa #(32 127) 48 #:dimension 1 #:code-offset 2097280)
    (define-charset 'viscii #(0 255) -1 #:dimension 1 #:map "VISCII")
    (define-charset 'vietnamese-viscii-lower #(32 127) 49 #:dimension 1 #:code-offset 2097664)
    (define-charset 'vietnamese-viscii-upper #(32 127) 50 #:dimension 1 #:code-offset 2097792)
    (define-charset 'vscii #(0 255) -1 #:dimension 1 #:map "VSCII")
    (define-charset 'vscii-2 #(0 255) -1 #:dimension 1 #:map "VSCII-2")
    (define-charset 'koi8-r #(0 255) -1 #:dimension 1 #:map "KOI8-R")
    (define-charset 'alternativnyj #(0 255) -1 #:dimension 1 #:map "ALTERNATIVNYJ")
    (define-charset 'cp866 #(0 255) -1 #:dimension 1 #:map "IBM866")
    (define-charset 'koi8-u #(0 255) -1 #:dimension 1 #:map "KOI8-U")
    (define-charset 'koi8-t #(0 255) -1 #:dimension 1 #:map "KOI8-T")
    (define-charset 'georgian-ps #(0 255) -1 #:dimension 1 #:map "KA-PS")
    (define-charset 'georgian-academy #(0 255) -1 #:dimension 1 #:map "KA-ACADEMY")
    (define-charset 'windows-1250 #(0 255) -1 #:dimension 1 #:map "CP1250")
    (define-charset 'windows-1251 #(0 255) -1 #:dimension 1 #:map "CP1251")
    (define-charset 'windows-1252 #(0 255) -1 #:dimension 1 #:map "CP1252")
    (define-charset 'windows-1253 #(0 255) -1 #:dimension 1 #:map "CP1253")
    (define-charset 'windows-1254 #(0 255) -1 #:dimension 1 #:map "CP1254")
    (define-charset 'windows-1255 #(0 255) -1 #:dimension 1 #:map "CP1255")
    (define-charset 'windows-1256 #(0 255) -1 #:dimension 1 #:map "CP1256")
    (define-charset 'windows-1257 #(0 255) -1 #:dimension 1 #:map "CP1257")
    (define-charset 'windows-1258 #(0 255) -1 #:dimension 1 #:map "CP1258")
    (define-charset 'next #(0 255) -1 #:dimension 1 #:map "NEXTSTEP")
    (define-charset 'cp1125 #(0 255) -1 #:dimension 1 #:map "CP1125")
    (define-charset 'cp437 #(0 255) -1 #:dimension 1 #:map "IBM437")
    (define-charset 'cp720 #(0 255) -1 #:dimension 1 #:map "CP720")
    (define-charset 'cp737 #(0 255) -1 #:dimension 1 #:map "CP737")
    (define-charset 'cp775 #(0 255) -1 #:dimension 1 #:map "CP775")
    (define-charset 'cp851 #(0 255) -1 #:dimension 1 #:map "IBM851")
    (define-charset 'cp852 #(0 255) -1 #:dimension 1 #:map "IBM852")
    (define-charset 'cp855 #(0 255) -1 #:dimension 1 #:map "IBM855")
    (define-charset 'cp857 #(0 255) -1 #:dimension 1 #:map "IBM857")
    (define-charset 'cp858 #(0 255) -1 #:dimension 1 #:map "CP858")
    (define-charset 'cp860 #(0 255) -1 #:dimension 1 #:map "IBM860")
    (define-charset 'cp861 #(0 255) -1 #:dimension 1 #:map "IBM861")
    (define-charset 'cp862 #(0 255) -1 #:dimension 1 #:map "IBM862")
    (define-charset 'cp863 #(0 255) -1 #:dimension 1 #:map "IBM863")
    (define-charset 'cp864 #(0 255) -1 #:dimension 1 #:map "IBM864")
    (define-charset 'cp865 #(0 255) -1 #:dimension 1 #:map "IBM865")
    (define-charset 'cp869 #(0 255) -1 #:dimension 1 #:map "IBM869")
    (define-charset 'cp874 #(0 255) -1 #:dimension 1 #:map "IBM874")
    (define-charset 'arabic-digit #(34 42) 50 #:dimension 1 #:code-offset 1536)
    (define-charset 'arabic-1-column #(33 126) 51 #:dimension 1 #:code-offset 2097408)
    (define-charset 'arabic-2-column #(33 126) 52 #:dimension 1 #:code-offset 2097536)
    (define-charset 'lao #(33 126) 49 #:dimension 1 #:code-offset 3713)
    (define-charset 'mule-lao #(0 255) -1 #:dimension 1)
    (define-charset 'indian-is13194 #(33 126) 53 #:dimension 1 #:code-offset 1572864)
    (define-charset 'devanagari-cdac #(0 255) -1 #:dimension 1 #:code-offset 1573120)
    (define-charset 'sanskrit-cdac #(0 255) -1 #:dimension 1 #:code-offset 1573376)
    (define-charset 'bengali-cdac #(0 255) -1 #:dimension 1 #:code-offset 1573632)
    (define-charset 'tamil-cdac #(0 255) -1 #:dimension 1 #:code-offset 1573888)
    (define-charset 'telugu-cdac #(0 255) -1 #:dimension 1 #:code-offset 1574144)
    (define-charset 'assamese-cdac #(0 255) -1 #:dimension 1 #:code-offset 1574400)
    (define-charset 'oriya-cdac #(0 255) -1 #:dimension 1 #:code-offset 1574656)
    (define-charset 'kannada-cdac #(0 255) -1 #:dimension 1 #:code-offset 1574912)
    (define-charset 'malayalam-cdac #(0 255) -1 #:dimension 1 #:code-offset 1575168)
    (define-charset 'gujarati-cdac #(0 255) -1 #:dimension 1 #:code-offset 1575424)
    (define-charset 'punjabi-cdac #(0 255) -1 #:dimension 1 #:code-offset 1575680)
    (define-charset 'devanagari-akruti #(0 255) -1 #:dimension 1 #:code-offset 1575936)
    (define-charset 'bengali-akruti #(0 255) -1 #:dimension 1 #:code-offset 1576192)
    (define-charset 'punjabi-akruti #(0 255) -1 #:dimension 1 #:code-offset 1576448)
    (define-charset 'gujarati-akruti #(0 255) -1 #:dimension 1 #:code-offset 1576704)
    (define-charset 'oriya-akruti #(0 255) -1 #:dimension 1 #:code-offset 1576960)
    (define-charset 'tamil-akruti #(0 255) -1 #:dimension 1 #:code-offset 1577216)
    (define-charset 'telugu-akruti #(0 255) -1 #:dimension 1 #:code-offset 1577472)
    (define-charset 'kannada-akruti #(0 255) -1 #:dimension 1 #:code-offset 1577728)
    (define-charset 'malayalam-akruti #(0 255) -1 #:dimension 1 #:code-offset 1577984)
    (define-charset 'indian-glyph #(32 127 32 127) 52 #:dimension 2 #:code-offset 1573120)
    (define-charset 'indian-1-column #(33 126 33 126) 54 #:dimension 2 #:code-offset 1589248)
    (define-charset 'indian-2-column #(33 126 33 126) 53 #:dimension 2 #:code-offset 1589248)
    (define-charset 'tibetan #(33 126 33 37) 55 #:dimension 2 #:code-offset 1638400)
    (define-charset 'tibetan-1-column #(33 126 33 37) 56 #:dimension 2 #:code-offset 1638400)
    (define-charset 'mule-unicode-2500-33ff #(32 127 32 71) 50 #:dimension 2 #:code-offset 9472)
    (define-charset 'mule-unicode-e000-ffff #(32 127 32 117) 51 #:dimension 2 #:code-offset 57344)
    (define-charset 'mule-unicode-0100-24ff #(32 127 32 127) 49 #:dimension 2 #:code-offset 256)
    (define-charset 'unicode-bmp #(0 255 0 255) -1 #:dimension 2)
    (define-charset 'unicode-smp #(0 255 0 255) -1 #:dimension 2 #:code-offset 65536)
    (define-charset 'unicode-sip #(0 255 0 255) -1 #:dimension 2 #:code-offset 131072)
    (define-charset 'unicode-ssp #(0 255 0 255) -1 #:dimension 2 #:code-offset 917504)
    (define-charset 'ethiopic #(33 126 33 126) 51 #:dimension 2 #:code-offset 1703936)
    (define-charset 'mac-roman #(0 255) -1 #:dimension 1 #:map "MACINTOSH")
    (define-charset 'ebcdic-us #(0 255) -1 #:dimension 1 #:map "EBCDICUS")
    (define-charset 'ebcdic-uk #(0 255) -1 #:dimension 1 #:map "EBCDICUK")
    (define-charset 'ibm038 #(0 255) -1 #:dimension 1 #:map "IBM038")
    (define-charset 'ibm256 #(0 255) -1 #:dimension 1 #:map "IBM256")
    (define-charset 'ibm273 #(0 255) -1 #:dimension 1 #:map "IBM273")
    (define-charset 'ibm274 #(0 255) -1 #:dimension 1 #:map "IBM274")
    (define-charset 'ibm275 #(0 255) -1 #:dimension 1 #:map "IBM275")
    (define-charset 'ibm277 #(0 255) -1 #:dimension 1 #:map "IBM277")
    (define-charset 'ibm278 #(0 255) -1 #:dimension 1 #:map "IBM278")
    (define-charset 'ibm280 #(0 255) -1 #:dimension 1 #:map "IBM280")
    (define-charset 'ibm281 #(0 255) -1 #:dimension 1 #:map "IBM281")
    (define-charset 'ibm284 #(0 255) -1 #:dimension 1 #:map "IBM284")
    (define-charset 'ibm285 #(0 255) -1 #:dimension 1 #:map "IBM285")
    (define-charset 'ibm290 #(0 255) -1 #:dimension 1 #:map "IBM290")
    (define-charset 'ibm297 #(0 255) -1 #:dimension 1 #:map "IBM297")
    (define-charset 'ibm1047 #(0 255) -1 #:dimension 1 #:map "IBM1047")
    (define-charset 'hp-roman8 #(0 255) -1 #:dimension 1 #:map "HP-ROMAN8")
    (define-charset 'adobe-standard-encoding #(32 255) -1 #:dimension 1 #:map "stdenc")
    (define-charset 'symbol #(32 255) -1 #:dimension 1 #:map "symbol")
    (define-charset 'ibm850 #(0 255) -1 #:dimension 1 #:map "IBM850")
    (define-charset 'mik #(0 255) -1 #:dimension 1 #:map "MIK")
    (define-charset 'ptcp154 #(0 255) -1 #:dimension 1 #:map "PTCP154")
    (define-charset 'gb18030-2-byte #(64 254 129 254) -1 #:dimension 2 #:map "GB180302")
    (define-charset 'gb18030-4-byte-bmp #(48 57 129 254 48 57 129 132) -1 #:dimension 4 #:map "GB180304")
    (define-charset 'gb18030-4-byte-smp #(48 57 129 254 48 57 144 227) -1 #:dimension 4 #:code-offset 65536)
    (define-charset 'gb18030-4-byte-ext-1 #(48 57 129 254 48 57 132 143) -1 #:dimension 4 #:code-offset 2097152)
    (define-charset 'gb18030-4-byte-ext-2 #(48 57 129 254 48 57 227 254) -1 #:dimension 4 #:code-offset 2246732)
    (define-charset 'gb18030 #(0 255 0 254 0 254 0 254) -1 #:dimension 4)
    (define-charset 'chinese-cns11643-15 #(33 126 33 126) -1 #:dimension 2 #:code-offset 2623546)
))
