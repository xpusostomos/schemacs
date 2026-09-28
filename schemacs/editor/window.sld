(define-library (schemacs editor window)
  ;; This library mirrors GNU Emacs's `window.el': the window commands -
  ;; `split-window-below' (C-x 2), `split-window-right' (C-x 3),
  ;; `delete-window' (C-x 0), `delete-other-windows' (C-x 1) and
  ;; `other-window' (C-x o) - and the geometry they work in.
  ;;
  ;; The window *record* and its geometry queries are in
  ;; `(schemacs editor frame)', which is `window.c`'s half (`window-edges',
  ;; `window-body-height', `window-right-border?'); what is here is the
  ;; half that makes and removes windows.
  ;;
  ;; One thing here is a knowing deviation, and the tree below it is what
  ;; it stands in for. GNU Emacs keeps its windows in a tree, and
  ;; `delete-window' asks the window's parent combination which of its
  ;; siblings take over the space. This project keeps a flat list, so
  ;; which windows take over is inferred from the rectangles - the
  ;; row-band/column-band/adjacency search in `DELETE-WINDOW' - and the
  ;; inference is only right while the layout can be read back off the
  ;; rectangles. It is documented as a deviation in NCURSES-PLAN.txt and
  ;; goes when the window tree does.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `split-window-below' and `split-window-right' take an optional
    ;; size, which is a `case-lambda'.
    (scheme case-lambda)
    (only (schemacs editor command)
          new-command new-count-command uarg->integer)
    (only (schemacs editor engine)
          copy-marker new-text-editor set-marker! set!text-editor-buffer-name
          set!text-editor-file-name text-editor-buffer-name
          text-editor-get-cursor text-editor-modified? text-editor-set-cursor
          text-editor-type?)
    ;; `define-key' and the global map: the window keys are stated here,
    ;; beside the commands they run.
    (only (schemacs editor keymap)
         define-key
         *default-keymap*)
    (only (schemacs editor frame)
          %window-point
          *current-frame* current-editor frame-height frame-width
          make<ncurses-window> ncurses-frame-quit-cont
          ncurses-frame-selected-window ncurses-frame-windows select-window
          selected-window set!ncurses-frame-editor set!ncurses-frame-message
          set!ncurses-frame-windows set!window-children set!window-height
          set!window-left set!window-parent set!window-top set!window-top-line
          set!window-buffer set!window-width set-window-point!
          window-buffer window-children
          window-edges window-height window-left window-list window-parent
          window-top window-top-line window-width)
    ;; `display-buffer' puts what it shows in the buffer list's
    ;; most-recently-used order, which is Emacs's `record_buffer';
    ;; `pop-to-buffer' makes a buffer current by name when a string is
    ;; what it was given, and `switch-to-buffer' does the same.
    (only (schemacs editor buffer)
          bury-buffer get-buffer-create record-buffer! set-buffer)
    )

  (export
   delete-other-windows
   delete-other-windows-command
   delete-window
   delete-window-command
   display-buffer
   get-buffer-window
   list-substitute
   list-without
   other-window
   other-window-command
   pop-to-buffer
   quit-window
   pop-to-buffer-same-window
   split-window-below
   split-window-below-command
   split-window-right
   split-window-right-command
   switch-to-buffer
   switch-to-buffer-other-window
   window-absorb!
   window-min-height
   window-min-width
   window-position
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Windows
    ;;
    ;; The commands that make, remove and move between windows, named
    ;; and bound as GNU Emacs names and binds them: C-x 2
    ;; `split-window-below', C-x 1 `delete-other-windows', C-x 0
    ;; `delete-window' and C-x o `other-window'. Only splits one above
    ;; the other are made for now, which is the shape the completions
    ;; window needs; `split-window-right' (C-x 3) is the other half of
    ;; the work, and the window record already carries the columns for
    ;; it.

    (define window-min-height
      ;; The smallest a window may be made, in rows including its mode
      ;; line: GNU Emacs's `window-min-height'. Splitting a window into
      ;; pieces smaller than this signals an error rather than making a
      ;; window nothing can be read in.
      ;;--------------------------------------------------------------
      4)

    (define window-min-width
      ;; The narrowest a window may be made, in columns: GNU Emacs's
      ;; `window-min-width'.
      ;;--------------------------------------------------------------
      10)

    (define (window-position window windows)
      ;; Where WINDOW sits in the list WINDOWS, or #f when it is not
      ;; there.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (rest windows))
        (cond
         ((null? rest) #f)
         ((eq? (car rest) window) i)
         (else (loop (+ 1 i) (cdr rest))))))

    (define (list-without item lst)
      (cond
       ((null? lst) '())
       ((eq? (car lst) item) (cdr lst))
       (else (cons (car lst) (list-without item (cdr lst))))))

    (define (list-substitute item replacement lst)
      ;; LST with ITEM replaced by REPLACEMENT. A split puts an internal
      ;; window where a leaf stood, in the leaf's own place in the list, so
      ;; that the order the windows are in - and with it the cyclic order
      ;; `OTHER-WINDOW' walks - is the order they are arranged in.
      ;;--------------------------------------------------------------
      (cond
       ((null? lst) '())
       ((eq? (car lst) item) (append replacement (cdr lst)))
       (else (cons (car lst) (list-substitute item replacement (cdr lst))))))

    (define (make-window-parent window new top height left width)
      ;; The internal window a split inserts in WINDOW's place: it holds
      ;; WINDOW and NEW, and occupies what WINDOW occupied before the split.
      ;;
      ;; GNU Emacs makes a *new* internal window here and leaves WINDOW a
      ;; leaf, so that a command holding WINDOW across a split still holds a
      ;; window that shows a buffer, and the split window stays the selected
      ;; one. Only leaves hold a buffer or point, which is why this one has
      ;; neither.
      ;;--------------------------------------------------------------
      (make<ncurses-window> #f #f 0 top height left width
                            (window-parent window) (list window new)))

    (define (install-window-parent! frame window parent)
      ;; Put PARENT where WINDOW was in the tree, in WINDOW's own place in
      ;; the list, so that the order the windows are in - and with it the
      ;; cyclic order `OTHER-WINDOW' walks - is the order they are arranged
      ;; in. Its children take their parent from it.
      ;;--------------------------------------------------------------
      (let ((grandparent (window-parent window)))
        (set!window-parent (car (window-children parent)) parent)
        (set!window-parent (cadr (window-children parent)) parent)
        (if grandparent
            (set!window-children
             grandparent
             (list-substitute window (list parent) (window-children grandparent)))
            (set!ncurses-frame-windows
             frame (list-substitute window (list parent)
                                    (ncurses-frame-windows frame))))
        parent))

    (define (split-window-below window size)
      (let* ((frame (*current-frame*))
             (height (window-height window))
             (upper (cond ((not size) (floor-quotient (+ height 1) 2))
                          ((< 0 size) size)
                          (else (- height (abs size)))))
             (lower (- height upper)))
        (when (or (< upper 1) (< lower 1)
                  (and (not size)
                       (or (< upper window-min-height)
                           (< lower window-min-height))))
          (error "Size of new window too small"))
        (let ((top (window-top window))
              (left (window-left window))
              (width (window-width window)))
          (set!window-height window upper)
          (let ((new (make<ncurses-window>
                      (window-buffer window)
                      (copy-marker (window-buffer window)
                                   (text-editor-get-cursor (window-buffer window)))
                      (window-top-line window)
                      (+ top upper)
                      lower
                      left
                      width
                      #f '())))
            (install-window-parent!
             frame window
             (make-window-parent window new top height left width))
            new))))

    (define (split-window-right window size)
      (let* ((frame (*current-frame*))
             (width (window-width window))
             (left (cond ((not size) (floor-quotient (+ width 1) 2))
                         ((< 0 size) size)
                         (else (- width (abs size)))))
             (right (- width left)))
        (when (or (< left 1) (< right 1)
                  (and (not size)
                       (or (< left window-min-width)
                           (< right window-min-width))))
          (error "Size of new window too small"))
        (let ((top (window-top window))
              (start (window-left window))
              (height (window-height window)))
          (set!window-width window left)
          (let ((new (make<ncurses-window>
                      (window-buffer window)
                      (copy-marker (window-buffer window)
                                   (text-editor-get-cursor (window-buffer window)))
                      (window-top-line window)
                      top
                      height
                      (+ start left)
                      right
                      #f '())))
            (install-window-parent!
             frame window
             (make-window-parent window new top height start width))
            new))))

    (define (absorb-into! window edge delta)
      ;; WINDOW gains DELTA at EDGE ('left, 'right, 'top or 'bottom), and so
      ;; does each of its children that reached that edge - a child that did
      ;; not is not beside what was removed, so there is no room for it there.
      ;; Only leaves show a buffer, so the growth has to arrive at them: an
      ;; internal window's rectangle is the union of its children's.
      ;;--------------------------------------------------------------
      (let ((before (window-edges window)))
        (case edge
          ((right) (set!window-width window (+ (window-width window) delta)))
          ((left) (set!window-left window (- (window-left window) delta))
                  (set!window-width window (+ (window-width window) delta)))
          ((bottom) (set!window-height window (+ (window-height window) delta)))
          ((top) (set!window-top window (- (window-top window) delta))
                 (set!window-height window (+ (window-height window) delta))))
        (for-each
         (lambda (child)
           (let ((ce (window-edges child)))
             (when (case edge
                     ((right) (= (list-ref ce 2) (list-ref before 2)))
                     ((left) (= (car ce) (car before)))
                     ((bottom) (= (list-ref ce 3) (list-ref before 3)))
                     ((top) (= (list-ref ce 1) (list-ref before 1))))
               (absorb-into! child edge delta))))
         (window-children window))))

    (define (get-buffer-window buffer)
      ;; The window showing BUFFER, or false when none does: GNU Emacs's
      ;; `get-buffer-window', which is `window.c''s - it is where a buffer
      ;; can be found by looking at the windows.
      ;;--------------------------------------------------------------
      (let loop ((rest (window-list)))
        (cond ((null? rest) #f)
              ((eq? (window-buffer (car rest)) buffer) (car rest))
              (else (loop (cdr rest))))))

    (define (display-buffer--inhibit-same-window? action)
      ;; Whether ACTION refuses the selected window. GNU Emacs's
      ;; `display-buffer' reads that two ways: a non-list ACTION means
      ;; `inhibit-same-window' outright - which is what `pop-to-buffer''s
      ;; second argument is, and so what `switch-to-buffer-other-window'
      ;; passes - and an action alist may say it in an
      ;; `inhibit-same-window' entry, which is how Emacs's
      ;; `Buffer-menu-other-window' binds `display-buffer-overriding-action'.
      ;;--------------------------------------------------------------
      (cond ((not action) #f)
            ((not (list? action)) #t)
            (else
             (let ((entry (assq 'inhibit-same-window (cdr action))))
               (and entry (cdr entry) #t)))))

    (define (display-buffer buffer . args)
      ;; Show BUFFER in some window without selecting it, and answer with
      ;; that window, or false when there is none: GNU Emacs's
      ;; `display-buffer'.
      ;;
      ;; Emacs's second argument, ACTION, is a list of *action functions*
      ;; tried in order, each answering a window or nil, customizable per
      ;; caller and per buffer name through `display-buffer-alist'. There
      ;; is one policy here, which is what Emacs's default action comes to
      ;; for a buffer like the ones this editor displays, tried in the
      ;; order Emacs tries them:
      ;;
      ;;  1. `display-buffer-reuse-window' - a window already showing
      ;;     BUFFER, unless ACTION refuses the selected one;
      ;;  2. `display-buffer-use-some-window' - some other window, showing
      ;;     something else. Emacs reaches this whenever there is another
      ;;     window to use, and it is why `C-x C-b' in a frame that already
      ;;     has two windows replaces what is in the other one rather than
      ;;     splitting again and leaving three;
      ;;  3. `display-buffer-pop-up-window' - split the selected window
      ;;     below and use the new one. This is the only choice when the
      ;;     frame has one window.
      ;;
      ;; A newly split window uses `split-window-sensibly's even split,
      ;; which is the default of `split-window-below'.
      ;;
      ;; A window that starts showing a buffer takes the buffer's own
      ;; point, which is what Emacs's `set_window_buffer' does with
      ;; `(set-marker w->pointm (buffer's point) buffer)'. It matters for
      ;; a buffer that has been put in order before being shown - the
      ;; Buffer Menu moves point onto its first line as it draws - where
      ;; leaving the window's point at the beginning would put it back on
      ;; the titles.
      ;;--------------------------------------------------------------
      (let ((refuse-selected
             (display-buffer--inhibit-same-window?
              (if (pair? args) (car args) #f))))
        (let ((showing
               ;; 1. a window that shows BUFFER already
               (let loop ((rest (window-list)))
                 (cond ((null? rest) #f)
                       ((and (eq? (window-buffer (car rest)) buffer)
                             (not (and refuse-selected
                                       (eq? (car rest) (selected-window)))))
                        (car rest))
                       (else (loop (cdr rest))))))
              (other
               ;; 2. any other window
               (let loop ((rest (window-list)))
                 (cond ((null? rest) #f)
                       ((not (eq? (car rest) (selected-window))) (car rest))
                       (else (loop (cdr rest)))))))
          (cond
           (showing (record-buffer! buffer) showing)
           (other (set!window-buffer other buffer)
                  (set!window-top-line other 0)
                  (set-window-point! other (text-editor-get-cursor buffer))
                  (record-buffer! buffer)
                  other)
           (else
            (let* ((window (selected-window))
                   (height (window-height window)))
              (if (< height (* 2 window-min-height))
                  ;; no room to split: the selected window shows it, which
                  ;; is Emacs's `display-buffer-use-some-window' fallback
                  (begin
                    (set!window-buffer window buffer)
                    (set!window-top-line window 0)
                    (set-window-point! window (text-editor-get-cursor buffer))
                    (record-buffer! buffer)
                    window)
                  ;; split below, and the new window shows it
                  (let ((new (split-window-below window #f)))
                    (set!window-buffer new buffer)
                    (set!window-top-line new 0)
                    (set-window-point! new (text-editor-get-cursor buffer))
                    (record-buffer! buffer)
                    new))))))))

    (define (display-buffer--buffer-or-name thing)
      ;; THING as a buffer, making one when it is a name no buffer has:
      ;; GNU Emacs's `window-normalize-buffer-to-switch-to', which is what
      ;; makes `C-x b newname' give a new buffer rather than an error.
      ;;--------------------------------------------------------------
      (cond ((text-editor-type? thing) thing)
            ((string? thing) (get-buffer-create thing))
            (else (error "not a buffer or a buffer name" thing))))

    (define (pop-to-buffer buffer-or-name . args)
      ;; Show BUFFER-OR-NAME in some window and select that window: GNU
      ;; Emacs's `pop-to-buffer'. ACTION is Emacs's second argument, passed
      ;; to `display-buffer'; NORECORD says not to put the buffer at the
      ;; front of the recently-selected list.
      ;;--------------------------------------------------------------
      (let* ((action (if (pair? args) (car args) #f))
             (norecord (if (and (pair? args) (pair? (cdr args)))
                           (cadr args)
                           #f))
             (buffer (display-buffer--buffer-or-name buffer-or-name))
             (window (display-buffer buffer action)))
        ;; Emacs falls back to making the buffer current when
        ;; `display-buffer' found no window at all.
        (if window (select-window window) (set-buffer buffer))
        (unless norecord (record-buffer! buffer))
        buffer))

    (define (pop-to-buffer-same-window buffer . args)
      ;; Show BUFFER in some window, preferring the selected one: GNU
      ;; Emacs's `pop-to-buffer-same-window', which is `pop-to-buffer' with
      ;; an action that allows the selected window.
      ;;--------------------------------------------------------------
      (pop-to-buffer buffer '(nil (inhibit-same-window . #f))
                     (if (pair? args) (car args) #f)))

    (define (switch-to-buffer buffer-or-name . args)
      ;; Display BUFFER-OR-NAME in the *selected* window: GNU Emacs's
      ;; `switch-to-buffer'. The window shows it from its first line, and
      ;; the window's point is the buffer's - a window is a view of a
      ;; buffer, not a copy of it.
      ;;
      ;; The argument may be a buffer or a name, as in Emacs, and a name
      ;; with no buffer behind it makes one - Emacs's `switch-to-buffer'
      ;; does that too, so `C-x b newname RET' gives a new buffer rather
      ;; than an error. The buffer becomes the most recently used one,
      ;; which is Emacs's `record_buffer', unless NORECORD says otherwise;
      ;; Emacs's third argument, FORCE-SAME-WINDOW, is about minibuffer and
      ;; dedicated windows, which are not modelled here.
      ;;--------------------------------------------------------------
      (let* ((norecord (if (pair? args) (car args) #f))
             (buffer (display-buffer--buffer-or-name buffer-or-name))
             (window (selected-window)))
        (set!window-buffer window buffer)
        (set!window-top-line window 0)
        (set-marker! (%window-point window) (text-editor-get-cursor buffer)
                     buffer)
        (unless norecord (record-buffer! buffer))
        buffer))

    (define (switch-to-buffer-other-window buffer-or-name . args)
      ;; Select BUFFER-OR-NAME in another window: GNU Emacs's
      ;; `switch-to-buffer-other-window', which is `pop-to-buffer' with an
      ;; ACTION that refuses the selected window - so the buffer goes in
      ;; the other window and *that* window is selected, which is what
      ;; leaves the Buffer Menu where it was.
      ;;--------------------------------------------------------------
      (pop-to-buffer buffer-or-name #t (if (pair? args) (car args) #f)))


    (define (window-absorb! taker gone)
      ;; Give TAKER the space that GONE occupied, TAKER being the sibling the
      ;; parent combined it with: whichever edge of TAKER touched GONE gains
      ;; GONE's width or height there.
      ;;
      ;; Which edge that is comes from the two rectangles, and the *parent* is
      ;; what says GONE and TAKER are combined at all - which is the window
      ;; tree's answer, and what the old row-band/column-band search had to
      ;; guess.
      ;;--------------------------------------------------------------
      (let ((t (window-edges taker))
            (g (window-edges gone)))
        (cond
         ((= (list-ref t 2) (car g))
          (absorb-into! taker 'right (window-width gone)))
         ((= (car t) (list-ref g 2))
          (absorb-into! taker 'left (window-width gone)))
         ((= (list-ref t 3) (list-ref g 1))
          (absorb-into! taker 'bottom (window-height gone)))
         (else
          (absorb-into! taker 'top (window-height gone))))
        taker))

    (define (delete-window window)
      (let* ((frame (*current-frame*))
             (parent (window-parent window))
             (siblings (and parent (list-without window (window-children parent))))
             (selected (ncurses-frame-selected-window frame)))
        (cond
         ((and (not parent) (<= (length (ncurses-frame-windows frame)) 1))
          (error "Attempt to delete minibuffer or sole ordinary window"))
         (else
          (for-each (lambda (taker) (window-absorb! taker window)) siblings)
          (if parent
              (let ((rest (list-without window (window-children parent))))
                (set!window-children parent rest)
                (when (<= (length rest) 1)
                  (let ((child (car rest)))
                    (set!window-parent child (window-parent parent))
                    (if (window-parent parent)
                        (set!window-children
                         (window-parent parent)
                         (list-substitute parent
                                          (list child)
                                          (window-children (window-parent parent))))
                        (set!ncurses-frame-windows
                         frame
                         (list-substitute parent
                                          (list child)
                                          (ncurses-frame-windows frame)))))))
              (set!ncurses-frame-windows
               frame (list-without window (ncurses-frame-windows frame))))
          (when (eq? window selected)
            (begin (select-window (car (window-list frame)))
                   (record-buffer!
                    (window-buffer (car (window-list frame))))))
          (set!window-parent window #f)
          (set!window-children window '())
          window))))

    (define (delete-other-windows window)
      ;; GNU Emacs's `delete-other-windows': make WINDOW the frame's
      ;; only window, filling the frame.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (select-window window)
        (record-buffer! (window-buffer window))
        (set!window-top window 0)
        (set!window-left window 0)
        (set!window-height window (max 1 (- (frame-height frame) 1)))
        (set!window-width window (frame-width frame))
        ;; WINDOW becomes the only window of the frame, so it is no longer
        ;; inside anything and holds nothing: the tree is one leaf.
        (set!window-parent window #f)
        (set!window-children window '())
        (set!ncurses-frame-windows frame (list window))
        window))

    (define split-window-below-command
      ;; The command C-x 2 runs. Its prefix argument is the SIZE
      ;; `split-window-below' takes, as a number or false when there was
      ;; none - GNU Emacs's `(interactive "P")'.
      ;;--------------------------------------------------------------
      (new-command
       "split-window-below"
       (lambda (uarg)
         (let ((size (uarg->integer #f uarg)))
           ;; GNU Emacs's `split-window-below' checks this one itself,
           ;; because `split-window' would not.
           (when (and size (< size 0) (< (- size) window-min-height))
             (error "Size of new window too small"))
           (split-window-below (selected-window) size)))
       (case-lambda
        (() (split-window-below (selected-window) #f))
        ((size) (split-window-below (selected-window) size))
        ((size window) (split-window-below window size)))
       "Split the selected window into two, one above the other."
       'uarg))

    (define split-window-right-command
      ;; The command C-x 3 runs, the mirror of `split-window-below-command'.
      ;;--------------------------------------------------------------
      (new-command
       "split-window-right"
       (lambda (uarg)
         (let ((size (uarg->integer #f uarg)))
           ;; GNU Emacs's `split-window-right' checks this one itself,
           ;; because `split-window' would not.
           (when (and size (< size 0) (< (- size) window-min-width))
             (error "Size of new window too small"))
           (split-window-right (selected-window) size)))
       (case-lambda
        (() (split-window-right (selected-window) #f))
        ((size) (split-window-right (selected-window) size))
        ((size window) (split-window-right window size)))
       "Split the selected window into two, side by side."
       'uarg))

    (define delete-window-command
      (new-command
       "delete-window"
       (lambda () (delete-window (selected-window)))
       (case-lambda
        (() (delete-window (selected-window)))
        ((window) (delete-window window)))
       "Remove the selected window, leaving its rows or columns to the
windows it was combined with."))

    (define delete-other-windows-command
      (new-command
       "delete-other-windows"
       (lambda () (delete-other-windows (selected-window)))
       (case-lambda
        (() (delete-other-windows (selected-window)))
        ((window) (delete-other-windows window)))
       "Make the selected window the only window on the frame."))

    ;; Selecting a window in GNU Emacs also puts its buffer at the front of
    ;; the buffer list, which is what makes the Buffer Menu list the buffers
    ;; in the order they were last looked at. That is `record_buffer' in
    ;; `window.c', which reaches into buffer.c's alist because in C the two
    ;; halves are one program; here they are two libraries and
    ;; `(select-window)' is in `(schemacs editor frame)', which cannot reach
    ;; the buffer list - the buffer library imports it - so the window
    ;; commands below record for themselves. `pop-to-buffer' and
    ;; `switch-to-buffer' do it with their own NORECORD argument.

    (define (quit-window)
      ;; GNU Emacs's `quit-window' (q in the Buffer Menu), which is
      ;; `window.el''s: take this window off the frame and bury the buffer
      ;; it was showing. A frame's only window cannot be removed, and then
      ;; the buffer is just buried.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (window (ncurses-frame-selected-window frame))
             (buffer (window-buffer window)))
        (bury-buffer buffer)
        (if (> (length (window-list)) 1)
            (delete-window window)
            #f)))

    (define (other-window count)
      ;; Select the COUNT-th window on from the selected one, cycling
      ;; round the frame's windows: GNU Emacs's `other-window'. A negative
      ;; COUNT goes the other way, which is how a command that has just
      ;; moved to a window it made gets back to the one it came from.
      ;;--------------------------------------------------------------
      (let* ((windows (window-list))
             (n (length windows))
             (at (window-position (selected-window) windows))
             (window (list-ref windows (modulo (+ at count) n))))
        (select-window window)
        (record-buffer! (window-buffer window))
        window))

    (define other-window-command
      ;; GNU Emacs's `other-window': select the next window, or the
      ;; COUNT-th one on, cycling round the frame's windows.
      ;;--------------------------------------------------------------
      (new-count-command
       "other-window"
       (lambda (count) (other-window count))
       "Select the next window, COUNT windows on."))

    ;; The window keys, on the ones GNU Emacs binds them to.
    (define-key *default-keymap* (list (list 'ctrl #\x) #\2)
      split-window-below-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\3)
      split-window-right-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\1)
      delete-other-windows-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\0)
      delete-window-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\o)
      other-window-command)

    ))
