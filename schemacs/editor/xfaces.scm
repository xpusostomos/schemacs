(define-library (schemacs editor xfaces)
  ;; This library mirrors GNU Emacs's `xfaces.c`: the layer between the
  ;; faces `(schemacs editor faces)' describes and the pixels - or, here,
  ;; the terminal cells - they are drawn in.
  ;;
  ;; It does two things, and both are needed before anything can be drawn
  ;; with a face:
  ;;
  ;;   1. **Merging.** A face reaches text as the `face' property, which
  ;;      may name one face, give a property list, or list several faces.
  ;;      Turning that into one set of attributes is
  ;;      `merge_face_vectors' / `merge_face_ref', and the `:inherit'
  ;;      recursion in them is the part that matters: `faces.el''s
  ;;      `face-attribute' resolves `:inherit' only for attributes that
  ;;      are *relative*, so it is not the function a display can use.
  ;;   2. **Folding down.** A terminal can draw bold, italic, underline,
  ;;      strike-through, overline, inverse-video and two colours, and
  ;;      nothing else. `realize_tty_face' drops everything else - family,
  ;;      foundry, width, height, box, stipple - so that two faces
  ;;      differing only in their font are *one* face on a terminal. That
  ;;      is why the standard specs are written with `(min-colors N)'
  ;;      branches: the display's capabilities decide which branch is
  ;;      chosen, and the fold-down decides what is left of it.
  ;;
  ;; Not ported, with what each would need: the colour tables Emacs builds
  ;; from terminfo when the terminal is opened (`init_tty') and the
  ;; approximation it falls back on (`tty-color-approximate') - what is
  ;; here is the ANSI names, which is what a text terminal has;
  ;; `face_at_buffer_position' and the face cache (`lookup_face'), which
  ;; belong to the display (`xdisp.c') and are step D; and the X and
  ;; window-system half of the file, which has no meaning here.
  ;;
  ;; See FACES-PLAN.txt for the plan this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editor faces)
          *face-attributes* *undefined-face-attribute*)
    ;; The buffer's own `face-remapping-alist' - a buffer-local variable,
    ;; so its reader is the buffer's slot table (`buffer.c'). It is a
    ;; leaf below this library, which is what lets it be read here.
    (only (schemacs editor buffer) current-buffer buffer-local-value)
    ;; What a colour *name* means on this terminal - which is not its own
    ;; business, and lives where Emacs has it, in `tty-colors.el'.
    (only (schemacs editor tty-colors) tty-color-translate)
    ;; `(inexact->exact (truncate ...))' for a resolved relative height.
    (only (guile) inexact->exact))

  (export
   attribute-value
   attributes-set
   face-attributes-empty
   face-realized-attributes
   merge-face-ref
   merge-face-vectors
   map-tty-color
   realize-tty-face
   tty-capable-p
   tty-slant-number
   tty-weight-number
   *face-attribute-names*
   *tty-slant-table*
   *tty-weight-table*
   )

  (begin


    ;;----------------------------------------------------------------
    ;; Merging faces

    (define *face-attribute-names*
      ;; The attributes, in the order Emacs's `LFACE_*_INDEX' puts them.
      ;; The order matters because a merge walks them in it, so that an
      ;; earlier attribute cannot be overwritten by a later one from the
      ;; same face.
      ;;--------------------------------------------------------------
      '(:family :foundry :width :height :weight :slant :underline
                :overline :extend :strike-through :box :inverse-video
                :foreground :background :stipple :inherit))

    (define (face-realized-attributes face)
      ;; The attributes a face has been given, as a plist, or the empty
      ;; list when it has none. This is Emacs's `lface', the vector
      ;; `merge_face_vectors' works on.
      ;;--------------------------------------------------------------
      (let ((entry (assq face (*face-attributes*)))) (if entry (cdr entry) '())))

    (define (face-attributes-empty)
      ;; A set of attributes with nothing specified - the vector
      ;; `merge_face_vectors' starts from.
      ;;--------------------------------------------------------------
      '())

    (define (attribute-value attrs attribute)
      ;; ATTRIBUTE's value in ATTRS, or `unspecified' when absent.
      ;;--------------------------------------------------------------
      (let loop ((rest attrs))
        (cond ((not (and (pair? rest) (pair? (cdr rest))))
               *undefined-face-attribute*)
              ((eq? (car rest) attribute) (cadr rest))
              (else (loop (cddr rest))))))

    (define (attributes-set attrs attribute value)
      ;; ATTRS with ATTRIBUTE set to VALUE.
      ;;--------------------------------------------------------------
      (let loop ((rest attrs) (acc '()) (found #f))
        (cond
         ((not (and (pair? rest) (pair? (cdr rest))))
          (if found (reverse acc) (cons attribute (cons value attrs))))
         ((eq? (car rest) attribute)
          (loop (cddr rest) (cons value (cons attribute acc)) #t))
         (else (loop (cddr rest) (cons (cadr rest) (cons (car rest) acc)) found)))))

    (define (merge-face-vectors from to)
      ;; GNU Emacs's `merge_face_vectors': merge FROM's attributes into
      ;; TO, answering the merged set.
      ;;
      ;; FROM's `:inherit' is merged *first*, so that a face's own
      ;; attributes override what it inherits from - and that recursion is
      ;; the whole point of the function, because `faces.el''s
      ;; `face-attribute' does not do it for attributes that are not
      ;; relative. This is the function the display reads faces with.
      ;;--------------------------------------------------------------
      (let* ((inherit (attribute-value from ':inherit))
             (to (if (and (not (eq? inherit *undefined-face-attribute*))
                          inherit)
                     (merge-face-ref inherit to)
                     to)))
        (let loop ((names *face-attribute-names*) (to to))
          (cond
           ((null? names) to)
           (else
            (let ((value (attribute-value from (car names))))
              (loop (cdr names)
                    (cond
                     ((eq? value *undefined-face-attribute*) to)
                     ((eq? (car names) ':height)
                      ;; A relative height scales what it merges into, and
                      ;; the answer is ABSOLUTE - Emacs's
                      ;; `merge_face_heights' (`xfaces.c:2253') makes a
                      ;; fixnum of "relative X absolute". Leaving the
                      ;; product a flonum makes it look *relative* to
                      ;; whoever reads it next, and the renderer then
                      ;; scales it again.
                      (let ((was (attribute-value to ':height)))
                        (attributes-set
                         to ':height
                         (if (and (real? value) (inexact? value) (real? was)
                                  (not (eq? was *undefined-face-attribute*)))
                             (inexact->exact (truncate (* value was)))
                             value))))
                     (else (attributes-set to (car names) value))))))))))

    (define (face-remapping-alist)
      ;; GNU Emacs's `Vface_remapping_alist' (`xfaces.c:2141'), which is
      ;; buffer-local wherever a remapping mode has set it: an alist of
      ;; `(FACE SPEC ...)', where the specs are what FACE is *drawn* as in
      ;; this buffer.
      ;;
      ;; Read through the buffer's own slots, which is where a
      ;; buffer-local variable lives here, and with `()' when there is no
      ;; current buffer - Emacs's global value.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if buffer
            (buffer-local-value buffer 'face-remapping-alist '())
            '())))

    (define (merge-face-ref face-ref to . args)
      ;; GNU Emacs's `merge_face_ref': merge a *reference* to a face or
      ;; faces - what the `face' text property holds - into TO.
      ;;
      ;; A reference may be a face name, a property list of attributes,
      ;; or a list of either.
      ;;
      ;; **A list is merged from the END backwards**, which is Emacs's
      ;; own rule and the opposite of reading order: "This is a list of
      ;; face refs.  Those at the beginning of the list take precedence
      ;; over what follows, so we have to merge from the end backwards"
      ;; (`xfaces.c:2989'). So a list whose first element is
      ;; `(:weight italic)' and whose last is `bold' comes out *italic* -
      ;; the first element wins - and a remapping's relative `:height`,
      ;; which `face-remap-add-relative' puts first, survives the base
      ;; face that follows it. Merging forwards instead is what made
      ;; `text-scale-mode' do nothing: the base face's absolute height
      ;; overwrote the scale.
      ;;
      ;; **A face name goes through the buffer's remapping first**, and a
      ;; remapped face is answered *entirely* by its remapping - that is
      ;; Emacs's `get_lface_attributes' (`xfaces.c:2124'), which resets
      ;; the attribute vector before merging the mapping, so a
      ;; buffer-local adjustment overrides the global face rather than
      ;; adding to it.
      ;;
      ;; **ARGS carries the faces being remapped right now**, which is
      ;; Emacs's `named_merge_points' (`push_named_merge_point',
      ;; `xfaces.c:2100'). A remapping's base spec is usually the face
      ;; itself - `face-remap-add-relative' writes `(FACE SPEC ... FACE)'
      ;; - so without the guard reading a remapped face recurses for
      ;; ever. Emacs's answer when the face is already on the chain is
      ;; `get_lface_attributes_no_remap': its global definition.
      ;;
      ;; This is the second argument the tree's rule sanctions: Emacs
      ;; threads `named_merge_points' through the call, and a dynamic
      ;; binding here would be exactly what the rule forbids.
      ;;--------------------------------------------------------------
      (let ((pending (if (pair? args) (car args) '())))
        (cond
         ((not face-ref) to)
         ((symbol? face-ref)
          (let ((remapping (and (not (memq face-ref pending))
                                (assq face-ref (face-remapping-alist)))))
            (if remapping
                (merge-face-ref (cdr remapping) (face-attributes-empty)
                                (cons face-ref pending))
                (merge-face-vectors (face-realized-attributes face-ref) to))))
         ((pair? face-ref)
          (if (keyword? (car face-ref))
              ;; The property-list form: the attributes themselves.
              (merge-face-vectors face-ref to)
              ;; Or a list of references, merged backwards so that the
              ;; first one is merged last and therefore wins.
              (let loop ((rest (reverse face-ref)) (to to))
                (if (null? rest)
                    to
                    (loop (cdr rest)
                          (merge-face-ref (car rest) to pending))))))
         (else to))))

    (define (keyword? x)
      ;; A face attribute name: a symbol whose name starts with a colon.
      ;;--------------------------------------------------------------
      (and (symbol? x)
           (let ((name (symbol->string x)))
             (and (> (string-length name) 0)
                  (char=? (string-ref name 0) #\:)))))

    ;;----------------------------------------------------------------
    ;; Folding a face down onto what a terminal can show

    (define *tty-weight-table*
      ;; GNU Emacs's `font-weight-table': a weight name and its numeric
      ;; value. `realize_tty_face' asks whether the weight is *greater
      ;; than 100* - normal - and bold is 200, so a face that inherits
      ;; `bold' or asks for a heavier weight is drawn bold and one that
      ;; asks for `light' is not.
      ;;--------------------------------------------------------------
      '((thin . 0) (ultra-light . 20) (extra-light . 40) (light . 50)
        (semi-light . 55) (regular . 80) (normal . 80) (medium . 100)
        (semi-bold . 180) (bold . 200) (extra-bold . 205) (ultra-bold . 210)
        (black . 210) (heavy . 210)))

    (define *tty-slant-table*
      ;; GNU Emacs's `font-slant-table'. `realize_tty_face' asks whether
      ;; the slant is anything but 100 - `normal' - so both `italic' and
      ;; `oblique' come out italic on a terminal.
      ;;--------------------------------------------------------------
      '((reverse-oblique . 80) (reverse-italic . 90) (normal . 100)
        (italic . 110) (oblique . 110)))

    (define (tty-weight-number weight)
      ;; The numeric weight of a weight name, or 100 for one that is not
      ;; in the table - the same default the C's
      ;; `FONT_WEIGHT_NAME_NUMERIC' macro has.
      ;;--------------------------------------------------------------
      (let ((entry (assq weight *tty-weight-table*)))
        (if entry (cdr entry) 100)))

    (define (tty-slant-number slant)
      ;; The numeric slant of a slant name, or 100.
      ;;--------------------------------------------------------------
      (let ((entry (assq slant *tty-slant-table*)))
        (if entry (cdr entry) 100)))

    (define (map-tty-color name)
      ;; GNU Emacs's `map_tty_color': the index of the terminal colour to
      ;; draw NAME with. Emacs answers with the terminal's own colour when
      ;; it has one by that name and the *nearest* one when it has not -
      ;; and it usually has not, because almost nothing a face spec names
      ;; (`grey75', `magenta4', `lightskyblue1') is an ANSI colour. That
      ;; approximation is `tty-colors'' business: `tty_lookup_color' calls
      ;; `tty-color-desc' and takes the INDEX out of the `(NAME INDEX R G
      ;; B)' it answers, which is `tty-color-translate'.
      ;;--------------------------------------------------------------
      (tty-color-translate name))

    (define (tty-capable-p options)
      ;; GNU Emacs's `tty_capable_p': whether the terminal can show the
      ;; attributes in OPTIONS, a plist. This is the question
      ;; `display-supports-face-attributes-p' asks of the display, and on
      ;; a terminal the answer is the same one - a termcap frame can show
      ;; weight, slant, underline and inverse-video and nothing else.
      ;;--------------------------------------------------------------
      (let loop ((rest options))
        (cond
         ((not (and (pair? rest) (pair? (cdr rest)))) #t)
         ((memq (car rest) '(:weight :slant :underline :inverse-video
                                      :foreground :background :strike-through
                                      :overline))
          (loop (cddr rest)))
         (else #f))))

    (define (realize-tty-face attrs)
      ;; GNU Emacs's `realize_tty_face': fold a set of face attributes
      ;; down onto what a terminal can actually draw, and answer that.
      ;;
      ;; Everything a graphical display would do with a face is dropped
      ;; here: `:family', `:foundry', `:width', `:box', `:stipple' and
      ;; `:height' have no terminal equivalent, so two faces that differ
      ;; only in their font are the *same* face on a terminal. What
      ;; survives is a handful of switches and a pair of colours, which is
      ;; what `term.c' turns into escape sequences.
      ;;--------------------------------------------------------------
      (let ((weight (tty-weight-number (attribute-value attrs ':weight)))
            (slant (tty-slant-number (attribute-value attrs ':slant)))
            (underline (attribute-value attrs ':underline))
            (reverse (attribute-value attrs ':inverse-video))
            (strike (attribute-value attrs ':strike-through))
            (overline (attribute-value attrs ':overline))
            (foreground (attribute-value attrs ':foreground))
            (background (attribute-value attrs ':background)))
        (list ':bold (> weight 100)
              ':italic (not (= slant 100))
              ':reverse (and (not (eq? reverse *undefined-face-attribute*))
                             (and reverse #t))
              ':strike-through (and (not (eq? strike *undefined-face-attribute*))
                                    (and strike #t))
              ':overline (and (not (eq? overline *undefined-face-attribute*))
                              (and overline #t))
              ;; `:underline' is t for a plain underline, a colour name
              ;; for a coloured one, or a plist; all three mean "draw an
              ;; underline" to a terminal.
              ':underline (cond
                           ((eq? underline *undefined-face-attribute*) #f)
                           ((not underline) #f)
                           (else #t))
              ':foreground (if (and (string? foreground)
                                    (not (eq? foreground *undefined-face-attribute*)))
                               (map-tty-color foreground)
                               *undefined-face-attribute*)
              ':background (if (and (string? background)
                                    (not (eq? background *undefined-face-attribute*)))
                               (map-tty-color background)
                               *undefined-face-attribute*))))

    ))
