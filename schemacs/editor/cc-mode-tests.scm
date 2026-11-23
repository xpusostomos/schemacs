;; Tests for `(schemacs editor cc-mode)' - the first pass of
;; `lisp/progmodes/cc-mode.el': the found-type half of the change
;; machinery.
;;
;; **Every expectation here is Emacs 31.1's own answer**, measured with
;; `emacs -Q --batch' in a real `c-mode' buffer (`/tmp/measure-ccmode.el'
;; and `/tmp/measure-coalesce2.el', rebuilt from the cases below).
;;
;; The two `c-*-de-typedef' functions are carried but not tested here:
;; their inputs are the `c-typedef' text properties font locking writes,
;; so they are exercised by the change-hook differential once
;; `c-before-change'/`c-after-change' are wired. Emacs's own answers
;; were measured: after `(delete-region 1 8)' on
;; "typedef int myint;\nmyint x;", "myint" is out of `c-found-types',
;; and `c-before-change-de-typedef' over the same text empties it.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (guile) hash-ref hash-set!)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor buffer) allocate-buffer set-buffer buffer-local-value
       set-buffer-local-value!)
 (only (schemacs editor editfns) insert goto-char point)
 (only (schemacs editor syntax) set-syntax-table)
 (only (schemacs editor cc-defs) c-lang-const *c-buffer-is-cc-mode*)
 (schemacs editor cc-langs)
 (only (schemacs editor cc-styles) c-set-style)
 (only (schemacs editor cc-engine) c-found-types c-add-type-1 c-clear-found-types
       c-new-id-start c-new-id-end c-new-id-is-type)
 (only (schemacs editor cc-mode)
       c-unfind-enclosing-token c-unfind-coalesced-tokens c-update-new-id))

(test-begin "schemacs_editor_cc_mode")

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (c-set-style "gnu")
      ;; `c-common-init' creates the table; cc-mode.el's mode
      ;; definitions are not ported, so the replay does it.
      (c-clear-found-types))
    b))

(define (found? name)
  (let ((h (c-found-types)))
    (and h (hash-ref h name))))

(define (put-found! name)
  (hash-set! (c-found-types) name #t))

;;--------------------------------------------------------------
;; `c-unfind-enclosing-token'
;;--------------------------------------------------------------
;; Emacs, measured: inside "abc" the function answers t and removes the
;; name; at the following space it answers nil and leaves the name.
(let ((b (fresh "abc def\n")))
  (c-add-type-1 1 4)
  (test-equal "the type was recorded" #t (found? "abc"))
  (test-equal "c-unfind-enclosing-token inside the token" #t
              (c-unfind-enclosing-token 2))
  (test-equal "and it removed the name" #f (found? "abc")))

(let ((b (fresh "abc def\n")))
  (c-add-type-1 1 4)
  (test-equal "c-unfind-enclosing-token at the space" #f
              (c-unfind-enclosing-token 4))
  (test-equal "the name is still there" #t (found? "abc")))

;;--------------------------------------------------------------
;; `c-unfind-coalesced-tokens'
;;--------------------------------------------------------------
;; Emacs, measured on "fo o": removing the space (BEG 3, END 4) would
;; join the fragments, so both fragments are removed - "o" by the
;; end-of-region arm and "fo" by the beg one - while the joined name,
;; which nobody had recorded, is untouched.
(let ((b (fresh "fo o\n")))
  (put-found! "o")
  (put-found! "fo")
  (put-found! "foo")
  (c-unfind-coalesced-tokens 3 4)
  (test-equal "the fragment after END is removed" #f (found? "o"))
  (test-equal "the fragment before BEG is removed" #f (found? "fo"))
  (test-equal "the joined name is not touched" #t (found? "foo")))

;; Emacs, measured on "xfo oy": both whole identifiers go.
(let ((b (fresh "xfo oy\n")))
  (put-found! "xfo")
  (put-found! "oy")
  (c-unfind-coalesced-tokens 4 5)
  (test-equal "xfo is removed" #f (found? "xfo"))
  (test-equal "oy is removed" #f (found? "oy")))

;;--------------------------------------------------------------
;; `c-update-new-id'
;;--------------------------------------------------------------
;; Emacs, measured: at the end of "abc" in "int abc = 1;" the bounds
;; are 5 and 9, and the type flag is cleared.
(let ((b (fresh "int abc = 1;\n")))
  (goto-char 8)
  (set-buffer-local-value! b 'c-new-id-is-type #t)
  (c-update-new-id (point))
  (test-equal "c-update-new-id's start" 5 (c-new-id-start))
  (test-equal "c-update-new-id's end" 9 (c-new-id-end))
  (test-equal "c-update-new-id clears the type flag" #f (c-new-id-is-type)))

(test-end "schemacs_editor_cc_mode")
