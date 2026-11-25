;; Tests for `(schemacs abbrev)`, a port of GNU Emacs's `abbrev.el'.
;; Every expectation is what `emacs -Q --batch' answers for the same
;; calls, measured first. The table is a record here where Emacs's is an
;; obarray; `abbrev-symbol' answers that record.

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer)
 (only (schemacs editfns) insert point buffer-substring-no-properties)
 (only (schemacs abbrev)
       make-abbrev-table define-abbrev-table define-abbrev abbrev-table-p
       clear-abbrev-table copy-abbrev-table abbrev-expansion abbrev-symbol
       abbrev-table-get abbrev-table-put abbrev-table-named
       abbrev-mode-variable set!abbrev-mode-variable!
       local-abbrev-table set!local-abbrev-table
       expand-abbrev abbrev--default-expand
       global-abbrev-table))

(define (fresh-buffer)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    b))

(test-begin "schemacs_editor_abbrev")

(test-assert "a made table is an abbrev table"
             (abbrev-table-p (make-abbrev-table)))
(test-assert "and a plain list is not"
             (not (abbrev-table-p '(a b))))
(test-equal "table properties are a plist"
            'v
            (let ((tbl (make-abbrev-table)))
              (abbrev-table-put tbl ':regexp 'v)
              (abbrev-table-get tbl ':regexp)))

(let ((tbl (make-abbrev-table)))
  (define-abbrev tbl "tt" "testing")
  (test-equal "an abbrev expands" "testing" (abbrev-expansion "tt" tbl))
  (test-equal "lookup folds case" "testing" (abbrev-expansion "TT" tbl))
  (test-equal "and mixed case" "testing" (abbrev-expansion "Tt" tbl))
  (test-assert "abbrev-symbol answers the record"
               (not (not (abbrev-symbol "tt" tbl))))
  (test-equal "an unknown name is nil" #f (abbrev-expansion "zz" tbl)))

;; A named table is reachable through the registry, which stands in for
;; `(symbol-value 'NAME)'.
(define-abbrev-table 'abbrev-test-table
  (list (list "aa" "bb") (list "cc" "dd")))
(test-assert "define-abbrev-table registers the table"
             (abbrev-table-p (abbrev-table-named 'abbrev-test-table)))
(test-equal "its definitions are in it" "bb"
            (abbrev-expansion "aa" (abbrev-table-named 'abbrev-test-table)))
(test-equal "and the second one too" "dd"
            (abbrev-expansion "cc" (abbrev-table-named 'abbrev-test-table)))
(test-equal "defining again reuses the table" "ee"
            (begin
              (define-abbrev-table 'abbrev-test-table
                (list (list "aa" "ee")))
              (abbrev-expansion "aa" (abbrev-table-named 'abbrev-test-table))))

;; Expansion in a buffer, with the mode's table installed.
(let ((tbl (make-abbrev-table)))
  (define-abbrev tbl "tt" "testing")
  (let ((b (fresh-buffer)))
    (set!local-abbrev-table tbl)
    (insert "tt")
    (expand-abbrev)
    (test-equal "expansion replaces the abbreviation" "testing"
                (buffer-substring-no-properties 1 (point)))
    (test-equal "point is after the expansion" 8 (point))))

(let ((tbl (make-abbrev-table)))
  (define-abbrev tbl "tt" "testing")
  (let ((b (fresh-buffer)))
    (set!local-abbrev-table tbl)
    (insert "Tt")
    (expand-abbrev)
    (test-equal "capitalised abbreviation capitalises the expansion" "Testing"
                (buffer-substring-no-properties 1 (point)))))
(let ((tbl (make-abbrev-table)))
  (define-abbrev tbl "tt" "testing")
  (let ((b (fresh-buffer)))
    (set!local-abbrev-table tbl)
    (insert "TT")
    (expand-abbrev)
    (test-equal "all-caps abbreviation upcases the expansion" "TESTING"
                (buffer-substring-no-properties 1 (point)))))

;; **No abbrev before point answers nil, not the unspecified value.**
;; This is the reported bug: `c-mode` sets `abbrev-mode` t (as Emacs's
;; `(setq abbrev-mode t)` does), so `internal_self_insert`'s
;; `expand-abbrev` runs on every word followed by a space; the port's
;; `abbrev--before-point` used a Scheme `when` in value position, whose
;; unspecified value is *true*, so `abbrev--default-expand` did
;; `(list-ref #<unspecified> 0)` - "Wrong type argument in position 1:
;; #<unspecified>" on typing `void ' in a C buffer. Measured on Emacs
;; 31.1: both calls below answer nil, and point is left at 5.
(let ((tbl (make-abbrev-table)))
  (define-abbrev tbl "tt" "testing")
  (let ((b (fresh-buffer)))
    (set!local-abbrev-table tbl)
    (set!abbrev-mode-variable! #t)
    (insert "void")
    (test-equal "a word that is not an abbrev answers nil" #f
                (expand-abbrev))))

;; The `:regexp` table's own `when` is an operand of the `and` that
;; builds `res`; a Scheme `when` answering the unspecified value there
;; makes the `and` go on to read `start`/`end` from the previous
;; attempt. Emacs answers nil here too.
(let ((tbl (make-abbrev-table)))
  (abbrev-table-put tbl ':regexp "\\<x\\(\\w+\\)")
  (define-abbrev tbl "tt" "testing")
  (let ((b (fresh-buffer)))
    (set!local-abbrev-table tbl)
    (set!abbrev-mode-variable! #t)
    (insert "void")
    (test-equal "a non-matching :regexp table answers nil too" #f
                (expand-abbrev))
    (test-equal "and point is left where it was" 5 (point))))

;; `abbrev-mode` is the buffer-local variable, as in C's abbrev.c.
(let ((b (fresh-buffer)))
  (test-equal "abbrev-mode is off by default" #f (abbrev-mode-variable))
  (test-equal "and the setter turns it on" #t
              (begin (set!abbrev-mode-variable! #t)
                     (abbrev-mode-variable)))
  (test-equal "and off again" #f
              (begin (set!abbrev-mode-variable! #f)
                     (abbrev-mode-variable))))

;; `clear-abbrev-table` and `copy-abbrev-table`.
(let ((tbl (make-abbrev-table)))
  (define-abbrev tbl "aa" "bb")
  (let ((copy (copy-abbrev-table tbl)))
    (test-equal "a copied table has the abbrev" "bb"
                (abbrev-expansion "aa" copy))
    (define-abbrev tbl "aa" "cc")
    (test-equal "and is a copy, not a view" "bb"
                (abbrev-expansion "aa" copy)))
  (clear-abbrev-table tbl)
  (test-equal "a cleared table has nothing" #f
              (abbrev-expansion "aa" tbl)))

(test-end "schemacs_editor_abbrev")
