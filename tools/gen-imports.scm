#!/usr/bin/env guile
!#
;;; Generate `schemacs/editor/imports.scm` - the `(schemacs editor
;;; imports)` library, which is the whole editor under one name.
;;;
;;; Why it exists, in Chris's words: "what I would want is he has one line
;;; to include all the default editor components, and then a relatively
;;; simple list of what other things to import." So a user's
;;; `imports.scm` says
;;;
;;;     (import (schemacs editor imports))     ; the whole editor
;;;     (import (my-utils))                    ; and whatever else
;;;
;;; and that one line is this library.
;;;
;;; **The export list is generated and not written by hand**, which is
;;; the point of this file: 1700-odd names across sixty libraries, and a
;;; hand-written list would be wrong within a week. Re-run this after
;;; adding a library or an export:
;;;
;;;     guile -L . -s tools/gen-imports.scm
;;;
;;; and `loadup-tests.scm` fails if the file on disk is not what this
;;; would write - the same rule the editor's library list lives under.
;;;
;;; Both sides use Guile's reader rather than a hand-rolled matcher, for
;;; the reason `tools/save-excursion-audit.py` records: a matcher that
;;; miscounts a paren reports nonsense with confidence.

(import (scheme base) (scheme file) (scheme write) (ice-9 match)
        (only (guile) sort))

(define root
  (let ((d (dirname (dirname (current-filename)))))
    d))

(define editor-dir (string-append root "/schemacs/editor"))

;; The one file not to include: this library itself. Everything else in
;; `schemacs/editor' is part of the editor, and a user's environment wants
;; all of it - `loadup' included, since it holds the library list and the
;; environment builder.
(define (library-file? name)
  (and (string-suffix? ".scm" name)
       (not (string-suffix? "-tests.scm" name))
       (not (string=? name "imports.scm"))))

(define (read-all-from path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((acc '()))
        (let ((form (read p)))
          (if (eof-object? form) (reverse acc) (loop (cons form acc))))))))

(define (directory-entries dir)
  (let ((d (opendir dir)))
    (let loop ((acc '()))
      (let ((name (readdir d)))
        (if (eof-object? name)
            (begin (closedir d) (sort acc string<?))
            (loop (cons name acc)))))))

(define (declaration decls kind)
  (let loop ((rest decls))
    (cond ((null? rest) #f)
          ((and (pair? (car rest)) (eq? (car (car rest)) kind)) (car rest))
          (else (loop (cdr rest))))))

;; The library's name and the names it exports, as the reader sees them.
(define (library-of path)
  (let ((form (let loop ((rest (read-all-from path)))
                (cond ((null? rest) #f)
                      ((and (pair? (car rest)) (eq? (car (car rest)) 'define-library))
                       (car rest))
                      (else (loop (cdr rest)))))))
    (and form
         (let* ((name (cadr form))
                (decls (cddr form))
                (export (declaration decls 'export)))
           (and export
                (cons name
                      (map (lambda (item)
                             ;; `(rename (internal external))' exports the
                             ;; second name.
                             (if (and (pair? item) (eq? (car item) 'rename))
                                 (cadr (cadr item))
                                 item))
                           (cdr export))))))))

(define libraries
  (let loop ((names (directory-entries editor-dir)) (acc '()))
    (cond ((null? names) (reverse acc))
          ((library-file? (car names))
           (let ((lib (library-of (string-append editor-dir "/" (car names)))))
             (loop (cdr names) (if lib (cons lib acc) acc))))
          (else (loop (cdr names) acc)))))

;; One name once: `simple' re-exports what `cmds' owns - a name is
;; exported by two libraries and is the *same* binding - so the union is
;; what belongs in the export list.
(define all-names
  (let ((seen (make-hash-table)) (out '()))
    (for-each
     (lambda (lib)
       (for-each (lambda (n)
                   (unless (hashq-ref seen n)
                     (hashq-set! seen n #t)
                     (set! out (cons n out))))
                 (cdr lib)))
     libraries)
    (sort out (lambda (a b) (string<? (symbol->string a) (symbol->string b))))))

;; A name two libraries both export - `simple' re-exports what `cmds'
;; owns, `files' re-exports `buffer''s `kill-buffer' - is one binding
;; offered twice, and importing both libraries at once makes Guile warn
;; "imported from both". The first library (in the sorted order below)
;; keeps the name and the others `except' it: the union is the same, and
;; the warning goes. **A name two libraries export with *different*
;; bindings is not this**, and would be silently resolved by it - so
;; `loadup-tests.scm' checks every one of these is a single binding, and
;; fails when it is not.
(define (lib< a b)
  (string<? (symbol->string (cadr a)) (symbol->string (cadr b))))

(define sorted-libraries (sort libraries lib<))

(define excepted
  (let ((owner (make-hash-table)))
    ;; the first library, in the order the import list is written, owns it
    (for-each (lambda (lib)
                (for-each (lambda (n)
                            (unless (hashq-ref owner n)
                              (hashq-set! owner n (car lib))))
                          (cdr lib)))
              sorted-libraries)
    (let loop ((rest sorted-libraries) (out '()))
      (if (null? rest)
          (reverse out)
          (let* ((lib (car rest))
                 (names (let keep ((ns (cdr lib)) (acc '()))
                          (cond ((null? ns) (reverse acc))
                                ((eq? (hashq-ref owner (car ns)) (car lib))
                                 (keep (cdr ns) acc))
                                (else (keep (cdr ns) (cons (car ns) acc)))))))
            (loop (cdr rest)
                  (if (pair? names) (cons (cons (car lib) names) out) out)))))))

(define (render)
  (let ((port (open-output-string)))
    (define (line . parts) (for-each (lambda (p) (display p port)) parts) (newline port))
    (line ";; -*- mode: scheme; coding: utf-8 -*-")
    (line ";;")
    (line ";; `(schemacs editor imports)' - the whole editor under one name.")
    (line ";;")
    (line ";; **Generated by `tools/gen-imports.scm'. Do not edit by hand** -")
    (line ";; re-run it instead:")
    (line ";;")
    (line ";;     guile -L . -s tools/gen-imports.scm")
    (line ";;")
    (line ";; What this is for. GNU Emacs has one obarray, so a name is reachable")
    (line ";; from anywhere - which is why an init file can `(setq")
    (line ";; inhibit-startup-screen t)' with no `require', why `M-:' can evaluate")
    (line ";; anything, and why a REPL into a running Emacs finds every command.")
    (line ";; This tree's names live one library per Emacs file, and a module holds")
    (line ";; none of them until it imports them. This library is the one name that")
    (line ";; stands for all of them:")
    (line ";;")
    (line ";;     (import (schemacs editor imports))")
    (line ";;")
    (line ";; **The editor itself never imports this**, deliberately: the rule that a")
    (line ";; name lives in the file its Emacs source lives in only holds if every")
    (line ";; library says what it uses. This is for the three places where there is")
    (line ";; no import to write - a REPL prompt, a typed expression, and the user's")
    (line ";; own `imports.scm' - which `(schemacs editor loadup)' builds.")
    (newline port)
    (line "(define-library (schemacs editor imports)")
    (line "  (import")
    (for-each
     (lambda (lib)
       (let ((ex (assoc lib excepted)))
         (if ex
             (line "    (except " (write-to-string lib) " "
                   (apply string-append
                          (map (lambda (n) (string-append " " (symbol->string n)))
                               (cdr ex)))
                   ")")
             (line "    " (write-to-string lib)))))
     (map car sorted-libraries))
    (line "    )")
    (line "  (export")
    (for-each (lambda (n) (line "    " n)) all-names)
    (line "    ))")
    (get-output-string port)))

(define (write-to-string x)
  (let ((p (open-output-string))) (write x p) (get-output-string p)))

(define (out-path) (string-append editor-dir "/imports.scm"))

(define rendered (render))

(cond
 ((and (pair? (cdr (command-line))) (string=? (cadr (command-line)) "--check"))
  (let ((existing (and (file-exists? (out-path))
                       (call-with-input-file (out-path)
                         (lambda (p)
                           (let loop ((acc '()))
                             (let ((l (read-line p)))
                               (if (eof-object? l)
                                   (apply string-append (reverse acc))
                                   (loop (cons (string-append l "\n") acc))))))))))
    (if (equal? existing rendered)
        (begin (display "imports.scm is up to date\n") (exit 0))
        (begin (display "imports.scm is NOT what the generator writes\n")
               (exit 1)))))
 (else
  (call-with-output-file (out-path)
    (lambda (p) (display rendered p)))
  (display (string-append "wrote " (out-path) ": "
                          (number->string (length libraries)) " libraries, "
                          (number->string (length all-names)) " names\n"))))
