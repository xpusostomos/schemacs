;; Tests for the tooltip stack - `tooltip.el` and the help-echo half of
;; `note_mouse_highlight`.
;;
;; The chain under test is Emacs's own:
;;
;;   `note_mouse_highlight` finds `help-echo` under the pointer and calls
;;   `show_help_echo` (`keyboard.c`), which runs `show-help-function` -
;;   `tooltip-show-help`. That starts a delayed timer; when it fires,
;;   `tooltip-show` asks the display for a tip through `x-show-tip`.
;;
;; The display is a `<test-display>` with `display-show-tip` recording
;; the call, so the tooltip window itself is the one thing not exercised
;; - `pgtk-tests`' method sweep and the live Gtk check cover that half.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) setvbuf string-contains format)
 (only (oop goops) make define-class define-method)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (prefix (only (schemacs editor test-display) <test-display>) stub:)
 (only (schemacs editor dispnew) current-display display-show-tip
       display-hide-tip)
 (only (schemacs editor frame)
       *current-frame* *default-frame-alist* new-frame frame-selected-window
       window-last-mode-line window-top window-height window-body-left
       *pre-command-hook*)
 (only (schemacs editor buffer) *current-buffer* allocate-buffer set-point
       with-current-buffer set-buffer-modified-p)
 (only (schemacs editor editfns) insert message current-message)
 (only (schemacs editor xdisp) render! note-mouse-highlight clear-help-echo!
       *show-help-echo-function* *mode-line-default-help-echo*
       mode-line-default-help-echo)
 (only (schemacs editor textprop) get-text-property)
 (only (schemacs editor keyboard) *show-help-function* *help-echo-substitute-function*
       *mouse-fixup-help-message-function* show-help-echo)
 (only (schemacs editor tooltip)
       tooltip-mode tooltip-mode-variable *tooltip-delay* *tooltip-short-delay*
       *tooltip-recent-seconds* *tooltip-hide-delay* *tooltip-functions*
       tooltip-help-message tooltip-timeout-id tooltip-hide-time
       tooltip-delay tooltip-cancel-delayed-tip tooltip-start-delayed-tip
       tooltip-timeout tooltip-show tooltip-hide tooltip-show-help
       tooltip-show-help-non-mode tooltip-help-tips x-show-tip x-hide-tip
       *x-show-tooltip-timeout*)
 (only (schemacs editor faces) *window-system* face-list face-spec-recalc
       face-attribute)
 (only (schemacs editor mouse) mouse-fixup-help-message))

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_tooltip")

(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

;; The display records what a tooltip would have been shown on.
(define-class <tip-test-display> (stub:<test-display>)
  (tips #:init-value '() #:accessor test-tips)
  (hides #:init-value 0 #:accessor test-hides))

(define-method (display-show-tip (d <tip-test-display>) frame string timeout)
  (set! (test-tips d) (cons (list frame string timeout) (test-tips d)))
  #t)

(define-method (display-hide-tip (d <tip-test-display>))
  (set! (test-hides d) (+ 1 (test-hides d)))
  #t)

(define display (make <tip-test-display> #:column-width 1 #:line-height 1))
(current-display display)

(define (frame-of text)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed
      (insert text)
      (set-buffer-modified-p #f))
    (set-point ed 1)
    (parameterize ((*current-buffer* #f)) (new-frame ed 24 80))))

(define (line-of f)
  (let ((w (frame-selected-window f)))
    (values w
            (car (window-last-mode-line w))
            (+ (window-top w) (window-height w) -1))))

;;-------------------------------------
;; `show_help_echo` - `keyboard.c:2259`
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_show_help_echo")

(define shown '())
(define (record-shown help) (set! shown (cons help shown)))

(parameterize ((*show-help-function* record-shown))
  (test-equal "a string is displayed as it stands"
              '("a string")
              (begin (set! shown '())
                     (show-help-echo "a string" #f #f 1)
                     shown))
  (test-equal "a function gets the window, object and position"
              '("W:1")
              (begin (set! shown '())
                     (show-help-echo (lambda (window object pos)
                                       (format #f "~a:~a" window pos))
                                     'W 'OBJ 1)
                     shown))
  (test-equal "a form is evaluated"
              '("from a form")
              (begin (set! shown '())
                     (show-help-echo '(string-append "from " "a form")
                                     #f #f 1)
                     shown))
  (test-equal "a function that answers nil leaves the previous help"
              '("kept")
              (begin
                (set! shown '())
                (show-help-echo "kept" #f #f 1)
                (show-help-echo (lambda (w o p) #f) #f #f 1)
                (reverse shown)))
  (test-equal "nil clears"
              '(#f)
              (begin (set! shown '())
                     (show-help-echo #f #f #f #f)
                     shown)))

(test-end "schemacs_editor_tooltip_show_help_echo")

;;-------------------------------------
;; Substitution and fixup
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_seams")

(parameterize ((*show-help-function* record-shown)
               (*help-echo-substitute-function*
                (lambda (help) (string-append "SUB:" help)))
               (*mouse-fixup-help-message-function*
                (lambda (msg) (string-append "FIX:" msg))))
  (test-equal "the fixup runs before the substitution, as in the C"
              '("SUB:FIX:mouse-2: go")
              (begin (set! shown '())
                     (show-help-echo "mouse-2: go" #f #f 1)
                     shown)))

(test-equal "mouse-fixup-help-message passes a non-link string through"
            "mouse-2: visit"
            ;; On a display with no pointer `(mouse-position)` answers
            ;; nil coordinates, so the link test fails and the message is
            ;; unchanged - the C's own first guard.
            (parameterize ((*window-system* 'pgtk))
              (mouse-fixup-help-message "mouse-2: visit")))

(test-end "schemacs_editor_tooltip_seams")

;;-------------------------------------
;; The mode is installed by loading the library
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_mode")

(test-assert "tooltip-mode is on, as Emacs's :init-value has it"
             (tooltip-mode-variable))
(test-assert "show-help-function is tooltip-show-help"
             (eq? (*show-help-function*) tooltip-show-help))
(test-assert "tooltip-help-tips is on tooltip-functions"
             (memq tooltip-help-tips (*tooltip-functions*)))
(test-assert "tooltip-hide is on pre-command-hook"
             (memq tooltip-hide (*pre-command-hook*)))

(test-end "schemacs_editor_tooltip_mode")

;;-------------------------------------
;; tooltip-delay and the delayed tip
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_delay")

(define (current-second-now)
  ((@ (scheme time) current-second)))

;; `tooltip-hide` asks `(display-graphic-p)`, and the non-graphic branch
;; reads the echo area - bind the window system so the branch under test
;; is the tip's.
(parameterize ((*tooltip-delay* 0.7) (*tooltip-short-delay* 0.1)
               (*tooltip-recent-seconds* 1)
               (*window-system* 'pgtk))
  (set! tooltip-hide-time #f)
  (test-equal "the first tip waits tooltip-delay" 0.7 (tooltip-delay))
  (set! tooltip-hide-time (current-second-now))
  (test-assert "a tip soon after another waits tooltip-short-delay"
               (< (tooltip-delay) 0.7))
  (set! tooltip-hide-time #f))

(test-equal "show-help starts a one-shot timer"
            #t
            (begin
              (tooltip-cancel-delayed-tip)
              (tooltip-show-help "first")
              (and tooltip-timeout-id #t)))

(parameterize ((*window-system* 'pgtk))
  (let ((first tooltip-timeout-id))
    (tooltip-show-help "first")
    (test-assert "the same help again keeps the timer"
                 (eq? first tooltip-timeout-id))
    (tooltip-show-help "second")
    (test-assert "different help replaces the timer"
                 (not (eq? first tooltip-timeout-id)))
    (tooltip-show-help #f)
    (test-equal "nil cancels the timer" #f tooltip-timeout-id)
    (set! tooltip-help-message #f)))

(test-end "schemacs_editor_tooltip_delay")

;;-------------------------------------
;; tooltip-show through the display
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_show")

(let ((f (frame-of "abc\n")))
  (parameterize ((*current-frame* f) (*current-buffer* #f)
                 (*window-system* 'pgtk))
    (for-each face-spec-recalc (face-list))
    (set! (test-tips display) '())
    (set! (test-hides display) 0)
    (tooltip-show (string-copy "Tiptext"))
    (test-equal "tooltip-show asks the display for a tip on the selected frame"
                (list f "Tiptext" (*tooltip-hide-delay*))
                (car (test-tips display)))
    (test-assert "and the text carries the tooltip face"
                 (memq 'tooltip
                       (let ((face (get-text-property
                                    0 'face (cadr (car (test-tips display))))))
                         (if (pair? face) face (list face)))))
    (test-assert "x-hide-tip hides the tip it showed"
                 (x-hide-tip))
    (test-equal "the display was asked to hide once" 1 (test-hides display))
    (test-assert "hiding twice answers nil"
                 (not (x-hide-tip)))))

(test-equal "x-show-tip turns an empty string into a space"
            " "
            (let ((f (frame-of "abc\n")))
              (parameterize ((*current-frame* f) (*current-buffer* #f))
                (set! (test-tips display) '())
                (x-show-tip "" f)
                (cadr (car (test-tips display))))))

(test-end "schemacs_editor_tooltip_show")

;;-------------------------------------
;; The echo-area half - tooltip.el:361
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_echo")

(let ((f (frame-of "abc\n")))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (message "")
    (tooltip-show-help-non-mode "one\ntwo")
    (test-equal "a newline becomes a comma and a space"
                "one, two" (current-message))
    (tooltip-show-help-non-mode #f)
    (test-equal "nil clears the message it set"
                #f (current-message))
    (message "before")
    (tooltip-show-help-non-mode "help")
    (tooltip-show-help-non-mode #f)
    (test-equal "the message from before comes back" "before"
                (current-message))
    (message "")))

(test-end "schemacs_editor_tooltip_echo")

;;-------------------------------------
;; Hovering the mode line finds its help-echo
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_hover")

(let ((f (frame-of "abc\n")))
  (parameterize ((*current-frame* f) (*current-buffer* #f)
                 (*show-help-function* record-shown))
    (render! f)
    (call-with-values (lambda () (line-of f))
      (lambda (w line row)
        (let* ((left (window-body-left w))
               ;; A genuinely plain stretch: the mode name carries the
               ;; major-mode help-echo now (`bindings.el:600`), so the
               ;; default fallback is what a column with *no* help-echo
               ;; property shows - the spaces or the position field.
               (col (+ left
                       (let loop ((i 0))
                         (cond ((>= i (string-length line)) 0)
                               ((get-text-property i 'help-echo line)
                                (loop (+ i 1)))
                               (else i)))))
               ;; The flag characters are at the start, after the mule
               ;; information (`-UUU:`): the read-only flag is the
               ;; character after that colon.
               (flag-col (+ left (string-contains line ":") 1)))
          (set! shown '())
          (clear-help-echo!)
          (note-mouse-highlight f flag-col row)
          (test-assert "the read-only flag's function supplies the help"
                       (and (pair? shown)
                            (string? (car shown))
                            (string-contains (car shown) "Buffer is")))
          ;; A buffer-local `mode-line-default-help-echo` is what a plain
          ;; stretch of the mode line shows - the C's
          ;; `w->mode_line_help_echo` fallback.
          (parameterize ((*mode-line-default-help-echo* "DEFAULT HELP"))
            (set! shown '())
            (clear-help-echo!)
            (note-mouse-highlight f col row)
            (test-equal "a plain stretch shows the default mode-line help"
                        "DEFAULT HELP"
                        (car shown)))
          (clear-help-echo!))))))

(test-end "schemacs_editor_tooltip_hover")

;;-------------------------------------
;; The frame's default help function
;;-------------------------------------

(test-begin "schemacs_editor_tooltip_default_help")

(let ((f (frame-of "abc\n")))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let* ((w (frame-selected-window f)))
      ;; A sole selected window has nothing to select, drag, enlarge or
      ;; delete - the C answers nil, and nil must be `#f` (a `when` here
      ;; once answered the unspecified value and `concat` rejected it).
      (test-equal "a sole selected window has no default mode-line help"
                  #f
                  (mode-line-default-help-echo w)))))

(test-end "schemacs_editor_tooltip_default_help")

(test-end "schemacs_editor_tooltip")
