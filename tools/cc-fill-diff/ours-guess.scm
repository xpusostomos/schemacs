;; The schemacs side of the c-guess-fill-prefix differential. Usage:
;;   guile --no-auto-compile -L . -L "$SITE" -s ours-guess.scm FILE OUT [cpp]
;; Same probes as emacs-guess.el; the mode replay is ours-stmt.scm's.
(import (scheme base) (scheme write)
        (only (guile) open-output-string get-output-string)
        (only (schemacs buffer) allocate-buffer set-buffer
              set-buffer-local-value! current-buffer call-with-buffer-local)
        (only (schemacs editfns) insert point-min point-max goto-char point
              save-excursion)
        (only (schemacs syntax) set-syntax-table)
        (only (schemacs indent) *fill-prefix*)
        (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*)
        (only (schemacs progmodes cc-vars) *c-default-style*
              c-make-macro-with-semi-re c-make-noise-macro-regexps)
        (only (schemacs progmodes cc-styles)
              c-set-style c-setup-paragraph-variables cc-choose-style-for-mode)
        (only (schemacs progmodes cc-engine)
              c-clear-found-types c-literal-limits c-literal-type)
        (only (schemacs progmodes cc-cmds) c-guess-fill-prefix c-indent-line))
(import (schemacs progmodes cc-langs))
(import (schemacs progmodes cc-align))

(define args (cdr (command-line)))
(define file (car args))
(define out (cadr args))
(define cpp? (and (pair? (cddr args)) (string=? (caddr args) "cpp")))
(define mode (if cpp? 'c++-mode 'c-mode))

(define (read-file-text file)
  (call-with-input-file file
    (lambda (p)
      (let loop ((cs '()))
        (let ((c (read-char p)))
          (if (eof-object? c)
              (list->string (reverse cs))
              (loop (cons c cs))))))))
(define text (read-file-text file))

(define (sw x)
  (cond
   ((eq? x #f) "nil")
   ((eq? x #t) "t")
   ((null? x) "nil")
   ((pair? x)
    (let loop ((l x) (acc '()))
      (cond
       ((pair? l) (loop (cdr l) (cons (sw (car l)) acc)))
       ((null? l) (string-append "(" (join (reverse acc)) ")"))
       ((eq? l #f) (string-append "(" (join (reverse acc)) ")"))
       (else (string-append "(" (join (reverse acc)) " . " (sw l) ")")))))
   (else
    (let ((s (open-output-string)))
      (write x s)
      (get-output-string s)))))

(define (join lst)
  (if (null? lst)
      ""
      (let loop ((l (cdr lst)) (acc (car lst)))
        (if (null? l)
            acc
            (loop (cdr l) (string-append acc " " (car l)))))))

(define (probe thunk)
  (guard (e (else 'error)) (thunk)))

(define (fresh-buffer)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (parameterize ((*c-buffer-is-cc-mode* mode))
      (if cpp? (c-init-language-vars c++-mode) (c-init-language-vars c-mode))
      (set-syntax-table
       (if cpp?
           ((c-lang-const c-make-mode-syntax-table c++))
           ((c-lang-const c-make-mode-syntax-table c))))
      (c-set-style (cc-choose-style-for-mode mode (*c-default-style*)))
      (c-setup-paragraph-variables)
      (c-clear-found-types)
      (c-make-noise-macro-regexps)
      (c-make-macro-with-semi-re))
    (set-buffer-local-value! b 'indent-line-function c-indent-line)
    (set-buffer-local-value! b 'c-block-comment-flag #t)
    b))

(define (lit-probe pos thunk)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (save-excursion
      (goto-char pos)
      (let ((range (probe (lambda () (c-literal-limits)))))
        (if (and (pair? range) (memq (c-literal-type range) '(c c++)))
            (let ((ret (probe (lambda () (thunk range)))))
              (list (point) ret))
            #f)))))

(let ((p (open-output-file out)))
  (let loop ((pos 1) (end (string-length text)))
    (when (<= pos end)
      (fresh-buffer)
      (let* ((plain (lit-probe pos (lambda (r) (c-guess-fill-prefix r (c-literal-type r)))))
             (withfill (lit-probe pos
                                  (lambda (r)
                                    (parameterize ((*fill-prefix* "> "))
                                      (c-guess-fill-prefix r (c-literal-type r))))))
             (withprefix (lit-probe pos
                                    (lambda (r)
                                      (call-with-buffer-local
                                       'c-block-comment-prefix " * "
                                       (lambda () (c-guess-fill-prefix r (c-literal-type r)))))))
             (withnone (lit-probe pos
                                  (lambda (r)
                                    (call-with-buffer-local
                                     'c-block-comment-prefix ""
                                     (lambda () (c-guess-fill-prefix r (c-literal-type r))))))))
        (when plain
          (display (string-append
                    (number->string pos)
                    " | plain=" (sw plain)
                    " withfill=" (sw withfill)
                    " withprefix=" (sw withprefix)
                    " withnone=" (sw withnone)
                    "\n")
                   p)))
      (loop (+ pos 1) end)))
  (close-output-port p))
