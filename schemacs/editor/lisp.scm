(define-library (schemacs editor lisp)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/lisp.el' - the Lisp
  ;; editing commands that go with a Lisp major mode. Emacs 31 keeps
  ;; `beginning-of-defun' and `end-of-defun' here too (they were
  ;; `editfns.c''s in older versions), so the whole of Chris's list that
  ;; is lisp.el's is in this file.
  ;;
  ;; Not carried, each named against what it waits for:
  ;;
  ;;   * `delete-pair', `delete-pair-push-mark', `delete-pair-blink-delay'
  ;;     - they need `blink-matching-open' and the undo list's
  ;;     `delete-pair' grouping.
  ;;   * `kill-backward-up-list' - it needs `thing-at-point' (thingatpt.el).
  ;;   * `mark-defun-back' - it is `mark-defun''s own `this-command'
  ;;     symbol, and this tree has no command symbols separate from the
  ;;     procedures.
  ;;   * `narrow-to-defun' is carried (`C-x n d'); the narrowing it uses
  ;;     is `editfns.scm`'s.
  ;;   * `beginning-of-defun''s `wrong-number-of-arguments' fallback
  ;;     catches every error instead: one condition type here.
  ;;
  ;; `move-past-close-and-reindent' is here too, but its body needs the
  ;; Lisp indentation engine (`calculate-lisp-indent') and is waiting on
  ;; that.

  (import
    (scheme base)
    (only (guile) caddr)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor keymap) define-key)
    (only (schemacs editor command)
          define-command current-prefix-arg uarg->integer *last-command-event*)
    (only (schemacs editor subr) kbd user-error)
    (only (schemacs editor buffer) transient-mark-mode mark-active)
    (only (schemacs editor editfns)
          narrow-to-region point-max save-restriction)
    (only (schemacs editor character) event-basic-type)
    (only (schemacs editor simple)
          push-mark mark set-mark kill-region use-region-p
          %transpose-subr back-to-indentation newline-and-indent
          delete-indentation-command
          *this-command* *last-command*)
    (only (schemacs editor editfns)
          point point-min point-max goto-char insert insert-char forward-line
          line-beginning-position line-end-position bobp eobp bolp
          point-marker preceding-char following-char save-excursion eolp
          region-beginning region-end
          ;; `beginning-of-defun-raw` scans the whole buffer and clamps
          ;; the answer back into the restriction (`lisp.el:465`).
          save-restriction widen)
    (only (schemacs editor cmds) beginning-of-line end-of-line forward-char)
    (only (schemacs editor syntax) skip-chars-forward skip-chars-backward
          parse-partial-sexp)
    (only (schemacs editor syntax)
          scan-sexps scan-lists backward-prefix-chars skip-syntax-forward
          skip-syntax-backward forward-comment syntax-ppss
          syntax-ppss-toplevel-pos ppss-comment-or-string-start
          *syntax-begin-function* char-syntax
          *open-paren-in-column-0-is-defun-start*
          make-scan-error scan-error? scan-error-message scan-error-start
          scan-error-end)
    (only (schemacs editor search)
          looking-at re-search-backward re-search-forward save-match-data
          match-end match-beginning)
    ;; `narrow-to-defun`'s INCLUDE-COMMENTS walk reads the page delimiter
    ;; (`lisp.el:783`).
    (only (schemacs editor paragraphs) *page-delimiter*))

  (export
   buffer-end
   *defun-prompt-regexp* *parens-require-spaces*
   *forward-sexp-function* forward-sexp-default-function
   forward-sexp backward-sexp mark-sexp
   *forward-list-function* forward-list-default-function
   forward-list backward-list
   *down-list-function* down-list-default-function down-list
   *up-list-function* up-list up-list-default-function backward-up-list
   kill-sexp backward-kill-sexp
   *beginning-of-defun-function* beginning-of-defun beginning-of-defun-raw
   beginning-of-defun--in-emptyish-line-p beginning-of-defun-comments
   *end-of-defun-function* *end-of-defun-moves-to-eol* end-of-defun
   mark-defun narrow-to-defun narrow-to-defun-include-comments
   *transpose-sexps-function* transpose-sexps-default-function
   transpose-sexps
   move-past-close-and-reindent *calculate-lisp-indent-function*
   insert-pair-alist insert-pair insert-parentheses)

  (begin

    (define insert-pair-alist
      ;; GNU Emacs's `insert-pair-alist' (lisp.el:794), a defcustom.
      ;;--------------------------------------------------------------
      (list (list (char->integer #\() (char->integer #\)))
            (list (char->integer #\[) (char->integer #\]))
            (list (char->integer #\{) (char->integer #\}))
            (list (char->integer #\<) (char->integer #\>))
            (list (char->integer #\") (char->integer #\"))
            (list (char->integer #\') (char->integer #\'))
            (list (char->integer #\`) (char->integer #\`))))

    ;; ---------------------------------------------------------------
    ;; `forward-sexp' and the motion commands (`lisp/emacs-lisp/lisp.el').
    ;; ---------------------------------------------------------------
    (define *defun-prompt-regexp* (make-parameter #f))
    (define *parens-require-spaces* (make-parameter #t))

    (define (buffer-end arg)
      ;; GNU Emacs's `buffer-end' (`lisp.el:576'): "Return the \"far
      ;; end\" position of the buffer, in direction ARG."
      ;;--------------------------------------------------------------
      (if (> arg 0) (point-max) (point-min)))

    (define (forward-sexp-default-function arg)
      ;; GNU Emacs's `forward-sexp-default-function' (`lisp.el:66').
      ;;--------------------------------------------------------------
      (goto-char (or (scan-sexps (point) arg) (buffer-end arg)))
      (if (< arg 0) (backward-prefix-chars)))

    (define *forward-sexp-function* (make-parameter forward-sexp-default-function))

    (define-command (forward-sexp . rest)
      "Move forward across one balanced expression (sexp).
With ARG, do it that many times.  Negative arg -N means move
backward across N balanced expressions.  This command assumes
point is not in a string or comment.  Calls
`forward-sexp-function' to do the work, if that is non-nil."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if interactive
            (guard (e ((scan-error? e)
                       (user-error (if (> arg 0) "No next sexp"
                                       "No previous sexp"))))
              (forward-sexp arg #f))
            (begin
              (if (not arg) (set! arg 1))
              ((or (*forward-sexp-function*) forward-sexp-default-function)
               arg)))))

    (define-command (backward-sexp . rest)
      "Move backward across one balanced expression (sexp).
With ARG, do it that many times.  Negative arg -N means
move forward across N balanced expressions."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if (not arg) (set! arg 1))
        (forward-sexp (- arg) interactive)))

    (define-command (mark-sexp . rest)
      "Set mark ARG sexps from point or move mark one sexp.
When called from Lisp with ALLOW-EXTEND omitted or nil, mark is
set ARG sexps from point."
      (interactive (list (current-prefix-arg) 1))
      (let ((arg (if (pair? rest) (car rest) #f))
            (allow-extend (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (cond
         ((and allow-extend
               (or (and (eq? (*last-command*) (*this-command*)) (mark #t))
                   (and (transient-mark-mode) (mark-active))))
          (set! arg (if arg (uarg->integer 1 arg)
                        (if (< (mark #t) (point)) -1 1)))
          (set-mark
           (save-excursion
             (goto-char (mark #t))
             (guard (e ((scan-error? e)
                        (user-error
                         (if (equal? (scan-error-message e)
                                     "Containing expression ends prematurely")
                             "No more sexp to select"
                           (scan-error-message e)))))
               (forward-sexp arg))
             (point))))
         (else
          (push-mark
           (save-excursion
             (guard (e ((scan-error? e)
                        (user-error
                         (if (equal? (scan-error-message e)
                                     "Containing expression ends prematurely")
                             "No sexp to select"
                           (scan-error-message e)))))
               (forward-sexp (uarg->integer 1 arg)))
             (point))
           #f #t)))))

    (define (forward-list-default-function arg)
      ;; GNU Emacs's `forward-list-default-function' (`lisp.el:174').
      ;;--------------------------------------------------------------
      (goto-char (or (scan-lists (point) arg 0) (buffer-end arg))))

    (define *forward-list-function* (make-parameter forward-list-default-function))

    (define-command (forward-list . rest)
      "Move forward across one balanced group of parentheses.
With ARG, do it that many times.
Negative arg -N means move backward across N groups of parentheses."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if interactive
            (guard (e ((scan-error? e)
                       (user-error (if (> arg 0) "No next group"
                                       "No previous group"))))
              (forward-list arg #f))
            (begin
              (if (not arg) (set! arg 1))
              ((or (*forward-list-function*) forward-list-default-function)
               arg)))))

    (define-command (backward-list . rest)
      "Move backward across one balanced group of parentheses.
With ARG, do it that many times.
Negative arg -N means move forward across N groups of parentheses."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if (not arg) (set! arg 1))
        (forward-list (- arg) interactive)))

    (define (down-list-default-function arg)
      ;; GNU Emacs's `down-list-default-function' (`lisp.el:194').
      ;;--------------------------------------------------------------
      (let ((inc (if (> arg 0) 1 -1)))
        (let loop ()
          (if (not (= arg 0))
              (begin
                (goto-char (or (scan-lists (point) inc -1) (buffer-end arg)))
                (set! arg (- arg inc))
                (loop))))))

    (define *down-list-function* (make-parameter #f))

    (define-command (down-list . rest)
      "Move forward down one level of parentheses.
With ARG, do this that many times.
A negative argument means move backward but still go down a level."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (when (and (not (*down-list-function*))
                   (ppss-comment-or-string-start (syntax-ppss)))
          (user-error "This command doesn't work in strings or comments"))
        (if interactive
            (guard (e ((scan-error? e) (user-error "At bottom level")))
              (down-list arg #f))
            (begin
              (if (not arg) (set! arg 1))
              (if (*down-list-function*)
                  ((*down-list-function*) arg)
                  (down-list-default-function arg))))))

    (define *up-list-function* (make-parameter #f))

    (define-command (backward-up-list . rest)
      "Move backward out of one level of parentheses.
With ARG, do this that many times.  A negative argument means
move forward but still to a less deep spot."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker) (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (escape-strings (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (no-syntax-crossing
             (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                  (caddr rest))))
        (up-list (- (if arg arg 1)) escape-strings no-syntax-crossing)))

    (define-command (up-list . rest)
      "Move forward out of one level of parentheses.
With ARG, do this that many times.  A negative argument means
move backward but still to a less deep spot."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker) (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (escape-strings (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (no-syntax-crossing
             (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                  (caddr rest))))
        (if (*up-list-function*)
            ((*up-list-function*) arg escape-strings no-syntax-crossing)
            (up-list-default-function arg escape-strings no-syntax-crossing))))

    (define (up-list-default-function arg escape-strings no-syntax-crossing)
      ;; GNU Emacs's `up-list-default-function' (`lisp.el:271').
      ;;
      ;; **The `no-syntax-crossing` narrowing is the C's**: when point is
      ;; inside a string or comment and the caller has asked not to cross
      ;; a boundary, the scan is restricted to that string or comment, so
      ;; `scan-lists` cannot pair a parenthesis with one outside it. It
      ;; was the error arm alone until 2026-11-17, which reaches the same
      ;; answer by a different route; the C's route is the one here now
      ;; that `narrow-to-region` exists.
      ;;--------------------------------------------------------------
      (if (not arg) (set! arg 1))
      (let ((inc (if (> arg 0) 1 -1))
            (pos #f))
        (let loop ()
          (if (not (= arg 0))
              (begin
                (guard (e ((scan-error? e)
                           (let ((syntax #f))
                             (or
                              ;; "If we bumped up against the end of a
                              ;; list, see whether we're inside a
                              ;; string: if so, just go to the
                              ;; beginning or end of that string."
                              (and escape-strings
                                   (set! syntax (syntax-ppss))
                                   (list-ref syntax 3)
                                   (goto-char (list-ref syntax 8))
                                   (begin (when (> inc 0) (forward-sexp))
                                          #t))
                              ;; "If we narrowed to a comment above and
                              ;; failed to escape it, the error might be
                              ;; our fault, not an indication that we're
                              ;; out of syntax. Try again from beginning
                              ;; or end of the comment."
                              (and no-syntax-crossing
                                   (set! syntax (syntax-ppss))
                                   (list-ref syntax 4)
                                   (goto-char (list-ref syntax 8))
                                   (or (< inc 0)
                                       (forward-comment 1))
                                   (set! arg (+ arg inc)))
                              (if no-syntax-crossing
                                  (user-error "At top level")
                                  (raise e))))))
                  (save-restriction
                    ;; "If we've been asked not to cross string boundaries
                    ;; and we're inside a string, narrow to that string so
                    ;; that scan-lists doesn't find a match in a different
                    ;; string."
                    (when no-syntax-crossing
                      (let* ((syntax (syntax-ppss))
                             (string-comment-start (list-ref syntax 8)))
                        (when string-comment-start
                          (save-excursion
                            (goto-char string-comment-start)
                            (narrow-to-region
                             (point)
                             (if (list-ref syntax 3)   ; in string
                                 (guard (e2 ((scan-error? e2) (point-max)))
                                   (forward-sexp 1)
                                   (point))
                                 (begin (forward-comment 1) (point))))))))
                    (if (or (not (*forward-sexp-function*))
                            (eq? (*forward-sexp-function*)
                                 forward-sexp-default-function))
                        (goto-char (or (scan-lists (point) inc 1)
                                       (buffer-end arg)))
                        (begin
                          (guard (e ((scan-error? e)
                                     (goto-char (if (> arg 0)
                                                    (scan-error-end e)
                                                    (scan-error-start e)))))
                            (let spin ()
                              (set! pos (point))
                              (forward-sexp inc)
                              (if (not (= (point) pos)) (spin))))
                          (if (= (point) pos)
                              (raise (make-scan-error "Unbalanced parentheses"
                                                      (point) (point))))))))
                (set! arg (- arg inc))
                (loop))))
        #f))

    (define-command (kill-sexp . rest)
      "Kill the sexp (balanced expression) following point.
With ARG, kill that many sexps after point.
Negative arg -N means kill N sexps before point."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if interactive
            (guard (e ((scan-error? e)
                       (user-error (if (> arg 0) "No next sexp"
                                       "No previous sexp"))))
              (kill-sexp arg #f))
            (let ((opoint (point)))
              (forward-sexp (if arg arg 1))
              (kill-region opoint (point))))))

    (define-command (backward-kill-sexp . rest)
      "Kill the sexp (balanced expression) preceding point.
With ARG, kill that many sexps before point."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (kill-sexp (- (if arg arg 1)) interactive)))

    ;; ---------------------------------------------------------------
    ;; `beginning-of-defun' (`lisp.el:395') and `end-of-defun'
    ;; (`lisp.el:583').
    ;; ---------------------------------------------------------------
    (define *beginning-of-defun-function* (make-parameter #f))

    (define-command (beginning-of-defun . rest)
      "Move backward to the beginning of a defun.
With ARG, do it that many times.  Negative ARG means move forward
to the ARGth following beginning of defun."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let ((arg (if (pair? rest) (car rest) #f)))
        (or (not (eq? (*this-command*) beginning-of-defun))
            (eq? (*last-command*) beginning-of-defun)
            (and (transient-mark-mode) (mark-active))
            (push-mark))
        (and (beginning-of-defun-raw arg)
             (begin (beginning-of-line) #t))))

    (define (beginning-of-defun-raw . rest)
      ;; GNU Emacs's `beginning-of-defun-raw' (`lisp.el:411'): "Move point
      ;; to the character that starts a defun."
      ;;
      ;; The `save-restriction'/`widen' pair around the scanner's branch
      ;; is carried now that narrowing exists (`lisp.el:465`). The C's
      ;; `wrong-number-of-arguments' fallback catches every error,
      ;; because this tree has one condition type for errors.
      ;;--------------------------------------------------------------
      (let ((arg (if (pair? rest) (car rest) #f)))
        (if (not arg) (set! arg 1))
        (cond
         ((*beginning-of-defun-function*)
          (guard (e (#t
                     (if (> arg 0)
                         (let loop ((i 0))
                           (if (< i arg)
                               (begin ((*beginning-of-defun-function*))
                                      (loop (+ i 1)))))
                         (let loop ((i 0))
                           (if (< i (- arg))
                               (begin (end-of-defun) (loop (+ i 1))))))))
            ((*beginning-of-defun-function*) arg)))
         ((or (*defun-prompt-regexp*)
              (*open-paren-in-column-0-is-defun-start*))
          (when (and (< arg 0) (not (eobp))) (forward-char 1))
          (and (let ((found #f))
                 (let loop ()
                   (set! found (re-search-backward
                                (if (*defun-prompt-regexp*)
                                    (string-append
                                     (if (*open-paren-in-column-0-is-defun-start*)
                                         "^\\s(\\|" "")
                                     "\\(?:" (*defun-prompt-regexp*) "\\)\\s(")
                                    "^\\s(")
                                #f 'move arg))
                   (if (and found
                            (save-match-data
                              (ppss-comment-or-string-start (syntax-ppss))))
                       (loop)))
                 found)
               (begin (goto-char (- (match-end 0) 1)) #t)))
         ((= arg 0) #f)
         (else
          (let ((floor (point-min))
                (ceiling (point-max))
                (arg-+ve (> arg 0))
                (encl-pos #f))
            ;; **`(save-restriction (widen))`** (`lisp.el:465`): the scan
            ;; runs over the whole buffer, and FLOOR/CEILING - read from
            ;; `point-min`/`point-max` *before* it - are what clamps the
            ;; answer back into the restriction.
            (save-restriction
             (widen)
            (let ((ppss (parameterize ((*syntax-begin-function* #f))
                          (syntax-ppss))))
              ;; "Back out of any comment/string, so that encl-pos will
              ;; always become nil if we're at top-level."
              (when (ppss-comment-or-string-start ppss)
                (goto-char (ppss-comment-or-string-start ppss))
                (set! ppss (syntax-ppss)))
              (set! encl-pos (syntax-ppss-toplevel-pos ppss))
              (if encl-pos (goto-char encl-pos))
              (and encl-pos arg-+ve (set! arg (- arg 1)))
              (and (not encl-pos) (not arg-+ve) (not (looking-at "\\s("))
                   (set! arg (+ arg 1)))
              (guard (e (#t
                         (goto-char (if arg-+ve floor ceiling))
                         #f))
                (goto-char (scan-lists (point) (- arg) 0))
                (if arg-+ve
                    (if (>= (point) floor)
                        #t
                        (begin (goto-char floor) #f))
                    ;; "forward to next (, or trigger the c-c"
                    (begin
                      (goto-char (- (scan-lists (point) 1 -1) 1))
                      (if (<= (point) ceiling)
                          #t
                          (begin (goto-char ceiling) #f))))))))))))

    (define (beginning-of-defun--in-emptyish-line-p)
      ;; GNU Emacs's `beginning-of-defun--in-emptyish-line-p'
      ;; (`lisp.el:531'): "Return non-nil if the point is in an
      ;; \"emptyish\" line."
      ;;--------------------------------------------------------------
      (save-excursion
        (forward-line 0)
        (let ((ppss (syntax-ppss)))
          (and (not (list-ref ppss 3))
               (< (line-end-position)
                  (begin (when (list-ref ppss 4)
                           (goto-char (list-ref ppss 8)))
                         (forward-comment (point-max))
                         (point)))))))

    (define-command (beginning-of-defun-comments . rest)
      "Move to the beginning of ARGth defun, including comments."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let ((arg (if (pair? rest) (car rest) #f))
            (first-line-p #f))
        (if (not arg) (set! arg 1))
        (beginning-of-defun arg)
        (let loop ()
          (if (let ((ppss (begin
                            (set! first-line-p (= (forward-line -1) -1))
                            (syntax-ppss (line-end-position)))))
                (let inner ()
                  (when (and (list-ref ppss 4)
                             (< (list-ref ppss 8) (line-beginning-position)))
                    (goto-char (list-ref ppss 8))
                    (set! ppss (syntax-ppss (line-end-position)))
                    (inner)))
                (and (not first-line-p)
                     (begin
                       (skip-syntax-backward "-" (line-beginning-position))
                       (not (bolp)))
                     (beginning-of-defun--in-emptyish-line-p)))
              (loop)))
        (forward-line (if first-line-p 0 1))))

    (define *end-of-defun-function* (make-parameter (lambda () (forward-sexp 1))))
    (define *end-of-defun-moves-to-eol* (make-parameter #t))

    (define-command (end-of-defun . rest)
      "Move forward to next end of defun.
With argument, do it that many times.
Negative argument -N means move back to Nth preceding end of defun."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if interactive
            (guard (e ((scan-error? e) (user-error (scan-error-message e))))
              (end-of-defun arg #f))
            (begin
              (or (not (eq? (*this-command*) end-of-defun))
                  (eq? (*last-command*) end-of-defun)
                  (and (transient-mark-mode) (mark-active))
                  (push-mark))
              (if (or (not arg) (= arg 0)) (set! arg 1))
              (let ((pos (point))
                    (success #f)
                    (beg #f))
                (when (*end-of-defun-moves-to-eol*) (end-of-line 1))
                (beginning-of-defun-raw 1)
                (set! beg (point))
                (define (skip)
                  ;; When comparing point against POS, "if point was
                  ;; right after the end of the function, it's still
                  ;; considered as \"in that function\"".
                  (unless (bolp)
                    (skip-chars-forward " \t")
                    (if (looking-at "\\s<\\|\n")
                        (forward-line 1))))
                ((*end-of-defun-function*))
                (when (<= arg 1) (skip))
                (cond
                 ((> arg 0)
                  (if (> (point) pos)
                      (set! arg (- arg 1))
                      (goto-char pos))
                  (unless (= arg 0)
                    (set! success (beginning-of-defun-raw (- arg)))
                    (when success ((*end-of-defun-function*)))))
                 ((< arg 0)
                  (when (< (point) pos) (set! arg (+ arg 1)))
                  (unless (= arg 0)
                    (goto-char beg)
                    (set! success (beginning-of-defun-raw (- arg)))
                    (when success
                      (set! beg (point))
                      ((*end-of-defun-function*))))))
                (skip)
                (let loop ()
                  (when (and (< arg 0) (>= (point) pos) success)
                    ;; "We intended to move backward, but this ended up
                    ;; not doing so: Try harder!"
                    (goto-char beg)
                    (set! success (beginning-of-defun-raw (- arg)))
                    (if (or (>= (point) beg) (not success))
                        (set! arg 0)
                        (begin
                          (set! beg (point))
                          ((*end-of-defun-function*))
                          (skip)
                          (loop))))))))))

    (define-command (mark-defun . rest)
      "Put mark at end of this defun, point at beginning.
The defun marked is the one that contains point or follows point."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if interactive
            (guard (e ((scan-error? e) (user-error (scan-error-message e))))
              (mark-defun arg #f))
            (begin
              (set! arg (if arg arg 1))
              (cond
               ((use-region-p)
                (if (>= arg 0)
                    (set-mark
                     (save-excursion
                       (goto-char (mark #t))
                       ;; "change the dotimes below to (end-of-defun arg)
                       ;; once bug #24427 is fixed"
                       (let loop ((i 0))
                         (if (< i arg) (begin (end-of-defun) (loop (+ i 1)))))
                       (point)))
                    (beginning-of-defun-comments (- arg))))
               (else
                (let ((opoint (point))
                      (beg #f)
                      (end #f))
                  (push-mark opoint)
                  ;; "Try first in this order for the sake of languages
                  ;; with nested functions where several can end at the
                  ;; same place as with the offside rule, e.g. Python."
                  (beginning-of-defun-comments)
                  (set! beg (point))
                  (end-of-defun)
                  (set! end (point))
                  (when (or (and (<= (point) opoint) (> arg 0))
                            (= beg (point-min)))
                    ;; "beginning-of-defun moved back one defun so we got
                    ;; the wrong one."
                    (goto-char opoint)
                    (end-of-defun)
                    (set! end (point))
                    (beginning-of-defun-comments)
                    (set! beg (point)))
                  (goto-char beg)
                  (cond
                   ((> arg 0)
                    (let loop ((i 0))
                      (if (< i arg) (begin (end-of-defun) (loop (+ i 1)))))
                    (set! end (point))
                    (push-mark end #f #t)
                    (goto-char beg))
                   (else
                    (goto-char beg)
                    (unless (= arg -1)
                      ;; "beginning-of-defun behaves strange with zero
                      ;; arg"
                      (beginning-of-defun (- (- arg) 1)))
                    (push-mark end #f #t))))))
              (skip-chars-backward "[:space:]\n")
              (unless (bobp)
                (forward-line 1))))))

    (define-command (insert-pair . rest)
      "Enclose following ARG sexps in a pair of OPEN and CLOSE characters.
Leave point after the first character."
      (interactive (list (current-prefix-arg) #f #f))
      (let ((arg (if (pair? rest) (car rest) #f))
            (open (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (close (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                        (caddr rest))))
        (if (not (and open close))
            (let ((pair (or (assq *last-command-event* insert-pair-alist)
                            (assq (event-basic-type *last-command-event*)
                                  insert-pair-alist))))
              (if pair
                  (if (list-ref pair 2)
                      (begin (set! open (list-ref pair 1))
                             (set! close (list-ref pair 2)))
                      (begin (set! open (list-ref pair 0))
                             (set! close (list-ref pair 1)))))))
        (if (and open close)
            (if (and (transient-mark-mode) (mark-active))
                (begin
                  (save-excursion
                    (goto-char (region-end))
                    (insert close))
                  (goto-char (region-beginning))
                  (insert open))
                (begin
                  (if arg (set! arg (uarg->integer 1 arg)) (set! arg 0))
                  (cond ((> arg 0) (skip-chars-forward " \t"))
                        ((< arg 0) (forward-sexp arg) (set! arg (- arg))))
                  (and (*parens-require-spaces*)
                       (not (bobp))
                       (memv (char-syntax (preceding-char))
                             (list #\w #\_ (char-syntax close)))
                       (insert " "))
                  (insert open)
                  (save-excursion
                    (or (eqv? arg 0) (forward-sexp arg))
                    (insert close)
                    (and (*parens-require-spaces*)
                         (not (eobp))
                         (memv (char-syntax (following-char))
                               (list #\w #\_ (char-syntax open)))
                         (insert " ")))))
            (insert-char (event-basic-type *last-command-event*)
                         (uarg->integer 1 arg)))))

    (define-command (insert-parentheses . rest)
      "Enclose following ARG sexps in parentheses.
Leave point after open-paren."
      (interactive (list (current-prefix-arg)))
      (let ((arg (if (pair? rest) (car rest) #f)))
        (insert-pair arg (char->integer #\() (char->integer #\)))))

    ;; ---------------------------------------------------------------
    ;; `transpose-sexps' - simple.el's, but it needs `forward-sexp',
    ;; which lives in this library, so it is here beside it.
    ;; ---------------------------------------------------------------
    (define (transpose-sexps-default-function arg)
      ;; GNU Emacs's `transpose-sexps-default-function' (`simple.el:8807').
      ;;--------------------------------------------------------------
      (if (if (> arg 0)
              (looking-at "\\sw\\|\\s_")
              (and (not (bobp))
                   (save-excursion
                     (forward-char -1)
                     (looking-at "\\sw\\|\\s_"))))
          ;; "Jumping over a symbol. We might be inside it, mind you."
          (begin
            ((if (> arg 0) skip-syntax-backward skip-syntax-forward) "w_")
            (cons (save-excursion (forward-sexp arg) (point)) (point)))
          ;; "Otherwise, we're between sexps. Take a step back before
          ;; jumping to make sure we'll obey the same precedence no
          ;; matter which direction we're going."
          (begin
            ((if (> arg 0) skip-syntax-backward skip-syntax-forward) " .")
            (cons (save-excursion (forward-sexp arg) (point))
                  (begin
                    (let loop ()
                      (if (or (forward-comment (if (> arg 0) 1 -1))
                              (not (= 0 ((if (> arg 0) skip-syntax-forward
                                             skip-syntax-backward)
                                         "."))))
                          (loop)))
                    (point))))))

    (define *transpose-sexps-function* (make-parameter transpose-sexps-default-function))

    (define-command (transpose-sexps . rest)
      "Like \\[transpose-chars] (`transpose-chars'), but applies to sexps.
Unlike `transpose-words', point must be between the two sexps and not
in the middle of a sexp to be transposed."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (point-marker)))
      (let ((arg (if (pair? rest) (car rest) #f))
            (interactive (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if interactive
            (guard (e ((scan-error? e)
                       (user-error "Not between two complete sexps")))
              (transpose-sexps arg #f))
            (%transpose-subr (*transpose-sexps-function*) arg 'special))))

    ;; ---------------------------------------------------------------
    ;; `bindings.el''s keys for the commands above.
    ;; ---------------------------------------------------------------
    (define-key km:*default-keymap* (kbd "C-M-f") forward-sexp)
    (define-key km:*default-keymap* (kbd "C-M-b") backward-sexp)
    (define-key km:*default-keymap* (kbd "C-M-SPC") mark-sexp)
    (define-key km:*default-keymap* (kbd "C-M-n") forward-list)
    (define-key km:*default-keymap* (kbd "C-M-p") backward-list)
    (define-key km:*default-keymap* (kbd "C-M-d") down-list)
    (define-key km:*default-keymap* (kbd "C-M-u") backward-up-list)
    (define-key km:*default-keymap* (kbd "C-M-k") kill-sexp)
    (define-key km:*default-keymap* (kbd "C-M-e") end-of-defun)
    (define-key km:*default-keymap* (kbd "C-M-a") beginning-of-defun)
    (define-key km:*default-keymap* (kbd "C-M-h") mark-defun)

    (define narrow-to-defun-include-comments #f)
    ;; ^ GNU Emacs's `narrow-to-defun-include-comments' (`lisp.el:739'):
    ;; "If non-nil, `narrow-to-defun' will also show comments preceding
    ;; the defun." A `defvar` in the C, so a plain variable - and the
    ;; self-assignment is the compiler's constant-folding guard.
    (set! narrow-to-defun-include-comments narrow-to-defun-include-comments)

    (define-command (narrow-to-defun . rest)
      ;; GNU Emacs's `narrow-to-defun' (`lisp.el:742'): "Make text
      ;; outside current defun invisible. The current defun is the one
      ;; that contains point or follows point."
      ;;
      ;; `(while (looking-at "^\n") ...)' is a Scheme `let loop` because
      ;; Elisp's `while` is a special form.
      ;;--------------------------------------------------------------
      "Make text outside current defun invisible.
The current defun is the one that contains point or follows point.
Preceding comments are included if INCLUDE-COMMENTS is non-nil.
Interactively, the behavior depends on `narrow-to-defun-include-comments'."
      (interactive (list narrow-to-defun-include-comments))
      (let ((include-comments (and (pair? rest) (car rest))))
        (save-excursion
          (widen)
          (let ((opoint (point))
                (beg #f)
                (end #f))
            ;; "Try first in this order for the sake of languages with
            ;; nested functions where several can end at the same place as
            ;; with the offside rule, e.g. Python."
            ;;
            ;; "Finding the start of the function is a bit problematic
            ;; since `beginning-of-defun' when we are on the first
            ;; character of the function might go to the previous
            ;; function. Therefore we first move one character forward and
            ;; then call `beginning-of-defun'."
            (unless (eolp) (forward-char))
            (beginning-of-defun)
            (set! beg (point))
            (end-of-defun)
            (set! end (point))
            (let loop ()
              (when (looking-at "^\n")
                (forward-line 1)
                (loop)))
            (unless (> (point) opoint)
              ;; "beginning-of-defun moved back one defun so we got the
              ;; wrong one."
              (goto-char opoint)
              (end-of-defun)
              (set! end (point))
              (beginning-of-defun)
              (set! beg (point)))
            (when include-comments
              (goto-char beg)
              ;; "Move back past all preceding comments (and whitespace)."
              (when (forward-comment -1)
                (let loop ()
                  (when (forward-comment -1) (loop)))
                ;; "Move forwards past any page breaks within these
                ;; comments."
                (when (and (*page-delimiter*)
                           (not (string=? (*page-delimiter*) "")))
                  (let loop ()
                    (when (re-search-forward (*page-delimiter*) beg #t)
                      (loop))))
                ;; "Lastly, move past any empty lines."
                (skip-chars-forward "[:space:]\n")
                (beginning-of-line)
                (set! beg (point))))
            (goto-char end)
            (re-search-backward "^\n" (- (point) 1) #t)
            (narrow-to-region beg end)))))

    ;; `narrow-map`'s `d` (`bindings.el:1669'), flat - see the note on
    ;; `narrow-map` in `editfns.scm`. It goes AFTER the command it binds:
    ;; a `define-key` here holds the command's *value*, and a binding
    ;; above its definition reads an unbound variable at module load.
    (define-key km:*default-keymap* (kbd "C-x n d") narrow-to-defun)

    ;; ---------------------------------------------------------------
    ;; `move-past-close-and-reindent' (`lisp.el:969').
    ;; ---------------------------------------------------------------
    (define *calculate-lisp-indent-function* (make-parameter #f))
    ;; ^ The seam for `calculate-lisp-indent', which is `lisp-mode.el''s
    ;; and lives in `(schemacs editor lisp-mode)' - a library that
    ;; imports *this* one, so the call has to come the other way. The
    ;; Lisp mode fills it at load time, as `simple.scm' fills
    ;; `*delete-horizontal-space-function*'.

    (define-command (move-past-close-and-reindent)
      "Move past next `)', delete indentation before it, then indent after it."
      (interactive '())
      (up-list 1)
      (forward-char -1)
      (let loop ()
        (when (save-excursion
                (let ((before-paren (point)))
                  (back-to-indentation)
                  (and (= (point) before-paren)
                       (begin
                         ;; "Move to end of previous line."
                         (beginning-of-line)
                         (forward-char -1)
                         ;; "Verify it doesn't end within a string or
                         ;; comment."
                         (let ((end (point))
                               (state #f))
                           (beginning-of-line)
                           ;; "Get state at start of line."
                           (set! state
                                 (list 0 #f #f
                                       (not ((*calculate-lisp-indent-function*)))
                                       #f #f #f #f #f))
                           ;; "Parse state across the line to get state at
                           ;; end."
                           (set! state (parse-partial-sexp
                                        (point) end #f #f state))
                           ;; "Check not in string or comment."
                           (and (not (list-ref state 3))
                                (not (list-ref state 4))))))))
          (delete-indentation-command #f #f #f)
          (loop)))
      (forward-char 1)
      (newline-and-indent))

    (define-key km:*default-keymap* (kbd "M-)") move-past-close-and-reindent)

    (define-key km:*default-keymap* (kbd "M-(") insert-parentheses)
    (define-key km:*default-keymap* (kbd "C-M-t") transpose-sexps)

    ))
