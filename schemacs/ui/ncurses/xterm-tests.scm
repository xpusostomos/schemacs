(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 ;; The terminal's own selection: OSC 52, which `xterm.el' implements
 ;; because the *terminal* carries the clipboard, not the display.
 (only (schemacs ui ncurses xterm)
       *xterm--set-selection* *xterm--get-selection*
       xterm-max-cut-length xterm--selection-char
       xterm--base64-encode xterm--base64-decode
       xterm--tty-set-selection xterm--tty-get-selection))

(setvbuf (current-output-port) 'none)

;; These were the last section of `schemacs/editor/select-tests.scm',
;; which tested `select.sld' (shared) *through* the terminal's
;; implementation. OSC 52 is the terminal's - `xterm.el' is where Emacs
;; puts it too - so it lives beside `xterm.sld', and that is the whole
;; reason this file is under `ui/': an editor test that asserts the
;; terminal's behaviour belongs with the terminal, not with the editor.
;;
;; Nothing here needs a display object of any kind, which is what makes
;; the split clean: these ask `xterm--tty-set-selection' what it wrote to
;; `current-output-port'.

(test-begin "schemacs_ui_ncurses_xterm")

;;--------------------------------------------------------------------
;; The terminal's selection: OSC 52
;;------------------------------------------------------------------

;; Base64, as OSC 52 carries it: no line breaks, `=' padding.
(test-equal "aGVsbG8="
  (xterm--base64-encode (string->utf8 "hello")))
(test-equal "aGVsbG8="
  (xterm--base64-encode (string->utf8 "hello")))
;; The pad cases: 4 + 1, 4 + 2, and an empty text.
(test-equal "aGVsbG8h"
  (xterm--base64-encode (string->utf8 "hello!")))
(test-equal "aGVsbG8heA=="
  (xterm--base64-encode (string->utf8 "hello!x")))
(test-equal ""
  (xterm--base64-encode (string->utf8 "")))
;; and it comes back: every encoding here decodes to what went in.
(test-equal (string->utf8 "hello")
  (xterm--base64-decode (xterm--base64-encode (string->utf8 "hello"))))
(test-equal (string->utf8 "hello!")
  (xterm--base64-decode (xterm--base64-encode (string->utf8 "hello!"))))
;; A terminal that will not give the selection answers `!', which is
;; not base64, and neither is a truncated reply: both are no text.
(test-equal #f (xterm--base64-decode "!"))
(test-equal #f (xterm--base64-decode "aGVsbG8"))

;; Setting: with the terminal parameter on, the cut goes out as
;; `\e]52;<c|p>;<base64>\a' on the tty, past ncurses's screen.
(define (sent-to-terminal thunk)
  (let ((port (open-output-string)))
    (parameterize ((current-output-port port))
      (thunk))
    (get-output-string port)))

(test-equal "clip set"
  "\x1b;]52;c;aGVsbG8=\x07;"
  (parameterize ((*xterm--set-selection* #t))
    (sent-to-terminal
     (lambda () (xterm--tty-set-selection 'CLIPBOARD "hello")))))

;; PRIMARY is `p'.
(test-equal "primary set"
  "\x1b;]52;p;aGVsbG8=\x07;"
  (parameterize ((*xterm--set-selection* #t))
    (sent-to-terminal
     (lambda () (xterm--tty-set-selection 'PRIMARY "hello")))))

;; With the parameter off - a terminal that has not said it takes
;; selections - nothing goes out, which is every non-xterm terminal.
(test-equal ""
  (parameterize ((*xterm--set-selection* #f))
    (sent-to-terminal
     (lambda () (xterm--tty-set-selection 'CLIPBOARD "hello")))))

;; Disowning - the value #f - sends nothing: an OSC 52 sequence cannot
;; take a selection away.
(test-equal ""
  (parameterize ((*xterm--set-selection* #t))
    (sent-to-terminal
     (lambda () (xterm--tty-set-selection 'CLIPBOARD #f)))))

;; A cut longer than `xterm-max-cut-length' is not sent - the terminal
;; would mistreat or ignore it.
(test-equal ""
  (parameterize ((*xterm--set-selection* #t)
                 (xterm-max-cut-length 4))
    (sent-to-terminal
     (lambda () (xterm--tty-set-selection 'CLIPBOARD "longer than four")))))

;; SECONDARY has no one-letter name: error, as `xterm--selection-char' is.
(test-assert "SECONDARY errors"
  (guard (e (#t #t))
    (xterm--selection-char 'SECONDARY)
    #f))

;; Reading with the gate off answers #f - and not `when''s
;; unspecified, which is true in Scheme and had `C-y' pasting an empty
;; string instead of the kill, fourteen tests ago.
(test-equal #f
  (parameterize ((*xterm--get-selection* #f))
    (xterm--tty-get-selection 'CLIPBOARD 'STRING)))

(test-end "schemacs_editor_select")

(test-end "schemacs_ui_ncurses_xterm")
