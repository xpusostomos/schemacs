(define-library (schemacs regexp-opt)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/regexp-opt.el': the
  ;; generator that turns a list of literal strings into one regexp that
  ;; matches any of them, ordered so that it always matches the longest.
  ;;
  ;; It exists here because Dired's `dired-font-lock-keywords' calls it -
  ;; the two `completion-ignored-extensions' keywords build their pattern
  ;; from a list of file-name suffixes, and Emacs writes
  ;; `(regexp-opt completion-ignored-extensions)' for that.
  ;;
  ;; It is beside `map-ynp.sld' rather than among the `editor/' libraries
  ;; because Emacs keeps both under `lisp/emacs-lisp/'; the tree does not
  ;; mirror that subdirectory, and `map-ynp.sld' set the precedent.
  ;;
  ;; Not ported, named rather than faked:
  ;;
  ;;   * **`regexp-opt-depth'**, which counts the non-shy groups in a
  ;;     regexp - it needs `subregexp-context-p' (subr.el), the scan that
  ;;     tells a group-open marker from a `\\(' inside a bracket
  ;;     expression or after a backslash. Nothing here needs it.
  ;;   * **`regexp-opt-charset''s char-table**. Emacs builds a
  ;;     `regexp-opt-charset' char-table and walks it with
  ;;     `map-char-table', which iterates in character-code order; a
  ;;     sorted list of the characters is the same walk in the same order,
  ;;     so that is what is done here. The range-merging below it is the
  ;;     C's, step for step.

  (import
    (scheme base)
    (scheme char)
    ;; `sort' orders the strings; `delete-duplicates' is not used because
    ;; Emacs's `delete-dups' keeps the *first* of equal elements and SRFI
    ;; 1's may keep any - `%delete-dups' below is Emacs's three lines.
    (only (guile) sort)
    ;; `regexp-quote' is search.c's, and `try-completion' and
    ;; `all-completions' are `minibuf.c''s - the same two `files.sld'
    ;; imports for the same purpose.
    (only (schemacs editor search) regexp-quote)
    (only (schemacs editor minibuf) all-completions try-completion)
    ;; `regexp-unmatchable' is `subr.el''s, and is one line.
    (only (schemacs editor subr) regexp-unmatchable))

  (export regexp-opt regexp-opt-group regexp-opt-charset)

  (begin

    (define (%delete-dups list)
      ;; GNU Emacs's `delete-dups': "Destructively remove `equal'
      ;; duplicates from LIST. Store the result in LIST and return it. In
      ;; the simplest case, return LIST. The order is preserved, and the
      ;; *first* of equal elements survives."
      ;;--------------------------------------------------------------
      (let loop ((rest list) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((member (car rest) acc) (loop (cdr rest) acc))
              (else (loop (cdr rest) (cons (car rest) acc))))))

    (define (%any pred list)
      ;; cl-lib's `any', which `regexp-opt-group' asks whether any *other*
      ;; member is one character long
      ;;--------------------------------------------------------------
      (cond ((null? list) #f)
            ((pred (car list)) #t)
            (else (%any pred (cdr list)))))

    (define (%string-reverse string)
      ;; Emacs's `reverse' of a string, which `regexp-opt-group' takes a
      ;; common *suffix* with ("sgnirts" in the C is the list of reversed
      ;; strings).
      ;;--------------------------------------------------------------
      (list->string (reverse (string->list string))))

    (define (%string-to-char string)
      ;; Emacs's `string-to-char'
      ;;--------------------------------------------------------------
      (string-ref string 0))

    (define (%nreverse-string string)
      ;; the C's `(nreverse xiffus)': a string, reversed in place - and
      ;; for a string the two are one operation.
      ;;--------------------------------------------------------------
      (%string-reverse string))

    (define (regexp-opt strings . args)
      ;; GNU Emacs's `regexp-opt': "Return a regexp to match a string in
      ;; the list STRINGS. Each member of STRINGS is treated as a fixed
      ;; string, not as a regexp. ... The returned regexp is ordered in
      ;; such a way that it will always match the longest string
      ;; possible."
      ;;
      ;; PAREN is a string, `words', `symbols', non-nil or nil, as
      ;; documented: see `regexp-opt-group' for what the grouping
      ;; constructs come to.
      ;;--------------------------------------------------------------
      (let* ((paren (if (pair? args) (car args) #f))
             (open (cond ((string? paren) paren) (paren "\\(") (else #f)))
             (re (if (pair? strings)
                     (regexp-opt-group
                      (%delete-dups (sort (list-copy strings) string<?))
                      (or open #t) (not open))
                     ;; "No strings: return an unmatchable regexp."
                     (string-append (or open "\\(?:")
                                    regexp-unmatchable "\\)"))))
        (cond ((eq? paren 'words) (string-append "\\<" re "\\>"))
              ((eq? paren 'symbols) (string-append "\\_<" re "\\_>"))
              (else re))))

    (define (regexp-opt-group strings . args)
      ;; GNU Emacs's `regexp-opt-group': "Return a regexp to match a string
      ;; in the sorted list STRINGS. If PAREN non-nil, output regexp
      ;; parentheses around returned regexp. If LAX non-nil, don't output
      ;; parentheses if it doesn't require them. Merges keywords to avoid
      ;; backtracking in Emacs's regexp matcher."
      ;;
      ;; "The basic idea is to find the shortest common prefix or suffix,
      ;; remove it and recurse. If there is no prefix, we divide the list
      ;; into two so that (at least) one half will have at least a
      ;; one-character common prefix.
      ;;
      ;; Also we delay the addition of grouping parenthesis as long as
      ;; possible until we're sure we need them, and try to remove
      ;; one-character sequences so we can use character sets rather than
      ;; grouping parenthesis."
      ;;--------------------------------------------------------------
      (let* ((paren (if (pair? args) (car args) #f))
             (lax (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (open-group (cond ((string? paren) paren) (paren "\\(?:") (else "")))
             (close-group (if paren "\\)" ""))
             (open-charset (if lax "" open-group))
             (close-charset (if lax "" close-group)))
        (cond
         ;; "If there are no strings, just return the empty string."
         ((= 0 (length strings)) "")
         ;; "If there is only one string, just return it."
         ((= 1 (length strings))
          (if (= 1 (string-length (car strings)))
              (string-append open-charset (regexp-quote (car strings))
                             close-charset)
              (string-append open-group (regexp-quote (car strings))
                             close-group)))
         ;; "If there is an empty string, remove it and recurse on the
         ;; rest."
         ((= 0 (string-length (car strings)))
          (string-append open-charset
                         (regexp-opt-group (cdr strings) #t #t) "?"
                         close-charset))
         ;; "If there are several one-char strings, use charsets."
         ((and (= 1 (string-length (car strings)))
               (%any (lambda (s) (= 1 (string-length s))) (cdr strings)))
          (let ((letters '()) (rest '()))
            ;; "Collect one-char strings."
            (for-each (lambda (s)
                        (if (= 1 (string-length s))
                            (set! letters (cons (%string-to-char s) letters))
                            (set! rest (cons s rest))))
                      strings)
            (if (pair? rest)
                ;; "several one-char strings: take them and recurse on the
                ;; rest (first so as to match the longest)."
                (string-append open-group
                               (regexp-opt-group (reverse rest))
                               "\\|" (regexp-opt-charset letters)
                               close-group)
                ;; "all are one-char strings: just return a character set."
                (string-append open-charset
                               (regexp-opt-charset letters)
                               close-charset))))
         (else
          ;; "We have a list of different length strings."
          (let ((prefix (try-completion "" strings)))
            (if (> (string-length prefix) 0)
                ;; "common prefix: take it and recurse on the suffixes."
                (let* ((n (string-length prefix))
                       (suffixes (map (lambda (s) (substring s n (string-length s)))
                                      strings)))
                  (string-append open-group
                                 (regexp-quote prefix)
                                 (regexp-opt-group suffixes #t #t)
                                 close-group))
                (let* ((sgnirts (map %string-reverse strings))
                       (xiffus (try-completion "" sgnirts)))
                  (if (> (string-length xiffus) 0)
                      ;; "common suffix: take it and recurse on the
                      ;; prefixes."
                      (let* ((n (- (string-length xiffus)))
                             (prefixes
                              ;; "Sorting is necessary in cases such as
                              ;; (\"ad\" \"d\")."
                              ;;
                              ;; N is the *negative* length of the
                              ;; common suffix, because the C's
                              ;; `(substring s 0 n)' is Elisp's
                              ;; substring, whose END may be counted from
                              ;; the end of the string: `(substring s 0
                              ;; -3)' is all but the last three
                              ;; characters. Guile's is an index and
                              ;; refuses a negative one, so the same cut
                              ;; is written out.
                              (sort (map (lambda (s)
                                           (substring s 0 (- (string-length s) (- n))))
                                         strings)
                                    string<?)))
                        (string-append open-group
                                       (regexp-opt-group prefixes #t #t)
                                       (regexp-quote (%nreverse-string xiffus))
                                       close-group))
                      ;; "Otherwise, divide the list into those that start
                      ;; with a particular letter and those that do not,
                      ;; and recurse on them."
                      (let* ((char (substring (car strings) 0 1))
                             (half1 (all-completions char strings))
                             (half2 (list-tail strings (length half1))))
                        (string-append open-group
                                       (regexp-opt-group half1)
                                       "\\|" (regexp-opt-group half2)
                                       close-group))))))))))

    (define (%charset-runs sorted)
      ;; The runs in the sorted character list SORTED, as a list of
      ;; `(START . END)' in order - the C's `map-char-table' walk over a
      ;; `regexp-opt-charset' char-table, which iterates in character-code
      ;; order, so a sorted list is the same walk in the same order.
      ;;--------------------------------------------------------------
      ;; The arithmetic is in *character codes*: the C works on a
      ;; char-table, whose keys are integers, where a character here is a
      ;; character - and `(+ char 1)' is not a thing.
      (let loop ((rest (map char->integer sorted)) (start #f) (end #f) (acc '()))
        (cond ((null? rest) (reverse (if start (cons (cons start end) acc) acc)))
              ((not start) (loop (cdr rest) (car rest) (car rest) acc))
              ((= (car rest) (+ end 1)) (loop (cdr rest) start (car rest) acc))
              (else (loop (cdr rest) (car rest) (car rest)
                          (cons (cons start end) acc))))))

    (define (%charset-text runs)
      ;; The regexp text the RUNS become: a range where one is worth it,
      ;; and the characters one by one otherwise - the C's `(> end (+
      ;; start 2))' test and the `while (>= end start)' walk under it.
      ;;--------------------------------------------------------------
      (let loop ((rest runs) (out ""))
        (if (null? rest)
            out
            (let ((start (car (car rest)))
                  (end (cdr (car rest))))
              (loop (cdr rest)
                    (if (> end (+ start 2))
                        (string-append out (string (integer->char start))
                                       "-" (string (integer->char end)))
                        (let more ((out out) (c start))
                          (if (> c end)
                              out
                              (more (string-append out (string (integer->char c)))
                                    (+ c 1))))))))))

    (define (regexp-opt-charset chars)
      ;; GNU Emacs's `regexp-opt-charset': "Return a regexp to match a
      ;; character in CHARS. CHARS should be a list of characters. ...
      ;; The basic idea is to find character ranges. Also we take care in
      ;; the position of character set meta characters in the character
      ;; set regexp."
      ;;--------------------------------------------------------------
      (let ((bracket "") (dash "") (caret "") (letters '()))
        ;; "Make a character map but extract character set meta
        ;; characters."
        (for-each (lambda (char)
                    (cond ((char=? char #\]) (set! bracket "]"))
                          ((char=? char #\^) (set! caret "^"))
                          ((char=? char #\-) (set! dash "-"))
                          (else (set! letters (cons char letters)))))
                  chars)
        (let ((all (string-append
                    bracket
                    (%charset-text (%charset-runs (sort letters char<?)))
                    caret dash)))
          ;; "Make sure that ] is first, ^ is not first, - is first or
          ;; last."
          (cond ((= 0 (string-length all)) regexp-unmatchable)
                ((= 1 (string-length all)) (regexp-quote all))
                ((string=? all "^-") "[-^]")
                (else (string-append "[" all "]"))))))


    ))
