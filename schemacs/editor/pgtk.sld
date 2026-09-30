(define-library (schemacs editor pgtk)
  ;; This library mirrors the role of GNU Emacs's `src/pgtkterm.c': the
  ;; GTK display. `term.sld' is the text terminal's implementation of
  ;; `(schemacs editor dispnew)''s interface; this is the windowed one -
  ;; same generics, a different surface behind them, and nothing in the
  ;; editor changed to accommodate it. That is the point of the split.
  ;;
  ;; Two things about guile-gi shape this file, both measured rather than
  ;; guessed (GTK-PLAN.md records the experiments):
  ;;
  ;;   * The typelib surface is loaded into THIS module with
  ;;     `typelib->module', and only `<pgtk-display>' and
  ;;     `with-gtk-display' are exported. An R7RS `export' of the
  ;;     typelib's own names fails outright, so the names must stay
  ;;     private; that suits us anyway, since importing them wholesale
  ;;     shadows core bindings (it shadowed `begin').
  ;;   * `push-duplicate-handler!' must be called before any typelib
  ;;     generic is used. Without it every such call fails with a
  ;;     misleading "Too few \"in\" arguments" error.
  ;;
  ;; Drawing is done with guile-cairo, not guile-gi: guile-gi binds no
  ;; cairo primitives (no `move_to', `fill' or `paint'), while guile-cairo
  ;; has them all. The frame is drawn into an image surface we own; when
  ;; Gtk asks the drawing area for a repaint we paint that surface into
  ;; the context it hands us, wrapped as a guile-cairo context.
  ;;
  ;; Positions are pixels, and a character is one pixel - the same
  ;; degenerate case a text terminal is (`term.sld''s `column-width' is
  ;; 1). The editor's redisplay therefore works in cells as it always
  ;; has, and this file multiplies by a font metric to find the pixel.
  ;;
  ;; See GTK-PLAN.md for the plan this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (scheme write) display write)
    (only (guile) catch ash logand inexact->exact round
          get-internal-real-time internal-time-units-per-second)
    (oop goops)
    ;; The drawing primitives, which guile-gi does not bind.
    (cairo)
    ;; guile-gi, and only what is needed from it: `(gi)''s own `equal?'
    ;; and friends would collide with `(scheme base)''s.
    (gi)
    (gi repository)
    (only (gi) <signal>)
    (gi util)
    ;; The GTK surface, from the module that holds it: see pgtk-names.scm
    ;; for why it is not loaded here. `only' is required - the surface is
    ;; thousands of names and importing them wholesale shadows core
    ;; bindings.
    (only (schemacs editor pgtk-names)
          init-check! <GtkWindow> <GtkDrawingArea> <GtkContainer> <GtkWidget>
          widget:show-all widget:hide widget:destroy widget:queue-draw
          widget:can-focus widget:grab-focus widget:set-size-request
          widget:hexpand widget:vexpand window:resizable
          window:resize
          container:add
          connect main-iteration-do? set-prgname set-program-class
          modifier-type->number widget:get-allocated-width
          widget:get-allocated-height
          event:get-state event:get-keyval keyval-to-unicode)
    ;; The display interface this implements.
    (only (schemacs editor dispnew)
          <display> clear-frame-area! column-width current-display
          display-color-cells
          draw-window-cursor! flush-display! key-event->keymap-path
          line-height read-input-event realize-face resume-display!
          screen-size suspend-display! update-window-begin!
          update-window-end! write-glyphs!)
    ;; Opening a display initializes faces against it, as `term.sld''s
    ;; `with-terminal' does.
    (only (schemacs editor faces)
          *display-color-cells* *display-type* *frame-background-mode*
          *window-system* face-list face-spec-recalc)
    (only (schemacs editor xfaces) attribute-value)
    ;; How many cells a character takes - a CJK ideograph is one character
    ;; and two cells, so a run is not `string-length' wide.
    (only (schemacs editor disp-table) char-display-width)
    ;; The development back door. `poll-repl!' is a no-op unless
    ;; `main-gtk.scm' was asked to open it; this loop is the only place a
    ;; windowed editor is ever idle, so it is where the REPL gets its turn.
    (only (schemacs repl) poll-repl!)
    ;; A colour *name* means what `term/tty-colors.el' says it means.
    (only (schemacs editor tty-colors) tty-color-standard-values))

  (export
   <pgtk-display>
   with-gtk-display
   ;; What opening a display does to the face machinery, so a test can do
   ;; it to a display with no window and then read what it draws - which
   ;; is how the *colour* of a face is checked without an eye on it.
   ;; `term.sld''s `initialize-display-faces!' is the same thing for a
   ;; terminal, and is private for the same reason: only opening a
   ;; display should call it.
   initialize-pgtk-faces!
   ;; The blocking read, exported for tests that drive it without a
   ;; window; nothing in the editor uses it by name.
   pgtk-read-event
   pgtk-enqueue!
   ;; The current frame written to a PNG: how a windowed editor is
   ;; checked without a pair of eyes on it.
   pgtk-write-screenshot!
   ;; The window, so a test can push a synthetic key at it.
   pgtk-window
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The typelib surface, privately
    ;;------------------------------------------------------------------


    ;; Before any generic above is called. Without these two, every
    ;; typelib generic misresolves and fails with "Too few \"in\"
    ;; arguments" - an error that reads like an arity bug and is not.
    (push-duplicate-handler! 'merge-generics)
    (push-duplicate-handler! 'shrug-equals)

    ;;----------------------------------------------------------------
    ;; The metrics of one character
    ;;
    ;; A cell is one pixel as far as the interface is concerned, but a
    ;; real font needs a real box to draw in, so the driver keeps the
    ;; cell's size in pixels and multiplies. The font is monospace, so
    ;; one advance serves every character.
    ;;------------------------------------------------------------------

    (define *cell-width* 9)
    (define *cell-height* 18)
    (define *font-size* 15)

    (define (cell-x x) (* x *cell-width*))
    (define (cell-y y) (* y *cell-height*))

    ;;----------------------------------------------------------------
    ;; Faces
    ;;
    ;; `realize-face' answers a token the redisplay treats as opaque -
    ;; except that `xdisp.sld''s `line-end-fill-attribute' compares it
    ;; with `=', so it must be an INTEGER and 0 must mean "no face".
    ;; Faces are therefore interned to ids here, and the id's
    ;; attributes are kept beside it.
    ;;------------------------------------------------------------------

    (define (colour->rgb value)
      ;; A face colour as three cairo components, or #f when the face
      ;; does not name one. VALUE is a pixel integer, a colour name, or
      ;; the unspecified marker.
      ;;
      ;; A name is looked up in `term/tty-colors.el''s table - the same
      ;; table a terminal uses - rather than parsed here, because that is
      ;; where this editor already says what a colour name means.
      ;; `tty-color-standard-values' and not `tty-color-values': the
      ;; latter gives the *terminal's* rendering of a colour, which maps
      ;; `gray' to the palette's white.
      ;;--------------------------------------------------------------
      (cond
       ((integer? value)
        (list (/ (logand (ash value -16) 255) 255.0)
              (/ (logand (ash value -8) 255) 255.0)
              (/ (logand value 255) 255.0)))
       ((string? value)
        (let ((rgb (tty-color-standard-values value)))
          (and (list? rgb)
               (= 3 (length rgb))
               (map (lambda (c) (/ c 65535.0)) rgb))))
       (else #f)))

    (define (realize-face-token attrs)
      ;; ATTRS interned to an integer id, 0 for the plain face.
      ;;
      ;; `:inverse-video' is what a terminal draws the mode line and the
      ;; search match with - there is no colour on a monochrome terminal,
      ;; only swapped ones - so it is honoured by swapping the pair here.
      ;; With neither colour set the pair is black on white, and
      ;; inverting that gives white on black.
      ;;--------------------------------------------------------------
      (if (not attrs)
          0
          (let* ((foreground (colour->rgb (attribute-value attrs ':foreground)))
                 (background (colour->rgb (attribute-value attrs ':background)))
                 (inverse (eq? #t (attribute-value attrs ':inverse-video)))
                 (bold (eq? #t (attribute-value attrs ':bold)))
                 (underline (eq? #t (attribute-value attrs ':underline)))
                 (fg (if inverse (or background (list 1.0 1.0 1.0))
                         (or foreground (list 0.0 0.0 0.0))))
                 (bg (if inverse (or foreground (list 0.0 0.0 0.0))
                         background))
                 (key (list fg bg bold underline)))
            (if (and (equal? fg (list 0.0 0.0 0.0))
                     (not bg) (not bold) (not underline))
                0
                (let ((found (assoc key (*face-table*))))
                  (if found
                      (cdr found)
                      (let ((id (+ 1 (length (*face-table*)))))
                        (*face-table* (append (*face-table*)
                                              (list (cons key id))))
                        id)))))))

    (define *face-table* (make-parameter '()))
    ;; ^ `((KEY . ID) ...)`, id 0 meaning the plain face.

    (define (face-entry token)
      ;; The interned attributes for TOKEN, or #f. TOKEN may be #f or 0,
      ;; which the redisplay uses to mean "the display's own appearance"
      ;; - it is not an id, so there is no entry for it.
      ;;--------------------------------------------------------------
      (and (integer? token)
           (let loop ((lst (*face-table*)))
             (cond ((null? lst) #f)
                   ((= (cdr (car lst)) token) (car lst))
                   (else (loop (cdr lst)))))))

    (define (face-token-part token n)
      ;; Component N of TOKEN's `(FOREGROUND BACKGROUND BOLD UNDERLINE)'.
      ;; The table holds `(KEY . ID)`, so the key is taken first.
      ;;--------------------------------------------------------------
      (let ((found (face-entry token)))
        (and found (list-ref (car found) n))))

    (define (face-token-foreground token) (face-token-part token 0))
    (define (face-token-background token) (face-token-part token 1))

    ;;----------------------------------------------------------------
    ;; Keys
    ;;
    ;; The rule is Emacs's `xg_widget_key_press_event_cb'
    ;; (gtkutil.c:6520): a keysym that `keyval_to_unicode' maps to a
    ;; character is a character event, and everything else - the cursor
    ;; keys, function keys, the keypad - is an event whose code is the
    ;; keysym, which `key-event->keymap-path' then names.
    ;;
    ;; The modifiers are `pgtk_gtk_to_emacs_modifiers' (pgtkterm.c:5157):
    ;; note that Mod1 is META, not alt.
    ;;------------------------------------------------------------------

    (define named-keysyms
      ;; The keysyms this editor's keymaps have names for, as
      ;; `(KEYSYM . NAME)'. The rest are left unhandled, which is what
      ;; Emacs does with a key it has no name for.
      ;;--------------------------------------------------------------
      (list (cons #xff51 "left")   (cons #xff53 "right")
            (cons #xff52 "up")     (cons #xff54 "down")
            (cons #xff50 "home")   (cons #xff57 "end")
            (cons #xff55 "prior")  (cons #xff56 "next")
            (cons #xffff "delete") (cons #xff63 "insert")))

    (define (modifier-symbols state)
      ;; The modifier symbols of a GDK modifier state, in the order
      ;; `key-event->keymap-path' builds its paths in. The masks are
      ;; Gdk's: SHIFT 1, CONTROL 4, MOD1 8, SUPER 1<<26, HYPER 1<<27,
      ;; META 1<<28. Note that MOD1 means META here, as Emacs has it in
      ;; `pgtk_gtk_to_emacs_modifiers' - not alt.
      ;;--------------------------------------------------------------
      (let ((bits (if (integer? state) state 0)))
        (define (set? mask) (not (= 0 (logand bits mask))))
        ;; Shift is deliberately dropped: `(schemacs keymap)' has no shift
        ;; modifier - `modifier->integer' takes only ctrl/meta/super/hyper/
        ;; alt - so a shifted key must be reported without it or the lookup
        ;; fails with "unknown keymap-index modifier symbol". The keysym
        ;; already carries the case (shift+a arrives as `A'), and the
        ;; terminal drops shift the same way: `named-key-modifiers' in
        ;; term.sld answers #f for the shift variants.
        (append (if (set? (ash 1 26)) (list 'super) '())
                (if (set? (ash 1 27)) (list 'hyper) '())
                (if (or (set? (ash 1 28)) (set? 8)) (list 'meta) '())
                (if (set? 4) (list 'ctrl) '()))))

    (define (character-path c)
      ;; The key sequence for a character. A control character is
      ;; `C-<letter>`, which is the ASCII protocol a terminal obeys:
      ;; `ncurses-key->keymap-path' in `term.sld' folds the same way, and
      ;; the two must agree because the keymaps are the same. This is
      ;; what makes RET (`#\\return`, code 13) the `C-m' the keymap binds
      ;; to `newline' rather than a literal carriage return.
      ;;--------------------------------------------------------------
      (let ((ci (char->integer c)))
        (cond
         ((char=? c #\return) (list 'ctrl #\m))
         ((char=? c #\newline) (list 'ctrl #\j))
         ((char=? c #\esc) (list 'ctrl #\[))
         ((or (= ci 127) (char=? c #\backspace)) (list 'ctrl #\h))
         ((= ci 0) (list 'ctrl #\@))
         ((and (< 0 ci) (< ci 27)) (list 'ctrl (integer->char (+ 96 ci))))
         ((and (>= ci 28) (< ci 32)) (list 'ctrl (integer->char ci)))
         (else (list c)))))

    (define (key-event->path ev)
      ;; The keymap path for one of this display's key events: a
      ;; character, or a named key's string.
      ;;--------------------------------------------------------------
      (let ((keysym (cdr ev))
            (mods (modifier-symbols (car ev))))
        (if (< keysym 256)
            ;; A plain ASCII keysym is the character itself.
            (append mods (character-path (integer->char keysym)))
            (let* ((unicode (keyval-to-unicode keysym))
                   (named (assoc keysym named-keysyms)))
              (cond
               (named (append mods (list (cdr named))))
               ((and unicode (> unicode 0))
                (append mods (character-path (integer->char unicode))))
               (else #f))))))

    ;;----------------------------------------------------------------
    ;; The display
    ;;------------------------------------------------------------------

    (define-class <pgtk-display> (<display>)
      (window  #:init-value #f #:accessor pgtk-window)
      ;; The drawing area: the widget Gtk asks for a repaint, and the
      ;; widget whose allocation is the size the display draws at.
      (area    #:init-value #f #:accessor pgtk-area)
      (surface #:init-value #f #:accessor pgtk-surface)
      (cr      #:init-value #f #:accessor pgtk-cr)
      ;; The grid, in character cells: what the redisplay thinks the
      ;; display is, and what `screen-size' answers.
      (columns #:init-value 80 #:accessor pgtk-columns)
      (rows    #:init-value 24 #:accessor pgtk-rows)
      ;; The allocation in PIXELS to use when there is no widget to ask -
      ;; a display opened without a window, as a test does. With a widget,
      ;; `pgtk-allocation' asks it and these are never consulted.
      (pixel-width #:init-value 720 #:accessor pgtk-pixel-width)
      (pixel-height #:init-value 432 #:accessor pgtk-pixel-height)
      ;; Input events the signal handler has collected.
      (queue   #:init-value '() #:accessor pgtk-queue)
      ;; The last allocation a redraw was asked for, so an unchanged one
      ;; does not ask again - which it otherwise does on every frame,
      ;; and redraws forever.
      (last-allocation #:init-value #f #:accessor pgtk-last-allocation)
      ;; The pixel size the surface was last DRAWN at, so the read can
      ;; tell when what is on screen no longer matches the window.
      (drawn-size #:init-value #f #:accessor pgtk-drawn-size))

    (define (pgtk-enqueue! d ev)
      ;; Put an input event on the display's queue, where the blocking
      ;; read will find it. The signal handler calls this.
      ;;--------------------------------------------------------------
      (set! (pgtk-queue d) (append (pgtk-queue d) (list ev))))

    (define modifier-keysyms
      ;; The keysyms of the modifier keys themselves. Pressing one is not
      ;; a key this editor can act on, and Emacs never sees one at all -
      ;; a terminal, and a window system, consume them. Gtk delivers
      ;; them, so they are dropped here; otherwise every shift press is
      ;; reported as "unhandled event: 65515" (`0xffeb', Shift_L), which
      ;; is what the compositor sends when the window takes focus.
      ;;--------------------------------------------------------------
      (list #xffe1 #xffe2   ; Shift_L, Shift_R
            #xffe3 #xffe4   ; Control_L, Control_R
            #xffe7 #xffe8   ; Meta_L, Meta_R
            #xffe9 #xffea   ; Alt_L, Alt_R
            #xffeb #xffec   ; Super_L, Super_R
            #xffed #xffee   ; Hyper_L, Hyper_R
            #xffe5 #xffe6   ; Caps_Lock, Shift_Lock
            #xff7f #xfe03)) ; Num_Lock, ISO_Level3_Shift

    (define (pgtk-event-keysym e)
      ;; The keysym of a Gdk key event.
      ;;--------------------------------------------------------------
      (let*-values (((_ keysym) (event:get-keyval e)))
        keysym))

    (define (pgtk-encode-event e)
      ;; A GTK key press as the single INTEGER the interface carries: the
      ;; modifier state in the high bits and the keysym in the low ones.
      ;;
      ;; It has to be an integer because that is what `read-input-event'
      ;; may answer - a character or an integer - and a GTK key is
      ;; (modifiers, keysym), which neither a character nor a bare keysym
      ;; can hold. A terminal needs no such encoding because ncurses
      ;; folds the modifiers into the byte; its keypad codes are the same
      ;; idea (a terminal key that is not a character).
      ;;--------------------------------------------------------------
      ;; `event:get-state' and `event:get-keyval' are the Gdk accessors
      ;; whose C forms take an out-parameter, so each answers TWO values:
      ;; whether it worked, then the value. Taking the first alone yields
      ;; the success flag, which is a boolean - hence `let*-values'.
      ;;--------------------------------------------------------------
      (let*-values (((_ state) (event:get-state e))
                    ((_ keysym) (event:get-keyval e)))
        (+ keysym (ash (modifier-type->number state) 32))))

    (define (pgtk-decode-event code)
      ;; The `(MODIFIER-STATE . KEYSYM)' a code encodes.
      ;;--------------------------------------------------------------
      (cons (ash code -32) (logand code #xFFFFFFFF)))

    (define *resize-code* -1)
    ;; ^ What a resize is reported as. `read-input-event' may answer only a
    ;; character or an integer, and a resize is neither a key nor a
    ;; character - so, like a terminal's own `KEY_RESIZE', it is a code of
    ;; this display's that the key decoder turns into `(resize)'.

    (define (pgtk-ensure-surface! d)
      ;; Make the drawing surface the size the WIDGET is, in pixels - not
      ;; the size of the grid. The grid is the allocation divided by a
      ;; cell, so it is always up to a cell smaller; the surface is what
      ;; is painted into the widget, so it is the larger of the two. A
      ;; surface is made when the display opens, and again after a resize,
      ;; because the old one is the wrong shape and would clip.
      ;;--------------------------------------------------------------
      (let* ((raw (or (pgtk-allocation d)
                      (cons (pgtk-pixel-width d) (pgtk-pixel-height d))))
             ;; Exact integers, always: cairo answers an inexact surface
             ;; size with "invalid value (typically too big)", which
             ;; describes the number's type and not its magnitude, and
             ;; sends you hunting for a size that was never the problem.
             (size (cons (inexact->exact (round (car raw)))
                         (inexact->exact (round (cdr raw))))))
        (let* ((surface (cairo-image-surface-create 'argb32
                                                    (car size) (cdr size)))
               (cr (cairo-create surface)))
          (cairo-select-font-face cr "monospace" 'normal 'normal)
          (cairo-set-font-size cr *font-size*)
          (set! (pgtk-surface d) surface)
          (set! (pgtk-cr d) cr))))

    (define (pgtk-resize! d width height)
      ;; Take the window's new size in pixels as the grid's new size, and
      ;; tell the command loop, which re-tiles the frame and redraws.
      ;;--------------------------------------------------------------
      ;; Nothing is remembered about the *size*: `screen-size' and the
      ;; surface both ask the widget. This only asks the command loop to
      ;; draw again - and only when the allocation has actually changed,
      ;; since asking on every frame redraws forever.
      ;;--------------------------------------------------------------
      (let ((last (pgtk-last-allocation d)))
        (unless (and last (= (car last) width) (= (cdr last) height))
          (set! (pgtk-last-allocation d) (cons width height))
          (pgtk-enqueue! d 'resize))))

    (define (pgtk-allocation d)
      ;; What the widget is actually allocated, in pixels, asked for each
      ;; time rather than remembered.
      ;;
      ;; Asking rather than remembering is what keeps the surface and the
      ;; widget from disagreeing: a size remembered from a `size-allocate'
      ;; signal is stale between the window changing and the signal being
      ;; handled, or when no signal comes at all.
      ;;--------------------------------------------------------------
      (let ((area (pgtk-area d)))
        (if area
            (let ((w (widget:get-allocated-width area))
                  (h (widget:get-allocated-height area)))
              (if (and (> w 0) (> h 0)) (cons w h) #f))
            #f)))

    (define (pgtk-cells d)
      ;; The grid, from the allocation. Falls back to what is remembered
      ;; when there is no window yet, which is what a test sees.
      ;;--------------------------------------------------------------
      (let ((size (pgtk-allocation d)))
        (if size
            (cons (max 1 (quotient (car size) *cell-width*))
                  (max 1 (quotient (cdr size) *cell-height*)))
            (cons (pgtk-columns d) (pgtk-rows d)))))

    (define (pgtk-now-ms)
      (quotient (* 1000 (get-internal-real-time))
                internal-time-units-per-second))

    (define (pgtk-read-event d timeout)
      ;; Read one input event, TIMEOUT milliseconds allowed - a negative
      ;; TIMEOUT blocks. This is `read-input-event''s body: it pumps the
      ;; GTK main loop until the queue has something or the deadline
      ;; passes.
      ;;
      ;; The deadline is a GLib timeout that pushes a sentinel, so the
      ;; loop is woken by GLib rather than by a clock. An event is
      ;; `(MODIFIER-STATE . KEYSYM)'.
      ;;
      ;; A blocking read must never answer #f: `keyboard.sld' takes that
      ;; for the end of input and leaves the editor.
      ;;--------------------------------------------------------------
      (let ((drawn (pgtk-drawn-size d))
            (now (pgtk-allocation d)))
        ;; Whatever the signals did or did not deliver, the read is the
        ;; one place that always runs: if what was drawn is not the
        ;; window's size, that is a resize the editor has not acted on.
        (when (and drawn now
                   (or (not (= (car drawn) (car now)))
                       (not (= (cdr drawn) (cdr now)))))
          (pgtk-enqueue! d 'resize)))
      (let ((deadline (and (>= timeout 0) (+ (pgtk-now-ms) timeout))))
        (let loop ()
          (let ((queue (pgtk-queue d)))
            (cond
             ((and (pair? queue) (eq? (car queue) 'pgtk-deadline))
              (set! (pgtk-queue d) (cdr queue))
              #f)
             ((pair? queue)
              (set! (pgtk-queue d) (cdr queue))
              (let ((item (car queue)))
                (cond
                 ((eq? item 'resize) *resize-code*)
                 ;; A modifier press is not a key: drop it and read on,
                 ;; so the caller never sees an event it cannot act on.
                 ((memv (pgtk-event-keysym item) modifier-keysyms) (loop))
                 (else (pgtk-encode-event item)))))
             ((and deadline (>= (pgtk-now-ms) deadline))
              #f)
             (else
              ;; Nothing yet. Give the development REPL a turn - a no-op
              ;; unless `SCHEMACS_REPL' opened it, and the only place a
              ;; windowed editor is ever idle - then process one event,
              ;; waiting only as long as the deadline allows.
              (poll-repl!)
              (if deadline
                  (catch #t
                    (lambda () (main-iteration-do? #f))
                    (lambda args #f))
                  (catch #t
                    (lambda () (main-iteration-do? #t))
                    (lambda args #f)))
              (loop)))))))

    (define-method (read-input-event (d <pgtk-display>) timeout)
      (pgtk-read-event d timeout))

    (define-method (key-event->keymap-path (d <pgtk-display>) ev)
      ;; EV is the integer `read-input-event' answered; decode it into
      ;; the modifier state and keysym this file builds paths from.
      ;;--------------------------------------------------------------
      (cond
       ((eqv? ev *resize-code*) '(resize))
       ((integer? ev) (key-event->path (pgtk-decode-event ev)))
       (else #f)))

    (define-method (screen-size (d <pgtk-display>))
      ;; In pixels, and a character is one pixel here, so this is the
      ;; grid in cells - asked of the window every time, so the redisplay
      ;; follows the window with no signal to keep in step.
      ;;--------------------------------------------------------------
      (pgtk-cells d))

    (define-method (column-width (d <pgtk-display>)) 1)
    (define-method (line-height (d <pgtk-display>)) 1)

    (define-method (display-color-cells (d <pgtk-display>)) 16777216)

    (define-method (realize-face (d <pgtk-display>) face-attrs)
      (realize-face-token face-attrs))

    (define-method (clear-frame-area! (d <pgtk-display>))
      ;; Fill the surface with the default face's background and start a
      ;; new frame: everything drawn from here overwrites it. The surface
      ;; is made here rather than at open, and remade after a resize,
      ;; because its size is the grid's.
      ;;--------------------------------------------------------------
      (pgtk-ensure-surface! d)
      (let ((cr (pgtk-cr d)))
        (when cr
          (cairo-set-source-rgb cr 1 1 1)
          (cairo-paint cr))))

    (define-method (update-window-begin! (d <pgtk-display>)) #t)
    (define-method (update-window-end! (d <pgtk-display>)) #t)

    (define (text-cells text)
      ;; How many cells TEXT occupies in this editor's model: the sum of
      ;; its characters' widths.
      ;;
      ;; `char-display-width' and not `string-length', which is the whole
      ;; reason a run cannot simply be handed to cairo: a CJK ideograph is
      ;; one character and two cells, so a run drawn as one string - or a
      ;; background rectangle measured by its length - is one cell short
      ;; for each of them.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0))
        (if (>= i (string-length text))
            col
            (loop (+ i 1)
                  (+ col (char-display-width (string-ref text i) col))))))

    (define-method (write-glyphs! (d <pgtk-display>) text y x token)
      ;; Draw TEXT at cell (X, Y), a *cluster* at a time.
      ;;
      ;; The surface is ours, so the cell grid is exact and there is no
      ;; clipping to leave to anyone else - but the grid is made of cells
      ;; and a string is made of characters, and the two stop agreeing at
      ;; the first wide character. So each cluster is placed at its own
      ;; cell column, and the column advances by the character's width
      ;; rather than by one. This is what the terminal does for us: it
      ;; advances by the width it knows the character has.
      ;;
      ;; A cluster is a character plus the zero-width characters after it
      ;; - a letter and its combining accent - which are drawn together so
      ;; that the accent lands on the letter and not on an empty cell.
      ;;--------------------------------------------------------------
      (let ((cr (pgtk-cr d))
            (foreground (face-token-foreground token))
            (background (face-token-background token)))
        (when cr
          ;; The run's own background first, so a face that paints cells
          ;; rather than glyphs - the mode line, the region - is drawn,
          ;; and as many *cells* wide as the run is.
          (when background
            (apply cairo-set-source-rgb cr background)
            (cairo-rectangle cr (cell-x x) (cell-y y)
                             (* *cell-width* (text-cells text))
                             *cell-height*)
            (cairo-fill cr))
          (apply cairo-set-source-rgb cr (or foreground (list 0.0 0.0 0.0)))
          (let loop ((i 0) (col 0))
            (when (< i (string-length text))
              (let* ((end (let scan ((j (+ i 1)))
                            (if (and (< j (string-length text))
                                     (= 0 (char-display-width
                                           (string-ref text j) col)))
                                (scan (+ j 1))
                                j)))
                     (c (string-ref text i)))
                (cairo-move-to cr (cell-x (+ x col))
                               (+ (cell-y y) (- *cell-height* 5)))
                (cairo-show-text cr (substring text i end))
                (loop end (+ col (char-display-width c col)))))))))

    (define-method (draw-window-cursor! (d <pgtk-display>) row column cells)
      ;; A filled block at the cell, drawn after the text - CELLS cells
      ;; wide, because the cursor sits on the character at point and a
      ;; double-width character is two cells.
      ;;--------------------------------------------------------------
      (let ((cr (pgtk-cr d)))
        (when cr
          (cairo-set-source-rgb cr 0 0 0)
          (cairo-rectangle cr (cell-x column) (cell-y row)
                           (* *cell-width* (max 1 cells)) *cell-height*)
          (cairo-fill cr))))

    (define (pgtk-present! d gtk-cr)
      ;; Paint what we have drawn into the context Gtk handed us. This is
      ;; where the picture is put on the screen, at the moment Gtk asks
      ;; for it, so there is no snapshot waiting to go stale and nothing
      ;; for Gtk to scale - it is our pixels, at their own size, drawn by
      ;; us.
      ;;
      ;; The context is Gtk's, wrapped by guile-gi; guile-cairo cannot use
      ;; another library's wrapper, so the pointer is read out of it and
      ;; wrapped again as a guile-cairo context.
      ;;--------------------------------------------------------------
      (let ((surface (pgtk-surface d))
            (cr (cairo-pointer->context (slot-ref gtk-cr 'value))))
        (when surface
          (cairo-set-source-surface cr surface 0 0)
          (cairo-paint cr))))

    (define-method (flush-display! (d <pgtk-display>))
      ;; What has been drawn becomes visible when Gtk next asks us to
      ;; paint: there is no buffer to hand over any more.
      ;;--------------------------------------------------------------
      (let ((area (pgtk-area d)))
        (when area (widget:queue-draw area))))

    (define (pgtk-write-screenshot! d path)
      ;; Write what the display is showing to PATH as a PNG.
      ;;--------------------------------------------------------------
      (let ((surface (pgtk-surface d)))
        (when surface
          (cairo-surface-flush surface)
          (cairo-surface-write-to-png surface path))))

    (define-method (suspend-display! (d <pgtk-display>))
      ;; There is no SIGTSTP meaning for a window; hiding it is the
      ;; nearest thing, and leaves the editor able to be stopped.
      ;;--------------------------------------------------------------
      (let ((w (pgtk-window d)))
        (when w (widget:hide w))))

    (define-method (resume-display! (d <pgtk-display>))
      (let ((w (pgtk-window d)))
        (when w (widget:show-all w))))

    ;;----------------------------------------------------------------
    ;; Opening the display
    ;;------------------------------------------------------------------

    (define (initialize-pgtk-faces! d)
      ;; Tell the face machinery what this display can draw, then
      ;; recompute the specs against it, as `with-terminal' does.
      ;;
      ;; Each of the four is the frame parameter GNU Emacs's pgtk backend
      ;; sets, and each is a *separate* question - a face spec tests them
      ;; in different conjuncts, so getting one wrong silently picks a
      ;; branch written for another kind of display:
      ;;
      ;;   * `window-system' is `pgtk' - `pgtk_create_frame' sets it, as
      ;;     `xfns.c' sets `x'. It is what a spec's `(type tty)' branch is
      ;;     tested against, so leaving it #f makes every tty branch match
      ;;     on a graphical frame: `header-line' then comes out underlined
      ;;     and not inverse-video, which is a terminal's answer.
      ;;   * `display-type' is `color', which is what `pgtkfns.c:2781'
      ;;     sets explicitly - NOT the window system's name. It is what a
      ;;     `(class color)' branch is tested against, so setting it to
      ;;     `pgtk' makes every colour branch fail and drops the region to
      ;;     the spec's last-resort `(#t :background "gray")' instead of
      ;;     `lightgoldenrod2'.
      ;;   * `display-color-cells' is the display's own answer.
      ;;   * `frame-background-mode' is `light': this display paints the
      ;;     default face as black on white.
      ;;--------------------------------------------------------------
      (*window-system* 'pgtk)
      (*display-color-cells* (display-color-cells d))
      (*display-type* 'color)
      (*frame-background-mode* 'light)
      (for-each face-spec-recalc (face-list)))

    (define (with-gtk-display thunk)
      ;; Open a GTK window, make it the editor's display, run THUNK, and
      ;; take it down afterwards. The counterpart of `with-terminal'.
      ;;--------------------------------------------------------------
      ;; The name the window manager knows this window by. On Wayland
      ;; the app-id comes from the program name, which would otherwise be
      ;; `guile' - so a compositor rule cannot name this editor. Setting
      ;; both before Gtk is initialised is what makes it `schemacs'.
      ;;--------------------------------------------------------------
      (set-prgname "schemacs")
      (set-program-class "schemacs")
      (init-check!)
      (let* ((columns 80)
             (rows 24)
             (width (* columns *cell-width*))
             (height (* rows *cell-height*))
             (win (make <GtkWindow>))
             (area (make <GtkDrawingArea>))
             (d (make <pgtk-display>)))
        (set! (pgtk-window d) win)
        (set! (pgtk-area d) area)
        (set! (pgtk-columns d) columns)
        (set! (pgtk-rows d) rows)
        (set! (pgtk-pixel-width d) width)
        (set! (pgtk-pixel-height d) height)
        ;; Keys arrive here and go on the queue the read drains. The
        ;; event is queued raw and decoded by the read. A toplevel window
        ;; receives key events without being told to ask for them;
        ;; setting an event mask on one crashes GTK.
        (connect win (make <signal> #:name "key-press-event")
                 (lambda (w e) (pgtk-enqueue! d e) #t))
        ;; A size is REQUESTED, not set as a default. `set-default-size'
        ;; pins the window: Gtk then never accepts the size a compositor
        ;; tiles it to, and the compositor - handed a window it cannot
        ;; resize - scales the buffer instead, which is what stretched
        ;; text was. `window:resize' asks, so the window still starts a
        ;; sensible shape but follows whatever it is given.
        (set! (window:resizable win) #t)
        (window:resize win width height)
        (connect win (make <signal> #:name "size-allocate")
                 (lambda (w rect)
                   (pgtk-resize! d (widget:get-allocated-width w)
                                   (widget:get-allocated-height w))
                   #t))
        ;; Draw again once the window has actually been mapped and
        ;; allocated: the first frame is drawn before that, and if the
        ;; window ends up a different size the editor should draw it
        ;; again at the size it really is.
        (connect win (make <signal> #:name "map-event")
                 (lambda (w e) (pgtk-enqueue! d 'resize) #f))
        ;; The area must not dictate the window's size: a window's
        ;; minimum size comes from its child, so a size request as large
        ;; as the window would pin it there. A one-cell request plus
        ;; expand lets the window be any size and gives the drawing area
        ;; the whole of it.
        ;;--------------------------------------------------------------
        (widget:set-size-request area 1 1)
        (set! (widget:hexpand area) #t)
        (set! (widget:vexpand area) #t)
        ;; Every repaint Gtk asks for is answered by painting our own
        ;; drawing into the context it gives us, at its size.
        (connect area (make <signal> #:name "draw")
                 (lambda (w cr) (pgtk-present! d cr) #t))
        (container:add win area)
        ;; Key events go to the focused widget. A drawing area does not
        ;; take focus, so the window itself must - otherwise a keystroke
        ;; has nowhere to be delivered and the editor silently never
        ;; hears from the keyboard.
        (set! (widget:can-focus win) #t)
        (widget:show-all win)
        (widget:grab-focus win)
        (current-display d)
        (initialize-pgtk-faces! d)
        (dynamic-wind
         (lambda () #t)
         thunk
         (lambda ()
           (widget:destroy win)
           (current-display #f)))))

    ))
