#!/usr/bin/env guile
!#
;; Fontify files the way a display does, and report what breaks.
;;
;; The Groovy crash of 2026-11-27 ("Invalid search bound (wrong side of
;; point)") only appeared through jit-lock's *chunked* fontification,
;; after a C-family buffer had been visited.  A whole-buffer
;; `font-lock-ensure` did not see it.  This harness recreates that
;; sequence: enter c-mode once (the buffer-local state a real session
;; has), then for each file visit it and fontify it in 1500-character
;; jit-lock chunks, catching every error and naming the file and chunk.
;;
;;     tools/font-lock-sweep.scm FILE...
;;
;; Output is one line per file ("ok" or the errors), then a summary.
;; Exit status 1 if any file had an error.

(import
 (scheme base)
 (scheme write)
 (only (guile) program-arguments)
 (only (schemacs buffer)
       allocate-buffer set-buffer current-buffer get-buffer-create
       buffer-name erase-buffer)
 (only (schemacs editfns) insert point-max point-min)
 (only (schemacs files) find-file-noselect)
 (only (schemacs font-core) font-lock-mode)
 (only (schemacs jit-lock) jit-lock-fontify-now)
 (only (schemacs frame) new-frame *current-frame*)
 (only (schemacs dispnew) current-display)
 (only (oop goops) make)
 (only (schemacs test-display) <test-display>)
 (only (schemacs progmodes cc-mode) c-mode))

(define (report file start e)
  (display "ERROR ")
  (display file)
  (display " chunk ")
  (display start)
  (display ": ")
  (if (error-object? e)
      (begin (display (error-object-message e))
             (display " ")
             (write (error-object-irritants e)))
      (write e))
  (newline))

(define (fontify-file path)
  (define errors 0)
  (guard (e (#t (report path 0 e) (set! errors (+ errors 1)) #f))
    (let ((b (find-file-noselect path)))
      (if (not b)
          (begin (report path 0 "find-file-noselect answered #f")
                 (set! errors (+ errors 1)))
          (begin
            (set-buffer b)
            (guard (e (#t (report path 0 e)
                          (set! errors (+ errors 1)) #f))
              (font-lock-mode 1))
            (let ((z (point-max)))
              (let loop ((start (point-min)))
                (when (<= start z)
                  (guard (e (#t (report path start e)
                                (set! errors (+ errors 1)) #f))
                    (jit-lock-fontify-now
                     start (min z (+ start 1500))))
                  (loop (+ start 1500)))))))))
  errors)

(define (main args)
  (current-display (make <test-display>))
  ;; "A real session has visited a C-family buffer": this is what made
  ;; `c-font-lock-init`'s delq matter, and it is the state the Groovy
  ;; crash needed.
  (let ((c (allocate-buffer)))
    (set-buffer c)
    (insert "int x;\n")
    (let ((f (new-frame c 24 80)))
      (parameterize ((*current-frame* f))
        (c-mode))))
  (let ((files (cdr args))
        (bad 0))
    (for-each
     (lambda (path)
       (let ((n (fontify-file path)))
         (if (= n 0)
             (begin (display "ok ") (display path) (newline))
             (set! bad (+ bad 1)))))
     files)
    (display (length files))
    (display " files, ")
    (display bad)
    (display " with errors")
    (newline)
    (if (> bad 0) 1 0)))

(exit (main (program-arguments)))
