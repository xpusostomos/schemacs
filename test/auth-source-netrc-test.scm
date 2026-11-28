(import
  (scheme base)
  (scheme write)
  (scheme file)
  (only (guile) setvbuf)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (oop goops) make)
  (only (schemacs dispnew) current-display)
  (only (schemacs test-display) <test-display>)
  (only (schemacs frame) new-frame *current-frame* *current-buffer*)
  (only (schemacs buffer) get-buffer-create with-current-buffer current-buffer
        major-mode buffer-local-value)
  (only (schemacs editfns) insert buffer-string)
  (only (schemacs fns) plist-get)
  (only (schemacs files) file-exists-p)
  (only (schemacs auth-source)
        *auth-sources* *auth-source-do-cache* *auth-source-save-behavior*
        *auth-source-creation-defaults* *authinfo-hidden*
        auth-source-search auth-source-user-and-password auth-source-delete
        auth-source-backend auth-source-backend-parse
        auth-source-backends auth-source-backends-parser-file
        auth-source-backends-parser-macos-keychain
        auth-source-netrc-parse auth-source-netrc-parse-all
        auth-source-netrc-normalize auth-source-netrc-create
        auth-source--decode-octal-string auth-source--obfuscate
        auth-source--deobfuscate auth-source-format-cache-entry
        auth-source-remember auth-source-recall auth-source-remembered-p
        auth-source-forget auth-source-forget+ auth-source-search-spec
        auth-source-json-search authinfo-mode auth-source-backend-type
        auth-source-backend-source slot-value))

;; `auth-source.el`'s backend machinery: the parser, the netrc and JSON
;; backends, the cache, and `authinfo-mode'. Every expectation below is
;; Emacs 31.1's own answer for the same fixture (measured with
;; `emacs -Q --batch'), except the two named as the port's own shape:
;; the `read-passwd' backend's cached answer is a list wrapping the
;; stored one, which is Emacs's `(list found)', and the JSON token's
;; `:secret' is a thunk here where Emacs's is a closure.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)
(define %frame (new-frame (get-buffer-create "auth-source-netrc-tests") 24 80))

(define (write-file path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define %netrc "/tmp/auth-source-netrc-test")
(define %json "/tmp/auth-source-json-test.json")
(define %created "/tmp/auth-source-created-test")

(write-file %netrc
            (string-append
             "machine host1 login user1 password pass1 port 143\n"
             "machine host2 login user2 password \"pass 2\"\n"
             "default login anon password guest\n"))
(write-file %json
            "[{\"machine\":\"h1\",\"login\":\"u1\",\"password\":\"p1\"},\
{\"machine\":\"h2\",\"login\":\"u2\",\"password\":\"p2\"}]")

;; Emacs's `auth-source-search' reads `auth-sources' dynamically; the
;; tree's variable is a parameter.
(define (with-sources sources thunk)
  (parameterize ((*auth-sources* sources)
                 (*auth-source-do-cache* #f)
                 (*current-frame* %frame)
                 (*current-buffer* #f))
    (thunk)))

(test-begin "schemacs_auth_source_netrc")

;;------------------------------------------------------------------
;; Backend parsing
;;------------------------------------------------------------------

(test-equal 'netrc
  (with-sources '()
    (lambda ()
      (auth-source-backend-type (auth-source-backend-parse %netrc)))))

(test-equal %netrc
  (with-sources '()
    (lambda ()
      (auth-source-backend-source (auth-source-backend-parse %netrc)))))

(test-equal 'json
  (with-sources '()
    (lambda ()
      (auth-source-backend-type (auth-source-backend-parse %json)))))

;; An entry that names a file that does not exist is `ignore' when
;; `auth-source-ignore-non-existing-file' is on (the default), and
;; `auth-source-backends' then falls back to the read-passwd backend.
(test-equal '(read-passwd)
  (with-sources '("/tmp/auth-source-does-not-exist")
    (lambda ()
      (map auth-source-backend-type (auth-source-backends)))))

;; The macOS keychain's name forms parse into their backend, which is
;; inert on a machine without `/usr/bin/security'.
(test-equal '(macos-keychain-internet "default")
  (with-sources '()
    (lambda ()
      (let ((b (auth-source-backend-parse 'macos-keychain-internet)))
        (list (auth-source-backend-type b) (auth-source-backend-source b))))))

(test-equal '(macos-keychain-generic "mine")
  (with-sources '()
    (lambda ()
      (let ((b (auth-source-backend-parse "macos-keychain-generic:mine")))
        (list (auth-source-backend-type b) (auth-source-backend-source b))))))

;; The extra parameters of an entry: `:host` and `:user` restrict the
;; backend's matching.
(test-equal '("only" "justme")
  (with-sources '()
    (lambda ()
      (let ((b (auth-source-backend-parse
                (list ':source %netrc ':host "only" ':user "justme"))))
        (list (slot-value b 'host) (slot-value b 'user))))))

;;------------------------------------------------------------------
;; The netrc parser and normalizer
;;------------------------------------------------------------------

(test-equal 3
  (with-sources '()
    (lambda ()
      (length (auth-source-netrc-parse-all %netrc)))))

;; The host filter keeps the matching machine and the `default' entry,
;; whose machine is t - which matches any host, as it does in Emacs.
(test-equal '("host1" #t)
  (with-sources '()
    (lambda ()
      (map (lambda (entry)
             (let ((cell (assoc "machine" entry)))
               (cdr cell)))
           (auth-source-netrc-parse ':file %netrc ':max 5000
                                    ':host "host1" ':user #t ':port #t)))))

;; Normalization: the keys are keywords and the password is obfuscated
;; behind a function.
(test-equal '("host1" "user1" "143" "pass1")
  (with-sources '()
    (lambda ()
      (let* ((entries (auth-source-netrc-parse ':file %netrc ':max 5000
                                               ':host "host1" ':user #t ':port #t))
             (token (car (auth-source-netrc-normalize entries %netrc))))
        (list (plist-get token ':host)
              (plist-get token ':user)
              (plist-get token ':port)
              ((plist-get token ':secret)))))))

(test-equal "pass 2"
  (with-sources '()
    (lambda ()
      (let ((token (car (auth-source-netrc-normalize
                         (auth-source-netrc-parse ':file %netrc ':max 5000
                                                  ':host "host2" ':user #t ':port #t)
                         %netrc))))
        ((plist-get token ':secret))))))

;; The obfuscation is one integer per character, which is the C's
;; non-GnuTLS branch (the GnuTLS one is not ported).
(test-equal '(97 98 99)
  (map (lambda (c) c) (auth-source--obfuscate "bcd")))
(test-equal "bcd"
  (auth-source--deobfuscate (auth-source--obfuscate "bcd")))

;;------------------------------------------------------------------
;; `auth-source-search'
;;------------------------------------------------------------------

;; `:host "host1"' finds the machine and the default entry; the token
;; carries host, user and port, and its secret answers the password.
(test-equal '("host1" "user1" "143" "pass1" #t)
  (with-sources (list %netrc)
    (lambda ()
      (let ((tokens (auth-source-search ':host "host1" ':max 5)))
        (list (plist-get (car tokens) ':host)
              (plist-get (car tokens) ':user)
              (plist-get (car tokens) ':port)
              ((plist-get (car tokens) ':secret))
              (eq? (plist-get (cadr tokens) ':host) #t))))))

(test-equal #t
  (with-sources (list %netrc)
    (lambda ()
      (auth-source-search ':host "host1" ':max 0))))

(test-assert "a search with no match answers Emacs's nil (the empty list)"
  (with-sources (list %netrc)
    (lambda ()
      (null? (auth-source-search ':host "host1" ':user "nobody" ':max 5)))))

;; `:require '(:secret)' drops entries without one, and the default
;; entry keeps its `:host` of t.
(test-equal '(#t)
  (with-sources (list %netrc)
    (lambda ()
      (map (lambda (token) (plist-get token ':host))
           (auth-source-search ':host "nonhost" ':require '(:secret) ':max 5)))))

;; `auth-source-user-and-password' answers (USER PASSWORD TOKEN).
(test-equal '("user2" "pass 2")
  (with-sources (list %netrc)
    (lambda ()
      (let ((answer (auth-source-user-and-password "host2")))
        (list (car answer) (cadr answer))))))

;;------------------------------------------------------------------
;; The cache
;;------------------------------------------------------------------

(let ((spec (list ':host "host1" ':max 1)))
  (test-equal #f (auth-source-remembered-p spec))
  (auth-source-remember spec (list (list ':host "cached")))
  (test-equal #t (auth-source-remembered-p spec))
  (test-equal '((:host "cached")) (auth-source-recall spec))
  (test-assert "forget removes the entry" (auth-source-forget spec))
  (test-equal #f (auth-source-remembered-p spec)))

;; `forget+' matches a partial spec against what was stored.
(let ((spec (list ':host "host9" ':max 1)))
  (auth-source-remember spec '())
  (test-equal 1 (auth-source-forget+ ':host "host9")))

;; `auth-source-search-spec' drops the meta keys and `t' values.
(test-equal '(:host ("h"))
  (auth-source-search-spec '(:host "h" :create #t :max 1 :delete #f)))

;;------------------------------------------------------------------
;; Creating and saving a netrc line
;;------------------------------------------------------------------

(when (file-exists-p %created) (delete-file %created))
(write-file %created "machine hostA login userA password passA\n")

(let ((token
       (with-sources (list %created)
         (lambda ()
           ;; Every created field is in the spec, so nothing prompts; the
           ;; saver's own question is skipped by `save-behavior' t.
           (parameterize ((*auth-source-save-behavior* #t))
             (car (auth-source-search ':host "newhost"
                                      ':user "newuser"
                                      ':port "imap"
                                      ':secret "pass"
                                      ':create #t ':max 1)))))))
  (test-equal '("newhost" "newuser" "imap")
    (list (plist-get token ':host) (plist-get token ':user)
          (plist-get token ':port)))
  (test-assert "the created token has a save function"
               (procedure? (plist-get token ':save-function)))
  ;; Saving with `auth-source-save-behavior' t writes without asking.
  (with-sources '()
    (lambda ()
      (parameterize ((*auth-source-save-behavior* #t))
        ((plist-get token ':save-function)))
      (test-equal
       (string-append "machine newhost login newuser port imap password pass\n"
                      "machine hostA login userA password passA\n")
       (call-with-input-file %created (lambda (port) (read-string 4096 port)))))))

;;------------------------------------------------------------------
;; The JSON backend
;;------------------------------------------------------------------

(test-equal '("h1" "u1" "p1")
  (with-sources (list %json)
    (lambda ()
      (let ((tokens (auth-source-search ':host "h1" ':max 5)))
        (list (plist-get (car tokens) ':host)
              (plist-get (car tokens) ':user)
              ((plist-get (car tokens) ':secret)))))))

(test-equal 2
  (with-sources (list %json)
    (lambda ()
      (length (auth-source-search ':host #t ':max 10)))))

;;------------------------------------------------------------------
;; The octal decoder (the macOS Keychain backend's)
;;------------------------------------------------------------------

(test-equal (string #\a #\\ #\b) (auth-source--decode-octal-string "a\\134b"))
(test-equal "café" (auth-source--decode-octal-string "caf\\303\\251"))

;;------------------------------------------------------------------
;; `authinfo-mode'
;;------------------------------------------------------------------

(with-current-buffer (get-buffer-create "*authinfo-test*")
  (insert "machine host login user password secret\n")
  (authinfo-mode)
  (test-equal 'authinfo-mode (major-mode))
  (test-equal "#" (buffer-local-value (current-buffer) 'comment-start))
  (test-equal "" (buffer-local-value (current-buffer) 'comment-end)))

(test-end "schemacs_auth_source_netrc")
