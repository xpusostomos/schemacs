(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf format)
 (only (schemacs editor character) kbd)
 (prefix (schemacs editor keymap) km:)
 (only (schemacs editor replace) *query-replace-map*)
 (only (oop goops) make)
 (only (schemacs map-ynp) map-y-or-n-p)
 (prefix (schemacs map-ynp) my:)
 (only (schemacs editor frame)
       *current-frame* *echo-area-buffer* *frame-list* *frame-creation-function*
       new-frame set-window-buffer! frame-selected-window frame-message
       *default-frame-alist*)
 (only (schemacs editor buffer)
       allocate-buffer *buffer-list* *current-buffer* with-current-buffer
       set-buffer-modified-p buffer-modified-p)
 (only (schemacs editor test-display) <test-display> test-display-script)
 (only (schemacs editor dispnew) current-display read-input-event)
 (only (schemacs editor keyboard) *unread-command-events*)
 (only (schemacs editor editfns) insert current-message))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; `map-y-or-n-p` (`map-ynp.el:43`) is the question-asker `save-some-
;; buffers` asks through, and every expectation below is Emacs 31.1's
;; own text for the same question: the prompt is the C's format string
;; with each key written by `substitute-command-keys`.
;;
;; The answers are read from a `<test-display>` script, which is what a
;; key event is for the minibuffer's read.

(define *display* (make <test-display>))
(current-display *display*)
(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define (with-asker script thunk)
  ;; A frame over an empty buffer, the script the read will see, and the
  ;; asker's state fresh - `unread-command-events` in particular, because
  ;; a quit's pushback would otherwise reach the next test.
  (let* ((ed (allocate-buffer))
         (frame (new-frame ed 24 80)))
    (parameterize ((*frame-list* (list frame))
                   (*current-frame* frame)
                   (*echo-area-buffer* #f)
                   (*buffer-list* '())
                   (*current-buffer* #f)
                   (*unread-command-events* '()))
      (set-window-buffer! (frame-selected-window frame) ed)
      (*current-buffer* ed)
      (with-current-buffer ed (insert ""))
      (set! (test-display-script *display*) script)
      (thunk frame))))

(test-begin "schemacs_map_ynp")

;; `y` and `SPC` act; `n` and `DEL` skip; the count is the actions taken.
(test-equal (list 2 (list "b" "a"))
  (with-asker (list #\y #\space)
    (lambda (frame)
      (let ((seen '()))
        (list (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                            (lambda (o) (set! seen (cons o seen)))
                            '("a" "b") '("buffer" "buffers" "save")
                            '() #f)
              seen)))))

;; The prompt is Emacs's, character for character - captured from the
;; answer's echo, which is `"%s%s"` of the prompt and the key. The key
;; list is `save-some-buffers-action-alist`'s minus `d`, which needs
;; `diff-no-select`; with no action alist the user-keys part is empty.
(test-equal "Save a? (y, n, !, ., q, or C-h) y"
  (with-asker (list #\y)
    (lambda (frame)
      (let ((message #f))
        (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                      (lambda (o) (set! message (current-message)))
                      '("a") '("buffer" "buffers" "save") '() #f)
        (substring message
                   0
                   (string-length message))))))

;; `q` stops without acting; `!` acts on everything without asking; `.`
;; acts on the current object and stops.
(test-equal '(0 ())
  (with-asker (list #\q)
    (lambda (frame)
      (let ((seen '()))
        (list (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                            (lambda (o) (set! seen (cons o seen)))
                            '("a" "b") '("buffer" "buffers" "save") '() #f)
              seen)))))

(test-equal '(2 ("a" "b"))
  (with-asker (list #\!)
    (lambda (frame)
      (let ((seen '()))
        (list (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                            (lambda (o) (set! seen (cons o seen)))
                            '("a" "b") '("buffer" "buffers" "save") '() #f)
              (reverse seen))))))

(test-equal '(1 ("a"))
  (with-asker (list #\.)
    (lambda (frame)
      (let ((seen '()))
        (list (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                            (lambda (o) (set! seen (cons o seen)))
                            '("a" "b") '("buffer" "buffers" "save") '() #f)
              (reverse seen))))))

;; A prompter that answers a non-string acts without asking: that is how
;; `save-some-buffers` saves everything under a prefix argument (`t`).
(test-equal '(3 ("a" "b" "c"))
  (with-asker '()
    (lambda (frame)
      (let ((seen '()))
        (list (map-y-or-n-p (lambda (o) #t)
                            (lambda (o) (set! seen (cons o seen)))
                            '("a" "b" "c") '("buffer" "buffers" "save") '() #f)
              (reverse seen))))))

;; `M-~` in an action alist: a user key whose function returning non-nil
;; counts as an action and moves on without asking again.
(test-equal '(1 (skipped))
  (with-asker (list #\x1b #\~)
    (lambda (frame)
      (let ((seen '()))
        (list (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                            (lambda (o) (set! seen (cons o seen)))
                            '("a") '("buffer" "buffers" "save")
                            (list (list (vector-ref (kbd "M-~") 0)
                                        (lambda (o) (set! seen (cons 'skipped seen)) #t)
                                        "skip this buffer and mark it unmodified"))
                            #f)
              (reverse seen))))))

;; C-g quits: `def` is `quit`, `quit-flag` is set, and the next read
;; raises it - which is the C's two steps.
(test-equal 'quit
  (with-asker (list #\x07)
    (lambda (frame)
      (call/cc
       (lambda (k)
         (with-exception-handler
          (lambda (e) (k 'quit))
          (lambda ()
            (map-y-or-n-p (lambda (o) (format #f "Save ~a? " o))
                          (lambda (o) #f)
                          '("a") '("buffer" "buffers" "save") '() #f)
            'no-quit)))))))

;; The answers `map-y-or-n-p` consults are `query-replace-map`'s, and
;; the symbols are Emacs's. Measured on Emacs 31.1 with
;; `(lookup-key query-replace-map (vector KEY))' for each key:
;;
;;   y act, SPC act, ! automatic, n skip, DEL skip, q exit, RET exit,
;;   z nil, . act-and-exit
;;
;; **ESC is the one difference**: Emacs's map answers an ESC *prefix
;; keymap* there (`C-v`, `v` and `M-v` are bound behind ESC), so the bare
;; ESC exits through the prefix's own entry; this tree binds the bare ESC
;; to `exit-prefix`, which is the same documented answer ("ESC or q to
;; exit") one lookup earlier.
(test-equal '(act act automatic skip skip exit exit exit-prefix #f act-and-exit)
  (map (lambda (k) (km:keymap-lookup *query-replace-map* (vector k)))
       (list (char->integer #\y) 32 (char->integer #\!)
             (char->integer #\n) 127 (char->integer #\q) 13 27
             (char->integer #\z) (char->integer #\.))))

(test-end "schemacs_map_ynp")
