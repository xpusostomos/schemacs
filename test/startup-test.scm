(import
 (scheme base)
 (scheme char)
 (scheme file)
 (only (guile) delete-file mkdir rmdir setenv unsetenv %load-path)
 (only (srfi srfi-13) string-contains string-suffix?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer buffer-modified-p buffer-name
       get-buffer major-mode with-current-buffer)
 (only (schemacs editfns)
       buffer-substring goto-char insert point-max point-min)
 (only (schemacs frame) *current-buffer* *current-frame* new-frame)
 (only (schemacs custom) custom-variable-p)
 (only (schemacs startup) *after-init-hook* *before-init-hook*
       *initial-scratch-message* get-scratch-buffer-create init-path
       load-init splash-file display-startup-screen
       inhibit-startup-screen))

;; `startup.el`'s init file, as loaded here: where it is looked for, and
;; that loading one works. The loader is taken from
;; `../guile-scsh/editor/init.scm' - see `startup.sld'.
;;
;; The search order is the shell's, and so is the rule worth testing:
;; with `XDG_CONFIG_HOME' set but its file missing, the old spelling under
;; `$HOME' is still consulted - "the variable relocates the config, it
;; does not delete the old one."

(test-begin "schemacs_editor_startup")

(define root "/tmp/schemacs-startup-tests")

(define (clean!)
  (for-each (lambda (p) (guard (e (#t #f)) (delete-file p)))
            (list (string-append root "/.config/schemacs/init.scm")
                  (string-append root "/.schemacs")
                  (string-append root "/wrote.txt")))
  (for-each (lambda (p) (guard (e (#t #f)) (rmdir p)))
            (list (string-append root "/.config/schemacs")
                  (string-append root "/.config")
                  root)))

(define (write-file path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define (read-all path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((c (read-char port)))
          (if (eof-object? c)
              (list->string (reverse acc))
              (loop (cons c acc))))))))

(clean!)
(guard (e (#t #f)) (mkdir root))
(guard (e (#t #f)) (mkdir (string-append root "/.config")))
(guard (e (#t #f)) (mkdir (string-append root "/.config/schemacs")))

;; the XDG location, when it is there
(write-file (string-append root "/.config/schemacs/init.scm") ";; xdg\n")
(setenv "HOME" root)
(setenv "XDG_CONFIG_HOME" (string-append root "/.config"))
(test-equal (string-append root "/.config/schemacs/init.scm") (init-path))

;; ... and the old spelling under `$HOME' when the XDG file is not there:
;; the variable relocates the config, it does not delete the old one
(delete-file (string-append root "/.config/schemacs/init.scm"))
(write-file (string-append root "/.schemacs") ";; old spelling\n")
(test-equal (string-append root "/.schemacs") (init-path))

;; with no variable set, the file is `~/.config/schemacs/init.scm' - which
;; is not there - and the old spelling is not there either, so there is no
;; init file at all
(delete-file (string-append root "/.schemacs"))
(unsetenv "XDG_CONFIG_HOME")
(test-equal #f (init-path))

;; Loading one: the file is plain Scheme with Guile's *ordinary* bindings -
;; `display' and `call-with-output-file' - because it is read in the user's
;; module rather than in `startup.sld''s.
(write-file (string-append root "/.schemacs")
            (string-append "(call-with-output-file \"" root "/wrote.txt\"\n"
                           "  (lambda (port) (display \"loaded\" port)))\n"))
(load-init)
(test-equal "loaded" (read-all (string-append root "/wrote.txt")))

;; An init file with an error in it is reported and the editor starts
;; anyway: `load-init' answers without raising.
(write-file (string-append root "/.schemacs") "(this-is-not-bound)\n")
(test-equal "no raise"
  (guard (e (#t "raised")) (load-init) "no raise"))

(clean!)

;;--------------------------------------------------------------------
;; The startup screen
;;--------------------------------------------------------------------
;; GNU Emacs's splash is Lisp that builds its own text; this one is a file
;; of text looked for on the load path (`startup.sld'). Two places, in
;; order: a `splash.txt' in a directory on the load path, which is a
;; user's own, and `schemacs/splash.txt' beside this tree's libraries.
;;
;; What is *shown* is checked in a pty (`tools/pty-check.py', `splash'),
;; because it needs a frame; the search and the setting are here.
;;--------------------------------------------------------------------
(define splash-root "/tmp/schemacs-splash-tests")

(guard (e (#t #f)) (delete-file (string-append splash-root "/splash.txt")))
(guard (e (#t #f)) (rmdir splash-root))
(guard (e (#t #f)) (mkdir splash-root))

(write-file (string-append splash-root "/splash.txt") "mine\n")
(set! %load-path (cons splash-root %load-path))
(test-equal "a splash.txt on the load path is the one found"
  (string-append splash-root "/splash.txt")
  (splash-file))

;; ... and with none there, the copy the tree ships, which lives with the
;; libraries rather than at its root
(delete-file (string-append splash-root "/splash.txt"))
(test-assert "and the tree's own schemacs/splash.txt when there is none"
  (let ((path (splash-file)))
    (and path (string-suffix? "schemacs/splash.txt" path))))

;; `inhibit-startup-screen' is the setting an init file writes - Emacs's
;; own name for it, and its own default
(test-equal "the startup screen is on until something inhibits it"
  #f (inhibit-startup-screen))

(test-equal "and inhibited, `display-startup-screen' makes no buffer"
  #f
  (begin (inhibit-startup-screen #t)
         (display-startup-screen #f)
         (get-buffer "*Schemacs*")))

;; The setting is a `define-custom' (`startup.el:68', a defcustom): a
;; parameter with the documentation and type recorded, set by calling it.
(test-assert "inhibit-startup-screen is a define-custom parameter"
             (and (custom-variable-p 'inhibit-startup-screen)
                  (procedure? inhibit-startup-screen)))

(test-end "schemacs_editor_startup")

;;--------------------------------------------------------------------
;; `*scratch*' - `get-scratch-buffer-create' and its message
;;--------------------------------------------------------------------
;; `initial-scratch-message' and `initial-major-mode' are what the
;; buffer holds when the editor starts; `get-scratch-buffer-create'
;; (`simple.el:11553') is the lazy path, and is what
;; `switch-to-buffer "*scratch*"' reaches through `window.scm''s seam.
(test-begin "schemacs_editor_startup_scratch")

(define ed (allocate-buffer))

(parameterize ((*current-frame* (new-frame ed 24 80))
               (*current-buffer* #f))
  (define scratch (get-scratch-buffer-create))
  (define (scratch-text)
    (with-current-buffer scratch
      (buffer-substring (point-min) (point-max))))

  (test-equal "get-scratch-buffer-create makes *scratch*"
    "*scratch*" (and scratch (buffer-name scratch)))

  (test-assert "and puts the message in it"
    (string-contains (scratch-text)
                     "This buffer is for text that is not saved"))

  (test-equal "unmodified, as startup.el:3021 leaves it" #f
    (buffer-modified-p scratch))

  (test-equal "and in `initial-major-mode'" 'lisp-interaction-mode
    (with-current-buffer scratch (major-mode)))

  ;; "Don't touch the buffer contents or mode unless we know that we
  ;; just created it" - a second call answers the same buffer untouched.
  (with-current-buffer scratch (goto-char (point-max)) (insert "typed"))
  (let ((before (scratch-text)))
    (get-scratch-buffer-create)
    (test-equal "a second call leaves the contents alone" before
      (scratch-text))))

(test-end "schemacs_editor_startup_scratch")

;;--------------------------------------------------------------------
;; The startup hooks, around the init file
;;--------------------------------------------------------------------
;; `before-init-hook` runs before the init file and `after-init-hook`
;; after it - whether or not there was a file and whether or not it
;; failed, because Emacs runs the second in `command-line` outside
;; `startup--load-user-init-file`'s catch (`startup.el:1721`).
(test-begin "schemacs_editor_startup_hooks")

(define hook-marker (string-append root "/hook-marker.txt"))
(define hook-log '())

(define (hook-before)
  (set! hook-log (cons 'before hook-log)))

(define (hook-after)
  (set! hook-log
        (cons (if (file-exists? hook-marker) 'after-with-init 'after-no-init)
              hook-log)))

(parameterize ((*current-frame* (new-frame ed 24 80))
               (*current-buffer* #f)
               (*before-init-hook* (list hook-before))
               (*after-init-hook* (list hook-after)))
  (guard (e (#t #f)) (mkdir root))
  (guard (e (#t #f)) (mkdir (string-append root "/.config")))
  (guard (e (#t #f)) (mkdir (string-append root "/.config/schemacs")))
  (setenv "HOME" root)
  (setenv "XDG_CONFIG_HOME" (string-append root "/.config"))
  (guard (e (#t #f)) (delete-file hook-marker))

  ;; The init file leaves a marker the after hook can see: `before` first,
  ;; then the file, then `after` with the marker in place.
  (write-file (string-append root "/.config/schemacs/init.scm")
              (string-append "(call-with-output-file \"" hook-marker "\"\n"
                             "  (lambda (out) (display \"init\" out)))\n"))
  (load-init)
  (test-equal "before, then the init file, then after" '(after-with-init before)
    hook-log)

  ;; An init file that raises still gets `after-init-hook`, and the marker
  ;; is not there because the file never got that far.
  (guard (e (#t #f)) (delete-file hook-marker))
  (write-file (string-append root "/.config/schemacs/init.scm")
              "(this-is-not-bound)\n")
  (set! hook-log '())
  (load-init)
  (test-equal "and an init file that failed does not skip it"
    '(after-no-init before) hook-log))

(test-end "schemacs_editor_startup_hooks")
