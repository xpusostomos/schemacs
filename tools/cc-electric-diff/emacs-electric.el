;;; Differential harness: run each scenario's electric command in a real
;;; Emacs c-mode/c++-mode buffer and print the resulting text and point.
;;; Usage: emacs -Q --batch -l emacs-electric.el -- scenarios.tsv
(require 'cc-mode)

(defun ee-decode (s)
  (let ((out "") (i 0) (n (length s)))
    (while (< i n)
      (let ((c (aref s i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) n))
          (let ((d (aref s (1+ i))))
            (setq out (concat out
                              (cond ((eq d ?n) "\n")
                                    ((eq d ?t) "\t")
                                    ((eq d ?\\) "\\")
                                    (t (char-to-string d)))))
            (setq i (+ i 2))))
         (t (setq out (concat out (char-to-string c)))
            (setq i (1+ i))))))
    out))

(defun ee-encode (s)
  (let ((out ""))
    (dotimes (i (length s))
      (let ((c (aref s i)))
        (setq out (concat out
                          (cond ((eq c ?\n) "\\n")
                                ((eq c ?\t) "\\t")
                                ((eq c ?\\) "\\\\")
                                (t (char-to-string c)))))))
    out))

(defun ee-rows (file)
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (unless (string= line "")
            (push (split-string line "\t" nil) rows)))
        (forward-line 1))
      (nreverse rows))))

(defun ee-run (row)
  (let* ((name (nth 0 row))
         (lang (nth 1 row))
         (cmd (intern (nth 2 row)))
         (key (string-to-number (nth 3 row)))
         (arg (nth 4 row))
         (auto (string-to-number (nth 5 row)))
         (hungry (string-to-number (nth 6 row)))
         (elec (string-to-number (nth 7 row)))
         (syn (string-to-number (nth 8 row)))
         (point-spec (nth 9 row))
         (cleanups (nth 10 row))
         (text (ee-decode (nth 11 row))))
    (with-temp-buffer
      (insert text)
      (if (string= lang "cpp") (c++-mode) (c-mode))
      (setq c-auto-newline (not (zerop auto)))
      (setq c-hungry-delete-key (not (zerop hungry)))
      (setq c-electric-flag (not (zerop elec)))
      (setq c-syntactic-indentation (not (zerop syn)))
      (unless (string= cleanups "default")
        (setq c-cleanup-list
              (mapcar #'intern (split-string cleanups ","))))
      (when (eq cmd 'c-electric-pound)
        (setq c-electric-pound-behavior '(alignleft)))
      (goto-char (if (string= point-spec "end")
                     (point-max)
                     (string-to-number point-spec)))
      (let ((last-command-event key))
        (cond ((string= arg "none") (funcall cmd))
              ((string= arg "nil") (funcall cmd nil))
              (t (funcall cmd (string-to-number arg)))))
      (princ (format "%s\t%s\t%d\n"
                     name (ee-encode (buffer-string)) (point))))))

(dolist (row (ee-rows (car (last command-line-args-left))))
  (ee-run row))
