(import
 (only (schemacs editor buffer) allocate-buffer bufferp buffer-pt buffer-beg buffer-z text-editor-buffer-name set!text-editor-buffer-name text-editor-file-name set!text-editor-file-name buffer-modified-p set-buffer-modified-p buffer-read-only? set!buffer-read-only text-editor-text-props set!text-editor-text-props *inhibit-read-only* *buffer-visited-file-modtime-function* buffer-modified-tick buffer-chars-modified-tick text-editor-cache-long-scans set!text-editor-cache-long-scans show-text-editor text-editor-undo-list set!text-editor-undo-list)
 (only (schemacs editor undo) record-insert record-delete text-editor-undo-boundary! text-editor-undo-disable! text-editor-undo-enable! text-editor-undo-recording? *undo-limit* undo-insertion-entry? undo-deletion-entry? undo-modified-entry? *point-before-last-command-or-undo* *buffer-before-last-command-or-undo*)
 (only (schemacs editor insdel) *after-change-functions* signal-after-change *text-property-offset-function* invalidate-buffer-caches)
 (only (schemacs editor fns) count-lines)
 (scheme base)
 (scheme char)
 (scheme time)
 
 (schemacs editor buffer)
 (schemacs editor frame)
 (schemacs editor editfns)
 (schemacs editor search)
 (schemacs editor casefiddle)
 (only (schemacs editor marker) markerp marker-position)
 ;; `primitive-undo` is `undo.c`'s and reaches this tree through the
 ;; library that holds undo.c until `undo.scm` exists.
 (only (schemacs editor simple) primitive-undo)
 (only (srfi 64) test-assert test-equal test-begin test-end test-error)
 (only (schemacs editor syntax) with-syntax-table copy-syntax-table standard-syntax-table modify-syntax-entry)
 )

;; The search.c layer's tests: the match data's conventions (one-based
;; in a buffer, zero-based in a string), the translation layer's
;; reading of an Emacs regexp, and `replace-match''s paths.

(test-begin "search")

;; ------------------------------------------------------------------
;; a buffer to work in

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
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
       (markerp (car md)))
     ;; a marker's position and the integer beside it are the same
     ;; position - which they were not: the markers came back one behind,
     ;; so this answered `(4 9)' where `(match-data t)' answered `(5 10)'.
     ;; Emacs 31.1 answers `(5 10)' both ways.
     (test-equal "match-data's pairs are the match"
       (list 5 10) (list (marker-position (car md))
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

;; `replace_range` records the change as **one** deletion of the old text
;; and **one** insertion of the new, and the insertion's record is
;; `(BEG . BEG+LENGTH)` - the range the insertion occupies, which is what
;; undoing it deletes (`record_insert`'s second argument is a *length*,
;; `undo.c:86`). Written with a position there instead, the record is
;; `(10 . 5)` and undoing it deletes nothing, so the replacement stays.
;;
;; This is the one test that would have caught that, and it is here
;; because it did not exist: the departure was invisible to every other
;; test in the suite, and to `casify-region`'s own.
(test-equal "replace-match's undo record is a deletion and an insertion"
  '(("apple" . -5) (10 . 15))
  (with-buffer
   (lambda ()
     (fill "one apple, two apples")
     (set!text-editor-undo-list (current-buffer) '())
     (search-forward "apple")
     (replace-match "FRUIT" #f #f)
     (text-editor-undo-list (current-buffer)))))

(test-equal "one undo puts the matched text back"
  '("one apple, two apples" 10)
  (with-buffer
   (lambda ()
     (fill "one apple, two apples")
     (set!text-editor-undo-list (current-buffer) '())
     (search-forward "apple")
     (replace-match "FRUIT" #f #f)
     (primitive-undo 1 (text-editor-undo-list (current-buffer)))
     (list (buffer-substring (point-min) (point-max)) (point)))))

;; the error strings are the C's

;; "`(match-beginning 0)' with no match data is nil, not an error" -
;; measured on Emacs 31.1, and the C says so too: `match_limit' answers
;; nil for `n >= search_regs.num_regs', which is every N when there are
;; no registers. This port raised "No match data, because no search
;; succeeded", and `(set-match-data nil)` (which must clear the
;; registers) did not clear them either - `narrow-to-page` walks into
;; both.
(test-equal "match-beginning with no match data answers nil"
  #f
  (parameterize ((*search-regs* #f)) (match-beginning 0)))
(test-equal "and match-end too"
  #f
  (parameterize ((*search-regs* #f)) (match-end 0)))
(test-equal "set-match-data nil clears the last search's registers"
  #f
  (begin (string-match "b" "abc")
         (set-match-data #f)
         (match-beginning 0)))
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

;; ------------------------------------------------------------------
;; The search window, and `$' at its edges.
;;
;; `re_search_2' is handed the buffer and a `stop', so `$' is judged
;; against the text the buffer really has. This tree hands Guile's
;; `regexp-exec' a copy, and a copy ending at the bound makes the engine
;; see an end of string there - every expectation below is Emacs 31.1's,
;; and the first two were answered as matches before the window grew one
;; character past the bound.
;;
;; The window is also what keeps a search cheap: `regexp-exec' is
;; O(length of the string) and not O(distance to the match), so handing
;; it the buffer - or the whole range a font-lock keyword may search,
;; which is the file - is what made opening a 257 KB Scheme file burn
;; 13.5 s in the keyword pass. It doubles only when the answer could
;; depend on its edge.

(define (search-in text from thunk)
  (with-buffer
   (lambda ()
     (let ((b (get-buffer-create "*search-boundary*")))
       (set-buffer b)
       (erase-buffer)
       (insert text)
       (goto-char from)
       (thunk)))))

;; `looking-at' answers from the whole buffer in the C - `re_match_2''s
;; `p1' - and copying it made every call O(buffer) twice over: 300 calls
;; on a 257 KB buffer were 7.7 s. It reads a window now, and this is the
;; same shape as the syntax-table cache's test: a hundred calls on a
;; 200 000-character buffer take 6 ms, and the bound is a hundred times
;; that.
(test-equal "looking-at does not copy the buffer for every call"
  (list #t #t)
  (search-in (make-string 200000 #\a) 100000
             (lambda ()
               (let ((t0 (current-jiffy)))
                 (let loop ((i 0))
                   (when (< i 100) (looking-at "aaa") (loop (+ i 1))))
                 (list (looking-at "aaa")
                       (< (* 1000 (/ (- (current-jiffy) t0) (jiffies-per-second)))
                          1000))))))

(test-equal "a `$' at the bound is not an end of line"
  (list #f 1) (search-in "abcdef" 1
                         (lambda () (list (re-search-forward "$" 4 #t) (point)))))

(test-equal "... and a match that needs one does not count"
  (list #f 1) (search-in "abc def " 1
                         (lambda () (list (re-search-forward "b$" 6 #t) (point)))))

(test-equal "a backward `$' from mid-line does not match at point"
  (list 3 3) (search-in "ab\ncd" 4
                        (lambda () (list (re-search-backward "$" 1 #t) (point)))))

(test-equal "... and one that really is a line end does"
  (list 3 3) (search-in "ab\ncd" 5
                        (lambda () (list (re-search-backward "$" 1 #t) (point)))))

;; The C's engine matches against `stop', so a pattern whose longest
;; match runs past point still matches shorter: `c*' at point 3 of "abc"
;; is the empty match at 3, not the earlier one.
(test-equal "a match longer than the point is taken shorter"
  (list 3 3) (search-in "abc" 3
                        (lambda () (list (re-search-backward "c*" 1 #t) (point)))))

(test-equal "... and the same for a repeated character"
  (list 3 3) (search-in "aaa" 4
                        (lambda () (list (re-search-backward "a+" 1 #t) (point)))))


;; ---------------------------------------------------------------------
;; `\_<' and `\_>': the *symbol* boundary (`regex-emacs.c:5508'), which
;; the ERE cannot say - the empty group plus the syntax-table check after
;; the match. `&' and `:' are `Ssymbol' in a Lisp mode, not `Sword' -
;; which is why the old word-boundary stand-in never matched them - so
;; the tests run under a table that says so. Every expectation is Emacs
;; 31.1's, measured with `emacs -Q --batch' in `emacs-lisp-mode'.
;; ---------------------------------------------------------------------
(define (lisp-syntax-table)
  ;; A Lisp mode's table for the characters these tests use: `&', `:' and
  ;; `?' are symbol constituents there (measured: all three are 95).
  (let ((table (copy-syntax-table (standard-syntax-table))))
    (modify-syntax-entry (integer->char 38) "_" table)   ; &
    (modify-syntax-entry (integer->char 58) "_" table)   ; :
    (modify-syntax-entry (integer->char 63) "_" table)   ; ?
    table))

(define (symbol-match pattern string)
  (with-syntax-table (lisp-syntax-table) (lambda () (string-match pattern string))))

(test-equal "a symbol that starts with & is a symbol start"
  2 (symbol-match "\\_<&[a-z]+\\_>" "x &optional y"))

(test-equal "a keyword's colon is a symbol start too"
  2 (symbol-match "\\_<:[a-z]+\\_>" "  :keyword  "))

(test-equal "... but not in the middle of a symbol"
  #f (symbol-match "\\_<foo\\_>" "xfoobar"))

(test-equal "... and the symbol end test"
  #f (symbol-match "a\\_>" "a?"))

(test-equal "... unless the next character is not a symbol"
  0 (symbol-match "a\\_>" "a "))

;; An assertion in an alternative that did not match has no position;
;; testing #f as one raised "Wrong type argument" (the `:doc' entry of
;; the Lisp keyword tables, `checkdoc.el').
(test-equal "an assertion in the other alternative is not tested"
  0 (symbol-match ":documentation\\_>\\|:doc\\_>" ":doc "))

;; One Emacs group may be several glibc groups: `\(?1:' in two
;; alternatives is Emacs group 1 either way (`easy-mmode.el').
(test-equal "a numbered group shared by two alternatives binds either"
  (list 0 2)
  (let ((start (symbol-match "\\(?1:ab\\)\\|\\(?1:cd\\)" "cd")))
    (list start (match-end 1))))

(test-equal "... and the other alternative too"
  (list 0 2)
  (let ((start (symbol-match "\\(?1:ab\\)\\|\\(?1:cd\\)" "ab")))
    (list start (match-end 1))))


;; **`looking-back`** (`subr.el:5907`): the match ends at point, GREEDY
;; keeps the furthest one - the C extends it under
;; `(save-restriction (narrow-to-region (point-min) start))` - and the
;; match data is left at *buffer* positions, which is what `font-lock`
;; reads. Measured on Emacs 31.1 over "aaa" with point after it: plain
;; `(t 3 4)`, greedy `(t 1 4)`, and `(looking-back nil)` is t (the C's
;; `concat` turns a nil REGEXP into nothing).
(test-equal '((#t 3 4) (#t 1 4) #t)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "aaa")
    (goto-char 4)
    (let ((plain (list (looking-back "a+" #f)
                       (match-beginning 0) (match-end 0)))
          (greedy (list (looking-back "a+" #f #t)
                        (match-beginning 0) (match-end 0)))
          (empty (looking-back #f)))
      (list plain greedy empty))))

;; **A search stops at the restriction**, and an explicit BOUND follows
;; `search_command`'s rules (`search.c:1006`): nil is `ZV` forward, an
;; explicit one is clipped to `[BEGV, ZV]`, and one on the wrong side of
;; point is "Invalid search bound (wrong side of point)".
(test-equal '(#f #f not-an-error)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "hello world")
    (narrow-to-region 1 5)
    (goto-char 1)
    (list
     ;; "world" is in the buffer but outside the accessible portion
     (search-forward "world" #f #t)
     ;; "o" is at 5, which is ZV - not accessible
     (search-forward "o" #f #t)
     ;; a bound beyond ZV is clipped rather than refused
     (if (search-forward "h" 100 #t) 'not-an-error 'not-an-error))))

(test-equal 'wrong-side
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "hello world")
    (goto-char 5)
    (guard (e (#t 'wrong-side))
      (search-forward "x" 1 #t)
      'no-error)))

(test-end)
