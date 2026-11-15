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
       new-frame frame-height frame-editor frame-live-p frame-list
       frame-selected-window
       window-list window-buffer window-point window-top window-height
       window-width window-left select-window select-frame
       set-window-buffer! set-window-point! set-window-start! %window-start)
 (only (schemacs editor window)
       split-window delete-window delete-other-windows
       current-window-configuration set-window-configuration
       window-configuration-p window-configuration-frame)
 (only (schemacs editor buffer)
       allocate-buffer buffer-name buffer-pt buffer-beg %kill-buffer
       get-buffer-create with-current-buffer set-point set-buffer
       buffer-live-p *kill-buffer-query-functions*)
 (only (schemacs editor editfns) insert goto-char)
 (only (schemacs editor marker) marker-position))

;; Regression tests for window configurations - `window.c`'s
;; `current-window-configuration` and `set-window-configuration`, which
;; `(schemacs editor window)` ports because restoring one has to ask
;; whether a buffer is alive.
;;
;; Every expectation is what GNU Emacs's `window.c` says the two do; the
;; docstrings are quoted at the tests they settle, and the numbers are
;; the ones a 24x80 `new-frame` with no menu bar gives (23 text rows).

(setvbuf (current-output-port) 'none)

;; The display the frame asks its size of, as `tty-editor-tests` does: an
;; object that answers the interface and draws nowhere.
(define *test-display* (make <test-display>))
(current-display *test-display*)

;; A frame with no menu bar takes no row of its own; the echo area takes
;; the last one, leaving 23 rows of text.
(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define (test-frame ed)
  (new-frame ed 24 80))

(define (frame-with text)
  (let* ((ed (allocate-buffer))
         (frame (test-frame ed)))
    (with-current-buffer ed (insert text))
    (set-point ed (buffer-beg ed))
    frame))

(define (window-rects frame)
  (map (lambda (w) (list (window-top w) (window-height w)))
       (window-list frame)))

(define (window-points frame)
  (map window-point (window-list frame)))

(define (window-starts frame)
  (map (lambda (w) (marker-position (%window-start w)))
       (window-list frame)))

(test-begin "schemacs_editor_window_config")

;; "This describes the number of windows, their sizes and current
;; buffers" - and restoring it puts them back after
;; `delete-other-windows`, because the saved vector holds the window
;; objects themselves. That is the C's own "Kludge Alert! Mark all
;; windows now on frame as `deleted'. Restoring the new configuration
;; `undeletes' any that are in it".
(test-equal '((0 11) (11 12))
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (let ((config (current-window-configuration)))
        (delete-other-windows (frame-selected-window frame))
        (set-window-configuration config)
        (window-rects frame)))))

;; The frame's selected window is part of the configuration:
;; `data->current_window` is restored, so the selection is where it was
;; however the layout was left.
(test-equal '(#t #f)
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (let* ((upper (car (window-list frame)))
             (config (current-window-configuration)))
        (select-window (cadr (window-list frame)))
        (set-window-configuration config)
        (list (eq? (frame-selected-window frame) upper)
              (eq? (frame-selected-window frame)
                   (cadr (window-list frame))))))))

;; "and for each displayed buffer, where display starts, and the
;; position of point." Two windows on *different* buffers keep a point
;; each: the one that is not selected comes back to 2, and the selected
;; one comes back to 1 and not 3 - it shows the buffer that was current
;; when the configuration was recorded, and "an exception is made for
;; point in the current buffer". Measured on Emacs 31.1 with the same
;; steps: `(mapcar #'window-point (window-list))` is `(1 2)`.
(test-equal '(1 2)
  (let* ((frame (frame-with "alpha\nbeta\ngamma\n"))
         (other (get-buffer-create "wc-second"))
         (wins (parameterize ((*current-frame* frame) (*current-buffer* #f))
                 (split-window (frame-selected-window frame) -12 #f)
                 (window-list frame))))
    (with-current-buffer other (insert "second buffer text"))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (set-window-buffer! (cadr wins) other)
      (set-window-point! (car wins) 3)
      (set-window-point! (cadr wins) 2)
      (let ((config (current-window-configuration)))
        (set-window-point! (car wins) 1)
        (set-window-point! (cadr wins) 1)
        (set-buffer (get-buffer-create "wc-third"))
        (set-window-configuration config)
        (window-points frame)))))

;; "An exception is made for point in the current buffer: its value is
;; -not- saved." The C keeps the point the buffer has *now* in
;; `old_point` and writes it back into the recorded window, so restoring
;; a configuration does not move point.
(test-equal '(5 5)
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((ed (window-buffer (frame-selected-window frame))))
        (goto-char 2)
        (let ((config (current-window-configuration)))
          (goto-char 5)
          (set-window-configuration config)
          (list (buffer-pt ed)
                (window-point (frame-selected-window frame))))))))

;; Where each window's display starts is saved with it.
(test-equal '(1 10)
  (let* ((frame (frame-with "one\ntwo\nthree\nfour\nfive\nsix\n"))
         (wins (parameterize ((*current-frame* frame) (*current-buffer* #f))
                 (split-window (frame-selected-window frame) -12 #f)
                 (window-list frame))))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (set-window-start! (cadr wins) 10)
      (let ((config (current-window-configuration)))
        (set-window-start! (cadr wins) 1)
        (set-buffer (get-buffer-create "wc-other"))
        (set-window-configuration config)
        (window-starts frame)))))

;; A window deleted after the configuration was recorded is *undeleted*
;; by the restore, with the buffer it was showing.
(test-equal '(#t (0 11) (11 12))
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (frame-selected-window frame) -12 #f)
      (let* ((config (current-window-configuration))
             (lower (cadr (window-list frame))))
        (delete-window lower)
        (set-window-configuration config)
        (list (eq? (window-buffer (cadr (window-list frame)))
                   (window-buffer (car (window-list frame))))
              (car (window-rects frame))
              (cadr (window-rects frame)))))))

;; `window-configuration-p` and `window-configuration-frame` - "Return
;; the frame that CONFIG, a window-configuration object, is about."
(test-equal '(#t #f #t)
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((config (current-window-configuration)))
        (list (window-configuration-p config)
              (window-configuration-p 'not-a-configuration)
              (eq? (window-configuration-frame config) frame))))))

;; A window whose buffer was killed is kept and shows some other buffer:
;; the default `window-restore-killed-buffer-windows` deletes only a
;; *dedicated* window, and no window here is dedicated.
(test-equal '(#t #t 2)
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame) (*current-buffer* #f)
                   (*kill-buffer-query-functions* '()))
      (split-window (frame-selected-window frame) -12 #f)
      (let* ((config (current-window-configuration))
             (lower (cadr (window-list frame)))
             (lost (window-buffer lower)))
        (%kill-buffer lost)
        (set-window-configuration config)
        (list (not (buffer-live-p lost))
              (not (eq? (window-buffer (cadr (window-list frame))) lost))
              (length (window-list frame)))))))

;; "Normally, this function selects the frame of the CONFIGURATION, but
;; if DONT-SET-FRAME is non-nil, it leaves selected the frame which was
;; current at the start of the function."
(test-equal '(#t #t)
  (let* ((frame-a (frame-with "alpha\nbeta\n"))
         (frame-b (frame-with "gamma\ndelta\n"))
         (config-b (parameterize ((*current-frame* frame-b)
                                  (*current-buffer* #f))
                     (current-window-configuration))))
    (list
     ;; without DONT-SET-FRAME, the configuration's frame is selected
     (parameterize ((*current-frame* frame-a) (*current-buffer* #f))
       (set-window-configuration config-b)
       (eq? (*current-frame*) frame-b))
     ;; with it, the frame that was current stays current
     (parameterize ((*current-frame* frame-a) (*current-buffer* #f))
       (set-window-configuration config-b #t #f)
       (eq? (*current-frame*) frame-a)))))

(test-end "schemacs_editor_window_config")
