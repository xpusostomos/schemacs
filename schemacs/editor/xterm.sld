(define-library (schemacs editor xterm)
  ;; This library mirrors GNU Emacs's `term/xterm.el': what Emacs does to
  ;; an xterm when it opens one. Two parts of that file are here, because
  ;; they are the two that decide how a face comes out on the screen:
  ;;
  ;;  * `xterm-register-default-colors' - the colours an xterm has, which
  ;;    for a 256-colour xterm are the sixteen named ones, the 6x6x6 cube
  ;;    and the 24 grays, computed as xterm's own `256colres.pl' computes
  ;;    them. `startup.el' registers only the standard eight; this is what
  ;;    replaces them for an xterm.
  ;;  * the background query - `xterm--query' with `\e]11;?\e\\', whose
  ;;    reply says what colour the terminal's background really is, and
  ;;    `xterm--set-background-mode', which turns that into `dark' or
  ;;    `light'. This is why Emacs on a dark xterm picks the `(background
  ;;    dark)' branch of `region' - `blue3' - where the fallback in
  ;;    `frame.el', which knows nothing but the terminal's name, would
  ;;    say `light' for any xterm.
  ;;
  ;; Emacs asks the terminal first who it is (`\e[>0c', the Secondary
  ;; Device Attributes query) and only asks about the background when the
  ;; answer says an xterm of version 242 or later, or a gnome-terminal
  ;; new enough to answer; that gate is ported with it.
  ;;
  ;;  * the key maps - `xterm-rxvt-function-map' and `xterm-function-map',
  ;;    which `xterm--init' pushes into `input-decode-map'
  ;;    (`xterm.el:982'). They are `*input-decode-map*' below, keyed on
  ;;    the escape sequence as Emacs keys them.
  ;;
  ;; Not ported: `modifyOtherKeys', the
  ;; window title, the cursor updates, bracketed paste and focus
  ;; tracking, the mouse, and `xterm--maybe-update-default-face', which
  ;; gives the `default' face the exact colours the terminal reported.
  ;; The rxvt hand-off at the top of `xterm--init' is not either:
  ;; `term/rxvt.el' is not here.
  ;;
  ;; The selection is the OSC 52 path: `gui-backend-get-selection' and
  ;; `gui-backend-set-selection' for `window-system' nil, which move
  ;; text to and from the clipboard through `\e]52;' sequences. Only
  ;; the bare-terminal branch of the set method is ported - the Device
  ;; Control String wrapper for `screen' is not, and this tree's
  ;; `TERM=screen*' never reaches `terminal-init-xterm' anyway. The
  ;; method for the tty display is `term.sld''s, which delegates here.
  ;;
  ;; Emacs's `xterm--query' has an asynchronous path - when input is
  ;; pending it registers the reply's prefix in `input-decode-map' and
  ;; carries on. There is no `input-decode-map' here, so the query is
  ;; the synchronous path only: send, read with a timeout, and give back
  ;; whatever was read that was not the reply.

  (import
    (scheme base)
    (scheme char)
    (only (scheme write) display)
    ;; `caddr' is `(scheme cxr)'s: an entry of `xterm-standard-colors' is
    ;; `(NAME INDEX (R G B))'.
    (only (scheme cxr) caddr)
    ;; `ash' and `logior' for `xterm-rgb-convert-to-16bit'; the hex is
    ;; read with `string->number' in base 16. `string->utf8' and
    ;; `utf8->string', which turn the clipboard's text into the bytes
    ;; the OSC 52 sequence carries and back, are `(scheme base)''s.
    (only (guile) ash logior string-contains string-split)
    ;; The terminal: the query goes out on the output port, and the reply
    ;; is read one event at a time with a timeout, as
    ;; `xterm--read-event-for-query' reads it. What was read and was not
    ;; the reply goes back with `ungetch', which is
    ;; `unread-command-events' here.
    (only (ncurses curses) flushinp getch stdscr timeout! ungetch)
    (only (schemacs editor tty-colors)
          tty-color-clear tty-color-define *color-name-rgb-alist*)
    (only (schemacs editor faces) *display-color-cells* *frame-background-mode*))

  (export
   terminal-init-xterm
   xterm-standard-colors
   xterm-rgb-convert-to-16bit
   xterm-register-default-colors
   xterm-query-timeout
   xterm--query
   xterm--set-background-mode
   xterm--report-background-handler
   xterm--report-foreground-handler
   xterm--version-handler
   *input-decode-map*
   *xterm--background-color*
   *xterm--foreground-color*
   xterm-max-cut-length
   xterm--selection-char
   xterm--base64-encode
   xterm--base64-decode
   xterm--init-activate-set-selection
   xterm--init-activate-get-selection
   *xterm--set-selection*
   *xterm--get-selection*
   xterm--tty-set-selection
   xterm--tty-get-selection
   )

  (begin

    (define xterm-standard-colors
      ;; GNU Emacs's `xterm-standard-colors': "Names of 16 standard
      ;; xterm/aixterm colors, their numbers, and RGB values." The RGB
      ;; values are 8-bit, from XTerm-col.ad, and are widened when
      ;; registered.
      ;;--------------------------------------------------------------
      '(("black"          0 (  0   0   0))   ; black
        ("red"            1 (205   0   0))   ; red3
        ("green"          2 (  0 205   0))   ; green3
        ("yellow"         3 (205 205   0))   ; yellow3
        ("blue"           4 (  0   0 238))   ; blue2
        ("magenta"        5 (205   0 205))   ; magenta3
        ("cyan"           6 (  0 205 205))   ; cyan3
        ("white"          7 (229 229 229))   ; gray90
        ("brightblack"    8 (127 127 127))   ; gray50
        ("brightred"      9 (255   0   0))   ; red
        ("brightgreen"   10 (  0 255   0))   ; green
        ("brightyellow"  11 (255 255   0))   ; yellow
        ("brightblue"    12 ( 92  92 255))   ; rgb:5c/5c/ff
        ("brightmagenta" 13 (255   0 255))   ; magenta
        ("brightcyan"    14 (  0 255 255))   ; cyan
        ("brightwhite"   15 (255 255 255)))) ; white

    (define (xterm-rgb-convert-to-16bit prim)
      ;; GNU Emacs's `xterm-rgb-convert-to-16bit': "Convert an 8-bit
      ;; primary color value PRIM to a corresponding 16-bit value."
      ;;--------------------------------------------------------------
      (logior prim (ash prim 8)))

    (define (xterm-register-default-colors colors)
      ;; GNU Emacs's `xterm-register-default-colors': register as many
      ;; colours as the display has - the first sixteen from COLORS, and
      ;; the rest computed as xterm computes its 88- or 256-colour
      ;; scheme. "This and other formulas taken from 256colres.pl and
      ;; 88colres.pl in the xterm distribution."
      ;;
      ;; The 24-bit case registers every named colour with its own value
      ;; as its index; it is ported as Emacs has it, though ncurses's
      ;; colour pairs cannot carry a 24-bit value, so a face on such a
      ;; terminal still comes out through the pair table.
      ;;--------------------------------------------------------------
      (let ((ncolors (*display-color-cells*)))
        (when (> ncolors 0)
          ;; Clear the 8 default tty colors registered by startup.el
          (tty-color-clear))
        ;; Only register as many colors as are supported by the display.
        (let loop ((colors colors) (ncolors ncolors))
          (cond
           ((and (> ncolors 0) (pair? colors))
            (let ((color (car colors)))
              (tty-color-define (car color) (cadr color)
                                (map xterm-rgb-convert-to-16bit (caddr color))))
            (loop (cdr colors) (- ncolors 1)))
           ((> ncolors 0)
            ;; We've exhausted the colors from `colors'.  If there are
            ;; more colors to support, compute them now.
            (cond
             ((= ncolors 16777200)      ; 24-bit xterm
              ;; all named tty colors
              (let loop ((rest *color-name-rgb-alist*)
                         (idx (length xterm-standard-colors)))
                (unless (null? rest)
                  (let ((color (car rest)))
                    (if (assoc (car color) xterm-standard-colors)
                        (loop (cdr rest) idx)
                        (begin
                          (tty-color-define (car color) idx (cdr color))
                          (loop (cdr rest) (+ idx 1))))))))
             ((= ncolors 240)           ; 256-color xterm
              ;; 216 non-gray colors first
              (let loop ((r 0) (g 0) (b 0) (ncolors ncolors))
                (if (> ncolors 24)
                    (begin
                      (tty-color-define
                       (string-append "color-" (number->string (- 256 ncolors)))
                       (- 256 ncolors)
                       (map xterm-rgb-convert-to-16bit
                            (list (if (zero? r) 0 (+ (* r 40) 55))
                                  (if (zero? g) 0 (+ (* g 40) 55))
                                  (if (zero? b) 0 (+ (* b 40) 55)))))
                      (let* ((b (+ b 1))
                             (g (if (> b 5) (+ g 1) g))
                             (b (if (> b 5) 0 b))
                             (r (if (> g 5) (+ r 1) r))
                             (g (if (> g 5) 0 g)))
                        (loop r g b (- ncolors 1))))
                    ;; Now the 24 gray colors
                    (let grays ((ncolors ncolors))
                      (when (> ncolors 0)
                        (let ((color (xterm-rgb-convert-to-16bit
                                      (+ 8 (* (- 24 ncolors) 10)))))
                          (tty-color-define
                           (string-append "color-" (number->string (- 256 ncolors)))
                           (- 256 ncolors)
                           (list color color color)))
                        (grays (- ncolors 1)))))))
             ((= ncolors 72)            ; 88-color xterm
              ;; 64 non-gray colors
              (let ((levels '(0 139 205 255)))
                (let loop ((r 0) (g 0) (b 0) (ncolors ncolors))
                  (if (> ncolors 8)
                      (begin
                        (tty-color-define
                         (string-append "color-" (number->string (- 88 ncolors)))
                         (- 88 ncolors)
                         (map xterm-rgb-convert-to-16bit
                              (list (list-ref levels r)
                                    (list-ref levels g)
                                    (list-ref levels b))))
                        (let* ((b (+ b 1))
                               (g (if (> b 3) (+ g 1) g))
                               (b (if (> b 3) 0 b))
                               (r (if (> g 3) (+ r 1) r))
                               (g (if (> g 3) 0 g)))
                          (loop r g b (- ncolors 1))))
                      ;; Now the 8 gray colors
                      (let grays ((ncolors ncolors))
                        (when (> ncolors 0)
                          (let ((color (xterm-rgb-convert-to-16bit
                                        (exact
                                         (floor
                                          (if (= ncolors 8)
                                              46.36363636
                                              (+ (* (- 8 ncolors) 23.18181818)
                                                 69.54545454)))))))
                            (tty-color-define
                             (string-append "color-" (number->string (- 88 ncolors)))
                             (- 88 ncolors)
                             (list color color color)))
                          (grays (- ncolors 1))))))))
             (else
              (error "Unsupported number of xterm colors" (+ 16 ncolors)))))
           (else #f)))))

    ;;----------------------------------------------------------------
    ;; Asking the terminal

    (define xterm-query-timeout
      ;; GNU Emacs's `xterm-query-timeout': "Seconds to wait for an
      ;; answer from the terminal."
      ;;--------------------------------------------------------------
      (make-parameter 2))

    (define *xterm--background-color* (make-parameter #f))
    (define *xterm--foreground-color* (make-parameter #f))
    ;; ^ The terminal parameters `xterm--background-color' and
    ;; `xterm--foreground-color': what the terminal said its colours are,
    ;; as `(R G B)', or #f when it has not said.

    (define (xterm--send-string-to-terminal string)
      ;; `send-string-to-terminal': the bytes go straight to the tty,
      ;; past ncurses's screen, as Emacs's go past its display.
      ;;--------------------------------------------------------------
      (display string (current-output-port))
      (flush-output-port (current-output-port)))

    (define (xterm--read-event-for-query)
      ;; GNU Emacs's `xterm--read-event-for-query': `read-event' with
      ;; `xterm-query-timeout', or #f when nothing came. Emacs holds
      ;; redisplay off for the first fifth of a second so the query does
      ;; not make the screen flash; nothing here redisplays while it
      ;; waits.
      ;;--------------------------------------------------------------
      (timeout! (stdscr) (exact (round (* 1000 (xterm-query-timeout)))))
      (let ((event (getch (stdscr))))
        (timeout! (stdscr) -1)
        event))

    (define (xterm--read-string term1 . rest)
      ;; GNU Emacs's `xterm--read-string': read up to TERM1, or to TERM1
      ;; followed by TERM2 - `\e\\', the string terminator - dropping the
      ;; terminator. A read that times out ends the string where it is.
      ;;--------------------------------------------------------------
      (let ((term2 (if (pair? rest) (car rest) #f)))
        (let loop ((chars '()) (last #f))
          (let ((chr (xterm--read-event-for-query)))
            (cond
             ((not (char? chr))
              (list->string (reverse chars)))
             ((if term2
                  (and last (char=? last term1) (char=? chr term2))
                  (char=? chr term1))
              ;; with TERM2 the TERM1 already taken is not part of it
              (list->string (reverse (if term2 (cdr chars) chars))))
             (else (loop (cons chr chars) chr)))))))

    (define (xterm--query query handlers)
      ;; GNU Emacs's `xterm--query': "Send QUERY string to the terminal
      ;; and watch for a response. HANDLERS is an alist with elements of
      ;; the form (STRING . FUNCTION). We run the first FUNCTION whose
      ;; STRING matches the input events."
      ;;
      ;; This is Emacs's synchronous branch. An event that is not the
      ;; next character of a handler's STRING is pushed back to be read
      ;; as a key, and so are the characters of the STRING matched before
      ;; it, in order - which is what `unread-command-events' gets in
      ;; Emacs, and `ungetch' here (last pushed is first read, so the
      ;; pushes run backwards).
      ;;--------------------------------------------------------------
      ;; Pending input can be mistakenly returned by the calls to
      ;; read-event below: discard it.
      (flushinp)
      (xterm--send-string-to-terminal query)
      (let next ((handlers handlers))
        (when (pair? handlers)
          (let* ((handler (car handlers))
                 (prefix (car handler))
                 (n (string-length prefix)))
            (let loop ((i 0))
              (if (< i n)
                  (let ((evt (xterm--read-event-for-query)))
                    (cond
                     ((and (char? evt) (char=? evt (string-ref prefix i)))
                      (loop (+ i 1)))
                     (else
                      (when evt (ungetch evt))
                      (let back ((i i))
                        (when (> i 0)
                          (ungetch (string-ref prefix (- i 1)))
                          (back (- i 1))))
                      (next (cdr handlers)))))
                  ((cdr handler))))))))

    (define (xterm--parse-rgb-reply str)
      ;; The `rgb:R/G/B' in a colour reply, as `(R G B)' read in hex, or
      ;; #f: Emacs's `string-match' on
      ;; "rgb:\\([a-f0-9]+\\)/\\([a-f0-9]+\\)/\\([a-f0-9]+\\)".
      ;;--------------------------------------------------------------
      (let ((at (string-contains str "rgb:")))
        (and at
             (let ((parts (string-split
                           (substring str (+ at 4) (string-length str)) #\/)))
               (and (= (length parts) 3)
                    (let ((rgb (map (lambda (part) (string->number part 16)) parts)))
                      (and (not (memq #f rgb)) rgb)))))))

    (define (xterm--report-background-handler)
      ;; GNU Emacs's `xterm--report-background-handler':
      ;; "The reply should be: \e ] 11 ; rgb: NUMBER1 / NUMBER2 / NUMBER3 \e \\"
      ;;--------------------------------------------------------------
      (let ((rgb (xterm--parse-rgb-reply (xterm--read-string #\escape #\\))))
        (when rgb (*xterm--background-color* rgb))))

    (define (xterm--report-foreground-handler)
      ;; GNU Emacs's `xterm--report-foreground-handler'.
      ;;--------------------------------------------------------------
      (let ((rgb (xterm--parse-rgb-reply (xterm--read-string #\escape #\\))))
        (when rgb (*xterm--foreground-color* rgb))))

    (define (xterm--query-colors)
      ;; The two colour queries, as `xterm--version-handler' and
      ;; `xterm--init' send them: the background, then the foreground.
      ;;--------------------------------------------------------------
      (xterm--query (string #\escape #\] #\1 #\1 #\; #\? #\escape #\\)
                    (list (cons (string #\escape #\] #\1 #\1 #\;)
                                xterm--report-background-handler)))
      (xterm--query (string #\escape #\] #\1 #\0 #\; #\? #\escape #\\)
                    (list (cons (string #\escape #\] #\1 #\0 #\;)
                                xterm--report-foreground-handler))))

    (define (xterm--version-handler)
      ;; GNU Emacs's `xterm--version-handler':
      ;; "The reply should be: \e [ > NUMBER1 ; NUMBER2 ; NUMBER3 c".
      ;; What is kept of it is the decision it makes: whether the
      ;; terminal is one that answers the colour queries, and - version
      ;; 203 was when xterm grew OSC 52 - whether it can take the
      ;; clipboard. Emacs also turns on `modifyOtherKeys' for version
      ;; 216 and later, which is not ported.
      ;;--------------------------------------------------------------
      (let* ((str (xterm--read-string #\c))
             (fields (string-split str #\;)))
        (when (>= (length fields) 3)
          (let ((type (car fields))
                (version (string->number (cadr fields))))
            (when version
              ;; Hack attack!  bug#16988: gnome-terminal reports "1;NNNN;0"
              ;; with a large NNNN but is based on a rather old xterm code.
              (let ((version
                     (cond
                      ((and (> version 2000)
                            (or (string=? type "1") (string=? type "65")))
                       (when (> version 4000) (xterm--query-colors))
                       200)
                      ;; `screen' (which returns 83;40003;0) seems to also
                      ;; lack support for some of these
                      ((string=? type "83") 200)
                      (else version))))
                ;; If version is 242 or higher, assume the xterm supports
                ;; reporting the background color
                (when (>= version 242)
                  (xterm--query-colors))
                ;; In version 203 support for accessing the X selection was
                ;; added.  Hterm reports itself as version 256 and supports it
                ;; as well.  gnome-terminal doesn't and is excluded by this
                ;; test.
                (when (>= version 203)
                  ;; Most xterms seem to have it disabled by default, and if it's
                  ;; disabled, C-y will incur a timeout, so we only use it if the user
                  ;; explicitly requests it.
                  ;;(xterm--init-activate-get-selection)
                  (xterm--init-activate-set-selection))))))))

    ;;----------------------------------------------------------------
    ;; The selection: OSC 52
    ;;
    ;; `gui-backend-get-selection' and `gui-backend-set-selection' for
    ;; `window-system' nil (`xterm.el:1131', `xterm.el:1161'): the text
    ;; goes to the terminal as `\e]52;c;BASE64\a', and comes back as
    ;; the reply to `\e]52;c;?\e\\'. The gate is the terminal
    ;; parameter `xterm--set-selection' / `xterm--get-selection' -
    ;; `*xterm--set-selection*' / `*xterm--get-selection*' here, the
    ;; way `*xterm--background-color*' is its parameter - and the
    ;; version handler turns the set one on for xterm 203 and later.
    ;; The read stays off by default: "Most xterms seem to have it
    ;; disabled by default, and if it's disabled, C-y will incur a
    ;; timeout, so we only use it if the user explicitly requests it."

    (define xterm-max-cut-length
      ;; GNU Emacs's `xterm-max-cut-length': "Maximum number of bytes
      ;; to cut into xterm using the OSC 52 sequence." Terminals
      ;; mistreat or ignore a sequence longer than their own limit.
      ;;--------------------------------------------------------------
      (make-parameter 100000))

    (define *xterm--set-selection* (make-parameter #f))
    (define *xterm--get-selection* (make-parameter #f))
    ;; ^ The terminal parameters `xterm--set-selection' and
    ;; `xterm--get-selection'.

    (define *base64-alphabet*
      ;; RFC 4648's alphabet. `data-encoding.sld' has the alphabets,
      ;; but its one entry point, `encode-data', is a TODO stub, so the
      ;; code below is all of it: no line breaks, `=' padding, as
      ;; Emacs's `base64-encode-string' with `:no-line-break' makes.
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    (define (xterm--base64-value char)
      ;; CHAR's value in `*base64-alphabet'', or #f when it has none -
      ;; which includes the padding `='.
      ;;--------------------------------------------------------------
      (string-contains *base64-alphabet* (string char)))

    (define (xterm--base64-encode bytevector)
      ;; Base64 of BYTEVECTOR. Three bytes become four characters; a
      ;; remainder of one or two pads.
      ;;--------------------------------------------------------------
      (let ((len (bytevector-length bytevector)))
        (let loop ((i 0) (acc '()))
          (if (>= i len)
              (list->string (reverse acc))
              (let* ((rem (- len i))
                     (b0 (bytevector-u8-ref bytevector i))
                     (b1 (if (> rem 1) (bytevector-u8-ref bytevector (+ i 1)) 0))
                     (b2 (if (> rem 2) (bytevector-u8-ref bytevector (+ i 2)) 0))
                     (n (+ (* b0 65536) (* b1 256) b2)))
                (let* ((acc (cons (string-ref *base64-alphabet*
                                              (quotient n 262144))
                                  acc))
                       (acc (cons (string-ref *base64-alphabet*
                                              (modulo (quotient n 4096) 64))
                                  acc))
                       (acc (if (> rem 1)
                                (cons (string-ref *base64-alphabet*
                                                  (modulo (quotient n 64) 64))
                                      acc)
                                (cons #\= acc)))
                       (acc (if (> rem 2)
                                (cons (string-ref *base64-alphabet* (modulo n 64))
                                      acc)
                                (cons #\= acc))))
                  (loop (+ i 3) acc)))))))

    (define (xterm--base64-decode string)
      ;; STRING's base64 as a bytevector, or #f when STRING is not
      ;; base64 - which is how a terminal's denial (`52;c;!') comes
      ;; back as no text at all.
      ;;--------------------------------------------------------------
      (let ((len (string-length string)))
        (let loop ((i 0) (acc '()))
          (cond
           ((>= i len)
            (let* ((n (length acc))
                   (out (make-bytevector n)))
              (let build ((j 0) (rest (reverse acc)))
                (when (pair? rest)
                  (bytevector-u8-set! out j (car rest))
                  (build (+ j 1) (cdr rest))))
              out))
           ;; Not padded to a multiple of four.
           ((> (+ i 4) len) #f)
           (else
            (let* ((v0 (xterm--base64-value (string-ref string i)))
                   (v1 (xterm--base64-value (string-ref string (+ i 1))))
                   (c2 (string-ref string (+ i 2)))
                   (c3 (string-ref string (+ i 3)))
                   (v2 (if (char=? c2 #\=)
                           #f
                           (xterm--base64-value c2)))
                   (v3 (if (char=? c3 #\=)
                           #f
                           (xterm--base64-value c3))))
              (cond
               ((not (and v0 v1)) #f)
               ;; `==': one byte, whose top six bits are V0's and whose
               ;; bottom two are the top two of V1.
               ((char=? c2 #\=)
                (if (char=? c3 #\=)
                    (loop (+ i 4)
                          (cons (logior (ash v0 2) (quotient v1 16)) acc))
                    #f))
               ;; `=': two bytes.
               ((char=? c3 #\=)
                (loop (+ i 4)
                      (cons (logior (ash (modulo v1 16) 4) (quotient v2 4))
                            (cons (logior (ash v0 2) (quotient v1 16))
                                  acc))))
               (else
                (loop (+ i 4)
                      (cons (logior (ash (modulo v2 4) 6) v3)
                            (cons (logior (ash (modulo v1 16) 4) (quotient v2 4))
                                  (cons (logior (ash v0 2) (quotient v1 16))
                                        acc))))))))))))

    (define (xterm--selection-char type)
      ;; GNU Emacs's `xterm--selection-char': the one-letter selection
      ;; name an OSC 52 sequence carries.
      ;;--------------------------------------------------------------
      (cond ((eq? type 'PRIMARY) "p")
            ((eq? type 'CLIPBOARD) "c")
            (else (error "Invalid selection type" type))))

    (define (xterm--init-activate-get-selection)
      ;; GNU Emacs's `xterm--init-activate-get-selection'.
      ;;--------------------------------------------------------------
      (*xterm--get-selection* #t))

    (define (xterm--init-activate-set-selection)
      ;; GNU Emacs's `xterm--init-activate-set-selection'.
      ;;--------------------------------------------------------------
      (*xterm--set-selection* #t))

    (define (xterm--tty-set-selection selection data)
      ;; The body of `gui-backend-set-selection''s tty method
      ;; (`xterm.el:1161'): "Copy DATA to the X selection using the
      ;; OSC 52 escape sequence."
      ;;
      ;; Not ported: the Device Control String wrapper for `screen',
      ;; which this tree never initialises for (`terminal-init-screen'
      ;; is not here, and `TERM=screen*' does not reach
      ;; `terminal-init-xterm') - so the bare-sequence branch only, and
      ;; the chopping of long DCS sequences with it. A `#f' DATA -
      ;; Emacs's "disown it" - is a no-op, where the window-system
      ;; method disowns: an OSC 52 sequence cannot take a selection
      ;; away, and nothing can be sent that would.
      ;;--------------------------------------------------------------
      (when (*xterm--set-selection*)
        ;; A #f DATA - Emacs's "disown it" - sends nothing, and is
        ;; checked before the string the rest expects.
        (when data
          (unless (string? data)
            (error "Selection value must be a string" data))
          (let* ((base64 (xterm--base64-encode (string->utf8 data)))
                 (length (string-length base64)))
            (if (> length (xterm-max-cut-length))
                ;; Emacs warns - "Selection too long to send to terminal:
                ;; N bytes" - and sits for two seconds; xterm.sld has no
                ;; frame or echo area to reach, so the cut is skipped in
                ;; silence.
                #f
                (xterm--send-string-to-terminal
                 (string-append
                  (string #\escape #\] #\5 #\2 #\;)
                  (xterm--selection-char selection)
                  ";" base64 (string #\bel))))))))

    (define (xterm--tty-get-selection selection data-type)
      ;; The body of `gui-backend-get-selection''s tty method
      ;; (`xterm.el:1131'): ask with `\e]52;<char>;?', and read the
      ;; reply - the base64 of the selection, or `!' when the terminal
      ;; will not give it, or nothing at all when the terminal does not
      ;; speak OSC 52. The query uses ST as its terminator to get ST as
      ;; the reply's (bug#36879), and a reply is waited for
      ;; `xterm-query-timeout' - the two seconds `C-y' costs on a
      ;; terminal that stays silent, which is why the gate is off by
      ;; default.
      ;;--------------------------------------------------------------
      ;; Emacs's method has a cl-defmethod context that also refuses
      ;; the question when the terminal was initialised as `screen' -
      ;; bug#36879 again - which here is folded into the gate: a screen
      ;; never runs this init, so the parameter is #f, and an explicit
      ;; override would not be second-guessed the way Emacs's is.
      ;;--------------------------------------------------------------
      ;; The gate answers #f, not `when''s unspecified: the method's
      ;; caller asks "is there text?", and unspecified is true in
      ;; Scheme - C-y would paste an empty string rather than the kill.
      ;;--------------------------------------------------------------
      (if (*xterm--get-selection*)
          (begin
            (unless (eq? data-type 'STRING)
              (error "Unsupported data type" data-type))
            (let ((prefix (string #\escape #\] #\5 #\2 #\;
                                  (string-ref (xterm--selection-char selection) 0)
                                  #\;)))
              (let ((reply
                     (xterm--query (string-append prefix "?"
                                                  (string #\escape #\\))
                                   (list (cons prefix
                                               ;; Read data up to the string
                                               ;; terminator, ST.
                                               (lambda ()
                                                 (xterm--read-string
                                                  #\escape #\\)))))))
                ;; A silent terminal answers the prefix match with nothing
                ;; readable - not a string - and a denial is `!', which is
                ;; not base64: both come out as #f, "no text".
                (and (string? reply)
                     (let ((bytes (xterm--base64-decode reply)))
                       (and bytes (utf8->string bytes)))))))
          #f))

    (define (xterm--set-background-mode redc greenc bluec)
      ;; GNU Emacs's `xterm--set-background-mode': "Use the heuristic in
      ;; `frame-set-background-mode' to decide if a frame is dark." Emacs
      ;; sets the terminal parameter `background-mode', which
      ;; `frame-terminal-default-bg-mode' reads; here that is
      ;; `*frame-background-mode*', the one place the specs look.
      ;;--------------------------------------------------------------
      (*frame-background-mode*
       (if (< (+ redc greenc bluec) (* .6 (+ 65535 65535 65535)))
           'dark
           'light)))

    (define (terminal-init-xterm)
      ;; GNU Emacs's `terminal-init-xterm', which is `xterm--init': the
      ;; colours the terminal has, then - `xterm-extra-capabilities' being
      ;; `check' - the Secondary Device Attributes query, whose handler
      ;; asks about the colours when the terminal is one that answers.
      ;; Then, if the background was reported, the background mode.
      ;;
      ;; Emacs's `tty-set-up-initial-frame-faces' runs here as well, twice
      ;; if the mode changed; the caller recalculates the faces once after
      ;; this returns, which is the same thing done once.
      ;;--------------------------------------------------------------
      (xterm-register-default-colors xterm-standard-colors)
      ;; Try to find out the type of terminal by sending a "Secondary
      ;; Device Attributes (DA)" query.
      (xterm--query (string #\escape #\[ #\> #\0 #\c)
                    (list (cons (string #\escape #\[ #\>) xterm--version-handler)))
      (let ((bg-color (*xterm--background-color*)))
        (when bg-color
          (apply xterm--set-background-mode bg-color))))


    (define *input-decode-map*
      ;; GNU Emacs's `input-decode-map' as `term/xterm.el' fills it: "The
      ;; mapping from escape sequences to Fn is done in input-decode-map"
      ;; (`xterm.el:671'). `xterm--init' pushes two maps into it,
      ;; `xterm-rxvt-function-map' (`xterm.el:211') and
      ;; `xterm-function-map' (`:252', which takes the rxvt one as its
      ;; *parent*); what is here is both flattened, the parent/child split
      ;; being a keymap-inheritance detail with no counterpart in a table
      ;; of (SEQUENCE . EVENT).
      ;;
      ;; It is keyed on the *escape sequence*, which is Emacs's own
      ;; architecture and the whole reason a modified function key can be
      ;; read at all. ncurses decodes `\e[1;3A' into a keycode it has no
      ;; constant for; `(keyname)' names that keycode from terminfo, and
      ;; for these it answers a terminfo name - `kUP3' - which `tiget'
      ;; turns back into `\e[1;3A', the sequence below. Nothing parses a
      ;; modifier out of a name, which is what the code this replaced did
      ;; and why it could not work.
      ;;
      ;; 255 entries, transcribed from `xterm.el:211-661'.
      ;;
      ;; A parameter rather than a plain list because Emacs's is a
      ;; *variable* - `input-decode-map' is a keymap a package can
      ;; `define-key' into - and a parameter is this tree's spelling of
      ;; one.
      ;;--------------------------------------------------------------
      (make-parameter (list
            (cons "\x1b;O2A" 'S-up)
            (cons "\x1b;O2B" 'S-down)
            (cons "\x1b;O2C" 'S-right)
            (cons "\x1b;O2D" 'S-left)
            (cons "\x1b;O2F" 'S-end)
            (cons "\x1b;O2H" 'S-home)
            (cons "\x1b;O2P" 'S-f1)
            (cons "\x1b;O2Q" 'S-f2)
            (cons "\x1b;O2R" 'S-f3)
            (cons "\x1b;O2S" 'S-f4)
            (cons "\x1b;O2j" 'S-kp-multiply)
            (cons "\x1b;O2k" 'S-kp-add)
            (cons "\x1b;O2l" 'S-kp-separator)
            (cons "\x1b;O2m" 'S-kp-subtract)
            (cons "\x1b;O2o" 'S-kp-divide)
            (cons "\x1b;O2p" 'S-kp-0)
            (cons "\x1b;O2q" 'S-kp-1)
            (cons "\x1b;O2r" 'S-kp-2)
            (cons "\x1b;O2s" 'S-kp-3)
            (cons "\x1b;O2t" 'S-kp-4)
            (cons "\x1b;O2u" 'S-kp-5)
            (cons "\x1b;O2v" 'S-kp-6)
            (cons "\x1b;O2w" 'S-kp-7)
            (cons "\x1b;O2x" 'S-kp-8)
            (cons "\x1b;O2y" 'S-kp-9)
            (cons "\x1b;O3P" 'M-f1)
            (cons "\x1b;O3Q" 'M-f2)
            (cons "\x1b;O3R" 'M-f3)
            (cons "\x1b;O3S" 'M-f4)
            (cons "\x1b;O4P" 'M-S-f1)
            (cons "\x1b;O4Q" 'M-S-f2)
            (cons "\x1b;O4R" 'M-S-f3)
            (cons "\x1b;O4S" 'M-S-f4)
            (cons "\x1b;O4j" 'M-S-kp-multiply)
            (cons "\x1b;O4k" 'M-S-kp-add)
            (cons "\x1b;O4l" 'M-S-kp-separator)
            (cons "\x1b;O4m" 'M-S-kp-subtract)
            (cons "\x1b;O4o" 'M-S-kp-divide)
            (cons "\x1b;O4p" 'M-S-kp-0)
            (cons "\x1b;O4q" 'M-S-kp-1)
            (cons "\x1b;O4r" 'M-S-kp-2)
            (cons "\x1b;O4s" 'M-S-kp-3)
            (cons "\x1b;O4t" 'M-S-kp-4)
            (cons "\x1b;O4u" 'M-S-kp-5)
            (cons "\x1b;O4v" 'M-S-kp-6)
            (cons "\x1b;O4w" 'M-S-kp-7)
            (cons "\x1b;O4x" 'M-S-kp-8)
            (cons "\x1b;O4y" 'M-S-kp-9)
            (cons "\x1b;O5A" 'C-up)
            (cons "\x1b;O5B" 'C-down)
            (cons "\x1b;O5C" 'C-right)
            (cons "\x1b;O5D" 'C-left)
            (cons "\x1b;O5F" 'C-end)
            (cons "\x1b;O5H" 'C-home)
            (cons "\x1b;O5P" 'C-f1)
            (cons "\x1b;O5Q" 'C-f2)
            (cons "\x1b;O5R" 'C-f3)
            (cons "\x1b;O5S" 'C-f4)
            (cons "\x1b;O6P" 'C-S-f1)
            (cons "\x1b;O6Q" 'C-S-f2)
            (cons "\x1b;O6R" 'C-S-f3)
            (cons "\x1b;O6S" 'C-S-f4)
            (cons "\x1b;O6j" 'C-S-kp-multiply)
            (cons "\x1b;O6k" 'C-S-kp-add)
            (cons "\x1b;O6l" 'C-S-kp-separator)
            (cons "\x1b;O6m" 'C-S-kp-subtract)
            (cons "\x1b;O6o" 'C-S-kp-divide)
            (cons "\x1b;O6p" 'C-S-kp-0)
            (cons "\x1b;O6q" 'C-S-kp-1)
            (cons "\x1b;O6r" 'C-S-kp-2)
            (cons "\x1b;O6s" 'C-S-kp-3)
            (cons "\x1b;O6t" 'C-S-kp-4)
            (cons "\x1b;O6u" 'C-S-kp-5)
            (cons "\x1b;O6v" 'C-S-kp-6)
            (cons "\x1b;O6w" 'C-S-kp-7)
            (cons "\x1b;O6x" 'C-S-kp-8)
            (cons "\x1b;O6y" 'C-S-kp-9)
            (cons "\x1b;O8j" 'C-M-S-kp-multiply)
            (cons "\x1b;O8k" 'C-M-S-kp-add)
            (cons "\x1b;O8l" 'C-M-S-kp-separator)
            (cons "\x1b;O8m" 'C-M-S-kp-subtract)
            (cons "\x1b;O8o" 'C-M-S-kp-divide)
            (cons "\x1b;O8p" 'C-M-S-kp-0)
            (cons "\x1b;O8q" 'C-M-S-kp-1)
            (cons "\x1b;O8r" 'C-M-S-kp-2)
            (cons "\x1b;O8s" 'C-M-S-kp-3)
            (cons "\x1b;O8t" 'C-M-S-kp-4)
            (cons "\x1b;O8u" 'C-M-S-kp-5)
            (cons "\x1b;O8v" 'C-M-S-kp-6)
            (cons "\x1b;O8w" 'C-M-S-kp-7)
            (cons "\x1b;O8x" 'C-M-S-kp-8)
            (cons "\x1b;O8y" 'C-M-S-kp-9)
            (cons "\x1b;OA" 'up)
            (cons "\x1b;OB" 'down)
            (cons "\x1b;OC" 'right)
            (cons "\x1b;OD" 'left)
            (cons "\x1b;OF" 'end)
            (cons "\x1b;OH" 'home)
            (cons "\x1b;OP" 'f1)
            (cons "\x1b;OQ" 'f2)
            (cons "\x1b;OR" 'f3)
            (cons "\x1b;OS" 'f4)
            (cons "\x1b;OX" 'kp-equal)
            (cons "\x1b;Oj" 'kp-multiply)
            (cons "\x1b;Ok" 'kp-add)
            (cons "\x1b;Ol" 'kp-separator)
            (cons "\x1b;Om" 'kp-subtract)
            (cons "\x1b;Oo" 'kp-divide)
            (cons "\x1b;Op" 'kp-0)
            (cons "\x1b;Oq" 'kp-1)
            (cons "\x1b;Or" 'kp-2)
            (cons "\x1b;Os" 'kp-3)
            (cons "\x1b;Ot" 'kp-4)
            (cons "\x1b;Ou" 'kp-5)
            (cons "\x1b;Ov" 'kp-6)
            (cons "\x1b;Ow" 'kp-7)
            (cons "\x1b;Ox" 'kp-8)
            (cons "\x1b;Oy" 'kp-9)
            (cons "\x1b;[11~" 'f1)
            (cons "\x1b;[12~" 'f2)
            (cons "\x1b;[13~" 'f3)
            (cons "\x1b;[14~" 'f4)
            (cons "\x1b;[15;2~" 'S-f5)
            (cons "\x1b;[15;3~" 'M-f5)
            (cons "\x1b;[15;4~" 'M-S-f5)
            (cons "\x1b;[15;5~" 'C-f5)
            (cons "\x1b;[15;6~" 'C-S-f5)
            (cons "\x1b;[15~" 'f5)
            (cons "\x1b;[17;2~" 'S-f6)
            (cons "\x1b;[17;3~" 'M-f6)
            (cons "\x1b;[17;4~" 'M-S-f6)
            (cons "\x1b;[17;5~" 'C-f6)
            (cons "\x1b;[17;6~" 'C-S-f6)
            (cons "\x1b;[17~" 'f6)
            (cons "\x1b;[18;2~" 'S-f7)
            (cons "\x1b;[18;3~" 'M-f7)
            (cons "\x1b;[18;4~" 'M-S-f7)
            (cons "\x1b;[18;5~" 'C-f7)
            (cons "\x1b;[18;6~" 'C-S-f7)
            (cons "\x1b;[18~" 'f7)
            (cons "\x1b;[19;2~" 'S-f8)
            (cons "\x1b;[19;3~" 'M-f8)
            (cons "\x1b;[19;4~" 'M-S-f8)
            (cons "\x1b;[19;5~" 'C-f8)
            (cons "\x1b;[19;6~" 'C-S-f8)
            (cons "\x1b;[19~" 'f8)
            (cons "\x1b;[1;2A" 'S-up)
            (cons "\x1b;[1;2B" 'S-down)
            (cons "\x1b;[1;2C" 'S-right)
            (cons "\x1b;[1;2D" 'S-left)
            (cons "\x1b;[1;2F" 'S-end)
            (cons "\x1b;[1;2H" 'S-home)
            (cons "\x1b;[1;2P" 'S-f1)
            (cons "\x1b;[1;2Q" 'S-f2)
            (cons "\x1b;[1;2R" 'S-f3)
            (cons "\x1b;[1;2S" 'S-f4)
            (cons "\x1b;[1;3A" 'M-up)
            (cons "\x1b;[1;3B" 'M-down)
            (cons "\x1b;[1;3C" 'M-right)
            (cons "\x1b;[1;3D" 'M-left)
            (cons "\x1b;[1;3F" 'M-end)
            (cons "\x1b;[1;3H" 'M-home)
            (cons "\x1b;[1;4A" 'M-S-up)
            (cons "\x1b;[1;4B" 'M-S-down)
            (cons "\x1b;[1;4C" 'M-S-right)
            (cons "\x1b;[1;4D" 'M-S-left)
            (cons "\x1b;[1;4F" 'M-S-end)
            (cons "\x1b;[1;4H" 'M-S-home)
            (cons "\x1b;[1;5A" 'C-up)
            (cons "\x1b;[1;5B" 'C-down)
            (cons "\x1b;[1;5C" 'C-right)
            (cons "\x1b;[1;5D" 'C-left)
            (cons "\x1b;[1;5F" 'C-end)
            (cons "\x1b;[1;5H" 'C-home)
            (cons "\x1b;[1;6A" 'C-S-up)
            (cons "\x1b;[1;6B" 'C-S-down)
            (cons "\x1b;[1;6C" 'C-S-right)
            (cons "\x1b;[1;6D" 'C-S-left)
            (cons "\x1b;[1;6F" 'C-S-end)
            (cons "\x1b;[1;6H" 'C-S-home)
            (cons "\x1b;[1;7A" 'C-M-up)
            (cons "\x1b;[1;7B" 'C-M-down)
            (cons "\x1b;[1;7C" 'C-M-right)
            (cons "\x1b;[1;7D" 'C-M-left)
            (cons "\x1b;[1;7F" 'C-M-end)
            (cons "\x1b;[1;7H" 'C-M-home)
            (cons "\x1b;[1;8A" 'C-M-S-up)
            (cons "\x1b;[1;8B" 'C-M-S-down)
            (cons "\x1b;[1;8C" 'C-M-S-right)
            (cons "\x1b;[1;8D" 'C-M-S-left)
            (cons "\x1b;[1;8F" 'C-M-S-end)
            (cons "\x1b;[1;8H" 'C-M-S-home)
            (cons "\x1b;[1~" 'home)
            (cons "\x1b;[20;2~" 'S-f9)
            (cons "\x1b;[20;3~" 'M-f9)
            (cons "\x1b;[20;4~" 'M-S-f9)
            (cons "\x1b;[20;5~" 'C-f9)
            (cons "\x1b;[20;6~" 'C-S-f9)
            (cons "\x1b;[20~" 'f9)
            (cons "\x1b;[21;2~" 'S-f10)
            (cons "\x1b;[21;3~" 'M-f10)
            (cons "\x1b;[21;4~" 'M-S-f10)
            (cons "\x1b;[21;5~" 'C-f10)
            (cons "\x1b;[21;6~" 'C-S-f10)
            (cons "\x1b;[21~" 'f10)
            (cons "\x1b;[23;2~" 'S-f11)
            (cons "\x1b;[23;3~" 'M-f11)
            (cons "\x1b;[23;4~" 'M-S-f11)
            (cons "\x1b;[23;5~" 'C-f11)
            (cons "\x1b;[23;6~" 'C-S-f11)
            (cons "\x1b;[23~" 'f11)
            (cons "\x1b;[24;2~" 'S-f12)
            (cons "\x1b;[24;3~" 'M-f12)
            (cons "\x1b;[24;4~" 'M-S-f12)
            (cons "\x1b;[24;5~" 'C-f12)
            (cons "\x1b;[24;6~" 'C-S-f12)
            (cons "\x1b;[24~" 'f12)
            (cons "\x1b;[29~" 'menu)
            (cons "\x1b;[2;2~" 'S-insert)
            (cons "\x1b;[2;3~" 'M-insert)
            (cons "\x1b;[2;4~" 'M-S-insert)
            (cons "\x1b;[2;5~" 'C-insert)
            (cons "\x1b;[2;6~" 'C-S-insert)
            (cons "\x1b;[2;7~" 'C-M-insert)
            (cons "\x1b;[2;8~" 'C-M-S-insert)
            (cons "\x1b;[2~" 'insert)
            (cons "\x1b;[3;2~" 'S-delete)
            (cons "\x1b;[3;3~" 'M-delete)
            (cons "\x1b;[3;4~" 'M-S-delete)
            (cons "\x1b;[3;5~" 'C-delete)
            (cons "\x1b;[3;6~" 'C-S-delete)
            (cons "\x1b;[3;7~" 'C-M-delete)
            (cons "\x1b;[3;8~" 'C-M-S-delete)
            (cons "\x1b;[3~" 'delete)
            (cons "\x1b;[4~" 'select)
            (cons "\x1b;[5;2~" 'S-prior)
            (cons "\x1b;[5;3~" 'M-prior)
            (cons "\x1b;[5;4~" 'M-S-prior)
            (cons "\x1b;[5;5~" 'C-prior)
            (cons "\x1b;[5;6~" 'C-S-prior)
            (cons "\x1b;[5;7~" 'C-M-prior)
            (cons "\x1b;[5;8~" 'C-M-S-prior)
            (cons "\x1b;[5~" 'prior)
            (cons "\x1b;[6;2~" 'S-next)
            (cons "\x1b;[6;3~" 'M-next)
            (cons "\x1b;[6;4~" 'M-S-next)
            (cons "\x1b;[6;5~" 'C-next)
            (cons "\x1b;[6;6~" 'C-S-next)
            (cons "\x1b;[6;7~" 'C-M-next)
            (cons "\x1b;[6;8~" 'C-M-S-next)
            (cons "\x1b;[6~" 'next)
            (cons "\x1b;[A" 'up)
            (cons "\x1b;[B" 'down)
            (cons "\x1b;[C" 'right)
            (cons "\x1b;[D" 'left))))
    ))
