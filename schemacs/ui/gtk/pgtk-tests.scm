;; Tests for `(schemacs ui gtk pgtk)', the GTK display - the parts that
;; need no window.
;;
;; A `<pgtk-display>' is made directly, never opened: `with-gtk-display' is
;; what calls `init-check!', and nothing here does. What is exercised is
;; the two things that are pure functions of a display object - the key
;; decode, and what a face realizes to - plus one honest check of the
;; *pixels*, because that is where the colour of a face actually lives.
;;
;; That last one is not decoration. The display used to tell the face
;; machinery its `display-type' was `pgtk', where the contract is
;; `color'/`grayscale'/`mono'. Every `(class color)' branch of every spec
;; therefore failed, and `region' fell through to the last-resort
;; `(#t :background "gray")'- a grey so close to the white background
;; that the region looked like it was not drawn at all. No test of the
;; face *table* could see that: the table was right, and the branch
;; chosen from it was wrong. Reading the rendered pixels is what sees it.
;;-------------------------------------------------------------
(import
 (only (schemacs editor editfns) insert)
 (scheme base)
 (scheme char)
 (only (guile) setvbuf delete-file getpid)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) make)
 (prefix (only (schemacs ui gtk pgtk)
               <pgtk-display> initialize-pgtk-faces! pgtk-write-screenshot!
               note-mouse-movement pgtk-mouse-moved
               ;; what a character cell measures, so the pixel checks
               ;; below sample the font's cell and not a remembered one
               pgtk-cell-size
               ;; The local selection read - see its section below. It
               ;; needs no window and no clipboard: the record is the
               ;; display's own and the converters are `select.sld`'s.
               pgtk-selections pgtk-get-local-selection
               pgtk-get-selection-internal selection-data-to-lisp-data
               ;; The popup's `widget_value' tree - `pgtk_menu_show`'s
               ;; loop. A pure function of `menu_items' and the flags,
               ;; which is why it can be tested with no window - see the
               ;; section at the end of this file.
               pgtk-popup-build-tree)
         pt:)
 (prefix (schemacs editor faces) f:)
 ;; The command this file can test and the terminal suites cannot: it is
 ;; graphic-only, so a windowed display is the only place it runs.
 (prefix (only (schemacs editor face-remap)
               global-text-scale-adjust text-scale-increase
               text-scale-mode-amount face-remapping-alist)
         scale:)
 (prefix (schemacs editor xfaces) x:)
 (prefix (schemacs editor xdisp) xd:)
 (prefix (schemacs editor dispnew) dn:)
 (prefix (schemacs editor frame) fr:)
 (prefix (only (schemacs editor test-display)
               <test-display> test-display-glyphs) td:)
 (prefix (schemacs editor window) window:)
 
 (only (schemacs editor buffer) buffer-local-value set-buffer-local-value!
       %mark-marker with-current-buffer
 set-point allocate-buffer buffer-pt)
 ;; the mark's read and write are marker.c's now, on the buffer's own
 ;; slot; `text-editor-mark`/`set!text-editor-mark` are gone.
 (only (schemacs editor marker) marker-position set-marker)
 (only (schemacs editor textprop) put-text-property)
 (prefix (schemacs editor isearch) is:)
 (only (schemacs editor buffer) overlays-at overlay-get overlay-start)
 ;; Imported for the *faces* it defines - `dired-marked' and the two
 ;; beside it are dired.el's own `defface's - which the test below
 ;; realizes. Loaded by both front ends in the real editor, so this is
 ;; not a test-only dependency.
 (only (schemacs editor dired))
 ;; `tsdh-dark`'s mode-line names no foreground - the case below.
 (only (schemacs editor theme) load-theme disable-theme)
 (only (schemacs editor keyboard) dispatch-input-event)
 ;; The `menu_items` array the popup's tree is built from, and the
 ;; `widget_value` accessors the checks below read it back with.
 (prefix (only (schemacs editor menu)
               list-of-panes MENU-KEYMAPS
               widget-value-name widget-value-enabled? widget-value-contents
               widget-value-next widget-value-call-data
               widget-value-button-type)
         menu:)

 (only (cairo) cairo-image-surface-create-from-png cairo-image-surface-get-data
       cairo-image-surface-get-stride))

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_pgtk")

;;------------------------------------------------------------------
;; A display, with no window and no Gtk init.
;;------------------------------------------------------------------

;; **A `<test-display>` has no menu bar widget.** The pgtk frames these
;; tests make are a drawing surface with pixels; the toolkit's bar sits
;; above that surface, outside the area they measure. A terminal's bar is
;; a *row* of its text area, which is `frame-top-margin`'s one difference
;; between the two - so the frames here are made with the bar turned off.
(fr:*default-frame-alist*
 (cons '(menu-bar-lines . 0) (fr:*default-frame-alist*)))

(define (new-display)
  (let ((d (make pt:<pgtk-display>)))
    (dn:current-display d)
    (pt:initialize-pgtk-faces! d)
    d))

;;------------------------------------------------------------------
;; The key decode
;;
;; `read-input-event' may answer only a character or an integer, so this
;; display folds `(MODIFIER-STATE . KEYSYM)' into one integer. These are
;; the exact values the plan records as measured.
;;
;; What the decode answers is the *key event* GNU Emacs's
;; `make_lispy_event' would - an integer carrying the character in the
;; low bits and the modifiers above it, or a symbol for a key that is
;; not a character - which is the same form a terminal's decode answers
;; with and the form `(kbd "M-x")' and every binding in the tree spell.
;;------------------------------------------------------------------

(define (key-event ev) (dn:key-event->key (new-display) ev))

(define (encode state keysym) (+ keysym (* state (expt 2 32))))

(test-equal 97 (key-event 97))                            ; `a'
(test-equal 1 (key-event (encode 4 97)))                  ; C-a
(test-equal 134217848 (key-event (encode 8 120)))         ; M-x
(test-equal 'up (key-event 65362))                        ; GDK_KEY_Up
(test-equal 'left (key-event 65361))
;; A key that is not a character is a *symbol*, which is what Emacs
;; reads a function key as - `(kbd "<up>")' is `#(up)' - and a
;; modified one is the symbol with the modifier in its name, which is
;; exactly `(kbd "C-<left>")' = `#(C-left)'.
(test-equal 'C-left (key-event (encode 4 65361)))         ; C-<left>

;; A control character keeps its own event: RET is 13, which is the
;; `(kbd "RET")' the minibuffer's map binds, and TAB is 9. The
;; *terminal* folds these onto control-M and control-I because a
;; terminal has one byte for the pair; a window system has the keysym,
;; and Emacs's event there is the character.
;; Return, TAB and Escape keep their *names* here: a window system
;; sends a keysym, and Emacs names it `return', `tab', `escape' from
;; `lispy_function_keys' (`keyboard.c':5513'). That they *mean* 13, 9
;; and 27 is `function-key-map''s job (`bindings.el':1554'), one
;; translation further on - `keyboard.sld''s `function-key-translate',
;; exercised in `subr-tests.scm'.
(test-equal 'return (key-event #xff0d))                   ; GDK_KEY_Return
(test-equal 'tab (key-event #xff09))                      ; GDK_KEY_Tab
(test-equal 'escape (key-event #xff1b))                   ; GDK_KEY_Escape
(test-equal 'delete (key-event #xffff))                   ; GDK_KEY_Delete
(test-equal 'kp-enter (key-event #xff8d))
(test-equal 'M-return (key-event (encode 8 #xff0d)))

;; A resize is a code, not a key: `read-input-event' cannot answer a
;; pair, so the display uses one integer for it, as a terminal uses
;; KEY_RESIZE.
(test-equal 'resize (key-event -1))

;; A keysym with no name and no Unicode character is not a key this
;; editor can act on, and answers #f rather than inventing a name.
(test-equal #f (key-event (encode 0 65515)))              ; GDK_KEY_Shift_L alone

;;------------------------------------------------------------------
;; C-SPC sets the mark from a GTK window
;;
;; This one test crosses two layers, which is why the bug was invisible
;; to both of them. `simple.sld` binds `set-mark-command` to `C-@`, and
;; `C-@` is what a *terminal* sends for either spelling - a terminal has
;; one byte for the pair. A GTK window does not: C-SPC arrives as a
;; `space` keysym with the control modifier, a different event entirely,
;; so the binding above it never fired and pressing C-SPC did nothing.
;; Emacs binds both, in `bindings.el`:
;;
;;     (define-key global-map "\C-@" 'set-mark-command)
;;     (define-key global-map [?\C- ] 'set-mark-command)
;;
;; So the check is the *event the backend produces*, through the real
;; `dispatch-input-event', to the mark - the same path a keypress takes.
;;------------------------------------------------------------------

;; GDK's control modifier, `GDK_CONTROL_MASK = 1 << 2', folded into the
;; state field of a key event the way the C's shift is.
(define (with-control keysym) (+ keysym (* 4 (expt 2 32))))
(define key-c-spc (with-control #x20))   ; GDK_KEY_space with Control
(define key-c-at  (with-control #x40))   ; GDK_KEY_at with Control

(define (mark-after key)
  ;; Dispatch KEY as the GTK display would, then two C-f, and answer the
  ;; mark as the region code sees it.
  (let* ((display (new-display))
         (ed (allocate-buffer))
         (frame (fr:new-frame ed 24 80)))
    (parameterize ((fr:*current-frame* frame))
      (with-current-buffer ed (insert "hello world"))
      (set-point ed 1)
      (dispatch-input-event frame key)
      ;; C-f is a *motion* command, which keeps the mark active - it is how
      ;; a region is made at all.
      (dispatch-input-event frame (with-control (char->integer #\f)))
      (dispatch-input-event frame (with-control (char->integer #\f)))
      (list (buffer-local-value ed 'mark-active #f)
            (marker-position (%mark-marker ed))
            (buffer-pt ed)))))

(define c-spc-mark (mark-after key-c-spc))
(test-equal #t (car c-spc-mark))
(test-equal 1 (cadr c-spc-mark))
;; and the motion still worked, so the mark is a region and not a
;; deactivated leftover
(test-equal 3 (caddr c-spc-mark))

;; C-@ keeps working - a terminal can only ever send that one.
(test-equal (list #t 1 3) (mark-after key-c-at))

;;------------------------------------------------------------------
;; Faces intern to integers, 0 meaning "plain"
;;
;; `xdisp.sld''s `line-end-fill-attribute' compares a realized face with
;; `=', so a display must hand back an integer, and 0 must be the plain
;; face. A GUI cannot answer an opaque record.
;;------------------------------------------------------------------

(define (realize display face . attrs)
  (f:face-spec-recalc face)
  (dn:realize-face display (x:face-realized-attributes face)))

(define plain-token (realize (new-display) 'default))

;; The plain face is 0 - the constraint the redisplay depends on.
(test-equal 0 plain-token)

;; Two faces that draw *differently* must not intern to the same token,
;; or the redisplay would draw one as the other.
(let ((d (new-display)))
  (pt:initialize-pgtk-faces! d)
  (let ((region (dn:realize-face d (x:face-realized-attributes 'region)))
        (mode-line (dn:realize-face d (x:face-realized-attributes 'mode-line))))
    (test-assert (and (integer? region) (not (= 0 region))))
    (test-assert (and (integer? mode-line) (not (= 0 mode-line))))
    (test-assert (not (= region mode-line)))
    ;; Interning is a pure function of the attributes: asking twice gives
    ;; the same id, or the face table would grow without bound.
    (test-equal region (dn:realize-face d (x:face-realized-attributes 'region)))))

;;------------------------------------------------------------------
;; What the display draws, in pixels
;;
;; The one check the face table cannot make: the region's background is
;; the `lightgoldenrod2' its spec picks for a graphical display with a
;; light background - NOT the `gray' last-resort branch, which is so close
;; to the white background that it reads as "the region is not drawn".
;;------------------------------------------------------------------

(define (render-region text point mark)
  ;; A frame on a display, with the region [MARK, POINT) active, rendered
  ;; by the real `render!'.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    (set-point ed point)
    (set-marker (%mark-marker ed) mark ed)
    (set-buffer-local-value! ed 'mark-active #t)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    d))

(define (pixel-reader path)
  ;; Read a PNG back and answer a `(PIXEL X Y)' procedure giving `(R G B)'.
  ;; The file is a round trip through cairo; there is no way to ask the
  ;; display for its surface by name, and going via the PNG is also what
  ;; makes this a check of what the editor would *show*.
  (let* ((surf (cairo-image-surface-create-from-png path))
         (data (cairo-image-surface-get-data surf))
         (stride (inexact->exact
                  (round (cairo-image-surface-get-stride surf)))))
    (lambda (x y)
      ;; Premultiplied ARGB32, little-endian: bytes are B G R A.
      (let ((i (+ (* y stride) (* x 4))))
        (list (bytevector-u8-ref data (+ i 2))
              (bytevector-u8-ref data (+ i 1))
              (bytevector-u8-ref data i))))))

(define (shot-of display)
  ;; Render what DISPLAY is showing to a PNG, read it back, and delete it.
  (let ((path (string-append "/tmp/schemacs-pgtk-tests-"
                             (number->string (getpid)) ".png")))
    (pt:pgtk-write-screenshot! display path)
    (let ((pixel (pixel-reader path)))
      (delete-file path)
      pixel)))

;; The region [3, 6) of "hello world" - Emacs's positions, so the three
;; `l', `l' and `o' at columns 2, 3 and 4 - with point at 6.
(define pixel (shot-of (render-region "hello world" 6 3)))

;; One character is a font cell - 9x20 pixels for the 15-pixel monospace
;; font this display opens by default, which is *asked* rather than
;; assumed: the cell is the font's size, and the font follows the
;; `default' face's `:height'. Sample the last row of the first text row,
;; which is below every glyph but a descender's tail - so the text these
;; helpers read must have none - and is therefore the *background* the
;; run painted, and not a glyph stroke drawn over it.
(define cell-size (pt:pgtk-cell-size))
(define cell-w (car cell-size))
(define cell-h (cdr cell-size))
(define (cell-pixel cell) (pixel (+ (* cell cell-w) 4) (- cell-h 1)))

(define lightgoldenrod2 '(238 220 130))
(define white '(255 255 255))

(test-equal lightgoldenrod2 (cell-pixel 2))
(test-equal lightgoldenrod2 (cell-pixel 3))
(test-equal lightgoldenrod2 (cell-pixel 4))
;; and the plain text either side of it is NOT painted
(test-equal white (cell-pixel 0))
(test-equal white (cell-pixel 1))
(test-equal white (cell-pixel 6))

;;------------------------------------------------------------------
;; The `:box` face attribute is drawn - on a window system only
;;
;; GNU Emacs draws a face's `:box` around its glyph run in the
;; graphical back ends (`pgtk_draw_glyph_string_box`, `pgtkterm.c:2004`)
;; and not on a terminal (`realize_tty_face` drops the attribute). The
;; box `tsdh-dark` puts on the mode line is this: a one-pixel red line
;; along the top and bottom of the mode line row. The pixel is read at
;; the row's first line, where the box's top side is.
;;------------------------------------------------------------------

(define (render-with-mode-line-box)
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello\n"))
    (f:set-face-attribute 'mode-line #f ':box
                          '(:line-width 1 :color "red"))
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    d))

(define box-shot (shot-of (render-with-mode-line-box)))
;; The mode line is the row above the echo area: a 24-row frame has 22
;; text rows, the mode line at row 22 and the echo area under it.
(define mode-line-y (* 22 cell-h))
(define red '(255 0 0))
(test-equal red (box-shot 2 mode-line-y))
(test-equal red (box-shot (- (* 80 cell-w) 1) mode-line-y))
;; ...and the box's *inside* keeps the mode line's own colours, so the
;; line is a box and not a filled rectangle.
(test-assert "the box encloses the mode line rather than filling it"
             (not (equal? red (box-shot 2 (+ mode-line-y 5)))))

;;------------------------------------------------------------------
;; A basic face with no foreground takes the default face's
;;
;; GNU Emacs's `realize_named_face` (`xfaces.c:6590`) starts every basic
;; face from the *default* face's fully-specified attributes and merges
;; the named face over them. `tsdh-dark` gives `mode-line` a background
;; and a box and no `:foreground`, so Emacs draws white-smoke text on
;; it; merging the mode-line chain alone left the foreground
;; unspecified, and the Gtk backend's fallback is black - a black mode
;; line on a dark theme.
;;------------------------------------------------------------------

(define (token-foreground token)
  ((@@ (schemacs ui gtk pgtk) face-token-foreground) token))

(test-equal #t
  (let ((d (new-display)))
    (load-theme 'tsdh-dark #t)
    (let ((ml (token-foreground (xd:face->attribute 'mode-line-active
                                                    'mode-line-active)))
          (df (token-foreground (xd:face->attribute 'default 'default))))
      (disable-theme 'tsdh-dark)
      (equal? ml df))))

;;------------------------------------------------------------------
;; A wide character takes two cells - in the drawing, not just in the
;; arithmetic
;;
;; The region [1, 4) of "x<CJK>o|Z" is four cells: one for `x', two for
;; the CJK character, one for `o'. Drawing the run's background by its
;; `string-length' makes it three and leaves the fourth cell white, which
;; is the same mistake one layer down from where the arithmetic is tested -
;; and one only the pixels can see.
;;
;; `o' and not a letter with a descender, because `wide-cell-pixel'
;; samples the foot of the cell - see `cell-pixel'.
;;------------------------------------------------------------------

(define wide-text (string-append "x" (string (integer->char #x4E2D)) "o|Z"))
(define wide-pixel (shot-of (render-region wide-text 4 1)))
(define (wide-cell-pixel cell) (wide-pixel (+ (* cell cell-w) 4) (- cell-h 1)))

(test-equal lightgoldenrod2 (wide-cell-pixel 0))
(test-equal lightgoldenrod2 (wide-cell-pixel 1))
(test-equal lightgoldenrod2 (wide-cell-pixel 2))
;; the fourth cell of the region, which counting characters loses
(test-equal lightgoldenrod2 (wide-cell-pixel 3))
;; and the text after the region is not painted
(test-equal white (wide-cell-pixel 5))


;;------------------------------------------------------------------
;; The `default' face's `:height' is the size the text is drawn at
;;
;; This is the whole of what `global-text-scale-adjust'
;; (`(schemacs editor face-remap)') does: it sets the face's height and
;; redisplays. Until the renderer read that face, the command changed a
;; record that nothing looked at and the text stayed the same size - so
;; the check has to be of the *pixels*, because the record was always
;; right and a test of the table could never have seen it.
;;
;; `:height' is in tenths of a point, as it is in Emacs, and the pixel
;; size it works out to is Emacs's own `POINT_TO_PIXEL' at this display's
;; resolution.
;;------------------------------------------------------------------

(define (row-inked? pix y width)
  ;; Whether any pixel of row Y, among the first WIDTH columns, is
  ;; something other than the background.
  (let x-loop ((x 0))
    (cond ((>= x width) #f)
          ((equal? (pix x y) white) (x-loop (+ x 1)))
          (else #t))))

(define (ink-rows display)
  ;; How many pixel rows of the first text row carry ink - which is the
  ;; glyph's height, in pixels.
  (let ((pix (shot-of display))
        (cell (pt:pgtk-cell-size)))
    (let row-loop ((y 0) (n 0))
      (if (>= y (cdr cell))
          n
          (row-loop (+ y 1)
                    (if (row-inked? pix y (car cell)) (+ n 1) n))))))

(define (ink-rows-at-height height)
  ;; A frame on a fresh display with one tall character in it, drawn with
  ;; the `default' face at HEIGHT tenths of a point. The face is set
  ;; *after* the display is made: opening a display recalculates the face
  ;; specs, which resets it.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert "M"))
    (let ((frame (fr:new-frame ed 24 80)))
      (f:set-face-attribute 'default #f ':height height)
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    (ink-rows d)))

;; The default face's own height is 113 - `PIXEL_TO_POINT' of the
;; 15-pixel font this display opens - and 250 is a quarter larger in
;; points, which is a visibly bigger glyph: 15 pixels against 33.
(define initial-height (f:face-attribute 'default ':height))
;; A graphic display gives the `default' face a height - it is the size
;; `global-text-scale-adjust' reads to know what the text is now, and a
;; face with none makes the command's arithmetic meaningless. It comes
;; from the font this display opened, in tenths of a point.
(test-assert "a Gtk display gives the default face a height"
  (number? initial-height))
(define small-ink (ink-rows-at-height initial-height))
(define big-ink (ink-rows-at-height 250))

(test-assert "the default face's height changes the size the text is drawn"
  (> small-ink 0))
(test-assert "a larger height draws a larger glyph"
  (> big-ink small-ink))

;; And the font goes back, because the checks below sample the pixel
;; columns this file measured at the top of itself: the last render is
;; the restore.
(ink-rows-at-height initial-height)

;;------------------------------------------------------------------
;; `global-text-scale-adjust' - the command, from end to end
;;
;; It is graphic-only in Emacs ("a terminal has one font"), so a windowed
;; display is the only place it can be run at all; and what it has to do
;; is visible only in the pixels, which is why the check is here rather
;; than beside the command.
;;
;; One step is 5 units of 1/10 pt - `global-text-scale-adjust--increment-
;; factor' times the interactive argument - and 118 tenths is 11.8pt,
;; which at this display's 96 dpi is a 16-pixel font instead of 15.
;;------------------------------------------------------------------

(define (with-scale increment thunk)
  ;; Run THUNK with `global-text-scale-adjust' available as INCREMENT
  ;; steps, then put the text size back however THUNK left it - the
  ;; renders below sample pixel columns this file measured at its top.
  ;; Putting the face's height back is not enough on its own: the font is
  ;; reopened where the grid is asked for, which `screen-size' is.
  (dynamic-wind
   (lambda () #t)
   thunk
   (lambda ()
     (f:set-face-attribute 'default #f ':height initial-height)
     (dn:screen-size (dn:current-display)))))

(with-scale 1
 (lambda ()
   (let* ((d (new-display))
          (ed (allocate-buffer)))
     (with-current-buffer ed (insert "M"))
     (let ((frame (fr:new-frame ed 24 80)))
       (parameterize ((fr:*current-frame* frame))
         (xd:render! frame)
         (let ((before (pt:pgtk-cell-size))
               (start (f:face-attribute 'default ':height))
               (height (lambda () (f:face-attribute 'default ':height))))
           ;; **Through the real chord**, which is `face-remap.el`'s own
           ;; binding - `C-x C-M-+'. The command redisplays itself, so
           ;; this is also what makes the new size visible: the redisplay
           ;; is where the font is reopened.
           (dispatch-input-event frame (encode 4 (char->integer #\x)))
           (dispatch-input-event frame (encode 12 (char->integer #\+)))
           (test-equal "C-x C-M-+ raises the default face by half a point"
             (+ start 5) (height))
           (test-assert "and the cell grows with it"
             (> (cdr (pt:pgtk-cell-size)) (cdr before)))
           ;; **The continuation key.** The command installs a transient
           ;; map, so the very next key is looked up there first and `+'
           ;; adjusts again with no prefix chord - through the real
           ;; command loop, the only path that consults
           ;; `overriding-terminal-local-map'.
           (dispatch-input-event frame (char->integer #\+))
           (test-equal "and `+' after it adjusts again" (+ start 10) (height))
           ;; and `-' goes the other way, which is what reading the key
           ;; as a *basic type* is for: a modifier bit left on would make
           ;; it another "increase"
           (dispatch-input-event frame (char->integer #\-))
           (test-equal "and `-' brings it back down" (+ start 5) (height))
           ;; and `0' returns to the height the first adjustment found
           (dispatch-input-event frame (char->integer #\0))
           (test-equal "and `0' goes back to the height it started at"
             start (height))))))))



;;------------------------------------------------------------------
;; `global-text-scale-adjust-resizes-frames`
;;
;; Emacs's option decides between two behaviours when the font changes:
;; with it nil - the default - the frame keeps its pixel size and shows
;; fewer rows and columns; with it on, `adjust_frame_size` grows the
;; frame so that the row and column count stays the same
;; (`x_new_font`, `xterm.c:27167`). The command says so in as many words:
;; "controls whether the frames are resized to keep the same number of
;; lines and characters per line".
;;
;; Both halves are checked here, because either one alone is a bug that
;; looks like the feature working: an always-resize would ignore the
;; option, and a never-resize would make it a no-op.
;;------------------------------------------------------------------

(define (size-after-request inhibit-var)
  ;; The frame's column count after `x_new_font`'s resize of a frame whose
  ;; font has just grown, with `frame-inhibit-implied-resize` set to
  ;; INHIBIT-VAR.
  ;;
  ;; The situation modelled is the one the font change creates: the frame
  ;; is 720 x 480 pixels - 72 columns of the *new* 10-pixel cell - and
  ;; `adjust_frame_size` is asked for 800 x 480, which is 80 columns at
  ;; that cell, the column count the frame had at the old font.
  ;; `x_new_font` passes `FRAME_COLS (f) * FRAME_COLUMN_WIDTH (f)` with
  ;; the *new* width, which is where the 800 comes from.
  ;;
  ;; **This is `adjust_frame_size` with inhibit 3**, the font's own case:
  ;; with the variable set, `frame_inhibit_resize` refuses and the frame
  ;; keeps its 720 pixels, so it holds 72 columns; with it clear the frame
  ;; grows to 800 and keeps 80. That is precisely the choice
  ;; `global-text-scale-adjust-resizes-frames` makes - it binds this
  ;; variable - and it is the mechanism worth testing, because no display
  ;; in this tree can both re-measure its cell and be resized.
  ;;--------------------------------------------------------------
  (parameterize ((fr:*frame-list* '())
                 (fr:*frame-inhibit-implied-resize* inhibit-var))
    (let* ((d (make td:<test-display> #:columns 72 #:rows 24
                    #:column-width 10 #:line-height 22))
           (ed (allocate-buffer)))
      (dn:current-display d)
      (let ((frame (fr:new-frame-on d ed 24 72)))
        (fr:adjust-frame-size! frame 800 480 3 #f 'font)
        (fr:frame-width frame)))))

(test-equal "with an implied resize inhibited the frame keeps its pixels"
  72 (size-after-request #t))

(test-equal "and with it allowed the frame grows to keep its columns"
  80 (size-after-request #f))

;; `frame-inhibit-implied-resize` has Emacs's three spellings.
(test-equal '(#t #t #f #t)
  (list (parameterize ((fr:*frame-inhibit-implied-resize* #t))
          (fr:frame-inhibit-resize? #f #t 'font))
        (parameterize ((fr:*frame-inhibit-implied-resize* 'force))
          (fr:frame-inhibit-resize? #f #f 'font))
        (parameterize ((fr:*frame-inhibit-implied-resize* '(size)))
          (fr:frame-inhibit-resize? #f #t 'font))
        (parameterize ((fr:*frame-inhibit-implied-resize* '(font)))
          (fr:frame-inhibit-resize? #f #t 'font))))

;;------------------------------------------------------------------
;; `text-scale-adjust` - the buffer-local scaling, in pixels
;;
;; Emacs's `text-scale-mode` does not touch the `default` face's own
;; `:height`; it puts a *relative* one in the buffer's
;; `face-remapping-alist`, and the display merges that when it realizes
;; the face. This is the check that the merge reaches the pixels.
;;
;; **The departure it pins is the renderer's**: one grid per display, so
;; a buffer's scale is the frame's scale. Emacs gives every glyph row its
;; own height and leaves other windows alone; `pgtk-ensure-font!` says so
;; where it merges the face.
;;------------------------------------------------------------------

(define (ink-rows-scaled steps)
  ;; The glyph's height in pixels with the buffer's text scaled by STEPS.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert "M"))
    (let ((frame (fr:new-frame ed 24 80)))
      (with-current-buffer ed
        (scale:text-scale-increase steps)
        (parameterize ((fr:*current-frame* frame))
          (xd:render! frame))
        (let ((rows (ink-rows d)))
          ;; back to the face's own size, and the frame measured again
          (scale:text-scale-increase 0)
          (parameterize ((fr:*current-frame* frame))
            (xd:render! frame))
          rows)))))

(define unscaled-ink (ink-rows-scaled 0))
(define scaled-ink (ink-rows-scaled 3))

(test-assert "text-scale-increase draws a larger glyph"
  (> scaled-ink unscaled-ink))

;;------------------------------------------------------------------
;; **A row is as tall as the font the frame draws.**
;;
;; The renderer has one font per frame (`pgtk-ensure-font!` says so, and
;; why), and it draws every run at that size. A row's metrics therefore
;; have to come from the *frame's* font, not from the face's own
;; `:height`: measuring per face gave 21-pixel rows in an unscaled window
;; of a frame whose font had been scaled to 60 by the window next door,
;; and the 60-pixel glyphs were then drawn on 21-pixel rows - on top of
;; each other. Measured with `C-x C-+` in a split frame.
;;
;; The test is the invariant that disagreement violates: the metrics a
;; row is laid out with are the cell the text is drawn in.
;;------------------------------------------------------------------

(define (metrics-match-cell steps)
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert "M"))
    (let ((frame (fr:new-frame ed 24 80)))
      (with-current-buffer ed
        (scale:text-scale-increase steps)
        (parameterize ((fr:*current-frame* frame))
          (xd:render! frame))
        (let ((m (dn:face-metrics d #f))
              (cell (dn:display-cell-size d)))
          (scale:text-scale-increase 0)
          (parameterize ((fr:*current-frame* frame))
            (xd:render! frame))
          (= (+ (car m) (cdr m)) (cdr cell)))))))

(test-equal "row metrics are the drawn font's, unscaled and scaled"
  '(#t #t)
  (list (metrics-match-cell 0) (metrics-match-cell 3)))

;;------------------------------------------------------------------
;; A character the monospace face has no glyph for is drawn with the
;; glyph its *fallback* font has, and not as the missing-glyph box
;;
;; This is the one thing Cairo's own toy text API cannot do:
;; `cairo-show-text' draws with the single face `cairo-select-font-face'
;; chose, and a character that face has no glyph for comes out as the
;; box. `U+10400' - Deseret, in the supplementary plane, and the fourth
;; line of `encoding-test-files/utf8.txt' - is such a character here.
;;
;; **The test compares it against a character nothing can draw.** A
;; *noncharacter* (`U+10FFFD') has no glyph in any font, so Pango draws
;; the box for it; if `U+10400' were also drawn as the box the two
;; renderings would be pixel-for-pixel the same. They were, under the toy
;; API - measured, the same md5 over the same crop - and they are not now.
;; Comparing against the box rather than asserting "there is ink" is what
;; makes this a test of *fallback*: the box is ink too.
;;------------------------------------------------------------------

(define (render-one-character ch)
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert (string ch)))
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    (shot-of d)))

(define (glyph-band pix)
  ;; The pixels of the first cell's glyph band, as a list - what the
  ;; character actually drew, ignoring the rest of the screen.
  (let loop ((x 0) (y 3) (out '()))
    (cond ((>= x 9) (reverse out))
          ((>= y 18) (loop (+ x 1) 3 out))
          (else (loop x (+ y 1) (cons (pix x y) out))))))

(test-assert "a character outside the font is drawn with a fallback glyph"
  (not (equal? (glyph-band (render-one-character (integer->char #x10400)))
               (glyph-band (render-one-character (integer->char #x10FFFD))))))

;;------------------------------------------------------------------
;; A search match keeps the face that was under it
;;
;; `isearch' and `lazy-highlight' are *overlay* faces in GNU Emacs:
;; `isearch-highlight' makes an overlay and `overlay-put's the `isearch'
;; face on it (isearch.el:4026), and `face_at_buffer_position' merges an
;; overlay's face over the text property's. So a font-locked word inside
;; a match keeps its colour and gains the search face on top.
;;
;; Drawing the match in the search face *alone* - which is what this did -
;; paints over the cells under it with one face, so the word's colour is
;; gone for as long as the search lasts. Only the pixels can see it: the
;; attributes are all present and correct in the face table, and the
;; search face is drawn either way.
;;
;; `lazy-highlight' is the face the *other* matches get, and its spec
;; sets a background and nothing else - so the colour a word is drawn in
;; with a match on it must be the colour it is drawn in without one. That
;; is what is compared, and it holds whatever the palette is.
;;------------------------------------------------------------------

(define (render-search text face-start face-end pattern)
  ;; TEXT with `font-lock-keyword-face' over [FACE-START, FACE-END), and
  ;; PATTERN highlighted the way the search highlights it - by
  ;; `isearch-lazy-highlight-update', the very call `isearch' makes, which
  ;; puts a `lazy-highlight' overlay on each match in the window. #f for
  ;; no search at all.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    (set-point ed 0)
    (put-text-property face-start face-end 'face 'font-lock-keyword-face ed)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (when pattern
          (is:isearch-lazy-highlight-update
           ed (fr:frame-selected-window frame) pattern #f))
        (xd:render! frame))
      (shot-of d))))

(define (cell-colours pix cell)
  ;; The distinct `(R G B)' the pixels of CELL's glyph band take.
  (let ((seen '()))
    (let x-loop ((x 0))
      (when (< x 9)
        (let y-loop ((y 3))
          (when (< y 15)
            (let ((c (pix (+ (* cell 9) x) y)))
              (unless (member c seen) (set! seen (cons c seen)))
              (y-loop (+ y 1)))))
        (x-loop (+ x 1))))
    seen))

(define (inkiest colours)
  ;; The colour in COLOURS furthest from white: a glyph's own colour
  ;; rather than its antialiased edges or the cell's background.
  (let loop ((rest colours) (best #f) (far -1))
    (if (null? rest)
        best
        (let ((d (apply + (map (lambda (v) (- 255 v)) (car rest)))))
          (if (> d far)
              (loop (cdr rest) (car rest) d)
              (loop (cdr rest) best far))))))

;; Cell 4 is inside "keyword" (cells 3 to 9); point is at 0, so the match
;; is one of the *other* matches and gets `lazy-highlight'.
(define no-search-pixels (render-search "aa keyword bb" 3 10 #f))
(define searching-pixels (render-search "aa keyword bb" 3 10 "keyword"))
(define no-search-colours (cell-colours no-search-pixels 4))
(define searching-colours (cell-colours searching-pixels 4))
(define keyword-ink (inkiest no-search-colours))

;; the word is drawn in a colour of its own without a search...
(test-assert "a font-locked word is drawn in its face's colour"
  (not (equal? keyword-ink white)))
;; ...and the same colour with one, which is the merge.
;;
;; **The test is a *nearness* and not an equality, and Pango is why.**
;; The glyph is rasterized by Pango now rather than by Cairo's toy text
;; API, and the two antialias it slightly differently: measured, the toy
;; path leaves thirteen *fully inked* pixels in this glyph and Pango
;; leaves none, so its darkest pixel is a coverage blend - and a blend
;; over the search face's background is a different `(R G B)' from the
;; same blend over the cell's own, by one or two in each channel. The two
;; renderings are otherwise pixel-for-pixel the same picture (checked by
;; eye at 400%), so what the assertion is for - the *face* the word is
;; drawn in is unchanged by the search, only the background under it - is
;; measured as "as dark as before", which a face colour change would fail.
(test-assert "a search match keeps the face colour that was under it"
  (let ((search-ink (inkiest searching-colours)))
    (and keyword-ink search-ink
         (<= (- (apply + (map (lambda (v) (- 255 v)) search-ink)))
             (- (apply + (map (lambda (v) (- 255 v)) keyword-ink)))
             16))))
;; and the search face is drawn there at all - the cell's background is
;; what `lazy-highlight' changes
(test-assert "and the search face is drawn over it"
  (not (equal? (list (no-search-pixels (+ (* 4 9) 4) 16))
               (list (searching-pixels (+ (* 4 9) 4) 16)))))

;; The case above has a `face' text property, so the renderer is on its
;; face path either way. The one the shortcut broke is a buffer with *no*
;; text properties at all: `draw-line!' used to draw such a row in one
;; write with no face, so an overlay face was never looked up and the
;; match was invisible. Overlays are faces too, and the shortcut has to
;; ask whether this row has one.
(define (render-plain-search text pattern)
  ;; TEXT with no text properties at all, and PATTERN highlighted.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    (set-point ed 0)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (when pattern
          (is:isearch-lazy-highlight-update
           ed (fr:frame-selected-window frame) pattern #f))
        (xd:render! frame))
      (shot-of d))))

(define plain-pixels (render-plain-search "aa keyword bb" #f))
(define plain-search-pixels (render-plain-search "aa keyword bb" "keyword"))
(define (plain-cell pix) (list (pix (+ (* 4 9) 4) 16)))

(test-assert "a search is drawn on a buffer with no text properties"
  (not (equal? (plain-cell plain-pixels) (plain-cell plain-search-pixels))))

;; The mechanism behind it, without a display: the highlight is an
;; overlay carrying the face, so the display merges it like any other
;; overlay - `isearch-highlight' makes it, `isearch-dehighlight' removes
;; it, and the lazy highlighter makes one per other match.
(let* ((ed (allocate-buffer)))
  (with-current-buffer ed (insert "alpha beta alpha"))
  (set-point ed 0)
  (parameterize ((fr:*current-frame* (fr:new-frame ed 24 80)))
    (is:isearch-highlight 0 5)
    (is:isearch-lazy-highlight-update ed (fr:frame-selected-window
                                          (fr:*current-frame*))
                                      "alpha" #f)
    (test-equal "isearch-highlight puts the `isearch' face on an overlay"
      'isearch
      (let loop ((ovs (overlays-at 2 #t)))
        (and (pair? ovs)
             (if (eq? (overlay-get (car ovs) 'face) 'isearch)
                 'isearch
                 (loop (cdr ovs))))))
    ;; one overlay per match, so the list holds the position each match
    ;; *starts* at - "alpha" twice in "alpha beta alpha", at 1 and at 12
    (test-equal "and the lazy highlighter a `lazy-highlight' one per match"
      '(12 1)
      (let loop ((i 1) (acc '()))
        (if (> i 16)           ; the text's length, from `point-min'
            acc
            (loop (+ i 1)
                  (if (let loop-ovs ((ovs (overlays-at i #t)))
                        (and (pair? ovs)
                             (if (and (eq? (overlay-get (car ovs) 'face)
                                           'lazy-highlight)
                                      (= (overlay-start (car ovs)) i))
                                 #t
                                 (loop-ovs (cdr ovs)))))
                      (cons i acc)
                      acc)))))
    (is:isearch-dehighlight)
    (test-assert "isearch-dehighlight takes the `isearch' overlay away"
      (not (let loop ((ovs (overlays-at 3 #t)))
             (and (pair? ovs)
                  (if (eq? (overlay-get (car ovs) 'face) 'isearch)
                      #t
                      (loop (cdr ovs)))))))
    (is:lazy-highlight-cleanup #t)))

;;------------------------------------------------------------------
;; The `display' text property replaces a character on the screen
;;
;; GNU Emacs's `handle_display_prop': a character whose `display'
;; property is a string is *drawn* as that string while the buffer keeps
;; the character. Dired is what asks for it - `dired--insert-disk-space'
;; writes ": (15 GiB available)" over the header's colon - so this is one
;; of the few redisplay facts that changes what the user sees in Dired.
;;
;; Only the pixels can tell: the property is on the buffer either way and
;; every layout function would agree with itself. What is checked is that
;; the cells *past* the line's own last character have ink with the
;; property and none without it - which is the substitution, in the one
;; place a substitution can be seen.
;;------------------------------------------------------------------

(define (render-line text prop?)
  ;; A frame on a display showing TEXT, with the last character's
  ;; `display' property set to a long string when PROP?.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    (set-point ed 0)
    (when prop?
      (put-text-property (- (string-length text) 1) (string-length text)
                         'display ": (15 GiB available)" ed))
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    (shot-of d)))

(define (cell-has-ink? pix cell)
  ;; Whether any pixel of CELL is ink. **The whole cell is scanned**, not
  ;; a band inside it: it used to be y 3..15, which was "inside the glyph
  ;; band" of the 18-pixel cell this file used to assume, and once the
  ;; cell came from the font it was both taller and differently
  ;; positioned, so a real glyph fell outside the band and read as blank.
  ;;
  ;; `pix` positions are clipped to the surface, so a cell past the right
  ;; edge answers blank rather than erroring - which is what the loops
  ;; below rely on when they walk to cell 24.
  (let x-loop ((x 0))
    (cond ((>= x cell-w) #f)
          ((let y-loop ((y 0))
             ;; **The whole cell is scanned, and it is the font's** -
             ;; `cell-w' and `cell-h' above. It used to start at y 3 and
             ;; stop at 15, which was "inside the glyph band" of an
             ;; 18-pixel cell; a cell measured from the font is taller and
             ;; its glyph starts higher, so a fixed band misses ink and a
             ;; cell that has a character reads as blank.
             (cond ((>= y cell-h) #f)
                   ((not (equal? '(255 255 255)
                                 (pix (+ (* cell cell-w) x) y)))
                    #t)
                   (else (y-loop (+ y 1)))))
           #t)
          (else (x-loop (+ x 1))))))

(define colon-pixels (render-line "  /tmp:" #t))
(define plain-pixels (render-line "  /tmp:" #f))

;; `render-line` is called twice and each call makes its own display; the
;; second leaves ITS display current, and `shot-of` reads the one it is
;; handed - so the picture and the pixels agree. Nothing to do beyond
;; noting it: a display made later is not the one already photographed.

;; The line's own characters are drawn either way: cells 2..6 are
;; "/tmp:".
(test-assert "the line's own characters are drawn"
  (cell-has-ink? colon-pixels 2))
;; and with the property, so is "(15 GiB available)" - which is longer
;; than the character it replaces, so it reaches into cells the plain line
;; leaves empty.
(test-assert "a display property is drawn over the character it is on"
  ;; ": (15 GiB available)" is nineteen characters on a cell the plain
  ;; line ends at, so the row's last cell - 6 for the colon plus 19 less
  ;; one - carries its closing bracket. Counting the cells with ink would
  ;; depend on the font; naming two that are well inside it does not.
  (and (cell-has-ink? colon-pixels 12)
       (cell-has-ink? colon-pixels 24)))
(test-assert "and nothing is drawn there without it"
  ;; **From cell 8**, not 7: the plain line is `"  /tmp:"`, seven
  ;; characters in cells 0..6, and cell 7 is the column *after* it. The
  ;; loop used to start at 7 because the cursor was left at the end of
  ;; the insertion and `render-line` did not move point to 0 - so cell 7
  ;; held the cursor, not text. Point is at 1 now (`set-point`), the
  ;; cursor is on cell 0, and 7 is blank, which is what makes this a
  ;; check of the property rather than of where the cursor happened to
  ;; be.
  (let loop ((c 8))
    (cond ((>= c 25) #t)
          ((cell-has-ink? plain-pixels c) #f)
          (else (loop (+ c 1))))))

;; A face whose colour is named in a spec's `(min-colors 88)' or
;; `(min-colors 16)' branch must realize to a colour, and it did not:
;; every face realized to the plain token 0, so the GUI drew no face at
;; all. The cause was the *name*: those branches say "Firebrick",
;; "chocolate1", "DarkOrange" and "dark cyan", the table Emacs ships
;; (and this tree ports) spells them "firebrick", "chocolate1",
;; "darkorange" and "darkcyan", and a GUI frame resolves a name through
;; the X server, whose matching is case-insensitive and ignores spaces.
;; A terminal never met the difference, because its 8-colour branch
;; names "yellow", "red" and "magenta", spelled the same either way -
;; which is why this showed only under Gtk.
;;
;; These two are the faces the standard specs colour that way; the
;; MERGE is what the redisplay does before realizing (`merge-face-vectors'
;; resolves `:inherit'), and leaving it out is what made `dired-marked'
;; look uncoloured for a second reason.
(test-assert "a face named in the many-colour branch realizes to a colour"
  (let ((d (new-display)))
    (let ((w (realize d 'warning)))
      (and (> w 0) (not (= w plain-token))))))

(test-assert "an inheriting face realizes as what it inherits"
  ;; The merge by hand, because the `realize' helper above passes the
  ;; face's own attributes as they stand - which is what a test of the
  ;; interning wants, and not what the redisplay does. The redisplay
  ;; merges first: `merge-face-vectors' is "the function the display
  ;; reads faces with", and it is what resolves `:inherit'. Measured
  ;; before the colour-name fix: `dired-marked' realized to the plain
  ;; token on Gtk, for this reason as well as for the name one.
  (let* ((d (new-display))
         (rm (lambda (face)
               (f:face-spec-recalc face)
               (dn:realize-face d (x:merge-face-vectors
                                   (x:face-realized-attributes face) '())))))
    (list (= ((lambda () (rm 'dired-marked)))
             (rm 'warning))
          (> (rm 'dired-flagged) 0)
          (> (rm 'dired-mark) 0))))

;;------------------------------------------------------------------
;; Two frames, two windows, two scroll positions
;;
;; `render!' is a loop over frames here as it is in GNU Emacs
;; (`FOR_EACH_FRAME', `xdisp.c:14350'), and each frame's window is
;; scrolled to *its own* point. It used to bind `*current-frame*' to the
;; frame being drawn, which made that frame's window look like the
;; selected one - and `window-point' answers the buffer's point for the
;; selected window - so a second frame's window was scrolled to the
;; first frame's point and the two moved together.
;;
;; Measured on Emacs 31.1 with two frames on one buffer, point at 300 in
;; a 24-row frame: the selected frame's `window-start' is 232 and the
;; other frame's is still 1.
;;------------------------------------------------------------------
(test-equal '(#t #t)
  (parameterize ((fr:*frame-list* '()))
    (let* ((d1 (make pt:<pgtk-display>))
           (d2 (make pt:<pgtk-display>)))
      (dn:current-display d1)
      (pt:initialize-pgtk-faces! d1)
      (pt:initialize-pgtk-faces! d2)
      (let ((ed (allocate-buffer)))
        (with-current-buffer ed (insert (apply string-append
                   (map (lambda (i) "aaaaaaaaaa\n")
                        (let loop ((i 1) (acc '()))
                          (if (> i 60) (reverse acc)
                              (loop (+ i 1) (cons i acc))))))))
        (set-point ed 1)
        (let ((f1 (fr:new-frame-on d1 ed 24 80))
              (f2 (fr:new-frame-on d2 ed 24 80)))
          (parameterize ((fr:*current-frame* f1))
            (set-point ed 300)
            (xd:render! f1)
            (xd:render! f2)
            (list (= 1 (xd:window-start (fr:frame-selected-window f2)))
                  (> (xd:window-start (fr:frame-selected-window f1)) 1))))))))

;;------------------------------------------------------------------
;; Rows are *pixels*, and a window's text starts at its own top edge
;;
;; `write-glyphs!` takes a pixel y - Emacs's `glyph->y` in a glyph
;; matrix - and a font cell is 20 pixels tall, not one. Two things were
;; being given a row index where a pixel offset belongs:
;;
;;   1. `row->pixel-y` multiplied by `line-height`, which on a windowed
;;      display is 1 - the redisplay's *unit*, not `FRAME_LINE_HEIGHT`.
;;      The mode line of a 24-row frame therefore drew at pixel 23 of
;;      480, at the top of the window. Chris, using it: "the gtk
;;      interface is broken it shows the mode line at the top".
;;   2. the text walk started at y 0 rather than at the window's own top
;;      edge, so a split window's lower half painted over the upper
;;      half's first rows.
;;
;; **A `<test-display>` is what can see this**, which is why the test is
;; here rather than on a pgtk display: it takes a *cell* as a keyword and
;; records every draw's y, so a 20-pixel cell is one `#:line-height 20`
;; and the recorded y values are the renderer's own. The bugs above were
;; invisible precisely because a display whose cell is 1 makes the row
;; index and the pixel offset the same number.
;;------------------------------------------------------------------
;; **The mode line is at the *bottom*, in real pixels.** `row->pixel-y`
;; multiplied a row index by `line-height`, which on this display is 1 -
;; the redisplay's *unit*, not `FRAME_LINE_HEIGHT` (20 pixels). So the
;; mode line of a 24-row frame drew at pixel 23 of 480: a band two rows
;; from the top, on top of the first lines of text. Chris, using the
;; real window: "the gtk interface is broken it shows the mode line at
;; the top".
;;
;; **The check has to run on a *pgtk* display, not a `<test-display>`.**
;; A test display answers `line-height` with its own pixel cell, so the
;; wrong multiplier is the right number there and the bug hides - which
;; is precisely why this shipped. This display's unit is 1 and its cell
;; is 20, which is the pair that tells them apart.
(define (band-ink pix cell y0 y1)
  ;; How many pixels of the rows [Y0, Y1) are not the background, the
  ;; grid being 80 cells across at CELL's width.
  ;;--------------------------------------------------------------
  (let ((cw (car cell)))
    (let loop ((x 0) (y y0) (n 0))
      (cond ((>= y y1) n)
            ((>= x (* 80 cw)) (loop 0 (+ y 1) n))
            (else (loop (+ x 1) y
                        (if (equal? (pix x y) white) n (+ n 1))))))))

(test-equal "the mode line inks the frame's last text row, not the top"
  '(#t #t)
  (parameterize ((fr:*frame-list* '()))
    (let* ((d (new-display))
           (ed (allocate-buffer))
           (f (fr:new-frame-on d ed 24 80)))
      (with-current-buffer ed (insert "hello\nworld"))
      (parameterize ((fr:*current-frame* f))
        (xd:render! f)
        (let* ((pix (shot-of d))
               ;; **The cell is asked for *now***, after the redisplay has
               ;; opened the font: `*cell-height*` starts at the module's
               ;; 18 and becomes the font's 20 when it is realized, so a
               ;; value taken at load time measures the wrong bands.
               (cell (pt:pgtk-cell-size))
               (ch (cdr cell)))
          ;; A frame of 24 rows has 23 text rows and the echo area as its
          ;; last row, so the window - which fills the frame - has its
          ;; mode line on row 22. That row carries the mode line's own
          ;; inverse-video band across the whole width: the text is padded
          ;; to the window's 80 columns, so the band is the full 720
          ;; pixels.
          ;;
          ;; A row index mistaken for a pixel offset put that band at
          ;; pixel 23 instead - inside the *first* line of text - which is
          ;; what Chris saw as "the mode line at the top". Row 0 carries
          ;; the buffer's own `hello`, a handful of glyphs and nothing
          ;; else: the mode line's band would cover the full width.
          (list
           ;; the whole band: every pixel of the 80-cell row is inked
           (= (band-ink pix cell (* 22 ch) (* 23 ch)) (* 80 (car cell) ch))
           ;; and row 0 holds only the buffer's text, a fraction of that
           (< (band-ink pix cell 0 ch) (* 20 (car cell) ch))))))))

;; And on a *split* window: the lower window's first text row is one cell
;; below the upper window's mode line, not on top of it.
;;
;; The upper window is 5 rows of text plus its mode line at pixel 80, and
;; then one blank cell - the rest of its text area - before the lower
;; window's text begins at 100. It was 0, which drew the second window's
;; rows over the first window's.
(test-equal 100
  (parameterize ((fr:*frame-list* '()))
    (let* ((d (make td:<test-display> #:rows 12 #:columns 40
                    #:line-height 20 #:column-width 9))
           (ed (allocate-buffer))
           (f (fr:new-frame-on d ed 12 40)))
      (dn:current-display d)
      (with-current-buffer ed
        (let loop ((i 0))
          (when (< i 20) (insert "L\n") (loop (+ i 1)))))
      (parameterize ((fr:*current-frame* f))
        (window:split-window-below 5 (fr:selected-window))
        (xd:render! f)
        ;; The lower window's first text row is found by its *pixel
        ;; position*, not by counting draw calls: a mode line is a run
        ;; per face now (the buffer name carries `mode-line-buffer-id`),
        ;; so the fifth call is no longer a fixed thing.
        (let loop ((glyphs (reverse (td:test-display-glyphs d))))
          (cond ((null? glyphs) #f)
                ((>= (cadr (car glyphs)) 100) (cadr (car glyphs)))
                (else (loop (cdr glyphs)))))))))

;;------------------------------------------------------------------
;; The echo area belongs to one frame
;;
;; GNU Emacs's `echo_area_window' is
;; `FRAME_MINIBUF_WINDOW (SELECTED_FRAME ())' (`xdisp.c:13782'), and
;; `redisplay_window' draws the message only for a window that *is* that
;; one (`:20526'); every other frame's minibuffer window is left blank.
;; Drawing it on all of them is what put the prompt - and, with it, every
;; character typed into the minibuffer - into every frame at once.
;;
;; This is a pixel check because that is where the bug was: the message
;; still *belonged* to the right frame all along, and what was wrong was
;; which frames it got painted on.
;;------------------------------------------------------------------

;; `echo-row-ink` measures the *message*, so the row it looks at must be
;; the one the message goes on. That is decided by the frame's own echo
;; area, `(fr:frame-message frame)` - not by the surface's last rows,
;; which are whatever the frame's height happens to be.

(define (echo-row-ink pix)
  ;; How many pixels of the frame's last row are not the background -
  ;; the echo area's row, which is where a message is drawn.
  ;;
  ;; The echo area is the frame's last *text row*: row 23 of 24, in the
  ;; display's grid, which is where a message is drawn. The surface is
  ;; that grid times the cell, so the row starts at `(* 23 cell-h)`.
  ;;--------------------------------------------------------------
  (let loop ((x 0) (y (* 23 cell-h)) (n 0))
    (cond ((>= y (* 24 cell-h)) n)
          ((>= x (* 80 cell-w)) (loop 0 (+ y 1) n))
          (else (loop (+ x 1) y
                      (if (equal? (pix x y) white) n (+ n 1)))))))

(test-equal '(#t #t)
  (parameterize ((fr:*frame-list* '()))
    (let* ((d1 (make pt:<pgtk-display>))
           (d2 (make pt:<pgtk-display>)))
      (dn:current-display d1)
      (pt:initialize-pgtk-faces! d1)
      (pt:initialize-pgtk-faces! d2)
      (let* ((ed (allocate-buffer))
             (f1 (fr:new-frame-on d1 ed 24 80))
             (f2 (fr:new-frame-on d2 ed 24 80)))
        (parameterize ((fr:*current-frame* f1))
          ;; **Both messages are set before either frame is drawn**, and
          ;; each frame is drawn and photographed on its own. Setting F1's
          ;; message *after* F2 was drawn is what made this fail inside
          ;; the suite and pass alone: the transient map of tests before
          ;; this one can leave `*current-frame*` and the echo area buffer
          ;; in a state where the second `set!frame-message` clears the
          ;; buffer the first one draws from, and a frame drawn from a
          ;; shared echo buffer shows whatever was set last.
          (fr:set!frame-message f2 "a message for the frame that is not selected")
          (fr:set!frame-message f1 "a message for the selected frame")
          (xd:render! f2)
          (let ((blank (zero? (echo-row-ink (shot-of d2)))))
            (xd:render! f1)
            (list blank (> (echo-row-ink (shot-of d1)) 0))))))))

;;------------------------------------------------------------------
;; The pointer's glyph filter
;;
;; GNU Emacs's `note_mouse_movement' (`pgtkterm.c:5892'): "If the mouse is
;; over a different glyph than it was last time, tell the mainstream emacs
;; code by setting mouse_moved. If not, ask for another motion event, so we
;; can check again the next time it moves." The `mouse-movement' event is
;; then made by the *reader* (`some_mouse_moved', `keyboard.c:4525'), once,
;; from a queried position - not by the signal, once per report.
;;
;; This is what makes a drag past the edge of a window keep scrolling, and
;; a front end that makes an event per raw report cannot do it: the scroll
;; loop ends on any input, so it ends on every twitch of the mouse.
;;------------------------------------------------------------------

(define (movement-report! d column row)
  ;; One Gtk motion report, through the front end's own entry point.
  ;;--------------------------------------------------------------
  (pt:note-mouse-movement d column row))

(let* ((d (new-display))
       (f (fr:new-frame-on d (allocate-buffer) 24 80)))
  (parameterize ((fr:*current-frame* f))
    (test-equal #f (pt:pgtk-mouse-moved d))
    (test-equal "the first report is a movement, there being no glyph yet"
      #t (movement-report! d 3 4))
    (test-equal #t (pt:pgtk-mouse-moved d))
    ;; ...and having been made into an event, it is not one any more.
    (set! (pt:pgtk-mouse-moved d) #f)
    (test-equal "a report on the cell the pointer is already on is not one"
      #f (movement-report! d 3 4))
    (test-equal #f (pt:pgtk-mouse-moved d))
    (test-equal "a report on another cell is a movement again"
      #t (movement-report! d 3 5))))

(test-equal "the glyph a report is compared against is its cell"
  (list 7 9 1 1)
  (let ((d (new-display)))
    (parameterize ((fr:*current-frame* (fr:new-frame-on d (allocate-buffer) 24 80)))
      (xd:remember-mouse-glyph (fr:*current-frame*) 7 9))))

;;------------------------------------------------------------------
;; Reading our own selection - `pgtk_get_local_selection'
;;
;; **None of this needs a window, a Gtk init or a clipboard.** Emacs
;; answers a read of a selection *it owns* out of its own record
;; (`LOCAL_SELECTION') and through `selection-converter-alist', never
;; going to the server - which is why `(gui-get-selection 'CLIPBOARD
;; 'TARGETS)' can answer with the target vector rather than with the
;; text. The record is set here by hand, because `set-selection!' would
;; have to call `gtk_clipboard_set_text' and this display has no Gtk.
;;
;; The C is `pgtk_get_local_selection' (`pgtkselect.c:236') and the
;; DEFUN above it, `pgtk-get-selection-internal' (`:1606').
;;------------------------------------------------------------------

(define (owning-display selection value)
  ;; A display that has asserted SELECTION holding VALUE, as
  ;; `pgtk_own_selection' writes the record: `(SELECTION VALUE TIMESTAMP
  ;; FRAME)' (`pgtkselect.c:151-160').
  ;;--------------------------------------------------------------
  (let* ((d (new-display))
         (f (fr:new-frame-on d (allocate-buffer) 24 80)))
    (set! (pt:pgtk-selections d) (list (list selection value 7 f)))
    d))

(define (read-selection d selection target)
  (pt:pgtk-get-selection-internal d selection target #f #f))

;; A text target answers the value itself, and **no encoding is
;; involved**: the C passes a nil TYPE to the converter for a local
;; request, which is what `xselect--encode-string''s first line is for.
(test-equal "a local read of a text target is the value as it stands"
  "hello there" (read-selection (owning-display 'CLIPBOARD "hello there") 'CLIPBOARD 'STRING))

(test-equal "and for each of the text targets" '("hello there" "hello there" "hello there")
  (let ((d (owning-display 'CLIPBOARD "hello there")))
    (list (read-selection d 'CLIPBOARD 'UTF8_STRING)
          (read-selection d 'CLIPBOARD 'TEXT)
          (read-selection d 'CLIPBOARD '#{text/plain;charset=utf-8}#))))

;; `TIMESTAMP' never reaches a converter: it is the C's special case and
;; answers element 2 of the record. It used to answer #f.
(test-equal "TIMESTAMP answers the recorded timestamp" 7
  (read-selection (owning-display 'CLIPBOARD "hello") 'CLIPBOARD 'TIMESTAMP))

;; The target vector - `xselect-convert-to-targets', which is the whole
;; point of the local path being local. TIMESTAMP and MULTIPLE lead it
;; (`select.el:673'), and every target in the converter table follows.
(test-equal "TARGETS is a vector beginning with TIMESTAMP and MULTIPLE"
  #t
  (let* ((v (read-selection (owning-display 'CLIPBOARD "hello") 'CLIPBOARD 'TARGETS))
         (l (vector->list v)))
    (and (vector? v)
         (equal? (list-head l 2) '(TIMESTAMP MULTIPLE))
         (and (memq 'STRING l) (memq 'UTF8_STRING l)
              (memq 'TARGETS l) (memq 'SAVE_TARGETS l) #t))))

;; bug#72254: a TARGETS answer is a vector even when it holds one item,
;; "producing issues with programs that expect the TARGETS property
;; always to return vectors".
(test-equal "a TARGETS answer is always a vector"
  #t
  (let ((v (read-selection (owning-display 'CLIPBOARD "x") 'CLIPBOARD 'TARGETS)))
    (vector? v)))

;; A symbol value converts to its name for `STRING'? No - **it does not,
;; and that is Emacs's behaviour**: `xselect-convert-to-string' takes a
;; string, and a symbol goes to `xselect-convert-to-atom', which answers
;; the symbol. This is what makes an `ATOM' target work and a `STRING'
;; one answer nil for the same value.
(test-equal "a symbol value answers the ATOM target and not STRING"
  '(foo #f)
  (let ((d (owning-display 'CLIPBOARD 'foo)))
    (list (read-selection d 'CLIPBOARD 'ATOM)
          (read-selection d 'CLIPBOARD 'STRING))))

;; LENGTH is the string's length as the protocol's `(HIGH . LOW)' pair,
;; and `clean_local_selection_data' turns that pair back into the number
;; - which is the C's `(cons_to_signed obj 16)' pairing
;; (`pgtkselect.c:1547').
(test-equal "LENGTH comes back as a number, not as its two halves" 11
  (read-selection (owning-display 'CLIPBOARD "hello there") 'CLIPBOARD 'LENGTH))

;; An INTEGER value, the same round trip the other way.
(test-equal "an integer value answers INTEGER as the number" 300
  (read-selection (owning-display 'CLIPBOARD 300) 'CLIPBOARD 'INTEGER))

;; `_EMACS_INTERNAL' is `xselect-convert-to-identity': the value as a
;; one-element vector, which `clean_local_selection_data' unwraps again.
(test-equal "the identity target round-trips" "hello"
  (read-selection (owning-display 'CLIPBOARD "hello") 'CLIPBOARD '_EMACS_INTERNAL))

;; A target with no converter is nil, which is "we do not know how to do
;; this conversion" - the C's `(else value = Qnil)'.
(test-equal "an unknown target answers #f" #f
  (read-selection (owning-display 'CLIPBOARD "hello") 'CLIPBOARD 'NO_SUCH_TARGET))

;; A selection we do not own has no local record at all, and the answer
;; is nil before any converter is consulted - the C's
;; `(if (NILP (local_value)) return Qnil)'.
(test-equal "a selection we do not own has no local value" #f
  (pt:pgtk-get-local-selection (new-display) 'CLIPBOARD 'STRING #t))

;; `SAVE_TARGETS' answers the *symbol* `NULL' - not nil - and that is
;; Emacs: `xselect-convert-to-save-targets' returns `'NULL', and NULL is
;; "we did the conversion and have no value", which is a different answer
;; from "we do not know how to do this conversion". It is what tells a
;; freedesktop clipboard manager the selection can be saved. `DELETE' is
;; the other NULL answer, and it *acts* on the way - see below.
(test-equal "SAVE_TARGETS on CLIPBOARD answers the symbol NULL" 'NULL
  (read-selection (owning-display 'CLIPBOARD "hello") 'CLIPBOARD 'SAVE_TARGETS))

;; The same target on a selection that is not the CLIPBOARD answers nil:
;; `(when (eq selection 'CLIPBOARD) 'NULL)'.
(test-equal "SAVE_TARGETS on PRIMARY answers nothing at all" #f
  (read-selection (owning-display 'PRIMARY "hello") 'PRIMARY 'SAVE_TARGETS))

;; MULTIPLE is refused by the DEFUN, as in the C.
(test-equal "MULTIPLE errors" #t
  (let ((d (owning-display 'CLIPBOARD "hello")))
    (guard (e (#t #t))
      (read-selection d 'CLIPBOARD 'MULTIPLE)
      #f)))

;; The data decode, driven directly - `selection_data_to_lisp_data''s
;; table. These are the C's own rows.
(test-equal "format 8 decodes to a string" "abc"
  (pt:selection-data-to-lisp-data #vu8(97 98 99) 3 "STRING" 8))
(test-equal "a format-16 non-INTEGER decodes to a vector"
  '#(1 2) (pt:selection-data-to-lisp-data #vu8(1 0 2 0) 4 "FOO" 16))
(test-equal "a format-32 non-INTEGER decodes to a vector"
  '#(1 2) (pt:selection-data-to-lisp-data
           #vu8(1 0 0 0 2 0 0 0) 8 "FOO" 32))
(test-equal "a single format-32 INTEGER decodes to a number"
  5 (pt:selection-data-to-lisp-data #vu8(5 0 0 0) 4 "INTEGER" 32))
(test-equal "a negative format-32 INTEGER stays negative"
  -1 (pt:selection-data-to-lisp-data
      #vu8(255 255 255 255) 4 "INTEGER" 32))
(test-equal "a single format-16 INTEGER decodes to a number"
  5 (pt:selection-data-to-lisp-data #vu8(5 0) 2 "INTEGER" 16))
;; A UTF-8 clipboard is decoded by the coding system the data *type*
;; names, which is select.el's rule (`select.el:391') done one function
;; earlier - see `selection-bytes->string'.
(test-equal "format 8 decodes UTF-8 bytes to their characters" "café"
  (pt:selection-data-to-lisp-data #vu8(99 97 102 195 169) 5 "UTF8_STRING" 8))
(test-equal "the NULL type answers nothing"
  #f (pt:selection-data-to-lisp-data #vu8() 0 "NULL" 32))

;;------------------------------------------------------------------
;; The popup's tree - `pgtk_popup_build_tree` (`pgtkmenu.c:616-771`)
;;
;; `pgtk_menu_show` is in three parts: build a `widget_value' tree from
;; `menu_items`, turn it into a `GtkMenu` and run a loop until it pops
;; down, then walk the array back from the selected index to the entry.
;; The middle part needs a window; the *first* is a pure function of the
;; array and the flags, and it is where the three rules live that a
;; reader would not guess:
;;
;;   * a pane is a submenu only when it has a name *and* the menu is not
;;     a keymap menu - `!(menuflags & MENU_KEYMAPS) && *pane_string`;
;;   * a lone top-level pane is flattened whatever the flags say
;;     (`menu_items_n_panes == 1`), because one submenu is noise;
;;   * the title is prepended with **two** separators beneath it, which
;;     is what draws the rule under a dialog's heading.
;;
;; Every number and every shape below comes from that C loop.
;;--------------------------------------------------------------

(define (menu-names wv)
  ;; The NAME of WV and of everything its `next' reaches, in order.
  (let loop ((w wv) (out '()))
    (if (not w)
        (reverse out)
        (loop (menu:widget-value-next w)
              (cons (menu:widget-value-name w) out)))))

(define (pane-names wv)
  ;; Each pane's NAME paired with the names of the items under it - the
  ;; shape the two rules above disagree about.
  (let loop ((pane wv) (out '()))
    (if (not pane)
        (reverse out)
        (loop (menu:widget-value-next pane)
              (cons (list (menu:widget-value-name pane)
                          (menu-names (menu:widget-value-contents pane)))
                    out)))))

(test-equal "an old-fashioned menu's named panes become submenus"
  '(("P1" ("One")) ("P2" ("Two")))
  (begin
    (menu:list-of-panes '(("P1" ("One" . one)) ("P2" ("Two" . two))))
    (pane-names (menu:widget-value-contents (pt:pgtk-popup-build-tree 0 #f)))))

(test-equal "a keymap menu puts every pane's items directly under the menu"
  '("One" "Two")
  (begin
    (menu:list-of-panes '(("P1" ("One" . one)) ("P2" ("Two" . two))))
    (menu-names (menu:widget-value-contents
                 (pt:pgtk-popup-build-tree menu:MENU-KEYMAPS #f)))))

(test-equal "one top-level pane is flattened whatever the flags say"
  '(("Only") ("Only"))
  (begin
    (menu:list-of-panes '(("Solo" ("Only" . only))))
    (let ((plain (menu-names (menu:widget-value-contents
                              (pt:pgtk-popup-build-tree 0 #f)))))
      (menu:list-of-panes '(("Solo" ("Only" . only))))
      (list plain
            (menu-names (menu:widget-value-contents
                         (pt:pgtk-popup-build-tree menu:MENU-KEYMAPS #f)))))))

(test-equal "the tree's root is the `menu' pseudo-item"
  '("menu" #t)
  (begin
    (menu:list-of-panes '(("Solo" ("Only" . only))))
    (let ((root (pt:pgtk-popup-build-tree 0 #f)))
      (list (menu:widget-value-name root) (menu:widget-value-enabled? root)))))

(test-equal "a title is prepended above two separators"
  '("A Title" "--" "--" "Only")
  (begin
    (menu:list-of-panes '(("Solo" ("Only" . only))))
    (menu-names (menu:widget-value-contents
                 (pt:pgtk-popup-build-tree 0 "A Title")))))

(test-equal "the title itself is an unselectable plain item"
  '(#t none)
  (begin
    (menu:list-of-panes '(("Solo" ("Only" . only))))
    (let ((title (menu:widget-value-contents
                  (pt:pgtk-popup-build-tree 0 "A Title"))))
      (list (menu:widget-value-enabled? title)
            (menu:widget-value-button-type title)))))

;; The selection callback hands back an index into `menu_items', and the
;; walk-back compares it against the slot it is standing on - so the
;; index has to be the item's own, panes counted. A pane is 3 slots and
;; an item 8 (`keyboard.h:358`), so a one-pane old-fashioned list puts
;; its first item at 3 and a two-pane one puts the second pane's first
;; item at 3 + 8 + 3 = 14.
(test-equal "an item's call_data is its index in the menu_items array"
  3
  (begin
    (menu:list-of-panes '(("Solo" ("Only" . only))))
    (menu:widget-value-call-data
     (menu:widget-value-contents (pt:pgtk-popup-build-tree 0 #f)))))

(test-equal "the index counts the panes and items before it"
  14
  (begin
    (menu:list-of-panes '(("P1" ("One" . one)) ("P2" ("Two" . two))))
    (menu:widget-value-call-data
     (menu:widget-value-contents
      (menu:widget-value-next
       (menu:widget-value-contents (pt:pgtk-popup-build-tree 0 #f)))))))

;; A bare string in the old list form is a disabled label - Emacs's
;; `list_of_items` pushes it with ENABLE nil (`menu.c:470`) - and the
;; tree keeps that as `enabled` false rather than dropping it. The pane
;; is the flattening case above, so its two items sit directly under the
;; root.
(test-equal "a bare string is a disabled item, not a missing one"
  '(#f #t)
  (begin
    (menu:list-of-panes '(("Solo" "Label" ("Live" . live))))
    (let ((first (menu:widget-value-contents
                  (pt:pgtk-popup-build-tree 0 #f))))
      (list (menu:widget-value-enabled? first)
            (menu:widget-value-enabled? (menu:widget-value-next first))))))


(test-end "schemacs_editor_pgtk")
