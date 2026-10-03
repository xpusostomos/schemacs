(define-library (schemacs editor env)
  ;; This library mirrors GNU Emacs's `lisp/env.el' - the environment
  ;; variable layer, of which `substitute-env-vars' is the one piece the
  ;; file primitives need (`substitute-in-file-name', `fileio.c').
  ;;
  ;; The variable's *value* is Guile's `getenv', which is the same
  ;; `getenv' the C calls. What is written here is Emacs's substitution
  ;; rule on top of it, and the regexp that finds the references.

  (import
    (scheme base)
    (scheme char)
    (only (guile) getenv)
    (only (schemacs editor search)
          match-beginning match-end match-string replace-match string-match)
    )

  (export
   env--substitute-vars-regexp
   substitute-env-vars
   )

  (begin

    (define env--substitute-vars-regexp
      ;; GNU Emacs's `env--substitute-vars-regexp' (env.el:60):
      ;;
      ;;   "\\$\\(?:\\(?1:[[:alnum:]_]+\\)\\|{\\(?1:[^{}]+\\)}\\|\\$\\)"
      ;;
      ;; which is `$NAME', `${NAME}' or `$$' - NAME in group 1 for the
      ;; first two, and group 1 unset for the third, which is how
      ;; `substitute-env-vars' tells "a variable to look up" from "a
      ;; literal dollar sign".
      ;;
      ;; Emacs spells the outer group *shy* (`\(?:') and the inner ones
      ;; *numbered* (`\(?1:') so that both alternatives share group 1.
      ;; glibc's ERE, which is the engine underneath this tree, has no
      ;; spelling for either - our translator rejects `\(?' outright.
      ;; The same match is spelled here with plain groups in an order
      ;; that keeps the distinction: `$$' first and matching no group,
      ;; then the bare name as group 1 and the braced one as group 2.
      ;; A caller asking `(match-beginning 1)' and `(match-beginning 2)'
      ;; gets the same three-way answer the C does.
      ;;
      ;; `[{]' and `[}]' are how a literal brace is written here: an
      ;; unescaped `{' is an interval operator to ERE, and a bracket
      ;; expression is copied through the translation verbatim.
      ;;
      ;; The pattern is written in the *Emacs* dialect, as the original
      ;; is, because that is what `string-match' reads - `\|' for
      ;; alternation and `\(' `\)' for a group. Writing it in ERE
      ;; syntax instead gets `|' escaped by the translation into a
      ;; literal and the pattern matches nothing at all.
      ;;--------------------------------------------------------------
      "\\$\\$\\|\\$\\([[:alnum:]_]+\\)\\|\\$[{]\\([^{}]+\\)[}]")

    (define (substitute-env-vars string . rest)
      ;; GNU Emacs's `substitute-env-vars' (env.el:63): "Substitute
      ;; environment variables referred to in STRING. `$FOO' where FOO
      ;; is an environment variable name means to substitute the value of
      ;; that variable. The variable name should be terminated with a
      ;; character not a letter, digit or underscore; otherwise, enclose
      ;; the entire variable name in braces. ... Use `$$' to insert a
      ;; single dollar sign."
      ;;
      ;; WHEN-UNDEFINED: nil replaces an undefined variable with the
      ;; empty string; a function is called with the name and should
      ;; answer the replacement or nil to leave the reference alone; any
      ;; other non-nil leaves it alone.
      ;;--------------------------------------------------------------
      (let ((when-undefined (if (pair? rest) (car rest) #f)))
        (let loop ((start 0) (string string))
          (if (not (string-match env--substitute-vars-regexp string start))
              string
              (let ((whole (match-string 0 string)))
                (if (string=? whole "$$")
                    ;; a literal dollar sign, and on past it
                    (loop (+ 1 (match-beginning 0))
                          (replace-match "$" #t #t string))
                    (let* ((var (or (match-string 1 string)
                                    (match-string 2 string)))
                           (value (getenv var)))
                      (cond
                       ;; an undefined variable, when the caller asked for
                       ;; the reference to be left standing
                       ((and (not value)
                             (if (procedure? when-undefined)
                                 (let ((answered (when-undefined var)))
                                   (set! value answered)
                                   (not answered))
                                 when-undefined))
                        (loop (match-end 0) string))
                       (else
                        (let ((value (or value "")))
                          ;; on past what was put in, so that a value
                          ;; holding a `$' is not substituted again -
                          ;; the C's `(+ (match-beginning 0) (length
                          ;; value))'
                          (loop (+ (match-beginning 0) (string-length value))
                                (replace-match value #t #t string))))))))))))

    ))
