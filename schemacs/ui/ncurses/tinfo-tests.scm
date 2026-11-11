;; Tests for `(schemacs ui ncurses tinfo)' - the terminfo client layer
;; that replaces what this tree borrowed from ncurses.
;;
;; Every expectation below is the C library's own answer for the same
;; call, checked against `tigetstr`/`tigetnum`/`tigetflag`/`tparm` run
;; directly. They are what Phase 1 of `plans/TTY.md` is for: the layer has
;; to be right before anything is built on it.
;;
;; **TERM is pinned**, so a developer's `$TERM` cannot change what this
;; asserts - the same rule `tools/pty-check.py` follows for `COLORTERM`.
;;-------------------------------------------------------------
(import (scheme base)
        (scheme char)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (schemacs ui ncurses tinfo))

(test-begin "schemacs_ui_ncurses_tinfo")

;; There is a terminfo library on this machine, and it describes a
;; terminal.
(test-assert (tinfo-ready?))
(test-assert (setup-term "xterm-256color" 1))

;; `colors` is the capability `term.c` reads into `TN_max_colors`. An
;; xterm-256color answers 256, and that is what `display-color-cells` on
;; the tty is already built from (via ncurses).
(test-equal 256 (tigetnum "colors"))

;; A boolean capability: 1 for yes, 0 for no, -1 for "not a boolean" -
;; the three values `term.c` tests with `tigetflag ("bce") > 0`.
(test-equal 1 (tigetflag "bce"))
(test-equal 1 (tigetflag "xenl"))
;; `am` (automatic margins) is a boolean an xterm has.
(test-equal 1 (tigetflag "am"))
;; not a capability at all
(test-equal -1 (tigetflag "no-such-boolean-capability"))

;; `cup` is the cursor-addressing sequence, with `%p1`/`%p2` parameters
;; and an `%i` that makes them one-based. Measured on this terminal.
(test-equal "\x1b[%i%p1%d;%p2%dH" (tigetstr "cup"))

;; **A capability the terminal has not got answers #f.** `tigetstr`
;; returns `(char *) -1` for one, which is a *true* pointer once the FFI
;; has wrapped it - so the test is the address, not `null-pointer?`.
(test-equal #f (tigetstr "no-such-capability-at-all"))

;; `tparm` expands the parameters, and `%i` adds one to each - so
;; row 5, column 12 is `ESC [ 6 ; 13 H`.
(test-equal "\x1b[6;13H" (tparm "cup" 5 12))
;; and the first row, first column
(test-equal "\x1b[1;1H" (tparm "cup" 0 0))
;; `csr` sets a scroll region: rows 3..20 (0-based) become 4..21.
(test-equal "\x1b[4;21r" (tparm "csr" 3 20))
;; a capability with fewer parameters than nine is fine: the extra
;; arguments a caller does not give are zero.
(test-equal "\x1b[2;5r" (tparm "csr" 1 4))

;; The cache answers the same thing twice, and a second call does not
;; change the answer - it is a cache, not state that drifts.
(let ((first (tigetstr "cup")))
  (test-equal first (tigetstr "cup")))

;; `tputs` writes a capability, and strips a padding directive: the C's
;; `tputs` with `baud_rate` 0 emits nothing for `$<n>`, which is what a
;; pseudo-terminal asks for.
(test-equal "\x1b[6;13H"
  (let ((p (open-output-string)))
    (tputs (tparm "cup" 5 12) p)
    (get-output-string p)))
(test-equal "AB"
  (let ((p (open-output-string)))
    (tputs "A$<5>B" p)
    (get-output-string p)))

;; **The terminal hooks' capabilities are all there**, which is what makes
;; a tty backend possible at all: the sequences `term.c` builds on.
(for-each
 (lambda (cap)
   (test-assert (string? (tigetstr cap))))
 '("cup" "csr" "smcup" "rmcup" "smkx" "rmkx" "clear" "el" "ed"))

(test-end "schemacs_ui_ncurses_tinfo")
