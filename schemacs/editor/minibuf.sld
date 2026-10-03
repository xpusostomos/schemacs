(define-library (schemacs editor minibuf)
  ;; This library mirrors GNU Emacs's `minibuf.c': the three functions
  ;; that answer a question about a *completion table* - what the text
  ;; could become, what it could become to, and whether it is already
  ;; valid - and the dispatch on what a table may be.
  ;;
  ;; The split from `(schemacs editor minibuffer)' is Emacs's own:
  ;; `minibuf.c' is these three functions and nothing else, and
  ;; `minibuffer.el' is everything built on them (the styles,
  ;; `completing-read', the commands). They are separate libraries here
  ;; for the same reason.
  ;;
  ;; What a COLLECTION may be, and which the three functions dispatch on:
  ;;
  ;;  * **a list**, or an *alist* - an element's car is the candidate,
  ;;    and an element that is not a pair is itself one;
  ;;  * **a hash table** - the keys that are strings or symbols;
  ;;  * **a function** - called with three arguments, `(STRING PREDICATE
  ;;    ACTION)', because the caller tells the table *which question* it
  ;;    is asking: ACTION is #t for `test-completion', a procedure for
  ;;    `all-completions', and #f for `try-completion'.
  ;;
  ;; Not ported: **obarrays**, which are one of Emacs's four forms and
  ;; are a Lisp object - a vector of symbols with a Lisp name table
  ;; behind it - that this project has no analogue of. They belong to the
  ;; elisp layer, where a Lisp symbol table will live. Emacs's PREDICATE
  ;; may also be the symbol `commandp'; nothing here is a command in that
  ;; sense, so a predicate is a procedure.
  ;;
  ;; The C's `completion_regexp_list' - `completion-regexp-list', by which
  ;; every candidate must also match some regexps - is not ported either:
  ;; it needs a regexp engine, and nothing here sets it.
  ;;
  ;; See COMPLETION-PLAN.txt for the plan this library is the first step
  ;; of.

  (import
    (scheme base)
    (scheme char)
    ;; Guile's hash tables, which is what Emacs's hash-table form is.
    (only (guile) hash-table? hash-for-each))

  (export
   *history-add-new-input*
   *history-delete-duplicates*
   *history-length*
   all-completions
   compare-strings
   test-completion
   try-completion
   *completion-ignore-case*
   )

  (begin

    (define *completion-ignore-case*
      ;; GNU Emacs's `completion-ignore-case': whether a candidate
      ;; matches the text whatever the case. Emacs makes it
      ;; buffer-local in `read-file-name' on a case-insensitive file
      ;; system; it is a parameter here, this project's spelling of
      ;; buffer-local until the value is the buffer's (see
      ;; `(schemacs editor buffer)''s `buffer-local-value').
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *history-delete-duplicates*
      ;; GNU Emacs's `history-delete-duplicates' (`minibuf.c'): whether
      ;; adding an element to a history list removes earlier copies of
      ;; it. Off, as in Emacs.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *history-length*
      ;; GNU Emacs's `history-length' (`minibuf.c'): "maximum length of
      ;; history lists before truncation takes place", for the lists that
      ;; do not give one of their own. 100, as in Emacs.
      ;;--------------------------------------------------------------
      (make-parameter 100))

    (define *history-add-new-input*
      ;; GNU Emacs's `history-add-new-input' (`minibuf.c'): "Non-nil means
      ;; to add new elements in history. If set to nil, minibuffer reading
      ;; functions don't add new elements to the history list, so it is
      ;; possible to do this afterwards by calling `add-to-history'
      ;; explicitly."
      ;;
      ;; The reader adds the answer to its history when this is true, which
      ;; is what `read_minibuf' does with it (minibuf.c:984). The commands
      ;; that read a *series* of related answers - `query-replace' reads
      ;; FROM and TO into one history - turn it off and say where each
      ;; answer goes, which is how they keep a reader's automatic entry
      ;; from landing in a list the prompt was given to walk.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define (compare-strings string1 start1 end1 string2 start2 end2 . args)
      ;; GNU Emacs's `compare-strings', which is `fns.c''s: #t when the
      ;; two ranges are the same, and otherwise an integer whose
      ;; magnitude is *one more* than the index of the first difference
      ;; and whose sign says which string is less - which is why callers
      ;; write `(abs tem) - 1' to get the index.
      ;;
      ;; It is here rather than in a library of its own because these
      ;; three functions are its only caller so far; when `fns.sld'
      ;; exists it goes there, as `get' and `put' will.
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

    (define (collection-type collection)
      ;; Which of the table forms COLLECTION is: GNU Emacs's `type' in
      ;; `Ftry_completion'. A procedure is the function form, a pair or
      ;; the empty list is the list form, and a hash table is itself -
      ;; obarrays being the one form not represented here.
      ;;--------------------------------------------------------------
      (cond ((hash-table? collection) 'hash-table)
            ((procedure? collection) 'function)
            (else 'list)))

    (define (elements-of collection)
      ;; COLLECTION as a list of candidates, in the order the three
      ;; functions walk them: a list's elements with an alist element
      ;; reduced to its car, or a hash table's keys. Emacs walks the
      ;; three forms with one loop and picks the element out per type;
      ;; this reduces each form to the same list first.
      ;;--------------------------------------------------------------
      (cond
       ((not collection) '())
       ((hash-table? collection)
        (let ((acc '()))
          (hash-for-each (lambda (k v) (set! acc (cons k acc))) collection)
          (reverse acc)))
       ((procedure? collection) '())     ; the function form answers itself
       (else
        (let loop ((rest collection) (acc '()))
          (if (not (pair? rest))
              (reverse acc)
              (loop (cdr rest)
                    (cons (if (pair? (car rest)) (car (car rest)) (car rest))
                          acc)))))))

    (define (element-name elt)
      ;; ELT as the string to test a completion against, or #f when it is
      ;; not something that can be one: Emacs's
      ;; `(eltsring = CONSP (elt) ? XCAR (elt) : elt)' followed by its
      ;; "not a string or a symbol, skip" test.
      ;;--------------------------------------------------------------
      (cond ((string? elt) elt)
            ((symbol? elt) (symbol->string elt))
            (else #f)))

    (define (candidate-matches-string? string eltstring)
      ;; The C's "Is this element a possible completion?" test, which is
      ;; the gate everything else sits behind: the candidate must be at
      ;; least as long as what was typed, and must *start* with it. A
      ;; candidate that fails it is skipped outright - and leaving the
      ;; test out is not a small omission, because a skipped candidate is
      ;; one that cannot shrink the answer. Without it every candidate
      ;; that does *not* match still shortens the common prefix, and a
      ;; completion with no match at all answers the empty string instead
      ;; of nil.
      ;;--------------------------------------------------------------
      (and (<= (string-length string) (string-length eltstring))
           (eq? (compare-strings eltstring 0 (string-length string)
                                 string 0 (string-length string)
                                 (*completion-ignore-case*))
                #t)))

    (define (predicate-accepts? predicate elt)
      ;; Whether PREDICATE accepts ELT. Nothing here is a command, so
      ;; Emacs's `commandp' case does not arise.
      ;;--------------------------------------------------------------
      (or (not predicate) (and (predicate elt) #t)))

    (define (try-completion string collection . args)
      ;; GNU Emacs's `try-completion': what STRING can be completed to in
      ;; COLLECTION.
      ;;
      ;; #t when STRING is itself a candidate, so there is nothing to
      ;; add; #f when nothing matches; otherwise the longest prefix every
      ;; candidate that STRING starts agrees on - which is STRING itself
      ;; when they agree on nothing more.
      ;;
      ;; The running BESTMATCH-and-shrink loop is the C's, and so is the
      ;; early exit: once the match has shrunk to the length of what was
      ;; typed and there is more than one candidate, no later candidate
      ;; can lengthen it. The exception is the case-insensitive search,
      ;; which has to keep going to find the best-*cased* match.
      ;;--------------------------------------------------------------
      (let ((predicate (if (pair? args) (car args) #f)))
        (if (eq? (collection-type collection) 'function)
            (collection string predicate #f)
            (let loop ((rest (elements-of collection))
                       (bestmatch #f)
                       (bestmatchsize 0)
                       (matchcount 0))
              (cond
               ((null? rest)
                (cond
                 ((not bestmatch) #f)
                 ((and (= matchcount 1) (string=? bestmatch string)) #t)
                 (else (substring bestmatch 0 bestmatchsize))))
               (else
                (let ((eltstring (element-name (car rest))))
                  (if (or (not eltstring)
                          (not (candidate-matches-string? string eltstring))
                          (not (predicate-accepts? predicate (car rest))))
                      (loop (cdr rest) bestmatch bestmatchsize matchcount)
                      (cond
                       ((not bestmatch)
                        (loop (cdr rest) eltstring (string-length eltstring) 1))
                       (else
                        (let* ((compare (min bestmatchsize
                                             (string-length eltstring)))
                               (tem (compare-strings bestmatch 0 compare
                                                     eltstring 0 compare
                                                     (*completion-ignore-case*)))
                               (matchsize (if (eq? tem #t)
                                              compare
                                              (- (abs tem) 1)))
                               (old-bestmatch bestmatch)
                               (bestmatch (if (*completion-ignore-case*)
                                              (if (case-preferred? string
                                                                   old-bestmatch
                                                                   eltstring
                                                                   matchsize)
                                                  eltstring
                                                  bestmatch)
                                              bestmatch)))
                          (loop (cdr rest)
                                bestmatch
                                matchsize
                                (+ matchcount
                                   (if (or (not (= bestmatchsize
                                                   (string-length eltstring)))
                                           (not (= bestmatchsize matchsize))
                                           (and (*completion-ignore-case*)
                                                (not (eq? (compare-strings
                                                           old-bestmatch 0 compare
                                                           eltstring 0 compare
                                                           #f)
                                                          #t))))
                                       1
                                       0))))))))))))))))

    (define (case-preferred? string bestmatch eltstring matchsize)
      ;; The C's case-insensitive tie-break: prefer a candidate that
      ;; matches what was typed *exactly*, so that completing `foo'
      ;; against `Foo' and `foo' answers `foo' rather than `Foo'. It is
      ;; the `completion_ignore_case' branch of the C's loop.
      ;;--------------------------------------------------------------
      (let ((exact-elt (compare-strings eltstring 0 (string-length string)
                                        string 0 #f #f))
            (exact-best (compare-strings bestmatch 0 (string-length string)
                                         string 0 #f #f)))
        (or
         ;; A candidate the text matches *exactly* beats a longer one that
         ;; only shares the prefix - in Emacs's words, "if this is an exact
         ;; match except for case, use it as the best match rather than one
         ;; that is not an exact match".
         (and (= matchsize (string-length eltstring))
              (< matchsize (string-length bestmatch)))
         ;; Otherwise, when the two agree about whether they are exact
         ;; matches at all, prefer the one that matches the text *as
         ;; typed* - so completing `foo' against `Foo' and `foo' answers
         ;; `foo'.
         (and (= (if (= matchsize (string-length eltstring)) 1 0)
                 (if (= matchsize (string-length bestmatch)) 1 0))
              (eq? exact-elt #t)
              (not (eq? exact-best #t))))))

    (define (all-completions string collection . args)
      ;; GNU Emacs's `all-completions': every candidate in COLLECTION that
      ;; STRING is a prefix of, in the collection's order.
      ;;
      ;; The comparison runs over the *whole* candidate, so the answer is
      ;; #t-or-not rather than an index: a candidate matches when its
      ;; first `(string-length string)' characters are STRING's.
      ;;--------------------------------------------------------------
      (let ((predicate (if (pair? args) (car args) #f)))
        (if (eq? (collection-type collection) 'function)
            (collection string predicate #t)
            (let loop ((rest (elements-of collection)) (acc '()))
              (cond
               ((null? rest) (reverse acc))
               (else
                (let ((eltstring (element-name (car rest))))
                  (if (and eltstring
                           (candidate-matches-string? string eltstring)
                           (predicate-accepts? predicate (car rest)))
                      (loop (cdr rest) (cons eltstring acc))
                      (loop (cdr rest) acc)))))))))

    (define (test-completion string collection . args)
      ;; GNU Emacs's `test-completion': whether STRING is *already* one of
      ;; the candidates - the question RET asks, and not the same one
      ;; `try-completion' answers. `try-completion' says what the text
      ;; could become; this says whether it will do as it stands.
      ;;--------------------------------------------------------------
      (let ((predicate (if (pair? args) (car args) #f)))
        (cond
         ((eq? (collection-type collection) 'function)
          (collection string predicate 'lambda))
         (else
          (let loop ((rest (elements-of collection)))
            (cond
             ((null? rest) #f)
             (else
              (let ((eltstring (element-name (car rest))))
                (if (and eltstring
                         (predicate-accepts? predicate (car rest))
                         ;; The *whole* candidate against the whole
                         ;; string: one that merely starts with it is a
                         ;; completion of it, not the same as it.
                         (eq? (compare-strings string 0 #f eltstring 0 #f
                                               (*completion-ignore-case*))
                              #t))
                    #t
                    (loop (cdr rest)))))))))

    ))
