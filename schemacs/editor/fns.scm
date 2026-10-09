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
    (only (guile) LC_COLLATE LC_CTYPE)
    )

  (export compare-strings
          concat
          copy-sequence
          install-fns-textprop!
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