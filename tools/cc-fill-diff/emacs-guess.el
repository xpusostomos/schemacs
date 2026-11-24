;; The Emacs side of the c-guess-fill-prefix differential. Usage:
;;   emacs -Q --batch -l emacs-guess.el FILE OUT [cpp]
;; At every position of FILE (c-mode, or c++-mode with "cpp") that lies
;; in a comment, record c-guess-fill-prefix's answer four ways: plain,
;; with fill-prefix bound, and with c-block-comment-prefix bound to a
;; nonempty and to an empty string. Each record is one line.
(let* ((args command-line-args-left)
       (file (nth 0 args))
       (out (nth 1 args))
       (cpp (nth 2 args)))
  (setq command-line-args-left nil)
  (let* ((text (with-temp-buffer
                 (set-buffer-multibyte t)
                 (insert-file-contents file)
                 (buffer-substring-no-properties (point-min) (point-max))))
         (mode (if (equal cpp "cpp") 'c++-mode 'c-mode))
         (res nil))
    (defun probe (fun)
      (condition-case nil (funcall fun) (error 'error)))
    (defun lit-probe (pos thunk)
      (save-excursion
        (goto-char pos)
        (let ((range (probe (lambda () (c-literal-limits)))))
          (when (and (consp range) (memq (c-literal-type range) '(c c++)))
            (let ((ret (probe (lambda () (funcall thunk range)))))
              (list (point) ret))))))
    (let ((pos 1))
      (while (<= pos (length text))
        (with-temp-buffer
          (insert text)
          (fundamental-mode)
          (funcall mode)
          (let ((plain (lit-probe pos (lambda (r) (c-guess-fill-prefix r (c-literal-type r)))))
                (withfill (lit-probe pos (lambda (r) (let ((fill-prefix "> "))
                                                         (c-guess-fill-prefix r (c-literal-type r))))))
                (withprefix (lit-probe pos (lambda (r) (let ((c-block-comment-prefix " * "))
                                                           (c-guess-fill-prefix r (c-literal-type r))))))
                (withnone (lit-probe pos (lambda (r) (let ((c-block-comment-prefix ""))
                                                        (c-guess-fill-prefix r (c-literal-type r)))))))
            (when plain
              (push (format "%d | plain=%S withfill=%S withprefix=%S withnone=%S"
                            pos plain withfill withprefix withnone)
                    res))))
        (setq pos (1+ pos)))
      (with-temp-file out
        (dolist (line (nreverse res))
          (insert line)
          (newline))))))
