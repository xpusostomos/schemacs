(define-library (schemacs editor dired)
  ;; This library mirrors GNU Emacs's `lisp/dired.el': the Dired mode -
  ;; the listing's line reader, the commands that move in it, mark in it
  ;; and read file names out of it.
  ;;
  ;; The *file primitives* it is built on are `src/dired.c''s and live in
  ;; `(schemacs editor diredc)' beside this library: Emacs has both
  ;; `src/dired.c' and `lisp/dired.el', which would want the same file
  ;; name here, and the elisp half keeps the plain one, as
  ;; `minibuffer.sld' keeps it against `minibuf.sld'. The listing itself
  ;; is `(schemacs editor ls-lisp)' through `insert-directory'.
  ;;
  ;; **`dired-move-to-filename' is exact when our own listing put the
  ;; text there.** Emacs tries the `dired-filename' text property first
  ;; and falls back to `directory-listing-before-filename-regexp' - a
  ;; regexp that has to recognize ISO, western, east-asian and
  ;; comma-separated dates in any locale. `ls-lisp-classify-file'
  ;; propertizes the name before it appends the type indicator, `concat'
  ;; carries the property into the line, `insert' grafts it into the
  ;; buffer, so the first arm is taken and the regexp is the fallback it
  ;; is meant to be. The regexp is ported and measured to agree with
  ;; Emacs on every line shape a listing has, so the fallback is real.
  ;;
  ;; Not ported yet, and named rather than faked:
  ;;
  ;;   * **the way in**: `dired-noselect', `dired-internal-noselect`,
  ;;     `dired-readin', `dired' (C-x d) and `dired-revert'. They need
  ;;     `create-file-buffer' and the `dired-buffers' registry, which
  ;;     are the next piece of work; the listing they would produce is
  ;;     already exact, since `insert-directory' is.
  ;;   * **subdirectories**: `dired-insert-subdir', `dired-subdir-alist`,
  ;;     `dired-build-subdir-alist`, `dired-next-dirline' and the
  ;;     header line. Every `dired-get-subdir' branch below is left out
  ;;     with the same reason.
  ;;   * **the file operations**: the `dired-do-*' commands of
  ;;     `dired.el' proper and all of `dired-aux.el' - copy, rename,
  ;;     chmod, compress, and the shell-command guesses.
  ;;   * **wdired**, **`dired-x'**, **desktop**, the font-lock keywords,
  ;;     `dired-hide-details-mode', and `dired-click-to-select-mode' -
  ;;     each of which is a feature with its own file in Emacs.
  ;;   * `dired-mark''s region branch (`dired-mark-region',
  ;;     `region-active-p') and the `dired-hide-details-*' properties.
  ;;     `dired--hidden-p' itself *is* ported and is used by
  ;;     `dired-move-to-end-of-filename', so that the guard there is the
  ;;     C's guard rather than an omission; it answers nil everywhere
  ;;     today, because nothing here sets `invisible' `dired' - the
  ;;     hiding commands are what would.
  ;;
  ;; And the *filesystem* half of the listing: `dired--insert-disk-space'
  ;; is not ported, so the `total N' line ls-lisp writes stays where it
  ;; is. Emacs 31 deletes it - `dired-free-space' defaults to `first'
  ;; (dired.el:224), which `dired--insert-disk-space' reads as "remove
  ;; the line and put the free space on the header's colon" - and that
  ;; needs `file-system-info' (fileio.c), `get-free-disk-space' and
  ;; `byte-count-to-string-function' (files.el). Measured against
  ;; `emacs -Q --batch', which answers a first content line of
  ;; `  drwxr-xr-x', not `  total'. The test in
  ;; `dired-mode-tests.scm' pins the current shape and says so.

  (import
    (scheme base)
    (scheme char)
    ;; `read' is Guile's, and wants a port where Emacs's takes a
    ;; string - see `dired-get-filename'. `delq' is `dired-buffers-for-dir'
    ;; and `dired-unadvertise' dropping a killed buffer from the registry,
    ;; as the C's `delq' does.
    (only (guile) caddr delq open-input-string read string-prefix?
          string-suffix?)
    ;; The file primitives this is built on, and their library.
    (only (schemacs editor diredc) file-attributes)
    (only (schemacs editor fileio)
          directory-file-name expand-file-name file-directory-p
          file-exists-p file-name-absolute-p file-name-as-directory
          file-name-directory-part file-name-nondirectory-part
          file-readable-p)
    (only (schemacs editor files)
          abbreviate-file-name create-file-buffer
          directory-listing-before-filename-regexp files--name-absolute-system-p
          find-file insert-directory
          read-file-name revert-buffer)
    ;; `indent-rigidly' is indent.el's, and is what gives a dired buffer
    ;; its two-column indent
    (only (schemacs editor indent) indent-rigidly)
    ;; The buffer, and the buffer-locals Dired keeps on it - including
    ;; `default-directory', which `dired-noselect' reads before this
    ;; library's own `dired-directory' exists, and
    ;; `revert-buffer-function', which `dired-mode' sets to `dired-revert'.
    (only (schemacs editor buffer)
          *case-fold-search* buffer-local-keymap buffer-local-value buffer-modified-p
          buffer-name current-buffer default-directory erase-buffer
          get-buffer-create kill-all-local-variables kill-buffer major-mode
          restore-buffer-modified-p set!buffer-default-directory
          set!buffer-local-keymap set!major-mode set-buffer
          *inhibit-read-only*
          set!mode-name set-buffer-local-value! set-buffer-modified-p
          use-local-map with-current-buffer)
    (only (schemacs editor editfns)
          buffer-substring buffer-substring-no-properties char-after char-before
          eobp forward-line goto-char insert
          line-beginning-position line-end-position point point-marker point-max
          point-min preceding-char save-excursion)
    (only (schemacs editor search)
          looking-at looking-at-p match-beginning match-end match-string
          re-search-backward re-search-forward regexp-quote replace-match
          search-forward string-match string-match-p)
    (only (schemacs editor textprop)
          add-text-properties get-char-property get-text-property
          next-single-property-change put-text-property
          remove-text-properties set-text-properties)
    (only (schemacs editor simple)
          beginning-of-line delete-char end-of-line forward-char
          special-mode special-mode-map)
    (only (schemacs editor keymap) define-key set-keymap-parent
          *default-keymap*)
    (only (schemacs editor command) current-prefix-arg define-command)
    (only (schemacs editor engine)
          marker-position set-marker! text-editor-set-read-only!)
    (only (schemacs editor indentc) *indent-tabs-mode*)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor window)
          display-buffer pop-to-buffer-same-window quit-window switch-to-buffer)
    ;; the switches prompt, which the C reads with `read-string'
    (only (schemacs editor minibuffer) read-from-minibuffer)
    (only (schemacs editor subr) run-hooks run-mode-hooks string-replace)
    )

  (export
   *dired-buffers*
   *dired-initial-position-hook*
   *dired-subdir-alist*
   dired
   dired-advertise
   dired-alist-add-1
   dired-build-subdir-alist
   dired-buffers
   dired-buffers-for-dir
   dired-clear-alist
   dired-find-buffer-nocreate
   dired-goto-file
   dired-goto-file-1
   dired-goto-next-file
   dired-goto-next-nontrivial-file
   dired-in-this-tree-p
   dired-initial-position
   dired-internal-noselect
   dired-mark-remembered
   dired-normalize-subdir
   dired-noselect
   dired-read-dir-and-switches
   dired-readin
   dired-readin-insert
   dired-remember-marks
   dired-revert
   dired-sort-other
   dired-subdir-alist
   dired-subdir-regexp
   dired-unadvertise
   set!dired-buffers!
   set!dired-subdir-alist!
   *dired-actual-switches*
   *dired-after-readin-hook*
   *dired-before-readin-hook*
   *dired-del-marker*
   *dired-directory*
   *dired-listing-switches*
   *dired-ls-F-marks-symlinks*
   *dired-marker-char*
   *dired-mode-hook*
   *dired-trivial-filenames*
   dired--hidden-p
   dired-actual-switches
   dired-between-files
   dired-directory
   dired-filename-property
   dired-flag-file-deletion
   dired-get-filename
   dired-insert-directory
   dired-insert-set-properties
   dired-mark
   dired-marker-regexp
   dired-mode
   dired-mode-map
   dired-move-to-end-of-filename
   dired-move-to-filename
   dired-next-line
   dired-previous-line
   dired-repeat-over-lines
   set!dired-actual-switches!
   set!dired-directory!
   dired-unmark
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The options
    ;;------------------------------------------------------------------

    (define *dired-listing-switches* (make-parameter "-al"))
    ;; ^ GNU Emacs's `dired-listing-switches' (dired.el:63): "Switches
    ;; passed to `ls' for Dired. MUST contain `l' for proper operation."

    (define *dired-marker-char* (make-parameter #\*))
    ;; ^ "In Dired, the current mark character. This is what the
    ;; do-commands look for, and what the mark-commands store." The C
    ;; binds it (`(let ((dired-marker-char ?\s)) ...)') to unmark with a
    ;; space, which is a `parameterize' here.

    (define *dired-del-marker* (make-parameter #\D))
    ;; ^ "Character used to flag files for deletion."

    (define *dired-trivial-filenames* (make-parameter "\\`\\.\\.?\\'\\|\\`\\.?#"))
    ;; ^ "Regexp of files to skip when looking for the first file to
    ;; move to. If it appears at the beginning of a file name, that file
    ;; is not reached by `dired-next-line'."

    (define *dired-directory* (make-parameter #f))
    (define *dired-actual-switches* (make-parameter #f))
    ;; ^ The two buffer-locals `dired-directory' and
    ;; `dired-actual-switches'. Emacs makes them buffer-local, and the
    ;; accessors below are `buffer-local-value' on the current buffer -
    ;; which is the same shape `(schemacs editor buffer)' uses for
    ;; `default-directory'.

    (define (dired-directory)
      (buffer-local-value (current-buffer) '*dired-directory*
                           (*dired-directory*)))

    (define (set!dired-directory! value)
      (set-buffer-local-value! (current-buffer) '*dired-directory* value))

    (define (dired-actual-switches)
      (buffer-local-value (current-buffer) '*dired-actual-switches*
                           (*dired-actual-switches*)))

    (define (set!dired-actual-switches! value)
      (set-buffer-local-value! (current-buffer) '*dired-actual-switches* value))

    (define *dired-mode-hook* (make-parameter '()))
    (define *dired-before-readin-hook* (make-parameter '()))
    (define *dired-after-readin-hook* (make-parameter '()))
    ;; ^ "This hook is run before [after] reading a new directory into a
    ;; Dired buffer. It may be used to change `dired-actual-switches'."

    (define dired-filename-property 'dired-filename)
    ;; ^ The property `ls-lisp-classify-file' puts on the name, and the
    ;; one `dired-move-to-filename' looks for.

    ;;----------------------------------------------------------------
    ;; The regexps
    ;;------------------------------------------------------------------

    ;; "These regexps must be tested at beginning-of-line, but are also
    ;; used to search for next matches, so neither omitting `^' nor
    ;; replacing `^' by `\n' (to make it slightly faster) will work."

    (define dired-re-inode-size
      "[0-9 \t]*[.,0-9]*[BkKMGTPEZYRQ]?[ \t]*")
    ;; ^ "Regexp for optional initial inode and file size as made by
    ;; `ls -i -s'."

    (define dired-re-mark "^[^ \n]")
    ;; ^ "Regexp matching a marked line. Important: the match ends just
    ;; after the marker."

    (define dired-re-maybe-mark "^. ")

    (define dired-re-dir
      ;; "The [^:] part after `d' and `l' is to avoid confusion with the
      ;; DOS/Windows-style drive letters in directory names, like in
      ;; `d:/foo'."
      (string-append dired-re-maybe-mark dired-re-inode-size "d[^:]"))

    (define dired-re-sym
      (string-append dired-re-maybe-mark dired-re-inode-size "l[^:]"))

    (define dired-re-special
      (string-append dired-re-maybe-mark dired-re-inode-size "[bcsp][^:]"))

    (define dired-re-perms "[-bcdlps][-r][-w].[-r][-w].[-r][-w].")
    ;; ^ "Regular expression to match the permission flags in `ls -l'."

    (define dired-re-dot "^.* \\.\\.?/?$")
    ;; ^ "Regexp matching a line whose file name is `.' or `..'."

    (define dired-permission-flags-regexp
      "\\([^ ]\\)[-r][-w]\\([^ ]\\)[-r][-w]\\([^ ]\\)[-r][-w]\\([^ ]\\)")
    ;; ^ The same, as `dired-move-to-end-of-filename' uses it: "Restrict
    ;; perm bits to be non-blank, otherwise this matches one char too
    ;; early (looking backward)".

    (define *dired-ls-F-marks-symlinks* (make-parameter #f))
    ;; ^ GNU Emacs's `dired-ls-F-marks-symlinks' (dired.el:157): "Informs
    ;; Dired about how `ls -lF' marks symbolic links. Set this to t if
    ;; `ls' ... with `-lF' marks the symbolic link itself with a trailing
    ;; @", which is the Ultrix/macOS behaviour. Nil, the default, as in
    ;; Emacs, which is what `ln -s foo bar; ls -F bar' gives as
    ;; `bar -> foo'.

    (define (dired--hidden-p . rest)
      ;; GNU Emacs's `dired--hidden-p' (dired.el:3470): "the line is
      ;; hidden", which the hiding commands mark with `invisible'
      ;; `dired' on the text. Nothing here hides a line yet -
      ;; `dired-hide-subdir' and friends are not ported - so this
      ;; answers false for every position, which is the same answer the
      ;; C gives in a buffer nothing has hidden. It is ported rather
      ;; than left out so that `dired-move-to-end-of-filename''s guard
      ;; is the C's guard and not an omission that would have to be
      ;; found again.
      ;;--------------------------------------------------------------
      (let ((pos (if (and (pair? rest) (car rest)) (car rest) (point))))
        ;; the property functions are the interval tree's, which is
        ;; zero-based, and POS is a buffer position
        (eq? (get-char-property (- pos 1) 'invisible) 'dired)))

    (define (dired-check-switches switches short . rest)
      ;; GNU Emacs's `dired-check-switches': "Return non-nil if the string
      ;; SWITCHES matches LONG or SHORT format."
      ;;--------------------------------------------------------------
      (let ((long (if (pair? rest) (car rest) #f)))
        (and (string? switches)
             (string-match (string-append
                            "\\(\\`\\| \\)-[[:alnum:]]*" short
                            (if long (string-append "\\|--" long "\\>") ""))
                           switches)
             #t)))

    (define (dired-switches-escape-p switches)
      ;; "Do not match things like `--block-size' that happen to contain
      ;; `b'."
      ;;--------------------------------------------------------------
      (dired-check-switches switches "b" "\\(quoting-style=\\)?escape"))

    ;;----------------------------------------------------------------
    ;; Reading a line: where the file name is
    ;;------------------------------------------------------------------

    (define (dired-marker-regexp)
      ;; GNU Emacs's `dired-marker-regexp': a line whose first character
      ;; is the current marker.
      ;;--------------------------------------------------------------
      (string-append "^" (regexp-quote (string (*dired-marker-char*)))))

    (define (dired-between-files)
      ;; GNU Emacs's `dired-between-files': "This used to be a regexp
      ;; match of the `total ...' line output by ls, which is slightly
      ;; faster, but that is not very robust; notably, it fails for
      ;; non-english locales."
      ;;--------------------------------------------------------------
      (save-excursion (not (dired-move-to-filename))))

    (define (dired-move-to-filename . rest)
      ;; GNU Emacs's `dired-move-to-filename' (dired.el:3502): "Move to
      ;; the beginning of the filename on the current line. Return the
      ;; position of the beginning of the filename, or nil if none found."
      ;;
      ;; "First try assuming `ls --dired' was used" - here the property
      ;; is written by `ls-lisp-classify-file' and `concat' rather than
      ;; by `--dired', but it is the same property and the same exact
      ;; answer. The regexp is the fallback, and `raise-error' is the
      ;; C's RAISE-ERROR.
      ;;--------------------------------------------------------------
      (let ((raise-error (and (pair? rest) (car rest)))
            (eol (if (and (pair? rest) (pair? (cdr rest))) (cadr rest)
                     (line-end-position))))
        (beginning-of-line)
        ;; The interval tree's positions are *zero*-based and everything
        ;; in this library is one-based, as Emacs's is; the property
        ;; functions are the tree's, so the conversion is here at the
        ;; seam. Without it the name comes out one character short and
        ;; one character early.
        (let ((change (next-single-property-change (- (point) 1)
                                                   dired-filename-property
                                                   #f (- eol 1))))
          (cond
           ((and change (< change (- eol 1)))
            (goto-char (+ change 1))
            (point))
           ((re-search-forward directory-listing-before-filename-regexp eol #t)
            (goto-char (match-end 0))
            (point))
           ((re-search-forward dired-permission-flags-regexp eol #t)
            ;; "Ha! There *is* a file. Our regexp-from-hell just failed
            ;; to find it."
            (if raise-error
                (error "Unrecognized line!  Check directory-listing-before-filename-regexp"))
            (beginning-of-line)
            #f)
           (raise-error (error "No file on this line"))
           (else #f)))))

    (define (dired-move-to-end-of-filename . rest)
      ;; GNU Emacs's `dired-move-to-end-of-filename' (dired.el:3530):
      ;; "Assumes point is at beginning of filename. On failure, signals
      ;; an error (with non-nil NO-ERROR just returns nil)."
      ;;
      ;; With the property, the end is one lookup. Without it the C
      ;; re-derives the file type from the mode string, guesses symlinks
      ;; by searching for ` -> ', and subtracts characters to undo
      ;; `-F''s marker - which is the cost the property is there to
      ;; avoid.
      ;;
      ;; The C's `if hidden' has its guard and its answer as *siblings*
      ;; in the `let', not inside the else: a hidden line moves point
      ;; nowhere and so reaches the `(error "File line is hidden...")'
      ;; arm. Putting them inside the else, which an earlier version of
      ;; this did, means a hidden line answers nil instead of signalling.
      ;;--------------------------------------------------------------
      (let ((no-error (and (pair? rest) (car rest))))
        (if (get-text-property (- (point) 1) dired-filename-property)
            ;; no LIMIT, so "no further change" answers #f and the C's
            ;; `(1- (point-max))' is the fallback; see
            ;; `dired-move-to-filename' for the zero/one-based seam.
            (let ((change (next-single-property-change (- (point) 1)
                                                       dired-filename-property)))
              (goto-char (if change (+ change 1) (- (point-max) 1))))
            (let ((opoint (point))
                  (used-f (dired-check-switches (dired-actual-switches)
                                                "F" "classify"))
                  (eol (line-end-position))
                  (hidden (dired--hidden-p))
                  (file-type #f) (executable #f) (symlink #f))
              (if hidden
                  #f
                  (begin
                    ;; "Find out what kind of file this is" - the C's
                    ;; `save-excursion' wraps this part alone, so it is
                    ;; the movement below that moves point.
                    (save-excursion
                      (if (re-search-backward dired-permission-flags-regexp #f #t)
                          (begin
                            (set! file-type (char-after (match-beginning 1)))
                            (set! symlink (char=? file-type #\l))
                            (set! executable
                                  (and used-f
                                       (string-match "[xst]"
                                                     (string-append
                                                      (match-string 2)
                                                      (match-string 3)
                                                      (match-string 4))))))
                          (if (not no-error) (error "No file on this line"))))
                    ;; "Move point to end of name".
                    (if symlink
                        ;; The `" -> "` separates the link from its
                        ;; target, so its start is the end of the name.
                        ;; When there is none the C does not move point
                        ;; at all - the inner `if' has no else - and the
                        ;; `opoint' test below then answers nil.
                        ;; Answering `eol' here, which the port did,
                        ;; would quietly invent a name rather than fail.
                        (if (search-forward " -> " eol #t)
                            (begin
                              (forward-char -4)
                              (if (and used-f
                                       (*dired-ls-F-marks-symlinks*)
                                       (char=? (char-before) #\@))
                                  (forward-char -1)))
                            #f)
                        ;; "else not a symbolic link": the name runs to
                        ;; the end of the line, and only `-F''s
                        ;; one-character type marker is backed off.
                        ;;
                        ;; This `(goto-char eol)' is the line the port had
                        ;; dropped - it had put one in the *symlink*
                        ;; branch, where the C has none. Without it point
                        ;; never moved, so the test below answered nil for
                        ;; every ordinary file: `dired-get-filename'
                        ;; returned nil for a whole listing whenever the
                        ;; `dired-filename' property was absent.
                        (begin
                          (goto-char eol)
                          ;; "ls -lF marks dirs, sockets, fifos and
                          ;; executables with exactly one trailing
                          ;; character. (Executable bits on symlinks
                          ;; ain't mean a thing, even to ls, but we know
                          ;; it's not a symlink.)"
                          (if (and used-f
                                   (or (memv file-type (list #\d #\s #\p))
                                       executable))
                              (forward-char -1))))))
              (if (or no-error (not (eq? opoint (point))))
                  (if (eq? opoint (point)) #f (point))
                  (error "%s"
                         ;; the C wraps the hidden message in
                         ;; `substitute-command-keys', which is not
                         ;; ported, so the `\\[...]' stands as itself
                         (if hidden
                             "File line is hidden, type \\[dired-hide-subdir] to unhide"
                             "No file on this line")))))))
    (define (dired-get-filename . rest)
      ;; GNU Emacs's `dired-get-filename' (dired.el:3280): "In Dired,
      ;; return name of file mentioned on this line."
      ;;
      ;; LOCALP is `no-dir', `verbatim', t or nil, and
      ;; NO-ERROR-IF-NOT-FILEP treats `.' and `..' as regular names.
      ;;--------------------------------------------------------------
      (let* ((localp (if (pair? rest) (car rest) #f))
             (no-error-if-not-filep (and (pair? rest) (pair? (cdr rest))
                                         (cadr rest)))
             (already-absolute #f)
             (p1 #f)
             (p2 #f)
             (file #f))
        ;; The C is `(save-excursion (if (setq p1 (dired-move-to-filename
        ;; ...)) (setq p2 (dired-move-to-end-of-filename ...))))': the
        ;; two moves are how the name is *found*, and point is left where
        ;; the caller had it. Without the `save-excursion' - which this
        ;; did not have - every caller that asks on a line and then
        ;; carries on from point is moved to the end of the name:
        ;; `dired-remember-marks' then read its mark character from the
        ;; wrong place and `dired-remind-marks' loop never advanced.
        (save-excursion
          (set! p1 (dired-move-to-filename (not no-error-if-not-filep)))
          (if p1
              (set! p2 (dired-move-to-end-of-filename no-error-if-not-filep))))
        (set! file (and p1 p2 (buffer-substring p1 p2)))
        (when file
          ;; "Get rid of the mouse-face property that file names have" -
          ;; the property is on the string `buffer-substring' answered
          ;; with, which is why that line exists in the C at all.
          ;; `string-length' and not `length': Emacs's `length' takes a
          ;; string and Guile's does not - it is the list length, and a
          ;; string is not a list.
          (set-text-properties 0 (string-length file) '() file)
          ;; "Unquote names quoted by ls or by dired-insert-directory.
          ;; This code was written using `read' to unquote."
          (let loop ()
            (if (string-match "\\([^\\]\\|\\`\\)\\(\"\\)" file)
                (begin
                  (set! file (replace-match "\\\"" #f #t file 1))
                  (loop))))
          ;; Emacs's `read' takes a *string*; Guile's takes a port, so
          ;; the string has to be wrapped in one.
          (set! file (read (open-input-string (string-append "\"" file "\"")))))
        ;; "Hence we don't need to worry about converting `\\' back to `\'"
        (set! already-absolute (and file (files--name-absolute-system-p file)))
        (cond
         ((not file) #f)
         ((eq? localp 'verbatim) file)
         ((and (not no-error-if-not-filep)
               (member file '("." "..")))
          (error "Cannot operate on `.' or `..'"))
         ((and (eq? localp 'no-dir) already-absolute)
          (file-name-nondirectory-part file))
         (already-absolute
          ;; the C wraps the name for a file name handler that is not
          ;; `safe-magic' - handlers are not ported, so the name stands
          file)
         ((eq? localp 'no-dir) file)
         ;; The C has this arm and the last one separately, differing only
         ;; in the same handler wrapping; and both *concatenate* rather
         ;; than expand. That is what keeps `.' and `..' as themselves:
         ;; `expand-file-name' would turn `.' into the directory and `..'
         ;; into its parent, and `dired-goto-next-nontrivial-file''s test
         ;; - which asks whether the name is `.' or `..' - then never
         ;; matches, so point stays on the `.' line.
         (else (string-append (dired-current-directory localp) file)))))

    (define (dired-repeat-over-lines arg function)
      ;; GNU Emacs's `dired-repeat-over-lines': "This version skips
      ;; non-file lines."
      ;;--------------------------------------------------------------
      (let ((pos (point-marker)))
        (beginning-of-line)
        (let loop ((arg arg))
          (when (and (> arg 0) (not (eobp)))
            (set! arg (- arg 1))
            (beginning-of-line)
            (let skip ((looping #t))
              (when (and looping (not (eobp)))
                (if (dired-between-files)
                    (begin (forward-line 1) (skip (not (eobp))))
                    (set! looping #f))))
            (save-excursion
              (forward-line 1)
              (set-marker! pos (point)))
            (save-excursion (function))
            ;; "Advance to the next line - actually, to the line that
            ;; *was* next. (If FUNCTION inserted some new lines in
            ;; between, skip them.)"
            (goto-char (marker-position pos))
            (loop arg)))
        (let loop ((arg arg))
          (when (and (< arg 0) (not (bobp)))
            (set! arg (+ arg 1))
            (forward-line -1)
            (let skip ((looping #t))
              (when (and looping (not (bobp)))
                (if (dired-between-files)
                    (begin (forward-line -1) (skip (not (bobp))))
                    (set! looping #f))))
            (beginning-of-line)
            (save-excursion (function))
            (loop arg)))
        (set-marker! pos #f)
        (dired-move-to-filename)))

    (define (dired-insert-directory dir switches . rest)
      ;; GNU Emacs's `dired-insert-directory' (dired.el:1806): "Insert a
      ;; directory listing of DIR, Dired style. If HDR is non-nil, insert
      ;; a header line with the directory name."
      ;;
      ;; The C's three arms are its two ways of *running* `ls' and the
      ;; one way of not running it. Only the last is here - this editor
      ;; lists with `ls-lisp' everywhere - and so are only the pieces of
      ;; the tail that follow from it. Named rather than faked:
      ;;
      ;;   * `--dired -N' and the `-d' the wildcard arm prepends: they
      ;;     are for `insert-directory-program'.
      ;;   * the quoting of `\' and `^M' the C does "unless ls quoted
      ;;     them for us". ls-lisp does not quote, so a name holding
      ;;     either comes through as itself; Emacs would show `\\' and
      ;;     `\015'. It needs `replace-match' carrying the match's own
      ;;     text properties, which is a piece of its own.
      ;;   * `dired--insert-disk-space', which runs `df'.
      ;;   * the wildcard line and `dired--make-directory-clickable'.
      ;;--------------------------------------------------------------
      (let ((opoint (point))
            (file-list (if (pair? rest) (car rest) #f))
            (wildcard (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (hdr (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                      (caddr rest))))
        (insert-directory dir switches wildcard (not wildcard))
        ;; "If we used --dired and it worked, the lines are already
        ;; indented. Otherwise, indent them."
        (if (not (save-excursion (goto-char opoint) (looking-at-p "  ")))
            (parameterize ((*indent-tabs-mode* #f))
              (indent-rigidly opoint (point) 2)))
        ;; "Insert text at the beginning to standardize things."
        (let ((content-point opoint))
          (save-excursion
            (goto-char opoint)
            (when (and (or hdr wildcard)
                       (not (and (looking-at "^  \\(.*\\):$")
                                 (file-name-absolute-p (match-string 1)))))
              (let* ((dir-indent "  ")
                     (dir-name (directory-file-name
                                (file-name-directory-part dir))))
                (insert dir-indent dir-name ":\n"))
              (set! content-point (point))))
          (dired-insert-set-properties content-point (point)))))

    (define (dired-insert-set-properties beg end)
      ;; GNU Emacs's `dired-insert-set-properties' (dired.el:2087): "Add
      ;; various text properties to the lines in the region, from BEG to
      ;; END."
      ;;
      ;; What is ported is the part that matters without
      ;; `dired-hide-details-mode' and the mouse: a line with no file on
      ;; it is marked invisible, and a line with one carries
      ;; `dired-filename' over the name - which is the seed
      ;; `dired-move-to-filename' reads. The overlays the C puts on for
      ;; `dired-filename-display-length', and the `invisible' detail
      ;; properties for the hide-details toggles, are not ported; see the
      ;; library comment.
      ;;--------------------------------------------------------------
      (save-excursion
        (goto-char beg)
        ;; The C's `(while (< (point) end) ...)'. Scheme has no `while',
        ;; and `while' is not one - it is Elisp's, and an unbound `while'
        ;; swallows the whole command into a key that does nothing.
        (let loop ()
         (when (< (point) end)
          (guard (e (#t #f))
            (if (not (dired-move-to-filename))
                (if (looking-at-p "^$")
                    #f
                    ;; The property functions' positions are the
                    ;; interval tree's, and this tree's is ZERO-based
                    ;; where Emacs's is BEG-relative with BEG = 1 - the
                    ;; C's `find_interval' subtracts `BUF_BEG'
                    ;; (intervals.c:614). So every position that goes to
                    ;; one is converted here at the seam, as
                    ;; `dired-move-to-filename' converts its own. Doing
                    ;; it in two places and not the third is what left
                    ;; `dired-filename' one position to the right: the
                    ;; name's property ran over the newline and into the
                    ;; next line, so `next-single-property-change'
                    ;; answered a position past the line and
                    ;; `dired-get-filename' read a name with a newline
                    ;; in it.
                    (put-text-property (- (line-beginning-position) 1)
                                       (line-end-position)
                                       'invisible 'dired-hide-details-information))
                (let ((opoint (point)))
                  (save-excursion
                    (dired-move-to-end-of-filename)
                    (add-text-properties
                     (- opoint 1) (- (point) 1)
                     (list dired-filename-property #t
                           'mouse-face 'highlight
                           'help-echo "mouse-2: visit this file in other window"))))))
          (forward-line 1)
          (loop)))))

    ;;----------------------------------------------------------------
    ;; Moving
    ;;------------------------------------------------------------------

    (define-command (dired-next-line arg)
      "Move down ARG lines, then position at filename."
      (interactive (list 1))
      (forward-line arg)
      (dired-move-to-filename))

    (define-command (dired-previous-line arg)
      "Move up ARG lines, then position at filename."
      (interactive (list 1))
      (dired-next-line (- arg)))

    ;;----------------------------------------------------------------
    ;; Marking
    ;;------------------------------------------------------------------

    (define (dired-mark-files-in-region start end)
      ;; GNU Emacs's `dired-mark-files-in-region'.
      ;;--------------------------------------------------------------
      (parameterize ((*inhibit-read-only* #t))
        (if (> start end) (error "Start > End"))
        (goto-char start)                ; assumed at beginning of line
        (let loop ()
          (when (< (point) end)
            (let skip ((looping #t))
              (when (and looping (< (point) end))
                (if (dired-between-files)
                    (begin (forward-line 1) (skip (< (point) end)))
                    (set! looping #f))))
            (if (and (not (looking-at-p dired-re-dot))
                     (dired-get-filename #f #t))
                (begin (delete-char 1) (insert (*dired-marker-char*))))
            (forward-line 1)
            (loop)))))

    (define-command (dired-mark arg interactive)
      "Mark the file at point in the Dired buffer.
With a prefix arg, mark files on the next ARG lines."
      (interactive (list (current-prefix-arg) #t))
      ;; The C's first branch - marking the *region* when
      ;; `dired-mark-region' says so and the mark is active - is not
      ;; ported; see the library comment.
      (parameterize ((*inhibit-read-only* #t))
        (dired-repeat-over-lines
         arg
         (lambda ()
           (if (or (not (looking-at-p dired-re-dot))
                   ;; "Don't skip symlinks to `.', `..', etc."
                   (save-excursion
                     (re-search-forward dired-permission-flags-regexp #f #t)
                     (char=? (char-after (match-beginning 1)) #\l))
                   (not (equal? (*dired-marker-char*) (*dired-del-marker*))))
               (begin (delete-char 1)
                      (insert (*dired-marker-char*))))))))

    (define-command (dired-unmark arg interactive)
      "Unmark the file at point in the Dired buffer."
      (interactive (list (current-prefix-arg) #t))
      (parameterize ((*dired-marker-char* #\space))
        (dired-mark arg interactive)))

    (define-command (dired-flag-file-deletion arg interactive)
      "In Dired, flag the current line's file for deletion."
      (interactive (list (current-prefix-arg) #t))
      (parameterize ((*dired-marker-char* (*dired-del-marker*)))
        (dired-mark arg interactive)))

    ;;----------------------------------------------------------------
    ;; The commands whose homes are `files.el' and `window.el'
    ;;------------------------------------------------------------------

    (define-command (dired-find-file)
      "In Dired, visit the file or directory named on this line."
      (interactive)
      (find-file (dired-get-filename)))

    ;;----------------------------------------------------------------
    ;; The dired buffers: the registry, and reading a directory in
    ;;------------------------------------------------------------------
    ;;
    ;; `dired-noselect' is the way in. `dired-internal-noselect' finds
    ;; the buffer or makes one, `dired-readin' fills it, and it is
    ;; registered in `dired-buffers' so that asking for a directory a
    ;; second time reuses the buffer Emacs's way.

    (define *dired-buffers* (make-parameter '()))
    ;; ^ GNU Emacs's `dired-buffers' (dired.el:1517): "Alist of expanded
    ;; directories and their associated Dired buffers." `dired-advertise'
    ;; enlarges it and `dired-buffers-for-dir' queries it; a killed buffer
    ;; found there is dropped, which is Emacs's own cleanup and the reason
    ;; it is an alist and not a list.

    (define (dired-buffers) (*dired-buffers*))
    (define (set!dired-buffers! value) (*dired-buffers* value))

    (define *dired-subdir-alist* (make-parameter '()))
    (define (dired-subdir-alist)
      (buffer-local-value (current-buffer) '*dired-subdir-alist*
                          (*dired-subdir-alist*)))
    (define (set!dired-subdir-alist! value)
      (set-buffer-local-value! (current-buffer) '*dired-subdir-alist* value))

    (define *dired-initial-position-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `dired-initial-position-hook' (dired.el): "Hook run
    ;; by `dired-initial-position'."

    (define dired-subdir-regexp "^. \\(.+\\)\\(:\\)\n")
    ;; ^ GNU Emacs's `dired-subdir-regexp' (dired.el:646): "Regexp
    ;; matching a maybe hidden subdirectory line in `ls -lR' output.
    ;; Subexpression 1 is the subdirectory proper, no trailing colon. The
    ;; match starts at the beginning of the line and ends after the end of
    ;; the line."
    ;;
    ;; What it matches in *this* port is the header line
    ;; `dired-insert-directory' writes - two spaces, the name, a colon,
    ;; a newline - so the top level directory of a plain listing is one of
    ;; its matches, and that is where dired's idea of "which directory
    ;; this buffer is showing" comes from.

    (define (dired-in-this-tree-p file dir)
      ;; GNU Emacs's `dired-in-this-tree-p' (dired.el:3756): "Is FILE part
      ;; of the directory tree starting at DIR?" The answer is a match
      ;; position or nil, as the C's `string-match-p' is - callers use it
      ;; as a boolean.
      ;;--------------------------------------------------------------
      (string-match-p (string-append "^" (regexp-quote dir)) file))

    (define (dired-normalize-subdir dir)
      ;; GNU Emacs's `dired-normalize-subdir' (dired.el:3764): "Prepend
      ;; default-directory to DIR if relative file name.
      ;; `dired-get-filename' must be able to make a valid file name from a
      ;; file and its directory DIR."
      ;;--------------------------------------------------------------
      (file-name-as-directory
       (if (file-name-absolute-p dir)
           dir
           (expand-file-name dir (default-directory)))))

    (define (dired-clear-alist)
      ;; GNU Emacs's `dired-clear-alist' (dired.el:3791): every marker in
      ;; the alist is unset, so a marker does not keep a dead buffer or a
      ;; stale position alive.
      ;;--------------------------------------------------------------
      (let loop ()
        (when (pair? (dired-subdir-alist))
          (set-marker! (cdr (car (dired-subdir-alist))) #f)
          (set!dired-subdir-alist! (cdr (dired-subdir-alist)))
          (loop))))

    (define (dired-alist-add-1 dir new-marker)
      ;; GNU Emacs's `dired-alist-add-1' (dired.el:3918): "Add new DIR at
      ;; NEW-MARKER. Don't sort."
      ;;--------------------------------------------------------------
      (set!dired-subdir-alist!
       (cons (cons (dired-normalize-subdir dir) new-marker)
             (dired-subdir-alist))))

    (define (dired-build-subdir-alist . rest)
      ;; GNU Emacs's `dired-build-subdir-alist' (dired.el:3827): "Build
      ;; `dired-subdir-alist' by parsing the buffer. Returns the new value
      ;; of the alist."
      ;;
      ;; The C also *edits* each heading, replacing the name with its
      ;; expansion when a recursive listing gave it a relative one, and
      ;; marks the absolute part `invisible' for
      ;; `dired-hide-details-hide-absolute-location'.
      ;; `dired-insert-directory' writes an absolute name, so the
      ;; replacement is the same string here and the property belongs to
      ;; hide-details, which is not ported. `dired-switches-recursive-p' -
      ;; whose `-R' listings are the only ones with more than one heading,
      ;; and which is also what the C's ange-ftp arm keys off - is the
      ;; subdirectory work still to come; so is the `(> count 1)' message.
      ;;--------------------------------------------------------------
      (dired-clear-alist)
      (save-excursion
        (let ((file-entry-beg-re (string-append dired-re-maybe-mark
                                                dired-re-inode-size
                                                dired-re-perms)))
          (goto-char (point-min))
          (set!dired-subdir-alist! '())
          (let loop ()
            (when (re-search-forward dired-subdir-regexp #f #t)
              ;; "Avoid taking a file name ending in a colon as a subdir
              ;; name."
              (unless (save-excursion
                        (goto-char (match-beginning 0))
                        (beginning-of-line)
                        (looking-at-p file-entry-beg-re))
                (save-excursion
                  (goto-char (match-beginning 1))
                  (let ((new-dir-name (buffer-substring-no-properties
                                       (point) (match-end 1))))
                    (dired-alist-add-1
                     (expand-file-name new-dir-name)
                     ;; "Place a sub directory boundary between lines."
                     (save-excursion
                       (goto-char (match-beginning 0))
                       (beginning-of-line)
                       (point-marker))))))
              (loop))))
        (dired-subdir-alist)))

    (define (dired-buffers-for-dir dir . rest)
      ;; GNU Emacs's `dired-buffers-for-dir' (dired.el:3655): "Return a
      ;; list of buffers for DIR (top level or in-situ subdir). ... The
      ;; list is in reverse order of buffer creation, most recent last.
      ;; As a side effect, killed Dired buffers for DIR are removed from
      ;; `dired-buffers'."
      ;;
      ;; Not ported: the FILE argument's wildcard test, which is for a
      ;; buffer whose `dired-directory' is a wildcard pattern.
      ;;--------------------------------------------------------------
      (let ((dir (file-name-as-directory (expand-file-name dir))))
        (let loop ((rest (dired-buffers)) (result '()))
          (cond
           ((null? rest) result)
           (else
            (let ((elt (car rest)))
              (let ((buf (cdr elt)))
                (cond
                 ;; "Buffer is killed - clean up"
                 ((not (buffer-name buf))
                  (set!dired-buffers! (delq elt (dired-buffers)))
                  (loop (cdr rest) result))
                 ((dired-in-this-tree-p dir (car elt))
                  (with-current-buffer buf
                    (if (assoc dir (dired-subdir-alist))
                        (loop (cdr rest) (cons buf result))
                        (loop (cdr rest) result))))
                 (else (loop (cdr rest) result))))))))))

    (define (dired-advertise)
      ;; GNU Emacs's `dired-advertise' (dired.el:3735): "Advertise in
      ;; variable `dired-buffers' that we dired `default-directory'."
      ;;--------------------------------------------------------------
      (let ((expanded-default (expand-file-name (default-directory))))
        (if (memq (current-buffer) (dired-buffers-for-dir expanded-default))
            #f                          ; "we have already advertised ourselves"
            (set!dired-buffers!
             (cons (cons expanded-default (current-buffer))
                   (dired-buffers))))))

    (define (dired-unadvertise dir)
      ;; GNU Emacs's `dired-unadvertise' (dired.el:3745): "Remove DIR from
      ;; the buffer alist in variable `dired-buffers'. This has the effect
      ;; of removing any buffer whose main directory is DIR. It does not
      ;; affect buffers in which DIR is a subdir."
      ;;--------------------------------------------------------------
      (set!dired-buffers!
       (delq (assoc (expand-file-name dir) (dired-buffers))
             (dired-buffers))))

    (define (dired-find-buffer-nocreate dirname . rest)
      ;; GNU Emacs's `dired-find-buffer-nocreate' (dired.el:1526): "This
      ;; differs from `dired-buffers-for-dir' in that it does not consider
      ;; subdirs of default-directory and searches for the first match
      ;; only. Also, the major mode must be MODE."
      ;;
      ;; The C's first arm is `dired-x''s - `dired-find-subdir', which is
      ;; what looks in subdirectories - and that library is not ported, so
      ;; the arm taken is the other one.
      ;;--------------------------------------------------------------
      (let ((mode (if (and (pair? rest) (car rest)) (car rest) 'dired-mode))
            (dirname (expand-file-name dirname)))
        (let loop ((blist (dired-buffers)))
          (cond
           ((null? blist) #f)
           (else
            (let ((buf (cdr (car blist))))
              (if (not (buffer-name buf))
                  (loop (cdr blist))
                  (let ((found
                         (with-current-buffer buf
                           (if (and (eq? (major-mode) mode)
                                    (dired-directory)
                                    (equal? dirname
                                            (expand-file-name
                                             (if (pair? (dired-directory))
                                                 (car (dired-directory))
                                                 (dired-directory)))))
                               buf
                               #f))))
                    (if found found (loop (cdr blist)))))))))))

    (define (dired-noselect dir-or-list . rest)
      ;; GNU Emacs's `dired-noselect' (dired.el:1293): "Like `dired' but
      ;; return the Dired buffer as value, do not select it."
      ;;
      ;; "This loses the distinction between "/foo/*/" and "/foo/*" that
      ;; some shells make."
      ;;
      ;; Not ported: `find-file-visit-truename' (nil by default), which is
      ;; what would replace the name with its truename.
      ;;--------------------------------------------------------------
      (let* ((switches (and (pair? rest) (car rest)))
             (dir-or-list (or dir-or-list (default-directory)))
             (dirname (if (pair? dir-or-list) (car dir-or-list) dir-or-list))
             (initially-was-dirname
              (string=? (file-name-as-directory dirname) dirname))
             (dirname (abbreviate-file-name
                       (expand-file-name (directory-file-name dirname))))
             ;; "If the argument was syntactically a directory name not a
             ;; file name, or if it happens to name a file that is a
             ;; directory, convert it syntactically to a directory name.
             ;; The reason for checking initially-was-dirname and not just
             ;; file-directory-p is that file-directory-p is slow over
             ;; ftp."
             (dirname (if (or initially-was-dirname (file-directory-p dirname))
                          (file-name-as-directory dirname)
                          dirname))
             (dir-or-list (if (pair? dir-or-list)
                              (cons dirname (cdr dir-or-list))
                              dirname)))
        (dired-internal-noselect dir-or-list switches)))

    (define (dired-sort-other switches . rest)
      ;; GNU Emacs's `dired-sort-other' (dired.el:5246): "Specify new `ls'
      ;; SWITCHES for current Dired buffer. ... With optional second arg
      ;; NO-REVERT, don't refresh the listing afterwards."
      ;;
      ;; Not ported: `dired-sort-R-check', which saves and restores
      ;; `dired-subdir-alist' across the `-R' switch and so is the
      ;; subdirectory work, and `dired-sort-set-mode-line', which shows
      ;; "by name"/"by date" in the mode line.
      ;;--------------------------------------------------------------
      (let ((no-revert (and (pair? rest) (car rest))))
        (set!dired-actual-switches! switches)
        (if (not no-revert) (revert-buffer))))

    (define (dired-readin)
      ;; GNU Emacs's `dired-readin' (dired.el:1570): "Read in a new Dired
      ;; buffer. Differs from `dired-insert-subdir' in that it accepts
      ;; wildcards, erases the buffer, and builds the subdir-alist anew."
      ;;
      ;; "default-directory and dired-actual-switches must be buffer-local
      ;; and initialized by now" - `dired-internal-noselect' does that
      ;; before it calls this.
      ;;
      ;; Not ported: `file-name-coding-system' (no file-name coding system
      ;; here), `set-visited-file-modtime' (which belongs to the
      ;; auto-revert staleness `dired-buffer-stale-p' reports - not
      ;; ported), `dired--make-directory-clickable', and the `widen',
      ;; there being no narrowing to undo.
      ;;--------------------------------------------------------------
      (save-excursion
        ;; "This hook which may want to modify `dired-actual-switches'
        ;; based on `dired-directory'"
        (run-hooks *dired-before-readin-hook*)
        (parameterize ((*inhibit-read-only* #t))
          (erase-buffer)
          (dired-readin-insert))
        (goto-char (point-min))
        ;; "Must first make alist buffer local and set it to nil because
        ;; dired-build-subdir-alist will call dired-clear-alist first"
        (set!dired-subdir-alist! '())
        (dired-build-subdir-alist)
        ;; "readin is simple and it is not affected by the user, so don't
        ;; treat it as a modification"
        (set-buffer-modified-p #f)
        ;; "The hook can successfully use dired functions (e.g.
        ;; dired-get-filename) as the subdir-alist has been built in
        ;; dired-readin."
        (run-hooks *dired-after-readin-hook*)))

    (define (dired-readin-insert)
      ;; GNU Emacs's `dired-readin-insert' (dired.el:1626): "Insert
      ;; listing for the specified dir (and maybe file list) already in
      ;; `dired-directory', assuming a clean buffer."
      ;;
      ;; Not ported: `insert-directory-wildcard-in-dir-p', whose wildcard
      ;; test is the first half of the C's "inaccessible" condition, and
      ;; the `ls' error-file cleanup, which is for
      ;; `insert-directory-program' - ls-lisp leaves no such file.
      ;;--------------------------------------------------------------
      (let ((dir (if (pair? (dired-directory))
                     (car (dired-directory))
                     (dired-directory)))
            (file-list (and (pair? (dired-directory))
                            (cdr (dired-directory)))))
        (let ((dir (expand-file-name dir)))
          (cond
           ;; "If we are reading a whole single directory..."
           ((and (string=? "" (file-name-nondirectory-part dir))
                 (not file-list))
            (dired-insert-directory dir (dired-actual-switches) #f
                                    (not (file-directory-p dir)) #t))
           ((not (file-readable-p
                  (directory-file-name (file-name-directory-part dir))))
            (error "Directory %s inaccessible or nonexistent" dir))
           (else
            ;; "Else treat it as a wildcard spec unless we have an
            ;; explicit list of files."
            (dired-insert-directory dir (dired-actual-switches)
                                    file-list (not file-list) #t))))))

    (define (dired-make-relative file . rest)
      ;; GNU Emacs's `dired-make-relative' (dired.el:3395): "Convert FILE
      ;; (an absolute file name) to a name relative to DIR. If DIR is
      ;; omitted or nil, it defaults to `default-directory'. If FILE is
      ;; not in the directory tree of DIR, return FILE unchanged."
      ;;--------------------------------------------------------------
      (let* ((dir (if (and (pair? rest) (car rest))
                      (car rest)
                      (default-directory)))
             ;; "This case comes into play if default-directory is set to
             ;; use ~."
             (dir (if (string-match-p "\\(\\`\\|:\\)~" dir)
                      (expand-file-name dir)
                      dir)))
        (if (string-match (string-append "^" (regexp-quote dir)) file)
            (substring file (match-end 0))
            file)))

    (define (dired-current-directory . rest)
      ;; GNU Emacs's `dired-current-directory' (dired.el:4039): "Return
      ;; the name of the subdirectory to which this line belongs. This
      ;; returns a string with trailing slash, like `default-directory'.
      ;; Optional argument means return a file name relative to
      ;; `default-directory'."
      ;;--------------------------------------------------------------
      (let ((localp (and (pair? rest) (car rest)))
            (here (point))
            ;; `(pair? ...)' and not `(or ...)': the C's `(or
            ;; dired-subdir-alist (error ...))' raises for nil, and `'()'
            ;; is *true* here - so a buffer with no alist would fall
            ;; through and answer #f, which `string-append' then rejects
            ;; three frames away.
            (alist (if (pair? (dired-subdir-alist))
                       (dired-subdir-alist)
                       (error "No subdir-alist in %s" (buffer-name)))))
        (let loop ((rest alist) (dir #f))
          (if (null? rest)
              (if localp
                  (dired-make-relative dir (default-directory))
                  dir)
              (let ((elt (car rest)))
                (if (<= (marker-position (cdr elt)) here)
                    ;; "use `<=' (not `<') as subdir line is part of subdir"
                    (if localp
                        (dired-make-relative (car elt) (default-directory))
                        (car elt))
                    (loop (cdr rest) (car elt))))))))

    (define (dired-subdir-max)
      ;; GNU Emacs's `dired-subdir-max' (dired.el:4057): "Subdirs start at
      ;; the beginning of their header lines and end just before the
      ;; beginning of the next header line (or end of buffer)."
      ;;
      ;; The C's second arm is `dired-next-subdir', which moves through
      ;; the alist - and it is only reached when there is more than one
      ;; entry, which is the subdirectory work. The first arm is the one
      ;; every buffer this port makes takes.
      ;;--------------------------------------------------------------
      (save-excursion
        (if (or (null? (cdr (dired-subdir-alist)))
                (not (dired-next-subdir 1 #t #t)))
            (point-max)
            (point))))

    (define (dired-goto-next-file)
      ;; GNU Emacs's `dired-goto-next-file' (dired.el:3935): advance to the
      ;; next line that has a file on it.
      ;;
      ;; The C's bound is `(1- (dired-subdir-max))'.
      ;;--------------------------------------------------------------
      (let ((max (- (dired-subdir-max) 1)))
        ;; `while' is Elisp's, and Scheme has no `while' - one left in by
        ;; accident is an unbound variable, so the whole command becomes
        ;; a key that does nothing.
        (let loop ()
          (when (and (not (dired-move-to-filename)) (< (point) max))
            (forward-line 1)
            (loop)))))

    (define (dired-goto-next-nontrivial-file)
      ;; GNU Emacs's `dired-goto-next-nontrivial-file' (dired.el:3924):
      ;; "Position point on first nontrivial file after point."
      ;;--------------------------------------------------------------
      (dired-goto-next-file)            ; "so there is a file to compare with"
      (if (string? (*dired-trivial-filenames*))
          (let loop ()
            (when (and (not (eobp))
                       (string-match-p
                        (*dired-trivial-filenames*)
                        (file-name-nondirectory-part
                         (or (dired-get-filename #f #t) ""))))
              (forward-line 1)
              (dired-move-to-filename)
              (loop)))))

    (define (dired-initial-position dirname)
      ;; GNU Emacs's `dired-initial-position' (dired.el:4022): "Return
      ;; position of point in a new listing of DIRNAME. Point is assumed to
      ;; be at the beginning of a new subdir line. Runs the hook
      ;; `dired-initial-position-hook'."
      ;;
      ;; Not ported: the C's `(and (featurep 'dired-x) dired-find-subdir
      ;; (dired-goto-subdir dirname))', which is dired-x's.
      ;;--------------------------------------------------------------
      (end-of-line)
      (when (*dired-trivial-filenames*) (dired-goto-next-nontrivial-file))
      (run-hooks *dired-initial-position-hook*))

    (define (dired-internal-noselect dir-or-list . rest)
      ;; GNU Emacs's `dired-internal-noselect' (dired.el:1411).
      ;;
      ;; "If DIR-OR-LIST is a string and there is an existing dired buffer
      ;; for it, just leave buffer as it is (don't even call
      ;; `dired-revert'). This saves time especially for deep trees or
      ;; with ange-ftp. The user can type `g' easily, and it is more
      ;; consistent with find-file."
      ;;
      ;; Not ported: `dired-auto-revert-buffer' and the offer to revert a
      ;; directory that changed on disk (`dired-directory-changed-p'),
      ;; `dired--align-all-files', the literal-newline warning, and the
      ;; `ls'-error `unwind-protect' - each named where the C has it.
      ;;--------------------------------------------------------------
      (let* ((switches (and (pair? rest) (car rest)))
             (mode (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (old-buf (current-buffer))
             (dirname (if (pair? dir-or-list) (car dir-or-list) dir-or-list))
             (found (dired-find-buffer-nocreate dirname mode))
             (new-buffer-p (not found))
             (buffer (or found (create-file-buffer dirname))))
        (set-buffer buffer)
        (if (not new-buffer-p)
            ;; "existing buffer ..."
            (cond
             (switches
              ;; "... but new switches. file list may have changed ...
              ;; this calls dired-revert"
              (set!dired-directory! dir-or-list)
              (dired-sort-other switches))
             ;; "Always revert when `dir-or-list' is a cons."
             ((or (pair? dir-or-list) (pair? (dired-directory)))
              (set!dired-directory! dir-or-list)
              (revert-buffer))
             (else #f))
            ;; "Else a new buffer"
            (begin
              (set!buffer-default-directory buffer
                                             (file-name-directory-part dirname))
              (unless switches (set! switches (*dired-listing-switches*)))
              (if mode (mode) (dired-mode dir-or-list switches))
              ;; "default-directory and dired-actual-switches are set now
              ;; (buffer-local), so we can call dired-readin"
              (dired-readin)
              (goto-char (point-min))
              (dired-initial-position dirname)))
        (set-buffer old-buf)
        buffer))

    (define (dired-read-dir-and-switches str)
      ;; GNU Emacs's `dired-read-dir-and-switches' (dired.el:1124): "For
      ;; use in interactive."
      ;;
      ;; The C calls `read-directory-name' instead of `read-file-name'
      ;; when a dialog is about to be used, so that a dialog knows to ask
      ;; for a directory; there is no dialog here, so the arm taken is the
      ;; other one - which is also the one that lets a file name be
      ;; completed for a wildcard pattern.
      ;;--------------------------------------------------------------
      (reverse
       (list
        (if (current-prefix-arg)
            (read-from-minibuffer "Dired listing switches: "
                                  (*dired-listing-switches*))
            #f)
        (read-file-name (string-append "Dired " str "(directory): ")
                        (default-directory) (default-directory) #f))))

    (define-command (dired dirname switches)
      "\"Edit\" directory DIRNAME--delete, rename, print, etc. some files in it.
Optional second argument SWITCHES specifies the options to be used
when invoking `insert-directory-program', usually `ls', which produces
the listing of the directory files and their attributes.
Interactively, a prefix argument will cause the command to prompt
for SWITCHES."
      ;; "Cannot use (interactive \"D\") because of wildcards."
      (interactive (dired-read-dir-and-switches ""))
      (let ((buf (dired-noselect dirname switches)))
        (if buf
            (pop-to-buffer-same-window buf)
            (current-buffer))))

    (define (dired-remember-marks beg end)
      ;; GNU Emacs's `dired-remember-marks' (dired.el:2364): "Return alist
      ;; of files and their marks, from BEG to END."
      ;;
      ;; Not ported: the C's unhide first - "Must unhide to make this
      ;; work" - which is `dired-hide-details-mode''s `invisible'
      ;; machinery. Nothing here hides a line, so there is nothing to
      ;; unhide.
      ;;--------------------------------------------------------------
      (let ((alist '()))
        (save-excursion
          (goto-char beg)
          (let loop ()
            (when (re-search-forward dired-re-mark end #t)
              (let ((fil (dired-get-filename #f #t)))
                (when fil
                  (set! alist (cons (cons fil (preceding-char)) alist))))
              (loop))))
        alist))

    (define (dired-mark-remembered alist)
      ;; GNU Emacs's `dired-mark-remembered' (dired.el:2377): "Mark all
      ;; files remembered in ALIST. Each element of ALIST looks like (FILE
      ;; . MARKERCHAR)."
      ;;--------------------------------------------------------------
      (save-excursion
        ;; `while' is Elisp's; `for-each' is what this is here
        (for-each
         (lambda (elt)
           (let ((fil (car elt))
                 (chr (cdr elt)))
             (when (dired-goto-file fil)
               (beginning-of-line)
               (delete-char 1)
               (insert chr))))
         alist)))

    (define (dired-goto-file-1 file full-name limit)
      ;; GNU Emacs's `dired-goto-file-1' (dired.el:3988): "Advance to the
      ;; Dired listing labeled by FILE; return its position. Return nil if
      ;; the listing is not found."
      ;;
      ;; "Filenames are preceded by SPC, this makes the search faster";
      ;; and the answer is checked, because "Match could have BASE just as
      ;; initial substring or in permission bits etc."
      ;;
      ;; Not ported: the `string-replace' of `\n' and `\t' for a `-b'
      ;; listing, since this port's listing never carries them - the `\'
      ;; doubling above it is unconditional in the C and is here too.
      ;;--------------------------------------------------------------
      (let* ((str (string-replace "\x0d;" "\\^m" file))
             (str (string-replace "\\" "\\\\" str))
             (search-string (string-append " " str)))
        (let loop ((found #f))
          (if (or found (not (search-forward search-string limit #t)))
              found
              (if (equal? full-name (dired-get-filename #f #t))
                  (dired-move-to-filename)
                  (begin (forward-line 1) (loop #f)))))))

    (define (dired-goto-file file)
      ;; GNU Emacs's `dired-goto-file' (dired.el:3940): "Go to line
      ;; describing file FILE in this Dired buffer. Return value of point
      ;; on success, else nil. FILE must be an absolute file name."
      ;;
      ;; Not ported: the C's `prog1 (push-mark)' in the interactive spec
      ;; and the `dired-mode' mode check; and its second search, for the
      ;; name relative to `default-directory', which is for buffers
      ;; `find-dired' made.
      ;;--------------------------------------------------------------
      (unless (file-name-absolute-p file)
        (error "File name `%s' is not absolute" file))
      (let* ((file (directory-file-name file)) ; "does no harm if not a directory"
             (dir (file-name-directory-part file))
             (found (or
                     ;; "First, look for a listing under the absolute name."
                     (save-excursion
                       (dired-goto-file-1 file file (point-max)))
                     ;; "Otherwise, look for it as a relative name, a base
                     ;; name only. The hair is to get the result of
                     ;; `dired-goto-subdir' without calling it if we don't
                     ;; have any subdirs."
                     (save-excursion
                       (when (if (string=? dir (expand-file-name
                                                (default-directory)))
                                 (goto-char (point-min))
                                 ;; the C's `(and (cdr dired-subdir-alist)
                                 ;; (dired-goto-subdir dir))' - the
                                 ;; subdirectory work
                                 #f)
                         (dired-goto-file-1 (file-name-nondirectory-part file)
                                            file (dired-subdir-max)))))))
        (if found (point) #f)))

    (define (dired-revert . rest)
      ;; "Reread the Dired buffer.
      ;; Must also be called after `dired-actual-switches' have changed.
      ;; Should not fail even on completely garbaged buffers.
      ;; Preserves old cursor, marks/flags, hidden-p."
      ;;
      ;; "Dired sets `revert-buffer-function' to this function. The args
      ;; ARG and NOCONFIRM, passed from `revert-buffer', are ignored." It
      ;; is not a command: the C has no `interactive' spec, and `g' is
      ;; bound to `revert-buffer', which is what finds it here.
      ;;
      ;; Not ported: the saved cursor and window positions, the hidden
      ;; subdirectories, `dired-uncache', `dired-insert-old-subdirs' and
      ;; `dired--align-all-files' - the subdirectory and widening work.
      ;;--------------------------------------------------------------
      (let ((modflag (buffer-modified-p))
            ;; marks are saved before the read, and put back after it
            (mark-alist (dired-remember-marks (point-min) (point-max))))
        ;; "Run dired-after-readin-hook just once, below."
        (let ((*dired-after-readin-hook* '()))
          (dired-readin))
        ;; The C binds `inhibit-read-only' to t around its whole body, and
        ;; `dired-mark-remembered' is what needs it: it puts each mark
        ;; back by deleting and inserting in the buffer, which is
        ;; read-only in dired-mode. `case-fold-search' is nil there too,
        ;; for the ls flags it compares.
        (parameterize ((*inhibit-read-only* #t)
                       (*case-fold-search* #f))
          (dired-mark-remembered mark-alist))
        ;; "... run the hook for the whole buffer, and only after markers
        ;; have been reinserted"
        (run-hooks *dired-after-readin-hook*)
        (unless modflag (restore-buffer-modified-p #f))))

    ;;----------------------------------------------------------------
    ;; The mode
    ;;------------------------------------------------------------------

    (define (make-dired-mode-map)
      ;; GNU Emacs's `dired-mode-map' (dired.el:2424), "Local keymap for
      ;; Dired mode buffers", whose parent is `special-mode-map'.
      ;;
      ;; The subset bound here is the one whose commands are ported; the
      ;; rest of the C's map is listed in the library comment.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*dired-mode-map*)))
        ;; the C's `:parent special-mode-map' in the map's own
        ;; `defvar-keymap' (dired.el:2427), which is where it belongs
        ;; because `dired-mode' is a plain function and not a derived mode
        (set-keymap-parent map special-mode-map)
        (define (bind! key command)
          (define-key map (if (list? key) key (list key)) command))
        (bind! #\n dired-next-line)
        (bind! #\space dired-next-line)
        (bind! #\p dired-previous-line)
        (bind! #\m dired-mark)
        (bind! #\u dired-unmark)
        (bind! #\d dired-flag-file-deletion)
        (bind! #\< delete-char)
        (bind! #\g revert-buffer)
        ;; RET is `(ctrl #\m)' and not `#\return': a terminal sends byte
        ;; 13, and Emacs's keymap has the same key, where RET and C-m are
        ;; one key.
        (bind! (list 'ctrl #\m) dired-find-file)
        (bind! #\f dired-find-file)
        (bind! #\e dired-find-file)
        (bind! #\q quit-window)
        map))

    (define dired-mode-map (make-dired-mode-map))

    ;; dired.el:1214 is `;;;###autoload (keymap-set ctl-x-map "d" #'dired)'.
    ;; It is the last thing in the file for the reason the other binding
    ;; libraries give: `define-key' holds the command's value, and Guile
    ;; resolves a binding when the form is evaluated.
    (define-key *default-keymap* (list (list 'ctrl #\x) (list #\d))
      dired)

    (define (dired-mode . rest)
      ;; GNU Emacs's `dired-mode' (dired.el:2840) is a plain function, not
      ;; a `define-derived-mode': its signature is `(&optional dirname
      ;; switches)' and `dired-internal-noselect' calls it with them for a
      ;; new buffer. Two more differences follow from that. The C's keymap
      ;; declares its parent on the map itself (`:parent special-mode-map',
      ;; dired.el:2427) rather than having the mode set it; and this tree's
      ;; `define-derived-mode' generates a function of no arguments, so the
      ;; shape had to be written out by hand.
      ;;
      ;; The C also sets things this tree has no counterpart for -
      ;; `mode-line-buffer-identification', `font-lock-defaults',
      ;; `desktop-save-buffer', `buffer-stale-function',
      ;; `buffer-auto-revert-by-notification', `page-delimiter',
      ;; `list-buffers-directory', `grep-read-files-function',
      ;; `dired-switches-alist', the invisibility spec,
      ;; `hack-dir-local-variables-non-file-buffer', the `dnd' and
      ;; isearch/context-menu hooks, and `window-point-context-*'.
      ;;--------------------------------------------------------------
      "Mode for \"editing\" directory listings."
      (let ((dirname (and (pair? rest) (car rest)))
            (switches (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (kill-all-local-variables)
        (use-local-map dired-mode-map)
        ;; "default-directory is already set" - `dired-internal-noselect'
        ;; set it before calling this, and `dired-advertise' reads it.
        (dired-advertise)
        (set!major-mode 'dired-mode)
        (set!mode-name "Dired")
        (text-editor-set-read-only! (current-buffer) #t)
        ;; "Dired sets `revert-buffer-function' to this function" - which
        ;; is what makes `g' and any `revert-buffer' call read the
        ;; directory again rather than the file's text.
        (set-buffer-local-value! (current-buffer) 'revert-buffer-function
                                 dired-revert)
        (set!dired-directory! (or dirname (default-directory)))
        (set!dired-actual-switches! (or switches (*dired-listing-switches*)))
        (set!dired-subdir-alist! '())
        ;; The C's last act is `(dired-sort-other dired-actual-switches t)':
        ;; the switches are already set, and `t' is NO-REVERT, so what
        ;; `dired-sort-other' would add - `dired-sort-R-check''s subdir
        ;; save and the mode line's "by date" - is what it does not.
        (dired-sort-other (dired-actual-switches) #t)
        (run-mode-hooks *dired-mode-hook*)))

    ))
