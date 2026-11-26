;; The schemacs side of the cc-cmds filling differential. Usage:
;;   guile --no-auto-compile -L . -L "$SITE" -s ours-fill.scm FILE OUT [cpp]
;; Same probes as emacs-fill.el; the mode replay is ours-stmt.scm's plus
;; the two per-mode settings Emacs's c-mode makes: `comment-multi-line'
;; t and `fill-paragraph-function' c-fill-paragraph.
(import (scheme base) (scheme write)
        (only (guile) open-output-string get-output-string)
        (only (schemacs buffer) allocate-buffer set-buffer
              set-buffer-local-value! current-buffer)
        (only (schemacs editfns) insert point-min point-max goto-char point
              save-excursion buffer-substring-no-properties)
        (only (schemacs syntax) set-syntax-table)
        (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*)
        (only (schemacs progmodes cc-vars) *c-default-style*
              c-make-macro-with-semi-re c-make-noise-macro-regexps)
        (only (schemacs progmodes cc-styles)
              c-set-style c-setup-paragraph-variables cc-choose-style-for-mode)
        (only (schemacs insdel) *before-change-functions*
              *after-change-functions*)
        (only (schemacs progmodes cc-mode) c-before-change c-after-change)
        (only (schemacs progmodes cc-engine)
              c-clear-found-types c-literal-limits c-literal-type
              c-collect-line-comments c-restore-<>-properties
              set!c-new-BEG set!c-new-END)
        (only (schemacs newcomment) *comment-multi-line*)
        (only (schemacs textmodes fill) *fill-paragraph-function*)
        (only (schemacs progmodes cc-cmds)
              c-fill-paragraph c-indent-new-comment-line
              c-context-line-break c-context-open-line c-indent-line))
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

(define (oneline s)
  (list->string (map (lambda (c) (if (char=? c #\newline) #\| c))
                     (string->list s))))

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
    (set-buffer-local-value! b 'indent-line-function c-indent-line)
    (set-buffer-local-value! b 'c-block-comment-flag #t)
    b))

(define (run pos thunk)
  (fresh-buffer)
  ;; `(funcall mode)' on the Emacs side runs `c-common-init', which
  ;; installs the two change hooks and (for C++) the `<>' properties;
  ;; without them a command that edits twice sees stale caches and the
  ;; multi-line `#define' transient comes out differently.
  (parameterize ((*c-buffer-is-cc-mode* mode)
                 (*comment-multi-line* #t)
                 (*fill-paragraph-function* c-fill-paragraph)
                 (*before-change-functions*
                  (cons c-before-change (*before-change-functions*)))
                 (*after-change-functions*
                  (cons c-after-change (*after-change-functions*))))
    (goto-char pos)
    (let ((ret (probe thunk)))
      (list (point) ret (oneline (buffer-substring-no-properties
                                  (point-min) (point-max)))))))

(let ((p (open-output-file out)))
  (let loop ((pos 1) (end (string-length text)))
    (when (<= pos end)
      (let ((fill (run pos (lambda () (c-fill-paragraph #f))))
            (incl (run pos (lambda () (c-indent-new-comment-line))))
            (clb (run pos (lambda () (c-context-line-break))))
            (col (run pos (lambda () (c-context-open-line)))))
        (display (string-append
                  (number->string pos)
                  " | fill=" (sw fill)
                  " incl=" (sw incl)
                  " clb=" (sw clb)
                  " col=" (sw col)
                  "\n")
                 p))
      (loop (+ pos 1) end)))
  (close-output-port p))
