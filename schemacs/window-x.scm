(define-library (schemacs window-x)
  ;; This library mirrors GNU Emacs's `lisp/window-x.el' - the window
  ;; operations that belong to no other file. Three of them are about
  ;; frames rather than windows: `split-frame' divides a frame's windows
  ;; into two frames, `merge-frames' puts them back together, and
  ;; `window-make-frame' moves one window to a frame of its own. All
  ;; three stand on `window-get-split-combination', which is the one
  ;; function here.
  ;;
  ;; **Only `window-get-split-combination` is carried.** It is what
  ;; `tab-bar-split-tab` needs (`tab-bar.el:1978`), and `tab-bar.scm`
  ;; imports it for that. The frame commands wait for a `make-frame`
  ;; that can be given a window configuration to start from - in this
  ;; tree a new frame shows the selected window's buffer and copies
  ;; nothing - which is `window-state-put` applied to a new frame's
  ;; root, and nothing has asked for it yet. Also not carried, from the
  ;; same file: the side-window placement functions
  ;; (`display-buffer-in-side-window' and the `window--make-*' helpers)
  ;; and the atomic-window ones (`window-atom-root' and friends) -
  ;; neither side nor atomic windows exist in this tree.
  ;;
  ;; See `(schemacs window)` for the tree algebra and
  ;; `combine-windows` it is built on.

  (import
    (scheme base)
    (only (schemacs frame)
          frame-selected-window
          window-child window-frame window-last-child
          window-next-sibling window-parent)
    (only (schemacs window)
          combine-windows window-child-count))

  (export window-get-split-combination)

  (begin

    (define (window-get-split-combination window arg)
      ;; GNU Emacs's `window-get-split-combination` (`window-x.el:417`):
      ;; "Return window combination suitable for `split-frame`. WINDOW is
      ;; the main window in which the combination should be derived. ARG
      ;; is the argument passed to `split-frame`. Return a combination of
      ;; windows `split-frame` is considered to split off."
      ;;
      ;; The whole of it is arithmetic on the *first level* of WINDOW's
      ;; children: ARG counts child windows, the pivot is the one at that
      ;; position (from the end when ARG is negative), and the answer is
      ;; the side of the pivot that does not hold the selected window -
      ;; the one child itself when that side is a single window, and a
      ;; fresh internal window over the run when it is several.
      ;;--------------------------------------------------------------
      (let* ((reverse (< arg 0))
             ;; "This is where the pivot window is."
             (total-window-count (window-child-count window))
             (pivot-window-pos (- (if reverse
                                      (+ total-window-count arg)
                                      arg)
                                  1))
             (pivot-window (window-child window))
             (active-window (frame-selected-window (window-frame window)))
             ;; "If FRAME's selected window is on the left side of the
             ;; pivot window."
             (active-window-on-left (eq? pivot-window active-window)))
        ;; "We want the 2nd level window that the active window is a part
        ;; of" - the child of WINDOW that the selected window descends
        ;; from.
        (let ((active-window
               (let climb ((aw active-window))
                 (if (eq? (window-parent aw) window)
                     aw
                     (climb (window-parent aw))))))
          ;; "Now we need to find the pivot window."
          (let ((pivot-window
                 (let loop ((n 0) (pivot pivot-window))
                   (if (< n pivot-window-pos)
                       (let ((next (window-next-sibling pivot)))
                         (when (eq? active-window next)
                           (set! active-window-on-left #t))
                         (loop (+ n 1) next))
                       pivot))))
            ;; "Now we have pivot-window set, and we just need to
            ;; combine. We want to split away all windows from the side of
            ;; the pivot that doesn't contain the active window."
            (let* ((first (window-child window))
                   (last (window-last-child window))
                   (next-pivot-sib (window-next-sibling pivot-window))
                   (right-comb (if (eq? next-pivot-sib last)
                                   last
                                   (combine-windows next-pivot-sib last)))
                   (left-comb (if (eq? first pivot-window)
                                  first
                                  (combine-windows first pivot-window))))
              (if active-window-on-left right-comb left-comb))))))))
