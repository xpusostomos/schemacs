(define-library (schemacs editor intervals)
  ;; This library mirrors GNU Emacs's `intervals.c`: the interval tree
  ;; that holds text properties, and the operations on it.
  ;;
  ;; An *interval* is a run of characters that share a property list, and
  ;; the tree is a binary search tree of them ordered by position, each
  ;; node also counting the characters in its whole subtree
  ;; (`total-length'), so that the interval containing a position can be
  ;; found by descending once rather than by walking the runs. The tree is
  ;; *balanced by weight* - see `balance-an-interval' - which is not
  ;; red-black or AVL: the invariant is that no rotation can reduce the
  ;; difference between the sizes of a node's two subtrees, and the
  ;; rotations restore that. (So the tree can be deeper than a red-black
  ;; one; nothing observable depends on its shape.)
  ;;
  ;; Two things this library does not carry over from the C, both stated
  ;; where they matter:
  ;;
  ;;  * **Positions are 0-based.** Emacs's interval positions are 1-based
  ;;    for a buffer (`create_root_interval' sets `new->position = BEG',
  ;;    which is 1) and 0-based for a string, because they *are* Lisp
  ;;    buffer positions. This engine indexes characters from 0
  ;;    everywhere - `text-editor-get-cursor' is such an index - so the
  ;;    positions here are 0-based too, which is Emacs's *string*
  ;;    convention. The 1-based conversion belongs to the elisp layer,
  ;;    the same way `point' does, and is not done silently here.
  ;;  * **The sticky bits are not cached.** `set_interval_plist' in the C
  ;;    copies four flags out of the plist onto the struct
  ;;    (`front_sticky', `rear_sticky', `write_protect', `visible') so
  ;;    that the checks in `intervals.h' are a field read rather than a
  ;;    list walk. The flags are always derivable from the plist, and a
  ;;    stale cache is a real bug class in the C (which is why those
  ;;    macros are documented as unreliable); here they are read from the
  ;;    plist each time.
  ;;
  ;; Not ported, with what each would need: `graft_intervals_into_buffer'
  ;; (inserting a string that *carries* properties into a buffer; the
  ;; properties must be on the inserted text already, so nothing here
  ;; needs it yet), `copy_intervals' and `copy_intervals_to_string' (the
  ;; same, for `buffer-substring'), the multibyte conversion
  ;; (`set_intervals_multibyte_1'), and the GC traversal
  ;; (`traverse_intervals', `reproduce_interval' and the rest), a real GC
  ;; having no use for them.
  ;;
  ;; The Lisp-level API over this tree is `(schemacs editor textprop)',
  ;; which mirrors `textprop.c', exactly as in Emacs.
  ;;
  ;; See FACES-PLAN.txt for the plan this library is the first step of.

  (import
    (scheme base)
    (scheme char)
    ;; `symbol-property' is Guile's name for the symbol properties that
    ;; `get' and `put' below are Emacs's names for.
    (only (guile) symbol-property set-symbol-property!)
    (only (schemacs editor engine)
          text-editor-char-count
          text-editor-text-props set!text-editor-text-props))

  (export
   ;; the node
   <interval>
   make<interval>
   interval-type?
   interval-total-length
   interval-position
   interval-left
   interval-right
   interval-up
   interval-plist
   set!interval-total-length
   set!interval-position
   set!interval-left
   set!interval-right
   set!interval-up
   set!interval-plist
   ;; the measured fields, as `intervals.h' spells them
   interval-length
   interval-last-pos
   interval-left-total-length
   interval-right-total-length
   ;; shape tests
   interval-right-child?
   interval-left-child?
   interval-parent?
   interval-left-child-of?
   interval-right-child-of?
   interval-root?
   interval-leaf?
   interval-only?
   interval-both-kids?
   interval-default?
   ;; the tree
   find-interval
   next-interval
   previous-interval
   update-interval
   split-interval-right
   split-interval-left
   merge-interval-right
   merge-interval-left
   delete-interval
   copy-properties
   copy-interval-parent
   balance-an-interval
   balance-possible-root-interval
   balance-intervals
   intervals-equal?
   merge-properties-sticky
   create-root-interval
   ;; the buffer's tree
   buffer-intervals
   set!buffer-intervals
   offset-intervals
   adjust-intervals-for-insertion
   adjust-intervals-for-deletion
   interval-deletion-adjustment
   ;; properties, as this file has them (`textprop.c' has the rest)
   textget
   lookup-char-property
   interval-plist-get
   *text-property-default-nonsticky*
   *char-property-alias-alist*
   *default-text-properties*
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The node

    (define-record-type <interval>
      ;; GNU Emacs's `struct interval' - see `intervals.h'. The fields
      ;; `write_protect', `visible', `front_sticky' and `rear_sticky' are
      ;; not here; they are plist reads, as the header explains.
      ;;--------------------------------------------------------------
      (make<interval> total-length position left right up plist)
      interval-type?
      (total-length interval-total-length set!interval-total-length)
      ;; ^ TOTAL_LENGTH (i): the characters this interval describes plus
      ;; every character in its two subtrees.
      (position     interval-position     set!interval-position)
      ;; ^ The 0-based index of this interval's first character. It is a
      ;; *cache*, and the C is emphatic about when it is valid: it is set
      ;; for the interval `find_interval', `next_interval',
      ;; `previous_interval' and `update_interval' settle on, and is not
      ;; to be relied on for the nodes they passed through on the way.
      (left         interval-left         set!interval-left)
      (right        interval-right        set!interval-right)
      (up           interval-up           set!interval-up)
      ;; ^ The interval holding this one, or - for the root - the object
      ;; the tree belongs to (here a `<text-editor>' from
      ;; `(schemacs editor engine)'), or #f for a tree with no object.
      ;; Emacs has one field and a bit saying which of the two it holds
      ;; (`up.interval' and `up_obj'); the bit is `interval?', tested
      ;; with `interval-parent?' and `interval-object' below.
      (plist        interval-plist        set!interval-plist)
      ;; ^ The property list for this run of characters.
      )

    (define (make-interval)
      ;; GNU Emacs's `make_interval' in `alloc.c': a node with everything
      ;; zeroed and no properties. The callers below fill it in.
      ;;--------------------------------------------------------------
      (make<interval> 0 0 #f #f #f '()))

    (define (interval-length i)
      ;; LENGTH (i): the characters I describes itself, which is its
      ;; whole subtree less its two children's.
      ;;--------------------------------------------------------------
      (- (interval-total-length i)
         (interval-right-total-length i)
         (interval-left-total-length i)))

    (define (interval-left-total-length i)
      ;; LEFT_TOTAL_LENGTH (i), which is 0 for a missing left child.
      ;;--------------------------------------------------------------
      (let ((left (interval-left i))) (if left (interval-total-length left) 0)))

    (define (interval-right-total-length i)
      ;; RIGHT_TOTAL_LENGTH (i).
      ;;--------------------------------------------------------------
      (let ((right (interval-right i))) (if right (interval-total-length right) 0)))

    (define (interval-last-pos i)
      ;; INTERVAL_LAST_POS (i): the position just past I's last
      ;; character. Needs I's position cache to be valid.
      ;;--------------------------------------------------------------
      (+ (interval-position i) (interval-length i)))

    (define (interval-right-child? i) (and (interval-right i) #t))
    (define (interval-left-child? i) (and (interval-left i) #t))

    (define (interval-parent? i)
      ;; INTERVAL_HAS_PARENT: `up' holds another interval.
      ;;--------------------------------------------------------------
      (and i (interval-type? (interval-up i)) #t))

    (define (interval-object i)
      ;; The object a root interval belongs to, or #f. Emacs's
      ;; INTERVAL_HAS_OBJECT / GET_INTERVAL_OBJECT pair.
      ;;--------------------------------------------------------------
      (let ((up (and i (interval-up i))))
        (if (and up (not (interval-type? up))) up #f)))

    (define (set-interval-object! i object)
      (set!interval-up i object))

    (define (interval-left-child-of? i)
      (let ((parent (and i (interval-up i))))
        (and (interval-type? parent) (eq? (interval-left parent) i) #t)))

    (define (interval-right-child-of? i)
      (let ((parent (and i (interval-up i))))
        (and (interval-type? parent) (eq? (interval-right parent) i) #t)))

    (define (interval-root? i)
      ;; ROOT_INTERVAL_P: no parent *interval* - an object or nothing is
      ;; not a parent.
      ;;--------------------------------------------------------------
      (not (interval-parent? i)))

    (define (interval-leaf? i)
      (and (not (interval-left i)) (not (interval-right i)) #t))

    (define (interval-only? i)
      (and (interval-root? i) (interval-leaf? i) #t))

    (define (interval-both-kids? i)
      (and (interval-left i) (interval-right i) #t))

    (define (interval-default? i)
      ;; DEFAULT_INTERVAL_P: no interval at all, or one with no
      ;; properties.
      ;;--------------------------------------------------------------
      (or (not i) (null? (interval-plist i))))

    (define (copy-interval-parent target source)
      ;; `copy_interval_parent': TARGET takes SOURCE's parent linkage.
      ;;--------------------------------------------------------------
      (set!interval-up target (interval-up source))
      target)

    (define (copy-properties source target)
      ;; GNU Emacs's `copy_properties': TARGET's properties become
      ;; SOURCE's, copied so that later changes to one do not show in the
      ;; other.
      ;;--------------------------------------------------------------
      (if (and (interval-default? source) (interval-default? target))
          target
          (set!interval-plist target (list-copy (interval-plist source))))
      target)

    ;;----------------------------------------------------------------
    ;; Properties, which `intervals.c' keeps here
    ;;
    ;; `textget' and its helper are `intervals.c''s in Emacs (line 1706)
    ;; even though they are about properties rather than about the tree,
    ;; which is why they are here too: `merge_properties_sticky' below
    ;; needs them, and there is no ordering in which `textprop.c' could
    ;; supply them.

    (define *default-text-properties*
      ;; GNU Emacs's `default-text-properties': property values seen for
      ;; every character that has no value of its own.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *char-property-alias-alist*
      ;; GNU Emacs's `char-property-alias-alist': a property that stands
      ;; for others when it is absent.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define (get symbol property)
      ;; GNU Emacs's `get': the value of a *symbol* property. This is not
      ;; the same thing as a text property - it is how a `category' symbol
      ;; carries the properties its text shares - and Emacs keeps `get'
      ;; and `put' in `fns.c' rather than here. They are defined here for
      ;; now, because `textget' below is their only caller in the ported
      ;; code so far; they move to `fns.sld' when the elisp layer grows
      ;; one, and this definition goes with them.
      ;;--------------------------------------------------------------
      (symbol-property symbol property))

    (define (put symbol property value)
      ;; GNU Emacs's `put'.
      ;;--------------------------------------------------------------
      (set-symbol-property! symbol property value)
      value)

    (define (plist-member plist prop)
      ;; GNU Emacs's `plist-member' in `fns.c': the tail of PLIST that
      ;; starts at PROP, or #f. `interval-plist-get' cannot answer this,
      ;; because a property that is present with the value #f would look
      ;; absent - and `merge_properties_sticky' needs to know the
      ;; difference, which is exactly the difference between "the left
      ;; side has this property with a nil value" and "the left side does
      ;; not have it".
      ;;--------------------------------------------------------------
      (let loop ((tail plist))
        (cond ((not (pair? tail)) #f)
              ((not (pair? (cdr tail))) #f)
              ((eq? (car tail) prop) tail)
              (else (loop (cddr tail))))))

    (define (interval-plist-get plist prop)
      ;; `plist_get': the value of PROP in PLIST, or #f.
      ;;--------------------------------------------------------------
      (let loop ((tail plist))
        (cond ((null? tail) #f)
              ((null? (cdr tail)) #f)
              ((eq? (car tail) prop) (cadr tail))
              (else (loop (cddr tail))))))

    (define (lookup-char-property plist prop textprop?)
      ;; GNU Emacs's `lookup_char_property': PROP's value, or - when PROP
      ;; is absent - the value the plist's `category' symbol carries for
      ;; it, then an alias, then the default value.
      ;;
      ;; The `category' rule is what lets a whole class of text share
      ;; properties by naming a symbol once.
      ;;--------------------------------------------------------------
      (let loop ((tail plist) (fallback #f))
        (cond
         ((or (null? tail) (null? (cdr tail)))
          (cond
           (fallback fallback)
           (else
            (let ((alias (assq prop (*char-property-alias-alist*))))
              ;; no alias entry means an empty list of alternatives,
              ;; not a #f to take the cdr of
              (let aliases ((rest (if alias (cdr alias) '())) (found #f))
                (cond
                 (found found)
                 ((null? rest)
                  (if (and textprop? (pair? (*default-text-properties*)))
                      (interval-plist-get (*default-text-properties*) prop)
                      #f))
                 (else (aliases (cdr rest)
                                (interval-plist-get plist (car rest))))))))))
         ((eq? (car tail) prop) (cadr tail))
         (else
          (loop (cddr tail)
                (let ((sym (cadr tail)))
                  (if (and (eq? (car tail) 'category) (symbol? sym))
                      (let ((v (get sym prop))) (or v fallback))
                      fallback)))))))

    (define (textget plist prop)
      ;; GNU Emacs's `textget'.
      ;;--------------------------------------------------------------
      (lookup-char-property plist prop #t))

    ;;----------------------------------------------------------------
    ;; Balancing
    ;;
    ;; By weight, not by height: Emacs makes no promise about the depth of
    ;; the tree, only that no rotation would bring the two subtrees'
    ;; sizes closer together.

    (define (rotate-right A)
      ;; GNU Emacs's `rotate_right'. B is A's left child; B becomes the
      ;; parent and A B's right child, and B's right child c becomes A's
      ;; left child:
      ;;
      ;;       A            B
      ;;      / \          / \
      ;;     B   ->       c   A
      ;;    / \              / \
      ;;   c                ...
      ;;--------------------------------------------------------------
      (let* ((B (interval-left A))
             (c (interval-right B))
             (old-total (interval-total-length A)))
        ;; Deal with any parent of A: make it point to B.
        (unless (interval-root? A)
          (if (interval-left-child-of? A)
              (set!interval-left (interval-up A) B)
              (set!interval-right (interval-up A) B)))
        (copy-interval-parent B A)
        ;; Make B the parent of A.
        (set!interval-right B A)
        (set!interval-up A B)
        ;; Make A point to c.
        (set!interval-left A c)
        (when c (set!interval-up c A))
        ;; A's total length is decreased by the length of B and its left
        ;; child - which is C, the child saved before the reassignment
        ;; below. Reading B's right child *here* would read A, which has
        ;; just become it, and the arithmetic would then never settle.
        (set!interval-total-length
         A (- (interval-total-length A)
              (- (interval-total-length B)
                 (if c (interval-total-length c) 0))))
        ;; B must have the same total length A had.
        (set!interval-total-length B old-total)
        B))

    (define (rotate-left A)
      ;; GNU Emacs's `rotate_left', the mirror of `rotate-right'.
      ;;--------------------------------------------------------------
      (let* ((B (interval-right A))
             (c (interval-left B))
             (old-total (interval-total-length A)))
        (unless (interval-root? A)
          (if (interval-left-child-of? A)
              (set!interval-left (interval-up A) B)
              (set!interval-right (interval-up A) B)))
        (copy-interval-parent B A)
        (set!interval-left B A)
        (set!interval-up A B)
        (set!interval-right A c)
        (when c (set!interval-up c A))
        ;; C is B's *old* left child, saved above - see the same note in
        ;; `rotate-right'.
        (set!interval-total-length
         A (- (interval-total-length A)
              (- (interval-total-length B)
                 (if c (interval-total-length c) 0))))
        (set!interval-total-length B old-total)
        B))

    (define (balance-an-interval i)
      ;; GNU Emacs's `balance_an_interval': rotate I while a rotation
      ;; would make its two subtrees' sizes more nearly equal. The test is
      ;; "would the difference after the rotation be smaller than the
      ;; difference now", which is why this is not a height rule.
      ;;--------------------------------------------------------------
      (let loop ((i i))
        (let ((old-diff (- (interval-left-total-length i)
                           (interval-right-total-length i))))
          (cond
           ((> old-diff 0)
            ;; Since the left child is longer, there must be one.
            (let* ((left (interval-left i))
                   (new-diff (- (+ (- (interval-total-length i)
                                      (interval-total-length left))
                                   (interval-right-total-length left))
                                (interval-left-total-length left))))
              (if (>= (abs new-diff) old-diff)
                  i
                  (let ((rotated (rotate-right i)))
                    (balance-an-interval (interval-right rotated))
                    (loop rotated)))))
           ((< old-diff 0)
            (let* ((right (interval-right i))
                   (new-diff (- (+ (- (interval-total-length i)
                                      (interval-total-length right))
                                   (interval-left-total-length right))
                                (interval-right-total-length right))))
              (if (>= (abs new-diff) (- old-diff))
                  i
                  (let ((rotated (rotate-left i)))
                    (balance-an-interval (interval-left rotated))
                    (loop rotated)))))
           (else i)))))

    (define (balance-possible-root-interval interval)
      ;; GNU Emacs's `balance_possible_root_interval': balance INTERVAL,
      ;; and put the result back in whatever holds it when that is an
      ;; object rather than another interval - a rotation changes which
      ;; node is the root.
      ;;--------------------------------------------------------------
      (cond
       ((interval-object interval)
        (let* ((owner (interval-object interval))
               (balanced (balance-an-interval interval)))
          (set-interval-object! balanced owner)
          ;; The rotation may have made a different node the root, so the
          ;; object has to be told which one it is now - the C's
          ;; `set_buffer_intervals (XBUFFER (parent), interval)'. Without
          ;; this the buffer goes on pointing at the old root, and every
          ;; later lookup starts from the wrong node.
          (set!buffer-intervals owner balanced)
          balanced))
       ((not (interval-parent? interval)) interval)
       (else (balance-an-interval interval))))

    (define (balance-intervals-internal tree)
      ;; GNU Emacs's `balance_intervals_internal': balance within each
      ;; side, then balance the node.
      ;;--------------------------------------------------------------
      (when (interval-left tree)
        (balance-intervals-internal (interval-left tree)))
      (when (interval-right tree)
        (balance-intervals-internal (interval-right tree)))
      (balance-an-interval tree))

    (define (balance-intervals tree)
      ;; GNU Emacs's `balance_intervals'.
      ;;--------------------------------------------------------------
      (if tree (balance-intervals-internal tree) #f))

    ;;----------------------------------------------------------------
    ;; Splitting

    (define (split-interval-right interval offset)
      ;; GNU Emacs's `split_interval_right': INTERVAL keeps its first
      ;; OFFSET characters and a new interval takes the rest, which is
      ;; returned. The new interval has no properties: the caller decides
      ;; what they should be (`copy_properties' is the usual answer).
      ;;--------------------------------------------------------------
      (let* ((new (make-interval))
             (position (interval-position interval))
             (new-length (- (interval-length interval) offset)))
        (set!interval-position new (+ position offset))
        (set!interval-up new interval)
        (if (not (interval-right interval))
            (begin
              (set!interval-right interval new)
              (set!interval-total-length new new-length))
            ;; Insert the new node between INTERVAL and its right child.
            (begin
              (set!interval-right new (interval-right interval))
              (set!interval-up (interval-right interval) new)
              (set!interval-right interval new)
              (set!interval-total-length
               new (+ new-length (interval-total-length (interval-right new))))
              (balance-an-interval new)))
        (balance-possible-root-interval interval)
        new))

    (define (split-interval-left interval offset)
      ;; GNU Emacs's `split_interval_left': a new interval takes
      ;; INTERVAL's first OFFSET characters and is returned; INTERVAL
      ;; keeps the rest.
      ;;--------------------------------------------------------------
      (let* ((new (make-interval))
             (new-length offset))
        (set!interval-position new (interval-position interval))
        (set!interval-position interval (+ (interval-position interval) offset))
        (set!interval-up new interval)
        (if (not (interval-left interval))
            (begin
              (set!interval-left interval new)
              (set!interval-total-length new new-length))
            (begin
              (set!interval-left new (interval-left interval))
              (set!interval-up (interval-left new) new)
              (set!interval-left interval new)
              (set!interval-total-length
               new (+ new-length (interval-total-length (interval-left new))))
              (balance-an-interval new)))
        (balance-possible-root-interval interval)
        new))

    ;;----------------------------------------------------------------
    ;; Finding

    (define (interval-start-pos source)
      ;; GNU Emacs's `interval_start_pos'. Emacs answers 1 for a buffer
      ;; and 0 for a string, because that is where a buffer's positions
      ;; start; ours are 0-based for both, as the header explains.
      ;;--------------------------------------------------------------
      (if (interval-object source) 0 0))

    (define (find-interval tree position)
      ;; GNU Emacs's `find_interval': the interval containing POSITION.
      ;; A position at the end of the tree gives the interval holding the
      ;; last character.
      ;;
      ;; RELATIVE-POSITION is the distance from the left edge of the
      ;; subtree being looked at down to POSITION, and it is *reduced* on
      ;; the way down when the search goes right - which is what makes
      ;; this a single descent rather than a walk of the runs.
      ;;--------------------------------------------------------------
      (if (not tree)
          #f
          (let ((position (- position (interval-start-pos tree))))
            (let loop ((tree (balance-possible-root-interval tree))
                       (relative position))
              (cond
               ((< relative (interval-left-total-length tree))
                (loop (interval-left tree) relative))
               ((and (interval-right tree)
                     (>= relative
                         (- (interval-total-length tree)
                            (interval-right-total-length tree))))
                (loop (interval-right tree)
                      (- relative
                         (- (interval-total-length tree)
                            (interval-right-total-length tree)))))
               (else
                ;; Settled. `(- position relative)' is the absolute
                ;; position of the left edge of the subtree we are
                ;; standing on, since RELATIVE was reduced by exactly the
                ;; amount each step to the right moved that edge; adding
                ;; the left subtree's size gives this interval's own
                ;; first character.
                (set!interval-position
                 tree (+ (- position relative) (interval-left-total-length tree)))
                tree))))))

    (define (next-interval interval)
      ;; GNU Emacs's `next_interval': the interval after INTERVAL, with
      ;; its position cache set.
      ;;--------------------------------------------------------------
      (if (not interval)
          #f
          (let ((next-position (+ (interval-position interval)
                                  (interval-length interval))))
            (let ((i interval))
              (if (interval-right i)
                  (let loop ((i (interval-right i)))
                    (if (interval-left i)
                        (loop (interval-left i))
                        (begin (set!interval-position i next-position) i)))
                  (let loop ((i i))
                    (cond
                     ((not (interval-parent? i)) #f)
                     ((interval-left-child-of? i)
                      (let ((parent (interval-up i)))
                        (set!interval-position parent next-position)
                        parent))
                     (else (loop (interval-up i))))))))))

    (define (previous-interval interval)
      ;; GNU Emacs's `previous_interval'.
      ;;--------------------------------------------------------------
      (if (not interval)
          #f
          (if (interval-left interval)
              (let loop ((i (interval-left interval)))
                (if (interval-right i)
                    (loop (interval-right i))
                    (begin (set!interval-position
                            i (- (interval-position interval) (interval-length i)))
                           i)))
              (let loop ((i interval))
                (cond
                 ((not (interval-parent? i)) #f)
                 ((interval-right-child-of? i)
                  (let ((parent (interval-up i)))
                    (set!interval-position
                     parent (- (interval-position interval) (interval-length parent)))
                    parent))
                 (else (loop (interval-up i))))))))

    (define (set-parent-position! i)
      ;; SET_PARENT_POSITION (i): keep I's parent's position cache in step
      ;; with I's.
      ;;--------------------------------------------------------------
      (let ((parent (interval-up i)))
        (if (interval-left-child-of? i)
            (set!interval-position
             parent (+ (interval-position i)
                       (interval-total-length i)
                       (- (interval-left-total-length i))))
            (set!interval-position
             parent (- (interval-position i)
                       (interval-left-total-length i)
                       (interval-length parent))))))

    (define (update-interval i pos)
      ;; GNU Emacs's `update_interval': the interval containing POS,
      ;; given some interval I of the same tree whose position cache is
      ;; right. The caches of the nodes walked through are corrected as it
      ;; goes.
      ;;--------------------------------------------------------------
      (if (not i)
          #f
          (let loop ((i i))
            (cond
             ((< pos (interval-position i))
              (cond
               ((>= pos (- (interval-position i) (interval-left-total-length i)))
                (let ((left (interval-left i)))
                  (set!interval-position
                   left (- (interval-position i)
                           (interval-total-length left)
                           (- (interval-left-total-length left))))
                  (loop left)))
               ((not (interval-parent? i))
                (error "Point before start of properties"))
               (else (set-parent-position! i) (loop (interval-up i)))))
             ((>= pos (interval-last-pos i))
              (cond
               ((< pos (+ (interval-last-pos i) (interval-right-total-length i)))
                (let ((right (interval-right i)))
                  (set!interval-position
                   right (+ (interval-last-pos i) (interval-left-total-length right)))
                  (loop right)))
               ((not (interval-parent? i))
                (error "Point after end of properties"))
               (else (set-parent-position! i) (loop (interval-up i)))))
             (else i)))))

    ;;----------------------------------------------------------------
    ;; Deleting

    (define (delete-node i)
      ;; GNU Emacs's `delete_node': remove I from its tree by merging its
      ;; two subtrees into one, and return the subtree that should take
      ;; I's place. The caller puts it in I's parent. The left subtree is
      ;; hung off the leftmost node of the right one, which is the
      ;; cheapest place to put it and keeps the order.
      ;;--------------------------------------------------------------
      (cond
       ((not (interval-left i)) (interval-right i))
       ((not (interval-right i)) (interval-left i))
       (else
        (let* ((migrate (interval-left i))
               (migrate-amt (interval-total-length migrate)))
          (set!interval-total-length
           (interval-right i)
           (+ (interval-total-length (interval-right i)) migrate-amt))
          (let loop ((this (interval-right i)))
            (if (interval-left this)
                (begin
                  (set!interval-total-length
                   (interval-left this)
                   (+ (interval-total-length (interval-left this)) migrate-amt))
                  (loop (interval-left this)))
                (begin
                  (set!interval-left this migrate)
                  (set!interval-up migrate this)
                  (interval-right i))))))))

    (define (delete-interval i)
      ;; GNU Emacs's `delete_interval': take I out of the tree. I is
      ;; presumed already empty - no adjustment is made for its length.
      ;;--------------------------------------------------------------
      (if (interval-root? i)
          (let* ((owner (interval-object i))
                 (parent (delete-node i)))
            (when parent (set-interval-object! parent owner))
            (when owner (set!buffer-intervals owner parent)))
          (let ((parent (interval-up i)))
            (if (interval-left-child-of? i)
                (begin
                  (set!interval-left parent (delete-node i))
                  (when (interval-left parent)
                    (set!interval-up (interval-left parent) parent)))
                (begin
                  (set!interval-right parent (delete-node i))
                  (when (interval-right parent)
                    (set!interval-up (interval-right parent) parent)))))))

    (define (interval-deletion-adjustment tree from amount)
      ;; GNU Emacs's `interval_deletion_adjustment': delete as much of
      ;; AMOUNT as this subtree can spare, starting FROM characters into
      ;; it, and answer how much was really deleted. An interval emptied
      ;; by this leaves the tree.
      ;;--------------------------------------------------------------
      (if (not tree)
          0
          (cond
           ;; Left branch.
           ((< from (interval-left-total-length tree))
            (let ((subtract (interval-deletion-adjustment
                             (interval-left tree) from amount)))
              (set!interval-total-length
               tree (- (interval-total-length tree) subtract))
              subtract))
           ;; Right branch.
           ((>= from (- (interval-total-length tree)
                        (interval-right-total-length tree)))
            (let ((subtract
                   (interval-deletion-adjustment
                    (interval-right tree)
                    (- from (- (interval-total-length tree)
                               (interval-right-total-length tree)))
                    amount)))
              (set!interval-total-length
               tree (- (interval-total-length tree) subtract))
              subtract))
           ;; Here: this node.
           (else
            (let* ((my-amount (- (- (interval-total-length tree)
                                    (interval-right-total-length tree))
                                 from))
                   (amount (if (> amount my-amount) my-amount amount)))
              (set!interval-total-length
               tree (- (interval-total-length tree) amount))
              (when (= 0 (interval-length tree))
                (delete-interval tree))
              amount)))))

    (define (adjust-intervals-for-deletion buffer start length)
      ;; GNU Emacs's `adjust_intervals_for_deletion': LENGTH characters
      ;; at START are gone from BUFFER.
      ;;
      ;; Each pass deletes what it can from one interval and then starts
      ;; again from the root, because an interval emptied on the way may
      ;; have taken the node the walk was standing on with it.
      ;;--------------------------------------------------------------
      (let ((tree (buffer-intervals buffer)))
        (if (not tree)
            #f
            (if (= length (interval-total-length tree))
                (set!buffer-intervals buffer #f)
                (if (interval-only? tree)
                    (set!interval-total-length
                     tree (- (interval-total-length tree) length))
                    (let ((start (min start (interval-total-length tree))))
                      (let loop ((left-to-delete length))
                        (when (> left-to-delete 0)
                          (let* ((deleted (interval-deletion-adjustment
                                           tree start left-to-delete))
                                 (tree (buffer-intervals buffer)))
                            (set! left-to-delete (- left-to-delete deleted))
                            (if (and tree (= left-to-delete
                                             (interval-total-length tree)))
                                (set!buffer-intervals buffer #f)
                                (loop left-to-delete)))))))))))

    (define (merge-interval-right i)
      ;; GNU Emacs's `merge_interval_right': I is absorbed by its
      ;; successor, which is returned and which keeps its own properties.
      ;; The caller must know I is not the rightmost interval.
      ;;--------------------------------------------------------------
      (let ((absorb (interval-length i)))
        (if (interval-right i)
            ;; It is below us: add ABSORB as we descend.
            (let loop ((successor (interval-right i)))
              (if (interval-left successor)
                  (begin
                    (set!interval-total-length
                     successor (+ (interval-total-length successor) absorb))
                    (loop (interval-left successor)))
                  (begin
                    (set!interval-total-length
                     successor (+ (interval-total-length successor) absorb))
                    (delete-interval i)
                    successor)))
            ;; Zero this interval out, then climb until we are a left
            ;; child.
            (begin
              (set!interval-total-length
               i (- (interval-total-length i) absorb))
              (let loop ((successor i))
                (cond
                 ((not (interval-parent? successor))
                  (error "merge-interval-right: the last interval"))
                 ((interval-left-child-of? successor)
                  (let ((parent (interval-up successor)))
                    (delete-interval i)
                    parent))
                 (else
                  (let ((parent (interval-up successor)))
                    (set!interval-total-length
                     parent (- (interval-total-length parent) absorb))
                    (loop parent)))))))))

    (define (merge-interval-left i)
      ;; GNU Emacs's `merge_interval_left': I is absorbed by its
      ;; predecessor, which is returned.
      ;;--------------------------------------------------------------
      (let ((absorb (interval-length i)))
        (if (interval-left i)
            (let loop ((predecessor (interval-left i)))
              (if (interval-right predecessor)
                  (begin
                    (set!interval-total-length
                     predecessor (+ (interval-total-length predecessor) absorb))
                    (loop (interval-right predecessor)))
                  (begin
                    (set!interval-total-length
                     predecessor (+ (interval-total-length predecessor) absorb))
                    (delete-interval i)
                    predecessor)))
            (begin
              (set!interval-total-length
               i (- (interval-total-length i) absorb))
              (let loop ((predecessor i))
                (cond
                 ((not (interval-parent? predecessor))
                  (error "merge-interval-left: the first interval"))
                 ((interval-right-child-of? predecessor)
                  (let ((parent (interval-up predecessor)))
                    (delete-interval i)
                    parent))
                 (else
                  (let ((parent (interval-up predecessor)))
                    (set!interval-total-length
                     parent (- (interval-total-length parent) absorb))
                    (loop parent)))))))))

    ;;----------------------------------------------------------------
    ;; Comparing

    (define (intervals-equal-1 i0 i1 use-equal?)
      ;; GNU Emacs's `intervals_equal_1': whether two intervals carry the
      ;; same properties, whatever order the plists are in, comparing
      ;; values with `equal?' or `eq?'.
      ;;--------------------------------------------------------------
      (cond
       ((and (interval-default? i0) (interval-default? i1)) #t)
       ((or (interval-default? i0) (interval-default? i1)) #f)
       (else
        (let loop ((i0-cdr (interval-plist i0)) (i1-cdr (interval-plist i1)))
          (cond
           ((not (and (pair? i0-cdr) (pair? i1-cdr)))
            (and (null? i0-cdr) (null? i1-cdr)))
           (else
            (let* ((i0-sym (car i0-cdr))
                   (i0-cdr (cdr i0-cdr)))
              (if (not (pair? i0-cdr))
                  #f
                  (let find ((i1-val (interval-plist i1)))
                    (cond
                     ((null? i1-val) #f)
                     ((eq? (car i1-val) i0-sym)
                      (let ((i1-val (cdr i1-val)))
                        (cond
                         ((not (pair? i1-val)) #f)
                         ((if use-equal?
                              (not (equal? (car i1-val) (car i0-cdr)))
                              (not (eq? (car i1-val) (car i0-cdr))))
                          #f)
                         (else
                          (let ((i1-cdr (cdr i1-cdr)))
                            (if (not (pair? i1-cdr))
                                #f
                                (loop (cdr i0-cdr) (cdr i1-cdr))))))))
                     (else
                      (let ((i1-val (cdr i1-val)))
                        (if (not (pair? i1-val)) #f (find (cdr i1-val)))))))))))))))

    (define (intervals-equal? i0 i1)
      ;; GNU Emacs's `intervals_equal'.
      ;;--------------------------------------------------------------
      (intervals-equal-1 i0 i1 #f))

    ;;----------------------------------------------------------------
    ;; Inheriting on insertion

    (define *text-property-default-nonsticky*
      ;; GNU Emacs's `text-property-default-nonsticky': an alist saying,
      ;; per property, how it behaves when text is inserted beside it.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define (tmem sym set)
      ;; The C's TMEM: a list means membership, and anything else - `t'
      ;; in particular - means every property.
      ;;--------------------------------------------------------------
      (if (pair? set) (and (memq sym set) #t) (and set #t)))

    (define (default-nonsticky sym)
      ;; The `text-property-default-nonsticky' entry for SYM, or #f: a
      ;; pair whose cdr says whether the property is non-sticky by
      ;; default.
      ;;--------------------------------------------------------------
      (assq sym (*text-property-default-nonsticky*)))

    (define (nonsticky-by-default? entry sym)
      ;; The `(and (consp tmp) (not (nilp (cdr tmp))))' test, which
      ;; appears three times in the C.
      ;;--------------------------------------------------------------
      (and entry (cdr entry) #t))

    (define (sticky-by-default? entry sym)
      ;; The `(and (consp tmp) (nilp (cdr tmp)))' test.
      ;;--------------------------------------------------------------
      (and entry (not (cdr entry)) #t))

    (define (merge-properties-sticky pleft pright)
      ;; GNU Emacs's `merge_properties_sticky': the properties that text
      ;; inserted *between* two runs should have.
      ;;
      ;; Each property is inherited from whichever side has a sticky face
      ;; turned towards the insertion point: from the left unless the left
      ;; is `rear-nonsticky' for it, from the right if the right is
      ;; `front-sticky' for it. When both sides offer it, the non-nil
      ;; value wins, and the left wins a tie. Inheriting a property
      ;; inherits its stickiness as well, which is what makes the next
      ;; insertion beside the new text behave the same way again.
      ;;
      ;; The C walks PRIGHT and then PLEFT with the same body twice, the
      ;; second time knowing the property is not in PRIGHT; this is the
      ;; same two walks written out, because the second one's conditions
      ;; are simpler rather than identical.
      ;;--------------------------------------------------------------
      (let ((lfront (textget pleft 'front-sticky))
            (lrear  (textget pleft 'rear-nonsticky))
            (rfront (textget pright 'front-sticky))
            (rrear  (textget pright 'rear-nonsticky)))

        ;; Walk PRIGHT: every property it has is offered to the insertion.
        (let right-loop ((tail pright) (props '()) (front '()) (rear '()))
          (if (null? tail)
              ;; Walk PLEFT for the properties PRIGHT did not have.
              (let left-loop ((tail pleft) (props props)
                              (front front) (rear rear))
                (if (null? tail)
                    (let* ((props (reverse props))
                           (props (if (null? rear)
                                      props
                                      (cons 'rear-nonsticky
                                            (cons (reverse rear) props))))
                           (cat (textget props 'category)))
                      ;; A `category' that is itself front-sticky does not
                      ;; need the properties spelled out.
                      (if (and (pair? front)
                               (not (and cat (symbol? cat)
                                         (eq? (get cat 'front-sticky) #t))))
                          (cons 'front-sticky (cons (reverse front) props))
                          props))
                    (let ((sym (car tail)))
                      (cond
                       ((or (eq? sym 'rear-nonsticky) (eq? sym 'front-sticky))
                        (left-loop (cddr tail) props front rear))
                       ;; Already considered in the PRIGHT walk.
                       ((assq sym pright)
                        (left-loop (cddr tail) props front rear))
                       (else
                        (let* ((lval (cadr tail))
                               (entry (default-nonsticky sym)))
                          ;; RVAL is known to be nil here, so the C's
                          ;; two-way test simplifies.
                          (cond
                           ((not (or (tmem sym lrear)
                                     (nonsticky-by-default? entry sym)))
                            (left-loop (cddr tail)
                                       (cons lval (cons sym props))
                                       (if (tmem sym lfront)
                                           (cons sym front)
                                           front)
                                       rear))
                           ((or (tmem sym rfront)
                                (sticky-by-default? entry sym))
                            ;; The value is nil, but the stickiness is
                            ;; still inherited from the right.
                            (left-loop (cddr tail) props
                                       (cons sym front)
                                       (if (tmem sym rrear)
                                           (cons sym rear)
                                           rear)))
                           (else
                            (left-loop (cddr tail) props front rear)))))))))
              (let ((sym (car tail)))
                (cond
                 ((or (eq? sym 'rear-nonsticky) (eq? sym 'front-sticky))
                  (right-loop (cddr tail) props front rear))
                 (else
                  (let* ((rval (cadr tail))
                         (lpair (assq sym pleft))
                         ;; Defined on the right for certain, since we are
                         ;; walking PRIGHT.
                         (lpresent (and lpair #t))
                         (lval (if lpair (cadr lpair) #f))
                         (entry (default-nonsticky sym))
                         (use-left (and lpresent
                                        (not (or (tmem sym lrear)
                                                 (nonsticky-by-default?
                                                  entry sym)))))
                         (use-right (or (tmem sym rfront)
                                        (sticky-by-default? entry sym)))
                         ;; When both sides offer it, a nil value on one
                         ;; side hands the property to the other; the left
                         ;; wins a tie between two non-nil values.
                         (use-left (if (and use-left use-right (not lval))
                                       #f
                                       use-left))
                         (use-right (if (and use-left use-right (not rval))
                                        #f
                                        use-right)))
                    (cond
                     (use-left
                      (right-loop (cddr tail)
                                  (cons lval (cons sym props))
                                  (if (tmem sym lfront)
                                      (cons sym front)
                                      front)
                                  (if (tmem sym lrear)
                                      (cons sym rear)
                                      rear)))
                     (use-right
                      (right-loop (cddr tail)
                                  (cons rval (cons sym props))
                                  (if (tmem sym rfront)
                                      (cons sym front)
                                      front)
                                  (if (tmem sym rrear)
                                      (cons sym rear)
                                      rear)))
                     (else (right-loop (cddr tail) props front rear)))))))))))

    ;;----------------------------------------------------------------
    ;; The buffer's tree

    (define (buffer-intervals buffer)
      ;; GNU Emacs's `buffer_intervals': the root of BUFFER's interval
      ;; tree, or #f when it has none. The slot is the engine's, which is
      ;; where the C keeps it too (`BVAR (buf, intervals)').
      ;;--------------------------------------------------------------
      (text-editor-text-props buffer))

    (define (set!buffer-intervals buffer tree)
      ;; GNU Emacs's `set_buffer_intervals'.
      ;;--------------------------------------------------------------
      (set!text-editor-text-props buffer tree))

    (define (create-root-interval parent)
      ;; GNU Emacs's `create_root_interval': a tree of one interval
      ;; covering all of PARENT, which is the object the tree belongs to.
      ;;--------------------------------------------------------------
      (let ((new (make-interval)))
        (set!interval-total-length new (text-editor-char-count parent))
        (set!interval-position new 0)
        (set!buffer-intervals parent new)
        (set-interval-object! new parent)
        new))

    (define (offset-intervals buffer start length)
      ;; GNU Emacs's `offset_intervals': the tree of BUFFER after LENGTH
      ;; characters have been added at START (LENGTH positive) or removed
      ;; from it (negative). This is the call `insdel.c' makes from every
      ;; insertion and deletion, and the engine makes from beside
      ;; `adjust-markers-for-insertion!' and
      ;; `adjust-markers-for-deletion!', which are the same fact about the
      ;; same edit.
      ;;--------------------------------------------------------------
      (let ((tree (buffer-intervals buffer)))
        (if (or (not tree) (= length 0))
            #f
            (if (> length 0)
                (adjust-intervals-for-insertion tree start length)
                (adjust-intervals-for-deletion buffer start (- length))))))

    (define (adjust-intervals-for-insertion tree position length)
      ;; GNU Emacs's `adjust_intervals_for_insertion': LENGTH characters
      ;; have been inserted at POSITION, so every interval that covers
      ;; them grows, and the new text takes the properties the sticky
      ;; rules say it should.
      ;;
      ;; The hard case is an insertion *between* two runs. The C extends
      ;; the left-hand run over the new text, then splits it again when
      ;; the sticky rules ask for something other than that run's
      ;; properties - which is why the merged property list is computed
      ;; and compared rather than decided up front.
      ;;--------------------------------------------------------------
      (let* ((eobp (>= position (interval-total-length tree)))
                 (position (if eobp (interval-total-length tree) position))
                 (i (find-interval tree position)))

            ;; An insertion in the middle of a run: if any property there
            ;; is one that should not be extended over the new text, the
            ;; run is split at the insertion point first, so that the
            ;; extension happens at a boundary.
            (let ((i (if (or (= position (interval-position i)) eobp)
                         i
                         (let ((rear (textget (interval-plist i) 'rear-nonsticky))
                               (front (textget (interval-plist i) 'front-sticky)))
                           (let ((problem?
                                  (cond
                                   ;; All properties non-sticky: split.
                                   ((and rear (not (pair? rear))) #t)
                                   ;; All properties sticky: do not split.
                                   ((and front (not (pair? front))) #f)
                                   (else
                                    ;; Otherwise, one property at a time.
                                    (let loop ((tail (interval-plist i)))
                                      (cond
                                       ((not (and (pair? tail) (pair? (cdr tail))))
                                        #f)
                                       (else
                                        (let* ((prop (car tail))
                                               (entry (default-nonsticky prop)))
                                          (cond
                                           ((and (pair? front) (memq prop front))
                                            (loop (cddr tail)))
                                           ((and (pair? rear) (memq prop rear))
                                            #t)
                                           ((and entry (cdr entry)) #t)
                                           (else (loop (cddr tail))))))))))))
                             (if problem?
                                 (let ((temp (split-interval-right
                                              i (- position (interval-position i)))))
                                   (copy-properties i temp)
                                   temp)
                                 i))))))

              (if (or (= position (interval-position i)) eobp)
                  ;; Between two runs, or at the very end: extend the
                  ;; left one, then split off what the sticky rules give
                  ;; the new text.
                  (let* ((prev (cond ((= position 0) #f)
                                     (eobp i)
                                     (else (previous-interval i))))
                         (i (if eobp #f i)))
                    (let loop ((temp (if prev prev i)))
                      (when temp
                        (set!interval-total-length
                         temp (+ (interval-total-length temp) length))
                        (let ((balanced (balance-possible-root-interval temp)))
                          (loop (let ((up (interval-up balanced)))
                                  (if (interval-type? up) up #f)))))
                    (let* ((pleft (if prev (interval-plist prev) '()))
                           (pright (if i (interval-plist i) '()))
                           (newplist (merge-properties-sticky pleft pright))
                           (newi (make<interval> 0 0 #f #f #f newplist)))
                      (cond
                       ((not prev)
                        ;; Position 0: a new run at the front.
                        (unless (intervals-equal? i newi)
                          (let ((new (split-interval-left i length)))
                            (set!interval-plist new newplist))))
                       (else
                        (unless (intervals-equal? prev newi)
                          (let ((prev (split-interval-right
                                       prev (- position (interval-position prev)))))
                            (set!interval-plist prev newplist)
                            (when (and i (intervals-equal? prev i))
                              (merge-interval-right prev)))))))))
                  ;; Otherwise: the new text is inside one run, which just
                  ;; grows.
                  (let loop ((temp i))
                    (when temp
                      (set!interval-total-length
                       temp (+ (interval-total-length temp) length))
                      (let ((balanced (balance-possible-root-interval temp)))
                        (loop (let ((up (interval-up balanced)))
                                (if (interval-type? up) up #f)))))))
              tree)))

    ))
