(define-library (schemacs editor-impl)
  ;; This library provides a long list of parameters which must be
  ;; parameterized by a back-end implemention. APIs in lirbaries such
  ;; as `(SCHEMACS APPS EMACS)` call the procedures stored into these
  ;; parameters.

  (import
    (scheme base)
    (scheme case-lambda)
    (only (scheme write) display write)
    (only (schemacs elisp-eval print) elisp-prin1 elisp-princ)
    (only (schemacs elisp-eval environment)
          *elisp-input-port*
          *elisp-output-port*
          *elisp-error-port*
          )
    )

  (export
   new-buffer-view*
   delete-char*
   new-mode-line-view*
   new-echo-area-view*
   new-header-line-view*
   mode-line-display-items*
   new-window-view*
   new-minibuffer-view*
   new-winframe-view*
   display-in-echo-area*
   clear-echo-area*
   get-minibuffer-text*
   exit-minibuffer*
   focus-minibuffer*
   clear-minibuffer*
   new-editor-view*
   self-insert-command*
   insert-into-buffer*
   is-graphical-display?*
   is-buffer-modified?*
   current-editor-closure*
   selected-frame*
   current-buffer*
   select-window*
   command-error-default-function*
   prin1*
   princ*
   )

  (begin

    (define is-graphical-display?* (make-parameter #f))

    (define is-buffer-modified?* (make-parameter (lambda (_) #t)))

    (define self-insert-command*
      ;; This is a command that needs to be defined in the front-end. This
      ;; parameter must contain a procedure that takes two arguments:
      ;; 1. data of <window-type> in which the event occurred, and 2. a
      ;; string of characters produced by running "km:keymap-index->ascii"
      ;; on the <keymap-index-type> data produced by the front-end.
      (make-parameter (lambda (window string) (display string))))

    (define new-buffer-view*
      ;; Takes 1 parameter: the buffer of type <buffer-type> that is being constructed.
      (make-parameter (lambda (_) #f)))

    (define insert-into-buffer*
      (make-parameter (lambda (string-or-char) (values))))

    (define delete-char*
      (make-parameter (lambda (char-count save-to-killring) #f)))

    (define (make-null-line-display parent-window)
      ;; The default back-end implementation for constructing any line
      ;; display is to take the parent window as an argument and always
      ;; return #f.
      #f)

    (define new-mode-line-view* (make-parameter make-null-line-display))

    (define new-echo-area-view* (make-parameter make-null-line-display))

    (define new-window-view*
      ;; Takes 1 parameter: the window of type <window-type> that is being constructed.
      (make-parameter (lambda (_) #f)))

    (define new-header-line-view* (make-parameter make-null-line-display))

    (define mode-line-display-items*
      ;; Must be a procedure that takes 3 arguments: the parent window of
      ;; <window-type>, a view of <line-display-type>, and a list of
      ;; strings or propertized strings to be inserted into the display.
      (make-parameter
       (lambda (window line-disp info)
         (display ";; no implementation for mode-line-set-info\n")
         (display ";; ")
         (write info)
         (newline))))

    (define new-minibuffer-view*
      ;; This function will be evaluated shortly after the function set in
      ;; the new-winframe-view parameter. This function takes 1
      ;; parameter: the frame being constructed, which will reflect
      ;; whatever changes were made by the function in
      ;; new-winframe-view.
      (make-parameter (lambda (minibuffer) #f)))

    (define new-winframe-view*
      ;; Takes 2 parameters: the farme being constructed, and an initial
      ;; window of type <window-type>.
      (make-parameter (lambda (frame window) #f)))

    (define new-editor-view* (make-parameter (lambda (editor) #f)))

    (define display-in-echo-area*
      (make-parameter
       (lambda (winframe str)
         (display str) (newline))))

    (define clear-echo-area*
      (make-parameter
       (lambda (winframe)
         (newline)
         (values))))

    (define get-minibuffer-text*
      ;; Copy the text currently in the minibuffer and return it.
      (make-parameter (lambda (frame) #f))
      )

    (define exit-minibuffer*
      ;; If the minibuffer is visible, hide the minibuffer and show the echo area.
      (make-parameter (lambda (frame) #f))
      )

    (define focus-minibuffer*
      (make-parameter (lambda (winframe prompt) (display prompt)))
      )

    (define clear-minibuffer*
      (make-parameter (lambda (window) #f))
      )

    (define (make-editor-state-closure data)
      (case-lambda
        (() data)
        ((new-data) (set! data new-data) new-data)
        ))

    (define *current-editor* (make-parameter (make-editor-state-closure #f)))

    (define (current-editor-closure* . args) (apply (*current-editor*) args))

    (define select-window*
      (make-parameter
       (lambda (window)
         (display ";; *impl/select-window* not implemented\n")
         )))

    ;; -------------------------------------------------------------------------------------------------
    ;; These are global variables from the point of view of Emacs
    ;; Lisp. They are parameters in this library, and are parameterized by
    ;; the GUI provider library. These APIs are exposed in the (SCHEMACS
    ;; EDITOR) library, but as procedures which cannot modify the
    ;; parameter.

    (define selected-frame*  (make-parameter #f))
    ;;(define selected-window* (make-parameter #f)) ;; <-- NO, this should not exist*
    (define current-buffer*  (make-parameter #f))

    ;; * the `selected-window` API should not be provided because it
    ;; should be defined as `(view (selected-frame) =>winframe-window)`.
    ;; Instead the back-end API should use =>winframe-window to update the
    ;; winframe whenever a focus change event occurs in the GUI front-end.
    ;; This is what the `FOCUS-WINDOW*` API should do.

    ;;-------------------------------------------------------------------------------------------------

    (define command-error-default-function*
      (make-parameter (lambda (data context signal) #f)))

    ;;--------------------------------------------------------------------------------------------------

    ;; `prin1' and `princ' are `print.c`'s, and the real ones are in
    ;; `(schemacs elisp-eval print)'. What stood here was
    ;; `(write val stream)' - Guile's `write', which is not `prin1': it
    ;; says `#t' where Lisp wants `t', it has no `print-length' and no
    ;; `print-level', and it does not know this tree's `nil'.
    (define default-prin1-impl
      (case-lambda
        ((val) (elisp-prin1 val (*elisp-output-port*)))
        ((val stream) (elisp-prin1 val stream))
        ((val stream overrides) (elisp-prin1 val stream overrides))
        ))

    (define prin1* (make-parameter default-prin1-impl))

    (define default-princ-impl
      (case-lambda
        ((val) (elisp-princ val (*elisp-output-port*)))
        ((val stream) (elisp-princ val stream))
        ))

    (define princ* (make-parameter default-princ-impl))

    ))
