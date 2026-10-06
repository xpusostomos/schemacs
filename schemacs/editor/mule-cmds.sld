(define-library (schemacs editor mule-cmds)
  ;; This library mirrors GNU Emacs's `lisp/international/mule-cmds.el',
  ;; which is where the multilingual *commands* live: the `C-x RET' keymap
  ;; and the four commands on it that this tree can honour.
  ;;
  ;; **Why it is a library of its own rather than part of `mule.sld'.**
  ;; `mule.sld' is below the minibuffer, and every command here prompts -
  ;; `read-coding-system' is a `completing-read'. That is the same wall
  ;; `goto-line', `zap-to-char' and `set-fill-column' hit, and the same
  ;; answer: the prompting command sits above the minibuffer and says so.
  ;; `read-coding-system' is `coding.c''s function and is here for that
  ;; reason alone.
  ;;
  ;; Not carried from `mule-keymap', each with what it would need: `F'
  ;; (`set-file-name-coding-system'), `t' and `k' (the terminal's and the
  ;; keyboard's coding systems - there is one terminal here and its
  ;; encoding is the process's), `p' (a subprocess's - there are no
  ;; subprocesses), `x' and `X' (the selection's), `C-\' (an input method,
  ;; which is `quail' and is a project of its own) and `l' (the language
  ;; environment, which is a table of defaults for all of the above).
  ;;
  ;; Also not carried: `select-safe-coding-system', which
  ;; `set-buffer-file-coding-system' calls to warn when the chosen coding
  ;; system cannot encode something in the buffer. It needs
  ;; `find-coding-systems-region', which needs charsets - see
  ;; `detect-coding-charset' in `coding.sld'. Without it the command does
  ;; what it is told, which is what FORCE says to do.

  (import
    (scheme base)
    ;; The coding systems, and the two variables that let one command's
    ;; I/O use a coding system the buffer's own does not name.
    (only (schemacs editor coding)
          coding-system-p coding-system-name
          *coding-system-table*
          *coding-system-for-read* *coding-system-for-write*)
    ;; `merge-coding-systems' is `mule.el''s, which is `mule.sld'.
    (only (schemacs editor mule) merge-coding-systems)
    ;; `buffer-file-coding-system' and what a revert re-reads with.
    (only (schemacs editor files)
          buffer-file-coding-system set!buffer-file-coding-system
          revert-buffer)
    (only (schemacs editor buffer)
          current-buffer set-buffer-modified-p)
    (only (schemacs editor editfns) message)
    ;; The prompt. `completing-read' is `minibuf.c''s and `make<history>'
    ;; is the history a coding-system prompt keeps.
    (only (schemacs editor minibuffer)
          completing-read make<history> history-entries set!history-entries)
    (only (schemacs editor command) define-command current-prefix-arg
          *pending-coding-system*)
    ;; `delq' is Guile's list `delete' - R7RS has no destructive one -
    ;; and `hash-map->list' is how the registry is walked now that it is a
    ;; hash table rather than a list.
    (only (guile) delq hash-map->list)
    (only (schemacs editor keymap) define-key *default-keymap*)
    ;; The keymap constructor is `keymap` in `(schemacs keymap)`.
    (only (schemacs keymap) keymap)
    ;; `kbd' is `subr.el''s: a key description to the vector of events
    ;; a `define-key' takes.
    (only (schemacs editor subr) kbd)
    )

  (export
   mule-keymap
   *coding-system-history* coding-system-alist
   read-coding-system read-buffer-file-coding-system
   set-buffer-file-coding-system
   revert-buffer-with-coding-system
   universal-coding-system-argument
   )

  (begin

    (define *coding-system-history* (make<history> '()))
    ;; ^ GNU Emacs's `coding-system-history' (`coding.c'), the history the
    ;; coding-system prompt keeps.

    (define (coding-system-alist)
      ;; GNU Emacs's `coding-system-alist' (`coding.c'): "Alist of coding
      ;; system names. Each element is one element list of coding system
      ;; name. This variable is given to `completing-read' as COLLECTION
      ;; argument." Each element is a one-element *list* because that is
      ;; how `completing-read' expects a collection entry to be shaped.
      ;;--------------------------------------------------------------
      ;;
      ;; The table is a hash table keyed by the name, as Emacs's
      ;; `Vcoding_system_hash_table' is, so this walks it rather than
      ;; mapping over a list.
      ;;--------------------------------------------------------------
      (hash-map->list
       (lambda (name cs) (list (symbol->string name)))
       (*coding-system-table*)))

    (define (read-coding-system prompt . args)
      ;; GNU Emacs's `read-coding-system' (`coding.c:8625'): "Read a
      ;; coding system from the minibuffer, prompting with string PROMPT.
      ;; If the user enters null input, return second argument
      ;; DEFAULT-CODING-SYSTEM."
      ;;
      ;; Emacs binds `completion-ignore-case' around the read because
      ;; every coding system name is lower case, which this tree's
      ;; completion does not need a binding for: it matches the way
      ;; `try-completion' does and there is no case-folding variable.
      ;;--------------------------------------------------------------
      (let ((default (if (pair? args) (car args) #f)))
        (let ((name (completing-read
                     (if default
                         (string-append prompt
                                        " (default "
                                        (if (symbol? default)
                                            (symbol->string default)
                                            default)
                                        "): ")
                         (string-append prompt ": "))
                     (coding-system-alist)
                     #f #t #f *coding-system-history*
                     (if (symbol? default) (symbol->string default) default))))
          (if (or (not name) (string=? name ""))
              (if (symbol? default) default #f)
              (string->symbol name)))))

    (define (read-buffer-file-coding-system)
      ;; GNU Emacs's `read-buffer-file-coding-system' (`mule.el:1250'):
      ;; the prompt `C-x RET f' asks with.
      ;;
      ;; Emacs narrows the completions to the coding systems that can
      ;; *encode the buffer*, which is `find-coding-systems-region' and
      ;; needs charsets; here the whole table is offered, which is what
      ;; Emacs does when the region is `undecided' (`(equal bcss
      ;; '(undecided))' - its own first branch). The default is the
      ;; buffer's current coding system, which is the useful one.
      ;;--------------------------------------------------------------
      (read-coding-system "Coding system for saving file"
                          (buffer-file-coding-system (current-buffer))))

    (define-command (set-buffer-file-coding-system coding-system force nomodify)
      ;; C-x RET f runs this. GNU Emacs's `set-buffer-file-coding-system'
      ;; (`mule.el:1308'): "Set the file coding-system of the current
      ;; buffer to CODING-SYSTEM. This means that when you save the
      ;; buffer, it will be converted according to CODING-SYSTEM."
      ;;
      ;; FORCE says what to do about an aspect CODING-SYSTEM leaves
      ;; unspecified: without it the aspect comes from the buffer's
      ;; previous value (`merge-coding-systems'), with it the aspect is
      ;; left unspecified. That is why the buffer is marked modified -
      ;; the next save must happen even if nothing was edited, because
      ;; the *bytes* it writes are different.
      ;;
      ;; The `select-safe-coding-system' warning Emacs runs before the
      ;; assignment is not carried; see the file header.
      "Set the file coding-system of the current buffer to CODING-SYSTEM.
This means that when you save the buffer, it will be converted
according to CODING-SYSTEM.

If CODING-SYSTEM leaves the text conversion unspecified, or if it leaves
the end-of-line conversion unspecified, FORCE controls what to do.
If FORCE is nil, get the unspecified aspect (or aspects) from the buffer's
previous `buffer-file-coding-system' value (if it is specified there).
Otherwise, leave it unspecified.

This marks the buffer modified so that the succeeding \\[save-buffer]
surely saves the buffer with CODING-SYSTEM.  From a program, if you
don't want to mark the buffer modified, specify t for NOMODIFY."
      (interactive (list (read-buffer-file-coding-system)
                         (current-prefix-arg) #f))
      (unless (coding-system-p coding-system)
        (error "Invalid coding system `%s'" coding-system))
      (let* ((buffer (current-buffer))
             (current (buffer-file-coding-system buffer))
             (coding (if (and coding-system current (not force))
                         (merge-coding-systems coding-system current)
                         coding-system)))
        (set!buffer-file-coding-system buffer coding)
        (unless nomodify
          (set-buffer-modified-p #t))
        (message "Coding system for saving this buffer is now %s"
                 (buffer-file-coding-system buffer))))

    (define-command (revert-buffer-with-coding-system coding-system force)
      ;; C-x RET r runs this. GNU Emacs's
      ;; `revert-buffer-with-coding-system' (`mule.el:1354'): "Visit the
      ;; current buffer's file again using coding system CODING-SYSTEM."
      ;;
      ;; It is `universal-coding-system-argument' applied to
      ;; `revert-buffer' - the read is done with the named coding system
      ;; and the buffer takes it - and Emacs's own shape is to bind
      ;; `coding-system-for-read' for the revert rather than to set the
      ;; buffer's variable first.
      "Visit the current buffer's file again using coding system CODING-SYSTEM.
For a list of possible values of CODING-SYSTEM, use \\[list-coding-systems]."
      (interactive (list (read-coding-system "Coding system for visited file (default nil)")
                         (current-prefix-arg)))
      (when coding-system
        (unless (coding-system-p coding-system)
          (error "Invalid coding system `%s'" coding-system))
        (let ((current (buffer-file-coding-system (current-buffer))))
          (when (and current (not force))
            (set! coding-system (merge-coding-systems coding-system current)))))
      (let ((*coding-system-for-read* coding-system))
        (revert-buffer)))

    (define-command (universal-coding-system-argument coding-system)
      ;; C-x RET c runs this. GNU Emacs's
      ;; `universal-coding-system-argument' (`mule-cmds.el:323'): "Execute
      ;; an I/O command using the specified CODING-SYSTEM."
      ;;
      ;; It is a *prefix* command: it does nothing itself, it arranges for
      ;; the next command's reading and writing to use CODING-SYSTEM.
      "Execute an I/O command using the specified CODING-SYSTEM."
      (interactive (list (read-coding-system
                          "Coding system for following command"
                          (buffer-file-coding-system (current-buffer)))))
      ;; **This is the whole of it, and Emacs needs three hooks and a
      ;; rewritten `this-command' to do the same thing.** The command loop
      ;; reads `*pending-coding-system*' where it reads the prefix
      ;; argument and binds the two coding-system variables around the
      ;; command - see `command.sld'. C-x RET c *is* a prefix command in
      ;; Emacs (`prefix-command-preserve-state'), so the prefix argument is
      ;; the mechanism it belongs in rather than one to imitate.
      (*pending-coding-system* coding-system)
      (message "With coding system %s" coding-system))

    (define mule-keymap (keymap))
    ;; ^ GNU Emacs's `mule-keymap' (`mule-cmds.el:41'), with the three
    ;; commands this tree has. See the file header for the rest.
    ;;
    ;; **It is the object and not the thing that gets looked up.** Emacs
    ;; binds `ctl-x-map'\'s `C-m' to it and a lookup descends into a
    ;; keymap-valued binding; this tree's lookup walks a map's own layers
    ;; and the maps beside it and does not descend, which is why
    ;; `find-file-other-window` is bound as a flat `C-x 4 f` rather than
    ;; as a submap of `C-x 4`. The commands are bound flat below and this
    ;; stays as the description of the keyboard it is in Emacs - a value
    ;; you can still `(define-key mule-keymap ...)` into.

    (define-key mule-keymap (kbd "f") set-buffer-file-coding-system)
    (define-key mule-keymap (kbd "r") revert-buffer-with-coding-system)
    (define-key mule-keymap (kbd "c") universal-coding-system-argument)

    ;; "Keep `C-x C-m ...' for mule specific commands."
    ;; RET *is* `C-m' - one key in a terminal and one event here,
    ;; measured: `(event-convert-list`\''s answer for `(ctrl ?m)` is 13, and
    ;; `(kbd "C-x RET f")` and `(kbd "C-x C-m f")` are the same key
    ;; sequence.
    (define-key *default-keymap* (kbd "C-x RET f") set-buffer-file-coding-system)
    (define-key *default-keymap* (kbd "C-x RET r") revert-buffer-with-coding-system)
    (define-key *default-keymap* (kbd "C-x RET c") universal-coding-system-argument)

    ))
