(define-library (schemacs map-ynp)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/map-ynp.el': the
  ;; question-askers that walk a list of objects - `map-y-or-n-p', of
  ;; which nothing needs the list walking yet, and `read-answer', which
  ;; Dired's `dired-delete-file' asks before it deletes a directory that
  ;; has anything in it.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * **`map-y-or-n-p' itself** - the prompter/actor loop that asks
  ;;     about each object in a list, including its `help' key and its
  ;;     `C-h' handling. Nothing here needs it; `read-answer' is the
  ;;     whole of what Dired asks for.
  ;;   * **the dialog-box path** - Emacs asks for an answer with
  ;;     `x-popup-dialog' when `use-dialog-box' and
  ;;     `display-popup-menus-p' both allow it. There are no popup menus
  ;;     in this tree, so that arm cannot be taken and is not written.
  ;;   * **the short-answer keymap** - Emacs binds each one-character
  ;;     answer in a sparse keymap whose `self-insert-command' is
  ;;     remapped to say "Type ? for help", so that a key that is not an
  ;;     answer does not go into the minibuffer at all. That needs
  ;;     `delete-minibuffer-contents' (minibuf.c's), which is not
  ;;     ported; the answer is read with `read-char-from-minibuffer'
  ;;     instead - the same one-key question, with an unbound answer
  ;;     beeping the same message. The long-answer path, which is the
  ;;     one `read-answer-short''s default of `auto' resolves to, is
  ;;     Emacs's own.
  ;;   * **`read-answer-map--memoize'** - Emacs caches each answers list's
  ;;     keymap in a weak-keyed hash. The keymap is a function call here.

  (import
    (scheme base)
    (scheme char)
    ;; `string-join' is `mapconcat''s: the answers written out between
    ;; ", " for the prompt.
    (only (guile) caddr string-join)
    ;; the question, and the one-key question the short path asks
    (only (schemacs editor minibuffer)
          read-from-minibuffer read-char-from-minibuffer)
    ;; a message goes to the echo area, and the `message' that puts it
    ;; there is editfns.c's in Emacs 31
    (only (schemacs editor editfns) format message)
    )

  (export *read-answer-short* *use-short-answers* read-answer
          read-answer-short)

  (begin

    (define *read-answer-short* (make-parameter 'auto))
    ;; ^ GNU Emacs's `read-answer-short' (map-ynp.el:406), whose default
    ;; is `auto': "accept short answers if `use-short-answers' is
    ;; non-nil, or the function cell of `yes-or-no-p' is set to
    ;; `y-or-n-p'."

    (define *use-short-answers* (make-parameter #f))
    ;; ^ GNU Emacs's `use-short-answers', false by default.

    (define (read-answer-short)
      ;; The resolution `read-answer' makes of `read-answer-short'
      ;; (map-ynp.el:451). Emacs's second test is on `yes-or-no-p''s
      ;; *function cell*, which a user can set to `y-or-n-p'; a command
      ;; here is a procedure rather than a name with a cell, so that way
      ;; of asking for short answers has no equivalent, and the variable
      ;; is the one that answers.
      ;;--------------------------------------------------------------
      (if (eq? (*read-answer-short*) 'auto)
          (*use-short-answers*)
          (*read-answer-short*)))

    (define (read-answer question answers)
      ;; GNU Emacs's `read-answer' (map-ynp.el:415): "Read an answer
      ;; either as a complete word or its character abbreviation. Ask
      ;; user a question and accept an answer from the list of possible
      ;; answers. Return the long answer even when accepting short ones."
      ;;
      ;; ANSWERS is an alist of `(LONG-ANSWER SHORT-ANSWER HELP-MESSAGE)',
      ;; as it is in Emacs.
      ;;--------------------------------------------------------------
      (let* ((short (read-answer-short))
             (answers-with-help
              (if (assoc "help" answers)
                  answers
                  (append answers '(("help" ?? "show this help message")))))
             (answers-without-help
              (let loop ((rest answers-with-help) (acc '()))
                (cond ((null? rest) (reverse acc))
                      ((equal? (car (car rest)) "help") (loop (cdr rest) acc))
                      (else (loop (cdr rest) (cons (car rest) acc))))))
             (prompt
              (string-append question
                             "("
                             (string-join
                              (map (lambda (a)
                                     (if short
                                         (short-answer-text (cadr a))
                                         (car a)))
                                   answers-with-help)
                              ", ")
                             ") "))
             (the-message
              (string-append
               "Please answer "
               (string-join
                (map (lambda (a)
                       (string-append "`"
                                      (if short (short-answer-text (cadr a))
                                          (car a))
                                      "'"))
                     answers-with-help)
                " or ")
               "."))
             (answer #f))
        (let loop ()
          (set! answer
                (string-downcase
                 (if short
                     (string (read-char-from-minibuffer prompt))
                     (read-from-minibuffer prompt #f #f #f #f))))
          (if (assoc answer answers-without-help)
              answer
              (begin
                ;; "help" is the two-character answer `?', and the rest
                ;; of the answers are listed - Emacs shows them in the
                ;; `*Help*' window, which is not ported; the message
                ;; takes their place.
                (message "%s" (read-answer-help-text question answers-with-help
                                                     short))
                (loop))))
        ;; the long answer, which is the car of the entry the answer matched
        (car (assoc answer answers-without-help))))

    (define (short-answer-text short-answer)
      ;; A short answer written out: `map-ynp.el' does this with
      ;; `(if (characterp (nth 1 a)) (format "%c" (nth 1 a))
      ;; (key-description (nth 1 a)))' - a character, or a key like C-M-h
      ;; named by `key-description'.
      ;;--------------------------------------------------------------
      (if (char? short-answer)
          (string short-answer)
          (format "%s" short-answer)))

    (define (read-answer-help-text question answers-with-help short)
      ;; The text `read-answer''s `help' branch puts in `*Help*' - here
      ;; said in the echo area, since the help window is not ported.
      ;;--------------------------------------------------------------
      (string-append
       question
       (string-join
        (map (lambda (a)
               (string-append "`"
                              (if short (short-answer-text (cadr a)) (car a))
                              "'"
                              (if short
                                  (string-append " (" (car a) ")")
                                  "")
                              " to "
                              (caddr a)))
             answers-with-help)
        ", ")
       "."))

    ))
