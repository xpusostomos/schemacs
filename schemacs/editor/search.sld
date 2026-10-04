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
          match:substring match:start match:end match:count)
    ;; the cxr accessors are Guile's, as `(schemacs editor editfns)'s
    ;; import of them is
    (only (guile) cadr caddr cddr cdddr cadddr
          make-regexp regexp-exec
          regexp/icase regexp/newline regexp/notbol regexp/noteol
          string-index)
    (only (schemacs editor engine)
          copy-marker marker-buffer marker-position marker-type?
          set-marker! text-editor-type?
          text-editor-char-count text-editor-copy-string
          text-editor-delete-from-cursor text-editor-get-cursor
          text-editor-insert text-editor-search-backward
          text-editor-search-forward text-editor-set-cursor)
    ;; `*case-fold-search*' is the case folding every search here
    ;; consults (`case-fold-search', buffer.c:6009), `with-current-buffer'
    ;; what `looking-at' and the like read the buffer through.
    (only (schemacs editor buffer)
          *case-fold-search* current-buffer with-current-buffer)
    (only (schemacs editor frame) current-editor)
    ;; The position answers are one-based and the engine's are
    ;; zero-based; the conversion is at the edges only, as everywhere
    ;; else in the Emacs-named layer.
    (only (schemacs editor editfns)
          bobp buffer-substring delete-region eobp goto-char insert
          point point-min point-max save-excursion)
    (only (schemacs editor simple) word-char?)
    ;; The case transfer of `replace-match' casifies the replacement
    ;; with the string case functions.
    (only (schemacs editor casefiddle)
          casify-region capitalize downcase upcase upcase-initials)
    (only (guile) string-index)
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
                 (if (marker-type? v) (marker-position v) v)))))))

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
                                     (copy-marker buffer (- (cdr pair) 1)))
                                 (cons (if as-integers
                                           (car pair)
                                           (copy-marker buffer
                                                        (- (car pair) 1)))
                                       acc)))))))))

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
                (set-marker! (car l) #f))
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
             ((text-editor-type? (car l))
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
                              ((marker-type? beg)
                               (cons (+ 1 (marker-position beg))
                                     (and (marker-type? end)
                                          (+ 1 (marker-position end)))))
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
      ;;--------------------------------------------------------------
      (memv c (list #\w #\W #\b #\B #\< #\>
                    #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9
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

    (define (%translate-emacs-regexp pattern)
      ;; An Emacs regexp spelled as the Emacs regexp dialect spells
      ;; it, into the ERE that matches the same: the group, alternation
      ;; and interval syntax swaps the escaped and unescaped forms -
      ;; `\(' is a group here and a literal there - and what is
      ;; special in ERE unescaped (`(' `)' `|' `{') is literal in an
      ;; Emacs pattern, so it is escaped. Bracket expressions are
      ;; copied verbatim, the way both dialects read them.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length pattern))
            (list->string (reverse acc))
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
                       ;; the escaped-and-special-to-ERE swaps
                       ((memv c2 '(#\( #\) #\| #\{ #\}))
                        (loop (+ i 2) (cons c2 acc)))
                       ((%pass-through-escape c2)
                        (loop (+ i 2) (cons c2 (cons #\\ acc))))
                       ((%untranslated-escape c2)
                        (error "Regexp escape this engine does not implement"
                               (string #\\ c2)))
                       ;; a shy group, or `\(?N:M\)': no ERE spelling
                       ((char=? c2 #\?)
                        (error "Regexp escape this engine does not implement" "\\(?"))
                       (else
                        ;; anything else: the character itself, as
                        ;; regex-emacs.c's backslash default does
                        (loop (+ i 2) (cons c2 acc)))))))
               ;; ERE specials that are literal in an Emacs pattern
               ((memv c '(#\( #\) #\| #\{))
                (loop (+ i 1) (cons c (cons #\\ acc))))
               (else (loop (+ i 1) (cons c acc))))))))

    (define (%compile-emacs-regexp pattern icase?)
      ;; Compile PATTERN as an Emacs pattern: through `%emacs-ere',
    ;; with a cache standing for `regexp_cache'.
      ;;--------------------------------------------------------------
      (let ((key (cons pattern icase?)))
        (cond
         ((assoc key %regexp-cache) (cadr (assoc key %regexp-cache)))
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
          (let ((rx (make-regexp (%translate-emacs-regexp pattern)
                                 (if icase? regexp/icase 0)
                                 regexp/newline)))
            (set! %regexp-cache
                  (cons (list key rx)
                        (let trim ((l %regexp-cache) (n 0))
                          (cond ((>= n 16) '())
                                ((null? l) '())
                                (else (cons (car l)
                                            (trim (cdr l) (+ n 1))))))))
            rx)))))

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
      ;;--------------------------------------------------------------
      (let* ((n (max (match:count match)
                     (length (or (*search-regs*) '()))))
             (regs (make-list n #f)))
        (let loop ((i 0))
          (when (< i (match:count match))
            (let ((s (match:start match i))
                  (e (match:end match i)))
              ;; a subexpression that did not match answers #f for
              ;; both (`(-1 . -1)' in ice-9/regex.scm)
              (if s
                  (list-set! regs i (cons s e))
                  #f))
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
      (let* ((start (if (pair? args) (car args) 0))
             (inhibit (and (pair? args) (pair? (cdr args)) (cadr args)))
             (start (if (< start 0) (+ start (string-length string)) start))
             (icase? (*case-fold-search*)))
        (let ((m (regexp-exec (%compile-emacs-regexp pattern icase?)
                              string start
                              (%bol-flags string start))))
          (cond
           ((not m) #f)
           (inhibit (match:start m 0))
           (else
            (%string-match-into-regs m)
            (*last-thing-searched* 'string)
            (match:start m 0))))))

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
      ;; The whole buffer text goes in with point as the offset, as the
      ;; C hands `re_match_2' the whole accessible portion, so the
      ;; positions that come back are the buffer's own and `^' is
      ;; judged against the real character before point.
      ;;--------------------------------------------------------------
      (with-current-buffer (current-buffer)
        (let* ((ed (current-buffer))
               (from (text-editor-get-cursor ed))
               (text (text-editor-copy-string ed 0 (text-editor-char-count ed))))
          (let ((m (regexp-exec (%compile-emacs-regexp regexp (*case-fold-search*))
                                text from (%bol-flags text from))))
            (cond
             ;; "right at the start of a match": a match further along
             ;; is not one at point, and answers the C's `-1' / nil.
             ((or (not m) (not (= (match:start m 0) from))) #f)
             (else
              (%string-match-into-regs m)
              ;; zero-based buffer positions to one-based ones; the
              ;; match was made against the buffer itself, so nothing
              ;; else is added
              (match-data--translate 1)
              (*last-thing-searched* (current-buffer))
              #t))))))

    (define (looking-back regexp . args)
      ;; GNU Emacs's `looking-back' (subr.el): "Return non-nil if text
      ;; before point matches regular expression REGEXP." The C's
      ;; shape is a backward search for `\<REGEXP\>\=' which the
      ;; substrate has no `\=' to spell; the honest stand-in searches
      ;; every start from point backward for a match that ends at
      ;; point, which is what GREEDY-less `looking-back' means. LIMIT
      ;; is the lowest start worth trying; GREEDY is not ported
      ;; (`save-restriction' and the extension walk are not here).
      ;;--------------------------------------------------------------
      (let* ((limit (if (pair? args) (car args) (point-min)))
             (pt (point))
             (start (max limit (point-min))))
        (let loop ((s (- pt 1)))
          (cond
           ((< s start) #f)
           ((string-match regexp (buffer-substring s (point-max)) 0)
            ;; the match must reach point: the text from S to PT is
            ;; what matches
            (and (= (match-end 0) (- pt s)) s))
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
             (limit (or bound (text-editor-char-count ed))))
        (let loop ((left (max 1 count)) (from (text-editor-get-cursor ed)))
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
              (text-editor-set-cursor ed found)
              (%set-search-regs (+ 1 (- found (string-length string)))
                                (string-length string))
              (+ 1 found)))))))

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
             (limit (or bound 0)))
        (let loop ((left (max 1 count)) (from (text-editor-get-cursor ed)))
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
              (text-editor-set-cursor ed found)
              (%set-search-regs (+ 1 found) (string-length string))
              (+ 1 found)))))))

    (define (%search-window-text ed at limit backward)
      ;; The stretch of the buffer the search from AT can reach, and AT's
      ;; offset within it.
      ;;
      ;; The C hands `re_search_2' *pointers into the buffer* -
      ;; "re_search_2 (bufp, (char *) p1, s1, (char *) p2, s2, ...)"
      ;; (search.c:1207) - with `stop' limiting how far it scans, so it
      ;; never materialises the text at all. Guile's `regexp-exec' wants a
      ;; string, so one has to be made; but only of the stretch the search
      ;; can reach, which is what keeps this from being O(buffer) per
      ;; search.
      ;;
      ;; It used to copy the WHOLE buffer on every call, and since every
      ;; font-lock keyword is a search, that made fontification
      ;; quadratic. Measured on a 5815-character buffer, 1000 calls:
      ;; `(re-search-forward "^[^ \n]" 47 t)' took 5.52s and the same
      ;; search bounded to the whole buffer took 5.70s - a bound that
      ;; costs nothing is a bound that is not being used.
      ;;
      ;; The window begins one character *before* the search's start
      ;; because `^' is judged by `%bol-flags', which reads the character
      ;; before it; without that character every window's first position
      ;; would look like a line beginning.
      ;;
      ;; Windowing is sound rather than a guess because the two
      ;; constructs that could tell a window from the whole buffer are
      ;; already refused: `%emacs-ere' rejects `\=' (buffer start) and
      ;; `\'' (buffer end) with an error.
      ;;
      ;; Forward reaches [AT, LIMIT); backward walks the start position
      ;; down from AT to LIMIT and takes only a match that *ends* by AT,
      ;; so it reaches [LIMIT, AT).
      ;;--------------------------------------------------------------
      (let* ((wstart (min (if backward (max 0 (- limit 1)) (max 0 (- at 1)))
                          (if backward at limit)))
             (wend (if backward at limit)))
        (cons (text-editor-copy-string ed wstart wend) wstart)))

    (define (%re-search regexp bound noerror count backward)
      ;; `search_command' (search.c) and `search_buffer' for the regexp
      ;; path: find the COUNTth match of REGEXP between point and
      ;; BOUND, NOERROR answering nil for what would signal, and leave
      ;; point at the match's far end (forward) or start (backward),
      ;; answering the point value, as the C's DEFUNs do.
      ;;
      ;; The text searched is `%search-window-text''s window rather than
      ;; the whole buffer; positions are the buffer's, and the window's
      ;; offsets are added and subtracted at the two ends of the search.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (size (text-editor-char-count ed))
             (limit (or bound
                        (if backward 0 size)))
             (from (text-editor-get-cursor ed)))
        (let loop ((left (max 1 count)) (at from))
          (let* ((window (%search-window-text ed at limit backward))
                 (whole (car window))
                 (base (cdr window))
                 (found
                  (cond
                   ((not backward)
                    ;; Forward: `re_search_2' with `start' at point,
                    ;; `range' up to the bound, and the `stop' argument
                    ;; the bound as well - so a match running past the
                    ;; bound is not one, and the next position is tried.
                    (let* ((here (- (min at limit) base))
                           (m (regexp-exec
                               (%compile-emacs-regexp regexp (*case-fold-search*))
                               whole here (%bol-flags whole here))))
                      (and m
                           (let ((s (+ (match:start m 0) base))
                                 (e (+ (match:end m 0) base)))
                             (if (<= e limit) (list m s e) #f)))))
                   (else
                    ;; Backward: `re_search_2' with a negative `range'
                    ;; walks the start position down from point to the
                    ;; bound and takes the first one the pattern matches
                    ;; at; its `stop' is point - "Don't allow match past
                    ;; current point" - which is what steps the walk back
                    ;; on a repeated search, and why the end test is
                    ;; against `at' and not the bound. The walk begins
                    ;; *at* point; beginning it at the bound instead is
                    ;; what made every `re-search-backward' answer nil.
                    (let try ((s at))
                      (cond
                       ((< s limit) #f)
                       (else
                        (let* ((here (- s base))
                               (m (regexp-exec
                                   (%compile-emacs-regexp regexp (*case-fold-search*))
                                   whole here (%bol-flags whole here))))
                          (if (and m
                                   (= (+ (match:start m 0) base) s)
                                   (<= (+ (match:end m 0) base) at))
                              (list m s (+ (match:end m 0) base))
                              (try (- s 1)))))))))))
            (cond
             ((not found)
              (if noerror #f (error "Search failed" regexp)))
             ((> left 1) (loop (- left 1) (if backward (cadr found)
                                              (caddr found))))
             (else
              (text-editor-set-cursor ed
                                      (if backward (cadr found) (caddr found)))
              ;; the registers of the match actually made, not a
              ;; re-derivation of it from a copy of the matched text -
              ;; the copy made `^' and the subexpression offsets answers
              ;; about the copy, not about the buffer.
              ;;
              ;; The window's own offset goes on here as well as the
              ;; 0-to-1: the match object's positions are relative to the
              ;; text that was searched, and that text used to be the
              ;; whole buffer (so its offset was 0 and this line was
              ;; right); with the search windowed to what it can reach,
              ;; leaving the offset out reports every register `base'
              ;; characters too low. Font-lock is where that shows, since
              ;; it searches from the middle of a buffer rather than from
              ;; the beginning.
              (%string-match-into-regs (car found))
              (match-data--translate (+ base 1))
              (*last-thing-searched* (current-buffer))
              (+ 1 (if backward (cadr found) (caddr found))))))))
)

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
                         (cons (buffer-substring
                                (+ 1 (car (list-ref regs sub)))
                                (+ 1 (cdr (list-ref regs sub))))
                               acc)))
                 ((and (char<=? #\1 c #\9)
                       (< (- (char->integer c) 48) (length regs)))
                  (let ((pair (list-ref regs (- (char->integer c) 48))))
                    (cond
                     ((and pair (>= (car pair) 1))
                      (loop (+ i 2)
                            (cons (buffer-substring
                                   (+ 1 (car pair)) (+ 1 (cdr pair)))
                                  acc)))
                     ;; that subexp did not match: nothing
                     (else (loop (+ i 2) acc)))))
                 ((char=? c #\\)
                  (loop (+ i 2) (cons "\\\\" acc)))
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
                 ((char=? c #\\) (loop (+ i 2) (cons "\\\\" acc)))
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
             (size (text-editor-char-count ed))
             ;; `opoint = PT <= sub_start ? PT : max (PT, sub_end) - ZV'
             ;; - the recorded point, negative being an offset from the
             ;; buffer's end
             (pt (+ 1 (text-editor-get-cursor ed)))
             (opoint (if (<= pt sub-start)
                         pt
                         (- (max pt sub-end) (+ 1 size))))
             ;; the case pattern of the matched text
             (case-action
              (if fixedcase 'nochange
                  (%case-action-of (buffer-substring
                                    sub-start sub-end))))
             ;; the substitution, if the replacement is not literal
             (newtext
              (if literal
                  newtext
                  (%substitute-replacement newtext regs sub)))
             (newpoint (+ sub-start (string-length newtext))))
        ;; replace the region, as `replace_range' does - the engine
        ;; boundary takes the one-based positions down to indices
        (text-editor-set-cursor ed (- sub-start 1))
        (text-editor-delete-from-cursor ed (- sub-end sub-start))
        (text-editor-insert ed newtext)
        ;; the match data follows the change, as the C's
        ;; `replace_range' asks `update_search_regs' for
        (%update-search-regs sub-start sub-end newpoint)
        ;; casify the inserted text, as the C calls Fupcase_region /
        ;; Fupcase_initials_region over it
        (cond
         ((eq? case-action 'all-caps)
          (casify-region 'upcase sub-start newpoint))
         ((eq? case-action 'cap-initials)
          (casify-region 'capitalize-up sub-start newpoint))
         (else #f))
        ;; put point back where it was, then move it "officially" to
        ;; the replacement's end
        (text-editor-set-cursor
         ed (max 0 (min size
                        (if (< opoint 0)
                            (+ (+ 1 size) opoint)
                            (- opoint 1)))))
        (text-editor-set-cursor ed (- newpoint 1))
        #f))

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
                   (buffer-substring beg end))))))

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
          (let ((string (buffer-substring
                         (match-beginning 0) (match-end 0))))
            (match-data--translate (- (match-beginning 0)))
            (replace-match replacement fixedcase literal string))))
    )))

