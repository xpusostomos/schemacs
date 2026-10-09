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
 (only (schemacs editor loadup) editor-libraries editor-excluded-libraries
       open-editor-namespace!))

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

(test-end "schemacs_loadup")
