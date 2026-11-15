(define-library (schemacs editor icons)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/icons.el' - the
  ;; `define-icon' macro and the code that picks a displayable form of an
  ;; icon. It is what `tab-line.el' builds its "new tab", "close tab" and
  ;; scroll buttons with.
  ;;
  ;; **Images are not carried, and that is the one departure.** An icon's
  ;; specification lists the forms it can take in the order the user
  ;; prefers them (`icon-preference': image, emoji, symbol, text), and
  ;; `icons--create' answers a form only if the display can show it. This
  ;; tree has no image support - the Gtk front end draws text, and the
  ;; terminal can only draw text - so the `image' method always answers
  ;; #f and the preference falls through to `symbol' or `text', which is
  ;; exactly what Emacs does on a text terminal. The `emoji' method asks
  ;; `display-multi-font-p' and `internal-char-font', neither of which
  ;; exists here, so it answers #f too and `symbol' is where a terminal
  ;; lands in Emacs as well.
  ;;
  ;; The icon registry is a symbol property (`icon--properties'), as the C
  ;; keeps it in `put', and `define-icon' evaluates its SPECIFICATION once
  ;; at definition time - the C's `',specification' does the same, which
  ;; is why `,(concat " " [#x2022])' inside a backquoted spec works.

  (import
    (scheme base)
    (scheme char)
    ;; `take' is the C's `(take 2 parent-keywords)'; `delete-duplicates'
    ;; is `icons--copy-spec'... no, that is a plain mapcar.
    (only (srfi srfi-1) take)
    (only (schemacs editor custom) define-custom custom-add-to-group
          custom-current-group)
    ;; `propertize` is `editfns.c`'s; `concat` and `string-replace` are
    ;; `fns.c`'s and `subr.el`'s.
    (only (schemacs editor editfns) propertize)
    (only (schemacs editor fns) concat copy-sequence)
    (only (schemacs editor subr) string-replace)
    (only (schemacs editor intervals) get put)
    (only (schemacs editor data) keywordp)
    (only (schemacs editor textprop) get-text-property))

  (export
   define-icon icon-string icon-elements iconp icon-documentation
   icon-complete-spec icon-spec-keywords icon-spec-values
   icons--register icons--spec icons--copy-spec icons--merge-spec
   icons--create *icon-preference*)

  (begin

    (define-custom *icon-preference* '(image emoji symbol text)
      "List of icon types to use, in order of preference.
Emacs will choose the icon of the highest preference possible
on the current display, and \"degrade\" gracefully to an icon
type that's available."
      :type '(repeat (choice (const :tag "Images" image)
                             (const :tag "Colorful Emojis" emoji)
                             (const :tag "Monochrome Symbols" symbol)
                             (const :tag "Text Only" text))))

    (define-syntax define-icon
      ;; GNU Emacs's `define-icon' (`icons.el:57'): "Define an icon
      ;; identified by NAME. ... SPECIFICATION is an alist of entries
      ;; where the first element is the type, and the rest are icons of
      ;; that type. Valid types are `image', `emoji', `symbol' and
      ;; `text'."
      ;;
      ;; The C checks `symbolp' on NAME and insists on a `:version'
      ;; keyword, then expands to `(icons--register ',name ',parent
      ;; ,specification ,documentation ',keywords)' - so SPECIFICATION
      ;; is *evaluated* at definition time and the result quoted. The
      ;; same here: the specification is an ordinary Scheme expression,
      ;; which is what makes `,(concat ...)' in a backquoted spec work.
      ;;
      ;; The keywords are 2n arguments - `:version' and its value, and
      ;; so on - and they are read as *data*, the way `define-custom'
      ;; reads `:type'. **Quoting the whole list is what makes that
      ;; work**: written as `(list (quote keyword) value ...)' each
      ;; value is an *expression*, so a keyword value that is itself a
      ;; symbol - `:help-echo' in a two-pair list - was evaluated and
      ;; reported unbound.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ name parent specification documentation keyword value ...)
         (begin
           (if (not (symbol? (quote name)))
               (error "NAME must be a symbol: ~a" (quote name)))
           (icons--register (quote name) (quote parent)
                            specification documentation
                            (quote (keyword value ...)))))))

    (define (icons--register name parent spec doc keywords)
      ;; GNU Emacs's `icons--register' (`icons.el:84').
      ;;--------------------------------------------------------------
      (put name 'icon--properties (list parent spec doc keywords))
      (custom-add-to-group
       (or (plist-get-keyword keywords ':group)
           (custom-current-group))
       name 'custom-icon))

    (define (plist-get-keyword plist key)
      ;; `(plist-get PLIST KEY)' over a list of alternating keywords and
      ;; values. `plist-get' itself lives above this library, and this is
      ;; its whole body for a list that starts with a keyword.
      ;;--------------------------------------------------------------
      (cond ((not (pair? plist)) #f)
            ((eq? (car plist) key) (and (pair? (cdr plist)) (cadr plist)))
            (else (plist-get-keyword (cddr plist) key))))

    (define (icon-spec-keywords spec)
      ;; GNU Emacs's `icon-spec-keywords' (`icons.el:91').
      ;;--------------------------------------------------------------
      (let skip ((rest (cdr spec)))
        (if (or (not (pair? rest)) (keywordp (car rest)))
            rest
            (skip (cdr rest)))))

    (define (icon-spec-values spec)
      ;; GNU Emacs's `icon-spec-values' (`icons.el:94').
      ;;--------------------------------------------------------------
      (let take-while ((rest (cdr spec)) (acc '()))
        (cond ((or (not (pair? rest)) (keywordp (car rest)))
               (reverse acc))
              (else (take-while (cdr rest) (cons (car rest) acc))))))

    (define (iconp object)
      ;; GNU Emacs's `iconp' (`icons.el:97'): "Return nil if OBJECT is
      ;; not an icon. If OBJECT is an icon, return the icon properties."
      ;;--------------------------------------------------------------
      (and (symbol? object) (get object 'icon--properties)))

    (define (icon-documentation icon)
      ;; GNU Emacs's `icon-documentation' (`icons.el:102').
      ;;--------------------------------------------------------------
      (let ((props (iconp icon)))
        (unless props
          (error "~a is not a valid icon" icon))
        (list-ref props 2)))

    (define (icons--spec icon)
      ;; GNU Emacs's `icons--spec' (`icons.el:109').
      ;;--------------------------------------------------------------
      (list-ref (iconp icon) 1))

    (define (icons--copy-spec spec)
      ;; GNU Emacs's `icons--copy-spec' (`icons.el:112'): "We
      ;; destructively modify `spec' when merging, so copy it."
      ;;--------------------------------------------------------------
      (map copy-sequence spec))

    (define (icon-complete-spec icon . args)
      ;; GNU Emacs's `icon-complete-spec' (`icons.el:115'): "Return the
      ;; merged spec for ICON."
      ;;
      ;; The two optional arguments (`inhibit-theme',
      ;; `inhibit-inheritance') are not carried as flags: nothing here
      ;; sets `theme-icon', and the only caller is `icon-string', which
      ;; passes neither.
      ;;--------------------------------------------------------------
      (let ((props (iconp icon)))
        (let ((parent (car props))
              (spec (icons--copy-spec (list-ref props 1))))
          ;; "Let the Customize theme override" - `theme-icon' is
          ;; `custom-theme-set-icons'' property, and no theme here sets
          ;; one; the branch is named rather than carried.
          ;; "Inherit from the parent spec (recursively)."
          (let loop ((parent parent) (spec spec))
            (if (not parent)
                spec
                (let ((parent-props (get parent 'icon--properties)))
                  (loop (and parent-props (car parent-props))
                        (if parent-props
                            (icons--merge-spec spec (list-ref parent-props 1))
                            spec))))))))

    (define (icons--merge-spec merged parent-spec)
      ;; GNU Emacs's `icons--merge-spec' (`icons.el:174').
      ;;
      ;; `(push elem merged)' is a `set!' of the local: nothing outside
      ;; sees the list being built. `(nconc current (take 2
      ;; parent-keywords))' is destructive in the C too - it splices onto
      ;; the section's last pair, which may be the merged list's own.
      ;;--------------------------------------------------------------
      (for-each
       (lambda (elem)
         (let ((current (assq (car elem) merged)))
           (if (not current)
               ;; "Just add the entry."
               (set! merged (cons elem merged))
               ;; "See if there are any keywords to inherit."
               (let ((parent-keywords (icon-spec-keywords elem))
                     (current-keywords (icon-spec-keywords current)))
                 (let loop ((pk parent-keywords))
                   (when (pair? pk)
                     (unless (plist-get-keyword current-keywords (car pk))
                       (set-cdr! (list-tail current
                                            (- (length current) 1))
                                 (take 2 pk)))
                     (loop (cddr pk))))))))
       parent-spec)
      merged)

    (define (icons--create type icon keywords)
      ;; GNU Emacs's `icons--create' (`icons.el:191-236'), the four
      ;; `cl-defmethod's in one dispatch.
      ;;
      ;;   `image' - always #f here: this tree has no image support and
      ;;   no `display-images-p'. Named in the header.
      ;;   `emoji' - #f: it needs `display-multi-font-p' and
      ;;   `internal-char-font', which this tree has not got; a terminal
      ;;   in Emacs answers #f there too.
      ;;   `symbol' - ICON when every character of it is displayable.
      ;;   `text' - always ICON.
      ;;--------------------------------------------------------------
      (case type
        ((image) #f)
        ((emoji) #f)
        ((symbol)
         (and (string? icon)
              (let loop ((i 0))
                (or (>= i (string-length icon))
                    (and (char-displayable? (string-ref icon i))
                         (loop (+ i 1)))))
              icon))
        ((text) icon)
        (else #f)))

    (define (char-displayable? c)
      ;; `char-displayable-p' (`fontset.c') asks the terminal's fonts
      ;; whether C has a glyph. This tree's terminal is the process's,
      ;; and every character the buffer can hold is drawn: a character
      ;; with no glyph is the font's box, not a display failure the
      ;; editor can detect. So the answer is #t, which is what Emacs
      ;; gives on a terminal whose fontset claims the character.
      ;;--------------------------------------------------------------
      #t)

    (define (icon-string name)
      ;; GNU Emacs's `icon-string' (`icons.el:133'): "Return a string
      ;; suitable for display in the current buffer for icon NAME."
      ;;--------------------------------------------------------------
      (let ((props (iconp name)))
        (unless props
          (error "~a is not a valid icon" name))
        (let ((spec (icon-complete-spec name))
              (keywords (list-ref props 3)))
          ;; "We now have a full spec, so check the intersection of what
          ;; the user wants and what this Emacs is capable of showing."
          (let ((icon-string
                 (let found ((prefs (*icon-preference*)))
                   (if (null? prefs)
                       #f
                       (let* ((type (car prefs))
                              (type-spec (assq type spec))
                              (type-keywords (and type-spec
                                                  (icon-spec-keywords type-spec))))
                         ;; `(and type-spec ...)' is nil in Elisp and
                         ;; #f here, and `(null? #f)' is false - so the
                         ;; absent-spec case has to be the empty list,
                         ;; which is what Emacs's nil reads as in the
                         ;; `null' test below.
                         (or (let try ((icons (or (and type-spec
                                                       (icon-spec-values type-spec))
                                                   '())))
                               (if (null? icons)
                                   #f
                                   (let ((result (icons--create
                                                  type (car icons)
                                                  type-keywords)))
                                     (if result
                                         (let ((face (and type-keywords
                                                          (plist-get-keyword
                                                           type-keywords ':face))))
                                           (if face
                                               (propertize result 'face face)
                                               result))
                                         (try (cdr icons))))))
                             (found (cdr prefs))))))))
            (unless icon-string
              (error "Couldn't find any way to display the ~a icon" name))
            (let ((help (plist-get-keyword keywords ':help-echo)))
              (when help
                (set! icon-string (propertize icon-string 'help-echo help))))
            (propertize icon-string 'rear-nonsticky #t)))))

    (define (icon-elements name)
      ;; GNU Emacs's `icon-elements' (`icons.el:164'): "Return the
      ;; elements of icon NAME. The elements are represented as a plist
      ;; where the keys are `string', `face' and `image'."
      ;;--------------------------------------------------------------
      (let ((string (icon-string name)))
        (list 'face (get-text-property 0 'face string)
              'image (get-text-property 0 'display string)
              'string (substring string 0))))

    ))
