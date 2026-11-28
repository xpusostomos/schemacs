(define-library (schemacs fns)
  ;; This library mirrors GNU Emacs's `src/fns.c', and holds one piece
  ;; of it so far: the string comparisons `compare-strings',
  ;; `string-lessp' and `string-collate-lessp'.
  ;;
  ;; They are together here because they are the three that `ls-lisp'
  ;; asked for and the three `(schemacs minibuf)' had been
  ;; carrying with a note saying exactly this - "when `fns.sld' exists
  ;; it goes there, as `get' and `put' will". `compare-strings' is
  ;; still re-exported from `minibuf.sld', so its callers do not move.
  ;;
  ;; `string-collate-lessp' is the locale's ordering, and it is what
  ;; makes a directory listing sort the way GNU `ls' and GNU Emacs's own
  ;; `ls-lisp' sort: by glibc's collation rules, where punctuation and
  ;; case weigh less than letters, rather than by character code. Guile
  ;; wraps the same `strcoll' in `(ice-9 i18n)', so what is here is that
  ;; library's `string-locale<?' under Emacs's name and argument list.
  ;;
  ;; Emacs's `str_collate' (sysdep.c:4668) builds a wide-character
  ;; string and calls `wcscoll'; `(ice-9 i18n)' calls `strcoll' on the
  ;; locale-encoded bytes. For a UTF-8 locale the two use the same
  ;; glibc tables and answer the same, which is how this is checked: the
  ;; docstring's own example, `(sort '("11" "12" "1 1" "1 2" "1.1"
  ;; "1.2") #'string-collate-lessp)'.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * `string-collate-equalp', its twin over `str_collate'.
  ;;   * the rest of fns.c - `concat', `mapconcat', the hash tables,
  ;;     `proper-list-p', `string-distance'. Several of them already
  ;;     exist elsewhere in this tree and move here when fns.c is worked
  ;;     through; the two `get'/`put' the minibuf's note named do not
  ;;     exist yet.

  (import
    ;; `define-custom' - the C variables `cus-start.el' makes
    ;; customizable (see the declaration below).
    (only (schemacs custom) define-custom)
    (scheme base)
    ;; `list-copy` is `(srfi srfi-1)`'s, and `copy-sequence`'s list arm is
    ;; it - as Emacs's list arm is `Fcopy_sequence`'s cons walk.
    (only (srfi srfi-1) list-copy)
    (scheme char)
    ;; the same `strcoll' glibc gives Emacs's `str_collate'.
    ;; The three procedures are `(ice-9 i18n)'s; the two LC_ constants
    ;; are `(guile)'s - `(ice-9 i18n)' does not re-export them.
    (only (ice-9 i18n) string-locale-ci<? string-locale<? make-locale)
    ;; the whole of `copy-sequence''s string arm - the C calls
    ;; `copy_intervals' and `set_string_intervals' there
    (only (schemacs intervals)
          compare-string-intervals copy-intervals set-interval-object!
          set!string-intervals string-intervals)
    ;; `line-number-at-pos' is a DEFUN of this file and reads the buffer
    ;; through `point' (`PT') and the bounds, and its POSITION argument
    ;; may be a marker - the C's `MARKERP (position)' branch - so the
    ;; marker predicates come with it.
    (only (schemacs buffer)
          buffer-beg buffer-pt buffer-z bufferp current-buffer get-buffer
          text-editor-text)
    ;; the characters themselves - `count_lines' is a walk over them, as
    ;; the C's `display_count_lines' is a walk over the buffer's bytes.
    (only (schemacs buffer-text)
          buffer-text-ref buffer-text-base buffer-text-for-each)
    (only (schemacs marker) marker-position markerp)
    ;; `copy-sequence`'s bool-vector arm - the C's `Fcopy_sequence`
    ;; copies one, and `copy-category-table` (category.c) copies the
    ;; category sets it walks with it.
    (only (schemacs data)
          aref bool-vector? %bool-vector-copy %bool-vector-length)
    ;; `copy-sequence`'s char-table arm - `Fcopy_sequence` calls
    ;; `Fcopy_char_table` for one, and `casetab.c` copies a case table
    ;; with it.
    (only (schemacs chartab) char-table? copy-char-table)
    ;; the version comparison `string-version-lessp' is written over -
    ;; gnulib's `lib/filevercmp.c'.
    (only (schemacs filevercmp) %filevercmp)
    (only (guile) LC_COLLATE LC_CTYPE logxor lognot logand logior ash
          inexact->exact sin caddr cadddr hash-for-each)
    ;; `md5`'s UTF-8 bytes of a string; the C encodes with
    ;; `coding.c`, which this library is below.
    (only (ice-9 iconv) string->bytevector)
    )

  (export compare-strings
          equal-including-properties
          mapconcat
          identity
          delete
          %string
          nthcdr
   take
          nth
          elt
          %length
          proper-list-p
          mapcar
          mapcan
          %substring
          md5
          buffer-hash
          maphash
          concat
          vconcat
          copy-sequence
          copy-alist
          nreverse
          nconc clear-string
          %assq
          rassq rassoc
          %count-lines
          install-fns-textprop!
          line-number-at-pos
          plist-get plist-put
          string-collate-lessp
          string-equal string-search
          string-lessp
          string-version-lessp
          ;; `fns.c`'s two dialog-box switches.
          *use-dialog-box* use-file-dialog
          )

  (begin

    (define (compare-strings string1 start1 end1 string2 start2 end2 . args)
      ;; GNU Emacs's `compare-strings' (fns.c): #t when the two ranges
      ;; are the same, and otherwise an integer whose magnitude is *one
      ;; more* than the index of the first difference and whose sign
      ;; says which string is less - which is why callers write
      ;; `(abs tem) - 1' to get that index.
      ;;
      ;; The C walks the two ranges together, and when one runs out
      ;; first the shorter is the lesser at that position - which is
      ;; what makes "abc" sort before "abcd".
      ;;--------------------------------------------------------------
      (let ((ignore-case (if (pair? args) (car args) #f))
            ;; Emacs's docstring: "A value of nil for START1 or START2
            ;; means to use the beginning of the string" - `s-ends-with?'
            ;; is the caller that passes them as nil.
            (start1 (if start1 start1 0))
            (start2 (if start2 start2 0))
            (end1 (if end1 end1 (string-length string1)))
            (end2 (if end2 end2 (string-length string2))))
        (let loop ((i start1) (j start2) (n 0))
          (cond
           ((or (>= i end1) (>= j end2))
            (cond ((and (>= i end1) (>= j end2)) #t)
                  ((>= i end1) (- (+ n 1)))   ; string1 is a prefix: it is less
                  (else (+ n 1))))
           (else
            (let* ((c1 (string-ref string1 i))
                   (c2 (string-ref string2 j))
                   (c1 (if ignore-case (char-downcase c1) c1))
                   (c2 (if ignore-case (char-downcase c2) c2)))
              (cond
               ((char=? c1 c2) (loop (+ 1 i) (+ 1 j) (+ 1 n)))
               ((char<? c1 c2) (- (+ n 1)))
               (else (+ n 1)))))))))

    ;;----------------------------------------------------------------
    ;; The seam to `textprop.sld'
    ;;
    ;; `concat' moves the properties of its pieces with two functions
    ;; that are `textprop.c''s, and `(schemacs textprop)' is
    ;; *above* this library: `(schemacs minibuf)' imports this one
    ;; for `compare-strings', and textprop reaches minibuf through buffer
    ;; and subr. Emacs has the same cycle between fns.c and textprop.c and
    ;; does not care; a library system does, so the two are handed over at
    ;; load - the same seam as `install-ls-lisp-files!' and
    ;; `install-intervals-set-text-properties!'.

    (define %text-property-list
      (lambda args (error "fns: textprop.sld's `text-property-list' is not installed")))
    (define %add-text-properties-from-list
      (lambda args
        (error "fns: textprop.sld's `add-text-properties-from-list' is not installed")))

    (define (install-fns-textprop! text-property-list add-text-properties-from-list)
      (set! %text-property-list text-property-list)
      (set! %add-text-properties-from-list add-text-properties-from-list))

    ;;----------------------------------------------------------------
    ;; `md5' (`fns.c:6381')
    ;;
    ;; The RFC 1321 digest over a string's UTF-8 bytes. Emacs encodes
    ;; with `prefer-coding-system' (UTF-8 in a stock session) and lets
    ;; the caller name another with CODING-SYSTEM; **that argument is
    ;; not carried** - `fns.scm' is below `coding.scm', and a non-nil
    ;; CODING-SYSTEM signals rather than silently digesting UTF-8. The
    ;; buffer arm is not carried either, for the same reason: encoding a
    ;; buffer is the coding layer's. `md5'-as-a-checksum is what
    ;; `rfc2104-hash' asks for, and that is a string.
    ;;------------------------------------------------------------

    (define (%md5-u32 x) (logand x #xffffffff))

    (define (%md5-rotl x s)
      (%md5-u32 (logior (ash x s) (ash x (- s 32)))))

    (define %md5-k
      ;; `K[i] = floor(2^32 * abs(sin(i + 1)))' (RFC 1321, section 3.4).
      (list->vector
       (map (lambda (x)
              (%md5-u32 (inexact->exact (floor (* 4294967296 (abs (sin x)))))))
            (let loop ((i 1) (acc '()))
              (if (> i 64) (reverse acc) (loop (+ i 1) (cons i acc)))))))

    (define %md5-s
      ;; The per-round left-rotation amounts (RFC 1321, section 3.4).
      #(7 12 17 22 7 12 17 22 7 12 17 22 7 12 17 22
        5 9 14 20 5 9 14 20 5 9 14 20 5 9 14 20
        4 11 16 23 4 11 16 23 4 11 16 23 4 11 16 23
        6 10 15 21 6 10 15 21 6 10 15 21 6 10 15 21))

    (define (%md5-f i b c d)
      ;; The four auxiliary functions F, G, H, I of RFC 1321, 3.4.
      (cond ((< i 16) (logior (logand b c) (logand (lognot b) d)))
            ((< i 32) (logior (logand d b) (logand (lognot d) c)))
            ((< i 48) (logxor b c d))
            (else (logxor c (logior b (lognot d))))))

    (define (%md5-g i)
      (cond ((< i 16) i)
            ((< i 32) (modulo (+ (* 5 i) 1) 16))
            ((< i 48) (modulo (+ (* 3 i) 5) 16))
            (else (modulo (* 7 i) 16))))

    (define (%md5-block m a b c d)
      (let ((aa a) (bb b) (cc c) (dd d))
        (do ((i 0 (+ i 1))) ((= i 64))
          (let* ((f (%md5-f i bb cc dd))
                 (g (%md5-g i))
                 (sum (%md5-u32 (+ aa (%md5-u32 f)
                                   (vector-ref %md5-k i)
                                   (vector-ref m g))))
                 (rot (%md5-rotl sum (vector-ref %md5-s i)))
                 (tmp dd))
            (set! dd cc)
            (set! cc bb)
            (set! bb (%md5-u32 (+ bb rot)))
            (set! aa tmp)))
        (list (%md5-u32 (+ a aa)) (%md5-u32 (+ b bb))
              (%md5-u32 (+ c cc)) (%md5-u32 (+ d dd)))))

    (define (%md5-digest msg)
      ;; MSG is a bytevector: the digest is over bytes, and the caller
      ;; has already chosen the encoding (see `md5` below).
      (let* ((len (bytevector-length msg))
             (pad (modulo (- 56 (+ len 1)) 64))
             (total (+ len 1 pad 8))
             (padded (make-bytevector total 0)))
        (bytevector-copy! padded 0 msg)
        (bytevector-u8-set! padded len #x80)
        (let ((bits (* len 8)))
          (do ((i 0 (+ i 1))) ((= i 8))
            (bytevector-u8-set! padded (+ len 1 pad i)
                                (logand (ash bits (- (* 8 i))) #xff))))
        (let loop ((off 0)
                   (a #x67452301) (b #xefcdab89) (c #x98badcfe) (d #x10325476))
          (if (>= off total)
              (let ((out (make-bytevector 16 0)))
                (do ((i 0 (+ i 1))) ((= i 4))
                  (bytevector-u8-set! out i (logand (ash a (- (* 8 i))) #xff))
                  (bytevector-u8-set! out (+ 4 i) (logand (ash b (- (* 8 i))) #xff))
                  (bytevector-u8-set! out (+ 8 i) (logand (ash c (- (* 8 i))) #xff))
                  (bytevector-u8-set! out (+ 12 i) (logand (ash d (- (* 8 i))) #xff)))
                out)
              (let ((m (make-vector 16 0)))
                (do ((i 0 (+ i 1))) ((= i 16))
                  (vector-set! m i
                               (logior (bytevector-u8-ref padded (+ off (* 4 i)))
                                       (ash (bytevector-u8-ref padded (+ off (* 4 i) 1)) 8)
                                       (ash (bytevector-u8-ref padded (+ off (* 4 i) 2)) 16)
                                       (ash (bytevector-u8-ref padded (+ off (* 4 i) 3)) 24))))
                (let ((r (%md5-block m a b c d)))
                  (loop (+ off 64) (car r) (cadr r) (caddr r) (cadddr r))))))))

    (define (%md5-two-hex n)
      (let ((s (number->string n 16)))
        (if (= (string-length s) 1) (string-append "0" s) s)))

    (define (md5 object . rest)
      ;; GNU Emacs's `md5' (`fns.c:6381'): "Return MD5 message digest of
      ;; OBJECT, a buffer or string. ... The MD5 digest is 32-character
      ;; long." START and END are string positions, and a string's
      ;; positions are zero-based and END is exclusive - measured:
      ;; `(md5 "abcdef" 2 3)' is the digest of "c".
      ;;--------------------------------------------------------------
      ;; **A bytevector is accepted as well as a string**, which Emacs's
      ;; `md5' does not: Scheme has no unibyte string, and the HMAC in
      ;; `(schemacs net rfc2104)' needs the digest of raw bytes. This is
      ;; the named departure of the tree's string model.
      (unless (or (string? object) (bytevector? object))
        (error "md5: only a string or bytevector is supported here (the buffer arm needs `coding.scm')"))
      (when (and (>= (length rest) 3) (list-ref rest 2))
        (error "md5: CODING-SYSTEM is not supported (fns.scm is below coding.scm)"))
      (let* ((start (if (and (pair? rest) (car rest)) (car rest) 0))
             (end (if (and (pair? rest) (pair? (cdr rest)) (cadr rest))
                      (cadr rest)
                      (if (bytevector? object)
                          (bytevector-length object)
                          (string-length object))))
             (bytes (if (bytevector? object)
                        (let ((bv (make-bytevector (- end start))))
                          (bytevector-copy! bv 0 object start end)
                          bv)
                        (string->bytevector (substring object start end)
                                            "UTF-8")))
             (digest (%md5-digest bytes)))
        (let loop ((i 0) (acc ""))
          (if (= i 16)
              acc
              (loop (+ i 1)
                    (string-append acc
                                   (%md5-two-hex (bytevector-u8-ref digest i))))))))

    ;;----------------------------------------------------------------
    ;; `buffer-hash`
    ;;----------------------------------------------------------------

    (define (buffer-hash . args)
      ;; GNU Emacs's `buffer-hash' (`fns.c:6454`): "Return a hash of the
      ;; contents of BUFFER-OR-NAME. This hash is performed on the raw
      ;; internal format of the buffer, disregarding any coding systems.
      ;; If nil, use the current buffer."
      ;;
      ;; **The hash function is Guile's, not SHA-1**, and that is the one
      ;; departure here: Emacs answers a 40-character hex digest of a
      ;; SHA-1 over the buffer's bytes, and Guile's core has no SHA-1.
      ;; The tree's one caller is `with-buffer-unmodified-if-unchanged'
      ;; (`fill.scm' - `subr-x.el`'s macro, which Emacs uses to leave a
      ;; buffer unmodified when a fill ends where it started), and all it
      ;; does is compare two hashes of the same buffer, so what the
      ;; function has to be is *equal for equal text and different for
      ;; different text*. **Guile's `hash' is not usable for that**:
      ;; measured, `(hash (u32vector 1 2) N)' and `(hash (u32vector 1 3)
      ;; N)' answer the same number, because a uniform vector is hashed by
      ;; identity rather than by contents. So the fold is FNV-1a over the
      ;; code points, one pass and no allocation, in `%text-hash' below.
      ;; Emacs's own docstring says the value is "not guaranteed to return
      ;; the same hash between different Emacs versions", so the number
      ;; itself was never an interface.
      ;;
      ;; A BUFFER-OR-NAME that names no buffer is `nsberror`'s signal,
      ;; which is this tree's "Wrong type argument".
      ;;--------------------------------------------------------------
      (let* ((buffer-or-name (and (pair? args) (car args)))
             (buffer (cond ((not buffer-or-name) (current-buffer))
                           ((bufferp buffer-or-name) buffer-or-name)
                           (else
                            (or (get-buffer buffer-or-name)
                                (error "Wrong type argument" buffer-or-name))))))
        (%text-hash (text-editor-text buffer))))

    (define (maphash function table)
      ;; GNU Emacs's `maphash' (`fns.c:4644'): "Call FUNCTION on each
      ;; key/value pair in TABLE. FUNCTION is called with two arguments,
      ;; KEY and VALUE. Return nil."
      ;;--------------------------------------------------------------
      (hash-for-each (lambda (key value) (function key value)) table)
      #f)

    (define (%text-hash text)
      ;; FNV-1a over the code points, one pass and no allocation - which
      ;; is `sha1_process_bytes`' shape over the C's two segments, with a
      ;; different function. Guile's own `hash' is *not* usable here:
      ;; measured, `(hash (u32vector 1 2) N)' and `(hash (u32vector 1 3)
      ;; N)' answer the same number, because a uniform vector is hashed by
      ;; identity rather than by contents.
      ;;--------------------------------------------------------------
      (let ((h #x811c9dc5))
        (buffer-text-for-each
         text
         (lambda (position code)
           (set! h (modulo (* (logxor h code) #x01000193) #x100000000))))
        h))

    ;;----------------------------------------------------------------
    ;; Lines, counted and numbered
    ;;----------------------------------------------------------------

    (define (%count-lines ed from to)
      ;; The number of line boundaries between the positions FROM and TO -
      ;; GNU Emacs's `count_lines' (`xdisp.c:29903'), which is one call to
      ;; `display_count_lines (FROM, TO, ZV, &ignored)', the `count > 0'
      ;; branch of that walk.
      ;;
      ;; **The `%` is because Emacs's Lisp-visible `count-lines' is a
      ;; *different function* - `simple.el:1800' - and that one owns the
      ;; plain name, in `simple.scm'.** The C has both too, and they do
      ;; not collide there because this one is a C function with no Lisp
      ;; name at all (`lisp.h:4409' declares it and nothing DEFUNs it).
      ;; The two answer differently: over `"a\nb\nc"', the Lisp
      ;; `(count-lines 1 6)' is **3** (it adds one when the range does
      ;; not end at the start of a line), where this walk finds the two
      ;; newlines and answers **2**. The tree has been here before with
      ;; `kill-buffer' - the user-visible name is Emacs's, and the
      ;; mechanism takes the `%'.
      ;;
      ;; **Its Emacs file is `xdisp.c', and it lives here.** The C needs
      ;; it low, because `fns.c''s `line-number-at-pos' - this file's own
      ;; - is its only caller that is not `lread.c:645'; but
      ;; `(schemacs xdisp)' is the top of this tree's graph, so a
      ;; `count-lines' in its own file could only be reached from above,
      ;; and `line-number-at-pos' could not reach it at all. It is placed
      ;; beside the one function that wants it, and `xdisp.scm' imports
      ;; it from here. A placement departure, and this is the note.
      ;;
      ;; **The walk is a character-at-a-time one where the C's is a
      ;; byte-pointer one.** `display_count_lines' walks raw bytes up to
      ;; `BUFFER_CEILING_OF' and only then recomputes an address - a step
      ;; that exists because Emacs's buffer holds bytes with a gap at an
      ;; arbitrary point in them. `buffer-text' holds one element per
      ;; character and `buffer-text-ref' steps over the gap itself, so
      ;; the ceiling would buy one branch per element and nothing else.
      ;; The answers are identical. `selective-display', the C's other
      ;; branch (where a `\r' also ends a line), is not ported.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((pos from) (n 0))
          (cond
           ((>= pos to) n)
           ((= (buffer-text-ref text pos) #x0a) (loop (+ pos 1) (+ n 1)))
           (else (loop (+ pos 1) n))))))

    (define (line-number-at-pos . args)
      ;; GNU Emacs's `line-number-at-pos' (`fns.c:6688'), a DEFUN of this
      ;; file: "Return the line number at POSITION in the current buffer.
      ;; If POSITION is nil or omitted, it defaults to point's position
      ;; in the current buffer."
      ;;
      ;; The C's body, in its own order: a nil POSITION is `PT'; a
      ;; *marker* is its position (`marker_byte_position' of it when the
      ;; marker is in this buffer, `CHAR_TO_BYTE' of its position when it
      ;; is not - the same character position either way, this tree
      ;; having no bytes); anything else must be a fixnum inside
      ;; `[BEG, Z]', and the C raises `args-out-of-range' when it is not;
      ;; and then the answer is `count_lines (BEGV, POS) + 1'.
      ;;
      ;; **ABSOLUTE picks the start of the count**, and narrowing is what
      ;; makes the two starts differ: "If the buffer is narrowed, the
      ;; return value by default counts the lines from the beginning of
      ;; the accessible portion ... But if the second optional argument
      ;; ABSOLUTE is non-nil, the value counts the lines from the absolute
      ;; start of the buffer."
      ;;
      ;; The C's two branches, in its order: an absolute count starts at
      ;; `BEG` and takes POS as it stands; otherwise POS is *clipped* to
      ;; `[BEGV, ZV]` and the count starts at `BEGV`.
      ;;--------------------------------------------------------------
      (let* ((position (if (pair? args) (car args) #f))
             (ed (current-buffer))
             (pos (cond ((not position) (buffer-pt ed))
                        ((markerp position) (marker-position position))
                        ((integer? position)
                         (if (and (<= (buffer-beg ed) position)
                                  (<= position (buffer-z ed)))
                             position
                             (error "Args out of range" position
                                    (buffer-beg ed) (buffer-z ed))))
                        (else (error "Wrong type argument" position))))
             (absolute (and (pair? args) (pair? (cdr args)) (cadr args))))
        (if absolute
            (+ 1 (%count-lines ed
                               (buffer-text-base (text-editor-text ed))
                               pos))
            (+ 1 (%count-lines ed (buffer-beg ed)
                               (min (max pos (buffer-beg ed))
                                    (buffer-z ed)))))))

    (define (%chars-or-numbers->string elements)
      ;; A list of characters or character code points, as a string - the
      ;; C's `Fstring`: "The elements ... should be characters or
      ;; integers that are valid character codes." A character passes as
      ;; itself (it is this tree's spelling of one), an integer through
      ;; `integer->char`.
      ;;--------------------------------------------------------------
      (list->string
       (map (lambda (x)
              (cond ((char? x) x)
                    ((integer? x) (integer->char x))
                    (else (error "Wrong type argument: characterp" x))))
            elements)))

    (define (concat . args)
      ;; GNU Emacs's `concat' (fns.c): "Concatenate all the arguments and
      ;; make the result a string. The arguments may be strings, lists of
      ;; numbers, or vectors of numbers, which are turned into strings.
      ;; ... The result is a string with the text properties of the
      ;; arguments, when they have any."
      ;;
      ;; The string arm is here, with the list/vector-of-characters arms
      ;; beside it. **Those take `numbers` as well as characters**, as the
      ;; C's do (`Fstring` accepts either for a character element) - the
      ;; docstring's "lists of numbers" - which is what `mapconcat`'s
      ;; pieces arrive as when FUNCTION answers `(list c)`. The record and
      ;; bool-vector arms are not carried, nothing asking for them.
      ;;
      ;; The properties are what make this `concat' rather than
      ;; `string-append': the C concatenates first and then copies the
      ;; properties of each argument that had any onto the result at the
      ;; offset that argument was placed at, through `text_property_list'
      ;; and `add_text_properties_from_list'. `ls-lisp-format' builds its
      ;; whole line with this, and the `dired-filename' property has to
      ;; come out the other end.
      ;;--------------------------------------------------------------
      (let ((pieces
             (map (lambda (arg)
                    (cond ((string? arg) arg)
                          ((not arg) "")
                          ((char? arg) (string arg))
                          ((list? arg) (%chars-or-numbers->string arg))
                          ((vector? arg)
                           (%chars-or-numbers->string (vector->list arg)))
                          (else (error "Wrong type argument: sequencep" arg))))
                  args)))
        (let ((result (apply string-append pieces)))
          ;; Only a piece that carries properties is copied - the C's
          ;; `textprops' array holds only those - and each is copied at
          ;; the offset it went in at, which is what DELTA is.
          (let loop ((pieces pieces) (to 0))
            (if (null? pieces)
                result
                (let ((piece (car pieces)))
                  (if (string-intervals piece)
                      (%add-text-properties-from-list
                       result
                       (%text-property-list piece 0 (string-length piece) #f)
                       to))
                  (loop (cdr pieces) (+ to (string-length piece)))))))))

    (define (vconcat . sequences)
      ;; GNU Emacs's `vconcat` (`fns.c:750`), which is `concat_to_vector`
      ;; (`:735`): "Concatenate all the arguments and make the result a
      ;; vector. The result is a vector whose elements are the elements of
      ;; all the arguments. Each argument may be a list, vector or
      ;; string."
      ;;
      ;; A string contributes its *characters*, which is what makes
      ;; `(vconcat "ab")` the key sequence `[?a ?b]` - the C's
      ;; `concat_to_vector` reads a string with `FETCH_STRING_CHAR_ADVANCE`
      ;; for exactly that reason.
      ;;
      ;; `keymap.c`'s `append_key` is the caller that made this worth
      ;; having: it builds a key sequence one event at a time.
      ;;--------------------------------------------------------------
      (let* ((elements
              (apply append
                     (map (lambda (sequence)
                            (cond ((vector? sequence) (vector->list sequence))
                                  ((string? sequence)
                                   (map char->integer
                                        (string->list sequence)))
                                  ((pair? sequence) sequence)
                                  (else '())))
                          sequences)))
             (result (make-vector (length elements) #f)))
        (let loop ((i 0) (rest elements))
          (if (null? rest)
              result
              (begin
                (vector-set! result i (car rest))
                (loop (+ i 1) (cdr rest)))))))

    (define (mapconcat-sequence-elements sequence)
      ;; The sequence walk `mapcar1' makes for a list, a vector or a
      ;; string: a list of the elements, with a string's characters as
      ;; integers. `mapconcat', `mapcar' and `mapcan' all read a
      ;; sequence this way.
      ;;--------------------------------------------------------------
      (cond ((list? sequence) sequence)
            ((not sequence) '())   ; Emacs's nil
            ((vector? sequence) (vector->list sequence))
            ((string? sequence)
             (let loop ((i 0) (out '()))
               (if (>= i (string-length sequence))
                   (reverse out)
                   (loop (+ i 1)
                         (cons (char->integer
                                (string-ref sequence i))
                               out)))))
            (else
             (error "Wrong type argument: sequencep" sequence))))

    (define (mapconcat function sequence . rest)
      ;; GNU Emacs's `mapconcat' (`fns.c'): "Apply FUNCTION to each element
      ;; of SEQUENCE, and concat the results as strings. In between each
      ;; pair of results, stick in SEPARATOR."
      ;;
      ;; SEQUENCE may be a list, a vector or a string; over a string
      ;; FUNCTION is called with each character as an *integer*, as the
      ;; C's `mapcar1' does. A nil result is the empty string, and the
      ;; separator may be a string, a vector or a list of characters -
      ;; `concat' takes all of those, and copies their properties, as the
      ;; C's final `Fconcat' does. A bool-vector sequence is not carried;
      ;; nothing here makes one.
      ;;--------------------------------------------------------------
      (let* ((elements (mapconcat-sequence-elements sequence))
             (pieces
              (let loop ((rest elements) (out '()))
                (if (null? rest)
                    (reverse out)
                    (loop (cdr rest) (cons (function (car rest)) out)))))
             (sep (if (pair? rest) (or (car rest) "") "")))
        (if (null? pieces)
            ""
            (let loop ((rest (cdr pieces)) (out (concat (car pieces))))
              (if (null? rest)
                  out
                  (loop (cdr rest) (concat out sep (car rest))))))))

    (define (delete elt seq)
      ;; GNU Emacs's `delete' (`fns.c:2138`): "Delete members of SEQ
      ;; which are `equal' to ELT, and return the result. SEQ must be a
      ;; sequence (i.e. a list, a vector, or a string)."
      ;;
      ;; The list arm is `delq''s splice with `equal?' instead of `eq?'
      ;; - destructive, as Emacs's is. The vector and string arms are
      ;; non-destructive copies. Emacs's string arm compares *characters
      ;; as integers*; an element of a Scheme string is a character, so
      ;; an integer ELT is compared as its character.
      ;;--------------------------------------------------------------
      (define (same? a b)
        (equal? (if (and (char? b) (integer? a)) (char->integer b) b) a))
      (cond
       ((or (pair? seq) (null? seq))
        ;; "if (NILP (prev)) return ...; check the head, then splice."
        (let skip ((l seq))
          (cond ((null? l) l)
                ((same? elt (car l)) (skip (cdr l)))
                (else
                 (let loop ((prev l) (rest (cdr l)))
                   (cond ((null? rest) l)
                         ((same? elt (car rest))
                          (set-cdr! prev (cdr rest))
                          (loop prev (cdr rest)))
                         (else (loop rest (cdr rest)))))))))
       ((vector? seq)
        (list->vector
         (let loop ((i 0) (out '()))
           (if (>= i (vector-length seq))
               (reverse out)
               (loop (+ i 1)
                     (if (same? elt (vector-ref seq i))
                         out
                         (cons (vector-ref seq i) out)))))))
       ((string? seq)
        (list->string
         (let loop ((i 0) (out '()))
           (if (>= i (string-length seq))
               (reverse out)
               (loop (+ i 1)
                     (if (same? elt (string-ref seq i))
                         out
                         (cons (string-ref seq i) out)))))))
       (else (error "Wrong type argument: sequencep, ~s" seq))))

    (define (%string . elements)
      ;; GNU Emacs's `string' (`character.c:846`): "Return a newly
      ;; created string containing the characters whose codes are the
      ;; arguments." Its arguments are integers in Emacs; characters
      ;; are accepted here too, the same courtesy `aref' pays in
      ;; reverse. **Placement**: `character.c' has no library here, and
      ;; `%chars-or-numbers->string' (below) is the shared walk.
      ;;--------------------------------------------------------------
      (%chars-or-numbers->string elements))

    (define (identity argument)
      ;; GNU Emacs's `identity' (`fns.c:49`): "Return the ARGUMENT
      ;; unchanged."
      ;;--------------------------------------------------------------
      argument)

    (define (%length sequence)
      ;; GNU Emacs's `length' (`fns.c:127`): "Return the length of vector,
      ;; list or string SEQUENCE." - and, since the C tests them, a
      ;; bool-vector's bit count and a char-table's `MAX_CHAR + 1'.
      ;;
      ;; **Named `%length' because a core binding cannot be shadowed**:
      ;; `(scheme base)` exports `length`, and a library definition of it
      ;; is refused (the rule `%assq' and `%substring` carry). Emacs's
      ;; `length` also takes nil - either of this tree's nils - as 0.
      ;;--------------------------------------------------------------
      (cond ((null? sequence) 0)
            ((pair? sequence) (length sequence))
            ((string? sequence) (string-length sequence))
            ((vector? sequence) (vector-length sequence))
            ((bool-vector? sequence) (%bool-vector-length sequence))
            ((char-table? sequence) (+ #x3FFFFF 1))
            ((not sequence) 0)
            (else (error "Wrong type argument: sequencep, ~s" sequence))))

    (define (proper-list-p object)
      ;; GNU Emacs's `proper-list-p' (`fns.c:244'): "Return OBJECT's
      ;; length if it is a proper list, nil otherwise. A proper list is
      ;; neither circular nor dotted (i.e., its last cdr is nil)."
      ;;
      ;; The C walks with `FOR_EACH_TAIL_SAFE`, which is Floyd's
      ;; tortoise and hare: a circular list is recognised as soon as the
      ;; fast pointer meets the slow one, and a dotted one by its last
      ;; cdr not being nil. Both answers are `#f'.
      ;;--------------------------------------------------------------
      (let loop ((tail object) (tortoise object) (step 0) (len 0))
        (cond
         ((null? tail) len)
         ((not (pair? tail)) #f)
         ((and (> step 1) (eq? tail tortoise)) #f)
         (else
          (loop (cdr tail)
                (if (even? step)
                    (if (pair? tortoise) (cdr tortoise) tortoise)
                    tortoise)
                (+ step 1)
                (+ len 1))))))

    (define (nthcdr n list)
      ;; GNU Emacs's `nthcdr' (`fns.c:1750`): "Take cdr N times on
      ;; LIST, return the result." A list shorter than N answers nil -
      ;; the C's `return Qnil' after `CHECK_LIST_END' - rather than
      ;; Scheme's `list-tail' error, which is the tolerance the callers
      ;; rely on.
      ;;
      ;; **Moved here from `subr.scm', where it was a placement
      ;; departure**: `nthcdr' and `nth' are `fns.c''s, and `elt' is
      ;; written on them. `subr.scm' imports and re-exports both, so
      ;; its callers are unchanged.
      ;;--------------------------------------------------------------
      (let loop ((n n) (rest list))
        (if (or (<= n 0) (not (pair? rest)))
            rest
            (loop (- n 1) (cdr rest)))))

    (define (take n list)
      ;; GNU Emacs's `take' (`fns.c:1672'): "Return the first N elements
      ;; of LIST. If N is zero or negative, return nil. If N is greater
      ;; or equal to the length of LIST, return LIST (or a copy)."
      ;;
      ;; The C builds the copy with `Fcons' and answers `Qnil' for the
      ;; empty cases; this tree spells an empty list `'()`, so the
      ;; answer can be `append`ed, as `rx''s caller does.
      ;;--------------------------------------------------------------
      (cond ((not (integer? n))
             (error "Wrong type argument: integerp, ~s" n))
            ((<= n 0) '())
            ((null? list) '())
            ((list? list)
             ;; `(list X)' would apply the parameter `list` - Lisp-1.
             (let loop ((m (- n 1)) (rest (cdr list))
                        (acc (cons (car list) '())))
               (if (and (> m 0) (pair? rest))
                   (loop (- m 1) (cdr rest) (cons (car rest) acc))
                   (reverse acc))))
            (else (error "Wrong type argument: listp, ~s" list))))

    (define (nth n list)
      ;; GNU Emacs's `nth' (`fns.c:1846`): "Return the Nth element of
      ;; LIST. N counts from zero. If LIST is not that long, nil is
      ;; returned." Emacs's body is `(car (nthcdr n list))' - and `(car
      ;; nil)' is nil; this tree's nil for the callers that test the
      ;; answer is `#f' (the spelling `subr.scm' used before the move).
      ;;--------------------------------------------------------------
      (let ((tail (nthcdr n list)))
        (and (pair? tail) (car tail))))

    (define (elt sequence n)
      ;; GNU Emacs's `elt' (`fns.c:1854`): "Return element of SEQUENCE at
      ;; index N."
      ;;
      ;; Emacs's own body is two lines: a list (and nil, which is a
      ;; list) is `(car (nthcdr N SEQUENCE))', everything else is
      ;; `aref' - whose string arm answers a character *code*. The
      ;; list arm's out-of-range answer is `(car nil)' i.e. nil.
      ;;--------------------------------------------------------------
      (cond ((or (pair? sequence) (null? sequence))
             (let ((tail (nthcdr n sequence)))
               (if (pair? tail) (car tail) '())))
            ((or (string? sequence) (vector? sequence)
                 (char-table? sequence) (bool-vector? sequence))
             (aref sequence n))
            (else
             (error "Wrong type argument: sequencep, ~s" sequence))))

    (define (mapcar function sequence)
      ;; GNU Emacs's `mapcar' (`fns.c:3552'): "Apply FUNCTION to each
      ;; element of SEQUENCE, and make a list of the results."
      ;;
      ;; SEQUENCE may be a list, a vector or a string; over a string
      ;; FUNCTION is called with each character as an *integer*, as the
      ;; C's `mapcar1' does (`mapconcat' above takes the same walk).
      ;;--------------------------------------------------------------
      (let loop ((rest (mapconcat-sequence-elements sequence)) (out '()))
        (if (null? rest)
            (reverse out)
            (loop (cdr rest) (cons (function (car rest)) out)))))

    (define (mapcan function sequence)
      ;; GNU Emacs's `mapcan' (`fns.c:3586'): "Apply FUNCTION to each
      ;; element of SEQUENCE, and concatenate the results by altering
      ;; them (using `nconc')."
      ;;
      ;; Emacs's body is `(apply #'nconc (Fmapcar ...))' over an
      ;; argument vector; here the mapped results are handed straight to
      ;; `nconc', which has the C's own mutating walk.
      ;;--------------------------------------------------------------
      (apply nconc (mapcar function sequence)))

    (define (%substring string . args)
      ;; GNU Emacs's `substring' (`fns.c:1579'): "Return a new string
      ;; whose contents are a substring of STRING. ... Negative values
      ;; count from the end of STRING. If TO is nil, it means the length
      ;; of STRING. If FROM is nil or omitted, it means 0."
      ;;
      ;; **Why it exists: Scheme's `substring' drops text properties.**
      ;; Emacs's is `substring_both', which copies the characters and
      ;; then `copy_text_properties' from the source range - so a ported
      ;; Elisp that cuts a propertized string keeps its faces and its
      ;; `keymap`/`close-tab` properties. Guile's `substring' is, in
      ;; Emacs's vocabulary, `substring-no-properties' (`fns.c:1610'),
      ;; and a port that reaches for it loses them silently: the tab
      ;; bar's padding loop (`tab-bar-auto-width`, `tab-bar.el:1444') is
      ;; built out of `substring' and `concat', and the close button
      ;; stopped being a close button because of it.
      ;;
      ;; **Named `%substring' because a core binding cannot be shadowed**
      ;; - the rule `%assq' (`:463') already carries - and `substring' is
      ;; `(scheme base)''s. Use this one wherever the Emacs original uses
      ;; `substring', and Guile's only where Emacs would have written
      ;; `substring-no-properties'.
      ;;
      ;; **Not carried: the vector arm.** Emacs's `CHECK_VECTOR_OR_STRING`
      ;; lets `substring` cut a vector too; nothing here does, and
      ;; `vector-copy` is the Scheme spelling of the same operation.
      ;;--------------------------------------------------------------
      (let* ((len (string-length string))
             (from (if (and (pair? args) (car args)) (car args) 0))
             (from (if (< from 0) (+ len from) from))
             (to (if (and (pair? args) (pair? (cdr args)) (cadr args))
                     (cadr args)
                     len))
             (to (if (< to 0) (+ len to) to)))
        ;; `validate_subarray` (`fns.c:1550`): "Signals an error if the
        ;; range is not within the array's bounds" - it does not clip, and
        ;; a FROM past TO is the same error. Measured on Emacs 31.1:
        ;; `(substring "abcdef" -9)` and `(substring "abcdef" 5 2)` both
        ;; raise `args-out-of-range`.
        (unless (and (<= 0 from) (<= from len))
          (error "Args out of range" string from))
        (unless (and (<= 0 to) (<= to len))
          (error "Args out of range" string to))
        (when (> from to)
          (error "Args out of range" string from to))
        (let ((result (substring string from to))
              (ivs (string-intervals string)))
          (when ivs
            (let ((copy (copy-intervals ivs from (- to from))))
              (when copy
                (set-interval-object! copy result)
                (set!string-intervals result copy))))
          result)))

    (define (equal-including-properties o1 o2)
      ;; GNU Emacs's `equal-including-properties' (`fns.c:2823'): "Return
      ;; t if two Lisp objects have similar structure and contents. This
      ;; is like `equal' except that it compares the text properties of
      ;; strings. (`equal' ignores text properties.)"
      ;;
      ;; Scheme's `equal?' ignores a string's properties too, and that is
      ;; not a corner case here: the redisplay skips a mode line or tab
      ;; line whose freshly formatted string `equal?' says it already
      ;; drew, and two tab lines can have exactly the same characters
      ;; with different *faces* - which is what a window switching
      ;; between two buffers produces. The skip then left a wiped row
      ;; blank (`C-x <right>' `C-x <left>' in a tab-line frame).
      ;;
      ;; The C is `internal_equal' with `EQUAL_INCLUDING_PROPERTIES',
      ;; which recurses through conses and vectors and, for strings,
      ;; calls `compare_string_intervals'. The vector arm is carried; the
      ;; hash-table, char-table and record arms answer `equal?' here,
      ;; nothing in the tree asking for their properties.
      ;;--------------------------------------------------------------
      (cond
       ((and (string? o1) (string? o2))
        (and (string=? o1 o2) (compare-string-intervals o1 o2)))
       ((and (pair? o1) (pair? o2))
        (and (equal-including-properties (car o1) (car o2))
             (equal-including-properties (cdr o1) (cdr o2))))
       ((and (vector? o1) (vector? o2))
        (and (= (vector-length o1) (vector-length o2))
             (let loop ((i 0))
               (or (>= i (vector-length o1))
                   (and (equal-including-properties (vector-ref o1 i)
                                                    (vector-ref o2 i))
                        (loop (+ i 1)))))))
       (else (equal? o1 o2))))

    (define (copy-sequence arg)
      ;; GNU Emacs's `copy-sequence' (fns.c:761): "Return a copy of a
      ;; list, vector, string, char-table or record. The elements of a
      ;; list, vector or record are not copied; they are shared with the
      ;; original."
      ;;
      ;; **The list and vector arms are the Scheme calls Emacs's C
      ;; makes**, and they are not optional: `icons.el`'s `icons--copy-spec`
      ;; is `(map #'copy-sequence spec)` over each entry of an icon's
      ;; specification, which is a *list*, and this function answered
      ;; "Wrong type argument: sequencep" for it until a caller arrived.
      ;;
      ;; A string's properties are copied because the C copies them -
      ;; `copy_intervals' over the whole of it - and because a copy that
      ;; quietly lost them would make `substring' and `concat' the only
      ;; ways to keep them.
      ;;--------------------------------------------------------------
      (cond
       ((pair? arg) (list-copy arg))
       ((null? arg) '())
       ((string? arg)
        (let ((val (string-copy arg))
              (ivs (string-intervals arg)))
          (if ivs
              (let ((copy (copy-intervals ivs 0 (string-length val))))
                (set-interval-object! copy val)
                (set!string-intervals val copy)))
          val))
       ((vector? arg) (vector-copy arg))
       ;; `Fcopy_sequence`'s bool-vector arm (`fns.c`): a new vector with
       ;; the same elements.
       ((bool-vector? arg) (%bool-vector-copy arg))
       ((char-table? arg) (copy-char-table arg))
       (else (error "Wrong type argument: sequencep" arg))))

    (define (copy-alist alist)
      ;; GNU Emacs's `copy-alist' (`fns.c:1516'): "Return a copy of
      ;; ALIST. This is an alist which represents the same mapping from
      ;; objects to objects, but does not share the alist structure with
      ;; ALIST. The objects mapped (cars and cdrs of elements of the
      ;; alist) are shared, however. Elements of ALIST that are not conses
      ;; are also shared."
      ;;
      ;; The C is `Fcopy_sequence' and then a fresh cons for every element
      ;; that is a cons - `XSETCAR (tem, Fcons (XCAR (car), XCDR (car)))`.
      ;; That is what a style needs: `c-get-style-variables' hands out
      ;; copies of `c-style-alist''s entries, and `c-set-offset' then
      ;; `setcdr's them in place.
      ;;--------------------------------------------------------------
      (if (null? alist)
          alist
          (let ((copy (list-copy alist)))
            (let loop ((tail copy))
              (when (pair? tail)
                (let ((element (car tail)))
                  (when (pair? element)
                    (set-car! tail (cons (car element) (cdr element))))
                  (loop (cdr tail)))))
            copy)))

    (define (nreverse seq)
      ;; GNU Emacs's `nreverse' (`fns.c:2269'): "Reverse order of items
      ;; in a list, vector or string SEQ. If SEQ is a list, it should be
      ;; nil-terminated. This function may destructively modify SEQ to
      ;; produce the value."
      ;;
      ;; The string arm is `Freverse', whose string case returns a new
      ;; string - Guile's `string-reverse' - because `(scheme base)' owns
      ;; the name `reverse' and a library cannot shadow a core binding.
      ;; The C's bool-vector arm has no counterpart here: `bool-vector'
      ;; is a pseudovector type this tree does not carry.
      ;;--------------------------------------------------------------
      (cond
       ((null? seq) seq)
       ((pair? seq)
        (let loop ((prev '()) (tail seq))
          (if (pair? tail)
              (let ((next (cdr tail)))
                ;; "If SEQ contains a cycle, attempting to reverse it
                ;; in-place will inevitably come back to SEQ."
                (when (eq? next seq) (error "Circular list"))
                (set-cdr! tail prev)
                (loop tail next))
              (begin
                (unless (null? tail)
                  (error "Wrong type argument: listp" seq))
                prev))))
       ((vector? seq)
        (let ((size (vector-length seq)))
          (let loop ((i 0))
            (when (< i (quotient size 2))
              (let ((tem (vector-ref seq i)))
                (vector-set! seq i (vector-ref seq (- size i 1)))
                (vector-set! seq (- size i 1) tem))
              (loop (+ i 1))))
          seq))
       ;; `Freverse`'s string arm. Guile has no core `string-reverse`
       ;; ((srfi srfi-13)'s is not imported here), so it is the list
       ;; reversal spelled out.
       ((string? seq) (list->string (reverse (string->list seq))))
       (else (error "Wrong type argument: arrayp" seq))))

    (define (clear-string string)
      ;; GNU Emacs's `clear-string` (`fns.c:3365'): "Clear the contents
      ;; of STRING.  This makes STRING unibyte, clears its contents to
      ;; null characters, and removes all text properties.  This may
      ;; change its length."
      ;;
      ;; The string's text properties live in its interval tree;
      ;; dropping the tree is `Fset_text_properties (0, len, nil,
      ;; string)`.  **Departure**: this tree has no unibyte strings, so
      ;; the filled string keeps one NUL *character* per character where
      ;; Emacs's holds one NUL byte per byte of the old string; for an
      ;; ASCII string - the password `read-passwd` clears - the two are
      ;; the same.
      ;;--------------------------------------------------------------
      (if (not (string? string))
          (error "Wrong type argument: stringp, ~a" string))
      (set!string-intervals string #f)
      (string-fill! string #\nul)
      #f)

    (define (nconc . lists)
      ;; GNU Emacs's `nconc' (`fns.c:3390'): "Concatenate any number of
      ;; lists by altering them. Only the last argument is not altered,
      ;; and need not be a list."
      ;;
      ;; The C's `args' array is written back as it walks - when an
      ;; argument is nil the *next* argument is rebound to the tail just
      ;; linked, so the nil disappears into the chain - and that is why
      ;; the arguments are a vector here rather than the rest list.
      ;;--------------------------------------------------------------
      (let* ((nargs (length lists))
             (args (list->vector lists)))
        (let ((val '()))
          (let loop ((argnum 0))
            (if (>= argnum nargs)
                val
                (let ((tem (vector-ref args argnum)))
                  ;; Emacs's `nil' is this tree's `'()` *and* `#f'; the
                  ;; C's NILP test skips both, and `mapcan' hands #f in
                  ;; as the result of a function that matched nothing.
                  (if (or (null? tem) (not tem))
                      (loop (+ argnum 1))
                      (begin
                        (when (null? val) (set! val tem))
                        (if (= (+ argnum 1) nargs)
                            val
                            (begin
                              (unless (pair? tem)
                                (error "Wrong type argument: listp" tem))
                              ;; FOR_EACH_TAIL: the last pair of TEM.
                              (let ((tail (let last ((tail tem))
                                            (let ((next (cdr tail)))
                                              (if (pair? next)
                                                  (last next)
                                                  tail)))))
                                (let ((next (vector-ref args (+ argnum 1))))
                                  ;; A nil next is a proper list end; #f
                                  ;; is this tree's other nil, so it is
                                  ;; written as the empty list rather
                                  ;; than left as a dotted tail. (`'()'
                                  ;; is true in Scheme: the test must
                                  ;; name both nils.)
                                  (if (or (null? next) (not next))
                                      (begin
                                        (set-cdr! tail '())
                                        (vector-set! args (+ argnum 1) tail))
                                      (set-cdr! tail next)))
                                (loop (+ argnum 1)))))))))))))

    (define (string-equal s1 s2)
      ;; GNU Emacs's `string-equal` (`fns.c:339`): "Return t if two
      ;; strings have identical contents. Case is significant, but text
      ;; properties are ignored. Symbols are also allowed; their print
      ;; names are used instead."
      ;;
      ;; `string=?' here compares characters and knows nothing of text
      ;; properties, which is what "properties are ignored" means; the
      ;; symbol arm is the C's first two lines.
      ;;--------------------------------------------------------------
      (string=? (if (symbol? s1) (symbol->string s1) s1)
                (if (symbol? s2) (symbol->string s2) s2)))

    (define (string-search needle haystack . rest)
      ;; GNU Emacs's `string-search' (`fns.c:6583'): "Search for the
      ;; string NEEDLE in the string HAYSTACK.  The return value is the
      ;; position of the first occurrence of NEEDLE in HAYSTACK, or nil
      ;; if no match was found.  ... Case is always significant and text
      ;; properties are ignored."
      ;;
      ;; START-POS must be between zero and the length of HAYSTACK,
      ;; inclusive, as the C's `CHECK_FIXNUM' arm says; nil is zero.
      ;;--------------------------------------------------------------
      (let* ((start (if (and (pair? rest) (car rest)) (car rest) 0))
             (n (string-length needle))
             (h (string-length haystack)))
        (when (or (< start 0) (> start h))
          (error "Args out of range" start))
        (let loop ((i start))
          (cond
           ((> i (- h n)) #f)
           ((let inner ((j 0))
              (cond ((= j n) #t)
                    ((char=? (string-ref haystack (+ i j))
                             (string-ref needle j))
                     (inner (+ j 1)))
                    (else #f)))
            i)
           (else (loop (+ i 1)))))))

    (define (string-lessp s1 s2)
      ;; GNU Emacs's `string-lessp' (fns.c): "Return t if first arg
      ;; string is less than second in lexicographic order. Case is
      ;; significant." It is `compare-strings' over the whole of both,
      ;; which is how the C is written too.
      ;;--------------------------------------------------------------
      (let ((u (compare-strings s1 0 #f s2 0 #f #f)))
        (and (integer? u) (< u 0))))

    (define (string-version-lessp s1 s2)
      ;; GNU Emacs's `string-version-lessp' (fns.c:577): "Return non-nil
      ;; if S1 is less than S2, as version strings.
      ;;
      ;; This function compares version strings S1 and S2:
      ;;    1) By prefix lexicographically.
      ;;    2) Then by version (similarly to version comparison of
      ;;       Debian's dpkg). Leading zeros in version numbers are
      ;;       ignored.
      ;;    3) If both prefix and version are equal, compare as ordinary
      ;;       strings.
      ;;
      ;; For example, \"foo2.png\" compares less than \"foo12.png\".
      ;; Case is significant. Symbols are also allowed; their print
      ;; names are used instead."
      ;;
      ;; The C hands the two strings' bytes to `filenvercmp'
      ;; (`filevercmp.c:140'); the comparison itself is
      ;; `(schemacs filevercmp)'. The symbol coercion is the
      ;; C's: a symbol's print name, then `CHECK_STRING' on each.
      ;;--------------------------------------------------------------
      (let ((s1 (if (symbol? s1) (symbol->string s1) s1))
            (s2 (if (symbol? s2) (symbol->string s2) s2)))
        (unless (string? s1) (error "Wrong type argument: stringp" s1))
        (unless (string? s2) (error "Wrong type argument: stringp" s2))
        (< (%filevercmp s1 s2) 0)))

    (define (string-collate-lessp s1 s2 . args)
      ;; GNU Emacs's `string-collate-lessp' (fns.c): "Return t if first
      ;; arg string is less than second in collation order. Symbols are
      ;; also allowed; their print names are used instead."
      ;;
      ;; "The optional argument LOCALE, a string, overrides the setting
      ;; of your current locale identifier for collation. ...
      ;; If IGNORE-CASE is non-nil, characters are converted to
      ;; lower-case before comparing them."
      ;;
      ;; The C lowercases with `towlower' and then calls `wcscoll';
      ;; `(ice-9 i18n)''s `string-locale-ci<?' is the same pairing of
      ;; `towlower' and `strcoll', so the two branches below are the two
      ;; of `str_collate'.
      ;;--------------------------------------------------------------
      (let* ((locale (if (pair? args) (car args) #f))
             (ignore-case (and (pair? args) (pair? (cdr args)) (cadr args)))
             (s1 (if (symbol? s1) (symbol->string s1) s1))
             (s2 (if (symbol? s2) (symbol->string s2) s2))
             (loc (if (string? locale)
                      (make-locale (list LC_COLLATE LC_CTYPE) locale)
                      #f)))
        (define (compare)               ; the C's `wcscoll'
          (if loc
              (if ignore-case
                  (string-locale-ci<? s1 s2 loc)
                  (string-locale<? s1 s2 loc))
              (if ignore-case
                  (string-locale-ci<? s1 s2)
                  (string-locale<? s1 s2))))
        (compare)))

    ;;----------------------------------------------------------------
    ;; `assq'
    ;;----------------------------------------------------------------

    (define (%assq key alist)
      ;; GNU Emacs's `assq' (`fns.c:1967'): "Return non-nil if KEY is `eq'
      ;; to the car of an element of ALIST. The value is actually the
      ;; first element of ALIST whose car is KEY. Elements of ALIST that
      ;; are not conses are ignored."
      ;;
      ;; **The `%` is because Guile's core `assq` cannot be shadowed by a
      ;; library import.** Measured: a library that excepts `assq' from
      ;; `(scheme base)' and imports another library's `assq' still calls
      ;; the core one - the module's binding is not the imported
      ;; procedure (`(eq? (module-ref user 'assq) (module-ref other
      ;; 'assq))' is #f). That is the same situation `%kill-buffer' is in,
      ;; from the other side: the host claims the plain name.
      ;;
      ;; The difference this port exists for is the docstring's last
      ;; sentence, which R7RS's `assq' does not have: it is "an error" for
      ;; an element not to be a pair, and Guile's raises, where Emacs
      ;; steps over it. Measured on Emacs 31.1: `(assq 'bar '(foo))' is
      ;; nil and `(assq 'bar '(foo (bar . 2)))' is `(bar . 2)'. It is the
      ;; shape `buffer-invisibility-spec' has - symbols and `(SYMBOL .
      ;; BOOL)' pairs in one list - and it is why `window--state-assq' and
      ;; `tab-bar--assq' exist lower in the tree.
      ;;
      ;; **The rest of the tree still calls the core `assq'.** Converting
      ;; it, and `assoc''s identical tolerance, is named in DEPARTURES.md
      ;; as the follow-up rather than done in this pass; the two private
      ;; look-alikes above are where that work starts.
      ;;
      ;; The C walks with `FOR_EACH_TAIL' and then `CHECK_LIST_END', so an
      ;; improper tail is `wrong-type-argument listp'; this raises the
      ;; tree's ordinary type error there, and reads Elisp's nil as either
      ;; of the tree's two spellings (`#f' or `()').
      ;;--------------------------------------------------------------
      (let loop ((tail alist))
        (cond ((or (null? tail) (not tail)) #f)
              ((not (pair? tail)) (error "Wrong type argument" alist))
              ((and (pair? (car tail)) (eq? (car (car tail)) key))
               (car tail))
              (else (loop (cdr tail))))))

    ;; `rassq' and `rassoc' (`fns.c:2050', `:2063')
    ;;
    ;; The reverse `assq': the value is the element whose *cdr* is KEY.
    ;; cc-engine's `c-add-stmt-syntax' asks `(rassq SYNTAX-SYMBOL
    ;; c-other-decl-block-key-in-symbols-alist)', and the host has no
    ;; binding for either name (`(scheme base)' has no `rassq', and
    ;; Guile's own module does not export one - measured), so both are
    ;; written out here. Non-cons elements are ignored, as in `%assq'.
    (define (rassq key alist)
      ;; "Return non-nil if KEY is `eq' to the cdr of an element of
      ;; ALIST. The value is actually the first element of ALIST whose
      ;; cdr is KEY."
      (let loop ((tail alist))
        (cond ((or (null? tail) (not tail)) #f)
              ((not (pair? tail)) (error "Wrong type argument" alist))
              ((and (pair? (car tail)) (eq? (cdr (car tail)) key))
               (car tail))
              (else (loop (cdr tail))))))

    (define (rassoc key alist)
      ;; "Return non-nil if KEY is `equal' to the cdr of an element of
      ;; ALIST. The value is actually the first element of ALIST whose cdr
      ;; equals KEY." The C's `eq_comparable_value' fast path is the same
      ;; test as the `equal?' it skips.
      (let loop ((tail alist))
        (cond ((or (null? tail) (not tail)) #f)
              ((not (pair? tail)) (error "Wrong type argument" alist))
              ((and (pair? (car tail))
                    (or (eq? (cdr (car tail)) key)
                        (equal? (cdr (car tail)) key)))
               (car tail))
              (else (loop (cdr tail))))))

    ;;----------------------------------------------------------------
    ;; Property lists - `fns.c`'s three, which the menu machinery needs
    ;; (`keymap--menu-item-binding` reads a `:filter` out of a
    ;; `menu-item` definition) and nothing here had yet.
    ;;
    ;; Emacs 31 added the optional PREDICATE to all three; it defaults
    ;; to `eq', which is what the two-argument calls get.
    ;;----------------------------------------------------------------

    (define (%plist-match? predicate a b)
      (if predicate (predicate a b) (eq? a b)))

    (define (plist-get plist prop . optional)
      ;; GNU Emacs's `plist-get' (`fns.c:2609'): "Extract a value from a
      ;; property list. ... This function doesn't signal an error if
      ;; PLIST is invalid."
      ;;
      ;; **Nil is also a value**, so a missing property and a property
      ;; whose value is nil both answer nil - that is why `plist-member'
      ;; exists.
      ;;--------------------------------------------------------------
      (let ((predicate (if (pair? optional) (car optional) #f)))
        (let loop ((tail plist))
          (cond ((not (pair? tail)) #f)
                ((not (pair? (cdr tail))) #f)
                ((%plist-match? predicate (car tail) prop) (cadr tail))
                ;; TWO conses a step: the C's body advances one and
                ;; `FOR_EACH_TAIL' advances the other, so it only ever
                ;; lands on a property, never on a value.
                (else (loop (cddr tail)))))))

    (define (plist-put plist prop val . optional)
      ;; GNU Emacs's `plist-put' (`fns.c:2667'): "Change value in PLIST
      ;; of PROP to VAL. ... The PLIST is modified by side effects."
      ;;
      ;; The new pair goes at the END when PROP is absent, and the list
      ;; itself is answered when a previous element was changed, so
      ;; `(setq x (plist-put x prop val))' is the caller's shape.
      ;;--------------------------------------------------------------
      (let ((predicate (if (pair? optional) (car optional) #f)))
        (let loop ((prev #f) (tail plist))
          (cond
           ((not (pair? tail))
            (unless (null? tail)
              (error "Wrong type argument: plistp" plist))
            (let ((newcell (cons prop
                                 (cons val (if prev (cddr prev) plist)))))
              (if prev
                  (begin (set-cdr! (cdr prev) newcell) plist)
                  newcell)))
           ((not (pair? (cdr tail)))
            (error "Wrong type argument: plistp" plist))
           ((%plist-match? predicate (car tail) prop)
            (set-car! (cdr tail) val)
            plist)
           (else (loop tail (cddr tail)))))))

    ;; `plist-member' is **intervals.scm's**, not this file's, even
    ;; though `fns.c' keeps all three together: `merge_properties_sticky'
    ;; needs it, `intervals' is below this library, and a second copy
    ;; here would be the tree's duplicate-binding bug (`loadup-tests'
    ;; fails on two definitions of one name). Its walk is the same
    ;; two-cons step these use.

    ;;----------------------------------------------------------------
    ;; The dialog-box switches - `fns.c:6850'
    ;;
    ;; **The pair is deliberately not the same kind of variable.**
    ;; `use-dialog-box' is `let'-bound by Emacs's own Lisp
    ;; (`bookmark.el':1371, `simple.el':4311), so it is a parameter, as
    ;; this tree's convention makes every dynamically bound variable.
    ;; `use-file-dialog' is only ever read and `setq'-ed, so it is a
    ;; plain variable - and like every plain variable a user is meant to
    ;; `setq', it carries the self-assignment that stops the compiler
    ;; folding its reads (see `*enable-disabled-menus-and-buttons*' in
    ;; `(schemacs keyboard)').
    ;;----------------------------------------------------------------

    (define-custom *use-dialog-box* #t
      "Non-nil means mouse commands use dialog boxes to ask questions.\nThis applies to ‘y-or-n-p’ and ‘yes-or-no-p’ questions asked by commands\ninvoked by mouse clicks and mouse menu items.\n\nOn some platforms, file selection dialogs are also enabled if this is\nnon-nil."
      :type 'boolean
      :group 'menu
      :version "21.1")
    ;; ^ GNU Emacs's `use-dialog-box' (`fns.c:6850'): "Non-nil means
    ;; mouse commands use dialog boxes to ask questions. This applies to
    ;; `y-or-n-p' and `yes-or-no-p' questions asked by commands invoked
    ;; by mouse clicks and mouse menu items. On some platforms, file
    ;; selection dialogs are also enabled if this is non-nil."

    (define use-file-dialog #t)
    ;; ^ GNU Emacs's `use-file-dialog' (`fns.c:6859'): "Non-nil means
    ;; mouse commands use a file dialog to ask for files. This applies
    ;; to commands from menus and tool bar buttons even when they are
    ;; initiated from the keyboard. If `use-dialog-box' is nil, that
    ;; disables the use of a file dialog, regardless of the value of
    ;; this variable."
    (set! use-file-dialog use-file-dialog)

    ))