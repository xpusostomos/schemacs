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
  ;; Not ported: the key maps (`xterm-function-map' - the keys come
  ;; through ncurses's terminfo lookup here), `modifyOtherKeys', the
  ;; selection (OSC 52), the window title, the cursor updates,
  ;; bracketed paste and focus tracking, the mouse, and
  ;; `xterm--maybe-update-default-face', which gives the `default' face
  ;; the exact colours the terminal reported. The rxvt hand-off at the
  ;; top of `xterm--init' is not either: `term/rxvt.el' is not here.
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
    ;; read with `string->number' in base 16.
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
   *xterm--background-color*
   *xterm--foreground-color*
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
      ;; terminal is one that answers the colour queries. Emacs also
      ;; turns on `modifyOtherKeys' for version 216 and later, which is
      ;; not ported.
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
                  (xterm--query-colors))))))))

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

    ))
