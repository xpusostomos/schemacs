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
  ;; another. That is why the terminal front end needs no counterpart.
  ;;
  ;; **The renderer reads the face.** That was the half missing when the
  ;; command first landed: the Gtk front end drew at a constant, so
  ;; setting `:height' changed a record and no pixels. `pgtk.sld`'s
  ;; `pgtk-ensure-font!' is now Emacs's `realize_default_face' plus
  ;; `x_new_font' - it works out the pixel size from this face's
  ;; `:height' and takes the cell's measurements from the font that comes
  ;; back - so the command changes the text size for real, and
  ;; `pgtk-tests.scm` measures that in pixels.
  ;;
  ;; **Both halves are here.** The global command has its continuation
  ;; keys (a transient map, which `(schemacs editor keyboard)`'s
  ;; `set-transient-map` is) and its four `C-x C-M-` bindings; and the
  ;; *buffer-local* half - `face-remapping-alist`, the add/remove/set-base
  ;; family, and `text-scale-mode` with `text-scale-adjust`, `-set`,
  ;; `-increase` and `-decrease` on `C-x C-`, `C-x C-=`, `C-x C--` and
  ;; `C-x C-0`.
  ;;
  ;; The remapping is read where Emacs reads it: `xfaces.sld`'s
  ;; `merge-face-ref` consults the buffer's `face-remapping-alist` when it
  ;; realizes a face name, and `xdisp.sld`'s `render-window!` makes the
  ;; window's buffer current while it draws - `set_buffer_internal` in
  ;; `redisplay_window`.
  ;;
  ;; **`global-text-scale-adjust-resizes-frames` works.** The command
  ;; binds `frame-inhibit-implied-resize` around the face change, exactly
  ;; as Emacs does, and `pgtk.sld`'s font realization ends with
  ;; `x_new_font`'s `adjust_frame_size` call - so with the option off the
  ;; frame keeps its pixels, and with it on the frame grows to keep its
  ;; rows and columns.
  ;;
  ;; Not carried: `set-transient-map`'s MESSAGE ("Use %k for further
  ;; adjustment"), which needs `map-keymap`, `format-spec` and
  ;; `substitute-command-keys`; and `text-scale-pinch`, which needs a
  ;; `pinch` event - there is no touch input here.
  ;;
  ;; **One departure, and it is the renderer's**: Emacs gives every glyph
  ;; row its own height, so scaling one buffer leaves other windows
  ;; alone. `pgtk-ensure-font!` merges the default face of the buffer
  ;; being edited and draws the whole frame at that size, so a buffer's
  ;; scale is the frame's. Closing that needs per-window row heights - a
  ;; renderer of its own.

  (import
    (scheme base)
    ;; `sort' is Guile's - `(sort LIST LESS?)' - and `last-pair' is
    ;; srfi-1's.
    (only (guile) log sort)
    (only (srfi srfi-1) last-pair)
    (only (schemacs editor faces)
          face-attribute face-attribute-relative-p set-face-attribute)
    (only (schemacs editor xfaces)
          attribute-value face-attributes-empty merge-face-ref)
    ;; `face-remapping-alist' is a buffer-local, so it is read and
    ;; written through the buffer's own slots.
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!)
    ;; `text-scale-min-amount' and `-max-amount' are bounded by the
    ;; frame's pixel geometry - `frame.c''s `frame-char-height' and
    ;; `frame-char-width', and `frame.el''s `display-pixel-width'.
    (only (schemacs editor frame)
          *frame-inhibit-implied-resize* display-graphic-p frame-char-height
          frame-char-width display-pixel-width)
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor easy-mmode) define-minor-mode)
    ;; `current-prefix-arg` and `uarg->integer` are `define-minor-mode`'s:
    ;; the interactive form it generates reads them, and an interactive
    ;; expression is evaluated in the *defining* library's module.
    (only (schemacs editor command) define-command *last-command-event*
          current-prefix-arg uarg->integer)
    ;; The key's *basic type* - the character with every modifier
    ;; stripped - which is what Emacs's `pcase' over `last-command-event'
    ;; tests: `C-M-+' and `+' are the same adjustment.
    (only (schemacs editor character) event-basic-type kbd)
    ;; The continuation keys, which are Emacs's `set-transient-map': the
    ;; next key is looked up here first, so `+' after the command adjusts
    ;; again without a prefix chord.
    (only (schemacs editor keymap) define-key *default-keymap*)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor keyboard) set-transient-map)
    ;; `redisplay' with FORCE is this tree's `redisplay-frames!', the
    ;; redisplay the command loop calls - there is no separate name.
    (only (schemacs editor xdisp)
          force-mode-line-update redisplay-frames!)
    (only (schemacs editor window) force-window-update))


  (export
   global-text-scale-adjust
   global-text-scale-adjust-limits
   global-text-scale-adjust-resizes-frames
   global-text-scale-adjust--default-height
   global-text-scale-adjust--increment-factor
   ;; the buffer-local half
   face-remapping-alist face-remap-add-relative face-remap-remove-relative
   face-remap-set-base face-remap-reset-base face-remap-order
   face-attrs-more-relative-p internal-lisp-face-attributes
   text-scale-mode text-scale-mode-step
   text-scale-mode-variable set!text-scale-mode-variable!
   text-scale-mode-amount text-scale-mode-lighter
   text-scale-remap-header-line
   text-scale-adjust text-scale-increase text-scale-decrease text-scale-set
   text-scale-min-amount text-scale-max-amount)

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

When you invoke this command, it performs the initial change of the
font size, and after that allows further changes by typing one of the
following keys immediately after invoking the command:

   `+' , `='   Globally increase the height of the default face
   `-'      Globally decrease the height of the default face
   `0'      Globally reset the height of the default face

\(The change of the font size produced by these keys depends on the
final component of the key sequence, with all modifiers removed.)

The variable `global-text-scale-adjust-resizes-frames' controls
whether the frames are resized to keep the same number of lines
and characters per line when the font size is adjusted."
      (interactive "p")
      (when (display-graphic-p)
        ;; **The height the command reads is the height it can
        ;; arithmetic on**, so an unset face is given one first - the
        ;; size of the font already open, which is `set_lface_from_font`'s
        ;; rule and what a graphic display's `realize_default_face`
        ;; always ends up with. A face with no `:height` is
        ;; `unspecified`, and adding an increment to that is the bug this
        ;; avoids: `Wrong type argument in position 1: unspecified`.
        ;;
        ;; **A departure, and it is honest**: Emacs never gets here with
        ;; an unset face, because its `x-create-frame' always realizes the
        ;; default face before a command can run. This tree has no such
        ;; step for a display made by hand, which is how a test makes one.
        (when (not (number? (face-attribute 'default ':height)))
          (set-face-attribute 'default #f ':height
                              (frame-char-height)))
        (unless global-text-scale-adjust--default-height
          (set! global-text-scale-adjust--default-height
                (face-attribute 'default ':height)))
        (let* ((key (event-basic-type (*last-command-event*)))
               (cur (face-attribute 'default ':height))
               (inc (%adjust-increment (or increment 1) key))
               (limits (global-text-scale-adjust-limits))
               (new (+ cur inc)))
          (when (< (car limits)
                   new
                   (cdr limits))
            ;; **`frame-inhibit-implied-resize' is what makes the
            ;; option work**, exactly as Emacs binds it round the two
            ;; calls: "The variable `global-text-scale-adjust-resizes-
            ;; frames' controls whether the frames are resized to keep
            ;; the same number of lines and characters per line". With it
            ;; inhibited, `x_new_font' changes the cell and leaves the
            ;; frame's pixels alone - so the frame holds fewer rows. With
            ;; it clear, `adjust_frame_size' keeps the row and column
            ;; count by growing the frame, `Qfont`'s inhibit of 3.
            (let ((*frame-inhibit-implied-resize*
                   (if (global-text-scale-adjust-resizes-frames) #f #t)))
              (set-face-attribute 'default #f ':height new)
              (redisplay-frames!))
            ;; "If the display cannot honour the step, widen it" - the C
            ;; re-runs the command with a bigger factor rather than
            ;; leaving the user pressing a key that does nothing.
            (when (and (not (and (char? key) (char=? key #\0)))
                       (= cur (face-attribute 'default ':height)))
              (set! global-text-scale-adjust--increment-factor
                    (+ 1 global-text-scale-adjust--increment-factor))
              (global-text-scale-adjust increment)))
          ;; **The continuation keys.** Emacs installs a transient map
          ;; holding `+', `=' and `-' - plain and `C-M-' - each bound to
          ;; this command, so the key after an adjustment adjusts again
          ;; without a prefix chord. It is installed only when the key
          ;; that invoked the command was a character, which is why the
          ;; `key' above is the *basic type*: `C-M-+' and `+' are one
          ;; adjustment, and `M-x global-text-scale-adjust' - whose event
          ;; is the RET that ran it - gets no continuation keys at all.
          ;;
          ;; Emacs installs this inside the `let*' and passes a MESSAGE
          ;; ("Use %k for further adjustment") that `set-transient-map'
          ;; renders with `map-keymap', `key-description' and
          ;; `substitute-command-keys'. That message is not carried - see
          ;; the file header.
          (when (char? key)
            (set-transient-map global-text-scale-adjust-map #f #f))))
      #f)

    (define global-text-scale-adjust-map
      ;; The map `global-text-scale-adjust' installs after adjusting -
      ;; Emacs's `make-sparse-keymap' with its twelve bindings. Defined
      ;; after the command because a binding is a command's *value*.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*global-text-scale-adjust-map*)))
        (for-each
         (lambda (prefix)
           (for-each (lambda (key)
                       (define-key map (kbd (string-append prefix key))
                                   global-text-scale-adjust))
                     '("+" "=" "-" "0")))
         '("" "C-M-"))
        map))

    ;; `face-remap.el`'s own four `;;;###autoload' key definitions, which
    ;; is how this command is reached: `C-x C-M-+', `C-x C-M-=',
    ;; `C-x C-M--' and `C-x C-M-0'.
    ;;
    ;; Emacs writes them as `(define-key ctl-x-map [(control meta ?+)])
    ;; ...)'. This tree has no `ctl-x-map' - every `C-x' binding goes
    ;; straight into the global map as a multi-key sequence, which is what
    ;; `(define-key ... (kbd "C-x 4 f"))' does elsewhere - so they are
    ;; spelled in full.
    (define-key *default-keymap* (kbd "C-x C-M-+") global-text-scale-adjust)
    (define-key *default-keymap* (kbd "C-x C-M-=") global-text-scale-adjust)
    (define-key *default-keymap* (kbd "C-x C-M--") global-text-scale-adjust)
    (define-key *default-keymap* (kbd "C-x C-M-0") global-text-scale-adjust)

    ;;----------------------------------------------------------------
    ;; `face-remapping-alist' - the buffer-local half of this file
    ;;
    ;; An entry is `(FACE SPEC ...)'. The specs are merged left to right,
    ;; so the last one wins, as in a `face' text property's list of
    ;; faces; and the global definition of FACE is the lowest priority
    ;; unless `face-remap-set-base' replaced it. `xfaces.sld''s
    ;; `merge-face-ref' is what reads an entry when a face is realized.
    ;;
    ;; **`face-remapping-alist' is a function here, not a variable.**
    ;; Emacs's is a `defvar` that each buffer makes local; this tree's
    ;; buffer-locals are a per-buffer table keyed by a symbol, so the
    ;; reader is a procedure that asks the current buffer. Setting it is
    ;; `set-buffer-local-value!', which the functions below do.
    ;;------------------------------------------------------------------

    (define (face-remapping-alist)
      ;; The current buffer's alist, or `()' when it has none - which is
      ;; also Emacs's global value.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if buffer
            (buffer-local-value buffer 'face-remapping-alist '())
            '())))

    (define (set-face-remapping-alist! alist)
      (set-buffer-local-value! (current-buffer) 'face-remapping-alist alist)
      alist)

    (define internal-lisp-face-attributes
      ;; GNU Emacs's `internal-lisp-face-attributes'
      ;; (`face-remap.el:70'): the attributes in `LFACE_VECTOR' order,
      ;; with `#f' where the C vector has nil and without its trailing
      ;; `:vector' guard. `:font', `:fontset' and `:distant-foreground'
      ;; are not attributes this tree defines - nothing sets them, so
      ;; nothing counts them - and they are kept in the list for the
      ;; order's sake.
      ;;--------------------------------------------------------------
      '(#f
        :family :foundry :width :height :weight :slant :underline
        :inverse-video :foreground :background :stipple :overline
        :strike-through :box :font :inherit :fontset
        :distant-foreground :extend))

    (define (%face-attrs-vector attrs)
      ;; GNU Emacs's `face-attributes-as-vector' (`xfaces.c:5408'): a
      ;; reference to a face or faces merged into an empty attribute set.
      ;; Emacs answers a vector; here the merge's own answer *is* the set.
      ;;--------------------------------------------------------------
      (if attrs
          (merge-face-ref attrs (face-attributes-empty))
          (face-attributes-empty)))

    (define (%relative-attribute-count attrs)
      (let loop ((names internal-lisp-face-attributes) (n 0))
        (cond ((null? names) n)
              ((and (car names)
                    (face-attribute-relative-p
                     (car names) (attribute-value attrs (car names))))
               (loop (cdr names) (+ n 1)))
              (else (loop (cdr names) n)))))

    (define (face-attrs-more-relative-p attrs1 attrs2)
      ;; GNU Emacs's `face-attrs-more-relative-p': whether ATTRS1 has
      ;; more relative attributes than ATTRS2 - the sort predicate
      ;; `face-remap-order' puts the absolute remappings first with, so
      ;; that a relative one (a scale factor) applies on top of them.
      ;;--------------------------------------------------------------
      (< (%relative-attribute-count (%face-attrs-vector attrs1))
         (%relative-attribute-count (%face-attrs-vector attrs2))))

    (define (face-remap-order entry)
      ;; GNU Emacs's `face-remap-order': ENTRY with its specs sorted so
      ;; that the more relative ones come later. The base spec is last
      ;; and is not sorted - it is the face's own definition, which every
      ;; relative spec is relative *to*.
      ;;--------------------------------------------------------------
      (let* ((reversed (reverse entry))
             (sorted (cons (car reversed)
                           (sort (cdr reversed) face-attrs-more-relative-p))))
        (reverse sorted)))

    (define (face-remap-add-relative face . specs)
      ;; GNU Emacs's `face-remap-add-relative': add SPECS as a remapping
      ;; of FACE in this buffer, and answer a cookie for
      ;; `face-remap-remove-relative'.
      ;;--------------------------------------------------------------
      ;; "The remaining arguments, SPECS, should form a list of faces" -
      ;; one already-wrapped list is unwrapped, which is what Emacs's own
      ;; `(while (and (consp specs) (null (cdr specs))) ...)' does.
      (let loop ((specs specs))
        (if (and (pair? specs) (null? (cdr specs)))
            (loop (car specs))
            (begin
              (let ((entry (assq face (face-remapping-alist))))
                (unless entry
                  ;; "explicitly merge with global def": the base is the
                  ;; face itself.
                  (set! entry (list face face))
                  (set-face-remapping-alist!
                   (cons entry (face-remapping-alist))))
                (let ((faces (cdr entry)))
                  (when (symbol? faces) (set! faces (list faces)))
                  (set-cdr! entry (face-remap-order (cons specs faces)))
                  (force-mode-line-update)))
              (cons face specs)))))

    (define (remq item list)
      ;; GNU Emacs's `remq': LIST without the elements `eq?' to ITEM -
      ;; and **the same object** when there was nothing to remove, which
      ;; `face-remap-remove-relative' tests with `eq?'.
      ;;--------------------------------------------------------------
      (cond ((null? list) list)
            ((eq? (car list) item) (remq item (cdr list)))
            (else (let ((rest (remq item (cdr list))))
                    (if (eq? rest (cdr list)) list (cons (car list) rest))))))

    (define (face-remap-remove-relative cookie)
      ;; GNU Emacs's `face-remap-remove-relative': remove what
      ;; `face-remap-add-relative' added, and answer the spec that was
      ;; removed.
      ;;--------------------------------------------------------------
      (let ((remapping (assq (car cookie) (face-remapping-alist))))
        (when remapping
          (let ((updated (remq (cdr cookie) (cdr remapping))))
            (unless (eq? updated (cdr remapping))
              (set-cdr! remapping updated)
              (when (or (null? updated)
                        (and (eq? (car updated) (car cookie))
                             (null? (cdr updated))))
                (set-face-remapping-alist!
                 (remq remapping (face-remapping-alist)))
                (force-mode-line-update))
              (cdr cookie))))))

    (define (face-remap-reset-base face)
      ;; GNU Emacs's `face-remap-reset-base': make FACE's base remapping
      ;; its normal definition again, leaving any relative ones on top.
      ;;--------------------------------------------------------------
      (let ((entry (assq face (face-remapping-alist))))
        (when entry
          ;; Nothing but a base: the whole entry is the base, so it goes.
          (if (null? (cddr entry))
              (set-face-remapping-alist!
               (remq entry (face-remapping-alist)))
              (set-car! (last-pair entry) face))
          (force-mode-line-update))))

    (define (face-remap-set-base face . specs)
      ;; GNU Emacs's `face-remap-set-base': the base SPECS for FACE, in
      ;; place of its global definition. With no specs, or with FACE
      ;; itself as the only one, that is `face-remap-reset-base'.
      ;;--------------------------------------------------------------
      (let loop ((specs specs))
        (if (and (pair? specs) (not (null? (car specs))) (null? (cdr specs)))
            (loop (car specs))
            (if (or (null? specs) (eq? specs face))
                (face-remap-reset-base face)
                (let ((entry (assq face (face-remapping-alist))))
                  (if entry
                      (set-car! (last-pair entry) specs)
                      (set-face-remapping-alist!
                       (cons (list face specs) (face-remapping-alist))))
                  (force-mode-line-update))))))

    ;;----------------------------------------------------------------
    ;; text-scale-mode
    ;;------------------------------------------------------------------

    (define-custom text-scale-mode-step 1.2
      "Scale factor used by `text-scale-mode`.
Each positive or negative step scales the size of the `default'
face's font by this amount."
      :type 'number
      :group 'display
      :version "23.1")

    (define (text-scale-mode-lighter)
      ;; `text-scale-mode-lighter`, a buffer-local: the lighter the mode
      ;; line shows, as `+0`, `+2` or `-1`.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'text-scale-mode-lighter "+0"))

    (define (set!text-scale-mode-lighter value)
      (set-buffer-local-value! (current-buffer) 'text-scale-mode-lighter value))

    (define (text-scale-mode-amount)
      ;; `text-scale-mode-amount`, a buffer-local: how many steps the
      ;; scaling is up or down.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'text-scale-mode-amount 0))

    (define (set!text-scale-mode-amount value)
      (set-buffer-local-value! (current-buffer) 'text-scale-mode-amount value))

    (define (text-scale-remap-header-line)
      ;; `text-scale-remap-header-line`, a buffer-local: whether the
      ;; header line is scaled too.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'text-scale-remap-header-line #f))

    (define (face-remap--clear-remappings)
      ;; GNU Emacs's `face-remap--clear-remappings': remove every
      ;; remapping `text-scale-mode' added, so that turning the mode on
      ;; again starts from the face's own definition.
      ;;--------------------------------------------------------------
      (for-each face-remap-remove-relative
                (buffer-local-value (current-buffer)
                                    'text-scale-mode-remapping '()))
      (set-buffer-local-value! (current-buffer) 'text-scale-mode-remapping '()))

    (define (face-remap--remap-face sym)
      ;; GNU Emacs's `face-remap--remap-face': a *relative* `:height' of
      ;; `(text-scale-mode-step ^ amount)' - a scale factor, which
      ;; `merge-face-vectors'' `:height' merge multiplies the face's own
      ;; height by.
      ;;--------------------------------------------------------------
      (set-buffer-local-value!
       (current-buffer) 'text-scale-mode-remapping
       (cons (face-remap-add-relative
              sym
              ':height
              (expt (text-scale-mode-step) (text-scale-mode-amount)))
             (buffer-local-value (current-buffer)
                                 'text-scale-mode-remapping '()))))

    (define-minor-mode text-scale-mode
      "Minor mode for displaying buffer text in a larger/smaller font.

The amount of scaling is determined by the variable
`text-scale-mode-amount': one step scales the global default
face size by the value of the variable `text-scale-mode-step'
\(a negative amount shrinks the text).

The `text-scale-increase', `text-scale-decrease', and
`text-scale-set' functions may be used to interactively modify
the variable `text-scale-mode-amount' (they also enable or
disable `text-scale-mode' as necessary)."
      :lighter (" " text-scale-mode-lighter)
      (face-remap--clear-remappings)
      (set!text-scale-mode-lighter
       (string-append (if (>= (text-scale-mode-amount) 0) "+" "")
                      (number->string (text-scale-mode-amount))))
      (when (text-scale-mode-variable)
        (face-remap--remap-face 'default)
        (when (text-scale-remap-header-line)
          (face-remap--remap-face 'header-line)))
      (force-window-update (current-buffer)))

    (define (text-scale-min-amount)
      ;; GNU Emacs's `text-scale-min-amount': "When the resulting
      ;; pixel-height of characters will become smaller than 1 pixel, we
      ;; can expect trouble from the display engine."
      ;;--------------------------------------------------------------
      ;; Emacs's `(log X BASE)'; Guile's `log' takes one argument, and
      ;; the base change is the same arithmetic.
      (/ (log (/ 1.0 (frame-char-height))) (log (text-scale-mode-step))))

    (define (text-scale-max-amount)
      ;; GNU Emacs's `text-scale-max-amount': the display engine uses a
      ;; 16-bit short for a glyph's pixel width, hence 0xffff.
      ;;--------------------------------------------------------------
      (/ (log (/ (min (display-pixel-width) #xffff) (frame-char-width)))
         (log (text-scale-mode-step))))

    (define-command (text-scale-set level)
      "Set the scale factor of the default face in the current buffer to LEVEL.
If LEVEL is non-zero, `text-scale-mode' is enabled, otherwise it is disabled.

LEVEL is a number of steps, with 0 representing the default size.
Each step scales the height of the default face by the variable
`text-scale-mode-step' (a negative number decreases the height by
the same amount)."
      (interactive "p")
      ;; Emacs's `(max (min level (text-scale-max-amount))
      ;; (text-scale-min-amount))', spelled out: Guile's `min' and `max'
      ;; answer an *inexact* result when any argument is inexact, and
      ;; Emacs's answer one of their arguments - so a level inside the
      ;; range stays the integer the prefix argument gave, and the
      ;; lighter reads `+3` rather than `+3.0`.
      (set!text-scale-mode-amount
       (let ((level (if (> level (text-scale-max-amount))
                        (text-scale-max-amount)
                        level)))
         (if (< level (text-scale-min-amount))
             (text-scale-min-amount)
             level)))
      (text-scale-mode (if (zero? (text-scale-mode-amount)) -1 1))
      #f)

    (define-command (text-scale-increase inc)
      "Increase the font size of the default face in current buffer by INC steps.
If the new height is other than the default, `text-scale-mode' is enabled.

Each step scales the height of the default face by the variable
`text-scale-mode-step' (a negative number of steps decreases the
height by the same amount).  As a special case, an argument of 0
will remove any scaling currently active."
      (interactive "p")
      (let* ((current-value (if (text-scale-mode-variable)
                                (text-scale-mode-amount)
                                0))
             (new-value (if (= inc 0) 0 (+ current-value inc))))
        (if (or (> new-value (text-scale-max-amount))
                (< new-value (text-scale-min-amount)))
            (error "Cannot ~a the font size any further"
                   (if (> inc 0) "increase" "decrease")))
        (set!text-scale-mode-amount new-value))
      (text-scale-mode (if (zero? (text-scale-mode-amount)) -1 1))
      #f)

    (define-command (text-scale-decrease dec)
      "Decrease the font size of the default face in current buffer by DEC steps.
See `text-scale-increase' for more details."
      (interactive "p")
      (text-scale-increase (- dec))
      #f)

    (define-command (text-scale-adjust inc)
      "Adjust the font size in the current buffer by INC steps.
Interactively, INC is the prefix numeric argument, and defaults to 1.

The actual adjustment made depends on the final component of the
keybinding used to invoke the command, with all modifiers removed:

   `+', `='   Increase font size in current buffer by one step
   `-'      Decrease font size in current buffer by one step
   `0'      Reset the font size to the global default

After adjusting, continue to read input events and further adjust
the font size as long as the input event (with all modifiers removed)
is one of the above characters.

Each step scales the height of the default face by the factor that
is the value of `text-scale-mode-step' (a negative number of steps
decreases the height by that factor).  As a special case, an argument
of 0 will remove any scaling currently active."
      (interactive "p")
      (let* ((base (event-basic-type (*last-command-event*)))
             (step (cond ((or (eqv? base #\+) (eqv? base #\=)) (or inc 1))
                         ((eqv? base #\-) (- (or inc 1)))
                         ((eqv? base #\0) 0)
                         (else (or inc 1)))))
        (text-scale-increase step)
        ;; The continuation keys: `+', `=' and `-' - plain and `C-', each
        ;; running the adjust again with the *sign* of the original
        ;; argument, so a repeated key does not flip the direction of a
        ;; prefixed one.
        (set-transient-map
         (let ((map (km:keymap '*text-scale-adjust-map*)))
           (for-each
            (lambda (mods)
              (for-each (lambda (key)
                          (define-key map (kbd (string-append mods key))
                                      (lambda () (text-scale-adjust (abs (or inc 1))))))
                        '("+" "=" "-" "0")))
            '("" "C-"))
           map)
         #f
         #f))
      #f)

    ;; `face-remap.el`'s own four `;;;###autoload' key definitions for
    ;; `text-scale-adjust', spelled in full as the global ones above are.
    (define-key *default-keymap* (kbd "C-x C-+") text-scale-adjust)
    (define-key *default-keymap* (kbd "C-x C-=") text-scale-adjust)
    (define-key *default-keymap* (kbd "C-x C--") text-scale-adjust)
    (define-key *default-keymap* (kbd "C-x C-0") text-scale-adjust)
    ))
