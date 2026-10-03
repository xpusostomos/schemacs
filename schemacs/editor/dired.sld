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
  ;;     `region-active-p'), `dired-hide-details-*', and the
  ;;     `dired--hidden-p' test, which needs the `invisible' property
  ;;     and an invisibility spec the display does not have yet.

  (import
    (scheme base)
    (scheme char)
    ;; `read' is Guile's, and wants a port where Emacs's takes a
    ;; string - see `dired-get-filename'
    (only (guile) caddr open-input-string read string-prefix? string-suffix?)
    ;; The file primitives this is built on, and their library.
    (only (schemacs editor diredc) file-attributes)
    (only (schemacs editor fileio)
          directory-file-name expand-file-name file-directory-p
          file-name-as-directory file-name-directory-part
          file-name-nondirectory-part)
    (only (schemacs editor files)
          directory-listing-before-filename-regexp find-file insert-directory
          revert-buffer)
    ;; `indent-rigidly' is indent.el's, and is what gives a dired buffer
    ;; its two-column indent
    (only (schemacs editor indent) indent-rigidly)
    ;; The buffer, and the buffer-locals Dired keeps on it.
    (only (schemacs editor buffer)
          buffer-local-keymap buffer-local-value buffer-name current-buffer
          erase-buffer get-buffer-create kill-buffer set!buffer-local-keymap
          set-buffer-local-value! set-buffer-modified-p buffer-modified-p)
    (only (schemacs editor editfns)
          buffer-substring buffer-substring-no-properties char-after char-before
          eobp forward-line goto-char insert line-beginning-position
          line-end-position point point-marker point-max
          point-min save-excursion)
    (only (schemacs editor search)
          looking-at looking-at-p match-beginning match-end match-string
          re-search-backward re-search-forward regexp-quote replace-match
          search-forward string-match)
    (only (schemacs editor textprop)
          add-text-properties get-char-property get-text-property
          next-single-property-change put-text-property
          remove-text-properties set-text-properties)
    (only (schemacs editor simple)
          beginning-of-line delete-char end-of-line special-mode
          special-mode-map)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor keymap) define-key *default-keymap*)
    (only (schemacs editor command) current-prefix-arg define-command)
    (only (schemacs editor engine)
          marker-position set-marker! text-editor-set-read-only!)
    (only (schemacs editor indentc) *indent-tabs-mode*)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor window)
          display-buffer quit-window switch-to-buffer)
    (only (schemacs editor subr) run-hooks)
    )

  (export
   *dired-actual-switches*
   *dired-after-readin-hook*
   *dired-before-readin-hook*
   *dired-del-marker*
   *dired-directory*
   *dired-listing-switches*
   *dired-marker-char*
   *dired-mode-hook*
   *dired-trivial-filenames*
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
      ;; GNU Emacs's `dired-move-to-end-of-filename': "Assumes point is at
      ;; beginning of filename. On failure, signals an error (with
      ;; non-nil NO-ERROR just returns nil)."
      ;;
      ;; With the property, the end is one lookup. Without it the C
      ;; re-derives the file type from the mode string, guesses symlinks
      ;; by searching for ` -> ', and subtracts characters to undo
      ;; `-F''s marker - which is the cost the property is there to
      ;; avoid.
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
                  (file-type #f) (executable #f) (symlink #f))
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
              (if symlink
                  (if (search-forward " -> " eol #t)
                      (begin
                        (forward-char -4)
                        (if (and used-f
                                 (char=? (char-before) #\@))
                            (forward-char -1)))
                      (goto-char eol))
                  ;; "ls -lF marks dirs, sockets, fifos and executables
                  ;; with exactly one trailing character."
                  (if (and used-f
                           (or (memv file-type (list #\d #\s #\p)) executable))
                      (forward-char -1)))
              (if (or no-error (not (eq? opoint (point))))
                  (if (eq? opoint (point)) #f (point))
                  (error "No file on this line"))))))

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
             (p1 (dired-move-to-filename (not no-error-if-not-filep)))
             (p2 (and p1 (dired-move-to-end-of-filename no-error-if-not-filep)))
             (file (and p1 p2 (buffer-substring p1 p2))))
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
        (cond
         ((not file) #f)
         ((eq? localp 'verbatim) file)
         ((and (not no-error-if-not-filep)
               (member file '("." "..")))
          (error "Cannot operate on `.' or `..'"))
         ((eq? localp 'no-dir) (file-name-nondirectory-part file))
         (else (expand-file-name file (dired-directory))))))

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
                    (put-text-property (line-beginning-position)
                                       (+ 1 (line-end-position))
                                       'invisible 'dired-hide-details-information))
                (let ((opoint (point)))
                  (save-excursion
                    (dired-move-to-end-of-filename)
                    (add-text-properties
                     opoint (point)
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
      (let ((inhibit-read-only #t))
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
      (let ((inhibit-read-only #t))
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

    (define-derived-mode (dired-mode special-mode "Dired" dired-mode-map
                                     *dired-mode-hook*)
      "Major mode for editing a directory listing."
      ;; The C sets `buffer-read-only' and a few things this tree has no
      ;; counterpart for - `mode-line-buffer-identification',
      ;; `font-lock-defaults', `desktop-save-buffer',
      ;; `buffer-stale-function', `buffer-auto-revert-by-notification',
      ;; `page-delimiter', `list-buffers-directory' and
      ;; `grep-read-files-function'.
      (text-editor-set-read-only! (current-buffer) #t)
      (set!dired-directory! (or (*dired-directory*) ""))
      (set!dired-actual-switches! (or (*dired-actual-switches*)
                                      (*dired-listing-switches*))))


    ))
