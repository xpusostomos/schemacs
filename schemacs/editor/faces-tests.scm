(import
 (only (schemacs editor editfns) insert point-max)
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf iota)
 (prefix (schemacs editor faces) f:)
 ;; for the run walk at the end: a buffer, a property on it, and the
 ;; computation that turns the two into runs
 (prefix (schemacs editor xdisp) xd:)
 (only (schemacs editor test-display) <test-display>)
 (prefix (schemacs editor dispnew) dn:)
 (only (oop goops) define-class make)
 (only (schemacs editor faces) set-face-attribute)
 (prefix (schemacs editor xfaces) x:)
 
 (only (schemacs editor buffer) set-buffer-local-value! %mark-marker with-current-buffer
 set-point allocate-buffer make-overlay overlay-put *current-buffer* overlays-at)
 ;; the mark is a marker, so it is marker.c's `set-marker` that puts it
 ;; on the buffer's slot - `text-editor-mark`'s write before it, gone.
 (only (schemacs editor marker) set-marker)
 (only (schemacs editor textprop) put-text-property))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor faces)', which mirrors GNU
;; Emacs's `faces.el'.
;;
;; The interesting thing to test is not the face table - that is a plist
;; lookup - but which *branch of a spec* a given display picks, because
;; that is where Emacs's behaviour is surprising: a spec written for a
;; graphical display falls through to a `(t ...)' branch on a terminal, so
;; `mode-line' is inverse video and `lazy-highlight' is underlined here
;; even though neither says so at the top of its spec.
;;
;; The standard faces are realized when the library loads, so these tests
;; read them as loaded and do not bind `*face-attributes*' - binding it
;; would hide every face there is.

(test-begin "schemacs_editor_faces")

;; Rendering realizes a face on the *display* (`realize-face' is a
;; display method), so the tests that ask what a face draws as run
;; against a display object: `(schemacs editor test-display)'s, which
;; draws nowhere and needs no terminal at all.
;;--------------------------------------------------------------

(define (with-display thunk color-cells type background)
  ;; Run THUNK with the display described, then realize the standard
  ;; faces again so the specs are chosen against it.
  ;;--------------------------------------------------------------
  (parameterize ((f:*display-color-cells* color-cells)
                 (f:*display-type* type)
                 (f:*frame-background-mode* background)
                 (f:*window-system* #f)
                 (dn:current-display (make <test-display>)))
    (for-each f:face-spec-recalc (f:face-list))
    ;; The first face a display realizes is the default one - that is
    ;; what makes token 0 mean "plain" - and a display that draws nothing
    ;; never realizes one by itself. Do what starting up does.
    (dn:lookup-face (dn:current-display)
                    (x:face-realized-attributes 'default))
    (thunk)))

;; A face exists, and the standard ones are there.
(test-equal '(#t #t #t #f)
  (list (f:facep 'bold)
        (f:facep 'mode-line)
        (f:facep 'isearch)
        (f:facep 'no-such-face-at-all)))

;; A spec with no condition matches anything: `bold' is bold wherever it
;; is drawn.
(test-equal '(bold bold)
  (list (f:face-attribute 'bold ':weight)
        (with-display (lambda () (f:face-attribute 'bold ':weight))
                      8 'color #f)))

;; `mode-line' is the case the renderer already hardcoded. On a
;; *monochrome* terminal every `(class color grayscale)' branch fails and
;; the spec's last - `(t :inverse-video t)' - is the one that counts, which
;; is why the mode line is drawn in reverse video.
(test-equal #t
  (with-display (lambda () (f:face-attribute 'mode-line ':inverse-video))
                1 'mono #f))

;; `region' is Emacs's spec as it stands: `blue3' on a dark display with
;; 16 colours or more, and `blue' with a white foreground on eight.
(test-equal '("blue3" "blue")
  (list (with-display (lambda () (f:face-attribute 'region ':background))
                      256 'color 'dark)
        (with-display (lambda () (f:face-attribute 'region ':background))
                      8 'color #f)))

;; With 8 colours but the display's background unknown, the colour branches
;; that ask about the background still fail, so it is the `(t ...)' branch
;; even though the terminal has colour to offer.
(test-equal #t
  (with-display (lambda () (f:face-attribute 'mode-line ':inverse-video))
                8 'color #f))

;; Give the display 88 colours and a known light background and the *first*
;; branch of `mode-line' wins instead, with a background and a box - the
;; branch a graphical Emacs would use - and no `:inverse-video' at all,
;; which is why the answer is `unspecified' there.
(test-equal '("grey75" "black" unspecified)
  (with-display (lambda ()
                  (list (f:face-attribute 'mode-line ':background)
                        (f:face-attribute 'mode-line ':foreground)
                        (f:face-attribute 'mode-line ':inverse-video)))
                88 'color 'light))

;; `lazy-highlight' is the other way round: an 8-colour terminal matches
;; its `(min-colors 8)' branch, which sets a background; a monochrome one
;; falls through to `(t :underline t)'.
(test-equal '(#t "turquoise3" unspecified)
  (list (with-display (lambda () (f:face-attribute 'lazy-highlight ':underline))
                      1 'mono #f)
        (with-display (lambda () (f:face-attribute 'lazy-highlight ':background))
                      8 'color #f)
        (with-display (lambda () (f:face-attribute 'lazy-highlight ':underline))
                      8 'color #f)))

;; `error' has a `default' branch, which is not a condition: its `:weight
;; bold' is the base that following branches add to. On a monochrome
;; terminal no colour branch matches, so what is left is the default plus
;; the last branch's `:inverse-video t'.
(test-equal '(bold #t "red")
  (list (with-display (lambda () (f:face-attribute 'error ':weight))
                      1 'mono #f)
        (with-display (lambda () (f:face-attribute 'error ':inverse-video))
                      1 'mono #f)
        (with-display (lambda () (f:face-attribute 'error ':foreground))
                      8 'color #f)))

;; A `default' branch is the whole answer when nothing matches, which is
;; how `mode-line-inactive' gets its `:inherit mode-line'.
(test-equal 'mode-line
  (f:face-attribute 'mode-line-inactive ':inherit))

;; An attribute nothing has set is `unspecified' rather than nil - the
;; difference between "not said" and "said off", which every spec's
;; fall-through depends on.
(test-equal 'unspecified
  (f:face-attribute 'bold ':stipple))

;; `set-face-attribute' overrides whatever the spec chose, and
;; `face-spec-recalc' puts the spec back.
(test-equal '(normal bold)
  (let ((was (f:face-attribute 'bold ':weight)))
    (f:set-face-attribute 'bold #f ':weight 'normal)
    (let ((now (f:face-attribute 'bold ':weight)))
      (f:face-spec-recalc 'bold)
      (list now (f:face-attribute 'bold ':weight)))))

;; `face-all-attributes' answers every attribute, and asks with an
;; inherited default so that none of the answers is relative.
(test-equal 16
  (length (f:face-all-attributes 'bold)))

;; `face-spec-set-match-display' is the test each spec branch goes
;; through, so it is worth asserting on directly.
(test-equal '(#t #t #t #f #t #f)
  (parameterize ((f:*display-color-cells* 8)
                 (f:*display-type* 'color)
                 (f:*frame-background-mode* #f))
    (list (f:face-spec-set-match-display #t)
          (f:face-spec-set-match-display '((type tty)))
          (f:face-spec-set-match-display '((class color)))
          (f:face-spec-set-match-display '((min-colors 88)))
          (f:face-spec-set-match-display '((min-colors 8)))
          (f:face-spec-set-match-display '((background dark))))))

;; A conjunct list must match on every conjunct, not just one.
(test-equal '(#t #f)
  (parameterize ((f:*display-color-cells* 8)
                 (f:*display-type* 'color)
                 (f:*frame-background-mode* #f))
    (list (f:face-spec-set-match-display '((class color) (min-colors 8)))
          (f:face-spec-set-match-display '((class color) (min-colors 88))))))

;; The cursor face is what the *display* draws the cursor in - black on a
;; light frame, white on a dark one (`faces.el:2948`) - and a theme may
;; set it to anything, which is how a themed editor gets a visible
;; cursor. Reading the face is the whole of the C's `cursor_pixel`;
;; the gtk backend's `cursor-box-colour` is that read.
(test-equal '("black" "white")
  (list (with-display (lambda () (f:face-attribute 'cursor ':background))
                      88 'color 'light)
        (with-display (lambda () (f:face-attribute 'cursor ':background))
                      88 'color 'dark)))

;; `defface' defines a face, gives it a spec, and realizes it - which is
;; what a ported Elisp file full of `defface' forms will do.
(test-equal '(#t bold)
  (let ((name 'schemacs-test-face))
    ;; inside a quoted spec the keyword needs no quote of its own: it is
    ;; data, and `':weight' would be the two-element list `(quote :weight)'
    (f:defface name '((#t :weight bold)) "A face a test made.")
    (list (f:facep name)
          (f:face-attribute name ':weight))))

(test-end "schemacs_editor_faces")

;;--------------------------------------------------------------------
;; The run walk, which is how a face on buffer text reaches the screen
;;
;; `line-face-runs' is the half of it that can be tested without a
;; terminal: it says which spans of a line share a face. `draw-line!'
;; emits the attributes, and those primitives are the ones the pty battery
;; covers through the mode line and the search.

;; The run walk realizes a face on the display (`face-at-buffer-position'
;; answers what the face *draws as*), so the group, which asks that
;; question, runs against a display object - the same one `with-display'
;; makes, set once for the group. It has no terminal behind it, which
;; keeps it monochrome.
(dn:current-display (make <test-display>))

(test-begin "schemacs_editor_faces_runs")

;; The runs group computes realized attributes (`face-at-buffer-position'
;; realizes on the display), so it runs against one, as documented above.
(dn:current-display (make <test-display>))

(define (runs-for ed line-start len)
  ;; `line-face-runs' asks the *current* buffer for overlay changes, as
  ;; the C does, and `display-window!' makes the window's buffer current
  ;; around the row walk for that reason. A test that hands it a buffer
  ;; must do the same, or the overlay walk reads whichever buffer happens
  ;; to be current - `#f' in a fresh process, which raised "Wrong type
  ;; argument ... expecting struct: #f" from `next-overlay-change'.
  ;; These tests were failing that way, unnoticed, until the suite check
  ;; was made to notice a group that never finishes.
  (parameterize ((*current-buffer* ed))
    (xd:line-face-runs ed line-start len)))

(define (buffer-with-face text from to face)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    (put-text-property from to 'face face ed)
    ed))

;; A line with no faces is one run with no attributes - the case the
;; renderer takes the fast path for.
;;
;; **LINE-START is a buffer position and positions are one-based** (the
;; tree's convention since 2026-10-05): these tests passed `0` for a line
;; at the start of the buffer, which is out of range, and
;; `attrs-at-buffer-position' raised `Args out of range: 0' - so they had
;; been failing, unnoticed, because `tools/run-suites.py' could not see
;; failures in a suite that aborts.
(test-equal '(1 ((0 6 0)))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcdef"))
    (let ((runs (runs-for ed 1 6)))
      (list (length runs) runs))))

;; A face on the middle of a line cuts it into three runs, and each run
;; carries the attribute number for its face - bold, on this display.
;; `put-text-property 2 5' is positions 2, 3 and 4, which of a line
;; starting at position 1 are the offsets 1 to 4.
(test-equal 3
  (length (runs-for (buffer-with-face "abcdefgh" 2 5 'bold) 1
                             8)))

(test-equal '(#f #t #f)
  (let ((runs (runs-for (buffer-with-face "abcdefgh" 2 5 'bold) 1
                                 8)))
    (let loop ((rest runs) (acc '()))
      (if (null? rest)
          (reverse acc)
          (loop (cdr rest) (cons (not (= 0 (caddr (car rest)))) acc))))))

;; ...and the runs cover the line exactly, with no gap and no overlap.
(test-equal '((0 1) (1 4) (4 8))
  (map (lambda (run) (list (car run) (cadr run)))
       (runs-for (buffer-with-face "abcdefgh" 2 5 'bold) 1 8)))

;; The runs are bounded by the *line*, and their positions are buffer
;; columns offset by where the line starts - which is what makes the
;; renderer's per-line walk work at all. The attribute numbers themselves
;; are the display's and are not asserted: only that the middle run is a
;; *different* run from its neighbours.
;;
;; ...and the columns are offset by where the line starts. The line here is
;; "def", starting at buffer position 4, and the face is on position 5 -
;; the "e" - so it is the *middle* column that is bold.
(test-equal '((0 1) (1 2) (2 3))
  (let ((ed (buffer-with-face "abcdefgh" 5 6 'bold)))
    (map (lambda (run) (list (car run) (cadr run)))
         (runs-for ed 4 3))))

(test-equal #t
  (let* ((ed (buffer-with-face "abcdefgh" 5 6 'bold))
         (runs (runs-for ed 4 3)))
    (and (not (= (caddr (car runs)) (caddr (cadr runs))))
         (not (= (caddr (cadr runs)) (caddr (caddr runs)))))))

;; The active region is an overlay the window carries, and its face is
;; merged with the text property's like any other overlay's. These tests
;; make the overlay `redisplay--update-region-highlight` makes, then
;; exercise the same per-character run walk that redisplay uses.
;;
;; **An 8-colour display, because the extension is the `:extend`
;; attribute.** Emacs's region face sets `:extend t` on every colour
;; branch and none on its `(class mono)` branch, and Emacs on a vt100
;; paints only the characters and the newline's own cell (measured).
;; The tests that ask whether a line break is painted to the edge need a
;; display whose region spec has `:extend`.
(define (region-buffer text point mark active?)
  ;; **The active region is an overlay of the window's now**, not a face
  ;; merged from point and mark: `redisplay--update-region-highlight`
  ;; (`simple.el:7332`) makes one with the `region` face and a `window`
  ;; property, from `(min point mark)` and `(max point mark)` - the
  ;; overlay itself does not swap a reversed range
  ;; (`clip_to_bounds (obeg, end, Z)`, `buffer.c`). The test makes what
  ;; that function makes.
  ;;
  ;; An *inactive* region has no overlay; an empty one is a zero-length
  ;; overlay, which `overlays-at` does not report - so neither paints.
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    (when active?
      (let ((ov (make-overlay (min point mark) (max point mark) ed)))
        (overlay-put ov 'face 'region)))
    ed))

(define (region-runs text start end active?)
  (with-display
   (lambda ()
     (runs-for (region-buffer text start end active?) 1
                        (string-length text)))
   8 'color #f))

(define region-attribute (region-runs "abcdef" 2 5 #t))

(test-equal '((0 1) (1 4) (4 6))
  (map (lambda (run) (list (car run) (cadr run))) region-attribute))
(test-equal #t
  (let ((runs region-attribute))
    (and (= (caddr (car runs)) 0)
         (not (= (caddr (car runs)) (caddr (cadr runs))))
         (= (caddr (car runs)) (caddr (caddr runs))))))

;; Reversing point and mark selects the same half-open range.
(test-equal (map caddr region-attribute)
  (map caddr (region-runs "abcdef" 5 2 #t)))

;; Inactive and empty regions do not change the default face. (An empty
;; overlay has no characters, so `overlays-at` never reports it; its two
;; boundaries can still split a run, which paints nothing.)
(test-equal '((0 6 0)) (region-runs "abcdef" 2 5 #f))
(test-equal '(0 0) (map caddr (region-runs "abcdef" 2 2 #t)))

;; **The `window` property is what keeps a region out of the other
;; windows** - `sort_overlays`'s `overlay_matches_window`
;; (`buffer.c:3367`), asked through `*drawing-window*`. A region overlay
;; carries the window it belongs to and is invisible in every other.
(test-equal '(#t #f)
  (with-display
   (lambda ()
     (let* ((ed (allocate-buffer)))
       (with-current-buffer ed
         (insert "abcdef")
         (let ((here (list 'window-a))
               (there (list 'window-b))
               (ov (make-overlay 2 5 ed)))
           (overlay-put ov 'face 'region)
           (overlay-put ov 'window here)
           (list (parameterize ((*current-buffer* ed) (xd:*drawing-window* here))
                   (not (= (xd:face-at-buffer-position ed 3) 0)))
                 (parameterize ((*current-buffer* ed) (xd:*drawing-window* there))
                   (not (= (xd:face-at-buffer-position ed 3) 0))))))))
   1 'mono #f))

;; When the active region covers a line's break, its face fills the rest
;; of the row - including a *blank* line's - because the face at the
;; newline has `:extend` (`extend_face_id`, `xdisp.c:24429`). A final
;; line at `point-max` has no newline and extends nothing.
(test-equal '(#t #f)
  (with-display
   (lambda ()
     (let ((ed (region-buffer "ab\n\ncd" 4 5 #t))
           (default (xd:face->attribute 'default)))
       ;; `\n\ncd` starts at position 3; the blank line's own break is
       ;; position 4, and the buffer's last line ends at `point-max`.
       (with-current-buffer ed
         (list (not (= (xd:extend-fill-token ed 4 default) default))
               (not (= (xd:extend-fill-token ed (point-max) default)
                       default))))))
   8 'color #f))

(test-end "schemacs_editor_faces_runs")

;;------------------------------------------------------------------
;; The background mode, and what recomputes it
;;
;; `frame-set-background-mode' (`frame.el:1529') computes the mode from
;; the default face's background and re-chooses the specs that test
;; `(background dark)' and `(background light)' when it changes - and
;; the hardcode it replaced on Gtk was why a themed black frame read
;; every light branch, `Find file:' drawing `minibuffer-prompt''s
;; `medium blue' on black. The computation is `color-dark-p' over the
;; colour's values, which is the C's gamma-corrected luminance against
;; the 0.325 cut-off.
;;
;; `set-face-attribute' is the C's trigger (`xfaces.c:3902'): a
;; background change on `default' reaches the recompute through the
;; hook parameter, `frame.scm' having installed the function there -
;; the tree's shape for the C's `calln' across a library boundary.
;;------------------------------------------------------------------

;; **In a group of its own.** `srfi-64' here raises "Wrong type argument
;; ... expecting struct: #f" for any test evaluated outside a group once
;; a group has ended (measured with a two-group file), so these three
;; top-level tests could never have run after `faces_runs' - and the
;; crash that used to stop this file before them hid it.
(test-begin "schemacs_editor_faces_background")

(test-equal "color-dark-p answers the C's table"
  '(#t #f)
  (list (f:color-dark-p '(0.0 0.0 0.0))          ; black
        (f:color-dark-p '(1.0 1.0 1.0))))        ; white

(test-equal "a dark default flips the mode and the branches follow"
  '(light dark light)
  (parameterize ((f:*display-color-cells* 256)
                 (f:*display-type* 'color)
                 (f:*frame-background-mode* #f)
                 (f:*window-system* 'pgtk)
                 (dn:current-display (make <test-display>)))
    ;; The hook is what a caller without a frame library reaches
    ;; through; here the computed answer is driven directly.
    (let* ((set-mode (@@ (schemacs editor frame) frame-set-background-mode))
           (mode (lambda () (f:*frame-background-mode*))))
      ;; a light default - the stock white - and the light branch
      (set-face-attribute 'default #f ':background "white")
      (set-mode #f)
      (let ((light (mode)))
        ;; the theme's black
        (set-face-attribute 'default #f ':background "black")
        (set-mode #f)
        (let ((dark (mode)))
          ;; and back
          (set-face-attribute 'default #f ':background "white")
          (set-mode #f)
          (list light dark (mode)))))))

(test-equal "and the prompt's own dark branch answers cyan"
  ;; a *string*, which is what a colour attribute holds - Emacs's
  ;; `(face-attribute 'minibuffer-prompt :foreground)' is "cyan", and the
  ;; test had expected the symbol, so it could never have passed. It had
  ;; never run: `srfi-64' here cannot evaluate a test outside a group
  ;; once a group has ended, and these three were outside one.
  "cyan"
  (parameterize ((f:*display-color-cells* 256)
                 (f:*display-type* 'color)
                 (f:*frame-background-mode* 'dark)
                 (f:*window-system* 'pgtk)
                 (dn:current-display (make <test-display>)))
    (for-each f:face-spec-recalc (f:face-list))
    (x:attribute-value
     (x:merge-face-ref 'minibuffer-prompt
                       (x:merge-face-ref 'default (x:face-attributes-empty)))
     ':foreground)))

(test-end "schemacs_editor_faces_background")

(test-begin "schemacs_editor_faces_extend")

;;--------------------------------------------------------------------
;; The face the rest of a row is filled with: Emacs's `extend_face_id`
;; (`xdisp.c:24429`) is the last glyph's face only when the faces at the
;; row's end say `:extend` (`merge_named_face`, `xfaces.c:2527`). The
;; `isearch` face does not say it, so a search match at the end of a
;; line stops at the match; `region` says it, so it reaches the edge -
;; and `tools/pty-check.py`'s `region-highlight` and `isearch-highlight`
;; are where that is pinned end to end. Measured on Emacs 31.1 in a
;; pty, the search match is written as `\e[36m\e[45m888\e[39;49m` -
;; three cells, the padding back in the default face - where this port
;; painted the highlight to column 80.
;;--------------------------------------------------------------------

(define (extend-token ed end last-token)
  (with-display
   (lambda ()
     (parameterize ((*current-buffer* ed))
       (list (xd:extend-fill-token ed end last-token)
             (xd:face->attribute 'default))))
   1 'mono #f))

;; An isearch match over the "888" of "abc 888\nxx" does not reach the
;; line's end: the newline at 9 has no extending face, so the fill is the
;; default face.
(test-equal '(#t #t)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc 888\nxx"))
    (let ((ov (make-overlay 5 8 ed)))
      (overlay-put ov 'face 'isearch)
      (let* ((match (parameterize ((*current-buffer* ed))
                      (xd:face-at-buffer-position ed 5)))
             (tokens (extend-token ed 9 match))
             (fill (car tokens))
             (default (cadr tokens)))
        ;; the match itself is *not* the default face - the highlight is
        ;; drawn - and the fill is
        (list (not (= match default)) (= fill default))))))

;; A final line with no newline never extends (Emacs's `ends_at_zv_p`).
(test-equal #t
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc 888"))
    (let ((ov (make-overlay 5 8 ed)))
      (overlay-put ov 'face 'isearch)
      (let* ((match (parameterize ((*current-buffer* ed))
                      (xd:face-at-buffer-position ed 5)))
             (tokens (extend-token ed 8 match)))
        (= (car tokens) (cadr tokens))))))

(test-end "schemacs_editor_faces_extend")
