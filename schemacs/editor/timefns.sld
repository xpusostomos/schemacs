(define-library (schemacs editor timefns)
  ;; This library mirrors GNU Emacs's `src/timefns.c': the time values
  ;; and the three things asked of them so far - `current-time',
  ;; `float-time', `time-subtract' and `format-time-string', with
  ;; `time-less-p'.
  ;;
  ;; A Lisp time here is the four-element `(HIGH LOW USEC PSEC)' list the
  ;; C's `make_lisp_time' answers with, which is what `file-attributes'
  ;; carries and what `(current-time)' returns: "Emacs uses a Lisp
  ;; representation of times by default, fixed-point and with some
  ;; hacks", as `current-time-list' is true. `lisp_time_argument' is the
  ;; read half, and it takes all the forms Emacs's does - that list, a
  ;; `(TICKS . HZ)' pair, a plain number of seconds, or nil for now.
  ;;
  ;; `format-time-string' is where a Guile library is *substituted* for a
  ;; port, which is what this project asks for when the function already
  ;; exists: its body is `(srfi srfi-19)''s `date->string' - a strftime
  ;; by another spelling - over an `(ice-9 i18n)' month and day table.
  ;; That is better than a port would be, because the names are the
  ;; *locale's*: `~b' resolves through `locale-month-short', so a German
  ;; locale prints `Mär' where a table written out here would print
  ;; `Mar'. SRFI-19 spells the directives with `~' where the C spells
  ;; them with `%' and the letters are otherwise the same, so a
  ;; `%' string is rewritten to a `~' one and handed over.
  ;;
  ;; `localtime''s answer carries three things SRFI-19's date wants: the
  ;; broken-down fields, the zone's name (its last element, "+07" on
  ;; this machine) and the zone offset. The offset element is *seconds
  ;; west* of UTC - measured, -25200 on a UTC+7 machine - and SRFI-19
  ;; takes seconds east, so it is negated on the way in. `%Z' is the
  ;; name and `%z' the offset, which is how Emacs splits them.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * the ZONE argument of `format-time-string'. Emacs's is an
  ;;     explicit zone name, a list of zone rules, t for UTC, or an
  ;;     offset in seconds; here the time is the machine's local time,
  ;;     which is what a nil ZONE means and what `ls-lisp' asks for.
  ;;   * `%g', `%G' and `%V' - the ISO week-numbering year and week,
  ;;     which SRFI-19 does not have either and which need the week
  ;;     arithmetic `%U' and `%W' get from the same place.
  ;;   * `time-add', `time-equal-p', `time-convert', `encode-time',
  ;;     `format-seconds' and the rest of the file.
  ;;
  ;; A departure worth naming: `time-subtract' answers a Lisp *time*,
  ;; as Emacs 31's does with `current-time-list' true - measured,
  ;; `(time-subtract '(27329 0 0 0) nil)' is `(0 3164 763424 551000)',
  ;; not the `(TICKS . HZ)' pair of older Emacsen. A difference and a
  ;; time are the same shape here, which is why `time-less-p' reads any
  ;; of them.

  (import
    (scheme base)
    (scheme char)
    ;; the clock, and the local-time breakdown SRFI-19's date needs
    (only (guile) ash cadddr caddr gettimeofday logand localtime string-index)
    ;; the substituted implementation - see the comment above
    (only (srfi srfi-19) date->string make-date)
    )

  (export current-time
          float-time
          format-time-string
          make-lisp-time
          time-less-p
          time-subtract
          )

  (begin

    ;;----------------------------------------------------------------
    ;; The Lisp time
    ;;------------------------------------------------------------------

    (define (make-lisp-time seconds nanoseconds)
      ;; GNU Emacs's `make_lisp_time' (timefns.c): the four-element
      ;; `(HIGH LOW USEC PSEC)' list `current-time' answers with, where
      ;; the time is `(+ (* HIGH 65536) LOW)' seconds and the last two
      ;; are the nanoseconds split into microseconds and the rest.
      ;;--------------------------------------------------------------
      (list (ash seconds -16)
            (logand seconds #xffff)
            (quotient nanoseconds 1000)
            (* 1000 (remainder nanoseconds 1000))))

    (define (lisp-time-arguments time)
      ;; GNU Emacs's `lisp_time_argument' (timefns.c): TIME read as
      ;; `(SECONDS . PICOSECONDS)', which is the whole of what the
      ;; functions below understand by "a time" - the C reads it into a
      ;; `struct lisp_time' of ticks and a rate, and picoseconds is that
      ;; struct at the rate every form here shares.
      ;;
      ;; A proper list is the `(HIGH LOW USEC PSEC)' form, a pair that
      ;; is not a list is `(TICKS . HZ)', and a number is seconds.
      ;;--------------------------------------------------------------
      (cond
       ((not time) (%now-arguments))
       ((number? time) (cons time 0))
       ((pair? time)
        (if (list? time)
            (cons (+ (* (car time) 65536) (cadr time))
                  (+ (* (caddr time) 1000000) (cadddr time)))
            (let ((ticks (* (car time) 1000000000000))
                  (hz (cdr time)))
              (cons (floor-quotient ticks hz)
                    (floor-remainder ticks hz)))))
       (else (error "Invalid time" time))))

    (define (%now-arguments)
      ;; The clock as `(SECONDS . PICOSECONDS)' - `(current-time)' before
      ;; it is dressed in the Lisp shape.
      ;;--------------------------------------------------------------
      (let ((now (gettimeofday)))
        (cons (car now) (* 1000000 (cdr now)))))

    (define (current-time)
      ;; GNU Emacs's `current-time': "Return the current time, as the
      ;; number of seconds since 1970-01-01 00:00:00."
      ;;--------------------------------------------------------------
      (let ((now (%now-arguments)))
        (make-lisp-time (car now) (cdr now))))

    (define (float-time . rest)
      ;; GNU Emacs's `float-time': "Convert TIME to a floating-point
      ;; number of seconds since the epoch. If TIME is nil, use the
      ;; current time."
      ;;--------------------------------------------------------------
      (let ((t (lisp-time-arguments (if (pair? rest) (car rest) #f))))
        (+ (inexact (car t)) (/ (inexact (cdr t)) 1000000000000.0))))

    (define (time-less-p a b)
      ;; GNU Emacs's `time-less-p' (timefns.c): "Return non-nil if time
      ;; value A is less than time value B." Either may be a time, a
      ;; difference or a plain number of seconds, which is what
      ;; `lisp_time_argument' is for.
      ;;--------------------------------------------------------------
      (let ((ta (lisp-time-arguments a))
            (tb (lisp-time-arguments b)))
        (if (= (car ta) (car tb))
            (< (cdr ta) (cdr tb))
            (< (car ta) (car tb)))))

    (define (time-subtract a . rest)
      ;; GNU Emacs's `time-subtract': "Subtract two time values, A minus
      ;; B. ... If B is nil, it defaults to the current time."
      ;;
      ;; The answer comes back through the C's `ticks_hz_list4', not
      ;; through `make_lisp_time', and the two split the sub-second part
      ;; *differently*: `make_lisp_time' answers `(USEC PSEC)' as
      ;; `(ns / 1000, ns % 1000 * 1000)', where `ticks_hz_list4' takes
      ;; the low twelve digits of the value as *picoseconds* and answers
      ;; their high six and low six. Measured on the same pair, Emacs
      ;; gives `(0 65532 999996 999997)' where the other split would
      ;; give `(0 65532 999996 997000)' - so the whole subtraction is
      ;; done in picoseconds, which is where the twelve digits are.
      ;;--------------------------------------------------------------
      (let* ((ta (lisp-time-arguments a))
             (tb (lisp-time-arguments (if (pair? rest) (car rest) #f)))
             (total (- (+ (* (car ta) 1000000000000) (cdr ta))
                       (+ (* (car tb) 1000000000000) (cdr tb)))))
        ;; `floor-' and not a plain quotient, so that a time before the
        ;; epoch borrows the way the C's normalisation does
        (let* ((secs (floor-quotient total 1000000000000))
               (rem (floor-remainder total 1000000000000)))
          (list (ash secs -16)
                (logand secs #xffff)
                (quotient rem 1000000)
                (remainder rem 1000000)))))

    ;;----------------------------------------------------------------
    ;; Formatting
    ;;------------------------------------------------------------------

    (define %srfi-19-directives
      ;; The directives `(srfi srfi-19)''s `date->string' has, which are
      ;; the C's strftime's with the letters unchanged and `~' for `%'.
      ;; Read off its own table rather than guessed.
      "12345ABDHIMNSTUVWXYZabcdefhjklmnprstuwxyz")

    (define (format-time-string format . rest)
      ;; GNU Emacs's `format-time-string' (timefns.c): "Format a time
      ;; value as a string. ... The first argument is a format control
      ;; string, and the function copies it to the output, replacing `%'
      ;; specifications with fields of TIME as it goes."
      ;;
      ;; The body is SRFI-19's `date->string', for the reason the
      ;; library comment gives: the directive letters are the same and
      ;; its month and day names are the locale's.
      ;;--------------------------------------------------------------
      (let* ((time (if (pair? rest) (car rest) #f))
             (args (lisp-time-arguments time))
             (broken (localtime (car args)))
             (date (make-date (quotient (cdr args) 1000)
                              (vector-ref broken 0)          ; second
                              (vector-ref broken 1)          ; minute
                              (vector-ref broken 2)          ; hour
                              (vector-ref broken 3)          ; day of month
                              (+ 1 (vector-ref broken 4))    ; month, 1-based
                              (+ 1900 (vector-ref broken 5)) ; year, from 1900
                              (- (vector-ref broken 9)))))   ; east of UTC
        (date->string date (%format-time-directives format broken))))

    (define (%format-time-directives format broken)
      ;; FORMAT with its `%' directives spelled as SRFI-19's `~' ones.
      ;;
      ;; Four of the C's directives are not SRFI-19's and are written
      ;; out here: `%C' is the century, `%P' is the morning/afternoon in
      ;; lower case where `%p' is in upper, `%F' is `%Y-%m-%d', `%q' is
      ;; the quarter of the year, and `%Z' is the zone's *name* - which
      ;; SRFI-19 spells as the numeric offset instead. None of the text
      ;; written in is a `~', so putting it into the string SRFI-19 is
      ;; about to read cannot be mistaken for a directive.
      ;;
      ;; "an unknown directive stands for itself" - measured: Emacs
      ;; answers "%Q" for "%Q".
      ;;--------------------------------------------------------------
      (let ((year (+ 1900 (vector-ref broken 5)))
            (month (+ 1 (vector-ref broken 4)))
            (hour (vector-ref broken 2)))
        (let loop ((i 0) (acc ""))
          (if (>= i (string-length format))
              acc
              (let ((c (string-ref format i)))
                (if (and (char=? c #\%)
                         (< (+ i 1) (string-length format)))
                    (let ((d (string-ref format (+ i 1))))
                      (loop (+ i 2)
                            (string-append
                             acc
                             (cond
                              ;; a literal `%' - written in as itself,
                              ;; because SRFI-19 reads `~' and not
                              ;; `%', so there is nothing to escape
                              ((char=? d #\%) "%")
                              ((char=? d #\C)
                               (let ((n (number->string (quotient year 100))))
                                 (if (< (string-length n) 2)
                                     (string-append "0" n)
                                     n)))
                              ((char=? d #\P) (if (< hour 12) "am" "pm"))
                              ((char=? d #\F) "~Y-~m-~d")
                              ((char=? d #\q)
                               (number->string (+ 1 (quotient (- month 1) 3))))
                              ((char=? d #\Z) (vector-ref broken 10))
                              ((string-index %srfi-19-directives d)
                               (string #\~ d))
                              ;; "an unknown directive stands for
                              ;; itself", as the C's copy loop leaves it
                              (else (string #\% d))))))
                    (loop (+ i 1) (string-append acc (string c)))))))))

    ))