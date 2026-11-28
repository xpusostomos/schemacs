;; Tests for `(schemacs calendar time-date)': `format-seconds` and the
;; `time-add` it stands on. Every expectation is Emacs 31.1's own answer
;; for the same call (`emacs -Q --batch`), measured first:
;;
;;   (format-seconds "%h:%02m:%02s" 3821) -> "1:03:41"
;;   (format-seconds "%z%h:%m:%s" 65)     -> "0:1:5"
;;   (time-add 1 2)                       -> 3
;;
;; The one named departure: a float's `time-add` *form* follows this
;; tree's four-element time, where Emacs's is (TICKS . HZ) for most
;; floats (`(time-add 1.5 0.5)' is `(9007199254740992 .
;; 4503599627370496)' there). The value is the same; only the shape is
;; not, and `float-time` reads both.

(import
 (scheme base)
 (only (srfi 64) test-equal test-begin test-end)
 (only (schemacs calendar time-date) format-seconds)
 (only (schemacs timefns) time-add time-subtract float-time))

(test-begin "schemacs_calendar_time_date")

;;----------------------------------------------------------------
;; format-seconds (`time-date.el:269')
;;----------------------------------------------------------------

(test-equal "%h:%02m:%02s" "1:03:41" (format-seconds "%h:%02m:%02s" 3821))
(test-equal "%m:%02s" "1:15" (format-seconds "%m:%02s" 75))
(test-equal "a lower-case unit is the bare number" "5"
            (format-seconds "%s" 5))
(test-equal "an upper-case unit takes the name" "5 seconds"
            (format-seconds "%S" 5))
(test-equal "all five units" "0 1 1 1 1"
            (format-seconds "%y %d %h %m %s" 90061))
(test-equal "%z drops leading zero units" "0:1:5"
            (format-seconds "%z%h:%m:%s" 65))
(test-equal "%z with more units" "0:0:0:1:5"
            (format-seconds "%z%y:%d:%h:%m:%s" 65))
(test-equal "%x drops trailing zero units" "1:"
            (format-seconds "%h:%m:%s%x" 3600))
(test-equal "an integer conversion truncates a float" "1"
            (format-seconds "%s" 1.5))
(test-equal "%,1s is one decimal" "1.6"
            (format-seconds "%,1s" 1.56))
(test-equal "%.2S zero-pads" "05 seconds"
            (format-seconds "%.2S" 5))
(test-equal "%% is a literal percent" "% 5"
            (format-seconds "%% %s" 5))
;; This tree's errors carry the *template* and its irritants, not a
;; formatted string (`keyboard.scm`'s reporter formats them) - the same
;; departure `error-message-string` records.
(test-equal "an unknown specifier signals the C's template"
            "Bad format specifier: `~a'"
            (guard (e (#t (if (error-object? e)
                              (error-object-message e)
                              #f)))
              (format-seconds "%q" 1)
              #f))
(test-equal "units out of order with %z signal"
            "Units are not in decreasing order of size"
            (guard (e (#t (if (error-object? e)
                              (error-object-message e)
                              #f)))
              (format-seconds "%z%s%h" 1)
              #f))

;;----------------------------------------------------------------
;; time-add / time-subtract's value
;;----------------------------------------------------------------

(test-equal "two integers add to an integer" 3 (time-add 1 2))
(test-equal "two integers subtract to an integer" 3 (time-subtract 5 2))
(test-equal "list times add as list times" '(0 4 0 0)
            (time-add '(0 1 500000 0) '(0 2 500000 0)))
(test-equal "an integer and a list keep the list form" '(0 3 500000 0)
            (time-add 1.5 2))
(test-equal "float-time reads the sum" 1.56
            (float-time (time-add 1 (time-subtract 1.56 1))))

(test-end "schemacs_calendar_time_date")
