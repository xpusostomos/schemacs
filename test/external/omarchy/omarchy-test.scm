;; `omarchy.el`'s font-height logic and the two options it reads, ported
;; from upstream's `test/omarchy-test.el' (which arrived with the daemon
;; font-size fix, "never take the default face height from a
;; non-graphical frame").
;;
;; **The Elisp stubs `face-attribute', `set-face-attribute' and
;; `font-family-list' with `cl-letf'; this suite drives the real face
;; store instead.** There is one frame's worth of faces here, and the
;; frame argument is accepted and not consulted, so `#f' for FRAME reads
;; and writes the same values the Elisp stubs were pretending to.
;;
;; The graphical-frame branches need a frame with a font driver, which a
;; batch script has not got; they were driven on a Gtk frame by hand
;; (height 113 preserved, a poisoned 1 repaired to the fallback). What
;; is here is every branch that a terminal can reach.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (only (schemacs faces)
              set-face-attribute face-attribute *window-system*)
        (only (schemacs editfns) *message-log-function*)
        (only (schemacs external omarchy omarchy)
              *omarchy-font-height* *omarchy-fallback-font-height*
              omarchy-apply-font))

(test-begin "schemacs_external_omarchy")

(define omarchy-module (resolve-module '(schemacs external omarchy omarchy)))

(define (omarchy--private name)
  ;; `module-ref', not `@@': the name is a run-time value here, and `@@'
  ;; takes its name as syntax.
  (module-ref omarchy-module name))

(define (set-private! name value)
  (module-set! omarchy-module name value))

(define (reset-font-state!)
  (set-private! 'omarchy--warned-unusable-height #f)
  (set-private! 'omarchy--pending-font #f))

(define (sane-height-p height)
  ((omarchy--private 'omarchy--sane-height-p) height))

(define (resolve-font-height frame . optional)
  (apply (omarchy--private 'omarchy--resolve-font-height) frame optional))

(define (repair-default-height)
  ((omarchy--private 'omarchy--repair-default-height)))

;;------------------------------------------------------------------
;; omarchy--sane-height-p
;;------------------------------------------------------------------

(test-equal #f (sane-height-p 1))
(test-equal #f (sane-height-p 'unspecified))
(test-equal #f (sane-height-p 19))
(test-equal #t (sane-height-p 20))
(test-equal #t (sane-height-p 120))

;;------------------------------------------------------------------
;; omarchy--resolve-font-height - the first of HEIGHT, the custom and
;; the current height wins, in that order.
;;------------------------------------------------------------------

(reset-font-state!)
(set-face-attribute 'default #f ':height 140)

;; an explicit HEIGHT overrides both
(parameterize ((*omarchy-font-height* 130))
  (test-equal 150 (resolve-font-height #f 150)))

;; `omarchy-font-height' overrides the height in effect
(parameterize ((*omarchy-font-height* 130))
  (test-equal 130 (resolve-font-height #f)))

;; a usable current height is preserved, and nothing warns
(let ((messages 0))
  (parameterize ((*omarchy-font-height* #f)
                 (*message-log-function*
                  (lambda (text) (set! messages (+ messages 1)))))
    (test-equal 140 (resolve-font-height #f))
    (test-equal 0 messages)))

;; a poisoned one falls back to 110 and warns exactly once
(reset-font-state!)
(set-face-attribute 'default #f ':height 1)
(let ((messages 0))
  (parameterize ((*omarchy-font-height* #f)
                 (*message-log-function*
                  (lambda (text) (set! messages (+ messages 1)))))
    (test-equal 110 (resolve-font-height #f))
    (test-equal 110 (resolve-font-height #f))
    (test-equal 1 messages)))
(test-assert (omarchy--private 'omarchy--warned-unusable-height))

;; `omarchy-fallback-font-height' controls the value used
(reset-font-state!)
(parameterize ((*omarchy-fallback-font-height* 90))
  (test-equal 90 (resolve-font-height #f)))

;;------------------------------------------------------------------
;; omarchy-apply-font with no graphical frame
;;
;; The font is queued for the first client frame, as upstream's does.
;; Emacs also adds `omarchy--apply-pending-font' to
;; `server-after-make-frame-hook'; this tree has no daemon and no such
;; hook, so there is nothing to add it to and no hook to assert on.
;;------------------------------------------------------------------

(reset-font-state!)
(set-face-attribute 'default #f ':height 140)
(parameterize ((*window-system* #f))
  (omarchy-apply-font "X")
  (test-equal (cons "X" #f) (omarchy--private 'omarchy--pending-font))
  ;; nothing was applied
  (test-equal 140 (face-attribute 'default ':height #f)))

;; a poisoned height is not repaired without a graphical frame either
(reset-font-state!)
(set-face-attribute 'default #f ':height 1)
(parameterize ((*window-system* #f))
  (repair-default-height)
  (test-equal 1 (face-attribute 'default ':height #f)))

(test-end "schemacs_external_omarchy")
