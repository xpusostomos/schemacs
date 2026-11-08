(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (prefix (schemacs editor custom) cu:)
 (only (schemacs editor custom)
       define-custom custom-declare-variable custom-initialize-set
       custom-add-option custom-add-dependencies custom-handle-keyword
       custom-variable-p custom--standard-value
       *custom-dont-initialize* *custom-declare-variable-hook*)
 (only (schemacs editor intervals) get put)
 (only (schemacs editor faces) face-attribute)
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

(define-custom *gx* 2
  "A test option."
  :type 'integer
  :group 'editing
  :version "31.1")

(test-equal "the variable has its standard value"
  2 (*gx*))

;; **The option is a parameter**, so it can be bound for one command the
;; way Elisp's `let` binds a `defcustom` - `(let ((fill-column 40)) ...)'
;; is ordinary Emacs code. That is the reason it is a parameter and not a
;; plain variable: a plain one would make the ported `let` shadow
;; lexically while the called function went on reading the global.
(test-equal "an option can be bound with `parameterize', as `let' binds a defcustom"
  '(2 40 2)
  (list (*gx*)
        (parameterize ((*gx* 40)) (*gx*))
        (*gx*)))

(test-equal "`standard-value' holds the expression, as a thunk"
  '(2)
  (list ((car (get '*gx* 'standard-value)))))

(test-equal "`custom--standard-value' evaluates it"
  2 (custom--standard-value '*gx*))

(test-equal "`:type' is the property `custom-type'"
  'integer (get '*gx* 'custom-type))

(test-equal "`:version' is `custom-version'"
  "31.1" (get '*gx* 'custom-version))

(test-equal "the docstring is `variable-documentation'"
  "A test option." (get '*gx* 'variable-documentation))

(test-equal "`:group' adds the option to the group's member list"
  '((*gx* custom-variable))
  (get 'editing 'custom-group))

(test-assert "`custom-variable-p' knows a customizable variable"
  (custom-variable-p '*gx*))

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

(define-custom *gset* 5
  "Doubles on set."
  :type 'integer
  :set (lambda (symbol value)
         ((get symbol 'custom-writer) symbol (* 2 value))))

(test-equal "the default initializer calls `:set` at definition"
  10 (*gset*))

(define-custom *ginit* 7
  "Not re-set when it is already bound."
  :type 'integer
  :initialize custom-initialize-set)

(test-equal "`custom-initialize-set` leaves an already-bound variable alone"
  7 (*ginit*))

;;-------------------------------------------------------------
;; The clauses the walk must recognise, and the two errors
;;-------------------------------------------------------------

(define-custom *goptions* 1
  "Has options."
  :type 'integer
  :options '(1 2 3))

(test-equal "`:options' is `custom-options'"
  '(1 2 3) (get '*goptions* 'custom-options))

(define-custom *greq* 1 "Requires a feature." :require 'foo)

(test-equal "`:require' is `custom-requests'"
  '(foo) (get '*greq* 'custom-requests))

(test-equal "`custom-add-option' conses onto the front, as the C does"
  '(4 1 2 3)
  (begin (custom-add-option '*goptions* 1)     ; already there
         (custom-add-option '*goptions* 4)
         (get '*goptions* 'custom-options)))

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
     (custom-handle-keyword '*gx* ':bogus 1 'custom-variable))))

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

;;-------------------------------------------------------------
;; The themes - `custom.el''s second half
;;
;; A theme is written to a temporary directory - the way a user's own
;; lives beside their init file - and loaded from there, with
;; `*custom-theme-load-path*' pointing at it. The whole chain is the
;; test: `define-theme' declares, `custom-theme-set-faces' records,
;; `load-theme' reads and enables, the face's attributes change, and
;; `disable-theme' brings the defface spec back.
;;-------------------------------------------------------------

(define *theme-dir* "/tmp/schemacs-custom-tests-themes")
(define *theme-file* (string-append *theme-dir* "/dusk-theme.scm"))

(system (string-append "mkdir -p " *theme-dir*))
(call-with-output-file *theme-file*
  (lambda (port)
    (display "(import (schemacs editor custom) (schemacs editor faces))\n" port)
    (display "(define-theme dusk \"A dark test theme.\")\n" port)
    (display "(custom-theme-set-faces\n" port)
    (display " 'dusk\n" port)
    (display " '(default ((#t (:foreground \"wheat\" :background \"black\"))))\n" port)
    (display " '(region ((#t (:foreground \"white\" :background \"dark green\")))))\n" port)
    (display "(provide-theme 'dusk)\n" port)))

(cu:*custom-theme-load-path* (list *theme-dir*))

(test-equal "the theme is available before it is loaded"
  '(dusk) (cu:custom-available-themes))

(test-equal "load-theme finds the file, enables the theme and applies its faces"
  '("wheat" "dark green" (dusk))
  (begin
    (cu:load-theme 'dusk #t)
    (list (face-attribute 'default ':foreground)
          (face-attribute 'region ':background)
          (cu:*custom-enabled-themes*))))

(test-equal "disable-theme brings the defface spec back"
  ;; `default' comes back unspecified - which is what Emacs's reset
  ;; leaves it on a graphic display, the frame's own colours showing
  ;; through - and `region' comes back the defface spec's `(min-colors
  ;; 8)' branch, `blue', for the display-less default of
  ;; `*display-color-cells*'.
  (list 'unspecified "blue")
  (begin
    (cu:disable-theme 'dusk)
    (list (face-attribute 'default ':foreground)
          (face-attribute 'region ':background))))

;; What the theme leaves behind on the face's own property: one
;; `(THEME SPEC)' record, which `face-spec-recalc' walks. The duplicate
;; the first version of this left - a second record, from `face-spec-set'
;; being told the spec was the *defface* one - is what this pins: there
;; is one record per theme, and the defface spec beside it is the face's
;; own.
(test-equal "the face carries one theme record, and its defface spec is untouched"
  '(#t #t #t)
  (begin
    (cu:load-theme 'dusk #t)
    (let ((records (get 'region 'theme-face)))
      (cu:disable-theme 'dusk)
      (list (= 1 (length records))
            (eq? 'dusk (caar records))
            (not (equal? (cadar records)
                         (face-defface-spec 'region)))))))

(test-end "schemacs_editor_custom")
