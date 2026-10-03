(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor timefns)
 )

;; timefns.c's tests: the Lisp time and what is asked of it.
;;
;; Every expectation is what `emacs -Q --batch' answers on this machine
;; for the same call - the format string tests in the machine's own
;; locale and zone (UTC+7), which is the point of them: a table of
;; month names written out here would pass in English and be wrong
;; everywhere else, and the values below come from SRFI-19's locale
;; tables and `localtime', not from a table of ours.
;;
;; A time of zero seconds is 1970-01-01 00:00:00 UTC, which is
;; 1970-01-01 07:00 here.

(test-begin "schemacs_editor_timefns")

;; ------------------------------------------------------------------
;; the shape

(test-equal "a time is the four-element list `current-time' answers with"
  4
  (length (current-time)))

(test-equal "`make_lisp_time': the seconds split into HIGH and LOW, the
rest into USEC and PSEC" '(1 0 500000 0)
  (make-lisp-time 65536 500000000))

(test-equal "`make_lisp_time' splits the nanoseconds into USEC and PSEC"
  '(0 0 1 0)
  (make-lisp-time 0 1000))

;; ------------------------------------------------------------------
;; float-time, time-less-p

(test-equal "float-time of 65536 seconds" 65536.0
  (float-time '(1 0 0 0)))

;; a plain number is a number of seconds, which is the C's reading
(test-equal '(#t #f #f #t)
  (list (time-less-p -1 0)
        (time-less-p '(0 0 0 0) 0)      ; equal, so not less
        (time-less-p 0 '(0 0 0 0))
        (time-less-p 0 1)))

;; the nanoseconds decide when the seconds are equal
(test-equal '(#t #f)
  (list (time-less-p '(0 0 0 0) '(0 0 0 1))
        (time-less-p '(0 0 0 1) '(0 0 0 0))))

;; ------------------------------------------------------------------
;; time-subtract

;; "If B is nil, it defaults to the current time" - and with both nil
;; the two reads of the clock are two reads, so the answer is a
;; microsecond or two apart, not a reliable zero. That is Emacs's shape
;; too, so the pair here is explicit.

;; "a difference is a Lisp time, as Emacs 31's is" - measured, Emacs
;; answers the same list for the same pair
(test-equal '(0 65532 999996 999997)
  (time-subtract '(1 2 3 4) '(0 5 6 7)))

;; a borrow goes the right way: ten seconds less three and a half is six
;; and a half, not six and a negative half
(test-equal '(0 6 500000 0)
  (time-subtract '(0 10 0 0) '(0 3 500000 0)))

;; and going backwards the seconds go negative with a positive
;; fraction, which is the C's normalisation - Emacs answers this list
(test-equal '(-1 65534 500000 0)
  (time-subtract '(0 0 0 0) '(0 1 500000 0)))

;; ------------------------------------------------------------------
;; format-time-string

(test-equal "the two formats `ls-lisp-format-time-list' holds"
  '("Jan  1 07:00" "Jan  1  1970")
  (list (format-time-string "%b %e %H:%M" '(0 0 0 0))
        (format-time-string "%b %e  %Y" '(0 0 0 0))))

(test-equal "the ISO formats, which a locale chooses"
  '("01-01 07:00" "1970-01-01 ")
  (list (format-time-string "%m-%d %H:%M" '(0 0 0 0))
        (format-time-string "%Y-%m-%d " '(0 0 0 0))))

;; "the directives Emacs has and SRFI-19 does not" - the four written
;; out, plus the ones both have
(test-equal "19 am 1970-01-01 % 1 +07 +0700 001"
  (format-time-string "%C %P %F %% %q %Z %z %j" '(0 0 0 0)))

;; "an unknown directive stands for itself" - measured: Emacs answers
;; "%Q" for "%Q", so the `%' is kept
(test-equal "%Q"
  (format-time-string "%Q" '(0 0 0 0)))

;; a nil TIME is the current time, which is what the C's nil means
(test-equal (format-time-string "%Y" (current-time))
  (format-time-string "%Y"))

;; the quarter of the year, for a date either side of a boundary
(test-equal '("1" "3" "3" "4")
  (list (format-time-string "%q" '(0 0 0 0))       ; 1970-01-01
        (format-time-string "%q" '(27216 0 0 0))   ; 2026-07-01
        (format-time-string "%q" '(27300 0 0 0))   ; 2026-09-29
        (format-time-string "%q" (current-time))))

(test-end "schemacs_editor_timefns")