;; -*- mode: scheme; -*-
;; Tests for `(schemacs progmodes prog-mode)' - the two commands `prog-mode.el'
;; puts in `prog-mode-map', `C-M-q' (`prog-indent-sexp') and `M-q'
;; (`prog-fill-reindent-defun'), and the text-detection predicate under the
;; second.
;;
;; **Every expectation is Emacs 31.1's own answer**, measured with
;; `emacs -Q --batch' on the same text in `emacs-lisp-mode' first; the
;; command output is compared byte for byte.

(import
  (scheme base)
  (scheme char)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs buffer)
        *current-buffer* allocate-buffer get-buffer-create set-buffer
        erase-buffer set!buffer-fill-column)
  (only (schemacs editfns) insert buffer-string goto-char)
  (only (schemacs frame) *current-frame* new-frame)
  (only (schemacs syntax)
        set-syntax-table copy-syntax-table standard-syntax-table)
  (only (schemacs progmodes elisp-mode) emacs-lisp-mode)
  (only (schemacs progmodes prog-mode)
        prog-mode prog-mode-map prog-indent-sexp prog-fill-reindent-defun
        prog--text-at-point-p)
  (only (schemacs keymap) keymap-lookup)
  (only (schemacs keyboard) key-binding)
  (only (schemacs subr) kbd))

(test-begin "schemacs_editor_prog_mode")

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*prog-mode-tests*")))
      (set-buffer b)
      (erase-buffer)
      (set-syntax-table (copy-syntax-table (standard-syntax-table)))
      (thunk b))))

(define fixture "(defun foo ()\n(bar)\n  (baz))\n")

;; `C-M-q' (`prog-indent-sexp', `prog-mode.el:131') indents the expression
;; after point; Emacs at point 1 of the badly indented defun gives the
;; fully indented one.
(test-equal "C-M-q indents the sexp after point"
  "(defun foo ()\n  (bar)\n  (baz))\n"
  (with-buffer
   (lambda (b)
     (insert fixture)
     (emacs-lisp-mode)
     (goto-char 1)
     (prog-indent-sexp)
     (buffer-string))))

;; With a prefix, the enclosing defun. Measured on Emacs from point 15 (the
;; `(bar)' line): the whole defun comes out indented.
(test-equal "C-u C-M-q indents the enclosing defun"
  "(defun foo ()\n  (bar)\n  (baz))\n"
  (with-buffer
   (lambda (b)
     (insert fixture)
     (emacs-lisp-mode)
     (goto-char 15)
     (prog-indent-sexp #t)
     (buffer-string))))

;; `M-q' in code reindents the defun rather than filling anything.
(test-equal "M-q in code reindents the defun"
  "(defun foo ()\n  (bar)\n  (baz))\n"
  (with-buffer
   (lambda (b)
     (insert fixture)
     (emacs-lisp-mode)
     (goto-char 15)
     (prog-fill-reindent-defun)
     (buffer-string))))

;; `M-q' in a comment fills the paragraph, continuing the `;;' - Emacs with
;; `fill-column' 30.
(test-equal "M-q in a comment fills the paragraph"
  ";; a very long comment line\n;; that should be filled\n;; because it is long indeed"
  (with-buffer
   (lambda (b)
     (insert ";; a very long comment line that should be filled because it is long indeed")
     (emacs-lisp-mode)
     (set!buffer-fill-column b 30)
     (goto-char 5)
     (prog-fill-reindent-defun)
     (buffer-string))))

;; `prog--text-at-point-p' (`prog-mode.el:144'): comments and strings are
;; text, code is not. Emacs answers nil/nil in code and at a bare `(',
;; a position at a `;;' start and inside a comment, and a position inside
;; a string.
(test-equal "text-at-point: code and a bare paren are not text"
  '(#f #f)
  (with-buffer
   (lambda (b)
     (insert fixture)
     (emacs-lisp-mode)
     (list (begin (goto-char 20) (prog--text-at-point-p))
           (begin (goto-char 3) (prog--text-at-point-p))))))

(test-equal "text-at-point: a comment is text"
  '(1 1)
  (with-buffer
   (lambda (b)
     (insert ";; hello\nx")
     (emacs-lisp-mode)
     (list (begin (goto-char 1) (prog--text-at-point-p))
           (begin (goto-char 4) (prog--text-at-point-p))))))

;; Emacs answers 4 here - the `"' that opens the string.
(test-equal "text-at-point: a string is text"
  4
  (with-buffer
   (lambda (b)
     (insert "(x \";; in string\")\n")
     (emacs-lisp-mode)
     (goto-char 5)
     (prog--text-at-point-p))))

;; The two keys, as `prog-mode.el:104' binds them - in the map itself and,
;; through the derived mode's keymap parent, in a `prog-mode' buffer.
(test-equal "prog-mode-map binds C-M-q and M-q"
  (list 'prog-indent-sexp 'prog-fill-reindent-defun)
  (list (procedure-name (keymap-lookup prog-mode-map (kbd "C-M-q")))
        (procedure-name (keymap-lookup prog-mode-map (kbd "M-q")))))

(test-equal "M-q reaches prog-fill-reindent-defun through the mode"
  'prog-fill-reindent-defun
  (with-buffer
   (lambda (b)
     (prog-mode)
     (procedure-name (key-binding (kbd "M-q"))))))

(test-end "schemacs_editor_prog_mode")
