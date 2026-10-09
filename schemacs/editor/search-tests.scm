(import
 (scheme base)
 (scheme char)
 (schemacs editor engine)
 (schemacs editor buffer)
 (schemacs editor frame)
 (schemacs editor editfns)
 (schemacs editor search)
 (schemacs editor casefiddle)
 (only (srfi 64) test-assert test-equal test-begin test-end test-error)
 )

;; The search.c layer's tests: the match data's conventions (one-based
;; in a buffer, zero-based in a string), the translation layer's
;; reading of an Emacs regexp, and `replace-match''s paths.

(test-begin "search")

;; ------------------------------------------------------------------
;; a buffer to work in

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (new-text-editor) 24 80))
                 (*current-buffer* #f)
                 (*case-fold-search* #f))
    (thunk)))

(define (fill text)
  (insert text)
  (goto-char (point-min)))

;; ------------------------------------------------------------------
;; the translation layer

(test-equal "translation: group"
  2 (string-match "\\(ab\\)" "xxab"))
(test-equal "translation: alternation is leftmost"
  0 (string-match "x\\|ab" "xxab"))
(test-equal "translation: interval"
  0 (string-match "ab\\{1,2\\}" "abbb"))
(test-equal "translation: interval exact"
  #f (string-match "ab\\{3\\}" "abb"))
(test-equal "translation: literal specials are escaped"
  #f (string-match "(ab)" "xxab"))  ; Emacs's ( is literal; "xxab" has none
(test-equal "translation: literal parens match themselves"
  2 (string-match "(ab)" "xx(ab)"))
(test-equal "translation: word boundary"
  2 (string-match "\\<foo\\>" "a foo b"))
(test-equal "translation: back reference"
  0 (string-match "\\(a\\)\\1" "aa"))
;; A bracket expression is copied through the translation verbatim.
;; It used to come out *reversed*: the scanner conses its characters,
;; so its list is backwards, and it was reversed before being appended
;; to an accumulator that is also backwards - the one reverse at the
;; end then turned `[0-9]' into `]9-0[' and the compiler rejected it.
(test-equal "translation: bracket expression"
  0 (string-match "foo[0-9]" "foo1 foo2 foo3"))
(test-equal "translation: bracket expression alone"
  1 (string-match "[0-9]" "a1b"))
(test-equal "translation: bracket expression is not a literal"
  #f (string-match "[0-9]" "abc"))
(test-equal "translation: bracket range"
  0 (string-match "[a-z]+" "abc"))
(test-equal "translation: negated bracket expression"
  0 (string-match "[^0-9]" "a1"))
(test-equal "translation: ] first in a set is a member"
  0 (string-match "[]a]" "]a"))
(test-equal "translation: unclosed bracket is rejected"
  #t (guard (e (#t #t)) (string-match "[0-9" "a1") #f))
(test-equal "translation: case-fold parameter"
  0 (parameterize ((*case-fold-search* #t))
      (string-match "FOO" "foo")))
(test-equal "translation: case-sensitive default"
  #f (parameterize ((*case-fold-search* #f))
      (string-match "FOO" "foo")))

(test-equal "regexp-quote escapes the regexp chars"
  "\\[a\\*b\\." (regexp-quote "[a*b."))
(test-equal "regexp-quote'd string matches itself"
  11 (string-match (regexp-quote "two") "one apple, two apples, three"))

;; ------------------------------------------------------------------
;; the match data of string-match: zero-based string positions

;; "xx one apple": x=0 x=1 ' '=2 o=3 n=4 e=5 ' '=6 a=7 ... e=11
(test-equal "string-match returns 0-based start"
  3 (string-match "\\(\\w+\\) apple" "xx one apple"))
(test-equal "string-match's groups are 0-based"
  3 (match-beginning 1))
(test-equal "string-match's end"
  12 (match-end 0))

;; ------------------------------------------------------------------
;; the match data of a buffer search: one-based

(with-buffer
 (lambda ()
   (fill "one apple, two apples, three")
   (test-equal "search-forward answers point"
     10 (search-forward "apple"))
   (test-equal "search-forward's match-beginning is one-based"
     5 (match-beginning 0))
   (test-equal "search-forward's match-end is one-based"
     10 (match-end 0))
   ;; search-backward answers and leaves the START
   ;; "one apple, two apples, three": "apples" at 1-based 16..21
   (goto-char (point-max))
   (test-equal "search-backward answers the start"
     16 (search-backward "apples"))
   (test-equal "search-backward left point at its start"
     16 (point))
   (test-equal "search-backward's match data"
     (list 16 22) (list (match-beginning 0) (match-end 0)))))

;; ------------------------------------------------------------------
;; match-data / set-match-data round trip

(with-buffer
 (lambda ()
   (fill "one apple, two apples, three")
   (search-forward "apple")
   (let ((md (match-data)))
     ;; buffer search: markers by default
     (test-assert "match-data's entries are markers"
       (marker-type? (car md)))
     ;; a marker's position is the engine's index, one behind the
     ;; one-based position
     (test-equal "match-data's pairs are the match"
       (list 4 9) (list (marker-position (car md))
                        (marker-position (cadr md))))
     (set-match-data md)
     (test-equal "set-match-data restores the positions"
       (list 5 10) (list (match-beginning 0) (match-end 0))))))

(with-buffer
 (lambda ()
   (fill "one apple")
   (search-forward "apple")
   (let* ((md (match-data #t))
          (buf (current-buffer)))
     (test-equal "match-data's integers are one-based"
       (list 5 10) (list (car md) (cadr md)))
     ;; the buffer is appended, as the C does
     (test-equal "match-data's integers append the buffer"
       buf (list-ref md 2)))))

;; ------------------------------------------------------------------
;; replace-match: the string path

(test-equal "replace-match string: literal"
  "FRUIT, two apples"
  (begin
    (string-match "one apple" "one apple, two apples")
    (replace-match "FRUIT" #t #t "one apple, two apples")))
(test-equal "replace-match string: case transfer nochange"
  "FRUIT, two apples"
  (begin
    (string-match "one apple" "one apple, two apples")
    ;; the match is lower case, the replacement stands
    (replace-match "FRUIT" #f #t "one apple, two apples")))
(test-equal "replace-match string: all-caps transfer"
  "FRUIT, two apples"
  (begin
    (string-match "ONE APPLE" "ONE APPLE, two apples")
    ;; the match is all caps and has a multiletter word: the
    ;; replacement follows it up
    (replace-match "fruit" #f #t "ONE APPLE, two apples")))
(test-equal "replace-match string: cap-initials transfer"
  "Apple, apples"
  (begin
    (string-match "Fruit Two" "Fruit Two, apples")
    ;; the match's words all start upper: the replacement's
    ;; initials follow
    (replace-match "apple" #f #t "Fruit Two, apples")))
(test-equal "replace-match string: \\& substitution"
  "one one, apples"
  (begin
    (string-match "one" "one, apples")
    (replace-match "one \\&" #t #f "one, apples")))
(test-equal "replace-match string: \\1 substitution"
  "apple, apples, apples"
  (begin
    (string-match "\\(\\w+\\)s" "apples, apples")
    (replace-match "\\1, \\&" #t #f "apples, apples")))

;; ------------------------------------------------------------------
;; replace-match: the buffer path

(with-buffer
 (lambda ()
   (fill "one apple, two apples")
   (search-forward "apple")
   (test-equal "replace-match buffer answers #f"
     #f (replace-match "FRUIT" #f #f))
   (test-equal "replace-match buffer replaced the text"
     "one FRUIT, two apples" (buffer-substring (point-min) (point-max)))
   (test-equal "replace-match leaves point at the replacement's end"
     10 (point))))

;; the error strings are the C's

(test-error "match-beginning with no match data"
  #t
  (parameterize ((*search-regs* #f)) (match-beginning 0)))
(test-error "replace-match with no match data"
  #t
  (parameterize ((*search-regs* #f)) (replace-match "x" #t #t)))

;; ------------------------------------------------------------------
;; bracket expressions, where the two dialects' text differs

;; `[[:name:]]' is a named character class in both dialects, and its own
;; `]' must not close the set it stands in. It once did, which turned
;; `[[:alnum:]_]' into the named class followed by a literal `_]' - and
;; the environment-variable regexp's `[[:alnum:]_]+' then stopped
;; matching, which is how it was found.
(test-equal '(0 7 0 3)
  (list (string-match "[[:alnum:]_]+" "abc_def")
        (match-end 0)
        (string-match "[[:alpha:]]+" "abc")
        (match-end 0)))
;; and the whole match is the underscore-including name
(test-equal "abc_def"
  (begin (string-match "[[:alnum:]_]+" "abc_def") (match-string 0 "abc_def")))
(test-equal '(#f 0)
  ;; a name, not `[:...:]'/`[...]', still matches letters
  (list (string-match "[[:alpha:]]" "123")
        (string-match "[[:digit:]]" "123")))

;; glibc reads `[.' inside a bracket as the start of a collating element
;; and refuses the pattern; Emacs reads a literal `[' and the `.'. What
;; `wildcard-to-regexp' produces for `[.*+\^$?]' is exactly that shape,
;; so this is where it was found.
(test-equal '(0 0 #f)
  ;; a class of `[' `.` `*' `+' `\' `^' `$' `?'
  (list (string-match "[[.*+\\^$?]" "[")
        (string-match "[[.*+\\^$?]" ".")
        (string-match "[[.*+\\^$?]" "x")))

;; `[[]' - a class holding only `[' - is the same repair
(test-equal '(0 1)
  (list (string-match "[[]" "[")
        (match-end 0)))

;; ------------------------------------------------------------------
;; the anchor, and what `^' means
;;
;; Every expectation here is `emacs -Q --batch' on this machine. They
;; are here because the suite passed without them: `looking-at' searched
;; *forward* from point, so a pattern that occurred anywhere later on
;; the line answered t, and `^' was judged against the start of a copy
;; rather than against the character before the position. Dired's own
;; indent reads `(looking-at-p "  ")' and had never once fired.

;; "right at the start of a match" - a match further along is not one
(test-equal '(#f #t #t)
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*anchor*")))
       (set-buffer b)
       (erase-buffer)
       (fill "total 7\nabc\n  xyz\n")
       (goto-char 1)
       (let ((a (looking-at "  "))          ; two spaces are on line 3
             (b* (looking-at "total")))
         (goto-char 9)                      ; the beginning of "abc"
         (list a b* (looking-at "^abc")))))))

;; `^' mid-line is not a line beginning, and is one just after a newline
(test-equal '(#f #t #f)
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*bol*")))
       (set-buffer b)
       (erase-buffer)
       (fill "total 7\nabc\n  xyz\n")
       (goto-char 10)                       ; 'b' of "abc", mid-line
       (let ((mid (looking-at "^bc")))
         (goto-char 9)
         (let ((bol (looking-at "^abc")))
           (goto-char 12)                   ; the newline ending "abc"
           (list mid bol (looking-at "^  xyz"))))))))

;; a `^' that cannot match at a real line beginning makes the search
;; miss the line it is standing on
(test-equal '(12 18)
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*bol*")))
       (set-buffer b)
       (erase-buffer)
       (fill "total 7\nabc\n  xyz\n")
       (goto-char 9)
       (let ((a (re-search-forward "^abc" #f #t)))
         (goto-char 9)
         (list a (re-search-forward "^  xyz" #f #t)))))))

;; the same question asked of a string, with the start itself a line
;; beginning - 2 is the beginning of "b", 1 is the newline before it
(test-equal '(2 2 2)
  (list (string-match "^b" "a\nb" 2)
        (string-match "^b" "a\nb" 1)
        (string-match "^b" "a\nb" 0)))

;; and 1 is not a line beginning in "ab"
(test-equal #f (string-match "^b" "ab" 1))

;; ------------------------------------------------------------------
;; `re-search-backward'
;;
;; This answered nil for *every* pattern: the walk began at the bound
;; rather than at point, and the bound is 0 when searching backwards, so
;; the first test failed and the walk stopped before it began. Nothing
;; in the tree noticed because both callers swallow the nil -
;; `dired-move-to-end-of-filename' reads it as "no file on this line",
;; and query-replace's backward loop as "no match".

(test-equal '(9 9 9)
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*back*")))
       (set-buffer b)
       (erase-buffer)
       (fill "one two\nthree four\nfive\n")
       (goto-char 10)
       (let ((a (re-search-backward "^." #f #t)))
         (goto-char 10)
         (let ((b* (re-search-backward "^" #f #t)))
           (goto-char 9)
           (list a b* (re-search-backward "^" #f #t))))))))

;; the match may not extend past point - the C's `stop' - so a backward
;; search from just after a word finds the word before it
(test-equal '(5 1)
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*back*")))
       (set-buffer b)
       (erase-buffer)
       (fill "one two\nthree four\nfive\n")
       (goto-char 6)
       (let ((a (re-search-backward "t" #f #t)))
         (goto-char 14)
         (list a (re-search-backward "^one" #f #t)))))))

;; a repeated backward search steps back one match at a time rather than
;; answering the same match three times
(test-equal 1
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*back*")))
       (set-buffer b)
       (erase-buffer)
       (fill "aaa\n")
       (goto-char 4)
       (re-search-backward "a" #f #t 3)))))

;; and no match answers nil rather than signalling
(test-equal #f
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*back*")))
       (set-buffer b)
       (erase-buffer)
       (fill "five\n")
       (goto-char 5)
       (re-search-backward "z" #f #t)))))

;; ------------------------------------------------------------------
;; case folding off, and the trap that made every one of these fail
;;
;; `%compile-emacs-regexp' passed `(if icase? regexp/icase 0)' among
;; `make-regexp''s flags, and **a flag list containing a 0 makes Guile
;; compile a POSIX *basic* regular expression** - so with
;; `case-fold-search' nil the ERE this translator produces was read
;; literally: `a\|b' matched only "a|b", and `a+' only "a+". Every
;; expectation here is Emacs 31.1's, from
;; `(let ((case-fold-search nil)) (string-match PATTERN STRING))`.

(test-equal "case-off: alternation is still an alternation"
  0 (with-buffer (lambda () (string-match "a\\|b" "b"))))

(test-equal "case-off: a plus is still a repetition"
  0 (with-buffer (lambda () (string-match "a+" "aaa"))))

(test-equal "case-off: groups are still groups"
  0 (with-buffer (lambda () (string-match "\\(ab\\)+" "abab"))))

(test-equal "case-off: intervals are still intervals"
  0 (with-buffer (lambda () (string-match "ab\\{2\\}" "abb"))))

;; ...and case is still significant: `A' does not match "a".
(test-equal "case-off: case matters"
  #f (with-buffer (lambda () (string-match "A" "abc"))))

(test-equal "case-on: case does not matter"
  0 (parameterize ((*case-fold-search* #t)) (string-match "A" "abc")))

(test-end)
