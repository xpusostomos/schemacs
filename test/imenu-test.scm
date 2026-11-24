;; Tests for `(schemacs imenu)`, a port of GNU Emacs's `imenu.el'.
;; Every expectation is what `emacs -Q --batch' answers for the same
;; call, with `imenu-use-markers' bound to nil so the positions compare
;; as numbers.

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer)
 (only (schemacs editfns) insert point)
 (only (schemacs marker) marker-position)
 (only (schemacs imenu)
       *imenu-use-markers* imenu-generic-expression
       set!imenu-generic-expression imenu--generic-function
       imenu--split imenu--in-alist imenu--subalist-p imenu--make-index-alist
       imenu--cleanup imenu--index-alist set!imenu--index-alist
       imenu--rescan-item imenu-default-goto-function imenu))

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    b))

(test-begin "schemacs_editor_imenu")

(parameterize ((*imenu-use-markers* #f))
  (let ((b (fresh "int foo;\nint bar;\n")))
    (test-equal "the generic function builds the alist"
                '(("foo" . 1) ("bar" . 10))
                (imenu--generic-function
                 (list (list #f "^\\s-*\\(int\\) \\([a-z]+\\);" 2))))
    (test-equal "a menu title nests its items"
                '(("Funcs" ("foo" . 1) ("bar" . 10)))
                (imenu--generic-function
                 (list (list "Funcs" "^\\s-*\\(int\\) \\([a-z]+\\);" 2))))
    (test-equal "the search is case-insensitive by default"
                '(("foo" . 1) ("bar" . 10))
                (imenu--generic-function
                 (list (list #f "^\\s-*\\(INT\\) \\([a-z]+\\);" 2))))))

(test-equal "imenu--split cuts into N-sized sublists"
            '((1 2 3) (4 5 6) (7 8))
            (imenu--split (list 1 2 3 4 5 6 7 8) 3))

(test-assert "a subalist is a list whose cadr is a list"
             (imenu--subalist-p '("Funcs" ("foo" . 1))))
(test-assert "a cons item is not"
             (not (imenu--subalist-p '("foo" . 1))))

(test-equal "imenu--in-alist finds a nested item"
            '("bar" . 10)
            (imenu--in-alist "bar"
                             (list (list "Funcs" (cons "foo" 1)
                                         (cons "bar" 10)))))
(test-equal "and answers nil for one that is not there" #f
            (imenu--in-alist "zzz" (list (list "Funcs" (cons "foo" 1)))))

;; The command jumps through a (NAME POSITION FUNCTION) item.
(let ((b (fresh "abcdefghij")))
  (imenu (list "foo" 5 imenu-default-goto-function))
  (test-equal "imenu jumps to the position" 5 (point)))

;; `imenu--make-index-alist` runs the mode's index function and adds the
;; rescan item.
(parameterize ((*imenu-use-markers* #f))
  (let ((b (fresh "int foo;\nint bar;\n")))
    (set!imenu-generic-expression
     (list (list #f "^\\s-*\\(int\\) \\([a-z]+\\);" 2)))
    (let ((index (imenu--make-index-alist)))
      (test-equal "the rescan item leads the index"
                  imenu--rescan-item (car index))
      (test-equal "and the definitions follow"
                  '(("foo" . 1) ("bar" . 10)) (cdr index)))))

;; `imenu--cleanup` detaches the markers in the index.
(let ((b (fresh "int foo;\n")))
  (set!imenu-generic-expression
   (list (list #f "^\\s-*\\(int\\) \\([a-z]+\\);" 2)))
  (let* ((index (imenu--make-index-alist))
         (item (cadr index))
         (marker (cdr item)))
    (test-assert "the index uses a marker by default"
                 (*imenu-use-markers*))
    (imenu--cleanup)
    (test-assert "and cleanup detaches it"
                 (not (marker-position marker)))))

(test-end "schemacs_editor_imenu")
