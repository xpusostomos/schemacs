;; Schemacs' entry point: the command line, and which front end to run.
;;
;;     seg [-w|--window] [--chdir DIR] [-h|--help] [FILE...]
;;
;; `seg' is the launcher - it puts the tree, and the built guile-cairo,
;; on the load path and loads this file. Like `main-gtk.scm' and
;; `main-ncurses.scm' this is a *program* and not a library: it does its
;; work as it is loaded rather than exporting a function.
;;
;; The options are read with Guile's own command-line processing,
;; `(ice-9 getopt-long)'. It is the same shape as glibc's `getopt_long',
;; which is what `emacs.c' itself calls, so it is the nearest thing to
;; Emacs' own behaviour that a Scheme program has. It wants the real
;; `(command-line)' - "a value similar to what (program-arguments)
;; returns", program name included - and answers an alist of `(NAME .
;; VALUE)' with the arguments that are neither options nor option values
;; under the key `()'. argv[0] is replaced by its basename first, so that
;; a complaint about a bad option reads `seg: ...' the way this tree's
;; launcher has always complained.
;;
;; **The terminal is the default; `-w' asks for the Gtk window.** Emacs
;; spells the same choice the other way round (`emacs -nw' is the
;; terminal, `emacs' the window), which is why this is worth saying out
;; loud. `-w' is schemacs' own flag and has no Emacs counterpart.
;;------------------------------------------------------------------

;; Only the editor's own libraries are imported here. Each front end's is
;; resolved at the moment it is chosen, which is what keeps a terminal
;; editor from needing the Gtk stack and the windowed one from needing
;; ncurses - the reason this is one entry point rather than two.
(import (scheme base)
        (ice-9 exceptions)
        (ice-9 getopt-long)
        (only (srfi srfi-13) string-contains)
        (only (schemacs repl) remove-repl-port-file! start-repl!)
        ;; `(scheme process-context)' is deliberately *not* imported, even
        ;; though `command-line' and `exit' are what it is wanted for: this
        ;; file is loaded into `(guile-user)', where both are already core
        ;; bindings, and importing the library on top of them makes Guile
        ;; warn that it "overrides core binding `exit'". The bindings are
        ;; named here so that the dependency is still on the record.
        (only (guile) %load-path basename catch chdir command-line exit
              format getenv module-ref module-variable resolve-module
              setenv string->number))

(setenv "GUILE_WARN_DEPRECATED" "no")

(define *program-name* (basename (car (command-line))))
;; ^ What this program calls itself in a message. Emacs uses argv[0]
;; (`emacs.c': `fprintf (stderr, "%s: Can't chdir to %s: %s\n", argv[0],
;; ...)'), which for a launcher invoked by its path would be the whole
;; path; the basename is what the tree's `seg' has always used.

(define *option-spec*
  ;; `getopt-long''s grammar. `--chdir' takes a value, in both spellings
  ;; (`--chdir DIR' and `--chdir=DIR'); `-w' and `-h' are the
  ;; single-character forms of `--window' and `--help'. There is no
  ;; place for a description here - this Guile's `getopt-long' has no
  ;; such property (it raises `invalid getopt-long option property' for
  ;; one), so the usage text below is written out by hand.
  '((window (single-char #\w) (value #f))
    (chdir  (value #t))
    (help   (single-char #\h) (value #f))))

(define (usage port)
  (format port "Usage: ~a [OPTION]... [FILE]...~%" *program-name*)
  (format port "Edit FILE, or start on an empty buffer.~%")
  (format port "~%")
  (format port "  -w, --window     start the Gtk editor (the terminal is the default)~%")
  (format port "      --chdir=DIR  change to directory DIR before starting~%")
  (format port "  -h, --help       print this and exit~%"))

(define (condition-text e)
  ;; The text of an exception, in Guile's own two halves put back
  ;; together: a condition's message is a *format template* and the text
  ;; is in its irritants - `(exception-message e)' for a failed `chdir'
  ;; is the string "~A", with "No such file or directory" beside it.
  ;; This is what `eval-expression''s backtrace header does for the same
  ;; reason. A message that is not a template formats to itself.
  ;;--------------------------------------------------------------
  (let ((message (exception-message e))
        (irritants (exception-irritants e)))
    (if (and (string? message)
             (pair? irritants)
             (string-contains message "~"))
        (catch #t
          (lambda () (apply format #f message irritants))
          (lambda args message))
        message)))

(define (change-directory! dir)
  ;; GNU Emacs' `--chdir DIR' (`emacs.c:1534'): "Change to directory
  ;; DIR." It is one of the options Emacs handles while scanning its
  ;; command line, before anything else the line asks for - which here
  ;; means before the editor makes its first buffer, so that
  ;; `default-directory' and every relative file name after it on the
  ;; line are the new directory's.
  ;;
  ;; The failure is the C's too: its message and its exit status -
  ;; "Can't chdir to %s: %s" with strerror's text, then exit 1. (Emacs
  ;; also remembers the directory it started in, as `original_pwd'; that
  ;; is for its daemon and for `emacs_wd', neither of which this tree
  ;; has.)
  ;;--------------------------------------------------------------
  (guard (e (#t (format (current-error-port) "~a: Can't chdir to ~a: ~a~%"
                        *program-name* dir (condition-text e))
             (exit 1)))
    (chdir dir)))

(define (cairo-bridge?)
  ;; Whether the guile-cairo on the load path is the one this tree is
  ;; built against: the newer one with `cairo-pointer->context', which
  ;; wraps the cairo context Gtk hands the `draw' signal. The packaged
  ;; guile-cairo predates it, and without it the editor dies at its first
  ;; repaint with an unbound variable three frames away from the
  ;; directory that is missing - which reads as a bug in the editor.
  ;;
  ;; Tested by importing the library exactly as the Gtk backend does. A
  ;; library that will not load at all answers "no bridge" rather than
  ;; taking this program down with it.
  ;;--------------------------------------------------------------
  (catch #t
    (lambda ()
      (and (module-variable (resolve-module '(cairo)) 'cairo-pointer->context)
           #t))
    (lambda args #f)))

(define (cairo-directory)
  ;; Where the launcher was told to look, for the message below: the load
  ;; path entry under the tree, or #f when there is none - which is a
  ;; different complaint and says so.
  ;;--------------------------------------------------------------
  (let loop ((path %load-path))
    (cond ((null? path) #f)
          ((string-contains (car path) ".guile-cairo") (car path))
          (else (loop (cdr path))))))

(define (check-cairo!)
  ;; The launcher's own check, moved here so that it runs only when the
  ;; Gtk editor is what was asked for: a terminal editor needs no cairo at
  ;; all, and failing a terminal run over it would be wrong.
  ;;
  ;; Two separate messages rather than one `format' with a computed
  ;; format string, which is what keeps this file free of the compiler's
  ;; `non-literal format string' warning.
  ;;--------------------------------------------------------------
  (unless (cairo-bridge?)
    (let ((dir (cairo-directory)))
      (format (current-error-port)
              "~a: cairo-pointer->context is not available.~%~%" *program-name*)
      (if dir
          (format (current-error-port)
                  "  Looked first in: ~a~%~%" dir)
          (format (current-error-port)
                  "  No .guile-cairo directory is on the load path.~%~%"))
      (format (current-error-port)
              (string-append
               "That directory is a *built copy* of a newer guile-cairo than the~%"
               "packaged one; it is what wraps the cairo context GTK hands the~%"
               "draw signal. Build it from the guile-cairo checkout (it is not~%"
               "committed):~%~%"))
      (let ((tree (tree-of-cairo dir)))
        (format (current-error-port)
                "  cd ~a/../guile-cairo && ./autogen.sh && ./configure~%"
                tree)
        (format (current-error-port)
                "  make install --prefix=~a/.guile-cairo~%~%" tree))
      (format (current-error-port)
              "See GTK-PLAN.md, \"Rendering: guile-gi's cairo gap\".~%")
      (exit 1))))

(define (tree-of-cairo dir)
  ;; DIR is the launcher's `.guile-cairo' load path entry; the tree is what
  ;; it sits under. "<tree>" when there is no such entry, so that the
  ;; instructions above still read as instructions.
  ;;--------------------------------------------------------------
  (let ((suffix "/.guile-cairo/share/guile/site/3.0"))
    (if (and dir
             (> (string-length dir) (string-length suffix))
             (string=? suffix (substring dir
                                         (- (string-length dir)
                                            (string-length suffix)))))
        (substring dir 0 (- (string-length dir) (string-length suffix)))
        "<tree>")))

(define (start-front-end module name args)
  ;; Load one front end and run it with the file names.
  ;;
  ;; **Resolved here, not imported at the top of the file**, so that only
  ;; the front end being started is loaded - a terminal editor has no
  ;; business needing guile-gi, and a windowed one no business needing
  ;; ncurses.
  ;;
  ;; `main-gtk' and `main-ncurses' return when the editor quits, which is
  ;; how the caller knows it is on the way out.
  ;;--------------------------------------------------------------
  (apply (module-ref (resolve-module module) name) args))

(define (start-back-door!)
  ;; The development back door, the same one `main-gtk.scm' and
  ;; `main-ncurses.scm' open and for the same reason - see
  ;; `schemacs/repl.sld'. `SCHEMACS_REPL' names a port and the editor
  ;; opens Guile's *cooperative* REPL server on it, so a running editor
  ;; can be read and poked through `tools/repl.py'. Set here rather than
  ;; in the editor so that nothing in the editor proper knows the back
  ;; door exists - and, with no `SCHEMACS_REPL', still opened when an
  ;; init file calls `(start-repl!)' with no port of its own.
  ;;--------------------------------------------------------------
  (let ((port (getenv "SCHEMACS_REPL")))
    (when port
      (start-repl! (string->number port)))))

(let* ((arguments (cons *program-name* (cdr (command-line))))
       (options (getopt-long arguments *option-spec*))
       (files (option-ref options '() '())))
  (when (option-ref options 'help #f)
    (usage (current-output-port))
    (exit 0))
  (let ((dir (option-ref options 'chdir #f)))
    (when dir
      (change-directory! dir)))
  (start-back-door!)
  (if (option-ref options 'window #f)
      (begin
        (check-cairo!)
        (start-front-end '(schemacs ui platform gtk) 'main-gtk files))
      (start-front-end '(schemacs ui platform ncurses) 'main-ncurses files))
  ;; The editor proper does not know the back door exists and cannot tidy
  ;; up after it, so the file it wrote is removed here - the one step
  ;; `main-gtk.scm' and `main-ncurses.scm' also end with.
  (remove-repl-port-file!))
