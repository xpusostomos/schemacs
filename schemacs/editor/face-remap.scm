(define-library (schemacs editor face-remap)
  ;; This library mirrors GNU Emacs's `face-remap.el' - the global text
  ;; scaling half of it. GNU Emacs has two ways to make the text bigger:
  ;; `text-scale-adjust', which scales one buffer's faces by a *factor*
  ;; (`text-scale-mode-step'), and `global-text-scale-adjust', which
  ;; changes the `default' face's height for every frame by an
  ;; *increment*, in units of 1/10 pt. This is the second.
  ;;
  ;; **It is graphic-only in Emacs, and it is here too**: the command is
  ;; wrapped in `(when (display-graphic-p) ...)', so on a terminal it does
  ;; nothing at all - a terminal has one font and cannot be asked for
  ;; another. That is why the ncurses front end needs no counterpart.
  ;;
  ;; **Departure, and the one that matters**: the Gtk front end takes its
  ;; font size from `pgtk.sld`'s `*font-size*' constant, not from the
  ;; `default' face's `:height', so setting the face changes the record
  ;; and not yet the pixels. `set-face-attribute' and `:height' are
  ;; ported (`faces.sld'), so the command is Emacs's; what is missing is
  ;; the renderer reading the face. Named here rather than papered over.
  ;;
  ;; Not carried: the continuation keys (`+'/`-'/`0' after the command,
  ;; which Emacs implements with a transient map and `read-event'), the
  ;; frame resizing `global-text-scale-adjust-resizes-frames' asks for,
  ;; and the whole buffer-local half of the file - `text-scale-mode',
  ;; `text-scale-adjust', `face-remap-add-relative' and the
  ;; `face-remapping-alist'.

  (import
    (scheme base)
    (only (schemacs editor faces) face-attribute set-face-attribute)
    (only (schemacs editor frame) display-graphic-p)
    (only (schemacs editor editfns) message)
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor command) define-command *last-command-event*)
    ;; `redisplay' with FORCE is this tree's `redisplay-frames!', the
    ;; redisplay the command loop calls - there is no separate name.
    (only (schemacs editor xdisp) redisplay-frames!))

  (export
   global-text-scale-adjust
   global-text-scale-adjust-limits
   global-text-scale-adjust-resizes-frames
   global-text-scale-adjust--default-height
   global-text-scale-adjust--increment-factor)

  (begin

    (define-custom global-text-scale-adjust-resizes-frames #f
      "Whether `global-text-scale-adjust' resizes the frames."
      :type 'boolean
      :group 'display
      :version "29.1")

    (define-custom global-text-scale-adjust-limits '(10 . 500)
      "Min/max values for `global-text-scale-adjust'.
This is a cons cell where the `car' has the minimum font size and
the `cdr' has the maximum font size, in units of 1/10 pt."
      :type 'cons
      :group 'display
      :version "29.1")

    ;; GNU Emacs's two `defvar's beside the command, and for the same
    ;; reason: the first is the height `0' goes back to, and the second
    ;; grows when the display cannot take a step, so a display that
    ;; rounds small changes still moves.
    (define global-text-scale-adjust--default-height #f)
    (define global-text-scale-adjust--increment-factor 5)

    (define (%adjust-increment increment key)
      ;; The C's `pcase' over the final key: `-' goes the other way, `0'
      ;; returns to the height first seen, anything else - including `=',
      ;; `+' and the command's own key - steps by INCREMENT.
      (cond ((eqv? key #\-)
             (* (- increment) global-text-scale-adjust--increment-factor))
            ((eqv? key #\0)
             (- global-text-scale-adjust--default-height
                (face-attribute 'default ':height)))
            (else
             (* increment global-text-scale-adjust--increment-factor))))

    (define-command (global-text-scale-adjust increment)
      "Change (a.k.a. \"adjust\") the font size of all faces by INCREMENT.

Interactively, INCREMENT is the prefix numeric argument, and defaults
to 1.  Positive values of INCREMENT increase the font size, negative
values decrease it.

The variable `global-text-scale-adjust-resizes-frames' controls
whether the frames are resized to keep the same number of lines
and characters per line when the font size is adjusted."
      (interactive "p")
      (when (display-graphic-p)
        (unless global-text-scale-adjust--default-height
          (set! global-text-scale-adjust--default-height
                (face-attribute 'default ':height)))
        (let* ((key (and (pair? (*last-command-event*))
                         (car (*last-command-event*))))
               (cur (face-attribute 'default ':height))
               (inc (%adjust-increment (or increment 1) key))
               (new (+ cur inc)))
          (when (< (car global-text-scale-adjust-limits)
                   new
                   (cdr global-text-scale-adjust-limits))
            (set-face-attribute 'default #f ':height new)
            (redisplay-frames!)
            ;; "If the display cannot honour the step, widen it" - the C
            ;; re-runs the command with a bigger factor rather than
            ;; leaving the user pressing a key that does nothing.
            (when (and (not (and (char? key) (char=? key #\0)))
                       (= cur (face-attribute 'default ':height)))
              (set! global-text-scale-adjust--increment-factor
                    (+ 1 global-text-scale-adjust--increment-factor))
              (global-text-scale-adjust increment)))))
      #f)
    ))
