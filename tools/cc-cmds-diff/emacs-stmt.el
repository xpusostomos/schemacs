;; The Emacs side of the cc-cmds statement-movement differential. Usage:
;;   emacs -Q --batch -l emacs-stmt.el FILE OUT [cpp]
;; At every position of FILE (c-mode, or c++-mode with "cpp"), record the
;; answers of the statement, sentence, comment-indent and conditional
;; functions added to cc-cmds.scm. The read-only probes share one buffer
;; per position, as they do in Emacs; each record is one line.
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
    (defun mv (pos thunk)
      (save-excursion
        (goto-char pos)
        (let ((ret (probe thunk)))
          (list (point) ret))))
    (defun lit-probe (pos pred thunk)
      (save-excursion
        (goto-char pos)
        (let ((range (probe (lambda () (c-literal-limits)))))
          (when (and (consp range) (funcall pred (c-literal-type range)))
            (let ((ret (probe (lambda () (funcall thunk range)))))
              (list (point) ret))))))
    (let ((pos 1))
      (while (<= pos (length text))
        (with-temp-buffer
          (insert text)
          (fundamental-mode)
          (funcall mode)
          (let* ((mp (save-excursion
                       (goto-char pos)
                       (probe (lambda ()
                                (and (not (bobp)) (c-beginning-of-macro)
                                     (point))))))
                 (me (save-excursion
                       (goto-char pos)
                       (probe (lambda ()
                                (and (not (eobp)) (c-beginning-of-macro)
                                     (progn (c-end-of-macro) (point)))))))
                 (bos1 (mv pos (lambda () (c-beginning-of-statement 1 nil nil))))
                 (bosS (mv pos (lambda () (c-beginning-of-statement 1 nil t))))
                 (eos1 (mv pos (lambda () (c-end-of-statement 1 nil nil))))
                 (eosS (mv pos (lambda () (c-end-of-statement 1 nil t))))
                 (back (mv pos (lambda () (c-back-over-illiterals mp))))
                 (fwd (mv pos (lambda () (c-forward-over-illiterals me nil))))
                 (fwde (mv pos (lambda () (c-forward-over-illiterals me t))))
                 (prec (mv pos (lambda () (c-ascertain-preceding-literal))))
                 (foll (mv pos (lambda () (c-ascertain-following-literal))))
                 (term (mv pos (lambda () (c-after-statement-terminator-p))))
                 (oneline (lit-probe pos (lambda (type) t)
                                     (lambda (r) (c-one-line-string-p r))))
                 (sencb (lit-probe pos (lambda (type) (memq type '(c c++)))
                                   (lambda (r) (c-beginning-of-sentence-in-comment r))))
                 (sence (lit-probe pos (lambda (type) (memq type '(c c++)))
                                   (lambda (r) (c-end-of-sentence-in-comment r))))
                 (sensb (lit-probe pos (lambda (type) (eq type 'string))
                                   (lambda (r) (c-beginning-of-sentence-in-string r))))
                 (sense (lit-probe pos (lambda (type) (eq type 'string))
                                   (lambda (r) (c-end-of-sentence-in-string r))))
                 (cind (mv pos (lambda () (c-comment-indent))))
                 (outline (mv pos (lambda () (c-outline-level))))
                 (clp (mv pos (lambda () (c-in-comment-line-prefix-p))))
                 (scan1 (probe (lambda () (c-scan-conditionals 1))))
                 (scanm1 (probe (lambda () (c-scan-conditionals -1))))
                 (scan1d (probe (lambda () (c-scan-conditionals 1 -1))))
                 (scan1e (probe (lambda () (c-scan-conditionals 1 nil t)))))
            (push (format "%d | bos1=%S bosS=%S eos1=%S eosS=%S back=%S fwd=%S fwde=%S prec=%S foll=%S term=%S oneline=%S sencb=%S sence=%S sensb=%S sense=%S cind=%S outline=%S clp=%S scan1=%S scanm1=%S scan1d=%S scan1e=%S"
                          pos bos1 bosS eos1 eosS back fwd fwde prec foll term
                          oneline sencb sence sensb sense cind outline clp
                          scan1 scanm1 scan1d scan1e)
                  res)))
        (setq pos (1+ pos))))
    (with-temp-file out
      (dolist (line (nreverse res))
        (insert line)
        (newline)))))
