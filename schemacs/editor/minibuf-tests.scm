(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf make-hash-table)
 (prefix (schemacs editor minibuf) mb:))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor minibuf)', which mirrors GNU
;; Emacs's `minibuf.c': the three questions about a completion table, and
;; the four forms a table may take.
;;
;; The three are worth keeping distinct, because two of them sound alike
;; and are not: `try-completion' says what the text *could become*, and
;; `test-completion' says whether it is *already valid*. Emacs's RET asks
;; the second one, and getting them confused is how a minibuffer accepts
;; a name that does not exist.

(test-begin "schemacs_editor_minibuf")

;; What the text could become: the longest prefix the candidates agree on,
;; and the input itself when they agree on nothing more.
;;
;; The first of these is worth reading twice, because #t is *not* the
;; answer: there are two candidates, and Emacs returns #t only for a
;; single exact match. With "foo" and "foobar" both matching, what is left
;; is the prefix they agree on, which is what was typed.
(test-equal '("foo" "fooba" "foo")
  (list (mb:try-completion "foo" '("foo" "foobar"))
        (mb:try-completion "foo" '("foobar" "foobaz"))
        (mb:try-completion "fo" '("foo" "food"))))

;; ...and #t is the answer when there really is one candidate and it is
;; exactly what was typed.
(test-equal #t
  (mb:try-completion "foo" '("foo" "bar")))

(test-equal #t
  (mb:try-completion "foo" '("foo")))

;; Nothing matching is #f rather than the empty string, which is what a
;; caller checks before deciding to complain.
(test-equal #f
  (mb:try-completion "zzz" '("foo" "bar")))

;; An *alist*'s candidates are its keys, and an element that is not a pair
;; is its own candidate - which is how a table mixes the two.
(test-equal "foo"
  (mb:try-completion "fo" '(("foo" . 1) ("bar" . 2))))

(test-equal "foo"
  (mb:try-completion "fo" '("foo" ("bar" . 2))))

;; A hash table's candidates are its keys that are strings or symbols.
(test-equal '(#t)
  (let ((table (make-hash-table)))
    (hash-set! table "foo" 1)
    (hash-set! table "bar" 2)
    (list (mb:test-completion "foo" table))))

;; The *function* form: the table is called with three arguments, the
;; third being which question is being asked - #t for the list of all
;; completions, #f for what the text could become, and `lambda' for
;; whether it is valid.
(test-equal '(list try test)
  (let ((table (lambda (string predicate action)
                 (if (eq? action #t) 'list
                     (if action 'test 'try)))))
    (list (mb:all-completions "" table)
          (mb:try-completion "" table)
          (mb:test-completion "" table))))

;; The predicate is a filter over the candidates - the third argument the
;; three functions take.
(test-equal '(("bar") "bar")
  (list (mb:all-completions "" '("foo" "bar") (lambda (e) (string=? e "bar")))
        (mb:try-completion "" '("foo" "bar") (lambda (e) (string=? e "bar")))))

;; `test-completion' is not `try-completion': "fo" can be completed to
;; something but is not itself a candidate, and only the first of those is
;; a reason to accept it.
(test-equal '(#t #f "foo")
  (list (mb:test-completion "foo" '("foo" "foobar"))
        (mb:test-completion "fo" '("foo" "foobar"))
        (mb:try-completion "fo" '("foo" "foobar"))))

;; Case is significant by default, and `completion-ignore-case' makes it
;; not.
(test-equal '(#f #t #f "foo")
  (list (mb:test-completion "FOO" '("foo"))
        (parameterize ((mb:*completion-ignore-case* #t))
          (mb:test-completion "FOO" '("foo")))
        (mb:try-completion "FOO" '("foo"))
        ;; ignoring case, the text is completed to the candidate - so the
        ;; answer carries the candidate's case, not the typed one. It is
        ;; still not #t, because #t means "no change needed" and the case
        ;; does change.
        (parameterize ((mb:*completion-ignore-case* #t))
          (mb:try-completion "FOO" '("foo")))))

;; ...and when case is ignored, the candidate that matches *as typed* wins
;; over one that differs only in case - so completing `FOO' against `Foo'
;; and `FOO' answers `FOO'.
(test-equal "FOO"
  (parameterize ((mb:*completion-ignore-case* #t))
    (mb:try-completion "FOO" '("Foo" "FOO" "foobar"))))

;; `compare-strings' is what all of that is built on, and its answer for
;; unequal strings is one more than the index of the first difference,
;; signed - which is why callers write `(- (abs tem) 1)'.
(test-equal '(#t -3 3 #t -4)
  (list (mb:compare-strings "abc" 0 3 "abc" 0 3 #f)
        ;; "abc" and "abd" first differ at index 2, and the answer is that
        ;; index *plus one*, negative because the first string is less
        (mb:compare-strings "abc" 0 3 "abd" 0 3 #f)
        (mb:compare-strings "abd" 0 3 "abc" 0 3 #f)
        (mb:compare-strings "ABc" 0 3 "abc" 0 3 #t)
        ;; ranges that are not the whole strings
        (mb:compare-strings "hello" 0 5 "help" 0 4 #f)))

(test-end "schemacs_editor_minibuf")
