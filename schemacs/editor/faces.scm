(define-library (schemacs editor faces)
  ;; This library mirrors GNU Emacs's `faces.el`: the faces themselves -
  ;; the named sets of attributes that text can be drawn with - and the
  ;; specs that say which attributes a face has on a given display.
  ;;
  ;; A face is three things stacked, and this library is the first two:
  ;;
  ;;   1. a *spec*, from `defface': a list of `(DISPLAY . ATTRIBUTES)'
  ;;      branches, of which the first whose DISPLAY matches the terminal
  ;;      is the one that counts;
  ;;   2. the *realized* attributes, which are what the spec's chosen
  ;;      branch came to;
  ;;   3. the `face' text property, which is how a face reaches
  ;;      characters at all - that is `(schemacs editor textprop)' and the
  ;;      display, not this.
  ;;
  ;; Three deviations, each stated where it is felt:
  ;;
  ;;  * **One frame.** Emacs realizes a face per frame, because the same
  ;;    face has to look different on a terminal and on a window system,
  ;;    and keeps `face-new-frame-defaults' for frames not made yet. There
  ;;    is one frame here, so there is one set of realized attributes, and
  ;;    the FRAME argument is accepted and not consulted. The meaning is
  ;;    unchanged - a spec is still chosen per display - but the storage is
  ;;    flatter.
  ;;  * **No Custom, no themes, no X resources.** `face-spec-recalc'
  ;;    applies the defface spec and the override spec and nothing else,
  ;;    which is those three steps with nothing in between.
  ;;  * **Attribute values are not resolved against a terminal here.**
  ;;    Emacs turns a colour name into a pixel, loads a font and drops
  ;;    what the display cannot show while *setting* the attribute. That
  ;;    is the fold-down `(schemacs editor xfaces)' does, one layer down,
  ;;    so this library records what a spec says and stops.
  ;;
  ;; See FACES-PLAN.txt for the plan this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `(inexact->exact (truncate ...))' for a relative `:height' resolved
    ;; against an absolute one - Emacs's "relative X absolute => absolute".
    ;; `(inexact->exact (truncate ...))' for a relative `:height' resolved
    ;; against an absolute one - Emacs's "relative X absolute => absolute".
    ;; `caddr' is `(guile)''s - `color-dark-p''s blue component reads
    ;; it, as most of this tree's three-part accessors do.
    (only (guile) inexact->exact caddr)
    ;; `get' reads a face's `theme-face' property - the enabled themes'
    ;; specs, which `face-spec-recalc' now walks - and `plist-member' is
    ;; what finds `:extend' in the chosen branch. Both are `fns.c`'s,
    ;; which is `intervals.scm`'s until there is an `fns.sld` of its own.
    (only (schemacs editor intervals) get put plist-member)
    ;; `current-display' answers "is there a frame to realize a face
    ;; against?" - which is what Emacs's `(dolist (frame (frame-list))
    ;; (face-spec-recalc face frame))' asks, and why a `defface' at load
    ;; time recalculates nothing. It is #f until a front end opens the
    ;; display, which is Emacs's empty frame list.
    (only (schemacs editor dispnew) current-display
          ;; `xfaces.c` sets `windows_or_buffers_changed` when a face
          ;; changes (`:801`, `:3110`, `:3200`): the redisplay skips a
          ;; window whose glyph matrix is still good, so a face that moves
          ;; has to say so.
          set-windows-or-buffers-changed!))

  (export
   ;; the face table
   check-face
   face-list
   facep
   make-face
   ;; reading
   face-all-attributes
   face-attribute
   face-attribute-merged-with
   face-attribute-relative-p
   face-documentation
   face-defface-spec
   face-override-spec
   internal-get-lisp-face-attribute
   merge-face-attribute
   ;; writing
   internal-set-lisp-face-attribute
   set-face-attribute
   ;; specs
   custom-declare-face
   defface
   face-spec-choose
   face-spec-recalc
   face-spec-reset-face
   face-spec-set
   face-spec-set-2
   face-spec-set-match-display
   ;; what the display can do, which the specs are chosen against
   display-supports-face-attributes-p
   *display-color-cells*
   *display-type*
   *face-attribute-name-alist*
   *face-attributes*
   color-dark-p
   *frame-background-mode-function*
   *frame-background-mode*
   *undefined-face-attribute*
   *window-system*
   )

  (begin

    (define *face-attributes*
      ;; The attributes each face has been given, as an alist of
      ;; `(FACE . PLIST)'. Emacs holds these per frame
      ;; (`frame-face-alist') and keeps a separate set of defaults for
      ;; frames not made yet; one frame here means one set - see the
      ;; header.
      ;;
      ;; A parameter so that a test can bind it and get a clean slate,
      ;; which is this project's convention for state a test would
      ;; otherwise leak into the next one.
      ;;--------------------------------------------------------------
      (make-parameter '()))


    ;;----------------------------------------------------------------
    ;; The faces, and their attributes

    (define *face-attribute-name-alist*
      ;; GNU Emacs's `face-attribute-name-alist': every attribute a face
      ;; can have, with a descriptive name. The order is the order Emacs
      ;; lists them in, and `face-all-attributes' answers in it.
      ;;--------------------------------------------------------------
      '((:family . "font family")
        (:foundry . "font foundry")
        (:width . "character set width")
        (:height . "height in 1/10 pt")
        (:weight . "weight")
        (:slant . "slant")
        (:underline . "underline")
        (:overline . "overline")
        (:extend . "extend")
        (:strike-through . "strike-through")
        (:box . "box")
        (:inverse-video . "inverse-video display")
        (:foreground . "foreground color")
        (:background . "background color")
        (:stipple . "background stipple")
        (:inherit . "inheritance")))

    (define *undefined-face-attribute* 'unspecified)
    ;; ^ GNU Emacs's `unspecified': the value an attribute has when
    ;; nothing has set it, and not the same as nil (which says "off").

    (define (facep face)
      ;; GNU Emacs's `facep': whether FACE names a face.
      ;;--------------------------------------------------------------
      (and (symbol? face) (assq face (*face-attributes*)) #t))

    (define (check-face face)
      ;; GNU Emacs's `check-face': FACE, or an error naming it.
      ;;--------------------------------------------------------------
      (or (and (facep face) face)
          (error "Invalid face" face)))

    (define (face-list)
      ;; GNU Emacs's `face-list': every face that exists.
      ;;--------------------------------------------------------------
      (map car (*face-attributes*)))

    (define (make-face face)
      ;; GNU Emacs's `make-face': a face with no attributes set, made if
      ;; it does not exist and answered with if it does.
      ;;--------------------------------------------------------------
      (unless (facep face)
        (*face-attributes*
         (cons (cons face '()) (*face-attributes*))))
      face)

    (define (internal-get-lisp-face-attribute face attribute . args)
      ;; The C `internal-get-lisp-face-attribute': ATTRIBUTE's value on
      ;; FACE, or `unspecified' when nothing has set it.
      ;;
      ;; Emacs reads this off the *frame* the face is realized on; there
      ;; is one frame here, so there is one set of realized attributes
      ;; and the frame argument is accepted and not consulted. That is a
      ;; deviation of the data model, not of the meaning: see the header.
      ;;--------------------------------------------------------------
      (let ((entry (assq (check-face face) (*face-attributes*))))
        ;; **No fallback is invented here.** The `default' face answers a
        ;; `:height' because the two places Emacs writes one into the
        ;; LFace are ported - `face-spec-reset-face' pins it to 1 on a
        ;; non-graphic frame (`faces.el:1667') and leaves a realized
        ;; height alone on a graphic one, and the GUI front end fills it
        ;; from the frame's font the way `set_lface_from_font'
        ;; (`xfaces.c:2211') does (`pgtk-ensure-font!'). Answering a
        ;; made-up height here looked like a fix and was a departure: it
        ;; said 100 on a terminal, where Emacs says 1.
        (and entry
             (let loop ((plist (cdr entry)))
               (cond ((not (and (pair? plist) (pair? (cdr plist))))
                      *undefined-face-attribute*)
                     ((eq? (car plist) attribute) (cadr plist))
                     (else (loop (cddr plist))))))))

    (define (face-attribute-relative-p attribute value)
      ;; GNU Emacs's `face-attribute-relative-p' (`xfaces.c:4193'). Its
      ;; docstring is the whole rule:
      ;;
      ;;   "A relative value is one that doesn't entirely override
      ;;    whatever is inherited from another face. For most possible
      ;;    attributes, the only relative value that users see is
      ;;    `unspecified'. However, for `:height', floating point values
      ;;    are also relative."
      ;;
      ;; So `unspecified' is relative for *every* attribute, `:height' is
      ;; relative for anything that is not a fixnum, and nothing else is
      ;; relative at all. **This used to answer `t' for `:weight bold',
      ;; `:slant italic', a coloured `:underline' and a `:box' list,
      ;; which is not this function.** Those values are merged rather
      ;; than replaced, but by `merge_face_vectors' (`xfaces.sld'), and
      ;; conflating the two made `face-remap-order' sort absolute
      ;; remappings as if they were relative.
      ;;--------------------------------------------------------------
      (cond
       ((eq? value *undefined-face-attribute*) #t)
       ((eq? attribute ':height) (not (and (integer? value) (exact? value))))
       (else #f)))

    (define (merge-face-attribute attribute value1 value2)
      ;; The C `merge_face_attribute', which is *much* smaller than it
      ;; looks like it should be: a relative VALUE1 is only actually
      ;; resolved for `:height'. For every other attribute the relative
      ;; value is handed back as it stands, so `face-attribute' with
      ;; INHERIT may still answer a relative value - which its docstring
      ;; says it may, and is why the display does not use this function.
      ;;
      ;; The display merges faces with `merge_face_vectors' instead, which
      ;; resolves weight, slant, underline and the rest as it walks
      ;; `:inherit'. That is a different function in a different file
      ;; (`xfaces.c') and belongs to `(schemacs editor xfaces)'.
      ;;--------------------------------------------------------------
      (cond
       ((eq? value1 *undefined-face-attribute*) value2)
       ((eq? attribute ':height)
        ;; `merge_face_heights' (`xfaces.c:2253'), which this C function
        ;; calls: a fixnum is absolute and is used as it stands; a
        ;; flonum is a *scale* of VALUE2, and "relative X absolute =>
        ;; absolute".
        (cond
         ((and (integer? value1) (exact? value1)) value1)
         ((and (real? value1) (number? value2))
          (if (and (integer? value2) (exact? value2))
              (inexact->exact (truncate (* value1 value2)))
              (* value1 value2)))
         (else value1)))
       (else value1)))

    (define (face-attribute-merged-with attribute value faces . args)
      ;; GNU Emacs's `face-attribute-merged-with': VALUE merged with the
      ;; faces it inherits from, until it is no longer relative.
      ;;--------------------------------------------------------------
      (cond
       ((not (face-attribute-relative-p attribute value)) value)
       ((null? faces) value)
       ((pair? faces)
        (face-attribute-merged-with
         attribute
         (face-attribute-merged-with attribute value (car faces))
         (cdr faces)))
       (else
        ;; "It's not resource, but it's a list of faces. One of them may
        ;; not exist." - `faces.el`'s own guard in
        ;; `face-attribute-merged-with`: an inherited face that is not
        ;; defined contributes nothing. A theme converted from Modus
        ;; inherits faces this editor has no `defface` for
        ;; (`modus-themes-ui-variable-pitch` is one), and raising
        ;; "Invalid face" there killed the whole redisplay.
        (merge-face-attribute attribute value
                              (if (facep faces)
                                  (face-attribute faces attribute #f #t)
                                  *undefined-face-attribute*)))))

    (define (face-attribute face attribute . args)
      ;; GNU Emacs's `face-attribute': ATTRIBUTE's value on FACE.
      ;;
      ;; The optional arguments are FRAME and then INHERIT
      ;; (`(face-attribute FACE ATTRIBUTE &optional FRAME INHERIT)').
      ;; FRAME is accepted and not consulted: Emacs reads the attribute
      ;; off the frame the face is realized on, and there is one frame
      ;; here - the same deviation `internal-get-lisp-face-attribute'
      ;; documents.
      ;;
      ;; **It read INHERIT where FRAME belongs until 2026-11-09.** Every
      ;; existing caller that passed an INHERIT passed a FRAME first
      ;; (`(face-attribute FACE A #f INHERIT)'), so the two shapes
      ;; agreed; the omarchy port's `(face-attribute 'default :height
      ;; FRAME)' is the first that passes only a FRAME, and it was read
      ;; as an inherit face.
      ;;
      ;; With no INHERIT only what FACE itself defines is read, so the
      ;; answer may be `unspecified` or a relative value; with INHERIT the
      ;; value is merged with the faces `:inherit' names, and with
      ;; INHERIT = `default' (or a face) it is merged with that too, until
      ;; it is absolute. That is what makes `(face-attribute F :weight nil
      ;; 'default)' always answer a weight.
      ;;--------------------------------------------------------------
      (let ((frame (if (pair? args) (car args) #f))
            (inherit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (let* ((value (internal-get-lisp-face-attribute face attribute frame))
               (value (if (and inherit (face-attribute-relative-p attribute value))
                          (let ((inh-from (face-attribute face ':inherit)))
                            (if (or (not inh-from)
                                    (eq? inh-from *undefined-face-attribute*))
                                value
                                (face-attribute-merged-with
                                 attribute value inh-from)))
                          value)))
          (if (and inherit
                   (not (eq? inherit #t))
                   (face-attribute-relative-p attribute value))
              (face-attribute-merged-with attribute value inherit)
              value))))

    (define (face-all-attributes face . args)
      ;; GNU Emacs's `face-all-attributes': every attribute of FACE as an
      ;; alist, in `face-attribute-name-alist' order.
      ;;--------------------------------------------------------------
      (map (lambda (pair)
             (cons (car pair) (face-attribute face (car pair) #t 'default)))
           *face-attribute-name-alist*))

    ;;----------------------------------------------------------------
    ;; What the display can do
    ;;
    ;; `face-spec-choose' picks a `defface' branch by asking these. On a
    ;; terminal they are nearly constant, so they are parameters: a test
    ;; can bind them and a future window-system backend can set them.

    (define *window-system*
      ;; GNU Emacs's `(window-system FRAME)': #f on a terminal, and a
      ;; symbol naming the window system otherwise. A `(type tty)' branch
      ;; of a spec matches exactly when this is #f.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *display-type*
      ;; GNU Emacs's `display-type' frame parameter: `color', `grayscale'
      ;; or `mono'.
      ;;--------------------------------------------------------------
      (make-parameter 'color))

    (define *display-color-cells*
      ;; GNU Emacs's `(display-color-cells FRAME)': how many colours the
      ;; display has. This is what a `(min-colors 8)' branch is tested
      ;; against, and it is why a spec written for 88 colours falls
      ;; through to its `(t ...)' branch on an 8-colour terminal.
      ;;--------------------------------------------------------------
      (make-parameter 8))

    (define *frame-background-mode*
      ;; GNU Emacs's `frame-background-mode': `light' or `dark', or #f
      ;; when it is not known - in which case a `(background dark)'
      ;; branch does not match either way, which is what Emacs does until
      ;; something asks the terminal.
      ;;
      ;; **It is also the user's override**, which is the sense Emacs's
      ;; defvar has (`frame.el:1467'): "If non-nil, use that setting
      ;; rather than determine the background mode from the frame
      ;; color". `frame-terminal-default-bg-mode' asks it first, and
      ;; `frame--current-background-mode''s computed answer is what it
      ;; falls through to.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    ;; **The Emacs name of this parameter, for theme data.** A theme file
    ;; is written in Emacs's names, and this tree's dynamically bound
    ;; variables carry stars; `frame-background-mode` is the one variable
    ;; a Modus-derived theme sets, so its two halves are registered under
    ;; the Emacs name - where `custom--getter` and `custom--setter` read
    ;; them - while the starred parameter stays the name a library here
    ;; uses.
    (put 'frame-background-mode 'custom-reader
         (lambda () (*frame-background-mode*)))
    (put 'frame-background-mode 'custom-writer
         (lambda (symbol value) (*frame-background-mode* value)))

    ;; The relative luminance a background must fall under to count as
    ;; dark - `faces.el:1894''s "cut-off value determined
    ;; experimentally".
    (define *color-luminance-dark-limit* 0.325)

    (define (color-dark-p rgb)
      ;; GNU Emacs's `color-dark-p' (`faces.el:1900'): "Whether RGB is
      ;; more readable against white than black. RGB is a 3-element list
      ;; (R G B), each component in the range [0,1]."
      ;;
      ;; "Compute the relative luminance after gamma-correcting
      ;; (assuming sRGB), and compare to a cut-off value determined
      ;; experimentally." The gamma is 2.2, "an approximation to sRGB
      ;; gamma; it should be good enough for the purpose of this
      ;; function", and the components weigh as the CIE curve does.
      ;;--------------------------------------------------------------
      (let* ((r (expt (car rgb) 2.2))
             (g (expt (cadr rgb) 2.2))
             (b (expt (caddr rgb) 2.2))
             (y (+ (* r 0.2126) (* g 0.7152) (* b 0.0722))))
        (< y *color-luminance-dark-limit*)))

    (define (display-supports-face-attributes-p options)
      ;; GNU Emacs's `display-supports-face-attributes-p': whether the
      ;; display can show the attributes in OPTIONS, a plist. A terminal
      ;; can show weight, slant, underline and inverse-video and not much
      ;; else, and `(supports :box t)' - which several of the standard
      ;; specs test - is what this answers no to.
      ;;--------------------------------------------------------------
      (let loop ((rest options))
        (cond
         ((not (and (pair? rest) (pair? (cdr rest)))) #t)
         ((memq (car rest) '(:weight :slant :underline :inverse-video
                                      :foreground :background))
          (loop (cddr rest)))
         (else #f))))

    (define (face-spec-set-match-display display)
      ;; GNU Emacs's `face-spec-set-match-display': whether DISPLAY, one
      ;; conjunct list from a spec, matches this display. Every conjunct
      ;; must match; a conjunct is `(REQ OPTION ...)'.
      ;;--------------------------------------------------------------
      ;; **Two spellings of Elisp's `t' meet here.** This tree's own
      ;; `defface' specs write `#t' for "matches every display", but a
      ;; *theme file* carries Elisp data: inside a backquoted spec the
      ;; symbol `t' is literal, and Emacs compares against that symbol
      ;; (`faces.el', `face-spec-set-match-display' starts `(if (eq
      ;; conjuncts t) ...)'). A stock theme's `((t (:inherit ...)))'
      ;; therefore read as a conjunct list beginning with the symbol `t'
      ;; and failed as "expecting pair" - every theme converted from
      ;; GNU Emacs's `etc/themes' has entries of that shape.
      ;;--------------------------------------------------------------
      (if (or (eq? display #t) (eq? display 't))
          #t
          (let loop ((conjuncts display) (match #t))
            (cond
             ((or (not match) (null? conjuncts)) match)
             (else
              (let* ((conjunct (car conjuncts))
                     (req (car conjunct))
                     (options (cdr conjunct)))
                (loop (cdr conjuncts)
                      (cond
                       ((eq? req 'type)
                        (or (and (memq (*window-system*) options) #t)
                            (and (not (*window-system*))
                                 (memq 'tty options)
                                 #t)))
                       ((eq? req 'min-colors)
                        (and (>= (*display-color-cells*) (car options)) #t))
                       ((eq? req 'class)
                        (and (memq (*display-type*) options) #t))
                       ((eq? req 'background)
                        (and (memq (*frame-background-mode*) options) #t))
                       ((eq? req 'supports)
                        (display-supports-face-attributes-p options))
                       (else
                        (error "Unknown req" req options))))))))))

    (define (face-spec-choose spec . args)
      ;; GNU Emacs's `face-spec-choose': the attributes SPEC picks for
      ;; this display - the first branch whose condition matches.
      ;;
      ;; A `default' condition is not a condition: it sets the attributes
      ;; that following branches are *appended to*, which is how
      ;; `mode-line-inactive' inherits from `mode-line' and then adds its
      ;; own. If nothing matches and there was a default, the default is
      ;; the whole answer.
      ;;--------------------------------------------------------------
      (let ((no-match (if (pair? args) (car args) #f)))
        (let loop ((tail spec) (result #f) (defaults #f) (found #f))
          (cond
           ;; A face with no spec of this kind has #f, not the empty list -
           ;; `face-spec-recalc' asks for both specs either way.
           ((not (pair? tail))
            (cond (defaults (append defaults (or result '())))
                  (found result)
                  (else no-match)))
           (else
            (let* ((entry (car tail))
                   (display (car entry))
                   (attrs (cdr entry))
                   ;; An old-style entry is `(DISPLAY ATTRS)' with the
                   ;; attributes as one list; a new-style one is
                   ;; `(DISPLAY ATTR VALUE ...)'.
                   ;; **An entry may name no attributes at all**, which
                   ;; is `defface menu`'s `(type x-toolkit)` branch: it
                   ;; matches a GUI frame and specifies nothing. `(cdr
                   ;; attrs)` on the empty list raised here, so the one
                   ;; spec in Emacs with an empty branch could not be
                   ;; ported.
                   (thisval (cond ((null? attrs) '())
                                  ((null? (cdr attrs)) (car attrs))
                                  (else attrs))))
              (cond
               ((eq? display 'default)
                (loop (cdr tail) result thisval found))
               ((face-spec-set-match-display display)
                (loop '() thisval defaults #t))
               (else (loop (cdr tail) result defaults found)))))))))

    (define (internal-set-lisp-face-attribute face attribute value)
      ;; The C `internal-set-lisp-face-attribute`: ATTRIBUTE of FACE
      ;; becomes VALUE.
      ;;
      ;; Emacs sets it on a frame and does the work of turning a colour
      ;; name into a pixel, loading a font, and so on. None of that
      ;; applies to a terminal - the realization is `(schemacs editor
      ;; xfaces)''s - so this records the value, which is what the rest of
      ;; `faces.el' reads.
      ;;--------------------------------------------------------------
      (let ((face (check-face face)))
        (let loop ((rest (*face-attributes*)) (acc '()))
          (cond
           ((null? rest) (*face-attributes* (reverse acc)))
           ((eq? (caar rest) face)
            ;; Carry on round the loop rather than storing here: storing
            ;; mid-walk would keep only the faces seen so far and drop
            ;; every face after this one.
            (loop (cdr rest)
                  (cons (cons face (plist-put (cdar rest) attribute value))
                        acc)))
           (else (loop (cdr rest) (cons (car rest) acc)))))
        value))

    (define (plist-put plist key value)
      ;; PLIST with KEY set to VALUE: the entry replaced if it is there,
      ;; added at the front if not - which is what `setq' on a face
      ;; attribute does.
      ;;--------------------------------------------------------------
      (let loop ((rest plist) (acc '()) (found #f))
        (cond
         ((not (and (pair? rest) (pair? (cdr rest))))
          (if found
              (append (reverse acc) rest)
              (cons key (cons value plist))))
         ((eq? (car rest) key)
          (loop (cddr rest) (cons value (cons key acc)) #t))
         (else (loop (cddr rest) (cons (cadr rest) (cons (car rest) acc)) found)))))

    (define *frame-background-mode-function* (make-parameter #f))
    ;; ^ The seam `Fset_face_attribute''s background-colour branch is
    ;; (`xfaces.c:3902'): "Changing the background color might change
    ;; the background mode, so that we have to load new defface specs.
    ;; Call frame-set-background-mode to do that." The C reaches the
    ;; Lisp through `calln' - one obarray - which a Scheme library
    ;; below `frame.scm' cannot; the hook parameter is this tree's
    ;; shape for it (`buffer.scm''s `*buffer-visited-file-modtime-
    ;; function*' is the same arrangement). `frame.scm' installs
    ;; `frame-set-background-mode' as the value, and nobody below
    ;; knows a frame exists.

    (define (set-face-attribute face frame . args)
      ;; GNU Emacs's `set-face-attribute': set attributes of FACE. ARGS is
      ;; the plist, as it is in Elisp; FRAME is accepted and not consulted
      ;; (one frame here - see the header).
      ;;
      ;; **A background change on `default' recomputes the background
      ;; mode**, which is the C's branch - the face-spec branches
      ;; testing `(background dark)' and `(background light)' are only
      ;; as right as that answer, and a theme that sets the default
      ;; face's background has changed them all.
      ;;--------------------------------------------------------------
      (let ((background-changed #f))
        (let loop ((rest args))
          (cond
           ((not (and (pair? rest) (pair? (cdr rest)))) face)
           (else
            (when (and (eq? face 'default)
                       (eq? (car rest) ':background)
                       (not (equal? (cadr rest)
                                    (face-attribute 'default ':background))))
              (set! background-changed #t))
            (internal-set-lisp-face-attribute face (car rest) (cadr rest))
            (loop (cddr rest)))))
        (when (and background-changed (*frame-background-mode-function*))
          ((*frame-background-mode-function*) #f))
        ;; "The face changed, so no cached glyph matrix can be trusted" -
        ;; `xfaces.c:801`.
        (set-windows-or-buffers-changed! #t))
      face)

    (define (face-spec-set-2 face face-attrs)
      ;; GNU Emacs's `face-spec-set-2': apply the attribute plist
      ;; FACE-ATTRS to FACE. Emacs filters out attributes the terminal
      ;; cannot express via `face-x-resources'; that is step C's job here,
      ;; so all of them are applied.
      ;;--------------------------------------------------------------
      (if face-attrs
          (apply set-face-attribute face #f face-attrs)
          #f))

    (define (face-spec-reset-face face)
      ;; GNU Emacs's `face-spec-reset-face' (`faces.el:1652'): "Reset all
      ;; attributes of FACE on FRAME to unspecified", with one exception,
      ;; which is the Elisp's own:
      ;;
      ;;   (if (eq face 'default)
      ;;       ;; For the default face, avoid making any attribute
      ;;       ;; unspecified.  Instead, set attributes to default values
      ;;       ;; (see also realize_default_face in xfaces.c).
      ;;       (append
      ;;        '(:underline nil :overline nil :strike-through nil
      ;;          :box nil :inverse-video nil :stipple nil :inherit nil
      ;;          :extend nil)
      ;;        (when (fboundp 'display-graphic-p)
      ;;          (unless (display-graphic-p frame)
      ;;            `(:family "default" :foundry "default" :width normal
      ;;              :height 1 :weight normal :slant normal
      ;;              :foreground ,(if (frame-parameter nil 'reverse)
      ;;                               "unspecified-bg" "unspecified-fg")
      ;;              :background ,(if (frame-parameter nil 'reverse)
      ;;                               "unspecified-fg" "unspecified-bg")))))
      ;;     ;; For all other faces, unspecify all attributes.
      ;;     face--attributes-unspecified)
      ;;
      ;; **The `default' branch is what keeps a `:height' alive.** On a
      ;; graphic frame the Elisp names no `:height', so the one the
      ;; frame's font gave it - `set_lface_from_font' (`xfaces.c:2211'),
      ;; `pgtk-ensure-font!' here - survives a theme load; on a terminal
      ;; it is pinned to 1, which is `realize_default_face''s non-window
      ;; branch (`xfaces.c:6088'). Both measured on Emacs 31.1:
      ;; `(face-attribute 'default :height)' is 113 before and after
      ;; `(load-theme 'wombat t)' under pgtk, and 1 under `emacs -nw'.
      ;; This used to wipe the whole plist, so a theme load left the
      ;; height `unspecified' - and the omarchy port's guard, which reads
      ;; exactly that attribute, warned and fell back to its own size.
      ;;
      ;; The reset goes through `set-face-attribute' rather than writing
      ;; the table, which is the Elisp's `apply' and is what puts the
      ;; background through the background-mode hook.
      ;;
      ;; Three departures, all of them about the frame this tree does not
      ;; have: there is no `reverse' frame parameter (nothing iconifies
      ;; or reverses), so the ordinary pair is used; `display-graphic-p'
      ;; is `*window-system*' for its one frame; and the `default' branch
      ;; runs only when a display exists at all, because the values it
      ;; writes describe a *frame* and a library loaded before any front
      ;; end has opened one would otherwise pin a terminal's stock height
      ;; into the single set of attributes a GUI frame later inherits -
      ;; measured: a GTK editor opened its font at a tenth of a point and
      ;; the omarchy port warned "height is 1" and fell back to 110.
      ;;--------------------------------------------------------------
      (let ((face (check-face face)))
        (if (and (eq? face 'default) (current-display))
            (apply set-face-attribute face #f
                   (append
                    '(:underline #f :overline #f :strike-through #f :box #f
                      :inverse-video #f :stipple #f :inherit #f :extend #f)
                    (if (*window-system*)
                        '()
                        '(:family "default" :foundry "default"
                          :width normal :height 1
                          :weight normal :slant normal
                          :foreground "unspecified-fg"
                          :background "unspecified-bg"))))
            (apply set-face-attribute face #f
                   (let loop ((rest *face-attribute-name-alist*) (acc '()))
                     (if (null? rest)
                         (reverse acc)
                         (loop (cdr rest)
                               (cons *undefined-face-attribute*
                                     (cons (caar rest) acc)))))))
        face))

    ;;----------------------------------------------------------------
    ;; Specs, and how they become attributes

    (define *face-specs*
      ;; GNU Emacs's `face-defface-spec' symbol property: the spec
      ;; `defface' gave each face, which `face-spec-recalc' realizes.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *face-override-specs*
      ;; GNU Emacs's `face-override-spec': a spec set *after* the
      ;; defface one, which overrides it entirely. `face-spec-set' sets
      ;; this by default, which is what Custom and user code want.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *face-documentation*
      (make-parameter '()))

    (define (face-defface-spec face)
      ;; GNU Emacs's `face-defface-spec': the spec `defface' gave FACE.
      ;;--------------------------------------------------------------
      (let ((entry (assq face (*face-specs*)))) (and entry (cdr entry))))

    (define (face-override-spec face)
      ;; GNU Emacs's `face-override-spec'.
      ;;--------------------------------------------------------------
      (let ((entry (assq face (*face-override-specs*)))) (and entry (cdr entry))))

    (define (face-documentation face)
      ;; GNU Emacs's `face-documentation'.
      ;;--------------------------------------------------------------
      (let ((entry (assq (check-face face) (*face-documentation*))))
        (and entry (cdr entry))))

    (define (face-spec-recalc face)
      ;; GNU Emacs's `face-spec-recalc' (`faces.el:1726'): realize FACE
      ;; again from its specs - reset it, then apply the enabled themes'
      ;; specs, then the defface spec's chosen branch (only when no theme
      ;; matched), then the override spec's.
      ;;
      ;; The theme step is the one this tree was missing, and it is
      ;; Emacs's own shape: each face's `theme-face' property is a list
      ;; of `(THEME SPEC)', the first element of which is the theme
      ;; enabled most recently (`enable-theme' conses onto it), so the
      ;; records are walked in reverse - earliest theme first - and the
      ;; first branch that matches this display wins. A theme's spec
      ;; *overrides* the defface spec entirely rather than inheriting
      ;; from it - `faces.el:1752` - with the one exception of `:extend',
      ;; which is taken from the defface spec when the theme left it
      ;; unspecified.
      ;;
      ;; Emacs walks frames and consults X resources; here there is one
      ;; frame's worth of faces and no X, which leaves these steps.
      ;;--------------------------------------------------------------
      (let* ((face (check-face face))
             (no-match 0)
             (defface-attrs
              (lambda ()
                (face-spec-choose (face-defface-spec face)))))
        (face-spec-reset-face face)
        ;; (theme and user customization)
        (let* ((theme-faces (or (get face 'theme-face) '()))
               (theme-face-applied
                ;; **Every matching theme is applied, in order - not
                ;; the first one that matches.** Emacs's `dolist' over
                ;; the reversed records calls `face-spec-set-2' for each
                ;; record whose spec matches, so the *last* one applied
                ;; (the most recently enabled theme) has the final say.
                ;; Stopping at the first match gave the earliest theme
                ;; precedence and made every later `load-theme' a no-op
                ;; on any face an earlier theme had set - the "first
                ;; theme load works, later ones do nothing" report.
                (let walk ((rest (reverse theme-faces)) (applied #f))
                  (if (null? rest)
                      applied
                      (let ((attrs (face-spec-choose (cadr (car rest))
                                                     no-match)))
                        (if (eq? attrs no-match)
                            (walk (cdr rest) applied)
                            (begin
                              (face-spec-set-2 face attrs)
                              (walk (cdr rest) #t))))))))
          ;; (defface default spec) - only when no theme's spec matched.
          (unless theme-face-applied
            (face-spec-set-2 face (defface-attrs)))
          ;; :extend is inherited from the defface spec even when a
          ;; theme's spec matched, which is `faces.el:1757''s pair of
          ;; branches: the C's `default-attrs' is the defface spec's
          ;; chosen branch, a plist, and `plist-member' is what finds
          ;; `:extend' in it.
          (when (and theme-face-applied
                     (eq? *undefined-face-attribute*
                          (face-attribute face ':extend)))
            (let ((tail (plist-member (defface-attrs) ':extend)))
              (and tail (face-spec-set-2 face (list ':extend (cadr tail))))))
          ;; defface override spec
          (face-spec-set-2 face (face-spec-choose (face-override-spec face))))
        ;; a spec was chosen, so the face's appearance may have moved -
        ;; `xfaces.c:3110`'s `windows_or_buffers_changed`
        (set-windows-or-buffers-changed! #t)
        face))

    (define (face-spec-set face spec . args)
      ;; GNU Emacs's `face-spec-set': SPEC becomes one of FACE's specs,
      ;; and FACE is realized again.
      ;;
      ;; SPEC-TYPE names which spec. nil - the common case, and what this
      ;; defaults to - means the override spec, which *replaces* what the
      ;; defface spec would have chosen rather than adding to it.
      ;;--------------------------------------------------------------
      (let ((face (check-face face))
            (spec-type (if (pair? args) (car args) 'face-override-spec)))
        (cond
         ((eq? spec-type 'face-defface-spec)
          (*face-specs* (cons (cons face spec) (*face-specs*))))
         ((eq? spec-type 'face-override-spec)
          (*face-override-specs* (cons (cons face spec) (*face-override-specs*))))
         ((eq? spec-type 'reset)
          (*face-override-specs* (cons (cons face #f) (*face-override-specs*))))
         (else #f))
        (make-face face)
        (face-spec-recalc face)
        face))

    (define (custom-declare-face face spec docstring)
      ;; GNU Emacs's `custom-declare-face' (`cus-face.el:32'), which
      ;; `defface' expands into: define the face, record its defface spec
      ;; and its documentation, and realize it.
      ;;
      ;; **"Realize" means against a *frame*, and a `defface' the
      ;; libraries run while they load has none yet.** `face-spec-set'
      ;; ends `(dolist (frame (frame-list)) (face-spec-recalc face
      ;; frame))', and this library is loaded before any front end opens
      ;; a display - where Emacs is never in that position, because
      ;; `faces.el' is loaded during the dump and the first frame exists
      ;; before any user-visible `defface' runs. `face-spec-reset-face'
      ;; is the one place that matters, since its `default' branch pins
      ;; a *terminal frame's* stock values (`:height 1' among them); it
      ;; asks `(current-display)' - "is there a frame at all?" - and
      ;; leaves the face unspecified when the answer is no. The frames'
      ;; own initialization recalcs every face when the display opens
      ;; (`initialize-pgtk-faces!', `initialize-display-faces!'), which
      ;; is what a real `frame-list' would have pointed at.
      ;;--------------------------------------------------------------
      (make-face face)
      (*face-specs* (cons (cons face spec) (*face-specs*)))
      (*face-documentation* (cons (cons face docstring) (*face-documentation*)))
      (face-spec-recalc face)
      face)

    (define (defface face spec docstring)
      ;; GNU Emacs's `defface'. Emacs's is a macro, because the spec is
      ;; quoted Elisp that has to survive compilation; a spec here is
      ;; already data, so this is the function the macro expands to.
      ;;--------------------------------------------------------------
      (custom-declare-face face spec docstring))

    ;;----------------------------------------------------------------
    ;; The standard faces
    ;;
    ;; Taken from GNU Emacs's `faces.el' (and `isearch.el' for the two
    ;; search faces) and converted, rather than retyped, so that the
    ;; specs are the ones Emacs ships - including the `(min-colors 88)'
    ;; and `(background light/dark)' branches that a small or
    ;; monochrome terminal falls through to the `(t ...)' branch of.

    (defface 'default
          '((#t #f))
          "Basic default face.")

    (defface 'bold
          '((#t :weight bold))
          "Basic bold face.")

    (defface 'italic
          '((((supports :slant italic)) :slant italic) (((supports :underline #t)) :underline #t :slant italic) (#t :slant italic))
          "Basic italic face.")

    (defface 'underline
          '((((supports :underline #t)) :underline #t) (((supports :weight bold :underline #t)) :weight bold) (#t :underline #t))
          "Basic underlined face.")

    (defface 'mode-line-active
          '((#t :inherit mode-line))
          "Face for the selected mode line.
This inherits from the `mode-line` face.")

    (defface 'mode-line-buffer-id
          '((#t (:weight bold)))
          "Face used for buffer identification parts of the mode line.")

    (defface 'mode-line
          '((((class color grayscale) (min-colors 88) (background light)) :box (:line-width -1 :style released-button) :background "grey75" :foreground "black") (((class color grayscale) (min-colors 88) (background dark)) :box (:line-width -1 :style released-button) :background "grey20" :foreground "white") (#t :inverse-video #t))
          "Face for the mode lines as well as header lines.
    See `mode-line-active' and `mode-line-inactive' for the faces
    used on mode lines.")

    (defface 'mode-line-inactive
          '((default :inherit mode-line) (((class color grayscale) (min-colors 88) (background light)) :weight light :box (:line-width -1 :color "grey75" :style #f) :foreground "grey20" :background "grey90") (((class color grayscale) (min-colors 88) (background dark)) :weight light :box (:line-width -1 :color "grey40" :style #f) :foreground "grey80" :background "grey30"))
          "Basic mode line face for non-selected windows.")

    (defface 'vertical-border
          '((((type tty)) :inherit mode-line-inactive))
          "Face used for vertical window dividers on ttys.")

    (defface 'header-line
          '((default :inherit mode-line) (((type tty)) :inverse-video #f :underline #t) (((class color grayscale) (background light)) :background "grey90" :foreground "grey20" :box #f) (((class color grayscale) (background dark)) :background "grey20" :foreground "grey90" :box #f) (((class mono) (background light)) :background "white" :foreground "black" :inverse-video #f :box #f :underline #t) (((class mono) (background dark)) :background "black" :foreground "white" :inverse-video #f :box #f :underline #t))
          "Basic header-line face.")

    (defface 'region
          '((((class color) (min-colors 88) (background dark)) :background "blue3" :extend #t) (((class color) (min-colors 88) (background light)) :background "lightgoldenrod2" :extend #t) (((class color) (min-colors 16) (background dark)) :background "blue3" :extend #t) (((class color) (min-colors 16) (background light)) :background "lightgoldenrod2" :extend #t) (((class color) (min-colors 8)) :background "blue" :foreground "white" :extend #t) (((type tty) (class mono)) :inverse-video #t) (#t :background "gray" :extend #t))
          "Basic face for highlighting the region.")

    ;;--------------------------------------------------------------
    ;; The TTY face and the three the terminal's menus are drawn with
    ;; (`faces.el:3035`, `:3130`). **Emacs 31's `menu` face has an
    ;; empty `x-toolkit` branch** - a GUI's menu bar is the toolkit's -
    ;; and the three `tty-menu-*` faces are what `tty_menu_activate`
    ;; looks up (`term.c:3635`). They were missing here because there
    ;; was no terminal menu to draw; `term.scm`'s menu now draws with
    ;; them.
    ;;--------------------------------------------------------------
    (defface 'menu
          '((((type tty)) :inverse-video #t) (((type x-toolkit))) (#t :inverse-video #t))
          "Basic face for the font and colors of the menu bar and popup menus.")

    (defface 'tty-menu-enabled-face
          '((((class color)) :foreground "yellow" :background "blue" :weight #t) (#t :weight #t))
          "Face for displaying enabled items in TTY menus.")

    (defface 'tty-menu-disabled-face
          '((((class color) (min-colors 16)) :foreground "lightgray" :background "blue") (((class color)) :foreground "white" :background "blue") (#t :inherit shadow))
          "Face for displaying disabled items in TTY menus.")

    (defface 'tty-menu-selected-face
          '((((class color)) :background "red") (#t :inverse-video #t))
          "Face for displaying the currently selected item in TTY menus.")

    (defface 'highlight
          '((((class color) (min-colors 88) (background light)) :background "darkseagreen2") (((class color) (min-colors 88) (background dark)) :background "darkolivegreen") (((class color) (min-colors 16) (background light)) :background "darkseagreen2") (((class color) (min-colors 16) (background dark)) :background "darkolivegreen") (((class color) (min-colors 8)) :background "green" :foreground "black") (#t :inverse-video #t))
          "Basic face for highlighting.")

    (defface 'cursor
          '((((background light)) :background "black") (((background dark)) :background "white"))
          "Basic face for the cursor color under X.
Currently, only the `:background` attribute is meaningful; all
other attributes are ignored.  The cursor foreground color is
taken from the background color of the underlying text.

Note: Other faces cannot inherit from the cursor face.")

    (defface 'mouse '((#t #f))
          "Basic face for the mouse color under X.")

    (defface 'minibuffer-prompt
          '((((background dark)) :foreground "cyan") (((type pc)) :foreground "magenta") (#t :foreground "medium blue"))
          "Face for minibuffer prompts.
    By default, Emacs automatically adds this face to the value of
    `minibuffer-prompt-properties', which is a list of text properties
    used to display the prompt text.")

    (defface 'error
          '((default :weight bold) (((class color) (min-colors 88) (background light)) :foreground "Red1") (((class color) (min-colors 88) (background dark)) :foreground "Pink") (((class color) (min-colors 16) (background light)) :foreground "Red1") (((class color) (min-colors 16) (background dark)) :foreground "Pink") (((class color) (min-colors 8)) :foreground "red") (#t :inverse-video #t))
          "Basic face used to highlight errors and to denote failure.")

    (defface 'warning
          '((default :weight bold) (((class color) (min-colors 16)) :foreground "DarkOrange") (((class color)) :foreground "yellow"))
          "Basic face used to highlight warnings.")

    (defface 'success
          '((default :weight bold) (((class color) (min-colors 16) (background light)) :foreground "ForestGreen") (((class color) (min-colors 88) (background dark)) :foreground "Green1") (((class color) (min-colors 16) (background dark)) :foreground "Green") (((class color)) :foreground "green"))
          "Basic face used to indicate successful operation.")

    (defface 'shadow
          '((((class color grayscale) (min-colors 88) (background light)) :foreground "grey50") (((class color grayscale) (min-colors 88) (background dark)) :foreground "grey70") (((class color) (min-colors 8) (background light)) :foreground "green") (((class color) (min-colors 8) (background dark)) :foreground "yellow"))
          "Basic face for shadowed text.")

    (defface 'link
          '((((class color) (min-colors 88) (background light)) :foreground "RoyalBlue3" :underline #t) (((class color) (background light)) :foreground "blue" :underline #t) (((class color) (min-colors 88) (background dark)) :foreground "cyan1" :underline #t) (((class color) (background dark)) :foreground "cyan" :underline #t) (#t :inherit underline))
          "Basic face for unvisited links.")

    (defface 'trailing-whitespace
          '((((class color) (background light)) :background "red1") (((class color) (background dark)) :background "red1") (#t :inverse-video #t))
          "Basic face for highlighting trailing whitespace.")

    (defface 'show-paren-match
          '((((class color) (background light)) :background "turquoise") (((class color) (background dark)) :background "steelblue3") (((background dark) (min-colors 4)) :background "grey50") (((background light) (min-colors 4)) :background "gray") (#t :inherit underline))
          "Face used for a matching paren.")

    (defface 'isearch
          '((((class color) (min-colors 88) (background light)) (:background "magenta3" :foreground "lightskyblue1")) (((class color) (min-colors 88) (background dark)) (:background "palevioletred2" :foreground "brown4")) (((class color) (min-colors 16)) (:background "magenta4" :foreground "cyan1")) (((class color) (min-colors 8)) (:background "magenta4" :foreground "cyan1")) (#t (:inverse-video #t)))
          "Face for highlighting Isearch matches.")

    (defface 'lazy-highlight
          '((((class color) (min-colors 88) (background light)) (:background "paleturquoise" :distant-foreground "black")) (((class color) (min-colors 88) (background dark)) (:background "paleturquoise4" :distant-foreground "white")) (((class color) (min-colors 16)) (:background "turquoise3" :distant-foreground "white")) (((class color) (min-colors 8)) (:background "turquoise3" :distant-foreground "white")) (#t (:underline #t)))
          "Face for lazy highlighting of matches other than the current one.
    Used in Isearch when `isearch-lazy-highlight' is non-nil,
    and in `query-replace' when `query-replace-lazy-highlight' is non-nil.")

    (defface 'completions-first-difference
          '((#t (:inherit bold)))
          "Face for the first character after point in completions.
    See also the face `completions-common-part'.")
    (defface 'completions-highlight
          '((#t (:inherit highlight)))
          "Default face for highlighting the current completion candidate.")
    (defface 'completions-common-part
          '((((class color) (min-colors 16) (background light)) :foreground "blue3") (((class color) (min-colors 16) (background dark)) :foreground "lightblue"))
          "Face for the parts of completions which matched the pattern.
    See also the face `completions-first-difference'.")

    ))
