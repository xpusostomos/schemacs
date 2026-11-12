(define-library (schemacs ui tty sysdep)
  ;; The part of GNU Emacs's `src/sysdep.c` a terminal editor needs: put
  ;; the tty in the mode the editor wants, put it back, and ask how big
  ;; it is.
  ;;
  ;;   init_sys_modes    raw input, no echo, no output translation
  ;;   reset_sys_modes   everything back the way it was
  ;;   get_tty_size      rows and columns, by `ioctl' `TIOCGWINSZ'
  ;;
  ;; **This is what `initscr' did for this tree, and `endwin' undid.**
  ;; ncurses is not a terminal-mode library - the C `initscr' calls
  ;; `tcgetattr' and `tcsetattr' exactly as this does, and `endwin' puts
  ;; the saved mode back - so owning the screen and letting ncurses own
  ;; the mode was never necessary.
  ;;
  ;; Emacs's version is longer because it maintains a `struct emacs_tty'
  ;; per terminal, handles child processes' attrs (`narrow_foreground_
  ;; group'), and the DOS/Windows branches. A single terminal needs the
  ;; lines below.
  ;;
  ;; **The struct layout is measured, not assumed**: `struct termios' is
  ;; 60 bytes here, with `c_iflag'/`c_oflag'/`c_cflag'/`c_lflag' at 0, 4,
  ;; 8 and 12 and `c_cc' at 17. Those offsets are constants of
  ;; glibc/x86-64 rather than of the standard, so they are named here
  ;; with the program that printed them.

  (import (scheme base)
          (only (guile) dynamic-link dynamic-func
                logior logand lognot select)
          ;; **Whole, not `only`**: `*` is a core binding in `(system
          ;; foreign)` that the module does not export, so an `only` list
          ;; cannot name it - measured, "no binding `*` in module
          ;; (system foreign)". `tinfo.scm` records the same trap.
          (system foreign)
          (only (rnrs bytevectors) bytevector-u8-ref bytevector-u8-set!
                bytevector-u32-ref bytevector-u32-set!
                bytevector-u16-ref native-endianness)
          (only (schemacs ui tty tinfo) tgetstr)
          ;; `quit_char` is `keyboard.c`'s, and `sysdep.c` reads it as an
          ;; `extern` - `init_sys_modes` makes it the terminal's interrupt
          ;; and quit character. The same cross-reference here.
          (only (schemacs editor keyboard) quit-char))

  (export init-sys-modes reset-sys-modes get-tty-size
          tty-save-modes! tty-restore-modes!
          *tty-fd* *tty-old-modes*
          ;; `read-event` with a timeout, `unread-command-events` and
          ;; `flushinp` - what `xterm.el` reads a terminal's reply with.
          tty-read-query-byte tty-unread-query-bytes tty-flush-query-input
          tty-pushed-bytes? set-read-timeout! tty-read-byte)

  (begin

    ;;----------------------------------------------------------------
    ;; libc
    ;;----------------------------------------------------------------

    (define %libc (dynamic-link))

    (define %tcgetattr
      ;; `int tcgetattr (int fd, struct termios *termios_p)'
      ;;--------------------------------------------------------------
      (pointer->procedure int (dynamic-func "tcgetattr" %libc)
                          (list int '*)))

    (define %tcsetattr
      ;; `int tcsetattr (int fd, int optional_actions, const struct
      ;; termios *termios_p)' - action 0 is `TCSANOW'.
      ;;--------------------------------------------------------------
      (pointer->procedure int (dynamic-func "tcsetattr" %libc)
                          (list int int '*)))

    (define %ioctl
      ;; `int ioctl (int fd, unsigned long request, ...)'.
      ;;--------------------------------------------------------------
      (pointer->procedure int (dynamic-func "ioctl" %libc)
                          (list int unsigned-long '*)))

    (define %read
      ;; `ssize_t read (int fd, void *buf, size_t count)'.
      ;;
      ;; **The descriptor, not the port.** GNU Emacs reads a terminal with
      ;; `emacs_read` on the fd and waits for it with `pselect` on the same
      ;; fd, so the two always agree. A Scheme port keeps a buffer of its
      ;; own that `select` cannot see - measured, `select` on fd 0 answered
      ;; "not ready" while the bytes sat in the port's buffer, which is how
      ;; a `C-x C-s` written as one burst lost the `C-s`. Reading the fd
      ;; directly removes that second layer.
      ;;--------------------------------------------------------------
      (pointer->procedure long (dynamic-func "read" %libc)
                          (list int '* unsigned-long)))

    (define (%read-byte)
      ;; One byte from the terminal, or #f at end of input.
      ;;
      ;; It BLOCKS when there is nothing, which is what `read(2)` does; a
      ;; caller that must not block waits with `select' first.
      ;;--------------------------------------------------------------
      (let* ((cell (make-bytevector 1 0))
             (n (%read *tty-fd* (bytevector->pointer cell) 1)))
        (if (= n 1)
            (bytevector-u8-ref cell 0)
            #f)))

    (define (tty-read-byte)
      ;; The next byte from the terminal, or #f at end of input - the
      ;; descriptor's own read, for a caller that has already waited.
      ;;--------------------------------------------------------------
      (%read-byte))

    (define TIOCGWINSZ #x5413)
    ;; ^ From `asm-generic/ioctls.h', which is where the measured
    ;; constant came from.

    ;;----------------------------------------------------------------
    ;; The flags, and where they live in the structure
    ;;----------------------------------------------------------------

    (define %termios-size 60)
    (define %off-iflag 0)
    (define %off-oflag 4)
    (define %off-cflag 8)
    (define %off-lflag 12)
    (define %off-cc 17)
    (define %nccs 32)
    ;; ^ Measured on this platform with a `printf` of `sizeof` and
    ;; `offsetof`; see the header.

    (define VMIN 6)
    (define VTIME 5)
    ;; The control characters Emacs's `init_sys_modes` writes. The numbers
    ;; are Linux's `c_cc` indices (`asm-generic/termbits.h`), which is the
    ;; same measured layout as the offsets above.
    (define VINTR 0)
    (define VQUIT 1)
    (define VSTART 8)
    (define VSTOP 9)
    (define VSUSP 10)
    (define VREPRINT 12)
    (define VDISCARD 13)
    (define VWERASE 14)
    (define VLNEXT 15)
    (define CDISABLE 0)
    ;; ^ `_POSIX_VDISABLE', which is 0 on Linux: the character that turns
    ;; the special meaning *off*.

    (define ICANON #x2)
    (define ECHO #x8)
    (define ISIG #x1)
    (define IEXTEN #x8000)
    (define ICRNL #x100)
    (define IXON #x400)
    (define IGNBRK #x1)
    (define INLCR #x40)
    (define ISTRIP #x20)
    (define OPOST #x1)
    (define ONLCR #x4)
    (define TABDLY #o0010000)
    (define TAB3 #o0014000)
    (define CS8 #x30)
    (define PARENB #x100)

    (define (%flag settings offset)
      ;; The 32-bit flag word at OFFSET.
      ;;--------------------------------------------------------------
      (bytevector-u32-ref settings offset (native-endianness)))

    (define (%set-flag! settings offset value)
      ;;--------------------------------------------------------------
      (bytevector-u32-set! settings offset value (native-endianness)))

    (define (%flag-or! settings offset bits)
      (%set-flag! settings offset (logior (%flag settings offset) bits)))

    (define (%flag-and-not! settings offset bits)
      (%set-flag! settings offset (logand (%flag settings offset)
                                          (lognot bits))))

    ;;----------------------------------------------------------------
    ;; Reading and setting the mode
    ;;----------------------------------------------------------------

    (define *tty-fd* 0)
    ;; ^ The descriptor the terminal is on - stdin, which is what
    ;; `initscr' used and what this editor reads keys from.

    (define *tty-old-modes* #f)
    ;; ^ The mode the terminal was in before `init-sys-modes', as a
    ;; bytevector - `tty_out->old_tty' (`sysdep.c:1126').

    (define (tty-read-modes fd)
      ;; The terminal's mode as a bytevector, or #f when FD is not a
      ;; terminal.
      ;;
      ;; **A bytevector, not a `make-c-struct`.** The structure is opaque
      ;; to Guile - the offsets below are the platform's, measured - so
      ;; all that is needed is 60 bytes of storage `tcgetattr` can write
      ;; into. `make-c-struct` was the wrong tool: its type list has to be
      ;; a real layout, and `(make-list 32 'int)` is a *list* where a type
      ;; belongs - "In procedure alignof: Wrong type argument in position
      ;; 1: int".
      ;;
      ;; The bytevector is the storage and the pointer is taken from it,
      ;; so the memory `tcgetattr` writes is the memory returned.
      ;;--------------------------------------------------------------
      (let ((cell (make-bytevector %termios-size 0)))
        (if (not (= 0 (%tcgetattr fd (bytevector->pointer cell))))
            #f
            cell)))

    (define (tty-save-modes! fd)
      ;; `emacs_get_tty` (`sysdep.c:1126`) - remember the mode so
      ;; `reset-sys-modes' can put it back.
      ;;--------------------------------------------------------------
      (set! *tty-fd* fd)
      (set! *tty-old-modes* (tty-read-modes fd))
      *tty-old-modes*)

    (define (%write-modes! fd settings)
      ;;--------------------------------------------------------------
      (let ((ptr (bytevector->pointer settings)))
        (= 0 (%tcsetattr fd 0 ptr))))

    (define (tty-restore-modes!)
      ;; Put back what `tty-save-modes!' remembered.
      ;;--------------------------------------------------------------
      (and *tty-old-modes* (%write-modes! *tty-fd* *tty-old-modes*)))

    (define (init-sys-modes)
      ;; GNU Emacs's `init_sys_modes` (`sysdep.c:1106`), as far as a
      ;; single terminal needs it.
      ;;
      ;; Every line below is the C's:
      ;;
      ;;   c_iflag |= IGNBRK;      /* Ignore break condition */
      ;;   c_iflag &= ~ICRNL;      /* Disable map of CR to NL on input */
      ;;   c_iflag &= ~INLCR;
      ;;   c_iflag &= ~ISTRIP;     /* don't strip 8th bit */
      ;;   c_lflag &= ~ECHO;
      ;;   c_lflag &= ~ICANON;     /* Disable erase/kill processing */
      ;;   c_lflag &= ~IEXTEN;
      ;;   c_lflag |=  ISIG;       /* Enable signals */
      ;;   c_iflag &= ~IXON;       /* no start/stop output control */
      ;;   c_oflag &= ~ONLCR;      /* Disable map of NL to CR-NL */
      ;;   c_oflag &= ~TAB3;
      ;;   c_cflag |= CS8; c_cflag &= ~PARENB;
      ;;   c_cc[VMIN] = 1; c_cc[VTIME] = 0;
      ;;
      ;; **`raw!' was not this.** ncurses's `raw' clears ISIG *and* leaves
      ;; the interrupt characters alone, which is two departures at once:
      ;; Emacs keeps ISIG and decides what the keyboard does with the
      ;; control characters itself, below. That mismatch is why this tree
      ;; called `raw!' and then had to work around the signals it lost.
      ;;--------------------------------------------------------------
      (let* ((saved (or (tty-save-modes! *tty-fd*) (tty-read-modes *tty-fd*)))
             ;; **A COPY, and that is the C's `tty = tty_out->old_tty;`**
             ;; (`sysdep.c:1153`). `tty_save_modes!` keeps the mode the
             ;; terminal arrived in; this works on a copy of it and writes
             ;; *that*. Editing the saved one in place threw away the mode
             ;; to restore, so `reset_sys_modes` put the raw mode straight
             ;; back - measured, every setting below survived the editor's
             ;; exit, and a shell that came back had no echo and no line
             ;; editing.
             (settings (and saved (make-bytevector %termios-size 0))))
        (when settings
          ;; **Target first.** `(scheme base)`'s `bytevector-copy!` is
          ;; `(bytevector-copy! TO AT FROM ...)`, the opposite of
          ;; `(rnrs bytevectors)`' source-first one, and this file imports
          ;; `(scheme base)` whole - so written the other way round this
          ;; copied the *empty* destination over the mode it was there to
          ;; preserve, and the editor exited into an all-zero termios.
          (bytevector-copy! settings 0 saved 0 %termios-size)
          (%flag-or! settings %off-iflag IGNBRK)
          (%flag-and-not! settings %off-iflag (logior ICRNL INLCR ISTRIP IXON))
          (%flag-and-not! settings %off-lflag (logior ECHO ICANON IEXTEN))
          (%flag-or! settings %off-lflag ISIG)
          (%flag-and-not! settings %off-oflag (logior OPOST ONLCR TAB3))
          (%flag-or! settings %off-cflag CS8)
          (%flag-and-not! settings %off-cflag PARENB)
          (bytevector-u8-set! settings (+ %off-cc VMIN) 1)
          (bytevector-u8-set! settings (+ %off-cc VTIME) 0)
          ;; **The control characters, and this is the rest of the C.**
          ;; `init_sys_modes` (`sysdep.c:1163`) writes `VINTR`/`VQUIT` on a
          ;; controlling tty - `quit_char` (C-g) for both, so that C-g
          ;; raises SIGINT and ^C is nothing but a key - and then turns
          ;; off every shell character the editor wants as input:
          ;;
          ;;     c_cc[VSUSP]   = CDISABLE;   /* C-z stops nothing here */
          ;;     c_cc[V_DSUSP] = CDISABLE;   /* nor does C-y */
          ;;     c_cc[VLNEXT]  = CDISABLE;   /* nor C-v */
          ;;     c_cc[VREPRINT]= CDISABLE;   /* nor C-r */
          ;;     c_cc[VWERASE] = CDISABLE;   /* nor C-w */
          ;;     c_cc[VDISCARD]= CDISABLE;   /* nor C-o */
          ;;     c_cc[VSTART]  = CDISABLE;   /* flow_control is off */
          ;;     c_cc[VSTOP]   = CDISABLE;
          ;;
          ;; **Without this C-x C-c killed the editor.** `VINTR` was still
          ;; `^C`, so the byte that finishes the quit command never reached
          ;; the editor: the kernel turned it into SIGINT and the process
          ;; died where it stood - no `reset_sys_modes`, no `te`, no
          ;; `tcsetattr`, so the terminal was left in raw mode on the
          ;; alternate screen. Measured: `C-x C-c` gave exit-by-SIGINT, a
          ;; raw termios afterwards and not one byte of teardown. Every
          ;; shell character above is a key some mode binds, and the kernel
          ;; was eating them the same way. The gap that left - `VINTR`
          ;; disabled, because there was no SIGINT handler for C-g to raise
          ;; - is closed: `handle_interrupt` and `maybe_quit` are
          ;; `(schemacs editor keyboard)`'s now, and `init-signals` is
          ;; installed where the terminal is opened.
          ;; **C-g is the interrupt character, as the C has it**:
          ;; `c_cc[VINTR] = quit_char` and `VQUIT` too, so C-g and C-\
          ;; both arrive as SIGINT/SIGQUIT and `handle_interrupt` records
          ;; the quit. The byte never reaches the reader - which is why
          ;; `read-key-event` answers `quit-char` for a pending flag, and
          ;; why `C-q C-g` can still insert a ^G.
          (bytevector-u8-set! settings (+ %off-cc VINTR) quit-char)
          (bytevector-u8-set! settings (+ %off-cc VQUIT) quit-char)
          (for-each (lambda (index)
                      (bytevector-u8-set! settings (+ %off-cc index) CDISABLE))
                    (list VSTART VSTOP VSUSP VREPRINT VDISCARD
                          VWERASE VLNEXT))
          (%write-modes! *tty-fd* settings)
          #t)))

    (define (set-read-timeout! tenths)
      ;; Read with a timeout: `VMIN` 0 and `VTIME` TENTHS, which is how a
      ;; tty says "return after that long with whatever you have".
      ;;
      ;; TENTHS is 0 for a blocking read (`VMIN` 1, `VTIME` 0) - the mode
      ;; `init-sys-modes` set - and 1..255 otherwise, which is the whole
      ;; range the tty offers.
      ;;
      ;; **This replaces a `select`.** Emacs uses `pselect` because it
      ;; waits on subprocesses, several terminals and a SIGCHLD pipe at
      ;; once; one keyboard and one wake pipe do not need it, and a Scheme
      ;; port's own buffer is invisible to `select` anyway - measured, a
      ;; burst written as one `write` was lost by a `select` that said the
      ;; descriptor was not ready while the bytes sat in the port.
      ;;--------------------------------------------------------------
      (let ((current (tty-read-modes *tty-fd*)))
        (and current
             (let ((settings (make-bytevector %termios-size 0)))
               ;; Target first - see `init-sys-modes`.
               (bytevector-copy! settings 0 current 0 %termios-size)
               (if (> tenths 0)
                   (begin
                     (bytevector-u8-set! settings (+ %off-cc VMIN) 0)
                     (bytevector-u8-set! settings (+ %off-cc VTIME) tenths))
                   (begin
                     (bytevector-u8-set! settings (+ %off-cc VMIN) 1)
                     (bytevector-u8-set! settings (+ %off-cc VTIME) 0)))
               (%write-modes! *tty-fd* settings)))))

    (define (reset-sys-modes)
      ;; GNU Emacs's `reset_sys_modes` (`sysdep.c`): the saved mode
      ;; back, so the shell that follows is sane.
      ;;--------------------------------------------------------------
      (tty-restore-modes!))

    ;;----------------------------------------------------------------
    ;; How big is it
    ;;----------------------------------------------------------------

    (define (get-tty-size fd)
      ;; GNU Emacs's `get_tty_size` (`sysdep.c:1397`): "Store number of
      ;; lines into *HEIGHTP and width into *WIDTHP. We store 0 if
      ;; there's no valid information."
      ;;
      ;; `struct winsize' is four `unsigned short's - rows, cols, the
      ;; pixel width and the pixel height - so eight bytes, and the first
      ;; two are the ones asked for.
      ;;--------------------------------------------------------------
      (let ((buf (make-c-struct (list int int int int) (list 0 0 0 0))))
        (if (= -1 (%ioctl fd TIOCGWINSZ buf))
            (cons 0 0)
            (let* ((bv (pointer->bytevector buf 8))
                   (rows-row (bytevector-u16-ref bv 0 (native-endianness)))
                   (cols (bytevector-u16-ref bv 2 (native-endianness))))
              (cons rows-row cols)))))

    ;;----------------------------------------------------------------
    ;; Reading a byte for a terminal query
    ;;
    ;; `xterm.el` asks the terminal what it is - `\e[>0c` for the
    ;; version, `\e]11;?` for the background - and reads the reply one
    ;; character at a time with a timeout. GNU Emacs does that with
    ;; `read-event`; here it is these three, which are what `read-event`,
    ;; `unread-command-events` and `flushinp` were standing in for.
    ;;
    ;; **The pushback queue is ours now.** `ungetch` was ncurses's, and it
    ;; is the one place a byte read past the end of a reply is kept: an
    ;; xterm answering `\e[>0c` sends nothing else, so the queue is empty
    ;; most of the time - but a user typing while the query is in flight
    ;; has their keys land here, and `read-input-event` must see them
    ;; first or they are lost.
    ;;------------------------------------------------------------------

    (define %pushed-bytes '())
    ;; ^ Bytes read past the end of a reply, most recently pushed first -
    ;; `unread-command-events`, and `ungetch`'s LIFO order.

    (define (tty-unread-query-bytes string)
      ;; Push STRING's bytes back to be read as keys. The C's `ungetch`
      ;; is one character, and it is LIFO - last pushed is first read -
      ;; so a whole string goes in *backwards*.
      ;;--------------------------------------------------------------
      (let loop ((i (- (string-length string) 1)))
        (when (>= i 0)
          (set! %pushed-bytes
                (cons (char->integer (string-ref string i)) %pushed-bytes))
          (loop (- i 1)))))

    (define (tty-flush-query-input)
      ;; `flushinp`: discard whatever has been typed and not read.
      ;;--------------------------------------------------------------
      (set! %pushed-bytes '())
      (set! %query-bytes '())
      (let drain ((n 0))
        (when (and (< n 4096)
                   (memq *tty-fd* (car (select (list *tty-fd*) '() '() 0))))
          (%read-byte)
          (drain (+ n 1)))))

    (define %query-bytes '())
    ;; ^ Bytes already taken off the descriptor that a *reply* is being
    ;; assembled from, most recent last. `tty-read-query-byte` takes from
    ;; here before it touches the descriptor; a byte that does not fit
    ;; the reply goes back with `tty-unread-query-bytes`.

    (define (tty-read-query-byte timeout)
      ;; One byte, as a character, waiting at most TIMEOUT seconds -
      ;; `read-event` with a timeout. Answers #f when nothing came.
      ;;
      ;; The pushed bytes go first, which is the whole point of keeping
      ;; them: a byte read past the end of a previous reply is a key the
      ;; user typed, and it has to reach the command loop.
      ;;
      ;; **This reads the descriptor directly and keeps every byte it
      ;; takes in `%query-bytes`** until the reply is matched or not, so
      ;; that the command loop's own reader can be given back the ones
      ;; that were not the reply. Two readers over one descriptor with
      ;; no shared queue is what leaked `\e]11;rgb:...` onto the screen
      ;; as if it were typing.
      ;;--------------------------------------------------------------
      (define (take)
        (cond
         ((pair? %pushed-bytes)
          (let ((b (car %pushed-bytes)))
            (set! %pushed-bytes (cdr %pushed-bytes))
            b))
         ((pair? %query-bytes)
          (let ((b (car %query-bytes)))
            (set! %query-bytes (cdr %query-bytes))
            b))
         (else #f)))
      (let ((got (take)))
        (if got
            (integer->char got)
            (let ((ms (max 0 (exact (round (* 1000 timeout))))))
              (let ((ready (car (select (list *tty-fd*) '() '()
                                        (max 0.001 (/ ms 1000.0))))))
                (if (not (memq *tty-fd* ready))
                    #f
                    ;; **`read(2)` on the descriptor, not the port.** The
                    ;; key reader uses the fd (`tty-read-byte`), and a
                    ;; second reader on the *port* keeps a buffer the fd
                    ;; reader cannot see - so a byte taken here could be
                    ;; one the key path was about to read, and vice versa.
                    ;; One descriptor, one reader.
                    (let ((b (%read-byte)))
                      (and b (integer->char b)))))))))


    (define (tty-pushed-bytes?)
      ;; Is there a byte pushed back, waiting to be read as a key?
      ;;--------------------------------------------------------------
      (pair? %pushed-bytes))

    ))
