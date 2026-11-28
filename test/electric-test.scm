;; Tests for `(schemacs electric)', a port of GNU Emacs's `lisp/electric.el'.
;; Every expectation is what `emacs -Q --batch' answers for the same
;; setup (measured first): a fundamental-mode buffer holding "  abc",
;; then `newline' typed, under each of the settings below.

(import
 (scheme base)
 (scheme file)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer)
       allocate-buffer set-buffer current-buffer set-buffer-local-value!
       buffer-local-value local-variable-p set!buffer-file-name)
 (only (schemacs character) kbd)
 (only (schemacs command) call-interactively)
 (only (schemacs editfns)
       insert point point-max goto-char buffer-string
       buffer-substring-no-properties)
 (only (schemacs fileio) delete-file-internal)
 (only (schemacs cmds) *post-self-insert-hook* self-insert-command)
 (only (schemacs command) *last-command-event*)
 (only (schemacs progmodes cc-mode) c-mode)
 (only (schemacs textmodes text-mode) text-mode)
 (only (schemacs files)
       save-buffer *before-save-hook* *after-save-hook*
       *require-final-newline*)
 (only (schemacs indent) indent-relative)
 (only (schemacs keyboard) key-binding)
 (only (schemacs simple)
       insert-newline newline-and-indent *real-this-command*
       *blink-matching-paren*)
 (only (schemacs subr) add-hook remove-hook)
 (only (schemacs electric)
       *electric-indent-actions* electric-indent-chars set!electric-indent-chars
       *electric-layout-rules* electric-layout-rules set!electric-layout-rules
       electric-layout-mode electric-layout-mode-value
       electric-quote-mode
       *electric-indent-functions*
       electric-indent-inhibit set!electric-indent-inhibit
       *electric-indent-functions-without-reindent*
       electric-indent-can-reindent-p
       electric-indent--activate-indent-actions
       electric-indent-save-hook
       electric-indent-post-self-insert-function
       electric-indent-just-newline
       electric-newline-and-maybe-indent
       electric-indent-mode electric-indent-mode-hook
       electric-indent-mode-value
       electric-indent-local-mode electric-indent-local-mode-hook))

(test-begin "schemacs_editor_electric")

(define (fresh)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "  abc")
    b))

(define (text)
  (buffer-substring-no-properties 1 (point-max)))

;;----------------------------------------------------------------------
;; The mode is on and its hook is in place, as Emacs is dumped
;;----------------------------------------------------------------------

(test-equal "the mode is on by default" #t (electric-indent-mode-value))
(test-assert "and its post-self-insert entry is installed"
             (not (not (memq electric-indent-post-self-insert-function
                             (*post-self-insert-hook*)))))
(test-assert "its hook variable is a parameter"
             (procedure? electric-indent-mode-hook))
(test-assert "as is the local mode's"
             (procedure? electric-indent-local-mode-hook))
(test-equal "C-j is electric-newline-and-maybe-indent, not plain newline"
            #t (eq? (key-binding (kbd "C-j"))
                    electric-newline-and-maybe-indent))
(test-equal "newline is the only electric character by default"
            (list 10) (electric-indent-chars))

;;----------------------------------------------------------------------
;; What a typed newline does under each setting (Emacs's answers)
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (call-interactively insert-newline)
  (test-equal "a newline reindents the new line" "  abc\n  " (text)))

(let ((b (fresh)))
  (set!electric-indent-inhibit #t)
  (call-interactively insert-newline)
  (test-equal "electric-indent-inhibit does not stop the new line's indent"
              "  abc\n  " (text)))

(let ((b (fresh)))
  (electric-indent-local-mode -1)
  (call-interactively insert-newline)
  (test-equal "with the mode off locally, a newline does not indent"
              "  abc\n" (text)))

(let ((b (fresh)))
  (parameterize ((*electric-indent-functions*
                  (list (lambda (char) 'no-indent))))
    (call-interactively insert-newline))
  (test-equal "a hook answering no-indent stops the indentation"
              "  abc\n" (text)))

(let ((b (fresh)))
  (electric-indent-mode -1)
  (call-interactively insert-newline)
  (test-equal "with the mode off globally, a newline does not indent"
              "  abc\n" (text))
  (electric-indent-mode 1)
  (test-assert "and the mode and its hook come back"
               (and (electric-indent-mode-value)
                    (not (not (memq electric-indent-post-self-insert-function
                                    (*post-self-insert-hook*)))))))

(let ((b (fresh)))
  (call-interactively electric-newline-and-maybe-indent)
  (test-equal "the C-j command inserts a newline with no indentation"
              "  abc\n" (text)))

(let ((b (fresh)))
  (electric-indent-mode -1)
  (call-interactively electric-newline-and-maybe-indent)
  (test-equal "with the mode off it indents like newline-and-indent"
              "  abc\n  " (text))
  (electric-indent-mode 1))

(let ((b (fresh)))
  (electric-indent-mode -1)
  (call-interactively newline-and-indent)
  (test-equal "newline-and-indent indents with the mode off"
              "  abc\n  " (text))
  (electric-indent-mode 1))

;;----------------------------------------------------------------------
;; electric-indent-inhibit is buffer-local
;;----------------------------------------------------------------------

(let ((a (fresh)))
  (set!electric-indent-inhibit #t)
  (test-equal "the buffer's own value" #t (electric-indent-inhibit))
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (test-equal "another buffer is not inhibited" #f (electric-indent-inhibit))))

;;----------------------------------------------------------------------
;; electric-indent-can-reindent-p
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (test-equal "the default indent-line-function cannot reindent" #f
              (electric-indent-can-reindent-p))
  (set-buffer-local-value! b 'indent-line-function (lambda () #f))
  (test-equal "a real one can" #t (electric-indent-can-reindent-p))
  (set!electric-indent-inhibit #t)
  (test-equal "unless this buffer is inhibited" #f
              (electric-indent-can-reindent-p))
  (set!electric-indent-inhibit #f)
  (set-buffer-local-value! b 'indent-line-function indent-relative)
  (test-equal "and the four line-up style functions are refused" #f
              (electric-indent-can-reindent-p))
  (test-equal "the list holds procedures" #t
              (eq? (car (*electric-indent-functions-without-reindent*))
                   indent-relative)))

;;----------------------------------------------------------------------
;; electric-indent-local-mode
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (electric-indent-local-mode -1)
  (test-equal "the local mode can turn it off in one buffer" #f
              (electric-indent-mode-value))
  (test-equal "another buffer still has it on" #t
              (let ((other (allocate-buffer)))
                (set-buffer other)
                (electric-indent-mode-value)))
  (set-buffer b)
  (electric-indent-local-mode 1)
  (test-equal "turning it back on kills the local binding, as Emacs does" #t
              (electric-indent-mode-value))
  (test-assert "which leaves no local value behind"
               (not (local-variable-p 'electric-indent-mode b))))

;;----------------------------------------------------------------------
;; The save hooks, and the before-save action
;;----------------------------------------------------------------------

(let* ((b (fresh))
       (path "/tmp/electric-save-test.txt")
       (log '()))
  (set!buffer-file-name b path)
  (let ((before (lambda () (set! log (cons 'before log))
                   (goto-char (point-max))
                   (insert "!")))
        (after (lambda () (set! log (cons 'after log)))))
    (add-hook *before-save-hook* before)
    (add-hook *after-save-hook* after)
    ;; This tree's `require-final-newline' defaults to #t where Emacs's
    ;; is nil (a named departure, files.scm); bind Emacs's answer so the
    ;; hook, not the newline rule, is what the file shows.
    (parameterize ((*require-final-newline* #f))
      (save-buffer))
    (remove-hook *before-save-hook* before)
    (remove-hook *after-save-hook* after)
    (test-equal "the save hooks run, before then after" '(before after)
                (reverse log))
    (test-equal "the before hook's edit is what was written" "  abc!"
                (call-with-input-file path
                  (lambda (port) (read-string 6 port))))
    (delete-file-internal path)))

(let ((b (fresh)))
  (parameterize ((*electric-indent-actions* '(before-save)))
    (electric-indent--activate-indent-actions #t)
    (test-assert "the before-save action installs its hook"
                 (not (not (memq electric-indent-save-hook
                                 (*before-save-hook*)))))
    (electric-indent--activate-indent-actions #f)
    (test-assert "and turning the action off removes it"
                 (not (memq electric-indent-save-hook
                            (*before-save-hook*))))))

;; The save hook only acts for a real save, as Emacs's
;; `real-this-command' test does.
(let ((b (fresh))
      (called #f))
  (set-buffer-local-value! b 'indent-line-function
                           (lambda () (set! called #t)))
  (parameterize ((*electric-indent-actions* '(before-save))
                 (*real-this-command* #f))
    (electric-indent-save-hook)
    (test-equal "a command that is not a save does not reindent" #f called)
    (parameterize ((*real-this-command* save-buffer))
      (electric-indent-save-hook)
      (test-equal "a save does" #t called))))

(test-end "schemacs_editor_electric")


;;----------------------------------------------------------------------
;; The other two modes (`electric.el:422`, `:575`).
;; Every expectation below is `emacs -Q --batch`'s output for the same
;; typed keys - `self-insert-command` with `last-command-event` bound,
;; which is what a keystroke does.
;;----------------------------------------------------------------------

(test-begin "schemacs_editor_electric_modes")

;; The group above's `fresh` holds "  abc" on purpose; these cases all
;; start from an empty buffer, as the Emacs measurements did.
(define (empty-buffer)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    b))

(define (type-text text)
  (for-each (lambda (c)
              (parameterize ((*last-command-event* (char->integer c)))
                (self-insert-command 1)))
            (string->list text)))

;; Emacs: typing "a{b!c}d" with rules `{ after', `} before', `! around'
;; answers "a{\nb\n!\nc\n}d".
(let ((b (empty-buffer)))
  (*electric-layout-rules* '((123 . after) (125 . before) (33 . around)))
  (electric-layout-mode 1)
  (dynamic-wind
   (lambda () #f)
   (lambda ()
     (type-text "a{b!c}d")
     (test-equal "electric-layout-mode inserts the rule's newlines"
                 "a{\nb\n!\nc\n}d"
                 (buffer-string)))
   (lambda ()
     (electric-layout-mode -1)
     (*electric-layout-rules* #f))))

;; Emacs: text-mode, "a `b' c" -> "a ‘b’ c".
(let ((b (empty-buffer)))
  (text-mode)
  (electric-quote-mode 1)
  (dynamic-wind
   (lambda () #f)
   (lambda ()
     (type-text "a `b' c")
     (test-equal "electric-quote-mode requotes in a paragraph"
                 "a ‘b’ c"
                 (buffer-string)))
   (lambda () (electric-quote-mode -1))))

;; Emacs: "``x''" -> "“x”".
(let ((b (empty-buffer)))
  (text-mode)
  (electric-quote-mode 1)
  (dynamic-wind
   (lambda () #f)
   (lambda ()
     (type-text "``x''")
     (test-equal "consecutive single quotes become a double quote"
                 "“x”"
                 (buffer-string)))
   (lambda () (electric-quote-mode -1))))

;; Emacs: fundamental-mode (no comment syntax) leaves them alone.
(let ((b (empty-buffer)))
  (electric-quote-mode 1)
  (dynamic-wind
   (lambda () #f)
   (lambda ()
     (type-text "a `b'")
     (test-equal "outside text and comments the quotes stay"
                 "a `b'"
                 (buffer-string)))
   (lambda () (electric-quote-mode -1))))

;; Emacs: inside a C comment they are requoted.
(let ((b (empty-buffer)))
  (c-mode)
  (electric-quote-mode 1)
  (dynamic-wind
   (lambda () #f)
   (lambda ()
     (parameterize ((*blink-matching-paren* #f))
       (type-text "/* a `b' */"))
     (test-equal "inside a comment they are requoted"
                 "/* a ‘b’ */"
                 (buffer-string)))
   (lambda () (electric-quote-mode -1))))

;; Emacs: c-mode with electric-indent-mode, "if (x) {" + newline + "yyy"
;; answers "if (x) {\n  yyy".
(let ((b (empty-buffer)))
  (c-mode)
  (electric-indent-mode 1)
  (parameterize ((*blink-matching-paren* #f))
    (type-text "if (x) {\nyyy"))
  (test-equal "electric-indent-mode indents the new line in c-mode"
              "if (x) {\n  yyy"
              (buffer-string)))

;; The buffer-local half of `electric-indent-chars`: a mode appends its
;; own characters (groovy-mode's `{}():;,[]'), and the reader sees them
;; in that buffer only.
(let ((b (empty-buffer)))
  (set!electric-indent-chars
   (cons (char->integer #\{) (electric-indent-chars)))
  (test-equal "set!electric-indent-chars extends this buffer's list"
              (cons (char->integer #\{) (list 10))
              (electric-indent-chars))
  (let ((other (fresh)))
    (test-equal "and another buffer still sees the default"
                (list 10)
                (electric-indent-chars))))

(test-end "schemacs_editor_electric_modes")
