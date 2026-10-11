(import
 (scheme base)
 (scheme char)
 (only (guile) getenv)
 (schemacs editor fileio)
 ;; The visited-file time is recorded on a *buffer*, so the tests below
 ;; need one to record it on.
 (only (schemacs editor buffer)
       allocate-buffer with-current-buffer set!buffer-file-name)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

;; fileio.c's tests: the file predicates, the mode bits, and the name
;; arithmetic. These read the real filesystem - /tmp and a file that is
;; certainly there - rather than a fixture, because that is what the
;; functions are about; what is asserted is the *shape* of each answer,
;; not a particular machine's contents.

(test-begin "fileio")

;; ------------------------------------------------------------------
;; the predicates

(test-equal "file-directory-p on a directory" #t (file-directory-p "/tmp"))
(test-equal "file-directory-p on a file" #f (file-directory-p "/etc/hostname"))
(test-equal "file-directory-p on something missing" #f (file-directory-p "/tmp/no-such-entry"))
;; "As a special case, this function will also return t if FILENAME is
;; the empty string" - Emacs reads "" as the current directory.
(test-equal "file-directory-p on the empty string" #t (file-directory-p ""))

(test-equal "file-regular-p on a file" #t (file-regular-p "/etc/hostname"))
(test-equal "file-regular-p on a directory" #f (file-regular-p "/tmp"))
(test-equal "file-regular-p on something missing" #f (file-regular-p "/tmp/no-such-entry"))

;; ------------------------------------------------------------------
;; every predicate expands its argument first
;;
;; The C's `check_file_access' (`fileio.c:2992'), the shared body of
;; `file-exists-p', `file-executable-p' and `file-readable-p', opens with
;; `file = Fexpand_file_name (file, Qnil);', and `file-writable-p' and
;; `file-directory-p' do the same in their own bodies. `file-exists-p' was
;; the one that did not, and nothing noticed while every caller passed an
;; absolute name: with a `~' it answered nil for a file that is there.
;; Every expectation here is Emacs 31.1's - `emacs -Q --batch` answers t,
;; t and nil for these three.

(test-equal "file-exists-p expands a leading ~" #t (file-exists-p "~"))
(test-equal "and a ~ with its slash" #t (file-exists-p "~/"))
(test-equal "and a ~ with a dot" #t (file-exists-p "~/."))
(test-equal "a ~ name that is not there" #f
  (file-exists-p "~/no-such-entry-for-schemacs-tests"))

;; ...and the whole family, so that a `~' cannot come to be a special
;; case that one of them forgets. Emacs's own answers, in order:
;; t t t nil nil nil t (the last is `file-writable-p' - a name that does
;; not exist is writable when its directory is).
(test-equal '(#t #t #t #f #f #f #t)
  (list (file-directory-p "~")
        (file-readable-p "~")
        (file-executable-p "~")
        (file-regular-p "~")
        (file-symlink-p "~")
        (file-exists-p "~/no-such-entry-for-schemacs-tests")
        (file-writable-p "~/no-such-entry-for-schemacs-tests")))

(test-equal "file-readable-p on a file" #t (file-readable-p "/etc/hostname"))
(test-equal "file-readable-p on something missing" #f (file-readable-p "/tmp/no-such-entry"))
(test-equal "file-executable-p on a program" #t (file-executable-p "/bin/sh"))
(test-equal "file-executable-p on a data file" #f (file-executable-p "/etc/hostname"))

;; `file-symlink-p' answers the *target*, so what is asserted is that it
;; is a string at all - the target of /proc/self is this process's pid.
(test-assert "file-symlink-p on a symlink answers a string"
  (string? (file-symlink-p "/proc/self")))
(test-equal "file-symlink-p on a directory" #f (file-symlink-p "/tmp"))
(test-equal "file-symlink-p on something missing" #f (file-symlink-p "/tmp/no-such-entry"))

;; ------------------------------------------------------------------
;; the mode bits

;; /bin/sh is executable by everyone, so its mode ends in 111 - and the
;; point of the test is that `file-modes' keeps the *low twelve* bits and
;; nothing of the file type.
(test-equal "file-modes of /bin/sh" #o755 (file-modes "/bin/sh"))
(test-equal "file-modes of something missing" #f (file-modes "/tmp/no-such-entry"))
(test-assert "file-modes is at most the twelve low bits"
  (< (file-modes "/bin/sh") #o10000))

;; ------------------------------------------------------------------
;; naming

(test-equal "file-name-as-directory adds a slash" "/a/" (file-name-as-directory "/a"))
(test-equal "file-name-as-directory keeps one" "/a/" (file-name-as-directory "/a/"))
;; `file_name_as_directory''s first case, not its last: the empty name is
;; "." as a directory (fileio.c:314), so `(file-name-as-directory "")' is
;; "./" and not "".
(test-equal "file-name-as-directory of the empty string" "./" (file-name-as-directory ""))

(test-equal "directory-file-name drops the slash" "/a/b" (directory-file-name "/a/b/"))
(test-equal "directory-file-name of a bare name" "/a/b" (directory-file-name "/a/b"))
;; the root keeps its own slash
(test-equal "directory-file-name of the root" "/" (directory-file-name "/"))
;; and "//" keeps both, which is the *exception around* the stripping
;; loop (fileio.c:685): "if they are all slashes, leave "/" and "//"
;; alone, and treat "///" and longer as if they were "/"."
(test-equal "directory-file-name of the double root" "//" (directory-file-name "//"))
(test-equal "directory-file-name of three slashes" "/" (directory-file-name "///"))
(test-equal "directory-file-name of four slashes" "/" (directory-file-name "////"))

(test-equal "file-name-absolute-p of an absolute name" #t (file-name-absolute-p "/a"))
(test-equal "file-name-absolute-p of a relative name" #f (file-name-absolute-p "a"))
(test-equal "file-name-absolute-p of a home name" #t (file-name-absolute-p "~/a"))
(test-equal "file-name-absolute-p of the empty string" #f (file-name-absolute-p ""))

(test-equal "file-name-concat joins with a slash" "/a/b/c"
  (file-name-concat "/a" "b" "c"))
(test-equal "file-name-concat does not double a slash" "/a/b/c"
  (file-name-concat "/a/" "b" "c"))
;; a nil component is skipped, which is what lets a caller write
;; `(file-name-concat dir (and cond "sub") name)'
(test-equal "file-name-concat skips nil" "/a/c" (file-name-concat "/a" #f "c"))

;; ------------------------------------------------------------------
;; `~' expansion, and the environment variables

;; `expand-file-name' expands a leading `~' before it joins anything,
;; which is the C's own order (`Fexpand_file_name', fileio.c:1393).
(test-equal "expand-file-name of a bare ~" (or (getenv "HOME") "/")
  (expand-file-name "~"))
(test-equal "expand-file-name of ~/x"
  (string-append (or (getenv "HOME") "/") "/x")
  (expand-file-name "~/x"))
;; `~USER' is that user's home, from the same password lookup the C does
(test-equal "expand-file-name of ~root" "/root" (expand-file-name "~root"))
(test-equal "expand-file-name of ~root/x" "/root/x" (expand-file-name "~root/x"))
;; a `~' naming no user is left standing, the C's own fallback
(test-assert "expand-file-name leaves an unknown user alone"
  (string-suffix? "~nosuchuser/x" (expand-file-name "~nosuchuser/x")))

(test-equal "file-name-absolute-p of ~/a" #t (file-name-absolute-p "~/a"))
(test-equal "file-name-absolute-p of ~root/a" #t (file-name-absolute-p "~root/a"))
(test-equal "file-name-absolute-p of an unknown user" #f
  (file-name-absolute-p "~nosuchuser/a"))

;; A leading "//" survives `expand-file-name', and that is the whole
;; reason its canonicalization is a walk over the name rather than a
;; rebuild from segments: the C collapses repeated slashes "except leave
;; leading '//' alone" (fileio.c:1710), and the test for it is
;; `p != target || IS_DIRECTORY_SEP (p[2])' - so a pair at the very start
;; stays unless a *third* slash follows it. POSIX gives exactly two
;; leading slashes an implementation-defined meaning, which is where a
;; network host goes, so the pair is not a doubled separator.
(test-equal "expand-file-name keeps a leading double slash" "//tmp"
  (expand-file-name "//tmp"))
(test-equal "expand-file-name keeps the double root" "//" (expand-file-name "//"))
(test-equal "expand-file-name keeps the pair, not the run" "//a/b"
  (expand-file-name "//a//b"))
(test-equal "expand-file-name collapses three slashes" "/tmp"
  (expand-file-name "///tmp"))
(test-equal "expand-file-name collapses a doubled separator inside" "/tmp/x"
  (expand-file-name "/tmp//x"))

;; `/..' at the root does nothing - the C's `o != target' guard
;; (fileio.c:1685) - and `..' at the root is "the superroot on certain
;; file systems", so it is kept. A stack of segments pops at the root and
;; loses it.
(test-equal "expand-file-name keeps /.. at the root" "/.." (expand-file-name "/.."))
(test-equal "expand-file-name of /foo/.. is the root" "/"
  (expand-file-name "/foo/.."))
(test-equal "expand-file-name keeps the last .. of /foo/../.." "/.."
  (expand-file-name "/foo/../.."))
(test-equal "expand-file-name of /foo/../bar" "/bar"
  (expand-file-name "/foo/../bar"))
(test-equal "expand-file-name drops a /." "/foo" (expand-file-name "/foo/."))
(test-equal "expand-file-name keeps a trailing /. as the root" "/"
  (expand-file-name "/./"))

;; `substitute-in-file-name' - the variables, and the `/~' and `//'
;; rule that discards what came before
(test-equal "substitute-in-file-name of $HOME/x"
  (string-append (or (getenv "HOME") "/") "/x")
  (substitute-in-file-name "$HOME/x"))
(test-equal "substitute-in-file-name discards before //" "/b"
  (substitute-in-file-name "/a//b"))
;; an undefined variable is left standing, which is what
;; `substitute-env-in-file-name''s WHEN-UNDEFINED does on Unix
(test-equal "substitute-in-file-name leaves an undefined variable" "/a/$nope/b"
  (substitute-in-file-name "/a/$nope/b"))

;; ------------------------------------------------------------------
;; the visited file's modification time
;;
;; Every answer here is Emacs 31.1's, read off `emacs -Q --batch' on
;; files made for the purpose. The point of the whole family is what
;; `record_first_change' (`undo.c:210') writes into the `(t . TIME)' undo
;; mark: undoing back to the mark of the last save makes a buffer
;; unmodified again only while the file still holds the time it held when
;; the mark was made.

(define vf-root "/tmp/schemacs-modtime-test.txt")

(define (vf-write! contents)
  (guard (e (#t #f)) (delete-file vf-root))
  (call-with-output-file vf-root (lambda (p) (display contents p)))
  vf-root)

;; A buffer that visits nothing has recorded no time, and the answer is
;; the *integer* 0 rather than a time. Emacs documents the three answers
;; exactly: "a Lisp timestamp ... if the current buffer has a recorded
;; file modification time, 0 if it doesn't, and -1 if the visited file
;; doesn't exist."
(test-equal "visited-file-modtime with no file" 0
  (with-current-buffer (allocate-buffer) (visited-file-modtime)))

;; A buffer that knows nothing is *believed* rather than doubted - Emacs
;; has not been told anything, so it does not claim the file has moved.
(test-equal "verify-visited-file-modtime with no file" #t
  (with-current-buffer (allocate-buffer) (verify-visited-file-modtime)))

;; The two integer flags, which are the two sentinels a `struct timespec'
;; cannot hold - "no time is known" and "the file is not there" - turned
;; into the two integers the interface documents.
(test-equal "the two sentinels are 0 and -1" '(0 -1 0)
  (with-current-buffer (allocate-buffer)
    (set-visited-file-modtime 0)
    (let ((unknown (visited-file-modtime)))
      (set-visited-file-modtime -1)
      (list unknown (visited-file-modtime)
            (begin (set-visited-file-modtime 0) (visited-file-modtime))))))

;; Any other integer is neither a flag nor a time, and the C range-checks
;; it: `check_integer_range (time_flag, -1, 0)'.
(test-equal "a fixnum outside -1..0 is refused" #t
  (guard (e (#t #t)) (set-visited-file-modtime 5) #f))

;; A recorded time is a real Lisp time, and it is what makes "has the file
;; moved since?" a question with an answer: rewrite the file under the
;; buffer and `verify-visited-file-modtime' says so.
(test-equal "a recorded time notices a file that has changed" '(#t #t #f)
  (let* ((path (vf-write! "abc"))
         (b (allocate-buffer)))
    (set!buffer-file-name b path)
    (with-current-buffer b
      (set-visited-file-modtime)
      (let ((recorded (visited-file-modtime))
            (verified (verify-visited-file-modtime)))
        ;; the file changes underneath, not through the buffer
        (vf-write! "abcdef")
        (list verified (list? recorded) (verify-visited-file-modtime))))))

(guard (e (#t #f)) (delete-file vf-root))

(test-end "fileio")
