(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor custom)
       define-custom custom-declare-variable custom-initialize-set
       custom-add-option custom-add-dependencies custom-handle-keyword
       custom-variable-p custom--standard-value
       *custom-dont-initialize* *custom-declare-variable-hook*)
 (only (schemacs editor intervals) get put)
 (only (ice-9 exceptions) exception-message))

;; `custom.el`'s declaration half: `defcustom' and the
;; `custom-declare-variable' it calls.
;;
;; Every expectation below is `emacs -Q --batch' on Emacs 31.1, asked for
;; the same declaration - `(defcustom gx 2 "A test option." :type 'integer
;; :group 'editing :version "31.1")' there, the same form spelled the way
;; this tree spells it here.
;;
;; **The one that would be easy to get wrong is the `:set' function.** The
;; C's `custom-initialize-reset' *calls* the setter when the declaration
;; runs, so an option whose `:set' doubles its value is 10 and not 5 - and
;; a port that merely stored the value would be 5. Measured in Emacs, and
;; pinned here.

(test-begin "schemacs_editor_custom")

;;-------------------------------------------------------------
;; A declaration, and what it records
;;-------------------------------------------------------------

(define-custom gx 2
  "A test option."
  :type 'integer
  :group 'editing
  :version "31.1")

(test-equal "the variable has its standard value"
  2 gx)

(test-equal "`standard-value' holds the expression, as a thunk"
  '(2)
  (list ((car (get 'gx 'standard-value)))))

(test-equal "`custom--standard-value' evaluates it"
  2 (custom--standard-value 'gx))

(test-equal "`:type' is the property `custom-type'"
  'integer (get 'gx 'custom-type))

(test-equal "`:version' is `custom-version'"
  "31.1" (get 'gx 'custom-version))

(test-equal "the docstring is `variable-documentation'"
  "A test option." (get 'gx 'variable-documentation))

(test-equal "`:group' adds the option to the group's member list"
  '((gx custom-variable))
  (get 'editing 'custom-group))

(test-assert "`custom-variable-p' knows a customizable variable"
  (custom-variable-p 'gx))

(test-assert "and does not claim a variable that is not one"
  (not (custom-variable-p 'car)))

;;-------------------------------------------------------------
;; The initializers, which are what `:initialize` picks between
;;-------------------------------------------------------------
;; `custom-initialize-reset` is the default, and it *calls the setter* -
;; so a `:set` that doubles gives 10, exactly as Emacs does. The setter
;; here writes through the variable's own writer, which is what a real
;; `:set` written for this tree does.
;;-------------------------------------------------------------

(define-custom gset 5
  "Doubles on set."
  :type 'integer
  :set (lambda (symbol value)
         ((get symbol 'custom-writer) symbol (* 2 value))))

(test-equal "the default initializer calls `:set` at definition"
  10 gset)

(define-custom ginit 7
  "Not re-set when it is already bound."
  :type 'integer
  :initialize custom-initialize-set)

(test-equal "`custom-initialize-set` leaves an already-bound variable alone"
  7 ginit)

;;-------------------------------------------------------------
;; The clauses the walk must recognise, and the two errors
;;-------------------------------------------------------------

(define-custom goptions 1
  "Has options."
  :type 'integer
  :options '(1 2 3))

(test-equal "`:options' is `custom-options'"
  '(1 2 3) (get 'goptions 'custom-options))

(define-custom greq 1 "Requires a feature." :require 'foo)

(test-equal "`:require' is `custom-requests'"
  '(foo) (get 'greq 'custom-requests))

(test-equal "`custom-add-option' conses onto the front, as the C does"
  '(4 1 2 3)
  (begin (custom-add-option 'goptions 1)     ; already there
         (custom-add-option 'goptions 4)
         (get 'goptions 'custom-options)))

(test-equal "`custom-add-dependencies' keeps the order the C keeps"
  '(b a)
  (begin (custom-add-dependencies 'gdeps '(a b))
         (get 'gdeps 'custom-dependencies)))

;; The C's `(error "Unknown keyword %s")` and "Doc string is missing", as
;; this tree's `error` says them.
(test-equal "an unknown keyword is an error, not silence"
  "Unknown keyword ~a"
  (exception-message
   (guard (e (#t e))
     (custom-handle-keyword 'gx ':bogus 1 'custom-variable))))

(test-equal "a docstring that is a keyword is 'Doc string is missing'"
  "Doc string is missing"
  (exception-message
   (guard (e (#t e))
     (custom-declare-variable 'gmissing (lambda () 1) ':type
                              (lambda (symbol) 1)
                              (lambda (symbol value) value)))))

;;-------------------------------------------------------------
;; The switch, and the hook
;;-------------------------------------------------------------

(test-equal "`custom-dont-initialize' skips the initializer, and the hook still runs"
  '(#t unset)
  (let ((seen 'unset) (hook-ran #f))
    (parameterize ((*custom-dont-initialize* #t)
                   (*custom-declare-variable-hook*
                    (list (lambda () (set! hook-ran #t)))))
      (custom-declare-variable 'gdont (lambda () 42) "no init"
                               (lambda (symbol) seen)
                               (lambda (symbol value) (set! seen value))))
    ;; the variable was never set to its standard value, and the hook ran
    ;; anyway - the C's `run-hooks' is *outside* the `unless'
    (list hook-ran seen)))

(test-end "schemacs_editor_custom")
