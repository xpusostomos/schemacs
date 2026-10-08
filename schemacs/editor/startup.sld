(define-library (schemacs editor startup)
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
  ;; (schemacs editor startup)" and suggests "Add #:declarative? #f to
  ;; your define-module invocation". There is no `define-module' to add
  ;; it to - this is a `define-library', which Guile's R7RS expansion
  ;; does not pass the clause through (tried: it is a syntax error) - and
  ;; the warning is *correct*: loading the user's init file at run time
  ;; is exactly a non-declarative act, which is why Guile is right to ask
  ;; for the hint rather than to be silenced. Turning this library into a
  ;; `define-module' to carry one line of metadata would be a bigger
  ;; change than the warning is worth; it stays, and says so.

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
    (only (guile) %load-path catch current-module getenv load resolve-module
          set-current-module)
    ;; the editor's names, which the init file is given before it is
    ;; loaded - see `load-init'
    (only (schemacs editor loadup) open-editor-namespace!)
    (only (schemacs editor buffer)
          *inhibit-read-only* erase-buffer get-buffer-create
          set!buffer-read-only set-buffer-modified-p use-local-map
          with-current-buffer)
    (only (schemacs editor command) define-command)
    (only (schemacs editor editfns) goto-char)
    (only (schemacs editor fileio) file-exists-p locate-file-internal)
    (only (schemacs editor files) find-file-noselect insert-file-contents)
    (only (schemacs editor buff-menu) list-buffers)
    (only (schemacs editor keymap) define-key)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor simple) scroll-down-command scroll-up-command)
    (only (schemacs editor subr) kbd)
    (only (schemacs editor window)
          display-buffer other-window quit-window switch-to-buffer
          switch-to-buffer-other-window))

  (export
   command-line-1
   command-line-1--display
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
   ;; whether the init file is loaded at all - the command line's
   ;; `--no-init-file' (`-q'), which an entry point binds
   *init-file-user*
   )

  (begin

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

    (define (load-init)
      ;; Load the init file, if there is one. An error in it is reported
      ;; and the editor starts anyway, as the shell's does.
      ;;
      ;; `(scheme base)' has no `getenv'; the shell's file is a
      ;; `define-module' with Guile's own bindings, and this library is
      ;; an R7RS one, so `getenv' comes from `(guile)'.
      ;;--------------------------------------------------------------
      (let ((path (and (*init-file-user*) (init-path))))
        (when path
          ;; In the *user's* module and not this library's, so that the
          ;; file has Guile's ordinary bindings - `display', `getenv` and
          ;; the rest - and `(import (schemacs repl))' works, rather than
          ;; only what this library happens to import. Emacs's init file
          ;; has the same property: it runs with all of Emacs's Lisp to
          ;; hand, not with the internals of `startup.el'.
          ;;
          ;; **And it is *given* the editor's names**, which is that
          ;; property and not a convenience: Emacs's init file can say
          ;; `(setq inhibit-startup-screen t)' because the variable is in
          ;; the one obarray. Here the name has to be put in the module
          ;; first, or `(set! inhibit-startup-screen #t)' - the spelling
          ;; this tree documents - is an unbound variable. The back door
          ;; is given the same names by the same call
          ;; (`schemacs/editor/loadup.sld').
          (open-editor-namespace! (resolve-module '(guile-user)))
          (let ((here (current-module)))
            (catch #t
              (lambda ()
                (dynamic-wind
                  (lambda () (set-current-module (resolve-module '(guile-user))))
                  (lambda () (load path))
                  (lambda () (set-current-module here))))
              (lambda (key . args)
                (display "error: init file ") (display path)
                (display ": ") (display key) (display " ") (display args)
                (newline)))))))

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

    (define inhibit-startup-screen #f)
    ;; ^ GNU Emacs's `inhibit-startup-screen' (`startup.el:68'): "Non-nil
    ;; inhibits the startup screen. This is for use in your personal init
    ;; file (but NOT site-start.el), once you are familiar with the
    ;; contents of the startup screen."
    ;;
    ;; **A variable, and the init file can `set!' it** - which needs the
    ;; name to be *there* when the init file runs, and it is: `load-init'
    ;; gives the init file's module the editor's names
    ;; (`open-editor-namespace!'), the way Emacs's init file has all of
    ;; Emacs's Lisp to hand. `(set! inhibit-startup-screen #t)' is exactly
    ;; Emacs's `(setq inhibit-startup-screen t)'.
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
      (when (and (not inhibit-startup-screen) (splash-file))
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
      (load-init)
      (let ((displayable-buffers '()))
        (for-each
         (lambda (name)
           (set! displayable-buffers
                 (cons (find-file-noselect name) displayable-buffers)))
         args)
        (command-line-1--display displayable-buffers)
        ;; The startup screen comes *after* the files, which is Emacs's
        ;; order (`startup.el:3125') and what puts the splash in the
        ;; window below them rather than over them. CONCISE is Emacs's
        ;; argument: #t when the command line named something to show.
        (display-startup-screen (> (length displayable-buffers) 0))))

    ))
