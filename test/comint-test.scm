(import
 (scheme base)
 (scheme write)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (srfi srfi-13) string-contains)
 (only (guile) setvbuf)
 (only (schemacs dispnew) current-display)
 (only (schemacs test-display) <test-display>
       test-display-script set!test-display-script)
 (only (schemacs frame) *current-frame* *current-buffer* new-frame
       selected-window window-body-width)
 (only (schemacs buffer)
       allocate-buffer get-buffer-create buffer-name with-current-buffer
       current-buffer major-mode erase-buffer)
 (only (schemacs editfns) point point-min goto-char point-max insert buffer-string
       buffer-substring delete-region save-excursion)
 (only (schemacs search) search-forward)
 (only (schemacs comint)
       make-comint comint-mode comint-check-proc comint-send-input
       comint-previous-input comint-input-ring comint-next-prompt
       comint-arguments comint-args comint-delim-arg comint-within-quotes
       comint-insert-previous-argument comint-accumulate
       comint-accum-marker comint-goto-process-mark
       comint-bol-or-process-mark comint-set-process-mark
       comint-line-beginning-position
       comint-extract-string comint-source-default
       comint-kill-whole-line comint-kill-region comint-proc-query
       comint-read-noecho comint-send-invisible comint-password-function
       set!comint-password-function comint-watch-for-password-prompt
       comint-postoutput-scroll-to-bottom
       *comint-output-filter-functions*
       *comint-delimiter-argument-list* *comint-input-autoexpand*)
 (only (schemacs core ring) ring-length ring-ref)
 (only (schemacs process) get-buffer-process accept-process-output
       process-status process-mark delete-process)
 (only (schemacs textprop) get-char-property)
 (only (schemacs marker) marker-position)
 (only (schemacs keyboard) timer-check!)
 (only (schemacs core timer) timer-next-delay)
 (only (schemacs symbol-props) get)
 (only (schemacs simple) *last-command* *this-command* current-kill)
 (only (schemacs files) default-directory))

;; `comint.scm`, tranches 1 and 2. Every expectation is Emacs 31.1's
;; own: the argument-splitting rows were measured with
;; `emacs -Q --batch -l /tmp/comint-meas.el' on the same strings, and
;; the shell tests run the same `/bin/sh' pty a user would.
;;
;; A comint buffer needs a frame - `comint-term-environment' asks the
;; selected window for its width, as Emacs's `(window-width)' does - so
;; the suite makes one, as every frame-using suite here does.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)

(define frame (new-frame (get-buffer-create "comint-tests") 24 80))

(define (buffer-text buffer)
  (with-current-buffer buffer (buffer-string)))

(define (wait-for buffer text)
  ;; Drain the process until BUFFER's text contains TEXT, or give up
  ;; after about three seconds.
  (let ((proc (get-buffer-process buffer)))
    (let loop ((n 0))
      (cond ((not proc) #f)
            ((string-contains (buffer-text buffer) text) #t)
            ((>= n 60) #f)
            (else (accept-process-output proc 0.05)
                  (loop (+ n 1)))))))

(test-begin "schemacs_editor_comint")

;;------------------------------------------------------------------
;; The argument helpers (`comint.el:1761'-`:1897'): every row measured
;; on Emacs 31.1.
;;------------------------------------------------------------------

(test-equal "ls -l \"a b\"" (comint-arguments "ls -l \"a b\" c" 0 2))
(test-equal "-l x" (comint-arguments "ls -l x" 1 #f))
(test-equal "b" (comint-arguments "a  b" #f #f))
(test-equal "a : b c"
            (parameterize ((*comint-delimiter-argument-list* (list #\:)))
              (comint-arguments "a:b c" 0 3)))
(test-equal '("y" ":" "x")
            (parameterize ((*comint-delimiter-argument-list* (list #\:)))
              (comint-delim-arg "x:y")))

;; `comint-within-quotes': "a 'b c' d" has two quotes over 1..9 (even)
;; and one over 1..4 (odd), which Emacs answers nil and t.
(with-current-buffer (get-buffer-create " *comint-quotes*")
  (erase-buffer)
  (insert "a 'b c' d")
  (test-equal #f (comint-within-quotes 1 9))
  (test-equal #t (comint-within-quotes 1 4)))

;; `comint-args' reads a range from the buffer: "1-2" asks for args 1..2
;; of "cmd a b c", which Emacs answers "a b".
(with-current-buffer (get-buffer-create " *comint-args*")
  (erase-buffer)
  (insert "zz 1-2")
  (test-equal "a b" (comint-args "cmd a b c" 4 7)))

;;------------------------------------------------------------------
;; The shell: a `/bin/sh' in a comint buffer.
;;------------------------------------------------------------------

(parameterize ((*current-frame* frame)
               (*current-buffer* #f))
  (let ((buffer (make-comint "schemacs-comint-test" "/bin/sh")))
    (test-equal "*schemacs-comint-test*" (buffer-name buffer))
    (with-current-buffer buffer
      (test-assert (eq? (major-mode) 'comint-mode))
      (test-assert (comint-check-proc buffer))
      (test-assert (eq? (process-status (get-buffer-process buffer)) 'run))
      (test-equal 0 (ring-length (comint-input-ring))))
    ;; One command: RET sends it, the pty echoes it, the shell prints.
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "echo CMU-$((6*7))")
      (comint-send-input))
    (test-assert (wait-for buffer "CMU-42"))
    (with-current-buffer buffer
      ;; the input is in the history ring
      (test-equal 1 (ring-length (comint-input-ring)))
      (test-equal "echo CMU-$((6*7))" (ring-ref (comint-input-ring) 0)))
    ;; C-p brings it back into the input area.
    (with-current-buffer buffer
      (goto-char (point-max))
      (comint-previous-input 1)
      (test-equal "echo CMU-$((6*7))"
                  (buffer-substring
                   (process-mark (get-buffer-process buffer))
                   (point))))
    ;; A history reference: with `comint-input-autoexpand' set to
    ;; `input' (Emacs's default is nil, which leaves `!!' literal),
    ;; `!!' expands to the previous command.
    (with-current-buffer buffer
      (erase-buffer)
      (goto-char (point-max))
      (insert "!!")
      (parameterize ((*comint-input-autoexpand* 'input))
        (comint-send-input)))
    (test-assert (wait-for buffer "CMU-42"))
    (with-current-buffer buffer
      (test-equal 2 (ring-length (comint-input-ring)))
      (test-equal "echo CMU-$((6*7))" (ring-ref (comint-input-ring) 0)))
    ;; `comint-next-prompt' walks the `field' property changes and stops
    ;; at the beginning of an *input* field - a run of nil `field'
    ;; property after an `output' run (`comint.el:2857`). Asserting the
    ;; rule (nil at point, output just before it) rather than a position,
    ;; since where the first such run is depends on the shell's output.
    (with-current-buffer buffer
      (goto-char (point-min))
      (comint-next-prompt 1)
      (test-equal #f (get-char-property (point) 'field))
      (test-equal 'output (get-char-property (- (point) 1) 'field)))
    ;; `comint-proc-query` sends its string and waits for the answer;
    ;; the output must reach the process buffer.  The input ring is not
    ;; touched - the string goes straight to the process.
    (comint-proc-query (get-buffer-process buffer) "echo CPQ-7\n")
    (test-assert "comint-proc-query's answer arrives" (wait-for buffer "CPQ-7"))
    (with-current-buffer buffer
      (test-equal "the ring still holds the two typed commands" 2
                  (ring-length (comint-input-ring))))
    (delete-process (get-buffer-process buffer))))

;;------------------------------------------------------------------
;; The read-only prompt's kill commands (`comint.el:2992', `:3006').
;; Every expectation is Emacs 31.1's on the same buffer and point.
;;------------------------------------------------------------------

(with-current-buffer (get-buffer-create " *comint-kill*")
  (erase-buffer)
  (insert "aa\nbb\ncc")
  (comint-mode)
  (goto-char 4)
  (parameterize ((*last-command* 'ignore))
    (comint-kill-whole-line 1))
  (test-equal "comint-kill-whole-line kills the line and its newline"
              "aa\ncc" (buffer-string))
  (test-equal "and leaves point at the kill's start" 4 (point))
  (test-equal "with the line on the ring" "bb\n" (current-kill 0)))

(with-current-buffer (get-buffer-create " *comint-kill-region*")
  (erase-buffer)
  (insert "aa\nbb\ncc")
  (comint-mode)
  (parameterize ((*last-command* 'ignore))
    (comint-kill-region 3 7))
  (test-equal "comint-kill-region kills the region" "aacc" (buffer-string))
  (test-equal "and point follows the deletion" 5 (point))
  (test-equal "with the region on the ring" "\nbb\n" (current-kill 0)))

;;------------------------------------------------------------------
;; The remaining history and process commands
;; (`comint.el:2902', `:3597'-`:3670').
;;
;; Every expectation below is Emacs 31.1's own on the same `/bin/sh'.
;; The commands are called with `*last-command*` and `*this-command*`
;; bound the way the command loop binds them: `comint-insert-previous-
;; argument` compares the two to tell a repeat invocation, and
;; `comint-bol-or-process-mark` compares `last-command` with itself.
(parameterize ((*current-frame* frame)
               (*current-buffer* #f))
  (let ((buffer (make-comint "schemacs-comint-cmds" "/bin/sh")))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "echo IPA-$((6*7)) two")
      (comint-send-input))
    (test-assert (wait-for buffer "IPA-42 two"))
    ;; No prefix: the last argument of the previous command.
    (with-current-buffer buffer
      (goto-char (point-max))
      (parameterize ((*last-command* 'a-different-command)
                     (*this-command* comint-insert-previous-argument))
        (comint-insert-previous-argument #f))
      (test-equal "two"
                  (buffer-substring
                   (process-mark (get-buffer-process buffer))
                   (point))))
    ;; An immediate repeat deletes what it inserted and inserts again.
    (with-current-buffer buffer
      (parameterize ((*last-command* comint-insert-previous-argument)
                     (*this-command* comint-insert-previous-argument))
        (comint-insert-previous-argument #f))
      (test-equal "two"
                  (buffer-substring
                   (process-mark (get-buffer-process buffer))
                   (point))))
    ;; `comint-accumulate` joins lines, and the pair becomes *one*
    ;; history item. Emacs leaves the accumulation marker at the start
    ;; of the line it opened - the process mark plus the first line and
    ;; its newline.
    (with-current-buffer buffer
      (delete-region (process-mark (get-buffer-process buffer)) (point-max))
      (goto-char (point-max))
      (insert "echo A-$((6*7))")
      (comint-accumulate)
      (insert "echo B-$((6*7))")
      (test-equal "echo A-$((6*7))\necho B-$((6*7))"
                  (buffer-substring
                   (process-mark (get-buffer-process buffer))
                   (point-max)))
      (test-equal (+ (marker-position (process-mark (get-buffer-process buffer)))
                     (string-length "echo A-$((6*7))\n"))
                  (marker-position (comint-accum-marker))))
    (with-current-buffer buffer
      (comint-send-input))
    (test-assert (wait-for buffer "A-42"))
    (test-assert (wait-for buffer "B-42"))
    (with-current-buffer buffer
      (test-equal "echo A-$((6*7))\necho B-$((6*7))"
                  (ring-ref (comint-input-ring) 0))
      (test-equal 2 (ring-length (comint-input-ring))))
    ;; `comint-bol-or-process-mark`: from output text the first
    ;; invocation goes to the line's beginning (the field machinery's
    ;; rule, which is `comint-line-beginning-position`), an immediate
    ;; repeat to the process mark. Measured on Emacs 31.1 from the
    ;; `IPA-42` line: 23, then the process mark.
    (with-current-buffer buffer
      (goto-char (point-min))
      (search-forward "IPA-42")
      (let ((linebeg (save-excursion (comint-line-beginning-position))))
        (parameterize ((*last-command* 'a-different-command))
          (comint-bol-or-process-mark))
        (test-equal linebeg (point)))
      (parameterize ((*last-command* comint-bol-or-process-mark))
        (comint-bol-or-process-mark))
      (test-equal (marker-position (process-mark (get-buffer-process buffer)))
                  (point)))
    ;; `comint-set-process-mark` moves the process mark to point, and
    ;; `comint-goto-process-mark` moves point to the process mark.
    (with-current-buffer buffer
      (goto-char (point-min))
      (comint-set-process-mark)
      (test-equal (point)
                  (marker-position (process-mark (get-buffer-process buffer))))
      (goto-char (point-max))
      (comint-goto-process-mark)
      (test-equal (marker-position (process-mark (get-buffer-process buffer)))
                  (point)))
    (delete-process (get-buffer-process buffer))))

;;------------------------------------------------------------------
;; The source-file defaults and prompts (`comint.el:3068'-`:3160').
;;
;; `comint-get-source` itself prompts, so the two pure helpers are what
;; is measured here; every expectation is Emacs 31.1's own.
(parameterize ((*current-frame* frame) (*current-buffer* #f))
  (with-current-buffer (get-buffer-create " *comint-source*")
    (erase-buffer)
    (insert "(foo \"bar\" baz)")
    (goto-char 8)
    (test-equal "a string at point is the source default" "bar"
                (comint-extract-string))
    (goto-char 2)
    (test-equal "and no string at point is nil" #f (comint-extract-string))
    ;; The previous command's pair is the answer when the buffer is not
    ;; a source buffer.
    (test-equal '("/x/" . "f")
                (comint-source-default (cons "/x/" "f") '(fundamental-mode)))
    ;; With nothing remembered it is the default directory alone - a
    ;; one-element list in Emacs, i.e. a cons whose cdr is nil.
    (let ((default (comint-source-default #f '(fundamental-mode))))
      (test-equal (default-directory) (car default))
      (test-equal #f (cdr default)))))

;;------------------------------------------------------------------
;; The password commands (`comint.el:2550'-`:2629`)
;;
;; `read-passwd` is what they read through, and the reads here are
;; driven the way the editor drives them: a scripted test display and a
;; frame. A real `sh` with `stty -echo` is the other end, so the
;; password is checked where it arrives - a comint buffer's process.
;;------------------------------------------------------------------

;; `comint-read-noecho` is obsolete since 28.1 in favour of
;; `read-passwd' (`(declare (obsolete read-passwd "28.1"))').
(test-equal '(read-passwd #f "28.1")
  (get 'comint-read-noecho 'byte-obsolete-info))

;; ... and it really does read through it.
(parameterize ((*current-frame* frame) (*current-buffer* #f))
  (set!test-display-script *test-display* (list 111 108 100 13))
  (test-equal "comint-read-noecho reads through read-passwd" "old"
    (comint-read-noecho "Old password: ")))

;; `comint-password-function` is a buffer-local variable.
(with-current-buffer (get-buffer-create " *comint-password-function*")
  (set!comint-password-function (lambda (prompt) "fn"))
  (test-equal '("fn is a procedure" #f)
    (list (if (procedure? (comint-password-function)) "fn is a procedure" #f)
          (begin (set!comint-password-function #f)
                 (comint-password-function)))))

;; `comint-send-invisible` reads a line without echo and sends it. The
;; shell turns its own echo off, so the only place the password appears
;; in the buffer is the line the shell prints.
(parameterize ((*current-frame* frame) (*current-buffer* #f)
               ;; **Without the watching filter here:** the shell's
               ;; prompt would arm `comint-watch-for-password-prompt`'s
               ;; zero-delay timer, and the prompt's own read would fire
               ;; it - the timer's read would then take the keys scripted
               ;; for the direct call.
               (*comint-output-filter-functions*
                (list comint-postoutput-scroll-to-bottom)))
  (let ((buffer (make-comint
                 "schemacs-comint-pw" "/bin/sh" #f "-c"
                 "stty -echo; printf 'Password: '; IFS= read -r x; printf 'GOTP:%s\n' \"$x\"")))
    (test-assert "the shell asks for a password" (wait-for buffer "Password:"))
    (set!test-display-script *test-display* (list 115 51 99 13))
    (with-current-buffer buffer
      (comint-send-invisible "Password: "))
    (test-assert "comint-send-invisible sent it" (wait-for buffer "GOTP:s3c"))
    (let ((proc (get-buffer-process buffer)))
      ;; The shell exits as soon as it answers, and `get-buffer-process`
      ;; answers nil once the sentinel has run - while `delete-process`
      ;; accepts a dead *process object*. Nothing to do when it is gone.
      (when proc (delete-process proc)))))

;; A buffer's `comint-password-function` answers instead of the
;; minibuffer: the scripted key is a canary that must not be read.
(parameterize ((*current-frame* frame) (*current-buffer* #f)
               (*comint-output-filter-functions*
                (list comint-postoutput-scroll-to-bottom)))
  (let ((buffer (make-comint
                 "schemacs-comint-pwfn" "/bin/sh" #f "-c"
                 "stty -echo; printf 'Password: '; IFS= read -r x; printf 'GOTF:%s\n' \"$x\"")))
    (test-assert "the shell asks for a password" (wait-for buffer "Password:"))
    (set!test-display-script *test-display* (list 106 13))
    (with-current-buffer buffer
      (set!comint-password-function (lambda (prompt) "fnsecret"))
      (comint-send-invisible "Password: "))
    (test-assert "the password function's answer was sent"
                 (wait-for buffer "GOTF:fnsecret"))
    (let ((proc (get-buffer-process buffer)))
      ;; The shell exits as soon as it answers, and `get-buffer-process`
      ;; answers nil once the sentinel has run - while `delete-process`
      ;; accepts a dead *process object*. Nothing to do when it is gone.
      (when proc (delete-process proc)))))

;; **The output filter asks by itself.** `comint-output-filter-functions`
;; carries `comint-watch-for-password-prompt` by default, and a prompt in
;; the process's output arms a zero-delay timer that prompts from the
;; minibuffer - out of the filter, so the filter is not paused while a
;; password is typed. `timer-check!` is what the command loop would call.
(parameterize ((*current-frame* frame) (*current-buffer* #f))
  (let ((buffer (make-comint
                 "schemacs-comint-watch" "/bin/sh" #f "-c"
                 "stty -echo; printf 'Password: '; IFS= read -r x; printf 'GOTW:%s\n' \"$x\"")))
    (test-assert "the shell asks for a password" (wait-for buffer "Password:"))
    (test-assert "the prompt armed a timer" (timer-next-delay))
    (set!test-display-script *test-display* (list 119 13))
    (timer-check!)
    (test-assert "the watched prompt sent the password"
                 (wait-for buffer "GOTW:w"))
    (let ((proc (get-buffer-process buffer)))
      ;; The shell exits as soon as it answers, and `get-buffer-process`
      ;; answers nil once the sentinel has run - while `delete-process`
      ;; accepts a dead *process object*. Nothing to do when it is gone.
      (when proc (delete-process proc)))))

(test-end "schemacs_editor_comint")
