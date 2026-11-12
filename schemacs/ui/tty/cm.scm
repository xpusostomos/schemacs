(define-library (schemacs ui tty cm)
  ;; GNU Emacs's `src/cm.c': cursor motion, and the cost model that picks
  ;; the cheapest way to get from where the cursor is to where it should
  ;; be.
  ;;
  ;;   cmputc          write one byte to the terminal
  ;;   evalcost        count one byte as one unit of cost
  ;;   cmcheckmagic    the cursor reached the right margin
  ;;   cmcostinit      measure each motion's cost, once, from terminfo
  ;;   calccost        the cost of up/down/left/right/tabs between two
  ;;                   positions, and optionally the motion itself
  ;;   cmgoto          the cheapest of home, last-line, CR, relative and
  ;;                   absolute, and then it
  ;;   Wcm_clear       forget everything, including where the cursor is
  ;;   Wcm_init        refuse a terminal that cannot address the cursor
  ;;
  ;; **This is why Emacs's tty output is short.** ncurses has a cost
  ;; model of its own (`_nc_mvcur`), and it is a different one - a table
  ;; sampled from the terminal's speeds rather than measured from the
  ;; capability strings this terminal actually has. Once the screen is
  ;; ours there is no second model to disagree with.
  ;;
  ;; The structure this walks is `struct cm` (`cm.h`), a field per
  ;; capability plus a field per cost.
  ;;
  ;; Four departures from the C, all named where they happen: the record
  ;; is a Scheme record rather than a struct reached through pointer
  ;; macros; `emacs_tputs` is a plain write (this tree has no
  ;; termscript); `tputs`' padding is stripped here rather than by the
  ;; library, which is what it amounts to at baud 0; and `tgoto` is
  ;; `tparm` over the capability's own format, with the swap the caller
  ;; does because `cup` names row first.

  (import (scheme base)
          (only (guile) logior logand ash)
          ;; `display` is `(scheme write)`'s - `(scheme base)` does not
          ;; export it.
          (only (scheme write) display)
          (only (schemacs ui tty tinfo) tgetstr tigetnum tigetflag tparm))

  (export
   <cm> make-cm
   cm-rows cm-cols cm-curY cm-curX
   set-cm-curY! set-cm-curX!
   ;; The screen's size, which `adjust_frame_size` writes when a tty
   ;; frame is resized (`frame.c:1053`, `:1088`) and which nothing here
   ;; had a way to write.
   set-cm-rows! set-cm-cols!
   cmputc set-cmputc!
   cmcheckmagic
   cmcostinit calccost cmgoto
   Wcm-clear Wcm-init losecursor
   %cm-initialize!
   *cost*
   ;; the capability strings and their costs, which the terminal's own
   ;; hooks and the tests read
   cm-up cm-down cm-left cm-right cm-home cm-cr cm-ll cm-tab
   cm-abs cm-habs cm-vabs
   cm-autowrap cm-magicwrap cm-usetabs cm-losewrap cm-autolf
   cm-tabwidth
   cm-cc-up cm-cc-down cm-cc-left cm-cc-right cm-cc-home cm-cc-cr
   cm-cc-ll cm-cc-tab cm-cc-abs cm-cc-habs cm-cc-vabs)

  (begin

    (define BIG 9999)
    ;; ^ The C's "cannot get there from here".

    ;;----------------------------------------------------------------
    ;; The structure: what the terminal can do, and what each motion costs
    ;;----------------------------------------------------------------

    (define-record-type <cm>
      (make-cm)
      cm?
      ;; where the cursor is, -1 in both when that is not known
      (curY cm-curY set-cm-curY!)
      (curX cm-curX set-cm-curX!)
      ;; the capability strings, termcap's names
      (up cm-up set-cm-up!)
      (down cm-down set-cm-down!)
      (left cm-left set-cm-left!)
      (right cm-right set-cm-right!)
      (home cm-home set-cm-home!)
      (cr cm-cr set-cm-cr!)
      (ll cm-ll set-cm-ll!)
      (tab cm-tab set-cm-tab!)
      (abs cm-abs set-cm-abs!)
      (habs cm-habs set-cm-habs!)
      (vabs cm-vabs set-cm-vabs!)
      ;; the screen, and how tabs behave on it
      (cols cm-cols set-cm-cols!)
      (rows cm-rows set-cm-rows!)
      (tabwidth cm-tabwidth set-cm-tabwidth!)
      (autowrap cm-autowrap set-cm-autowrap!)
      (magicwrap cm-magicwrap set-cm-magicwrap!)
      (usetabs cm-usetabs set-cm-usetabs!)
      (losewrap cm-losewrap set-cm-losewrap!)
      (autolf cm-autolf set-cm-autolf!)
      ;; the costs, filled in by `cmcostinit'
      (cc-up cm-cc-up set-cm-cc-up!)
      (cc-down cm-cc-down set-cm-cc-down!)
      (cc-left cm-cc-left set-cm-cc-left!)
      (cc-right cm-cc-right set-cm-cc-right!)
      (cc-home cm-cc-home set-cm-cc-home!)
      (cc-cr cm-cc-cr set-cm-cc-cr!)
      (cc-ll cm-cc-ll set-cm-cc-ll!)
      (cc-tab cm-cc-tab set-cm-cc-tab!)
      (cc-abs cm-cc-abs set-cm-cc-abs!)
      (cc-habs cm-cc-habs set-cm-cc-habs!)
      (cc-vabs cm-cc-vabs set-cm-cc-vabs!))

    (define *cost* 0)
    ;; ^ The C's global `cost`, which `evalcost` sums into.

    (define %putc
      ;; `cmputc` - how a byte leaves. `set-cmputc!` installs it, because
      ;; the writer belongs to whoever owns the terminal, and this
      ;; library must not guess.
      ;;--------------------------------------------------------------
      #f)

    (define (set-cmputc! proc) (set! %putc proc))

    (define (cmputc c)
      ;; GNU Emacs's `cmputc`: one byte to the terminal's output, masked
      ;; to seven bits. THE TERMSCRIPT HALF IS NOT CARRIED.
      ;;--------------------------------------------------------------
      (when %putc (%putc (logand c #o177)))
      c)

    (define (evalcost c)
      ;; GNU Emacs's `evalcost`: count a byte, and answer it so the walk
      ;; can go on.
      ;;--------------------------------------------------------------
      (set! *cost* (+ *cost* 1))
      c)

    ;;----------------------------------------------------------------
    ;; Writing a capability, and pricing one
    ;;----------------------------------------------------------------

    (define (%strip-padding string)
      ;; `$<n>` is a delay, and `tputs` with `baud_rate` 0 emits nothing
      ;; for one - which is what a pseudo-terminal asks for, and what the
      ;; terminal here gets.
      ;;--------------------------------------------------------------
      (let loop ((chars (string->list string)) (out '()))
        (cond
         ((null? chars) (list->string (reverse out)))
         ((char=? (car chars) #\$)
          (let ((rest (cdr chars)))
            (if (and (pair? rest) (char=? (car rest) #\<))
                (let skip ((r rest))
                  (cond ((null? r) (list->string (reverse out)))
                        ((char=? (car r) #\>) (loop (cdr r) out))
                        (else (skip (cdr r)))))
                (loop rest (cons #\$ out)))))
         (else (loop (cdr chars) (cons (car chars) out))))))

    (define (%emit string)
      ;; `emacs_tputs (tty, str, 1, cmputc)` - write STRING a byte at a
      ;; time, so the cursor's position and the byte count stay in step.
      ;;--------------------------------------------------------------
      (when string
        (let ((chars (string->list (%strip-padding string))))
          (for-each (lambda (ch) (cmputc (char->integer ch))) chars))))

    (define (%price string)
      ;; The same walk through `evalcost` instead: `tputs (str, 1,
      ;; evalcost)` and then read the counter back.
      ;;--------------------------------------------------------------
      (if (not string)
          BIG
          (begin
            (set! *cost* 0)
            (let ((chars (string->list (%strip-padding string))))
              (for-each (lambda (ch) (evalcost (char->integer ch))) chars))
            *cost*)))

    (define (%cap-expand cap a b)
      ;; `tgoto` - expand CAP for one position, or "" when the terminal
      ;; has no such capability.
      ;;
      ;; The C's `tgoto` takes (x, y) and swaps for `cm` but not for
      ;; `ch`/`cv`; here the arguments arrive already in the capability's
      ;; own order, which is `tparm`'s, so there is nothing to swap. That
      ;; is the same thing the C's `tparam` wrapper (`tparam.c`) does -
      ;; and `term.c:1280` calls `tparam` for the face sequences, not
      ;; `tgoto`.
      ;;--------------------------------------------------------------
      ;; **CAP here is already the capability *string*.** `tparm` expands
      ;; a string; a termcap name it cannot resolve, because `tinfo`'s
      ;; `tparm` looks a name up with `tigetstr` and `cm.scm` speaks
      ;; termcap (`cm`, not `cup`). Passing the name made every expansion
      ;; "" and every absolute move free - measured, `cc-abs` was 0 and
      ;; `cmgoto` chose to address absolutely and then emitted nothing, so
      ;; a second screen row was drawn over the first.
      ;;--------------------------------------------------------------
      (if (not cap)
          ""
          (or (tparm cap a b) "")))

    (define (cmcheckmagic tty)
      ;; GNU Emacs's `cmcheckmagic`: on a terminal with `xn`, reaching the
      ;; right margin leaves the cursor in a phantom column, and the only
      ;; guaranteed-safe thing is CR LF from there.
      ;;
      ;; The C `emacs_abort`s when the cursor is past the last row on a
      ;; non-magicwrap terminal. Nothing here should reach that, and an
      ;; abort is not a behaviour to port - it is the C saying "this
      ;; cannot happen". A no-op is the honest answer.
      ;;--------------------------------------------------------------
      (when (= (cm-curX tty) (cm-cols tty))
        (when (and (cm-magicwrap tty)
                   (< (cm-curY tty) (- (cm-rows tty) 1)))
          (cmputc (char->integer #\return))
          (cmputc (char->integer #\newline))
          (set-cm-curX! tty 0)
          (set-cm-curY! tty (+ (cm-curY tty) 1)))))

    (define (cmcostinit tty)
      ;; GNU Emacs's `cmcostinit`: price every motion once, by writing it
      ;; through `evalcost` and reading the counter back.
      ;;
      ;; The three parameterised capabilities get their MINIMUM cost, by
      ;; expanding at (0, 0) - "the real cost is computed when (if) they
      ;; are candidates for the least-cost motion".
      ;;--------------------------------------------------------------
      (set-cm-cc-up! tty (%price (cm-up tty)))
      (set-cm-cc-down! tty (%price (cm-down tty)))
      (set-cm-cc-left! tty (%price (cm-left tty)))
      (set-cm-cc-right! tty (%price (cm-right tty)))
      (set-cm-cc-home! tty (%price (cm-home tty)))
      (set-cm-cc-cr! tty (%price (cm-cr tty)))
      (set-cm-cc-ll! tty (%price (cm-ll tty)))
      (set-cm-cc-tab! tty (if (cm-tabwidth tty) (%price (cm-tab tty)) BIG))
      (set-cm-cc-abs! tty (if (cm-abs tty)
                              (%price (%cap-expand (cm-abs tty) 0 0))
                              BIG))
      (set-cm-cc-habs! tty (if (cm-habs tty)
                               (%price (%cap-expand (cm-habs tty) 0 0))
                               BIG))
      (set-cm-cc-vabs! tty (if (cm-vabs tty)
                               (%price (%cap-expand (cm-vabs tty) 0 0))
                               BIG)))

    ;;----------------------------------------------------------------
    ;; The cost of a motion
    ;;----------------------------------------------------------------

    (define (%repeat n proc)
      ;; Call PROC N times - the C's `do { ... } while (--deltay > 0)`.
      ;;--------------------------------------------------------------
      (let loop ((k n))
        (when (> k 0)
          (proc)
          (loop (- k 1)))))

    (define (calccost tty srcy srcx dsty dstx doit)
      ;; GNU Emacs's `calccost`: the cost to get from (SRCY, SRCX) to
      ;; (DSTY, DSTX) with up/down/left/right and tabs, and with DOIT the
      ;; motion itself.
      ;;
      ;; Answers a pair `(COST . OK?)` - the C's BIG return is `(BIG
      ;; . #f)`, and its happy returns are `(cost . #t)`. A pair and not
      ;; two values, because the caller adds it to other costs.
      ;;--------------------------------------------------------------
      (if (= (cm-curX tty) (cm-cols tty))
          ;; "If we have just wrapped on a terminal with xn, don't believe
          ;; the cursor position: give up here and force absolute."
          (cons BIG #f)
          (let ((totalcost 0))
            (let* ((deltay (- dsty srcy))
                   (up? (< deltay 0))
                   (ay (abs deltay))
                   (c (if up? (cm-cc-up tty) (cm-cc-down tty))))
              (cond
               ((= c BIG) (set! totalcost BIG))
               ((zero? ay) #t)
               (else
                (set! totalcost (* c ay))
                (when doit
                  (%repeat ay (lambda () (%emit (if up? (cm-up tty) (cm-down tty)))))))))
            (if (= totalcost BIG)
                (cons BIG #f)
                (let ((deltax (- dstx srcx)))
                  (cond
                   ((zero? deltax) (cons totalcost #t))
                   (else
                    (let ((srcx2 srcx))
                      ;; --- tabs: "the toughie" ---
                      ;; `tty_cursor_movement_use_TAB' is Emacs's user
                      ;; option and its default is 1 (`term.c:5379`);
                      ;; `tty_cursor_movement_use_TAB_BS' (overshoot a
                      ;; tab then back up) defaults to 0 in Emacs 31 and
                      ;; is not carried - with it off, `c` is BIG and
                      ;; `ntabs` is never replaced, which is what the
                      ;; `if` around it amounts to.
                      (when (and (cm-usetabs tty)
                                 (not (= (cm-cc-tab tty) BIG))
                                 (cm-tabwidth tty))
                        (let* ((tw (cm-tabwidth tty))
                               (ntabs (quotient (+ deltax (modulo srcx tw)) tw))
                               (tabx (* (+ (quotient srcx tw) ntabs) tw))
                               (tabcost (if (> ntabs 0)
                                            (+ (* ntabs (cm-cc-tab tty))
                                               (* (- dstx tabx) (cm-cc-right tty)))
                                            BIG)))
                          (when (and (< tabcost BIG)
                                     (< tabcost (* deltax (cm-cc-right tty))))
                            (set! totalcost (+ totalcost tabcost))
                            (when doit
                              (%repeat ntabs (lambda () (%emit (cm-tab tty)))))
                            (set! srcx2 tabx))))
                      ;; --- the rest, right or left ---
                      (let* ((d2 (- dstx srcx2))
                             (right? (> d2 0))
                             (ad (abs d2))
                             (c2 (cond ((zero? d2) 0)
                                       (right? (cm-cc-right tty))
                                       (else (cm-cc-left tty)))))
                        (cond
                         ((and (> ad 0) (= c2 BIG)) (cons BIG #f))
                         (else
                          (when doit
                            (%repeat ad
                                     (lambda ()
                                       (%emit (if right? (cm-right tty)
                                                  (cm-left tty))))))
                          (cons (+ totalcost (* c2 ad)) #t))))))))))))

    (define (cmgoto tty row col)
      ;; GNU Emacs's `cmgoto`: the cheapest of relative motion, home +
      ;; relative, last line + relative, CR + relative, and absolute -
      ;; and then the motion.
      ;;--------------------------------------------------------------
      (if (and (= row (cm-curY tty)) (= col (cm-curX tty)))
          #t
          (let* ((relcost (let ((r (calccost tty (cm-curY tty) (cm-curX tty)
                                            row col #f)))
                            (if (cdr r) (car r) BIG)))
                 (homecost (if (< (cm-cc-home tty) BIG)
                               (let ((r (calccost tty 0 0 row col #f)))
                                 (if (cdr r) (+ (cm-cc-home tty) (car r)) BIG))
                               BIG))
                 (llcost (if (< (cm-cc-ll tty) BIG)
                             (let ((r (calccost tty (- (cm-rows tty) 1) 0
                                                row col #f)))
                               (if (cdr r) (+ (cm-cc-ll tty) (car r)) BIG))
                             BIG))
                 (crcost (if (< (cm-cc-cr tty) BIG)
                             (let ((r (if (cm-autolf tty)
                                          (if (>= (+ (cm-curY tty) 1)
                                                  (cm-rows tty))
                                              (cons BIG #f)
                                              (calccost tty (+ (cm-curY tty) 1)
                                                        0 row col #f))
                                          (calccost tty (cm-curY tty) 0
                                                    row col #f))))
                               (if (cdr r) (+ (cm-cc-cr tty) (car r)) BIG))
                             BIG))
                 (use 'rel)
                 (relcost (if (< homecost relcost)
                              (begin (set! use 'home) homecost)
                              relcost))
                 (relcost (if (< llcost relcost)
                              (begin (set! use 'll) llcost)
                              relcost))
                 (relcost (if (< crcost relcost)
                              (begin (set! use 'cr) crcost)
                              relcost))
                 ;; the direct cost, and which capability it would use
                 (habs? (and (= row (cm-curY tty)) (< (cm-cc-habs tty) BIG)))
                 (vabs? (and (not habs?) (= col (cm-curX tty))
                             (< (cm-cc-vabs tty) BIG)))
                 (dcm (cond (habs? (cm-habs tty))
                            (vabs? (cm-vabs tty))
                            (else (cm-abs tty))))
                 (directcost (cond (habs? (cm-cc-habs tty))
                                   (vabs? (cm-cc-vabs tty))
                                   (else (cm-cc-abs tty)))))
            ;; "In the following comparison, the = in <= is because when
            ;; the costs are the same, it looks nicer to move directly."
            ;; **`ch` takes the COLUMN and `cv` takes the ROW.** The
            ;; C's `tgoto (dcm, col, row)` serves both because `tgoto`
            ;; hands its first argument to `%p1` and each capability
            ;; names the one it wants - `ch` is `%i%p1%dG` and `cv` is
            ;; `%i%p1%dd`. Passing `col` to both sent `cv` the column:
            ;; measured, a mode line bound for row 11 was moved with
            ;; `ESC[1d` - VPA to row 1 - and landed on row 0.
            (let ((expanded (cond (habs? (%cap-expand dcm col 0))
                                  (vabs? (%cap-expand dcm row 0))
                                  (else (%cap-expand dcm row col)))))
              (if (and dcm
                       (<= directcost relcost)
                       (<= (%price expanded) relcost))
                  (begin
                  (%emit expanded)
                  (set-cm-curY! tty row)
                  (set-cm-curX! tty col)
                  #t)
                (begin
                  (cond
                   ((eq? use 'home)
                    (%emit (cm-home tty))
                    (set-cm-curY! tty 0) (set-cm-curX! tty 0))
                   ((eq? use 'll)
                    (%emit (cm-ll tty))
                    (set-cm-curY! tty (- (cm-rows tty) 1)) (set-cm-curX! tty 0))
                   ((eq? use 'cr)
                    (%emit (cm-cr tty))
                    (when (cm-autolf tty)
                      (set-cm-curY! tty (+ (cm-curY tty) 1)))
                    (set-cm-curX! tty 0)))
                  (calccost tty (cm-curY tty) (cm-curX tty) row col #t)
                  (set-cm-curY! tty row)
                  (set-cm-curX! tty col)
                  #t))))))

    ;;----------------------------------------------------------------
    ;; Setting it up, and forgetting it
    ;;----------------------------------------------------------------

    (define (Wcm-clear tty)
      ;; GNU Emacs's `Wcm_clear`: forget everything, INCLUDING where the
      ;; cursor is - which is how `cmgoto` is forced to absolute-address.
      ;;--------------------------------------------------------------
      (set-cm-curY! tty -1)
      (set-cm-curX! tty -1)
      (set-cm-up! tty #f)
      (set-cm-down! tty #f)
      (set-cm-left! tty #f)
      (set-cm-right! tty #f)
      (set-cm-home! tty #f)
      (set-cm-cr! tty #f)
      (set-cm-ll! tty #f)
      (set-cm-tab! tty #f)
      (set-cm-abs! tty #f)
      (set-cm-habs! tty #f)
      (set-cm-vabs! tty #f)
      (set-cm-cols! tty 0)
      (set-cm-rows! tty 0)
      (set-cm-tabwidth! tty 0)
      (set-cm-autowrap! tty #f)
      (set-cm-magicwrap! tty #f)
      (set-cm-usetabs! tty #f)
      (set-cm-losewrap! tty #f)
      (set-cm-autolf! tty #f))

    (define (losecursor tty)
      ;; GNU Emacs's `losecursor` (`cm.h:158`): "curX = -1, curY = -1" -
      ;; forget WHERE the cursor is, and nothing else.
      ;;
      ;; **Not `Wcm-clear`.** `tty_set_terminal_modes` ends with
      ;; `losecursor (tty)` (`term.c:222`), and this port called
      ;; `Wcm-clear` there instead - which wipes every capability
      ;; string, so after entering the terminal `cmgoto` had no `cr`, no
      ;; `cup` and no `up`, and could emit nothing at all. Every row was
      ;; drawn where the last one ended. `Wcm_clear` is the C's
      ;; `memset` and belongs at terminal *initialisation* only.
      ;;--------------------------------------------------------------
      (set-cm-curX! tty -1)
      (set-cm-curY! tty -1))

    (define (Wcm-init tty)
      ;; GNU Emacs's `Wcm_init`: 0 when the terminal can address the
      ;; cursor, -1 when it cannot, -2 when its size is not known.
      ;;--------------------------------------------------------------
      (cond
       ((cm-abs tty) 0)
       ((or (not (cm-up tty)) (not (cm-left tty))) -1)
       ((or (not (cm-down tty)) (not (cm-right tty))) -1)
       ((or (<= (cm-rows tty) 0) (<= (cm-cols tty) 0)) -2)
       (else 0)))

    (define (%cm-initialize! tty rows cols)
      ;; Read the terminal's cursor capabilities into TTY, the way
      ;; `tty_init` does (`term.c:4597-4650`), then settle the flags and
      ;; the size.
      ;;
      ;; Two of these are not a plain `tgetstr`, and both are the C's:
      ;;  * `Left` is a literal backspace when `bs` is set - "can't
      ;;    possibly be longer" - and `le` or `bc` otherwise;
      ;;  * `Down` falls back to `nl`, an obsolete name for `do`.
      ;;--------------------------------------------------------------
      (Wcm-clear tty)
      (set-cm-abs! tty (tgetstr "cm"))
      (set-cm-habs! tty (tgetstr "ch"))
      (set-cm-vabs! tty (tgetstr "cv"))
      (set-cm-up! tty (tgetstr "up"))
      (set-cm-down! tty (or (tgetstr "do") (tgetstr "nl")))
      (set-cm-left! tty (if (> (tigetflag "bs") 0)
                            "\b"
                            (or (tgetstr "le") (tgetstr "bc"))))
      (set-cm-right! tty (tgetstr "nd"))
      (set-cm-home! tty (tgetstr "ho"))
      (set-cm-cr! tty (tgetstr "cr"))
      (set-cm-ll! tty (tgetstr "ll"))
      (set-cm-tab! tty (tgetstr "ta"))
      (set-cm-tabwidth! tty (max 0 (tigetnum "it")))
      ;; **`xenl`, not `xn`.** `tgetflag ("xn")` is termcap's name for
      ;; it and `tigetflag` is terminfo's, where the capability is
      ;; `xenl`. Measured on this terminal, `xn` answers -1 and `xenl`
      ;; answers 1 - so magicwrap was off when it should be on, `cmplus`
      ;; booked a wrap the terminal had only *armed*, and every row was
      ;; one lower than the picture. The same trap as `Co`/`colors`.
      (set-cm-magicwrap! tty (> (tigetflag "xenl") 0))
      ;; "Since we make MagicWrap terminals look like AutoWrap, we need
      ;; to have the former flag imply the latter."
      (set-cm-autowrap! tty (or (cm-magicwrap tty) (> (tigetflag "am") 0)))
      (set-cm-losewrap! tty #f)
      (set-cm-autolf! tty (> (tigetflag "rn") 0))
      ;; `UseTabs` is "tabs_safe_p && TabWidth == 8" (`term.c:5008`),
      ;; and `tabs_safe_p` is the output mode's `TABDLY` not being
      ;; `TAB3` - which `init_sys_modes` has just switched off, so it is
      ;; true. Named rather than asked: this is a terminal whose output
      ;; we have just put in raw mode.
      (set-cm-usetabs! tty (and (= (cm-tabwidth tty) 8) #t))
      (set-cm-rows! tty rows)
      (set-cm-cols! tty cols)
      tty)

    ))
