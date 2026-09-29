(define-library (schemacs editor xdisp)
  ;; This library mirrors GNU Emacs's `xdisp.c': the redisplay. It draws
  ;; each window's rows of text, its mode line and the vertical border
  ;; beside it, then the echo area, then places the terminal cursor. What
  ;; it draws is derived entirely from state it can reach without knowing
  ;; about editing: the buffers the windows show, where their points are,
  ;; and the frame's echo area.
  ;;
  ;; Two things make that true, and both are why this library comes when
  ;; it does. The echo area's buffer and prompt are read from the frame
  ;; (`*echo-area-buffer*', `*echo-area-prompt*'), which is where GNU
  ;; Emacs keeps them, so the renderer has nothing to ask a minibuffer.
  ;; And what to draw as a search match arrives in `*search-highlight*',
  ;; which the search commands publish - in Emacs the same fact is the
  ;; `isearch' and `lazy-highlight' faces on the match. A renderer that
  ;; imported the minibuffer and the search would sit in a cycle with
  ;; them, and this is the knot the layout plan cuts here.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `display' is not in `(scheme base)' - it is `(scheme write)'s - and
    ;; `caddr' is `(scheme cxr)'s. The mode line's evaluator uses both, and
    ;; neither is missed until a mode line is drawn.
    (only (scheme write) display)
    (only (scheme cxr) caddr)
    (ncurses curses)
    ;; The mode line reads a line and column out of the engine, which
    ;; answers with one of these.
    (only (schemacs ui text-buffer-impl)
          text-location-type? text-location-line text-location-column)

    (only (schemacs editor engine)
         line-break-newline line-break-crlf line-break-return
         string-search-forward text-editor-buffer-name text-editor-text-props
         text-editor-char-count text-editor-file-name
         text-editor-cursor-column text-editor-cursor-line
         text-editor-get-cursor text-editor-mark text-editor-get-end-of-line
         text-editor-get-line-column text-editor-get-start-of-line
         text-editor-line-count text-editor-line-editor-ref
         text-editor-line-outer-size text-editor-modified?
         text-editor-read-only? text-editor-text-line-ref
         text-editor-to-string text-line-inner->string)
    (only (schemacs editor frame)
         *echo-area-buffer* *echo-area-prompt* frame-height frame-width
         ncurses-frame-message ncurses-frame-selected-window
         sync-frame-size! window-body-height
         window-body-width window-buffer window-height window-left
         window-list
         selected-window set!window-top-line window-point window-right-border?
         window-top
         window-top-line)
    (only (schemacs editor disp-table)
         char-display-glyph current-line-display-column expand-line-display
         line-display-offsets)
    ;; The `face' text property, and the faces themselves. A face reaches
    ;; the display through these three libraries and no others: the
    ;; property says which faces are in effect, `xfaces' merges them and
    ;; folds them down, and this file turns that into terminal attributes.
    (only (schemacs editor textprop) get-text-property)
    (only (schemacs editor buffer)
          *transient-mark-mode* buffer-local-value)
    (only (schemacs editor faces) *undefined-face-attribute*)
    (only (schemacs editor xfaces)
          attribute-value face-attributes-empty face-realized-attributes
          merge-face-ref merge-face-vectors realize-tty-face)
    ;; `logior' is Guile's, not R7RS's: the attributes are bit flags.
    (only (guile) logior)
    )

  (export
   ;; The search highlight is the search commands' to set, so it is
   ;; exported; `render!' and the mode line are what the rest calls.
   *search-highlight*
   cursor-screen-position
   highlight-matches
   ;; the run computation, which is what a caller can test without a
   ;; terminal: `draw-line!' itself needs one
   line-face-runs
   line-end-fill-attribute
   *mode-line-format*
   face-at-buffer-position
   face->attribute
   format-mode-line
   line-continuation-display?
   line-display-width
   mode-line-string
   render!
   status-string
   )

  (begin

    (define *search-highlight*
      ;; What the renderer should draw as search matches, or false when
      ;; nothing should be: a pair of the search string and whether the
      ;; search folds case.
      ;;
      ;; The matching itself lives with the search commands - this is a
      ;; *display* fact, and it is here because the display layer must not
      ;; have to know who set it. In GNU Emacs the same fact is a text
      ;; property: isearch puts the `isearch\' face on the match point is
      ;; on and the `lazy-highlight\' face on the others, and `xdisp.c\'
      ;; draws whatever faces it finds. This editor has no text properties
      ;; and no overlays yet, so isearch publishes what it found here and
      ;; the renderer draws it.
      ;;--------------------------------------------------------------
      (make-parameter #f))
    (define (ncurses-line-string ed i)
      ;; Get the displayable contents of line I (not including its
      ;; line break) as a string, or #f when I is past the end of the
      ;; buffer. The current line is read from the line editor, which
      ;; holds the live copy of the line under the cursor; every other
      ;; line is read from the lines gap-buffer.
      ;;--------------------------------------------------------------
      (cond
       ((= i (text-editor-cursor-line ed))
        ;; The live current line: the line editor's characters, from
        ;; the start of the line to the end of the line.
        (call-with-port (open-output-string)
          (lambda (port)
            (let* ((start (text-editor-get-start-of-line ed))
                   (end   (text-editor-get-end-of-line ed))
                   (len   (- end start)))
              (let loop ((j 0))
                (when (< j len)
                  (let ((ch (text-editor-line-editor-ref ed j)))
                    (when ch (write-char ch port)))
                  (loop (+ 1 j)))))
            (get-output-string port))))
       ((< i (text-editor-line-count ed))
        ;; the display form of the line: its contents WITHOUT the
        ;; terminating line break
        (text-line-inner->string (text-editor-text-line-ref ed i)))
       (else #f)))

    (define (truncate-line str width)
      (let ((len (string-length str)))
        (cond
         ((<= len width) str)
         ((<= width 0) "")
         (else (substring str 0 width)))))

    (define (pad-line str width)
      (let ((len (string-length str)))
        (cond
         ((< width len) (truncate-line str width))
         (else (string-append str (make-string (- width len) #\space))))))

    (define (scroll-to-cursor! window)
      ;; Adjust WINDOW's top line so that its point is visible, as GNU
      ;; Emacs's redisplay does before drawing each window.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (cursor-line (text-editor-cursor-line ed))
             (vheight (window-body-height window)))
        (cond
         ((< cursor-line (window-top-line window))
          (set!window-top-line window cursor-line))
         ((>= cursor-line (+ (window-top-line window) vheight))
          (set!window-top-line
           window (+ 1 (- cursor-line vheight)))
           ))))

    (define *mode-line-window* (make-parameter #f))

    (define (mode-line-eol-desc)
      ;; The mode-line mnemonic for the EOL convention of WINDOW's buffer:
      ;; GNU Emacs's `mode-line-eol-desc', which reads the buffer-local
      ;; `buffer-file-coding-system' in the window being rendered.
      ;;--------------------------------------------------------------
      (let* ((window (*mode-line-window*))
             (line-break
              (buffer-local-value (window-buffer window)
                                  'buffer-file-coding-system
                                  line-break-newline)))
        (cond ((eq? line-break line-break-crlf) "(DOS)")
              ((eq? line-break line-break-return) "(Mac)")
              ((eq? line-break line-break-newline) ":")
              (else ""))))

    (define *mode-line-format*
      ;; GNU Emacs's `mode-line-format': the template a window's mode line is
      ;; drawn from, evaluated by `FORMAT-MODE-LINE' below.
      ;;
      ;; The default is GNU Emacs's own for the parts this editor can show:
      ;; `mode-line-modified' (`("%1*" "%1+")' in `bindings.el', which is the
      ;; two-cell `--', `**' or `%%'), the buffer name in a twelve-wide field
      ;; (`mode-line-buffer-identification', `("%12b")'), then the line and
      ;; column of the window's own point (`mode-line-position').
      ;;
      ;; Emacs's default also names variables in the format - `mode-line-mule-info',
      ;; `mode-line-position', `mode-line-modes' and so on - and a symbol in
      ;; the format is evaluated at display time. This editor has no variable
      ;; registry yet, so a symbol here resolves to nothing, exactly as an
      ;; unbound variable does in Emacs; the default therefore spells out what
      ;; it shows rather than naming it. When the elisp layer brings a variable
      ;; registry, the names go back in.
      ;;--------------------------------------------------------------
      (make-parameter
       (list (list ':eval mode-line-eol-desc)
             " "
             (list "%1*" "%1+")
             " "
             "%12b"
             " -- L" "%l" " C" "%c")))

    (define (mode-line-construct spec window)
      ;; The text one `%'-construct stands for: GNU Emacs's
      ;; `decode_mode_spec'. SPEC is the character after the `%'.
      ;;
      ;; The constructs this editor can answer are the ones about the buffer
      ;; and the window's point. The rest - the percentages of the buffer
      ;; above or below the window (`%p', `%P', `%o', `%q'), the coding
      ;; systems (`%z', `%Z'), the process (`%s') and the recursion depth
      ;; (`%[', `%]') - are printed as they stand, which is what Emacs does
      ;; with a construct it does not recognise either.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (at (text-editor-get-line-column ed (window-point window))))
        (case spec
          ((#\%) "%")
          ((#\b) (or (text-editor-buffer-name ed) "*scratch*"))
          ((#\f) (or (text-editor-file-name ed) ""))
          ((#\l) (number->string (text-location-line at)))
          ;; `%c' counts from zero - "the leftmost column is displayed as
          ;; zero", which a terminal Emacs confirms: `(format-mode-line "%c")'
          ;; at the start of a line is "0". The engine counts from one, as it
          ;; must for a screen position, so the construct subtracts.
          ((#\c) (number->string (- (text-location-column at) 1)))
          ;; `%C' is `%c' counting from one rather than zero
          ((#\C) (number->string (text-location-column at)))
          ;; `%*' is `%' read-only, `*' modified, `-' neither; `%+' is `*'
          ;; modified, `%' read-only, `-' neither; `%&' is `*' modified
          ((#\*) (if (text-editor-read-only? ed)
                     "%"
                     (if (text-editor-modified? ed) "*" "-")))
          ((#\+) (if (text-editor-modified? ed)
                     "*"
                     (if (text-editor-read-only? ed) "%" "-")))
          ((#\&) (if (text-editor-modified? ed) "*" "-"))
          ((#\i) (number->string (text-editor-char-count ed)))
          ((#\I) (let ((n (text-editor-char-count ed)))
                   (cond ((< n 10000) (number->string n))
                         ((< n 10000000)
                          (string-append (number->string (quotient n 1000)) "k"))
                         (else
                          (string-append (number->string (quotient n 1000000))
                                         "M")))))
          ;; `%-' is "enough dashes to fill the mode line": how many is only
          ;; known when the line is placed, so the drawing code pads instead
          ((#\-) "")
          (else (string #\% spec)))))

    (define (number-in-field? text)
      ;; Whether TEXT is a number, which is what decides which side a field
      ;; pads on. Measured from a terminal Emacs: `%6l' at the first line is
      ;; "     1" - a number is padded on the *left*, so that the digits line
      ;; up as point moves - and `%12b' is "probe       ", padded on the
      ;; right. The test is Emacs's: a leading digit or a minus sign.
      ;;--------------------------------------------------------------
      (and (> (string-length text) 0)
           (or (char-numeric? (string-ref text 0))
               (char=? (string-ref text 0) #\-))))

    (define (pad-mode-line-field text width)
      ;; TEXT in a field WIDTH wide, in the `%N<spec>' form: GNU Emacs pads a
      ;; number on the left and anything else on the right. A text longer than
      ;; the field is cut to it.
      ;;--------------------------------------------------------------
      (let ((len (string-length text)))
        (cond
         ((= len width) text)
         ((> len width) (substring text 0 width))
         ((number-in-field? text)
          (string-append (make-string (- width len) #\space) text))
         (else (string-append text (make-string (- width len) #\space))))))

    (define (pad-mode-line-element text width)
      ;; TEXT in the field of an `(N ...)' element. This is a different
      ;; mechanism from `%N<spec>' and it pads differently: measured from the
      ;; same terminal Emacs, `(6 "%l")' at the first line is "1     " where
      ;; `%6l' is "     1". The element form is a *precision* - the text is
      ;; laid out to that width and short text simply does not fill it - so
      ;; the padding goes on the right whatever the text is.
      ;;--------------------------------------------------------------
      (let ((len (string-length text)))
        (if (>= len width)
            (substring text 0 width)
            (string-append text (make-string (- width len) #\space)))))

    (define (expand-mode-line-string str window)
      ;; STR with its `%'-constructs expanded: GNU Emacs's processing of a
      ;; string in a mode line. A `%' followed by digits is a field width, as
      ;; in `%12b'; a `%' followed by anything else is a construct. A `%' at
      ;; the very end is a literal `%'.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (let loop ((i 0) (width #f))
            (when (< i (string-length str))
              (let ((c (string-ref str i)))
                (cond
                 ((and (char=? c #\%) (not width))
                  (loop (+ 1 i) 'pending))
                 ((eq? width 'pending)
                  (if (char-numeric? c)
                      (loop (+ 1 i) (- (char->integer c) (char->integer #\0)))
                      (let ((text (mode-line-construct c window)))
                        (display (if width text text) port)
                        (loop (+ 1 i) #f))))
                 ((integer? width)
                  (if (char-numeric? c)
                      (loop (+ 1 i) (+ (* 10 width)
                                       (- (char->integer c) (char->integer #\0))))
                      (begin
                        (display (pad-mode-line-field
                                  (mode-line-construct c window) width)
                                 port)
                        (loop (+ 1 i) #f))))
                 (else
                  (write-char c port)
                  (loop (+ 1 i) #f))))))
          (get-output-string port))))

    (define (format-mode-line format . args)
      ;; GNU Emacs's `format-mode-line': the mode line FORMAT produces for a
      ;; window, WINDOW being the second argument or the selected window.
      ;; A construct is a string, list, symbol, or nil; `:eval' holds a
      ;; zero-argument procedure in place of an Emacs Lisp form.
      ;;--------------------------------------------------------------
      (let ((window (if (pair? args) (car args) (selected-window))))
        (parameterize ((*mode-line-window* window))
          (let process ((construct format))
            (cond
             ((not construct) "")
             ((string? construct) (expand-mode-line-string construct window))
             ((integer? construct) "")
             ((symbol? construct) "")
             ((pair? construct)
              (cond
               ((and (memq (car construct) '(:eval :propertize))
                     (pair? (cdr construct)))
                (process (if (eq? (car construct) ':eval)
                             ((cadr construct))
                             (cadr construct))))
               ((symbol? (car construct))
                (process (if (and (pair? (cdr construct))
                                  (pair? (cddr construct)))
                             (caddr construct)
                             #f)))
               ((integer? (car construct))
                (let* ((width (car construct))
                       (rest (if (pair? (cdr construct)) (cadr construct) #f))
                       (text (process rest)))
                  (if (< width 0)
                      (if (> (string-length text) (- width))
                          (substring text 0 (- width))
                          text)
                      (pad-mode-line-element text width))))
               (else (apply string-append (map process construct)))))
             (else ""))))))

    (define (mode-line-string window)
      ;; The window's mode line: GNU Emacs's `MODE-LINE-STRING' is what
      ;; its format produces for this window, which is the whole of it -
      ;; there is no hand-rolled string here any more. What the format
      ;; says, and what it may say, is in `*MODE-LINE-FORMAT*'.
      ;;
      ;; The name is the buffer's, not the file's: Emacs names a buffer
      ;; visiting a file after the file without its directory (that is
      ;; what `create-file-buffer' does), and names a buffer with no file
      ;; of its own - so a window can show "*Completions*", which visits
      ;; nothing.
      ;;
      ;; The hand-rolled indicator that used to be here is gone with it:
      ;; it reported `%%' for any read-only buffer, so a buffer that was
      ;; both modified and read-only showed `%%' when Emacs shows `%*'.
      ;; That is what `%1*' followed by `%1+' gives - see
      ;; ENGINE-FINDINGS.txt.
      ;;
      ;; The position is per window because point is: two windows on the
      ;; same buffer are at different places in it, and each mode line
      ;; says where its own window is.
      ;;--------------------------------------------------------------
      (parameterize ((*mode-line-window* window))
        (format-mode-line (*mode-line-format*) window)))

    (define (status-string frame)
      ;; The mode line of the selected window, which is the one the
      ;; frame is about.
      ;;--------------------------------------------------------------
      (mode-line-string (ncurses-frame-selected-window frame)))

    (define (line-outer-size ed line-index)
      ;; How many characters line LINE-INDEX advances the buffer's
      ;; character index by - its contents plus its line break, which is
      ;; what the CDF counts, and so what the next line's first character
      ;; is offset by.
      ;;--------------------------------------------------------------
      (text-editor-line-outer-size ed line-index))

    (define (display-column-of line col)
      ;; The screen column at which buffer column COL of LINE is drawn,
      ;; which is where a search match has to be drawn.
      ;;--------------------------------------------------------------
      (string-length
       (expand-line-display (substring line 0 (min col (string-length line)))
                            10000)))

    ;;----------------------------------------------------------------
    ;; Faces

    (define *tty-color-pairs*
      ;; The colour pairs made so far, as `((FOREGROUND . BACKGROUND) .
      ;; PAIR)'. Emacs keeps the same table on the frame (`tty_face_1'
      ;; makes a pair per combination a face asks for), because a
      ;; terminal has only so many and they have to be shared.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define (tty-color-pair foreground background)
      ;; The ncurses colour-pair number for FOREGROUND and BACKGROUND,
      ;; making the pair the first time it is asked for. A missing colour
      ;; is #f and becomes -1, which is how ncurses spells "the
      ;; terminal's own default". 0 means no pair at all.
      ;;--------------------------------------------------------------
      (cond
       ((and (not foreground) (not background)) 0)
       ((not (has-colors?)) 0)
       (else
        (let* ((key (cons foreground background))
               (entry (assoc key (*tty-color-pairs*))))
          (cond
           (entry (cdr entry))
           (else
            (let ((n (+ 1 (length (*tty-color-pairs*)))))
              (init-pair! n (if foreground foreground -1)
                          (if background background -1))
              (*tty-color-pairs* (cons (cons key n) (*tty-color-pairs*)))
              n)))))))

    (define (tty-face-attribute face)
      ;; A realized tty face as one ncurses attribute number: the bit
      ;; flags `term.c' would turn into escape sequences, which is all a
      ;; terminal can be told. The colour pair is made here, on first use.
      ;;--------------------------------------------------------------
      (let ((foreground (attribute-value face ':foreground))
            (background (attribute-value face ':background)))
        (let ((bits 0))
          (when (attribute-value face ':bold)
            (set! bits (logior bits A_BOLD)))
          (when (attribute-value face ':underline)
            (set! bits (logior bits A_UNDERLINE)))
          (when (attribute-value face ':reverse)
            (set! bits (logior bits A_REVERSE)))
          (let ((pair (tty-color-pair (if (number? foreground) foreground #f)
                                      (if (number? background) background #f))))
            (if (> pair 0) (logior bits (color-pair pair)) bits)))))

    (define (face->attribute face-name)
      ;; The ncurses attribute number for a *named* face: GNU Emacs's
      ;; `face_at_buffer_position' where the face is known by name, which
      ;; is what the mode line and the echo area need.
      ;;--------------------------------------------------------------
      (tty-face-attribute
       (realize-tty-face
        (merge-face-vectors (face-realized-attributes face-name)
                            (face-realized-attributes 'default)))))

    (define (line-face-runs ed line-start line-string)
      ;; LINE-STRING as maximal runs of characters that share one face:
      ;; `(FROM TO ATTRIBUTE)' in buffer columns, ATTRIBUTE being what
      ;; `face-at-buffer-position' answers.
      ;;
      ;; The runs, not the characters, are what gets drawn: a terminal is
      ;; told "these cells are bold" once per run rather than once per
      ;; character, which is the same reason Emacs walks faces with
      ;; `next-single-property-change' instead of asking at every
      ;; position.
      ;;--------------------------------------------------------------
      (let ((len (string-length line-string)))
        (if (= len 0)
            '()
            (let loop ((i 1)
                       (start 0)
                       (attribute (face-at-buffer-position ed line-start))
                       (acc '()))
              (if (>= i len)
                  (reverse (cons (list start len attribute) acc))
                  (let ((a (face-at-buffer-position ed (+ line-start i))))
                    (if (equal? a attribute)
                        (loop (+ 1 i) start attribute acc)
                        (loop (+ 1 i) i a (cons (list start i attribute) acc)))))))))

    (define (draw-line! ed line-start line-string display
                        screen-row x0 width)
      ;; Draw one line of a window at SCREEN-ROW, X0, each run of
      ;; characters that share a face drawn with it. A buffer with no
      ;; properties and no active region keeps the original fast path.
      ;;--------------------------------------------------------------
      (if (and (not (text-editor-text-props ed))
               (not (region-face-active? ed)))
          (addstr (stdscr) display #:y screen-row #:x x0)
          (let ((offsets (line-display-offsets line-string)))
            (for-each
             (lambda (run)
               (let ((from (list-ref offsets (car run)))
                     (to (list-ref offsets (cadr run)))
                     (attribute (caddr run)))
                 ;; The line is drawn up to the window's WIDTH: a run
                 ;; starting past the window's edge is not drawn at all,
                 ;; and one cut by it stops at the edge - which is how
                 ;; GNU Emacs truncates a line at the window boundary.
                 ;; The slow (properties) path has to say so itself,
                 ;; where the fast path hands the whole line to ncurses
                 ;; and lets it clip.
                 (when (< from width)
                   (attr-on! (stdscr) attribute)
                   (addstr (stdscr)
                           (substring display from
                                      (min to (min (string-length display)
                                                   width)))
                           #:y screen-row #:x (+ x0 from))
                   (attr-off! (stdscr) attribute))))
             (line-face-runs ed line-start line-string))))
      ;; xdisp.c draws a continuation glyph when more of the logical line
      ;; remains, with the default face. Otherwise a region may extend its
      ;; face into empty cells at the line end.
      (if (line-continuation-display? line-string width)
          (draw-continuation-glyph! screen-row x0 width)
          (let ((fill (line-end-fill-attribute ed line-start line-string
                                               display width)))
            (when fill
              (attr-on! (stdscr) fill)
              (addstr (stdscr)
                      (make-string (- width (string-length display)) #\space)
                      #:y screen-row
                      #:x (+ x0 (string-length display)))
              (attr-off! (stdscr) fill)))))

    (define (line-display-width line-string)
      ;; Count all cells, expanding tabs at each successive display column.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (column 0))
        (if (>= i (string-length line-string))
            column
            (let* ((ch (string-ref line-string i))
                   (glyph (char-display-glyph ch column)))
              (loop (+ i 1) (+ column (string-length glyph)))))))

    (define (line-continuation-display? line-string width)
      ;; Whether the logical line's full display width exceeds this row:
      ;; GNU Emacs puts a special continuation glyph in the final cell.
      ;; Tabs and control characters may occupy more than one display cell.
      ;;--------------------------------------------------------------
      (and (> width 0)
           (> (line-display-width line-string) width)))

    (define (draw-continuation-glyph! row x0 width)
      ;; The continuation glyph is a special display character, not buffer
      ;; text, and Emacs draws it with the default face even inside a region.
      ;;--------------------------------------------------------------
      (let ((attribute (face->attribute 'default)))
        (move (stdscr) row (+ x0 width -1))
        (attr-on! (stdscr) attribute)
        (addstr (stdscr) "\\")
        (attr-off! (stdscr) attribute)))

    (define (line-end-fill-attribute ed line-start line-string display width)
      ;; Face used for cells after a line's text when the line-end
      ;; position is inside the active region. A line that ends at point-max
      ;; has no newline position and gets no extension face in Emacs.
      ;;--------------------------------------------------------------
      (let* ((row-end (+ line-start (string-length line-string)))
             (mark (text-editor-mark ed))
             (point (text-editor-get-cursor ed))
             (region-start (and mark (min point mark)))
             (region-end (and mark (max point mark))))
        (and (< (string-length display) width)
             (region-face-active? ed)
             region-start
             region-end
             (<= region-start row-end)
             (< row-end region-end)
             (< row-end (text-editor-char-count ed))
             (region-face-at-position? ed row-end)
             ;; The region face's :extend fills newline space even in the
             ;; monochrome spec, where :extend itself is unspecified and
             ;; inverse-video is the visible TTY attribute.
             (let* ((attrs (merge-face-ref 'region
                                           (merge-face-vectors
                                            (face-realized-attributes 'default)
                                            (face-attributes-empty))))
                    (extend (attribute-value attrs ':extend))
                    (inverse (attribute-value attrs ':inverse-video))
                    (attribute (face-at-buffer-position ed (- row-end 1))))
               (and (or (and (not (eq? extend *undefined-face-attribute*))
                             extend)
                        (and (not (eq? inverse *undefined-face-attribute*))
                             inverse))
                    (not (= attribute 0))
                    attribute)))))

    (define (region-face-active? ed)
      (and (buffer-local-value ed 'transient-mark-mode
                               (*transient-mark-mode*))
           (buffer-local-value ed 'mark-active #f)
           (text-editor-mark ed)))

    (define (region-face-at-position? ed position)
      ;; Whether POSITION is covered by ED's active region. GNU Emacs
      ;; redisplay merges the `region' face while the mark is active and
      ;; transient-mark-mode is enabled; the region is [min(mark, point),
      ;; max(mark, point)). Read ED directly, as redisplay does for the
      ;; buffer belonging to the window it is drawing.
      ;;--------------------------------------------------------------
      (and (buffer-local-value ed 'transient-mark-mode
                               (*transient-mark-mode*))
           (buffer-local-value ed 'mark-active #f)
           (let ((mark (text-editor-mark ed)))
             (and mark
                  (let* ((point (text-editor-get-cursor ed))
                         (beginning (min mark point))
                         (end (max mark point)))
                    (and (>= position beginning)
                         (< position end)))))))

    (define (face-at-buffer-position ed position)
      ;; The ncurses attribute number for the face in effect at POSITION
      ;; in ED: GNU Emacs's `face_at_buffer_position'. The `face' text
      ;; property there - a face name, a property list, or a list of
      ;; either - is merged with the `default' face and folded down to
      ;; what the terminal can draw. `xfaces.c' merges overlays after the
      ;; text property; the active region face follows those in Emacs's
      ;; redisplay pipeline, and is merged here after the property face.
      ;;
      ;; Emacs caches the realized face against the position, because
      ;; this runs per character; a cache is worth adding when the
      ;; renderer starts asking per character rather than per run.
      ;;--------------------------------------------------------------
      (let ((attrs
             (merge-face-ref (get-text-property position 'face ed)
                             (merge-face-vectors
                              (face-realized-attributes 'default)
                              (face-attributes-empty)))))
        (tty-face-attribute
         (realize-tty-face
          (if (region-face-at-position? ed position)
              (merge-face-ref 'region attrs)
              attrs)))))

    (define (draw-match row x0 line display-string line-start len start end
                        point width)
      ;; Draw the part of the search match [START, END) that falls on this
      ;; line over the text already drawn there: in reverse video when
      ;; point is inside the match (GNU Emacs's `isearch' face) and in
      ;; bold otherwise (`lazy-highlight'). ROW is the screen row and X0
      ;; the screen column the window's text starts at.
      ;;--------------------------------------------------------------
      (let* ((col (max 0 (- start line-start)))
             (to (min len (- end line-start)))
             (x (display-column-of line col))
             (y (display-column-of line to)))
        (when (and (< x width) (< x y))
          (let ((attribute
                 (face->attribute
                  (if (and (<= start point) (<= point end))
                      'isearch 'lazy-highlight))))
            (attr-on! (stdscr) attribute)
            (addstr (stdscr)
                    (substring display-string x
                               (min y (string-length display-string)))
                    #:y row #:x (+ x0 x))
            (attr-off! (stdscr) attribute)))))

    (define (highlight-matches window row line display-string line-start width
                               pattern case-fold?)
      ;; Draw the search matches that fall on this line over the line that
      ;; has just been drawn, so that what was found can be seen.
      ;;
      ;; The matching is done on the line's own text rather than through
      ;; the buffer: a buffer search re-reads the text from where it
      ;; starts, and a screenful of rows each searching a large buffer
      ;; costs far more than the drawing is worth - enough to look like a
      ;; hang. Only matches that lie wholly within the line are drawn, so
      ;; a search string containing a line break (typed as C-j) finds its
      ;; match and moves point, but nothing is highlighted for it.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (row (+ row (window-top window)))
             (x0 (window-left window))
             (len (string-length line))
             (point (text-editor-get-cursor ed))
             (plen (string-length pattern)))
        (let loop ((at 0))
          (let ((found (string-search-forward line pattern at case-fold?)))
            (when (and found (<= (+ found plen) len))
              (draw-match row x0 line display-string line-start len
                          (+ line-start found) (+ line-start found plen)
                          point width)
              ;; on to the next match, starting inside this one so that
              ;; overlapping matches are found too, as a repeated search
              ;; finds them
              (loop (+ 1 found)))))))

    (define (cursor-screen-position window)
      ;; Where on the screen WINDOW's point belongs, as a pair, or #f
      ;; when it is scrolled out of view. In frame coordinates: the
      ;; window's own rows start below its top.
      ;;
      ;; It is the *window's* point that is placed, and only the
      ;; selected window shows a cursor - a terminal has one cursor, as
      ;; GNU Emacs draws only the selected window's.
      ;;
      ;; Point is always on a line the buffer really has - the engine
      ;; reports the end of a buffer whose last line has no break after
      ;; it as the end of that line, not as an empty line past it (see
      ;; `TEXT-EDITOR-INDEX-LINE-OFFSET'), which is where GNU Emacs puts
      ;; `point-max' too. A line break at the end of the buffer *does*
      ;; start an empty line, and that line gets a row of its own.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (line (text-editor-cursor-line ed))
             (column (text-editor-cursor-column ed))
             (line-string (ncurses-line-string ed line))
             (width (window-body-width window))
             (vheight (window-body-height window))
             (screen-row (- line (window-top-line window))))
        (when (and line-string
                   (>= screen-row 0) (< screen-row vheight))
          (cons (+ screen-row (window-top window))
                (+ (window-left window)
                   (min (current-line-display-column ed column)
                        (- width 1)))))))

    (define (render-window! window)
      ;; Draw one window: its rows of text within its rectangle, then its
      ;; mode line along its last row.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (width (window-body-width window))
             (x0 (window-left window))
             (vheight (window-body-height window))
             (border (and (window-right-border? window) (+ x0 width)))
             (highlight (*search-highlight*)))
        ;; rows of text. Each row's line starts LINE-START characters
        ;; into the buffer, which is what lets a search match be found in
        ;; buffer terms and then drawn in screen terms.
        (let loop ((row 0) (line-start 0))
          (when (< row vheight)
            (let* ((line-index (+ (window-top-line window) row))
                   (line-string (ncurses-line-string ed line-index)))
              (when line-string
                (let ((display (expand-line-display line-string width)))
                  (draw-line! ed line-start line-string display
                              (+ row (window-top window)) x0 width)
                  ;; the characters the current search matched, drawn over
                  ;; the line: the match point is in reverse video (GNU
                  ;; Emacs's `isearch' face) and the other matches in view
                  ;; in bold (`lazy-highlight')
                  (when highlight
                    (highlight-matches window row line-string display
                                       line-start width (car highlight)
                                       (cdr highlight)))))
              (loop (+ 1 row)
                    (+ line-start
                       (or (line-outer-size ed line-index) 0)))
              )))
        ;; the mode line, on the window's last row. The face is Emacs's
        ;; `mode-line' for the selected window and `mode-line-inactive'
        ;; for the others - and on a terminal `mode-line' is
        ;; `:inverse-video t', which is what this used to hardcode.
        (let ((attribute (face->attribute (if (eq? window (selected-window))
                                              'mode-line
                                              'mode-line-inactive))))
          (attr-on! (stdscr) attribute)
          (addstr (stdscr)
                  (pad-line (truncate-line (mode-line-string window) width) width)
                  #:y (+ (window-top window) (window-height window) -1)
                  #:x x0)
          (attr-off! (stdscr) attribute))
        ;; the vertical border between this window and the one to its
        ;; right: GNU Emacs draws it down every row of the windows,
        ;; their mode lines included
        (when border
          (let loop ((row (window-top window))
                     (end (+ (window-top window) (window-height window))))
            (when (< row end)
              (addstr (stdscr) "|" #:y row #:x border)
              (loop (+ 1 row) end))))))

    (define (render! frame)
      ;; Draw every window, then the echo area, then place the terminal
      ;; cursor at the selected window's point. Each window has its own
      ;; mode line, as GNU Emacs gives each window one; the echo area
      ;; belongs to the frame and is drawn last, over the bottom row.
      ;;--------------------------------------------------------------
      (sync-frame-size! frame)
      (let ((width (frame-width frame))
            (height (frame-height frame))
            ;; the *leaves*: a window that holds children shows no buffer
            ;; and has no mode line of its own, so what is drawn is the
            ;; windows at the bottom of the tree
            (windows (window-list frame)))
        (erase (stdscr))
        ;; Only the selected window is scrolled to show its point here:
        ;; it is the one point moves in, and its buffer is the one
        ;; commands act on. A window that is not selected keeps the view
        ;; it had, as GNU Emacs leaves a window's start alone until it
        ;; is displayed with its own point.
        (let ((selected (ncurses-frame-selected-window frame)))
          (when selected (scroll-to-cursor! selected)))
        (for-each render-window! windows)
        ;; Echo area: the minibuffer when one is active, exactly as GNU
        ;; Emacs draws it (the minibuffer *is* the echo area while it is
        ;; being read), otherwise whatever message is pending.
        (let ((reading (*echo-area-buffer*)))
          (cond
           ;; While a minibuffer is being read its line is the prompt and
           ;; what has been typed, with any pending message appended after
           ;; it - which is what Emacs's `minibuffer-message' does, and it
           ;; is where the completion candidates have to go or they would
           ;; hide the very text being completed.
           ;;
           ;; The buffer and its prompt come from the frame, which is
           ;; where GNU Emacs keeps them too (`echo_area_buffer[0]', and
           ;; the prompt as text in that buffer). Nothing here knows what
           ;; a minibuffer is: it draws a buffer that happens to have a
           ;; prompt beside it, which is what the echo area is.
           (reading
            (addstr (stdscr)
                    (truncate-line (string-append (or (*echo-area-prompt*) "")
                                                  (text-editor-to-string reading)
                                                  (ncurses-frame-message frame))
                                   width)
                    #:y (- height 1) #:x 0))
           (else
            (addstr (stdscr)
                    (truncate-line (ncurses-frame-message frame) width)
                    #:y (- height 1) #:x 0))))
        ;; force a full repaint: partial-update optimizations (scroll
        ;; regions, insert/delete character) desync the physical
        ;; terminal when lines merge
        (clearok! (stdscr) #t)
        ;; Place the terminal cursor: in the minibuffer while one is
        ;; active (Emacs's `cursor-in-echo-area'), else at the selected
        ;; window's point - the only window whose cursor is drawn, there
        ;; being one cursor on a terminal.
        (let ((reading (*echo-area-buffer*)))
          (if reading
              ;; At point in the input, where Emacs's `cursor-in-echo-area'
              ;; leaves it: a message is shown after the input, and it must
              ;; not drag the cursor along with it - a long one (the
              ;; completion candidates, say) would pin the cursor to the
              ;; right edge of the screen whatever point did.
              (move (stdscr) (- height 1)
                    (min (+ (string-length (or (*echo-area-prompt*) ""))
                            (text-editor-cursor-column reading))
                         (- width 1)))
              (let ((selected (ncurses-frame-selected-window frame)))
                (when selected
                  (let ((at (cursor-screen-position selected)))
                    (when at (move (stdscr) (car at) (cdr at))))))))
        (refresh (stdscr))
        ))

    ))
