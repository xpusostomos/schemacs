;; The Emacs side of the cc-cmds filling differential. Usage:
;;   emacs -Q --batch -l emacs-fill.el FILE OUT [cpp]
;; At every position of FILE (c-mode, or c++-mode with "cpp"), run each
;; of c-fill-paragraph, c-indent-new-comment-line, c-context-line-break
;; and c-context-open-line in its own fresh buffer, and record the
;; resulting text (newlines shown as |) and point. One line per
;; position; a probe that signals records "error".
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
    (defun oneline (s) (subst-char-in-string ?\n ?| s))
    (defun run (pos fun)
      (with-temp-buffer
        (insert text)
        (fundamental-mode)
        (funcall mode)
        (goto-char pos)
        (let ((ret (probe fun)))
          (list (point) ret (oneline (buffer-substring-no-properties
                                      (point-min) (point-max)))))))
    (let ((pos 1))
      (while (<= pos (length text))
        (let ((fill (run pos (lambda () (c-fill-paragraph))))
              (incl (run pos (lambda () (c-indent-new-comment-line))))
              (clb (run pos (lambda () (c-context-line-break))))
              (col (run pos (lambda () (c-context-open-line)))))
          (push (format "%d | fill=%S incl=%S clb=%S col=%S"
                        pos fill incl clb col)
                res))
        (setq pos (1+ pos)))
      (with-temp-file out
        (dolist (line (nreverse res))
          (insert line)
          (newline))))))
