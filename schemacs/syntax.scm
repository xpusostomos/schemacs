(define-library (schemacs syntax)
  ;; This library mirrors GNU Emacs's `src/syntax.c' - the syntax tables,
  ;; the character-skipping primitives, the word motions and
  ;; `parse-partial-sexp' - and, at the bottom, the `lisp/emacs-lisp/
  ;; syntax.el' half: `with-syntax-table', `syntax-ppss' and
  ;; `syntax-propertize'. **`syntax.el' has no library of its own here**
  ;; because its file name would be this one's (`syntax.sld' is
  ;; `syntax.c''s), and its functions are the same subject; the seam is
  ;; named rather than faked, as `locate-file-internal' is in
  ;; `fileio.sld'.
  ;;
  ;; What is here, in the C's order:
  ;;
  ;;   * the syntax descriptor - a fixnum whose low 8 bits are the
  ;;     class and whose high bits are the comment flags, or a cons
  ;;     `(SYNTAX . MATCHING-CHAR)' when a matching character is stored;
  ;;   * the syntax-table DEFUNs, and the standard table itself
  ;;     (`init_syntax_once');
  ;;   * `scan_words' and the word motions, the syntax table's first
  ;;     consumers. **This file's old `word-char?' (mg's `inword' -
  ;;     alphanumeric plus underscore) is gone**, because Emacs's word
  ;;     motion is `SYNTAX (c) == Sword' and nothing else: in the
  ;;     standard table `_' is symbol syntax, so `forward-word' stops at
  ;;     it where the old predicate did not;
  ;;   * `char_quoted', `forw_comment' and `scan_sexps_forward', the
  ;;     scanner `parse-partial-sexp' runs;
  ;;   * `parse-partial-sexp';
  ;;   * `syntax.el': `with-syntax-table', `syntax-ppss' and its cache,
  ;;     `syntax-ppss-flush-cache', `syntax-ppss-toplevel-pos',
  ;;     `syntax-propertize'.
  ;;
  ;; **Departures, all forced by this tree's representation:**
  ;;
  ;;   * There are no byte positions. `from_byte' and the `*_byte'
  ;;     parameters of the C collapse into the character position, which
  ;;     is what the rest of the tree uses.
  ;;   * `gl_state' is a vector rather than a C struct and its object
  ;;     slot is always the current buffer - nothing here scans a string
  ;;     through it. The interval walk, the `b_property'..`e_property'
  ;;     run, the `old_prop' invalidation rule and the
  ;;     INTERVALS_AT_ONCE lookahead are the C's, and `%syntax-entry-in'
  ;;     applies the `UPDATE_SYNTAX_TABLE' pair where the C's loops do it
  ;;     by hand, so that a lookup can never be made without it.
  ;;   * `word_boundary_p' (`syntax.c:1425') is `category.scm''s port,
  ;;     called from the word scans below: it reads `char-script-table'
  ;;     and the two category alists, which that library loads. It
  ;;     answered false always while the tree had no script table; the
  ;;     data landed with the regexp-engine pass.
  ;;   * `find_defun_start''s one-thousand-character cache
  ;;     (`search.c:585') is not carried; its `comment-use-syntax-ppss'
  ;;     shortcut is.
  ;;   * `syntax-propertize-rules' (the macro) is not carried; a mode
  ;;     can set `syntax-propertize-function' to its own function.
  ;;   * `syntax-ppss''s near-the-last-position heuristic uses a fixed
  ;;     span where the C reads its statistics vector; the vector is kept
  ;;     and read by `syntax-ppss-stats' but is not used to choose.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (guile) ash logand logior most-positive-fixnum)
    ;; The Unicode blocks' syntax, `characters.el'''s half of the
    ;; standard table - see `%standard-syntax-table'.
    (only (schemacs international characters) standard-syntax-runs)

    ;; `%skip-chars`'s BOUND is a number or a marker - `CHECK_FIXNUM_
    ;; COERCE_MARKER` (`buffer.h`) - and so are the other scans'
    ;; positions; `marker.scm` is above `buffer.scm` and below this
    ;; library, so the coercion comes from there.
    (only (schemacs marker) markerp marker-position)
    (only (schemacs buffer) current-buffer
          fetch-char set-point buffer-pt buffer-beg buffer-z
          *inhibit-read-only*
          buffer-local-value set-buffer-local-value!)
    (only (schemacs chartab)
          make-char-table char-table? char-table-p char-table-ref char-table-set
          char-table-set-range char-table-range set-char-table-range
          char-table-parent set-char-table-parent char-table-default
          char-table-subtype copy-char-table char-table-ref-and-range)
    ;; `word_boundary_p' (`category.c`), the word scans' script test.
    (only (schemacs category) word-boundary-p)
    (only (schemacs command) maybe-quit rarely-quit define-command)
    ;; `define-custom' - the three `syntax.c' variables `cus-start.el'
    ;; makes customizable (see "the variables scan_words reads" below).
    (only (schemacs custom) define-custom)
    ;; `*before-change-functions*' - `insdel.c''s hook list, which is
    ;; what this library flushes its parse-state cache from.
    (only (schemacs insdel)
          *before-change-functions* *inhibit-modification-hooks*)
    (only (schemacs intervals)
          interval-position interval-length interval-last-pos interval-plist
          update-interval next-interval previous-interval textget)
    (only (schemacs textprop)
          get-text-property put-text-property remove-text-properties
          get-char-property
          interval-of)
    )

  (export
   ;; syntax.c's DEFUNs
   syntax-table-p syntax-table standard-syntax-table copy-syntax-table
   set-syntax-table char-syntax char-syntax-in syntax-class-to-char
   matching-paren
   ;; the flag readers `internal-describe-syntax-value` (help-fns.scm)
   ;; prints - `SYNTAX_FLAGS_*` (`syntax.c:61`)
   %comstart-first? %comstart-second? %comend-first? %comend-second?
   %prefix-flag? %styleb-bit %stylec2 %nested?
   ;; `syntax-after` is `subr.el:6563`'s, not `syntax.c`'s - placed here
   ;; because it reads the `syntax-table` text property through
   ;; `get-char-property`, which is this library's neighbour.
   syntax-after
   string-to-syntax modify-syntax-entry
   parse-partial-sexp
   ;; syntax.c's class codes
   swhitespace spunct sword ssymbol sopen sclose squote sstring smath
   sescape scharquote scomment sendcomment sinherit scomment-fence
   sstring-fence smax
   ;; the syntax code letters (`syntax_spec_code', `syntax.c:1063')
   %spec-code
   ;; skip-chars
   skip-chars-forward
   skip-chars-backward
   ;; skip-syntax
   skip-syntax-forward
   skip-syntax-backward
   ;; the list scan and its motions
   scan-lists scan-sexps backward-prefix-chars forward-comment
   *forward-comment-function*
   ;; `SYNTAX (c)' at a position - the C's reader, which `search.c''s
   ;; `\_<' and `\_>' need (they are zero-width tests only a syntax
   ;; table can make, so `(schemacs search)' checks them itself).
   %setup-syntax-table %class-in
   <scan-error> make-scan-error scan-error? scan-error-message
   scan-error-start scan-error-end
   scan-error-string
   ;; word motion - the old names, now over the syntax table
   word-char?
   forward-word forward-word-strictly backward-word-strictly
   *find-word-boundary-function-table* *constrain-to-field-function*
   forward-word-position backward-word-position
   word-run-end word-run-start
   ;; syntax.el
   with-syntax-table syntax-ppss syntax-ppss-depth syntax-ppss-context
   syntax-ppss-toplevel-pos syntax-ppss-flush-cache syntax-propertize
   ppss-comment-or-string-start
   syntax-propertize-wholelines syntax-propertize-multiline
   ;; the variables
   *parse-sexp-lookup-properties* *parse-sexp-ignore-comments*
   *words-include-escapes* *comment-end-can-be-escaped*
   *open-paren-in-column-0-is-defun-start* *comment-use-syntax-ppss*
   *syntax-ppss-table* *syntax-begin-function*
   *syntax-propertize-chunk-size*
   *syntax-propertize-extend-region-functions*
   *syntax-ppss-max-span*
   syntax-propertize-chunks *internal-syntax-propertize-function*
   )

  (begin

    ;; ---------------------------------------------------------------
    ;; The syntax descriptor (`syntax.h:42-63').
    ;; ---------------------------------------------------------------
    (define swhitespace 0)
    (define spunct 1)
    (define sword 2)
    (define ssymbol 3)
    (define sopen 4)
    (define sclose 5)
    (define squote 6)
    (define sstring 7)
    (define smath 8)
    (define sescape 9)
    (define scharquote 10)
    (define scomment 11)
    (define sendcomment 12)
    (define sinherit 13)
    (define scomment-fence 14)
    (define sstring-fence 15)
    (define smax 16)

    ;; `ST_COMMENT_STYLE' / `ST_STRING_STYLE' (`syntax.c:134-138').
    (define %st-comment-style 257)
    (define %st-string-style 258)

    ;; `syntax_code_spec' (`syntax.c:1084').
    (define %syntax-code-spec " .w_()'\"$\\/<>@!|")

    ;; `syntax_spec_code' (`syntax.c:1063'): the class each letter stands
    ;; for, or #f for a letter that is not a syntax code.
    (define (%spec-code ch)
      (case ch
        ((#\space #\-) swhitespace)
        ((#\.) spunct)
        ((#\w) sword)
        ((#\_) ssymbol)
        ((#\() sopen)
        ((#\)) sclose)
        ((#\') squote)
        ((#\") sstring)
        ((#\$) smath)
        ((#\\) sescape)
        ((#\/) scharquote)
        ((#\<) scomment)
        ((#\>) sendcomment)
        ((#\@) sinherit)
        ((#\!) scomment-fence)
        ((#\|) sstring-fence)
        (else #f)))

    ;; The flags' bit positions (`syntax.c:61-110').
    (define (%comstart-first? code) (not (zero? (logand (ash code -16) 1))))
    (define (%comstart-second? code) (not (zero? (logand (ash code -17) 1))))
    (define (%comend-first? code) (not (zero? (logand (ash code -18) 1))))
    (define (%comend-second? code) (not (zero? (logand (ash code -19) 1))))
    (define (%comstartend-first? code) (not (zero? (logand code #x50000))))
    (define (%prefix-flag? code) (not (zero? (logand (ash code -20) 1))))
    (define (%styleb-bit code) (if (zero? (logand (ash code -21) 1)) 0 1))
    (define (%nested? code) (not (zero? (logand (ash code -22) 1))))
    (define (%stylec2 code) (logand (ash code -22) 2))
    (define (%comment-style code other)
      ;; `SYNTAX_FLAGS_COMMENT_STYLE' (`syntax.c:114').
      ;;--------------------------------------------------------------
      (logior (%styleb-bit code) (%stylec2 code) (%stylec2 other)))

    ;; An entry is either a fixnum or a cons `(CODE . MATCH)'.
    (define (%entry-code ent) (if (pair? ent) (car ent) ent))
    (define (%entry-match ent) (if (pair? ent) (cdr ent) #f))
    (define (%syntax-class ent) (logand (%entry-code ent) #xff))

    ;; `Vsyntax_code_object' (`syntax.c:1095').
    (define %syntax-code-objects
      (let ((v (make-vector smax #f)))
        (let loop ((i 0))
          (when (< i smax)
            (vector-set! v i (cons i #f))
            (loop (+ i 1))))
        v))

    (define (iota-range from to)
      (let loop ((i to) (acc '()))
        (if (< i from) acc (loop (- i 1) (cons i acc)))))

    ;; ---------------------------------------------------------------
    ;; The standard syntax table (`init_syntax_once', `syntax.c:3663').
    ;; ---------------------------------------------------------------
    (define (%standard-syntax-table)
      (let* ((table (make-char-table 'syntax-table
                                     (vector-ref %syntax-code-objects
                                                 swhitespace)))
             (punct (vector-ref %syntax-code-objects spunct))
             (space (vector-ref %syntax-code-objects swhitespace))
             (word (vector-ref %syntax-code-objects sword))
             (symbol (vector-ref %syntax-code-objects ssymbol)))
        ;; "Control characters should not be whitespace."
        (let loop ((i 0))
          (when (<= i (char->integer #\space))
            (char-table-set table i punct)
            (loop (+ i 1))))
        (char-table-set table 127 punct)
        ;; "Except that a few really are whitespace."
        (for-each (lambda (c) (char-table-set table c space))
                  (list 32 9 10 13 12))
        (for-each (lambda (c) (char-table-set table c word))
                  (append (iota-range (char->integer #\a) (char->integer #\z))
                          (iota-range (char->integer #\A) (char->integer #\Z))
                          (iota-range (char->integer #\0) (char->integer #\9))
                          (list (char->integer #\$) (char->integer #\%))))
        (for-each (lambda (pair)
                    (char-table-set table (car pair)
                                    (cons (list-ref pair 1) (list-ref pair 2))))
                  (list (list (char->integer #\() sopen (char->integer #\)))
                        (list (char->integer #\)) sclose (char->integer #\())
                        (list (char->integer #\[) sopen (char->integer #\]))
                        (list (char->integer #\]) sclose (char->integer #\[))
                        (list (char->integer #\{) sopen (char->integer #\}))
                        (list (char->integer #\}) sclose (char->integer #\{))))
        (char-table-set table (char->integer #\") (cons sstring #f))
        (char-table-set table (char->integer #\\) (cons sescape #f))
        ;; the ten symbol constituents, "_-+*/&|<>="
        (for-each (lambda (ch) (char-table-set table (char->integer ch) symbol))
                  (string->list "_-+*/&|<>="))
        ;; and the twelve punctuation characters ".,;:?!#@~^'`"
        (for-each (lambda (ch) (char-table-set table (char->integer ch) punct))
                  (string->list ".,;:?!#@~^'`"))
        ;; "All multibyte characters have syntax `word' by default."
        (char-table-set-range table 128 #x3FFFFF word)
        ;; ...and then `characters.el' walks the Unicode blocks:
        ;; punctuation to `.', arrows and mathematical operators to `_',
        ;; the CJK bracket pairs to `('/`)'. That is what makes `‘'
        ;; punctuation and `\u2192' a symbol in a real Emacs, and without
        ;; it every character above ASCII was `word' - see
        ;; `(schemacs international characters)'.
        (for-each
         (lambda (run)
           (let* ((start (car run))
                  (end (cadr run))
                  (class (list-ref run 2))
                  (pair (and (> (length run) 3) (list-ref run 3)))
                  (entry (cond ((eq? class 'space) space)
                               ((eq? class 'dot) punct)
                               ((eq? class 'underscore) symbol)
                               ((eq? class 'open)
                                (if pair
                                    (cons sopen pair)
                                    (vector-ref %syntax-code-objects sopen)))
                               ((eq? class 'close)
                                (if pair
                                    (cons sclose pair)
                                    (vector-ref %syntax-code-objects sclose)))
                               (else word))))
             (char-table-set-range table start end entry)))
         standard-syntax-runs)
        table))

    (define *standard-syntax-table* (%standard-syntax-table))

    (define (standard-syntax-table)
      ;; GNU Emacs's `standard-syntax-table' (`syntax.c:1010'): "Return
      ;; the standard syntax table. This is the one used for new
      ;; buffers."
      ;;--------------------------------------------------------------
      *standard-syntax-table*)

    (define (syntax-table-p obj)
      ;; GNU Emacs's `syntax-table-p' (`syntax.c:984'): "Return t if
      ;; OBJECT is a syntax table. Currently, any char-table counts as a
      ;; syntax table."
      ;;--------------------------------------------------------------
      (and (char-table? obj) (eq? (char-table-subtype obj) 'syntax-table)))

    (define (%buffer-syntax-table buffer)
      (buffer-local-value buffer 'syntax-table *standard-syntax-table*))

    (define (syntax-table)
      ;; GNU Emacs's `syntax-table' (`syntax.c:1002'): "Return the
      ;; current syntax table. This is the one specified by the current
      ;; buffer."
      ;;--------------------------------------------------------------
      (%buffer-syntax-table (current-buffer)))

    (define (set-syntax-table table)
      ;; GNU Emacs's `set-syntax-table' (`syntax.c:1045'): "Select a new
      ;; syntax table for the current buffer."
      ;;--------------------------------------------------------------
      (if (not (syntax-table-p table))
          (error "Wrong type argument: syntax-table-p" table))
      (set-buffer-local-value! (current-buffer) 'syntax-table table)
      table)

    (define (copy-syntax-table . rest)
      ;; GNU Emacs's `copy-syntax-table' (`syntax.c:1019'): "Construct a
      ;; new syntax table and return it. It is a copy of the TABLE,
      ;; which defaults to the standard syntax table."
      ;;--------------------------------------------------------------
      (let ((table (if (pair? rest) (car rest) #f)))
        (if table
            (if (not (syntax-table-p table))
                (error "Wrong type argument: syntax-table-p" table))
            (set! table *standard-syntax-table*))
        (let ((copy (copy-char-table table)))
          ;; "Only the standard syntax table should have a default
          ;; element. Other syntax tables should inherit from parents
          ;; instead."
          (set-char-table-range copy #f #f)
          (if (not (char-table-parent copy))
              (set-char-table-parent copy *standard-syntax-table*))
          copy)))

    ;; ---------------------------------------------------------------
    ;; `char-syntax', `syntax-class-to-char', `matching-paren'
    ;; (`syntax.c:1098-1154').
    ;; ---------------------------------------------------------------
    (define (%char-code c)
      (if (char? c) (char->integer c) c))

    (define (char-syntax-in table character)
      ;; The class CHARACTER has in TABLE: `char-syntax` with the table
      ;; explicit. **No Emacs counterpart** - `char_syntax` reads the
      ;; current table only - but cc-defs' `c-make-keywords-re` needs
      ;; the *mode's* table while cc-langs is being evaluated at
      ;; compile time, where there is no current buffer.
      ;;--------------------------------------------------------------
      (let* ((c (%char-code character))
             (code (%syntax-class (char-table-ref table c))))
        (string-ref %syntax-code-spec code)))

    (define (char-syntax character)
      ;; GNU Emacs's `char-syntax' (`syntax.c:1098'): "Return the syntax
      ;; code of CHARACTER, described by a character."
      ;;--------------------------------------------------------------
      (char-syntax-in (syntax-table) character))

    (define (syntax-class-to-char syntax)
      ;; GNU Emacs's `syntax-class-to-char' (`syntax.c:1124'): "Return
      ;; the syntax char of CLASS, described by an integer."
      ;;--------------------------------------------------------------
      (if (or (not (integer? syntax)) (< syntax 0) (>= syntax smax))
          (error "Args out of range" (- smax 1) syntax))
      (string-ref %syntax-code-spec syntax))

    (define (matching-paren character)
      ;; GNU Emacs's `matching-paren' (`syntax.c:1141'): "Return the
      ;; matching parenthesis of CHARACTER, or nil if none."
      ;;--------------------------------------------------------------
      (let* ((c (%char-code character))
             (ent (char-table-ref (syntax-table) c)))
        (if (memv (%syntax-class ent) (list sopen sclose))
            (%entry-match ent)
            #f)))

    ;; ---------------------------------------------------------------
    ;; `syntax-after' (`subr.el:6563').
    ;; ---------------------------------------------------------------
    (define (syntax-after pos)
      ;; GNU Emacs's `syntax-after' (`subr.el:6563'): "Return the raw
      ;; syntax descriptor for the char after POS. If POS is outside the
      ;; buffer's accessible portion, return nil."
      ;;
      ;; The text property wins - `comment-enter-backward` is its
      ;; caller here, through `comment-indent-new-line` - and the answer
      ;; is the same shape `string-to-syntax` gives, a `(CODE .
      ;; MATCHING)` cons.
      ;;--------------------------------------------------------------
      (if (or (< pos (%point-min)) (>= pos (%point-max)))
          #f
          (let ((st (if (*parse-sexp-lookup-properties*)
                        (get-char-property pos 'syntax-table)
                        #f)))
            (if (pair? st)
                st
                (char-table-ref (or st (syntax-table))
                                (%char-code (fetch-char (current-buffer) pos)))))))

    ;; ---------------------------------------------------------------
    ;; `string-to-syntax' (`syntax.c:1156') and `modify-syntax-entry'
    ;; (`syntax.c:1234').
    ;; ---------------------------------------------------------------
    (define (string-to-syntax string)
      ;; GNU Emacs's `string-to-syntax' (`syntax.c:1156'): "Convert a
      ;; syntax descriptor STRING into a raw syntax descriptor."
      ;;--------------------------------------------------------------
      (if (not (string? string))
          (error "Wrong type argument: stringp" string))
      (if (zero? (string-length string))
          (error "Invalid syntax description letter: "))
      (let ((code (%spec-code (string-ref string 0))))
        (if (not code)
            (error "Invalid syntax description letter: ~a"
                   (string-ref string 0)))
        (if (= code sinherit)
            #f
            (let* ((rest (cdr (string->list string)))
                   (match (if (pair? rest)
                              (if (char=? (car rest) #\space) #f (car rest))
                              #f))
                   (flags (if (pair? rest) (cdr rest) '())))
              (let loop ((cs flags) (val code))
                (if (null? cs)
                    (if (and (< val smax) (not match))
                        (vector-ref %syntax-code-objects val)
                        (cons val (if match (char->integer match) #f)))
                    (let ((bit (case (car cs)
                                 ((#\1) 16) ((#\2) 17) ((#\3) 18) ((#\4) 19)
                                 ((#\p) 20) ((#\b) 21) ((#\n) 22) ((#\c) 23)
                                 (else #f))))
                      (loop (cdr cs) (if bit (logior val (ash 1 bit)) val)))))))))

    (define (modify-syntax-entry c newentry . rest)
      ;; GNU Emacs's `modify-syntax-entry' (`syntax.c:1234'): "Set syntax
      ;; for character CHAR according to string NEWENTRY."
      ;;--------------------------------------------------------------
      (let ((table (if (pair? rest) (car rest) #f)))
        (if (not table) (set! table (syntax-table)))
        (if (not (syntax-table-p table))
            (error "Wrong type argument: syntax-table-p" table))
        (let ((entry (string-to-syntax newentry)))
          (if (pair? c)
              (char-table-set-range table (car c) (cdr c) entry)
              (char-table-set table (%char-code c) entry))
          #f)))

    ;; ---------------------------------------------------------------
    ;; The variables `scan_words' and the scanner read.
    ;;
    ;; `cus-start.el' is the bridge that makes a C `DEFVAR' customizable
    ;; in Emacs: an entry there gives the variable a `standard-value',
    ;; which is what `custom-variable-p' and Customize read
    ;; (`(custom-variable-p 'words-include-escapes)' is `(nil)' -
    ;; non-nil - in Emacs 31.1). Three of the six below are listed
    ;; (`cus-start.el:621-624', `syntax.c''s three) and are
    ;; `define-custom' here; the other three are not and stay plain
    ;; parameters. **That is the rule for every C variable this tree
    ;; ports: check `cus-start.el' for its name.**
    ;; ---------------------------------------------------------------
    (define-custom *words-include-escapes* #f
      "Non-nil means `forward-word', etc., should treat escape chars part of words."
      :type 'boolean
      :group 'editing-basics)
    ;; **Departure**: Emacs's `parse_sexp_lookup_properties' starts nil
    ;; (`DEFVAR_BOOL', `syntax.c:3772') and `font-lock' and
    ;; `run-mode-hooks' set it buffer-locally (`font-lock.el:1531',
    ;; `subr.el:2779'); ours starts #t because nothing here sets it that
    ;; way yet - see DEPARTURES.md.
    (define *parse-sexp-lookup-properties* (make-parameter #t))
    ;; **Departure**: Emacs's `standard-value' here is nil
    ;; (`cus-start.el:621'); ours is #t, because the modes that set it
    ;; buffer-locally (`prog-mode.el:401', `scheme.el:185') are ported
    ;; but no cc-mode exists yet - see DEPARTURES.md.
    (define-custom *parse-sexp-ignore-comments* #t
      "Non-nil means `forward-sexp', etc., should treat comments as whitespace."
      :type 'boolean
      :group 'editing-basics)
    (define *comment-end-can-be-escaped* (make-parameter #f))
    (define-custom *open-paren-in-column-0-is-defun-start* #t
      "Non-nil means an open paren in column 0 denotes the start of a defun."
      :type 'boolean
      :group 'editing-basics
      :version "21.1")
    (define *comment-use-syntax-ppss* (make-parameter #t))

    ;; ---------------------------------------------------------------
    ;; `gl_state' (`syntax.h:66'), `SETUP_SYNTAX_TABLE' (`syntax.c:250')
    ;; and `update_syntax_table' (`syntax.c:336').
    ;;
    ;; **This is the syntax-table cache, and it is what makes a scan
    ;; linear.** `SYNTAX(c)' reads the `syntax-table' text property,
    ;; which belongs to an *interval* and not to a character: the C keeps
    ;; the interval the last lookup landed in and the run
    ;; `b_property'..`e_property' over which its table applies, answers
    ;; every character inside the run from that cache, and walks to the
    ;; neighbouring interval (`update_interval') when the scan crosses a
    ;; boundary. A scan of a whole buffer therefore costs one `textget'
    ;; per interval rather than one property walk per character.
    ;;
    ;; What stood here before was a forward-only run cache built with
    ;; `next-single-property-change', and it was wrong in both
    ;; directions. `next-single-property-change' walks intervals forward
    ;; until the *named* property changes - so once font-lock had put
    ;; `face' runs on a buffer whose text carried no `syntax-table'
    ;; property, every lookup walked to the end of the buffer. And a
    ;; backward scan never hit the cache at all, because the cached run
    ;; began at the position just asked about, so the next character
    ;; back was always a miss. `C-M-b' from the end of a 257 KB Scheme
    ;; file cost 144 s with font-lock on; with Emacs's cache below it is
    ;; what Emacs's is.
    ;;--------------------------------------------------------------
    (define %uninitialized-interval (list 'uninitialized-interval))
    (define %intervals-at-once 30)          ; INTERVALS_AT_ONCE

    ;; The fields of `struct gl_state_s' (`syntax.h:66'), in its order.
    ;; Slot 0 is the object being scanned, which is the current buffer
    ;; here: Emacs's Qnil object means exactly that, and nothing scans a
    ;; string through this.
    (define %gl-start 1)                    ; where the object begins
    (define %gl-stop 2)                     ; one past its end
    (define %gl-use-global 3)               ; global_code, or the table?
    (define %gl-global-code 4)
    (define %gl-current-table 5)
    (define %gl-old-prop 6)
    (define %gl-b-property 7)               ; first position the table is
    (define %gl-e-property 8)               ;   valid at, and one past
    (define %gl-forward-i 9)                ; where to look on the way
    (define %gl-backward-i 10)              ;   forward, and backward
    (define %gl-truncated 11)               ; e_property_truncated

    (define %gl-state
      (vector #f 1 1 #f #f *standard-syntax-table* #f 1 1
              %uninitialized-interval %uninitialized-interval #f))

    (define (%point-max) (buffer-z (current-buffer)))
    ;; `(point-min)`/`(point-max)` are `editfns.scm`'s, and that library
    ;; imports this one - so the two positions are read here.
    (define (%point-min) (buffer-beg (current-buffer)))

    (define %syntax-propertize-done 0)
    ;; ^ `syntax-propertize--done` cached for the scan loops: the C reads
    ;; its own global on every `UPDATE_SYNTAX_TABLE_FORWARD`
    ;; (`syntax.c:516`), and a `buffer-local-value` per character would
    ;; be the same check at ten times the cost. `%setup-syntax-table`
    ;; re-reads it from the buffer, and `syntax-propertize` keeps it.

    (define *internal-syntax-propertize-function* (make-parameter #f))
    ;; ^ How `internal--syntax-propertize' (`syntax.el:481') runs: a
    ;; procedure of one thunk that preserves the match data around it.
    ;; Emacs spells that `save-match-data', and **`save-match-data' is
    ;; the search library's, which is *above* this one** - so the save is
    ;; a seam and `(schemacs search)' installs it. Without it (a
    ;; scan outside any search) the identity is right.

    (define (%internal-syntax-propertize charpos)
      ;; `internal--syntax-propertize' (`syntax.el:481'), "called
      ;; directly from C" by `parse_sexp_propertize'. The `save-match-data'
      ;; is what makes propertizing safe *from inside a regexp match*:
      ;; the mode's function runs searches of its own, and without the
      ;; save they overwrite the match data of the match being attempted -
      ;; which showed up as font-lock's "No match %s in highlight" on a
      ;; file whose propertize function had not run yet.
      ;;--------------------------------------------------------------
      (let ((thunk (lambda ()
                     (syntax-propertize
                      (min (+ syntax-propertize-chunks charpos) (%point-max))))))
        (if (*internal-syntax-propertize-function*)
            ((*internal-syntax-propertize-function*) thunk)
            (thunk))))

    (define (%parse-sexp-propertize charpos)
      ;; `parse_sexp_propertize' (`syntax.c:480'): "Ensure that the
      ;; `syntax-table' properties are applied up to CHARPOS, then set
      ;; the syntax table up again for it." A scan that crosses into
      ;; unpropertized text has to stop and let the mode's function run,
      ;; because the properties it sets change what the rest of the scan
      ;; sees.
      ;;--------------------------------------------------------------
      (let ((zv (%point-max)))
        (if (and (<= %syntax-propertize-done charpos)
                 (< %syntax-propertize-done zv))
            (begin
              (%internal-syntax-propertize (min zv (+ 1 charpos)))
              (%setup-syntax-table))
            (when (> (vector-ref %gl-state %gl-e-property)
                     %syntax-propertize-done)
              ;; "e_property_truncated" - the run the cache believes in
              ;; extends past what has been propertized, so it is a
              ;; belief no longer: the interval cache has to be reset
              ;; before it is trusted again (`syntax.c:497').
              (vector-set! %gl-state %gl-e-property %syntax-propertize-done)
              (vector-set! %gl-state %gl-truncated #t))))
      #f)

    (define (%setup-syntax-table)
      ;; `SETUP_SYNTAX_TABLE' (`syntax.c:250'): "This should be called
      ;; with FROM at the start of forward search, or after the last
      ;; position of the backward search." The C then primes the cache for
      ;; FROM in the direction COUNT; here the first lookup primes it (see
      ;; `%syntax-entry-in'), which is why this takes no arguments.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (vector-set! %gl-state 0 ed)
        (vector-set! %gl-state %gl-start (buffer-beg ed))
        (vector-set! %gl-state %gl-stop (+ (buffer-z ed) 1))
        (vector-set! %gl-state %gl-use-global #f)
        (vector-set! %gl-state %gl-current-table (%buffer-syntax-table ed))
        (vector-set! %gl-state %gl-old-prop #f)
        (vector-set! %gl-state %gl-forward-i %uninitialized-interval)
        (vector-set! %gl-state %gl-backward-i %uninitialized-interval)
        (set! %syntax-propertize-done
              (buffer-local-value ed 'syntax-propertize--done 0))
        (vector-set! %gl-state %gl-truncated #f))
      #f)

    (define (%update-syntax-table pos count)
      ;; `update_syntax_table' (`syntax.c:336'): "Update gl_state to an
      ;; appropriate interval which contains CHARPOS. The sign of COUNT
      ;; gives the relative position of CHARPOS wrt the previously valid
      ;; interval." The interval walk is `update_interval''s: one step
      ;; per interval crossed, so a scan of a whole buffer costs one
      ;; `textget' per interval rather than one per character.
      ;;--------------------------------------------------------------
      (let ((invalidate #t)
            (i #f))
        ;; The C's opening `if': first time, find the interval POS is in;
        ;; otherwise walk from the interval the last lookup cached.
        (if (eq? (vector-ref %gl-state %gl-backward-i) %uninitialized-interval)
            (begin
              (vector-set! %gl-state %gl-old-prop #f)
              (set! i (interval-of (current-buffer) pos))
              (vector-set! %gl-state %gl-forward-i i)
              (vector-set! %gl-state %gl-backward-i i)
              (set! invalidate #f)
              (if i
                  (begin
                    (vector-set! %gl-state %gl-b-property (interval-position i))
                    (vector-set! %gl-state %gl-e-property (interval-last-pos i)))
                  (begin
                    (vector-set! %gl-state %gl-b-property
                                 (vector-ref %gl-state %gl-start))
                    (vector-set! %gl-state %gl-e-property
                                 (vector-ref %gl-state %gl-stop)))))
            (begin
              ;; "We are guaranteed to be called with CHARPOS either in i,
              ;; or further off."
              (set! i (if (> count 0)
                          (vector-ref %gl-state %gl-forward-i)
                          (vector-ref %gl-state %gl-backward-i)))
              (when (not i)
                (error "Error in syntax_table logic for to-the-end intervals"))
              (when (< pos (interval-position i))          ; move left
                (when (> count 0)
                  (error "Error in syntax_table logic for intervals <-"))
                (set! i (update-interval i pos))
                (when (not (= (interval-last-pos i)
                              (vector-ref %gl-state %gl-b-property)))
                  (set! invalidate #f)
                  (vector-set! %gl-state %gl-forward-i i)
                  (vector-set! %gl-state %gl-e-property (interval-last-pos i))))
              (when (and i (>= pos (interval-last-pos i)))  ; move right
                (when (< count 0)
                  (error "Error in syntax_table logic for intervals ->"))
                (set! i (update-interval i pos))
                (when (not (= (interval-position i)
                              (vector-ref %gl-state %gl-e-property)))
                  (set! invalidate #f)
                  (vector-set! %gl-state %gl-backward-i i)
                  (vector-set! %gl-state %gl-b-property (interval-position i))))))
        (when i
          (let ((tmp-table (textget (interval-plist i) 'syntax-table)))
            ;; "Need to invalidate?" - only when the interval we landed in
            ;; is not adjacent to the cached run with the same table.
            (when invalidate
              (set! invalidate
                    (not (eq? tmp-table (vector-ref %gl-state %gl-old-prop)))))
            ;; "Did not get to adjacent interval with the same table =>
            ;; invalidate the old range."
            (when invalidate
              (if (> count 0)
                  (begin
                    (vector-set! %gl-state %gl-backward-i i)
                    (vector-set! %gl-state %gl-b-property (interval-position i)))
                  (begin
                    (vector-set! %gl-state %gl-forward-i i)
                    (vector-set! %gl-state %gl-e-property (interval-last-pos i)))))
            (when (not (eq? tmp-table (vector-ref %gl-state %gl-old-prop)))
              (vector-set! %gl-state %gl-current-table tmp-table)
              (vector-set! %gl-state %gl-old-prop tmp-table)
              (cond
               ((syntax-table-p tmp-table)
                (vector-set! %gl-state %gl-use-global #f))
               ((pair? tmp-table)
                (vector-set! %gl-state %gl-use-global #t)
                (vector-set! %gl-state %gl-global-code tmp-table))
               (else
                (vector-set! %gl-state %gl-use-global #f)
                (vector-set! %gl-state %gl-current-table
                             (%buffer-syntax-table (current-buffer))))))
            ;; The C's walk over the adjacent intervals the same table
            ;; covers, INTERVALS_AT_ONCE at a time; a NULL answer means
            ;; "this property goes to the end of the object".
            (let loop ((j i) (cnt 0))
              (cond
               ((not j)
                (if (> count 0)
                    (begin
                      (vector-set! %gl-state %gl-e-property
                                   (vector-ref %gl-state %gl-stop))
                      (vector-set! %gl-state %gl-forward-i #f))
                    (vector-set! %gl-state %gl-b-property
                                 (vector-ref %gl-state %gl-start))))
               ((and (> cnt 0)
                     (not (eq? tmp-table
                               (textget (interval-plist j) 'syntax-table))))
                (if (> count 0)
                    (begin
                      (vector-set! %gl-state %gl-e-property (interval-position j))
                      (vector-set! %gl-state %gl-forward-i j))
                    (begin
                      (vector-set! %gl-state %gl-b-property
                                   (+ (interval-position j) (interval-length j)))
                      (vector-set! %gl-state %gl-backward-i j))))
               ((= cnt %intervals-at-once)
                (if (> count 0)
                    (begin
                      ;; "e_property at EOB is not set to ZV but to ZV+1,
                      ;; so that we can do INC(from);
                      ;; UPDATE_SYNTAX_TABLE_FORWARD without having to
                      ;; check eob between the two."
                      (vector-set! %gl-state %gl-e-property
                                   (+ (interval-position j) (interval-length j)
                                      (if (next-interval j) 0 1)))
                      (vector-set! %gl-state %gl-forward-i j))
                    (begin
                      (vector-set! %gl-state %gl-b-property (interval-position j))
                      (vector-set! %gl-state %gl-backward-i j))))
               (else
                (loop (if (> count 0) (next-interval j) (previous-interval j))
                      (+ cnt 1))))))))
      #f)

    (define (%syntax-entry-in ed pos c)
      ;; `SYNTAX(c)' at POS - the C's `syntax_property_entry (c, 1)'
      ;; (`syntax.h:97'), which answers `gl_state.global_code' when the
      ;; property is a raw descriptor and the table's entry otherwise.
      ;; The `UPDATE_SYNTAX_TABLE' pair (`syntax.h:210') happens here, at
      ;; the one place every character read goes through, rather than at
      ;; every move in every loop.
      ;;--------------------------------------------------------------
      (if (and (*parse-sexp-lookup-properties*) (eq? ed (current-buffer)))
          (begin
            (if (eq? (vector-ref %gl-state %gl-backward-i)
                     %uninitialized-interval)
                (%update-syntax-table pos 1)
                (begin
                  (when (< pos (vector-ref %gl-state %gl-b-property))
                    (%update-syntax-table pos -1))
                  (when (>= pos (vector-ref %gl-state %gl-e-property))
                    (if (vector-ref %gl-state %gl-truncated)
                        ;; The cached run was truncated to
                        ;; `syntax-propertize--done', so the intervals it
                        ;; names may not be the ones the buffer has any
                        ;; more - and a walk off the last one says "Error
                        ;; in syntax_table logic for to-the-end
                        ;; intervals". Start the cache again.
                        (begin (%setup-syntax-table)
                               (%update-syntax-table pos 1))
                        (%update-syntax-table pos 1)))))
            ;; `update_syntax_table_forward`'s tail (`syntax.c:516'): a
            ;; run that reaches past what has been propertized has to be
            ;; propertized now. **Checked on every character**, as the
            ;; C's `UPDATE_SYNTAX_TABLE_FORWARD' does - checking it only
            ;; when the run changes left a buffer half propertized, since
            ;; the last run reaches to ZV and no change is ever seen
            ;; again (`vtable.el' line 208 indented 8 where Emacs says
            ;; 6).
            (when (> (vector-ref %gl-state %gl-e-property)
                     %syntax-propertize-done)
              (%parse-sexp-propertize pos))
            (if (vector-ref %gl-state %gl-use-global)
                (vector-ref %gl-state %gl-global-code)
                (char-table-ref (vector-ref %gl-state %gl-current-table) c)))
          (char-table-ref (%buffer-syntax-table ed) c)))

    (define (%code-in ed pos c)
      (%entry-code (%syntax-entry-in ed pos c)))

    (define (%class-in ed pos c)
      (logand (%code-in ed pos c) #xff))

    (define (%word-boundary? c1 c2)
      ;; `word_boundary_p' (`syntax.c:1425'): "Return true if there is a
      ;; word boundary between two word-constituent characters C1 and C2
      ;; if they appear in this order."
      ;;
      ;; `category.scm' ports the function whole, script table and the
      ;; two category alists included. When the first word-motion port
      ;; was written the tree had no `char-script-table' and this
      ;; answered false always; the data has since landed, so the real
      ;; test is made.
      ;;--------------------------------------------------------------
      (word-boundary-p c1 c2))

    (define *find-word-boundary-function-table* (make-parameter (make-char-table #f)))
    ;; ^ `Vfind_word_boundary_function_table' (`syntax.c:3799', `:3814'):
    ;; "Table of functions that decide word boundaries. It maps a
    ;; character to a function..." The C makes it an empty char-table
    ;; (`Fmake_char_table (Qnil, Qnil)') and calls an entry when
    ;; `Ffboundp' of it is non-nil. An entry here is a *procedure*,
    ;; because a Lisp-1 has no symbol-to-function indirection for
    ;; `fboundp' to be asked. A parameter, because `forward-word-strictly'
    ;; `let'-binds it, and the convention says a Elisp `let' target is a
    ;; parameter - the stars are this tree's, not Emacs's.

    (define (%word-boundary-function ch)
      ;; `CHAR_TABLE_REF (Vfind_word_boundary_function_table, CH)'
      ;; followed by the C's `Ffboundp' test.
      (let ((f (char-table-ref (*find-word-boundary-function-table*) ch)))
        (and (procedure? f) f)))

    (define (%scan-words ed from count)
      ;; `scan_words' (`syntax.c:1454'): "Return the position across
      ;; COUNT words from FROM. If that many words cannot be found
      ;; before the end of the buffer, return 0. COUNT negative means
      ;; scan backward and stop at word beginning."
      ;;--------------------------------------------------------------
      ;; `SETUP_SYNTAX_TABLE (from, ...)' (`:1472') - the word motion is
      ;; a `SYNTAX (c)' reader like every other scan, so it primes the
      ;; syntax-table cache before it starts.
      (%setup-syntax-table)
      (let ((beg (buffer-beg ed))
            (end (buffer-z ed))
            (escapes (*words-include-escapes*)))
        (define (word-class? code)
          (or (= code sword)
              (and escapes (memv code (list sescape scharquote)))))
        (define (char-at p) (char->integer (fetch-char ed p)))
        (cond
         ((> count 0)
          (let loop ((from from) (count count))
            ;; Scan to the start of the next word; CH0 is that character
            ;; and FROM the position after it, in the C's terms. 0 is
            ;; the C's "ran out of buffer".
            (define (scan-to-word i)
              (cond ((= i end) 0)
                    ((word-class? (%class-in ed i (char-at i)))
                     (start-run (char-at i) (+ i 1)))
                    (else (rarely-quit i) (scan-to-word (+ i 1)))))
            (define (start-run ch0 from1)
              (let ((func (%word-boundary-function ch0)))
                (if func
                    ;; The boundary table has an entry for CH0: it
                    ;; decides where the word ends (`syntax.c:1494').
                    (let ((pos (func (- from1 1) end)))
                      (if (and (integer? pos) (< from1 pos) (<= pos end))
                          (loop pos (- count 1))
                          (loop from1 (- count 1))))
                    (let run ((p from1) (ch0 ch0))
                      (if (or (= p end)
                              (let* ((d (char-at p))
                                     (dc (%class-in ed p d)))
                                (or (not (word-class? dc))
                                    (%word-boundary? ch0 d))))
                          (loop p (- count 1))
                          (begin (rarely-quit p)
                                 (run (+ p 1) (char-at p))))))))
            (cond ((<= count 0) from)
                  ((= from end) 0)
                  (else (scan-to-word from)))))
         ((< count 0)
          (let loop ((from from) (count count))
            ;; Scan backward to the last character of the previous word;
            ;; CH1 is that character and I its position (the C's FROM).
            ;; The boundary test is directional and takes its two
            ;; characters in text order - (CH0, CH1).
            (define (scan-to-word i)
              (cond ((< i beg) 0)
                    ((word-class? (%class-in ed i (char-at i)))
                     (start-run i (char-at i)))
                    (else (rarely-quit i) (scan-to-word (- i 1)))))
            (define (start-run i ch1)
              (let ((func (%word-boundary-function ch1)))
                (if func
                    (let ((pos (func i beg)))
                      (if (and (integer? pos) (<= beg pos) (< pos i))
                          (loop pos (+ count 1))
                          (loop i (+ count 1))))
                    (let run ((p (- i 1)) (ch1 ch1))
                      (if (or (< p beg)
                              (let* ((d (char-at p))
                                     (dc (%class-in ed p d)))
                                (or (not (word-class? dc))
                                    (%word-boundary? d ch1))))
                          (loop (+ p 1) (+ count 1))
                          (begin (rarely-quit p)
                                 (run (- p 1) (char-at p))))))))
            (cond ((>= count 0) from)
                  ((= from beg) 0)
                  (else (scan-to-word (- from 1))))))
         (else from))))

    (define (word-char? c)
      ;; The word-constituent predicate - `SYNTAX (c) == Sword' from the
      ;; current syntax table, as Emacs decides it.
      ;;--------------------------------------------------------------
      (= (%syntax-class (char-table-ref (syntax-table) (%char-code c)))
         sword))

    ;; ---------------------------------------------------------------
    ;; `forward-word' (`syntax.c:1581')
    ;; ---------------------------------------------------------------
    ;;
    ;; The C DEFUN calls `constrain_to_field', which is `editfns.c''s
    ;; and lives above this library, so it arrives through a seam that
    ;; `editfns.scm' installs as it loads - the shape every upward reach
    ;; in this tree takes (`*barf-if-buffer-read-only-function*' and its
    ;; kind). Nothing here can load without the installer in practice;
    ;; an uninstalled seam is an error that names it rather than a
    ;; silent `#f'.
    (define *constrain-to-field-function* (make-parameter #f))

    (define-command (forward-word . rest)
      "Move point forward ARG words (backward if ARG is negative).
If ARG is omitted or nil, move point forward one word.
Normally returns t.
If an edge of the buffer or a field boundary is reached, point is
left there and the function returns nil.  Field boundaries are not
noticed if `inhibit-field-text-motion' is non-nil.

The word boundaries are normally determined by the buffer's syntax
table and character script (according to `char-script-table'), but
`find-word-boundary-function-table', such as set up by `subword-mode',
can change that.  If a Lisp program needs to move by words determined
strictly by the syntax table, it should use `forward-word-strictly'
instead.  See Info node `(elisp) Word Motion' for details."
      (interactive "^p")
      (let* ((arg (if (pair? rest) (car rest) #f))
             (arg (if arg arg 1)))
        (unless (integer? arg)
          (error "Wrong type argument: integerp, ~s" arg))
        (let* ((ed (current-buffer))
               (orig (%scan-words ed (buffer-pt ed) arg))
               (val (if (= orig 0)
                        (if (> arg 0) (buffer-z ed) (buffer-beg ed))
                        orig))
               (constrain (*constrain-to-field-function*))
               (val (if (procedure? constrain)
                        (constrain val (buffer-pt ed) #f #f #f)
                        (error "`constrain-to-field' is not installed: the `constrain-to-field' seam of `syntax.scm' is set by `editfns.scm'"))))
          (set-point ed val)
          (if (= val orig) #t #f))))

    ;; `forward-word-strictly' and `backward-word-strictly'
    ;; (`subr.el:6593', `:6609'). **Placement departure**: `subr.scm'
    ;; is below this library and cannot call `forward-word', and these
    ;; are the two functions that bind `find-word-boundary-function-
    ;; table' to an empty table, which is exactly this library's
    ;; variable. They are the reason a `subword-mode' style splitter
    ;; cannot influence a mode that asks for strict word motion.
    (define word-move-empty-char-table #f)
    ;; ^ `subr.el''s `(defvar word-move-empty-char-table nil)': made on
    ;; first use. A plain variable (nothing `let'-binds it).

    (define (forward-word-strictly . rest)
      "Move point forward ARG words (backward if ARG is negative).
If ARG is omitted or nil, move point forward one word.
Normally returns t.
If an edge of the buffer or a field boundary is reached, point is
left there and the function returns nil.  Field boundaries are not
noticed if `inhibit-field-text-motion' is non-nil.

This function is like `forward-word', but it is not affected
by `find-word-boundary-function-table'.  It is also not interactive."
      (parameterize ((*find-word-boundary-function-table*
                      (if (char-table-p word-move-empty-char-table)
                          word-move-empty-char-table
                          (begin
                            (set! word-move-empty-char-table (make-char-table #f))
                            word-move-empty-char-table))))
        (forward-word (let ((arg (if (pair? rest) (car rest) #f)))
                        (if arg arg 1)))))

    (define (backward-word-strictly . rest)
      "Move backward until encountering the beginning of a word.
With argument ARG, do this that many times.
If ARG is omitted or nil, move point backward one word.

This function is like `backward-word', but it is not affected
by `find-word-boundary-function-table'.  It is also not interactive."
      (parameterize ((*find-word-boundary-function-table*
                      (if (char-table-p word-move-empty-char-table)
                          word-move-empty-char-table
                          (begin
                            (set! word-move-empty-char-table (make-char-table #f))
                            word-move-empty-char-table))))
        (forward-word (- (let ((arg (if (pair? rest) (car rest) #f)))
                           (if arg arg 1))))))

    (define (forward-word-position ed)
      ;; The answer as a position: `0' is `scan_words''s failure, and
      ;; the motion stops at the edge, so the edge is the position.
      (let ((p (%scan-words ed (buffer-pt ed) 1)))
        (if (= p 0) (buffer-z ed) p)))

    (define (backward-word-position ed)
      (let ((p (%scan-words ed (buffer-pt ed) -1)))
        (if (= p 0) (buffer-beg ed) p)))

    (define (word-run-end ed count)
      (let loop ((i 0) (pos (buffer-pt ed)))
        (if (>= i count)
            pos
            (let ((next (%scan-words ed pos 1)))
              (if (or (= next 0) (= next pos))
                  pos
                  (loop (+ 1 i) next))))))

    (define (word-run-start ed count)
      (let loop ((i 0) (pos (buffer-pt ed)))
        (if (>= i count)
            pos
            (let ((prev (%scan-words ed pos -1)))
              (if (= prev 0)
                  pos
                  (if (= prev pos)
                      prev
                      (loop (+ 1 i) prev)))))))

    ;; ---------------------------------------------------------------
    ;; `skip-chars-forward' / `skip-chars-backward' (`syntax.c:1618')
    ;; over `skip_chars' (`:1660').
    ;;
    ;; The C builds a `fastmap' over ASCII and a `char_ranges' vector
    ;; over the rest, then walks. This is the same test one character at
    ;; a time - the maps are an optimisation, and the answers are the
    ;; same.
    ;; ---------------------------------------------------------------
    (define (%wctype-member? name c)
      ;; `[:NAME:]' in a skip set - `re_wctype_parse' and
      ;; `re_iswctype' (`regex-emacs.c'). ASCII answers are the C's
      ;; macros; the rest are Guile's character predicates, which is
      ;; this tree's answer for the wide-character tables.
      ;;--------------------------------------------------------------
      (define (ascii lo hi) (and (>= c lo) (<= c hi)))
      (define (wide pred) (and (<= c #x10FFFF) (pred (integer->char c))))
      (case name
        ((alnum) (or (ascii (char->integer #\0) (char->integer #\9))
                     (ascii (char->integer #\A) (char->integer #\Z))
                     (ascii (char->integer #\a) (char->integer #\z))
                     (wide char-alphabetic?)))
        ((alpha) (or (ascii (char->integer #\A) (char->integer #\Z))
                     (ascii (char->integer #\a) (char->integer #\z))
                     (wide char-alphabetic?)))
        ((blank) (or (= c 32) (= c 9) (wide char-whitespace?)))
        ((cntrl) (or (and (>= c 0) (< c 32)) (= c 127)))
        ((digit) (or (ascii (char->integer #\0) (char->integer #\9))
                     (wide char-numeric?)))
        ((graph) (and (> c 32) (< c 127)))
        ((lower) (or (ascii (char->integer #\a) (char->integer #\z))
                     (wide char-lower-case?)))
        ((print) (and (>= c 32) (< c 127)))
        ((punct) (and (> c 32) (< c 127)
                      (not (ascii (char->integer #\0) (char->integer #\9)))
                      (not (ascii (char->integer #\A) (char->integer #\Z)))
                      (not (ascii (char->integer #\a) (char->integer #\z)))))
        ((space) (or (= c 32) (= c 9) (= c 10) (= c 13) (= c 12) (= c 11)
                     (wide char-whitespace?)))
        ((upper) (or (ascii (char->integer #\A) (char->integer #\Z))
                     (wide char-upper-case?)))
        ((xdigit) (or (ascii (char->integer #\0) (char->integer #\9))
                      (ascii (char->integer #\A) (char->integer #\F))
                      (ascii (char->integer #\a) (char->integer #\f))))
        ((ascii) (< c 128))
        ((nonascii) (>= c 128))
        ((unibyte) (<= c #xFF))
        ((multibyte) (> c #xFF))
        ((word) (or (ascii (char->integer #\0) (char->integer #\9))
                    (ascii (char->integer #\A) (char->integer #\Z))
                    (ascii (char->integer #\a) (char->integer #\z))
                    (= c (char->integer #\_))
                    (wide char-alphabetic?)))
        (else #f)))

    (define (%skip-chars-set set)
      ;; The C's `fastmap' and `char_ranges': the set as ranges and
      ;; named classes, with the `^' negation.
      ;;--------------------------------------------------------------
      (let* ((n (string-length set))
             (negate (and (> n 0) (char=? (string-ref set 0) #\^)))
             (items '()))
        (let loop ((i (if negate 1 0)) (pending #f) (lo #f))
          ;; PENDING is the character that could start a range; LO is
          ;; where a "-" range would begin.
          (define (emit c)
            ;; A one-character range, as integers - the member test
            ;; compares code points.
            (set! items (cons (cons (char->integer c) (char->integer c))
                              items)))
          (if (>= i n)
              (begin
                (when pending (emit pending))
                (set! items (reverse items))
                (values negate items))
              (let ((ch (string-ref set i)))
                (cond
                 ((and (char=? ch #\[) (< (+ i 1) n)
                       (char=? (string-ref set (+ i 1)) #\:))
                  (let scan ((j (+ i 2)))
                    (cond
                     ((>= (+ j 1) n) (loop (+ i 1) pending lo))
                     ((and (char=? (string-ref set j) #\:)
                           (char=? (string-ref set (+ j 1)) #\]))
                      (let ((name (string->symbol
                                   (substring set (+ i 2) j))))
                        (set! items (cons name items))
                        (loop (+ j 2) pending lo)))
                     (else (scan (+ j 1))))))
                 ((char=? ch #\\)
                  (if (< (+ i 1) n)
                      (begin (set! items (cons (cons (char->integer (string-ref set (+ i 1)))
                                                     (char->integer (string-ref set (+ i 1)))) items))
                             (loop (+ i 2) #f lo))
                      (loop (+ i 1) pending lo)))
                 ((and (char=? ch #\-) pending (< (+ i 1) n))
                  (let ((hi (string-ref set (+ i 1))))
                    (set! items (cons (cons (char->integer pending)
                                            (char->integer hi)) items))
                    (loop (+ i 2) #f #f)))
                 (else
                  (when pending (emit pending))
                  (loop (+ i 1) ch lo))))))))

    (define (%skip-chars-member? c items)
      (let loop ((rest items))
        (cond ((null? rest) #f)
              ((symbol? (car rest))
               (or (%wctype-member? (car rest) c) (loop (cdr rest))))
              ((and (>= c (car (car rest))) (<= c (cdr (car rest)))) #t)
              (else (loop (cdr rest))))))

    (define (%coerce-marker-pos x)
      ;; `CHECK_FIXNUM_COERCE_MARKER` (`buffer.h`): a marker is replaced
      ;; by its charpos - the C does not ask which buffer it is in - and
      ;; anything else must be a fixnum.
      (cond ((markerp x) (marker-position x))
            ((integer? x) x)
            (else (error "Wrong type argument: integer-or-marker-p" x))))

    (define (%skip-chars forwardp set lim)
      (let* ((ed (current-buffer))
             (beg (buffer-beg ed))
             (end (buffer-z ed))
             (limit (min (max (cond ((not lim) (if forwardp end beg))
                                    (else (%coerce-marker-pos lim)))
                              beg)
                         end))
             (start (buffer-pt ed)))
        (call-with-values (lambda () (%skip-chars-set set))
          (lambda (negate items)
            (if (if forwardp (>= start limit) (<= start limit))
                (begin (set-point ed start) 0)
                (let loop ((pos start))
                  (let* ((p (if forwardp pos (- pos 1)))
                         (inside? (%skip-chars-member?
                                   (char->integer (fetch-char ed p)) items)))
                    (if (if negate (not inside?) inside?)
                        (let ((next (if forwardp (+ pos 1) (- pos 1))))
                          (rarely-quit next)
                          (if (if forwardp (>= next limit) (<= next limit))
                              (begin (set-point ed next) (- next start))
                              (loop next)))
                        (begin (set-point ed pos) (- pos start))))))))))

    (define (skip-chars-forward set . rest)
      ;; GNU Emacs's `skip-chars-forward' (`syntax.c:1618'): "Move point
      ;; forward across chars in specified CHAR-SET."
      ;;--------------------------------------------------------------
      (%skip-chars #t set (if (pair? rest) (car rest) #f)))

    (define (skip-chars-backward set . rest)
      ;; GNU Emacs's `skip-chars-backward' (`syntax.c:1630'): "Move
      ;; point backward across chars in specified CHAR-SET."
      ;;--------------------------------------------------------------
      (%skip-chars #f set (if (pair? rest) (car rest) #f)))

    ;; ---------------------------------------------------------------
    ;; `char_quoted' (`syntax.c:533').
    ;; ---------------------------------------------------------------
    (define (%char-quoted ed pos)
      (let ((beg (buffer-beg ed)))
        (let loop ((i pos) (quoted #f))
          (if (<= i beg)
              quoted
              (let* ((p (- i 1))
                     (c (char->integer (fetch-char ed p)))
                     (code (%class-in ed p c)))
                (if (memv code (list sescape scharquote))
                    (loop p (not quoted))
                    quoted))))))

    ;; ---------------------------------------------------------------
    ;; `find_defun_start' (`syntax.c:585'), `prev_char_comend_first'
    ;; (`:679') and `back_comment' (`:695') - the backward half of the
    ;; comment machinery `scan_lists' below scans with.
    ;; ---------------------------------------------------------------
    (define (%prev-char-comend-first? ed pos)
      ;; `prev_char_comend_first' (`syntax.c:679'): "Return the
      ;; SYNTAX_COMEND_FIRST of the character before POS".
      ;;--------------------------------------------------------------
      (let ((p (- pos 1)))
        (and (>= p (buffer-beg ed))
             (%comend-first? (%code-in ed p
                                       (char->integer (fetch-char ed p)))))))

    (define (%find-defun-start pos)
      ;; `find_defun_start' (`syntax.c:585'): "Return a defun-start
      ;; position before POS and not too far before."
      ;;
      ;; The C caches the answer for a thousand characters; that is an
      ;; optimisation only, and is not carried.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (beg (buffer-beg ed))
             ;; `scan_newline' (`search.c') with count -1: the C backs up
             ;; to the start of the line, and walks one line at a time
             ;; after that. That scan is `search.c''s, and `search.scm'
             ;; imports this library - so the one-line walk is here.
             (line-start
              (lambda (p)
                (let loop ((q p))
                  (if (or (<= q beg)
                          (= (char->integer (fetch-char ed (- q 1))) 10))
                      q
                      (loop (- q 1)))))))
        (if (*comment-use-syntax-ppss*)
            (let ((boc (list-ref (syntax-ppss pos) 8)))
              (if (integer? boc) boc pos))
            (if (not (*open-paren-in-column-0-is-defun-start*))
                beg
                (let loop ((p (line-start pos)))
                  (cond
                   ((<= p beg) p)
                   ((= (%class-in ed p (char->integer (fetch-char ed p)))
                       sopen)
                    p)
                   (else (loop (line-start (- p 1))))))))))

    (define (%back-comment start stop comnested comstyle)
      ;; `back_comment' (`syntax.c:695'): "Check whether charpos FROM is
      ;; at the end of a comment." Answers `(FOUND? . BEGIN)'.
      ;;
      ;; The C's `lossage' arm - two kinds of string delimiter mixed up,
      ;; so the backward walk cannot tell a comment-starter from text in a
      ;; string - decodes forward from `find_defun_start' with
      ;; `scan_sexps_forward', which is this file's
      ;; `%scan-sexps-forward' over the C's own state record.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (beg (buffer-beg ed))
             (comment-end start)
             (string-style -1)
             (string-lossage #f)
             (comment-lossage #f)
             (comstart-pos 0)
             (defun-start 0)
             (nesting 1)
             (escape? (*comment-end-can-be-escaped*))
             (from start)
             (syntax 0)
             (quit-count 0)
             (outcome #f))
        (define (cp p) (char->integer (fetch-char ed p)))
        (define (post at) (cons (not (= at comment-end)) at))

        ;; The C's backward walk.
        (let walk ()
          ;; `rarely_quit (++quit_count)' (`syntax.c:738'): counted in an
          ;; `unsigned short', so the quit is looked at once every 65536
          ;; characters.
          (set! quit-count (+ quit-count 1))
          (rarely-quit quit-count)
          (cond
           (outcome #f)
           ((= from stop)
            (set! from (if (= comstart-pos 0) comment-end comstart-pos))
            (set! outcome 'finished))
           (else
            (set! from (- from 1))
            (let* ((prev-syntax syntax)
                   (c (cp from))
                   (syn (%code-in ed from c))
                   (code (logand syn #xff))
                   (com2start (and (%comstart-first? syn)
                                   (%comstart-second? prev-syntax)
                                   (= comstyle (%comment-style prev-syntax syn))
                                   (eq? (or (%nested? prev-syntax) (%nested? syn))
                                        comnested)))
                   (com2end (and (%comend-first? syn)
                                 (%comend-second? prev-syntax)))
                   (comstart (or com2start (= code scomment))))
              (set! syntax syn)
              (cond
               ;; "If a 2-char comment sequence partly overlaps with
               ;; another, we don't try to be clever."
               ((and (> from stop) (or com2end comstart)
                     (let* ((next (- from 1))
                            (next-syn (%code-in ed next (cp next))))
                       (or (and (or comstart comnested)
                                (%comend-second? syn)
                                (%comend-first? next-syn))
                           (and (or com2end comnested)
                                (%comstart-second? syn)
                                (= comstyle (%comment-style syn prev-syntax))
                                (%comstart-first? next-syn)))))
                (set! outcome 'lossage))
               (else
                ;; "The first time we see one, we need to consider it as
                ;; a comment starter, and the subsequent times as a
                ;; comment ender."
                (when (and com2start (= comstart-pos 0))
                  (set! com2end #f))
                (let ((code (cond (com2end sendcomment)
                                  (com2start scomment)
                                  (else code))))
                  (cond
                   ;; "Ignore comment starters of a different style."
                   ;;
                   ;; **`(not com2start)` is the C's `else if' chain and
                   ;; not a refinement of it** (`syntax.c:807'): the test
                   ;; applies only to a *single-character* `Scomment'.
                   ;; A two-character starter has just been converted to
                   ;; `Scomment` by the line above, and its style is
                   ;; computed from the pair, so asking `(%comment-style
                   ;; syn 0)` about one half of it answers something
                   ;; else. Without the guard `/* c */` never matches
                   ;; its own opener (`/`'s style bit is 1 against the
                   ;; pair's 0) and every backward `forward-comment`
                   ;; over a C block comment reports lossage.
                   ((and (not com2start)
                         (= code scomment)
                         (or (not (= comstyle (%comment-style syn 0)))
                             (not (eq? (%nested? syn) comnested))))
                    (walk))
                   ;; "Ignore escaped characters, except comment-enders
                   ;; which cannot be escaped."
                   ((and (or escape? (not (= code sendcomment)))
                         (%char-quoted ed from))
                    (walk))
                   (else
                    ;; The C switches on the enum; the classes are
                    ;; values here, so the dispatch is a `cond'.
                    (cond
                     ((or (= code sstring-fence) (= code scomment-fence)
                          (= code sstring))
                      (let ((c (cond ((= code sstring-fence) %st-string-style)
                                     ((= code scomment-fence) %st-comment-style)
                                     (else c))))
                        (cond ((= string-style -1) (set! string-style c))
                              ((= string-style c) (set! string-style -1))
                              (else (set! string-lossage #t))))
                      (walk))
                     ((= code scomment)
                      (cond
                       ((or (not (= string-style -1)) comment-lossage
                            string-lossage)
                        (set! outcome 'lossage))
                       ((not comnested)
                        (set! comstart-pos from)
                        (walk))
                       (else
                        (set! nesting (- nesting 1))
                        (if (<= nesting 0)
                            (set! outcome 'found)
                            (walk)))))
                     ((= code sendcomment)
                      (if (and (= (%comment-style syn 0) comstyle)
                               (eq? (or (and com2end (%nested? prev-syntax))
                                        (%nested? syn))
                                    comnested))
                          ;; "This is the same style of comment ender as
                          ;; ours."
                          (if comnested
                              (set! nesting (+ nesting 1))
                              (set! from stop))
                          ;; "We're mixing comment styles here."
                          (when (or (not (= comstart-pos 0)) (not (= c 10)))
                            (set! comment-lossage #t)))
                      (walk))
                     ((= code sopen)
                      ;; "Assume a defun-start point is outside of
                      ;; strings."
                      (when (and (*open-paren-in-column-0-is-defun-start*)
                                 (not (*comment-use-syntax-ppss*))
                                 (or (= from stop)
                                     (= (cp (- from 1)) 10)))
                        (set! defun-start from)
                        (set! from stop))
                      (walk))
                     (else (walk))))))))))))

        (cond
         ((or (eq? outcome 'found) (eq? outcome 'finished))
          (post from))
         (else
          ;; the C's `lossage'
          (let* ((ds (if (= defun-start 0)
                         (%find-defun-start comment-end)
                         defun-start))
                 (adjusted (if (= defun-start 0) (> ds beg) #t)))
            (let loop ((ds ds) (adjusted adjusted))
              (let* ((state (%internalize-parse-state #f))
                     (state (begin (set!state-location! state ds) state))
                     (ignored (%scan-sexps-forward state comment-end -1000000
                                                   #f 0))
                     (next-ds comment-end)
                     (next-adjusted adjusted))
                (if (and (= (state-incomment state) (if comnested 1 -1))
                         (= (state-comstyle state) comstyle))
                    (set! from (state-comstr-start state))
                    (begin
                      (set! from comment-end)
                      ;; "If comment_end is inside some other comment,
                      ;; maybe ours is nested, so we need to try again
                      ;; from within the surrounding comment."
                      (when (not (= (state-incomment state) 0))
                        (set! next-ds (+ (state-comstr-start state) 2)))))
                (if (< next-ds comment-end)
                    (loop next-ds next-adjusted)
                    (post from)))))))))


    ;; ---------------------------------------------------------------
    ;; `forw_comment' (`syntax.c:2311').
    ;; ---------------------------------------------------------------
    (define (%forw-comment ed from stop nesting style prev-syntax)
      ;; "Jump over a comment, assuming we are at the beginning of one."
      ;; Answers four values: found?, charpos, incomment, last-syntax.
      ;;--------------------------------------------------------------
      (let ((nesting (if (<= nesting 0) -1 nesting))
            (escape (*comment-end-can-be-escaped*))
            (quit-count 0))
        (let loop ((from from) (syntax prev-syntax) (prev 0) (nesting nesting)
                   (entered #f))
          ;; `rarely_quit (++quit_count)' (`syntax.c:2504').
          (set! quit-count (+ quit-count 1))
          (rarely-quit quit-count)
          (define (failure at)
            (values #f at nesting
                    (if (or (memv (logand syntax #xff) (list sescape scharquote))
                            (%comend-first? syntax)
                            (and (> nesting 0) (%comstart-first? syntax)))
                        syntax smax)))
          (cond
           ;; "Enter the loop in the middle so that we find a 2-char
           ;; comment ender if we start in the middle of it."
           ;; (`syntax.c:2327'.) The C's `forw_incomment' label reads
           ;; the *pending* syntax as the first half of a two-character
           ;; construct and the character AT FROM as the second, and
           ;; consumes nothing when it finds the ender. Re-entering the
           ;; ordinary loop instead (the first version of this port)
           ;; treated the character at FROM as the first half, so a
           ;; scan resuming on `*' `/' of a closing `*/' ran on to the
           ;; end of the buffer still "inside" the comment.
           ((and (not entered) (not (= syntax 0)) (< from stop))
            (let* ((c1 (char->integer (fetch-char ed from)))
                   (other (%code-in ed from c1)))
              (cond
               ;; A comment end of the same style.
               ((and (%comend-first? syntax)
                     (%comend-second? other)
                     (= (%comment-style syntax other) style)
                     (if (or (%nested? syntax) (%nested? other))
                         (> nesting 0)
                         (< nesting 0)))
                (set! nesting (- nesting 1))
                (if (<= nesting 0)
                    (values #t from nesting smax)
                    ;; A nested comment continues past its first ender.
                    (loop (+ from 1) smax smax nesting #t)))
               ;; A nested comment of the same style.
               ((and (> nesting 0)
                     (%comstart-first? syntax)
                     (= (%comment-style other syntax) style)
                     (%comstart-second? other)
                     (or (%nested? syntax) (%nested? other)))
                (loop (+ from 1) smax smax (+ nesting 1) #t))
               ;; Neither: the ordinary loop consumes the character at
               ;; FROM with the pending syntax as its `prev'.
               (else
                (loop from syntax syntax nesting #t)))))
           ((= from stop) (failure from))
           (else
            (let* ((c (char->integer (fetch-char ed from)))
                   (code (%class-in ed from c))
                   (prev syntax)
                   (syntax (%code-in ed from c))
                   (code (logand syntax #xff)))
              (cond
               ;; a comment end of the same style
               ((and (= code sendcomment)
                     (= (%comment-style syntax 0) style)
                     (if (%nested? syntax)
                         ;; **Not `(set! nesting (1- nesting))' in
                         ;; value position**: `set!' answers the
                         ;; *unspecified* value here (and the old one
                         ;; elsewhere), where Elisp's `setq' answers the
                         ;; new one. A `#|' comment nested once in
                         ;; Scheme code read `#<unspecified>' as the
                         ;; nesting count and died in `='.
                         (let ((new (- nesting 1)))
                           (set! nesting new)
                           (and (> new -1) (= new 0)))
                         (< nesting 0))
                     (not (and escape
                               (memv (logand prev #xff) (list sescape scharquote)))))
                (values #t from nesting smax))
               ((and (= code scomment-fence) (= style %st-comment-style))
                (values #t from nesting smax))
               (else
                (when (and (> nesting 0) (= code scomment)
                           (%nested? syntax)
                           (= (%comment-style syntax 0) style))
                  (set! nesting (+ nesting 1)))
                (let ((from (if (and escape (memv code (list sescape scharquote)))
                                (if (>= (+ from 1) (- stop 1))
                                    (- stop 1)
                                    (+ from 2))
                                (+ from 1))))
                  ;; `forw_incomment' - the two 2-character tests
                  (cond
                   ((and (< from stop)
                         (%comend-first? syntax)
                         (let* ((c1 (char->integer (fetch-char ed from)))
                                (other (%code-in ed from c1)))
                           (and (%comend-second? other)
                                (= (%comment-style syntax other) style)
                                (if (or (%nested? syntax) (%nested? other))
                                    (> nesting 0)
                                    (< nesting 0)))))
                    (set! nesting (- nesting 1))
                    (if (<= nesting 0)
                        (values #t from nesting smax)
                        (loop (+ from 1) smax smax nesting #t)))
                   ((and (> nesting 0) (< from stop)
                         (%comstart-first? syntax)
                         (let* ((c1 (char->integer (fetch-char ed from)))
                                (other (%code-in ed from c1)))
                           (and (= (%comment-style other syntax) style)
                                (%comstart-second? other)
                                (or (%nested? syntax) (%nested? other)))))
                    (loop (+ from 1) smax smax (+ nesting 1) #t))
                   (else (loop from syntax syntax nesting #t))))))))))))

    ;; ---------------------------------------------------------------
    ;; `syntax_multibyte' (`syntax.c:2644') and the ignore-comments test.
    ;; ---------------------------------------------------------------
    (define (%syntax-multibyte ed pos c multibyte-symbol)
      ;; `syntax_multibyte' (`syntax.c:2644'): "Return syntax code of
      ;; character C if C is an ASCII character or if MULTIBYTE_SYMBOL_P
      ;; is false. Otherwise, return Ssymbol."
      ;;--------------------------------------------------------------
      (if (and multibyte-symbol (> c 127))
          ssymbol
          (%class-in ed pos c)))

    (define (%parse-sexp-ignore-comments?)
      ;; `parse_sexp_ignore_comments' (`syntax.c:139'), the buffer-local
      ;; the scans read. A buffer that has not set it reads the
      ;; *global's* value, as a buffer-local does in Emacs - before the
      ;; state-cache port this answered `#f' unconditionally, so a scan
      ;; saw the braces inside comments.
      ;;
      ;; **Departure**: the global's default here is `#t' where Emacs's
      ;; starts nil (`DEFVAR_BOOL', `syntax.c:3769') and the modes that
      ;; want it set it buffer-locally (`prog-mode.el:401',
      ;; `scheme.el:185', `cc-mode.el:639'). Ours relies on the global
      ;; because there is no cc-mode yet and the other modes' local
      ;; settings are in; see DEPARTURES.md.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'parse-sexp-ignore-comments
                          (*parse-sexp-ignore-comments*)))

    ;; ---------------------------------------------------------------
    ;; `scan-error' - `xsignal3 (Qscan_error, ...)'.
    ;;
    ;; Emacs's condition carries three data fields, and
    ;; `error-message-string' renders them as `Scan error: "MSG", START,
    ;; END' (measured on Emacs 31.1). This tree's conditions are Guile
    ;; error objects with a message string, so a scan error is a record
    ;; of its own and the reporter and `error-message-string' know it -
    ;; the same shape `<quit-condition>' took.
    ;; ---------------------------------------------------------------
    (define-record-type <scan-error>
      (make-scan-error message start end) scan-error?
      (message scan-error-message)
      (start scan-error-start)
      (end scan-error-end))

    (define (%scan-lists-error msg start end)
      ;; What the C's `xsignal3 (Qscan_error, MSG, START, END)' signals:
      ;; the raw message and the two positions, as the C's data is.
      ;;--------------------------------------------------------------
      (raise (make-scan-error msg start end)))

    (define (scan-error-string err)
      ;; What `error-message-string' renders for a scan error - measured
      ;; on Emacs 31.1, which says `Scan error: "Unbalanced parentheses",
      ;; 1, 5' for that signal.
      ;;--------------------------------------------------------------
      (string-append "Scan error: \"" (scan-error-message err) "\", "
                     (number->string (scan-error-start err)) ", "
                     (number->string (scan-error-end err))))

    (define (%scan-lists from0 count depth sexpflag)
      ;; `scan_lists' (`syntax.c:2660'): "Scan from character number FROM
      ;; by COUNT lists. Scan forward if COUNT is positive, backward if
      ;; COUNT is negative. Return the character number of the position
      ;; thus found."
      ;;
      ;; Answers #f - Elisp's nil - when the buffer ran out between
      ;; objects, and signals "Unbalanced parentheses" when it ran out
      ;; inside one.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (beg (buffer-beg ed))
             (zv (buffer-z ed))
             (stop (if (> count 0) zv beg))
             (min-depth (if (> depth 0) 0 depth))
             (multibyte-symbol
              (and sexpflag
                   (buffer-local-value (current-buffer)
                                       'multibyte-syntax-as-symbol #f)))
             (last-good from0)
             (ignore (%parse-sexp-ignore-comments?)))
        (define (cp p) (char->integer (fetch-char ed p)))
        (define (class-at p) (%syntax-multibyte ed p (cp p) multibyte-symbol))

        ;; `maybe_quit ()' (`syntax.c:2689'): "Every loop that might run
        ;; for a long time ... ought to call maybe_quit at least once."
        (maybe-quit)
        (%setup-syntax-table)
        (let ((from (max beg (min from0 zv)))
              (quit-count 0)
              (mathexit #f)
              (comstyle 0)
              (comnested #f)
              (code 0)
              (c 0)
              (stringterm 0))
          (define (lose) (%scan-lists-error "Unbalanced parentheses" last-good from))
          (define (lose-early)
            (%scan-lists-error "Containing expression ends prematurely"
                               last-good from))
          (if (= count 0)
              from
              (let loop ((mode (if (> count 0) 'f-top 'b-top)))
                ;; `rarely_quit (++quit_count)' (`syntax.c:2695' and
                ;; `:2863'): once every 65536 characters, so that a long
                ;; scan answers C-g.
                (set! quit-count (+ quit-count 1))
                (rarely-quit quit-count)
                (case mode

                  ;; -------------------------------------------------
                  ;; The forward scan: the top of `while (from < stop)'.
                  ;; -------------------------------------------------
                  ((f-top)
                   (if (>= from stop)
                       (loop 'f-end)
                       (let* ((c0 (cp from))
                              (syn (%code-in ed from c0))
                              (syn-code (%syntax-multibyte ed from c0
                                                           multibyte-symbol))
                              (comstart-first (%comstart-first? syn))
                              (prefix (%prefix-flag? syn)))
                         (set! c c0)
                         (set! code syn-code)
                         (set! comnested (%nested? syn))
                         (set! comstyle (%comment-style syn 0))
                         (when (= depth min-depth) (set! last-good from))
                         (set! from (+ from 1))
                         (when (and (< from stop) comstart-first)
                           (set! c (cp from))
                           (let ((other (%code-in ed from c)))
                             (when (and (%comstart-second? other) ignore)
                               (set! code scomment)
                               (set! comstyle (%comment-style other syn))
                               (set! comnested (or (%nested? other) comnested))
                               (set! from (+ from 1)))))
                         (if prefix
                             (loop 'f-top)
                             ;; The C switches on the enum; the classes
                             ;; are *values* here, so the dispatch is a
                             ;; `cond' and not a `case' - a `case' would
                             ;; compare the number with the symbol.
                             (cond
                               ((or (= code sescape) (= code scharquote))
                                (if (= from stop)
                                    (lose)
                                    (begin
                                      (set! from (+ from 1))
                                      (loop (if (or (> depth 0) (not sexpflag))
                                                'f-top
                                                'f-word)))))
                               ((or (= code sword) (= code ssymbol))
                                (loop (if (or (> depth 0) (not sexpflag))
                                          'f-top
                                          'f-word)))
                               ((= code scomment-fence)
                                (loop 'f-comment-fence))
                               ((= code scomment) (loop 'f-comment))
                               ((= code smath)
                                (if (not sexpflag)
                                    (loop 'f-top)
                                    (begin
                                      (when (and (not (= from stop))
                                                 (= c (cp from)))
                                        (set! from (+ from 1)))
                                      (if mathexit
                                          (begin (set! mathexit #f)
                                                 (loop 'f-close1))
                                          (begin (set! mathexit #t)
                                                 (loop 'f-open))))))
                               ((= code sopen) (loop 'f-open))
                               ((= code sclose) (loop 'f-close1))
                               ((or (= code sstring) (= code sstring-fence))
                                (set! stringterm (cp (- from 1)))
                                (loop 'f-string))
                               (else (loop 'f-top)))))))

                  ;; the word loop, which ends the object at `done'
                  ((f-word)
                   (if (>= from stop)
                       (loop 'f-done)
                       (let ((c1-code (class-at from)))
                         (cond
                          ((memv c1-code (list scharquote sescape))
                           (set! from (+ from 1))
                           (if (= from stop) (lose) (loop 'f-word)))
                          ((memv c1-code (list sword ssymbol squote))
                           (set! from (+ from 1))
                           (loop 'f-word))
                          (else (loop 'f-done))))))

                  ((f-string)
                   (if (>= from stop)
                       (lose)
                       (let ((c1 (cp from))
                             (c1-code (class-at from)))
                         (if (if (= code sstring)
                                 (and (= c1 stringterm) (= c1-code sstring))
                                 (= c1-code sstring-fence))
                             (begin
                               (set! from (+ from 1))
                               (loop (if (and (= depth 0) sexpflag)
                                         'f-done
                                         'f-top)))
                             (begin
                               (when (memv c1-code (list scharquote sescape))
                                 (set! from (+ from 1)))
                               (set! from (+ from 1))
                               (loop 'f-string))))))

                  ((f-comment-fence)
                   (set! comstyle %st-comment-style)
                   (loop 'f-comment))

                  ((f-comment)
                   (if (not ignore)
                       (loop 'f-top)
                       ;; `forw_comment''s NESTING is an EMACS_INT: the
                       ;; C passes `comnested', a bool, and its `nesting
                       ;; <= 0' turns that into -1 or 1.
                       (let-values (((found at incomment last)
                                     (%forw-comment ed from stop
                                                    (if comnested 1 0)
                                                    comstyle 0)))
                         (set! from at)
                         (cond ((not found)
                                (if (= depth 0) (loop 'f-done) (lose)))
                               (else (set! from (+ from 1))
                                     (loop 'f-top))))))

                  ((f-open)
                   (set! depth (+ depth 1))
                   (loop (if (= depth 0) 'f-done 'f-top)))

                  ((f-close1)
                   (set! depth (- depth 1))
                   (if (= depth 0)
                       (loop 'f-done)
                       (begin
                         (when (< depth min-depth) (lose-early))
                         (loop 'f-top))))

                  ((f-done)
                   ;; The C's `done: count--;' ends the `while (count >
                   ;; 0)' loop, and the `while (count < 0)' loop that
                   ;; follows is entered only when COUNT is still
                   ;; negative - which it cannot now be.
                   (set! count (- count 1))
                   (loop (if (> count 0) 'f-top 'finish)))

                  ((f-end)
                   ;; "Reached end of buffer. Error if within object,
                   ;; return nil if between."
                   (if (not (= depth 0)) (lose) #f))

                  ;; -------------------------------------------------
                  ;; The backward scan: the top of `while (from > stop)'.
                  ;; -------------------------------------------------
                  ((b-top)
                   (if (<= from stop)
                       (loop 'b-end)
                       (begin
                         (set! from (- from 1))
                         (let* ((c0 (cp from))
                                (syn (%code-in ed from c0))
                                (syn-code (%syntax-multibyte ed from c0
                                                             multibyte-symbol)))
                           (set! c c0)
                           (set! code syn-code)
                           (when (= depth min-depth) (set! last-good from))
                           (set! comstyle 0)
                           (set! comnested (%nested? syn))
                           (when (= code sendcomment)
                             (set! comstyle (%comment-style syn 0)))
                           (when (and (> from stop) (%comend-second? syn)
                                      (%prev-char-comend-first? ed from) ignore)
                             ;; "We must record the comment style
                             ;; encountered so that later, we can match
                             ;; only the proper comment begin sequence
                             ;; of the same style."
                             (set! from (- from 1))
                             (set! code sendcomment)
                             (let* ((c2 (cp from))
                                    (other (%code-in ed from c2)))
                               (set! comstyle (%comment-style other syn))
                               (set! comnested (or (%nested? other) comnested))))
                           ;; "Quoting turns anything except a
                           ;; comment-ender into a word character. Note
                           ;; that this cannot be true if we decremented
                           ;; FROM in the if-statement above."
                           (cond
                            ((and (not (= code sendcomment))
                                  (%char-quoted ed from))
                             (set! from (- from 1))
                             (set! code sword)
                             (loop 'b-dispatch))
                            ((%prefix-flag? syn) (loop 'b-top))
                            (else (loop 'b-dispatch)))))))

                  ((b-dispatch)
                   (cond
                     ((or (= code sword) (= code ssymbol)
                          (= code sescape) (= code scharquote))
                      (loop (if (or (> depth 0) (not sexpflag))
                                'b-top
                                'b-word)))
                     ((= code smath)
                      (if (not sexpflag)
                          (loop 'b-top)
                          (begin
                            (when (> from beg)
                              (when (and (not (= from stop))
                                         (= c (cp (- from 1))))
                                (set! from (- from 1))))
                            (if mathexit
                                (begin (set! mathexit #f) (loop 'b-open2))
                                (begin (set! mathexit #t) (loop 'b-close))))))
                     ((= code sclose) (loop 'b-close))
                     ((= code sopen) (loop 'b-open2))
                     ((= code sendcomment)
                      (if (not ignore)
                          (loop 'b-top)
                          (let ((found (%back-comment from stop comnested
                                                      comstyle)))
                            ;; "FIXME: if !found, it really wasn't a
                            ;; comment-end ... we don't bother."
                            (when (car found) (set! from (cdr found)))
                            (loop 'b-top))))
                     ((or (= code scomment-fence) (= code sstring-fence))
                      (loop 'b-fence))
                     ((= code sstring)
                      (set! stringterm (cp from))
                      (loop 'b-string))
                     (else (loop 'b-top))))

                  ((b-word)
                   (if (<= from stop)
                       (loop 'b-done2)
                       (let ((c1-code (class-at (- from 1))))
                         ;; "Don't allow comment-end to be quoted."
                         (cond
                          ((= c1-code sendcomment) (loop 'b-done2))
                          ((%char-quoted ed (- from 1))
                           (set! from (- from 1))
                           (loop 'b-word))
                          ((memv c1-code (list sword ssymbol squote))
                           (set! from (- from 1))
                           (loop 'b-word))
                          (else (loop 'b-done2))))))

                  ((b-close)
                   (set! depth (+ depth 1))
                   (loop (if (= depth 0) 'b-done2 'b-top)))

                  ((b-open2)
                   (set! depth (- depth 1))
                   (if (= depth 0)
                       (loop 'b-done2)
                       (begin
                         (when (< depth min-depth) (lose-early))
                         (loop 'b-top))))

                  ((b-fence)
                   (if (= from stop)
                       (lose)
                       (begin
                         (set! from (- from 1))
                         (if (and (not (%char-quoted ed from))
                                  (= (class-at from) code))
                             (loop (if (and (= code sstring-fence)
                                            (= depth 0) sexpflag)
                                       'b-done2
                                       'b-top))
                             (loop 'b-fence)))))

                  ((b-string)
                   (if (= from stop)
                       (lose)
                       (begin
                         (set! from (- from 1))
                         (if (and (not (%char-quoted ed from))
                                  (= (cp from) stringterm)
                                  (= (class-at from) sstring))
                             (loop (if (and (= depth 0) sexpflag)
                                       'b-done2
                                       'b-top))
                             (loop 'b-string)))))

                  ((b-done2)
                   (set! count (+ count 1))
                   (loop (if (< count 0) 'b-top 'finish)))

                  ((b-end)
                   ;; "Reached start of buffer. Error if within object,
                   ;; return nil if between."
                   (if (not (= depth 0)) (lose) #f))

                  ((finish) from)

                  (else (error "scan-lists: bad mode"))))))))

    ;; ---------------------------------------------------------------
    ;; The DEFUNs built on the scan: `scan-lists' (`syntax.c:3054'),
    ;; `scan-sexps' (`:3079'), `backward-prefix-chars' (`:3096'),
    ;; `skip-syntax-forward'/`-backward' (`:1642', `:1653' over
    ;; `skip_syntaxes', `:2120') and `forward-comment' (`:2436').
    ;; ---------------------------------------------------------------
    (define (scan-lists from count depth)
      ;; GNU Emacs's `scan-lists' (`syntax.c:3054'): "Scan from character
      ;; number FROM by COUNT lists. ... If DEPTH is nonzero, treat that
      ;; as the nesting depth of the starting point".
      ;;--------------------------------------------------------------
      (if (not (integer? from)) (error "Wrong type argument: fixnump" from))
      (if (not (integer? count)) (error "Wrong type argument: fixnump" count))
      (if (not (integer? depth)) (error "Wrong type argument: fixnump" depth))
      (%scan-lists from count depth #f))

    (define (scan-sexps from count)
      ;; GNU Emacs's `scan-sexps' (`syntax.c:3079'): "Scan from character
      ;; number FROM by COUNT balanced expressions."
      ;;--------------------------------------------------------------
      (if (not (integer? from)) (error "Wrong type argument: fixnump" from))
      (if (not (integer? count)) (error "Wrong type argument: fixnump" count))
      (%scan-lists from count 0 #t))

    (define (backward-prefix-chars)
      ;; GNU Emacs's `backward-prefix-chars' (`syntax.c:3096'): "Move
      ;; point backward over any number of chars with prefix syntax. This
      ;; includes chars with expression prefix syntax class (') and those
      ;; with the prefix syntax flag (p)."
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (beg (buffer-beg ed))
             (pos (buffer-pt ed))
             (opoint pos))
        (if (<= pos beg)
            (begin (set-point ed opoint) #f)
            (begin
              (%setup-syntax-table)
              (set! pos (- pos 1))
              (let loop ()
                (let ((c (and (>= pos beg) (fetch-char ed pos))))
                  (when (and c
                             (not (%char-quoted ed pos))
                             (let ((syn (%code-in ed pos (char->integer c))))
                               (or (= (logand syn #xff) squote)
                                   (%prefix-flag? syn))))
                    (set! opoint pos)
                    (when (> pos beg)
                      (set! pos (- pos 1))
                      (loop)))))
              (set-point ed opoint)
              #f))))

    (define (%skip-syntaxes forwardp string lim)
      ;; `skip_syntaxes' (`syntax.c:2120'). The C's `fastmap' is a
      ;; membership test on the classes the string names; the answer is
      ;; what `skip-syntax-forward'/`-backward' return, the distance
      ;; travelled.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (beg (buffer-beg ed))
             (end (buffer-z ed))
             (negate (and (> (string-length string) 0)
                          (char=? (string-ref string 0) #\^)))
             (codes (let loop ((i (if negate 1 0)) (acc '()))
                      (if (>= i (string-length string))
                          acc
                          (let ((c (%spec-code (string-ref string i))))
                            (loop (+ i 1) (if c (cons c acc) acc))))))
             (lim (cond ((not lim) (if forwardp end beg))
                        ((integer? lim) lim)
                        (else (error "Wrong type argument: integer-or-marker-p"
                                     lim))))
             (limit (min (max lim beg) end))
             (start (buffer-pt ed)))
        (if (if forwardp (>= start limit) (<= start limit))
            (begin (set-point ed start) 0)
            (begin
              (%setup-syntax-table)
              (let loop ((pos start))
                (let ((code (%class-in ed (if forwardp pos (- pos 1))
                                       (char->integer
                                        (fetch-char ed (if forwardp pos
                                                           (- pos 1)))))))
                  (if (if negate (not (memv code codes)) (memv code codes))
                      (let ((next (if forwardp (+ pos 1) (- pos 1))))
                        (rarely-quit next)
                        (if (if forwardp (>= next limit) (<= next limit))
                            (begin (set-point ed next) (- next start))
                            (loop next)))
                      (begin (set-point ed pos) (- pos start)))))))))

    (define (skip-syntax-forward string . rest)
      ;; GNU Emacs's `skip-syntax-forward' (`syntax.c:1642'): "Move point
      ;; forward across chars in specified syntax classes."
      ;;--------------------------------------------------------------
      (%skip-syntaxes #t string (if (pair? rest) (car rest) #f)))

    (define (skip-syntax-backward string . rest)
      ;; GNU Emacs's `skip-syntax-backward' (`syntax.c:1653'): "Move
      ;; point backward across chars in specified syntax classes."
      ;;--------------------------------------------------------------
      (%skip-syntaxes #f string (if (pair? rest) (car rest) #f)))

    (define *forward-comment-function* (make-parameter #f))

    (define (forward-comment count)
      ;; GNU Emacs's `forward-comment' (`syntax.c:2436'): "Move forward
      ;; across up to COUNT comments. If COUNT is negative, move
      ;; backward. Stop scanning if we find something other than a
      ;; comment or whitespace. Set point to where scanning stops."
      ;;--------------------------------------------------------------
      (if (*forward-comment-function*)
          ((*forward-comment-function*) count)
          (let* ((ed (current-buffer))
                 (stop (if (> count 0) (buffer-z ed) (buffer-beg ed)))
                 (from (buffer-pt ed))
                 (count1 count))
            (define (cp p) (char->integer (fetch-char ed p)))
            (define (finish at val) (set-point ed at) val)
            (define (done) (set-point ed from) #t)
            (%setup-syntax-table)

            (define (forward)
              (if (<= count1 0)
                  (done)
                  (let ((comstyle 0) (comnested #f) (code 0) (c 0))
                    (define (skip)
                      (if (= from stop)
                          (finish from #f)
                          (let* ((c0 (cp from))
                                 (syn (%code-in ed from c0))
                                 (comstart-first (%comstart-first? syn)))
                            (set! c c0)
                            (set! code (logand syn #xff))
                            (set! comnested (%nested? syn))
                            (set! comstyle (%comment-style syn 0))
                            (set! from (+ from 1))
                            (when (and (< from stop) comstart-first)
                              (set! c (cp from))
                              (let ((other (%code-in ed from c)))
                                (when (%comstart-second? other)
                                  (set! code scomment)
                                  (set! comstyle (%comment-style other syn))
                                  (set! comnested (or (%nested? other)
                                                      comnested))
                                  (set! from (+ from 1)))))
                            (if (or (= code swhitespace)
                                    (and (= code sendcomment) (= c 10)))
                                (skip)
                                (cond
                                 ((= code scomment-fence)
                                  (set! comstyle %st-comment-style)
                                  (after-comment))
                                 ((not (= code scomment))
                                  (set! from (- from 1))
                                  (finish from #f))
                                 (else (after-comment)))))))
                    (define (after-comment)
                      (let-values (((found at incomment last)
                                    (%forw-comment ed from stop
                                                   (if comnested 1 0)
                                                   comstyle 0)))
                        (set! from at)
                        (if (not found)
                            (finish from #f)
                            (begin
                              (set! from (+ from 1))
                              (set! count1 (- count1 1))
                              (forward)))))
                    (skip))))

            (define (backward)
              (if (>= count1 0)
                  (done)
                  (let ((c 0) (orig-code 0) (code 0) (comstyle 0)
                        (comnested #f) (quoted #f))
                    (define (scan)
                      (if (<= from stop)
                          (finish (buffer-beg ed) #f)
                          (begin
                            (set! from (- from 1))
                            (set! quoted (%char-quoted ed from))
                            (let* ((c0 (cp from))
                                   (syn (%code-in ed from c0)))
                              (set! c c0)
                              (set! code (logand syn #xff))
                              (set! orig-code code)
                              (set! comstyle 0)
                              (set! comnested (%nested? syn))
                              (when (= code sendcomment)
                                (set! comstyle (%comment-style syn 0)))
                              (when (and (> from stop) (%comend-second? syn)
                                         (%prev-char-comend-first? ed from)
                                         (not (%char-quoted ed (- from 1))))
                                ;; "We must record the comment style
                                ;; encountered so that later, we can match
                                ;; only the proper comment begin sequence
                                ;; of the same style."
                                (set! from (- from 1))
                                (set! code sendcomment)
                                (let* ((c1 (cp from))
                                       (other (%code-in ed from c1)))
                                  (set! comstyle (%comment-style other syn))
                                  (set! comnested (or (%nested? other)
                                                      comnested))))
                              ;; The dispatch is on `code`, not on the
                              ;; character's own class: `code` is what
                              ;; the two-char merge above rewrote, and
                              ;; the C's switch is over it
                              ;; (`syntax.c:812'). Dispatching on the
                              ;; original made every merged comment end
                              ;; (`*/`) look like punctuation and the
                              ;; scan leave at the comment's last
                              ;; character.
                              (cond
                               ((= code scomment-fence) (fence))
                               ((= code sendcomment) (comment-arm))
                               ((or (not (= code swhitespace)) quoted)
                                (leave))
                               (else (scan)))))))
                    (define (fence)
                      ;; "Skip until first preceding unquoted comment_fence."
                      (let ((ini from))
                        (let scan ((fence-found #f))
                          (cond
                           (fence-found
                            (set! count1 (+ count1 1))
                            (backward))
                           ((<= from stop) (begin (set! from ini) (leave)))
                           (else
                            (set! from (- from 1))
                            (let ((c0 (cp from)))
                              (if (and (= (logand (%code-in ed from c0) #xff)
                                          scomment-fence)
                                       (not (%char-quoted ed from)))
                                  (scan #t)
                                  (scan #f))))))))
                    (define (comment-arm)
                      (let ((found (and (or (not quoted)
                                            (not (*comment-end-can-be-escaped*)))
                                        (%back-comment from stop comnested
                                                       comstyle))))
                        (cond
                         ((not (car found))
                          (if (= c 10)
                              ;; "This end-of-line is not an
                              ;; end-of-comment. Treat it like a
                              ;; whitespace."
                              (scan)
                              (begin
                                ;; "It was a two-char Sendcomment."
                                (when (not (= orig-code code))
                                  (set! from (+ from 1)))
                                (leave))))
                         (else
                          (set! from (cdr found))
                          (set! count1 (+ count1 1))
                          (backward)))))
                    (define (leave)
                      (set! from (+ from 1))
                      (finish from #f))
                    (scan))))

            (if (> count 0) (forward) (backward)))))

    ;; ---------------------------------------------------------------
    ;; `scan_sexps_forward' (`syntax.c:3178').
    ;; ---------------------------------------------------------------
    (define-record-type <parse-state>
      (%make-parse-state depth instring incomment comstyle quoted mindepth
                         thislevelstart prevlevelstart location
                         comstr-start levelstarts prev-syntax)
      parse-state?
      (depth state-depth set!state-depth!)
      (instring state-instring set!state-instring!)
      (incomment state-incomment set!state-incomment!)
      (comstyle state-comstyle set!state-comstyle!)
      (quoted state-quoted set!state-quoted!)
      (mindepth state-mindepth set!state-mindepth!)
      (thislevelstart state-thislevelstart set!state-thislevelstart!)
      (prevlevelstart state-prevlevelstart set!state-prevlevelstart!)
      (location state-location set!state-location!)
      (comstr-start state-comstr-start set!state-comstr-start!)
      (levelstarts state-levelstarts set!state-levelstarts!)
      (prev-syntax state-prev-syntax set!state-prev-syntax!))

    (define (%oldstate-ref s i)
      ;; `(car (nthcdr I S))' - Elisp's `Fcar'/`Fcdr' walk answers nil
      ;; past the end of the list, and `parse-partial-sexp' accepts a
      ;; state that carries only the elements its caller filled in:
      ;; `move-past-close-and-reindent' passes a **nine**-element one
      ;; (`lisp.el:985'), which the C reads happily. `list-ref' raised
      ;; "Argument 2 out of range: 9" instead.
      ;;--------------------------------------------------------------
      (let loop ((n i) (l s))
        (cond ((not (pair? l)) #f)
              ((= n 0) (car l))
              (else (loop (- n 1) (cdr l))))))

    (define (%internalize-parse-state external)
      ;; `internalize_parse_state' (`syntax.c:3502').
      ;;--------------------------------------------------------------
      (if (not external)
          (%make-parse-state 0 -1 0 0 #f 0 -1 -1 0 -1 '() smax)
          (let* ((s external)
                 (depth (let ((d (%oldstate-ref s 0))) (if (integer? d) d 0)))
                 (ins (%oldstate-ref s 3))
                 (instring (cond ((not ins) -1)
                                 ((eq? ins #t) %st-string-style)
                                 ((integer? ins) ins)
                                 (else %st-string-style)))
                 (inc (%oldstate-ref s 4))
                 (incomment (cond ((not inc) 0)
                                  ((eq? inc #t) -1)
                                  ((integer? inc) inc)
                                  (else -1)))
                 (quoted (and (%oldstate-ref s 5) #t))
                 (cs (%oldstate-ref s 7))
                 (comstyle (cond ((not cs) 0)
                                 ((and (integer? cs) (<= 0 cs %st-comment-style)) cs)
                                 (else %st-comment-style)))
                 (cstart (%oldstate-ref s 8))
                 (comstr-start (if (integer? cstart) cstart -1))
                 (levelstarts (%oldstate-ref s 9))
                 (prev (%oldstate-ref s 10))
                 (prev-syntax (if (integer? prev) prev smax)))
            (%make-parse-state depth instring incomment comstyle quoted 0
                               -1 -1 -1 comstr-start levelstarts prev-syntax))))

    (define (%scan-sexps-forward state end targetdepth stopbefore commentstop)
      ;; `scan_sexps_forward' (`syntax.c:3178').  Sets STATE's fields and
      ;; answers the position the scan stopped at.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (level-last (make-vector 100 -1))
             (level-prev (make-vector 100 -1))
             (curlevel 0)
             (depth (state-depth state))
             (mindepth depth)
             (boundary-stop (= commentstop -1))
             (start-quoted (state-quoted state))
             (nofence #f)
             (quit-count 0)
             (from (state-location state))
             ;; "Keep one character before FROM" (`syntax.c:3205'):
             ;; `prev_from = from; if (from != BEGV) dec_both'. A scan
             ;; that resumes on the *second* character of a two-char
             ;; comment opener must report the literal's start as that
             ;; second char minus one, and it reads `prev_from' to do
             ;; it. With `prev_from' left equal to FROM the start came
             ;; out one character late.
             (prev-from (if (> from (buffer-beg ed)) (- from 1) from))
             (prev-syntax (state-prev-syntax state))
             (prev-prev-syntax smax))

        (define (char-code p) (char->integer (fetch-char ed p)))
        (define (class-at p) (%class-in ed p (char-code p)))
        (define (entry-at p) (%code-in ed p (char-code p)))

        (define (inc-from!)
          ;; `INC_FROM' (`syntax.c:3212').
          (set! prev-prev-syntax prev-syntax)
          (set! prev-syntax (entry-at from))
          (set! prev-from from)
          (set! from (+ from 1)))

        (define (in-2char-comment-start? p)
          ;; `in_2char_comment_start' (`syntax.c:3144').
          (if (and (%comstart-first? prev-syntax)
                   (let ((syntax (entry-at p)))
                     (if (%comstart-second? syntax)
                         (begin
                           (set!state-comstyle! state
                                                (%comment-style syntax prev-syntax))
                           (set!state-incomment!
                            state (if (or (%nested? prev-syntax) (%nested? syntax))
                                      1 -1))
                           (set!state-comstr-start! state prev-from)
                           #t)
                         #f)))
              #t
              #f))

        (define (set-level-prev!)
          (vector-set! level-prev curlevel (vector-ref level-last curlevel)))

        (define (finish!)
          (set!state-depth! state depth)
          (set!state-mindepth! state mindepth)
          (set!state-thislevelstart! state (vector-ref level-prev curlevel))
          (set!state-prevlevelstart!
           state (if (= curlevel 0) -1 (vector-ref level-last (- curlevel 1))))
          (set!state-location! state from)
          (set!state-levelstarts!
           state (let loop ((i (- curlevel 1)) (acc '()))
                   (if (< i 0) acc (loop (- i 1) (cons (vector-ref level-last i) acc)))))
          (set!state-prev-syntax!
           state (if (or (%comstartend-first? prev-syntax) (state-quoted state))
                     prev-syntax smax))
          from)

        ;; the level stack, from OLDSTATE
        (let loop ((ls (state-levelstarts state)))
          (when (pair? ls)
            (vector-set! level-last curlevel (car ls))
            (vector-set! level-prev curlevel -1)
            (set! curlevel (min (+ curlevel 1) 99))
            (loop (cdr ls))))
        (vector-set! level-prev curlevel -1)
        (vector-set! level-last curlevel -1)
        (set!state-quoted! state #f)
        (%setup-syntax-table)

        (define (step mode)
          ;; `rarely_quit (++quit_count)' (`syntax.c:2504' and `:2590'):
          ;; the parse loop answers C-g once every 65536 characters.
          (set! quit-count (+ quit-count 1))
          (rarely-quit quit-count)
          (cond
           ;; ---- the main loop -------------------------------------
           ((eq? mode 'normal)
            (if (>= from end)
                'done
                (begin
                  (inc-from!)
                  (cond
                   ((and (< from end) (in-2char-comment-start? from))
                    (inc-from!)
                    'atcomment)
                   ((%prefix-flag? prev-syntax) 'normal)
                   (else
                    (let ((code (logand prev-syntax #xff)))
                      (cond
                       ((memv code (list sescape scharquote))
                        (if stopbefore
                            'stop
                            (begin
                              (vector-set! level-last curlevel prev-from)
                              ;; `goto startquoted' - **the quoted
                              ;; character itself is consumed**, and
                              ;; that is what stops `\"' from opening a
                              ;; string. Answering `symstarted' here
                              ;; left the `"' to the main loop, which
                              ;; read it as a string opener: measured,
                              ;; `(a \" b)' was "in string" from the
                              ;; quote onwards.
                              'startquoted)))
                       ((memv code (list sword ssymbol))
                        (if stopbefore
                            'stop
                            (begin
                              (vector-set! level-last curlevel prev-from)
                              'symstarted)))
                       ((= code scomment-fence)
                        (set!state-comstyle! state %st-comment-style)
                        (set!state-incomment! state -1)
                        (set!state-comstr-start! state prev-from)
                        'atcomment)
                       ((= code scomment)
                        (set!state-comstyle! state (%comment-style prev-syntax 0))
                        (set!state-incomment! state (if (%nested? prev-syntax) 1 -1))
                        (set!state-comstr-start! state prev-from)
                        'atcomment)
                       ((= code sopen)
                        (if stopbefore
                            'stop
                            (begin
                              (set! depth (+ depth 1))
                              (vector-set! level-last curlevel prev-from)
                              (set! curlevel (min (+ curlevel 1) 99))
                              (vector-set! level-prev curlevel -1)
                              (vector-set! level-last curlevel -1)
                              (if (= targetdepth depth) 'done 'normal))))
                       ((= code sclose)
                        (set! depth (- depth 1))
                        (if (< depth mindepth) (set! mindepth depth))
                        (if (> curlevel 0) (set! curlevel (- curlevel 1)))
                        (set-level-prev!)
                        (if (= targetdepth depth) 'done 'normal))
                       ((memv code (list sstring sstring-fence))
                        ;; "state->comstr_start = from - 1" - FROM has
                        ;; already been incremented, so this is the
                        ;; character that started the string.
                        (set!state-comstr-start! state prev-from)
                        (if stopbefore
                            'stop
                            (begin
                              (vector-set! level-last curlevel prev-from)
                              (set!state-instring!
                               state (if (= code sstring)
                                         (char-code prev-from)
                                         %st-string-style))
                              ;; `startinstring:' sets NOFENCE before its
                              ;; loop; the initial entry did it in the
                              ;; mode choice, and a string opened during
                              ;; the scan has to do it here.
                              (set! nofence
                                    (not (= (state-instring state) %st-string-style)))
                              (if boundary-stop 'done 'startinstring))))
                       (else 'normal))))))))
           ;; ---- symstarted ----------------------------------------
           ((eq? mode 'symstarted)
            (if (>= from end)
                (begin (set-level-prev!) 'normal)
                (if (in-2char-comment-start? from)
                    (begin (inc-from!) 'atcomment)
                    (let ((sc (class-at from)))
                      (cond
                       ((memv sc (list scharquote sescape))
                        (inc-from!)
                        (if (>= from end)
                            'endquoted
                            (begin (inc-from!) 'symstarted)))
                       ((memv sc (list sword ssymbol squote))
                        (inc-from!)
                        'symstarted)
                       (else
                        (set-level-prev!)
                        'normal))))))
           ;; ---- atcomment ----------------------------------------
           ((eq? mode 'atcomment)
            ;; The C's COMMENTSTOP is an int - 0, 1 or -1 - and `if
            ;; (commentstop || boundary_stop)' is false only for 0.
            ;; **0 is true in Scheme**, so it is tested numerically; the
            ;; first version wrote `(or commentstop ...)' and every
            ;; ordinary parse stopped dead at the first comment starter.
            (if (or (not (= commentstop 0)) boundary-stop)
                'done
                'startincomment))
           ;; ---- startincomment -----------------------------------
           ((eq? mode 'startincomment)
            (let-values (((found at incomment last)
                          (%forw-comment ed from end (state-incomment state)
                                         (state-comstyle state)
                                         (if (= from (buffer-beg ed)) 0 prev-syntax))))
              (set! from at)
              (if (not found)
                  (begin
                    (set!state-incomment! state incomment)
                    (set! prev-syntax last)
                    (if (memv (logand prev-syntax #xff) (list sescape scharquote))
                        'endquoted
                        'done))
                  (begin
                    (inc-from!)
                    (set!state-incomment! state 0)
                    (set!state-comstyle! state 0)
                    (set! prev-syntax smax)
                    (if boundary-stop 'done 'normal)))))
           ;; ---- startinstring ------------------------------------
           ((eq? mode 'startinstring)
            (if (>= from end)
                'done
                (let* ((c (char-code from))
                       (c-code (class-at from)))
                  (cond
                   ((and nofence (= c (state-instring state)) (= c-code sstring))
                    'string-end)
                   ((= c-code sstring-fence)
                    (if nofence
                        (begin (inc-from!) 'startinstring)
                        'string-end))
                   ((memv c-code (list scharquote sescape))
                    (inc-from!)
                    (if (>= from end)
                        'endquoted
                        (begin (inc-from!) 'startinstring)))
                   (else (inc-from!) 'startinstring)))))
           ;; ---- string_end ---------------------------------------
           ((eq? mode 'string-end)
            (set!state-instring! state -1)
            (set-level-prev!)
            (inc-from!)
            (if boundary-stop 'done 'normal))
           ;; ---- startquoted --------------------------------------
           ((eq? mode 'startquoted)
            (if (= from end) 'endquoted (begin (inc-from!) 'symstarted)))
           ;; ---- startquotedinstring ------------------------------
           ((eq? mode 'startquotedinstring)
            (if (>= from end)
                'endquoted
                (begin (inc-from!) 'startinstring)))
           ;; ---- stop ---------------------------------------------
           ((eq? mode 'stop)
            (set! from prev-from)
            (set! prev-syntax prev-prev-syntax)
            'done)
           ;; ---- endquoted ----------------------------------------
           ((eq? mode 'endquoted)
            (set!state-quoted! state #t)
            'done)
           (else 'done)))

        ;; the mode the C's `goto's enter at
        (let ((mode
               (cond
                ((not (= (state-incomment state) 0)) 'startincomment)
                ((>= (state-instring state) 0)
                 (set! nofence (not (= (state-instring state) %st-string-style)))
                 (if start-quoted 'startquotedinstring 'startinstring))
                (start-quoted 'startquoted)
                ((and (< from end) (in-2char-comment-start? from))
                 (inc-from!)
                 (set! prev-syntax smax)
                 'atcomment)
                (else 'normal))))
          (let loop ((mode mode))
            (if (eq? mode 'done)
                (finish!)
                (loop (step mode)))))))

    (define (parse-partial-sexp from to . rest)
      ;; GNU Emacs's `parse-partial-sexp' (`syntax.c:3567'): "Parse Lisp
      ;; syntax starting at FROM until TO; return status of parse at TO."
      ;;--------------------------------------------------------------
      (define (arg i) (if (>= i (length rest)) #f (list-ref rest i)))
      (let* ((targetdepth (arg 0))
             (stopbefore (arg 1))
             (oldstate (arg 2))
             (commentstop (arg 3))
             (target (cond ((not targetdepth) -1000000)
                           ((integer? targetdepth) targetdepth)
                           (else (error "Wrong type argument: fixnump"
                                        targetdepth)))))
        (when (> from to)
          (error "End position is smaller than start position"))
        (let* ((state (%internalize-parse-state oldstate))
               ;; the scanner starts at FROM: state->location is not used
               ;; by the C (it is an output), so bind it here.
               (state (begin (set!state-location! state from) state))
               (loc (%scan-sexps-forward state to target
                                         (and stopbefore #t)
                                         (cond ((not commentstop) 0)
                                               ((eq? commentstop 'syntax-table) -1)
                                               (else 1)))))
          (set-point (current-buffer) loc)
          (list (state-depth state)
                (if (< (state-prevlevelstart state) 0)
                    #f (state-prevlevelstart state))
                (if (< (state-thislevelstart state) 0)
                    #f (state-thislevelstart state))
                (if (>= (state-instring state) 0)
                    (if (= (state-instring state) %st-string-style)
                        #t (state-instring state))
                    #f)
                (cond ((< (state-incomment state) 0) #t)
                      ((= (state-incomment state) 0) #f)
                      (else (state-incomment state)))
                (and (state-quoted state) #t)
                (state-mindepth state)
                ;; "style of comment, if any" - and *no style* is
                ;; `comstyle` 0, which must answer nil: Elisp's `(not 0)`
                ;; is nil, so the C's `state.comstyle ? ... : Qnil`
                ;; needs a zero test here, not a truthiness test (0 is
                ;; true in Scheme, which made element 7 answer 0).
                (cond ((zero? (state-comstyle state)) #f)
                      ((= (state-comstyle state) %st-comment-style) 'syntax-table)
                      (else (state-comstyle state)))
                (if (or (not (= (state-incomment state) 0))
                        (>= (state-instring state) 0))
                    (state-comstr-start state)
                    #f)
                (state-levelstarts state)
                (if (= (state-prev-syntax state) smax)
                    #f (state-prev-syntax state))))))

    ;; ---------------------------------------------------------------
    ;; syntax.el
    ;; ---------------------------------------------------------------
    (define *syntax-ppss-table* (make-parameter #f))
    (define *syntax-begin-function* (make-parameter #f))
    (define *syntax-ppss-max-span* (make-parameter 20000))
    ;; `syntax-propertize-function` (`syntax.el:391`) is a
    ;; `defvar-local`; it is read with `buffer-local-value` above, and
    ;; no parameter of that name exists.
    (define syntax-propertize-chunks
      ;; "We're not sure how far we'll go.  In my tests, using chunks of
      ;; 2000 brings the overhead to something negligible.  Passing
      ;; `charpos' directly also works (basically works line-by-line) but
      ;; results in an overhead which I thought was a bit too high."
      ;; (`syntax.el:473'). Read, never `let'-bound, so a plain variable.
      ;;--------------------------------------------------------------
      2000)

    (define *syntax-propertize-chunk-size* (make-parameter 500))
    (define *syntax-propertize-extend-region-functions* (make-parameter '()))

    (define (with-syntax-table table thunk)
      ;; GNU Emacs's `with-syntax-table' (`syntax.el:33'): "Execute BODY
      ;; with TABLE as the current syntax table."
      ;;--------------------------------------------------------------
      (let ((saved (syntax-table)))
        (dynamic-wind
          (lambda () (set-syntax-table table))
          thunk
          (lambda () (set-syntax-table saved)))))

    (define *syntax-ppss-stats* (make-vector 6 0))

    (define (%syntax-ppss-data)
      ;; `syntax-ppss--data' (`syntax.el:595'): "Cons of two elements
      ;; (LAST . CACHE). Where LAST is a pair (LAST-POS . LAST-PPS)
      ;; caching the last invocation and CACHE is a list of (POS . PPSS)
      ;; pairs, in decreasing POS order. These are valid when the buffer
      ;; has no restriction."
      ;;
      ;; **Two cells, and buffer-local, as Emacs's two `defvar-local`s
      ;; are.** `syntax-ppss-wide' for a buffer at its full extent and
      ;; `syntax-ppss-narrow' for one inside a `save-restriction' -
      ;; reset whenever the narrowing's start moves - "so a parse done
      ;; inside a `save-restriction` cannot poison the cache the
      ;; unnarrowed parse reads" (`syntax.el:525`). The single parameter
      ;; this replaces was both shared by every buffer and blind to
      ;; narrowing, which is how `M-j` in a fresh buffer could read an
      ;; empty buffer's state back at a position that has text.
      ;;--------------------------------------------------------------
      (let ((buf (current-buffer)))
        (if (= (%point-min) 1)
            (or (buffer-local-value buf 'syntax-ppss-wide #f)
                (let ((v (cons #f '())))
                  (set-buffer-local-value! buf 'syntax-ppss-wide v)
                  v))
            (begin
              (unless (equal? (buffer-local-value buf 'syntax-ppss-narrow-start #f)
                              (%point-min))
                (set-buffer-local-value! buf 'syntax-ppss-narrow-start
                                         (%point-min))
                (set-buffer-local-value! buf 'syntax-ppss-narrow (cons #f '())))
              (buffer-local-value buf 'syntax-ppss-narrow #f)))))

    (define (%nth n lst)
      (let loop ((i 0) (l lst))
        (cond ((null? l) #f)
              ((= i n) (car l))
              (else (loop (+ i 1) (cdr l))))))

    (define (syntax-ppss . rest)
      ;; GNU Emacs's `syntax-ppss' (`syntax.el:606'): "Parse-Partial-Sexp
      ;; State at POS, defaulting to point."
      ;;--------------------------------------------------------------
      ;; "`(unless pos (setq pos (point)))'" (`syntax.el:617'): a nil POS
      ;; means point, and **a caller that passes one must not corrupt the
      ;; cache**. A `(syntax-ppss #f)` used to store `(cons #f PPSS)` as
      ;; the last entry; a later call then found OLD-PPSS with OLD-POS
      ;; nil, took the "use OLD-PPSS" branch, and compared
      ;; `(<= (or toplevel-pos (nth 2 ppss)) pos)' - `nth 2' is nil for
      ;; the empty buffer's state - which raises "Wrong type argument in
      ;; position 2: #f" from a `<'. Found by `M-j' in a fresh buffer:
      ;; the first fontification inserts, and the syntactic pass asks
      ;; for a state at a nil START.
      (let ((pos (or (and (pair? rest) (car rest))
                     (buffer-pt (current-buffer)))))
        (syntax-propertize pos)
        (with-syntax-table (or (*syntax-ppss-table*) (syntax-table))
          (lambda ()
            (let* ((cell (%syntax-ppss-data))
                   (ppss-last (car cell))
                   (ppss-cache (cdr cell))
                   (old-pos (and ppss-last (car ppss-last)))
                   (old-ppss (and ppss-last (cdr ppss-last)))
                   (pt-min (%point-min))
                   (ppss #f))
              (if (and old-pos (> old-pos pos)) (set! old-pos #f))
              (set! ppss
                    (cond
                     ;; "Use the OLD-POS if usable and close."
                     ((and old-pos (< (- pos old-pos) 2000))
                      (parse-partial-sexp old-pos pos #f #f old-ppss #f))
                     ;; "Use OLD-PPSS if possible and close enough."
                     ((and (not old-pos) old-ppss
                           (let ((m (or (syntax-ppss-toplevel-pos old-ppss)
                                        (%nth 2 old-ppss))))
                             (set! pt-min m)
                             (and (<= m pos)
                                  (< (- pos m) (*syntax-ppss-max-span*)))))
                      ;; The OLD-PPSS branch updates `last` - measured on
                      ;; Emacs 31.1: `(syntax-ppss 15)' then
                      ;; `(syntax-ppss 6)' leaves `last` at 6 - but not
                      ;; the cache list. The OLD-POS branch updates
                      ;; *neither* ("Don't update the `last' cache",
                      ;; `syntax.el:632'), which the same measurement
                      ;; shows: 10 then 13 leaves `last` at 10.
                      (let ((ppss (parse-partial-sexp pt-min pos #f #f #f #f)))
                        (set-car! cell (cons pos ppss))
                        (set-buffer-local-value!
                         (current-buffer) 'syntax-ppss--updated-cache #t)
                        ppss))
                     (else
                      ;; **`pt-min` is rebound here.** Emacs's `else` binds
                      ;; `(pt-min (point-min))`; without it the failed
                      ;; OLD-PPSS branch above leaves `pt-min` at a position
                      ;; *after* POS, and the parse below gets FROM > TO -
                      ;; "End position is smaller than start position".
                      (let ((cache-pred #f) (cache ppss-cache)
                            (pt-min (%point-min))
                            (pt-best (%point-min)) (ppss-best #f))
                        ;; "Setup the before-change function if necessary."
                        ;; `(add-hook 'before-change-functions
                        ;;            #'syntax-ppss-flush-cache 99 t)'
                        ;; (`syntax.el:677'). Emacs installs it buffer-locally
                        ;; the first time a buffer is parsed; a hook here is a
                        ;; parameter, so it is one list and the `memq' keeps
                        ;; it to one entry. **Without it a cached state
                        ;; outlives the edit that moved the positions it
                        ;; describes** - `syntax-ppss' then answers a state
                        ;; from the wrong place, and `comment-search-forward'
                        ;; on a line that plainly starts with `;' finds no
                        ;; comment. Found by `indent-region' over a file with
                        ;; a commented-out block; the answer depended on where
                        ;; the region started, which is the signature of a
                        ;; stale cache.
                        ;; "`(unless (or ppss-cache ppss-last) ...)'" - and
                        ;; **an empty cache list is TRUE in Scheme**, so the
                        ;; test is `pair?' and not the list itself.
                        (unless (or (pair? ppss-cache) ppss-last)
                          (unless (memq syntax-ppss-flush-cache
                                        (*before-change-functions*))
                            (*before-change-functions*
                             (append (*before-change-functions*)
                                     (list syntax-ppss-flush-cache)))))
                        (let loop ((c cache) (pred #f))
                          (cond ((and (pair? c) (< pos (caar c)))
                                 (loop (cdr c) c))
                                (else (set! cache c) (set! cache-pred pred))))
                        (when (pair? cache)
                          (set! pt-min (caar cache))
                          (set! ppss-best (cdar cache)))
                        (if (or (not old-pos) (< old-pos pt-min))
                            (begin (set! pt-best pt-min) #t)
                            (begin (set! pt-best old-pos)
                                   (set! ppss-best old-ppss)))
                        (let ((ppss
                               (if (< (- pos pt-best) (*syntax-ppss-max-span*))
                                   (parse-partial-sexp pt-best pos #f #f
                                                       ppss-best #f)
                                   (let slow ((pt-min pt-min)
                                              (ppss-best ppss-best)
                                              (ppss-cache ppss-cache))
                                     (if (> (- pos pt-min)
                                            (* 2 (*syntax-ppss-max-span*)))
                                         (let ((mid (quotient (+ pt-min pos) 2)))
                                           (let ((mid-ppss
                                                  (parse-partial-sexp
                                                   pt-min mid #f #f ppss-best #f)))
                                             (slow mid mid-ppss
                                                   (cons (cons mid mid-ppss)
                                                         ppss-cache))))
                                         (parse-partial-sexp
                                          pt-min pos #f #f ppss-best #f))))))
                          ;; "Store it in the cache." Emacs keeps the list in
                          ;; **decreasing position order**, which the scan
                          ;; above relies on; a blind push breaks it and then
                          ;; `pt-min' can come back *after* POS.
                          (let ((pair (cons pos ppss)))
                            (if cache-pred
                                (if (> (- (caar cache-pred) pos)
                                       (*syntax-ppss-max-span*))
                                    (set-cdr! cache-pred
                                              (cons pair (cdr cache-pred)))
                                    (set-car! cache-pred pair))
                                (if (or (null? ppss-cache)
                                        (> (- (caar ppss-cache) pos)
                                           (*syntax-ppss-max-span*)))
                                    (set! ppss-cache (cons pair ppss-cache))
                                    (set-car! ppss-cache pair))))
                          ;; "`(setq ppss-last (cons pos ppss))'
                          ;; (setcar cell ppss-last) (setcdr cell
                          ;; ppss-cache)'" - the `last` entry and the cache
                          ;; list, and the flag the propertizer reads.
                          (set-car! cell (cons pos ppss))
                          (set-cdr! cell ppss-cache)
                          (set-buffer-local-value!
                           (current-buffer) 'syntax-ppss--updated-cache #t)
                          ppss)))))
              ppss)))))

    (define (ppss-comment-or-string-start ppss)
      ;; GNU Emacs's `ppss-comment-or-string-start' (`syntax.el'): "The
      ;; start position of the comment or string that PPSS says point is
      ;; in, or nil."
      ;;--------------------------------------------------------------
      (list-ref ppss 8))

    (define (syntax-ppss-depth ppss)
      ;; `syntax-ppss-depth' (`syntax.el:487').
      ;;--------------------------------------------------------------
      (car ppss))

    (define (syntax-ppss-toplevel-pos ppss)
      ;; `syntax-ppss-toplevel-pos' (`syntax.el:490').
      ;;--------------------------------------------------------------
      ;; The C is two lines:
      ;;
      ;;   (or (car (nth 9 ppss))
      ;;       (nth 8 ppss))
      ;;
      ;; **This had drifted into a `cond' on the depth** that also asked
      ;; `(> (nth 4 ppss) 0)' - and element 4 is `t' for a non-nestable
      ;; comment, so `>' raised "Wrong type argument" the first time a
      ;; scan asked this about a state outside a comment. Found by
      ;; `beginning-of-defun' on a buffer holding `?\"'.
      (or (let ((levels (%nth 9 ppss))) (and (pair? levels) (car levels)))
          (%nth 8 ppss)))

    (define (syntax-ppss-context ppss)
      ;; `syntax-ppss-context' (`syntax.el:500').
      ;;--------------------------------------------------------------
      (cond ((%nth 3 ppss) 'string)
            ((%nth 4 ppss) 'comment)
            (else #f)))

    (define (syntax-ppss-flush-cache beg . rest)
      ;; `syntax-ppss-flush-cache' (`syntax.el:544'): "Flush the cache of
      ;; `syntax-ppss' starting at position BEG."
      ;;
      ;; **Both cells** (`:550`), which is what a narrowed parse and an
      ;; unnarrowed one need. Emacs also moves `syntax-propertize--done'
      ;; back (`syntax.el:547`) unless a propertize is in process; that
      ;; is here too, without the in-process flag - a propertize that
      ;; flushes its own region would redo work, never do less.
      ;;--------------------------------------------------------------
      (let ((done (%propertize-done)))
        ;; "`(unless (syntax-propertize--in-process-p) ...)'"
        ;; (`syntax.el:547'): while a propertize is in process the limit
        ;; is `most-positive-fixnum` and must be left alone - `:389' says
        ;; why: "so that `syntax-ppss-flush-cache' can be used from within
        ;; `syntax-propertize' without ruining the `syntax-table' already
        ;; set."
        (unless (= done most-positive-fixnum)
          (unless (< done beg)
            (set-buffer-local-value! (current-buffer) 'syntax-propertize--done
                                     (min beg done)))))
      (let loop ((names '(syntax-ppss-wide syntax-ppss-narrow)))
        (when (pair? names)
          (let ((cell (buffer-local-value (current-buffer) (car names) #f)))
            (when (pair? cell)
              (let ((last (car cell)))
                (when (and (pair? last) (< beg (or (car last) 0)))
                  ;; "If `syntax-begin-function' jumped to BEG, then the
                  ;; old state at BEG can depend on the text after BEG
                  ;; (which is presumably changed)."
                  (if (<= beg (or (syntax-ppss-toplevel-pos (cdr last))
                                  (list-ref last 3)
                                  0))
                      (set-car! cell #f)
                      (set-car! last #f))))
              (set-cdr! cell
                        (let loop2 ((c (cdr cell)))
                          (cond ((null? c) '())
                                ((> (caar c) beg) (loop2 (cdr c)))
                                (else (cons (car c) (loop2 (cdr c)))))))))
          (loop (cdr names))))
      #f)

    ;; The three editfns functions the propertize helpers need. Local
    ;; because `editfns.sld' imports this library (the word motions), and
    ;; a port of `syntax.el' may not close that cycle.
    (define (point) (buffer-pt (current-buffer)))
    (define (goto-char pos) (set-point (current-buffer) pos))
    (define (beginning-of-line)
      (let loop ((p (point)))
        (if (or (<= p 1)
                (char=? (fetch-char (current-buffer) (- p 1)) #\newline))
            (set-point (current-buffer) p)
            (loop (- p 1)))))
    (define (end-of-line)
      (let ((max (buffer-z (current-buffer))))
        (let loop ((p (point)))
          (if (or (>= p max)
                  (char=? (fetch-char (current-buffer) p) #\newline))
              (set-point (current-buffer) p)
              (loop (+ p 1))))))
    (define (save-excursion thunk)
      (let ((buf (current-buffer))
            (pt (point)))
        (dynamic-wind (lambda () #f) thunk
                      (lambda ()
                        (if (eq? buf (current-buffer))
                            (set-point buf pt)
                            #t)))))

    (define (syntax-propertize-wholelines start end)
      ;; `syntax-propertize-wholelines' (`syntax.el:152').
      ;;--------------------------------------------------------------
      (save-excursion
        (lambda ()
          (goto-char start)
          (beginning-of-line)
          (set! start (point))
          (goto-char end)
          (end-of-line)
          (set! end (point))
          (cons start end))))

    (define (syntax-propertize-multiline start end)
      ;; `syntax-propertize-multiline' (`syntax.el:171').
      ;;--------------------------------------------------------------
      (save-excursion
        (lambda ()
          (goto-char start)
          (beginning-of-line)
          (when (and (> (point) 1)
                     (get-text-property (-(point) 1) 'syntax-multiline))
            (set! start (-(point) 1)))
          (goto-char end)
          (when (and (< (point) (%point-max))
                     (get-text-property (point) 'syntax-multiline))
            (end-of-line)
            (set! end (point)))
          (cons start end))))

    (define (%propertize-done)
      ;; `syntax-propertize--done' (`syntax.el:391'): buffer-local, and
      ;; `most-positive-fixnum` while a propertize is *in process* - the
      ;; C's `syntax-propertize--in-process-p' (`:384') tests exactly
      ;; that value, and it is what stops the recursion.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'syntax-propertize--done 0))

    (define (%set-propertize-done! value)
      (set-buffer-local-value! (current-buffer) 'syntax-propertize--done value)
      (set! %syntax-propertize-done value))

    (define (syntax-propertize pos)
      ;; GNU Emacs's `syntax-propertize' (`syntax.el:395'): "Ensure that
      ;; syntax-table properties are set until POS (a buffer point)."
      ;;
      ;; **The in-process sentinel is the point of this port.** Emacs
      ;; binds `syntax-propertize--done' to `most-positive-fixnum` around
      ;; the mode's function (`:457') precisely because the function
      ;; calls `syntax-ppss' - which calls back here - and because the
      ;; `syntax-ppss-flush-cache` that can run inside must not reset the
      ;; limit. Without it every `syntax-ppss' re-entered the propertizer
      ;; and re-flushed the parse cache, which cleared the *position* of
      ;; the cached state while keeping the state, and the next parse read
      ;; that state back as if it belonged to the new position - the
      ;; "Wrong type argument in position 2: #f" that made `narrow-to-
      ;; defun` fail in an `emacs-lisp-mode` buffer.
      ;;--------------------------------------------------------------
      (when (< (%propertize-done) pos)
        (let ((fun (buffer-local-value (current-buffer)
                                       'syntax-propertize-function #f)))
          (if (or (not fun) (eq? fun 'ignore))
              ;; `(memq syntax-propertize-function '(nil ignore))' - a
              ;; mode that has nothing to do says so with `ignore'.
              (%set-propertize-done! (max (%point-max) pos))
              (begin
                ;; `(setq-local parse-sexp-lookup-properties t)' (`:403').
                (set-buffer-local-value! (current-buffer)
                                         'parse-sexp-lookup-properties #t)
                ;; "Since we share a single 'flush' function between
                ;; `syntax-ppss' and `syntax-propertize', we also have to
                ;; make sure the flush function is installed here
                ;; (bug#29767)." - only when the limit has been left
                ;; behind the narrowing.
                (when (< (%propertize-done) (%point-min))
                  (unless (memq syntax-ppss-flush-cache
                                (*before-change-functions*))
                    (*before-change-functions*
                     (append (*before-change-functions*)
                             (list syntax-ppss-flush-cache)))))
                ;; `(save-excursion (with-silent-modifications (with-syntax-table ...)))'
                ;; - the `with-silent-modifications` is spelled out; see
                ;; the note in the previous version of this function and
                ;; DEPARTURES.md for the two bindings carried and the two
                ;; not.
                (parameterize ((*inhibit-modification-hooks* #t)
                               (*inhibit-read-only* #t))
                 (save-excursion
                  (lambda ()
                   (with-syntax-table (or (*syntax-ppss-table*) (syntax-table))
                    (lambda ()
                     (let* ((start (max (min (%propertize-done) (%point-max))
                                        (%point-min)))
                            (end (max pos
                                      (min (%point-max)
                                           (+ start
                                              (*syntax-propertize-chunk-size*))))))
                      ;; The extend-region walk, with the limit bound to
                      ;; the sentinel around each function (`:433').
                      (let extend ((funs (*syntax-propertize-extend-region-functions*))
                                   (b start) (e end))
                        (cond
                         ((null? funs)
                          ;; "Flush `ppss` cache between the original value
                          ;; of START and that set above by
                          ;; `syntax-propertize-extend-region-functions`."
                          (syntax-ppss-flush-cache b)
                          ;; "Move the limit before calling the function,
                          ;; so it's done in case of errors."
                          (%set-propertize-done! e)
                          ;; "Remove the properties we are about to
                          ;; recompute."
                          (remove-text-properties
                           b e '(syntax-table nil syntax-multiline nil))
                          ;; "Bind `syntax-propertize--done' to avoid
                          ;; recursion!"
                          (%set-propertize-done! most-positive-fixnum)
                          (set-buffer-local-value!
                           (current-buffer) 'syntax-ppss--updated-cache #f)
                          (dynamic-wind
                            (lambda () #f)
                            (lambda () (fun b e))
                            (lambda () (%set-propertize-done! e)))
                          ;; "`syntax-ppss' was called and updated the cache
                          ;; while we were propertizing so we need to flush
                          ;; the part of the cache that may have been
                          ;; rendered out-of-date by the new properties."
                          (when (buffer-local-value
                                 (current-buffer) 'syntax-ppss--updated-cache #f)
                            (syntax-ppss-flush-cache b)))
                         (else
                          (let ((new (let ((saved (%propertize-done)))
                                       (%set-propertize-done! most-positive-fixnum)
                                       (dynamic-wind
                                         (lambda () #f)
                                         (lambda () ((car funs) b e))
                                         (lambda () (%set-propertize-done! saved))))))
                            (if new
                                (extend (cdr funs) (car new) (cdr new))
                                (extend (cdr funs) b e))))))))))))))))
      #f)

    ))
