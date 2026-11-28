;; `replace.el`'s Occur - `occur`, `occur-mode` and the engine under
;; them. Every expectation here was measured on GNU Emacs 31.1 first,
;; with `emacs -Q --batch` on the same text.
;;
;; `occur` displays through `display-buffer`, so a frame is part of the
;; fixture; nothing here draws, and the *Occur* buffer's text and its
;; text properties are what the tests read. The search loop that runs
;; `isearch-occur` from the tool bar draws, so its end-to-end test is
;; `tty-editor-tests.scm`'s and the pty battery's.

(import (scheme base)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (only (schemacs custom) custom-variable-p)
        (only (schemacs buffer)
              current-buffer with-current-buffer
              get-buffer get-buffer-create %kill-buffer erase-buffer
              buffer-read-only? buffer-name major-mode
              *current-buffer*)
        (only (schemacs frame) *current-frame* new-frame)
        (only (schemacs editfns)
              insert buffer-string char-after point goto-char
              point-min forward-line)
        (only (schemacs simple)
              *next-error-highlight* *next-error-highlight-no-select*)
        (only (schemacs replace)
              occur occur-1 occur-mode occur-mode-goto-occurrence
              occur-next occur-prev occur-rename-buffer
              occur--targets-start occur-mode--find-occurrences
              occur-revert-arguments isearch-occur occur-mode-hook
              *list-matching-lines-default-context-lines*
              *list-matching-lines-jump-to-current-line*)
        (only (schemacs font-core) turn-on-font-lock)
        (only (schemacs textprop) get-text-property)
        (only (schemacs marker) marker-position marker-buffer)
        (only (schemacs isearch) isearch-string
              isearch-case-fold-search isearch-regexp)
        (only (schemacs command) current-prefix-arg
              command-procedure command-record-of)
        (only (schemacs subr) split-string)
        (only (schemacs frame) window-point)
        (only (schemacs window) get-buffer-window))

(test-begin "schemacs_editor_occur")

;;--------------------------------------------------------------------
;; The fixture
;;--------------------------------------------------------------------

;; A source buffer called ` *temp*` - the header line names the
;; buffer - with TEXT in it, and *Occur* thrown away first so each test
;; starts clean. `*next-error-highlight*` is off: Emacs's default 0.5
;; arms a timer, and a test has no command loop to run it.
(define (in-source text thunk)
  (let ((ed (get-buffer-create " *temp*")))
    (with-current-buffer ed
      (erase-buffer)
      (insert text))
    (let ((old (get-buffer "*Occur*")))
      (when old (%kill-buffer old)))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed)
                   (*next-error-highlight* #f))
      (thunk))))

(define (occur-text)
  (with-current-buffer (get-buffer "*Occur*")
    (buffer-string)))

;;--------------------------------------------------------------------
;; The list itself
;;--------------------------------------------------------------------

;; Emacs 31.1: `(occur "beta")` on this text writes
;;   "2 matches for "beta" in buffer:  *temp*"
;; with `           ` for the seven-wide line number of every line.
(test-equal "occur lists the matching lines, numbered in Emacs's field"
  "2 matches for \"beta\" in buffer:  *temp*\n      2:beta\n      3:gamma beta\n"
  (in-source "alpha\nbeta\ngamma beta\ndelta\n"
             (lambda () (occur "beta" #f #f) (occur-text))))

(test-equal "the *Occur* buffer is in occur-mode and read only"
  '(occur-mode #t)
  (in-source "alpha\nbeta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 (list (major-mode) (buffer-read-only? (current-buffer)))))))

;; The prefix carries `occur-prefix`, `read-only` and the `occur-target`
;; list of (BEG-MARKER . END-MARKER), one pair per match on the line:
;; Emacs's `text-properties-at 40` on the fixture. The positions are the
;; source buffer's - `beta` at 7..11 and `beta` at 18..22.
(test-equal "a line's prefix carries occur-target with one marker pair per match"
  '(1 (7 . 11))
  (in-source "alpha\nbeta\ngamma beta\ndelta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 ;; The prefix of the second line begins at 41.
                 (list (length (get-text-property 41 'occur-target))
                       (let ((pair (car (get-text-property
                                         41 'occur-target))))
                         (cons (marker-position (car pair))
                               (marker-position (cdr pair)))))))))

(test-equal "the matching text carries occur-match and the `match' face"
  '(t match)
  (in-source "alpha\nbeta\ngamma beta\ndelta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 ;; 49 is the `b` of the first line's `beta`.
                 (list (get-text-property 49 'occur-match)
                       (get-text-property 49 'face))))))

;;--------------------------------------------------------------------
;; context lines - NLINES
;;--------------------------------------------------------------------

;; Emacs 31.1, `(occur "match" 1)` on this text:
;;   "1 match for "match" in buffer:  *temp*"
;;   "       :l2"
;;   "      3:l3 match"
;;   "       :l4"
(test-equal "NLINES puts context lines round the match, prefixed with `       :`"
  "1 match for \"match\" in buffer:  *temp*\n       :l2\n      3:l3 match\n       :l4\n"
  (in-source "l1\nl2\nl3 match\nl4\nl5\n"
             (lambda () (occur "match" 1 #f) (occur-text))))

;; `list-matching-lines-jump-to-current-line` (Emacs 31.1 measured): the
;; line point was on - which does not match - is inserted between the
;; matches, carrying `current-line`, and the *window's* point is put
;; just after it (`occur--final-pos`, which `occur-1` reads after the
;; engine has returned - so the binding must span both).
(test-equal '(t 61)
  (in-source "l1\nl2 x\nl3\nl4 x\nl5\n"
             (lambda ()
               (goto-char 1)
               (forward-line 2)
               (parameterize ((*list-matching-lines-jump-to-current-line* #t))
                 (occur "x" #f #f))
               (with-current-buffer (get-buffer "*Occur*")
                 (list (get-text-property 59 'current-line)
                       (window-point (get-buffer-window (current-buffer) #t)))))))

(test-equal '("2 matches for \"x\" in buffer:  *temp*"
              "      2:l2 x"
              "       :l3"
              "      4:l4 x")
  (in-source "l1\nl2 x\nl3\nl4 x\nl5\n"
             (lambda ()
               (goto-char 1)
               (forward-line 2)
               (parameterize ((*list-matching-lines-jump-to-current-line* #t))
                 (occur "x" #f #f))
               (with-current-buffer (get-buffer "*Occur*")
                 (let ((lines (split-string (buffer-string) "\n")))
                   (list (car lines) (cadr lines) (caddr lines)
                         (cadddr lines)))))))

;;--------------------------------------------------------------------
;; collect mode - NLINES as a replacement regexp
;;--------------------------------------------------------------------

(test-equal "a string NLINES collects the replacements, in fundamental-mode"
  '("foo\nbar\n" fundamental-mode)
  (in-source "defun foo\ndefun bar\n"
             (lambda ()
               (occur "defun \\(\\S +\\)" "\\1" #f)
               (with-current-buffer (get-buffer "*Occur*")
                 (list (buffer-string) (major-mode))))))

;;--------------------------------------------------------------------
;; no matches
;;--------------------------------------------------------------------

(test-equal "no matches kills the *Occur* buffer"
  #f
  (in-source "alpha\n"
             (lambda () (occur "zzz" #f #f) (get-buffer "*Occur*"))))

;;--------------------------------------------------------------------
;; a region
;;--------------------------------------------------------------------

;; The header says "within region: START-END" and only the region is
;; searched. Emacs 31.1 measured: 1 match, the third line.
(test-equal "a region restricts the search and says so in the header"
  '("1 match for \"beta\" in buffer:  *temp* within region: 10-22"
    "      3:two beta")
  (in-source "one beta\ntwo\ntwo beta\n"
             (lambda ()
               (occur "beta" #f (list (cons 10 22)))
               (with-current-buffer (get-buffer "*Occur*")
                 (list (car (split-string (buffer-string) "\n"))
                       (cadr (split-string (buffer-string) "\n")))))))

;;--------------------------------------------------------------------
;; moving through the list
;;--------------------------------------------------------------------

;; `occur-next` goes to the position where `occur-match` changes - the
;; end of the match's run in the *Occur* buffer. Then Emacs signals
;; `user-error "No more matches"` on the third call (measured).
(test-equal '(53 72 user-error)
  (in-source "alpha\nbeta\ngamma beta\ndelta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 (goto-char 1)
                 (occur-next 1)
                 (let ((first (point)))
                   (occur-next 1)
                   (list first (point)
                         (guard (ex (else 'user-error))
                           (occur-next 1)
                           'no-error)))))))

;; RET on a line goes to that occurrence in its buffer: from the second
;; line's prefix, Emacs answers the buffer, point 7 and the character
;; there.
(test-equal '(" *temp*" 7 #\b)
  (in-source "alpha\nbeta\ngamma beta\ndelta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 (goto-char 41)
                 (occur-mode-goto-occurrence #f))
               (list (buffer-name) (point) (char-after (point))))))

;;--------------------------------------------------------------------
;; reverting - g hands the recorded arguments back
;;--------------------------------------------------------------------

(test-equal '("beta" #f)
  (in-source "alpha\nbeta\ngamma beta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 (let ((args (occur-revert-arguments)))
                   (list (car args) (cadr args)))))))

(test-equal "*Occur:  *temp**"
  (in-source "alpha\nbeta\n"
             (lambda ()
               (occur "beta" #f #f)
               (with-current-buffer (get-buffer "*Occur*")
                 (occur-rename-buffer #f #f)
                 (buffer-name)))))

;;--------------------------------------------------------------------
;; isearch-occur - the Show hits button's command
;;--------------------------------------------------------------------

;; `isearch-string` is a literal, so the command quotes it: searching
;; for `b.ta` with a literal search shows only the line holding a
;; literal `b.ta`, not every `beta` (measured: `1 match for "b\.ta"`,
;; then `      3:b.ta here`).
(test-equal '("1 match for \"b\\.ta\" in buffer:  *temp*"
              "      3:b.ta here")
  (in-source "alpha\nbeta\nb.ta here\n"
             (lambda ()
               (set! isearch-string "b.ta")
               (set! isearch-regexp #f)
               (parameterize ((current-prefix-arg #f))
                 ((command-procedure (command-record-of isearch-occur)) #f))
               (with-current-buffer (get-buffer "*Occur*")
                 (let ((lines (split-string (buffer-string) "\n")))
                   (list (car lines) (cadr lines)))))))

;; The case folding the search was using travels with the command
;; (`isearch-case-fold-search`), so a case-insensitive search lists the
;; other case too (measured: both lines).
(test-equal '("2 matches for \"beta\" in buffer:  *temp*"
              "      1:alpha BETA"
              "      2:beta")
  (in-source "alpha BETA\nbeta\n"
             (lambda ()
               (set! isearch-string "beta")
               (set! isearch-case-fold-search #t)
               (parameterize ((current-prefix-arg #f))
                 ((command-procedure (command-record-of isearch-occur)) #f))
               (with-current-buffer (get-buffer "*Occur*")
                 (let ((lines (split-string (buffer-string) "\n")))
                   (list (car lines) (cadr lines) (caddr lines)))))))

(test-end "schemacs_editor_occur")

;;----------------------------------------------------------------------
;; `occur-mode-hook` is a define-custom parameter (replace.el:1643)
;;----------------------------------------------------------------------
;; Emacs declares it a defcustom with `(turn-on-font-lock)' as its
;; default; here the default is set by calling the parameter (a `set!'
;; would shadow the imported binding and change nothing).

(test-begin "schemacs_editor_occur_hook")

(test-assert "occur-mode-hook is a parameter"
             (procedure? occur-mode-hook))

(test-equal "its default is the one function Emacs's defcustom names"
  (list turn-on-font-lock)
  (occur-mode-hook))

(test-equal "and it is a define-custom"
  #t
  (custom-variable-p 'occur-mode-hook))

(test-end "schemacs_editor_occur_hook")
