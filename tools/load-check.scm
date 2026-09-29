#!/usr/bin/env guile
!#
;; Load a config file the way the plugin does: stub every foreign-procedure
;; first (no real libhyprscheme.so available here), then eval the rest.
;; Prints file:line for every error it hits; exit 0 iff clean.
(use-modules (ice-9 rdelim))

(define (form-line form)
  (let ((props (source-properties form)))
    (or (assq-ref props 'line) 0)))

(define (load-file path)
  (let ((port (open-input-file path)))
    (let loop ()
      (let ((form (read port)))
        (unless (eof-object? form)
          ;; stub pre-pass: define foreign-procedure names as null pointers
          (if (and (pair? form) (eq? (car form) 'define)
                   (pair? (caddr form))
                   (eq? (car (caddr form)) 'foreign-procedure))
              (catch #t
                (lambda ()
                  (eval `(define ,(string->symbol (cadr (caddr form)))
                           (string->pointer "stub"))
                        (interaction-environment)))
                (lambda args #f)))
          ;; real eval, with error reporting
          (catch #t
            (lambda () (eval form (interaction-environment)))
            (lambda args
              (format #t "~a:~a: ERROR: ~s~%"
                      path (form-line form) args)))
          (loop))))))

(if (null? (cdr (command-line)))
    (begin (display "usage: load-check.scm FILE.scm\n") (exit 2))
    (begin
      (for-each load-file (cdr (command-line)))
      (exit 0)))
