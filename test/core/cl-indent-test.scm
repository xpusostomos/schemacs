;; Tests for `(schemacs core cl-indent)': the Common Lisp indentation
;; engine (`common-lisp-indent-function', its specform walk and its method
;; table) and the `derived-mode-p' it asks.
;;
;; Every indentation expected here is Emacs 31.1's own: the fixture is
;; indented by `emacs -Q --batch' with `(lisp-mode)' and
;; `(indent-region (point-min) (point-max))', and the test asks this
;; tree's `calculate-lisp-indent' for the column of each line of the
;; *same* text - so it is `lisp-mode''s idempotence, one line at a time.
;;
;; The property checks are `(get SYMBOL 'common-lisp-indent-function)' in
;; that same Emacs, after `(mapatoms (lambda (s) (function-get s
;; 'lisp-indent-function 'macro)))' - which is what makes Emacs's answers
;; stable: a macro's indent property only exists once its file is loaded,
;; and this tree's table is static data, i.e. the "everything loaded"
;; answer.

(import
 (scheme base)
 (schemacs buffer)
 (schemacs frame)
 (schemacs editfns)
 (schemacs search)
 (schemacs syntax)
 (schemacs core derived)
 (only (schemacs core lisp-mode)
       calculate-lisp-indent lisp-mode lisp-body-indent)
 (only (schemacs core cl-indent)
       common-lisp-indent-function common-lisp-indent-function-1
       lisp-indent-find-method lisp-indent-259 lisp-extended-loop-p
       lisp-indent-defun-method lisp-indent-lambda-list-keywords-regexp)
 (only (schemacs intervals) get)
 (only (srfi 64) test-assert test-equal test-begin test-end))

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*cl-indent-test*")))
      (set-buffer b)
      (erase-buffer)
      (thunk b))))

(define fixture
  "(defun foo (a b)
  (let ((x 1)
        (y 2))
    (when a
      b)))
(defmethod print-object ((obj foo) stream)
  (print-unreadable-object (obj stream :type t)
    (princ \"foo\")))
(case x
  ((a) 1)
  (t 2))
(flet ((f (x)
         (1+ x)))
  (f 1))
(loop for i from 1 to 10
      collect i)
(tagbody
 start
   (go end)
 end)
(let* ((a 1)
       (b 2))
  (while a
    (setq a nil)))
")

(define (indent-at-line text line)
  ;; The column `calculate-lisp-indent' gives the first non-blank
  ;; character of LINE (1-based) in a `lisp-mode' buffer holding TEXT.
  ;;--------------------------------------------------------------
  (with-buffer
   (lambda (b)
     (insert text)
     (lisp-mode)
     (goto-char 1)
     (forward-line (- line 1))
     (skip-chars-forward " \t")
     ;; "The value can also be a list of the form (COLUMN
     ;; CONTAINING-SEXP-START)" (`lisp-mode.el:1060'), and
     ;; `lisp-indent-line' takes the car - so does this.
     (let ((indent (calculate-lisp-indent)))
       (if (pair? indent) (car indent) indent)))))

(test-begin "schemacs_editor_cl_indent")

;; ------------------------------------------------------------------
;; The method table (`cl-indent.el:741-829')
;; ------------------------------------------------------------------
(test-equal "`defun' is a defun-like method"
  '(4 &lambda &body) (get 'defun 'common-lisp-indent-function))
(test-equal "`defmacro' follows `defun'"
  '(4 &lambda &body) (get 'defmacro 'common-lisp-indent-function))
(test-equal "`ccase' is `case'"
  (get 'case 'common-lisp-indent-function)
  (get 'ccase 'common-lisp-indent-function))
(test-equal "`case' is a destructuring specform"
  '(4 &rest (&whole 2 &rest 1)) (get 'case 'common-lisp-indent-function))
(test-equal "the second `if' entry wins"
  '(&rest nil) (get 'if 'common-lisp-indent-function))
(test-equal "and elisp's `if' gets its own rule"
  2 (get 'if 'common-lisp-indent-function-for-elisp))
(test-equal "`progn' is the compatibility table's"
  0 (get 'progn 'common-lisp-indent-function))

;; ------------------------------------------------------------------
;; `lisp-indent-find-method' (`cl-indent.el:164')
;; ------------------------------------------------------------------
(test-equal "a method of its own is found first"
  '(4 &rest (&whole 2 &rest 1))
  (lisp-indent-find-method 'case))
(test-equal "and the compatibility table is the fallback"
  1 (lisp-indent-find-method 'while))
(test-assert "no-compat does not fall back"
  (not (lisp-indent-find-method 'while #t)))
(test-equal "`lisp-indent-defun-method' is the C's"
  '(4 &lambda &body) lisp-indent-defun-method)
(test-assert "the lambda-list keyword regexp is the C's"
  (and (= 0 (string-match lisp-indent-lambda-list-keywords-regexp "&body"))
       (= 0 (string-match lisp-indent-lambda-list-keywords-regexp
                          "&allow-other-keys"))
       (not (string-match lisp-indent-lambda-list-keywords-regexp
                          "&nonsense"))))

;; ------------------------------------------------------------------
;; `lisp-mode' installs the engine (`lisp-mode.el:866')
;; ------------------------------------------------------------------
(test-assert "`lisp-mode' sets `lisp-indent-function' to a procedure"
  (with-buffer
   (lambda (b)
     (lisp-mode)
     (procedure? (buffer-local-value (current-buffer)
                                     'lisp-indent-function #f)))))

;; ------------------------------------------------------------------
;; The engine, line by line - Emacs 31.1's columns
;; ------------------------------------------------------------------
(test-equal "a defun's body" 2 (indent-at-line fixture 2))
(test-equal "a `let' binding" 8 (indent-at-line fixture 3))
(test-equal "the body of a `let'" 4 (indent-at-line fixture 4))
(test-equal "the body of a `defmethod'" 2 (indent-at-line fixture 7))
(test-equal "a `case' clause" 2 (indent-at-line fixture 10))
(test-equal "a tag expression inside a `tagbody'" 1 (indent-at-line fixture 18))
(test-equal "a tagbody form" 3 (indent-at-line fixture 19))
(test-equal "a `let*' binding" 7 (indent-at-line fixture 22))
(test-equal "the body of a nested `while'" 4 (indent-at-line fixture 24))

(test-equal "an extended loop's parts"
  6 (indent-at-line fixture 16))

;; The rest of the C's specform vocabulary, on its own fixture (a
;; `destructuring-bind' pattern, a backquoted list with `,@', and a
;; `defstruct' body) - Emacs 31.1's columns for the same three lines.
(define fixture2
  "(destructuring-bind (a b &rest c)
    (list 1 2 3)
  (+ a b))
`(a ,b ,@c
    (d ,(e f)))
(defstruct point
  (x 0))
")
(test-equal "a `destructuring-bind' pattern" 4 (indent-at-line fixture2 2))
(test-equal "and its body" 2 (indent-at-line fixture2 3))
(test-equal "a backquoted list's second element" 4 (indent-at-line fixture2 5))
(test-equal "a `defstruct' slot" 2 (indent-at-line fixture2 7))

(test-assert "`lisp-extended-loop-p' tells an extended loop from a symbol"
  (with-buffer
   (lambda (b)
     (insert "(loop for i from 1 to 10) (loop 5)")
     (lisp-mode)
     (and (save-excursion (goto-char 1) (lisp-extended-loop-p 1))
          (not (save-excursion (goto-char 25)
                               (lisp-extended-loop-p 25)))))))

(test-end "schemacs_editor_cl_indent")
