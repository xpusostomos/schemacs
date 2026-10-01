#!/usr/bin/env -S guile --no-auto-compile --r7rs -s
!#
;; syntax-check — run Guile's own reader over Scheme files, surface any
;; read error with the reader's own file:line:col.
;;
;; No hand-rolled parser: Guile's reader (read) is the parser. It reports
;; every paren/string/comment error with a position — this wrapper just
;; makes the failure loud and script-friendly (exit 1) so it can gate
;; edits to the machinery files.
;;
;; The reader must be the R7RS one, because the project is R7RS
;; throughout: Guile's default reader misreads a `|sym;with;semicolons|'
;; datum - select.sld's `text/plain;charset=utf-8' selection target is
;; one - and reports a phantom unbalanced paren on a file that loads
;; fine. `guile -s' carries no command-line flags across, so when this
;; script was not started with the flag, it starts itself again with it.
;;
;; Usage: guile -s tools/syntax-check.scm FILE...
;; Exit 0 = every file reads clean; 1 = at least one read error.

(use-modules (ice-9 exceptions))

(define (main files)
  (let ((ok (guard (c (#t #f))
              (for-each check-file files)
              #t)))
    (format #t "~a: (~a files)~%"
            (if ok "ok" "FAILED") (length files))
    (exit (if ok 0 1))))

(define (check-file path)
  (with-exception-handler
      (lambda (e)
        ;; the reader's message carries the file:line:col itself
        (format #t "~a~%" (exception-message e))
        (throw 'syntax-check-failed))
    (lambda ()
      (call-with-input-file path
        (lambda (p)
          (let loop ()
            (let ((form (read p)))
              (unless (eof-object? form)
                (loop)))))))))

(if (getenv "SCHEMACS_SYNTAX_CHECKED")
    (main (cdr (command-line)))
    (begin
      (setenv "SCHEMACS_SYNTAX_CHECKED" "1")
      (exit (status:exit-val
             (apply system*
                    "guile" "--no-auto-compile" "--r7rs" "-s"
                    (car (command-line))
                    (cdr (command-line)))))))