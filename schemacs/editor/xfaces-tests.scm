(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (prefix (schemacs editor faces) f:)
 (prefix (schemacs editor xfaces) x:))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor xfaces)', which mirrors GNU
;; Emacs's `xfaces.c'.
;;
;; Two things are worth testing and they are different in kind: the
;; *merge*, which is where a `face' property becomes one set of
;; attributes (and where `:inherit' has to be resolved, which
;; `face-attribute' does not do), and the *fold-down*, which is where a
;; set of attributes becomes the handful of switches a terminal can draw.

(test-begin "schemacs_editor_xfaces")

(define (value attrs attribute) (x:attribute-value attrs attribute))

;; A set with nothing in it answers `unspecified' for everything - the
;; difference between "not said" and "said off".
(test-equal '(unspecified unspecified)
  (list (value (x:face-attributes-empty) ':weight)
        (value (x:face-attributes-empty) ':inverse-video)))

;; Merging a face's attributes in: what the face says arrives, and what it
;; does not say stays unsaid rather than becoming nil.
(test-equal '(bold unspecified)
  (let ((to (x:merge-face-vectors (x:face-realized-attributes 'bold)
                                  (x:face-attributes-empty))))
    (list (value to ':weight) (value to ':stipple))))

;; `:inherit' is resolved - and this is the part `faces.el''s
;; `face-attribute' does *not* do. `mode-line-inactive' inherits
;; `mode-line', which on a terminal is inverse video, so merging the
;; former gives the latter's `:inverse-video' even though
;; `mode-line-inactive' never says it.
(test-equal '(#t mode-line)
  (let ((to (x:merge-face-vectors
             (x:face-realized-attributes 'mode-line-inactive)
             (x:face-attributes-empty))))
    (list (value to ':inverse-video) (value to ':inherit))))

;; A face's *own* attributes win over what it inherits: the merge is done
;; with `:inherit' first, then overwritten by the face itself. `error'
;; inherits nothing but has a `default' branch, so this checks the other
;; direction - `underline' inherits nothing and is underlined.
(test-equal #t
  (value (x:merge-face-vectors (x:face-realized-attributes 'underline)
                               (x:face-attributes-empty))
         ':underline))

;; A `face' property may be a face name, a property list, or a list of
;; either - and a list merges left to right so the last one wins.
(test-equal 'italic
  (let ((to (x:merge-face-ref 'bold (x:face-attributes-empty))))
    (value (x:merge-face-ref '(:weight italic) to) ':weight)))

;; A *list* of references merges left to right, so the last one wins -
;; which is what makes `(face 'bold '(:weight italic))' mean italic.
(test-equal 'italic
  (value (x:merge-face-ref '(bold (:weight italic)) (x:face-attributes-empty))
         ':weight))

;; The fold-down. What survives on a terminal is the switches and the
;; colours; everything a graphical display would use a font for is gone.
(test-equal '(#t #f #f #f #f)
  (let ((tt (x:realize-tty-face (x:face-realized-attributes 'bold))))
    (list (value tt ':bold) (value tt ':italic)
          (value tt ':underline) (value tt ':reverse)
          (value tt ':strike-through))))

(test-equal '(#f #f #t #f #f)
  (let ((tt (x:realize-tty-face (x:face-realized-attributes 'underline))))
    (list (value tt ':bold) (value tt ':italic)
          (value tt ':underline) (value tt ':reverse)
          (value tt ':strike-through))))

;; The numbers are Emacs's own tables, and the fold-down is what turns a
;; number into a switch: `bold' is 200 and anything above `normal's 100 is
;; bold, while `light' at 50 is not.
(test-equal '(200 110 50 100)
  (list (x:tty-weight-number 'bold) (x:tty-slant-number 'italic)
        (x:tty-weight-number 'light) (x:tty-slant-number 'normal)))

(test-equal '(#t #f #t)
  (list (value (x:realize-tty-face '(:weight bold)) ':bold)
        (value (x:realize-tty-face '(:weight light)) ':bold)
        (value (x:realize-tty-face '(:slant oblique)) ':italic)))

;; Colours fold down to an index, and a colour the terminal does not have
;; answers #f rather than an index nobody can draw.
(test-equal '(1 6 #f)
  (list (x:map-tty-color "red") (x:map-tty-color "cyan")
        (x:map-tty-color "no-such-colour")))

;; What the terminal can show is what `display-supports-face-attributes-p'
;; asks, and a box is the thing it says no to - which is what makes the
;; standard specs fall through to their `(min-colors 8)' branches.
(test-equal '(#t #f)
  (list (x:tty-capable-p '(:weight bold :underline t))
        (x:tty-capable-p '(:box (:line-width 1)))))

(test-end "schemacs_editor_xfaces")
