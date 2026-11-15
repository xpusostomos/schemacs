;; Tests for `(schemacs editor scheme)': the indentation engine
;; (`scheme-indent-function', `scheme-let-indent' and the property
;; table) and the syntax-table properties (`scheme-syntax-propertize').
;;
;; Every expectation here is Emacs 31.1's own: the indents are
;; `calculate-lisp-indent' in `scheme-mode', and the properties are what
;; `(get-text-property POS 'syntax-table)' answers there after
;; `(syntax-propertize (point-max))' - `(string-to-syntax "< cn")' is
;; 12582923 and `"> cn"' is 12582924.

(import
 (scheme base)
 (schemacs editor buffer)
 (schemacs editor frame)
 (schemacs editor editfns)
 (schemacs editor search)
 (schemacs editor syntax)
 (schemacs editor textprop)
 (only (schemacs editor scheme)
       scheme-mode scheme-indent-function scheme-let-indent
       scheme-syntax-propertize)
 (only (schemacs editor lisp-mode) calculate-lisp-indent)
 (only (schemacs editor intervals) get)
 (only (srfi 64) test-assert test-equal test-begin test-end))

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*scheme-test*")))
      (set-buffer b)
      (erase-buffer)
      (thunk b))))

(define (indent-at text pos)
  (with-buffer
   (lambda (b)
     (insert text)
     (scheme-mode)
     (goto-char pos)
     (calculate-lisp-indent))))

(define (syntax-at text pos)
  (with-buffer
   (lambda (b)
     (insert text)
     (scheme-mode)
     (scheme-syntax-propertize 1 (point-max))
     (get-text-property pos 'syntax-table))))

(test-begin "schemacs_editor_scheme")

;; ------------------------------------------------------------------
;; The property table (`scheme.el:522-760')
;; ------------------------------------------------------------------
(test-equal "`begin' is a specform 0"
  0 (get 'begin 'scheme-indent-function))
(test-equal "`do' takes two"
  2 (get 'do 'scheme-indent-function))
(test-equal "`syntax-rules' indents like a defun"
  'defun (get 'syntax-rules 'scheme-indent-function))
(test-equal "`let' is `scheme-let-indent'"
  scheme-let-indent (get 'let 'scheme-indent-function))
(test-equal "`define-library' takes one"
  1 (get 'define-library 'scheme-indent-function))
(test-equal "the MIT dialect's entries are there by default"
  1 (get 'fluid-let 'scheme-indent-function))
(test-equal "DSSSL's `element' takes one"
  1 (get 'element 'scheme-indent-function))

;; ------------------------------------------------------------------
;; The indentation, measured on `emacs -Q --batch' in `scheme-mode'
;; ------------------------------------------------------------------
;; A `let' binding list indents two, its body two more.
(test-equal "`let' body indents under the first binding"
  2 (indent-at "(let ((x 1))\n      x)\n" 15))
;; `lambda' is a specform 1: its body starts two columns in.
(test-equal "`lambda' body indents two"
  2 (indent-at "(lambda (x)\n  x)\n" 14))
;; `define' is caught by the "starts with def" rule and indents as a
;; defform.
(test-equal "`define' indents its body two"
  2 (indent-at "(define (f x)\n  x)\n" 16))
;; `do' is a specform 2, and `lisp-indent-specform' answers a *pair*
;; for the body line - Emacs's own `(4 1)'.
(test-equal "`do' body is a specform 2"
  (list 4 1) (indent-at "(do ((i 0))\n    (x))\n" 14))
;; `if' has no property: the continuation aligns under the first
;; argument.
(test-equal "`if' has no property"
  #f (get 'if 'scheme-indent-function))
(test-equal "... and indents under its first argument"
  4 (indent-at "(if a\n    b)\n" 7))

;; ------------------------------------------------------------------
;; The syntax-table properties (`scheme.el:684-760'): `#;' opens a
;; comment that the *end of the commented sexp* closes.
;; ------------------------------------------------------------------
(test-equal "`#;' gets the comment-start syntax"
  12582923 (car (syntax-at "(a #;b c)\n" 4)))
(test-equal "... and the commented sexp's end the comment-end one"
  12582924 (car (syntax-at "(a #;b c)\n" 6)))
;; The rule has no "not in a string" guard - Emacs marks these too,
;; measured: `(get-text-property 13 'syntax-table)' is `(12582923)'.
(test-equal "a `#;' inside a string is marked too"
  12582923 (car (syntax-at "(display \"a #; b\")\n" 13)))
(test-equal "and one inside a comment"
  12582923 (car (syntax-at ";; #; here\n" 4)))

(test-end "schemacs_editor_scheme")
