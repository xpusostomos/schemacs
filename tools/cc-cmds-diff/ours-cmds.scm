;; The schemacs side of the cc-cmds indentation differential. Usage:
;;   guile --no-auto-compile -L . -L "$SITE" -s ours-cmds.scm STYLE FILE OUT [cpp]
;; The mode replay is `tools/cc-indent-diff/ours-indent.scm''s; the
;; command under test is `c-indent-region' over the whole buffer.
(import (scheme base) (scheme write)
        (schemacs buffer) (schemacs editfns)
        (schemacs syntax) (schemacs cmds)
        (schemacs progmodes cc-defs) (schemacs progmodes cc-langs)
        (schemacs progmodes cc-vars) (schemacs progmodes cc-styles)
        (schemacs progmodes cc-engine) (schemacs progmodes cc-align)
        (schemacs progmodes cc-cmds)
        (only (schemacs insdel) *before-change-functions* *after-change-functions*)
        (only (schemacs progmodes cc-mode) c-before-change c-after-change))
(define args (cdr (command-line)))
(define style (car args))
(define file (cadr args))
(define out (caddr args))
(define cpp? (and (pair? (cdddr args)) (string=? (cadddr args) "cpp")))
(define mode (if cpp? 'c++-mode 'c-mode))
(define b (get-buffer-create "cmds"))
(set-buffer b)
(call-with-input-file file
  (lambda (p) (let loop () (let ((c (read-char p))) (unless (eof-object? c) (insert (string c)) (loop))))))
(set-buffer-local-value! b 'major-mode mode)
(set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
(set-syntax-table (if cpp?
                      ((c-lang-const c-make-mode-syntax-table c++))
                      ((c-lang-const c-make-mode-syntax-table c))))
(parameterize ((*c-buffer-is-cc-mode* mode))
  (if cpp? (c-init-language-vars c++-mode) (c-init-language-vars c-mode))
  (c-set-style style)
  (c-setup-paragraph-variables)
  (c-clear-found-types)
  (c-make-noise-macro-regexps)
  (c-make-macro-with-semi-re)
  (when cpp?
    (set!c-new-BEG (point-min))
    (set!c-new-END (point-max))
    (c-restore-<>-properties (point-min) (point-max) 0)))
(goto-char (point-min))
;; `c-buffer-is-cc-mode' is a buffer-local in Emacs, set by
;; `c-basic-common-init'; this tree models it as a parameter, so it must
;; be bound for the whole command - C++-only branches (Qt access labels
;; among them) read it.
(parameterize ((*c-buffer-is-cc-mode* mode)
               (*before-change-functions*
                (cons c-before-change (*before-change-functions*)))
               (*after-change-functions*
                (cons c-after-change (*after-change-functions*))))
  (c-indent-region (point-min) (point-max)))
(call-with-output-file out
  (lambda (p) (display (buffer-substring (point-min) (point-max)) p)))
