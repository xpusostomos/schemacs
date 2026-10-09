(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 ;; The terminal's own selection: OSC 52, which `xterm.el' implements
 ;; because the *terminal* carries the clipboard, not the display.
 (only (schemacs ui ncurses xterm)
       *xterm--set-selection* *xterm--get-selection*
       xterm-max-cut-length xterm--selection-char
       xterm--base64-encode xterm--base64-decode
       xterm--tty-set-selection xterm--tty-get-selection
       ;; The decode map, which `term.scm' consults for a keycode ncurses
       ;; could not name - see the last section of this file.
       *input-decode-map*))

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

;; The expected sequences are built from `#\escape' and `#\bel' rather
;; than written as `\x1b' escapes, which is what `xterm.scm''s writer does
;; too. These two lines read `"\x1b;]52;...\x07;"' until the `--r7rs' flag
;; was dropped: R7RS ends a `\x...;' escape with the `;', the default
;; reader takes that `;' as an ordinary character, and the expectation
;; then held two stray semicolons - so the test would have gone on
;; passing only if the *writer* had grown them as well.
(test-equal "clip set"
  (string-append (string #\escape #\] #\5 #\2 #\;)
                 "c;aGVsbG8="
                 (string #\bel))
  (parameterize ((*xterm--set-selection* #t))
    (sent-to-terminal
     (lambda () (xterm--tty-set-selection 'CLIPBOARD "hello")))))

;; PRIMARY is `p'.
(test-equal "primary set"
  (string-append (string #\escape #\] #\5 #\2 #\;)
                 "p;aGVsbG8="
                 (string #\bel))
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

;;--------------------------------------------------------------------
;; The decode map: what a modified function key's bytes become
;;------------------------------------------------------------------
;; `*input-decode-map*' is the 255-entry table `xterm.scm' transcribes from
;; `xterm.el:211-661', and `term.scm' consults it with `(assoc sequence
;; ...)' on the sequence `tiget' gives back for a keycode ncurses could not
;; name. Nothing parses a modifier out of anything.
;;
;; **These are the first checks it has ever had**, and they are here
;; because of how the `--r7rs' removal found it: every one of the 255
;; entries was keyed on `"\x1b;O2A"' - ESC, then a stray `;' the default
;; reader keeps - so the table matched nothing at all, and *no check
;; failed*, because no check anywhere presses a modified function key.
;; A dead table that nothing reads from looks exactly like a working one.
;; Each expectation is `xterm.el''s own binding for that sequence.
(define (decoded chars)
  (let ((entry (assoc (list->string chars) (*input-decode-map*))))
    (and entry (cdr entry))))

(test-equal 'S-up   (decoded (list #\esc #\O #\2 #\A)))
(test-equal 'S-left (decoded (list #\esc #\O #\2 #\D)))
(test-equal 'C-up   (decoded (list #\esc #\O #\5 #\A)))
;; The case ncurses cannot name at all: `\e[1;3A' is a keycode whose only
;; name is a terminfo one (`kUP3'), which is the road to this table.
(test-equal 'M-up   (decoded (list #\esc #\[ #\1 #\; #\3 #\A)))
(test-equal 'C-up   (decoded (list #\esc #\[ #\1 #\; #\5 #\A)))
;; Every entry is keyed on a sequence that starts with ESC: a table whose
;; keys had all grown a character would still hold 255 entries.
(test-equal 255
  (apply + (map (lambda (e) (if (char=? (string-ref (car e) 0) #\esc) 1 0))
                (*input-decode-map*))))

(test-end "schemacs_ui_ncurses_xterm")
