;;; check-exports.scm -- every name a library exports should be a name it
;;; *defines*.
;;;
;;; A library that exports a name it never defines loads perfectly well:
;;; the loss only shows up when something *imports* it, as "Unbound
;;; variable" at run time. That is how a scripted splice that removed a
;;; definition went unnoticed here twice in one day - the file read, the
;;; suite ran, and only the one test that happened to use the name failed.
;;;
;;; This reads each `.sld' with Guile's own reader, takes the names out of
;;; its `export' clause, and asks Guile's module system whether the
;;; library defines each of them itself - as opposed to importing it,
;;; which an `export' does not do.
;;;
;;;     tools/check-exports.scm [FILE...]     # the editor libraries by default
;;;
;;; Run it the way the editor is run - `--r7rs' is what makes Guile's
;;; module system look for `.sld' files at all, so without it every
;;; library reports as one that did not load:
;;;
;;;     guile --no-auto-compile --r7rs -L . -s tools/check-exports.scm
;;;
;;; Exit status is 1 when something is exported but not defined.

(use-modules (ice-9 match)
             (ice-9 pretty-print)
             ;; `scandir' is Guile's - the directory list the file search
             ;; needs - along with the module system this asks.
             (ice-9 ftw))

(define (library-files)
  (if (null? (cdr (command-line)))
      ;; `schemacs/apps' is the retiring legacy layer, and has names
      ;; exported that nothing defines - pre-existing, and its own
      ;; business. Name it explicitly to look at it:
      ;;     tools/check-exports.scm schemacs/apps/debugui.sld
      ;; The UI directories are walked too: the toolkit libraries moved
      ;; there when they stopped being `(schemacs editor ...)'
      ;; (`schemacs/ui/gtk' and `schemacs/ui/ncurses').
      (let loop ((dirs '("schemacs/editor" "schemacs/ui/gtk" "schemacs/ui/ncurses"))
                 (acc '()))
        (if (null? dirs)
            (reverse acc)
            (loop (cdr dirs)
                  (append (reverse
                           (map (lambda (name) (string-append (car dirs) "/" name))
                                (scandir (car dirs)
                                         (lambda (n)
                                           (and (string-suffix? ".sld" n)
                                                (not (string=? "." n))
                                                (not (string=? ".." n)))))))
                          acc))))
      (cdr (command-line))))

(define (exported-names form)
  ;; The names an `export' clause exports, as pairs of the name an
  ;; importer sees and the name that has to be defined here. For a plain
  ;; name the two are the same; for `(rename (INNER OUTER))' the importer
  ;; sees OUTER and the *library* must define INNER.
  (let loop ((clauses (cdr form)) (acc '()))
    (cond
     ((null? clauses) (reverse acc))
     ((and (pair? (car clauses)) (eq? 'export (car (car clauses))))
      (loop (cdr clauses)
            (append (reverse
                     (map (lambda (item)
                            (if (and (pair? item) (eq? 'rename (car item)))
                                (cons (cadr (cadr item)) (car (cadr item)))
                                (cons item item)))
                          (cdr (car clauses))))
                    acc)))
     (else (loop (cdr clauses) acc)))))

(define (bound-in? module name depth)
  ;; Whether NAME is bound in MODULE or in something MODULE uses - a
  ;; library may export a name it imported, which is a re-export rather
  ;; than a mistake. DEPTH bounds the search, because modules use each
  ;; other in cycles.
  ;;--------------------------------------------------------------
  (let ((var (module-local-variable module name)))
    (cond
     ((and var (variable-bound? var)) #t)
     ((<= depth 0) #f)
     (else (let loop ((uses (module-uses module)))
             (cond ((null? uses) #f)
                   ((bound-in? (car uses) name (- depth 1)) #t)
                   (else (loop (cdr uses)))))))))

(define (report file)
  ;; Whether something in FILE is exported but not defined there.
  ;;--------------------------------------------------------------
  (let* ((form (call-with-input-file file read))
         (name (cadr form))
         (exports (exported-names form))
         ;; `resolve-interface' *loads* the library, which
         ;; `resolve-module' alone does not - and a library that cannot
         ;; be loaded is worth reporting too.
         (module (begin (false-if-exception (resolve-interface name))
                        (false-if-exception (resolve-module name #:ensure #f)))))
    (cond
     ((not module) (list file (list 'did-not-load)))
     (else
      (let loop ((names exports) (missing '()))
        (cond
         ((null? names)
          (and (pair? missing) (list file (reverse missing))))
         ;; The name has to be *bound* in the module. Guile answers a
         ;; variable even for a name no definition ever made - its value
         ;; is then `#<undefined>' - so `module-local-variable' alone
         ;; would say yes to everything, which is how the first version of
         ;; this check missed the very thing it was written for.
         ((bound-in? module (cdr (car names)) 3)
          (loop (cdr names) missing))
         (else (loop (cdr names) (cons (car names) missing)))))))))

(let loop ((files (library-files)) (bad 0))
  (cond
   ((null? files)
    (if (zero? bad)
        (begin (display "ok: every exported name is defined by the library that exports it\n")
               (exit 0))
        (begin (display (string-append
                         "\nA name exported but never defined loads, and fails only when\n"
                         "something imports it. Check what removed the definition.\n"))
               (exit 1))))
   (else
    (let ((result (report (car files))))
      (when result
        (set! bad (+ 1 bad))
        (display (car result)) (display ":\n")
        (for-each (lambda (n) (display "    ") (write n) (newline)) (cadr result)))
      (loop (cdr files) bad)))))
