(import
  (scheme base)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor chartab)
        make-char-table char-table-p char-table-subtype
        char-table-parent set-char-table-parent
        char-table-extra-slot set-char-table-extra-slot
        char-table-range set-char-table-range)
  (only (schemacs editor intervals) put))

;; Regression tests for `(schemacs editor chartab)', which mirrors GNU
;; Emacs's `src/chartab.c'. **Every expectation is Emacs 31.1's own
;; answer**, measured with `emacs -Q --batch' on the same expressions;
;; `nil' prints as `#f' here, which is this tree's nil.

(test-begin "schemacs_editor_chartab")

(define t1 (make-char-table 'foo))

(test-equal "an unset character answers nil"
  #f (char-table-range t1 97))

(test-equal "the nil RANGE answers the default, which starts nil"
  #f (char-table-range t1 #f))

(test-equal "a character set with the fixnum form reads back"
  (begin (set-char-table-range t1 97 'x) (char-table-range t1 97))
  'x)

(test-equal "... and its neighbour is still nil"
  #f (char-table-range t1 98))

(test-equal "a default is what an unset character answers"
  (begin (set-char-table-range t1 #f 'd) (char-table-range t1 98))
  'd)

(test-equal "... and the nil RANGE reads it too"
  'd (char-table-range t1 #f))

(test-equal "... and an explicit character still wins over it"
  'x (char-table-range t1 97))

;; `(set-char-table-range T '(?a . ?z) 'r)' - the cons RANGE, which is
;; what `modify-syntax-entry' passes for a range.
(set-char-table-range t1 (cons 97 122) 'r)

(test-equal "a cons range covers its first character"
  'r (char-table-range t1 97))
(test-equal "... its middle"
  'r (char-table-range t1 109))
(test-equal "... its last"
  'r (char-table-range t1 122))
(test-equal "... and stops there"
  'd (char-table-range t1 65))
(test-equal "reading a cons RANGE answers the value for FROM"
  'r (char-table-range t1 (cons 97 122)))

(test-equal "the t RANGE sets every character"
  (begin (set-char-table-range t1 #t 'all) (char-table-range t1 97))
  'all)
(test-equal "... including ones above the ASCII block"
  'all (char-table-range t1 #x20ac))

(test-equal "the subtype is the purpose it was made with"
  'foo (char-table-subtype t1))

;; ------------------------------------------------------------------
;; parents

(define par (make-char-table 'foo))
(define kid (make-char-table 'foo))
(set-char-table-range par 97 'p)
(set-char-table-parent kid par)

(test-equal "a nil entry is inherited from the parent"
  'p (char-table-range kid 97))
(test-equal "... and the parent's own nil still answers nil"
  #f (char-table-range kid 98))
(test-assert "the parent is the table that was passed"
  (eq? (char-table-parent kid) par))
(test-equal "the parent is not changed by being inherited from"
  'p (char-table-range par 97))

(test-equal "a table cannot be made its own ancestor"
  "Attempt to make a chartable be its own parent"
  (guard (e (#t (error-object-message e)))
    (set-char-table-parent par kid)))

;; ------------------------------------------------------------------
;; extra slots - `char-table-extra-slots' is a symbol property of the
;; purpose (`make-char-table's docstring), which `put' sets.

(put 'with-extras 'char-table-extra-slots 2)
(define t2 (make-char-table 'with-extras))

(test-equal "an extra slot starts as the table's init"
  #f (char-table-extra-slot t2 0))
(test-equal "an extra slot can be set and read"
  (begin (set-char-table-extra-slot t2 1 'e) (char-table-extra-slot t2 1))
  'e)

;; ------------------------------------------------------------------

(test-assert "char-table-p knows a char-table"
  (char-table-p (make-char-table 'foo)))
(test-assert "... and is false for anything else"
  (not (char-table-p 5)))

(test-end "schemacs_editor_chartab")
