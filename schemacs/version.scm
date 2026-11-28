(define-library (schemacs version)
  ;; GNU Emacs's `lisp/version.el', the part of it that is data. The
  ;; C half is `emacs.c' - `DEFVAR_LISP ("emacs-version", ...)',
  ;; `emacs.c:3594' - and the two numerals `version.el' derives from it.
  ;;
  ;; The value: this tree replicates GNU Emacs 31.1, and every
  ;; behavioural measurement in the tree is against 31.1, so the string
  ;; is that release's. Subprocesses are told `INSIDE_EMACS=<this>
  ;; ,comint' by `comint-exec-1', which is where Emacs puts the same
  ;; text.
  ;;
  ;; **Not carried, and why**: `version.el''s `emacs-version` *command*
  ;; (the one that prints the banner) and `emacs-build-time', `-number'
  ;; and `-system-configuration', which it prints. They are a display of
  ;; a build this tree does not have. The command also cannot share its
  ;; name with the variable in a Lisp-1, which is the name collision
  ;; `comment-add' and `tab-bar-separator' already carry.

  (import (scheme base)
          (only (srfi srfi-13) string-contains))

  (export emacs-version emacs-major-version emacs-minor-version)

  (begin

    (define emacs-version
      ;; GNU Emacs's `emacs-version` (`emacs.c:3594'): the release
      ;; string the build reports.
      ;;--------------------------------------------------------------
      "31.1")

    (define emacs-major-version
      ;; GNU Emacs's `emacs-major-version` (`version.el:57'): "Major
      ;; version number of Emacs, as an integer." The C is
      ;; `(string-to-number (match-string 0 (string-match "^[0-9]+"
      ;; emacs-version)))'.
      ;;--------------------------------------------------------------
      (let ((dot (string-contains emacs-version ".")))
        (string->number (substring emacs-version 0 dot))))

    (define emacs-minor-version
      ;; GNU Emacs's `emacs-minor-version` (`version.el:63'): "Minor
      ;; version number of Emacs, as an integer." The C's regexp is
      ;; "^[0-9]+\\.\\([0-9]+\\)".
      ;;--------------------------------------------------------------
      (let* ((dot (string-contains emacs-version "."))
             (rest (substring emacs-version (+ dot 1)))
             (dot2 (string-contains rest ".")))
        (string->number (if dot2 (substring rest 0 dot2) rest))))))
