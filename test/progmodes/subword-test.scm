(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs buffer)
       allocate-buffer set-buffer current-buffer
       buffer-local-value local-variable-p)
 (only (schemacs editfns) insert goto-char point buffer-string)
 (only (schemacs syntax) forward-word forward-word-strictly)
 (only (schemacs simple) backward-word kill-word mark)
 (only (schemacs progmodes subword)
       subword-mode superword-mode global-subword-mode global-superword-mode
       subword-mode-variable superword-mode-variable
       subword-forward subword-backward subword-capitalize subword-downcase
       subword-upcase subword-kill subword-mark
       subword-find-word-boundary-function-table subword-empty-char-table
       c-subword-mode capitalized-words-mode)
 (only (schemacs symbol-props) get)
 (only (schemacs subr) *minor-mode-alist*))

;; Regression tests for `lisp/progmodes/subword.el' as this tree ports
;; it - `subword.scm'. **Every expectation is Emacs 31.1's own**,
;; measured with `emacs -Q --batch' on the same text first.
;;
;; The mechanism under test is a buffer-local
;; `find-word-boundary-function-table' that `syntax.scm`'s word scan
;; consults, so the motion tests are the regression tests for that
;; consultation - `forward-word' from 1 on "fooBarBaz" stops at 4 with
;; the mode on and at 10 with it off.

(setvbuf (current-output-port) 'none)

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    b))

(test-begin "schemacs_editor_subword")

;;--------------------------------------------------------------
;; The modes.
;;--------------------------------------------------------------
(fresh "")
(subword-mode 1)
(test-equal "enabling subword-mode sets its variable"
            '(#t #f) (list (subword-mode-variable) (superword-mode-variable)))
;; "A bare call enables rather than toggles" - `define-minor-mode`'s
;; rule, measured on Emacs: `subword-mode` twice leaves it on.
(subword-mode 1)
(test-equal "and twice is still on" #t (subword-mode-variable))
(subword-mode -1)
(test-equal "a negative argument turns it off" #f (subword-mode-variable))

(fresh "")
(subword-mode 1)
(superword-mode 1)
(test-equal "superword-mode turns subword-mode off, as the bodies say"
            '(#f #t)
            (list (subword-mode-variable) (superword-mode-variable)))

(test-equal "the two lighters are Emacs's"
            '((subword-mode " ,") (superword-mode " ²"))
            (list (assq 'subword-mode (*minor-mode-alist*))
                  (assq 'superword-mode (*minor-mode-alist*))))

(test-equal "the globalized modes exist"
            '(#t #t)
            (list (and global-subword-mode #t)
                  (and global-superword-mode #t)))

;;--------------------------------------------------------------
;; Word motion through the boundary table.
;;--------------------------------------------------------------
(fresh "fooBarBaz")
(subword-mode 1)
(goto-char 1)
(test-equal "forward-word stops at each subword boundary"
            '(4 7 10)
            (list (begin (forward-word 1) (point))
                  (begin (forward-word 1) (point))
                  (begin (forward-word 1) (point))))
(test-equal "backward-word stops at each subword boundary too"
            '(7 4)
            (list (begin (backward-word 1) (point))
                  (begin (backward-word 1) (point))))

(fresh "fooBarBaz")
(goto-char 1)
(forward-word 1)
(test-equal "without the mode a word is the whole symbol"
            '(10 #f) (list (point) (subword-mode-variable)))

(fresh "this_is_a_symbol x")
(superword-mode 1)
(goto-char 1)
(test-equal "superword-mode treats the whole symbol as one word"
            '(17 19)
            (list (begin (forward-word 1) (point))
                  (begin (forward-word 1) (point))))

(fresh "one two three")
(superword-mode 1)
(goto-char 1)
(test-equal "and an ordinary word is still a word"
            '(4 8)
            (list (begin (forward-word 1) (point))
                  (begin (forward-word 1) (point))))

;; `forward-word-strictly' `let'-binds the table, which Emacs's
;; `specbind' puts *above* the buffer-local value the mode set - so the
;; strict motion must see the whole word even with the mode on.
(fresh "fooBarBaz")
(subword-mode 1)
(goto-char 1)
(test-equal "forward-word-strictly ignores the mode's splitter"
            '(#t 10) (list (forward-word-strictly 1) (point)))

;;--------------------------------------------------------------
;; `subword-setup-buffer`'s buffer-local, both ways.
;;--------------------------------------------------------------
(fresh "")
(subword-mode 1)
(test-equal "the on state installs the subword table buffer-locally"
            '(#t #t)
            (list (local-variable-p 'find-word-boundary-function-table
                                    (current-buffer))
                  (eq? (buffer-local-value
                        (current-buffer) 'find-word-boundary-function-table)
                       subword-find-word-boundary-function-table)))
(subword-mode -1)
(test-equal "and off leaves the empty table behind, as Emacs does"
            '(#t #t)
            (list (local-variable-p 'find-word-boundary-function-table
                                    (current-buffer))
                  (eq? (buffer-local-value
                        (current-buffer) 'find-word-boundary-function-table)
                       subword-empty-char-table)))

;;--------------------------------------------------------------
;; The compatibility commands (`subword.el:133'-`:254').
;;--------------------------------------------------------------
(fresh "fooBarBaz")
(subword-mode 1)
(goto-char 1)
(test-equal "subword-forward counts subwords"
            '(4 10 10)
            (list (subword-forward 1)
                  (subword-forward 2)
                  (point)))
(test-equal "subword-backward is its negative"
            '(7 7)
            (list (subword-backward 1) (point)))

(fresh "foo bar")
(subword-mode 1)
(goto-char 1)
(test-equal "subword-capitalize capitalizes the first subword"
            (list #f "Foo bar" 4)
            (list (subword-capitalize 1) (buffer-string) (point)))

(fresh "Foo Bar")
(subword-mode 1)
(goto-char 1)
(test-equal "subword-downcase downcases it"
            (list #f "foo Bar" 4)
            (list (subword-downcase 1) (buffer-string) (point)))

(fresh "foo bar")
(subword-mode 1)
(goto-char 1)
(test-equal "subword-upcase upcases it"
            (list #f "FOO bar" 4)
            (list (subword-upcase 1) (buffer-string) (point)))

(fresh "!!!")
(subword-mode 1)
(goto-char 1)
(test-equal "subword-capitalize with no letter catches search-failed"
            (list #f "!!!")
            (list (subword-capitalize 1) (buffer-string)))

(fresh "fooBarBaz qux")
(subword-mode 1)
(goto-char 1)
(subword-kill 1)
(test-equal "subword-kill takes just the first subword"
            '("BarBaz qux" 1)
            (list (buffer-string) (point)))

(fresh "fooBarBaz qux")
(subword-mode 1)
(goto-char 1)
(kill-word 1)
(test-equal "and kill-word goes through the same table"
            '("BarBaz qux" 1)
            (list (buffer-string) (point)))

(fresh "fooBarBaz")
(subword-mode 1)
(goto-char 1)
(subword-mark 1)
(test-equal "subword-mark marks the subword's end and leaves point"
            '(1 4)
            (list (point) (mark #t)))

;;--------------------------------------------------------------
;; The aliases (`subword.el:89', `:119') and their obsolescence.
;;--------------------------------------------------------------
(test-equal "c-subword-mode and capitalized-words-mode are subword-mode"
            '(#t #t)
            (list (eq? c-subword-mode subword-mode)
                  (eq? capitalized-words-mode subword-mode)))
(test-equal "with the byte-obsolete-info Emacs's make-obsolete writes"
            '((subword-mode #f "23.2") (subword-mode #f "25.1"))
            (list (get 'c-subword-mode 'byte-obsolete-info)
                  (get 'capitalized-words-mode 'byte-obsolete-info)))

(test-end "schemacs_editor_subword")
