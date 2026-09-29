(define-library (schemacs editor dispnew)
  ;; This library mirrors GNU Emacs's `dispnew.c' and, with it, the
  ;; `struct redisplay_interface' of `dispextern.h': the interface
  ;; between the redisplay and a display. Emacs's redisplay (xdisp.c)
  ;; produces glyphs and never draws; dispnew.c's update machinery
  ;; hands them to a display through a per-display vtable of function
  ;; pointers - `write_glyphs', `update_window_begin_hook',
  ;; `draw_window_cursor', `flush_display' and the rest. The vtable is
  ;; expressed here as GOOPS generics dispatching on a display object,
  ;; `<display>'; each display type - the text terminal's
  ;; `<tty-display>', a graphics one later - answers the generics with
  ;; methods. The wording of the departure (a Scheme object system
  ;; where Emacs has a C struct) is in NCURSES-PLAN.txt.
  ;;
  ;; The generics are what a display provides, and the only way the
  ;; editor touches one: xdisp draws through these, keyboard reads
  ;; input through `read-input-event', and the platform sets
  ;; `current-display' when it opens a display. The redisplay never
  ;; imports a display driver.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.
  (import (oop goops) (scheme base))

  (export
   <display>
   current-display
   write-glyphs!
   clear-frame-area!
   update-window-begin!
   update-window-end!
   draw-window-cursor!
   flush-display!
   read-input-event
   realize-face
   screen-size
   display-color-cells
   )

  (begin

    (define-class <display> ()
      ;; The kind of thing a display is. A display answers the generics
      ;; below; the class itself carries no data - everything a display
      ;; knows comes back through its methods - so it is the type the
      ;; generics dispatch on, with `eq?' identity (`#:pure').
      ;;--------------------------------------------------------------
      #:pure #t)

    (define current-display (make-parameter #f))
    ;; ^ The display the editor is running on: Emacs's `terminal'. The
    ;; platform sets it when it opens (`term.c''s `init_tty' makes the
    ;; terminal the editor's terminal); it is `#f' before any is open,
    ;; which a display call from a non-display context (a unit test
    ;; calling the redisplay's helpers) crashes on, loudly.

    ;;----------------------------------------------------------------
    ;; The generics: what the redisplay needs of a display
    ;;
    ;; Named after the operations of Emacs's `struct redisplay_interface'
    ;; where one exists, and after the terminal calls they stand for
    ;; otherwise. All are single-dispatch on the display; the window or
    ;; buffer being drawn is an argument, never a dispatch key.
    ;;------------------------------------------------------------------

    (define-generic write-glyphs!)
    ;; Draw a run of TEXT at row Y, column X with ATTRIBUTE: the cells
    ;; xdisp has decided are one face. Emacs's `write_glyphs'.
    ;; `(write-glyphs! display text y x attribute)'.

    (define-generic clear-frame-area!)
    ;; Clear the whole display surface, ready for the frame drawn next.
    ;; Emacs's `clear_frame_area' over the frame's whole rectangle.
    ;; `(clear-frame-area! display)'.

    (define-generic update-window-begin!)
    ;; A window is about to be updated: the begin half of Emacs's
    ;; `update_window_begin_hook'. `(update-window-begin! display)'.

    (define-generic update-window-end!)
    ;; The window being updated is done: Emacs's
    ;; `update_window_end_hook'. `(update-window-end! display)'.

    (define-generic draw-window-cursor!)
    ;; Put the display cursor at ROW, COLUMN (frame coordinates), which
    ;; is where input shows itself going. Emacs's `draw_window_cursor'.
    ;; `(draw-window-cursor! display row column)'.

    (define-generic flush-display!)
    ;; Everything drawn since the last flap is now what the display
    ;; shows. Emacs's `flush_display'. `(flush-display! display)'.

    (define-generic read-input-event)
    ;; The next input event, or #f when there is none in TIMEOUT
    ;; milliseconds - a negative TIMEOUT blocks. An event's meaning is
    ;; the display's business; a keyboard reads a char, a mouse a
    ;; button. `(read-input-event display timeout)'.

    (define-generic realize-face)
    ;; The display's token for a face whose realized attributes are
    ;; FACE-ATTRS: what the display will need to draw it. The token is
    ;; opaque to the redisplay, which only hands it back to
    ;; `write-glyphs!'. Emacs's face realization (`realize_face' in
    ;; xfaces.c) is per display for the same reason.
    ;; `(realize-face display face-attrs)'.

    (define-generic screen-size)
    ;; The display's size in rows and columns, as `(ROWS . COLUMNS)'.
    ;; `(screen-size display)'.

    (define-generic display-color-cells)
    ;; How many colours the display can show at once - zero for a
    ;; monochrome one. `(display-color-cells display)'.

    ;;----------------------------------------------------------------
    ))