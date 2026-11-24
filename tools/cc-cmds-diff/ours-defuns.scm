;; The schemacs side of the cc-cmds defun-movement differential. Usage:
;;   guile --no-auto-compile -L . -L "$SITE" -s ours-defuns.scm FILE OUT [cpp]
;; For every position of FILE, record the same answers as
;; emacs-defuns.el. Each position gets a fresh buffer, and the mode's
;; setup is the replay c-basic-common-init will do once cc-mode.el is
;; ported (the harnesses for the other cc tranches use the same one).
(import (scheme base) (scheme write)
        (only (guile) open-output-string get-output-string)
        (only (schemacs buffer) allocate-buffer set-buffer
              set-buffer-local-value!)
        (only (schemacs editfns) insert point-min point-max goto-char point
              save-excursion buffer-substring-no-properties)
        (only (schemacs syntax) set-syntax-table)
        (only (schemacs progmodes cc-defs)
              c-lang-const *c-buffer-is-cc-mode*)
        (only (schemacs progmodes cc-vars) *c-default-style*
              c-make-macro-with-semi-re c-make-noise-macro-regexps)
        (only (schemacs progmodes cc-styles)
              c-set-style c-setup-paragraph-variables cc-choose-style-for-mode)
        (only (schemacs progmodes cc-engine)
              c-clear-found-types c-restore-<>-properties
              c-new-BEG set!c-new-BEG c-new-END set!c-new-END)
        (only (schemacs progmodes cc-cmds)
              c-where-wrt-brace-construct c-in-function-trailer-p
              c-defun-name c-cpp-define-name c-declaration-limits
              c-defun-name-and-limits c-beginning-of-defun c-end-of-defun
              c-indent-defun))
(import (schemacs progmodes cc-langs))
;; `c-gnu-impose-minimum' (the gnu style's special-indent hook) is
;; cc-align's, and a real c-mode has it loaded; without it labels
;; stay at column 0 where Emacs moves them to 1.
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

(define (oneline str)
  ;; Both sides write a newline as `|'; see emacs-defuns.el.
  (let loop ((cs (string->list str)) (acc '()))
    (if (null? cs)
        (list->string (reverse acc))
        (loop (cdr cs)
              (cons (if (char=? (car cs) #\newline) #\| (car cs)) acc)))))

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
      (c-make-macro-with-semi-re)
      (when cpp?
        (set!c-new-BEG (point-min))
        (set!c-new-END (point-max))
        (c-restore-<>-properties (point-min) (point-max) 0)))
    b))

(define (here pos thunk)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (save-excursion
      (goto-char pos)
      (probe thunk))))

(define (move pos thunk)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (save-excursion
      (goto-char pos)
      (let ((ret (probe thunk)))
        (cons (point) ret)))))

(let ((p (open-output-file out)))
  (let loop ((pos 1) (end (string-length text)))
    (when (<= pos end)
      (fresh-buffer)
      (let ((where (here pos (lambda () (c-where-wrt-brace-construct))))
            (trailer (here pos (lambda () (c-in-function-trailer-p))))
            (dname (here pos (lambda () (c-defun-name))))
            (cppname (here pos (lambda () (c-cpp-define-name))))
            (limits (here pos (lambda () (c-declaration-limits #f))))
            (limitsn (here pos (lambda () (c-declaration-limits #t))))
            (dandl (here pos (lambda () (c-defun-name-and-limits #f))))
            (dbeg (move pos (lambda () (c-beginning-of-defun))))
            (dend (move pos (lambda () (c-end-of-defun))))
            ;; See emacs-defuns.el: a fresh buffer, because
            ;; `c-indent-defun' edits and the change hooks that
            ;; invalidate cc's caches arrive with cc-mode.el.
            (idf (begin
                   (fresh-buffer)
                   (parameterize ((*c-buffer-is-cc-mode* mode))
                     (goto-char pos)
                     (probe (lambda ()
                              (c-indent-defun)
                              (oneline
                               (buffer-substring-no-properties
                                (point-min) (point-max)))))))))
        (display (string-append
                  (number->string pos)
                  " | where=" (sw where)
                  " trailer=" (sw trailer)
                  " name=" (sw dname)
                  " cpp=" (sw cppname)
                  " limits=" (sw limits)
                  " limitsn=" (sw limitsn)
                  " dandl=" (sw dandl)
                  " dbeg=" (sw dbeg)
                  " dend=" (sw dend)
                  " idf=" (sw idf)
                  "\n")
                 p))
      (loop (+ pos 1) end)))
  (close-output-port p))
