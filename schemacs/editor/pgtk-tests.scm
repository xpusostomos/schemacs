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
 (prefix (only (schemacs editor pgtk)
               <pgtk-display> initialize-pgtk-faces! pgtk-write-screenshot!
               note-mouse-movement pgtk-mouse-moved)
         pt:)
 (prefix (schemacs editor faces) f:)
 (prefix (schemacs editor xfaces) x:)
 (prefix (schemacs editor xdisp) xd:)
 (prefix (schemacs editor dispnew) dn:)
 (prefix (schemacs editor frame) fr:)
 (only (schemacs editor engine)
        new-text-editor text-editor-insert text-editor-set-cursor
        set!text-editor-mark)
 (only (schemacs editor buffer) buffer-local-value set-buffer-local-value!)
 (only (schemacs editor textprop) put-text-property)
 (prefix (schemacs editor isearch) is:)
 (only (schemacs editor buffer) overlays-at overlay-get overlay-start)
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
;; *terminal* folds these onto `(ctrl #\m)' and `(ctrl #\i)' because a
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
      (text-editor-set-cursor ed 1)
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
    (pt:pgtk-write-screenshot! display path)
    (let ((pixel (pixel-reader path)))
      (delete-file path)
      pixel)))

;; The region [3, 6) of "hello world" - Emacs's positions, so the three
;; `l', `l' and `o' at columns 2, 3 and 4 - with point at 6.
(define pixel (shot-of (render-region "hello world" 6 3)))

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
;; The region [1, 4) of "x<CJK>y|Z" is four cells: one for `x', two for
;; the CJK character, one for `y'. Drawing the run's background by its
;; `string-length' makes it three and leaves the fourth cell white, which
;; is the same mistake one layer down from where the arithmetic is tested -
;; and one only the pixels can see.
;;------------------------------------------------------------------

(define wide-text (string-append "x" (string (integer->char #x4E2D)) "y|Z"))
(define wide-pixel (shot-of (render-region wide-text 4 1)))
(define (wide-cell-pixel cell) (wide-pixel (+ (* cell 9) 4) 16))

(test-equal lightgoldenrod2 (wide-cell-pixel 0))
(test-equal lightgoldenrod2 (wide-cell-pixel 1))
(test-equal lightgoldenrod2 (wide-cell-pixel 2))
;; the fourth cell of the region, which counting characters loses
(test-equal lightgoldenrod2 (wide-cell-pixel 3))
;; and the text after the region is not painted
(test-equal white (wide-cell-pixel 5))


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
         (ed (new-text-editor)))
    (text-editor-insert ed (string ch))
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
         (ed (new-text-editor)))
    (text-editor-insert ed text)
    (text-editor-set-cursor ed 0)
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
         (ed (new-text-editor)))
    (text-editor-insert ed text)
    (text-editor-set-cursor ed 0)
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
(let* ((ed (new-text-editor)))
  (text-editor-insert ed "alpha beta alpha")
  (text-editor-set-cursor ed 0)
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
         (ed (new-text-editor)))
    (text-editor-insert ed text)
    (text-editor-set-cursor ed 0)
    (when prop?
      (put-text-property (- (string-length text) 1) (string-length text)
                         'display ": (15 GiB available)" ed))
    (let ((frame (fr:new-frame ed 24 80)))
      (parameterize ((fr:*current-frame* frame))
        (xd:render! frame)))
    (shot-of d)))

(define (cell-has-ink? pix cell)
  ;; Whether any pixel of CELL's glyph band is not the white background.
  ;; The band is below the top of the row and above its bottom, where the
  ;; glyph strokes are - a cell with no character is blank throughout.
  (let x-loop ((x 0))
    (cond ((>= x 9) #f)
          ((let y-loop ((y 3))
             (cond ((>= y 15) #f)
                   ((not (equal? '(255 255 255)
                                 (pix (+ (* cell 9) x) y)))
                    #t)
                   (else (y-loop (+ y 1)))))
           #t)
          (else (x-loop (+ x 1))))))

(define colon-pixels (render-line "  /tmp:" #t))
(define plain-pixels (render-line "  /tmp:" #f))

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
  (let loop ((c 7))
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
      (let ((ed (new-text-editor)))
        (text-editor-insert
         ed (apply string-append
                   (map (lambda (i) "aaaaaaaaaa\n")
                        (let loop ((i 1) (acc '()))
                          (if (> i 60) (reverse acc)
                              (loop (+ i 1) (cons i acc)))))))
        (text-editor-set-cursor ed 1)
        (let ((f1 (fr:new-frame-on d1 ed 24 80))
              (f2 (fr:new-frame-on d2 ed 24 80)))
          (parameterize ((fr:*current-frame* f1))
            (text-editor-set-cursor ed 300)
            (xd:render! f1)
            (xd:render! f2)
            (list (= 1 (xd:window-start (fr:frame-selected-window f2)))
                  (> (xd:window-start (fr:frame-selected-window f1)) 1))))))))

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

(define (echo-row-ink pix)
  ;; How many pixels of the frame's last row are not the background -
  ;; the echo area's row, which is where a message is drawn. A character
  ;; cell is 9x18 pixels and the frame is 24 rows, so the last row is
  ;; rows 414 to 431.
  ;;--------------------------------------------------------------
  (let loop ((x 0) (y (* 23 18)) (n 0))
    (cond ((>= y (* 24 18)) n)
          ((>= x (* 80 9)) (loop 0 (+ y 1) n))
          (else (loop (+ x 1) y
                      (if (equal? (pix x y) white) n (+ n 1)))))))

(test-equal '(#t #t)
  (parameterize ((fr:*frame-list* '()))
    (let* ((d1 (make pt:<pgtk-display>))
           (d2 (make pt:<pgtk-display>)))
      (dn:current-display d1)
      (pt:initialize-pgtk-faces! d1)
      (pt:initialize-pgtk-faces! d2)
      (let* ((ed (new-text-editor))
             (f1 (fr:new-frame-on d1 ed 24 80))
             (f2 (fr:new-frame-on d2 ed 24 80)))
        (parameterize ((fr:*current-frame* f1))
          ;; F1 is the selected frame and F2 is not, so the message F2 is
          ;; holding is one that is not being shown anywhere.
          (fr:set!frame-message f2 "a message for the frame that is not selected")
          (xd:render! f2)
          (let ((blank (zero? (echo-row-ink (shot-of d2)))))
            (fr:set!frame-message f1 "a message for the selected frame")
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
       (f (fr:new-frame-on d (new-text-editor) 24 80)))
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
    (parameterize ((fr:*current-frame* (fr:new-frame-on d (new-text-editor) 24 80)))
      (xd:remember-mouse-glyph (fr:*current-frame*) 7 9))))

(test-end "schemacs_editor_pgtk")
