;; A randomised check of the window resize engine - `adjust-window-trailing-edge`
;; over random window trees, in both directions.
;;
;; It exists because the tree's *combination axis* used to be inferred from
;; the children's rectangles, which a combination down to one child cannot
;; answer: a horizontal drag then treated a one-child vertical combination as
;; horizontal, resized a frame-wide window, and died with "Failed adjusting
;; window" - Chris's report. Before the axis was stored this found 1508 such
;; failures in 300 trees; after it, none. Run it after touching
;; `window--resize-*`, `split-window` or the window record:
;;
;;     guile --no-auto-compile -L . -s tools/window-resize-fuzz.scm
;;
;; Exit status is 1 on any failure.
(import (scheme base)
        (only (guile) random string-contains)
        (only (oop goops) make define-class define-method)
        (only (schemacs editor test-display) <test-display>)
        (only (schemacs editor dispnew) current-display window-system-display?
                display-default-scroll-bar-width)
        (only (schemacs editor frame) *current-frame* new-frame
                frame-selected-window window-list window-left window-width
                window-top window-height set-frame-parameter frame-width)
        (only (schemacs editor window) split-window
                adjust-window-trailing-edge)
        (only (schemacs editor buffer) allocate-buffer set-buffer set-point)
        (only (schemacs editor editfns) insert)
        (only (schemacs editor xdisp) render!))

(define-class <win-test-display> (<test-display>))
(define-method (window-system-display? (d <win-test-display>)) #t)
(define-method (display-default-scroll-bar-width (d <win-test-display>)) 18)
(define d (make <win-test-display> #:rows 40 #:columns 120
                #:column-width 9 #:line-height 20))
(current-display d)
(define (pick lst) (and (pair? lst) (list-ref lst (random (length lst)))))
(define (shape f)
  (map (lambda (w) (list (window-left w) (window-top w) (window-width w) (window-height w)))
       (window-list f)))
(define failures 0)

(define (expected-error? message)
  ;; Emacs's own answers for an edge that cannot move - not failures.
  (or (string-contains message "No resizable window")
      (string-contains message "No window on the")
      (string-contains message "No window below")))

(define (check-one f w horizontal delta)
  (guard (e (#t (let ((m (error-object-message e)))
                  (unless (expected-error? m)
                    (set! failures (+ failures 1))
                    (display (list 'FAIL 'shape (shape f)
                                   'window (list (window-left w) (window-top w)
                                                 (window-width w) (window-height w))
                                   'horizontal horizontal
                                   'delta delta 'message m))
                    (newline)))))
    (adjust-window-trailing-edge w delta horizontal #f)))
(let loop ((i 0))
  (when (< i 300)
    (define ed (allocate-buffer))
    (set-buffer ed)
    (insert "hello\nworld\n")
    (set-point ed 1)
    (define f (new-frame ed 40 120))
    (parameterize ((*current-frame* f))
      (render! f)
      (let build ((k 0))
        (when (< k 3)
          (let ((w (pick (window-list f))))
            (guard (e (#t #f))
              (if (= 0 (random 2))
                  (split-window w #f 'right)
                  (split-window w #f 'below))))
          (build (+ k 1))))
      (guard (e (#t #f)) (render! f))
      (for-each
       (lambda (w)
         (for-each
          (lambda (horizontal)
            (for-each
             (lambda (delta)
               (check-one f w horizontal delta))
             '(1 -1 2 -2)))
          '(#t #f)))
       (window-list f))
      (guard (e (#t #f)) (render! f)))
    (loop (+ i 1))))
(display (list 'failures failures)) (newline)
(exit (if (= failures 0) 0 1))
