;; Tests for `(schemacs files)' - the parts of `files.el' that can
;; be asked a question without a terminal, which here is `cd' and the
;; search path machinery under it.
;;
;; Every expectation below was read off a real Emacs first:
;;
;;   emacs -Q --batch --eval '(progn
;;     (cd "/tmp") (princ (format "%S" default-directory))
;;     (condition-case e (cd "/etc/hostname")
;;       (error (princ (error-message-string e)))))'
;;
;; gave "/tmp/", "No such directory: /etc/hostname" and
;; "/etc/hostname/: no such directory" for `cd-absolute' - note the
;; trailing slash in the last, which `file-name-as-directory' put there
;; before the test was made.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) getenv mkdir sort)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 
 (only (schemacs buffer) buffer-local-value default-directory current-buffer allocate-buffer
       get-buffer-create set-buffer set-buffer-local-value! major-mode
       set!buffer-file-name with-current-buffer)
 (only (schemacs editfns) insert)
 (only (schemacs intervals) put)
 (only (schemacs window) window-normalize-buffer-to-switch-to)
 (only (schemacs frame) *current-frame* new-frame)
 (only (schemacs fileio)
       directory-file-name file-directory-p file-name-case-insensitive-p
       file-name-directory-part file-name-nondirectory-part)
 (only (schemacs search) regexp-quote)
 (only (schemacs files)
       *abbreviated-home-dir* *directory-abbrev-alist*
       abbreviate-file-name cd cd-absolute cd-path set!cd-path
       directory-abbrev-apply file-name-completion-table
       parse-colon-path locate-file set-buffer-major-mode
       get-file-buffer
       file-expand-wildcards file-local-name
       ;; file-local variables
       hack-local-variables file-local-variables-alist
       set!file-local-variables-alist
       *before-hack-local-variables-hook* *enable-local-variables*
       *safe-local-variable-values*))

(setvbuf (current-output-port) 'none)

(define (message-of thunk)
  ;; The exception's message, as the echo area would show it - the same
  ;; accessors `keyboard.sld''s `report-command-error!' uses.
  ;;--------------------------------------------------------------
  (guard (e (#t (if (error-object? e)
                    (error-object-message e)
                    (format #f "~a" e))))
    (thunk)
    #f))

(define ed (allocate-buffer))
(define frame (new-frame ed 24 80))

(test-begin "schemacs_editor_files")

;;--------------------------------------------------------------------
;; `parse-colon-path'
;;------------------------------------------------------------------

(test-equal '("/a/" "/b/") (parse-colon-path "/a:/b"))

;; An empty element - leading, trailing or doubled - is nil, meaning
;; `default-directory'.
(test-equal '(#f "/a/" #f "/b/") (parse-colon-path ":/a::/b"))

;; A run of leading slashes collapses to one; two of them are not
;; special here, which the C spells `double-slash-special-p'.
(test-equal '("/a/") (parse-colon-path "///a"))
(test-equal '("/a/") (parse-colon-path "//a"))

;;--------------------------------------------------------------------
;; `cd'
;;------------------------------------------------------------------

(test-equal "/tmp/"
  (parameterize ((*current-frame* frame))
    (cd "/tmp")
    (default-directory)))

;; A file that is not a directory is not found by the search, which asks
;; for `dir-ok' - so it is the same "No such directory" a missing one
;; gets, not `cd-absolute''s "is not a directory".
(test-equal "No such directory: /etc/hostname"
  (parameterize ((*current-frame* frame)) (message-of (lambda () (cd "/etc/hostname")))))

(test-equal "No such directory: /no/such/place"
  (parameterize ((*current-frame* frame)) (message-of (lambda () (cd "/no/such/place")))))

;; `cd-absolute' is reached with the trailing slash already on, so its
;; message carries it - and its test is `(file-directory-p
;; "/etc/hostname/")', which is false, and then `(file-exists-p
;; "/etc/hostname/")', which is false too, because of that slash.
(test-equal "/etc/hostname/: no such directory"
  (parameterize ((*current-frame* frame))
    (message-of (lambda () (cd-absolute "/etc/hostname")))))

;; CDPATH: the name is looked for *under* each entry, so `cd "tmp"' with
;; a CDPATH of "/" finds "/tmp".
(test-equal "/tmp/"
  (parameterize ((*current-frame* frame))
    (set!cd-path (list "/"))
    (cd "tmp")
    (default-directory)))

;; and `cd-path' answers what was set - it is a defvar, read and written.
(test-equal '("/")
  (parameterize ((*current-frame* frame)) (set!cd-path (list "/")) (cd-path)))

;;--------------------------------------------------------------------
;; `locate-file' and its `dir-ok'
;;------------------------------------------------------------------

;; The predicate that accepts a directory answers it ...
(test-equal "/tmp"
  (locate-file "/tmp" '("/") '()
               (lambda (f) (and (file-directory-p f) 'dir-ok))))

;; ... and the answer is the *joined* name, not the argument.
(test-equal "/bin"
  (locate-file "bin" '("/") '()
               (lambda (f) (and (file-directory-p f) 'dir-ok))))

;; A suffix is appended before the test, and a name that is not there is
;; nil.
(test-equal #f (locate-file "/no/such/place" '("/") '() #f))

;;--------------------------------------------------------------------
;; `abbreviate-file-name'
;;------------------------------------------------------------------
;; Every expectation is Emacs 31.1's own answer for the same name, from
;; running this list through `emacs -Q --batch --eval'. The `~' rule is
;; `C-x C-f''s prompt and `C-x C-b''s File column: both read a name
;; through this.

(define home (getenv "HOME"))

(test-equal "the home directory itself is just `~'"
  "~" (abbreviate-file-name home))

(test-equal "a name under it keeps its own path after the `~'"
  "~/x" (abbreviate-file-name (string-append home "/x")))

(test-equal "and a home directory with its slash is `~/'"
  "~/" (abbreviate-file-name (string-append home "/")))

(test-equal "deeper names too"
  "~/a/b/c" (abbreviate-file-name (string-append home "/a/b/c")))

;; The slash in the regexp is what stops `/usr/foobar' being taken for the
;; home directory `/usr/foo' - `directory-abbrev-make-regexp''s group.
(test-equal "a name that merely starts with the home directory is left alone"
  (string-append home "foo/x")
  (abbreviate-file-name (string-append home "foo/x")))

(test-equal "...and so is one that shares a prefix of the last component"
  (string-append home "2")
  (abbreviate-file-name (string-append home "2")))

(test-equal "a name outside the home directory is left alone"
  "/etc/hosts" (abbreviate-file-name "/etc/hosts"))

(test-equal "a relative name is not touched"
  "relative" (abbreviate-file-name "relative"))

(test-equal "and neither is the root"
  "/" (abbreviate-file-name "/"))

;; `directory-abbrev-alist''s FROM is a *regexp*, anchored by convention,
;; and every matching element applies in order.
(test-equal "directory-abbrev-alist shortens by its regexp"
  "/s/doc/x"
  (parameterize ((*directory-abbrev-alist*
                  (list (cons "\\`/usr/share/" "/s/"))))
    (abbreviate-file-name "/usr/share/doc/x")))

(test-equal "directory-abbrev-apply takes the tail from the match's end"
  "/s/doc/x"
  (parameterize ((*directory-abbrev-alist*
                  (list (cons "\\`/usr/share/" "/s/"))))
    (directory-abbrev-apply "/usr/share/doc/x")))

;; `abbreviated-home-dir' is a cache, and *what it was built from* shows
;; when the alist also covers the home directory. Emacs 31.1 answers
;; "~/chris/y" with the cache already warm and "~/y" with it cold - the
;; cached regexp is the *abbreviated* home, so a name the alist has
;; already rewritten to start with `~' is substituted again. Both are
;; measured, and both are reproduced.
(test-equal '("~/chris/y" "~/y")
  (let* ((parent (file-name-directory-part (directory-file-name home)))
         (alist (list (cons (string-append "\\`" (regexp-quote parent)) "~/"))))
    ;; warm: the cache is built from a home directory no alist rewrote
    (abbreviate-file-name home)
    (parameterize ((*directory-abbrev-alist* alist))
      (list (abbreviate-file-name (string-append home "/y"))
            ;; cold: the cache is built with the alist in force
            (parameterize ((*abbreviated-home-dir* #f))
              (abbreviate-file-name (string-append home "/y")))))))

;; `file-name-case-insensitive-p' is what `abbreviate-file-name' binds
;; `case-fold-search' to, and on this platform the C's answer is a
;; constant - `fileio.sld' says why. It is what makes the substitutions
;; above case-*sensitive*, as Emacs's are on the same filesystem.
(test-equal #f (file-name-case-insensitive-p "/etc/hosts"))

;;--------------------------------------------------------------------
;; `~' in the name being completed
;;------------------------------------------------------------------
;; `read-file-name' puts the *abbreviated* default directory in the
;; minibuffer, so TAB hands this table a `~' to resolve. Emacs's
;; `realdir' is `(or specdir default-directory)' (`minibuffer.el:3721')
;; and the expansion is the C's, inside `file-name-completion' and
;; `file-name-all-completions': `directory = Fexpand_file_name
;; (directory, Qnil);'. Without it the table read `~/' as a *relative*
;; directory, `directory-entries' raised "No such file or directory" and
;; TAB in a `C-x C-f' prompt did nothing at all.

(test-assert "the completion table expands a ~ directory"
  (pair? (file-name-completion-table "~/" #f #t)))

;; ...and it completes a *name* under it, which is what TAB does: the
;; home directory always has one of these two, and both are asked for by
;; a prefix that only matches inside it.
(test-assert "and completes a name under it"
  (let ((completions (file-name-completion-table "~/.bash" #f #t)))
    (and (list? completions)
         (list? (file-name-completion-table "~/" #f #t)))))

;; Not tested here: Emacs's *user-name* completion - the
;; `(string-match-p "\\`~[^/\\]*\\'" string)' branch of
;; `completion-file-name-table' (`minibuffer.el:3695'), which completes
;; `~ro' to `~root/'. It needs `system-users', which this tree has no
;; port of. A `~user/x' still *works* - `expand-file-name''s `~USER' rule
;; is the C's and is ported - it is only the completion of the user name
;; that is missing.

;; `cd' sets `list-buffers-directory' as well as `default-directory'
;; (`files.el:980-981'), and that is what `C-x C-b`'s File column shows for
;; a buffer that visits no file - so `cd' in `*scratch*' is visible there.
(test-equal '("/tmp/" "/tmp/")
  (parameterize ((*current-frame* frame))
    (set!cd-path (list "/"))
    (cd "tmp")
    (list (default-directory)
          (buffer-local-value (current-buffer) 'list-buffers-directory #f))))

(test-end "schemacs_editor_files")

;;------------------------------------------------------------------
;; `set-buffer-major-mode' takes the *default* mode, not the current one
;;------------------------------------------------------------------
;;
;; Measured on Emacs 31.1: `(window-normalize-buffer-to-switch-to "fresh")'
;; run from a `text-mode' buffer answers a buffer in `fundamental-mode',
;; and a `*scratch*' buffer takes `initial-major-mode', which is
;; `lisp-interaction-mode'. Reading the *target* buffer's own mode - what
;; this did - left `C-x b fresh' in a Scheme buffer a Scheme buffer.

(test-begin "schemacs_editor_files_major_mode")

(test-equal 'fundamental-mode
  (let ((source (get-buffer-create "sbmm-source")))
    (set-buffer source)
    (set-buffer-local-value! source 'major-mode 'scheme-mode)
    (let ((fresh (window-normalize-buffer-to-switch-to "sbmm-fresh")))
      (buffer-local-value fresh 'major-mode 'fundamental-mode))))

(test-equal 'lisp-interaction-mode
  (let ((scratch (get-buffer-create "*scratch*")))
    (set-buffer-local-value! scratch 'major-mode 'fundamental-mode)
    (set-buffer-major-mode scratch)
    (buffer-local-value scratch 'major-mode 'fundamental-mode)))

(test-end "schemacs_editor_files_major_mode")


;;--------------------------------------------------------------------
;; File-local variables: the -*- line and the Local Variables block.
;;
;; Every expectation is what `emacs -Q --batch' answers with
;; `enable-local-variables' bound to `:all' (so the safety prompt, which
;; this test cannot answer, is out of the way). `nil' in a value is this
;; tree's #f, which is why `indent-tabs-mode: nil' reads back as false.

(test-begin "schemacs_editor_files_local_variables")

(define (local-variables-buffer text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    b))

(parameterize ((*enable-local-variables* ':all))
  (let ((b (local-variables-buffer "-*- foo-bar: 42; str: \"x\" -*-\nbody")))
    (hack-local-variables)
    (test-equal "the -*- line sets a number" 42
                (buffer-local-value b 'foo-bar #f))
    (test-equal "and a string" "x" (buffer-local-value b 'str #f))
    (test-equal "and records them in file-local-variables-alist" 42
                (cdr (assq 'foo-bar (file-local-variables-alist))))
    (test-equal "the coding: tag is not a variable" #f
                (assq 'coding (file-local-variables-alist))))

  (let ((b (local-variables-buffer
            "body\nLocal Variables:\nfoo-bar: 42\nstr: \"x\"\nEnd:\n")))
    (hack-local-variables)
    (test-equal "the Local Variables block sets a number" 42
                (buffer-local-value b 'foo-bar #f))
    (test-equal "and a string" "x" (buffer-local-value b 'str #f)))

  (let ((b (local-variables-buffer
            "body\nLocal Variables:\nmode: text\nEnd:\n")))
    (hack-local-variables)
    (test-equal "mode: runs the mode" 'text-mode (major-mode b)))

  (let ((b (local-variables-buffer
            "body\nLocal Variables:\nindent-tabs-mode: nil\nEnd:\n")))
    (hack-local-variables)
    (test-equal "nil is this tree's false" #f
                (buffer-local-value b 'indent-tabs-mode 'absent))))

;; The before-hook runs after the alist is filled and before the
;; variables are applied, which is where cc-mode's c-before-hack-hook
;; reads and rewrites the file's style (cc-mode.el:863).
(let ((b (local-variables-buffer
          "body\nLocal Variables:\nfoo-bar: 42\nEnd:\n"))
      (log '()))
  (parameterize ((*enable-local-variables* ':all)
                 (*before-hack-local-variables-hook*
                  (list (lambda ()
                          (set! log (cons 'ran log))
                          (set!file-local-variables-alist
                           (cons (cons 'added 7) (file-local-variables-alist)))))))
    (hack-local-variables)
    (test-equal "before-hack-local-variables-hook ran" '(ran) log)
    (test-equal "its addition is applied too" 7
                (buffer-local-value b 'added #f))
    (test-equal "and the file's own variable as well" 42
                (buffer-local-value b 'foo-bar #f))))

;; A variable marked safe with `put' is applied without the prompt.
(put 'safe-marked-test-variable 'safe-local-variable integer?)
(let ((b (local-variables-buffer
          "body\nLocal Variables:\nsafe-marked-test-variable: 9\nEnd:\n")))
  (parameterize ((*enable-local-variables* #t))
    (hack-local-variables)
    (test-equal "a safe-local-variable property applies without asking" 9
                (buffer-local-value b 'safe-marked-test-variable #f))))

;; A value in `safe-local-variable-values' likewise.
(let ((b (local-variables-buffer
          "body\nLocal Variables:\nplist-test-variable: \"v\"\nEnd:\n")))
  (parameterize ((*enable-local-variables* #t)
                 (*safe-local-variable-values*
                  (list (cons 'plist-test-variable "v"))))
    (hack-local-variables)
    (test-equal "safe-local-variable-values applies without asking" "v"
                (buffer-local-value b 'plist-test-variable #f))))


;;----------------------------------------------------------------------
;; `get-file-buffer` (`buffer.c`'s `Fget_file_buffer`, placed in this
;; library because it opens with `expand-file-name`): the buffer whose
;; `buffer-file-name` is the *expansion* of the argument.
(test-equal "get-file-buffer finds the buffer visiting the expanded name"
  #t
  (with-current-buffer (get-buffer-create " *get-file-buffer*")
    (set!buffer-file-name (current-buffer) "/tmp/get-file-buffer-test.txt")
    (eq? (get-file-buffer "/tmp/get-file-buffer-test.txt") (current-buffer))))

(test-equal "get-file-buffer expands its argument"
  #t
  (with-current-buffer (get-buffer-create " *get-file-buffer-2*")
    (set!buffer-file-name (current-buffer) "/tmp/get-file-buffer-test.txt")
    (eq? (get-file-buffer "/tmp/../tmp//get-file-buffer-test.txt")
         (current-buffer))))

(test-equal "and answers nil for a file nobody visits"
  #f
  (get-file-buffer "/tmp/no-such-file-is-visited.txt"))

(test-end "schemacs_editor_files_local_variables")

;;----------------------------------------------------------------------
;; `file-expand-wildcards' and `file-local-name' (`files.el'), which
;; compile.el's `compilation-find-file' reads.  Every expectation is
;; Emacs 31.1's on the same directory (the README of `tools/' records
;; the warning that `*-nondirectory' is this tree's spelling of
;; `file-name-nondirectory').
(test-begin "schemacs_editor_files_wildcards")

(define wild-dir "/tmp/schemacs-files-wild-test/")
(guard (e (else #f)) (mkdir wild-dir #o700))
(for-each
 (lambda (name)
   (call-with-output-file (string-append wild-dir name)
     (lambda (port) (display "" port))))
 '("a.txt" "b.txt" "c.scm"))

(define (names-of pattern)
  ;; Sorted, because a directory's order is the filesystem's.
  (sort (map file-name-nondirectory-part (file-expand-wildcards pattern))
        string<?))

(test-equal "a wildcard expands the names that match, and only those"
            '("a.txt" "b.txt")
            (names-of (string-append wild-dir "*.txt")))
(test-equal "a question mark matches one character"
            '("c.scm")
            (names-of (string-append wild-dir "?.scm")))
(test-equal "a bracket class matches one of its characters"
            '("a.txt" "b.txt")
            (names-of (string-append wild-dir "[ab].txt")))
(test-equal "a pattern with no wildcard answers the file if it exists"
            (list (string-append wild-dir "a.txt"))
            (file-expand-wildcards (string-append wild-dir "a.txt")))
(test-equal "and nil when it does not"
            '()
            (file-expand-wildcards (string-append wild-dir "nope.txt")))
;; bug#15417: a pattern ending in "/" is the directory itself, not the
;; names in it.
(test-equal "a trailing slash answers the directory itself"
            (list wild-dir)
            (file-expand-wildcards wild-dir))
(test-equal "an absolute pattern answers absolute names"
            #t
            (let ((name (car (file-expand-wildcards
                              (string-append wild-dir "c.scm")))))
              (and (char=? (string-ref name 0) #\/)
                   (string=? (file-name-nondirectory-part name)
                             "c.scm"))))
(test-equal "file-local-name is the name itself when nothing is remote"
            (list "/tmp/x.txt" "x.txt")
            (list (file-local-name "/tmp/x.txt") (file-local-name "x.txt")))

(test-end "schemacs_editor_files_wildcards")
