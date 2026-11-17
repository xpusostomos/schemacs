;; -*- mode: scheme; -*-
;; Tests for `(schemacs editor novice)' and the disabled-command check in
;; `run-command' (`command.scm`'s `command-execute').
;;
;; The interactive prompt itself is the pty battery's - it reads a key and
;; draws the help buffer - so what is tested here is the machinery: the
;; property, the check's three outcomes (hook, query, run), and the
;; bypass `%run-command` exists for.

(import
  (scheme base)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor command)
        define-command command-query command-record-named run-command
        %run-command *disabled-command-function*
        *command-execute--query-function*)
  (only (schemacs editor novice) en/disable-command)
  (only (schemacs editor intervals) get put)
  (only (ice-9 exceptions) exception-message))

(test-begin "schemacs_editor_novice")

(define ran #f)

(define-command (novice-test-command)
  "A command the tests disable."
  (interactive)
  (set! ran #t))

;; `en/disable-command` is the property, in both directions, and an
;; unknown name is `invalid-function`'s report with Emacs's words.
(put 'novice-test-command 'disabled #t)
(test-equal #t (get 'novice-test-command 'disabled))
(en/disable-command 'novice-test-command #f)
(test-equal #f (get 'novice-test-command 'disabled))
(test-equal "Invalid command name"
  (guard (e (#t (exception-message e)))
    (en/disable-command 'no-such-command-here #t)))

;; A plain-t disabled command with the hook installed: the hook runs and
;; the command does not.
(test-equal '(#t #f)
  (begin
    (put 'novice-test-command 'disabled #t)
    (set! ran #f)
    (let ((hooked #f))
      (parameterize ((*disabled-command-function* (lambda () (set! hooked #t)))
                     (*command-execute--query-function* #f))
        (run-command (command-record-named 'novice-test-command)))
      (list hooked ran))))

;; ...and with the hook nil the machinery is off - Emacs's
;; "all commands work normally" - so the command runs.
(test-equal #t
  (begin
    (put 'novice-test-command 'disabled #t)
    (set! ran #f)
    (parameterize ((*disabled-command-function* #f))
      (run-command (command-record-named 'novice-test-command)))
    ran))

;; The `query' form: the asker answers yes or no, and the command runs
;; only on yes. `command-query` writes `(query VERBOSE PROMPT)`.
(test-equal '(query #f #f #t)
  (begin
    (command-query 'novice-test-command "Proceed?" #f)
    (let ((disabled (get 'novice-test-command 'disabled)))
      (set! ran #f)
      (parameterize ((*disabled-command-function* #f)
                     (*command-execute--query-function*
                      (lambda (cmd) #f)))
        (run-command (command-record-named 'novice-test-command)))
      (let ((no ran))
        (set! ran #f)
        (parameterize ((*command-execute--query-function*
                        (lambda (cmd) #t)))
          (run-command (command-record-named 'novice-test-command)))
        (list (car disabled) (cadr disabled) no ran)))))

;; `%run-command` is the bypass `disabled-command-function` calls back
;; through - Emacs's `call-interactively` - so a disabled command runs
;; through it without the check.
(test-equal #t
  (begin
    (put 'novice-test-command 'disabled #t)
    (set! ran #f)
    (parameterize ((*disabled-command-function*
                    (lambda () (error "the check must not run"))))
      (%run-command (command-record-named 'novice-test-command) '()))
    ran))

(test-end "schemacs_editor_novice")
