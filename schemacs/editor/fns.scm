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
    (scheme char)
    ;; the same `strcoll' glibc gives Emacs's `str_collate'.
    ;; The three procedures are `(ice-9 i18n)'s; the two LC_ constants
    ;; are `(guile)'s - `(ice-9 i18n)' does not re-export them.
    (only (ice-9 i18n) string-locale-ci<? string-locale<? make-locale)
    ;; the whole of `copy-sequence''s string arm - the C calls
    ;; `copy_intervals' and `set_string_intervals' there
    (only (schemacs editor intervals)
          copy-intervals set-interval-object! set!string-intervals
          string-intervals)
    ;; `line-number-at-pos' is a DEFUN of this file and reads the buffer
    ;; through `point' (`PT') and the bounds, and its POSITION argument
    ;; may be a marker - the C's `MARKERP (position)' branch - so the
    ;; marker predicates come with it.
    (only (schemacs editor buffer)
          buffer-beg buffer-pt buffer-z current-buffer text-editor-text)
    ;; the characters themselves - `count_lines' is a walk over them, as
    ;; the C's `display_count_lines' is a walk over the buffer's bytes.
    (only (schemacs editor buffer-text) buffer-text-ref)
    (only (schemacs editor marker) marker-position markerp)
    (only (guile) LC_COLLATE LC_CTYPE)
    )

  (export compare-strings
          concat
          copy-sequence
          count-lines
          install-fns-textprop!
          line-number-at-pos
          string-collate-lessp
          string-lessp
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
    ;; Lines, counted and numbered
    ;;----------------------------------------------------------------

    (define (count-lines ed from to)
      ;; The number of line boundaries between the positions FROM and TO -
      ;; GNU Emacs's `count_lines' (`xdisp.c:29892'), which is one call to
      ;; `display_count_lines (FROM, TO, ZV, &ignored)', the `count > 0'
      ;; branch of that walk.
      ;;
      ;; **Emacs also has a *Lisp* `count-lines' - `simple.el:1800' - and
      ;; it is a different function that answers differently.** It narrows
      ;; to START..END, counts the newlines in there, and adds one when
      ;; `START /= END' and the greater end is not at the beginning of a
      ;; line: measured, `(count-lines 1 6)' over `"a\nb\nc"' is **3**,
      ;; where this walk from 1 to 6 finds the two newlines and answers
      ;; **2**. That one is `simple.el''s, so it belongs in `simple.scm',
      ;; and it is not ported - it is written over `narrow-to-region' and
      ;; `re-search-forward', and nothing here is narrowed. So this name
      ;; is the *C helper's*, spelled as the C spells it, and it must not
      ;; be read as the Lisp function of the same spelling.
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
      ;; **ABSOLUTE cannot change the answer here, and is still taken.**
      ;; The C chooses between `BEG_BYTE' and `BEGV_BYTE' for the start
      ;; of the count, and it is the *narrowing* that makes those differ:
      ;; "If the buffer is narrowed, the return value by default counts
      ;; the lines from the beginning of the accessible portion ... But
      ;; if the second optional argument ABSOLUTE is non-nil, the value
      ;; counts the lines from the absolute start of the buffer."
      ;; Nothing is narrowed in this tree, so the two starts are the same
      ;; start. The argument is accepted rather than dropped so that the
      ;; DEFUN's shape is Emacs's - both arguments are optional there,
      ;; `0, 2, 0' - and the day narrowing arrives this becomes the C's
      ;; two-branch start.
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
                        (else (error "Wrong type argument" position)))))
        (+ 1 (count-lines ed (buffer-beg ed) pos))))

    (define (concat . args)
      ;; GNU Emacs's `concat' (fns.c): "Concatenate all the arguments and
      ;; make the result a string. The arguments may be strings, lists of
      ;; numbers, or vectors of numbers, which are turned into strings.
      ;; ... The result is a string with the text properties of the
      ;; arguments, when they have any."
      ;;
      ;; The string arm is here, with the list-of-characters arm beside
      ;; it; the vector, record and bool-vector arms are not, nothing
      ;; asking for them.
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
                          ((list? arg) (list->string arg))
                          ((vector? arg) (list->string (vector->list arg)))
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

    (define (copy-sequence arg)
      ;; GNU Emacs's `copy-sequence' (fns.c:761): "Return a copy of a
      ;; list, vector, string, char-table or record. The elements of a
      ;; list, vector or record are not copied; they are shared with the
      ;; original."
      ;;
      ;; Only the *string* arm is here, which is the one that carries
      ;; text properties: "the elements are shared" is the C's note for
      ;; the others, and Scheme's `string-copy' and `list-copy' already
      ;; are those arms. A string's properties are copied because the C
      ;; copies them - `copy_intervals' over the whole of it - and
      ;; because a copy that quietly lost them would make `substring' and
      ;; `concat' the only ways to keep them.
      ;;--------------------------------------------------------------
      (cond
       ((not (string? arg)) (error "Wrong type argument: sequencep" arg))
       (else
        (let ((val (string-copy arg))
              (ivs (string-intervals arg)))
          (if ivs
              (let ((copy (copy-intervals ivs 0 (string-length val))))
                (set-interval-object! copy val)
                (set!string-intervals val copy)))
          val))))

    (define (string-lessp s1 s2)
      ;; GNU Emacs's `string-lessp' (fns.c): "Return t if first arg
      ;; string is less than second in lexicographic order. Case is
      ;; significant." It is `compare-strings' over the whole of both,
      ;; which is how the C is written too.
      ;;--------------------------------------------------------------
      (let ((u (compare-strings s1 0 #f s2 0 #f #f)))
        (and (integer? u) (< u 0))))

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

    ))