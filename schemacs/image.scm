(define-library (schemacs image)
  ;; This library mirrors the parts of GNU Emacs's `lisp/image.el' that
  ;; the tool bar stands on: `find-image`, the spec search behind it,
  ;; and the type predicates a caller asks before using a spec.
  ;;
  ;; **What is not here, and why.** `image.el' is mostly a *display*
  ;; library: `create-image' records an image, `image-size' measures it,
  ;; and the redisplay draws it through `image.c'. This tree's images
  ;; are drawn by the toolkit - a `GtkImage` built by the Gtk front end
  ;; from the file a spec names (`pgtk.scm') - so there is no image
  ;; object to record and no `image.c' to port. What is carried is the
  ;; *choosing*: which of a list of specs this display can use.
  ;;
  ;; Named departures, each at the function it belongs to: an image is
  ;; a plain spec list rather than an opaque `image' struct with an id;
  ;; `image-mask-p' cannot answer (nothing loads the bitmap here, and
  ;; the toolkit's pixbuf carries its own alpha); `:data' images and the
  ;; `:scale'/`:rotation' transform properties are not carried; and a
  ;; relative `:file' is searched in the directories `image-load-path'
  ;; names, not in `load-path' as well.

  (import
   (only (schemacs custom) define-custom)
   (scheme base)
   (only (guile) %load-path string-rindex
         make-hash-table hash-ref hash-set!)
   ;; The file-name search and the predicates that answer "is there a
   ;; file here": `lread.c`'s `locate-file-internal` and `fileio.c`'s.
   (only (schemacs fileio)
         locate-file-internal file-exists-p file-readable-p)
   ;; `plist-get', `plist-put' and `copy-sequence` are `fns.c`'s.
   (only (schemacs fns) plist-get plist-put copy-sequence)
   ;; `display-graphic-p` is `frame.el`'s, and `display-images-p` is
   ;; defined here beside what it asks (see the note on it).
   (only (schemacs frame) display-graphic-p)
   ;; `tool-bar--image-expression` builds a form whose tests are these
   ;; three; it is here because both `tool-bar.scm` and `isearch.scm`
   ;; need it and `tool-bar.scm` imports `isearch.scm` (its Search
   ;; button names `isearch-forward`), so `isearch.scm` cannot import
   ;; `tool-bar.scm` - see the function's note.
   (only (schemacs faces)
         face-attribute display-color-p *display-color-cells*))

  (export
   find-image image-search-load-path image-property
   image-type image-type-available-p image-mask-p
   create-image display-images-p
   *image-load-path* find-image--cache
   tool-bar--image-expression)

  (begin

    ;;----------------------------------------------------------------
    ;; Where image files are searched - `image.el:122`
    ;;----------------------------------------------------------------

    (define (%initial-image-load-path)
      ;; `image-load-path`'s value: "a list of locations in which to
      ;; search for image files."
      ;;
      ;; GNU Emacs's default is `(list (file-name-as-directory
      ;; (expand-file-name "images" data-directory)) 'data-directory
      ;; 'load-path)' - its install directory's `images', then those two
      ;; variables by name. This tree has no `data-directory`; its
      ;; images ship beside its libraries at `schemacs/etc/images`,
      ;; which is found on the load path exactly as `splash.txt` is
      ;; (`startup.scm`), and that one directory is the whole list.
      ;;--------------------------------------------------------------
      (let ((found (locate-file-internal "schemacs/etc/images/open.xpm"
                                          %load-path)))
        (if found
            (list (substring found 0 (+ 1 (string-rindex found #\/))))
            '())))

    (define-custom *image-load-path*
      ;; GNU Emacs's `image-load-path` (a defcustom, and `let`-bound by
      ;; `image-load-path-for-library`, so a parameter here).
      ;;
      ;; An element may be a directory string; Emacs also allows a
      ;; variable symbol whose value is a string or a list. That arm is
      ;; not carried - nothing here writes one, and a Scheme variable
      ;; is not a symbol with a value.
      ;;--------------------------------------------------------------
       (%initial-image-load-path)
      "List of locations in which to search for image files.
The images for icons shown in the tool bar are also looked up
in these locations.

If an element is a string, it defines a directory to search.
If an element is a variable symbol whose value is a string, that
value defines a directory to search.
If an element is a variable symbol whose value is a list, the
value is used as a list of directories to search.

Subdirectories are not automatically included in the search."
      :type '(repeat (choice directory variable)))

    (define (image-search-load-path file . args)
      ;; GNU Emacs's `image-search-load-path` (`image.el:786`): "Search
      ;; for a file in the image load path. ... Return the file name of
      ;; the image, or nil if not found."
      ;;--------------------------------------------------------------
      (let ((path (if (and (pair? args) (car args))
                      (car args)
                      (*image-load-path*))))
        (let loop ((dirs path))
          (cond
           ((null? dirs) #f)
           ((not (string? (car dirs))) (loop (cdr dirs)))
           (else
            (let* ((dir (car dirs))
                   (name (if (string=? dir "")
                             file
                             (string-append
                              (if (char=? (string-ref
                                           dir (- (string-length dir) 1))
                                          #\/)
                                  dir
                                  (string-append dir "/"))
                              file))))
              (if (file-readable-p name) name (loop (cdr dirs)))))))))

    ;;----------------------------------------------------------------
    ;; Image types and availability - `image.el`'s `create-image`
    ;;----------------------------------------------------------------

    (define %image-extensions
      ;; The types this tree's toolkit can load: GdkPixbuf has the XPM
      ;; loader this build's icons need (measured), and the PNG, PNM
      ;; and XBM loaders are part of the library. Anything else gets
      ;; nil from `image-type-available-p`, as Emacs answers for a type
      ;; its build has no support for.
      '(("xpm" . xpm) ("png" . png) ("pbm" . pbm) ("pnm" . pbm)
        ("xbm" . xbm) ("jpg" . jpeg) ("jpeg" . jpeg) ("gif" . gif)))

    (define (image-type file-or-data . args)
      ;; GNU Emacs's `image-type` (`image.el`): the type of an image
      ;; from its TYPE argument, its data's magic, or its file name's
      ;; extension - in that order.
      ;;
      ;; **Only the name's extension is carried.** Nothing here passes
      ;; `:data', and the file is loaded by the toolkit, which does its
      ;; own sniffing; a caller that gives TYPE gets it back.
      ;;--------------------------------------------------------------
      (let ((type (and (pair? args) (car args)))
            (data-p (and (pair? args) (pair? (cdr args)) (cadr args))))
        (or type
            (and (not data-p)
                 (string? file-or-data)
                 (let loop ((table %image-extensions))
                   (cond ((null? table) #f)
                         ((let* ((ext (car (car table)))
                                 (n (string-length ext))
                                 (s (string-length file-or-data)))
                            (and (> s n)
                                 (char=? (string-ref file-or-data
                                                     (- s n 1))
                                         #\.)
                                 (string=? (substring file-or-data
                                                      (- s n) s)
                                           ext)))
                          (cdr (car table)))
                         (else (loop (cdr table)))))))))

    (define (image-type-available-p type)
      ;; GNU Emacs's `image-type-available-p` (`image.el`): "Return t
      ;; if image-type TYPE is supported for displaying images."
      ;;--------------------------------------------------------------
      (and (symbol? type)
           (memq type '(xpm png pbm xbm jpeg gif)) #t))

    (define (image-mask-p spec . args)
      ;; GNU Emacs's `image-mask-p` (`image.c:...`): "Return t if image
      ;; SPEC has a mask bitmap."
      ;;
      ;; **Not carried, and the answer is nil.** Emacs asks the image
      ;; machinery that loaded the bitmap. Nothing loads a bitmap here -
      ;; the file is handed to a `GtkImage` when the button is made -
      ;; and the toolkit's pixbuf keeps the XPM's transparency itself.
      ;; `tool-bar-make-keymap-1` reads the nil as "mask unknown" and
      ;; adds `:mask heuristic`, which is Emacs's own answer for an
      ;; image whose mask it has not computed.
      ;;--------------------------------------------------------------
      #f)

    (define (create-image file-or-data . args)
      ;; GNU Emacs's `create-image` (`image.el:500`): "Create an image
      ;; from FILE-OR-DATA."
      ;;
      ;; The answer is the `(image :type TYPE :file FILE ...)` spec, not
      ;; an image id: that spec is what `find-image`'s callers read
      ;; (`plist-get ... :file`), and it is what the Gtk front end turns
      ;; into a widget. `:scale` and `:transform-smoothing` are not
      ;; added - nothing here rescales, and the toolkit draws at the
      ;; bitmap's own size.
      ;;--------------------------------------------------------------
      (let ((type (and (pair? args) (car args)))
            (data-p (and (pair? args) (pair? (cdr args)) (cadr args)))
            (props (if (and (pair? args) (pair? (cdr args)))
                       (cddr args)
                       '())))
        (let ((type (image-type file-or-data type data-p)))
          (and type
               (image-type-available-p type)
               (append (list 'image ':type type
                             (if data-p ':data ':file) file-or-data)
                       props)))))

    ;;----------------------------------------------------------------
    ;; find-image - `image.el:813`
    ;;----------------------------------------------------------------

    (define (image-property image property)
      ;; GNU Emacs's `image-property` (`image.el:606`): "Return the value
      ;; of PROPERTY in IMAGE." The image's plist begins *after* the
      ;; leading `image` symbol - Emacs's arm is literally `(plist-get
      ;; (cdr image) property)` - so `plist-get` on the whole list reads
      ;; the symbol as a property name and every lookup is off by one.
      ;;--------------------------------------------------------------
      (plist-get (cdr image) property))

    (define find-image--cache (make-hash-table))

    (define (%spec-props-without spec drop)
      ;; SPEC without the plist entries named in DROP - Emacs's
      ;; `(setf (image-property image :type) nil)` pair, which is what
      ;; the spec passed on to `create-image` must not carry twice.
      ;;--------------------------------------------------------------
      (let loop ((rest spec) (out '()))
        (cond ((or (null? rest) (null? (cdr rest))) (reverse out))
              ((memq (car rest) drop) (loop (cddr rest) out))
              (else (loop (cddr rest)
                          (cons (cdr rest) (cons (car rest) out)))))))

    (define (find-image specs . args)
      ;; GNU Emacs's `find-image` (`image.el:813`): "Find an image that
      ;; satisfies one of a list of image specifications. ... The
      ;; function returns the image specification for the first
      ;; specification in the list whose TYPE is supported and FILE, if
      ;; specified, exists."
      ;;
      ;; CACHE is Emacs's second argument: "results are cached and
      ;; returned on subsequent calls" - and `tool-bar-make-keymap-1`
      ;; passes t for it, so a redisplay does not stat every icon again.
      ;;--------------------------------------------------------------
      (let ((cache (and (pair? args) (car args))))
        (or (and cache (hash-ref find-image--cache specs))
            (let loop ((rest specs))
              (if (null? rest)
                  (begin
                    (when cache (hash-set! find-image--cache specs #f))
                    #f)
                  (let* ((spec (car rest))
                         (type (plist-get spec ':type))
                         (file (plist-get spec ':file)))
                    (if (not (string? file))
                        ;; `:data' images are not carried - see the
                        ;; library header - so a spec with neither a
                        ;; readable file nor a type this build has is
                        ;; unsatisfied.
                        (loop (cdr rest))
                        (let ((found (image-search-load-path file)))
                          (if (not found)
                              (loop (cdr rest))
                              (let ((image
                                     (guard (e (else #f))
                                       (apply create-image found #f #f
                                              (%spec-props-without
                                               spec '(:type :file))))))
                                (if (and image
                                         (or (not type)
                                             (eq? type (image-property
                                                        image ':type))))
                                    (begin
                                      (when cache
                                        (hash-set! find-image--cache specs
                                                   image))
                                      image)
                                    (loop (cdr rest)))))))))))))

    (define (display-images-p . args)
      ;; GNU Emacs's `display-images-p` (`frame.el:2717`): "Return
      ;; non-nil if DISPLAY can display images." The C is
      ;; `(and (display-graphic-p display) (fboundp 'image-mask-p)
      ;; (fboundp 'image-size))' - the second half asks whether image.el
      ;; is loaded.
      ;;
      ;; **A placement departure**: `frame.el` is its home, but this
      ;; library is what holds the image functions the question is
      ;; about, and `frame.scm` is below it. Here the answer is the
      ;; display's: a window-system display can show images (the Gtk
      ;; front end draws a `GtkImage`), and a terminal cannot.
      ;;--------------------------------------------------------------
      (apply display-graphic-p args))

    (define (tool-bar--image-expression icon)
      ;; GNU Emacs's `tool-bar--image-expression` (`tool-bar.el:236`):
      ;; "Return an expression that evaluates to an image spec for
      ;; ICON."
      ;;
      ;; **Placement departure**: `tool-bar.el` is its home, but
      ;; `isearch.el` uses it for `isearch-tool-bar-image`, and
      ;; `tool-bar.scm` imports `isearch.scm` (its Search button names
      ;; `isearch-forward`) - so an import in the other direction would
      ;; be a cycle. It is here, in the library that is about images,
      ;; below both; `tool-bar.scm` imports it from here.
      ;;
      ;; The expression is a *form* - `(find-image (cond ...) t)` -
      ;; because which of the file variants can be used is a fact about
      ;; the display at the time the bar is built, not about the time
      ;; the item was defined. The `cond` is part of the form for that
      ;; reason; its tests are this tree's spelling of
      ;; `display-color-p`/`display-color-cells`.
      ;;--------------------------------------------------------------
      (let* ((fg (face-attribute 'tool-bar ':foreground))
             (bg (face-attribute 'tool-bar ':background))
             (colors (append (if (eq? fg 'unspecified)
                                 '()
                                 (list ':foreground fg))
                             (if (eq? bg 'unspecified)
                                 '()
                                 (list ':background bg))))
             (xpm-spec (list ':type 'xpm ':file (string-append icon ".xpm")))
             (xpm-lo-spec (list ':type 'xpm ':file
                                (string-append "low-color/" icon ".xpm")))
             (pbm-spec (append (list ':type 'pbm ':file
                                     (string-append icon ".pbm"))
                               colors))
             (xbm-spec (append (list ':type 'xbm ':file
                                     (string-append icon ".xbm"))
                               colors)))
        (list 'find-image
              (list 'cond
                    (list (list 'not (list 'display-color-p))
                          (list 'quote (list pbm-spec xbm-spec
                                             xpm-lo-spec xpm-spec)))
                    (list (list '< (list '*display-color-cells*) 256)
                          (list 'quote (list xpm-lo-spec xpm-spec
                                             pbm-spec xbm-spec)))
                    (list 'else
                          (list 'quote (list xpm-spec pbm-spec xbm-spec))))
              #t))))
)
