(define-library (schemacs core warnings)
  ;; GNU Emacs's `lisp/emacs-lisp/warnings.el', of which this tree has
  ;; one function: the way a library tells the user that something it
  ;; did looks wrong.
  ;;
  ;; **The departure is the destination.** Emacs's `display-warning`
  ;; writes the message into a `*Warnings*' buffer with `warn' buttons
  ;; and obeys `warning-suppress-types', `warning-minimum-level' and the
  ;; rest of the warnings machinery; none of that is ported. What is
  ;; kept is the contract that matters to a caller - TYPE and MESSAGE,
  ;; with the message shown - delivered through `message`, which is
  ;; where this editor's notices already go (the echo area, and
  ;; `*Messages*' through `*message-log-function*').

  (import (scheme base)
          (only (schemacs editfns) message))

  (export display-warning)

  (begin

    (define %message message)
    ;; ^ `message` is ALSO the name of `display-warning''s second
    ;; parameter, and Emacs's argument order requires that name. A
    ;; parameter binding shadows the imported procedure, so the first
    ;; caller of this library - `omarchy--warn-unusable-height' - got
    ;; "Wrong type to apply: <the warning text>": `(message ...)` was
    ;; the string being called. Nothing had called `display-warning`
    ;; before it, which is how the two identical names survived.

    (define (display-warning type message . args)
      ;; GNU Emacs's `display-warning` (`warnings.el`): "Display a
      ;; warning message, MESSAGE. TYPE is the warning type: either a
      ;; custom group name (a symbol), or a list of symbols whose first
      ;; element is a custom group name."
      ;;
      ;; LEVEL and BUFFER-NAME are accepted and not consulted - there is
      ;; one *Warnings* destination here, the echo area, and no level
      ;; filtering. The text is Emacs's own rendering: the type, a
      ;; colon, and the message.
      ;;--------------------------------------------------------------
      (%message "%s: %s"
                (if (pair? type) (car type) type)
                message))))
