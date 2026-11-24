;;; Differential harness, schemacs side: the same scenarios, driven
;;; through the ported commands in a replayed c-mode/c++-mode buffer.
(import
 (scheme base)
 (scheme write)
 (only (schemacs buffer)
       allocate-buffer set-buffer set-buffer-local-value!)
 (only (schemacs editfns) insert point point-min point-max goto-char
       buffer-substring)
 (only (schemacs syntax) set-syntax-table)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*)
 (schemacs progmodes cc-langs)
 (only (schemacs progmodes cc-vars)
       c-syntactic-indentation set!c-syntactic-indentation
       c-cleanup-list set!c-cleanup-list
       *c-electric-pound-behavior*
       c-make-noise-macro-regexps c-make-macro-with-semi-re)
 (only (schemacs progmodes cc-styles) c-set-style)
 (only (schemacs progmodes cc-engine)
       c-clear-found-types
       c-electric-flag set!c-electric-flag
       c-auto-newline set!c-auto-newline
       c-hungry-delete-key set!c-hungry-delete-key)
 ;; **The mode's change hooks are deliberately NOT installed.** Emacs's
 ;; `c-mode' runs `c-before-change'/`c-after-change' on every edit, and
 ;; cc-mode.el is not ported; enabling them here (they are ported and
 ;; verified on their own) runs the caches through edits they have not
 ;; been exercised on yet - `c-laomib-fix-elt' raises - which is a
 ;; separate job. The electric commands are compared in isolation, as
 ;; `tools/cc-cmds-diff' compares the indentation commands.
 (schemacs progmodes cc-align)
 (only (schemacs progmodes cc-cmds)
       c-electric-brace c-electric-semi&comma c-electric-colon
       c-electric-slash c-electric-star c-electric-pound c-electric-paren
       c-electric-backspace c-hungry-delete-backwards
       c-electric-delete-forward c-hungry-delete-forward
       c-electric-continued-statement c-electric-lt-gt c-indent-line)
 (only (schemacs newcomment) set!comment-start set!comment-end)
 (only (schemacs command) *last-command-event*))

(define (decode s)
  (let ((out '()) (i 0) (n (string-length s)))
    (let loop ()
      (when (< i n)
        (let ((c (string-ref s i)))
          (cond
           ((and (char=? c #\\) (< (+ i 1) n))
            (let ((d (string-ref s (+ i 1))))
              (set! out (cons (cond ((char=? d #\n) #\newline)
                                    ((char=? d #\t) #\tab)
                                    (else d))
                              out))
              (set! i (+ i 2))))
           (else (set! out (cons c out)) (set! i (+ i 1)))))
        (loop)))
    (list->string (reverse out))))

(define (encode s)
  (let ((out '()))
    (string-for-each
     (lambda (c)
       (set! out (cons (cond ((char=? c #\newline) "\\n")
                             ((char=? c #\tab) "\\t")
                             ((char=? c #\\) "\\\\")
                             (else (string c)))
                       out)))
     s)
    (apply string-append (reverse out))))

(define (read-rows file)
  (let ((rows '()))
    (call-with-input-file file
      (lambda (p)
        (let loop ()
          (let ((line (read-line p)))
            (unless (eof-object? line)
              (unless (string=? line "")
                (set! rows (cons (string-split line #\tab) rows)))
              (loop))))))
    (reverse rows)))

(define (string-split str sep)
  ;; Keep empty fields, including the last one.
  (let ((n (string-length str)))
    (let loop ((i 0) (start 0) (out '()))
      (if (= i n)
          (reverse (cons (substring str start n) out))
          (if (char=? (string-ref str i) sep)
              (loop (+ i 1) (+ i 1) (cons (substring str start i) out))
              (loop (+ i 1) start out))))))

(define (nth n lst) (list-ref lst n))

(define commands
  `(("c-electric-brace" . ,c-electric-brace)
    ("c-electric-semi&comma" . ,c-electric-semi&comma)
    ("c-electric-colon" . ,c-electric-colon)
    ("c-electric-slash" . ,c-electric-slash)
    ("c-electric-star" . ,c-electric-star)
    ("c-electric-pound" . ,c-electric-pound)
    ("c-electric-paren" . ,c-electric-paren)
    ("c-electric-backspace" . ,c-electric-backspace)
    ("c-hungry-delete-backwards" . ,c-hungry-delete-backwards)
    ("c-electric-delete-forward" . ,c-electric-delete-forward)
    ("c-hungry-delete-forward" . ,c-hungry-delete-forward)
    ("c-electric-continued-statement" . ,c-electric-continued-statement)
    ("c-electric-lt-gt" . ,c-electric-lt-gt)))

(define (fresh text lang)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (if (string=? lang "cpp")
        (begin
          (set-buffer-local-value! b 'major-mode 'c++-mode)
          (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
          (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
            (c-init-language-vars c++-mode)
            (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
            (c-set-style "gnu")
            (c-clear-found-types)
            (c-make-noise-macro-regexps)
            (c-make-macro-with-semi-re)))
        (begin
          (set-buffer-local-value! b 'major-mode 'c-mode)
          (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
          (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
            (c-init-language-vars c-mode)
            (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
            (c-set-style "gnu")
            (c-clear-found-types)
            (c-make-noise-macro-regexps)
            (c-make-macro-with-semi-re))))
    (set-buffer-local-value! b 'c-block-comment-flag #t)
    ;; `c-basic-common-init' (`cc-mode.el') sets `indent-line-function';
    ;; cc-mode.el is not ported, so the replay does what the mode will.
    (set-buffer-local-value! b 'indent-line-function c-indent-line)
    (set!comment-start "/* ")
    (set!comment-end " */")
    b))

(define (run row)
  (let* ((name (nth 0 row))
         (lang (nth 1 row))
         (cmdname (nth 2 row))
         (key (string->number (nth 3 row)))
         (arg (nth 4 row))
         (auto (not (= 0 (string->number (nth 5 row)))))
         (hungry (not (= 0 (string->number (nth 6 row)))))
         (elec (not (= 0 (string->number (nth 7 row)))))
         (syn (not (= 0 (string->number (nth 8 row)))))
         (point-spec (nth 9 row))
         (cleanups (nth 10 row))
         (text (decode (nth 11 row)))
         (cmd (cdr (assoc cmdname commands)))
         (mode (if (string=? lang "cpp") 'c++-mode 'c-mode)))
    (fresh text lang)
    (set!c-electric-flag elec)
    (set!c-syntactic-indentation syn)
    (set!c-auto-newline auto)
    (set!c-hungry-delete-key hungry)
    (unless (string=? cleanups "default")
      (set!c-cleanup-list
       (map string->symbol (string-split cleanups #\,))))
    (when (string=? cmdname "c-electric-pound")
      (*c-electric-pound-behavior* '(alignleft)))
    (goto-char (if (string=? point-spec "end") (point-max)
                   (string->number point-spec)))
    (parameterize ((*c-buffer-is-cc-mode* mode)
                   (*last-command-event* key))
      (cond ((string=? arg "none") (cmd))
            ((string=? arg "nil") (cmd #f))
            (else (cmd (string->number arg)))))
    (display name) (display "\t")
    (display (encode (buffer-substring (point-min) (point-max))))
    (display "\t") (display (point)) (newline)
    (force-output)))

(for-each run (read-rows (cadr (command-line))))
