(define-library (schemacs editor fns)
  ;; This library mirrors GNU Emacs's `src/fns.c', and holds one piece
  ;; of it so far: the string comparisons `compare-strings',
  ;; `string-lessp' and `string-collate-lessp'.
  ;;
  ;; They are together here because they are the three that `ls-lisp'
  ;; asked for and the three `(schemacs editor minibuf)' had been
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
    (only (schemacs editor intervals)
          compare-string-intervals copy-intervals set-interval-object!
          set!string-intervals string-intervals)
    ;; `line-number-at-pos' is a DEFUN of this file and reads the buffer
    ;; through `point' (`PT') and the bounds, and its POSITION argument
    ;; may be a marker - the C's `MARKERP (position)' branch - so the
    ;; marker predicates come with it.
    (only (schemacs editor buffer)
          buffer-beg buffer-pt buffer-z bufferp current-buffer get-buffer
          text-editor-text)
    ;; the characters themselves - `count_lines' is a walk over them, as
    ;; the C's `display_count_lines' is a walk over the buffer's bytes.
    (only (schemacs editor buffer-text)
          buffer-text-ref buffer-text-base buffer-text-for-each)
    (only (schemacs editor marker) marker-position markerp)
    ;; `copy-sequence`'s bool-vector arm - the C's `Fcopy_sequence`
    ;; copies one, and `copy-category-table` (category.c) copies the
    ;; category sets it walks with it.
    (only (schemacs editor data)
          bool-vector? %bool-vector-copy)
    ;; `copy-sequence`'s char-table arm - `Fcopy_sequence` calls
    ;; `Fcopy_char_table` for one, and `casetab.c` copies a case table
    ;; with it.
    (only (schemacs editor chartab) char-table? copy-char-table)
    ;; the version comparison `string-version-lessp' is written over -
    ;; gnulib's `lib/filevercmp.c'.
    (only (schemacs editor filevercmp) %filevercmp)
    (only (guile) LC_COLLATE LC_CTYPE logxor)
    )

  (export compare-strings
          equal-including-properties
          mapconcat
          %substring
          buffer-hash
          concat
          vconcat
          copy-sequence
          nreverse
          nconc
          %assq
          %count-lines
          install-fns-textprop!
          line-number-at-pos
          plist-get plist-put
          string-collate-lessp
          string-equal
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
    ;; that are `textprop.c''s, and `(schemacs editor textprop)' is
    ;; *above* this library: `(schemacs editor minibuf)' imports this one
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
      ;; `(schemacs editor xdisp)' is the top of this tree's graph, so a
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
      (let* ((elements
              (cond ((list? sequence) sequence)
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
                  (if (null? tem)
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
                                  (set-cdr! tail next)
                                  (when (null? next)
                                    (vector-set! args (+ argnum 1) tail)))
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
      ;; `(schemacs editor filevercmp)'. The symbol coercion is the
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
    ;; `(schemacs editor keyboard)').
    ;;----------------------------------------------------------------

    (define *use-dialog-box* (make-parameter #t))
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