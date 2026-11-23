(require 'easymenu)
(defun pr (x)
  (cond ((null x) (princ "nil"))
        ((eq x t) (princ "t"))
        ((symbolp x) (princ (symbol-name x)))
        ((numberp x) (princ (number-to-string x)))
        ((stringp x) (prin1 x))
        ((vectorp x) (princ "[") (dotimes (i (length x)) (if (> i 0) (princ " ")) (pr x (aref x i))) (princ "]"))
        ((consp x) (princ "(") (pr (car x))
         (setq x (cdr x))
         (while (consp x) (princ " ") (pr (car x)) (setq x (cdr x)))
         (when x (princ " . ") (pr x))
         (princ ")"))
        (t (princ "proc"))))
(defconst specs
  (list ["Simple" simple-cmd t]
        ["Keys" my-cmd :keys "C-c k"]
        ["Active" my-cmd :active (list 'fboundp 'x)]
        ["Visible" my-cmd :visible nil]
        ["Visible2" my-cmd :visible t]
        ["Toggle" my-cmd :style toggle :selected my-var]
        ["Radio" my-cmd :style radio :selected my-var]
        ["Button" my-cmd :style button]
        ["Label" my-cmd :label "Shown"]
        ["Suffix" my-cmd :suffix "!"]
        ["Suffix2" my-cmd :suffix my-suffix-var]
        ["Help" my-cmd :help "help text"]
        ["Cache" my-cmd :key-sequence "C-c c"]
        "---"
        "Plain string"
        ["KeysMarked" my-cmd :keys "C-c \\[next-line]"]
        ["Active2" my-cmd :active my-flag]
        ["LabelForm" my-cmd :label (list 'my-label)]))
(dolist (spec specs)
  (condition-case e
      (progn (pr (easy-menu-convert-item spec)) (terpri))
    (error (princ "error") (terpri))))
;; always-true
(dolist (x '(t nil foo (quote x) (quote (a)) 5 "s"))
  (pr (easy-menu-always-true-p x)) (terpri))
;; name match: item is (KEY . BINDING) as the alist walk sees it
(dolist (name '("Label" Label (quote Label) (quote Nothing)))
  (pr (easy-menu-name-match name (cons 'labelkey '("Label" . def)))) (terpri))
