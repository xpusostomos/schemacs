;;; gen-standard-syntax-runs.el --- emit `characters.scm''s syntax runs  -*- lexical-binding: t; -*-
;;
;; The syntax half of `lisp/international/characters.el', as data: the
;; runs of code points above ASCII whose syntax in the *standard* syntax
;; table is not `word'. `syntax.scm''s `%standard-syntax-table' applies
;; them; without them every character above ASCII is `word', which is
;; what `init_syntax_once' gives and what `characters.el' then walks the
;; Unicode blocks to correct.
;;
;;     emacs -Q --batch --load tools/gen-standard-syntax-runs.el \
;;       2>/dev/null > /tmp/runs.scm
;;
;; and paste the output into `standard-syntax-runs' in
;; `schemacs/editor/characters.scm'. The classes are `space', `dot',
;; `underscore', `open' and `close'; an open or close carries the
;; matching bracket's code point as a fourth element.

(with-temp-buffer
  (let ((table (standard-syntax-table))
        (out '()) (c 128) (start 128) (cur nil))
    (set-syntax-table table)
    (while (<= c #x10FFFF)
      (let* ((ch (decode-char 'ucs c))
             (s (if ch (char-syntax ch) ?w)))
        (if (null cur)
            (setq cur s start c)
          (unless (eq s cur)
            (push (list start (1- c) cur) out)
            (setq start c cur s))))
      (setq c (1+ c)))
    (push (list start #x10FFFF cur) out)
    (setq out (nreverse out))
    (dolist (r out)
      (unless (eq (nth 2 r) ?w)
        (let* ((a (nth 0 r)) (b (nth 1 r)) (s (nth 2 r))
               (lit (cond ((eq s ?\s) "space") ((eq s ?.) "dot")
                          ((eq s ?_) "underscore") ((eq s ?\() "open")
                          ((eq s ?\)) "close") (t nil)))
               (pair (when (memq s '(?\( ?\)))
                       (let ((ch (decode-char 'ucs a)))
                         (when ch (matching-paren ch))))))
          (princ (format "      (#x%x #x%x %s%s)\n" a b lit
                         (if pair (format " #x%x" pair) ""))))))))
