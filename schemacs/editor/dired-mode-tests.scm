(import
 (scheme base)
 (scheme char)
 (only (guile) delete-file mkdir rmdir)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor buffer)
 (schemacs editor dired)
 (schemacs editor editfns)
 (schemacs editor files)
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

(test-begin "schemacs_editor_dired_mode")

;; ------------------------------------------------------------------
;; the fixture

(define root "/tmp/schemacs-dired-mode-tests")

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
  ;; A dired buffer, made the way `dired-readin' makes one: the listing
  ;; goes in with `dired-insert-directory' - which indents it by two and
  ;; puts the directory's header line above it - and the two
  ;; buffer-locals the commands read are set. The way *in*
  ;; (`dired-noselect') is not ported yet; see the library's comment.
  (let ((buffer (get-buffer-create "*dired-mode-tests*")))
    (set-buffer buffer)
    (erase-buffer)
    (set!dired-directory! (string-append root "/"))
    (set!dired-actual-switches! (if (pair? switches) (car switches) "-al"))
    (insert-directory root (if (pair? switches) (car switches) "-al") #f #t)
    ;; `dired-insert-directory' is ported and calls `indent-rigidly' for
    ;; this, but its own indent is not firing yet - see the note in the
    ;; library - so the tests do it with the same function, which is what
    ;; makes the buffer dired's shape. `dired-re-maybe-mark' is `"^. "',
    ;; so the shape is not cosmetic.
    (indent-rigidly (point-min) (point) 2)
    (goto-char (point-min))
    buffer))

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
;; the indented listing
(test-equal '("  total" "  drwxr-xr-x")
  (let ((b (listing)))
    (goto-char (point-min))
    (list (buffer-substring-no-properties (point) (+ (point) 7))
          (let ((start (line-beginning-position 2)))
            (buffer-substring-no-properties start (+ start 12))))))

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
    (let ((total (dired-between-files)))
      (forward-line 3)                    ; the a.txt line
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
;; deletion flag
(test-equal '("  " "  " "  " "* " "  " "  " "")
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
    (dired-mark 1 #f)
    (first-chars-of-every-line)))

(test-equal '("  " "* " "  " "  " "  " "  " "")
  (let ((b (listing)))
    (goto-char (point-min))
    (forward-line 1)                      ; the `.` line
    (dired-mark 1 #f)
    (first-chars-of-every-line)))

;; `dired-flag-file-deletion' is the same command with the deletion
;; marker bound
(test-equal '("  " "  " "  " "  " "D " "  " "")
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "b\\.txt" #f #t)
    (beginning-of-line)
    (dired-flag-file-deletion 1 #f)
    (first-chars-of-every-line)))

;; and `dired-unmark' the same with a space
(test-equal '("  " "  " "  " "  " "  " "  " "")
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
    (dired-mark 1 #f)
    ;; `dired-repeat-over-lines' leaves point on the *next* file line, so
    ;; a bare `(dired-unmark 1)' straight after a mark unmarks the line
    ;; below - Emacs's answer too. Back to a.txt first, which is what a
    ;; user pressing `m' then `u' on the same line does.
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
    (dired-unmark 1 #f)
    (first-chars-of-every-line)))

;; a prefix argument marks that many lines
(test-equal '("  " "  " "  " "* " "* " "  " "")
  (let ((b (listing)))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (beginning-of-line)
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
    (dired-insert-set-properties (point-min) (point-max))
    (goto-char (point-min))
    (re-search-forward "a\\.txt" #f #t)
    (goto-char (- (point) 1))
    (list (get-text-property (- (point) 1) 'dired-filename)
          (get-char-property (- (point) 1) 'mouse-face))))

(test-end "schemacs_editor_dired_mode")
