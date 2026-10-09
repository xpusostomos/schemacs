(define-library (schemacs string)
  ;; This library exists to provide a uniform interface to common APIs
  ;; that might be defined in different places depending on which
  ;; Scheme implementation is running this code. APIs exported here
  ;; can be imported exactly once per environment elsehwere in this
  ;; program without having to write a `COND-EXPAND` statement
  ;; everywhere one of these APIs are used.

  (import
    (scheme base))

  (cond-expand
    (guile
     (import (only (srfi 13) string-fold))
     )
    (chibi
     (import (only (chibi string) string-fold))
     )
    (mit 
     (import (only (srfi 140) string-fold))
     )
    ((library (srfi 13))
     (import (only (srfi 13) string-fold))
     )
    ((library (srfi 140))
     (import (only (srfi 140) string-fold))
     )
    (else
     (begin
       (define (string-fold proc accum instr)
         (let ((len (string-length instr)))
           (let loop ((i 0) (accum accum))
             (cond
              ((< i len)
               (loop (+ 1 i) (proc (string-ref instr i) accum))
               )
              (else accum)
              ))))
       )
     ))
  (export
   string-fold
   ))
