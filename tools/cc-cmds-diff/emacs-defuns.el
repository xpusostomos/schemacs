;; The Emacs side of the cc-cmds defun-movement differential. Usage:
;;   emacs -Q --batch -l emacs-defuns.el FILE OUT [cpp]
;; For every position of FILE (in c-mode, or c++-mode with the third
;; argument "cpp"), record the answers of the defun-movement functions
;; added to cc-cmds.scm's port. Each position gets a fresh buffer, so
;; the mode's caches start empty as they do in `cc-cmds-tests.scm'.
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
    (defun oneline (str)
      ;; `%S' prints a newline in a string literally, which would break
      ;; the one-record-per-position format; both sides write `|'.
      (mapconcat (lambda (c) (if (eq c ?\n) "|" (char-to-string c)))
                 (string-to-list str) ""))
    (defun probe (thunk)
      (condition-case nil
          (funcall thunk)
        (error 'error)))
    (defun here (pos thunk)
      (save-excursion
        (goto-char pos)
        (probe thunk)))
    (defun move (pos thunk)
      (save-excursion
        (goto-char pos)
        (let ((ret (probe thunk)))
          (cons (point) ret))))
    (let ((pos 1))
      (while (<= pos (length text))
        (with-temp-buffer
          (insert text)
          (fundamental-mode)
          (funcall mode)
          (let ((where (here pos (lambda () (c-where-wrt-brace-construct))))
                (trailer (here pos (lambda () (c-in-function-trailer-p))))
                (dname (here pos (lambda () (c-defun-name))))
                (cppname (here pos (lambda () (c-cpp-define-name))))
                (limits (here pos (lambda () (c-declaration-limits nil))))
                (limitsn (here pos (lambda () (c-declaration-limits t))))
                (dandl (here pos (lambda () (c-defun-name-and-limits nil))))
                (dbeg (move pos (lambda () (c-beginning-of-defun))))
                (dend (move pos (lambda () (c-end-of-defun))))
                ;; `c-indent-defun' edits, and the read-only probes
                ;; above leave text properties cc caches in; in Emacs the
                ;; mode's change functions invalidate them, and this tree
                ;; installs those only when cc-mode.el lands. So this one
                ;; probe gets its own fresh buffer, as a command would.
                (idf (with-temp-buffer
                       (insert text)
                       (fundamental-mode)
                       (funcall mode)
                       (goto-char pos)
                       (probe (lambda ()
                                (c-indent-defun)
                                (oneline
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))))))
            (push (format "%d | where=%S trailer=%S name=%S cpp=%S limits=%S limitsn=%S dandl=%S dbeg=%S dend=%S idf=%S"
                          pos where trailer dname cppname limits limitsn
                          dandl dbeg dend idf)
                  res)))
        (setq pos (1+ pos))))
    (with-temp-file out
      (dolist (line (nreverse res))
        (insert line)
        (newline)))))
