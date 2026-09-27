(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (prefix (schemacs editor faces) f:))

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

(define (with-display thunk color-cells type background)
  ;; Run THUNK with the display described, then realize the standard
  ;; faces again so the specs are chosen against it.
  ;;--------------------------------------------------------------
  (parameterize ((f:*display-color-cells* color-cells)
                 (f:*display-type* type)
                 (f:*frame-background-mode* background)
                 (f:*window-system* #f))
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
