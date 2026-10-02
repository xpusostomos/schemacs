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

(test-end)
