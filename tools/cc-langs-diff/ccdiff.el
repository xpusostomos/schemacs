;;; -*- lexical-binding: t -*-
(require 'cc-langs)

(defun ccdiff-norm (x)
  (cond
   ((null x) "(NIL)")
   ((eq x t) "(T)")
   ((stringp x)
    (concat "(S" (mapconcat (lambda (c) (format " %x" c)) (string-to-list x) "") ")"))
   ((symbolp x) (format "(Y %s)" (symbol-name x)))
   ((characterp x) (format "(I %d)" x))
   ((integerp x) (format "(I %d)" x))
   ((floatp x) (format "(F %s)" x))
   ((consp x)
    (concat "(L"
            (let ((l x) (acc ""))
              (while (consp l)
                (setq acc (concat acc " " (ccdiff-norm (car l))))
                (setq l (cdr l)))
              (concat acc (if l (concat " . " (ccdiff-norm l)) "")))
            ")"))
   ((vectorp x) (format "(VEC %d)" (length x)))
   ((char-table-p x) "(CT)")
   ((functionp x) "(FN)")
   (t "(OTHER)")))

(defvar ccdiff-langs '(c c++ objc java idl pike awk))

(with-temp-file "/tmp/emacs-vals.txt"
  (dolist (name (with-temp-buffer
                  (insert-file-contents "/tmp/ccnames.txt")
                  (split-string (buffer-string) "\n" t)))
    (let ((sym (intern name)))
      (dolist (lang ccdiff-langs)
        (insert name "\t" (symbol-name lang) "\t"
                (condition-case nil
                    (ccdiff-norm (c-get-lang-constant sym nil
                                                      (intern (concat (symbol-name lang) "-mode"))))
                  (error
                   ;; Emacs's `c-get-lang-constant' calls `makunbound'
                   ;; on the constant's symbol after an error, which
                   ;; discards the source definitions for *every*
                   ;; language; reload cc-langs to restore them.
                   (load "cc-langs")
                   "(ERR)"))
                "\n")))))
(kill-emacs 0)
