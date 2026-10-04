(import
 (scheme base)
 (scheme char)
 (only (guile) delete-file mkdir rmdir setvbuf)
 (only (schemacs editor engine) new-text-editor)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor buffer)
 (schemacs editor dired)
 (schemacs editor editfns)
 (only (schemacs editor buffer) *inhibit-read-only*)
 (only (schemacs editor files) revert-buffer insert-directory)
 (schemacs editor frame)
 (only (schemacs editor search) regexp-quote re-search-forward)
 (only (schemacs editor indent) indent-rigidly)
 (only (schemacs editor simple) beginning-of-line)
 (schemacs editor textprop)
 )

;; dired.el's tests: the line reader and the marking commands, driven the
;; way dired drives them.
;;
;; Every expectation is what `emacs -Q --batch' answers with
;; `(dired DIR)' and the same calls on the same tree - the listing is
;; `insert-directory''s, which ls-lisp-tests.scm has already checked
;; against Emacs's own ls-lisp byte for byte, so what is on trial here is
;; dired's reading of it.
;;
;; The tests make their own tree under /tmp and **delete nothing**: not
;; one of them calls a delete command. `dired-flag-file-deletion' here
;; only writes a `D' into the buffer, which is all it does in Emacs too
;; - the deleting is `dired-do-flagged-delete', which is not ported and
;; is not wanted in a test.

;; Unbuffered output, so a run that hangs shows where it got to - the
;; same line `textprop-tests.scm' carries, and for the same reason.
(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_dired_mode")

;; ------------------------------------------------------------------
;; the fixture

(define root "/tmp/schemacs-dired-mode-tests")

;; One frame for the whole file. Setting a parameter as a plain top-level
;; expression binds it for the rest of the file, which is what these tests
;; need: without a frame every command that reads the current buffer dies,
;; and the failure is a `struct-vtable' error on #f three frames away.
(*current-frame* (new-frame (new-text-editor) 24 80))

(define (fixture!)
  (for-each (lambda (name)
              (guard (e (#t #f)) (delete-file (string-append root name))))
            (list "/b.txt" "/a.txt" "/sub/c.txt"))
  (guard (e (#t #f)) (delete-file (string-append root "/sub/c.txt")))
  (guard (e (#t #f)) (rmdir (string-append root "/sub")))
  (guard (e (#t #f)) (rmdir root))
  (guard (e (#t #f)) (mkdir root))
  (guard (e (#t #f)) (mkdir (string-append root "/sub")))
  (call-with-output-file (string-append root "/a.txt")
    (lambda (p) (display "a" p)))
  (call-with-output-file (string-append root "/b.txt")
    (lambda (p) (display "bb" p)))
  (call-with-output-file (string-append root "/sub/c.txt")
    (lambda (p) (display "ccc" p))))

(fixture!)

(define (listing . switches)
  ;; A dired buffer, made the way dired makes one: `dired-noselect'. It
  ;; sets `dired-directory', `dired-actual-switches' and
  ;; `dired-subdir-alist', puts the header line and the two-space indent
  ;; in, and is the same path `C-x d' takes - which is what the tests
  ;; should be driving now that the way in is ported.
  ;;
  ;; The directory is passed with its trailing slash, as `C-x d' passes
  ;; it: `dired-insert-directory' takes the header's name from
  ;; `(file-name-directory dir)', which is the whole name only when the
  ;; name *is* a directory name.
  ;;
  ;; A *fresh* buffer each time. The registry hands the same buffer back
  ;; for the same directory, and a revert keeps the marks - which is
  ;; Emacs's behaviour and exactly what `dired-revert' is for - so a test
  ;; that marks a line would leave it marked for the next one. Killing it
  ;; first also exercises the registry dropping a killed buffer, which
  ;; `dired-buffers-for-dir' does as a side effect.
  (for-each kill-buffer (dired-buffers-for-dir root))
  (let ((buffer (dired-noselect (string-append root "/")
                                (if (pair? switches) (car switches) "-al"))))
    (set-buffer buffer)
    (goto-char (point-min))
    buffer))

(define (goto-file-line name)
  ;; Point at the beginning of the line naming NAME, whichever line of
  ;; the listing that is - the tests must not count lines, because the
  ;; header and the `total' line are what changed when the indent
  ;; started working.
  (goto-char (point-min))
  (re-search-forward (string-append " " (regexp-quote name)) #f #t)
  (beginning-of-line)
  (point))

(define (goto-dot-line)
  ;; The `.` line: a space, then `.` at the end of the line. Searching
  ;; for `\.$' alone would find the `..' line too.
  (goto-char (point-min))
  (re-search-forward " \\.$" #f #t)
  (beginning-of-line)
  (point))

(define (names)
  ;; Every file name on every line, the way dired reads them.
  (goto-char (point-min))
  (let loop ((acc '()))
    (if (eobp)
        (reverse acc)
        (begin
          (if (dired-move-to-filename)
              (set! acc (cons (dired-get-filename 'no-dir #t) acc))
              #f)
          (forward-line 1)
          (loop acc)))))

(define (first-chars-of-every-line)
  ;; The first two characters of each line, which is where a mark goes.
  (let ((text (buffer-string)))
    (map (lambda (line) (if (> (string-length line) 1)
                            (substring line 0 2)
                            line))
         (let loop ((i 0) (start 0) (acc '()))
           (if (>= i (string-length text))
               (reverse (cons (substring text start i) acc))
               (if (char=? #\newline (string-ref text i))
                   (loop (+ i 1) (+ i 1) (cons (substring text start i) acc))
                   (loop (+ i 1) start acc)))))))

;; ------------------------------------------------------------------
;; reading the listing

;; the whole listing, read line by line - the names, in the order they
;; appear, `.' and `..' included, measured: `emacs -Q --batch' answers
;; exactly this list for the same tree
(test-equal '("." ".." "a.txt" "b.txt" "sub")
  (let ((b (listing))) (names)))

;; and the buffer above it is dired's: the directory's header line, then
;; the `total' line, then the indented listing.
;;
;; The `total' line is a **departure**: Emacs 31 deletes it. Its
;; `dired-free-space' is `first' by default (dired.el:224), and
;; `dired--insert-disk-space' reads that as "remove the total line and
;; put the free space as a `display' property on the header's colon",
;; which needs `file-system-info' (fileio.c) and `get-free-disk-space'
;; (files.el). Neither is ported, so this leaves the line where ls-lisp
;; put it. Measured: `(dired-noselect DIR)' in `emacs -Q --batch' gives
;; a first content line of `  drwxr-xr-x', not `  total'.
;; The second line is `  total N', and N is the tree's block count, which
;; is not this test's business - so the prefix is asserted, not the line.
(test-equal (list (string-append "  " root ":") "  total")
  (let ((b (listing)))
    (goto-char (point-min))
    (list (buffer-substring-no-properties (line-beginning-position)
                                          (line-end-position))
          (let ((start (line-beginning-position 2)))
            (buffer-substring-no-properties start (+ start 7))))))

;; `dired-move-to-filename' leaves point on the name
(test-equal "a.txt"
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
    (dired-move-to-filename)
    (buffer-substring-no-properties (point) (dired-move-to-end-of-filename #t))))

;; the three shapes `dired-get-filename' answers in
(test-equal (list (string-append root "/a.txt") "a.txt" "a.txt")
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
    (dired-move-to-filename)
    (list (dired-get-filename)
          (dired-get-filename 'no-dir)
          (dired-get-filename 'verbatim))))

;; "Return t if ... on a line with no file" - the `total' line
(test-equal '(#t #f)
  (let ((b (listing)))
    (goto-char (point-min))
    ;; the `total' line, found by its text rather than counted to: the
    ;; header and the total line are what the indent fix changed
    (re-search-forward "^  total" #f #t)
    (beginning-of-line)
    (let ((total (dired-between-files)))
      (goto-file-line "a.txt")
      (list total (dired-between-files)))))

(test-equal "the marker regexp is the current marker's line"
  "^\\*"
  (dired-marker-regexp))

;; ------------------------------------------------------------------
;; marking, which is all these commands do.
;;
;; The second argument is Emacs's `&optional interactive'; this tree's
;; convention is fixed parameters the interactive expression fills in,
;; so a caller from Lisp passes #f - which is exactly what Emacs's nil
;; means, and what skips the region branch.

;; measured: mark writes `*' in the first column, and on a *dot* line too
;; - the C's last guard lets it through when the marker is not the
;; deletion flag. One leading `"  "' more than there used to be, for the
;; header line the indent fix brought in.
(test-equal '("  " "  " "  " "  " "* " "  " "  " "")
  (let ((b (listing)))
    (goto-file-line "a.txt")
    (dired-mark 1 #f)
    (first-chars-of-every-line)))

(test-equal '("  " "  " "* " "  " "  " "  " "  " "")
  (let ((b (listing)))
    (goto-dot-line)
    (dired-mark 1 #f)
    (first-chars-of-every-line)))

;; `dired-flag-file-deletion' is the same command with the deletion
;; marker bound
(test-equal '("  " "  " "  " "  " "  " "D " "  " "")
  (let ((b (listing)))
    (goto-file-line "b.txt")
    (dired-flag-file-deletion 1 #f)
    (first-chars-of-every-line)))

;; and `dired-unmark' the same with a space
(test-equal '("  " "  " "  " "  " "  " "  " "  " "")
  (let ((b (listing)))
    (goto-file-line "a.txt")
    (dired-mark 1 #f)
    ;; `dired-repeat-over-lines' leaves point on the *next* file line, so
    ;; a bare `(dired-unmark 1)' straight after a mark unmarks the line
    ;; below - Emacs's answer too. Back to a.txt first, which is what a
    ;; user pressing `m' then `u' on the same line does.
    (goto-file-line "a.txt")
    (dired-unmark 1 #f)
    (first-chars-of-every-line)))

;; a prefix argument marks that many lines
(test-equal '("  " "  " "  " "  " "* " "* " "  " "")
  (let ((b (listing)))
    (goto-file-line "a.txt")
    (dired-mark 2 #f)
    (first-chars-of-every-line)))

;; ------------------------------------------------------------------
;; `dired-insert-set-properties'

;; the symbol `highlight', not the string - `mouse-face''s value is a
;; face name, and `test-equal' compares with `equal?', which does not
;; confuse the two even though the failure output looks alike
(test-equal (list #t 'highlight)
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
    ;; `dired-insert-set-properties' writes properties, and a property
    ;; change checks read-only as an insertion does - so the caller binds
    ;; it, which in Emacs is `dired-readin'
    (parameterize ((*inhibit-read-only* #t))
      (dired-insert-set-properties (point-min) (point-max)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (goto-char (- (point) 1))
    (list (get-text-property (- (point) 1) 'dired-filename)
          (get-char-property (- (point) 1) 'mouse-face))))

;; ------------------------------------------------------------------
;; `dired-move-to-end-of-filename''s regexp path
;;
;; This is the path that runs when the `dired-filename' property is
;; absent, which is what happens without `ls --dired'. It never worked:
;; it answered nil for every ordinary file, because the port had dropped
;; the `(goto-char eol)' the C does for a non-symlink (dired.el:3581) and
;; put one in the *symlink* branch instead - where the C has none. It was
;; invisible because `re-search-backward', which finds the permission
;; flags, also answered nil for everything; a nil from either is read as
;; "no file on this line".
;;
;; The listing is plain text here, so there is no property on it at all.
;; Expectations measured: `emacs -Q --batch' reading the same lines.

(define (plain-listing . switches)
  (let ((buffer (get-buffer-create "*dired-plain*")))
    (set-buffer buffer)
    (erase-buffer)
    (set!dired-directory! "/tmp/")
    (set!dired-actual-switches! (if (pair? switches) (car switches) "-al"))
    (insert "  -rw-r--r--  1 chris chris    1 10-04 06:03 a.txt\n")
    (insert "  drwxr-xr-x  2 chris chris   60 10-04 06:03 sub\n")
    (insert "  -rwxr-xr-x  1 chris chris    1 10-04 06:03 run\n")
    (insert "  lrwxrwxrwx  1 chris chris    4 10-04 06:03 link -> a.txt\n")
    (goto-char (point-min))
    buffer))

(define (marked-listing)
  ;; the same lines as `ls -F' writes them: `/` on the directory, `*' on
  ;; the executable, and `@' on the link whose *link* is marked
  (let ((buffer (get-buffer-create "*dired-marked*")))
    (set-buffer buffer)
    (erase-buffer)
    (set!dired-directory! "/tmp/")
    (set!dired-actual-switches! "-alF")
    (insert "  -rw-r--r--  1 chris chris    1 10-04 06:03 a.txt\n")
    (insert "  drwxr-xr-x  2 chris chris   60 10-04 06:03 sub/\n")
    (insert "  -rwxr-xr-x  1 chris chris    1 10-04 06:03 run*\n")
    (insert "  lrwxrwxrwx  1 chris chris    4 10-04 06:03 link -> a.txt\n")
    (insert "  lrwxrwxrwx  1 chris chris    4 10-04 06:03 link2@ -> a.txt\n")
    (goto-char (point-min))
    buffer))

(define (names-on-every-line)
  (goto-char (point-min))
  (let loop ((acc '()))
    (if (eobp)
        (reverse acc)
        (begin
          (beginning-of-line)
          (let ((p1 (dired-move-to-filename)))
            (if p1
                (let ((p2 (dired-move-to-end-of-filename #t)))
                  (set! acc (cons (and p2 (buffer-substring-no-properties p1 p2))
                                  acc)))))
          (forward-line 1)
          (loop acc)))))

(test-equal '("a.txt" "sub" "run" "link")
  (let ((b (plain-listing))) (names-on-every-line)))

;; With `-F' each name carries one trailing type character, and the C
;; backs off exactly one for a directory, a socket, a fifo or an
;; executable - but not for a plain file. Note that the listing has to
;; actually carry the markers: `-alF' over a listing *without* them makes
;; the C back off a real character, which `emacs -Q --batch' confirms by
;; answering `("a.txt" "su" "ru" "link")' for that shape.
(test-equal '("a.txt" "sub" "run" "link" "link2@")
  (let ((b (marked-listing))) (names-on-every-line)))

;; `dired-ls-F-marks-symlinks' is the C's `dired-ls-F-marks-symlinks':
;; nil means `ls -F' is taken to mark the *target* (`link -> a.txt'), so
;; the `@' on `link2@ -> a.txt' stays part of the name; t means it marks
;; the link itself and the `@' comes off. Both lists measured.
(test-equal '("a.txt" "sub" "run" "link" "link2")
  (let ((b (marked-listing)))
    (parameterize ((*dired-ls-F-marks-symlinks* #t))
      (names-on-every-line))))

(test-end "schemacs_editor_dired_mode")
