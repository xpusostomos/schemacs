(define-library (schemacs calendar time-date)
  ;; GNU Emacs's `lisp/calendar/time-date.el'.
  ;;
  ;; **Only `format-seconds` is carried.**  It is the one function in the
  ;; file this tree has a caller for - `compilation-handle-exit`'s
  ;; status message - and the rest of the file is date arithmetic
  ;; (`time-to-days`, `date-to-time`, `seconds-to-string`, ...) with no
  ;; caller here yet.  The time primitives it stands on are
  ;; `(schemacs timefns)`'s, which is `src/timefns.c`'s port.
  ;;
  ;; `format-seconds`' contract is Emacs 31.1's, measured first: a
  ;; lower-case specifier is the bare number, an upper-case one adds the
  ;; unit name ("5 seconds"), `%z` drops leading zero units, `%x` drops
  ;; trailing ones, `%,1s` gives one decimal, `%.2S` zero-pads, and `%%`
  ;; is a literal percent sign.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editfns) format)
    (only (schemacs search) string-match match-beginning match-end
          match-string replace-match)
    (only (schemacs fns) concat nth string-equal)
    (only (schemacs subr) replace-regexp-in-string string-replace string-trim)
    (only (schemacs casefiddle) downcase)
    (only (schemacs buffer) *case-fold-search*)
    (only (schemacs timefns) current-time time-less-p time-subtract
          time-convert time-add time-equal-p float-time))

  (export format-seconds)

  (begin


    (define (format-seconds string seconds)
      "Use format control STRING to format the time value SECONDS.
The valid format specifiers are:
%y is the number of (365-day) years.
%d is the number of days.
%h is the number of hours.
%m is the number of minutes.
%s is the number of seconds.
%z is a non-printing control flag (see below).
%% is a literal \"%\".

Upper-case specifiers are followed by the unit-name (e.g. \"years\").
Lower-case specifiers return only the unit.

\"%\" may be followed by a number specifying a width, with an
optional leading \".\" for zero-padding.  For example, \"%.3Y\" will
return something of the form \"001 year\".

The \"%s\" spec takes an additional optional parameter,
introduced by the \",\" character, to say how many decimals to
use.  \"%,1s\" means \"use one decimal\".

The \"%z\" specifier does not print anything.  When it is used, specifiers
must be given in order of decreasing size.  To the left of \"%z\", nothing
is output until the first non-zero unit is encountered.

The \"%x\" specifier does not print anything.  When it is used,
specifiers must be given in order of decreasing size.  To the
right of \"%x\", trailing zero units are not output."
      ;; `time-date.el:269'.
      ;;--------------------------------------------------------------
      (let ((start 0)
            (units '(("y" "year"   31536000)
                     ("d" "day"       86400)
                     ("h" "hour"       3600)
                     ("m" "minute"       60)
                     ("s" "second"        1)
                     ("z")
                     ("x")))
            (usedunits '())
            (zeroflag #f)
            (larger #f)
            (prev #f)
            (name #f)
            (unit #f)
            (leading-zeropos #f)
            (trailing-zeropos #f)
            (fraction #f)
            (minus #f)
            (chop-leading #f)
            (chop-trailing #f))
        (parameterize ((*case-fold-search* #t))
          (let loop ()
            (when (string-match "%\\.?[0-9]*\\(,[0-9]\\)?\\(.\\)" string start)
              (set! start (match-end 0))
              (let ((spec (match-string 2 string)))
                (unless (string-equal spec "%")
                  (let ((match (assoc (downcase spec) units)))
                    (unless match
                      (error "Bad format specifier: `~a'" spec))
                    (when (assoc (downcase spec) usedunits)
                      (error "Multiple instances of specifier: `~a'" spec))
                    (if (or (string-equal (car match) "z")
                            (string-equal (car match) "x"))
                        (set! zeroflag #t)
                        (unless larger
                          (set! unit (nth 2 match))
                          (set! larger (and prev (> unit prev)))
                          (set! prev unit)))
                    (set! usedunits (cons match usedunits)))))
              (loop))))
        (when (and zeroflag larger)
          (error "Units are not in decreasing order of size"))
        (unless seconds
          (set! seconds (current-time)))
        (let ((negative (time-less-p seconds 0)))
          ;; Treat -0.0 like 0.0.
          (set! minus (if negative "-" #f))
          (set! seconds (if negative (time-subtract 0 seconds) seconds))
          (let ((s (time-convert seconds 'integer)))
            (set! fraction (time-subtract seconds s))
            (set! seconds s)))
        (for-each
         (lambda (u)
           ;; Emacs's `(cadr '("z"))' is nil; Scheme's is an error.
           (set! name (if (pair? (cdr u)) (cadr u) #f))
           (set! unit (nth 2 u))
           (when (string-match
                  (format "%%\\(\\.?[0-9]+\\)?\\(,[0-9]+\\)?\\(%s\\)"
                          (car u))
                  string)
             (cond
              ((string-equal (car u) "z")
               (set! chop-leading
                     (if leading-zeropos
                         (min leading-zeropos (match-beginning 0))
                         ;; The entire spec is zero, get past "%z" to last 0.
                         (+ 2 (match-beginning 0)))))
              ((string-equal (car u) "x")
               (set! chop-trailing #t))
              (else
               ;; Cf `article-make-date-line' in gnus-art.
               (let* ((num (floor-quotient seconds unit))
                      (is-zero (and (= num 0)
                                    (or (not (= unit 1))
                                        (time-equal-p 0 fraction)))))
                 ;; Start position of the first non-zero unit.
                 (when (and (not leading-zeropos) (not is-zero))
                   (set! leading-zeropos (match-beginning 0)))
                 (unless is-zero
                   (set! trailing-zeropos #f))
                 (when (and (not trailing-zeropos) is-zero)
                   (set! trailing-zeropos (match-beginning 0)))
                 (set! seconds (- seconds (* num unit)))
                 (let ((g1 (match-string 1 string))
                       (g2 (match-string 2 string))
                       (g3 (match-string 3 string)))
                   (set! string
                         (replace-match
                          (format
                           (if g2
                               (concat
                                "%"
                                (and g1
                                     (if (char=? (string-ref g1 0) #\.)
                                         (concat "0" (substring g1 1))
                                         g1))
                                (concat "." (substring g2 1))
                                "f%s")
                               (concat "%" g1 "d%s"))
                           (if (= unit 1)
                               ;; `float-time' rounds, then `format'
                               ;; rounds.  Oh well.
                               (float-time (time-add num fraction))
                               num)
                           (if (string-equal g3 (car u))
                               ""       ; lower-case, no unit-name
                               (format " %s%s" name
                                       (if (= num 1) "" "s"))))
                          #t #t string))))))))
         units)
        (let ((pre string))
          (when (and chop-trailing trailing-zeropos)
            (set! string (substring string 0 trailing-zeropos)))
          (when chop-leading
            (set! string (substring string chop-leading)))
          ;; If we ended up removing everything, return the formatted
          ;; string in full.
          (when (string=? string "")
            (set! string pre)))
        (set! string (replace-regexp-in-string "%[zx]" "" string))
        (concat minus (string-trim (string-replace "%%" "%" string)))))
))
