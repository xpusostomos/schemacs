(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (prefix (schemacs editor faces) f:)
 ;; for the run walk at the end: a buffer, a property on it, and the
 ;; computation that turns the two into runs
 (prefix (schemacs editor xdisp) xd:)
 (prefix (schemacs editor term) term:)
 (prefix (schemacs editor dispnew) dn:)
 (only (oop goops) define-class make)
 (only (schemacs editor engine)
        new-text-editor text-editor-insert text-editor-set-cursor
        text-editor-line-outer-size set!text-editor-mark)
 (only (schemacs editor buffer) set-buffer-local-value!)
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
;; against a display object. A terminal display is made without opening
;; a terminal: realizing only consults the pair table when there are
;; colours, and `has-colors?' answers #f before `initscr' - so a
;; display-less machine stays monochrome and no curses call is made.
(define-class <test-display> (term:<tty-display>))

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

(define (buffer-with-face text from to face)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed text)
    (put-text-property from to 'face face ed)
    ed))

;; A line with no faces is one run with no attributes - the case the
;; renderer takes the fast path for.
(test-equal '(1 ((0 6 0)))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((runs (xd:line-face-runs ed 0 "abcdef")))
      (list (length runs) runs))))

;; A face on the middle of a line cuts it into three runs, and each run
;; carries the attribute number for its face - bold, on this display.
(test-equal 3
  (length (xd:line-face-runs (buffer-with-face "abcdefgh" 2 5 'bold) 0
                             "abcdefgh")))

(test-equal '(#f #t #f)
  (let ((runs (xd:line-face-runs (buffer-with-face "abcdefgh" 2 5 'bold) 0
                                 "abcdefgh")))
    (let loop ((rest runs) (acc '()))
      (if (null? rest)
          (reverse acc)
          (loop (cdr rest) (cons (not (= 0 (caddr (car rest)))) acc))))))

;; ...and the runs cover the line exactly, with no gap and no overlap.
(test-equal '((0 2) (2 5) (5 8))
  (map (lambda (run) (list (car run) (cadr run)))
       (xd:line-face-runs (buffer-with-face "abcdefgh" 2 5 'bold) 0 "abcdefgh")))

;; The runs are bounded by the *line*, and their positions are buffer
;; columns offset by where the line starts - which is what makes the
;; renderer's per-line walk work at all.
;; The runs are bounded by the *line*, and their positions are buffer
;; columns offset by where the line starts - which is what makes the
;; renderer's per-line walk work at all. The attribute numbers themselves
;; are ncurses's bit flags and are not asserted: only that the middle run
;; is a *different* run from its neighbours.
;; ...and the columns are offset by where the line starts. The line here
;; is "bcd" starting at buffer column 4, and the face is on buffer column
;; 5 - the "c" - so it is the *middle* column that is bold.
(test-equal '((0 1) (1 2) (2 3))
  (let ((ed (buffer-with-face "abcdefgh" 5 6 'bold)))
    (map (lambda (run) (list (car run) (cadr run)))
         (xd:line-face-runs ed 4 "bcd"))))

(test-equal #t
  (let* ((ed (buffer-with-face "abcdefgh" 5 6 'bold))
         (runs (xd:line-face-runs ed 4 "bcd")))
    (and (not (= (caddr (car runs)) (caddr (cadr runs))))
         (not (= (caddr (cadr runs)) (caddr (caddr runs)))))))

;; The active region is another face merged after the text property's
;; face. These tests set the point, mark and buffer-local mark-active just
;; as the commands do, then exercise the same per-character run walk that
;; redisplay uses.
(define (region-buffer text point mark active?)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed text)
    (text-editor-set-cursor ed point)
    (set!text-editor-mark ed mark)
    (when active?
      (set-buffer-local-value! ed 'mark-active #t))
    ed))

(define (region-runs text point mark active?)
  ;; On a monochrome terminal the region face is inverse-video, which
  ;; makes the region's runs observable without an initialized ncurses
  ;; color palette.
  (with-display
   (lambda ()
     (xd:line-face-runs (region-buffer text point mark active?) 0 text))
   1 'mono #f))

(define region-attribute (region-runs "abcdef" 2 5 #t))

(test-equal '((0 2) (2 5) (5 6))
  (map (lambda (run) (list (car run) (cadr run))) region-attribute))
(test-equal #t
  (let ((runs region-attribute))
    (and (= (caddr (car runs)) 0)
         (not (= (caddr (car runs)) (caddr (cadr runs))))
         (= (caddr (car runs)) (caddr (caddr runs))))))

;; Reversing point and mark selects the same half-open range.
(test-equal (map caddr region-attribute)
  (map caddr (region-runs "abcdef" 5 2 #t)))

;; Inactive, empty and unset-mark regions do not change the default face.
(test-equal '((0 6 0)) (region-runs "abcdef" 2 5 #f))
(test-equal '((0 6 0)) (region-runs "abcdef" 2 2 #t))
(test-equal '((0 6 0)) (region-runs "abcdef" 2 #f #t))

;; When the active region reaches the end of a line, its face fills the
;; remaining screen cells; a final line at point-max has no newline to extend.
(test-equal #t
  (with-display
   (lambda ()
     (let* ((ed (region-buffer "ab\ncdef" 3 0 #t))
            (attribute (xd:line-end-fill-attribute ed 0 "ab" "ab" 10)))
       (and attribute (not (= attribute 0)))))
   1 'mono #f))
(test-equal #f
  (with-display
   (lambda ()
     (xd:line-end-fill-attribute (region-buffer "abcdef" 3 0 #t)
                                 0 "abcdef" "abcdef" 10))
   1 'mono #f))

(test-end "schemacs_editor_faces_runs")
