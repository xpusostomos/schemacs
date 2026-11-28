(define-library (schemacs startup)
  ;; This library mirrors GNU Emacs's `startup.el`: what the editor does
  ;; between being started and handing control to the command loop - the
  ;; files named on the command line, and the windows they are shown in.
  ;;
  ;; What `startup.el' is mostly about is not here. Its bulk is the
  ;; option table (`--eval', `-L', `-Q', the long-option abbreviations),
  ;; the `*scratch*' buffer's banner, the splash screen with its logo and
  ;; its `about-emacs' links, and the dumping and site-file machinery.
  ;; This is the part a command line of file names goes through:
  ;; `command-line-1''s `process-file-arg', which visits each file, and
  ;; the `let' at the end of `command-line-1' that decides which windows
  ;; to put them in.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  ;; Guile warns here that `load' is used "in declarative module
  ;; (schemacs startup)" and suggests "Add #:declarative? #f to
  ;; your define-module invocation". There is no `define-module' to add
  ;; it to - this is a `define-library', whose expansion takes only R7RS
  ;; declarations, and an extra clause is not even rejected: measured, it
  ;; becomes a body expression, evaluates and is forgotten, so the
  ;; warning comes back. **The declaration is made at the top of the body
  ;; instead**, where its own comment explains why it has to be a macro
  ;; and why leaving the module declarative is not an option.

  (import
    (scheme base)
    ;; the init file's error report is *said*, so `display' is needed here
    ;; (`newline' is `(scheme base)''s) - and without it the handler that
    ;; catches a bad init file is itself an error, which is a worse failure
    ;; than the one it reports
    (only (scheme write) display)
    ;; `load' is Guile's own, and is what the init file is read with - the
    ;; same call the shell in `../guile-scsh/editor/init.scm' makes.
    ;; `%load-path' is where the splash screen's text is looked for.
    ;; `set-module-declarative?!' and `datum->syntax' are for the
    ;; declaration at the top of the body, not for the init file.
    (only (guile) %load-path catch current-module datum->syntax format
          getenv load resolve-module set-current-module
          set-module-declarative?!)
    ;; `exception-message' and `-irritants' are `ice-9 exceptions''s -
    ;; the two reads `%condition-text' makes of a raised condition.
    (only (ice-9 exceptions) exception-message exception-irritants)
    (only (guile) string-contains)
    ;; the editor's names are *not* given to the init file: it imports what
    ;; it needs, as an Emacs init file requires what it needs - see
    ;; `load-init'
    (only (schemacs buffer)
          *inhibit-read-only* *scratch-buffer-name* erase-buffer get-buffer
          get-buffer-create major-mode
          buffer-default-directory current-buffer set!buffer-default-directory
          set!buffer-read-only set-buffer-modified-p use-local-map
          with-current-buffer)
    (only (schemacs command) define-command)
    ;; `define-custom` is `custom.el`'s, and `initial-scratch-message` is
    ;; a defcustom - the declaration `startup.el:1841` writes.
    (only (schemacs custom) define-custom)
    (only (schemacs editfns) buffer-size goto-char insert)
    (only (schemacs fileio)
          expand-file-name file-exists-p locate-file-internal)
    (only (schemacs files)
          find-file-noselect insert-file-contents set-buffer-major-mode)
    ;; the switch that colours a source buffer as its mode is set
    (only (schemacs font-core) global-font-lock-mode)
    ;; an init file that failed is *said* in the echo area as well as on
    ;; stdout - see `load-init'
    (only (schemacs frame) *current-frame* set!frame-message)
    (only (schemacs buff-menu) list-buffers)
    (only (schemacs keymap) define-key)
    (prefix (schemacs keymap) km:)
    ;; The user environment - `$XDG_CONFIG_HOME/imports.scm', or the whole
    ;; editor when there is no such file - which the init file is loaded
    ;; into when it is evaluated. It is built here, in the boot, because
    ;; this is Emacs's `normal-top-level': the place the names are there
    ;; before anything of the user's is read.
    (only (schemacs loadup) open-user-environment!)
    (only (schemacs simple)
          messages-buffer-mode scroll-down-command scroll-up-command)
    ;; **The menu bar is loaded for its side effect**, which is where
    ;; `loadup.el` loads it: `(load "menu-bar")` among the preloaded
    ;; libraries. What that runs is the `[menu-bar]` keymap's creation
    ;; and the standard menus. Without this line they
    ;; would exist only when the *user's* `imports.scm` happened to
    ;; import the whole editor - and a user who replaces that file is
    ;; exactly the one the menus must still be there for.
    (only (schemacs menu-bar) menu-bar-file-menu menu-bar-edit-menu)
    (only (schemacs subr) kbd run-hooks)
    ;; `command-line-normalize-file-name` (`startup.el:3160`) is
    ;; `string-match`/`replace-match` and nothing else.
    (only (schemacs search) string-match replace-match save-match-data)
    ;; `substitute-command-keys` is `help.el`'s; the scratch message's
    ;; `\[find-file]` is written for it (`startup.el:1843`), and Emacs
    ;; preloads help.el (`loadup.el`), so startup may import it.
    (only (schemacs help) substitute-command-keys)
    (only (schemacs window)
          *get-scratch-buffer-create-function*
          display-buffer other-window quit-window switch-to-buffer
          switch-to-buffer-other-window))

  (export
   command-line-1
   command-line-1--display
   command-line-normalize-file-name
   init-path
   load-init
   ;; the startup screen and its one setting - `startup.el''s
   ;; `inhibit-startup-screen', which an init file says `set!' to
   inhibit-startup-screen
   splash-file
   display-startup-screen
   normal-splash-screen
   exit-splash-screen
   splash-screen-keymap
   ;; the startup hooks and the `*scratch*` buffer - `startup.el`'s
   *before-init-hook* *after-init-hook* *emacs-startup-hook*
   *window-setup-hook* *inhibit-startup-hooks*
   *initial-scratch-message* get-scratch-buffer-create
   ;; whether the init file is loaded at all - the command line's
   ;; `--no-init-file' (`-q'), which an entry point binds
   *init-file-user* *user-init-file*
   ;; emacs.c's two process facts the Lisp layer reads
   system-type daemonp
   )

  (begin

    ;;----------------------------------------------------------------
    ;; This library is not declarative - Guile's `#:declarative? #f'
    ;;----------------------------------------------------------------
    ;; `load' is used below, so this module is not a declarative one, and
    ;; Guile says so at every compile: "Use of `load' in declarative module
    ;; (schemacs startup).  Add #:declarative? #f to your
    ;; define-module invocation." There is no `define-module' here to add
    ;; it to - `define-library' takes only R7RS declarations, and an extra
    ;; clause is not even rejected: it becomes a *body expression*, is
    ;; evaluated, and is forgotten, so the warning comes back (measured).
    ;; So the fact is declared here instead, in two steps - and both are
    ;; needed, for different reasons, which is what the two comments below
    ;; are about.
    ;;
    ;; **Leaving the module declarative is not an option, and the warning
    ;; is not merely untidy.** A declarative module lets Guile fold one of
    ;; its own definitions into its own code, so an outside `(set!)' of it
    ;; stops being seen: measured, a declarative library with
    ;; `(define flag #f)' and `(define (read-flag) flag)' answers **#f**
    ;; from `read-flag' after a caller has done `(set! flag #t)', once the
    ;; library is *compiled* - and #t while it is interpreted, which is why
    ;; no suite run with `--no-auto-compile' can see it. The definition at
    ;; risk here is `inhibit-startup-screen', which exists for the user's
    ;; init file to set, so the symptom would be an init file that works in
    ;; every test and quietly stops working for a user running a `.go'.
    (define-syntax %not-declarative!
      ;; The flag has to be set while the body is being *expanded*, which
      ;; is why this is a macro and not a call. The expander walks the
      ;; whole library body before running any of it, so a plain call as
      ;; the first form is already too late - measured, the warning still
      ;; came and the flag was still set for the rest of that compilation.
      ;; A macro's transformer runs when its use is expanded, which is the
      ;; moment wanted, and it is the moment the compiler decides whether
      ;; to treat this module's definitions as foldable.
      ;;--------------------------------------------------------------
      (lambda (x)
        (set-module-declarative?! (current-module) #f)
        (datum->syntax x '(if #f #f))))
    (%not-declarative!)
    (set-module-declarative?!
     (resolve-module '(schemacs startup) #f)
     #f)
    ;; ^ **The macro alone silences the warning without fixing anything**,
    ;; and finding that out took a measurement worth recording. `library'
    ;; expands to `(define-module ...)` *followed by* the body, and that
    ;; `define-module` is evaluated when the library is loaded - so it
    ;; re-declares the module, with the default declarative flag, after the
    ;; expansion-time flip has worn off. Measured with the macro alone: no
    ;; warning, and `(module-declarative? (resolve-module '(schemacs editor
    ;; startup)))` answering **#t**. That is the worst of both - a hidden
    ;; diagnostic and a module that still is not what it claims - and it
    ;; matters for anything that compiles *against* this library rather
    ;; than inside it. So the flag is set a second time, here, where it
    ;; runs after that `define-module` and before anything reads it. With
    ;; both, the measured answer is `(folded #t declarative #f)`.

    ;;----------------------------------------------------------------
    ;; The init file
    ;;------------------------------------------------------------------
    ;;
    ;; Taken from `../guile-scsh/editor/init.scm' - "the shell's init file",
    ;; loaded once on startup - with the directory renamed for this editor
    ;; and the paths below.
    ;;
    ;; Where it lives:
    ;;
    ;;     $XDG_CONFIG_HOME/schemacs/init.scm   when the variable is set
    ;;     $HOME/.config/schemacs/init.scm      when the variable is not
    ;;     $HOME/.schemacs                      the old spelling, when the
    ;;                                          one above is not there
    ;;
    ;; (With the variable set but its file missing, ~/.schemacs is still
    ;; consulted - the variable relocates the config, it does not delete the
    ;; old one.) The file is plain Scheme, loaded the way Guile loads any
    ;; Scheme file - with `load', so it is compiled and cached, and
    ;; `define-module' inside it behaves as it would anywhere. An error
    ;; stops the init where it happened and is reported; the editor starts
    ;; anyway.
    ;;
    ;; GNU Emacs's version of this is `startup--load-user-init-file'
    ;; (`startup.el') and the `user-init-file' it answers with, searching
    ;; `~/.emacs', `~/.emacs.el' and `~/.emacs.d/init.el'. The paths are the
    ;; shell's here because the tree already reads its configuration from
    ;; `$XDG_CONFIG_HOME'; the *shape* is Emacs's - load it before the
    ;; command line's files are visited, and carry on if it fails.

    (define (first-existing paths)
      (cond ((null? paths) #f)
            ((not (car paths)) (first-existing (cdr paths)))
            ((file-exists-p (car paths)) (car paths))
            (else (first-existing (cdr paths)))))

    (define (init-path)
      ;; The first of the init file's locations that exists, or #f.
      ;;--------------------------------------------------------------
      (let ((xdg (getenv "XDG_CONFIG_HOME"))
            (home (getenv "HOME")))
        (if xdg
            (first-existing (list (string-append xdg "/schemacs/init.scm")
                                  (and home (string-append home "/.schemacs"))))
            (first-existing (list (and home
                                       (string-append home "/.config/schemacs/init.scm"))
                                  (and home (string-append home "/.schemacs")))))))

    (define system-type
      ;; GNU Emacs's `system-type` (`emacs.c:3500'): "Value is symbol
      ;; indicating the operating system type." On Linux that is
      ;; `gnu/linux`, and this tree runs on Linux. It lives here rather
      ;; than in a library of its own because `emacs.c` has no mirror -
      ;; `main.scm` is this tree's entry - and `startup.el` is where the
      ;; Lisp layer is next to the process facts it asks about.
      ;;--------------------------------------------------------------
      'gnu/linux)

    (define (daemonp)
      ;; GNU Emacs's `daemonp` (`emacs.c:3398`): "Return non-nil if the
      ;; current Emacs is a daemon." This tree has no `--daemon` mode:
      ;; it is started attached to a terminal or a window and exits with
      ;; it, so the answer is always nil. Named rather than faked - an
      ;; external package that branches on it takes the non-daemon
      ;; branch, which is the true one here.
      ;;--------------------------------------------------------------
      #f)

    (define *user-init-file* (make-parameter #f))
    ;; ^ GNU Emacs's `user-init-file' (`startup.el`): "File name of the
    ;; user's init file ... nil if no init file has been loaded." Set by
    ;; `load-init` to the path it loaded; `novice.el`'s
    ;; `enable-command` asks whether there is one to write to.

    (define *init-file-user* (make-parameter #t))
    ;; ^ GNU Emacs's `init-file-user' (`startup.el:341'), which is what
    ;; `--no-init-file' (`-q') sets to nil (:1407) and what
    ;; `startup--load-user-init-file' tests before it loads anything.
    ;; **The value differs and the sense does not**: Emacs'
    ;; is the login name of the user whose init file to read, or nil for
    ;; none, because a `-u USER' can ask for someone else's. There is no
    ;; `-u' here and no such use for the name, so this answers the one
    ;; question `load-init' asks it - whether to load one at all - with
    ;; #t for yes and #f for `--no-init-file'.
    ;;
    ;; A parameter, so that an entry point binds it around the editor it
    ;; starts (`schemacs/main.scm' does) rather than setting a variable
    ;; the whole process would keep.

    (define (%template? s)
      ;; Whether S is one of Guile's message *templates* - "Unbound
      ;; variable: ~S" - rather than text to show as it stands.
      ;;--------------------------------------------------------------
      (and (string? s)
           (let loop ((i 0))
             (cond ((>= i (string-length s)) #f)
                   ((char=? #\~ (string-ref s i)) #t)
                   (else (loop (+ i 1)))))))

    (define (%condition-text condition)
      ;; A condition's message is a *format template* and its text is in
      ;; the irritants - `schemacs/main.scm''s `condition-text', which
      ;; cannot be imported here (it is `(guile)''s file, above this
      ;; library), spelled out. Both reads are defensive, a handler that
      ;; raises while reporting being worse than the error it reports.
      ;;--------------------------------------------------------------
      (let ((message (catch #t (lambda () (exception-message condition))
                             (lambda a #f)))
            (irritants (catch #t (lambda () (exception-irritants condition))
                               (lambda a '()))))
        (if (and (string? message)
                 (pair? irritants)
                 (string-contains message "~"))
            (catch #t
              (lambda () (apply format #f message irritants))
              (lambda args message))
            message)))

    (define (init-error-text path key args)
      ;; What is said about an init file that failed: the shell's wording,
      ;; then the condition's own - and a Guile condition's text is a
      ;; *format template* with its values in the irritants, so the two
      ;; are put back together here the way `schemacs/main.scm''s
      ;; `condition-text' does it for a bad command line.
      ;;
      ;; Measured, an unbound variable raises
      ;;
      ;;   (unbound-variable (#f "Unbound variable: ~S" (this-is-not-bound) #f))
      ;;
      ;; so without the join a user is shown `#f Unbound variable: ~S #f'
      ;; and never learns *which* name was unbound - which is the one
      ;; thing an init file's error most needs to say.
      ;;
      ;; **A `raise-exception' arrives as `%exception' and the condition
      ;; object itself.** Guile's `catch' hands the handler KEY and the
      ;; throw's arguments; the exception machinery's key is
      ;; `%exception' and its one argument is the condition - a compound
      ;; one when a library raised it with `error', whose message and
      ;; irritants are what the user needs. The walk below never finds a
      ;; template in a condition *object* - it is a record, not text - so
      ;; the fallback that used to name `%exception' now asks the
      ;; condition for its own text first. Measured, a `load-theme' that
      ;; found no theme file read as bare `%exception' and now reads
      ;; "Unable to find theme file for `dusk'".
      ;;--------------------------------------------------------------
      (let ((words (let flatten ((x args) (out '()))
                     (cond ((null? x) (reverse out))
                           ((pair? (car x))
                            (flatten (cdr x) (append (reverse (car x)) out)))
                           (else (flatten (cdr x) (cons (car x) out)))))))
        (let loop ((rest words))
          (cond
           ((null? rest)
            ;; The walk found nothing but the condition's key. A
            ;; `%exception' means ARGS holds the condition object, and
            ;; its own message - put together with its irritants - is
            ;; the text; anything else is the key's name, as before.
            (let ((text (and (eq? key '%exception)
                             (pair? args)
                             (%condition-text (car args)))))
              (string-append "error: init file " path ": "
                             (if (and text (not (string=? text "")))
                                 text
                                 (symbol->string key)))))
           ((%template? (car rest))
            (let ((text (catch #t
                          (lambda () (apply format #f (car rest) (cdr rest)))
                          (lambda a #f))))
              (string-append "error: init file " path ": "
                             (if text text (symbol->string key)))))
           ((and (string? (car rest)) (not (string=? (car rest) "")))
            (string-append "error: init file " path ": " (car rest)))
           (else (loop (cdr rest)))))))

    (define (load-init)
      ;; Load the init file, if there is one. An error in it is reported
      ;; and the editor starts anyway, as the shell's does.
      ;;
      ;; `(scheme base)' has no `getenv'; the shell's file is a
      ;; `define-module' with Guile's own bindings, and this library is
      ;; an R7RS one, so `getenv' comes from `(guile)'.
      ;;--------------------------------------------------------------
      ;; "The hook run before loading the init file": Emacs runs
      ;; `before-init-hook` at `startup.el:1612`, after the urgent options
      ;; and before any init file is looked at.
      (run-hooks (*before-init-hook*))
      (let ((path (and (*init-file-user*) (init-path))))
        (when path
          (*user-init-file* path)
          ;; In the *user's* module and not this library's, so that the
          ;; file has Guile's ordinary bindings - `display', `getenv' and
          ;; the rest - and `(import (scheme-utils repl server))' works,
          ;; rather than only what this library happens to import. Emacs's init file
          ;; has the same property: it runs with all of Emacs's Lisp to
          ;; hand, not with the internals of `startup.el'.
          ;;
          ;; **The file imports what it needs, as an Emacs init file
          ;; requires what it needs.** Emacs has one obarray, so `(setq
          ;; inhibit-startup-screen t)' needs no `require'; here a name
          ;; belongs to the library that mirrors its Emacs file -
          ;; `inhibit-startup-screen' is `startup.el''s, and so it is in
          ;; this one - and the init file says
          ;;
          ;;     (import (schemacs startup))
          ;;     (inhibit-startup-screen #t)
          ;;
          ;; It is a parameter (the `define-custom' below), so the value
          ;; is written by *calling* it; a `set!' would shadow the import
          ;; with a local binding and the editor would never see it.
          ;;
          ;; **The init file is evaluated in the user environment** -
          ;; the module `open-user-environment!' has just built, which is
          ;; `$XDG_CONFIG_HOME/imports.scm' when the user has one and the
          ;; whole editor when they do not. So `(inhibit-startup-screen
          ;; #t)' needs no import, as `(setq inhibit-startup-screen t)'
          ;; needs no `require' in Emacs, and the same is true of `M-:' and
          ;; the back door - one environment for the three places where the
          ;; editor did not write the code.
          ;;
          ;; **The editor's own libraries are not in that position and must
          ;; not be**: each imports what it uses with an `(only ...)' list,
          ;; which is the rule that keeps a name in the library mirroring
          ;; its Emacs file. It is only the user's code that has no library
          ;; to write an import in.
          ;;
          ;; A second `import' in the file is still fine, and is how a name
          ;; from a library the environment does not hold is reached.
          (let ((here (current-module)))
            (catch #t
              (lambda ()
                (dynamic-wind
                  (lambda () (set-current-module (resolve-module '(guile-user))))
                  (lambda () (load path))
                  (lambda () (set-current-module here))))
              (lambda (key . args)
                (let ((text (init-error-text path key args)))
                  ;; **In the echo area as well as on stdout**, because on
                  ;; stdout is where the *terminal* front end hides it:
                  ;; `display' writes to the normal screen, and ncurses
                  ;; then switches to the alternate one, so the message is
                  ;; there but unseeable until the editor exits - measured,
                  ;; with the namespace call removed, where the failure of
                  ;; `(inhibit-startup-screen #t)' is exactly the sort
                  ;; of error a user would be staring at. A frame is current
                  ;; by this point (both front ends make one before
                  ;; `command-line-1'), so the echo area is where it goes.
                  (display text)
                  (newline)
                  (when (*current-frame*)
                    (set!frame-message (*current-frame*) text))))))))
      ;; `after-init-hook` (`startup.el:1721`): "run after Emacs loads the
      ;; init file ...". It is outside the `catch` above because it runs
      ;; whether or not there was a file and whether or not it failed -
      ;; Emacs's `startup--load-user-init-file` catches the file's errors
      ;; itself, so the hook is past that catch.
      (run-hooks (*after-init-hook*))
      ;; "If *scratch* exists and init file didn't change its mode,
      ;; initialize it" (`startup.el:1723-1727`). The front ends make the
      ;; buffer before this runs, so it arrives here bare - the branch
      ;; Emacs takes for the *scratch* its C makes at dump time.
      (let ((scratch (get-buffer *scratch-buffer-name*)))
        (when scratch
          (with-current-buffer scratch
            (when (eq? (major-mode) 'fundamental-mode)
              (set-buffer-major-mode scratch))))))

    ;;----------------------------------------------------------------
    ;; The startup screen
    ;;----------------------------------------------------------------
    ;;
    ;; GNU Emacs's is Lisp that builds its own text (`normal-splash-screen`,
    ;; `startup.el:2372', and the image version beside it); this one is a
    ;; **file of text**, `splash.txt', looked for on the load path - which
    ;; is schemacs' own arrangement and the only departure of substance.
    ;; Everything around it is Emacs's: the buffer is `*GNU Emacs*' there
    ;; and `*Schemacs*' here, read-only, with a map of its own whose `q'
    ;; leaves; the command line's files are shown *first*, and the splash
    ;; goes in the window below them.

    (define-custom inhibit-startup-screen #f
      "Non-nil inhibits the startup screen.

This is for use in your personal init file (but NOT site-start.el),
once you are familiar with the contents of the startup screen."
      :type 'boolean)
    ;; ^ GNU Emacs's `inhibit-startup-screen' (`startup.el:68'): "Non-nil
    ;; inhibits the startup screen. This is for use in your personal init
    ;; file (but NOT site-start.el), once you are familiar with the
    ;; contents of the startup screen."
    ;;
    ;; **Here, as in Emacs, and the init file imports it.** Emacs has one
    ;; obarray, so `(setq inhibit-startup-screen t)' needs no `require';
    ;; this tree has one library per Emacs file and this one is
    ;; `startup.el''s, so an init file that wants it says
    ;;
    ;;     (import (schemacs startup))
    ;;     (inhibit-startup-screen #t)
    ;;
    ;; which is Emacs's `(require 'startup)' and `(setq ...)' in the same
    ;; two lines, the value written by calling the parameter.
    ;; (An `open-editor-namespace!' call in `load-init' used to
    ;; import *every* editor library into the user's module so that the
    ;; second line alone would work; that is not how a name is reached here
    ;; - it belongs to the file its Emacs source belongs to.)
    ;;
    ;; **`-q'/`--no-init-file' does not inhibit it**, in Emacs or here. In
    ;; Emacs it is `-Q' that does, and `-Q' is `-q' plus "no site file"
    ;; plus `--no-splash' - so this tree, which has no site file and no
    ;; `-Q', leaves `--no-splash' to be added if anyone wants it.

    (define (splash-file)
      ;; The path of the splash screen's text, or #f when there is none.
      ;;
      ;; Two places, in this order:
      ;;
      ;;   `splash.txt' in a directory on the load path - a user's own, and
      ;;   the tree's root is one of those (`se' puts it there);
      ;;   `schemacs/splash.txt' in one of those directories - beside this
      ;;   tree's libraries, which is where the copy it ships lives.
      ;;
      ;; Emacs searches for its splash *image* the same way
      ;; (`fancy-splash-image-file', `startup.el:2087', through the image
      ;; load path); for a text file there is nothing to copy.
      ;;--------------------------------------------------------------
      (or (locate-file-internal "splash.txt" %load-path)
          (locate-file-internal "schemacs/splash.txt" %load-path)))

    (define-command (exit-splash-screen)
      "Stop displaying the splash screen buffer."
      (interactive)
      ;; Emacs's is `(quit-window t)' - leave the window and *kill* the
      ;; buffer. This tree's `quit-window' takes no argument (its KILL and
      ;; WINDOW are window.el's optional pair, not ported), so the splash
      ;; is buried and comes back on `C-x b' rather than being killed.
      ;; Named rather than papered over: the buffer is one `insert-file-
      ;; contents' away from being remade, and `normal-splash-screen'
      ;; erases it first anyway.
      (quit-window))

    (define splash-screen-keymap
      ;; GNU Emacs's `splash-screen-keymap' (`startup.el:2039'), which is
      ;; these four keys and nothing else: SPC and DEL scroll, S-SPC
      ;; scrolls down, `q' leaves.
      ;;
      ;; Two departures, both from what this tree has: Emacs's parent is
      ;; `button-buffer-map' and it is `:suppress t' - there are no buttons
      ;; here (the splash is text, not a `fancy-splash-screen' with links)
      ;; and no `suppress-keymap', which AGENTS.md lists with what it would
      ;; need. So a printing character reaches `self-insert-command' and is
      ;; refused by the read-only buffer, where Emacs makes it undefined.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*splash-screen-keymap*)))
        (define (bind! key command)
          (define-key map (kbd key) command))
        (bind! "SPC" scroll-up-command)
        (bind! "DEL" scroll-down-command)
        (bind! "S-SPC" scroll-down-command)
        (bind! "q" exit-splash-screen)
        map))

    (define (normal-splash-screen concise)
      ;; GNU Emacs's `normal-splash-screen' (`startup.el:2372'), the text
      ;; one: a buffer holding the text, read-only, with the splash map as
      ;; its local map - shown in this window when it is all there is to
      ;; show, and in *another* window when the command line named files,
      ;; which is Emacs's `(display-buffer splash-buffer)' against its
      ;; `(switch-to-buffer splash-buffer)'.
      ;;
      ;; The buffer is not a *visiting* one: the text is read into
      ;; `*Schemacs*' with `insert-file-contents' and the buffer's file
      ;; name stays nil, which is also why read-only is the right flag
      ;; rather than merely "do not save this".
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer-create "*Schemacs*"))
            (path (splash-file)))
        (with-current-buffer buffer
          ;; writing into it needs the flag off, as everywhere else
          (parameterize ((*inhibit-read-only* #t))
            (erase-buffer)
            (insert-file-contents path))
          (use-local-map splash-screen-keymap)
          (set!buffer-read-only buffer #t)
          (set-buffer-modified-p #f)
          ;; Emacs: `(goto-char (point-min))'
          (goto-char 1))
        (if concise
            (display-buffer buffer)
            (switch-to-buffer buffer))))

    (define (display-startup-screen concise)
      ;; GNU Emacs's `display-startup-screen' (`startup.el:2724'), and the
      ;; test at the end of its `command-line-1' (`:3075'): the screen when
      ;; there is one and nothing has inhibited it. CONCISE is Emacs's own
      ;; argument - "display a concise version in another window" - and it
      ;; is `(> displayable-buffers-len 0)': the files the command line
      ;; named are already displayed, so the splash goes below them.
      ;;--------------------------------------------------------------
      (when (and (not (inhibit-startup-screen)) (splash-file))
        (normal-splash-screen concise)))

    (define (command-line-1--display displayable-buffers)
      ;; Show the buffers the command line named: the `let' at the end of
      ;; GNU Emacs's `command-line-1', whose `displayable-buffers' is
      ;; built with the files pushed onto its front as they are visited.
      ;; It therefore reads backwards, and `(car displayable-buffers)' is
      ;; the *last* file named - which is the one the selected window
      ;; shows, so `emacs a b c' leaves `c' in front of you.
      ;;
      ;;   1 buffer   it fills the frame, and there is one window
      ;;   2 buffers  the frame is split; the last file is above, the
      ;;              first below, and the top window is selected
      ;;   3 or more  the frame is split; the last file is above and the
      ;;              Buffer Menu is below. The files in between are
      ;;              visited as buffers but not shown - Emacs leaves
      ;;              them for `C-x b' - and the menu is what `list-buffers'
      ;;              does, which finds the frame already has a window to
      ;;              put it in rather than splitting again.
      ;;
      ;; Every step is `switch-to-buffer', `switch-to-buffer-other-window'
      ;; and `other-window', which is what Emacs's own code calls.
      ;;--------------------------------------------------------------
      (let ((count (length displayable-buffers)))
        (when (> count 0)
          (switch-to-buffer (car displayable-buffers)))
        (cond
         ;; Two buffers; display them both.
         ((= count 2)
          (switch-to-buffer-other-window (cadr displayable-buffers))
          ;; Focus on the first buffer.
          (other-window -1))
         ;; More than two buffers: show the first in the other window and
         ;; then walk the rest of them through *that* window, each one
         ;; recording itself as it goes, so that the buffer list - which is
         ;; what the Buffer Menu shows in a moment - ends up in the reverse
         ;; of the command line: `emacs a b c' leaves c, b, a. That is the
         ;; order Emacs's own comment here describes, and the one that
         ;; makes `next-buffer' walk back up the command line.
         ((> count 2)
          (let ((rest (reverse (cdr displayable-buffers))))
            (switch-to-buffer-other-window (car rest))
            (for-each (lambda (buffer) (switch-to-buffer buffer))
                      (cdr rest))
            ;; Focus on the first buffer.
            (other-window -1))))
        (when (> count 2)
          (list-buffers))))

    ;;----------------------------------------------------------------
    ;; The startup hooks - `startup.el:283-334', and where they run
    ;;----------------------------------------------------------------
    ;;
    ;; Emacs declares five. `term-setup-hook' is obsolete in Emacs 31
    ;; ("In new code, there is no reason to use this instead of
    ;; `emacs-startup-hook'") and is not carried - so `emacs-startup-hook`
    ;; is run on its own wherever the C runs the pair.
    ;;
    ;; **The hooks are parameters**, as every hook is in this tree (see
    ;; `add-hook`): Emacs code `let`-binds a hook when it wants a run to
    ;; see a different one, so the hook's name is the parameter's.
    (define *before-init-hook* (make-parameter '()))
    (define *after-init-hook* (make-parameter '()))
    (define *emacs-startup-hook* (make-parameter '()))
    (define *window-setup-hook* (make-parameter '()))
    (define *inhibit-startup-hooks* #f)
    ;; ^ "Non-nil means don't run some startup hooks, because we already
    ;; did" (`startup.el:310'). A plain variable: Emacs `setq`s it
    ;; (`command-line-1`, `:3117`) and nothing `let`-binds it.

    ;;----------------------------------------------------------------
    ;; `get-scratch-buffer-create' (`simple.el:11553') and
    ;; `initial-scratch-message' (`startup.el:1841')
    ;;----------------------------------------------------------------
    ;;
    ;; **A placement departure**: `simple.el` is this tree's `simple.scm`,
    ;; which is *below* `files.scm` (`initial-major-mode`) and this
    ;; library - so the function lives here, where both are reachable, as
    ;; `locate-file-internal` lives in `fileio.scm`. `window.scm` asks for
    ;; it through `*get-scratch-buffer-create-function*`, which this
    ;; library installs at load, the way `files.scm` installs its seam.
    (define-custom *initial-scratch-message*
      ";; This buffer is for text that is not saved, and for Lisp evaluation.
;; To create a file, visit it with `\\[find-file]' and enter text in its buffer.

"
      "Initial documentation displayed in *scratch* buffer at startup.
If this is nil, no message will be displayed."
      :type '(choice (text :tag "Message") (const :tag "none" nil))
      :group 'startup)

    (define (get-scratch-buffer-create)
      ;; "Return the *scratch* buffer, creating a new one if needed."
      ;;--------------------------------------------------------------
      (or (get-buffer *scratch-buffer-name*)
          (let ((scratch (get-buffer-create *scratch-buffer-name*)))
            ;; "Don't touch the buffer contents or mode unless we know
            ;; that we just created it."
            (with-current-buffer scratch
              (when (*initial-scratch-message*)
                (insert (substitute-command-keys (*initial-scratch-message*)))
                (set-buffer-modified-p #f))
              ;; `(funcall initial-major-mode)' in the C; through
              ;; `set-buffer-major-mode`, this tree's spelling of it,
              ;; whose `*scratch*` arm takes `(*initial-major-mode*)` and
              ;; resolves the command by name.
              (set-buffer-major-mode scratch)
              ;; Emacs 31 also sets the buffer's `trusted-content` to
              ;; `:all` when the mode is `lisp-interaction-mode`; the
              ;; content-trust machinery is not ported here and nothing
              ;; reads the slot.
              #t)
            scratch)))

    (*get-scratch-buffer-create-function* get-scratch-buffer-create)

    (define (command-line-1 args)
      ;; GNU Emacs's `command-line-1', for a command line of file names:
      ;; visit each one into its own buffer - Emacs's `process-file-arg',
      ;; which is `find-file-noselect' - and then show them.
      ;;
      ;; ARGS is the file names, in command-line order. Nothing comes back:
      ;; what the caller wanted has happened to the frame's windows.
      ;;--------------------------------------------------------------
      ;; Emacs loads the init file before it visits the files named on
      ;; the command line (`normal-top-level' runs `command-line' after it),
      ;; and so does this.
      ;;
      ;; **The `*Messages*' buffer is made first, so that it is there from
      ;; the start.** Emacs does it in `normal-top-level' (`startup.el:738'),
      ;; immediately before it runs `command-line', and it gives the buffer
      ;; the same `default-directory' as `*scratch*' - "just to keep things
      ;; predictable". Without it an Emacs has no `*Messages*' until
      ;; something first logs a message, and the difference shows in
      ;; `C-x C-b' and in a user's init file.
      ;;
      ;; The *placement* is a departure, and named: this tree has no
      ;; `normal-top-level', so the boot it would have run is here.
      (let ((dir (buffer-default-directory (current-buffer))))
        (with-current-buffer (get-buffer-create "*Messages*")
          (messages-buffer-mode)
          (set!buffer-default-directory (current-buffer)
                                       (or dir (expand-file-name "~/")))))
      ;; **The user's environment, built before anything of the user's is
      ;; read.** Emacs's `normal-top-level' has one obarray and every name
      ;; in Emacs is already in it by the time the init file runs; this is
      ;; the same moment for the same reason - `imports.scm' and
      ;; `init.scm' are both the user's code, and both are evaluated in
      ;; what this builds.
      ;;
      ;; The *placement* is a departure, as the `*Messages*' block above
      ;; is: this tree has no `normal-top-level', so the boot it would
      ;; have run is here.
      (open-user-environment!)
      (load-init)
      ;; **Global Font Lock mode is on from the start.** GNU Emacs's
      ;; `global-font-lock-mode` is `:init-value (not (or noninteractive
      ;; emacs-basic-display))` (`font-core.el:274`), and the dumped
      ;; Emacs has it before the init file is read. There is no dump
      ;; here, so the boot turns it on: the hook it puts on
      ;; `after-change-major-mode-hook` is what colours each buffer as
      ;; its mode is set, including the files visited just below.
      (global-font-lock-mode 1)
      (let ((displayable-buffers '()))
        (for-each
         (lambda (name)
           (set! displayable-buffers
                 (cons (find-file-noselect name) displayable-buffers)))
         args)
        ;; "If *scratch* exists and is empty, insert
        ;; initial-scratch-message. Do this before switching to *scratch*
        ;; below to handle bug#9605" (`startup.el:3015-3021`). The front
        ;; ends make the buffer before this runs, so this is the arm that
        ;; fills it - `get-scratch-buffer-create` is for the lazy case.
        (let ((scratch (get-buffer *scratch-buffer-name*)))
          (when (and (*initial-scratch-message*) scratch)
            (with-current-buffer scratch
              (when (= (buffer-size) 0)
                (insert (substitute-command-keys (*initial-scratch-message*)))
                (set-buffer-modified-p #f)))))
        (command-line-1--display displayable-buffers)
        ;; `emacs-startup-hook` and `window-setup-hook` - `startup.el`'s
        ;; DEFVARs above - at the two sites Emacs runs them. With a
        ;; startup screen about to be displayed they run here, before it
        ;; is drawn (`:3094`, `:3115`), and `inhibit-startup-hooks` is
        ;; set (`:3117`) so they do not run again. **With
        ;; `inhibit-startup-screen` non-nil Emacs still runs them**, in
        ;; `normal-top-level`'s tail (`:807`, `:848`) - measured on Emacs
        ;; 31.1, both ways - and that tail is the `else` here, this tree
        ;; having no `normal-top-level`.
        (if (and (not (inhibit-startup-screen)) (splash-file))
            (begin
              (unless *inhibit-startup-hooks*
                (run-hooks (*emacs-startup-hook*))
                (run-hooks (*window-setup-hook*))
                (set! *inhibit-startup-hooks* #t))
              ;; The startup screen comes *after* the files, which is
              ;; Emacs's order (`startup.el:3125') and what puts the
              ;; splash in the window below them rather than over them.
              ;; CONCISE is Emacs's argument: #t when the command line
              ;; named something to show.
              (display-startup-screen (> (length displayable-buffers) 0)))
            (unless *inhibit-startup-hooks*
              (run-hooks (*emacs-startup-hook*))
              (run-hooks (*window-setup-hook*))))))

    (define (command-line-normalize-file-name file)
      "Collapse multiple slashes to one, to handle non-Emacs file names."
      ;; `startup.el:3160'.  The `system-type' arm that collapses
      ;; backslashes on MS-DOS and Windows is not carried (`w32' is not
      ;; ported); the GNU branch is the one this editor runs.
      ;;--------------------------------------------------------------
      (save-match-data
        ;; Use arg 1 so that we don't collapse // at the start of the
        ;; file name.  However, /// at the beginning is supposed to mean
        ;; just /, not //.
        (if (string-match "^///+" file)
            (set! file (replace-match "/" #t #t file)))
        (let loop ()
          (when (string-match "//+" file 1)
            (set! file (replace-match "/" #t #t file))
            (loop)))
        file))

    ))
