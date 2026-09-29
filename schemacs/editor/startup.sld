(define-library (schemacs editor startup)
  ;; This library mirrors GNU Emacs's `startup.el`: what the editor does
  ;; between being started and handing control to the command loop - the
  ;; files named on the command line, and the windows they are shown in.
  ;;
  ;; What `startup.el' is mostly about is not here. Its bulk is the
  ;; option table (`--eval', `-L', `-Q', the long-option abbreviations),
  ;; the `*scratch*' buffer's banner, the splash screen with its logo and
  ;; its `about-emacs' links, and the dumping and site-file machinery.
  ;; This is the part a command line of file names goes through:
  ;; `command-line-1''s `process-file-arg', which visits each file, and
  ;; the `let' at the end of `command-line-1' that decides which windows
  ;; to put them in.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (only (schemacs editor files) find-file-noselect)
    (only (schemacs editor buff-menu) list-buffers)
    (only (schemacs editor window)
          display-buffer other-window switch-to-buffer
          switch-to-buffer-other-window))

  (export
   command-line-1
   command-line-1--display
   )

  (begin

    (define (command-line-1--display displayable-buffers)
      ;; Show the buffers the command line named: the `let' at the end of
      ;; GNU Emacs's `command-line-1', whose `displayable-buffers' is
      ;; built with the files pushed onto its front as they are visited.
      ;; It therefore reads backwards, and `(car displayable-buffers)' is
      ;; the *last* file named - which is the one the selected window
      ;; shows, so `emacs a b c' leaves `c' in front of you.
      ;;
      ;;   1 buffer   it fills the frame, and there is one window
      ;;   2 buffers  the frame is split; the last file is above, the
      ;;              first below, and the top window is selected
      ;;   3 or more  the frame is split; the last file is above and the
      ;;              Buffer Menu is below. The files in between are
      ;;              visited as buffers but not shown - Emacs leaves
      ;;              them for `C-x b' - and the menu is what `list-buffers'
      ;;              does, which finds the frame already has a window to
      ;;              put it in rather than splitting again.
      ;;
      ;; Every step is `switch-to-buffer', `switch-to-buffer-other-window'
      ;; and `other-window', which is what Emacs's own code calls.
      ;;--------------------------------------------------------------
      (let ((count (length displayable-buffers)))
        (when (> count 0)
          (switch-to-buffer (car displayable-buffers)))
        (cond
         ;; Two buffers; display them both.
         ((= count 2)
          (switch-to-buffer-other-window (cadr displayable-buffers))
          ;; Focus on the first buffer.
          (other-window -1))
         ;; More than two buffers: show the first in the other window and
         ;; then walk the rest of them through *that* window, each one
         ;; recording itself as it goes, so that the buffer list - which is
         ;; what the Buffer Menu shows in a moment - ends up in the reverse
         ;; of the command line: `emacs a b c' leaves c, b, a. That is the
         ;; order Emacs's own comment here describes, and the one that
         ;; makes `next-buffer' walk back up the command line.
         ((> count 2)
          (let ((rest (reverse (cdr displayable-buffers))))
            (switch-to-buffer-other-window (car rest))
            (for-each (lambda (buffer) (switch-to-buffer buffer))
                      (cdr rest))
            ;; Focus on the first buffer.
            (other-window -1))))
        (when (> count 2)
          (list-buffers))))

    (define (command-line-1 args)
      ;; GNU Emacs's `command-line-1', for a command line of file names:
      ;; visit each one into its own buffer - Emacs's `process-file-arg',
      ;; which is `find-file-noselect' - and then show them.
      ;;
      ;; ARGS is the file names, in command-line order. Nothing comes back:
      ;; what the caller wanted has happened to the frame's windows.
      ;;--------------------------------------------------------------
      (let ((displayable-buffers '()))
        (for-each
         (lambda (name)
           (set! displayable-buffers
                 (cons (find-file-noselect name) displayable-buffers)))
         args)
        (command-line-1--display displayable-buffers)))

    ))
