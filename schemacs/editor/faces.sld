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
    (scheme char))

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
        (let ((value (and entry
                          (let loop ((plist (cdr entry)))
                            (cond ((not (and (pair? plist) (pair? (cdr plist))))
                                   *undefined-face-attribute*)
                                  ((eq? (car plist) attribute) (cadr plist))
                                  (else (loop (cddr plist))))))))
          value)))

    (define (face-attribute-relative-p attribute value)
      ;; The C `face_attribute_relative_p': whether VALUE has to be merged
      ;; with what the face inherits from rather than used as it stands.
      ;; A weight of `light' or `bold' is relative (it means "one step
      ;; from the inherited weight"); a float height is relative; an
      ;; underline that is neither nil nor t is a *colour*; a box that is
      ;; a list carries attributes to merge.
      ;;--------------------------------------------------------------
      (cond
       ((eq? attribute ':weight) (or (eq? value 'light) (eq? value 'bold)))
       ((eq? attribute ':slant) (eq? value 'italic))
       ((eq? attribute ':height) (real? value))
       ((eq? attribute ':underline)
        (and (not (eq? value #f)) (not (eq? value #t))))
       ((eq? attribute ':box) (pair? value))
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
        ;; A float height is a *scale* of what was inherited; an absolute
        ;; one is itself.
        (if (and (real? value1) (inexact? value1) (number? value2))
            (* value1 value2)
            value1))
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
        (merge-face-attribute attribute value
                              (face-attribute faces attribute #f #t)))))

    (define (face-attribute face attribute . args)
      ;; GNU Emacs's `face-attribute': ATTRIBUTE's value on FACE.
      ;;
      ;; With no INHERIT only what FACE itself defines is read, so the
      ;; answer may be `unspecified` or a relative value; with INHERIT the
      ;; value is merged with the faces `:inherit' names, and with
      ;; INHERIT = `default' (or a face) it is merged with that too, until
      ;; it is absolute. That is what makes `(face-attribute F :weight nil
      ;; 'default)' always answer a weight.
      ;;--------------------------------------------------------------
      (let ((inherit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (let* ((value (internal-get-lisp-face-attribute face attribute))
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
      ;;--------------------------------------------------------------
      (make-parameter #f))

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
      (if (eq? display #t)
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
                   (thisval (if (null? (cdr attrs)) (car attrs) attrs)))
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

    (define (set-face-attribute face frame . args)
      ;; GNU Emacs's `set-face-attribute': set attributes of FACE. ARGS is
      ;; the plist, as it is in Elisp; FRAME is accepted and not consulted
      ;; (one frame here - see the header).
      ;;--------------------------------------------------------------
      (let loop ((rest args))
        (cond
         ((not (and (pair? rest) (pair? (cdr rest)))) face)
         (else
          (internal-set-lisp-face-attribute face (car rest) (cadr rest))
          (loop (cddr rest)))))
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
      ;; GNU Emacs's `face-spec-reset-face': every attribute of FACE back
      ;; to unspecified. Emacs makes an exception of `default', which is
      ;; set to the values `realize_default_face' would give it rather
      ;; than to unspecified, because a completely unspecified default
      ;; face leaves nothing to fall back on.
      ;;--------------------------------------------------------------
      (let ((face (check-face face)))
        (let loop ((rest (*face-attributes*)) (acc '()))
          (cond
           ((null? rest) (*face-attributes* (reverse acc)))
           ((eq? (caar rest) face) (loop (cdr rest) (cons (cons face '()) acc)))
           (else (loop (cdr rest) (cons (car rest) acc))))))
      face)

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
      ;; GNU Emacs's `face-spec-recalc': realize FACE again from its
      ;; specs - reset it, then apply the defface spec's chosen branch and
      ;; then the override spec's.
      ;;
      ;; Emacs does this per frame, applies theme specs in between, and
      ;; consults X resources; none of those exist here (one frame, no
      ;; themes, no X), which leaves exactly these three steps.
      ;;--------------------------------------------------------------
      (let ((face (check-face face)))
        (face-spec-reset-face face)
        (face-spec-set-2 face (face-spec-choose (face-defface-spec face)))
        (face-spec-set-2 face (face-spec-choose (face-override-spec face)))
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
      ;; GNU Emacs's `custom-declare-face', which `defface' expands into:
      ;; define the face, record its defface spec and its documentation,
      ;; and realize it.
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

    (defface 'mode-line
          '((((class color grayscale) (min-colors 88) (background light)) :box (:line-width -1 :style released-button) :background "grey75" :foreground "black") (((class color grayscale) (min-colors 88) (background dark)) :box (:line-width -1 :style released-button) :background "grey20" :foreground "white") (#t :inverse-video #t))
          "Face for the mode lines as well as header lines.
    See `mode-line-active' and `mode-line-inactive' for the faces
    used on mode lines.")

    (defface 'mode-line-inactive
          '((default :inherit mode-line) (((class color grayscale) (min-colors 88) (background light)) :weight light :box (:line-width -1 :color "grey75" :style #f) :foreground "grey20" :background "grey90") (((class color grayscale) (min-colors 88) (background dark)) :weight light :box (:line-width -1 :color "grey40" :style #f) :foreground "grey80" :background "grey30"))
          "Basic mode line face for non-selected windows.")

    (defface 'header-line
          '((default :inherit mode-line) (((type tty)) :inverse-video #f :underline #t) (((class color grayscale) (background light)) :background "grey90" :foreground "grey20" :box #f) (((class color grayscale) (background dark)) :background "grey20" :foreground "grey90" :box #f) (((class mono) (background light)) :background "white" :foreground "black" :inverse-video #f :box #f :underline #t) (((class mono) (background dark)) :background "black" :foreground "white" :inverse-video #f :box #f :underline #t))
          "Basic header-line face.")

    (defface 'region
          '((((class color) (min-colors 88) (background dark)) :background "blue3" :extend #t) (((class color) (min-colors 88) (background light)) :background "lightgoldenrod2" :extend #t) (((class color) (min-colors 16) (background dark)) :background "blue3" :extend #t) (((class color) (min-colors 16) (background light)) :background "lightgoldenrod2" :extend #t) (((class color) (min-colors 8)) :background "blue" :foreground "white" :extend #t) (((type tty) (class mono)) :inverse-video #t) (#t :background "gray" :extend #t))
          "Basic face for highlighting the region.")

    (defface 'highlight
          '((((class color) (min-colors 88) (background light)) :background "darkseagreen2") (((class color) (min-colors 88) (background dark)) :background "darkolivegreen") (((class color) (min-colors 16) (background light)) :background "darkseagreen2") (((class color) (min-colors 16) (background dark)) :background "darkolivegreen") (((class color) (min-colors 8)) :background "green" :foreground "black") (#t :inverse-video #t))
          "Basic face for highlighting.")

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
    (defface 'completions-common-part
          '((((class color) (min-colors 16) (background light)) :foreground "blue3") (((class color) (min-colors 16) (background dark)) :foreground "lightblue"))
          "Face for the parts of completions which matched the pattern.
    See also the face `completions-first-difference'.")

    ))
