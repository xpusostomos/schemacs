(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor frame) *current-frame* new-frame selected-window
       window-parameter window-list)
 (only (schemacs editor buffer)
       allocate-buffer buffer-local-value buffer-name current-buffer
       get-buffer-create set-buffer set-buffer-local-value!
       with-current-buffer)
 (only (schemacs editor window) switch-to-buffer)
 (only (schemacs editor editfns) insert)
 (only (schemacs editor textprop) get-text-property)
 (only (schemacs editor subr) *after-change-major-mode-hook* run-hooks)
 (only (schemacs editor tab-line)
       tab-line-mode tab-line-mode-variable global-tab-line-mode
       global-tab-line-mode-variable tab-line-format
       tab-line-tabs-window-buffers tab-line-tabs-fixed-window-buffers
       tab-line-select-tab tab-line-hscroll tab-line--get-tab-property
       tab-line-tab-map tab-line-mode--turn-on tab-line-tabs-non-excluded
       tab-line-force-update))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Tests for `(schemacs editor tab-line)` - the Lisp half of
;; `tab-line.el`. The display half (the reserved row and the drawing) is
;; `xdisp.scm`'s and `frame.scm`'s, and is checked by the geometry probe
;; in AGENTS.md and by `tools/pty-check.py`; what is here is the format
;; the redisplay reads and the commands that act on it.
;;
;; Every expectation is Emacs 31.1's behaviour for the same sequence,
;; read off `tab-line.el` where it is a rule (the tab string's `tab` and
;; `keymap` properties, the fixed ordering) and off a real Emacs where it
;; is an answer.

(*current-frame* (new-frame (allocate-buffer) 24 80))

(define (fresh name text)
  ;; A buffer called NAME, shown in the selected window, holding TEXT.
  ;;
  ;; `switch-to-buffer` is what a tab line is about: it is the *window's*
  ;; buffer history that `tab-line-tabs-window-buffers` walks, and
  ;; `set-buffer` does not touch it.
  (let ((b (get-buffer-create name)))
    (switch-to-buffer b)
    (insert text)
    b))

;;----------------------------------------------------------------
;; The mode, and the format it installs
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_mode")

(define tab-buffer (fresh "tab-one" "one"))

(test-equal "the mode is off to begin with" #f (tab-line-mode-variable))

(tab-line-mode 1)

(test-equal "turning it on installs the default format"
            #t
            (let ((format (buffer-local-value (current-buffer)
                                              'tab-line-format #f)))
              (and (pair? format)
                   (eq? (car format) ':eval)
                   (procedure? (cadr format))
                   #t)))

(tab-line-mode -1)

(test-equal "turning it off takes the format away"
            #f
            (buffer-local-value (current-buffer) 'tab-line-format #f))

(tab-line-mode 1)

(test-end "schemacs_editor_tab_line_mode")

;;----------------------------------------------------------------
;; The format
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_format")

(test-equal "the tab line names the window's buffer"
            "tab-one"
            (buffer-name (get-text-property 1 'tab
                                           (car (tab-line-format)))))

(test-equal "the tab carries its keymap, which is how a click reaches a command"
            tab-line-tab-map
            (get-text-property 1 'keymap (car (tab-line-format))))

(test-assert "and a face"
             (get-text-property 1 'face (car (tab-line-format))))

;; `tab-line--get-tab-property` looks at 1, then 0, then the first
;; position the property changes at - which is how a separator of any
;; length is skipped.
(test-equal "the tab property is found through the separator"
            tab-buffer
            (tab-line--get-tab-property 'tab (car (tab-line-format))))

(test-end "schemacs_editor_tab_line_format")

;;----------------------------------------------------------------
;; The tab list, and switching to a tab
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_tabs")

(define tab-two (fresh "tab-two" "two"))
(define tab-three (fresh "tab-three" "three"))

(test-equal "the fixed ordering keeps the order the tabs were added in"
            (list tab-buffer tab-two tab-three)
            (tab-line-tabs-fixed-window-buffers))

;; Switching back to a buffer already on the tab line must not move it.
(switch-to-buffer tab-buffer)

(test-equal "switching back does not reorder the fixed tabs"
            (list tab-buffer tab-two tab-three)
            (tab-line-tabs-fixed-window-buffers))

;; The *window* ordering, which is what `tab-line-tabs-window-buffers`
;; answers, is the window's own history: the current buffer, then the
;; ones it showed before, most recent first.
(test-equal "the window ordering is the window's own history"
            (list tab-two tab-three tab-buffer)
            (tab-line-tabs-window-buffers))

;; A click on a tab: the event is `(down-mouse-1 POSN)` and the posn
;; carries the *string* the click landed on - `(nth 4 posn)` - which is
;; what `posn-string` answers.
(define (tab-event string window)
  (list 'down-mouse-1
        (list window 'tab-line (cons 0 0) 0 (cons string 0) 0)))

(define (tab-string-for buffer)
  ;; The piece of the tab line that stands for BUFFER: the first string
  ;; whose `tab` property is it. A piece is the separator plus the tab,
  ;; so the property starts at position 1.
  (let loop ((pieces (tab-line-format)))
    (cond ((null? pieces) #f)
          ((and (string? (car pieces))
                (eq? (get-text-property 1 'tab (car pieces)) buffer))
           (car pieces))
          (else (loop (cdr pieces))))))

(tab-line-select-tab (tab-event (tab-string-for tab-two) (selected-window)))

(test-equal "clicking a tab selects its buffer"
            "tab-two"
            (buffer-name (current-buffer)))

(test-end "schemacs_editor_tab_line_tabs")

;;----------------------------------------------------------------
;; Scrolling
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_hscroll")

(tab-line-hscroll 1)
(tab-line-force-update #t)
(tab-line-hscroll 1)

(test-equal "scrolling right is stored as the window parameter"
            2
            (window-parameter (selected-window) 'tab-line-hscroll))

(tab-line-hscroll 100)

(test-equal "and is clamped to the last tab"
            2
            (window-parameter (selected-window) 'tab-line-hscroll))

(tab-line-hscroll -100)

(test-equal "and to the first"
            0
            (window-parameter (selected-window) 'tab-line-hscroll))

(test-end "schemacs_editor_tab_line_hscroll")

;;----------------------------------------------------------------
;; The globalized mode
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_global")

(test-equal "the global mode is off to start with"
            #f
            (global-tab-line-mode-variable))

;; A buffer whose tab line was turned off by hand keeps it off.
(set-buffer (get-buffer-create "tab-excluded"))
(set-buffer-local-value! (current-buffer) 'tab-line-exclude #t)
(tab-line-mode--turn-on)

(test-equal "`tab-line-exclude' keeps a buffer out of the global mode"
            #f
            (tab-line-mode-variable))

(set-buffer tab-buffer)
(global-tab-line-mode 1)

(test-equal "switching the global mode on turns the local one on"
            #t
            (tab-line-mode-variable))

(test-equal "and installs one after-change-major-mode-hook entry"
            1
            (length (*after-change-major-mode-hook*)))

(set-buffer (get-buffer-create "tab-new"))
(run-hooks (*after-change-major-mode-hook*))

(test-equal "a new buffer gets the tab line when its major mode is set"
            #t
            (tab-line-mode-variable))

(global-tab-line-mode -1)

(test-equal "switching it off removes the hook entry"
            0
            (length (*after-change-major-mode-hook*)))

(test-equal "and turns the tab line off in the buffers that had it"
            #f
            (with-current-buffer
                tab-buffer
              (tab-line-mode-variable)))

;; `tab-line-tabs-non-excluded` is the filter Emacs 31 offers for the
;; window-buffer list; a buffer whose `tab-line-exclude` is set drops out
;; of it.
(set-buffer tab-two)

(test-equal "the non-excluded filter keeps a buffer that is not excluded"
            (list tab-two)
            (tab-line-tabs-non-excluded (list tab-two)))

(set-buffer-local-value! tab-two 'tab-line-exclude #t)

(test-equal "and drops one that is"
            '()
            (tab-line-tabs-non-excluded (list tab-two)))

(test-end "schemacs_editor_tab_line_global")
