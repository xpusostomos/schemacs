(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (ice-9 exceptions) exception-message)
 (only (schemacs editor command)
       define-command define-alias command-record-of command-procedure
       command-record-named *barf-if-buffer-read-only-function*
       *point-marker-function* *mark-marker-function*)
 (only (schemacs editor buffer)
       allocate-buffer with-current-buffer current-buffer
       set!buffer-read-only)
 (only (schemacs editor editfns) goto-char insert buffer-string
       mark-marker)
 (only (schemacs editor marker) marker-position marker-buffer)
 (only (schemacs editor simple) set-mark deactivate-mark region-active-p)
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

(define-command (region-args-command beg end)
  "A command whose specification is `r': the region's two positions."
  (interactive "r")
  (*got* (list beg end)))

(define-command (active-region-args-command beg end)
  "A command whose specification is `R': the region, or two nils."
  (interactive "R")
  (*got* (list beg end)))

(define-command (nil-arg-command arg)
  "A command whose specification is `i': always nil."
  (interactive "i")
  (*got* arg))

(define-command (region-and-prefix-command beg end uarg)
  "A command whose specification is `r\nP': region, then raw prefix."
  (interactive "r\nP")
  (*got* (list beg end uarg)))

(define-command (point-arg-command mark)
  "A command whose specification is `d': point, as a marker."
  (interactive "d")
  (*got* mark))

(define-command (mark-arg-command mark)
  "A command whose specification is `m': the mark, as a marker."
  (interactive "m")
  (*got* mark))

(define-command (bad-code-command)
  "A command with a code that is not one."
  (interactive "q")
  (*got* 'ran))

(define-command (dash-marker-command arg)
  "A command whose specification begins with `-', Lucid's no-op."
  (interactive "-P")
  (*got* arg))

(define-command (plus-marker-command)
  "A command whose specification begins with `+', which is an error."
  (interactive "+")
  (*got* 'ran))

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
;; `d' and `m' reach `editfns.c`'s two marker functions the same way.
(test-equal "and editfns installs the d and m readers" '(#t #t)
            (list (procedure? (*point-marker-function*))
                  (procedure? (*mark-marker-function*))))
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

(test-begin "region-codes")
;;--------------------------------------------------------------
;; "r": the two positions, smaller first, whichever way round point
;; and mark are.
(with-current-buffer ed
  (insert "hello world\n")
  (goto-char 1)
  (set-mark 6)
  (test-equal "r gives the region's two positions" '(1 6)
              (begin ((entry region-args-command) #f) (*got*)))
  (goto-char 12)
  (test-equal "r sorts them, point above mark" '(6 12)
              (begin ((entry region-args-command) #f) (*got*)))
  ;; "R" is the same while the region is active...
  (goto-char 1)
  (test-equal "R gives the region while it is active" '(1 6)
              (begin ((entry active-region-args-command) #f) (*got*)))
  ;; ...and two nils once it is not, where "r" signals.
  (deactivate-mark)
  (test-equal "R gives two nils for an inactive region" '(#f #f)
              (begin ((entry active-region-args-command) #f) (*got*)))
  (test-equal "and r signals for one" "The mark is not active now"
              (message-of (lambda () ((entry region-args-command) #f))))
  ;; The mark being unset is the other error, and `check_mark`'s order
  ;; asks it first - which is why it is `callint.c`'s and not
  ;; `region_limit`'s.
  (set-mark #f)
  (test-equal "r with no mark set says there is no region"
              "The mark is not set now, so there is no region"
              (message-of (lambda () ((entry region-args-command) #f))))
  (test-equal "and R does not signal at all" '(#f #f)
              (begin ((entry active-region-args-command) #f) (*got*))))
(test-end "region-codes")

(test-begin "multi-code-specs")
;;--------------------------------------------------------------
;; "r\nP": the newline separates codes and contributes nothing, so the
;; three arguments arrive in the order the codes are written.
(with-current-buffer ed
  (goto-char 1)
  (set-mark 6)
  (test-equal "a newline separates codes" '(1 6 (4))
              (begin ((entry region-and-prefix-command) '(4)) (*got*)))
  ;; "i" ignores the prefix and supplies nil.
  (test-equal "i supplies nil" #f
              (begin ((entry nil-arg-command) '(4)) (*got*)))
  ;; "-" is Lucid's no-op marker, peeled with the others.
  (test-equal "- is ignored and the rest is read" '(4)
              (begin ((entry dash-marker-command) '(4)) (*got*)))
  ;; "+" is "not used in `interactive' for ordinary commands".
  (test-equal "+ is an error" "`+' is not used in `interactive' for ordinary commands"
              (message-of (lambda () ((entry plus-marker-command) #f)))))
(test-end "multi-code-specs")

(test-begin "no-io-codes")
;;--------------------------------------------------------------
;; "d" - "Value of point. Does not do I/O" (`callint.c:502') - is a
;; *marker* at point, which the command may keep, not a position.
(with-current-buffer ed
  (goto-char 4)
  (test-equal "d gives a marker at point" 4
              (begin ((entry point-arg-command) #f) (marker-position (*got*))))
  (test-equal "and it is attached to the buffer" (current-buffer)
              (marker-buffer (*got*)))
  (goto-char 7)
  (test-equal "the marker is a point in time, so it does not follow point" 4
              (marker-position (*got*)))

  ;; "m" - "Value of mark. Does not do I/O" (`:623') - is the buffer's
  ;; *own* mark marker, so moving the returned marker moves the mark.
  (set-mark 6)
  (test-equal "m gives the mark as a marker" 6
              (begin ((entry mark-arg-command) #f) (marker-position (*got*))))
  (test-equal "and it is the buffer's own mark marker" #t
              (eq? (*got*) (mark-marker)))

  ;; The mark check is `check_mark (false)': the no-region message is
  ;; "so there is no region" and this one is not.
  (set-mark #f)
  (*got* 'none)
  (test-equal "m with no mark set says only that the mark is not set"
              "The mark is not set now"
              (message-of (lambda () ((entry mark-arg-command) #f))))
  (test-equal "and the body never ran" 'none (*got*)))
(test-end "no-io-codes")

(test-begin "bad-code")
;;--------------------------------------------------------------
;; An unread code is Emacs's error, naming the letter and its two
;; numbers - "Invalid control letter `%c' (#o%03o, #x%04x) in
;; interactive calling string" (`callint.c:744'), measured on Emacs
;; 31.1 (which renders the quotes as `‘q’' on a terminal).
(with-current-buffer ed
  (test-equal "an unread code names the letter, its octal and its hex"
              "Invalid control letter `q' (#o161, #x0071) in interactive calling string"
              (message-of (lambda () ((entry bad-code-command) #f)))))
(test-end "bad-code")
;;--------------------------------------------------------------
(test-begin "plain-specs")
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
