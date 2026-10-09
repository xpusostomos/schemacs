;; Tests for `(schemacs editor files)' - the parts of `files.el' that can
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
 (only (guile) getenv)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine) new-text-editor)
 (only (schemacs editor buffer) buffer-local-value default-directory current-buffer)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor fileio)
       directory-file-name file-directory-p file-name-case-insensitive-p
       file-name-directory-part)
 (only (schemacs editor search) regexp-quote)
 (only (schemacs editor files)
       *abbreviated-home-dir* *directory-abbrev-alist*
       abbreviate-file-name cd cd-absolute cd-path set!cd-path
       directory-abbrev-apply file-name-completion-table
       parse-colon-path locate-file))

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

(define ed (new-text-editor))
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
