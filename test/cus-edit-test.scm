;; Tests for `(schemacs cus-edit)': `customize-set-variable` and
;; `custom-quote`. The expectations are Emacs 31.1's:
;;
;;   (customize-set-variable 'fill-column 40) -> 40, and the variable is 40
;;   (get 'fill-column 'customized-value)     -> (40)
;;   (custom-quote 5) -> 5, (custom-quote 'a) -> 'a (a quoted form)

(import
 (scheme base)
 (only (srfi 64) test-equal test-begin test-end)
 (only (schemacs custom) define-custom custom-variable-p)
 (only (schemacs cus-edit) customize-set-variable custom-quote)
 (only (schemacs intervals) get put)
 (only (schemacs data) set-default keywordp)
 (only (schemacs chartab) char-table?))

(define-custom *cus-edit-test-option* 5
  "A variable for the cus-edit tests."
  :type 'integer :group 'emacs)

(test-begin "schemacs_cus_edit")

(test-equal "customize-set-variable returns the value" 9
            (customize-set-variable '*cus-edit-test-option* 9))
(test-equal "and sets the variable" 9 (*cus-edit-test-option*))
(test-equal "and records the customized value" '(9)
            (get '*cus-edit-test-option* 'customized-value))
(test-equal "the variable is customizable"
            #t (custom-variable-p '*cus-edit-test-option*))

(test-equal "a comment is recorded" "why not"
            (begin (customize-set-variable '*cus-edit-test-option* 10 "why not")
                   (get '*cus-edit-test-option* 'variable-comment)))
(test-equal "an empty comment clears it" #f
            (begin (customize-set-variable '*cus-edit-test-option* 11 "")
                   (get '*cus-edit-test-option* 'variable-comment)))

;; `custom-quote` is self-quoting for the C's types and quotes the rest.
(test-equal "a number is self-quoting" 5 (custom-quote 5))
(test-equal "a string is self-quoting" "x" (custom-quote "x"))
(test-equal "#t is self-quoting" #t (custom-quote #t))
(test-equal "a symbol is quoted" '(quote a) (custom-quote 'a))
(test-equal "a list is quoted" '(quote (1 2)) (custom-quote '(1 2)))
(test-equal "a keyword is self-quoting" ':x (custom-quote ':x))

(test-end "schemacs_cus_edit")
