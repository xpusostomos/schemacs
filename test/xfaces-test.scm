(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (prefix (schemacs faces) f:)
 (prefix (schemacs xfaces) x:)
 ;; A buffer, because `face-remapping-alist' is buffer-local and the
 ;; remapping is read through whatever buffer is current.
 (only (schemacs buffer)
       allocate-buffer current-buffer set-buffer-local-value!
       with-current-buffer))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs xfaces)', which mirrors GNU
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
;; either. A property list merged into what is already there is the
;; ordinary case: the later attribute wins.
(test-equal 'italic
  (let ((to (x:merge-face-ref 'bold (x:face-attributes-empty))))
    (value (x:merge-face-ref '(:weight italic) to) ':weight)))

;; **A *list* of references is merged from the end backwards**, so the
;; *first* element wins - `xfaces.c:2989`: "This is a list of face refs.
;; Those at the beginning of the list take precedence over what follows,
;; so we have to merge from the end backwards." This test used to pin
;; the opposite, and it is the reason `text-scale-mode` did nothing: the
;; relative `:height` a remapping puts *first* lost to the base face
;; that follows it.
(test-equal 'bold
  (value (x:merge-face-ref '(bold (:weight italic)) (x:face-attributes-empty))
         ':weight))
(test-equal 'italic
  (value (x:merge-face-ref '((:weight italic) bold) (x:face-attributes-empty))
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


;;------------------------------------------------------------------
;; `face-remapping-alist'
;;
;; GNU Emacs's `get_lface_attributes' (`xfaces.c:2124') answers a face
;; name through the *buffer's* `face-remapping-alist' before the global
;; definition, and a remapped face is answered **entirely** by the
;; mapping - the attribute vector is reset first, so the global face does
;; not show through. That is what `text-scale-mode' (`face-remap.el')
;; adjusts the font size with, and it is what this checks.
;;------------------------------------------------------------------

(define (attributes-with-remapping remapping)
  ;; The attributes the `default' face realizes to in a buffer whose
  ;; `face-remapping-alist' is REMAPPING, and in one with none.
  (let ((remapped (allocate-buffer))
        (plain (allocate-buffer)))
    (set-buffer-local-value! remapped 'face-remapping-alist remapping)
    (list (with-current-buffer remapped
            (x:merge-face-ref 'default (x:face-attributes-empty)))
          (with-current-buffer plain
            (x:merge-face-ref 'default (x:face-attributes-empty))))))

(let ((answer (attributes-with-remapping '((default (:background "red"))))))
  (test-equal "a remapped face takes the buffer's mapping"
    "red" (value (car answer) ':background))
  ;; **And nothing of the global face shows through** - the mapping is
  ;; the whole answer, which is Emacs's reset-before-merge.
  (test-equal "a remapped face has no attribute it does not name"
    'unspecified (value (car answer) ':weight))
  ;; a buffer with no mapping is untouched
  (test-equal "a buffer with no mapping uses the global face"
    'unspecified (value (cadr answer) ':background)))

;; A face the mapping does not name is not remapped at all: `bold` still
;; realizes its own `(:weight bold)` spec.
(test-equal "a face the mapping does not name is the global one"
  (list 'unspecified 'bold)
  (let* ((buffer (allocate-buffer))
         (answer (with-current-buffer buffer
                   (x:merge-face-ref 'bold (x:face-attributes-empty)))))
    (list (value answer ':background) (value answer ':weight))))

(test-end "schemacs_editor_xfaces")
