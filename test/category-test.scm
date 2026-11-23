;; Tests for `(schemacs category)', a port of GNU Emacs's
;; `src/category.c'. Every expectation is Emacs 31.1's own answer for the
;; same call, measured with `emacs -Q --batch' first.
;;
;; The category table is a buffer-local value here, as in Emacs, so each
;; group works in a fresh buffer.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer)
 (only (schemacs chartab) make-char-table)
 (only (schemacs data) bool-vector-p bool-vector-ref)
 (schemacs category))

(define (fresh-buffer)
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    ed))

(define (message-of thunk)
  ;; The error's template and irritants, the two pieces the tree's
  ;; reporter formats with. Emacs's message is the formatted string;
  ;; this is where the same two pieces are asserted.
  (catch #t
    (lambda () (thunk) 'no-error)
    (lambda (key . args)
      (if (and (pair? args) (error-object? (car args)))
          (let ((e (car args)))
            (list (error-object-message e) (error-object-irritants e)))
          (cons key args)))))

(test-begin "schemacs_editor_category")

;; `make-category-set' (`category.c:72'): a bool-vector with t at the
;; indexes of the mnemonics.
(let ((set (make-category-set "al")))
  (test-equal "a category set names its members" "al"
              (category-set-mnemonics set))
  (test-assert "and has t at those indexes only"
               (and (bool-vector-p set)
                    (bool-vector-ref set (char->integer #\a))
                    (bool-vector-ref set (char->integer #\l))
                    (not (bool-vector-ref set (char->integer #\b))))))

;; A fresh table's sets are empty, and the first unused category is 32.
(let* ((ed (fresh-buffer))
       (tbl (make-category-table)))
  (set-category-table tbl)
  (test-equal "a fresh table has an empty set for every character" ""
              (category-set-mnemonics (char-category-set #\A)))
  (test-equal "and the first unused category is space" 32
              (get-unused-category tbl))
  (test-assert "make-category-table makes a category table"
               (category-table-p tbl))
  (test-assert "a plain char-table is not one"
               (not (category-table-p (make-char-table 'foo #f)))))

;; `define-category' (`category.c:105') and `category-docstring'.
(let* ((ed (fresh-buffer))
       (tbl (make-category-table)))
  (set-category-table tbl)
  (define-category 97 "ASCII" tbl)
  (test-equal "a category keeps its docstring" "ASCII"
              (category-docstring 97 tbl))
  (test-equal "defining a category leaves space unused" 32
              (get-unused-category tbl))
  (test-equal "a category cannot be defined twice"
              '("Category `~a' is already defined" (#\a))
              (message-of (lambda () (define-category 97 "again" tbl)))))

;; `modify-category-entry' (`category.c:314'): add and remove, and the
;; C's "Undefined category" for a category that was never defined.
(let* ((ed (fresh-buffer))
       (tbl (make-category-table)))
  (set-category-table tbl)
  (define-category 97 "ASCII" tbl)
  (modify-category-entry #\A 97 tbl)
  (test-equal "a character gains the category it is given" "a"
              (category-set-mnemonics (char-category-set #\A)))
  (modify-category-entry #\A 97 tbl #t)
  (test-equal "and loses it when RESET is non-nil" ""
              (category-set-mnemonics (char-category-set #\A)))
  (test-equal "an undefined category is an error"
              '("Undefined category: ~a" (#\z))
              (message-of (lambda () (modify-category-entry #\B 122 tbl))))
  ;; A cons is an inclusive range (`category.c:337').
  (define-category 98 "ASCII" tbl)
  (modify-category-entry (cons #\A #\C) 98 tbl)
  (test-equal "a range adds the category to every character in it"
              '("" "b" "b" "b" "" "")
              (map (lambda (c)
                     (category-set-mnemonics (char-category-set c)))
                   (list #\@ #\A #\B #\C #\D #\E))))

;; The category set is the table's, and the table is the buffer's.
(let* ((ed1 (fresh-buffer))
       (ed2 (allocate-buffer))
       (tbl (make-category-table)))
  (set-buffer ed1)
  (set-category-table tbl)
  (define-category 97 "ASCII" tbl)
  (modify-category-entry #\A 97 tbl)
  (set-buffer ed2)
  ;; Emacs 31.1's standard table gives A the set ".Lalr"; what matters
  ;; here is that it is not the category `a` this test put on A in ed1.
  (test-equal "another buffer has the standard table, not this one" ".Lalr"
              (category-set-mnemonics (char-category-set #\A)))
  (set-buffer ed1)
  (test-equal "and the first buffer kept its own" "a"
              (category-set-mnemonics (char-category-set #\A))))

;; `copy-category-table' (`category.c:217'): no contents are shared.
(let* ((ed (fresh-buffer))
       (tbl (make-category-table))
       (copy #f))
  (set-category-table tbl)
  (define-category 97 "ASCII" tbl)
  (modify-category-entry #\A 97 tbl)
  (set! copy (copy-category-table tbl))
  (set-category-table copy)
  (modify-category-entry #\C 97 copy)
  (test-equal "a copied table keeps the docstrings" "ASCII"
              (category-docstring 97 copy))
  (test-equal "and its own category sets" "a"
              (category-set-mnemonics (char-category-set #\C)))
  (set-category-table tbl)
  (test-equal "while the original is unchanged" ""
              (category-set-mnemonics (char-category-set #\C)))
  (test-equal "and still has the set it had" "a"
              (category-set-mnemonics (char-category-set #\A))))

;; `word_boundary_p' (`category.c:376'). With the script table this tree
;; has so far - one script for every character - and no categories named
;; by `word-separating-categories', two word characters are one word.
(test-equal "no word boundary inside a script without categories" #f
            (word-boundary-p (char->integer #\a) (char->integer #\b)))

(test-end "schemacs_editor_category")
