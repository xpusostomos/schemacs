(define-library (schemacs editor loadup)
  ;; GNU Emacs's `loadup.el' is the file that loads the editor: "load up
  ;; the standard Emacs" - simple.el, files.el, window.el and the rest -
  ;; before the first command runs. What this library holds is the same
  ;; fact said once: **the list of libraries the editor is made of**, and
  ;; the one thing anyone does with it, which is to give those names to a
  ;; module.
  ;;
  ;; **One thing wants that: the back door.** Its session is pinned to
  ;; `(guile-user)', which has none of the editor's names, and it answered
  ;; `Unbound variable: find-file' until it was given them
  ;; (`schemacs/repl.sld'). A user typing at that prompt can `import' what
  ;; it wants, and `tools/repl.py -m MODULE' does it for them; what this
  ;; saves is knowing *which* library holds a name while poking at a
  ;; running editor.
  ;;
  ;; **The init file is deliberately not a caller.** It imports what it
  ;; needs - `(import (schemacs editor startup))' for
  ;; `inhibit-startup-screen', which is `startup.el''s and so lives in
  ;; `startup.sld' - because a name belongs in the file its Emacs source
  ;; belongs to, and one bloated namespace in the user's module is not the
  ;; price of saving them a line. (`load-init' did call this for a while;
  ;; see AGENTS.md.)
  ;;
  ;; The list is written out rather than derived - the tree's root is not
  ;; a thing a running editor knows - so it can go stale, and
  ;; `loadup-tests.scm' is what notices: it walks `schemacs/editor/*.sld'
  ;; and fails on a library that is neither in the list nor in the
  ;; excluded pair.

  (import
 (only (schemacs editor buffer) allocate-buffer bufferp buffer-pt buffer-beg buffer-z text-editor-buffer-name set!text-editor-buffer-name text-editor-file-name set!text-editor-file-name buffer-modified-p set-buffer-modified-p buffer-read-only? set!buffer-read-only text-editor-text-props set!text-editor-text-props *inhibit-read-only* *buffer-visited-file-modtime-function* buffer-modified-tick buffer-chars-modified-tick text-editor-cache-long-scans set!text-editor-cache-long-scans show-text-editor text-editor-undo-list set!text-editor-undo-list)
 (only (schemacs editor undo) record-insert record-delete text-editor-undo-boundary! text-editor-undo-disable! text-editor-undo-enable! text-editor-undo-recording? *undo-limit* undo-insertion-entry? undo-deletion-entry? undo-modified-entry? *point-before-last-command-or-undo* *buffer-before-last-command-or-undo*)
 (only (schemacs editor insdel) *after-change-functions* signal-after-change *text-property-offset-function* invalidate-buffer-caches)
 (only (schemacs editor fns) count-lines)
    ;; `file-exists-p' is `fileio.c`'s, and is what finds the user's
    ;; `imports.scm' - the tree's own, so that a `~' in a path is
    ;; expanded the way every other file name in this editor is.
    (only (schemacs editor fileio) file-exists-p)
    (scheme base)
    ;; `call-with-input-file', for the user's file.
    (scheme file)
    ;; `import' and `eval' are `(guile)''s - the `(scheme eval)' library
    ;; is not what evaluates an `import' form - and so is `resolve-module'.
    ;; `getenv' is how `$XDG_CONFIG_HOME' is read (`(scheme base)' has
    ;; neither it nor `read').
    ;;
    ;; **`read' and not `load', for the user's `imports.scm'.** A
    ;; declarative module - which is what this Guile's `define-library'
    ;; makes - may not `load', and it says so ("Use of `load' in
    ;; declarative module"); reading the forms and evaluating each one in
    ;; the environment module does the same job here, and does it
    ;; directly: the file *is* a list of forms to evaluate in that module.
    (only (guile) eval getenv read resolve-module))

  (export editor-libraries editor-excluded-libraries
          imports-path open-editor-namespace! open-user-environment!)

  (begin
    ;;------------------------------------------------------------------
    ;; The editor's names
    ;;------------------------------------------------------------------

    ;; **The back door is a REPL into the editor, so the editor's names
    ;; have to be there.** GNU Emacs has one obarray: `find-file' is
    ;; reachable from anywhere, including from `eval', which is why a bad
    ;; expression typed into a running Emacs can still call every command
    ;; there is. This tree's names live in one library per Emacs file, and
    ;; a bare `(guile-user)' holds none of them - so the first thing
    ;; anybody typed at `se --repl' was
    ;;
    ;;     scheme@(guile-user)> (find-file "README.md")
    ;;     Unbound variable: find-file
    ;;
    ;; which reads as the back door being broken when it is working. The
    ;; nearest thing this tree has to Emacs's obarray is the set of the
    ;; editor's libraries, and the module the session is pinned to is
    ;; `(guile-user)' (`poll-repl!'), so the two are put together: the
    ;; session is *given* the editor.
    ;;
    ;; The list is written out rather than derived - the tree's root is
    ;; not a thing the running editor knows - so it can go stale, and
    ;; `repl-tests.scm' is what notices: it walks `schemacs/editor/*.sld'
    ;; and fails on a library that is neither here nor in the excluded
    ;; pair below.

    (define %excluded-libraries
      ;; The editor's libraries that are deliberately *not* in the list.
      ;; One now, and the other two left for a *structural* reason rather
      ;; than a note in here:
      ;;
      ;;   `(schemacs editor loadup)' is this list, which cannot sensibly
      ;;   be in itself: what it hands out is the editor, and it is the
      ;;   hand.
      ;;
      ;;   `(schemacs editor test-display)' is *test support*: a display
      ;;   with nothing behind it, which the suites use so that none of
      ;;   them has to import a front end. It is excluded for the same
      ;;   reason the toolkits are - the back door has no business handing
      ;;   a session a display that draws nowhere.
      ;;
      ;;   **The toolkit libraries are not `(schemacs editor ...)' at all
      ;;   any more**: they belong to whichever front end binds them, and
      ;;   they live beside it. This list used to name them so that a
      ;;   terminal editor's session would not drag guile-gi in, and the
      ;;   windowed one would not drag guile-ncurses in; moving them out
      ;;   of `schemacs/editor/' is the same decision made where it cannot
      ;;   be forgotten - `loadup-tests.scm' walks *this* directory, so a
      ;;   library that is not in it cannot be handed out by accident.
      ;;   `schemacs/main.scm' says the same thing about the front ends
      ;;   ("a terminal editor has no business needing guile-gi, and a
      ;;   windowed one no business needing ncurses").
      ;;   `(schemacs editor imports)' is the whole editor under one
      ;;   name, which is what the list above *is* - a second way to say
      ;;   it. It cannot be in the list in any case: it imports every
      ;;   library, and this one is one of them, so the list naming it
      ;;   would be a cycle.
      '((schemacs editor loadup)
        (schemacs editor imports)
        (schemacs editor test-display)))

    (define %editor-libraries
      ;; Every `(schemacs editor ...)' there is, less the pair above:
      ;; sorted, so a diff of this file shows the one library that moved.
      ;;--------------------------------------------------------------
      '((schemacs editor buff-menu)
        (schemacs editor buffer)
        (schemacs editor buffer-text)
        (schemacs editor casefiddle)
        (schemacs editor character)
        (schemacs editor characters)
        (schemacs editor charset)
        (schemacs editor cmds)
        (schemacs editor coding)
        (schemacs editor command)
        (schemacs editor data)
        (schemacs editor derived)
        (schemacs editor dired)
        (schemacs editor diredc)
        (schemacs editor disp-table)
        (schemacs editor dispnew)
        (schemacs editor easy-mmode)
        (schemacs editor editfns)
        
        (schemacs editor env)
        (schemacs editor faces)
        (schemacs editor fileio)
        (schemacs editor files)
        (schemacs editor fns)
        (schemacs editor font-core)
        (schemacs editor font-lock)
        (schemacs editor frame)
        (schemacs editor indent)
        (schemacs editor indentc)
        (schemacs editor insdel)
        (schemacs editor intervals)
        (schemacs editor isearch)
        (schemacs editor keyboard)
        (schemacs editor keymap)
        (schemacs editor ls-lisp)
        (schemacs editor marker)
        (schemacs editor minibuf)
        (schemacs editor minibuffer)
        (schemacs editor mouse)
        (schemacs editor mule)
        (schemacs editor mule-cmds)
        (schemacs editor pages)
        (schemacs editor paragraphs)
        (schemacs editor region-cache)
        (schemacs editor replace)
        (schemacs editor rmc)
        (schemacs editor search)
        (schemacs editor select)
        (schemacs editor simple)
        (schemacs editor startup)
        (schemacs editor subr)
        (schemacs editor syntax)
        (schemacs editor tabulated-list)
        (schemacs editor textprop)
        (schemacs editor timefns)
        (schemacs editor timer)
        (schemacs editor tty-colors)
        (schemacs editor undo)
        (schemacs editor window)
        (schemacs editor xdisp)
        (schemacs editor xfaces)))

    (define (editor-libraries)
      ;; What the back door's session is given, and - with
      ;; `back-door-excluded-libraries' - everything the editor is made
      ;; of, the two together being the whole of `schemacs/editor'. The
      ;; test that keeps them honest (`repl-tests.scm') reads both and the
      ;; directory.
      ;;--------------------------------------------------------------
      %editor-libraries)

    (define (editor-excluded-libraries)
      ;; The pair above, exported so that "the two lists are the whole
      ;; editor" can be *checked* rather than hoped for.
      ;;--------------------------------------------------------------
      %excluded-libraries)

    (define open-editor-namespace!
      ;; Give MODULE - `(guile-user)' when none is named, which is what
      ;; the session is pinned to, and what `load-init' loads the init
      ;; file into - the editor's names. One `import' form, evaluated
      ;; there, which is what typing it at the prompt does.
      ;;
      ;; **Two traps, both found by compiling this file and neither
      ;; visible to `tools/syntax-check.scm'**, which runs the *reader* -
      ;; and both files read perfectly.
      ;;
      ;; `(scheme base)' has to be imported explicitly. This Guile's
      ;; `define-library' does not give a library R7RS's implicit
      ;; `(scheme base)', so without it `define' is not a macro there and
      ;; the compiler's complaint is not about the import at all: it said
      ;; "source expression failed to match any pattern in form
      ;; (open-editor-namespace! . module)" and sent me hunting a dotted
      ;; procedure header, which is *legal* (measured: `(define (f . a)
      ;; a)' in a library that does import `(scheme base)' compiles).
      ;;
      ;; `(case-lambda (() ...) ...)' is rejected by the compiler in a
      ;; library - "unexpected syntax in form ()" - while the interpreter
      ;; accepts it. Hence `(lambda module ...)': the one shape that is
      ;; both variadic and compilable, with MODULE the list of arguments.
      ;;
      ;; **No guard.** A library that will not load is a broken list, and
      ;; a session that quietly has no `find-file' - or an init file whose
      ;; `(set! inhibit-startup-screen #t)' is an unbound variable - is
      ;; the bug this exists to fix; better a backtrace at startup than
      ;; something that looks fine and is not.
      ;;--------------------------------------------------------------
      (lambda module
        (eval (cons 'import %editor-libraries)
              (if (pair? module) (car module)
                  (resolve-module '(guile-user))))))

    ;;------------------------------------------------------------------
    ;; The user's environment - `imports.scm'
    ;;------------------------------------------------------------------
    ;;
    ;; Three things evaluate code that the editor did not write, and
    ;; therefore have no `import' form to write for them:
    ;;
    ;;   * `M-:' - an expression typed at a prompt (`eval-expression');
    ;;   * the REPL back door - the same, line by line;
    ;;   * the user's `init.scm' - a *file* of the user's, loaded whole.
    ;;
    ;; In GNU Emacs all three reach every name there is, because Emacs has
    ;; **one obarray**: `find-file' is bound in it, so a typed expression,
    ;; a REPL line and an init file all find it with no `require'. This
    ;; tree's names live one library per Emacs file and a module holds
    ;; none of them until it imports them, so the three need somewhere to
    ;; look - and this is that place.
    ;;
    ;; **It is one place, deliberately.** Before it, the three got three
    ;; different answers: the back door was given every editor library
    ;; (`open-editor-namespace!'), `M-:' evaluated in `(current-module)'
    ;; - which is the editor's module only by luck, and is the *command's*
    ;; module while a prompt is up, so `M-:' failed inside `find-file`'s
    ;; minibuffer read and not outside it - and an init file got whatever
    ;; it imported for itself. Now all three read the same module.
    ;;
    ;; **And the user says what is in it.** `$XDG_CONFIG_HOME/imports.scm`
    ;; is a plain Scheme file - "just a list of imports" - evaluated in
    ;; that module; the conventional first line names the whole editor:
    ;;
    ;;     (import (schemacs editor imports))     ; the whole editor
    ;;     (import (my-utils))                    ; and whatever else
    ;;
    ;; With no such file the environment is that first line alone, which
    ;; is GNU Emacs's starting position: every editor name and nothing
    ;; else. **A file replaces the default rather than adding to it**,
    ;; which is what "full control over what is imported into his default
    ;; environment" means (Chris, 2026-10-13) - and it is why the file has
    ;; to say `(schemacs editor imports)' itself if it wants the editor.
    ;;
    ;; **The editor's own libraries never use this.** They import what
    ;; they use, one `(only ...)` list each, which is the rule that keeps
    ;; a name in the library that mirrors its Emacs file. This is the
    ;; stand-in for the obarray in the three places where there is no
    ;; library to write an import in, and nowhere else.

    (define (first-existing paths)
      ;; The first of PATHS that names a file that is there, or #f.
      ;; `init-path' in `startup.scm' is the same walk over the init
      ;; file's locations; this one is here rather than there because the
      ;; environment is built here and `startup.scm' is above this
      ;; library.
      ;;--------------------------------------------------------------
      (cond ((null? paths) #f)
            ((not (car paths)) (first-existing (cdr paths)))
            ((file-exists-p (car paths)) (car paths))
            (else (first-existing (cdr paths)))))

    (define (imports-path)
      ;; Where the user's `imports.scm' is, or #f when there is none.
      ;;
      ;; **`$XDG_CONFIG_HOME/imports.scm' first, because that is where
      ;; Chris said it goes** - and its `schemacs' subdirectory second,
      ;; which is where this tree's `init.scm' has always been looked for,
      ;; so a user who keeps the two together finds them both.
      ;;--------------------------------------------------------------
      (let ((xdg (getenv "XDG_CONFIG_HOME"))
            (home (getenv "HOME")))
        (if xdg
            (first-existing (list (string-append xdg "/imports.scm")
                                  (string-append xdg "/schemacs/imports.scm")))
            (first-existing (list (and home
                                       (string-append home "/.config/schemacs/imports.scm")))))))

    (define %default-user-imports '(import (schemacs editor imports)))
    ;; ^ What the environment is when the user has said nothing: the whole
    ;; editor, by the one name that stands for it. It is the same line a
    ;; user's `imports.scm' writes, which is the point - there is one way
    ;; to say "all of it", and the default uses it too.

    (define (open-user-environment! . module)
      ;; Give MODULE - `(guile-user)' when none is named, which is where
      ;; the command loop runs and what the back door's session is pinned
      ;; to - the names its code is evaluated against: the user's
      ;; `imports.scm' when there is one, and the whole editor when there
      ;; is not.
      ;;
      ;; Repeat calls are cheap and harmless: an `import' evaluated twice
      ;; is the same import, and the user's file is only read when it is
      ;; there. The front ends call it once, from the boot in
      ;; `startup.scm' - which is Emacs's `normal-top-level', the place
      ;; the obarray is complete before anything is read from the user.
      ;;--------------------------------------------------------------
      (let ((m (if (pair? module) (car module) (resolve-module '(guile-user)))))
        (let ((file (imports-path)))
          (if file
              ;; **Each form in MODULE and not this library's**, so the
              ;; `import' forms land where their reader expects them -
              ;; exactly as `load-init' loads an init file into the
              ;; user's module, and for the same reason.
              (call-with-input-file file
                (lambda (port)
                  (let loop ()
                    (let ((form (read port)))
                      (unless (eof-object? form)
                        (eval form m)
                        (loop))))))
              (eval %default-user-imports m)))
        m))

    ))
