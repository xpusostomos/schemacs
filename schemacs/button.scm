(define-library (schemacs button)
  ;; GNU Emacs's `lisp/button.el', of which this tree carries the part
  ;; the redisplay and `compilation--insert-abbreviated-line' use: the
  ;; text-property buttons built by `buttonize-region' and clicked with
  ;; `push-button'.
  ;;
  ;; **Not carried**, each with what it waits for:
  ;;
  ;;   * the button *types* (`define-button-type', `button-type-*',
  ;;     `button-category-symbol') - `type' is a `category' symbol and
  ;;     this tree's `get-text-property' does follow `category', but
  ;;     nothing here defines a type yet;
  ;;   * the navigation commands (`forward-button', `backward-button',
  ;;     `next-button', `previous-button', `button-mode') and their
  ;;     `button-buffer-map' bindings, which want `next-single-char-
  ;;     property-change' and the `button-describe' Help buffer;
  ;;   * `describe-button' and friends (a `*Help*' command);
  ;;   * the mode-line/header-line `posn-string' arm of `push-button'
  ;;     and the touchscreen arms - no touch event exists in either
  ;;     front end, and no area button is made here yet.  The arm is
  ;;     written, so a string button works when one arrives.
  ;;
  ;; The buttons are text-property buttons: the property plist is the
  ;; C's, including `category t' (which is what `button-at' tests for
  ;; and what makes an old `get-text-property' lookup find the button).

  (import
    (scheme base)
    (only (schemacs faces) defface)
    (only (schemacs keymap) make-sparse-keymap define-key set-keymap-parent)
    (only (schemacs command) define-command *last-command-event*)
    (only (schemacs buffer)
          current-buffer with-current-buffer bufferp
          make-overlay overlayp overlay-start overlay-end overlay-get
          overlay-put delete-overlay overlays-in)
    (only (schemacs editfns)
          point point-min point-max goto-char save-excursion propertize)
    (only (schemacs textprop)
          get-text-property get-char-property next-single-property-change
          previous-single-property-change add-text-properties
          remove-text-properties put-text-property add-face-text-property)
    (only (schemacs marker) markerp copy-marker marker-buffer)
    (only (schemacs subr) event-start posn-window posn-string posn-point kbd)
    (only (schemacs window) display-buffer save-selected-window)
    (only (schemacs frame) select-window window-buffer recenter))

  (export button-map button-buffer-map
          button-start button-end button-get button-put button-at
          button-activate push-button
          buttonize buttonize-region unbuttonize-region
          button--properties button--area-button-p)

  (begin

    (defface 'button '((t (:inherit link)))
      "Default face used for buttons.")

    (define button-buffer-map (make-sparse-keymap "Button buffer"))
    (define button-map (make-sparse-keymap "Button"))
    (set-keymap-parent button-map button-buffer-map)

    (define (button--area-button-p b)
      "Return non-nil if BUTTON is an area button.
Such area buttons are used for buttons in the mode-line and header-line."
      ;; `button.el:290'.
      (and (pair? b) (string? (car b)) #t))

    (define (button--area-button-string b)
      "Return area button BUTTON's button-string."
      ;; `button.el:295': `(defalias 'button--area-button-string #'car)'.
      (car b))

    (define (button--properties callback data help-echo)
      ;; `button.el:654'.
      ;;--------------------------------------------------------------
      (append
       (list 'font-lock-face 'button
             'mouse-face 'highlight
             'button #t
             'follow-link #t
             'category #t
             'button-data data
             'keymap button-map
             'action callback)
       (if help-echo
           (list 'help-echo help-echo
                 ;; Record that button.el is responsible for this property.
                 'help-echo-button #t)
           '())))

    (define (button-start button)
      "Return the position at which BUTTON starts.

This function only works when BUTTON is in the current buffer."
      ;; `button.el:185'.
      ;;--------------------------------------------------------------
      (if (overlayp button)
          (overlay-start button)
          ;; Must be a text-property button.
          (or (previous-single-property-change (+ button 1) 'button)
              (point-min))))

    (define (button-end button)
      "Return the position at which BUTTON ends.

This function only works when BUTTON is in the current buffer."
      ;; `button.el:195'.
      ;;--------------------------------------------------------------
      (if (overlayp button)
          (overlay-end button)
          ;; Must be a text-property button.
          (or (next-single-property-change button 'button)
              (point-max))))

    (define (button-get button prop)
      "Get the property of button BUTTON named PROP.

This function only works when BUTTON is in the current buffer."
      ;; `button.el:205'.
      ;;--------------------------------------------------------------
      (cond ((overlayp button) (overlay-get button prop))
            ((button--area-button-p button)
             (get-text-property (cdr button) prop
                                (button--area-button-string button)))
            ((markerp button)
             (get-text-property button prop (marker-buffer button)))
            (else                       ; must be a text-property button
             (get-text-property button prop))))

    (define (button-put button prop val)
      "Set BUTTON's PROP property to VAL.

This function only works when BUTTON is in the current buffer."
      ;; `button.el:219'.  The `type' translation and the `category'
      ;; refusal are the C's; the type-to-category translation needs
      ;; `button-category-symbol', which is not carried (see the header).
      ;;--------------------------------------------------------------
      (when (memq prop '(type :type))
        (error "Button types are not carried (see (schemacs button))"))
      (when (eq? prop 'category)
        ;; Disallow updating the `category' property directly.
        (error "Button `category' property may not be set directly"))
      (cond ((overlayp button) (overlay-put button prop val))
            ((button--area-button-p button)
             (let ((string (button--area-button-string button)))
               (put-text-property 0 (string-length string) prop val string)))
            (else                       ; must be a text-property button
             (put-text-property
              (or (previous-single-property-change (+ button 1) 'button)
                  (point-min))
              (or (next-single-property-change button 'button)
                  (point-max))
              prop val))))

    (define (button-at pos)
      "Return the button at position POS in the current buffer, or nil.
If the button at POS is a text property button, the return value
is a marker pointing to POS."
      ;; `button.el:414'.
      ;;--------------------------------------------------------------
      (let ((button (get-char-property pos 'button)))
        (and button (get-char-property pos 'category)
             (if (overlayp button)
                 button
                 ;; Must be a text-property button; return a marker
                 ;; pointing to it.
                 (copy-marker pos #t)))))

    (define (button-activate button . rest)
      "Call BUTTON's `action' property.
If USE-MOUSE-ACTION is non-nil, invoke the button's `mouse-action'
property instead of `action'; if the button has no `mouse-action',
the value of `action' is used instead."
      ;; `button.el:247'.
      ;;--------------------------------------------------------------
      (let* ((use-mouse-action (and (pair? rest) (car rest)))
             (action (or (and use-mouse-action
                              (button-get button 'mouse-action))
                         (button-get button 'action)))
             (data (button-get button 'button-data)))
        (if (markerp action)
            (save-selected-window
              (select-window (display-buffer (marker-buffer action)))
              (goto-char action)
              (recenter 0))
            (action (or data button)))))

    (define-command (push-button pos use-mouse-action)
      "Perform the action specified by a button at location POS.
POS may be either a buffer position or a mouse-event.
POS defaults to point, except when `push-button' is invoked
interactively as the result of a mouse-event, in which case, the
position in the event is used.

If there's no button at POS, do nothing and return nil, otherwise
return t."
      (interactive
       (list (if (integer? (*last-command-event*))
                 (point)
                 (*last-command-event*))))
      ;; `button.el:467'.
      ;;--------------------------------------------------------------
      (if (and (not (integer? pos))
               (pair? pos))
          ;; POS is a mouse event; switch to the proper window/buffer.
          (let ((posn (event-start pos)))
            (with-current-buffer (window-buffer (posn-window posn))
              (let* ((str (posn-string posn))
                     (str-button (and str
                                      (get-text-property (cdr str) 'button
                                                         (car str)))))
                (if str-button
                    ;; mode-line, header-line, or display string event.
                    (button-activate str #t)
                    (push-button (posn-point posn) #t)))))
          ;; POS is just normal position.
          (let ((button (button-at (or pos (point)))))
            (when button
              (button-activate button use-mouse-action)
              #t))))

    (define (buttonize string callback . rest)
      "Make STRING into a button and return it.
When clicked, CALLBACK will be called with the DATA as the
function argument.  If DATA isn't present (or is nil), the button
itself will be used instead as the function argument."
      ;; `button.el:638'.
      ;;--------------------------------------------------------------
      (let ((data (and (pair? rest) (car rest)))
            (help-echo (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (apply propertize string
               (button--properties callback data help-echo))
        (add-face-text-property 0 (string-length string) 'button #t string)
        string))

    (define (buttonize-region start end callback . rest)
      "Make the region between START and END into a button.
When clicked, CALLBACK will be called with the DATA as the
function argument.  If DATA isn't present (or is nil), the button
itself will be used instead as the function argument."
      ;; `button.el:669'.
      ;;--------------------------------------------------------------
      (let ((data (and (pair? rest) (car rest)))
            (help-echo (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        ;; This tree's `add-text-properties` takes the plist as one
        ;; list, where Emacs takes it as &rest arguments.
        (add-text-properties start end
                             (button--properties callback data help-echo))
        (add-face-text-property start end 'button #t)))

    (define (unbuttonize-region start end)
      "Remove all the buttons between START and END.
This removes both text-property and overlay based buttons."
      ;; `button.el:681'.
      ;;--------------------------------------------------------------
      (for-each (lambda (o)
                  (when (overlay-get o 'button)
                    (delete-overlay o)))
                (overlays-in start end))
      (remove-text-properties
       start end
       (append
        (button--properties #f #f #f)
        ;; Only remove help-echo if it was added by button.el.
        (if (get-text-property start 'help-echo-button)
            (list 'help-echo #f 'help-echo-button #f)
            '())))
      (add-face-text-property start end 'button #f))

    ;; The keys come after the commands, a binding being a value.
    (define-key button-map (kbd "RET") push-button)
    (define-key button-map (vector 'mouse-2) push-button)
    (define-key button-map (vector 'follow-link) 'mouse-face)
    ))
