(define-library (schemacs textprop)
  ;; This library mirrors GNU Emacs's `textprop.c`: the Lisp-level API
  ;; over the interval tree that `(schemacs intervals)` holds.
  ;;
  ;; Emacs splits these the same way - `intervals.c` is the tree and
  ;; `textprop.c` is the API - and the split matters, because the tree's
  ;; operations are about positions and property lists while these are
  ;; about *ranges* of a buffer: they validate the range, find the
  ;; intervals it covers, split them at its ends, and merge or replace
  ;; the property lists as the function's contract says.
  ;;
  ;; Three things this library does not carry over, each stated where it
  ;; is felt:
  ;;
  ;;  * **Buffers only, not strings.** Emacs's functions take an OBJECT
  ;;    that may be a buffer or a string, and strings carry intervals of
  ;;    their own (`string_intervals'). Scheme strings cannot hold
  ;;    properties, so everything here acts on a buffer - the engine's
  ;;    `<text-editor>'. That is what blocks `propertize' (below), and it
  ;;    is a limitation of the string type, not of the tree.
  ;;  * **Positions are 0-based**, as `(schemacs intervals)`
  ;;    explains: this engine indexes characters from 0, so these take
  ;;    character indices where Emacs takes 1-based buffer positions. The
  ;;    conversion belongs to the elisp layer, as `point` does.
  ;;  * **No overlays.** `get-char-property' in Emacs also reads
  ;;    properties from the overlays at POSITION; there are none here, so
  ;;    it is `get-text-property' and says so. `face_at_buffer_position'
  ;;    in the display will need the same shape, so the function is here
  ;;    with the seam ready rather than left out.
  ;;
  ;; Not ported, with what each would need: `remove-list-of-text-properties'
  ;; (a list rather than a plist of property names, which is a second
  ;; walk of the same code), and `text-property-any' and `-not-all' (a
  ;; scan for a value, used by `read-only' checks in modes).
  ;;
  ;; `propertize' is `editfns.c`'s and lives there, and strings do carry
  ;; properties now (`string-intervals-property`), so `add-face-text-property`
  ;; - which needs `add_text_properties_1`'s prepend/append set-type -
  ;; is here beside `add-text-properties' and is what the tab line stacks
  ;; a face onto a close button's icon with.
  ;;
  ;; See FACES-PLAN.txt for the plan this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (guile) caddr)
    (only (schemacs buffer)
          *current-buffer* bufferp current-buffer overlay-get overlays-at
          next-overlay-change previous-overlay-change
          with-current-buffer buffer-local-value
          *get-text-property-function*)
    ;; `modify_text_properties`'s body is `insdel.c`'s
    ;; `prepare_to_modify_buffer_1` - the half that does not touch the
    ;; caches, because a property write does not change the characters -
    ;; and `buffer.c`'s modification counter, which it raises *without*
    ;; touching `chars_modiff`. `record_first_change` is `undo.c`'s and is
    ;; what leaves the "the file was saved here" mark behind.
    ;;
    ;; **This is the whole of the engine import this file used to have**:
    ;; it held `bufferp' - `buffer.c`'s, and read from there now - and
    ;; `text-editor-note-property-change!', which was this file's own
    ;; `modify_text_properties' under an invented name. That name is gone
    ;; and the function is defined below, in the file that owns it.
    (only (schemacs insdel) prepare-to-modify-buffer-1)
    (only (schemacs undo) record-first-change)
    (only (schemacs buffer) %text-editor-incr-modiff!
          buffer-beg buffer-z)
    ;; `install-intervals-set-text-properties!' is the seam back *up*
    ;; into this library - see the end of the file.
    (only (schemacs fns) install-fns-textprop!)
    (only (schemacs intervals)
          ;; `text-property-default-nonsticky` is `textprop.c`'s in
          ;; Emacs, but this tree keeps it with the insertion code that
          ;; reads it (`adjust_intervals_for_insertion`), which is
          ;; `intervals.scm`'s. Two definitions of it meant two answers
          ;; to "is this property sticky" - caught by
          ;; `loadup-tests`' duplicate-export check.
          *text-property-default-nonsticky*
          install-intervals-set-text-properties!)
    (prefix (schemacs intervals) iv:))

  (export
   add-face-text-property
   add-text-properties
   add-text-properties-from-list
   modify-text-properties
   text-property-list
   get-char-property
   remove-text-properties
   set-text-properties
   get-text-property
   ;; The field machinery (`textprop.c`'s stickiness rule and the walks a
   ;; field is found with).
   text-property-stickiness
   next-property-change previous-property-change
   next-char-property-change previous-char-property-change
   next-single-char-property-change previous-single-char-property-change
   interval-of
   interval-has-some-properties-list
   keyword?
   next-single-property-change
   previous-single-property-change
   put-text-property
   remove-list-of-text-properties
   text-properties-at
   text-property-any
   text-property-not-all
   validate-interval-range
   validate-plist
   ;; the kinds of change `add_properties' can make to a property that is
   ;; already there - `add-face-text-property' is what uses the last two
   *text-property-replace*
   *text-property-prepend*
   *text-property-append*
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Which interval, and which plist

    (define (validate-plist list)
      ;; GNU Emacs's `validate_plist': LIST as a property list. A
      ;; non-list is made into `(LIST nil)', and an odd-length list is an
      ;; error - Emacs signals "Odd length text property list" rather
      ;; than reading past the end.
      ;;--------------------------------------------------------------
      (cond
       ((null? list) '())
       ((not (pair? list)) (list list #f))
       (else
        (let loop ((tail list))
          (cond
           ((null? tail) list)
           ((not (pair? (cdr tail)))
            (error "Odd length text property list" list))
           (else (loop (cddr tail))))))))

    (define (object-or-current args)
      ;; The OBJECT an optional argument names, with nil meaning the
      ;; current buffer - which is what every one of these functions'
      ;; C does first thing: `if (NILP (object)) object =
      ;; Fcurrent_buffer ()'. Passing an explicit nil is *not* the same
      ;; as omitting the argument until it is read this way, and a nil
      ;; taken for a real object is a `text-editor-char-count' of #f.
      ;;--------------------------------------------------------------
      (or (and (pair? args) (car args)) (current-buffer)))

    (define (validate-interval-range object start end force?)
      ;; GNU Emacs's `validate_interval_range': the interval covering
      ;; START..END in OBJECT - a buffer or a string, which is the C's
      ;; `BUFFERP (object) ? buffer_intervals (XBUFFER (object)) :
      ;; string_intervals (object)'.
      ;; Answers three values - the interval (or #f), and START and END
      ;; as they were corrected - because the C corrects its arguments
      ;; through pointers and Scheme has to return them.
      ;;
      ;; A zero-length range is not an error but has no interval: it is
      ;; "the properties of a point", which some callers ask for and
      ;; which only `text-properties-at' and the `-property-change'
      ;; functions do.
      ;;
      ;; FORCE? is the C's FORCE: when the buffer has text but no
      ;; interval tree yet, make one rather than answering #f. Only a
      ;; function that is about to *put* a property needs that.
      ;;--------------------------------------------------------------
      ;; The C's bounds are `BUF_BEGV'/`BUF_ZV' - the *restriction*,
      ;; not the text - and a position outside them signals rather than
      ;; being clipped. `iv:object-beg-position' is `BEG' (always 1) for
      ;; `create_root_interval' and cannot answer this.
      (let* ((lo (if (string? object) 0 (buffer-beg object)))
             (hi (if (string? object) (string-length object) (buffer-z object)))
             (start (if (> start end) end start))
             (end (if (> start end) start end)))
        (cond
         ((and (= start end)) (values #f start end))
         ((or (< start lo) (< hi end))
          (error "Args out of range" start end))
         (else
          (let ((i (or (iv:object-intervals object)
                       (and force? (iv:create-root-interval object)))))
            (values (and i (iv:find-interval i start)) start end))))))

    (define (interval-of object position)
      ;; GNU Emacs's `interval_of': the interval POSITION is in, or #f.
      ;;--------------------------------------------------------------
      (let ((lo (if (string? object) 0 (buffer-beg object)))
            (hi (if (string? object) (string-length object) (buffer-z object))))
        (if (or (< position lo) (< hi position))
            (error "Args out of range" position)
            (let ((i (iv:object-intervals object)))
              (and i (iv:find-interval i position))))))

    ;;----------------------------------------------------------------
    ;; Reading

    (define (text-properties-at position . args)
      ;; GNU Emacs's `text-properties-at': the property list of the
      ;; character at POSITION.
      ;;
      ;; A POSITION at the end of an interval is the end of the *text*
      ;; there is no character after, so there are no properties - which
      ;; is the C's `if (position == LENGTH (i) + i->position) return
      ;; Qnil'. It is what makes `(get-text-property (point-max) ...)'
      ;; answer nil rather than reading the last character's properties.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (let ((interval (interval-of object position)))
          (cond
           ((not interval) '())
           ((= position (iv:interval-last-pos interval)) '())
           (else (iv:interval-plist interval))))))

    (define (get-text-property position prop . args)
      ;; GNU Emacs's `get-text-property': the value of PROP at POSITION,
      ;; or #f. TEXTGET is what answers, so a `category' property and the
      ;; default values are honoured.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (iv:textget (text-properties-at position object) prop)))

    (define (get-char-property position prop . args)
      ;; GNU Emacs's `get-char-property' (textprop.c:681): "Return the
      ;; value of POSITION's property PROP, in OBJECT. Both overlay
      ;; properties and text properties are checked."
      ;;
      ;; The rule is `get_char_property_and_overlay''s (textprop.c:619):
      ;; walk the overlays at POSITION "in order of decreasing priority"
      ;; and take the first that has the property; the text property
      ;; answers only when no overlay has it. This is the seam the
      ;; overlays were always meant to meet the display at.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        ;; "Both overlay properties and text properties are checked" - but
        ;; only a *buffer* has overlays, which is the C's
        ;; `if (BUFFERP (object))'.
        (if (not (bufferp object))
            (get-text-property position prop object)
            (parameterize ((*current-buffer* object))
              (let loop ((ovs (overlays-at position #t)))
                (cond ((null? ovs) (get-text-property position prop object))
                      ((overlay-get (car ovs) prop))
                      (else (loop (cdr ovs)))))))))

    ;;----------------------------------------------------------------
    ;; Whether an interval already has some properties

    (define (plist-member-of plist prop)
      ;; Whether PLIST has PROP at all. `interval-plist-get' cannot answer
      ;; this: a property present with the value #f looks just like one
      ;; that is absent, and the difference matters to `add_properties'.
      ;;--------------------------------------------------------------
      (let loop ((tail plist))
        (cond ((not (and (pair? tail) (pair? (cdr tail)))) #f)
              ((eq? (car tail) prop) #t)
              (else (loop (cddr tail))))))

    (define (interval-has-all-properties plist i)
      ;; GNU Emacs's `interval_has_all_properties' (textprop.c:221):
      ;; "Return true if interval I has all the properties, with the
      ;; same values, of list PLIST."
      ;;
      ;; *Every* element of PLIST has to be looked for, and the answer to
      ;; the first one is not the answer: answering there says only "I
      ;; have this one property", which is true of nearly every call, so
      ;; `add-text-properties-1' concluded the interval needed no change
      ;; and silently added nothing. A multi-property plist whose first
      ;; property was already present never landed at all - which is how
      ;; `dired-insert-set-properties'' `(dired-filename t mouse-face
      ;; highlight help-echo ...)' left a name carrying no `mouse-face',
      ;; because ls-lisp had already marked it `dired-filename'.
      ;;--------------------------------------------------------------
      (let loop ((tail plist))
        (cond
         ((not (and (pair? tail) (pair? (cdr tail)))) #t)
         (else
          (let ((sym (car tail))
                (val (cadr tail)))
            (and
             (let find ((mine (iv:interval-plist i)))
               (cond
                ((not (and (pair? mine) (pair? (cdr mine)))) #f)
                ((eq? (car mine) sym) (eq? (cadr mine) val))
                (else (find (cddr mine)))))
             (loop (cddr tail))))))))

    (define (interval-has-some-properties plist i)
      ;; GNU Emacs's `interval_has_some_properties': I has one of the
      ;; property *names* in PLIST, whatever the values - which is all
      ;; `remove-text-properties' cares about.
      ;;
      ;; PLIST may be an *odd-length* list here: `remove-text-properties'
      ;; is documented to take names and ignore the values, so callers
      ;; write `(face)' or `(face nil)' and both must work. The C walks
      ;; `while (CONSP (tail1))' and steps by two, relying on its `Fcdr'
      ;; of nil being nil; the step below has to say the same thing,
      ;; because Scheme's `cdr' of the empty list is an error.
      ;;--------------------------------------------------------------
      (let loop ((tail plist))
        (cond
         ((not (pair? tail)) #f)
         ((plist-member-of (iv:interval-plist i) (car tail)) #t)
         (else (loop (if (pair? (cdr tail)) (cddr tail) '()))))))

    (define (interval-has-some-properties-list list i)
      ;; GNU Emacs's `interval_has_some_properties_list': I has one of the
      ;; property names in LIST, whatever the values - the same question
      ;; `interval-has-some-properties' asks, asked of a plain list of
      ;; names rather than of a plist. `remove-list-of-text-properties'
      ;; is the caller, and this is the only difference between it and
      ;; `remove-text-properties'.
      ;;--------------------------------------------------------------
      (let loop ((tail list))
        (cond ((not (pair? tail)) #f)
              ((plist-member-of (iv:interval-plist i) (car tail)) #t)
              (else (loop (cdr tail))))))

    (define *text-property-replace* 'replace)
    (define *text-property-prepend* 'prepend)
    (define *text-property-append* 'append)
    ;; ^ GNU Emacs's `enum property_set_type'. A property already on an
    ;; interval can be replaced by the new value, or the new value can be
    ;; pushed onto the front (or the back) of it as a list - which is how
    ;; `add-face-text-property' *stacks* faces instead of losing the ones
    ;; already there.

    (define (keyword? x)
      ;; GNU Emacs's `keywordp': a symbol whose name starts with a colon.
      ;;--------------------------------------------------------------
      (and (symbol? x)
           (let ((name (symbol->string x)))
             (and (> (string-length name) 0)
                  (char=? (string-ref name 0) #\:)))))

    (define (add-properties plist i set-type)
      ;; GNU Emacs's `add_properties': merge PLIST's properties into
      ;; interval I, replacing or stacking where the C says to.
      ;;
      ;; The C also records every change in the buffer's undo list
      ;; (`record_property_change'). Property changes are not in this
      ;; engine's undo list yet, so that is not done - see the header.
      ;;--------------------------------------------------------------
      (let loop ((tail plist) (changed? #f))
        (cond
         ((not (and (pair? tail) (pair? (cdr tail)))) changed?)
         (else
          (let ((sym (car tail))
                (val (cadr tail)))
            (let find ((mine (iv:interval-plist i)))
              (cond
               ((not (and (pair? mine) (pair? (cdr mine))))
                ;; Not there at all: put it at the front of I's plist.
                (iv:set!interval-plist
                 i (cons sym (cons val (iv:interval-plist i))))
                (loop (cddr tail) #t))
               ((not (eq? (car mine) sym)) (find (cddr mine)))
               ((eq? (cadr mine) val) (loop (cddr tail) changed?))
               (else
                ;; Present with a different value.
                (let ((old (cadr mine)))
                  (if (eq? set-type *text-property-replace*)
                      (set-car! (cdr mine) val)
                      ;; An old value that is *already* a list grows by an
                      ;; element; anything else becomes a two-element
                      ;; list. Emacs excepts an anonymous face - a plist
                      ;; beginning with a keyword, which is a face's
                      ;; attributes rather than a list of faces - so that
                      ;; it is not mistaken for a list of faces.
                      (if (and (pair? old)
                               (not (and (eq? sym 'face)
                                         (keyword? (car old)))))
                          (set-car! (cdr mine)
                                    (if (eq? set-type *text-property-prepend*)
                                        (cons val old)
                                        (append old (list val))))
                          (set-car! (cdr mine)
                                    (if (eq? set-type *text-property-prepend*)
                                        (list val old)
                                        (list old val)))))
                  (loop (cddr tail) #t))))))))))

    (define (modify-text-properties object start end)
      ;; GNU Emacs's `modify_text_properties` (`textprop.c:76'): "Prepare to
      ;; modify the text properties of BUFFER from START to END." Every
      ;; property write to a *buffer* goes through it, and it is a near
      ;; twin of `insdel.c`'s `modify_text` - a change that no
      ;; insert/delete primitive makes - with three differences, all of
      ;; them the C's:
      ;;
      ;;   * it calls `prepare_to_modify_buffer_1`, the half that does
      ;;     **not** invalidate the region caches: the characters have not
      ;;     changed, so the line-break cache is still good. (This tree
      ;;     used to call `invalidate-buffer-caches` here, which the C
      ;;     does not - harmless, and wrong.)
      ;;   * `modiff_incr (&MODIFF, 1)` - a constant one, where
      ;;     `modify_text` passes the region's length.
      ;;   * it does **not** set `CHARS_MODIFF`, which is the whole reason
      ;;     the two counters exist apart.
      ;;
      ;; **What `prepare_to_modify_buffer_1` brings with it is the point
      ;; of the port**, and this tree did not have it: the read-only gate
      ;; (measured, `put-text-property` on a read-only buffer signals
      ;; `(buffer-read-only #<buffer>)` in Emacs 31.1 and is allowed when
      ;; `inhibit-read-only` is set), `before-change-functions` (measured:
      ;; called once by one property write), and the `deactivate-mark`
      ;; flag - `Fset (Qdeactivate_mark, Qt)`, its last line, and measured:
      ;; a property write turns it from nil to t.
      ;;
      ;; **And `record_first_change` is the other half of what was
      ;; missing.** The C tests `MODIFF <= SAVE_MODIFF` before raising the
      ;; counter, so the *first* change after a save - of any kind, a face
      ;; included - leaves the `(t . TOKEN)` entry that says where the file
      ;; was. Without it, undoing back past a property change went too far.
      ;;
      ;; **Not carried**, each named where Emacs has it:
      ;; `BUF_COMPUTE_UNCHANGED` (this tree keeps `beg_unchanged` but not
      ;; its sibling `end_unchanged`, whose only readers are a redisplay
      ;; that recomputes), `bset_point_before_scroll` (the redisplay's own
      ;; bookkeeping), and the `first_time` half of the call's guard
      ;; (`:1231`) - the C runs this once per outermost property write and
      ;; this runs it on every recursive one, which raises the counter more
      ;; than Emacs does and changes nothing else.
      ;;--------------------------------------------------------------
      (with-current-buffer object
        (prepare-to-modify-buffer-1 start end)
        (record-first-change)
        (%text-editor-incr-modiff! (current-buffer) 0)))

    (define (add-text-properties-1 start end properties object set-type)
      ;; GNU Emacs's `add_text_properties_1': add PROPERTIES to the text
      ;; START..END of OBJECT.
      ;;
      ;; The interval the range starts in is split at START when the range
      ;; starts inside it, so that the change begins on a boundary; then
      ;; every interval the range covers is given the properties, and the
      ;; last one is split at the end of the range when it runs past it,
      ;; so that only the part inside is changed.
      ;;--------------------------------------------------------------
      (let ((properties (validate-plist properties)))
        (if (null? properties)
            #f
            (let-values (((i start end)
                          (validate-interval-range object start end #t)))
              (if (not i)
                  #f
                  (begin
                    ;; A property write goes through the buffer's
                    ;; modification machinery - GNU Emacs's
                    ;; `modify_text_properties' (`textprop.c:76'), called
                    ;; at the same point (`if (BUFFERP (object) &&
                    ;; first_time)', `:1231'). It runs the change hooks,
                    ;; marks the buffer modified, and does **not** touch
                    ;; `chars_modiff', because the characters have not
                    ;; changed - which is why a cache of something
                    ;; computed from them is not thrown away by it.
                    (if (bufferp object)
                        (modify-text-properties object start end))
                  (let ((len (- end start)))
                    (let ((i (if (= start (iv:interval-position i))
                                 i
                                 (let* ((unchanged i)
                                        (new (iv:split-interval-right
                                              unchanged
                                              (- start
                                                 (iv:interval-position unchanged)))))
                                   (iv:copy-properties unchanged new)
                                   new))))
                      (let loop ((i i) (len len) (changed? #f))
                        (cond
                         ((>= (iv:interval-length i) len)
                          (cond
                           ((interval-has-all-properties properties i)
                            changed?)
                           ((= (iv:interval-length i) len)
                            (add-properties properties i set-type))
                           (else
                            ;; The interval runs past the end of the range.
                            ;; Split it there and change only the part
                            ;; inside - which `split-interval-left' answers
                            ;; with, leaving I as the remainder.
                            (let* ((unchanged i)
                                   (piece (iv:split-interval-left
                                           unchanged len)))
                              (iv:copy-properties unchanged piece)
                              (add-properties properties piece set-type)))))
                         (else
                          (loop (iv:next-interval i)
                                (- len (iv:interval-length i))
                                (or (add-properties properties i set-type)
                                    changed?)))))))))))))

    (define (add-text-properties start end properties . args)
      ;; GNU Emacs's `add-text-properties': merge PROPERTIES into the text
      ;; from START to END. A property already there with a different
      ;; value is *replaced*; one that is not there is added; and the rest
      ;; of each interval's plist is left alone.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (add-text-properties-1 start end properties object
                               *text-property-replace*)))

    (define (add-face-text-property start end face . args)
      ;; GNU Emacs's `add-face-text-property' (`textprop.c:1345'): "Add
      ;; the face property to the text from START to END. ... If any text
      ;; in the region already has a non-nil `face' property, those
      ;; face(s) are retained. This is done by setting the `face' property
      ;; to a list of faces, with FACE as the first element (by default)
      ;; and the pre-existing faces as the remaining elements. If optional
      ;; fourth argument APPEND is non-nil, append FACE to the end of the
      ;; face list instead."
      ;;
      ;; The C is three lines: `AUTO_LIST2 (properties, Qface, face)'
      ;; then `add_text_properties_1' with `TEXT_PROPERTY_PREPEND' or
      ;; `TEXT_PROPERTY_APPEND'. Both halves are already here - the merge
      ;; rule is `add-text-properties-1`'s set-type argument - so this is
      ;; the same three lines.
      ;;
      ;; OBJECT is the fifth argument, as it is in Emacs; it may be a
      ;; buffer or a string. `propertize' and the tab line both pass a
      ;; string.
      ;;--------------------------------------------------------------
      (let* ((append (if (pair? args) (car args) #f))
             (object (object-or-current
                      (if (and (pair? args) (pair? (cdr args)))
                          (cdr args)
                          '()))))
        (add-text-properties-1 start end (list 'face face) object
                               (if append
                                   *text-property-append*
                                   *text-property-prepend*))
        #f))

    (define (put-text-property start end property value . args)
      ;; GNU Emacs's `put-text-property': set one property, which is
      ;; `add-text-properties' of a one-property plist.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (add-text-properties start end (list property value) object)
        #f))

    ;;----------------------------------------------------------------
    ;; Replacing properties

    (define (set-properties properties interval)
      ;; GNU Emacs's `set_properties': INTERVAL's property list becomes
      ;; PROPERTIES, copied so that the caller's list and the interval's
      ;; are not the same list.
      ;;
      ;; The C records the old values for undo here, as `add_properties'
      ;; does; property changes are not in this engine's undo list yet.
      ;;--------------------------------------------------------------
      (iv:set!interval-plist interval (list-copy properties)))

    (define (set-text-properties-1 start end properties object i)
      ;; GNU Emacs's `set_text_properties_1': PROPERTIES *replace* the
      ;; properties of the text START..END, interval by interval.
      ;;
      ;; An interval left with no properties merges back into its
      ;; neighbour as the walk goes (`merge_interval_left'), which is what
      ;; keeps `set-text-properties' from leaving a trail of empty
      ;; intervals behind it - and why the walk carries `prev-changed'.
      ;;
      ;; The first block is the case where the range begins *inside* an
      ;; interval: split it at START, and if the piece from there is
      ;; already longer than the range, split it again at the end and the
      ;; whole job is done.
      ;;--------------------------------------------------------------
      ;; the same raise as `add-text-properties-1''s, for a replacement
      (if (bufferp object)
          (modify-text-properties object start end))
      (let ((len (- end start)))
        (if (<= len 0)
            #f
            (let-values (((i len prev-changed done?)
                          (if (= start (iv:interval-position i))
                              (values i len #f #f)
                              (let* ((unchanged i)
                                     (piece (iv:split-interval-right
                                             unchanged
                                             (- start
                                                (iv:interval-position unchanged)))))
                                (if (> (iv:interval-length piece) len)
                                    (begin
                                      (iv:copy-properties unchanged piece)
                                      (set-properties
                                       properties (iv:split-interval-left piece len))
                                      (values #f 0 #f #t))
                                    (begin
                                      (set-properties properties piece)
                                      (if (= (iv:interval-length piece) len)
                                          (values #f 0 #f #t)
                                          (values piece
                                                  (- len (iv:interval-length piece))
                                                  piece
                                                  #f))))))))
              (if done?
                  #t
                  (let loop ((i i) (len len) (prev-changed prev-changed))
                    (cond
                     ((>= (iv:interval-length i) len)
                      (let ((i (if (> (iv:interval-length i) len)
                                   (iv:split-interval-left i len)
                                   i)))
                        (set-properties properties i)
                        (when prev-changed (iv:merge-interval-left i))
                        #t))
                     (else
                      (let ((step (iv:interval-length i)))
                        (set-properties properties i)
                        (if prev-changed
                            (let ((merged (iv:merge-interval-left i)))
                              (loop (iv:next-interval merged)
                                    (- len step) merged))
                            (loop (iv:next-interval i) (- len step) i)))))))))))

    (define (set-text-properties start end properties . args)
      ;; GNU Emacs's `set-text-properties': PROPERTIES become the whole
      ;; property list of the text from START to END. With no properties
      ;; at all, this removes every property from the range.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (properties (validate-plist properties)))
        (let-values (((i start end)
                      (validate-interval-range object start end #t)))
          (if (not i)
              #f
              (begin
                (set-text-properties-1 start end properties object i)
                #t)))))

    ;;----------------------------------------------------------------
    ;; Removing properties

    (define (remove-properties plist list i)
      ;; GNU Emacs's `remove_properties': take the properties named in
      ;; PLIST (or, when that is empty, the names in LIST) off interval I.
      ;; The values in PLIST are ignored - it is the names that matter.
      ;;
      ;; The C walks I's plist and unlinks each match, head included, so
      ;; that every occurrence goes; a filter over the plist is the same
      ;; answer and is what this is.
      ;;--------------------------------------------------------------
      ;; As in `interval-has-some-properties', PLIST may be an odd-length
      ;; list of names with no values, so the walk takes the names while
      ;; there are pairs and steps by two without assuming a value follows
      ;; the last one.
      (let ((names (if (pair? plist)
                       (let loop ((tail plist) (acc '()))
                         (cond ((not (pair? tail)) (reverse acc))
                               (else (loop (if (pair? (cdr tail))
                                               (cddr tail)
                                               '())
                                           (cons (car tail) acc)))))
                       list)))
        (if (null? names)
            #f
            (let loop ((tail (iv:interval-plist i)) (acc '()) (changed? #f))
              (cond
               ((not (and (pair? tail) (pair? (cdr tail))))
                (if changed?
                    (begin (iv:set!interval-plist i (reverse acc)) #t)
                    #f))
               ((memq (car tail) names) (loop (cddr tail) acc #t))
               (else (loop (cddr tail)
                           (cons (cadr tail) (cons (car tail) acc))
                           changed?)))))))

    (define (%remove-properties-from i start end properties names)
      ;; The removal itself: the properties named by PROPERTIES (or, when
      ;; that is empty, by NAMES) off the text from START to END, I being
      ;; the interval START falls in. The C's walk - the range may begin
      ;; inside an interval, so it is split at START first, and then each
      ;; interval that has something is cleared until the range runs out.
      ;;--------------------------------------------------------------
      (let ((has? (if (pair? properties)
                      (lambda (i) (interval-has-some-properties properties i))
                      (lambda (i)
                        (interval-has-some-properties-list names i)))))
        (let ((i (if (= start (iv:interval-position i))
                     i
                     (let* ((unchanged i)
                            (piece (iv:split-interval-right
                                    unchanged
                                    (- start (iv:interval-position unchanged)))))
                       (iv:copy-properties unchanged piece)
                       piece))))
          (let loop ((i i) (len (- end start)) (modified? #f))
            (cond
             ((>= (iv:interval-length i) len)
              (cond
               ((not (has? i)) modified?)
               ((= (iv:interval-length i) len)
                (remove-properties properties names i))
               (else
                ;; I has the properties and runs past the end of the range:
                ;; split it there and remove only from the part inside.
                (let* ((unchanged i)
                       (piece (iv:split-interval-left unchanged len)))
                  (iv:copy-properties unchanged piece)
                  (remove-properties properties names piece)))))
             (else
              (let ((next (iv:next-interval i))
                    (len (- len (iv:interval-length i))))
                (loop next len
                      (or (remove-properties properties names i)
                          modified?)))))))))

    (define (%remove-properties-range object start end properties names)
      ;; The walk GNU Emacs's `Fremove_text_properties' and
      ;; `Fremove_list_of_text_properties' both make; they differ only in
      ;; which predicate asks "has this interval got any of the names" -
      ;; PROPERTIES being the names-with-values plist and NAMES the plain
      ;; list of names.
      ;;
      ;; The C's first step walks to the first interval in the range that
      ;; carries one of them, *and goes on to remove from there*: a range
      ;; that begins before the property does is not a reason to remove
      ;; nothing. This used to answer #t at that point and remove nothing,
      ;; so the function reported success and changed nothing whenever
      ;; START fell before the property - which is the shape
      ;; `dired-fontify-line!' has, clearing a whole line while the face
      ;; sits on the file name in the middle of it. Measured: a face on
      ;; [6,8) of a ten-character buffer survived
      ;; `(remove-text-properties 0 10 '(face))', which answered #t.
      ;;--------------------------------------------------------------
      (let ((has? (if (pair? properties)
                      (lambda (i) (interval-has-some-properties properties i))
                      (lambda (i)
                        (interval-has-some-properties-list names i)))))
        (let-values (((i start end)
                      (validate-interval-range object start end #f)))
          (cond
           ((not i) #f)
           ((and (null? properties) (null? names)) #f)
           (else
            (let loop ((i i) (from start))
              (cond
               ((or (not i) (<= end from)) #f)
               ((has? i)
                (%remove-properties-from i from end properties names))
               (else
                (let ((next (iv:next-interval i)))
                  (loop next (if next (iv:interval-position next) end)))))))))))

    (define (remove-text-properties start end properties . args)
      ;; GNU Emacs's `remove-text-properties': take the properties named
      ;; in PROPERTIES off the text from START to END, leaving the others.
      ;; Answers #t when something was actually removed.
      ;;--------------------------------------------------------------
      ;; PROPERTIES is *not* run through `validate-plist': the C does not
      ;; validate it here, precisely so that a list of names with no
      ;; values - which is what callers write - is accepted.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        ;; `Fremove_text_properties' raises the counter for a buffer, as
        ;; the adding side does (`textprop.c:1775')
        (if (bufferp object)
            (modify-text-properties object start end))
        (%remove-properties-range object start end properties '())))

    (define (remove-list-of-text-properties start end properties . args)
      ;; GNU Emacs's `remove-list-of-text-properties': "like
      ;; `remove-text-properties' except that the third argument is a
      ;; list of property names rather than a property list". It is what
      ;; `font-lock-default-unfontify-region' clears a region with, since
      ;; the properties it manages are a list of names.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (if (bufferp object)
            (modify-text-properties object start end))
        (%remove-properties-range object start end '() properties)))

    ;;----------------------------------------------------------------
    ;; Looking for a value

    (define (text-property-any start end property value . args)
      ;; GNU Emacs's `text-property-any' (textprop.c:1821): "Check text
      ;; from START to END for property PROPERTY equaling VALUE. If so,
      ;; return the position of the first character whose property
      ;; PROPERTY is `eq' to VALUE. Otherwise return nil."
      ;;
      ;; Positions here are the interval layer's zero-based indices, as
      ;; every other function of this library's are.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (let-values (((i start end)
                      (validate-interval-range object start end #f)))
          (if (not i)
              ;; the C's `(!NILP (value) || EQ (start, end) ? Qnil : start)'
              (if (or value (= start end)) #f start)
              (let loop ((i i))
                (cond ((not i) #f)
                      ((>= (iv:interval-position i) end) #f)
                      ((eq? (iv:textget (iv:interval-plist i) property) value)
                       (max (iv:interval-position i) start))
                      (else (loop (iv:next-interval i)))))))))

    (define (text-property-not-all start end property value . args)
      ;; GNU Emacs's `text-property-not-all' (textprop.c:1857): "Check
      ;; text from START to END for property PROPERTY not equaling VALUE.
      ;; If so, return the position of the first character whose property
      ;; PROPERTY is not `eq' to VALUE. Otherwise, return nil."
      ;;
      ;; The walk may find the interval that *precedes* START, and the C
      ;; then answers START itself rather than that interval's position.
      ;;--------------------------------------------------------------
      (let ((object (object-or-current args)))
        (let-values (((i start end)
                      (validate-interval-range object start end #f)))
          (if (not i)
              ;; the C's `(NILP (value) || EQ (start, end)) ? Qnil : start'
              (if (or (not value) (= start end)) #f start)
              (let loop ((i i) (s start))
                (cond ((not i) #f)
                      ((>= (iv:interval-position i) end) #f)
                      ((not (eq? (iv:textget (iv:interval-plist i) property)
                                 value))
                       (max (iv:interval-position i) s))
                      (else (loop (iv:next-interval i) s))))))))

    ;;----------------------------------------------------------------
    ;; Where a property changes

    (define (next-single-property-change position prop . args)
      ;; GNU Emacs's `next-single-property-change': the position of the
      ;; next change of PROP at or after POSITION, or LIMIT when the value
      ;; does not change again before it. With no LIMIT the search runs to
      ;; the end of the buffer, and "no change" answers #f.
      ;;
      ;; This is the function a renderer walks a line with: the characters
      ;; between one change and the next all have the same value, so they
      ;; can be drawn in one go.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (end (or limit (iv:object-end-position object))))
        (let ((i (interval-of object (min position
                                          (iv:object-last-position object)))))
          (if (not i)
              limit
              (let ((here (iv:textget (iv:interval-plist i) prop)))
                (let loop ((next (iv:next-interval i)))
                  (cond
                   ((and next
                         (eq? here (iv:textget (iv:interval-plist next) prop))
                         (or (not limit) (< (iv:interval-position next) limit)))
                    (loop (iv:next-interval next)))
                   ((or (not next) (>= (iv:interval-position next) end)) limit)
                   (else (iv:interval-position next)))))))))

    (define (previous-single-property-change position prop . args)
      ;; GNU Emacs's `previous-single-property-change': the position of the
      ;; previous change of PROP before POSITION, or LIMIT.
      ;;
      ;; It starts with the interval holding the character *before*
      ;; POSITION, which is why a POSITION that begins an interval steps
      ;; back one first - otherwise a change exactly at POSITION would be
      ;; reported as being before it.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (let* ((at (interval-of object (min position
                                            (iv:object-last-position object))))
               (i (if (and at (= (iv:interval-position at) position))
                      (iv:previous-interval at)
                      at)))
          (if (not i)
              limit
              (let ((here (iv:textget (iv:interval-plist i) prop)))
                (let loop ((previous (iv:previous-interval i)))
                  (cond
                   ((and previous
                         (eq? here (iv:textget (iv:interval-plist previous) prop))
                         (or (not limit) (> (iv:interval-last-pos previous) limit)))
                    (loop (iv:previous-interval previous)))
                   ((or (not previous)
                        (<= (iv:interval-last-pos previous)
                            (or limit (iv:object-beg-position object))))
                    limit)
                   (else (iv:interval-last-pos previous)))))))))
    ;;----------------------------------------------------------------
    ;; Fields, and the property walks that find them
    ;;
    ;; A *field* is a run of text whose `field' text property is the
    ;; same. GNU Emacs uses fields for the minibuffer's prompt, for
    ;; comint's prompts and for `read-only' regions, and the motion
    ;; commands stop at their edges: `line-beginning-position' and
    ;; `line-end-position' hand their answers to `constrain-to-field'
    ;; (`editfns.c:717', `:772'), which is why `C-a' in a minibuffer
    ;; goes to the end of the prompt and not to the start of the line.
    ;;
    ;; The three pieces are here because they are `textprop.c`'s: the
    ;; stickiness rule, the walks over a *char* property (text property
    ;; or overlay), and the two walks over *any* property the first pair
    ;; is built on.
    ;;----------------------------------------------------------------

    (define (next-property-change position . args)
      ;; GNU Emacs's `next-property-change' (`textprop.c:952'): "Return
      ;; the position of next property change" - of *any* property, which
      ;; is the walk the char-property pair below is built on.
      ;;
      ;; The C compares the whole interval plist; `next-single-property-
      ;; change` compares one property of it.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (end (or limit (iv:object-end-position object))))
        (let ((i (interval-of object (min position
                                          (iv:object-last-position object)))))
          (if (not i)
              (or limit end)
              (let ((here (iv:interval-plist i)))
                (let loop ((next (iv:next-interval i)))
                  (cond
                   ((and next
                         (equal? here (iv:interval-plist next))
                         (or (not limit) (< (iv:interval-position next) limit)))
                    (loop (iv:next-interval next)))
                   ((or (not next) (>= (iv:interval-position next) end))
                    (or limit end))
                   (else (iv:interval-position next)))))))))

    (define (previous-property-change position . args)
      ;; GNU Emacs's `previous-property-change': the position of the
      ;; previous change of any property. It starts from the character
      ;; *before* POSITION, which is why a POSITION that begins an
      ;; interval steps back one first.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (let* ((at (interval-of object (min position
                                            (iv:object-last-position object))))
               (i (if (and at (= (iv:interval-position at) position))
                      (iv:previous-interval at)
                      at)))
          (if (not i)
              limit
              (let ((here (iv:interval-plist i)))
                (let loop ((previous (iv:previous-interval i)))
                  (cond
                   ((and previous
                         (equal? here (iv:interval-plist previous))
                         (or (not limit) (> (iv:interval-last-pos previous) limit)))
                    (loop (iv:previous-interval previous)))
                   ((or (not previous)
                        (<= (iv:interval-last-pos previous)
                            (or limit (iv:object-beg-position object))))
                    limit)
                   (else (iv:interval-last-pos previous)))))))))

    (define (next-char-property-change position limit)
      ;; GNU Emacs's `next-char-property-change` (`textprop.c:718`):
      ;; "Return the position of next text property or overlay change."
      ;;
      ;; The C is three lines: the next overlay change, clipped to LIMIT,
      ;; and then the next property change up to that point - so a text
      ;; property change and an overlay boundary are both found, whichever
      ;; comes first.
      ;;--------------------------------------------------------------
      (let ((temp (next-overlay-change position)))
        (if (and limit (< limit temp)) (set! temp limit))
        ;; `Fnext_property_change (position, Qnil, temp)` - the OBJECT
        ;; is nil, so TEMP is the *limit*, which is the third argument
        (next-property-change position #f temp)))

    (define (previous-char-property-change position limit)
      ;; GNU Emacs's `previous-char-property-change` (`textprop.c:744`).
      ;; The C takes the *earlier* of the previous overlay change and
      ;; LIMIT; a position below `point-min` is clipped to it.
      ;;--------------------------------------------------------------
      (let ((temp (previous-overlay-change position)))
        (if (and limit (> limit temp)) (set! temp limit))
        ;; `Fprevious_property_change (position, Qnil, temp)`: object
        ;; nil, limit TEMP
        (previous-property-change position #f temp)))

    (define (next-single-char-property-change position prop . args)
      ;; GNU Emacs's `next-single-char-property-change` (`textprop.c:771`):
      ;; "the position of next text property or overlay change for a
      ;; specific property."
      ;;
      ;; The C walks from change to change of *any* property or overlay
      ;; and stops at the first where PROP's char-property (overlay
      ;; first, then text) differs from what it was at POSITION. Overlays
      ;; matter here and not in `next-single-property-change`, which is
      ;; what makes this the one a field walk uses.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (zv (iv:object-end-position object))
             (limit (or limit zv)))
        (if (>= position limit)
            ;; "position = limit; if (position > ZV) XSETFASTINT
            ;; (position, ZV)" - the clamp is on the *limit*
            (if (> limit zv) zv limit)
            (let ((initial (get-char-property position prop object)))
              (let loop ((p position))
                (let ((next (next-char-property-change p limit)))
                  (cond ((>= next limit) limit)
                        ((not (eq? (get-char-property next prop object) initial)) next)
                        ((>= next zv) next)
                        (else (loop next)))))))))

    (define (previous-single-char-property-change position prop . args)
      ;; GNU Emacs's `previous-single-char-property-change`
      ;; (`textprop.c:858`): the same walk backwards. The value compared
      ;; against is the char-property of the character *before*
      ;; POSITION, and the answer is the position where it began.
      ;;--------------------------------------------------------------
      (let* ((object (object-or-current args))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (limit (or limit (iv:object-beg-position object))))
        (if (<= position limit)
            limit
            (let ((initial (get-char-property (- position 1) prop object)))
              (let loop ((p position))
                (let ((prev (previous-char-property-change p limit)))
                  (cond ((<= prev limit) limit)
                        ((not (eq? (get-char-property (- prev 1) prop object)
                                   initial))
                         prev)
                        (else (loop prev)))))))))

    (define (text-property-stickiness prop position buffer)
      ;; GNU Emacs's `text_property_stickiness` (`textprop.c`): 1 if an
      ;; insertion at POSITION would inherit PROP from the character
      ;; *after* it, -1 if from the character before, 0 if from neither.
      ;;
      ;; Rear-stickiness is the default - a property extends backwards
      ;; over inserted text unless `rear-nonsticky' says otherwise - and
      ;; `front-sticky' is what extends it forwards, which is how the
      ;; minibuffer prompt keeps its `field' off the text typed after it:
      ;; `read_minibuf` marks the prompt `rear-nonsticky` for exactly
      ;; this (and `front-sticky`, so its own characters are in it).
      ;;--------------------------------------------------------------
      (let* ((prev-pos (- position 1))
             (default (assq prop (*text-property-default-nonsticky*)))
             ;; The C's `ignore_previous_character = pos <= BUF_BEGV' -
             ;; the *restriction*, so that the previous character is
             ;; never read outside it. `iv:object-beg-position' is
             ;; `BEG' (always 1) and let a narrowed buffer read at
             ;; BEGV-1, which now signals.
             (ignore-previous (<= position
                                  (if (string? buffer) 0 (buffer-beg buffer))))
             ;; "if (ignore_previous_character || (CONSP (defalt) && !NILP (XCDR (defalt))))"
             (rear-sticky? (not (or ignore-previous
                                    (and (pair? default) (cdr default)))))
             (rear-sticky?
              (and rear-sticky?
                   (let ((rn (get-text-property prev-pos 'rear-nonsticky buffer)))
                     (not (if (pair? rn)
                              (and (memq prop rn) #t)
                              (and rn #t))))))
             (front (get-text-property position 'front-sticky buffer))
             (front-sticky? (or (eq? front #t)
                                (and (pair? front) (and (memq prop front) #t)))))
        (cond ((and rear-sticky? (not front-sticky?)) -1)
              ((and (not rear-sticky?) front-sticky?) 1)
              ((and (not rear-sticky?) (not front-sticky?)) 0)
              ;; "the stickiness properties are inconsistent, so we have
              ;; to disambiguate. Basically, rear-sticky wins, _except_
              ;; if the property that would be inherited has a value of
              ;; nil, in which case front-sticky wins."
              ((or ignore-previous
                   (not (get-text-property prev-pos prop buffer)))
               1)
              (else -1))))

    (define (text-property-list object start end prop)
      ;; GNU Emacs's `text_property_list' (textprop.c): the properties of
      ;; OBJECT from START to END as a list of `(START END PLIST)'
      ;; triples, one per run of text that has any - newest first, as the
      ;; C's consing leaves them.
      ;;
      ;; PROP, when given, keeps only that one property of each run, and a
      ;; run without it is left out altogether. That is the C's `if
      ;; (!NILP (prop))' walk, and it is what lets a caller ask for one
      ;; property down a whole string.
      ;;--------------------------------------------------------------
      (let-values (((i start end) (validate-interval-range object start end #f)))
        (if (not i)
            '()
            (let loop ((i i) (s start) (e end) (acc '()))
              (if (or (not i) (>= s e))
                  acc
                  (let* ((interval-end (min (+ (iv:interval-position i)
                                               (iv:interval-length i))
                                            e))
                         (len (- interval-end s))
                         (plist (if (not prop)
                                    (iv:interval-plist i)
                                    ;; the C's `Fplist_member', which
                                    ;; answers the *tail* - not
                                    ;; `plist-member-of' above, which
                                    ;; answers a boolean
                                    (let find ((tail (iv:interval-plist i)))
                                      (cond ((not (and (pair? tail)
                                                       (pair? (cdr tail))))
                                             '())
                                            ((eq? (car tail) prop)
                                             (list prop (cadr tail)))
                                            (else (find (cddr tail)))))))
                         (next (iv:next-interval i)))
                    (loop next
                          (if next (iv:interval-position next) e)
                          e
                          (if (null? plist)
                              acc
                              (cons (list s (+ s len) plist) acc)))))))))

    (define (add-text-properties-from-list object list delta)
      ;; GNU Emacs's `add_text_properties_from_list' (textprop.c): add
      ;; every run of LIST - `(START END PLIST)' triples - to OBJECT,
      ;; with DELTA added to each end. It is how `concat' moves the
      ;; properties of the pieces it was given onto the string it made.
      ;;--------------------------------------------------------------
      (for-each (lambda (item)
                  (add-text-properties (+ (car item) delta)
                                       (+ (cadr item) delta)
                                       (caddr item)
                                       object))
                list)
      #f)


    ;; `graft-intervals-into-buffer' clears the properties of text it is
    ;; given that carries none, and the C does that with
    ;; `set_text_properties_1' from *this* file, which sits above
    ;; `(schemacs intervals)'. Handed over once, at load, the same
    ;; way files.el's two functions are handed to `ls-lisp'.
    (install-intervals-set-text-properties! set-text-properties-1)
    (install-fns-textprop! text-property-list add-text-properties-from-list)

    ;; The seam `barf-if-buffer-read-only' (`buffer.scm') reads to ask
    ;; whether the `inhibit-read-only` *text property* is set where a
    ;; change is being made - the C's third test (`buffer.c:2465'). It is
    ;; a seam because the tree's lookups are this library's and this
    ;; library is above the buffer's; it is cold, because the C's `&&`
    ;; only asks when the buffer is read-only and `inhibit-read-only' is
    ;; nil.
    (*get-text-property-function* get-text-property)

    ;; **`char-property-alias-alist`'s buffer-local reader.** The variable
    ;; is `intervals.c`'s and the reader there is below the buffer's
    ;; slots; this library is above both and installs the answer: the
    ;; current buffer's own list - `font-lock-default-function` makes
    ;; `font-lock-face` an alias of `face` in a buffer where the mode is
    ;; on - or the global one. Emacs reads the *current* buffer's value
    ;; even when the text being read belongs to another buffer
    ;; (`intervals.c:1733` reads `Vchar_property_alias_alist` in
    ;; `current_buffer`'s context), and so does this.
    (iv:*char-property-alias-alist-function*
     (lambda ()
       ;; **`(current-buffer)` and not `(*current-buffer*)`**: the
       ;; parameter is #f whenever no `set-buffer` has pinned a buffer -
       ;; which is the ordinary case, because the current buffer falls
       ;; back to the selected window's - and this reader has to see
       ;; *that* buffer's list, as `lookup_char_property` sees
       ;; `current_buffer`. Reading the raw parameter answered the global
       ;; list for every buffer nobody had explicitly pinned, so a
       ;; `font-lock-face` property never resolved.
       (let ((buffer (current-buffer)))
         (if buffer
             (buffer-local-value buffer 'char-property-alias-alist
                                 (iv:*char-property-alias-alist*))
             (iv:*char-property-alias-alist*)))))

    ))
