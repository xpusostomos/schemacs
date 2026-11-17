(define-library (schemacs editor search)
  ;; This library mirrors GNU Emacs's `search.c': the search and match
  ;; primitives - `search-forward' and `search-backward' (which were
  ;; here in `(schemacs editor editfns)' and have come home to the file
  ;; the C has them in), `string-match', `looking-at',
  ;; `re-search-forward' and `re-search-backward', the match data -
  ;; `match-data', `set-match-data', `match-beginning', `match-end',
  ;; `match-data--translate' - and `replace-match', `regexp-quote' and
  ;; `match-substitute-replacement'.
  ;;
  ;; The regular expression ENGINE is not ported: `regex-emacs.c' is
  ;; some five thousand lines of backtracking matcher that the C
  ;; builds `compile_pattern' and `re_search' on, and standing in for
  ;; it is Guile's own - `(ice-9 regex)', glibc's POSIX extended
  ;; regular expressions, over which `%emacs-ere' translates. GNU
  ;; libc's ERE already speaks several of Emacs's escapes as they
  ;; stand - `\w', `\W', `\b', `\B', `\<', `\>' and the back
  ;; references `\1' - `\9' - and the translator swaps the conventions
  ;; the two spell differently: what Emacs escapes (`\(', `\)', `\|',
  ;; `\{n,m\}') is unescaped in ERE, and what ERE takes special
  ;; unescaped (`(', `)', `|', `{') is literal in an Emacs pattern.
  ;; A backslash before a character neither table knows matches that
  ;; character literally in both, which regex-emacs.c's backslash
  ;; `default:' does (`goto normal_char').
  ;;
  ;; What this cannot give, because no regexp substrate can, is the
  ;; syntax table: `\s' and `\S', `\c' and `\C', `\=', `\_' and the
  ;; string beginning and end `\`' and `\'` signal an error naming the
  ;; construct rather than guessing. And glibc matches leftmost-LONGEST
  ;; where Emacs's matcher is leftmost-FIRST - `a\|ab' matches "ab"
  ;; here where Emacs's matches "a" - which is what `posix-string-match'
  ;; asks for and `string-match' does not get.
  ;;
  ;; The match data is the C's `search_regs': a register per
  ;; parenthesized subexpression, `*search-regs*' here, a parameter
  ;; whose value is a list of `(START . END)' pairs, `#f' for a
  ;; subexpression that did not match. The positions a register holds
  ;; are the C's: ONE-based buffer positions (`BEG = 1' in buffer.h)
  ;; after a search in a buffer, zero-based string positions after one
  ;; in a string - `*last-thing-searched*' says which, and is the C's
  ;; `last_thing_searched'. The register count only grows, as the C's
  ;; does (`set_search_regs' clears the registers, it does not shrink
  ;; them), so a regexp's groups survive a following literal search as
  ;; unanswered.

  (import
    (scheme base)
    (scheme char)
    ;; `make-regexp' and `regexp-exec' are Guile core primitives, not
    ;; `(ice-9 regex)''s, which only adds the `match:*' accessors; the
    ;; `regexp/*' flags are core too. `string-match' here is ours, the
    ;; C's `string-match', which shadows no import because this one is
    ;; not taken.
    (only (ice-9 regex)
          match:start match:end match:count)
    ;; the cxr accessors are Guile's, as `(schemacs editor editfns)'s
    ;; import of them is
    (only (guile) cadr caddr cddr cdddr cadddr logand logior
          make-regexp regexp-exec
          regexp/icase regexp/newline regexp/notbol
          string-index)
    (only (schemacs editor marker)
          make-marker marker-buffer marker-position markerp set-marker)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs editor intervals) make-buffer-string)
    
    ;; `*case-fold-search*' is the case folding every search here
    ;; consults (`case-fold-search', buffer.c:6009), `with-current-buffer'
    ;; what `looking-at' and the like read the buffer through. The
    ;; line-break cache accessors and `cache-long-scans' are the buffer's
    ;; own slots (`buffer.c`), which `find-newline` below reads.
    (only (schemacs editor buffer)
          *case-fold-search* current-buffer with-current-buffer
          text-editor-text
          %text-editor-newline-cache set!%text-editor-newline-cache
          text-editor-cache-long-scans set-point bufferp buffer-beg buffer-z buffer-pt
          ;; `FETCH_CHAR` for the `\_<'/`\_>' assertion's `SYNTAX (c)'
          fetch-char)
    ;; The raw character store: `buffer.h`'s macros, which the scans below
    ;; read character by character as `find_newline` does with
    ;; `FETCH_CHAR`.
    (only (schemacs editor buffer-text)
          buffer-text-ref code-point->char
          ;; The scan's side of `buffer-text-ref' - see the comment in
          ;; `text-editor-search-forward'.
          buffer-text-store buffer-text-base buffer-text-gpt
          buffer-text-gap-size)
    ;; The store's own type. `u32vector-ref' is what `BUF_BEG_ADDR'
    ;; indexing is in Scheme; it is not in `(scheme base)' nor in
    ;; `(rnrs bytevectors)' on this Guile - `(guile)' is where the
    ;; typed-vector accessors live, as `buffer-text.scm' found.
    (only (guile) u32vector-ref)
    ;; `\w', `\W', `\sC' and `\SC' are the syntax table's classes in an
    ;; Emacs pattern (`regex-emacs.c' reads `SYNTAX (c)'), so the
    ;; translation reads the table too.
    (only (schemacs editor syntax)
          syntax-table standard-syntax-table with-syntax-table char-syntax
          string-to-syntax syntax-class-to-char
          ;; the `\_<'/`\_>' assertions read the table at a position
          %setup-syntax-table %class-in sword ssymbol
          ;; and the propertize hook installs this library's
          ;; `save-match-data' - see `%current-assertions'
          *internal-syntax-propertize-function*)
    ;; Walking a syntax table's runs for `\sC' and `\w' above ASCII:
    ;; `char_table_ref_and_range' (`chartab.c:320'), the C's own walk.
    (only (schemacs editor chartab) char-table-ref-and-range char-table-parent)
    ;; `syntax-propertize-rules' writes the `syntax-table' property
    ;; (`put-text-property'); its `subregexp-context-p' is below.
    (only (schemacs editor textprop) put-text-property)
    ;; The line-break cache: `region-cache.c`, which is the buffer's
    ;; `newline_cache` there. It is what makes searching a buffer with
    ;; very long lines affordable - a stretch already searched and found
    ;; free of line breaks is skipped whole rather than scanned again.
    ;; **It came here with the scans** (2026-10-12); the engine held this
    ;; import before, for the same reason.
    (only (schemacs editor region-cache)
          new-region-cache  know-region-cache
          region-cache-forward  region-cache-backward)
    ;; **This library does not import `editfns.scm`**, and that is what
    ;; lets `editfns.scm` be built on *it*. The four names it took from
    ;; there - `buffer-substring`, `point`, `point-min`, `point-max` -
    ;; were a departure from `search.c` anyway: search.c reads the buffer
    ;; through the macros (`PT`, `BEGV`, `ZV`, `BYTE_POS_ADDR`) and
    ;; `make_buffer_string` (`insdel.c`), never through `editfns.c`.
    ;; Verified by grep: `search.c` calls no editfns function at all.
    ;; The positions come from `buffer.scm`'s accessors, which the
    ;; engine re-exports, and the strings from `make-buffer-string`,
    ;; which is the C's own.
    (only (schemacs editor syntax) word-char?)
    ;; The case transfer of `replace-match' casifies the replacement
    ;; with the string case functions.
    (only (schemacs editor casefiddle)
          casify-region upcase upcase-initials)
    (only (guile) string-index)
    ;; The seam `insdel.scm` declares for `update_search_regs`: it is
    ;; `search.c`'s function (this file's) and `replace_range`, below, is
    ;; what calls it.
    (only (schemacs editor insdel) *update-search-regs-function* replace-range)
    )

  (export
   *last-thing-searched*
   *search-regs*
   looking-at
   looking-at-p
   string-match-p
   looking-back
   match-beginning
   match-data
   match-data--translate
   match-end
   match-string
   match-substitute-replacement
   re-search-backward
   re-search-forward
   regexp-quote
   replace-match
   save-match-data
   search-backward
   search-forward
   set-match-data
   string-match
   ;; `search.c`'s innermost literal walk and the two buffer searches it
   ;; carries, moved here from `engine.scm` on 2026-10-12.
   string-search-forward
   text-editor-search-forward
   text-editor-search-backward
   ;; The line scans: `find_newline` (`search.c:675`),
   ;; `scan_newline_from_point` (`:986') and `find_before_next_newline`
   ;; (`:997'). **They moved here from `engine.scm` on 2026-10-12**,
   ;; which held them only because the line arithmetic read them; that
   ;; arithmetic is `editfns.scm`'s now and imports them from here.
   find-newline
   scan-newline-from-point
   find-before-next-newline
   ;; `syntax.el`'s rules engine and the two `subr.el`/`regexp-opt.el`
   ;; helpers it needs - see the placement note beside them
   syntax-propertize-rules syntax-propertize-precompile-rules
   subregexp-context-p regexp-opt-depth
   )

  (begin
    (define *last-thing-searched*
      ;; GNU Emacs's `last_thing_searched': what the last search was
      ;; against - the buffer, the symbol `string' for the C's `Qt',
      ;; or false when there has been none. `match-data' reads it to
      ;; know whether its positions are buffer or string ones.
      ;;--------------------------------------------------------------
      (make-parameter #f))
    (define *search-regs*
      ;; GNU Emacs's `search_regs': a register per subexpression, here
      ;; a list of `(START . END)' pairs in the positions the search
      ;; ran in - one-based in a buffer, zero-based in a string - `#f'
      ;; for a register whose subexpression did not match. The list's
      ;; length is `search_regs.num_regs', and it only grows: see the
      ;; file header.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (%no-match-data)
      ;; `match_limit''s "no search has succeeded yet" state.
      ;;--------------------------------------------------------------
      (not (*search-regs*)))

    (define (%match-limit n beginningp)
      ;; GNU Emacs's `match_limit' (search.c:2776): the position of
      ;; SUBEXP N's start or end, `#f' for a subexpression that did not
      ;; match and for one beyond the register count - the C answers
      ;; nil for both (`n >= search_regs.num_regs || start[n] < 0' ->
      ;; Qnil) - and the "no search succeeded" error while there is no
      ;; match data at all.
      ;;--------------------------------------------------------------
      (cond
       ((< n 0) (error "Args out of range" n 0))
       ((not (*search-regs*)) (error "No match data, because no search succeeded"))
       ((>= n (length (*search-regs*))) #f)
       (else
        (let ((pair (list-ref (*search-regs*) n)))
          (and pair
               ;; A *position*, always: the C's `match_limit' answers
               ;; `make_fixnum (search_regs.start[n])', and `search_regs'
               ;; holds positions there whatever `match-data' is asked
               ;; to return. The registers kept here are the markers a
               ;; buffer search makes, so the position is read back out
               ;; of one - handing the marker itself to `goto-char' or
               ;; to arithmetic is "Wrong type argument in position 1",
               ;; which is what `query-replace-regexp' was failing with
               ;; once it moved point to a match.
               (let ((v ((if beginningp car cdr) pair)))
                 (if (markerp v) (marker-position v) v)))))))

    (define (match-beginning subexp)
      ;; GNU Emacs's `match-beginning' (search.c:2793): "position of
      ;; start of text matched by last search."
      ;;--------------------------------------------------------------
      (%match-limit subexp #t))

    (define (match-end subexp)
      ;; GNU Emacs's `match-end' (search.c:2806): "position of end of
      ;; text matched by last search."
      ;;--------------------------------------------------------------
      (%match-limit subexp #f))

    (define (%regs->match-data integers)
      ;; The value `match-data' returns: the registers flattened to
      ;; `(BEG END ...)' - `#f' for a register that did not match,
      ;; markers in the buffer that was searched unless INTEGERS,
      ;; zero-based integers in a string - with the trailing
      ;; non-matching registers ELIDED, which is the C's doing too
      ;; (`len = 2 * i + 2' is only advanced for a matching register).
      ;; A buffer search with INTEGERS appends the buffer itself, as
      ;; the C does.
      ;;--------------------------------------------------------------
      (let* ((string-search? (eq? 'string (*last-thing-searched*)))
             (regs (*search-regs*))
             (as-integers (or string-search? integers))
             ;; a buffer search's markers point into the buffer the
             ;; search was made in - the C's `last_thing_searched'
             (buffer (and (not string-search?) (*last-thing-searched*))))
        (let build ((i 0) (acc '()))
          (if (>= i (length regs))
              (reverse
               (if (and (not string-search?) integers)
                   (cons buffer acc)
                   acc))
              (let ((pair (list-ref regs i)))
                (build (+ i 1)
                       (if (not pair)
                           acc
                           (cons (if as-integers
                                     (cdr pair)
                                     (%match-marker buffer (cdr pair)))
                                 (cons (if as-integers
                                           (car pair)
                                           (%match-marker buffer (car pair)))
                                       acc)))))))))

    (define (%match-marker buffer position)
      ;; One register's marker, as the C makes it: two statements,
      ;; `data[2 * i] = Fmake_marker (); Fset_marker (data[2 * i],
      ;; make_fixnum (start), last_thing_searched);' (`search.c:2892'),
      ;; with no function named between them. The `%` is this tree's mark
      ;; for a helper the C does not name.
      ;;
      ;; **POSITION is a buffer position as it stands**, one-based, which
      ;; is what `search_regs.start' holds. This used to subtract one,
      ;; from when the registers here were zero-based - and the integers
      ;; beside it in `%regs->match-data' never did, so the same match
      ;; came back as markers at `(4 9)' and integers at `(5 10)'. Emacs
      ;; answers `(5 10)' either way.
      ;;--------------------------------------------------------------
      (let ((marker (make-marker)))
        (set-marker marker position buffer)
        marker))

    (define (match-data . args)
      ;; GNU Emacs's `match-data' (search.c:2816): "Return a list of
      ;; positions that record text matched by the last search." The
      ;; optional INTEGERS makes buffer positions integers with the
      ;; buffer appended; REUSE is filled destructively; RESEAT points
      ;; the markers it would reuse to nowhere. `#f' when no search has
      ;; succeeded yet.
      ;;--------------------------------------------------------------
      (let* ((integers (and (pair? args) (car args)))
             (reuse (and (pair? args) (pair? (cdr args)) (cadr args)))
             (reseat (and (pair? args) (pair? (cdr args)) (pair? (cddr args))
                          (caddr args))))
        (when (and reseat reuse)
          ;; the C's RESEAT: unchain the markers sitting in REUSE
          (let loop ((l reuse))
            (when (pair? l)
              (when (marker-buffer (car l))
                (set-marker (car l) #f))
              (set-car! l #f)
              (loop (cdr l)))))
        (cond
         ((not (*last-thing-searched*)) (if reuse reuse '()))
         ((not reuse)
          (%regs->match-data integers))
         (else
          ;; REUSE is destructively extended or filled: what does not
          ;; fit answers nil, as the C's does
          (let ((values (%regs->match-data integers)))
            (let fill ((tail reuse) (i 0))
              (cond
               ((>= i (length values)) reuse)
               ((not (pair? tail))
                ;; extend REUSE with what does not fit: a fresh list
                ;; of the remainder spliced on, the C's `XSETCDR'
                (set-cdr! tail (list-copy (list-tail values i)))
                reuse)
               (else
                (set-car! tail (list-ref values i))
                (fill (cdr tail) (+ i 1))))))))))

    (define (set-match-data list)
      ;; GNU Emacs's `set-match-data' (search.c:2949): "Set internal
      ;; data on last search match from elements of LIST" - a list
      ;; `(BEG END ...)' from `match-data', markers or integers or nil
      ;; in pairs, or with the buffer itself as one final element. A
      ;; marker that points nowhere counts as nil (`XSETFASTINT
      ;; (marker, 0)'), the list's nil pairs make their registers
      ;; unanswered, and the registers beyond the list are cleared,
      ;; which is the C's final loop.
      ;;--------------------------------------------------------------
      ;; The C discriminates buffer from string by what it finds: a
      ;; marker's buffer, or the buffer element, makes the match data
      ;; the buffer's; anything else stays a string's.
      (cond
       ((not list) #f)
       (else
        ;; the register count grows, never shrinks - `xpalloc'
        (let* ((old (*search-regs*))
               (n (max (length old) (quotient (+ (length list) 1) 2)))
               (pairs (make-list n #f)))
          (let loop ((l list) (i 0) (buffer #f))
            (cond
             ((not (pair? l))
              ;; the registers beyond the list are cleared
              (*search-regs* pairs)
              (*last-thing-searched*
               (if buffer buffer 'string))
              #f)
             ((bufferp (car l))
              (loop (cdr l) i (car l)))
             (else
              (let* ((beg (car l))
                     (rest (cdr l))
                     (end (if (pair? rest) (car rest) #f)))
                ;; a nil pair clears its register
                (when (< i n)
                  (list-set! pairs i
                             (cond
                              ((not beg) #f)
                              ((markerp beg)
                               ;; the C's `XSETFASTINT (marker_position
                               ;; (beg), ...)' - a marker's own position,
                               ;; one-based, as the integers here are.
                               ;; This used to add one, the other half of
                               ;; the subtraction `match-data' used to
                               ;; make; the two cancelled, and both were
                               ;; one away from Emacs.
                               (cons (marker-position beg)
                                     (and (markerp end)
                                          (marker-position end))))
                              (else
                               (cons
                                (cond ((integer? beg) beg)
                                      (else 0))
                                (cond ((integer? end) end)
                                      (else 0)))))))
                (loop (if (pair? rest) (cdr rest) '())
                      (+ i 1)
                      buffer)))))))))

    (define-syntax save-match-data
      ;; GNU Emacs's `save-match-data' (subr.el): "Execute BODY,
      ;; saving and restoring match data." The match data is restored
      ;; however the body leaves - an unwind-protect in Elisp, a
      ;; dynamic-wind here - because the body may quit.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ body ...)
         (let ((saved (*search-regs*))
               (saved-thing (*last-thing-searched*)))
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda ()
               (*search-regs* saved)
               (*last-thing-searched* saved-thing)))))))

    (define (match-data--translate n)
      ;; GNU Emacs's `match-data--translate' (search.c:3062): "Add N to
      ;; all positions in the match data." Internal.
      ;;--------------------------------------------------------------
      (when (*search-regs*)
        (*search-regs*
         (map
          (lambda (pair)
            (if (not pair)
                #f
                (cons (max 0 (+ (car pair) n))
                      (max 0 (+ (cdr pair) n)))))
          (*search-regs*)))
        #f))

    ;;----------------------------------------------------------------
    ;; The translation: an Emacs regexp to ERE, `%emacs-ere'
    ;;------------------------------------------------------------------

    (define %regexp-cache '())
    ;; ^ The compiled pattern cache, most recent first - a stand-in
    ;; for search.c's `regexp_cache', which `compile_pattern' keeps.

    (define (%untranslated-escape c)
      ;; Whether the ESCAPE `\<C>' is one the translator rejects:
      ;; everything that asks the syntax table or a position this
      ;; substrate has no answer for. The C's backslash switch has
      ;; these cases and this engine cannot honour them.
      ;;--------------------------------------------------------------
      (memv c (list #\= #\s #\S #\c #\C #\` #\' #\_)))

    (define (%pass-through-escape c)
      ;; Whether the ESCAPE `\<C>' means the same thing in ERE as in
      ;; an Emacs pattern and passes through untranslated: the word
      ;; and buffer anchors glibc has (`\<' `\' are glibc's GNU
      ;; extensions), the back references, and the punctuation a
      ;; backslash makes literal in BOTH dialects - regex-emacs.c's
      ;; backslash `default:' takes the character itself, and an ERE
      ;; escape of a special character makes that character literal,
      ;; so `\.' `\. is the same in both.
      ;;
      ;; **`\w' and `\W' are NOT here.** Emacs's `\w' is the syntax
      ;; table's word class, and glibc's is `[[:alnum:]_]' of the
      ;; locale - which keeps the underscore that Emacs's standard
      ;; table calls *symbol* syntax. `%syntax-class-ere' translates
      ;; them from the table instead, as `regex-emacs.c' reads it.
      ;;--------------------------------------------------------------
      (memv c (list #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9
                    ;; the string beginning and end: glibc's too, as `\<'
                    ;; is, and they keep that meaning when `^' and `$'
                    ;; are asked for the line's
                    #\` #\'
                    #\. #\* #\? #\+ #\[ #\] #\$ #\^ #\\)))

    (define (%without-nul text)
      ;; TEXT with every NUL taken out. See `%class-for-ere'.
      ;;
      ;; The parameter is TEXT and not STRING: `string' is the
      ;; constructor this walks with, and naming the parameter after it
      ;; made every `(string c)' a call of the *parameter* - the same
      ;; departure search.sld's `replace-match' had.
      ;;--------------------------------------------------------------
      ;; A NUL is dropped, and `[^\000-\177]' - "a character that is not
      ;; ASCII", which `directory-listing-before-filename-regexp' is full
      ;; of - therefore comes out as `[^-\177]', a *different* set. There
      ;; is no way to do better: glibc cannot be handed a NUL in a
      ;; pattern, has no `[:ascii:]' named class, refuses a range over
      ;; control characters in a locale ("Invalid range end" for
      ;; `[^ -DEL]', and `[^SOH-DEL]' silently matches everything), and
      ;; `[:print:]' is the *locale's* printable set, so it takes
      ;; non-ASCII in with it.
      ;;
      ;; What it costs, measured against `emacs -Q --batch' on the six
      ;; line shapes a listing actually has - western `Oct  2 15:09',
      ;; ISO `10-02 22:09', ISO with seconds and a zone
      ;; `2026-10-02 22:09:01.123 +0700', western with the day first,
      ;; a date-less line, and the `total' line - is nothing: every one
      ;; gives the same match end, and the two that fail to match fail
      ;; in Emacs too. So `directory-listing-before-filename-regexp' may
      ;; be used here as Emacs uses it.
      (let loop ((i 0) (acc ""))
        (if (>= i (string-length text))
            acc
            (let ((c (string-ref text i)))
              (loop (+ i 1)
                    (cond ((not (char=? c #\nul))
                           (string-append acc (string c)))
                          (else acc)))))))

    (define (%class-for-ere class)
      ;; CLASS is a bracket expression spelled as an *Emacs* pattern
      ;; spells it, and this is where the two dialects' text differs.
      ;; Two things are repaired, both measured rather than guessed:
      ;;
      ;;   1. A NUL - the C's `\000' - cannot go through `make-regexp',
      ;;      which hands the pattern to `regcomp' as a C string.
      ;;      `[^\000]' is "any character" and becomes `(.|<newline>)':
      ;;      under `regexp/newline' a `.` is every character but a
      ;;      newline, and the newline is named. A NUL as the *start of
      ;;      a range* becomes `\001', which is the same set - see
      ;;      `%without-nul'. A NUL anywhere else is a member that
      ;;      cannot be spelled and is dropped - and where it was the
      ;;      *first* member the `^' that follows it stops being first,
      ;;      so that one is escaped to stay the literal it was.
      ;;
      ;;   2. glibc reads `[.', `[:' and `[=' *inside* a bracket as the
      ;;      start of a collating element, a named character class and
      ;;      an equivalence class, where Emacs reads a literal `[' and
      ;;      then the character after it. So `[[.*+\^$?]', which Emacs
      ;;      reads as the eight characters `[ . * + \ ^ $ ?', makes
      ;;      glibc say "Unmatched [, [^, [:, [., or [=" - which is how
      ;;      `wildcard-to-regexp' found this. Escaping the character
      ;;      *after* such a `[' is what glibc takes (`[[\.*+\^$?]'
      ;;      matches `[' as Emacs does); escaping the `[' itself does
      ;;      not. `[:name:]' is a named class in both dialects and is
      ;;      left alone.
      ;;--------------------------------------------------------------
      (let* ((len (string-length class))
             (negated? (and (> len 1) (char=? #\^ (string-ref class 1))))
             (body (substring class (if negated? 2 1) (- len 1)))
             (bare (%without-nul body)))
        (cond
         ;; `[^\000]' is every character, and `regexp/newline' keeps `.`
         ;; from matching a newline, so the newline is named
         ((and negated? (string=? bare ""))
          (string-append "(.|" (string #\newline) ")"))
         (else
          (string-append
           "["
           (if negated? "^" "")
           (if (and (not negated?)
                    (> (string-length body) 0)
                    (char=? #\nul (string-ref body 0))
                    (> (string-length body) 1)
                    (char=? #\^ (string-ref body 1)))
               "\\"                        ; the `^' was not the first member
               "")
           (%escape-class-brackets bare)
           "]")))))

    (define (%escape-class-brackets members)
      ;; The `[.' / `[:' / `[=' repair of `%class-for-ere', over the
      ;; members of a class.
      ;;--------------------------------------------------------------
      (let ((len (string-length members)))
        (let loop ((i 0) (acc ""))
          (if (>= i len)
              acc
              (let ((c (string-ref members i)))
                (if (and (char=? c #\[)
                         (< (+ i 1) len)
                         (memv (string-ref members (+ i 1)) (list #\. #\: #\=))
                         (not (and (char=? (string-ref members (+ i 1)) #\:)
                                   (%named-class-at? members i))))
                    (loop (+ i 2)
                          (string-append acc "[" "\\"
                                         (string (string-ref members (+ i 1)))))
                    (loop (+ i 1) (string-append acc (string c)))))))))

    (define (%named-class-end text i)
      ;; The index just past the `]' of a `[:name:]' beginning at I in
      ;; TEXT, or #f when the `[' there does not begin one. A named
      ;; character class is `[:', a name, `:]', and both dialects read
      ;; it the same way - which is the whole reason the bracket walk
      ;; has to know where it ends.
      ;;--------------------------------------------------------------
      (and (char=? #\[ (string-ref text i))
           (< (+ i 1) (string-length text))
           (char=? #\: (string-ref text (+ i 1)))
           (let scan ((j (+ i 2)))
             (cond ((>= j (string-length text)) #f)
                   ((char=? #\: (string-ref text j))
                    (and (< (+ j 1) (string-length text))
                         (char=? #\] (string-ref text (+ j 1)))
                         (+ j 2)))
                   ((char=? #\] (string-ref text j)) #f)
                   (else (scan (+ j 1)))))))

    (define (%named-class-at? text i)
      ;; Whether the `[' at I in TEXT begins a `[:name:]'.
      ;;--------------------------------------------------------------
      (and (%named-class-end text i) #t))

    ;;----------------------------------------------------------------
    ;; `\w', `\W', `\sC' and `\SC': the syntax table's classes
    ;;
    ;; In Emacs these are not character classes at all - `regex-emacs.c'
    ;; asks `SYNTAX (c)' of every character it looks at - and glibc's
    ;; `\w' is the locale's `[[:alnum:]_]', which is a different set: the
    ;; standard syntax table gives `_' *symbol* syntax, so Emacs's `\w'
    ;; does not match it. The translation is therefore the set of
    ;; characters whose syntax class is the one asked for, spelled as an
    ;; ERE bracket expression.
    ;;
    ;; The set is enumerated over ASCII only, and the departure is named:
    ;; a class that a table gives to a character above 127 is not
    ;; expressible in a glibc bracket expression here (a range over
    ;; characters in the locale is refused - `[À-ÿ]' is "Invalid range
    ;; end"), and the classes the Lisp modes use have no such member:
    ;; every character above 127 has word syntax in their tables, and
    ;; glibc's own `\w' matches the letters among them.
    ;;------------------------------------------------------------------

    (define %syntax-class-cache '())
    ;; ^ ((TABLE . CLASS-CHAR) . ERE-CLASS), most recent first

    (define (%syntax-designator-class class-char)
      ;; The class number the designator CLASS-CHAR names, as
      ;; `string-to-syntax' reads it - `\s-' is whitespace, whose
      ;; `char-syntax' is a *space*; both designators name class 0.
      ;;--------------------------------------------------------------
      (let ((desc (string-to-syntax (string class-char))))
        (cond ((not desc) #f)
              ((pair? desc) (car desc))
              (else (logand desc #xFF)))))

    (define (%syntax-class-members table class-char)
      ;; The ASCII code points, ascending, whose syntax class in TABLE is
      ;; the one CLASS-CHAR designates.
      ;;--------------------------------------------------------------
      (let ((class (if (%syntax-designator-class class-char)
                       (syntax-class-to-char
                        (%syntax-designator-class class-char))
                       class-char)))
        (with-syntax-table table
          (lambda ()
            (let loop ((c 0) (acc '()))
              (cond ((>= c 128) (reverse acc))
                    ((char=? (char-syntax (integer->char c)) class)
                     ;; **A NUL is left out**: glibc hands the pattern to
                     ;; `regcomp' as a C string, so a NUL in it truncates
                     ;; the expression - the same wall `%without-nul'
                     ;; meets. A syntax class that contains NUL therefore
                     ;; does not match it through this translation.
                     (loop (+ c 1) (if (zero? c) acc (cons c acc))))
                    (else (loop (+ c 1) acc))))))))

    (define (%char-table-runs table from to)
      ;; The runs of code points FROM..TO over which TABLE's *inherited*
      ;; value is constant: ascending `(START END VALUE)'.
      ;;
      ;; `char_table_ref_and_range' (`chartab.c:320') narrows to a run of
      ;; the table's **own** values and does not consult the parent - its
      ;; own comment says so - and a syntax table is always inherited:
      ;; `copy-syntax-table' clears the default and sets the standard
      ;; table as the parent, which is the C's own line ("Only the
      ;; standard syntax table should have a default element"). So a
      ;; region the child does not set answers from the parent, and the
      ;; walk has to descend into it rather than read the child's nil as
      ;; a value. Without this every character above ASCII of every mode
      ;; was one run of the *standard* table's default, and `\w' matched
      ;; punctuation (`checkdoc.el''s `‘' came out word syntax).
      ;;--------------------------------------------------------------
      (let loop ((c from) (acc '()))
        (if (> c to)
            (reverse acc)
            (let ((f (list c)) (t (list to)))
              (let ((val (char-table-ref-and-range table c f t)))
                (let ((start (max from (car f)))
                      (end (min (car t) to)))
                  (cond
                   ((or (not val) (null? val))
                    ;; the child says nothing here: the parent answers
                    (let ((p (char-table-parent table)))
                      (if p
                          (loop (+ end 1)
                                (append (reverse (%char-table-runs p start end))
                                        acc))
                          (loop (+ end 1) (cons (list start end val) acc)))))
                   (else (loop (+ end 1) (cons (list start end val) acc))))))))))

    (define (%syntax-class-runs table class-char)
      ;; The runs of code points **above ASCII**, in TABLE, split by
      ;; whether their syntax class is the one CLASS-CHAR designates:
      ;; two answers, the matching runs and the ones that are not, each
      ;; ascending inclusive `(START . END)' pairs.
      ;;
      ;; `%syntax-class-members' enumerates the ASCII ones because there
      ;; are 128 of them; above ASCII an enumeration is the whole
      ;; character space, so the walk is over the *runs*
      ;; `%char-table-runs' answers and each run is one range in a
      ;; bracket expression. The walk stops at `#x10FFFF', the largest
      ;; character a Guile string can hold (`max-char' is `#x3FFFFF' and
      ;; `integer->char' refuses beyond it).
      ;;--------------------------------------------------------------
      (let ((class (if (%syntax-designator-class class-char)
                       (syntax-class-to-char
                        (%syntax-designator-class class-char))
                       class-char))
            (top #x10FFFF))
        (with-syntax-table table
          (lambda ()
            (let loop ((rs (%char-table-runs table 128 top)) (yes '()) (no '()))
              (cond
               ((null? rs) (values (reverse yes) (reverse no)))
               (else
                (let ((start (car (car rs))) (end (cadr (car rs))))
                  (if (char=? (char-syntax (integer->char start)) class)
                      (loop (cdr rs)
                            (if (and (pair? yes) (= start (+ (cdr (car yes)) 1)))
                                (cons (cons (car (car yes)) end) (cdr yes))
                                (cons (cons start end) yes))
                            no)
                      (loop (cdr rs) yes
                            (if (and (pair? no) (= start (+ (cdr (car no)) 1)))
                                (cons (cons (car (car no)) end) (cdr no))
                                (cons (cons start end) no))))))))))))

    (define (%runs-length runs)
      ;; The number of code points in RUNS.
      ;;--------------------------------------------------------------
      (let loop ((rs runs) (n 0))
        (if (null? rs) n
            (loop (cdr rs) (+ n 1 (- (cdr (car rs)) (car (car rs))))))))

    (define (%ere-class-runs-text runs)
      ;; RUNS, ascending inclusive `(START . END)' pairs above ASCII,
      ;; as the body of a bracket expression - **one code point at a
      ;; time**, not as `START-END'.
      ;;
      ;; A range in a glibc bracket expression is read in the *locale's
      ;; collation*, not in code-point order - `%ere-class-text''s
      ;; comment has the measurement for ASCII - and for the multibyte
      ;; blocks it fails outright: `\x7f-\xa0' and `←-ⱏ' are both
      ;; "Invalid range end" here. The data this is fed is small (the
      ;; non-`word' runs of a syntax table are 2344 code points in all,
      ;; measured on Emacs 31.1's standard table), so enumerating it is
      ;; what fits and what is right.
      ;;--------------------------------------------------------------
      (let loop ((rs runs) (acc '()))
        (cond ((null? rs) (apply string-append (reverse acc)))
              (else
               (let ((start (car (car rs))) (end (cdr (car rs))))
                 (loop (cdr rs)
                       (let inner ((c end) (a acc))
                         (if (< c start)
                             a
                             (inner (- c 1)
                                    (cons (string (integer->char c)) a))))))))))

    (define (%ere-class-join ascii-text range-text)
      ;; The ASCII members' body and the runs' body, joined so that the
      ;; two characters POSIX gives a special place keep it: `]' must be
      ;; first in the whole bracket expression (it is, `%ere-class-body'
      ;; puts it there) and `-' must be last - which it is not if the
      ;; runs are simply appended, and glibc then reads `-¤' as a range,
      ;; measured: "Invalid range end".
      ;;--------------------------------------------------------------
      (let ((n (string-length ascii-text)))
        (if (and (> n 0) (char=? (string-ref ascii-text (- n 1)) #\-))
            (string-append (substring ascii-text 0 (- n 1)) range-text "-")
            (string-append ascii-text range-text))))

    (define (%syntax-class-entry table class-char)
      ;; TABLE's CLASS-CHAR named as a bracket expression's body, as
      ;; `(COMPLEMENT? . BODY)': BODY is the text and COMPLEMENT? says
      ;; that the set BODY names is the *complement* of the class.
      ;;
      ;; **The smaller of the two is named**, because a syntax table is
      ;; mostly its default: `\w' has every character above ASCII, and
      ;; naming that positively asks glibc for the range
      ;; `\x80-\U10ffff', which its collation refuses - measured,
      ;; "Invalid collation character" - while its complement is the
      ;; handful of ASCII characters that are not word constituents.
      ;;--------------------------------------------------------------
      (call-with-values (lambda () (%syntax-class-runs table class-char))
        (lambda (yes no)
          (let* ((ascii-yes (%syntax-class-members table class-char))
                 (ascii-no (let loop ((c 1) (acc '()))
                             (cond ((>= c 128) (reverse acc))
                                   ((memv c ascii-yes) (loop (+ c 1) acc))
                                   (else (loop (+ c 1) (cons c acc))))))
                 (yes-count (+ (length ascii-yes) (%runs-length yes)))
                 (no-count (+ (length ascii-no) (%runs-length no))))
            (cond
             ((and (null? ascii-yes) (null? yes))
              ;; the class is empty; `%syntax-class-ere' spells it
              (cons #f ""))
             ((<= yes-count no-count)
              (cons #f (%ere-class-join (%ere-class-body ascii-yes)
                                        (%ere-class-runs-text yes))))
             (else
              (cons #t (%ere-class-join (%ere-class-body ascii-no)
                                        (%ere-class-runs-text no)))))))))

    (define (%ere-class-escape c)
      ;; The code point C as one member of a bracket expression.
      ;;
      ;; **Nothing is escaped**, because POSIX gives backslash no special
      ;; meaning *inside* a bracket expression and glibc does not add one:
      ;; `[\\]' is the two characters `\' and `\', and `\^' is `\'
      ;; *and* `^' - measured. So the three characters that do have a
      ;; meaning there are placed rather than escaped: `]' first, `^'
      ;; anywhere but first, `-' last (`%ere-class-body').
      ;;--------------------------------------------------------------
      (string (integer->char c)))

    (define (%ere-class-text members)
      ;; MEMBERS, ascending code points, as the body of a bracket
      ;; expression.
      ;;
      ;; **One member at a time, not ranges.** A range in a glibc bracket
      ;; expression is read in the *locale's collation*, not in code-point
      ;; order: `[<-_]' is "Invalid range end" in the en_US.UTF-8 locale,
      ;; where `_' collates before `<'. Emacs's own matcher compares
      ;; characters, so the only class that means the same in both is an
      ;; enumeration.
      ;;--------------------------------------------------------------
      (let loop ((rest members) (acc '()))
        (if (null? rest)
            (apply string-append (reverse acc))
            (loop (cdr rest) (cons (%ere-class-escape (car rest)) acc)))))

    (define (%ere-class-body members)
      ;; MEMBERS as a bracket expression's body, in the positions POSIX
      ;; gives each character a literal meaning in: "`]' as the first
      ;; character stands for itself", `^' anywhere but first, and a `-'
      ;; last is not a range operator.
      ;;--------------------------------------------------------------
      (let loop ((rest members) (close? #f) (caret? #f) (dash? #f) (rest2 '()))
        (cond ((null? rest)
               (string-append (if close? "]" "")
                              (%ere-class-text (reverse rest2))
                              (if caret? "^" "")
                              (if dash? "-" "")))
              ((= (car rest) 93) (loop (cdr rest) #t caret? dash? rest2))
              ((= (car rest) 94) (loop (cdr rest) close? #t dash? rest2))
              ((= (car rest) 45) (loop (cdr rest) close? caret? #t rest2))
              (else (loop (cdr rest) close? caret? dash? (cons (car rest) rest2))))))

    (define (%syntax-class-ere table class-char negated?)
      ;; TABLE's CLASS-CHAR as an ERE bracket expression, or its
      ;; complement when NEGATED?.
      ;;--------------------------------------------------------------
      (let* ((key (cons table class-char))
             (hit (assoc key %syntax-class-cache))
             (entry (if hit
                        (cdr hit)
                        (let ((e (%syntax-class-entry table class-char)))
                          (set! %syntax-class-cache
                                (cons (cons key e) %syntax-class-cache))
                          e)))
             ;; `(COMPLEMENT? . BODY)': BODY names the class, or its
             ;; complement - see `%syntax-class-entry'.
             (complement? (car entry))
             (body (cdr entry)))
        (cond
         ;; The body is empty, so the set it names is empty; the other
         ;; extreme is written as the locale's every character.
         ;; `[[:print:][:cntrl:]]' is that set; the brackets are still
         ;; brackets rather than `regexp-unmatchable', so the expression
         ;; can be quantified (`\s-+' has to compile).
         ((string=? body "")
          (if (eq? complement? negated?)
              ;; the class itself is the one written, and it is empty
              (if negated? "[[:print:][:cntrl:]]" "[^[:print:][:cntrl:]]")
              ;; the class is every character, and its complement is what
              ;; is written
              (if negated? "[^[:print:][:cntrl:]]" "[[:print:][:cntrl:]]")))
         (else (string-append "[" (if (eq? complement? negated?) "" "^")
                              body "]")))))

    (define (%numbered-group-end pattern j)
      ;; The index just past the `:' of a `(?N:' beginning at J, where J
      ;; points at the first digit.
      ;;--------------------------------------------------------------
      (let loop ((k j))
        (if (char=? (string-ref pattern k) #\:) (+ k 1) (loop (+ k 1)))))

    (define (%numbered-group-colon pattern j)
      ;; Whether the text at J in PATTERN is `<digits>:' - the inside of a
      ;; `\(?N:...\)' group.
      ;;--------------------------------------------------------------
      (let loop ((k j))
        (cond ((>= k (string-length pattern)) #f)
              ((char=? (string-ref pattern k) #\:) (> k j))
              ((char-numeric? (string-ref pattern k)) (loop (+ k 1)))
              (else #f))))

    (define (%numbered-group-number pattern j)
      ;; The N of a `(?N:' whose digits begin at J.
      ;;--------------------------------------------------------------
      (string->number (substring pattern j
                                 (- (%numbered-group-end pattern j) 1))))

    (define (%translate-emacs-regexp pattern table)
      ;; An Emacs regexp spelled as the Emacs regexp dialect spells
      ;; it, into the ERE that matches the same: the group, alternation
      ;; and interval syntax swaps the escaped and unescaped forms -
      ;; `\(' is a group here and a literal there - and what is
      ;; special in ERE unescaped (`(' `)' `|' `{') is literal in an
      ;; Emacs pattern, so it is escaped. Bracket expressions are
      ;; copied verbatim, the way both dialects read them.
      ;;--------------------------------------------------------------
      ;; The group numbers are the second answer. Emacs's match data is
      ;; numbered by *its* groups, and glibc's by the `('s this
      ;; translation emits - which are not the same set, because a shy
      ;; group `\(?:...\)' has no number in Emacs and needs a group
      ;; here. `mapping' records which glibc group holds which Emacs
      ;; group, and `%string-match-into-regs' renumbers through it.
      ;;
      ;; **One Emacs group may be several glibc groups.** `\(?N:' is how
      ;; a Lisp keyword regexp shares a group number between the
      ;; alternatives of a `\|' - `\(?1:a\)\|\(?1:b\)' is Emacs group 1
      ;; either way - and glibc cannot make two groups one register. The
      ;; mapping therefore holds a *list* per Emacs group, and the one
      ;; that matched is the register's value. Found through font-lock's
      ;; "No match 1 in highlight" on `easy-mmode.el'.
      (let ((next-group 1)
            (glibc-groups 0)
            (mapping '())
            ;; The `\_<'/`\_>' assertions: `(GLIBC-GROUP . KIND)' for each,
            ;; checked against the syntax table after the match - see
            ;; `%assertions-hold-buffer?'.
            (assertions '()))
        (define (group-mapping)
          ;; Entry I is the glibc group, or the list of them, that holds
          ;; Emacs group I.
          ;;----------------------------------------------------------
          (let ((v (make-vector next-group 0)))
            (vector-set! v 0 0)
            (for-each
             (lambda (p)
               (let ((n (car p)) (g (cdr p)))
                 (vector-set! v n
                              (if (eqv? 0 (vector-ref v n))
                                  g
                                  (let ((old (vector-ref v n)))
                                    (if (list? old)
                                        (append old (list g))
                                        (list old g)))))))
             mapping)
            v))
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length pattern))
            (values (list->string (reverse acc)) (group-mapping)
                    (reverse assertions))
            (let ((c (string-ref pattern i)))
              (cond
               ;; a bracket expression: copied to its `]', with one
               ;; repair - see `%class-for-ere'
               ((char=? c #\[)
                (let scan ((j (+ i 1)) (seen-start #f) (members '()))
                  (cond
                   ((>= j (string-length pattern))
                    ;; an unclosed bracket: Emacs's matcher says
                    ;; "Unmatched [" and so does glibc - copy the rest
                    ;; and let the compiler reject it
                    (loop (string-length pattern)
                          (append (reverse
                                   (string->list
                                    (string-append
                                     "["
                                     (list->string (reverse members)))))
                                  acc)))
                   ((and (char=? (string-ref pattern j) #\])
                         ;; a `]' first in the set is its own member
                         (or seen-start (>= j (+ i 2))))
                    ;; MEMBERS is consed, so it is in reverse; the
                    ;; class text is put into ACC - which is itself the
                    ;; text reversed - reversed again, so that the one
                    ;; reverse at the end of this walk turns it the
                    ;; right way round. Appending it the other way is
                    ;; what once turned `[0-9]' into `]9-0['.
                    (let ((class (%class-for-ere
                                  (list->string
                                   (append (list #\[)
                                           (reverse members)
                                           (list #\]))))))
                      (loop (+ j 1)
                            (append (reverse (string->list class)) acc))))
                   (else
                    (let ((named (and (char=? (string-ref pattern j) #\[)
                                      (%named-class-end pattern j))))
                      (if named
                          ;; A `[:name:]' is copied whole, so that its
                          ;; own `]' does not close the set it stands
                          ;; in. Closing there is what turned
                          ;; `[[:alnum:]_]' into the named class
                          ;; followed by a literal `_]', and what the
                          ;; environment-variable regexp's
                          ;; `[[:alnum:]_]+' then stopped matching.
                          (let copy ((k j) (members members))
                            (if (>= k named)
                                (scan named #t members)
                                (copy (+ k 1)
                                      (cons (string-ref pattern k) members))))
                          (scan (+ j 1)
                                (or seen-start
                                    (not (char=? (string-ref pattern j) #\^)))
                                (cons (string-ref pattern j) members))))))))
               ((char=? c #\\)
                (if (>= (+ i 1) (string-length pattern))
                    (error "Trailing backslash in regexp" pattern)
                    (let ((c2 (string-ref pattern (+ i 1))))
                      (cond
                       ;; **A shy group comes first, because `\(' is taken
                       ;; by the swap below.** Emacs's own default
                       ;; `file-coding-system-alist' has an entry using one
                       ;; - `\\(?:tgz\\|svgz\\|sifz\\)' - so refusing
                       ;; them made that alist uncompilable.
                       ;; `\\(?:RE\\)' and `\\(RE\\)' accept exactly
                       ;; the same language; the only difference is whether
                       ;; the group takes a match-data slot, and this engine
                       ;; renumbers shy groups anyway (see the header). So
                       ;; the `?:' is dropped and the group is made
                       ;; ordinary.
                       ;;
                       ;; `\\(?N:M\\)' and `\\(?-N:M\\)' *number* the
                       ;; group, which is a different thing, and still have
                       ;; no ERE spelling.
                       ;; `\(' '?' ':' - the *fourth* character is the
                       ;; colon, and the second is the paren, which is why
                       ;; this sits in the `\(' branch and not the `\?'
                       ;; one.
                       ((and (char=? c2 #\()
                             (< (+ i 3) (string-length pattern))
                             (char=? (string-ref pattern (+ i 2)) #\?)
                             (char=? (string-ref pattern (+ i 3)) #\:))
                        (set! glibc-groups (+ glibc-groups 1))
                        (loop (+ i 4) (cons #\( acc)))
                       ;; `\(?N:...\)' - a group with a *chosen* number.
                       ;; `rx''s `(group-n N ...)' is the spelling, and
                       ;; the Lisp keyword tables use it.
                       ((and (char=? c2 #\()
                             (< (+ i 3) (string-length pattern))
                             (char=? (string-ref pattern (+ i 2)) #\?)
                             (%numbered-group-colon pattern (+ i 3)))
                        (let ((n (%numbered-group-number pattern (+ i 3))))
                          (set! glibc-groups (+ glibc-groups 1))
                          (set! mapping (cons (cons n glibc-groups) mapping))
                          (set! next-group (max next-group (+ n 1)))
                          (loop (%numbered-group-end pattern (+ i 3))
                                (cons #\( acc))))
                       ;; a plain `\(' - a capturing group, and the next
                       ;; number Emacs would give it
                       ((char=? c2 #\()
                        (set! glibc-groups (+ glibc-groups 1))
                        (set! mapping (cons (cons next-group glibc-groups)
                                            mapping))
                        (set! next-group (+ next-group 1))
                        (loop (+ i 2) (cons #\( acc)))
                       ;; the escaped-and-special-to-ERE swaps
                       ((memv c2 '(#\) #\| #\{ #\}))
                        (loop (+ i 2) (cons c2 acc)))
                       ;; `\w' and `\W': the syntax table's word class,
                       ;; which is not glibc's `\w' - see
                       ;; `%syntax-class-ere'.
                       ((memv c2 '(#\w #\W))
                        (loop (+ i 2)
                              (append (reverse
                                       (string->list
                                        (%syntax-class-ere
                                         table #\w (char=? c2 #\W))))
                                      acc)))
                       ;; `\sC' and `\SC': the syntax class C.
                       ((memv c2 '(#\s #\S))
                        (if (>= (+ i 2) (string-length pattern))
                            (error "Invalid syntax class" pattern)
                            (loop (+ i 3)
                                  (append (reverse
                                           (string->list
                                            (%syntax-class-ere
                                             table
                                             (string-ref pattern (+ i 2))
                                             (char=? c2 #\S))))
                                          acc))))
                       ;; `\_<' and `\_>': the *symbol* boundary. It is a
                       ;; zero-width test of the buffer's syntax table, and
                       ;; no regexp substrate can make one - glibc has the
                       ;; *word* boundary `\<'/`\>' and nothing aware of
                       ;; `SYNTAX (c)'. So the ERE gets an **empty group**
                       ;; where the boundary goes, and the match is checked
                       ;; against the syntax table afterwards; a match whose
                       ;; assertion fails is refused and the search asks
                       ;; again from the next position - which is what the
                       ;; C's backtracking does, one layer up. The group is
                       ;; glibc's alone: `\_<' takes no Emacs group number,
                       ;; so `mapping' is not told about it.
                       ((and (char=? c2 #\_)
                             (< (+ i 2) (string-length pattern))
                             (memv (string-ref pattern (+ i 2)) '(#\< #\>)))
                        (set! glibc-groups (+ glibc-groups 1))
                        (set! assertions
                              (cons (cons glibc-groups
                                          (if (char=? (string-ref pattern (+ i 2)) #\<)
                                              'symbeg
                                              'symend))
                                    assertions))
                        (loop (+ i 3) (cons #\) (cons #\( acc))))
                       ;; `\<', `\>', `\b' and `\B' are the *syntax
                       ;; table's* word class (`regex-emacs.c:5424',
                       ;; `:5465', `:5379'), and glibc's word class is
                       ;; the locale's - so the two disagree wherever a
                       ;; table says `$' or `%' or, in scheme-mode's
                       ;; font-lock table, `-' is a word constituent.
                       ;; They are assertions like `\_<' - see
                       ;; `%assertions-hold-buffer?'.
                       ((memv c2 '(#\< #\> #\b #\B))
                        (set! glibc-groups (+ glibc-groups 1))
                        (set! assertions
                              (cons (cons glibc-groups
                                          (case c2
                                            ((#\<) 'wordbeg)
                                            ((#\>) 'wordend)
                                            ((#\b) 'wordbound)
                                            (else 'notwordbound)))
                                    assertions))
                        (loop (+ i 2) (cons #\) (cons #\( acc))))
                       ((%pass-through-escape c2)
                        (loop (+ i 2) (cons c2 (cons #\\ acc))))
                       ((%untranslated-escape c2)
                        (error "Regexp escape this engine does not implement"
                               (string #\\ c2)))
                       ((char=? c2 #\?)
                        (error "Regexp escape this engine does not implement" "\\(?"))
                       (else
                        ;; anything else: the character itself, as
                        ;; regex-emacs.c's backslash default does
                        (loop (+ i 2) (cons c2 acc)))))))
               ;; ERE specials that are literal in an Emacs pattern
               ((memv c '(#\( #\) #\| #\{))
                (loop (+ i 1) (cons c (cons #\\ acc))))
               (else (loop (+ i 1) (cons c acc)))))))))

    (define (%regexp-cache-lookup key)
      ;; The cache entry for KEY - `(KEY REGEXP GROUP-MAP)' - or #f. KEY is
      ;; `(PATTERN ICASE TABLE)', and `assoc' would compare it with
      ;; `equal?' - which walks the whole char-table - so the parts are
      ;; compared here.
      ;;--------------------------------------------------------------
      (let loop ((l %regexp-cache))
        (cond ((null? l) #f)
              ((and (string=? (car key) (car (car (car l))))
                    (eq? (list-ref key 1) (list-ref (car (car l)) 1))
                    (eq? (list-ref key 2) (list-ref (car (car l)) 2)))
               (car l))
              (else (loop (cdr l))))))

    (define %current-group-map #f)
    ;; ^ The group mapping of the pattern compiled last, which is the one
    ;; the match about to be read belongs to - see
    ;; `%string-match-into-regs'.

    (define %current-assertions '())
    ;; ^ The `\_<'/`\_>' assertions of the pattern compiled last
    ;; (`(GLIBC-GROUP . symbeg-or-symend)'), which the match about to be
    ;; read must satisfy before it is a match at all.

    (*internal-syntax-propertize-function*
     (lambda (thunk)
       ;; `internal--syntax-propertize''s `save-match-data'
       ;; (`syntax.el:481'), installed from here because
       ;; `save-match-data' is this library's and `(schemacs editor
       ;; syntax)' is below it. This runs *from inside a regexp match*:
       ;; the mode's propertize function runs searches of its own, and
       ;; without the save they overwrite the match data of the match
       ;; being attempted - font-lock reported "No match %s in
       ;; highlight" on a file whose `syntax-propertize-function' had not
       ;; run yet. The compile-time globals are saved with it, for the
       ;; same reason: a nested search compiles patterns too.
       ;;--------------------------------------------------------------
       (save-match-data
         (let ((map %current-group-map)
               (assertions %current-assertions))
           (dynamic-wind
             (lambda () #f)
             thunk
             (lambda ()
               (set! %current-group-map map)
               (set! %current-assertions assertions)))))))

    (define (%compile-emacs-regexp pattern icase?)
      ;; Compile PATTERN as an Emacs pattern: through `%emacs-ere',
    ;; with a cache standing for `regexp_cache'.
      ;;
      ;; The syntax table is part of the key because `\w' and `\sC' are
      ;; read from it - see `%syntax-class-ere'. The buffer's own, or the
      ;; standard table when a match is asked for outside any buffer.
      ;;--------------------------------------------------------------
      (let* ((table (if (current-buffer) (syntax-table) (standard-syntax-table)))
             (key (list pattern icase? table)))
        (cond
         ((let ((hit (%regexp-cache-lookup key)))
            (and hit
                 (begin (set! %current-group-map (car (cddr hit)))
                        (set! %current-assertions (car (cdddr hit)))
                        (cadr hit)))))
         (else
          ;; `regexp/newline' is what makes `^' and `$' mean what they
          ;; mean to Emacs: the start and end of a *line*, not of the
          ;; whole string. It settles two things at once, and both were
          ;; wrong without it - measured against this machine's Emacs:
          ;; `(string-match "^b" "a\nb")' is 2 there and was #f here, and
          ;; `(string-match "a.b" "a\nb")' is nil there and was 0 here,
          ;; because Emacs's `.' does not match a newline and POSIX's
          ;; does until this flag is given. The string anchors `\`' and
          ;; `\'' keep their own meaning under it.
          ;;
          ;; **The flags are ONE integer, and it must not be 0.**
          ;; `make-regexp' takes any number of flag arguments, and a list
          ;; containing a 0 makes Guile compile a POSIX *basic* regular
          ;; expression - measured: `(make-regexp "a|b" 0)' matches only
          ;; the literal "a|b", while `(make-regexp "a|b" 4)' matches
          ;; "a". So the ERE this translator produces - `(', `)', `|',
          ;; `+', `?', `{' - would be read literally. The call here used
          ;; to pass `(if icase? regexp/icase 0)' beside
          ;; `regexp/newline', which means **every case-sensitive search
          ;; was compiled as a basic regexp**: with `case-fold-search'
          ;; nil, `(string-match "a\\|b" "b")' answered #f where Emacs
          ;; answers 0, and `"a+"' matched only a literal "a+". Found by
          ;; `abbreviate-file-name', which binds `case-fold-search' to
          ;; `file-name-case-insensitive-p' (nil here) and whose own
          ;; pattern is `\\(/\\|\\'\\)'.
          (let-values (((translated map assertions)
                        (%translate-emacs-regexp pattern table)))
          (let ((rx (make-regexp translated
                                 (logior (if icase? regexp/icase 0)
                                         regexp/newline))))
            (set! %current-group-map map)
            (set! %current-assertions assertions)
            (set! %regexp-cache
                  (cons (list key rx map assertions)
                        (let trim ((l %regexp-cache) (n 0))
                          (cond ((>= n 16) '())
                                ((null? l) '())
                                (else (cons (car l)
                                            (trim (cdr l) (+ n 1))))))))
            rx))))))

    ;;----------------------------------------------------------------
    ;; The searches
    ;;------------------------------------------------------------------

    (define (%string-match-into-regs match)
      ;; The registers a Guile match object holds, as ours: the C's
      ;; `re_match' fills `search_regs' with what the pattern matched,
      ;; zero-based for a string, `#f' where a subexpression did not
      ;; match. The register count only grows, as the file header says
      ;; - the C's `set_search_regs' and `re_match' both clear, neither
      ;; shrinks.
      ;;
      ;; **The group numbers are renumbered through the pattern's
      ;; mapping**: a register is an *Emacs* group, and glibc numbered
      ;; its groups differently wherever a shy or numbered group was in
      ;; the pattern. `%current-group-map' is the mapping of the pattern
      ;; compiled last, which is this match's.
      ;;--------------------------------------------------------------
      (let* ((map %current-group-map)
             (glibc-groups (match:count match))
             (ours (if map (vector-length map) glibc-groups))
             (n (max ours (length (or (*search-regs*) '()))))
             (regs (make-list n #f)))
        (let loop ((i 0))
          (when (< i ours)
            (let* ((g (if map (vector-ref map i) i))
                   ;; One Emacs group may be several glibc groups when the
                   ;; pattern spells `\(?N:' in more than one alternative;
                   ;; the one that matched is the register.
                   (found (let scan ((gs (if (list? g) g (list g))))
                            (cond ((null? gs) #f)
                                  ((< (car gs) glibc-groups)
                                   (let ((s (match:start match (car gs))))
                                     (if s
                                         (cons s (match:end match (car gs)))
                                         (scan (cdr gs)))))
                                  (else (scan (cdr gs)))))))
              (if found (list-set! regs i found) #f))
            (loop (+ i 1))))
        (*search-regs* regs)))

    (define (%bol-flags text start)
      ;; The flags for a match that begins at START of TEXT: `0' when
      ;; START is a real beginning of line, `regexp/notbol' when it is
      ;; not.
      ;;
      ;; It has to be said, because glibc takes the offset
      ;; `regexp-exec' is handed as a beginning of line whether or not
      ;; it is one - `(regexp-exec (make-regexp "^b" regexp/newline)
      ;; "ab" 1)' matches at 1, where Emacs's `re_search', handed the
      ;; whole string and the position, reads the character before the
      ;; position and answers nil. This flag is how it is told
      ;; otherwise. And *when* to pass it is a real question, not the
      ;; `start = 0' guess it used to be: `(string-match "^b" "a\nb"
      ;; 2)' is 2 in Emacs, because 2 is the beginning of a line, so a
      ;; `^' that cannot match there makes `re-search-forward "^abc"'
      ;; from the start of a line miss the very line it stands on.
      ;;--------------------------------------------------------------
      (if (and (> start 0)
               (not (char=? #\newline (string-ref text (- start 1)))))
          regexp/notbol
          0))

    ;;----------------------------------------------------------------
    ;; The `\_<' and `\_>' assertions (`regex-emacs.c:5508', `:5549')
    ;;----------------------------------------------------------------

    (define (%symbol-char-at ed pos)
      ;; `SYNTAX (c)' at POS tested as the symbol boundary tests it:
      ;; `Sword' or `Ssymbol'. Read through the syntax-table property, as
      ;; every `SYNTAX (c)' is.
      ;;--------------------------------------------------------------
      (memv (%class-in ed pos (char->integer (fetch-char ed pos)))
            (list sword ssymbol)))

    (define (%word-char-at ed pos)
      ;; `SYNTAX (c)' at POS tested as the *word* boundary tests it:
      ;; `Sword' alone, where the symbol boundary accepts `Ssymbol' as
      ;; well. (`WORD_BOUNDARY_P', which the C also consults, is `#f'
      ;; here - see `%word-boundary?'.)
      ;;--------------------------------------------------------------
      (memv (%class-in ed pos (char->integer (fetch-char ed pos)))
            (list sword)))

    (define (%assertions-hold-buffer? match base)
      ;; Whether the `\_<'/`\_>' assertions of the pattern compiled last
      ;; hold at MATCH's positions. The C tests them inside its matcher;
      ;; this engine cannot, so the match is refused and the search asks
      ;; again - `%re-search-forward-1' does that, which is the C's
      ;; backtracking one layer up.
      ;;
      ;; "Case 2: S2 is neither Sword nor Ssymbol" / "Case 3: ... S1 is
      ;; Sword or Ssymbol" (`regex-emacs.c:5508'): a symbol begins where
      ;; a symbol constituent follows a non-constituent, and ends where
      ;; one is followed by a non-constituent.
      ;;--------------------------------------------------------------
      (or (null? %current-assertions)
          (let ((ed (current-buffer)))
            (%setup-syntax-table)
            (let loop ((l %current-assertions))
              (cond
               ((null? l) #t)
               (else
                (let ((pos0 (match:start match (caar l))))
                 ;; An assertion in an alternative that did not match has
                 ;; no position (`match:start' answers #f); the C never
                 ;; reached it, so there is nothing to test.
                 (if (not pos0)
                     (loop (cdr l))
                     (let ((pos (+ base pos0)))
                  (if (case (cdar l)
                        ((symbeg)
                         (and (< pos (buffer-z ed))
                              (%symbol-char-at ed pos)
                              (or (= pos (buffer-beg ed))
                                  (not (%symbol-char-at ed (- pos 1))))))
                        ((symend)
                         (and (> pos (buffer-beg ed))
                              (%symbol-char-at ed (- pos 1))
                              (or (>= pos (buffer-z ed))
                                  (not (%symbol-char-at ed pos)))))
                        ;; "Case 1: D is at the end of string"; "Case 2:
                        ;; S2 is not Sword"; "Case 3: ... S1 is Sword"
                        ;; (`regex-emacs.c:5424').
                        ((wordbeg)
                         (and (< pos (buffer-z ed))
                              (%word-char-at ed pos)
                              (or (= pos (buffer-beg ed))
                                  (not (%word-char-at ed (- pos 1))))))
                        ((wordend)
                         (and (> pos (buffer-beg ed))
                              (%word-char-at ed (- pos 1))
                              (or (>= pos (buffer-z ed))
                                  (not (%word-char-at ed pos)))))
                        ;; `wordbound' (`regex-emacs.c:5379'): "Case 1:
                        ;; D is at the beginning or the end of string" is
                        ;; a boundary; otherwise it is where exactly one
                        ;; side is `Sword'.
                        ((wordbound)
                         (or (= pos (buffer-beg ed))
                             (>= pos (buffer-z ed))
                             (not (eq? (and (%word-char-at ed (- pos 1)) #t)
                                       (and (%word-char-at ed pos) #t)))))
                        ((notwordbound)
                         (and (> pos (buffer-beg ed))
                              (< pos (buffer-z ed))
                              (eq? (and (%word-char-at ed (- pos 1)) #t)
                                   (and (%word-char-at ed pos) #t))))
                        (else #f))
                      (loop (cdr l))
                      #f))))))))))

    (define (%string-symbol-char? string i)
      ;; The same test on a string: Emacs reads the *current buffer's*
      ;; syntax table for a string search, and a string has no
      ;; text properties, so `char-syntax' is the whole of it.
      ;;--------------------------------------------------------------
      (memv (char-syntax (string-ref string i)) (list #\w #\_)))

    (define (%string-word-char? string i)
      ;; The word test on a string, as `%string-symbol-char?' is the
      ;; symbol one.
      ;;--------------------------------------------------------------
      (char=? (char-syntax (string-ref string i)) #\w))

    (define (%assertions-hold-string? match string)
      (or (null? %current-assertions)
          (let ((n (string-length string)))
            (let loop ((l %current-assertions))
              (cond
               ((null? l) #t)
               (else
                (let ((pos (match:start match (caar l))))
                 (if (not pos)
                     (loop (cdr l))
                  (if (case (cdar l)
                        ((symbeg)
                         (and (< pos n)
                              (%string-symbol-char? string pos)
                              (or (= pos 0)
                                  (not (%string-symbol-char? string (- pos 1))))))
                        ((symend)
                         (and (> pos 0)
                              (%string-symbol-char? string (- pos 1))
                              (or (= pos n)
                                  (not (%string-symbol-char? string pos)))))
                        ((wordbeg)
                         (and (< pos n)
                              (%string-word-char? string pos)
                              (or (= pos 0)
                                  (not (%string-word-char? string (- pos 1))))))
                        ((wordend)
                         (and (> pos 0)
                              (%string-word-char? string (- pos 1))
                              (or (= pos n)
                                  (not (%string-word-char? string pos)))))
                        ((wordbound)
                         (or (= pos 0) (= pos n)
                             (not (eq? (%string-word-char? string (- pos 1))
                                       (%string-word-char? string pos)))))
                        ((notwordbound)
                         (and (> pos 0) (< pos n)
                              (eq? (%string-word-char? string (- pos 1))
                                   (%string-word-char? string pos))))
                        (else #f))
                      (loop (cdr l))
                      #f)))))))))

    (define (string-match pattern string . args)
      ;; GNU Emacs's `string-match' (search.c:442): "Return index of
      ;; start of string match for REGEXP in STRING, or nil." The
      ;; optional START is where to begin, and the optional
      ;; INHIBIT-MODIFY keeps the match data alone (the C's newer
      ;; fourth argument); the C's older calls pass only START. The
      ;; match data records the match with ZERO-based string
      ;; positions, and `*last-thing-searched*' becomes the symbol
      ;; `string' - the C's `Qt'. Case folding follows
      ;; `case-fold-search', as the C's `string_match_1' reads the
      ;; buffer's value.
      ;;--------------------------------------------------------------
      (let* (;; "If NILP (start) pos = 0" (`search.c:384`). A nil START is
             ;; 0, not a number to compare - `string-trim` passes nil
             ;; here whenever the leading trim did not match, which is
             ;; the ordinary case.
             (start (if (pair? args) (or (car args) 0) 0))
             (inhibit (and (pair? args) (pair? (cdr args)) (cadr args)))
             (len (string-length string))
             ;; "if (pos < 0 && -pos <= len) pos = len + pos; else if
             ;; (0 > pos || pos > len) args_out_of_range"
             (start (cond ((and (< start 0) (<= (- start) len))
                           (+ len start))
                          ((or (< start 0) (> start len))
                           (error "Args out of range: ~a, ~a" string start))
                          (else start)))
             (icase? (*case-fold-search*)))
        (let scan ((start start))
          (let ((m (regexp-exec (%compile-emacs-regexp pattern icase?)
                                string start
                                (%bol-flags string start))))
            (cond
             ((not m) #f)
             ;; A `\_<' or `\_>' that does not hold here is not a match;
             ;; ask again from the next character, as the C's matcher
             ;; backtracks.
             ((not (%assertions-hold-string? m string))
              (let ((next (+ (match:start m 0) 1)))
                (if (> next len) #f (scan next))))
             (inhibit (match:start m 0))
             (else
              (%string-match-into-regs m)
              (*last-thing-searched* 'string)
              (match:start m 0)))))))

    (define (string-match-p regexp string . rest)
      ;; GNU Emacs's `string-match-p' (subr.el:5946): "Same as
      ;; `string-match' except this function does not change the match
      ;; data."
      ;;
      ;; It is `subr.el''s and it is here for the same reason
      ;; `looking-at-p' is: `(schemacs editor subr)' is *below* this
      ;; library, so subr cannot reach `string-match'. The C's fourth
      ;; argument, INHIBIT-MODIFY, is how `string-match' itself says it.
      ;;--------------------------------------------------------------
      (string-match regexp string (if (pair? rest) (car rest) 0) #t))

    (define (looking-at-p regexp)
      ;; GNU Emacs's `looking-at-p' (subr.el): "Same as `looking-at'
      ;; except this function does not change the match data."
      ;;
      ;; It is `subr.el''s, and it is here rather than in
      ;; `(schemacs editor subr)' because that library is *below* this
      ;; one: `simple' imports `subr' and this library imports `simple',
      ;; so subr cannot reach `looking-at'. This tree moves a function
      ;; down to the library that can hold it and says so, as
      ;; `goto-line' is in `minibuffer.sld' for the same reason.
      ;;--------------------------------------------------------------
      (save-match-data (looking-at regexp)))

    (define (looking-at regexp)
      ;; GNU Emacs's `looking-at' (search.c:347): "Return t if point is
      ;; right at the start of a match for REGEXP" - the match does not
      ;; move point, and the match data is the buffer's, one-based.
      ;;
      ;; The C is `re_match_2 (..., PT_BYTE - BEGV_BYTE, ...)', which
      ;; is an *anchored* match at point: the regexp has to match
      ;; *there*, not merely somewhere after it. Guile's `regexp-exec'
      ;; searches forward from the offset it is handed, so the anchor
      ;; must be asked for - and leaving it out made `looking-at-p' on a
      ;; two-space pattern answer t on a buffer whose first line is
      ;; `total 7', because there are two spaces further down the
      ;; listing. That was dired's own indent never firing: its
      ;; `looking-at-p' guard read t on an unindented listing and the
      ;; function concluded someone else had indented it already.
      ;;
      ;; The text searched is a window of the buffer that begins one
      ;; character before point, so `^' is judged against the real
      ;; character in front of it, and doubles until the match ends
      ;; inside it. It used to be the whole buffer - `re_match_2''s
      ;; `p1', which costs nothing in C and costs this tree the buffer
      ;; twice, once to copy it and once inside `regexp-exec', whose cost
      ;; is proportional to the string's length. Measured: 300 calls on a
      ;; 257 KB buffer were 7.7 s; a match at point needs a line.
      ;;--------------------------------------------------------------
      (with-current-buffer (current-buffer)
        (let* ((ed (current-buffer))
               (from (buffer-pt ed))
               (base (max (buffer-beg ed) (- from 1)))
               (z (buffer-z ed))
               (compiled (%compile-emacs-regexp regexp (*case-fold-search*))))
          (let try ((wend (min z (+ from %search-chunk))) (span %search-chunk))
            (let* ((text (make-buffer-string ed base wend))
                   (here (- from base))
                   (m (regexp-exec compiled text here (%bol-flags text here))))
              (cond
               ;; "right at the start of a match": a match further along
               ;; is not one at point, and answers the C's `-1' / nil.
               ((or (not m) (not (= (match:start m 0) here))) #f)
               ;; A `\_<' or `\_>' that does not hold here is not a
               ;; match at point.
               ((not (%assertions-hold-buffer? m base)) #f)
               ;; A match ending at the window's edge may have matched
               ;; `$' or `\b' against the edge rather than the buffer;
               ;; widen and ask again.
               ((and (= (match:end m 0) (- wend base)) (< wend z))
                (try (min z (+ wend span)) (* 2 span)))
               (else
                (%string-match-into-regs m)
                ;; the window's first position is what the offsets are
                ;; relative to
                (match-data--translate base)
                (*last-thing-searched* (current-buffer))
                #t)))))))

    (define (looking-back regexp . args)
      ;; GNU Emacs's `looking-back' (`subr.el:5907'): "Return non-nil if
      ;; text before point matches regular expression REGEXP. Like
      ;; `looking-at' except matches before point, and is slower."
      ;;
      ;; The C searches backward for `\(?:REGEXP\)\=' - a match
      ;; *ending* at point - and with GREEDY extends it under
      ;; `(save-restriction (narrow-to-region (point-min) start))':
      ;;
      ;;   (while (and (> pos (point-min))
      ;;               (save-excursion (goto-char pos) (backward-char 1)
      ;;                               (looking-at (concat regexp "\'"))))
      ;;     (setq pos (1- pos)))
      ;;
      ;; **It stops at the first position that does not match**, so the
      ;; extension is contiguous - not "try every start and keep the
      ;; furthest", which is the same answer and walks the whole buffer
      ;; to find it. (The first version of this port did exactly that and
      ;; took the editor down in font-lock, which calls this with GREEDY
      ;; on every comment end.)
      ;;
      ;; This engine refuses `\=' (`%emacs-ere'), so both halves are the
      ;; same question asked the other way up: does REGEXP match the
      ;; *whole* of S..PT? The C's narrowing to `(point-min)..start` is
      ;; the same text, so the copy stops at PT.
      ;;
      ;; The match data is translated to buffer positions, as
      ;; `looking-at` leaves it: `font-lock` reads `(match-beginning 0)`
      ;; from this call.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             ;; **A nil REGEXP is an *empty* one**, because the C builds
             ;; `(concat "\\(?:" regexp "\\)\\=")' and `concat` drops
             ;; nil: `font-lock` calls this with
             ;; `(or font-lock-comment-end-skip comment-end-skip)`, which
             ;; is nil outside a comment. Measured: `(looking-back nil)'
             ;; is t.
             (regexp (or regexp ""))
             (limit (if (pair? args) (car args) (buffer-beg ed)))
             (greedy (and (pair? args) (pair? (cdr args)) (cadr args)))
             (pt (buffer-pt ed))
             (start (max (or limit (buffer-beg ed)) (buffer-beg ed)))
             (match-at? (lambda (s)
                          (and (string-match regexp (make-buffer-string ed s pt) 0)
                               (= (match-end 0) (- pt s))))))
        (let loop ((s pt))
          (cond
           ((< s start) #f)
           ((match-at? s)
            (let ((s (if greedy
                         ;; `(while (and (> pos (point-min)) ...))`, with
                         ;; the walk stopping at the first failure
                         (let extend ((s s))
                           (if (and (> s (buffer-beg ed)) (match-at? (- s 1)))
                               (extend (- s 1))
                               s))
                         s)))
              (%set-search-regs s (- pt s))
              #t))
           (else (loop (- s 1)))))))

    (define (%set-search-regs beg len)
      ;; GNU Emacs's `set_search_regs' (search.c:2178): the literal
      ;; search's match - register 0 gets it, every other register is
      ;; cleared to unanswered, and the register count does not
      ;; shrink.
      ;;--------------------------------------------------------------
      (let* ((old (or (*search-regs*) '()))
             (n (max 1 (length old)))
             (regs (make-list n #f)))
        (list-set! regs 0 (cons beg (+ beg len)))
        (*search-regs* regs)
        (*last-thing-searched* (current-buffer))
        #f))

    ;;----------------------------------------------------------------
    ;; The literal search
    ;;------------------------------------------------------------------
    ;; GNU Emacs's `search-forward' and `search-backward' reach the text
    ;; through `search_command` -> `search_buffer` -> `simple_search`
    ;; (search.c), and this is that innermost walk. It is a literal
    ;; search over the buffer's characters, in which a line break counts
    ;; as a single #\newline, and it answers a position rather than
    ;; moving point: the two DEFUNs below do the moving and the match
    ;; data, as `search_command` does.
    ;;
    ;; Case folding is the caller's decision, passed in: the rule that an
    ;; upper-case letter in the search string turns folding off
    ;; (`search-upper-case') belongs to isearch, not to `search-forward',
    ;; which only obeys `case-fold-search'.
    ;;
    ;; **Moved here from `engine.scm` on 2026-10-12**, which had it only
    ;; because `search.scm` and `isearch.scm` both import that library.

    ;;----------------------------------------------------------------
    ;; Searching
    ;;
    ;; GNU Emacs's `search-forward' and `search-backward' (mg's
    ;; forwsrch/backsrch): a literal search over the buffer's
    ;; characters, in which a line break counts as a single #\newline.
    ;; Both leave point at the far end of the match - past it when
    ;; searching forward, at its start when searching backward - and
    ;; these procedures return that position, so a caller can put its
    ;; cursor where Emacs would have left point.
    ;;
    ;; Case folding is the caller's decision, passed in: in Emacs the
    ;; rule that an upper-case letter in the search string turns folding
    ;; off (`search-upper-case') belongs to isearch, not to
    ;; `search-forward', which only obeys `case-fold-search'.
    ;;------------------------------------------------------------------

    (define (string-search-forward haystack needle from case-fold?)
      ;; The index of the first occurrence of NEEDLE in the string
      ;; HAYSTACK at or after FROM, or #f. With CASE-FOLD? the comparison
      ;; ignores case, the way mg's `eq' macro does with its `xcase'
      ;; argument. This is the rule the buffer searches below use, and it
      ;; is exported so that a caller which already holds the text - the
      ;; renderer drawing search matches, say - can apply the same rule
      ;; without asking the buffer for it again.
      ;; The index of the first occurrence of NEEDLE in HAYSTACK at or
      ;; after FROM, or #f. With CASE-FOLD? the comparison ignores case,
      ;; the way mg's `eq' macro does with its `xcase' argument.
      ;;--------------------------------------------------------------
      (let ((n (string-length haystack))
            (m (string-length needle)))
        (let loop ((i from))
          (cond
           ((> (+ i m) n) #f)
           ((%string-match-at? haystack needle i case-fold?)
            i)
           (else (loop (+ 1 i)))))))


    (define (%string-match-at? haystack needle at case-fold?)
      ;; Whether NEEDLE occurs in HAYSTACK at index AT.
      ;;--------------------------------------------------------------
      (let ((m (string-length needle)))
        (let loop ((j 0))
          (cond
           ((>= j m) #t)
           ((char=? (%fold (string-ref haystack (+ at j)) case-fold?)
                    (%fold (string-ref needle j) case-fold?))
            (loop (+ 1 j)))
           (else #f)))))

    (define (%fold c case-fold?)
      (if case-fold? (char-downcase c) c))

    (define (%buffer-match-at? ed needle at case-fold?)
      ;; Whether NEEDLE occurs in ED at position AT. This is
      ;; `%string-match-at?`'s rule - `%fold` per character and
      ;; `char=?` - applied to the *buffer's* characters instead of a
      ;; copy of them.
      ;;
      ;; The character is made with `code-point->char`, as
      ;; `buffer-text-substring` makes it: a byte character has no
      ;; `integer->char` and is the replacement character the string
      ;; path makes it, so a search over either text agrees.
      ;;--------------------------------------------------------------
      (let ((store (text-editor-text ed))
            (m (string-length needle)))
        (let loop ((j 0))
          (or (>= j m)
              (and (char=? (%fold (code-point->char
                                   (buffer-text-ref store (+ at j)))
                                  case-fold?)
                           (%fold (string-ref needle j) case-fold?))
                   (loop (+ j 1)))))))

    (define (%first-char-candidate? cp first first-cp first-down-cp first-up-cp
                                    first-folded case-fold?)
      ;; Whether the code point CP could begin a match for the needle
      ;; whose first character is FIRST: the prefilter both scans run on
      ;; every buffer character, so that the conversion to a character
      ;; and the folding are paid only where a match could start.
      ;;
      ;; FIRST-CP, FIRST-DOWN-CP and FIRST-UP-CP are FIRST and its two
      ;; casings as code points, and FIRST-FOLDED is what `%fold` makes of
      ;; it - all hoisted out of the scan's loop so that the
      ;; per-character cost is integer compares. **Both casings** are
      ;; needed, not just the upcase: `char-upcase` of an uppercase needle
      ;; is itself, so a rule built from it alone never matches the
      ;; lowercase text an uppercase needle is folded against. Measured on
      ;; the failing search in a 240 KB file: 92 ms a keystroke when every
      ;; character was converted and folded, 5.2 ms with these compares.
      ;;
      ;; Everything that is not ASCII falls back to the rule
      ;; `%buffer-match-at?' applies, so the two cannot disagree about
      ;; which character starts a match.
      ;;--------------------------------------------------------------
      (cond
       ((= cp first-cp) #t)
       ;; A byte character has no character of its own; it is drawn as
       ;; the replacement character and matches one in the needle for the
       ;; same reason `%buffer-match-at?' lets it.
       ((> cp #x10FFFF)
        (char=? (code-point->char cp) (if case-fold? first-folded first)))
       (case-fold?
        (or (= cp first-down-cp)
            (= cp first-up-cp)
            (and (> cp 127)
                 (char=? (char-downcase (code-point->char cp)) first-folded))))
       (else #f)))

    (define (text-editor-search-forward ed string start case-fold?)
      ;; Search forward from the position START for STRING. Returns the
      ;; position just past the match, which is where GNU Emacs's
      ;; `search-forward' leaves point, or #f when STRING does not
      ;; occur there. An empty STRING finds nothing, as it does for
      ;; mg's `is_find', rather than matching everywhere as Emacs's
      ;; `search-forward' does - an empty search string means "no search
      ;; yet" to the incremental search that wants this.
      ;;
      ;; **The scan is over the buffer, as `search_buffer`
      ;; (`search.c`)** is: it reads the characters ahead of point and
      ;; stops at the first match. It used to copy everything from START
      ;; to `point-max` into a string first, which made every isearch
      ;; keystroke cost the *rest of the buffer* - measured, 9.3 ms at
      ;; the top of a 240 KB file and linear in the file size, where the
      ;; answer is usually a few characters away. The copy is what
      ;; `make-buffer-string` is for and it is still the right tool for
      ;; `looking-at` over a known range; this one has no end in sight.
      ;;
      ;; The first character is compared before the whole match, so the
      ;; scan costs one buffer read per character it passes.
      ;;--------------------------------------------------------------
      (let ((m (string-length string))
            (z (buffer-z ed)))
        (and (< 0 m)
             (let* ((bt (text-editor-text ed))
                    ;; `BEG_ADDR', `BEG', `GPT' and `GAP_SIZE', hoisted
                    ;; out of the loop as the C's macros are expanded out
                    ;; of it. The gap test per character is Emacs's own -
                    ;; `FETCH_CHAR' does it too - and doing it here, one
                    ;; fixnum compare instead of two record reads per
                    ;; character, is what took a failing 240 KB scan from
                    ;; 92 ms to 5.
                    (store (buffer-text-store bt))
                    (base (buffer-text-base bt))
                    (gpt (buffer-text-gpt bt))
                    (gap (buffer-text-gap-size bt))
                    (first (string-ref string 0))
                    (first-cp (char->integer first))
                    (first-down-cp (char->integer (char-downcase first)))
                    (first-up-cp (char->integer (char-upcase first)))
                    (first-folded (%fold first case-fold?)))
               (let loop ((p start))
                 (cond
                  ((> (+ p m) z) #f)
                  ((and (%first-char-candidate?
                         (u32vector-ref store
                                        (if (< p gpt)
                                            (- p base)
                                            (+ (- p base) gap)))
                         first first-cp first-down-cp first-up-cp first-folded
                         case-fold?)
                        (%buffer-match-at? ed string p case-fold?))
                   (+ p m))
                  (else (loop (+ p 1)))))))))

    (define (text-editor-search-backward ed string start case-fold?)
      ;; Search backward from the position START for STRING. Returns the
      ;; position of the start of the match, which is where GNU Emacs's
      ;; `search-backward' leaves point, or #f when STRING does not
      ;; occur before START. An empty STRING finds nothing.
      ;;
      ;; Like the forward scan, this reads the buffer in place rather
      ;; than copying `point-min`..START: the match is usually a line or
      ;; two back, and the copy was the whole distance however near it
      ;; was.
      ;;--------------------------------------------------------------
      (let ((m (string-length string))
            (beg (buffer-beg ed)))
        (and (< 0 m)
             (let* ((bt (text-editor-text ed))
                    (store (buffer-text-store bt))
                    (base (buffer-text-base bt))
                    (gpt (buffer-text-gpt bt))
                    (gap (buffer-text-gap-size bt))
                    (first (string-ref string 0))
                    (first-cp (char->integer first))
                    (first-down-cp (char->integer (char-downcase first)))
                    (first-up-cp (char->integer (char-upcase first)))
                    (first-folded (%fold first case-fold?)))
               (let loop ((p (- start m)))
                 (cond
                  ((< p beg) #f)
                  ((and (%first-char-candidate?
                         (u32vector-ref store
                                        (if (< p gpt)
                                            (- p base)
                                            (+ (- p base) gap)))
                         first first-cp first-down-cp first-up-cp first-folded
                         case-fold?)
                        (%buffer-match-at? ed string p case-fold?))
                   p)
                  (else (loop (- p 1)))))))))

    ;;----------------------------------------------------------------
    ;; Newlines

    (define (find-newline ed start count end)
      ;; GNU Emacs's `find_newline' (`search.c:675'): scan COUNT line
      ;; boundaries from START, forward for a positive COUNT and
      ;; backward for a negative one, and stop at END if COUNT of them
      ;; are not there.
      ;;
      ;; Two values come back: where the scan stopped, and how many
      ;; boundaries it found, counted the way COUNT is - positive going
      ;; forward, negative going backward. Where it found them all, the
      ;; position is just past the COUNTth one; where it ran out of
      ;; text, it is END. Both conventions are the C's, whose caller
      ;; reads the pair out of `*counted' and `*bytepos'.
      ;;
      ;; Scanning backward looks at the character *before* the position
      ;; it is at, so a COUNT of -1 from the middle of a line lands on
      ;; the line's first character when there is a newline just behind
      ;; it - which is what `bol' is.
      ;;
      ;; END false means what the C's zero means: "the end of the buffer
      ;; in the direction of travel" - `ZV' going forward, `BEGV' going
      ;; backward (`search.c:681').
      ;;
      ;; The line-break cache (`buf->newline_cache', which is
      ;; `(schemacs editor region-cache)') is consulted on the way, as
      ;; the C consults it: a stretch already searched and found to hold
      ;; no line break is skipped whole, and a stretch this scan crosses
      ;; without finding one is recorded as known. That is what makes a
      ;; buffer with very long lines affordable - see `region-cache.sld'
      ;; for why the C has it at all.
      ;;--------------------------------------------------------------
      (let* ((end  (or end (if (< 0 count)
                               (buffer-z ed)
                               (buffer-beg ed))))
             ;; The cache is made here on first use, as the C makes it
             ;; (`if (!cache_buffer->newline_cache) cache_buffer->
             ;; newline_cache = new_region_cache ()', `search.c:640') - a
             ;; buffer whose lines are never searched never pays for one.
             (cache (and (text-editor-cache-long-scans ed)
                         (or (%text-editor-newline-cache ed)
                             (let ((c (new-region-cache
                                       (buffer-beg ed))))
                               (set!%text-editor-newline-cache ed c)
                               c)))))
        (if (< 0 count)
            (find-newline-forward ed start count end cache)
            (find-newline-backward ed start count end cache))))

    (define (%newline-in ed pos lim)
      ;; The first line break in [POS, LIM), or false when there is none -
      ;; the C's "dumb loop", the innermost scan that knows nothing about
      ;; the cache or the buffer's ends. It carries one variable, because
      ;; it runs once per character.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((p pos))
          (cond ((>= p lim) #f)
                ((= (buffer-text-ref text p) #x0a) p)
                (else (loop (+ p 1)))))))

    (define (%newline-before ed pos lim)
      ;; The first line break strictly before POS and at or after LIM,
      ;; answering the position just *after* it, or false when there is
      ;; none. Scanning backward looks at the character before the
      ;; position it is at, which is why the answer is a position past the
      ;; break rather than on it.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((p pos))
          (cond ((<= p lim) #f)
                ((= (buffer-text-ref text (- p 1)) #x0a) p)
                (else (loop (- p 1)))))))

    (define (find-newline-forward ed start count end cache)
      ;; The forward half of `find-newline'. Each round asks the cache
      ;; where the knowledge runs out, scans that far for a line break,
      ;; and records what it crossed - which is the C's structure: consult,
      ;; dumb-loop, `know_region_cache', repeat.
      ;;
      ;; A stretch the cache calls known holds no line break, so it is
      ;; stepped over rather than looked at. That is the whole saving.
      ;;--------------------------------------------------------------
      (let ((beg (buffer-beg ed))
            (z (buffer-z ed)))
        (let outer ((pos start) (left count) (found 0))
          (if (>= pos end)
              (values end found)
              (call-with-values
                  (lambda ()
                    (if cache
                        (region-cache-forward cache beg z pos)
                        (values 0 pos)))
                (lambda (known next-change)
                  (cond
                   ((= known 1)
                    ;; known: no break in here at all - step over it
                    (let ((skip (min next-change end)))
                      (if (<= skip pos)
                          (values end found)
                          (outer skip left found))))
                   (else
                    ;; unknown as far as NEXT-CHANGE, or as far as the
                    ;; caller asked
                    (let ((lim (min (if (> next-change pos) next-change end)
                                    end)))
                      (let ((nl (%newline-in ed pos lim)))
                        (cond
                         ((not nl)
                          (when (and cache (> lim pos))
                            (know-region-cache cache beg z pos lim))
                          (outer lim left found))
                         (else
                          (when (and cache (> nl pos))
                            (know-region-cache cache beg z pos nl))
                          (if (= left 1)
                              (values (+ nl 1) (+ found 1))
                              (outer (+ nl 1) (- left 1) (+ found 1)))))))))))))))

    (define (find-newline-backward ed start count end cache)
      ;; The backward half of `find-newline', the mirror of the forward
      ;; one: consult, scan down to where the knowledge runs out, record
      ;; what was crossed, repeat.
      ;;--------------------------------------------------------------
      (let ((beg (buffer-beg ed))
            (z (buffer-z ed)))
        (let outer ((pos start) (left count) (found 0))
          (if (<= pos end)
              (values end found)
              (call-with-values
                  (lambda ()
                    (if cache
                        (region-cache-backward cache beg z pos)
                        (values 0 pos)))
                (lambda (known next-change)
                  (cond
                   ((= known 1)
                    (let ((skip (max next-change end)))
                      (if (>= skip pos)
                          (values end found)
                          (outer skip left found))))
                   (else
                    (let ((lim (max (if (< next-change pos) next-change end)
                                    end)))
                      (let ((nl (%newline-before ed pos lim)))
                        (cond
                         ((not nl)
                          (when (and cache (< lim pos))
                            (know-region-cache cache beg z lim pos))
                          (outer lim left found))
                         (else
                          (when (and cache (< nl pos))
                            (know-region-cache cache beg z nl pos))
                          ;; The count of boundaries found is
                          ;; `found - 1' here, and it was a hardcoded
                          ;; `-1' until 2026-10-06 - so every backward
                          ;; scan answered "one found" however many it
                          ;; had crossed. That is what the C's
                          ;; `counted' is, and `find_before_next_newline'
                          ;; reads it to decide whether to step back
                          ;; onto the newline. A COUNT of -2 found two
                          ;; breaks and said one, and nothing saw it
                          ;; until `line-end-position' was given the
                          ;; optional N that reaches a count below -1.
                          (if (= left -1)
                              (values nl (- found 1))
                              (outer (- nl 1) (+ left 1) (- found 1)))))))))))))))

    (define (scan-newline-from-point ed count)
      ;; GNU Emacs's `scan_newline_from_point' (`search.c':986'): scan
      ;; COUNT line boundaries from point. It does not move point.
      ;;
      ;; Two values come back - where the scan stopped, and how many
      ;; boundaries it found - which is the C's two out-parameters
      ;; (`*charpos' and the returned `counted'). A COUNT at or below
      ;; zero scans backward, one boundary further back than COUNT asks
      ;; for; that difference is what makes `bol' land on the *start* of
      ;; a line where `forward-line' would land on the one before it.
      ;;--------------------------------------------------------------
      (if (<= count 0)
          (find-newline ed (buffer-pt ed) (- count 1)
                        (buffer-beg ed))
          (find-newline ed (buffer-pt ed) count
                        (buffer-z ed))))

    ;; **`bol' and `eol' have left, for `(schemacs editor editfns)'.**
    ;; They are `editfns.c:665' and `:723' - the internal pair
    ;; `line-beginning-position', `line-end-position', `beginning-of-line'
    ;; and `forward-line' are all built on - and they moved *up* rather
    ;; than the scans below moving down. That direction is the one the
    ;; C's own layering takes: `editfns.c' calls `search.c''s scans, so
    ;; the scans sit below the arithmetic that reads them, and this
    ;; library is where the scans are. They reach `scan-newline-from-point'
    ;; and `find-before-next-newline' here through this library's exports.

    (define (find-before-next-newline ed from cnt)
      ;; GNU Emacs's `find_before_next_newline' (`search.c':997'): where
      ;; the line boundary CNT boundaries away from FROM begins. With a
      ;; positive CNT the scan lands just *after* the newline, so it
      ;; steps back one, to the newline's own position - which is what
      ;; an end-of-line wants.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (find-newline ed from cnt #f))
        (lambda (pos found)
          (if (= found cnt) (- pos 1) pos))))

    (define (search-forward string . args)
      ;; GNU Emacs's `search-forward' (search.c:2218): "Search forward
      ;; from point for STRING. Set point to the end of the occurrence
      ;; found, and return point." BOUND limits the search, NOERROR
      ;; keeps a failed search from signalling, COUNT - which is what
      ;; `zap-to-char''s ARGth occurrence passes - finds the COUNTth
      ;; match. The case folding is `case-fold-search''s, which the
      ;; caller may override: the optional fourth argument is this
      ;; tree's, for the upper-case-char rule `zap-to-char' applies.
      ;; The match data records the match (the C's `search_buffer'
      ;; calls `set_search_regs' for every kind of search it makes).
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (bound (if (pair? args) (car args) #f))
             (noerror (and (pair? args) (pair? (cdr args)) (cadr args)))
             (count (if (and (pair? args) (pair? (cdr args))
                             (pair? (cddr args)))
                        (caddr args)
                        1))
             (fold (if (and (pair? args) (pair? (cdr args))
                            (pair? (cddr args)) (pair? (cdddr args)))
                       (cadddr args)
                       (*case-fold-search*)))
             (limit (%search-limit ed bound #f)))
        (if (< count 0)
            (search-backward string bound noerror (- count) fold)
            (let loop ((left (max 1 count)) (from (buffer-pt ed)))
          (let ((found (text-editor-search-forward
                        ed string (min from limit) fold)))
            (cond
             ((not found)
              (if noerror
                  #f
                  (error "Search failed" string)))
             ((> found limit)
              (if noerror #f (error "Search failed" string)))
             ((> left 1) (loop (- left 1) found))
             (else
              (set-point ed found)
              ;; FOUND is a position now - the engine's positions are
              ;; Emacs's - so the match starts `(string-length string)'
              ;; before it and neither the register nor the answer adds
              ;; the one they used to, when positions were zero-based.
              (%set-search-regs (- found (string-length string))
                                (string-length string))
              found)))))))

    (define (search-backward string . args)
      ;; GNU Emacs's `search-backward' (search.c:2206): the backward
      ;; mirror of `search-forward', which answers the START of the
      ;; match - and leaves point there, as the C does.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (bound (if (pair? args) (car args) #f))
             (noerror (and (pair? args) (pair? (cdr args)) (cadr args)))
             (count (if (and (pair? args) (pair? (cdr args))
                             (pair? (cddr args)))
                        (caddr args)
                        1))
             (fold (if (and (pair? args) (pair? (cdr args))
                            (pair? (cddr args)) (pair? (cdddr args)))
                       (cadddr args)
                       (*case-fold-search*)))
             (limit (%search-limit ed bound #t)))
        (if (< count 0)
            (search-forward string bound noerror (- count) fold)
            (let loop ((left (max 1 count)) (from (buffer-pt ed)))
          (let ((found (text-editor-search-backward
                        ed string (max from limit) fold)))
            (cond
             ((not found)
              (if noerror #f (error "Search failed" string)))
             ((< found limit)
              (if noerror #f (error "Search failed" string)))
             ((> left 1) (loop (- left 1) found))
             (else
              ;; `found' is the match's start, where the backward
              ;; search leaves point
              (set-point ed found)
              (%set-search-regs found (string-length string))
              found)))))))

    (define (%search-limit ed bound backward)
      ;; `search_command`'s BOUND arithmetic (`search.c:1006`), which is
      ;; the same for every search entry point:
      ;;
      ;;   if (NILP (bound)) lim = n > 0 ? ZV : BEGV;
      ;;   else { lim = fix_position (bound);
      ;;          if (n > 0 ? lim < PT : lim > PT)
      ;;            error ("Invalid search bound (wrong side of point)");
      ;;          if (lim > ZV) lim = ZV;
      ;;          else if (lim < BEGV) lim = BEGV; }
      ;;
      ;; The default is the *accessible* end, so a search in a narrowed
      ;; buffer stops at the restriction; an explicit bound is checked
      ;; against point and then clipped to it.
      ;;--------------------------------------------------------------
      (let ((pt (buffer-pt ed)))
        (cond
         ((not bound) (if backward (buffer-beg ed) (buffer-z ed)))
         (else
          (when (if backward (> bound pt) (< bound pt))
            (error "Invalid search bound (wrong side of point)"))
          (min (max bound (buffer-beg ed)) (buffer-z ed))))))

    (define %search-chunk 512)
    ;; ^ The smallest stretch of text a search copies for Guile's regexp
    ;; engine to run on.
    ;;
    ;; **`regexp-exec' costs time proportional to the length of the
    ;; string it is handed, not to how far it scans.** Measured on this
    ;; machine: 0.9 µs on a 257-character string and 870 µs on a
    ;; 257 000-character one, and 6.4 ms against 3.4 µs for a match at
    ;; the very start. So a search may not be handed the buffer, and it
    ;; may not be handed the whole range it is allowed to search either
    ;; - a font-lock keyword's range is the file. It is handed a window,
    ;; which doubles until the answer cannot depend on where the window
    ;; ends.

    (define (%search-window ed start end)
      ;; The buffer's text from START (inclusive) to END (exclusive) -
      ;; `make_buffer_string' between two positions.
      ;;--------------------------------------------------------------
      (make-buffer-string ed start end))

    (define (%re-search-forward-1 regexp at limit)
      ;; One match of REGEXP at or after AT and ending by LIMIT, as
      ;; `re_search_2' with a positive `range' finds it. Answers
      ;; `(MATCH START END BASE)', where BASE is the first position of
      ;; the window the match was found in, or #f.
      ;;
      ;; The window begins one character before AT so that `^' is judged
      ;; against the character really in front of it (`%bol-flags'); that
      ;; is the only lookbehind the engine can need, because `\=' and
      ;; `\'' are refused by `%emacs-ere'.
      ;;--------------------------------------------------------------
      ;; The window may run one character PAST the bound, so that `$'
      ;; and `\b' are judged against the real character there and not
      ;; against an end of string the buffer has not got; a match is
      ;; still refused when it ends past the bound (`(> e limit)'), which
      ;; is Emacs's `stop'.
      (let* ((cap (min (buffer-z (current-buffer)) (+ limit 1))))
        (let find ((wend (min cap (+ (min at limit) %search-chunk)))
                   (span %search-chunk))
          (let* ((base (max (buffer-beg (current-buffer)) (- (min at limit) 1)))
                 (whole (%search-window (current-buffer) base wend))
                 (here (- (min at limit) base)))
          (let scan ((start here))
            (let ((m (regexp-exec regexp whole start (%bol-flags whole start))))
              (cond
               ((not m)
                (if (>= wend cap)
                    #f
                    (find (min cap (+ wend span)) (* 2 span))))
               (else
                (let ((s (+ (match:start m 0) base))
                      (e (+ (match:end m 0) base)))
                  (cond
                   ;; **A match that runs past the bound is refused, and the
                   ;; search answers nil** - Emacs would take a shorter
                   ;; match at the same start if the pattern has one, and
                   ;; this cannot ask for it without truncating the text at
                   ;; the bound, which would make `$' and `\b' match an end
                   ;; of string the buffer has not got (measured: it
                   ;; fabricated two `$' matches in a 500-case corpus).
                   ;; Left as it is, and named in DEPARTURES.md.
                   ((> e limit) #f)
                   ;; A match ending at the window's own edge may have
                   ;; matched `$' (or a `\b') against the edge rather than
                   ;; against the buffer; widen and ask again.
                   ((and (= e wend) (< wend cap))
                    (find (min cap (+ wend span)) (* 2 span)))
                   ;; A `\_<' or `\_>' that does not hold here is not a
                   ;; match; the C's matcher backtracks and tries the next
                   ;; start, and so does this.
                   ((not (%assertions-hold-buffer? m base))
                    (let ((next (+ (match:start m 0) 1)))
                      (if (> next (string-length whole))
                          (if (>= wend cap)
                              #f
                              (find (min cap (+ wend span)) (* 2 span)))
                          (scan next))))
                   (else (list m s e base))))))))))))

    (define (%re-search-backward-1 regexp at limit)
      ;; `re_search_2' with a negative `range': walk the start position
      ;; down from AT to LIMIT and take the first one the pattern matches
      ;; at, with the match ending by AT - "Don't allow match past
      ;; current point", which is what steps the walk back on a repeated
      ;; search. The walk begins *at* point; beginning it at the bound
      ;; instead is what made every `re-search-backward' answer nil.
      ;;--------------------------------------------------------------
      (let find ((low (max limit (- at %search-chunk)))
                 (span %search-chunk))
        ;; The window runs one character PAST `at` as well as one before
        ;; the lowest position tried: `$` and `\b` are judged against the
        ;; character after the match, and a window that ends at `at`
        ;; makes the engine see an end of string there - `(re-search-
        ;; backward "$" BOUND t)' from a point in the middle of a line
        ;; then reports a match at point. The extra character is never
        ;; allowed to be part of a match: the test below is `(<= end at)'.
        (let* ((base (max (buffer-beg (current-buffer)) (- low 1)))
               (wend (min (buffer-z (current-buffer)) (+ at 1)))
               (whole (%search-window (current-buffer) base wend)))
          (let try ((s at))
            (cond
             ((< s low)
              (if (<= low limit)
                  #f
                  (find (max limit (- low span)) (* 2 span))))
             (else
              (let* ((here (- s base))
                     (m (regexp-exec regexp whole here (%bol-flags whole here))))
                (cond
                 ((and m
                       (= (+ (match:start m 0) base) s)
                       (<= (+ (match:end m 0) base) at)
                       (%assertions-hold-buffer? m base))
                  (list m s (+ (match:end m 0) base) base))
                 ((and m (= (+ (match:start m 0) base) s))
                  ;; The longest match here runs past point; the C
                  ;; engine's `stop' is point, so ask again with the text
                  ;; ending there.
                  (let* ((tshort (%search-window (current-buffer) base at))
                         (tm (regexp-exec regexp tshort here
                                          (%bol-flags tshort here))))
                    (if (and tm
                             (= (+ (match:start tm 0) base) s)
                             (<= (+ (match:end tm 0) base) at)
                             (%assertions-hold-buffer? tm base))
                        (list tm s (+ (match:end tm 0) base) base)
                        (try (- s 1)))))
                 (else (try (- s 1)))))))))))

    (define (%re-search regexp bound noerror count backward)
      ;; `search_command' (search.c) and `search_buffer' for the regexp
      ;; path: find the COUNTth match of REGEXP between point and
      ;; BOUND, NOERROR answering nil for what would signal, and leave
      ;; point at the match's far end (forward) or start (backward),
      ;; answering the point value, as the C's DEFUNs do.
      ;;
      ;; The text searched is a window of the buffer (`%search-window');
      ;; positions are the buffer's, and the window's first position is
      ;; added to the offsets the engine answers.
      ;;--------------------------------------------------------------
      ;; `search_command' (`search.c:1033'): "n = direction; if (!NILP
      ;; (count)) n *= XFIXNUM (count);" - **a negative COUNT flips the
      ;; direction**, so `(re-search-backward RE nil nil -1)' searches
      ;; *forward*. Measured on Emacs 31.1; `beginning-of-defun-raw'
      ;; depends on it.
      (let* ((n (* (if count count 1) (if backward -1 1)))
             (backward (< n 0))
             (count (abs n))
             (ed (current-buffer))
             (from (buffer-pt ed))
             (regexp (%compile-emacs-regexp regexp (*case-fold-search*)))
             ;; `search_command`'s bound rule, in the C's order: the
             ;; wrong-side check is against the *unclipped* argument.
             (limit (%search-limit ed bound backward)))
        (let loop ((left (max 1 count)) (at from))
          (let ((found (if backward
                           (%re-search-backward-1 regexp at limit)
                           (%re-search-forward-1 regexp at limit))))
            (cond
             ((not found)
              ;; `search_command' (`search.c'): "If NOERROR is neither
              ;; nil nor t ... just move point to the limit" - the
              ;; `move' sentinel, which `beginning-of-defun-raw' passes.
              (if (not noerror)
                  (error "Search failed" regexp)
                  (begin
                    (when (not (eq? noerror #t))
                      ;; "just move point to the limit" - the *clipped*
                      ;; one, which is what `lim` is by then in the C.
                      (set-point ed limit))
                    #f)))
             ((> left 1) (loop (- left 1) (if backward (cadr found)
                                              (caddr found))))
             (else
              (set-point ed
                                      (if backward (cadr found) (caddr found)))
              ;; the registers of the match actually made, not a
              ;; re-derivation of it from a copy of the matched text -
              ;; the copy made `^' and the subexpression offsets answers
              ;; about the copy, not about the buffer.
              ;;
              ;; The window's own first position goes on here as well as
              ;; the 0-to-1: the match object's positions are relative to
              ;; the text that was searched, so the register for offset O
              ;; is at position `(+ base O)'.
              (%string-match-into-regs (car found))
              (match-data--translate (cadddr found))
              (*last-thing-searched* (current-buffer))
              ;; ... and the answer is that same position.
              (if backward (cadr found) (caddr found))))))))

    (define (re-search-forward regexp . args)
      ;; GNU Emacs's `re-search-forward' (search.c:2264): "Search
      ;; forward from point for regular expression REGEXP. Set point to
      ;; the end of the occurrence found, and return point."
      ;;--------------------------------------------------------------
      (let ((bound (if (pair? args) (car args) #f))
            (noerror (and (pair? args) (pair? (cdr args)) (cadr args)))
            (count (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args)))
                       (caddr args)
                       1)))
        (%re-search regexp bound noerror count #f)))

    (define (re-search-backward regexp . args)
      ;; GNU Emacs's `re-search-backward' (search.c:2248): the backward
      ;; mirror, which answers the START of the match and leaves point
      ;; there.
      ;;--------------------------------------------------------------
      (let ((bound (if (pair? args) (car args) #f))
            (noerror (and (pair? args) (pair? (cdr args)) (cadr args)))
            (count (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args)))
                       (caddr args)
                       1)))
        (%re-search regexp bound noerror count #t)))

    ;;----------------------------------------------------------------
    ;; The replacement
    ;;------------------------------------------------------------------

    (define (regexp-quote string)
      ;; GNU Emacs's `regexp-quote' (search.c:3165): "Return a regexp
      ;; string which matches exactly STRING and nothing else" - the
      ;; C's escape set, `[ * . \ ? + ^ $'.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length string))
            (list->string (reverse acc))
            (let ((c (string-ref string i)))
              (if (memv c '(#\[ #\* #\. #\\ #\? #\+ #\^ #\$))
                  (loop (+ i 1) (cons c (cons #\\ acc)))
                  (loop (+ i 1) (cons c acc)))))))

    (define (%case-action-of matched-text)
      ;; The case transfer `replace-match' decides from the matched
      ;; text (search.c:2406-2510): `all-caps' when no character is
      ;; lower case and some word is more than one letter;
      ;; `cap-initials' when no word starts with a non-upper initial
      ;; and some word is more than one letter; `nochange' otherwise -
      ;; with the C's special case that upper case with no lower case
      ;; and no multiletter word is still nochange.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (prev-word? #f)
                 (some-multiletter-word #f) (some-lowercase #f)
                 (some-nonuppercase-initial #f) (some-uppercase #f))
        (if (>= i (string-length matched-text))
            (cond
             ((and (not some-lowercase) some-multiletter-word) 'all-caps)
             ((and (not some-nonuppercase-initial)
                   some-multiletter-word) 'cap-initials)
             ((and (not some-nonuppercase-initial) some-uppercase) 'all-caps)
             (else 'nochange))
            (let* ((c (string-ref matched-text i))
                   (lower (char-lower-case? c))
                   (upper (char-upper-case? c))
                   (word (word-char? c)))
              (cond
               (lower
                ;; "Cannot be all caps if any original char is lower
                ;; case" - and the word it starts was not begun by an
                ;; upper case letter
                (loop (+ i 1) word
                      (if (not prev-word?) some-multiletter-word #t)
                      #t
                      (if (not prev-word?) #t some-nonuppercase-initial)
                      some-uppercase))
               (upper
                (loop (+ i 1) word
                      (if (not prev-word?) #t some-multiletter-word)
                      some-lowercase
                      some-nonuppercase-initial
                      #t))
               (else
                ;; "If the initial is a caseless word constituent,
                ;; treat that like a lowercase initial"
                (loop (+ i 1) word
                      some-multiletter-word some-lowercase
                      (if (not prev-word?) #t some-nonuppercase-initial)
                      some-uppercase)))))))

    (define (%substitute-replacement newtext regs sub)
      ;; The `\N' substitution of `replace-match''s buffer path
      ;; (search.c:2614-2731): walk NEWTEXT, `\&' for the whole match,
      ;; `\N' for the Nth subexpression's text - nothing for one that
      ;; did not match - `\\' for a backslash, and an error for any
      ;; other use of `\' ("Invalid use of `\\' in replacement text").
      ;; The `\?' is left standing, which is what the C leaves it as
      ;; ("for compatibility with query-replace-regexp").
      ;;--------------------------------------------------------------
      (let loop ((i 0) (acc '()))
        (cond
         ((>= i (string-length newtext))
          (apply string-append (reverse acc)))
         ((char=? (string-ref newtext i) #\\)
          (if (>= (+ i 1) (string-length newtext))
              (error "Invalid use of `\\' in replacement text")
              (let ((c (string-ref newtext (+ i 1))))
                (cond
                 ((char=? c #\&)
                   (loop (+ i 2)
                         (cons (make-buffer-string
                                (current-buffer)
                                (+ 1 (car (list-ref regs sub)))
                                (+ 1 (cdr (list-ref regs sub))))
                               acc)))
                 ((and (char<=? #\1 c #\9)
                       (< (- (char->integer c) 48) (length regs)))
                  (let ((pair (list-ref regs (- (char->integer c) 48))))
                    (cond
                     ((and pair (>= (car pair) 1))
                      (loop (+ i 2)
                            (cons (make-buffer-string
                                   (current-buffer)
                                   (+ 1 (car pair)) (+ 1 (cdr pair)))
                                  acc)))
                     ;; that subexp did not match: nothing
                     (else (loop (+ i 2) acc)))))
                 ((char=? c #\\)
                  (loop (+ i 2) (cons "\\" acc)))
                 (else
                  (error "Invalid use of `\\' in replacement text"))))))
         (else (loop (+ i 1) (cons (make-string 1 (string-ref newtext i)) acc))))))

    (define (%update-search-regs oldstart oldend newend)
      ;; The match data's adjustment `replace_range' asks for
      ;; (search.c:3119): the replaced region's shift moves the
      ;; registers outside it, pins those inside, and "leans towards
      ;; leaving the start[i]s unchanged and moving the end[i]s" for
      ;; the subgroups it cannot tell apart.
      ;;--------------------------------------------------------------
      (let ((change (- newend oldend)))
        (*search-regs*
         (map
          (lambda (pair)
            (if (not pair)
                #f
                (cons
                 (cond
                  ((<= (car pair) oldstart) (car pair))
                  ((>= (car pair) oldend) (+ (car pair) change))
                  (else oldstart))
                 (cond
                  ((>= (cdr pair) oldend) (+ (cdr pair) change))
                  ((> (cdr pair) oldstart) oldstart)
                  (else (cdr pair))))))
          (*search-regs*)))))

    (define (replace-match newtext . args)
      ;; GNU Emacs's `replace-match' (search.c:2344): "Replace text
      ;; matched by last search with NEWTEXT. Leave point at the end
      ;; of the replacement text." FIXEDCASE keeps the replacement's
      ;; case as typed; LITERAL inserts NEWTEXT as it stands instead
      ;; of reading `\&' and `\N'; STRING makes it act on a string,
      ;; answering a new string, and SUBEXP replaces just that
      ;; subexpression.
      ;;--------------------------------------------------------------
      (let* ((fixedcase (and (pair? args) (car args)))
             (literal (and (pair? args) (pair? (cdr args)) (cadr args)))
             (string (and (pair? args) (pair? (cdr args)) (pair? (cddr args))
                          (caddr args)))
             (subexp (and (pair? args) (pair? (cdr args)) (pair? (cddr args))
                          (pair? (cdddr args))
                          (cadddr args))))
        ;; the C's fast path: no backslash in NEWTEXT is literal
        (let* ((sub (or subexp 0))
               (literal (or literal
                            (not (string-index newtext #\\)))))
          (cond
           ((not (*search-regs*))
            (error "`replace-match' called before any match found"))
           ((>= sub (length (*search-regs*)))
            (error "replace-match subexpression does not exist" sub))
           ((and (not string) (not (*last-thing-searched*)))
            (error "`replace-match' called before any match found"))
           (string
            ;; the string path: a new string, the original untouched
            (replace-match-string newtext fixedcase literal string sub))
           (else
            (replace-match-buffer newtext fixedcase literal sub))))))

    (define (replace-match-string newtext fixedcase literal string subexp)
      ;; The string path of `replace-match' (search.c:2543-2590): the
      ;; part of STRING before the match, the substituted NEWTEXT
      ;; casified as the match's case pattern asks, and the part after.
      ;;--------------------------------------------------------------
      (let* ((regs (*search-regs*))
             (sub (or subexp 0))
             (pair (list-ref regs sub)))
        (cond
         ((not pair)
          (error "replace-match subexpression does not exist" subexp))
         (else
          (let* ((sub-start (car pair))
                 (sub-end (cdr pair))
                 ;; decide how to casify from the matched text
                 (case-action
                  (if fixedcase 'nochange
                      (%case-action-of (substring string sub-start sub-end))))
                 (newtext
                  (if literal
                      newtext
                      ;; the string path's own substitution walk,
                      ;; which answers the parts of the match
                      (%substitute-string-replacement
                       newtext string sub-start sub-end regs)))
                 (newtext
                  (cond
                   ((eq? case-action 'all-caps) (upcase newtext))
                   ((eq? case-action 'cap-initials) (upcase-initials newtext))
                   (else newtext))))
            (string-append
             (substring string 0 sub-start)
             newtext
             (substring string sub-end (string-length string))))))))

    (define (%substitute-string-replacement newtext string sub-start sub-end regs)
      ;; The string path's substitution (search.c:2543-2590): `\&' and
      ;; `\N' take the STRING's own matched text - the string's
      ;; positions are zero-based, so a register's test is simply
      ;; `matched'. The walk accumulates STRINGS - the parts and the
      ;; plain characters each join as their own piece.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (acc '()))
        (cond
         ((>= i (string-length newtext))
          (apply string-append (reverse acc)))
         ((char=? (string-ref newtext i) #\\)
          (if (>= (+ i 1) (string-length newtext))
              (error "Invalid use of `\\' in replacement text")
              (let ((c (string-ref newtext (+ i 1))))
                (cond
                 ((char=? c #\&)
                  (loop (+ i 2)
                        (cons (substring string sub-start sub-end) acc)))
                 ((and (char<=? #\1 c #\9)
                       (< (- (char->integer c) 48) (length regs)))
                  (let ((pair (list-ref regs (- (char->integer c) 48))))
                    (if (and pair (>= (car pair) 0))
                        (loop (+ i 2)
                              (cons (substring string (car pair) (cdr pair))
                                    acc))
                        ;; did not match: nothing
                        (loop (+ i 2) acc))))
                 ((char=? c #\\) (loop (+ i 2) (cons "\\" acc)))
                 (else (error "Invalid use of `\\' in replacement text"))))))
         (else (loop (+ i 1) (cons (make-string 1 (string-ref newtext i)) acc))))))

    (define (replace-match-buffer newtext fixedcase literal subexp)
      ;; The buffer path of `replace-match' (search.c:2593-2775): the
      ;; substituted text replaces the match, is casified in place as
      ;; the case pattern asks, point ends up at the replacement's end
      ;; - after the recorded point is put back and moved "officially",
      ;; as the C's TEMP_SET_PT and move_if_not_intangible are.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (regs (*search-regs*))
             (sub (or subexp 0))
             (pair (list-ref regs sub))
             (sub-start (car pair))
             (sub-end (cdr pair))
             (zv (buffer-z ed))
             ;; `opoint = PT <= sub_start ? PT : max (PT, sub_end) - ZV'
             ;; - the recorded point, negative being an offset from the
             ;; buffer's end
             (pt (buffer-pt ed))
             (opoint (if (<= pt sub-start)
                         pt
                         (- (max pt sub-end) zv)))
             ;; the case pattern of the matched text
             (case-action
              (if fixedcase 'nochange
                  (%case-action-of (make-buffer-string
                                    ed sub-start sub-end))))
             ;; the substitution, if the replacement is not literal
             (newtext
              (if literal
                  newtext
                  (%substitute-replacement newtext regs sub)))
             (newpoint (+ sub-start (string-length newtext))))
        ;; "Replace the old text with the new in the cleanest possible
        ;; way." The C is one call, and **it does not move point to
        ;; SUB-START first** - `replace_range` relocates point as if it
        ;; were a marker, which is a different thing: a point before the
        ;; replaced text keeps its place, one inside it lands at
        ;; SUB-START, and one at SUB-END follows the new text. The tree
        ;; used to park point at SUB-START and then delete and insert,
        ;; which is three changes where the C makes one - and the match
        ;; data follows the change through `replace_range`'s own
        ;; `adjust_match_data` argument, which is why the explicit
        ;; `%update-search-regs` call that stood here is gone.
        ;;
        ;; The C's arguments are `(sub_start, sub_end, newtext, true,
        ;; false, true)`: run the change hooks and signal once, do not
        ;; inherit properties, and adjust the match data.
        (replace-range sub-start sub-end newtext #t #f #t)
        ;; casify the inserted text, as the C calls Fupcase_region /
        ;; Fupcase_initials_region over it
        (cond
         ((eq? case-action 'all-caps)
          (casify-region 'upcase sub-start newpoint))
         ((eq? case-action 'cap-initials)
          (casify-region 'capitalize-up sub-start newpoint))
         (else #f))
        ;; "Put point back where it was in the text, if possible." The
        ;; C's `opoint <= 0` is not `< 0` - a zero names a place counted
        ;; from the end of the buffer, which is how `replace-match-string'
        ;; (the C's string path) spells "at the end".
        (set-point
         ed (max (buffer-beg ed)
                 (min zv (if (<= opoint 0)
                             (+ zv opoint)
                             opoint))))
        ;; "Now move point `officially' to the end of the inserted
        ;; replacement." The C's `move_if_not_intangible` is not ported -
        ;; there is no intangible text here - so this is the `goto-char`
        ;; it amounts to.
        (set-point ed newpoint)
        #f))

    ;; Install the seam `replace_range` reads. In the C `search.c` is
    ;; *above* `insdel.c` and `replace_range` calls `update_search_regs`
    ;; up the build - which is why a library below cannot call it and the
    ;; parameter exists. `replace-match` is the caller that asks for it
    ;; (`replace_range (..., adjust_match_data = true)`), so that a match
    ;; still names the same text after the replacement.
    (*update-search-regs-function*
     (lambda (oldstart oldend newend)
       (%update-search-regs oldstart oldend newend)))

    (define (match-string num . args)
      ;; GNU Emacs's `match-string' (subr.el:5848): "Return the string
      ;; of text matched by the previous search or regexp operation."
      ;; STRING, when given, is the string the last `string-match' ran
      ;; on; when not, the text comes from the current buffer, whose
      ;; `buffer-substring' answers it with the match data's positions.
      ;; `#f' when the NUMth pair did not match.
      ;;
      ;; This is subr.el's function and it would be in `(schemacs
      ;; editor subr)', but subr is imported BY simple, and search is
      ;; above simple - the same wall the file header of subr knows.
      ;;--------------------------------------------------------------
      (let ((beg (match-beginning num)))
        (and beg
             (let ((end (match-end num))
                   (string (if (pair? args) (car args) #f)))
               (if string
                   (substring string beg end)
                   ;; Emacs's `match-string' is `buffer-substring' for a
                   ;; buffer, which copies the properties with the text.
                   (make-buffer-string (current-buffer) beg end #t))))))

    (define (match-substitute-replacement replacement . args)
      ;; GNU Emacs's `match-substitute-replacement' (subr.el:5890):
      ;; "Return REPLACEMENT as it will be inserted by `replace-match'"
      ;; - the back references substituted and the case transferred,
      ;; with no edit made. The C's way is `replace-match''s string
      ;; path against the matched text itself, which the C's
      ;; `match-data--translate' makes of the buffer's match data.
      ;;--------------------------------------------------------------
      (let* ((fixedcase (and (pair? args) (car args)))
             (literal (and (pair? args) (pair? (cdr args)) (cadr args))))
        (save-match-data
          (let ((string (make-buffer-string
                         (current-buffer) (match-beginning 0) (match-end 0)
                         #t)))
            (match-data--translate (- (match-beginning 0)))
            (replace-match replacement fixedcase literal string))))
    )

    ;;----------------------------------------------------------------
    ;; `syntax-propertize-rules' (`syntax.el:223')
    ;;------------------------------------------------------------------
    ;; Emacs's macro compiles its RULES into **one scan**: the rule
    ;; regexps are joined with `\|' and the groups tell the generated
    ;; code which rule matched. This is that engine, as a procedure.
    ;;
    ;; **A departure in *form*: the macro is a procedure here.** The C's
    ;; macro `eval's each rule's REGEXP expression at macro-expansion
    ;; time; Scheme has no such step, so a rule's REGEXP is a *string*
    ;; the caller has already built (`regexp-opt', or a literal), and
    ;; the actions - Elisp expressions in the C - are procedures of no
    ;; arguments returning a syntax entry or `#f'. An action may also be
    ;; a descriptor string, or a list `(prog1 X Y ...)', which is the
    ;; C's special form of that name: X's value is applied as the
    ;; property and the Ys are run after it.
    ;;
    ;; The engine bodies below are the C's: the offset accounting, the
    ;; group-0 wrapping, `syntax-propertize--shift-groups-and-backrefs'
    ;; and the match-data shift an action that is code needs.

        (define (%sp-any pred list)
      ;; cl-lib's `any', the walk the C's `(or ...)' expands to.
      ;;--------------------------------------------------------------
      (let loop ((l list))
        (cond ((null? l) #f)
              ((pred (car l)) #t)
              (else (loop (cdr l))))))

    (define (%shift-match-data offset)
      ;; "Keep match 0 as is, but shift everything else"
      ;; (`syntax.el:270'): `(let ((md (match-data 'ints)))
      ;; (setcdr (cdr md) (nthcdr (* (1+ OFFSET) 2) md)) (set-match-data md))'.
      ;;
      ;; **The list may be SHORTER than that offset.** `match-data'
      ;; elides trailing registers that did not match - `(match-data)'
      ;; for `\(a\)\(b\)?' on "a" is `(0 1 0 1)', measured - so a
      ;; rule whose groups did not participate hands a short list, and
      ;; `nthcdr' off its end is the empty list, not an error.
      ;;--------------------------------------------------------------
      (let* ((md (match-data))
             (cut (* (+ 1 offset) 2)))
        (when (pair? (cdr md))
          (set-cdr! (cdr md)
                    (if (>= cut (length md)) '() (list-tail md cut))))
        (set-match-data md)))

    ;;----------------------------------------------------------------
    ;; `subregexp-context-p' and `regexp-opt-depth'
    ;;------------------------------------------------------------------
    ;; Both serve `regexp-opt.el''s callers: the depth is what
    ;; `syntax-propertize-rules' asks each rule's regexp for, to know
    ;; where the next rule's groups begin.
    ;;
    ;; **A placement departure.** `subregexp-context-p' is `subr.el''s
    ;; and `regexp-opt-depth' is `regexp-opt.el''s, but both are
    ;; `string-match' clients, and `(schemacs regexp-opt)' already
    ;; imports *this* library for `regexp-quote' - importing it back
    ;; would be a cycle. They live here, as `locate-file-internal' lives
    ;; in fileio.sld.

    (define (subregexp-context-p regexp pos . rest)
      ;; GNU Emacs's `subregexp-context-p' (`subr.el'): "Return non-nil
      ;; if POS is in a normal subregexp context in REGEXP. A subregexp
      ;; context is one where a sub-regexp can appear. A non-subregexp
      ;; context is for example within brackets, or within a repetition
      ;; bounds operator `\\={...\\}', or right after a `\\'. If
      ;; START is non-nil, it should be a position in REGEXP, smaller
      ;; than POS, and known to be in a subregexp context."
      ;;
      ;; **A departure in *implementation*, not in meaning.** Emacs
      ;; reuses its regexp parser here: it matches the prefix against
      ;; the empty string and treats "Unmatched [ or [^", "Unmatched
      ;; \\{" and "Trailing backslash" as the non-context answers.
      ;; This engine's parser words two of those differently ("Invalid
      ;; regular expression" for the unclosed bracket), so the state is
      ;; scanned directly - the same three situations, decided rather
      ;; than diagnosed by message.
      ;;--------------------------------------------------------------
      (let ((start (if (pair? rest) (or (car rest) 0) 0))
            (len (string-length regexp)))
        (let loop ((i start))
          (cond
           ((>= i pos) #t)
           ;; "right after a `\\'": the escape and its character are
           ;; both skipped; an escape that would swallow POS is not a
           ;; context.
           ((char=? (string-ref regexp i) #\\)
            (if (>= (+ i 1) pos) #f (loop (+ i 2))))
           ((char=? (string-ref regexp i) #\[)
            ;; "within brackets": runs to its closing `]', where a
            ;; leading `]' (after an optional `^') is a member.
            (let scan ((j (+ i 1)) (first? #t))
              (cond ((>= j pos) #f)
                    ((and (char=? (string-ref regexp j) #\\)
                          (< (+ j 1) len))
                     (scan (+ j 2) #f))
                    ((and first? (char=? (string-ref regexp j) #\^))
                     (scan (+ j 1) #t))
                    ((and first? (char=? (string-ref regexp j) #\]))
                     (scan (+ j 1) #f))
                    ((char=? (string-ref regexp j) #\])
                     (loop (+ j 1)))
                    (else (scan (+ j 1) #f)))))
           ((and (char=? (string-ref regexp i) #\\)
                 (< (+ i 2) len)
                 (char=? (string-ref regexp (+ i 1)) #\{))
            ;; "within a repetition bounds operator `\\{...\\}'"
            (let scan ((j (+ i 2)))
              (cond ((>= j pos) #f)
                    ((and (char=? (string-ref regexp j) #\\)
                          (< (+ j 1) len)
                          (char=? (string-ref regexp (+ j 1)) #\}))
                     (loop (+ j 2)))
                    (else (scan (+ j 1))))))
           (else (loop (+ i 1)))))))

    (define (regexp-opt-depth regexp)
      ;; GNU Emacs's `regexp-opt-depth' (`regexp-opt.el'): "Return the
      ;; depth of REGEXP. This means the number of non-shy regexp
      ;; grouping constructs (parenthesized expressions) in REGEXP."
      ;;
      ;; The C validates the pattern with `(string-match regexp "")' and
      ;; then searches for `\\(\\(\\?[0-9]*:\\)?' over it; this
      ;; library sits below the search library, so the same two things
      ;; are done by a scan: a `\(' is a group unless `?[0-9]*:' follows
      ;; it, and the pattern's balance is checked on the way.
      ;;--------------------------------------------------------------
      (let ((len (string-length regexp)))
        (let loop ((i 0) (count 0) (open 0))
          (cond
           ((>= i len) count)
           ((char=? (string-ref regexp i) #\\)
            (cond
             ((>= (+ i 1) len) count)  ; a trailing backslash: nothing to count
             ;; `\(' - a group unless the shy/numbered marker follows
             ((char=? (string-ref regexp (+ i 1)) #\()
              (let shy ((j (+ i 2)))
                (cond
                 ((and (< j len) (char=? (string-ref regexp j) #\?))
                  ;; `?', then digits, then `:'
                  (let digits ((k (+ j 1)))
                    (cond ((and (< k len)
                                (char>=? (string-ref regexp k) #\0)
                                (char<=? (string-ref regexp k) #\9))
                           (digits (+ k 1)))
                          ((and (< k len) (char=? (string-ref regexp k) #\:))
                           (loop (+ k 1) count open))
                          (else (loop (+ i 2) (+ count 1) (+ open 1))))))
                 (else (loop (+ i 2) (+ count 1) (+ open 1))))))
             ;; `\)' closes one
             ((char=? (string-ref regexp (+ i 1)) #\))
              (if (> open 0) (loop (+ i 2) count (- open 1)) (loop (+ i 2) count open)))
             (else (loop (+ i 2) count open))))
           (else (loop (+ i 1) count open))))))

    (define (syntax-propertize-precompile-rules rules)
      ;; `syntax-propertize-precompile-rules' (`syntax.el:207'): "Return
      ;; a precompiled form of RULES to pass to `syntax-propertize-rules'."
      ;; In the C it is `(quote ,rules)'; there is nothing to precompile
      ;; in either implementation, so this answers the rules.
      ;;--------------------------------------------------------------
      rules)

    (define (%shift-groups-and-backrefs re n)
      ;; "Shift the group numbers and back-references in RE by N"
      ;; (`syntax.el:238'). `\(?3:' becomes `\(?5:' at N = 2, and a
      ;; `\2' back reference becomes `\4' - but only where a
      ;; sub-regexp can appear (`subregexp-context-p'), never in a
      ;; bracket expression or a repetition bound.
      ;;--------------------------------------------------------------
      (let* ((len (string-length re))
             (out (open-output-string)))
        (let loop ((i 0))
          (if (>= i len)
              (get-output-string out)
              (let ((c (string-ref re i)))
                (cond
                 ;; `\(?N:' - an explicitly numbered group
                 ((and (char=? c #\\)
                       (< (+ i 2) len)
                       (char=? (string-ref re (+ i 1)) #\()
                       (char=? (string-ref re (+ i 2)) #\?))
                  (let digits ((k (+ i 3)))
                    (cond
                     ((and (< k len)
                           (char>=? (string-ref re k) #\0)
                           (char<=? (string-ref re k) #\9))
                      (digits (+ k 1)))
                     ((and (> k (+ i 3)) (< k len) (char=? (string-ref re k) #\:))
                      (write-string (substring re i (+ i 3)) out)
                      (write-string (number->string
                                     (+ n (string->number (substring re (+ i 3) k))))
                                    out)
                      (write-string ":" out)
                      (loop (+ k 1)))
                     (else (write-char c out) (loop (+ i 1))))))
                 ;; `\N' - a back reference, shifted where a sub-regexp
                 ;; may appear
                 ((and (char=? c #\\)
                       (< (+ i 1) len)
                       (char>=? (string-ref re (+ i 1)) #\1)
                       (char<=? (string-ref re (+ i 1)) #\9)
                       (subregexp-context-p re i))
                  (write-char #\\ out)
                  (write-string (number->string
                                 (+ n (string->number
                                       (string (string-ref re (+ i 1))))))
                                out)
                  (loop (+ i 2)))
                 (else (write-char c out) (loop (+ i 1)))))))))

    (define (%action-apply! action start end)
      ;; One HIGHLIGHT's action (`syntax.el:250-290'): a descriptor
      ;; string, a procedure, or the `(prog1 X Y ...)' form.
      ;;--------------------------------------------------------------
      (define (apply-value! val)
        (when val (put-text-property start end 'syntax-table val)))
      (cond
       ((string? action) (apply-value! (string-to-syntax action)))
       ((procedure? action) (apply-value! (action)))
       ((and (pair? action) (eq? (car action) 'ignore))
        (for-each (lambda (thunk) (when (procedure? thunk) (thunk))) (cdr action)))
       ((and (pair? action) (eq? (car action) 'prog1))
        (let ((first (car (cdr action))))
          (apply-value! (if (string? first) (string-to-syntax first) (first))))
        (for-each (lambda (thunk) (when (procedure? thunk) (thunk)))
                  (cdr (cdr action))))
       (else #f)))

    (define %last-combined #f)
    (define (syntax-propertize-rules rules)
      ;; "Make a function that applies RULES for use in
      ;; `syntax-propertize-function'. The function will scan the
      ;; buffer, applying the rules where they match. The buffer is
      ;; scanned a single time, like \"lex\" would, rather than once per
      ;; rule."
      ;;--------------------------------------------------------------
      (let* ((n (length rules))
             (offset 0)
             (parts '())
             (branches '()))
        (for-each
         (lambda (rule)
           (let* ((orig-re (car rule))
                  (cases (cdr rule))
                  (zero (assq 0 cases))
                  ;; "If there's more than 1 rule, and the rule want[s] to
                  ;; apply highlight to match 0, create an extra group to
                  ;; be able to tell when *this* match 0 has succeeded."
                  (wrap? (and zero (> n 1)))
                  ;; **`offset' is the OUTER variable**, as the C's
                  ;; `(incf offset)' is: the next rule's groups start
                  ;; after this one's, so the increments have to stick.
                  (_ (when wrap? (set! offset (+ offset 1))))
                  (offset offset)
                  (re (if wrap? (string-append "\\(" orig-re "\\)") orig-re))
                  (re (%shift-groups-and-backrefs re offset))
                  ;; "If some of the subgroup rules include Elisp code,
                  ;; then we need to set the match-data so it's
                  ;; consistent with what the code expects."
                  (shift? (and (> offset 0)
                               (%sp-any (lambda (case) (not (string? (cadr case))))
                                        cases)))
                  (code-offset (if shift? 0 offset))
                  (condition
                   (cond
                    (zero (if (zero? offset)
                              (lambda () #t)
                              (lambda () (match-beginning offset))))
                    ((null? (cdr cases))
                     (let ((g (+ code-offset (car (car cases)))))
                       (lambda () (match-beginning g))))
                    (else
                     (lambda ()
                       (%sp-any (lambda (case)
                                  (match-beginning (+ code-offset (car case))))
                                cases)))))
                  (code
                   (lambda ()
                     (when shift? (%shift-match-data offset))
                     (for-each
                      (lambda (case)
                        (let ((g (+ code-offset (car case)))
                              (action (cadr case)))
                          ;; "If NUMBER did match"
                          (when (match-beginning g)
                            (%action-apply! action
                                            (match-beginning g)
                                            (match-end g)))))
                      cases))))
             (set! parts (cons re parts))
             (set! branches (cons (cons condition code) branches))
             (set! offset (+ offset (regexp-opt-depth orig-re)))))
         rules)
        (let ((combined
               (let join ((ps (reverse parts)) (acc ""))
                 (cond ((null? ps) acc)
                       ((string=? acc "") (join (cdr ps) (car ps)))
                       (else (join (cdr ps)
                                   (string-append acc "\\|" (car ps))))))))
          (set! %last-combined combined)
          (lambda (start end)
            (set-point (current-buffer) start)
            (let loop ()
              (when (and (< (buffer-pt (current-buffer)) end)
                         (re-search-forward combined end #t))
                (let inner ((bs (reverse branches)))
                  (when (pair? bs)
                    (if ((car (car bs)))
                        ((cdr (car bs)))
                        (inner (cdr bs)))))
                (loop)))))))

    ))
