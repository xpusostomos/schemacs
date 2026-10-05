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
 (only (schemacs editor buffer) default-directory)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor fileio) file-directory-p)
 (only (schemacs editor files)
       cd cd-absolute cd-path set!cd-path parse-colon-path locate-file))

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

(test-end "schemacs_editor_files")
