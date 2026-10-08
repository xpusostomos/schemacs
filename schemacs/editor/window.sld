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
          current-prefix-arg define-command uarg->integer)
    (only (schemacs editor engine)
          copy-marker new-text-editor set-marker! marker-position
          set!text-editor-buffer-name
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
          ;; the window's own hscroll state, which `set-window-hscroll!'
          ;; and the scroll commands maintain
          %window-hscroll %window-min-hscroll %window-suspend-auto-hscroll?
          set!%window-hscroll set!%window-min-hscroll
          set!%window-suspend-auto-hscroll?
          *current-frame* current-editor frame-height frame-width
          window-type?
          make<window> frame-quit-cont
          frame-selected-window frame-windows select-window
          selected-window set!frame-editor set!frame-message
          set!frame-windows set!window-children set!window-height
          set!window-left set!window-parent set!window-top
          set-window-buffer! set!window-width set-window-point!
          window-buffer window-children
          window-edges window-frame window-height window-left window-list
          window-parent
          window-body-width window-top window-width
          %window-start set!%window-start
          %window-start-at-line-beg set!%window-start-at-line-beg
          %window-end-pos set!%window-end-pos
          %window-end-vpos set!%window-end-vpos
          %window-end-valid? set!%window-end-valid?
          %window-base-line-number set!%window-base-line-number
          %window-base-line-pos set!%window-base-line-pos
          set-window-start! window-start-at-line-beg)
    ;; `display-buffer' puts what it shows in the buffer list's
    ;; most-recently-used order, which is Emacs's `record_buffer';
    ;; `pop-to-buffer' makes a buffer current by name when a string is
    ;; what it was given, and `switch-to-buffer' does the same.
    (only (schemacs editor buffer)
          bury-buffer buffer-local-value default-directory erase-buffer
          get-buffer-create
          kill-all-local-variables kill-buffer other-buffer record-buffer!
          set-buffer
          set!buffer-default-directory set!buffer-file-name set!buffer-read-only
          set-buffer-modified-p set-buffer-local-value!
          with-current-buffer *inhibit-read-only*)
    ;; `run-hooks' is `subr.el''s, and the two temp-buffer hooks below
    ;; are run through it.
    (only (schemacs editor subr) kbd run-hooks)
    ;; `temp-buffer-window-show' puts point at the beginning of the
    ;; buffer it is about to show, which `goto-char' is.
    (only (schemacs editor editfns) goto-char point-min)
    )

  (export
   delete-other-windows
   delete-window
   display-buffer
   get-buffer-window
   list-substitute
   list-without
   other-window
   pop-to-buffer
   quit-window
   pop-to-buffer-same-window
   split-window
   split-window-below
   split-main-window-below
   split-window-right
   switch-to-buffer
   switch-to-buffer-other-window
   window-absorb!
   window-min-height
   *cursor-in-echo-area*
   window-min-width
   display-buffer-below-selected
   quit-restore-window
   temp-buffer-window-setup
   temp-buffer-window-show
   window-live-p
   with-current-buffer-window
   with-selected-window
   window-position
   window-hscroll
   set-window-hscroll!
   scroll-left
   scroll-right
   )

  (begin

    (define *cursor-in-echo-area* (make-parameter #f))
    ;; ^ GNU Emacs's `cursor-in-echo-area', declared `DEFVAR_BOOL' in
    ;; `dispnew.c' and so false by default: whether to put a cursor in
    ;; the minibuffer at the end of a message there. False means the echo
    ;; area shows its message with no cursor, which is what a window
    ;; whose minibuffer is not being read wants.
    ;;
    ;; It is a parameter here rather than a variable, as this tree's
    ;; single-valued globals are; it is with `internal-show-cursor'
    ;; because `get_window_cursor_type' reads the two together - when
    ;; this is true and the window is the echo area's, the cursor's type
    ;; comes from the echo area rather than from the window.

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
      ;; An internal window shows no buffer, and so has neither a start
      ;; nor a point: the C asserts exactly that of one
      ;; (`eassert (!BUFFERP (w->contents) && NILP (w->start) && NILP
      ;; (w->pointm))', `window.c:219').
      (make<window> (window-frame window) #f #f #f #f 0 0 #f 0 0
                            top height left width
                            (window-parent window) (list window new)
                            0 0 #f 0))

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
            (set!frame-windows
             frame (list-substitute window (list parent)
                                    (frame-windows frame))))
        parent))

    (define (split-window window size horizontal)
      ;; GNU Emacs's `split-window' - `Fsplit_window' in window.c - the
      ;; one primitive every split is: divide the live window WINDOW in
      ;; two, the first part SIZE rows (or columns, for a horizontal
      ;; split) and the rest going to the new one - a positive SIZE on
      ;; the first part, a negative one -SIZE on the second, and half
      ;; and half (or close to it) when there is no SIZE. HORIZONTAL
      ;; splits side by side; otherwise the new window is below.
      ;;
      ;; `split-window-below' and `split-window-right' - window.el's
      ;; commands - read the argument from the keyfinger and call this;
      ;; a bare `C-x 2' gives both halves the same height
      ;; `window-min-height' or more, exactly as Emacs's plain
      ;; `(split-window)' does.
      ;;--------------------------------------------------------------
      (if horizontal
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
              (let ((new (make<window>
                          ;; the new window is on the frame of the one
                          ;; it split: `frame = WINDOW_FRAME (o)'
                          ;; (`window.c:5412'), `wset_frame (n, frame)'
                          ;; (`:5583')
                          (window-frame window)
                          (window-buffer window)
                          (copy-marker (window-buffer window)
                                       (text-editor-get-cursor (window-buffer window)))
                          ;; the start and whether it is a line beginning
                          ;; are copied together, as the C copies them
                          ;; (`save_window_save', `window.c:8374')
                          (copy-marker (window-buffer window)
                                       (marker-position (%window-start window)))
                          (%window-start-at-line-beg window)
                          0 0 #f 0 0
                          top
                          height
                          (+ start left)
                          right
                          #f '()
                          0 0 #f 0)))
                (install-window-parent!
                 frame window
                 (make-window-parent window new top height start width))
                new)))
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
              (let ((new (make<window>
                          ;; the new window is on the frame of the one
                          ;; it split: `frame = WINDOW_FRAME (o)'
                          ;; (`window.c:5412'), `wset_frame (n, frame)'
                          ;; (`:5583')
                          (window-frame window)
                          (window-buffer window)
                          (copy-marker (window-buffer window)
                                       (text-editor-get-cursor (window-buffer window)))
                          (copy-marker (window-buffer window)
                                       (marker-position (%window-start window)))
                          (%window-start-at-line-beg window)
                          0 0 #f 0 0
                          (+ top upper)
                          lower
                          left
                          width
                          #f '()
                          0 0 #f 0)))
                (install-window-parent!
                 frame window
                 (make-window-parent window new top height left width))
                new)))))
    (define (split-main-window-below buffer size)
      ;; Show BUFFER in a new window at the bottom of the frame, SIZE rows
      ;; tall and spanning the frame's whole width: GNU Emacs's
      ;; `display-buffer-at-bottom' does `(split-window-no-error
      ;; (window-main-window))', and with no side windows - which is all
      ;; this editor has - the main window is the frame's root window.
      ;; Splitting the *root* is what makes a completion list a
      ;; full-width window at the bottom even in a frame that is divided
      ;; left and right: the window above keeps its own arrangement and
      ;; gives up SIZE rows at the bottom.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (main (car (frame-windows frame)))
             (top (window-top main))
             (left (window-left main))
             (width (window-width main))
             (total (window-height main)))
        (when (>= size total)
          (error "Size of new window too small" size))
        ;; the frame's windows give up SIZE rows at the bottom
        (absorb-into! main 'bottom (- size))
        (let ((new (make<window>
                    (window-frame main)
                    buffer
                    (copy-marker buffer (text-editor-get-cursor buffer))
                    (copy-marker buffer 1) #t
                    0 0 #f 0 0
                    (+ top (- total size))
                    size
                    left
                    width
                    #f '()
                    0 0 #f 0)))
          (install-window-parent!
           frame main
           (make-window-parent main new top total left width))
          new)))

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

    (define display-buffer--same-window-action
      ;; GNU Emacs's `display-buffer--same-window-action' (window.el:8166):
      ;; "A `display-buffer' action for displaying in the same window.
      ;; Specifies to call `display-buffer-same-window'."
      ;;--------------------------------------------------------------
      (list 'display-buffer-same-window (cons 'inhibit-same-window #f)))

    (define (display-buffer--same-window-action? action)
      ;; Whether ACTION asks for `display-buffer-same-window'. Emacs's
      ;; action lists hold the *function* first and its alist after; this
      ;; tree has one policy rather than a list of action functions, so
      ;; the name is what is read - and it is the name Emacs's own value
      ;; carries. Named rather than faked: no other action function is
      ;; ported, and one that is would have to be dispatched on here.
      ;;--------------------------------------------------------------
      (and (list? action) (eq? (car action) 'display-buffer-same-window)))

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
      (let* ((action (if (pair? args) (car args) #f))
             (refuse-selected (display-buffer--inhibit-same-window? action))
             ;; GNU Emacs's `display-buffer-same-window' (window.el:8500):
             ;; "Display BUFFER in the selected window. ... fails if ALIST
             ;; has an `inhibit-same-window' element whose value is
             ;; non-nil, or if the selected window is a minibuffer window
             ;; or is dedicated to another buffer; in that case, return
             ;; nil. Otherwise, return the selected window." It is the
             ;; first - and for `pop-to-buffer-same-window''s action the
             ;; only - action function, so it is the *first* policy here.
             ;;
             ;; Without it `pop-to-buffer-same-window' fell through to
             ;; the split arm and showed the buffer in a new window below
             ;; the old one: every `find-file' from a minibuffer left two
             ;; windows and the old buffer above, which is not what
             ;; "preferably the same one" means.
             (same-window? (and (display-buffer--same-window-action? action)
                                (not refuse-selected))))
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
           (same-window?
            (let ((window (selected-window)))
              (set-window-buffer! window buffer)
              (record-buffer! buffer)
              window))
           (showing (record-buffer! buffer) showing)
           (other (set-window-buffer! other buffer)
                  (record-buffer! buffer)
                  other)
           (else
            (let* ((window (selected-window))
                   (height (window-height window)))
              (if (< height (* 2 window-min-height))
                  ;; no room to split: the selected window shows it, which
                  ;; is Emacs's `display-buffer-use-some-window' fallback
                  (begin
                    (set-window-buffer! window buffer)
                    (record-buffer! buffer)
                    window)
                  ;; split below, and the new window shows it
                  (let ((new (split-window window #f #f)))
                    (set-window-buffer! new buffer)
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
        (if window (select-window window) #f)
        ;; ... and in either case the buffer becomes the current one:
        ;; Emacs's `pop-to-buffer' ends by selecting the window it found,
        ;; and `select-window' makes that window's buffer current
        ;; (`Fselect_window', window.c:3803). `select-window' is the
        ;; frame's here and cannot reach `set-buffer' - `(schemacs editor
        ;; buffer)' is built *on* it - so the two commands that switch
        ;; buffers do it themselves, as `switch-to-buffer' does.
        (set-buffer buffer)
        (unless norecord (record-buffer! buffer))
        buffer))

    (define (pop-to-buffer-same-window buffer . args)
      ;; Show BUFFER in some window, preferring the selected one: GNU
      ;; Emacs's `pop-to-buffer-same-window', which is `pop-to-buffer' with
      ;; an action that allows the selected window.
      ;;--------------------------------------------------------------
      (pop-to-buffer buffer display-buffer--same-window-action
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
        (set-window-buffer! window buffer)
        (unless norecord (record-buffer! buffer))
        ;; The C's last line is `(set-buffer buffer)' (window.el:9706):
        ;; switching to a buffer *switches to it*, so the commands that
        ;; follow act on it. Without this the window showed the new buffer
        ;; while the current buffer stayed where it was - and since
        ;; `(current-buffer)' falls back to the frame's editor only while
        ;; `*current-buffer*' is unset, the editor looked right in a front
        ;; end that never sets it and was wrong in one that does. The GTK
        ;; front end sets it to `*scratch*' at startup, so there every
        ;; command acted on an empty buffer: the arrows said "Beginning of
        ;; buffer" and "End of buffer" at once, and `dired-mark' walked a
        ;; buffer with no listing in it for ever.
        (set-buffer buffer)
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

    (define-command (delete-window window)
      "Remove the selected window, leaving its rows or columns to the
windows it was combined with."
      (interactive (list (selected-window)))
      (let* ((frame (*current-frame*))
             (parent (window-parent window))
             (siblings (and parent (list-without window (window-children parent))))
             (selected (frame-selected-window frame)))
        (cond
         ((and (not parent) (<= (length (frame-windows frame)) 1))
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
                        (set!frame-windows
                         frame
                         (list-substitute parent
                                          (list child)
                                          (frame-windows frame)))))))
              (set!frame-windows
               frame (list-without window (frame-windows frame))))
          (when (eq? window selected)
            (begin (select-window (car (window-list frame)))
                   (record-buffer!
                    (window-buffer (car (window-list frame))))))
          (set!window-parent window #f)
          (set!window-children window '())
          window))))

    (define-command (delete-other-windows window)
      "Make the selected window the only window on the frame."
      (interactive (list (selected-window)))
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
        (set!frame-windows frame (list window))
        window))

    (define-command (split-window-below size window-to-split)
      ;; GNU Emacs's `split-window-below' (window.el), the command C-x 2
      ;; runs: split the selected window, or WINDOW-TO-SPLIT when one is
      ;; given, in two, one above the other. An interactive call reads
      ;; the prefix argument and the selected window itself, which is
      ;; exactly what Emacs's own `(interactive ...)' does - it reads
      ;; `current-prefix-arg' for the size.
      "Split the selected window into two windows, one above the other."
      (interactive (list (and (current-prefix-arg)
                              (uarg->integer 1 (current-prefix-arg)))
                         (selected-window)))
      ;; GNU Emacs's `split-window-below' checks this one itself,
      ;; because `split-window' would not.
      (when (and size (< size 0) (< (- size) window-min-height))
        (error "Size of new window too small"))
      (split-window window-to-split size #f))

    (define-command (split-window-right size window-to-split)
      ;; GNU Emacs's `split-window-right' (window.el), the command C-x 3
      ;; runs - the side-by-side mirror of `split-window-below'.
      "Split the selected window into two, side by side."
      (interactive (list (and (current-prefix-arg)
                              (uarg->integer 1 (current-prefix-arg)))
                         (selected-window)))
      ;; GNU Emacs's `split-window-right' checks this one itself,
      ;; because `split-window' would not.
      (when (and size (< size 0) (< (- size) window-min-width))
        (error "Size of new window too small"))
      (split-window window-to-split size #t))

    ;; Selecting a window in GNU Emacs also puts its buffer at the front of
    ;; the buffer list, which is what makes the Buffer Menu list the buffers
    ;; in the order they were last looked at. That is `record_buffer' in
    ;; `window.c', which reaches into buffer.c's alist because in C the two
    ;; halves are one program; here they are two libraries and
    ;; `(select-window)' is in `(schemacs editor frame)', which cannot reach
    ;; the buffer list - the buffer library imports it - so the window
    ;; commands below record for themselves. `pop-to-buffer' and
    ;; `switch-to-buffer' do it with their own NORECORD argument.

    (define-command (quit-window)
      ;; GNU Emacs's `quit-window' (q in the Buffer Menu, Dired and the
      ;; startup screen), which is `window.el''s: take this window off the
      ;; frame and bury the buffer it was showing. It is window.el's plain
      ;; function, and a command at the same time - which is why those
      ;; three can bind it to q directly.
      ;;
      ;; **A frame's only window cannot be removed, and then the *window*
      ;; is given another buffer.** Emacs's `quit-restore-window' ends
      ;; `(set-window-buffer window (other-buffer ...))' for that case
      ;; (`window.el'), which this did not: it buried the buffer and left
      ;; the window *showing* it, so `q' in Dired - or on the startup
      ;; screen - looked like it had done nothing at all. Burying a buffer
      ;; is not the same as showing a different one.
      "Leave the selected window and bury the buffer it was showing."
      (interactive)
      (let* ((frame (*current-frame*))
             (window (frame-selected-window frame))
             (buffer (window-buffer window)))
        (bury-buffer buffer)
        (if (> (length (window-list)) 1)
            (delete-window window)
            (switch-to-buffer (other-buffer buffer)))))

    (define-command (other-window count)
      "Select another window in cyclic ordering of windows, COUNT
windows on from the selected one; a negative COUNT goes the other way."
      (interactive "p")
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
        ;; ... and the buffer it shows becomes current, which in Emacs is
        ;; `select-window''s own doing (`Fselect_window', window.c:3803)
        (set-buffer (window-buffer window))
        (record-buffer! (window-buffer window))
        window))


    ;; Horizontal scrolling. `window-hscroll' and `set-window-hscroll'
    ;; are `window.c:1289''s - the setter clips to zero or more and
    ;; suspends auto hscrolling, and `scroll-left'/`scroll-right' are
    ;; `window.c:7101' and `:7127', bound to C-x < and C-x > as
    ;; `bindings.el' does. GNU Emacs disables both commands for new
    ;; users (`put 'scroll-left 'disabled t'); this tree has no
    ;; disabled-command machinery yet, so the keys run them.
    (define (window-hscroll window)
      ;; How many display columns WINDOW's lines are scrolled left by.
      ;;--------------------------------------------------------------
      (%window-hscroll window))

    (define (set-window-hscroll! window ncol)
      ;; Scroll WINDOW NCOL columns from the left margin. Clipped, as
      ;; `set_window_hscroll' clips (`window.c:1289'), and any change
      ;; suspends auto hscrolling (`window.c:1305') until the window's
      ;; point moves. The "prevent redisplay shortcuts" the C also does
      ;; has no counterpart here - there are none.
      ;;--------------------------------------------------------------
      (let ((h (max 0 ncol)))
        (unless (= (%window-hscroll window) h)
          (set!%window-hscroll window h))
        (set!%window-suspend-auto-hscroll? window #t)
        h))

    (define-command (scroll-left arg set-minimum)
      "Scroll selected window display ARG columns left.
Default for ARG is window width minus 2.
Value is the total amount of leftward horizontal scrolling in
effect after the change.
If SET-MINIMUM is non-nil, the new scroll amount becomes the
lower bound for automatic scrolling, i.e. automatic scrolling
will not scroll a window to a column less than the value returned
by this function.  This happens in an interactive call."
      ;; The interactive spec is `^P\np' (`window.c:7101'): the raw
      ;; prefix for ARG and the *count* for SET-MINIMUM - a count is
      ;; always a number, 1 when no prefix was typed, so every
      ;; interactive call sets the minimum, and a plain Lisp call, whose
      ;; SET-MINIMUM is nil, does not. The `^' (shift selection) has no
      ;; counterpart here and the `\n' is only a prompt separator.
      (interactive (list (current-prefix-arg)
                         (uarg->integer 1 (current-prefix-arg))))
      (let* ((window (selected-window))
             (requested (cond ((not arg)
                               (- (window-body-width window) 2))
                              (else (uarg->integer 1 arg))))
             (result (set-window-hscroll!
                      window
                      (+ (window-hscroll window) requested))))
        (when set-minimum
          (set!%window-min-hscroll window (window-hscroll window)))
        result))

    (define-command (scroll-right arg set-minimum)
      "Scroll selected window display ARG columns right.
Default for ARG is window width minus 2.
Value is the total amount of leftward horizontal scrolling in
effect after the change.
If SET-MINIMUM is non-nil, the new scroll amount becomes the
lower bound for automatic scrolling, i.e. automatic scrolling
will not scroll a window to a column less than the value returned
by this function.  This happens in an interactive call."
      (interactive (list (current-prefix-arg)
                         (uarg->integer 1 (current-prefix-arg))))
      (let* ((window (selected-window))
             (requested (cond ((not arg)
                               (- (window-body-width window) 2))
                              (else (uarg->integer 1 arg))))
             (result (set-window-hscroll!
                      window
                      (- (window-hscroll window) requested))))
        (when set-minimum
          (set!%window-min-hscroll window (window-hscroll window)))
        result))

    ;; The window keys, on the ones GNU Emacs binds them to.
    (define-key *default-keymap* (kbd "C-x 2")
      split-window-below)
    (define-key *default-keymap* (kbd "C-x 3")
      split-window-right)
    (define-key *default-keymap* (kbd "C-x 1")
      delete-other-windows)
    (define-key *default-keymap* (kbd "C-x 0")
      delete-window)
    (define-key *default-keymap* (kbd "C-x o")
      other-window)
    ;; `bindings.el' binds scroll-left and scroll-right here - the keys
    ;; for which GNU Emacs has the disabled-command guard this tree
    ;; cannot express yet.
    (define-key *default-keymap* (kbd "C-x <")
      scroll-left)
    (define-key *default-keymap* (kbd "C-x >")
      scroll-right)

    (define *temp-buffer-window-setup-hook* (make-parameter '()))
    (define *temp-buffer-window-show-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `temp-buffer-window-setup-hook' and
    ;; `temp-buffer-window-show-hook' (window.el): "Normal hook run
    ;; before [after] setting up [showing] a temporary buffer" - the
    ;; first runs with the buffer current and empty, the second with its
    ;; window selected. Nothing hangs off either here yet; they are the
    ;; extension points `temp-buffer-window-setup' and
    ;; `temp-buffer-window-show' run in Emacs.

    (define (window-live-p window)
      ;; GNU Emacs's `window-live-p' (window.c): "Return t if OBJECT is a
      ;; window that is displaying a buffer. A live window is one that
      ;; can be deleted." A window here is live while it is one of the
      ;; frame's windows - a deleted window is no longer on that list.
      ;;--------------------------------------------------------------
      (and (window-type? window)
           (let loop ((rest (window-list)))
             (cond ((null? rest) #f)
                   ((eq? (car rest) window) #t)
                   (else (loop (cdr rest)))))))

    (define-syntax with-selected-window
      ;; GNU Emacs's `with-selected-window': "Execute the forms in BODY
      ;; with WINDOW as the selected window." It selects WINDOW, which
      ;; Emacs does with a `norecord' argument so that a temporary
      ;; selection does not reorder the buffer list, and restores the
      ;; window that was selected however BODY leaves - which is the
      ;; `unwind-protect' in the C, a `dynamic-wind' here.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((with-selected-window window body ...)
         (let ((saved-window (selected-window)))
           (select-window window)
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda () (select-window saved-window)))))))

    (define (quit-restore-window window bury-or-kill)
      ;; GNU Emacs's `quit-restore-window' (window.el): "Deal with
      ;; WINDOW after having displayed it before and now burying or
      ;; killing it." Two of its jobs are done here - take WINDOW off the
      ;; frame when it is not the only one, and kill or bury the buffer
      ;; it was showing. The third is not: putting back the buffer the
      ;; window showed before, out of the `quit-restore' window
      ;; parameter, which Emacs's `display-buffer' records when it shows
      ;; a buffer and this tree's does not (it has one display policy
      ;; rather than a list of action functions to record between).
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        (when (and (window-live-p window) (< 1 (length (window-list))))
          (delete-window window))
        (cond ((eq? bury-or-kill 'kill) (kill-buffer buffer))
              ((eq? bury-or-kill 'bury) (bury-buffer buffer))
              (else #f))))

    (define display-buffer-below-selected
      ;; GNU Emacs's `display-buffer-below-selected' (window.el): "Try
      ;; displaying BUFFER in a window below the selected window."
      ;;
      ;; Emacs dispatches an action by calling this function; this tree's
      ;; `display-buffer' has one policy rather than a list of action
      ;; functions, and reads the name the way it reads
      ;; `display-buffer-same-window''s (see
      ;; `display-buffer--same-window-action?'). The split-below arm of
      ;; that policy is what "below the selected window" comes to, so the
      ;; name only has to be recognisable.
      ;;--------------------------------------------------------------
      (list 'display-buffer-below-selected))

    (define (temp-buffer-window-setup buffer-or-name)
      ;; GNU Emacs's `temp-buffer-window-setup' (window.el:3287): "Set
      ;; up temporary buffer specified by BUFFER-OR-NAME. Return the
      ;; buffer." The buffer is emptied and given a plain state - no
      ;; file, no local variables, not read-only - so that a caller can
      ;; print into it and show it.
      ;;
      ;; Two of the C's steps have nothing to do here and are named:
      ;; `delete-all-overlays' (there is no such function in this tree;
      ;; the overlays a `*Completions*' or `*Marked Files*' buffer would
      ;; carry are not made), and `inhibit-modification-hooks' (there are
      ;; no modification hooks to inhibit).
      ;;--------------------------------------------------------------
      (let ((old-dir (default-directory))
            (buffer (get-buffer-create buffer-or-name)))
        (with-current-buffer buffer
          (kill-all-local-variables)
          (set!buffer-default-directory buffer old-dir)
          (set!buffer-read-only buffer #f)
          (set!buffer-file-name buffer #f)
          (parameterize ((*inhibit-read-only* #t))
            (erase-buffer)
            (run-hooks *temp-buffer-window-setup-hook*)))
        buffer))

    (define (temp-buffer-window-show buffer . args)
      ;; GNU Emacs's `temp-buffer-window-show' (window.el:3303): "Show
      ;; temporary buffer BUFFER in a window. Return the window showing
      ;; BUFFER. Pass ACTION as action argument to `display-buffer'."
      ;;
      ;; The `window-combination-limit' binding around the call is about
      ;; which window gives up the space when the buffer is shown;
      ;; nothing here models that. `temp-buffer-resize-mode' is off by
      ;; default, so its `resize-temp-buffer-window' (and so
      ;; `fit-window-to-buffer') does not run, and `minibuffer-scroll-window'
      ;; is a variable this tree has not needed yet.
      ;;--------------------------------------------------------------
      (let ((action (if (pair? args) (car args) #f)))
        (with-current-buffer buffer
          (set-buffer-modified-p #f)
          (set!buffer-read-only buffer #t)
          (goto-char (point-min))
          (let ((window (display-buffer buffer action)))
            (when window
              (set-window-hscroll! window 0)
              (with-selected-window window
                (run-hooks *temp-buffer-window-show-hook*)))
            window))))

    (define-syntax with-current-buffer-window
      ;; GNU Emacs's `with-current-buffer-window': "Evaluate BODY with a
      ;; buffer BUFFER-OR-NAME current and show that buffer." The value
      ;; is the last form of BODY, passed to QUIT-FUNCTION together with
      ;; the window when there is one - which is how `dired-mark-pop-up'
      ;; gets its confirmation to run with the window selected and to
      ;; take the window down again afterwards.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((with-current-buffer-window buffer-or-name action quit-function
                                     body ...)
         (let* ((window #f)
                (value #f)
                (buffer (temp-buffer-window-setup buffer-or-name)))
           (with-current-buffer buffer
             (set! value (let () body ...))
             (set! window (temp-buffer-window-show buffer action)))
           (if (procedure? quit-function)
               (quit-function window value)
               value)))))


    ))
