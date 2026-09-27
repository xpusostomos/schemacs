(define-library (schemacs editor textprop)
  ;; This library mirrors GNU Emacs's `textprop.c`: the Lisp-level API
  ;; over the interval tree that `(schemacs editor intervals)` holds.
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
  ;;  * **Positions are 0-based**, as `(schemacs editor intervals)`
  ;;    explains: this engine indexes characters from 0, so these take
  ;;    character indices where Emacs takes 1-based buffer positions. The
  ;;    conversion belongs to the elisp layer, as `point` does.
  ;;  * **No overlays.** `get-char-property' in Emacs also reads
  ;;    properties from the overlays at POSITION; there are none here, so
  ;;    it is `get-text-property' and says so. `face_at_buffer_position'
  ;;    in the display will need the same shape, so the function is here
  ;;    with the seam ready rather than left out.
  ;;
  ;; Not ported, with what each would need: `propertize' (a string type
  ;; that carries properties - Emacs keeps intervals on strings, and the
  ;; elisp layer's string type is where that would live; the C is in
  ;; `editfns.c', not `textprop.c'), `remove-list-of-text-properties'
  ;; (a list rather than a plist of property names, which is a second
  ;; walk of the same code), `text-property-any' and `-not-all' (a scan
  ;; for a value, used by `read-only' checks in modes), and
  ;; `add-face-text-property' (it needs `add_text_properties_1''s
  ;; prepend/append set-type, which is here as an argument but unused
  ;; until something calls it).
  ;;
  ;; See FACES-PLAN.txt for the plan this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editor engine)
          text-editor-char-count text-editor-text-props)
    (only (schemacs editor buffer) current-buffer)
    (prefix (schemacs editor intervals) iv:))

  (export
   add-text-properties
   get-char-property
   remove-text-properties
   set-text-properties
   get-text-property
   interval-of
   next-single-property-change
   previous-single-property-change
   put-text-property
   text-properties-at
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

    (define (validate-interval-range buffer start end force?)
      ;; GNU Emacs's `validate_interval_range': the interval covering
      ;; START..END in BUFFER, with the range checked and put in order.
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
      (let* ((length (text-editor-char-count buffer))
             (start (if (> start end) end start))
             (end (if (> start end) start end)))
        (cond
         ((and (= start end)) (values #f start end))
         ((or (< start 0) (< length end))
          (error "Args out of range" start end))
         (else
          (let ((i (or (iv:buffer-intervals buffer)
                       (and force? (iv:create-root-interval buffer)))))
            (values (and i (iv:find-interval i start)) start end))))))

    (define (interval-of buffer position)
      ;; GNU Emacs's `interval_of': the interval POSITION is in, or #f.
      ;;--------------------------------------------------------------
      (let ((length (text-editor-char-count buffer)))
        (if (or (< position 0) (< length position))
            (error "Args out of range" position)
            (let ((i (iv:buffer-intervals buffer)))
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
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (let ((interval (interval-of buffer position)))
          (cond
           ((not interval) '())
           ((= position (iv:interval-last-pos interval)) '())
           (else (iv:interval-plist interval))))))

    (define (get-text-property position prop . args)
      ;; GNU Emacs's `get-text-property': the value of PROP at POSITION,
      ;; or #f. TEXTGET is what answers, so a `category' property and the
      ;; default values are honoured.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (iv:textget (text-properties-at position buffer) prop)))

    (define (get-char-property position prop . args)
      ;; GNU Emacs's `get-char-property': like `get-text-property', and
      ;; also reads the overlays at POSITION. There are no overlays here,
      ;; so this is the text property alone - and it is written as the
      ;; place an overlay lookup would go, because the display's
      ;; `face_at_buffer_position' wants the same seam.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (get-text-property position prop buffer)))

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
      ;; GNU Emacs's `interval_has_all_properties': every property in
      ;; PLIST is on I with an `eq?' value. It is what lets
      ;; `add-text-properties-1' skip an interval it would not change.
      ;;--------------------------------------------------------------
      (let loop ((tail plist))
        (cond
         ((not (and (pair? tail) (pair? (cdr tail)))) #t)
         (else
          (let ((sym (car tail))
                (val (cadr tail)))
            (let find ((mine (iv:interval-plist i)))
              (cond
               ((not (pair? mine)) #f)
               ((eq? (car mine) sym) (eq? (cadr mine) val))
               (else (find (if (pair? (cdr mine)) (cddr mine) '()))))))))))

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

    (define (add-text-properties-1 start end properties buffer set-type)
      ;; GNU Emacs's `add_text_properties_1': add PROPERTIES to the text
      ;; START..END of BUFFER.
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
                          (validate-interval-range buffer start end #t)))
              (if (not i)
                  #f
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
                                    changed?))))))))))))

    (define (add-text-properties start end properties . args)
      ;; GNU Emacs's `add-text-properties': merge PROPERTIES into the text
      ;; from START to END. A property already there with a different
      ;; value is *replaced*; one that is not there is added; and the rest
      ;; of each interval's plist is left alone.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (add-text-properties-1 start end properties buffer
                               *text-property-replace*)))

    (define (put-text-property start end property value . args)
      ;; GNU Emacs's `put-text-property': set one property, which is
      ;; `add-text-properties' of a one-property plist.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (add-text-properties start end (list property value) buffer)
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

    (define (set-text-properties-1 start end properties buffer i)
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
      (let* ((buffer (if (pair? args) (car args) (current-buffer)))
             (properties (validate-plist properties)))
        (let-values (((i start end)
                      (validate-interval-range buffer start end #t)))
          (if (not i)
              #f
              (begin
                (set-text-properties-1 start end properties buffer i)
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

    (define (remove-text-properties start end properties . args)
      ;; GNU Emacs's `remove-text-properties': take the properties named
      ;; in PROPERTIES off the text from START to END, leaving the others.
      ;; Answers #t when something was actually removed.
      ;;--------------------------------------------------------------
      ;; PROPERTIES is *not* run through `validate-plist': the C does not
      ;; validate it here, precisely so that a list of names with no
      ;; values - which is what callers write - is accepted.
      (let* ((buffer (if (pair? args) (car args) (current-buffer))))
        (let-values (((i start end)
                      (validate-interval-range buffer start end #f)))
          (cond
           ((not i) #f)
           ((null? properties) #f)
           ((not (interval-has-some-properties properties i))
            ;; Nothing on this interval to remove; walk to the next one
            ;; that has something, or give up at the end of the range.
            (let loop ((i (iv:next-interval i))
                       (len (- end start (iv:interval-length i))))
              (cond
               ((not i) #f)
               ((<= len 0) #f)
               ((interval-has-some-properties properties i) #t)
               (else (loop (iv:next-interval i)
                           (- len (iv:interval-length i)))))))
           (else
            ;; The range may begin inside an interval: split it so the
            ;; removal starts on a boundary.
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
                   ((not (interval-has-some-properties properties i)) modified?)
                   ((= (iv:interval-length i) len)
                    (remove-properties properties '() i))
                   (else
                    ;; I has the properties and runs past the end of the
                    ;; range: split it there and remove only from the
                    ;; part inside.
                    (let* ((unchanged i)
                           (piece (iv:split-interval-left unchanged len)))
                      (iv:copy-properties unchanged piece)
                      (remove-properties properties '() piece)))))
                 (else
                  (let ((next (iv:next-interval i))
                        (len (- len (iv:interval-length i))))
                    (loop next len
                          (or (remove-properties properties '() i)
                              modified?))))))))))))
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
      (let* ((buffer (if (pair? args) (car args) (current-buffer)))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (length (text-editor-char-count buffer))
             (end (or limit length)))
        (let ((i (interval-of buffer (min position (max 0 (- length 1))))))
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
      (let* ((buffer (if (pair? args) (car args) (current-buffer)))
             (limit (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (length (text-editor-char-count buffer)))
        (let* ((at (interval-of buffer (min position (max 0 (- length 1)))))
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
                        (<= (iv:interval-last-pos previous) (or limit 0)))
                    limit)
                   (else (iv:interval-last-pos previous)))))))))
    ))
