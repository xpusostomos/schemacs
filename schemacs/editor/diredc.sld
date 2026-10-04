(define-library (schemacs editor diredc)
  ;; This library mirrors the part of GNU Emacs's `src/dired.c' that the
  ;; listing is built on: `file-attributes' and the accessors over it,
  ;; `directory-files' and `directory-files-and-attributes'. The file is
  ;; called `dired.c' in Emacs and holds no dired commands at all - the
  ;; mode is `lisp/dired.el', which is `(schemacs editor dired)' beside
  ;; this library.
  ;;
  ;; The name is `diredc' and not `dired' because Emacs has *both*
  ;; `src/dired.c' and `lisp/dired.el', which would want the same file
  ;; name here; the elisp half keeps the plain name, as `minibuffer.sld'
  ;; keeps it against `minibuf.sld'. A library importing only the file
  ;; primitives should say `(schemacs editor diredc)'.
  ;;
  ;; `file-attributes' is where the work is. Guile answers a `stat' with
  ;; raw numbers; Emacs answers a *twelve-element list* whose parts have
  ;; shapes of their own, and everything downstream reads those shapes:
  ;; `ls-lisp' formats them, dired puts them in the listing and sorts by
  ;; them. Measured against `emacs -Q --batch' on this machine:
  ;;
  ;;   type=nil nlink=1 uid=0 gid=0
  ;;   atime=(27327 65287 111943 974000)
  ;;   size=13 modes="-rw-r--r--" ninth=t ino=299170 dev=32
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * file name handlers - `find-file-name-handler', which every
  ;;     `DEFUN' in the C asks before it does anything.
  ;;   * `file-name-completion' and `file-name-all-completions', which
  ;;     are dired.c's too but which this tree already does its own way
  ;;     in `(schemacs editor files)''s `file-name-completion-table'.
  ;;     Adding a second path would be a duplicate, not a port.
  ;;   * `file-attributes-lessp', the comparison `directory-files''s
  ;;     sorting uses for the newer callers.
  ;;
  ;; One departure is not ours and is named where it is made: Guile
  ;; 3.0.11's `stat:ctimensec' answers the ctime's seconds rather than
  ;; their fractional part, so the status-change time here is right to
  ;; the second and no finer. The cure is outside this tree - storage is
  ;; an opaque smob and the value is not in it - and an FFI `lstat' over
  ;; this platform's `struct stat' would only move the guesswork.

  (import
    (scheme base)
    (scheme char)
    ;; The operating system's answer, and the two lookups that turn a
    ;; uid and a gid into names. `lstat' is what `file-attributes' uses:
    ;; the C's `emacs_fstatat (... AT_SYMLINK_NOFOLLOW)'.
    ;; `sort', `string<?' and the `c...r' accessors the argument handling
    ;; reads; `cadr' and friends are `(guile)''s, as elsewhere in the tree.
    (only (guile)
          ash cadddr caddr cadr cdddr cddddr closedir getgrgid getpwuid logand
          lstat opendir readdir sort string<?
          stat:atime stat:atimensec stat:ctime stat:ctimensec stat:dev
          stat:gid stat:ino stat:mode stat:mtime stat:mtimensec stat:nlink
          stat:size stat:type stat:uid)
    (only (schemacs editor fileio)
          expand-file-name file-name-as-directory file-symlink-p)
    ;; the `(HIGH LOW USEC PSEC)' shape `file-attributes' answers a time
    ;; in - `make_lisp_time' is timefns.c's, and lives there
    (only (schemacs editor timefns) make-lisp-time)
    ;; the same regexp engine `string-match' reads
    (only (schemacs editor search) string-match)
    )

  (export
   *completion-ignored-extensions*
   directory-files
   directory-files-and-attributes
   file-attribute-access-time
   file-attribute-device-number
   file-attribute-group-id
   file-attribute-inode-number
   file-attribute-link-number
   file-attribute-modes
   file-attribute-modification-time
   file-attribute-size
   file-attribute-status-change-time
   file-attribute-type
   file-attribute-user-id
   file-attributes
   file-modes-string
   )

  (begin

    (define *completion-ignored-extensions*
      (make-parameter
       (list ".o" "~" ".bin" ".lbin" ".so" ".a" ".ln" ".blg" ".bbl" ".elc" ".lof" ".glo" ".idx" ".lot" ".svn/" ".hg/" ".git/" ".bzr/" "CVS/" "_darcs/" "_MTN" ".fmt" ".tfm" ".class" ".fas" ".lib" ".mem" ".x86f" ".sparcf" ".dfsl" ".pfsl" ".d64fsl" ".p64fsl" ".lx64fsl" ".lx32fsl" ".dx64fsl" ".dx32fsl" ".fx64fsl" ".fx32fsl" ".sx64fsl" ".sx32fsl" ".wx64fsl" ".wx32fsl" ".fasl" ".ufsl" ".fsl" ".dxl" ".lo" ".la" ".gmo" ".mo" ".toc" ".aux" ".cp" ".fn" ".ky" ".pg" ".tp" ".vr" ".cps" ".fns" ".kys" ".pgs" ".tps" ".vrs" ".pyc" ".pyo")))
    ;; ^ GNU Emacs's `completion-ignored-extensions' (`dired.c':1206), a
    ;; C variable: "Completion ignores file names ending in any string in
    ;; this list." The C's own default is nil; the list above is the one
    ;; Emacs 31 has at run time, taken from it rather than retyped - it is
    ;; what `dired-font-lock-keywords' builds the `dired-ignored' pattern
    ;; from.


    ;;----------------------------------------------------------------
    ;; The shape of `file-attributes''
    ;;------------------------------------------------------------------

    (define (file-modes-string mode)
      ;; The ten characters `file-attributes'' eighth element is - GNU
      ;; Emacs's `filemodestring' (`lib/filemode.c':154), whose rules are
      ;; `strmode''s (`:82'): the file type, then read, write and execute
      ;; for the owner, the group and everyone else.
      ;;
      ;; Two bits are written as a letter rather than as themselves:
      ;; `setuid' and `setgid' stand where the execute bit is, as `s'
      ;; when it is set and `S' when it is not, and the sticky bit
      ;; likewise as `t' or `T'.
      ;;--------------------------------------------------------------
      (let ((r? (not (= 0 (logand mode #o400))))
            (w? (not (= 0 (logand mode #o200))))
            (x? (not (= 0 (logand mode #o100))))
            (gr? (not (= 0 (logand mode #o040))))
            (gw? (not (= 0 (logand mode #o020))))
            (gx? (not (= 0 (logand mode #o010))))
            (or? (not (= 0 (logand mode #o004))))
            (ow? (not (= 0 (logand mode #o002))))
            (ox? (not (= 0 (logand mode #o001)))))
        (string
         ;; `ftypelet' (`:43'), in the C's own order: the two common ones
         ;; first, then the ones POSIX standardised.
         (case (logand mode #o170000)
           ((#o100000) #\-)             ; regular
           ((#o040000) #\d)             ; directory
           ((#o060000) #\b)             ; block device
           ((#o020000) #\c)             ; character device
           ((#o120000) #\l)             ; symbolic link
           ((#o010000) #\p)             ; fifo
           ((#o140000) #\s)             ; socket
           (else #\?))
         (if r? #\r #\-)
         (if w? #\w #\-)
         (if (not (= 0 (logand mode #o4000)))    ; setuid
             (if x? #\s #\S)
             (if x? #\x #\-))
         (if gr? #\r #\-)
         (if gw? #\w #\-)
         (if (not (= 0 (logand mode #o2000)))    ; setgid
             (if gx? #\s #\S)
             (if gx? #\x #\-))
         (if or? #\r #\-)
         (if ow? #\w #\-)
         (if (not (= 0 (logand mode #o1000)))    ; sticky
             (if ox? #\t #\T)
             (if ox? #\x #\-)))))

    (define (id-name lookup id)
      ;; The name a uid or a gid stands for, or #f when there is no such
      ;; entry - which is when the C answers the number instead.
      ;;--------------------------------------------------------------
      (guard (e (#t #f))
        (let ((entry (lookup id)))
          (and entry
               (let ((name (vector-ref entry 0)))
                 (and (string? name) (< 0 (string-length name)) name))))))

    (define (id-as-name? id-format)
      ;; The C's test: "only pass the extra arg if it is used" - a uid
      ;; is looked up when ID-FORMAT is neither nil nor `integer'.
      ;;--------------------------------------------------------------
      (and id-format (not (eq? id-format 'integer))))

    (define (file-attributes filename . rest)
      ;; GNU Emacs's `file-attributes' (`dired.c':953): "Return a list of
      ;; attributes of file FILENAME. Value is nil if specified file does
      ;; not exist."
      ;;
      ;; The twelve elements are the C's `CALLN (Flist, ...)'
      ;; (`dired.c':1113), in the C's order. The type is read with
      ;; `lstat' - "AT_SYMLINK_NOFOLLOW" - so a symlink answers its
      ;; *target* rather than what it points at.
      ;;--------------------------------------------------------------
      (let* ((id-format (if (pair? rest) (car rest) #f))
             (name (expand-file-name filename))
             (st (guard (e (#t #f)) (lstat name))))
        (if (not st)
            #f
            (let ((mode (stat:mode st))
                  (type (stat:type st)))
              (list
               ;; 0. "t for directory, string (name linked to) for
               ;; symbolic link, or nil"
               (cond ((eq? type 'symlink) (file-symlink-p name))
                     ((eq? type 'directory) #t)
                     (else #f))
               ;; 1. "Number of links to file."
               (stat:nlink st)
               ;; 2. "File uid as a string or (if ID-FORMAT is `integer'
               ;; or a string value cannot be looked up) as an integer."
               (if (id-as-name? id-format)
                   (or (id-name getpwuid (stat:uid st)) (stat:uid st))
                   (stat:uid st))
               ;; 3. "File gid, likewise."
               (if (id-as-name? id-format)
                   (or (id-name getgrgid (stat:gid st)) (stat:gid st))
                   (stat:gid st))
               ;; 4, 5, 6. "Last access time", "Last modification time",
               ;; "Last status change time", "in the style of
               ;; `current-time'".
               (make-lisp-time (stat:atime st) (stat:atimensec st))
               (make-lisp-time (stat:mtime st) (stat:mtimensec st))
               ;; `stat:ctimensec' is BROKEN in Guile 3.0.11: it returns
               ;; the ctime's *seconds*, not their fractional part, and
               ;; the real one is not reachable - the object is an
               ;; opaque smob, not a struct. Measured on this machine:
               ;; coreutils' `stat -c %z' says 2026-10-03
               ;; 19:31:12.683744438 for /tmp/cttest and Emacs's
               ;; `file-attributes' agrees, while `(stat:ctimensec)'
               ;; answers 1791030672, which is `(stat:ctime)'. The
               ;; sub-second part is therefore zero here, and the ctime
               ;; is right to the second. `-c' in a listing sorts on it,
               ;; so two files whose ctimes differ only below the second
               ;; can come out in the other order.
               (make-lisp-time (stat:ctime st) 0)
               ;; 7. "Size in bytes, as an integer."
               (stat:size st)
               ;; 8. "File modes, as a string of ten letters or dashes
               ;; as in ls -l."
               (file-modes-string mode)
               ;; 9. "An unspecified value, present only for backward
               ;; compatibility" - the C passes `Qt'.
               #t
               ;; 10. "inode number, as a nonnegative integer."
               (stat:ino st)
               ;; 11. "Filesystem device identifier".
               (stat:dev st))))))

    (define (file-attribute-type attributes) (list-ref attributes 0))
    (define (file-attribute-link-number attributes) (list-ref attributes 1))
    (define (file-attribute-user-id attributes) (list-ref attributes 2))
    (define (file-attribute-group-id attributes) (list-ref attributes 3))
    (define (file-attribute-access-time attributes) (list-ref attributes 4))
    (define (file-attribute-modification-time attributes) (list-ref attributes 5))
    (define (file-attribute-status-change-time attributes) (list-ref attributes 6))
    (define (file-attribute-size attributes) (list-ref attributes 7))
    (define (file-attribute-modes attributes) (list-ref attributes 8))
    (define (file-attribute-inode-number attributes) (list-ref attributes 10))
    (define (file-attribute-device-number attributes) (list-ref attributes 11))

    ;;----------------------------------------------------------------
    ;; Reading a directory
    ;;------------------------------------------------------------------

    (define (directory-names directory)
      ;; Every entry of DIRECTORY as `readdir' gives them, `.` and `..`
      ;; included - which is what Emacs's `directory-files' answers and
      ;; what this tree's `(schemacs editor files)''s `directory-entries'
      ;; deliberately does not, that one being for completion.
      ;;--------------------------------------------------------------
      (let ((port (opendir directory)))
        (if (not port)
            (error "Opening directory" directory)
            (let loop ((acc '()))
              (let ((entry (readdir port)))
                (cond ((eof-object? entry) (closedir port) (reverse acc))
                      (else (loop (cons entry acc)))))))))

    (define (directory-files directory . rest)
      ;; GNU Emacs's `directory-files' (`dired.c':379): "Return a list of
      ;; names of files in DIRECTORY."
      ;;
      ;; FULL makes the names absolute; MATCH keeps only the names whose
      ;; non-directory part matches a regexp; NOSORT leaves the order
      ;; alone; and COUNT stops after that many names - *before* the
      ;; sort, which is why `(directory-files "/tmp" nil nil nil 3)' need
      ;; not answer the three alphabetically first.
      ;;--------------------------------------------------------------
      (let* ((full (and (pair? rest) (car rest)))
             (match (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (nosort (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                          (caddr rest)))
             (count (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                         (pair? (cdddr rest)) (cadddr rest)))
             (dir (file-name-as-directory (expand-file-name directory)))
             (names (directory-names dir))
             (keep (let loop ((rest names) (acc '()))
                     (cond ((null? rest) (reverse acc))
                           ((and count (integer? count) (<= count (length acc)))
                            (reverse acc))
                           ((and match (not (string-match match (car rest))))
                            (loop (cdr rest) acc))
                           (else (loop (cdr rest) (cons (car rest) acc))))))
             (out (if full
                      (map (lambda (n) (string-append dir n)) keep)
                      keep)))
        ;; NOSORT answers the order the *C* keeps, which is not the
        ;; order `readdir' gives: `directory_files_internal' conses each
        ;; entry onto the front as it reads it (dired.c:351) and returns
        ;; that list untouched when NOSORT is non-nil - the
        ;; `Fnreverse' only happens on the way into the sort
        ;; (dired.c:367). So an unsorted `directory-files' answers the
        ;; entries in *reverse* readdir order, and `.` and `..` come
        ;; last. Measured: `(directory-files DIR nil nil t)' starts with
        ;; the most recently created entry.
        (if nosort (reverse out) (sort out string<?))))

    (define (directory-files-and-attributes directory . rest)
      ;; GNU Emacs's `directory-files-and-attributes' (`dired.c':407):
      ;; "Return a list of names of files and their attributes ... of the
      ;; form ((FILE1 . FILE1-ATTRS) (FILE2 . FILE2-ATTRS) ...)".
      ;;
      ;; The arguments are `directory-files'' with ID-FORMAT inserted
      ;; before COUNT, which is the C's own order.
      ;;--------------------------------------------------------------
      (let* ((full (and (pair? rest) (car rest)))
             (match (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (nosort (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                          (caddr rest)))
             (id-format (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                             (pair? (cdddr rest)) (cadddr rest)))
             (count (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                         (pair? (cdddr rest)) (pair? (cddddr rest))
                         (car (cddddr rest))))
             (dir (file-name-as-directory (expand-file-name directory)))
             (names (apply directory-files directory
                           (list full match nosort count))))
        ;; the attributes are read from the *full* name whatever FULL
        ;; says - which is what the C does, reading each entry with the
        ;; directory's file descriptor - or a relative name would be
        ;; looked up against the process's directory instead
        (map (lambda (name)
               (cons name
                     (file-attributes (if full
                                          name
                                          (string-append dir name))
                                      id-format)))
             names)))

    ))
