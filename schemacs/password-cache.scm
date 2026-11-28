(define-library (schemacs password-cache)
  ;; GNU Emacs's `lisp/password-cache.el', whole: the time-limited cache
  ;; `password-read' consults before it prompts.
  ;;
  ;; Two things are this tree's rather than Emacs's, both named at their
  ;; definitions:
  ;;
  ;;   * `password-data' is a Guile hash table with `equal?' hashing,
  ;;     which is Emacs's `(make-hash-table :test #'equal)';
  ;;   * `password-read' calls `read-passwd' through
  ;;     `*read-passwd-function*', a seam installed by
  ;;     `(schemacs auth-source)' as it loads. `read-passwd' is in
  ;;     `auth-source.el' and that library imports this one, so a direct
  ;;     import would be a cycle; Emacs has one obarray and calls the
  ;;     symbol.
  ;;
  ;; `password-reset' is a command, as Emacs makes it interactive.
  ;;------------------------------------------------------------
  (import
    (scheme base)
    (only (guile) make-hash-table hash-ref hash-set! hash-remove!
          hash-clear! hash-get-handle)
    (only (schemacs custom) define-custom)
    (only (schemacs fns) clear-string)
    (only (schemacs core timer) run-at-time)
    (only (schemacs command) define-command))

  (export *password-cache* *password-cache-expiry*
          password-data password-read-from-cache password-in-cache-p
          password-read *read-passwd-function*
          password-cache-remove password-cache-add password-reset)

  (begin

    (define-custom *password-cache* #t
      "Whether to cache passwords."
      :group 'password
      :type 'boolean)

    (define-custom *password-cache-expiry* 16
      "How many seconds passwords are cached, or nil to disable expiring.
Whether passwords are cached at all is controlled by `password-cache'."
      :group 'password
      :type '(choice (const :tag "Never" nil)
                     (integer :tag "Seconds")))

    (define password-data (make-hash-table))
    ;; ^ GNU Emacs's `password-data' (`password-cache.el:75'): "The hash
    ;; table of cached passwords, keyed by the KEY each was read for."
    ;; A plain variable: nothing `let`-binds it, it is mutated in place.
    ;; Guile's `make-hash-table' defaults to `equal?' hashing, which is
    ;; Emacs's `:test #'equal'.

    (define *read-passwd-function* (make-parameter #f))
    ;; The seam `password-read' below calls. `auth-source.el' owns
    ;; `read-passwd' and installs this as it loads; a session with no
    ;; auth-source library answers with an error naming the function.

    (define (password-read-from-cache key)
      ;; GNU Emacs's `password-read-from-cache' (`password-cache.el:78'):
      ;; "Obtain passphrase for KEY from time-limited passphrase cache.
      ;; Custom variables `password-cache' and `password-cache-expiry'
      ;; regulate cache behavior."
      ;;--------------------------------------------------------------
      (and (*password-cache*)
           key
           (hash-ref password-data key #f)))

    (define (password-in-cache-p key)
      ;; GNU Emacs's `password-in-cache-p' (`password-cache.el:87'):
      ;; "Check if KEY is in the cache."
      ;;--------------------------------------------------------------
      (and (*password-cache*)
           key
           (if (hash-get-handle password-data key) #t #f)))

    (define (password-read prompt . key-arg)
      ;; GNU Emacs's `password-read' (`password-cache.el:93'): "Read
      ;; password, for use with KEY, from user, or from cache if wanted.
      ;; KEY indicate the purpose of the password, so the cache can
      ;; separate passwords. The cache is not used if KEY is nil. KEY is
      ;; typically a string but can be anything (compared via `equal').
      ;; The variable `password-cache' control whether the cache is
      ;; used."
      ;;--------------------------------------------------------------
      (let ((key (if (pair? key-arg) (car key-arg) #f)))
        (or (password-read-from-cache key)
            (let ((read-passwd (*read-passwd-function*)))
              (if read-passwd
                  (read-passwd prompt)
                  (error "password-read: `read-passwd' is not available (schemacs auth-source is not loaded)"))))))

    (define (password-cache-remove key)
      ;; GNU Emacs's `password-cache-remove' (`password-cache.el:109'):
      ;; "Remove password indexed by KEY from password cache. This is
      ;; typically run by a timer setup from `password-cache-add', but
      ;; can be invoked at any time to forcefully remove passwords from
      ;; the cache. This may be useful when it has been detected that a
      ;; password is invalid, so that `password-read' query the user
      ;; again."
      ;;--------------------------------------------------------------
      (let ((password (hash-ref password-data key #f)))
        (when (string? password)
          (clear-string password))
        (hash-remove! password-data key)))

    (define (password-cache-add key password)
      ;; GNU Emacs's `password-cache-add' (`password-cache.el:121'):
      ;; "Add password to cache. The password is removed by a timer
      ;; after `password-cache-expiry' seconds."
      ;;--------------------------------------------------------------
      (when (and (*password-cache-expiry*)
                 (not (hash-get-handle password-data key)))
        (run-at-time (*password-cache-expiry*) #f password-cache-remove key))
      (hash-set! password-data key password)
      #f)

    (define-command (password-reset)
      "Clear the password cache."
      (interactive)
      (hash-clear! password-data))

    ))
