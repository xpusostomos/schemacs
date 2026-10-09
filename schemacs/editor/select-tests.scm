;; Tests for the window-system half of the kill ring: the cut and paste
;; functions (`interprogram-cut-function' and
;; `interprogram-paste-function'), which simple.sld's `kill-new' and
;; `current-kill' call, and the PRIMARY selection `deactivate-mark' sets
;; for `select-active-regions'.
;;
;; The keys are pressed for real, through the command loop, the way the
;; ncurses suite presses them - it was a test reaching the commands
;; directly that let the buffer-menu bugs through. The display is the
;; trick `faces-tests.scm' and the ncurses suite use - now one library,
;; `(schemacs editor test-display)': a display that draws nowhere. Here it
;; is subclassed once more, so
;; that the four selection generics of `dispnew' answer like a window
;; system's would and the clipboard is a field the test can read - and
;; write, which is how "another program cut something" is simulated.
;; The plain, unsubclassed stub is the `emacs -nw' case: its selection
;; generics are the defaults, which answer #f, and killing and yanking
;; must work all the same.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) setvbuf delete)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) make define-class define-method)
 ;; The four selection generics are imported so that the
;; `define-method's below extend *these* generics and not new ones of
;; their own - which is a silent trap: an unimported generic name makes
;; `define-method' create a fresh generic, the backend call through
;; `select.sld' still resolves to `dispnew''s, and the default method
;; answers #f with no error anywhere.
(only (schemacs editor dispnew)
      current-display get-selection set-selection!
      selection-owner? selection-exists?)
 (only (schemacs editor faces) *window-system*)
 ;; `(schemacs editor test-display)`: a display with nothing behind
 ;; it, subclassed below so that the four selection generics answer like a
 ;; window system's. (The terminal's own OSC 52 selection moved out, to
 ;; `xterm-tests.scm' beside `xterm.sld'.)
 (only (schemacs editor engine)
       new-text-editor text-editor-insert text-editor-set-cursor
       text-editor-get-cursor text-editor-to-string)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor keyboard) dispatch-input-event)
 (only (schemacs editor select)
       *select-enable-clipboard* *select-enable-primary*
       *saved-region-selection*
       *gui--last-selected-text-clipboard*
       *gui--last-selected-text-primary*
       *gui-last-cut-in-clipboard* *gui-last-cut-in-primary*
       ;; The Lisp half of a read of a selection this process owns - the
       ;; converter table `pgtk.sld''s `pgtk-get-local-selection' calls
       ;; through, and the encoder those converters use. See the
       ;; "Converting our own selection" section at the end of the file.
       *selection-converter-alist* *selection-coding-system*
       xselect--encode-string xselect--int-to-cons xselect-convert-to-string
       xselect-convert-to-targets xselect-convert-to-length
       xselect-convert-to-atom xselect-convert-to-integer
       xselect-convert-to-identity xselect-convert-to-save-targets
       xselect-convert-to-delete)
 (only (schemacs editor simple)
       *kill-ring* *kill-ring-yank-pointer*
       *kill-do-not-save-duplicates*
       *select-active-regions* *interprogram-cut-function*
       *interprogram-paste-function* deactivate-mark
       kill-new kill-append current-kill)
 (prefix (only (schemacs editor test-display) <test-display>) stub:)
 (only (schemacs editor buffer) mark-active))

(setvbuf (current-output-port) 'none)

;;--------------------------------------------------------------------
;; The display: a terminal with a clipboard
;;--------------------------------------------------------------------

(define-class <clipboard-tty> (stub:<test-display>)
  ;; The two selections that matter, held the way a window system's
  ;; backend holds them: the text, and whether this process owns it.
  (clipboard #:init-value #f #:accessor stub-clipboard)
  (primary   #:init-value #f #:accessor stub-primary)
  (owned     #:init-value '() #:accessor stub-owned))

(define-method (set-selection! (d <clipboard-tty>) selection value)
  ;; Assert SELECTION holding VALUE, or - VALUE #f - disown it, which is
  ;; "there is no such selection".
  ;;--------------------------------------------------------------
  (if value
      (begin
        (if (eq? selection 'CLIPBOARD)
            (set! (stub-clipboard d) value)
            (set! (stub-primary d) value))
        (set! (stub-owned d)
              (cons selection (delete selection (stub-owned d)))))
      (set! (stub-owned d) (delete selection (stub-owned d)))))

(define-method (get-selection (d <clipboard-tty>) selection target-type)
  ;; The recorded text; #f for a question about a timestamp, which Gtk's
  ;; clipboard cannot answer either.
  ;;--------------------------------------------------------------
  (if (eq? target-type 'TIMESTAMP)
      #f
      (if (eq? selection 'CLIPBOARD)
          (stub-clipboard d)
          (stub-primary d))))

(define-method (selection-owner? (d <clipboard-tty>) selection)
  (and (memq selection (stub-owned d)) #t))

(define-method (selection-exists? (d <clipboard-tty>) selection)
  (or (memq selection (stub-owned d))
      (and (get-selection d selection 'STRING) #t)))

;; Another program's cut: it reaches the clipboard the way an outside
;; program's does, through the backend and not through `gui-select-text',
;; so the last-seen bookkeeping is not updated and the next `C-y' sees
;; the clipboard as new.
(define (stub-cut! d text)
  (set-selection! d 'CLIPBOARD text))

;;--------------------------------------------------------------------
;; The harness
;;--------------------------------------------------------------------

(define (with-editor text thunk)
  ;; A frame over TEXT with a clipboard display, and the kill-ring and
  ;; selection state bound fresh, so one test's cuts do not leak into
  ;; the next.
  ;;--------------------------------------------------------------
  (let* ((ed (new-text-editor))
         (frame (new-frame ed 24 80))
         (d (make <clipboard-tty>)))
    (parameterize ((current-display d)
                   (*current-frame* frame)
                   ;; The stub display stands for a window system's
                   ;; backend, which is what a pgtk frame has: the
                   ;; tests here are the pgtk behaviour, and
                   ;; `display-selections-p' and the newness checks ask
                   ;; `*window-system*'.
                   (*window-system* 'pgtk)
                   (*kill-ring* '())
                   (*kill-ring-yank-pointer* '())
                   (*select-enable-clipboard* #t)
                   (*select-enable-primary* #f)
                   (*select-active-regions* #t)
                   (*saved-region-selection* #f)
                   (*gui--last-selected-text-clipboard* #f)
                   (*gui--last-selected-text-primary* #f)
                   (*gui-last-cut-in-clipboard* #f)
                   (*gui-last-cut-in-primary* #f))
      (text-editor-insert ed text)
      (text-editor-set-cursor ed 0)
      (thunk frame ed d))))

;; The plain terminal: no selections behind it, which is `emacs -nw'.
(define (with-tty text thunk)
  (let* ((ed (new-text-editor))
         (frame (new-frame ed 24 80)))
    (parameterize ((current-display (make stub:<test-display>))
                   (*current-frame* frame)
                   (*kill-ring* '())
                   (*kill-ring-yank-pointer* '())
                   (*saved-region-selection* #f)
                   (*gui--last-selected-text-clipboard* #f)
                   (*gui-last-cut-in-clipboard* #f))
      (text-editor-insert ed text)
      (text-editor-set-cursor ed 0)
      (thunk frame ed))))

(define (keys! frame . evs)
  (for-each (lambda (ev) (dispatch-input-event frame ev)) evs))

(define C-SPC #\nul)          ; C-SPC and C-@ are the same byte
(define C-e (integer->char 5))
(define C-w (integer->char 23))
(define C-y (integer->char 25))
;; M-w is two key events - ESC then the letter.
(define (M-w! frame) (keys! frame #\esc #\w))

;; The ring, as the tests read it: the front of the ring is what `C-y'
;; would insert, and #f when nothing has been killed yet - Elisp's
;; `(car nil)'.
(define (latest-kill)
  (if (pair? (*kill-ring*)) (car (*kill-ring*)) #f))

(test-begin "schemacs_editor_select")

;;--------------------------------------------------------------------
;; Cutting
;;------------------------------------------------------------------

;; M-w puts the region on the clipboard: `kill-ring-save' -> `kill-new'
;; -> `interprogram-cut-function' -> `gui-select-text' -> the backend.
(test-equal "hello"
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC)
      (text-editor-set-cursor ed 6)
      (M-w! frame)
      (stub-clipboard d))))

;; So does C-w, which also takes the text out of the buffer.
(test-equal '("" "hello world")
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (list (text-editor-to-string ed) (stub-clipboard d)))))

;; `select-enable-primary' is off, so M-w does not touch PRIMARY -
;; which is Emacs's default, not a bug.
(test-equal #f
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC)
      (text-editor-set-cursor ed 6)
      (M-w! frame)
      (stub-primary d))))

;; On a plain terminal the selection functions are no-ops, and the kill
;; still happens: `emacs -nw' keeps its kills in the ring.
(test-equal '("" "hello world")
  (with-tty "hello world"
    (lambda (frame ed)
      (keys! frame C-SPC C-e C-w)
      (list (text-editor-to-string ed) (latest-kill)))))

;;--------------------------------------------------------------------
;; Yanking
;;------------------------------------------------------------------

;; C-y after an Emacs cut yanks the kill, and does NOT pull the
;; clipboard in as a new kill: the clipboard is Emacs's own, unchanged
;; since the cut, which `gui--clipboard-selection-unchanged-p' sees.
(test-equal '("hello world" "hello world")
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (keys! frame C-y)
      (list (text-editor-to-string ed) (latest-kill)))))

;; Text another program cut is new, and C-y takes it - and it becomes
;; the latest kill, as `current-kill' adds it to the ring.
(test-equal '("from elsewhere" "from elsewhere")
  (with-editor "hello"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (stub-cut! d "from elsewhere")
      (keys! frame C-y)
      (list (text-editor-to-string ed) (latest-kill)))))

;; and the pulled text is in the ring *proper*, so `M-y' can walk to the
;; older kill behind it.
(test-equal '("hello" 2)
  (with-editor "hello"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (stub-cut! d "from elsewhere")
      (keys! frame C-y)
      (let ((ring (*kill-ring*)))
        ;; the front is the pull; the one behind it is the old kill
        (list (car (reverse ring)) (length ring))))))

;; An unchanged clipboard is not added again: the second C-y inserts the
;; same text and the ring does not grow.
(test-equal '("from elsewherefrom elsewhere" 2)
  (with-editor "hello"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (stub-cut! d "from elsewhere")
      (keys! frame C-y)
      (keys! frame C-y)
      (list (text-editor-to-string ed) (length (*kill-ring*))))))

;; A *changed* clipboard is taken again: cutting in the other program
;; between two C-y's means the second C-y takes the new text - and C-y
;; inserts again where the first one left point, which is why the buffer
;; holds both.
(test-equal '("firstsecond" "second")
  (with-editor "hello"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (stub-cut! d "first")
      (keys! frame C-y)
      (stub-cut! d "second")
      (keys! frame C-y)
      (list (text-editor-to-string ed) (latest-kill)))))

;;--------------------------------------------------------------------
;; The primary selection
;;------------------------------------------------------------------

;; Deactivating an active, non-empty region puts the region in PRIMARY,
;; which is `select-active-regions' being on: another program sees the
;; selection without a kill having happened.
(test-equal "selected text"
  (with-editor "selected text here"
    (lambda (frame ed d)
      (keys! frame C-SPC)
      (text-editor-set-cursor ed 14)
      (deactivate-mark)
      (stub-primary d))))

;; The saved-region branch: a kill has saved the region text, and the
;; deactivate that the command loop applies after the command sets
;; PRIMARY to it - but only when Emacs already owns PRIMARY, which it
;; does not here (the kill went to the clipboard). So PRIMARY is left
;; alone: Bug#16382's rule that a cut does not reset PRIMARY.
(test-equal #f
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (stub-primary d))))

;; and the saved text is spent once used - the C command loop clears
;; `saved-region-selection' after every command.
(test-equal #f
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC C-e C-w)
      (*saved-region-selection*))))

;; On a plain terminal `display-selections-p' is false, so deactivating
;; an active region does not try to set PRIMARY at all - and the mark
;; still goes inactive, the rest of `deactivate-mark' running all the
;; same.
(test-equal #f
  (with-tty "hello world"
    (lambda (frame ed)
      (keys! frame C-SPC)
      (text-editor-set-cursor ed 6)
      (deactivate-mark)
      (mark-active))))

;;--------------------------------------------------------------------
;; The empty kill ring
;;------------------------------------------------------------------

;; Yanking from an empty ring signals, exactly as `current-kill''s
;; `(or kill-ring (error "Kill ring is empty"))' does - which never
;; fired here while `'()' counted as true, and the `modulo' under it
;; divided by zero instead.
(test-assert "empty ring yank signals"
  (with-editor "hello"
    (lambda (frame ed d)
      (guard (e (#t #t))
        (parameterize ((*interprogram-paste-function* #f))
          (current-kill 0))
        #f))))

;; `kill-new' onto an empty ring with `kill-do-not-save-duplicates' on
;; works: Elisp's `(equal string (car kill-ring))' reads `(car nil)' as
;; nil and so does not skip the entry - Scheme's `(car '())' signalled.
(test-equal "first kill"
  (with-editor "hello"
    (lambda (frame ed d)
      (parameterize ((*kill-do-not-save-duplicates* #t))
        (kill-new "first kill"))
      (latest-kill))))

;; and `kill-append' onto an empty ring appends nothing: Elisp's `cur'
;; is nil then, and `(concat nil s)' is s.
(test-equal "appended"
  (with-editor "hello"
    (lambda (frame ed d)
      (parameterize ((*kill-do-not-save-duplicates* #t))
        (kill-append "appended" #f))
      (latest-kill))))

;;--------------------------------------------------------------------
;; Converting our own selection - `selection-converter-alist'
;;
;; The table `pgtk.sld''s `pgtk-get-local-selection' looks a requested
;; target up in, and the encoder its handlers use. **Everything here is
;; Emacs 31.1's own answer**, measured in `emacs -Q --batch' - and the
;; measurements are what corrected two expectations: a *unibyte* string
;; literal in batch takes the C_STRING branch of the TEXT polymorphism
;; and a multibyte one does not, so the numbers below are the multibyte
;; ones (`string-to-multibyte'), which is what every string is here.
;;------------------------------------------------------------------

;; `xselect--int-to-cons' (`select.el:576'): a number as the two 16-bit
;; halves the protocol carries it in.
(test-equal '(0 . 11) (xselect--int-to-cons 11))
(test-equal '(1 . 0) (xselect--int-to-cons 65536))

;; **The local path is the first line of `xselect--encode-string'**: the
;; C passes a nil TYPE for a request from this process, and then the
;; string is answered as it stands with no coding system involved. Every
;; call this tree makes arrives here.
(test-equal "hello" (xselect--encode-string #f "hello" #t #f))

;; `TEXT' is polymorphic, and the choice is made from the string's own
;; characters - Emacs's `(when (eq type 'TEXT) ...)'. Anything that fits
;; Latin-1 is STRING; a character past #x100 makes it UTF8_STRING.
(test-equal '(STRING . #vu8(97 98 99))
  (xselect--encode-string 'TEXT "abc" #t #f))
(test-equal '(STRING . #vu8(99 97 102 233))
  (xselect--encode-string 'TEXT "café" #t #f))
(test-equal '(UTF8_STRING . #vu8(115 110 226 152 131 119))
  (xselect--encode-string 'TEXT "sn☃w" #t #f))

;; A named type encodes with *its* coding system: UTF8_STRING is utf-8,
;; STRING is iso-latin-1 - which is what makes the two bytevectors above
;; differ.
(test-equal '(UTF8_STRING . #vu8(115 110 226 152 131 119))
  (xselect--encode-string 'UTF8_STRING "sn☃w" #t #f))
(test-equal '(STRING . #vu8(99 97 102 233))
  (xselect--encode-string 'STRING "café" #t #f))

;; "Most programs are unable to handle NUL bytes in strings", so a NUL is
;; written out as the two characters backslash and `0'.
(test-equal '(STRING . #vu8(97 92 48 98))
  (xselect--encode-string 'STRING (string #\a #\nul #\b) #t #f))

;; A type with no coding system here answers an error rather than
;; something made up - COMPOUND_TEXT is `compound-text-with-extensions',
;; which is the ISO-2022 family this tree does not carry.
(test-assert "an unencodable type signals rather than guessing"
  (guard (e (#t #t))
    (xselect--encode-string 'COMPOUND_TEXT "hello" #t #f)
    #f))

;; The table itself: the target symbols the C looks up by `eq?', and one
;; handler each. These are `select.el:903''s entries for the type-of-data
;; targets; the legacy ICCCM ones (`OWNER_OS', `HOST_NAME', `USER',
;; `FILE_NAME', `CHARACTER_POSITION', `LINE_NUMBER', `COLUMN_NUMBER') and
;; the DnD ones are absent, with the reason on each in `select.sld'.
(test-equal '(#t #t #t #t #t)
  (let ((alist (*selection-converter-alist*)))
    (list (and (procedure? (assq-ref alist 'STRING)) #t)
          (and (procedure? (assq-ref alist 'UTF8_STRING)) #t)
          (and (procedure? (assq-ref alist 'TARGETS)) #t)
          (and (procedure? (assq-ref alist 'SAVE_TARGETS)) #t)
          ;; **TIMESTAMP is not in the table at all**: it is the C's
          ;; special case and never reaches a converter.
          (not (assq 'TIMESTAMP alist)))))

;; The converters themselves, driven directly - the C calls them with
;; `(SELECTION TYPE VALUE)'.
(test-equal '(0 . 5) (xselect-convert-to-length #f #f "hello"))
(test-equal 'foo (xselect-convert-to-atom #f #f 'foo))
(test-equal #f (xselect-convert-to-atom #f #f "foo"))
(test-equal '(0 . 300) (xselect-convert-to-integer #f #f 300))
(test-equal #f (xselect-convert-to-integer #f #f "x"))
(test-equal '#("foo") (xselect-convert-to-identity #f #f "foo"))
(test-equal 'NULL (xselect-convert-to-save-targets 'CLIPBOARD #f "x"))
(test-equal #f (xselect-convert-to-save-targets 'PRIMARY #f "x"))

;; `xselect-convert-to-string' wants a *string*: a symbol value answers
;; the ATOM target and nil here, which is what makes the two targets
;; differ for one value.
(test-equal #f (xselect-convert-to-string #f #f 'foo))
(test-equal "hello" (xselect-convert-to-string #f #f "hello"))

;; TARGETS leads with TIMESTAMP and MULTIPLE, which are not converters but
;; the C's own, and then names every handler in the table.
(test-equal '(#t #t #t)
  (let* ((v (xselect-convert-to-targets 'CLIPBOARD #f "x"))
         (l (vector->list v)))
    (list (vector? v)
          (equal? (list-head l 2) '(TIMESTAMP MULTIPLE))
          (and (memq 'STRING l) (memq 'TARGETS l) #t))))

;; **`DELETE' acts and answers `NULL'**: "A return value of nil means that
;; we do not know how to do this conversion, and replies with an error. A
;; return value of NULL means that we have done the conversion (and any
;; side-effects) but have no value to return." The side effect is giving
;; the selection up, which on this stub display means disowning it.
(test-equal '(NULL #f)
  (with-editor "hello world"
    (lambda (frame ed d)
      (keys! frame C-SPC)
      (text-editor-set-cursor ed 6)
      (M-w! frame)
      (let ((answer (xselect-convert-to-delete 'CLIPBOARD #f "x")))
        (list answer (stub-clipboard d))))))

;; **The `test-end` is not decoration.** `tools/run-suites.py' counts a
;; suite as run only when it prints "*** Test suite finished", so a file
;; that begins a group and never ends it is reported as DID NOT RUN with
;; every test passing - which is exactly how this one read while its
;; `test-end' was sitting at the end of `xterm-tests.scm', where the
;; split had moved it.
(test-end "schemacs_editor_select")