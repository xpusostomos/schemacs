(define-library (schemacs font)
  ;; GNU Emacs's `src/font.c`, of which this tree has one function: the
  ;; one an external package asks a frame about its fonts.
  ;;
  ;; **The departure is the driver layer.** The C keeps a list of font
  ;; drivers on the frame and calls each one's `list_family` hook; here
  ;; the frame's display object answers the question as a display
  ;; generic (`display-font-families`, `dispnew.sld`), because the fonts
  ;; of a frame are a fact about the frame's display and this tree has
  ;; exactly one font stack per front end - Pango on Gtk, none on a
  ;; terminal.

  (import (scheme base)
          (only (schemacs frame) selected-frame frame-output)
          (only (schemacs dispnew) display-font-families))

  (export font-family-list)

  (begin

    (define (font-family-list . args)
      ;; GNU Emacs's `font-family-list` (`font.c:4442`): "List available
      ;; font families on the current frame. If FRAME is omitted or nil,
      ;; the selected frame is used." The answer is a list of family
      ;; names as strings, as the C's `SYMBOL_NAME` makes them.
      ;;--------------------------------------------------------------
      (let ((frame (if (and (pair? args) (car args))
                       (car args)
                       (selected-frame))))
        ;; `FRAME_FONT_DRIVER_LIST` of a frame with no window system is
        ;; empty, and the C's loop then answers nil. A frame with no
        ;; display object - no editor is running, as in a batch script -
        ;; has no driver either.
        (let ((display (and frame (frame-output frame))))
          (if display
              (display-font-families display)
              '()))))
  ))
