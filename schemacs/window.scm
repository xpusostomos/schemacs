(define-library (schemacs window)
  ;; This library mirrors GNU Emacs's `window.el': the window commands -
  ;; `split-window-below' (C-x 2), `split-window-right' (C-x 3),
  ;; `delete-window' (C-x 0), `delete-other-windows' (C-x 1) and
  ;; `other-window' (C-x o) - and the geometry they work in.
  ;;
  ;; The window *record* and its geometry queries are in
  ;; `(schemacs frame)', which is `window.c`'s half (`window-edges',
  ;; `window-body-height', `window-right-border?'); what is here is the
  ;; half that makes and removes windows.
  ;;
  ;; **The window tree is Emacs's**: a window's `parent` is an internal
  ;; window holding a list of children, `split-window` puts a new window
  ;; in the combination it belongs to when the C's `combination_limit`
  ;; rule says so, and `delete-window` asks that parent which sibling
  ;; takes the space over. What is left of the old flat-list model is
  ;; the *direction* of a combination: it is read off the children's
  ;; rectangles, because this record has no `w->horizontal`
  ;; (`window-stacked?`, `frame.scm`). Everything that would be
  ;; ambiguous with one child - the axis of a combination about to lose
  ;; its second-to-last window - is read before the tree is changed, as
  ;; the C reads `WINDOW_HORIZONTAL_COMBINATION_P (p)` before unlinking.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `define-custom' - the C variables `cus-start.el' makes
    ;; customizable (see the declaration below).
    (only (schemacs custom) define-custom)
    (scheme base)
    (scheme char)
    ;; `split-window-below' and `split-window-right' take an optional
    ;; size, which is a `case-lambda'.
    (scheme case-lambda)
    (only (schemacs command)
          current-prefix-arg define-command uarg->integer)
    ;; `cursor-in-echo-area` is `dispnew.c`'s and is re-exported here; the
    ;; redisplay that reads it is above this library, not below.
    (only (schemacs dispnew) *cursor-in-echo-area*)
    (only (schemacs marker) build-marker copy-marker marker-position
          set-marker make-marker markerp marker-last-position)
    ;; `catch`/`throw` is the C's `throw 'found`; Guile's escape
    ;; continuation is `let/ec`.
    (only (ice-9 control) let/ec)
    ;; The saved vector's parent/prev indices are looked up in a hash
    ;; table of window to index, as the C's `temslot` is a number in the
    ;; window and the lookup there is free. Guile's hash tables are not
    ;; `(scheme base)`'s.
    ;; `exact->inexact`/`inexact->exact` are Guile's: the resize engine
    ;; keeps the normal sizes as floats, as the C's `w->normal_lines` and
    ;; `w->normal_cols` are.
    (only (guile) make-hash-table hashq-ref hashq-set! exact->inexact inexact->exact)
    (only (ice-9 control) let/ec)
    ;; `switch-to-prev-buffer-skip-regexp` is matched against a buffer
    ;; name: `search.c`'s `string-match`.
    (only (schemacs search) string-match)
    
    ;; `define-key' and the global map: the window keys are stated here,
    ;; beside the commands they run.
    (only (schemacs keymap)
         define-key
         *default-keymap*)
    (only (schemacs frame)
          ;; the window's own hscroll state, which `set-window-hscroll!'
          ;; and the scroll commands maintain
          %window-hscroll
          set!%window-hscroll %window-min-hscroll set!%window-min-hscroll
          %window-suspend-auto-hscroll? set!%window-suspend-auto-hscroll?
          *current-frame* frame-height frame-width frame-top-margin
          frame-minibuffer-window
          ;; `FRAME_WINDOW_CHANGE`, which the window-tree functions set
          ;; (`window.c:3715`, `:4427`, `:4896`, `:5681`, `:5828'), and
          ;; the stamp and live-window count the change functions read
          ;; and bump
          set!frame-window-change frame-window-change
          frame-change-stamp set!frame-change-stamp
          frame-old-selected-window set!frame-old-selected-window
          frame-number-of-windows set!frame-number-of-windows
          *frame-list*
          window-type?
          make<window>
          frame-selected-window frame-windows select-window
          selected-window
          set!frame-windows set!window-children set!window-height
          set!window-left set!window-parent set!window-top
          set-window-buffer! set!window-width
          window-buffer window-children
          window-edges window-frame window-height window-left window-list
          window-parent
          window-stacked? set-window-combination-axis!
          window-body-width window-body-height window-top window-width
          window-internal?
          %window-start set!%window-start
          %window-start-at-line-beg set!%window-start-at-line-beg
          set-window-start! set-window-point! window-point
          ;; The buffer history, and the seam `set-window-buffer!` records
          ;; through.
          %window-prev-buffers set!%window-prev-buffers
          %window-next-buffers set!%window-next-buffers
          *record-window-buffer-function*
          ;; `current-window-configuration`/`set-window-configuration`
          ;; are window.c's and live in this library; these are what they
          ;; read and write.
          %window-point set!%window-point
          set!window-buffer set!frame-selected-window
          window-parameters set-window-parameter
          window-minibuffer-p *minibuffer*
          frame-list frame-live-p select-frame
          ;; `window-persistent-parameters` - which is window.c's
          ;; variable, and what `current-window-configuration` saves.
          *window-persistent-parameters*
          ;; The window tree's algebra and the size registers - the
          ;; `window.c` half of the size chapter, which the resize
          ;; engine and the state functions below are built on.
          frame-root-window frame-root-window-p
          window-live-p window-child window-next-sibling window-prev-sibling frame?
          window-pixel-edges
          window-last-child window-top-child window-left-child
          window-combination-p window-combined-p
          window-total-height window-total-width
          window-pixel-height window-pixel-width
          window-pixel-left window-pixel-top window-size
          window-normal-size
          window-combination-limit set-window-combination-limit
          window-dedicated-p set-window-dedicated-p
          window-fringes set-window-fringes
          window-margins set-window-margins
          window-scroll-bars set-window-scroll-bars
          window-vscroll set-window-vscroll
          window-mode-line-height window-header-line-height
          window-scroll-bar-width window-scroll-bar-height
          window-right-divider-width window-bottom-divider-width
          window-new-pixel set-window-new-pixel
          window-new-total set-window-new-total
          window-new-normal set-window-new-normal
          window-resize-apply window-resize-apply-total
          %window-resize-apply-1
          ;; `window-start` is `window.c`'s; the redisplay's marker,
          ;; answered as a position.
          window-start
          ;; The frame's character size, and what the minibuffer
          ;; window's own resizing is called.
          frame-char-height frame-char-width frame-type? selected-frame
          *resize-mini-windows* grow-mini-window shrink-mini-window
          minibuffer-window-active-p window-tab-line-height
          window-parameter
          ;; The window-change record: what each window was when
          ;; `run-window-change-functions` last ran (`window.h`'s
          ;; `change_stamp`, `old_buffer` and the four old sizes).
          window-change-stamp set!window-change-stamp
          window-old-buffer set!window-old-buffer
          window-old-pixel-width set!window-old-pixel-width
          window-old-pixel-height set!window-old-pixel-height
          window-old-body-pixel-width set!window-old-body-pixel-width
          window-old-body-pixel-height set!window-old-body-pixel-height)
    ;; `display-buffer' puts what it shows in the buffer list's
    ;; most-recently-used order, which is Emacs's `record_buffer';
    ;; `pop-to-buffer' makes a buffer current by name when a string is
    ;; what it was given, and `switch-to-buffer' does the same.
    (only (schemacs buffer)
          bury-buffer default-directory erase-buffer
          get-buffer-create
          kill-all-local-variables %kill-buffer other-buffer record-buffer!
          *scratch-buffer-name*
          set-buffer
          set!buffer-default-directory set!buffer-file-name set!buffer-read-only
          set-buffer-modified-p
          with-current-buffer *inhibit-read-only* buffer-pt bufferp
          buffer-list buffer-live-p buffer-name current-buffer
          buffer-local-value get-buffer
          *buffer-list-update-hook*)
    ;; `run-hooks' is `subr.el''s, and the two temp-buffer hooks below
    ;; are run through it.
    ;; `assq-delete-all` and `delq` are `subr.el`'s - `record-window-buffer`
    ;; drops an older entry with the first, and the history lists with the
    ;; second.
    (only (schemacs subr) assq-delete-all delq kbd run-hooks user-error nth
          with-temp-buffer)
    ;; `temp-buffer-window-show' puts point at the beginning of the
    ;; buffer it is about to show, which `goto-char' is.
    (only (schemacs editfns) goto-char point-min)
    )

  (export
   delete-other-windows
   delete-window
   display-buffer
   get-buffer-window
   get-buffer-window-list
   list-substitute
   list-without
   other-window
   *window-configuration-change-hook*
   run-window-change-functions
   pop-to-buffer
   quit-window
   pop-to-buffer-same-window
   force-window-update
   split-window
   split-window-below
   split-main-window-below
   split-window-right
   switch-to-buffer
   switch-to-buffer-other-window
   window-normalize-buffer-to-switch-to
   ;; Window configurations - `window.c`'s, restored and recorded here.
   current-window-configuration set-window-configuration
   window-configuration-p window-configuration-frame
   *window-restore-killed-buffer-windows*
   ;; A window's buffer history - `window.el`'s.
   window-prev-buffers set-window-prev-buffers
   window-next-buffers set-window-next-buffers
   record-window-buffer unrecord-window-buffer
   set-window-buffer-start-and-point
   switch-to-prev-buffer switch-to-next-buffer
   next-buffer previous-buffer
   *switch-to-visible-buffer* *switch-to-prev-buffer-skip*
   *switch-to-prev-buffer-skip-regexp*
   *read-buffer-to-switch*
   *set-buffer-major-mode-function*
   *get-scratch-buffer-create-function*
   window-min-height
   *cursor-in-echo-area*
   window-min-width
   display-buffer-below-selected
   quit-restore-window
   temp-buffer-window-setup
   temp-buffer-window-show
   window-live-p
   with-current-buffer-window
   with-selected-window save-selected-window save-window-excursion
   window-position
   window-hscroll
   set-window-hscroll!
   scroll-left
   scroll-right
   ;; The size arithmetic - `window.el`'s half of the size chapter.
   window-safe-min-height window-safe-min-width window-resize-pixelwise
   *window-combination-resize* *window-combination-limit*
   window-normalize-window adjust-window-trailing-edge window-at-side-p one-window-p
   window-resize-pixelwise window-valid-p frame-char-size
   window-safe-min-pixel-height window-min-pixel-height
   window-safe-min-pixel-width window-min-pixel-width
   window-safe-min-size window-min-size window--min-size-ignore-p
   window-normal-size window-size
   window--min-size-1 window-sizable window-sizable-p
   window-preserved-size window--preserve-size window-body-size
   window--size-fixed-1 window-size-fixed-p
   window--min-delta-1 window-min-delta window--max-delta-1 window-max-delta
   window--resizable window--resizable-p window-resizable window-resizable-p
   window--size-to-pixel window--pixel-to-total
   window--resize-reset window--resize-reset-1 window--resize-apply-p
   window--resize-child-windows window--resize-child-windows-normal
   window--resize-child-windows-skip-p
   window--resize-siblings window--resize-this-window
   window--resize-mini-window window-resize window-resize-no-error
   window-full-height-p window-right-sibling window-left-sibling
   split-window-no-error window-deletable-p frame-deletable-p
   delete-window-internal recombine-windows
   walk-window-subtree window--check
   ;; The tree walks, and the two ways of asking about a combination -
   ;; `window.el`'s - plus `window.c`'s `combine-windows`.
   walk-window-tree-1 walk-window-tree window-child-count window-main-window
   combine-windows
   ;; Window states - `window.el:6370`.
   window--state-assq window--state-ref window--state-normalize-buffer-name
   window--state-get-1 window-state-get
   window-state-put-list window-state-put-stale-windows
   window-state-put-kept-windows window-state-put-selected-window
   window--state-put-1 window--state-put-2 window-state-put
   window-state-buffers
   )

  (begin

    (define *read-buffer-to-switch* (make-parameter #f))
    ;; ^ How a buffer name is read for `switch-to-buffer' and the commands
    ;; that use it. GNU Emacs reads it with `read-buffer-to-switch'
    ;; (`window.el:9485'), which is *this file's* function - and it cannot
    ;; be defined here: it completes with `internal-complete-buffer-except'
    ;; and installs the table through `minibuffer-with-setup-hook', and
    ;; both are `(schemacs minibuffer)', which is built on this
    ;; library. So this library says *what* to read and the minibuffer
    ;; library says *how*, the way `*frame-creation-function*' already
    ;; works here: `(schemacs minibuffer)' sets it as it loads.
    ;; The prompt it is given is Emacs's own, "Switch to buffer: ".

    (define *set-buffer-major-mode-function* (make-parameter #f))
    ;; ^ How a buffer created by `window-normalize-buffer-to-switch-to'
    ;; gets its major mode. `set-buffer-major-mode' is `buffer.c''s
    ;; function (`:2283') and its port lives in `(schemacs files)',
    ;; which is built on this library - a mode *command* is found through
    ;; the command table - so this library holds the seam and `files.scm'
    ;; installs it as it loads, as it does for the `f' interactive
    ;; code's reader. Emacs calls it from the create branch below and
    ;; from `other_buffer_safely' and `shell-command'; the first of those
    ;; is this one.
    ;;
    ;; It matters beyond tidiness: a new buffer that never runs a major
    ;; mode never runs `after-change-major-mode-hook', so no
    ;; `define-globalized-minor-mode' reaches it - `C-x b NAME' made a
    ;; buffer with no font-lock and no `tab-line-mode' where Emacs's has
    ;; both.

    (define *get-scratch-buffer-create-function* (make-parameter #f))
    ;; ^ How the `"*scratch*"' arm below makes its buffer.
    ;; `get-scratch-buffer-create' is `simple.el`'s and its port lives in
    ;; `(schemacs startup)` - `simple.scm` is below `files.scm`,
    ;; where `initial-major-mode` lives, and startup is where both are
    ;; reachable - so this library holds the seam and `startup.scm`
    ;; installs it as it loads, as `files.scm` installs the mode seam
    ;; above. Emacs's arm is `(get-scratch-buffer-create)`, which is
    ;; `(or (get-buffer X) (let ((b (get-buffer-create X))) ...))`; the
    ;; fallback here is the bare buffer, for an editor started without
    ;; the boot - a test or a probe - so it gets a `*scratch*` rather
    ;; than an error.

    ;; `*cursor-in-echo-area*` is `dispnew.c`'s (`DEFVAR_BOOL` at
    ;; `:7538`) and lives in `(schemacs dispnew)` now: the
    ;; redisplay reads it in `get_window_cursor_type` (`xdisp.c:34825`),
    ;; and this library is above the renderer. It is re-exported here
    ;; from the import above, so every name that reached it through this
    ;; library still does.

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

    (define (make-window-parent window new before? top height left width)
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
                            (window-parent window)
                            (if before? (list new window) (list window new))
                            0 0 #f 0 '() '()
                            #f 0 0 0 0 0 0 0 -1 #f '() #f
                          0 #f 0 0 0 0))

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

    (define (%children-through children stop)
      ;; CHILDREN from its first element through STOP, inclusive: the run
      ;; `combine-windows` takes out of its parent's sibling list. A leaf
      ;; of this tree's representation - Emacs keeps siblings as a chain
      ;; of `w->next` pointers and has nothing to name the run with.
      ;;--------------------------------------------------------------
      (let loop ((rest children) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((eq? (car rest) stop) (reverse (cons stop acc)))
              (else (loop (cdr rest) (cons (car rest) acc))))))

    (define (%children-before children first)
      ;; CHILDREN up to but not including FIRST.
      ;;--------------------------------------------------------------
      (let loop ((rest children) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((eq? (car rest) first) (reverse acc))
              (else (loop (cdr rest) (cons (car rest) acc))))))

    (define (combine-windows first last)
      ;; GNU Emacs's `combine-windows` (`window.c:5213`): "Combine
      ;; windows from FIRST to LAST inclusive. FIRST and LAST must be
      ;; different, valid windows in the same combination, that is,
      ;; windows with the same parent window. If LAST is not reachable
      ;; from FIRST by applying `window-next-sibling` repeatedly, invert
      ;; FIRST and LAST. If FIRST has no previous and LAST has no next
      ;; sibling, return nil. Otherwise, make a new parent window whose
      ;; first child window becomes FIRST and whose last child window
      ;; becomes LAST, insert that parent window in the window tree in
      ;; lieu of the windows starting with FIRST and ending with LAST and
      ;; return the new parent window."
      ;;
      ;; **It is `window.c`'s and stands beside `split-window`** for the
      ;; reason that one does: the machinery that makes an internal
      ;; window and puts it in the tree is in this library, not in
      ;; `(schemacs frame)`.
      ;;
      ;; Two departures, both of the representation. The C writes
      ;; `w->prev`/`w->next` and `XWINDOW (p->parent)->contents`; here a
      ;; combination is a list, so the splice is one list rebuild. And
      ;; the C ends by calling `window_set_parent_and_normal_sizes` on
      ;; the new parent and on its parent to record fractional normal
      ;; sizes; normal sizes here are derived from the rectangles
      ;; (`window-normal-size`), so setting PARENT's rectangle is the
      ;; whole of it.
      ;;--------------------------------------------------------------
      (let ((f first) (l last))
        (when (eq? f l)
          ;; The C's "Don't make a matryoshka window."
          (error "Cannot combine a window with itself"))
        ;; "If LAST is not reachable from FIRST by applying
        ;; `window-next-sibling` repeatedly, invert FIRST and LAST."
        (let ((w (let walk ((w f))
                   (if (or (eq? w l) (not (window-next-sibling w)))
                       w
                       (walk (window-next-sibling w))))))
          (unless (eq? w l)
            (let ((w2 (let walk ((w l))
                        (if (or (eq? w f) (not (window-next-sibling w)))
                            w
                            (walk (window-next-sibling w))))))
              (if (eq? w2 f)
                  (let ((tmp f)) (set! f l) (set! l tmp))
                  (error "Windows to combine must be children of same parent")))))
        (if (and (not (window-prev-sibling f)) (not (window-next-sibling l)))
            ;; "FIRST and LAST are already the first and last child of
            ;; their parent."
            #f
            (let* ((parent (window-parent f))
                   ;; The direction the parent divided its children. The
                   ;; C reads `XWINDOW (f->parent)->horizontal`
                   ;; (`window.c:5267`); `window-left-child` is the
                   ;; public spelling of that field here.
                   (horflag (and (window-left-child parent) #t))
                   (kids (window-children parent))
                   (inside (%children-through (memq f kids) l))
                   (p (make<window> (window-frame f) #f #f #f #f 0 0 #f 0 0
                                    (window-top f) (window-height f)
                                    (window-left f) (window-width f)
                                    parent inside
                                    0 0 #f 0 '() '()
                                    #f 0 0 0 0 0 0 0 -1 #f '() #f
                          0 #f 0 0 0 0)))
              (set-window-combination-axis! p (if horflag
                                                   'horizontal
                                                   'vertical))
              ;; "Set up PARENT's positions and sizes": the union of the
              ;; run's rectangles.
              (if horflag
                  (begin
                    (set!window-width p (+ (window-left l) (window-width l)
                                           (- (window-left f))))
                    (set!window-height p (window-height f)))
                  (begin
                    (set!window-height p (+ (window-top l) (window-height l)
                                            (- (window-top f))))
                    (set!window-width p (window-width f))))
              ;; "Fix parent slots for PARENT's children" - they are
              ;; PARENT's now. Their normal sizes follow from these
              ;; rectangles, which is what `window_set_parent_and_normal_sizes`
              ;; computes in the C, and PARENT's own share of its
              ;; siblings follows from its own rectangle the same way.
              (for-each (lambda (child) (set!window-parent child p)) inside)
              ;; "Splice in PARENT into the window tree" - the C's four
              ;; pointer writes, here one list rebuild.
              (let ((new-kids (append (%children-before kids f)
                                      (list p)
                                      (cdr (memq l kids)))))
                (if parent
                    (set!window-children parent new-kids)
                    (set!frame-windows (window-frame f) new-kids)))
              p))))

    (define (force-window-update . args)
      ;; GNU Emacs's `force-window-update' (`window.c`): "Force
      ;; re-display of all windows of OBJECT" - mark them so the next
      ;; redisplay rebuilds them whether or not they look out of date.
      ;;
      ;; **Nothing to mark here**: this redisplay redraws every window of
      ;; every frame on every `render!`, so a window is always rebuilt on
      ;; the next frame. `force-mode-line-update' (`xdisp.sld') is the
      ;; same no-op for the same reason.
      ;;--------------------------------------------------------------
      #f)

    (define (list-insert-after item new lst)
      ;; LST with NEW inserted directly after ITEM. The list spelling of
      ;; the C's `wset_next (o, new)' / `wset_prev (o->next, new)' pair -
      ;; which is how `split-window` puts the new window *after* the one
      ;; it split, and how `delete-window` takes it out again.
      ;;--------------------------------------------------------------
      (cond ((null? lst) (list new))
            ((eq? (car lst) item) (cons item (cons new (cdr lst))))
            (else (cons (car lst) (list-insert-after item new (cdr lst))))))

    (define (list-insert-before item new lst)
      ;; LST with NEW inserted directly before ITEM: SIDE `above`/`left`
      ;; puts the new window *before* the one it split, the other half
      ;; of the C's `wset_prev`/`wset_next` pair (`window.c:5586`).
      ;;--------------------------------------------------------------
      (cond ((null? lst) (list new))
            ((eq? (car lst) item) (cons new lst))
            (else (cons (car lst) (list-insert-before item new (cdr lst))))))

    (define (%split-window-install! frame window new horizontal before?
                                    top height left width)
      ;; Where `split-window` puts the new window, which is the C's
      ;; `combination_limit` decision (`window.c:5427`): "Set
      ;; combination_limit if we have to make a new parent window. We do
      ;; that if either `window-combination-limit` is t, or OLD has no
      ;; parent, or OLD is ortho-combined."
      ;;
      ;; Otherwise the new window becomes OLD's next sibling in the
      ;; combination OLD is already in - which is what makes splitting
      ;; the bottom window of a three-window frame a combination of
      ;; three rather than a combination of two nested in another two.
      ;; OLD keeps its rectangle's start and gives up SIZE along the
      ;; split axis; the other siblings are untouched, which is what the
      ;; C's `window_resize_apply` computes when
      ;; `window-combination-resize` is nil.
      ;;--------------------------------------------------------------
      (let* ((parent (window-parent window))
             ;; "OLD is ortho-combined": the parent divided its children
             ;; along the other axis, so the two cannot be siblings.
             (ortho (and parent
                         (if horizontal
                             (window-top-child parent)
                             (window-left-child parent))))
             (combination-limit (or (eq? (*window-combination-limit*) #t)
                                    (not parent)
                                    ortho)))
        (if combination-limit
            (let ((p (install-window-parent!
                      frame window
                      (make-window-parent window new before?
                                          top height left width))))
              ;; The new combination's axis - `w->vchild`/`w->hchild` in
              ;; the C, which a split sets with its direction
              ;; (`window.c:5500`: `wset_hchild`/`wset_vchild`).
              (set-window-combination-axis! p (if horizontal
                                                   'horizontal
                                                   'vertical))
              (when (window-internal? window)
                ;; **"Get entire space from WINDOW"** (`window.el:5945`):
                ;; an internal window's children give up the new window's
                ;; share in the proportion the resize engine uses, which
                ;; is the same rule the delete that takes the new window
                ;; away hands it back by. `split-window-internal` does
                ;; this too - the C's `window_resize_apply (p, horflag)`
                ;; at its end - and a leaf has nothing to redistribute,
                ;; which is why the ordinary split never noticed.
                (let ((size-pixels (window-size new horizontal #t)))
                  (window--resize-reset frame horizontal)
                  (set-window-new-pixel new size-pixels)
                  (window--resize-this-window window (- size-pixels) horizontal #f)
                  (%window-resize-apply-1 p horizontal)))
              p)
            (begin
              ;; The ortho test above guarantees PARENT divides its
              ;; children on this axis; a combination made before the
              ;; axis was stored gets it here.
              (set-window-combination-axis! parent (if horizontal
                                                        'horizontal
                                                        'vertical))
              (set!window-parent new parent)
              (set!window-children
               parent
               (if before?
                   (list-insert-before window new (window-children parent))
                   (list-insert-after window new (window-children parent))))
              new))))

    (define (split-window window size . args)
      ;; `FRAME_WINDOW_CHANGE` (`window.c:5681`). **At the top rather
      ;; than at the C's end**, where this function has two return points
      ;; and the C one; a split that raises leaves the flag set where the
      ;; C's would not, and the next run finds nothing changed and runs
      ;; no hook - which is the same outcome, one pass earlier.
      ;;--------------------------------------------------------------
      (set!frame-window-change (window-frame window) #t)
      ;; GNU Emacs's `split-window' - `Fsplit_window' in window.c - the
      ;; one primitive every split is: divide the live window WINDOW in
      ;; two, the first part SIZE rows (or columns, for a horizontal
      ;; split) and the rest going to the new one - a positive SIZE on
      ;; the first part, a negative one -SIZE on the second, and half
      ;; and half (or close to it) when there is no SIZE.
      ;;
      ;; **SIDE and PIXELWISE are Emacs's** (`window.el:2833`): SIDE nil
      ;; (or `below`) puts the new window below, `above` above,
      ;; `left`/`right` beside it; `up` and `down` are `above` and
      ;; `below`, and any other non-nil value - `t` included - is
      ;; `right`, which is why the tree's old boolean HORIZONTAL callers
      ;; still mean what they meant. PIXELWISE means SIZE is pixels.
      ;;
      ;; **The tree's rectangles are cells**, so a pixel SIZE is turned
      ;; into cells here, at the edge; `window--state-put-1` splits with
      ;; pixel sizes and applies the exact sizes itself afterwards.
      ;;--------------------------------------------------------------
      (let* ((side (window--opt args 0))
             (pixelwise (window--opt args 1))
             (side (cond ((not side) 'below)
                         ((eq? side 'up) 'above)
                         ((eq? side 'down) 'below)
                         ((memq side '(below above right left)) side)
                         (else 'right)))
             (horizontal (memq side '(left right)))
             (before? (memq side '(above left)))
             (frame (window-frame window))
             (size (if (and pixelwise (number? size))
                       (let* ((step (if horizontal
                                        (frame-char-width frame)
                                        (frame-char-height frame)))
                              (cells (round (/ (abs size) step))))
                         (if (< size 0) (- cells) cells))
                       size)))
        (if horizontal
          (let* ((frame (window-frame window))
                 ;; The C's reference window (`window.c:5443`): "if
                 ;; OLD is live, use it as reference window. Use the
                 ;; frame's selected window as reference window"
                 ;; otherwise - an internal window can be split, and the
                 ;; new window then shows what the selected window shows.
                 (refer (if (window-live-p window)
                            window
                            (frame-selected-window frame)))
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
              ;; SIDE `left`: the new window takes the first part, and
              ;; OLD keeps its SIZE but moves after it.
              (when before?
                (set!window-left window (+ start right)))
              (set!window-width window left)
              (let ((new (make<window>
                          ;; the new window is on the frame of the one
                          ;; it split: `frame = WINDOW_FRAME (o)'
                          ;; (`window.c:5412'), `wset_frame (n, frame)'
                          ;; (`:5583')
                          (window-frame window)
                          (window-buffer refer)
                          ;; **`build-marker` and not `copy-marker`**: it
                          ;; is the C's way to make a marker when it has
                          ;; the buffer in hand (`alloc.c:3801`), which is
                          ;; this position - the window carries its buffer
                          ;; from construction. GNU Emacs makes the two
                          ;; markers *empty* in `make_window`
                          ;; (`window.c:4612`, `Fmake_marker`) and
                          ;; attaches them in `set_window_buffer`
                          ;; (`set_marker_both`, `:4375`); this tree's
                          ;; window takes its buffer as a constructor
                          ;; argument, which is a window.c shape left for
                          ;; when that file is next opened.
                          (build-marker (window-buffer refer)
                                        (buffer-pt (window-buffer refer)))
                          ;; the start and whether it is a line beginning
                          ;; are copied together, as the C copies them
                          ;; (`save_window_save', `window.c:8374`)
                          (build-marker (window-buffer refer)
                                        (marker-position (%window-start refer)))
                          (%window-start-at-line-beg refer)
                          0 0 #f 0 0
                          top
                          height
                          (if before? start (+ start left))
                          right
                          #f '()
                          0 0 #f 0 '() '()
                          #f 0 0 0 0 0 0 0 -1 #f '() #f
                          0 #f 0 0 0 0)))
                (%split-window-install! frame window new horizontal before?
                                        top height start width)
                new)))
          (let* ((frame (window-frame window))
                 (refer (if (window-live-p window)
                            window
                            (frame-selected-window frame)))
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
              ;; SIDE `above`: the new window takes the first part, and
              ;; OLD keeps its SIZE but moves below it.
              (when before?
                (set!window-top window (+ top lower)))
              (set!window-height window upper)
              (let ((new (make<window>
                          ;; the new window is on the frame of the one
                          ;; it split: `frame = WINDOW_FRAME (o)'
                          ;; (`window.c:5412'), `wset_frame (n, frame)'
                          ;; (`:5583')
                          (window-frame window)
                          (window-buffer refer)
                          (build-marker (window-buffer refer)
                                       (buffer-pt (window-buffer refer)))
                          (build-marker (window-buffer refer)
                                       (marker-position (%window-start refer)))
                          (%window-start-at-line-beg refer)
                          0 0 #f 0 0
                          (if before? top (+ top upper))
                          lower
                          left
                          width
                          #f '()
                          0 0 #f 0 '() '()
                          #f 0 0 0 0 0 0 0 -1 #f '() #f
                          0 #f 0 0 0 0)))
                (%split-window-install! frame window new horizontal before?
                                        top height left width)
                new))))))
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
      ;;
      ;; **It is `split-window` now** - "Splitting the *root* is what
      ;; makes a completion list a full-width window at the bottom even
      ;; in a frame that is divided left and right" - because
      ;; `split-window` can split an internal window and takes its
      ;; children's share through the resize engine, which is the rule
      ;; the delete gives them back by. The hand-rolled version this
      ;; replaces shrank only the child touching the bottom edge, so the
      ;; list closing again left the two file windows at 18/5 rather
      ;; than the 12/11 they started at.
      ;;--------------------------------------------------------------
      ;;
      ;; **SIZE is the new window's**, which is `split-window`'s negative
      ;; SIZE: "SIZE specifies the new number of lines for WINDOW (or the
      ;; new window if SIZE is negative)" (`window.el:5669`). A positive
      ;; SIZE would make the *upper* window SIZE rows and hand the list
      ;; everything else.
      (let ((window (split-window (window-main-window) (- size) #f)))
        (set-window-buffer! window buffer)
        window))

    ;; `absorb-into!` lived here: it grew a window and every child that
    ;; touched the same edge, and it was how this tree shrank and grew a
    ;; frame's windows by rectangles. Its last caller was the
    ;; hand-written `split-main-window-below`, which `split-window` now
    ;; does properly; with the delete on the resize engine the two size
    ;; models disagreed (`DEPARTURES.md`, "Splitting a window into an
    ;; existing combination"), so it is gone rather than left to be
    ;; picked up again.

    (define (get-buffer-window . args)
      ;; The window showing BUFFER-OR-NAME, or false when none does: GNU
      ;; Emacs's `get-buffer-window', which is `window.c''s - it is where
      ;; a buffer can be found by looking at the windows.
      ;;
      ;; BUFFER-OR-NAME is optional, as in Emacs (the current buffer), and
      ;; ALL-FRAMES chooses the frames to look at - `occur-1' asks with
      ;; `all-frames', because the *Occur* buffer may be showing on
      ;; another frame. Emacs's meanings: nil is the selected frame, t is
      ;; every frame, a frame is that frame; 0 and `visible' are the
      ;; visible frames, and every frame here is visible, so they are t.
      ;;--------------------------------------------------------------
      (let* ((thing (if (pair? args) (car args) (current-buffer)))
             (buffer (cond ((not thing) (current-buffer))
                           ((bufferp thing) thing)
                           (else (get-buffer thing))))
             (all (and (pair? args) (pair? (cdr args)) (cadr args)))
             (frames (cond ((or (eq? all #t) (eqv? all 0)
                                (eq? all 'visible) (eq? all 'all-frames))
                            (*frame-list*))
                           ((and all (not (symbol? all)) (not (number? all)))
                            (list all))
                           (else (list (*current-frame*)))))
             (in-frame (lambda (frame)
                         (let loop ((rest (window-list frame #t)))
                           (cond ((null? rest) #f)
                                 ((eq? (window-buffer (car rest)) buffer)
                                  (car rest))
                                 (else (loop (cdr rest))))))))
        (let loop ((rest frames))
          (cond ((null? rest) #f)
                ((in-frame (car rest)))
                (else (loop (cdr rest)))))))

    (define (get-buffer-window-list . args)
      ;; "Return list of all windows displaying BUFFER-OR-NAME, or nil if
      ;; none" - GNU Emacs's `get-buffer-window-list' (`window.el:2656'),
      ;; which walks `window-list-1 (selected-window) MINIBUF ALL-FRAMES'
      ;; and keeps the windows showing the buffer, in window-list order.
      ;;
      ;; BUFFER-OR-NAME, MINIBUF and ALL-FRAMES are as in
      ;; `get-buffer-window' above - the same frame choice and the same
      ;; three-way MINIBUF rule (`window-list' carries it).
      ;;
      ;; INDIRECT is not carried: it appends the windows whose buffer is
      ;; an indirect buffer of this one, and this tree has no indirect
      ;; buffers (`buffer-base-buffer' answers nil for every buffer), so
      ;; the C's loop would add nothing.
      ;;--------------------------------------------------------------
      (let* ((thing (if (pair? args) (car args) (current-buffer)))
             (buffer (cond ((not thing) (current-buffer))
                           ((bufferp thing) thing)
                           (else (get-buffer thing))))
             (minibuf (and (pair? args) (pair? (cdr args)) (cadr args)))
             (all (and (pair? args) (pair? (cdr args))
                       (pair? (cdr (cdr args)))
                       (car (cdr (cdr args)))))
             (frames (cond ((or (eq? all #t) (eqv? all 0)
                                (eq? all 'visible) (eq? all 'all-frames))
                            (*frame-list*))
                           ((and all (not (symbol? all)) (not (number? all)))
                            (list all))
                           (else (list (*current-frame*))))))
        ;; `(dolist (window window-list) (when (eq (window-buffer window)
        ;; buffer) (setq windows (cons window windows))))', then
        ;; `nreverse' - so the answer keeps the window-list order.
        (let loop ((frames frames) (acc '()))
          (cond ((null? frames) (reverse acc))
                (else
                 (loop (cdr frames)
                       (let inner ((rest (window-list (car frames) minibuf))
                                   (acc acc))
                         (cond ((null? rest) acc)
                               ((eq? (window-buffer (car rest)) buffer)
                                (inner (cdr rest) (cons (car rest) acc)))
                               (else (inner (cdr rest) acc))))))))))

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

    (define (window-normalize-buffer-to-switch-to buffer-or-name)
      ;; GNU Emacs's `window-normalize-buffer-to-switch-to'
      ;; (`window.el:9508'): "If BUFFER-OR-NAME is nil, return the buffer
      ;; returned by `other-buffer'. Else, if a buffer specified by
      ;; BUFFER-OR-NAME exists, return that buffer. If no such buffer
      ;; exists, create a buffer with the name BUFFER-OR-NAME and return
      ;; that buffer." It is what makes `C-x b newname' give a new buffer
      ;; rather than an error.
      ;;
      ;; Emacs's `pcase' has three arms and its middle one is `"*scratch*"'
      ;; -> `(get-scratch-buffer-create)'. **Two pieces of that are not
      ;; carried**: `get-scratch-buffer-create' is `simple.el''s
      ;; (`:11547') and lives above this library, and what it adds over
      ;; `get-buffer-create' - `initial-major-mode' and
      ;; `initial-scratch-message' - are `startup.el''s variables, which
      ;; this tree does not have (its `*scratch*' is made bare by the front
      ;; ends).
      ;;
      ;; The `_` arm is `(or (get-buffer X) (let ((b (get-buffer-create X)))
      ;; (set-buffer-major-mode b) b))', and the mode call reaches this
      ;; library through `*set-buffer-major-mode-function*' - see its
      ;; comment above.
      ;;--------------------------------------------------------------
      (cond ((not buffer-or-name) (other-buffer))
            ((and (string? buffer-or-name)
                  (string=? buffer-or-name *scratch-buffer-name*))
             ;; `(get-scratch-buffer-create)' in the C - through the
             ;; seam, see its comment above.
             (if (*get-scratch-buffer-create-function*)
                 ((*get-scratch-buffer-create-function*))
                 (get-buffer-create *scratch-buffer-name*)))
            ;; Emacs's own `_` arm is `(or (get-buffer X) (get-buffer-create
            ;; X))', and its `get-buffer' answers a *buffer* argument too.
            ;; This tree's does not - `buffer.sld''s takes a name - so the
            ;; buffer case is spelled out.
            ((bufferp buffer-or-name) buffer-or-name)
            ((string? buffer-or-name)
             (or (get-buffer buffer-or-name)
                 (let ((buffer (get-buffer-create buffer-or-name)))
                   (let ((set-mode (*set-buffer-major-mode-function*)))
                     (when set-mode (set-mode buffer)))
                   buffer)))
            (else (error "not a buffer or a buffer name" buffer-or-name))))

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
             (buffer (window-normalize-buffer-to-switch-to buffer-or-name))
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

    (define-command (switch-to-buffer buffer-or-name . args)
      "Display buffer BUFFER-OR-NAME in the selected window.

WARNING: This is NOT the way to work on another buffer temporarily
within a Lisp program!  Use `set-buffer' instead.  That avoids
messing with the `window-buffer' correspondences.

If the selected window cannot display the specified buffer
because it is a minibuffer window or strongly dedicated to
another buffer, call `pop-to-buffer' to select the buffer in
another window.

If called interactively, read the buffer name using `read-buffer'.
The variable `confirm-nonexistent-file-or-buffer' determines
whether to request confirmation before creating a new buffer.
See `read-buffer' for features related to input and completion
of buffer names.

BUFFER-OR-NAME may be a buffer, a string (a buffer name), or nil.
If BUFFER-OR-NAME is a string that does not identify an existing
buffer, create a buffer with that name.  If BUFFER-OR-NAME is
nil, switch to the buffer returned by `other-buffer'.

If optional argument NORECORD is non-nil, do not put the buffer
at the front of the buffer list, and do not make the window
displaying it the most recently selected one.

Return the buffer switched to."
      ;; The interactive spec is Emacs's. Its first step computes
      ;; `force-same-window' from `window-minibuffer-p' (this tree has no
      ;; minibuffer window - the echo area stands for it),
      ;; `window-dedicated-p' and `switch-to-buffer-in-dedicated-window'
      ;; (there are no dedicated windows here), and for an ordinary window
      ;; that answers `force-same-window' - so the list Emacs passes is
      ;; `(list NEWNAME nil force-same-window)', and the two we can give it
      ;; are nil for NORECORD and that symbol.
      ;;
      ;; **The name is read through `*read-buffer-to-switch*'** and not by
      ;; calling `read-buffer-to-switch' directly: that function is
      ;; `window.el''s but it completes with
      ;; `internal-complete-buffer-except' and installs the table through
      ;; `minibuffer-with-setup-hook', and both live in
      ;; `(schemacs minibuffer)', which is built on this library.
      ;; The minibuffer library sets this parameter as it loads.
      (interactive (list (let ((read-name (*read-buffer-to-switch*)))
                           (if read-name
                               (read-name "Switch to buffer: ")
                               (error "No buffer-name reader is installed")))
                         #f 'force-same-window))
      ;; Display BUFFER-OR-NAME in the *selected* window. The window shows
      ;; it from its first line, and the window's point is the buffer's - a
      ;; window is a view of a buffer, not a copy of it.
      ;;
      ;; **Emacs's next branches are not here**, each for the reason its
      ;; test is missing: `(eq buffer (window-buffer nil))' is the no-op
      ;; case, then the minibuffer window, a dedicated window, and
      ;; `switch-to-buffer-obey-display-actions' (nil in Emacs by default
      ;; and not ported). What is left is the C's ending.
      ;;
      ;; The argument may be a buffer or a name, as in Emacs, and a name
      ;; with no buffer behind it makes one - Emacs's `switch-to-buffer'
      ;; does that too, so `C-x b newname RET' gives a new buffer rather
      ;; than an error. The buffer becomes the most recently used one,
      ;; which is Emacs's `record_buffer', unless NORECORD says otherwise;
      ;; Emacs's third argument, FORCE-SAME-WINDOW, is about minibuffer and
      ;; dedicated windows, which are not modelled here.
      ;;--------------------------------------------------------------
      ;; `. args' and not three fixed parameters: NORECORD and
      ;; FORCE-SAME-WINDOW are optional in Emacs - "do not put the buffer at
      ;; the front of the buffer list" and the error-rather-than-pop case -
      ;; and this tree's callers inside the editor pass only the buffer, as
      ;; Emacs's do. The interactive spec above supplies Emacs's three.
      (let* ((norecord (if (pair? args) (car args) #f))
             (buffer (window-normalize-buffer-to-switch-to buffer-or-name))
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

    ;;----------------------------------------------------------------
    ;; A window's buffer history - `window.el:4564-5010`
    ;;----------------------------------------------------------------
    ;;
    ;; The entries are `(BUFFER START POINT)`: the window's start and
    ;; point for a buffer it showed before. They are what `C-x <left>`
    ;; and `C-x <right>` walk, and what the Buffers menu's "Next/Previous
    ;; Buffer" entries call.
    ;;
    ;; **What is not carried**, each because the thing its test reads does
    ;; not exist here: every branch on a *window parameter*
    ;; (`window-side`, `quit-restore`, `quit-restore-prev`), every branch
    ;; on a *frame parameter* (`buffer-predicate`), the minibuffer-window
    ;; branch (the echo area stands in for the minibuffer and is not a
    ;; window), and the dedicated-window check (nothing here dedicates a
    ;; window). What is left is the walk itself.

    (define (window-prev-buffers . args)
      ;; GNU Emacs's `window-prev-buffers` (`window.c:2322`): the buffers
      ;; WINDOW showed before the one it shows, as `(BUFFER START POS)`
      ;; triples, most recently replaced first.
      ;;--------------------------------------------------------------
      (%window-prev-buffers (or (and (pair? args) (car args))
                                (selected-window))))

    (define (set-window-prev-buffers window value)
      ;; GNU Emacs's `set-window-prev-buffers` (`window.c:2339`): "Set
      ;; WINDOW's previous buffers to PREV-BUFFERS." Answers the value,
      ;; as the C does.
      ;;--------------------------------------------------------------
      (set!%window-prev-buffers window value)
      value)

    (define (window-next-buffers . args)
      ;; GNU Emacs's `window-next-buffers` (`window.c:2353`): the buffers
      ;; `switch-to-prev-buffer` has stepped off, which
      ;; `switch-to-next-buffer` puts back first.
      ;;--------------------------------------------------------------
      (%window-next-buffers (or (and (pair? args) (car args))
                                (selected-window))))

    (define (set-window-next-buffers window value)
      ;; GNU Emacs's `set-window-next-buffers` (`window.c:2376`).
      ;;--------------------------------------------------------------
      (set!%window-next-buffers window value)
      value)

    (define *switch-to-visible-buffer* (make-parameter #t))
    ;; ^ GNU Emacs's `switch-to-visible-buffer` (`window.el:4685`): "If
    ;; this variable is non-nil, `switch-to-prev-buffer' and
    ;; `switch-to-next-buffer' may switch to a buffer that is visible in
    ;; some other window" - off, they skip such buffers.

    (define *switch-to-prev-buffer-skip* (make-parameter #f))
    ;; ^ GNU Emacs's `switch-to-prev-buffer-skip` (`window.el:4699`): nil,
    ;; `t`, `visible`, `0`, or a function of WINDOW, BUFFER and
    ;; BURY-OR-KILL.

    (define *switch-to-prev-buffer-skip-regexp* (make-parameter #f))
    ;; ^ GNU Emacs's `switch-to-prev-buffer-skip-regexp` (`:4749`): a
    ;; regexp, or a list of them, naming buffers never to switch to.

    (define (switch-to-prev-buffer-skip-p skip window buffer . args)
      ;; GNU Emacs's `switch-to-prev-buffer-skip-p` (`window.el:4762`):
      ;; whether BUFFER should be skipped for WINDOW.
      ;;
      ;; The C's non-function SKIP is a frame, and asks
      ;; `(get-buffer-window buffer skip)` - "is BUFFER shown on that
      ;; frame". This tree's `get-buffer-window` takes no frame: there is
      ;; one buffer list and a window's frame is its own, so the answer is
      ;; "is it shown in any window", which is what a single-frame editor
      ;; asks anyway.
      ;;--------------------------------------------------------------
      (or (and skip
               (if (procedure? skip)
                   (apply skip window buffer args)
                   (get-buffer-window buffer)))
          (and (*switch-to-prev-buffer-skip-regexp*)
               (let ((name (buffer-name buffer))
                     (regexps (let ((r (*switch-to-prev-buffer-skip-regexp*)))
                                (if (list? r) r (list r)))))
                 (let loop ((rest regexps))
                   (and (pair? rest)
                        (or (string-match (car rest) name)
                            (loop (cdr rest)))))))))

    (define (record-window-buffer . args)
      ;; GNU Emacs's `record-window-buffer` (`window.el:4590`): "Add the
      ;; buffer currently shown in WINDOW to the list of WINDOW's previous
      ;; buffers."
      ;;
      ;; The C calls this from `Fset_window_buffer` (`window.c:4475`)
      ;; *before* the buffer is replaced, which is why the entry can still
      ;; read the window's buffer, start and point.
      ;;--------------------------------------------------------------
      (let* ((window (or (and (pair? args) (car args)) (selected-window)))
             (buffer (window-buffer window))
             (prev-buffers (%window-prev-buffers window))
             (entry (assq buffer prev-buffers)))
        (when entry
          (set! prev-buffers (assq-delete-all buffer prev-buffers)))
        ;; "Reset WINDOW's next buffers. If needed, they are resurrected
        ;; by `switch-to-prev-buffer' and `switch-to-next-buffer'."
        (set!%window-next-buffers window '())
        ;; "For normal windows do not record insignificant buffers" - a
        ;; name starting with a space is one.
        (unless (char=? #\space (string-ref (buffer-name buffer) 0))
          (let ((start (marker-position (%window-start window)))
                (point (window-point window)))
            (set! entry
                  (cons buffer
                        (with-current-buffer buffer
                          (if entry
                              ;; "We have an entry, update marker
                              ;; positions."
                              (list (set-marker (list-ref entry 1) start buffer)
                                    (set-marker (list-ref entry 2) point buffer))
                              (list (build-marker buffer start)
                                    (build-marker buffer point))))))
            (set!%window-prev-buffers window (cons entry prev-buffers))
            (run-hooks (*buffer-list-update-hook*))))))

    ;; The seam `set-window-buffer!` records through - see
    ;; `*record-window-buffer-function*` in `frame.scm`.
    (*record-window-buffer-function* record-window-buffer)

    (define (unrecord-window-buffer window buffer . args)
      ;; GNU Emacs's `unrecord-window-buffer` (`window.el:4642`), without
      ;; the `quit-restore` half: "Make BUFFER disappear from most
      ;; components specified by the object of WINDOW." What is here is
      ;; the two it can reach - the previous-buffers alist and the
      ;; next-buffers list.
      ;;--------------------------------------------------------------
      (set!%window-prev-buffers
       window
       (delq (assq buffer (%window-prev-buffers window))
             (%window-prev-buffers window)))
      (set!%window-next-buffers window
                                 (delq buffer (%window-next-buffers window))))

    (define (set-window-buffer-start-and-point window buffer . args)
      ;; GNU Emacs's `set-window-buffer-start-and-point` (`window.el:4670`):
      ;; show BUFFER in WINDOW, and put the window's start and point at
      ;; what the history recorded for it.
      ;;--------------------------------------------------------------
      (let ((start (and (pair? args) (car args)))
            (point (and (and (pair? args) (pair? (cdr args))) (cadr args)))
            (selected (eq? window (selected-window)))
            (current (eq? (window-buffer window) (current-buffer))))
        (set-window-buffer! window buffer)
        (when (and selected current)
          (set-buffer buffer))
        (when start
          (set-window-start! window (marker-position start)))
        (when point
          (set-window-point! window (marker-position point)))))

    (define (switch-to-prev-buffer . args)
      ;; GNU Emacs's `switch-to-prev-buffer` (`window.el:4782`): "In
      ;; WINDOW switch to previous buffer. Return the buffer switched to,
      ;; nil if no suitable buffer could be found."
      ;;
      ;; BURY-OR-KILL says the buffer being left is about to go, so it is
      ;; not offered again; `append` keeps its entry but moves it to the
      ;; end of the list, so it is less likely to come back.
      ;;--------------------------------------------------------------
      (let* ((window (or (and (pair? args) (car args)) (selected-window)))
             (bury-or-kill (and (and (pair? args) (pair? (cdr args)))
                                (cadr args)))
             (old-buffer (window-buffer window))
             ;; "Save this since it's destroyed by `set-window-buffer'."
             (next-buffers (%window-next-buffers window))
             (skip (cond ((or (procedure? (*switch-to-prev-buffer-skip*))
                              (memq (*switch-to-prev-buffer-skip*)
                                    '(t visible 0)))
                          (*switch-to-prev-buffer-skip*))
                         ((or (*switch-to-prev-buffer-skip*)
                              (not (*switch-to-visible-buffer*)))
                          #t)
                         (else #f)))
             (new-buffer #f)
             (skipped #f))
        (let/ec found
          ;; "Scan WINDOW's previous buffers first, skipping entries of
          ;; next buffers."
          (for-each
           (lambda (entry)
             (let ((buffer (car entry)))
               (when (and (not (eq? buffer old-buffer))
                          (buffer-live-p buffer)
                          ;; "When BURY-OR-KILL is nil, avoid switching to
                          ;; a buffer in WINDOW's next buffers list."
                          (or bury-or-kill (not (memq buffer next-buffers))))
                 (if (switch-to-prev-buffer-skip-p skip window buffer bury-or-kill)
                     (set! skipped buffer)
                     (begin
                       (set-window-buffer-start-and-point
                        window buffer (list-ref entry 1) (list-ref entry 2))
                       (found #t))))))
           (%window-prev-buffers window))
          ;; "Scan reverted buffer list of WINDOW's frame next, skipping
          ;; entries of next buffers."
          (for-each
           (lambda (buffer)
             (when (and (buffer-live-p buffer)
                        (not (eq? buffer old-buffer))
                        (not (char=? #\space (string-ref (buffer-name buffer) 0)))
                        (or bury-or-kill (not (memq buffer next-buffers))))
               (if (switch-to-prev-buffer-skip-p skip window buffer bury-or-kill)
                   (set! skipped (or skipped buffer))
                   (begin
                     (set! new-buffer buffer)
                     (set-window-buffer-start-and-point window new-buffer)
                     (found #t)))))
           (if bury-or-kill (buffer-list) (reverse (buffer-list))))
          ;; "Scan reverted next buffers last (must not use nreverse
          ;; here!)"
          (unless bury-or-kill
            (for-each
             (lambda (buffer)
               (let ((entry (assq buffer (%window-prev-buffers window))))
                 (when (and (buffer-live-p buffer)
                            (not (eq? buffer old-buffer))
                            entry)
                   (if (switch-to-prev-buffer-skip-p skip window buffer bury-or-kill)
                       (set! skipped (or skipped buffer))
                       (begin
                         (set! new-buffer buffer)
                         (set-window-buffer-start-and-point
                          window new-buffer (list-ref entry 1) (list-ref entry 2))
                         (found #t))))))
             (reverse next-buffers)))
          (when (and skipped (not (procedure? (*switch-to-prev-buffer-skip*))))
            ;; "Show first skipped buffer, unless skip was a function."
            (set! new-buffer skipped)
            (set-window-buffer-start-and-point window new-buffer)))
        (if bury-or-kill
            (let ((entry (and (eq? bury-or-kill 'append)
                              (assq old-buffer (%window-prev-buffers window)))))
              (unrecord-window-buffer window old-buffer)
              (when entry
                ;; "Append old-buffer's entry to list of WINDOW's
                ;; previous buffers so it's less likely to get switched
                ;; to soon."
                (set!%window-prev-buffers
                 window (append (%window-prev-buffers window) (list entry)))))
            ;; "Move `old-buffer' to head of WINDOW's restored list of
            ;; next buffers."
            (set!%window-next-buffers
             window (cons old-buffer (delq old-buffer next-buffers))))
        ;; "Return new-buffer."
        new-buffer))

    (define (switch-to-next-buffer . args)
      ;; GNU Emacs's `switch-to-next-buffer` (`window.el:4915`): "In
      ;; WINDOW switch to next buffer." The opposite direction to
      ;; `switch-to-prev-buffer`, and it reads the same lists in the
      ;; opposite order.
      ;;--------------------------------------------------------------
      (let* ((window (or (and (pair? args) (car args)) (selected-window)))
             (old-buffer (window-buffer window))
             (next-buffers (%window-next-buffers window))
             (skip (cond ((or (procedure? (*switch-to-prev-buffer-skip*))
                              (memq (*switch-to-prev-buffer-skip*)
                                    '(t visible 0)))
                          (*switch-to-prev-buffer-skip*))
                         ((or (*switch-to-prev-buffer-skip*)
                              (not (*switch-to-visible-buffer*)))
                          #t)
                         (else #f)))
             (new-buffer #f)
             (skipped #f))
        (let/ec found
          ;; "Scan WINDOW's next buffers first."
          (for-each
           (lambda (buffer)
             (let ((entry (assq buffer (%window-prev-buffers window))))
               (when (and (buffer-live-p buffer)
                          (not (eq? buffer old-buffer))
                          entry)
                 (if (switch-to-prev-buffer-skip-p skip window buffer)
                     (set! skipped buffer)
                     (begin
                       (set! new-buffer buffer)
                       (set-window-buffer-start-and-point
                        window new-buffer (list-ref entry 1) (list-ref entry 2))
                       (found #t))))))
           next-buffers)
          ;; "Scan the buffer list of WINDOW's frame next, skipping
          ;; previous buffers entries."
          (for-each
           (lambda (buffer)
             (when (and (buffer-live-p buffer)
                        (not (eq? buffer old-buffer))
                        (not (char=? #\space (string-ref (buffer-name buffer) 0)))
                        (not (assq buffer (%window-prev-buffers window))))
               (if (switch-to-prev-buffer-skip-p skip window buffer)
                   (set! skipped (or skipped buffer))
                   (begin
                     (set! new-buffer buffer)
                     (set-window-buffer-start-and-point window new-buffer)
                     (found #t)))))
           (buffer-list))
          ;; "Scan WINDOW's reverted previous buffers last (must not use
          ;; nreverse here!)"
          (for-each
           (lambda (entry)
             (let ((buffer (car entry)))
               (when (and (not (eq? new-buffer buffer))
                          (not (eq? old-buffer buffer))
                          (buffer-live-p buffer))
                 (set! new-buffer buffer)
                 (if (switch-to-prev-buffer-skip-p skip window buffer)
                     (set! skipped (or skipped buffer))
                     (begin
                       (set-window-buffer-start-and-point
                        window buffer (list-ref entry 1) (list-ref entry 2))
                       (found #t))))))
           (reverse (%window-prev-buffers window)))
          (when (and skipped (not (procedure? (*switch-to-prev-buffer-skip*))))
            (set! new-buffer skipped)
            (set-window-buffer-start-and-point window new-buffer)))
        ;; "Remove `new-buffer' from and restore WINDOW's next buffers."
        (set!%window-next-buffers window (delq new-buffer next-buffers))
        new-buffer))

    (define-command (next-buffer arg interactive)
      "In selected window switch to ARGth next buffer.
Call `switch-to-next-buffer' unless the selected window is the
minibuffer window or is dedicated to its buffer."
      ;; "p\np": the prefix argument, and whether this is interactive -
      ;; which is what decides between an error and a quiet nil when
      ;; there is no next buffer.
      ;;--------------------------------------------------------------
      (interactive (list (uarg->integer 1 (current-prefix-arg)) #t))
      (let ((count (or arg 1)))
        (let loop ((n 0))
          (when (< n count)
            (when (and (not (switch-to-next-buffer)) interactive)
              (error "No next buffer"))
            (loop (+ n 1))))))

    (define-command (previous-buffer arg interactive)
      "In selected window switch to ARGth previous buffer.
Call `switch-to-prev-buffer' unless the selected window is the
minibuffer window or is dedicated to its buffer."
      (interactive (list (uarg->integer 1 (current-prefix-arg)) #t))
      (let ((count (or arg 1)))
        (let loop ((n 0))
          (when (< n count)
            (when (and (not (switch-to-prev-buffer)) interactive)
              (error "No previous buffer"))
            (loop (+ n 1))))))

    ;; `bindings.el`'s pair for them: `(define-key ctl-x-map [right]
    ;; 'next-buffer)' and its two neighbours, stated here beside the
    ;; commands as this library states its other keys.
    (define-key *default-keymap* (kbd "C-x <right>") next-buffer)
    (define-key *default-keymap* (kbd "C-x <left>") previous-buffer)

    ;;----------------------------------------------------------------
    ;; Window configurations
    ;;
    ;; GNU Emacs's `Fcurrent_window_configuration' (`window.c:8395') and
    ;; `Fset_window_configuration' (`:7661'), with `save_window_save'
    ;; (`:8263') beneath the first.
    ;;
    ;; **They are window.c's and live in this library, which is
    ;; window.el's.** Restoring a configuration has to ask whether a
    ;; buffer is still alive and, when it is not, find another one - and
    ;; `(schemacs frame)', which is window.c's half in this tree,
    ;; is *below* the library that owns buffers (`buffer.scm` imports
    ;; `frame.scm`). The seam pattern the tree uses elsewhere
    ;; (`*record-window-buffer-function*`, just above) could carry a
    ;; `buffer-live-p` down, but these two procedures are all of
    ;; window.c that would ask.
    ;;
    ;; The saved shape is the C's: one flat vector of saved windows in
    ;; the pre-order `save_window_save` walks, each holding **the window
    ;; object itself** and its parent's and previous sibling's *indices
    ;; into that vector* - which is what `wset_temslot` and `p->parent`
    ;; are in the C. Because the vector holds the objects, restoring a
    ;; configuration puts back windows that were deleted since - Emacs's
    ;; own "Kludge Alert! Mark all windows now on frame as `deleted'.
    ;; Restoring the new configuration `undeletes' any that are in it"
    ;; (`window.c:7810') - and their buffer history, which travels in
    ;; the object.
    ;;
    ;; Not carried, each because the window record has no such field:
    ;; the pixel geometry and the three `normal_*' fractions,
    ;; `dedicated', `combination_limit', the display table, the margins,
    ;; fringes and scroll bars, and `old_pointm'. The *function* arm of
    ;; `window-restore-killed-buffer-windows` is not carried either (the
    ;; two values that decide it, nil and t, are), and neither is the
    ;; frame resize the C ends with - `adjust_frame_size (f, -1, -1, 4,
    ;; ...)` asks for none.
    ;;----------------------------------------------------------------

    (define *window-restore-killed-buffer-windows*
      ;; GNU Emacs's `window-restore-killed-buffer-windows`
      ;; (`syms_of_window`): "Control restoring windows whose buffer was
      ;; killed. ... - t means to restore the window and show some other
      ;; buffer in it. - `delete' means to try to delete the window. -
      ;; `dedicated' means to try to delete the window if and only if it
      ;; is dedicated to its buffer. - nil, the default, which means that
      ;; `set-window-configuration' will try to delete the window if and
      ;; only if it is dedicated to its buffer".
      ;;
      ;; A parameter because a ported caller `let`-binds it - tab-bar's
      ;; `tab-bar-select-tab` binds it around the restore - which is the
      ;; test AGENTS.md gives for the two. `delete` and `dedicated` are
      ;; carried as values but delete nothing here: this tree has no
      ;; `dedicated' field, so a window is never dedicated and the two
      ;; arms reduce to nil's. Named here rather than silently accepted.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define-record-type <window-configuration>
      (make<window-configuration> frame saved selected-window current-buffer
                                  saved-frame)
      window-configuration?
      ;; `window-configuration-frame` (`window.c:7647'): "Return the
      ;; frame that CONFIG ... is about."
      (frame window-configuration-frame)
      ;; The flat saved vector - `data->saved_windows`.
      (saved window-configuration-saved-windows)
      ;; `data->current_window`: `FRAME_SELECTED_WINDOW (f)' when the
      ;; configuration was recorded.
      (selected-window window-configuration-selected-window)
      ;; `data->f_current_buffer`.
      (current-buffer window-configuration-current-buffer)
      ;; `data->selected_frame`, which is not necessarily `frame`.
      (saved-frame window-configuration-saved-frame))

    (define (window-configuration-p object)
      ;; GNU Emacs's `window-configuration-p` (`window.c:7640'): "Return
      ;; t if OBJECT is a window-configuration object." The record's own
      ;; predicate - `window-configuration?` - is the `-?` spelling the
      ;; record type gives; this is the name Emacs's callers use.
      ;;--------------------------------------------------------------
      (window-configuration? object))

    (define-record-type <saved-window>
      (make<saved-window> window buffer start point start-at-line-beg
                          top height left width hscroll min-hscroll
                          suspend-auto-hscroll? parameters parent prev)
      saved-window?
      (window saved-window-window)
      (buffer saved-window-buffer)
      (start saved-window-start)
      (point saved-window-point)
      (start-at-line-beg saved-window-start-at-line-beg)
      (top saved-window-top)
      (height saved-window-height)
      (left saved-window-left)
      (width saved-window-width)
      (hscroll saved-window-hscroll)
      (min-hscroll saved-window-min-hscroll)
      (suspend-auto-hscroll? saved-window-suspend-auto-hscroll?)
      (parameters saved-window-parameters)
      ;; Indices into the saved vector, as `p->parent`/`p->prev` are.
      (parent saved-window-parent)
      (prev saved-window-prev))

    (define (%window-tree-order frame)
      ;; `save_window_save`'s walk: a window, then its children, then its
      ;; siblings. Answers two values: the flat pre-order list, and a
      ;; table from each window to its previous sibling (or #f).
      ;;--------------------------------------------------------------
      (let ((order '())
            (prev-of (make-hash-table)))
        (define (walk w prev)
          (hashq-set! prev-of w prev)
          (set! order (cons w order))
          (let loop ((kids (window-children w)) (p #f))
            (unless (null? kids)
              (walk (car kids) p)
              (loop (cdr kids) (car kids)))))
        (let loop ((wins (frame-windows frame)) (p #f))
          (unless (null? wins)
            (walk (car wins) p)
            (loop (cdr wins) (car wins))))
        (values (reverse order) prev-of)))

    (define (%saved-window-parameters w)
      ;; `save_window_save`'s walk over `window-persistent-parameters`:
      ;; "Save values for persistent window parameters." The variable is
      ;; `((PARAM . SAVE?) ...)` and a parameter whose SAVE? is nil is
      ;; skipped; a parameter the window has no value for is saved as
      ;; nil, and one it has is saved with its value. The C pushes onto
      ;; the front, so the saved order is the reverse of the variable's.
      ;;
      ;; The C's cycle *detection* on the variable is not carried - its
      ;; answer is to reset the variable to nil, which `set!` cannot do
      ;; to another library's parameter from here anyway.
      ;;--------------------------------------------------------------
      (let loop ((pers (*window-persistent-parameters*)) (acc '()))
        (cond ((null? pers) acc)
              ((and (pair? (car pers)) (cdr (car pers)))
               (let ((par (assq (car (car pers)) (window-parameters w))))
                 (loop (cdr pers)
                       (cons (cons (car (car pers)) (and par (cdr par)))
                             acc))))
              (else (loop (cdr pers) acc)))))

    (define (current-window-configuration . args)
      ;; "Return an object representing the current window configuration
      ;; of FRAME. If FRAME is nil or omitted, use the selected frame.
      ;; This describes the number of windows, their sizes and current
      ;; buffers, and for each displayed buffer, where display starts,
      ;; and the position of point. An exception is made for point in
      ;; the current buffer: its value is -not- saved."
      ;;--------------------------------------------------------------
      (let ((frame (or (and (pair? args) (car args)) (*current-frame*))))
        (call-with-values (lambda () (%window-tree-order frame))
          (lambda (order prev-of)
            (let* ((n (length order))
                   (windows (list->vector order))
                   (index (make-hash-table))
                   (saved (make-vector n)))
              (let loop ((i 0))
                (unless (= i n)
                  (hashq-set! index (vector-ref windows i) i)
                  (loop (+ i 1))))
              (let loop ((i 0))
                (unless (= i n)
                  (let* ((w (vector-ref windows i))
                         (buf (window-buffer w))
                         ;; "If w is the selected window, then get the
                         ;; value of point from the buffer; pointm is
                         ;; garbage in the selected window."
                         (point (cond ((not buf) #f)
                                      ((eq? w (selected-window))
                                       (build-marker buf (buffer-pt buf)))
                                      ((%window-point w)
                                       (copy-marker (%window-point w)))
                                      (else #f)))
                         (start (and buf (%window-start w)
                                     (copy-marker (%window-start w))))
                         (parent (window-parent w))
                         (prev (hashq-ref prev-of w)))
                    (vector-set! saved i
                                 (make<saved-window>
                                  w buf start point
                                  (%window-start-at-line-beg w)
                                  (window-top w) (window-height w)
                                  (window-left w) (window-width w)
                                  (%window-hscroll w) (%window-min-hscroll w)
                                  (%window-suspend-auto-hscroll? w)
                                  (%saved-window-parameters w)
                                  (and parent (hashq-ref index parent))
                                  (and prev (hashq-ref index prev))))
                    (loop (+ i 1)))))
              (make<window-configuration> frame saved
                                          (frame-selected-window frame)
                                          (current-buffer)
                                          (*current-frame*)))))))

    (define (%restore-window-marker! window buffer get set position)
      ;; Write MARKER at POSITION in BUFFER, making the marker if the
      ;; window has none yet - the C's `set_marker_restricted` on
      ;; `w->start`/`w->pointm`, whose markers exist from `make_window`
      ;; and here are made lazily.
      ;;--------------------------------------------------------------
      (let ((marker (get window)))
        (cond (marker (set-marker marker (and position (marker-position position))
                                  buffer))
              ((not position) #f)
              (else (set window (build-marker buffer (marker-position position)))))))

    (define (set-window-configuration configuration . args)
      ;; **`FRAME_WINDOW_CHANGE` is set unconditionally** (`window.c:8082`),
      ;; even when the configuration is identical to the current one.
      ;; That is the *first* gate only: `run-window-change-functions` then
      ;; asks whether any window really changed buffer or size or was
      ;; deleted, and a restore of the layout the frame already has runs
      ;; no hook - measured on Emacs 31.1, and pinned in `window-tests`.
      ;; Set at the top rather than at the end where the C sets it: the
      ;; flag is read at the next redisplay, and the only difference is a
      ;; restore that errors half-way through.
      ;; "Set the configuration of windows and buffers as specified by
      ;; CONFIGURATION. ... Normally, this function selects the frame of
      ;; the CONFIGURATION, but if DONT-SET-FRAME is non-nil, it leaves
      ;; selected the frame which was current at the start of the
      ;; function. If DONT-SET-MINIWINDOW is non-nil, the mini-window of
      ;; the frame doesn't get set to the corresponding element of
      ;; CONFIGURATION. ... If CONFIGURATION was made from a frame that
      ;; is now deleted, only frame-independent values can be restored.
      ;; In this case, the return value is nil. Otherwise the value is
      ;; t."
      ;;
      ;; `window-restore-killed-buffer-windows` is read from this
      ;; library's parameter, not Emacs's variable - see its note.
      ;;--------------------------------------------------------------
      (unless (window-configuration? configuration)
        (error "Wrong type argument: window-configuration-p" configuration))
      ;; `FRAME_WINDOW_CHANGE` (`window.c:8082`), **unconditionally** -
      ;; which is what makes a restore that revives a deleted window a
      ;; change even though nothing on the frame moved.
      (let ((f (window-configuration-frame configuration)))
        (when f (set!frame-window-change f #t)))
      (let* ((dont-set-frame (and (pair? args) (car args) #t))
             (dont-set-miniwindow
              (and (pair? args) (pair? (cdr args)) (cadr args) #t))
             (frame (window-configuration-frame configuration))
             (saved (window-configuration-saved-windows configuration))
             (n (vector-length saved))
             (recorded (window-configuration-selected-window configuration))
             (new-current-buffer
              (let ((b (window-configuration-current-buffer configuration)))
                (and b (buffer-live-p b) b)))
             ;; The C's `old_point`: a point to restore at the end for a
             ;; buffer that the selected window does not show. Its
             ;; long comment on the three-way choice is the reason all
             ;; three arms are here.
             (old-point
              (cond
               ((not new-current-buffer) -1)
               ((eq? new-current-buffer (current-buffer))
                (if (and recorded
                         (eq? (window-buffer recorded) new-current-buffer)
                         (selected-window)
                         (eq? (window-buffer (selected-window))
                              new-current-buffer)
                         (not (eq? (selected-window) recorded)))
                    (or (and (%window-point recorded)
                             (marker-position (%window-point recorded)))
                        -1)
                    (buffer-pt new-current-buffer)))
               (else
                (if (and recorded
                         (eq? (window-buffer recorded) new-current-buffer)
                         (not (eq? (selected-window) recorded)))
                    (or (and (%window-point recorded)
                             (marker-position (%window-point recorded)))
                        -1)
                    (buffer-pt new-current-buffer))))))
        (when (frame-live-p frame)
          ;; "If a window we restore gets another buffer, record the
          ;; window's old buffer" - the C's first loop, which runs
          ;; before the tree is torn down.
          (let loop ((k 0))
            (unless (= k n)
              (let* ((p (vector-ref saved k))
                     (w (saved-window-window p))
                     (old (window-buffer w))
                     (new (saved-window-buffer p)))
                (when (and old
                           (not (eq? old new))
                           new
                           (buffer-live-p new)
                           (not (eq? new (*minibuffer*))))
                  ((*record-window-buffer-function*) w)))
              (loop (+ k 1))))
          ;; "Swap out" point from the selected window's buffer into the
          ;; window itself, before the tree is restored.
          (let ((sw (selected-window)))
            (when (and sw (window-buffer sw) (%window-point sw))
              (set-marker (%window-point sw)
                          (buffer-pt (window-buffer sw))
                          (window-buffer sw))))
          ;; Rebuild the window tree from the saved vector. The windows
          ;; that were on the frame and are not in the configuration are
          ;; left detached - the C's "delete_all_child_windows", which
          ;; only *marks* them deleted because the saved vector still
          ;; names the ones it will undelete.
          (let ((old-windows
                 (let walk ((ws (frame-windows frame)) (acc '()))
                   (cond ((null? ws) acc)
                         ((window-internal? (car ws))
                          (walk (window-children (car ws))
                                (walk (cdr ws) (cons (car ws) acc))))
                         (else (walk (cdr ws) (cons (car ws) acc))))))
                (saved-index (make-hash-table))
                (children (make-hash-table))
                (roots '()))
            (let loop ((k 0))
              (unless (= k n)
                (hashq-set! saved-index (saved-window-window (vector-ref saved k)) k)
                (loop (+ k 1))))
            (let loop ((k 0))
              (unless (= k n)
                (let* ((p (vector-ref saved k))
                       (w (saved-window-window p))
                       (pi (saved-window-parent p))
                       (parent (and pi
                                    (saved-window-window (vector-ref saved pi)))))
                  (set!window-parent w parent)
                  (when (not parent)
                    (set! roots (append roots (list w))))
                  ;; The vector is in the C's sibling order, so
                  ;; appending each window as it is met puts a parent's
                  ;; children in their own order.
                  (when parent
                    (hashq-set! children parent
                               (append (or (hashq-ref children parent) '())
                                       (list w))))
                  (loop (+ k 1)))))
            (let loop ((k 0))
              (unless (= k n)
                (let ((w (saved-window-window (vector-ref saved k))))
                  (set!window-children w (or (hashq-ref children w) '())))
                (loop (+ k 1))))
            (for-each (lambda (w)
                        (unless (hashq-ref saved-index w)
                          (set!window-parent w #f)
                          (set!window-children w '())))
                      old-windows)
            (set!frame-windows frame roots))
          ;; Restore each saved window's own state.
          (let loop ((k 0))
            (unless (= k n)
              (let* ((p (vector-ref saved k))
                     (w (saved-window-window p))
                     (buf (saved-window-buffer p)))
                (set!window-top w (saved-window-top p))
                (set!window-height w (saved-window-height p))
                (set!window-left w (saved-window-left p))
                (set!window-width w (saved-window-width p))
                (set!%window-hscroll w (saved-window-hscroll p))
                (set!%window-min-hscroll w (saved-window-min-hscroll p))
                (set!%window-suspend-auto-hscroll?
                 w (saved-window-suspend-auto-hscroll? p))
                ;; "Restore any window parameters that have been saved.
                ;; Parameters that have not been saved are left alone."
                (for-each
                 (lambda (pers)
                   (when (pair? pers)
                     (if (cdr pers)
                         (set-window-parameter w (car pers) (cdr pers))
                         (let ((par (assq (car pers) (window-parameters w))))
                           (when (and par (cdr par))
                             (set-cdr! par #f))))))
                 (saved-window-parameters p))
                (cond
                 ;; "If saved buffer is alive, install it, unless it's a
                 ;; minibuffer we explicitly prohibit."
                 ((and (not (window-internal? w))
                       buf (buffer-live-p buf)
                       (or (not dont-set-miniwindow)
                           (not (window-minibuffer-p w))))
                  (unless (eq? (window-buffer w) buf)
                    (set!window-buffer w buf))
                  (set!%window-start-at-line-beg
                   w (saved-window-start-at-line-beg p))
                  (%restore-window-marker! w buf %window-start
                                           set!%window-start
                                           (saved-window-start p))
                  (%restore-window-marker! w buf %window-point
                                           set!%window-point
                                           (saved-window-point p))
                  ;; "As documented in Fcurrent_window_configuration,
                  ;; don't restore the location of point in the buffer
                  ;; which was current when the window configuration was
                  ;; recorded."
                  (when (and (not (eq? buf new-current-buffer))
                             (eq? buf (current-buffer)))
                    (goto-char (marker-position (%window-point w)))))
                 ((window-internal? w) #f)
                 ;; "Keep window's old buffer; make sure the markers are
                 ;; real."
                 ((let ((cur (window-buffer w)))
                    (and cur (buffer-live-p cur)))
                  (let ((cur (window-buffer w)))
                    (unless (%window-start w)
                      (set!%window-start w (build-marker cur 1)))
                    (unless (%window-point w)
                      (set!%window-point w (build-marker cur (buffer-pt cur))))
                    (set!%window-start-at-line-beg w #t)))
                 ;; "Leaf window has no live buffer, get one."
                 (else
                  (let ((other (or (other-buffer (current-buffer))
                                   (get-buffer-create *scratch-buffer-name*))))
                    (set!window-buffer w other)
                    (set!%window-start w (build-marker other 1))
                    (set!%window-point w (build-marker other 1))
                    (set!%window-start-at-line-beg w #t))))
                (loop (+ k 1)))))
          ;; "Arrange *not* to restore point in the buffer that was
          ;; current when the window configuration was saved." The C
          ;; writes `old_point` into the recorded window's pointm
          ;; *before* selecting it, because `select_window` is what
          ;; hands that marker to the buffer.
          (when (and recorded new-current-buffer
                     (eq? (window-buffer recorded) new-current-buffer)
                     (%window-point recorded))
            (set-marker (%window-point recorded) (max 1 old-point)
                        new-current-buffer))
          ;; "select_window (data->current_window, Qt, true)": select the
          ;; window the configuration was recorded with. Emacs's
          ;; `select_window` also selects the frame the window is on;
          ;; here that is `select-frame`'s job below, and when the
          ;; configuration is of *another* frame only that frame's slot
          ;; is written - our `select-window` reads `(*current-frame*)`,
          ;; and pointing it at another frame's window would put that
          ;; window in the wrong frame's slot.
          (cond ((not recorded) #f)
                ((eq? frame (*current-frame*)) (select-window recorded))
                (else (set!frame-selected-window frame recorded)))
          ;; "do_switch_frame (NILP (dont_set_frame) ? data->selected_frame
          ;; : old_frame)".
          (let ((saved-frame (window-configuration-saved-frame configuration)))
            (when (and (not dont-set-frame)
                       saved-frame
                       (frame-live-p saved-frame))
              (select-frame saved-frame)))
          ;; "If the new current buffer doesn't appear in the selected
          ;; window, go to its old point."
          (when new-current-buffer
            (set-buffer new-current-buffer)
            (unless (eq? (window-buffer (selected-window))
                         new-current-buffer)
              (goto-char (max 1 old-point)))))
        (and (frame-live-p frame) #t)))

    (define (switch-to-buffer-other-window buffer-or-name . args)
      ;; Select BUFFER-OR-NAME in another window: GNU Emacs's
      ;; `switch-to-buffer-other-window', which is `pop-to-buffer' with an
      ;; ACTION that refuses the selected window - so the buffer goes in
      ;; the other window and *that* window is selected, which is what
      ;; leaves the Buffer Menu where it was.
      ;;--------------------------------------------------------------
      (pop-to-buffer buffer-or-name #t (if (pair? args) (car args) #f)))


    (define *window-configuration-change-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `window-configuration-change-hook` (`window.c:9227`):
    ;; "Normal hook run when the buffer in the window changes ...".
    ;;
    ;; **The hook `tab-bar-history-mode` runs on.** A change is noticed
    ;; Emacs's way: the four window-tree functions set the frame's
    ;; `FRAME_WINDOW_CHANGE` flag (`window.c:3715`, `:4427`, `:4896`,
    ;; `:5681`, `:5828`), and `run-window-change-functions` - which the
    ;; redisplay calls where `redisplay_internal` calls it
    ;; (`xdisp.c:17588`) - walks the frames whose flag is set, asks
    ;; whether any window really changed buffer or size or was deleted,
    ;; and runs this hook if so. A parameter because a hook is
    ;; `let`-bound around code that runs it.

    (define %old-selected-frame #f)
    ;; ^ `old_selected_frame` (`window.c:3958`): the frame that was
    ;; selected when window change functions last ran, so the next run
    ;; can tell whether a frame event was a *selection* change. Not
    ;; dynamically bound, so a plain variable.

    (define %window-change-record-frames #f)
    ;; ^ `window_change_record_frames` (`window.c:3947`): whether this
    ;; run of `run-window-change-functions` saw a change worth recording.
    ;; `window_change_record` does nothing when it is false, which is
    ;; what keeps the bookkeeping off the ordinary redisplay.

    (define (window-sub-list window windows)
      ;; GNU Emacs's `window_sub_list` (`window.c:3884`): "Return list of
      ;; live windows constructed by traversing any window sub-tree
      ;; rooted at WINDOW in preorder followed by right siblings of
      ;; WINDOW... The returned list is in reverse order."
      ;;--------------------------------------------------------------
      (let loop ((w window) (acc windows))
        (cond ((not w) acc)
              ((window-internal? w)
               (loop (window-next-sibling w)
                     (window-sub-list (window-child w) acc)))
              (else (loop (window-next-sibling w) (cons w acc))))))

    (define (%window-body-pixel-width window)
      ;; `window_body_width (w, WINDOW_BODY_IN_PIXELS)`: this tree has no
      ;; stored pixel width, so it is the body's columns times the
      ;; frame's character width - the same product `window-pixel-width`
      ;; is.
      ;;--------------------------------------------------------------
      (* (window-body-width window) (frame-char-width (window-frame window))))

    (define (%window-body-pixel-height window)
      ;; `window_body_height (w, WINDOW_BODY_IN_PIXELS)`.
      ;;--------------------------------------------------------------
      (* (window-body-height window) (frame-char-height (window-frame window))))

    (define (window-change-record-windows window stamp number)
      ;; GNU Emacs's `window_change_record_windows` (`window.c:3913`):
      ;; set each live window's change stamp, old buffer and four old
      ;; sizes to what they are now, and answer how many live windows
      ;; that was. "When not called by itself recursively, WINDOW is its
      ;; frame's root window, STAMP is the current change stamp of
      ;; WINDOW's frame and NUMBER is 0."
      ;;--------------------------------------------------------------
      (let loop ((w window) (n number))
        (cond ((not w) n)
              ((window-internal? w)
               (loop (window-next-sibling w)
                     (window-change-record-windows (window-child w) stamp n)))
              (else
               (set!window-change-stamp w stamp)
               (set!window-old-buffer w (window-buffer w))
               (set!window-old-pixel-width w (window-pixel-width w))
               (set!window-old-pixel-height w (window-pixel-height w))
               (set!window-old-body-pixel-width w (%window-body-pixel-width w))
               (set!window-old-body-pixel-height w (%window-body-pixel-height w))
               (loop (window-next-sibling w) (+ n 1))))))

    (define (window-change-record)
      ;; GNU Emacs's `window_change_record` (`window.c:3957`): "For each
      ;; frame that has recorded changes, record its selected window,
      ;; update Fchange stamp, record the states of all its live windows
      ;; via `window_change_record_windows` and reset its `window_change`
      ;; and `window_state_change` flags."
      ;;
      ;; The C's `FRAME_WINDOW_STATE_CHANGE` is not carried: only the
      ;; Lisp function `set-frame-window-state-change` (`frame.c:5047`)
      ;; ever sets it, and nothing here calls one.
      ;;--------------------------------------------------------------
      (when %window-change-record-frames
        (for-each
         (lambda (frame)
           ;; "Record FRAME's selected window."
           (set!frame-old-selected-window frame (frame-selected-window frame))
           ;; "Bump up FRAME's change stamp. If this wraps, make it 1 to
           ;; avoid that a new window (whose change stamp is always set
           ;; to 0) gets reported as 'existing before'."
           (let ((stamp (+ (frame-change-stamp frame) 1)))
             (set!frame-change-stamp frame (if (= stamp 0) 1 stamp)))
           ;; "Bump up the change stamps of all live windows on this
           ;; frame so the next call of this function can tell whether
           ;; any of them 'existed before'."
           (set!frame-number-of-windows
            frame
            (window-change-record-windows (frame-root-window frame)
                                          (frame-change-stamp frame) 0))
           ;; "Reset our flags."
           (set!frame-window-change frame #f))
         (*frame-list*)))
      (set! %old-selected-frame (*current-frame*)))

    (define (run-window-configuration-change-hook frame)
      ;; `run_window_configuration_change_hook` (`window.c:3786`): "The
      ;; buffer-local values are run with the window showing the buffer
      ;; selected. The default value is run with the frame specified by
      ;; F selected. All functions are called with the selected window's
      ;; buffer current."
      ;;
      ;; **Not carried**: the buffer-local half (`Flocal_variable_p` over
      ;; `(window-list frame lambda)`, then selecting each window) - a
      ;; buffer-local hook slot is a thing this tree's parameters do not
      ;; have, and nothing here sets one. `f->can_set_window_size` and
      ;; `f->after_make_frame` are Gtk sizing state, also not carried;
      ;; `Vrun_hooks` has no counterpart.
      ;;
      ;; FRAME is selected by binding `*current-frame*` rather than by
      ;; Emacs's `select_frame_norecord`: the selection is what
      ;; `(selected-frame)` answers, and the frame list does not record
      ;; one of these.
      ;;--------------------------------------------------------------
      (when (frame-type? frame)
        (parameterize ((*current-frame* frame))
          (run-hooks (*window-configuration-change-hook*)))))

    (define (window-buffer-change? frame window frame-window-change)
      ;; `window_buffer_change` (`window.c:4174`): "A 'buffer change'
      ;; means either the window's buffer changed or the window was not
      ;; part of this frame the last time window change functions were run
      ;; for it."
      ;;--------------------------------------------------------------
      (and frame-window-change
           (or (not (eq? (window-buffer window) (window-old-buffer window)))
               (not (= (window-change-stamp window)
                       (frame-change-stamp frame))))))

    (define (window-size-change? frame window frame-window-change)
      ;; `window_size_change` (`window.c:4186`): "A 'size change' means
      ;; either a buffer change or that the total or body size of the
      ;; window has changed."
      ;;--------------------------------------------------------------
      (and frame-window-change
           (or (window-buffer-change? frame window frame-window-change)
               (not (= (window-pixel-width window)
                       (window-old-pixel-width window)))
               (not (= (window-pixel-height window)
                       (window-old-pixel-height window)))
               (not (= (%window-body-pixel-width window)
                       (window-old-body-pixel-width window)))
               (not (= (%window-body-pixel-height window)
                       (window-old-body-pixel-height window))))))

    (define (any-window-either? yes? no? windows)
      ;; The two flags `run_window_change_functions`'s window walk
      ;; accumulates (`window.c:4211`): whether any window of WINDOWS
      ;; answers `yes?`, or, failing that, `no?`. Written as one walk
      ;; because the C computes both in the same loop.
      ;;--------------------------------------------------------------
      (cond ((null? windows) #f)
            ((yes? (car windows)) #t)
            ((no? (car windows)) #t)
            (else (any-window-either? yes? no? (cdr windows)))))

    (define (run-window-change-functions-for-frame frame selected-frame-change)
      ;; `run_window_change_functions`'s frame loop body
      ;; (`window.c:4124`-`:4310`) for one frame.
      ;;--------------------------------------------------------------
      (let* ((frame-window-change (frame-window-change frame))
             (frame-selected-change
              (and selected-frame-change
                   (or (eq? frame %old-selected-frame)
                       (eq? frame (*current-frame*)))))
             (frame-selected-window-change
              (not (eq? (frame-old-selected-window frame)
                        (frame-selected-window frame)))))
        ;; "Either we are not allowed to run hooks for this frame or no
        ;; window change has been reported for it since the last time we
        ;; ran window change functions on it."
        (when (and (frame-live-p frame)
                   (or frame-window-change frame-selected-change
                       frame-selected-window-change))
          (let* ((windows (reverse (window-sub-list (frame-root-window frame) '())))
                 (number-of-windows (length windows))
                 ;; "The following loop collects all data needed to tell
                 ;; whether the default value of a hook shall be run".
                 (frame-size-change
                  (any-window-either?
                   (lambda (w) (window-size-change? frame w frame-window-change))
                   (lambda (w) #f)
                   windows))
                 (frame-buffer-change
                  (any-window-either?
                   (lambda (w) (window-buffer-change? frame w frame-window-change))
                   (lambda (w) #f)
                   windows))
                 ;; "When the number of windows on a frame has decreased,
                 ;; at least one window of that frame was deleted."
                 (window-deleted
                  (< number-of-windows (frame-number-of-windows frame))))
            ;; "A frame has changed state when a size or buffer change
            ;; occurred, its selected window has changed, when it was
            ;; (de-)selected or its window state change flag was set" -
            ;; the record is kept for the next run. **This comes before
            ;; the hook**, as the C has it (`window.c:4296` then
            ;; `:4308`), so a hook that signals still leaves the record
            ;; due.
            (when (or frame-selected-change frame-selected-window-change
                      frame-buffer-change window-deleted frame-size-change)
              (set! %window-change-record-frames #t))
            ;; "A frame's configuration changed when one of its windows
            ;; has changed buffer or size or at least one window was
            ;; deleted."
            (when (or frame-size-change window-deleted)
              (run-window-configuration-change-hook frame))))))

    (define (run-window-change-functions)
      ;; GNU Emacs's `run_window_change_functions` (`window.c:4111`),
      ;; "called from a 'safe' position in `redisplay_internal`".
      ;;
      ;; **The three families of per-window hooks are not carried** -
      ;; `window-buffer-change-functions`, `window-size-change-functions`
      ;; and `window-selection-change-functions`, local and default, and
      ;; the `window-state-change-hook` they feed. What they need is kept,
      ;; because it is what decides whether the *configuration* hook
      ;; runs: `frame_size_change || window_deleted` (`:4300`).
      ;;
      ;; **Not carried**: the `Qinhibit_redisplay` binding around it
      ;; (`:4121`), which lives in `xdisp.scm` and is above this library;
      ;; `report_selected_window_change` (the input method); and
      ;; `f->can_set_window_size`/`f->after_make_frame`, which are Gtk
      ;; sizing state.
      ;;--------------------------------------------------------------
      (let ((selected-frame-change
             (not (eq? (*current-frame*) %old-selected-frame))))
        (set! %window-change-record-frames #f)
        ;; `window_change_record` is the C's `record_unwind_protect_void`
        ;; (`:4122`), so it runs even when a hook signals - which is what
        ;; keeps a failing hook from re-running for ever.
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (for-each (lambda (frame)
                        (run-window-change-functions-for-frame
                         frame selected-frame-change))
                      (*frame-list*)))
          (lambda () (window-change-record)))))

    (define (recombine-windows window)
      ;; GNU Emacs's `recombine_windows` (`window.c:2612`): "If WINDOW can
      ;; be deleted, delete it" is the neighbouring function; this one
      ;; splices WINDOW's children into its parent when WINDOW and its
      ;; parent are combinations of the same direction and WINDOW has no
      ;; `combination-limit` set - which is what stops a delete leaving a
      ;; combination of one kind nested in another of the same kind.
      ;;--------------------------------------------------------------
      (let* ((parent (window-parent window))
             (kids (window-children window)))
        (when (and parent
                   (not (window-combination-limit window))
                   (pair? kids)
                   ;; "WINDOW and PARENT are both either a vertical or a
                   ;; horizontal combination."
                   (eq? (and (window-left-child parent) #t)
                        (and (window-left-child window) #t)))
          (for-each (lambda (child) (set!window-parent child parent)) kids)
          (set!window-children
           parent (list-substitute window kids (window-children parent)))
          (set!window-children window '())
          (set!window-parent window #f))))

    (define (delete-window-internal window)
      ;; GNU Emacs's `delete-window-internal` (`window.c:5691`): "Remove
      ;; WINDOW from its frame. WINDOW defaults to the selected window.
      ;; Return nil. Signal an error when WINDOW is the only window on
      ;; its frame."
      ;;
      ;; **The sizes have already been handed out** by `delete-window`
      ;; before this runs: the resize engine wrote the new sizes into the
      ;; `new-*` registers and this applies them with the C's
      ;; `window_resize_apply (p, horflag)`. A window whose buffer and
      ;; children are both gone has been deleted already and is a no-op,
      ;; as the C's `NILP (w->contents)` test says.
      ;;--------------------------------------------------------------
      (if (and (not (window-buffer window)) (null? (window-children window)))
          #f
          (let ((parent (window-parent window)))
            (cond
             ((not parent)
              ;; "Never delete a minibuffer or frame root window."
              (error "Attempt to delete minibuffer or sole ordinary window"))
             ((and (not (window-prev-sibling window))
                   (not (window-next-sibling window)))
              ;; "Rather bow out here, this case should be handled on the
              ;; Elisp level."
              (error "Attempt to delete sole window of parent"))
             (else
              (let* ((frame (window-frame window))
                     (selected (frame-selected-window frame))
                     (sibling (or (window-prev-sibling window)
                                  (window-next-sibling window)))
                     ;; **Read before the unlink**: a combination left
                     ;; with one child has no axis to read off the
                     ;; rectangles, and `window-left-child` calls a
                     ;; one-child list horizontal. The C reads
                     ;; `WINDOW_HORIZONTAL_COMBINATION_P (p)` before it
                     ;; touches the tree too (`window.c:5717`).
                     (horizontal (and (window-left-child parent) #t))
                     (rest (list-without window (window-children parent))))
                ;; "Unlink WINDOW from window tree."
                (set!window-children parent rest)
                ;; "We can delete WINDOW now": the sizes the engine
                ;; computed go in, and every window's rectangle follows.
                (window-resize-apply frame horizontal)
                (when (= (length rest) 1)
                  ;; "A matryoshka where SIBLING has become the only
                  ;; child of PARENT": put SIBLING into PARENT's place.
                  (let ((child (car rest))
                        (grandparent (window-parent parent)))
                    (set!window-parent child grandparent)
                    (if grandparent
                        (set!window-children
                         grandparent
                         (list-substitute parent
                                          (list child)
                                          (window-children grandparent)))
                        (set!frame-windows
                         frame
                         (list-substitute parent (list child)
                                          (frame-windows frame))))
                    ;; "Try to merge SIBLING into its new parent."
                    (recombine-windows child)))
                ;; "It's a no-op to delete an already deleted window" is
                ;; not true of an internal one: its children go with it.
                (set!window-children window '())
                (set!window-parent window #f)
                (when (eq? window selected)
                  (let ((first (car (window-list frame))))
                    (select-window first)
                    (record-buffer! (window-buffer first))))
                ;; `FRAME_WINDOW_CHANGE (f) = true;` (`window.c:5828`), at
                ;; the end of the C's success branch - a *failed* delete
                ;; is not a window change.
                (set!frame-window-change frame #t)
                #f))))))

    (define-command (delete-window window)
      ;; GNU Emacs's `delete-window` (`window.el:4318`): "Delete
      ;; specified WINDOW... Return nil."
      ;;
      ;; **The space goes to ONE sibling**: "Emacs 23 preferably gives
      ;; WINDOW's space to its left sibling" - the resize engine grows
      ;; the previous sibling, or the next one when there is no previous,
      ;; by the deleted window's whole size. Giving every sibling a
      ;; share, which this did while every combination had two children,
      ;; would grow the frame by one window's worth per sibling.
      ;;
      ;; Not carried, each for want of what it reads: the
      ;; `delete-window` window parameter and `ignore-window-parameters`
      ;; (no side windows, no such parameter), `window--check`'s atomic
      ;; window handling, the "Attempt to delete main window of frame"
      ;; check (no side windows means the main window is the root, which
      ;; the parentless test already refuses) and
      ;; `delete-window-choose-selected` (this tree has no MRU list).
      "Delete WINDOW, giving its space to a sibling.
WINDOW defaults to the selected one. Return nil."
      (interactive (list (selected-window)))
      (let* ((frame (window-frame window))
             (parent (window-parent window)))
        (when (not parent)
          (error "Attempt to delete minibuffer or sole ordinary window"))
        (let* ((horizontal (and (window-left-child parent) #t))
               (size (window-size window horizontal #t))
               (sibling (or (window-prev-sibling window)
                            (window-next-sibling window))))
          (parameterize ((*window-combination-resize*
                          (or (*window-combination-resize*)
                              (window-parameter parent 'window-side))))
            (window--resize-reset frame horizontal)
            (cond
             ((and (not (eq? (*window-combination-resize*) #t))
                   sibling
                   (window-sizable-p sibling size horizontal #f #t))
              ;; "Resize WINDOW's sibling."
              (window--resize-this-window sibling size horizontal #f #t)
              (set-window-new-normal
               sibling (+ (window-normal-size sibling horizontal)
                          (window-normal-size window horizontal))))
             ((window--resizable-p window (- size) horizontal #f #f #f #t #t)
              ;; "Can do without resizing fixed-size windows."
              (window--resize-siblings window (- size) horizontal))
             (else
              ;; "Can't do without resizing fixed-size windows."
              (window--resize-siblings window (- size) horizontal #t))))
          (delete-window-internal window)
          (window--pixel-to-total frame horizontal))
        #f))

    (define-command (delete-other-windows window)
      "Make the selected window the only window on the frame."
      (interactive (list (selected-window)))
      ;; GNU Emacs's `delete-other-windows': make WINDOW the frame's
      ;; only window, filling the frame.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (select-window window)
        (record-buffer! (window-buffer window))
        ;; **`FRAME_WINDOW_CHANGE`** - the C's `Fdelete_other_windows_internal`
        ;; sets it itself, at the end (`window.c:3715`), where this
        ;; function assigns the rectangle directly instead of running the
        ;; resize engine. Without it, deleting the other windows is the
        ;; one window change nothing hears about.
        (set!frame-window-change frame #t)
        ;; **The text area begins below the menu bar**, Emacs's
        ;; `FRAME_TOP_MARGIN` - the row the bar is drawn in is not the
        ;; window's to use.
        (set!window-top window (frame-top-margin frame))
        (set!window-left window 0)
        (set!window-height window (max 1 (- (frame-height frame) 1
                                            (frame-top-margin frame))))
        (set!window-width window (frame-width frame))
        ;; WINDOW becomes the only window of the frame, so it is no longer
        ;; inside anything and holds nothing: the tree is one leaf.
        (set!window-parent window #f)
        (set!window-children window '())
        ;; **The minibuffer window is not in the window tree and is not
        ;; deleted by this.** GNU Emacs's frame has a root window holding
        ;; the ordinary windows and a *separate* `f->minibuffer_window`
        ;; (`frame.h`); deleting the other windows rebuilds the *root*
        ;; tree and never touches the minibuffer window. This tree keeps
        ;; the same two facts in `frame-windows` (the body) and
        ;; `frame-minibuffer-window`, and `window-list` composes them.
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
    ;; `(select-window)' is in `(schemacs frame)', which cannot reach
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
        ;; `select-window''s own doing (`Fselect_window', window.c:3803).
        ;; **A window with no buffer has nothing to make current** - the
        ;; minibuffer window before a prompt is read - and the C guards
        ;; both calls the same way (`Fset_buffer (w->contents)` with a nil
        ;; `contents`, and `record_buffer` inside `if (NILP (norecord))`
        ;; after it has checked the buffer).
        (let ((buffer (window-buffer window)))
          (when buffer
            (set-buffer buffer)
            (record-buffer! buffer)))
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
    ;; GNU Emacs's `(define-key map "b" #'switch-to-buffer)' is in the
    ;; `ctl-x-map' it builds at `subr.el:1746'. This tree has no
    ;; `bindings.el' and binds a command's keys where the command is, as
    ;; the C-x 2/3/1 window keys just below are bound here.
    (define-key *default-keymap* (kbd "C-x b") switch-to-buffer)

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

    (define-syntax save-selected-window
      ;; GNU Emacs's `save-selected-window' (window.el): "Execute BODY,
      ;; then select the previously selected window. The value returned
      ;; is the value of the last form in BODY."
      ;;
      ;; Emacs also saves and restores "the selected window in each
      ;; frame". `select-window` here does not switch frames - the
      ;; departure recorded at that function - so a selection made from
      ;; inside BODY never moves another frame's, and the selected window
      ;; is the whole of what needs putting back.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((save-selected-window body ...)
         (let ((saved-window (selected-window)))
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda () (select-window saved-window)))))))

    (define-syntax save-window-excursion
      ;; GNU Emacs's `save-window-excursion' (`subr.el:5304'):
      ;; "Execute BODY, then restore previous window configuration.
      ;; This macro saves the window configuration on the selected frame,
      ;; executes BODY, then calls `set-window-configuration' to restore
      ;; the saved window configuration.  The return value is the last
      ;; form in BODY.  The window configuration is also restored if BODY
      ;; exits nonlocally."
      ;;
      ;; **Placement departure**: Emacs has this in `subr.el`, but a
      ;; `subr.scm` macro cannot reach `current-window-configuration` -
      ;; `(schemacs window)` is above it - so the macro lives
      ;; beside the two functions it names, as `save-selected-window`
      ;; does. The C's `unwind-protect` is the tree's `dynamic-wind`.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((save-window-excursion body ...)
         (let ((wconfig (current-window-configuration)))
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda () (set-window-configuration wconfig)))))))

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
        (cond ((eq? bury-or-kill 'kill) (%kill-buffer buffer))
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


        ;;------------------------------------------------------------------
    ;; Window sizes - `window.el`'s half
    ;;
    ;; The tree's algebra is `frame.scm`'s (it is `window.c`'s); the
    ;; arithmetic that decides *whether* a window may change size, and
    ;; the state format that records and restores a layout, are
    ;; `window.el`'s and are here. They are here rather than in
    ;; `frame.scm` for one reason: they read `window-size-fixed` from the
    ;; buffer a window shows, and `buffer.scm` is above `frame.scm`.
    ;;
    ;; **Sizes are canonical units** - rows and columns - until the C's
    ;; own pixel arithmetic needs pixels, where the code multiplies by
    ;; `frame-char-size` exactly as the C divides by it. On a terminal
    ;; the two are the same numbers.
    ;;------------------------------------------------------------------

    (define window-safe-min-height 1)
    (define window-safe-min-width 2)
    (define window-resize-pixelwise #f)
    ;; ^ Emacs 31's `defcustom`s and their defaults: the absolute minimum
    ;; a window may be in any circumstances (`window.el:437`), and whether
    ;; a resize is rounded to whole characters (`:490`). Plain variables,
    ;; as the tree spells a `defcustom` the editor never `let`-binds.
    ;;
    ;; `window-combination-resize` (`:245`) *is* `let`-bound - by
    ;; `delete-window` (`:4372`), around the resize engine - so it is a
    ;; parameter, and `*...*` because that is what a dynamically bound
    ;; name looks like here.
    (define-custom *window-combination-resize* #f
      "If t, resize window combinations proportionally.\nIf this variable is nil, splitting a window gets the entire screen space\nfor displaying the new window from the window to split.  Deleting and\nresizing a window preferably resizes one adjacent window only.\n\nIf this variable is t, splitting a window tries to get the space\nproportionally from all windows in the same combination.  This means\nthat one can also split a window that is otherwise too small or of fixed\nsize.  Resizing and deleting a window then proportionally resizes all\nwindows in the same combination.\n\nOther values are reserved for future use.\n\nA specific split operation may ignore the value of this variable if it\nis affected by a non-nil value of ‘window-combination-limit’.  If you\nwant to use a sequence of ‘split-window’ calls to produce a specific,\npredefined layout of windows on a frame, bind this variable temporarily\nto nil."
      :type 'boolean
      :group 'windows
      :version "24.1")
    ;; ^ "If non-nil, `split-window' will try to resize the sibling
    ;; windows of the window it splits to preserve their sizes. If nil,
    ;; it will try to preserve their normal sizes." The parameter exists
    ;; for the same reason `delete-window` binds it: the resize engine
    ;; reads it several frames down.
    ;;
    ;; `window-combination-limit` is `window.c`'s DEFVAR_LISP
    ;; (`:9512`), default `window-size`, and `window--state-put-1` binds
    ;; it (`window.el:6554`), so it is a parameter too.
    (define-custom *window-combination-limit* 'window-size
      "If non-nil, splitting a window makes a new parent window.\nThe following values are recognized:\n\nnil means splitting a window will create a new parent window only if the\n    window has no parent window or the window shall become part of a\n    combination orthogonal to the one it is part of.\n\n‘window-size’ means that splitting a window for displaying a buffer\n    makes a new parent window provided ‘display-buffer’ is supposed to\n    explicitly set the window’s size due to the presence of a\n    ‘window-height’ or ‘window-width’ entry in the alist used by\n    ‘display-buffer’.  Otherwise, this value is handled like nil.\n\n‘temp-buffer-resize’ means that splitting a window for displaying a\n    temporary buffer via ‘with-temp-buffer-window’ makes a new parent\n    window only if ‘temp-buffer-resize-mode’ is enabled.  Otherwise,\n    this value is handled like nil.\n\n‘temp-buffer’ means that splitting a window for displaying a temporary\n    buffer via ‘with-temp-buffer-window’ always makes a new parent\n    window.  Otherwise, this value is handled like nil.\n\n‘display-buffer’ means that splitting a window for displaying a buffer\n    always makes a new parent window.  Since temporary buffers are\n    displayed by the function ‘display-buffer’, this value is stronger\n    than ‘temp-buffer’.  Splitting a window for other purpose makes a\n    new parent window only if needed.\n\nt means that splitting a window always creates a new parent window.  If\n    all splits behave this way, each frame’s window tree is a binary\n    tree and every window but the frame’s root window has exactly one\n    sibling.\n\nThe default value is ‘window-size’.  Other values are reserved for\nfuture use."
      :type '(choice (const :tag "Never" :value #f) (const :tag "If requested via buffer display alist" :value window-size) (const :tag "With Temp Buffer Resize mode" :value temp-buffer-resize) (const :tag "For temporary buffers" :value temp-buffer) (const :tag "For buffer display" :value display-buffer) (other :tag "Always" :value #t))
      :group 'windows
      :version "26.1")
    ;; ^ "If non-nil, `split-window' makes a new parent window. If the
    ;; value is t, a combination is always created... If it is
    ;; `window-size', a new combination is created if the resulting size
    ;; of the parent window would be too small... A value of nil means
    ;; always reuse the parent window." Only `t` changes what
    ;; `split-window` does here: the C tests `EQ (... Qt)` and treats
    ;; everything else - nil and `window-size` alike - as "reuse the
    ;; parent when the direction allows it".

    ;; `window-size-fixed` is a `defvar-local` (`window.el:1517`) and has
    ;; no definition here: this tree's buffer-local values are a
    ;; per-buffer table keyed by symbol, so a buffer that never set it
    ;; reads the default `nil` - which is what the one consult in
    ;; `window--size-fixed-1` asks the table for.

    (define (window--opt args i)
      ;; The Ith element of an optional-argument list, or #f. The tree's
      ;; spelling of `&optional` where a `case-lambda` cannot express it.
      ;;--------------------------------------------------------------
      (let loop ((rest args) (n i))
        (cond ((null? rest) #f)
              ((= n 0) (car rest))
              (else (loop (cdr rest) (- n 1))))))

    (define (window-normalize-window window . args)
      ;; GNU Emacs's `window-normalize-window` (`window.el:379`): "If
      ;; WINDOW is nil, return the selected window. Otherwise, if WINDOW
      ;; is a live or an internal window, return WINDOW; if LIVE-ONLY is
      ;; non-nil, return WINDOW for a live window only."
      ;;--------------------------------------------------------------
      (let ((live-only (window--opt args 0)))
        (cond
         ((not window) (selected-window))
         (live-only
          (if (window-live-p window)
              window
              (error "~a is not a live window" window)))
         ((or (window-live-p window) (window-internal? window)) window)
         (else (error "~a is not a valid window" window)))))

    (define (window-valid-p thing)
      ;; GNU Emacs's `window-valid-p` (`window.c`): "Return t if OBJECT
      ;; is a valid window." A valid window is either a live window or an
      ;; internal window; a deleted one is neither.
      ;;--------------------------------------------------------------
      (and (window-type? thing)
           (or (window-live-p thing) (window-internal? thing))
           #t))

    (define window-resize-pixelwise #f)
    ;; ^ GNU Emacs's `window-resize-pixelwise` (`window.c:9575`): "Non-nil
    ;; means resize windows pixelwise." A plain variable, as the C's
    ;; `DEFVAR_BOOL` is - nothing `let`-binds it, and a user `setq`s it.
    ;; The self-assignment keeps the compiler from folding the read to
    ;; its load-time value.
    (set! window-resize-pixelwise window-resize-pixelwise)

    (define (frame-char-size window-or-frame . args)
      ;; GNU Emacs's `frame-char-size` (`window.el:405`): the frame's
      ;; character height, or its width when HORIZONTAL.
      ;;--------------------------------------------------------------
      (let* ((horizontal (window--opt args 0))
             (frame (cond ((window-valid-p window-or-frame)
                           (window-frame window-or-frame))
                          ((frame-type? window-or-frame) window-or-frame)
                          (else (selected-frame)))))
        (if horizontal (frame-char-width frame) (frame-char-height frame))))

    (define (window-safe-min-pixel-height . args)
      ;; GNU Emacs's `window-safe-min-pixel-height` (`window.el:446`).
      ;;--------------------------------------------------------------
      (* window-safe-min-height
         (frame-char-size (window-normalize-window (window--opt args 0)))))

    (define (window-min-pixel-height . args)
      ;; GNU Emacs's `window-min-pixel-height` (`window.el:467`).
      ;;--------------------------------------------------------------
      (let ((window (window--opt args 0)))
        (* (max (if (window-minibuffer-p window) 1 window-min-height)
                window-safe-min-height)
           (frame-char-size window))))

    (define (window-safe-min-pixel-width . args)
      ;; GNU Emacs's `window-safe-min-pixel-width` (`window.el:478`).
      ;;--------------------------------------------------------------
      (* window-safe-min-width
         (frame-char-size (window-normalize-window (window--opt args 0)) #t)))

    (define (window-min-pixel-width . args)
      ;; GNU Emacs's `window-min-pixel-width` (`window.el:499`).
      ;;--------------------------------------------------------------
      (let ((window (window--opt args 0)))
        (* (max window-min-width window-safe-min-width)
           (frame-char-size window #t))))

    (define (window-safe-min-size . args)
      ;; GNU Emacs's `window-safe-min-size` (`window.el:1587`).
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0)))
            (horizontal (window--opt args 1))
            (pixelwise (window--opt args 2)))
        (if pixelwise
            (if horizontal
                (* window-safe-min-width (frame-char-width (window-frame window)))
                (* window-safe-min-height (frame-char-height (window-frame window))))
            (if horizontal window-safe-min-width window-safe-min-height))))

    (define (window-min-size . args)
      ;; GNU Emacs's `window-min-size` (`window.el:1605`): "Return the
      ;; minimum size of WINDOW."
      ;;--------------------------------------------------------------
      (window--min-size-1 (window-normalize-window (window--opt args 0))
                          (window--opt args 1)
                          (window--opt args 2)
                          (window--opt args 3)))

    (define (window--min-size-ignore-p window ignore)
      ;; GNU Emacs's `window--min-size-ignore-p` (`window.el:1615`).
      ;;--------------------------------------------------------------
      (if (window-valid-p ignore)
          (eq? window ignore)
          (not (memq ignore '(#f preserved)))))

    (define (window--min-size-1 window horizontal ignore pixelwise)
      ;; GNU Emacs's `window--min-size-1` (`window.el:1621`).
      ;;
      ;; The C's vertical branch adds pixel heights; this tree's
      ;; `window-*-height` queries answer rows, so the sum is taken in
      ;; rows and multiplied by the character height once.
      ;;--------------------------------------------------------------
      (let ((sub (window-child window)))
        (if sub
            (let ((value 0))
              (if (window-combined-p sub horizontal)
                  ;; "The minimum size of an iso-combination is the sum
                  ;; of the minimum sizes of its child windows."
                  (let loop ((sub sub))
                    (when sub
                      (set! value (+ value (window--min-size-1 sub horizontal ignore pixelwise)))
                      (loop (window-next-sibling sub))))
                  ;; "The minimum size of an ortho-combination is the
                  ;; maximum of the minimum sizes of its child windows."
                  (let loop ((sub sub))
                    (when sub
                      (set! value (max value (window--min-size-1 sub horizontal ignore pixelwise)))
                      (loop (window-next-sibling sub)))))
              value)
            (let ((buffer (window-buffer window)))
              (cond
               ((not buffer) 0)
               ((window-size-fixed-p window horizontal ignore)
                ;; "The minimum size of a fixed size window is its size."
                (window-size window horizontal pixelwise))
               ((eq? ignore 'safe)
                ;; "If IGNORE equals `safe' return the safe value."
                (window-safe-min-size window horizontal pixelwise))
               (horizontal
                (let* ((char-size (frame-char-size window #t))
                       (fringes (window-fringes window))
                       (margins (window-margins window))
                       (min-margins (window-parameter window 'min-margins))
                       (left-min-margin (and min-margins
                                             (number? (car min-margins))
                                             (car min-margins)))
                       (right-min-margin (and min-margins
                                              (number? (cdr min-margins))
                                              (cdr min-margins)))
                       (pixel-width
                        (+ (window-safe-min-size window #t #t)
                           (* (or left-min-margin (car margins) 0) char-size)
                           (* (or right-min-margin (cdr margins) 0) char-size)
                           (car fringes) (cadr fringes)
                           (window-scroll-bar-width window)
                           (window-right-divider-width window))))
                  (if pixelwise
                      (max (if window-resize-pixelwise
                               pixel-width
                               (* (ceiling (/ pixel-width char-size)) char-size))
                           (if (window--min-size-ignore-p window ignore)
                               0
                               (window-min-pixel-width window)))
                      (max (ceiling (/ pixel-width char-size))
                           (if (window--min-size-ignore-p window ignore)
                               0
                               window-min-width)))))
               (else
                (let* ((char-size (frame-char-size window))
                       (rows (+ (window-safe-min-size window)
                                (window-tab-line-height window)
                                (window-header-line-height window)
                                (window-scroll-bar-height window)
                                (window-mode-line-height window)
                                (window-bottom-divider-width window)))
                       (pixel-height (* rows char-size)))
                  (if pixelwise
                      (max (if window-resize-pixelwise
                               pixel-height
                               (* (ceiling (/ pixel-height char-size)) char-size))
                           (if (window--min-size-ignore-p window ignore)
                               0
                               (window-min-pixel-height window)))
                      (max (ceiling (/ pixel-height char-size))
                           (if (window--min-size-ignore-p window ignore)
                               0
                               window-min-height))))))))))

    (define (window-sizable window delta . args)
      ;; GNU Emacs's `window-sizable` (`window.el:1718`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (ignore (window--opt args 1))
            (pixelwise (window--opt args 2)))
        (set! window (window-normalize-window window))
        (cond
         ((< delta 0)
          (let ((min-size (window-min-size window horizontal ignore pixelwise))
                (size (window-size window horizontal pixelwise)))
            (if (<= size min-size)
                0
                (max (- min-size size) delta))))
         ((> delta 0)
          (if (window-size-fixed-p window horizontal ignore) 0 delta))
         (else 0))))

    (define (window-sizable-p window delta . args)
      ;; GNU Emacs's `window-sizable-p` (`window.el:1756`).
      ;;--------------------------------------------------------------
      (set! window (window-normalize-window window))
      (if (> delta 0)
          (>= (window-sizable window delta (window--opt args 0)
                              (window--opt args 1) (window--opt args 2))
              delta)
          (<= (window-sizable window delta (window--opt args 0)
                              (window--opt args 1) (window--opt args 2))
              delta)))

    (define (window-preserved-size . args)
      ;; GNU Emacs's `window-preserved-size` (`window.el:1545`).
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0) #t))
            (horizontal (window--opt args 1)))
        (let ((parameter (window-parameter window 'window-preserved-size)))
          ;; An `if` and not a `when`: a `when` whose test fails answers
          ;; the *unspecified* value, which is true, and the one caller
          ;; reads this in an `or`.
          (if (and (pair? parameter) (eq? (car parameter) (window-buffer window)))
              (list-ref parameter (if horizontal 1 2))
              #f))))

    (define (window--preserve-size window horizontal)
      ;; GNU Emacs's `window--preserve-size` (`window.el:1556`).
      ;;--------------------------------------------------------------
      (let ((size (window-preserved-size window horizontal)))
        (and (number? size)
             (= size (window-body-size window horizontal #t))
             #t)))

    (define (window-body-size . args)
      ;; GNU Emacs's `window-body-size` (`window.el:2120`).
      ;;--------------------------------------------------------------
      (let ((window (window--opt args 0))
            (horizontal (window--opt args 1))
            (pixelwise (window--opt args 2)))
        (if horizontal
            (if pixelwise
                (* (window-body-width window) (frame-char-width (window-frame window)))
                (window-body-width window))
            (if pixelwise
                (* (window-body-height window) (frame-char-height (window-frame window)))
                (window-body-height window)))))

    (define (window--size-fixed-1 window horizontal ignore)
      ;; GNU Emacs's `window--size-fixed-1` (`window.el:1766`).
      ;;--------------------------------------------------------------
      (let ((sub (window-child window)))
        (if sub
            (if (window-combined-p sub horizontal)
                ;; "An iso-combination is fixed size if all its child
                ;; windows are fixed-size."
                (let loop ((sub sub))
                  (cond ((not sub) #t)
                        ((not (window--size-fixed-1 sub horizontal ignore)) #f)
                        (else (loop (window-next-sibling sub)))))
                ;; "An ortho-combination is fixed-size if at least one of
                ;; its child windows is fixed-size."
                (let loop ((sub sub))
                  (cond ((not sub) #f)
                        ((window--size-fixed-1 sub horizontal ignore) #t)
                        (else (loop (window-next-sibling sub))))))
            ;; "WINDOW is a live window."
            (let ((fixed (and (window-buffer window)
                              (buffer-local-value (window-buffer window)
                                                  'window-size-fixed #f))))
              (and (or (not (window-valid-p ignore)) (not (eq? window ignore)))
                   (or (and (not (eq? ignore 'preserved))
                            (window--preserve-size window horizontal))
                       (if horizontal
                           (and (memq fixed '(width t)) #t)
                           (and (memq fixed '(height t)) #t))))))))

    (define (window-size-fixed-p . args)
      ;; GNU Emacs's `window-size-fixed-p` (`window.el:1804`).
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0)))
            (horizontal (window--opt args 1))
            (ignore (window--opt args 2)))
        (if (or (window-valid-p ignore) (memq ignore '(#f preserved)))
            (window--size-fixed-1 window horizontal ignore)
            #f)))

    (define (window--min-delta-1 window delta horizontal ignore trail noup pixelwise)
      ;; GNU Emacs's `window--min-delta-1` (`window.el:1814`).
      ;;--------------------------------------------------------------
      (if (not (window-parent window))
          ;; "If we can't go up, return zero."
          0
          (let* ((parent (window-parent window))
                 (sub (window-child parent)))
            (let ((done
                   (if (window-combined-p sub horizontal)
                       ;; "In an iso-combination throw DELTA if we find at
                       ;; least one child window and that window is either
                       ;; not fixed-size or we can ignore fixed-sizeness."
                       (let ((skip (eq? trail 'after)))
                         (let loop ((sub sub))
                           (cond
                            ((not sub) #f)
                            ((eq? sub window)
                             (set! skip (eq? trail 'before))
                             (loop (window-next-sibling sub)))
                            (skip (loop (window-next-sibling sub)))
                            ((window-size-fixed-p sub horizontal ignore)
                             (loop (window-next-sibling sub)))
                            (else 'done))))
                       ;; "In an ortho-combination set DELTA to the minimum
                       ;; value by which other child windows can shrink."
                       (let loop ((sub sub))
                         (cond
                          ((not sub) #f)
                          (else
                           (unless (eq? sub window)
                             (set! delta
                                   (min delta
                                        (max (- (window-size sub horizontal pixelwise 'ceiling)
                                                (window-min-size sub horizontal ignore pixelwise))
                                             0))))
                           (loop (window-next-sibling sub))))))))
              (cond ((eq? done 'done) delta)
                    (noup delta)
                    (else (window--min-delta-1 parent delta horizontal ignore
                                               trail #f pixelwise)))))))

    (define (window-min-delta . args)
      ;; GNU Emacs's `window-min-delta` (`window.el:1857`).
      ;;--------------------------------------------------------------
      (let* ((window (window-normalize-window (window--opt args 0)))
             (horizontal (window--opt args 1))
             (ignore (window--opt args 2))
             (trail (window--opt args 3))
             (noup (window--opt args 4))
             (nodown (window--opt args 5))
             (pixelwise (window--opt args 6))
             (size (window-size window horizontal pixelwise 'floor))
             (minimum (window-min-size window horizontal ignore pixelwise)))
        (cond
         (nodown
          ;; "If NODOWN is t, try to recover the entire size of WINDOW."
          (window--min-delta-1 window size horizontal ignore trail noup pixelwise))
         ((<= size minimum)
          ;; "If NODOWN is nil and WINDOW's size is already at its
          ;; minimum, there's nothing to recover."
          0)
         (else
          (window--min-delta-1 window (- size minimum) horizontal ignore
                               trail noup pixelwise)))))

    (define (window--max-delta-1 window delta horizontal ignore trail noup pixelwise)
      ;; GNU Emacs's `window--max-delta-1` (`window.el:1914`).
      ;;--------------------------------------------------------------
      (if (not (window-parent window))
          ;; "Can't go up. Return DELTA."
          delta
          (let* ((parent (window-parent window))
                 (sub (window-child parent))
                 (fixed #f))
            (if (window-combined-p sub horizontal)
                ;; "For an iso-combination calculate how much we can get
                ;; from other child windows."
                (let ((skip (eq? trail 'after)))
                  (let loop ((sub sub))
                    (when sub
                      (cond
                       ((eq? sub window) (set! skip (eq? trail 'before)))
                       (skip #f)
                       (else
                        (set! delta
                              (+ delta
                                 (max (- (window-size sub horizontal pixelwise 'floor)
                                         (window-min-size sub horizontal ignore pixelwise))
                                      0)))))
                      (loop (window-next-sibling sub)))))
                ;; "For an ortho-combination throw DELTA when at least one
                ;; child window is fixed-size." The throw's value is DELTA
                ;; either way, so a fixed sibling and NOUP mean the same
                ;; thing: stop here.
                (let loop ((sub sub))
                  (when sub
                    (when (and (not (eq? sub window))
                               (window-size-fixed-p sub horizontal ignore))
                      (set! fixed #t))
                    (loop (window-next-sibling sub)))))
            (if (or fixed noup)
                ;; "When NOUP is nil, DELTA is all we can get."
                delta
                ;; "Else try with parent of WINDOW, passing the DELTA we
                ;; recovered so far."
                (window--max-delta-1 parent delta horizontal ignore trail #f pixelwise)))))

    (define (window-max-delta . args)
      ;; GNU Emacs's `window-max-delta` (`window.el:1953`).
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0)))
            (horizontal (window--opt args 1))
            (ignore (window--opt args 2))
            (trail (window--opt args 3))
            (noup (window--opt args 4))
            (nodown (window--opt args 5))
            (pixelwise (window--opt args 6)))
        (if (and (not nodown) (window-size-fixed-p window horizontal ignore))
            ;; "With IGNORE and NODOWN nil return zero if WINDOW has fixed
            ;; size."
            0
            (window--max-delta-1 window 0 horizontal ignore trail noup pixelwise))))

    (define (window--resizable window delta . args)
      ;; GNU Emacs's `window--resizable` (`window.el:1987`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (ignore (window--opt args 1))
            (trail (window--opt args 2))
            (noup (window--opt args 3))
            (nodown (window--opt args 4))
            (pixelwise (window--opt args 5)))
        (set! window (window-normalize-window window))
        (cond
         ((< delta 0)
          (max (- (window-min-delta window horizontal ignore trail noup nodown pixelwise))
               delta))
         ((> delta 0)
          (min (window-max-delta window horizontal ignore trail noup nodown pixelwise)
               delta))
         (else 0))))

    (define (window--resizable-p window delta . args)
      ;; GNU Emacs's `window--resizable-p` (`window.el:2031`).
      ;;--------------------------------------------------------------
      (set! window (window-normalize-window window))
      (if (> delta 0)
          (>= (apply window--resizable window delta args) delta)
          (<= (apply window--resizable window delta args) delta)))

    (define (window-resizable window delta . args)
      ;; GNU Emacs's `window-resizable` (`window.el:2048`).
      ;;--------------------------------------------------------------
      (apply window--resizable (window-normalize-window window) delta args))

    (define (window-resizable-p window delta . args)
      ;; GNU Emacs's `window-resizable-p` (`window.el:2079`).
      ;;--------------------------------------------------------------
      (apply window--resizable-p (window-normalize-window window) delta args))

    (define (window--size-to-pixel window size . args)
      ;; GNU Emacs's `window--size-to-pixel` (`window.el:2721`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (pixelwise (window--opt args 1))
            (round-maybe (window--opt args 2)))
        (set! window (window-normalize-window window))
        (let ((char-size (frame-char-size window horizontal)))
          (if pixelwise
              (if (and round-maybe (not window-resize-pixelwise))
                  (* (round (/ size char-size)) char-size)
                  size)
              (* size char-size)))))

    (define (window--pixel-to-total-1 window horizontal char-size)
      ;; GNU Emacs's `window--pixel-to-total-1` (`window.el:2743`).
      ;;--------------------------------------------------------------
      (let ((child (window-child window)))
        (if (window-combination-p window horizontal)
            ;; "In an iso-combination distribute sizes proportionally."
            (let ((remainder (window-new-total window)))
              ;; "Initialize total sizes to each child's floor."
              (let loop ((child child))
                (when child
                  (let ((size (max (quotient (window-size child horizontal #t) char-size) 1)))
                    (set-window-new-total child size)
                    (set! remainder (- remainder size))
                    (loop (window-next-sibling child)))))
              ;; "Distribute remainder."
              (let loop ((remainder remainder))
                (when (> remainder 0)
                  (let inner ((child (window-last-child window))
                              (best-child #f)
                              (best-rem 0))
                    (cond
                     ((not child)
                      ;; "We MUST have a best-child here."
                      (set-window-new-total best-child 1 #t)
                      (loop (- remainder 1)))
                     (else
                      (when (and (<= (window-new-total child)
                                     (quotient (window-size child horizontal #t) char-size))
                                 (> (modulo (window-size child horizontal #t) char-size)
                                    best-rem))
                        (set! best-child child)
                        (set! best-rem (modulo (window-size child horizontal #t) char-size)))
                      (inner (window-prev-sibling child) best-child best-rem))))))
              ;; "Recurse."
              (let loop ((child child))
                (when child
                  (window--pixel-to-total-1 child horizontal char-size)
                  (loop (window-next-sibling child)))))
            ;; "In an ortho-combination assign new sizes directly."
            (let ((size (window-new-total window)))
              (let loop ((child child))
                (when child
                  (set-window-new-total child size)
                  (window--pixel-to-total-1 child horizontal char-size)
                  (loop (window-next-sibling child))))))))

    (define (window--pixel-to-total . args)
      ;; GNU Emacs's `window--pixel-to-total` (`window.el:2785`).
      ;;--------------------------------------------------------------
      (let* ((frame (or (window--opt args 0) (selected-frame)))
             (horizontal (window--opt args 1))
             (char-size (frame-char-size frame horizontal))
             (root (frame-root-window frame))
             (root-size (window-size root horizontal #t))
             (mini (let ((mini (frame-minibuffer-window frame)))
                     (and mini (eq? (window-frame mini) frame)
                          (not (eq? mini root))
                          mini)))
             (mini-size (and mini (window-size mini horizontal #t))))
        ;; "We round the line/column sizes of windows here to the nearest
        ;; integer."
        (if (and mini (not horizontal))
            (begin
              (set-window-new-total root (max (quotient root-size char-size) 1))
              (set-window-new-total mini (max (quotient mini-size char-size) 1))
              (let loop ((lines (- (round (/ (+ root-size mini-size) char-size))
                                   (+ (window-new-total root) (window-new-total mini)))))
                (when (> lines 0)
                  (if (>= (modulo root-size (window-new-total root))
                          (modulo mini-size (window-new-total mini)))
                      (set-window-new-total root 1 #t)
                      (set-window-new-total mini 1 #t))
                  (loop (- lines 1)))))
            (begin
              (set-window-new-total root (round (/ root-size char-size)))
              (when mini
                ;; "This is taken in the horizontal case only."
                (set-window-new-total mini (round (/ mini-size char-size))))))
        (unless (window-buffer root)
          (window--pixel-to-total-1 root horizontal char-size))
        ;; "Apply the new sizes."
        (window-resize-apply-total frame horizontal)))

    (define (window--resize-reset . args)
      ;; GNU Emacs's `window--resize-reset` (`window.el:2826`).
      ;;--------------------------------------------------------------
      (window--resize-reset-1
       (frame-root-window (or (window--opt args 0) (selected-frame)))
       (window--opt args 1)))

    (define (window--resize-reset-1 window horizontal)
      ;; GNU Emacs's `window--resize-reset-1` (`window.el:2837`).
      ;;--------------------------------------------------------------
      ;; "Register old size in the new total size."
      (set-window-new-pixel window (window-size window horizontal #t))
      (set-window-new-total window (window-size window horizontal))
      ;; "Reset new normal size."
      (set-window-new-normal window)
      (when (window-child window)
        (window--resize-reset-1 (window-child window) horizontal))
      (when (window-next-sibling window)
        (window--resize-reset-1 (window-next-sibling window) horizontal)))

    (define (window--resize-apply-p frame . args)
      ;; GNU Emacs's `window--resize-apply-p` (`window.el:2888`): whether
      ;; any window on FRAME has a new size that differs from its own.
      ;; `walk-window-tree` visits internal windows too, so this does.
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0)))
        (let walk ((window (frame-root-window frame)))
          (and window
               (or (not (= (window-new-pixel window)
                           (window-size window horizontal #t)))
                   (let loop ((kids (window-children window)))
                     (cond ((null? kids) #f)
                           ((walk (car kids)) #t)
                           (else (loop (cdr kids))))))))))

    (define (window--resize-child-windows-skip-p window)
      ;; GNU Emacs's `window--resize-child-windows-skip-p`
      ;; (`window.el:3049`).
      ;;--------------------------------------------------------------
      (memq (window-new-normal window) '(ignore stuck skip)))

    (define (window--resize-child-windows-normal parent horizontal window this-delta . args)
      ;; GNU Emacs's `window--resize-child-windows-normal`
      ;; (`window.el:3053`): set the children's shares from what they
      ;; should have contributed for THIS-DELTA.
      ;;--------------------------------------------------------------
      (let ((trail (window--opt args 0))
            (other-delta (window--opt args 1)))
        (let* ((parent-total (window-size parent horizontal #t))
               (delta-normal
                (if (and (= (- this-delta) (window-size window horizontal #t))
                         (or (not other-delta) (= other-delta 0)))
                    ;; "When WINDOW gets deleted and we can return its
                    ;; entire space to its siblings, use WINDOW's normal
                    ;; size as the normal delta."
                    (- (window-normal-size window horizontal))
                    ;; "In any other case calculate the normal delta from
                    ;; the relation of THIS-DELTA to the total size of
                    ;; PARENT."
                    (/ (exact->inexact this-delta) parent-total)))
               (skip (eq? trail 'after)))
          ;; "Set parent-normal to the sum of the normal sizes of all
          ;; child windows of PARENT that shall be resized."
          (let ((parent-normal
                 (let loop ((sub (window-child parent)) (sum 0.0) (skip skip))
                   (cond ((not sub) sum)
                         ((eq? sub window) (loop (window-next-sibling sub) sum (eq? trail 'before)))
                         (skip (loop (window-next-sibling sub) sum skip))
                         (else (loop (window-next-sibling sub)
                                     (+ sum (window-normal-size sub horizontal))
                                     skip))))))
            ;; "Set the new normal size of all child windows of PARENT
            ;; from what they should have contributed for recovering
            ;; THIS-DELTA lines."
            (let loop ((sub (window-child parent)) (skip (eq? trail 'after)))
              (when sub
                (cond ((eq? sub window) (loop (window-next-sibling sub) (eq? trail 'before)))
                      (skip (loop (window-next-sibling sub) skip))
                      (else
                       (let ((old-normal (window-normal-size sub horizontal)))
                         (set-window-new-normal
                          sub (min 1.0
                                   (max (- old-normal
                                           (* (/ old-normal parent-normal) delta-normal))
                                        0.0))))
                       (loop (window-next-sibling sub) skip)))))
            (when (number? other-delta)
              ;; "Set the new normal size of windows from what they should
              ;; have contributed for recovering OTHER-DELTA lines."
              (let ((delta-normal (/ (exact->inexact parent-total)
                                     (+ parent-total other-delta))))
                (let loop ((sub (window-child parent)) (skip (eq? trail 'after)))
                  (when sub
                    (cond ((eq? sub window) (loop (window-next-sibling sub) (eq? trail 'before)))
                          (skip (loop (window-next-sibling sub) skip))
                          (else
                           (set-window-new-normal
                            sub (min 1.0
                                     (max (* (window-new-normal sub) delta-normal)
                                          0.0)))
                           (loop (window-next-sibling sub) skip)))))))
            ;; "Set the new normal size of WINDOW to what is left by the
            ;; sum of the normal sizes of its siblings."
            (set-window-new-normal
             window
             (let loop ((sub (window-child parent)) (sum 0.0))
               (cond ((not sub) (min 1.0 (max (- 1.0 sum) 0.0)))
                     ((eq? sub window) (loop (window-next-sibling sub) sum))
                     ((not (number? (window-new-normal sub)))
                      (loop (window-next-sibling sub)
                            (+ sum (window-normal-size sub horizontal))))
                     (else (loop (window-next-sibling sub)
                                 (+ sum (window-new-normal sub)))))))))))

    (define (window--resize-child-windows parent delta . args)
      ;; GNU Emacs's `window--resize-child-windows` (`window.el:3108`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (window (window--opt args 1))
            (ignore (window--opt args 2))
            (trail (window--opt args 3))
            (edge (window--opt args 4))
            (char-size (window--opt args 5)))
        (let* ((first (window-child parent))
               (last (window-last-child parent))
               (parent-total (+ (window-size parent horizontal #t) delta))
               (char-size (or char-size
                              (and window-resize-pixelwise 1)
                              (frame-char-size window horizontal)))
               (best-window #f))
          (let* ((sub (let loop ((w first))
                        (if (and (window-next-sibling w)
                                 (or (and (eq? trail 'before)
                                          (not (window--resize-child-windows-skip-p
                                                (window-next-sibling w))))
                                     (and (eq? trail 'after)
                                          (window--resize-child-windows-skip-p w))))
                            (loop (window-next-sibling w))
                            w)))
                 (adjacent
                  (and edge (memq trail '(before after))
                       (if horizontal
                           (if (eq? trail 'before)
                               (= (+ (window-pixel-left sub) (window-pixel-width sub)) edge)
                               (= (window-pixel-left sub) edge))
                           (if (eq? trail 'before)
                               (= (+ (window-pixel-top sub) (window-pixel-height sub)) edge)
                               (= (window-pixel-top sub) edge)))
                       (window-sizable-p sub delta horizontal ignore #t))))
            (if adjacent
              ;; "Resize only windows adjacent to EDGE."
              (begin
                (window--resize-this-window sub delta horizontal ignore #t trail edge)
                (if (and window (eq? (window-parent sub) parent))
                    (begin
                      ;; "Assign new normal sizes."
                      (set-window-new-normal
                       sub (/ (exact->inexact (window-new-pixel sub)) parent-total))
                      (set-window-new-normal
                       window (- (window-normal-size window horizontal)
                                 (- (window-new-normal sub)
                                    (window-normal-size sub horizontal)))))
                    (window--resize-child-windows-normal parent horizontal sub 0 trail delta))
                ;; "Return 'normalized to notify `window--resize-siblings'
                ;; that normal sizes have been already set."
                'normalized)
              ;; "Resize all windows proportionally."
              (begin
                (let loop ((sub last))
                  (when sub
                    (cond
                     ((or (window--resize-child-windows-skip-p sub)
                          ;; "Ignore windows to skip and fixed-size child
                          ;; windows - in the latter case make it a window
                          ;; to skip."
                          (and (not ignore)
                               (window-size-fixed-p sub horizontal ignore)
                               (set-window-new-normal sub 'ignore)))
                      #f)
                     ((< delta 0)
                      ;; "When shrinking store the number of lines/cols we
                      ;; can get from this window here together with the
                      ;; total/normal size factor."
                      (set-window-new-normal
                       sub
                       (cons (window-min-delta sub horizontal ignore trail #t #f #t)
                             (- (/ (exact->inexact (window-size sub horizontal #t))
                                   parent-total)
                                (window-normal-size sub horizontal)))))
                     ((> delta 0)
                      ;; "When enlarging store the total/normal size factor
                      ;; only."
                      (set-window-new-normal
                       sub
                       (- (/ (exact->inexact (window-size sub horizontal #t))
                             parent-total)
                          (window-normal-size sub horizontal)))))
                    (loop (window-prev-sibling sub))))

                (cond
                 ((< delta 0)
                  ;; "Shrink windows by delta."
                  (let loop ((best-window #t) (delta delta))
                    (if (and best-window (not (= delta 0)))
                        (let inner ((sub last) (bw #f) (bv #f))
                          (cond
                           ((not sub)
                            (set! best-window bw)
                            (if bw
                                (begin
                                  (let ((best-delta (min (car (window-new-normal bw))
                                                         char-size (- delta))))
                                    (set! delta (+ delta best-delta))
                                    (set-window-new-pixel bw (- best-delta) #t)
                                    (set-window-new-normal
                                     bw
                                     (if (= (car (window-new-normal bw)) best-delta)
                                         'skip
                                         (cons (- (car (window-new-normal bw)) best-delta)
                                               (- (/ (exact->inexact (window-new-pixel bw))
                                                     parent-total)
                                                  (window-normal-size bw horizontal))))))
                                  (loop bw delta))
                                #f))
                           (else
                            (let ((nbw bw) (nbv bv))
                              (when (and (pair? (window-new-normal sub))
                                         (not (<= (car (window-new-normal sub)) 0))
                                         (or (not bv)
                                             (> (cdr (window-new-normal sub)) bv)))
                                (set! nbw sub)
                                (set! nbv (cdr (window-new-normal sub))))
                              (inner (window-prev-sibling sub) nbw nbv)))))
                        #f)))
                 ((> delta 0)
                  ;; "Enlarge windows by delta."
                  (let loop ((best-window #t) (delta delta))
                    (if (and best-window (not (= delta 0)))
                        (let inner ((sub last) (bw #f) (bv #f))
                          (cond
                           ((not sub)
                            (set! best-window bw)
                            (if bw
                                (begin
                                  (let ((best-delta (min delta char-size)))
                                    (set! delta (- delta best-delta))
                                    (set-window-new-pixel bw best-delta #t)
                                    (set-window-new-normal
                                     bw
                                     (- (/ (exact->inexact (window-new-pixel bw))
                                           parent-total)
                                        (window-normal-size bw horizontal))))
                                  (loop bw delta))
                                #f))
                           (else
                            (let ((nbw bw) (nbv bv))
                              (when (and (number? (window-new-normal sub))
                                         (or (not bv)
                                             (< (window-new-normal sub) bv)))
                                (set! nbw sub)
                                (set! nbv (window-new-normal sub)))
                              (inner (window-prev-sibling sub) nbw nbv)))))
                        #f))))

                (when best-window
                  (let loop ((sub last))
                    (when sub
                      (when (or (pair? (window-new-normal sub))
                                (number? (window-new-normal sub)))
                        ;; "Reset new normal size fields so
                        ;; `window-resize-apply' won't use them to apply
                        ;; new sizes."
                        (set-window-new-normal sub))
                      (unless (eq? (window-new-normal sub) 'ignore)
                        ;; "Resize this window's child windows
                        ;; (back-engineering delta from sub's old and new
                        ;; total sizes)."
                        (let ((delta (- (window-new-pixel sub)
                                        (window-size sub horizontal #t))))
                          (unless (and (= delta 0) (not trail))
                            (window--resize-this-window sub delta horizontal
                                                        ignore #f trail edge))))
                      (loop (window-prev-sibling sub)))))))))))

    (define (window--resize-siblings window delta . args)
      ;; GNU Emacs's `window--resize-siblings` (`window.el:3286`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (ignore (window--opt args 1))
            (trail (window--opt args 2))
            (edge (window--opt args 3))
            (char-size (window--opt args 4)))
        (when (window-parent window)
          (let ((parent (window-parent window))
                (delta delta))
            (if (window-combined-p (window-child parent) horizontal)
                ;; "In an iso-combination try to extract DELTA from
                ;; WINDOW's siblings."
                (let ((this-delta #f))
                  ;; "Decide which windows shall be left alone."
                  (let loop ((sub (window-child parent)) (skip (eq? trail 'after)))
                    (when sub
                      (cond
                       ((eq? sub window)
                        ;; "Make sure WINDOW is left alone when resizing
                        ;; its siblings."
                        (set-window-new-normal sub 'ignore)
                        (loop (window-next-sibling sub) (eq? trail 'before)))
                       (skip
                        ;; "Make sure this sibling is left alone when
                        ;; resizing its siblings."
                        (set-window-new-normal sub 'ignore)
                        (loop (window-next-sibling sub) skip))
                       (else
                        ;; "Set this-delta to t to signal that we found a
                        ;; sibling of WINDOW whose size is not fixed."
                        (unless (window-size-fixed-p sub horizontal ignore)
                          (set! this-delta #t))
                        (loop (window-next-sibling sub) skip)))))
                  ;; "Set this-delta to what we can get from WINDOW's
                  ;; siblings."
                  (set! this-delta
                        (if (= (- delta) (window-size window horizontal #t))
                            ;; "A deletion, presumably."
                            (if this-delta delta 0)
                            ;; "Any other form of resizing."
                            (window--resizable window delta horizontal ignore
                                               trail #t #f #t)))
                  ;; "Set other-delta to what we still have to get from
                  ;; ancestor windows of parent."
                  (let ((other-delta (- delta this-delta)))
                    (unless (= other-delta 0)
                      ;; "Unless we got everything from WINDOW's siblings,
                      ;; PARENT must be resized by other-delta lines or
                      ;; columns."
                      (set-window-new-pixel parent other-delta #t))
                    (if (= this-delta 0)
                        ;; "We haven't got anything from WINDOW's siblings
                        ;; but we must update the normal sizes to respect
                        ;; other-delta."
                        (window--resize-child-windows-normal
                         parent horizontal window this-delta trail other-delta)
                        (begin
                          ;; "We did get something from WINDOW's siblings
                          ;; which means we have to resize their child
                          ;; windows."
                          (unless (eq? (window--resize-child-windows
                                        parent (- this-delta) horizontal
                                        window ignore trail edge char-size)
                                       'normalized)
                            ;; "Set the normal sizes."
                            (window--resize-child-windows-normal
                             parent horizontal window this-delta trail other-delta))
                          ;; "Set DELTA to what we still have to get from
                          ;; ancestor windows."
                          (set! delta other-delta)))))
                ;; "In an ortho-combination all siblings of WINDOW must be
                ;; resized by DELTA."
                (begin
                  (set-window-new-pixel parent delta #t)
                  (let loop ((sub (window-child parent)))
                    (when sub
                      (unless (eq? sub window)
                        (window--resize-this-window sub delta horizontal ignore #t))
                      (loop (window-next-sibling sub))))))
            (unless (= delta 0)
              ;; "Go up."
              (window--resize-siblings parent delta horizontal ignore trail edge char-size))))))

    (define (window--resize-this-window window delta . args)
      ;; GNU Emacs's `window--resize-this-window` (`window.el:3385`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (ignore (window--opt args 1))
            (add (window--opt args 2))
            (trail (window--opt args 3))
            (edge (window--opt args 4))
            (char-size (window--opt args 5)))
        (when add
          ;; "Add DELTA to the new total size of WINDOW."
          (set-window-new-pixel window delta #t))
        (let ((sub (window-child window)))
          (cond
           ((not sub) #f)
           ((window-combined-p sub horizontal)
            ;; "In an iso-combination resize child windows according to
            ;; their normal sizes."
            (window--resize-child-windows window delta horizontal #f ignore
                                          trail edge char-size))
           (else
            ;; "In an ortho-combination resize each child window by
            ;; DELTA."
            (let loop ((sub sub))
              (when sub
                (window--resize-this-window sub delta horizontal ignore #t trail edge char-size)
                (loop (window-next-sibling sub)))))))))

    (define (window--resize-mini-window window delta)
      ;; GNU Emacs's `window--resize-mini-window` (`window.el:2853`), over
      ;; this tree's `grow-mini-window` - which is
      ;; `resize_mini_window`'s answer to the same question: the mini
      ;; window grows into the root window's rows, and a negative DELTA
      ;; shrinks it ("If DELTA is negative, this may shrink the
      ;; minibuffer window", `window.c:5901`). The C clamps DELTA to the
      ;; minimum the mini window needs and the maximum the root can give
      ;; before applying it; `grow-mini-window` clamps to the frame
      ;; itself, so the same clamp is spelled once, there.
      ;;--------------------------------------------------------------
      (when (and (window-minibuffer-p window) (not (= delta 0)))
        (grow-mini-window window
                          (inexact->exact
                           (round (/ delta (frame-char-height (window-frame window))))))))

    (define (window-resize window delta . args)
      ;; GNU Emacs's `window-resize` (`window.el:2901`): "Resize WINDOW
      ;; vertically by DELTA lines." Positive grows, negative shrinks,
      ;; and other windows in the combination take up or give the space.
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (ignore (window--opt args 1))
            (pixelwise (window--opt args 2)))
        (set! window (window-normalize-window window))
        (let* ((frame (window-frame window))
               (delta (window--size-to-pixel window delta horizontal pixelwise #t)))
          (cond
           ((eq? window (frame-root-window frame))
            (error "Cannot resize the root window of a frame"))
           ((window-minibuffer-p window)
            (if horizontal
                (error "Cannot resize minibuffer window horizontally")
                (window--resize-mini-window window delta)))
           ((and (not horizontal)
                 (window-full-height-p window)
                 (or (not *resize-mini-windows*)
                     (minibuffer-window-active-p (frame-minibuffer-window frame))))
            ;; "If WINDOW is full height and either `resize-mini-windows'
            ;; is nil or the minibuffer window is active, resize the
            ;; minibuffer window."
            (window--resize-mini-window (frame-minibuffer-window frame) (- delta)))
           ((or (window--resizable-p window delta horizontal ignore #f #f #f #t)
                (and (not ignore)
                     (set! ignore 'preserved)
                     (window--resizable-p window delta horizontal ignore #f #f #f #t)))
            (window--resize-reset frame horizontal)
            (window--resize-this-window window delta horizontal ignore #t)
            (let ((sibling (and (not (eq? (*window-combination-resize*) #t))
                                (window-combined-p window horizontal)
                                (or (window-right-sibling window)
                                    (window-left-sibling window)))))
              (if (and sibling
                       (window-sizable-p sibling (- delta) horizontal ignore #t))
                  ;; "If window-combination-resize is nil, WINDOW is part
                  ;; of an iso-combination, and WINDOW's neighboring right
                  ;; or left sibling can be resized as requested, resize
                  ;; that sibling."
                  (let ((normal-delta (/ (exact->inexact delta)
                                         (window-size (window-parent window) horizontal #t))))
                    (window--resize-this-window sibling (- delta) horizontal #f #t)
                    (set-window-new-normal
                     window (+ (window-normal-size window horizontal) normal-delta))
                    (set-window-new-normal
                     sibling (- (window-normal-size sibling horizontal) normal-delta)))
                  ;; "Otherwise, resize all other windows in the same
                  ;; combination."
                  (window--resize-siblings window delta horizontal ignore)))
            (when (window--resize-apply-p frame horizontal)
              (if (window-resize-apply frame horizontal)
                  (window--pixel-to-total frame horizontal)
                  (error "Failed to apply resizing ~a" window))))
           (else
            (error "Cannot resize window ~a" window))))))

    (define (window-resize-no-error window delta . args)
      ;; GNU Emacs's `window-resize-no-error` (`window.el:2995`).
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (ignore (window--opt args 1))
            (pixelwise (window--opt args 2)))
        (if (window--resizable-p window delta horizontal ignore #f #f #f pixelwise)
            (window-resize window delta horizontal ignore pixelwise)
            #f)))

    (define (adjust-window-trailing-edge window delta . args)
      ;; GNU Emacs's `adjust-window-trailing-edge` (`window.el:3528`):
      ;; "Move WINDOW's bottom edge by DELTA lines. Optional argument
      ;; HORIZONTAL non-nil means move WINDOW's right edge by DELTA
      ;; columns. ... If the edge can't be moved by DELTA lines or
      ;; columns, move it as far as possible in the desired direction."
      ;;
      ;; This is what a mode-line drag calls (`mouse-drag-line`,
      ;; `mouse.el:871`). DELTA is in lines/columns unless PIXELWISE;
      ;; the C turns one into the other with the frame's character size,
      ;; and here a cell *is* the display's pixel - `frame-char-size` is
      ;; 1 on a terminal and the frame's cell size on a toolkit display.
      ;;--------------------------------------------------------------
      (let ((horizontal (window--opt args 0))
            (pixelwise (window--opt args 1)))
        (set! window (window-normalize-window window))
        (let* ((frame (window-frame window))
               (minibuffer-window (frame-minibuffer-window frame))
               (right window)
               (left #f)
               (first-left #f)
               (first-right #f)
               (this-delta 0)
               (min-delta 0)
               (max-delta 0)
               (ignore #f))
          (unless pixelwise
            (set! pixelwise #t)
            (set! delta (* delta (frame-char-size window horizontal))))
          ;; Find the edge we want to move: the topmost window in a
          ;; vertical combination (or the leftmost in a horizontal one)
          ;; that has a sibling on the far side.
          ;; **RIGHT can become nil mid-walk**, and `window-parent` is a
          ;; record accessor: Elisp's `(window-parent nil)` means the
          ;; *selected* window (`decode_any_window`), ours raises
          ;; "expecting struct". Emacs's `while` also ends the moment the
          ;; parent is nil - that is what the walk-up is looking for - so
          ;; the nil test is the loop's own termination, written out.
          (let loop ()
            (when (and right
                       (or (not (window-combined-p right horizontal))
                           (not (window-right-sibling right)))
                       (set! right (window-parent right)))
              (loop)))
          (cond
           ;; "Resize the minibuffer window if it's on the same frame as
           ;; and immediately below WINDOW and it's either active or
           ;; `resize-mini-windows' is nil."
           ((and (not right) (not horizontal)
                 (eq? (window-frame minibuffer-window) frame)
                 (= (nth 1 (window-pixel-edges minibuffer-window))
                    (nth 3 (window-pixel-edges window)))
                 (or (not *resize-mini-windows*)
                     (minibuffer-window-active-p minibuffer-window)))
            (window--resize-mini-window minibuffer-window (- delta)))
           ;; **`set!` is not `setq`.** Elisp's `(not (setq left right))`
           ;; is true when RIGHT was nil; a Scheme `set!` answers the
           ;; *unspecified* value, which is true, so written that way the
           ;; test was never true and a nil LEFT went on to
           ;; `window-min-size` - "Wrong type argument ... #f", or from a
           ;; drag a window with no right sibling raising where Emacs says
           ;; "No window on the right of this one".
           ((let ((l right))
              (set! left l)
              (or (not l)
                  (let ((r (window-right-sibling l)))
                    (set! right r)
                    (not r))))
            (if horizontal
                (user-error "No window on the right of this one")
                (user-error "No window below this one")))
           (else
            ;; "Set LEFT to the first resizable window on the left. This
            ;; step is needed to handle fixed-size windows."
            (set! first-left left)
            (let loop ()
              (when (and left
                         (or (window-size-fixed-p left horizontal)
                             (and (< delta 0)
                                  (<= (window-size left horizontal #t)
                                      (window-min-size left horizontal #f #t)))))
                (set! left
                      (or (window-left-sibling left)
                          (begin
                            (let up ()
                              (when (and (set! left (window-parent left))
                                         (not (window-combined-p left horizontal)))
                                (up)))
                            (window-left-sibling left))))
                (loop)))
            (unless left
              ;; "We have to resize a size-preserved window. Start again
              ;; with the window initially on the left."
              (set! ignore 'preserved)
              (set! left first-left)
              (let loop ()
                (when (and left
                           (or (window-size-fixed-p left horizontal 'preserved)
                               (and (< delta 0)
                                    (<= (window-size left horizontal #t)
                                        (window-min-size left horizontal 'preserved #t)))))
                  (set! left
                        (or (window-left-sibling left)
                            (begin
                              (let up ()
                                (when (and (set! left (window-parent left))
                                           (not (window-combined-p left horizontal)))
                                  (up)))
                              (window-left-sibling left))))
                  (loop)))
              (unless left
                (if horizontal
                    (user-error "No resizable window on the left of this one")
                    (user-error "No resizable window above this one"))))
            ;; "Set RIGHT to the first resizable window on the right."
            (set! first-right right)
            (let loop ()
              (when (and right
                         (or (window-size-fixed-p right horizontal)
                             (and (> delta 0)
                                  (<= (window-size right horizontal #t)
                                      (window-min-size right horizontal 'preserved #t)))))
                (set! right
                      (or (window-right-sibling right)
                          (begin
                            (let up ()
                              (when (and (set! right (window-parent right))
                                         (not (window-combined-p right horizontal)))
                                (up)))
                            (window-right-sibling right))))
                (loop)))
            (unless right
              (set! ignore 'preserved)
              (set! right first-right)
              (let loop ()
                (when (and right
                           (or (window-size-fixed-p right horizontal 'preserved)
                               (and (> delta 0)
                                    (<= (window-size right horizontal #t)
                                        (window-min-size right horizontal 'preserved #t)))))
                  (set! right
                        (or (window-right-sibling right)
                            (begin
                              (let up ()
                                (when (and (set! right (window-parent right))
                                           (not (window-combined-p right horizontal)))
                                  (up)))
                              (window-right-sibling right))))
                  (loop)))
              (unless right
                (if horizontal
                    (user-error "No resizable window on the right of this one")
                    (user-error "No resizable window below this one"))))
            ;; LEFT and RIGHT (which might be both internal windows) are
            ;; now the two windows we want to resize.
            (cond
             ((> delta 0)
              (set! max-delta
                    (window--max-delta-1 left 0 horizontal ignore 'after #f pixelwise))
              (set! min-delta
                    (window--min-delta-1 right (- delta) horizontal ignore 'before #f pixelwise))
              (when (or (< max-delta delta) (> min-delta (- delta)))
                ;; "We can't get the whole DELTA - move as far as possible."
                (set! delta (min max-delta (- min-delta))))
              (unless (= delta 0)
                (window--resize-reset frame horizontal)
                ;; "Try to enlarge LEFT first."
                (set! this-delta
                      (window--resizable left delta horizontal ignore 'after #f #f pixelwise))
                (unless (= this-delta 0)
                  (window--resize-this-window
                   left this-delta horizontal ignore #t 'before
                   (if horizontal
                       (+ (window-pixel-left left) (window-pixel-width left))
                       (+ (window-pixel-top left) (window-pixel-height left)))))
                ;; "Shrink windows on right of LEFT."
                (window--resize-siblings
                 left delta horizontal ignore 'after
                 (if horizontal
                     (window-pixel-left right)
                     (window-pixel-top right)))))
             ((< delta 0)
              (set! max-delta
                    (window--max-delta-1 right 0 horizontal ignore 'before #f pixelwise))
              (set! min-delta
                    (window--min-delta-1 left delta horizontal ignore 'after #f pixelwise))
              (when (or (< max-delta (- delta)) (> min-delta delta))
                (set! delta (max (- max-delta) min-delta)))
              (unless (= delta 0)
                (window--resize-reset frame horizontal)
                ;; "Try to enlarge RIGHT."
                (set! this-delta
                      (window--resizable right (- delta) horizontal ignore 'before #f #f pixelwise))
                (unless (= this-delta 0)
                  (window--resize-this-window
                   right this-delta horizontal ignore #t 'after
                   (if horizontal
                       (window-pixel-left right)
                       (window-pixel-top right))))
                ;; "Shrink windows on left of RIGHT."
                (window--resize-siblings
                 right (- delta) horizontal ignore 'before
                 (if horizontal
                     (+ (window-pixel-left left) (window-pixel-width left))
                     (+ (window-pixel-top left) (window-pixel-height left)))))))
            (unless (= delta 0)
              ;; "Don't report an error in the standard case."
              (when (window--resize-apply-p frame horizontal)
                (if (window-resize-apply frame horizontal)
                    (window--pixel-to-total frame horizontal)
                    ;; "But do report an error if applying the changes
                    ;; fails."
                    (error "Failed adjusting window ~a" window)))))))))

    (define (window-full-height-p . args)
      ;; GNU Emacs's `window-full-height-p` (`window.el:2104`).
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0))))
        (if (window-minibuffer-p window)
            (eq? window (frame-root-window (window-frame window)))
            (= (window-pixel-height window)
               (window-pixel-height (frame-root-window (window-frame window)))))))

    (define (window-at-side-p . args)
      ;; GNU Emacs's `window-at-side-p` (`window.el:2276`): "Return t if
      ;; WINDOW is at SIDE of its containing frame. ... SIDE can be any
      ;; of the symbols `left', `top', `right' or `bottom'. The default
      ;; value nil is handled like `bottom'."
      ;;--------------------------------------------------------------
      (let* ((window (window-normalize-window (window--opt args 0)))
             (side (window--opt args 1))
             (edge (cond ((eq? side 'left) 0)
                         ((eq? side 'top) 1)
                         ((eq? side 'right) 2)
                         (else 3))))
        (= (nth edge (window-pixel-edges window))
           (nth edge (window-pixel-edges (frame-root-window (window-frame window)))))))

    (define (one-window-p . args)
      ;; GNU Emacs's `one-window-p` (`window.el:4145`): "Return non-nil
      ;; if the selected window is the only window. Optional arg NOMINI
      ;; non-nil means don't count the minibuffer even if it is active.
      ;; Otherwise, the minibuffer is counted when it is active."
      ;;
      ;; **Departure**: Emacs answers by comparing `next-window` with the
      ;; selected window; `next-window` is not carried (C-x o is
      ;; `other-window`'s own walk), so this counts the windows the same
      ;; rules select. ALL-FRAMES's `visible`/0 cases are all live frames
      ;; here - nothing iconifies.
      ;;--------------------------------------------------------------
      (let* ((nomini (window--opt args 0))
             (all-frames (window--opt args 1))
             (minibuf (if nomini 'never #f))
             (frames (cond ((eq? all-frames #t) (*frame-list*))
                           ((eq? all-frames 'visible) (*frame-list*))
                           ((eq? all-frames 0) (*frame-list*))
                           ((frame? all-frames) (list all-frames))
                           (else (list (*current-frame*)))))
             (count 0))
        (for-each
         (lambda (frame)
           (when (frame-live-p frame)
             (set! count (+ count (length (window-list frame minibuf))))))
         frames)
        (= count 1)))

    (define (window-right-sibling window)
      ;; GNU Emacs's `window-right` (`window.el:308`): "Return WINDOW's
      ;; right sibling. Return nil if WINDOW is the root window of its
      ;; frame." Emacs calls this `window-right`; this tree already
      ;; spells `window-left` for the *column* of a window's left edge
      ;; (Emacs's `window-left-column`), so the pair cannot take Emacs's
      ;; names here.
      ;;--------------------------------------------------------------
      (and window (window-parent window) (window-next-sibling window)))

    (define (window-left-sibling window)
      ;; GNU Emacs's `window-left` (`window.el:314`) - see the note above.
      ;;--------------------------------------------------------------
      (and window (window-parent window) (window-prev-sibling window)))

    (define (split-window-no-error window size side . args)
      ;; GNU Emacs's `split-window-no-error` (`window.el:5992`): "This
      ;; function is like `split-window' but does not signal an error when
      ;; WINDOW cannot be split." SIDE is Emacs's `below`/`right`; the
      ;; tree's `split-window` takes the boolean HORIZONTAL instead.
      ;;--------------------------------------------------------------
      (guard (e (#t #f))
        (split-window (window-normalize-window window) size
                      side (window--opt args 0))))

    (define (window-deletable-p . args)
      ;; GNU Emacs's `window-deletable-p` (`window.el:4199`): "Return t if
      ;; WINDOW can be safely deleted from its frame."
      ;;
      ;; Not carried: the tab branch (`'tab` - closing the window's tab
      ;; instead of the window; this tree's tab bar closes windows the
      ;; other way round), the atomic-window branch (`window-atom` -
      ;; there are no atomic windows here), and `window-deletable-functions`
      ;; - nothing in this tree runs that hook.
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0))))
        (cond
         ((frame-root-window-p window)
          ;; "WINDOW's frame can be deleted only if there are other
          ;; frames on the same terminal."
          (if (frame-deletable-p (window-frame window)) 'frame #f))
         ((window-minibuffer-p window)
          ;; "If WINDOW is the minibuffer window of a non-minibuffer-only
          ;; frame, it cannot be deleted separately."
          #f)
         (else #t))))

    (define (frame-deletable-p . args)
      ;; GNU Emacs's `frame-deletable-p` (`frame.el:195`), reduced: a
      ;; frame here can be deleted when it is not the last one. Emacs
      ;; also refuses a frame that hosts the active minibuffer and one
      ;; whose terminal has no other frame; there is one minibuffer per
      ;; frame here and no terminal objects.
      ;;--------------------------------------------------------------
      (or (window--opt args 0) (selected-frame))
      (> (length (frame-list)) 1))

    (define (walk-window-tree-1 fun window any . args)
      ;; GNU Emacs's `walk-window-tree-1` (`window.el:586`): "Helper
      ;; function for `walk-window-tree` and `walk-window-subtree`" - a
      ;; pre-order, depth-first walk of the siblings starting at WINDOW,
      ;; descending into the children of an internal window. SUB-ONLY
      ;; walks only the subtree rooted at WINDOW, not its siblings.
      ;;--------------------------------------------------------------
      (let ((sub-only (window--opt args 0)))
        (let loop ((w window))
          (when w
            (let ((buffer (window-buffer w)))
              (when (or buffer any) (fun w))
              (unless buffer
                (walk-window-tree-1 fun (window-left-child w) any)
                (walk-window-tree-1 fun (window-top-child w) any))
              (unless sub-only
                (loop (window-next-sibling w))))))))

    (define (walk-window-tree fun . args)
      ;; GNU Emacs's `walk-window-tree` (`window.el:614`): "Run function
      ;; FUN on each live window of FRAME" - with ANY, on all live and
      ;; internal windows - and with MINIBUF deciding about the
      ;; minibuffer window exactly as `window-list`'s argument does: t
      ;; means always, nil means only while it is active, and neither
      ;; means never.
      ;;--------------------------------------------------------------
      (let* ((frame (or (window--opt args 0) (selected-frame)))
             (any (window--opt args 1))
             (minibuf (window--opt args 2))
             (root (frame-root-window frame))
             (mini (frame-minibuffer-window frame)))
        (unless (eq? root mini)
          (walk-window-tree-1 fun root any))
        (when (and (window-live-p mini)
                   (eq? (window-frame mini) frame)
                   (or (eq? minibuf #t)
                       (and (not minibuf) (minibuffer-window-active-p mini))))
          (fun mini))))

    (define (window-child-count window)
      ;; GNU Emacs's `window-child-count` (`window.el:325`): "Return
      ;; number of WINDOW's child windows."
      ;;--------------------------------------------------------------
      (let ((count 0)
            (w (and (window-type? window) (window-child window))))
        (let loop ((w w))
          (when w
            (set! count (+ count 1))
            (loop (window-next-sibling w))))
        count))

    (define (window-main-window . args)
      ;; GNU Emacs's `window-main-window` (`window.el:914`): "Return the
      ;; main window of specified FRAME. If FRAME has no side windows,
      ;; return FRAME's root window. Otherwise, return either an internal
      ;; non-side window such that all other non-side windows on FRAME
      ;; descend from it, or the single live non-side window of FRAME."
      ;;
      ;; There are no side windows in this tree - `window-side` is a
      ;; window parameter nothing sets - so the walk never finds a main
      ;; window and the answer is the root. The walk is ported as it
      ;; stands because the parameter machinery is here and a side
      ;; window, if one ever comes, is what would make it matter.
      ;;--------------------------------------------------------------
      (let ((frame (or (window--opt args 0) (selected-frame)))
            (main #f))
        (walk-window-tree
         (lambda (window)
           (when (and (not (window-parameter window 'window-side))
                      (or (let ((sibling (window-prev-sibling window)))
                            (and sibling
                                 (window-parameter sibling 'window-side)))
                          (let ((sibling (window-next-sibling window)))
                            (and sibling
                                 (window-parameter sibling 'window-side)))))
             (set! main window)))
         frame #t 'nomini)
        (or main (frame-root-window frame))))

    (define (walk-window-subtree fun . args)
      ;; GNU Emacs's `walk-window-subtree` (`window.el:632`): "Run
      ;; function FUN on the subtree of windows rooted at WINDOW", live
      ;; windows only unless ANY.
      ;;
      ;; It is `walk-window-tree-1` with SUB-ONLY, which is how Emacs
      ;; spells it too - the sub-only walk also applies FUN to the root
      ;; when it is internal and ANY is set, which is what the C's
      ;; `(when (or buffer any) ...)` does.
      ;;--------------------------------------------------------------
      (let ((window (window-normalize-window (window--opt args 0)))
            (any (window--opt args 1)))
        (walk-window-tree-1 fun window any #t)))

    (define (window--check . args)
      ;; GNU Emacs's `window--check` (`window.el:1390`) checks side and
      ;; atomic windows; this tree has neither, so there is nothing to
      ;; check. It is here because `window-state-put` ends with it.
      ;;--------------------------------------------------------------
      #t)

    ;;------------------------------------------------------------------
    ;; Window states - `window.el:6370`
    ;;
    ;; A window state is the layout of a frame's windows as plain data:
    ;; the tree's shape, each window's size in pixels and as a fraction
    ;; of its parent, and the buffer, point and start it was showing.
    ;; `window-state-get` records one and `window-state-put` restores it
    ;; - into the same frame or into another - which is what a tab in
    ;; `tab-bar.el` stores and what a desktop file would.
    ;;------------------------------------------------------------------

    (define (window--state-ref key list)
      ;; `(cdr (assq KEY LIST))` with Elisp's nil: `#f` when the entry is
      ;; missing, where `(cdr #f)` would raise.
      ;;--------------------------------------------------------------
      (let ((entry (window--state-assq key list)))
        (and entry (cdr entry))))

    (define (window--state-assq key list)
      ;; Emacs's `(assq KEY LIST)` as it behaves on a window state or a
      ;; node of one. A node is its type symbol consed onto its alist, so
      ;; the entries sit one cons deeper than a plain alist's and the C's
      ;; `Fassq` - which compares `XCAR (XCAR (tail))` - reaches them;
      ;; Scheme's `assq` would instead try `(car 'leaf)`. The pair test
      ;; here is what the C's `XCAR` of a non-cons silently answers nil
      ;; for.
      ;;--------------------------------------------------------------
      (let loop ((tail list))
        (cond ((not (pair? tail)) #f)
              ((and (pair? (car tail)) (eq? (car (car tail)) key)) (car tail))
              (else (loop (cdr tail))))))

    (define (window--state-normalize-buffer-name buffer)
      ;; GNU Emacs's `window--state-normalize-buffer-name`
      ;; (`window.el:6370`): a buffer's name, which is what a state
      ;; written to a file can record - a buffer object does not survive
      ;; the write.
      ;;--------------------------------------------------------------
      (if (string? buffer) buffer (buffer-name buffer)))

    (define (window--state-get-1 window writable)
      ;; GNU Emacs's `window--state-get-1` (`window.el:6381`): the
      ;; subtree at WINDOW as the type symbol followed by the alist of
      ;; what is recorded, and then the states of the children when
      ;; WINDOW is internal.
      ;;
      ;; WRITABLE non-nil means the state must survive a round trip
      ;; through a file: point and start are recorded as positions rather
      ;; than markers, and only the parameters declared `writable` are
      ;; kept.
      ;;--------------------------------------------------------------
      (let* ((type (cond ((window-top-child window) 'vc)
                         ((window-left-child window) 'hc)
                         (else 'leaf)))
             (buffer (window-buffer window))
             (selected (eq? window (selected-window)))
             (next-buffers
              (if (window-live-p window)
                  (delq #f (map (lambda (buffer)
                                  (and (buffer-live-p buffer) buffer))
                                (window-next-buffers window)))
                  '()))
             (prev-buffers
              (if (window-live-p window)
                  (delq #f (map (lambda (entry)
                                  (and (buffer-live-p (car entry)) entry))
                                (window-prev-buffers window)))
                  '()))
             (head
              (append
               (list type)
               (if (window-next-sibling window) '() (list (cons 'last #t)))
               (list (cons 'pixel-width (window-pixel-width window))
                     (cons 'pixel-height (window-pixel-height window))
                     (cons 'total-width (window-total-width window))
                     (cons 'total-height (window-total-height window))
                     (cons 'normal-height (window-normal-size window #f))
                     (cons 'normal-width (window-normal-size window #t)))
               (if (window-live-p window)
                   '()
                   (list (cons 'combination-limit (window-combination-limit window))))
               ;; **The accumulator is `acc`, not `list`**: Emacs's
               ;; `let` binds a variable named `list` and builds its
               ;; answer with a backquote, but here `list` is the
               ;; procedure, and a variable of that name shadows it -
               ;; `(list (cons 'parameters list))` would then apply the
               ;; accumulator. (It did, as soon as a window carried any
               ;; parameter at all.)
               (let ((parameters (window-parameters window))
                     (acc '()))
                 ;; "Make copies of those window parameters whose
                 ;; persistence property is `writable' if WRITABLE is
                 ;; non-nil and non-nil if WRITABLE is nil."
                 (for-each
                  (lambda (par)
                    ;; `(cdr (assq ...))` on a miss is nil in Elisp; the
                    ;; empty list here has to be spelled out.
                    (let ((entry (assq (car par) (*window-persistent-parameters*))))
                      (let ((pers (and entry (cdr entry))))
                        (when (and pers (or (not writable) (eq? pers 'writable)))
                          (set! acc (cons (cons (car par) (cdr par)) acc))))))
                  parameters)
                 ;; "Add `clone-of` parameter if necessary."
                 (let ((entry (assq 'clone-of (*window-persistent-parameters*))))
                   (let ((pers (and entry (cdr entry))))
                     (when (and pers (or (not writable) (eq? pers 'writable))
                                (not (assq 'clone-of acc)))
                       (set! acc (cons (cons 'clone-of window) acc)))))
                 (if (pair? acc) (list (cons 'parameters acc)) '()))
               (if buffer
                   ;; "All buffer related things go in here."
                   (let ((point (window-point window))
                         (start (window-start window)))
                     (list
                      (cons 'buffer
                            (cons (if writable
                                      (window--state-normalize-buffer-name buffer)
                                      buffer)
                                  (list
                                   (cons 'selected selected)
                                   (cons 'hscroll (window-hscroll window))
                                   (cons 'fringes (window-fringes window))
                                   (cons 'margins (window-margins window))
                                   (cons 'scroll-bars (window-scroll-bars window))
                                   (cons 'vscroll (window-vscroll window))
                                   (cons 'dedicated (window-dedicated-p window))
                                   (cons 'point
                                         (if writable
                                             point
                                             (with-current-buffer buffer
                                               (copy-marker point))))
                                   (cons 'start
                                         (if writable
                                             start
                                             (with-current-buffer buffer
                                               (copy-marker start)))))))))
                   '())
               (if (pair? next-buffers)
                   (list (cons 'next-buffers
                               (if writable
                                   (map window--state-normalize-buffer-name next-buffers)
                                   next-buffers)))
                   '())
               (if (pair? prev-buffers)
                   (list (cons 'prev-buffers
                               (if writable
                                   (map (lambda (entry)
                                          (list (window--state-normalize-buffer-name (car entry))
                                                (marker-position (cadr entry))
                                                (marker-position (list-ref entry 2))))
                                        prev-buffers)
                                   prev-buffers)))
                   '())))
             (tail
              (if (memq type '(vc hc))
                  (let loop ((window (window-child window)) (list '()))
                    (cond ((not window) (reverse list))
                          (else (loop (window-next-sibling window)
                                      (cons (window--state-get-1 window writable) list)))))
                  '())))
        (append head tail)))

    (define (window-state-get . args)
      ;; GNU Emacs's `window-state-get` (`window.el:6461`): "Return state
      ;; of WINDOW as a Lisp object." The car is the constraints on the
      ;; size of WINDOW - the minimum sizes the state can be restored at
      ;; under each IGNORE - and the cdr is the subtree.
      ;;
      ;; **Markers and buffers, not positions and names**: WRITABLE is
      ;; nil by default, and a state that stays in memory can name the
      ;; buffer object itself and mark its point with markers, so an edit
      ;; between the save and the restore moves the point with the text.
      ;;--------------------------------------------------------------
      (let ((window (or (window--opt args 0) (frame-root-window)))
            (writable (window--opt args 1)))
        (unless (window-valid-p window)
          (error "~a is not a live or internal window" window))
        (cons
         (list (cons 'min-height (window-min-size window))
               (cons 'min-width (window-min-size window #t))
               (cons 'min-height-ignore (window-min-size window #f #t))
               (cons 'min-width-ignore (window-min-size window #t #t))
               (cons 'min-height-safe (window-min-size window #f 'safe))
               (cons 'min-width-safe (window-min-size window #t 'safe))
               (cons 'min-pixel-height (window-min-size window #f #f #t))
               (cons 'min-pixel-width (window-min-size window #t #f #t))
               (cons 'min-pixel-height-ignore (window-min-size window #f #t #t))
               (cons 'min-pixel-width-ignore (window-min-size window #t #t #t))
               (cons 'min-pixel-height-safe (window-min-size window #f 'safe #t))
               (cons 'min-pixel-width-safe (window-min-size window #t 'safe #t)))
         (window--state-get-1 window writable))))

    (define window-state-put-list '())
    (define window-state-put-stale-windows '())
    (define window-state-put-kept-windows '())
    (define window-state-put-selected-window #f)
    ;; ^ GNU Emacs's four `defvar`s (`window.el:6449`), which
    ;; `window-state-put` and its two helpers pass state through. Read
    ;; and `set!`-ed, never `let`-bound, so plain variables.

    (define (window--state-put-1 state window ignore totals pixelwise)
      ;; GNU Emacs's `window--state-put-1` (`window.el:6534`): rebuild
      ;; the tree under WINDOW from STATE, splitting for every child but
      ;; the last.
      ;;
      ;; **"Make sure to make a new parent window for a horizontal or
      ;; vertical combination embedded in one of the same type"**
      ;; (`window.el:6552`, Bug#50867 and Bug#64405): the state records
      ;; the combination the node belongs to, and a node whose children
      ;; would otherwise be flattened into its own parent by
      ;; `split-window`'s sibling rule gets a parent of its own.
      ;;--------------------------------------------------------------
      (let ((type (car state)))
        (set! state (cdr state))
        (cond
         ((eq? type 'leaf)
          ;; "For a leaf window just add unprocessed entries to
          ;; `window-state-put-list'."
          (set! window-state-put-list (cons (cons window state) window-state-put-list)))
         ((memq type '(vc hc))
          (let* ((horizontal (eq? type 'hc))
                 (total (window-size window horizontal pixelwise))
                 (first #t)
                 (window-combination-limit
                  (and (or (eq? (window--state-ref 'combination-limit state) #t)
                           (and horizontal (window-combined-p window #t))
                           (and (not horizontal) (window-combined-p window)))
                       #t))
                 (new #f))
            (parameterize ((*window-combination-limit* window-combination-limit))
            (for-each
             (lambda (item)
               ;; "Find the next child window. WINDOW always points to the
               ;; real window that we want to fill with what we find here."
               (when (memq (car item) '(leaf vc hc))
                 (if (window--state-assq 'last item)
                     ;; "The last child window."
                     (set! new #f)
                     ;; "Not the last child window, prepare for splitting
                     ;; WINDOW. SIZE is the new (and final) size of the old
                     ;; window."
                     (let ((size
                            (if totals
                                ;; "Use total size."
                                (cdr (window--state-assq
                                      (if horizontal 'pixel-width 'pixel-height)
                                      item))
                                ;; "Use normalized size and round."
                                (inexact->exact
                                 (round (* total
                                           (cdr (window--state-assq
                                                 (if horizontal 'normal-width 'normal-height)
                                                 item))))))))
                       ;; "Use safe sizes, we try to resize later."
                       (set! size
                             (max size
                                  (if horizontal
                                      (* window-safe-min-width
                                         (if pixelwise
                                             (frame-char-width (window-frame window))
                                             1))
                                      (* window-safe-min-height
                                         (if pixelwise
                                             (frame-char-height (window-frame window))
                                             1)))))
                       (if (window-sizable-p window (- size) horizontal 'safe pixelwise)
                           (begin
                             (set! new (split-window-no-error window size horizontal pixelwise)))
                           ;; "Give up if we can't resize window down to
                           ;; safe sizes."
                           (error "Cannot resize window ~a" window))
                       (when first
                         (set! first #f)
                         ;; "When creating the first child window add for
                         ;; parent unprocessed entries to
                         ;; `window-state-put-list'."
                         (set! window-state-put-list
                               (cons (cons (window-parent window) state)
                                     window-state-put-list)))))
                 ;; "Now process the current window (either the one we've
                 ;; just split or the last child of its parent)."
                 (window--state-put-1 item window ignore totals pixelwise)
                 ;; "Continue with the last window split off."
                 (set! window new)))
             state)))))))

    (define (window--state-put-2 ignore pixelwise)
      ;; GNU Emacs's `window--state-put-2` (`window.el:6591`): give every
      ;; window its parameters, its buffer and its sizes.
      ;;--------------------------------------------------------------
      (for-each
       (lambda (item)
         (let* ((window (car item))
                (combination-limit (window--state-ref 'combination-limit item))
                (parameters (window--state-ref 'parameters item))
                (state (window--state-ref 'buffer item))
                (next-buffers (window--state-ref 'next-buffers item))
                (prev-buffers (window--state-ref 'prev-buffers item)))
           (when combination-limit
             (set-window-combination-limit window combination-limit))
           ;; "Reset window's parameters and assign saved ones."
           (for-each
            (lambda (parameter)
              (set-window-parameter window (car parameter) #f))
            (window-parameters window))
           (when parameters
             (for-each
              (lambda (parameter)
                (set-window-parameter window (car parameter) (cdr parameter)))
              parameters))
           ;; "Process buffer related state."
           (when state
             (let* ((old-buffer-or-name (car state))
                    (buffer (get-buffer old-buffer-or-name))
                    (state (cdr state))
                    (dedicated (window--state-ref 'dedicated state)))
               (if (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (set-window-buffer! window buffer)
                     (set-window-hscroll! window (window--state-ref 'hscroll state))
                     (let ((fringes (window--state-ref 'fringes state)))
                       (set-window-fringes window (car fringes) (cadr fringes)))
                     (let ((margins (window--state-ref 'margins state)))
                       (set-window-margins window (car margins) (cdr margins)))
                     (let ((scroll-bars (window--state-ref 'scroll-bars state)))
                       (set-window-scroll-bars
                        window (car scroll-bars) (list-ref scroll-bars 2)
                        (list-ref scroll-bars 3) (list-ref scroll-bars 5)
                        (list-ref scroll-bars 6)))
                     (set-window-vscroll window (window--state-ref 'vscroll state))
                     ;; "Adjust vertically."
                     (if (or (memq (buffer-local-value buffer 'window-size-fixed #f)
                                   '(t height))
                             (window-preserved-size window))
                         ;; "A fixed height window, try to restore the
                         ;; original size."
                         (let ((delta (- (cdr (window--state-assq
                                               (if pixelwise 'pixel-height 'total-height)
                                               item))
                                         (window-size window #f pixelwise))))
                           (when (window--resizable-p window delta #f #f #f #f #f pixelwise)
                             (window-resize window delta #f #f pixelwise)))
                         ;; "Else check whether the window is not high enough."
                         (let* ((min-size (window-min-size window #f ignore pixelwise))
                                (delta (- min-size (window-size window #f pixelwise))))
                           (when (and (> delta 0)
                                      (window--resizable-p window delta #f ignore #f #f #f pixelwise))
                             (window-resize window delta #f ignore pixelwise))))
                     ;; "Adjust horizontally."
                     (if (or (memq (buffer-local-value buffer 'window-size-fixed #f)
                                   '(t width))
                             (window-preserved-size window #t))
                         (let ((delta (- (cdr (window--state-assq
                                               (if pixelwise 'pixel-width 'total-width)
                                               item))
                                         (window-size window #t pixelwise))))
                           (when (window--resizable-p window delta #t #f #f #f #f pixelwise)
                             (window-resize window delta #t #f pixelwise)))
                         (let* ((min-size (window-min-size window #t ignore pixelwise))
                                (delta (- min-size (window-size window #t pixelwise))))
                           (when (and (> delta 0)
                                      (window--resizable-p window delta #t ignore #f #f #f pixelwise))
                             (window-resize window delta #t ignore pixelwise))))
                     ;; "Set dedicated status."
                     (set-window-dedicated-p window dedicated)
                     ;; "Install positions (maybe we should do this after
                     ;; all windows have been created and sized)."
                     (guard (e (#t #f))
                       (set-window-start! window
                                          (let ((start (window--state-ref 'start state)))
                                            (if (markerp start) (marker-position start) start)))
                       (set-window-point! window
                                          (let ((point (window--state-ref 'point state)))
                                            (if (markerp point) (marker-position point) point))))
                     ;; "Select window if it's the selected one.")
                     (when (window--state-ref 'selected state)
                       (select-window window)
                       (set! window-state-put-selected-window window))
                     (set-window-next-buffers
                      window
                      (delq #f (map (lambda (buffer)
                                      (set! buffer (get-buffer buffer))
                                      (and (buffer-live-p buffer) buffer))
                                    (or next-buffers '()))))
                     (set-window-prev-buffers
                      window
                      (delq #f (map (lambda (entry)
                                      (let ((buffer (get-buffer (list-ref entry 0)))
                                            (m1 (list-ref entry 1))
                                            (m2 (list-ref entry 2)))
                                        (and (buffer-live-p buffer)
                                             (list buffer
                                                   (if (markerp m1) m1
                                                       (set-marker (make-marker) m1 buffer))
                                                   (if (markerp m2) m2
                                                       (set-marker (make-marker) m2 buffer))))))
                                    (or prev-buffers '())))))
                   (unless (window-minibuffer-p window)
                     ;; "Preferably show a buffer previously shown in this
                     ;; window."
                     (switch-to-prev-buffer window)
                     (cond
                      ((procedure? (*window-restore-killed-buffer-windows*))
                       (let* ((start (window--state-ref 'start state))
                              (start-pos (if (markerp start) (marker-last-position start) start))
                              (point (window--state-ref 'point state))
                              (point-pos (if (markerp point) (marker-last-position point) point)))
                         (set! window-state-put-kept-windows
                               (cons (list window old-buffer-or-name
                                           start-pos point-pos dedicated #f)
                                     window-state-put-kept-windows))))
                      ((or (and dedicated
                                (eq? (*window-restore-killed-buffer-windows*) 'dedicated))
                           (memq (*window-restore-killed-buffer-windows*) '(#f delete)))
                       ;; "Try to delete the window."
                       (set! window-state-put-stale-windows
                             (cons window window-state-put-stale-windows)))
                      (else #f))
                     (set-window-dedicated-p window #f)))))))
       window-state-put-list))

    (define (window-state-put state . args)
      ;; GNU Emacs's `window-state-put` (`window.el:6769`): "Put window
      ;; state STATE into WINDOW."
      ;;
      ;; IGNORE non-nil means ignore minimum window sizes and fixed size
      ;; restrictions; IGNORE `safe` means windows may go as small as
      ;; `window-safe-min-*`. `window-restore-killed-buffer-windows`
      ;; decides what happens to a window whose saved buffer was killed.
      ;;--------------------------------------------------------------
      (set! window-state-put-stale-windows '())
      (set! window-state-put-kept-windows '())
      (let ((window (window--opt args 0))
            (ignore (window--opt args 1)))
        ;; "When WINDOW is internal or nil, reduce it to a live one, then
        ;; create a new window on the same frame to put STATE into."
        (unless (window-live-p window)
          (let ((root window))
            (set! window
                  (if root
                      (let walk ((w root))
                        (cond ((not w) (selected-window))
                              ((and (window-live-p w)
                                    (not (window-parameter w 'window-side)))
                               w)
                              (else
                               (or (and (pair? (window-children w)) (walk (window-child w)))
                                   (walk (window-next-sibling w))))))
                      (selected-window)))
            ;; `delete-other-windows-internal`: make WINDOW the frame's
            ;; only window before the new one is made beside it.
            (when (window-live-p window)
              (delete-other-windows window))
            ;; "Create a new window to replace the existing one."
            ;; `(prog1 (split-window window window-safe-min-width t)
            ;;        (delete-window window))`: the OLD window is the one
            ;; deleted, so that the new one is what the state is put
            ;; into.
            (let ((new (guard (e (#t #f))
                         (split-window window window-safe-min-width #t))))
              (when new
                (let ((old window))
                  (set! window new)
                  (delete-window old))))))
        (set-window-dedicated-p window #f)
        (let* ((frame (window-frame window))
               (head (car state))
               ;; "We check here (1) whether the total sizes of root window
               ;; of STATE and that of WINDOW are equal so we can avoid
               ;; calculating new sizes, and (2) if we do have to resize
               ;; whether we can do so without violating size
               ;; restrictions."
               (pixelwise (and (window--state-ref 'pixel-width state)
                               (window--state-ref 'pixel-height state)))
               (totals (or (and pixelwise
                                (= (window-pixel-width window)
                                   (window--state-ref 'pixel-width state))
                                (= (window-pixel-height window)
                                   (window--state-ref 'pixel-height state)))
                           (and (= (window-total-width window)
                                   (window--state-ref 'total-width state))
                                (= (window-total-height window)
                                   (window--state-ref 'total-height state)))))
               (min-height (cdr (assq (if pixelwise 'min-pixel-height 'min-height) head)))
               (min-width (cdr (assq (if pixelwise 'min-pixel-width 'min-width) head))))
          (when (and (not totals)
                     (or (> min-height (window-size window #f pixelwise))
                         (> min-width (window-size window #t pixelwise)))
                     (or (not ignore)
                         (begin
                           (set! min-height
                                 (cdr (assq (if pixelwise
                                                'min-pixel-height-ignore
                                                'min-height-ignore)
                                            head)))
                           (set! min-width
                                 (cdr (assq (if pixelwise
                                                'min-pixel-width-ignore
                                                'min-width-ignore)
                                            head)))
                           (or (> min-height (window-size window #f pixelwise))
                               (> min-width (window-size window #t pixelwise)))
                           (or (not (eq? ignore 'safe))
                               (begin
                                 (set! min-height
                                       (cdr (assq (if pixelwise
                                                      'min-pixel-height-safe
                                                      'min-height-safe)
                                                  head)))
                                 (set! min-width
                                       (cdr (assq (if pixelwise
                                                      'min-pixel-width-safe
                                                      'min-width-safe)
                                                  head)))
                                 (or (> min-height (window-size window #f pixelwise))
                                     (> min-width (window-size window #t pixelwise))))))))
            (error "Window ~a too small to accommodate state" window))
          (set! state (cdr state))
          (set! window-state-put-list '())
          (set! window-state-put-selected-window #f)
          ;; "Work on the windows of a temporary buffer to make sure that
          ;; splitting proceeds regardless of any buffer local values of
          ;; `window-size-fixed`."
          (with-temp-buffer
            (set-window-buffer! window (current-buffer))
            (window--state-put-1 state window #f totals pixelwise)
            (window--state-put-2 ignore pixelwise))

          (when (window-live-p window-state-put-selected-window)
            (select-window window-state-put-selected-window))
          (let loop ((stale window-state-put-stale-windows))
            (when (pair? stale)
              (let ((window (car stale)))
                ;; "Avoid that `window-deletable-p' throws an error if
                ;; window was already deleted when exiting
                ;; `with-temp-buffer' above."
                (when (and (window-valid-p window)
                           (eq? (window-deletable-p window) #t))
                  (delete-window window)))
              (loop (cdr stale))))
          (when (procedure? (*window-restore-killed-buffer-windows*))
            ((*window-restore-killed-buffer-windows*)
             frame window-state-put-kept-windows 'state)
            (set! window-state-put-kept-windows '()))
          (window--check frame))))

    (define (window-state-buffers state)
      ;; GNU Emacs's `window-state-buffers` (`window.el:6900`): "Return
      ;; all buffers saved to the given window state STATE."
      ;;--------------------------------------------------------------
      (let ((buffer (let ((entry (window--state-assq 'buffer state)))
                      (and entry (cadr entry))))
            (buffers (let loop ((items (if (pair? (car state))
                                           (list (cdr state))
                                           (cdr state)))
                                (acc '()))
                       (cond ((null? items) (reverse acc))
                             ((memq (car (car items)) '(leaf vc hc))
                              (loop (cdr items)
                                    (append (reverse (window-state-buffers (car items)))
                                            acc)))
                             (else (loop (cdr items) acc))))))
        (if buffer (cons buffer buffers) buffers)))
    
    ))
