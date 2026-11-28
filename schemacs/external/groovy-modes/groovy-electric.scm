(define-library (schemacs external groovy-modes groovy-electric)
  ;; A port of `groovy-electric.el' from Groovy-Emacs-Modes
  ;; (https://github.com/Groovy-Emacs-Modes/groovy-emacs-modes) - the
  ;; electric minor mode for `groovy-mode'.  It lives under
  ;; `schemacs/external' because it is not part of GNU Emacs.
  ;;
  ;; Every function is the upstream one with its docstring; the
  ;; mechanical elisp-to-scheme translations apply (`setq' is `set!',
  ;; `when' whose value is used is `if', char literals are the integers
  ;; Elisp's `?\X' names - `last-command-event' is an integer here too).
  ;;
  ;; **Departures, each named where it is:**
  ;;
  ;;   * `defgroup groovy-electric' is carried now that `defgroup` is
  ;;     (`custom.scm`); the two `define-custom` variables keep their
  ;;     `:group` keywords.
  ;;   * The two defcustoms are `define-custom` parameters, so their
  ;;     names carry the tree's stars and are read as calls:
  ;;     `(*groovy-electric-expand-delimiters-list*)'.
  ;;   * **`define-minor-mode` is given the keyword form** where the
  ;;     upstream uses the positional one (INIT-VALUE LIGHTER KEYMAP
  ;;     BODY ...); the keywords are the same clauses and the tree's
  ;;     macro reads only that spelling (see `easy-mmode.scm`).
  ;;   * **The definitions are ordered differently from the file.**
  ;;     `define-minor-mode`'s body runs when the mode is toggled and
  ;;     names `groovy-electric-setup-keymap'; a Scheme binding must
  ;;     exist when the form runs, and `define-key` resolves its
  ;;     command when it is *called*, so the functions come first and
  ;;     the mode last.  Upstream's order is: defvar, defcustoms, the
  ;;     mode, the keymap setup, the predicates, the commands.
  ;;   * `self-insert-command` here takes the character as an
  ;;     argument (Emacs re-derives it from `last-command-event` in its
  ;;     interactive form), so each command passes
  ;;     `(*last-command-event*)`.
  ;;   * `(newline)` is `insert-newline` in this tree - `newline` is
  ;;     `(scheme base)`'s output procedure (see `simple.scm`).
  (import
    (scheme base)
    (only (schemacs custom) define-custom defgroup)
    (only (schemacs buffer) current-buffer)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs command) define-command prefix-numeric-value
          *last-command-event*)
    (only (schemacs keymap) define-key)
    (only (schemacs cmds) self-insert-command backward-char)
    (only (schemacs simple) insert-newline)
    (only (schemacs editfns) char-equal char-after preceding-char
          save-excursion point insert)
    (only (schemacs textprop) text-properties-at)
    (only (schemacs subr) car-safe)
    (only (schemacs progmodes cc-engine) c-literal-limits)
    (only (schemacs external groovy-modes groovy-mode) groovy-mode-map))

  ;; `groovy-electric-mode-variable` is the generated accessor over the
  ;; mode's buffer-local state - Emacs's `groovy-electric-mode` *as a
  ;; variable*; the bare name is the command in a Lisp-1.
  (export groovy-electric-mode groovy-electric-mode-variable
          groovy-electric-matching-delimeter-alist
          *groovy-electric-expand-delimiters-list*
          *groovy-electric-newline-before-closing-bracket*
          groovy-electric-setup-keymap
          groovy-electric-code-at-point-p
          groovy-electric-string-at-point-p
          groovy-electric-gstring-at-point-p
          groovy-electric-is-last-command-event-expandable-punct-p
          groovy-electric-curlies groovy-electric-matching-char
          groovy-electric-pound)

  (begin

    (define groovy-electric-matching-delimeter-alist
      ;; The pairs `{[('\"" close with.  Elisp's `?\[` and friends are
      ;; integers, and so is `last-command-event` here; the keys are
      ;; therefore the code points, as they are in Emacs.
      (list (cons (char->integer #\[) (char->integer #\]))
            (cons (char->integer #\() (char->integer #\)))
            (cons (char->integer #\') (char->integer #\'))
            (cons (char->integer #\") (char->integer #\"))))

    (defgroup groovy-electric ()
      "Minor mode providing electric editing commands for groovy files"
      :group 'groovy)

    (define-custom *groovy-electric-expand-delimiters-list* (list 'all)
      "*List of contexts where matching delimiter should be inserted.
The word 'all' will do all insertions."
      :type '(set :extra-offset 8
                  (const :tag "Everything" all)
                  (const :tag "Curly brace" #\{)
                  (const :tag "Square brace" #\[)
                  (const :tag "Round brace" #\()
                  (const :tag "Quote" #\')
                  (const :tag "Double quote" #\")
                  (const :tag "Dollar in GStrings" #\$))
      :group 'groovy-electric)

    (define-custom *groovy-electric-newline-before-closing-bracket* #f
      "*Controls whether a newline should be inserted before the
closing bracket or not."
      :type 'boolean :group 'groovy-electric)

    (define (groovy-electric-setup-keymap)
      ;; The keys are bound in the *major mode's* map, as upstream does
      ;; (`define-minor-mode''s KEYMAP argument is given the same map;
      ;; the tree registers it through `add-minor-mode` as Emacs does).
      (define-key groovy-mode-map "{" groovy-electric-curlies)
      (define-key groovy-mode-map "(" groovy-electric-matching-char)
      (define-key groovy-mode-map "[" groovy-electric-matching-char)
      (define-key groovy-mode-map "\"" groovy-electric-matching-char)
      (define-key groovy-mode-map "'" groovy-electric-matching-char)
      (define-key groovy-mode-map "$" groovy-electric-pound)
      #f)

    (define (groovy-electric-code-at-point-p)
      ;; **`(null (memq ...))` is `(not (memq ...))` here**: `memq`
      ;; answers `#f` where Elisp's nil is, and `(null? #f)` is false.
      (and (groovy-electric-mode-variable)
           (let* ((properties (text-properties-at (point))))
             (and (not (memq 'font-lock-string-face properties))
                  (not (memq 'font-lock-comment-face properties))))))

    (define (groovy-electric-string-at-point-p)
      (and (groovy-electric-mode-variable)
           (pair? (memq 'font-lock-string-face (text-properties-at (point))))))

    (define (groovy-electric-gstring-at-point-p)
      ;; "This checks it is a GString ("...") not normal string '...'"
      ;;
      ;; `(car (c-literal-limits))` is `car-safe`: outside a literal the
      ;; answer is nil there, and `char-after` of nil is `char-after` of
      ;; point, which is Emacs's own reading of `(char-after (car nil))`.
      (and (groovy-electric-mode-variable)
           (pair? (memq 'font-lock-string-face (text-properties-at (point))))
           (save-excursion
             (char-equal (char->integer #\")
                         (char-after (car-safe (c-literal-limits)))))))

    (define (groovy-electric-is-last-command-event-expandable-punct-p)
      (or (memq 'all (*groovy-electric-expand-delimiters-list*))
          (memq (*last-command-event*) (*groovy-electric-expand-delimiters-list*))))

    (define-command (groovy-electric-curlies arg)
      "Insert a curly brace and its closer when appropriate."
      (interactive "P")
      (self-insert-command (prefix-numeric-value arg) (*last-command-event*))
      (when (and (groovy-electric-is-last-command-event-expandable-punct-p)
                 (groovy-electric-code-at-point-p))
        (insert " ")
        (save-excursion
          (if (*groovy-electric-newline-before-closing-bracket*)
              (insert-newline))
          (insert "}")))
      #f)

    (define-command (groovy-electric-matching-char arg)
      "Insert the matching delimiter for the typed opener."
      (interactive "P")
      (self-insert-command (prefix-numeric-value arg) (*last-command-event*))
      (and (groovy-electric-is-last-command-event-expandable-punct-p)
           (groovy-electric-code-at-point-p)
           (save-excursion
             (insert (cdr (assoc (*last-command-event*)
                                 groovy-electric-matching-delimeter-alist)))))
      #f)

    (define-command (groovy-electric-pound arg)
      "Insert `${}' when a $ is typed in a GString."
      (interactive "P")
      (self-insert-command (prefix-numeric-value arg) (*last-command-event*))
      (when (and (groovy-electric-is-last-command-event-expandable-punct-p)
                 (groovy-electric-gstring-at-point-p)
                 (not (save-excursion        ; make sure it is not escaped
                        (backward-char 1)
                        (char-equal (char->integer #\\) (preceding-char)))))
        (insert "{}")
        (backward-char 1))
      #f)

    (define-minor-mode groovy-electric-mode
      "Toggle Groovy Electric minor mode.
With no argument, this command toggles the mode.  Non-null prefix
argument turns on the mode.  Null prefix argument turns off the
mode.

When Groovy Electric mode is enabled, simple, double and back
quotes as well as braces are paired auto-magically. Expansion
does not occur inside comments and strings. Note that you must
have Font Lock enabled. ${ } is expanded when in a GString"
      :init-value #f
      :lighter " Ge"
      :keymap groovy-mode-map
      (groovy-electric-setup-keymap))

    ))
