(define-library (schemacs external s)
  ;; A SUBSET of Magnus Henoch's `s.el', the string library
  ;; (https://github.com/magnars/s.el; the Emacs package is `s',
  ;; version 20260522 here).  It lives under `schemacs/external'
  ;; because it is not part of GNU Emacs.
  ;;
  ;; The subset is exactly what `groovy-emacs-modes' calls - seven
  ;; functions plus the three `-p' aliases - copied from the upstream
  ;; source function for function, docstrings included.  The rest of
  ;; s.el (the word-splitting, hashing, formatting and font-lock
  ;; helpers) is not ported: nothing in this tree calls it, and it is
  ;; not dead *upstream* code, so it is a named gap rather than a
  ;; deletion.  Add a function here the same way when something needs
  ;; it.
  ;;
  ;; **Departures**: `(null s)' is `(not s)' - the tree's nil is `#f'
  ;; and never the empty list in these functions' arguments - and the
  ;; `-p' names are `(define NAME TARGET)' rather than `defalias'; the
  ;; value is the same procedure object either way, which is what a
  ;; `defalias' gives.
  (import
    (scheme base)
    (only (schemacs search) replace-match save-match-data string-match
          string-match-p)
    (only (schemacs subr) split-string string-prefix-p)
    (only (schemacs fns) compare-strings))

  (export s-trim s-trim-left s-trim-right s-split
          s-starts-with? s-ends-with? s-matches?
          s-blank? s-blank-str?
          s-starts-with-p s-ends-with-p s-matches-p s-blank-str-p)

  (begin

    (define (s-trim-left s)
      ;; "Remove whitespace at the beginning of S."
      (save-match-data
        (if (string-match "\\`[ \t\n\r]+" s)
            (replace-match "" #t #t s)
            s)))

    (define (s-trim-right s)
      ;; "Remove whitespace at the end of S."
      (save-match-data
        (if (string-match "[ \t\n\r]+\\'" s)
            (replace-match "" #t #t s)
            s)))

    (define (s-trim s)
      ;; "Remove whitespace at the beginning and end of S."
      (s-trim-left (s-trim-right s)))

    (define (s-split separator s . rest)
      ;; "Split S into substrings bounded by matches for regexp
      ;; SEPARATOR.  If OMIT-NULLS is non-nil, zero-length substrings
      ;; are omitted.  This is a simple wrapper around the built-in
      ;; `split-string'."
      (let ((omit-nulls (and (pair? rest) (car rest))))
        (save-match-data
          (split-string s separator omit-nulls))))

    (define (s-starts-with? prefix s . rest)
      ;; "Does S start with PREFIX?  If IGNORE-CASE is non-nil, the
      ;; comparison is done without paying attention to case
      ;; differences.  Alias: `s-prefix?'.  This is a simple wrapper
      ;; around the built-in `string-prefix-p'."
      (let ((ignore-case (and (pair? rest) (car rest))))
        (string-prefix-p prefix s ignore-case)))

    (define (s-ends-with? suffix s . rest)
      ;; "Does S end with SUFFIX?  If IGNORE-CASE is non-nil, the
      ;; comparison is done without paying attention to case
      ;; differences.  Alias: `s-suffix?'"
      (let ((ignore-case (and (pair? rest) (car rest))))
        (let ((start-pos (- (string-length s) (string-length suffix))))
          (and (>= start-pos 0)
               (eq? #t (compare-strings suffix #f #f
                                        s start-pos #f ignore-case))))))

    (define (s--truthy? val)
      ;; Emacs's `(not (null val))'.  **`null?' is the wrong test here**:
      ;; this tree's nil is `#f' and `null?' asks about the empty list,
      ;; so `(not (null? #f))' is `#t' - every failed match would be
      ;; reported as a success (`s-matches-p' did exactly that).
      (if val #t #f))

    (define (s-matches? regexp s . rest)
      ;; "Does REGEXP match S?  If START is non-nil the search starts
      ;; at that index.  This is a simple wrapper around the built-in
      ;; `string-match-p'."
      (let ((start (and (pair? rest) (car rest))))
        (s--truthy? (string-match-p regexp s start))))

    (define (s-blank? s)
      ;; "Is S nil or the empty string?"
      (or (not s) (string=? "" s)))

    (define (s-blank-str? s)
      ;; "Is S nil or the empty string or string only contains
      ;; whitespace?"
      (or (s-blank? s) (s-blank? (s-trim s))))

    ;; The aliases (`s.el:773'-`:786').
    (define s-starts-with-p s-starts-with?)
    (define s-ends-with-p s-ends-with?)
    (define s-matches-p s-matches?)
    (define s-blank-str-p s-blank-str?)

    ))
