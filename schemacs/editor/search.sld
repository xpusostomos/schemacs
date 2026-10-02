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
          regexp/icase regexp/notbol regexp/noteol string-index)
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
               ((if beginningp car cdr) pair))))))

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
                    #\. #\* #\? #\+ #\[ #\] #\$ #\^ #\\)))

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
               ;; a bracket expression: copied verbatim to its `]'
               ((char=? c #\[)
                (let scan ((j (+ i 1)) (seen-start #f) (bacc (list #\[)))
                  (cond
                   ((>= j (string-length pattern))
                    ;; an unclosed bracket: Emacs's matcher says
                    ;; "Unmatched [" and so does glibc - copy the
                    ;; rest and let the compiler reject it
                    (loop (string-length pattern)
                          (append (reverse bacc) acc)))
                   ((and (char=? (string-ref pattern j) #\])
                         (or seen-start
                             ;; a `]' first in the set is a member
                             (and (>= j (+ i 2))
                                  (char=? (string-ref pattern j) #\]))))
                    ;; hmm - the `]` first in the set is its member;
                    ;; seen-start tracks whether we have passed one
                    ;; character already
                    (loop (+ j 1) (append (reverse (cons #\] bacc)) acc)))
                   (else
                    (scan (+ j 1)
                          (or seen-start
                              (not (char=? (string-ref pattern j) #\^)))
                          (cons (string-ref pattern j) bacc))))))
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
          (let ((rx (make-regexp (%translate-emacs-regexp pattern)
                                 (if icase? regexp/icase 0))))
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
                              (if (= start 0) 0 regexp/notbol))))
          (cond
           ((not m) #f)
           (inhibit (match:start m 0))
           (else
            (%string-match-into-regs m)
            (*last-thing-searched* 'string)
            (match:start m 0))))))

    (define (looking-at regexp)
      ;; GNU Emacs's `looking-at' (search.c:347): "Return t if point is
      ;; right at the start of a match for REGEXP" - the match does not
      ;; move point, and the match data is the buffer's, one-based.
      ;;--------------------------------------------------------------
      (with-current-buffer (current-buffer)
        (let* ((ed (current-buffer))
               (from (text-editor-get-cursor ed))
               (text (text-editor-copy-string ed from (text-editor-char-count ed))))
          (let ((m (regexp-exec (%compile-emacs-regexp regexp (*case-fold-search*))
                                text 0)))
            (cond
             ((not m) #f)
             (else
              (%string-match-into-regs m)
              ;; string positions to buffer positions: point's one-based
              ;; position is the offset
              (match-data--translate (+ 1 from))
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

    (define (%re-search regexp bound noerror count backward)
      ;; `search_command' (search.c) and `search_buffer' for the regexp
      ;; path: find the COUNTth match of REGEXP between point and
      ;; BOUND, NOERROR answering nil for what would signal, and leave
      ;; point at the match's far end (forward) or start (backward),
      ;; answering the point value, as the C's DEFUNs do.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (size (text-editor-char-count ed))
             (limit (or bound
                        (if backward 0 size)))
             (from (text-editor-get-cursor ed)))
        (let loop ((left (max 1 count)) (at from))
          (let ((found
                 (cond
                  ((not backward)
                   (let ((text (text-editor-copy-string
                                ed (min at limit) size)))
                     ;; `regexp/notbol': a match may not begin at
                     ;; `^' when the start is not the buffer's
                     ;; beginning - `re_search' says so for the C
                     (let ((m (regexp-exec
                               (%compile-emacs-regexp regexp (*case-fold-search*))
                               text 0
                               (if (= (min at limit) 0) 0 regexp/notbol))))
                       (and m
                            (let ((s (+ (min at limit) (match:start m 0)))
                                  (e (+ (min at limit) (match:end m 0))))
                              (if (<= e limit) (cons s e) #f))))))
                  (else
                   ;; backward: try each start downward, the way
                   ;; `re_search' walks back
                   (let try ((s (min at limit)))
                     (cond
                      ((< s 0) #f)
                      ((< s limit)
                       (let ((text (text-editor-copy-string ed s size)))
                         (let ((m (regexp-exec
                                   (%compile-emacs-regexp regexp (*case-fold-search*))
                                   text 0)))
                           (if (and m (<= (+ s (match:end m 0)) limit)
                                    ;; a backward search's match must
                                    ;; END at or before the start point
                                    ;; we began at - which AT already
                                    ;; says
                                    )
                               (cons s (+ s (match:end m 0)))
                               (try (- s 1))))))
                      (else #f)))))))
            (cond
             ((not found)
              (if noerror #f (error "Search failed" regexp)))
             ((> left 1) (loop (- left 1) (if backward (car found) (cdr found))))
             (else
              (text-editor-set-cursor ed
                                      (if backward (car found) (cdr found)))
              (%string-match-into-regs
               ;; re-derive the match object for the data
               (regexp-exec (%compile-emacs-regexp regexp (*case-fold-search*))
                            (text-editor-copy-string
                             ed (car found) (cdr found))
                            0))
              (match-data--translate (+ 1 (car found)))
              (*last-thing-searched* (current-buffer))
              (+ 1 (if backward (car found) (cdr found)))))))))

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

