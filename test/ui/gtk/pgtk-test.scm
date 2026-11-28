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
 (only (schemacs editfns) insert propertize)
 (scheme base)
 (scheme char)
 (only (guile) setvbuf delete-file getpid)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) make compute-applicable-methods)
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
               pgtk-popup-build-tree
               ;; The input queue and its drain: a key that arrives while
               ;; the editor is busy must not be stranded.
               pgtk-queue pgtk-drain-queue!
               ;; The bar-patch rules - see the groups at the end:
               ;; enabled-only changes are patched, anything else
               ;; rebuilds.
               pgtk-menubar-widgets pgtk-menubar-widget-at
               pgtk-toolbar-enable-slots-only?)
         pt:)
 (prefix (schemacs faces) f:)
 ;; The command this file can test and the terminal suites cannot: it is
 ;; graphic-only, so a windowed display is the only place it runs.
 (prefix (only (schemacs face-remap)
               global-text-scale-adjust text-scale-increase
               text-scale-decrease
               text-scale-mode-amount face-remapping-alist)
         scale:)
 (prefix (schemacs xfaces) x:)
 (prefix (schemacs xdisp) xd:)
 (prefix (schemacs dispnew) dn:)
 (prefix (schemacs frame) fr:)
 (prefix (only (schemacs test-display)
               <test-display> test-display-glyphs) td:)
 ;; A run drawn by hand at a place only a taller row could put it - the
 ;; text-area clip's check below.
 (only (schemacs glyph) make-glyph make-glyph-row
       glyph-row-ascent glyph-row-height glyph-row-y
       glyph-row-enabled? glyph-row-displays-text?
       glyph-row-continued? glyph-row-continuation-line?
       glyph-row-glyphs glyph-row-used glyph-row-x glyph-pixel-width
       set-glyph-row-enabled!)
 (only (schemacs matrix) glyph-matrix-rows window-desired-matrix
       window-current-matrix make-glyph-matrix matrix-diff-rows)
 (prefix (schemacs window) window:)
 
 (only (schemacs buffer) buffer-local-value set-buffer-local-value!
       %mark-marker with-current-buffer
 set-point allocate-buffer buffer-pt get-buffer-create
 set!buffer-word-wrap buffer-word-wrap)
 ;; the mark's read and write are marker.c's now, on the buffer's own
 ;; slot; `text-editor-mark`/`set!text-editor-mark` are gone.
 (only (schemacs marker) marker-position set-marker)
 (only (schemacs textprop) put-text-property)
 (prefix (schemacs isearch) is:)
 (only (schemacs buffer) overlays-at overlay-get overlay-start)
 ;; Imported for the *faces* it defines - `dired-marked' and the two
 ;; beside it are dired.el's own `defface's - which the test below
 ;; realizes. Loaded by both front ends in the real editor, so this is
 ;; not a test-only dependency.
 (only (schemacs dired))
 ;; `tsdh-dark`'s mode-line names no foreground - the case below.
 (only (schemacs theme) load-theme disable-theme)
 (only (schemacs keyboard) dispatch-input-event)
 ;; The display interface's own generics: the pointer queries must be
 ;; methods *of these*, not of a generic privately made in `pgtk.scm`.
 (only (schemacs dispnew)
       display-mouse-absolute-pixel-position display-set-mouse-pixel-position
       display-raise-frame)
 ;; The `menu_items` array the popup's tree is built from, and the
 ;; `widget_value` accessors the checks below read it back with.
 (prefix (only (schemacs menu)
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
 (cons '(left-fringe . 0)
       (cons '(right-fringe . 0)
             (cons '(menu-bar-lines . 0) (fr:*default-frame-alist*)))))

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
;; `xdisp.sld''s `extend-fill-token' compares a realized face with the
;; default's, so a display must hand back an integer, and 0 must be the
;; plain face. A GUI cannot answer an opaque record.
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
;; The cursor on a blank line leaves the region under it
;;
;; Point on an empty line is on its newline, column 0, and
;; `display_line` gives that newline a space glyph carrying its face
;; (`append_space_for_newline`, `xdisp.c:26597`); the cursor sits on
;; that glyph and `erase_phys_cursor` redraws the *row's* glyph with its
;; own face (`draw_phys_cursor_glyph`, `:35105`). Reading the glyph from
;; the buffer instead answered the default face, so every redisplay
;; repainted the cell the cursor sat on white - a hole in the region's
;; first cell, and only the first, because that is where the newline is
;; on an empty line.
;;
;; **The check needs two redisplays and a hollow cursor.** The first
;; records the cursor; the second's erase repaints the cell (with
;; nothing changed, the row diff skips the row, so the erase is the
;; only paint). A filled box would cover the cell - a frame that is not
;; focused draws the hollow one, whose interior is what the erase left.
;;------------------------------------------------------------------

(define (render-blank-region)
  ;; "aaa\n\nbbb\n", the region [5, 9): the blank line at 5 is the
  ;; region's first line and point 5 puts the cursor on its column 0.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert "aaa\n\nbbb\n"))
    (set-point ed 5)
    (set-marker (%mark-marker ed) 9 ed)
    (set-buffer-local-value! ed 'mark-active #t)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame)
                     (fr:*frame-focus* #f))
        (xd:render! frame)
        ;; **The steady state has nothing to redraw.** A redisplay with
        ;; no change leaves the rows alone and only the cursor is
        ;; repainted; the test display's face realization sets the
        ;; strong flag on the first render, so clear it to stand in for
        ;; the steady-state loop the user sees.
        (dn:set-windows-or-buffers-changed! #f)
        (xd:render! frame)))
    (shot-of d)))

(define blank-shot (render-blank-region))
;; The middle of row 1's first cell - the cell the cursor has just left.
(test-equal "the cursor on a blank line keeps the region in its cell"
            lightgoldenrod2
            (blank-shot 4 (+ cell-h (quotient cell-h 2))))
;; The cell beside it is the same region.
(test-equal lightgoldenrod2
            (blank-shot (+ cell-w 4) (+ cell-h (quotient cell-h 2))))

;;------------------------------------------------------------------
;; A face change repaints the *blank* rows as well
;;
;; GNU Emacs's `realize_face` ends its "remove the former face" branch
;; with `SET_FRAME_GARBAGED (cache->f)` (`xfaces.c:6252`), because
;; replacing a face's realization leaves every pixel of the old one
;; stale - and some of those pixels are under no glyph at all. A blank
;; row on a window-system frame is exactly that: `build-blank-row!`
;; fills glyphs on a terminal and lets the backend paint the remainder
;; here, so the diff finds the row equal to what was drawn and skips it.
;;
;; Measured before the fix, on this offscreen frame: after setting
;; `default`'s background black, a pixel in the text row read (0 0 0)
;; and one in a blank row still read (255 255 255) - the old colour.
;;------------------------------------------------------------------

(define (retheme-blank-row)
  ;; The pixel 5 cells into the row below the one line of text, before
  ;; and after the default face's background changes.
  (let* ((d (new-display))
         (ed (allocate-buffer))
         (was (f:face-attribute 'default ':background)))
    (with-current-buffer ed (insert "hello\n"))
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame))
      (let ((before (shot-of d)))
        (f:set-face-attribute 'default #f ':background "black")
        (parameterize ((fr:*current-frame* frame))
          (xd:render! frame))
        (let ((after (shot-of d))
              (y (* 10 cell-h)))
          ;; put the face back, so the checks below see the light frame
          (f:set-face-attribute 'default #f ':background was)
          (list (before 5 y) (after 5 y)))))))

(let ((shot (retheme-blank-row)))
  (test-equal "a blank row is drawn in the default face's background"
              white (car shot))
  (test-equal "and a change to that face reaches it"
              '(0 0 0) (cadr shot)))

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
;; (`(schemacs face-remap)') does: it sets the face's height and
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
;; `text-scale-adjust` - the buffer-local scaling, in its own window
;;
;; Emacs's `text-scale-mode` does not touch the `default` face's own
;; `:height`; it puts a *relative* one in the buffer's
;; `face-remapping-alist`, and the display merges that when it realizes
;; the face. Stage 3 of `plans/PER-FACE-FONTS.md`: the frame's font comes
;; from the `default` face's own attributes, and the scaling is the row's
;; - so a scaled buffer's lines are taller while the frame's grid, its
;; neighbour's lines and its cell stay the size they were.
;;------------------------------------------------------------------

(define (scaled-window-rows)
  ;; A frame with two windows: the selected one on a buffer scaled by
  ;; three steps, the other on an unscaled one. Answers
  ;; (CELL-BEFORE CELL-AFTER FRAME-ASCENT UPPER-ASCENT LOWER-ASCENT
  ;;  UPPER-HEIGHT LOWER-HEIGHT).
  (let* ((d (new-display))
         (scaled (allocate-buffer))
         (plain (allocate-buffer)))
    (with-current-buffer scaled (insert "M"))
    (with-current-buffer plain (insert "M"))
    (let* ((frame (fr:new-frame scaled 24 80))
           (cell-before (pt:pgtk-cell-size)))
      (parameterize ((fr:*current-frame* frame))
        (window:split-window-below 5 (fr:frame-selected-window frame))
        (let* ((windows (fr:window-list frame #f))
               (upper (car windows))
               (lower (cadr windows)))
          (fr:set-window-buffer! lower plain)
          (with-current-buffer scaled (scale:text-scale-increase 3))
          (xd:render! frame)
          (let* ((cell-after (pt:pgtk-cell-size))
                 (frame-metrics (dn:face-metrics d #f))
                 (upper-row (vector-ref
                             (glyph-matrix-rows
                              (window-desired-matrix upper)) 0))
                 (lower-row (vector-ref
                             (glyph-matrix-rows
                              (window-desired-matrix lower)) 0))
                 (answer (list cell-before cell-after
                               (car frame-metrics)
                               (glyph-row-ascent upper-row)
                               (glyph-row-ascent lower-row)
                               (glyph-row-height upper-row)
                               (glyph-row-height lower-row))))
            (with-current-buffer scaled (scale:text-scale-increase 0))
            answer))))))

(define scaled-windows (scaled-window-rows))

(test-equal "text-scale leaves the frame's cell alone"
  (list-ref scaled-windows 0) (list-ref scaled-windows 1))

(test-equal "the unscaled window's row is the frame's own line"
  (list-ref scaled-windows 2) (list-ref scaled-windows 4))

(test-assert "the scaled window's row is taller than the frame's line"
  (> (list-ref scaled-windows 3) (list-ref scaled-windows 2)))

(test-assert "and so is its height, in the same frame"
  (> (list-ref scaled-windows 5) (list-ref scaled-windows 6)))

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
          ;; **One message, on one frame.** F2 never gets one, so its
          ;; echo row must be blank however F1's is drawn - and this is
          ;; the check for the echo buffer being *the frame's*: with a
          ;; single shared ` *Echo Area 0*` (which is what
          ;; `get-buffer-create` gives you, and what this had first) F1's
          ;; write lands in the buffer F2 draws from and F2 shows F1's
          ;; message. Emacs's `echo_buffer[]` is global and does not have
          ;; this problem only because it is displayed on the selected
          ;; frame alone; this tree's messages are per frame, so the
          ;; buffers are too.
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
  ;; The entry point takes the position in *pixels*, as `posn-at-x-y`
  ;; does now; COLUMN and ROW are the cell the test is talking about.
  ;;--------------------------------------------------------------
  (let ((cell (pt:pgtk-cell-size)))
    (pt:note-mouse-movement d (* column (car cell)) (* row (cdr cell)))))

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
  (list 7 9 (car (pt:pgtk-cell-size)) (cdr (pt:pgtk-cell-size)))
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
  ;; **`#f`, not `#t`.** The C builds the title with an *enabled* widget
  ;; value (`make_widget_value (title, NULL, true, Qnil)`) and only a
  ;; GTK/NS popup with a `hide` property says otherwise - but a GTK
  ;; menu item with no `call_data` is the one Emacs draws as a
  ;; *disabled* heading, which is what real Emacs shows (measured), so
  ;; the tree is built with the title insensitive.
  '(#f none)
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

;;----------------------------------------------------------------
;; Which button, and the symbol it makes
;;----------------------------------------------------------------
;; **Every press used to be decoded as `down-mouse-1`.** The Gtk signal
;; handler tags the event with what kind of event it is, and the decoder
;; then spelled the symbol without ever asking which button - so a
;; right-click on the tab bar arrived as a left click, and
;; `[tab-bar down-mouse-3]` (the context menu, `tab-bar.el:569`) could
;; never fire on this front end. GNU Emacs spells these in
;; `modify_event_symbol`'s caller (`keyboard.c:6760`) from the button
;; number; this is that half of the decode, tested without a Gdk event
;; because the naming is a pure function of the number.
(test-begin "schemacs_pgtk_mouse_buttons")
(define (mouse-sym kind button)
  ((@@ (schemacs ui gtk pgtk) pgtk-mouse-button-symbol) kind button))
(test-equal "a left button names the click events"
  '(down-mouse-1 mouse-1 drag-mouse-1)
  (list (mouse-sym 'down 1) (mouse-sym 'click 1) (mouse-sym 'drag 1)))
(test-equal "the right button keeps its number, so the context menu can be bound"
  '(down-mouse-3 mouse-3 drag-mouse-3)
  (list (mouse-sym 'down 3) (mouse-sym 'click 3) (mouse-sym 'drag 3)))
(test-equal "the middle button too"
  '(down-mouse-2 mouse-2)
  (list (mouse-sym 'down 2) (mouse-sym 'click 2)))
(test-end "schemacs_pgtk_mouse_buttons")

(test-begin "schemacs_pgtk_queue")

;; **A key queued while a command or a redisplay was running was never
;; dispatched.** The outermost loop of this front end does not read - Gtk
;; hands each event straight to the command loop - so anything that
;; arrived while the editor was busy sat in the queue until the next
;; prompt or search consumed it, late and out of order - or for ever, if
;; no read ever came. `pgtk-drain-queue!` is the missing read: every
;; queued item, oldest first, through the same two decodes a read uses.
;; (The `C-s`-for-ever bug was a different one: Return arrives as the
;; symbol `return` and the search's read did not translate it.)
(test-equal '((19 115 13) ())
  (let ((d (make pt:<pgtk-display>)))
    (set! (pt:pgtk-queue d)
          (list (cons (quote menu-bar-event) 19)
                (cons (quote menu-bar-event) 115)
                (cons (quote menu-bar-event) 13)))
    (let ((seen '()))
      (pt:pgtk-drain-queue! d (lambda (ev) (set! seen (cons ev seen))))
      (list (reverse seen) (pt:pgtk-queue d)))))

;; A deadline sentinel is not a key: it means "the read's deadline
;; passed", and the drain drops it as the read does.
(test-equal '((19) ())
  (let ((d (make pt:<pgtk-display>)))
    (set! (pt:pgtk-queue d)
          (list (quote pgtk-deadline) (cons (quote menu-bar-event) 19)))
    (let ((seen '()))
      (pt:pgtk-drain-queue! d (lambda (ev) (set! seen (cons ev seen))))
      (list (reverse seen) (pt:pgtk-queue d)))))

(test-end "schemacs_pgtk_queue")

;;----------------------------------------------------------------
;; Underline - pgtkterm.c's `pgtk_draw_glyph_string'
;;----------------------------------------------------------------
;; `realize-face-token` has interned `:underline` since the face table
;; was written, and nothing drew it: a face carrying only an underline -
;; the `underline` face itself, which `list-matching-lines-buffer-name-face`
;; names, and every `header-line` - came out plain. GNU Emacs draws a
;; one-pixel line at `(font descent + 1) / 2` below the baseline
;; (`pgtkterm.c:2662-2714`), and the pixel is the only thing that can see
;; it.

(test-begin "schemacs_pgtk_underline")

(define (render-with-face text face)
  ;; A frame on a display whose TEXT carries FACE over its whole length,
  ;; rendered by the real `render!'.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (insert text)
      (put-text-property 1 (1+ (string-length text)) 'face face ed))
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    d))

;; Any ink at all in CELL's first-row column? The text there is a
;; *space*, so without an underline the whole column is background -
;; which is what makes this a test of the underline and not of a glyph.
(define (ink-at pixel cell)
  (let loop ((y 0))
    (cond ((>= y cell-h) #f)
          ((not (equal? (pixel (+ (* cell cell-w) 4) y) white)) #t)
          (else (loop (+ y 1))))))

(define underlined (shot-of (render-with-face "a a" 'underline)))
(define not-underlined (shot-of (render-with-face "a a" 'default)))

(test-equal '(#t #f)
  (list (ink-at underlined 1) (ink-at not-underlined 1)))

(test-end "schemacs_pgtk_underline")

;;----------------------------------------------------------------
;; The pointer queries are methods of the display interface's generics
;;----------------------------------------------------------------
;; `define-method` on a name that has not been imported silently makes a
;; fresh generic in the defining module, and nothing - the compiler, the
;; loader, or a test that merely calls the function - says a word. That is
;; what happened to these two: `pgtk.scm` defined methods on private
;; generics, `frame.scm`'s `mouse-absolute-pixel-position` called the real
;; one (default method `#f`), and the answer was `(0 . 0)`, so
;; `mouse-drag-line` sampled zeros and dragging a mode line resized
;; nothing. Ask the real generic which methods are applicable to a
;; `<pgtk-display>`: two (this display's and the default), not one.
(test-begin "schemacs_pgtk_pointer_queries")
(let ((d (make pt:<pgtk-display>)))
  (test-equal "the absolute pixel position dispatches to this display"
              2 (length (compute-applicable-methods
                         display-mouse-absolute-pixel-position (list d))))
  ;; The setter takes four arguments, and applicability is decided for
  ;; the arguments given: with one, no method applies at all and the
  ;; answer is #f rather than the default's.
  (test-equal "and the pointer warp does too"
              2 (length (compute-applicable-methods
                         display-set-mouse-pixel-position
                         (list d #f 0 0))))
  (test-equal "and raising the frame"
              2 (length (compute-applicable-methods
                         display-raise-frame (list d #f)))))
(test-end "schemacs_pgtk_pointer_queries")

;;------------------------------------------------------------------
;; The text area's bottom clips a row that crosses it
;;
;; GNU Emacs lays out the row whose top is above `it.last_visible_y`
;; and whose bottom crosses it (`try_window`'s loop), and the drawing
;; layer stops its ink at the window's box
;; (`get_glyph_string_clip_rects`). This backend draws every row one
;; cell high today - the per-face fonts that would make a row taller are
;; named in DEPARTURES.md - so no row it is given places ink past the
;; bottom. The run is therefore called *directly*, at five pixels above
;; the text area's bottom: the same call the redisplay makes, at a place
;; only a taller row could put it. Without the clip the run's background
;; paints into the mode line's row.
;;------------------------------------------------------------------

(test-begin "schemacs_pgtk_text_area_clip")
(let* ((d (new-display))
       (ed (allocate-buffer))
       (frame (fr:new-frame ed 24 80))
       (w (fr:frame-selected-window frame))
       (ch (cdr (pt:pgtk-cell-size)))
       (bottom (* (+ (fr:window-top w) (fr:window-height w)
                     (if (fr:window-minibuffer-p w) 0 -1))
                  ch))
       (y (- bottom 5))
       (token (xd:face->attribute 'region))
       ;; **A glyph's pixel width is in display units now** - pixels on
       ;; this display - so the cell is borrowed from the font rather
       ;; than the old `1'.
       (g (make-glyph "X" token (car (pt:pgtk-cell-size)) 'char #f 0))
       (row (make-glyph-row (vector g) 1 0 y 1 1 1 0 0 #f)))
  (parameterize ((fr:*current-frame* frame))
    (xd:render! frame))
  (dn:clear-frame-area! d)
  (dn:write-glyphs! d w row 'text 0 (vector g) 1)
  (let ((pixel (shot-of d)))
    (test-equal "a run's cells inside the text area are painted"
                '(238 220 130)          ; the region face's background
                (pixel 4 (- bottom 2)))
    (test-equal "its ink stops at the text area's bottom, not the mode line"
                white
                (pixel 4 (+ bottom 3))))
  ;; The cursor is a glyph string too (`draw_window_cursor` hands it the
  ;; window), so its box stops at the same line.
  (dn:clear-frame-area! d)
  (dn:draw-window-cursor! d w y 0 1 'filled-box-cursor 1 "X" token)
  (let ((pixel (shot-of d)))
    (test-assert "the cursor box is drawn inside the text area"
                 (not (equal? white (pixel 4 (- bottom 2)))))
    (test-equal "and it stops at the bottom as well"
                white
                (pixel 4 (+ bottom 3)))))
(test-end "schemacs_pgtk_text_area_clip")

;;------------------------------------------------------------------
;; The two bar-patch rules
;;
;; A click that only changes what is applicable - Save becoming
;; enabled, Cut when the mark is set, the Replace items in a read-only
;; buffer - must not rebuild a widget tree: every GObject call crosses
;; guile-gi at milliseconds, so rebuilding the menu bar and tool bar was
;; seconds per click. These pin the rules that decide what is patched.
;;------------------------------------------------------------------
(test-begin "schemacs_pgtk_bar_patch")
;; The tool bar's vector is `tool-bar-item-nslots' (12) per item, with
;; the enabled flag in slot 1 (`TOOL_BAR_ITEM_ENABLED_P', keyboard.c).
(let* ((n 12)
       (a (make-vector (* 2 n) #f))
       (b (vector-copy a)))
  (vector-set! a 1 #t)                  ; item 0 enabled
  (vector-set! b 1 #f)                  ; item 0 disabled
  (vector-set! a (+ n 1) #f)            ; item 1 disabled
  (vector-set! b (+ n 1) #f)
  (test-assert "an enabled flag moving is an enabled-only change"
               (pt:pgtk-toolbar-enable-slots-only? a b))
  (test-assert "and the other direction is too"
               (pt:pgtk-toolbar-enable-slots-only? b a))
  (let ((c (vector-copy b)))
    (vector-set! c 5 'a-different-command)
    (test-assert "a command changing is not"
                 (not (pt:pgtk-toolbar-enable-slots-only? b c))))
  (let ((c (vector-copy b)))
    (vector-set! c 2 #t)                ; the selected slot
    (test-assert "a selected flag changing is not (it chooses an image)"
                 (not (pt:pgtk-toolbar-enable-slots-only? b c))))
  (let ((c (vector-copy b)))
    (vector-set! c 1 'not-a-boolean)
    (test-assert "a non-boolean where the flag belongs is not"
                 (not (pt:pgtk-toolbar-enable-slots-only? b c))))
  (test-assert "the same vector is trivially an enabled-only change"
               (pt:pgtk-toolbar-enable-slots-only? b b))
  (test-assert "a different number of items is not"
               (not (pt:pgtk-toolbar-enable-slots-only? b (vector-copy b 0 n)))))

;; `pgtk-menubar-widget-at` is the map from a `menu_items' index - the
;; `call_data' a menu item's signal carries - to the widget it was built
;; as. The enabled flag of the item whose name is at INDEX is at
;; INDEX+1, selected at INDEX+6 (`MENU_ITEMS_ITEM_ENABLE'/`_SELECTED'),
;; which is what the patch uses.
(let ((d (make pt:<pgtk-display>)))
  (set! (pt:pgtk-menubar-widgets d) (list (cons 239 'the-widget)))
  (test-equal "the widget built for an item index"
              'the-widget (pt:pgtk-menubar-widget-at d 239))
  (test-assert "no widget for an index the bar did not build"
               (not (pt:pgtk-menubar-widget-at d 240)))
  (set! (pt:pgtk-menubar-widgets d) '())
  (test-assert "no widget before the bar is built"
               (not (pt:pgtk-menubar-widget-at d 239))))
(test-end "schemacs_pgtk_bar_patch")

;;----------------------------------------------------------------------
;; Stage 1 of `plans/PER-FACE-FONTS.md`: the measurement interface
;;----------------------------------------------------------------------
;; GNU Emacs opens a font per realized face (`font_load_for_lface`,
;; `xfaces.c`) and reads the glyph advance, ascent and descent from it.
;; This display now answers the same two questions per face:
;; `face-metrics` from the face's font, and `face-text-width` from Pango's
;; layout of the text in it. The row layout still counts cells (stage 4)
;; and the drawing still uses the frame font (stage 2), so these are
;; measurement checks, not pixel checks.

(test-begin "schemacs_pgtk_face_fonts")

(define face-font-display (new-display))
(define face-font-default
  (x:merge-face-ref 'default (x:face-attributes-empty)))
(define face-font-scaled
  (x:merge-face-ref '(:height 1.5) face-font-default))
(define face-font-serif
  (x:merge-face-ref '(:family "serif") face-font-default))

(test-equal "the default face measures the frame's realized font"
  (dn:face-metrics face-font-display #f)
  (dn:face-metrics face-font-display face-font-default))

(test-assert "a face with a larger :height has a taller font"
  (> (car (dn:face-metrics face-font-display face-font-scaled))
     (car (dn:face-metrics face-font-display face-font-default))))

(test-equal "the default face advances by the cell"
  (* 2 (car (pt:pgtk-cell-size)))
  (dn:face-text-width face-font-display face-font-default "MM"))

(test-assert "a scaled face advances further for the same text"
  (> (dn:face-text-width face-font-display face-font-scaled "MM")
     (dn:face-text-width face-font-display face-font-default "MM")))

;; A proportional family measures differently from the monospace default;
;; where the family is missing Pango falls back to a font of its own, so
;; this is an inequality rather than a number.
(test-assert "a face's :family reaches Pango"
  (not (= (dn:face-text-width face-font-display face-font-serif "MM")
          (dn:face-text-width face-font-display face-font-default "MM"))))

;;------------------------------------------------------------------
;; Stage 2: the face's font is what the run is drawn in
;;
;; `plans/PER-FACE-FONTS.md`'s second step. A run's glyphs come from the
;; run's own font, every run of a row sits on the row's baseline, and the
;; row is as tall as its tallest face. Two checks: the row's metrics, and
;; the ink itself - a `:height 1.5` face's glyph reaches higher above the
;; baseline than the normal one beside it, which cell-counting could not
;; produce, the cell height being the frame's.
;;------------------------------------------------------------------

(define face-font-tall (x:merge-face-ref '(:height 1.5) face-font-default))

(define (render-tall-face)
  ;; "g  g" with the first `g` at 1.5x, point after the newline so the
  ;; cursor is on neither glyph. Answers (DISPLAY FRAME).
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (insert "g  g\n")
      (put-text-property 1 2 'face '(:height 1.5)))
    (set-point ed 6)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame))
      (list d frame))))

(define tall-render (render-tall-face))
(define tall-display (car tall-render))
(define tall-frame (cadr tall-render))

(define (tallest-row frame)
  ;; The desired matrix row whose ascent is greater than the frame's own -
  ;; the row the scaled glyph is on. #f if there is none.
  (let* ((window (fr:frame-selected-window frame))
         (matrix (window-desired-matrix window))
         (rows (and matrix (glyph-matrix-rows matrix)))
         (frame-ascent (car (dn:face-metrics (fr:frame-output frame) #f))))
    (and rows
         (let loop ((i 0) (found #f))
           (if (>= i (vector-length rows))
               found
               (let ((row (vector-ref rows i)))
                 (loop (+ i 1)
                       (if (and row
                                (> (glyph-row-ascent row) frame-ascent))
                           row
                           found))))))))

(define tall-row (tallest-row tall-frame))

(test-assert "a scaled face makes its row taller than the frame's line"
  (and tall-row
       (> (glyph-row-ascent tall-row)
          (car (dn:face-metrics tall-display #f)))))

;; `compute_line_metrics`: ascent is the greatest ascent, height is that
;; plus the greatest descent - which for this row is the scaled face's
;; own.
(test-equal "the row's height is the scaled font's ascent plus descent"
  (+ (car (dn:face-metrics tall-display face-font-tall))
     (cdr (dn:face-metrics tall-display face-font-tall)))
  (glyph-row-height tall-row))

;; The ink. `cell-w` columns starting at cell 0 hold the scaled `g`; the
;; one in cell 3 is the frame's size. MAX-Y is generous: the scaled row
;; is 30-odd pixels, not 20.
(define (ink-extent pix x0 width max-y)
  ;; (TOP . BOTTOM) of the pixel rows in [0, MAX-Y) with ink in the
  ;; columns [X0, X0+WIDTH), or #f.
  (let loop ((y 0) (top #f) (bottom #f))
    (if (>= y max-y)
        (and top (cons top bottom))
        (let x-loop ((x x0) (inked #f))
          (cond ((>= x (+ x0 width))
                 (loop (+ y 1)
                       (if inked (or top y) top)
                       (if inked y bottom)))
                ((not (equal? (pix x y) white)) (x-loop (+ x 1) #t))
                (else (x-loop (+ x 1) inked)))))))

(define tall-shot (shot-of tall-display))
(define tall-ink (ink-extent tall-shot 0 cell-w 80))
(define normal-ink (ink-extent tall-shot (* 3 cell-w) cell-w 80))

(test-assert "the scaled glyph reaches above the normal one on its row"
  (and tall-ink normal-ink (< (car tall-ink) (car normal-ink))))

;; A descender is where a shared baseline shows: the scaled `g`'s ink
;; goes below the normal one's, because both hang from the same baseline
;; and the scaled font's descent is the deeper.
(test-assert "and below it, so the two hang from the row's baseline"
  (and tall-ink normal-ink (> (cdr tall-ink) (cdr normal-ink))))

;; And the *horizontal* advance is the face font's: the normal glyph after
;; a scaled one starts where the scaled glyph's advance left off, not at
;; the next cell of a frame grid. With the tall `M' at column 0 and three
;; spaces, the normal `M' begins at the tall glyph's advance plus three
;; cells - past x=36, where a cell grid would have put column 4.
(define (render-advance)
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (insert "M   M\n")
      (put-text-property 1 2 'face '(:height 1.5)))
    (set-point ed 6)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame)
                     (fr:*frame-focus* #f))
        (xd:render! frame)))
    d))

(define advance-shot (shot-of (render-advance)))

(test-equal "a scaled glyph's advance moves the next glyph past its cell"
  white
  (advance-shot (+ (* 4 cell-w) 1) (+ (quotient cell-h 2) 5)))

(test-assert "and the next glyph is drawn where that advance left it"
  (not (equal? white
              (advance-shot
               (+ (dn:face-text-width tall-display face-font-tall "M")
                  (* 3 cell-w) 2)
               (+ (quotient cell-h 2) 5)))))

;; **The mode line does not scale with the buffer.** GNU Emacs's
;; `realize_named_face` merges every named face onto the *unremapped*
;; `default` (`get_lface_attributes_no_remap`); `text-scale-mode`'s
;; remapping applies to buffer text, which is why C-x C-= changes the
;; text and leaves the mode line alone. Merging the remapped default as
;; the base scaled the mode line too - and, with a pixel layout, drew it
;; outside its row and across the frame.
(define (scale-mode-line-shots)
  ;; (TEXT-TOP-BEFORE TEXT-TOP-AFTER MODE-TOP-BEFORE MODE-TOP-AFTER),
  ;; each the first inked pixel row of its band in a screenshot of the
  ;; same frame before and after three text-scale steps.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed (insert "MMMM\n"))
    (set-point ed 1)
    (let* ((frame (fr:new-frame ed 24 80))
           (cells-y (cdr (pt:pgtk-cell-size)))
           (mode-top-y (* (- (fr:frame-height frame) 1) cells-y))
           (top-of
            (lambda (pix y0 y1)
              (let yloop ((y y0))
                (cond ((>= y y1) #f)
                      ((let xloop ((x 0))
                         (cond ((>= x (car (pt:pgtk-cell-size))) #f)
                               ((equal? (pix x y) white) (xloop (+ x 1)))
                               (else #t)))
                       y)
                      (else (yloop (+ y 1))))))))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame))
      (let* ((before (shot-of d))
             (text-before (ink-extent before 0 (* 20 cell-w) (* 2 cells-y)))
             (mode-before (top-of before mode-top-y
                                  (* (fr:frame-height frame) cells-y))))
        (with-current-buffer ed (scale:text-scale-increase 3))
        (parameterize ((fr:*current-frame* frame))
          (xd:render! frame))
        (let* ((after (shot-of d))
               (text-after (ink-extent after 0 (* 20 cell-w) (* 2 cells-y)))
               (mode-after (top-of after mode-top-y
                                   (* (fr:frame-height frame) cells-y))))
          (with-current-buffer ed (scale:text-scale-increase 0))
          (list text-before text-after mode-before mode-after))))))

(define scale-shots (scale-mode-line-shots))

(test-assert "text-scale-increase redraws the buffer text without a resize"
  (and (car scale-shots) (cadr scale-shots)
       (> (- (cdr (cadr scale-shots)) (car (cadr scale-shots)))
          (- (cdr (car scale-shots)) (car (car scale-shots))))))

(test-equal "and the mode line keeps its own font"
  (list-ref scale-shots 2) (list-ref scale-shots 3))

;; **A taller row leaves disabled matrix rows underneath it.** They have
;; no y, so blanking each at `index * FRAME_LINE_HEIGHT` painted strips
;; across the scaled rows - the last lines "stayed small" because the
;; strips wiped them and the tail below them was never cleared. The area
;; below the last laid-out row is cleared once, from its bottom.
(define (scaled-long-shot)
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (let loop ((i 0))
        (when (< i 60) (insert "line\n") (loop (+ i 1)))))
    (set-point ed 1)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (with-current-buffer ed (scale:text-scale-increase 3))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (let ((pix (shot-of d)))
        (with-current-buffer ed (scale:text-scale-increase 0))
        pix))))

(define long-scaled (scaled-long-shot))

(test-assert "no blank strip is painted across a scaled row"
  ;; y=260 is where a disabled row's index-derived cell row begins. With
  ;; 26-pixel ascent rows it is inside the 8th scaled line's glyph band;
  ;; a blank strip there is the bug.
  (let loop ((x 0))
    (cond ((>= x (* 4 cell-w)) #f)
          ((not (equal? (long-scaled x 260) white)) #t)
          (else (loop (+ x 1))))))

;; **Shrinking the font shows more lines.** `required_matrix_height`
;; sizes the glyph matrix by the *shortest* font the display has opened,
;; so a buffer scaled down has more rows than the frame has lines - the
;; lines that become visible are the point of the smaller font. Sizing
;; the matrix at the body's line count built only that many rows, so the
;; bottom of the window kept the previous, larger font's pixels.
(define (scaled-down-rows)
  ;; (BODY-HEIGHT TEXT-ROWS-BEFORE TEXT-ROWS-AFTER MATRIX-ROWS-AFTER
  ;;  LAST-TEXT-ROW-BOTTOM PIXEL-BOTTOM)
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (let loop ((i 0))
        (when (< i 60) (insert "line
") (loop (+ i 1)))))
    (set-point ed 1)
    (let* ((frame (fr:new-frame ed 24 80))
           (window (fr:frame-selected-window frame))
           (cell-h (cdr (pt:pgtk-cell-size)))
           (body (fr:window-body-height window))
           (text-rows
            (lambda ()
              ;; (TEXT-ROWS . BOTTOM), over the desired matrix.
              (let* ((m (window-desired-matrix window))
                     (rows (glyph-matrix-rows m)))
                (let loop ((i 0) (n 0) (bottom 0))
                  (if (>= i (vector-length rows))
                      (cons n bottom)
                      (let ((row (vector-ref rows i)))
                        (if (and row (glyph-row-enabled? row)
                                 (glyph-row-displays-text? row))
                            (loop (+ i 1) (+ n 1)
                                  (max bottom (+ (glyph-row-y row)
                                                 (glyph-row-height row))))
                            (loop (+ i 1) n bottom)))))))))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (let ((before (car (text-rows))))
        (with-current-buffer ed (scale:text-scale-decrease 3))
        (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
        (let* ((after (text-rows))
               (m (window-desired-matrix window))
               (rows (glyph-matrix-rows m)))
          (with-current-buffer ed (scale:text-scale-increase 0))
          (list body before (car after) (vector-length rows)
                (cdr after) (* body cell-h)))))))

(define down-rows (scaled-down-rows))

(test-assert "a smaller font builds more lines than the frame has rows"
  (> (caddr down-rows) (car down-rows)))

(test-assert "and more than it built at the larger font"
  (> (caddr down-rows) (cadr down-rows)))

(test-assert "the matrix has room for them - required_matrix_height"
  (> (list-ref down-rows 3) (car down-rows)))

(test-assert "and the text reaches the bottom of the window"
  (>= (list-ref down-rows 4) (- (list-ref down-rows 5) cell-h)))

(test-end "schemacs_pgtk_face_fonts")

;;------------------------------------------------------------------
;; `update_text_area`'s whole-line rule
;;
;; "If rows are at different X or Y, or rows have different height, or
;; the current row is marked invalid, write the entire line"
;; (`dispnew.c:4746`). With `text-scale-mode` a row's own glyphs and
;; height can be unchanged while the rows above it grew or shrank, which
;; moves it; comparing only the hash left the screen's copy of that line
;; at the old y - the thin lines left behind at a previous zoom level.
;;------------------------------------------------------------------

(test-begin "schemacs_pgtk_matrix_diff")

(define (diff-row x y)
  (let ((row (make-glyph-row (vector) 0 x y 1 15 20 x x #f)))
    (set-glyph-row-enabled! row #t)
    row))

(define (diff-of cx cy dx dy)
  (matrix-diff-rows (make-glyph-matrix (vector (diff-row cx cy)) 1 1)
                    (make-glyph-matrix (vector (diff-row dx dy)) 1 1)))

(test-equal "an unchanged row is not redrawn" '() (diff-of 0 0 0 0))

(test-equal "a row at a new y is redrawn"
  '(0) (diff-of 0 20 0 60))

(test-equal "and so is one at a new x"
  '(0) (diff-of 0 20 9 20))

(test-end "schemacs_pgtk_matrix_diff")

;;------------------------------------------------------------------
;; A scaled row's tail, and its continuation marker
;;
;; Two pixel checks for the departure that made `text-scale-mode`
;; "descend into madness" on a wrapped line:
;;
;;  * `clear_end_of_line` clears the *row's* rectangle. Clearing only
;;    `FRAME_LINE_HEIGHT` pixels of a 29-pixel row left the bottom of the
;;    old line underneath - "cleared to the end of the line, but at the
;;    wrong zoom level, leaving half a line still there".
;;  * `display_line` cuts the text where the next character would cross
;;    `last_visible_x` and puts continuation glyphs there, in the default
;;    face's own font. A marker pinned to the last frame cell is clipped
;;    to a sliver once the face's font is larger than a cell, and the gap
;;    the word wrap left is not filled.
;;------------------------------------------------------------------

(test-begin "schemacs_pgtk_scaled_rows")

(define (tail-clear-render)
  ;; A long line, then a short one, so the short one's tail has old
  ;; frame-sized text underneath it when the buffer is scaled.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (insert (make-string 60 #\M)) (insert "\n")
      (insert "MM\n")
      (let loop ((i 0))
        (when (< i 30)
          (insert (make-string 60 #\M)) (insert "\n")
          (loop (+ i 1)))))
    (set-point ed 1)
    (let* ((frame (fr:new-frame ed 24 80))
           (window (fr:frame-selected-window frame)))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (with-current-buffer ed (scale:text-scale-increase 2))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (let* ((rows (glyph-matrix-rows (window-desired-matrix window)))
             (row (vector-ref rows 1))
             (pix (shot-of d)))
        (with-current-buffer ed (scale:text-scale-increase 0))
        (list pix (glyph-row-y row) (glyph-row-height row))))))

(define tail-clear (tail-clear-render))

(test-assert "a scaled row's tail is cleared to its own bottom"
  ;; The second scaled row starts at y=29 and is 29 pixels tall; its
  ;; pixel at y=53 was the previous frame's text under a 20-pixel clear.
  (equal? white
          ((car tail-clear) (* 20 cell-w)
           (+ (cadr tail-clear) (caddr tail-clear) -5))))

(define (marker-render)
  ;; A word-wrapped line whose break leaves a wide gap: 50 `a's then a
  ;; space, so the continuation run has to fill from where the text
  ;; stopped to the window's edge.
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (set!buffer-word-wrap ed #t)
      ;; 40 `a's end well before x=620, so the gap the wrap leaves is
      ;; empty of text - anything inked there is the marker's.
      (insert (make-string 40 #\a))
      (insert " ")
      (insert (make-string 50 #\b)))
    (set-point ed 1)
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (with-current-buffer ed (scale:text-scale-increase 2))
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (let ((pix (shot-of d)))
        (with-current-buffer ed (scale:text-scale-increase 0))
        pix))))

(define marker-pix (marker-render))

(test-assert "the continuation run fills a wrapped row's gap"
  (let loop ((x 620))
    (cond ((>= x 700) #f)
          ((not (equal? (marker-pix x 15) white)) #t)
          (else (loop (+ x 1))))))

(test-assert "and the marker is drawn in the row's scaled font"
  ;; The gap is empty of text, so ink there is the marker's. Its lowest
  ;; stroke is below the frame's own row height (20), which a
  ;; frame-metric marker never reaches.
  (let loop ((x 620) (lowest -1))
    (if (>= x 700)
        (> lowest cell-h)
        (loop (+ x 1)
              (let y-loop ((y 0) (low lowest))
                (if (>= y (* 2 cell-h))
                    low
                    (y-loop (+ y 1)
                            (if (equal? (marker-pix x y) white)
                                low
                                (max low y)))))))))

(test-end "schemacs_pgtk_scaled_rows")

;;------------------------------------------------------------------
;; Fringes
;;
;; GNU Emacs gives a graphical frame an 8-pixel fringe on each side
;; (`fringe.el:164`), outside the text area: a wrapped line's
;; continuation is a curved-arrow bitmap in the right fringe at the end
;; of the continued row and in the left fringe at the start of the row
;; that continues it (`fringe.c:1245`, `:1290`), never text glyphs. The
;; bitmap is 8x8 and vertically centred in the row
;; (`draw_fringe_bitmap_1`, `fringe.c:632`), so it does not zoom with
;; the text.
;;------------------------------------------------------------------

(test-begin "schemacs_pgtk_fringes")

(define (fringed-frame)
  ;; A frame with the default 8-pixel fringes, on a 200-column line that
  ;; wraps once. Answers (DISPLAY FRAME PIX).
  (let* ((d (new-display))
         (ed (allocate-buffer)))
    (with-current-buffer ed
      (insert (make-string 200 #\W)))
    (set-point ed 1)
    (let ((frame (fr:new-frame ed 24 80)))
      (fr:set-frame-parameter frame 'left-fringe 8)
      (fr:set-frame-parameter frame 'right-fringe 8)
      (parameterize ((fr:*current-frame* frame)) (xd:render! frame))
      (list d frame (shot-of d)))))

(define fringed (fringed-frame))
(define fringed-display (car fringed))
(define fringed-frame (cadr fringed))
(define fringed-pix (caddr fringed))
(define fringed-window (fr:frame-selected-window fringed-frame))

(test-equal "a graphical frame's fringes are 8 pixels each"
  '(8 8 #f #f) (fr:window-fringes fringed-window))

;; `window_box_width` (`xdisp.c:1279`) is pixels: the window's pixel
;; width less both fringes. The body's *columns* are that divided by
;; the cell - 704/9 = 78 here - and the text starts 8 pixels in, which
;; is not a whole column.
(test-equal "the fringes come out of the box in pixels"
  (- (fr:window-pixel-width fringed-window) 16)
  (fr:window-box-width fringed-window))
(test-equal "and the text starts eight pixels in"
  (+ (fr:window-pixel-left fringed-window) 8)
  (fr:window-box-left fringed-window))
(test-equal "the body's columns are the box divided by the cell"
  (quotient (- (fr:window-pixel-width fringed-window) 16) 9)
  (fr:window-body-width fringed-window))

(define fringed-rows
  (glyph-matrix-rows (window-desired-matrix fringed-window)))

(define (row-of index) (vector-ref fringed-rows index))

(test-assert "the wrapped line's first row continues"
  (and (row-of 0) (glyph-row-continued? (row-of 0))))
(test-assert "and the row below it is a continuation line"
  (and (row-of 1) (glyph-row-continuation-line? (row-of 1))))

(define (dark? colour)
  (and colour (< (+ (car colour) (cadr colour) (caddr colour)) 240)))

(define (ink-in-box? pix x0 y0 x1 y1)
  ;; Whether any pixel in [X0,X1) x [Y0,Y1) is dark.
  (let loop ((y y0))
    (cond ((>= y y1) #f)
          ((let x-loop ((x x0))
             (cond ((>= x x1) #f)
                   ((dark? (pix x y)) #t)
                   (else (x-loop (+ x 1)))))
           #t)
          (else (loop (+ y 1))))))

(define (ink-rows-in-box pix x0 x1 y0 y1)
  ;; How many of the pixel rows [Y0,Y1) have a dark pixel in [X0,X1).
  (let loop ((y y0) (n 0))
    (if (>= y y1)
        n
        (loop (+ y 1)
              (if (let x-loop ((x x0))
                    (cond ((>= x x1) #f)
                          ((dark? (pix x y)) #t)
                          (else (x-loop (+ x 1)))))
                  (+ n 1)
                  n)))))

;; The right fringe of the first row: a curly arrow, 8x8, centred in
;; the 20-pixel row - y 6..14.
(define right-fringe-x (* (- (fr:window-width fringed-window) 1) cell-w))
(test-assert "the continued row's right fringe carries an arrow"
  (ink-in-box? fringed-pix right-fringe-x 6 (+ right-fringe-x cell-w) 14))

(test-assert "the fringe is a gutter, not white text background"
  (not (equal? white
              (fringed-pix (+ right-fringe-x 3) 1))))

;; The second row's left fringe carries the other arrow.
(test-assert "the continuation row's left fringe carries an arrow"
  (ink-in-box? fringed-pix 0 26 cell-w 34))

(test-assert "no text glyph is drawn in the left gutter"
  (not (ink-in-box? fringed-pix 0 0 (1- cell-w) 20)))

;; Scaling the text does not scale the arrow: the row is 29 pixels tall,
;; but the bitmap is still 8 (four to six dark scanlines for these
;; arrows) and it is centred in that row.
(define (fringed-scaled-shot)
  (with-current-buffer (fr:window-buffer fringed-window)
    (scale:text-scale-increase 2))
  (parameterize ((fr:*current-frame* fringed-frame))
    (xd:render! fringed-frame))
  (let* ((rows (glyph-matrix-rows (window-desired-matrix fringed-window)))
         (row0 (vector-ref rows 0))
         (shot (shot-of fringed-display)))
    (with-current-buffer (fr:window-buffer fringed-window)
      (scale:text-scale-increase 0))
    (list shot (glyph-row-y row0) (glyph-row-height row0))))

(define fringed-scaled (fringed-scaled-shot))
(define fringed-scaled-pix (car fringed-scaled))
(define fringed-scaled-y (cadr fringed-scaled))
(define fringed-scaled-h (caddr fringed-scaled))
(define fringe-arrow-columns
  (list right-fringe-x (+ right-fringe-x cell-w)))

(test-assert "the fringe arrow does not zoom"
  (let ((n (ink-rows-in-box fringed-scaled-pix
                            (car fringe-arrow-columns)
                            (cadr fringe-arrow-columns)
                            fringed-scaled-y
                            (+ fringed-scaled-y fringed-scaled-h))))
    (and (<= n 8) (> n 3))))

(test-assert "and it is centred vertically in the taller row"
  (let* ((mid (+ fringed-scaled-y
                 (quotient fringed-scaled-h 2)))
         (n (ink-rows-in-box fringed-scaled-pix
                             (car fringe-arrow-columns)
                             (cadr fringe-arrow-columns)
                             (- mid 6) (+ mid 6))))
    (> n 3)))

(test-end "schemacs_pgtk_fringes")

;; `window_resize_apply` (`window.c:4815`) stores the *pixel* size the
;; engine computed and derives `total_cols` from it by division. Before
;; this the tree rounded every level to whole cells, so a frame resize
;; redistributed its rounding error on each pass - the split drift. 719
;; pixels is not a multiple of this display's 9-pixel cell: the window
;; must keep 719 and floor to 79 columns.
(test-begin "schemacs_pgtk_window_pixels")
(let* ((ed (get-buffer-create "pixel-geometry"))
       (frame (fr:new-frame ed 24 80))
       (root (fr:frame-root-window frame)))
  (fr:set-window-new-pixel root 719)
  (fr:set-window-new-normal root 0.5)
  (fr:%window-resize-apply-1 root #t)
  (test-equal "the pixel size the engine set is kept exactly"
    719 (fr:window-pixel-width root))
  (test-equal "the column count is that divided by the cell"
    79 (fr:window-width root))
  (test-equal "and the normal size is stored, not re-derived"
    0.5 (fr:window-normal-size root #t)))
;; A window 479 pixels tall with 20-pixel lines is 23 whole lines and a
;; 19-pixel remainder. The mode line is at pixel 459 (bottom less one
;; line), not at `(top + 23 - 1) * 20 = 440`, which is a whole remainder
;; too high and paints over the last text row - the corruption seen
;; after zooming down from a large font.
(let* ((ed (get-buffer-create "mode-line-pixels"))
       (frame (fr:new-frame ed 24 80))
       (root (fr:frame-root-window frame)))
  (fr:set-window-new-pixel root 479)
  (fr:%window-resize-apply-1 root #f)
  (parameterize ((fr:*current-frame* frame))
    (xd:render! frame))
  (let* ((w (fr:frame-selected-window frame))
         (record (fr:window-last-mode-line w)))
    (test-equal "the mode line begins at the pixel bottom less one line"
      (- (+ (fr:window-pixel-top w) (fr:window-pixel-height w))
         (fr:frame-char-height frame))
      (caddr record))))
(test-end "schemacs_pgtk_window_pixels")

;; `string-pixel-width` (`subr-x.el:389`) measures through the display
;; iterator, so the face a string carries - a tab caption's bold face, a
;; `:height 1.5` run - changes the answer. The old cell product could not
;; see either.
(test-begin "schemacs_pgtk_string_pixel_width")
(let* ((plain (propertize "abc"))
       (scaled (propertize "abc" 'face '(:height 1.5))))
  (test-assert "a string measures wider than zero"
    (> (xd:string-pixel-width plain) 0))
  (test-assert "a scaled face measures wider than the plain one"
    (> (xd:string-pixel-width scaled)
       (xd:string-pixel-width plain)))
  (test-equal "newlines take the widest line"
    (max (xd:string-pixel-width "abc")
         (xd:string-pixel-width "abcdef"))
    (xd:string-pixel-width "abc\nabcdef")))
(test-end "schemacs_pgtk_string_pixel_width")

;; `buffer_posn_from_coords` walks the row's glyphs (`xdisp.c:17110`);
;; a click's position is the character whose advance contains the
;; pointer, not `x / frame-cell-width`. With a `:height 2.0` face the
;; first glyph is 27 pixels wide, so a click 10 pixels in is character
;; 1, where the cell division (10/9) answered character 2.
(test-begin "schemacs_pgtk_posn_pixels")
(let* ((ed (get-buffer-create "posn-pixels"))
       (frame (fr:new-frame ed 24 80)))
  (with-current-buffer ed
    (insert "aaa")
    (put-text-property 1 4 'face '(:height 2.0)))
  (parameterize ((fr:*current-frame* frame))
    (xd:render! frame)
    (let* ((w (fr:frame-selected-window frame))
           (row (vector-ref (glyph-matrix-rows (window-current-matrix w)) 0))
         (glyphs (glyph-row-glyphs row))
         (w0 (glyph-pixel-width (vector-ref glyphs 0)))
         (first-x (+ (glyph-row-x row) 10)))
    (test-assert "a tall first glyph is wider than a frame cell"
      (> w0 (fr:frame-char-width frame)))
    (test-equal "a click inside the first tall glyph is position 1"
      1 (cadr (xd:posn-at-x-y first-x (+ (glyph-row-y row) 2) frame)))
    (test-equal "a click inside the second glyph is position 2"
      2 (cadr (xd:posn-at-x-y (+ (glyph-row-x row) w0 5)
                              (+ (glyph-row-y row) 2) frame)))
    (test-equal "posn-at-point's x is the first glyph's own advance"
      (+ (glyph-row-x row) w0)
      (car (caddr (xd:posn-at-point 2 w))))
    (test-equal "pos-visible's X is the tall first glyph's advance"
      w0
      (car (xd:pos-visible-in-window-p 2 w #t))))))
(test-end "schemacs_pgtk_posn_pixels")
