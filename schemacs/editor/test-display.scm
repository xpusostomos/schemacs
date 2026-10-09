(define-library (schemacs editor test-display)
  ;; A display with nothing behind it: the object a test uses when it
  ;; needs *a* display and does not care which one.
  ;;
  ;; Three suites were already doing this by borrowing a front end, each
  ;; with a comment saying so - `faces-tests.scm' and
  ;; `ncurses-editor-tests.scm' subclassed `<tty-display>' ("a terminal
  ;; object with nothing behind it - no curses is started"), and
  ;; `mouse-tests.scm' subclassed `<pgtk-display>' for its pixel
  ;; geometry. That is what put a front end's library in the *editor's*
  ;; test files, which is the one thing the platform split is supposed to
  ;; prevent. This is that object, said once.
  ;;
  ;; What it answers:
  ;;
  ;;   * the geometry is *fields* - `screen-size', `column-width',
  ;;     `line-height', `display-color-cells' - so a test can be a 24x80
  ;;     terminal (1x1 per character, as Emacs's `make_terminal_frame'
  ;;     makes it) or a window system's pixels, and the redisplay's
  ;;     arithmetic can be exercised either way;
  ;;   * `write-glyphs!' records what was drawn instead of drawing it,
  ;;     which is also useful in its own right: a test can ask what the
  ;;     redisplay wrote;
  ;;   * `read-input-event' answers the events a test has *scripted*, in
  ;;     order, and `#f' when they run out - which is what a timed-out
  ;;     read answers, so a script that ends is a read that timed out;
  ;;   * `key-event->key' names a *keycode* only as far as the terminal
  ;;     does the same thing to it, and no further. Naming a keycode is
  ;;     the *terminal's* table (`term.sld's `function-key-names''), so a
  ;;     test that feeds an ncurses keycode and asserts its name is
  ;;     testing the terminal and belongs with the terminal, not here.
  ;;
  ;;     **But a character is not a keycode, and it is normalised to its
  ;;     integer here** - the same clause the terminal has, for the same
  ;;     reason. `make_lispy_event' for a terminal is `keyboard.c:8301':
  ;;     "buf.kind = ASCII_KEYSTROKE_EVENT; buf.code = cbuf[i];" - *the
  ;;     byte is the event*, and `term.sld' says so with
  ;;     `((char? ev) (char->integer ev))'. Emacs has no character type
  ;;     at all (`?a' *is* 97), so a test written in the Emacs idiom
  ;;     feeds `(integer->char 21)' for `C-u' and `#\a' for `a', which is
  ;;     exactly what the terminal's display is given by `getch'.
  ;;
  ;;     Leaving them as characters is not a stub that draws nowhere, it
  ;;     is a stub that answers a value no display produces: a terminal
  ;;     hands up the byte *21*, and Emacs has no character type for it to
  ;;     be a character of. `keymap-index' does read a character as the
  ;;     event its code point names, so the stub is not fatal today - but a
  ;;     test written in the Emacs idiom feeds the integer, and one that
  ;;     feeds a character is asserting on this tree's own convenience
  ;;     rather than on the terminal's behaviour.
  ;;
  ;; The selection generics are not implemented here: `dispnew.sld' gives
  ;; `<display>' defaults that answer nil, which is what a display with no
  ;; clipboard has to say, and `select-tests.scm' subclasses this to hold
  ;; one.

  (import
    (scheme base)
    (oop goops)
    ;; The face-token interning below is Guile's hash table, as
    ;; `(schemacs editor minibuf)' uses it for the same job.
    (only (guile) hash-ref hash-set! make-hash-table)
    (only (schemacs editor dispnew)
          <display>
          clear-frame-area! column-width display-color-cells
          draw-window-cursor! flush-display! key-event->key line-height
          read-input-event realize-face resume-display! screen-size
          suspend-display! update-window-begin! update-window-end!
          write-glyphs!))

  ;; `(make <test-display> #:rows 24)' is the constructor - GOOPS gives
  ;; `<class>' and keyword arguments rather than the `make<...>' names the
  ;; R7RS records in this tree have - and `(is-a? ...)' the predicate.
  (export <test-display>
          test-display-rows set!test-display-rows
          test-display-columns set!test-display-columns
          test-display-line-height set!test-display-line-height
          test-display-column-width set!test-display-column-width
          test-display-color-cells set!test-display-color-cells
          test-display-script set!test-display-script
          test-display-glyphs set!test-display-glyphs
          test-display-cursor set!test-display-cursor)

  (begin

    (define-class <test-display> (<display>)
      ;; A terminal's geometry by default - `(cols) x (lines)' with one
      ;; character to a cell - so a suite that says nothing gets what
      ;; `ncurses-editor-tests.scm' used to borrow a `<tty-display>' for.
      (rows        #:init-value 24 #:init-keyword #:rows
                   #:accessor test-display-rows
                   #:setter set!test-display-rows)
      (columns     #:init-value 80 #:init-keyword #:columns
                   #:accessor test-display-columns
                   #:setter set!test-display-columns)
      (line-height #:init-value 1 #:init-keyword #:line-height
                   #:accessor test-display-line-height
                   #:setter set!test-display-line-height)
      (column-width #:init-value 1 #:init-keyword #:column-width
                    #:accessor test-display-column-width
                    #:setter set!test-display-column-width)
      (color-cells #:init-value 8 #:init-keyword #:color-cells
                   #:accessor test-display-color-cells
                   #:setter set!test-display-color-cells)
      ;; The events `read-input-event' answers with, in order; and what
      ;; has been drawn, most recent first.
      (script      #:init-value '() #:init-keyword #:script
                   #:accessor test-display-script
                   #:setter set!test-display-script)
      (glyphs      #:init-value '() #:accessor test-display-glyphs
                   #:setter set!test-display-glyphs)
      ;; The last cursor position asked for, as `(ROW COLUMN TYPE)'.
      (cursor      #:init-value #f #:accessor test-display-cursor
                   #:setter set!test-display-cursor))

    (define-method (screen-size (d <test-display>))
      ;; The tty's own answer shape: a cons of columns and rows
      ;; (`term.sld''s `(cons (cols) (lines))').
      ;;--------------------------------------------------------------
      (cons (test-display-columns d) (test-display-rows d)))

    (define-method (column-width (d <test-display>)) (test-display-column-width d))
    (define-method (line-height (d <test-display>)) (test-display-line-height d))
    (define-method (display-color-cells (d <test-display>)) (test-display-color-cells d))

    (define-method (write-glyphs! (d <test-display>) text y x attribute)
      ;; Nothing is drawn anywhere; the text and where it would have gone
      ;; are kept, newest first.
      ;;--------------------------------------------------------------
      (set!test-display-glyphs
       d (cons (list text y x attribute) (test-display-glyphs d))))

    (define-method (clear-frame-area! (d <test-display>))
      (set!test-display-glyphs d '()))

    (define-method (update-window-begin! (d <test-display>)) #t)
    (define-method (update-window-end! (d <test-display>)) #t)

    (define-method (draw-window-cursor! (d <test-display>) row column cells
                                        type width text token)
      (set!test-display-cursor d (list row column type)))

    (define-method (flush-display! (d <test-display>)) #t)
    (define-method (suspend-display! (d <test-display>)) #t)
    (define-method (resume-display! (d <test-display>)) #t)

    (define-method (read-input-event (d <test-display>) timeout)
      ;; The next scripted event, or #f when the script has run out -
      ;; which is the answer a read that timed out gives, so a test that
      ;; wants a timeout scripts nothing (or lets the script run out).
      ;;--------------------------------------------------------------
      (let ((script (test-display-script d)))
        (if (null? script)
            #f
            (begin (set!test-display-script d (cdr script))
                   (car script)))))

    (define-method (key-event->key (d <test-display>) ev)
      ;; A character is a byte is an event, which is the terminal's first
      ;; clause (`term.sld') and the C's `buf.code = cbuf[i]'; anything
      ;; else the test fed is already the event the tests mean. See the
      ;; header: the terminal's keycode *table* is deliberately not here,
      ;; but this one step is not the table.
      ;;--------------------------------------------------------------
      (if (char? ev) (char->integer ev) ev))

    (define %face-tokens (make-hash-table))
    (define %next-face-token 0)

    (define-method (realize-face (d <test-display>) face-attrs)
      ;; **A token, and a number**, as both real displays answer: the
      ;; terminal interns to an ncurses attribute number (`term.sld`'s
      ;; `tty-face-attribute'), the GTK display to a drawing token
      ;; (`realize-face-token'). Equal attributes get the same token,
      ;; which is what makes two runs comparable, and the first one
      ;; realized - the default face, at startup - is 0.
      ;;
      ;; It used to hand FACE-ATTRS back unchanged, which reads as
      ;; reasonable for a display that draws nothing and is not: the
      ;; callers put the answer in a run as its ATTRIBUTE, compare runs
      ;; with `equal?' and tokens with `='.
      ;;--------------------------------------------------------------
      (or (hash-ref %face-tokens face-attrs)
          (let ((token %next-face-token))
            (set! %next-face-token (+ token 1))
            (hash-set! %face-tokens face-attrs token)
            token)))

    ))
