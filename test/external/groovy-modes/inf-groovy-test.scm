;; `inf-groovy.el' (`schemacs/external/groovy-modes/inf-groovy.scm').
;;
;; The helper rows are `emacs -Q --batch''s own answers for the same
;; input: the three pure functions were read out of upstream's file and
;; evaluated there (`/tmp/ig-pick.el'), not re-implemented for the
;; measurement.  The mode rows are Emacs 31.1's buffer state after
;; `(inferior-groovy-mode)' (the process itself is comint's, and the pty
;; battery is where a real subprocess is driven).

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs buffer)
       allocate-buffer set-buffer current-buffer buffer-local-value
       get-buffer buffer-name)
 (only (schemacs editfns) insert goto-char point-max)
 (only (schemacs comint)
       comint-prompt-regexp comint-process-echoes comint-eol-on-send
       comint-use-prompt-regexp comint-input-filter comint-get-old-input)
 (only (schemacs progmodes compile)
       compilation-error-regexp-alist
       compilation-shell-minor-mode compilation-shell-minor-mode-variable)
 (only (schemacs external groovy-modes groovy-mode)
       groovy-mode *groovy-mode-hook* groovy-mode-map)
 (only (schemacs external groovy-modes inf-groovy)
       groovy-args-to-list remove-in-string groovy-input-filter
       groovy-get-old-input inferior-groovy-mode
       inferior-groovy-newline
       inferior-groovy-prompt-pattern inferior-groovy-mode-map
       inferior-groovy-error-regexp-alist inf-groovy-keys
       groovy-send-definition groovy-send-last-sexp
       groovy-send-definition-and-go groovy-send-region
       groovy-send-region-and-go switch-to-groovy groovy-load-file
       run-groovy)
 (only (schemacs keymap) keymap-lookup)
 (only (schemacs subr) kbd))

(setvbuf (current-output-port) 'none)

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (if text (insert text))
    b))

;;----------------------------------------------------------------------
;; The three pure helpers, measured on Emacs 31.1.
;;----------------------------------------------------------------------
(test-begin "schemacs_inf_groovy_helpers")

(test-equal "groovy-args-to-list splits on blanks"
  '(("--color=false") ("a" "b") ("a" "b") ("a" "b") ()
    ("") ("a" "b") ("a" "") ("+Dx=y" "z"))
  (map groovy-args-to-list
       '("--color=false" "a b" " a b" "a  b" "  " "" "a\tb" "a "
         "+Dx=y z")))

(test-equal "remove-in-string removes every match"
  '("acac" "abc" "abc" "abc" "")
  (map (lambda (p) (remove-in-string (car p) (cadr p)))
       '(("abcabc" "b") ("abc" "^x") ("a1b22c" "[0-9]+") ("abc" "z")
         ("" "a"))))

(test-equal "groovy-input-filter drops inputs of 0, 1 or 2 letters"
  '(#f #f #t #t #f #f)
  (map groovy-input-filter '("a" "ab" "abc" "a b" "" "12")))

(test-equal "groovy-get-old-input answers what follows the prompt"
  "abc"
  (let ((b (fresh "groovy:000> abc")))
    (goto-char (point-max))
    (groovy-get-old-input)))

(test-end "schemacs_inf_groovy_helpers")

;;----------------------------------------------------------------------
;; `inferior-groovy-mode' - the buffer state Emacs 31.1 leaves.
;;----------------------------------------------------------------------
(test-begin "schemacs_inf_groovy_mode")

(let ((b (fresh #f)))
  (inferior-groovy-mode)
  (test-equal "the major mode is the symbol" 'inferior-groovy-mode
              (buffer-local-value b 'major-mode #f))
  (test-equal "and the mode name is Emacs's" "Inferior Groovy"
              (buffer-local-value b 'mode-name #f))
  (test-equal "the prompt regexp is the interpreter's"
              inferior-groovy-prompt-pattern (comint-prompt-regexp))
  (test-equal "process echoes are on" #t (comint-process-echoes))
  (test-equal "eol-on-send is on" #t (comint-eol-on-send))
  (test-equal "prompt-regexp input mode is on" #t (comint-use-prompt-regexp))
  (test-equal "the input filter is groovy's" groovy-input-filter
              (comint-input-filter))
  (test-equal "the old-input reader is groovy's" groovy-get-old-input
              (comint-get-old-input))
  (test-equal "compilation-shell-minor-mode is on" #t
              (compilation-shell-minor-mode-variable))
  (test-equal "and its error regexps are the inferior's"
              inferior-groovy-error-regexp-alist
              (compilation-error-regexp-alist))
  (test-equal "the mode line shows the process' status"
              '(":%s")
              (buffer-local-value b 'mode-line-process #f))
  ;; Turning it off through the generated toggle clears the variable.
  (compilation-shell-minor-mode 'toggle)
  (test-equal "toggling the shell minor mode off clears its variable" #f
              (compilation-shell-minor-mode-variable)))

(test-end "schemacs_inf_groovy_mode")

;;----------------------------------------------------------------------
;; The two keymaps, and the hook that adds `inf-groovy-keys' to
;; `groovy-mode-map' (upstream's `eval-after-load').
;;----------------------------------------------------------------------
(test-begin "schemacs_inf_groovy_keys")

;; The hook's function runs when `groovy-mode' does (Emacs's
;; `eval-after-load' adds it to `groovy-mode-hook', it does not call it
;; at load), so the buffer is put into the mode before the map is read.
(let ((b (fresh #f)))
  (groovy-mode))

(test-equal "the nine groovy-mode keys are inf-groovy's commands"
  (list groovy-send-definition groovy-send-last-sexp groovy-send-definition
        groovy-send-definition-and-go groovy-send-region
        groovy-send-region-and-go switch-to-groovy groovy-load-file
        run-groovy)
  (map (lambda (key) (keymap-lookup groovy-mode-map (kbd key)))
       '("C-M-x" "C-x C-e" "C-c M-d" "C-c C-x" "C-c M-r" "C-c C-r"
         "C-c C-z" "C-c C-l" "C-c C-s")))

(test-equal "the inferior mode's own map has its two keys"
  (list groovy-load-file inferior-groovy-newline)
  (map (lambda (key) (keymap-lookup inferior-groovy-mode-map (kbd key)))
       '("C-c C-l" "C-c C-m")))

(test-equal "loading inf-groovy put inf-groovy-keys on groovy-mode-hook"
  #t (if (memq inf-groovy-keys (*groovy-mode-hook*)) #t #f))

(test-end "schemacs_inf_groovy_keys")
