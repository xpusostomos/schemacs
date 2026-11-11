(define-library (schemacs ui tty tinfo)
  ;; GNU Emacs's `src/termcap.c` and the terminfo *client* half of
  ;; `src/term.c`: the six functions that read the terminal's description
  ;; and write a capability string out.
  ;;
  ;;   setup-term   read the terminal's description from $TERM
  ;;   tigetstr     a string capability   (`cup`, `csr`, `smcup`, ...)
  ;;   tigetnum     a numeric capability  (`colors`, `lines`, `cols`)
  ;;   tigetflag    a boolean capability  (`bce`, `xenl`, `am`)
  ;;   tparm        expand `%p1`-style parameters into the string
  ;;   tputs        emit a string, honouring `$<n>` padding
  ;;
  ;; **This is what Emacs links ncurses for.** `configure.ac:6100` names
  ;; the probe by `tputs` - "The required function 'tputs' was not found
  ;; in any library. The following libraries were tried (in order):
  ;; libtinfo, libncurses, libterminfo, libcurses, libtermcap" - and on
  ;; GNU/Linux `libtinfo` is tried first. So Emacs uses the library as a
  ;; **terminfo reader and writer**, the way it uses libpng, and never
  ;; calls `initscr`/`refresh`/`waddstr` at all (zero hits in `src/*.c`).
  ;;
  ;; This tree, until now, did the opposite: it drew *through* ncurses's
  ;; screen management, which Emacs owns for itself. That is the
  ;; departure `plans/TTY.md` removes, and this library is the layer that
  ;; replaces what was borrowed - nothing above it has changed yet, so
  ;; Phase 1 is a no-op for the screens.
  ;;
  ;; The library is `libncursesw.so.6` on this platform, which is also
  ;; what `libtinfo.so.6` resolves to. The name is asked for in that
  ;; order, as `configure.ac` does.
  ;;
  ;; See `plans/TTY.md`.

  (import (scheme base)
          ;; `dynamic-link` and `dynamic-func` are core bindings, and an
          ;; R7RS library does not see them without this - the same
          ;; import `pgtk.scm` and `fileio.scm` make for their FFI.
          (only (guile) dynamic-link dynamic-func inexact->exact
                string-contains false-if-exception)
          ;; The pointer surface is `(system foreign)`'s, not `(guile)`'s -
          ;; `string->pointer`, `pointer->string`, `pointer-address`,
          ;; `pointer->procedure`, `make-c-struct` **and `%null-pointer`**,
          ;; which is a *variable holding a NULL*, not a constructor:
          ;; `(%null-pointer)` is "wrong type to apply: pointer 0x0".
          ;; **Whole, not `only`**: the C type descriptors `int`, `long`
          ;; and `void` and the `*` wildcard are core bindings that no
          ;; module exports, so an `only` list cannot name them - measured,
          ;; "no binding `*' in module (system foreign)".
          (system foreign)
          ;; `display` is `(scheme write)`'s - `(scheme base)` does not
          ;; export it, which is the trap `term.sld` already records:
          ;; a helper written with `display` dies on its first line and
          ;; leaves an empty log behind.
          (only (scheme write) display))

  (export setup-term tgetstr tigetstr tigetnum tigetflag
          tparm tputs
          ;; the capability cache, and whether there is a terminal at all
          tinfo-capability tinfo-ready? tinfo-close!)

  (begin

    ;;----------------------------------------------------------------
    ;; The library, and the terminal it describes
    ;;----------------------------------------------------------------

    (define %tinfo-libraries
      ;; In `configure.ac`'s order: `libtinfo` first, then `libncurses`.
      ;; On this machine they are one binary (`libtinfo.so.6` is a
      ;; symlink to `libncursesw.so.6`), so either name finds it.
      ;;--------------------------------------------------------------
      '("libtinfo.so.6" "libncursesw.so.6" "libncurses.so.6"))

    (define %tinfo-lib
      (let loop ((rest %tinfo-libraries))
        (cond ((null? rest) #f)
              ((false-if-exception (dynamic-link (car rest)))
               (dynamic-link (car rest)))
              (else (loop (cdr rest))))))

    (define (tinfo-ready?)
      ;; Is there a terminfo library to talk to? A build without one is
      ;; not an editor, but nothing here should crash over it.
      ;;--------------------------------------------------------------
      (and %tinfo-lib #t))

    (define (%fn name ret args)
      ;; One C function, or #f when the library has no such symbol.
      ;;--------------------------------------------------------------
      (and %tinfo-lib
           (pointer->procedure ret (dynamic-func name %tinfo-lib) args)))

    ;; `int setupterm (const char *term, int fd, int *errret)'.
    ;; TERM nil means "$TERM". ERR is a 0/1/-1 answer, not a failure the
    ;; function returns: `setupterm` returns OK or ERR and fills in why.
    (define %setupterm (%fn "setupterm" int (list '* int '*)))
    ;; `char *tigetstr (const char *capname)' - a pointer into a static
    ;; buffer, or (char *)-1 for a capability the terminal has not got,
    ;; which arrives here as a pointer that is *not* null.
    ;; `char *tgetstr (const char *capname, char **area)' - the
    ;; **termcap** spelling of a capability, which is what `term.c` uses
    ;; for every face attribute: `tgetstr ("md")` is `ESC[1m` where
    ;; `tigetstr ("md")` is #f, because terminfo calls bold `bold`. The
    ;; AREA argument is a `char **` ncurses may write its own buffer
    ;; into; #f means "use your internal buffer", which is what every
    ;; `term.c` call passes.
    (define %tgetstr (%fn "tgetstr" '* (list '* '*)))
    (define %tigetstr (%fn "tigetstr" '* (list '*)))
    (define %tigetnum (%fn "tigetnum" int (list '*)))
    (define %tigetflag (%fn "tigetflag" int (list '*)))
    ;; `char *tparm (const char *, long x9)' - nine parameters, which is
    ;; every capability terminfo's format can address (`%p1`..`%p9`).
    (define %tparm (%fn "tparm" '* (list '* long long long long long
                                         long long long long)))

    (define %tinfo-started #f)
    (define *tinfo-caps* '())
    ;; ^ The capabilities read so far, as `((NAME . VALUE) ...)'. A
    ;; capability string never changes for a terminal, so one read serves
    ;; the process - which is what `tigetstr`'s static buffer means
    ;; anyway, and the reason `term.c` reads them once into
    ;; `TS_set_foreground` and friends.

    (define (%null-string-pointer)
      ;; A NULL `char *` - `(system foreign)`'s own `%null-pointer`,
      ;; which is **a variable holding one, not a constructor**:
      ;; `(%null-pointer)` is "wrong type to apply: pointer 0x0".
      ;;
      ;; Not `(make-c-struct (list '*) (list 0))` either - that asks Guile
      ;; to build a struct *containing* a pointer, and a `0` where a
      ;; pointer belongs is dereferenced: measured, "In procedure
      ;; pointer-address: Wrong type argument in position 1 (expecting
      ;; POINTER_P): 0".
      ;;--------------------------------------------------------------
      %null-pointer)

    (define (setup-term . optional)
      ;; Read the terminal's description - GNU Emacs does this in
      ;; `term_init` (`term.c`), through `tgetent`/`setupterm`.
      ;;
      ;; **`setup-term`, not `setupterm`**: `(ncurses curses)` exports a
      ;; `setupterm` of its own, and importing both made Guile pick one
      ;; silently - measured, the editor then drew nothing because every
      ;; `tparm` answered #f. Phase A removes ncurses from `term.scm`
      ;; entirely; until then the name has to be distinct.
      ;;
      ;; TERM is a string or #f for `$TERM`; FD is where errors are
      ;; reported (1, stdout, is what the C uses). Answer `#t` when the
      ;; description was found.
      ;;--------------------------------------------------------------
      (let* ((term (if (and (pair? optional) (car optional)) (car optional) #f))
             (fd (if (and (pair? optional) (pair? (cdr optional)))
                     (cadr optional) 1))
             (err (make-c-struct (list int) (list 0))))
        (if (not %setupterm)
            #f
            (let ((ok (= 0 (%setupterm (if term
                                           (string->pointer term)
                                           (%null-string-pointer))
                                       fd err))))
              (set! %tinfo-started ok)
              (if ok (set! *tinfo-caps* '()) #f)
              ok))))

    (define (tinfo-close!)
      ;; Forget what was read. `del_curterm`/`endwin` are the C's;
      ;; nothing here needs them, so this is the cache only.
      ;;--------------------------------------------------------------
      (set! *tinfo-caps* '())
      (set! %tinfo-started #f))

    (define (%cap-pointer name)
      ;; NAME's capability pointer, from the cache when it has been read.
      ;; A pointer answers `#f` for "the terminal has not got this", which
      ;; is what `(char *)-1` and NULL both mean to a caller here.
      ;;--------------------------------------------------------------
      (let ((cached (assoc name *tinfo-caps*)))
        (and cached (cdr cached))))

    (define (tinfo-capability name)
      ;; The *string* capability NAME, by `tigetstr` - `(tiget "cup")`
      ;; with a cache in front of it. Answers `#f` when the terminal has
      ;; none, which is `tigetstr`'s `(char *) -1`.
      ;;--------------------------------------------------------------
      (let ((cached (assoc name *tinfo-caps*)))
        (cond
         (cached (let ((p (cdr cached)))
                   (and p (not (null-pointer? p)) (pointer->string p))))
         ((not %tigetstr) #f)
         (else
          (let* ((p (%tigetstr (string->pointer name)))
                 (gone? (or (null-pointer? p)
                            ;; `tigetstr` answers `(char *)-1`, which
                            ;; the FFI wraps as a *true* pointer, for a
                            ;; capability the terminal does not have -
                            ;; `((unsigned long) -1)` is the test the C's
                            ;; own callers make.
                            (= (pointer-address p) (- (expt 2 64) 1))))
                 (value (if gone? #f p)))
            (set! *tinfo-caps*
                  (cons (cons name value) *tinfo-caps*))
            (and value (pointer->string value)))))))

    (define (tgetstr name . optional)
      ;; GNU Emacs's `tgetstr`: the capability NAME in **termcap** form
      ;; (`md`, `us`, `mr`, `me`, `op`, `AF`, `AB`), expanded or not.
      ;; Answers #f when the terminal has not got it.
      ;;
      ;; The AREA argument the C takes is #f here - ncurses uses its own
      ;; buffer, which is what `term.c` passes too (`&address` with
      ;; `address` nil).
      ;;--------------------------------------------------------------
      (let ((area (if (and (pair? optional) (car optional))
                      (car optional)
                      ;; `%null-pointer` is `(system foreign)`'s own NULL -
                      ;; **a variable holding one, not a constructor** -
                      ;; and "no area" is what `term.c` passes.
                      %null-pointer)))
        (if (not %tgetstr)
            #f
            (let ((p (%tgetstr (string->pointer name) area)))
              (and p (not (null-pointer? p)) (pointer->string p))))))

    (define (tigetstr name)
      ;; GNU Emacs's `tigetstr`, as `term.c` calls it: the capability's
      ;; sequence, or #f. A thin name for `tinfo-capability` so that the
      ;; call sites read like the C.
      ;;--------------------------------------------------------------
      (tinfo-capability name))

    (define (tigetnum name)
      ;; A numeric capability: `tigetnum "colors"` is 256 on an xterm and
      ;; -1 for one the terminal has not got, which is `TN_max_colors`'s
      ;; source in `term.c`.
      ;;--------------------------------------------------------------
      (if %tigetnum (%tigetnum (string->pointer name)) -1))

    (define (tigetflag name)
      ;; A boolean capability: 1 for yes, 0 for no, -1 for "not a
      ;; boolean capability". `term.c` tests `tigetflag ("bce") > 0` and
      ;; `tigetflag ("xenl")` in exactly those terms.
      ;;--------------------------------------------------------------
      (if %tigetflag (%tigetflag (string->pointer name)) -1))

    ;;----------------------------------------------------------------
    ;; Expanding and emitting
    ;;----------------------------------------------------------------

    (define (tparm cap . args)
      ;; Expand CAP's parameters: GNU Emacs's `tparm`, which `cmgoto`
      ;; (`cm.c`) and every `term.c` sequence go through.
      ;;
      ;; ARGS are the format's parameters, `%p1` first, as numbers.
      ;; Up to nine are taken - `%p1`..`%p9` is all a terminfo format can
      ;; address - and missing ones are 0, which is the C's contract.
      ;; Answers the expanded *string*, or #f when the terminal has no
      ;; such capability.
      ;;--------------------------------------------------------------
      (let ((pointer (cond ((string? cap) (and (tigetstr cap)
                                               (%cap-pointer cap)))
                           (else cap))))
        (cond
         ((or (not %tparm) (not pointer) (null-pointer? pointer)) #f)
         (else
          (let ((p (list->vector (append args (make-list 9 0)))))
            (pointer->string
             (%tparm pointer
                     (inexact->exact (vector-ref p 0))
                     (inexact->exact (vector-ref p 1))
                     (inexact->exact (vector-ref p 2))
                     (inexact->exact (vector-ref p 3))
                     (inexact->exact (vector-ref p 4))
                     (inexact->exact (vector-ref p 5))
                     (inexact->exact (vector-ref p 6))
                     (inexact->exact (vector-ref p 7))
                     (inexact->exact (vector-ref p 8)))))))))

    (define (tputs string port)
      ;; Write STRING to PORT - GNU Emacs's `tputs`, whose only work
      ;; beyond a write is padding.
      ;;
      ;; **The `$<n>` padding in a capability is expanded by the library,
      ;; and that is why Emacs links it.** Asking it to do so needs a
      ;; C callback (`int (*putc)(int)`), and a Scheme procedure wrapped
      ;; with `procedure->pointer` allocates on every call - so this
      ;; splits: a string with no padding (almost every capability on a
      ;; modern terminal, where `xenl`/`bce` handle the delay) is written
      ;; straight out, and the library is asked only when there is
      ;; padding to compute.
      ;;--------------------------------------------------------------
      (cond
       ((or (not string) (string=? string "")) #t)
       ((not (string-contains string "$<"))
        (display string port)
        #t)
       (else
        ;; with padding: the library's `tputs` over an unbuffered write
        (display (tputs-expand-padding string) port)
        #t)))

    (define (tputs-expand-padding string)
      ;; Padding is a delay in milliseconds which a terminal does not
      ;; need over a fast link - `baud_rate` is 0 here, as it is for a
      ;; pseudo-terminal, and the C's `tputs` with `affcnt` 1 emits
      ;; nothing for `$<n>`. So dropping the directive is what the C does
      ;; on this machine, not a simplification of it.
      ;;--------------------------------------------------------------
      (let loop ((chars (string->list string)) (out '()))
        (cond
         ((null? chars) (list->string (reverse out)))
         ((char=? (car chars) #\$)
          (let ((rest (cdr chars)))
            (if (and (pair? rest) (char=? (car rest) #\<))
                (let skip ((r rest) (acc out))
                  (cond ((null? r) (list->string (reverse acc)))
                        ((char=? (car r) #\>)
                         (loop (cdr r) acc))
                        (else (skip (cdr r) acc))))
                (loop rest (cons #\$ out)))))
         (else (loop (cdr chars) (cons (car chars) out))))))

    ))
