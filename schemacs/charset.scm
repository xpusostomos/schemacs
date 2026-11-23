(define-library (schemacs charset)
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

  (import (scheme base)
          ;; `open-input-file' and `file-exists?', for the map files.
          (scheme file)
          ;; `ash', `logand' and `logior' - the code-space and index
          ;; arithmetic - and `caddr' (which `(scheme base)' does not
          ;; export in this Guile), plus `%load-path', which finds the
          ;; tree's copy of the maps the way `splash-file' finds its text.
          (only (guile) ash logand logior caddr %load-path canonicalize-path)
          ;; the encoder and the unify table are char-tables, as in the C
          (only (schemacs chartab)
                make-char-table char-table? char-table-ref char-table-set
                char-table-set-range max-char)
          ;; `MAX_5_BYTE_CHAR', which bounds the unification lookup
          (only (schemacs character) *max-5-byte-char*))

  (export
   charset? define-charset
   charset-id charset-name charset-dimension
   charset-iso-final-char charset-iso-chars-96
   charset-code-space charset-code-offset
   charset-min-code charset-max-code
   charset-min-char charset-max-char
   charset-compact-codes-p charset-ascii-compatible-p
   charset-invalid-code
   *charset-table* charset-from-id charset-by-name
   iso-charset-table
   *iso-2022-charset-list*
   ;; the map tables and the two conversions
   *charset-map-path*
   decode-char encode-char
   ;; unification
   unify-charset *char-unify-table*
   charset-unified? charset-unify-map)

  (begin

    (define-record-type <charset>
      ;; GNU Emacs's `struct charset' (`charset.h:150'), field for field as
      ;; far as this tree can use them. The record and its accessors are
      ;; the C's:
      ;;
      ;;   ID, NAME, CODE-SPACE, DIMENSION, ISO-FINAL, ISO-CHARS-96  ...
      ;;   MIN-CODE / MAX-CODE   the code-point range, one byte per
      ;;                         dimension with each dimension's minimum
      ;;                         in its low byte (`charset.c:913')
      ;;   CODE-LINEAR-P         `code-point - MIN-CODE' is the index
      ;;   CODE-SPACE-MASK       per byte, which dimensions may use it
      ;;   CHAR-INDEX-OFFSET     the C's `char_index_offset'
      ;;   COMPACT-CODES-P       every code point below 0x10000
      ;;   ASCII-COMPATIBLE-P    ASCII characters mean themselves
      ;;   SUBSET / SUPERSET     `CHARSET_METHOD_SUBSET''s
      ;;                         (PARENT MIN MAX OFFSET) vector, and
      ;;                         `CHARSET_METHOD_SUPERSET''s list of
      ;;                         (CHARSET . OFFSET) - the C keeps them in
      ;;                         the attribute vector
      ;;   MIN-CHAR / MAX-CHAR   the character range (for a MAP charset
      ;;                         these come from the map, so they are #f
      ;;                         until it is loaded - the C's dump has
      ;;                         them; here they are loaded on demand)
      ;;   INVALID-CODE          `ENCODE_CHAR''s not-encodable answer
      ;;   FAST-MAP              190 bytes of "may contain C" bits
      ;;   DECODER / ENCODER     the loaded map's two directions
      ;;   UNIFY-MAP             the `:unify-map' file, and UNIFIED? its
      ;;                         loaded state; DEUNIFIER is the reverse
      ;;                         table `encode_char' reads
      ;;
      ;; MAP is the `:map' name ("JISX0208"), kept as Emacs keeps it in
      ;; the charset's attributes; `#f' means the charset has no map and
      ;; is OFFSET-based.
      (make-charset id name code-space dimension iso-final iso-chars-96
                    code-offset map
                    min-code max-code code-linear-p code-space-mask
                    char-index-offset compact-codes-p ascii-compatible-p
                    subset superset
                    min-char max-char invalid-code fast-map decoder encoder
                    unify-map unified? deunifier)
      charset?
      (id charset-id)
      (name charset-name)
      (code-space charset-code-space)
      (dimension charset-dimension)
      (iso-final charset-iso-final-char)
      (iso-chars-96 charset-iso-chars-96)
      (code-offset charset-code-offset)
      (map charset-map)
      (min-code charset-min-code)
      (max-code charset-max-code)
      (code-linear-p charset-code-linear-p)
      (code-space-mask charset-code-space-mask)
      (char-index-offset charset-char-index-offset)
      (compact-codes-p charset-compact-codes-p)
      (ascii-compatible-p charset-ascii-compatible-p
                          %set!charset-ascii-compatible-p!)
      (subset charset-subset)
      (superset charset-superset)
      (min-char charset-min-char %set!charset-min-char!)
      (max-char charset-max-char %set!charset-max-char!)
      (invalid-code charset-invalid-code)
      (fast-map charset-fast-map %set!charset-fast-map!)
      (decoder charset-decoder %set!charset-decoder!)
      (encoder charset-encoder %set!charset-encoder!)
      (unify-map charset-unify-map %set!charset-unify-map!)
      (unified? charset-unified? %set!charset-unified?!)
      (deunifier charset-deunifier %set!charset-deunifier!))

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
      ;; `#:code-offset', `#:map', `#:subset', `#:superset',
      ;; `#:min-code', `#:max-code', `#:ascii-compatible-p'.
      ;;
      ;; **Two normalisations happen before the C is reached and both are
      ;; ported**, because both change the answer. `:code-space' is
      ;; padded to eight elements (`mule.el:270') - the C's walk reads
      ;; four pairs whatever the caller gave - and `:dimension' is
      ;; settled from the *original* length of `:code-space'
      ;; (`mule.el:251'), not the padded one, so a two-element
      ;; `#(0 127)' is dimension 1 and not 4.
      ;;
      ;; The record's fields are `define_charset_internal''s
      ;; (`charset.c:866-1160'): the code-space walk, the linear test, the
      ;; byte mask, the code-point range (with `:min-code'/`:max-code'
      ;; overrides; a 32-bit value arrives as a `(HI . LO)' cons), the
      ;; compact-codes and invalid-code answers, and one of the four
      ;; methods. A `:map' charset's MIN-CHAR and MAX-CHAR stay #f until
      ;; its map is loaded (`%charset-ensure-defined'); a `:code-offset'
      ;; charset's are arithmetic here, exactly the C's `:997-1024'
      ;; block, FAST-MAP bits included; a `:subset'/`:superset' copies
      ;; its parents', after loading them if they are maps.
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
        (let* ((code-linear-p
                (or (= dimension 1)
                    (and (= (vector-ref cs 2) 256)
                         (or (= dimension 2)
                             (and (= (vector-ref cs 6) 256)
                                  (or (= dimension 3)
                                      (= (vector-ref cs 10) 256)))))))
               (code-space-mask
                (and (not code-linear-p)
                     (let ((mask (make-vector 256 0)))
                       (let loop ((i 0))
                         (if (>= i 4)
                             mask
                             (let inner ((b (vector-ref cs (* i 4))))
                               (if (<= b (vector-ref cs (+ (* i 4) 1)))
                                   (begin
                                     (vector-set! mask b
                                                  (logior (vector-ref mask b)
                                                          (ash 1 i)))
                                     (inner (+ b 1)))
                                   (loop (+ i 1)))))))))
               (min-code-orig (logior (vector-ref cs 0)
                                      (ash (vector-ref cs 4) 8)
                                      (ash (vector-ref cs 8) 16)
                                      (ash (vector-ref cs 12) 24)))
               (max-code-attr (%plist-ref rest #:max-code #f))
               (max-code (if max-code-attr
                             (%cons-to-unsigned max-code-attr)
                             (logior (vector-ref cs 1)
                                     (ash (vector-ref cs 5) 8)
                                     (ash (vector-ref cs 9) 16)
                                     (ash (vector-ref cs 13) 24))))
               (min-code-attr (%plist-ref rest #:min-code #f))
               (min-code (if min-code-attr
                             (%cons-to-unsigned min-code-attr)
                             min-code-orig))
               (char-index-offset
                (if min-code-attr
                    (%code-point-to-index code-linear-p code-space-mask cs
                                          min-code-orig 0 min-code)
                    0))
               (code-offset (%plist-ref rest #:code-offset 0))
               (map-name (%plist-ref rest #:map #f))
               (subset-attr (%plist-ref rest #:subset #f))
               (superset-attr (%plist-ref rest #:superset #f))
               (unify-map (%plist-ref rest #:unify-map #f))
               (subset
                (and subset-attr
                     (let ((parent (charset-by-name (car subset-attr))))
                       (unless parent
                         (error "Unknown charset in :subset" (car subset-attr)))
                       (vector (charset-id parent)
                               (cadr subset-attr)
                               (caddr subset-attr)
                               (list-ref subset-attr 3)))))
               (superset
                (and superset-attr
                     (map (lambda (elt)
                            (let* ((sym (if (pair? elt) (car elt) elt))
                                   (offset (if (pair? elt) (cdr elt) 0))
                                   (parent (charset-by-name sym)))
                              (unless parent
                                (error "Unknown charset in :superset" sym))
                              (cons (charset-id parent) offset)))
                          superset-attr)))
               (table (*charset-table*))
               (id (%next-charset-id))
               (charset (make-charset
                         id name cs dimension iso-final
                         (= 96 (vector-ref cs 2))
                         code-offset map-name
                         min-code max-code code-linear-p code-space-mask
                         char-index-offset
                         (< max-code #x10000)           ; compact-codes-p
                         (and map-name (%plist-ref rest #:ascii-compatible-p #f))
                         subset superset
                         #f #f                          ; min-char, max-char
                         (if (> min-code 0) 0 (+ max-code 1))
                         (make-vector 190 0)
                         #f #f
                         unify-map #f #f)))
          (if (>= id (vector-length table))
              (error "No room in the charset table for" name))
          (vector-set! table id charset)
          (let ((method (cond (subset 'subset)
                              (superset 'superset)
                              (map-name 'map)
                              (else 'offset))))
            (cond
             ;; The OFFSET half of `define_charset_internal'
             ;; (`charset.c:997-1024').
             ((eq? method 'offset)
              (let ((max-c (+ (%charset-code-point-to-index charset max-code)
                              code-offset))
                    (min-c (+ (%charset-code-point-to-index charset min-code)
                              code-offset))
                    (fast-map (charset-fast-map charset)))
                (%set!charset-max-char! charset max-c)
                (%set!charset-min-char! charset min-c)
                (let ((i (ash (ash min-c -7) 7)))
                  (let loop ()
                    (when (and (< i #x10000) (<= i max-c))
                      (%charset-fast-map-set! i fast-map)
                      (set! i (+ i 128))
                      (loop)))
                  (set! i (ash (ash i -12) 12))
                  (let loop2 ()
                    (when (<= i max-c)
                      (%charset-fast-map-set! i fast-map)
                      (set! i (+ i #x1000))
                      (loop2))))
                (when (and (= code-offset 0) (>= max-c #x80))
                  (%set!charset-ascii-compatible-p! charset #t))))
             ;; SUBset: "copy the parent's fast_map. It's not accurate, but
             ;; at least it works for quickly detecting which character
             ;; DOESN'T belong to this charset." (`charset.c:1048')
             ((eq? method 'subset)
              (let ((parent (charset-from-id (vector-ref subset 0))))
                (%charset-ensure-defined parent)
                (%set!charset-fast-map! charset
                                        (vector-copy (charset-fast-map parent)))
                (%set!charset-min-char! charset (charset-min-char parent))
                (%set!charset-max-char! charset (charset-max-char parent))))
             ;; SUPerset: the union of the parents' ranges and fast maps.
             ((eq? method 'superset)
              (let ((lo max-char)
                    (hi 0)
                    (fast-map (charset-fast-map charset)))
                (for-each
                 (lambda (parent-entry)
                   (let ((parent (charset-from-id (car parent-entry))))
                     (%charset-ensure-defined parent)
                     (when (< (charset-min-char parent) lo)
                       (set! lo (charset-min-char parent)))
                     (when (> (charset-max-char parent) hi)
                       (set! hi (charset-max-char parent)))
                     (let ((parent-fast (charset-fast-map parent)))
                       (let loop ((i 0))
                         (when (< i 190)
                           (vector-set! fast-map i
                                        (logior (vector-ref fast-map i)
                                                (vector-ref parent-fast i)))
                           (loop (+ i 1)))))))
                 superset)
                (%set!charset-min-char! charset lo)
                (%set!charset-max-char! charset hi)))))
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
          charset)))

    (define %next-charset-id
      ;; The C's `charset_table.next' (`charset.c:1145'): ids are handed
      ;; out in definition order, which is what makes
      ;; `iso-2022-charset-list' come out in id order.
      ;;--------------------------------------------------------------
      (let ((n 0))
        (lambda () (let ((id n)) (set! n (+ n 1)) id))))

    ;;------------------------------------------------------------------
    ;;------------------------------------------------------------------
    ;; Code points and character indices
    ;;------------------------------------------------------------------
    ;;
    ;; `CODE_POINT_TO_INDEX' (`charset.c:105') and `INDEX_TO_CODE_POINT'
    ;; (`:124'): a charset's map is indexed by a dense "character index",
    ;; the code point with each dimension's minimum subtracted and the
    ;; dimensions laid end to end. A linear charset is its own index minus
    ;; the minimum; anything else runs the C's four-dimension arithmetic,
    ;; and -1 answers "not in this charset".

    (define (%code-point-to-index linear? mask cs min-code char-index-offset code)
      ;; The macro's arithmetic over the fields, so `define-charset' can run
      ;; it before the record exists - a `:min-code' attribute needs the
      ;; index of the overridden minimum, computed against the original one
      ;; (`charset.c:928-940').
      ;;--------------------------------------------------------------
      (if linear?
          (- code min-code)
          (if (and (not (zero? (logand (vector-ref mask (ash code -24)) #x8)))
                   (not (zero? (logand (vector-ref mask (logand (ash code -16) #xFF)) #x4)))
                   (not (zero? (logand (vector-ref mask (logand (ash code -8) #xFF)) #x2)))
                   (not (zero? (logand (vector-ref mask (logand code #xFF)) #x1))))
              (- (+ (* (- (ash code -24) (vector-ref cs 12))
                       (vector-ref cs 11))
                    (* (- (logand (ash code -16) #xFF) (vector-ref cs 8))
                       (vector-ref cs 7))
                    (* (- (logand (ash code -8) #xFF) (vector-ref cs 4))
                       (vector-ref cs 3))
                    (- (logand code #xFF) (vector-ref cs 0)))
                 char-index-offset)
              -1)))

    (define (%charset-code-point-to-index charset code)
      (%code-point-to-index (charset-code-linear-p charset)
                            (charset-code-space-mask charset)
                            (charset-code-space charset)
                            (charset-min-code charset)
                            (charset-char-index-offset charset)
                            code))

    (define (%charset-index-to-code-point charset index)
      (let ((cs (charset-code-space charset)))
        (if (charset-code-linear-p charset)
            (+ index (charset-min-code charset))
            (let ((index (+ index (charset-char-index-offset charset))))
              (logior (+ (vector-ref cs 0) (modulo index (vector-ref cs 2)))
                      (ash (+ (vector-ref cs 4)
                              (modulo (quotient index (vector-ref cs 3))
                                      (vector-ref cs 6)))
                           8)
                      (ash (+ (vector-ref cs 8)
                              (modulo (quotient index (vector-ref cs 7))
                                      (vector-ref cs 10)))
                           16)
                      (ash (+ (vector-ref cs 12)
                              (quotient index (vector-ref cs 11)))
                           24))))))

    ;;------------------------------------------------------------------
    ;; The "may contain" bitmap - `struct charset''s `fast_map'
    ;; (`charset.h:269'), 190 bytes
    ;;------------------------------------------------------------------
    ;;
    ;; The first 64 bytes cover characters below 0x10000, one bit per
    ;; 128-character block; the last 126 cover the rest, one bit per
    ;; 4096-character block. The C spells both as macros over the array
    ;; (`charset.h:503', `:508').

    (define (%charset-fast-map-ref c map)
      (if (< c #x10000)
          (not (zero? (logand (vector-ref map (ash c -10))
                              (ash 1 (logand (ash c -7) 7)))))
          (not (zero? (logand (vector-ref map (+ (ash c -15) 62))
                              (ash 1 (logand (ash c -12) 7)))))))

    (define (%charset-fast-map-set! c map)
      (if (< c #x10000)
          (vector-set! map (ash c -10)
                       (logior (vector-ref map (ash c -10))
                               (ash 1 (logand (ash c -7) 7))))
          (vector-set! map (+ (ash c -15) 62)
                       (logior (vector-ref map (+ (ash c -15) 62))
                               (ash 1 (logand (ash c -12) 7))))))

    (define (%charset-method charset)
      ;; `CHARSET_METHOD' (`charset.h'): a `:map' file
      ;; (`CHARSET_METHOD_MAP'), a `:code-offset'
      ;; (`CHARSET_METHOD_OFFSET'), a `:subset', or a `:superset'. The C
      ;; stores the method; the attributes it was defined from are here,
      ;; so it is derived from them.
      ;;--------------------------------------------------------------
      (cond ((charset-subset charset) 'subset)
            ((charset-superset charset) 'superset)
            ((charset-map charset) 'map)
            (else 'offset)))

    (define (%cons-to-unsigned value)
      ;; GNU Emacs's `cons_to_unsigned' (`data.c'): "Convert a cons of
      ;; count1 and count2 to an integer. VALSIZE is the maximum size of
      ;; the integer." A 32-bit code point is written `(HI . LO)' in a
      ;; charset plist, because Lisp fixnums were once too small.
      ;;--------------------------------------------------------------
      (if (pair? value)
          (+ (* (car value) 65536) (cdr value))
          value))

    ;;------------------------------------------------------------------
    ;; Loading a map - `load_charset_map_from_file' (`charset.c:472'),
    ;; `load_charset_map_from_vector' (`:550') and `load_charset' (`:626')
    ;;------------------------------------------------------------------
    ;;
    ;; Each file line is `0xAAAA 0xCCCC' or `0xAAAA-0xBBBB 0xCCCC':
    ;; a code point (or range) and the character it maps to. The parse
    ;; builds entries, `%load-charset-map' turns them into the table the
    ;; `control-flag' asks for:
    ;;
    ;;   0  MIN-CHAR, MAX-CHAR and FAST-MAP (Emacs does this at dump time)
    ;;   1  the decoder: a vector, character index -> character (-1 unset)
    ;;   2  the encoder: a char-table, character -> character index (or,
    ;;      for a compact-codes charset, the code point itself)
    ;;
    ;; Flags 3 and 4 are Emacs's dump-time temporary tables, reached only
    ;; with `inhibit-load-charset-map' set; not carried.

    (define *charset-map-path*
      ;; GNU Emacs's `charset-map-path' (`charset.c:2417'): "List of
      ;; directories to search for charset map files." Emacs's default is
      ;; its installed `etc/charsets'; this tree ships that directory as
      ;; `schemacs/etc/charsets' and finds it on the load path, the way
      ;; `splash-file' finds its text.
      ;;
      ;; A parameter, as Emacs's defvar is a variable a user may set; the
      ;; default is computed once, from the load path as it is when this
      ;; library loads.
      ;;--------------------------------------------------------------
      (make-parameter
       (let loop ((dirs %load-path))
         (cond
          ((null? dirs) '())
          (else
           ;; `canonicalize-path', because a load path entry may be `.` and
           ;; the editor's `--chdir` moves what that means - the maps are
           ;; read long after startup.
           (let ((dir (string-append (guard (e (#t (car dirs)))
                                      (canonicalize-path (car dirs)))
                                     "/schemacs/etc/charsets")))
             (if (and (file-exists? (string-append dir "/JISX0208.map")))
                 (list dir)
                 (loop (cdr dirs)))))))))

    (define (%charset-find-map-file mapfile)
      ;; `openp' over `charset-map-path' with the suffixes `.map' and
      ;; `.txt' (`charset.c:483').
      ;;--------------------------------------------------------------
      (let loop ((dirs (*charset-map-path*)))
        (and (pair? dirs)
             (let search ((suffixes '(".map" ".txt")))
               (cond
                ((null? suffixes) (loop (cdr dirs)))
                (else
                 (let ((path (string-append (car dirs) "/" mapfile (car suffixes))))
                   (if (file-exists? path) path (search (cdr suffixes))))))))))

    (define-record-type <map-reader>
      (make-map-reader port lookahead)
      map-reader?
      (port map-reader-port)
      (lookahead map-reader-lookahead set!map-reader-lookahead))

    (define (%map-reader-getc reader)
      ;; The next character, or #f at end of file.
      ;;--------------------------------------------------------------
      (let ((ch (map-reader-lookahead reader)))
        (if ch
            (begin (set!map-reader-lookahead reader #f) ch)
            (let ((ch (read-char (map-reader-port reader))))
              (if (eof-object? ch) #f ch)))))

    (define (%hex-digit ch)
      (cond ((and (char>=? ch #\0) (char<=? ch #\9))
             (- (char->integer ch) 48))
            ((and (char>=? ch #\a) (char<=? ch #\f))
             (+ 10 (- (char->integer ch) (char->integer #\a))))
            ((and (char>=? ch #\A) (char<=? ch #\F))
             (+ 10 (- (char->integer ch) (char->integer #\A))))
            (else #f)))

    (define (%map-read-hex reader lookahead)
      ;; GNU Emacs's `read_hex' (`charset.c:406'): read "0xHEX", skipping
      ;; `#' comments. Answers (VALUES VALUE TERMINATOR OVERFLOW): the
      ;; terminator is the character after the number, or #f at end of
      ;; file; OVERFLOW is true when the value did not fit.
      ;;--------------------------------------------------------------
      (let loop ((c (if lookahead lookahead (%map-reader-getc reader))))
        (cond
         ((not c) (values 0 #f #f))
         ((char=? c #\#)
          ;; "Skip a comment till the end of the line."
          (let skip ((c (%map-reader-getc reader)))
            (cond ((not c) (loop #f))
                  ((char=? c #\newline) (loop (%map-reader-getc reader)))
                  (else (skip (%map-reader-getc reader))))))
         ((char=? c #\0)
          (let ((c (%map-reader-getc reader)))
            (cond
             ((not c) (values 0 #f #f))
             ((char=? c #\x)
              (let digits ((n 0) (overflow #f))
                (let ((ch (%map-reader-getc reader)))
                  (let ((digit (and ch (%hex-digit ch))))
                    (if digit
                        (digits (+ (* n 16) digit)
                                (or overflow (> n #x0FFFFFFF)))
                        (values n ch overflow))))))
             (else (loop (%map-reader-getc reader))))))
         (else (loop (%map-reader-getc reader))))))

    (define (%load-charset-map-from-file charset mapfile control-flag)
      ;; GNU Emacs's `load_charset_map_from_file' (`charset.c:472').
      ;;--------------------------------------------------------------
      (let ((path (%charset-find-map-file mapfile)))
        (unless path
          (error "Loading charset map: cannot find" mapfile))
        (let* ((port (open-input-file path))
               (reader (make-map-reader port #f))
               (min-code (charset-min-code charset))
               (max-code (charset-max-code charset))
               (entries '())
               (lookahead #f))
          (define (read-entry)
            ;; (VALUES FROM TO C OVERFLOW), or FROM #f at end of file.
            (call-with-values
             (lambda () (%map-read-hex reader lookahead))
             (lambda (from term overflow)
               (set! lookahead term)
               (if (not term)
                   (values #f #f #f overflow)
                   (if (char=? term #\-)
                       (call-with-values
                        (lambda () (%map-read-hex reader #f))
                        (lambda (to term2 overflow2)
                          (set! lookahead term2)
                          (if (not term2)
                              (values #f #f #f overflow2)
                              (call-with-values
                               (lambda () (%map-read-hex reader lookahead))
                               (lambda (c term3 overflow3)
                                 (set! lookahead term3)
                                 (if (not term3)
                                     (values #f #f #f overflow3)
                                     (values from to c
                                             (or overflow overflow2 overflow3))))))))
                       (begin
                         (set! lookahead #f)
                         (call-with-values
                          (lambda () (%map-read-hex reader lookahead))
                          (lambda (c term2 overflow2)
                            (set! lookahead term2)
                            (if (not term2)
                                (values #f #f #f overflow2)
                                (values from from c
                                        (or overflow overflow2)))))))))))
          (let loop ()
            (call-with-values read-entry
              (lambda (from to c overflow)
                (if (not from)
                    (begin
                      (close-port port)
                      (%load-charset-map charset (reverse entries) control-flag))
                    (begin
                      ;; "If the file is invalid, ignore the line."
                      (unless (or overflow
                                  (< from min-code) (> to max-code)
                                  (> from to)
                                  (> c max-char))
                        (set! entries (cons (list from to c) entries)))
                      (loop)))))))))

    (define (%load-charset-map charset entries control-flag)
      ;; GNU Emacs's `load_charset_map' (`charset.c:239'), less the
      ;; dump-time tables (flags 3 and 4).
      ;;--------------------------------------------------------------
      (when (pair? entries)
        (let ((csv (charset-code-space charset)))
          (define (entry-indices entry)
            ;; (VALUES FROM-INDEX TO-INDEX TO-CHAR) - the C's from_index,
            ;; to_index and to_c, before the `< 0' skip.
            (let* ((from (car entry)) (to (cadr entry)) (from-c (caddr entry))
                   (from-index (%charset-code-point-to-index charset from))
                   (to-index (if (= from to)
                                 from-index
                                 (%charset-code-point-to-index charset to))))
              (values from-index to-index
                      (if (= from to)
                          from-c
                          (+ from-c (- to-index from-index))))))
          (cond
           ((= control-flag 1)
            ;; The decoder. A MAP charset's is a vector indexed by
            ;; character index; an OFFSET (unified) one's is the global
            ;; unify char-table, keyed by code-point (`charset.c:350').
            (if (eq? (%charset-method charset) 'map)
                (let* ((size (+ 1 (%charset-code-point-to-index
                                   charset (charset-max-code charset))))
                       (decoder (make-vector (max size 0) -1)))
                  (for-each
                   (lambda (entry)
                     (call-with-values (lambda () (entry-indices entry))
                       (lambda (from-index to-index to-c)
                         (when (and (>= from-index 0) (>= to-index 0))
                           (let loop ((i from-index) (c (caddr entry)))
                             (when (<= i to-index)
                               (vector-set! decoder i c)
                               (loop (+ i 1) (+ c 1))))))))
                   entries)
                  (%set!charset-decoder! charset decoder))
                (begin
                  (unless *char-unify-table*
                    (set! *char-unify-table*
                          (make-char-table 'char-unify-table #f)))
                  (let ((offset (charset-code-offset charset)))
                    (for-each
                     (lambda (entry)
                       (call-with-values (lambda () (entry-indices entry))
                         (lambda (from-index to-index to-c)
                           (when (and (>= from-index 0) (>= to-index 0))
                             (let loop ((i from-index) (c (caddr entry)))
                               (when (<= i to-index)
                                 (char-table-set *char-unify-table*
                                                 (+ offset i) c)
                                 (loop (+ i 1) (+ c 1))))))))
                     entries)))))
           ((= control-flag 2)
            ;; The encoder: character -> character index (or, for a
            ;; compact-codes charset, the code point itself). A MAP
            ;; charset stores it as its encoder; an OFFSET (unified) one
            ;; stores it as its *deunifier* (`charset.c:276').
            (let ((encoder (make-char-table 'charset-encoder #f))
                  (compact (charset-compact-codes-p charset))
                  (map-method (eq? (%charset-method charset) 'map)))
              (for-each
               (lambda (entry)
                 (call-with-values (lambda () (entry-indices entry))
                   (lambda (from-index to-index to-c)
                     (when (and (>= from-index 0) (>= to-index 0))
                       (let loop ((i from-index) (c (caddr entry)))
                         (when (<= i to-index)
                           (when (not (char-table-ref encoder c))
                             (char-table-set encoder c
                                             (if (and map-method compact)
                                                 (%charset-index-to-code-point
                                                  charset i)
                                                 i)))
                           (loop (+ i 1) (+ c 1))))))))
               entries)
              (if map-method
                  (%set!charset-encoder! charset encoder)
                  (%set!charset-deunifier! charset encoder))))
           (else
            ;; Control flag 0: MIN-CHAR, MAX-CHAR and FAST-MAP.
            (let* ((first (caddr (car entries)))
                   (lo first)
                   (hi first)
                   (nonascii-min-char max-char)
                   (ascii-compatible (charset-ascii-compatible-p charset))
                   (fast-map (make-vector 190 0)))
              (for-each
               (lambda (entry)
                 (call-with-values (lambda () (entry-indices entry))
                   (lambda (from-index to-index to-c)
                     (when (and (>= from-index 0) (>= to-index 0))
                       (let ((from-c (caddr entry)))
                         ;; "if (to_c > max_char) max_char = to_c; else if
                         ;; (from_c < min_char) min_char = from_c;" - the
                         ;; else matters and is copied.
                         (if (> to-c hi)
                             (set! hi to-c)
                             (if (< from-c lo)
                                 (set! lo from-c)))
                         (when ascii-compatible
                           (if (not (< from-c #x80))
                               (if (< from-c nonascii-min-char)
                                   (set! nonascii-min-char from-c))
                               (if (not (< to-c #x80))
                                   (set! nonascii-min-char #x80))))
                         (let loop ((c from-c))
                           (when (<= c to-c)
                             (%charset-fast-map-set! c fast-map)
                             (loop (+ c 1)))))))))
               entries)
              (%set!charset-min-char! charset (if ascii-compatible
                                                 nonascii-min-char
                                                 lo))
              (%set!charset-max-char! charset hi)
              (%set!charset-fast-map! charset fast-map)))))))

    (define (%load-charset charset control-flag)
      ;; GNU Emacs's `load_charset' (`charset.c:626'): load CHARSET's map
      ;; for CONTROL-FLAG. A MAP charset loads its `:map'; an OFFSET one
      ;; loads its `:unify-map', and must have been unified first (the C
      ;; `emacs_abort's there; this errors).
      ;;--------------------------------------------------------------
      (let ((map (if (eq? (%charset-method charset) 'map)
                     (charset-map charset)
                     (begin
                       (unless (charset-unified? charset)
                         (error "Cannot load a map for an un-unified charset"
                                (charset-name charset)))
                       (charset-unify-map charset)))))
        (unless (string? map)
          (error "No map file for charset" (charset-name charset)))
        (%load-charset-map-from-file charset map control-flag)))

    ;;------------------------------------------------------------------
    ;; decode-char / encode-char - `charset.c:1828' and `:1848'
    ;;------------------------------------------------------------------

    (define (charset-by-name name)
      ;; The registry's name lookup - Emacs's `Vcharset_hash_table' keyed
      ;; by the charset symbol. The table is small, so the walk is over
      ;; it rather than a second registry that could go stale when
      ;; `*charset-table*' is parameterized by a test.
      ;;--------------------------------------------------------------
      (let ((table (*charset-table*)))
        (let loop ((i 0))
          (cond ((>= i (vector-length table)) #f)
                (else
                 (let ((charset (vector-ref table i)))
                   (if (and charset (eq? (charset-name charset) name))
                       charset
                       (loop (+ i 1)))))))))

    (define (%charset-ensure-defined charset)
      ;; A MAP charset's MIN-CHAR, MAX-CHAR and FAST-MAP come from its
      ;; map; Emacs loads them at dump time (`load_charset (charset, 0)'),
      ;; so here they are loaded on first use, which is what #f in
      ;; MIN-CHAR means.
      ;;--------------------------------------------------------------
      (when (and (eq? (%charset-method charset) 'map)
                 (not (charset-min-char charset)))
        (%load-charset charset 0))
      charset)

    (define (%charset-decode-char charset code)
      ;; GNU Emacs's `decode_char' (`charset.c:1650'): the four methods,
      ;; in the C's order - behind the `DECODE_CHAR' macro's ASCII
      ;; shortcut (`charset.h:427'): "ASCII_CHAR_P (code) &&
      ;; ascii_compatible_p" answers the code itself, before any range
      ;; test or map lookup.
      ;;--------------------------------------------------------------
      (if (and (< code #x80) (charset-ascii-compatible-p charset))
          code
          (if (or (< code (charset-min-code charset))
                  (> code (charset-max-code charset)))
              -1
          (cond
           ((eq? (%charset-method charset) 'subset)
            (let* ((info (charset-subset charset))
                   (parent (charset-from-id (vector-ref info 0)))
                   (this-code (- code (vector-ref info 3))))
              (if (or (< this-code (vector-ref info 1))
                      (> this-code (vector-ref info 2)))
                  -1
                  (%charset-decode-char parent this-code))))
           ((eq? (%charset-method charset) 'superset)
            (let loop ((parents (charset-superset charset)))
              (if (null? parents)
                  -1
                  (let ((c (%charset-decode-char
                            (charset-from-id (car (car parents)))
                            (- code (cdr (car parents))))))
                    (if (>= c 0) c (loop (cdr parents)))))))
           (else
            ;; "char_index = CODE_POINT_TO_INDEX (charset, code); if
            ;; (char_index < 0) return -1;" - the C checks this for
            ;; *both* remaining methods (`charset.c:1687'), and a
            ;; non-linear charset's mask can reject an in-range code
            ;; point (a byte outside its dimensions).
            (let ((index (%charset-code-point-to-index charset code)))
              (if (< index 0)
                  -1
                  (if (eq? (%charset-method charset) 'map)
                      (let ((decoder (or (charset-decoder charset)
                                         (begin (%load-charset charset 1)
                                                (charset-decoder charset)))))
                        (vector-ref decoder index))
                      (let ((c (+ index (charset-code-offset charset))))
                        (if (and (charset-unified? charset)
                                 (> c #x10FFFF)          ; MAX_UNICODE_CHAR
                                 (<= c *max-5-byte-char*))
                            (%maybe-unify-char
                             c (char-table-ref *char-unify-table* c))
                            c))))))))))

    (define (%charset-encode-char charset c)
      ;; GNU Emacs's `encode_char' (`charset.c:1717'): the four methods in
      ;; the C's order, with its fast-map test after the inherited ones.
      ;; The unified-charset (deunifier) arm is not carried: nothing here
      ;; defines a `:unify-map'.
      ;;--------------------------------------------------------------
      (%charset-ensure-defined charset)
      ;; `ENCODE_CHAR''s ASCII shortcut (`charset.h:443'): an ASCII
      ;; character in an ASCII-compatible charset encodes to itself,
      ;; whatever the map says.
      (if (and (< c #x80) (charset-ascii-compatible-p charset))
          c
          (let ((invalid (charset-invalid-code charset)))
        ;; A unified charset's character is first turned back into its
        ;; internal code through the deunifier (`charset.c:1727-1750').
        (when (charset-unified? charset)
          (let ((deunifier (or (charset-deunifier charset)
                               (begin (%load-charset charset 2)
                                      (charset-deunifier charset)))))
            (let ((index (and deunifier (char-table-ref deunifier c))))
              (when (integer? index)
                (set! c (+ (charset-code-offset charset) index))))))
        (cond
         ((eq? (%charset-method charset) 'subset)
          (let* ((info (charset-subset charset))
                 (parent (charset-from-id (vector-ref info 0)))
                 (code (%charset-encode-char parent c)))
            (if (or (= code (charset-invalid-code parent))
                    (< code (vector-ref info 1))
                    (> code (vector-ref info 2)))
                invalid
                (+ code (vector-ref info 3)))))
         ((eq? (%charset-method charset) 'superset)
          (let loop ((parents (charset-superset charset)))
            (if (null? parents)
                invalid
                (let ((code (%charset-encode-char
                             (charset-from-id (car (car parents))) c)))
                  (if (= code (charset-invalid-code
                               (charset-from-id (car (car parents)))))
                      (loop (cdr parents))
                      (+ code (cdr (car parents))))))))
         ((or (not (%charset-fast-map-ref c (charset-fast-map charset)))
              (< c (charset-min-char charset))
              (> c (charset-max-char charset)))
          invalid)
         ((eq? (%charset-method charset) 'map)
          (let ((encoder (or (charset-encoder charset)
                             (begin (%load-charset charset 2)
                                    (charset-encoder charset)))))
            (let ((value (char-table-ref encoder c)))
              (if (not value)
                  invalid
                  (if (charset-compact-codes-p charset)
                      value
                      (%charset-index-to-code-point charset value))))))
         (else
          (%charset-index-to-code-point
           charset (- c (charset-code-offset charset))))))))

    (define (decode-char charset code)
      ;; GNU Emacs's `decode-char' (`charset.c:1828'): "Decode the pair of
      ;; CHARSET and CODE-POINT into a character. Return nil if
      ;; CODE-POINT is not valid in CHARSET."
      ;;
      ;; The answer is a *code point* - what the C's charset layer deals
      ;; in - so it can be above Guile's `#x10FFFF` for a byte charset.
      ;; The obsolescent cons CODE-POINT is not carried.
      ;;--------------------------------------------------------------
      (let ((charset (if (charset? charset) charset (charset-by-name charset))))
        (unless charset
          (error "Invalid charset" charset))
        (let ((c (%charset-decode-char charset code)))
          (if (>= c 0) c #f))))

    (define (encode-char ch charset)
      ;; GNU Emacs's `encode-char' (`charset.c:1848'): "Encode the
      ;; character CH into a code-point of CHARSET. Return the encoded
      ;; code-point as an integer, or nil if CHARSET doesn't support CH."
      ;;--------------------------------------------------------------
      (let ((charset (if (charset? charset) charset (charset-by-name charset))))
        (unless charset
          (error "Invalid charset" charset))
        (let ((code (%charset-encode-char charset
                                          (if (char? ch) (char->integer ch) ch))))
          (if (= code (charset-invalid-code charset)) #f code))))

    ;;------------------------------------------------------------------
    ;; Unification - `unify_charset' (`charset.c:1318')
    ;;------------------------------------------------------------------
    ;;
    ;; Emacs's `(decode-char 'japanese-jisx0208 #x2121)' answers 12288
    ;; (U+3000), not the charset's internal code 0x140000, because
    ;; `mule-conf.el' unifies those charsets: it calls `unify-charset'
    ;; for each, which loads the charset's `:unify-map' file into a
    ;; global char-table and marks the charset unified. `decode_char' and
    ;; `encode_char' consult that table; this is that mechanism, and the
    ;; calls at the bottom of this file are mule-conf.el's list.

    (define *char-unify-table* #f)
    ;; ^ `Vchar_unify_table' (`charset.c:93'): "char-table for character
    ;; unification". A plain variable, made by the first
    ;; `unify-charset', as the C declares it.

    (define (%maybe-unify-char c val)
      ;; GNU Emacs's `maybe_unify_char' (`charset.c:1565'): "Return a
      ;; unified character code for C (>= 0x110000). VAL is a value of
      ;; Vchar_unify_table for C". A fixnum is the answer; nil means
      ;; "not unified"; anything else is a charset whose map is loaded
      ;; and asked again.
      ;;--------------------------------------------------------------
      (cond
       ((integer? val) val)
       ((not val) c)
       (else
        (let ((charset (charset-by-name val)))
          (if (not charset)
              c
              (begin
                (%load-charset charset 1)
                (let ((v (char-table-ref *char-unify-table* c)))
                  (if (integer? v) v c))))))))

    (define (unify-charset charset . rest)
      ;; GNU Emacs's `unify-charset' (`charset.c:1318'): "Unify
      ;; characters of CHARSET with Unicode."
      ;;
      ;; The early return is the C's: a already-unified charset with a
      ;; deunifier is left alone; a charset that is not unified cannot be
      ;; de-unified.
      ;;--------------------------------------------------------------
      (let* ((cs (if (charset? charset) charset (charset-by-name charset)))
             (unify-map (and (pair? rest) (car rest)))
             (deunify (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (unless cs (error "Invalid charset" charset))
        (unless (if deunify
                    (not (charset-unified? cs))
                    (and (charset-unified? cs) (charset-deunifier cs)))
          (%set!charset-unified?! cs #f)
          (if deunify
              (when (char-table? *char-unify-table*)
                (let* ((min-code (charset-min-code cs))
                       (max-code (charset-max-code cs))
                       (lo (%charset-decode-char cs min-code))
                       (hi (%charset-decode-char cs max-code)))
                  (char-table-set-range *char-unify-table* lo hi #f)))
              (begin
                (unless (and (eq? (%charset-method cs) 'offset)
                             (>= (charset-code-offset cs) #x110000))
                  (error "Can't unify charset:" (charset-name cs)))
                (when unify-map (%set!charset-unify-map! cs unify-map))
                (unless *char-unify-table*
                  (set! *char-unify-table*
                        (make-char-table 'char-unify-table #f)))
                (char-table-set-range *char-unify-table*
                                      (charset-min-char cs)
                                      (charset-max-char cs)
                                      (charset-name cs))
                (%set!charset-unified?! cs #t))))
        #f))

    ;;------------------------------------------------------------------
    ;; Emacs 31.1's charset set
    ;;------------------------------------------------------------------
    ;;
    ;; From a running Emacs's registry, in the order this file has always
    ;; carried them. Each entry is the code space, the ISO final char (-1
    ;; for a charset that has none) and every attribute the C's
    ;; `define_charset_internal' takes that the charset actually has:
    ;; `:dimension', `:code-offset', `:map', `:min-code'/`:max-code'
    ;; (a 32-bit value as a `(HI . LO)' cons, as `cons_to_unsigned'
    ;; reads it), `:subset', `:superset' and `:ascii-compatible-p'.
    ;;
    ;; **The first transcription carried only the code space, the ISO
    ;; final char and (for some) the offset and map** - enough for the
    ;; designation tables and not enough to convert a character. The
    ;; attributes came back from the same script when the map tables
    ;; needed them; a charset defined without its `:superset' (gb18030)
    ;; or its `:subset' (the latin-iso8859-* family) gets the wrong
    ;; method and cannot decode at all.
    ;;
    ;; `iso-8859-1' (id 1) and `latin-iso8859-1' (id 5) are both here and
    ;; are different charsets: the first is the whole 8-bit set, with no
    ;; ISO final char, and the second is the right-hand part of it, which
    ;; is what `ESC ( A' designates.

    (define-charset 'ascii #(0 127 0 0 0 0 0 0) 66 #:dimension 1 #:code-offset 0 #:ascii-compatible-p #t)
    (define-charset 'iso-8859-1 #(0 255 0 0 0 0 0 0) -1 #:dimension 1 #:code-offset 0 #:ascii-compatible-p #t)
    (define-charset 'unicode #(0 255 0 255 0 16 0 0) -1 #:dimension 3 #:code-offset 0 #:ascii-compatible-p #t)
    (define-charset 'emacs #(0 255 0 255 0 63 0 0) -1 #:dimension 3 #:code-offset 0 #:max-code 4194175 #:ascii-compatible-p #t)
    (define-charset 'eight-bit #(128 255 0 0 0 0 0 0) -1 #:dimension 1 #:code-offset 4194176)
    (define-charset 'latin-iso8859-1 #(32 127) 65 #:dimension 1 #:code-offset 160)
    (define-charset 'control-1 #(128 159) -1 #:dimension 1 #:code-offset 128)
    (define-charset 'eight-bit-control #(128 159) -1 #:dimension 1 #:code-offset 4194176)
    (define-charset 'eight-bit-graphic #(160 255) -1 #:dimension 1 #:code-offset 4194208)
    (define-charset 'iso-8859-2 #(0 255) -1 #:dimension 1 #:map "8859-2" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-2 #(32 127) 66 #:dimension 1 #:subset '(iso-8859-2 160 255 -128))
    (define-charset 'iso-8859-3 #(0 255) -1 #:dimension 1 #:map "8859-3" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-3 #(32 127) 67 #:dimension 1 #:subset '(iso-8859-3 160 255 -128))
    (define-charset 'iso-8859-4 #(0 255) -1 #:dimension 1 #:map "8859-4" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-4 #(32 127) 68 #:dimension 1 #:subset '(iso-8859-4 160 255 -128))
    (define-charset 'iso-8859-5 #(0 255) -1 #:dimension 1 #:map "8859-5" #:ascii-compatible-p #t)
    (define-charset 'cyrillic-iso8859-5 #(32 127) 76 #:dimension 1 #:subset '(iso-8859-5 160 255 -128))
    (define-charset 'iso-8859-6 #(0 255) -1 #:dimension 1 #:map "8859-6" #:ascii-compatible-p #t)
    (define-charset 'arabic-iso8859-6 #(32 127) 71 #:dimension 1 #:subset '(iso-8859-6 160 255 -128))
    (define-charset 'iso-8859-7 #(0 255) -1 #:dimension 1 #:map "8859-7" #:ascii-compatible-p #t)
    (define-charset 'greek-iso8859-7 #(32 127) 70 #:dimension 1 #:subset '(iso-8859-7 160 255 -128))
    (define-charset 'iso-8859-8 #(0 255) -1 #:dimension 1 #:map "8859-8" #:ascii-compatible-p #t)
    (define-charset 'hebrew-iso8859-8 #(32 127) 72 #:dimension 1 #:subset '(iso-8859-8 160 255 -128))
    (define-charset 'iso-8859-9 #(0 255) -1 #:dimension 1 #:map "8859-9" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-9 #(32 127) 77 #:dimension 1 #:subset '(iso-8859-9 160 255 -128))
    (define-charset 'iso-8859-10 #(0 255) -1 #:dimension 1 #:map "8859-10" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-10 #(32 127) 86 #:dimension 1 #:subset '(iso-8859-10 160 255 -128))
    (define-charset 'iso-8859-11 #(0 255) -1 #:dimension 1 #:map "8859-11" #:ascii-compatible-p #t)
    (define-charset 'thai-iso8859-11 #(32 127) 84 #:dimension 1 #:subset '(iso-8859-11 160 255 -128))
    (define-charset 'iso-8859-13 #(0 255) -1 #:dimension 1 #:map "8859-13" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-13 #(32 127) 89 #:dimension 1 #:subset '(iso-8859-13 160 255 -128))
    (define-charset 'iso-8859-14 #(0 255) -1 #:dimension 1 #:map "8859-14" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-14 #(32 127) 95 #:dimension 1 #:subset '(iso-8859-14 160 255 -128))
    (define-charset 'iso-8859-15 #(0 255) -1 #:dimension 1 #:map "8859-15" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-15 #(32 127) 98 #:dimension 1 #:subset '(iso-8859-15 160 255 -128))
    (define-charset 'iso-8859-16 #(0 255) -1 #:dimension 1 #:map "8859-16" #:ascii-compatible-p #t)
    (define-charset 'latin-iso8859-16 #(32 127) 102 #:dimension 1 #:subset '(iso-8859-16 160 255 -128))
    (define-charset 'thai-tis620 #(32 127) 84 #:dimension 1 #:code-offset 3584)
    (define-charset 'tis620-2533 #(0 255) -1 #:dimension 1 #:superset '(ascii (thai-tis620 . 128)) #:ascii-compatible-p #t)
    (define-charset 'jisx0201 #(0 223) -1 #:dimension 1 #:map "JISX0201")
    (define-charset 'latin-jisx0201 #(33 126) 74 #:dimension 1 #:subset '(jisx0201 33 126 0))
    (define-charset 'katakana-jisx0201 #(33 126) 73 #:dimension 1 #:subset '(jisx0201 161 254 -128))
    (define-charset 'chinese-gb2312 #(33 126 33 126) 65 #:dimension 2 #:code-offset 1114112 #:unify-map "GB2312")
    (define-charset 'chinese-gbk #(64 254 129 254) -1 #:dimension 2 #:code-offset 1441792 #:unify-map "GBK")
    (define-charset 'chinese-cns11643-1 #(33 126 33 126) 71 #:dimension 2 #:code-offset 1130496 #:unify-map "CNS-1")
    (define-charset 'chinese-cns11643-2 #(33 126 33 126) 72 #:dimension 2 #:code-offset 1146880 #:unify-map "CNS-2")
    (define-charset 'chinese-cns11643-3 #(33 126 33 126) 73 #:dimension 2 #:code-offset 1163264 #:unify-map "CNS-3")
    (define-charset 'chinese-cns11643-4 #(33 126 33 126) 74 #:dimension 2 #:code-offset 1179648 #:unify-map "CNS-4")
    (define-charset 'chinese-cns11643-5 #(33 126 33 126) 75 #:dimension 2 #:code-offset 1196032 #:unify-map "CNS-5")
    (define-charset 'chinese-cns11643-6 #(33 126 33 126) 76 #:dimension 2 #:code-offset 1212416 #:unify-map "CNS-6")
    (define-charset 'chinese-cns11643-7 #(33 126 33 126) 77 #:dimension 2 #:code-offset 1228800 #:unify-map "CNS-7")
    (define-charset 'big5 #(64 254 161 254) -1 #:dimension 2 #:code-offset 1245184 #:unify-map "BIG5")
    (define-charset 'chinese-big5-1 #(33 126 33 126) 48 #:dimension 2 #:code-offset 1265664 #:unify-map "BIG5-1")
    (define-charset 'chinese-big5-2 #(33 126 33 126) 49 #:dimension 2 #:code-offset 1275904 #:unify-map "BIG5-2")
    (define-charset 'japanese-jisx0208 #(33 126 33 126) 66 #:dimension 2 #:code-offset 1310720 #:unify-map "JISX0208")
    (define-charset 'japanese-jisx0208-1978 #(33 126 33 126) 64 #:dimension 2 #:code-offset 1327104 #:unify-map "JISC6226")
    (define-charset 'japanese-jisx0212 #(33 126 33 126) 68 #:dimension 2 #:code-offset 1343488 #:unify-map "JISX0212")
    (define-charset 'japanese-jisx0213-1 #(33 126 33 126) 79 #:dimension 2 #:code-offset 1359872 #:unify-map "JISX2131")
    (define-charset 'japanese-jisx0213-2 #(33 126 33 126) 80 #:dimension 2 #:code-offset 1376256 #:unify-map "JISX2132")
    (define-charset 'japanese-jisx0213-a #(33 126 33 126) -1 #:dimension 2 #:map "JISX213A")
    (define-charset 'japanese-jisx0213.2004-1 #(33 126 33 126) 81 #:dimension 2 #:superset '(japanese-jisx0213-a japanese-jisx0213-1))
    (define-charset 'katakana-sjis #(161 223) -1 #:dimension 1 #:subset '(jisx0201 161 223 0))
    (define-charset 'cp932-2-byte #(64 252 129 252) -1 #:dimension 2 #:map "CP932-2BYTE")
    (define-charset 'cp932 #(0 255 0 254) -1 #:dimension 2 #:superset '(ascii katakana-sjis cp932-2-byte))
    (define-charset 'korean-ksc5601 #(33 126 33 126) 67 #:dimension 2 #:code-offset 2596756 #:unify-map "KSC5601")
    (define-charset 'big5-hkscs #(64 254 161 254) -1 #:dimension 2 #:code-offset 2605592 #:unify-map "BIG5-HKSCS")
    (define-charset 'cp949-2-byte #(65 254 129 253) -1 #:dimension 2 #:map "CP949-2BYTE")
    (define-charset 'cp949 #(0 254 0 253) -1 #:dimension 2 #:superset '(ascii cp949-2-byte))
    (define-charset 'chinese-sisheng #(33 126) 48 #:dimension 1 #:code-offset 2097152 #:unify-map "MULE-sisheng")
    (define-charset 'ipa #(32 127) 48 #:dimension 1 #:code-offset 2097280 #:unify-map "MULE-ipa")
    (define-charset 'viscii #(0 255) -1 #:dimension 1 #:map "VISCII")
    (define-charset 'vietnamese-viscii-lower #(32 127) 49 #:dimension 1 #:code-offset 2097664 #:unify-map "MULE-lviscii")
    (define-charset 'vietnamese-viscii-upper #(32 127) 50 #:dimension 1 #:code-offset 2097792 #:unify-map "MULE-uviscii")
    (define-charset 'vscii #(0 255) -1 #:dimension 1 #:map "VSCII")
    (define-charset 'vscii-2 #(0 255) -1 #:dimension 1 #:map "VSCII-2")
    (define-charset 'koi8-r #(0 255) -1 #:dimension 1 #:map "KOI8-R" #:ascii-compatible-p #t)
    (define-charset 'alternativnyj #(0 255) -1 #:dimension 1 #:map "ALTERNATIVNYJ" #:ascii-compatible-p #t)
    (define-charset 'cp866 #(0 255) -1 #:dimension 1 #:map "IBM866" #:ascii-compatible-p #t)
    (define-charset 'koi8-u #(0 255) -1 #:dimension 1 #:map "KOI8-U" #:ascii-compatible-p #t)
    (define-charset 'koi8-t #(0 255) -1 #:dimension 1 #:map "KOI8-T" #:ascii-compatible-p #t)
    (define-charset 'georgian-ps #(0 255) -1 #:dimension 1 #:map "KA-PS" #:ascii-compatible-p #t)
    (define-charset 'georgian-academy #(0 255) -1 #:dimension 1 #:map "KA-ACADEMY" #:ascii-compatible-p #t)
    (define-charset 'windows-1250 #(0 255) -1 #:dimension 1 #:map "CP1250" #:ascii-compatible-p #t)
    (define-charset 'windows-1251 #(0 255) -1 #:dimension 1 #:map "CP1251" #:ascii-compatible-p #t)
    (define-charset 'windows-1252 #(0 255) -1 #:dimension 1 #:map "CP1252" #:ascii-compatible-p #t)
    (define-charset 'windows-1253 #(0 255) -1 #:dimension 1 #:map "CP1253" #:ascii-compatible-p #t)
    (define-charset 'windows-1254 #(0 255) -1 #:dimension 1 #:map "CP1254" #:ascii-compatible-p #t)
    (define-charset 'windows-1255 #(0 255) -1 #:dimension 1 #:map "CP1255" #:ascii-compatible-p #t)
    (define-charset 'windows-1256 #(0 255) -1 #:dimension 1 #:map "CP1256" #:ascii-compatible-p #t)
    (define-charset 'windows-1257 #(0 255) -1 #:dimension 1 #:map "CP1257" #:ascii-compatible-p #t)
    (define-charset 'windows-1258 #(0 255) -1 #:dimension 1 #:map "CP1258" #:ascii-compatible-p #t)
    (define-charset 'next #(0 255) -1 #:dimension 1 #:map "NEXTSTEP" #:ascii-compatible-p #t)
    (define-charset 'cp1125 #(0 255) -1 #:dimension 1 #:map "CP1125" #:ascii-compatible-p #t)
    (define-charset 'cp437 #(0 255) -1 #:dimension 1 #:map "IBM437" #:ascii-compatible-p #t)
    (define-charset 'cp720 #(0 255) -1 #:dimension 1 #:map "CP720" #:ascii-compatible-p #t)
    (define-charset 'cp737 #(0 255) -1 #:dimension 1 #:map "CP737" #:ascii-compatible-p #t)
    (define-charset 'cp775 #(0 255) -1 #:dimension 1 #:map "CP775" #:ascii-compatible-p #t)
    (define-charset 'cp851 #(0 255) -1 #:dimension 1 #:map "IBM851" #:ascii-compatible-p #t)
    (define-charset 'cp852 #(0 255) -1 #:dimension 1 #:map "IBM852" #:ascii-compatible-p #t)
    (define-charset 'cp855 #(0 255) -1 #:dimension 1 #:map "IBM855" #:ascii-compatible-p #t)
    (define-charset 'cp857 #(0 255) -1 #:dimension 1 #:map "IBM857" #:ascii-compatible-p #t)
    (define-charset 'cp858 #(0 255) -1 #:dimension 1 #:map "CP858" #:ascii-compatible-p #t)
    (define-charset 'cp860 #(0 255) -1 #:dimension 1 #:map "IBM860" #:ascii-compatible-p #t)
    (define-charset 'cp861 #(0 255) -1 #:dimension 1 #:map "IBM861" #:ascii-compatible-p #t)
    (define-charset 'cp862 #(0 255) -1 #:dimension 1 #:map "IBM862" #:ascii-compatible-p #t)
    (define-charset 'cp863 #(0 255) -1 #:dimension 1 #:map "IBM863" #:ascii-compatible-p #t)
    (define-charset 'cp864 #(0 255) -1 #:dimension 1 #:map "IBM864" #:ascii-compatible-p #t)
    (define-charset 'cp865 #(0 255) -1 #:dimension 1 #:map "IBM865" #:ascii-compatible-p #t)
    (define-charset 'cp869 #(0 255) -1 #:dimension 1 #:map "IBM869" #:ascii-compatible-p #t)
    (define-charset 'cp874 #(0 255) -1 #:dimension 1 #:map "IBM874" #:ascii-compatible-p #t)
    (define-charset 'arabic-digit #(34 42) 50 #:dimension 1 #:code-offset 1536)
    (define-charset 'arabic-1-column #(33 126) 51 #:dimension 1 #:code-offset 2097408)
    (define-charset 'arabic-2-column #(33 126) 52 #:dimension 1 #:code-offset 2097536)
    (define-charset 'lao #(33 126) 49 #:dimension 1 #:code-offset 3713)
    (define-charset 'mule-lao #(0 255) -1 #:dimension 1 #:superset '(ascii eight-bit-control (lao . 128)))
    (define-charset 'indian-is13194 #(33 126) 53 #:dimension 1 #:code-offset 1572864 #:unify-map "MULE-is13194")
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
    (define-charset 'tibetan #(33 126 33 37) 55 #:dimension 2 #:code-offset 1638400 #:unify-map "MULE-tibetan")
    (define-charset 'tibetan-1-column #(33 126 33 37) 56 #:dimension 2 #:code-offset 1638400)
    (define-charset 'mule-unicode-2500-33ff #(32 127 32 71) 50 #:dimension 2 #:code-offset 9472)
    (define-charset 'mule-unicode-e000-ffff #(32 127 32 117) 51 #:dimension 2 #:code-offset 57344 #:max-code 30015)
    (define-charset 'mule-unicode-0100-24ff #(32 127 32 127) 49 #:dimension 2 #:code-offset 256)
    (define-charset 'unicode-bmp #(0 255 0 255) -1 #:dimension 2 #:code-offset 0)
    (define-charset 'unicode-smp #(0 255 0 255) -1 #:dimension 2 #:code-offset 65536)
    (define-charset 'unicode-sip #(0 255 0 255) -1 #:dimension 2 #:code-offset 131072)
    (define-charset 'unicode-ssp #(0 255 0 255) -1 #:dimension 2 #:code-offset 917504)
    (define-charset 'ethiopic #(33 126 33 126) 51 #:dimension 2 #:code-offset 1703936 #:unify-map "MULE-ethiopic")
    (define-charset 'mac-roman #(0 255) -1 #:dimension 1 #:map "MACINTOSH" #:ascii-compatible-p #t)
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
    (define-charset 'hp-roman8 #(0 255) -1 #:dimension 1 #:map "HP-ROMAN8" #:ascii-compatible-p #t)
    (define-charset 'adobe-standard-encoding #(32 255) -1 #:dimension 1 #:map "stdenc")
    (define-charset 'symbol #(32 255) -1 #:dimension 1 #:map "symbol")
    (define-charset 'ibm850 #(0 255) -1 #:dimension 1 #:map "IBM850" #:ascii-compatible-p #t)
    (define-charset 'mik #(0 255) -1 #:dimension 1 #:map "MIK" #:ascii-compatible-p #t)
    (define-charset 'ptcp154 #(0 255) -1 #:dimension 1 #:map "PTCP154" #:ascii-compatible-p #t)
    (define-charset 'gb18030-2-byte #(64 254 129 254) -1 #:dimension 2 #:map "GB180302")
    (define-charset 'gb18030-4-byte-bmp #(48 57 129 254 48 57 129 132) -1 #:dimension 4 #:map "GB180304")
    (define-charset 'gb18030-4-byte-smp #(48 57 129 254 48 57 144 227) -1 #:dimension 4 #:code-offset 65536 #:min-code (cons 36912 33072) #:max-code (cons 58162 39477))
    (define-charset 'gb18030-4-byte-ext-1 #(48 57 129 254 48 57 132 143) -1 #:dimension 4 #:code-offset 2097152 #:min-code (cons 33841 42288) #:max-code (cons 36665 65081))
    (define-charset 'gb18030-4-byte-ext-2 #(48 57 129 254 48 57 227 254) -1 #:dimension 4 #:code-offset 2246732 #:min-code (cons 58162 39478) #:max-code (cons 65081 65081))
    (define-charset 'gb18030 #(0 255 0 254 0 254 0 254) -1 #:dimension 4 #:min-code 0 #:max-code (cons 65081 65081) #:superset '(ascii gb18030-2-byte gb18030-4-byte-bmp gb18030-4-byte-smp gb18030-4-byte-ext-1 gb18030-4-byte-ext-2))
    (define-charset 'chinese-cns11643-15 #(33 126 33 126) -1 #:dimension 2 #:code-offset 2623546 #:unify-map "CNS-F")
    (unify-charset 'chinese-gb2312)
    (unify-charset 'chinese-gbk)
    (unify-charset 'chinese-cns11643-1)
    (unify-charset 'chinese-cns11643-2)
    (unify-charset 'chinese-cns11643-3)
    (unify-charset 'chinese-cns11643-4)
    (unify-charset 'chinese-cns11643-5)
    (unify-charset 'chinese-cns11643-6)
    (unify-charset 'chinese-cns11643-7)
    (unify-charset 'big5)
    (unify-charset 'chinese-big5-1)
    (unify-charset 'chinese-big5-2)
    (unify-charset 'japanese-jisx0208)
    (unify-charset 'japanese-jisx0208-1978)
    (unify-charset 'japanese-jisx0212)
    (unify-charset 'japanese-jisx0213-1)
    (unify-charset 'japanese-jisx0213-2)
    (unify-charset 'korean-ksc5601)
    (unify-charset 'big5-hkscs)
    (unify-charset 'chinese-sisheng)
    (unify-charset 'ipa)
    (unify-charset 'vietnamese-viscii-lower)
    (unify-charset 'vietnamese-viscii-upper)
    (unify-charset 'indian-is13194)
    (unify-charset 'tibetan)
    (unify-charset 'ethiopic)
    (unify-charset 'chinese-cns11643-15)
))
