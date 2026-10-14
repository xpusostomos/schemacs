;; Tests for `(schemacs repl)': the *server* half of the development back
;; door - what an editor runs when it opens it.
;;
;; The client half has its own suite (`repl-client-tests.scm'). Here it is
;; the session's namespace, which is the thing that made `se --repl' look
;; broken on the day it was first used:
;;
;;     scheme@(guile-user)> (find-file "README.md")
;;     ;;; socket:9:1: warning: possibly unbound variable `find-file'
;;     Unbound variable: find-file
;;
;; The door itself was working - the socket, the port file, the prompt,
;; the evaluation in the editor's own process - and the session's module
;; had none of the editor's names. See `open-editor-namespace!' for why
;; that is a departure from GNU Emacs (one obarray) and what is done about
;; it.
;;
;; The live session is not testable from here: it needs an editor to
;; connect to. What *is* testable is the two halves of it - that the
;; prelude really does put the editor's names in a module, and that the
;; list of libraries it names is still the whole editor.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) catch eval make-fresh-user-module module-ref
       closedir eof-object? opendir readdir sort)
 (only (srfi srfi-13) string-drop-right string-suffix?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (scheme file) call-with-input-file delete-file file-exists?
       open-output-file)
 (only (guile) getenv module-variable resolve-module setenv system
       variable-bound? variable-ref)
 (only (schemacs editor loadup) editor-libraries editor-excluded-libraries
       imports-path open-editor-namespace! open-user-environment!))

(define (bound? module name)
  ;; Whether MODULE answers to NAME. `module-ref' raises for a name it has
  ;; never heard of, so the question needs a guard.
  ;;
  ;; **`find-file' and not `map'.** A fresh module has `(guile)' for its
  ;; parent, so every core name is bound whether the prelude has run or
  ;; not; only a name that belongs to the editor alone can tell the two
  ;; states apart.
  ;;-------------------------------------------------------------
  (catch #t (lambda () (module-ref module name) #t) (lambda args #f)))

(test-begin "schemacs_loadup")

;;-------------------------------------------------------------
;; The session's namespace
;;-------------------------------------------------------------
(let ((module (make-fresh-user-module)))
  (test-assert "a bare module has no find-file"
    (not (bound? module 'find-file)))
  (open-editor-namespace! module)
  (test-assert "the prelude gives the session find-file"
    (and (bound? module 'find-file)
         (procedure? (module-ref module 'find-file))))
  ;; One name from each of the corners a session wants: a command from
  ;; `files.el', the buffer registry from `buffer.c', a display function
  ;; from `xdisp.c' and the echo area from `frame.c'. A list that has gone
  ;; wrong tends to go wrong in one of the four.
  (test-assert "... and the buffer registry"
    (bound? module 'buffer-list))
  (test-assert "... and the display"
    (bound? module 'render!))
  (test-assert "... and the echo area"
    (bound? module 'set-message!))
  ;; `import' itself has to keep working: a session that wants one of the
  ;; two libraries the prelude leaves out asks for it by name, and that
  ;; has to work from the module the prelude built. (`bound?' cannot
  ;; answer this one: `import' is core *syntax*, so a bare module has it
  ;; too - hence a real import of a library nobody has loaded yet.)
  (test-assert "... and the session can still import"
    (begin (eval '(import (ice-9 format)) module) #t)))

;;-------------------------------------------------------------
;; The list is the whole editor, or it has gone stale
;;-------------------------------------------------------------
;; The list of libraries is written out in `repl.scm' rather than derived,
;; because the tree's root is not a thing a running editor knows - so a
;; library added tomorrow would silently be missing from every session
;; until somebody noticed. This is what notices: every `schemacs/editor/*.scm'
;; on disk has to be either given to the session or excluded on purpose.
;;-------------------------------------------------------------
(define (library<? a b)
  (string<? (symbol->string (car (reverse a)))
            (symbol->string (car (reverse b)))))

(define (editor-libraries-on-disk)
  ;; The `(schemacs editor ...)' libraries this directory holds.
  ;;
  ;; **The test suites live here too, and are not libraries.** They are
  ;; scripts - they `import', they do not `define-library' - so nothing
  ;; could hand one to a session, and asking whether one is in the list is
  ;; asking about the wrong population. Until the tree moved off `guile
  ;; --r7rs' the two kinds were told apart by *extension*, libraries being
  ;; `.sld' and suites `.scm'; now everything here is `.scm' and it takes
  ;; the name. A suite that is ever named without the `-tests' tail is a
  ;; false failure here rather than a missed library, which is the safe
  ;; direction.
  ;;-------------------------------------------------------------
  (let ((dir (opendir "schemacs/editor")))
    (let loop ((out '()))
      (let ((name (readdir dir)))
        (if (eof-object? name)
            (begin (closedir dir) (sort out library<?))
            (loop (if (and (string-suffix? ".scm" name)
                           (not (string-suffix? "-tests.scm" name)))
                      (cons (list 'schemacs 'editor
                                  (string->symbol (string-drop-right name 4)))
                            out)
                      out)))))))

(define (unclassified rest)
  (cond ((null? rest) '())
        ((member (car rest) (editor-libraries)) (unclassified (cdr rest)))
        ((member (car rest) (editor-excluded-libraries))
         (unclassified (cdr rest)))
        (else (cons (car rest) (unclassified (cdr rest))))))

(test-assert "there is an editor to walk"
  (pair? (editor-libraries-on-disk)))

(test-equal "every editor library is given to the session or excluded on purpose"
  '()
  (unclassified (editor-libraries-on-disk)))

(test-equal "nothing is in both lists"
  '()
  (let loop ((rest (editor-excluded-libraries)) (out '()))
    (cond ((null? rest) (reverse out))
          ((member (car rest) (editor-libraries))
           (loop (cdr rest) (cons (car rest) out)))
          (else (loop (cdr rest) out)))))

(test-equal "the session's list has no duplicates"
  '()
  (let loop ((rest (editor-libraries)) (seen '()) (out '()))
    (cond ((null? rest) (reverse out))
          ((member (car rest) seen) (loop (cdr rest) seen (cons (car rest) out)))
          (else (loop (cdr rest) (cons (car rest) seen) out)))))


;;-------------------------------------------------------------
;; The user's environment - `imports.scm'
;;-------------------------------------------------------------
;; The three consumers of it are a REPL prompt, a typed expression and
;; the user's `init.scm': code the editor did not write, and so code with
;; no library to write an import in for it. What is testable here is the
;; builder - that it gives a module the editor's names when the user has
;; said nothing, that it reads `$XDG_CONFIG_HOME/imports.scm' when there
;; is one, and that **the file says what the environment is** rather than
;; adding to a fixed base.
;;-------------------------------------------------------------
(define (with-imports-file body thunk)
  ;; Run THUNK with `$XDG_CONFIG_HOME' pointing at a throwaway directory
  ;; that holds BODY as `schemacs/imports.scm' - or, for #f, holds
  ;; nothing at all.
  ;;-------------------------------------------------------------
  (let* ((dir (string-append "/tmp/schemacs-loadup-tests-" (number->string (getpid))))
         (sub (string-append dir "/schemacs")))
    (system (string-append "mkdir -p " sub))
    (when body
      (call-with-output-file (string-append sub "/imports.scm")
        (lambda (port) (display body port))))
    (let ((old (getenv "XDG_CONFIG_HOME")))
      (setenv "XDG_CONFIG_HOME" dir)
      (dynamic-wind
        (lambda () #t)
        thunk
        (lambda ()
          (if old (setenv "XDG_CONFIG_HOME" old) (setenv "XDG_CONFIG_HOME" #f)))))))

(with-imports-file #f
 (lambda ()
   (test-assert "no imports.scm: the environment is the whole editor"
     (let ((m (make-fresh-user-module)))
       (open-user-environment! m)
       (and (bound? m 'find-file)
            (bound? m 'message)
            (bound? m 'render!))))
   (test-equal "no imports.scm: imports-path answers #f"
     #f (imports-path))))

(with-imports-file "(import (schemacs editor imports))\n"
 (lambda ()
   (test-assert "imports.scm naming the editor gives the editor's names"
     (let ((m (make-fresh-user-module)))
       (open-user-environment! m)
       (and (bound? m 'find-file) (bound? m 'message))))
   (test-equal "the file is found where it is written"
     "imports.scm"
     (let ((p (imports-path))) (substring p (- (string-length p) 11))))))

;; **The file replaces the default**, which is what "the user has full
;; control over what is imported into his default environment" means: a
;; file that does not name the editor gets an environment without it.
(with-imports-file "(import (scheme base))\n"
 (lambda ()
   (test-assert "imports.scm that leaves the editor out gets none of it"
     (let ((m (make-fresh-user-module)))
       (open-user-environment! m)
       (not (bound? m 'find-file))))))

;;-------------------------------------------------------------
;; One name, one binding
;;-------------------------------------------------------------
;; Sixty-odd libraries are imported into one module by `(schemacs editor
;; imports)', and a name two of them export is a collision - Guile's
;; "imported from both" - which the generated library resolves by
;; `except'-ing it from every library but the first. That is only correct
;; when the two are the *same* binding: `simple' re-exports what `cmds'
;; owns, `files' re-exports `buffer''s `kill-buffer', and those are one
;; procedure offered twice.
;;
;; **Two libraries that each define their own is the bug**, and it is not
;; hypothetical: `xdisp' used to `(make-parameter ...)' its own
;; `*minor-mode-alist*' beside `subr''s, so the mode line read one alist
;; and `add-minor-mode' wrote the other - and `casefiddle' exported
;; `upcase-region' after the command had moved to `simple', which handed
;; an *unbound* name to every importer. Both were found by writing this
;; down and looking. So the check is a test.
;;-------------------------------------------------------------
;; **The names a library *exports*, and not every binding it has.** A
;; private helper is invisible to an importer, so two libraries with a
;; private `keyword?' of their own is not a clash - `module-for-each'
;; shows local bindings and would report one, which is how this test
;; first came out with `xfaces' against `textprop' for a predicate
;; neither exports.
(define (exported-names file)
  (let* ((forms (call-with-input-file file
                  (lambda (port)
                    (let loop ((acc '()))
                      (let ((form (read port)))
                        (if (eof-object? form) (reverse acc) (loop (cons form acc))))))))
         (lib (let loop ((rest forms))
                (cond ((null? rest) #f)
                      ((and (pair? (car rest)) (eq? (car (car rest)) 'define-library))
                       (car rest))
                      (else (loop (cdr rest))))))
         (decl (and lib
                    (let loop ((rest (cddr lib)))
                      (cond ((null? rest) #f)
                            ((and (pair? (car rest)) (eq? (car (car rest)) 'export))
                             (car rest))
                            (else (loop (cdr rest))))))))
    (map (lambda (item)
           (if (and (pair? item) (eq? (car item) 'rename)) (cadr (cadr item)) item))
         (if decl (cdr decl) '()))))

(define (editor-library-files)
  ;; The `(name . path)' of every library the environment is built from.
  ;;-------------------------------------------------------------
  (let ((dir (opendir "schemacs/editor")))
    (let loop ((out '()))
      (let ((name (readdir dir)))
        (if (eof-object? name)
            (begin (closedir dir) out)
            (loop (if (and (string-suffix? ".scm" name)
                           (not (string-suffix? "-tests.scm" name))
                           (not (string=? name "imports.scm")))
                      (cons (cons (string-append "schemacs/editor/" name)
                                  (string->symbol (string-drop-right name 4)))
                            out)
                      out)))))))

(define (duplicate-export offender)
  ;; Walk every library the environment is built from and answer the
  ;; `(NAME . LIBRARY)' of each export that is a *different* binding from
  ;; the one an earlier library exported under the same name.
  ;;-------------------------------------------------------------
  (let ((seen (make-hash-table)) (bad '()))
    (for-each
     (lambda (entry)
       (let* ((name (cdr entry))
              (library (list 'schemacs 'editor name))
              (m (resolve-module library #f #:ensure #f)))
         (when m
           (for-each
            (lambda (exported)
              (let ((v (catch #t
                         (lambda () (module-variable m exported))
                         (lambda args #f))))
                (when (and v (variable-bound? v))
                  (let ((prev (hashq-ref seen exported)))
                    (if (not prev)
                        (hashq-set! seen exported v)
                        (if (not (eq? prev v))
                            (set! bad (cons (cons exported name) bad))))))))
            (exported-names (car entry))))))
     (editor-library-files))
    bad))

(test-equal "no exported name is two different bindings"
  '()
  (duplicate-export #f))

(test-end "schemacs_loadup")
