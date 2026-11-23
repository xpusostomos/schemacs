;; Tests for `(schemacs face-remap)' - GNU Emacs's
;; `face-remap.el': the buffer-local `face-remapping-alist' and the
;; scaling that is built on it.
;;
;; The *shape* expectations follow from the source: `face-remap.el`'s
;; commentary says an entry is `(FACE RELATIVE-SPECS ... BASE-SPECS)`
;; with the relative ones first, and `face-remap-add-relative` returns
;; `(cons face specs)`.
;;
;; **A display has to exist.** `text-scale-increase` is bounded by
;; `text-scale-min-amount` and `-max-amount`, which are computed from the
;; frame's pixel geometry, and with no display at all that geometry is
;; 1x1 - every scale is out of range. So a `<test-display>` is current
;; throughout, exactly as a terminal's display would be.
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme char)
 (only (guile) inexact->exact setvbuf)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (srfi srfi-1) filter last-pair)
 (prefix (schemacs face-remap) r:)
 (prefix (schemacs xfaces) x:)
 (prefix (only (schemacs faces) *undefined-face-attribute*) f:)
 (prefix (schemacs dispnew) dn:)
 (prefix (schemacs test-display) td:)
 (only (schemacs buffer)
       allocate-buffer with-current-buffer current-buffer
       buffer-local-value)
 (only (schemacs editfns) insert))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_face_remap")

(dn:current-display (make td:<test-display>
                       #:columns 80 #:rows 24
                       #:column-width 9 #:line-height 20))

(define (keyword-spec? x)
  ;; A face spec that is a property list rather than a face name.
  (and (pair? x) (eq? (string-ref (symbol->string (car x)) 0) #\:)))

(define (in-a-buffer thunk)
  ;; Run THUNK with a fresh buffer current - remappings are buffer-local,
  ;; so each of these tests needs a buffer of its own.
  (with-current-buffer (allocate-buffer) (thunk)))

;; A relative height as the hundredths digit, so the expectations do not
;; depend on how a flonum prints.
(define (scaled-height)
  (inexact->exact
   (round (* 100 (x:attribute-value
                  (x:merge-face-ref 'default (x:face-attributes-empty))
                  ':height)))))

;;------------------------------------------------------------------
;; `face-remap-add-relative' and its cookie
;;
;; The entry is `(FACE SPEC ... FACE)': the relative spec first, the
;; face's own definition as the base. The *first* element wins when the
;; list is merged - Emacs merges a face list from the end backwards - and
;; that is what makes the relative spec apply on top of the base.
;;------------------------------------------------------------------

(test-equal '(default (:height 1.2) default)
  (in-a-buffer
   (lambda ()
     (r:face-remap-add-relative 'default ':height 1.2)
     (car (r:face-remapping-alist)))))

;; The cookie is `(cons FACE SPECS)', and removing it takes the entry
;; away entirely: the base is all that is left, and that is the same as
;; no remapping at all.
(test-equal '()
  (in-a-buffer
   (lambda ()
     (let ((cookie (r:face-remap-add-relative 'default ':height 1.2)))
       (r:face-remap-remove-relative cookie)
       (r:face-remapping-alist)))))

;; Adding twice keeps both, the newer one first - and `face-remap-order'
;; puts the *absolute* one ahead of the relative one, which is the sort
;; it exists for.
(let ((entry (in-a-buffer
              (lambda ()
                (r:face-remap-add-relative 'default ':height 1.2)
                (r:face-remap-add-relative 'default ':foreground "red")
                (car (r:face-remapping-alist))))))
  (test-equal "adding twice keeps the face first and the base last"
    (list 'default 'default) (list (car entry) (car (last-pair entry))))
  (test-equal "and both specs, the newer one second"
    2 (length (filter (lambda (x) (keyword-spec? x)) entry))))

;; **The remapping is buffer-local**: another buffer does not see it.
(test-equal '(#f ())
  (let ((one (allocate-buffer))
        (two (allocate-buffer)))
    (with-current-buffer one
      (r:face-remap-add-relative 'default ':height 1.2))
    (list (buffer-local-value two 'face-remapping-alist #f)
          (with-current-buffer two (r:face-remapping-alist)))))

;;------------------------------------------------------------------
;; `face-remap-set-base' and `face-remap-reset-base'
;;
;; Setting the base replaces the face's own definition; resetting it
;; puts the face back. "If there's nothing except a base remapping, we
;; simply remove the entire remapping entry, as setting the base to the
;; default would be the same as the global definition."
;;------------------------------------------------------------------

(test-equal '((default (:weight bold)))
  (in-a-buffer
   (lambda ()
     (r:face-remap-set-base 'default '(:weight bold))
     (r:face-remapping-alist))))

(test-equal '()
  (in-a-buffer
   (lambda ()
     (r:face-remap-set-base 'default '(:weight bold))
     (r:face-remap-reset-base 'default)
     (r:face-remapping-alist))))

;; A relative spec on top of a base: resetting the base keeps the spec
;; and puts the face back as the lowest-priority element.
(test-equal '((default (:height 1.5) default))
  (in-a-buffer
   (lambda ()
     (r:face-remap-add-relative 'default ':height 1.5)
     (r:face-remap-set-base 'default '(:weight bold))
     (r:face-remap-reset-base 'default)
     (r:face-remapping-alist))))

;;------------------------------------------------------------------
;; `face-remap-order'
;;
;; "This function tries to sort multiple remappings for the same face, so
;; that remappings specifying relative face attributes are applied after
;; remappings specifying absolute face attributes."
;;
;; It is called on the *specs list*, whose last element is the base -
;; `(setcdr entry (face-remap-order (cons specs faces)))` - and not on
;; the whole `(FACE SPEC ... BASE)` entry.
;;------------------------------------------------------------------

(test-equal '((:height 1.5) (:foreground "red") default)
  (r:face-remap-order '((:foreground "red") (:height 1.5) default)))

;;------------------------------------------------------------------
;; `text-scale-mode' and `text-scale-increase'
;;
;; One step is a *factor* of `text-scale-mode-step' (1.2), applied to the
;; default face through a relative remapping - not to the face's own
;; `:height', which is why this and `global-text-scale-adjust' are two
;; commands.
;;------------------------------------------------------------------

(define (scale-state)
  (list (r:text-scale-mode-variable)
        (r:text-scale-mode-amount)
        (r:text-scale-mode-lighter)
        (r:face-remapping-alist)))

(test-equal '(#t 1 "+1" ((default (:height 1.2) default)))
  (in-a-buffer (lambda () (r:text-scale-increase 1) (scale-state))))

;; Two steps compound: 1.2 squared is 1.44, which is 144 hundredths.
(test-equal '(144 2 "+2")
  (in-a-buffer (lambda ()
                 (r:text-scale-increase 1)
                 (r:text-scale-increase 1)
                 (list (scaled-height)
                       (r:text-scale-mode-amount)
                       (r:text-scale-mode-lighter)))))

;; An argument of 0 removes any scaling, and the mode goes off with it.
(test-equal '(#f 0 "+0" ())
  (in-a-buffer (lambda ()
                 (r:text-scale-increase 2)
                 (r:text-scale-increase 0)
                 (scale-state))))

;; Shrinking is a negative amount, and the lighter says so.
(test-equal '(#t -1 "-1")
  (in-a-buffer (lambda ()
                 (r:text-scale-decrease 1)
                 (list (r:text-scale-mode-variable)
                       (r:text-scale-mode-amount)
                       (r:text-scale-mode-lighter)))))

;; `text-scale-set' goes straight to a level.
(test-equal '(#t 3 "+3")
  (in-a-buffer (lambda ()
                 (r:text-scale-set 3)
                 (list (r:text-scale-mode-variable)
                       (r:text-scale-mode-amount)
                       (r:text-scale-mode-lighter)))))

;;------------------------------------------------------------------
;; The bounds
;;
;; `text-scale-min-amount' is "when the resulting pixel-height of
;; characters will become smaller than 1 pixel" - `log(1/20)/log(1.2)`
;; for this display's 20-pixel line, which is about -16.4. The maximum is
;; bounded by the display's width in *characters* - `log(6480/9)/log(1.2)`
;; for 6480 pixels of 9-pixel cells, which is about 36.1.
;;
;; Both are the C's arithmetic: `(log (/ 1.0 (frame-char-height))
;; text-scale-mode-step)` and `(log (/ (min (display-pixel-width) #xffff)
;; (frame-char-width)) text-scale-mode-step)`.
;;------------------------------------------------------------------

(test-assert (and (< (r:text-scale-min-amount) -16)
                  (> (r:text-scale-min-amount) -17)))
(test-assert (and (> (r:text-scale-max-amount) 35)
                  (< (r:text-scale-max-amount) 37)))

;;------------------------------------------------------------------
;; A scaled face reaches the *row*, not just the glyphs
;;
;; `C-x +` grows the text, and the row it sits on has to grow with it -
;; otherwise the taller glyphs are cut off by the line below, which is
;; what Chris reported: "the font actually gets taller, but it truncated
;; by the next lines, so line spacing is wrong".
;;
;; The row's height is `row-metrics`'s, which asks the display for the
;; metrics of the face at the position. The face comes from
;; `attrs-at-buffer-position`, and *that* is where the bug was: it began
;; from `face-realized-attributes 'default`, which answers the face's
;; global definition and never consults the buffer's
;; `face-remapping-alist`. So the row was measured from the unscaled
;; default while the glyphs were drawn at the scale.
;;
;; Emacs reads the base through `lookup_basic_face` (`xfaces.c:7005`),
;; which applies `Vface_remapping_alist`. `merge-face-ref` is this tree's
;; equivalent, and that is what the base is read through now.
;;------------------------------------------------------------------

(test-equal "a scaled buffer's row is measured from the scaled face"
  '(#t #t)
  (in-a-buffer
   (lambda ()
     (let* ((ed (current-buffer))
            (attrs-at (@@ (schemacs xdisp) attrs-at-buffer-position))
            (before (x:attribute-value (attrs-at ed 1) ':height)))
       (r:text-scale-increase 2)
       (let ((after (x:attribute-value (attrs-at ed 1) ':height)))
         ;; Before the fix this was `unspecified` - the *global* default,
         ;; which is what `face-realized-attributes` answers - so every
         ;; row was measured at the unscaled height however tall the
         ;; glyphs were drawn.
         (list (eq? before f:*undefined-face-attribute*)
               (and (number? after) (not (eq? after before)))))))))

;; The rendered consequence - that a row below a scaled line actually
;; starts *below* the taller glyphs - needs a display with a font. A
;; `<test-display>` is a terminal: its `face-metrics` answers one height
;; for every face, so a scaled attribute cannot move it, and asserting
;; the growth here would be asserting a display this file does not have.
;; `pgtk-tests.scm` has that half, on the display whose `face-metrics`
;; does read `:height`.
(test-end "schemacs_editor_face_remap")
