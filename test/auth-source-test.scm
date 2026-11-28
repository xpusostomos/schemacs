(import
 (scheme base)
 (scheme write)
 (only (guile) setvbuf)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (srfi srfi-13) string-contains)
 (only (schemacs dispnew) current-display)
 (only (schemacs test-display) <test-display>
       test-display-script set!test-display-script)
 (only (schemacs frame)
       new-frame frame-minibuffer-window selected-window
       *current-frame* *current-buffer* *post-command-hook* *minibuffer*
       set-window-buffer!)
 (only (schemacs buffer)
       allocate-buffer get-buffer-create current-buffer with-current-buffer)
 (only (schemacs editfns) insert buffer-string)
 (only (schemacs textprop) put-text-property get-text-property)
 (only (schemacs minibuffer)
       *minibuffer-depth* minibuffer-prompt-end minibuffer-local-map
       delete-minibuffer-contents make<minibuffer> *read-hide-char*
       read-from-minibuffer *minibuffer-setup-hook*
       *enable-recursive-minibuffers*)
 (only (schemacs keymap) lookup-key)
 (only (schemacs character) kbd)
 (only (schemacs xdisp) *global-mode-string* format-mode-line)
 (only (schemacs auth-source)
       read-passwd read-passwd--password-hidden read-passwd--mode-line-icon
       read-passwd--mini-buffers read-passwd-mode read-passwd-map
       read-passwd-toggle-visibility))

;; `auth-source.el`'s `read-passwd` section - the mode-line icon, the
;; masking, the prompt's keymap, the minor mode and `read-passwd`
;; itself. The reads are driven the way the editor does it: a
;; `<test-display>` scripts the keys, `recursive-edit` reads them, and
;; every expectation about *state* (the display properties, the mode
;; line entry) is recorded by a post-command probe while the prompt is
;; up, because a prompt is over by the time the function returns.
;;
;; Emacs's own answers were measured with `emacs -Q -batch` wherever a
;; value could be asked for without a display (the map, the mask
;; string, the obsoletion record); the icon and the mode-line entry are
;; this tree's rendering and are pinned as such.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)

(define %frame (new-frame (get-buffer-create "auth-source-tests") 24 80))

;; What the post-command probe saw, most recent first: the `display`
;; and `help-echo` properties at the start of what has been typed, and
;; the mode line's rendering of `global-mode-string`.
(define %seen '())
(define (%probe)
  (when (> (*minibuffer-depth*) 0)
    (let ((b (current-buffer))
          (beg (minibuffer-prompt-end)))
      (set! %seen
            (cons (list (get-text-property beg 'display b)
                        (get-text-property beg 'help-echo b)
                        (format-mode-line 'global-mode-string))
                  %seen)))))

(define (read-with keys)
  ;; Run `read-passwd` with KEYS scripted. The probe is on the *global*
  ;; post-command hook; `read-passwd` adds its hider to the prompt
  ;; buffer's local one, and the global half runs first - so a probe
  ;; sees what the *previous* key's hide left, which is exactly what
  ;; makes the masking observable.
  (parameterize ((*current-frame* %frame) (*current-buffer* #f))
    (set! %seen '())
    (parameterize ((*post-command-hook*
                    (cons %probe (*post-command-hook*))))
      (set!test-display-script *test-display* keys)
      (read-passwd "Password: "))))

(define (seen-display char)
  (let loop ((s %seen))
    (cond ((null? s) #f)
          ((and (string? (caar s)) (string=? (caar s) char)) #t)
          (else (loop (cdr s))))))

(define (seen-no-display)
  (let loop ((s %seen))
    (cond ((null? s) #f)
          ((not (caar s)) #t)
          (else (loop (cdr s))))))

(define (every-seen-icon)
  (let loop ((s %seen))
    (cond ((null? s) (pair? %seen))
          ((string-contains (caddar s) "👁") (loop (cdr s)))
          (else #f))))

(test-begin "schemacs_auth_source")

;;------------------------------------------------------------------
;; The read itself, and the keymap's C-u and TAB.
;;------------------------------------------------------------------

(test-equal "a typed password comes back as typed" "s3cret"
  (read-with (list 115 51 99 114 101 116 13)))

;; `read-passwd-map`'s C-u is `delete-minibuffer-contents` (bug#12570):
;; "ab", C-u, "cd", RET answers "cd". It must win over
;; `minibuffer-local-map`'s `universal-argument`.
(test-equal "C-u clears the password typed so far" "cd"
  (read-with (list 97 98 21 99 100 13)))

;; TAB toggles visibility and does not enter the answer.
(let ((result (read-with (list 97 9 98 13))))
  (test-equal "TAB toggles visibility without typing anything" "ab" result)
  ;; After the TAB the password is visible again, which is the toggle's
  ;; state once the prompt has gone.
  (test-equal "the toggle left the password visible" #f
    read-passwd--password-hidden))

;; The prompt keymap: its own two bindings, and RET through the parent.
(test-equal (list delete-minibuffer-contents read-passwd-toggle-visibility
                  #t)
  (list (lookup-key read-passwd-map (kbd "C-u"))
        (lookup-key read-passwd-map (kbd "TAB"))
        (eq? (lookup-key read-passwd-map (kbd "RET"))
             (lookup-key minibuffer-local-map (kbd "RET")))))

;;------------------------------------------------------------------
;; The masking and the mode-line entry while the prompt is up
;;------------------------------------------------------------------

;; The default mask is `*`, and every hidden character carries the
;; hint. `read_hide_char` is what the mask character is.
(test-assert "typed text is masked with * and carries the hint"
  (let ((result (read-with (list 97 98 99 13))))
    (and (string=? result "abc")
         (seen-display "*")
         (every-seen-icon)
         (let loop ((s %seen))
           (cond ((null? s) #f)
                 ((equal? (cadar s)
                          "C-u: Clear password\nTAB: Toggle password visibility")
                  #t)
                 (else (loop (cdr s))))))))

;; `read-hide-char` overrides the mask, as the docstring says.
(test-assert "read-hide-char is the mask character"
  (parameterize ((*read-hide-char* #\#))
    (let ((result (read-with (list 97 98 13))))
      (and (string=? result "ab") (seen-display "#")))))

;; TAB reveals: the probe after the key that follows the TAB sees the
;; `display` property gone. (The probe runs before that key's own hide,
;; so it is TAB's effect it records.)
(test-assert "TAB removes the mask from what was typed"
  (begin
    (read-with (list 97 9 98 13))
    (and (seen-display "*") (seen-no-display))))

;; The icon is the symbol form: images are not carried here, which is
;; what Emacs on a text terminal shows too. A hidden password shows the
;; *show* icon (👁); a revealed one shows the conceal icon (⦵).
(test-assert "a hidden password's mode-line entry is the eye icon"
  (begin
    (read-with (list 97 13))
    (let* ((icon read-passwd--mode-line-icon)
           (string (if (and (pair? icon) (pair? (cdr icon))) (cadr icon) "")))
      (and (pair? icon)
           (eq? (car icon) ':propertize)
           (string-contains string "👁")))))

(test-assert "a revealed password's entry is the conceal icon"
  (begin
    (read-with (list 97 9 98 13))
    (let* ((icon read-passwd--mode-line-icon)
           (string (if (and (pair? icon) (pair? (cdr icon))) (cadr icon) "")))
      (and (pair? icon)
           (eq? (car icon) ':propertize)
           (string-contains string "⦵")))))

;; The entry is gone once the read is over, and so is the mode's own
;; buffer list.
(test-equal '(#f ())
  (list (let loop ((rest (*global-mode-string*)))
          (cond ((null? rest) #f)
                ((and (pair? (car rest)) (eq? (caar rest) ':eval)) #t)
                (else (loop (cdr rest)))))
        read-passwd--mini-buffers))

;;------------------------------------------------------------------
;; CONFIRM reads the password twice
;;------------------------------------------------------------------

(test-equal "a confirmed password is returned once" "ab"
  (parameterize ((*current-frame* %frame) (*current-buffer* #f))
    (set!test-display-script *test-display* (list 97 98 13 97 98 13))
    (read-passwd "Password: " #t)))

;;------------------------------------------------------------------
;; The mode and the toggle on their own
;;------------------------------------------------------------------
;;
;; `read-passwd-mode 1` is the public way into the state `read-passwd`
;; sets up: it pushes the prompt buffer onto `read-passwd--mini-buffers`
;; and hides the typed text. This runs it against a prompt shaped the
;; way `read_minibuf` shapes one - a real `make<minibuffer>` over the
;; buffer, because `minibuffer-prompt-end` reads `*minibuffer*` (with
;; none, it answers `point-min`, as the C's does, and the whole buffer
;; would be masked).

(let ((b (allocate-buffer))
      (mb (frame-minibuffer-window %frame)))
  (with-current-buffer b
    (insert "Password: abc")
    (put-text-property 1 11 'field #t))
  (set-window-buffer! mb b)
  (parameterize ((*minibuffer-depth* 1)
                 (*current-frame* %frame)
                 (*minibuffer* (make<minibuffer>
                                b "Password: " minibuffer-local-map
                                #f #f 0 #f))
                 (*read-hide-char* #\#))
    (with-current-buffer b
      (test-equal 11 (minibuffer-prompt-end))
      (read-passwd-mode 1)
      (test-equal "the mask is read-hide-char" "#"
                  (get-text-property 11 'display b))
      (test-equal "and the hint is on every hidden character"
                  "C-u: Clear password\nTAB: Toggle password visibility"
                  (get-text-property 13 'help-echo b))
      ;; Toggling again reveals: the display property is removed.
      (read-passwd-toggle-visibility)
      (test-equal "revealing removes the mask" #f
                  (get-text-property 11 'display b))
      (read-passwd-mode -1)
      (test-equal "the mode cleans up its buffer list" '()
                  read-passwd--mini-buffers))))

;; A toggle with no prompt up is an error, as Emacs's is.
(test-equal "No active minibuffer"
  (parameterize ((*minibuffer-depth* 0))
    (guard (e (#t (error-object-message e)))
      (read-passwd-toggle-visibility)
      #f)))

;;------------------------------------------------------------------
;; `enable-recursive-minibuffers` (`minibuf.c:641`)
;;
;; A read started while another prompt is up is a user-error unless the
;; variable says otherwise - which is why `read-passwd` binds it around
;; its own read. The setup hook is where to try it: it runs with the
;; prompt's depth already counted.
;;------------------------------------------------------------------

(test-equal "Command attempted to use minibuffer while in minibuffer"
  (let ((message #f)
        (tried #f))
    (parameterize ((*current-frame* %frame) (*current-buffer* #f))
      (set!test-display-script *test-display* (list 97 98 13))
      (parameterize ((*minibuffer-setup-hook*
                      (cons (lambda ()
                              (unless tried
                                (set! tried #t)
                                (guard (e (#t (set! message
                                                     (error-object-message e))))
                                  (read-from-minibuffer "Inner: "))))
                            (*minibuffer-setup-hook*))))
        (test-equal "the outer read still works" "ab"
          (read-from-minibuffer "Outer: "))))
    message))

;; With the variable bound, the inner prompt is read - and the two
;; answers come back in the order the prompts were answered.
(test-equal '("x" "y")
  (let ((tried #f)
        (inner #f))
    (parameterize ((*current-frame* %frame) (*current-buffer* #f)
                   (*enable-recursive-minibuffers* #t))
      (set!test-display-script *test-display* (list 120 13 121 13))
      (parameterize ((*minibuffer-setup-hook*
                      (cons (lambda ()
                              (unless tried
                                (set! tried #t)
                                (set! inner (read-from-minibuffer "Inner: "))))
                            (*minibuffer-setup-hook*))))
        (let ((outer (read-from-minibuffer "Outer: ")))
          (list inner outer))))))

(test-end "schemacs_auth_source")
