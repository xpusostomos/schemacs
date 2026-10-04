(define-library (schemacs editor subr)
  ;; This library mirrors GNU Emacs's `subr.el': the small general
  ;; functions the rest of Emacs is written in terms of.
  ;;
  ;; What is here so far is one of them, `add-to-history', which the kill
  ;; ring and the mark ring both push onto. Subr is enormous and mostly
  ;; elisp-layer; it grows as the things that need it arrive.

  (import
    (scheme base)
    ;; `history-length' and `history-delete-duplicates' are `minibuf.c''s
    ;; variables, and `add-to-history' reads them for the maximum length
    ;; when the caller does not give one.
    (only (schemacs editor minibuf)
          *history-delete-duplicates* *history-length*)
    ;; `delete' is Guile's - R7RS has no list `delete' - and `logand' is
    ;; `key-parse''s control-character folding.
    (only (guile) delete logand string-contains)
    ;; `string-prefix-p' compares with `compare-strings', which is
    ;; fns.c's and lives in `(schemacs editor fns)'. That library is
    ;; below this one - it imports none of subr - so this is not a
    ;; cycle.
    (only (schemacs editor fns) compare-strings)
    )

  (export
   add-to-history
   string-prefix-p
   string-replace
   *after-change-major-mode-hook*
   *change-major-mode-after-body-hook*
   *delayed-after-hook-functions*
   *delayed-mode-hooks*
   *delay-mode-hooks*
   delay-mode-hooks
   ignore
   run-hooks
   run-mode-hooks
   kbd
   nthcdr
   )

  (begin
    (define (string-prefix-p prefix string . rest)
      ;; GNU Emacs's `string-prefix-p' (subr.el:6246): "Return non-nil if
      ;; STRING begins with PREFIX. PREFIX should be a string; the
      ;; function returns non-nil if the characters at the beginning of
      ;; STRING compare equal with PREFIX. If IGNORE-CASE is non-nil, the
      ;; comparison is done without paying attention to letter-case
      ;; differences."
      ;;
      ;; The answer is the C's `(eq t (compare-strings ...))' - against
      ;; the symbol `t', not against a true value: `compare-strings'
      ;; answers the index of the first difference when they differ, so
      ;; `eq t' is the whole test.
      ;;
      ;; `string-length' and not `length': Emacs's `length' takes a
      ;; string and Guile's does not.
      ;;--------------------------------------------------------------
      (let ((ignore-case (and (pair? rest) (car rest)))
            (prefix-length (string-length prefix)))
        (if (> prefix-length (string-length string))
            #f
            (eq? #t (compare-strings prefix 0 prefix-length
                                     string 0 prefix-length
                                     ignore-case)))))

    (define (string-replace from-string to-string in-string)
      ;; GNU Emacs's `string-replace' (subr.el:6157): "Replace FROM-STRING
      ;; with TO-STRING in IN-STRING each time it occurs."
      ;;
      ;; The C searches with `string-search', which is `string-contains'
      ;; here and answers an index rather than the C's position or nil -
      ;; the two are the same question. An empty FROM-STRING is the C's
      ;; `wrong-length-argument', which is an error here too.
      ;;--------------------------------------------------------------
      (when (string=? from-string "")
        (error "Wrong length argument: 0"))
      (let loop ((start 0) (result '()))
        (let ((pos (string-contains in-string from-string start)))
          (cond
           ((not pos)
            ;; "No replacements were done, so just return the original
            ;; string" - the C's answer when RESULT is still nil
            (if (null? result)
                in-string
                (begin
                  (unless (= start (string-length in-string))
                    (set! result (cons (substring in-string start) result)))
                  (apply string-append (reverse result)))))
           (else
            (loop (+ pos (string-length from-string))
                  (cons to-string
                        (if (= start pos)
                            result
                            (cons (substring in-string start pos) result)))))))))


    ;;
    ;; GNU Emacs's `kbd' (`subr.el:1258') is how a user writes a key
    ;; sequence: `(kbd "C-x C-f")', `(kbd "C-/")', `(kbd "<up>")'. It is
    ;; `key-parse' (`keymap.el:235') doing the work, and it is the one
    ;; place the key vocabulary is written down: every binding in Emacs
    ;; is either a literal string/vector or a `kbd' call, and both end up
    ;; in the same representation.
    ;;
    ;; Without it there is no way for a user to write a binding at all -
    ;; the only way here was a raw path list, and the path each *front
    ;; end* produces for a key is not the same. A terminal folds C-/ and
    ;; C-_ into one byte where a window system sends two different
    ;; keysyms, so a binding written against one front end's spelling
    ;; matched only that front end - which is why C-/ and C-_ did nothing
    ;; on the graphical one, and why C-@ and C-SPC needed two bindings.
    ;;
    ;; The result is this tree's key path: a list of keys, each either a
    ;; character, a string naming a keyboard key, or a list of modifier
    ;; symbols followed by the character or string - so `(kbd "C-x C-f")'
    ;; is `((ctrl #\x) (ctrl #\f))' and `(kbd "C-/")' is `((ctrl #\/))'.
    ;; `define-key' takes it and `keymap-index' reads it, so a binding
    ;; written with `kbd' is written the way a front end is expected to
    ;; deliver.
    ;;----------------------------------------------------------------

    (define *key-parse-modifiers*
      ;; The modifier prefixes `key-parse' takes, with the symbols that
      ;; name them in a key path. Emacs accumulates the same six, as bits
      ;; on the character; here they are the path's modifier symbols.
      '((#\A . alt)
        (#\C . ctrl)
        (#\H . hyper)
        (#\M . meta)
        (#\s . shift)
        (#\S . super)))

    (define *key-parse-named*
      ;; The named keys `key-parse' translates, with the characters they
      ;; stand for. These are `key-parse''s own list.
      ;; `\delete' is ncurses's DEL; Scheme has no character name for
      ;; it that this tree agrees on, so it is the character 127.
      '(("NUL" . #\nul) ("RET" . #\return) ("LFD" . #\newline)
        ("TAB" . #\tab) ("ESC" . #\esc) ("SPC" . #\space)
        ("DEL" . ,(integer->char 127))))

    (define (key-parse-word keys pos)
      ;; The next word of KEYS from POS: up to the next space, but a word
      ;; that begins with `<' runs to its `>', which is how `<up>' holds
      ;; a space it should not be split at.
      ;;--------------------------------------------------------------
      (let ((end (string-length keys)))
        (if (and (< pos end) (char=? (string-ref keys pos) #\<))
            (let scan ((i (+ pos 1)))
              (cond ((>= i end) end)
                    ((char=? (string-ref keys i) #\>) (+ i 1))
                    (else (scan (+ i 1)))))
            (let scan ((i pos))
              (cond ((>= i end) end)
                    ((char=? (string-ref keys i) #\space) i)
                    (else (scan (+ i 1))))))))

    (define (key-parse-modifiers word)
      ;; The modifier symbols WORD prefixes and the character or named
      ;; key they modify: `(VALUES . REST)'. `key-parse' strips the
      ;; prefixes one at a time, so `C-M-_` is two.
      ;;--------------------------------------------------------------
      (let loop ((mods '()) (rest word))
        (if (and (> (string-length rest) 2)
                 (char=? (string-ref rest 1) #\-)
                 (assv (string-ref rest 0) *key-parse-modifiers*))
            (loop (cons (cdr (assv (string-ref rest 0)
                                   *key-parse-modifiers*))
                        mods)
                  (substring rest 2))
            (cons (reverse mods) rest))))

    (define (parse-key word)
      ;; One word of a `kbd' string as one key of a key path: the chord
      ;; `(modifiers... character-or-string)'.
      ;;--------------------------------------------------------------
      (if (and (> (string-length word) 2)
               (char=? (string-ref word 0) #\<)
               (char=? (string-ref word (- (string-length word) 1)) #\>))
          ;; `<up>' names a keyboard key, which is how a named key is
          ;; written in a key path here - and Emacs's is a symbol in the
          ;; vector, `up', the same thing as the string this tree uses.
          (substring word 1 (- (string-length word) 1))
          (let* ((mods-and-key (key-parse-modifiers word))
                 (mods (car mods-and-key))
                 (named (cdr mods-and-key))
                 ;; the modifiers are off; now a `<...>` names a keyboard
                 ;; key, which is why this is done after them
                 (named (if (and (> (string-length named) 2)
                                 (char=? (string-ref named 0) #\<)
                                 (char=? (string-ref named
                                                    (- (string-length named) 1))
                                 #\>))
                            (substring named 1 (- (string-length named) 1))
                            named))
                 (found (assoc named *key-parse-named*))
                 (char (if found (cdr found) (and (= (string-length named) 1)
                                                 (string-ref named 0)))))
            (cond
             (char (if (null? mods) char (append mods (list char))))
             (named (if (null? mods) named (append mods (list named))))
             (else #f)))))

    (define (kbd keys)
      ;; GNU Emacs's `kbd': KEYS as this tree's key path, for `define-key'.
      ;;--------------------------------------------------------------
      (let loop ((rest keys) (keys '()))
        (if (string=? rest "")
            (reverse keys)
            (let* ((pos (let scan ((i 0))
                          (cond ((>= i (string-length rest)) #f)
                                ((char=? (string-ref rest i) #\space)
                                 (scan (+ i 1)))
                                (else i))))
                   (word-beg (or pos (string-length rest)))
                   (word-end (key-parse-word rest word-beg))
                   (word (substring rest word-beg word-end))
                   (key (parse-key word)))
              (loop (substring rest (min word-end (string-length rest)))
                    (cons key keys))))))


    (define (run-hooks . hooks)
      ;; GNU Emacs's `run-hooks' (subr.el): run each hook in turn. A hook
      ;; is named by a *variable* in Emacs and read by this; here a hook
      ;; is the list of procedures itself - the tree keeps one as a
      ;; `make-parameter' holding a list - so the list is what is passed.
      ;; An argument that is a procedure rather than a list is a single
      ;; function, which is what `run-hooks' does with a non-list value.
      ;;--------------------------------------------------------------
      (for-each (lambda (hook)
                  (cond ((not hook) #f)
                        ((procedure? hook) (hook))
                        (else (for-each (lambda (f) (f)) hook))))
                hooks))

    (define *change-major-mode-after-body-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `change-major-mode-after-body-hook' (`subr.el'):
    ;; "Normal hook run after running the body of `define-derived-mode'."

    (define *after-change-major-mode-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `after-change-major-mode-hook' (`subr.el'): "Normal
    ;; hook run at the end of `run-mode-hooks', which see. ... every
    ;; major mode runs it, whether it is defined with `define-derived-mode'
    ;; or not."

    (define *delay-mode-hooks* (make-parameter #f))
    ;; ^ GNU Emacs's `delay-mode-hooks' (`subr.el'): "Non-nil means
    ;; `run-mode-hooks' should delay running the hooks." A buffer-local
    ;; variable in Emacs and a parameter here, as this tree keeps
    ;; buffer-local flags.

    (define *delayed-mode-hooks* (make-parameter '()))
    ;; ^ GNU Emacs's `delayed-mode-hooks': the hooks a mode asked for
    ;; while the running was delayed, newest first.

    (define *delayed-after-hook-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `delayed-after-hook-functions': what a derived
    ;; mode's `:after-hook' pushed, run at the very end of
    ;; `run-mode-hooks'.

    (define (delay-mode-hooks thunk)
      ;; GNU Emacs's `delay-mode-hooks' (`subr.el':2795): "Execute BODY,
      ;; but delay any `run-mode-hooks'. These hooks will be executed by
      ;; the first following call to `run-mode-hooks' that occurs outside
      ;; any `delay-mode-hooks' form."
      ;;
      ;; A macro in Emacs; a procedure taking the body as a thunk here,
      ;; which is how this tree spells a body-taking form that has no
      ;; syntax of its own to keep.
      ;;--------------------------------------------------------------
      (parameterize ((*delay-mode-hooks* #t)) (thunk)))

    (define (run-mode-hooks . hooks)
      ;; GNU Emacs's `run-mode-hooks' (subr.el:2756): "Run mode hooks
      ;; `delayed-mode-hooks' and HOOKS, or delay HOOKS. ... Otherwise,
      ;; runs hooks in the sequence: `change-major-mode-after-body-hook',
      ;; `delayed-mode-hooks' (in reverse order), HOOKS, then runs
      ;; `hack-local-variables' (if the buffer is visiting a file), runs
      ;; the hook `after-change-major-mode-hook', and finally evaluates
      ;; the functions in `delayed-after-hook-functions'."
      ;;
      ;; Not ported: `hack-local-variables', there being no file-local
      ;; variable machinery here yet. The C's other errand in that gap -
      ;; turning on `parse-sexp-lookup-properties' when
      ;; `syntax-propertize-function' is set - waits for
      ;; `syntax-propertize' too.
      ;;--------------------------------------------------------------
      (if (*delay-mode-hooks*)
          ;; "just adds the HOOKS to the list"
          (*delayed-mode-hooks* (append hooks (*delayed-mode-hooks*)))
          (begin
            (set! hooks (append (reverse (*delayed-mode-hooks*)) hooks))
            (*delayed-mode-hooks* '())
            (apply run-hooks
                   (cons (*change-major-mode-after-body-hook*) hooks))
            (run-hooks (*after-change-major-mode-hook*))
            (let ((after (reverse (*delayed-after-hook-functions*))))
              (*delayed-after-hook-functions* '())
              (for-each (lambda (f) (f)) after)))))

    (define (ignore . _arguments)
      ;; GNU Emacs's `ignore' (`subr.el:501'): accept any arguments, do
      ;; nothing, and answer nil. It is what Emacs binds keys that must be
      ;; received but not acted on to - `[sigusr1]' in
      ;; `special-event-map' - and it is what this tree's resize event is
      ;; bound to: a frame resize is handled by redisplay re-framing, and
      ;; the event only has to be dispatched for the loop to redraw.
      ;;
      ;; Emacs answers nil here, which this tree's `#f' is - and writing
      ;; the word `nil' was an error, not a spelling, and is what the
      ;; "unbound variable: nil" the echo area showed was.
      ;;--------------------------------------------------------------
      #f)

    (define (nthcdr n list)
      ;; GNU Emacs's `nthcdr': the tail of LIST after the first N
      ;; elements - and nil when the list is shorter than that, which is
      ;; the whole point of having it: Scheme's `list-tail' is an error
      ;; there, and Elisp's sloppiness is what the callers rely on.
      ;;--------------------------------------------------------------
      (let loop ((n n) (rest list))
        (if (or (<= n 0) (not (pair? rest)))
            rest
            (loop (- n 1) (cdr rest)))))

    (define (add-to-history history-list newelt . args)
      ;; GNU Emacs's `add-to-history': HISTORY-LIST with NEWELT on the
      ;; front, duplicates of it removed when
      ;; `history-delete-duplicates' says so, and the list cut back to
      ;; MAXELT - which answers with `history-length' when the caller
      ;; does not give one.
      ;;
      ;; It takes the list and answers a new one, rather than taking a
      ;; variable's name as Emacs's does: a Scheme procedure cannot set a
      ;; variable the caller names, so the setting is the caller's.
      ;;--------------------------------------------------------------
      (let* ((maxelt (if (pair? args) (car args) #f))
             (keep-all (if (and (pair? args) (pair? (cdr args)))
                           (cadr args)
                           #f))
             (maxelt (or maxelt (*history-length*))))
        (if (and (list? history-list)
                 (or keep-all
                     (not (string? newelt))
                     (< 0 (string-length newelt)))
                 ;; Elisp's `(car nil)' is nil, so Emacs's test is
                 ;; true for an empty list; Scheme's is an error, so
                 ;; the emptiness is tested for.
                 (or keep-all
                     (not (and (pair? history-list)
                               (equal? (car history-list) newelt)))))
            (let* ((history (if (*history-delete-duplicates*)
                                (delete newelt history-list)
                                history-list))
                   (history (cons newelt history)))
              (cond
               ((not (integer? maxelt)) history)
               ((<= maxelt 0) '())
               (else
                (let ((tail (nthcdr (- maxelt 1) history)))
                  (if (pair? tail) (set-cdr! tail '()))
                  history))))
            history-list)))

    ))
