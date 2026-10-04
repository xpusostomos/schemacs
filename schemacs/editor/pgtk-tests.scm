;; Tests for `(schemacs editor pgtk)', the GTK display - the parts that
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
 (scheme base)
 (scheme char)
 (only (guile) setvbuf delete-file getpid)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) make)
 (only (schemacs editor pgtk)
       <pgtk-display> initialize-pgtk-faces! pgtk-write-screenshot!)
 (prefix (schemacs editor faces) f:)
 (prefix (schemacs editor xfaces) x:)
 (prefix (schemacs editor xdisp) xd:)
 (prefix (schemacs editor dispnew) dn:)
 (prefix (schemacs editor frame) fr:)
 (only (schemacs editor engine)
        new-text-editor text-editor-insert text-editor-set-cursor
        set!text-editor-mark)
 (only (schemacs editor buffer) buffer-local-value set-buffer-local-value!)
 ;; Imported for the *faces* it defines - `dired-marked' and the two
 ;; beside it are dired.el's own `defface's - which the test below
 ;; realizes. Loaded by both front ends in the real editor, so this is
 ;; not a test-only dependency.
 (only (schemacs editor dired))
 (only (schemacs editor keyboard) dispatch-input-event)
 (only (schemacs editor engine) text-editor-mark text-editor-get-cursor)
 (only (cairo) cairo-image-surface-create-from-png cairo-image-surface-get-data
       cairo-image-surface-get-stride))

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_pgtk")

;;------------------------------------------------------------------
;; A display, with no window and no Gtk init.
;;------------------------------------------------------------------

(define (new-display)
  (let ((d (make <pgtk-display>)))
    (dn:current-display d)
    (initialize-pgtk-faces! d)
    d))

;;------------------------------------------------------------------
;; The key decode
;;
;; `read-input-event' may answer only a character or an integer, so this
;; display folds `(MODIFIER-STATE . KEYSYM)' into one integer. These are
;; the exact values the plan records as measured.
;;------------------------------------------------------------------

(define (path ev) (dn:key-event->keymap-path (new-display) ev))

(define (encode state keysym) (+ keysym (* state (expt 2 32))))

(test-equal '(#\a) (path 97))
(test-equal '(ctrl #\a) (path (encode 4 97)))
(test-equal '(meta #\x) (path (encode 8 120)))
(test-equal '("up") (path 65362))                  ; GDK_KEY_Up
(test-equal '("left") (path 65361))
;; A named key's path element is a *string* (`"up"'), as the terminal's
;; is - so `(list 'ctrl "left")', not `'(ctrl left)', which `equal?' says
;; differs from it while printing identically.
(test-equal (list 'ctrl "left") (path (encode 4 65361))) ; C-<left>

;; A control character folds to `C-<letter>', as the terminal folds it -
;; which is what makes RET the `C-m' the keymap binds to `newline'.
(test-equal '(ctrl #\m) (path 13))                 ; GDK_KEY_Return
(test-equal '(ctrl #\i) (path 9))                  ; GDK_KEY_Tab
(test-equal '(ctrl #\a) (path (encode 4 97)))

;; A resize is a code, not a key: `read-input-event' cannot answer a pair,
;; so the display uses one integer for it, as a terminal uses KEY_RESIZE.
;; A named key is a *string* in a key path - the arrows are `(list "up")' -
;; and `keymap-index' reads a bare symbol as a modifier, which `(resize)'
;; would be.
(test-equal '("resize") (path -1))

;; A keysym with no name and no Unicode character is not a key this
;; editor can act on, and answers #f rather than inventing a name.
(test-equal #f (path (encode 0 65515)))            ; GDK_KEY_Shift_L alone

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

(define (ctrl keysym) (+ keysym (* 4 (expt 2 32))))
(define key-c-spc (ctrl #x20))   ; GDK_KEY_space with Control
(define key-c-at  (ctrl #x40))   ; GDK_KEY_at with Control

(define (mark-after key)
  ;; Dispatch KEY as the GTK display would, then two C-f, and answer the
  ;; mark as the region code sees it.
  (let* ((display (new-display))
         (ed (new-text-editor))
         (frame (fr:new-frame ed 24 80)))
    (parameterize ((fr:*current-frame* frame))
      (text-editor-insert ed "hello world")
      (text-editor-set-cursor ed 0)
      (dispatch-input-event frame key)
      ;; C-f is a *motion* command, which keeps the mark active - it is how
      ;; a region is made at all.
      (dispatch-input-event frame (ctrl (char->integer #\f)))
      (dispatch-input-event frame (ctrl (char->integer #\f)))
      (list (buffer-local-value ed 'mark-active #f)
            (text-editor-mark ed)
            (text-editor-get-cursor ed)))))

(define c-spc-mark (mark-after key-c-spc))
(test-equal #t (car c-spc-mark))
(test-equal 0 (cadr c-spc-mark))
;; and the motion still worked, so the mark is a region and not a
;; deactivated leftover
(test-equal 2 (caddr c-spc-mark))

;; C-@ keeps working - a terminal can only ever send that one.
(test-equal (list #t 0 2) (mark-after key-c-at))

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
  (initialize-pgtk-faces! d)
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
         (ed (new-text-editor)))
    (text-editor-insert ed text)
    (text-editor-set-cursor ed point)
    (set!text-editor-mark ed mark)
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
    (pgtk-write-screenshot! display path)
    (let ((pixel (pixel-reader path)))
      (delete-file path)
      pixel)))

;; The region [2, 5) of "hello world": cells 2, 3 and 4, with point on 5.
(define pixel (shot-of (render-region "hello world" 5 2)))

;; One character is 9x18 logical pixels. Sample the bottom of the first
;; text row, below the glyphs, so what is read is the *background* the
;; run painted and not a glyph stroke drawn over it.
(define (cell-pixel cell) (pixel (+ (* cell 9) 4) 16))

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
;; A wide character takes two cells - in the drawing, not just in the
;; arithmetic
;;
;; The region [0, 3) of "x<CJK>y|Z" is four cells: one for `x', two for
;; the CJK character, one for `y'. Drawing the run's background by its
;; `string-length' makes it three and leaves the fourth cell white, which
;; is the same mistake one layer down from where the arithmetic is tested -
;; and one only the pixels can see.
;;------------------------------------------------------------------

(define wide-text (string-append "x" (string (integer->char #x4E2D)) "y|Z"))
(define wide-pixel (shot-of (render-region wide-text 3 0)))
(define (wide-cell-pixel cell) (wide-pixel (+ (* cell 9) 4) 16))

(test-equal lightgoldenrod2 (wide-cell-pixel 0))
(test-equal lightgoldenrod2 (wide-cell-pixel 1))
(test-equal lightgoldenrod2 (wide-cell-pixel 2))
;; the fourth cell of the region, which counting characters loses
(test-equal lightgoldenrod2 (wide-cell-pixel 3))
;; and the text after the region is not painted
(test-equal white (wide-cell-pixel 5))


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

(test-end "schemacs_editor_pgtk")
