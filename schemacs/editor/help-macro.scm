(define-library (schemacs editor help-macro)
  ;; This library mirrors GNU Emacs's `lisp/help-macro.el`: the macro
  ;; `make-help-screen', which constructs single-character dispatching
  ;; with browsable help such as `help-for-help' provides.
  ;;
  ;; **What is here and what is not.** The variables and the macro are
  ;; `help-macro.el`'s, and so is the screen itself - `help--help-screen`
  ;; - except that the screen lives in `(schemacs editor help)`: it calls
  ;; `substitute-command-keys` and `help--key-description-fontified`,
  ;; which are `help.el`'s, and a static import graph cannot have this
  ;; library below `help.scm` while `help.scm` imports this library's
  ;; macro. The macro reaches the screen through
  ;; `*help--help-screen-function*`, which `help.scm` installs as it
  ;; loads - Emacs gets the same indirection from its one obarray at run
  ;; time, where `help--help-screen` is simply there.
  ;;
  ;; **Not carried**, each named where the screen uses it:
  ;; `variable-pitch-mode` (the `help-for-help-use-variable-pitch` branch;
  ;; the option is carried so a user setting it sees no error),
  ;; `iconify-frame`, `handle-switch-frame`,
  ;; `frame-toggle-on-screen-keyboard`, `vertical-scroll-bar` (neither
  ;; front end has scroll bars) and `ding`.

  (import
    (scheme base)
    ;; `datum->syntax`, `syntax-case` and the quasisyntax identifiers the
    ;; macro is written with: `(scheme base)` has none of them - the same
    ;; import `easy-mmode.scm` makes for the same reason.
    (only (guile) datum->syntax quasisyntax syntax syntax->datum syntax-case unsyntax)
    (only (schemacs editor command) define-command)
    (only (schemacs editor custom) define-custom))

  (export *three-step-help* *help-for-help-use-variable-pitch*
          *help--help-screen-function* make-help-screen)

  (begin

    (define-custom *three-step-help* #f
      "Non-nil means give more info about Help command in three steps.
The three steps are simple prompt, prompt with all options, and
window listing and describing the options.
A value of nil means skip the middle step, so that \\[help-command] \\[help-command]
gives the window that lists the options."
      :type 'boolean
      :group 'help)
    ;; ^ `help-macro.el:72' - a defcustom, and default nil: a bare
    ;; `C-h C-h' goes straight to the window.

    (define-custom *help-for-help-use-variable-pitch* #t
      "If non-nil, `help-for-help' should use `variable-pitch-mode'."
      :type 'boolean
      :group 'help)
    ;; ^ `help-macro.el:81'. **The option is carried and the branch is
    ;; not**: `variable-pitch-mode` is a face-remap mode this tree has
    ;; not ported, so `help--help-screen` skips it.

    (define *help--help-screen-function* (make-parameter #f))
    ;; ^ How the macro calls `help--help-screen`. It is `help.el`'s in
    ;; Emacs; here the function cannot live in this library (see the
    ;; header), so `(schemacs editor help)` defines it and installs it
    ;; here at load, as `help-mode.scm` installs `*help-mode-function*`.

    (define-syntax make-help-screen
      ;; "Construct help-menu function name FNAME. When invoked, FNAME
      ;; shows HELP-LINE and reads a command using HELPED-MAP. If the
      ;; command is the help character, FNAME displays HELP-TEXT and
      ;; continues trying to read a command using HELPED-MAP. When FNAME
      ;; finally does get a command, it executes that command and then
      ;; returns." (`help-macro.el:87')
      ;;
      ;; The Elisp is `(defun ,fname () ... (help--help-screen ...))`,
      ;; and the expansion is the same shape with this tree's
      ;; `define-command`. **The `interactive` form is built with the
      ;; caller's context**: it is a `syntax-rules` literal of
      ;; `define-command` and not a binding anywhere, so one written into
      ;; a template here would resolve in this library, where it is
      ;; unbound, and psyntax would refuse the expansion - the same trap
      ;; `define-minor-mode` documents.
      (lambda (stx)
        (syntax-case stx ()
          ((_ fname help-line help-text helped-map)
           ;; **Splicing a pattern variable into a template is refused by
           ;; this Guile's quasisyntax** - "reference to pattern variable
           ;; outside syntax form" - so the name is first turned into a
           ;; syntax *object* (with the call site's context) and that
           ;; value is what the template splices, as `define-minor-mode`
           ;; splices its `mode-id`. The `interactive` form is built the
           ;; same way and for the same reason.
           (let* ((name-id (datum->syntax (syntax fname)
                                          (syntax->datum (syntax fname))))
                  (interactive-form (datum->syntax name-id
                                                   (list 'interactive))))
             #`(define-command (#,name-id)
                 "Help command."
                 #,interactive-form
                 ((*help--help-screen-function*)
                  help-line help-text helped-map #f))))
          ((_ fname help-line help-text helped-map buffer-name)
           (let* ((name-id (datum->syntax (syntax fname)
                                          (syntax->datum (syntax fname))))
                  (interactive-form (datum->syntax name-id
                                                   (list 'interactive))))
             #`(define-command (#,name-id)
                 "Help command."
                 #,interactive-form
                 ((*help--help-screen-function*)
                  help-line help-text helped-map buffer-name)))))))

    ))
