(define-library (schemacs editor fileio)
  ;; This library mirrors GNU Emacs's `src/fileio.c' - the file
  ;; primitives themselves, as against `files.el' (`(schemacs editor
  ;; files)'), which is the file-*visiting* layer built on them.
  ;;
  ;; Most of these are a wrapping of what Guile already has, which is the
  ;; substitution AGENTS.md allows for a facility that exists in Scheme
  ;; or in a library: `stat' / `lstat' with their `stat:mode' and
  ;; `stat:type' accessors, `access?', `readlink', `mkdir', `rmdir',
  ;; `delete-file', `rename-file', `copy-file' and `chmod'. What is
  ;; written here is the *Emacs contract* on top of them - which
  ;; arguments are expanded first, what a missing file answers, what a
  ;; symlink answers, and how much of the mode is kept.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * file name handlers (`file-name-handler-alist'), which is what
  ;;     makes a name like "/ssh:host:/path" work. Every function here
  ;;     asks `find-file-name-handler' in the C, and there is no handler
  ;;     list in this tree, so the question is not asked.
  ;;   * `substitute-in-file-name', which is a chain of its own: it needs
  ;;     `search_embedded_absfilename' and `substitute-env-vars'
  ;;     (`env.el'), neither of which is here yet.
  ;;   * `default-directory' is a buffer-local *variable* (`buffer.c')
  ;;     that `expand-file-name' reads. It used to live in
  ;;     `(schemacs editor files)', which is where the file I/O half of
  ;;     this project started, and has moved to `(schemacs editor
  ;;     buffer)' beside `buffer-default-directory', where it belongs.
  ;;
  ;; `expand-file-name', `file-exists-p' and `file-writable-p' were in
  ;; `(schemacs editor files)' too, where the file I/O half of this
  ;; project started, and have now been moved here where they belong.

  (import
    (scheme base)
    (scheme char)
    ;; `logand' is Guile's, not R7RS's, and `file-modes' masks with it;
    ;; `string-rindex' is what the two name helpers find their slash
    ;; with.
    (only (guile) logand string-rindex)
    ;; `statvfs' is reached through Guile's FFI - `(system foreign)'
    ;; dlopens libc and calls the function through its pointer, so there
    ;; is no C to write. `(rnrs bytevectors)' is here for the struct: the
    ;; C fills a buffer we own, and its fields are read at fixed offsets.
    ;; The FFI is two imports, split as `pgtk.sld' splits it: the
    ;; *pointer procedures* are `(system foreign)''s, while
    ;; `dynamic-link' and `dynamic-func' are core bindings and come from
    ;; `(guile)'. Importing `(system foreign)' whole binds neither of those
    ;; two - inside a `define-library' it binds nothing at all, which a
    ;; five-line library shows - so the split is not tidiness.
    (only (system foreign)
          pointer->procedure string->pointer bytevector->pointer int)
    (only (guile) dynamic-link dynamic-func)
    (only (rnrs bytevectors) bytevector-u64-ref native-endianness)
    ;; The operating system calls. `rename-file' and `copy-file' are
    ;; renamed as they come in, because this library defines functions
    ;; under those two names and would otherwise call itself.
    (rename (only (guile) rename-file copy-file)
            (rename-file %rename-file)
            (copy-file %copy-file))
    (only (guile)
          F_OK R_OK W_OK X_OK
          access? chmod delete-file getenv getpwnam lstat mkdir readlink rmdir
          stat stat:mode stat:type)
    ;; `substitute-env-vars' is `env.el''s, and is what
    ;; `substitute-in-file-name' below substitutes the variables with.
    (only (schemacs editor env) substitute-env-vars)
    ;; `find-file-name-handler' matches a handler's regexp against the
    ;; name, which is the same regexp engine `string-match' reads.
    (only (schemacs editor search) string-match)
    ;; `default-directory' is what a name with no directory of its own is
    ;; expanded against - a buffer-local variable in Emacs, and so
    ;; `buffer.c''s, which is where it now lives.
    (only (schemacs editor buffer) default-directory)
    )

  (export
   file-system-info
   *file-name-handler-alist*
   *inhibit-file-name-handlers*
   *inhibit-file-name-operation*
   copy-file
   delete-directory-internal
   delete-file-internal
   directory-file-name
   directory-name-p
   expand-file-name
   file-directory-p
   file-exists-p
   file-name-directory-part
   file-name-nondirectory-part
   file-writable-p
   file-executable-p
   file-modes
   file-name-absolute-p
   file-name-as-directory
   file-name-concat
   file-readable-p
   file-regular-p
   file-symlink-p
   find-file-name-handler
   make-directory-internal
   rename-file
   set-file-modes
   substitute-in-file-name
   )

  (begin

    (define (path-segments path)
      ;; PATH's segments, with the empty ones - from a leading or a
      ;; repeated slash - dropped.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (start 0) (acc '()))
        (cond
         ((= i (string-length path))
          (reverse (if (< start i) (cons (substring path start i) acc) acc)))
         ((char=? (string-ref path i) #\/)
          (loop (+ 1 i) (+ 1 i)
                (if (< start i) (cons (substring path start i) acc) acc)))
         (else (loop (+ 1 i) start acc)))))

    (define (join-path-segments segments)
      ;; SEGMENTS joined with a slash between them: the tail of
      ;; `expand-file-name' that puts a resolved path back together.
      ;;--------------------------------------------------------------
      (if (null? segments)
          ""
          (let loop ((rest (cdr segments)) (acc (car segments)))
            (if (null? rest)
                acc
                (loop (cdr rest) (string-append acc "/" (car rest)))))))

    (define (user-homedir name)
      ;; GNU Emacs's `user_homedir' (fileio.c:972): "the home directory
      ;; of the user NAME, or a null pointer if" there is no such user
      ;; or their home is not an absolute name. `getpwnam' is the same
      ;; lookup the C does; the directory is the sixth field of the
      ;; entry it answers.
      ;;--------------------------------------------------------------
      (guard (e (#t #f))
        (let ((entry (getpwnam name)))
          (and entry
               (let ((dir (vector-ref entry 5)))
                 (and dir
                      (< 0 (string-length dir))
                      (char=? #\/ (string-ref dir 0))
                      dir))))))

    (define (get-homedir)
      ;; GNU Emacs's `get_homedir' (fileio.c:1945): the `HOME' this
      ;; process was started with, which is what a bare `~' expands to.
      ;;--------------------------------------------------------------
      (or (getenv "HOME") "/"))

    (define (expand-tilde name)
      ;; GNU Emacs's `Fexpand_file_name''s leading-`~' rule
      ;; (fileio.c:1393): "An initial \"~\" in NAME expands to your
      ;; home directory. An initial \"~USER\" in NAME expands to
      ;; USER's home directory." A `~' that names no user is left
      ;; standing, which is the C's own fallback.
      ;;--------------------------------------------------------------
      (if (or (= 0 (string-length name))
              (not (char=? #\~ (string-ref name 0))))
          name
          (let loop ((i 1))
            (cond
             ((or (= i (string-length name))
                  (char=? #\/ (string-ref name i)))
              (let ((rest (substring name i (string-length name))))
                (if (= i 1)
                    (string-append (get-homedir) rest)
                    (let ((home (user-homedir (substring name 1 i))))
                      (if home (string-append home rest) name)))))
             (else (loop (+ i 1)))))))

    (define %libc (dynamic-link))
    ;; ^ libc itself, dlopened once.

    (define %c-statvfs
      ;; `int statvfs(const char *path, struct statvfs *buf)'
      ;;--------------------------------------------------------------
      (pointer->procedure int
                          (dynamic-func "statvfs" %libc)
                          (list '* '*)))

    (define (file-system-info filename)
      ;; GNU Emacs's `file-system-info' (fileio.c): "Return storage
      ;; information about the file system FILENAME is on. Value is a list
      ;; of numbers (TOTAL FREE AVAIL), where TOTAL is the total size of
      ;; the file system, FREE is the free space in it, and AVAIL is the
      ;; size of the free space available to an unprivileged user. ...
      ;; If the underlying system call fails, value is nil."
      ;;
      ;; The C calls `statvfs' (`lib/fsusage.c':126) and multiplies by the
      ;; *fundamental* block size - `f_frsize' when it is non-zero and
      ;; `f_bsize' otherwise, "f_frsize isn't guaranteed to be supported"
      ;; - which is why offset 8 is read first below and offset 0 only as
      ;; the fallback.
      ;;
      ;; The struct is read at fixed offsets, and those ARE C's `struct
      ;; statvfs' on this platform: `unsigned long' twice and then three
      ;; `fsblkcnt_t', each 8 bytes on x86-64 glibc. That is the one
      ;; fragile thing here and it is named rather than trusted: the
      ;; offsets move on a 32-bit build, where `unsigned long' is 4 bytes.
      ;; Measured against `emacs -Q --batch''s own `file-system-info' on
      ;; the same paths, and against `df -B1'.
      ;;--------------------------------------------------------------
      (let* ((path (expand-file-name filename))
             (buf (make-bytevector 128 0))
             (res (%c-statvfs (string->pointer path)
                              (bytevector->pointer buf))))
        (if (not (= res 0))
            #f
            (let* ((endian (native-endianness))
                   (bsize (bytevector-u64-ref buf 0 endian))   ; f_bsize
                   (frsize (bytevector-u64-ref buf 8 endian))  ; f_frsize
                   (blocks (bytevector-u64-ref buf 16 endian)) ; f_blocks
                   (bfree (bytevector-u64-ref buf 24 endian))  ; f_bfree
                   (bavail (bytevector-u64-ref buf 32 endian)) ; f_bavail
                   (unit (if (zero? frsize) bsize frsize)))
              (list (* unit blocks) (* unit bfree) (* unit bavail))))))

    (define (expand-file-name name . args)
      ;; GNU Emacs's `expand-file-name': NAME as an absolute file name.
      ;; A NAME with no directory of its own - one not starting with a
      ;; slash - is relative to DEFAULT-DIRECTORY, which is the asking
      ;; buffer's own when no other is given; either way the `.` and `..`
      ;; segments are resolved and repeated slashes collapsed.
      ;;
      ;; This is what `read-file-name' answers with, which is why a bare
      ;; name can be typed at the prompt at all: Emacs puts the directory
      ;; *in* the minibuffer, so its answer is absolute already, while
      ;; this editor keeps the prompt beside the buffer rather than in it
      ;; - so what is typed has to be joined to the directory here. A
      ;; name typed in a buffer visiting a file is relative to that
      ;; file's directory, which is what `default-directory' says.
      ;;
      ;; An initial `~' or `~USER' is expanded first, which is the C's
      ;; own order (`Fexpand_file_name' does the home directory before it
      ;; joins anything). Not implemented: the environment-variable,
      ;; wildcard and remote-file syntaxes.
      ;;--------------------------------------------------------------
      (let* ((name (expand-tilde name))
             (default (if (pair? args) (car args) (default-directory)))
             (full (cond
                    ((= 0 (string-length name)) default)
                    ((char=? (string-ref name 0) #\/) name)
                    (else (string-append default name))))
             ;; A trailing slash names a directory and has to survive
             ;; the rebuilding below, which would otherwise drop it.
             ;; An *empty* NAME is the exception, and Emacs's: it expands
             ;; to the directory itself with no trailing slash.
             (directory? (and (< 0 (string-length name))
                              (< 1 (string-length full))
                              (char=? (string-ref full
                                                  (- (string-length full) 1))
                                      #\/))))
        (let resolve ((rest (path-segments full)) (acc '()))
          (cond
           ((null? rest)
            (let ((path (string-append "/" (join-path-segments
                                            (reverse acc)))))
              (cond ((string=? path "/") path)
                    (directory? (string-append path "/"))
                    (else path))))
           ((string=? (car rest) ".") (resolve (cdr rest) acc))
           ;; a `..' takes back the segment before it, and does nothing
           ;; at the root, which is what Emacs does with one
           ((string=? (car rest) "..")
            (resolve (cdr rest) (if (null? acc) acc (cdr acc))))
           (else (resolve (cdr rest) (cons (car rest) acc)))))))

    (define (file-name-directory-part name)
      ;; The directory part of NAME, including the final slash, or "" for
      ;; a bare name: GNU Emacs's `file-name-directory' as we need it.
      ;;--------------------------------------------------------------
      (let ((slash (string-rindex name #\/)))
        (if slash (substring name 0 (+ 1 slash)) "")))

    (define (file-name-nondirectory-part name)
      ;; The part of NAME after the last slash: GNU Emacs's
      ;; `file-name-nondirectory'.
      ;;--------------------------------------------------------------
      (let ((slash (string-rindex name #\/)))
        (if slash (substring name (+ 1 slash) (string-length name)) name)))

    (define (directory-name-p name)
      ;; GNU Emacs's `directory-name-p' (fileio.c:703): whether NAME
      ;; ends with a directory separator - "for example `usr/' and
      ;; `usr' are both directories, but only `usr/' is a directory
      ;; name". It is what `write-file' asks of the name the user gave,
      ;; since a name that ends in a slash names a directory and the
      ;; file gets the buffer's own base name in it.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length name))
           (char=? (string-ref name (- (string-length name) 1)) #\/)))

    (define (file-writable-p path)
      ;; GNU Emacs's `file-writable-p' (fileio.c): "t if you can write
      ;; to file or directory PATH". A file that does not exist is
      ;; writable when its directory is, which is Emacs's rule and the
      ;; one `write-file' works from - a buffer made writable by the
      ;; file it now visits.
      ;;--------------------------------------------------------------
      (if (file-exists-p path)
          (access? path W_OK)
          (let ((dir (file-name-directory-part path)))
            (access? (if (string=? dir "") "." dir) W_OK))))

    (define (file-exists-p path)
      ;; GNU Emacs's `file-exists-p': whether PATH names something that
      ;; exists. Emacs's is true of a directory as well as of a file, and
      ;; so is this.
      ;;
      ;; `guard', not `with-exception-handler': the exception `stat'
      ;; raises is *non-continuable*, and a handler that returns from one
      ;; of those re-raises it - so the `with-exception-handler' spelling
      ;; this started as answered nothing at all and let the error out.
      ;;--------------------------------------------------------------
      (guard (e (else #f))
        (stat path)
        #t))

    ;;----------------------------------------------------------------
    ;; File name handlers
    ;;
    ;; The hook every function below asks before it does anything, which
    ;; is what makes a name that is not a path on this machine work -
    ;; TRAMP's `/ssh:host:/path', `jka-compr''s transparent `.gz',
    ;; archive entries. Emacs has no SSH code in it: a handler is
    ;; *registered* and the primitives hand the name to it. No handler is
    ;; registered here, so nothing is handled - but the question is
    ;; asked, which is the difference between "no remote files" and "this
    ;; primitive cannot".
    ;;------------------------------------------------------------------

    (define *file-name-handler-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `file-name-handler-alist': "Alist of handler
    ;; functions for special file name constructs. Each element looks
    ;; like (REGEXP . HANDLER)."

    (define *inhibit-file-name-handlers* (make-parameter '()))
    (define *inhibit-file-name-operation* (make-parameter #f))
    ;; ^ GNU Emacs's two: the handlers and the operation for which they
    ;; are skipped, which is how a handler calls the standard function
    ;; without calling itself.

    (define (find-file-name-handler filename operation)
      ;; GNU Emacs's `find-file-name-handler' (fileio.c:370): "Return
      ;; FILENAME's handler function for OPERATION, if it has one.
      ;; Otherwise, return nil. A file name is handled if one of the
      ;; regular expressions in `file-name-handler-alist' matches it."
      ;;
      ;; The match that reaches *furthest right* wins - the C keeps the
      ;; largest `match_pos', not the first - which is how a handler for
      ;; the tail of a name (`jka-compr''s `.gz', an archive entry) is
      ;; preferred to one for its head.
      ;;
      ;; Not ported: the `operations' property on the handler symbol,
      ;; which lets a handler declare which operations it serves. There
      ;; are no symbol properties here, so a handler is asked for
      ;; everything.
      ;;--------------------------------------------------------------
      (if (not (string? filename))
          #f
          (let ((inhibited (if (eq? operation
                                    (*inhibit-file-name-operation*))
                               (*inhibit-file-name-handlers*)
                               '())))
            (let loop ((chain (*file-name-handler-alist*))
                       (result #f) (pos -1))
              (cond
               ((null? chain) result)
               ((not (pair? (car chain))) (loop (cdr chain) result pos))
               (else
                (let* ((elt (car chain))
                       (regexp (car elt))
                       (handler (cdr elt))
                       (at (and (string? regexp)
                                (guard (e (#t #f))
                                  (string-match regexp filename)))))
                  (if (and at (> at pos) (not (memq handler inhibited)))
                      (loop (cdr chain) handler at)
                      (loop (cdr chain) result pos)))))))))

    ;;----------------------------------------------------------------
    ;; Asking about a file
    ;;------------------------------------------------------------------

    (define (file-readable-p filename)
      ;; GNU Emacs's `file-readable-p' (fileio.c:3032): "Return t if
      ;; file FILENAME exists and you can read it."
      ;;
      ;; The C's `check_file_access (filename, Qfile_readable_p, R_OK)',
      ;; which is `access' and nothing else.
      ;;--------------------------------------------------------------
      (access? (expand-file-name filename) R_OK))

    (define (file-executable-p filename)
      ;; GNU Emacs's `file-executable-p' (fileio.c:3022): "Return t if
      ;; FILENAME can be executed by you. For a directory, this means you
      ;; can access files in that directory."
      ;;--------------------------------------------------------------
      (access? (expand-file-name filename) X_OK))

    (define (file-symlink-p filename)
      ;; GNU Emacs's `file-symlink-p' (fileio.c:3162): "Return non-nil if
      ;; file FILENAME is the name of a symbolic link. The value is the
      ;; link target, as a string." It "does not check whether the link
      ;; target exists", and a name that is not a link answers nil -
      ;; `readlink' fails for one, which is that nil.
      ;;--------------------------------------------------------------
      (let ((name (expand-file-name filename)))
        (guard (e (#t #f)) (readlink name))))

    (define (file-directory-p filename)
      ;; GNU Emacs's `file-directory-p' (fileio.c:3185): "Return t if
      ;; FILENAME names an existing directory." A symlink to a directory
      ;; counts as one, which is why this is `stat' and not `lstat'.
      ;;
      ;; The empty string answers t: "As a special case, this function
      ;; will also return t if FILENAME is the empty string ... Emacs
      ;; interpret[ing] the empty string (in some cases) as the current
      ;; directory."
      ;;--------------------------------------------------------------
      (if (= 0 (string-length filename))
          #t
          (let ((name (expand-file-name filename)))
            (guard (e (#t #f))
              (eq? 'directory (stat:type (stat name)))))))

    (define (file-regular-p filename)
      ;; GNU Emacs's `file-regular-p' (fileio.c:3359): "Return t if
      ;; FILENAME names a regular file. This is the sort of file that
      ;; holds an ordinary stream of data bytes." A symlink to a regular
      ;; file counts as one.
      ;;--------------------------------------------------------------
      (let ((name (expand-file-name filename)))
        (guard (e (#t #f))
          (eq? 'regular (stat:type (stat name))))))

    ;;----------------------------------------------------------------
    ;; The mode bits
    ;;------------------------------------------------------------------

    (define (file-modes filename . rest)
      ;; GNU Emacs's `file-modes' (fileio.c:3644): "Return mode bits of
      ;; file named FILENAME, as an integer. Return nil if FILENAME does
      ;; not exist. If optional FLAG is `nofollow', do not follow
      ;; FILENAME if it is a symbolic link."
      ;;
      ;; The C keeps `st_mode & 07777' - the permission and setuid/setgid
      ;; bits, without the file type - which is what the 12 low bits are.
      ;;--------------------------------------------------------------
      (let ((nofollow (and (pair? rest) (eq? 'nofollow (car rest))))
            (name (expand-file-name filename)))
        (guard (e (#t #f))
          (logand (stat:mode ((if nofollow lstat stat) name)) #o7777))))

    (define (set-file-modes filename mode . rest)
      ;; GNU Emacs's `set-file-modes' (fileio.c:3666): "Set mode bits of
      ;; file named FILENAME to MODE (an integer). Only the 12 low bits
      ;; of MODE are used."
      ;;
      ;; The C reports "Doing chmod" on failure; `chmod' signals by
      ;; itself here, which the command loop reports the same way.
      ;;--------------------------------------------------------------
      (chmod (expand-file-name filename) (logand mode #o7777)))

    ;;----------------------------------------------------------------
    ;; Naming
    ;;------------------------------------------------------------------

    (define (file-name-as-directory file)
      ;; GNU Emacs's `file-name-as-directory' (fileio.c:634): "Return a
      ;; string representing the file name FILE interpreted as a
      ;; directory. ... For a Unix-syntax file name, just appends a slash
      ;; unless a trailing slash is already present."
      ;;--------------------------------------------------------------
      (if (or (= 0 (string-length file))
              (char=? #\/ (string-ref file (- (string-length file) 1))))
          file
          (string-append file "/")))

    (define (directory-file-name directory)
      ;; GNU Emacs's `directory-file-name' (fileio.c:727): "Returns the
      ;; file name of the directory named DIRECTORY. This is the name of
      ;; the file that holds the data for the directory DIRECTORY."
      ;;
      ;; The slash comes off, except that the root keeps its own - the
      ;; C stops at "the last slash that is not the first character".
      ;;--------------------------------------------------------------
      (let loop ((end (string-length directory)))
        (if (and (> end 1)
                 (char=? #\/ (string-ref directory (- end 1))))
            (loop (- end 1))
            (substring directory 0 end))))

    (define (file-name-absolute-p filename)
      ;; GNU Emacs's `file-name-absolute-p' (fileio.c:2967): "Return t if
      ;; FILENAME is an absolute file name. On Unix, absolute file names
      ;; start with `/'. In Emacs, an absolute file name can also start
      ;; with an initial `~' or `~USER' component, where USER is a valid
      ;; login name."
      ;;
      ;; The C's `file_name_absolute_p' (fileio.c:2979) asks three things
      ;; of a leading `~': that the name ends there, that a slash follows
      ;; it, or that a user of that name exists. The answer is `t' or
      ;; nil - and `user_homedir' answers the *directory* it found, so
      ;; each of those tests is wrapped to turn it into the boolean.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length filename))
           (or (char=? #\/ (string-ref filename 0))
               (and (char=? #\~ (string-ref filename 0))
                    (or (= 1 (string-length filename))
                        (char=? #\/ (string-ref filename 1))
                        (let loop ((i 1))
                          (cond ((>= i (string-length filename))
                                 (and (user-homedir (substring filename 1 i))
                                      #t))
                                ((char=? #\/ (string-ref filename i))
                                 (and (user-homedir (substring filename 1 i))
                                      #t))
                                (else (loop (+ i 1))))))))))

    (define (file-name-concat directory . components)
      ;; GNU Emacs's `file-name-concat' (fileio.c:846): "Append
      ;; COMPONENTS to DIRECTORY and return the resulting string. Each
      ;; element in COMPONENTS must be a string or nil. DIRECTORY or the
      ;; non-final elements in COMPONENTS may or may not end with a
      ;; slash -- if they don't end with a slash, a slash will be
      ;; inserted before concatenating."
      ;;
      ;; A nil component is skipped, which is what lets a caller write
      ;; `(file-name-concat dir (and cond "sub") name)'. The C drops
      ;; them before it starts.
      ;;--------------------------------------------------------------
      (let loop ((parts (cons directory components)) (acc ""))
        (if (null? parts)
            acc
            (let ((part (car parts)))
              (if (not part)
                  (loop (cdr parts) acc)
                  (loop (cdr parts)
                        (cond ((= 0 (string-length acc)) part)
                              ((char=? #\/ (string-ref acc
                                                      (- (string-length acc) 1)))
                               (string-append acc part))
                              (else (string-append acc "/" part)))))))))

    (define (search-embedded-absfilename name)
      ;; GNU Emacs's `search_embedded_absfilename' (fileio.c:2033): the
      ;; index of the first `/` that is followed by what begins an
      ;; absolute file name - another `/', or a `~' - or #f when there
      ;; is none. The C starts at the second character, because the
      ;; first has nothing before it to be a slash.
      ;;--------------------------------------------------------------
      (let loop ((i 1))
        (cond ((>= i (string-length name)) #f)
              ((and (char=? #\/ (string-ref name (- i 1)))
                    (file-name-absolute-p (substring name i (string-length name))))
               i)
              (else (loop (+ i 1))))))

    (define (substitute-in-file-name filename)
      ;; GNU Emacs's `substitute-in-file-name' (fileio.c:2046):
      ;; "Substitute environment variables referred to in FILENAME. ...
      ;; If FOO is not defined in the environment, `$FOO' is left
      ;; unchanged in the value of this function. If `/~' appears, all of
      ;; FILENAME through that `/' is discarded. If `//' appears,
      ;; everything up to and including the first of those `/' is
      ;; discarded."
      ;;
      ;; The C does it in two passes, and the two differ. Before the
      ;; variables are substituted it *starts over* on the rest of the
      ;; name, which its own comment explains is important for a name
      ;; like "/home/foo//:/hello///there"; after them it walks on to the
      ;; last such place instead, because starting over would need the
      ;; dollars quoted first. Both are copied as they stand.
      ;;--------------------------------------------------------------
      (let ((at (search-embedded-absfilename filename)))
        (if at
            (substitute-in-file-name
             (substring filename at (string-length filename)))
            ;; `substitute-env-in-file-name' on Unix is
            ;; `substitute-env-vars' with WHEN-UNDEFINED true, which is
            ;; what leaves an undefined `$FOO' standing.
            (let ((substituted (substitute-env-vars filename #t)))
              (if (string=? substituted filename)
                  filename
                  (let loop ((from substituted))
                    (let ((p (search-embedded-absfilename from)))
                      (if p
                          (loop (substring from p (string-length from)))
                          from))))))))

    ;;----------------------------------------------------------------
    ;; Changing what is on disk
    ;;------------------------------------------------------------------

    (define (make-directory-internal directory)
      ;; GNU Emacs's `make-directory-internal' (fileio.c:2562): "Create a
      ;; new directory named DIRECTORY." The C's mode is
      ;; `0777 & ~auto_saving_dir_umask' - the umask comes off, so what
      ;; is asked for is 0777 and the system applies the rest.
      ;;--------------------------------------------------------------
      (mkdir (expand-file-name directory) #o777))

    (define (delete-directory-internal directory)
      ;; GNU Emacs's `delete-directory-internal' (fileio.c:2583): remove
      ;; DIRECTORY itself. The C's is `rmdir', so a directory with
      ;; anything in it is an error rather than a recursive delete -
      ;; `delete-directory' (`files.el') is the recursive one.
      ;;--------------------------------------------------------------
      (rmdir (expand-file-name directory)))

    (define (delete-file-internal filename)
      ;; GNU Emacs's `delete-file-internal' (fileio.c:2602): "Delete file
      ;; named FILENAME; internal use only. If it is a symlink, remove
      ;; the symlink."
      ;;
      ;; A file that is not there is not an error - the C ignores ENOENT
      ;; and reports every other failure - which is what makes
      ;; `delete-file' safe to call twice.
      ;;--------------------------------------------------------------
      (guard (e (#t #f)) (delete-file (expand-file-name filename))))

    (define (rename-file file newname . rest)
      ;; GNU Emacs's `rename-file' (fileio.c:2724): "Rename FILE as
      ;; NEWNAME. Both args must be strings. If NEWNAME is a directory
      ;; name, rename FILE to a like-named file under NEWNAME. For
      ;; NEWNAME to be recognized as a directory name, it should end in a
      ;; slash."
      ;;
      ;; "Signal a `file-already-exists' error if a file NEWNAME already
      ;; exists unless optional third argument OK-IF-ALREADY-EXISTS is
      ;; non-nil." A non-nil integer asks the user, which is the
      ;; interactive path and is not ported; anything else non-nil
      ;; overwrites, which is what `rename-file' itself does.
      ;;--------------------------------------------------------------
      (let ((ok (and (pair? rest) (car rest))))
        (when (and (not ok) (file-exists-p newname))
          (error "Renaming: file already exists" newname))
        (rename-file-internal (expand-file-name file) newname)))

    (define (rename-file-internal file newname)
      ;; The rename itself, once the already-exists question is settled.
      ;; A NEWNAME that names a directory - one ending in a slash - takes
      ;; the file under it, which is the C's rule and the docstring's.
      ;;--------------------------------------------------------------
      (let ((newname (if (and (< 0 (string-length newname))
                               (char=? #\/ (string-ref newname
                                                       (- (string-length newname) 1))))
                         (string-append newname
                                        (let loop ((i (- (string-length file) 1)))
                                          (if (or (< i 0)
                                                  (char=? #\/ (string-ref file i)))
                                              (substring file (+ i 1) (string-length file))
                                              (loop (- i 1)))))
                         newname)))
        (%rename-file (expand-file-name file) (expand-file-name newname))))

    (define (copy-file file newname . rest)
      ;; GNU Emacs's `copy-file' (fileio.c:2252): "Copy FILE to NEWNAME.
      ;; Both args must be strings. If NEWNAME is a directory name, copy
      ;; FILE to a like-named file under NEWNAME."
      ;;
      ;; "This function always sets the file modes of the output file to
      ;; match the input file", which `copy-file' does by itself. The
      ;; C's optional OK-IF-ALREADY-EXISTS and KEEP-TIME are taken and
      ;; not honoured: there are no file times to keep here, and the
      ;; overwrite question is the caller's.
      ;;--------------------------------------------------------------
      (let ((newname (if (and (< 0 (string-length newname))
                               (char=? #\/ (string-ref newname
                                                       (- (string-length newname) 1))))
                         (string-append newname
                                        (let loop ((i (- (string-length file) 1)))
                                          (if (or (< i 0)
                                                  (char=? #\/ (string-ref file i)))
                                              (substring file (+ i 1) (string-length file))
                                              (loop (- i 1)))))
                         newname)))
        (%copy-file (expand-file-name file) (expand-file-name newname))))

    ))
