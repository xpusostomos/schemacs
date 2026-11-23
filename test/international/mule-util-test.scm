(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs international mule-util)
       truncate-string-to-width truncate-string-ellipsis))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs international mule-util)` - `mule-util.el`'s
;; `truncate-string-to-width`. Every expectation below is Emacs 31.1's
;; own answer for the same call, measured with `emacs -Q --batch` before
;; the port was written.

(test-begin "schemacs_editor_mule_util")

(test-equal "a string that fits is unchanged"
            "abc"
            (truncate-string-to-width "abc" 5))

(test-equal "a longer one is cut at the column"
            "abc"
            (truncate-string-to-width "abcdef" 3))

(test-equal "START-COLUMN skips to its column first"
            "bcd"
            (truncate-string-to-width "abcdef" 4 1))

(test-equal "PADDING fills the shortfall"
            "abc  "
            (truncate-string-to-width "abc" 5 0 #\space))

(test-equal "ELLIPSIS replaces the cut end"
            "a..."
            (truncate-string-to-width "abcdef" 4 0 #f "..."))

(test-equal "but not when the string is only just longer than it"
            "abcd"
            (truncate-string-to-width "abcd" 4 0 #f "..."))

;; A start column past the end of the string: nothing to return, and no
;; padding either - the C's `(if (< column start-column) ... (if padding
;; ... ""))` only pads when there is a column to pad *from*.
(test-equal "a start column past the end is the empty string"
            ""
            (truncate-string-to-width "abcdef" 3 4))

(test-equal "and it stays empty with PADDING given"
            ""
            (truncate-string-to-width "abcdef" 3 4 #\space))

;; The width is `char-width`'s, so a two-column character counts twice.
(test-equal "a wide character counts for two columns"
            (string (integer->char #x4e00))
            (truncate-string-to-width (string (integer->char #x4e00) #\x) 2))

(test-equal "the default ellipsis is the horizontal ellipsis character"
            (string (integer->char #x2026))
            (truncate-string-ellipsis))

(test-end "schemacs_editor_mule_util")
