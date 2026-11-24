;; The schemacs side of the cc-cmds statement-movement differential.
;; Usage:
;;   guile --no-auto-compile -L . -L "$SITE" -s ours-stmt.scm FILE OUT [cpp]
;; Same probes as emacs-stmt.el; the mode replay is ours-defuns.scm's.
(import (scheme base) (scheme write)
        (only (guile) open-output-string get-output-string)
        (only (schemacs buffer) allocate-buffer set-buffer
              set-buffer-local-value!)
        (only (schemacs editfns) insert point-min point-max goto-char point
              save-excursion bobp eobp)
        (only (schemacs syntax) set-syntax-table)
        (only (schemacs progmodes cc-defs)
              c-lang-const *c-buffer-is-cc-mode*)
        (only (schemacs progmodes cc-vars) *c-default-style*
              c-make-macro-with-semi-re c-make-noise-macro-regexps)
        (only (schemacs progmodes cc-styles)
              c-set-style c-setup-paragraph-variables cc-choose-style-for-mode)
        (only (schemacs progmodes cc-engine)
              c-clear-found-types c-restore-<>-properties
              c-new-BEG set!c-new-BEG c-new-END set!c-new-END
              c-literal-limits c-literal-type c-beginning-of-macro
              c-end-of-macro)
        (only (schemacs progmodes cc-cmds)
              c-beginning-of-statement c-end-of-statement
              c-back-over-illiterals c-forward-over-illiterals
              c-ascertain-preceding-literal c-ascertain-following-literal
              c-after-statement-terminator-p c-one-line-string-p
              c-beginning-of-sentence-in-comment
              c-end-of-sentence-in-comment
              c-beginning-of-sentence-in-string c-end-of-sentence-in-string
              c-comment-indent c-outline-level c-in-comment-line-prefix-p
              c-scan-conditionals))
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
       ((null? l)
        (string-append "(" (join (reverse acc)) ")"))
       ((eq? l #f)
        (string-append "(" (join (reverse acc)) ")"))
       (else
        (string-append "(" (join (reverse acc)) " . " (sw l) ")")))))
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
    (set-buffer-local-value! b 'c-block-comment-flag #t)
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
      (c-make-macro-with-semi-re)
      (when cpp?
        (set!c-new-BEG (point-min))
        (set!c-new-END (point-max))
        (c-restore-<>-properties (point-min) (point-max) 0)))
    b))

(define (mv pos thunk)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (save-excursion
      (goto-char pos)
      (let ((ret (probe thunk)))
        (list (point) ret)))))

(define (lit-probe pos pred thunk)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (save-excursion
      (goto-char pos)
      (let ((range (probe (lambda () (c-literal-limits)))))
        (if (and (pair? range) (pred (c-literal-type range)))
            (let ((ret (probe (lambda () (thunk range)))))
              (list (point) ret))
            #f)))))

(let ((p (open-output-file out)))
  (let loop ((pos 1) (end (string-length text)))
    (when (<= pos end)
      (fresh-buffer)
      (let* ((mp (parameterize ((*c-buffer-is-cc-mode* mode))
                   (save-excursion
                     (goto-char pos)
                     (probe (lambda ()
                              (and (not (bobp)) (c-beginning-of-macro)
                                   (point)))))))
             (me (parameterize ((*c-buffer-is-cc-mode* mode))
                   (save-excursion
                     (goto-char pos)
                     (probe (lambda ()
                              (and (not (eobp)) (c-beginning-of-macro)
                                   (begin (c-end-of-macro) (point))))))))
             (bos1 (mv pos (lambda () (c-beginning-of-statement 1 #f #f))))
             (bosS (mv pos (lambda () (c-beginning-of-statement 1 #f #t))))
             (eos1 (mv pos (lambda () (c-end-of-statement 1 #f #f))))
             (eosS (mv pos (lambda () (c-end-of-statement 1 #f #t))))
             (back (mv pos (lambda () (c-back-over-illiterals mp))))
             (fwd (mv pos (lambda () (c-forward-over-illiterals me #f))))
             (fwde (mv pos (lambda () (c-forward-over-illiterals me #t))))
             (prec (mv pos (lambda () (c-ascertain-preceding-literal))))
             (foll (mv pos (lambda () (c-ascertain-following-literal))))
             (term (mv pos (lambda () (c-after-statement-terminator-p))))
             (oneline (lit-probe pos (lambda (t) #t)
                                 (lambda (r) (c-one-line-string-p r))))
             (sencb (lit-probe pos (lambda (t) (memq t '(c c++)))
                               (lambda (r) (c-beginning-of-sentence-in-comment r))))
             (sence (lit-probe pos (lambda (t) (memq t '(c c++)))
                               (lambda (r) (c-end-of-sentence-in-comment r))))
             (sensb (lit-probe pos (lambda (t) (eq? t 'string))
                               (lambda (r) (c-beginning-of-sentence-in-string r))))
             (sense (lit-probe pos (lambda (t) (eq? t 'string))
                               (lambda (r) (c-end-of-sentence-in-string r))))
             (cind (mv pos (lambda () (c-comment-indent))))
             (outline (mv pos (lambda () (c-outline-level))))
             (clp (mv pos (lambda () (c-in-comment-line-prefix-p))))
             (scan1 (probe (lambda () (c-scan-conditionals 1))))
             (scanm1 (probe (lambda () (c-scan-conditionals -1))))
             (scan1d (probe (lambda () (c-scan-conditionals 1 -1))))
             (scan1e (probe (lambda () (c-scan-conditionals 1 #f #t)))))
        (display (string-append
                  (number->string pos)
                  " | bos1=" (sw bos1)
                  " bosS=" (sw bosS)
                  " eos1=" (sw eos1)
                  " eosS=" (sw eosS)
                  " back=" (sw back)
                  " fwd=" (sw fwd)
                  " fwde=" (sw fwde)
                  " prec=" (sw prec)
                  " foll=" (sw foll)
                  " term=" (sw term)
                  " oneline=" (sw oneline)
                  " sencb=" (sw sencb)
                  " sence=" (sw sence)
                  " sensb=" (sw sensb)
                  " sense=" (sw sense)
                  " cind=" (sw cind)
                  " outline=" (sw outline)
                  " clp=" (sw clp)
                  " scan1=" (sw scan1)
                  " scanm1=" (sw scanm1)
                  " scan1d=" (sw scan1d)
                  " scan1e=" (sw scan1e)
                  "\n")
                 p))
      (loop (+ pos 1) end)))
  (close-output-port p))
