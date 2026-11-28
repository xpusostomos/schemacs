(define-library (schemacs process)
  ;; GNU Emacs's `src/process.c', the asynchronous subprocess half: the
  ;; process object, `make-process'/`start-process', the filters and
  ;; sentinels, `accept-process-output', the wait loop, and the send
  ;; side.  It exists so that `comint.el' - and through it
  ;; `inf-groovy' - has what Emacs's comint stands on.
  ;;
  ;; **The mechanism is Guile's and libc's, the shape is the C's.**
  ;; `primitive-fork' and `execlp' are Guile's; `pipe(2)',
  ;; `openpty(3)', `read(2)', `write(2)' and `strsignal(3)' are called
  ;; through `(system foreign)' because Guile's port layer buffers and
  ;; retries non-blocking reads (measured: `get-bytevector-some' on an
  ;; empty O_NONBLOCK pipe blocks), which a select-driven loop cannot
  ;; have.  The FFI is the technique `pgtk.scm' already uses.
  ;;
  ;; **Named departures**, each where it is used as well as here:
  ;;
  ;;   * **Network, serial and datagram processes are not carried.**
  ;;     They are the half of process.c that needs sockets and
  ;;     termios; nothing here asks for them, and `make-network-process'
  ;;     and friends are absent rather than stubbed.
  ;;
  ;;   * **`SIGCHLD` is a Scheme `sigaction' handler that sets a flag.**
  ;;     Emacs's handler reaps with `waitpid' inside the signal.  A
  ;;     Scheme handler runs at the VM's safe point, so this one only
  ;;     flags; the reaping is `%reap-children!', which the wait loops
  ;;     call.  Measured: SIGCHLD does interrupt a blocking `select'
  ;;     (it returns an empty ready set, with the handler run), so a
  ;;     front end's `select' services it exactly as Emacs's `pselect'
  ;;     does.
  ;;
  ;;   * **The exec-failure pipe is not carried.**  Emacs makes a third
  ;;     pipe so the child can report an `exec' failure to the parent;
  ;;     here the program is located first (`%locate-program', the
  ;;     `openp' call in `make-process') and an exec failure in the
  ;;     child exits 127.
  ;;
  ;;   * **`:stderr' is not carried**: a process's standard error is
  ;;     its standard output, which is Emacs's `:stderr nil' behaviour
  ;;     and what comint uses.
  ;;
  ;;   * **The connection type is a pty or a pipe.**  `:connection-type'
  ;;     is read as the C reads it (`pty', `pipe', nil for the
  ;;     `process-connection-type' default, or a cons for a type per
  ;;     direction), and a pty is `openpty(3)' plus `setsid' and
  ;;     `TIOCSCTTY' in the child - the C's `allocate_pty' and
  ;;     `emacs_spawn' pty branch.  `openpty' searches for a free pty,
  ;;     so the C's `pty_name' search loop has nothing to do here.
  ;;
  ;;   * **The keyword plist is data.**  Scheme's `:name' is not a
  ;;     self-evaluating keyword (measured: `:name' is an unbound
  ;;     variable), so callers pass the keywords quoted -
  ;;     `(make-process ':name "x" ':command '("cat"))' - and
  ;;     `start-process' is the ordinary spelling.
  ;;
  ;;   * `process-contact', `list-processes', `process-attributes',
  ;;     `list-system-processes', `set-process-window-size' and
  ;;     `make-pipe-process' are not carried: nothing here reads them.
  (import
    (scheme base)
    (scheme char)
    (scheme cxr)
    (srfi srfi-4)
    (only (guile)
          logand logior
          ;; the child and the descriptors
          primitive-fork primitive-exit execlp chdir setsid dup2
          close-fdes open-fdes fcntl F_GETFL F_SETFL O_NONBLOCK O_WRONLY
          waitpid WNOHANG WUNTRACED
          status:exit-val status:term-sig status:stop-sig
          select kill sleep
          sigaction SIGCHLD SIGINT SIGKILL SIGQUIT SIGTSTP SIGCONT
          stat stat:type access? X_OK getcwd getenv environ
          string-prefix?
          dynamic-link dynamic-func)
    (only (system foreign)
          pointer->procedure
          make-c-struct parse-c-struct bytevector->pointer
          pointer->string string->pointer
          int unsigned-long size_t ssize_t pointer? null-pointer?
          void %null-pointer)
    (only (scheme time) current-second)
    (only (scheme file) open-input-file)
    (only (schemacs buffer)
          current-buffer bufferp buffer-live-p buffer-name
          get-buffer get-buffer-create set-buffer save-current-buffer
          buffer-zv buffer-read-only? set!buffer-read-only
          buffer-local-value set-buffer-local-value!)
    (only (schemacs editfns) point point-max goto-char message format
          buffer-substring insert)
    (only (schemacs insdel) insert-from-string)
    (only (schemacs marker) make-marker set-marker marker-position
          marker-buffer)
    (only (schemacs buffer-text) code-point->char)
    (only (schemacs coding) decode-coding-bytes encode-coding-string
          *coding-system-for-read* *coding-system-for-write*)
    (only (schemacs command) define-command maybe-quit *inhibit-quit*)
    (only (schemacs search) save-match-data)
    (only (schemacs subr) error-message-string split-string)
    ;; `callproc.c`'s two variables, which `start-process-shell-command`
    ;; needs; the tree has them in the synchronous library.
    (only (schemacs callproc) shell-file-name shell-command-switch)
    (only (schemacs fns) concat)
    (only (schemacs core timer) timer-next-delay run-at-time cancel-timer)
    ;; `timer_check' is `keyboard.c''s, and the tree put it where the C
    ;; has it: `(schemacs keyboard)'.
    (only (schemacs keyboard) timer-check!)
    (only (schemacs xdisp) *mode-line-process-status-function*))

  (export
   make-process start-process start-process-shell-command start-file-process
   start-file-process-shell-command
   process-query-on-exit-flag set-process-query-on-exit-flag
   num-processors
   interrupt-process kill-process quit-process stop-process continue-process
   processp process-name process-command process-buffer set-process-buffer
   process-mark set-process-mark process-filter set-process-filter
   process-sentinel set-process-sentinel process-status process-exit-status
   process-id process-live-p process-list get-process get-buffer-process
   delete-process signal-process process-send-string process-send-region
   process-send-eof accept-process-output process-tty-name
   internal-default-process-filter internal-default-process-sentinel
   process-coding-system set-process-coding-system
   *process-connection-type* *process-environment* *exec-path*
   *delete-exited-processes* *default-process-coding-system*
   process-wait-descriptors process-service-ready! process-service!
   process-alive-processes? *process-event-function*)

  (begin

    ;;----------------------------------------------------------------
    ;; The C bindings.
    ;;----------------------------------------------------------------

    (define %libc (dynamic-link))
    (define (%c-func return name args)
      (pointer->procedure return (dynamic-func name %libc) args))

    (define %c-pipe (%c-func int "pipe" (list '*)))
    (define %c-read (%c-func ssize_t "read" (list int '* size_t)))
    (define %c-write (%c-func ssize_t "write" (list int '* size_t)))
    (define %c-openpty (%c-func int "openpty" (list '* '* '* '* '*)))
    (define %c-ioctl (%c-func int "ioctl" (list int unsigned-long '*)))
    (define %c-ptsname (%c-func '* "ptsname" (list int)))
    (define %c-errno-location (%c-func '* "__errno_location" '()))
    (define %c-strsignal (%c-func '* "strsignal" (list int)))
    (define %c-clearenv (%c-func int "clearenv" '()))
    (define %c-putenv (%c-func int "putenv" (list '*)))

    (define (errno)
      ;; `__errno_location''s int, this thread's errno.
      (car (parse-c-struct (%c-errno-location) (list int))))

    (define EINTR 4)
    (define EAGAIN 11)
    (define EPIPE 32)
    ;; ^ Linux's numbers; the three errno values this file tests.

    (define TIOCSCTTY #x540E)
    ;; ^ `asm-generic/ioctls.h'; the ioctl that makes the pty the
    ;; child's controlling terminal, as `emacs_spawn' does.

    (define SIGKILL 9)

    (define %read-process-output-max 65536)
    ;; ^ Emacs's `read-process-output-max' default (`process.c'), the
    ;; most bytes read from one process at a time.

    (define %read-buffer (make-bytevector %read-process-output-max))
    ;; ^ One buffer shared by every read: reads are serialized on this
    ;; thread, and a fresh 64 KB allocation per read is the per-keystroke
    ;; garbage the redisplay work spent a pass removing.

    (define (%make-pipe)
      ;; `pipe(2)': (READ-FD . WRITE-FD), raw descriptors.
      (let* ((p (make-c-struct (list int int) (list 0 0)))
             (rc (%c-pipe p)))
        (if (= rc 0)
            (let ((v (parse-c-struct p (list int int))))
              (cons (car v) (cadr v)))
            (error "Creating pipe failed"))))

    (define (%open-pty)
      ;; `openpty(3)': (MASTER SLAVE NAME), or #f.
      (let* ((m (make-c-struct (list int) (list 0)))
             (s (make-c-struct (list int) (list 0)))
             (rc (%c-openpty m s %null-pointer %null-pointer %null-pointer)))
        (if (= rc 0)
            (let* ((master (car (parse-c-struct m (list int))))
                   (slave (car (parse-c-struct s (list int))))
                   (name (%c-ptsname master)))
              (list master slave
                    (and name (not (null-pointer? name))
                         (pointer->string name))))
            #f)))

    (define (ioctl% fd request arg)
      (%c-ioctl fd request (make-c-struct (list int) (list arg))))

    ;;----------------------------------------------------------------
    ;; The process object - `struct Lisp_Process`, the fields this tree
    ;; uses.
    ;;----------------------------------------------------------------

    (define-record-type <process>
      (make<process> name)
      process?
      (name process-name)
      (tty-name %process-tty-name %set-process-tty-name!)
      (command %process-command %set-process-command!)
      (filter %process-filter %set-process-filter!)
      (sentinel %process-sentinel %set-process-sentinel!)
      (buffer %process-buffer %set-process-buffer!)
      (plist %process-plist %set-process-plist!)
      (type %process-type %set-process-type!)
      (mark %process-mark %set-process-mark!)
      (status %process-status %set-process-status!)
      (decode-coding %process-decode-coding %set-process-decode-coding!)
      (encode-coding %process-encode-coding %set-process-encode-coding!)
      (pid %process-pid %set-process-pid!)
      (infd %process-infd %set-process-infd!)
      (outfd %process-outfd %set-process-outfd!)
      (alive %process-alive %set-process-alive!)
      (raw-status %process-raw-status %set-process-raw-status!)
      (tick %process-tick %set-process-tick!)
      (update-tick %process-update-tick %set-process-update-tick!)
      (nbytes-read %process-nbytes-read %set-process-nbytes-read!)
      (write-queue %process-write-queue %set-process-write-queue!)
      (kill-without-query %process-kill-without-query
                          %set-process-kill-without-query!)
      (pty-in %process-pty-in %set-process-pty-in!)
      (pty-out %process-pty-out %set-process-pty-out!))
    ;; ^ Field names take no `?': `define-record-type' appends `!' to make
    ;; the setter, so `alive?' would give `set-alive?!' (the tree's own
    ;; recorded trap).

    (define %process-alist '())
    ;; ^ `Vprocess_alist': ((NAME . PROCESS) ...), newest first.

    (define *process-event-function*
      (make-parameter #f))
    ;; ^ A front end's "a process event happened, wake this loop" thunk
    ;; for a loop a `SIGCHLD' cannot interrupt (the Gtk one).  The
    ;; terminal needs none - its `select' returns.

    (define *process-connection-type* (make-parameter #t))
    ;; ^ `process-connection-type': `pty' (or t) for a pty, `pipe' (or
    ;; nil) for a pipe.  Emacs's default is t.

    (define *process-environment* (make-parameter (environ)))
    ;; ^ `process-environment': the child's environment, "NAME=VALUE"
    ;; strings; the initial value is this process's environment.

    (define *exec-path*
      (make-parameter
       (map (lambda (d) (if (string=? d "") "." d))
            (split-string (or (getenv "PATH") "") ":"))))

    (define *delete-exited-processes* (make-parameter #t))
    ;; ^ `delete-exited-processes'.

    (define *default-process-coding-system*
      (make-parameter (cons 'undecided-unix 'undecided-unix)))
    ;; ^ `default-process-coding-system': (DECODE . ENCODE), Emacs's
    ;; own default.

    (define %status-changed #f)
    ;; ^ Whether the last `status_notify` had anything to report - set
    ;; whenever a process's tick was handled, so a caller can redisplay
    ;; for a *sentinel's* output too, not only for bytes read.

    (define %process-tick-count 0)
    ;; ^ `process_tick' (`process.c:7917'): every status change raises
    ;; it.  The name carries `-count' because the record's accessor is
    ;; `%process-tick' - a duplicate would make the accessor call a
    ;; number ("Wrong type to apply: 1", measured).

    (define (%tick!)
      (set! %process-tick-count (+ %process-tick-count 1))
      %process-tick-count)

    (define (processp object) (process? object))

    (define (get-process name)
      ;; GNU Emacs's `get-process': the process named NAME, or nil.
      (let ((cell (assoc name %process-alist)))
        (and cell (cdr cell))))

    (define (process-list) (map cdr %process-alist))

    (define (process-id process)
      ;; `process-id': the child's pid, nil for a non-child.
      (let ((pid (%process-pid process)))
        (and pid (> pid 0) pid)))

    (define (process-live-p process)
      ;; `subr.el''s: live statuses are run, stop, open, listen, connect.
      (let ((status (process-status process)))
        (and (memq status '(run stop open listen connect)) #t)))

    (define (process-command process) (%process-command process))
    (define (process-buffer process) (%process-buffer process))
    (define (process-mark process) (%process-mark process))
    (define (process-filter process) (%process-filter process))
    (define (process-sentinel process) (%process-sentinel process))
    (define (process-tty-name process) (%process-tty-name process))

    (define (set-process-mark process marker)
      ;; `process.c:1372': "Set PROCESS's mark to MARKER."
      (%set-process-mark! process marker)
      marker)

    (define (process-status process)
      ;; `process.c:1205'.
      (let ((process (if (string? process) (get-process process) process)))
        (if (not (process? process))
            #f
            (begin
              (%update-status! process)
              (let ((status (%process-status process)))
                (if (pair? status) (car status) status))))))

    (define (process-exit-status process)
      ;; `process.c:1251': the exit code or the signal number, 0 before.
      (begin
        (%update-status! process)
        (let ((status (%process-status process)))
          (if (pair? status) (cadr status) 0))))

    (define (%update-status! process)
      ;; `update_status': the raw `waitpid' word becomes the status list.
      (if (%process-raw-status process)
          (begin
            (%set-process-status!
             process (%status-convert (%process-raw-status process)))
            (%set-process-raw-status! process #f))))

    (define (%status-convert w)
      ;; `status_convert' (`process.c:760').  The three Guile accessors
      ;; answer the value or #f, so each is tested against #f.
      (cond ((status:stop-sig w) (list 'stop (status:stop-sig w) #f))
            ((not (not (status:exit-val w)))
             (list 'exit (status:exit-val w) #f))
            ((status:term-sig w)
             (list 'signal (status:term-sig w)
                   (not (zero? (logand w #x80)))))
            (else 'run)))
    ;; ^ `status:exit-val' answers #f for "did not exit normally" and 0
    ;; for a normal exit, so the test is `not #f', not truthiness.

    (define (%decode-status status)
      ;; `decode_status' -> (SYMBOL CODE COREDUMP).
      (if (symbol? status)
          (list status 0 #f)
          (list (car status) (cadr status)
                (and (pair? (cddr status)) (car (cddr status))))))

    (define (%status-message process)
      ;; `status_message' (`process.c:813'): what the sentinel is given.
      (let* ((parts (%decode-status (%process-status process)))
             (symbol (car parts))
             (code (cadr parts))
             (coredump (caddr parts)))
        (cond
         ((memq symbol '(signal stop))
          (let ((name (%strsignal code)))
            (concat (if (and name (> (string-length name) 0))
                        (string-append
                         (string (char-downcase (string-ref name 0)))
                         (substring name 1))
                        "unknown")
                    (if coredump " (core dumped)\n" "\n"))))
         ((eq? symbol 'exit)
          (if (= code 0)
              "finished\n"
              (format "exited abnormally with code %d%s\n"
                      code (if coredump " (core dumped)" ""))))
         ((eq? symbol 'failed)
          (format "failed with code %s\n" code))
         (else (concat (symbol->string symbol) "\n")))))

    (define (%strsignal n)
      (let ((p (%c-strsignal n)))
        (and p (not (null-pointer? p)) (pointer->string p))))

    ;;----------------------------------------------------------------
    ;; Servicing: what a front end's wait asks of this library.
    ;;----------------------------------------------------------------

    (define (process-alive-processes?)
      (let loop ((al %process-alist))
        (cond ((null? al) #f)
              ((%process-alive (cdar al)) #t)
              (else (loop (cdr al))))))

    (define (%install-child-signal!)
      ;; `child_signal_init': flag the change and wake the front end if
      ;; it can be woken; the reaping is `%reap-children!'.
      (sigaction SIGCHLD
                 (lambda (sig)
                   (let ((wake (*process-event-function*)))
                     (when wake (wake))))))

    (define (%reap-children!)
      ;; `handle_child_signal''s loop (`process.c:7780'): every live
      ;; child that has changed is reaped and its raw status recorded,
      ;; which raises its tick for `%status-notify'.
      (for-each
       (lambda (cell)
         (let ((p (cdr cell)))
           (when (and (%process-alive p) (%process-pid p)
                      (> (%process-pid p) 0))
             (let ((r (waitpid (%process-pid p) (logior WNOHANG WUNTRACED))))
               (when (not (zero? (car r)))
                 (%set-process-raw-status! p (cdr r))
                 (when (or (not (not (status:exit-val (cdr r))))
                           (status:term-sig (cdr r)))
                   (%set-process-alive! p #f))
                 (%set-process-tick! p (%tick!)))))))
       %process-alist))

    (define (%process-by-fd fd)
      ;; **FD may be a port**: a front end's `select` ready set can hold
      ;; the back door's wake port beside the raw descriptors, and `=`
      ;; on a port raises (measured: "Wrong type argument in position 1:
      ;; #<input: read pipe>").  Only descriptors can name a process.
      (if (not (integer? fd))
          #f
          (let loop ((al %process-alist))
            (cond ((null? al) #f)
                  ((= (%process-infd (cdar al)) fd) (cdar al))
                  (else (loop (cdr al)))))))

    (define (process-wait-descriptors)
      ;; The readable descriptors a front end's `select' watches: the
      ;; process half of `compute_input_wait_mask'.
      (let loop ((al %process-alist) (acc '()))
        (cond ((null? al) (reverse acc))
              (else
               (let ((p (cdar al)))
                 (loop (cdr al)
                       (if (and (%process-alive p)
                                (>= (%process-infd p) 0)
                                (not (eq? (%process-filter p) 't)))
                           (cons (%process-infd p) acc)
                           acc)))))))

    (define (process-service-ready! ready)
      ;; Read what `select' said is readable, then report status
      ;; changes - the C's two steps after `pselect'.  Answers the bytes
      ;; read, so a front end knows whether there is something to
      ;; redisplay (Emacs's `got_some_output').
      (let ((total -1))
        (for-each
         (lambda (fd)
           (let ((p (%process-by-fd fd)))
             (when p
               (let ((n (%read-process-output p)))
                 (when (> n 0)
                   (set! total (max total (+ (if (> total 0) total 0) n))))))))
         ready)
        (let ((n (%status-notify #f #f)))
          (if %status-changed (max n 1) (max total n)))))

    (define %process-poll-timer #f)
    (define %process-poll-delay 0.2)
    ;; ^ **The reaper, when `SIGCHLD` does not arrive.**  Emacs reaps
    ;; from its SIGCHLD handler and a signal interrupts `pselect`;
    ;; Guile runs `sigaction` handlers on a thread of its own, and in
    ;; the editor a SIGCHLD did **not** end the terminal's `select`
    ;; (measured: a child dead for four seconds still answered `run`).
    ;; The timer is armed while any process exists, so the command
    ;; loop's read wakes on it (`timer-next-delay`), runs
    ;; `timer-check!`, and the timer reaps and reports - and the loop
    ;; redisplays when a timer ran, which is what shows a sentinel's
    ;; message.

    (define (ensure-process-poll!)
      (unless %process-poll-timer
        (set! %process-poll-timer
              (run-at-time %process-poll-delay %process-poll-delay
                           (lambda ()
                             (process-service!)
                             (unless (process-alive-processes?)
                               (when %process-poll-timer
                                 (cancel-timer %process-poll-timer))
                               (set! %process-poll-timer #f)))))))

    (define (process-service!)
      ;; The same without descriptors to go on: reap and report.
      ;; **A status change counts as something to draw**: a sentinel's
      ;; message is output too, and Emacs redisplays after
      ;; `status_notify` whether or not bytes came with it.
      (%reap-children!)
      (let ((n (%status-notify #f #f)))
        (if %status-changed (max n 1) n)))

    ;;----------------------------------------------------------------
    ;; Creating: `make-process', `create_process' and the child.
    ;;----------------------------------------------------------------

    (define (%plist-get plist key)
      (let loop ((rest plist))
        (cond ((null? rest) #f)
              ((eq? (car rest) key) (and (pair? (cdr rest)) (cadr rest)))
              (else (loop (cddr rest))))))

    (define (%is-pty-from-symbol sym)
      ;; `is_pty_from_symbol' (`process.c:1381').
      (cond ((eq? sym 'pty) #t)
            ((eq? sym 'pipe) #f)
            ((not sym) (if (*process-connection-type*) #t #f))
            (else (error "Unknown connection type %s" sym))))

    (define (%directory? path)
      (and (access? path 0)
           (let ((st (stat path)))
             (eq? 'directory (stat:type st)))))

    (define (%file-executable? path)
      (and (access? path X_OK)
           (let ((st (stat path)))
             (not (eq? 'directory (stat:type st))))))

    (define (%locate-program program)
      ;; The `openp' call in `make-process' (`process.c:2040'): an
      ;; absolute name is used as it stands; anything else is searched
      ;; for in `exec-path'.
      (define (absolute? name)
        (and (> (string-length name) 0)
             (char=? (string-ref name 0) #\/)))
      (guard (e (else
                 (error "Searching for program: No such file or directory, %s"
                        program)))
        (if (absolute? program)
            (if (%directory? program)
                (error "Specified program for new process is a directory")
                program)
            (let loop ((dirs (*exec-path*)))
              (cond
               ((null? dirs)
                (error "Searching for program: No such file or directory, %s"
                       program))
               (else
                (let* ((dir (car dirs))
                       (path (string-append
                              dir
                              (if (char=? (string-ref dir
                                                      (- (string-length dir) 1))
                                          #\/)
                                  "" "/")
                              program)))
                  (if (%file-executable? path)
                      path
                      (loop (cdr dirs))))))))))

    (define (%unique-process-name name)
      ;; `make_process': NAME, NAME<1>, NAME<2>, ... until unused.
      (let loop ((candidate name) (i 1))
        (if (get-process candidate)
            (loop (string-append name "<" (number->string i) ">") (+ i 1))
            candidate)))

    (define (%update-process-mark! process)
      ;; `update_process_mark'.
      (let ((buffer (%process-buffer process)))
        (if (and buffer (buffer-live-p buffer))
            (set-marker (%process-mark process) (buffer-zv buffer) buffer)
            (set-marker (%process-mark process) #f))))

    (define (make-process . args)
      ;; GNU Emacs's `make-process' (`process.c:1813').  ARGS is the
      ;; keyword plist as data - see the header on quoting.
      (if (null? args)
          #f
          (let* ((contact args)
                 (name (%plist-get contact ':name))
                 (buffer-arg (%plist-get contact ':buffer))
                 (buffer (and buffer-arg (get-buffer-create buffer-arg)))
                 (command (%plist-get contact ':command))
                 (program (and (pair? command) (car command))))
            (when (not (string? name))
              (error "make-process: :name must be a string"))
            (let ((proc (make<process> (%unique-process-name name))))
              (%set-process-tty-name! proc #f)
              (%set-process-command! proc
                                     (if (pair? command) (list-copy command) #f))
              (%set-process-buffer! proc buffer)
              (%set-process-sentinel!
               proc (or (%plist-get contact ':sentinel)
                        internal-default-process-sentinel))
              (%set-process-filter!
               proc (or (%plist-get contact ':filter)
                        internal-default-process-filter))
              (%set-process-type! proc 'real)
              (%set-process-plist! proc '())
              (%set-process-status! proc 'run)
              (%set-process-mark! proc (make-marker))
              (%set-process-alive! proc #f)
              (%set-process-raw-status! proc #f)
              (%set-process-tick! proc 0)
              (%set-process-update-tick! proc 0)
              (%set-process-nbytes-read! proc 0)
              (%set-process-write-queue! proc '())
              (%set-process-infd! proc -1)
              (%set-process-outfd! proc -1)
              (%set-process-pid! proc 0)
              (%set-process-kill-without-query!
               proc (%plist-get contact ':noquery))
              (let ((type (%plist-get contact ':connection-type)))
                (if (pair? type)
                    (begin (%set-process-pty-in! proc
                                                 (%is-pty-from-symbol (car type)))
                           (%set-process-pty-out! proc
                                                  (%is-pty-from-symbol (cdr type))))
                    (let ((pty (%is-pty-from-symbol type)))
                      (%set-process-pty-in! proc pty)
                      (%set-process-pty-out! proc pty))))
              (let* ((coding (%plist-get contact ':coding))
                     (decode (if (pair? coding)
                                 (car coding)
                                 (or coding (*coding-system-for-read*)
                                     (car (*default-process-coding-system*)))))
                     (encode (if (pair? coding)
                                 (cdr coding)
                                 (or coding (*coding-system-for-write*)
                                     (cdr (*default-process-coding-system*))))))
                (%set-process-decode-coding! proc decode)
                (%set-process-encode-coding! proc encode))
              (%update-process-mark! proc)
              (set! %process-alist
                    (cons (cons (process-name proc) proc) %process-alist))
              (%create-process! proc program (and (pair? command) (cdr command)))
              proc))))

    ;;----------------------------------------------------------------
    ;; Spawning: `posix_spawn' for a pipe, `forkpty' for a pty.
    ;;----------------------------------------------------------------
    ;;
    ;; **Guile's `primitive-fork' is not usable here.** Installing a
    ;; Scheme `sigaction' handler starts Guile's signal-handling
    ;; thread, and `scm_fork' then aborts the process (measured: a
    ;; SIGABRT inside `scm_fork' from `pthread_once'; two processes,
    ;; parent and child, core-dumped).  Emacs itself prefers
    ;; `posix_spawn' and only forks for a pty; here `posix_spawn' does
    ;; the pipe case and libc's `forkpty' the pty case - both are C
    ;; forks that never enter Guile's fork wrapper, and the child runs
    ;; exactly one or two primitives before `execv'.

    (define %c-posix-spawn
      (%c-func int "posix_spawn"
               (list '* '* '* '* '* '*)))
    (define %c-fa-init
      (%c-func int "posix_spawn_file_actions_init" (list '*)))
    (define %c-fa-destroy
      (%c-func int "posix_spawn_file_actions_destroy" (list '*)))
    (define %c-fa-adddup2
      (%c-func int "posix_spawn_file_actions_adddup2" (list '* int int)))
    (define %c-fa-addclose
      (%c-func int "posix_spawn_file_actions_addclose" (list '* int)))
    (define %c-fa-addchdir
      (let ((f (dynamic-func "posix_spawn_file_actions_addchdir_np" %libc)))
        (and f (pointer->procedure int f (list '* '*)))))
    (define %c-forkpty
      (%c-func int "forkpty" (list '* '* '* '*)))
    (define %c-execv (%c-func int "execv" (list '* '* '*)))
    (define %c-chdir-guard (%c-func int "chdir" (list '*)))

    (define (%file-actions)
      ;; A zeroed `posix_spawn_file_actions_t'.  glibc's struct is
      ;; `{int allocated; int used; void *actions; int pad[16];}' - 80
      ;; bytes; 128 is enough and stays 8-byte aligned, which
      ;; `make-c-struct' guarantees.
      (let ((fa (make-c-struct (make-list 32 int) (make-list 32 0))))
        (%c-fa-init fa)
        fa))

    (define (%string-array strings)
      ;; STRINGS as a NULL-terminated `char *[]'.  Answers
      ;; (ARRAY . STRING-POINTERS) so the caller can free them.
      (let* ((ptrs (map string->pointer strings))
             (arr (make-c-struct (append (make-list (length ptrs) '*) (list '*))
                                 (append ptrs (list %null-pointer)))))
        (cons arr ptrs)))

    (define (%free-string-array! pair)
      ;; Nothing to free: `string->pointer' hands back GC-managed
      ;; memory, and `free' on it corrupts the heap - measured, "free():
      ;; invalid size" and a core dump after about a hundred spawns.
      ;; The array is GC memory too, and everything becomes collectable
      ;; as soon as the spawn returns.
      #t)

    (define (%spawn-error what code)
      (error "%s: %s" what (%strerror code)))

    (define (%strerror code)
      (let ((p ((%c-func '* "strerror" (list int)) code)))
        (if (and p (not (null-pointer? p))) (pointer->string p) "?")))

    (define (%ptsname master)
      (let ((p (%c-ptsname master)))
        (and p (not (null-pointer? p)) (pointer->string p))))

    (define (%install-process-running! process pid inchannel outchannel)
      ;; The C's "Record this as an active process, with its channels."
      (%set-process-pid! process pid)
      (%set-process-alive! process #t)
      (%set-process-infd! process inchannel)
      (%set-process-outfd! process outchannel)
      (%set-process-status! process 'run))

    (define (%spawn-pty! path cwd argv envp)
      ;; `forkpty(3)': openpty, fork and `login_tty' in C - the pty
      ;; branch of `emacs_spawn' (setsid, TIOCSCTTY and the three
      ;; descriptors), none of it in Scheme.  Answers the master fd in
      ;; the parent; the child either execs the program or exits 127.
      (let* ((m (make-c-struct (list int) (list 0)))
             (pid (%c-forkpty m %null-pointer %null-pointer %null-pointer)))
        (cond
         ((= pid 0)
          (when cwd (%c-chdir-guard (string->pointer cwd)))
          (%c-execv (string->pointer path) (car argv) (car envp))
          (primitive-exit 127))
         ((< pid 0)
          (error "Opening pty failed"))
         (else
          (let ((master (car (parse-c-struct m (list int)))))
            (fcntl master F_SETFL
                   (logior (fcntl master F_GETFL) O_NONBLOCK))
            (cons pid master))))))

    (define (%spawn-pipe! path cwd argv envp)
      ;; `posix_spawn' with the C's pipe descriptors as file actions -
      ;; Emacs's preferred mechanism for a subprocess, and the one that
      ;; never enters Guile's fork wrapper.  Answers (PID . (IN .
      ;; OUT)) with the parent's two ends.
      (let* ((stdin-pipe (%make-pipe))
             (stdout-pipe (%make-pipe))
             (forkin (car stdin-pipe))
             (outchannel (cdr stdin-pipe))
             (inchannel (car stdout-pipe))
             (forkout (cdr stdout-pipe))
             (fa (%file-actions))
             (pid (make-c-struct (list int) (list 0)))
             (rc 0))
        (fcntl inchannel F_SETFL
               (logior (fcntl inchannel F_GETFL) O_NONBLOCK))
        (fcntl outchannel F_SETFL
               (logior (fcntl outchannel F_GETFL) O_NONBLOCK))
        (%c-fa-adddup2 fa forkin 0)
        (%c-fa-adddup2 fa forkout 1)
        (%c-fa-adddup2 fa forkout 2)
        (%c-fa-addclose fa forkin)
        (%c-fa-addclose fa forkout)
        (%c-fa-addclose fa outchannel)
        (%c-fa-addclose fa inchannel)
        (when (and %c-fa-addchdir cwd)
          (%c-fa-addchdir fa (string->pointer cwd)))
        (set! rc (%c-posix-spawn pid (string->pointer path) fa %null-pointer
                                 (car argv) (car envp)))
        (%c-fa-destroy fa)
        (close-fdes forkin)
        (close-fdes forkout)
        (if (zero? rc)
            (cons (car (parse-c-struct pid (list int)))
                  (cons inchannel outchannel))
            (begin
              (close-fdes inchannel)
              (close-fdes outchannel)
              (%spawn-error "Searching for program" rc)))))

    (define (%create-process! process program args)
      ;; `create_process' (`process.c:2206') on `emacs_spawn''s two
      ;; mechanisms: `forkpty' for a pty, `posix_spawn' for a pipe.
      (when (not program)
        (error "make-process: no :command"))
      (let* ((pty-in (%process-pty-in process))
             (pty-out (%process-pty-out process))
             (pty (and (or pty-in pty-out) #t))
             (path (%locate-program program))
             (cwd (or (buffer-local-value (current-buffer)
                                          'default-directory #f)
                      (getcwd)))
             (argv (%string-array (cons path args)))
             (envp (%string-array (*process-environment*))))
        (%install-child-signal!)
        (cond
         (pty
          (when (not (and pty-in pty-out))
            (error "make-process: a mixed :connection-type is not carried"))
          (let ((r (%spawn-pty! path cwd argv envp)))
            (%free-string-array! argv)
            (%free-string-array! envp)
            (%set-process-tty-name! process (%ptsname (cdr r)))
            (%install-process-running! process (car r) (cdr r) (cdr r))
            (ensure-process-poll!)))
         (else
          (let ((r (%spawn-pipe! path cwd argv envp)))
            (%free-string-array! argv)
            (%free-string-array! envp)
            (%install-process-running! process (car r)
                                       (cadr r) (cddr r))
            (ensure-process-poll!))))))

    (define (start-process name buffer program . args)
      ;; GNU Emacs's `start-process' (`subr.el`): `make-process' with a
      ;; command list.
      (make-process ':name name ':buffer buffer ':command (cons program args)))

    (define (start-process-shell-command name buffer command)
      ;; GNU Emacs's `start-process-shell-command' (`process.c`).
      (make-process ':name name ':buffer buffer
                    ':command (list shell-file-name shell-command-switch command)
                    ':connection-type 'pipe))

    (define (start-file-process name buffer program . program-args)
      ;; GNU Emacs's `start-file-process` (`simple.el:5293'): "Start a
      ;; program in a subprocess. Return the process object for it.
      ;; Similar to `start-process', but may invoke a file name handler
      ;; based on `default-directory'."
      ;;
      ;; **A placement departure**: Emacs has it in `simple.el`, and
      ;; `simple.scm` is above this library (it imports `keyboard`,
      ;; which imports `process` for `timer-check!`), so a definition
      ;; there would close the cycle - the `%kill-buffer` rule. The
      ;; handler arm is not carried, and has nothing to find: no
      ;; file-name handler is registered here (`file-remote-p` answers
      ;; nil for everything), so Emacs's own
      ;; `(if fh (apply fh ...) (apply #'start-process ...))' reduces to
      ;; the call below.
      ;;--------------------------------------------------------------
      (apply start-process name buffer program program-args))

    (define (start-file-process-shell-command name buffer command)
      ;; GNU Emacs's `start-file-process-shell-command' (`subr.el:5063'):
      ;; "Similar to `start-process-shell-command', but calls
      ;; `start-file-process'."
      ;;
      ;; **A placement departure**, as for `start-file-process` above:
      ;; Emacs has it in `subr.el`, which is below this library here.
      ;; Emacs's `with-connection-local-variables` arm is not carried -
      ;; no connection-local machinery exists here, and no file-name
      ;; handler either.
      ;;--------------------------------------------------------------
      (start-file-process name buffer shell-file-name shell-command-switch
                          command))

    ;;----------------------------------------------------------------
    ;; The accessors with a body.
    ;;----------------------------------------------------------------

    (define (set-process-buffer process buffer)
      ;; `process.c:1339'.
      (if (not (eq? (%process-buffer process) buffer))
          (begin
            (%set-process-buffer! process buffer)
            (%update-process-mark! process)))
      buffer)

    (define (set-process-filter process filter)
      ;; `process.c:1405'.  t means stop reading the process's output.
      (%set-process-filter! process (or filter internal-default-process-filter))
      (process-filter process))

    (define (set-process-sentinel process sentinel)
      ;; `process.c:1464'.
      (%set-process-sentinel! process
                              (or sentinel internal-default-process-sentinel))
      (process-sentinel process))

    (define (process-coding-system process)
      ;; `process.c:8085'.
      (cons (%process-decode-coding process) (%process-encode-coding process)))

    (define (set-process-coding-system process decoding encoding)
      ;; `process.c:8058'.
      (%set-process-decode-coding! process decoding)
      (%set-process-encode-coding! process encoding)
      #f)

    (define (get-buffer-process buffer)
      ;; `process.c:8455'.
      (let ((buffer (and buffer (get-buffer buffer))))
        (and buffer
             (let loop ((al %process-alist))
               (cond ((null? al) #f)
                     ((eq? (%process-buffer (cdar al)) buffer) (cdar al))
                     (else (loop (cdr al))))))))

    (define (%get-process-x name)
      ;; `get_process' (`process.c:1073'): the coercion the commands
      ;; with a PROCESS argument use.
      (cond
       ((string? name)
        (or (get-process name)
            (let ((buffer (get-buffer name)))
              (if buffer
                  (%get-process-x buffer)
                  (error "Process %s does not exist" name)))))
       ((not name) (%get-process-x (current-buffer)))
       ((bufferp name)
        (or (get-buffer-process name)
            (error "Buffer %s has no process"
                   (or (buffer-name name) "?"))))
       (else
        (when (not (process? name))
          (error "Wrong type argument: processp, %s" name))
        name)))

    ;;----------------------------------------------------------------
    ;; Output: `read_process_output' and the filters.
    ;;----------------------------------------------------------------

    (define (internal-default-process-filter process text)
      ;; `process.c:6686': "This inserts the process's output into its
      ;; buffer, if there is one.  Otherwise it discards the output."
      (let ((buffer (%process-buffer process)))
        (when (and buffer (buffer-live-p buffer))
          (save-current-buffer
           (lambda ()
             (set-buffer buffer)
             (let ((opoint (point))
                   (read-only (buffer-read-only? buffer))
                   (deactivate (buffer-local-value buffer 'deactivate-mark #f)))
               (set!buffer-read-only buffer #f)
               (let* ((marker (%process-mark process))
                      (before (if (marker-buffer marker)
                                  (begin (goto-char (marker-position marker))
                                         (point))
                                  (goto-char (point-max)))))
                 ;; `insert_from_string_before_markers': INHERIT false,
                 ;; BEFORE-MARKERS true.
                 (insert-from-string text #f #t)
                 (set-marker (%process-mark process) (point) buffer)
                 (goto-char (if (>= opoint before)
                                (+ opoint (- (point) before))
                                opoint)))
               (set!buffer-read-only buffer read-only)
               ;; "Handling the process output should not deactivate
               ;; the mark" (`read_process_output').
               (set-buffer-local-value! buffer 'deactivate-mark deactivate)))))
      #f))

    (define (internal-default-process-sentinel process msg)
      ;; `process.c:8007': the "\nProcess NAME MESSAGE" line in the
      ;; process's buffer.
      (let ((buffer (%process-buffer process)))
        (when (and buffer (buffer-live-p buffer)
                   (not (eq? (%process-status process) 'run)))
          (save-current-buffer
           (lambda ()
             (set-buffer buffer)
             (let ((opoint (point))
                   (read-only (buffer-read-only? buffer))
                   (deactivate (buffer-local-value buffer 'deactivate-mark #f)))
               (set!buffer-read-only buffer #f)
               (let* ((marker (%process-mark process))
                      (before (if (marker-buffer marker)
                                  (begin (goto-char (marker-position marker))
                                         (point))
                                  (goto-char (point-max)))))
                 (insert (concat "\nProcess " (process-name process) " " msg))
                 (set-marker (%process-mark process) (point) buffer)
                 (goto-char (if (>= opoint before)
                                (+ opoint (- (point) before))
                                opoint)))
               (set!buffer-read-only buffer read-only)
               (set-buffer-local-value! buffer 'deactivate-mark deactivate)))))
      #f))

    (define (%points->text points)
      ;; Decoded code points as a Scheme string.  A byte character
      ;; (`#x3FFF00 + byte') has no character to be - the standing
      ;; departure - so it becomes U+FFFD here; the buffer path is
      ;; lossless because `insert-from-string' takes the list itself.
      (list->string
       (map (lambda (cp) (if (> cp #x10FFFF) #\xfffd (code-point->char cp)))
            points)))

    (define (%read-process-output process)
      ;; `read_process_output' (`process.c:6279'): one read, disposed.
      (let ((fd (%process-infd process)))
        (if (< fd 0)
            -1
            (let ((n (%c-read fd (bytevector->pointer %read-buffer)
                              %read-process-output-max)))
              (cond
               ((< n 0) -1)              ; EAGAIN or EINTR: nothing now
               ((= n 0) 0)               ; end of file
               (else
                (let* ((bytes (bytevector-copy %read-buffer 0 n))
                       (points (decode-coding-bytes
                                bytes (%process-decode-coding process))))
                  (%set-process-nbytes-read!
                   process (+ (%process-nbytes-read process) n))
                  (%dispose-process-output process points)
                  n)))))))

    (define (%dispose-process-output process points)
      ;; `read_and_dispose_of_process_output' (`process.c:6559'): the
      ;; filter call, quit inhibited and errors wrapped.
      (let ((filter (%process-filter process)))
        (if (eq? filter 't)
            #f
            (let ((text (if (eq? filter internal-default-process-filter)
                            points
                            (%points->text points))))
              (parameterize ((*inhibit-quit* #t))
                (save-match-data
                 (%condition-case-report
                  "error in process filter: "
                  (lambda () (filter process text)))))))))

    (define (%condition-case-report prefix thunk)
      ;; `internal_condition_case_1' with `read_process_output_error_handler'
      ;; (`process.c:6248'): an error in a filter is reported and the
      ;; wait carries on.
      (guard (e (else
                 (message "%s%s" prefix
                          (if (error-object? e)
                              (error-message-string e)
                              (format "%s" e)))
                 #f))
        (thunk)))

    ;;----------------------------------------------------------------
    ;; Status changes: `status_notify' and the sentinels.
    ;;----------------------------------------------------------------

    (define (%status-notify deleting-process wait-process)
      ;; `status_notify' (`process.c:7917').  Returns how many bytes
      ;; were read (-1 for none).
      (let ((got -1))
        (set! %status-changed #f)
        (for-each
         (lambda (cell)
           (let ((p (cdr cell)))
             (when (not (= (%process-tick p) (%process-update-tick p)))
               (set! %status-changed #t)
               (%set-process-update-tick! p (%process-tick p))
               ;; "If process is still active, read any output that
               ;; remains."
               (let drain ()
                 ;; **The gate is the descriptor, not ALIVE.**  The C's
                 ;; `status_notify' reads "any output that remains"
                 ;; from a process whose status has *changed* - which
                 ;; is exactly the process that has just died - and
                 ;; gating on ALIVE dropped the last chunk whenever the
                 ;; child exited with output still in the pipe
                 ;; (measured: a flaky empty buffer in the suite).
                 (when (and (>= (%process-infd p) 0)
                            (not (eq? (%process-filter p) 't))
                            (not (eq? p deleting-process)))
                   (let ((n (%read-process-output p)))
                     (set! got (max got n))
                     (when (> n 0) (drain)))))
               (%update-status! p)
               (let ((msg (%status-message p)))
                 (let ((symbol (car (%decode-status (%process-status p)))))
                   (when (memq symbol '(signal exit closed))
                     (if (*delete-exited-processes*)
                         (%remove-process! p)
                         (%deactivate-process! p))))
                 (%set-process-update-tick! p (%process-tick p))
                 (%exec-sentinel p msg)))))
         %process-alist)
        got))

    (define (%exec-sentinel process reason)
      ;; `exec_sentinel' (`process.c:7844').
      (let ((sentinel (%process-sentinel process)))
        (parameterize ((*inhibit-quit* #t))
          (save-match-data
           (%condition-case-report
            "error in process sentinel: "
            (lambda () (sentinel process reason)))))))

    (define (%remove-process! process)
      ;; `remove_process' (`process.c:1023').
      (set! %process-alist
            (let loop ((al %process-alist) (acc '()))
              (cond ((null? al) (reverse acc))
                    ((eq? (cdar al) process) (loop (cdr al) acc))
                    (else (loop (cdr al) (cons (car al) acc))))))
      (%deactivate-process! process))

    (define (%deactivate-process! process)
      ;; `deactivate_process': close the descriptors.
      (when (>= (%process-infd process) 0)
        (close-fdes (%process-infd process)))
      (when (and (>= (%process-outfd process) 0)
                 (not (= (%process-outfd process) (%process-infd process))))
        (close-fdes (%process-outfd process)))
      (%set-process-infd! process -1)
      (%set-process-outfd! process -1))

    ;;----------------------------------------------------------------
    ;; Sending: `send_process' and the DEFUNs over it.
    ;;----------------------------------------------------------------

    (define (%string->u32vector string)
      (list->u32vector (map char->integer (string->list string))))

    (define (%send-text process text)
      ;; TEXT is a Scheme string; it goes out in the process's encoding.
      (%send-process process
                     (encode-coding-string (%string->u32vector text)
                                           (%process-encode-coding process))))

    (define (process-send-string process string)
      ;; `process.c:7032'.
      (%send-text (%get-process-x process) string)
      #f)

    (define (process-send-region process start end)
      ;; `process.c:6996'.
      (%send-text (%get-process-x process) (buffer-substring start end))
      #f)

    (define (%send-process process bytes)
      ;; `send_process' (`process.c:6767'): the write loop, with the
      ;; C's EAGAIN wait.
      (let ((outfd (%process-outfd process)))
        (when (< outfd 0)
          (error "Output file descriptor of %s is closed"
                 (process-name process)))
        (let ((len (bytevector-length bytes)))
          (let loop ((start 0))
            (when (< start len)
              (let ((n (%c-write outfd (bytevector->pointer bytes start)
                                 (- len start))))
                (cond
                 ((> n 0) (loop (+ start n)))
                 ((= n 0) (loop start))
                 (else
                  (let ((e (errno)))
                    (cond
                     ((= e EINTR) (loop start))
                     ((= e EAGAIN)
                      ;; The child's buffer is full: accept its output
                      ;; for a moment, then retry - the C's
                      ;; `wait_reading_process_output (0, 20ms, ...)'.
                      (process-service!)
                      (if (null? (car (select '() (list outfd) '() 0.02)))
                          (sleep 0)
                          #t)
                      (loop start))
                     ((= e EPIPE)
                      (when (>= (%process-outfd process) 0)
                        (close-fdes (%process-outfd process)))
                      (%set-process-outfd! process -1)
                      (error "Process %s no longer connected to pipe; closed it"
                             (process-name process)))
                     (else
                      (error "Writing to process %s"
                             (process-name process)))))))))))))

    (define (process-send-eof . process-arg)
      ;; `process.c:7474' `(process-send-eof &optional PROCESS)': "^D on
      ;; a pty's input, or close the write end and give the slot
      ;; /dev/null." PROCESS nil means the current buffer's process, as
      ;; the C's `get_process` has it.
      (let* ((process (if (pair? process-arg) (car process-arg) #f))
             (process (or process (get-buffer-process (current-buffer))))
             (process (%get-process-x process)))
        (when (not (eq? (%process-status process) 'run))
          (error "Process %s not running: %s"
                 (process-name process) (%status-message process)))
        (if (%process-pty-in process)
            (%send-process process (bytevector 4))
            (begin
              (when (>= (%process-outfd process) 0)
                (close-fdes (%process-outfd process)))
              (%set-process-outfd! process (open-fdes "/dev/null" O_WRONLY 0))))
        #f))

    (define (signal-process process sig)
      ;; `process.c:7455', the pid form.
      (let ((pid (cond ((process? process) (%process-pid process))
                       ((string? process)
                        (let ((p (get-process process)))
                          (and p (%process-pid p))))
                       (else process))))
        (if (and pid (> pid 0))
            (begin (kill pid sig) 0)
            (error "Process %s does not exist" process))))

    (define (num-processors . query-arg)
      ;; GNU Emacs's `num-processors` (`process.c:8643'): "Return the
      ;; number of processors, a positive integer. Each usable thread
      ;; execution unit counts as a processor. By default, count the
      ;; number of available processors, overridable via the
      ;; OMP_NUM_THREADS environment variable. If optional argument
      ;; QUERY is `current', ignore OMP_NUM_THREADS. If QUERY is `all',
      ;; also count processors not available."
      ;;
      ;; **The count comes from /proc/cpuinfo**, which lists every
      ;; processor the kernel sees; the C's `NPROC_CURRENT` narrows to
      ;; the affinity mask, and Guile exposes no `getaffinity` on this
      ;; build, so `current` and `all` answer the same number here -
      ;; the named departure.
      ;;--------------------------------------------------------------
      (let ((query (if (pair? query-arg) (car query-arg) #f)))
        (if (not (eq? query 'current))
            (let ((env (getenv "OMP_NUM_THREADS")))
              (if (and env (string->number env) (> (string->number env) 0))
                  (string->number env)
                  (%num-processors-from-proc)))
            (%num-processors-from-proc))))

    (define (%num-processors-from-proc)
      (let ((port (open-input-file "/proc/cpuinfo"))
            (count 0))
        (let loop ()
          (let ((line (read-line port)))
            (if (eof-object? line)
                (begin (close-port port) (if (> count 0) count 1))
                (begin
                  (if (string-prefix? "processor" line)
                      (set! count (+ count 1)))
                  (loop)))))))

    (define (process-query-on-exit-flag process)
      ;; GNU Emacs's `process-query-on-exit-flag` (`process.c:1604'):
      ;; "Return the current value of query-on-exit flag for PROCESS."
      ;;--------------------------------------------------------------
      (not (%process-kill-without-query process)))

    (define (set-process-query-on-exit-flag process flag)
      ;; GNU Emacs's `set-process-query-on-exit-flag` (`process.c:1590'):
      ;; "Specify if query is needed for PROCESS when Emacs is exited. If
      ;; the second argument FLAG is non-nil, Emacs will query the user
      ;; before exiting or killing a buffer if PROCESS is running. This
      ;; function returns FLAG." The stored field is the negation, as
      ;; the C's `kill_without_query = NILP (flag)' is.
      ;;--------------------------------------------------------------
      (%set-process-kill-without-query! process (not flag))
      flag)

    ;;----------------------------------------------------------------
    ;; The signal commands: `process.c:7126' `process_send_signal',
    ;; and the five DEFUNs at `:7273'-`:7360'.
    ;;----------------------------------------------------------------

    (define (%process-send-signal process signo current-group)
      ;; `process_send_signal`: PROCESS may be a process, a buffer or
      ;; the name of either, and nil is the current buffer's process.
      ;; The signal goes to the process's own group, or - with
      ;; CURRENT-GROUP set and a pty - to the terminal's current group,
      ;; which is how `C-c C-c' interrupts the subjob the shell is
      ;; running rather than the shell.
      ;;
      ;; **Not carried**: the `SIGNALS_VIA_CHARACTERS' arm, which writes
      ;; the terminal's VINTR/VQUIT/VSUSP byte instead of calling
      ;; `kill' (it needs `tcgetattr', and the tree has one terminal).
      ;; The `kill' path below is the C's own fallback for the same
      ;; signals and reaches the same group.
      ;;--------------------------------------------------------------
      (let ((proc (cond ((process? process) process)
                        ((bufferp process) (get-buffer-process process))
                        ((string? process)
                         (or (get-process process)
                             (and (get-buffer process)
                                  (get-buffer-process (get-buffer process)))))
                        ((not process) (get-buffer-process (current-buffer)))
                        (else #f))))
        (unless proc
          (error "Process %s does not exist" process))
        (unless (eq? (%process-type proc) 'real)
          (error "Process ~a is not a subprocess" (process-name proc)))
        (when (< (%process-infd proc) 0)
          (error "Process ~a is not active" (process-name proc)))
        (let* ((group (and current-group (%process-pty-in proc) #t))
               (pid (%process-pid proc)))
          (kill (if group (- pid) pid) signo))
        process))

    (define (interrupt-process . args)
      ;; GNU Emacs's `interrupt-process` (`process.c:7273'): "Interrupt
      ;; process PROCESS. PROCESS may be a process, a buffer, or the
      ;; name of a process or buffer. No arg or nil means current
      ;; buffer's process. Second arg CURRENT-GROUP non-nil means send
      ;; signal to the current process-group of the process's
      ;; controlling terminal rather than to the process's own process
      ;; group. If the process is a shell, this means interrupt current
      ;; subjob rather than the shell."
      ;;--------------------------------------------------------------
      (%process-send-signal (if (pair? args) (car args) #f)
                            SIGINT
                            (if (and (pair? args) (pair? (cdr args)))
                                (cadr args) #f)))

    (define (kill-process . args)
      ;; GNU Emacs's `kill-process` (`process.c:7294'): "Kill process
      ;; PROCESS. May be process or name of one. See function
      ;; `interrupt-process' for more details on usage."
      ;;--------------------------------------------------------------
      (%process-send-signal (if (pair? args) (car args) #f)
                            SIGKILL
                            (if (and (pair? args) (pair? (cdr args)))
                                (cadr args) #f)))

    (define (quit-process . args)
      ;; GNU Emacs's `quit-process` (`process.c:7304'): "Send QUIT
      ;; signal to process PROCESS. May be process or name of one. See
      ;; function `interrupt-process' for more details on usage."
      ;;--------------------------------------------------------------
      (%process-send-signal (if (pair? args) (car args) #f)
                            SIGQUIT
                            (if (and (pair? args) (pair? (cdr args)))
                                (cadr args) #f)))

    (define (stop-process . args)
      ;; GNU Emacs's `stop-process` (`process.c:7313'): "Stop process
      ;; PROCESS. May be process or name of one. See function
      ;; `interrupt-process' for more details on usage."
      ;;
      ;; The C's network/serial/pipe "inhibit incoming traffic" arm has
      ;; nothing to do here: a pipe process's traffic is `select'ed,
      ;; and STATUS `stop' already makes `%read-process-output' leave
      ;; it alone.
      ;;--------------------------------------------------------------
      (%process-send-signal (if (pair? args) (car args) #f)
                            SIGTSTP
                            (if (and (pair? args) (pair? (cdr args)))
                                (cadr args) #f)))

    (define (continue-process . args)
      ;; GNU Emacs's `continue-process` (`process.c:7340'): "Continue
      ;; process PROCESS. May be process or name of one. See function
      ;; `interrupt-process' for more details on usage."
      ;;--------------------------------------------------------------
      (%process-send-signal (if (pair? args) (car args) #f)
                            SIGCONT
                            (if (and (pair? args) (pair? (cdr args)))
                                (cadr args) #f)))


    ;;----------------------------------------------------------------
    ;; `delete-process'.
    ;;----------------------------------------------------------------

    (define-command (delete-process process)
      "Delete PROCESS: kill it and forget about it immediately.
PROCESS may be a process, a buffer, the name of a process or buffer, or
nil, indicating the current buffer's process.

Interactively, it will kill the current buffer's process."
      (interactive (list 'message))
      (let ((mess (eq? process 'message))
            (p #f))
        (when mess (set! process #f))
        (set! p (%get-process-x process))
        (let ((pid (%process-pid p)))
          (when (and pid (> pid 0) (%process-alive p))
            (kill pid SIGKILL)
            ;; Emacs records the pid and lets the SIGCHLD handler reap
            ;; it; reaping here is what leaves no zombie behind.
            (let ((r (waitpid pid 0)))
              (when (not (zero? (car r)))
                (%set-process-raw-status! p (cdr r))
                (%set-process-alive! p #f)))))
        (%set-process-status! p (list 'signal SIGKILL #f))
        (%set-process-tick! p (%tick!))
        (%status-notify p #f)
        (%remove-process! p)
        (when mess (message "Deleted process"))
        #f))

    ;;----------------------------------------------------------------
    ;; The wait: `wait_reading_process_output' and
    ;; `accept-process-output'.
    ;;----------------------------------------------------------------

    (define (wait-reading-process-output time-limit nsecs read-kbd
                                         wait-process just-wait-proc)
      ;; `wait_reading_process_output' (`process.c:5373'), the part a
      ;; subprocess-only tree needs.  Answers the bytes read from
      ;; WAIT-PROCESS (or from any process when it is #f), -1 for none.
      ;;
      ;; TIME-LIMIT and NSECS follow the C: negative means "gobble what
      ;; is ready and return"; both zero means wait for ever; a
      ;; positive total is a deadline.  READ-KBD is 0 here (the caller
      ;; owns the keyboard), so timers run and a pending quit is
      ;; raised only by the callers that ask for it.
      ;;--------------------------------------------------------------
      (let* ((waiting (cond ((or (< time-limit 0) (< nsecs 0)) 'minimum)
                            ((or (> time-limit 0) (> nsecs 0)) 'timeout)
                            (else 'forever)))
             (deadline (and (eq? waiting 'timeout)
                            (+ (current-second) time-limit (/ nsecs 1e9)))))
        (let loop ((got -1))
          (when (>= read-kbd 0) (maybe-quit))
          (%reap-children!)
          (set! got (max got (%status-notify #f wait-process)))
          (let ((status (and wait-process (%process-status wait-process))))
            (cond
             ;; "Don't wait for output from a non-running process.  Just
             ;; read whatever data has already been received."
             ((and wait-process (not (memq status '(run stop))))
              (let drain ((total 0))
                (let ((n (%read-process-output wait-process)))
                  (if (> n 0) (drain (+ total n)) (+ (max got 0) total)))))
             ((eq? waiting 'minimum)
              (max got 0))
             (else
              (let* ((timer-delay (timer-next-delay))
                     (remaining (and deadline (- deadline (current-second))))
                     (timeout (cond ((eq? waiting 'timeout) (max 0 remaining))
                                    (timer-delay (max 0 timer-delay))
                                    (else #f)))
                     (fds (if (and wait-process just-wait-proc)
                              (if (>= (%process-infd wait-process) 0)
                                  (list (%process-infd wait-process))
                                  '())
                              (process-wait-descriptors)))
                     (ready (if (null? fds)
                                (begin (when timeout (wait-sleep timeout)) '())
                                (car (select fds '() '() timeout)))))
                (when (null? ready)
                  ;; A signal (SIGCHLD), a timer, or the deadline.
                  (%reap-children!)
                  (set! got (max got (%status-notify #f wait-process)))
                  (timer-check!))
                (for-each
                 (lambda (fd)
                   (let ((p (%process-by-fd fd)))
                     (when p
                       (let ((n (%read-process-output p)))
                         (when (and (> n 0)
                                    (or (not wait-process)
                                        (eq? p wait-process)))
                           (set! got (max got (+ (max got 0) n))))))))
                 ready)
                (%reap-children!)
                (set! got (max got (%status-notify #f wait-process)))
                (let ((status (and wait-process
                                   (%process-status wait-process))))
                  (cond
                   ;; The process waited for has exited and been
                   ;; drained, or has produced output.
                   ((and wait-process
                         (not (memq status '(run stop)))
                         (not (memq (%process-infd wait-process) ready)))
                    (max got 0))
                   ((and wait-process
                         (> (max got 0) 0))
                    (max got 0))
                   ((and deadline (>= (current-second) deadline))
                    (max got 0))
                   ((and (not ready) (eq? waiting 'timeout))
                    (max got 0))
                   (else (loop got)))))))))))

    (define (wait-sleep seconds)
      ;; `select' with a timeout and no descriptors: Guile allows the
      ;; empty set (measured), and unlike `sleep' a signal interrupts
      ;; it.
      (select '() '() '() (max 0 seconds)))

    (define (%arg args n)
      ;; The Nth of a rest argument list, #f when short.
      (let loop ((a args) (k n))
        (cond ((null? a) #f)
              ((= k 0) (car a))
              (else (loop (cdr a) (- k 1))))))

    (define (accept-process-output . args)
      ;; GNU Emacs's `accept-process-output' (`process.c:4909').
      (let* ((process (%arg args 0))
             (seconds (%arg args 1))
             (millisec (%arg args 2))
             (just-this-one (%arg args 3))
             (process (and process (%get-process-x process)))
             (just-this-one (if process just-this-one #f))
             (seconds (cond ((not millisec) seconds)
                            ((not seconds) (/ millisec 1000.0))
                            (else (+ seconds (/ millisec 1000.0)))))
             (time-limit (if (and (number? seconds) (> seconds 0)) seconds 0))
             (nsecs (cond ((not seconds) (if process 0 -1))
                          ((> seconds 0) 0)
                          (else -1))))
        (if (> (wait-reading-process-output
                time-limit nsecs 0 process
                (if just-this-one (if (number? just-this-one) -1 1) 0))
               0)
            #t
            #f)))

    ;; The mode line's `%s` construct (`xdisp.c:29824`) is this
    ;; library's: "no process" when the buffer has none, else
    ;; `symbol-name` of `process-status`.  `xdisp.scm` is below this
    ;; library, so it asks through the seam.
    (*mode-line-process-status-function*
     (lambda (buffer)
       (let ((proc (get-buffer-process buffer)))
         (if proc
             (symbol->string (process-status proc))
             "no process"))))
    ))
