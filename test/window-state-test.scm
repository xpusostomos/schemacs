(import
 (scheme base)
 (scheme write)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs dispnew) current-display)
 (only (schemacs test-display) <test-display>)
 (only (schemacs frame)
       *current-frame* *current-buffer* *default-frame-alist* *frame-list*
       *window-persistent-parameters*
       new-frame frame-root-window frame-list frame-live-p
       window-list window-buffer window-point window-top window-height
       window-width window-left window-dedicated-p set-window-dedicated-p
       window-parameter set-window-parameter window-live-p
       window-parent window-children window-frame)
 (only (schemacs window)
       split-window delete-window delete-other-windows
       window-min-size window-normal-size window-size
       window-resize window-resizable window-resize-no-error
       window-state-get window-state-put window-state-buffers
       window--state-assq window--state-ref
       window-deletable-p window-child-count combine-windows
       window-main-window)
 (only (schemacs buffer)
       allocate-buffer buffer-name buffer-pt buffer-beg get-buffer
       with-current-buffer set-point buffer-live-p)
 (only (schemacs editfns) insert goto-char)
 (only (schemacs marker) marker-position markerp)
 (only (schemacs window-x) window-get-split-combination)
 (only (ice-9 exceptions) exception-message))

;; Regression tests for window states - `window.el`'s `window-state-get`,
;; `window-state-put` and the size arithmetic they are built on.
;;
;; Every expectation below is GNU Emacs 31.1's own answer for the same
;; window tree, measured with `emacs -Q --batch' first. Emacs's batch
;; frame is 24 rows where this tree's text area is 23 (its echo area is
;; a window and takes the last row), so the tests that depend on the
;; frame's size assert the *rule* Emacs applies - a leaf's minimum is
;; `window-min-height' unless its own height is larger, a normal size is
;; the window's share of its parent - and the tests that do not assert
;; the exact number.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)

;; A frame with no menu bar takes no row of its own; the echo area takes
;; the last one, leaving 23 rows of text.
(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define (frame-with text)
  (let* ((ed (allocate-buffer))
         (frame (new-frame ed 24 80)))
    (with-current-buffer ed (insert text))
    (set-point ed (buffer-beg ed))
    frame))

(define (with-frame text thunk)
  ;; A fresh frame, current for the body, and dropped afterwards.
  (let* ((ed (allocate-buffer))
         (frame (new-frame ed 24 80)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (with-current-buffer ed (insert text))
      (set-point ed (buffer-beg ed))
      (thunk frame))))

(define (rects frame)
  (map (lambda (w) (list (window-top w) (window-height w)
                         (window-left w) (window-width w)))
       (window-list frame)))

(define (state-child state)
  ;; The first child node of a state or of one of its internal nodes: the
  ;; first element whose car is a type symbol. The state's spine is the
  ;; head's alist, then the root's type, its alist, and its children.
  (let loop ((rest (cddr state)))   ; skip the head and the node's own type
    (cond ((not (pair? rest)) #f)
          ;; A child node is an element whose car is a type symbol; the
          ;; alist entries are elements whose car is a key.
          ((and (pair? (car rest)) (memq (car (car rest)) '(leaf vc hc)))
           (car rest))
          (else (loop (cdr rest))))))

;;--------------------------------------------------------------
(test-begin "window-min-size")
;;--------------------------------------------------------------
;; `window-min-size` (`window.el:1605`). A leaf's minimum is the
;; height of its mode line plus the safe minimum (2 rows), raised to
;; `window-min-height` (4) unless the caller ignores it: measured,
;; `emacs -Q --batch` answers 4, 2 and 1 for a leaf's three IGNORE
;; values, and its width is 10, 2 and 2.
(with-frame ""
 (lambda (frame)
   (let ((leaf (car (window-list frame))))
     (test-equal "a leaf's minimum height is window-min-height"
                 4 (window-min-size leaf))
     (test-equal "ignoring size restrictions leaves the mode line and one row"
                 2 (window-min-size leaf #f #t))
     (test-equal "the safe minimum is window-safe-min-height"
                 1 (window-min-size leaf #f 'safe))
     (test-equal "a leaf's minimum width is window-min-width"
                 10 (window-min-size leaf #t))
     (test-equal "ignoring restrictions leaves window-safe-min-width"
                 2 (window-min-size leaf #t #t))
     (test-equal "the safe minimum width is window-safe-min-width"
                 2 (window-min-size leaf #t 'safe)))))

;; An iso-combination's minimum is the sum of its children's, an
;; ortho-combination's the maximum - the C's two branches. Measured on
;; a 10/14 split of a 24-row frame: 8 and 10 for the root.
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 10 #f)
     (let ((root (frame-root-window frame)))
       (test-equal "a vertical combination's minimum is the sum of its children"
                   8 (window-min-size root))
       (test-equal "its width minimum is the maximum of its children's"
                   10 (window-min-size root #t))
       (test-equal "... and with the restrictions ignored, the sum of 2s"
                   4 (window-min-size root #f #t))))))

;;--------------------------------------------------------------
(test-end "window-min-size")

(test-begin "window-normal-size")
;;--------------------------------------------------------------
;; `window-normal-size` (`window.c:947`): a window's share of its
;; parent along one axis, and 1.0 for the root and for a window not
;; combined on that axis.
(with-frame ""
 (lambda (frame)
   (let* ((a (car (window-list frame)))
          (b (split-window a 10 #f))
          (root (frame-root-window frame)))
     (test-equal "the root's normal height is 1.0" 1.0 (window-normal-size root #f))
     (test-equal "the first child's normal height is its share of the root"
                 0.43478260869565216 (window-normal-size a #f))
     (test-equal "the second child's normal height is the rest"
                 0.5652173913043478 (window-normal-size b #f))
     (test-equal "a vertically combined window's normal width is 1.0"
                 1.0 (window-normal-size b #t)))))

;;--------------------------------------------------------------
(test-end "window-normal-size")

(test-begin "window-resize")
;;--------------------------------------------------------------
;; `window-resize` (`window.el:2901`). Measured on a 24-row frame
;; split 10/14: +3 gives 13/11, then -5 gives 8/16, and the rest of
;; the combination follows. The numbers here are the same rule on this
;; tree's 23-row text area: 10/13, +3 -> 13/10, -5 -> 8/15.
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 10 #f)
     (test-equal "a vertical split starts 10/13" '((0 10) (10 13))
                 (map (lambda (w) (list (window-top w) (window-height w)))
                      (window-list frame)))
     (window-resize a 3)
     (test-equal "growing the first window takes its rows from the second"
                 '((0 13) (13 10))
                 (map (lambda (w) (list (window-top w) (window-height w)))
                      (window-list frame)))
     (window-resize a -5)
     (test-equal "shrinking it gives them back"
                 '((0 8) (8 15))
                 (map (lambda (w) (list (window-top w) (window-height w)))
                      (window-list frame)))
     (test-equal "the largest it can grow by is the sibling's room above its minimum"
                 11 (window-resizable a 100))
     (test-equal "asking to grow past that does nothing and answers nil"
                 #f (window-resize-no-error a 100))
     (test-equal "and the layout is unchanged" '((0 8) (8 15))
                 (map (lambda (w) (list (window-top w) (window-height w)))
                      (window-list frame))))))

;;--------------------------------------------------------------
(test-end "window-resize")

(test-begin "window-state-get")
;;--------------------------------------------------------------
(with-frame "one\ntwo\nthree\n"
 (lambda (frame)
   (let* ((a (car (window-list frame)))
          (b (split-window a 10 #f))
          (root (frame-root-window frame))
          (state (window-state-get root)))
     (test-equal "the state of a split frame is a horizontal combination"
                 'vc (cadr state))
     (test-equal "the head records twelve minimum sizes"
                 12 (length (car state)))
     (test-equal "and the names are Emacs's"
                 '(min-height min-width min-height-ignore min-width-ignore
                              min-height-safe min-width-safe
                              min-pixel-height min-pixel-width
                              min-pixel-height-ignore min-pixel-width-ignore
                              min-pixel-height-safe min-pixel-width-safe)
                 (map car (car state)))
     (test-equal "the root's total height is the frame's text rows"
                 23 (window--state-ref 'total-height state))
     (test-equal "its pixel height is the rows times the character height"
                 23 (window--state-ref 'pixel-height state))
     (test-equal "the first child's total height is its own"
                 10 (window--state-ref 'total-height (state-child state)))
     (test-equal "the last child is marked so"
                 #t (and (window--state-ref 'last (car (reverse state))) #t))
     (test-equal "the first child is not"
                 #f (window--state-ref 'last (state-child state)))
     (test-equal "each child carries its buffer"
                 (buffer-name (window-buffer a))
                 (buffer-name (car (window--state-ref 'buffer (state-child state)))))
     (test-equal "and its point as a marker" #t
                 (markerp (window--state-ref
                           'point (window--state-ref 'buffer (state-child state))))))))

;; WRITABLE: buffer names and positions, not buffers and markers, so
;; the state can be written to a file and read back.
(with-frame "one\ntwo\nthree\n"
 (lambda (frame)
   (let* ((state (window-state-get (frame-root-window frame) #t))
          (buffer-state (window--state-ref 'buffer state)))
     (test-equal "a writable state names the buffer" #t
                 (string? (car buffer-state)))
     (test-equal "and records point as a position" #f
                 (markerp (window--state-ref 'point (cdr buffer-state)))))))

;;--------------------------------------------------------------
(test-end "window-state-get")

(test-begin "window-state-put")
;;--------------------------------------------------------------
;; Restoring a state into the same frame: the layout, the buffers, and
;; the selected window come back.
(with-frame "one\ntwo\nthree\n"
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 10 #f)
     (let ((state (window-state-get (frame-root-window frame))))
       (delete-window (cadr (window-list frame)))
       (test-equal "one window before the restore" 1 (length (window-list frame)))
       (window-state-put state (frame-root-window frame))
       (test-equal "the split is back, with its sizes"
                   '((0 10 0 80) (10 13 0 80)) (rects frame))
       (test-equal "and the same buffer in both"
                   (buffer-name (window-buffer a))
                   (buffer-name (window-buffer (car (window-list frame)))))))))

;; The state of the whole frame put into an internal root: Emacs
;; replaces the root with a fresh live window and rebuilds the tree in
;; it.
(with-frame "one\n"
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 30 #t)
     (let ((state (window-state-get (frame-root-window frame))))
       (window-state-put state (frame-root-window frame))
       (test-equal "a horizontal combination is rebuilt in a new window"
                   '((0 30) (30 50))
                   (map (lambda (w) (list (window-left w) (window-width w)))
                        (window-list frame)))))))

;; Point, start and the window's parameters travel with the state.
(with-frame "one\ntwo\nthree\nfour\nfive\n"
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (goto-char 7)
     ;; A window parameter is only state if `window-persistent-parameters`
     ;; says it is (`window.el:6379`). Emacs's default list does not
     ;; include an application's own, so the test declares one.
     (*window-persistent-parameters*
      (cons (cons 'my-parameter #t) (*window-persistent-parameters*)))
     (set-window-parameter a 'my-parameter 'kept)
     (let ((state (window-state-get (frame-root-window frame))))
       (goto-char 1)
       (set-window-parameter a 'my-parameter #f)
       (window-state-put state (frame-root-window frame))
       (test-equal "point is restored" 7 (window-point a))
       (test-equal "and a persistent parameter with it"
                   'kept (window-parameter a 'my-parameter))))))

;; A window's dedicated flag is part of the state.
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (set-window-dedicated-p a 'soft)
     (let ((state (window-state-get (frame-root-window frame))))
       ;; The buffer's entries hang off the `(buffer ...)` sublist, and
       ;; Emacs's `assq` does not descend into a sublist: measured,
       ;; `(assq 'dedicated STATE)` on the whole state is nil while
       ;; `(assq 'dedicated (cdr (assq 'buffer STATE)))` is the entry.
       (test-equal "the state records the dedicated flag"
                   'soft (window--state-ref
                          'dedicated
                          (window--state-ref 'buffer state)))
       (set-window-dedicated-p a #f)
       (window-state-put state (frame-root-window frame))
       (test-equal "and puts it back" 'soft (window-dedicated-p a))))))

;; `window-state-buffers` names every buffer the state mentions.
(with-frame "one\n"
 (lambda (frame)
   (let ((state (window-state-get (frame-root-window frame))))
     ;; Emacs answers the buffer *twice* here: `window-state-buffers`
     ;; reads the root's own entry and then walks into the root's node,
     ;; whose `(buffer ...)` entry is the same one. Measured:
     ;; `(length (window-state-buffers (window-state-get)))` is 2 in
     ;; `emacs -Q --batch`.
     (test-equal "a one-window state names its buffer twice, as Emacs does"
                 2 (length (window-state-buffers state)))
     (test-equal "and it is the frame's buffer"
                 (buffer-name (window-buffer (car (window-list frame))))
                 (buffer-name (car (window-state-buffers state)))))))

;;--------------------------------------------------------------
(test-end "window-state-put")

(test-begin "window-deletable-p")
;;--------------------------------------------------------------
;; `window-deletable-p` (`window.el:4199`): a leaf can be deleted; the
;; frame's root only by deleting the frame, and only while another
;; frame exists.
;; **Several frames are live by the time this runs** - every test above
;; makes one and none is deleted - so the root answers `frame`: Emacs
;; refuses only when it is the *last* frame. Measured, with one frame
;; live, `(window-deletable-p (frame-root-window))` is nil and with two
;; it is `frame`.
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 10 #f)
     (test-equal "a leaf window can be deleted" #t (window-deletable-p a))
     (test-equal "the root is deletable while another frame exists"
                 'frame (window-deletable-p (frame-root-window frame))))))

(test-end "window-deletable-p")

;;--------------------------------------------------------------
(test-begin "window-combinations")
;;--------------------------------------------------------------
;; `split-window`'s parent rule (`window.c:5427`): "Set combination_limit
;; if we have to make a new parent window. We do that if either
;; `window-combination-limit` is t, or OLD has no parent, or OLD is
;; ortho-combined." Otherwise the new window joins OLD's combination -
;; which is what makes three splits of one window one combination of
;; three rather than a chain of nested pairs. Emacs's own answers for
;; the same three splits.
(with-frame ""
 (lambda (frame)
   (let* ((a (car (window-list frame))))
     (split-window a 6 #f)
     (let* ((b (cadr (window-list frame)))
            (c (split-window b 6 #f))
            (root (frame-root-window frame)))
       (test-equal "three splits of one window make one combination of three"
                   3 (window-child-count root))
       (test-equal "all three are children of the root"
                   '(#t #t #t)
                   (map (lambda (w) (eq? (window-parent w) root))
                        (window-list frame)))
       (test-equal "the first keeps the top of the frame"
                   '(0 6) (list (window-top a) (window-height a)))
       (test-equal "the middle sits below it"
                   '(6 6) (list (window-top b) (window-height b)))
       (test-equal "and the last below that"
                   '(12 11) (list (window-top c) (window-height c)))
       ;; A horizontal split of the bottom window is ortho-combined with
       ;; its parent, so it gets a combination of its own.
       (let ((d (split-window c 20 #t)))
         (test-equal "an ortho split makes a new parent"
                     #t (eq? (window-parent c) (window-parent d)))
         (test-equal "... which is not the root"
                     #f (eq? (window-parent c) root))
         (test-equal "... and the root still has three children"
                     3 (window-child-count root)))))))

;; `window-main-window` (`window.el:914`): with no side windows on the
;; frame it is the root window.
(with-frame ""
 (lambda (frame)
   (test-equal "the main window of a frame with no side windows is its root"
               #t (eq? (window-main-window) (frame-root-window frame)))
   (test-equal "a leaf has no children"
               0 (window-child-count (car (window-list frame))))))

;; `combine-windows` (`window.c:5213`): the run from FIRST to LAST
;; becomes one internal window in their place.
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 6 #f)
     (split-window (cadr (window-list frame)) 6 #f)
     (let* ((root (frame-root-window frame))
            (kids (window-children root))
            (b (cadr kids))
            (c (caddr kids))
            (p (combine-windows b c)))
       (test-equal "combining the last two children leaves two children"
                   2 (window-child-count root))
       (test-equal "the new parent spans both"
                   17 (window-height p))
       (test-equal "and starts where the first of them did"
                   6 (window-top p))
       (test-equal "its children are the two that were combined"
                   '(#t #t)
                   (map (lambda (w) (eq? (window-parent w) p)) (list b c)))
       (test-equal "the first child is left alone"
                   #t (eq? (car kids) (car (window-children root))))
       (test-equal "combining a window with itself is refused"
                   "Cannot combine a window with itself"
                   (guard (e (#t (exception-message e)))
                     (combine-windows b b)))
       (test-equal "the whole combination is already a combination"
                   #f (combine-windows (car (window-children root))
                                       (car (reverse (window-children root)))))))))

;; `delete-window` gives the deleted window's space to ONE sibling - its
;; previous one when it has one (`window.el:4372`).
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 6 #f)
     (split-window (cadr (window-list frame)) 6 #f)
     (let ((b (cadr (window-list frame))))
       (delete-window b)
       (test-equal "deleting the middle window gives its rows to the one above"
                   '((0 12) (12 11))
                   (map (lambda (w) (list (window-top w) (window-height w)))
                        (window-list frame)))
       (test-equal "and leaves the combination at two children"
                   2 (window-child-count (frame-root-window frame)))))))

;; `window-get-split-combination` (`window-x.el:417`): "the part which
;; does not include TAB's selected window".
;;
;; **It really does combine** - `combine-windows` rewrites the tree - so
;; each call needs a frame of its own; a second call on the same frame
;; sees the combination the first one made.
(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 6 #f)
     (split-window (cadr (window-list frame)) 6 #f)
     ;; The selected window is the first one, and with ARG 1 the pivot
     ;; is the first child: the selected window is on the pivot's side,
     ;; so the combination split off is the other two.
     (let ((comb (window-get-split-combination (frame-root-window frame) 1)))
       (test-equal "the combination is the other side of the pivot"
                   2 (window-child-count comb))
       (test-equal "and it begins below the first window"
                   6 (window-top comb))))))

(with-frame ""
 (lambda (frame)
   (let ((a (car (window-list frame))))
     (split-window a 6 #f)
     (split-window (cadr (window-list frame)) 6 #f)
     ;; With ARG -1 the pivot is the second child, the selected window
     ;; is to its left, and the part split off is the last window. The
     ;; last child is read first: the call rewrites the tree.
     (let* ((root (frame-root-window frame))
            (last (caddr (window-children root))))
       (test-equal "counting from the end takes the right-hand part"
                   #t (eq? (window-get-split-combination root -1) last))))))

(test-end "window-combinations")
