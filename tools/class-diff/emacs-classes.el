;; The Emacs side of the character-class differential. Run it, then
;; run ours-classes.scm, and `diff' the two outputs; README.md has the
;; commands. Every character is a multibyte string, so the matcher
;; takes the C's class branch for everything without a byte
;; representation, which is what a buffer's text does.
(let ((classes '("alnum" "alpha" "blank" "cntrl" "digit" "graph"
                 "lower" "print" "punct" "space" "upper" "xdigit"
                 "ascii" "nonascii" "unibyte" "multibyte" "word"))
      (chars (with-temp-buffer
               (insert-file-contents
                (expand-file-name "chars.txt"
                                  (file-name-directory
                                   (or load-file-name buffer-file-name))))
               (split-string (buffer-string) "\n" t))))
  ;; A fundamental-mode buffer, because `string-match' reads the
  ;; *current buffer's* syntax table for `[[:space:]]', `[[:word:]]'
  ;; and `[[:punct:]]' - and `*scratch*' runs lisp-interaction-mode,
  ;; whose newline is a comment ender rather than whitespace. The
  ;; schemacs side has no current buffer and falls back to its
  ;; standard table, which is what a fresh buffer has.
  (with-temp-buffer
    (dolist (cp (mapcar #'string-to-number chars))
      (let ((s (string cp)))
        (dolist (fold '(t nil))
          (let ((case-fold-search fold))
            (dolist (name classes)
              (princ (format "%d %s %s %d\n"
                             cp (if fold "fold" "nofold") name
                             (if (string-match-p
                                  (format "[[:%s:]]" name) s)
                                 1 0))))))))))
