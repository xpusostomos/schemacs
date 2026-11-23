(define-library (schemacs tooltip)
  ;; This library mirrors GNU Emacs's `lisp/tooltip.el': the delayed
  ;; display of the help text `help-echo` carries - "Emacs displays help
  ;; text (e.g. for buttons and menu items that you put the mouse on) in a
  ;; pop-up window" - and the echo-area fallback when tooltips are off or
  ;; the display is a terminal.
  ;;
  ;; The chain it sits in is three libraries long, and each step is a
  ;; different Emacs file:
  ;;
  ;;   `note_mouse_highlight` (`xdisp.c`) finds the `help-echo` under the
  ;;   pointer and calls `show_help_echo` (`keyboard.c`), which runs
  ;;   `show-help-function` - the variable *this* file installs, as
  ;;   `tooltip-show-help`. That starts `tooltip-delay`'s one-shot timer;
  ;;   when it fires, `tooltip-show` asks the display for a tip.
  ;;
  ;; The display half is `x-show-tip` (`xfns.c`; the Gtk build's is
  ;; `pgtkfns.c`). On the Gtk build `use-system-tooltips` is true, so the
  ;; tip is the *desktop's* own tooltip: `gtk_widget_set_tooltip_text` on
  ;; the frame's outer widget (`xg_show_tooltip`, `gtkutil.c:997`), which
  ;; is what real Emacs shows on the same desktop and why `tooltip` face
  ;; colours do not apply there.
  ;;
  ;; `tooltip-mode` is on by default, as in Emacs. Emacs arranges that
  ;; through `defcustom`'s `:set` function - `custom-set-minor-mode`
  ;; calls the mode - when `:initialize #'custom-initialize-after-file-load`
  ;; runs. `define-minor-mode` here accepts and drops `:set`/`:initialize`
  ;; (see `easy-mmode.scm`), so the call the setter would make is written
  ;; at the bottom of this file.
  ;;
  ;; **Not carried**, each because what it needs is not ported:
  ;; `tooltip-process-prompt-regexp` and `tooltip-strip-prompt` (they read
  ;; a process's buffer, and there are no subprocesses here);
  ;; `x-pre-popup-menu-hook` (the hook does not exist in this tree, so a
  ;; tooltip is not hidden when a menu pops up); `menu-or-popup-active-p`
  ;; (the NS-only guard in `tooltip-show-help`, and there is no NS here);
  ;; `tooltip-reuse-hidden-frame` and the tooltip *frame* of the non-GTK
  ;; path (this front end uses system tooltips, as the Gtk build does);
  ;; and `message-truncate-lines` (the echo area's own truncation).

  (import
    (scheme base)
    (scheme cxr)
    (only (schemacs command) current-prefix-arg uarg->integer)
    (only (schemacs custom) define-custom)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs keyboard) *show-help-function*
          sit-for)
    (only (schemacs editfns) message current-message
          region-beginning region-end buffer-substring point goto-char
          save-excursion)
    (only (schemacs dispnew) *cursor-in-echo-area*
          display-show-tip display-hide-tip)
    (only (schemacs frame) selected-frame selected-window
          window-minibuffer-p window-type? display-graphic-p frame?
          frame-output *pre-command-hook* window-buffer)
    (only (schemacs core timer) run-with-timer cancel-timer)
    (only (schemacs subr) add-hook remove-hook
          run-hook-with-args-until-success string-replace nth
          posn-window posn-point event-end)
    (only (schemacs faces) face-attribute)
    (only (schemacs textprop) add-face-text-property)
    (only (schemacs fns) copy-sequence equal-including-properties)
    (only (schemacs timefns) current-time float-time time-less-p
          time-since)
    (only (schemacs buffer) with-current-buffer)
    (only (schemacs simple) use-region-p)
    (only (schemacs search) looking-at)
    (only (schemacs syntax) skip-syntax-backward skip-syntax-forward
          syntax-ppss))

  (export
   tooltip-mode tooltip-mode-variable
   *tooltip-delay* *tooltip-short-delay* *tooltip-recent-seconds*
   *tooltip-hide-delay* *tooltip-x-offset* *tooltip-y-offset*
   *tooltip-frame-parameters* *tooltip-resize-echo-area*
   *tooltip-functions*
   ;; The state variables `tooltip.el` `defvar`s, which a test (or a
   ;; user at the back door) may want to read.
   tooltip-timeout-id tooltip-last-mouse-motion-event tooltip-hide-time
   tooltip-help-message tooltip-previous-message
   tooltip-event-buffer tooltip-delay tooltip-cancel-delayed-tip
   tooltip-start-delayed-tip tooltip-timeout
   tooltip-show tooltip-hide
   tooltip-identifier-from-point tooltip-expr-to-print
   tooltip-show-help-non-mode tooltip-show-help tooltip-help-tips
   x-show-tip x-hide-tip *x-show-tooltip-timeout*)

  (begin

    ;;----------------------------------------------------------------
    ;; Switching tooltips on/off - `tooltip.el:43`
    ;;----------------------------------------------------------------

    (define-minor-mode tooltip-mode
      "Toggle Tooltip mode.

When this global minor mode is enabled, Emacs displays help
text (e.g. for buttons and menu items that you put the mouse on)
in a pop-up window.

When Tooltip mode is disabled, Emacs displays help text in the
echo area, instead of making a pop-up window."
      :global #t
      ;; "Even if we start on a text-only terminal, make this non-nil by
      ;; default because we can open a graphical frame later (multi-tty)."
      :init-value #t
      :group 'tooltip
      ;; `(if (and tooltip-mode (fboundp 'x-show-tip)) ...)': `x-show-tip`
      ;; is defined below in this same library, so the `fboundp` half
      ;; has nothing to ask here.
      (if (tooltip-mode-variable)
          (begin
            (add-hook *pre-command-hook* tooltip-hide)
            (add-hook *tooltip-functions* tooltip-help-tips))
          ;; `(unless (and (boundp 'gud-tooltip-mode) gud-tooltip-mode)
          ;;   (remove-hook ...))' - gud is not ported, so the removal is
          ;; unconditional. `x-pre-popup-menu-hook` is not carried; see
          ;; the header.
          (remove-hook *pre-command-hook* tooltip-hide))
      (*show-help-function*
       (if (tooltip-mode-variable)
           tooltip-show-help
           tooltip-show-help-non-mode)))

    ;;----------------------------------------------------------------
    ;; Customizable settings - `tooltip.el:73`
    ;;----------------------------------------------------------------

    (define-custom *tooltip-delay* 0.7
      "Seconds to wait before displaying a tooltip the first time."
      :type 'number
      :group 'tooltip)

    (define-custom *tooltip-short-delay* 0.1
      "Seconds to wait between subsequent tooltips on different items."
      :type 'number
      :group 'tooltip)

    (define-custom *tooltip-recent-seconds* 1
      "Display tooltips if changing tip items within this many seconds.
Do so after `tooltip-short-delay'."
      :type 'number
      :group 'tooltip)

    (define-custom *tooltip-hide-delay* 10
      "Hide tooltips automatically after this many seconds."
      :type 'number
      :group 'tooltip)

    (define-custom *tooltip-x-offset* 5
      "X offset, in pixels, for the display of tooltips.
The offset is the distance between the X position of the mouse and
the left border of the tooltip window.  It must be chosen so that the
tooltip window doesn't contain the mouse when it pops up, or it may
interfere with clicking where you wish.

If `tooltip-frame-parameters' includes the `left' parameter,
the value of `tooltip-x-offset' is ignored."
      :type 'integer
      :group 'tooltip)

    (define-custom *tooltip-y-offset* +20
      "Y offset, in pixels, for the display of tooltips.
The offset is the distance between the Y position of the mouse and
the top border of the tooltip window.  It must be chosen so that the
tooltip window doesn't contain the mouse when it pops up, or it may
interfere with clicking where you wish.

If `tooltip-frame-parameters' includes the `top' parameter,
the value of `tooltip-y-offset' is ignored."
      :type 'integer
      :group 'tooltip)

    (define-custom *tooltip-frame-parameters*
      '((name . "tooltip")
        (internal-border-width . 2)
        (border-width . 1)
        (no-special-glyphs . #t))
      "Frame parameters used for tooltips.

If `left' or `top' parameters are included, they specify the absolute
position to pop up the tooltip.

Note that font and color parameters are ignored, and the attributes
of the `tooltip' face are used instead."
      :type '(repeat (cons :format "%v"
                           (symbol :tag "Parameter")
                           (sexp :tag "Value")))
      :group 'tooltip)

    (define-custom *tooltip-resize-echo-area* #f
      "If non-nil, using the echo area for tooltips will resize the echo area.
By default, when the echo area is used for displaying tooltips,
the tooltip text is truncated if it exceeds a single screen line.
When this variable is non-nil, the text is not truncated; instead,
the echo area is resized as needed to accommodate the full text
of the tooltip.
This variable has effect only on GUI frames."
      :type 'boolean
      :group 'tooltip)

    ;;----------------------------------------------------------------
    ;; Variables that are not customizable - `tooltip.el:157`
    ;;----------------------------------------------------------------

    (define *tooltip-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `tooltip-functions': "Functions to call to display
    ;; tooltips. Each function is called with one argument EVENT which is
    ;; a copy of the last mouse movement event that occurred. If one of
    ;; these functions displays the tooltip, it should return non-nil and
    ;; the rest are not called." A hook is a parameter in this tree.

    (define tooltip-timeout-id #f)
    ;; ^ "The id of the timeout started when Emacs becomes idle." Here it
    ;; is the timer object `run-with-timer` answered, which is what
    ;; `cancel-timer` takes.

    (define tooltip-last-mouse-motion-event #f)
    ;; ^ "A copy of the last mouse motion event seen." Set by gud's
    ;; tooltip mode in Emacs, which is not ported, so it stays nil - and
    ;; `tooltip-help-tips` ignores its argument anyway.

    (define tooltip-hide-time #f)
    ;; ^ "Time when the last tooltip was hidden."

    ;;----------------------------------------------------------------
    ;; Event accessors - `tooltip.el:177`
    ;;----------------------------------------------------------------

    (define (tooltip-event-buffer event)
      ;; "Return the buffer over which event EVENT occurred. This might
      ;; return nil if the event did not occur over a buffer."
      ;;--------------------------------------------------------------
      (let ((window (posn-window (event-end event))))
        (and (window-type? window) (window-buffer window))))

    ;;----------------------------------------------------------------
    ;; Timeout for tooltip display - `tooltip.el:186`
    ;;----------------------------------------------------------------

    (define (tooltip-delay)
      ;; "Return the delay in seconds for the next tooltip."
      ;;--------------------------------------------------------------
      (if (and tooltip-hide-time
               (time-less-p (time-since tooltip-hide-time)
                            (*tooltip-recent-seconds*)))
          (*tooltip-short-delay*)
          (*tooltip-delay*)))

    (define (tooltip-cancel-delayed-tip)
      ;; "Disable the tooltip timeout."
      ;;--------------------------------------------------------------
      (when tooltip-timeout-id
        (cancel-timer tooltip-timeout-id)
        (set! tooltip-timeout-id #f)))

    (define (tooltip-start-delayed-tip)
      ;; "Add a one-shot timeout to call function `tooltip-timeout'."
      ;;--------------------------------------------------------------
      (set! tooltip-timeout-id
            (run-with-timer (tooltip-delay) #f tooltip-timeout #f)))

    (define (tooltip-timeout object)
      ;; "Function called when timer with id `tooltip-timeout-id' fires."
      ;;--------------------------------------------------------------
      (run-hook-with-args-until-success (*tooltip-functions*)
                                        tooltip-last-mouse-motion-event))

    ;;----------------------------------------------------------------
    ;; Displaying tips - `tooltip.el:213`
    ;;----------------------------------------------------------------

    (define (tooltip-set-param alist key value)
      ;; "Change the value of KEY in alist ALIST to VALUE. If there's no
      ;; association for KEY in ALIST, add one, otherwise change the
      ;; existing association. Value is the resulting alist."
      ;;--------------------------------------------------------------
      (let ((cell (assq key alist)))
        (if cell
            (begin (set-cdr! cell value) alist)
            (cons (cons key value) alist))))

    (define *x-show-tooltip-timeout* 10)
    ;; ^ GNU Emacs's `x-show-tooltip-timeout` (`xfns.c` in the C): "Timeout
    ;; for tooltips, in seconds." `x-show-tip`'s TIMEOUT when the caller
    ;; gives none - `tooltip-show` always gives `tooltip-hide-delay`.

    (define x-tip-frame #f)
    ;; ^ The frame the tip belongs to - the C's `tip_last_frame`
    ;; (`pgtkfns.c:2570`). `x-hide-tip` needs it because the display that
    ;; shows the tip may no longer be the selected frame's when the tip
    ;; is hidden.

    (define (x-show-tip string . rest)
      ;; GNU Emacs's `x-show-tip` (`xfns.c`; the Gtk build's C is
      ;; `pgtkfns.c:3077`):
      ;;
      ;;   (x-show-tip STRING &optional FRAME PARMS TIMEOUT DX DY)
      ;;
      ;; "Show STRING in a tooltip window, at the current mouse position
      ;; on FRAME ... The tooltip will be hidden after TIMEOUT seconds."
      ;; The Gtk build with `use-system-tooltips` - the default - shows a
      ;; *system* tooltip, which ignores PARMS, DX and DY (see
      ;; `display-show-tip`'s note in `dispnew.scm`).
      ;;
      ;; The C answers nil on every path; the caller `tooltip-show` does
      ;; not read the answer.
      ;;--------------------------------------------------------------
      (let* ((frame (or (and (pair? rest) (car rest)) (selected-frame)))
             (parms (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (timeout (let ((value (and (pair? rest)
                                        (pair? (cdr rest))
                                        (pair? (cddr rest))
                                        (caddr rest))))
                        (if value value *x-show-tooltip-timeout*))))
        ;; The C's two checks "before we do anything real" - a string,
        ;; and an empty one becomes a space so there is something to
        ;; size.
        (unless (string? string)
          (error "Wrong type argument: stringp, ~s" string))
        (when (= (string-length string) 0)
          (set! string " "))
        (set! x-tip-frame frame)
        (let ((display (and (frame? frame) (frame-output frame))))
          (when display
            (display-show-tip display frame string timeout))))
      #f)

    (define (x-hide-tip)
      ;; GNU Emacs's `x-hide-tip`: "Hide the tooltip if one is displayed;
      ;; return t if there was one." The C's `pgtk_hide_tip` cancels the
      ;; hide timer first, which the display method does.
      ;;--------------------------------------------------------------
      (let ((frame x-tip-frame))
        (set! x-tip-frame #f)
        (and (frame? frame)
             (let ((display (frame-output frame)))
               (and display (display-hide-tip display))))))

    (define (tooltip-show text . rest)
      ;; GNU Emacs's `tooltip-show` (`tooltip.el:224`): "Show a tooltip
      ;; window displaying TEXT." USE-ECHO-AREA forces the echo area;
      ;; otherwise a text-only display uses it too. TEXT-FACE and
      ;; DEFAULT-FACE default to `tooltip`.
      ;;
      ;; The face attributes are put into the frame parameters as the C
      ;; does, though the system tooltip ignores them - and
      ;; `add-face-text-property` is applied to the caller's string, "so
      ;; if your code depends on the text properties, you should copy
      ;; the tooltip string before passing it".
      ;;--------------------------------------------------------------
      (let ((use-echo-area (and (pair? rest) (car rest)))
            (text-face (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (default-face (and (pair? rest) (pair? (cdr rest))
                               (pair? (cddr rest)) (caddr rest))))
        (if (or use-echo-area (not (display-graphic-p)))
            (tooltip-show-help-non-mode text)
            (guard (error (#t
                           ;; `message` is Emacs's, so the directive
                           ;; is `%s` - `~a` is `error`'s spelling.
                           (message "Error while displaying tooltip: %s" error)
                           (sit-for 1 #f)
                           (message "%s" text)))
              (let ((params (copy-sequence (*tooltip-frame-parameters*)))
                    (fg (face-attribute (or default-face 'tooltip) ':foreground))
                    (bg (face-attribute (or default-face 'tooltip) ':background)))
                (when (string? fg)
                  (set! params (tooltip-set-param params 'foreground-color fg))
                  (set! params (tooltip-set-param params 'border-color fg)))
                (when (string? bg)
                  (set! params (tooltip-set-param params 'background-color bg)))
                ;; APPEND non-nil "to avoid overriding any faces used in
                ;; our TEXT" - `help-key-binding` in a
                ;; `substitute-command-keys` result, for one.
                (add-face-text-property 0 (string-length text)
                                        (or text-face 'tooltip) #t text)
                (x-show-tip text (selected-frame) params
                            (*tooltip-hide-delay*)
                            (*tooltip-x-offset*)
                            (*tooltip-y-offset*)))))))

    (define (tooltip-hide . ignored)
      ;; GNU Emacs's `tooltip-hide` (`tooltip.el:285`): "Hide a tooltip,
      ;; if one is displayed. Value is non-nil if tooltip was open."
      ;;--------------------------------------------------------------
      (tooltip-cancel-delayed-tip)
      (if (display-graphic-p)
          (when (x-hide-tip)
            (set! tooltip-hide-time (float-time)))
          (let ((msg (current-message)))
            (message "")
            (when (not (or (not msg) (equal? msg "")))
              (set! tooltip-hide-time (float-time))))))

    ;;----------------------------------------------------------------
    ;; Debugger-related functions - `tooltip.el:300`
    ;;----------------------------------------------------------------

    (define (tooltip-identifier-from-point point)
      ;; "Extract the identifier at POINT, if any. Value is nil if no
      ;; identifier exists at point. Identifier extraction is based on
      ;; the current syntax table."
      ;;--------------------------------------------------------------
      (save-excursion
        (goto-char point)
        (let* ((start (begin (skip-syntax-backward "w_") (point)))
               (pstate (syntax-ppss)))
          (unless (or (looking-at "[0-9]")
                      (nth 3 pstate)
                      (nth 4 pstate))
            (skip-syntax-forward "w_")
            (when (> (point) start)
              (buffer-substring start (point)))))))

    (define (tooltip-expr-to-print event)
      ;; "Return an expression that should be printed for EVENT. If a
      ;; region is active and the mouse is inside the region, print the
      ;; region. Otherwise, figure out the identifier around the point
      ;; where the mouse is."
      ;;--------------------------------------------------------------
      (with-current-buffer (tooltip-event-buffer event)
        (let ((point (posn-point (event-end event))))
          (if (use-region-p)
              (when (and (<= (region-beginning) point) (<= point (region-end)))
                (buffer-substring (region-beginning) (region-end)))
              (tooltip-identifier-from-point point)))))

    ;; `tooltip-process-prompt-regexp` and `tooltip-strip-prompt` are
    ;; not carried: they read `comint-prompt-regexp` out of a *process*
    ;; buffer, and there are no subprocesses in this tree.

    ;;----------------------------------------------------------------
    ;; Tooltip help - `tooltip.el:351`
    ;;----------------------------------------------------------------

    (define tooltip-help-message #f)
    ;; ^ "The last help message received via `show-help-function'."

    (define tooltip-previous-message #f)
    ;; ^ "The previous content of the echo area."

    (define (tooltip-show-help-non-mode help)
      ;; "Function installed as `show-help-function' when Tooltip mode is
      ;; off. It is also called if Tooltip mode is on, for text-only
      ;; displays."
      ;;
      ;; `window-minibuffer-p` takes the window here rather than
      ;; defaulting to the selected one, and `cursor-in-echo-area` is a
      ;; parameter - both tree spellings. `message-truncate-lines`, which
      ;; the C binds around the message, is not ported (the echo area's
      ;; own truncation is the renderer's).
      ;;--------------------------------------------------------------
      (when (and (not (window-minibuffer-p (selected-window)))
                 (not (*cursor-in-echo-area*)))
        (cond
         ((string? help)
          (set! help (string-replace "\n" ", " help))
          (unless (or tooltip-previous-message
                      (equal-including-properties help (current-message))
                      (and (string? tooltip-help-message)
                           (equal-including-properties
                            tooltip-help-message (current-message))))
            (set! tooltip-previous-message (current-message)))
          (set! tooltip-help-message help)
          (message "%s" help))
         ((string? tooltip-previous-message)
          (message "%s" tooltip-previous-message)
          (set! tooltip-previous-message #f))
         ;; "Only stop displaying the message when the current message
         ;; is our own. This has the advantage of not clearing the echo
         ;; area when running after an error message was displayed
         ;; (Bug#3192)."
         ((equal-including-properties tooltip-help-message
                                      (current-message))
          (message #f)))))

    (define (tooltip-show-help msg)
      ;; "Function installed as `show-help-function'. MSG is either a
      ;; help string to display, or nil to cancel the display."
      ;;
      ;; The C's NS-only guard - "Tooltips can't be displayed on top of
      ;; the global menu bar on NS" - has nothing to ask here: there is
      ;; no NS front end and no `menu-or-popup-active-p`.
      ;;--------------------------------------------------------------
      (let ((previous-help tooltip-help-message))
        (set! tooltip-help-message msg)
        (cond
         ((not msg)
          ;; "Cancel display. This also cancels a delayed tip, if there
          ;; is one."
          (tooltip-hide))
         ((equal? previous-help msg)
          ;; "Same help as before (but possibly the mouse has moved or
          ;; the text properties have changed). Keep what we have."
          #f)
         (else
          ;; "A different help. Remove a previous tooltip, and display a
          ;; new one, with some delay."
          (tooltip-hide)
          (tooltip-start-delayed-tip)))))

    (define (tooltip-help-tips event)
      ;; "Hook function to display a help tooltip. This is installed on
      ;; the hook `tooltip-functions', which is run when the timer with
      ;; id `tooltip-timeout-id' fires. Value is non-nil if this function
      ;; handled the tip."
      ;;--------------------------------------------------------------
      (when (string? tooltip-help-message)
        (tooltip-show tooltip-help-message (not (tooltip-mode-variable)))
        #t))

    ;; The initialization Emacs reaches through `defcustom`'s `:set`.
    ;; `custom-initialize-after-file-load` sets the variable through
    ;; `custom-set-minor-mode`, which calls the mode - and the mode's body
    ;; is what installs `show-help-function`. Without this call the
    ;; variable would read t and nothing would be installed.
    (tooltip-mode 1)

    ))
