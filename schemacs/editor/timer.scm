(define-library (schemacs editor timer)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/timer.el', together
  ;; with the `timer_check' that `keyboard.c' runs from the command loop -
  ;; the part that actually decides which timer is ripe and runs it.
  ;;
  ;; A timer is something to do later, and the editor's own loop is what
  ;; makes "later" arrive: nothing here starts a thread or asks the
  ;; operating system for a signal. The command loop asks
  ;; `timer-next-delay' how long it may sleep before the next one is due,
  ;; gives its read that long, and calls `timer-check!' when it wakes.
  ;; Emacs is the same shape - its `read_char' computes the wait from
  ;; `timer_check' - and it is why a timer fires while the editor is
  ;; sitting still waiting for a key.
  ;;
  ;; Two kinds, as in Emacs:
  ;;
  ;;   * an ordinary timer is due at an absolute time;
  ;;   * an *idle* timer is due once the editor has been idle for N
  ;;     seconds - no key has come - and repeats each time it becomes
  ;;     idle again if REPEAT is set. "Idle" is Emacs's
  ;;     `timer_idleness_start_time': set when the editor goes to wait
  ;;     for input, cleared when input arrives.
  ;;
  ;; The editor's first caller is the blinking cursor
  ;; (`blink-cursor-mode', in `frame.sld'), which is a timer of each kind:
  ;; an idle one to notice that you have stopped typing, and an ordinary
  ;; repeating one to blink after that.

  (import
    (scheme base)
    ;; `current-second' is the clock. It is TAI seconds as an inexact
    ;; number, which is all a timer needs - differences are what matter.
    (only (scheme time) current-second)
    ;; `delq' is `subr.el''s in Emacs - it is what `cancel-timer' uses -
    ;; and Guile has it as a primitive rather than in `(scheme base)'.
    ;; `ceiling' and `inexact->exact' are here for `timer-reschedule!':
    ;; the delay is a fractional number of seconds and a front end wants
    ;; whole milliseconds.
    (only (guile) ceiling delq inexact->exact))

  (export
   *timer-idle-list*
   *timer-list*
   cancel-timer
   current-idle-time
   set!timer-due-at
   run-at-time
   run-with-idle-timer
   run-with-timer
   timer-armed?
   timer-args
   timer-idle-start!
   timer-idle-stop!
   timer-mark-run!
   timer-ripe?
   timer?
   *timer-wake*
   timer-next-delay
   timer-reschedule!
   timer-due-at
   timer-function
   timer-idle?
   timer-repeat
   )

  (begin

    (define-record-type <timer>
      (make-timer idle? due-at repeat function args)
      timer?
      (idle?    timer-idle?     set!timer-idle?)
      ;; ^ whether this is an idle timer rather than an ordinary one
      (due-at   timer-due-at    set!timer-due-at)
      ;; ^ for an ordinary timer, the absolute time it is due; for an
      ;; idle timer, how many seconds of idleness it waits for
      (repeat   timer-repeat    set!timer-repeat)
      ;; ^ how long until it runs again, or #f for a timer that runs once
      (function timer-function  set!timer-function)
      (args     timer-args      set!timer-args)
      ;; ^ what it does, and with what, as Emacs's `timer--function' and
      ;; `timer--args'. They are together because a timer that has lost
      ;; its arguments is no use to its caller.
      )

    (define *timer-list* (make-parameter '()))
    ;; ^ The ordinary timers, as GNU Emacs's `timer-list'. A parameter
    ;; rather than a private variable because the *check* is not in this
    ;; library: `timer_check' is `keyboard.c''s and lives in
    ;; `keyboard.sld', and it has to walk these lists and put a repeating
    ;; timer back at its next time. Emacs's are plain global variables
    ;; that every C file can read and write; a parameter is this tree's
    ;; way of publishing a global, and it is the closest thing to that.

    (define *timer-idle-list* (make-parameter '()))
    ;; ^ The idle timers, as GNU Emacs's `timer-idle-list'.

    (define *timer-idle-run* '())
    ;; ^ The idle timers that have already run in the current idle period.
    ;; An idle timer with REPEAT runs *once* "for each time Emacs becomes
    ;; idle" - its own docstring - and not every time the check comes
    ;; round. Without this an idle timer is ripe the moment it is due and
    ;; stays ripe for as long as the editor is idle, which makes
    ;; `timer-next-delay' answer zero for ever, the read return at once,
    ;; and the command loop spin: 140% of a processor, and a window that
    ;; never repaints. It was written that way first, and that is exactly
    ;; what it did.

    (define *idle-since* #f)
    ;; ^ When the editor last became idle, or #f while it is busy. GNU
    ;; Emacs's `timer_idleness_start_time', which is what
    ;; `current-idle-time' reads and what decides whether idle timers are
    ;; considered at all.

    (define (current-idle-time)
      ;; GNU Emacs's `current-idle-time': how long the editor has been
      ;; idle, or #f while it is not. It is what `run-with-idle-timer'
      ;; measures SECS against.
      ;;--------------------------------------------------------------
      (and *idle-since* (- (current-second) *idle-since*)))

    (define (timer-idle-start!)
      ;; The editor is about to wait for input. Called by the command
      ;; loop; the first such call after some input is when idleness
      ;; begins, so a later one does not move the clock.
      ;;--------------------------------------------------------------
      (unless *idle-since*
        (set! *idle-since* (current-second))
        ;; A new idle period: every idle timer is armed again.
        (set! *timer-idle-run* '())
        (timer-reschedule!)))

    (define (timer-idle-stop!)
      ;; Input arrived, so the editor is not idle: GNU Emacs clearing
      ;; `timer_idleness_start_time' when `read_char' finds something.
      ;;--------------------------------------------------------------
      (set! *idle-since* #f)
      (timer-reschedule!))

    (define (run-at-time time repeat function . args)
      ;; GNU Emacs's `run-at-time': do FUNCTION with ARGS in TIME
      ;; seconds, and every REPEAT seconds after that when REPEAT is not
      ;; false. TIME is a number of seconds from now; Emacs also accepts
      ;; a time of day as a string and an absolute time, which nothing
      ;; here has wanted yet - `timer-duration-words' and
      ;; `timer--time-setter' are the rest of it.
      ;;--------------------------------------------------------------
      (let ((timer (make-timer #f (+ (current-second) time) repeat
                               function args)))
        (*timer-list* (append (*timer-list*) (list timer)))
        (timer-reschedule!)
        timer))

    (define (run-with-timer secs repeat function . args)
      ;; GNU Emacs's `run-with-timer', which is `run-at-time' with its
      ;; arguments in the other order.
      ;;--------------------------------------------------------------
      (apply run-at-time secs repeat function args))

    (define (run-with-idle-timer secs repeat function . args)
      ;; GNU Emacs's `run-with-idle-timer': do FUNCTION the next time the
      ;; editor has been idle for SECS seconds. With REPEAT set it does
      ;; it again each time it has been idle that long *again* - once for
      ;; each time the editor becomes idle, which is what
      ;; `blink-cursor-delay' wants.
      ;;--------------------------------------------------------------
      (let ((timer (make-timer #t secs repeat function args)))
        (*timer-idle-list* (append (*timer-idle-list*) (list timer)))
        (timer-reschedule!)
        timer))

    (define (cancel-timer timer)
      ;; GNU Emacs's `cancel-timer': take TIMER out of whichever list it
      ;; is in. It is not an error to cancel a timer that has already
      ;; run, which matters because a timer that cancels itself is the
      ;; ordinary way to make a one-shot one.
      ;;--------------------------------------------------------------
      (*timer-list* (delq timer (*timer-list*)))
      (*timer-idle-list* (delq timer (*timer-idle-list*)))
      (timer-reschedule!)
      ;; Emacs answers nil here; this tree's nil is #f
      #f)

    (define (timer-ripe? timer idle?)
      ;; Whether TIMER should run now. An ordinary timer is ripe once its
      ;; time has come; an idle timer once the editor has been idle for
      ;; its SECS - and not at all while the editor is busy, which is why
      ;; `idle?' is handed in rather than read here.
      ;;--------------------------------------------------------------
      (if (timer-idle? timer)
          (and idle?
               (timer-armed? timer)
               (<= (timer-due-at timer) idle?))
          (<= (timer-due-at timer) (current-second))))

    (define (timer-armed? timer)
      ;; Whether an idle TIMER may run in this idle period. It may not if
      ;; it has already run in it: an idle timer with REPEAT runs "each
      ;; time Emacs has been idle for exactly SECS seconds (that is, only
      ;; once for each time Emacs becomes idle)", so it has to wait for
      ;; idleness to start afresh. `timer-idle-start!' arms them again.
      ;;
      ;; Without this an idle timer is ripe the moment it is due and stays
      ;; ripe for as long as the editor is idle, which makes the delay to
      ;; the next timer zero for ever, the read return at once, and the
      ;; command loop spin: 140% of a processor and a window that never
      ;; repaints. It was written that way first, and that is what it did.
      ;;--------------------------------------------------------------
      (not (memq timer *timer-idle-run*)))

    (define (timer-mark-run! timer)
      ;; Note that TIMER has run in this idle period, so that it does not
      ;; run again until the editor has been idle afresh.
      ;;--------------------------------------------------------------
      (set! *timer-idle-run* (cons timer *timer-idle-run*))
      (timer-reschedule!))

    ;;------------------------------------------------------------------
    ;; Telling the front end when to come back
    ;;
    ;; **A front end must be *told*, not polled.** Until now the command
    ;; loop armed its read with `timer-next-delay' and ran `timer-check!'
    ;; when the read came back, so a timer could only fire while
    ;; something was waiting to read a key. That is about to stop being
    ;; true: once Gtk owns the main loop there is no read to arm, and an
    ;; editor sitting idle would never fire a timer at all.
    ;;
    ;; So the delay is asked for when it changes rather than when a read
    ;; begins, and handed to `*timer-wake*' - the same shape as the
    ;; REPL's wake, for the same reason.
    ;;
    ;; The computation is Emacs's `timer_check' as the wait uses it, and
    ;; it lives *here* rather than in `keyboard.sld' where it was: "when
    ;; is the next timer due" is a fact about the timer lists, and the
    ;; timer module cannot ask the command loop without importing it.
    ;;------------------------------------------------------------------

    (define *timer-wake* (make-parameter #f))
    ;; ^ `(LAMBDA (MS) ...)' to arrange to be called back in MS
    ;; milliseconds, and with `#f' to cancel an arrangement already made
    ;; - or #f itself when this front end cannot be woken, in which case
    ;; the loop that waits keeps deriving its own timeout from
    ;; `timer-next-delay'.

    (define (timer-next-delay)
      ;; How many seconds the editor may sleep before the next timer is
      ;; due, or #f when none is. A negative answer means one is already
      ;; due. An idle timer counts from the start of the current idle
      ;; period, an ordinary one from now.
      ;;--------------------------------------------------------------
      (let ((idle (current-idle-time)))
        (let loop ((timers (append (*timer-list*)
                                   (if idle (*timer-idle-list*) '())))
                   (least #f))
          (cond
           ((null? timers) least)
           (else
            (let* ((timer (car timers))
                   (delay (if (timer-idle? timer)
                              (and (timer-armed? timer)
                                   (- (timer-due-at timer) idle))
                              (- (timer-due-at timer) (current-second)))))
              (loop (cdr timers)
                    (if (and delay (or (not least) (< delay least)))
                        delay least))))))))

    (define (timer-reschedule!)
      ;; Tell the front end when to come back for the next timer, if it
      ;; can be told. Called whenever the timer lists change and whenever
      ;; one has run.
      ;;--------------------------------------------------------------
      (let ((wake (*timer-wake*)))
        (when wake
          (let ((delay (timer-next-delay)))
            (wake (if delay
                      (max 0 (inexact->exact (ceiling (* 1000 delay))))
                      #f))))))

    ))
