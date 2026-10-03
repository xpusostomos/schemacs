(import
 (scheme base)
 (scheme char)
 (only (guile) delete-file mkdir rmdir sort string-prefix? string<?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor buffer)
 (schemacs editor diredc)
 (schemacs editor editfns)
 (schemacs editor files)
 (schemacs editor frame)
 (schemacs editor ls-lisp)
 )

;; ls-lisp.el's tests.
;;
;; The listing itself is checked by driving `ls-lisp--insert-directory'
;; and reading the buffer back, and every expectation in here was taken
;; from what `emacs -Q --batch' prints with
;; `ls-lisp-use-insert-directory-program' nil - the same function on the
;; same tree. `ls -l' is *not* the reference: this is ls-lisp's listing,
;; which is what this editor uses everywhere, and its collation and its
;; switch handling are its own.
;;
;; The times in a listing depend on when it is run, so the tests read the
;; *name column* out of the lines rather than the whole line, and the one
;; test that checks a whole line builds the file attributes by hand.
;; `*system-time-locale*' is pinned to "C" where a format is checked at
;; all, because otherwise the ISO format is chosen instead - see
;; `ls-lisp-format-time', which is Emacs's rule.

(test-begin "schemacs_editor_ls_lisp")

;; ------------------------------------------------------------------
;; the fixture

(define root "/tmp/schemacs-ls-lisp-tests")

(define (fixture!)
  (for-each (lambda (name)
              (guard (e (#t #f)) (delete-file (string-append root name))))
            (list "/b.txt" "/a.txt" "/z.lisp" "/dir/c.txt"))
  (guard (e (#t #f)) (delete-file (string-append root "/dir/c.txt")))
  (guard (e (#t #f)) (rmdir (string-append root "/dir")))
  (guard (e (#t #f)) (rmdir root))
  (guard (e (#t #f)) (mkdir root))
  (guard (e (#t #f)) (mkdir (string-append root "/dir")))
  (call-with-output-file (string-append root "/a.txt")
    (lambda (p) (display "aaa" p)))
  (call-with-output-file (string-append root "/b.txt")
    (lambda (p) (display "bbbbbbbbbb" p)))
  (call-with-output-file (string-append root "/z.lisp")
    (lambda (p) (display "z" p)))
  (call-with-output-file (string-append root "/dir/c.txt")
    (lambda (p) (display "cc" p))))

(fixture!)

(define (listing directory switches . rest)
  ;; The whole listing, as `ls-lisp--insert-directory' puts it in a
  ;; buffer - which is what `insert-directory' does too.
  (let ((buffer (get-buffer-create "*ls-lisp-tests*")))
    (set-buffer buffer)
    (erase-buffer)
    (ls-lisp--insert-directory directory switches
                              (and (pair? rest) (car rest))
                              (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
    (buffer-string)))

(define (names-of text)
  ;; The name column of every line but the `total' one. The name is the
  ;; last field, which is what `ls -l' prints it as.
  (let loop ((lines (let split ((i 0) (start 0) (acc '()))
                      (cond ((>= i (string-length text)) (reverse acc))
                            ((char=? #\newline (string-ref text i))
                             (split (+ i 1) (+ i 1)
                                    (cons (substring text start i) acc)))
                            (else (split (+ i 1) start acc)))))
             (acc '()))
    (cond ((null? lines) (reverse acc))
          ((or (string=? (car lines) "") (string-prefix? "total " (car lines)))
           (loop (cdr lines) acc))
          (else
           (let ((line (car lines)))
             (let last ((i (- (string-length line) 1)))
               (if (and (>= i 0) (not (char=? #\space (string-ref line i))))
                   (last (- i 1))
                   (loop (cdr lines)
                         (cons (substring line (+ i 1) (string-length line))
                               acc)))))))))

;; ------------------------------------------------------------------
;; the switches, on the fixture

;; "Default sorting is alphabetic", and the collation is the locale's -
;; which is what `ls-lisp-string-lessp' is for
(test-equal '("a.txt" "b.txt" "dir" "z.lisp")
  (names-of (listing root "-l" #f #t)))

;; "Finally reverse file alist if necessary"
(test-equal '("z.lisp" "dir" "b.txt" "a.txt")
  (names-of (listing root "-lr" #f #t)))

;; `-U' is unsorted: `ls-lisp-handle-switches' returns "without
;; otherwise changing the ordering". The order is the C's own - which
;; is `directory-files'' order, itself readdir order reversed (see the
;; note in dired.sld) - and this is `emacs -Q --batch' on the same tree.
(test-equal '("dir" "a.txt" "b.txt" "z.lisp")
  (names-of (listing root "-lU" #f #t)))

;; `-S' is "sorted on size. Make largest file come first" - and a
;; directory's size is its own, 4096 here, larger than any of the files
(test-equal '("dir" "b.txt" "a.txt" "z.lisp")
  (names-of (listing root "-lS" #f #t)))

;; `-X' is "sorted on extension", and `ls-lisp-extension''s key forces
;; the order "no ext" then "null ext" then "ext" - so the directory,
;; whose name has no dot at all, comes first. `b.txt' before `a.txt' is
;; not a mistake: the key carries a NUL, and *both* dialects' collation
;; stops at it, so the two are equal and the sort leaves the order it
;; found. `emacs -Q --batch' answers the same list.
(test-equal '("dir" "z.lisp" "b.txt" "a.txt")
  (names-of (listing root "-lX" #f #t)))

;; `-F' is "classify": a directory gets a `/'
(test-equal '("a.txt" "b.txt" "dir/" "z.lisp")
  (names-of (listing root "-lF" #f #t)))

;; `-a' shows `.` and `..'; `-A' shows them too but not as `.`/`..`
;; (which is the same list here), and neither is shown by default
(test-equal '("." ".." "a.txt" "b.txt" "dir" "z.lisp")
  (names-of (listing root "-la" #f #t)))

;; the `total' line, in kilobytes rounded up
(test-assert "the listing starts with a total line"
  (string-prefix? "total " (listing root "-l" #f #t)))

;; an empty match says so, as `ls' does
(test-equal "(No match)\ntotal 0\n"
  (listing (string-append root "/z*.none") "-l" #f #t))

;; ------------------------------------------------------------------
;; the parts that are not the listing

(test-equal "extension sort key: no ext, null ext, then ext"
  (list (string-append "\0\0\0name") (string-append "\0\0name.") (string-append "txt\0name.txt"))
  (list (ls-lisp-extension "name")
        (ls-lisp-extension "name.")
        (ls-lisp-extension "name.txt")))

;; "ignoring any version extension" - the extension is `txt', and the
;; name that follows the NUL is the *whole* name it was given
(test-equal (string-append "txt\0name.txt.~1~")
  (ls-lisp-extension "name.txt.~1~"))

(test-equal "the time switch chooses the attribute"
  '(6 5 4 #f)
  (list (ls-lisp-time-index '(#\c))
        (ls-lisp-time-index '(#\t))
        (ls-lisp-time-index '(#\u))
        (ls-lisp-time-index '(#\l))))

(test-equal "delete-matching keeps what does not match"
  '(("b" 1) ("c" 2))
  (reverse (map (lambda (e) (list (car e) (cdr e)))
                (ls-lisp-delete-matching "^a" '(("a" . 0) ("b" . 1) ("c" . 2))))))

;; "If the \"..\" directory entry has nil attributes, the attributes are
;; copied from the \".\" entry, if they are non-nil. Otherwise, the
;; offending element is removed."
(test-equal '(("." . 1) (".." . 1))
  (ls-lisp-sanitize '(("." . 1) (".." . #f) ("gone" . #f))))

(test-equal '(("." . 1))
  (ls-lisp-sanitize '(("." . 1) ("gone" . #f))))

;; ------------------------------------------------------------------
;; the long format, on attributes built by hand

(define (attr type nlink uid gid size modes)
  (list type nlink uid gid '(0 0 0 0) '(0 0 0 0) '(0 0 0 0) size modes #t 0 0))

;; A time of zero seconds is the 1st of January 1970, which is far
;; outside the six-month window - so `ls-lisp-format-time' uses the
;; second entry of `ls-lisp-format-time-list', and the expectation does
;; not move.
(test-equal "-rw-r--r--  1 1000 1000 5 Jan  1  1970 file.txt\n"
  (parameterize ((*system-time-locale* "C")
                 (*ls-lisp-uid-width* 1)
                 (*ls-lisp-gid-width* 1)
                 (*ls-lisp-size-width* 1))
    (ls-lisp-format "file.txt" (attr #f 1 1000 1000 5 "-rw-r--r--") 5 '() #f)))

;; "is a symbolic link" - the target is appended
(test-equal "-rw-r--r--  1 1000 1000 5 Jan  1  1970 link -> /nowhere\n"
  (parameterize ((*system-time-locale* "C")
                 (*ls-lisp-uid-width* 1)
                 (*ls-lisp-gid-width* 1)
                 (*ls-lisp-size-width* 1))
    (ls-lisp-format "link" (attr "/nowhere" 1 1000 1000 5 "-rw-r--r--") 5 '() #f)))

;; `(memq 'modes ls-lisp-verbosity)' decides between the ten characters
;; and the first four, and `links', `uid' and `gid' the rest
(test-equal "-rw-  1 1000 1000 5 Jan  1  1970 f\n"
  (parameterize ((*ls-lisp-verbosity* '(links uid gid)))
    (parameterize ((*system-time-locale* "C")
                   (*ls-lisp-uid-width* 1)
                   (*ls-lisp-gid-width* 1)
                   (*ls-lisp-size-width* 1))
      (ls-lisp-format "f" (attr #f 1 1000 1000 5 "-rw-r--r--") 5 '() #f))))

;; the `-g' switch asks for the group even when the verbosity hides it
(test-equal "-rw-r--r--  1 1000 1000 5 Jan  1  1970 f\n"
  (parameterize ((*ls-lisp-verbosity* '(modes links uid)))
    (parameterize ((*system-time-locale* "C")
                   (*ls-lisp-uid-width* 1)
                   (*ls-lisp-gid-width* 1)
                   (*ls-lisp-size-width* 1))
      (ls-lisp-format "f" (attr #f 1 1000 1000 5 "-rw-r--r--") 5 '(#\g) #f))))

;; "file-size-human-readable" is files.el's and is handed over by the
;; seam; the width is seven, as the C's `" %7s"'
(test-equal '("      29" "    1.5k" "    1.4M")
  (list (ls-lisp-format-file-size 29 #t)
        (ls-lisp-format-file-size 1500 #t)
        (ls-lisp-format-file-size 1500000 #t)))

;; and not human-readable is the plain number in the width the listing
;; computed for itself, which is the longest size it is about to print
(test-equal '(" 29" " 1500")
  (list (parameterize ((*ls-lisp-size-width* 2))
          (ls-lisp-format-file-size 29 #f))
        (parameterize ((*ls-lisp-size-width* 2))
          (ls-lisp-format-file-size 1500 #f))))

;; ------------------------------------------------------------------
;; the long forms of the switches

;; a known long option becomes its short form in place, and an unknown
;; one is left alone - "Long options not supported by ls-lisp are
;; removed" is done by the `--.*=.*' catch-all, which needs the `='
(test-equal '("-l -F" "-l --no-such-option")
  (list (ls-lisp--sanitize-switches "-l --classify")
        (ls-lisp--sanitize-switches "-l --no-such-option")))

;; the C replaces only the *first* match of each option, and `--sort=size'
;; is taken by the catch-all, not by `--sort.*[ \t]', which wants a space
(test-equal '("-l -a --all" "-l" "-l -t" "-l")
  (list (ls-lisp--sanitize-switches "-l --all --all")
        (ls-lisp--sanitize-switches "-l --version")
        (ls-lisp--sanitize-switches "-l --sort=time")
        (ls-lisp--sanitize-switches "-l --sort=size")))

(test-equal '("-l -A" "-l -a" "-l -r" "-l -R" "-l -s" "-l -i" "-l -n" "-l -h" "-l -G" "-l -F")
  (list (ls-lisp--sanitize-switches "-l --almost-all")
        (ls-lisp--sanitize-switches "-l --all")
        (ls-lisp--sanitize-switches "-l --reverse")
        (ls-lisp--sanitize-switches "-l --recursive")
        (ls-lisp--sanitize-switches "-l --size")
        (ls-lisp--sanitize-switches "-l --inode")
        (ls-lisp--sanitize-switches "-l --numeric-uid-gid")
        (ls-lisp--sanitize-switches "-l --human-readable")
        (ls-lisp--sanitize-switches "-l --no-group")
        (ls-lisp--sanitize-switches "-l --classify")))

;; ------------------------------------------------------------------
;; `insert-directory' - files.el's, which is what dispatches here

;; "Depending on the value of `ls-lisp-use-insert-directory-program'
;; this works either using a Lisp emulation of the \"ls\" program or by
;; running a directory listing program". That value is false here, so
;; the listing is ls-lisp's own - and it is the same listing
;; `ls-lisp--insert-directory' gives, which is the point of the seam.
(test-equal (listing root "-l" #f #t)
  (let ((buffer (get-buffer-create "*insert-directory-tests*")))
    (set-buffer buffer)
    (erase-buffer)
    (insert-directory root "-l" #f #t)
    (buffer-string)))

;; and a single file, which is the branch that does not list a directory
(test-equal (listing (string-append root "/a.txt") "-l" #f #f)
  (let ((buffer (get-buffer-create "*insert-directory-tests*")))
    (set-buffer buffer)
    (erase-buffer)
    (insert-directory (string-append root "/a.txt") "-l" #f #f)
    (buffer-string)))

(test-end "schemacs_editor_ls_lisp")