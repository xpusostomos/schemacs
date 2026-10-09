(define-library (schemacs bitwise)
  (import (scheme base))
  (cond-expand
    ((or guile (library (srfi 60)))
     (import
       (only (srfi 60)
             bit-set?  copy-bit
             logior  logand  logxor logbit?
             bitwise-ior  bitwise-and  bitwise-xor
             arithmetic-shift
             ))
     )
    (gambit
     ;; do nothing: SRFI 60 APIs are built-in to Gambit,
     ;; but the library (srfi 60) is not provided.
     )
    (chez
     (import (srfi 151))
     )
    ((or chibi stklos lispkit
         (library (srfi 151))
         (library (scheme bitwise))
         )
     (import
       (only (srfi 151)
             bit-set? copy-bit
             bitwise-ior  bitwise-and  bitwise-xor  bitwise-not
             arithmetic-shift
             ))
     (begin
       (define logbit? bit-set?)
       (define lognot  bitwise-not)
       (define logand  bitwise-and)
       (define logior  bitwise-ior)
       (define logxor  bitwise-xor)
       )))
  (cond-expand
    (mit
     (export)
     )
    (guile
     ;; Guile BUG? Try commenting out this (guile ...) condition.
     ;; Even if you do, Guile does not evaluate "else" condition
     ;; below, although it should. This (guile ...) condition is a
     ;; copy of the (else ...) condition below pasted here since
     ;; Guile's `COND-EXPAND` implementation seems to not be working
     ;; according to spec. The `COND-EXPAND` implementation used in
     ;; `DEFINE-LIBRARY` seems to be broken, but the `COND-EXPAND`
     ;; implementation used elsewhere in Guile works just fine.
     (export
      bit-set?  logbit?  copy-bit
      logior  logand  logxor
      bitwise-ior  bitwise-and  bitwise-xor
      arithmetic-shift
      ))
    (else
     (export
      bit-set?  logbit?  copy-bit
      logior  logand  logxor
      bitwise-ior  bitwise-and  bitwise-xor
      arithmetic-shift
      ))))
