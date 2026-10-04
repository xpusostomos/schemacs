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
    (only (guile) catch current-module getenv load resolve-module
          set-current-module)
    (only (schemacs editor fileio) file-exists-p)
    (only (schemacs editor files) find-file-noselect)
    (only (schemacs editor buff-menu) list-buffers)
    (only (schemacs editor window)
          display-buffer other-window switch-to-buffer
          switch-to-buffer-other-window))

  (export
   command-line-1
   command-line-1--display
   init-path
   load-init
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

    (define (load-init)
      ;; Load the init file, if there is one. An error in it is reported
      ;; and the editor starts anyway, as the shell's does.
      ;;
      ;; `(scheme base)' has no `getenv'; the shell's file is a
      ;; `define-module' with Guile's own bindings, and this library is
      ;; an R7RS one, so `getenv' comes from `(guile)'.
      ;;--------------------------------------------------------------
      (let ((path (init-path)))
        (when path
          ;; In the *user's* module and not this library's, so that the
          ;; file has Guile's ordinary bindings - `display', `getenv' and
          ;; the rest - and `(import (schemacs repl))' works, rather than
          ;; only what this library happens to import. Emacs's init file
          ;; has the same property: it runs with all of Emacs's Lisp to
          ;; hand, not with the internals of `startup.el'.
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
        (command-line-1--display displayable-buffers)))

    ))
