(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (prefix (schemacs editor minibuffer) mi:))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for the completion *styles* in `(schemacs editor
;; minibuffer)', which is GNU Emacs's `minibuffer.el'.
;;
;; A style is a way of completing, and the point of having a list of them
;; is that the first that finds anything wins - so the tests are as much
;; about the *walk* as about either style.
;;
;; POINT is where in the string the completion is happening; it is the end
;; of the string throughout, which is where a minibuffer prompt has it.

(test-begin "schemacs_editor_minibuffer_styles")

;; The styles that exist, in the alist Emacs dispatches through.
(test-equal '(basic substring)
  (map car (mi:completion-styles-alist)))

;; Prefix completion: what the text could become, and point at the end of
;; it - a *pair*, because a style may put point somewhere else.
(test-equal '("foo" . 3)
  (mi:completion-try-completion "fo" '("foo" "food") #f 2))

;; `#t` when what was typed is already the only completion, which is how a
;; caller knows there is nothing to insert.
(test-equal #t
  (mi:completion-try-completion "foo" '("foo") #f 3))

(test-equal #f
  (mi:completion-try-completion "zz" '("foo") #f 2))

;; The list of candidates, with the *base size* in the last cdr - the
;; length of the text the completion starts from, which is how a caller
;; learns how much of what was typed the completion replaces.
(test-equal '(("foo" "food") . 0)
  (let ((answer (mi:completion-all-completions "fo" '("foo" "food") #f 2)))
    (cons (list-head answer 2) (cdr (last-pair answer)))))

;; `substring' completes the string *wherever* it appears, which is the
;; whole difference from `basic': "oo" is not a prefix of anything here,
;; and `basic' alone finds nothing.
(test-equal #f
  (parameterize ((mi:*completion-styles* '(basic)))
    (mi:completion-all-completions "oo" '("foo" "bar") #f 2)))

(test-equal '(("foo") . 0)
  (let ((answer (mi:completion-all-completions "oo" '("foo" "bar") #f 2)))
    (cons (list-head answer 1) (cdr (last-pair answer)))))

;; ...and completing gives the *match* rather than a longer version of the
;; input, because a substring match is not a prefix of what was typed.
(test-equal '("foo" . 3)
  (mi:completion-try-completion "oo" '("foo" "bar") #f 2))

;; The walk: `basic' first, and `substring' only reached because `basic'
;; found nothing. Taking `basic' away leaves `substring' to answer.
(test-equal '("foo" . 3)
  (parameterize ((mi:*completion-styles* '(basic substring)))
    (mi:completion-try-completion "oo" '("foo") #f 2)))

(test-equal #f
  (parameterize ((mi:*completion-styles* '(basic)))
    (mi:completion-try-completion "oo" '("foo") #f 2)))

;; A style that is not in the alist is an error rather than a silent skip,
;; as in Emacs.
(test-equal #t
  (guard (ex (else #t))
    (parameterize ((mi:*completion-styles* '(no-such-style)))
      (mi:completion-try-completion "a" '("abc") #f 1))
    #f))

;; `completion-boundaries' is a table's answer to "where does the text you
;; are completing begin", and a plain list has no opinion.
(test-equal '(0 . 0)
  (mi:completion-boundaries "abc" '("abc") #f ""))

(test-end "schemacs_editor_minibuffer_styles")
