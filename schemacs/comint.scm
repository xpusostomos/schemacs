(define-library (schemacs comint)
  ;; GNU Emacs's `lisp/comint.el' - "general command interpreter in a
  ;; window" - in the file's own order: the variables, `comint-mode',
  ;; the exec cluster, the input history ring and its navigation, the
  ;; output filter, the prompt helpers, the simple senders, the
  ;; signal/subjob commands, `comint-send-input`, the history expansion,
  ;; the argument machinery, the prompt and matching motions, and
  ;; `comint-insert-input'.
  ;;
  ;; **What is not here yet**, each named with what it waits for:
  ;; `comint-write-output`/`-append-output-to-file`
  ;; (`write-region` is not ported); the dynamic completion cluster
  ;; (`completion-at-point` is not ported); `comint-history-isearch-*`;
  ;; `comint-redirect-*`; `comint-osc-process-output` (ansi-osc is not
  ;; ported); `comint-fontify-input-mode` (indirect buffers are not
  ;; ported); `comint-indent-input-*`; `comint-run` (its interactive
  ;; spec prompts, and `read-string` belongs above this library - it is
  ;; installed through a seam when the minibuffer library has one, the
  ;; `shell-command` shape; its prefix-switches arm also needs
  ;; `split-string-and-unquote`, which needs `read-from-string` - the
  ;; Elisp reader is not ported); `follow-mode` integration.
  ;;
  ;; **The password commands are in** (`comint-read-noecho`,
  ;; `comint-password-function`, `comint-send-invisible`,
  ;; `send-invisible`, `comint-watch-for-password-prompt`), on
  ;; `(schemacs auth-source)`'s `read-passwd`. The output-filter list's
  ;; default carries `comint-watch-for-password-prompt`, as Emacs's does;
  ;; `ansi-color-process-output` is the one member still missing
  ;; (`ansi-color` is not ported).
  ;;
  ;; **Docstrings are abridged** to the first sentence or two of
  ;; Emacs's, rather than the whole; nothing in the tree reads them.
  ;;
  ;; **Hooks are parameters**, as every hook in this tree is: `add-hook`
  ;; takes the hook object, and `run-hooks` dereferences a parameter
  ;; (merging its buffer-local half). A mode hands its hook's parameter
  ;; to `define-derived-mode` unchanged; a plain list would still run,
  ;; but nothing could add to it.
  ;;
  ;; The tree's buffer-local idiom is used throughout: a variable Emacs
  ;; `make-local-variable`s has a `*name*` parameter as its default and
  ;; an accessor pair `(name)` / `(set!name v)` over the buffer's slot.
  ;; That is why `comint-mode`'s body is shorter than Emacs's - the
  ;; `make-local-variable` calls have no counterpart to write.

  (import
    (scheme base)
    (only (guile) while catch throw)
    (only (schemacs custom) define-custom)
    (only (schemacs core ring)
          make-ring ring-insert ring-insert-at-beginning ring-extend
          ring-empty-p ring-length ring-ref ring-size ring-p)
    (only (schemacs core derived) define-derived-mode derived-mode-p)
    (only (schemacs core regexp-opt) regexp-opt)
    (only (schemacs buffer)
          current-buffer bufferp buffer-name get-buffer get-buffer-create
          set-buffer buffer-local-value set-buffer-local-value!
          default-directory call-with-buffer-local buffer-live-p
          *inhibit-read-only* with-current-buffer buffer-modified-tick
          buffer-file-name buffer-modified-p major-mode *case-fold-search*)
    (only (schemacs editfns)
          point point-min point-max goto-char insert buffer-substring
          buffer-substring-no-properties delete-region forward-line
          line-end-position line-beginning-position
          field-beginning field-end field-at-pos
          field-string-no-properties constrain-to-field save-restriction
          widen narrow-to-region save-excursion following-char preceding-char
          char-after
          bolp bobp eobp eolp
          message format point-marker point-min-marker buffer-string
          compare-buffer-substrings field-string
          *inhibit-field-text-motion*)
    (only (schemacs marker)
          make-marker set-marker marker-position copy-marker markerp)
    (only (schemacs cmds) beginning-of-line end-of-line delete-char forward-char
          self-insert-command)
    (only (schemacs keyboard) *this-command-keys* command-remapping
          sit-for)
    (only (schemacs syntax) skip-chars-forward syntax-ppss)
    (only (schemacs textprop)
          put-text-property add-text-properties remove-text-properties
          remove-list-of-text-properties get-char-property get-text-property
          next-single-char-property-change previous-single-char-property-change)
    (only (schemacs fns) concat string-equal nconc mapconcat %substring
          nthcdr nth)
    (only (schemacs data) mod /= string-to-number)
    (only (schemacs subr)
          run-hooks run-hook-with-args add-hook with-silent-modifications
          remq user-error with-temp-buffer ignore
          string-trim string-suffix-p string-replace
          posn-point event-end posn-window)
    (only (schemacs search)
          re-search-backward re-search-forward looking-at string-match
          replace-match regexp-quote match-beginning match-end match-string
          looking-at-p search-forward save-match-data)
    (only (schemacs character) kbd)
    (only (schemacs simple) copy-region-as-kill push-mark kill-region
          kill-whole-line just-one-space *last-command* *this-command*
          fundamental-mode string-empty-p)
    (only (schemacs files) insert-file-contents expand-file-name
          read-file-name get-file-buffer save-buffer y-or-n-p)
    ;; Emacs's `file-name-directory` is spelled `file-name-directory-part`
    ;; in this tree (fileio.scm's name for `Ffile_name_directory`); the
    ;; call sites use that spelling.
    (only (schemacs fileio) file-name-directory-part)
    (only (schemacs fileio) file-readable-p file-writable-p
          file-accessible-directory-p file-name-nondirectory-part
          file-exists-p file-directory-p substitute-in-file-name)
    (only (schemacs coding) coding-system-change-eol-conversion)
    (only (schemacs process)
          start-file-process processp process-buffer process-mark
          set-process-filter set-process-coding-system process-coding-system
          delete-process process-send-string process-send-region process-send-eof
          accept-process-output get-buffer-process process-status
          interrupt-process kill-process quit-process stop-process
          continue-process *process-environment* *exec-path*
          *process-connection-type*)
    (only (schemacs version) emacs-version)
    (only (schemacs window) with-selected-window get-buffer-window-list
          get-buffer-window display-buffer)
    (only (schemacs frame) selected-window window-buffer window-point
          window-body-width
          set-window-point set-window-start recenter *pre-command-hook*)
    (only (schemacs xdisp) *scroll-margin* file-remote-p
          pos-visible-in-window-p)
    (only (schemacs keymap) define-key make-sparse-keymap key-description
          lookup-key *default-keymap*)
    (only (schemacs command) define-command current-prefix-arg uarg->integer
          call-interactively called-interactively? prefix-numeric-value
          *last-command-event*)
    (only (schemacs dispnew) ding)
    (only (schemacs textmodes paragraphs) forward-paragraph)
    (only (schemacs minibuffer)
          read-from-minibuffer minibuffer-history-search-history
          history-entries format-prompt)
    ;; The password commands: `read-passwd` and the obsoletion writers.
    (only (schemacs auth-source) read-passwd)
    (only (schemacs core byte-run)
          make-obsolete define-obsolete-function-alias)
    ;; `string-limit` for `comint-watch-for-password-prompt`, and the
    ;; timer it defers the minibuffer read onto.
    (only (schemacs core subr-x) string-limit)
    (only (schemacs core timer) run-at-time)
    (only (schemacs core lisp) forward-sexp)
    (only (schemacs font-lock)
          font-lock-append-text-property
          font-lock--remove-face-from-text-property
          set!font-lock-defaults!)
    (only (schemacs international mule-conf)
          *password-word-equivalents* *password-colon-equivalents*))

  (export comint-mode comint-mode-map
          make-comint-in-buffer make-comint comint-exec comint-exec-1
          comint-term-environment comint-check-proc comint-nonblank-p
          comint-output-filter comint-snapshot-last-prompt
          comint-carriage-motion comint-postoutput-scroll-to-bottom
          comint-adjust-window-point comint-preinput-scroll-to-bottom
          comint-truncate-buffer comint-strip-ctrl-m comint-show-maximum-output
          comint-get-old-input-default comint-copy-old-input
          comint-send-input comint-send-eof comint-delchar-or-maybe-eof
          comint-skip-input comint-magic-space
          comint-replace-by-expanded-history
          comint-replace-by-expanded-history-before-point
          comint-within-quotes comint-how-many-region comint-args
          comint-delim-arg comint-arguments comint-update-fence
          comint-after-pmark-p comint-simple-send comint-line-beginning-position
          comint-backward-matching-input comint-forward-matching-input
          comint-next-prompt comint-previous-prompt comint-insert-input
          comint-regexp-arg
          comint-bol comint-send-string comint-send-region
          comint-delete-output comint-show-output comint-clear-buffer
          comint-interrupt-subjob comint-kill-subjob comint-quit-subjob
          comint-stop-subjob comint-continue-subjob comint-kill-input
          comint-read-input-ring comint-add-to-input-history
          comint-previous-input comint-next-input
          comint-previous-matching-input comint-next-matching-input
          comint-previous-matching-input-from-input
          comint-next-matching-input-from-input
          comint-insert-previous-argument
          comint-insert-previous-argument-last-start-pos
          comint-insert-previous-argument-last-index
          *comint-insert-previous-argument-from-end*
          comint-source-default comint-check-source comint-extract-string
          comint-get-source
          comint-kill-whole-line comint-kill-region comint-proc-query
          comint-read-noecho comint-password-function
          set!comint-password-function comint-send-invisible send-invisible
          *comint--prompt-recursion-depth*
          comint-watch-for-password-prompt
          comint-get-next-from-history comint-accumulate
          comint-goto-process-mark comint-bol-or-process-mark
          comint-set-process-mark
          comint-previous-matching-input-string
          comint-previous-matching-input-string-position
          comint-search-arg comint-search-start comint-restore-input
          comint-delete-input comint-mode-hook comint-exec-hook
          *comint-prompt-regexp* comint-prompt-regexp set!comint-prompt-regexp
          *comint-prompt-read-only*
          *comint-input-ring-size* *comint-input-ring-file-name*
          *comint-input-autoexpand* *comint-input-ignoredups*
          *comint-input-sender* *comint-input-filter*
          comint-input-filter set!comint-input-filter
          *comint-get-old-input* comint-get-old-input set!comint-get-old-input
          *comint-eol-on-send* comint-eol-on-send set!comint-eol-on-send
          *comint-use-prompt-regexp* comint-use-prompt-regexp
          set!comint-use-prompt-regexp
          *comint-process-echoes* comint-process-echoes
          set!comint-process-echoes
          *comint-highlight-input* *comint-pager*
          *comint-terminfo-terminal* *comint-delete-old-input*
          *comint-input-ring-separator* *comint-input-history-ignore*
          *comint-delimiter-argument-list* comint-delimiter-argument-list
          *comint-input-ring-file-prefix* *comint-output-filter-functions*
          *comint-preoutput-filter-functions*
          *comint-input-filter-functions* *comint-inhibit-carriage-motion*
          *comint-scroll-to-bottom-on-input* *comint-move-point-for-output*
          *comint-scroll-show-maximum-output*
          *comint-move-point-for-matching-input*
          *comint-buffer-maximum-size* *comint-password-prompt-regexp*
          *comint-password-prompt-max-length* *comint-input-sender-no-newline*
          *comint-max-line-length* comint-last-input-start comint-last-input-end
          comint-last-output-start comint-input-ring comint-input-ring-index
          comint-save-input-ring-index comint-stored-incomplete-input
          comint-accum-marker comint-last-prompt comint-ptyp
          comint-matching-input-from-input-string comint-file-name-prefix
          comint-file-name-chars comint-file-name-quote-list)

  (begin

    ;;----------------------------------------------------------------
    ;; The buffer-local variables (`comint.el:159'-`:527').
    ;;----------------------------------------------------------------

    (define *comint-prompt-regexp* (make-parameter "^"))
    ;; ^ `:159' `(defvar comint-prompt-regexp "^")': "Regexp to
    ;; recognize prompts in the inferior process. ... This variable is
    ;; only used if the variable `comint-use-prompt-regexp' is non-nil."
    (define (comint-prompt-regexp)
      (buffer-local-value (current-buffer) 'comint-prompt-regexp
                          (*comint-prompt-regexp*)))
    (define (set!comint-prompt-regexp v)
      (set-buffer-local-value! (current-buffer) 'comint-prompt-regexp v))

    (define-custom *comint-prompt-read-only* #f
      "If non-nil, the comint prompt is read only.
The read only region includes the newline before the prompt.
This does not affect existing prompts.
Certain derived modes may override this option."
      :type 'boolean :group 'comint :version "22.1")
    (define (comint-prompt-read-only)
      (buffer-local-value (current-buffer) 'comint-prompt-read-only
                          (*comint-prompt-read-only*)))
    (define (set!comint-prompt-read-only v)
      (set-buffer-local-value! (current-buffer) 'comint-prompt-read-only v))

    (define *comint-delimiter-argument-list* (make-parameter '()))
    ;; ^ `:201': "List of characters to recognize as separate arguments
    ;; in input."
    (define (comint-delimiter-argument-list)
      (buffer-local-value (current-buffer) 'comint-delimiter-argument-list
                          (*comint-delimiter-argument-list*)))
    (define (set!comint-delimiter-argument-list v)
      (set-buffer-local-value! (current-buffer) 'comint-delimiter-argument-list v))

    (define-custom *comint-input-autoexpand* #f
      "If non-nil, expand input command history references on completion.
This mirrors the optional behavior of tcsh (its autoexpand and histlist)."
      :type '(choice (const :tag "off" nil) (const input) (const history)
                     (other :tag "on" t))
      :group 'comint)
    (define (comint-input-autoexpand)
      (buffer-local-value (current-buffer) 'comint-input-autoexpand
                          (*comint-input-autoexpand*)))
    (define (set!comint-input-autoexpand v)
      (set-buffer-local-value! (current-buffer) 'comint-input-autoexpand v))

    (define-custom *comint-highlight-input* #t
      "If non-nil, highlight input with `comint-highlight-input' face.
Otherwise keep the original highlighting untouched."
      :version "28.1" :type 'boolean :group 'comint)

    (define-custom *comint-input-ignoredups* #f
      "If non-nil, don't add input matching the last on the input ring.
This mirrors the optional behavior of bash."
      :type 'boolean :group 'comint)
    (define (comint-input-ignoredups)
      (buffer-local-value (current-buffer) 'comint-input-ignoredups
                          (*comint-input-ignoredups*)))
    (define (set!comint-input-ignoredups v)
      (set-buffer-local-value! (current-buffer) 'comint-input-ignoredups v))

    (define-custom *comint-input-ring-file-name* #f
      "If non-nil, name of the file to read/write input history.
See also `comint-read-input-ring' and `comint-write-input-ring'."
      :type '(choice (const :tag "Disable input history" nil) file)
      :group 'comint)
    (define (comint-input-ring-file-name)
      (buffer-local-value (current-buffer) 'comint-input-ring-file-name
                          (*comint-input-ring-file-name*)))
    (define (set!comint-input-ring-file-name v)
      (set-buffer-local-value! (current-buffer) 'comint-input-ring-file-name v))

    (define-custom *comint-pager* #f
      "If non-nil, the program to use for pagination of program output.
If nil, use the default pager."
      :version "30.1"
      :type '(choice (const :tag "Use default PAGER" nil)
                     (const :tag "Don't do paging (PAGER=cat)" "cat")
                     (string :tag "Program name or absolute path of pager"))
      :group 'comint)

    (define-custom *comint-insert-previous-argument-from-end* #f
      "If non-nil, `comint-insert-previous-argument' counts args from the end.
If this variable is nil, the default, `comint-insert-previous-argument'
counts the arguments from the beginning; if non-nil, it counts from
the end instead.  This emulates the behavior of `ESC-NUM ESC-.'
in both Bash and zsh: in Bash, `number' counts from the
beginning (variable is nil), while in zsh, it counts from the end."
      :type 'boolean
      :group 'comint
      :version "27.1")

    (define *comint-input-ring-file-prefix* (make-parameter #f))
    ;; ^ `:291': "The prefix to skip when parsing the input ring file."

    (define-custom *comint-scroll-to-bottom-on-input* #f
      "Controls whether input to interpreter causes window to scroll.
If nil, then do not scroll.  If t or `all', scroll all windows showing
buffer.  If `this', scroll only the selected window."
      :type '(choice (const :tag "off" nil) (const t) (const all) (const this))
      :group 'comint)
    (define (comint-scroll-to-bottom-on-input)
      (buffer-local-value (current-buffer) 'comint-scroll-to-bottom-on-input
                          (*comint-scroll-to-bottom-on-input*)))
    (define (set!comint-scroll-to-bottom-on-input v)
      (set-buffer-local-value! (current-buffer)
                               'comint-scroll-to-bottom-on-input v))

    (define-custom *comint-move-point-for-output* #f
      "Controls whether interpreter output moves point to the end of the output.
If nil, then output never moves point to the output.
If t or `all', move point in all windows showing the buffer.
If `this', move point only the selected window.
If `others', move point only in other windows."
      :type '(choice (const :tag "off" nil) (const t) (const all)
                     (const this) (const others))
      :group 'comint)
    (define (comint-move-point-for-output)
      (buffer-local-value (current-buffer) 'comint-move-point-for-output
                          (*comint-move-point-for-output*)))
    (define (set!comint-move-point-for-output v)
      (set-buffer-local-value! (current-buffer) 'comint-move-point-for-output v))

    (define-custom *comint-move-point-for-matching-input* 'after-input
      "Controls where to place point after matching input."
      :version "26.1"
      :type '(radio (const :tag "Stay after input" after-input)
                    (const :tag "Move to end of line" end-of-line))
      :group 'comint)

    (define-custom *comint-scroll-show-maximum-output* #t
      "Controls how to scroll due to interpreter output.
Non-nil means scroll so that the window is full of text
and point is on the last line."
      :type 'boolean :group 'comint)
    (define (comint-scroll-show-maximum-output)
      (buffer-local-value (current-buffer) 'comint-scroll-show-maximum-output
                          (*comint-scroll-show-maximum-output*)))
    (define (set!comint-scroll-show-maximum-output v)
      (set-buffer-local-value! (current-buffer)
                               'comint-scroll-show-maximum-output v))

    (define-custom *comint-buffer-maximum-size* 1024
      "The maximum size in lines for Comint buffers.
Comint buffers are truncated from the top to be no greater than this
number, if the function `comint-truncate-buffer' is on
`comint-output-filter-functions'."
      :type 'natnum :group 'comint)

    (define-custom *comint-input-ring-size* 500
      "Size of the input history ring in `comint-mode'."
      :type 'natnum :group 'comint :version "23.2")
    (define (comint-input-ring-size)
      (buffer-local-value (current-buffer) 'comint-input-ring-size
                          (*comint-input-ring-size*)))
    (define (set!comint-input-ring-size v)
      (set-buffer-local-value! (current-buffer) 'comint-input-ring-size v))

    (define *comint-input-ring-separator* (make-parameter "\n"))
    ;; ^ `:373': "Separator between commands in the history file."

    (define *comint-input-history-ignore* (make-parameter "^#"))
    ;; ^ `:376': "Regexp for history entries that should be ignored
    ;; when Comint initializes."

    (define-custom *comint-process-echoes* #f
      "If non-nil, assume that the subprocess echoes any input.
If so, delete one copy of the input so that only one copy eventually
appears in the buffer."
      :type 'boolean :group 'comint)
    (define (comint-process-echoes)
      (buffer-local-value (current-buffer) 'comint-process-echoes
                          (*comint-process-echoes*)))
    (define (set!comint-process-echoes v)
      (set-buffer-local-value! (current-buffer) 'comint-process-echoes v))

    ;; `comint-password-prompt-regexp` (`:399'): built by `concat' over
    ;; `regexp-opt''s groups and the two `mule-conf.scm' lists, which is
    ;; the shape of Emacs's own `(concat ...)'.
    (define-custom *comint-password-prompt-regexp*
      (concat
       "\\(^ *\\|"
       (regexp-opt
        '("Enter" "enter" "Enter same" "enter same" "Enter the" "enter the"
          "Current" "Vault" "SSH" "BECOME"
          "Enter Auth" "enter auth" "Old" "old" "New" "new" "login"
          "Kerberos" "CVS" "UNIX" " SMB" "LDAP" "PEM" "SUDO"
          "[sudo]" "[sudo: authenticate]" "[su: authenticate]"
          "doas" "Repeat" "Bad" "Retype" "Verify")
        #t)
       " +.*\\)"
       "\\(?:" (regexp-opt (*password-word-equivalents*)) "\\|Response\\)"
       "\\(?:\\(?:, try\\)? *again\\| (empty for no passphrase)\\| (again)\\)?"
       "\\(?: [[:alpha:]]+ .+\\)?[[:blank:]]*"
       "[" (apply string (*password-colon-equivalents*)) "][[:space:]]*\\'"
       "\\|^Enter encryption key: (repeat) *\\'"
       "\\|^Vault password ([^@-][^@]*): \\'"
       "\\|^[^@ \t\n]+@[^@ \t\n]+'s password: *\\'"
       "\\|^([^)@ \t\n]+@[^)@ \t\n]+) Password\\(?: for [^)@ \t\n]+@[^)@ \t\n]+\\)?: *\\'")
      "Regexp matching prompts for passwords in the inferior process.
This is used by `comint-watch-for-password-prompt'."
      :version "31.1" :type 'regexp :group 'comint)

    (define *comint-password-prompt-max-length* (make-parameter 256))
    ;; ^ `:437'.

    (define *comint-get-old-input* (make-parameter #f))
    ;; ^ `:443' `(defvar comint-get-old-input #'comint-get-old-input-default)'.
    ;; The procedure is set at the end of this file, after its definition.
    (define (comint-get-old-input)
      (buffer-local-value (current-buffer) 'comint-get-old-input
                          (*comint-get-old-input*)))
    (define (set!comint-get-old-input v)
      (set-buffer-local-value! (current-buffer) 'comint-get-old-input v))

    (define *comint-dynamic-complete-functions* (make-parameter '()))
    ;; ^ `:452'. The completion tranche will fill it.

    (define *comint-input-filter* (make-parameter #f))
    ;; ^ `:460' `(defvar comint-input-filter #'comint-nonblank-p)'.
    (define (comint-input-filter)
      (buffer-local-value (current-buffer) 'comint-input-filter
                          (*comint-input-filter*)))
    (define (set!comint-input-filter v)
      (set-buffer-local-value! (current-buffer) 'comint-input-filter v))

    (define *comint-input-filter-functions* (make-parameter '()))
    (define (comint-input-filter-functions)
      (buffer-local-value (current-buffer) 'comint-input-filter-functions
                          (*comint-input-filter-functions*)))
    (define (set!comint-input-filter-functions v)
      (set-buffer-local-value! (current-buffer)
                               'comint-input-filter-functions v))

    (define-custom *comint-output-filter-functions*
      ;; Emacs's default is `(ansi-color-process-output
      ;; comint-postoutput-scroll-to-bottom comint-watch-for-password-prompt)';
      ;; `ansi-color-process-output` is the one still missing
      ;; (`ansi-color` is not ported).
      '()
      "Functions to call after output is inserted into the buffer.
One possible function is `comint-postoutput-scroll-to-bottom'.
These functions get one argument, a string containing the text as
originally inserted."
      :type 'hook :group 'comint)

    (define *comint-input-sender-no-newline* (make-parameter #f))
    ;; ^ `:483'.

    (define *comint-input-sender* (make-parameter #f))
    ;; ^ `:486' `(defvar comint-input-sender #'comint-simple-send)'.
    (define (comint-input-sender)
      (buffer-local-value (current-buffer) 'comint-input-sender
                          (*comint-input-sender*)))
    (define (set!comint-input-sender v)
      (set-buffer-local-value! (current-buffer) 'comint-input-sender v))

    (define-custom *comint-eol-on-send* #t
      "Non-nil means go to the end of the line before sending input.
See `comint-send-input'."
      :type 'boolean :group 'comint)
    (define (comint-eol-on-send)
      (buffer-local-value (current-buffer) 'comint-eol-on-send
                          (*comint-eol-on-send*)))
    (define (set!comint-eol-on-send v)
      (set-buffer-local-value! (current-buffer) 'comint-eol-on-send v))

    (define-custom *comint-use-prompt-regexp* #f
      "If non-nil, use `comint-prompt-regexp' to recognize prompts.
If nil, then program output and user-input are given different `field'
properties, which Emacs commands can use to distinguish them."
      :type 'boolean :group 'comint)
    (define (comint-use-prompt-regexp)
      (buffer-local-value (current-buffer) 'comint-use-prompt-regexp
                          (*comint-use-prompt-regexp*)))
    (define (set!comint-use-prompt-regexp v)
      (set-buffer-local-value! (current-buffer) 'comint-use-prompt-regexp v))

    (define-custom comint-mode-hook '()
      "Hook run upon entry to `comint-mode'.
This is run before the process is cranked up."
      :type 'hook :group 'comint)
    (define-custom comint-exec-hook '()
      "Hook run each time a process is exec'd by `comint-exec'.
This is called after the process is cranked up.  It is useful for things that
must be done each time a process is executed in a Comint mode buffer (e.g.,
`set-process-query-on-exit-flag').  In contrast, `comint-mode-hook' is only
executed once, when the buffer is created."
      :type 'hook :group 'comint)
    ;; ^ `:512', `:518'. Plain lists, as `cc-mode.scm` spells mode hooks.

    (define-custom *comint-terminfo-terminal* "dumb"
      "Value to use for TERM when the system uses terminfo."
      :type '(choice (const "dumb") (const "dumb-emacs-ansi") string)
      :group 'comint :version "26.1")

    (define *comint-max-line-length* 4096)
    ;; ^ `:539' - `(pcase system-type ('gnu/linux 4096) ...)'; this tree
    ;; runs on GNU/Linux.

    (define comint-mode-map (make-sparse-keymap "comint-mode-map"))
    ;; ^ `:548'. The object in Emacs's order; the bindings at the end of
    ;; the file, because a Scheme keymap holds procedures.

    (define (comint-ptyp)
      (buffer-local-value (current-buffer) 'comint-ptyp #t))
    (define (set!comint-ptyp v)
      (set-buffer-local-value! (current-buffer) 'comint-ptyp v))

    ;; `:670'-`:686' the per-buffer state.
    (define (comint-input-ring)
      (buffer-local-value (current-buffer) 'comint-input-ring #f))
    (define (set!comint-input-ring v)
      (set-buffer-local-value! (current-buffer) 'comint-input-ring v))
    (define (comint-last-input-start)
      (buffer-local-value (current-buffer) 'comint-last-input-start #f))
    (define (set!comint-last-input-start v)
      (set-buffer-local-value! (current-buffer) 'comint-last-input-start v))
    (define (comint-last-input-end)
      (buffer-local-value (current-buffer) 'comint-last-input-end #f))
    (define (set!comint-last-input-end v)
      (set-buffer-local-value! (current-buffer) 'comint-last-input-end v))
    (define (comint-last-output-start)
      (buffer-local-value (current-buffer) 'comint-last-output-start #f))
    (define (set!comint-last-output-start v)
      (set-buffer-local-value! (current-buffer) 'comint-last-output-start v))
    (define (comint-input-ring-index)
      (buffer-local-value (current-buffer) 'comint-input-ring-index #f))
    (define (set!comint-input-ring-index v)
      (set-buffer-local-value! (current-buffer) 'comint-input-ring-index v))
    (define (comint-matching-input-from-input-string)
      (buffer-local-value (current-buffer)
                          'comint-matching-input-from-input-string ""))
    (define (set!comint-matching-input-from-input-string v)
      (set-buffer-local-value! (current-buffer)
                               'comint-matching-input-from-input-string v))
    (define (comint-save-input-ring-index)
      (buffer-local-value (current-buffer) 'comint-save-input-ring-index #f))
    (define (set!comint-save-input-ring-index v)
      (set-buffer-local-value! (current-buffer) 'comint-save-input-ring-index v))
    (define (comint-accum-marker)
      (buffer-local-value (current-buffer) 'comint-accum-marker #f))
    (define (set!comint-accum-marker v)
      (set-buffer-local-value! (current-buffer) 'comint-accum-marker v))
    (define (comint-insert-previous-argument-last-start-pos)
      (buffer-local-value (current-buffer)
                          'comint-insert-previous-argument-last-start-pos #f))
    (define (set!comint-insert-previous-argument-last-start-pos v)
      (set-buffer-local-value! (current-buffer)
                               'comint-insert-previous-argument-last-start-pos v))
    (define (comint-insert-previous-argument-last-index)
      (buffer-local-value (current-buffer)
                          'comint-insert-previous-argument-last-index #f))
    (define (set!comint-insert-previous-argument-last-index v)
      (set-buffer-local-value! (current-buffer)
                               'comint-insert-previous-argument-last-index v))
    (define (comint-stored-incomplete-input)
      (buffer-local-value (current-buffer) 'comint-stored-incomplete-input ""))
    (define (set!comint-stored-incomplete-input v)
      (set-buffer-local-value! (current-buffer) 'comint-stored-incomplete-input v))
    (define (comint-file-name-prefix)
      (buffer-local-value (current-buffer) 'comint-file-name-prefix ""))
    (define (set!comint-file-name-prefix v)
      (set-buffer-local-value! (current-buffer) 'comint-file-name-prefix v))
    (define (comint-file-name-chars)
      (buffer-local-value (current-buffer) 'comint-file-name-chars
                          "~/A-Za-z0-9_^$!#%&{}@`'.,:()-"))
    (define (set!comint-file-name-chars v)
      (set-buffer-local-value! (current-buffer) 'comint-file-name-chars v))
    (define (comint-file-name-quote-list)
      (buffer-local-value (current-buffer) 'comint-file-name-quote-list #f))
    (define (set!comint-file-name-quote-list v)
      (set-buffer-local-value! (current-buffer) 'comint-file-name-quote-list v))
    (define (comint-last-prompt)
      (buffer-local-value (current-buffer) 'comint-last-prompt #f))
    (define (set!comint-last-prompt v)
      (set-buffer-local-value! (current-buffer) 'comint-last-prompt v))

    (define *comint-preoutput-filter-functions* (make-parameter '()))
    (define (comint-preoutput-filter-functions)
      (buffer-local-value (current-buffer) 'comint-preoutput-filter-functions
                          (*comint-preoutput-filter-functions*)))
    (define (set!comint-preoutput-filter-functions v)
      (set-buffer-local-value! (current-buffer)
                               'comint-preoutput-filter-functions v))

    (define-custom *comint-inhibit-carriage-motion* #f
      "If nil, Comint will interpret `carriage control' characters in output.
See `comint-carriage-motion' for details."
      :type 'boolean :group 'comint)

    (define-custom *comint-delete-old-input* #t
      "When non-nil, delete old input on inserting previous input."
      :type 'boolean :group 'comint :version "29.1")
    (define (comint-delete-old-input)
      (buffer-local-value (current-buffer) 'comint-delete-old-input
                          (*comint-delete-old-input*)))
    (define (set!comint-delete-old-input v)
      (set-buffer-local-value! (current-buffer) 'comint-delete-old-input v))

    (define *comint--prompt-rear-nonsticky*
      '( field inhibit-line-move-field-capture read-only font-lock-face
         insert-in-front-hooks))
    ;; ^ `:1915' - "Text properties we set on the prompt and don't want to
    ;; leak past it."

    (define system-uses-terminfo #t)
    ;; ^ `sysdep.c`'s DEFVAR_BOOL, true on every GNU/Linux build; placed
    ;; here because comint-term-environment is its only reader in this
    ;; tree.

    ;;----------------------------------------------------------------
    ;; `comint-mode` (`comint.el:707').
    ;;----------------------------------------------------------------

    (define-derived-mode (comint-mode fundamental-mode "Comint"
                                      comint-mode-map comint-mode-hook)
      "Major mode for interacting with an inferior interpreter.
Interpreter name is same as buffer name, sans the asterisks.
Return at end of buffer sends line as input.
Return not at end copies rest of line to end and sends it.
Setting variable `comint-eol-on-send' means jump to the end of the line
before submitting new input.

The mode maintains an input history of size `comint-input-ring-size'."
      ;; The body is Emacs's, less the `make-local-variable` calls (the
      ;; accessors in this file read the buffer's slot first) and less
      ;; the three pieces named in the header as not carried: the
      ;; input-method `text-conversion-style`, the `add-function` on
      ;; `filter-buffer-substring-function`, and the
      ;; `completion-at-point-functions` local hook.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer)
                               'mode-line-process '(":%s"))
      (set!comint-last-input-start (point-min-marker))
      (set!comint-last-input-end (point-min-marker))
      (set!comint-last-output-start (make-marker))
      (unless (comint-input-ring)
        (set!comint-input-ring (make-ring (comint-input-ring-size))))
      (unless (comint-input-ring-index)
        (set!comint-input-ring-index #f))
      (unless (comint-save-input-ring-index)
        (set!comint-save-input-ring-index #f))
      (set!comint-file-name-prefix (or (file-remote-p (default-directory)) ""))
      (set!comint-accum-marker (make-marker))
      (set!font-lock-defaults! '(#f #t))
      (set-buffer-local-value! (current-buffer) 'next-line-add-newlines #f)
      ;; "Local hook so we can click to select the buffer before the
      ;; command runs" (`comint.el:785'): `(add-hook 'pre-command-hook
      ;; #'comint-preinput-scroll-to-bottom t t)' - depth t (appended)
      ;; and LOCAL.
      (add-hook *pre-command-hook* comint-preinput-scroll-to-bottom #t #t))

    ;;----------------------------------------------------------------
    ;; `comint-check-proc` and the exec cluster (`:800'-`:1015').
    ;;----------------------------------------------------------------

    (define (comint-check-proc buffer)
      ;; GNU Emacs's `comint-check-proc` (`comint.el:800`): "Return
      ;; non-nil if there is a living process associated w/buffer BUFFER.
      ;; Living means the status is `open', `run', or `stop'. BUFFER can
      ;; be either a buffer or the name of one."
      ;;--------------------------------------------------------------
      (let ((proc (get-buffer-process buffer)))
        (and proc (memq (process-status proc) '(open run stop)))))

    (define (make-comint-in-buffer name buffer program . rest)
      ;; GNU Emacs's `make-comint-in-buffer` (`comint.el:808`): "Make a
      ;; Comint process NAME in BUFFER, running PROGRAM. ... If there is
      ;; a running process in BUFFER, it is not restarted."
      ;;--------------------------------------------------------------
      (let ((startfile (if (pair? rest) (car rest) #f))
            (switches (if (pair? rest) (cdr rest) '())))
        (set! buffer (get-buffer-create (or buffer (concat "*" name "*"))))
        (unless (comint-check-proc buffer)
          (with-current-buffer buffer
            (unless (derived-mode-p 'comint-mode)
              (comint-mode)))
          (comint-exec buffer name program startfile switches))
        buffer))

    (define (make-comint name program . rest)
      ;; GNU Emacs's `make-comint` (`comint.el:839`): "Make a Comint
      ;; process NAME in a buffer, running PROGRAM. ... Returns the
      ;; (possibly newly created) process buffer."
      ;;--------------------------------------------------------------
      (apply make-comint-in-buffer name #f program rest))

    (define (comint-exec buffer name command startfile switches)
      ;; GNU Emacs's `comint-exec` (`comint.el:875`): "Start up a process
      ;; named NAME in buffer BUFFER for Comint modes. ... This function
      ;; blasts any old process running in the buffer, and does not set
      ;; the buffer mode. ... The hook `comint-exec-hook' is run after
      ;; each exec."
      ;;
      ;; The `open-network-stream` arm (COMMAND a cons) is not carried -
      ;; there are no network connections in this tree - and a cons
      ;; COMMAND signals that.
      ;;--------------------------------------------------------------
      (with-current-buffer buffer
        (let ((proc (get-buffer-process buffer)))
          (if proc (delete-process proc)))
        (let ((proc (if (pair? command)
                        (error "Network streams are not supported")
                        (comint-exec-1 name buffer command switches))))
          (set-process-filter proc comint-output-filter)
          (set!comint-ptyp (*process-connection-type*))
          (goto-char (point-max))
          (set-marker (process-mark proc) (point))
          (when startfile
            (comint-send-string proc
                                (with-temp-buffer
                                  (insert-file-contents startfile)
                                  (buffer-string))))
          (run-hooks comint-exec-hook)
          buffer)))

    (define (comint-exec-1 name buffer command switches)
      ;; GNU Emacs's `comint-exec-1` (`comint.el:914`) - "This auxiliary
      ;; function cranks up the process for comint-exec in the
      ;; appropriate environment."
      ;;
      ;; Emacs's `let` of `process-environment` and `exec-path` are
      ;; `parameterize` here (they are parameters), and its `let` of
      ;; `default-directory` is `call-with-buffer-local`.
      ;;--------------------------------------------------------------
      (let* ((env (append (comint-term-environment)
                          (list (concat "INSIDE_EMACS=" emacs-version ",comint"))
                          (if (*comint-pager*)
                              (if (string? (*comint-pager*))
                                  (list (concat "PAGER=" (*comint-pager*)))
                                  (error "comint-pager should be a string: ~a"
                                         (*comint-pager*)))
                              '())
                          (*process-environment*)))
             (dd (default-directory))
             (dd (if (file-accessible-directory-p dd) dd "/")))
        (call-with-buffer-local
         'default-directory dd
         (lambda ()
           (parameterize
               ((*process-environment* env)
                (*exec-path*
                 (if (and command (file-name-directory-part command))
                     (cons dd (*exec-path*))
                     (*exec-path*))))
             (let ((proc (apply start-file-process name buffer command switches)))
               (unless (processp proc) (error "No process started"))
               (let* ((coding-systems (process-coding-system proc))
                      (decoding (car coding-systems))
                      (encoding (cdr coding-systems)))
                 ;; Even if `start-file-process` left the coding system
                 ;; for encoding undecided, use the decoding one, with
                 ;; EOL conversion suppressed.
                 (if (and decoding (not encoding))
                     (set-process-coding-system
                      proc decoding
                      (coding-system-change-eol-conversion decoding 'unix)))
                 proc)))))))

    (define (comint-term-environment)
      ;; GNU Emacs's `comint-term-environment` (`comint.el:950`): "Return
      ;; an environment variable list for terminal configuration."
      ;;
      ;; The DEFUN `window-width` is this tree's `window-body-width`.
      ;;--------------------------------------------------------------
      (if system-uses-terminfo
          (list (concat "TERM=" (*comint-terminfo-terminal*))
                "TERMCAP="
                (concat "COLUMNS="
                        (number->string (window-body-width (selected-window)))))
          (list "TERM=emacs"
                (concat "TERMCAP=emacs:co#"
                        (number->string (window-body-width (selected-window)))
                        ":tc=unknown:"))))

    (define (comint-nonblank-p str)
      ;; GNU Emacs's `comint-nonblank-p` (`comint.el:967`): "Return
      ;; non-nil if STR contains non-whitespace syntax."
      ;;--------------------------------------------------------------
      (not (string-match "\\`\\s *\\'" str)))

    ;;----------------------------------------------------------------
    ;; Input history (`comint.el:1016'-`:1320').
    ;;----------------------------------------------------------------

    (define (comint-read-input-ring . silent-arg)
      ;; GNU Emacs's `comint-read-input-ring` (`comint.el:1039`): "Set
      ;; the buffer's `comint-input-ring' from a history file. ..."
      ;;--------------------------------------------------------------
      (let ((silent (if (pair? silent-arg) (car silent-arg) #f)))
        (cond ((or (not (comint-input-ring-file-name))
                   (string-equal (comint-input-ring-file-name) ""))
               #f)
              ((not (file-readable-p (comint-input-ring-file-name)))
               (or silent
                   (message "Cannot read history file %s"
                            (comint-input-ring-file-name))))
              (else
               (let* ((file (comint-input-ring-file-name))
                      (ring-size (min 1500 (comint-input-ring-size)))
                      (ring (make-ring ring-size))
                      (ring-max-size (comint-input-ring-size))
                      (ring-separator (*comint-input-ring-separator*))
                      (ring-file-prefix (*comint-input-ring-file-prefix*))
                      (history-ignore (*comint-input-history-ignore*))
                      (ignoredups (comint-input-ignoredups)))
                 (with-temp-buffer
                   (insert-file-contents file)
                   (goto-char (point-max))
                   (let loop ((count 0))
                     (if (and (< count ring-max-size)
                              (re-search-backward ring-separator #f #t))
                         (let ((end (match-beginning 0)))
                           (goto-char (if (re-search-backward ring-separator #f #t)
                                          (match-end 0)
                                          (point-min)))
                           (when (and ring-file-prefix (looking-at ring-file-prefix))
                             (goto-char (match-end 0)))
                           (let ((history (buffer-substring (point) end)))
                             (when (and (not (string-match history-ignore history))
                                        (or (not ignoredups)
                                            (ring-empty-p ring)
                                            (not (string-equal
                                                  (ring-ref ring (- (ring-length ring) 1))
                                                  history))))
                               (when (= count ring-size)
                                 (ring-extend ring
                                              (min (- ring-max-size ring-size)
                                                   ring-size))
                                 (set! ring-size (ring-size ring)))
                               (ring-insert-at-beginning ring history)
                               (loop (+ count 1)))))))
                 (set!comint-input-ring ring)
                 (set!comint-input-ring-index #f)))))))

    ;;----------------------------------------------------------------
    ;; History expansion (`comint.el:1396'-`:1552').
    ;;----------------------------------------------------------------

    (define (comint-replace-by-expanded-history . args)
      ;; GNU Emacs's `comint-replace-by-expanded-history`
      ;; (`comint.el:1396'): "Expand input command history references
      ;; before point. Expansion is dependent on the value of
      ;; `comint-input-autoexpand'. ... Returns t if successful."
      ;;
      ;; Emacs splits the work in two: the c-a-p function does a
      ;; side-effect-free dry run that answers a thunk when (and only
      ;; when) an expandable reference is present, and this calls the
      ;; thunk. That split exists so the same machinery can serve
      ;; `completion-at-point-functions`; the dry run is carried here
      ;; anyway, because it is also what makes the function *do
      ;; nothing* when `comint-input-autoexpand' is nil - which is
      ;; Emacs's observable behaviour, measured on 31.1: with the
      ;; variable nil and "!!" in the buffer it answers nil and leaves
      ;; the text alone.
      ;;--------------------------------------------------------------
      (let ((silent (if (pair? args) (car args) #f))
            (start (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (let ((f (comint-c-a-p-replace-by-expanded-history silent start)))
          (if f (f)))))

    (define (comint-c-a-p-replace-by-expanded-history . args)
      ;; GNU Emacs's `comint-c-a-p-replace-by-expanded-history`
      ;; (`comint.el:1421`): "Expand input command history at point. For
      ;; use on `completion-at-point-functions'."
      ;;
      ;; The `catch` is the third conjunct of the `and`: it runs the
      ;; dry run, which THROWS (tag `dry-run') at the first expandable
      ;; reference instead of changing the buffer, and its non-nil
      ;; answer is the signal that there is something to expand. The
      ;; thrown value is never used as a function - the `if` then
      ;; answers the thunk below.
      ;;--------------------------------------------------------------
      (let ((silent (if (pair? args) (car args) #f))
            (start (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (if (and (comint-input-autoexpand)
                 (if (comint-use-prompt-regexp)
                     ;; Use comint-prompt-regexp
                     (save-excursion
                       (beginning-of-line)
                       (looking-at (concat (comint-prompt-regexp) "!\\|\\^")))
                     ;; Use input fields. User input that hasn't been
                     ;; entered yet, at the end of the buffer, has a nil
                     ;; `field' property.
                     (and (not (get-char-property (point) 'field))
                          (string-match "!\\|^\\^" (field-string))))
                 (catch 'dry-run
                   (lambda ()
                     (comint-replace-by-expanded-history-before-point
                      silent start 'dry-run))
                   (lambda (key value) value)))
            (lambda ()
              ;; Looks like there might be history references in the
              ;; command.
              (let ((previous-modified-tick (buffer-modified-tick)))
                (comint-replace-by-expanded-history-before-point silent start)
                (/= previous-modified-tick (buffer-modified-tick)))))))

    (define (comint-replace-by-expanded-history-before-point silent . rest)
      ;; GNU Emacs's `comint-replace-by-expanded-history-before-point`
      ;; (`comint.el:1444'): "Expand directory stack reference before
      ;; point. ... Returns t if successful. ... If DRY-RUN is non-nil,
      ;; throw to DRY-RUN before performing any actual side-effect."
      ;;
      ;; Every branch that would change the buffer (or say something
      ;; about the reference) starts with `(if dry-run (throw dry-run
      ;; TAG))' - the C's first statement in the matching branch. The
      ;; distinction between the tags (`message`, `history`, `expand')
      ;; is not observable through the caller above; it is kept because
      ;; it is what the C says.
      ;;--------------------------------------------------------------
      (let ((start (if (pair? rest) (car rest) #f))
            (dry-run (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f)))
        (save-excursion
          (let ((toend (- (line-end-position) (point))))
            (let ((start (or start (comint-line-beginning-position))))
              (goto-char start)
              (let loop ()
                (skip-chars-forward "^!^" (- (line-end-position) toend))
                (when (< (point) (- (line-end-position) toend))
                  ;; References: !!, !-num, !foo, !?foo, !{bar},
                  ;; !?{bar}, ^oh, ^my^, ^god^it, ^never^ends^, with
                  ;; argument-range suffixes after the plings.
                  (set!comint-input-ring-index #f)
                  (cond
                   ((or (let ((pc (preceding-char)))
                          (and (char? pc) (char=? pc #\\)))
                        (comint-within-quotes start (point)))
                    ;; The history is quoted, or we're in quotes.
                    (goto-char (+ (point) 1)))
                   ((looking-at "![0-9]+\\($\\|[^-]\\)")
                    ;; We cannot know the interpreter's idea of input
                    ;; line numbers.
                    (if dry-run (throw dry-run 'message))
                    (goto-char (match-end 0))
                    (message "Absolute reference cannot be expanded"))
                   ((looking-at "!-\\([0-9]+\\):?\\([0-9^$*-]+\\)?")
                    ;; Just a number of args from `number' lines backward.
                    (if dry-run (throw dry-run 'history))
                    (let* ((mb2 (match-beginning 2))
                           (me2 (match-end 2))
                           (number (- (string-to-number
                                       (buffer-substring (match-beginning 1)
                                                         (match-end 1)))
                                      1)))
                      (if (<= number (ring-length (comint-input-ring)))
                          (begin
                            (replace-match
                             (comint-args (comint-previous-input-string number)
                                          mb2 me2)
                             #t #t)
                            (set!comint-input-ring-index number)
                            (message "History item: %d" (+ number 1)))
                          (begin
                            (goto-char (match-end 0))
                            (message "Relative reference exceeds input history size")))))
                   ((or (looking-at "!!?:?\\([0-9^$*-]+\\)")
                        (looking-at "!!"))
                    ;; Just a number of args from the previous input line.
                    (if dry-run (throw dry-run 'expand))
                    (let ((mb1 (match-beginning 1))
                          (me1 (match-end 1)))
                      (replace-match (comint-args (comint-previous-input-string 0)
                                                  mb1 me1)
                                     #t #t)
                      (message "History item: previous")))
                   ((looking-at
                     "!\\??\\({\\(.+\\)}\\|\\(\\sw+\\)\\):?\\([0-9^$*-]+\\)?")
                    ;; Most recent input starting with or containing
                    ;; (possibly protected) string, maybe just a number
                    ;; of args.
                    (if dry-run (throw dry-run 'expand))
                    (let* ((mb1 (match-beginning 1)) (me1 (match-end 1))
                           (mb2 (match-beginning 2)) (me2 (match-end 2))
                           (mb4 (match-beginning 4)) (me4 (match-end 4))
                           (exp (buffer-substring (or mb2 mb1) (or me2 me1)))
                           (pref (if (looking-at-p "!\\?") "" "^"))
                           (pos (save-match-data
                                  (comint-previous-matching-input-string-position
                                   (concat pref (regexp-quote exp)) 1))))
                      (if (not pos)
                          (begin
                            (goto-char (match-end 0))
                            (or silent
                                (begin (message "Not found") (ding))))
                          (begin
                            (set!comint-input-ring-index pos)
                            (replace-match
                             (comint-args (ring-ref (comint-input-ring) pos)
                                          mb4 me4)
                             #t #t)
                            (message "History item: %d" (+ pos 1))))))
                   ((looking-at "\\^\\([^^]+\\)\\^?\\([^^]*\\)\\^?")
                    ;; Quick substitution on the previous input line.
                    (if dry-run (throw dry-run 'expand))
                    (let ((old (buffer-substring (match-beginning 1)
                                                 (match-end 1)))
                          (new (buffer-substring (match-beginning 2)
                                                 (match-end 2)))
                          (mb0 (match-beginning 0)))
                      (replace-match (comint-previous-input-string 0) #t #t)
                      (let ((pos (point)))
                        (goto-char mb0)
                        (if (not (search-forward old pos #t))
                            (or silent (user-error "Not found"))
                            (begin
                              (replace-match new #t #t)
                              (message "History item: substituted"))))))
                   (else (forward-char 1)))
                  (loop))))))))

    (define (comint-regexp-arg prompt)
      ;; GNU Emacs's `comint-regexp-arg` (`comint.el:1210'): "Return list
      ;; of regexp and prefix arg using PROMPT."
      ;;--------------------------------------------------------------
      (let ((regexp (read-from-minibuffer prompt #f #f
                                          minibuffer-history-search-history)))
        ;; If the user didn't enter anything, nothing is added to the
        ;; search history. Use the previous search regexp, if there is
        ;; one.
        (list (if (string-equal regexp "")
                  (or (let ((entries (history-entries
                                      minibuffer-history-search-history)))
                        (and (pair? entries) (car entries)))
                      regexp)
                  regexp)
              (prefix-numeric-value (current-prefix-arg)))))

    (define-command (comint-magic-space arg)
      "Expand input history references before point and insert ARG spaces.
A useful command to bind to SPC.  See `comint-replace-by-expanded-history'."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      ;; `comint.el:1544'.
      ;;--------------------------------------------------------------
      (comint-replace-by-expanded-history)
      (self-insert-command arg))

    ;;----------------------------------------------------------------
    ;; Quote counting and argument splitting (`comint.el:1761'-`:1897').
    ;;----------------------------------------------------------------

    (define (comint-within-quotes beg end)
      ;; GNU Emacs's `comint-within-quotes` (`comint.el:1761`): "Return t
      ;; if the number of quotes between BEG and END is odd. Quotes are
      ;; single and double."
      ;;--------------------------------------------------------------
      (let ((countsq (comint-how-many-region "\\(^\\|[^\\]\\)'" beg end))
            (countdq (comint-how-many-region "\\(^\\|[^\\]\\)\"" beg end)))
        (or (odd? countsq) (odd? countdq))))

    (define (comint-how-many-region regexp beg end)
      ;; GNU Emacs's `comint-how-many-region` (`comint.el:1768`): "Return
      ;; number of matches for REGEXP from BEG to END."
      ;;--------------------------------------------------------------
      (let ((count 0))
        (save-excursion
          (save-match-data
            (goto-char beg)
            (while (re-search-forward regexp end #t)
              (set! count (+ count 1)))))
        count))

    (define (comint-args string begin end)
      ;; GNU Emacs's `comint-args` (`comint.el:1778`): "From STRING,
      ;; return the args depending on the range specified in the text
      ;; from BEGIN to END. If BEGIN is nil, assume all args. Ignore
      ;; leading `:'. Range can be x-y, x-, -y, where x/y can be [0-9],
      ;; *, ^, $."
      ;;--------------------------------------------------------------
      (save-match-data
        (if (not begin)
            (comint-arguments string 0 #f)
            (let* ((from (if (char=? (char-after begin) #\:) (+ begin 1) begin))
                   (range (buffer-substring from end))
                   (nth (cond ((string-match "^[*^]" range) 1)
                              ((string-match "^-" range) 0)
                              ((string-equal range "$") #f)
                              (else (string-to-number range))))
                   (mth (cond ((string-match "[-*$]$" range) #f)
                              ((string-match "-" range)
                               (string-to-number (substring range (match-end 0))))
                              (else nth))))
              (comint-arguments string nth mth)))))

    (define (comint-delim-arg arg)
      ;; GNU Emacs's `comint-delim-arg` (`comint.el:1797`): "Return a
      ;; list of arguments from ARG. Break it up at the delimiters in
      ;; `comint-delimiter-argument-list'. Returned list is backwards.
      ;; Characters with non-nil values of the text property `literal'
      ;; are assumed to have literal values ... and are not considered to
      ;; be delimiters."
      ;;--------------------------------------------------------------
      (if (not (comint-delimiter-argument-list))
          (list arg)
          (let ((args '())
                (pos 0)
                (len (string-length arg)))
            (while (< pos len)
              (let ((char (string-ref arg pos))
                    (start pos))
                (if (and (memv char (comint-delimiter-argument-list))
                         (not (get-text-property pos 'literal arg)))
                    (while (and (< pos len)
                                (eqv? (string-ref arg pos) char))
                      (set! pos (+ pos 1)))
                    (while (and (< pos len)
                                (not (and (memv (string-ref arg pos)
                                                (comint-delimiter-argument-list))
                                          (not (get-text-property
                                                pos 'literal arg)))))
                      (set! pos (+ pos 1))))
                (set! args (cons (%substring arg start pos) args))))
            args)))

    (define (comint-arguments string nth mth)
      ;; GNU Emacs's `comint-arguments` (`comint.el:1827`): "Return from
      ;; STRING the NTH to MTH arguments. NTH and/or MTH can be nil,
      ;; which means the last argument. ... Returned arguments are
      ;; separated by single spaces."
      ;;
      ;; The `w32-shell-dos-semantics` arm (backslashes are literal on
      ;; MS-DOS) is not carried - there is no w32 here - so
      ;; BACKSLASH-ESCAPE is always true and QUOTE-SUBEXPR is 2.
      ;;--------------------------------------------------------------
      (let* ((first "[^ \n\t\"'`\\\\]\\|\\(\\\\.\\)\\|")
             (argpart (string-append
                       first
                       "\\(\"\\([^\"\\\\]\\|\\\\.\\)*\"\\|"
                       "'[^']*'\\|"
                       "`[^`]*`\\)"))
             (quote-subexpr 2)
             (args '())
             (pos 0)
             (count 0)
             (beg #f)
             (quotes #f)
             (str #f))
        ;; Build a list of all the args until we have as many as we want.
        (let loop ()
          (if (and (or (not mth) (< mth 0) (<= count mth))
                   (string-match argpart string pos))
              (begin
                ;; Apply the `literal' text property to
                ;; backslash-escaped characters, so that
                ;; `comint-delim-arg' won't break them up.
                (when (match-beginning 1)
                  (put-text-property (match-beginning 1) (match-end 1)
                                     'literal #t string))
                (if (and beg (= pos (match-beginning 0)))
                    ;; It's contiguous, part of the same arg.
                    (begin
                      (set! pos (match-end 0))
                      (unless quotes
                        (set! quotes (match-beginning quote-subexpr))))
                    ;; It's a new separate arg.
                    (begin
                      (when beg
                        ;; Put the previous arg, if there was one, onto
                        ;; ARGS.
                        (set! str (%substring string beg pos))
                        (set! args (if quotes
                                       (cons str args)
                                       (nconc (comint-delim-arg str) args))))
                      (set! count (length args))
                      (set! quotes (match-beginning quote-subexpr))
                      (set! beg (match-beginning 0))
                      (set! pos (match-end 0))))
                (loop))
              #f))
        (when beg
          (set! str (%substring string beg pos))
          (set! args (if quotes
                         (cons str args)
                         (nconc (comint-delim-arg str) args))))
        (set! count (length args))
        (let ((n (cond ((not nth) (- count 1))
                       ((>= nth 0) nth)
                       (else (+ count nth))))
              (m (cond ((not mth) 0)
                       ((>= mth 0) (- (- count mth) 1))
                       (else (- (- mth) 1)))))
          (mapconcat (lambda (a) a) (nthcdr n (reverse (nthcdr m args))) " "))))

    (define (comint-add-to-input-history cmd)
      ;; GNU Emacs's `comint-add-to-input-history` (`comint.el:1899`):
      ;; "Add CMD to the input history. Ignore duplicates if
      ;; `comint-input-ignoredups' is non-nil."
      ;;--------------------------------------------------------------
      (when (and ((comint-input-filter) cmd)
                 (or (not (comint-input-ignoredups))
                     (not (ring-p (comint-input-ring)))
                     (ring-empty-p (comint-input-ring))
                     (not (string-equal (ring-ref (comint-input-ring) 0) cmd))))
        (let ((size (ring-size (comint-input-ring))))
          (and (= size (ring-length (comint-input-ring)))
               (< size (comint-input-ring-size))
               (ring-extend (comint-input-ring)
                            (min size (- (comint-input-ring-size) size)))))
        (ring-insert (comint-input-ring) cmd)))

    (define (comint-search-arg arg)
      ;; GNU Emacs's `comint-search-arg` (`comint.el:1224`).
      ;;--------------------------------------------------------------
      (cond ((not (comint-after-pmark-p))
             (user-error "Not at command line"))
            ((or (not (comint-input-ring))
                 (ring-empty-p (comint-input-ring)))
             (user-error "Empty input ring"))
            ((= arg 0)
             (set!comint-input-ring-index #f)
             1)
            (else arg)))

    (define (comint-restore-input)
      ;; `comint.el:1238': "Restore unfinished input."
      ;;--------------------------------------------------------------
      (when (comint-input-ring-index)
        (comint-delete-input)
        (when (> (string-length (comint-stored-incomplete-input)) 0)
          (insert (comint-stored-incomplete-input))
          (message "Input restored"))
        (set!comint-input-ring-index #f)))

    (define (comint-search-start arg)
      ;; `comint.el:1248': "Index to start a directional search,
      ;; starting at `comint-input-ring-index'."
      ;;--------------------------------------------------------------
      (if (comint-input-ring-index)
          (mod (+ (comint-input-ring-index) (if (> arg 0) 1 -1))
               (ring-length (comint-input-ring)))
          (if (>= arg 0)
              0
              (- (ring-length (comint-input-ring)) 1))))

    (define (comint-previous-input-string arg)
      ;; `comint.el:1259'.
      ;;--------------------------------------------------------------
      (ring-ref (comint-input-ring)
                (if (comint-input-ring-index)
                    (mod (+ arg (comint-input-ring-index))
                         (ring-length (comint-input-ring)))
                    arg)))

    (define-command (comint-previous-input arg)
      "Cycle backwards through input history, saving input."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      ;; `comint.el:1267'.
      ;;--------------------------------------------------------------
      (if (and (comint-input-ring-index)
               (or (and (< arg 0) (eqv? (comint-input-ring-index) 0))
                   (and (> arg 0)
                        (eqv? (comint-input-ring-index)
                              (- (ring-length (comint-input-ring)) 1))))
               (not (string-equal (comint-stored-incomplete-input) "")))
          (comint-restore-input)
          (comint-previous-matching-input "." arg)))

    (define-command (comint-next-input arg)
      "Cycle forwards through input history."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (comint-previous-input (- arg)))

    (define (comint-previous-matching-input-string regexp arg)
      ;; `comint.el:1286'.
      ;;--------------------------------------------------------------
      (let ((pos (comint-previous-matching-input-string-position regexp arg)))
        (if pos (ring-ref (comint-input-ring) pos) #f)))

    (define (comint-previous-matching-input-string-position regexp arg . start-arg)
      ;; GNU Emacs's `comint-previous-matching-input-string-position`
      ;; (`comint.el:1292`): "Return the index matching REGEXP ARG places
      ;; along the input ring. Moves relative to START, or
      ;; `comint-input-ring-index'."
      ;;
      ;; The C's two nested `while`s, as named lets: the outer steps once
      ;; per ARG, the inner keeps stepping until a match or until it has
      ;; come all the way round (`tried-each-ring-item`).
      ;;--------------------------------------------------------------
      (let ((start (if (pair? start-arg) (car start-arg) #f)))
        (if (or (not (ring-p (comint-input-ring)))
                (ring-empty-p (comint-input-ring)))
            (user-error "No history")
            (let* ((len (ring-length (comint-input-ring)))
                   (motion (if (> arg 0) 1 -1))
                   (n0 (mod (- (or start (comint-search-start arg)) motion) len)))
              (let loop ((arg arg) (n n0) (prev #f) (tried #f))
                (if (and (/= arg 0) (not tried))
                    (let* ((prev n)
                           (n (mod (+ n motion) len))
                           (res (let inner ((n n) (tried tried))
                                  (if (and (< n len) (not tried)
                                           (not (string-match
                                                 regexp
                                                 (ring-ref (comint-input-ring) n))))
                                      (let ((n2 (mod (+ n motion) len)))
                                        (inner n2 (= n2 prev)))
                                      (cons n tried)))))
                      (loop (if (> arg 0) (- arg 1) (+ arg 1))
                            (car res) prev (cdr res)))
                    (and (string-match regexp (ring-ref (comint-input-ring) n))
                         n)))))))

    (define (comint-delete-input)
      ;; `comint.el:1319': "Delete all input between accumulation or
      ;; process mark and point."
      ;;--------------------------------------------------------------
      (delete-region (or (marker-position (comint-accum-marker))
                         (process-mark (get-buffer-process (current-buffer))))
                     (point-max)))

    (define (comint-previous-matching-input regexp n . restore-arg)
      ;; GNU Emacs's `comint-previous-matching-input` (`comint.el:1327`).
      ;;--------------------------------------------------------------
      (let ((restore (if (pair? restore-arg) (car restore-arg) #f))
            (n (comint-search-arg n)))
        (let ((pos (comint-previous-matching-input-string-position regexp n)))
          (if (not pos)
              (user-error "Not found")
              (if (and (comint-input-ring-index) restore
                       (or (and (< n 0) (< (comint-input-ring-index) pos))
                           (and (> n 0) (> (comint-input-ring-index) pos))))
                  (comint-restore-input)
                  (begin
                    (if (not (comint-input-ring-index))
                        (set!comint-stored-incomplete-input
                         ((comint-get-old-input))))
                    (set!comint-input-ring-index pos)
                    (message "History item: %d" (+ pos 1))
                    (comint-delete-input)
                    (insert (ring-ref (comint-input-ring) pos))))))))

    (define (comint-next-matching-input regexp n)
      ;; `comint.el:1357'.
      ;;--------------------------------------------------------------
      (comint-previous-matching-input regexp (- n)))

    (define (comint-previous-matching-input-from-input n)
      ;; GNU Emacs's `comint-previous-matching-input-from-input`
      ;; (`comint.el:1365`).
      ;;--------------------------------------------------------------
      (let ((opoint (point)))
        (unless (memq (*last-command*)
                      (list comint-previous-matching-input-from-input
                            comint-next-matching-input-from-input))
          (set!comint-matching-input-from-input-string
           (buffer-substring
            (or (marker-position (comint-accum-marker))
                (process-mark (get-buffer-process (current-buffer))))
            (point)))
          (set!comint-input-ring-index #f))
        (comint-previous-matching-input
         (concat "^" (regexp-quote (comint-matching-input-from-input-string)))
         n #t)
        (when (eq? (*comint-move-point-for-matching-input*) 'after-input)
          (goto-char opoint))))

    (define (comint-next-matching-input-from-input n)
      ;; `comint.el:1387'.
      ;;--------------------------------------------------------------
      (comint-previous-matching-input-from-input (- n)))

    ;;----------------------------------------------------------------
    ;; `comint-send-input` (`comint.el:1920'-`:2106') and the fence it
    ;; updates (`:2964').
    ;;----------------------------------------------------------------

    (define (comint-update-fence)
      ;; GNU Emacs's `comint-update-fence` (`comint.el:2964'): "Update
      ;; read-only status of newline before point. The `fence' read-only
      ;; property is used to indicate that a newline is read-only for no
      ;; other reason than to \"fence off\" a following front-sticky
      ;; read-only region."
      ;;--------------------------------------------------------------
      (let* ((pt (point)) (lst (get-text-property pt 'front-sticky)))
        (and (bolp)
             (not (bobp))
             (with-silent-modifications
               (if (and (get-text-property pt 'read-only)
                        (if (list? lst) (memq 'read-only lst) #t))
                   (unless (get-text-property (- pt 1) 'read-only)
                     (put-text-property (- pt 1) pt 'read-only 'fence))
                   (when (eq? (get-text-property (- pt 1) 'read-only) 'fence)
                     (remove-list-of-text-properties (- pt 1) pt
                                                     '(read-only))))))))

    (define-command (comint-send-input . args)
      "Send input to process.
After the process output mark, sends all text from the process mark to
point as input to the process.  Before the process output mark, calls
value of variable `comint-get-old-input' to retrieve old input, copies
it to the process mark, and sends it.

This command also sends and inserts a final newline, unless
NO-NEWLINE is non-nil.

Any history reference may be expanded depending on the value of the
variable `comint-input-autoexpand'.  The list of function names
contained in the value of `comint-input-filter-functions' is called on
the input before sending it.  The input is entered into the input
history ring, if the value of variable `comint-input-filter' returns
non-nil when called on the input."
      (interactive '())
      ;; `comint.el:1920'. The interactive spec is Emacs's `(interactive
      ;; nil comint-mode)' - no arguments; the two optional parameters
      ;; are a rest list.
      ;;
      ;; Emacs first cancels `completion-in-region-mode' if it is on;
      ;; that mode is not ported (the header's completion gap).
      ;;--------------------------------------------------------------
      (let ((no-newline (if (pair? args) (car args) #f))
            (artificial (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        ;; Note that the input string does not include its terminal
        ;; newline.
        (let ((proc (get-buffer-process (current-buffer))))
          (if (not proc)
              (user-error "Current buffer has no process")
              (begin
                (widen)
                (let* ((pmark (process-mark proc))
                       (intxt (if (>= (point) (marker-position pmark))
                                  (begin
                                    (if (comint-eol-on-send)
                                        (if (comint-use-prompt-regexp)
                                            (end-of-line 1)
                                            (goto-char (field-end))))
                                    (buffer-substring pmark (point)))
                                  (let ((copy ((comint-get-old-input))))
                                    (goto-char pmark)
                                    (insert copy)
                                    copy)))
                       (input (if (not (eq? (comint-input-autoexpand) 'input))
                                  intxt
                                  ;; Expand and leave it visible in buffer.
                                  (begin
                                    (comint-replace-by-expanded-history #t pmark)
                                    (buffer-substring pmark (point)))))
                       (history (if (not (eq? (comint-input-autoexpand) 'history))
                                    input
                                    ;; Expand, then insert back.
                                    (begin
                                      (comint-replace-by-expanded-history #t pmark)
                                      (let ((copy (buffer-substring pmark (point)))
                                            (start (point)))
                                        (insert input)
                                        (delete-region pmark start)
                                        copy)))))
                  ;; Delete and reinsert input. This seems like a
                  ;; no-op, except for the resulting entries in the undo
                  ;; list: undoing this insertion will delete the
                  ;; region, moving the process mark back to its
                  ;; original position.
                  (let ((inhibit-read-only #t))
                    (delete-region pmark (point))
                    (insert input))
                  (unless no-newline
                    (insert "\n"))
                  (comint-add-to-input-history history)
                  (run-hook-with-args (comint-input-filter-functions)
                                      (if no-newline input (concat input "\n")))
                  (let ((beg (marker-position pmark))
                        (end (if no-newline (point) (- (point) 1))))
                    (with-silent-modifications
                      (when (> end beg)
                        (when (*comint-highlight-input*)
                          (add-text-properties
                           beg end
                           '(font-lock-face comint-highlight-input
                             comint--fontify-input-inhibit-fontification #t
                             front-sticky #t)))
                        (unless (comint-use-prompt-regexp)
                          ;; Give old user input a field property of
                          ;; `input'; the terminating newline is put
                          ;; into a special `boundary' field so cursor
                          ;; movement between input and output fields is
                          ;; smoother.
                          (add-text-properties
                           beg end
                           '(mouse-face highlight
                             help-echo "mouse-2: insert after prompt as new input"))))
                      (unless (or no-newline (comint-use-prompt-regexp))
                        ;; Cover the terminating newline.
                        (add-text-properties
                         end (+ end 1)
                         (list 'rear-nonsticky *comint--prompt-rear-nonsticky*
                               'field 'boundary
                               'inhibit-line-move-field-capture #t)))))
                  (comint-snapshot-last-prompt)
                  (set!comint-save-input-ring-index (comint-input-ring-index))
                  (set!comint-input-ring-index #f)
                  ;; Update the markers before we send the input in case
                  ;; we get output amidst sending the input.
                  (set-marker (comint-last-input-start) pmark)
                  (set-marker (comint-last-input-end) (point))
                  (set-marker pmark (point))
                  ;; Clear the "accumulation" marker.
                  (set-marker (comint-accum-marker) #f)
                  (parameterize ((*comint-input-sender-no-newline* no-newline))
                    ((comint-input-sender) proc input))
                  ;; Optionally delete echoed input (after checking it).
                  (when (and (comint-process-echoes) (not artificial))
                    (let ((echo-len (- (marker-position (comint-last-input-end))
                                       (marker-position (comint-last-input-start)))))
                      ;; Wait for all input to be echoed.
                      (let echo-loop ()
                        (when (and (> (+ (marker-position (comint-last-input-end))
                                         echo-len)
                                      (point-max))
                                   (accept-process-output proc)
                                   (= 0 (compare-buffer-substrings
                                         #f (comint-last-input-start)
                                         (- (point-max) echo-len)
                                         #f (comint-last-input-end) (point-max))))
                          (echo-loop)))
                      (if (and (<= (+ (marker-position (comint-last-input-end))
                                      echo-len)
                                   (point-max))
                               (= 0 (compare-buffer-substrings
                                     #f (comint-last-input-start)
                                     (comint-last-input-end)
                                     #f (comint-last-input-end)
                                     (+ (marker-position (comint-last-input-end))
                                        echo-len))))
                          ;; Certain parts of the text to be deleted may
                          ;; have been mistaken for prompts; prevent
                          ;; problems when `comint-prompt-read-only' is
                          ;; non-nil.
                          (let ((inhibit-read-only #t)
                                (pos (+ (marker-position (comint-last-input-end))
                                        echo-len)))
                            (delete-region (comint-last-input-end) pos)
                            (when (comint-prompt-read-only)
                              (save-excursion
                                (goto-char (comint-last-input-end))
                                (comint-update-fence)))))))
                  ;; This used to call `comint-output-filter-functions',
                  ;; but that scrolled the buffer in undesirable ways.
                  (set-marker (comint-last-output-start) pmark)
                  (run-hook-with-args (*comint-output-filter-functions*) "")))))))

    (define-command (comint-send-eof)
      "Send an EOF to the current buffer's process."
      (interactive '())
      ;; `comint.el:2807'.
      ;;--------------------------------------------------------------
      (comint-send-input #t #t)
      (process-send-eof))

    (define (comint-skip-input)
      ;; GNU Emacs's `comint-skip-input` (`comint.el:2774`): "Skip all
      ;; pending input, from last stuff output by interpreter to point.
      ;; This means mark it as if it had been sent as input, without
      ;; sending it. The command keys used to trigger the command that
      ;; called this function are inserted into the buffer."
      ;;--------------------------------------------------------------
      (call-with-buffer-local
       'comint-input-sender ignore
       (lambda ()
         (call-with-buffer-local
          'comint-input-filter-functions '()
          (lambda () (comint-send-input #t #t)))))
      (end-of-line 1)
      (let ((pos (point))
            (marker (process-mark (get-buffer-process (current-buffer))))
            (inhibit-read-only #t))
        (insert "  " (key-description (*this-command-keys*)))
        (if (= (marker-position marker) pos)
            (set-marker marker (point)))))

    (define-command (comint-delchar-or-maybe-eof arg)
      "Behave like the global binding or send an EOF to subprocess.
Sends an EOF only if point is at the end of the buffer and there is no
input."
      (interactive (list (current-prefix-arg)))
      ;; `comint.el:2797'.
      ;;--------------------------------------------------------------
      (let ((proc (get-buffer-process (current-buffer))))
        (if (and (eobp) proc
                 (= (point) (marker-position (process-mark proc))))
            (comint-send-eof)
            (let ((cmd (lookup-key *default-keymap* (*this-command-keys*))))
              (call-interactively (or (command-remapping cmd) cmd))))))

    ;;----------------------------------------------------------------
    ;; Prompt helpers, the simple senders (`:2453'-`:2643').
    ;;----------------------------------------------------------------

    (define (comint-get-old-input-default)
      ;; GNU Emacs's `comint-get-old-input-default` (`comint.el:2453`):
      ;; "Default for `comint-get-old-input'. If `comint-use-prompt-regexp'
      ;; is nil, then either return the current input field, if point is
      ;; on an input field, or the current line, if point is on an output
      ;; field. ..."
      ;;--------------------------------------------------------------
      (let ((field-prop #f))
        (if (and (not (comint-use-prompt-regexp))
                 (not (begin
                        (set! field-prop (get-char-property (field-beginning) 'field))
                        field-prop)))
            (field-string-no-properties (field-beginning))
            (begin
              (comint-bol #f)
              (buffer-substring-no-properties
               (point)
               (if (or (comint-use-prompt-regexp) (eq? field-prop 'output))
                   (line-end-position)
                   (field-end)))))))

    (define-command (comint-copy-old-input)
      "Insert after prompt old input at point as new input to be edited.
Calls `comint-get-old-input' to get old input."
      (interactive '())
      ;; `comint.el:2474'.
      ;;--------------------------------------------------------------
      (let ((input ((comint-get-old-input)))
            (process (get-buffer-process (current-buffer))))
        (if (not process)
            (user-error "Current buffer has no process")
            (begin
              (goto-char (process-mark process))
              (insert input)))))

    (define (comint-skip-prompt)
      ;; `comint.el:2485'.
      ;;--------------------------------------------------------------
      (if (and (looking-at (comint-prompt-regexp))
               (<= (match-end 0) (line-end-position)))
          (goto-char (match-end 0))))

    (define (comint-after-pmark-p)
      ;; `comint.el:2492'.
      ;;--------------------------------------------------------------
      (let ((process (get-buffer-process (current-buffer))))
        (when process
          (let ((pmark (process-mark process)))
            (<= (marker-position pmark) (point))))))

    (define (comint-simple-send proc string)
      ;; GNU Emacs's `comint-simple-send` (`comint.el:2499`).
      ;;--------------------------------------------------------------
      (comint-send-string proc
                          (if (*comint-input-sender-no-newline*)
                              string
                              (concat string "\n")))
      (if (and (*comint-input-sender-no-newline*)
               (not (string-equal string "")))
          (process-send-eof)))

    (define (comint-line-beginning-position)
      ;; GNU Emacs's `comint-line-beginning-position` (`comint.el:2514`).
      ;;--------------------------------------------------------------
      (if (comint-use-prompt-regexp)
          (save-excursion
            (beginning-of-line)
            (comint-skip-prompt)
            (point))
          (constrain-to-field (if (eq? (field-at-pos (point)) 'output)
                                  (line-beginning-position)
                                  (field-beginning))
                              (line-end-position))))

    (define-command (comint-bol arg)
      "Go to the beginning of line, then skip past the prompt, if any.
If prefix argument is given, the prompt is not skipped."
      (interactive (list (current-prefix-arg)))
      ;; `comint.el:2537'.
      ;;--------------------------------------------------------------
      (if arg
          (forward-line 0)
          (goto-char (comint-line-beginning-position))))


    ;; For compatibility.
    (define (comint-read-noecho prompt . ignore)
      ;; `comint.el:2550': `(defun comint-read-noecho (prompt
      ;; &optional _ignore) (declare (obsolete read-passwd "28.1"))
      ;; (read-passwd prompt))'. The declaration is the `make-obsolete`
      ;; below the definition, the second argument is ignored, and
      ;; **Emacs's function has no docstring** - the obsoletion
      ;; information is where the warning lives - so neither has this.
      ;;--------------------------------------------------------------
      (read-passwd prompt))

    (make-obsolete 'comint-read-noecho 'read-passwd "28.1")

    ;; These three functions are for entering text you don't want echoed or
    ;; saved -- typically passwords to ftp, telnet, or somesuch.
    ;; Just enter m-x comint-send-invisible and type in your line.

    (define (comint-password-function)
      ;; `(defvar-local comint-password-function nil)'
      ;; (`comint.el:2558'): "Abnormal hook run when prompted for a
      ;; password. This function gets one argument, a string containing
      ;; the prompt. It may return a string containing the password, or
      ;; nil if normal password prompting should occur."
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'comint-password-function #f))
    (define (set!comint-password-function v)
      (set-buffer-local-value! (current-buffer) 'comint-password-function v))

    (define-command (comint-send-invisible . rest)
      "Read a string without echoing.
Then send it to the process running in the current buffer.
The string is sent using `comint-input-sender'.
Security bug: your string can still be temporarily recovered with
\\[view-lossage]; `clear-this-command-keys' can fix that."
      ;; `comint.el:2564'. Emacs's spec is `(interactive "P" comint-mode)';
      ;; the MODES argument only filters M-x completion, as on
      ;; `comint-kill-whole-line`, so it is not carried. The
      ;; interactive PREFIX is the prompt to use, and it is the
      ;; command's one argument.
      ;;--------------------------------------------------------------
      (interactive "P")
      (let ((prompt (and (pair? rest) (car rest))))
        (let ((proc (get-buffer-process (current-buffer)))
              (prefix
               (if (eq? (window-buffer (selected-window)) (current-buffer))
                   ""
                   ;; Emacs's `%s` of a buffer is its name (`princ`).
                   (format "(In buffer %s) " (current-buffer)))))
          (if proc
              (let ((prefix-prompt (concat prefix
                                           (or prompt "Non-echoed text: ")))
                    (str #f))
                (when (comint-password-function)
                  (set! str ((comint-password-function) prefix-prompt)))
                (unless str
                  (set! str (read-passwd prefix-prompt)))
                (if (string? str)
                    (begin
                      (comint-snapshot-last-prompt)
                      ((comint-input-sender) proc str))
                    (message "Warning: text will be echoed")))
              (error "Buffer ~a has no process"
                     (buffer-name (current-buffer)))))))

    (define-obsolete-function-alias send-invisible comint-send-invisible "27.1")
    ;; ^ `(define-obsolete-function-alias 'send-invisible
    ;; #'comint-send-invisible "27.1")' (`comint.el:2592').

    (define *comint--prompt-recursion-depth* (make-parameter 0))
    ;; ^ `(defvar comint--prompt-recursion-depth 0)' (`comint.el:2594').
    ;; A parameter because the timer callback `let`-binds it and the
    ;; binding has to be visible to a timer that callback arms: a Scheme
    ;; `let` would not be.

    (define (comint-watch-for-password-prompt string)
      "Prompt in the minibuffer for password and send without echoing.
Looks for a match to `comint-password-prompt-regexp' in order
to detect the need to (prompt and) send a password.  Ignores any
carriage returns (\\r) in STRING.

This function could be in the list `comint-output-filter-functions'."
      ;; `comint.el:2596', clause for clause.
      ;;--------------------------------------------------------------
      (let* ((string (string-limit
                      (string-replace "\r" "" string)
                      (*comint-password-prompt-max-length*) #t))
             (prompt #f))
        (when (parameterize ((*case-fold-search* #t))
                (string-match (*comint-password-prompt-regexp*) string))
          (set! prompt
                (let ((content (string-trim (match-string 0 string)
                                            "[ \n\r\t\v\f\b\a]+" "\n+"))
                      (suffix " "))
                  (concat content
                          (and (not (string-empty-p content))
                               (not (string-suffix-p suffix content))
                               suffix))))
          ;; Use `run-at-time' in order not to pause execution of the
          ;; process filter with a minibuffer.
          (run-at-time
           0 #f
           (lambda (current-buf)
             (with-current-buffer current-buf
               (parameterize ((*comint--prompt-recursion-depth*
                               (+ 1 (*comint--prompt-recursion-depth*))))
                 (if (> (*comint--prompt-recursion-depth*) 10)
                     (message "Password prompt recursion too deep")
                     (when (get-buffer-process (current-buffer))
                       (comint-send-invisible prompt))))))
           (current-buffer)))))

    (define (comint-send-string process string)
      ;; `comint.el:2633': "Like `process-send-string', but also does
      ;; extra bookkeeping for Comint mode."
      ;;--------------------------------------------------------------
      (if process
          (with-current-buffer (if (processp process)
                                   (process-buffer process)
                                   (get-buffer process))
            (comint-snapshot-last-prompt))
          (comint-snapshot-last-prompt))
      (process-send-string process string))

    (define (comint-send-region process start end)
      ;; `comint.el:2643'.
      ;;--------------------------------------------------------------
      (if process
          (with-current-buffer (if (processp process)
                                   (process-buffer process)
                                   (get-buffer process))
            (comint-snapshot-last-prompt))
          (comint-snapshot-last-prompt))
      (process-send-region process start end))

    ;;----------------------------------------------------------------
    ;; The output filter (`comint.el:2107'-`:2350').
    ;;----------------------------------------------------------------

    (define (comint-snapshot-last-prompt)
      ;; GNU Emacs's `comint-snapshot-last-prompt` (`comint.el:2131`):
      ;; "Snapshot the current `comint-last-prompt'. Freezes the
      ;; `font-lock-face' text property in place."
      ;;--------------------------------------------------------------
      (when (comint-last-prompt)
        (with-silent-modifications
          (font-lock-append-text-property
           (car (comint-last-prompt)) (cdr (comint-last-prompt))
           'font-lock-face 'comint-highlight-prompt))
        (set!comint-last-prompt #f)))

    (define (comint-carriage-motion start end)
      ;; **START and END are coerced from markers first**: Emacs calls
      ;; this with `comint-last-output-start` (a marker) and the numbers
      ;; come out of its arithmetic; Scheme's `>` refuses a marker, so
      ;; the two are turned into positions at entry - the C's
      ;; `CHECK_FIXNUM_COERCE_MARKER`, which every Elisp arithmetic
      ;; operator applies. Measured: without this, the *first* process
      ;; output (whose `comint-last-output-start` is still the marker
      ;; `comint-mode` made) raised "Wrong type argument in position 1".
      ;;
      ;; GNU Emacs's `comint-carriage-motion` (`comint.el:2145`):
      ;; "Interpret carriage control characters in the region from START
      ;; to END. Translate carriage return/linefeed sequences to
      ;; linefeeds. Make single carriage returns delete to the beginning
      ;; of the line. Make backspaces delete the previous character."
      ;;--------------------------------------------------------------
      (let ((start (if (markerp start) (marker-position start) start))
            (end (if (markerp end) (marker-position end) end)))
        (save-excursion
          (goto-char start)
          (let* ((inhibit-field-text-motion #t)
               (inhibit-read-only #t)
               (lbeg (line-beginning-position))
               (delete-end #f))
          (when (and (> start (point-min))
                     (get-text-property (- start 1) 'comint-must-overwrite))
            (set! delete-end (point-marker))
            (remove-text-properties lbeg start '(comint-must-overwrite #f)))
          (narrow-to-region lbeg end)
          (let loop ()
            (when (and (skip-chars-forward "^\b\n\r") (not (eobp)))
              (let ((ch (following-char)))
                (cond ((char=? ch #\backspace)
                       (delete-char 1)
                       (if (> (point) lbeg) (delete-char -1)))
                      ((char=? ch #\newline)
                       (when delete-end
                         (if (< (marker-position delete-end) (point))
                             (delete-region lbeg (marker-position delete-end)))
                         (set-marker delete-end #f)
                         (set! delete-end #f))
                       (forward-char 1)
                       (set! lbeg (point)))
                      (else
                       (delete-char 1)
                       (if delete-end
                           (when (< (marker-position delete-end) (point))
                             (delete-region lbeg (marker-position delete-end))
                             (set-marker delete-end (point)))
                           (set! delete-end (point-marker))))))
              (loop)))
          (when delete-end
            ;; `CHECK_FIXNUM_COERCE_MARKER': Elisp's `<' and `delete-region'
            ;; take a marker, Scheme's do not.
            (if (< (marker-position delete-end) (point))
                (delete-region lbeg (marker-position delete-end))
                (put-text-property lbeg (marker-position delete-end)
                                   'comint-must-overwrite #t))
            (set-marker delete-end #f))
          (widen)))))

    (define (comint--mark-as-output beg end)
      ;; `comint.el:2293'.
      ;;--------------------------------------------------------------
      (with-silent-modifications
        (add-text-properties
         beg end
         (list 'rear-nonsticky *comint--prompt-rear-nonsticky*
               'front-sticky '(field inhibit-line-move-field-capture)
               'field 'output
               'inhibit-line-move-field-capture #t))))

    (define (comint-output-filter process string)
      ;; GNU Emacs's `comint-output-filter` (`comint.el:2205`): "The
      ;; purpose of using this filter for comint processes is to keep
      ;; comint-last-input-end from moving forward when output is
      ;; inserted."
      ;;--------------------------------------------------------------
      (let ((oprocbuf (process-buffer process)))
        (when (and string oprocbuf (buffer-name oprocbuf))
          (with-current-buffer oprocbuf
            ;; Run preoutput filters.
            (let ((functions (comint-preoutput-filter-functions)))
              (while (and (pair? functions) string)
                (if (eq? (car functions) #t)
                    (let ((functions (*comint-preoutput-filter-functions*)))
                      (while (and (pair? functions) string)
                        (set! string ((car functions) string))
                        (set! functions (cdr functions))))
                    (set! string ((car functions) string)))
                (set! functions (cdr functions))))
            (let ((inhibit-read-only #t)
                  (saved-point (copy-marker (point) #t)))
              (save-restriction
                (widen)
                (goto-char (process-mark process))
                ;; `(set-marker comint-last-output-start (point))' in
                ;; Emacs - moving the marker. Replacing the slot with a
                ;; number broke the very next `set-marker` on it (and
                ;; left `comint-carriage-motion` a marker to do
                ;; arithmetic on, which Elisp allows and Scheme does
                ;; not).
                (set-marker (comint-last-output-start) (point))
                (put-text-property 0 (string-length string) 'field 'output string)
                (insert string)
                (set-marker (process-mark process) (point))
                (unless (*comint-inhibit-carriage-motion*)
                  (comint-carriage-motion (comint-last-output-start) (point)))
                (goto-char saved-point)
                (run-hook-with-args (*comint-output-filter-functions*) string)
                (set-marker saved-point (point))
                (goto-char (process-mark process))
                (unless (comint-use-prompt-regexp)
                  (comint--mark-as-output (comint-last-output-start) (point)))
                ;; Highlight the prompt: the most recent output that does
                ;; not end with a newline.
                (let ((prompt-start (save-excursion (forward-line 0) (point)))
                      (inhibit-read-only #t))
                  (when (comint-prompt-read-only)
                    (with-silent-modifications
                      (or (= (point-min) prompt-start)
                          (get-text-property (- prompt-start 1) 'read-only)
                          (put-text-property (- prompt-start 1) prompt-start
                                             'read-only 'fence))
                      (add-text-properties
                       prompt-start (point)
                       '(read-only #t front-sticky (read-only)))))
                  (when (comint-last-prompt)
                    (font-lock--remove-face-from-text-property
                     (car (comint-last-prompt)) (cdr (comint-last-prompt))
                     'font-lock-face 'comint-highlight-prompt))
                  (set!comint-last-prompt
                   (cons (copy-marker prompt-start) (point-marker)))
                  (font-lock-append-text-property prompt-start (point)
                                                  'font-lock-face
                                                  'comint-highlight-prompt)
                  (add-text-properties
                   prompt-start (point)
                   (list 'rear-nonsticky *comint--prompt-rear-nonsticky*)))
                (goto-char saved-point)))))))

    ;;----------------------------------------------------------------
    ;; Scrolling on output (`comint.el:2330'-`:2445').
    ;;----------------------------------------------------------------

    (define (comint-preinput-scroll-to-bottom)
      ;; The pre-command hook `comint-mode` installs. Emacs adds it to
      ;; the buffer's local `pre-command-hook`; this tree's `add-hook`
      ;; is global, so the function checks the mode.
      ;;--------------------------------------------------------------
      (when (derived-mode-p 'comint-mode)
        (let ((process (get-buffer-process (current-buffer))))
          (when process
            (for-each
             (lambda (w)
               (comint-adjust-window-point w process)
               (when (eq? (window-point w) (point-max))
                 (with-selected-window w
                   (recenter (- -1 (*scroll-margin*))))))
             (get-buffer-window-list (current-buffer) #f #t))))))

    (define (comint-adjust-window-point window process)
      ;; GNU Emacs's `comint-adjust-window-point` (`comint.el:2384`):
      ;; "Move point in WINDOW based on Comint settings. For point
      ;; adjustment use the process-mark of PROCESS."
      ;;--------------------------------------------------------------
      (and (< (window-point window) (marker-position (process-mark process)))
           (or (memq (*comint-move-point-for-output*) '(#t all))
               (eq? (*comint-move-point-for-output*)
                    (if (eq? (selected-window) window) 'this 'others))
               (and (marker-position (or (comint-last-output-start)
                                         (make-marker)))
                    (>= (window-point window)
                        (marker-position (comint-last-output-start)))))
           (set-window-point window (marker-position (process-mark process)))))

    (define (comint-postoutput-scroll-to-bottom string)
      ;; GNU Emacs's `comint-postoutput-scroll-to-bottom`
      ;; (`comint.el:2354`). The `follow-mode` arm is not carried
      ;; (follow.el is not ported).
      ;;--------------------------------------------------------------
      (let* ((current (current-buffer))
             (process (get-buffer-process current)))
        (when process
          (for-each
           (lambda (w)
             (comint-adjust-window-point w process)
             (and (*comint-scroll-show-maximum-output*)
                  (eq? (window-point w) (point-max))
                  (with-selected-window w
                    (recenter (- -1 (*scroll-margin*))))))
           (get-buffer-window-list current #f #t)))))

    (define (comint-truncate-buffer . _string)
      ;; GNU Emacs's `comint-truncate-buffer` (`comint.el:2413`):
      ;; "Truncate the buffer to `comint-buffer-maximum-size'."
      ;;--------------------------------------------------------------
      (save-excursion
        (goto-char (process-mark (get-buffer-process (current-buffer))))
        (forward-line (- (*comint-buffer-maximum-size*)))
        (beginning-of-line)
        (let ((inhibit-read-only #t))
          (delete-region (point-min) (point)))))

    (define (comint-strip-ctrl-m . args)
      ;; GNU Emacs's `comint-strip-ctrl-m` (`comint.el:2424`): "Strip
      ;; trailing `^M' characters from the current output group."
      ;;--------------------------------------------------------------
      (let ((interactive (if (and (pair? args) (pair? (cdr args)))
                             (cadr args) #f))
            (process (get-buffer-process (current-buffer))))
        (if (not process)
            (when interactive
              (error "No process in the current buffer"))
            (let ((pmark (process-mark process)))
              (save-excursion
                (guard (e (#t #f))
                  (goto-char (if interactive
                                 (comint-last-input-end)
                                 (comint-last-output-start))))
                (while (re-search-forward "\r+$" pmark #t)
                  (replace-match "" #t #t)))))))

    (define-command (comint-show-maximum-output)
      "Put the end of the buffer at the bottom of the window."
      (interactive '())
      (goto-char (point-max))
      (recenter (- -1 (*scroll-margin*))))

    ;;----------------------------------------------------------------
    ;; Output and signal commands (`comint.el:2656'-`:2812').
    ;;----------------------------------------------------------------

    (define (comint-delete-output . kill-arg)
      ;; GNU Emacs's `comint-delete-output` (`comint.el:2656`): "Delete
      ;; all output from interpreter since last input. If KILL
      ;; (interactively, the prefix), save the killed text in the kill
      ;; ring. This command does not delete the prompt."
      ;;--------------------------------------------------------------
      (let ((kill (if (pair? kill-arg) (car kill-arg) #f))
            (proc (get-buffer-process (current-buffer)))
            (inhibit-read-only #t))
        (let ((replacement
               (save-excursion
                 (let ((pmark (begin (goto-char (process-mark proc))
                                     (forward-line 0)
                                     (point-marker))))
                   (when kill
                     (copy-region-as-kill (comint-last-input-end) pmark))
                   (delete-region (comint-last-input-end) pmark)
                   (goto-char (process-mark proc))
                   (let ((r (concat "*** output flushed ***\n"
                                    (buffer-substring pmark (point)))))
                     (delete-region pmark (point))
                     r)))))
          (comint-output-filter proc replacement))))

    (define-command (comint-show-output)
      "Display start of this batch of interpreter output at top of window.
Sets mark to the value of point when this command is run."
      (interactive '())
      (push-mark)
      (let ((pos (or (and (comint-last-input-end)
                          (marker-position (comint-last-input-end)))
                     (point-max))))
        (cond ((comint-use-prompt-regexp)
               (goto-char pos)
               (beginning-of-line 0)
               (set-window-start (selected-window) (point))
               (comint-skip-prompt))
              (else
               (goto-char (field-beginning pos))
               (set-window-start (selected-window) (point))))))

    (define-command (comint-clear-buffer)
      "Clear the comint buffer."
      (interactive '())
      (parameterize ((*comint-buffer-maximum-size* 0))
        (comint-truncate-buffer)))

    (define-command (comint-interrupt-subjob)
      "Interrupt the current subjob."
      (interactive '())
      (interrupt-process #f (comint-ptyp)))

    (define-command (comint-kill-subjob)
      "Send kill signal to the current subjob."
      (interactive '())
      (kill-process #f (comint-ptyp)))

    (define-command (comint-quit-subjob)
      "Send quit signal to the current subjob."
      (interactive '())
      (quit-process #f (comint-ptyp)))

    (define-command (comint-stop-subjob)
      "Stop the current subjob."
      (interactive '())
      (stop-process #f (comint-ptyp)))

    (define-command (comint-continue-subjob)
      "Send CONT signal to process buffer's process group."
      (interactive '())
      (continue-process #f (comint-ptyp)))

    (define-command (comint-kill-input)
      "Kill all text from last stuff output by interpreter to point."
      (interactive '())
      (let ((pmark (process-mark (get-buffer-process (current-buffer)))))
        (if (> (point) (marker-position pmark))
            (kill-region pmark (point)))))

    ;;----------------------------------------------------------------
    ;; Prompt and matching motions (`comint.el:2814'-`:2902').
    ;;----------------------------------------------------------------

    (define-command (comint-backward-matching-input regexp n)
      "Search backward through buffer for input fields that match REGEXP.
If `comint-use-prompt-regexp' is non-nil, then input fields are identified
by lines that match `comint-prompt-regexp'.

With prefix argument N, search for Nth previous match.
If N is negative, find the next or Nth next match."
      (interactive (comint-regexp-arg "Backward input matching (regexp): "))
      ;; `comint.el:2814'.
      ;;--------------------------------------------------------------
      (if (comint-use-prompt-regexp)
          ;; Use comint-prompt-regexp.
          (let* ((re (concat (comint-prompt-regexp) ".*" regexp))
                 (pos (save-excursion
                        (end-of-line (if (> n 0) 0 1))
                        (if (re-search-backward re #f #t n)
                            (point)))))
            (if (not pos)
                (begin (message "Not found") (ding))
                (begin (goto-char pos) (comint-bol #f))))
          ;; Use input fields.
          (let* ((dir (if (< n 0) -1 1))
                 (pos (save-excursion
                        (let loop ((n n))
                          (unless (= n 0)
                            (unless (re-search-backward regexp #f #t dir)
                              (user-error "Not found"))
                            (unless (get-char-property (point) 'field)
                              (set! n (- n dir)))
                            (loop n)))
                        (field-beginning))))
            (goto-char pos))))

    (define-command (comint-forward-matching-input regexp n)
      "Search forward through buffer for input fields that match REGEXP.
If `comint-use-prompt-regexp' is non-nil, then input fields are identified
by lines that match `comint-prompt-regexp'.

With prefix argument N, search for Nth following match.
If N is negative, find the previous or Nth previous match."
      (interactive (comint-regexp-arg "Forward input matching (regexp): "))
      ;; `comint.el:2846'.
      ;;--------------------------------------------------------------
      (comint-backward-matching-input regexp (- n)))

    (define-command (comint-next-prompt n)
      "Move to end of Nth next prompt in the buffer.
If `comint-use-prompt-regexp' is nil, then this means the beginning of
the Nth next `input' field, otherwise, it means the Nth occurrence of
text matching `comint-prompt-regexp'."
      (interactive "^p")
      ;; `comint.el:2857'.
      ;;--------------------------------------------------------------
      (if (comint-use-prompt-regexp)
          ;; Use comint-prompt-regexp. `paragraph-start` is a
          ;; buffer-local here, so Emacs's `let` is
          ;; `call-with-buffer-local`.
          (call-with-buffer-local
           'paragraph-start (comint-prompt-regexp)
           (lambda ()
             (end-of-line (if (> n 0) 1 0))
             (forward-paragraph n)
             (comint-skip-prompt)))
          ;; Use input fields.
          (let ((pos (point))
                (input-pos #f))
            (let loop ((n n) (pos pos) (input-pos input-pos))
              (if (= n 0)
                  (when input-pos (goto-char input-pos))
                  (let* ((prev-pos pos)
                         (pos (if (> n 0)
                                  (next-single-char-property-change pos 'field)
                                  (previous-single-char-property-change
                                   pos 'field))))
                    (cond
                     ((= pos prev-pos)
                      ;; Ran off the end of the buffer. There's always
                      ;; an input field at the end of the buffer, but
                      ;; it has a `field' property of nil.
                      (loop 0 pos (if (> n 0) (point-max) input-pos)))
                     ((not (get-char-property pos 'field))
                      (loop (if (< n 0) (+ n 1) (- n 1)) pos pos))
                     (else (loop n pos input-pos)))))))))

    (define-command (comint-previous-prompt n)
      "Move to end of Nth previous prompt in the buffer.
If `comint-use-prompt-regexp' is nil, then this means the beginning of
the Nth previous `input' field, otherwise, it means the Nth occurrence of
text matching `comint-prompt-regexp'."
      (interactive "^p")
      ;; `comint.el:2894'.
      ;;--------------------------------------------------------------
      (comint-next-prompt (- n)))

    (define-command (comint-insert-input event)
      "In a Comint buffer, set the current input to the previous input at point.
If there is no previous input at point, run the command specified
by the global keymap (usually `mouse-yank-at-click')."
      (interactive "e")
      ;; `comint.el:977'.
      ;;--------------------------------------------------------------
      (let ((pos (posn-point (event-end event)))
            (field #f)
            (input #f))
        (with-selected-window (posn-window (event-end event))
          ;; If pos is at the very end of a field, the mouse-click was
          ;; probably outside (to the right) of the field.
          (and (< pos (field-end pos))
               (< (field-end pos) (point-max))
               (begin
                 (set! field (field-at-pos pos))
                 (set! input (field-string-no-properties pos)))))
        (if (or (not input) (not (comint-accum-marker)) field)
            ;; Fall back to the global definition if (i) the selected
            ;; buffer is not a comint buffer, or (ii) there is no input
            ;; at POS.
            (let* ((keys (*this-command-keys*))
                   (last-key (and (vector? keys)
                                  (vector-ref keys (- (vector-length keys) 1))))
                   (fun (and last-key
                             (lookup-key *default-keymap* (vector last-key)))))
              (and fun (not (eq? fun comint-insert-input))
                   (call-interactively fun)))
            ;; Otherwise, insert the previous input.
            (with-selected-window (posn-window (event-end event))
              (goto-char (point-max))
              ;; First delete any old unsent input at the end.
              (when (comint-delete-old-input)
                (delete-region
                 (or (marker-position (comint-accum-marker))
                     (process-mark (get-buffer-process (current-buffer))))
                 (point)))
              ;; Insert the input at point.
              (insert input)))))

    ;;----------------------------------------------------------------
    ;; `comint-insert-previous-argument` (`comint.el:2902'-`:2963').
    ;;----------------------------------------------------------------

    (define-command (comint-insert-previous-argument index)
      "Insert the INDEXth argument from the previous Comint command-line at point.
Spaces are added at beginning and/or end of the inserted string if
necessary to ensure that it's separated from adjacent arguments.
Interactively, if no prefix argument is given, the last argument is inserted.
Repeated interactive invocations will cycle through the same argument
from progressively earlier commands (using the value of INDEX specified
with the first command).  Values of INDEX < 0 count from the end, so
INDEX = -1 is the last argument.  This command is like \"M-.\" in
Bash and zsh."
      (interactive (list (current-prefix-arg)))
      ;; `comint.el:2917'.
      ;;--------------------------------------------------------------
      (unless (or (not index) (null? index))
        (set! index (prefix-numeric-value index)))
      (if (eq? (*last-command*) (*this-command*))
          ;; Delete last input inserted by this command.
          (begin
            (delete-region (comint-insert-previous-argument-last-start-pos)
                           (point))
            (set! index (comint-insert-previous-argument-last-index)))
          ;; This is a non-repeat invocation, so initialize state.
          (begin
            (when (and index (*comint-insert-previous-argument-from-end*))
              (set! index (- index)))
            (set!comint-input-ring-index #f)
            (set!comint-insert-previous-argument-last-index index)
            (when (not (comint-insert-previous-argument-last-start-pos))
              ;; First usage; initialize to a marker.
              (set!comint-insert-previous-argument-last-start-pos
               (make-marker)))))
      ;; Make sure we're not in the prompt, and add a beginning space if
      ;; necessary.
      (if (<= (point) (comint-line-beginning-position))
          (comint-bol #f)
          (just-one-space 1))
      ;; Remember the beginning of what we insert, so we can delete it if
      ;; the command is repeated.
      (set-marker (comint-insert-previous-argument-last-start-pos) (point))
      ;; Insert the argument.
      (let ((input-string (comint-previous-input-string 0)))
        (insert (comint-arguments input-string index index)))
      ;; Make next invocation return arg from previous input.
      (set!comint-input-ring-index (+ 1 (or (comint-input-ring-index) 0)))
      ;; Add a terminating space if necessary.
      (unless (eolp)
        (just-one-space 1)))


    ;;----------------------------------------------------------------
    ;; The read-only prompt's kill commands (`comint.el:2992'-`:3037').
    ;;----------------------------------------------------------------

    (define-command (comint-kill-whole-line . rest)
      "Kill current line, ignoring read-only and field properties.
With prefix arg COUNT, kill that many lines starting from the current line.
If COUNT is negative, kill backward.  Also kill the preceding newline,
instead of the trailing one.  \\(This is meant to make \\[repeat] work well
with negative arguments.)
If COUNT is zero, kill current line but exclude the trailing newline.
The read-only status of newlines is updated with `comint-update-fence',
if necessary."
      ;; `comint.el:2992'.  Emacs's spec is `(interactive "p" comint-mode)';
      ;; the MODES argument only filters M-x completion
      ;; (`read-extended-command-predicate`) and does not affect the
      ;; command, so it is not carried - a named departure.
      ;;--------------------------------------------------------------
      (interactive "p")
      (let ((count (if (pair? rest) (car rest) #f)))
        (parameterize ((*inhibit-read-only* #t)
                       (*inhibit-field-text-motion* #t))
          (kill-whole-line count))
        (when (>= count 0) (comint-update-fence))))

    (define-command (comint-kill-region beg end)
      "Like `kill-region', but ignore read-only properties, if safe.
This command assumes that the buffer contains read-only
\"prompts\" which are regions with front-sticky read-only
properties at the beginning of a line, with the preceding newline
being read-only to protect the prompt.  This is true of the
comint prompts if `comint-prompt-read-only' is non-nil.  This
command will not delete the region if this would create mutilated
or out of place prompts.  That is, if any part of a prompt is
deleted, the entire prompt must be deleted and all remaining
prompts should stay at the beginning of a line.  If this is not
the case, this command just calls `kill-region' with all
read-only properties intact.  The read-only status of newlines is
updated using `comint-update-fence', if necessary."
      ;; `comint.el:3006'.  The MODES argument is the departure noted on
      ;; `comint-kill-whole-line` above.  `(listp X)` is `(or (not X)
      ;; (list? X))` here, and a nil property is the empty memq list.
      ;;--------------------------------------------------------------
      (interactive "r")
      (save-excursion
        (let* ((true-beg (min beg end))
               (true-end (max beg end))
               (beg-bolp (begin (goto-char true-beg) (bolp)))
               (beg-lst (get-text-property true-beg 'front-sticky))
               (beg-bad (and (get-text-property true-beg 'read-only)
                             (if (and beg-lst (not (list? beg-lst)))
                                 #t
                                 (if (memq 'read-only
                                           (if (pair? beg-lst) beg-lst '()))
                                     #t #f))))
               (end-bolp (begin (goto-char true-end) (bolp)))
               (end-lst (get-text-property true-end 'front-sticky))
               (end-bad (and (get-text-property true-end 'read-only)
                             (if (and end-lst (not (list? end-lst)))
                                 #t
                                 (if (memq 'read-only
                                           (if (pair? end-lst) end-lst '()))
                                     #t #f)))))
          (if (or (and (not beg-bolp) (or beg-bad end-bad))
                  (and (not end-bolp) end-bad))
              (kill-region beg end)
              (parameterize ((*inhibit-read-only* #t))
                (kill-region beg end)
                (comint-update-fence))))))


    ;;----------------------------------------------------------------
    ;; Source-file defaults and prompts (`comint.el:3068'-`:3160').
    ;;----------------------------------------------------------------

    (define (comint-source-default previous-dir/file source-modes)
      "Compute the defaults for `load-file' and `compile-file' commands.

PREVIOUS-DIR/FILE is a pair (DIRECTORY . FILENAME) from the last
source-file processing command, or nil if there hasn't been one yet.
SOURCE-MODES is a list used to determine what buffers contain source
files: if the major mode of the buffer is in SOURCE-MODES, it's source.

The function returns a pair: (default-directory . default-file)."
      ;; `comint.el:3068'.
      ;;--------------------------------------------------------------
      (cond ((and (buffer-file-name) (memq (major-mode) source-modes))
             (cons (file-name-directory-part (buffer-file-name))
                   (file-name-nondirectory-part (buffer-file-name))))
            (previous-dir/file)
            (else
             (cons (default-directory) #f))))

    (define (comint-check-source fname)
      "Check whether to save buffers visiting file FNAME.
Prior to loading or compiling (or otherwise processing) a file (in the CMU
process-in-a-buffer modes), this function can be called on the filename.
If the file is loaded into a buffer, and the buffer is modified, the user
is queried to see if he wants to save the buffer before proceeding with
the load or compile."
      ;; `comint.el:3106'.
      ;;--------------------------------------------------------------
      (let ((buff (get-file-buffer fname)))
        (if (and buff
                 (buffer-modified-p buff)
                 (y-or-n-p (format "Save buffer %s first? "
                                   (buffer-name buff))))
            (with-current-buffer buff
              (save-buffer)))))

    (define (comint-extract-string)
      "Return string around point, or nil."
      ;; `comint.el:3118'.
      ;;--------------------------------------------------------------
      (let ((syntax (syntax-ppss)))
        (if (not (nth 3 syntax))
            #f
            ;; Emacs's `condition-case () ... (error nil)'.
            (guard (e (else #f))
              (buffer-substring-no-properties
               (+ 1 (nth 8 syntax))
               (begin
                 (goto-char (nth 8 syntax))
                 (forward-sexp)
                 (- (point) 1)))))))

    (define (comint-get-source prompt prev-dir/file source-modes mustmatch-p)
      "Prompt for filenames in commands that process source files,
e.g. loading or compiling a file.
Provides a default, if there is one, and returns the result filename.

See `comint-source-default' for more on determining defaults.

PROMPT is the prompt string.  PREV-DIR/FILE is the (DIRECTORY . FILE) pair
from the last source processing command.  SOURCE-MODES is a list of major
modes used to determine what file buffers contain source files.  If
MUSTMATCH-P is true, then the filename reader will only accept a file that
exists."
      ;; `comint.el:3131'.
      ;;--------------------------------------------------------------
      (let* ((def (comint-source-default prev-dir/file source-modes))
             (stringfile (comint-extract-string))
             (sfile-p (and stringfile
                           (guard (e (else #f))
                             (file-exists-p stringfile))
                           (not (file-directory-p stringfile))))
             (defdir (if sfile-p
                         (file-name-directory-part stringfile)
                         (car def)))
             (deffile (if sfile-p
                          (file-name-nondirectory-part stringfile)
                          (cdr def)))
             (ans (read-file-name (format-prompt prompt deffile)
                                  defdir
                                  (concat defdir deffile)
                                  mustmatch-p)))
        (list (expand-file-name (substitute-in-file-name ans)))))

    (define (comint-proc-query proc str)
      "Send to the inferior process PROC the string STR.
Pop-up but do not select a window for the inferior process so that
its response can be seen."
      ;; `comint.el:3186', line for line.
      ;;--------------------------------------------------------------
      (let* ((proc-buf (process-buffer proc))
             (proc-mark (process-mark proc)))
        (display-buffer proc-buf)
        (set-buffer proc-buf) ; but it's not the selected *window*
        (let ((proc-win (get-buffer-window proc-buf 0))
              (proc-pt (marker-position proc-mark)))
          (comint-send-string proc str) ; send the query
          (accept-process-output proc)  ; wait for some output
          ;; Try to position the proc window so you can see the answer.
          ;; This is bogus code.  If you delete the (sit-for 0), it breaks.
          ;; I don't know why.  Wizards invited to improve it.
          (unless (pos-visible-in-window-p proc-pt proc-win)
            (let ((opoint (window-point proc-win)))
              (set-window-point proc-win proc-mark)
              (sit-for 0)
              (if (not (pos-visible-in-window-p opoint proc-win))
                  (push-mark opoint)
                  (set-window-point proc-win opoint)))))))

    ;;----------------------------------------------------------------
    ;; The remaining process and history commands
    ;; (`comint.el:3597'-`:3670').
    ;;----------------------------------------------------------------

    (define-command (comint-get-next-from-history)
      "After fetching a line from input history, this fetches the following line.
In other words, this recalls the input line after the line you recalled last.
You can use this to repeat a sequence of input lines."
      (interactive '())
      ;; `comint.el:3597'.
      ;;--------------------------------------------------------------
      (if (comint-save-input-ring-index)
          (begin
            (set!comint-input-ring-index
             (+ 1 (comint-save-input-ring-index)))
            (comint-next-input 1))
          (message "No previous history command")))

    (define-command (comint-accumulate)
      "Accumulate a line to send as input along with more lines.
This inserts a newline so that you can enter more text
to be sent along with this line.  Use \\[comint-send-input]
to send all the accumulated input, at once.
The entire accumulated text becomes one item in the input history
when you send it."
      (interactive '())
      ;; `comint.el:3608'.
      ;;
      ;; Emacs's `(>= (point) comint-accum-marker pmark)' compares three
      ;; values, two of them markers; Elisp arithmetic coerces them and
      ;; Scheme's `>=' does not, so the positions are read out first.
      ;;--------------------------------------------------------------
      (let ((proc (get-buffer-process (current-buffer))))
        (when proc
          (let ((pmark (process-mark proc)))
            (when (or (marker-position (comint-accum-marker))
                      (begin
                        (set-marker (comint-accum-marker) pmark)
                        #t))
              (when (and (>= (point) (marker-position (comint-accum-marker)))
                         (>= (marker-position (comint-accum-marker))
                             (marker-position pmark)))
                ;; Delete and reinsert input.  This seems like a no-op,
                ;; except for the resulting entries in the undo list:
                ;; undoing this insertion will delete the region, moving
                ;; the accumulation marker back to its original
                ;; position.
                (let ((text (buffer-substring (comint-accum-marker) (point))))
                  (parameterize ((*inhibit-read-only* #t))
                    (delete-region (comint-accum-marker) (point))
                    (insert text)))))))
        (insert "\n")
        ;; `comint.el:3629': the accumulation marker follows the new
        ;; line, and a running history search is rewound with it.
        (set-marker (comint-accum-marker) (point))
        (if (comint-input-ring-index)
            (set!comint-save-input-ring-index
             (- (comint-input-ring-index) 1)))))

    (define-command (comint-goto-process-mark)
      "Move point to the process mark.
The process mark separates output, and input already sent,
from input that has not yet been sent."
      (interactive '())
      ;; `comint.el:3636'.
      ;;--------------------------------------------------------------
      (let ((proc (or (get-buffer-process (current-buffer))
                      (user-error "Current buffer has no process"))))
        (goto-char (process-mark proc))
        (when (called-interactively? comint-goto-process-mark)
          (message "Point is now at the process mark"))))

    (define-command (comint-bol-or-process-mark)
      "Move point to beginning of line (after prompt) or to the process mark.
The first time you use this command, it moves to the beginning of the line
\(but after the prompt, if any).  If you repeat it again immediately,
it moves point to the process mark.

The process mark separates the process output, along with input already sent,
from input that has not yet been sent.  Ordinarily, the process mark
is at the beginning of the current input line; but if you have
used \\[comint-accumulate] to send multiple lines at once,
the process mark is at the beginning of the accumulated input."
      (interactive '())
      ;; `comint.el:3647'.
      ;;--------------------------------------------------------------
      (if (not (eq? (*last-command*) comint-bol-or-process-mark))
          (comint-bol #f)
          (comint-goto-process-mark)))

    (define-command (comint-set-process-mark)
      "Set the process mark at point."
      (interactive '())
      ;; `comint.el:3663'.
      ;;--------------------------------------------------------------
      (let ((proc (or (get-buffer-process (current-buffer))
                      (user-error "Current buffer has no process"))))
        (set-marker (process-mark proc) (point))
        (message "Process mark set")))

    ;;----------------------------------------------------------------
    ;; The keymap bindings (`comint.el:548'-`:650'), after the commands:
    ;; a Scheme keymap holds procedures.
    ;;----------------------------------------------------------------

    (define-key comint-mode-map (kbd "M-p") comint-previous-input)
    (define-key comint-mode-map (kbd "M-n") comint-next-input)
    (define-key comint-mode-map (kbd "C-c C-c") comint-interrupt-subjob)
    (define-key comint-mode-map (kbd "C-c C-z") comint-stop-subjob)
    (define-key comint-mode-map (kbd "C-c C-\\") comint-quit-subjob)
    (define-key comint-mode-map (kbd "C-c C-o") comint-delete-output)
    (define-key comint-mode-map (kbd "C-c M-o") comint-clear-buffer)
    (define-key comint-mode-map (kbd "C-c C-r") comint-show-output)
    (define-key comint-mode-map (kbd "C-c C-e") comint-show-maximum-output)
    (define-key comint-mode-map (kbd "C-c C-u") comint-kill-input)
    (define-key comint-mode-map (kbd "C-c C-m") comint-copy-old-input)
    (define-key comint-mode-map (kbd "RET") comint-send-input)
    (define-key comint-mode-map (kbd "C-d") comint-delchar-or-maybe-eof)
    (define-key comint-mode-map (kbd "C-c C-d") comint-send-eof)
    (define-key comint-mode-map (kbd "C-c SPC") comint-accumulate)
    (define-key comint-mode-map (kbd "C-c C-x") comint-get-next-from-history)
    (define-key comint-mode-map (kbd "C-c C-a") comint-bol-or-process-mark)
    (define-key comint-mode-map (kbd "C-c .") comint-insert-previous-argument)
    (define-key comint-mode-map (kbd "C-c C-n") comint-next-prompt)
    (define-key comint-mode-map (kbd "C-c C-p") comint-previous-prompt)
    (define-key comint-mode-map (vector 'mouse-2) comint-insert-input)

    (*comint-output-filter-functions*
     (list comint-postoutput-scroll-to-bottom
           comint-watch-for-password-prompt))
    (*comint-get-old-input* comint-get-old-input-default)
    (*comint-input-filter* comint-nonblank-p)
    (*comint-input-sender* comint-simple-send)))

