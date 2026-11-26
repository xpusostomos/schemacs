;; The schemacs side of the character-class differential; see
;; emacs-classes.el and README.md.
(import (scheme base) (scheme write) (scheme file)
        (only (schemacs buffer) *case-fold-search*)
        (schemacs search))
(define classes '("alnum" "alpha" "blank" "cntrl" "digit" "graph"
                  "lower" "print" "punct" "space" "upper" "xdigit"
                  "ascii" "nonascii" "unibyte" "multibyte" "word"))
(define (chars)
  (call-with-input-file "chars.txt"
    (lambda (p)
      (let loop ((acc '()))
        (let ((line (read-line p)))
          (if (eof-object? line)
              (reverse acc)
              (loop (cons (string->number line) acc))))))))
(for-each
 (lambda (cp)
   (let ((s (string (integer->char cp))))
     (for-each
      (lambda (fold)
        (parameterize ((*case-fold-search* fold))
          (for-each
           (lambda (name)
             (let ((re (string-append "[[" ":" name ":" "]]")))
               (display cp) (display " ")
               (display (if fold "fold" "nofold")) (display " ")
               (display name) (display " ")
               (display (if (string-match re s) 1 0))
               (newline)))
           classes)))
      (list #t #f))))
 (chars))
