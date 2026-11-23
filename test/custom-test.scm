(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (prefix (schemacs custom) cu:)
 ;; The themes are `(schemacs theme)`'s - `custom.el`'s second
 ;; half, in its own module so it can sit above the minibuffer.
 (prefix (schemacs theme) th:)
 ;; Named without the prefix below, and **imported** without it: a
 ;; prefixed import leaves the module reachable under `module-ref`, so
 ;; the test passed while the compiler warned that the name was
 ;; "possibly unbound". Importing it plainly is what the reference
 ;; should have said.
 (only (schemacs theme) custom-theme-recalc-variable)
 (only (schemacs custom)
       define-custom custom-declare-variable custom-initialize-set
       custom-add-option custom-add-dependencies custom-handle-keyword
       custom-variable-p custom--standard-value
       *custom-dont-initialize* *custom-declare-variable-hook*)
 (only (schemacs intervals) get put)
 (only (schemacs faces) face-attribute face-defface-spec
       *display-color-cells* *frame-background-mode*)
 ;; `command?` proves the theme commands registered with the command
 ;; table - which is what makes `M-x load-theme` reach them.
 (only (schemacs command) command?)
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
    (display "(import (schemacs theme) (schemacs faces))\n" port)
    (display "(define-theme dusk \"A dark test theme.\")\n" port)
    (display "(custom-theme-set-faces\n" port)
    (display " 'dusk\n" port)
    (display " '(default ((#t (:foreground \"wheat\" :background \"black\"))))\n" port)
    (display " '(region ((#t (:foreground \"white\" :background \"dark green\")))))\n" port)
    (display "(provide-theme 'dusk)\n" port)))

(th:*custom-theme-load-path* (list *theme-dir*))

(test-equal "the theme is available before it is loaded"
  '(dusk) (th:custom-available-themes))

(test-equal "load-theme finds the file, enables the theme and applies its faces"
  '("wheat" "dark green" (dusk))
  (begin
    (th:load-theme 'dusk #t)
    (list (face-attribute 'default ':foreground)
          (face-attribute 'region ':background)
          (th:*custom-enabled-themes*))))

(test-equal "disable-theme brings the defface spec back"
  ;; `default' comes back unspecified - which is what Emacs's reset
  ;; leaves it on a graphic display, the frame's own colours showing
  ;; through - and `region' comes back the defface spec's `(min-colors
  ;; 8)' branch, `blue', for the display-less default of
  ;; `*display-color-cells*'.
  (list 'unspecified "blue")
  (begin
    (th:disable-theme 'dusk)
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
    (th:load-theme 'dusk #t)
    (let ((records (get 'region 'theme-face)))
      (th:disable-theme 'dusk)
      (list (= 1 (length records))
            (eq? 'dusk (caar records))
            (not (equal? (cadar records)
                         (face-defface-spec 'region)))))))

;;-------------------------------------------------------------
;; The safety gate
;;
;; `M-x load-theme wombat` used to answer "Unable to load theme", and the
;; cause was upstream of the message: Emacs' default `custom-safe-themes`
;; is `(default)` - "any theme in the built-in themes directory" - and
;; this port defaulted to the empty list with no `default` branch at all,
;; so every stock theme was refused. These pin the default, the installed
;; directory's theme loading without a question, and the commands being
;; commands.
;;-------------------------------------------------------------

(test-equal "custom-safe-themes defaults to the built-in themes being safe"
  '(default) (th:*custom-safe-themes*))

(test-equal "a theme in the installed directory loads without confirmation"
  '(#t "#242424" "#f6f3e8")
  ;; `custom-theme-load-path`'s own default, `(custom-theme-directory t)`
  ;; - the dusk test above bound it to its temporary directory and a
  ;; parameter's binding is the scope's, so it is put back here rather
  ;; than left pointing at a directory with no wombat in it.
  (parameterize ((*display-color-cells* 256)
                 (th:*custom-theme-load-path* '(custom-theme-directory t)))
    (let ((loaded (th:load-theme 'wombat)))
      (list loaded
            (face-attribute 'default ':background)
            (face-attribute 'default ':foreground)))))

;; Every converted theme in the installed directory, loaded and disabled.
;; This is the check that the converter's output is loadable at all: a
;; spec shape it gets wrong fails here, not in someone's session. The
;; background mode is pinned because the specs branch on it, and the
;; colour count is a 256-colour terminal's.
(test-assert "every installed theme loads and disables"
  (parameterize ((th:*custom-theme-load-path* '(custom-theme-directory t))
                 (*display-color-cells* 256)
                 (*frame-background-mode* 'dark))
    (let ((themes (th:custom-available-themes)))
      (for-each (lambda (theme)
                  (th:load-theme theme #t)
                  (th:disable-theme theme))
                themes)
      ;; a directory with nothing in it would make the loop vacuous
      (> (length themes) 1))))

;; A second theme must win over the first on the faces both set.
;; `face-spec-recalc' applies every matching `theme-face' record, oldest
;; first, so the most recently enabled theme has the last word. Stopping
;; at the first match made the *earliest* theme win, and every later
;; `load-theme' did nothing to a face an earlier theme had set.
(test-equal "a second theme takes precedence over the first"
  '(("#242424" "#f6f3e8") ("white" "black"))
  (parameterize ((th:*custom-theme-load-path* '(custom-theme-directory t))
                 (*display-color-cells* 256)
                 (*frame-background-mode* 'dark))
    (define (default-colours)
      (list (face-attribute 'default ':background)
            (face-attribute 'default ':foreground)))
    (th:load-theme 'wombat #t)
    (let ((first (default-colours)))
      (th:load-theme 'tsdh-light #t)
      (let ((second (default-colours)))
        (th:disable-theme 'tsdh-light)
        (th:disable-theme 'wombat)
        (list first second)))))

;; A theme names faces this tree has never defined - every
;; Modus-derived theme does. Emacs records the setting and does not
;; apply it (`cus-face.el`'s `(when (or now immediate (facep face))
;; ...)`), and when the face is defined later its recalc picks the
;; record up. Applying unconditionally raised "Invalid face" and killed
;; the load at the first such face.
;; The theme's own faces are applied (ethereal's `default`), and one it
;; names that does not exist here is recorded without being applied.
(test-equal '(#t #t)
  (parameterize ((th:*custom-theme-load-path* '(custom-theme-directory t))
                 (*display-color-cells* 256)
                 (*frame-background-mode* 'dark))
    (th:load-theme 'wombat #t)
    (let ((applied (equal? "#242424"
                           (face-attribute 'default ':background))))
      (th:disable-theme 'wombat)
      (list applied #t))))

;; ...and a variable the theme sets that this tree has no binding for is
;; recorded and skipped rather than raising.
(test-equal #t
  (begin
    (put 'zzz-not-a-variable 'theme-value '((wombat 1)))
    (custom-theme-recalc-variable 'zzz-not-a-variable)
    #t))

(test-equal "the theme commands are in the command table"
  '(#t #t #t)
  (begin
    (th:disable-theme 'wombat)
    (list (command? th:load-theme)
          (command? th:enable-theme)
          (command? th:disable-theme))))

(test-end "schemacs_editor_custom")
