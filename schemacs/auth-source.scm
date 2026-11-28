(define-library (schemacs auth-source)
  ;; GNU Emacs's `lisp/auth-source.el', whole except for the backends
  ;; that need a subsystem this tree does not have. The file's order is
  ;; kept: the variables, the backend class and parsers, `auth-source-
  ;; search' and its cache, the read-passwd backend, the netrc backend,
  ;; the JSON backend, `auth-source-user-and-password', `authinfo-mode',
  ;; and the `read-passwd' section at the end (which is where Emacs
  ;; keeps it, because it arrived in this file last).
  ;;
  ;; **Departures**, each named where it bites:
  ;;
  ;;   * **EIEIO.** `auth-source-backend' is a record. `auth-source-
  ;;     backend' is its constructor taking the class's keyword
  ;;     arguments, and `slot-value'/`oset' are private procedures over
  ;;     the record, so the call sites are Emacs's. `make-instance
  ;;     'auth-source-backend' is spelled `auth-source-backend'.
  ;;   * **Keywords are quoted symbols.** A scheme has no
  ;;     self-evaluating `:host'; every call site writes `':host', and
  ;;     the plists are compared with `eq?' as Emacs compares its
  ;;     keywords.
  ;;   * **`cl-defun''s `&key' is a plist.** The `auth-source-search'
  ;;     family takes `&rest spec' and reads the keys with `plist-get',
  ;;     which has the CL first-occurrence rule. `&allow-other-keys' is
  ;;     the default because unknown keys are simply never read.
  ;;   * **`cl-assert' is an explicit check** with Web the same message;
  ;;     `cl-dolist'/`cl-return' are `let/ec' loops; `cl-case' is
  ;;     `case'; `cl-loop' is a named let.
  ;;   * **The GPG half is not ported** (Chris's call): `auth-source-
  ;;     epa-extract-gpg-token', `auth-source-epa-make-gpg-token', the
  ;;     passphrase callback and the GnuTLS obfuscation arm. A `gpg:'
  ;;     token in a netrc file is still *read*, but calling its secret
  ;;     function signals that EPG is not ported rather than returning
  ;;     ciphertext as if it were a password.
  ;;   * **The Secrets API backend is not ported** (D-Bus), and
  ;;     `secrets-enabled' is defined as nil, which is the branch Emacs
  ;;     itself takes on a machine without the package: the parser
  ;;     declines and `auth-source-backend-parse' makes the `ignore'
  ;;     backend.
  ;;   * **The plstore backend is not ported** (plstore.el, base64 and
  ;;     EPG). A `.plist' source parses to a backend whose search
  ;;     function signals the gap. The macOS Keychain backend *is*
  ;;     ported: it is ordinary Lisp plus the `security' command, and it
  ;;     is inert on a machine whose `auth-sources' names no keychain.
  ;;   * **`customize-save-variable'** (the saver's `N' answer) saves
  ;;     for the session only: this tree has no custom-file writer yet.
  ;;     The header of `auth-source-netrc-saver' says so.
  ;;   * **`auth-source-backends' is a procedure** here, not a macro;
  ;;     it reads the `*auth-sources*' parameter. A caller that wants
  ;;     Emacs's `let'-binding writes `parameterize'.
  ;;   * `authinfo-mode' uses overlays; `authinfo--toggle-display' is
  ;;     ported but `reveal-mode' (which calls it) is not, so the mode
  ;;     hides the passwords once and leaves the toggle to a key this
  ;;     tree does not have. Named in the mode's body.
  ;;
  ;; The `read-passwd' section's own departures are in its comment
  ;; block, which is Emacs's position for them.
  ;;------------------------------------------------------------
  (import
    (scheme base)
    (scheme char)
    (only (guile) delq while list-head u32vector->list)
    (only (ice-9 control) let/ec)
    (only (schemacs custom) define-custom)
    (only (schemacs core icons)
          define-icon icon-string *icon-preference*)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs core syntax-macros) dotimes)
    (only (schemacs core seq) seq-uniq seq-keep seq-difference seq-union)
    (only (schemacs data) keywordp number-to-string string-to-number)
    (only (schemacs fns)
          clear-string delete maphash mapcar plist-get plist-put %string
          string-equal copy-sequence nth nconc nreverse %length)
    (only (schemacs buffer)
          current-buffer with-current-buffer buffer-local-value
          set-buffer-local-value! buffer-live-p erase-buffer
          kill-local-variable use-local-map get-buffer-create set-buffer
          buffer-name bufferp make-overlay overlay-put overlay-start
          overlay-end overlays-in)
    (only (schemacs editfns)
          buffer-size message format insert buffer-string buffer-substring
          goto-char point point-min point-max char-after eolp eobp bolp
          save-excursion forward-line user-login-name narrow-to-region
          save-restriction propertize)
    (only (schemacs search)
          string-match match-string match-string-no-properties
          match-beginning match-end looking-at save-match-data
          string-match-p re-search-forward)
    (only (schemacs subr)
          add-hook remove-hook intern intern-soft ensure-list
          replace-regexp-in-string with-temp-buffer member-ignore-case
          remq ignore string-to-list car-safe cdr-safe)
    (only (schemacs textprop)
          put-text-property remove-list-of-text-properties)
    (only (schemacs character) kbd)
    (only (schemacs keymap) make-sparse-keymap define-key set-keymap-parent)
    (only (schemacs command)
          define-command current-prefix-arg uarg->integer)
    (only (schemacs minibuffer)
          read-from-minibuffer format-prompt read-char-choice
          minibuffer-prompt-end *read-hide-char*
          active-minibuffer-window delete-minibuffer-contents
          minibuffer-local-map minibuffer-with-setup-hook
          *enable-recursive-minibuffers*)
    (only (schemacs simple)
          buffer-disable-undo *select-active-regions* count-lines
          fundamental-mode)
    (only (schemacs frame) *post-command-hook* window-buffer)
    (only (schemacs xdisp)
          force-mode-line-update *global-mode-string*)
    (only (schemacs keyboard) sit-for)
    (only (schemacs cmds) *post-self-insert-hook*)
    (only (schemacs insdel) *inhibit-modification-hooks*)
    ;; The password cache this file fills (`password-cache.el`).
    (only (schemacs password-cache)
          password-cache-add password-cache-remove password-read-from-cache
          password-in-cache-p password-data *read-passwd-function*
          *password-cache-expiry*)
    ;; The netrc saver's cache key (`rfc2104.el') and the digest it is
    ;; built on (`fns.c`'s `md5').
    (only (schemacs net rfc2104) rfc2104-hash)
    (only (schemacs fns) md5)
    ;; The JSON backend's parser (`json.el`'s read half).
    (only (schemacs json) json-read-file)
    ;; The netrc backend reads and writes files through these.
    (only (schemacs fileio)
          file-exists-p expand-file-name set-file-modes)
    (only (schemacs files)
          file-name-extension file-name-sans-extension
          insert-file-contents write-region y-or-n-p)
    (only (schemacs diredc) file-attributes file-attribute-modification-time)
    (only (schemacs timefns) time-equal-p)
    ;; The saver's help screen (`with-output-to-temp-buffer' is
    ;; `subr.el`'s, placed in `help.scm` for the display it needs) and
    ;; the mode that screen is shown in.
    (only (schemacs help) with-output-to-temp-buffer)
    (only (schemacs help-mode) help-mode)
    (only (schemacs print) princ *standard-output*)
    (only (schemacs window) get-buffer-window delete-window)
    (only (schemacs eval) run-hook-wrapped)
    (only (schemacs callproc) call-process)
    (only (schemacs coding) decode-coding-string)
    (only (schemacs core derived) define-derived-mode)
    (only (schemacs font-lock) font-lock-add-keywords)
    (only (schemacs newcomment)
          comment-start set!comment-start comment-end set!comment-end)
    (only (schemacs syntax) skip-chars-forward)
    (only (schemacs cmds) forward-char))

  (export
    ;; The search API
    auth-source-search auth-source-delete auth-source-search-backends
    auth-source-user-and-password auth-info-password
    auth-source-pick-first-password
    ;; The variables
    *auth-source-cache-expiry* *auth-source-protocols* *auth-source-protocols-customize*
    *auth-source-creation-defaults* *auth-source-creation-prompts*
    *auth-source-save-behavior* *auth-source-netrc-use-gpg-tokens*
    *auth-source-do-cache* *auth-source-debug* *auth-sources*
    *auth-source-gpg-encrypt-to* *auth-source-ignore-non-existing-file*
    *auth-source-netrc-cache* *authinfo-hidden* *authinfo-hide-elements*
    *auth-source-ignored-keys*
    ;; The backend machinery
    auth-source-backend auth-source-backend? auth-source-backend-type
    auth-source-backend-source auth-source-backend-host
    auth-source-backend-user auth-source-backend-port
    auth-source-backend-data auth-source-backend-create-function
    auth-source-backend-search-function
    slot-value oset
    auth-source-backend-parse auth-source-backends
    auth-source-backends-parser-file auth-source-backends-parser-macos-keychain
    auth-source-backends-parser-secrets auth-source-backend-parse-parameters
    auth-source-file-name-p
    *auth-source-backend-parser-functions*
    ;; The cache
    auth-source-forget-all-cached auth-source-format-cache-entry
    auth-source-remember auth-source-recall auth-source-remembered-p
    auth-source-forget auth-source-forget+ auth-source-specmatchp
    ;; The spec helpers
    auth-source-keys auth-source-search-keys auth-source-returned-keys
    auth-source-search-spec auth-source-search-collection
    auth-source-format-prompt auth-source-ensure-strings
    auth-source--aput-1 auth-source--aget
    auth-source-read-passwd-search auth-source-read-passwd-create
    ;; The netrc backend
    auth-source-netrc-parse-all auth-source-netrc-parse
    auth-source-netrc-parse-next-interesting auth-source-netrc-looking-at-token
    auth-source-netrc-parse-one auth-source-current-line
    auth-source-netrc-parse-entries auth-source-netrc-normalize
    auth-source-netrc-search auth-source-netrc-element-or-first
    auth-source-netrc-create auth-source-netrc-saver
    auth-source--symbol-keyword auth-source--obfuscate auth-source--deobfuscate
    ;; The JSON backend
    auth-source-json-check auth-source-json-search
    ;; The macOS Keychain backend
    auth-source-macos-keychain-search auth-source--decode-octal-string
    auth-source-macos-keychain-search-items
    auth-source-macos-keychain-result-append auth-source-macos-keychain-create
    ;; `authinfo-mode'
    authinfo-mode authinfo--keywords authinfo--hide-passwords
    authinfo--toggle-display
    ;; The read-passwd section
    read-passwd read-passwd-mode read-passwd-map
    read-passwd-mode-variable
    read-passwd-toggle-visibility
    read-passwd--hide-password
    read-passwd--password-hidden read-passwd--mode-line-icon
    read-passwd--mini-buffers)

  (begin

    ;;----------------------------------------------------------------
    ;; The variables and the backend class (`auth-source.el:77'-`:352').
    ;;----------------------------------------------------------------

    (define secrets-enabled #f)
    ;; ^ `(defvar secrets-enabled)' (`auth-source.el:77'), with the value
    ;; a machine without the Secrets package has: nil. The Secrets
    ;; backend is not ported (D-Bus), and its parser declines exactly as
    ;; Emacs's does when this is nil.

    (define-custom *auth-source-cache-expiry* 7200
      "How many seconds passwords are cached, or nil to disable expiring.
Overrides `password-cache-expiry' through a let-binding."
      :version "24.1"
      :type '(choice (const :tag "Never" nil)
                     (const :tag "All Day" 86400)
                     (const :tag "2 Hours" 7200)
                     (const :tag "30 Minutes" 1800)
                     (integer :tag "Seconds")))

    ;; The `auth-source-backend' class (`auth-source.el:98') is a
    ;; record. Emacs's slots are EIEIO slots; `slot-value' and `oset'
    ;; below are the two operations the rest of the file uses on them,
    ;; so every call site reads as Emacs's. The initforms are the
    ;; class's.
    (define-record-type <auth-source-backend>
      (%make-auth-source-backend type source host user port data
                                 create-function search-function)
      auth-source-backend?
      (type auth-source-backend-type set!auth-source-backend-type!)
      (source auth-source-backend-source set!auth-source-backend-source!)
      (host auth-source-backend-host set!auth-source-backend-host!)
      (user auth-source-backend-user set!auth-source-backend-user!)
      (port auth-source-backend-port set!auth-source-backend-port!)
      (data auth-source-backend-data set!auth-source-backend-data!)
      (create-function auth-source-backend-create-function
                       set!auth-source-backend-create-function!)
      (search-function auth-source-backend-search-function
                       set!auth-source-backend-search-function!))

    (define (auth-source-backend . params)
      ;; GNU Emacs's `auth-source-backend', the EIEIO constructor
      ;; (`auth-source.el:98'): `(auth-source-backend :type ... :source
      ;; ... :host ... :user ... :port ... :data ... :create-function
      ;; ... :search-function ...)'. PARAMS is a plist of quoted
      ;; keywords; the initforms are the class's.
      ;;--------------------------------------------------------------
      (%make-auth-source-backend
       (let ((v (plist-get params ':type))) (if v v 'netrc))
       (plist-get params ':source)
       (let ((v (plist-get params ':host))) (if v v #t))
       (let ((v (plist-get params ':user))) (if v v #t))
       (let ((v (plist-get params ':port))) (if v v #t))
       (plist-get params ':data)
       (let ((v (plist-get params ':create-function))) (if v v ignore))
       (let ((v (plist-get params ':search-function))) (if v v ignore))))

    (define (slot-value object slot)
      ;; EIEIO's `slot-value', over the one class this file has. An
      ;; unknown slot is EIEIO's `invalid-slot-name', which
      ;; `auth-source-search''s filter loop catches; a plain error is
      ;; what that loop's `condition-case' sees.
      ;;--------------------------------------------------------------
      (case slot
        ((type) (auth-source-backend-type object))
        ((source) (auth-source-backend-source object))
        ((host) (auth-source-backend-host object))
        ((user) (auth-source-backend-user object))
        ((port) (auth-source-backend-port object))
        ((data) (auth-source-backend-data object))
        ((create-function) (auth-source-backend-create-function object))
        ((search-function) (auth-source-backend-search-function object))
        (else (error "Invalid slot name: ~a" slot))))

    (define (oset object slot value)
      ;; EIEIO's `oset', as `slot-value' above: set SLOT of OBJECT to
      ;; VALUE and answer VALUE.
      ;;--------------------------------------------------------------
      (case slot
        ((type) (set!auth-source-backend-type! object value))
        ((source) (set!auth-source-backend-source! object value))
        ((host) (set!auth-source-backend-host! object value))
        ((user) (set!auth-source-backend-user! object value))
        ((port) (set!auth-source-backend-port! object value))
        ((data) (set!auth-source-backend-data! object value))
        ((create-function) (set!auth-source-backend-create-function! object value))
        ((search-function) (set!auth-source-backend-search-function! object value))
        (else (error "Invalid slot name: ~a" slot)))
      value)

    (define-custom *auth-source-protocols*
      '((imap "imap" "imaps" "143" "993")
        (pop3 "pop3" "pop" "pop3s" "110" "995")
        (ssh  "ssh" "22")
        (sftp "sftp" "115")
        (smtp "smtp" "25"))
      "List of authentication protocols and their names."
      :version "23.2"
      :type '(repeat :tag "Authentication Protocols"
                     (cons :tag "Protocol Entry"
                           (symbol :tag "Protocol")
                           (repeat :tag "Names"
                                   (string :tag "Name")))))

    ;; Generate all the protocols in a format Customize can use.
    ;; TODO: generate on the fly from auth-source-protocols
    (define *auth-source-protocols-customize*
      (mapcar (lambda (a)
                (let ((p (car-safe a)))
                  (list 'const
                        ':tag (string-upcase (symbol->string p))
                        p)))
              (*auth-source-protocols*)))

    (define *auth-source-creation-defaults* (make-parameter '()))
    ;; ^ `(defvar auth-source-creation-defaults nil)` (`auth-source.el:161'):
    ;; "Defaults for creating token values.  Usually let-bound." A
    ;; parameter because it is let-bound (by callers around a creation).

    (define *auth-source-creation-prompts* (make-parameter '()))
    ;; ^ `(defvar auth-source-creation-prompts nil)` (`auth-source.el:165'):
    ;; "Default prompts for token values.  Usually let-bound."

    (define-custom *auth-source-save-behavior* 'ask
      "If set, auth-source will respect it for save behavior."
      :version "23.2"
      :type '(choice
              :tag "auth-source new token save behavior"
              (const :tag "Always save" t)
              (const :tag "Never save" nil)
              (const :tag "Ask" ask)))

    (define-custom *auth-source-netrc-use-gpg-tokens* 'never
      "Set this to tell `auth-source' when to create GPG password
tokens in netrc files.  It's either an alist or `never'.
Note that if EPA/EPG is not available, this should NOT be used."
      :version "23.2"
      :type '(choice
              (const :tag "Always use GPG password tokens" (t gpg))
              (const :tag "Never use GPG password tokens" never)
              (repeat :tag "Use a lookup list"
                      (list
                       (choice :tag "Matcher"
                               (const :tag "Match anything" t)
                               (regexp :tag "Regular expression"))
                       (choice :tag "What to do"
                               (const :tag "Save GPG-encrypted password tokens" gpg)
                               (const :tag "Don't encrypt tokens" never))))))

    (define-custom *auth-source-do-cache* #t
      "Whether auth-source should cache information with `password-cache'."
      :version "23.2"
      :type 'boolean)

    (define-custom *auth-source-debug* #f
      "Whether auth-source should log debug messages.

If the value is nil, debug messages are not logged.

If the value is t, debug messages are logged with `message'.  In
that case, your authentication data will be in the clear (except
for passwords).

If the value is a function, debug messages are logged by calling
 that function using the same arguments as `message'."
      :version "23.2"
      :type '(choice
              :tag "auth-source debugging mode"
              (const :tag "Log using `message' to the *Messages* buffer" t)
              (const :tag "Log all trivia with `message' to the *Messages* buffer"
                     trivia)
              (function :tag "Function that takes arguments like `message'")
              (const :tag "Don't log anything" nil)))

    (define-custom *auth-sources* '("~/.authinfo" "~/.authinfo.gpg" "~/.netrc")
      "List of authentication sources.
Each entry is the authentication type with optional properties.
Entries are tried in the order in which they appear.
See Info node `(auth)Help for users' for details.

If an entry names a file with the \".gpg\" extension and you have
EPA/EPG set up, the file will be encrypted and decrypted
automatically.  See Info node `(epa)Encrypting/decrypting gpg files'
for details.

If this option is nil, no authentication source is used but the local
password cache.

It's best to customize this with \\[customize-variable] because
the choices can get pretty complex."
      :version "26.1"
      :type '(choice (const :tag "Password cache" nil)
                     (repeat :tag "Authentication Sources"
                             (choice
                              (string :tag "Just a file")
                              (const :tag "Default Secrets API Collection" default)
                              (const :tag "Login Secrets API Collection" "secrets:Login")
                              (const :tag "Temp Secrets API Collection" "secrets:session")
                              (const :tag "Default internet Mac OS Keychain"
                                     macos-keychain-internet)
                              (const :tag "Default generic Mac OS Keychain"
                                     macos-keychain-generic)
                              (list :tag "Source definition"
                                    (const :format "" :value :source)
                                    (choice :tag "Authentication backend choice"
                                            (string :tag "Authentication Source (file)")
                                            (list
                                             :tag "Secret Service API/KWallet/GNOME Keyring/KeyPassXC"
                                             (const :format "" :value :secrets)
                                             (choice :tag "Collection to use"
                                                     (string :tag "Collection name")
                                                     (const :tag "Default" default)
                                                     (const :tag "Login" "Login")
                                                     (const :tag "Temporary" "session")))
                                            (list
                                             :tag "Mac OS internet Keychain"
                                             (const :format ""
                                                    :value :macos-keychain-internet)
                                             (choice :tag "Keychain to use"
                                                     (string :tag "internet Keychain path")
                                                     (const :tag "default" default)))
                                            (list
                                             :tag "Mac OS generic Keychain"
                                             (const :format ""
                                                    :value :macos-keychain-generic)
                                             (choice :tag "Keychain to use"
                                                     (string :tag "generic Keychain path")
                                                     (const :tag "default" default))))
                                    (repeat :tag "Extra Parameters" :inline t
                                            (choice :tag "Extra parameter"
                                                    :value (:host t)
                                                    (list
                                                     :tag "Host" :inline t
                                                     (const :format "" :value :host)
                                                     (choice :tag "Host (machine) choice"
                                                             (const :tag "Any" t)
                                                             (regexp
                                                              :tag "Regular expression")))
                                                    (list
                                                     :tag "Protocol" :inline t
                                                     (const :format "" :value :port)
                                                     (choice
                                                      :tag "Protocol"
                                                      (const :tag "Any" t)
                                                      ,@*auth-source-protocols-customize*))
                                                    (list :tag "User" :inline t
                                                          (const :format "" :value :user)
                                                          (choice
                                                           :tag "Personality/Username"
                                                           (const :tag "Any" t)
                                                           (string
                                                            :tag "Name"))))))
                              (sexp :tag "A data structure (external provider)"))))
      :link '(custom-manual "(auth) Help for users"))

    (define-custom *auth-source-gpg-encrypt-to* #t
      "List of recipient keys that `authinfo.gpg' encrypted to.
If the value is not a list, symmetric encryption will be used."
      :version "24.1"
      :type '(choice (const :tag "Symmetric encryption" t)
                     (repeat :tag "Recipient public keys"
                             (string :tag "Recipient public key"))))

    (define (%nil? value)
      ;; Emacs's nil is two objects here: `#f` and the empty list, and
      ;; the empty list is *true* in Scheme. Every test in this file
      ;; that Emacs writes as a plain `(not X)' or `(if X ...)' over a
      ;; value that can be a list goes through this.
      ;;--------------------------------------------------------------
      (or (not value) (null? value)))

    (define (auth-source-do-debug . msg)
      (when (*auth-source-debug*)
        (apply auth-source-do-warn msg)))

    (define (auth-source-do-trivia . msg)
      (when (or (eq? (*auth-source-debug*) 'trivia)
                (procedure? (*auth-source-debug*)))
        (apply auth-source-do-warn msg)))

    (define (auth-source-do-warn . msg)
      (apply
       ;; set logger to either the function in auth-source-debug or 'message
       ;; note that it will be 'message if auth-source-debug is nil
       (if (procedure? (*auth-source-debug*))
           (*auth-source-debug*)
           message)
       msg))

    (define (auth-source-read-char-choice prompt choices)
      "Read one of CHOICES by `read-char-choice', or `read-char'.
Only one of CHOICES will be returned.  The PROMPT is augmented
with \"[a/b/c] \" if CHOICES is \\(?a ?b ?c)."
      ;; `auth-source.el:337'. `cl-loop for c in choices collect
      ;; (format "%c/" c)' is `map' here; the rest is the C's.
      ;;--------------------------------------------------------------
      (when choices
        (let* ((prompt-choices
                (apply string-append
                       (map (lambda (c) (string-append (string c) "/")) choices)))
               (prompt-choices (string-append "["
                                              (substring prompt-choices 0 -1)
                                              "] "))
               (full-prompt (string-append prompt prompt-choices))
               (k #f))
          (while (not (memq k choices))
            (set! k (read-char-choice full-prompt choices)))
          k)))

    (define *auth-source-backend-parser-functions* (make-parameter '()))
    ;; ^ `(defvar auth-source-backend-parser-functions nil)'
    ;; (`auth-source.el:353'): "List of auth-source parser functions.
    ;; Each function takes an entry from `auth-sources' as parameter and
    ;; returns a backend or nil if the entry is not supported.  Add a
    ;; parser function to this list with `add-hook'.  Searching for a
    ;; backend starts with the first element on the list and stops as
    ;; soon as a function returns non-nil." A parameter because
    ;; `add-hook` is how the three parsers are registered - the same
    ;; reason every hook here is one.

    (define (auth-source-backend-parse entry)
      "Create an `auth-source-backend' from an ENTRY in `auth-sources'."
      ;; `auth-source.el:361'. Emacs's `run-hook-wrapped' calls each
      ;; parser with ENTRY and stops at the first non-nil; a parser that
      ;; answers a backend whose type is `ignore' does not count, which
      ;; is the `when-let*' guard.
      ;;--------------------------------------------------------------
      (let* ((backend
              (run-hook-wrapped
               (*auth-source-backend-parser-functions*)
               (lambda (fun entry)
                 (let ((result (fun entry)))
                   (and result
                        (not (eq? (slot-value result 'type) 'ignore))
                        result)))
               entry)))
        (unless backend
          ;; none of the parsers worked
          (auth-source-do-debug
           "auth-source-backend-parse: invalid backend spec: %S" entry)
          (set! backend (auth-source-backend ':source "" ':type 'ignore)))
        (auth-source-backend-parse-parameters entry backend)))

    (define (auth-source-backends)
      "List of usable backends from `auth-sources'.
Filter out backends with type `ignore'.
A fallback backend is added to ensure, that at least `read-passwd' is called."
      ;; `auth-source.el:382'. Emacs's macro; a procedure here (see the
      ;; header), reading the `*auth-sources*' parameter, so a caller's
      ;; `let` is a `parameterize'.
      ;;--------------------------------------------------------------
      (let ((backends
             (seq-uniq
              (seq-keep
               (lambda (entry)
                 (let ((backend (auth-source-backend-parse entry)))
                   (and backend
                        (not (eq? (slot-value backend 'type) 'ignore))
                        backend)))
               (*auth-sources*)))))
        ;; Emacs's `(or ... fallback)': the empty list is true in Scheme,
        ;; so the fallback is an `if`, not an `or`.
        (if (pair? backends)
            backends
            ;; Fallback.
            (list (auth-source-backend
                   ':source ""
                   ':type 'read-passwd
                   ':search-function auth-source-read-passwd-search
                   ':create-function auth-source-read-passwd-create)))))

    (define (auth-source-keys spec)
      "Return keys from SPEC."
      ;; `auth-source.el:399': `(cl-loop for i below (length spec) by 2
      ;; collect (nth i spec))'. A procedure here (the macro's argument
      ;; is evaluated once either way).
      ;;--------------------------------------------------------------
      (let loop ((i 0) (acc '()))
        (if (>= i (length spec))
            (reverse acc)
            (loop (+ i 2) (cons (nth i spec) acc)))))

    (define *auth-source-ignored-keys* (make-parameter
      '(:create :delete :max :backend :label :require :type)))
    ;; ^ `(defconst auth-source-ignored-keys ...)` (`auth-source.el:404'):
    ;; "List of meta keys to be ignored in data stores." A parameter
    ;; because `auth-source-macos-keychain-search` `let`-binds it around
    ;; its call to `auth-source-search-spec` - the convention's test.

    (define (auth-source-search-keys spec)
      "Filter out ignored keys from SPEC."
      ;; `auth-source.el:408'.
      ;;--------------------------------------------------------------
      (seq-difference (auth-source-keys spec) (*auth-source-ignored-keys*)))

    (define (auth-source-returned-keys spec)
      "Needed keys (always including host, login, port, and secret)."
      ;; `auth-source.el:412'.
      ;;--------------------------------------------------------------
      (seq-union '(:host :login :port :secret) (auth-source-search-keys spec)))

    (define (auth-source-search-spec spec)
      "Build a search spec without the ignored keys.
If a search key is nil or t (match anything), skip it."
      ;; `auth-source.el:416'.
      ;;--------------------------------------------------------------
      (apply append
             (map (lambda (k)
                    (let ((v (plist-get spec k)))
                      (when (and v (not (eq? v #t)))
                        (list k (auth-source-ensure-strings v)))))
                  (auth-source-search-keys spec))))

    (define-custom *auth-source-ignore-non-existing-file* #t
      "If set non-nil, file-based backends are ignored if the file does not exist.
Consequently, no newly created entry is saved in such a backend when
this user option is non-nil.

Supported backend types are `netrc', `plstore' and `json'."
      :version "31.1"
      :type 'boolean)

    (define (auth-source-backends-parser-file entry)
      ;; `auth-source.el:435'. Take just a file name use it as a
      ;; netrc/plist file, matching any user, host, and protocol.
      ;;--------------------------------------------------------------
      (when (string? entry)
        (set! entry (list ':source entry)))
      (let* ((source (plist-get entry ':source))
             (source-without-gpg
              (if (and (string? source)
                       (equal? (file-name-extension source) "gpg"))
                  (file-name-sans-extension source)
                  (or source "")))
             (extension (or (and (string? source-without-gpg)
                                 (file-name-extension source-without-gpg))
                            "")))
        (cond
         ((or (not (string? source))
              (and (*auth-source-ignore-non-existing-file*)
                   (not (file-exists-p source))))
          (auth-source-do-debug
           "auth-source-backend-parse: not existing file, ignoring spec: %S" entry)
          (auth-source-backend
           ':source ""
           ':type 'ignore))
         ((equal? extension "plist")
          ;; The plstore backend is not ported (`auth-source.el:460'):
          ;; its search function signals the gap when something asks
          ;; for it, and the declaration below is why a `.plist' source
          ;; still parses.
          (auth-source-backend
           ':source source
           ':type 'plstore
           ':search-function auth-source-plstore-search
           ':create-function auth-source-plstore-create
           ':data #f))
         ((member-ignore-case extension '("json"))
          (auth-source-backend
           ':source source
           ':type 'json
           ':search-function auth-source-json-search))
         (else
          (auth-source-backend
           ':source source
           ':type 'netrc
           ':search-function auth-source-netrc-search
           ':create-function auth-source-netrc-create)))))

    ;; Note this function should be last in the parser functions, so we add it first
    (add-hook *auth-source-backend-parser-functions*
              auth-source-backends-parser-file)

    (define (auth-source-backends-parser-macos-keychain entry)
      ;; `auth-source.el:481'. Take macos-keychain-{internet,generic}:XYZ
      ;; and use it as macOS Keychain "XYZ" matching any user, host, and
      ;; protocol.
      ;;--------------------------------------------------------------
      (when (and (string? entry)
                 (string-match "^macos-keychain-internet:\\(.+\\)" entry))
        (set! entry (list ':source (list ':macos-keychain-internet
                                         (match-string 1 entry)))))
      (when (and (string? entry)
                 (string-match "^macos-keychain-generic:\\(.+\\)" entry))
        (set! entry (list ':source (list ':macos-keychain-generic
                                         (match-string 1 entry)))))
      ;; take 'macos-keychain-internet or generic and use it as a Mac OS
      ;; Keychain collection matching any user, host, and protocol
      (when (or (eq? entry 'macos-keychain-internet)
                (and (string? entry)
                     (string=? entry "macos-keychain-internet")))
        (set! entry '(:source (:macos-keychain-internet default))))
      (when (or (eq? entry 'macos-keychain-generic)
                (and (string? entry)
                     (string=? entry "macos-keychain-generic")))
        (set! entry '(:source (:macos-keychain-generic default))))
      (cond
       ;; the macOS Keychain
       ((and
         (not (null? (plist-get entry ':source))) ; the source must not be nil
         (list? (plist-get entry ':source))       ; and it must be a list
         (or
          (plist-get (plist-get entry ':source) ':macos-keychain-generic)
          (plist-get (plist-get entry ':source) ':macos-keychain-internet)))
        (let* ((source-spec (plist-get entry ':source))
               (keychain-generic (plist-get source-spec ':macos-keychain-generic))
               (keychain-type (if keychain-generic
                                  'macos-keychain-generic
                                  'macos-keychain-internet))
               (source (plist-get source-spec (if keychain-generic
                                                  ':macos-keychain-generic
                                                  ':macos-keychain-internet))))
          (when (symbol? source)
            (set! source (symbol->string source)))
          (auth-source-backend
           ':source source
           ':type keychain-type
           ':search-function auth-source-macos-keychain-search
           ':create-function auth-source-macos-keychain-create)))
       (else
        (auth-source-do-debug
         "auth-source-backend-parse: no macos keychain, ignoring spec: %S" entry)
        (auth-source-backend
         ':source ""
         ':type 'ignore))))

    (add-hook *auth-source-backend-parser-functions*
              auth-source-backends-parser-macos-keychain)

    (define (auth-source-backends-parser-secrets entry)
      ;; `auth-source.el:536'. Take secrets:XYZ and use it as a Secrets
      ;; API collection "XYZ" matching any user, host, and protocol.
      ;;
      ;; **The Secrets backend is not ported** (it needs D-Bus and
      ;; `secrets.el`), and `secrets-enabled` is `#f`, so the big
      ;; condition is false and the `cond` answers nil - which is the
      ;; branch Emacs itself takes when `(require 'secrets)` fails. The
      ;; `(require 'secrets nil t)` call itself is spelled as the fact
      ;; it would answer.
      ;;--------------------------------------------------------------
      (when (and (string? entry) (string-match "^secrets:\\(.+\\)" entry))
        (set! entry (list ':source (list ':secrets (match-string 1 entry)))))
      ;; take 'default and use it as a Secrets API default collection
      ;; matching any user, host, and protocol
      (when (eq? entry 'default)
        (set! entry '(:source (:secrets default))))
      (cond
       ;; the Secrets API.  We require the package, in order to have a
       ;; defined value for `secrets-enabled'.
       ((and
         (not (null? (plist-get entry ':source))) ; the source must not be nil
         (list? (plist-get entry ':source))       ; and it must be a list
         (not (null? (plist-get
                      (plist-get entry ':source)
                      ':secrets))) ; the source must have :secrets
         secrets-enabled)                ; and that API must be enabled
        ;; not reachable: `secrets-enabled` is #f
        #f)
       ;; Emacs's `cond` answers nil when no clause matches; Scheme's
       ;; answers the unspecified value, which is true. The parser's
       ;; caller tests the answer.
       (else #f)))

    (add-hook *auth-source-backend-parser-functions*
              auth-source-backends-parser-secrets)

    (define (auth-source-backend-parse-parameters entry backend)
      "Fill in the extra `auth-source-backend' parameters of ENTRY.
Using the plist ENTRY, get the :host, :port, and :user search
parameters."
      ;; `auth-source.el:582'.
      ;;--------------------------------------------------------------
      (let ((entry (if (string? entry)
                       #f
                       entry))
            (val #f))
        ;; `(when (setq val ...) ...)' - a `set!' in the test is the
        ;; unspecified value, which is true, so the value is taken in a
        ;; `let` first (the tree's setq-as-value rule).
        (set! val (plist-get entry ':host))
        (when val (oset backend 'host val))
        (set! val (plist-get entry ':user))
        (when val (oset backend 'user val))
        (set! val (plist-get entry ':port))
        (when val (oset backend 'port val)))
      backend)

    (define (auth-source-file-name-p file)
      "Say whether FILE is used by `auth-sources'."
      ;; `auth-source.el:600'.
      ;;--------------------------------------------------------------
      (let* ((backends (auth-source-backends))
             (files
              (mapcar (lambda (x)
                        (when (member (slot-value x 'type) '(json netrc plstore))
                          (slot-value x 'source)))
                      backends)))
        (member (expand-file-name file)
                (mapcar expand-file-name (remq #f files)))))

    ;;----------------------------------------------------------------
    ;; `auth-source-search' and its cache (`auth-source.el:615'-`:997').
    ;;----------------------------------------------------------------

    (define (auth-source-search . spec)
      "Search or modify authentication backends according to SPEC.

This function parses `auth-sources' for matches of the SPEC
plist.  It can optionally create or update an authentication
token if requested.  A token is just a standard Emacs property
list with a :secret property that can be a function; all the
other properties will always hold scalar values.

Typically the :secret property, if present, contains a password.

Common search keys are :max, :host, :port, and :user.  In
addition, :create specifies if and how tokens will be created.
Finally, :type can specify which backend types you want to check.

A string value is always matched literally.  A symbol is matched
as its string value, literally.  All the SPEC values can be
single values (symbol or string) or lists thereof (in which case
any of the search terms matches).

:create t means to create a token if possible.

A new token will be created if no matching tokens were found.
The new token will have only the keys the backend requires.  For
the netrc backend, for instance, that's the user, host, and
port keys.

:create \\='(A B C)  or
:create \\='(:unencrypted A B :encrypted C)
also means to create a token if possible.

:require (A B C) means that only results that contain those
tokens will be returned.  Thus for instance requiring :secret
will ensure that any results will actually have a :secret
property.

:delete t means to delete any found entries.  nil by default.
Use `auth-source-delete' in Lisp code instead of calling
`auth-source-search' directly with this parameter.

:type (X Y Z) will check only those backend types.  `netrc' and
`secrets' are the only ones supported right now.

:max N means to try to return at most N items (defaults to 1).
More than N items may be returned, depending on the search and
the backend.

When :max is 0 the function will return just t or nil to indicate
if any matches were found.

:host (X Y Z) means to match only hosts X, Y, or Z according to
the match rules above.  Defaults to t.

:user (X Y Z) means to match only users X, Y, or Z according to
the match rules above.  Defaults to t.

:port (P Q R) means to match only protocols P, Q, or R.
Defaults to t.

:K (V1 V2 V3) for any other key K will match values V1, V2, or
V3 (note the match rules above).

The return value is a list with at most :max tokens.  Each token
is a plist with keys :backend :host :port :user, plus any other
keys provided by the backend (notably :secret).  But note the
exception for :max 0, which see above.

The token can hold a :save-function key.  If you call that, the
user will be prompted to save the data to the backend.  You can't
request that this should happen right after creation, because
`auth-source-search' has no way of knowing if the token is
actually useful.  So the caller must arrange to call this function.

The token's :secret key can hold a function.  In that case you
must call it to obtain the actual value."
      ;; `auth-source.el:615'. The `&key max require create delete' and
      ;; `&allow-other-keys' are plist reads here (see the header); the
      ;; `cl-assert's are explicit checks with the C's messages.
      ;;--------------------------------------------------------------
      (let* ((backends (auth-source-backends))
             (max (let ((m (plist-get spec ':max))) (if m m 1)))
             (cached (auth-source-remembered-p spec))
             ;; note that we may have cached results but found is still nil
             ;; (there were no results from the search)
             (found (auth-source-recall spec))
             (filtered-backends #f))
        (if (and cached (*auth-source-do-cache*))
            (auth-source-do-debug
             "auth-source-search: found %d CACHED results matching %S"
             (if found (length found) 0) spec)
            (begin
              ;; (cl-assert (or (eq t create) (listp create)) t "...")
              (let ((create (plist-get spec ':create)))
                (unless (or (eq? create #t) (%nil? create) (list? create))
                  (error "Invalid auth-source :create parameter (must be t or a list): ~a ~a"
                         create spec)))
              (unless (let ((require (plist-get spec ':require)))
                        (or (%nil? require) (list? require)))
                (error "Invalid auth-source :require parameter (must be a list): ~a"
                       (plist-get spec ':require)))

              (set! filtered-backends (copy-sequence backends))
              (for-each
               (lambda (backend)
                 (let/ec done
                   (for-each
                    (lambda (key)
                      ;; ignore invalid slots
                      (guard (e (#t #f))
                        (unless (auth-source-search-collection
                                 (plist-get spec key)
                                 (slot-value
                                  backend
                                  (if (keywordp key)
                                      (intern-soft (substring (symbol->string key) 1))
                                      key)))
                          (set! filtered-backends (delq backend filtered-backends))
                          (done #f))))
                    (auth-source-search-keys spec))))
               backends)

              (auth-source-do-trivia
               "auth-source-search: found %d backends matching %S"
               (length filtered-backends) spec)

              ;; (debug spec "filtered" filtered-backends)
              ;; First go through all the backends without :create, so we can
              ;; query them all.
              (set! found (auth-source-search-backends filtered-backends
                                                       spec
                                                       ;; to exit early
                                                       max
                                                       ;; create is always nil here
                                                       #f
                                                       (plist-get spec ':delete)
                                                       (plist-get spec ':require)))

              (auth-source-do-debug
               "auth-source-search: found %d results (max %d) matching %S"
               (if found (length found) 0) max spec)

              ;; If we didn't find anything, then we allow the backend(s) to
              ;; create the entries.
              (when (and (plist-get spec ':create)
                         (%nil? found))
                (set! found (auth-source-search-backends filtered-backends
                                                         spec
                                                         ;; to exit early
                                                         max
                                                         (plist-get spec ':create)
                                                         (plist-get spec ':delete)
                                                         (plist-get spec ':require)))
                (auth-source-do-debug
                 "auth-source-search: CREATED %d results (max %d) matching %S"
                 (if found (length found) 0) max spec))

              ;; note we remember the lack of result too, if it's applicable
              (when (*auth-source-do-cache*)
                (auth-source-remember spec found))))

        (if (= max 0)
            (not (null? found))
            found)))

    (define (auth-source-search-backends backends spec max create delete require)
      ;; `auth-source.el:838'.
      ;;--------------------------------------------------------------
      (let ((max (if (= max 0) 1 max)) ; stop with 1 match if we're asked for zero
            (matches '()))
        (for-each
         (lambda (backend)
           (when (> max (length matches)) ; if we need more matches...
             (let* ((bmatches
                     (apply (slot-value backend 'search-function)
                            (append
                             (list ':backend backend
                                   ':type (slot-value backend 'type)
                                   ;; note we're overriding whatever the spec
                                   ;; has for :max, :require, :create, and :delete
                                   ':max max
                                   ':require require
                                   ':create create
                                   ':delete delete)
                             spec))))
               (when (not (%nil? bmatches))
                 (auth-source-do-trivia
                  "auth-source-search-backend: got %d (max %d) in %s:%s matching %S"
                  (length bmatches) max
                  (slot-value backend 'type)
                  (slot-value backend 'source)
                  spec)
                 (set! matches (append matches bmatches))))))
         backends)
        matches))

    (define (auth-source-delete . spec)
      "Delete entries from the authentication backends according to SPEC.
Calls `auth-source-search' with the :delete property in SPEC set to t.
The backend may not actually delete the entries.

Returns the deleted entries."
      ;; `auth-source.el:864'.
      ;;--------------------------------------------------------------
      (apply auth-source-search (plist-put spec ':delete #t)))

    (define (auth-source-search-collection collection value)
      "Return t if VALUE is t or COLLECTION is t or COLLECTION contains VALUE."
      ;; `auth-source.el:872'.
      ;;--------------------------------------------------------------
      (when (and (not (pair? collection)) (not (eq? collection #t)))
        (set! collection (list collection)))

      ;; (debug :collection collection :value value)
      (or (eq? collection #t)
          (eq? value #t)
          (equal? collection value)
          (member value collection)))

    (define *auth-source-netrc-cache* '())
    ;; ^ `(defvar auth-source-netrc-cache nil)` (`auth-source.el:883'). A
    ;; plain variable: it is `setq`-ed (through `auth-source--aput`) and
    ;; read, never `let`-bound.

    (define-command (auth-source-forget-all-cached)
      "Forget all cached auth-source data."
      ;; `auth-source.el:885'.
      ;;--------------------------------------------------------------
      (interactive)
      (maphash (lambda (key _password)
                 (when (eq? 'auth-source (car-safe key))
                   ;; remove that key
                   (password-cache-remove key)))
               password-data)
      (set! *auth-source-netrc-cache* '()))

    (define (auth-source-format-cache-entry spec)
      "Format SPEC entry to put it in the password cache."
      ;; `auth-source.el:895'. `(auth-source . ,spec)'.
      ;;--------------------------------------------------------------
      (cons 'auth-source spec))
      ;; `(auth-source . ,(auth-source-search-spec spec)))

    (define (auth-source-remember spec found)
      "Remember FOUND search results for SPEC."
      ;; `auth-source.el:900'. Emacs `let`-binds `password-cache-expiry';
      ;; the tree binds the parameter of the same meaning.
      ;;--------------------------------------------------------------
      (parameterize ((*password-cache-expiry* (*auth-source-cache-expiry*)))
        (password-cache-add
         (auth-source-format-cache-entry spec) found)))

    (define (auth-source-recall spec)
      "Recall FOUND search results for SPEC."
      ;; `auth-source.el:906'.
      ;;--------------------------------------------------------------
      (password-read-from-cache (auth-source-format-cache-entry spec)))

    (define (auth-source-remembered-p spec)
      "Check if SPEC is remembered."
      ;; `auth-source.el:910'.
      ;;--------------------------------------------------------------
      (password-in-cache-p
       (auth-source-format-cache-entry spec)))

    (define (auth-source-forget spec)
      "Forget any cached data matching SPEC exactly.

This is the same SPEC you passed to `auth-source-search'.
Returns t or nil for forgotten or not found."
      ;; `auth-source.el:915'.
      ;;--------------------------------------------------------------
      (password-cache-remove (auth-source-format-cache-entry spec)))

    (define (auth-source-forget+ . spec)
      "Forget any cached data matching SPEC.  Return forgotten count.

This is not a full `auth-source-search' spec but works similarly.
For instance, \\(:host \"myhost\" \"yourhost\") would find all the
cached data that was found with a search for those two hosts,
while \\(:host t) would find all host entries."
      ;; `auth-source.el:922'.
      ;;--------------------------------------------------------------
      (let ((count 0))
        (maphash
         (lambda (key _password)
           (when (and (eq? 'auth-source (car-safe key))
                      ;; and the spec matches what was stored in the cache
                      (auth-source-specmatchp spec (cdr key)))
             ;; remove that key
             (password-cache-remove key)
             (set! count (+ count 1))))
         password-data)
        count))

    (define (auth-source-specmatchp spec stored)
      ;; `auth-source.el:941'. The `cl-dolist ... (cl-return 'no)' is a
      ;; `let/ec'.
      ;;--------------------------------------------------------------
      (let ((keys (auth-source-keys spec)))
        ;; The C answers `(not (eq <dolist> 'no))', so the escape answers
        ;; `'no' and the ordinary path answers t.
        (let/ec no
          (for-each (lambda (key)
                      (unless (auth-source-search-collection
                               (plist-get stored key)
                               (plist-get spec key))
                        (no #f)))
                    keys)
          #t)))

    (define (auth-info-password auth-info)
      "Return the :secret password from the AUTH-INFO."
      ;; `auth-source.el:950'.
      ;;--------------------------------------------------------------
      (let ((secret (plist-get auth-info ':secret)))
        (if (procedure? secret)
            (secret)
            secret)))

    (define (auth-source-pick-first-password . spec)
      "Pick the first secret found by applying `auth-source-search' to SPEC."
      ;; `auth-source.el:957'.
      ;;--------------------------------------------------------------
      (auth-info-password
       (car-safe (apply auth-source-search (plist-put spec ':max 1)))))

    (define (auth-source-format-prompt prompt alist)
      "Format PROMPT using %x (for any character x) specifiers in ALIST.
Remove trailing \": \"."
      ;; `auth-source.el:962'. The `%%%c' format is built with
      ;; `string-append' - a character is a string of one in this tree -
      ;; and the replacement is literal (the C's fifth argument).
      ;;--------------------------------------------------------------
      (set! prompt (replace-regexp-in-string ":\\s-*$" "" prompt))
      (for-each (lambda (cell)
                  (let ((c (nth 0 cell))
                        (v (nth 1 cell)))
                    (when (and c v)
                      (set! prompt (replace-regexp-in-string
                                    (string-append "%" (string c))
                                    (format "%s" v)
                                    prompt #f #t)))))
                alist)
      prompt)

    (define (auth-source-ensure-strings values)
      ;; `auth-source.el:975'. `ensure-list' then numbers to strings.
      ;;--------------------------------------------------------------
      (if (eq? values #t)
          values
          (mapcar (lambda (value)
                    (if (number? value)
                        (format "%s" value)
                        value))
                  (ensure-list values))))

    (define (auth-source--aput-1 alist key val)
      ;; `auth-source.el:985': the C's in-place alist update.
      ;;--------------------------------------------------------------
      (let ((seen '())
            (rest alist))
        (while (and (pair? rest) (not (equal? key (caar rest))))
          (set! seen (cons (car rest) seen))
          (set! rest (cdr rest)))
        (cons (cons key val)
              (if (null? rest) alist
                  (nconc (nreverse seen)
                         (if (equal? key (caar rest)) (cdr rest) rest))))))

    (define-syntax auth-source--aput
      (syntax-rules ()
        ((_ var key val) (set! var (auth-source--aput-1 var key val)))))

    (define (auth-source--aget alist key)
      ;; `auth-source.el:997'. `(cdr (assoc key alist))', with the nil
      ;; answer for an absent key that Emacs's `(cdr nil)' gives.
      ;;--------------------------------------------------------------
      (let ((cell (assoc key alist)))
        (if cell (cdr cell) #f)))

    ;;----------------------------------------------------------------
    ;; Backend specific parsing: just read the password
    ;; (`auth-source.el:1002'-`:1116').
    ;;----------------------------------------------------------------

    (define (auth-source-read-passwd-search . spec)
      "Search in password cache; spec is like `auth-source'."
      ;; `auth-source.el:1002'.
      ;;--------------------------------------------------------------
      (when (plist-get spec ':delete)
        (error "The `read-passwd' auth-source backend doesn't support deletion yet"))

      (let ((found (auth-source-recall (auth-source-search-spec spec))))
        (cond
         ((not (%nil? found)) (list found))
         ((not (%nil? (plist-get spec ':create)))
          (apply (slot-value (plist-get spec ':backend) 'create-function) spec)))))

    (define (auth-source-read-passwd-create . spec)
      ;; `auth-source.el:1017'.
      ;;--------------------------------------------------------------
      (let* ((base-required '(host user port secret))
             ;; we know (because of an assertion in auth-source-search) that the
             ;; :create parameter is either t or a list (which includes nil)
             (current-data (car-safe (apply auth-source-search
                                       (list ':max 1
                                             ':host (plist-get spec ':host)
                                             ':user (plist-get spec ':user)
                                             ':port (plist-get spec ':port)))))
             ;; `valist' is an alist
             (valist '())
             ;; `artificial' will be returned if no creation is needed
             (artificial '()))

        ;; only for base required elements (defined as function parameters):
        ;; fill in the valist with whatever data we may have from the search
        ;; we complete the first value if it's a list and use the value otherwise
        (for-each
         (lambda (br)
           (let ((val (plist-get spec (auth-source--symbol-keyword br))))
             (when val
               (let ((br-choice (cond
                                 ;; all-accepting choice (predicate is t)
                                 ((eq? #t val) #f)
                                 ;; just the value otherwise
                                 (else val))))
                 (when br-choice
                   (auth-source--aput valist br br-choice))))))
         base-required)

        ;; for each required element
        (for-each
         (lambda (r)
           (let* ((data (auth-source--aget valist r))
                  ;; take the first element if the data is a list
                  (data (or (auth-source-netrc-element-or-first data)
                            (plist-get current-data
                                       (auth-source--symbol-keyword r))))
                  ;; this is the default to be offered
                  (given-default (auth-source--aget
                                  (*auth-source-creation-defaults*) r))
                  ;; the default supplementals are simple:
                  ;; for the user, try `given-default' and then (user-login-name);
                  ;; otherwise take `given-default'
                  (default (cond
                            ((and (not given-default) (eq? r 'user))
                             (user-login-name))
                            (else given-default)))
                  (printable-defaults (list
                                       (cons 'user
                                             (or
                                              (auth-source-netrc-element-or-first
                                               (auth-source--aget valist 'user))
                                              (plist-get artificial ':user)
                                              "[any user]"))
                                       (cons 'host
                                             (or
                                              (auth-source-netrc-element-or-first
                                               (auth-source--aget valist 'host))
                                              (plist-get artificial ':host)
                                              "[any host]"))
                                       (cons 'port
                                             (or
                                              (auth-source-netrc-element-or-first
                                               (auth-source--aget valist 'port))
                                              (plist-get artificial ':port)
                                              "[any port]"))))
                  (prompt (or (auth-source--aget (*auth-source-creation-prompts*) r)
                              (case r
                                ((secret) "%p password for %u@%h")
                                ((user) "%p user name for %h")
                                ((host) "%p host name for user %u")
                                ((port) "%p port for %u@%h")
                                (else (format "Enter %s (%%u@%%h:%%p)" r)))))
                  (prompt (auth-source-format-prompt
                           prompt
                           (list (list #\u (auth-source--aget printable-defaults 'user))
                                 (list #\h (auth-source--aget printable-defaults 'host))
                                 (list #\p (auth-source--aget printable-defaults 'port))))))

             ;; Store the data, prompting for the password if needed.
             (set! data (or data
                            (if (eq? r 'secret)
                                (or (%auth-source-eval-default default)
                                    (read-passwd  (format-prompt prompt #f)))
                                (if (and (string? default) (*auth-source-save-behavior*))
                                    (read-from-minibuffer
                                     (format-prompt prompt default) #f #f #f default)
                                    (%auth-source-eval-default default)))))

             (when data
               (set! artificial
                     (plist-put artificial
                                (auth-source--symbol-keyword r)
                                (if (eq? r 'secret)
                                    (let ((data data))
                                      (lambda () data))
                                    data))))))
         base-required)

        (list artificial)))

    ;;----------------------------------------------------------------
    ;; Backend specific parsing: netrc/authinfo backend
    ;; (`auth-source.el:1118'-`:1758').
    ;;----------------------------------------------------------------

    (define (%auth-source-eval-default default)
      ;; Emacs's `(eval default)' (`auth-source.el:1113'): a default
      ;; from `auth-source-creation-defaults' is a *form*. The values
      ;; this tree stores are strings and numbers, for which `eval'
      ;; answers the value; a procedure is called, which is the nearest
      ;; a scheme gets to a form that computes itself.
      ;;--------------------------------------------------------------
      (if (procedure? default) (default) default))

    (define (auth-source-netrc-parse-all file)
      "Parse FILE and return all entries."
      ;; `auth-source.el:1118'.
      ;;--------------------------------------------------------------
      (auth-source-netrc-parse ':file file ':allow-null #t))

    ;; (auth-source-netrc-parse :file "~/.authinfo.gpg")
    (define (auth-source-netrc-parse . args)
      "Parse FILE and return a list of matching entries in the file.
If ALLOW-NULL, allow nil values of HOST, USER and PORT to match.

Note that the MAX parameter is used so we can exit the parse early."
      ;; `auth-source.el:1123'. `&key file max host user port require
      ;; allow-null &allow-other-keys'.
      ;;--------------------------------------------------------------
      (let ((file (plist-get args ':file))
            (max (plist-get args ':max))
            (host (plist-get args ':host))
            (user (plist-get args ':user))
            (port (plist-get args ':port))
            (require (plist-get args ':require))
            (allow-null (plist-get args ':allow-null)))
        (if (list? file)
            ;; We got already parsed contents; just return it.
            file
            (when (file-exists-p file)
              (set! port (auth-source-ensure-strings port))
              (with-temp-buffer
                (let* ((max (or max 5000))       ; sanity check: default to stop at 5K
                       (modified 0)
                       (cached (let ((cell (assoc file *auth-source-netrc-cache*)))
                                 (and cell (cdr cell))))
                       (cached-mtime (plist-get cached ':mtime))
                       (cached-secrets (plist-get cached ':secret))
                       (check (lambda (alist)
                                (and alist
                                     (or
                                      (and allow-null (%nil? host))
                                      (auth-source-search-collection
                                       host
                                       (or
                                        (auth-source--aget alist "machine")
                                        (auth-source--aget alist "host")
                                        #t)))
                                     (or
                                      (and allow-null (%nil? user))
                                      (auth-source-search-collection
                                       user
                                       (or
                                        (auth-source--aget alist "login")
                                        (auth-source--aget alist "account")
                                        (auth-source--aget alist "user")
                                        #t)))
                                     (or
                                      (and allow-null (%nil? port))
                                      (auth-source-search-collection
                                       port
                                       (or
                                        (auth-source--aget alist "port")
                                        (auth-source--aget alist "protocol")
                                        #t)))
                                     (or
                                      ;; the required list of keys is nil, or
                                      (%nil? require)
                                      ;; every element of require is in n (normalized)
                                      (let ((n (nth 0 (auth-source-netrc-normalize
                                                       (list alist) file))))
                                        (let loop ((reqs require))
                                          (or (null? reqs)
                                              (and (plist-get n (car reqs))
                                                   (loop (cdr reqs))))))))))
                       (result '()))

                  (if (and (procedure? cached-secrets)
                           (time-equal-p
                            cached-mtime
                            (file-attribute-modification-time
                             (file-attributes file))))
                      (begin
                        (auth-source-do-trivia
                         "auth-source-netrc-parse: using CACHED file data for %s"
                         file)
                        (insert (cached-secrets)))
                      (begin
                        (insert-file-contents file)
                        ;; cache all netrc files (used to be just .gpg files)
                        ;; Store the contents of the file obfuscated in memory.
                        (auth-source--aput
                         *auth-source-netrc-cache* file
                         (list ':mtime (file-attribute-modification-time
                                        (file-attributes file))
                               ':secret (let ((v (auth-source--obfuscate (buffer-string))))
                                          (lambda () (auth-source--deobfuscate v)))))))
                  (goto-char (point-min))
                  (let ((entries (auth-source-netrc-parse-entries check max)))
                    ;; `(while (setq alist (pop entries)))' again: the
                    ;; `set!' value is not the test.
                    (let loop ()
                      (when (pair? entries)
                        (set! result (cons (nreverse (car entries)) result))
                        (set! entries (cdr entries))
                        (loop))))

                  (when (< 0 modified)
                    ;; The C's epa-file local-variable block is GPG's and
                    ;; is not carried (see the header); the save it
                    ;; guards is below.
                    (when (y-or-n-p (format "Save file %s? (%d deletions)"
                                            file modified))
                      (write-region (point-min) (point-max) file #f 'silent)
                      (auth-source-do-debug
                       "auth-source-netrc-parse: modified %d lines in %s"
                       modified file)))

                  (nreverse result)))))))

    (define (auth-source-netrc-parse-next-interesting)
      "Advance to the next interesting position in the current buffer."
      ;; `auth-source.el:1223'.
      ;;--------------------------------------------------------------
      (skip-chars-forward "\t ")
      ;; If we're looking at a comment or are at the end of the line, move forward
      (while (or (eqv? (char-after) #\#)
                 (and (eolp)
                      (not (eobp))))
        (forward-line 1)
        (skip-chars-forward "\t ")))

    (define (auth-source-netrc-looking-at-token)
      "Say whether the next think in the buffer is a token (password, etc).
Match data is altered to reflect the token."
      ;; `auth-source.el:1233'.
      ;;--------------------------------------------------------------
      (or (looking-at "'\\([^']*\\)'")
          (looking-at "\"\\([^\"]*\\)\"")
          (looking-at "\\([^ \t\n]+\\)")))

    (define (auth-source-netrc-parse-one)
      "Read one thing from the current buffer."
      ;; `auth-source.el:1240'.
      ;;--------------------------------------------------------------
      (auth-source-netrc-parse-next-interesting)

      ;; Emacs's `when` answers nil when its test fails; Scheme's answers
      ;; the unspecified value, which the caller's `while` would read as
      ;; "a token" for ever. The `if` is the C's answer written out.
      (if (auth-source-netrc-looking-at-token)
          (begin
            (forward-char (%length (match-string 0)))
            (let ((result (match-string-no-properties 1)))
              (auth-source-netrc-parse-next-interesting)
              result))
          #f))

    ;; with thanks to org-mode
    (define (auth-source-current-line . pos-arg)
      ;; `auth-source.el:1251' (`defsubst').
      ;;--------------------------------------------------------------
      (let ((pos (and (pair? pos-arg) (car pos-arg))))
        (save-excursion
          (and pos (goto-char pos))
          ;; works also in narrowed buffer, because we start at 1, not point-min
          (+ (if (bolp) 1 0) (count-lines 1 (point))))))

    (define (auth-source-netrc-parse-entries check max)
      "Parse up to MAX netrc entries, passed by CHECK, from the current buffer."
      ;; `auth-source.el:1257'.
      ;;
      ;; **The C's `while (setq item ...)' is a named `let' here.** A
      ;; `set!' answers the unspecified value in this Scheme, which is
      ;; true, so `(while (set! item (parse-one)))' never stops.
      ;;--------------------------------------------------------------
      (let ((adder (lambda (check alist all)
                     (when (and
                            alist
                            (> max (length all))
                            (check alist))
                       (set! all (cons alist all)))
                     all))
            (item #f) (item2 #f) (all '()) (alist '()) (default #f))
        (let loop ()
          (set! item (auth-source-netrc-parse-one))
          (when item
            (set! default (equal? item "default"))
            ;; We're starting a new machine.  Save the old one.
            (when (and (pair? alist)
                       (or default
                           (equal? item "machine")))
              ;; (auth-source-do-trivia
              ;;  "auth-source-netrc-parse-entries: got entry %S" alist)
              (set! all (adder check alist all))
              (set! alist '()))
            ;; In default entries, we don't have a next token.
            ;; We store them as ("machine" . t)
            (if default
                (set! alist (cons (cons "machine" #t) alist))
                ;; Not a default entry.  Grab the next item.
                (let ((value (auth-source-netrc-parse-one)))
                  (set! item2 value)
                  (when value
                    ;; Did we get a "machine" value?
                    (if (equal? item2 "machine")
                        (error
                         "%s: Unexpected `machine' token at line %d"
                         "auth-source-netrc-parse-entries"
                         (auth-source-current-line))
                        (set! alist (cons (cons item item2) alist))))))
            (loop)))

        ;; Clean up: if there's an entry left over, use it.
        (when (pair? alist)
          (set! all (adder check alist all))
          ;; (auth-source-do-trivia
          ;;  "auth-source-netrc-parse-entries: got2 entry %S" alist)
          )
        (nreverse all)))

    (define (auth-source--symbol-keyword symbol)
      ;; `auth-source.el:1352'.
      ;;--------------------------------------------------------------
      (intern (format ":%s" symbol)))

    (define (auth-source-netrc-normalize alist filename)
      ;; `auth-source.el:1355'. Emacs's `(while (setq item (pop entry)))'
      ;; is a named `let' here: the `set!' value is not the test.
      ;;--------------------------------------------------------------
      (mapcar (lambda (entry)
                (let ((ret '()))
                  (let loop ()
                    (when (pair? entry)
                      (let ((item (car entry))
                            (k #f)
                            (v #f))
                        (set! k (car item))
                        (set! v (cdr item))
                        (set! entry (cdr entry))

                        ;; apply key aliases
                        (set! k (cond ((member k '("machine")) "host")
                                      ((member k '("login" "account")) "user")
                                      ((member k '("protocol")) "port")
                                      ((member k '("password")) "secret")
                                      (else k)))

                        ;; Send back the secret in a function (lexical
                        ;; binding).  We slightly obfuscate the passwords
                        ;; (that's the "(mapcar #+' ..)" stuff) to avoid
                        ;; showing the passwords in clear text in backtraces
                        ;; and the like.
                        (when (equal? k "secret")
                          (set! v (let ((lexv (auth-source--obfuscate v))
                                        (token-decoder #f))
                                    (when (string-match "^gpg:" v)
                                      ;; it's a GPG token: it needs EPG to
                                      ;; decrypt, and EPG is not ported (see
                                      ;; the header). The decoder is kept so
                                      ;; the failure happens when a caller
                                      ;; asks for the secret, not when the
                                      ;; file is read.
                                      (set! token-decoder
                                            (lambda (val)
                                              (set! token-decoder #f)
                                              (error "auth-source: a gpg: token needs EPG, which is not ported (%s)" filename))))
                                    (lambda ()
                                      (if token-decoder
                                          (token-decoder
                                           (auth-source--deobfuscate lexv))
                                          (auth-source--deobfuscate lexv))))))
                        (set! ret (plist-put ret
                                             (auth-source--symbol-keyword k)
                                             v))
                        (loop))))
                  ret))
              alist))

    ;; Never change this variable.
    (define auth-source--session-nonce #f)
    ;; ^ `(defvar auth-source--session-nonce nil)` (`auth-source.el:1399').

    (define (auth-source--obfuscate string)
      ;; `auth-source.el:1401'. **The GnuTLS arm is not carried** (no
      ;; GnuTLS here): what is below is the C's `else' branch, the
      ;; one-integer-per-character obfuscation, which is the whole of
      ;; the answer on an Emacs built without GnuTLS.
      ;;--------------------------------------------------------------
      (mapcar (lambda (c) (- (if (char? c) (char->integer c) c) 1)) string))

    (define (auth-source--deobfuscate data)
      ;; `auth-source.el:1437', the non-GnuTLS branch.
      ;;--------------------------------------------------------------
      (apply %string (mapcar (lambda (c) (+ c 1)) data)))

    (define (auth-source-netrc-search . spec)
      "Given a property list SPEC, return search matches from the `:backend'.
See `auth-source-search' for details on SPEC."
      ;; `auth-source.el:1454'.
      ;;--------------------------------------------------------------
      ;; just in case, check that the type is correct (null or same as the backend)
      (let ((backend (plist-get spec ':backend))
            (require (plist-get spec ':require))
            (create (plist-get spec ':create))
            (type (plist-get spec ':type))
            (max (plist-get spec ':max))
            (host (plist-get spec ':host))
            (user (plist-get spec ':user))
            (port (plist-get spec ':port)))
        (unless (or (%nil? type) (eq? type (auth-source-backend-type backend)))
          (error "Invalid netrc search: ~a ~a" type (auth-source-backend-type backend)))

        (let ((results (auth-source-netrc-normalize
                        (auth-source-netrc-parse
                         ':max max
                         ':require require
                         ':file (auth-source-backend-source backend)
                         ':host (or host #t)
                         ':user (or user #t)
                         ':port (or port #t))
                        (auth-source-backend-source backend))))

          ;; if we need to create an entry AND none were found to match
          (when (and create
                     (%nil? results))

            ;; create based on the spec and record the value
            (set! results (or
                           ;; if the user did not want to create the entry
                           ;; in the file, it will be returned
                           (apply (slot-value backend 'create-function) spec)
                           ;; if not, we do the search again without :create
                           ;; to get the updated data.

                           ;; the result will be returned, even if the search fails
                           (apply auth-source-netrc-search
                                  (plist-put spec ':create #f)))))
          results)))

    (define (auth-source-netrc-element-or-first v)
      ;; `auth-source.el:1491'.
      ;;--------------------------------------------------------------
      (if (list? v)
          (nth 0 v)
          v))

    ;; (auth-source-search :host "nonesuch" :type 'netrc :max 1 :create t)
    ;; (auth-source-search :host "nonesuch" :type 'netrc :max 1 :create t :create-extra-keys '((A "default A") (B)))

    (define (auth-source-netrc-create . spec)
      ;; `auth-source.el:1499'.
      ;;--------------------------------------------------------------
      (let* ((backend (plist-get spec ':backend))
             (host (plist-get spec ':host))
             (port (plist-get spec ':port))
             (create (plist-get spec ':create))
             (user (plist-get spec ':user))
             (base-required '(host user port secret))
             ;; we know (because of an assertion in auth-source-search) that the
             ;; :create parameter is either t or a list (which includes nil)
             (create-extra (if (eq? #t create) '() create))
             (current-data (car-safe (apply auth-source-search
                                       (list ':max 1
                                             ':host host
                                             ':user user
                                             ':port port))))
             (required (append base-required create-extra))
             (file (auth-source-backend-source backend))
             (add "")
             ;; Whether to set save-function.
             (save-function #f)
             ;; `valist' is an alist
             (valist '())
             ;; `artificial' will be returned if no creation is needed
             (artificial '()))

        ;; only for base required elements (defined as function parameters):
        ;; fill in the valist with whatever data we may have from the search
        ;; we complete the first value if it's a list and use the value otherwise
        (for-each
         (lambda (br)
           (let ((val (plist-get spec (auth-source--symbol-keyword br))))
             (when val
               (let ((br-choice (cond
                                 ;; all-accepting choice (predicate is t)
                                 ((eq? #t val) #f)
                                 ;; just the value otherwise
                                 (else val))))
                 (when br-choice
                   (auth-source--aput valist br br-choice))))))
         base-required)

        ;; for extra required elements, see if the spec includes a value for them
        (for-each
         (lambda (er)
           (let ((k (auth-source--symbol-keyword er))
                 (keys (auth-source-keys spec)))
             (when (memq k keys)
               (auth-source--aput valist er (plist-get spec k)))))
         create-extra)

        ;; for each required element
        (for-each
         (lambda (r)
           (let* ((data (auth-source--aget valist r))
                  ;; take the first element if the data is a list
                  (data (or (auth-source-netrc-element-or-first data)
                            (plist-get current-data
                                       (auth-source--symbol-keyword r))))
                  ;; this is the default to be offered
                  (given-default (auth-source--aget
                                  (*auth-source-creation-defaults*) r))
                  ;; the default supplementals are simple:
                  ;; for the user, try `given-default' and then (user-login-name);
                  ;; otherwise take `given-default'
                  (default (cond
                            ((and (not given-default) (eq? r 'user))
                             (user-login-name))
                            (else given-default)))
                  (printable-defaults (list
                                       (cons 'user
                                             (or
                                              (auth-source-netrc-element-or-first
                                               (auth-source--aget valist 'user))
                                              (plist-get artificial ':user)
                                              "[any user]"))
                                       (cons 'host
                                             (or
                                              (auth-source-netrc-element-or-first
                                               (auth-source--aget valist 'host))
                                              (plist-get artificial ':host)
                                              "[any host]"))
                                       (cons 'port
                                             (or
                                              (auth-source-netrc-element-or-first
                                               (auth-source--aget valist 'port))
                                              (plist-get artificial ':port)
                                              "[any port]"))))
                  (prompt (or (auth-source--aget (*auth-source-creation-prompts*) r)
                              (case r
                                ((secret) "%p password for %u@%h")
                                ((user) "%p user name for %h")
                                ((host) "%p host name for user %u")
                                ((port) "%p port for %u@%h")
                                (else (format "Enter %s (%%u@%%h:%%p)" r)))))
                  (prompt (auth-source-format-prompt
                           prompt
                           (list (list #\u (auth-source--aget printable-defaults 'user))
                                 (list #\h (auth-source--aget printable-defaults 'host))
                                 (list #\p (auth-source--aget printable-defaults 'port))))))

             ;; Store the data, prompting for the password if needed.
             (set! data (or data
                            (if (eq? r 'secret)
                                ;; Special case prompt for passwords.
                                (let* ((ep (format "Use GPG password tokens in %s?" file))
                                       (gpg-encrypt
                                        (cond
                                         ((eq? (*auth-source-netrc-use-gpg-tokens*) 'never)
                                          'never)
                                         ((list? (*auth-source-netrc-use-gpg-tokens*))
                                          (let ((check (copy-sequence
                                                        (*auth-source-netrc-use-gpg-tokens*)))
                                                (item #f) (ret #f))
                                            (while (pair? check)
                                              (set! item (car check))
                                              (set! check (cdr check))
                                              (when (or (eq? (car item) #t)
                                                        (string-match (car item) file))
                                                (set! ret (cdr item))
                                                (set! check '())))
                                            ret))
                                         (else 'never)))
                                       (plain
                                        (or (%auth-source-eval-default default)
                                            (read-passwd (format-prompt prompt #f)))))
                                  ;; ask if we don't know what to do (in which case
                                  ;; auth-source-netrc-use-gpg-tokens must be a list)
                                  (unless gpg-encrypt
                                    (set! gpg-encrypt (if (y-or-n-p ep) 'gpg 'never))
                                    ;; TODO: save the defcustom now? or ask?
                                    (*auth-source-netrc-use-gpg-tokens*
                                     (cons (list file gpg-encrypt)
                                           (*auth-source-netrc-use-gpg-tokens*))))
                                  (if (eq? gpg-encrypt 'gpg)
                                      ;; `auth-source-epa-make-gpg-token' is
                                      ;; EPG's and is not ported (the
                                      ;; header).
                                      (error "auth-source: creating a gpg: token needs EPG, which is not ported")
                                      plain))
                                (if (and (string? default) (*auth-source-save-behavior*))
                                    (read-from-minibuffer
                                     (format-prompt prompt default) #f #f #f default)
                                    (%auth-source-eval-default default)))))

             (when data
               (set! artificial
                     (plist-put artificial
                                (auth-source--symbol-keyword r)
                                (if (eq? r 'secret)
                                    (let ((data data))
                                      (lambda () data))
                                    data))))

             ;; When r is not an empty string...
             (when (and (string? data)
                        (< 0 (string-length data)))
               (when (eq? r 'secret)
                 (set! save-function
                       (not (and (string-match-p "\"" data)
                                 (string-match-p "'" data)))))
               ;; this function is not strictly necessary but I think it
               ;; makes the code clearer -tzz
               (let ((printer (lambda ()
                                ;; append the key (the symbol name of r)
                                ;; and the value in r
                                (format "%s%s %s"
                                        ;; prepend a space
                                        (if (= 0 (string-length add)) "" " ")
                                        ;; remap auth-source tokens to netrc
                                        (case r
                                          ((user) "login")
                                          ((host) "machine")
                                          ((secret) "password")
                                          ((port) "port") ; redundant but clearer
                                          (else (symbol->string r)))
                                        (cond
                                         ((string-match-p "\"" data)
                                          (format "'%s'" data))
                                         ((string-match-p "['# ]" data)
                                          (format "%S" data))
                                         (else data))))))
                 (set! add (string-append add (printer)))))))
         required)

        (when save-function
          (plist-put
           artificial
           ':save-function
           (let ((file file)
                 (add add))
             (lambda () (auth-source-netrc-saver file add)))))

        (list artificial)))

    (define (auth-source-netrc-saver file add)
      "Save a line ADD in FILE, prompting along the way.
Respects `auth-source-save-behavior'.  Uses
`auth-source-netrc-cache' to avoid prompting more than once."
      ;; `auth-source.el:1680'.
      ;;
      ;; **`?N` saves for this session only**: Emacs
      ;; `customize-save-variable`s the option into the custom file, and
      ;; this tree has no custom-file writer (see the header). The
      ;; message says so.
      ;;--------------------------------------------------------------
      (let* ((key (format "%s %s" file (rfc2104-hash md5 64 16 file add)))
             (cached (assoc key *auth-source-netrc-cache*)))

        (if cached
            (auth-source-do-trivia
             "auth-source-netrc-saver: found previous run for key %s, returning"
             key)
            (with-temp-buffer
              (when (file-exists-p file)
                (insert-file-contents file))
              ;; "we want the new data to be found first, so insert at
              ;; beginning"
              (goto-char (point-min))

              ;; Ask AFTER we've successfully opened the file.
              (let ((prompt (format "Save auth info to file %s? " file))
                    (done (not (eq? (*auth-source-save-behavior*) 'ask)))
                    (bufname "*auth-source Help*")
                    (k #f))
                (while (not done)
                  (set! k (auth-source-read-char-choice prompt (list #\y #\n #\N #\e #\?)))
                  (case k
                    ((#\y) (set! done #t))
                    ((#\?) (save-excursion
                            (with-output-to-temp-buffer bufname
                              (princ
                               (string-append "(y)es, save\n"
                                              "(n)o but use the info\n"
                                              "(N)o and don't ask to save again\n"
                                              "(e)dit the line\n"
                                              "(?) for help as you can see.\n"))
                              ;; Why?  Doesn't with-output-to-temp-buffer already do
                              ;; the exact same thing anyway?  --Stef
                              (set-buffer (*standard-output*))
                              (help-mode))))
                    ((#\n) (set! add "")
                          (set! done #t))
                    ((#\N)
                     (set! add "")
                     (set! done #t)
                     ;; Emacs: `(customize-save-variable
                     ;; 'auth-source-save-behavior nil)'. Session-only
                     ;; here (the header's departure).
                     (*auth-source-save-behavior* #f)
                     (message "auth-source-save-behavior set to nil for this session (saving it to the custom file is not ported)"))
                    ((#\e) (set! add (read-from-minibuffer "Line to add: " add)))
                    (else #f)))

                (when (get-buffer-window bufname)
                  (delete-window (get-buffer-window bufname)))

                ;; Make sure the info is not saved.
                (when (not (*auth-source-save-behavior*))
                  (set! add ""))

                (when (< 0 (string-length add))
                  (unless (bolp)
                    (insert "\n"))
                  (insert add "\n")
                  (write-region (point-min) (point-max) file #f 'silent)
                  ;; Make the .authinfo file non-world-readable.
                  (set-file-modes file #o600)
                  (auth-source-do-debug
                   "auth-source-netrc-create: wrote 1 new line to %s"
                   file)
                  (message "Saved new authentication information to %s" file)
                  #f))))
        (auth-source--aput *auth-source-netrc-cache* key "ran")))

    ;;----------------------------------------------------------------
    ;; Backend specific parsing: Secrets API backend
    ;; (`auth-source.el:1760'-`:2059') - not ported; see the header.
    ;;----------------------------------------------------------------

    ;;----------------------------------------------------------------
    ;; Backend specific parsing: macOS Keychain backend
    ;; (`auth-source.el:2061'-`:2253').
    ;;----------------------------------------------------------------

    (define (auth-source-macos-keychain-search . spec)
      "Search the macOS Keychain; spec is like `auth-source'.

All search keys must match exactly.  If you need substring
matching, do a wider search and narrow it down yourself.

You'll get back all the properties of the token as a plist.

The :type key is either `macos-keychain-internet' or
`macos-keychain-generic'."
      ;; `auth-source.el:2061'. `&key backend create delete type max'.
      ;; The `auth-source-ignored-keys' rebinding is a `parameterize' -
      ;; the variable is a parameter here because this function
      ;; `let`-binds it (see the header).
      ;;--------------------------------------------------------------
      (let ((backend (plist-get spec ':backend))
            (create (plist-get spec ':create))
            (delete (plist-get spec ':delete))
            (type (plist-get spec ':type))
            (max (plist-get spec ':max)))
        (when create
          (error "The macOS Keychain auth-source backend doesn't support creation yet"))
        (when delete
          (error "The macOS Keychain auth-source backend doesn't support deletion yet"))
        (parameterize ((*auth-source-ignored-keys*
                        (seq-difference
                         (seq-union (*auth-source-ignored-keys*) '(:host :port))
                         '(:label))))
          (let* ((coll (auth-source-backend-source backend))
                 (max (or max 5000))     ; sanity check: default to stop at 5K
                 ;; Extract host, port and user from spec
                 (hosts (plist-get spec ':host))
                 (hosts (if (pair? hosts) hosts (list hosts)))
                 (ports (plist-get spec ':port))
                 (ports (if (pair? ports) ports (list ports)))
                 (users (plist-get spec ':user))
                 (users (if (pair? users) users (list users)))
                 ;; Loop through all combinations of host/port and pass each of these to
                 ;; auth-source-macos-keychain-search-items.  Convert numeric port to
                 ;; string (bug#68376).
                 (items (let/ec match
                          (for-each
                           (lambda (host)
                             (for-each
                              (lambda (port)
                                (when (number? port)
                                  (set! port (number-to-string port)))
                                (for-each
                                 (lambda (user)
                                   (let ((items
                                          (apply auth-source-macos-keychain-search-items
                                                 (append
                                                  (list coll type max host port user)
                                                  (auth-source-search-spec spec)))))
                                     (when items
                                       (match items))))
                                 users))
                              ports))
                           hosts)
                          #f))
                 ;; ensure each item has each key in `auth-source-returned-keys'.
                 (items (mapcar (lambda (plist)
                                  (append
                                   (apply append
                                          (mapcar (lambda (req)
                                                    (if (plist-get plist req)
                                                        '()
                                                        (list req #f)))
                                                  (auth-source-returned-keys spec)))
                                   plist))
                                items)))
            items))))

    (define (auth-source--decode-octal-string string)
      "Convert octal STRING to utf-8 string.  E.g.: \"a\\134b\" to \"a\\b\"."
      ;; `auth-source.el:2155'. The C builds a unibyte string and decodes
      ;; it as UTF-8; a bytevector is this tree's unibyte string (see
      ;; `coding.scm'), and the decoded answer is a vector of code
      ;; points, which `list->string' takes here because the text is
      ;; valid UTF-8 by construction.
      ;;--------------------------------------------------------------
      (let* ((list (string-to-list string))
             (size (%length string))
             (bytes
              (let loop ((i 0) (acc '()))
                (if (>= i size)
                    (reverse acc)
                    (let ((var (nth i list)))
                      (if (char=? var #\\)
                          (loop (+ i 4)
                                (cons (string->number
                                       (list->string
                                        (list-head (list-tail list (+ i 1)) 3))
                                       8)
                                      acc))
                          (loop (+ i 1) (cons (char->integer var) acc)))))))
             (decoded (decode-coding-string (apply bytevector bytes) 'utf-8)))
        (list->string (map integer->char (u32vector->list decoded)))))

    (define (auth-source-macos-keychain-search-items coll type _max
                                                     host port user . spec)
      ;; `auth-source.el:2171'. `&key label &allow-other-keys'.
      ;;--------------------------------------------------------------
      (let* ((label (plist-get spec ':label))
             (keychain-generic (eq? type 'macos-keychain-generic))
             (args (list (if keychain-generic
                             "find-generic-password"
                             "find-internet-password")
                         "-g"))
             (ret (list ':type type)))
        (when label
          (set! args (append args (cons "-l" label))))
        (when host
          (set! args (append args (list (if keychain-generic "-c" "-s") host))))
        (when user
          (set! args (append args (list "-a" user))))

        (when port
          (if keychain-generic
              (set! args (append args (list "-s" port)))
              (set! args (append args (if (string-match-p "\\`[[:digit:]]+\\'" port)
                                          (list "-P" port)
                                          (list "-r" (substring
                                                      (format "%-4s" port)
                                                      0 4)))))))

        (unless (equal? coll "default")
          (set! args (append args (list coll))))

        (with-temp-buffer
          (apply call-process (append (list "/usr/bin/security" #f #t #f) args))
          (goto-char (point-min))
          (while (not (eobp))
            (cond
             ((looking-at "^password: \\(?:0x[0-9A-F]+\\)? *\"\\(.+\\)\"")
              (set! ret (auth-source-macos-keychain-result-append
                         ret
                         keychain-generic
                         "secret"
                         (let ((v (auth-source--decode-octal-string
                                   (match-string 1))))
                           (lambda () v)))))
             ;; TODO: check if this is really the label
             ;; match 0x00000007 <blob>="AppleID"
             ((looking-at
               "^[ ]+0x00000007 <blob>=\\(?:0x[0-9A-F]+\\)? *\"\\(.+\\)\"")
              (set! ret (auth-source-macos-keychain-result-append
                         ret
                         keychain-generic
                         "label"
                         (auth-source--decode-octal-string (match-string 1)))))
             ;; match "crtr"<uint32>="aapl"
             ;; match "svce"<blob>="AppleID"
             ((looking-at
               "^[ ]+\"\\([a-z]+\\)\"[^=]+=\\(?:0x[0-9A-F]+\\)? *\"\\(.+\\)\"")
              (set! ret (auth-source-macos-keychain-result-append
                         ret
                         keychain-generic
                         (auth-source--decode-octal-string (match-string 1))
                         (auth-source--decode-octal-string (match-string 2))))))
            (forward-line)))
        ;; return `ret' iff it has the :secret key
        (and (plist-get ret ':secret) (list ret))))

    (define (auth-source-macos-keychain-result-append result generic k v)
      ;; `auth-source.el:2235': pushes VALUE and the mapped keyword onto
      ;; the plist front, so the plist comes out reversed.
      ;;--------------------------------------------------------------
      (set! result (cons v result))
      (set! result (cons (auth-source--symbol-keyword
                          (cond
                           ((equal? k "acct") "user")
                           ;; for generic keychains, creator is host, service is port
                           ((and generic (equal? k "crtr")) "host")
                           ((and generic (equal? k "svce")) "port")
                           ;; for internet keychains, protocol is port, server is host
                           ((and (not generic) (equal? k "ptcl")) "port")
                           ((and (not generic) (equal? k "srvr")) "host")
                           (else k)))
                         result))
      result)

    (define (auth-source-macos-keychain-create . spec)
      ;; `auth-source.el:2249': Emacs's whole body is `(debug spec)` - a
      ;; TODO placeholder that enters the debugger. There is no `debug`
      ;; here, so the same placeholder says so.
      ;;--------------------------------------------------------------
      (error "auth-source-macos-keychain-create is a TODO in Emacs (its body is (debug spec))"))


    ;;----------------------------------------------------------------
    ;; Backend specific parsing: PLSTORE backend
    ;; (`auth-source.el:2255'-`:2439') - not ported (see the header).
    ;; The two declarations below are what a `.plist' source parses to;
    ;; asking one for a search signals the gap instead of pretending.
    ;;----------------------------------------------------------------

    (define (auth-source-plstore-search . spec)
      (error "auth-source: the plstore backend is not ported (needs plstore.el, base64 and EPG)"))

    (define (auth-source-plstore-create . spec)
      (error "auth-source: the plstore backend is not ported (needs plstore.el, base64 and EPG)"))

    ;;----------------------------------------------------------------
    ;; Backend specific parsing: JSON backend
    ;; (`auth-source.el:2440'-`:2506').
    ;;----------------------------------------------------------------

    (define (auth-source-json-check host user port require item)
      ;; `auth-source.el:2440'.
      ;;--------------------------------------------------------------
      (and item
           (auth-source-search-collection
            (or host #t)
            (or
             (plist-get item ':machine)
             (plist-get item ':host)
             #t))
           (auth-source-search-collection
            (or user #t)
            (or
             (plist-get item ':login)
             (plist-get item ':account)
             (plist-get item ':user)
             #t))
           (auth-source-search-collection
            (or port #t)
            (or
             (plist-get item ':port)
             (plist-get item ':protocol)
             #t))
           (or
            ;; the required list of keys is nil, or
            (%nil? require)
            ;; every element of require is in
            (let loop ((reqs require))
              (or (null? reqs)
                  (and (plist-get item (car reqs))
                       (loop (cdr reqs))))))))

    (define (auth-source-json-search . spec)
      "Given a property list SPEC, return search matches from the `:backend'.
See `auth-source-search' for details on SPEC."
      ;; `auth-source.el:2443'.
      ;;--------------------------------------------------------------
      ;; just in case, check that the type is correct (null or same as the backend)
      (let ((backend (plist-get spec ':backend))
            (require (plist-get spec ':require))
            (type (plist-get spec ':type))
            (max (plist-get spec ':max))
            (host (plist-get spec ':host))
            (user (plist-get spec ':user))
            (port (plist-get spec ':port)))
        (unless (or (%nil? type) (eq? type (auth-source-backend-type backend)))
          (error "Invalid JSON search: ~a ~a" type (auth-source-backend-type backend)))

        ;; Hide the secrets early to avoid accidental exposure.
        (let* ((jdata
                (mapcar (lambda (entry)
                          (let ((ret '()))
                            (while (pair? entry)
                              (let* ((item (car entry))
                                     (k (auth-source--symbol-keyword (car item)))
                                     (v (cdr item)))
                                (set! entry (cdr entry))
                                (set! k (cond ((memq k '(:machine)) ':host)
                                              ((memq k '(:login :account)) ':user)
                                              ((memq k '(:protocol)) ':port)
                                              ((memq k '(:password)) ':secret)
                                              (else k)))
                                ;; send back the secret in a function (lexical binding)
                                (when (eq? k ':secret)
                                  (set! v (let ((lexv v))
                                            (lambda () lexv))))
                                (set! ret (plist-put ret k v))))
                            ret))
                        (json-read-file (auth-source-backend-source backend))))
               (max (or max 5000))       ; sanity check: default to stop at 5K
               (all '()))
          (for-each (lambda (item)
                      (when (and item
                                 (> max (length all))
                                 (auth-source-json-check host user port require item))
                        (set! all (cons item all))))
                    jdata)
          (nreverse all))))

    ;;----------------------------------------------------------------
    ;; The end of the search API (`auth-source.el:2507'-`:2527').
    ;;----------------------------------------------------------------

    (define (auth-source-user-and-password host . user-arg)
      ;; `auth-source.el:2507'.
      ;;--------------------------------------------------------------
      (let* ((user (and (pair? user-arg) (car user-arg)))
             (auth-info (car-safe
                         (if user
                             (apply auth-source-search
                                    (list ':host host
                                          ':user user
                                          ':max 1
                                          ':require '(:user :secret)
                                          ':create #f))
                             (apply auth-source-search
                                    (list ':host host
                                          ':max 1
                                          ':require '(:user :secret)
                                          ':create #f)))))
             (user (plist-get auth-info ':user))
             (password (auth-info-password auth-info)))
        (list user password auth-info)))

    ;;----------------------------------------------------------------
    ;; Tiny mode for editing .netrc/.authinfo modes (that basically just
    ;; hides passwords and adds basic syntax highlighting)
    ;; (`auth-source.el:2528'-`:2595').
    ;;----------------------------------------------------------------

    (define-custom *authinfo-hidden* "password"
      "Regexp matching elements in .authinfo/.netrc files that should be hidden."
      :type 'regexp
      :version "27.1")

    (define-custom *authinfo-hide-elements* #t
      "Whether to use `authinfo-hidden' to hide elements in authinfo files."
      :type 'boolean
      :version "28.1")

    (define authinfo--keywords
      '(("^#.*" (0 'font-lock-comment-face))
        ("^\\(machine\\)[ \t]+\\([^ \t\n]+\\)"
         (1 'font-lock-variable-name-face)
         (2 'font-lock-builtin-face))
        ("\\(login\\)[ \t]+\\([^ \t\n]+\\)"
         (1 'font-lock-comment-delimiter-face)
         (2 'font-lock-keyword-face))
        ("\\(password\\)[ \t]+\\([^ \t\n]+\\)"
         (1 'font-lock-comment-delimiter-face)
         (2 'font-lock-doc-face))
        ("\\(port\\)[ \t]+\\([^ \t\n]+\\)"
         (1 'font-lock-comment-delimiter-face)
         (2 'font-lock-type-face))
        ("\\([^ \t\n]+\\)[, \t]+\\([^ \t\n]+\\)"
         (1 'font-lock-constant-face)
         (2 nil))))
    ;; ^ `(defvar authinfo--keywords ...)` (`auth-source.el:2538').

    (define authinfo-mode-map (make-sparse-keymap '*authinfo-mode-map*))
    (define authinfo-mode-hook (make-parameter '()))
    ;; ^ The hook `define-derived-mode' invents for `authinfo-mode', handed
    ;; in here: a parameter, as every hook is (`add-hook` takes the hook
    ;; object; `run-hooks` dereferences it). Emacs `defvar`s it rather than
    ;; declaring a defcustom, so it is not a `define-custom`.

    (define-derived-mode (authinfo-mode fundamental-mode "Authinfo"
                                        authinfo-mode-map authinfo-mode-hook)
      "Mode for editing .authinfo/.netrc files.

This is just like `fundamental-mode', but has basic syntax
highlighting and hides passwords.  Passwords are revealed when
point is moved into the passwords (see `authinfo-hide-elements').

\\{authinfo-mode-map}"
      ;; `auth-source.el:2557'.
      ;;
      ;; **`reveal-mode` is not ported**, so the hiding is not switched
      ;; on: `authinfo--hide-passwords` installs overlays whose
      ;; `display` would need `reveal-mode`'s point-entered hook to take
      ;; them off again, and a password that can never be revealed is
      ;; worse than one that is visible. The hiding function below is
      ;; ported and can be called by hand; that is the named gap.
      ;;--------------------------------------------------------------
      (font-lock-add-keywords #f authinfo--keywords)
      (set!comment-start "#")
      (set!comment-end "")
      ;; Emacs: `(when authinfo-hide-elements (authinfo--hide-passwords
      ;; (point-min) (point-max)) (reveal-mode))'.
      #f)

    (define (authinfo--hide-passwords start end)
      ;; `auth-source.el:2572'.
      ;;--------------------------------------------------------------
      (save-excursion
        (save-restriction
          (narrow-to-region start end)
          (goto-char start)
          (while (re-search-forward (format "\\(\\s-\\|^\\)\\(%s\\)\\s-+"
                                            (*authinfo-hidden*))
                                    #f #t)
            (when (auth-source-netrc-looking-at-token)
              (let ((overlay (make-overlay (match-beginning 0) (match-end 0))))
                (overlay-put overlay 'display
                             (propertize "****" 'face 'font-lock-doc-face))
                (overlay-put overlay 'reveal-toggle-invisible
                             authinfo--toggle-display)))))))

    (define (authinfo--toggle-display overlay hide)
      ;; `auth-source.el:2587'.
      ;;--------------------------------------------------------------
      (if hide
          (overlay-put overlay 'display
                       (propertize "****" 'face 'font-lock-doc-face))
          (overlay-put overlay 'display #f)))

    ;;----------------------------------------------------------------
    ;; The mode-line icons (`auth-source.el:2597'-`:2613').
    ;;
    ;; "It would be preferable to use "👁" ("\N{EYE}"). However, there
    ;; is no corresponding Unicode char with a slash. So we use symbols
    ;; as fallback only, with "⦵" ("\N{CIRCLE WITH HORIZONTAL BAR}")
    ;; for hiding the password."
    ;;----------------------------------------------------------------

    (define-icon read-passwd--show-password-icon #f
      `((image "reveal.svg" "reveal.pbm" :height (0.8 . em))
        (symbol "👁")
        (text "<o>"))
      "Mode line icon to show a hidden password."
      :version "30.1"
      :help-echo "mouse-1: Toggle password visibility")

    (define-icon read-passwd--hide-password-icon #f
      `((image "conceal.svg" "conceal.pbm" :height (0.8 . em))
        (symbol "⦵")
        (text "<\\>"))
      "Mode line icon to hide a visible password."
      :version "30.1"
      :help-echo "mouse-1: Toggle password visibility")

    (define read-passwd--mode-line-icon #f)
    ;; ^ `(defvar read-passwd--mode-line-icon nil)': "Propertized mode
    ;; line icon for showing/hiding passwords." A plain variable - it is
    ;; only ever `setq`-ed, never `let`-bound.

    (define read-passwd--password-hidden #f)
    ;; ^ `(defvar read-passwd--password-hidden nil)`: "Flag indicating
    ;; whether password in minibuffer is hidden."

    (define (read-passwd--hide-password)
      "Make password in minibuffer hidden or visible."
      ;; `auth-source.el:2621', loop for loop. The range is
      ;; `minibuffer-prompt-end` through `point-max`, one character at a
      ;; time - Emacs's `dotimes` over `(1+ (- (buffer-size) beg))`,
      ;; with `buffer-size` being the number of characters and positions
      ;; being one-based.
      ;;------------------------------------------------------------
      (let ((beg (minibuffer-prompt-end))
            ;; `read-hide-char` holds a character in Emacs, where a
            ;; character *is* an integer; a caller may set it either
            ;; way here, so both are accepted.
            (hide (let ((c (or (*read-hide-char*) #\*)))
                    (if (integer? c) (integer->char c) c))))
        (dotimes (i (+ 1 (- (buffer-size) beg)))
          (let ((from (+ i beg))
                (to (+ 1 i beg)))
            (if read-passwd--password-hidden
                (put-text-property from to 'display (string hide))
                (remove-list-of-text-properties from to '(display)))
            (put-text-property
             from to
             'help-echo "C-u: Clear password\nTAB: Toggle password visibility")))))

    (define (%read-passwd-mode-line-icon)
      ;; The `:eval` value `global-mode-string` holds while a password is
      ;; being read. Emacs writes `(:eval read-passwd--mode-line-icon)`
      ;; - a form naming a *variable*; this tree's `:eval` holds a
      ;; procedure, and it is named (not a fresh lambda per call) so the
      ;; `member` test that removes the entry compares equal: `equal?`
      ;; on two procedures is `eq?`.
      ;;------------------------------------------------------------
      read-passwd--mode-line-icon)

    (define-command (read-passwd-toggle-visibility . rest)
      "Toggle minibuffer contents visibility.
Adapt also mode line.  If optional FORCE is non-nil, hide the minibuffer
contents."
      ;; `auth-source.el:2633'. The command is called from TAB in the
      ;; prompt and from a mode-line click; FORCE is the `t` the mode's
      ;; own body passes to always start out hidden.
      ;;------------------------------------------------------------
      (interactive)
      (let ((force (and (pair? rest) (car rest))))
        (let ((win (active-minibuffer-window)))
          (unless win (error "No active minibuffer"))
          ;; FIXME: In case of a recursive minibuffer, this may select the
          ;; wrong mini-buffer.
          (with-current-buffer (window-buffer win)
            (when (memq 'read-passwd-mode
                        (buffer-local-value (current-buffer)
                                            'local-minor-modes '()))
              (set! read-passwd--password-hidden
                    (or force (not read-passwd--password-hidden)))
              (set! read-passwd--mode-line-icon
                    ;; Emacs's `(:propertize ,ICON mouse-face
                    ;; mode-line-highlight keymap ,MAP)`. The icon's own
                    ;; `help-echo` (from `icon-string`) stays on the
                    ;; text; these are added over it, as `propertize`
                    ;; adds.
                    (list ':propertize
                          (if (*icon-preference*)
                              (icon-string
                               (if read-passwd--password-hidden
                                   'read-passwd--show-password-icon
                                   'read-passwd--hide-password-icon))
                              "")
                          'mouse-face 'mode-line-highlight
                          'keymap %read-passwd-toggle-map))
              (force-mode-line-update 'all)
              (read-passwd--hide-password))))))

    ;; The keymap the mode-line icon carries: Emacs's `eval-when-compile'
    ;; block inside `read-passwd-toggle-visibility' (`auth-source.el:2654').
    ;; A map, and not a `:keymap` property spelled inline, because a text
    ;; property holds the object. The `define-key` has to follow the
    ;; command it binds - a binding resolves when the form runs.
    (define %read-passwd-toggle-map (make-sparse-keymap))
    (define-key %read-passwd-toggle-map
                (vector 'mode-line 'mouse-1) read-passwd-toggle-visibility)

    ;;----------------------------------------------------------------
    ;; The prompt's keymap (`auth-source.el:2664'-`:2668').
    ;;----------------------------------------------------------------

    (define read-passwd-map (make-sparse-keymap))
    (set-keymap-parent read-passwd-map minibuffer-local-map)
    (define-key read-passwd-map (kbd "C-u") delete-minibuffer-contents) ; bug#12570
    (define-key read-passwd-map (kbd "TAB") read-passwd-toggle-visibility)

    (define read-passwd--mini-buffers '())
    ;; ^ "List of minibuffers where `read-passwd' is active."

    (define-minor-mode read-passwd-mode
      "Toggle visibility of password in minibuffer."
      :keymap read-passwd-map
      (unless (read-passwd-mode-variable)
        (set! read-passwd--mini-buffers
              (delq (current-buffer) read-passwd--mini-buffers)))
      (unless (pair? read-passwd--mini-buffers)
        (let ((mode-string (list ':eval %read-passwd-mode-line-icon)))
          (if (read-passwd-mode-variable)
              ;; Add `read-passwd--mode-line-icon'.
              (or (member mode-string (*global-mode-string*))
                  (*global-mode-string*
                   (append (*global-mode-string*) (list mode-string))))
              ;; Remove `read-passwd--mode-line-icon'.
              (*global-mode-string*
               (delete mode-string (*global-mode-string*))))))
      (when (read-passwd-mode-variable)
        (set! read-passwd--mini-buffers
              (cons (current-buffer) read-passwd--mini-buffers)))
      ;; Always hide the current password.
      (when (pair? read-passwd--mini-buffers)
        (with-current-buffer (car read-passwd--mini-buffers)
          (read-passwd-toggle-visibility #t))))

    (define (read-passwd prompt . rest)
      "Read a password, prompting with PROMPT, and return password as a string.
If optional CONFIRM is non-nil, read the password twice to make sure.
Optional DEFAULT is a default password to use instead of empty input.

This function echoes `*' for each character that the user types.
You could let-bind `read-hide-char' to another hiding character, though.

Once the caller uses the password, it can erase the password
by doing (clear-string STRING)."
      ;; `auth-source.el:2703'. Not a command in Emacs - it has no
      ;; interactive spec - so it is a plain procedure here too.
      ;;------------------------------------------------------------
      (let ((confirm (and (pair? rest) (car rest)))
            (default (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if confirm
            (let ((success #f))
              (while (not success)
                (let ((first (read-passwd prompt #f default))
                      (second (read-passwd "Confirm password: " #f default)))
                  (if (equal? first second)
                      (begin
                        (and (string? second) (not (eq? first second))
                             (clear-string second))
                        (set! success first))
                      (begin
                        (and (string? first) (clear-string first))
                        (and (string? second) (clear-string second))
                        (message "Password not repeated accurately; please start over")
                        (sit-for 1)))))
              success)
            (let ((minibuf #f))
              (minibuffer-with-setup-hook
                  (lambda ()
                    (set! minibuf (current-buffer))
                    ;; Turn off electricity. Of the four `setq-local`s,
                    ;; two are this tree's buffer slots and two are
                    ;; parameters bound around the read below:
                    ;; `post-self-insert-hook`, `select-active-regions`
                    ;; and `inhibit-modification-hooks` have no
                    ;; buffer-local half to write.
                    (buffer-disable-undo) ; `(setq-local buffer-undo-list t)'
                    ;; `(setq-local show-paren-mode nil)' - bug#16091.
                    ;; `show-paren-mode-value` reads the buffer's own
                    ;; slot, which is what `setq-local` writes in Emacs.
                    (set-buffer-local-value! (current-buffer) 'show-paren-mode #f)
                    (use-local-map read-passwd-map)
                    (read-passwd-mode 1)
                    (add-hook *post-command-hook* read-passwd--hide-password
                              #f #t))
                (lambda ()
                  (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (parameterize ((*post-self-insert-hook* '())
                                     (*select-active-regions* #f)
                                     (*inhibit-modification-hooks* #f)
                                     (*read-hide-char*
                                      (or (*read-hide-char*) #\*))
                                     ;; Emacs's `(let
                                     ;; ((enable-recursive-minibuffers t)) ...)'
                                     ;; around this read.
                                     (*enable-recursive-minibuffers* #t))
                        (read-from-minibuffer prompt #f #f #t default))) ; t = "no history"
                    (lambda ()
                      (when (buffer-live-p minibuf)
                        (with-current-buffer minibuf
                          (read-passwd-mode -1)
                          ;; Not sure why but it seems that there might be
                          ;; cases where the minibuffer is not always
                          ;; properly reset later on, so undo whatever
                          ;; we've done here (bug#11392).
                          (remove-hook *post-command-hook*
                                       read-passwd--hide-password #t)
                          (kill-local-variable 'show-paren-mode)
                          ;; And of course, don't keep the sensitive data
                          ;; around.
                          (erase-buffer)))))))))))

    ))

;; `comint.el`'s `comint-read-noecho` is obsoleted in favour of this
;; function (`comint.el:2551`); the `make-obsolete` belongs beside the
;; command in `comint.scm`, and is written there.
