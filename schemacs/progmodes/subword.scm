(define-library (schemacs progmodes subword)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/subword.el' -
  ;; whole, and this one file is both packages: since Emacs 29
  ;; `superword.el' was merged into it, so `superword-mode' lives here
  ;; beside `subword-mode' and shares its keymap (`:258'). There is no
  ;; `cc-subword.el' in Emacs 31 either - `c-subword-mode' is this
  ;; file's obsolete alias (`:119') and `cc-cmds.el`'s fallback
  ;; (`cc-cmds.el:1551').
  ;;
  ;; **How the mode works, and what it rests on here.** The mode does
  ;; not remap the motion commands: it installs a
  ;; `find-word-boundary-function-table' in the buffer
  ;; (`subword-setup-buffer', `:333'), and `forward-word' - the C's
  ;; `scan_words' (`syntax.c:1494') - consults it at each word's first
  ;; character. `syntax.scm' ports that consultation; what this
  ;; library adds is that the variable is read *buffer-locally* there -
  ;; `setq-local' is this tree's buffer slot - and that
  ;; `forward-word-strictly' binds the same slot around its scan, as
  ;; Emacs's `let' of a buffer-local variable shadows it.
  ;;
  ;; **Not carried, each named**: the
  ;; `define-obsolete-variable-alias' half of `cc-cmds.el`'s fallback
  ;; (`c-subword-mode` is aliased as a function; this tree has no
  ;; variable alias), and `subword-forward-function`/
  ;; `subword-backward-function` hold *procedures* here where Emacs
  ;; holds symbols (`'subword-forward-internal'), because a Lisp-1 has
  ;; no symbol-to-function indirection - a user who sets one must set
  ;; a procedure.
  (import
    (scheme base)
    (only (guile) format)
    (prefix (schemacs keymap) km:)
    (only (schemacs core easy-mmode)
          define-minor-mode define-globalized-minor-mode)
    (only (schemacs core byte-run) define-obsolete-function-alias)
    (only (schemacs core syntax-macros) dotimes)
    (only (schemacs command)
          define-command
          ;; `define-minor-mode`'s generated interactive form is
          ;; `eval`ed in *this* library's module, so these two names
          ;; have to be here (the macro's note says so).
          current-prefix-arg uarg->integer)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          call-with-buffer-local
          ;; `case-fold-search` is `buffer.c:6009`'s variable, which the
          ;; searches' engine consults.
          *case-fold-search*)
    (only (schemacs chartab) make-char-table set-char-table-range)
    (only (schemacs editfns)
          goto-char point point-min point-max
          save-excursion save-restriction narrow-to-region)
    (only (schemacs search)
          re-search-forward re-search-backward
          match-beginning match-end search-failed? save-match-data)
    (only (schemacs syntax) forward-word)
    (only (schemacs subr) forward-symbol)
    (only (schemacs simple)
          backward-word kill-region %transpose-subr
          mark set-mark push-mark
          upcase-region downcase-region
          *last-command* *this-command*)
    ;; `current-bidi-paragraph-direction` is `xdisp.c`'s, and this is
    ;; this tree's first `progmodes` library to reach the renderer -
    ;; for the four-line reader `subword-right`/`subword-left` compare
    ;; against. `simple.scm`'s `right-char` went the other way with the
    ;; fact written down (it does not call it, since every paragraph
    ;; here is left-to-right); a mode that *asks* gets the real
    ;; function.
    (only (schemacs xdisp) current-bidi-paragraph-direction))

  (export subword-mode superword-mode
          global-subword-mode global-superword-mode
          subword-mode-map superword-mode-map
          subword-mode-hook superword-mode-hook
          subword-mode-variable set!subword-mode-variable!
          superword-mode-variable set!superword-mode-variable!
          subword-forward subword-backward subword-right subword-left
          subword-mark subword-kill subword-backward-kill
          subword-transpose subword-downcase subword-upcase
          subword-capitalize
          c-subword-mode capitalized-words-mode
          subword-forward-function subword-backward-function
          subword-forward-regexp subword-backward-regexp
          subword-forward-internal subword-backward-internal
          subword-setup-buffer subword-find-word-boundary
          subword-find-word-boundary-function-table
          subword-empty-char-table)

  (begin

    (define subword-forward-function #f)
    ;; ^ `subword.el:68': "Function to call for forward subword
    ;; movement." Emacs's value is the *symbol* `'subword-forward-internal'
    ;; because `funcall` resolves a symbol through the obarray; this
    ;; tree has no such indirection, so it holds the procedure.
    ;;
    ;; **`#f` here and the procedure assigned after its definition** -
    ;; the `normal-auto-fill-function` shape: a top-level `define` whose
    ;; init names a procedure defined below it is a forward reference,
    ;; and the interpreter raises "Unbound variable" at load where the
    ;; compiler resolves it. The `set!` also marks the variable mutable
    ;; against the compiler's constant folding.
    ;;--------------------------------------------------------------

    (define subword-backward-function #f)
    ;; ^ `subword.el:71', the same for the backward direction.
    ;;--------------------------------------------------------------

    (define subword-forward-regexp
      "\\W*\\(\\([[:upper:]]*\\(\\W\\)?\\)[[:lower:][:digit:]]*\\)")
    ;; ^ `subword.el:74': "Regexp used by `subword-forward-internal'."
    (set! subword-forward-regexp subword-forward-regexp)

    (define subword-backward-regexp
      "\\(\\(\\W\\|[[:lower:][:digit:]]\\)\\([[:upper:]]+\\W*\\)\\|\\W\\w+\\)")
    ;; ^ `subword.el:78'.
    (set! subword-backward-regexp subword-backward-regexp)

    (define subword-mode-map
      ;; GNU Emacs's `defvar-keymap subword-mode-map` (`subword.el:82`):
      ;; "We originally remapped motion keys here, but now use Emacs
      ;; core hooks. Leave this keymap around so that user additions to
      ;; it keep working." It is empty on purpose.
      ;;
      ;; **Named, because `define-minor-mode` finds it by name**: the
      ;; macro looks for a `MODE-map` binding in the defining module
      ;; when no `:keymap` is given (`easy-mmode.el:160`), which is how
      ;; user additions to it take effect.
      ;;--------------------------------------------------------------
      (km:keymap '*subword-mode-map*))

    (define (subword-mode-variable)
      ;; The buffer's value of Emacs's `subword-mode` variable - which
      ;; is a `DEFVAR_PER_BUFFER`-style slot here, keyed by the mode's
      ;; own symbol, as every `define-minor-mode` variable is.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'subword-mode #f))

    (define (set!subword-mode-variable! value)
      (set-buffer-local-value! (current-buffer) 'subword-mode value))

    (define-minor-mode subword-mode
      "Toggle subword movement and editing (Subword mode).

Subword mode is a buffer-local minor mode.  Enabling it changes
the definition of a word so that word-based commands stop inside
symbols with mixed uppercase and lowercase letters,
e.g. \"GtkWidget\", \"EmacsFrameClass\", \"NSGraphicsContext\".

Here we call these mixed case symbols `nomenclatures'.  Each
capitalized (or completely uppercase) part of a nomenclature is
called a `subword'.  Here are some examples:

  Nomenclature           Subwords
  ===========================================================
  GtkWindow          =>  \"Gtk\" and \"Window\"
  EmacsFrameClass    =>  \"Emacs\", \"Frame\" and \"Class\"
  NSGraphicsContext  =>  \"NS\", \"Graphics\" and \"Context\"

This mode changes the definition of a word so that word commands
treat nomenclature boundaries as word boundaries."
      :lighter " ,"
      :variable (lambda () (subword-mode-variable))
                (lambda (v) (set!subword-mode-variable! v))
      ;; `(when subword-mode (superword-mode -1))` - the two modes are
      ;; alternatives, as `subword.el:114' has it.
      (when (subword-mode-variable) (superword-mode -1))
      (subword-setup-buffer))

    ;; `subword.el:89`'s alias comes first in the file, before the mode
    ;; it names; `define-alias` *evaluates* its target, so here it has
    ;; to follow the definition - an order departure forced by the
    ;; macro, not a change in what it means.
    (define-obsolete-function-alias capitalized-words-mode
      subword-mode "25.1")

    (define-obsolete-function-alias c-subword-mode subword-mode "23.2")
    ;; ^ `subword.el:119'. `cc-cmds.el:1555' defines the same alias
    ;; when subword has not been loaded yet; here this file is the one
    ;; that loads it, so the value is this line's - Emacs 31.1's end
    ;; state once the mode has been used, measured: `(subword-mode nil
    ;; "23.2")'.

    (define-globalized-minor-mode global-subword-mode subword-mode
      (lambda () (subword-mode 1))
      :group 'convenience)
    ;; ^ `subword.el:122'.

    ;;------------------------------------------------------------------
    ;; "N.B. These commands aren't used unless explicitly invoked;
    ;; they're here for compatibility." (`subword.el:126')
    ;;------------------------------------------------------------------

    (define-command (subword-forward . rest)
      ;; GNU Emacs's `subword-forward' (`subword.el:133'): "Do the same
      ;; as `forward-word' but on subwords." ARG is optional in Emacs
      ;; (`&optional arg' with `(unless arg (setq arg 1))'), which the
      ;; tree spells as a rest parameter.
      "Do the same as `forward-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `forward-word'."
      (interactive "^p")
      (let ((arg (or (and (pair? rest) (car rest)) 1)))
        (cond
         ((< 0 arg)
          (dotimes (_i arg (point))
            (subword-forward-function)))
         ((> 0 arg)
          (dotimes (_i (- arg) (point))
            (subword-backward-function)))
         (else (point)))))

    (define-command (subword-backward . rest)
      ;; GNU Emacs's `subword-backward' (`subword.el:149').
      "Do the same as `backward-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `backward-word'."
      (interactive "^p")
      (subword-forward (- (or (and (pair? rest) (car rest)) 1))))

    (define-command (subword-right . rest)
      ;; GNU Emacs's `subword-right' (`subword.el:156'): "Do the same
      ;; as `right-word' but on subwords." With no bidi here every
      ;; paragraph is left-to-right, which is what
      ;; `current-bidi-paragraph-direction' answers.
      "Do the same as `right-word' but on subwords."
      (interactive "^p")
      (let ((arg (and (pair? rest) (car rest))))
        (if (eq? (current-bidi-paragraph-direction) 'left-to-right)
            (subword-forward arg)
            (subword-backward arg))))

    (define-command (subword-left . rest)
      ;; GNU Emacs's `subword-left' (`subword.el:163').
      "Do the same as `left-word' but on subwords."
      (interactive "^p")
      (let ((arg (and (pair? rest) (car rest))))
        (if (eq? (current-bidi-paragraph-direction) 'left-to-right)
            (subword-backward arg)
            (subword-forward arg))))

    (define-command (subword-mark arg)
      ;; GNU Emacs's `subword-mark' (`subword.el:170'): "This code is
      ;; almost copied from `mark-word' in GNU Emacs."
      "Do the same as `mark-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `mark-word'."
      (interactive "p")
      (cond ((and (eq? (*last-command*) (*this-command*)) (mark #t))
             (set-mark
              (save-excursion
                (goto-char (mark #t))
                (subword-forward arg)
                (point))))
            (else
             (push-mark
              (save-excursion
                (subword-forward arg)
                (point))
              #f #t)))
      #f)

    (define-command (subword-kill arg)
      ;; GNU Emacs's `subword-kill' (`subword.el:189').
      "Do the same as `kill-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `kill-word'."
      (interactive "p")
      (kill-region (point) (subword-forward arg)))

    (define-command (subword-backward-kill arg)
      ;; GNU Emacs's `subword-backward-kill' (`subword.el:196').
      "Do the same as `backward-kill-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `backward-kill-word'."
      (interactive "p")
      (subword-kill (- arg)))

    (define-command (subword-transpose arg)
      ;; GNU Emacs's `subword-transpose' (`subword.el:203'). MOVER is
      ;; a procedure here where Emacs passes the symbol
      ;; `'subword-forward' - `transpose-subr`'s first argument.
      "Do the same as `transpose-words' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `transpose-words'."
      (interactive "*p")
      (%transpose-subr subword-forward arg))

    (define-command (subword-downcase arg)
      ;; GNU Emacs's `subword-downcase' (`subword.el:210').
      "Do the same as `downcase-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `downcase-word'."
      (interactive "p")
      (let ((start (point)))
        (downcase-region (point) (subword-forward arg))
        (when (< arg 0)
          (goto-char start)))
      #f)

    (define-command (subword-upcase arg)
      ;; GNU Emacs's `subword-upcase' (`subword.el:220').
      "Do the same as `upcase-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `upcase-word'."
      (interactive "p")
      (let ((start (point)))
        (upcase-region (point) (subword-forward arg))
        (when (< arg 0)
          (goto-char start)))
      #f)

    (define-command (subword-capitalize arg)
      ;; GNU Emacs's `subword-capitalize' (`subword.el:230'). The
      ;; `condition-case' is `search-failed`'s - a failed
      ;; `re-search-forward' answers nil and nothing else is caught,
      ;; which is why `search.scm` carries that condition type.
      "Do the same as `capitalize-word' but on subwords.
See the command `subword-mode' for a description of subwords.
Optional argument ARG is the same as for `capitalize-word'."
      (interactive "p")
      (guard (e ((search-failed? e) #f))
        (let ((count (abs arg))
              (start (point))
              (advance (>= arg 0)))
          (dotimes (_i count)
            (if advance
                (begin
                  (re-search-forward "[[:alpha:]]")
                  (goto-char (match-beginning 0)))
                (subword-backward #f))
            (let* ((p (point))
                   (pp (+ p 1))
                   (np (subword-forward #f)))
              (upcase-region p pp)
              (downcase-region pp np)
              (goto-char (if advance np p))))
          (unless advance
            (goto-char start))
          #f)))

    ;;------------------------------------------------------------------
    ;; Internal functions (`subword.el:280')
    ;;------------------------------------------------------------------

    (define superword-mode-map subword-mode-map)
    ;; ^ `subword.el:258': "Keymap used in `superword-mode' minor
    ;; mode." The same object as `subword-mode-map`, which is Emacs's
    ;; `(defvar superword-mode-map subword-mode-map)`.

    (define (superword-mode-variable)
      ;; The buffer's value of Emacs's `superword-mode` variable.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'superword-mode #f))

    (define (set!superword-mode-variable! value)
      (set-buffer-local-value! (current-buffer) 'superword-mode value))

    (define-minor-mode superword-mode
      "Toggle superword movement and editing (Superword mode).

Superword mode is a buffer-local minor mode.  Enabling it changes
the definition of words such that characters which have symbol
syntax are treated as parts of words: e.g., in `superword-mode',
\"this_is_a_symbol\" counts as one word.

\\{superword-mode-map}"
      :lighter " ²"
      :variable (lambda () (superword-mode-variable))
                (lambda (v) (set!superword-mode-variable! v))
      (when (superword-mode-variable) (subword-mode -1))
      (subword-setup-buffer))

    (define-globalized-minor-mode global-superword-mode superword-mode
      (lambda () (superword-mode 1))
      :group 'convenience)
    ;; ^ `subword.el:276'.

    (define (subword-forward-internal)
      ;; GNU Emacs's `subword-forward-internal' (`subword.el:284').
      ;;
      ;; `superword-mode` is the buffer's variable; `(forward-symbol
      ;; 1)` is `subr.scm`'s. The `match-end`/`match-beginning` reads
      ;; are taken *after* the `save-excursion` for the reason the
      ;; Lisp does: match data is not part of the excursion.
      ;;--------------------------------------------------------------
      (if (superword-mode-variable)
          (forward-symbol 1)
          (if (and (save-excursion
                     (parameterize ((*case-fold-search* #f))
                       (re-search-forward subword-forward-regexp #f #t)))
                   (> (match-end 0) (point)))
              (goto-char
               (cond
                ((and (< 1 (- (match-end 2) (match-beginning 2)))
                      ;; "If we have an all-caps word with no following
                      ;; lower-case or non-word letter, don't leave the
                      ;; last char (bug#13758)."
                      (not (and (not (match-beginning 3))
                                (= (match-end 2) (match-end 1)))))
                 (- (match-end 2) 1))
                (else (match-end 0))))
              (forward-word 1))))

    (define (subword-backward-internal)
      ;; GNU Emacs's `subword-backward-internal' (`subword.el:304').
      ;;--------------------------------------------------------------
      (if (superword-mode-variable)
          (forward-symbol -1)
          (if (save-excursion
                (parameterize ((*case-fold-search* #f))
                  (re-search-backward subword-backward-regexp #f #t)))
              (goto-char
               (cond
                ((and (match-end 3)
                      (< 1 (- (match-end 3) (match-beginning 3)))
                      (not (= (point) (match-end 3))))
                 (- (match-end 3) 1))
                (else (+ (match-beginning 0) 1))))
              (backward-word 1))))

    (set! subword-forward-function subword-forward-internal)
    (set! subword-backward-function subword-backward-internal)
    ;; ^ The two values `subword.el:68`/`:71` declare with their
    ;; definitions in hand; see the note where they are made.

    (define (subword-setup-buffer)
      ;; GNU Emacs's `subword-setup-buffer' (`subword.el:333'): the
      ;; `setq-local' is this tree's buffer slot, which is what
      ;; `syntax.scm`'s word scan consults before the parameter.
      ;;--------------------------------------------------------------
      (set-buffer-local-value!
       (current-buffer)
       'find-word-boundary-function-table
       (if (or (subword-mode-variable) (superword-mode-variable))
           subword-find-word-boundary-function-table
           subword-empty-char-table)))

    (define (subword-find-word-boundary pos limit)
      ;; GNU Emacs's `subword-find-word-boundary' (`subword.el:339'):
      ;; "Catch-all handler in
      ;; `subword-find-word-boundary-function-table'."
      ;;
      ;; `(let ((find-word-boundary-function-table
      ;; subword-empty-char-table)) ...)` is Elisp's dynamic binding of
      ;; a buffer-local variable, so it is `call-with-buffer-local`
      ;; here - a `parameterize` would not shadow the slot this very
      ;; function exists to be found through.
      ;;--------------------------------------------------------------
      (call-with-buffer-local
       'find-word-boundary-function-table subword-empty-char-table
       (lambda ()
         (save-match-data
          (save-excursion
           (save-restriction
            (if (< pos limit)
                (begin
                  (goto-char pos)
                  (narrow-to-region (point-min) limit)
                  (subword-forward-function))
                (begin
                  (goto-char (+ pos 1))
                  (narrow-to-region limit (point-max))
                  (subword-backward-function)))
            (point)))))))

    ;; The two tables `subword.el:320`/`:328` declare *above*
    ;; `subword-setup-buffer`; the first names
    ;; `subword-find-word-boundary`, and here a `set-char-table-range`
    ;; with `#'subword-find-word-boundary` in it would be a forward
    ;; reference at load - Emacs quotes the symbol, this tree holds the
    ;; procedure. They follow the definitions they name.
    (define subword-find-word-boundary-function-table
      ;; "Assigned to `find-word-boundary-function-table' in
      ;; `subword-mode' and `superword-mode'; defers to
      ;; `subword-find-word-boundary'."
      ;;--------------------------------------------------------------
      (let ((tab (make-char-table #f)))
        (set-char-table-range tab #t subword-find-word-boundary)
        tab))

    (define subword-empty-char-table
      ;; "Assigned to `find-word-boundary-function-table' while we're
      ;; searching subwords in order to avoid unwanted reentrancy."
      ;;--------------------------------------------------------------
      (make-char-table #f))

    ))
