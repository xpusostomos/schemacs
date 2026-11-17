;; -*- mode: scheme; -*-
;; Tests for `(schemacs editor help)' and `(schemacs editor doc)' -
;; help.el's `substitute-command-keys', `substitute-quotes',
;; `key-valid-p' and `help--key-description-fontified', and doc.c's
;; `documentation' / `documentation-property'.
;;
;; **Every expectation is `emacs -Q --batch`'s own answer** on the same
;; input, measured first. The command-name cases use a fresh process's
;; global map, where `narrow-to-region` is bound to `C-x n n`.

(import
  (scheme base)
  (scheme char)
  (only (guile) string-contains)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor buffer) *current-buffer* allocate-buffer
        get-buffer-create set-buffer erase-buffer current-buffer)
  (only (schemacs editor frame) *current-frame* new-frame)
  ;; loading editfns registers its commands in `*command-table*`, which
  ;; `documentation`'s symbol path reads.
  (schemacs editor editfns)
  (only (schemacs editor editfns) *text-quoting-style*)
  (only (schemacs editor subr) kbd)
  (only (schemacs editor textprop) get-text-property)
  (only (schemacs editor help)
        substitute-command-keys substitute-quotes key-valid-p
        help--key-description-fontified)
  (only (schemacs editor doc) documentation documentation-property)
  (only (ice-9 exceptions) exception-message))

(test-begin "schemacs_editor_help")

;; The tree's string properties live beside the string
;; (`string-intervals-property`), not in it, so `test-equal`'s `equal?`
;; compares contents and these tests can assert on the strings directly.

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*help-tests*")))
      (set-buffer b)
      (erase-buffer)
      (thunk))))

;; ------------------------------------------------------------------
;; `key-valid-p' - the table measured on Emacs 31.1.
(test-equal '(#t #t #t #t #t #f #f #t #t #f #f #f #f)
  (map key-valid-p
       (list "C-x" "C-x n n" "f" "<f6>" "C-M-<space>" "not-a-key"
             "" "S o m" "H-<left>" "M-C-down" "C-" "<>" "a  b")))

;; ------------------------------------------------------------------
;; `substitute-command-keys'

;; An ordinary string comes back unchanged.
(test-equal "abc"
  (with-buffer (lambda () (substitute-command-keys "abc"))))

;; `\[COMMAND]' - the key when bound, "M-x NAME" when not.
(test-equal "C-x n n"
  (with-buffer (lambda () (substitute-command-keys "\\[narrow-to-region]"))))
(test-equal "M-x no-such-command"
  (with-buffer
   (lambda () (substitute-command-keys "\\[no-such-command]"))))

;; `\`KEY'' - the key, fontified with `help-key-binding' (both the
;; `face' and the `font-lock-face' property, as the C adds both).
(test-equal "type C-x now"
  (with-buffer (lambda () (substitute-command-keys "type \\`C-x' now"))))
(test-equal '(help-key-binding help-key-binding)
  (with-buffer
   (lambda ()
     (let ((s (substitute-command-keys "type \\`C-x' now")))
       (list (get-text-property 5 'face s)
             (get-text-property 5 'font-lock-face s))))))

;; A quoted thing that is not a key is left for the quote rule: under
;; `curve' the backtick becomes a left quote and the apostrophe a right
;; one, and the backslash stands.
(test-equal "x\\‘not-a-key’"
  (with-buffer
   (lambda ()
     (parameterize ((*text-quoting-style* 'curve))
       (substitute-command-keys "x\\`not-a-key'")))))

;; `\=' quoting, at the end and in the middle, and a trailing backslash.
(test-equal '("abc\\" "abc\\=" "ab" "\\[")
  (with-buffer
   (lambda ()
     (list (substitute-command-keys "abc\\")
           (substitute-command-keys "abc\\=")
           (substitute-command-keys "a\\=b")
           (substitute-command-keys "\\=\\[")))))

;; The three quoting styles, measured.
(test-equal '("‘a’ and ’b’" "'a' and 'b'" "`a' and 'b'")
  (with-buffer
   (lambda ()
     (list (parameterize ((*text-quoting-style* 'curve))
             (substitute-command-keys "`a' and 'b'"))
           (parameterize ((*text-quoting-style* 'straight))
             (substitute-command-keys "`a' and 'b'"))
           (parameterize ((*text-quoting-style* 'grave))
             (substitute-command-keys "`a' and 'b'"))))))

(test-equal "‘a’" (substitute-quotes "`a'"))

;; `help--key-description-fontified' - the face on the key description.
(test-equal '("C-x n n" help-key-binding)
  (with-buffer
   (lambda ()
     (let ((s (help--key-description-fontified (kbd "C-x n n"))))
       (list s (get-text-property 0 'face s))))))

;; ------------------------------------------------------------------
;; `documentation' and `documentation-property'

;; `documentation' substitutes keys unless RAW: the docstring's
;; `\[widen]' becomes `C-x n w' in the first and stands in the second.
(test-assert "documentation substitutes keys"
  (let ((doc (documentation 'narrow-to-region)))
    (and doc (string-contains doc "C-x n w"))))
(test-assert "documentation RAW keeps \\[widen]"
  (let ((doc (documentation 'narrow-to-region #t)))
    (and doc (string-contains doc "\\[widen]"))))

(test-equal #f (documentation-property 'nothing-here 'variable-documentation))

;; A symbol that names nothing and is not a procedure is the C's
;; `void-function' report; this tree's one error type carries it.
(test-equal "Void function"
  (guard (e (#t (exception-message e))) (documentation 'no-such-function)))

(test-equal "Invalid function"
  (guard (e (#t (exception-message e))) (documentation 42)))

(test-end "schemacs_editor_help")
