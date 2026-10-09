;; Schemacs' entry point: the command line, and which front end to run.
;;
;;     se [-w|--window] [--chdir DIR] [-h|--help] [FILE...]
;;
;; and the three that talk to a *running* editor instead of starting one:
;;
;;     se --server[=PORT]            open this editor's back door
;;     se --repl[=PORT]              be a REPL for another editor's
;;     se --remote[=PORT] FILE...    open files in another editor
;;
;; `se' (in `bin/') is the launcher - it puts the tree, or an installed
;; copy's own site directory, on the load path and loads this file. Like
;; `main-gtk.scm' and `main-ncurses.scm' this is a *program* and not a
;; library: it does its work as it is loaded rather than exporting a
;; function.
;;
;; The options are read with **SRFI 37**, `(srfi srfi-37)`: `args-fold`
;; folds over the command line, and each option's procedure answers the
;; seeds it is given - so the whole line is read in one pass with no state
;; outside the fold, which is the shape this file wants. It also permutes
;; (`se FILE -w' works) and it stops at `--'.
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
(import ;; **Nothing is imported from `(scheme base)' or `(scheme write)'**,
        ;; and that is the fix for a warning rather than a style choice.
        ;; This file is loaded into `(guile-user)', whose parent module is
        ;; `(guile)' and which therefore already has every one of them -
        ;; `list', `apply', `string-append', `assq', `display', `newline'
        ;; and the rest. Importing `(scheme base)' on top of them makes
        ;; Guile warn
        ;;
        ;;   WARNING: (guile-user): imported module (scheme base) overrides
        ;;   core binding `member'
        ;;
        ;; the first time each shadowed name is *looked up* - so `member'
        ;; and `for-each' warned at startup, two lines of stderr before the
        ;; first screen paint, from the launcher's own use of them.
        ;; `error' and `raise' were excluded here for the same reason and
        ;; the other 60-odd names were not, which is why the warning waited
        ;; for two of them to be used. The names taken from `(guile)' are
        ;; named below, so the dependency is still on the record - the
        ;; `(only (guile) ...)' form at the end of this list.
        (ice-9 exceptions)
        (srfi srfi-37)
        (only (srfi srfi-13) string-contains)
        (only (schemacs repl) remove-repl-port-file! start-repl!)
        ;; `command-line' and `exit' are `(scheme process-context)''s in
        ;; R7RS and core bindings in `(guile-user)'; they are named here for
        ;; the same reason as everything else in this list.
        (only (guile) %load-path basename catch chdir command-line exit
              format getenv module-ref module-variable resolve-module
              scm-error setenv string->number))

(setenv "GUILE_WARN_DEPRECATED" "no")

(define %guile-format format)
;; ^ **Captured here, at the top of the file, and not called by name
;; below.** This file is loaded into `(guile-user)', and so is the user's
;; *init file* - which imports whatever it needs, and an editor library
;; that exports a name this file uses then shadows it for every later call
;; in this module. `format' is the one that bites: Guile's takes the
;; DESTINATION first and `(schemacs editor editfns)'s `format' is Emacs's,
;; which takes the format *string* first - so the error message this file
;; prints on a bad command line became `%styled-format' being handed a
;; port as its format string, and the real error was never seen. Measured
;; by driving `se' with `SCHEMACS_REPL' set and a pty harness init file
;; (`(import (schemacs editor startup))'): the door did not open and the
;; only thing on the screen was "Wrong type argument ... #<output: file
;; /dev/pts/8>".

(define *program-name* (basename (car (command-line))))
;; ^ What this program calls itself in a message. Emacs uses argv[0]
;; (`emacs.c': `fprintf (stderr, "%s: Can't chdir to %s: %s\n", argv[0],
;; ...)'), which for a launcher invoked by its path would be the whole
;; path; the basename is what this launcher has always used.

(define *option-specs*
  ;; SRFI 37's option descriptions, and its seeds: each procedure is given
  ;; the seeds and answers the new ones - the file names so far, whether a
  ;; window was asked for, the directory to change to, and whether help was
  ;; asked for. There is no place here for a description, so the usage text
  ;; below is written out by hand.
  ;;
  ;; **Nothing leaves from in here.** `exit' raises, and the fold is run
  ;; inside a `guard' that turns a bad command line into a message - so an
  ;; `exit' from a processor would be caught by it and come out as a
  ;; backtrace. Asking for help is a seed like any other; `run-command-line'
  ;; acts on it.
  ;;--------------------------------------------------------------
  (list (option (list #\w "window") #f #f
                (lambda (opt name arg seen)
                  (argument-set seen 'window #t)))
        (option (list "chdir") #t #f
                (lambda (opt name arg seen)
                  (argument-set seen 'chdir arg)))
        ;; Emacs' `-q'/`--no-init-file' (`startup.el:1407' sets
        ;; `init-file-user' to nil for it). `-Q'/`--quick' is that plus
        ;; "no site file" and "no splash", neither of which exists here,
        ;; so it is not carried rather than carried as a synonym.
        (option (list #\q "no-init-file") #f #f
                (lambda (opt name arg seen)
                  (argument-set seen 'no-init-file #t)))
        ;; `--server[=PORT]' and `--repl[=PORT]': the argument is
        ;; *optional*, and SRFI 37 takes an optional argument only
        ;; attached - `--server=37146' and not `--server 37146', because
        ;; otherwise the next word could be a file name
        ;; (`srfi/srfi-37.scm:206'). Emacs spells its own optional
        ;; arguments the same way (`--daemon[=NAME]'). The value is left a
        ;; *string* here and checked in `option-port', so that
        ;; `--repl=abc' can be told from a port.
        (option (list "server") #f #t
                (lambda (opt name arg seen)
                  (argument-set seen 'server (or arg #t))))
        (option (list "repl") #f #t
                (lambda (opt name arg seen)
                  (argument-set seen 'repl (or arg #t))))
        ;; `-r'/`--remote[=PORT]': `emacsclient' from the other side - the
        ;; file names on the command line are opened by a *running*
        ;; editor, and no editor is started here.
        ;;
        ;; **Two records, because `-r' must not eat the file name.** SRFI
        ;; 37 fills a *short* option's argument out of the next word when
        ;; nothing is attached (`srfi-37.scm:143' - `-oARG' and `-o ARG'
        ;; are one code path there), so a `-r' that took an optional
        ;; argument would read `se -r foo.txt' as "port foo.txt". `-r' is
        ;; a plain flag and the port is spelled `--remote=PORT';
        ;; `-rPORT', the attached form, is rewritten below the way
        ;; `--chdir DIR' is.
        (option (list #\r) #f #f
                (lambda (opt name arg seen)
                  (argument-set seen 'remote #t)))
        (option (list "remote") #f #t
                (lambda (opt name arg seen)
                  (argument-set seen 'remote (or arg #t))))
        (option (list #\h "help") #f #f
                (lambda (opt name arg seen)
                  (argument-set seen 'help #t)))))

(define (argument-set seen key value)
  ;; One more thing the fold has seen. **The seed is an alist**, and not
  ;; one seed per option: with three options a value each read well, and
  ;; with six every procedure's arity changed for every option added.
  ;;--------------------------------------------------------------
  (cons (cons key value) seen))

(define (argument-value seen key default)
  ;; What the fold has seen for KEY, or DEFAULT.
  ;;--------------------------------------------------------------
  (let ((entry (assq key seen)))
    (if entry (cdr entry) default)))

(define (option-spelling opt)
  ;; How an option was written, for the message below: `--nope' for a long
  ;; one, `-x' for a short one. SRFI 37 hands the name apart from its
  ;; dashes (`args-fold' passes a character for a short option and the
  ;; name for a long one, `srfi/srfi-37.scm:186'), so they are put back.
  ;;--------------------------------------------------------------
  (let ((name (car (option-names opt))))
    (if (char? name)
        (string #\- name)
        (string-append "--" name))))

(define (unrecognized-option opt name arg seen)
  ;; An option nobody knows: Emacs' own words, and its own way of saying
  ;; them - `(error "Unknown option `%s'" argi)', `startup.el:2995'. The
  ;; error is raised and the caller turns it into a line on stderr and exit
  ;; 1, which is where this launcher's own words are added.
  ;;--------------------------------------------------------------
  (launcher-error "Unknown option `~a'" (option-spelling opt)))

(define (attach-option-arguments args)
  ;; **SRFI 37 takes a long option's argument only attached.**
  ;; `args-fold' wants `--chdir=DIR' and raises "Missing required argument
  ;; after `--chdir'' for `--chdir DIR' (`srfi/srfi-37.scm:206'). Emacs
  ;; takes either: `argmatch' reads the value after the `=' when there is
  ;; one and out of the *next argument* when there is not (`emacs.c:711',
  ;; `:728'). So the two-argument form is attached here, before the fold,
  ;; and the fold only ever sees the one spelling. `--' ends it: what
  ;; follows is operands, `--chdir' among them if it is written there.
  ;;--------------------------------------------------------------
  (cond ((null? args) args)
        ((string=? (car args) "--") args)
        ((and (string=? (car args) "--chdir") (pair? (cdr args)))
         (cons (string-append "--chdir=" (cadr args))
               (attach-option-arguments (cddr args))))
        ;; `-rPORT' as `--remote=PORT', and for the same reason again: `-r'
        ;; is a short option, and SRFI 37 takes a short option's argument
        ;; out of the *next* word when nothing is attached - so the
        ;; attached spelling has to become the long one, where the
        ;; argument is unambiguously attached, before the fold sees it.
        ((and (> (string-length (car args)) 2)
              (string=? "-r" (substring (car args) 0 2)))
         (cons (string-append "--remote=" (substring (car args) 2))
               (attach-option-arguments (cdr args))))
        (else (cons (car args) (attach-option-arguments (cdr args))))))

(define (parse-arguments args)
  ;; The command line as an alist: the file names in the order they were
  ;; given, whether a window was asked for, the directory to change to,
  ;; whether help was asked for, whether the init file is to be skipped,
  ;; and the `--server'/`--repl' ports.
  ;;
  ;; A bad command line comes back as an *exception* - SRFI 37 raises for a
  ;; long option whose argument is missing, which is the one malformed line
  ;; the fold cannot answer seeds for - and the caller turns it into a
  ;; message and exit 1. Nothing in here leaves or prints.
  ;;--------------------------------------------------------------
  (args-fold (attach-option-arguments args)
             *option-specs*
             unrecognized-option
             (lambda (operand seen)
               (argument-set seen 'files
                             (cons operand (argument-value seen 'files '()))))
             ;; **One seed, the empty alist.** `args-fold''s seeds are
             ;; its remaining arguments, so `'()' here is one seed whose
             ;; value is the empty list - not no seeds.
             '()))

(define (usage port)
  (%guile-format port "Usage: ~a [OPTION]... [FILE]...~%" *program-name*)
  (%guile-format port "Edit FILE, or start on an empty buffer.~%")
  (%guile-format port "~%")
  (%guile-format port "  -w, --window        start the Gtk editor (the terminal is the default)~%")
  (%guile-format port "      --chdir=DIR     change to directory DIR before starting~%")
  (%guile-format port "  -q, --no-init-file  do not load an init file~%")
  (%guile-format port "      --server[=PORT] open the REPL back door (on PORT when given)~%")
  (%guile-format port "      --repl[=PORT]   connect to a running editor's back door as a~%")
  (%guile-format port "                      REPL, and start no editor~%")
  (%guile-format port "  -r, --remote[=PORT] open FILE... in a running editor's `find-file',~%")
  (%guile-format port "                      and start no editor (`-r' takes no port;~%")
  (%guile-format port "                      `--remote=PORT' names one)~%")
  (%guile-format port "  -h, --help          print this and exit~%"))

(define (launcher-error message . irritants)
  ;; Signal a bad command line, with a message already formatted.
  ;;
  ;; **`error' is not `(scheme base)''s here.** This file imports
  ;; `(scheme base)' with `error' and `raise' taken out of it, so that
  ;; they do not override the core bindings of `(guile-user)' and make
  ;; Guile warn - and the `error' that is left is Guile's own, whose
  ;; *message* is the template "~A ~S" over the message and its
  ;; arguments. A reader of `se --nope' then sees
  ;; "Unknown option `~a' \"--nope\"" rather than the message. So the text
  ;; is formatted here and raised as a plain message condition, which is
  ;; what `condition-text' and the caller both expect.
  ;;--------------------------------------------------------------
  (apply scm-error 'misc-error *program-name* message irritants (list #f)))

(define (condition-text e)
  ;; The text of an exception, in Guile's own two halves put back
  ;; together: a condition's message is a *format template* and the text
  ;; is in its irritants - `(exception-message e)' for a failed `chdir'
  ;; is the string "~A", with "No such file or directory" beside it.
  ;; This is what `eval-expression''s backtrace header does for the same
  ;; reason. A message that is not a template formats to itself.
  ;;--------------------------------------------------------------
  ;; **Both are asked for defensively.** `exception-irritants' raises for
  ;; a condition that has none - a plain `&message', which is what the
  ;; REPL client signals when there is no server to connect to - and a
  ;; handler that raises while reporting an error is how an error turns
  ;; into a backtrace.
  (let ((message (catch #t (lambda () (exception-message e)) (lambda a #f)))
        (irritants (catch #t (lambda () (exception-irritants e)) (lambda a '()))))
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

(define (check-cairo!)
  ;; Run only when the Gtk editor is what was asked for: a terminal editor
  ;; needs no cairo at all, and failing a terminal run over it would be
  ;; wrong.
  ;;
  ;; **This used to name a `.guile-cairo' directory under the tree** and
  ;; tell the reader to build one there - a *staged install* of a newer
  ;; guile-cairo that the launcher put on the load path itself. That is
  ;; gone (2026-10-10): the library belongs on Guile's own load path, in
  ;; the prefix Guile was configured for, so the message names the install
  ;; rather than a directory this tree keeps.
  ;;--------------------------------------------------------------
  (unless (cairo-bridge?)
    (format (current-error-port)
            "~a: guile-cairo is too old for the Gtk front end.~%~%" *program-name*)
    (format (current-error-port)
            (string-append
             "  `cairo-pointer->context' is missing, and that is what wraps the~%"
             "  cairo context Gtk hands the `draw' signal - no Gtk frame can be~%"
             "  drawn without it. It is in guile-cairo newer than 1.11.2, and it~%"
             "  belongs where Guile looks for libraries, not in a directory this~%"
             "  editor knows about:~%~%"))
    (format (current-error-port)
            (string-append
             "      cd <the guile-cairo checkout>~%"
             "      ./configure --prefix=$(guile-config info prefix)~%"
             "      make && sudo make install~%~%"))
    (format (current-error-port)
            "  `~a' with no `-w' is a terminal editor and needs no cairo at all.~%"
            *program-name*)
    (exit 1)))

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

(define (option-port seen key)
  ;; The port an option with an *optional* argument was given: a number
  ;; for `--repl=37146', #t for a bare `--repl', and #f when the option
  ;; was not there at all. Anything else is a bad port number and says so.
  ;;--------------------------------------------------------------
  (let ((given (argument-value seen key #f)))
    (cond ((eq? given #t) #t)
          ((not given) #f)
          (else
           (let ((port (string->number given)))
             (unless (and port (exact-integer? port) (> port 0) (< port 65536))
               (launcher-error "--~a needs a port number, not `~a'"
                               key given))
             port)))))

(define (start-back-door! server)
  ;; Open the development back door - see `schemacs/repl.sld', and
  ;; `schemacs/repl-client.sld' for the other end of it.
  ;;
  ;; SERVER is a number for `--server=PORT', #t for a bare `--server'
  ;; (which chooses a port and writes it where clients look), or #f when
  ;; the command line did not ask - in which case `SCHEMACS_REPL' is the
  ;; older way to ask, and either of them is a door.
  ;;
  ;; **Loaded here, not imported at the top of the file**, for the same
  ;; reason the front ends are: `--repl' must not load the editor's
  ;; libraries, and this is one of them.
  ;;--------------------------------------------------------------
  (let ((env (getenv "SCHEMACS_REPL")))
    (cond ((number? server) (start-repl-in! server) #t)
          ((eq? server #t) (start-repl-in!) #t)
          (env
           ;; **`port' is bound by this `let' and returned by it.** It was
           ;; written as `(let ((port ...)) (when port (start-repl-in!
           ;; port))) port' - the answer outside the `let` that binds it -
           ;; so `SCHEMACS_REPL` answered "Unbound variable: port" and the
           ;; door never opened. It went unnoticed because nothing drove
           ;; this path: `tools/pty-check.py' started `main-ncurses.scm',
           ;; which opened its own door from the same variable, and
           ;; `--server'/`--repl' take the branches above. Found the day
           ;; the harness was pointed at `se'.
           (let ((port (string->number env)))
             (when port (start-repl-in! port))
             port))
          (else #f))))

(define (start-repl-in! . port)
  (apply (module-ref (resolve-module '(schemacs repl)) 'start-repl!) port))

(define (with-command-line-errors thunk)
  ;; Run THUNK with a bad command line reported rather than raised: the
  ;; message on stderr the way this launcher has always phrased it -
  ;; "<name>: <what>" - and exit 1.
  ;;
  ;; A `quit' is left alone: `exit' and an interrupt both arrive as one,
  ;; and catching it here is what would turn an `exit' inside THUNK into a
  ;; backtrace.
  ;;
  ;; **The editor is deliberately not run inside this.** An error on the
  ;; command line is the launcher's to report; an error in the editor is a
  ;; bug, and it should show its own backtrace rather than be dressed up
  ;; as a complaint about the command line. What is inside is the reading
  ;; of the command line and the two things that act on it - starting a
  ;; REPL client, and the `--repl'/`--server' checks.
  ;;--------------------------------------------------------------
  (guard (e ((quit-exception? e) (raise e))
             (#t (%guile-format (current-error-port) "~a: ~a~%"
                         *program-name* (condition-text e))
                 (exit 1)))
    (thunk)))

(define (init-file-user)
  ;; The parameter `load-init' consults, resolved only when an editor is
  ;; being started: `--repl' must not load the editor's libraries, and
  ;; this is the one thing on that path that would.
  ;;--------------------------------------------------------------
  (module-ref (resolve-module '(schemacs editor startup)) '*init-file-user*))

(define (start-editor files window no-init-file)
  ;; Start the front end the command line asked for, with `load-init''s
  ;; question answered: `--no-init-file' is bound *around the editor*, not
  ;; set as a variable, so that nothing else in the process has to know
  ;; about it.
  ;;--------------------------------------------------------------
  (let ((start (lambda ()
                 (if window
                     (begin
                       (check-cairo!)
                       (start-front-end '(schemacs ui gtk gtk-main)
                                        'main-gtk files))
                     (start-front-end '(schemacs ui ncurses ncurses-main)
                                      'main-ncurses files)))))
    (if no-init-file
        (let ((param (init-file-user)))
          (parameterize ((param #f)) (start)))
        (start))))

(define (check-connect-only option seen)
  ;; `--repl' and `--remote' both talk to an editor that is already
  ;; running, so neither can be combined with anything that starts one -
  ;; nor with the other. Which of them is the conflict is named, rather
  ;; than listing everything they cannot be combined with.
  ;;--------------------------------------------------------------
  (let ((other (cond ((argument-value seen 'window #f) "--window")
                     ((argument-value seen 'server #f) "--server")
                     ((and (eq? option 'repl) (argument-value seen 'remote #f))
                      "--remote")
                     ((and (eq? option 'remote) (argument-value seen 'repl #f))
                      "--repl")
                     (else #f))))
    (when other
      (launcher-error
       (string-append "--~a connects to an editor that is already running, "
                      "so it cannot be combined with ~a")
       option other))))

(define (run-repl-option seen)
  ;; `--repl': be a REPL for a *running* editor's back door, and start
  ;; none. That is what makes it `emacsclient'-like rather than a way to
  ;; start an editor, so combining it with anything that starts one is a
  ;; mistake worth saying out loud rather than ignoring.
  ;;--------------------------------------------------------------
  (check-connect-only 'repl seen)
  (let ((port (option-port seen 'repl)))
    (apply (module-ref (resolve-module '(schemacs repl-client))
                       'run-repl-client)
           (list (if (eq? port #t) #f port)))))

(define (run-remote-option seen)
  ;; `--remote': hand the file names to a running editor's `find-file',
  ;; and start nothing here.
  ;;
  ;; **No file is a usage error**, and says so with the form that would
  ;; work: the option exists to open files, and there is nothing else it
  ;; could sensibly do with none.
  ;;--------------------------------------------------------------
  (check-connect-only 'remote seen)
  (let ((files (reverse (argument-value seen 'files '()))))
    (unless (pair? files)
      (launcher-error "--remote needs a file to open~%~a --remote FILE [FILE...]"
                      *program-name*))
    (let ((port (option-port seen 'remote)))
      (apply (module-ref (resolve-module '(schemacs repl-client))
                         'run-remote-files)
             (list (if (eq? port #t) #f port) files)))))

(define (run-command-line args)
  ;; The order is the C's: the options are read, then `--chdir' moves the
  ;; process (before anything the line asks for - `emacs.c:1534' is the
  ;; same), then the back door opens, then the editor starts. The door is
  ;; opened before the editor so that a client can already be there when
  ;; the first command runs.
  ;;
  ;; The editor itself is started *outside* `with-command-line-errors': an
  ;; error in the editor is a bug and should show its own backtrace, not be
  ;; dressed up as a complaint about the command line.
  ;;--------------------------------------------------------------
  (let ((seen (with-command-line-errors (lambda () (parse-arguments args)))))
    (when (argument-value seen 'help #f)
      (usage (current-output-port))
      (exit 0))
    (cond ((argument-value seen 'repl #f)
           (with-command-line-errors (lambda () (run-repl-option seen))))
          ((argument-value seen 'remote #f)
           (with-command-line-errors (lambda () (run-remote-option seen))))
          (else
            (let ((dir (argument-value seen 'chdir #f))
                  (files (reverse (argument-value seen 'files '())))
                  (window (argument-value seen 'window #f))
                  (no-init-file (argument-value seen 'no-init-file #f)))
              (when dir
                (change-directory! dir))
              (let ((opened (with-command-line-errors
                             (lambda () (start-back-door!
                                         (option-port seen 'server))))))
                (start-editor files window no-init-file)
                ;; The editor proper does not know the back door exists and
                ;; cannot tidy up after it, so the file it wrote is removed
                ;; here - the one step `main-gtk.scm' and `main-ncurses.scm'
                ;; also end with.
                (when opened
                  ((module-ref (resolve-module '(schemacs repl))
                               'remove-repl-port-file!)))))))))

(run-command-line (cdr (command-line)))
