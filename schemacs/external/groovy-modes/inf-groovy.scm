(define-library (schemacs external groovy-modes inf-groovy)
  ;; `inf-groovy.el' from the Groovy-Emacs-Modes package - an inferior
  ;; Groovy (groovysh) process in a comint buffer, adapted upstream from
  ;; cmuscheme.el and inf-haskell.el.
  ;;
  ;; Upstream: https://github.com/Groovy-Emacs-Modes/groovy-emacs-modes
  ;; (the copy this port was read from is
  ;; `/home/chris/GITE/groovy-emacs-modes/inf-groovy.el').
  ;;
  ;; The file is ported whole.  The three spellings this tree imposes,
  ;; all named at their definitions:
  ;;
  ;;   * Emacs `setq's a buffer-local variable by name; here a variable
  ;;     with an accessor pair (`comint-prompt-regexp') is written with
  ;;     its setter, and a bare slot (`mode-line-process') with
  ;;     `set-buffer-local-value!'.
  ;;   * `read-string' in `run-groovy''s interactive form is
  ;;     `read-from-minibuffer': `(scheme base)' exports Guile's own
  ;;     `read-string', which shadows the minibuffer's prompt reader in
  ;;     an importing library (the clash recorded in AGENTS.md).
  ;;   * The keymaps are filled at the *end* of the file, because a
  ;;     `define-key' resolves its command when the form runs and the
  ;;     commands are defined below where Emacs defines the map.  The
  ;;     definitions themselves are in Emacs's order.
  ;;
  ;; Not carried: none.  Every command, variable and hook of
  ;; `inf-groovy.el' is here; `comint.el', `compile.el', `cc-cmds.el'
  ;; and `comint-get-source'/`-check-source' - the four things it
  ;; requires - are all ported.
  (export *groovysh* *groovysh-args*
          inferior-groovy-first-prompt-pattern
          inferior-groovy-prompt-pattern
          inferior-groovy-mode-hook inferior-groovy-mode-map
          inferior-groovy-error-regexp-alist
          inf-groovy-keys inferior-groovy-mode
          inferior-groovy-filter-regexp inferior-groovy-newline
          groovy-input-filter remove-in-string groovy-get-old-input
          groovy-args-to-list run-groovy groovy-proc
          groovy-send-region groovy-send-string groovy-send-definition
          groovy-send-last-sexp switch-to-groovy groovy-send-string-and-go
          groovy-send-region-and-go groovy-send-definition-and-go
          groovy-source-modes groovy-prev-l/c-dir/file groovy-load-file
          inf-groovy-load-hook groovy-buffer)

  (import
    (scheme base)
    (scheme char)
    (only (guile) getenv)
    (only (schemacs custom) define-custom)
    (only (schemacs command) define-command current-prefix-arg
          call-interactively)
    (only (schemacs buffer)
          current-buffer with-current-buffer set-buffer get-buffer
          get-buffer-create use-local-map buffer-local-value
          set-buffer-local-value! major-mode set!major-mode
          mode-name set!mode-name)
    (only (schemacs editfns)
          point point-max goto-char save-excursion save-restriction
          buffer-substring insert-before-markers format)
    (only (schemacs minibuffer) read-from-minibuffer)
    (only (schemacs files)
          read-file-name executable-find)
    (only (schemacs fileio)
          file-name-directory-part file-name-nondirectory-part)
    (only (schemacs search)
          string-match match-end re-search-forward re-search-backward)
    (only (schemacs fns) concat)
    (only (schemacs subr) add-hook run-hooks kbd)
    (only (schemacs keymap) define-key copy-keymap)
    (only (schemacs marker) move-marker)
    (only (schemacs process)
          get-buffer-process process-buffer process-mark
          accept-process-output)
    (only (schemacs window) pop-to-buffer)
    (only (schemacs comint)
          comint-mode comint-mode-map comint-check-proc make-comint
          comint-send-string comint-send-input comint-last-input-end
          comint-prompt-regexp set!comint-prompt-regexp
          comint-input-filter set!comint-input-filter
          comint-get-old-input set!comint-get-old-input
          comint-use-prompt-regexp set!comint-use-prompt-regexp
          comint-process-echoes set!comint-process-echoes
          comint-eol-on-send set!comint-eol-on-send
          comint-check-source comint-get-source)
    (only (schemacs progmodes compile)
          compilation-shell-minor-mode compilation-error-regexp-alist
          set!compilation-error-regexp-alist)
    (only (schemacs progmodes cc-cmds) c-beginning-of-defun c-end-of-defun)
    (only (schemacs core lisp) backward-sexp)
    (only (schemacs simple) push-mark)
    (only (schemacs external groovy-modes groovy-mode)
          groovy-mode-map *groovy-mode-hook*))

  (begin

    (define-custom *groovysh*
      (or (executable-find "groovysh")
          ;; Fall back to $GROOVY_HOME if the user has set that.
          (executable-find
           (format #f "~a/bin/groovysh" (or (getenv "GROOVY_HOME") ""))))
      "The path to the groovysh binary, used by `run-groovy'."
      :type 'string
      :group 'groovy)

    (define-custom *groovysh-args* "--color=false"
      "Arguments passed to groovysh when starting an inferior groovy buffer."
      :type 'string
      :group 'groovy)

    (define inferior-groovy-first-prompt-pattern "^groovy:.*> *")
    ;; ^ "First prompt regex pattern of groovy interpreter."

    (define inferior-groovy-prompt-pattern "^groovy:.*> *")
    ;; ^ "Prompt regex pattern of groovy interpreter."

    (define inferior-groovy-mode-hook (make-parameter '()))
    ;; ^ The hook; a parameter, as every hook in this tree is, so that
    ;; `add-hook` (which takes the hook object) can extend it. `run-hooks`
    ;; dereferences a parameter and merges its buffer-local half.

    (define inferior-groovy-mode-map #f)
    ;; ^ Made at the end of the file from `comint-mode-map' - a Scheme
    ;; binding resolves its commands when the form runs (the header's
    ;; ordering note).

    (define inferior-groovy-error-regexp-alist
      '(("SyntaxError: compile error\n^\\([^\\(].*\\):\\([1-9][0-9]*\\):"
         1 2)
        ("^\tfrom \\([^\\(].*\\):\\([1-9][0-9]*\\)\\(:in `.*'\\)?$" 1 2)))

    (define groovy-buffer #f)
    ;; ^ "Current groovy (actually groovysh) process buffer."  A plain
    ;; variable: nothing `let'-binds it, `run-groovy' `setq's it (which
    ;; is also what keeps the compiler from folding its reads).

    (define inferior-groovy-filter-regexp "\\`\\s *\\S ?\\S ?\\s *\\'")
    ;; ^ "Input matching this regexp are not saved on the history list."

    (define-command (inferior-groovy-newline)
      (interactive)
      (comint-send-input)
      (let ((proc (groovy-proc)))
        (comint-send-string proc "\n")))

    (define (groovy-input-filter str)
      "Don't save anything matching `inferior-groovy-filter-regexp'."
      (not (string-match inferior-groovy-filter-regexp str)))

    ;; adapted from replace-in-string in XEmacs (subr.el)
    (define (remove-in-string str regexp)
      "Remove all matches in STR for REGEXP and return the new string."
      (let ((rtn-str "") (start 0) (prev-start 0))
        (let loop ()
          (let ((match (string-match regexp str start)))
            (if match
                (begin
                  (set! prev-start start)
                  (set! start (match-end 0))
                  (set! rtn-str (concat rtn-str
                                        (substring str prev-start match)))
                  (loop))
                (concat rtn-str (substring str start)))))))

    (define (groovy-get-old-input)
      "Snarf the sexp ending at point."
      (save-excursion
        (let ((end (point)))
          (re-search-backward inferior-groovy-first-prompt-pattern)
          (remove-in-string (buffer-substring (point) end)
                            inferior-groovy-prompt-pattern))))

    (define (groovy-args-to-list string)
      (let ((where (string-match "[ \t]" string)))
        (cond ((not where) (list string))
              ((not (= where 0))
               (cons (substring string 0 where)
                     (groovy-args-to-list
                      (substring string (+ 1 where) (string-length string)))))
              (else
               (let ((pos (string-match "[^ \t]" string)))
                 (if (not pos)
                     '()
                     (groovy-args-to-list
                      (substring string pos (string-length string)))))))))

    (define-command (run-groovy cmd)
      "Run an inferior Groovy process, input and output via buffer *groovy*.
If there is a process already running in *groovy*, switch to that buffer.
With a prefix argument, prompt for the groovysh path and arguments
\(see variables `groovysh' and `groovysh-args' for the defaults).

Runs the hook `inferior-groovy-mode-hook' (after the
`comint-mode-hook' is run).  Type \\[describe-mode] in the
process buffer for a list of commands."
      ;; `inf-groovy.el:271'.  The interactive form reads the two values
      ;; only with a prefix argument, as the C's `(if current-prefix-arg
      ;; ...)' does; `read-string' there is `read-from-minibuffer' here
      ;; (the header's clash note).
      (interactive
       (list
        (format #f "~a ~a"
                (if (current-prefix-arg)
                    (read-file-name "groovysh binary: " (*groovysh*))
                    (*groovysh*))
                (if (current-prefix-arg)
                    (read-from-minibuffer "groovysh arguments: "
                                          (*groovysh-args*))
                    (*groovysh-args*)))))
      (if (not (comint-check-proc "*groovy*"))
          (let ((cmdlist (groovy-args-to-list cmd)))
            (set-buffer (apply make-comint "groovy" (car cmdlist) #f
                               (cdr cmdlist)))
            (inferior-groovy-mode)))
      (set! groovy-buffer "*groovy*")
      (pop-to-buffer "*groovy*")
      (get-buffer-process groovy-buffer))

    (define (groovy-proc)
      "Return the current groovy process.  See variable `groovy-buffer'."
      (let ((proc (get-buffer-process
                   (if (eq? (major-mode) 'inferior-groovy-mode)
                       (current-buffer)
                       groovy-buffer))))
        (or proc
            (call-interactively run-groovy))))

    (define-command (groovy-send-region start end)
      "Send the current region to the inferior Groovy process."
      (interactive "r")
      (save-excursion
        (save-restriction
          (let ((str (concat (buffer-substring start end) "\n"))
                (proc (groovy-proc)))
            (with-current-buffer (process-buffer proc)
              ;; "Wait for the prompt before sending, so the text lands
              ;; after the process' own output" - the C's `while'.
              (let loop ()
                (if (and (goto-char (comint-last-input-end))
                         (not (re-search-forward (comint-prompt-regexp) #f #t))
                         (accept-process-output proc))
                    (loop)))
              (goto-char (process-mark proc))
              (insert-before-markers str)
              ;; `(move-marker comint-last-input-end (point))' - the slot
              ;; holds a marker, and it must move with the text.
              (move-marker (comint-last-input-end) (point))
              (comint-send-string proc str)
              (comint-send-string proc "\n"))))))

    (define-command (groovy-send-string str)
      "Send a string STR to the inferior Groovy process."
      ;; `inf-groovy.el:349'.  Its `(interactive "r")' is upstream's
      ;; own (copied as it stands): calling it interactively sends the
      ;; region, not a string.
      (interactive "r")
      (save-excursion
        (save-restriction
          (let ((proc (groovy-proc)))
            (with-current-buffer (process-buffer proc)
              (let loop ()
                (if (and (goto-char (comint-last-input-end))
                         (not (re-search-forward (comint-prompt-regexp) #f #t))
                         (accept-process-output proc))
                    (loop)))
              (goto-char (process-mark proc))
              (insert-before-markers str)
              (move-marker (comint-last-input-end) (point))
              (comint-send-string proc str)
              (comint-send-string proc "\n"))))))

    (define-command (groovy-send-definition)
      "Send the current definition to the inferior Groovy process."
      (interactive)
      (save-excursion
        (c-end-of-defun)
        (let ((end (point)))
          (c-beginning-of-defun)
          (groovy-send-region (point) end))))

    (define-command (groovy-send-last-sexp)
      "Send the previous sexp to the inferior Groovy process."
      (interactive)
      (groovy-send-region (save-excursion (backward-sexp) (point)) (point)))

    (define-command (switch-to-groovy eob-p)
      "Switch to the groovy process buffer.
With argument, positions cursor at end of buffer."
      (interactive "P")
      (if (get-buffer groovy-buffer)
          (pop-to-buffer groovy-buffer)
          (error "No current process buffer, see variable `groovy-buffer'"))
      (cond (eob-p
             (push-mark)
             (goto-char (point-max)))))

    (define-command (groovy-send-string-and-go str)
      "Send the string STR to the inferior Groovy process.
Then switch to the process buffer."
      ;; upstream's `(interactive "r")', as `groovy-send-string`'s.
      (interactive "r")
      (groovy-send-string str)
      (switch-to-groovy #t))

    (define-command (groovy-send-region-and-go start end)
      "Send the current region to the inferior Groovy process.
Then switch to the process buffer."
      (interactive "r")
      (groovy-send-region start end)
      (switch-to-groovy #t))

    (define-command (groovy-send-definition-and-go)
      "Send the current definition to the inferior Groovy.
Then switch to the process buffer."
      (interactive)
      (groovy-send-definition)
      (switch-to-groovy #t))

    (define groovy-source-modes '(groovy-mode))
    ;; ^ "Used to determine if a buffer contains Groovy source code.
    ;; If it's loaded into a buffer that is in one of these major modes,
    ;; it's considered a groovy source file by groovy-load-file."

    (define groovy-prev-l/c-dir/file #f)
    ;; ^ "Caches the last (directory . file) pair."

    (define-command (groovy-load-file file-name)
      "Load a Groovy file into the inferior Groovy process."
      ;; T because LOAD needs an exact name.
      (interactive
       (list (comint-get-source "Load Groovy file: "
                                groovy-prev-l/c-dir/file
                                groovy-source-modes #t)))
      (comint-check-source file-name)
      (set! groovy-prev-l/c-dir/file
            (cons (file-name-directory-part file-name)
                  (file-name-nondirectory-part file-name)))
      (comint-send-string (groovy-proc) (concat ":l " file-name "\n")))

    (define inf-groovy-load-hook (make-parameter '()))
    ;; ^ "This hook is run when inf-groovy is loaded in." A parameter for
    ;; the reason `inferior-groovy-mode-hook' is.

    ;;------------------------------------------------------------------
    ;; The keymaps, last (the header's ordering note).  Emacs's `cond'
    ;; is one `if': the map is made once, on load.
    ;;------------------------------------------------------------------
    (unless inferior-groovy-mode-map
      (set! inferior-groovy-mode-map (copy-keymap comint-mode-map))
      (define-key inferior-groovy-mode-map (kbd "C-c C-l") groovy-load-file)
      (define-key inferior-groovy-mode-map (kbd "C-c C-m")
        inferior-groovy-newline))

    (define (inf-groovy-keys)
      "Set local key defs for inf-groovy in `groovy-mode'."
      (define-key groovy-mode-map (kbd "C-M-x") groovy-send-definition)
      (define-key groovy-mode-map (kbd "C-x C-e") groovy-send-last-sexp)
      (define-key groovy-mode-map (kbd "C-c M-d") groovy-send-definition)
      (define-key groovy-mode-map (kbd "C-c C-x")
        groovy-send-definition-and-go)
      (define-key groovy-mode-map (kbd "C-c M-r") groovy-send-region)
      (define-key groovy-mode-map (kbd "C-c C-r")
        groovy-send-region-and-go)
      (define-key groovy-mode-map (kbd "C-c C-z") switch-to-groovy)
      (define-key groovy-mode-map (kbd "C-c C-l") groovy-load-file)
      (define-key groovy-mode-map (kbd "C-c C-s") run-groovy))

    (define-command (inferior-groovy-mode)
      "Major mode for interacting with an inferior groovy (groovysh) process.

The following commands are available:
\\{inferior-groovy-mode-map}

A groovy process can be fired up with \\[run-groovy].

Customisation: Entry to this mode runs the hooks on
`comint-mode-hook' and `inferior-groovy-mode-hook' (in that order).

You can send text to the inferior groovy process from other buffers containing
Groovy source.
    `switch-to-groovy' switches the current buffer to the groovy process buffer.
    `groovy-send-definition' sends the current definition to the groovy process.
    `groovy-send-region' sends the current region to the groovy process.

    `groovy-send-definition-and-go', `groovy-send-region-and-go',
        switch to the groovy process buffer after sending their text.
For information on running multiple processes in multiple buffers, see
documentation for variable `groovy-buffer'.

Commands:
Return after the end of the process' output sends the text from the
    end of process to point.
Return before the end of the process' output copies the sexp ending at point
    to the end of the process' output, and sends it.
Delete converts tabs to spaces as it moves back.
Tab indents for groovy; with argument, shifts rest
    of expression rigidly with the current line.
\\<groovy-mode-map>
\\[prog-indent-sexp] does Tab on each line starting within following expression.
Paragraphs are separated only by blank lines.  # start comments.
If you accidentally suspend your process, use \\[comint-continue-subjob]
to continue it."
      (interactive)
      (comint-mode)
      ;; Customise in inferior-groovy-mode-hook
      (set!comint-prompt-regexp inferior-groovy-prompt-pattern)
      (set!major-mode 'inferior-groovy-mode)
      (set!mode-name "Inferior Groovy")
      (set-buffer-local-value! (current-buffer) 'mode-line-process '(":%s"))
      (use-local-map inferior-groovy-mode-map)
      (define-key inferior-groovy-mode-map (kbd "C-c C-m")
        inferior-groovy-newline)
      (set!comint-input-filter groovy-input-filter)
      (set!comint-get-old-input groovy-get-old-input)
      (set!comint-use-prompt-regexp #t)  ;; added v2
      (set!comint-process-echoes #t)     ;; added v2
      (set!comint-eol-on-send #t)        ;; added v2
      (compilation-shell-minor-mode #t)
      (set!compilation-error-regexp-alist
       inferior-groovy-error-regexp-alist)
      (run-hooks inferior-groovy-mode-hook))

    ;; `(eval-after-load 'groovy-mode (lambda () (add-hook
    ;; 'groovy-mode-hook 'inf-groovy-keys)))' - groovy-mode is imported,
    ;; so it is already loaded; the hook is the parameter the mode reads
    ;; through its getter.
    (add-hook *groovy-mode-hook* inf-groovy-keys)

    (run-hooks inf-groovy-load-hook)

    ;; A library body ends with an expression (`the last form').
    #t))
