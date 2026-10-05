(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine)
       new-text-editor text-editor-insert text-editor-to-string
       text-editor-set-cursor)
 (only (schemacs editor textprop) get-char-property put-text-property)
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

;;--------------------------------------------------------------------
;; Overlays - `buffer.c''s other half

;; `make-overlay' takes a range, and its two ends are *markers*: they
;; follow the text as it is edited, which is the difference between an
;; overlay and a text property.
(test-equal "an overlay spans the range it was made with"
  '(1 6)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (let ((o (make-overlay 1 6)))
           (list (overlay-start o) (overlay-end o))))))))

;; It follows the text: inserting at its *start*, with `front-advance'
;; nil, puts the new text inside it - the start stays and the end moves.
(test-equal "an overlay keeps text inserted at its start"
  '(1 9)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (let ((o (make-overlay 1 6)))
           (text-editor-set-cursor b 1)
           (text-editor-insert b "abc")
           (list (overlay-start o) (overlay-end o))))))))

;; and `front-advance' says the opposite: the text inserted at the start
;; goes *before* it, so both ends move
(test-equal "an overlay with front-advance moves with text at its start"
  '(4 9)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (let ((o (make-overlay 1 6 #f #t)))   ; front-advance
           (text-editor-set-cursor b 1)
           (text-editor-insert b "abc")
           (list (overlay-start o) (overlay-end o))))))))

;; and inserting at its end, with the default `rear-advance' nil, does
;; not extend it: the text goes *after* the overlay.
(test-equal "an overlay does not swallow text inserted at its end"
  '(0 5)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (let ((o (make-overlay 0 5)))
           (text-editor-set-cursor b 5)
           (text-editor-insert b "XYZ")
           (list (overlay-start o) (overlay-end o))))))))

(test-equal "overlay-put and overlay-get"
  '(bold ((face . bold)))
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello")
         (let ((o (make-overlay 0 3)))
           (overlay-put o 'face 'bold)
           (list (overlay-get o 'face) (overlay-properties o))))))))

;; `overlays-at' answers the overlays containing the character at POS -
;; and a zero-length overlay at POS is *not* one of them.
(test-equal "overlays-at, and an empty overlay is not at its own point"
  '(1 1 0)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (make-overlay 0 5)
         (make-overlay 8 8)
         (list (length (overlays-at 0))     ; the ranged overlay
               (length (overlays-at 3))     ; still the ranged one
               (length (overlays-at 8)))))))) ; the empty one is not

(test-equal "overlays-in answers the ones overlapping a region"
  '(1 0)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (make-overlay 0 5)
         (list (length (overlays-in 3 8))
               (length (overlays-in 6 9))))))))

(test-equal "next- and previous-overlay-change"
  '(5 0)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (make-overlay 0 5)
         (list (next-overlay-change 2) (previous-overlay-change 3)))))))

;; `delete-overlay' detaches it: it is in no buffer and has no ends.
(test-equal "delete-overlay leaves nothing behind"
  '(#f 0)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (let ((o (make-overlay 0 5)))
           (delete-overlay o)
           (list (overlay-start o) (length (overlays-at 0)))))))))

;; `overlays-at' with SORTED answers them by *decreasing* priority, which
;; is what the docstring says and what the redisplay merges onto.
(test-equal "overlays-at sorts by decreasing priority"
  '(3 2 1)
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (overlay-put (make-overlay 0 5) 'priority 1)
         (overlay-put (make-overlay 1 5) 'priority 3)
         (overlay-put (make-overlay 2 5) 'priority 2)
         (map (lambda (o) (overlay-get o 'priority))
              (overlays-at 3 #t)))))))

;; `get-char-property' reads the overlay *and* the text property, and the
;; overlay with the highest priority wins - which is the seam the
;; display's `face_at_buffer_position' reads.
(test-equal "get-char-property: the highest-priority overlay wins"
  'ov-face
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (overlay-put (make-overlay 1 6) 'face 'ov-face)
         (get-char-property 2 'face))))))

(test-equal "and the text property answers when no overlay has one"
  'text-face
  (with-buffers
   (lambda ()
     (let ((b (get-buffer-create "ov.txt")))
       (parameterize ((*current-buffer* b))
         (text-editor-insert b "hello world")
         (put-text-property 1 6 'face 'text-face)
         (overlay-put (make-overlay 1 6) 'priority 1)
         (get-char-property 2 'face))))))

(test-end "schemacs_editor_buffer")