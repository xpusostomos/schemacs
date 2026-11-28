(define-library (schemacs progmodes compile)
  ;; GNU Emacs's `lisp/progmodes/compile.el' - "run compiler as inferior of
  ;; Emacs, parse error messages" - in the file's own order.
  ;;
  ;; **Both tranches are in**: the variables, the faces, the
  ;; error-regexp data, the loc/file-structure machinery and the parser
  ;; (`compile.el:45-1930'); `compilation-get-file-structure'/
  ;; `--flush-file-structure' (`:3479'-`:3543'), which the parser needs
  ;; for every parsed message; the process runner (`compile',
  ;; `compilation-start', the sentinel, filter and exit handler); the
  ;; mode and its maps; `compilation-shell-minor-mode'/
  ;; `compilation-minor-mode'; the navigation commands
  ;; (`compilation-next-error'/`-file', `compile-goto-error',
  ;; `next-error-function') and `compilation-find-file'.
  ;;
  ;; The user-facing half is in too: `compilation-goto-in-progress-buffer',
  ;; the `%s' construct of `compilation-mode-line-errors' (through
  ;; `xdisp.scm`'s mode-line variable registry),
  ;; `compilation-mode-tool-bar-map' with Emacs's own images, the "Skip
  ;; Less Important Messages" submenu (`customize-set-variable` calls in
  ;; `:radio` items) and the
  ;; `compilation-max-output-line-length`/`compilation-hidden-output`
  ;; abbreviating path, whose `invisible` property the renderer honours.
  ;;
  ;; Named gaps, each beside its definition:
  ;;
  ;;   * `selective-display' is a per-buffer slot here (there is no
  ;;     symbol value to read) and the redisplay does not honour it, so
  ;;     a `t' selective display still draws the whole line where Emacs
  ;;     stops at ^M.  `compilation-beginning-of-line` is nevertheless
  ;;     the C's own function, arm for arm; what is missing is the
  ;;     renderer's half - `find_newline`'s selective line ends and the
  ;;     `^M` ellipsis - which `xdisp.scm` names.
  ;;   * `compilation-set-overlay-arrow` sets up nothing: what it stands
  ;;     on is a `((margin left-margin) "=>")` display spec in a
  ;;     two-column left margin, and this renderer draws neither display
  ;;     margins nor fringe bitmaps (`window-fringes` answers a
  ;;     terminal's zeros on both front ends).  The navigation still
  ;;     sets `overlay-arrow-position`; with the default
  ;;     `compilation-context-lines` nil and no left fringe Emacs draws
  ;;     no arrow either, so the default path matches.
  ;;   * `define-compilation-mode`'s `compilation-XXX` variable aliasing
  ;;     is `intern-soft`/`boundp` over the obarray.  This tree has no
  ;;     obarray (the deliberate no-universal-registry rule), and no
  ;;     derived compilation mode is ported, so the aliasing has nothing
  ;;     to find; a derived mode's port must name its variables
  ;;     explicitly or the tree must grow a `boundp` registry first.
  ;;   * the w32 arms (`compilation-w32-*`) are not ported.
  ;;
  ;; `compilation-loop' is `%compilation-loop-up'/`-down' here: Emacs's
  ;; macro splices a `while' with `setq's, and a Scheme procedure is the
  ;; only spelling this tree has for "the caller's N, PT and LAST are
  ;; updated".  Both answer `(PT N LAST MSG)', MSG last because it is
  ;; the message the caller must not lose when the loop ends.
  ;;
  ;; Two representation decisions, both the tree's conventions:
  ;;
  ;;   * `compilation-message' is Emacs's `cl-defstruct' as a record, with
  ;;     the struct's accessor names.
  ;;   * The data's HIGHLIGHT faces are written as Emacs wrote them -
  ;;     expressions in `compilation-error-regexp-alist-alist' - and
  ;;     `%compilation-eval-face' is the `(eval (car extra-item))' those
  ;;     faces stand for.  Emacs evaluates Lisp; this tree has no
  ;;     evaluator for data, and exactly four rules use an expression
  ;;     (two `compilation-face' calls, the `omake' flush and the
  ;;     `makepp' nested parse), so the evaluator covers those forms and
  ;;     signals on any other - Emacs's own "Don't know how to handle
  ;;     face" arm.
  ;;
  ;; **Lisp-1 splits**, both named where they are defined:
  ;; `compilation-mode-font-lock-keywords' is the data variable and
  ;; `compilation-mode-font-lock-keywords-function' is Emacs's function
  ;; of the same name (Emacs has one symbol with both a value and a
  ;; function); and the buffer-local-capable variables
  ;; (`compilation-error-screen-columns', `compilation-first-column',
  ;; `compilation-locs') are a global parameter plus `(name)' and
  ;; `(set!name v)' accessors, the tree's spelling for a variable with a
  ;; buffer-local half.
  ;;

  (import
    (scheme base)
    (scheme char)
    (only (guile) caddr cdddr cadddr hash-ref hash-set! hash-for-each
          hash-remove! make-hash-table inexact->exact)
    (only (schemacs custom) define-custom)
    (only (schemacs faces) defface)
    (only (schemacs command) define-command current-prefix-arg uarg->integer
          command-procedure command-record-named)
    (only (schemacs buffer)
          current-buffer with-current-buffer get-buffer get-buffer-create
          buffer-live-p buffer-name erase-buffer use-local-map
          bufferp local-variable-p kill-local-variable buffer-local-value
          set-buffer-local-value! *case-fold-search* *inhibit-read-only*
          major-mode set!major-mode mode-name set!mode-name
          kill-all-local-variables buffer-file-name
          set-buffer-modified-p buffer-read-only? set!buffer-read-only
          *kill-buffer-hook* *change-major-mode-hook*
          default-directory call-with-buffer-local
          overlays-at overlays-in make-overlay move-overlay delete-overlay
          overlay-put overlayp overlay-start overlay-get
          mark-active set!mark-active)
    (only (schemacs editfns)
          point point-min point-max goto-char save-excursion
          save-restriction widen forward-line
          line-beginning-position line-end-position bolp eobp bobp
          point-marker point-min-marker point-max-marker narrow-to-region
          buffer-size insert propertize
          message format)
    (only (schemacs cmds) beginning-of-line end-of-line forward-char
          backward-char)
    (only (schemacs simple) forward-to-indentation
          next-error-internal next-error-no-select next-error-last-buffer
          next-error-function set!next-error-function
          *next-error-highlight* *next-error-highlight-no-select*
          next-error-highlight-timer next-error-overlay-arrow-position
          push-mark buffer-disable-undo special-mode-map
          previous-error-no-select recenter-current-error
          next-error-find-buffer next-error-move-function
          set!page-delimiter)
    (only (schemacs marker)
          make-marker set-marker marker-position marker-buffer markerp
          copy-marker move-marker)
    (only (schemacs textprop)
          get-text-property put-text-property add-text-properties
          remove-text-properties text-properties-at
          remove-list-of-text-properties text-property-not-all
          next-single-property-change previous-single-property-change)
    (only (schemacs syntax) skip-chars-forward)
    (only (schemacs core text-property-search)
          text-property-search-forward prop-match-beginning)
    (prefix (only (schemacs keymap) keymap) km:)
    (only (schemacs keymap) define-key set-keymap-parent copy-keymap
          keymapp)
    (only (schemacs search)
          re-search-forward search-forward match-beginning match-end
          match-string match-string-no-properties string-match replace-match
          save-match-data)
    (only (schemacs files) expand-file-name file-truename cd save-some-buffers
          abbreviate-file-name find-file-noselect read-file-name
          revert-buffer file-expand-wildcards)
    (only (schemacs fileio)
          file-name-absolute-p file-name-directory-part
          file-name-nondirectory-part file-exists-p file-directory-p)
    (only (schemacs fns) concat nth nthcdr identity line-number-at-pos
          mapcar)
    (only (schemacs subr) delq with-silent-modifications run-mode-hooks
          run-hooks run-hook-with-args add-hook remove-hook ignore
          replace-regexp-in-string intern-soft user-error event-end kbd
          define-key-after menu-bar-separator string-lines ensure-list)
    (only (schemacs data) string-to-number aref make-local-variable)
    (only (schemacs font-lock)
          font-lock-append-text-property font-lock-add-keywords
          font-lock-remove-keywords font-lock-flush
          font-lock-register-keyword-variable!)
    (only (schemacs indentc) move-to-column current-column)
    (only (schemacs casefiddle) downcase)
    (only (schemacs character) *tab-width*)
    (only (schemacs core timer) run-with-timer run-at-time cancel-timer timer?)
    (only (schemacs process)
          get-buffer-process process-status num-processors process-buffer
          process-mark set-process-filter set-process-sentinel
          set-process-query-on-exit-flag process-exit-status
          process-query-on-exit-flag delete-process interrupt-process
          set-process-buffer
          process-send-eof start-file-process-shell-command
          *process-environment*)
    (only (schemacs comint) comint-file-name-prefix comint-mode comint-exec
          comint-term-environment comint-carriage-motion
          *comint-inhibit-carriage-motion*)
    (only (schemacs eval) funcall)
    (only (schemacs startup) command-line-normalize-file-name)
    (only (schemacs window) get-buffer-window display-buffer pop-to-buffer
          switch-to-buffer enlarge-window save-selected-window)
    (only (schemacs frame) set-window-point selected-window window-body-height
          window-list frame-root-window set-window-start window-fringes
          window-buffer window-frame window-height select-window
          *pre-command-hook* *post-command-hook*)
    (only (schemacs indentc) window-full-width?)
    (only (schemacs timefns) current-time-string float-time)
    (only (schemacs calendar time-date) format-seconds)
    (only (schemacs core derived) derived-mode-p)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs minibuffer) yes-or-no-p read-shell-command format-prompt
          completing-read make<history>)
    (only (schemacs tool-bar) tool-bar-map tool-bar-local-item)
    (only (schemacs cus-edit) customize-set-variable)
    (only (schemacs button) buttonize-region)
    (only (schemacs international mule) char-displayable-p)
    (only (schemacs callproc) call-process shell-file-name shell-command-switch)
    (only (schemacs env) substitute-env-vars)
    (only (schemacs dired) dired-other-window)
    (only (schemacs mouse) posn-set-point)
    (only (schemacs keyboard) sit-for *last-read-event*)
    (only (schemacs version) emacs-version)
    (only (schemacs insdel) *before-change-functions*)
    (only (schemacs xdisp) format-mode-line force-mode-line-update
          overlay-arrow-position overlay-arrow-string file-remote-p
          register-mode-line-variable!))

  (export
   *compilation-mode-hook* *compilation-start-hook* *compilation-window-height*
   *compilation-transform-file-match-alist* *compilation-filter-hook*
   *compilation-filter-start* *compilation-hidden-output*
   compilation-first-column set!compilation-first-column
   compilation-parse-errors-filename-function
   compilation-process-setup-function compilation-buffer-name-function
   *compilation-finish-functions* compilation-in-progress
   *compilation-error-regexp-alist* compilation-error-regexp-alist
   set!compilation-error-regexp-alist *compilation-error-case-fold-search*
   compilation-error-regexp-alist-alist compilation-directory
   compilation-directory-matcher compilation-page-delimiter
   compilation-error compilation-arguments set!compilation-arguments
   compilation-num-errors-found compilation-num-warnings-found
   compilation-num-infos-found compilation-mode-line-errors
   compilation-error-face compilation-warning-face compilation-info-face
   compilation-line-face compilation-column-face
   compilation-enter-directory-face compilation-leave-directory-face
   *compilation-error-screen-columns* compilation-error-screen-columns
   set!compilation-error-screen-columns *compilation-read-command*
   *compilation-search-all-directories* *compilation-ask-about-save*
   *compilation-save-buffers-predicate* *compilation-search-path*
   *compilation-search-extra-path* compilation-search-path
   set!compilation-search-path *compile-command*
   *compilation-disable-input* compilation-locs set!compilation-locs
   compilation-debug compilation-exit-message-function
   *compilation-environment* compilation-environment set!compilation-environment
   compile-history
   *compilation-message-face* compilation-auto-jump-to-next
   set!compilation-auto-jump-to-next *compilation-auto-jump-to-first-error*
   compilation-skip-to-next-location *compilation-skip-threshold*
   compilation-set-skip-threshold *compilation-skip-visited*
   compilation-type compilation-face
   compilation--make-cdrloc compilation--loc->col compilation--loc->line
   compilation--loc->file-struct compilation--loc->marker
   compilation--loc->visited
   compilation--make-file-struct compilation--file-struct->file-spec
   compilation--file-struct->formats compilation--file-struct->loc-tree
   compilation--make-message compilation--message? compilation--message->loc
   compilation--message->type compilation--message->end-loc
   compilation--message->rule
   compilation--flush-directory-cache compilation--previous-directory
   compilation-directory-properties compilation-assq
   compilation--file-known-p compilation-auto-jump
   compilation-error-properties compilation-beginning-of-line
   compilation-move-to-column compilation-internal-error-properties
   compilation--put-prop compilation--remove-properties
   compilation--parse-region compilation--note-type
   compilation-parse-errors compilation--parsed set!compilation--parsed
   compilation--ensure-parse compilation--flush-parse
   compilation-mode-font-lock-keywords
   compilation-mode-font-lock-keywords-function compilation-button-map
   compilation-get-file-structure compilation--flush-file-structure
   compile recompile compilation-start compilation-goto-in-progress-buffer
   compilation-buffer-name
   compilation--default-buffer-name compilation-set-window-height
   compilation-insert-annotation compilation--downcase-mode-name
   compilation-mode define-compilation-mode compilation-revert-buffer
   compilation-setup compilation--unsetup compilation-shell-minor-mode
   compilation-shell-minor-mode-variable
   compilation-minor-mode compilation-minor-mode-variable
   next-error-follow-minor-mode
   next-error-follow-minor-mode-variable
   next-error-follow-mode-post-command-hook
   compilation-handle-exit compilation-sentinel compilation-filter
   compilation--hide-output compilation--insert-abbreviated-line
   compilation-forget-errors compilation-menu-map compilation-mode-map
   compilation-minor-mode-map compilation-shell-minor-mode-map
   compilation-mode-tool-bar-map compilation-buffer-internal-p
   compilation-buffer-p compilation-next-single-property-change
   compilation-next-error compilation-previous-error compilation-next-file
   compilation-previous-file compilation-display-error kill-compilation
   compile-goto-error compilation-find-buffer compilation--update-markers
   compilation-next-error-function compilation-goto-locus
   compilation-fake-loc compilation-context-lines
   compilation-set-window compilation-set-overlay-arrow
   compilation--expand-fn compilation-find-file-1 compilation-find-file
   compilation-current-error set!compilation-current-error
   compilation-messages-start set!compilation-messages-start
   compilation--start-time set!compilation--start-time
   compilation-highlight-regexp set!compilation-highlight-regexp
   compilation-highlight-overlay *compilation-scroll-output*
   *compilation-always-kill* *compilation-max-output-line-length*
   *compilation-context-lines* *compilation-highlight-regexp*)

  (begin
    ;;----------------------------------------------------------------
    ;; The options (`compile.el:45'-`:171').
    ;;----------------------------------------------------------------

    (define-custom *compilation-mode-hook* '()
      "List of hook functions run by `compilation-mode'."
      :type 'hook)
    (define-custom *compilation-start-hook* '()
      "Hook run after starting a new compilation process.
The hook is run with one argument, the new process."
      :type 'hook)
    (define-custom *compilation-window-height* #f
      "Number of lines in a compilation window.
If nil, use Emacs default."
      :type '(choice (const :tag "Default" nil) integer)
      :group 'compilation)
    (define-custom *compilation-transform-file-match-alist*
      '(("/bin/[a-z]*sh\\'" #f))
      "Alist of regexp/replacements to alter file names in compiler messages.
If the replacement is nil, the matching message will not be considered
an error or warning.  If not nil, it should be a replacement string
for the matched regexp."
      :type '(repeat (list regexp (choice (const :tag "Not an error" nil)
                                          string)))
      :version "27.1"
      :group 'compilation)
    (define-custom *compilation-filter-hook* '()
      "Hook run after `compilation-filter' has inserted a string into the buffer.
It is called with the variable `compilation-filter-start' bound
to the position of the start of the inserted text, and point at
its end.

If Emacs lacks asynchronous process support, this hook is run
after `call-process' inserts the grep output into the buffer."
      :type 'hook :version "31.1")
    (define *compilation-filter-start* (make-parameter #f))
    (define-custom *compilation-hidden-output* #f
      "Regexp to match output from the compilation that should be hidden.
This can also be a list of regexps."
      :type '(choice regexp (repeat regexp))
      :version "29.1"
      :group 'compilation)

    ;; `compilation-first-column' is a `defvar' the C `let'-binds and a
    ;; mode may `setq-local'.  The global is a parameter and the accessor
    ;; reads the buffer's slot first, so a `parameterize' of the global
    ;; is the C's `let' (this is how the target buffer's value wins).
    (define *compilation-first-column* (make-parameter 1))
    (define (compilation-first-column)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-first-column b))
            (buffer-local-value b 'compilation-first-column
                                (*compilation-first-column*))
            (*compilation-first-column*))))
    (define (set!compilation-first-column v)
      (set-buffer-local-value! (current-buffer) 'compilation-first-column v))

    (define compilation-parse-errors-filename-function identity)
    ;; GNU Emacs's default is `ignore' (`compile.el:139').
    (define compilation-process-setup-function ignore)
    (define compilation-buffer-name-function #f)
    (define *compilation-finish-functions* (make-parameter '()))
    (define compilation-in-progress '())

    (define-command (compilation-goto-in-progress-buffer)
      "Switch to the compilation buffer."
      (interactive)
      ;; `compile.el:171'.
      ;;--------------------------------------------------------------
      (cond
       ((> (length compilation-in-progress) 1)
        (switch-to-buffer
         (completing-read
          "Several compilation buffers; switch to: "
          (mapcar (lambda (process)
                    (buffer-name (process-buffer process)))
                  compilation-in-progress)
          #f #t)))
       ((pair? compilation-in-progress)
        (switch-to-buffer (process-buffer (car compilation-in-progress))))
       (else
        (error "No ongoing compilations"))))

    (define compilation-error "error")
    ;; A `defvar' set buffer-locally by `compilation-start'.
    (define (compilation-arguments)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation-arguments #f))))
    (define (set!compilation-arguments v)
      (set-buffer-local-value! (current-buffer) 'compilation-arguments v))
    ;; Emacs's `compilation-num-*' are `defvar's set buffer-locally by
    ;; `compilation-setup'; the global default is a parameter and the
    ;; accessor is the buffer-local half.
    (define *compilation-num-errors-found* (make-parameter 0))
    (define *compilation-num-warnings-found* (make-parameter 0))
    (define *compilation-num-infos-found* (make-parameter 0))
    (define (compilation-num-errors-found)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-num-errors-found b))
            (buffer-local-value b 'compilation-num-errors-found
                                (*compilation-num-errors-found*))
            (*compilation-num-errors-found*))))
    (define (set!compilation-num-errors-found v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-num-errors-found v))
    (define (compilation-num-warnings-found)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-num-warnings-found b))
            (buffer-local-value b 'compilation-num-warnings-found
                                (*compilation-num-warnings-found*))
            (*compilation-num-warnings-found*))))
    (define (set!compilation-num-warnings-found v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-num-warnings-found v))
    (define (compilation-num-infos-found)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-num-infos-found b))
            (buffer-local-value b 'compilation-num-infos-found
                                (*compilation-num-infos-found*))
            (*compilation-num-infos-found*))))
    (define (set!compilation-num-infos-found v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-num-infos-found v))
    (define compilation-mode-line-errors
      ;; Emacs's value is `(:eval (int-to-string compilation-num-errors-found))`
      ;; - a Lisp form the C's mode-line evaluator runs.  This tree's
      ;; `:eval` holds a *procedure* (the same convention
      ;; `mode-line-position` uses), so each form is a thunk.  The
      ;; buffer being formatted is the current one during the
      ;; redisplay (`display-window!` sets it), which is what the
      ;; `compilation-num-*-found` accessors read.
      (list " ["
            (list ':propertize
                  (list ':eval
                        (lambda () (number->string
                                    (compilation-num-errors-found))))
                  'face 'compilation-error
                  'help-echo "Number of errors so far")
            " "
            (list ':propertize
                  (list ':eval
                        (lambda () (number->string
                                    (compilation-num-warnings-found))))
                  'face 'compilation-warning
                  'help-echo "Number of warnings so far")
            " "
            (list ':propertize
                  (list ':eval
                        (lambda () (number->string
                                    (compilation-num-infos-found))))
                  'face 'compilation-info
                  'help-echo "Number of informational messages so far")
            "]"))

    ;; `mode-line-process` names this variable as a construct, and a
    ;; plain `define` is not reachable by name (`xdisp.scm`'s registry).
    (register-mode-line-variable!
     'compilation-mode-line-errors
     (lambda () compilation-mode-line-errors))

    ;;----------------------------------------------------------------
    ;; The error regexp data (`compile.el:215'-`:925'), transcribed from
    ;; Emacs 31.1's own `compilation-error-regexp-alist-alist' by a
    ;; script, as the tree's data always is.  `nil' is #f and `t' is #t;
    ;; everything else is the Lisp datum.  The HIGHLIGHT expressions stay
    ;; as written and are evaluated by `%compilation-eval-face'.
    ;;----------------------------------------------------------------

    (define compilation-error-regexp-alist-alist
      '((#{absoft}# "^\\(?:[Ee]rror on \\|[Ww]arning on\\( \\)\\)?[Ll]ine[ 	]+\\([0-9]+\\)[ 	]+of[ 	]+\"?\\([a-zA-Z]?:?[^\":
]+\\)\"?:" 3 2 #f (1)) (#{ada}# "\\(warning: .*\\)? at \\([^ 
]+\\):\\([0-9]+\\)$" 2 3 #f (1)) (#{aix}# " in line \\([0-9]+\\) of file \\([^ 
]+[^. 
]\\)\\.? " 2 1) (#{ansible-fatal}# "^fatal: .*: FAILED!" #f #f #f 2 0 (0 #{compilation-error-face}#)) (#{ansible-error}# "^\\[ERROR\\]:" #f #f #f 2 0 (0 #{compilation-error-face}#)) (#{ansible-warning}# "^\\[\\(?:DEPRECATION \\)?WARNING\\]:" #f #f #f 1 0 (0 #{compilation-warning-face}#)) (#{ansible-included}# "^included: \\([^[:space:]]+\\)" 1 #f #f 0 1) (#{ansible-origin}# "^Origin: \\([^[:space:]]+\\):\\([[:digit:]]+\\):\\([[:digit:]]+\\)" 1 2 3 0 1) (#{ant}# "^[ 	]*\\(?:\\[[^] 
]+\\][ 	]*\\)\\{1,2\\}\\(\\(?:[A-Za-z]:\\)?[^: 
]+\\):\\([0-9]+\\):\\(?:\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\):\\)?\\( warning\\)?" 1 (2 . 4) (3 . 5) (6)) (#{bash}# "^\\([^: 
	]+\\): line \\([0-9]+\\):" 1 2) (#{borland}# "^\\(?:Error\\|Warnin\\(g\\)\\) \\(?:[FEW][0-9]+ \\)?\\([a-zA-Z]?:?[^:( 	
]+\\) \\([0-9]+\\)\\(?:[) 	]\\|:[^0-9
]\\)" 2 3 #f (1)) (#{python-tracebacks-and-caml}# "^[ 	]*File \\(\"?\\)\\([^,\" 
	<>]+\\)\\1, lines? \\([0-9]+\\)-?\\([0-9]+\\)?\\(?:$\\|,\\(?: characters? \\([0-9]+\\)-?\\([0-9]+\\)?:\\)?\\([ 
]Warning\\(?: [0-9]+\\)?:\\)?\\)" 2 (3 . 4) (5 . 6) (7)) (#{cmake}# "^CMake \\(?:Error\\|\\(Warning\\)\\) at \\(.*\\):\\([1-9][0-9]*\\) ([^)]+):$" 2 3 #f (1)) (#{cmake-info}# "^  \\(?: \\*\\)?\\(.*\\):\\([1-9][0-9]*\\) ([^)]+)$" 1 2 #f 0) (#{comma}# "^\"\\([^,\" 
	]+\\)\", line \\([0-9]+\\)\\(?:[(. pos]+\\([0-9]+\\))?\\)?[:.,; (-]\\( warning:\\|[-0-9 ]*(W)\\)?" 1 2 3 (4)) (#{msft}# "^ *\\([0-9]+>\\)?\\(\\(?:[a-zA-Z]:\\)?[^ :(	
][^:(	
]*\\)(\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?) ?: \\(?:see declaration\\|\\(?:warnin\\(g\\)\\|[a-z ]+\\) C[0-9]+:\\)" 2 3 4 (5)) (#{edg-1}# "^\\([^ 
]+\\)(\\([0-9]+\\)): \\(?:error\\|warnin\\(g\\)\\|remar\\(k\\)\\)" 1 2 #f (3 . 4)) (#{edg-2}# "at line \\([0-9]+\\) of \"\\([^ 
]+\\)\"$" 2 1 #f 0) (#{epc}# "^Error [0-9]+ at (\\([0-9]+\\):\\([^)
]+\\))" 2 1) (#{ftnchek}# "\\(^Warning .*\\)? line[ 
]\\([0-9]+\\)[ 
]\\(?:col \\([0-9]+\\)[ 
]\\)?file \\([^ :;
]+\\)" 4 2 3 (1)) (#{gradle-kotlin}# "^\\(?:\\(w\\)\\|\\([iv]\\)\\|e\\): file://\\(\\(?:[A-Za-z]:\\)?[^
:]+\\):\\([[:digit:]]+\\):\\([[:digit:]]+\\) " 3 4 5 (1 . 2)) (#{gradle-kotlin-legacy}# "^\\(?:\\(w\\)\\|\\([iv]\\)\\|e\\): \\(\\(?:[A-Za-z]:\\)?[^
:]+\\): (\\([[:digit:]]+\\), \\([[:digit:]]+\\)): " 3 4 5 (1 . 2)) (#{gradle-android}# "^ *ERROR:\\(?1:[^
:]+\\):\\(?2:[[:digit:]]+\\): " 1 2) (#{iar}# "^\"\\(.*\\)\",\\([0-9]+\\)\\s-+\\(?:Error\\|Warnin\\(g\\)\\)\\[[0-9]+\\]:" 1 2 #f (3)) (#{ibm}# "^\\([^( 
	]+\\)(\\([0-9]+\\):\\([0-9]+\\)) : \\(?:warnin\\(g\\)\\|informationa\\(l\\)\\)?" 1 2 3 (4 . 5)) (#{irix}# "^[-[:alnum:]_/ ]+: \\(?:\\(?:[sS]evere\\|[eE]rror\\|[wW]arnin\\(g\\)\\|[iI]nf\\(o\\)\\)[0-9 ]*: \\)?\\([^,\" 
	]+\\)\\(?:, line\\|:\\) \\([0-9]+\\):" 3 4 #f (1 . 2)) (#{java}# "^\\(?:[ 	]+at \\|==[0-9]+== +\\(?:at\\|b\\(y\\)\\)\\).+(\\([^()
]+\\):\\([0-9]+\\))$" 2 3 #f (1)) (#{javac}# "^\\(\\(?:[A-Za-z]:\\)?[^
:]+\\):\\([0-9]+\\): \\(warning: \\)?.*
.*
 *\\^$" 1 2 #{current-column}# (3)) (#{jikes-file}# "^\\(?:Found\\|Issued\\) .* compiling \"\\(.+\\)\":$" 1 #f #f 0) (#{maven}# "^\\(?:\\[\\(?:ERROR\\|\\(?1:WARNING\\)\\|\\(?2:INFO\\)\\)] \\)?\\(?3:[^
 []\\(?:[^
 :]\\| [^
/-]\\|:[^
 []\\)*\\):\\[\\(?4:[[:digit:]]+\\),\\(?5:[[:digit:]]+\\)] " 3 4 5 (1 . 2)) (#{jikes-line}# "^ *\\([0-9]+\\)\\.[ 	]+.*
 +\\(<-*>
\\*\\*\\* \\(?:Error\\|Warnin\\(g\\)\\)\\)" #f 1 #f 2 0 (2 (#{compilation-face}# (#{quote}# (3))))) (#{clang-include}# "^In file included from \\([^
:]+\\):\\([0-9]+\\):$" 1 2 #f 0) (#{gcc-include}# "^\\(?:In file included \\|                 \\|	\\)from \\([0-9]*[^0-9
]\\(?:[^
 :]\\| [^-/
]\\|:[^ 
]\\)*?\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\(?:\\([:,]\\|$\\)\\)?" 1 2 3 (#f . 4)) (#{ruby-Test::Unit}# "^    [[ ]?\\([^ (].*\\):\\([1-9][0-9]*\\)\\(\\]\\)?:in " 1 2) (#{rust-panic}# "^\\(?:    \\)?thread '.+' \\(?:([[:digit:]]+) \\)?\\(?1:panicked\\) at \\(?2:.+\\):\\(?3:[[:digit:]]+\\):\\(?4:[[:digit:]]+\\):$" 2 3 4 #f #f (1 #{compilation-error-face}#)) (#{rust}# "^\\(?:\\(?1:error\\)\\|\\(?2:warning\\)\\|\\(?3:note\\)\\)\\(?:\\[[0-9A-Z]+]\\)?:.*
 +--> \\(?4:.+\\):\\(?5:[0-9]+\\):\\(?6:[0-9]+\\)" 4 5 6 (2 . 3) #f (1 #{compilation-error-face}#) (2 #{compilation-warning-face}#) (3 #{compilation-info-face}#)) (#{ruff}# "^\\(?:[A-Z]+[0-9]+\\|[0-9a-z-]+:\\) [^ ].+
 *--> \\(?1:.+\\):\\(?2:[1-9][0-9]*\\):\\(?3:[1-9][0-9]*\\)$" 1 2 3 2) (#{lua}# "^[^	
]+?: \\([^	
]+?\\):\\([0-9]+\\): .+
stack traceback:
	" 1 2 #f 2 1) (#{lua-stack}# "^	\\(?:\\[C]:\\|\\([^	
]+?\\):\\(?:\\([0-9]+\\):\\)?\\) in " 1 2 #f 0 1) (#{gmake}# ": \\*\\*\\* \\[\\(\\(.+?\\):\\([0-9]+\\): .+\\)\\]" 2 3 #f 0 1) (#{gcc-nested-notes}# "^\\(?9:\\(?:  \\)+\\)[*•][[:space:]].*[

]+\\9  \\(?1:\\(?:[^	
 0-9]\\|[0-9]+[^
0-9]\\)\\(?:[^
 :]\\| [^
/-]\\|:[^
 ]\\)*?\\):\\(?2:[0-9]+\\):\\(?3:[0-9]+\\):" 1 2 3 0) (#{gnu}# "^\\(?:[[:alpha:]][.[:alnum:]-]+: ?\\| +|?\\)?\\(?1:\\(?:[^	
 0-9]\\|[0-9]+[^
0-9]\\)\\(?:[^
 :]\\| [^
/-]\\|:[^
 ]\\)*?\\): ?\\(?2:[0-9]+\\)\\(?:-\\(?4:[0-9]+\\)\\(?:\\.\\(?5:[0-9]+\\)\\)?\\|[.:]\\(?3:[0-9]+\\)\\(?:-\\(?:\\(?4:[0-9]+\\)\\.\\)?\\(?5:[0-9]+\\)\\)?\\)?:\\(?: *\\(?6:\\(?:FutureWarning\\|RuntimeWarning\\|W\\(?::\\|arning\\)\\|warning\\)\\)\\| *\\(?7:\\(?:I\\(?::\\|nfo\\(?:rmation\\(?:al\\)?\\)?\\)\\|Note\\|in\\(?:fo\\(?:rmation\\(?:al\\)?\\)?\\|stantiated from\\)\\|note\\|required from\\)\\|\\[ skipping .+ ]\\)\\| *\\(?:[Ee]rror\\)\\|[0-9]?\\(?:[^
0-9]\\|$\\)\\|[0-9][0-9][0-9]\\)" 1 (2 . 4) (3 . 5) (6 . 7)) (#{cucumber}# "\\(?:^\\(?:cucumber\\(?: -p [^[:space:]]+\\)?\\|     \\)\\|#\\) \\([^(].*\\):\\([1-9][0-9]*\\)" 1 2) (#{lcc}# "^\\(?:E\\|\\(W\\)\\), \\([^(
]+\\)(\\([0-9]+\\),[ 	]*\\([0-9]+\\)" 2 3 4 (1)) (#{makepp}# "^makepp\\(?:\\(?:: warning\\(:\\).*?\\|\\(: Scanning\\|: [LR]e?l?oading makefile\\|: Imported\\|log:.*?\\) \\|: .*?\\)`\\(\\(\\S +?\\)\\(?::\\([0-9]+\\)\\)?\\)['(]\\)" 4 5 #f (1 . 2) 3 (0 (#{progn}# (#{save-match-data}# (#{compilation-parse-errors}# (#{match-end}# 0) (#{line-end-position}#) (#{`}# ("`\\(\\(\\S +?\\)\\(?::\\([0-9]+\\)\\)?\\)['(]" 2 3 #f (#{,}# (#{cond}# ((#{match-end}# 1) 1) ((#{match-end}# 2) 0) (#t 2))) 1)))) (#{end-of-line}#) #f))) (#{mips-1}# " (\\([0-9]+\\)) in \\([^ 
]+\\)" 2 1) (#{mips-2}# " in \\([^()
 ]+\\)(\\([0-9]+\\))$" 1 2) (#{omake}# "^\\*\\*\\* omake: file \\(.*\\) changed" 1 #f #f #f #f (0 (#{progn}# (#{compilation--flush-file-structure}# (#{match-string}# 1)) #f))) (#{oracle}# "^\\(?:Semantic error\\|Error\\|PCC-[0-9]+:\\).* line \\([0-9]+\\)\\(?:\\(?:,\\| at\\)? column \\([0-9]+\\)\\)?\\(?:,\\| in\\| of\\)? file \\(.*?\\):?$" 3 1 2) (#{perl}# " at \\([^ 
]+\\) line \\([0-9]+\\)\\(?:[,.]\\|$\\| during global destruction\\.$\\)" 1 2) (#{php}# "\\(?:Parse\\|Fatal\\) error: \\(.*\\) in \\(.*\\) on line \\([0-9]+\\)" 2 3 #f #f) (#{rxp}# "^\\(?:Error\\|Warnin\\(g\\)\\):.*
.* line \\([0-9]+\\) char \\([0-9]+\\) of file://\\(.+\\)" 4 2 3 (1)) (#{shellcheck}# "^In \\(.+\\) line \\([0-9]+\\):" 1 2) (#{sparc-pascal-file}# "^\\w\\w\\w \\w\\w\\w +[0-3]?[0-9] +[0-2][0-9]:[0-5][0-9]:[0-5][0-9] [12][09][0-9][0-9] +\\(.*\\):$" 1 #f #f 0) (#{sparc-pascal-line}# "^\\(\\(?:E\\|\\(w\\)\\) +[0-9]+\\) line \\([0-9]+\\) -  " #f 3 #f (2) #f (1 (#{compilation-face}# (#{quote}# (2))))) (#{sparc-pascal-example}# "^ +\\([0-9]+\\) +.*
\\(\\(?:e\\|\\(w\\)\\) [0-9]+\\)-+" #f 1 #f (3) #f (2 (#{compilation-face}# (#{quote}# (3))))) (#{sun}# ": \\(?:ERROR\\|WARNIN\\(G\\)\\|REMAR\\(K\\)\\) \\(?:[[:alnum:] ]+, \\)?File = \\(.+\\), Line = \\([0-9]+\\)\\(?:, Column = \\([0-9]+\\)\\)?" 3 4 5 (1 . 2)) (#{sun-ada}# "^\\([^, 
	]+\\), line \\([0-9]+\\), char \\([0-9]+\\)[:., (-]" 1 2 3) (#{watcom}# "^[ 	]*\\(\\(?:[a-zA-Z]:\\)?[^ :(	
][^:(	
]*\\)(\\([0-9]+\\)): ?\\(?:\\(Error! E[0-9]+\\)\\|\\(Warning! W[0-9]+\\)\\):" 1 2 #f (4)) (#{4bsd}# "\\(?:^\\|::  \\|\\S ( \\)\\(/[^ 
	()]+\\)(\\([0-9]+\\))\\(?:: \\(warning:\\)?\\|$\\| ),\\)" 1 2 #f (3)) (#{gcov-file}# "^ *-: *\\(0\\):Source:\\(.+\\)$" 2 1 #f 0 #f) (#{gcov-header}# "^ *-: *\\(0\\):\\(?:Object\\|Graph\\|Data\\|Runs\\|Programs\\):.+$" #f 1 #f 0 #f) (#{gcov-nomark}# "^ *-: *\\([1-9]\\|[0-9]\\{2,\\}\\):.*$" #f 1 #f 0 #f (0 (#{quote}# #{default}#)) (1 #{compilation-line-face}#)) (#{gcov-called-line}# "^ *\\([0-9]+\\): *\\([0-9]+\\):.*$" #f 2 #f 0 #f (0 (#{quote}# #{default}#)) (1 #{compilation-info-face}#) (2 #{compilation-line-face}#)) (#{gcov-never-called}# "^ *\\(#####\\): *\\([0-9]+\\):.*$" #f 2 #f 2 #f (0 (#{quote}# #{default}#)) (1 #{compilation-error-face}#) (2 #{compilation-line-face}#)) (#{perl--Pod::Checker}# "^\\*\\*\\* \\(?:ERROR\\|\\(WARNING\\)\\).* \\(?:at\\|on\\) line \\([0-9]+\\) \\(?:.* \\)?in file \\([^ 	
]+\\)" 3 2 #f (1)) (#{perl--Test}# "^# Failed test [0-9]+ in \\([^ 	
]+\\) at line \\([0-9]+\\)" 1 2) (#{perl--Test2}# "^\\(.*NOK.*\\)?# Test [0-9]+ got:.* (\\([^ 	
]+\\) at line \\([0-9]+\\)\\( fail #[0-9]+\\)?)" 2 3) (#{perl--Test::Harness}# "^.*NOK.* \\([^ 	
]+\\) at line \\([0-9]+\\)" 1 2) (#{weblint}# "^\\([^ 	
(]+\\) (\\([0-9]+\\):\\([0-9]+\\)) " 1 2 3) (#{guile-file}# "^In \\(.+\\..+\\):
" 1 #f #f 0) (#{guile-line}# "^ *\\([0-9]+\\): *\\([0-9]+\\)" #f 1 2) (#{typescript-tsc-plain}# "^\\([^	
 ()][^
()]*\\)(\\([0-9]+\\),\\([0-9]+\\)): error [0-9A-Z]+: " 1 2 3 2) (#{typescript-tsc-pretty}# "^\\([^	
 ()][^
()]*\\):\\([0-9]+\\):\\([0-9]+\\) - error [0-9A-Z]+: " 1 2 3 2)))

    (define-custom *compilation-error-regexp-alist*
      (delq 'omake (map car compilation-error-regexp-alist-alist))
      "Alist that specifies how to match errors in compiler output.
Each elt has the form (REGEXP FILE [LINE COLUMN TYPE HYPERLINK
HIGHLIGHT...])."
      :type '(repeat (choice symbol sexp))
      :group 'compilation)

    (define (compilation-error-regexp-alist)
      ;; The defcustom with a buffer-local half: a mode that
      ;; `setq-local's it (inf-groovy does) gets its own.
      ;;--------------------------------------------------------------
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-error-regexp-alist b))
            (buffer-local-value b 'compilation-error-regexp-alist
                                (*compilation-error-regexp-alist*))
            (*compilation-error-regexp-alist*))))

    (define (set!compilation-error-regexp-alist v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-error-regexp-alist v))

    (define *compilation-error-case-fold-search* (make-parameter #f))
    ;; `compilation-directory' is a `defvar' the mode sets buffer-locally;
    ;; the global is a parameter, and the accessor is the buffer-local
    ;; half (the `compilation-first-column' shape).
    (define *compilation-directory* (make-parameter #f))
    (define (compilation-directory)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-directory b))
            (buffer-local-value b 'compilation-directory
                                (*compilation-directory*))
            (*compilation-directory*))))
    (define (set!compilation-directory v)
      (set-buffer-local-value! (current-buffer) 'compilation-directory v))
    (define compilation-directory-matcher
      '("\\(?:Entering\\|Leavin\\(g\\)\\) directory [`']\\(.+\\)'$" (2 . 1)))
    (define compilation-page-delimiter
      "^\\(?:\f\\|.*\\(?:Entering\\|Leaving\\) directory [`'].+'\n\\)+")

    (define-custom *compilation-error-screen-columns* #t
      "If non-nil, column numbers in error messages are screen columns.
Otherwise they are interpreted as character positions, with
each character occupying one column.
If this is buffer-local in the destination buffer, Emacs obeys
that value, otherwise it uses the value in the *compilation*
buffer."
      :type 'boolean
      :version "20.4"
      :group 'compilation)
    (define (compilation-error-screen-columns)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-error-screen-columns b))
            (buffer-local-value b 'compilation-error-screen-columns
                                (*compilation-error-screen-columns*))
            (*compilation-error-screen-columns*))))
    (define (set!compilation-error-screen-columns v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-error-screen-columns v))

    (define-custom *compilation-read-command* #t
      "Non-nil means \\[compile] reads the compilation command to use.
Otherwise, \\[compile] just uses the value of `compile-command'."
      :type 'boolean
      :group 'compilation)
    (define-custom *compilation-search-all-directories* #t
      "Whether further upward directories should be used when searching a file."
      :type 'boolean
      :version "28.1"
      :group 'compilation)
    (define-custom *compilation-ask-about-save* #t
      "Non-nil means \\[compile] asks which buffers to save before compiling.
Otherwise, it saves all modified buffers without asking."
      :type 'boolean
      :group 'compilation)
    (define-custom *compilation-save-buffers-predicate* #f
      "The second argument (PRED) passed to `save-some-buffers' before compiling."
      :type '(choice (const :tag "Default (save all file-visiting buffers)" nil)
                     (const :tag "Save all buffers" t)
                     function)
      :version "24.1"
      :group 'compilation)
    (define-custom *compilation-search-path* '(#f)
      "List of directories to search for source files named in error messages.
Elements should be directory names, not file names of directories.
The value nil as an element means to try the default directory."
      :type '(repeat (choice (const :tag "Default" nil)
                             (string :tag "Directory")))
      :group 'compilation)
    (define-custom *compilation-search-extra-path* '()
      "List of extra directories to search for source files named in error messages.
Elements in this list will be searched before those in
`compilation-search-path'."
      :type '(repeat (string :tag "Directory"))
      :version "31.1"
      :group 'compilation)
    ;; `(ceiling (num-processors) 1.5)' is ceil(2n/3): Emacs's own
    ;; divisor rule, so that a multi-core box does not start every core.
    (define-custom *compile-command* (format "make -k -j%d "
               (quotient (+ (* 2 (num-processors)) 2) 3))
      "Last shell command used to do a compilation; default for next compilation.

Sometimes it is useful for files to supply local values for this variable.
You might also use mode hooks to specify it in certain modes, like this:

    (add-hook \\='c-mode-hook
       (lambda ()
	 (unless (or (file-exists-p \"makefile\")
		     (file-exists-p \"Makefile\"))
           (setq-local compile-command
		(concat \"make -k \"
			(if buffer-file-name
			  (shell-quote-argument
			    (file-name-sans-extension buffer-file-name))))))))

It's often useful to leave a space at the end of the value."
      :type 'string :group 'compilation)
    (define-custom *compilation-disable-input* #f
      "If non-nil, send end-of-file as compilation process input."
      :type 'boolean
      :version "22.1"
      :group 'compilation)

    ;; A weak per-compilation-buffer hash indexed by (FILENAME . DIRECTORY).
    ;; Emacs makes it `equal' and sets it buffer-locally in
    ;; `compilation-setup'; the accessor returns the buffer's table.
    (define (compilation-locs)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation-locs #f))))
    (define (set!compilation-locs v)
      (set-buffer-local-value! (current-buffer) 'compilation-locs v))

    (define compilation-debug #f)
    (define compilation-exit-message-function
      (lambda (process-status exit-status msg) (cons msg exit-status)))
    (define-custom *compilation-environment* '()
      "List of environment variables for compilation to inherit.
Each element should be a string of the form ENVVARNAME=VALUE."
      :type '(repeat (string :tag "ENVVARNAME=VALUE"))
      :options '(("LANG=C"))
      :version "24.1"
      :group 'compilation)
    (define (compilation-environment)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-environment b))
            (buffer-local-value b 'compilation-environment
                                (*compilation-environment*))
            (*compilation-environment*))))
    (define (set!compilation-environment v)
      (set-buffer-local-value! (current-buffer) 'compilation-environment v))
    (define (compilation-search-path)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-search-path b))
            (buffer-local-value b 'compilation-search-path
                                (*compilation-search-path*))
            (*compilation-search-path*))))
    (define (set!compilation-search-path v)
      (set-buffer-local-value! (current-buffer) 'compilation-search-path v))
    ;; A history *record*, as this tree's prompts take them (`compile.el:1124'
    ;; has a list; the two shapes meet in `read-shell-command').
    (define compile-history (make<history> '()))

    ;;----------------------------------------------------------------
    ;; The faces and their variables (`compile.el:1126'-`:1205').
    ;;----------------------------------------------------------------

    (defface 'compilation-error '((t (:inherit error)))
      "Face used to highlight compiler errors.")
    (defface 'compilation-warning '((t (:inherit warning)))
      "Face used to highlight compiler warnings.")
    (defface 'compilation-info '((t (:inherit success)))
      "Face used to highlight compiler information.")
    (defface 'compilation-mode-line-fail
      '((default :inherit compilation-error)
        (((class color) (min-colors 16)) :foreground "Red1" :weight bold)
        (((class color) (min-colors 8)) :foreground "red")
        (t :inverse-video #t :weight bold))
      "Face for Compilation mode's \"error\" mode line indicator.")
    (defface 'compilation-mode-line-run '((t (:inherit compilation-warning)))
      "Face for Compilation mode's \"running\" mode line indicator.")
    (defface 'compilation-mode-line-exit
      '((default :inherit compilation-info)
        (((class color) (min-colors 16))
         :foreground "ForestGreen" :weight bold)
        (((class color)) :foreground "green" :weight bold)
        (t :weight bold))
      "Face for Compilation mode's \"exit\" mode line indicator.")
    (defface 'compilation-line-number '((t (:inherit font-lock-keyword-face)))
      "Face for displaying line numbers in compiler messages.")
    (defface 'compilation-column-number '((t (:inherit font-lock-doc-face)))
      "Face for displaying column numbers in compiler messages.")

    (define-custom *compilation-message-face* 'underline
      "Face name to use for whole messages.
Faces `compilation-error-face', `compilation-warning-face',
`compilation-info-face', `compilation-line-face' and
`compilation-column-face' get prepended to this, when applicable."
      :type 'face
      :group 'compilation)

    (define compilation-error-face 'compilation-error)
    (define compilation-warning-face 'compilation-warning)
    (define compilation-info-face 'compilation-info)
    (define compilation-line-face 'compilation-line-number)
    (define compilation-column-face 'compilation-column-number)
    (define compilation-enter-directory-face 'font-lock-function-name-face)
    (define compilation-leave-directory-face 'font-lock-builtin-face)

    (define-custom *compilation-auto-jump-to-first-error* #f
      "If non-nil, automatically jump to the first error during compilation."
      :type '(choice (const :tag "Never" nil) (const :tag "Always" t)
                     (const :tag "If location known" if-location-known)
                     (const :tag "First known location" first-known))
      :group 'compilation)
    ;; `defvar-local compilation-auto-jump-to-next' (`:1219').
    (define (compilation-auto-jump-to-next)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation-auto-jump-to-next #f))))
    (define (set!compilation-auto-jump-to-next v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-auto-jump-to-next v))

    (define compilation-skip-to-next-location #t)
    (define-custom *compilation-skip-threshold* 1
      "Compilation motion commands skip less important messages.
The value can be either 2 -- skip anything less than error, 1 --
skip anything less than warning or 0 -- don't skip any messages."
      :type '(choice (const :tag "Skip warnings and info" 2)
                     (const :tag "Skip info" 1)
                     (const :tag "No skip" 0))
      :group 'compilation)

    (define-command (compilation-set-skip-threshold level)
      "Switch the `compilation-skip-threshold' level."
      (interactive (list (modulo (if (current-prefix-arg)
                                     (uarg->integer 1 (current-prefix-arg))
                                     (+ 1 (*compilation-skip-threshold*)))
                                 3)))
      ;; `compile.el:1239'.
      ;;--------------------------------------------------------------
      (*compilation-skip-threshold* level)
      (message "Skipping %s"
               (cond ((= (*compilation-skip-threshold*) 0) "Nothing")
                     ((= (*compilation-skip-threshold*) 1) "Info messages")
                     ((= (*compilation-skip-threshold*) 2) "Warnings and info")
                     (else ""))))

    (define-custom *compilation-skip-visited* #f
      "Compilation motion commands skip visited messages if this is t."
      :type 'boolean
      :group 'compilation)

    (define (compilation-type type)
      ;; `compile.el:1262'.
      ;;--------------------------------------------------------------
      (let ((end (cdr type)))
        (or (and (car type) (match-end (car type)) 1)
            (and (integer? end) (match-end end) 0)
            2)))

    (define (compilation-face type)
      ;; `compile.el:1267'.
      ;;--------------------------------------------------------------
      (let ((typ (compilation-type type)))
        (cond ((eqv? typ 1) compilation-warning-face)
              ((eqv? typ 0) compilation-info-face)
              ((eqv? typ 2) compilation-error-face)
              (else #f))))

    ;;----------------------------------------------------------------
    ;; The loc machinery (`compile.el:1304'-`:1368').
    ;;----------------------------------------------------------------

    (define (compilation--make-cdrloc line file-struct marker)
      (list line file-struct marker #f))
    (define (compilation--loc->col loc) (car loc))
    (define (compilation--loc->line loc) (nth 1 loc))
    (define (compilation--loc->file-struct loc) (nth 2 loc))
    (define (compilation--loc->marker loc) (nth 3 loc))
    (define (compilation--loc->visited loc) (nthcdr 5 loc))

    (define (compilation--make-file-struct file-spec formats . loc-tree)
      ;; Emacs's FORMATS is always a list - it is `apply'ed over
      ;; (`compilation-find-file'), so nil must be the empty list and
      ;; not this tree's `#f'.  The parser hands over nil for a rule
      ;; with no explicit format list.
      (cons file-spec (cons (if (pair? formats) formats '())
                            (if (pair? loc-tree) (car loc-tree) '()))))
    (define (compilation--file-struct->file-spec fs) (car fs))
    (define (compilation--file-struct->formats fs) (cadr fs))
    (define (compilation--file-struct->loc-tree fs) (cdr fs))

    (define-record-type <compilation--message>
      (compilation--make-message loc type end-loc rule)
      compilation--message?
      (loc compilation--message->loc)
      (type compilation--message->type)
      (end-loc compilation--message->end-loc)
      (rule compilation--message->rule))

    (define (%compilation-pos x)
      ;; `(< pos marker)' is Elisp's marker coercion.
      (if (markerp x) (marker-position x) x))

    ;; Emacs's `car'/`cdr' of nil are nil; Guile's raise.  The loc tree
    ;; is a short list at its leaf (a file with no line yet is
    ;; `(FILE-SPEC FORMATS)'), so these are used wherever the C reads a
    ;; list that may end early.
    (define (%c-car x) (if (pair? x) (car x) #f))
    (define (%c-cdr x) (if (pair? x) (cdr x) '()))
    (define (%c-cadr x) (%c-car (%c-cdr x)))
    (define (%c-cddr x) (%c-cdr (%c-cdr x)))

    (define (compilation--previous-directory-cache)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation--previous-directory-cache
                                   #f))))
    (define (set!compilation--previous-directory-cache v)
      (set-buffer-local-value! (current-buffer)
                               'compilation--previous-directory-cache v))

    (define (compilation--flush-directory-cache start end)
      ;; `compile.el:1358'.
      ;;--------------------------------------------------------------
      (let ((cache (compilation--previous-directory-cache)))
        (cond
         ((or (not cache) (<= (%compilation-pos (car cache)) start)) #f)
         ((or (not (cdr cache))
              (not (marker-buffer (cdr cache)))
              (<= (%compilation-pos (cdr cache)) start))
          (set-marker (car cache) start))
         (else (set!compilation--previous-directory-cache #f)))))

    (define (compilation--previous-directory pos)
      "Like (previous-single-property-change POS 'compilation-directory), but faster."
      ;; `compile.el:1368'.
      ;;--------------------------------------------------------------
      (let ((cache (compilation--previous-directory-cache)))
        (if (and cache
                 (< pos (%compilation-pos (car cache)))
                 (or (not (cdr cache))
                     (< (%compilation-pos (cdr cache)) pos)))
            ;; No need to call previous-single-property-change.
            (cdr cache)
            (let* ((cache* (and cache
                                (<= (%compilation-pos (car cache)) pos)
                                (car cache)))
                   (prev (previous-single-property-change
                          pos 'compilation-directory #f cache*))
                   (res
                    (cond
                     ((not cache*)
                      (set!compilation--previous-directory-cache
                       (cons (copy-marker pos)
                             (if prev (copy-marker prev) #f)))
                      prev)
                     ((and prev (= prev (%compilation-pos cache*)))
                      (set-marker (car (compilation--previous-directory-cache))
                                  pos)
                      (cdr (compilation--previous-directory-cache)))
                     (else
                      (set-marker cache* pos)
                      (set-cdr! (compilation--previous-directory-cache)
                                (if prev (copy-marker prev) #f))
                      prev))))
              (if (markerp res) (marker-position res) res)))))

    (define (compilation-directory-properties idx leave)
      ;; `compile.el:1406'.
      ;;--------------------------------------------------------------
      (if leave (set! leave (match-end leave)))
      ;; find previous stack, and push onto it, or if `leave' pop it
      (let ((dir (compilation--previous-directory (match-beginning 0))))
        (set! dir (if dir (or (get-text-property (- dir 1)
                                                 'compilation-directory)
                              (get-text-property dir 'compilation-directory))
                      #f))
        (list 'font-lock-face (if leave
                                  compilation-leave-directory-face
                                  compilation-enter-directory-face)
              'compilation-directory
              (if leave
                  (or (and dir (cdr dir)) '(#f)) ; nil only isn't a change
                  (cons (match-string-no-properties idx) dir))
              ;; Place a `compilation-message' everywhere we change
              ;; text-properties so `compilation--remove-properties' can
              ;; know what to remove.
              'compilation-message (compilation--make-message #f 0 #f #f)
              'mouse-face 'highlight
              'keymap compilation-button-map
              'help-echo "mouse-2: visit destination directory")))

    ;; Data type `reverse-ordered-alist' retriever (`compile.el:1435').
    (define (compilation-assq key alist)
      ;;--------------------------------------------------------------
      (let* ((l1 alist)
             (l2 (cdr l1)))
        (car
         (if (if (not key)
                 ;; `'()` is true in Scheme; Emacs's `(null key)` arm
                 ;; tests the same thing this `pair?' does.
                 (if (pair? l2) (not (caar l2)) #f)
                 (begin
                   (let loop ()
                     (when (if (pair? l2)
                               (if (caar l2) (< key (caar l2)) #t)
                               #f)
                       (set! l1 l2)
                       (set! l2 (cdr l1))
                       (loop)))
                   (if (pair? l2) (eq? key (caar l2)) #f)))
             l2
             (begin
               (set-cdr! l1 (cons (list key) l2))
               (cdr l1))))))

    (define (%compilation-symbol-value sym)
      ;; The `symbol-value' the data's faces go through.
      ;;--------------------------------------------------------------
      (cond ((eq? sym 'compilation-line-face) compilation-line-face)
            ((eq? sym 'compilation-error-face) compilation-error-face)
            ((eq? sym 'compilation-info-face) compilation-info-face)
            ((eq? sym 'compilation-warning-face) compilation-warning-face)
            (else (error "Void variable: ~a" sym))))

    (define (%compilation-eval-face face)
      ;; The `(eval (car extra-item))' of `compilation-parse-errors'
      ;; (`compile.el:1856') over the forms the rules actually contain.
      ;;--------------------------------------------------------------
      (cond
       ((symbol? face) (%compilation-symbol-value face))
       ((and (pair? face) (eq? (car face) 'quote)) (cadr face))
       ((and (pair? face) (eq? (car face) 'compilation-face))
        (let ((arg (cadr face)))
          (compilation-face
           (if (and (pair? arg) (eq? (car arg) 'quote)) (cadr arg) arg))))
       ;; omake's `(progn (compilation--flush-file-structure (match-string 1)) nil)'.
       ((and (pair? face)
             (eq? (car face) 'progn)
             (pair? (cdr face))
             (pair? (cadr face))
             (eq? (car (cadr face)) 'compilation--flush-file-structure))
        (compilation--flush-file-structure (match-string 1))
        #f)
       ;; makepp's nested parse.
       ((and (pair? face)
             (eq? (car face) 'progn)
             (pair? (cdr face))
             (pair? (cadr face))
             (eq? (car (cadr face)) 'save-match-data))
        (save-match-data
          (compilation-parse-errors
           (match-end 0) (line-end-position)
           (list "`\\(\\(\\S +?\\)\\(?::\\([0-9]+\\)\\)?\\)['(]" 2 3 #f
                 (cond ((match-end 1) 1)
                       ((match-end 2) 0)
                       (else 2))
                 1)))
        (end-of-line 1)
        #f)
       (else (error "Don't know how to handle face ~a" face))))

    (define (%compilation-functionp x)
      ;; Emacs's `functionp' over the values the rule data holds: the
      ;; procedures this tree writes and the one function *symbol* Emacs
      ;; data names (`javac''s COLUMN is `current-column').
      ;;--------------------------------------------------------------
      (or (procedure? x) (eq? x 'current-column)))

    (define (%compilation-funcall x)
      (cond ((procedure? x) (x))
            ((eq? x 'current-column) (current-column))
            (else (error "Invalid function: ~a" x))))

    (define (compilation--file-known-p)
      "Say whether the file under point can be found."
      ;; `compile.el:1447'.
      ;;--------------------------------------------------------------
      (let ((msg (get-text-property (point) 'compilation-message)))
        (if (not msg)
            #f
            (let ((loc (compilation--message->loc msg)))
              (if (not loc)
                  #f
                  (let ((elem
                         (compilation-find-file-1
                          (point-marker)
                          (caar (compilation--loc->file-struct loc))
                          (%c-cadr (car (compilation--loc->file-struct loc)))
                          (compilation--file-struct->formats
                           (compilation--loc->file-struct loc)))))
                    (and elem (car elem))))))))

    (define (compilation-auto-jump buffer pos)
      ;; `compile.el:1459'.
      ;;--------------------------------------------------------------
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (goto-char pos)
          (let ((win (get-buffer-window buffer 0)))
            (if win (set-window-point win pos)))
          (when (compilation-auto-jump-to-next)
            (cond
             ((eq? (*compilation-auto-jump-to-first-error*)
                   'if-location-known)
              (when (compilation--file-known-p) (compile-goto-error)))
             ((eq? (*compilation-auto-jump-to-first-error*) 'first-known)
              (let loop ()
                (let ((match (and (not (compilation--file-known-p))
                                  (text-property-search-forward
                                   'compilation-message #f #f #t))))
                  (when match
                    (goto-char (prop-match-beginning match))
                    (loop))))
              (when (compilation--file-known-p) (compile-goto-error)))
             (else (compile-goto-error)))))))

    ;;----------------------------------------------------------------
    ;; Error properties and the parser (`compile.el:1485'-`:1930').
    ;;----------------------------------------------------------------

    (define (compilation-error-properties file line end-line col end-col type
                                          fmt rule)
      ;; `compile.el:1485'.
      ;;--------------------------------------------------------------
      (if (text-property-not-all (match-beginning 0) (point)
                                 'compilation-message #f)
          ;; Emacs's `unless' answers nil here, which the caller tests;
          ;; Scheme's `unless' would answer the unspecified value (true).
          #f
          (begin
            (if file
                ;; Emacs's `(when (stringp (setq file ...)) ...)': the
                ;; body runs only when the parsed name is a string.
                (begin
                  (set! file (if (%compilation-functionp file)
                                 (%compilation-funcall file)
                                 (match-string-no-properties file)))
                  (when (string? file)
                    (let ((dir
                           (if (file-name-absolute-p file)
                               #f
                               (let ((pos (compilation--previous-directory
                                           (match-beginning 0))))
                                 (if pos
                                     (or (get-text-property
                                          (- pos 1) 'compilation-directory)
                                         (get-text-property
                                          pos 'compilation-directory))
                                     #f)))))
                      (set! file (cons file (and dir (car dir)))))))
                ;; This message didn't mention one, get it from previous
                (let ((prev-pos
                       ;; Find the previous message.
                       (previous-single-property-change (point)
                                                        'compilation-message)))
                  (if prev-pos
                      ;; Get the file structure that belongs to it.
                      (let* ((prev
                              (or (get-text-property (- prev-pos 1)
                                                     'compilation-message)
                                  (get-text-property prev-pos
                                                     'compilation-message)))
                             (prev-file-struct
                              (and prev
                                   (compilation--loc->file-struct
                                    (compilation--message->loc prev)))))
                        ;; Construct FILE . DIR from that.
                        (if prev-file-struct
                            (set! file (cons (caar prev-file-struct)
                                             (%c-cadr
                                              (car prev-file-struct))))))
                      #f)
                  (unless file
                    (set! file '("*unknown*")))))
            ;; All of these fields are optional, get them only if we have
            ;; an index, and it matched some part of the message.
            (set! line
                  (if (%compilation-functionp line)
                      (%compilation-funcall line)
                      (and line
                           (begin (set! line (match-string-no-properties line))
                                  line)
                           (string-to-number line))))
            (set! end-line
                  (if (%compilation-functionp end-line)
                      (%compilation-funcall end-line)
                      (and end-line
                           (begin
                             (set! end-line
                                   (match-string-no-properties end-line))
                             end-line)
                           (string-to-number end-line))))
            (set! col
                  (if (%compilation-functionp col)
                      (%compilation-funcall col)
                      (and col
                           (begin (set! col (match-string-no-properties col))
                                  col)
                           (string-to-number col))))
            (set! end-col
                  (let ((ec (if (%compilation-functionp end-col)
                                (%compilation-funcall end-col)
                                (and end-col (match-beginning end-col)
                                     (string-to-number
                                      (match-string-no-properties
                                       end-col))))))
                    (if ec
                        (+ 1 ec)     ; Add one to get an exclusive bound.
                        (and end-line -1))))
            (if (pair? type)            ; not a static type
                (let ((end (cdr type)))
                  (set! type (or (and (car type) (match-end (car type)) 1)
                                 (and (integer? end) (match-end end) 0)
                                 2))))
            ;; Remove matches like /bin/sh and do other file name transforms.
            (save-match-data
              (let ((file-name
                     (and (pair? file)
                          (not (bufferp (car file)))
                          (if (pair? (cdr file))
                              (expand-file-name (car file) (cdr file))
                              (car file)))))
                (when file-name
                  (let loop ((rules (*compilation-transform-file-match-alist*)))
                    (when (pair? rules)
                      (let* ((rule (car rules))
                             (regexp (car rule))
                             (replacement (cadr rule)))
                        (if (string-match regexp file-name)
                            (if replacement
                                (set! file
                                      (list (replace-match replacement
                                                           #f #f file-name)))
                                (set! file #f))
                            (loop (cdr rules)))))))))
            (if (not file)
                ;; If we ignored all the files with errors on this line,
                ;; then return nil.
                #f
                (begin
                  (when (and (compilation-auto-jump-to-next)
                             (>= type (*compilation-skip-threshold*)))
                    (kill-local-variable 'compilation-auto-jump-to-next)
                    (run-with-timer 0 #f compilation-auto-jump
                                    (current-buffer) (match-beginning 0)))
                  (compilation-internal-error-properties
                   file line end-line col end-col type fmt rule))))))

    (define (compilation-beginning-of-line . args)
      "Like `beginning-of-line', but accounts for lines hidden by `selective-display'."
      ;; `compile.el:1578`, arm for arm:
      ;;
      ;;   (if (or (not (eq selective-display t)) (null n) (= n 1))
      ;;       (beginning-of-line n)
      ;;     (re-search-forward "[\n\r]" nil 'end (1- n))
      ;;     (if (< n 0) (beginning-of-line)))
      ;;
      ;; **`selective-display` is the buffer slot**, read the way every
      ;; per-buffer variable without an accessor pair is
      ;; (`buffer-invisibility-spec` is the same).  Emacs's default is
      ;; nil, which is the `#f` default here.  The *motion* is exact;
      ;; what the redisplay does with the variable is the renderer's
      ;; named gap (see the header), not this function's.
      ;;--------------------------------------------------------------
      (let ((n (if (pair? args) (car args) #f)))
        (if (or (not (eq? (buffer-local-value (current-buffer)
                                              'selective-display #f)
                          #t))
                (not n)
                (= n 1))
            (beginning-of-line n)
            (begin
              (re-search-forward "[\n\r]" #f 'end (- n 1))
              (if (< n 0) (beginning-of-line))))))

    (define (compilation-move-to-column col screen)
      "Go to column COL on the current line.
If SCREEN is non-nil, columns are screen columns, otherwise, they are
just char-counts."
      ;; `compile.el:1589'.
      ;;--------------------------------------------------------------
      (set! col (- col (compilation-first-column)))
      (if screen
          ;; Presumably, the compilation tool doesn't know about our
          ;; current `tab-width' setting, so it probably assumed 8-wide
          ;; TABs (bug#21038).
          (parameterize ((*tab-width* 8))
            (move-to-column (max col 0)))
          (goto-char (min (+ (line-beginning-position) col)
                          (line-end-position)))))

    (define (compilation-internal-error-properties file line end-line col
                                                   end-col type fmts rule)
      "Get the meta-info that will be added as text-properties."
      ;; `compile.el:1600'.
      ;;--------------------------------------------------------------
      (unless file (set! file '("*unknown*")))
      (let* ((file-struct (compilation-get-file-structure file fmts))
             ;; Get first already existing marker (if any has one, all have
             ;; one).  Do this first, as the compilation-assq's may create
             ;; new nodes.
             (marker-line
              (%c-cadr (compilation--file-struct->loc-tree file-struct)))
             (marker0 (and marker-line
                           (compilation--loc->marker
                            (%c-cadr marker-line))))
             (screen-columns (compilation-error-screen-columns))
             (first-column (compilation-first-column)))
        (let ((marker marker0)
              (marker-l marker-line)
              (end-marker #f)
              (loc #f)
              (end-loc #f))
          (if (not (and marker (marker-buffer marker)))
              (set! marker #f)          ; no valid marker for this file
              (begin
                (unless line (set! line 1)) ; normalize no linenumber to line 1
                ;; find nearest loc, at least one exists
                (let loop ((rest (%c-cddr
                                  (compilation--file-struct->loc-tree
                                   file-struct))))
                  (when (pair? rest)
                    (let ((x (car rest)))
                      (if (> (car x) line)     ; Still bigger.
                          (begin (set! marker-l x)
                                 (loop (cdr rest)))
                          (begin
                            (if (> (- (or (car marker-l) 1) line)
                                   (- line (car x))) ; Current line is nearer.
                                (set! marker-l x))
                            #f)))))
                (set! marker (compilation--loc->marker (%c-cadr marker-l)))
                (set! marker-l (or (car marker-l) 1))
                (parameterize ((*compilation-first-column* first-column))
                  (with-current-buffer (marker-buffer marker)
                    (let ((screen-columns
                           ;; Obey the compilation-error-screen-columns of
                           ;; the target buffer if its major mode set it
                           ;; buffer-locally.
                           (if (local-variable-p
                                'compilation-error-screen-columns
                                (current-buffer))
                               (compilation-error-screen-columns)
                               screen-columns)))
                      (save-excursion
                        (save-restriction
                          (widen)
                          (goto-char (marker-position marker))
                          ;; Set end-marker if appropriate and go to line.
                          (if (not (or end-col end-line))
                              (compilation-beginning-of-line
                               (- line marker-l -1))
                              (begin
                                (compilation-beginning-of-line
                                 (- (or end-line line) marker-l -1))
                                (if (or (not end-col) (< end-col 0))
                                    (end-of-line 1)
                                    (compilation-move-to-column
                                     end-col screen-columns))
                                (set! end-marker (point-marker))
                                (when end-line
                                  (compilation-beginning-of-line
                                   (- line end-line -1)))))
                          (if col
                              (compilation-move-to-column col screen-columns)
                              (forward-to-indentation 0))
                          (set! marker (point-marker)))))))))
          (set! loc (compilation-assq
                     line (compilation--file-struct->loc-tree file-struct)))
          (set! end-loc
                (if end-line
                    (compilation-assq
                     end-col (compilation-assq
                              end-line
                              (compilation--file-struct->loc-tree
                               file-struct)))
                    (if end-col             ; use same line element
                        (compilation-assq end-col loc)
                        #f)))
          (set! loc (compilation-assq col loc))
          ;; If they are new, make the loc(s) reference the file they point to.
          (unless (pair? (cdr loc))
            (set-cdr! loc (compilation--make-cdrloc line file-struct
                                                    marker)))
          (if end-loc
              (unless (pair? (cdr end-loc))
                (set-cdr! end-loc
                          (compilation--make-cdrloc (or end-line line)
                                                    file-struct
                                                    end-marker))))
          ;; Must start with face
          (list 'font-lock-face (*compilation-message-face*)
                'compilation-message
                (compilation--make-message loc type end-loc rule)
                'help-echo (if col
                               "mouse-2: visit this file, line and column"
                               (if line
                                   "mouse-2: visit this file and line"
                                   "mouse-2: visit this file"))
                'keymap compilation-button-map
                'mouse-face 'highlight))))

    (define (compilation--put-prop matchnum prop val)
      ;; `compile.el:1704'.
      ;;--------------------------------------------------------------
      (when (and (integer? matchnum) (match-beginning matchnum))
        (put-text-property
         (match-beginning matchnum) (match-end matchnum)
         prop val)))

    (define (compilation--remove-properties . args)
      ;; `compile.el:1710'.
      ;;--------------------------------------------------------------
      (let ((start (if (pair? args) (car args) #f))
            (end (and (pair? args) (pair? (cdr args)) (cadr args))))
        (with-silent-modifications
          (unless start (set! start (point-min)))
          (unless end (set! end (point-max)))
          (compilation--flush-directory-cache start end)
          (let loop ((start start))
            (let ((next (or (next-single-property-change
                             start 'compilation-message #f end)
                            end)))
              (when (get-text-property start 'compilation-message)
                (remove-list-of-text-properties
                 start next
                 '(compilation-debug compilation-directory
                   compilation-message font-lock-face help-echo
                   mouse-face)))
              (when (< next end)
                (loop next)))))))

    (define (compilation--parse-region start end)
      ;; `compile.el:1737'.
      ;;--------------------------------------------------------------
      (goto-char end)
      (unless (bolp)
        ;; We generally don't like to parse partial lines.
        (unless (eobp) (error "Assertion failed: (eobp)"))
        (let ((proc (get-buffer-process (current-buffer))))
          (when (and proc (memq (process-status proc) '(run open)))
            (set! end (line-beginning-position)))))
      (compilation--remove-properties start end)
      ;; compilation-directory-matcher is the only part that really needs
      ;; to be parsed sequentially.
      (goto-char start)
      (let loop ()
        (when (re-search-forward (car compilation-directory-matcher) end #t)
          (compilation--flush-directory-cache (match-beginning 0)
                                              (match-end 0))
          (when compilation-debug
            (font-lock-append-text-property
             (match-beginning 0) (match-end 0)
             'compilation-debug
             (vector 'directory compilation-directory-matcher)))
          (let elts ((rest (cdr compilation-directory-matcher)))
            (when (pair? rest)
              (let ((elt (car rest)))
                (add-text-properties (match-beginning (car elt))
                                     (match-end (car elt))
                                     (compilation-directory-properties
                                      (car elt) (cdr elt))))
              (elts (cdr rest))))
          (loop)))
      (compilation-parse-errors start end))

    (define (compilation--note-type type)
      "Note that a new message with severity TYPE was seen.
This updates the appropriate variable used by the mode-line."
      ;; `compile.el:1769'.
      ;;--------------------------------------------------------------
      (cond ((eqv? type 0)
             (set!compilation-num-infos-found
              (+ (compilation-num-infos-found) 1)))
            ((eqv? type 1)
             (set!compilation-num-warnings-found
              (+ (compilation-num-warnings-found) 1)))
            ((eqv? type 2)
             (set!compilation-num-errors-found
              (+ (compilation-num-errors-found) 1)))))

    (define (compilation-parse-errors start end . rules)
      "Parse errors between START and END.
The errors recognized are the ones specified in RULES which default
to `compilation-error-regexp-alist' if RULES is nil."
      ;; `compile.el:1777'.
      ;;--------------------------------------------------------------
      (parameterize ((*case-fold-search*
                      (*compilation-error-case-fold-search*)))
        (let ((omake-included
               (memq 'omake (compilation-error-regexp-alist)))
              (rule-items (if (pair? rules) rules
                              (compilation-error-regexp-alist))))
          (let loop-rules ((rest rule-items))
            (when (pair? rest)
              (let* ((rule-item (car rest))
                     (item (if (symbol? rule-item)
                               (cdr (assq rule-item
                                          compilation-error-regexp-alist-alist))
                               rule-item))
                     (pat (car item))
                     (file (nth 1 item))
                     (line (nth 2 item))
                     (col (nth 3 item))
                     (type (nth 4 item))
                     (rule (and (symbol? rule-item) rule-item))
                     (end-line #f)
                     (end-col #f)
                     (fmt #f)
                     (props #f))

                ;; omake reports some error indented, so skip the indentation.
                (when (and omake-included pat)
                  (if (string-match "\\`\\([^^]\\|\\^\\( \\*\\|\\[\\)\\)" pat)
                      #f ;; Not anchored or anchored but already allows
                         ;; empty spaces.
                      (set! pat (concat "^\\(?:      \\)?"
                                        (substring pat 1)))))

                (if (and (pair? file) (not (%compilation-functionp file)))
                    (begin (set! fmt (cdr file)) (set! file (car file))))
                (if (and (pair? line) (not (%compilation-functionp line)))
                    (begin
                      (set! end-line
                            (let ((e (cdr line)))
                              (and (or (integer? e)
                                       (%compilation-functionp e))
                                   e)))
                      (set! line (car line))))
                (if (and (pair? col) (not (%compilation-functionp col)))
                    (begin
                      (set! end-col
                            (let ((e (cdr col)))
                              (and (or (integer? e)
                                       (%compilation-functionp e))
                                   e)))
                      (set! col (car col))))

                (unless (or (not (nth 5 item)) (integer? (nth 5 item)))
                  (error "HYPERLINK should be an integer: ~s" (nth 5 item)))

                (goto-char start)
                (let loop-search ()
                  (when (and pat (re-search-forward pat end #t))
                    (set! props
                          (compilation-error-properties
                           file line end-line col end-col (or type 2)
                           fmt rule))
                    (when props
                      (when file
                        (let ((this-type (if (pair? type)
                                             (compilation-type type)
                                             (or type 2))))
                          (compilation--note-type this-type)
                          (compilation--put-prop
                           file 'font-lock-face
                           (%compilation-symbol-value
                            (aref (vector 'compilation-info-face
                                          'compilation-warning-face
                                          'compilation-error-face)
                                  this-type)))))
                      (compilation--put-prop line 'font-lock-face
                                             compilation-line-face)
                      (compilation--put-prop end-line 'font-lock-face
                                             compilation-line-face)
                      (compilation--put-prop col 'font-lock-face
                                             compilation-column-face)
                      (compilation--put-prop end-col 'font-lock-face
                                             compilation-column-face)
                      ;; Obey HIGHLIGHT.
                      (let loop-extra ((extra (nthcdr 6 item)))
                        (when (pair? extra)
                          (let* ((extra-item (car extra))
                                 (mn (car extra-item)))
                            (when (match-beginning mn)
                              (let ((face (%compilation-eval-face
                                           (cadr extra-item))))
                                (cond
                                 ((not face) #f)
                                 ((or (symbol? face) (string? face))
                                  (put-text-property
                                   (match-beginning mn) (match-end mn)
                                   'font-lock-face face))
                                 ((and (pair? face)
                                       (eq? (car face) 'face)
                                       (or (symbol? (cadr face))
                                           (string? (cadr face))))
                                  (compilation--put-prop mn 'font-lock-face
                                                         (cadr face))
                                  (add-text-properties
                                   (match-beginning mn) (match-end mn)
                                   (cddr face)))
                                 (else
                                  (error "Don't know how to handle face ~a"
                                         face)))))
                            (loop-extra (cdr extra)))))
                      (let ((mn (or (nth 5 item) 0)))
                        (when compilation-debug
                          (font-lock-append-text-property
                           (match-beginning 0) (match-end 0)
                           'compilation-debug (vector 'std item props)))
                        (add-text-properties
                         (match-beginning mn) (match-end mn)
                         (cddr props))
                        (font-lock-append-text-property
                         (match-beginning mn) (match-end mn)
                         'font-lock-face (cadr props))))
                    (loop-search)))
                (loop-rules (cdr rest))))))))

    (define (compilation--parsed)
      (let ((b (current-buffer)))
        (if b (buffer-local-value b 'compilation--parsed -1) -1)))
    (define (set!compilation--parsed v)
      (set-buffer-local-value! (current-buffer) 'compilation--parsed v))

    (define (compilation--ensure-parse limit)
      "Make sure the text has been parsed up to LIMIT."
      ;; `compile.el:1888'.
      ;;--------------------------------------------------------------
      (save-excursion
        (goto-char limit)
        (set! limit (line-beginning-position 2))
        (unless (markerp (compilation--parsed))
          ;; We use a marker for compilation--parsed so that users (such
          ;; as grep.el) don't need to flush-parse when they modify the
          ;; buffer in a way that impacts buffer positions but does not
          ;; require re-parsing.
          (set!compilation--parsed
           (set-marker (make-marker)
                       (save-excursion
                         (goto-char (point-min))
                         (text-property-search-forward 'compilation-annotation)
                         ;; If we have no end marker, this will be
                         ;; `point-min' still.
                         (point)))))
        (when (< (%compilation-pos (compilation--parsed)) limit)
          (let ((start (max (%compilation-pos (compilation--parsed))
                            (point-min))))
            (move-marker (compilation--parsed) limit)
            (goto-char start)
            (forward-line 0) ; Not line-beginning-position: ignore (comint)
                             ; fields.
            (let loop ()
              (when (and (not (bobp))
                         (get-text-property (- (point) 1)
                                            'compilation-multiline))
                (forward-line -1)
                (loop)))
            (with-silent-modifications
              (compilation--parse-region
               (point) (%compilation-pos (compilation--parsed)))))))
      #f)

    (define (compilation--flush-parse start end)
      "Mark the region between START and END for re-parsing."
      ;; `compile.el:1918'.
      ;;--------------------------------------------------------------
      (if (markerp (compilation--parsed))
          (move-marker (compilation--parsed)
                       (min start (%compilation-pos (compilation--parsed))))))

    (define (compilation-mode-font-lock-keywords-function)
      "Return expressions to highlight in Compilation mode."
      ;; `compile.el:1923'.  The name is Emacs's function; the *data*
      ;; variable of the same name is below (a Lisp-1 split).
      ;;--------------------------------------------------------------
      (append
       (list (list compilation--ensure-parse))
       compilation-mode-font-lock-keywords))

    ;; The `compilation-mode-font-lock-keywords' defvar's contents
    ;; (`compile.el:1165'-`:1190'), with the faces as the values they
    ;; evaluate to and the one form (`(compilation-face '(4 . 3))') as a
    ;; procedure, which is what this tree's font-lock calls.
    (define compilation-mode-font-lock-keywords
      (list
       ;; configure output lines.
       (list "^[Cc]hecking \\(?:[Ff]or \\|[Ii]f \\|[Ww]hether \\(?:to \\)?\\)?\\(.+\\)\\.\\.\\. *\\(?:(cached) *\\)?\\(\\(yes\\(?: .+\\)?\\)\\|no\\|\\(.*\\)\\)$"
             (list 1 'font-lock-variable-name-face)
             (list 2 (lambda () (compilation-face '(4 . 3)))))
       ;; Command output lines.  Recognize `make[n]:' lines too.
       (list "^\\([[:alnum:]_/.+-]+\\)\\(\\[\\([0-9]+\\)\\]\\)?[ \t]*:"
             (list 1 'font-lock-function-name-face)
             (list 3 compilation-line-face #f #t))
       (cons " --?o\\(?:utfile\\|utput\\)?[= ]\\(\\S +\\)" 1)
       (list "^Compilation \\(finished\\).*"
             (list 0 '(face nil compilation-message nil help-echo nil
                       mouse-face nil) #t)
             (list 1 compilation-info-face))
       (list "^Compilation \\(exited abnormally\\|interrupt\\|killed\\|terminated\\|segmentation fault\\)\\(?:.*with code \\([0-9]+\\)\\)?.*"
             (list 0 '(face nil compilation-message nil help-echo nil
                       mouse-face nil) #t)
             (list 1 compilation-error-face)
             (list 2 compilation-error-face #f #t))))

    ;; The map the parser's property lists name.  Its bindings are added
    ;; with the commands that carry them (`compile-goto-error' and the
    ;; button actions), in the map's own section later in the file.
    (define compilation-button-map (km:keymap '*compilation-button-map*))


    ;;----------------------------------------------------------------
    ;; Running the compilation (`compile.el:1937'-`:2351', `:2451'-
    ;; `:2747', and the navigation of `:2844'-`:3543').  The maps are at
    ;; the end of this section because a Scheme keymap holds the
    ;; command *procedures* and must be built after they exist.
    ;;----------------------------------------------------------------

    (define-custom *compilation-scroll-output* #f
      "Non-nil to scroll the *compilation* buffer window as output appears.

The value `first-error' stops scrolling at the first error, and leaves
point on its location in the *compilation* buffer."
      :type '(choice (const :tag "No scrolling" nil)
                     (const :tag "Scroll compilation output" t)
                     (const :tag "Stop scrolling at the first error"
                            first-error))
      :version "20.3"
      :group 'compilation)

    (define-custom *compilation-always-kill* #f
      "If t, always kill a running compilation process before starting a new one.
If nil, ask to kill it."
      :type 'boolean
      :version "24.3"
      :group 'compilation)

    (define-custom *compilation-max-output-line-length* 400
      "Output lines that are longer than this value will be hidden.
If nil, don't hide anything."
      :type '(choice (const :tag "Hide nothing" nil) integer)
      :version "29.1"
      :group 'compilation)

    (define-custom *compilation-context-lines* #f
      "Display this many lines of leading context before the current message.
If nil or t, and the left fringe is displayed, don't scroll the
compilation output window; an arrow in the left fringe points to
the current message."
      :type '(choice integer
                     (const :tag "Scroll window when no fringe" nil)
                     (const :tag "No window scrolling" t))
      :version "22.1"
      :group 'compilation)

    (define-custom *compilation-highlight-regexp* #f
      "Regexp to match the error in the line indicated by \\[next-error].
This variable's value can also be a function, which will be called with
the error message as its argument and should return a regexp to match
or nil."
      :type '(choice regexp (const :tag "No highlighting" nil) function)
      :group 'compilation)
    (define (compilation-highlight-regexp)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-highlight-regexp b))
            (buffer-local-value b 'compilation-highlight-regexp
                                (*compilation-highlight-regexp*))
            (*compilation-highlight-regexp*))))
    (define (set!compilation-highlight-regexp v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-highlight-regexp v))

    ;; `defvar' `compilation-highlight-overlay' (`compile.el:1177').
    (define compilation-highlight-overlay #f)

    ;; `defvar-local compilation--start-time' (`compile.el:2059').
    (define (compilation--start-time)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation--start-time #f))))
    (define (set!compilation--start-time v)
      (set-buffer-local-value! (current-buffer) 'compilation--start-time v))

    (define (compilation--downcase-mode-name mode)
      "Downcase the name of major MODE, even if MODE is not a string."
      ;; `compile.el:2062'.
      ;;--------------------------------------------------------------
      (downcase (format-mode-line mode)))

    (define (compilation-buffer-name name-of-mode mode-command name-function)
      "Return the name of a compilation buffer to use."
      ;; `compile.el:2012'.
      ;;--------------------------------------------------------------
      ((or name-function
           compilation-buffer-name-function
           compilation--default-buffer-name)
       name-of-mode))

    (define (compilation--default-buffer-name name-of-mode)
      ;; `compile.el:2026'.
      ;;--------------------------------------------------------------
      (cond ((or (eq? (major-mode) (intern-soft name-of-mode))
                 (eq? (major-mode)
                      (intern-soft (concat name-of-mode "-mode"))))
             (buffer-name))
            (else (concat "*" (downcase name-of-mode) "*"))))

    (define (compilation--update-in-progress-mode-line)
      ;; `compile.el:2046'.
      ;;--------------------------------------------------------------
      (unless compilation-in-progress (force-mode-line-update #t)))

    (define (compilation-insert-annotation . args)
      "Insert ARGS at point, adding the `compilation-annotation' text property."
      ;; `compile.el:2051'.
      ;;--------------------------------------------------------------
      (let ((start (point)))
        (apply insert args)
        (put-text-property start (point) 'compilation-annotation #t)))

    (define (compilation-read-command command)
      ;; `compile.el:1929'.
      ;;--------------------------------------------------------------
      (read-shell-command "Compile command: " command compile-history))

    (define-command (compile command comint)
      "Compile the program including the current buffer.  Default: run `make'."
      (interactive
       (list
        (let ((cmd (*compile-command*)))
          (if (or (*compilation-read-command*) (current-prefix-arg))
              (compilation-read-command cmd)
              cmd))
        (pair? (current-prefix-arg))))
      ;; `compile.el:1937'.
      ;;--------------------------------------------------------------
      (unless (equal? command (*compile-command*))
        (*compile-command* command))
      (save-some-buffers (not (*compilation-ask-about-save*))
                         (*compilation-save-buffers-predicate*))
      (*compilation-directory* (default-directory))
      (compilation-start command comint))

    (define-command (recompile edit-command)
      "Re-compile the program including the current buffer."
      (interactive (list (current-prefix-arg)))
      ;; `compile.el:1981'.
      ;;--------------------------------------------------------------
      (save-some-buffers (not (*compilation-ask-about-save*))
                         (*compilation-save-buffers-predicate*))
      (call-with-buffer-local
       'default-directory (or (compilation-directory) (default-directory))
       (lambda ()
         (let ((command (*compile-command*))
               (args (compilation-arguments)))
           (when edit-command
             (set! command (compilation-read-command
                            (or (and args (car args)) command)))
             (when args (set-car! args command)))
           (apply compilation-start (or args (list command)))))))

    ;; `default-directory' is a function here; `let' of a parameter's
    ;; name would shadow it, so the dynamic binding is a `parameterize'
    ;; of the buffer's directory slot instead: set it around the body.
    ;; (This is the tree's spelling of Emacs's `(let ((default-directory
    ;; ...)) ...)' - the C's variable is the buffer's own.)
    (define-syntax with-default-directory
      (syntax-rules ()
        ((_ dir body ...)
         (call-with-buffer-local 'default-directory dir
                                 (lambda () body ...)))))

    (define (compilation-start command . rest)
      "Run compilation command COMMAND (low level interface)."
      ;; `compile.el:2069'.
      ;;
      ;; The MODE argument may be a symbol naming a command or `t' for
      ;; comint.  FILE-EXPAND-WILDCARDS is the `cd' branch's globbing
      ;; disambiguation (bug#15417): `cd build-*' uses the one directory
      ;; it matches, and leaves the pattern alone when the glob is
      ;; ambiguous.
      ;;--------------------------------------------------------------
      (let* ((mode (if (pair? rest) (car rest) #f))
             (name-function (and (pair? rest) (pair? (cdr rest))
                                 (cadr rest)))
             (highlight-regexp (and (pair? rest) (pair? (cdr rest))
                                    (pair? (cddr rest)) (caddr rest)))
             (continue (and (pair? rest) (pair? (cdr rest))
                            (pair? (cddr rest)) (pair? (cdddr rest))
                            (cadddr rest)))
               (continue-pos #f))
        (unless mode (set! mode 'compilation-mode))
        (let* ((name-of-mode (if (eq? mode #t)
                                 "compilation"
                                 (replace-regexp-in-string
                                  "-mode\\'" "" (symbol->string mode))))
               (thisdir (default-directory))
               (thisenv (compilation-environment))
               (thissearchpath (append (*compilation-search-extra-path*)
                                       (compilation-search-path)))
               (outwin #f) (outbuf #f))
          (set! outbuf
                (get-buffer-create
                 (compilation-buffer-name name-of-mode mode name-function)))
          (with-current-buffer outbuf
            ;; A new buffer inherits `default-directory' from the buffer
            ;; that made it in Emacs (`get-buffer-create'); this tree's
            ;; `get-buffer-create' leaves the slot unset, so the
            ;; compilation buffer records the caller's directory here,
            ;; which is also the directory the process starts in.
            (set-buffer-local-value! (current-buffer) 'default-directory
                                     thisdir)
            (let ((comp-proc (get-buffer-process (current-buffer))))
              (if comp-proc
                  (if (or (not (eq? (process-status comp-proc) 'run))
                          (eq? (process-query-on-exit-flag comp-proc) #f)
                          (yes-or-no-p
                           (format "A %s process is running; kill it? "
                                   name-of-mode)))
                      (guard (e (else #t))
                        (interrupt-process comp-proc)
                        (sit-for 1)
                        (delete-process comp-proc))
                      (error "Cannot have two processes in `~a' at once"
                             (buffer-name)))))
            ;; first transfer directory from where M-x compile was called
            (set!compilation-directory thisdir)
            ;; Make compilation buffer read-only.  The filter can still
            ;; write it.  Clear out the compilation buffer.
            (parameterize ((*inhibit-read-only* #t))
            (call-with-buffer-local
             'default-directory thisdir
             (lambda ()
              ;; Then evaluate a cd command if any, but don't perform it
              ;; yet, else start-command would do it again through the
              ;; shell.
              (cd (if (not (string-match
                            "\\`\\s *cd\\(?:\\s +\\(\\S +?\\|'[^']*'\\|\"\\(?:[^\"`$\\]\\|\\\\.\\)*\"\\)\\)?\\s *[;&\n]"
                            command))
                      (default-directory)
                      (if (not (match-end 1))
                          "~"
                          (if (char=? (string-ref command (match-beginning 1))
                                      #\')
                              (substring command (+ (match-beginning 1) 1)
                                         (- (match-end 1) 1))
                              (if (char=? (string-ref command
                                                      (match-beginning 1))
                                          #\")
                                  (replace-regexp-in-string
                                   "\\\\\\(.\\)" "\\1"
                                   (substring command
                                              (+ (match-beginning 1) 1)
                                              (- (match-end 1) 1)))
                                  ;; Try globbing as well (bug#15417).
                                  (let* ((substituted-dir
                                          (substitute-env-vars
                                           (match-string 1 command)))
                                         ;; FIXME: This also tries to
                                         ;; expand `*' that were
                                         ;; introduced by the envvar
                                         ;; expansion!
                                         (expanded-dir
                                          (file-expand-wildcards
                                           substituted-dir)))
                                    (if (= (length expanded-dir) 1)
                                        (car expanded-dir)
                                        substituted-dir)))))))
              (if continue
                  (begin
                    ;; Save the point so we can restore it.
                    (set! continue-pos (point))
                    (goto-char (point-max)))
                  (erase-buffer))
              ;; Select the desired mode.
              (if (not (eq? mode #t))
                  (begin
                    (buffer-disable-undo)
                    (funcall (if (procedure? mode)
                                 mode
                                 (command-procedure
                                  (command-record-named mode)))))
                  (begin
                    (set!buffer-read-only (current-buffer) #f)
                    (comint-mode)
                    (compilation-shell-minor-mode 1)))
              ;; Remember the original dir, so we can use it when we
              ;; recompile.
              (set!compilation-directory thisdir)
              (set!compilation-environment thisenv)
              (set!compilation-search-path thissearchpath)
              (if highlight-regexp
                  (set!compilation-highlight-regexp highlight-regexp))
              (if (or (*compilation-auto-jump-to-first-error*)
                      (eq? (*compilation-scroll-output*) 'first-error))
                  (set!compilation-auto-jump-to-next #t))
              (when (= (buffer-size) 0)
                ;; Output a mode setter, for saving and later reloading
                ;; this buffer.
                (compilation-insert-annotation
                 "-*- mode: " name-of-mode
                 "; default-directory: "
                 ;; Emacs's `(prin1-to-string (abbreviate-file-name ...))':
                 ;; the printer is not ported; `%S' is its string arm.
                 (format "%S" (abbreviate-file-name (default-directory)))
                 " -*-\n"))
              (compilation-insert-annotation
               (format "%s started at %s\n\n"
                       (mode-name)
                       (substring (current-time-string) 0 19))
               command "\n")
              (set!compilation--start-time (float-time))
              (set! thisdir (default-directory)))))
            (set-buffer-modified-p #f))
          ;; Pop up the compilation buffer.
          (set! outwin (display-buffer outbuf '(#f (allow-no-window . #t))))
          (with-current-buffer outbuf
            (parameterize ((*process-environment*
                            (append
                             (compilation-environment)
                             (or (and (derived-mode-p 'comint-mode)
                                      (comint-term-environment))
                                 '())
                             (list (format "INSIDE_EMACS=%s,compile"
                                           emacs-version))
                             ;; Some external programs (like "git grep")
                             ;; use a pager; defeat that.
                             (list "PAGER=")
                             (list-copy (*process-environment*)))))
              (set!compilation-arguments
               (list command mode name-function highlight-regexp))
              (set-buffer-local-value! (current-buffer) 'revert-buffer-function
                                       compilation-revert-buffer)
              (when (and outwin (not continue)
                         (not (*compilation-scroll-output*)))
                (set-window-start outwin (point-min)))
              ;; Position point as the user will see it.
              (let ((desired-visible-point
                     (cond (continue-pos continue-pos)
                           ((*compilation-scroll-output*) (point-max))
                           (else (point-min)))))
                (goto-char desired-visible-point)
                (when (and outwin (not (eq? outwin (selected-window))))
                  (set-window-point outwin desired-visible-point)))
              ;; The setup function is called before
              ;; compilation-set-window-height so it can set the
              ;; compilation-window-height buffer locally.
              (if compilation-process-setup-function
                  (compilation-process-setup-function))
              (and outwin (compilation-set-window-height outwin))
              ;; Start the compilation.
              (if #t                   ; `make-process' exists here
                  (let ((proc
                         (if (eq? mode #t)
                             (get-buffer-process
                              (comint-exec
                               outbuf (compilation--downcase-mode-name
                                       (mode-name))
                               shell-file-name #f
                               (list shell-command-switch command)))
                             (start-file-process-shell-command
                              (compilation--downcase-mode-name (mode-name))
                              outbuf command))))
                    ;; Make the buffer's mode line show process state.
                    ;; (This tree's mode line does not draw
                    ;; `mode-line-process' - named in the header.)
                    (set-buffer-local-value!
                     (current-buffer) 'mode-line-process
                     '((:propertize ":%s" face compilation-mode-line-run)
                       compilation-mode-line-errors))
                    (when (*compilation-always-kill*)
                      (set-process-query-on-exit-flag proc #f))
                    (set-process-sentinel proc compilation-sentinel)
                    (unless (eq? mode #t)
                      ;; Keep the comint filter, since it's needed for
                      ;; proper handling of the prompts.
                      (set-process-filter proc compilation-filter))
                    ;; Use (point-max) here so that output comes in
                    ;; after the initial text, regardless of where the
                    ;; user sees point.
                    (set-marker (process-mark proc) (point-max) outbuf)
                    (when (*compilation-disable-input*)
                      (guard (e (else #t))
                        (process-send-eof proc)))
                    (run-hook-with-args (*compilation-start-hook*) proc)
                    (compilation--update-in-progress-mode-line)
                    (set! compilation-in-progress
                          (cons proc compilation-in-progress)))
                  ;; No asynchronous processes available.
                  (begin
                    (message "Executing `%s'..." command)
                    (set-buffer-local-value!
                     (current-buffer) 'mode-line-process
                     '((:propertize ":run" face compilation-mode-line-run)
                       compilation-mode-line-errors))
                    (force-mode-line-update)
                    (sit-for 0)          ; Force redisplay
                    (save-excursion
                      ;; Insert the output at the end, after the initial
                      ;; text, regardless of where the user sees point.
                      (goto-char (point-max))
                      (parameterize ((*inhibit-read-only* #t)
                                     (*compilation-filter-start* (point)))
                       (let ((status (call-process shell-file-name #f outbuf
                                                   #f "-c" command)))
                        (run-hooks (*compilation-filter-hook*))
                        (cond ((number? status)
                               (compilation-handle-exit
                                'exit status
                                (if (zero? status)
                                    "finished\n"
                                    (format "exited abnormally with code %d\n"
                                            status))))
                              ((string? status)
                               (compilation-handle-exit
                                'signal status (concat status "\n")))
                              (else
                               (compilation-handle-exit
                                'bizarre status status))))))
                    (set-buffer-modified-p #f)
                    (message "Executing `%s'...done" command)))
              ;; Now finally cd to where the shell started make/grep/...
              (set! thisdir (default-directory))
              (when (*compilation-scroll-output*)
                (goto-char (point-max)))))
          ;; Make it so the next C-x ` will use this buffer.
          (set! next-error-last-buffer outbuf)
          outbuf)))

    (define (compilation-set-window-height window)
      "Set the height of WINDOW according to `compilation-window-height'."
      ;; `compile.el:2339'.
      ;;--------------------------------------------------------------
      (let ((height (buffer-local-value (window-buffer window)
                                        'compilation-window-height #f)))
        (and height
             (window-full-width? window)
             ;; If window is alone in its frame, aside from a
             ;; minibuffer, don't change its height.
             (not (eq? window (frame-root-window
                               (window-frame window))))
             ;; Stef said that doing the saves in this order is safer.
             (save-excursion
               (save-selected-window
                 (select-window window)
                 (enlarge-window (- height (window-height window))))))))

    ;;----------------------------------------------------------------
    ;; Navigation (`compile.el:2844'-`:3543').
    ;;----------------------------------------------------------------

    (define (compilation-buffer-internal-p)
      "Test if inside a compilation buffer."
      ;; `compile.el:2844'.
      ;;--------------------------------------------------------------
      (local-variable-p 'compilation-locs (current-buffer)))

    (define (compilation-buffer-p buffer)
      "Test if BUFFER is a compilation buffer."
      ;; `compile.el:2848'.
      ;;--------------------------------------------------------------
      (with-current-buffer buffer
        (compilation-buffer-internal-p)))

    (define (compilation-next-single-property-change position prop . rest)
      ;; `compile.el:2884'.
      ;;--------------------------------------------------------------
      (let ((object (and (pair? rest) (car rest)))
            (limit (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (parsed #f))
        (let loop ((position position))
          (compilation--ensure-parse
           (begin (set! parsed (max (%compilation-pos (compilation--parsed))
                                    (or limit (point-max))))
                  parsed))
          (let ((res (next-single-property-change position prop object limit)))
            (if (and (or (not res) (eq? res limit))
                     (< position (or limit (point-max))))
                (loop parsed)
                res)))))

    (define (%compilation-loop-up n pt different-file loc last limit)
      ;; The macro `compilation-loop` (`compile.el:2853') in its forward
      ;; direction: loop while N > 0, counting down one per counted
      ;; message.  The second `or` arm in the C *moves PT* to the next
      ;; property change when the position found carries no message -
      ;; the message run's end does not - so the advance is explicit.
      ;;--------------------------------------------------------------
      (let loop ((n n) (pt pt) (last last) (msg #f))
        (if (<= n 0)
            (list pt n last msg)
            (let* ((opt pt)
                   (pt (or (compilation-next-single-property-change
                            pt 'compilation-message #f limit)
                           (if (or (eq? (get-text-property
                                         limit 'compilation-message)
                                        (get-text-property opt
                                                           'compilation-message))
                                   (eq? pt opt))
                               (user-error
                                (if (get-buffer-process (current-buffer))
                                    "No more ~as yet"
                                    "Past last ~a")
                                compilation-error)
                               limit))))
              (let ((msg (get-text-property pt 'compilation-message)))
                (unless msg
                  (let ((p (compilation-next-single-property-change
                            pt 'compilation-message #f limit)))
                    (when p
                      (set! pt p)
                      (set! msg (get-text-property p
                                                   'compilation-message)))))
                (unless msg
                  (user-error
                   (if (get-buffer-process (current-buffer))
                       "No more ~as yet"
                       "Past last ~a")
                   compilation-error))
                (let* ((this-file (compilation--loc->file-struct
                                   (compilation--message->loc msg)))
                       (skip? (or (< (compilation--message->type msg)
                                     (*compilation-skip-threshold*))
                                  (if different-file (eq? last this-file) #f)
                                  (if (*compilation-skip-visited*)
                                      (compilation--loc->visited
                                       (compilation--message->loc msg))
                                      #f)
                                  (if compilation-skip-to-next-location
                                      (eq? (compilation--message->loc msg)
                                           loc)
                                      #f))))
                  (loop (if skip? n (- n 1)) pt
                        (if different-file this-file last) msg)))))))

    (define (%compilation-loop-down n pt different-file loc last limit)
      ;; The macro `compilation-loop` in its backward direction: loop
      ;; while N < 0, counting up.
      ;;--------------------------------------------------------------
      (let loop ((n n) (pt pt) (last last) (msg #f))
        (if (>= n 0)
            (list pt n last msg)
            (let* ((opt pt)
                   (pt (or (previous-single-property-change
                            pt 'compilation-message #f limit)
                           (if (or (eq? (get-text-property
                                         limit 'compilation-message)
                                        (get-text-property opt
                                                           'compilation-message))
                                   (eq? pt opt))
                               (user-error "Moved back before first ~a"
                                           compilation-error)
                               limit))))
              (let ((msg (get-text-property pt 'compilation-message)))
                (unless msg
                  (let ((p (previous-single-property-change
                            pt 'compilation-message #f limit)))
                    (when p
                      (set! pt p)
                      (set! msg (get-text-property p
                                                   'compilation-message)))))
                (unless msg
                  (user-error "Moved back before first ~a"
                              compilation-error))
                (let* ((this-file (compilation--loc->file-struct
                                   (compilation--message->loc msg)))
                       (skip? (or (< (compilation--message->type msg)
                                     (*compilation-skip-threshold*))
                                  (if different-file (eq? last this-file) #f)
                                  (if (*compilation-skip-visited*)
                                      (compilation--loc->visited
                                       (compilation--message->loc msg))
                                      #f)
                                  (if compilation-skip-to-next-location
                                      (eq? (compilation--message->loc msg)
                                           loc)
                                      #f))))
                  (loop (if skip? n (+ n 1)) pt
                        (if different-file this-file last) msg)))))))

    (define-command (compilation-next-error n different-file pt)
      "Move point to the next error in the compilation buffer."
      (interactive (list (if (current-prefix-arg)
                             (uarg->integer 1 (current-prefix-arg))
                             1)
                         #f #f))
      ;; `compile.el:2898'.
      ;;--------------------------------------------------------------
      (unless (compilation-buffer-p (current-buffer))
        (error "Not in a compilation buffer"))
      (unless pt (set! pt (point)))
      (compilation--ensure-parse pt)
      (let* ((msg (get-text-property pt 'compilation-message))
             (loc (and msg (compilation--message->loc msg)))
             (last #f))
        (if (= n 0)
            (unless (or msg             ; find message near here
                        (begin
                          (set! msg (get-text-property
                                     (max (- pt 1) (point-min))
                                     'compilation-message))
                          msg))
              (set! pt (previous-single-property-change
                        pt 'compilation-message #f (line-beginning-position)))
              (unless (begin
                        (set! msg (get-text-property
                                   (max (- (or pt (point-min)) 1) (point-min))
                                   'compilation-message))
                        msg)
                (set! pt (compilation-next-single-property-change
                          (or pt (point)) 'compilation-message #f
                          (line-end-position)))
                (unless (begin
                          (set! msg (get-text-property
                                     (or pt (point)) 'compilation-message))
                          msg)
                  (set! pt (point)))))
            (begin
            (set! last (compilation--loc->file-struct loc))
            (if (>= n 0)
                (let ((res (%compilation-loop-up n pt different-file loc last
                                                 (point-max))))
                  (set! pt (list-ref res 0))
                  (set! last (list-ref res 2))
                  (set! msg (list-ref res 3)))
                (begin
                  ;; Don't move "back" to message at or before point.
                  ;; Pass an explicit (point-min) to make sure pt is
                  ;; non-nil.
                  (set! pt (previous-single-property-change
                            pt 'compilation-message #f (point-min)))
                  (let ((res (%compilation-loop-down
                              n pt different-file loc last (point-min))))
                    (set! pt (list-ref res 0))
                    (set! last (list-ref res 2))
                    (set! msg (list-ref res 3)))))))
        (goto-char pt)
        (or msg (user-error "No ~a here" compilation-error))))

    (define-command (compilation-previous-error n)
      "Move point to the previous error in the compilation buffer."
      (interactive (list (if (current-prefix-arg)
                             (uarg->integer 1 (current-prefix-arg))
                             1)))
      ;; `compile.el:2956'.
      ;;--------------------------------------------------------------
      (compilation-next-error (- n) #f #f))

    (define-command (compilation-next-file n)
      "Move point to the next error for a different file than the current one."
      (interactive (list (if (current-prefix-arg)
                             (uarg->integer 1 (current-prefix-arg))
                             1)))
      ;; `compile.el:2965'.
      ;;--------------------------------------------------------------
      (compilation-next-error n #t #f))

    (define-command (compilation-previous-file n)
      "Move point to the previous error for a different file than the current one."
      (interactive (list (if (current-prefix-arg)
                             (uarg->integer 1 (current-prefix-arg))
                             1)))
      ;; `compile.el:2971'.
      ;;--------------------------------------------------------------
      (compilation-next-file (- n)))

    (define-command (compilation-display-error)
      "Display the source for current error in another window."
      (interactive)
      ;; `compile.el:2977'.
      ;;--------------------------------------------------------------
      (set!compilation-current-error (point))
      (next-error-no-select 0))

    (define-command (kill-compilation)
      "Kill the process made by the \\[compile] or \\[grep] commands."
      (interactive)
      ;; `compile.el:2983'.
      ;;--------------------------------------------------------------
      (let ((buffer (compilation-find-buffer)))
        (if (get-buffer-process buffer)
            (interrupt-process (get-buffer-process buffer))
            (error "The ~a process is not running"
                   (compilation--downcase-mode-name (mode-name))))))

    (define-command (compile-goto-error . rest)
      "Visit the source for the error message at point.
Use this command in a compilation log buffer."
      (interactive (list *last-read-event*))
      ;; `compile.el:2994'.  EVENT is `&optional'; callers pass none.
      ;;--------------------------------------------------------------
      (let ((event (and (pair? rest) (car rest))))
      (if event (posn-set-point (event-end event)))
      (or (compilation-buffer-p (current-buffer))
          (error "Not in a compilation buffer"))
      (compilation--ensure-parse (point))
      (if (get-text-property (point) 'compilation-directory)
          (dired-other-window
           (car (get-text-property (point) 'compilation-directory)))
          (begin
            (set!compilation-current-error (point))
            (next-error-internal)))))

    (define (compilation-find-buffer . rest)
      "Return a compilation buffer."
      ;; `compile.el:3010'.
      ;;--------------------------------------------------------------
      (let ((avoid-current (and (pair? rest) (car rest))))
        (if (and (compilation-buffer-internal-p) (not avoid-current))
            (current-buffer)
            (next-error-find-buffer avoid-current #f
                                    compilation-buffer-internal-p))))

    (define (compilation--update-markers loc marker screen-columns first-column)
      "Update markers in LOC, and set MARKER to location pointed by LOC."
      ;; `compile.el:3019'.
      ;;--------------------------------------------------------------
      (with-current-buffer
          (if (bufferp (caar (compilation--loc->file-struct loc)))
              (caar (compilation--loc->file-struct loc))
              (apply compilation-find-file
                     marker
                     (caar (compilation--loc->file-struct loc))
                     (%c-cadr (car (compilation--loc->file-struct loc)))
                     (compilation--file-struct->formats
                      (compilation--loc->file-struct loc))))
        (let ((screen-columns
               ;; Obey the compilation-error-screen-columns of the target
               ;; buffer if its major mode set it buffer-locally.
               (if (local-variable-p 'compilation-error-screen-columns
                                     (current-buffer))
                   (compilation-error-screen-columns)
                   screen-columns))
              (first-column
               (if (local-variable-p 'compilation-first-column
                                     (current-buffer))
                   (compilation-first-column)
                   first-column))
              (last 1))
          (parameterize ((*compilation-first-column* first-column))
            (save-restriction
              (widen)
              (goto-char (point-min))
              ;; Treat file's found lines in forward order, 1 by 1.
              (for-each
               (lambda (line)
                 (when (car line)      ; else a filename without a line#
                   (compilation-beginning-of-line (- (car line) last -1))
                   (set! last (car line)))
                 ;; Treat line's found columns and store/update a marker
                 ;; for each.
                 (for-each
                  (lambda (col)
                    (if (compilation--loc->col col)
                        (if (eqv? (compilation--loc->col col) -1)
                            ;; Special case for range end.
                            (end-of-line 1)
                            (compilation-move-to-column
                             (compilation--loc->col col) screen-columns))
                        (begin
                          (beginning-of-line 1)
                          (skip-chars-forward " \t")))
                    (if (compilation--loc->marker col)
                        (set-marker (compilation--loc->marker col) (point))
                        (set-car! (cdddr col) (point-marker))))
                  (cdr line)))
               (reverse (%c-cddr (compilation--loc->file-struct loc)))))))))

    (define-command (compilation-next-error-function n reset)
      "Advance to the next error message and visit the file where the error was.
This is the value of `next-error-function' in Compilation buffers."
      (interactive (list (if (current-prefix-arg)
                             (uarg->integer 1 (current-prefix-arg))
                             1)
                         #f))
      ;; `compile.el:3067'.
      ;;--------------------------------------------------------------
      (when reset
        (set!compilation-current-error #f))
      (let* ((screen-columns (compilation-error-screen-columns))
             (first-column (compilation-first-column))
             (msg (compilation-next-error
                   (if n n 1) #f
                   (or (compilation-current-error)
                       (compilation-messages-start)
                       (point-min))))
             (loc (compilation--message->loc msg))
             (end-loc (compilation--message->end-loc msg))
             (marker (point-marker)))
        (unless loc
          (user-error "No next error"))
        (set!compilation-current-error (point-marker))
        (set! overlay-arrow-position
         (if (bolp)
             (compilation-current-error)
             (copy-marker (line-beginning-position))))
        ;; If loc contains no marker, no error in that file has been
        ;; visited.  If the marker is invalid the buffer has been killed.
        ;; So, recalculate all markers for that file.
        (unless (and (compilation--loc->marker loc)
                     (marker-buffer (compilation--loc->marker loc)))
          (compilation--update-markers loc marker screen-columns
                                       first-column))
        (compilation-goto-locus marker (compilation--loc->marker loc)
                                (compilation--loc->marker end-loc))
        (set-car! (list-tail loc 4) #t)))

    ;; `defvar-local compilation-gcpro' (`compile.el:3110').
    (define (compilation-gcpro)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation-gcpro #f))))
    (define (set!compilation-gcpro v)
      (set-buffer-local-value! (current-buffer) 'compilation-gcpro v))

    (define (compilation-fake-loc marker file . rest)
      "Preassociate MARKER with FILE."
      (or (pair? file) (set! file (list file)))
      (compilation--flush-file-structure file)
      (let* ((fs (compilation-get-file-structure file))
             (line (if (pair? rest) (car rest) #f))
             (col (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        ;; Between the current call and the first occurrence of an error
        ;; message referring to FILE, the data is only kept in the weak
        ;; hash-table compilation-locs, so we need to prevent this entry
        ;; from being GC'd away.
        (set!compilation-gcpro (cons fs (compilation-gcpro)))
        (let* ((loc (compilation-assq (or line 1) (cdr fs)))
               (loc (compilation-assq col loc)))
          (unless (not (cdr loc)) (error "Assertion failed"))
          (set-cdr! loc (compilation--make-cdrloc line fs marker))
          loc)))

    (define (compilation-set-window w mk)
      "Maybe align the compilation output window W with marker MK near top."
      ;; `compile.el:3158'.
      ;;--------------------------------------------------------------
      (cond ((integer? (*compilation-context-lines*))
             (set-window-start
              w (save-excursion
                  (goto-char mk)
                  (compilation-beginning-of-line
                   (- 1 (*compilation-context-lines*)))
                  (point))))
            ((and (not (*compilation-context-lines*))
                  ;; If there is no left fringe.
                  (eqv? (car (window-fringes w)) 0))
             (set-window-start
              w (save-excursion
                  (goto-char mk)
                  (beginning-of-line 1)
                  (point)))))
      (set-window-point w mk))

    ;; `defvar-local compilation-arrow-overlay' (`compile.el:3175'); the
    ;; margin/fringe arrow needs `display` margins, which this renderer
    ;; does not draw - named in the header.
    (define (compilation-arrow-overlay)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation-arrow-overlay #f))))
    (define (set!compilation-arrow-overlay v)
      (set-buffer-local-value! (current-buffer)
                               'compilation-arrow-overlay v))

    (define (compilation-set-overlay-arrow w)
      "Set up, or switch off, the overlay-arrow for window W."
      ;; `compile.el:3225`.  This renderer draws no fringe/margin arrows
      ;; (see `xdisp.scm`); the `overlay-arrow-position` the tty path
      ;; uses is set by `compilation-next-error-function`.
      ;;--------------------------------------------------------------
      #f)

    (define (compilation-goto-locus msg mk end-mk)
      "Jump to an error corresponding to MSG at MK."
      ;; `compile.el:3256'.
      ;;--------------------------------------------------------------
      (let* ((from-compilation-buffer (eq? (window-buffer (selected-window))
                                           (marker-buffer msg)))
             ;; Use an existing window if it is in a visible frame.
             (pre-existing (get-buffer-window (marker-buffer msg) 0))
             (w (if (and from-compilation-buffer pre-existing)
                    ;; Calling display-buffer here may end up (partly)
                    ;; hiding the error location if the two buffers are
                    ;; in two different frames.  So don't do it if it's
                    ;; not necessary.
                    pre-existing
                    (display-buffer (marker-buffer msg)
                                    '(#f (allow-no-window . #t)))))
             (highlight-regexp
              (with-current-buffer (marker-buffer msg)
                ;; also do this while we change buffer
                (goto-char (marker-position msg))
                (and w (begin
                         (compilation-set-window w msg)
                         (compilation-set-overlay-arrow w)))
                (compilation-highlight-regexp))))
        ;; Ideally, the window-size should be passed to `display-buffer'
        ;; so it's only used when creating a new window.
        (when (and (not pre-existing) w)
          (compilation-set-window-height w))
        (if (or from-compilation-buffer
                (eq? w (selected-window)))
            ;; If the compilation buffer window is selected, keep the
            ;; compilation buffer in this window; display the source in
            ;; another window.
            (pop-to-buffer (marker-buffer mk) 'other-window)
            (switch-to-buffer (marker-buffer mk)))
        (unless (eq? (goto-char (marker-position mk)) (point))
          ;; If narrowing gets in the way of going to the right place,
          ;; widen.
          (widen)
          (if (next-error-move-function)
              ((next-error-move-function) msg mk)
              (goto-char (marker-position mk))))
        (if end-mk
            (push-mark (marker-position end-mk) #t)
            (if (mark-active) (set!mark-active #f)))
        (when highlight-regexp
          (if (timer? next-error-highlight-timer)
              (cancel-timer next-error-highlight-timer))
          (unless compilation-highlight-overlay
            (set! compilation-highlight-overlay
                  (make-overlay (point-min) (point-min)))
            (overlay-put compilation-highlight-overlay 'face 'next-error))
          (with-current-buffer (marker-buffer mk)
            (save-excursion
              (if end-mk (goto-char end-mk) (end-of-line 1))
              (let ((end (point)))
                (if mk (goto-char mk) (beginning-of-line 1))
                (if (and (string? highlight-regexp)
                         (re-search-forward highlight-regexp end #t))
                    (begin
                      (goto-char (match-beginning 0))
                      (move-overlay compilation-highlight-overlay
                                    (match-beginning 0) (match-end 0)
                                    (current-buffer)))
                    (move-overlay compilation-highlight-overlay
                                  (point) end (current-buffer)))
                (if (or (eq? (*next-error-highlight*) #t)
                        (number? (*next-error-highlight*)))
                    ;; We want highlighting: delete overlay on next input.
                    (add-hook (*pre-command-hook*)
                              compilation-goto-locus-delete-o)
                    ;; We don't want highlighting: delete overlay now.
                    (delete-overlay compilation-highlight-overlay))
                ;; We want highlighting for a limited time: set up a
                ;; timer to delete it.
                (when (number? (*next-error-highlight*))
                  (set! next-error-highlight-timer
                        (run-at-time (*next-error-highlight*) #f
                                     compilation-goto-locus-delete-o))))))
          (when (eq? (*next-error-highlight*) 'fringe-arrow)
            ;; We want a fringe arrow (instead of highlighting).
            (set! next-error-overlay-arrow-position
                  (copy-marker (line-beginning-position)))))))

    (define (compilation-goto-locus-delete-o)
      ;; `compile.el:3345'.
      ;;--------------------------------------------------------------
      (delete-overlay compilation-highlight-overlay)
      ;; Get rid of timer and hook that would try to do this again.
      (if (timer? next-error-highlight-timer)
          (cancel-timer next-error-highlight-timer))
      (remove-hook (*pre-command-hook*) compilation-goto-locus-delete-o))

    (define (compilation--expand-fn directory filename)
      "Expand FILENAME or resolve its true name."
      ;; `compile.el:3353'.
      ;;--------------------------------------------------------------
      (let ((expandedname (expand-file-name filename directory)))
        (if (file-exists-p expandedname)
            expandedname
            (file-truename (concat directory "/" filename)))))

    (define (compilation-find-file-1 marker filename directory . rest)
      ;; `compile.el:3362'.
      ;;--------------------------------------------------------------
      (let ((formats (if (pair? rest) (car rest) #f)))
        (or formats (set! formats '("%s")))
        (let ((dirs (compilation-search-path))
              (spec-dir (if directory
                            (expand-file-name directory)
                            (default-directory)))
              (filename filename)
              (buffer #f) (thisdir #f) (fmts #f) (name #f))
          (if (and filename (file-name-absolute-p filename))
              ;; The file name is absolute.  Use its explicit directory
              ;; as the first in the search path, and strip it from
              ;; FILENAME.
              (begin
                (set! filename (abbreviate-file-name
                                (expand-file-name filename)))
                (set! dirs (cons (file-name-directory-part filename) dirs))
                (set! filename (file-name-nondirectory-part filename))))
          ;; Now search the path.
          (let loop ()
            (when (and dirs (not buffer))
              (set! thisdir (or (car dirs) spec-dir))
              (set! fmts formats)
              ;; For each directory, try each format string.
              (let loop2 ()
                (when (and fmts (not buffer))
                  (set! name (compilation--expand-fn
                              thisdir (format (car fmts) filename)))
                  (set! buffer (and (file-exists-p name)
                                    (find-file-noselect name)))
                  (set! fmts (cdr fmts))
                  (loop2)))
              (set! dirs (cdr dirs))
              (loop)))
          ;; If we haven't found it, this might be a parallel build.
          ;; Search the directories further up the buffer.
          (when (and (not buffer)
                     (*compilation-search-all-directories*))
            (with-current-buffer (marker-buffer marker)
              (save-excursion
                (goto-char (marker-position marker))
                (let ((prev (compilation--previous-directory (point))))
                  (when prev (goto-char prev)))
                (set! dirs
                      (cdr (or (get-text-property
                                (- (point) 1) 'compilation-directory)
                               (get-text-property
                                (point) 'compilation-directory))))))
            (let loop ()
              (when (and dirs (not buffer))
                (set! thisdir (car dirs))
                (set! fmts formats)
                (let loop2 ()
                  (when (and fmts (not buffer))
                    (set! name (compilation--expand-fn
                                thisdir (format (car fmts) filename)))
                    (set! buffer (and (file-exists-p name)
                                      (find-file-noselect name)))
                    (set! fmts (cdr fmts))
                    (loop2)))
                (set! dirs (cdr dirs))
                (loop))))
          (list buffer spec-dir))))

    (define (compilation-find-file marker filename directory . formats)
      "Find a buffer for file FILENAME."
      ;; `compile.el:3413'.  `ding' is not ported (the message is the
      ;; report); `overlays-in' walks the found buffer for the intangible
      ;; overlays hideshow marks.
      ;;--------------------------------------------------------------
      (let* ((res (apply compilation-find-file-1 marker filename directory
                         formats))
             (buffer (car res))
             (spec-dir (cadr res)))
        (let loop ()                   ; Repeat until an existing file.
          (when (not buffer)
          ;; The file doesn't exist.  Ask the user where to find it.
          (save-excursion               ; This save-excursion is
                                        ; probably not right.
            (let ((w (display-buffer (marker-buffer marker)
                                     '(#f (allow-no-window . #t)))))
              (with-current-buffer (marker-buffer marker)
                (goto-char (marker-position marker))
                (and w (begin
                         (compilation-set-window w marker)
                         (compilation-set-overlay-arrow w))))
              (let* ((name (read-file-name
                            (format-prompt (format "Find this %s in" filename)
                                           compilation-error)
                            spec-dir filename #t #f))
                     (origname name))
                (cond
                 ((not (file-exists-p name))
                  (message "Cannot find file `%s'" name)
                  (sit-for 2))
                 ((and (file-directory-p name)
                       (not (file-exists-p
                             (begin
                               (set! name (compilation--expand-fn name
                                                                  filename))
                               name))))
                  (message "No `%s' in directory %s" filename origname)
                  (sit-for 2))
                 (else
                  (set! buffer (find-file-noselect name)))))))
            (loop)))
        ;; Make intangible overlays tangible.
        (for-each (lambda (ov)
                    (when (overlay-get ov 'intangible)
                      (overlay-put ov 'intangible #f)))
                  (overlays-in (point-min) (point-max)))
        buffer))

    (define-command (compilation-mode . rest)
      "Major mode for compilation log buffers."
      (interactive)
      (let ((name-of-mode (and (pair? rest) (car rest))))
      ;; `compile.el:2523'.  `jit-lock-defer-time` (deferred
      ;; fontification) is not ported and is still a named gap; the page
      ;; delimiter and the tool bar map are set buffer-locally as the
      ;; mode sets them.
      ;;--------------------------------------------------------------
      (kill-all-local-variables)
      (use-local-map compilation-mode-map)
      ;; Let windows scroll along with the output.
      (set-buffer-local-value! (current-buffer) 'window-point-insertion-type #t)
      (set-buffer-local-value! (current-buffer) 'tool-bar-map
                               compilation-mode-tool-bar-map)
      (set!page-delimiter compilation-page-delimiter)
      (set!major-mode 'compilation-mode)
      (set!mode-name (or name-of-mode "Compilation"))
      (compilation-setup)
      (set!buffer-read-only (current-buffer) #t)
      (run-mode-hooks (*compilation-mode-hook*))))

    (define-syntax define-compilation-mode
      ;; `compile.el:2555'.  The `compilation-XXX' variable aliasing
      ;; (`grep-scroll-output' from `compilation-scroll-output') is not
      ;; carried: it is Emacs's `intern-soft'/`boundp' over the obarray,
      ;; and no such mode exists here yet.  The mode itself derives from
      ;; `compilation-mode` as Emacs's does.
      (syntax-rules ()
        ((_ mode name doc body ...)
         (define-derived-mode (mode compilation-mode name) doc body ...))))

    (define-command (compilation-revert-buffer ignore-auto noconfirm)
      ;; `compile.el:2594'.
      ;;--------------------------------------------------------------
      (if (buffer-file-name)
          (call-with-buffer-local 'revert-buffer-function #f
                                  (lambda ()
                                    (revert-buffer ignore-auto noconfirm)))
          (if (or noconfirm (yes-or-no-p "Restart compilation? "))
              (begin
                (reattach-compilation-arguments)
                (apply compilation-start (compilation-arguments))))))

    (define (reattach-compilation-arguments)
      ;; `revert-buffer-function' is called with the compilation buffer
      ;; current, so the accessor answers its own arguments; this no-op
      ;; names that fact for the reader.
      #f)

    ;; `compilation-current-error' and `compilation-messages-start' are
    ;; `defvar's the mode makes buffer-local (`compile.el:2601', `:2605').
    (define *compilation-current-error-default* #f)
    (define (compilation-current-error)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'compilation-current-error b))
            (buffer-local-value b 'compilation-current-error #f)
            *compilation-current-error-default*)))
    (define (set!compilation-current-error v)
      (set-buffer-local-value! (current-buffer) 'compilation-current-error v))
    (define (compilation-messages-start)
      (let ((b (current-buffer)))
        (and b (buffer-local-value b 'compilation-messages-start #f))))
    (define (set!compilation-messages-start v)
      (set-buffer-local-value! (current-buffer) 'compilation-messages-start v))

    (define (compilation-setup . rest)
      "Prepare the buffer for the compilation parsing commands to work."
      ;; `compile.el:2609'.
      ;;--------------------------------------------------------------
      (let ((minor (and (pair? rest) (car rest))))
        (make-local-variable 'compilation-current-error)
        (make-local-variable 'compilation-messages-start)
        (set-buffer-local-value! (current-buffer)
                                 'compilation-error-screen-columns
                                 (*compilation-error-screen-columns*))
        (set!compilation-num-errors-found 0)
        (set!compilation-num-warnings-found 0)
        (set!compilation-num-infos-found 0)
        (set-buffer-local-value! (current-buffer) 'overlay-arrow-string "")
        (set! next-error-overlay-arrow-position #f)
        (add-hook (*kill-buffer-hook*)
                  (lambda () (set! next-error-overlay-arrow-position #f))
                  #f #t)
        (set!next-error-function compilation-next-error-function)
        (set-buffer-local-value! (current-buffer) 'comint-file-name-prefix
                                 (or (file-remote-p (default-directory)) ""))
        (set!compilation-locs (make-hash-table))
        (add-hook (*before-change-functions*) compilation--flush-parse #f #t)
        (add-hook (*change-major-mode-hook*) compilation--remove-properties
                  #f #t)
        (if minor
            (begin
              (font-lock-add-keywords #f
                                      (compilation-mode-font-lock-keywords-function))
              (font-lock-flush))
            (set-buffer-local-value! (current-buffer) 'font-lock-defaults
                                     '((compilation-mode-font-lock-keywords) #t))))
      #f)

    (define (compilation--unsetup)
      ;; `compile.el:2644'.
      ;;--------------------------------------------------------------
      (font-lock-remove-keywords
       #f (compilation-mode-font-lock-keywords-function))
      (remove-hook (*before-change-functions*) compilation--flush-parse #f #t)
      (kill-local-variable 'compilation--parsed)
      (compilation--remove-properties)
      (font-lock-flush))

    (define (compilation-handle-exit process-status exit-status msg)
      "Write MSG in the current buffer and hack its `mode-line-process'."
      ;; `compile.el:2677'.
      ;;--------------------------------------------------------------
      (parameterize ((*inhibit-read-only* #t))
      (let ((status (if compilation-exit-message-function
                        (compilation-exit-message-function
                         process-status exit-status msg)
                        (cons msg exit-status)))
            (omax (point-max))
            (opoint (point))
            (cur-buffer (current-buffer)))
        ;; Record where we put the message, so we can ignore it later on.
        (goto-char omax)
        (compilation-insert-annotation #\newline (mode-name) " " (car status))
        (if (and (number? (*compilation-window-height*))
                 (zero? (*compilation-window-height*)))
            (message "%s" (cdr status)))
        (if (bolp) (forward-char -1))
        (compilation-insert-annotation
         " at "
         (substring (current-time-string) 0 19)
         ", duration "
         (let ((elapsed (- (float-time) (compilation--start-time))))
           (cond ((< elapsed 10) (format "%.2f s" elapsed))
                 ((< elapsed 60) (format "%.1f s" elapsed))
                 (else (format-seconds "%h:%02m:%02s" elapsed)))))
        (goto-char (point-max))
        ;; Prevent that message from being recognized as a compilation
        ;; error.
        (add-text-properties omax (point) '(compilation-handle-exit #t))
        (set-buffer-local-value!
         (current-buffer) 'mode-line-process
         (list
          (let ((out-string (format ":%s [%s]" process-status (cdr status)))
                (msg (format "%s %s" (mode-name)
                             (replace-regexp-in-string
                              "\n?$" "" (car status)))))
            (message "%s" msg)
            (propertize out-string
                        'help-echo msg
                        'face (if (> exit-status 0)
                                  'compilation-mode-line-fail
                                  'compilation-mode-line-exit)))
          compilation-mode-line-errors))
        ;; Force mode line redisplay soon.
        (force-mode-line-update)
        (if (and opoint (< opoint omax))
            (goto-char opoint))
        (run-hook-with-args (*compilation-finish-functions*) cur-buffer msg))))

    (define (compilation-sentinel proc msg)
      "Sentinel for compilation buffers."
      ;; `compile.el:2727'.
      ;;--------------------------------------------------------------
      (if (memq (process-status proc) '(exit signal))
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ((buffer (process-buffer proc)))
                (if (not (buffer-name buffer))
                    ;; buffer killed
                    (set-process-buffer proc #f)
                    (with-current-buffer buffer
                      ;; Write something in the compilation buffer and
                      ;; hack its mode line.
                      (compilation-handle-exit (process-status proc)
                                               (process-exit-status proc)
                                               msg)))))
            (lambda ()
              (set! compilation-in-progress
                    (delq proc compilation-in-progress))
              (compilation--update-in-progress-mode-line)
              ;; Since the buffer and mode line will show that the
              ;; process is dead, we can delete it now.
              (delete-process proc)))))

    (define (compilation-filter proc string)
      "Process filter for compilation buffers.
Just inserts the text, handles carriage motion, and runs
`compilation-filter-hook'."
      ;; `compile.el:2748'.
      ;;--------------------------------------------------------------
      (when (buffer-live-p (process-buffer proc))
        (with-current-buffer (process-buffer proc)
          (let (;; `save-excursion' doesn't use the right insertion-type
                ;; for us.
                (pos (copy-marker (point) #t))
                ;; `save-restriction' doesn't use the right insertion
                ;; type either: if we are inserting at the end of the
                ;; accessible part of the buffer, keep the inserted text
                ;; visible.
                (min (point-min-marker))
                (max (copy-marker (point-max) #t)))
           (parameterize ((*inhibit-read-only* #t)
                          (*compilation-filter-start*
                           (marker-position (process-mark proc))))
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (widen)
                (goto-char (*compilation-filter-start*))
                ;; We used to use `insert-before-markers', so that
                ;; windows with point at `process-mark' scroll along
                ;; with the output, but we now use
                ;; window-point-insertion-type instead.
                (if (not (*compilation-max-output-line-length*))
                    (insert string)
                    (for-each
                     (lambda (line)
                       (compilation--insert-abbreviated-line
                        line (*compilation-max-output-line-length*)))
                     (string-lines string #f #t)))
                (when (*compilation-hidden-output*)
                  (compilation--hide-output (*compilation-filter-start*)))
                (unless (*comint-inhibit-carriage-motion*)
                  (comint-carriage-motion (process-mark proc) (point)))
                (set-marker (process-mark proc) (point))
                ;; Update the number of errors in
                ;; compilation-mode-line-errors
                (compilation--ensure-parse (point))
                (run-hooks (*compilation-filter-hook*)))
              (lambda ()
                (goto-char pos)
                (narrow-to-region (marker-position min) (marker-position max))
                (set-marker pos #f)
                (set-marker min #f)
                (set-marker max #f))))))))

    (define (compilation--hide-output start)
      ;; `compile.el:2777'.
      ;;--------------------------------------------------------------
      (save-excursion
        (goto-char start)
        (beginning-of-line)
        ;; Apply the match to each line, but wait until we have a
        ;; complete line.
        (let ((start (point)))
          (let loop ()
            (when (search-forward "\n" #f #t)
              (save-restriction
                (narrow-to-region start (point))
                (for-each
                 (lambda (regexp)
                   (goto-char start)
                   (let loop2 ()
                     (when (re-search-forward regexp #f #t)
                       ;; Emacs's data is `'(invisible t
                       ;; rear-nonsticky t)'; here `t` is `#t`, the
                       ;; tree's one true value - a bare `t` would be
                       ;; the *symbol*, which is truthy but not what
                       ;; `invisible-p` answers.
                       (add-text-properties
                        (match-beginning 0) (match-end 0)
                        (list 'invisible #t 'rear-nonsticky #t))
                       (loop2))))
                 (ensure-list (*compilation-hidden-output*)))
                (goto-char (point-max)))
              (loop))))))

    (define (compilation--insert-abbreviated-line string width)
      ;; `compile.el:2795'.
      ;;--------------------------------------------------------------
      (if (and (> (current-column) 0)
               (get-text-property (- (point) 1) 'button))
          ;; We already have an abbreviation; just add the string to it.
          (let ((beg (point)))
            (insert string)
            (add-text-properties
             beg
             ;; Don't make the final newline invisible.
             (if (char=? (string-ref string (- (string-length string) 1))
                         #\newline)
                 (- (point) 1)
                 (point))
             (text-properties-at (- beg 1))))
          ;; Emacs's `if` takes any number of ELSE forms; Scheme's takes
          ;; one, so the else list is a `begin`.
          (begin
          (insert string)
          ;; If we exceeded the limit, hide the last portion of the line.
          (let* ((ends-in-nl
                  (char=? (string-ref string (- (string-length string) 1))
                          #\newline))
                 (curcol (if ends-in-nl
                             (begin (backward-char 1) (current-column))
                             (current-column))))
            (when (> curcol width)
              (let ((start (save-excursion
                             (move-to-column width)
                             (point))))
                (buttonize-region
                 start (point)
                 (lambda (start)
                   (parameterize ((*inhibit-read-only* #t))
                     (remove-text-properties
                      start
                      (save-excursion (goto-char start) (line-end-position))
                      (text-properties-at start)))))
                (put-text-property start (point) 'display
                                   (if (char-displayable-p #\…)
                                       "[…]"
                                       "[...]"))))
            (if ends-in-nl (forward-char 1))))))

    (define-command (compilation-forget-errors)
      ;; `compile.el:3545'.
      ;;--------------------------------------------------------------
      (let ((locs (compilation-locs)))
        (if locs
            (hash-for-each (lambda (k v) (hash-remove! locs k)) locs)))
      (set!compilation-gcpro '())
      (set!compilation-current-error #f)
      (let* ((proc (get-buffer-process (current-buffer)))
             (mark (if proc (process-mark proc) #f))
             (pos (or mark (point-max))))
        (set!compilation-messages-start
              ;; In the future, ignore the text already present in the
              ;; buffer.  Since many process filter functions insert
              ;; before markers, we need to put ours just before the
              ;; insertion point rather than at the insertion point.
              (if (> pos (point-min))
                  (copy-marker (- pos 1))
                  pos)))
      ;; Again, since this command is used in buffers that contain
      ;; several compilations, to set the beginning of "this
      ;; compilation", it's a good place to reset
      ;; compilation-auto-jump-to-next.
      (set!compilation-auto-jump-to-next
       (or (*compilation-auto-jump-to-first-error*)
           (eq? (*compilation-scroll-output*) 'first-error))))

    ;;----------------------------------------------------------------
    ;; The minor mode and the maps (`compile.el:2353'-`:2550',
    ;; `:2652'-`:2675').  The maps are here, after the commands, because
    ;; a keymap holds command *procedures*.
    ;;----------------------------------------------------------------

    (define *next-error-follow-last-line-default* #f)
    (define (next-error-follow-last-line)
      (let ((b (current-buffer)))
        (if (and b (local-variable-p 'next-error-follow-last-line b))
            (buffer-local-value b 'next-error-follow-last-line #f)
            *next-error-follow-last-line-default*)))
    (define (set!next-error-follow-last-line v)
      (set-buffer-local-value! (current-buffer)
                               'next-error-follow-last-line v))

    (define (next-error-follow-mode-post-command-hook)
      ;; `simple.el:526'.  Placed here (a named departure): it reads
      ;; `compilation-context-lines` and `compilation-current-error`,
      ;; which live in this library, and `simple.scm` is below it.
      ;;--------------------------------------------------------------
      (unless (equal? (next-error-follow-last-line)
                      (line-number-at-pos))
        (set!next-error-follow-last-line (line-number-at-pos))
        (guard (e (else #t))
          (parameterize ((*compilation-context-lines* #f))
            (set!compilation-current-error (point))
            (next-error-no-select 0)))))

    (define-minor-mode next-error-follow-minor-mode
      "Minor mode for Compilation, Grep, Occur and Diff modes."
      :group 'next-error :init-value #f :lighter " Fol"
      (if (not next-error-follow-minor-mode)
          (remove-hook (*post-command-hook*)
                       next-error-follow-minor-mode-variable
   next-error-follow-mode-post-command-hook)
          (begin
            (add-hook (*post-command-hook*)
                      next-error-follow-minor-mode-variable
   next-error-follow-mode-post-command-hook)
            (make-local-variable 'next-error-follow-last-line))))

    ;; `compilation-menu-map' (`compile.el:2353'), with the "Skip Less
    ;; Important Messages" submenu its items name (lambdas over
    ;; `customize-set-variable`, as Emacs writes them).
    (define compilation-menu-map (km:keymap '*compilation-menu-map*))
    ;; `compile.el:2353'.  Emacs's entries are defined in its order -
    ;; Stop first, Next Error last - and `define-key`'s prepending turns
    ;; that into the display order Emacs's own map has (measured on
    ;; Emacs 31.1: `(compilation-next-error compilation-previous-error
    ;; compilation-first-error compilation-mode-separator2
    ;; compilation-skip compilation-next-error-follow-minor-mode
    ;; compilation-mode-separator3 stop-subjob)`).
    ;;
    ;; The Skip submenu's three items are lambdas over
    ;; `customize-set-variable` in Emacs, and they are lambdas here too;
    ;; the tree's `compilation-skip-threshold` is a `define-custom`
    ;; parameter, so the symbol passed is the starred one and the radio
    ;; form reads the parameter where Emacs reads the variable.
    ;; `next-error-follow-minor-mode`'s toggle form is the generated
    ;; `-variable` accessor for the same reason the mode's body uses it.
    (define-key compilation-menu-map (vector 'stop-subjob)
      '(menu-item "Stop Compilation" kill-compilation
                  :help "Kill the process made by the M-x compile or M-x grep commands"))
    (define-key compilation-menu-map (vector 'compilation-mode-separator3)
      '("----" . #f))
    (define-key compilation-menu-map
      (vector 'compilation-next-error-follow-minor-mode)
      (list 'menu-item "Auto Error Display" next-error-follow-minor-mode
            ':help "Display the error under cursor when moving the cursor"
            ':button (list ':toggle
                           (list 'next-error-follow-minor-mode-variable))))
    (define %compilation-skip-map (km:keymap "Skip"))
    (define-key %compilation-skip-map (vector 'compilation-skip-none)
      (list 'menu-item "Don't Skip Any Messages"
            (lambda ()
              (customize-set-variable '*compilation-skip-threshold* 0))
            ':help "Do not skip any type of messages"
            ':button (list ':radio
                           (list '= (list '*compilation-skip-threshold*) 0))))
    (define-key %compilation-skip-map (vector 'compilation-skip-info)
      (list 'menu-item "Skip Info"
            (lambda ()
              (customize-set-variable '*compilation-skip-threshold* 1))
            ':help "Skip anything less than warning"
            ':button (list ':radio
                           (list '= (list '*compilation-skip-threshold*) 1))))
    (define-key %compilation-skip-map
      (vector 'compilation-skip-warning-and-info)
      (list 'menu-item "Skip Warnings and Info"
            (lambda ()
              (customize-set-variable '*compilation-skip-threshold* 2))
            ':help "Skip over Warnings and Info, stop for errors"
            ':button (list ':radio
                           (list '= (list '*compilation-skip-threshold*) 2))))
    (define-key compilation-menu-map (vector 'compilation-skip)
      (cons "Skip Less Important Messages" %compilation-skip-map))
    (define-key compilation-menu-map (vector 'compilation-mode-separator2)
      '("----" . #f))
    (define-key compilation-menu-map (vector 'compilation-first-error)
      '(menu-item "First Error" first-error
                  :help "Restart at the first error, visit corresponding source code"))
    (define-key compilation-menu-map (vector 'compilation-previous-error)
      '(menu-item "Previous Error" previous-error
                  :help "Visit previous `next-error' message and corresponding source code"))
    (define-key compilation-menu-map (vector 'compilation-next-error)
      '(menu-item "Next Error" next-error
                  :help "Visit next `next-error' message and corresponding source code"))

    ;; `compilation-mode-map' (`compile.el:2451').
    (define compilation-mode-map (km:keymap '*compilation-mode-map*))
    (set-keymap-parent compilation-mode-map special-mode-map)
    (define-key compilation-mode-map (vector 'mouse-2) compile-goto-error)
    (define-key compilation-mode-map (vector 'follow-link) 'mouse-face)
    (define-key compilation-mode-map (kbd "C-c C-c") compile-goto-error)
    (define-key compilation-mode-map (kbd "RET") compile-goto-error)
    (define-key compilation-mode-map (kbd "C-o") compilation-display-error)
    (define-key compilation-mode-map (kbd "C-c C-k") kill-compilation)
    (define-key compilation-mode-map (kbd "M-n") compilation-next-error)
    (define-key compilation-mode-map (kbd "M-p") compilation-previous-error)
    (define-key compilation-mode-map (kbd "M-{") compilation-previous-file)
    (define-key compilation-mode-map (kbd "M-}") compilation-next-file)
    (define-key compilation-mode-map (kbd "n") next-error-no-select)
    (define-key compilation-mode-map (kbd "p") previous-error-no-select)
    (define-key compilation-mode-map (kbd "TAB") compilation-next-error)
    (define-key compilation-mode-map (vector 'backtab)
      compilation-previous-error)
    (define-key compilation-mode-map (kbd "g") recompile)
    (define-key compilation-mode-map (kbd "C-c C-f")
      next-error-follow-minor-mode)
    (define-key compilation-mode-map (vector 'menu-bar 'compilation)
      (cons "Compile" compilation-menu-map))
    (define-key compilation-mode-map
      (vector 'menu-bar 'compilation 'compilation-separator2)
      '("----" . #f))
    (define-key compilation-mode-map
      (vector 'menu-bar 'compilation 'compilation-recompile)
      '(menu-item "Recompile" recompile
                  :help "Re-compile the program including the current buffer"))
    (define-key compilation-mode-map
      (vector 'menu-bar 'compilation 'compilation-compile)
      '(menu-item "Compile..." compile
                  :help "Compile the program including the current buffer.  Default: run `make'"))

    ;; `compilation-minor-mode-map' and `compilation-shell-minor-mode-map'
    ;; (`compile.el:2402', `:2426').
    (define compilation-minor-mode-map
      (km:keymap '*compilation-minor-mode-map*))
    (set-keymap-parent compilation-minor-mode-map special-mode-map)
    (define-key compilation-minor-mode-map (vector 'mouse-2) compile-goto-error)
    (define-key compilation-minor-mode-map (vector 'follow-link) 'mouse-face)
    (define-key compilation-minor-mode-map (kbd "C-c C-c") compile-goto-error)
    (define-key compilation-minor-mode-map (kbd "RET") compile-goto-error)
    (define-key compilation-minor-mode-map (kbd "C-o") compilation-display-error)
    (define-key compilation-minor-mode-map (kbd "C-c C-k") kill-compilation)
    (define-key compilation-minor-mode-map (kbd "M-n") compilation-next-error)
    (define-key compilation-minor-mode-map (kbd "M-p") compilation-previous-error)
    (define-key compilation-minor-mode-map (kbd "M-{") compilation-previous-file)
    (define-key compilation-minor-mode-map (kbd "M-}") compilation-next-file)
    (define-key compilation-minor-mode-map (kbd "n") next-error-no-select)
    (define-key compilation-minor-mode-map (kbd "p") previous-error-no-select)
    (define-key compilation-minor-mode-map (kbd "l") recenter-current-error)
    (define-key compilation-minor-mode-map (kbd "g") recompile)
    (define-key compilation-minor-mode-map (vector 'menu-bar 'compilation)
      (cons "Errors" compilation-menu-map))

    (define compilation-shell-minor-mode-map
      (km:keymap '*compilation-shell-minor-mode-map*))
    (define-key compilation-shell-minor-mode-map (kbd "M-C-m")
      compile-goto-error)
    (define-key compilation-shell-minor-mode-map (kbd "M-C-n")
      compilation-next-error)
    (define-key compilation-shell-minor-mode-map (kbd "M-C-p")
      compilation-previous-error)
    (define-key compilation-shell-minor-mode-map (kbd "M-{")
      compilation-previous-file)
    (define-key compilation-shell-minor-mode-map (kbd "M-}")
      compilation-next-file)
    (define-key compilation-shell-minor-mode-map (vector 'menu-bar 'compilation)
      (cons "Errors" compilation-menu-map))

    ;; `compilation-button-map' (`compile.el:2439'): the map the parser's
    ;; text properties name, built where it was made in tranche 1.
    (define-key compilation-button-map (vector 'mouse-2) compile-goto-error)
    (define-key compilation-button-map (vector 'follow-link) 'mouse-face)
    (define-key compilation-button-map (kbd "RET") compile-goto-error)

    ;; `compilation-mode-tool-bar-map' (`compile.el:2494'): the global
    ;; tool bar with its Undo and second separator taken out, a separator
    ;; added, and the four navigation/control buttons.  Emacs's commands
    ;; are symbols; here they are the procedures they are bound to, and
    ;; `:enable` is the same Scheme form `menu-item-eval-property` runs.
    (define compilation-mode-tool-bar-map
      (if (keymapp tool-bar-map)
          (let ((map (copy-keymap tool-bar-map)))
            (define-key map (vector 'undo) #f)
            (define-key map (vector 'separator-2) #f)
            (define-key-after map (vector 'separator-compile)
                              menu-bar-separator)
            (tool-bar-local-item
             "left-arrow" previous-error-no-select 'previous-error-no-select
             map ':rtl "right-arrow" ':help "Goto previous error")
            (tool-bar-local-item
             "right-arrow" next-error-no-select 'next-error-no-select
             map ':rtl "left-arrow" ':help "Goto next error")
            (tool-bar-local-item
             "cancel" kill-compilation 'kill-compilation map
             ':enable '(let ((buffer (compilation-find-buffer)))
                         (get-buffer-process buffer))
             ':help "Stop compilation")
            (tool-bar-local-item
             "refresh" recompile 'recompile map
             ':help "Restart compilation")
            map)
          #f))

    ;; `compilation-shell-minor-mode' and `compilation-minor-mode'
    ;; (`compile.el:2653', `:2666').  **A named ordering departure**:
    ;; `define-minor-mode` asks its module for `MODE-map` as the
    ;; definition form runs, and a Scheme binding of a keymap does not
    ;; exist until its `define` has - so the two modes are defined after
    ;; the two maps, where Emacs defines them before.  Their getters are
    ;; `MODE-variable', the tree's accessor-pair spelling for a mode
    ;; whose name is also a command.
    (define-minor-mode compilation-shell-minor-mode
      "Toggle Compilation Shell minor mode.

When Compilation Shell minor mode is enabled, all the
error-parsing commands of the Compilation major mode are
available but bound to keys that don't collide with Shell mode.
See `compilation-mode'."
      :lighter " Shell-Compile"
      (if (compilation-shell-minor-mode-variable)
          (compilation-setup #t)
          (compilation--unsetup)))

    (define-minor-mode compilation-minor-mode
      "Toggle Compilation minor mode.

When Compilation minor mode is enabled, all the error-parsing
commands of Compilation major mode are available.  See
`compilation-mode'."
      :lighter " Compilation"
      (if (compilation-minor-mode-variable)
          (compilation-setup #t)
          (compilation--unsetup)))

    ;;----------------------------------------------------------------
    ;; File structures (`compile.el:3479'-`:3543'), which the parser
    ;; reaches through every message that names a file.
    ;;----------------------------------------------------------------

    (define (compilation-get-file-structure file . rest)
      "Retrieve FILE's file-structure or create a new one.
FILE should be (FILENAME) or (RELATIVE-FILENAME . DIRNAME)."
      ;; `compile.el:3479'.
      ;;--------------------------------------------------------------
      (let ((fmt (if (pair? rest) (car rest) #f)))
        (or (hash-ref (compilation-locs) file)
            ;; File was not previously encountered, at least not in the
            ;; form passed.  Let's normalize it and look again.
            (let* ((filename (car file))
                   ;; Get the specified directory from FILE.
                   (spec-directory
                    (if (pair? (cdr file))
                        (file-truename (concat (comint-file-name-prefix)
                                               (cdr file)))
                        #f)))
              ;; Check for a comint-file-name-prefix and prepend it if
              ;; appropriate.
              (if (file-name-absolute-p filename)
                  (set! filename (concat (comint-file-name-prefix) filename)))
              ;; If compilation-parse-errors-filename-function is defined,
              ;; use it to process the filename.  The result might be a
              ;; buffer.
              (unless (or (not compilation-parse-errors-filename-function)
                          (eq? compilation-parse-errors-filename-function
                               identity))
                (save-match-data
                  (set! filename
                        (compilation-parse-errors-filename-function
                         filename))))
              ;; Some compilers produce bogus file names like
              ;; "./bar//foo.c" for file "bar/foo.c".
              (if (string? filename)
                  (set! filename
                        (command-line-normalize-file-name filename)))
              ;; Store it for the possibly unnormalized name
              (hash-set!
               (compilation-locs) file
               (or (hash-ref (compilation-locs)
                             (cons filename spec-directory))
                   (let ((fs (compilation--make-file-struct
                              (list filename spec-directory) fmt)))
                     (hash-set! (compilation-locs)
                                (cons filename spec-directory) fs)
                     fs)))))))

    (define (compilation--flush-file-structure file)
      ;; `compile.el:3535'.
      ;;--------------------------------------------------------------
      (unless (pair? file) (set! file (list file)))
      (let ((fs (compilation-get-file-structure file)))
        (unless (eq? fs (hash-ref (compilation-locs) file))
          (error "Assertion failed: file structure"))
        (unless (eq? fs (hash-ref (compilation-locs)
                                  (cons (caar fs) (cadr (car fs)))))
          (error "Assertion failed: file structure"))
        (let ((keys '()))
          (hash-for-each (lambda (k v)
                           (if (eq? v fs) (set! keys (cons k keys))))
                         (compilation-locs))
          (for-each (lambda (k) (hash-remove! (compilation-locs) k))
                    keys))))

    ))
