(import
 (scheme base)
 (scheme write)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor dispnew) current-display)
 (only (schemacs editor test-display) <test-display>)
 (only (schemacs editor frame)
       *current-frame* *current-buffer* *default-frame-alist*
       new-frame frame-selected-window
       frame-change-stamp frame-window-change
       set-window-buffer! select-window selected-frame
       window-parent window-combination-axis window-combined-p
       window-width window-left)
 (only (schemacs editor window)
       split-window delete-window delete-other-windows
       adjust-window-trailing-edge
       current-window-configuration set-window-configuration
       *window-configuration-change-hook*
       run-window-change-functions)
 (only (schemacs editor buffer) get-buffer-create))

;; Regression tests for `run_window_change_functions` (`window.c:4111`) -
;; the mechanism that decides when `window-configuration-change-hook`
;; runs, and so when `tab-bar-history-mode` records a change.
;;
;; **Every expectation here is Emacs 31.1's**, measured in an `emacs -nw`
;; pty by counting the hook's calls after a `redisplay`:
;;
;;   split                            1
;;   no-op set-window-configuration   0
;;   real set-window-configuration    1
;;   select-window (same window)      0
;;   set-window-buffer (different)    1
;;   set-window-buffer (same buffer)  0
;;
;; The zero for a no-op restore is the interesting one: `FRAME_WINDOW_CHANGE`
;; is set by the restore, but the hook is gated on a window really having
;; changed buffer or size or been deleted, which a restore of the layout
;; the frame already has does not do.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)

(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define hook-calls 0)

(define (count-hook-call . _)
  (set! hook-calls (+ hook-calls 1)))

(define (fresh-frame)
  (new-frame (get-buffer-create "window-tests") 24 80))

;; Run THUNK as one command would, with a hook that counts, and answer how
;; many times the hook ran. `run-window-change-functions` is what the
;; redisplay calls, in the place `redisplay_internal` calls it.
(define (hook-calls-after thunk)
  (set! hook-calls 0)
  (parameterize ((*window-configuration-change-hook*
                  (cons count-hook-call (*window-configuration-change-hook*))))
    (thunk)
    (run-window-change-functions))
  hook-calls)

(test-begin "schemacs_editor_window")

;; A split is a window change.
(test-equal 1
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (hook-calls-after (lambda ()
                          (split-window (frame-selected-window frame) -12 #f))))))

;; **And restoring the layout the frame already has is not.** The C's
;; `Fset_window_configuration` sets `FRAME_WINDOW_CHANGE` unconditionally
;; (`window.c:3715`) and the hook still does not run, because no window
;; changed buffer or size and none was deleted.
;;
;; The prime first is what a frame has by the time a user is typing: its
;; windows were recorded when they were made (`set_window_buffer` sets the
;; flag and a frame's first redisplay records them). A frame that has
;; never been recorded counts every window as new - in Emacs too.
(test-equal 0
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (run-window-change-functions)
      (hook-calls-after
       (lambda ()
         (set-window-configuration (current-window-configuration)))))))

;; A restore that really changes the layout is one.
(test-equal 1
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (run-window-change-functions)
      (let ((cfg (current-window-configuration)))
        (delete-other-windows (frame-selected-window frame))
        (run-window-change-functions)
        (hook-calls-after (lambda () (set-window-configuration cfg)))))))

;; Deleting a window is a change even though nothing changed buffer or
;; size: the frame simply has fewer windows than it did.
(test-equal 1
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (run-window-change-functions)
      (hook-calls-after
       (lambda () (delete-window (frame-selected-window frame)))))))

;; Selecting the window that is already selected is not a change.
(test-equal 0
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (hook-calls-after
       (lambda () (select-window (frame-selected-window frame)))))))

;; A window showing a different buffer is a "buffer change", which the C
;; counts as a size change as well (`window.c:4186`'s comment: "A buffer
;; change implies a size change because either this window didn't show the
;; buffer before or this window didn't show the buffer the last time").
(test-equal 1
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (hook-calls-after
       (lambda ()
         (set-window-buffer! (frame-selected-window frame)
                             (get-buffer-create "window-tests-other")))))))

;; ... and setting the buffer it already shows is not.
(test-equal 0
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((window (frame-selected-window frame)))
        (set-window-buffer! window (get-buffer-create "window-tests-other"))
        (run-window-change-functions)
        (hook-calls-after
         (lambda ()
           (set-window-buffer! window (get-buffer-create "window-tests-other"))))))))

;; `window_change_record` is the C's `record_unwind_protect_void`
;; (`window.c:4122`), so the flag goes down even when a hook signals. That
;; is what keeps a failing hook from running on every redisplay for ever.
(test-equal #f
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (guard (e (#t #f))
        (parameterize ((*window-configuration-change-hook*
                        (cons (lambda () (error "hook failed"))
                              (*window-configuration-change-hook*))))
          (run-window-change-functions)))
      (frame-window-change frame))))

;; The hook runs with FRAME selected, as `run_window_configuration_change_hook`
;; arranges (`window.c:3826`).
(test-equal #t
  (let ((frame (fresh-frame))
        (calls-on-frame #f))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (parameterize ((*window-configuration-change-hook*
                      (cons (lambda () (set! calls-on-frame (selected-frame)))
                            (*window-configuration-change-hook*))))
        (split-window (frame-selected-window frame) -12 #f)
        (run-window-change-functions))
      (eq? calls-on-frame frame))))

;; The stamp moves once per run that recorded something, the flag goes
;; down with it, and a run with nothing to do does neither.
(test-equal '(#t #f 1 1)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (let* ((before (frame-change-stamp frame))
             (flag-at-start (frame-window-change frame)))
        (run-window-change-functions)
        (let ((after-first (- (frame-change-stamp frame) before)))
          (run-window-change-functions)
          (list flag-at-start
                (frame-window-change frame)
                after-first
                (- (frame-change-stamp frame) before)))))))


;;----------------------------------------------------------------
;; A combination's axis is stored, not guessed
;;----------------------------------------------------------------
;; Emacs keeps it in `w->vchild' / `w->hchild' and `WINDOW_VERTICAL_COMBINATION_P`
;; reads that field. This tree inferred it from the children's
;; rectangles, which a combination down to *one* child cannot answer -
;; and a session that had one (a drag on the vertical line) then treated
;; it as horizontal and tried to resize a frame-wide window: "Failed
;; adjusting window". The axis is stored now, set by the split that makes
;; the combination.
(test-begin "schemacs_editor_window_combination_axis")

(let* ((frame (fresh-frame))
       (a (frame-selected-window frame))
       (b (split-window a #f 'below)))
  (test-equal "a split below makes a vertical combination"
              'vertical (window-combination-axis (window-parent a)))
  (test-equal "the upper window is in a vertical combination"
              #t (window-combined-p a))
  (test-equal "and not in a horizontal one"
              #f (window-combined-p a 'horizontal))
  (let* ((b2 (split-window b #f 'right))
         (parent (window-parent b)))
    (test-equal "a split on the right makes a horizontal combination"
                'horizontal (window-combination-axis parent))
    (test-equal "the outer combination is still vertical"
                'vertical (window-combination-axis (window-parent a)))
    ;; A horizontal drag on the lower pair changes the pair's widths and
    ;; leaves the frame-wide window alone.
    (let ((aw (window-width a))
          (w1 (window-width b))
          (w2 (window-width b2)))
      (adjust-window-trailing-edge b 1 #t #f)
      (test-equal "the pair's left window widened by one"
                  (+ w1 1) (window-width b))
      (test-equal "its sibling gave up one"
                  (- w2 1) (window-width b2))
      (test-equal "the window above the pair keeps the frame's width"
                  aw (window-width a)))))

(test-end "schemacs_editor_window_combination_axis")

(test-end "schemacs_editor_window")
