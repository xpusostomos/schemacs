(define-library (schemacs editor cmds)
  ;; This library mirrors GNU Emacs's `cmds.c': the simple editing
  ;; commands and the one subroutine they run through.
  ;;
  ;; What is here so far is `internal-self-insert' (`cmds.c:312'), which
  ;; is where overwrite mode lives - the whole of the ` Ovwrt' behaviour
  ;; is this function's overwrite branch and nothing else.
  ;;
  ;; Not ported from `cmds.c': `self-insert-command' itself and its
  ;; neighbours (`forward-char', `backward-char', `newline',
  ;; `delete-char', `kill-line', ...) still live in `simple.sld', where
  ;; the original author put them. They belong here; moving them is its
  ;; own piece of work, and this library is the seat they will move to.
  ;; Also not ported: the abbrev expansion at the top of
  ;; `internal_self_insert' (`expand-abbrev' and the `no-self-insert'
  ;; property), because `abbrev-mode' is not here, and the
  ;; `auto-fill-function' call after the insert, because auto fill is
  ;; not here either. Both are marked at the point they would go.

  (import
    (scheme base)
    (scheme char)
    (only (guile) most-positive-fixnum)
    (only (schemacs editor character) char-width)
    (only (schemacs editor buffer)
          buffer-overwrite-mode current-buffer)
    (only (schemacs editor editfns)
          char-after char-before delete-region goto-char insert point
          point-max)
    (only (schemacs editor indentc) current-column move-to-column)
    )

  (export
   internal-self-insert
   )

  (begin

    (define (internal-self-insert c n)
      ;; GNU Emacs's `internal_self_insert' (`cmds.c:312'): "Insert N
      ;; times character C. If this insertion is suitable for direct
      ;; output (completely simple), return 0. A value of 1 indicates
      ;; this *might* not have been simple. A value of 2 means this did
      ;; things that call for an undo boundary."
      ;;
      ;; The return value is not read here: its two non-zero answers are
      ;; about undo amalgamation and hooks (`Qundo_auto__this_command_
      ;; amalgamating' and the `before/after-change-functions' test), and
      ;; neither is ported. It is answered anyway, because it is what the
      ;; function means.
      ;;
      ;; The overwrite branch in the middle is the whole of overwrite
      ;; mode. Two things about it are worth keeping in view because they
      ;; are easy to get wrong:
      ;;
      ;;   - it works by *moving point with `move-to-column'* and then
      ;;     asking how far it went. What has to be deleted is not simply
      ;;     N characters: it is however many characters it takes to
      ;;     cover the columns the new text will occupy, which is what
      ;;     makes overwriting a wide character with a narrow one (or the
      ;;     reverse) leave the rest of the line where it was.
      ;;   - it puts point back before doing anything (`SET_PT_BOTH (pos,
      ;;     pos_byte)'), because the move was a measurement and not a
      ;;     move.
      ;;
      ;; `Fchar_width' is `char-width', which is 0 for a newline, so the
      ;; `cwidth != 0' test is what makes a newline insert rather than
      ;; overwrite - as does the `c2 != '\n'' test for the character
      ;; already there.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer))
            (chars-to-delete 0)
            (spaces-to-insert 0)
            (hairy 0))
        (let ((overwrite (buffer-overwrite-mode ed)))
          (when (and overwrite (< (point) (point-max)))
            ;; "This is the character after point."
            (let ((c2 (char-after (point))))
              (cond
               ;; "Overwriting in binary-mode always replaces C2 by C."
               ((eq? overwrite 'overwrite-mode-binary)
                (set! chars-to-delete n))
               ;; "Overwriting in textual-mode doesn't always do that.
               ;; It inserts newlines in the usual way, and inserts any
               ;; character at end of line or before a tab if it doesn't
               ;; use the whole width of the tab."
               ((and (not (char=? c #\newline))
                     (not (char=? c2 #\newline))
                     (not (= (char-width c) 0)))
                (let ((cwidth (char-width c))
                      (curcol (current-column)))
                  ;; The C's overflow guard, `n <= (min (MOST_POSITIVE_
                  ;; FIXNUM, PTRDIFF_MAX) - curcol) / cwidth'. It exists
                  ;; so that `curcol + n * cwidth' cannot overflow; with
                  ;; exact integers it can only be reached by an absurd
                  ;; repeat count, but the guard is the C's and dropping
                  ;; it would be a departure.
                  (when (<= n (quotient (- most-positive-fixnum curcol) cwidth))
                    (let* ((pos (point))
                           ;; "Column the cursor should be placed at
                           ;; after this insertion."
                           (target-clm (+ curcol (* n cwidth)))
                           ;; "The actual cursor position after the trial
                           ;; of moving to column TARGET_CLM. It is
                           ;; greater than TARGET_CLM if the TARGET_CLM
                           ;; is middle of multi-column character. In
                           ;; that case, the new point is set after that
                           ;; character."
                           (actual-clm (move-to-column target-clm #f)))
                      (set! chars-to-delete (- (point) pos))
                      (when (> actual-clm target-clm)
                        ;; "We will delete too many columns. Let's fill
                        ;; columns by spaces so that the remaining text
                        ;; won't move."
                        (let ((before (char-before)))
                          (if (and before (char=? before #\tab))
                              ;; "Rather than add spaces, let's just keep
                              ;; the tab."
                              (set! chars-to-delete (- chars-to-delete 1))
                              (set! spaces-to-insert (- actual-clm target-clm)))))
                      ;; the measurement is over: put point back
                      (goto-char pos))))))))
          ;; `expand-abbrev' and its `no-self-insert' property go here in
          ;; the C; `abbrev-mode' is not ported.
          (if (> chars-to-delete 0)
              ;; `replace_range (PT, to, string, ...)' followed by
              ;; `Fforward_char (n)': the region is replaced by the
              ;; character repeated N times and the padding spaces, and
              ;; point ends *after the N characters* and before the
              ;; spaces - which is what leaves the cursor where the typed
              ;; character is.
              (let* ((start (point))
                     (string (string-append (make-string n c)
                                            (if (> spaces-to-insert 0)
                                                (make-string spaces-to-insert #\space)
                                                ""))))
                (delete-region start (+ start chars-to-delete))
                (goto-char start)
                (insert string)
                (goto-char (+ start n)))
              (when (> n 0)
                (insert (make-string n c))))
          ;; `internal-auto-fill' goes here in the C; auto fill is not
          ;; ported. Neither is `post-self-insert-hook', which is the
          ;; last thing the C runs.
          hairy)))

    ))
