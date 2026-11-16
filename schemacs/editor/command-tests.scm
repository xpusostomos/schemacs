(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (ice-9 exceptions) exception-message)
 (only (schemacs editor command)
       define-command define-alias command-record-of command-procedure
       command-record-named *barf-if-buffer-read-only-function*)
 (only (schemacs editor buffer)
       allocate-buffer with-current-buffer current-buffer
       set!buffer-read-only)
 ;; Loaded for its effect: the command loop installs the `*' check's
 ;; seam as it loads (`*barf-if-buffer-read-only-function*').
 (only (schemacs editor keyboard) dispatch-key-event))

;; Regression tests for `callint.c`'s interactive specifications as this
;; tree reads them (`command.scm`'s `interactive-proc`).
;;
;; The `*' marker - "an error is signaled if the buffer is read-only"
;; (`callint.c:98`, peeled with `@', `-', `+' and `^' before any code is
;; read, `:362') - is what `comment-indent' declares, and until it was
;; ported neither that command nor any other could carry it.
;;
;; Each test drives the *interactive entry* - the procedure
;; `register-command!` filed on the command's record - which is exactly
;; what the command loop calls for a keypress.

(setvbuf (current-output-port) 'none)

(define *got* (make-parameter 'none))

(define-command (star-command uarg)
  "A command whose specification is `*P': the raw prefix, and the
read-only check."
  (interactive "*P")
  (*got* uarg))

(define-command (star-only-command)
  "A command whose specification is `*' alone: no arguments, and the
read-only check."
  (interactive "*")
  (*got* 'ran))

(define-command (star-shift-command uarg)
  "A command whose specification stacks both leading markers, `*^P'."
  (interactive "*^P")
  (*got* uarg))

(define-command (plain-command)
  "A command with no interactive arguments at all."
  (interactive)
  (*got* 'ran))

(define-command (aliased-command)
  "The target of `aliased-name'."
  (interactive)
  (*got* 'ran))

(define-alias aliased-name aliased-command)

(define (entry command)
  ;; The interactive entry the command loop would call.
  (command-procedure (command-record-of command)))

(define (message-of thunk)
  ;; What the echo area would show, irritants put back into the message
  ;; the way `keyboard.scm`'s `report-command-error!` does it.
  (guard (e (#t (let ((message (error-object-message e))
                      (irritants (error-object-irritants e)))
                  (if (and (list? irritants) (pair? irritants))
                      (apply format #f message irritants)
                      message))))
    (thunk)))

(define ed (allocate-buffer))

;;--------------------------------------------------------------
(test-begin "star-seam")
;;--------------------------------------------------------------
;; The seam is installed by the command loop's library, and without it a
;; `*' specification silently checks nothing.
(test-equal "the command loop installs the * check" #t
            (procedure? (*barf-if-buffer-read-only-function*)))
(test-end "star-seam")

(test-begin "star-marker")
;;--------------------------------------------------------------
;; "*" alone: no arguments, and the body runs on a writable buffer.
(with-current-buffer ed
  (test-equal "a * command runs on a writable buffer" 'ran
              (begin ((entry star-only-command) #f) (*got*)))
  (test-equal "and its body got no argument" 'ran (*got*)))

;; ...and refuses on a read-only one, *before* the body - which is the
;; whole point of `*' rather than a check the command writes itself.
(with-current-buffer ed
  (set!buffer-read-only (current-buffer) #t)
  (*got* 'none)
  (test-equal "a * command signals on a read-only buffer"
              "Buffer is read-only"
              (message-of (lambda () ((entry star-only-command) #f))))
  (test-equal "and its body never ran" 'none (*got*))
  (set!buffer-read-only (current-buffer) #f))

;; "*P": the marker is stripped and what follows is read as usual, so the
;; prefix still reaches the command.
(with-current-buffer ed
  (test-equal "a *P command still gets the raw prefix" '(4)
              (begin ((entry star-command) '(4)) (*got*)))
  (set!buffer-read-only (current-buffer) #t)
  (test-equal "and still checks the buffer first" "Buffer is read-only"
              (message-of (lambda () ((entry star-command) '(4)))))
  (set!buffer-read-only (current-buffer) #f))

;; The markers stack, one per recursion, as the C's loop over the
;; leading characters reads them: `*^P' is the check, then the `^'
;; marker (dropped here - there is no shift-select), then the prefix.
(with-current-buffer ed
  (test-equal "*^P reads the check, then the marker, then the code" '(4)
              (begin ((entry star-shift-command) '(4)) (*got*))))
(test-end "star-marker")

(test-begin "plain-specs")
;;--------------------------------------------------------------
;; `(interactive)` - the empty specification - is a thunk, which is why
;; the `*' marker had to decide its call shape from what remains of the
;; string rather than from the marker itself.
(with-current-buffer ed
  (test-equal "an empty specification runs with no arguments" 'ran
              (begin ((entry plain-command)) (*got*))))
(test-end "plain-specs")

(test-begin "define-alias")
;;--------------------------------------------------------------
;; One procedure, two names, one record - Emacs's `defalias'.
(test-equal '(#t #t)
  (list (eq? aliased-name aliased-command)
        (eq? (command-record-named "aliased-name")
             (command-record-named "aliased-command"))))
(test-end "define-alias")
