(import
  (scheme base)
  (scheme char)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor buffer)
        *current-buffer* allocate-buffer get-buffer-create set-buffer
        erase-buffer buffer-z set-point major-mode buffer-local-value)
  (only (schemacs editor editfns) insert)
  (only (schemacs editor frame) *current-frame* new-frame)
  (only (schemacs editor syntax)
        char-syntax set-syntax-table syntax-table standard-syntax-table
        copy-syntax-table)
  (only (schemacs editor font-lock)
        font-lock-fontify-buffer font-lock-defaults set!font-lock-defaults!)
  (only (schemacs editor font-core) font-lock-mode)
  (only (schemacs editor textprop) get-text-property)
  (only (schemacs editor scheme) scheme-mode)
  (only (schemacs editor elisp-mode) emacs-lisp-mode lisp-interaction-mode)
  (only (schemacs editor lisp-mode) lisp-mode lisp-data-mode)
  (only (schemacs editor text-mode) text-mode)
  (only (schemacs editor files) find-file-noselect kill-buffer)
  (only (schemacs editor buffer) set!text-editor-file-name with-current-buffer))

;; Regression tests for the three Lisp-family modes that this tree now
;; has: `scheme-mode' (`lisp/progmodes/scheme.el'), `emacs-lisp-mode'
;; (`lisp/progmodes/elisp-mode.el') and `lisp-mode'
;; (`lisp/emacs-lisp/lisp-mode.el'). **Every face expectation is Emacs
;; 31.1's own answer**, measured with `emacs -Q --batch' on the same text
;; in the same mode; where this tree's answer differs the test says why
;; (the doc-string face, which needs `forward-sexp').

(test-begin "schemacs_editor_lisp_modes")

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*lisp-mode-tests*")))
      (set-buffer b)
      (erase-buffer)
      ;; The buffer keeps the syntax table of whatever mode ran last, and
      ;; a mode installs its own; starting from the standard one is what a
      ;; fresh buffer has.
      (set-syntax-table (copy-syntax-table (standard-syntax-table)))
      (thunk b))))

(define (face-at ed where) (get-text-property where 'face ed))

;; ------------------------------------------------------------------
;; the syntax tables

(with-buffer
 (lambda (b)
   (scheme-mode)
   (test-equal "scheme-mode is the major mode"
     'scheme-mode (major-mode))
   (test-equal "`;' starts a comment in Scheme"
     #\< (char-syntax #\;))
   (test-equal "... and `|' is a string quote, as Emacs's table has it"
     #\" (char-syntax #\|))
   (test-equal "... while a digit is a word constituent"
     #\w (char-syntax #\1))))

(with-buffer
 (lambda (b)
   (emacs-lisp-mode)
   (test-equal "emacs-lisp-mode is the major mode"
     'emacs-lisp-mode (major-mode))
   ;; measured: Emacs's `emacs-lisp-mode' keeps the `lisp-data-mode'
   ;; table, where `[' is the paren the base table makes it - the
   ;; `lisp-mode-syntax-table' that gives it symbol syntax is *lisp-mode's*
   (test-equal "`[' is a paren in Elisp, as in Emacs"
     #\( (char-syntax #\[))
   (test-equal "... and `#' quotes, with the comment flags Emacs gives it"
     #\' (char-syntax #\#))))

(with-buffer
 (lambda (b)
   (lisp-mode)
   (test-equal "lisp-mode is the major mode"
     'lisp-mode (major-mode))
   (test-equal "`[' is a symbol constituent in lisp-mode"
     #\_ (char-syntax #\[))
   (test-equal "... and `|' is a string quote"
     #\" (char-syntax #\|))))

;; ------------------------------------------------------------------
;; the fontification
;;
;; measured on `"(define (foo x) ; hi\n  \"s\" (+ x 1))\n"' in
;; `scheme-mode': `define' is the keyword, `foo' the function name, the
;; comment its own face, and the string `font-lock-string-face' here
;; where Emacs's `lisp-font-lock-syntactic-face-function' would say
;; `font-lock-doc-face' (they differ in name only - doc-face inherits
;; string-face, and this tree does not carry that function).

(with-buffer
 (lambda (b)
   (insert "(define (foo x) ; hi\n  \"s\" (+ x 1))\n")
   (set-point b 1)
   (scheme-mode)
   (font-lock-mode #t)
   (font-lock-fontify-buffer)
   (test-equal "`define' is a keyword"
     'font-lock-keyword-face (face-at b 3))
   (test-equal "`foo' is the function name"
     'font-lock-function-name-face (face-at b 11))
   (test-equal "the comment's `;' is the comment face"
     'font-lock-comment-face (face-at b 18))
   (test-equal "... and the comment's text too"
     'font-lock-comment-face (face-at b 20))
   (test-equal "the string is the string face"
     'font-lock-string-face (face-at b 25))
   (test-equal "and the space after the name has none"
     #f (face-at b 13))))

;; measured on `"(defun foo (x) \"doc\" x)\n"' in `emacs-lisp-mode':
;; `defun' keyword, `foo' function name, and (in Emacs) the docstring's
;; `font-lock-doc-face' where this tree has the string face.
(with-buffer
 (lambda (b)
   (insert "(defun foo (x) \"doc\" x)\n")
   (set-point b 1)
   (emacs-lisp-mode)
   (font-lock-mode #t)
   (font-lock-fontify-buffer)
   (test-equal "`defun' is a keyword in Elisp"
     'font-lock-keyword-face (face-at b 3))
   (test-equal "`foo' is the function name"
     'font-lock-function-name-face (face-at b 9))
   (test-equal "the docstring is a string here"
     'font-lock-string-face (face-at b 20))))

;; the same shape in `lisp-mode' (Common Lisp keywords)
(with-buffer
 (lambda (b)
   (insert "(defun foo (x) (format t \"hi\"))\n")
   (set-point b 1)
   (lisp-mode)
   (font-lock-mode #t)
   (font-lock-fontify-buffer)
   (test-equal "`defun' is a keyword in lisp-mode too"
     'font-lock-keyword-face (face-at b 3))
   (test-equal "`foo' is the function name"
     'font-lock-function-name-face (face-at b 9))))

;; ------------------------------------------------------------------
;; the mode's variables

(with-buffer
 (lambda (b)
   (scheme-mode)
   (test-equal "prog-mode gives the buffer a final newline on saving"
     #t (buffer-local-value b 'require-final-newline #f))
   (test-equal "and it asks the Lisp scanner to ignore comments"
     #t (buffer-local-value b 'parse-sexp-ignore-comments #f))
   (test-equal "the mode's font-lock-defaults name the three levels"
     3 (length (car (font-lock-defaults))))))

;; ------------------------------------------------------------------
;; `lisp-data-mode' and `lisp-interaction-mode'

(with-buffer
 (lambda (b)
   (lisp-data-mode)
   (test-equal "lisp-data-mode is its own mode"
     'lisp-data-mode (major-mode))
   (test-equal "... and `[' is a paren, as Emacs's lisp-data table has it"
     #\( (char-syntax #\[))))

(with-buffer
 (lambda (b)
   (lisp-interaction-mode)
   (test-equal "lisp-interaction-mode derives from emacs-lisp-mode"
     'lisp-interaction-mode (major-mode))
   (test-equal "... and keeps the Elisp table"
     #\( (char-syntax #\[))))

;; ------------------------------------------------------------------
;; `set-auto-mode' chooses the mode from the file name
;;
;; `auto-mode-alist' is Emacs 31.1's own list, so `.scm' is
;; `scheme-mode', `.el' is `emacs-lisp-mode' and a `-*- mode: ... -*-'
;; tag beats the name - all measured on Emacs 31.1.

(define (write-file path text)
  (let ((port (open-output-file path)))
    (display text port)
    (close-port port)))

(define (visit path text)
  (write-file path text)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80)))
    (let ((b (find-file-noselect path)))
      (let ((mode (with-current-buffer b (major-mode))))
        (kill-buffer b)
        mode))))

(test-equal "a `.scm' file opens in scheme-mode"
  'scheme-mode (visit "/tmp/auto-mode-test.scm" "(define x 1)\n"))

(test-equal "a `.el' file opens in emacs-lisp-mode"
  'emacs-lisp-mode (visit "/tmp/auto-mode-test.el" "(defvar x 1)\n"))

(test-equal "a `.sld' file opens in scheme-mode too"
  'scheme-mode (visit "/tmp/auto-mode-test.sld" "(define-library (x))\n"))

(test-equal "a `-*- mode: lisp -*-' tag beats the file name"
  'lisp-mode (visit "/tmp/auto-mode-test.scm.txt"
                    ";; -*- mode: lisp -*-\n(defun x ())\n"))

(test-equal "a `.txt' file opens in text-mode"
  'text-mode (visit "/tmp/auto-mode-test.txt" "hello\n"))

(test-equal "a file whose mode this tree has not got keeps the default"
  'fundamental-mode (visit "/tmp/auto-mode-test.c" "int main(void) {}\n"))

(test-end "schemacs_editor_lisp_modes")
