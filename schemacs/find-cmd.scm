(define-library (schemacs find-cmd)
  ;; This library mirrors GNU Emacs's `lisp/find-cmd.el' - the
  ;; sexp-to-`find(1)'-command builder, all of it, function for function
  ;; in the file's order.  It arrives with the Groovy modes, whose
  ;; `grails-mode' builds its "find the project's files" command with
  ;; it.
  ;;
  ;; **Departures, both forced by the host:**
  ;;
  ;;   * `find-program' is grep.el's defcustom, and grep.el is not
  ;;     ported.  It is defined HERE, with grep.el's own default
  ;;     ("find"), as the tree's star-named parameter, and named so that
  ;;     the day grep.el lands this definition moves there.
  ;;
  ;;   * **The operator entries of `find-constituents' hold the
  ;;     PROCEDURES, not their symbols.**  Emacs stores `find-and' and
  ;;     tests `(fboundp option)'; there is no function obarray here, so
  ;;     the alist carries the procedures and the test is
  ;;     `procedure?'.  Everything else in the alist - the minimum
  ;;     argument counts, the joiners, the quote flags - is Emacs's data
  ;;     character for character.
  (import
    (scheme base)
    (only (guile) caddr cdddr format hash-ref hash-set! make-hash-table)
    (only (schemacs subr) shell-quote-argument)
    (only (schemacs fns) mapconcat)
    (only (schemacs eval) funcall)
    (only (schemacs fileio) expand-file-name)
    (only (schemacs buffer) default-directory)
    (only (schemacs custom) define-custom))

  (export find-cmd find-constituents
          find-and find-or find-not find-prune find-generic
          find-command find-to-string
          *find-program*)

  (begin

    (define-custom *find-program* "find"
      "Program used to find files."
      :type 'string
      :group 'grep)

    (define find-constituents
      (list
        (cons 'and 'find-and)
        (cons 'not 'find-not)
        (cons 'or  'find-or)

        (cons 'a 'find-and)
        (cons 'n 'find-not)
        (cons 'o 'find-or)

        (cons 'prune 'find-prune)

        ;; switches
        (cons 'L '(0))
        (cons 'P '(0))
        (cons 'H '(0))

        ;; generic tests
        (cons 'amin       '(1))
        (cons 'anewer     '(1))
        (cons 'atime      '(1))
        (cons 'cmin       '(1))
        (cons 'cnewer     '(1))
        (cons 'ctime      '(1))
        (cons 'empty      '(0))
        (cons 'executable '(0))
        (cons 'false      '(0))
        (cons 'fstype     '(1))
        (cons 'gid        '(1))
        (cons 'group      '(1))
        (cons 'ilname     '(1))
        (cons 'iname      '(1))
        (cons 'inum       '(1))
        (cons 'ipath      '(1))
        (cons 'iregex     '(1))
        (cons 'iwholename '(1))
        (cons 'links      '(1))
        (cons 'lname      '(1))
        (cons 'mmin       '(1))
        (cons 'mtime      '(1))
        (cons 'name       '(1))
        (cons 'newer      '(1))
        (cons 'nogroup    '(0))
        (cons 'nouser     '(0))
        (cons 'path       '(1))
        (cons 'perm       '(0))
        (cons 'readable   '(0))
        (cons 'regex      '(1))
        (cons 'samefile   '(1))
        (cons 'size       '(1))
        (cons 'true       '(0))
        (cons 'type       '(1))
        (cons 'uid        '(1))
        (cons 'used       '(1))
        (cons 'user       '(1))
        (cons 'wholename  '(1))
        (cons 'writable   '(0))
        (cons 'xtype      '(nil))

        ;; normal options (always true)
        (cons 'daystart              '(0))
        (cons 'depth                 '(0))
        (cons 'maxdepth              '(1))
        (cons 'mindepth              '(1))
        (cons 'mount                 '(0))
        (cons 'noleaf                '(0))
        (cons 'ignore_readdir_race   '(0))
        (cons 'noignore_readdir_race '(0))
        (cons 'regextype             '(1))
        (cons 'xdev                  '(0))

        ;; actions
        (cons 'delete  '(0))
        (cons 'print0  '(0))
        (cons 'printf  '(1))
        (cons 'fprintf '(2))
        (cons 'print   '(0))
        (cons 'fprint0 '(1))
        (cons 'fprint  '(1))
        (cons 'ls      '(0))
        (cons 'fls     '(1))
        (cons 'prune   '(0))
        (cons 'quit    '(0))

        ;; these need to be terminated with a ;
        (cons 'exec    (list 1 'find-command #t))
        (cons 'ok      (list 1 'find-command #t))
        (cons 'execdir (list 1 'find-command #t))
        (cons 'okdir   (list 1 'find-command #t)))
      ;; "Holds details of each of the find options.  The car of each
      ;; alist is the name.  The cdr is minimum args, the function used
      ;; to join many occurrences of the argument together, and whether
      ;; or not to leave quotes off the string (non-nil means the string
      ;; will be quoted)."
      ;;
      ;; The names are SYMBOLS, as in Emacs's data; `%find-functions'
      ;; (filled at the end of the file) is the stand-in for the
      ;; function obarray `fboundp' and `funcall' reach through.
      )

    (define %find-functions (make-hash-table))
    ;; Set up at the end of the file, after the functions exist.


    (define (find-cmd . subfinds)
      ;; "Initiate the building of a find command. ... `default-directory'
      ;; is used as the initial search path.  The result is a string that
      ;; should be ready for the command line."
      (string-append (*find-program*) " "
                     (shell-quote-argument (expand-file-name (default-directory))) " "
                     (if (pair? (cdr subfinds))
                         (mapconcat find-to-string subfinds)
                         (find-to-string (car subfinds)))))

    (define (find-and form)
      ;; "And FORMs together, so:
      ;;   (and (mtime \"+1\") (name \"something\"))
      ;; will produce:
      ;;   find . \\( -mtime +1 -and -name something \\)"
      (if (< (length form) 2)
          (find-to-string (car form))
          (string-append "\\( "
                         (mapconcat find-to-string form "-and ")
                         "\\) ")))

    (define (find-or form)
      ;; "Or FORMs together, so:
      ;;   (or (mtime \"+1\") (name \"something\"))
      ;; will produce:
      ;;   find . \\( -mtime +1 -or -name something \\)"
      (if (< (length form) 2)
          (find-to-string (car form))
          (string-append "\\( "
                         (mapconcat find-to-string form "-or ")
                         "\\) ")))

    (define (find-not form)
      ;; "Or FORMs together and prefix with a -not, so:
      ;;   (not (mtime \"+1\") (name \"something\"))
      ;; will produce:
      ;;   -not \\( -mtime +1 -or -name something \\)"
      (string-append "-not " (find-or (map find-to-string form))))

    (define (find-prune form)
      ;; "-or together FORMs postfix `-prune' and then -or that with a
      ;; -true, so:
      ;;   ((prune (name \".svn\" \".git\")) (name \"*.pm\"))
      ;; will produce (unwrapped):
      ;;   \\( \\( \\( -name .svn -or -name .git \\) / -prune -or -true
      ;;   \\) -and -name *.pm \\)"
      (find-or
       (list
        (string-append (find-or (map find-to-string form)) (find-generic "prune"))
        (find-generic "true"))))

    (define (find-generic option . rest)
      ;; "Allow an arbitrary string to be used as a form.  OPTION is the
      ;; name of the form, OPER is the function used to either OR or AND
      ;; multiple results together.  ARGCOUNT is the minimum of args that
      ;; OPTION can receive and ARGS are the arguments for OPTION.  If
      ;; DONT-QUOTE is non-nil, arguments are quoted for passing them to
      ;; the shell."  (Emacs's two optional arguments are this tree's
      ;; rest list.)
      (let* ((oper (and (pair? rest) (car rest)))
             (argcount (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (args (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                        (caddr rest)))
             (dont-quote (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                              (pair? (cdddr rest)) (car (cdddr rest)))))
        (when (and (number? argcount)
                   (< (if args (length args) 0) argcount))
          (error "`~a' needs at least ~a arguments" option argcount))
        (let ((oper (if oper
                        (if (symbol? oper) (hash-ref %find-functions oper) oper)
                        find-or)))
          (if (pair? args)
              (funcall oper (map (lambda (x)
                                   (string-append "-" option
                                                  (if dont-quote
                                                      (string-append " " x " ")
                                                      (string-append " "
                                                                     (shell-quote-argument x)
                                                                     " "))))
                                 args))
              (string-append "-" option " ")))))

    (define (find-command form)
      ;; "For each item in FORM add a terminating semi-colon and turn
      ;; them into valid switches.  The result is -and(ed) together."
      (find-and (map (lambda (x)
                       (string-append (find-to-string x) "\\; "))
                     form)))

    (define (find-to-string form)
      ;; "Parse FORM to produce a set of valid find arguments."
      (cond
        ((string? form)
         form)
        ((pair? form)
         (let* ((entry (assoc (car form) find-constituents))
                (option (and entry (cdr entry))))
           (cond
             ((and (symbol? option) (hash-ref %find-functions option))
              (funcall (hash-ref %find-functions option) (cdr form)))
             ((pair? option)
              (let ((option (symbol->string (car form)))
                    (argcnt (car option))
                    (oper (and (pair? (cdr option)) (cadr option)))
                    (dont-quote (and (pair? (cdr option))
                                     (pair? (cddr option))
                                     (car (cddr option)))))
                (find-to-string
                 (find-generic option oper argcnt (cdr form) dont-quote))))
             (else
              (error "Sorry I don't know how to handle `~a'" (car form))))))
        (else #f)))

    
    ;; `find-constituents' holds the operator NAMES; this is the obarray
    ;; `(fboundp option)' / `(funcall option ...)' would consult.
    (hash-set! %find-functions 'find-and find-and)
    (hash-set! %find-functions 'find-not find-not)
    (hash-set! %find-functions 'find-or find-or)
    (hash-set! %find-functions 'find-prune find-prune)
    (hash-set! %find-functions 'find-command find-command)

    ))
