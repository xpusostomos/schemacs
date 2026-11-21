(use-modules (schemacs editor cc-langs) (schemacs editor cc-defs) (ice-9 rdelim) (schemacs editor chartab))
(define (hex s)
  (let loop ((cs (string->list s)) (out ""))
    (if (null? cs) out
        (loop (cdr cs) (string-append out " " (number->string (char->integer (car cs)) 16))))))
(define (nrm x)
  (cond
   ((not x) "(NIL)")
   ((eq? x #t) "(T)")
   ((string? x) (string-append "(S" (hex x) ")"))
   ((symbol? x) (string-append "(Y " (symbol->string x) ")"))
   ((char? x) (string-append "(I " (number->string (char->integer x)) ")"))
   ((integer? x) (string-append "(I " (number->string x) ")"))
   ((number? x) (string-append "(F " (number->string x) ")"))
   ((null? x) "(NIL)")
   ((pair? x) (string-append "(L"
                             (let loop ((l x) (out ""))
                               (if (pair? l)
                                   (loop (cdr l) (string-append out " " (nrm (car l))))
                                   (if (null? l) out
                                       (string-append out " . " (nrm l)))))
                             ")"))
   ((vector? x) (string-append "(VEC " (number->string (vector-length x)) ")"))
   ((procedure? x) "(FN)")
   ((char-table? x) "(CT)")
   (else "(OTHER)")))
(define langs '(c c++ objc java idl pike awk))
(define names (call-with-input-file "/tmp/ccnames.txt"
                (lambda (p) (let loop ((l (read-line p)) (acc '()))
                              (if (eof-object? l) (reverse acc)
                                  (loop (read-line p) (cons l acc)))))))
(with-output-to-file "/tmp/ours-vals.txt"
  (lambda ()
    (for-each
     (lambda (name)
       (let ((sym (string->symbol name)))
         (for-each
          (lambda (lang)
            (let ((mode (string->symbol (string-append (symbol->string lang) "-mode"))))
              (display name) (display "\t") (display lang) (display "\t")
              (display (catch #t
                         (lambda () (nrm (c-get-lang-constant sym #f mode)))
                         (lambda (k . args) "(ERR)")))
              (newline)))
          langs)))
     names)))
