(define-library (schemacs editor novice)
  ;; This library mirrors GNU Emacs's `lisp/novice.el' - the
  ;; disabled-command prompt: the function that asks "Use this command?"
  ;; and the two commands that turn a command's disabled flag off or on.
  ;;
  ;; `disabled-command-function` is the value of the variable of the same
  ;; name, which `command.scm` reads in `run-command` (its
  ;; `command-execute`): the prompt here, or nil - "the feature is
  ;; disabled, i.e. all commands work normally". It is installed as this
  ;; library loads, and so is the `query' form's asker.
  ;;
  ;; **What is not carried, and what it waits for**: the init-file write
  ;; in `en/disable-command`. Emacs finds `user-init-file` - the tree has
  ;; one now, `startup.scm`'s - and edits the `(put 'CMD 'disabled X)`
  ;; line out of the user's file and appends a new one. This tree's init
  ;; file is Scheme: the same line would be `(put 'CMD 'disabled #t)`
  ;; *and* would need an `(import (schemacs editor intervals))` beside
  ;; it, and `find-file-noselect`/`save-buffer` do the rest. So the
  ;; session effect (the `put`) is carried and the file edit is named;
  ;; `y` at the prompt enables the command for this session, and the
  ;; user who wants it to last adds the two lines to their init file.

  (import
    (scheme base)
    (scheme char)
    (only (guile) format caddr)
    ;; `this-command` and `this-command-keys`: the command being run and
    ;; the keys it came from.
    (only (schemacs editor simple) *this-command*)
    (only (schemacs editor keyboard) *this-command-keys*)
    ;; the machine, and the prompt's substitution.
    (only (schemacs editor command)
          *disabled-command-function* *command-execute--query-function*
          *quit-flag* command-type? command-name command-record-named
          command-interactive-spec command-record-of %run-command define-command)
    (only (schemacs editor character) kbd)
    (only (schemacs editor intervals) get put)
    (only (schemacs editor help) substitute-command-keys)
    (only (schemacs editor keymap) key-description)
    (only (schemacs editor doc) documentation)
    (only (schemacs editor rmc) read-multiple-choice)
    (only (schemacs editor files) y-or-n-p)
    (only (schemacs editor minibuffer) yes-or-no-p)
    (only (schemacs editor frame) *current-frame*)
    (only (schemacs editor startup) *user-init-file*)
    ;; the help text's first paragraph
    (only (schemacs editor buffer)
          allocate-buffer *current-buffer* current-buffer)
    (only (schemacs editor editfns)
          buffer-string char-after delete-region goto-char insert
          point-min point-max)
    (only (schemacs editor search) search-forward match-beginning)
    (only (schemacs editor indent) indent-rigidly))

  (export disabled-command-function enable-command disable-command
          en/disable-command)

  (begin

    (define (%this-command-symbol)
      ;; Emacs's `this-command` is the command's *symbol*; this tree's
      ;; holds what the keymap was bound to - and a keymap's binding for
      ;; a `define-command' is the command's *procedure*, not the record
      ;; (`dispatch-action`'s whole point). The prompt wants the name,
      ;; so the record is found from either shape.
      ;;--------------------------------------------------------------
      (let ((c (*this-command*)))
        (cond ((symbol? c) c)
              ((command-type? c) (string->symbol (command-name c)))
              ((procedure? c)
               (let ((record (command-record-of c)))
                 (and record (string->symbol (command-name record)))))
              (else c))))

    (define (%command-execute--query cmd)
      ;; GNU Emacs's `command-execute--query' (`simple.el:2857'):
      ;; "Query the user whether to run COMMAND." The `disabled'
      ;; property is `(query VERBOSE QUERY)'; VERBOSE picks
      ;; `yes-or-no-p', as `command-query`'s docstring says.
      ;;--------------------------------------------------------------
      (let* ((name (if (command-type? cmd)
                       (string->symbol (command-name cmd))
                       cmd))
             (query (get name 'disabled))
             (verbose (and (pair? query) (pair? (cdr query)) (cadr query)))
             (prompt (and (pair? query) (pair? (cdr query))
                          (pair? (cddr query)) (caddr query))))
        (if verbose
            (yes-or-no-p (*current-frame*) prompt)
            (y-or-n-p prompt))))

    (define (disabled-command-function . rest)
      ;; GNU Emacs's `disabled-command-function' (`novice.el:45'): the
      ;; prompt for a command whose `disabled' property is plain t.
      ;;
      ;; The CMD and KEYS optional arguments are for a programmatic
      ;; caller; the dispatch calls it with none and it takes the
      ;; command being run and the keys it came from.
      ;;--------------------------------------------------------------
      (let* ((cmd (or (and (pair? rest) (car rest)) (%this-command-symbol)))
             (keys (or (and (pair? rest) (pair? (cdr rest)) (cadr rest))
                       (*this-command-keys*)))
             (disabled (get cmd 'disabled))
             (help-string
              (string-append
               (if (or (and (> (vector-length keys) 0)
                            (eqv? (vector-ref keys 0)
                                  (vector-ref (kbd "M-x") 0)))
                       (and (>= (vector-length keys) 2)
                            (eqv? (vector-ref keys 0) 27)
                            (eqv? (vector-ref keys 1) 120)))
                   (format #f "You have invoked the disabled command ~a.\n" cmd)
                   (substitute-command-keys
                    (format #f
                            "You have typed \\`~a', invoking disabled command ~a.\n"
                            (key-description keys) cmd)))
               ;; "Any special message saying why the command is
               ;; disabled."
               (if (string? disabled)
                   disabled
                   (string-append
                    "It is disabled because new users often find it confusing.\n"
                    (substitute-command-keys
                     "Here's the first part of its description:\n\n")
                    ;; "Keep only the first paragraph of the
                    ;; documentation."
                    (parameterize ((*current-buffer* (allocate-buffer)))
                      (insert (or (guard (e (#t #f)) (documentation cmd))
                                  "<< not documented >>"))
                      (goto-char (point-min))
                      (when (search-forward "\n\n" #f #t)
                        (delete-region (match-beginning 0) (point-max)))
                      (indent-rigidly (point-min) (point-max) 3)
                      (buffer-string))))
               (substitute-command-keys
                "
Do you want to use this command anyway?

You can now type:
 \\`n'    (also C-g) to cancel--don't try the command; it remains disabled.
 \\`y'    to enable the command (no questions if you use it again).
 \\`SPC'  to try the command just this once, but leave it disabled.
 \\`!'    to enable it and all the disabled commands for this session.")))
             (char (car (read-multiple-choice
                         "Use this command?"
                         (list (list #\n "no")
                               (list #\y "yes")
                               (list #\space "(space bar) only once")
                               (list #\! "use and enable all"))
                         help-string
                         "*Disabled Command*"))))
        (cond
         ((char=? char (integer->char 7))
          ;; `(setq quit-flag t)' - the next command-loop check quits.
          (*quit-flag* #t))
         ((char=? char #\!)
          (*disabled-command-function* #f))
         ((char=? char #\y)
          (if (and (*user-init-file*)
                   (not (string=? "" (*user-init-file*)))
                   (y-or-n-p "Enable command for future editing sessions also? "))
              (enable-command cmd)
              (put cmd 'disabled #f)))
         (else #f))
        ;; "Try the command just this once" and "enable" both run it; a
        ;; refusal does not. It goes through `%run-command`, Emacs's
        ;; `call-interactively`, which does not ask again.
        (unless (char=? char #\n)
          (let ((record (command-record-named cmd)))
            (when record
              (if (command-interactive-spec record)
                  (%run-command record (list #f))
                  (%run-command record '())))))
        #f))

    (define (en/disable-command command disable)
      ;; GNU Emacs's `en/disable-command' (`novice.el:113'): "Set
      ;; COMMAND's disabled property to DISABLE." The init-file half is
      ;; not carried - see the library header.
      ;;--------------------------------------------------------------
      (unless (command-record-named command)
        (error "Invalid command name" command))
      (put command 'disabled disable)
      #f)

    (define-command (enable-command command)
      ;; GNU Emacs's `enable-command' (`novice.el:160'): "Allow COMMAND
      ;; to be executed without special confirmation from now on."
      ;;--------------------------------------------------------------
      "Allow COMMAND to be executed without special confirmation from now on.
COMMAND must be a symbol.
This command alters the user's .emacs file so that this will apply
to future sessions."
      (interactive "CEnable command: ")
      (en/disable-command command #f))

    (define-command (disable-command command)
      ;; GNU Emacs's `disable-command' (`novice.el:169'): "Require
      ;; special confirmation to execute COMMAND from now on."
      ;;--------------------------------------------------------------
      "Require special confirmation to execute COMMAND from now on.
COMMAND must be a symbol.
This command alters your init file so that this choice applies to
future sessions."
      (interactive "CDisable command: ")
      (en/disable-command command #t))

    ;; The variable's value: "If nil, the feature is disabled, i.e. all
    ;; commands work normally." Installed here, where the function is -
    ;; a library's own function is installed after its definition.
    (*disabled-command-function* disabled-command-function)
    (*command-execute--query-function* %command-execute--query)))
