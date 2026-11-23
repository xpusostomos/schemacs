#!/usr/bin/env guile
!#
;;; convert-theme.scm --- convert an Emacs `etc/themes/*.el' theme
;;;
;;; This tree's themes are Scheme (`schemacs/themes/NAME-theme.scm'):
;;; `define-theme' instead of `deftheme', and `custom-theme-set-faces'
;;; taking the *evaluated* spec lists - which is what the Elisp
;;; backquote builds when the file loads.
;;;
;;; The plain-data themes are not code in any interesting sense: a
;;; `deftheme' with a docstring and a property list, a `let' binding the
;;; display class and any named palette, one `custom-theme-set-faces'
;;; whose arguments are all backquoted lists, and `provide-theme'. This
;;; reads that subset, evaluates it in a tiny environment of its own -
;;; no `eval' of arbitrary code - and writes the tree's shape.
;;;
;;;     guile -L . -s tools/convert-theme.scm SRC.el DEST.scm
;;;     guile -L . -s tools/convert-theme.scm --all DIR [OUTDIR]
;;;
;;; `--all' converts every `-theme.el' in DIR it can and names the ones
;;; it cannot. The files it cannot are the generated modus-* themes
;;; (`modus-themes-with-colors' is a compiler, not data), leuven (whose
;;; face list is built by a `defun' over `seq-filter'), and
;;; newcomers-presets (real conditional code). Converting those means
;;; porting their engines, which is a different job.
;;;
;;; **What is deliberately not carried**: `custom-theme-set-variables'
;;; (none of the plain themes use one), and top-level forms other than
;;; the four below are ignored with a note on stderr - `make-obsolete'
;;; is the only one in this set.
;;;
;;; The evaluator reads the Elisp with Scheme's reader, which works
;;; because the subset is reader-compatible: `\`' and `,' and `,@' are
;;; the same syntax, `quote' is written out by the reader, and none of
;;; these files uses `?c' characters, `#' or vectors. Elisp's `t' and
;;; `nil' are bound in the environment; attribute values must become
;;; `#t'/`#f', because this tree's face code treats `'()' as true
;;; exactly where Elisp's nil is false (`realize-tty-face`'s
;;; `(and reverse #t)`, for one). That is why `nil' is `#f' here and not
;;; the empty list.

(import (scheme base)
        (scheme write)
        (only (srfi srfi-1) filter find)
        (only (guile) sort opendir readdir closedir command-line exit
              string-prefix? string-rindex with-output-to-string))

;;------------------------------------------------------------------
;; A tiny evaluator for the theme subset
;;
;; ENV is an alist of (SYMBOL . VALUE), innermost binding first.
;;------------------------------------------------------------------

(define (lookup name env)
  (cond ((assq name env) => cdr)
        ;; A keyword self-evaluates, as Elisp's does. Nothing evaluates
        ;; one in this subset, but the reader hands one over unchanged
        ;; if it ever appears at a head position.
        ((and (symbol? name)
              (> (string-length (symbol->string name)) 0)
              (char=? #\: (string-ref (symbol->string name) 0)))
         name)
        ((eq? name 't) #t)
        ((eq? name 'nil) #f)
        (else (error "Unbound variable in theme file" name))))

(define (ev form env)
  (cond
   ((symbol? form) (lookup form env))
   ((not (pair? form)) form)        ; string, number, boolean, ()
   (else
    (case (car form)
      ((quote) (cadr form))
      ((quasiquote) (qq (cadr form) env 1))
      ((unquote) (error "Unquote outside quasiquote"))
      ((let)
       (let* ((bindings (cadr form))
              (new (append
                    ;; Elisp's `let' evaluates every binding in the
                    ;; outer scope, which is Scheme's too.
                    (map (lambda (b) (cons (car b) (ev (cadr b) env)))
                         bindings)
                    env)))
         (ev-body (cddr form) new)))
      ((let*)
       (let loop ((bindings (cadr form)) (new env))
         (if (null? bindings)
             (ev-body (cddr form) new)
             (loop (cdr bindings)
                   (cons (cons (caar bindings) (ev (cadar bindings) new))
                         new)))))
      ((if) (if (ev (cadr form) env)
                (ev (caddr form) env)
                (if (null? (cdddr form)) #f (ev (cadddr form) env))))
      ((when) (if (ev (cadr form) env) (ev-body (cddr form) env) #f))
      ((unless) (if (ev (cadr form) env) #f (ev-body (cddr form) env)))
      ((and)
       (let loop ((l (cdr form)) (v #t))
         (if (null? l) v
             (let ((v (ev (car l) env)))
               (if v (loop (cdr l) v) #f)))))
      ((or)
       (let loop ((l (cdr form)))
         (if (null? l) #f
             (let ((v (ev (car l) env)))
               (if v v (loop (cdr l)))))))
      ((cond)
       (let loop ((clauses (cdr form)))
         (cond ((null? clauses) #f)
               ((eq? (caar clauses) 'else) (ev-body (cdar clauses) env))
               ((ev (caar clauses) env) (ev-body (cdar clauses) env))
               (else (loop (cdr clauses))))))
      ((begin) (ev-body (cdr form) env))
      ;; The theme forms. `deftheme' and `provide-theme' are recorded;
      ;; `custom-theme-set-faces' evaluates its specs and records them.
      ((deftheme)
       (let* ((name (cadr form))
              (doc (caddr form))
              (props (cdddr form)))
         (cons 'deftheme
               (cons name
                     (cons doc
                           (let loop ((rest props) (out '()))
                             (if (null? rest)
                                 (reverse out)
                                 (loop (cddr rest)
                                       (cons (ev (cadr rest) env)
                                             (cons (car rest) out))))))))))
      ((custom-theme-set-faces)
       (let ((theme (ev (cadr form) env)))
         (cons 'faces
               (cons theme
                     (map (lambda (spec) (ev spec env)) (cddr form))))))
      ((provide-theme)
       (list 'provide (ev (cadr form) env)))
      ((make-obsolete)
       ;; A warning at load time in Emacs; nothing here consults it.
       (display "note: ignoring make-obsolete\n" (current-error-port))
       '(ignored))
      (else
       (error "Unsupported form in theme file" (car form)))))))

(define (ev-body body env)
  (let loop ((l body) (v #f))
    (if (null? l) v (loop (cdr l) (ev (car l) env)))))

(define (qq form env depth)
  (cond
   ((not (pair? form)) form)
   ((eq? (car form) 'unquote)
    (if (= depth 1)
        (ev (cadr form) env)
        (list 'unquote (qq (cadr form) env (- depth 1)))))
   ((eq? (car form) 'quasiquote)
    (list 'quasiquote (qq (cadr form) env (+ depth 1))))
   ((and (pair? (car form))
         (eq? (caar form) 'unquote-splicing)
         (= depth 1))
    (append (ev (cadar form) env)
            (qq (cdr form) env depth)))
   (else
    (cons (qq (car form) env depth) (qq (cdr form) env depth)))))

;;------------------------------------------------------------------
;; Reading and writing
;;------------------------------------------------------------------

(define (read-all path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (reverse acc)
              (loop (cons form acc))))))))

(define (evaluate-theme-file path)
  (let loop ((forms (read-all path)) (out '()))
    (if (null? forms)
        (reverse out)
        (let ((v (ev (car forms) '())))
          (loop (cdr forms)
                (if (and (pair? v) (memq (car v) '(deftheme faces provide)))
                    (cons v out)
                    out))))))

(define (basename path)
  (let ((slash (string-rindex path #\/)))
    (if slash (substring path (+ 1 slash) (string-length path)) path)))

(define (write-doc doc port)
  ;; A docstring as a literal with real newlines, the way the hand-
  ;; written wombat file has it: easier to read in the file than `\n'
  ;; escapes, and the same string when read back.
  (display "\"" port)
  (let loop ((i 0))
    (when (< i (string-length doc))
      (let ((c (string-ref doc i)))
        (cond ((char=? c #\") (display "\\\"" port))
              ((char=? c #\\) (display "\\\\" port))
              (else (display c port)))
        (loop (+ i 1)))))
  (display "\"" port))

(define (emit theme path)
  (let ((deftheme (and (pair? theme) (car theme)))
        (faces (filter (lambda (f) (eq? (car f) 'faces)) theme))
        (provides (filter (lambda (f) (eq? (car f) 'provide)) theme)))
    (unless deftheme
      (error "No `deftheme' in" path))
    (call-with-output-file path
      (lambda (port)
        (display ";;; " port)
        (display (basename path) port)
        (display " --- converted from GNU Emacs's etc/themes\n" port)
        (display ";; Generated by tools/convert-theme.scm; do not edit by hand.\n"
                 port)
        (newline port)
        ;; **The file imports what it uses.** `load-theme` reads a theme
        ;; with `load`, which evaluates it in whatever module is current;
        ;; `define-theme`, `custom-theme-set-faces` and `provide-theme`
        ;; are `(schemacs theme)`'s. Without this line a theme
        ;; loads only where those names happen to be imported already -
        ;; the hand-written test theme in `custom-tests.scm' has the same
        ;; line for the same reason.
        (display "(import (schemacs theme))" port)
        (newline port)
        (newline port)
        ;; (deftheme NAME DOC PROP VALUE ...)
        (display "(define-theme " port)
        (write (cadr deftheme) port)
        (newline port)
        (display "  " port)
        (write-doc (caddr deftheme) port)
        (newline port)
        (display "  (" port)
        (let loop ((rest (cdddr deftheme)) (first #t))
          (when (pair? rest)
            (unless first (display " " port))
            (write (car rest) port)
            (display " " port)
            (write (cadr rest) port)
            (loop (cddr rest) #f)))
        (display "))" port)
        (newline port)
        (newline port)
        (for-each
         (lambda (f)
           (let ((theme-name (cadr f))
                 (specs (cddr f)))
             (display "(custom-theme-set-faces" port)
             (newline port)
             (display " '" port)
             (write theme-name port)
             (newline port)
             (for-each (lambda (spec)
                         (display " '" port)
                         (write spec port)
                         (newline port))
                       specs)
             (display ")" port)
             (newline port)
             (newline port)))
         faces)
        (for-each (lambda (f)
                    (display "(provide-theme '" port)
                    (write (cadr f) port)
                    (display ")" port)
                    (newline port))
                  provides)))))

(define (directory-entries dir)
  (let ((d (opendir dir)))
    (let loop ((acc '()))
      (let ((name (readdir d)))
        (if (eof-object? name)
            (begin (closedir d) (sort acc string<?))
            (loop (cons name acc)))))))

(define (theme-file? name)
  (and (string-suffix? "-theme.el" name)
       (not (string-prefix? "." name))))

(define (string-suffix? suffix s)
  (and (>= (string-length s) (string-length suffix))
       (string=? suffix
                 (substring s (- (string-length s) (string-length suffix))
                            (string-length s)))))

(define (condition-text e)
  (or (and (error-object? e) (error-object-message e))
      (with-output-to-string (lambda () (write e)))))

(define (main args)
  (cond
   ((and (pair? args) (string=? (car args) "--all"))
    (let* ((dir (cadr args))
           (out-dir (if (pair? (cddr args)) (caddr args) dir))
           (failed '()))
      (for-each
       (lambda (name)
         (when (theme-file? name)
           (let* ((src (string-append dir "/" name))
                  (out-name (string-append
                             (substring name 0 (- (string-length name) 3))
                             ".scm"))
                  (out (string-append out-dir "/" out-name)))
             (guard (e (else
                        (display "skip " (current-error-port))
                        (display name (current-error-port))
                        (display ": " (current-error-port))
                        (display (condition-text e) (current-error-port))
                        (newline (current-error-port))
                        (set! failed (cons name failed))))
               (emit (evaluate-theme-file src) out)
               (display "wrote " (current-error-port))
               (display out (current-error-port))
               (newline (current-error-port))))))
       (directory-entries dir))
      (unless (null? failed)
        (display "not convertible: " (current-error-port))
        (write (reverse failed) (current-error-port))
        (newline (current-error-port)))))
   ((= (length args) 2)
    (emit (evaluate-theme-file (car args)) (cadr args)))
   (else
    (display "usage: convert-theme.scm SRC.el DEST.scm\n" (current-error-port))
    (display "       convert-theme.scm --all DIR [OUTDIR]\n" (current-error-port))
    (exit 1))))

(main (cdr (command-line)))
