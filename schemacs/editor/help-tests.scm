;; -*- mode: scheme; -*-
;; Tests for `(schemacs editor help)' and `(schemacs editor doc)' -
;; help.el's `substitute-command-keys', `substitute-quotes',
;; `key-valid-p' and `help--key-description-fontified', and doc.c's
;; `documentation' / `documentation-property'.
;;
;; **Every expectation is `emacs -Q --batch`'s own answer** on the same
;; input, measured first. The command-name cases use a fresh process's
;; global map, where `narrow-to-region` is bound to `C-x n n`.

(import
  (scheme base)
  (scheme char)
  (only (guile) string-contains)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor buffer) *current-buffer* allocate-buffer
        get-buffer-create set-buffer erase-buffer current-buffer)
  (only (schemacs editor frame) *current-frame* new-frame)
  ;; loading editfns registers its commands in `*command-table*`, which
  ;; `documentation`'s symbol path reads.
  (schemacs editor editfns)
  (only (schemacs editor editfns) *text-quoting-style*)
  (only (schemacs editor subr) kbd)
  (only (schemacs editor textprop) get-text-property)
  (only (schemacs editor help)
        substitute-command-keys substitute-quotes key-valid-p
        help--key-description-fontified)
  (only (schemacs editor doc) documentation documentation-property)
  ;; Help mode, for its effect: it installs `*help-mode-function*`, which
  ;; is what puts `*Help*` in the mode (help.el is below help-mode.el and
  ;; reaches it the way Emacs reaches an autoload).
  (schemacs editor help-mode)
  ;; the describe machinery
  (only (schemacs editor help)
        describe-map describe-buffer-bindings describe-bindings
        help--describe-map-compare help-fns-function-name help-buffer)
  (only (schemacs editor command) define-command)
  (only (schemacs editor keymap) keymap define-key *default-keymap*
        lookup-key keymapp)
  (only (schemacs editor buffer) get-buffer-create buffer-local-keymap
        buffer-read-only? buffer-local-value buffer-name erase-buffer
        set-buffer set!buffer-local-keymap)
  (only (schemacs editor editfns) buffer-string)
  (only (schemacs editor frame) window-list window-buffer *current-frame*)
  (only (ice-9 exceptions) exception-message))

(test-begin "schemacs_editor_help")

;; The tree's string properties live beside the string
;; (`string-intervals-property`), not in it, so `test-equal`'s `equal?`
;; compares contents and these tests can assert on the strings directly.

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*help-tests*")))
      (set-buffer b)
      (erase-buffer)
      (thunk))))

;; ------------------------------------------------------------------
;; `key-valid-p' - the table measured on Emacs 31.1.
(test-equal '(#t #t #t #t #t #f #f #t #t #f #f #f #f)
  (map key-valid-p
       (list "C-x" "C-x n n" "f" "<f6>" "C-M-<space>" "not-a-key"
             "" "S o m" "H-<left>" "M-C-down" "C-" "<>" "a  b")))

;; ------------------------------------------------------------------
;; `substitute-command-keys'

;; An ordinary string comes back unchanged.
(test-equal "abc"
  (with-buffer (lambda () (substitute-command-keys "abc"))))

;; `\[COMMAND]' - the key when bound, "M-x NAME" when not.
(test-equal "C-x n n"
  (with-buffer (lambda () (substitute-command-keys "\\[narrow-to-region]"))))
(test-equal "M-x no-such-command"
  (with-buffer
   (lambda () (substitute-command-keys "\\[no-such-command]"))))

;; `\`KEY'' - the key, fontified with `help-key-binding' (both the
;; `face' and the `font-lock-face' property, as the C adds both).
(test-equal "type C-x now"
  (with-buffer (lambda () (substitute-command-keys "type \\`C-x' now"))))
(test-equal '(help-key-binding help-key-binding)
  (with-buffer
   (lambda ()
     (let ((s (substitute-command-keys "type \\`C-x' now")))
       (list (get-text-property 5 'face s)
             (get-text-property 5 'font-lock-face s))))))

;; A quoted thing that is not a key is left for the quote rule: under
;; `curve' the backtick becomes a left quote and the apostrophe a right
;; one, and the backslash stands.
(test-equal "x\\‘not-a-key’"
  (with-buffer
   (lambda ()
     (parameterize ((*text-quoting-style* 'curve))
       (substitute-command-keys "x\\`not-a-key'")))))

;; `\=' quoting, at the end and in the middle, and a trailing backslash.
(test-equal '("abc\\" "abc\\=" "ab" "\\[")
  (with-buffer
   (lambda ()
     (list (substitute-command-keys "abc\\")
           (substitute-command-keys "abc\\=")
           (substitute-command-keys "a\\=b")
           (substitute-command-keys "\\=\\[")))))

;; The three quoting styles, measured.
(test-equal '("‘a’ and ’b’" "'a' and 'b'" "`a' and 'b'")
  (with-buffer
   (lambda ()
     (list (parameterize ((*text-quoting-style* 'curve))
             (substitute-command-keys "`a' and 'b'"))
           (parameterize ((*text-quoting-style* 'straight))
             (substitute-command-keys "`a' and 'b'"))
           (parameterize ((*text-quoting-style* 'grave))
             (substitute-command-keys "`a' and 'b'"))))))

(test-equal "‘a’" (substitute-quotes "`a'"))

;; `help--key-description-fontified' - the face on the key description.
(test-equal '("C-x n n" help-key-binding)
  (with-buffer
   (lambda ()
     (let ((s (help--key-description-fontified (kbd "C-x n n"))))
       (list s (get-text-property 0 'face s))))))

;; ------------------------------------------------------------------
;; `documentation' and `documentation-property'

;; `documentation' substitutes keys unless RAW: the docstring's
;; `\[widen]' becomes `C-x n w' in the first and stands in the second.
(test-assert "documentation substitutes keys"
  (let ((doc (documentation 'narrow-to-region)))
    (and doc (string-contains doc "C-x n w"))))
(test-assert "documentation RAW keeps \\[widen]"
  (let ((doc (documentation 'narrow-to-region #t)))
    (and doc (string-contains doc "\\[widen]"))))

(test-equal #f (documentation-property 'nothing-here 'variable-documentation))

;; A symbol that names nothing and is not a procedure is the C's
;; `void-function' report; this tree's one error type carries it.
(test-equal "Void function"
  (guard (e (#t (exception-message e))) (documentation 'no-such-function)))

(test-equal "Invalid function"
  (guard (e (#t (exception-message e))) (documentation 42)))

;; ------------------------------------------------------------------
;; `describe-map' and the tree over it - what `C-h b` is made of.
;;
;; Every expectation is Emacs 31.1's own answer for the same keymap,
;; measured first. The one difference is the separator line: Emacs in
;; `--batch` cannot underline and prints dashes, while a terminal can
;; - `emacs -nw` answers t to `(display-supports-face-attributes-p
;; '(:underline t))`, measured - and so does this tree, which is the
;; blank line the two print.

(define-command (help-test-forward) "A command for the describe tests."
  (interactive) #f)
(define-command (help-test-backward) "A command for the describe tests."
  (interactive) #f)
(define-command (help-test-goto) "A command for the describe tests."
  (interactive) #f)
(define-command (help-test-undo) "A command for the describe tests."
  (interactive) #f)

(define (help-test-keymap)
  (let ((m (keymap))
        (sub (keymap)))
    (define-key m (kbd "a") help-test-forward)
    (define-key m (kbd "b") help-test-backward)
    (define-key m (kbd "C-c") sub)
    (define-key sub (kbd "x") help-test-undo)
    (define-key m (vector 'f1) help-test-goto)
    m))

;; The sort: integers first and ascending, then symbols in the natural
;; version order.
(test-equal '(#t #f #t #f #t #t)
  (map (lambda (p) (help--describe-map-compare (list (car p)) (list (cadr p))))
       '((1 2) (2 1) (1 a) (a 1) (f2 f11) (a b))))

;; `help-fns-function-name' on this tree's definitions: a command's
;; name, and a plain procedure's.
(test-equal '("help-test-forward" "#<procedure>")
  (list (help-fns-function-name help-test-forward)
        (help-fns-function-name (lambda () #f))))

;; `describe-map' prints the map in sorted order, and the prefix's
;; contents (`C-c x') are not this map's entries - the caller's tree
;; walk describes them.
(test-equal "\na\t\thelp-test-forward\nb\t\thelp-test-backward\n<f1>\t\thelp-test-goto\n"
  (with-buffer
   (lambda ()
     (describe-map (help-test-keymap))
     (buffer-string))))

;; `describe-buffer-bindings' prints the sections; the local map's
;; heading is the major mode's, and its body is the subtree's too.
(let ((want (string-append
             "\f\n`fundamental-mode' Major Mode Bindings:\n\n"
             "Key             Binding\n\n"
             "a\t\thelp-test-forward\n"
             "b\t\thelp-test-backward\n"
             "<f1>\t\thelp-test-goto\n\n"
             "C-c x\t\thelp-test-undo\n")))
  (test-equal want
    (with-buffer
     (lambda ()
       (set!buffer-local-keymap (current-buffer) (help-test-keymap))
       (describe-buffer-bindings (current-buffer))
       (let* ((s (buffer-string))
              (i (string-contains s "`fundamental-mode'")))
         (substring s (- i 2) (+ (- i 2) (string-length want))))))))

;; `describe-bindings' makes `*Help*', puts it in help mode, read-only,
;; and shows it in a window - `with-help-window`'s whole job.
(test-equal '("*Help*" help-mode #t)
  (with-buffer
   (lambda ()
     (describe-bindings)
     (let ((h (get-buffer-create "*Help*")))
       (list (buffer-name h)
             (buffer-local-value h 'major-mode #f)
             (buffer-read-only? h))))))

;; ...and the window it went to is on the frame. `display-buffer` splits
;; the frame's only window for it, which is what the tree does on a
;; terminal too.
(test-equal #t
  (with-buffer
   (lambda ()
     (describe-bindings)
     (let ((h (get-buffer-create "*Help*")))
       (pair? (memq h (map window-buffer
                           (window-list (*current-frame*) #t))))))))

;; `C-h b` is `describe-bindings`, looked up the way the command loop
;; looks it up.
(test-equal #t
  (eq? (lookup-key *default-keymap* (kbd "C-h b")) describe-bindings))

(test-end "schemacs_editor_help")
