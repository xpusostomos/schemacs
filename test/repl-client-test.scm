;;-------------------------------------------------------------
;; What is still schemacs' in the client
;;
;; **THE CLIENT ITSELF IS NOT.** The socket, the prompt, the answer-to-an-error
;; test and the two threads of an interactive session were the same code in
;; scheme-shell, so they are `(scheme-utils repl client)' now, and that module's
;; suite tests them: a nested prompt is an error, a value ending in `>' is not
;; mistaken for one, a connection that ends before a prompt answers #f, an
;; instance that does not answer is skipped.
;;
;; What this file tested *most* of - the port file convention, and reading a
;; port out of a file a dead editor left behind - is gone with the transport:
;; a socket's name is its address, and whether it answers is settled by
;; connecting.
;;
;; Two things are left that the shared module cannot know, and they are what is
;; tested here:
;;
;;   * what `--remote' puts on the wire: one `find-file', whose name is a string
;;     literal that a quote or a backslash in the name cannot end;
;;   * which editor a bare `--repl' means, which is a policy about THIS
;;     program's runtime directory.
;;
;; `tools/pty-check.py''s `back-door' check drives the real thing end to end: a
;; real editor, a real socket, both halves.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) getcwd getpid mkdir setenv)
 (only (srfi srfi-13) string-contains string-suffix?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (scheme-utils repl server)
       start-repl! stop-repl! repl-name! repl-directory-name! repl-wake!)
 (only (schemacs repl-client) repl-file-expression repl-endpoint))

(test-begin "schemacs_repl_client")

;;-------------------------------------------------------------
;; What `--remote' sends
;;-------------------------------------------------------------

(test-equal "a relative name is expanded against the client's directory"
  (string-append "(find-file \"" (getcwd) "/README.md\")")
  (repl-file-expression "README.md"))

(test-equal "an absolute name is left alone"
  "(find-file \"/etc/hostname\")"
  (repl-file-expression "/etc/hostname"))

(test-equal "a quote in the name cannot end the literal"
  "(find-file \"/tmp/a\\\"b\")"
  (repl-file-expression "/tmp/a\"b"))

(test-equal "nor can a backslash escape what follows"
  "(find-file \"/tmp/a\\\\b\")"
  (repl-file-expression "/tmp/a\\b"))

;;-------------------------------------------------------------
;; Which editor a bare `--repl' means
;;-------------------------------------------------------------
;;
;; A runtime directory of this test's own, so that it cannot look at a real
;; editor's sockets - and so that "nothing is running" is a state a test can
;; arrange at all.
(define dir (string-append "/tmp/schemacs-repl-client-test-"
                           (number->string (getpid))))
(catch #t (lambda () (mkdir dir #o700)) (lambda args #f))
(setenv "XDG_RUNTIME_DIR" dir)
(repl-directory-name! "schemacs-repl-client-test")

(test-assert "no editor running is an error, and not a silent nothing"
  (catch #t (lambda () (repl-endpoint #f "--repl") #f) (lambda args #t)))

(test-assert "naming an editor that is not running says so"
  (catch #t (lambda () (repl-endpoint "work" "--repl") #f) (lambda args #t)))

;; A door of this test's own, so that both answers can be checked against the
;; same one. **A wake that arranges nothing** is what a test host is: there is
;; no loop here to call back into, and a socket that answers is all this needs.
(repl-wake! (lambda (drain) #f))
(repl-name! (lambda () "tested"))
(start-repl!)

(test-assert "a bare --repl takes the only editor there is"
  (let ((path (repl-endpoint #f "--repl")))
    (and (string? path)
         (string-suffix? ".sock" path)
         (string-contains path "tested"))))

(test-assert "and --repl=NAME takes the editor with that name"
  (string-contains (repl-endpoint "tested" "--repl") "tested"))

(test-assert "while a different name is still an error"
  (catch #t (lambda () (repl-endpoint "other" "--repl") #f) (lambda args #t)))

(stop-repl!)

(test-end "schemacs_repl_client")
