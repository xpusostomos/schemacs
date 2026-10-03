(import
 (scheme base)
 (scheme char)
 (only (guile) getenv)
 (schemacs editor fileio)
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
(test-equal "file-name-as-directory of the empty string" "" (file-name-as-directory ""))

(test-equal "directory-file-name drops the slash" "/a/b" (directory-file-name "/a/b/"))
(test-equal "directory-file-name of a bare name" "/a/b" (directory-file-name "/a/b"))
;; the root keeps its own slash
(test-equal "directory-file-name of the root" "/" (directory-file-name "/"))

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

(test-end "fileio")
