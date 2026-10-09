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
    (scheme base)
    ;; `import' and `eval' are `(guile)''s - the `(scheme eval)' library
    ;; is not what evaluates an `import' form - and so is `resolve-module'.
    (only (guile) eval resolve-module))

  (export editor-libraries editor-excluded-libraries
          open-editor-namespace!)

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
      ;;   **The toolkit libraries are not `(schemacs editor ...)' at all
      ;;   any more** - `(schemacs ui gtk pgtk)' and `(schemacs ui ncurses
      ;;   term)' are under `schemacs/ui/', beside the front ends that
      ;;   bind them. This list used to name them so that a terminal
      ;;   editor's session would not drag guile-gi in, and the Gtk one
      ;;   would not drag guile-ncurses in; moving them out of
      ;;   `schemacs/editor/' is the same decision made where it cannot be
      ;;   forgotten - `loadup-tests.scm' walks *this* directory, so a
      ;;   library that is not in it cannot be handed out by accident.
      ;;   `schemacs/main.scm' says the same thing about the front ends
      ;;   ("a terminal editor has no business needing guile-gi, and a
      ;;   windowed one no business needing ncurses").
      '((schemacs editor loadup)))

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
        (schemacs editor engine)
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
        (schemacs editor intervals)
        (schemacs editor isearch)
        (schemacs editor keyboard)
        (schemacs editor keymap)
        (schemacs editor ls-lisp)
        (schemacs editor minibuf)
        (schemacs editor minibuffer)
        (schemacs editor mouse)
        (schemacs editor mule)
        (schemacs editor mule-cmds)
        (schemacs editor pages)
        (schemacs editor paragraphs)
        (schemacs editor region-cache)
        (schemacs editor replace)
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

    ))
