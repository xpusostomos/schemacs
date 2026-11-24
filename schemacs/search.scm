(define-library (schemacs search)
  ;; This library mirrors GNU Emacs's `search.c': the search and match
  ;; primitives - `search-forward' and `search-backward' (which were
  ;; here in `(schemacs editfns)' and have come home to the file
  ;; the C has them in), `string-match', `looking-at',
  ;; `re-search-forward' and `re-search-backward', the match data -
  ;; `match-data', `set-match-data', `match-beginning', `match-end',
  ;; `match-data--translate' - and `replace-match', `regexp-quote' and
  ;; `match-substitute-replacement'.
  ;;
  ;; **The regular expression engine is Emacs's own.** It is
  ;; `src/regex-emacs.c', ported in `(schemacs regex-emacs)` -
  ;; the compiler, the fastmap, the backtracking matcher with its
  ;; memoization, and `re_search' - and it replaced Guile's glibc ERE
  ;; in 2026-11-21. What that bought, beyond fidelity, is the whole
  ;; dialect rather than a translated subset: leftmost-FIRST
  ;; alternation (`a\|ab' matches "a", not "ab"), the syntax table's
  ;; `\w'/`\s'/`\_<'/`\_>', categories `\c'/`\C', `\=' and the buffer
  ;; anchors `` \` ``/`\'`, shy and explicitly numbered groups, and a
  ;; match over the buffer read through its gap instead of a copied
  ;; window. The old translation layer, its 512-character search
  ;; window and the `\_<' assertions it simulated are gone.
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
    ;; the cxr accessors are Guile's, as `(schemacs editfns)'s
    ;; import of them is. `string-index' is for `replace-match''s
    ;; `\\' scan. The regexp substrate's `make-regexp'/`regexp-exec'
    ;; and `(ice-9 regex)''s accessors left with the ERE translator.
    (only (guile) cadr caddr cddr cdddr cadddr string-index)
    (only (schemacs marker)
          make-marker marker-buffer marker-position markerp set-marker)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs intervals) make-buffer-string)
    
    ;; `*case-fold-search*' is the case folding every search here
    ;; consults (`case-fold-search', buffer.c:6009), `with-current-buffer'
    ;; what `looking-at' and the like read the buffer through. The
    ;; line-break cache accessors and `cache-long-scans' are the buffer's
    ;; own slots (`buffer.c`), which `find-newline` below reads.
    (only (schemacs buffer)
          *case-fold-search* current-buffer with-current-buffer
          text-editor-text
          %text-editor-newline-cache set!%text-editor-newline-cache
          text-editor-cache-long-scans set-point bufferp
          buffer-beg buffer-z buffer-pt)
    ;; The raw character store: `buffer.h`'s macros, which the scans below
    ;; read character by character as `find_newline` does with
    ;; `FETCH_CHAR`.
    (only (schemacs buffer-text)
          buffer-text-ref code-point->char
          ;; The scan's side of `buffer-text-ref' - see the comment in
          ;; `text-editor-search-forward'.
          buffer-text-store buffer-text-base buffer-text-gpt
          buffer-text-gap-size buffer-text-z)
    ;; The store's own type. `u32vector-ref' is what `BUF_BEG_ADDR'
    ;; indexing is in Scheme; it is not in `(scheme base)' nor in
    ;; `(rnrs bytevectors)' on this Guile - `(guile)' is where the
    ;; typed-vector accessors live, as `buffer-text.scm' found.
    (only (guile) u32vector-ref)
    ;; `syntax-table' is what a match's context carries (the engine
    ;; reads it), `string-to-syntax' is `syntax-propertize-rules'',
    ;; and the propertize hook installs this library's
    ;; `save-match-data'.
    (only (schemacs syntax)
          syntax-table string-to-syntax
          *internal-syntax-propertize-function*)
    ;; The case table the regexp engine folds with: `search.c` passes
    ;; the buffer's CANON slot as the compiler's TRANSLATE when
    ;; `case-fold-search' is non-nil (`string_match_1', `:398'). The
    ;; ASCII table is what a search outside any buffer gets - Emacs
    ;; always has a current buffer, this tree can be asked without one.
    (only (schemacs casetab) case-canon-table *ascii-canon-table*)
    ;; `\cC' and `\CC' read the buffer's category table while matching,
    ;; as `categoryspec' does through `CATEGORYP' (`regex-emacs.c').
    (only (schemacs category) category-table)
    ;; **The regexp engine is Emacs's own** - `src/regex-emacs.c',
    ;; ported in `(schemacs regex-emacs)'. The header of this
    ;; library said for two years that the engine was not ported and
    ;; that Guile's glibc ERE stood in for it; it is ported now, and
    ;; this file is the `regexp_cache` and `search_regs` around it, as
    ;; `search.c` is around the C engine.
    (only (schemacs regex-emacs)
          make-re-pattern-buffer re-pattern-buffer-nsub
          re-pattern-buffer-translate make-re-fastmap re-compile-pattern
          make-re-registers re-registers-num
          re-registers-start re-registers-end
          string->re-text buffer->re-text make-re-context
          re-match-2 re-search)
    ;; `syntax-propertize-rules' writes the `syntax-table' property
    ;; (`put-text-property'); its `subregexp-context-p' is below.
    (only (schemacs textprop) put-text-property)
    ;; The line-break cache: `region-cache.c`, which is the buffer's
    ;; `newline_cache` there. It is what makes searching a buffer with
    ;; very long lines affordable - a stretch already searched and found
    ;; free of line breaks is skipped whole rather than scanned again.
    ;; **It came here with the scans** (2026-10-12); the engine held this
    ;; import before, for the same reason.
    (only (schemacs region-cache)
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
    (only (schemacs syntax) word-char?)
    ;; The case transfer of `replace-match' casifies the replacement
    ;; with the string case functions.
    (only (schemacs casefiddle)
          casify-region upcase upcase-initials)
    ;; The seam `insdel.scm` declares for `update_search_regs`: it is
    ;; `search.c`'s function (this file's) and `replace_range`, below, is
    ;; what calls it.
    (only (schemacs insdel) *update-search-regs-function* replace-range)
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
   match-string match-string-no-properties
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
      ;; GNU Emacs's `match_limit' (`search.c:2776'):
      ;;
      ;;     if (n < 0 || n >= search_regs.num_regs
      ;;         || search_regs.start[n] < 0)
      ;;       return Qnil;
      ;;
      ;; **`#f' in all three cases**, including no match data at all -
      ;; `(set-match-data nil)' then `(match-beginning 0)' is nil in
      ;; Emacs, measured. This port raised twice there ("Args out of
      ;; range" for a negative N, "No match data, because no search
      ;; succeeded" with no registers), which `narrow-to-page` walks
      ;; straight into: it clears the match data with
      ;; `(set-match-data nil)' and then asks `(match-beginning 0)'.
      ;; The only error the C raises is `CHECK_FIXNUM`'s.
      ;;--------------------------------------------------------------
      (cond
       ((not (integer? n)) (error "Wrong type argument: fixnump" n))
       ((< n 0) #f)
       ((not (*search-regs*)) #f)
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
      ;; The value `match-data' returns (`search.c:2860'): the
      ;; registers flattened to `(BEG END ...)' - `#f' for *each*
      ;; element of a register that did not match, markers in the
      ;; buffer that was searched unless INTEGERS, zero-based integers
      ;; in a string - with the *trailing* non-matching registers
      ;; ELIDED. The C tracks that with `len = 2 * i + 2', advanced
      ;; only for a matching register, so an unmatched register in the
      ;; middle is two nils and an unmatched one at the end is absent:
      ;; `(string-match "^\\(a\\)?\\(b\\)\\(c\\)?$" "b")' is
      ;; `(0 1 nil nil 0 1)'.
      ;;
      ;; A buffer search with INTEGERS appends the buffer itself, as
      ;; the C does.
      ;;--------------------------------------------------------------
      (let* ((string-search? (eq? 'string (*last-thing-searched*)))
             (regs (or (*search-regs*) '()))
             (as-integers (or string-search? integers))
             ;; a buffer search's markers point into the buffer the
             ;; search was made in - the C's `last_thing_searched'
             (buffer (and (not string-search?) (*last-thing-searched*)))
             (last-used (let loop ((i (- (length regs) 1)))
                          (cond ((< i 0) -1)
                                ((list-ref regs i) i)
                                (else (loop (- i 1)))))))
        (let build ((i 0) (acc '()))
          (cond
           ((> i last-used)
            (reverse
             (if (and (not string-search?) integers)
                 (cons buffer acc)
                 acc)))
           (else
            (let ((pair (list-ref regs i)))
              (if pair
                  (build (+ i 1)
                         (cons (if as-integers
                                   (cdr pair)
                                   (%match-marker buffer (cdr pair)))
                               (cons (if as-integers
                                         (car pair)
                                         (%match-marker buffer (car pair)))
                                     acc)))
                  (build (+ i 1) (cons #f (cons #f acc))))))))))

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
             (reuse (and (pair? args) (pair? (cdr args))
                         (let ((r (cadr args))) (and (pair? r) r))))
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
         ((not (*last-thing-searched*))
          ;; "If REUSE is not usable, cons up the values and return
          ;; them" - and this test comes *before* REUSE is looked at,
          ;; so a REUSE given to a session with no search is returned
          ;; as it stands by neither branch: the C's early return is
          ;; `return Qnil' (`search.c:2849').
          #f)
         ((not reuse)
          ;; The C returns a *zero-length list* when every register is
          ;; unanswered (the trailing-nil trim reaches index 0), and
          ;; Emacs's empty list is `nil'. Here `'()` is a true value,
          ;; so the empty answer is `#f' - ported Emacs code tests
          ;; `(match-data)' for nil (`c-ml-string-in-end-delim' does).
          (let ((v (%regs->match-data integers)))
            (if (null? v) #f v)))
         (else
          ;; REUSE is destructively filled; if the values do not fill
          ;; it the rest is set to nil, and if it is too short the
          ;; remainder is consed on (`search.c:2897').
          (let ((values (%regs->match-data integers)))
            (let fill ((i 0) (tail reuse) (prev #f))
              (cond
               ((pair? tail)
                (set-car! tail (if (< i (length values))
                                   (list-ref values i)
                                   #f))
                (fill (+ i 1) (cdr tail) tail))
               ((< i (length values))
                (set-cdr! prev (list-copy (list-tail values i)))
                reuse)
               (else reuse))))))))

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
       ((not list)
        ;; "The registers beyond the list are cleared, which is the C's
        ;; final loop" - and for a nil LIST *that is every register*
        ;; (`for (i = length; i < search_regs.num_regs; i++) start[i] =
        ;; -1;' with length 0). Emacs measured: a search, then
        ;; `(set-match-data nil)', then `(match-beginning 0)' answers
        ;; nil. Returning without clearing left the last search's
        ;; registers readable, which `narrow-to-page` walks into: it
        ;; clears the match data and asks `(match-beginning 0)' to learn
        ;; whether `forward-page' matched.
        (*search-regs*
         (let ((n (length (or (*search-regs*) '()))))
           (make-list n #f)))
        (*last-thing-searched* 'string)
        #f)
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
    ;; The compiled pattern cache (`regexp_cache')
    ;;------------------------------------------------------------------

    (define %regexp-cache '())
    ;; ^ `search.c`'s `searchbuf_head' list: the compiled patterns,
    ;; most recent first, bounded to 16 entries as the C's cache is.

    (define (%regexp-cache-lookup key)
      ;; The cache entry for KEY - `(KEY COMPILED)' - or #f. KEY is
      ;; `(PATTERN TRANSLATE TABLE)': the C's cache compares
      ;; `cp->buf.translate' itself (`search.c:220'), not a flag, so a
      ;; buffer with its own case table cannot reuse an entry compiled
      ;; with another's. `assoc' would compare the key with `equal?' -
      ;; which walks the whole char-table - so the parts are compared
      ;; here.
      ;;--------------------------------------------------------------
      (let loop ((l %regexp-cache))
        (cond ((null? l) #f)
              ((and (string=? (car key) (car (car (car l))))
                    (eq? (list-ref key 1) (list-ref (car (car l)) 1))
                    (eq? (list-ref key 2) (list-ref (car (car l)) 2)))
               (car l))
              (else (loop (cdr l))))))

    (*internal-syntax-propertize-function*
     (lambda (thunk)
       ;; `internal--syntax-propertize''s `save-match-data'
       ;; (`syntax.el:481'), installed from here because
       ;; `save-match-data' is this library's and `(schemacs editor
       ;; syntax)' is below it. This runs *from inside a regexp match*:
       ;; the mode's propertize function runs searches of its own, and
       ;; without the save they overwrite the match data of the match
       ;; being attempted - font-lock reported "No match %s in
       ;; highlight" on a file whose `syntax-propertize-function' had
       ;; not run yet.
       ;;--------------------------------------------------------------
       (save-match-data (thunk))))

    (define-record-type <compiled-regexp>
      ;; What `regexp_cache` holds: the compiled engine buffer, and the
      ;; two facts every match needs from it - the TRANSLATE table the
      ;; compiler folded with (nil when `case-fold-search' is off) and
      ;; the subexpression count, which is the register count the
      ;; matcher fills.
      ;;--------------------------------------------------------------
      (make-compiled-regexp bufp translate nsub)
      compiled-regexp?
      (bufp compiled-regexp-bufp)
      (translate compiled-regexp-translate)
      (nsub compiled-regexp-nsub))

    (define (%current-canon-table)
      ;; The buffer's CANON case table, or the ASCII one when there is
      ;; no current buffer. `case_canon_table' is `buffer.c''s slot.
      ;;--------------------------------------------------------------
      (if (current-buffer) (case-canon-table) *ascii-canon-table*))

    (define (%current-category-table)
      ;; The current buffer's category table (`category-table' answers
      ;; the standard one when a buffer has none). No no-buffer fallback:
      ;; `with-syntax-table' here binds the table even with no current
      ;; buffer, and reading the fallback instead made `\_<'/`\_>' tests
      ;; miss the table they were run under - the standard table's `:'
      ;; is punctuation where Lisp mode's is a symbol constituent.
      ;;--------------------------------------------------------------
      (category-table))

    (define (%compile-emacs-regexp pattern icase?)
      ;; `compile_pattern' (`search.c:197'): the cache lookup and, on a
      ;; miss, `re_compile_pattern' - the engine's own compiler.
      ;;
      ;; **The syntax table is still part of the key.** The compiler
      ;; does not read it (`\w' and `\sC' compile to `syntaxspec'
      ;; opcodes, evaluated by the matcher), but the C's cache entry
      ;; carries the table it was compiled for, and keeping it here
      ;; means a pattern compiled under one buffer's table is never
      ;; handed to a match under another's. It costs nothing: the
      ;; lookup compares the three parts directly.
      ;;
      ;; The engine is handed the pattern as code points, so a
      ;; multibyte pattern needs no `multibyte' flag and a unibyte one
      ;; cannot arise: this tree's strings are code points throughout.
      ;;--------------------------------------------------------------
      (let* ((table (syntax-table))
             ;; `translate' is chosen before the lookup because it is
             ;; part of the key, as `cp->buf.translate' is.
             (translate (and icase? (%current-canon-table)))
             (key (list pattern translate table)))
        (cond
         ((let ((hit (%regexp-cache-lookup key)))
            (and hit (cadr hit))))
         (else
          (let* ((bufp (make-re-pattern-buffer
                        #f (make-re-fastmap 0 #f) translate 0 #f #f #f))
                 (message (re-compile-pattern pattern (string-length pattern)
                                              #f #f bufp)))
            (when message
              ;; The C signals `invalid-regexp' with the message string
              ;; as its data; measured, it prints
              ;; `Invalid regexp: "Invalid content of \\{\\}"'.
              (error "Invalid regexp: ~s" message))
            (let ((compiled (make-compiled-regexp
                             bufp translate (re-pattern-buffer-nsub bufp))))
              (set! %regexp-cache
                    (cons (list key compiled)
                          (let trim ((l %regexp-cache) (n 0))
                            (cond ((>= n 16) '())
                                  ((null? l) '())
                                  (else (cons (car l)
                                              (trim (cdr l) (+ n 1))))))))
              compiled))))))

    ;;----------------------------------------------------------------
    ;; The searches
    ;;------------------------------------------------------------------

    (define re-nregs 30)
    ;; ^ `RE_NREGS' (`regex-emacs.c:885'): the register arrays start
    ;; this long and grow by half again, or to the pattern's count,
    ;; whichever is larger (`re_match_2_internal''s `succeed_label').

    (define (%make-search-registers compiled)
      ;; The C's `struct re_registers' for one match: `num_regs' is the
      ;; larger of what the last search left (the registers never
      ;; shrink), the pattern's `re_nsub + 1' and RE_NREGS - which is
      ;; how `re_match_2_internal' allocates its first set. The arrays
      ;; are filled by the matcher; -1 is its "unset" value.
      ;;--------------------------------------------------------------
      (let ((n (max re-nregs
                    (+ (compiled-regexp-nsub compiled) 1)
                    (length (or (*search-regs*) '())))))
        (make-re-registers n (make-vector n -1) (make-vector n -1))))

    (define (%engine-regs-into-search-regs regs base)
      ;; `re_match_2_internal''s `succeed_label' (`regex-emacs.c:4720')
      ;; as this tree's registers: the engine's text offsets shifted by
      ;; BASE - 0 for a string, BEGV for a buffer - as `(START . END)'
      ;; pairs, `#f' where the register is -1, the arrays' length being
      ;; `num_regs'. Registers past the pattern's own groups are -1 by
      ;; the C's final loop, so they become `#f' here too.
      ;;--------------------------------------------------------------
      (let* ((n (re-registers-num regs))
             (starts (re-registers-start regs))
             (ends (re-registers-end regs))
             (pairs (make-list n #f)))
        (let loop ((i 0))
          (when (< i n)
            (let ((s (if (< i (vector-length starts)) (vector-ref starts i) -1))
                  (e (if (< i (vector-length ends)) (vector-ref ends i) -1)))
              (when (>= s 0)
                (list-set! pairs i (cons (+ base s) (+ base e)))))
            (loop (+ i 1))))
        (*search-regs* pairs)))

    (define (%buffer-re-text ed)
      ;; The buffer's accessible text as a `<re-text>', with no copy:
      ;; the hoisted `BEG_ADDR'/`GPT'/`GAP_SIZE' (`buffer.h') the
      ;; engine's reader indexes, its position 0 being BEGV.
      ;;
      ;; **`buffer->re-text' speaks STORE indexes**, where this tree's
      ;; buffer positions are one-based (`buffer-text-base', Emacs's
      ;; `BEG'): the store index of position P is `P - base'. So the
      ;; three ends are converted here and the text's position 0 is
      ;; `(- BEGV base)'. Passing buffer positions instead skipped the
      ;; first character and stopped one short of the last - every
      ;; match one position early, which is how this was found.
      ;;--------------------------------------------------------------
      (let* ((txt (text-editor-text ed))
             (base (buffer-text-base txt)))
        (buffer->re-text (buffer-text-store txt)
                         (- (buffer-text-gpt txt) base)
                         (buffer-text-gap-size txt)
                         (- (buffer-beg ed) base)
                         (- (buffer-z ed) base))))

    (define (%string-match-context text compiled)
      ;; The context `string_match_1' matches in: the current buffer's
      ;; syntax and category tables (Emacs reads them whatever the
      ;; object is), the pattern's translate table, no buffer, and
      ;; position 0 - the text's own coordinates.
      ;;--------------------------------------------------------------
      (make-re-context text
                       (syntax-table)
                       (%current-category-table)
                       (compiled-regexp-translate compiled)
                       #f #f 0))

    (define (%buffer-match-context text compiled base point)
      ;; The context a buffer search matches in. BASE is BEGV - the
      ;; buffer position of the text's first character, which `\=''s
      ;; `at_dot' and the syntax reader add their offsets to - and
      ;; POINT is the buffer's point, the position `at_dot' compares
      ;; with.
      ;;--------------------------------------------------------------
      (make-re-context text (syntax-table) (%current-category-table)
                       (compiled-regexp-translate compiled)
                       point #t base))

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
             (icase? (*case-fold-search*))
             (compiled (%compile-emacs-regexp pattern icase?))
             (text (string->re-text string))
             (ctx (%string-match-context text compiled))
             (regs (%make-search-registers compiled))
             ;; `re_search' with `startpos = pos', `range = size - pos'
             ;; and `stop = size' (`string_match_1', `search.c:415').
             (found (re-search (compiled-regexp-bufp compiled) text start
                               (- len start) regs len ctx)))
        (cond
         ((< found 0) #f)
         ;; `preserve_match_data' nil: the C asks with `search_regs_1'
         ;; and leaves `search_regs' and `last_thing_searched' alone.
         (inhibit found)
         (else
          (%engine-regs-into-search-regs regs 0)
          (*last-thing-searched* 'string)
          found))))

    (define (string-match-p regexp string . rest)
      ;; GNU Emacs's `string-match-p' (subr.el:5946): "Same as
      ;; `string-match' except this function does not change the match
      ;; data."
      ;;
      ;; It is `subr.el''s and it is here for the same reason
      ;; `looking-at-p' is: `(schemacs subr)' is *below* this
      ;; library, so subr cannot reach `string-match'. The C's fourth
      ;; argument, INHIBIT-MODIFY, is how `string-match' itself says it.
      ;;--------------------------------------------------------------
      (string-match regexp string (if (pair? rest) (car rest) 0) #t))

    (define (looking-at-p regexp)
      ;; GNU Emacs's `looking-at-p' (subr.el): "Same as `looking-at'
      ;; except this function does not change the match data."
      ;;
      ;; It is `subr.el''s, and it is here rather than in
      ;; `(schemacs subr)' because that library is *below* this
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
      ;; The C is `re_match_2 (p1, s1, p2, s2, PT_BYTE - BEGV_BYTE,
      ;; &search_regs, ZV_BYTE - BEGV_BYTE)' (`looking_at_1',
      ;; `search.c:316'): an *anchored* match at point, over the whole
      ;; accessible text with no copy - `BEGV_ADDR' and the gap are the
      ;; engine's own reader here.
      ;;
      ;; An anchored match cannot match "somewhere after point":
      ;; `re_match_2' is asked for a match at the one position, where
      ;; `re_search' would scan forward from it.
      ;;--------------------------------------------------------------
      (with-current-buffer (current-buffer)
        (let* ((ed (current-buffer))
               (from (buffer-pt ed))
               (base (buffer-beg ed))
               (z (buffer-z ed))
               (compiled (%compile-emacs-regexp regexp (*case-fold-search*)))
               (text (%buffer-re-text ed))
               (ctx (%buffer-match-context text compiled base from))
               (regs (%make-search-registers compiled))
               (matched (re-match-2 (compiled-regexp-bufp compiled) text
                                    (- from base) regs (- z base) ctx)))
          (if (< matched 0)
              #f
              (begin
                (%engine-regs-into-search-regs regs base)
                (*last-thing-searched* ed)
                #t)))))

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
      ;; **This is not the C's `\(?:REGEXP\)\=' search.** The port
      ;; predates the engine and asks the same relation the other way
      ;; up: does REGEXP match the *whole* of S..PT? The C's narrowing
      ;; to `(point-min)..start` is the same text, so the copy stops at
      ;; PT. The engine has `\=' now, so this could be rewritten to
      ;; the C's shape; the answers agree, and nothing has needed it.
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
             ;; **The C's test is `(looking-at (concat regexp "\\'"))',
             ;; i.e. a match that starts HERE and reaches PT** - not
             ;; merely one that ends at PT. The difference shows on a
             ;; regexp like `[ \t]*\*/': at a position just before a
             ;; non-space, a match ending at PT still exists further
             ;; along, and the old end-only test extended the match
             ;; over it. Measured in `font-lock''s comment-delimiter
             ;; pass on "/* aaa */": Emacs' answer is 7..10, the
             ;; end-only test gave 1..10.
             (match-at? (lambda (s)
                          (let ((str (make-buffer-string ed s pt)))
                            (and (string-match regexp str 0)
                                 (= (match-beginning 0) 0)
                                 (= (match-end 0) (string-length str)))))))
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
      ;; `(schemacs region-cache)') is consulted on the way, as
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
                             (let ((text (text-editor-text ed)))
                               (let ((c (new-region-cache
                                         (buffer-text-base text)
                                         (buffer-text-z text))))
                                 (set!%text-editor-newline-cache ed c)
                                 c))))))
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
      ;; **The cache's endpoints are the *text*'s; the scan's is the
      ;; restriction's.** `region_cache_forward` reads `BUF_BEG`/`BUF_Z`
      ;; (`region-cache.c`), while the scan still stops at the caller's
      ;; END (ZV forward, BEGV back).
      (let* ((text (text-editor-text ed))
             (beg (buffer-text-base text))
             (z (buffer-text-z text)))
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
      ;; **The cache's endpoints are the *text*'s; the scan's is the
      ;; restriction's.** `region_cache_forward` reads `BUF_BEG`/`BUF_Z`
      ;; (`region-cache.c`), while the scan still stops at the caller's
      ;; END (ZV forward, BEGV back).
      (let* ((text (text-editor-text ed))
             (beg (buffer-text-base text))
             (z (buffer-text-z text)))
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

    ;; **`bol' and `eol' have left, for `(schemacs editfns)'.**
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
              ;; `search_command''s NOERROR rule (`search.c:1072'): a
              ;; non-nil NOERROR other than `t' moves point to LIMIT
              ;; before answering nil; `t' leaves point alone.
              (if (and noerror (not (eq? noerror #t)))
                  (begin (set-point ed limit) #f)
                  (if noerror #f (error "Search failed" string))))
             ((> found limit)
              (if (and noerror (not (eq? noerror #t)))
                  (begin (set-point ed limit) #f)
                  (if noerror #f (error "Search failed" string))))
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
              ;; The C's NOERROR rule, as in `search-forward'.
              (if (and noerror (not (eq? noerror #t)))
                  (begin (set-point ed limit) #f)
                  (if noerror #f (error "Search failed" string))))
             ((< found limit)
              (if (and noerror (not (eq? noerror #t)))
                  (begin (set-point ed limit) #f)
                  (if noerror #f (error "Search failed" string))))
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

    (define (%re-search-forward-1 compiled at limit)
      ;; `search_buffer_re''s forward call (`search.c:1207'):
      ;;
      ;;   re_search_2 (bufp, p1, s1, p2, s2,
      ;;                PT - BEGV, lim - PT, &search_regs, lim - BEGV)
      ;;
      ;; One match at or after AT and ending by LIMIT. Answers
      ;; `(REGS START END BASE)' - the engine's registers and the
      ;; buffer positions of the match - or #f.
      ;;
      ;; The text is the whole accessible buffer, read through the
      ;; gap: no copy, and the engine's own STOP argument is what keeps
      ;; a match inside LIMIT - there is no truncated copy for `$' or
      ;; `\b' to match against.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (base (buffer-beg ed))
             (text (%buffer-re-text ed))
             (ctx (%buffer-match-context text compiled base (buffer-pt ed)))
             (regs (%make-search-registers compiled))
             (found (re-search (compiled-regexp-bufp compiled) text
                               (- at base) (- limit at)
                               regs (- limit base) ctx)))
        (if (< found 0)
            #f
            (list regs
                  (+ base (vector-ref (re-registers-start regs) 0))
                  (+ base (vector-ref (re-registers-end regs) 0))
                  base))))

    (define (%re-search-backward-1 compiled at limit)
      ;; The C's backward call (`search.c:1254'):
      ;;
      ;;   re_search_2 (bufp, p1, s1, p2, s2,
      ;;                PT - BEGV, lim - PT, &search_regs, PT - BEGV)
      ;;
      ;; a negative range, with STOP at point - "Don't allow match past
      ;; current point", which is what steps the walk back on a
      ;; repeated search. The register positions are relative to BEGV.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (base (buffer-beg ed))
             (text (%buffer-re-text ed))
             (ctx (%buffer-match-context text compiled base (buffer-pt ed)))
             (regs (%make-search-registers compiled))
             (found (re-search (compiled-regexp-bufp compiled) text
                               (- at base) (- limit at)
                               regs (- at base) ctx)))
        (if (< found 0)
            #f
            (list regs
                  (+ base found)
                  (+ base (vector-ref (re-registers-end regs) 0))
                  base))))

    (define (%re-search pattern bound noerror count backward)
      ;; `search_command' (search.c) and `search_buffer' for the regexp
      ;; path: find the COUNTth match of PATTERN between point and
      ;; BOUND, NOERROR answering nil for what would signal, and leave
      ;; point at the match's far end (forward) or start (backward),
      ;; answering the point value, as the C's DEFUNs do.
      ;;
      ;; The text searched is the buffer's accessible text through the
      ;; gap; the engine's registers are relative to BEGV, and
      ;; `%engine-regs-into-search-regs' shifts them to buffer
      ;; positions.
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
             (compiled (%compile-emacs-regexp pattern (*case-fold-search*)))
             ;; `search_command`'s bound rule, in the C's order: the
             ;; wrong-side check is against the *unclipped* argument.
             (limit (%search-limit ed bound backward)))
        (let loop ((left (max 1 count)) (at from))
          (let ((found (if backward
                           (%re-search-backward-1 compiled at limit)
                           (%re-search-forward-1 compiled at limit))))
            (cond
             ((not found)
              ;; `search_command' (`search.c'): "If NOERROR is neither
              ;; nil nor t ... just move point to the limit" - the
              ;; `move' sentinel, which `beginning-of-defun-raw' passes.
              (if (not noerror)
                  (error "Search failed" pattern)
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
              ;; the registers of the match actually made, shifted from
              ;; the engine's BEGV-relative offsets to buffer positions
              (%engine-regs-into-search-regs (car found) (cadddr found))
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
                   ;; The registers are Emacs's own 1-based buffer
                   ;; positions - the C hands them to
                   ;; `Fbuffer_substring' as they stand. The `+ 1's that
                   ;; stood here were from before the 2026-10-05
                   ;; conversion to Emacs's coordinates, and they
                   ;; shifted every `\&' and `\N' one character right:
                   ;; found through `replace-regexp-in-region', whose
                   ;; `\2\1' answered `b1' for a match of `a1'.
                   (loop (+ i 2)
                         (cons (make-buffer-string
                                (current-buffer)
                                (car (list-ref regs sub))
                                (cdr (list-ref regs sub)))
                               acc)))
                 ((and (char<=? #\1 c #\9)
                       (< (- (char->integer c) 48) (length regs)))
                  (let ((pair (list-ref regs (- (char->integer c) 48))))
                    (cond
                     ((and pair (>= (car pair) 1))
                      (loop (+ i 2)
                            (cons (make-buffer-string
                                   (current-buffer)
                                   (car pair) (cdr pair))
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

    (define (match-string-no-properties num . args)
      ;; GNU Emacs's `match-string-no-properties' (subr.el:5876):
      ;; "Return text matched by last search, without properties."
      ;; STRING, when given, is the string the last `string-match' ran
      ;; on; when not, the text comes from the current buffer.  `#f'
      ;; when the NUMth pair did not match.
      (let ((beg (match-beginning num)))
        (and beg
             (let ((end (match-end num))
                   (string (if (pair? args) (car args) #f)))
               (if string
                   (substring string beg end)
                   (make-buffer-string (current-buffer) beg end #f))))))

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
    ;; `string-match' clients, and `(schemacs core regexp-opt)' already
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
