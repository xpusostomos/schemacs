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
    ;; `delete' is Guile's - R7RS has no list `delete'.
    (only (guile) delete)
    )

  (export
   add-to-history
   kbd
   nthcdr
   )

  (begin
    ;;----------------------------------------------------------------
    ;; `kbd' - the way a key is *named*.
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
