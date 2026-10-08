(import
 (scheme base)
 (scheme char)
 (scheme file)
 (only (guile) delete-file mkdir rmdir setenv unsetenv %load-path)
 (only (srfi srfi-13) string-suffix?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor buffer) get-buffer)
 (only (schemacs editor startup) init-path load-init splash-file
       display-startup-screen inhibit-startup-screen))

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
  #f inhibit-startup-screen)

(test-equal "and inhibited, `display-startup-screen' makes no buffer"
  #f
  (begin (set! inhibit-startup-screen #t)
         (display-startup-screen #f)
         (get-buffer "*Schemacs*")))

(test-end "schemacs_editor_startup")
