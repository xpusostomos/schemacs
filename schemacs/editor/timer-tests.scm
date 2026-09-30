;; Tests for `(schemacs editor timer)' - `emacs-lisp/timer.el' and the
;; `timer_check' that runs the timers - and for the cursor visibility the
;; blink turns off and on.
;;
;; Time is involved, so the margins are generous: a test that waits 80ms
;; for a 20ms timer is not measuring the clock, it is measuring "did it
;; run at all". Nothing here asserts a timer fired *exactly* when it was
;; due, because that is not something a loaded machine can promise.
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme char)
 (only (guile) setvbuf usleep)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (prefix (schemacs editor timer) t:)
 ;; `timer_check' is `keyboard.c''s, so the check is `keyboard.sld''s
 (prefix (schemacs editor keyboard) kb:)
 (prefix (schemacs editor frame) fr:)
 (prefix (schemacs editor faces) f:)
 (only (schemacs editor engine) new-text-editor)
 (only (oop goops) make))

(setvbuf (current-output-port) 'none)

(define (wait-ms ms) (usleep (* 1000 ms)))

(define (run-due-timers!)
  ;; `timer-check!' answers whether anything ran; a couple of calls let a
  ;; timer that is due right now settle.
  (let loop ((n 0))
    (when (< n 4)
      (kb:timer-check!)
      (wait-ms 5)
      (loop (+ n 1)))))

(test-begin "schemacs_editor_timer")

;;------------------------------------------------------------------
;; Ordinary timers
;;------------------------------------------------------------------

;; A timer that is not due yet does not run, and one that is due does.
(let ((fired 0))
  (t:run-at-time 0.05 #f (lambda () (set! fired (+ fired 1))))
  (test-equal 0 fired)                  ; not yet
  (test-equal #f (kb:timer-check!))      ; and nothing ran
  (wait-ms 80)
  (test-equal #t (kb:timer-check!))
  (test-equal 1 fired))

;; A timer runs once, not every time it is checked.
(let ((fired 0))
  (t:run-at-time 0.01 #f (lambda () (set! fired (+ fired 1))))
  (wait-ms 30)
  (run-due-timers!)
  (test-equal 1 fired))

;; `run-with-timer' is `run-at-time' with its arguments in the other order,
;; and a repeating one runs again - measured from when it was due, so a
;; timer that came late does not fall further and further behind.
(let ((fired 0))
  (t:run-with-timer 0.01 0.01 (lambda () (set! fired (+ fired 1))))
  (wait-ms 25)
  (run-due-timers!)
  (test-assert (> fired 1)))

;; `cancel-timer' stops it, and cancelling a timer that already ran is not
;; an error - which is what makes a one-shot timer able to cancel itself.
(let ((fired 0))
  (let ((timer (t:run-at-time 0.01 #f (lambda () (set! fired (+ fired 1))))))
    (t:cancel-timer timer)
    (wait-ms 30)
    (run-due-timers!)
    (test-equal 0 fired)
    (t:cancel-timer timer)
    (test-assert #t)))                  ; cancelling twice is fine

;; A timer is a timer.
(test-assert (t:timer? (t:run-at-time 10 #f (lambda () #t))))

;;------------------------------------------------------------------
;; Idle timers
;;------------------------------------------------------------------

;; An idle timer does *not* run while the editor is busy. This is the
;; whole reason blinking waits for you to stop typing.
(let ((fired 0))
  (t:timer-idle-start!)                 ; not idle - nothing has waited
  (t:timer-idle-stop!)
  (t:run-with-idle-timer 0.01 #t (lambda () (set! fired (+ fired 1))))
  (wait-ms 40)
  (kb:timer-check!)
  (test-equal 0 fired)
  ;; and now it is idle, so it runs
  (t:timer-idle-start!)
  (wait-ms 40)
  (kb:timer-check!)
  (test-assert (> fired 0)))

;; Idleness is when the editor waits, and it begins once - a second call
;; while it is still idle does not move the clock.
(t:timer-idle-start!)
(let ((first (t:current-idle-time)))
  (wait-ms 30)
  (t:timer-idle-start!)
  (test-assert (< first (t:current-idle-time))))
(t:timer-idle-stop!)
(test-equal #f (t:current-idle-time))

;;------------------------------------------------------------------
;; The cursor's visibility - what the blink turns off and on
;;------------------------------------------------------------------

(let* ((ed (new-text-editor))
       (frame (fr:new-frame ed 24 80)))
  (parameterize ((fr:*current-frame* frame))
    ;; shown to begin with
    (test-equal #t (fr:internal-show-cursor-p #f))
    (fr:internal-show-cursor #f #f)
    (test-equal #f (fr:internal-show-cursor-p #f))
    (test-equal #t (fr:window-cursor-off? (fr:selected-window)))
    (fr:internal-show-cursor #f #t)
    (test-equal #t (fr:internal-show-cursor-p #f))
    ;; and the type rule answers "no cursor" while it is off - which is
    ;; what makes the blink something you can see. The rule itself is
    ;; checked in `ncurses-editor-tests.scm'; what is here is the flag.
    (fr:internal-show-cursor #f #f)
    (test-equal #t (fr:window-cursor-off? (fr:selected-window)))))

;; Blinking is a graphical-frame thing: Emacs says so in the mode's own
;; docstring ("On text-only terminals, cursor blinking is controlled by
;; the terminal"), and `blink-cursor--should-blink' asks for a focused
;; *graphical* frame. With no window system there is nothing to blink,
;; which is why the terminal never starts a timer for it.
(parameterize ((fr:*blink-cursor-mode* #t))
  (test-equal #f (fr:blink-cursor-check))
  (test-equal #f fr:blink-cursor-idle-timer))

;; `blink-cursor--should-blink' wants a focused *graphical* frame -
;; "Returns whether we have any focused non-TTY frame" - so which of the
;; two is missing decides the answer. Both are checked here with the
;; window system a parameter, which is what `initialize-display-faces!'
;; sets when a display opens.
(parameterize ((f:*window-system* 'pgtk))
  (parameterize ((fr:*blink-cursor-mode* #t) (fr:*frame-focus* #t))
    (test-equal #t (fr:blink-cursor--should-blink)))
  ;; a windowed frame that has lost the focus does not blink: that is the
  ;; difference between this and a frame that never had a window system
  (parameterize ((fr:*blink-cursor-mode* #t) (fr:*frame-focus* #f))
    (test-equal #f (fr:blink-cursor--should-blink)))
  (parameterize ((fr:*blink-cursor-mode* #f) (fr:*frame-focus* #t))
    (test-equal #f (fr:blink-cursor--should-blink))))
;; and on a terminal neither matters
(parameterize ((f:*window-system* #f)
               (fr:*blink-cursor-mode* #t) (fr:*frame-focus* #t))
  (test-equal #f (fr:blink-cursor--should-blink)))

(test-end "schemacs_editor_timer")
