;; The Emacs side of the cc-cmds indentation differential. Usage:
;;   emacs -Q --batch -l emacs-cmds.el STYLE FILE OUT [cpp]
;; Opens FILE, turns on c-mode (or c++-mode), sets STYLE, runs
;; `c-indent-region' over the whole buffer, and writes the result to OUT.
(let* ((args command-line-args-left)
       (style (nth 0 args))
       (file (nth 1 args))
       (out (nth 2 args))
       (cpp (nth 3 args)))
  (setq command-line-args-left nil)
  (find-file file)
  (fundamental-mode)
  (funcall (if (equal cpp "cpp") 'c++-mode 'c-mode))
  (c-set-style style)
  (goto-char (point-min))
  (c-indent-region (point-min) (point-max))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (with-temp-file out (insert text)))
  (kill-emacs 0))
