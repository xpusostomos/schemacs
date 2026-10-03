(define-library (schemacs editor ls-lisp)
  ;; This library mirrors GNU Emacs's `lisp/ls-lisp.el': the directory
  ;; listing written in Lisp rather than read out of an `ls' program.
  ;;
  ;; Emacs uses it on the platforms that have no `ls' (MS-DOS, Windows)
  ;; and, on Unix, only when `ls-lisp-use-insert-directory-program' says
  ;; so. *This* editor uses it everywhere, and that is a decision of
  ;; Chris's rather than an accident: `insert-directory' on Unix runs
  ;; `insert-directory-program' through `call-process' and parses its
  ;; `--dired' output, which needs a subprocess, a temp file for stderr,
  ;; the shell's quoting rules and the coding-system round trip - all of
  ;; it machinery this editor does not have, for a listing it can build
  ;; from `file-attributes', which it does have.
  ;;
  ;; The consequence to know about: the listing follows *ls-lisp's*
  ;; rules and not `ls''s - its own collation, its own
  ;; `ls-lisp-dirs-first', its own switch handling. Comparing our dired
  ;; against a Unix Emacs will show differences that are this choice
  ;; working as intended.
  ;;
  ;; What the port is built on: `file-attributes' and
  ;; `directory-files-and-attributes' and the `file-attribute-*'
  ;; accessors (`(schemacs editor diredc)'), the name arithmetic in
  ;; `(schemacs editor fileio)', and the regexp engine `string-match'
  ;; (`(schemacs editor search)').
  ;;
  ;; Where the C calls files.el and cannot:
  ;;
  ;;   `ls-lisp--insert-directory' needs files.el's `wildcard-to-regexp',
  ;;   and `ls-lisp-format' its `file-size-human-readable'; files.sld is
  ;;   this library's *importer* - a Scheme library
  ;;   import cannot be circular. Emacs has the same cycle and gets away
  ;;   with it because files.el only `(require 'ls-lisp)' from inside a
  ;;   function body. The same seam is made here explicitly:
  ;;   `install-ls-lisp-files!' is called by files.sld at load. The
  ;;   wildcard path is the only one that needs it, and it says the
  ;;   function is missing rather than silently matching nothing.
  ;;
  ;;   * the `-R' recursion: `ls-lisp-insert-directory' lists one
  ;;     directory here, where Emacs's walks into every subdirectory it
  ;;     finds and heads each with its name.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * the MS-Windows branches (`ls-lisp-UCA-like-collation', the
  ;;     `w32-collate-ignore-punctuation' binding): there is no Windows
  ;;     here.
  ;;   * the `invalid-regexp' retry at the end of
  ;;     `ls-lisp--insert-directory' - a file whose name holds a `['
  ;;     that a wildcard put there - which needs `wildcard-to-regexp''s
  ;;     error slot and `file-relative-name', the other half of the same
  ;;     files.el seam.
  ;;   * the `dired-filename' text property that `ls-lisp-classify-file'
  ;;     and `ls-lisp-format' put on the name. Dired's line reader here
  ;;     reads the name off the line, which it has to do in any case:
  ;;     there is no `--dired' output to put the property in.
  ;;   * the `-R' recursion, which dired does itself.

  (import
    (scheme base)
    (scheme char)
    ;; `sort' has no R7RS spelling, and `string-index' is Guile's.
    (only (guile) sort string-index)
    ;; the window's width, which `ls-lisp-column-format' lays out to
    (only (schemacs editor frame) selected-window window-body-width)
    (only (schemacs editor diredc)
          directory-files directory-files-and-attributes file-attributes
          file-attribute-group-id file-attribute-inode-number
          file-attribute-link-number file-attribute-modes
          file-attribute-size file-attribute-type
          file-attribute-user-id)
    (only (schemacs editor fileio)
          expand-file-name file-directory-p file-exists-p
          file-name-absolute-p file-name-as-directory
          file-name-directory-part file-name-nondirectory-part)
    (only (guile) getenv)
    (only (schemacs editor fns)
          compare-strings concat string-collate-lessp)
    ;; the time values `ls-lisp-format-time' asks how old a file is
    (only (schemacs editor timefns)
          format-time-string time-less-p time-subtract)
    (only (schemacs editor search)
          match-beginning match-end string-match)
    (only (schemacs editor editfns)
          forward-line goto-char insert point propertize save-excursion)
    )

  (export
   *ls-lisp-dirs-first*
   *ls-lisp-format-time-list*
   *ls-lisp-ignore-case*
   *ls-lisp-support-shell-wildcards*
   *ls-lisp-use-localized-time-format*
   *ls-lisp-use-string-collate*
   *ls-lisp-block-width*
   *ls-lisp-gid-width*
   *ls-lisp-size-width*
   *ls-lisp-uid-width*
   *ls-lisp-verbosity*
   *system-time-locale*
   install-ls-lisp-files!
   ls-lisp--insert-directory
   ls-lisp--sanitize-switches
   ls-lisp-classify
   ls-lisp-classify-file
   ls-lisp-column-format
   ls-lisp-delete-matching
   ls-lisp-extension
   ls-lisp-format
   ls-lisp-format-file-size
   ls-lisp-format-time
   ls-lisp-handle-switches
   ls-lisp-insert-directory
   ls-lisp-sanitize
   ls-lisp-string-lessp
   ls-lisp-time-index
   ls-lisp-version-lessp
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The options
    ;;------------------------------------------------------------------

    (define *ls-lisp-verbosity*
      (make-parameter '(modes links uid gid)))
    ;; ^ GNU Emacs's `ls-lisp-verbosity', which says which parts the
    ;; long listing shows at all. Emacs computes its default from
    ;; `ls-lisp-emulation', dropping `gid' under MS-Windows; the four
    ;; are what a Unix Emacs ends up with. Where Emacs's default omits
    ;; `modes' and prints four characters, ours names it.

    (define *ls-lisp-ignore-case* (make-parameter #f))
    ;; ^ "Non-nil means treat file names in a case-insensitive way."

    (define *ls-lisp-use-localized-time-format* (make-parameter #f))
    ;; ^ GNU Emacs's `ls-lisp-use-localized-time-format': "Non-nil means
    ;; to always format file times with a localized format, even when
    ;; the locale is the C or POSIX locale."

    (define *ls-lisp-use-string-collate* (make-parameter #t))
    ;; ^ GNU Emacs's `ls-lisp-use-string-collate': "Non-nil causes
    ;; ls-lisp to sort files in locale-dependent collation order. A
    ;; value of nil means use ordinary string comparison (see
    ;; `compare-strings') for sorting files. A non-nil value uses
    ;; `string-collate-lessp' instead, which more closely emulates what
    ;; GNU ls does."
    ;;
    ;; Emacs computes the default from `ls-lisp-emulation' - nil for the
    ;; MacOS and UNIX emulations, non-nil otherwise, which is the branch
    ;; GNU/Linux takes. There is no `ls-lisp-emulation' here, so it is
    ;; that branch's answer.

    (define *ls-lisp-dirs-first* (make-parameter #f))
    ;; ^ "Non-nil means group directories first, then files, like GNU ls
    ;; invoked with `--group-directories-first'."

    (define *ls-lisp-support-shell-wildcards* (make-parameter #t))
    ;; ^ "Non-nil means treat file name wildcards as shell wildcards;
    ;; nil means treat them as regexps."

    (define *ls-lisp-format-time-list*
      (make-parameter '("%b %e %H:%M" "%b %e  %Y")))
    ;; ^ "List of format strings used for display of file times. The
    ;; first element is used for recent files, the second for older
    ;; ones." Emacs's own defaults for a C locale.

    ;; The four widths the long listing computes for itself. In Emacs
    ;; they are `defvar's holding a format string built from the widest
    ;; value in the listing - `ls-lisp-uid-d-fmt' and its three
    ;; siblings; here they hold the width itself, which is what the
    ;; string was for.
    (define *ls-lisp-uid-width* (make-parameter 1))
    (define *ls-lisp-gid-width* (make-parameter 1))
    (define *ls-lisp-size-width* (make-parameter 1))
    (define *ls-lisp-block-width* (make-parameter 1))

    ;;----------------------------------------------------------------
    ;; The files.el seam
    ;;------------------------------------------------------------------

    (define %wildcard-to-regexp
      (lambda (wildcard)
        (error "ls-lisp: files.el's `wildcard-to-regexp' is not installed")))

    (define %file-size-human-readable
      (lambda (file-size . rest)
        (error "ls-lisp: files.el's `file-size-human-readable' is not installed")))

    (define (install-ls-lisp-files! wildcard-to-regexp file-size-human-readable)
      ;; Called by files.sld at load, for the reason the library comment
      ;; gives: both are files.el's, and files.sld is this library's
      ;; importer.
      ;;--------------------------------------------------------------
      (set! %wildcard-to-regexp wildcard-to-regexp)
      (set! %file-size-human-readable file-size-human-readable))

    ;;----------------------------------------------------------------
    ;; Two helpers where Emacs uses a format directive
    ;;------------------------------------------------------------------

    (define (pad-left string width)
      ;; Emacs's `%Nd' - the value right-aligned in a field WIDTH wide.
      ;; Written out because Guile's `format' has no decimal directive,
      ;; and its `~ND' is not one.
      ;;--------------------------------------------------------------
      (let ((n (string-length string)))
        (if (>= n width)
            string
            (string-append (make-string (- width n) #\space) string))))

    (define (pad-right string width)
      ;; Emacs's `%-Ns' - the value left-aligned in a field WIDTH wide,
      ;; which is what the uid and gid formats are built with and what
      ;; `ls-lisp-column-format' prints the names with.
      ;;--------------------------------------------------------------
      (let ((n (string-length string)))
        (if (>= n width)
            string
            (string-append string (make-string (- width n) #\space)))))
    (define (string-trim-right string)
      (let loop ((end (string-length string)))
        (if (and (> end 0) (char-whitespace? (string-ref string (- end 1))))
            (loop (- end 1))
            (substring string 0 end))))

    (define (string-trim-left string)
      (let loop ((start 0))
        (if (and (< start (string-length string))
                 (char-whitespace? (string-ref string start)))
            (loop (+ start 1))
            (substring string start (string-length string)))))

    (define (string-trim string)
      ;; GNU Emacs's `string-trim', which `ls-lisp--sanitize-switches'
      ;; ends with.
      ;;--------------------------------------------------------------
      (string-trim-left (string-trim-right string)))

    ;;----------------------------------------------------------------
    ;; Sanitizing
    ;;------------------------------------------------------------------

    (define (ls-lisp-sanitize file-alist)
      ;; GNU Emacs's `ls-lisp-sanitize' (ls-lisp.el:488): "Fixes any
      ;; elements whose file attributes are nil, meaning `file-attributes'
      ;; failed for them - this is known to happen for some network
      ;; shares, in particular for the \"..\" directory entry. If the
      ;; \"..\" entry has nil attributes, the attributes are copied from
      ;; the \".\" entry, if they are non-nil. Otherwise, the offending
      ;; element is removed, as are any other elements with nil
      ;; attributes."
      ;;
      ;; The C's `(rassq-delete-all nil file-alist)' removes *every*
      ;; element whose cdr is nil, the dot entry included.
      ;;--------------------------------------------------------------
      (let ((dot (assoc "." file-alist))
            (dotdot (assoc ".." file-alist)))
        (if (and dotdot (not (cdr dotdot)) (cdr dot))
            (set-cdr! dotdot (cdr dot))))
      (let loop ((rest file-alist) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((cdr (car rest)) (loop (cdr rest) (cons (car rest) acc)))
              (else (loop (cdr rest) acc)))))

    (define (ls-lisp-delete-matching regexp entries)
      ;; GNU Emacs's `ls-lisp-delete-matching': "Delete all elements
      ;; matching REGEXP from LIST, return new list." The C conses the
      ;; survivors, so the answer comes out in the reverse order - a
      ;; fact its own comment shrugs at ("Should perhaps use setcdr for
      ;; efficiency").
      ;;--------------------------------------------------------------
      (let loop ((rest entries) (acc '()))
        (cond ((null? rest) acc)
              ((string-match regexp (car (car rest))) (loop (cdr rest) acc))
              (else (loop (cdr rest) (cons (car rest) acc))))))

    ;;----------------------------------------------------------------
    ;; Sorting
    ;;------------------------------------------------------------------

    (define (ls-lisp-string-lessp s1 s2)
      ;; GNU Emacs's `ls-lisp-string-lessp': "Return t if string S1
      ;; should sort before string S2. Case is significant if
      ;; `ls-lisp-ignore-case' is nil. Uses `string-collate-lessp' if
      ;; `ls-lisp-use-string-collate' is non-nil, `compare-strings'
      ;; otherwise.
      ;;
      ;; On GNU/Linux systems, if the locale specifies UTF-8 as the
      ;; codeset, the sorting order will place together file names that
      ;; differ only by punctuation characters, like `.emacs' and
      ;; `emacs'."
      ;;
      ;; The C binds `w32-collate-ignore-punctuation' around the
      ;; comparison, which only means anything under MS-Windows.
      ;;--------------------------------------------------------------
      (if (*ls-lisp-use-string-collate*)
          (string-collate-lessp s1 s2 #f (*ls-lisp-ignore-case*))
          (let ((u (compare-strings s1 0 #f s2 0 #f (*ls-lisp-ignore-case*))))
            (and (integer? u) (< u 0)))))

    (define (ls-lisp-version-lessp s1 s2)
      ;; GNU Emacs's `ls-lisp-version-lessp': "This is the same as
      ;; `string-lessp' (with the exception of case insensitivity), but
      ;; sequences of digits are compared numerically, as a whole, in
      ;; the same manner as the `strverscmp' function available in some
      ;; standard C libraries does."
      ;;
      ;; The C's walk, kept in its shape: run the two strings together
      ;; until a digit sequence in each decides; compare the
      ;; non-numerical parts as strings and the numerical ones as
      ;; numbers, with a leading-zero run - a "fraction" - compared by
      ;; length first.
      ;;--------------------------------------------------------------
      (let ((i1 0) (i2 0)
            (len1 (string-length s1)) (len2 (string-length s2))
            (val 0)
            (ni1 #f) (ni2 #f) (e1 #f) (e2 #f)
            (found-2-numbers #f))
        (let loop ()
          (when (and (< i1 len1) (< i2 len2) (= val 0))
            (unless found-2-numbers
              (set! ni1 (string-match "[0-9]+" s1 i1))
              (set! e1 (and ni1 (match-end 0)))
              (set! ni2 (string-match "[0-9]+" s2 i2))
              (set! e2 (and ni2 (match-end 0))))
            (cond
             ((and ni1 ni2)
              (cond
               ((and (> ni1 i1) (> ni2 i2))
                ;; "Compare non-numerical part as strings."
                (let ((u (compare-strings s1 i1 ni1 s2 i2 ni2
                                                  (*ls-lisp-ignore-case*))))
                  (set! val (if (eq? u #t) 0 u)))
                (set! i1 ni1) (set! i2 ni2) (set! found-2-numbers #t))
               ((and (= ni1 i1) (= ni2 i2))
                (set! found-2-numbers #f)
                ;; "Compare numerical parts as integral and/or
                ;; fractional parts."
                (let* ((sub1 (substring s1 ni1 e1))
                       (sub2 (substring s2 ni2 e2))
                       ;; a "fraction" is a run with leading zeros
                       (fr1 (string-match "\\`0+" sub1))
                       (efr1 (and fr1 (match-end 0)))
                       (fr2 (string-match "\\`0+" sub2))
                       (efr2 (and fr2 (match-end 0))))
                  (cond
                   ;; "Two fractions: the longer one is less than the
                   ;; other, but only if the common prefix is all
                   ;; zeroes, otherwise fall back on numerical
                   ;; comparison."
                   ((and fr1 fr2)
                    (if (or (and (< efr1 (- e1 ni1)) (< efr2 (- e2 ni2))
                                 (not (char=? (string-ref sub1 efr1)
                                              (string-ref sub2 efr2))))
                            (= efr1 (- e1 ni1))
                            (= efr2 (- e2 ni2)))
                        (set! val (- val (- (string-length sub1)
                                            (string-length sub2))))))
                   (fr1                       ; a fraction is less
                    (set! val (- 0 ni1 1)))   ; make sure val is non-zero
                   (fr2
                    (set! val (+ 1 ni2))))    ; likewise
                  (if (= val 0)               ; fall back on the numbers
                      (set! val (- (string->number sub1)
                                   (string->number sub2))))
                  (set! i1 e1) (set! i2 e2)))
               (else
                (let ((u (compare-strings s1 i1 #f s2 i2 #f
                                                  (*ls-lisp-ignore-case*))))
                  (set! val (if (eq? u #t) 0 u)))
                (set! i1 len1) (set! i2 len2))))
             (else
              (let ((u (compare-strings s1 i1 #f s2 i2 #f
                                                (*ls-lisp-ignore-case*))))
                (set! val (if (eq? u #t) 0 u)))
              (set! i1 len1) (set! i2 len2)))
            (loop)))
        (if (= val 0) (set! val (- len1 len2)))
        (< val 0)))

    (define (ls-lisp-time-index switches)
      ;; GNU Emacs's `ls-lisp-time-index': "Return time index into
      ;; file-attributes according to ls SWITCHES list. Return nil if no
      ;; time switch found." The C's comment: "Default of nil is
      ;; IMPORTANT and used in `ls-lisp-handle-switches'!"
      ;;--------------------------------------------------------------
      (cond ((memq #\c switches) 6)     ; last mode change
            ((memq #\t switches) 5)     ; last modtime
            ((memq #\u switches) 4)     ; last access
            (else #f)))
    (define (ls-lisp-handle-switches file-alist switches)
      ;; GNU Emacs's `ls-lisp-handle-switches': "Return new FILE-ALIST
      ;; sorted according to SWITCHES. SWITCHES is a list of characters.
      ;; Default sorting is alphabetic."
      ;;
      ;; The C sorts a copy, because `sort' may modify its argument and
      ;; the caller's list is wanted again on an error, and it wraps the
      ;; sort in a `condition-case' that reports "Unsorted (ls-lisp
      ;; sorting error)" rather than hitting the user with it. Guile's
      ;; `sort' is non-destructive and the comparisons below do not
      ;; raise, so neither is needed.
      ;;
      ;; The C's steps are statements, and they are statements here too,
      ;; rather than one nested `let' - which is what the classify step
      ;; going missing in an earlier draft of this file looked like.
      ;;--------------------------------------------------------------
      ;; The C folds the time index into the `cond' as `(setq index ...)',
      ;; whose nil is false; Guile's `set!' answers an unspecified value,
      ;; which is true - so the index is taken once, before the sort.
      (let ((index (ls-lisp-time-index switches)))
        (if (memq #\U switches)                 ; unsorted
            #t
            (set! file-alist
                  (sort file-alist
                        (cond
                         ((memq #\S switches)   ; sorted on size
                          ;; "Make largest file come first"
                          (lambda (x y)
                            (< (file-attribute-size (cdr y))
                               (file-attribute-size (cdr x)))))
                         (index                 ; sorted on time
                          (lambda (x y)
                            (time-less-p (list-ref (cdr y) index)
                                         (list-ref (cdr x) index))))
                         ((memq #\X switches)   ; sorted on extension
                          (lambda (x y)
                            (ls-lisp-string-lessp
                             (ls-lisp-extension (car x))
                             (ls-lisp-extension (car y)))))
                         ((memq #\v switches)   ; sorted by version number
                          (lambda (x y)
                            (ls-lisp-version-lessp (car x) (car y))))
                         (else                  ; sorted alphabetically
                          (lambda (x y)
                            (ls-lisp-string-lessp (car x) (car y))))))))
        (if (memq #\F switches)                 ; classify switch
            (set! file-alist (map ls-lisp-classify file-alist)))
        (if (*ls-lisp-dirs-first*)
            ;; "Re-sort directories first, without otherwise changing
            ;; the ordering, and reverse whole list. `cadr' of each
            ;; element of `file-alist' is t for directory, string (name
            ;; linked to) for symbolic link, or nil."
            (let loop ((rest file-alist) (dirs '()) (files '()))
              (cond
               ((null? rest)
                (set! file-alist
                      (if (memq #\U switches)   ; unsorted order is reversed
                          (append dirs files)   ; the C's `(nconc dirs files)'
                          (append files dirs))))
               ((let ((el (car rest)))
                  (or (eq? (cadr el) #t)        ; directory
                      (and (string? (cadr el))  ; symlink to a directory
                           (file-directory-p (cadr el)))))
                (loop (cdr rest) (cons (car rest) dirs) files))
               (else
                (loop (cdr rest) dirs (cons (car rest) files))))))
        ;; "Finally reverse file alist if necessary. (eq below MUST
        ;; compare `(not (memq ...))' to force comparison of t or nil,
        ;; rather than list tails!)"
        (if (eq? (eq? (not (memq #\U switches))   ; unsorted order is reversed
                      (not (memq #\r switches)))   ; reversed sort requested
                 (*ls-lisp-dirs-first*))           ; already reversed
            (reverse file-alist)
            file-alist)))

    ;;----------------------------------------------------------------
    ;; Classifying a name - the `-F' switch
    ;;------------------------------------------------------------------

    (define (ls-lisp-classify-file filename fattr)
      ;; GNU Emacs's `ls-lisp-classify-file': "Append a character to
      ;; FILENAME indicating the file type. ... The file type indicators
      ;; are `/' for directories, `@' for symbolic links, `|' for FIFOs,
      ;; `=' for sockets, `*' for regular files that are executable, and
      ;; nothing for other types of files."
      ;;
      ;; "This function puts the `dired-filename' property on FILENAME,
      ;; but not on the character indicator it appends." That is what
      ;; makes it `concat' and not `string-append', and what makes the
      ;; property cover the name and stop before the `/': the name is
      ;; propertized first, and the indicator is a second piece of the
      ;; concatenation with nothing on it. See the library comment.
      ;;--------------------------------------------------------------
      (let ((type (file-attribute-type fattr))
            (modestr (file-attribute-modes fattr))
            (file-name (propertize filename 'dired-filename #t)))
        (cond
         (type (concat file-name (if (eq? type #t) "/" "@")))
         ((string-index modestr #\x) (concat file-name "*"))
         ((char=? #\p (string-ref modestr 0)) (concat file-name "|"))
         ((char=? #\s (string-ref modestr 0)) (concat file-name "="))
         (else file-name))))

    (define (ls-lisp-classify filedata)
      ;; GNU Emacs's `ls-lisp-classify': "FILEDATA has the form
      ;; (FILENAME . ATTRIBUTES)."
      ;;--------------------------------------------------------------
      (cons (ls-lisp-classify-file (car filedata) (cdr filedata))
            (cdr filedata)))

    (define (ls-lisp-extension filename)
      ;; GNU Emacs's `ls-lisp-extension': "Return extension of FILENAME
      ;; (ignoring any version extension) FOLLOWED by null and full
      ;; filename, SOLELY for full alpha sort." The C's comment: "Force
      ;; extension sort order: `no ext' then `null ext' then `ext' to
      ;; agree with GNU ls."
      ;;--------------------------------------------------------------
      (let* ((len (string-length filename))
             (last-dot? (char=? #\. (string-ref filename (- len 1)))))
        (string-append
         (if last-dot?
             "\0"                       ; null extension
             (let loop ((i (- len 1)))
               (cond
                ((< i 0) "\0\0")        ; no extension
                ((char=? #\. (string-ref filename i))
                 (if (not (char=? #\~ (string-ref filename (+ i 1))))
                     (substring filename (+ i 1) len)
                     ;; a version extension found - ignore it
                     (let ((end i))
                       (let loop2 ((i (- i 1)))
                         (cond ((< i 0) "\0\0")   ; no extension
                               ((char=? #\. (string-ref filename i))
                                (substring filename (+ i 1) end))
                               (else (loop2 (- i 1))))))))
                (else (loop (- i 1))))))
         "\0" filename)))

    ;;----------------------------------------------------------------
    ;; Formatting one line
    ;;------------------------------------------------------------------
    (define (ls-lisp-format-time file-attr time-index)
      ;; GNU Emacs's `ls-lisp-format-time': "Format time for file with
      ;; attributes FILE-ATTR according to TIME-INDEX. Use the same
      ;; method as ls to decide whether to show time-of-day or year,
      ;; depending on distance between file date and the current time.
      ;; All ls time options, namely c, t and u, are handled."
      ;;
      ;; The cutoff: "Consider a time to be recent if it is within the
      ;; past six months. A Gregorian year has 365.2425 * 24 * 60 * 60
      ;; == 31556952 seconds on the average, and half of that is
      ;; 15778476. Write the constant explicitly to avoid roundoff
      ;; error."
      ;;
      ;; "This function determines as side effect the locale relevant
      ;; for displaying times, by using `system-time-locale' if non-nil,
      ;; and falling back to environment variables LC_ALL, LC_TIME, and
      ;; LANG."
      ;;
      ;; "Use traditional time format in the C or POSIX locale,
      ;; ISO-style time format otherwise, so columns line up."
      ;;--------------------------------------------------------------
      (let* ((time (list-ref file-attr (or time-index 5))) ; default: modtime
             (diff (time-subtract time #f))
             (past-cutoff -15778476)                       ; half a Gregorian year
             (locale (ls-lisp--time-locale))
             ;; a C or POSIX locale is no locale at all
             (locale (if (member locale '("C" "POSIX")) #f locale))
             (iso (and locale (not (*ls-lisp-use-localized-time-format*)))))
        (guard (e (#t "Unk  0  0000"))         ; the C's `condition-case'
          (format-time-string
           (if (and (not (time-less-p diff past-cutoff))
                    (not (time-less-p 0 diff)))    ; "is within the past six months"
               (if iso "%m-%d %H:%M"
                   (list-ref (*ls-lisp-format-time-list*) 0))
               (if iso "%Y-%m-%d "
                   (list-ref (*ls-lisp-format-time-list*) 1)))
           time))))

    (define %ls-lisp--time-locale #f)
    ;; ^ The C's `ls-lisp--time-locale': the locale the first call
    ;; found, kept "for next calls" so the environment is read once.

    (define *system-time-locale* (make-parameter #f))
    ;; ^ GNU Emacs's `system-time-locale', which `ls-lisp-format-time'
    ;; consults before the environment.

    (define (ls-lisp--time-locale)
      ;; The C's locale search: `system-time-locale' first, then the
      ;; cache, then LC_ALL, LC_TIME and LANG in that order - with "C"
      ;; kept when none of them is set.
      ;;--------------------------------------------------------------
      (or (*system-time-locale*)
          %ls-lisp--time-locale
          (let loop ((vars '("LC_ALL" "LC_TIME" "LANG")))
            (cond ((null? vars)
                   (set! %ls-lisp--time-locale "C")
                   "C")
                  ((getenv (car vars))
                   (set! %ls-lisp--time-locale (getenv (car vars)))
                   (getenv (car vars)))
                  (else (loop (cdr vars)))))))

    (define (digits n)
      ;; The C's `(length (format "%.0f" n))' - the field width the size
      ;; formats are built with.
      ;;--------------------------------------------------------------
      (string-length (number->string n)))

    (define (ls-lisp-format-file-size file-size human-readable)
      ;; GNU Emacs's `ls-lisp-format-file-size': the `%d' or the `%7s'
      ;; according to HUMAN-READABLE.
      ;;--------------------------------------------------------------
      (if (not human-readable)
          (string-append " " (pad-left (number->string file-size)
                                       (*ls-lisp-size-width*)))
          (string-append " "
                         (pad-left (%file-size-human-readable file-size) 7))))

    (define (ls-lisp-format file-name file-attr file-size switches time-index)
      ;; GNU Emacs's `ls-lisp-format' (ls-lisp.el:758): "Format one line
      ;; of long ls output for file FILE-NAME. FILE-ATTR and FILE-SIZE
      ;; give the file's attributes and size."
      ;;
      ;; The C's `(format " %18d " inode)' and `(format "%3d" links)'
      ;; are `pad-left' calls here, for the reason the helper gives.
      ;;--------------------------------------------------------------
      (let ((file-type (file-attribute-type file-attr))  ; t, a string, or nil
            (drwxrwxrwx (file-attribute-modes file-attr))
            (verbosity (*ls-lisp-verbosity*)))
        (concat
         (if (memq #\i switches)          ; inode number
             (string-append
              " "
              (pad-left (number->string
                         (file-attribute-inode-number file-attr))
                        18)
              " ")
             "")
         (if (memq #\s switches)          ; size in K, rounded up
             ;; "In GNU ls, -h affects the size in blocks, displayed
             ;; by -s, as well."
             (if (memq #\h switches)
                 (string-append
                  (pad-left (%file-size-human-readable
                             (* 1024 (ceiling (/ file-size 1024))))
                            7)
                  " ")
                 (string-append
                  (pad-left (number->string (ceiling (/ file-size 1024)))
                            (*ls-lisp-block-width*))
                  " "))
             "")
         (if (memq 'modes verbosity)
             drwxrwxrwx                   ; the modes string
             (substring drwxrwxrwx 0 4))  ; "d" or "-" for directory vs file
         (if (memq 'links verbosity)
             (pad-left (number->string
                        (file-attribute-link-number file-attr))
                       3)
             "")
         ;; "Numeric uid/gid are more confusing than helpful; Emacs
         ;; should be able to make strings of them. They tend to be
         ;; bogus on non-UNIX platforms anyway so optionally hide them."
         (if (memq 'uid verbosity)
             ;; "uid can be a string or an integer"
             (let ((uid (file-attribute-user-id file-attr)))
               (if (string? uid)
                   (string-append " " (pad-right uid (*ls-lisp-uid-width*)))
                   (string-append " " (pad-left (number->string uid)
                                                (*ls-lisp-uid-width*)))))
             "")
         (if (not (memq #\G switches))    ; GNU ls: shows group by default
             (if (or (memq #\g switches)  ; UNIX ls: no group by default
                     (memq 'gid verbosity))
                 (let ((gid (file-attribute-group-id file-attr)))
                   (if (string? gid)
                       (string-append " " (pad-right gid (*ls-lisp-gid-width*)))
                       (string-append " " (pad-left (number->string gid)
                                                    (*ls-lisp-gid-width*)))))
                 "")
             "")
         (ls-lisp-format-file-size file-size (memq #\h switches))
         " "
         (ls-lisp-format-time file-attr time-index)
         " "
         ;; "ls-lisp-classify-file already did that" - with `-F' the name
         ;; arrived propertized; otherwise it is propertized here. Either
         ;; way the property is on the name and not on what follows it.
         (if (not (memq #\F switches))
             (propertize file-name 'dired-filename #t)
             file-name)
         (if (string? file-type)          ; is a symbolic link
             (concat " -> " file-type)
             "")
         "\n")))

    ;;----------------------------------------------------------------
    ;; The column layout - the `-C' switch
    ;;------------------------------------------------------------------

    (define (ls-lisp-column-format file-alist)
      ;; GNU Emacs's `ls-lisp-column-format': "Insert the file names
      ;; (only) in FILE-ALIST into the current buffer. Format in
      ;; columns, sorted vertically, following GNU ls -C. Responds to
      ;; the window width as ls should but may not!"
      ;;
      ;; The C inserts each field and then deletes the whitespace back
      ;; from the row's end. The row is built as a string here and
      ;; right-trimmed in one step, which is the same text with the same
      ;; trailing space gone.
      ;;--------------------------------------------------------------
      (let ((files '()) (nfiles 0) (colwid 0))
        (for-each (lambda (entry)
                    (let ((file (car entry)))
                      (set! nfiles (+ nfiles 1))
                      (set! files (cons file files))
                      (if (> (string-length file) colwid)
                          (set! colwid (string-length file)))))
                  file-alist)
        (let* ((files (reverse files))
               (colwid (+ 2 colwid))            ; 2 character column gap
               (ncols (max 1 (quotient (window-body-width (selected-window))
                                       colwid)))
               (collen (quotient nfiles ncols))) ; floor of column length
          (if (> nfiles (* collen ncols)) (set! collen (+ collen 1)))
          ;; "Output the file names in columns, sorted vertically"
          (let loop ((i 0))
            (when (< i collen)
              (let loop2 ((j i) (row ""))
                (if (< j nfiles)
                    (loop2 (+ j collen) (string-append row
                                                       (pad-right (list-ref files j)
                                                                  colwid)))
                    (begin
                      (insert (string-trim-right row))
                      ;; "FJW: This is completely unnecessary, but I
                      ;; don't like trailing white space..."
                      (insert "\n"))))
              (loop (+ i 1)))))))

    ;;----------------------------------------------------------------
    ;; The switches
    ;;------------------------------------------------------------------

    (define (ls-lisp--sanitize-switches switches)
      ;; GNU Emacs's `ls-lisp--sanitize-switches': "Convert long options
      ;; of GNU `ls' to their short form. Conversion is done only for
      ;; flags supported by ls-lisp. Long options not supported by
      ;; ls-lisp are removed. Supported options are: A a B C c F G g h i
      ;; n R r S s t U u v X. The l switch is assumed to be always
      ;; present and cannot be turned off."
      ;;
      ;; The C's table is short-form to long-form *regexp*, and
      ;; `replace-match' replaces the first match of each - which is
      ;; what the splice below does.
      ;;--------------------------------------------------------------
      (let ((flags
             '(("-a" . "--all")
               ("-A" . "--almost-all")
               ("-B" . "--ignore-backups")
               ("-c" . "--time=ctime")
               ("-C" . "--color")
               ("-F" . "--classify")
               ("-G" . "--no-group")
               ("-h" . "--human-readable")
               ("-H" . "--dereference-command-line")
               ("-i" . "--inode")
               ("-n" . "--numeric-uid-gid")
               ("-r" . "--reverse")
               ("-R" . "--recursive")
               ("-s" . "--size")
               ("-t" . "--sort=time")
               ("-S" . "--sort.*[ \\\t]")
               ("-u" . "--time=atime")
               (""   . "--group-directories-first")
               (""   . "--.*=.*[ \t\n]?")     ; catch all with a `=' in it
               (""   . "--version"))))
        (let loop ((rest flags))
          (if (null? rest)
              (string-trim switches)
              (let ((at (string-match (cdr (car rest)) switches)))
                (if at
                    (set! switches
                          (string-append
                           (substring switches 0 at)
                           (car (car rest))
                           (substring switches (match-end 0)
                                      (string-length switches)))))
                (loop (cdr rest)))))))

    (define (ls-lisp--insert-directory file switches wildcard full-directory-p)
      ;; GNU Emacs's `ls-lisp--insert-directory' (ls-lisp.el:260): "This
      ;; implementation of `insert-directory' works using Lisp functions
      ;; rather than `insert-directory-program'. It does not support all
      ;; `ls' switches - those that work are: A a B C c F G g h i n R r
      ;; S s t U u v X. The l switch is assumed to be always present and
      ;; cannot be turned off. Long variants of the above switches, as
      ;; documented for GNU `ls', are also supported; unsupported long
      ;; options are silently ignored."
      ;;
      ;; SWITCHES arrives as the string the caller was given and leaves
      ;; as the list of its characters - the C's
      ;; `(delete ?\s (delete ?- (append switches nil)))'.
      ;;--------------------------------------------------------------
      (let ((wildcard-regexp #f))
        (let ((switches (or switches "")))
          (let ((dirs-first (if (or (*ls-lisp-dirs-first*)
                                    (string-match "--group-directories-first"
                                                  switches))
                                #t #f)))
            (when (string-match "--group-directories-first" switches)
              ;; "if ls-lisp-dirs-first is nil, dirs are grouped but come
              ;; out in reverse order"
              (set! switches (string-append
                              (substring switches 0 (match-beginning 0))
                              (substring switches (match-end 0)
                                         (string-length switches)))))
            ;; "Remove unrecognized long options, and convert the
            ;; recognized ones to their short variants."
            (set! switches (ls-lisp--sanitize-switches switches))
            ;; "Convert SWITCHES to a list of characters."
            (set! switches (let loop ((i 0) (acc '()))
                             (if (>= i (string-length switches))
                                 (reverse acc)
                                 (let ((c (string-ref switches i)))
                                   (loop (+ i 1)
                                         (if (or (char=? c #\space)
                                                 (char=? c #\-))
                                             acc
                                             (cons c acc)))))))
            ;; "Sometimes we get `.../foo*/' as FILE. While the shell
            ;; and `ls' don't mind, we certainly do, because it makes us
            ;; think there is no wildcard, only a directory name."
            (when (and (*ls-lisp-support-shell-wildcards*)
                       (string-match "[?*[]" file)
                       ;; "Prefer an existing file to wildcards, like
                       ;; `dired-noselect' does."
                       (not (file-exists-p file)))
              (when (char=? #\/ (string-ref file (- (string-length file) 1)))
                (set! file (substring file 0 (- (string-length file) 1))))
              (set! wildcard #t))
            (if wildcard
                (begin
                  (set! wildcard-regexp
                        (if (*ls-lisp-support-shell-wildcards*)
                            (%wildcard-to-regexp
                             (file-name-nondirectory-part file))
                            (file-name-nondirectory-part file)))
                  (set! file (file-name-directory-part file)))
                (if (memq #\B switches)
                    (set! wildcard-regexp "[^~]\\'")))
            (parameterize ((*ls-lisp-dirs-first* dirs-first))
              (ls-lisp-insert-directory
               file switches (ls-lisp-time-index switches)
               wildcard-regexp full-directory-p))))))

    (define (ls-lisp-insert-directory file switches time-index
                                      wildcard-regexp full-directory-p)
      ;; GNU Emacs's `ls-lisp-insert-directory' (ls-lisp.el:324):
      ;; "Insert directory listing for FILE, formatted according to
      ;; SWITCHES. Leaves point after the inserted text. SWITCHES is a
      ;; *list* of characters. TIME-INDEX is the time index into
      ;; file-attributes according to SWITCHES. WILDCARD-REGEXP is nil
      ;; or an *Emacs regexp*. FULL-DIRECTORY-P means file is a
      ;; directory and SWITCHES does not contain `d', so that a full
      ;; listing is expected."
      ;;--------------------------------------------------------------
      (if (or (and wildcard-regexp
                   (not (string=? "[^~]\\'" wildcard-regexp))) ; the -B pseudo-wildcard
              full-directory-p)
          (let* ((dir (file-name-as-directory (expand-file-name file)))
                 (id-format (if (memq #\n switches) 'integer 'string))
                 ;; the C reads with `t' for NOSORT: the sort is
                 ;; `ls-lisp-handle-switches'' business, not the reader's
                 (file-alist (directory-files-and-attributes
                              dir #f wildcard-regexp #t id-format))
                 (sum 0)
                 (max-uid-len 0)
                 (max-gid-len 0)
                 (max-file-size 0)
                 (total-line #f))
            (set! file-alist (ls-lisp-sanitize file-alist))
            (cond ((memq #\A switches)
                   (set! file-alist
                         (ls-lisp-delete-matching "^\\.\\.?$" file-alist)))
                  ((not (memq #\a switches))
                   ;; "if neither -A nor -a, flush . files"
                   (set! file-alist
                         (ls-lisp-delete-matching "^\\." file-alist))))
            (set! file-alist (ls-lisp-handle-switches file-alist switches))
            (if (memq #\C switches)             ; column (-C) format
                (ls-lisp-column-format file-alist)
                (begin
                  (set! total-line (cons (point)
                                         (if (pair? file-alist)
                                             (car file-alist)
                                             #f)))
                  ;; "Find the appropriate format for displaying uid,
                  ;; gid, and file size, by finding the longest strings
                  ;; among all the files we are about to display."
                  (for-each
                   (lambda (elt)
                     (let* ((attr (cdr elt))
                            (fuid (file-attribute-user-id attr))
                            (uid-len (if (string? fuid)
                                         (string-length fuid)
                                         (string-length (number->string fuid))))
                            (fgid (file-attribute-group-id attr))
                            (gid-len (if (string? fgid)
                                         (string-length fgid)
                                         (string-length (number->string fgid))))
                            (size (file-attribute-size attr)))
                       (if (> uid-len max-uid-len) (set! max-uid-len uid-len))
                       (if (> gid-len max-gid-len) (set! max-gid-len gid-len))
                       (if (> size max-file-size) (set! max-file-size size))))
                   file-alist)
                  (parameterize
                      ((*ls-lisp-uid-width* max-uid-len)
                       (*ls-lisp-gid-width* max-gid-len)
                       (*ls-lisp-size-width* (digits max-file-size))
                       (*ls-lisp-block-width*
                        (digits (ceiling (/ max-file-size 1024)))))
                    ;; the long (-l) format
                    (for-each
                     (lambda (elt)
                       (let ((short (car elt))
                             (attr (cdr elt)))
                         (when attr
                           (set! sum (+ (file-attribute-size attr) sum))
                           (insert (ls-lisp-format short attr
                                                   (file-attribute-size attr)
                                                   switches time-index)))))
                     file-alist))
                  ;; "Insert total size of all files"
                  (save-excursion
                    (goto-char (car total-line))
                    (if (not (cdr total-line))
                        ;; "Shell says ``No match'' if no files match the
                        ;; wildcard; let's say something similar."
                        (insert "(No match)\n"))
                    (insert (string-append
                             "total "
                             (number->string (ceiling (/ sum 1024)))
                             "\n")))))
            ;; "dired-insert-directory expects to find point after the
            ;; text. But if the listing is empty, as e.g. in empty
            ;; directories with -a removed from switches, point will be
            ;; before the inserted text, and dired-insert-directory will
            ;; not indent the listing correctly. Getting past the
            ;; inserted text solves this."
            (if (not (and total-line (cdr total-line))) (forward-line 2))
            #t)
          ;; "If not full-directory-p, FILE *must not* end in /, as
          ;; file-attributes will not recognize a symlink to a directory,
          ;; so must make it a relative filename as ls does"
          (begin
            (if (file-name-absolute-p file)
                (set! file (expand-file-name file)))
            (if (char=? #\/ (string-ref file (- (string-length file) 1)))
                (set! file (substring file 0 (- (string-length file) 1))))
            (let ((fattr (file-attributes file 'string)))
              (if fattr
                  (insert (ls-lisp-format
                           (if (memq #\F switches)
                               (ls-lisp-classify-file file fattr)
                               file)
                           fattr (file-attribute-size fattr)
                           switches time-index))
                  ;; "Emulate what we do on Posix hosts when we call
                  ;; access-file in insert-directory."
                  (error "Reading directory: Directory doesn't exist or is inaccessible"
                         file))))))

    ))