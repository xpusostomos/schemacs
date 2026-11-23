;; Tests for the mode line's clickable items - the part of
;; `bindings.el` this tree ports: `mode-line-modified`,
;; `mode-line-remote`, the EOL mnemonic, `%n` and the buffer
;; identification, each a propertized string whose `local-map`/`keymap`
;; makes it a button and whose `mouse-face` lights it under the pointer.
;;
;; **The clicks go through the real key path.** `dispatch-key` is what
;; the command loop calls for one event, and a mouse event's position is
;; the posn `posn-at-x-y` answers for the drawn mode line - the same
;; answer the front ends hand the loop. Nothing here calls a command
;; directly except where the test is about the command's own effect.
;;
;; Every expected string was measured on GNU Emacs 31.1 in a pty first:
;; the flag characters (`%1*` then `%1+`), the EOL mnemonics, and the
;; `-UUU:` prefix a UTF-8 buffer in a UTF-8 terminal draws.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) setvbuf string-contains hashv-ref)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) make define-class define-method)
 (prefix (only (schemacs test-display) <test-display>) stub:)
 (only (schemacs test-display) test-display-glyphs)
 (only (schemacs dispnew) current-display draw-box!)
 (only (schemacs frame)
       *current-frame* *default-frame-alist* new-frame frame-selected-window
       window-last-mode-line window-top window-height window-buffer
       set-window-buffer! frame-message frame-keymap-state selected-window)
 (only (schemacs window) split-window)
 (only (schemacs buffer)
       *current-buffer* allocate-buffer with-current-buffer set-point
       buffer-modified-p buffer-read-only? set-buffer-local-value!
       buffer-local-value set!buffer-read-only set-buffer-modified-p
       buffer-overwrite-mode current-buffer)
 (only (schemacs editfns)
       insert narrow-to-region buffer-narrowed-p point-min goto-char point-max)
 (only (schemacs xdisp)
       render! posn-at-x-y format-mode-line
       mode-line-modified mode-line-remote
       mode-line-read-only-map mode-line-modified-map mode-line-widen-map
       mode-line-change-eol-map mode-line-buffer-identification-map
       mode-line-buffer-identification
       mode-line-remote-help-echo mode-line-read-only-help-echo
       mode-line-modified-help-echo
       mode-line-toggle-read-only mode-line-toggle-modified mode-line-widen
       mode-line-change-eol mode-line-previous-buffer mode-line-next-buffer
       note-mouse-highlight clear-mouse-face! track-mouse
       ;; the mode name's and the lighters' buttons
       string-property-run-at mode-line-major-mode-keymap
       mode-line-minor-mode-keymap mode-line-mode-menu
       bindings--sort-menu-keymap
       mode-line-major-mode-help-echo mode-line-minor-mode-help-echo
       ;; the line/column item and its percentages
       mode-line-column-line-number-mode-map line-column-mode-menu
       percent99
       ;; the coding-system item
       mode-line-coding-system-map mode-line-mule-info-help-echo
       mode-line-coding-system-describe mode-line-coding-system-set
       *describe-coding-system-function*
       *set-buffer-file-coding-system-command*)
 (only (schemacs subr) event-start posn-string posn-area posn-window
       *minor-mode-alist*)
 (only (schemacs textprop) get-text-property)
 (only (schemacs keyboard) *last-read-event* dispatch-key
       *overriding-terminal-local-map*)
 (only (schemacs keymap) lookup-key keymapp keymap-bindings map-keymap
       make-sparse-keymap)
 (only (schemacs files) buffer-file-coding-system)
 ;; The EOL item's command reaches `set-buffer-file-coding-system`
 ;; through a seam this library installs as it loads - a real editor has
 ;; it because a front end imports `mule-cmds`.
 (only (schemacs international mule-cmds))
 ;; The box's edges are face attributes: the test sets them.
 (only (schemacs faces) *frame-background-mode* *display-color-cells*
       face-list face-spec-recalc)
 ;; `mouse.scm` binds `[mode-line down-mouse-1]` and `[mode-line mouse-1]`
 ;; in the global map - the drag handle and `mouse-select-window` - which
 ;; a real editor has and a click on a plain stretch of the mode line
 ;; needs. Its own commands are tested in `mouse-tests`.
 (only (schemacs mouse)
       mouse-menu-major-mode-map minor-mode-menu-from-indicator
       mouse-menu-major-mode-menu mode-line-minor-mode-menu
       mode-line-line-column-menu
       describe-minor-mode-completion-table-for-indicator
       *popup-menu-function* *menu-bar-edit-menu*
       *describe-function-function*)
 ;; The toggles menu's `:button` expression names the buffer's own
 ;; reader, and the generated minor-mode menu's "Turn off" item names
 ;; the command.
 (only (schemacs simple) overwrite-mode
       line-number-mode column-number-mode size-indication-mode
       line-number-mode-variable column-number-mode-variable
       size-indication-mode-variable)
 (only (schemacs fns) equal-including-properties))

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_mode_line")

;; A terminal-shaped stub: one cell per character and one row per line,
;; so a mode-line position is a column. The menu bar is off, as in the
;; other display suites - it would take a row and move the mode line.
(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))
(define-class <box-test-display> (stub:<test-display>)
  ;; Every `draw-box!` call, as `(X CELLS LEFT? RIGHT?)` - the box test
  ;; reads the vertical edges.
  (boxes #:init-value '() #:accessor test-box-calls))

(define-method (draw-box! (d <box-test-display>) box token x y cells height
                          left? right?)
  (set! (test-box-calls d)
        (cons (list x cells left? right?) (test-box-calls d))))

(define display (make <box-test-display> #:column-width 1 #:line-height 1))
(current-display display)

(define (frame-of text)
  (let ((ed (allocate-buffer)))
    ;; Inserting marks a buffer modified; every test below wants a known
    ;; state to start from, so the fixture clears the flag - which is
    ;; `set-buffer-modified-p`'s own job, not a write to a slot.
    (with-current-buffer ed
      (insert text)
      (set-buffer-modified-p #f))
    (set-point ed 1)
    (parameterize ((current-display display))
      (let ((f (new-frame ed 24 80)))
        (parameterize ((*current-frame* f))
          (render! f))
        f))))

(define (window-of f) (frame-selected-window f))
(define (mode-line-row w) (+ (window-top w) (window-height w) -1))

(define (mouse-event f window key x)
  ;; The event the display makes for a click at column X on WINDOW's mode
  ;; line, as `dispatch-key` takes it.
  (let ((posn (posn-at-x-y x (mode-line-row window) f)))
    (*last-read-event* (list key posn))
    posn))

(define (click f window key x)
  (mouse-event f window key x)
  (dispatch-key f key)
  (frame-message f))

(define (column-of line prop) (or (string-contains line prop) #f))

(define (column-with-map line map)
  ;; The first column of LINE whose `local-map` is MAP.
  (let loop ((i 0))
    (cond ((>= i (string-length line)) #f)
          ((eq? (get-text-property i 'local-map line) map) i)
          (else (loop (+ i 1))))))

;;----------------------------------------------------------------
;; The constructs - what `format-mode-line` makes of them
;;----------------------------------------------------------------

(test-begin "schemacs_editor_mode_line_constructs")

(let* ((f (frame-of "abc\n"))
       (w (window-of f)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let ((flags (format-mode-line mode-line-modified w)))
      (test-equal "an unmodified writable buffer draws --"
                  "--" flags)
      (test-assert "the first flag is the read-only item"
                   (eq? (lookup-key (get-text-property 0 'local-map flags)
                                    (vector 'mode-line 'mouse-1))
                        mode-line-toggle-read-only))
      (test-assert "the second flag is the modified item"
                   (eq? (lookup-key (get-text-property 1 'local-map flags)
                                    (vector 'mode-line 'mouse-1))
                        mode-line-toggle-modified))
      (test-assert "both flags carry the highlight face"
                   (and (eq? (get-text-property 0 'mouse-face flags)
                             'mode-line-highlight)
                        (eq? (get-text-property 1 'mouse-face flags)
                             'mode-line-highlight))))))

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (with-current-buffer ed
      (insert "x")
      (set!buffer-read-only ed #t))
    (test-equal "a modified read-only buffer draws %*"
                "%*" (format-mode-line mode-line-modified w))))

(let* ((f (frame-of "abc\n"))
       (w (window-of f)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    ;; Emacs's `mode_line_elt_no`: measured on 31.1, `(format-mode-line
    ;; '("%z" "%1*" "%1+"))` is `#("UUU--" 0 3 (mode-line-elt-no 2) 3 4
    ;; (mode-line-elt-no 3) 4 5 (mode-line-elt-no 4))` - the list itself
    ;; is element 1, and each string its own.
    (let ((s (format-mode-line (list "%z" "%1*" "%1+") w)))
      (test-equal "format-mode-line marks each element with mode-line-elt-no"
                  (list "UUU--" 2 3 4)
                  (list s
                        (get-text-property 0 'mode-line-elt-no s)
                        (get-text-property 3 'mode-line-elt-no s)
                        (get-text-property 4 'mode-line-elt-no s))))
    (test-equal "the remote flag is - for a local directory"
                "-" (format-mode-line mode-line-remote w))
    ;; **The `help-echo` value is the function itself.** `bindings.el`
    ;; stores the symbol `mode-line-remote-help-echo` and Emacs resolves
    ;; it through its obarray; this tree has no function obarray, so the
    ;; property holds the procedure - the same choice a keymap makes when
    ;; it holds a command.
    (test-assert "and it carries the highlight face and a help function"
                 (and (eq? (get-text-property 0 'mouse-face
                                              (format-mode-line mode-line-remote w))
                           'mode-line-highlight)
                      (eq? (get-text-property 0 'help-echo
                                              (format-mode-line mode-line-remote w))
                           mode-line-remote-help-echo)))))

;; The EOL mnemonic and the narrowing indicator are in the assembled mode
;; line, not in a construct of their own: the first is `%z`'s sibling
;; inside `mode-line-mule-info`, the second is the `%n` element of
;; `mode-line-modes`.

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let ((line (car (window-last-mode-line w))))
      (test-equal "a UTF-8 buffer on a terminal starts -UUU:"
                  "-UUU:" (substring line 0 5))
      (test-assert "the EOL mnemonic is a button for `mode-line-change-eol`"
                   (eq? (lookup-key (get-text-property 4 'keymap line)
                                    (vector 'mode-line 'mouse-1))
                        mode-line-change-eol))
      (test-assert "and it carries the highlight face"
                   (eq? (get-text-property 4 'mouse-face line)
                        'mode-line-highlight)))
    (with-current-buffer ed (narrow-to-region 1 2))
    (render! f)
    (let* ((line (car (window-last-mode-line w)))
           (at (string-contains line " Narrow")))
      (test-assert "a narrowed buffer shows Narrow"
                   (and at #t))
      (test-assert "the narrowing indicator widens on mouse-2"
                   (eq? (lookup-key (get-text-property at 'local-map line)
                                    (vector 'mode-line 'mouse-2))
                        mode-line-widen)))))

(let* ((f (frame-of "abc\n"))
       (w (window-of f)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let* ((ident (format-mode-line mode-line-buffer-identification w))
           (map (get-text-property 0 'local-map ident)))
      (test-equal "the buffer name is in a twelve-wide field, padded right"
                  "Untitled    " ident)
      (test-assert "mouse-1 on the name is the previous buffer"
                   (eq? (lookup-key map (vector 'mode-line 'mouse-1))
                        mode-line-previous-buffer))
      (test-assert "mouse-3 on the name is the next buffer"
                   (eq? (lookup-key map (vector 'mode-line 'mouse-3))
                        mode-line-next-buffer))
      (test-assert "the name keeps its face and gains the highlight"
                   (and (eq? (get-text-property 0 'face ident)
                             'mode-line-buffer-id)
                        (eq? (get-text-property 0 'mouse-face ident)
                             'mode-line-highlight))))))

(test-end "schemacs_editor_mode_line_constructs")

;;----------------------------------------------------------------
;; The commands, through the real dispatch
;;----------------------------------------------------------------

(test-begin "schemacs_editor_mode_line_commands")

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (ed (window-buffer w))
       (line (car (window-last-mode-line w))))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (test-equal "clicking the first flag toggles read-only"
                #t
                (begin (click f w 'mouse-1
                              (column-with-map line mode-line-read-only-map))
                       (buffer-read-only? ed)))
    (test-equal "and clicking it again turns read-only off"
                #f
                (begin (click f w 'mouse-1
                              (column-with-map line mode-line-read-only-map))
                       (buffer-read-only? ed)))
    (test-equal "clicking the second flag sets the modified bit"
                #t
                (begin (click f w 'mouse-1
                              (column-with-map line mode-line-modified-map))
                       (buffer-modified-p ed)))
    (test-equal "and clicking it again clears it"
                #f
                (begin (click f w 'mouse-1
                              (column-with-map line mode-line-modified-map))
                       (buffer-modified-p ed)))))

(let* ((f (frame-of "line one\nline two\nline three\n"))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (with-current-buffer ed (narrow-to-region 6 14))
    (render! f)
    (let* ((line (car (window-last-mode-line w)))
           (at (string-contains line " Narrow")))
      (click f w 'mouse-2 at)
      (test-equal "a mouse-2 click on Narrow widens the clicked buffer"
                  #f (buffer-narrowed-p))
      (test-equal "and it is the buffer the click reached"
                  1 (point-min)))))

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (set-buffer-local-value! ed 'buffer-file-coding-system 'utf-8-unix)
    (click f w 'mouse-1 4)
    (test-equal "clicking the EOL mnemonic cycles unix to dos"
                'utf-8-dos (buffer-file-coding-system ed))
    (render! f)
    (test-equal "the mode line shows the DOS mnemonic afterwards"
                "(DOS)" (substring (car (window-last-mode-line w)) 4 9))
    (click f w 'mouse-1 4)
    (test-equal "and dos to mac"
                'utf-8-mac (buffer-file-coding-system ed))
    (click f w 'mouse-1 4)
    (test-equal "and mac back to unix"
                'utf-8-unix (buffer-file-coding-system ed))))

;; **The click acts on the window it landed in**, which is what
;; `with-selected-window` is for: the current buffer is one window's,
;; the clicked mode line the other's.

(let* ((f (frame-of "abc\n"))
       (w1 (window-of f))
       (second (allocate-buffer)))
  (with-current-buffer second
    (insert "xyz\n")
    (set-buffer-modified-p #f))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let ((w2 (split-window w1 #f 'below)))
      (set-window-buffer! w2 second)
      (render! f)
      (let* ((other (window-buffer w2))
             (line (car (window-last-mode-line w2)))
             (col (column-with-map line mode-line-modified-map)))
        (with-current-buffer (window-buffer w1) (set-buffer-modified-p #f))
        ;; the flag's state before the click
        (test-equal "the unclicked buffer is unmodified"
                    #f (buffer-modified-p (window-buffer w1)))
        (click f w2 'mouse-1 col)
        (test-equal "the clicked window's buffer toggled"
                    #t (buffer-modified-p other))
        (test-equal "the other buffer did not"
                    #f (buffer-modified-p (window-buffer w1)))))))

(test-end "schemacs_editor_mode_line_commands")

;;----------------------------------------------------------------
;; The press that precedes every click
;;----------------------------------------------------------------
;;
;; A real click is `down-mouse-1` and then `mouse-1`. On a mode-line
;; item the string's map binds the release (`[mode-line mouse-1]`) and
;; not the press, and Emacs's `read_key_sequence` *disposes of* an
;; unbound up/down click rather than looking it up alone
;; (`keyboard.c:12115`). Retrying it alone found the text binding
;; `mouse-drag-region` and ran it on a mode-line position - "Wrong type
;; argument in position 2: #f" whenever an item was pressed.

(test-begin "schemacs_editor_mode_line_press")

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let* ((line (car (window-last-mode-line w)))
           (col (column-with-map line mode-line-modified-map)))
      ;; The press alone: no message, and no chord left pending.
      (mouse-event f w 'down-mouse-1 col)
      (dispatch-key f 'down-mouse-1)
      (test-equal "a press on a mode-line item is dropped silently"
                  "" (frame-message f))
      (test-equal "...and leaves no prefix state behind"
                  #f (frame-keymap-state f))
      ;; Then the release, as a real click sends it.
      (mouse-event f w 'mouse-1
                   (column-with-map (car (window-last-mode-line w))
                                    mode-line-modified-map))
      (dispatch-key f 'mouse-1)
      (test-equal "the release of a click on the flag toggles it, with no error"
                  #t (buffer-modified-p ed))
      (test-equal "...and the echo area is still quiet"
                  "" (frame-message f)))))

(let* ((f (frame-of "abc\n"))
       (w1 (window-of f))
       (second (allocate-buffer)))
  (with-current-buffer second
    (insert "xyz\n")
    (set-buffer-modified-p #f))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let* ((w2 (split-window w1 #f 'below))
           (line #f)
           (col #f))
      (set-window-buffer! w2 second)
      (render! f)
      (set! line (car (window-last-mode-line w2)))
      (set! col (column-with-map line mode-line-buffer-identification-map))
      (test-assert "the buffer-name item has a map"
                   (and (integer? col) #t))
      (mouse-event f w2 'down-mouse-1 col)
      (dispatch-key f 'down-mouse-1)
      (test-equal "a press on the buffer name says nothing"
                  "" (frame-message f))
      (mouse-event f w2 'mouse-1
                   (column-with-map (car (window-last-mode-line w2))
                                    mode-line-buffer-identification-map))
      (dispatch-key f 'mouse-1)
      (test-equal "and its release switches the clicked window's buffer"
                  #t (eq? (window-buffer w2) (window-buffer w1))))))

;; A press on a plain part of the mode line is still the drag handle:
;; its release selects the window, as `[mode-line mouse-1]` is bound to
;; `mouse-select-window` - the bottom window's mode line, which
;; `mouse-drag-mode-line` leaves alone.
(let* ((f (frame-of "abc\n"))
       (w1 (window-of f)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (let* ((w2 (split-window w1 #f 'below))
           (line #f)
           (col #f)
           (row #f))
      (render! f)
      (set! line (car (window-last-mode-line w2)))
      ;; A plain stretch: the field padding after the line number (the
      ;; `mode-line-position` field is six wide and the number is three)
      ;; is not part of any item - it carries only the element marker.
      (set! col (+ (string-contains line "L1") 2))
      (set! row (mode-line-row w2))
      (test-assert "the plain stretch has no map"
                   (not (get-text-property col 'local-map line)))
      (mouse-event f w2 'down-mouse-1 col)
      (dispatch-key f 'down-mouse-1)
      (mouse-event f w2 'mouse-1 col)
      (dispatch-key f 'mouse-1)
      (test-equal "clicking a plain stretch of the mode line selects its window"
                  w2 (selected-window)))))

(test-end "schemacs_editor_mode_line_press")

;;----------------------------------------------------------------
;; The hover face - `note_mouse_highlight` on a mode line
;;----------------------------------------------------------------

(test-begin "schemacs_editor_mode_line_hover")

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (row (mode-line-row w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (clear-mouse-face!)
    (render! f)
    (let ((before (let loop ((gs (test-display-glyphs display)) (acc '()))
                    (cond ((null? gs) (reverse acc))
                          ((= (cadr (car gs)) row) (loop (cdr gs) (cons (car gs) acc)))
                          (else (loop (cdr gs) acc))))))
      (test-assert "the pointer over the flags highlights them"
                   (note-mouse-highlight f 5 row))
      (let* ((record (window-last-mode-line w))
             (run (list-ref record 4)))
        (test-assert "the run is recorded on the mode line"
                     (and run (pair? run)))
        ;; **The run stops at the element's edge.** Positions 4-7 - the
        ;; EOL mnemonic, both flags and the remote flag - all carry the
        ;; same `mouse-face` value, but each is its own format element,
        ;; so only the one under the pointer lights. Emacs's redisplay
        ;; gets this from each element being its own string object
        ;; (`store_mode_line_string`); `mode-line-elt-no` is the
        ;; flattened stand-in.
        (test-equal "the run is the element under the pointer, not the shared run"
                    '(5 6 mode-line-highlight) run)
        (test-assert "and the row was drawn with a different face token"
                     (not (equal? (let loop ((gs (test-display-glyphs display)) (acc '()))
                                    (cond ((null? gs) (reverse acc))
                                          ((= (cadr (car gs)) row)
                                           (loop (cdr gs) (cons (car gs) acc)))
                                          (else (loop (cdr gs) acc))))
                                  before))))
      (test-assert "the pointer leaving clears the highlight"
                   (note-mouse-highlight f -1 -1))
      (test-equal "and the record no longer has a run"
                  #f (list-ref (window-last-mode-line w) 4))
      ;; Each of the four adjacent items is its own target, and the
      ;; buffer name is one target holding its own characters only.
      (test-equal "every item is a separate target"
                  '((4 5) (5 6) (6 7) (7 8))
                  (map (lambda (col)
                         (clear-mouse-face!)
                         (render! f)
                         (note-mouse-highlight f col row)
                         (let ((run (list-ref (window-last-mode-line w) 4)))
                           (list (car run) (cadr run))))
                       '(4 5 6 7)))
      (let ((name-at (string-contains (car (window-last-mode-line w))
                                      "Untitled")))
        (clear-mouse-face!)
        (render! f)
        (note-mouse-highlight f name-at row)
        (let ((run (list-ref (window-last-mode-line w) 4)))
          (test-equal "the buffer name is one target, without the field padding"
                      (list name-at (+ name-at 8)) (list (car run) (cadr run))))))))

;; The hover box's vertical edges (`pgtk_draw_glyph_string`,
;; `pgtkterm.c:2048`).
;; A *dark colour* display, which is what a themed Gtk frame is: the
;; `mode-line` face's box comes from the `(background dark)` branch of
;; its defface, and the line's own box on every run is what used to
;; swallow the hovered item's left and right edges.
(parameterize ((*frame-background-mode* 'dark)
               (*display-color-cells* 256))
  (for-each face-spec-recalc (face-list))
  (let* ((f (frame-of "abc\n"))
         (w (window-of f))
         (row (mode-line-row w)))
    (parameterize ((*current-frame* f) (*current-buffer* #f))
      (render! f)
      (set! (test-box-calls display) '())
      (note-mouse-highlight f 4 row)
      ;; `member`, not `memq`: the calls are lists, and `memq` compares
      ;; their identity.
      (test-assert "the hovered item's box gets both vertical edges"
                   (and (member '(4 1 #t #t) (test-box-calls display)) #t))
      (test-equal "the line's own box between items still has none"
                  #t
                  (let ((between (member '(5 4 #f #f) (test-box-calls display))))
                    (and between #t)))
      (clear-mouse-face!)))
  ;; Back to the plain display the other tests assume.
  (for-each face-spec-recalc (face-list)))

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (row (mode-line-row w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (render! f)
    (let ((line (car (window-last-mode-line w))))
      (note-mouse-highlight f 5 row)
      (test-assert "the hovered line is lit"
                   (list-ref (window-last-mode-line w) 4))
      ;; The text under the pointer changes: a redisplay formats a new
      ;; line, and the recorded run was found in the old one. It must
      ;; not be painted over characters it never named.
      (with-current-buffer (window-buffer w) (insert "!"))
      (render! f)
      (test-equal "a line whose text changed drops the stale run"
                  #f (list-ref (window-last-mode-line w) 4)))))

(test-end "schemacs_editor_mode_line_hover")

;;----------------------------------------------------------------
;; A real click is a press and then a release
;;----------------------------------------------------------------
;;
;; The press on a mode line that is a drag handle runs
;; `mouse-drag-mode-line`, which installs a transient map. The release
;; must still reach the item under the pointer - `set-transient-map`'s
;; docstring: "if no match for a key is found in MAP, the normal key
;; lookup sequence then continues" - and the command that runs ends the
;; drag. Before the keymap-list fix the per-map lookup stopped at the
;; transient map, the release was unbound and dropped, and the editor
;; stayed in drag mode until C-g: reported from a real Gtk editor,
;; mousing over the mode-line flags.
(test-begin "schemacs_editor_mode_line_press_release")

(let* ((f (frame-of "abc\n"))
       (top (window-of f))
       ;; Split so the TOP window's mode line is a drag handle: a sole
       ;; window's cannot be dragged (`mouse-drag-mode-line`'s
       ;; `window-at-side-p` guard), and then no transient map exists and
       ;; the release is the ordinary case.
       (bottom (split-window top #f 'below))
       (ed (window-buffer top)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (render! f)
    (let* ((line (car (window-last-mode-line top)))
           (col (column-with-map line mode-line-read-only-map))
           (posn (posn-at-x-y col (mode-line-row top) f)))
      (set!buffer-read-only ed #f)
      (*last-read-event* (list 'down-mouse-1 posn))
      (dispatch-key f 'down-mouse-1)
      (test-assert "the press on a drag handle installs a transient map"
                   (pair? *overriding-terminal-local-map*))
      (*last-read-event* (list 'mouse-1 posn))
      (dispatch-key f 'mouse-1)
      (test-equal "the release still runs the item's command"
                  #t (buffer-read-only? ed))
      (test-assert "and the drag's transient map is gone"
                   (not (pair? *overriding-terminal-local-map*)))
      (test-equal "and pointer tracking is back off" #f track-mouse))))

(test-end "schemacs_editor_mode_line_press_release")

;;----------------------------------------------------------------
;; The mode name's and the lighters' menus
;;----------------------------------------------------------------
;;
;; `bindings.el:571-596`'s two keymaps and the three commands
;; `mouse.scm` names for them. Every expected value is Emacs 31.1's own
;; answer for the same click - `posn-object` over a lighter is that
;; lighter's string, and a press on it runs `mouse-minor-mode-menu`.

(test-begin "schemacs_editor_mode_line_menus")

(let* ((f (frame-of "abc\n"))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f)
                 (*minor-mode-alist*
                  (append (*minor-mode-alist*)
                          (list (list 'mode-line-test-flag " Test")))))
    (with-current-buffer ed
      (overwrite-mode 1)
      (set-buffer-local-value! ed 'mode-line-test-flag #t))
    (render! f)
    (let* ((line (car (window-last-mode-line w)))
           (row (mode-line-row w))
           (name-col (column-with-map line mode-line-major-mode-keymap))
           (ovw-col (string-contains line "Ovwrt"))
           (test-col (string-contains line "Test")))
      (test-assert "the mode name carries the major-mode map"
                   name-col)
      ;; The lighters' list is bindings.el's own - `auto-fill-function`
      ;; included, which is where the " Fill" lighter comes from (the
      ;; mode has no `:lighter` of its own).
      (test-equal "the alist has Emacs's auto-fill lighter"
                  " Fill"
                  (cadr (assq 'auto-fill-function (*minor-mode-alist*))))
      (test-equal "its mouse-2 is describe-mode"
                  'describe-mode
                  (lookup-key mode-line-major-mode-keymap
                              (vector 'mode-line 'mouse-2)))
      (test-assert "its mouse-1 pops the major mode menu"
                   (eq? (lookup-key mode-line-major-mode-keymap
                                    (vector 'mode-line 'down-mouse-1))
                        'mouse-menu-major-mode-menu))
      (test-assert "and its mouse-3 the minor modes menu"
                   (eq? (lookup-key mode-line-major-mode-keymap
                                    (vector 'mode-line 'down-mouse-3))
                        'mode-line-minor-mode-menu))
      (test-equal "the mode name's help text is bindings.el's"
                  "Major mode\nmouse-1: Display major mode menu\nmouse-2: Show help for major mode\nmouse-3: Toggle minor modes"
                  (get-text-property name-col 'help-echo line))
      ;; One run per lighter, which is what a click needs: Emacs's
      ;; lighters are separate strings, so its posn object is one of
      ;; them (measured: `" Ovwrt"` and `" Fill"`).
      (test-equal "a click on a lighter cuts out that lighter"
                  " Ovwrt"
                  (string-property-run-at (posn-at-x-y ovw-col row f)
                                          'local-map))
      (test-equal "and the second lighter is its own run"
                  " Test"
                  (string-property-run-at (posn-at-x-y test-col row f)
                                          'local-map))
      (test-assert "a lighter carries the minor-mode map"
                   (eq? (get-text-property ovw-col 'local-map line)
                        mode-line-minor-mode-keymap))
      (test-assert "and its mouse-2 is the describe command"
                   (eq? (lookup-key mode-line-minor-mode-keymap
                                    (vector 'mode-line 'mouse-2))
                        'mode-line-minor-mode-help))
      (test-equal "the indicator completion table lists the lighters that are on"
                  '("Ovwrt" "Test")
                  (describe-minor-mode-completion-table-for-indicator))
      (test-equal "the lighters' help text is bindings.el's"
                  "Minor mode\nmouse-1: Display minor mode menu\nmouse-2: Show help for minor mode\nmouse-3: Toggle minor modes"
                  (get-text-property ovw-col 'help-echo line))
      ;; A press on the lighter runs `mouse-minor-mode-menu`, and the
      ;; menu it builds is `mouse.el:283`'s - the "Turn off" item names
      ;; the mode's command.
      (let ((popped 'none))
        (parameterize ((*popup-menu-function*
                        (lambda (menu event) (set! popped menu))))
          (*last-read-event* (list 'down-mouse-1
                                   (posn-at-x-y ovw-col row f)))
          (dispatch-key f 'down-mouse-1))
        (test-assert "a press on a lighter pops its menu"
                     (keymapp popped))
        (test-equal "whose Turn off item names the mode"
                    'overwrite-mode
                    (and (keymapp popped)
                         (lookup-key popped (vector 'turn-off)))))
      ;; The "Help for minor mode" item exists only with a help library
      ;; installed - the seam's own rule - and calling it calls
      ;; `describe-function` with the mode.
      (let ((popped 'none)
            (described #f))
        (parameterize ((*popup-menu-function*
                        (lambda (menu event) (set! popped menu)))
                       (*describe-function-function*
                        (lambda (command) (set! described command))))
          (*last-read-event* (list 'down-mouse-1
                                   (posn-at-x-y ovw-col row f)))
          (dispatch-key f 'down-mouse-1)
          (when (keymapp popped)
            ((lookup-key popped (vector 'help)))))
        (test-equal "the Help item asks for the mode's documentation"
                    'overwrite-mode described))
      ;; The toggles menu: Emacs's three entries this tree can back, and
      ;; the sorter that orders them by their labels.
      (test-equal "the toggles menu has this tree's three modes"
                  '(auto-fill-mode font-lock-mode overwrite-mode)
                  (let ((keys '()))
                    (map-keymap (lambda (k v) (set! keys (cons k keys)))
                                (bindings--sort-menu-keymap mode-line-mode-menu))
                    (reverse keys)))
      (let* ((item (hashv-ref (keymap-bindings mode-line-mode-menu)
                              'overwrite-mode))
             (button (cdr (memq ':button item))))
        ;; Emacs's variable's value when the mode is on is the *symbol*
        ;; `overwrite-mode-textual`, not a boolean - the same answer the
        ;; `:button` handler treats as checked.
        (test-equal "the overwrite toggle reads the mode's variable"
                    'overwrite-mode-textual
                    (eval (cdr (car button)) (current-module))))
      ;; The major-mode menu in a mode with no menu of its own is the
      ;; Edit menu, which is Emacs's fallback (`menu-bar-edit-menu`).
      (let ((edit (make-sparse-keymap "Edit")))
        (parameterize ((*menu-bar-edit-menu* edit))
          (test-assert "a mode with no menu gets the Edit menu"
                       (eq? (mouse-menu-major-mode-map) edit)))))))

(test-end "schemacs_editor_mode_line_menus")

;;----------------------------------------------------------------
;; The line and column item - `bindings.el:727`
;;----------------------------------------------------------------
;;
;; `mode-line-position`: the percentage of the buffer above (or below)
;; the window, then the line number, and - only when Column Number mode
;; is on - the column. Emacs's default is `Top L1`/`All L1`, not this
;; tree's old `-- L1 C0`.

(test-begin "schemacs_editor_mode_line_position")

(let* ((f (frame-of "alpha\nbeta\n"))
       (w (window-of f)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (render! f)
    (let ((line (car (window-last-mode-line w))))
      (test-assert "the default line shows the percentage and the line"
                   (and (string-contains line "All L1")
                        (not (string-contains line " C0"))))
      (test-equal "the construct in a fully visible buffer"
                  "All L1   "
                  (format-mode-line 'mode-line-position w))
      (test-equal "a fully visible buffer's percent is All"
                  "All"
                  (format-mode-line "%p" w))
      (test-equal "and %q says the whole buffer is on screen"
                  "All   "
                  (format-mode-line "%q" w)))
    (dynamic-wind
     (lambda () (column-number-mode 1))
     (lambda ()
       (test-equal "with Column Number mode on it draws (LINE,COL)"
                   "All (1,0)    "
                   (format-mode-line 'mode-line-position w)))
     (lambda () (column-number-mode -1)))
    ;; The press on the percentages and the line/column text pops the
    ;; display menu - Emacs binds the menu keymap there and pops it
    ;; through `read_char`'s menu prompting; this tree's press names the
    ;; command.
    (test-equal "the position map's press is its menu command"
                'mode-line-line-column-menu
                (lookup-key mode-line-column-line-number-mode-map
                            (vector 'mode-line 'down-mouse-1)))
    (test-equal "the menu has Emacs's three toggles, in its display order"
                '(column-number-mode line-number-mode size-indication-mode)
                (let ((keys '()))
                  (map-keymap (lambda (k v) (set! keys (cons k keys)))
                              line-column-mode-menu)
                  (reverse keys)))
    (test-equal "their initial states are Emacs's"
                '(#f #t #f)
                (list (column-number-mode-variable)
                      (line-number-mode-variable)
                      (size-indication-mode-variable)))
    (let ((posn (posn-at-x-y (string-contains (car (window-last-mode-line w))
                                              "All")
                             (mode-line-row w) f))
          (popped 'none))
      (parameterize ((*popup-menu-function* (lambda (m e) (set! popped m))))
        (*last-read-event* (list 'down-mouse-1 posn))
        (dispatch-key f 'down-mouse-1))
      (test-assert "a press on the position pops the line/column menu"
                   (eq? popped line-column-mode-menu)))))

;; The percentages on a buffer taller than its window: at the top the
;; text above the window is none, so `%p' says "Top" and `%P' gives a
;; percentage; at the end the whole buffer is above the window's last
;; row, so `%p' says "Bottom".
(let* ((text (let loop ((i 1) (acc '()))
               (if (> i 100)
                   (apply string-append (reverse acc))
                   (loop (+ i 1)
                         (cons (format #f "line ~a\n" i) acc)))))
       (f (frame-of text))
       (w (window-of f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (render! f)
    (test-equal "at the top of a long buffer the percent is Top"
                "Top"
                (format-mode-line "%p" w))
    (with-current-buffer ed
      (goto-char (point-max)))
    (render! f)
    (test-equal "at the bottom it is Bottom"
                "Bottom"
                (format-mode-line "%p" w))
    (let ((q (format-mode-line "%q" w)))
      (test-assert "and %q ends at 100%"
                   (let ((n (string-length q)))
                     (and (>= n 4)
                          (string=? (substring q (- n 4) n) "100%")))))))

;; `percent99` is the C's formula, capped at 99.
(test-equal "percent99 rounds up and caps"
            '(0 50 10 99)
            (list (percent99 0 10) (percent99 1 2) (percent99 1 10)
                  (percent99 100 100)))

(test-end "schemacs_editor_mode_line_position")

;;----------------------------------------------------------------
;; The coding-system item - `bindings.el:74-88', `:203-226'
;;----------------------------------------------------------------
;;
;; The `%z` mnemonics at the start of the mode line are a button:
;; mouse-1 describes the buffer's coding system, mouse-3 sets it, and
;; the help text is `mode-line-mule-info-help-echo`'s.

(test-begin "schemacs_editor_mode_line_coding")

(let* ((f (frame-of "alpha\n"))
       (w (window-of f)))
  (parameterize ((*current-frame* f) (*current-buffer* #f))
    (render! f)
    (let* ((line (car (window-last-mode-line w)))
           (col (string-contains line "U"))
           (row (mode-line-row w)))
      (test-assert "the coding mnemonics carry the coding-system map"
                   (eq? (get-text-property col 'local-map line)
                        mode-line-coding-system-map))
      (test-equal "its help text names the coding system"
                  "Buffer coding system (multi-byte): utf-8-unix\nmouse-1: Describe coding system\nmouse-3: Set coding system"
                  ((get-text-property col 'help-echo line) w #f -1))
      (test-assert "and it is highlighted under the pointer"
                   (eq? (get-text-property col 'mouse-face line)
                        'mode-line-highlight))
      (let ((described #f))
        (parameterize ((*describe-coding-system-function*
                        (lambda (cs) (set! described cs))))
          (*last-read-event* (list 'mouse-1 (posn-at-x-y col row f)))
          (dispatch-key f 'mouse-1))
        (test-equal "mouse-1 asks to describe the buffer's coding system"
                    'utf-8-unix described))
      (let ((ran #f))
        (parameterize ((*set-buffer-file-coding-system-command*
                        (lambda () (set! ran #t))))
          (*last-read-event* (list 'mouse-3 (posn-at-x-y col row f)))
          (dispatch-key f 'mouse-3))
        (test-assert "mouse-3 runs set-buffer-file-coding-system"
                     ran)))))

(test-end "schemacs_editor_mode_line_coding")

(test-end "schemacs_editor_mode_line")
