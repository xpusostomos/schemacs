(import
  (scheme base)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs buffer)
        *current-buffer* allocate-buffer get-buffer-create set-buffer
        erase-buffer set-point buffer-pt mark-active)
  (only (schemacs editfns) insert buffer-string point)
  (only (schemacs frame) *current-frame* new-frame)
  (only (schemacs progmodes elisp-mode) emacs-lisp-mode eval-last-sexp eval-defun)
  (only (schemacs syntax)
        scan-sexps scan-lists forward-comment skip-syntax-forward
        skip-syntax-backward backward-prefix-chars
        scan-error-message scan-error-start scan-error-end)
  (only (schemacs core lisp)
        forward-sexp backward-sexp forward-list backward-list down-list
        backward-up-list beginning-of-defun end-of-defun mark-defun
        kill-sexp transpose-sexps insert-parentheses
        move-past-close-and-reindent)
  (only (schemacs simple) mark deactivate-mark)
  (only (schemacs subr) error-message-string)
  (only (schemacs loadup) open-user-environment!)
  (only (scheme eval) eval))

;; Every expectation in this file is GNU Emacs 31.1's own answer, measured
;; with `emacs -Q --batch' on the same text in `emacs-lisp-mode'. The
;; table of positions is the one the port was written against; where this
;; tree's answer differs the test says why.

(define *text*
  "(defun foo (a b)\n  \"doc\"\n  (let ((x 1))\n    (+ x a)))\n\n(defun bar ()\n  nil)\n")

(define (in-buffer text thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*lisp-tests*")))
      (set-buffer b)
      (erase-buffer)
      (insert text)
      (emacs-lisp-mode)
      ;; A mark left active by an earlier test is a region, and
      ;; `insert-pair' encloses the *region* when there is one - which is
      ;; Emacs's own rule, and what made this suite's first
      ;; `insert-parentheses' run enclose the wrong thing.
      (deactivate-mark)
      (set-point b 1)
      (thunk b))))

(define (at b pos) (set-point b pos))

(define (answer thunk)
  (guard (e (#t 'err)) (thunk)))

(test-begin "schemacs_editor_lisp")

;; ------------------------------------------------------------------
;; `scan-sexps' and `scan-lists' (`syntax.c:2660').
;;
;; Emacs: `"(foo) bar"' => (6 10 6 nil 1 7) for
;; (scan-sexps 1 1) (scan-sexps 1 2) (scan-lists 1 1 0)
;; (scan-lists 1 2 0) (scan-sexps 7 -1) (scan-sexps 10 -1).

(test-equal "scan-sexps and scan-lists answer Emacs's positions"
  (list 6 10 6 #f 1 7)
  (in-buffer "(foo) bar"
    (lambda (b)
      (list (scan-sexps 1 1) (scan-sexps 1 2) (scan-lists 1 1 0)
            (scan-lists 1 2 0) (scan-sexps 7 -1) (scan-sexps 10 -1)))))

;; Emacs on "(foo": (scan-sexps 1 1) signals, (scan-sexps 1 -1) is nil.
(test-equal "an unbalanced paren signals while a plain gap does not"
  (list 'err #f)
  (in-buffer "(foo"
    (lambda (b)
      (list (answer (lambda () (scan-sexps 1 1)))
            (answer (lambda () (scan-sexps 1 -1)))))))

(test-equal "the scan error carries Emacs's message and positions"
  (list "Unbalanced parentheses" 1 5)
  (in-buffer "(foo"
    (lambda (b)
      (guard (e (#t (list (scan-error-message e)
                          (scan-error-start e)
                          (scan-error-end e))))
        (scan-sexps 1 1)))))

;; ------------------------------------------------------------------
;; `forward-comment' (`syntax.c:2436') and `skip-syntax-*'.

;; Emacs on "  ; hi\nfoo": (forward-comment 1) t pt 8, again nil pt 8,
;; then (forward-comment -1) t pt 3.
(test-equal "forward-comment walks a comment both ways"
  '(#t 8 #f 8 #t 3)
  (in-buffer "  ; hi\nfoo"
    (lambda (b)
      (list (forward-comment 1) (buffer-pt b)
            (forward-comment 1) (buffer-pt b)
            (forward-comment -1) (buffer-pt b)))))

;; Emacs on "abc def": (skip-syntax-forward "w") 3 at 4, then 0 at 4.
(test-equal "skip-syntax-forward stops at the space"
  '(3 4 0 4)
  (in-buffer "abc def"
    (lambda (b)
      (list (skip-syntax-forward "w") (buffer-pt b)
            (skip-syntax-forward "w") (buffer-pt b)))))

;; Emacs on "abc def" from 7: -2 at 5, then 0 at 5.
(test-equal "skip-syntax-backward is its mirror"
  '(-2 5 0 5)
  (in-buffer "abc def"
    (lambda (b)
      (set-point b 7)
      (list (skip-syntax-backward "w") (buffer-pt b)
            (skip-syntax-backward "w") (buffer-pt b)))))

;; Emacs on "'(foo)" from 2: `backward-prefix-chars' goes to 1.
(test-equal "backward-prefix-chars crosses a quote"
  1
  (in-buffer "'(foo)"
    (lambda (b) (set-point b 2) (backward-prefix-chars) (buffer-pt b))))

;; ------------------------------------------------------------------
;; the motions, against Emacs's table for `*text*'
;;
;;   fwd-sexp   from 1 2 4 12 13 20 28 40 => 54 7 7 17 14 25 53 52
;;   bwd-sexp   from 12 45 52 55           => 8 33 45 1
;;   fwd-list   from 1 10 15               => 54 17 err
;;   bwd-list   from 45 52                 => 33 45
;;   down-list  from 1 15 20               => 2 err 29
;;   up-list    from 20 30 40              => 1 28 28
;;   beg-defun  from 1 5 20 30 45 52 60    => 1 1 1 1 1 1 56
;;   end-defun  from 1 5 20 45 52 60       => 55 55 55 55 55 77
;;   end-defun 2 from 10 45 52             => 77 77 77

(define (positions fn positions)
  (map (lambda (p)
         (in-buffer *text*
           (lambda (b) (set-point b p) (answer (lambda () (fn) (buffer-pt b))))))
       positions))

(test-equal "C-M-f forward-sexp"
  '(54 7 7 17 14 25 53 52)
  (positions (lambda () (forward-sexp 1)) '(1 2 4 12 13 20 28 40)))

(test-equal "C-M-b backward-sexp"
  '(8 33 45 1)
  (positions (lambda () (backward-sexp 1)) '(12 45 52 55)))

(test-equal "C-M-n forward-list"
  '(54 17 err)
  (positions (lambda () (forward-list 1)) '(1 10 15)))

(test-equal "C-M-p backward-list"
  '(33 45)
  (positions (lambda () (backward-list 1)) '(45 52)))

(test-equal "C-M-d down-list"
  '(2 err 29)
  (positions (lambda () (down-list 1)) '(1 15 20)))

(test-equal "C-M-u backward-up-list"
  '(1 28 28)
  (positions (lambda () (backward-up-list 1)) '(20 30 40)))

(test-equal "C-M-a beginning-of-defun"
  '(1 1 1 1 1 1 56)
  (positions (lambda () (beginning-of-defun 1)) '(1 5 20 30 45 52 60)))

(test-equal "C-M-e end-of-defun"
  '(55 55 55 55 55 77)
  (positions (lambda () (end-of-defun 1)) '(1 5 20 45 52 60)))

(test-equal "end-of-defun with a count walks that many defuns"
  '(77 77 77)
  (positions (lambda () (end-of-defun 2)) '(10 45 52)))

;; ------------------------------------------------------------------
;; mark-defun, kill-sexp, transpose-sexps, insert-parentheses

;; Emacs: `(mark-defun)' from 20 puts point at 1 and mark at 55.
(test-equal "mark-defun marks the defun point is in"
  '(1 55)
  (in-buffer *text*
    (lambda (b) (set-point b 20) (mark-defun) (list (buffer-pt b) (mark #t)))))

;; Emacs: kill-sexp from 12 kills "doc" - the string before point.
(test-equal "kill-sexp kills the sexp after point"
  " (c d)"
  (in-buffer "(a b) (c d)"
    (lambda (b) (set-point b 1) (kill-sexp 1) (buffer-string))))

;; Emacs: transpose-sexps is Emacs's own table.
;;   "foo bar" at 5, 1     => "bar foo" 8
;;   "(a b) (c d)" at 6, 1 => "(c d) (a b)" 12
;;   "a b c d" at 3, 1     => "b a c d" 4
;;   "a b c d" at 7, 1     => "a b d c" 8
;;   "a b c d" at 7, -1    => "a c b d" 4
(define (transposed text pos arg)
  (in-buffer text
    (lambda (b) (set-point b pos) (transpose-sexps arg)
      (list (buffer-string) (buffer-pt b)))))

(test-equal "C-M-t transpose-sexps"
  '(("bar foo" 8) ("(c d) (a b)" 12) ("b a c d" 4) ("a b d c" 8) ("a c b d" 4))
  (list (transposed "foo bar" 5 1)
        (transposed "(a b) (c d)" 6 1)
        (transposed "a b c d" 3 1)
        (transposed "a b c d" 7 1)
        (transposed "a b c d" 7 -1)))

;; Emacs: insert-parentheses is Emacs's own table.
(test-equal "M-( insert-parentheses"
  '(("foo () bar" 6) ("foo (bar)" 6) ("foo (bar)" 6) ("(abc)" 2) ("()" 2))
  (map (lambda (c)
         (in-buffer (list-ref c 0)
           (lambda (b) (set-point b (list-ref c 1))
             (insert-parentheses (list-ref c 2))
             (list (buffer-string) (buffer-pt b)))))
       (list (list "foo bar" 4 #f) (list "foo bar" 4 1) (list "foo bar" 8 -1)
             (list "abc" 1 1) (list "" 1 #f))))

;; ------------------------------------------------------------------
;; eval-last-sexp and eval-defun - the evaluator is Scheme's, so this
;; pins the reading and the printing, not a Lisp evaluator.

(test-equal "C-x C-e evaluates the sexp before point"
  "(+ 1 22)"
  (in-buffer "(+ 1 2)"
    (lambda (b) (set-point b 7) (eval-last-sexp 4) (buffer-string))))

(test-equal "C-M-x evaluates the defun and defines it"
  99
  (in-buffer "(define lisp-tests-zz 99)"
    (lambda (b) (set-point b 1) (eval-defun)
      (eval 'lisp-tests-zz (open-user-environment!)))))

;; ------------------------------------------------------------------
;; `move-past-close-and-reindent' (`lisp.el:969'), bound to M-).
;;
;; Both expectations are Emacs 31.1's own, measured with
;; `emacs -Q --batch' on the same text and the same starting point.
(test-begin "schemacs_editor_lisp_move_past_close_and_reindent")

(in-buffer "(defun foo ()\n  (a b\n       )\n  (c))\n"
  (lambda (b)
    (set-point b 20)
    (move-past-close-and-reindent)
    (test-equal "M-) pulls the lone `)' up and reindents what follows"
      "(defun foo ()\n  (a b)\n  \n  (c))\n" (buffer-string))
    (test-equal "...and point ends past the new line" 25 (point))))

(in-buffer "(defun foo ()\n  (a b\n       )\n  (c))\n"
  (lambda (b)
    (set-point b 16)
    (move-past-close-and-reindent)
    (test-equal "from inside the inner list nothing is joined"
      "(defun foo ()\n  (a b\n       )\n  (c))\n\n" (buffer-string))
    (test-equal "...and point is at the end of the buffer" 38 (point))))

(test-end "schemacs_editor_lisp_move_past_close_and_reindent")

(test-end "schemacs_editor_lisp")
