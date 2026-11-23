(define-library (schemacs itree)
  ;; A port of GNU Emacs's `src/itree.c' and `src/itree.h' - the interval
  ;; tree an Emacs 29.1-and-later buffer keeps its overlays in.
  ;;
  ;; The header of the C states the problem it solves, and it is worth
  ;; keeping in view because it is the reason this library exists at all:
  ;;
  ;;   Intervals of the form [BEGIN, END), are stored as nodes inside a
  ;;   RB tree, ordered by BEGIN.  The core operation of this tree
  ;;   (besides insert, remove, etc.) is finding all intervals
  ;;   intersecting with some given interval.  In order to perform this
  ;;   operation efficiently, every node stores a third value called
  ;;   LIMIT.
  ;;
  ;; and, further down, the second operation that a buffer needs:
  ;;
  ;;   Since this data-structure will be used for overlays in an Emacs
  ;;   buffer, a second core operation is the ability to insert and
  ;;   delete gaps in the tree.  This models the insertion and deletion
  ;;   of text in a buffer and the effects it may have on the positions
  ;;   of overlays.
  ;;
  ;; A gap is handled by OFFSET. The offset of a subtree is the amount
  ;; of shift still to be applied to its BEGIN, END and LIMIT values;
  ;; OTICK says whether a node's path to the root still has any offsets
  ;; outstanding. Inserting text after every node becomes "add LENGTH to
  ;; the root's offset", without touching the tree.
  ;;
  ;; **What this replaces here.** Before this library the tree kept its
  ;; overlays in a plain list per buffer, in order by start, with the two
  ;; ends of an overlay being markers: `make-overlay' inserted into the
  ;; list with a linear walk, `delete-overlay' removed with another, and
  ;; `overlays-at' walked the whole list. That is the shape GNU Emacs
  ;; used *before* 29.1 - and the C explains why it was replaced
  ;; (`etc/NEWS.29'): "speed up all the operations that involve
  ;; overlays, especially when there are lots of them in a buffer."
  ;; Isersearch's lazy highlight makes one overlay per match on every
  ;; keystroke, so a buffer with a few hundred `8's in it was quadratic
  ;; in both directions. This is the structure that fixes it.
  ;;
  ;; **Departures, all of them mechanical**:
  ;;
  ;;  - NULL is `#f'; a C struct is a record. The fields have the C's
  ;;    names (`begin', `end', `limit', `offset', `otick', `red',
  ;;    `front-advance', `rear-advance', `data'), with `begin' spelled
  ;;    `beg' in the constructor's parameters because `begin' is syntax
  ;;    in the body of this library.
  ;;
  ;;  - `ptrdiff_t' is a Scheme exact integer; `PTRDIFF_MIN' and
  ;;    `PTRDIFF_MAX' are `*ptrdiff-min*' and `*ptrdiff-max*'. They are
  ;;    sentinels in `limit' arithmetic and are never buffer positions.
  ;;
  ;;  - `eassert' is not carried into the running code: Emacs compiles
  ;;    its own assertions out unless configured with
  ;;    `--enable-checking', and this tree runs in production. The
  ;;    invariant checker itself *is* ported (`itree-check-tree'), for
  ;;    the tests, which is where the C's checking build earns its keep.
  ;;
  ;;  - `itree_stack_destroy' has no counterpart: the nodes are a Scheme
  ;;    vector and Guile's collector frees it. `itree_stack_create' and
  ;;    the push/pop pair are ported because the two gap operations walk
  ;;    with an explicit stack, and `itree_insert_gap' indexes the saved
  ;;    stack (`saved->nodes[i]') rather than popping it.
  ;;
  ;;  - The iterator lives in a record the caller makes
  ;;    (`make<itree-iterator>'), which is the `struct itree_iterator'
  ;;    the C's `ITREE_FOREACH' macro puts on the caller's stack. The
  ;;    macro's `for' loop becomes a named `let' over
  ;;    `itree-iterator-next' at the call sites; `break' is leaving the
  ;;    loop and `continue' is the next turn. `ITREE_FOREACH_NARROW' is
  ;;    `itree-iterator-narrow'.
  ;;
  ;;  - `emacs_abort' for an unknown order is a `case' that signals; the
  ;;    order is a symbol here, not an enum.
  ;;
  ;; Not ported, because nothing in this tree asks for it:
  ;; `itree_insert_gap''s `before_markers' is carried (buffer.c passes
  ;; it), and every other argument and return value is the C's.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    ;; `itree_max_height' is `2 * log (size + 1) / log (2) + 0.5', and
    ;; `log' is `(scheme inexact)''s, not `(scheme base)''s.
    (only (scheme inexact) log))

  (export
   ;; the two sentinels, which callers of the iterators pass as bounds
   *ptrdiff-min* *ptrdiff-max*
   ;; the records
   <itree-node> make<itree-node> itree-node?
   itree-node-parent itree-node-left itree-node-right
   itree-node-begin itree-node-end itree-node-limit
   itree-node-offset itree-node-otick itree-node-data
   itree-node-red itree-node-rear-advance itree-node-front-advance
   set!itree-node-parent set!itree-node-left set!itree-node-right
   set!itree-node-begin set!itree-node-end set!itree-node-limit
   set!itree-node-offset set!itree-node-otick set!itree-node-red
   <itree-tree> make<itree-tree> itree-tree?
   itree-tree-root itree-tree-otick itree-tree-size
   <itree-iterator> make<itree-iterator> itree-iterator?
   ;; `src/itree.h''s API, under the C's names
   itree-node-init
   itree-node-begin-of itree-node-end-of itree-node-set-region
   itree-create itree-destroy itree-empty-p itree-size itree-clear
   itree-insert itree-remove
   itree-insert-gap itree-delete-gap
   itree-iterator-start itree-iterator-narrow itree-iterator-next
   ;; the invariant checker, which the C keeps for its checking build,
   ;; and `itree_contains' - static in the C, and exported here because
   ;; the C's own tests include `itree.c' to reach it.
   itree-check-tree
   itree-contains
   itree-max-height
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The sentinels - `PTRDIFF_MIN' and `PTRDIFF_MAX'
    ;;------------------------------------------------------------------
    ;;
    ;; The C's pointers are 64 bits on this platform, and the two
    ;; constants are used as "less than any position" and "greater than
    ;; any position" in `limit' arithmetic. The exact bit width does not
    ;; matter as long as both are beyond any buffer; `2^62' is the
    ;; midpoint of a signed 64-bit range and can be neither overflowed
    ;; nor reached by a buffer position.
    (define *ptrdiff-min* (- (expt 2 62)))
    (define *ptrdiff-max* (expt 2 62))

    ;;----------------------------------------------------------------
    ;; The records - `struct itree_node', `struct itree_tree', and the
    ;; two the C keeps beside them
    ;;------------------------------------------------------------------

    (define-record-type <itree-node>
      (make<itree-node> parent left right beg end limit offset otick
                        data red rear-advance front-advance)
      itree-node?
      ;; The normal parent, left and right links found in binary trees.
      ;; See also `red', below, which completes the Red-Black tree
      ;; representation.
      (parent itree-node-parent set!itree-node-parent)
      (left   itree-node-left   set!itree-node-left)
      (right  itree-node-right  set!itree-node-right)
      ;; BEGIN and END are buffer positions describing the range. When a
      ;; node is in a tree these fields are read only, written only by
      ;; itree functions.
      (beg    itree-node-begin  set!itree-node-begin)
      (end    itree-node-end    set!itree-node-end)
      ;; LIMIT is a buffer position, the maximum of END of this node and
      ;; its children. OFFSET is in buffer position units, and will be
      ;; non-zero only when the node is dirty. OTICK determines whether
      ;; BEGIN, END, LIMIT and OFFSET are considered dirty.
      (limit  itree-node-limit  set!itree-node-limit)
      (offset itree-node-offset set!itree-node-offset)
      (otick  itree-node-otick  set!itree-node-otick)
      ;; Exclusively used by the client: an overlay here.
      (data   itree-node-data   set!itree-node-data)
      (red    itree-node-red    set!itree-node-red)
      ;; Same as for marker and overlays.
      (rear-advance  itree-node-rear-advance  set!itree-node-rear-advance)
      (front-advance itree-node-front-advance set!itree-node-front-advance))

    (define-record-type <itree-tree>
      (make<itree-tree> root otick size)
      itree-tree?
      (root  itree-tree-root  set!itree-tree-root)
      ;; offset tick, compared with node's otick
      (otick itree-tree-otick set!itree-tree-otick)
      ;; Number of nodes in the tree.
      (size  itree-tree-size  set!itree-tree-size))

    ;; State used when iterating intervals: `struct itree_iterator'.
    (define-record-type <itree-iterator>
      (make<itree-iterator> node beg end otick order)
      itree-iterator?
      ;; Beware: the `node' field always holds "the next" node to
      ;; consider, so it is always "one node ahead" of what the iterator
      ;; loop sees. `delete_all_overlays' depends on that detail: it
      ;; modifies the current node knowing the iterator will not need it
      ;; again.
      (node  itree-iterator-node  set!itree-iterator-node)
      (beg   itree-iterator-beg   set!itree-iterator-beg)
      (end   itree-iterator-end   set!itree-iterator-end)
      (otick itree-iterator-otick set!itree-iterator-otick)
      (order itree-iterator-order set!itree-iterator-order))

    ;;----------------------------------------------------------------
    ;; The stack - `struct itree_stack', a simple dynamic array with
    ;; stack semantics
    ;;------------------------------------------------------------------

    (define-record-type <itree-stack>
      (make<itree-stack> nodes size length)
      itree-stack?
      (nodes  itree-stack-nodes  set!itree-stack-nodes)
      (size   itree-stack-size   set!itree-stack-size)
      (length itree-stack-length set!itree-stack-length))

    (define (itree-stack-create initial-size)
      ;; `itree_stack_create' (`itree.c:144'): "This is just a simple
      ;; dynamic array with stack semantics."
      ;;--------------------------------------------------------------
      (let ((size (max 0 initial-size)))
        (make<itree-stack> (make-vector size #f) size 0)))

    (define (itree-stack-ensure-space stack nelements)
      ;; `itree_stack_ensure_space' (`itree.c:164'): `(nelements + 1) * 2'.
      ;;
      ;; The C reallocates and keeps what was there; the vector is copied
      ;; across, `length' elements wide - the slots past that are unset
      ;; in both.
      ;;--------------------------------------------------------------
      (when (> nelements (itree-stack-size stack))
        (let* ((new-size (* (+ nelements 1) 2))
               (old (itree-stack-nodes stack))
               (new (make-vector new-size #f)))
          (let loop ((i 0))
            (when (< i (itree-stack-length stack))
              (vector-set! new i (vector-ref old i))
              (loop (+ i 1))))
          (set!itree-stack-nodes stack new)
          (set!itree-stack-size stack new-size))))

    (define (itree-stack-push stack node)
      ;; `itree_stack_push' (`itree.c:177').
      ;;--------------------------------------------------------------
      (itree-stack-ensure-space stack (+ (itree-stack-length stack) 1))
      (vector-set! (itree-stack-nodes stack)
                   (itree-stack-length stack)
                   node)
      (set!itree-stack-length stack (+ (itree-stack-length stack) 1)))

    (define (itree-stack-pop stack)
      ;; `itree_stack_pop' (`itree.c:187'): "answers NULL when empty".
      ;;--------------------------------------------------------------
      (if (= (itree-stack-length stack) 0)
          #f
          (begin
            (set!itree-stack-length stack (- (itree-stack-length stack) 1))
            (vector-ref (itree-stack-nodes stack)
                        (itree-stack-length stack)))))

    ;;----------------------------------------------------------------
    ;; The invariant checker - `itree_max_height', `check_subtree' and
    ;; `check_tree'
    ;;------------------------------------------------------------------
    ;;
    ;; The C runs these under `eassert', which is nothing unless Emacs is
    ;; configured with `--enable-checking=yes,overlays'. They are ported
    ;; because the tests want them: a red-black tree with an offset
    ;; scheme is exactly the kind of code that is wrong only sometimes,
    ;; and a random-operation test that checks the invariants is what
    ;; catches the some-times.
    (define (itree-max-height tree)
      ;; `itree_max_height' (`itree.c:198'): "2 * log (tree->size + 1) /
      ;; log (2) + 0.5", truncated to an int by the C's return type.
      ;;--------------------------------------------------------------
      (exact (truncate (+ (* 2 (/ (log (+ (itree-tree-size tree) 1))
                                  (log 2)))
                          0.5))))

    (define-record-type <check-subtree-result>
      (make-check-subtree-result size limit black-height)
      check-subtree-result?
      ;; Node count of the tree.
      (size         check-subtree-result-size)
      ;; Limit of the tree (max END).
      (limit        check-subtree-result-limit)
      ;; Black height of the tree.
      (black-height check-subtree-result-black-height))

    (define (%itree-assert what)
      ;; The C's `eassert', for the checker: it raises rather than
      ;; aborting, so a test names the invariant that broke.
      ;;--------------------------------------------------------------
      (error "itree: invariant violated:" what))

    (define (check-subtree node check-red-black-invariants tree-otick
                           offset min-begin max-begin)
      ;; `check_subtree' (`itree.c:216').
      ;;--------------------------------------------------------------
      (if (not node)
          (make-check-subtree-result 0 *ptrdiff-min* 0)
          (let* ((offset (+ offset (itree-node-offset node)))
                 (begin (+ (itree-node-begin node) offset))
                 (end (+ (itree-node-end node) offset))
                 (limit (+ (itree-node-limit node) offset))
                 (parent (itree-node-parent node)))
            ;; Validate structure.
            (unless (or (not (itree-node-left node))
                        (eq? (itree-node-parent (itree-node-left node)) node))
              (%itree-assert "left child's parent"))
            (unless (or (not (itree-node-right node))
                        (eq? (itree-node-parent (itree-node-right node)) node))
              (%itree-assert "right child's parent"))
            ;; Validate otick. A node's otick must be <= to the tree's
            ;; otick and <= to its parent's otick.
            (unless (<= (itree-node-otick node) tree-otick)
              (%itree-assert "node otick <= tree otick"))
            (unless (or (not parent)
                        (<= (itree-node-otick node) (itree-node-otick parent)))
              (%itree-assert "node otick <= parent otick"))
            (unless (or (not (= (itree-node-otick node) tree-otick))
                        (= (itree-node-offset node) 0))
              (%itree-assert "clean node has zero offset"))
            (unless (<= min-begin max-begin)
              (%itree-assert "min-begin <= max-begin"))
            (unless (<= min-begin begin)
              (%itree-assert "min-begin <= begin"))
            (unless (<= begin max-begin)
              (%itree-assert "begin <= max-begin"))
            (unless (<= end limit)
              (%itree-assert "end <= limit"))
            (let* ((left-result
                    (check-subtree (itree-node-left node)
                                   check-red-black-invariants
                                   tree-otick offset min-begin begin))
                   (right-result
                    (check-subtree (itree-node-right node)
                                   check-red-black-invariants
                                   tree-otick offset begin max-begin))
                   (left-limit (check-subtree-result-limit left-result))
                   (right-limit (check-subtree-result-limit right-result)))
              (unless (<= left-limit limit)
                (%itree-assert "left limit <= limit"))
              (unless (<= right-limit limit)
                (%itree-assert "right limit <= limit"))
              (unless (= limit (max end (max left-limit right-limit)))
                (%itree-assert "limit is the max end"))
              (when check-red-black-invariants
                (unless (= (check-subtree-result-black-height left-result)
                           (check-subtree-result-black-height right-result))
                  (%itree-assert "equal black heights"))
                (unless (or (not parent)
                            (not (itree-node-red node))
                            (not (itree-node-red parent)))
                  (%itree-assert "no red node with a red parent")))
              (make-check-subtree-result
               (+ 1
                  (check-subtree-result-size left-result)
                  (check-subtree-result-size right-result))
               limit
               (+ (if (itree-node-red node) 0 1)
                  (check-subtree-result-black-height left-result)))))))

    (define (itree-check-tree tree . rest)
      ;; `check_tree' (`itree.c:286'): "Validate invariants for TREE. If
      ;; CHECK_RED_BLACK_INVARIANTS, red nodes with red children are
      ;; considered invalid." Answers #t or raises.
      ;;--------------------------------------------------------------
      (let ((check-red-black-invariants
             (if (pair? rest) (car rest) #t)))
        (unless tree (%itree-assert "tree is not NULL"))
        (unless (>= (itree-tree-size tree) 0)
          (%itree-assert "tree size >= 0"))
        (unless (eq? (= (itree-tree-size tree) 0)
                     (not (itree-tree-root tree)))
          (%itree-assert "empty tree iff no root"))
        (if (not (itree-tree-root tree))
            #t
            (let* ((node (itree-tree-root tree))
                   (result (check-subtree node check-red-black-invariants
                                          (itree-tree-otick tree)
                                          (itree-node-offset node)
                                          *ptrdiff-min* *ptrdiff-max*)))
              (unless (not (itree-node-parent node))
                (%itree-assert "root has no parent"))
              (unless (or (not check-red-black-invariants)
                          (not (itree-node-red node)))
                (%itree-assert "root is black"))
              (unless (= (check-subtree-result-size result)
                         (itree-tree-size tree))
                (%itree-assert "counted size"))
              #t))))

    ;;----------------------------------------------------------------
    ;; Internal functions - `null_safe_is_red' onwards
    ;;------------------------------------------------------------------

    (define (null-safe-is-red node)
      ;; `null_safe_is_red' (`itree.c:313').
      ;;--------------------------------------------------------------
      (and node (itree-node-red node)))

    (define (null-safe-is-black node)
      ;; `null_safe_is_black' (`itree.c:319'): "NULL nodes are black".
      ;;--------------------------------------------------------------
      (or (not node) (not (itree-node-red node))))

    (define (itree-newlimit node)
      ;; `itree_newlimit' (`itree.c:325'): "the maximum END of this node
      ;; and its children".
      ;;--------------------------------------------------------------
      (max (itree-node-end node)
           (max (if (itree-node-left node)
                    (+ (itree-node-limit (itree-node-left node))
                       (itree-node-offset (itree-node-left node)))
                    *ptrdiff-min*)
                (if (itree-node-right node)
                    (+ (itree-node-limit (itree-node-right node))
                       (itree-node-offset (itree-node-right node)))
                    *ptrdiff-min*))))

    (define (itree-update-limit node)
      ;; `itree_update_limit' (`itree.c:340'): "Update NODE's limit
      ;; attribute according to its children."
      ;;--------------------------------------------------------------
      (when node
        (set!itree-node-limit node (itree-newlimit node))))

    (define (itree-inherit-offset otick node)
      ;; `itree_inherit_offset' (`itree.c:355'): "Apply NODE's offset to
      ;; its begin, end and limit values and propagate it to its
      ;; children. Does nothing, if NODE is clean, i.e. NODE.otick =
      ;; tree.otick."
      ;;--------------------------------------------------------------
      (if (= (itree-node-otick node) otick)
          #f
          (begin
            ;; Offsets can be inherited from dirty nodes (with out of
            ;; date otick) during removal, since we do not travel down
            ;; from the root in that case.
            (let ((offset (itree-node-offset node)))
              (when (not (= offset 0))
                (set!itree-node-begin node (+ (itree-node-begin node) offset))
                (set!itree-node-end node (+ (itree-node-end node) offset))
                (set!itree-node-limit node (+ (itree-node-limit node) offset))
                (when (itree-node-left node)
                  (set!itree-node-offset
                   (itree-node-left node)
                   (+ (itree-node-offset (itree-node-left node)) offset)))
                (when (itree-node-right node)
                  (set!itree-node-offset
                   (itree-node-right node)
                   (+ (itree-node-offset (itree-node-right node)) offset)))
                (set!itree-node-offset node 0)))
            ;; The only thing that matters about 'otick is whether it's
            ;; equal to that of the tree.
            (when (or (not (itree-node-parent node))
                      (= (itree-node-otick (itree-node-parent node)) otick))
              (set!itree-node-otick node otick)))))

    (define (itree-propagate-limit node)
      ;; `itree_propagate_limit' (`itree.c:392'): "Update limit of NODE
      ;; and its ancestors. Stop when it becomes stable, i.e. new_limit =
      ;; old_limit."
      ;;--------------------------------------------------------------
      (when node
        (let loop ((node node))
          (let ((newlimit (itree-newlimit node)))
            (unless (= newlimit (itree-node-limit node))
              (set!itree-node-limit node newlimit)
              (when (itree-node-parent node)
                (loop (itree-node-parent node))))))))

    (define (itree-validate tree node)
      ;; `itree_validate' (`itree.c:413'): bring NODE and its ancestors
      ;; up to date with the tree's offsets, and answer NODE.
      ;;--------------------------------------------------------------
      (if (or (not node) (= (itree-tree-otick tree) (itree-node-otick node)))
          node
          (begin
            (when (not (eq? node (itree-tree-root tree)))
              (itree-validate tree (itree-node-parent node)))
            (itree-inherit-offset (itree-tree-otick tree) node)
            node)))

    ;;----------------------------------------------------------------
    ;; Tree operations
    ;;------------------------------------------------------------------

    (define (itree-node-init node front-advance rear-advance data)
      ;; `itree_node_init' (`itree.c:432'): "Initialize an allocated
      ;; node."
      ;;--------------------------------------------------------------
      (set!itree-node-parent node #f)
      (set!itree-node-left node #f)
      (set!itree-node-right node #f)
      (set!itree-node-begin node -1)
      (set!itree-node-end node -1)
      (set!itree-node-front-advance node front-advance)
      (set!itree-node-rear-advance node rear-advance)
      (set!itree-node-data node data))

    (define (itree-node-begin-of tree node)
      ;; `itree_node_begin' (`itree.c:449'): "Return NODE's begin value,
      ;; computing it if necessary."
      ;;
      ;; Named `-of' because `itree-node-begin' is the field accessor the
      ;; C's structure has; this is the function that validates first.
      ;;--------------------------------------------------------------
      (itree-validate tree node)
      (itree-node-begin node))

    (define (itree-node-end-of tree node)
      ;; `itree_node_end' (`itree.c:459').
      ;;--------------------------------------------------------------
      (itree-validate tree node)
      (itree-node-end node))

    (define (itree-create)
      ;; `itree_create' (`itree.c:469'): "Allocate an itree_tree."
      ;;--------------------------------------------------------------
      (let ((tree (make<itree-tree> #f 1 0)))
        (itree-clear tree)
        tree))

    (define (itree-clear tree)
      ;; `itree_clear' (`itree.c:479'): "Reset the tree TREE to its empty
      ;; state."
      ;;--------------------------------------------------------------
      (set!itree-tree-root tree #f)
      (set!itree-tree-otick tree 1)
      (set!itree-tree-size tree 0))

    (define (itree-destroy tree)
      ;; `itree_destroy' (`itree.c:498'): the C frees the struct; there
      ;; is nothing to free in Scheme, and the collector does it. Kept
      ;; because callers say what they mean - see `buffer-overlays-tree'
      ;; being cleared on `kill-buffer'.
      ;;--------------------------------------------------------------
      tree)

    (define (itree-empty-p tree)
      ;; `itree_empty_p' (`itree.h:118'): "not tree or no root".
      ;;--------------------------------------------------------------
      (or (not tree) (not (itree-tree-root tree))))

    (define (itree-size tree)
      ;; `itree_size' (`itree.c:507').
      ;;--------------------------------------------------------------
      (itree-tree-size tree))

    (define (itree-rotate-left tree node)
      ;; `itree_rotate_left' (`itree.c:515'): "Perform the familiar
      ;; left-rotation on node NODE."
      ;;--------------------------------------------------------------
      (let ((right (itree-node-right node)))
        (unless right (%itree-assert "rotate-left needs a right child"))
        (itree-inherit-offset (itree-tree-otick tree) node)
        (itree-inherit-offset (itree-tree-otick tree) right)

        ;; Turn right's left subtree into node's right subtree.
        (set!itree-node-right node (itree-node-left right))
        (when (itree-node-left right)
          (set!itree-node-parent (itree-node-left right) node))

        ;; right's parent was node's parent.
        (set!itree-node-parent right (itree-node-parent node))

        ;; Get the parent to point to right instead of node.
        (if (not (eq? node (itree-tree-root tree)))
            (if (eq? node (itree-node-left (itree-node-parent node)))
                (set!itree-node-left (itree-node-parent node) right)
                (set!itree-node-right (itree-node-parent node) right))
            (set!itree-tree-root tree right))

        ;; Put node on right's left.
        (set!itree-node-left right node)
        (set!itree-node-parent node right)

        ;; Order matters here.
        (itree-update-limit node)
        (itree-update-limit right)))

    (define (itree-rotate-right tree node)
      ;; `itree_rotate_right' (`itree.c:558').
      ;;--------------------------------------------------------------
      (let ((left (itree-node-left node)))
        (unless (and tree node left)
          (%itree-assert "rotate-right needs a left child"))
        (itree-inherit-offset (itree-tree-otick tree) node)
        (itree-inherit-offset (itree-tree-otick tree) left)

        (set!itree-node-left node (itree-node-right left))
        (when (itree-node-right left)
          (set!itree-node-parent (itree-node-right left) node))

        (set!itree-node-parent left (itree-node-parent node))
        (if (not (eq? node (itree-tree-root tree)))
            (if (eq? node (itree-node-right (itree-node-parent node)))
                (set!itree-node-right (itree-node-parent node) left)
                (set!itree-node-left (itree-node-parent node) left))
            (set!itree-tree-root tree left))

        (set!itree-node-right left node)
        (set!itree-node-parent node left)

        (itree-update-limit left)
        (itree-update-limit node)))

    (define (itree-insert-fix tree node)
      ;; `itree_insert_fix' (`itree.c:597'): "Repair the tree after an
      ;; insertion. The new NODE was added as red, so we may have 2 reds
      ;; in a row. Rebalance the parents as needed to re-establish the RB
      ;; invariants."
      ;;--------------------------------------------------------------
      (let loop ((node node))
        (when (null-safe-is-red (itree-node-parent node))
          ;; NODE is red and its parent is red. This is a violation of
          ;; red-black tree property #3.
          (let ((parent (itree-node-parent node))
                (grandparent (itree-node-parent (itree-node-parent node))))
            (if (eq? parent (itree-node-left grandparent))
                ;; We're on the left side of our grandparent, and OTHER
                ;; is our "uncle".
                (let ((uncle (itree-node-right grandparent)))
                  (if (null-safe-is-red uncle) ; case 1.a
                      ;; Uncle and parent are red but should be black
                      ;; because NODE is red. Change the colors
                      ;; accordingly and proceed with the grandparent.
                      (begin
                        (set!itree-node-red parent #f)
                        (set!itree-node-red uncle #f)
                        (set!itree-node-red grandparent #t)
                        (loop grandparent))
                      (let ((node (if (eq? node (itree-node-right parent))
                                      ;; case 2.a
                                      (begin
                                        (itree-rotate-left tree parent)
                                        parent)
                                      node)))
                        ;; case 3.a
                        (set!itree-node-red (itree-node-parent node) #f)
                        (set!itree-node-red
                         (itree-node-parent (itree-node-parent node))
                         #t)
                        (itree-rotate-right
                         tree (itree-node-parent (itree-node-parent node))))))
                ;; This is the symmetrical case of above.
                (let ((uncle (itree-node-left grandparent)))
                  (if (null-safe-is-red uncle) ; case 1.b
                      (begin
                        (set!itree-node-red parent #f)
                        (set!itree-node-red uncle #f)
                        (set!itree-node-red grandparent #t)
                        (loop grandparent))
                      (let ((node (if (eq? node (itree-node-left parent))
                                      ;; case 2.b
                                      (begin
                                        (itree-rotate-right tree parent)
                                        parent)
                                      node)))
                        ;; case 3.b
                        (set!itree-node-red (itree-node-parent node) #f)
                        (set!itree-node-red
                         (itree-node-parent (itree-node-parent node))
                         #t)
                        (itree-rotate-left
                         tree (itree-node-parent (itree-node-parent node))))))))))
      ;; The root may have been changed to red due to the algorithm. Set
      ;; it to black so that property #5 is satisfied.
      (set!itree-node-red (itree-tree-root tree) #f))

    (define (itree-insert-node tree node)
      ;; `itree_insert_node' (`itree.c:676'): "Insert a NODE into the
      ;; TREE. Note, that inserting a node twice results in undefined
      ;; behavior."
      ;;--------------------------------------------------------------
      (let ((otick (itree-tree-otick tree)))
        (let loop ((child (itree-tree-root tree)) (parent #f))
          (if (not child)
              (begin
                ;; Insert the node.
                (cond ((not parent) (set!itree-tree-root tree node))
                      ((<= (itree-node-begin node) (itree-node-begin parent))
                       (set!itree-node-left parent node))
                      (else
                       (set!itree-node-right parent node)))

                ;; Init the node.
                (set!itree-node-parent node parent)
                (set!itree-node-left node #f)
                (set!itree-node-right node #f)
                (set!itree-node-offset node 0)
                (set!itree-node-limit node (itree-node-end node))
                (set!itree-node-otick node otick)

                ;; Fix/update the tree.
                (set!itree-tree-size tree (+ (itree-tree-size tree) 1))
                (if (eq? node (itree-tree-root tree))
                    (set!itree-node-red node #f)
                    (begin
                      (set!itree-node-red node #t)
                      (itree-insert-fix tree node))))
              ;; Find the insertion point, accumulate node's offset and
              ;; update ancestors limit values.
              (begin
                (itree-inherit-offset otick child)
                (set!itree-node-limit child
                                      (max (itree-node-limit child)
                                           (itree-node-end node)))
                (loop (if (<= (itree-node-begin node)
                              (itree-node-begin child))
                          (itree-node-left child)
                          (itree-node-right child))
                      child))))))

    (define (itree-insert tree node begin end)
      ;; `itree_insert' (`itree.c:732').
      ;;--------------------------------------------------------------
      (set!itree-node-begin node begin)
      (set!itree-node-end node end)
      (set!itree-node-otick node (itree-tree-otick tree))
      (itree-insert-node tree node))

    (define (itree-node-set-region tree node begin end)
      ;; `itree_node_set_region' (`itree.c:744'): "Safely modify a
      ;; node's interval."
      ;;--------------------------------------------------------------
      (itree-validate tree node)
      (cond
       ((not (= begin (itree-node-begin node)))
        (itree-remove tree node)
        (set!itree-node-begin node (min begin (- *ptrdiff-max* 1)))
        (set!itree-node-end node (max (itree-node-begin node) end))
        (itree-insert-node tree node))
       ((not (= end (itree-node-end node)))
        (set!itree-node-end node (max (itree-node-begin node) end))
        (itree-propagate-limit node))))

    (define (itree-contains tree node)
      ;; `itree_contains' (`itree.c:767'): "Return true, if NODE is a
      ;; member of TREE."
      ;;--------------------------------------------------------------
      (let loop ((node node) (root (itree-tree-root tree)))
        (cond ((eq? node root) #t)
              ((not (itree-node-parent node)) #f)
              (else (loop (itree-node-parent node) root)))))

    (define (itree-limit-is-stable node)
      ;; `itree_limit_is_stable' (`itree.c:783').
      ;;--------------------------------------------------------------
      (or (not node)
          (= (itree-newlimit node) (itree-node-limit node))))

    (define (itree-subtree-min otick node)
      ;; `itree_subtree_min' (`itree.c:792').
      ;;--------------------------------------------------------------
      (if (not node)
          node
          (let loop ((node node))
            (itree-inherit-offset otick node)
            (if (itree-node-left node)
                (loop (itree-node-left node))
                node))))

    (define (itree-remove-fix tree node parent)
      ;; `itree_remove_fix' (`itree.c:807'): "Repair the tree after a
      ;; deletion. The black-depth of NODE is one less than that of its
      ;; sibling, so re-balance the parents to re-establish the RB
      ;; invariants."
      ;;--------------------------------------------------------------
      ;; The loop answers the node it stopped on, and only then is that
      ;; node's colour cleared - the C has the `if (node != NULL)
      ;; node->red = false;' *after* the loop, and doing it on every turn
      ;; would make a red parent that case 2 has just moved to black
      ;; before the loop condition re-tested it, which continues the walk
      ;; where the C stops.
      (let ((node
             (let loop ((node node) (parent parent))
               (if (and parent (null-safe-is-black node))
                   (if (eq? node (itree-node-left parent))
                       (let ((other (itree-node-right parent)))
                         (when (itree-node-red other) ; case 1.a
                           (set!itree-node-red other #f)
                           (set!itree-node-red parent #t)
                           (itree-rotate-left tree parent)
                           (set! other (itree-node-right parent)))
                         (if (and (null-safe-is-black (itree-node-left other))
                                  (null-safe-is-black
                                   (itree-node-right other))) ; 2.a
                             (begin
                               (set!itree-node-red other #t)
                               (loop parent (itree-node-parent parent)))
                             (begin
                               (when (null-safe-is-black
                                      (itree-node-right other)) ; 3.a
                                 (set!itree-node-red
                                  (itree-node-left other) #f)
                                 (set!itree-node-red other #t)
                                 (itree-rotate-right tree other)
                                 (set! other (itree-node-right parent)))
                               (set!itree-node-red
                                other (itree-node-red parent)) ; 4.a
                               (set!itree-node-red parent #f)
                               (set!itree-node-red
                                (itree-node-right other) #f)
                               (itree-rotate-left tree parent)
                               (itree-tree-root tree))))
                       (let ((other (itree-node-left parent)))
                         (when (itree-node-red other) ; case 1.b
                           (set!itree-node-red other #f)
                           (set!itree-node-red parent #t)
                           (itree-rotate-right tree parent)
                           (set! other (itree-node-left parent)))
                         (if (and (null-safe-is-black
                                   (itree-node-right other))
                                  (null-safe-is-black
                                   (itree-node-left other))) ; 2.b
                             (begin
                               (set!itree-node-red other #t)
                               (loop parent (itree-node-parent parent)))
                             (begin
                               (when (null-safe-is-black
                                      (itree-node-left other)) ; 3.b
                                 (set!itree-node-red
                                  (itree-node-right other) #f)
                                 (set!itree-node-red other #t)
                                 (itree-rotate-left tree other)
                                 (set! other (itree-node-left parent)))
                               (set!itree-node-red
                                other (itree-node-red parent)) ; 4.b
                               (set!itree-node-red parent #f)
                               (set!itree-node-red
                                (itree-node-left other) #f)
                               (itree-rotate-right tree parent)
                               (itree-tree-root tree)))))
                   node))))
        (when node
          (set!itree-node-red node #f))))

    (define (itree-total-offset node)
      ;; `itree_total_offset' (`itree.c:903'): "Return accumulated
      ;; offsets of NODE's parents."
      ;;--------------------------------------------------------------
      (let loop ((node node) (offset 0))
        (if (not (itree-node-parent node))
            offset
            (let ((parent (itree-node-parent node)))
              (loop parent (+ offset (itree-node-offset parent)))))))

    (define (itree-replace-child tree source dest)
      ;; `itree_replace_child' (`itree.c:923'): "Replace DEST with SOURCE
      ;; as a child of DEST's parent. Adjusts *only* the parent linkage
      ;; of SOURCE and either the parent's child link [or] the tree root."
      ;;--------------------------------------------------------------
      ;; The C's three tests are one `if/else if/else': the root case
      ;; must not fall through to the parent case, because the root has
      ;; just been replaced and `(itree-tree-root tree)' is the *source*
      ;; by then.
      (cond
       ((eq? dest (itree-tree-root tree))
        (set!itree-tree-root tree source))
       ((eq? dest (itree-node-left (itree-node-parent dest)))
        (set!itree-node-left (itree-node-parent dest) source))
       (else
        (set!itree-node-right (itree-node-parent dest) source)))
      (when source
        (set!itree-node-parent source (itree-node-parent dest))))

    (define (itree-transplant tree source dest)
      ;; `itree_transplant' (`itree.c:949').
      ;;--------------------------------------------------------------
      (itree-replace-child tree source dest)
      (set!itree-node-left source (itree-node-left dest))
      (when (itree-node-left source)
        (set!itree-node-parent (itree-node-left source) source))
      (set!itree-node-right source (itree-node-right dest))
      (when (itree-node-right source)
        (set!itree-node-parent (itree-node-right source) source))
      (set!itree-node-red source (itree-node-red dest)))

    (define (itree-remove tree node)
      ;; `itree_remove' (`itree.c:966'): "Remove NODE from TREE and
      ;; return it. NODE must exist in TREE."
      ;;--------------------------------------------------------------
      ;; We can get here straight from, say, 'move-overlay', so NODE may
      ;; be dirty.
      (itree-validate tree node)
      ;; Find 'splice', the leaf node to splice out of the tree. When
      ;; 'node' has at most one child this is 'node' itself. Otherwise,
      ;; it is the in order successor of 'node'.
      (let* ((splice (if (or (not (itree-node-left node))
                             (not (itree-node-right node)))
                         node
                         (itree-subtree-min (itree-tree-otick tree)
                                            (itree-node-right node))))
             ;; Find 'subtree', the only child of 'splice' (may be NULL).
             (subtree (if (itree-node-left splice)
                          (itree-node-left splice)
                          (itree-node-right splice)))
             ;; Save a pointer to the parent of where 'subtree' will
             ;; eventually be.
             (subtree-parent (if (not (eq? (itree-node-parent splice) node))
                                 (itree-node-parent splice)
                                 splice)))
        ;; If 'splice' is black removing it may violate Red-Black
        ;; invariants, so note this for later.
        ;;
        ;; Replace 'splice' with 'subtree' under subtree's parent. If
        ;; 'splice' is black, this creates a red-red violation, so
        ;; remember this now as the field can be overwritten when splice
        ;; is transplanted below.
        (itree-replace-child tree subtree splice)
        (let ((removed-black (not (itree-node-red splice))))
          ;; Replace 'node' with 'splice' in the tree and propagate
          ;; limit upwards, if necessary.
          (when (not (eq? splice node))
            (itree-transplant tree splice node)
            (itree-propagate-limit subtree-parent)
            (when (not (eq? splice subtree-parent))
              (itree-update-limit splice)))
          (itree-propagate-limit (itree-node-parent splice))
          (set!itree-tree-size tree (- (itree-tree-size tree) 1))
          ;; Fix any black height violation caused by removing a black
          ;; node.
          (when removed-black
            (itree-remove-fix tree subtree subtree-parent)))
        ;; Clear fields related to the tree for sanity while debugging.
        (set!itree-node-red node #f)
        (set!itree-node-right node #f)
        (set!itree-node-left node #f)
        (set!itree-node-parent node #f)
        (set!itree-node-limit node 0)
        node))

    ;;----------------------------------------------------------------
    ;; Insert/Delete Gaps - `itree_insert_gap', `itree_delete_gap'
    ;;------------------------------------------------------------------

    (define (itree-insert-gap tree pos length before-markers)
      ;; `itree_insert_gap' (`itree.c:1054'): "Insert a gap at POS of
      ;; length LENGTH expanding all intervals intersecting it, while
      ;; respecting their rear_advance and front_advance setting. If
      ;; BEFORE_MARKERS is non-zero, all overlays beginning/ending at
      ;; POS are treated as if their front_advance/rear_advance was
      ;; true."
      ;;--------------------------------------------------------------
      (if (or (not tree) (<= length 0) (not (itree-tree-root tree)))
          #f
          (let ()
            ;; Nodes with front_advance starting at pos may mess up the
            ;; tree order, so we need to remove them first. This doesn't
            ;; apply for 'before_markers' since in that case, all
            ;; positions move identically regardless of 'front_advance'
            ;; or 'rear_advance'.
            (let ((saved (itree-stack-create 0)))
              (unless before-markers
                ;; Actually any order would do.
                (let ((iter (itree-iterator-start
                             (make<itree-iterator> #f 0 0 0 'pre-order)
                             tree pos (+ pos 1) 'pre-order)))
                  (let loop ((node (itree-iterator-next iter)))
                    (when node
                      (when (and (= (itree-node-begin node) pos)
                                 (itree-node-front-advance node)
                                 ;; If we have front_advance and
                                 ;; !rear_advance and the overlay is
                                 ;; empty, make sure we don't move begin
                                 ;; past end by pretending it's
                                 ;; !front_advance.
                                 (or (not (= (itree-node-begin node)
                                             (itree-node-end node)))
                                     (itree-node-rear-advance node)))
                        (itree-stack-push saved node))
                      (loop (itree-iterator-next iter))))))
              (let loop ((i 0))
                (when (< i (itree-stack-length saved))
                  (itree-remove tree (vector-ref (itree-stack-nodes saved) i))
                  (loop (+ i 1))))

              ;; We can't use an iterator here, because we can't
              ;; effectively narrow AND shift some subtree at the same
              ;; time.
              (when (itree-tree-root tree)
                (let ((stack (itree-stack-create
                              (+ (itree-max-height tree) 1))))
                  (itree-stack-push stack (itree-tree-root tree))
                  (let loop ((node (itree-stack-pop stack)))
                    (when node
                      ;; Process in pre-order.
                      (itree-inherit-offset (itree-tree-otick tree) node)
                      (unless (> pos (itree-node-limit node))
                        (when (itree-node-right node)
                          (if (> (itree-node-begin node) pos)
                              ;; All nodes in this subtree are shifted
                              ;; by length.
                              (begin
                                (set!itree-node-offset
                                 (itree-node-right node)
                                 (+ (itree-node-offset
                                     (itree-node-right node))
                                    length))
                                (set!itree-tree-otick
                                 tree (+ (itree-tree-otick tree) 1)))
                              (itree-stack-push stack (itree-node-right node))))
                        (when (itree-node-left node)
                          (itree-stack-push stack (itree-node-left node)))

                        (if (if before-markers
                                (>= (itree-node-begin node) pos)
                                ;; node->begin == pos => !front-advance
                                (> (itree-node-begin node) pos))
                            (set!itree-node-begin
                             node (+ (itree-node-begin node) length)))
                        (when (or (> (itree-node-end node) pos)
                                  (and (= (itree-node-end node) pos)
                                       (or before-markers
                                           (itree-node-rear-advance node))))
                          (set!itree-node-end
                           node (+ (itree-node-end node) length))
                          (itree-propagate-limit node)))
                      (loop (itree-stack-pop stack))))))

              ;; Reinsert nodes starting at POS having front-advance.
              (let ((notick (itree-tree-otick tree)))
                (let loop ((node (itree-stack-pop saved)))
                  (when node
                    ;; The C's three easserts here - the node is clean,
                    ;; begins at POS and is not point-like - are checking
                    ;; build assertions; `itree-check-tree' is where this
                    ;; tree keeps that class.
                    (set!itree-node-begin node (+ (itree-node-begin node) length))
                    (set!itree-node-end node (+ (itree-node-end node) length))
                    (set!itree-node-otick node notick)
                    (itree-insert-node tree node)
                    (loop (itree-stack-pop saved)))))))))

    (define (itree-delete-gap tree pos length)
      ;; `itree_delete_gap' (`itree.c:1148'): "Delete a gap at POS of
      ;; length LENGTH, contracting all intervals intersecting it."
      ;;--------------------------------------------------------------
      (if (or (not tree) (<= length 0) (not (itree-tree-root tree)))
          #f
          (let ((stack (itree-stack-create (+ (itree-max-height tree) 1))))
            ;; Can't use the iterator here, because by decrementing begin,
            ;; we might unintentionally bring shifted nodes back into our
            ;; search space.
            (itree-stack-push stack (itree-tree-root tree))
            (let loop ((node (itree-stack-pop stack)))
              (when node
                (itree-inherit-offset (itree-tree-otick tree) node)
                (unless (> pos (itree-node-limit node))
                  (when (itree-node-right node)
                    (if (> (itree-node-begin node) (+ pos length))
                        ;; Shift right subtree to the left.
                        (begin
                          (set!itree-node-offset
                           (itree-node-right node)
                           (- (itree-node-offset (itree-node-right node))
                              length))
                          (set!itree-tree-otick
                           tree (+ (itree-tree-otick tree) 1)))
                        (itree-stack-push stack (itree-node-right node))))
                  (when (itree-node-left node)
                    (itree-stack-push stack (itree-node-left node)))

                  (when (< pos (itree-node-begin node))
                    (set!itree-node-begin
                     node (max pos (- (itree-node-begin node) length))))
                  (when (> (itree-node-end node) pos)
                    (set!itree-node-end
                     node (max pos (- (itree-node-end node) length)))
                    (itree-propagate-limit node)))
                (loop (itree-stack-pop stack)))))))

    ;;----------------------------------------------------------------
    ;; The iterator
    ;;------------------------------------------------------------------

    (define (itree-node-intersects node begin end)
      ;; `itree_node_intersects' (`itree.c:1208'): "Return true, if
      ;; NODE's interval intersects with [BEGIN, END). Note: We always
      ;; include empty nodes at BEGIN (and not at END), but if
      ;; BEGIN==END, then we don't include non-empty nodes starting at
      ;; BEGIN or ending at END. This seems to match the behavior of the
      ;; old overlays code ..."
      ;;--------------------------------------------------------------
      (or (and (< begin (itree-node-end node))
               (< (itree-node-begin node) end))
          (and (= (itree-node-begin node) (itree-node-end node))
               (= begin (itree-node-begin node)))))

    (define (itree-iter-next-in-subtree node iter)
      ;; `itree_iter_next_in_subtree' (`itree.c:1228'): "Return the
      ;; 'next' node in the current traversal order."
      ;;--------------------------------------------------------------
      (case (itree-iterator-order iter)
        ((ascending)
         (let ((next (itree-node-right node)))
           (cond
            ((not next)
             (let loop ((node node) (next (itree-node-parent node)))
               (cond ((not next) #f)
                     ((eq? (itree-node-right next) node) (loop next
                                                              (itree-node-parent next)))
                     (else
                      (set! node next)
                      (if (> (itree-node-begin node)
                             (itree-iterator-end iter))
                          #f
                          node)))))
            (else
             (set! node next)
             (itree-inherit-offset (itree-iterator-otick iter) node)
             (let loop ((node node) (next (itree-node-left node)))
               (if (and next
                        (begin
                          (itree-inherit-offset
                           (itree-iterator-otick iter) next)
                          (<= (itree-iterator-beg iter)
                              (itree-node-limit next))))
                   (loop next (itree-node-left next))
                   (if (> (itree-node-begin node)
                          (itree-iterator-end iter))
                       #f
                       node)))))))

        ((descending)
         (let ((next (itree-node-left node)))
           (if (or (not next)
                   (begin
                     (itree-inherit-offset (itree-iterator-otick iter) next)
                     (< (itree-node-limit next) (itree-iterator-beg iter))))
               (let loop ((node node) (next (itree-node-parent node)))
                 (cond ((not next) #f)
                       ((eq? (itree-node-left next) node)
                        (loop next (itree-node-parent next)))
                       (else next)))
               (let loop ((node next))
                 (let ((next (itree-node-right node)))
                   (if (and (<= (itree-node-begin node)
                                (itree-iterator-end iter))
                            next)
                       (begin
                         (itree-inherit-offset
                          (itree-iterator-otick iter) next)
                         (loop next))
                       node))))))

        ((pre-order)
         (let ((next (itree-node-left node)))
           (cond
            ((and next
                  (begin
                    (itree-inherit-offset (itree-iterator-otick iter) next)
                    (not (< (itree-node-limit next)
                            (itree-iterator-beg iter)))))
             next)
            (else
             (let ((next (itree-node-right node)))
               (if (and (<= (itree-node-begin node)
                            (itree-iterator-end iter))
                        next)
                   (begin
                     (itree-inherit-offset (itree-iterator-otick iter) next)
                     next)
                   (let loop ((node node) (next (itree-node-parent node)))
                     (cond
                      ((not next) #f)
                      ((eq? (itree-node-right next) node)
                       (loop next (itree-node-parent next)))
                      (else
                       (set! node next)
                       (set! next (itree-node-right node))
                       (if (and (<= (itree-node-begin node)
                                    (itree-iterator-end iter))
                                next)
                           (begin
                             (itree-inherit-offset
                              (itree-iterator-otick iter) next)
                             next)
                           (loop node (itree-node-parent node))))))))))))

        ((post-order)
         (let ((next (itree-node-parent node)))
           (if (or (not next) (eq? (itree-node-right next) node))
               next
               (let ((node next))
                 (let ((next (itree-node-right node)))
                   (if (not (and (<= (itree-node-begin node)
                                     (itree-iterator-end iter))
                                 next))
                       node
                       (let loop ((node next))
                         (itree-inherit-offset
                          (itree-iterator-otick iter) node)
                         (let ((next (itree-node-left node)))
                           (cond
                            ((and next
                                  (begin
                                    (itree-inherit-offset
                                     (itree-iterator-otick iter) next)
                                    (<= (itree-iterator-beg iter)
                                        (itree-node-limit next))))
                             (loop next))
                            (else
                             (set! next (itree-node-right node))
                             (if (and (<= (itree-node-begin node)
                                          (itree-iterator-end iter))
                                      next)
                                 (begin
                                   (itree-inherit-offset
                                    (itree-iterator-otick iter) next)
                                   (loop next))
                                 node)))))))))))

        (else
         (error "itree: unknown iteration order"
                (itree-iterator-order iter)))))

    (define (itree-iterator-first-node tree iter)
      ;; `itree_iterator_first_node' (`itree.c:1344').
      ;;--------------------------------------------------------------
      (let ((node (itree-tree-root tree)))
        (if node
            (let ((dummy (make<itree-node> #f #f #f 0 0 0 0 0 #f #f #f #f)))
              (itree-inherit-offset (itree-iterator-otick iter) node)
              (case (itree-iterator-order iter)
                ((ascending)
                 (set!itree-node-right dummy node)
                 (set!itree-node-begin dummy *ptrdiff-min*)
                 (itree-iter-next-in-subtree dummy iter))
                ((descending)
                 (set!itree-node-left dummy node)
                 (itree-iter-next-in-subtree dummy iter))
                ((pre-order)
                 node)
                ((post-order)
                 (set!itree-node-parent dummy dummy)
                 (set!itree-node-left dummy dummy)
                 (set!itree-node-right dummy node)
                 (set!itree-node-begin dummy *ptrdiff-min*)
                 (itree-iter-next-in-subtree dummy iter))
                (else
                 (error "itree: unknown iteration order"
                        (itree-iterator-order iter)))))
            #f)))

    (define (itree-iterator-start iter tree begin end order)
      ;; `itree_iterator_start' (`itree.c:1389'): "Start an iterator
      ;; enumerating all intervals in [BEGIN,END) in the given ORDER."
      ;;
      ;; ITER is the `struct itree_iterator' the C's `ITREE_FOREACH'
      ;; puts on the caller's stack; here the caller makes one with
      ;; `make<itree-iterator>' and hands it over.
      ;;--------------------------------------------------------------
      (unless iter (%itree-assert "iterator is not NULL"))
      (set!itree-iterator-beg iter begin)
      (set!itree-iterator-end iter end)
      (set!itree-iterator-otick iter (itree-tree-otick tree))
      (set!itree-iterator-order iter order)
      (set!itree-iterator-node iter (itree-iterator-first-node tree iter))
      iter)

    (define (itree-iterator-next iter)
      ;; `itree_iterator_next' (`itree.c:1409').
      ;;--------------------------------------------------------------
      (let loop ((node (itree-iterator-node iter)))
        (cond
         ((not node)
          (set!itree-iterator-node iter #f)
          #f)
         ((itree-node-intersects node
                                 (itree-iterator-beg iter)
                                 (itree-iterator-end iter))
          (set!itree-iterator-node iter
                                   (itree-iter-next-in-subtree node iter))
          node)
         (else
          (loop (itree-iter-next-in-subtree node iter))))))

    (define (itree-iterator-narrow iter begin end)
      ;; `itree_iterator_narrow' (`itree.c:1426'): "Limit G to the new
      ;; interval [BEGIN, END), which must be a subset of the current
      ;; one. I.E. it can't grow on either side."
      ;;--------------------------------------------------------------
      (set!itree-iterator-beg iter
                              (max begin (itree-iterator-beg iter)))
      (set!itree-iterator-end iter
                              (min end (itree-iterator-end iter)))
      iter)))
