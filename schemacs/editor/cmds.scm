(define-library (schemacs editor cmds)
  ;; This library mirrors GNU Emacs's `cmds.c': the simple editing
  ;; commands and the one subroutine they run through.
  ;;
  ;; What is here so far is `self-insert-command' (`cmds.c:263') and
  ;; `internal-self-insert' (`cmds.c:312') beneath it, which is where
  ;; overwrite mode lives - the whole of the ` Ovwrt' behaviour is that
  ;; function's overwrite branch and nothing else.
  ;;
  ;; Not ported from `cmds.c': its other commands (`forward-char',
  ;; `backward-char', `newline', `delete-char', `kill-line', ...) still
  ;; live in `simple.sld', where the original author put them. They belong
  ;; here; moving them is its own piece of work, and this library is the
  ;; seat they will move to. Also not ported: the abbrev expansion at the
  ;; top of `internal_self_insert' (`expand-abbrev' and the
  ;; `no-self-insert' property), because `abbrev-mode' is not here, and
  ;; the `auto-fill-function' call after the insert, because auto fill is
  ;; not here either. Both are marked at the point they would go.

  (import
    (scheme base)
    (scheme char)
    (only (guile) format most-positive-fixnum)
    (only (schemacs editor character) char-width characterp)
    (only (schemacs editor buffer)
          buffer-overwrite-mode current-buffer)
    (only (schemacs editor editfns)
          char-after char-before delete-region goto-char insert
          line-beginning-position line-end-position point point-max)
    (only (schemacs editor indentc) current-column move-to-column)
    (only (schemacs editor command)
          define-command uarg->integer current-prefix-arg
          *last-command-event*)
    (only (schemacs editor engine)
          text-editor-delete-from-cursor text-editor-get-cursor
          text-editor-get-end-of-line
          text-editor-get-start-of-line text-editor-insert
          text-editor-move-cursor text-editor-point-min text-editor-point-max
          text-editor-set-cursor)
    )

  (export
   internal-self-insert
   backward-char beginning-of-line delete-char end-of-line forward-char
   self-insert-command self-insert-tab
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


    ;;------------------------------------------------------------------
    ;; The commands
    ;;------------------------------------------------------------------

    (define-command (self-insert-command count char)
      ;; GNU Emacs's `self-insert-command' (`cmds.c:263'). Its interactive
      ;; spec is
      ;;
      ;;   "(list (prefix-numeric-value current-prefix-arg)
      ;;          last-command-event)"
      ;;
      ;; - the character is **the event that invoked the command**, handed
      ;; to it as an argument, and the body is `internal_self_insert''s
      ;; one level up.
      ;;
      ;; **The character used to be re-derived here instead**, from the
      ;; chord in the frame's keymap lookup state, through
      ;; `keymap-index-to-char'. It worked, and it was a departure with
      ;; two costs: the command loop had to store the lookup state *before*
      ;; the lookup so that this command could still find it (a coupling
      ;; Emacs does not have, and there was a NOTE saying so), and a caller
      ;; that ran the command without a keymap lookup in progress got
      ;; nothing at all. `digit-argument' re-derived its digit the same
      ;; way, and the same one variable fixes both.
      ;;
      ;; Not carried: `translate_char (Vtranslation_table_for_input, c)',
      ;; because there is no `keyboard-translate-table' here (nor a
      ;; `translation-table-for-input' to consult); and
      ;; `call0 (Qundo_auto_amalgamate)', the undo amalgamation for a
      ;; repeated self-insert (`internal-self-insert' does the undo work
      ;; it can). `bitch_at_user' is `ding', which is not ported - see
      ;; `minibuffer.sld''s note about there being no bell - so the branch
      ;; below is silent where Emacs rings.
      "Insert the character you type.
Whichever character C you type to run this command is inserted.
The numeric prefix argument N says how many times to repeat the insertion.
Before insertion, `expand-abbrev' is executed if the inserted character does
not have word syntax and the previous character in the buffer does.
After insertion, `internal-auto-fill' is called if
`auto-fill-function' is non-nil and if the `auto-fill-chars' table has
a non-nil value for the inserted character.  At the end, it runs
`post-self-insert-hook'."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (*last-command-event*)))
      ;; "if (XFIXNUM (n) < 0) error ("Negative repetition argument %d", n)"
      ;; - one formatted string, so the count is in the message and not an
      ;; irritant. Measured: "Negative repetition argument -1".
      (when (< count 0)
        (error (format #f "Negative repetition argument ~a" count)))
      ;; "Barf if the key that invoked this was not a character."
      ;;
      ;; `characterp' is the C's `CHARACTERP', so this is false for a
      ;; *named* key - but it is true for things the C's own
      ;; `internal_self_insert' can still be handed and this tree cannot:
      ;; a raw eight-bit byte character (`#x3FFF80' to `#x3FFFFF', which
      ;; is what the top of `MAX_CHAR' is for) and a *modified* event like
      ;; `M-x' (134217752, also below `MAX_CHAR'). `internal_self_insert
      ;; (int c, ...)' takes the code and its first act is `CHAR_STRING
      ;; (c, str)', which makes bytes out of any of them.
      ;;
      ;; This tree's `internal-self-insert' takes a *Scheme character*, and
      ;; Guile has none above `#x10FFFF' (measured: `(integer->char
      ;; #x10FFFF)' is the last one that works and `#x110000' raises), so
      ;; those events do nothing here rather than erroring. Emacs inserts
      ;; their bytes. It is the same gap `buffer-text.scm' names as "a byte
      ;; character has no character to be" - and `M-x' cannot reach this
      ;; command from the keymap, since a char-table cannot be indexed by
      ;; an event with modifier bits.
      ;;
      ;; Measured: `(self-insert-command 1 (logior 134217728 ?x))' inserts
      ;; nothing in Emacs 31.1 either, by a route that is `translate_char'
      ;; and `CHAR_STRING''s rather than this one.
      (if (or (not (characterp char)) (> char #x10FFFF))
          #f
          (internal-self-insert (integer->char char) count)))

    ;; Not an Emacs command: Emacs binds C-i to
    ;; `indent-for-tab-command', which indents. This inserts a tab,
    ;; which is what a terminal's TAB does here until that is ported.
    (define-command (self-insert-tab count)
      "Insert N tab characters at point."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-insert (current-buffer) #\tab)
          (loop (+ 1 i)))))

    (define (%move-point n forward)
      ;; GNU Emacs's `move_point' (`cmds.c:40'), which `forward-char' and
      ;; `backward-char' below both are:
      ;;
      ;;     if (NILP (n)) XSETFASTINT (n, 1); else CHECK_FIXNUM (n);
      ;;     new_point = PT + (forward ? XFIXNUM (n) : - XFIXNUM (n));
      ;;     if (new_point < BEGV) { SET_PT (BEGV); xsignal0 (Qbeginning_of_buffer); }
      ;;     if (new_point > ZV)   { SET_PT (ZV);   xsignal0 (Qend_of_buffer); }
      ;;     SET_PT (new_point);
      ;;
      ;; Three things there, and until 2026-10-06 this tree had none of
      ;; them: N is *optional* and a nil N is 1; the move stops at the
      ;; boundary; and it then **signals** - "On reaching end or beginning
      ;; of buffer, stop and signal error" - so a command that runs off
      ;; the end fails with `end-of-buffer' rather than quietly clamping.
      ;; The tree's `text-editor-move-cursor' clamps and says nothing.
      ;;
      ;; Emacs signals `beginning-of-buffer' and `end-of-buffer'; the
      ;; messages their error symbols carry, measured, are "Beginning of
      ;; buffer" and "End of buffer".
      ;;--------------------------------------------------------------
      (let ((n (if (or (not n) (eq? n #f)) 1 n)))
        (let* ((ed (current-buffer))
               (pt (text-editor-get-cursor ed))
               (new (if forward (+ pt n) (- pt n)))
               (low (text-editor-point-min ed))
               (high (text-editor-point-max ed)))
          (cond
           ((< new low)
            (text-editor-set-cursor ed low)
            (error "Beginning of buffer"))
           ((> new high)
            (text-editor-set-cursor ed high)
            (error "End of buffer"))
           (else
            (text-editor-set-cursor ed new)
            #f)))))

    (define-command (forward-char . rest)
      ;; GNU Emacs's `forward-char' (`cmds.c:69'), whose DEFUN is
      ;; `(0, 1, "^p")' - **N is optional**, and "If N is omitted or nil,
      ;; move point 1 character forward". It was a required parameter
      ;; here, so `(forward-char)' was a "Wrong number of arguments"
      ;; error where Emacs moves one character - which is how the bug was
      ;; found, by the backtrace port calling `(forward-char)' the way
      ;; Emacs's `debugger-setup-buffer' does.
      "Move point N characters forward (backward if N is negative).
On reaching end or beginning of buffer, stop and signal error.
Interactively, N is the numeric prefix argument.
If N is omitted or nil, move point 1 character forward."
      (interactive "p")
      (%move-point (if (pair? rest) (car rest) #f) #t))

    (define-command (backward-char . rest)
      ;; ...and its mirror, `(0, 1, "^p")' the same way: it is
      ;; `(move_point (n, 0))', so every word of the above holds with the
      ;; sign turned round.
      "Move point N characters backward (forward if N is negative).
On attempt to pass beginning or end of buffer, stop and signal error.
Interactively, N is the numeric prefix argument.
If N is omitted or nil, move point 1 character backward."
      (interactive "p")
      (%move-point (if (pair? rest) (car rest) #f) #f))

    (define-command (beginning-of-line . rest)
      ;; GNU Emacs's `beginning-of-line' (`cmds.c:148'), whose DEFUN is
      ;; `(0, 1, "^p")' and which is
      ;;
      ;;     if (NILP (n)) XSETFASTINT (n, 1); else CHECK_FIXNUM (n);
      ;;     SET_PT (XFIXNUM (Fline_beginning_position (n)));
      ;;
      ;; - so the whole of it is the N-line arithmetic `line-beginning-
      ;; position' does, and the movement. Ours took **no argument at
      ;; all**, which made `(beginning-of-line 2)' an error *and* left the
      ;; behaviour out: N moves forward N - 1 lines first, and 0 and
      ;; negatives move back, which is `bol`'s `count - 1' scan
      ;; (`editfns.c:665').
      "Move point to beginning of current line (in the logical order).
With argument N not nil or 1, move forward N - 1 lines first.
If point reaches the beginning or end of buffer, it stops there."
      (interactive "p")
      (goto-char (line-beginning-position (if (pair? rest) (car rest) #f))))

    (define-command (end-of-line . rest)
      ;; ...and `(0, 1, "^p")' the same way, over `line-end-position'.
      ;;
      ;; The C's `while (1)' loop around it (`cmds.c:186') is the
      ;; intangible-text dance - "If we skipped over a newline that
      ;; follows an invisible intangible run..." - and there is no
      ;; intangibility or invisibility here for it to correct for.
      "Move point to end of current line (in the logical order).
With argument N not nil or 1, move forward N - 1 lines first.
If point reaches the beginning or end of buffer, it stops there."
      (interactive "p")
      (goto-char (line-end-position (if (pair? rest) (car rest) #f))))

    (define-command (delete-char count)
      "Delete N characters after point."
      (interactive "p")
      (text-editor-delete-from-cursor (current-buffer) count))

    ))
