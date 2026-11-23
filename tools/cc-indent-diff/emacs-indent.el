;; The Emacs side of the indentation differential. Usage:
;;   emacs -Q --batch -l emacs-indent.el STYLE FILE
;; Prints (POSITION COLUMN) at every line start: the syntactic analysis
;; `c-guess-basic-syntax' followed by `c-get-syntactic-indentation',
;; with `c-syntactic-context' bound the way `c-indent-line' binds it.
(require 'cc-mode)
(let* ((style (car command-line-args-left))
       (file (cadr command-line-args-left)))
  (find-file file)
  (c-set-style style)
  (goto-char (point-min))
  (while (< (point) (point-max))
    (let ((pos (progn (beginning-of-line) (point))))
      (condition-case _e
          (let* ((syntax (c-guess-basic-syntax))
                 (column (let ((c-syntactic-context syntax))
                           (c-get-syntactic-indentation syntax))))
            (prin1 (list pos column)))
        (error (prin1 (list pos 'error))))
      (terpri))
    (forward-line 1)))
