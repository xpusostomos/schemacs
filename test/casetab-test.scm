;; Tests for `(schemacs casetab)', a port of GNU Emacs's
;; `src/casetab.c'. Every expectation is Emacs 31.1's own answer,
;; measured with `emacs -Q --batch' first.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer)
 (only (schemacs chartab)
       make-char-table char-table-extra-slot char-table-ref char-table-set)
 (schemacs casetab))

(test-begin "schemacs_editor_casetab")

;; The standard table, and the three slots `set_case_table` fills.
(let ((d (standard-case-table)))
  (test-assert "the standard table is a case table" (case-table-p d))
  (test-assert "a plain char-table is not one"
               (not (case-table-p (make-char-table 'foo #f))))
  (test-equal "the standard table's downcase mapping"
              '(97 97 48)
              (list (char-table-ref d 65) (char-table-ref d 97)
                    (char-table-ref d 48)))
  (test-equal "its UPCASE slot"
              '(65 65)
              (list (char-table-ref (char-table-extra-slot d 0) 65)
                    (char-table-ref (char-table-extra-slot d 0) 97)))
  (test-equal "its CANON slot"
              '(97 97)
              (list (char-table-ref (char-table-extra-slot d 1) 65)
                    (char-table-ref (char-table-extra-slot d 1) 97)))
  (test-equal "and its EQV slot"
              '(97 65)
              (list (char-table-ref (char-table-extra-slot d 2) 65)
                    (char-table-ref (char-table-extra-slot d 2) 97)))
  (test-assert "a fresh buffer's case table is the standard one"
               (eq? (current-case-table) d)))

;; `set-case-table` (`casetab.c:82') derives UP, CANON and EQV from a
;; table whose extra slots are nil. Emacs 31.1 on this table:
;;   down 65 -> 97, down 97 -> 97
;;   up 65 -> 97, up 97 -> 65
;;   canon 65 -> 97, canon 97 -> 97
;;   eqv 65 -> 97, eqv 97 -> 65
(let ((ed (allocate-buffer)))
  (set-buffer ed)
  (let ((tbl (make-char-table 'case-table #f)))
    (char-table-set tbl 65 97)
    (char-table-set tbl 97 97)
    (set-case-table tbl)
    (test-equal "set-case-table leaves the downcase mapping"
                '(97 97)
                (list (char-table-ref tbl 65) (char-table-ref tbl 97)))
    (test-equal "and derives UP"
                '(97 65)
                (list (char-table-ref (char-table-extra-slot tbl 0) 65)
                      (char-table-ref (char-table-extra-slot tbl 0) 97)))
    (test-equal "CANON"
                '(97 97)
                (list (char-table-ref (char-table-extra-slot tbl 1) 65)
                      (char-table-ref (char-table-extra-slot tbl 1) 97)))
    (test-equal "and EQV"
                '(97 65)
                (list (char-table-ref (char-table-extra-slot tbl 2) 65)
                      (char-table-ref (char-table-extra-slot tbl 2) 97)))
    (test-assert "the buffer's case table is the new one"
                 (eq? (current-case-table) tbl))
    (test-assert "and CANON's extra slot 2 is EQV"
                 (eq? (char-table-extra-slot (case-canon-table) 2)
                      (case-eqv-table)))))

(test-end "schemacs_editor_casetab")
