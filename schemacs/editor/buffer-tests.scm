(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine)
       new-text-editor text-editor-insert text-editor-to-string
       text-editor-set-cursor)
 (only (schemacs editor frame)
       *current-frame* *echo-area-buffer* new-frame selected-window
       set!window-buffer set!window-top-line window-buffer)
 (schemacs editor buffer)
 )

;; Tests for the buffer list - `(schemacs editor buffer)', which mirrors
;; GNU Emacs's `buffer.c'.
;;
;; The library has no consumer in the editor yet, so these are the only
;; check it has; they are written the way the other suites are, and each
;; one states what Emacs does for the same call, because the point of the
;; library is that Elisp's buffer functions mean here what they mean there.

;;--------------------------------------------------------------------
;; Harness

(define (fresh-frame)
  ;; A frame with no buffer in its window yet, which is what a frame is
  ;; before `new-frame' is given one. `*buffer-list*' is bound empty for
  ;; every test: it is module state, so one test's buffers would otherwise
  ;; be the next test's.
  ;;--------------------------------------------------------------
  (new-frame (new-text-editor) 24 80))

(define (with-buffers thunk)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame)
                   (*echo-area-buffer* #f)
                   (*buffer-list* '())
                   (*buffer-list-update-hook* '())
                   (*kill-buffer-query-functions* '())
                   (*current-buffer* #f))
      (thunk))))

(define (names) (map buffer-name (buffer-list)))

;;--------------------------------------------------------------------
;; Making buffers, and finding them by name

(test-begin "schemacs_editor_buffer")

;; `get-buffer-create' is the way to reach a buffer by name, and it answers
;; with the same buffer every time - which is what makes "*Completions*" a
;; thing two pieces of code can agree on.
(test-equal #t
  (with-buffers
   (lambda ()
     (let ((first (get-buffer-create "*scratch*")))
       (eq? first (get-buffer-create "*scratch*"))))))

(test-equal '(#f #t)
  (with-buffers
   (lambda ()
     (list (get-buffer "nope")
           (begin (get-buffer-create "yes") (bufferp (get-buffer "yes")))))))

;; `generate-new-buffer-name' appends `<N>', counting from 2 - GNU Emacs's
;; format, which the C in `buffer.c' gives as `name<2>'. It *skips* the
;; names that are taken rather than stopping at the first: with "taken",
;; "taken<2>" and "taken<3>" all existing, "taken" gives "taken<4>". And
;; the number goes on the name it was given, so "taken<2>" gives
;; "taken<2><2>".
(test-equal '("free" "taken<4>" "taken<2><2>" "taken<3><2>")
  (with-buffers
   (lambda ()
     (get-buffer-create "taken")
     (get-buffer-create "taken<2>")
     (get-buffer-create "taken<3>")
     (list (generate-new-buffer-name "free")
           (generate-new-buffer-name "taken")
           (generate-new-buffer-name "taken<2>")
           (generate-new-buffer-name "taken<3>")))))

;; A buffer just made is at the front of the list - Emacs's `buffer-list'
;; is in most-recently-used order, and making one is a use.
(test-equal '("new" "*scratch*")
  (with-buffers
   (lambda ()
     (get-buffer-create "*scratch*")
     (generate-new-buffer "new")
     (names))))

;; `rename-buffer' renames it in the list too, which is what makes the name
;; a buffer is found by afterwards.
(test-equal '(("renamed") #t #f)
  (with-buffers
   (lambda ()
     (let ((buffer (get-buffer-create "old")))
       (rename-buffer buffer "renamed")
       (list (names) (eq? buffer (get-buffer "renamed")) (get-buffer "old"))))))

;; ... and with the UNIQUE argument it makes the name unique rather than
;; refusing it.
(test-equal "taken<2>"
  (with-buffers
   (lambda ()
     (get-buffer-create "taken")
     (rename-buffer (get-buffer-create "other") "taken" #t))))

;; A name already in use is an error, as `rename-buffer' makes it one.
(test-equal #t
  (with-buffers
   (lambda ()
     (get-buffer-create "taken")
     (guard (ex (else #t))
       (rename-buffer (get-buffer-create "other") "taken")
       #f))))

;;--------------------------------------------------------------------
;; The current buffer

;; `set-buffer' makes a buffer current without putting it in a window, and
;; `current-buffer' answers with it - while the frame's own notion (the
;; selected window's buffer) is untouched.
(test-equal '("other" "start" "other")
  (with-buffers
   (lambda ()
     (let* ((start (get-buffer-create "start"))
            (other (get-buffer-create "other")))
       (set!window-buffer (selected-window) start)
       (set-buffer other)
       (list (buffer-name (current-buffer))
             ;; the window still shows what it showed: `set-buffer' does
             ;; not put a buffer in a window
             (buffer-name (window-buffer (selected-window)))
             ;; and `save-current-buffer' puts back the buffer that was
             ;; current when it was entered - `other', which `set-buffer'
             ;; set above - rather than the one it was given
             (begin (save-current-buffer (lambda () (set-buffer start)))
                    (buffer-name (current-buffer))))))))

;; `with-current-buffer' is a macro, as it is in Emacs, so the body reads
;; as if the buffer were simply current - and the buffer is restored
;; afterwards whatever the body does.
(test-equal '("inner" "outer" "outer")
  (with-buffers
   (lambda ()
     (let ((outer (get-buffer-create "outer"))
           (inner (get-buffer-create "inner")))
       (set-buffer outer)
       (list (with-current-buffer inner (buffer-name (current-buffer)))
             (buffer-name (current-buffer))
             (begin (guard (ex (else 'ignored))
                      (with-current-buffer inner (error "inside")))
                    (buffer-name (current-buffer))))))))

;;--------------------------------------------------------------------
;; The order of the list, and choosing another buffer

;; `bury-buffer' sends a buffer to the end, so `other-buffer' will not
;; choose it until there is nothing else.
(test-equal '(("a" "b") "a" "b")
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "b")))
       (get-buffer-create "a")
       (list (names)
             (begin (bury-buffer b) (buffer-name (car (buffer-list))))
             (buffer-name (other-buffer (get-buffer "a"))))))))

;; `other-buffer' answers with the most recently used buffer that is not
;; the one it was told to avoid.
(test-equal '("second" "first")
  (with-buffers
   (lambda ()
     (let ((first (get-buffer-create "first"))
           (second (get-buffer-create "second")))
       (list (buffer-name (other-buffer first))
             (buffer-name (other-buffer second)))))))

;; With no other buffer it makes `*scratch*' rather than answer with
;; nothing, so a window is never left showing a buffer that is not there.
(test-equal '("*scratch*" 2)
  (with-buffers
   (lambda ()
     (let ((only (get-buffer-create "only")))
       (list (buffer-name (other-buffer only))
             (length (buffer-list)))))))

;;--------------------------------------------------------------------
;; Killing

;; `kill-buffer' takes the buffer out of the list and answers with its
;; name, and the buffer stops being live though the object remains.
(test-equal '(("keep") "gone" #f #t)
  (with-buffers
   (lambda ()
     (let ((gone (get-buffer-create "gone")))
       (get-buffer-create "keep")
       (let ((name (kill-buffer gone)))
         (list (names) name (buffer-live-p gone) (bufferp gone)))))))

;; A buffer shown in a window is not left there: the window is given
;; another buffer, as `replace-buffer-in-windows' does in Emacs.
(test-equal '("other")
  (with-buffers
   (lambda ()
     (let* ((doomed (get-buffer-create "doomed"))
            (window (selected-window)))
       (set!window-buffer window doomed)
       (get-buffer-create "other")
       (kill-buffer doomed)
       (list (buffer-name (window-buffer window)))))))

;; `kill-buffer-query-functions' can refuse the kill, and then nothing
;; happens at all - the buffer stays and the answer is false.
(test-equal '(#f #t ("kept") "kept")
  (with-buffers
   (lambda ()
     (let ((kept (get-buffer-create "kept")))
       (parameterize ((*kill-buffer-query-functions* (list (lambda () #f))))
         (let ((refused (kill-buffer kept)))
           (list refused
                 (buffer-live-p kept)
                 (begin (*kill-buffer-query-functions* '())
                        (names))
                 (kill-buffer kept))))))))

;;--------------------------------------------------------------------
;; The slots a buffer has besides its text

;; A buffer's own keymap is the one the lookup searches before the global
;; map, and it lives beside the buffer rather than in it - and goes when
;; the buffer is killed, because the table that holds it is weak.
(test-equal '(#f a-keymap #f 17)
  (with-buffers
   (lambda ()
     (let ((buffer (get-buffer-create "slots")))
       (let ((before (buffer-local-keymap buffer)))
         (set!buffer-local-keymap buffer 'a-keymap)
         (set-buffer-local-value! buffer 'a-variable 17)
         (let ((after (buffer-local-keymap buffer))
               (value (buffer-local-value buffer 'a-variable #f)))
           (kill-buffer buffer)
           (list before after (buffer-local-keymap buffer) value)))))))

(test-end "schemacs_editor_buffer")