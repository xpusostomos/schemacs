(import
 (scheme base)
 (scheme char)
 (only (guile) delete-file filter getenv mkdir rmdir symlink)
 (schemacs editor diredc)
 (schemacs editor files)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

;; dired.c's tests, and the files.el wrappers built beside them.
;;
;; `file-attributes' is checked against what `emacs -Q --batch' answers
;; on this machine - the mode *string*, the uid as a *name* when asked
;; for one, the twelve-element shape - rather than against the numbers
;; alone, because the shape is the port's whole job: Guile hands back
;; integers and Emacs hands back a list whose parts have shapes of their
;; own, and everything downstream reads those shapes.
;;
;; The directory tests make their own tree under /tmp, so what they
;; assert does not depend on the rest of the machine.

(test-begin "dired")

;; ------------------------------------------------------------------
;; the fixture

(define root "/tmp/schemacs-dired-tests")

(define (fixture!)
  ;; every step guarded: a run that died partway leaves a tree behind,
  ;; and the next run has to be able to start from it
  (for-each (lambda (name)
              (guard (e (#t #f)) (delete-file (string-append root name))))
            (list "/link" "/sub/b.txt" "/b.txt" "/a.txt"))
  (guard (e (#t #f)) (rmdir (string-append root "/sub")))
  (guard (e (#t #f)) (rmdir root))
  (guard (e (#t #f)) (mkdir root))
  (guard (e (#t #f)) (mkdir (string-append root "/sub")))
  (call-with-output-file (string-append root "/a.txt")
    (lambda (p) (display "a" p)))
  (call-with-output-file (string-append root "/b.txt")
    (lambda (p) (display "bb" p)))
  (call-with-output-file (string-append root "/sub/b.txt")
    (lambda (p) (display "bbb" p))))

(fixture!)

;; ------------------------------------------------------------------
;; file-attributes

(define attrs (file-attributes (string-append root "/a.txt")))

(test-equal "file-attributes: a regular file's type is nil" #f
  (file-attribute-type attrs))
(test-equal "file-attributes: one link" 1
  (file-attribute-link-number attrs))
(test-equal "file-attributes: the size in bytes" 1
  (file-attribute-size attrs))
;; "File modes, as a string of ten letters or dashes as in ls -l."
(test-equal "file-attributes: the mode as a string" "-rw-r--r--"
  (file-attribute-modes attrs))
;; a time in `current-time' style: `(HIGH LOW USEC PSEC)'
(test-equal "file-attributes: a time is a four-element list" 4
  (length (file-attribute-modification-time attrs)))
(test-assert "file-attributes: the inode and device are numbers"
  (and (integer? (file-attribute-inode-number attrs))
       (integer? (file-attribute-device-number attrs))))

(test-equal "file-attributes: a directory's type is t" #t
  (file-attribute-type (file-attributes root)))
(test-equal "file-attributes: a missing file is nil" #f
  (file-attributes (string-append root "/no-such-file")))

;; ID-FORMAT: "valid values are `string' and `integer'. The latter is
;; the default" - so the uid is a *name* only when asked for one.
(test-equal "file-attributes: uid is a number by default" #t
  (integer? (file-attribute-user-id attrs)))
(test-equal "file-attributes: and a name when asked" (getenv "USER")
  (file-attribute-user-id (file-attributes (string-append root "/a.txt")
                                           'string)))

;; a symlink answers its *target*, not what it points at - which is what
;; `lstat' being the C's lookup means
(catch #t (lambda () (delete-file (string-append root "/link"))) (lambda e #f))
(guard (e (#t #f)) (symlink "/nowhere-at-all" (string-append root "/link")))
(test-equal "file-attributes: a symlink answers its target" "/nowhere-at-all"
  (file-attribute-type (file-attributes (string-append root "/link"))))
;; taken away again, or the directory tests below would count it
(guard (e (#t #f)) (delete-file (string-append root "/link")))

;; ------------------------------------------------------------------
;; directory-files

;; "." and ".." are in it, as Emacs's are, and it is sorted
(test-equal "directory-files: sorted, with . and .."
  '("." ".." "a.txt" "b.txt" "sub")
  (directory-files root))

(test-equal "directory-files: MATCH keeps the names that match" '("a.txt")
  (directory-files root #f "a\\.txt"))

(test-equal "directory-files: FULL gives absolute names"
  (list (string-append root "/.") (string-append root "/..")
        (string-append root "/a.txt") (string-append root "/b.txt")
        (string-append root "/sub"))
  (directory-files root #t))

;; "the function will return COUNT number of file names" - and it stops
;; before the sort, which is why the answer is not the alphabetically
;; first COUNT
(test-equal "directory-files: COUNT stops the reading" 2
  (length (directory-files root #f #f #f 2)))

;; NOSORT answers the C's list, which is readdir *reversed* - the C
;; conses each entry (dired.c:351) and only reverses on the way into the
;; sort (dired.c:367). `.` and `..` therefore come last, which is the
;; shape that tells this apart from readdir's own order.
(test-equal "directory-files: NOSORT reverses the readdir order" 5
  (length (directory-files root #f #f #t)))
(test-equal "directory-files: NOSORT puts .. and . last" '(".." ".")
  (let* ((names (directory-files root #f #f #t))
         (n (length names)))
    (list (list-ref names (- n 2)) (list-ref names (- n 1)))))

;; ------------------------------------------------------------------
;; directory-files-and-attributes

(define with-attrs (directory-files-and-attributes root #f #f #f 'string))
(test-equal "directory-files-and-attributes: one pair per name" 5
  (length with-attrs))
;; the attributes are read from the *full* name, or a relative one would
;; be looked up against the process's directory and answer nil
(test-equal "and every entry has real attributes" 5
  (length (filter (lambda (e) (pair? (cdr e))) with-attrs)))

;; ------------------------------------------------------------------
;; the files.el wrappers `ls-lisp' is built on

(test-equal "file-name-sans-versions: a backup" "foo.txt"
  (file-name-sans-versions "foo.txt~"))
(test-equal "file-name-sans-versions: a version string" "foo.txt"
  (file-name-sans-versions "foo.txt.~1~"))
(test-equal "file-name-sans-versions: a plain name is its own" "foo.txt"
  (file-name-sans-versions "foo.txt"))

(test-equal "file-name-sans-extension" "/a/b"
  (file-name-sans-extension "/a/b.txt"))
;; "a leading `.' of the file name ... doesn't count"
(test-equal "file-name-sans-extension: a dotfile keeps its dot" "/a/.hidden"
  (file-name-sans-extension "/a/.hidden"))

(test-equal "file-name-base" "b" (file-name-base "/a/b.txt"))
(test-equal "file-name-base of a dotfile" ".hidden"
  (file-name-base "/a/.hidden"))

(test-equal "file-truename resolves .." "/tmp"
  (file-truename "/tmp/../tmp"))

(test-equal "abbreviate-file-name substitutes ~"
  "~/x" (abbreviate-file-name (string-append (getenv "HOME") "/x")))

(test-equal "file-relative-name: under the directory" "c.txt"
  (file-relative-name "/a/b/c.txt" "/a/b"))
(test-equal "file-relative-name: a level up" "../c.txt"
  (file-relative-name "/a/c.txt" "/a/b"))
;; "don't bother with ANCESTOR if it would give us `./'"
(test-equal "file-relative-name: deeper" "c/d.txt"
  (file-relative-name "/a/b/c/d.txt" "/a/b"))

(test-end "dired")
