# Departures from GNU Emacs

Every place this tree knowingly does something GNU Emacs does not, or does
the same thing another way. Each entry says what Emacs does (with the file
and line), what this tree does instead, and what closing it would take.
Entries are added as they are found or made; the goal is that a future
session can pick one up without re-deriving it.

The rule they are all measured against: **port Emacs, function for
function**. A departure on this list is a debt, not a licence.

---

## Faces

### One set of realized attributes, not one per frame

- **Emacs**: attributes are realized per frame. `struct frame` carries a
  face cache (`FRAME_FACE_CACHE`, `xfaces.c`), `realize_face` works one
  frame at a time, `face-new-frame-defaults` holds the values a frame not
  yet made would get, and `face-attribute`'s FRAME argument selects which.
  A frame with no font yet, or a GUI frame and a tty frame at once, each
  have their own answer for the same face.
- **Here**: `(schemacs editor faces)` keeps one alist, `*face-attributes*`.
  The FRAME argument is accepted and ignored, and `(face-attribute FACE
  ATTRIBUTE t)` - Emacs's "the defaults for new frames" - answers the
  realized value instead. Documented in the library's header as deviation 1.
- **Consequences**: `face-set-after-frame-default` cannot merge a frame's
  own defaults; `custom--frame-color-default` skips its first test (below);
  the `default` face's reset has to be gated on there being any frame at
  all (below); a second frame on a different display cannot have a
  different font.
- **Closing it**: a per-frame attribute alist on `<frame>` with a lazy
  realize, `realize_face` per frame, and every reader told which frame it
  asks about - `faces.scm`, `frame.scm`, `xdisp.scm`'s face lookup and both
  front ends. Roughly 400-600 lines, and it is the root of three of the
  entries below.

### `face-set-after-frame-default` lives in `frame.scm`

- **Emacs**: `faces.el:2274`.
- **Here**: `frame.scm`, because it reads the frame's parameters and
  `frame.scm` sits above `faces.scm`. The same seam that put
  `locate-file-internal` in `fileio.scm` and `frame-or-buffer-changed-p`
  in `menu-bar.scm`. Behaviour is the same; only the file differs.
- **Closing it**: move `param_alist` and its readers below `faces.scm`, or
  a parameter seam for every read. Not worth it on its own.

### `custom--frame-color-default` skips the Elisp's first test

- **Emacs** (`custom.el:1727`): `(face-attribute 'default ATTRIBUTE t)` -
  the *defaults for new frames* - then the frame's X resource, then the
  two constants.
- **Here**: there is no "defaults for new frames" set (see above), so the
  first test cannot be asked without answering the realized colour, which
  is the very thing being replaced. Measured on Emacs 31.1:
  `(face-attribute 'default :background t)` is `unspecified` with a theme
  loaded *and* after disabling it, so the Elisp falls through to the two
  constants as well. There is no X resource database here either.
- **Closing it**: per-frame attributes (first entry).

### No `reverse` frame parameter

- **Emacs**: `tty-handle-reverse-video` (`faces.el:2307`) swaps the
  frame's foreground and background parameters for a terminal frame with a
  `reverse` parameter, and `face-spec-reset-face` (`faces.el:1669`) reads
  `(frame-parameter nil 'reverse)` when it picks `"unspecified-fg"` vs
  `"unspecified-bg"`.
- **Here**: `face-spec-reset-face` always uses the ordinary pair. Nothing
  in this tree creates a frame with `reverse` set, so nothing is visible
  today; it is a missing piece of the model rather than a chosen one.
- **Closing it**: port `tty-handle-reverse-video`, call it where the
  terminal frame is created (the tty front end, as Emacs's
  `tty-create-frame-with-faces` does), and give `faces.scm` the parameter -
  a seam, since `faces.scm` sits below `frame.scm`. ~30 lines.

### `face-spec-reset-face`'s `default` branch runs only when a display exists

- **Emacs**: the reset is reached per frame, so there is always a frame
  when its `default` branch runs.
- **Here**: the standard faces are realized while the libraries load,
  which is before any front end has opened a display. Without the guard
  the terminal branch's `:height 1` was written into the one attribute set
  a GUI frame later inherits - measured: a GTK editor opened its font at a
  tenth of a point and the omarchy port warned "height is 1" and fell back
  to 110.
- **Closing it**: per-frame attributes (first entry), or deferring all
  realization to frame creation the way `face-set-after-frame-default` is
  called at `x_create_frame`.

---

## The minibuffer

### The prompt is painted, not inserted

- **Emacs** (`read_minibuf`, `minibuf.c:855-866`): the prompt is inserted
  into the minibuffer buffer with `minibuffer-prompt-properties` -
  `field t`, `front-sticky`, `read-only t` and the `minibuffer-prompt`
  face among them - and its width is recorded in `minibuf_prompt_width`.
  `minibuffer-prompt-end` (`minibuf.c:505`) reads the `field` property, and
  `minibuffer-contents` is `(prompt_end, ZV)`.
- **Here**: the prompt is drawn by the echo area from `*echo-area-prompt*`
  and the buffer holds only what the user typed. Everything that asks
  where the prompt ends answers `(point-min)`, and three places carry the
  scar:
  - `minibuffer-prompt-end` is `(point-min)` (`minibuffer.scm`);
  - `next-line-or-history-element` clamps the Elisp's `(1- prompt-end)` to
    stay in range, because position 0 would be signalled;
  - `previous-line-or-history-element`'s "avoid moving point to the prompt"
    branch can never be true, and is left out.
- **Also missing**: a multi-line prompt is not modelled, and a user's
  `minibuffer-prompt-properties` customisation does nothing.
- **Closing it**: insert the prompt with its properties, record the width,
  and make `minibuffer-contents`, `minibuffer-set-contents!`, the cursor
  column and the completion table start at `prompt-end`. ~100 lines, and
  it is the last named departure of `read_minibuf`.

### `next-line-add-newlines` is not ported

- **Emacs**: a defcustom (`simple.el`), checked by `line-move` at the end
  of the buffer; `next-line-or-history-element` binds it to nil so a
  prompt never grows a newline.
- **Here**: `line-move` has no such check, so there is nothing to bind.
- **Closing it**: one conditional in `line-move` and the defcustom.

### The minibuffer buffer is named "Untitled"

- **Emacs**: ` *Minibuf-1*` (`nth_minibuffer`), with the level in the name.
- **Here**: `read-minibuffer-1` calls `allocate-buffer`, whose default name
  is `"Untitled"`. Visible in `(buffer-list)` and in `C-x b`.

### `choose_minibuf_frame` is not ported

- **Emacs** (`minibuf.c:105`): the minibuffer follows the selected frame;
  with several frames the minibuffer stacks are zipped (`:200-209`) so a
  prompt raised on one frame is not typed into on another.
- **Here**: one minibuffer per process, and the echo area is drawn only on
  the selected frame (`render!`), which is the same visible behaviour with
  one minibuffer.

---

## The terminal's colours

### Direct colour is carried in redefined palette slots

- **Emacs** (`term.c:4718-4762`): when the terminal can take a colour by
  its 24-bit value - the `setf24`/`setb24` string capabilities, the
  `setrgbf`/`setrgbb` pair, the `RGB` flag, the `Tc` flag, or
  `COLORTERM=truecolor` - `TN_max_colors` becomes 16777216 and Emacs
  writes `\e[38;2;r;g;bm` / `\e[48;2;r;g;bm` itself.
- **Here**: the same detection (minus the two flags, below) makes
  `display-color-cells` answer 16777216, so a face colour is used exactly
  rather than approximated. But this renderer draws through **ncurses**,
  and a colour pair carries an index, not a colour: `init-pair!` refuses a
  24-bit value (measured, "out of range -32768 to < 32767"). So each
  distinct colour is defined into a palette slot with `init-color!` - which
  ncurses sends as OSC 4 at refresh - and the pair uses that slot. ncurses
  resets the palette on `endwin` (OSC 104, measured).
- **Consequence**: while the editor runs, palette entries 255 down to 16
  are redefined to the colours in use; Emacs never touches them. A theme
  colour and a palette entry cannot collide here, because with direct
  colour every colour is a pixel and never an index.
- **Missing**: the `RGB` and `Tc` *boolean* capabilities cannot be read
  through guile-ncurses - `tiget` takes string capabilities only, and there
  is no `tigetflag`/`tigetnum` (checked). A terminal that advertises one of
  them without setting `COLORTERM` is drawn through the palette where Emacs
  would use exact colours. `setf24`/`setrgbf` and `COLORTERM` cover every
  terminal seen so far.
- **Closing it**: a tty backend that writes its own escape sequences, as
  Emacs's does, instead of drawing through ncurses. That is the real
  difference; the palette-slot cache is the accommodation.

### A window that has not changed is still rebuilt

- **Emacs** returns early from `redisplay_window` for a window that is not
  outdated (`window_outdated`, `window.c:231`): a cursor move costs the
  cursor and nothing else, because the rows are already in the desired
  matrix and `update_window` finds them equal.
- **Here**: every window's desired matrix is rebuilt on every redisplay,
  so a cursor move rebuilds and re-draws every row of every window. The
  diff then suppresses the *output* - ncurses or the toolkit emits only
  the cells that differ - so what a keystroke costs is the row building
  (~2.6 ms for 40 rows) rather than the drawing.
- **Why the skip is not in yet**: `assign_row` swaps the built rows out of
  the desired matrix into the current one, so a window that is skipped
  keeps an *empty* desired matrix; `update_window` would then compare that
  empty matrix against the screen and blank it. Emacs does not have the
  problem because a skipped window is not passed to `update_window` at
  all - the two have to be added together, and the first attempt (skip
  plus update, 2026-11-10) put a graphical frame into a redraw loop at
  startup.
- **Closing it**: skip both the rebuild *and* the `update-window!` call
  for a window that `window_outdated` and the window-start check both
  call fresh, with a per-window record of what was drawn
  (`w->last_modified`, `w->last_overlay_modified`, and the start the rows
  were built from).

### The terminal still repaints its whole frame

- **Emacs** on a terminal rebuilds the whole frame matrix every redisplay
  too (`build_frame_matrix` + `update_frame`, `dispnew.c`) - but the
  *cost* is as small as the diff because the terminal is handed a frame
  matrix it diffs itself.
- **Here** the terminal erases and repaints, and that is what makes a
  cursor move a whole-screen draw at ~13 ms. Removing it was tried on
  2026-11-10 and **five pty checks failed** (`insert-file`, `dired`,
  `find-alternate-file`, `revert-buffer`, `buffer-menu`), for a reason
  worth recording: **ncurses takes its own scrolling shortcut**
  (`ESC [ 1 ; 22 r` then `ESC M`, which shifts a region of rows) whenever
  it can, so ncurses's idea of the screen stops agreeing with the glyph
  matrices - and a row diff computed against the unscrolled matrix then
  writes to the wrong rows. Measured: `C-x i` drew the inserted file over
  the echo-area row, and Dired's marks never appeared.
- **The two ways out**, both real ports:
  - `try_window_id` (`xdisp.c:22583`) and
    `try_window_reusing_current_matrix`, which let a scrolled window reuse
    its matrix instead of rebuilding it - and give the diff a matrix that
    matches what ncurses already scrolled;
  - or the tty backend written as Emacs's is, owning its own frame matrix
    and writing escape sequences itself (`tty_write_glyphs`,
    `tty_update_window`), instead of drawing through ncurses and letting
    curses decide what to send.
- **Also needed either way**: the cursor has to be erased explicitly.
  That is now ported - `erase-window-cursor!` and `*phys-cursor*` are
  `erase_phys_cursor` and `w->phys_cursor` - and it was the other half of
  why the GTK front end left a trail of cursor boxes behind it.

## A terminal resize: the change of size, and the bug that made the editor quit

A resized terminal did not resize the frame: the modeline stayed on row 22
at 40 rows and the vertical border of a `C-x 3` split stayed in column 39 at
100 columns. Two separate faults were under it, and the second one *exited
the editor*, which is how it showed itself as "resize partly works, but it
dies sometimes doing it".

### What Emacs does

    SIGWINCH -> handle_window_change_signal      (dispnew.c:6606)
                  get_tty_size (fileno (tty->input), &width, &height)
                  if (width > 5 && height > 2)
                    change_frame_size (f, width, height, false, true, false)
    pselect returns -> do_pending_window_change (0)   (process.c:5862)
                  change_frame_size (..., delay = false)
                  adjust_frame_size (f, ..., 5, ...)   (frame.c)
                  -> resize_frame_windows              (window.c)

The handler **only parks the numbers** - the C says why: "Record the new
sizes, but don't reallocate the data structures now. Let that be done later
outside of the signal handler" (`dispnew.c:6630`). The wait applies them,
immediately after `pselect` returns and *before* the bytes are looked at, so
a key and a resize arriving together both count.

### What this tree had, and what is now there

- the SIGWINCH handler was a no-op `(lambda (sig) #t)`, with a comment
  claiming "the size is read from `ioctl` when `sync-frame-size!` asks" -
  and nothing ever asked, because nothing told the editor a redraw was due;
- `change_frame_size` / `do_pending_window_change` were not ported at all;
- `read-input-event` answered the symbol `resize` for **every** timeout and
  every signal alike, and `key-event->key` answered `#f` for a symbol - so
  the event existed only inside `read-input-event` and was dropped one frame
  later.

Now: `handle-window-change-signal` (term.scm), `change-frame-size`,
`%apply-frame-size` and `do-pending-window-change` (frame.scm), the frame's
`new-width`/`new-height`/`new-size-p` (`f->new_width`, `f->new_height`,
`f->new_size_p`) and the global `delayed-size-change`
(`delayed_size_change`); `sync-frame-size!` is now expressed on top of
`change-frame-size`; and `%wait-and-read` does the `pselect`-then-apply pair.

### The bug that quit the editor

The command loop's rule is `keyboard.scm`, `command_loop`:

    ((< want 0)                  ; a *blocking* read
     (let ((quit (frame-quit-cont frame))) (when quit (quit 'eof))))

"Nothing to read on a blocking read is the end of input", and the editor
exits with status 0. A signal interrupts `select` and it returns with an
empty ready set; the wait answered `#f`; the loop read that as end of input
and quit. Measured: 1 run in 3 with a bare resize, 3 in 3 with `C-x 3`
before it.

`key-event?` is `(not (eq? ev #f))`, so a *symbol* would at least not have
quit - but `read-key-event` never returned one, because `dispatch-special-
event` consumed it. The `#f` was the whole path.

The fix is Emacs's own loop shape: after an empty ready set the wait asks
whether the size changed, and if it did not it **selects again** rather than
answering `#f`. Only a deadline or a real end of input answers `#f` now.

### Departures, and whether they should be closed

1. **`read-input-event` makes a `resize` event, which Emacs's tty does not
   have.** Emacs applies the change inside the wait and never makes an event;
   its `special-event-map` has no `[resize]`. This tree's redisplay belongs
   to the read loop (`read-key-event` redisplays and loops on a special
   event), so the event is the seam. It is the design the gtk front end
   already uses (`*resize-code*`), and `[resize]` is bound to `ignore` in
   `special-event-map`. **Keep** unless the tty grows an independent
   redisplay trigger; closing it means redisplaying from the wait, which is a
   change to the loop rather than to this path.
2. **The wait calls `handle-window-change-signal` as well as the installed
   handler.** Emacs's handler body runs in signal context; Guile defers a
   `sigaction` handler to the VM's next safe point, and **measured, that
   point can be after `select` has already returned to Scheme** - the signal
   ends the wait, the wait's code runs, and the handler has not parked
   anything. So the wait reads the size itself (which is the same
   `get_tty_size` the C does) and the handler's own run is a harmless second
   opinion. **Cannot be closed** without a Guile signal API that runs
   handlers synchronously; what makes it safe is that parking is idempotent.
3. **`do-pending-window-change` answers whether a frame's size actually
   changed**, where the C returns void. Without it, a signal that woke the
   wait for nothing (any other signal, a coalesced SIGWINCH) would be
   indistinguishable from a resize and would either redraw the frame for
   every wake or - worse - return `#f` and quit. `%apply-frame-size` answers
   it, and `adjust_frame_size`'s no-op-for-an-unchanged-size is where the C
   gets the same answer implicitly.
4. **The C's `redisplaying_p || dont_resize_frames` guard is not
   enforceable here.** `*redisplay-in-progress*` is `(schemacs editor
   xdisp)`'s and that library imports `frame`, so `change-frame-size` cannot
   read it; nothing sets `dont_resize_frames` at all. What the guard protects
   - a size change requested *during* a redisplay - is this tree's
   `sync-frame-size!` call at the top of `render!`, which wants it applied
   there. The one caller that must be deferred is the signal path, and it
   passes DELAY. **Fine as it stands**, but it is a departure in the guard,
   not in the algorithm.
5. **`get-tty-size` answers `(ROWS . COLUMNS)`**; the C's out-parameters are
   `(width, height)`. A Scheme pair carries no names, and the rest of this
   tree reads a display size as `(height . width)` (`display-rows-cols`).
   Cosmetic, but worth knowing when comparing against `sysdep.c`.
6. **A pty that was never given a size answers 0 x 0**, which `get_tty_size`
   treats as "no valid information" and `screen-size` answers with the
   startup capabilities - so 24x80 until the first resize. That is why a
   harness must set the pty size *and* send SIGWINCH; the C's `> 5 / > 2`
   guard is the same rule from the other side.

### A Scheme trap this walked into

`%apply-frame-size` answers whether the size actually changed, and its first
version said so with `(and (< 0 new-height) (let ... (unless <unchanged> ...
#t)))`. On an *unchanged* size `unless` has nothing to do and returns the
**unspecified** value - which is *true* in Scheme - so the answer was yes for
every call, `do-pending-window-change` reported a resize for every wake, and
after the first real resize the editor would have redrawn its frame for ever.
Both results are `#t` values, so no test could see it; it was found by
reading the shape. The file's old lesson is the same one in the other
direction: `(or ring (error ...))` fires on `'()`. **A predicate answered by
a `when`/`unless` is not a predicate.**

### Two method notes

- **A truncating log hid the handler's line.** `(open-output-file ...)`
  truncates on every call, so a handler that logged on entry and a wait that
  logged after it left only the last line - and I concluded from that that
  the handler never ran, then built a whole explanation on it. `open-file`
  with `"a"` showed `(HANDLER ran)` *before* `(returned ...)`: Guile does run
  the handler before `select` returns to Scheme, at least most of the time.
  Check the instrument before believing the reading.
- **`change_frame_size`'s DELAY is not an optimisation.** Re-tiling windows
  from a signal handler - or from anywhere the redisplay is not expecting it
  - is the class of bug that shows up three screens away. Emacs parks and
  applies for that reason, and the port keeps the two steps apart even though
  Guile would often let one function do both.

## Giving the terminal back: two bugs in `init_sys_modes`, and the copy that was not one

Chris: *"it used to (and emacs does) save and restore the old terminal state
when you exit."* It did not, for two reasons, and `C-x C-c` never actually
reached the editor at all.

### 1. `c_cc[VINTR]` was still `^C`, so the quit command killed the editor

GNU Emacs's `init_sys_modes` (`sysdep.c:1163`) writes the control characters
after the flags:

```c
  tty.main.c_cc[VINTR]  = quit_char;   /* C-g gives SIGINT */
  tty.main.c_cc[VQUIT]  = quit_char;
  ...
  tty.main.c_cc[VSUSP]  = CDISABLE;    /* C-z is the editor's */
  tty.main.c_cc[V_DSUSP] = CDISABLE;   /* C-y */
  tty.main.c_cc[VLNEXT] = CDISABLE;    /* C-v */
  tty.main.c_cc[VREPRINT] = CDISABLE;  /* C-r */
  tty.main.c_cc[VWERASE] = CDISABLE;   /* C-w */
  tty.main.c_cc[VDISCARD] = CDISABLE;  /* C-o */
  tty.main.c_cc[VSTART] = CDISABLE;    /* flow_control is off */
  tty.main.c_cc[VSTOP]  = CDISABLE;
```

This tree wrote none of them, so every one of those characters was eaten by
the kernel before the editor saw it. The one that mattered: **`C-x C-c`'s
`C-c` became SIGINT**, and the editor died where it stood - no
`reset_sys_modes`, no `te`, no `tcsetattr`. Measured: `C-x C-c` gave
exit-by-signal-2, an all-raw termios afterwards, and not one byte of
teardown in the stream. `C-z`, `C-r`, `C-w` and `C-v` were unreachable for
the same reason.

~~**Departure: `VINTR`/`VQUIT` were `CDISABLE` here, not `quit_char`** -
closed the same day, see "C-g is a signal" below.~~ The first fix disabled
them, because there was no SIGINT handler for C-g to raise and a keyboard
signal would have killed the editor. `handle_interrupt` is ported now and
the characters are `quit_char`, as the C has them.

### 2. The "saved" terminal mode was the one being edited

`init_sys_modes` did

```scheme
(let ((settings (or (tty-save-modes! *tty-fd*) (tty-read-modes *tty-fd*))))
  ... (%flag-and-not! settings ...) (%write-modes! *tty-fd* settings))
```

and `tty-save-modes!` **is** `*tty-old-modes*`. So the raw-mode edits were
written into the copy that exists to be restored, and `reset_sys_modes`
faithfully put raw mode back. The C has the copy:

```c
  emacs_get_tty (fileno (tty_out->input), &tty_out->old_tty);
  tty = tty_out->old_tty;               /* sysdep.c:1153 */
  ... edits `tty`, not `tty_out->old_tty` ...
```

`init-sys-modes` now copies before it edits. Measured, after both fixes: the
termios the editor exits into is byte-identical to the one it found.

### 3. `bytevector-copy!` was called source-first, and `(scheme base)`'s is not

Writing the copy above with `(bytevector-copy! saved 0 settings 0 60)` - the
order `(rnrs bytevectors)` uses - copied the *empty* destination over the
saved mode, and the editor exited into an all-zero termios. `(scheme base)`
exports R7RS's `(bytevector-copy! TO AT FROM ...)`, and `sysdep.scm` imports
`(scheme base)` whole, so that is the one it gets. **The same call was in
`set-read-timeout!`**, where it silently never copied anything, so the timed
read's `VMIN`/`VTIME` were written into a bytevector that was then thrown
away - nothing calls that function today, which is why it never showed.

Both are called target-first now, with the trap named at the call site.

### The check

`tools/pty-check.py` grew **`terminal-restored`**, which forks its own pty
(it needs the slave side after the editor is gone, which `drive` cannot
give), records a fresh pty's termios as the reference, quits with `C-x C-c`
and asserts three things: the editor **exited** rather than being signalled,
the termios is byte-identical to the reference, and `te` was sent. Verified
failing both ways - with the control characters unwritten (signal 2, `iflag,
oflag, lflag, cc` different, no `te`) and with the save-then-copy reversed
(every field different).

### Also found in passing

`init_sys_modes` reads `(or (tty-save-modes! fd) (tty-read-modes fd))` -
i.e. "remember the mode, and if that failed use what is there". The `or`
made a second `tcgetattr` unreachable in the normal case, which is right;
what was wrong was that the two were the same object.

## C-g is a signal, and `keyboard-quit` signals `quit`

The departure the previous section left open, closed. GNU Emacs makes C-g
the terminal's **interrupt character** (`c_cc[VINTR] = quit_char`,
`init_sys_modes`, `sysdep.c:1163`), so a C-g never arrives as a byte: the
kernel consumes it and sends SIGINT. Everything else is built on that.

### What is ported

| Emacs | here |
|---|---|
| `quit_char = Ctl ('g')` (`keyboard.c:13227`) | `quit-char` (`command.scm`) |
| `Vquit_flag`, `Vinhibit_quit` | `*quit-flag*`, `*inhibit-quit*` |
| `handle_interrupt` (`keyboard.c`) | `handle-interrupt` (`keyboard.scm`) |
| `init_signals`' SIGINT/SIGQUIT | `init-signals`, called where the terminal opens |
| `maybe_quit` / `probably_quit` (`lisp.h:3897`, `eval.c:1887`) | `maybe-quit` |
| `read_key_sequence`'s opening `maybe_quit ()` (`keyboard.c:11917`) | the top of `read-key-event`'s loop |
| `read_char` answering `quit_char` for a pending flag (`:2806`) | `read-input-event` |
| `cmd_error`'s `Vquit_flag = Qnil; Vinhibit_quit = Qnil` (`:1014`) | `report-command-error!` |
| `keyboard-quit` (`simple.el:9785`) | `keyboard-quit` (`simple.scm`) |

`force_quit_count` is ported too: the third C-g in a row clears
`inhibit-quit`, which is how a user escapes a loop that meant to be
uninterruptible.

### The one mechanism that is not the C's

**There is no `longjmp`.** Emacs's `handle_interrupt` calls
`quit_throw_to_read_char`, which longjmps out of `pselect` and lands in
`read_char` with `c = quit_char`. Here the signal interrupts `select` (it
already did, for SIGWINCH), `%wait-and-read` stops waiting when the flag is
set, and `read-input-event` answers `quit-char` for it. Same event, same
place in the stream, no throw out of a signal handler - which is the part of
the C that a Scheme signal handler should not be asked to do.

**What that costs**: a C-g that arrives while a *long command* is running is
noticed at the next read rather than at the next `QUIT` inside the command.
Emacs calls `maybe_quit` from its C loops - `search_buffer`, the insdel
loops, `redisplay` - and those are `engine.scm` and `search.scm` here, which
are *below* `keyboard.scm` and cannot import it. Closing that needs the seam
this tree already uses for `*message-function*` and
`*record-window-buffer-function*`: a `*maybe-quit-function*` installed by
`keyboard.scm` and called from the engine's walks. Not done here, and named
rather than implied.

### Two departures in `keyboard-quit`

- **`saved-region-selection` and `defining-kbd-macro` are not carried.**
  The command loop clears the former after every command already
  (`keyboard.c:1647`), and there are no keyboard macros yet.
- **It clears the echo area and any half-entered chord**, which Emacs's does
  not - that is what this tree's `keyboard-quit` did before it signalled
  anything, and it is what `C-g` after `C-x` should look like.

### Where the quit condition lives, and why

`quit-char`, `*quit-flag*`, `*inhibit-quit*`, `<quit-condition>` and
`signal-quit` are in **`command.scm`**, not `keyboard.scm`, and re-exported
from `keyboard.scm` so every importer is unchanged. `keyboard-quit` is
`simple.el`'s and `simple.scm` is *below* `keyboard.scm`, so a command that
signals quit and clears the flag could reach neither - the same wall
`current-prefix-arg` was moved down for.

### The echo area did not blank the rest of its row

Found while testing this, and not caused by it: a message shorter than what
was already on the echo row left the tail behind. Measured, `M-x zzzz RET`
drew `No matchzzzz`, and a `Quit` after a minibuffer prompt left
`Quit/tmp/`. A window's glyph row is `window_box_width` cells - the text and
then spaces - and `update_window` diffs the whole of it; the echo area was
written with `write-run!` and nothing after it. Both branches now call
`clear-end-of-line-row!` for the rest of the row, which is what
`draw-glyph-row!` already did for every other row.

### The check

`tools/pty-check.py` grew **`quit-signal`**: C-g at top level must report
`Quit` and leave the editor running, and C-g inside a prompt must report
`Quit` with nothing of the prompt left behind it. Verified failing both ways
- with `init-signals` removed (the editor is killed by SIGINT) and with the
echo-area blanking removed (`'Quit/zzz'`).

## The terminal's back door had no wake, and an idle editor could not be woken

Found while testing the C-g work, and not caused by it: `back-door` and
`imports` had been failing in the full battery (and, because
`tools/pty-check.py`'s `main` does not catch exceptions, the battery was
**stopping at `back-door`** - the "everything else passed" runs had simply
not reached the later checks).

The command loop shortens its read for the door only when the front end
*has no* wake:

```scheme
(read-timeout-or -1 (timer-next-delay)
                 (and (repl-running?) (not (repl-wake)) 100))
```

`(repl-wake)` is `(scheme-utils repl server)`'s, and its default is
`default-wake` - **a procedure, so always true**. The terminal's own wake -
the self-pipe the notes say landed on 2026-10-07 - went away when this file
stopped being ncurses, so no cap was applied and no pipe was waited on: an
idle editor's `select` blocked for ever and the door answered only when a
key was typed. Measured: `repl -e '(+ 1 2)' NAME` timed out against an idle
editor and answered at once with a key being typed.

`install-repl-wake!` (`term.scm`, called by `with-terminal`) is that pipe
again: an unbuffered write end, `repl-wake!` given a procedure that stores
the thunk the server wants run on this thread and writes one byte, and
`%wait-and-read` selecting on **two** descriptors - the keyboard and the
pipe - and running the stored thunk when the pipe is the one that woke it.
`get-u8` drains it (a buffered read end would leave bytes behind and wake
the wait for ever).

Two Guile spellings worth knowing, both cost a round each: `put-u8` is
`(rnrs io ports)`'s and **not** `(guile)`'s, and that library's read is
`get-u8`, not `read-u8`.

## The redisplay skipped a window whose matrix was no longer the screen

The skip itself is a port: `redisplay_window` asks `window_outdated`
(`window.c:231`) and `current_matrix_up_to_date_p` (`xdisp.c:20576`) and,
when both are happy, builds nothing and only moves the cursor - so a `C-n`
in the middle of a window costs a cursor repaint. `xdisp.scm` now asks the
same questions (`window-matrix-valid?`) and skips the rebuild for a window
that is still fresh.

**The departure was that clearing the screen did not invalidate the
windows.** GNU Emacs's `redraw_frame` (`dispnew.c:3212`) ends with

```c
clear_current_matrices (f);
mark_window_display_accurate (FRAME_ROOT_WINDOW (f), 0);
```

and `mark_window_display_accurate_1` (`xdisp.c:18304`) is what gives
"inaccurate" its teeth: `w->last_modified = 0`, `w->last_overlay_modified
= 0`, `w->redisplay = true`. This tree cleared the surface and the glyph
matrices (`clear-garbaged-frames!`) and left the recorded ticks alone - so
every window still looked fresh, every window was skipped, and the rows
the clear had wiped were never repainted.

Measured, and it is exactly the symptom reported from using the editor:
**on startup the file does not appear until the terminal is resized.** The
first redisplay drew the file; a second redisplay cleared the surface and
drew only the mode line; the body stayed blank. A resize changed the
window's body width/height, which `window-matrix-valid?` *does* compare, so
the next redisplay rebuilt the window and the file came back.

Ported as it stands:

- `mark-window-display-accurate-1` (`xdisp.c:18304`) and
  `mark-window-display-accurate` (`:18407`), the latter walking
  `frame-windows`/`window-children` where the C walks `w->contents` and
  `w->next` (this tree's frame keeps a list of top windows, so there is no
  single root window object - departure, named in the source);
- `clear-garbaged-frames!` calls it with `#f` after clearing the matrices,
  which is `redraw_frame`'s own pair;
- the "accurate" direction replaces the tree's invented
  `window-matrix-note!`, so there is one function that records what a
  matrix was built from rather than two that could drift.

`w->last_had_star`, `w->last_point`, `clip_changed`,
`prevent_redisplay_optimizations_p`, and `w->redisplay` itself are not
carried - nothing here reads them; the two ticks are the whole of
`window_outdated`, and the start/size/hscroll fields are this tree's
stand-ins for `current_matrix_up_to_date_p`.

### And the overlay tick was never raised

Found by the same work, and a live bug on the GTK front end where the skip
already applied: `buffer-overlay-modified-tick` existed (`BUF_OVERLAY_MODIFF`,
`buffer.h`) but nothing ever incremented it, so `window_outdated`'s second
half was dead. Moving a search overlay or setting the region did not
invalidate anything, and with the skip in place those highlights simply did
not appear.

`modify_overlay` (`buffer.c:3689`) is ported now, and called where the C
calls it: `overlay-put` when a property actually changes (`:4090`),
`delete-overlay` through `drop_overlay`'s "only if the plist is non-empty"
rule (`:977`), and `move-overlay` with the C's three-way redisplay rule -
propertyless overlays are not drawn; a buffer change repaints both ranges;
otherwise the range the overlay *left* (`:3767`). The `BEG_UNCHANGED` half
of `BUF_COMPUTE_UNCHANGED` is carried because the `%l` cache reads it;
`END_UNCHANGED`, `BUF_LAST_MODIFIED_POS` and `bset_redisplay` are not,
because nothing here reads them.

### The terminal is diffed now, and four things had to be true first

Making the terminal incremental - which looks free, since its output path
is `term.c`'s and emits only the rows it is handed - turned the pty battery
from 77/78 into 65/78 on the first attempt. Rather than keep the
whole-screen repaint, each failure was traced to a missing rule, and all
four are now ported:

1. **`OVERLAY_MODIFF` was never raised** (above), so `region-highlight`,
   `isearch-highlight`, `isearch-highlight-row` and `isearch-multiline`
   were all stale rows.
2. **A current glyph row that was never on the screen compared equal to a
   blank desired row.** `update_window_line` (`dispnew.c:4749`) tests
   `!current_row->enabled_p` *before* comparing contents, "or the current
   row is marked invalid, write the entire line". `matrix-diff-rows` did
   not, so a window whose matrix grew - a window taking over the rows of
   one deleted beside it - kept the deleted window's text and mode line.
   Measured: `C-x C-b` then `q` left the buffer list on screen under the
   file; the same for the completions window and its `C-g`.
3. **The region is drawn from point and mark, and nothing recorded
   them.** GNU Emacs does not have this problem because
   `redisplay--update-region-highlight` (`simple.el:7332`) keeps the
   region in an *overlay* and moves it on every redisplay, which raises
   `OVERLAY_MODIFF`. This tree's renderer computes the region's face from
   the mark itself, so the window gained `last-point` and `last-mark`
   (`window.h`'s `w->last_point`, `w->last_mark`, written by
   `mark_window_display_accurate_1`) and `window-matrix-valid?` compares
   the pair **while the region is active**. Only then - a window with no
   region does not change when point moves, which is what keeps `C-n`
   costing a cursor.
4. **`C-z` then `fg` came back to a blank screen.** `Fresume_tty`
   (`term.c:2604`) ends with `SET_FRAME_VISIBLE (root, true)`, whose body
   (`frame.h:1537`) is `redisplay_other_windows ()` - "make sure the frame
   gets redisplayed if some changes were applied to it while it wasn't
   visible". Re-entering the terminal also blanks the alternate screen.
   `suspend-frame` now marks every frame on that display garbaged and
   re-runs the invalidation after `resume-display!`; GNU Emacs needs only
   the first half because its tty redisplay rebuilds and hands over the
   whole frame matrix every time. **That is the departure**: the garbage
   is this tree's half of `SET_FRAME_VISIBLE`.

Result: the pty battery is back to 77/78 with the terminal diffed, and what
a keystroke writes to a terminal is now the rows that changed.

### A pty check that was passing because of the repaint

`revert-buffer` answered the `Discard edits and reread from ...?` prompt
with a bare `y`. That prompt is `yes-or-no-p` (`files.el:7280`) - "the
whole word" - so the answer was rejected with "Please answer yes or no."
and the revert never happened. The check passed anyway because, on a
full-repaint terminal, the *unreverted* buffer was redrawn after every key
and its text is `EDITED original` - which contains `original`. It started
failing the moment rows that had not changed stopped being redrawn, which
is the check doing its job for the first time. It now answers `yes` and
asserts on the final screen: the file's text there, and no `EDITED`.

## The mode line is compared here, and what that exposed in the face code

`update_window` (`dispnew.c:4400`) diffs the mode line like any other row:
`display_mode_line` builds it into the window's desired glyph matrix, and
an unchanged mode line therefore costs nothing. This tree draws it
directly, outside the matrices (`render-window-mode-line!`), so the same
comparison is made there against what was last written - the padded
string, the face (it flips when a window is selected), and **the row and
column it went to**. The position is part of it for a reason that a pty
check found: `?` in a file prompt splits the window, the file's mode line
moves up, the string does not change, and a comparison by content alone
skipped it at the new row - the screen then showed one window where there
were two.

### `tty_turn_off_highlight` was missing its second statement

The mode-line comparison is what exposed this, and it is a one-line port
defect. GNU Emacs's `tty_turn_off_highlight` (`term.c:318`) is

```c
  if (tty->standout_mode) OUTPUT_IF (tty, tty->TS_end_standout_mode);
  tty->standout_mode = 0;
```

and this tree had only the first line. The flag is the terminal's model of
reverse video, and it has to be exact because `turn_on_face` emits a face's
foreground and background **swapped** while it is set (`term.c:2140` -
`TS_set_background` for the foreground value and the reverse for the
background). Leaving it set for ever meant every later glyph run re-emitted
`so` and sent its colours in the opposite order.

**Nothing looked wrong, which is why it survived**: `tty_highlight_if_desired`
emits `so` again whenever the flag says so, so the terminal really was in
reverse and the swapped colours really were right. Only the byte stream
differed from Emacs's - and `region-highlight`, which pins
`\e[37m\e[44m`, failed as soon as the mode line stopped being redrawn every
keystroke (its draw had been clearing the flag by accident).

The other half of the same port is `tty_highlight_if_desired`
(`term.c:398`), which is "on or off according to `inverse-video`" - both
`tty_turn_on_highlight` and `tty_turn_off_highlight` also maintain the
flag, which neither did here.

**The method note**: the evidence for this ("`turn_off_face` only clears
the flag when `me` and `se` are the same sequence") pointed at the wrong
function. Backing the optimisation out was the wrong response; reading the
next function in the same C file found it in one look. That is the rule
this file already carries - when behaviour is wrong, read the C rather
than route around it.

## The redisplay work that is not done, and three things seen from using it

Written down so the gaps are work items rather than discoveries. The first
table is what was deliberately left after the terminal became diffed; the
second is what Chris reported from using the editor, with the Emacs
mechanism each most likely departs from.

### Not done in the redisplay

| Emacs | state here |
|---|---|
| `scrolling_window`, `try_window_reusing_current_matrix`, `try_window_id` | not ported. A scroll redraws every row, because `matrix-diff-rows` compares row *i* with row *i*. Emacs shifts the still-valid runs; on a tty it then uses scroll regions or insert/delete-line (`FRAME_SCROLL_REGION_OK`). We carry no `cs`/`sf`/`sr`/`AL`/`DL` capabilities at all, so the row reuse would save CPU but not output - measured, a page scroll is already ~500 bytes on a 24x80 terminal. |
| the mode line as a row of the glyph matrix (`display_mode_line`) | drawn outside the matrices, so it is diffed by `render-window-mode-line!` instead of by `update_window`. |
| `w->redisplay`, `w->update_mode_line`, `mode_line_update_needed` | not carried. `windows-or-buffers-changed` is one flag standing in for a subset of them. |
| GTK damage rectangles | none: a window whose matrix changed repaints the window. |
| jit-lock / font-lock refontification | the font-lock pass is done up front, not on demand. |

### From using the editor (2026-11-13)

**(1) Holding an arrow key down keeps the cursor moving after the key is
released.** GNU Emacs stops within a keystroke of the release. Nothing here
buffers input deliberately: the terminal queues the repeats, we read one
per command, and while the per-keystroke cost is higher than the repeat
interval a backlog builds and is then worked off after the release. So the
question to answer first is what a keystroke actually costs end to end
(command + redisplay + the terminal's own processing), not whether some
ioctl is missing. Emacs is not doing anything special here - it is simply
draining the queue faster than the terminal fills it.

**(2) The cursor visibly jumps to the mode line while it is redrawn.**
GNU Emacs's `tty_update_begin` (`term.c`) is `tty_hide_cursor`, and
`tty_update_end` is `tty_show_cursor`: the cursor is made invisible for the
whole of `update_frame` and shown again afterwards, so the cursor motions
that write the rows are not seen. `update-window-begin!` here is a no-op
(`#t`) and `update-end!` only emits `TS_cursor_normal`, so every
`cursor_to!` the redisplay makes is visible. *Fixed - `civis` was read in
and `tty_hide_cursor`/`tty_show_cursor` bracket the frame now; the residue
was the show happening before the place, see "The cursor was shown before
it was placed" at the end of this file.*

**(3) After the terminal's theme changes, the background behind text is the
old colour and the rest of each line the new one, so the text forms a
jagged outline.** The renderer emits the default face with explicit
truecolor (`\e[38;2;229;229;229m\e[48;2;51;51;51m` for plain text), while
the parts of a row past the text are cleared with `ce` under no explicit
colour. When the terminal's palette changes, the cells carrying explicit
RGB keep what they were given and the cleared cells follow the terminal, so
the two no longer match. Emacs's tty default face is
`FACE_TTY_DEFAULT_FG_COLOR`/`..._BG_COLOR` - the terminal's own colours,
emitted as "no setaf/setab" - so the whole line moves together.
`realize-tty-face`/`realize-face` giving the default face concrete RGB from
the frame's background is where to look, not the drawing code.

# The cursor was shown before it was placed (2026-11-13)

Chris, after `civis`/`cnorm` bracketing landed: *"I can see the cursor flash
in the bottom left square when I move around. Is it possible that you should
have moved the cursor back to its correct position before calling
tty_update_end?"*

He was right about the cure and about the corner, and the departure was
structural rather than an ordering slip. `draw-window-cursor!` for a
terminal did three jobs in one hook:

    (emit cursor-visible)        ; vs / cvvis
    (cursor-to! row column)

so the cursor became visible **wherever the last glyph write left it** and
was then addressed to point. The last write of a frame is the echo area's
row - `clear-end-of-line-row!` on the frame's bottom row, starting at
column 0 - so the cursor appeared in the bottom-left cell and then jumped.
Captured on a pty, one `C-n` from a fresh editor:

    before:  ... \e[K  \e[?12;25h  \e[2d  \e[?12l \e[?25h
                        ^ show      ^ move
    after:   ... \e[K  \e[2d  \e[?12l \e[?25h
                        ^ move ^ show

**The C has these as three separate things, and this tree had them in
one.** `update_begin`/`update_end` (`term.c`) own the cursor's
*visibility* (`tty_hide_cursor` / `tty_show_cursor`); `tty_set_cursor`
(`dispnew.c:5672`) owns its *placement*, called by `update_frame` after
the frame's text is written; and the `draw_window_cursor` hook is a
*window-system* rif method - a termcap frame's `rif` is NULL (`term.c`),
because a terminal draws its own cursor and there is no reverse-video
cell to paint. So the port is:

- `draw-window-cursor!` for a tty records only whether the cursor is to
  be shown at all - GNU Emacs's `cursor_off_p` (`window.h`), which
  `tty_update_end` reads before showing - and draws nothing;
- a new display generic **`set-terminal-cursor!`** is `tty_set_cursor`:
  it addresses the hardware cursor at the position the redisplay
  recorded, and the window-system default does nothing because the
  toolkit owns its cursor;
- `update-end!` shows the cursor unless `cursor_off_p`, then flushes.

`render!` calls `set-terminal-cursor!` from the `*phys-cursor*` record
(where `note-phys-cursor!` stored the position, as `display_and_set_cursor`
stores `w->cursor`) immediately before `update-end!`. That is the order
Emacs's own `update_frame_with_menu` uses (place, then `update_end`), and
it is the order that cannot be seen: the address happens while the cursor
is still hidden.

`update-begin!`/`update-end!` also gained no-op `<display>` defaults,
which is the C's arrangement: `update_begin` only calls
`FRAME_TERMINAL (f)->update_begin_hook` when it is non-NULL, and the
window-system terminals leave the pair NULL. Without them the stub
display the suites use had no method at all, which is why
`ncurses-editor-tests` and `pgtk-tests` failed once the bracketing
landed.

Verified by the byte capture above, and by all 35 suites plus the pty
checks `redisplay`, `scroll`, `newline`, `region-highlight`,
`mode-line-eol`, `truecolor` and `no-display`.

Departure left standing, found while measuring: `visible-cursor`
(`term.c:5347`, `DEFVAR_BOOL`, default `1`) initialises this tree's
`tty-visible-cursor` to `#f`, so `vs` (`cvvis`) is never emitted after
`ve`. Same class of leak as `standout_mode`'s: a state flag with a
default that is not the C's.

# Emacs paints every terminal row to the edge (2026-11-13)

Chris: *"The main thing outstanding is to investigate if real emacs paints
every line to the edge, or just to the last character like schemacs."*

It paints to the edge, and the mechanism is `extend_face_to_end_of_line`
(`xdisp.c:24379`), called from `display_line`. Its comment:

> Extend the face of the last glyph in the text area of IT->glyph_row to
> the end of the display line. ... If the text area is empty, a space
> glyph is added to it to carry the face used for clearing the line.

Measured on Emacs 31.1 in a pty (`-nw -Q` on a 24x80 terminal, the
terminal answering the background queries as an xterm would), every text
row comes out as

    \e[38;2;255;255;255m\e[48;2;0;0;0m line 19 <73 spaces> \e[39;49m

- the text *and* the padding, in one face, all the way to column 80.
There is no `\e[K` (`ce`) anywhere in the paint.

Schemacs wrote the text in the default face's explicit truecolor and then
**erased** the rest of the row with `clear_end_of_line`, under
`\e[39;49m` - the terminal's default colours. That is exactly the jagged
outline: on a terminal theme change the written cells keep the explicit
RGB and the erased cells follow the terminal.

So the port:

- `extend-face-to-end-of-line` (`xdisp.scm`) is the tty branch: append
  space glyphs, carrying the *last* glyph's face, until the row reaches
  the window's width. It is called from `build-row!` (`display_line`),
  so the padding is part of the glyph row and the diff sees it.
- A row past the end of the buffer and the echo area's row are filled the
  same way (`fill-line-end-row!`), because they are cleared at draw time
  rather than built; only a window-system display uses `ce`, where the
  toolkit paints the background for it.
- `window-system-display?` is the new generic standing in for
  `FRAME_WINDOW_P`, because the choice is the *display's*
  (`<tty-display>` is a terminal; `<pgtk-display>` is not).

Verified on the same pty: schemacs now emits zero `ce` sequences, pads
every text row to 80 columns, and the padding sits under the same
`\e[38;2;229;229;229m\e[48;2;51;51;51m` as the text - the same shape as
Emacs's. `wide-columns`, `redisplay`, `scroll`, `newline`,
`region-highlight`, `completion-ui`, `truecolor`, `mode-line-eol`,
`hscroll` and `continuation` pass, and all 35 unit suites pass.

**Departure left standing**: the padding face. Emacs uses the last
glyph's *extend* face (`face_at_pos (it, LFACE_EXTEND_INDEX)`) unless the
row ends at ZV, in which case the default face; this port uses the last
glyph's face unconditionally. `build-row!` has no row that ends at ZV
(the row past the buffer is blanked separately), so the two agree on
every row this port builds - but `:extend nil` faces are not carried.

## A keystroke redrew the whole window, because a face's token was not interned (2026-11-13)

Chris, after the row-filling pass: *"you've fixed the painting problem, but now
the buffered keystrokes problem is back. This seems to break again on every time
you do something"* - and, when the scrolling path was suspected, *"it's not a
scroll issue."* Both were right. The cause was two departures that had been
there all along and only became expensive once a terminal row was filled to the
edge.

### 1. A realized face was a fresh object every time

GNU Emacs's glyphs carry a `face_id`, an integer, and `GLYPH_EQUAL_P` compares
them with `==`. This tree's glyphs carry the display's opaque token, and
`glyph-equal?` compares tokens with `eqv?` - which is only right if the same
attributes answer the *same object*. They did not: `realize-tty-face` conses a
new plist per call, and every row build realizes its faces again, so every
rebuilt row compared unequal to the one on the screen and `update_window` drew
the whole window on every keystroke.

It was invisible while a row was short. Measured on the tree before the filling
pass, one `C-n` in a 60-line file wrote 261 bytes - every row redrawn, each a
few characters plus a `ce`. Filling rows to the edge turned each of those into
80 cells, and the same keystroke wrote 2311 bytes against GNU Emacs 31.1's 211.

The fix is Emacs's: `lookup_face` (`xfaces.c`), the realized-face cache keyed by
the attributes - `FRAME_FACE_CACHE`'s job. `dispnew.scm` has `lookup-face`, and
the redisplay's four realization sites go through it. Departure, named in the
source: Emacs's cache lives on the frame and is capped at `FACE_CACHE_SIZE` with
least-used pruning; this one is per display and unbounded.

### 2. The rows below the buffer's end were cleared, not built

Emacs's `try_window` calls `display_line` while the window has room, so the rows
past `ZV` are built like any others - `prepare_desired_row`'s own comment is
"Clear the result glyph row and enable it" - and `extend_face_to_end_of_line`
fills them with blank glyphs in the default face. Being built, they compare
equal next redisplay and are never drawn again.

Ours stopped the loop when the buffer ran out of lines and left those rows
*disabled*, which is the one state the diff can never match: the current matrix
holds what was last drawn, the desired row holds nothing, so the row was cleared
again on every redisplay. That cost three bytes of `ce` each before the filling
pass and a whole row of spaces after it.

`xdisp.scm`'s `build-blank-row!` is `prepare_desired_row` for those rows, and
`display-window!` builds them out to the window's body height.

### Measured

| | before this pass | after | GNU Emacs 31.1 |
|---|---|---|---|
| typing one character, one-line buffer | 2311 B | **508 B** | 211 B |
| one `C-n`, no scroll | 421 B | 421 B | 212 B |
| 60 held `C-n`, quiet after the last key | 1284 ms | **519 ms** | - |
| editor CPU per `C-n` | 63 ms | **5 ms** | - |

(A *scrolling* keystroke is still 2313 bytes against Emacs's 212: Emacs scrolls
the screen with `scrolling_window` and a terminal scroll region, and this
redisplay rewrites every row. That is the gap named in "The redisplay work that
is not done" above, not this pass's. The paragraph there about holding an arrow
key down is this same measurement: a keystroke's cost has to be under the
terminal's repeat interval.)

### Tests

`ncurses-editor-tests.scm` +2: the same attributes answer the same token
*object* (with a display whose `realize-face` conses, as the terminal's does),
and two displays realise the same face separately.

# The GTK menu bar takes the mode line's colours (2026-11-13)

Chris asked for it, and named it correctly as a departure: *"Can you make the
gtk menu bar themed. I think this is a departure from emacs, you can check if
it has any theming for the menu bar, but I want it anyway."*

**It is one.** GNU Emacs has a `menu` face - "Basic face for the font and
colors of the menu bar and popup menus" (`faces.el:3035`) - and its
`((type x-toolkit))` branch is *empty*: a GTK frame's menu bar and popups take
the toolkit theme, and no face colours them. Emacs's terminal menu bar, by
contrast, is drawn by Emacs itself and does use the face (`:inverse-video t`).

Here the bar and every submenu take the **`mode-line` face's `:foreground` and
`:background`** - the active window's, that being the face the selected window
draws its mode line with - applied with a CSS provider and two class-scoped
rules (`pgtk.scm`'s "The menu bar's theme"). A hovered item swaps the pair,
which is the mode line's emphasis seen the way the `menu` face says a menu is
emphasised on a tty.

Two guile-gi facts, measured:

- `css-provider:load-from-data?` takes **two** arguments and the data is a
  **bytevector**; the C's third `gssize length` is folded into the marshalling.
  A string is refused with "Wrong type (expecting bytevector)".
- `<GtkCssProvider>` is not reachable as a class binding through the typelib
  module's interface, so the provider is made with `css-provider:new`.

The provider is attached to each widget's own style context rather than to the
screen, because a popup menu is a toplevel window of its own: a provider added
to the frame's widget would not follow it.

Verified on a live frame under a real display: the bar is `#bfbfbf` on
`#000000` (Emacs's default `mode-line`, grey75/blue), the `File` popup opens in
the same pair, and `css-provider:to-string` round-trips every rule, which is
GTK saying it parsed them.

**Still Emacs's**: this tree has no `menu` face at all, so nothing can override
the mode line's colours for menus specifically. That is the next step if the
two should be configurable apart.

# `C-x C-+` drew rows on top of each other (2026-11-13)

Chris, using the GTK front end: *"when I full screen the gtk interface and
start changing font size with `C-x C-+` things get corrupt. It's like the
non active window is not using the right font size and then there is
multiple mode lines, a large font one and a small font one, it's a real
mess."*

Two departures, and the second is the one that made the mess.

## 1. A window's rows stop at its text area, not at a row count

`display-window!` laid out `(window-body-height w)` rows and trusted the
frame's row grid for where each went. A row's *height* is not the frame's
line height: it comes from the faces on it, and `text-scale-mode` remaps
`default` for a buffer so a line is two or three lines tall. A scaled
window laid out the same number of rows and each was taller, so the rows
ran past the window's own bottom - over its mode line, and over the window
beneath.

GNU Emacs has the same row count and not the bug because the bound is a
**pixel**: `try_window`'s loop is `while (it.current_y < it.last_visible_y)`
with `last_visible_y = window_text_bottom_y (w)`. A tall line uses the
budget sooner, so a scaled window shows fewer lines.

`display-window!` now computes `y-limit` from the window's own geometry -
the top of its mode line - and stops laying rows out when the next would
cross it; the blank rows below a short buffer stop at the same bound.

**A departure inside the departure**: Emacs lays out a row that *starts*
above `last_visible_y` and clips it; this renderer has no per-window clip,
so a half row would paint over the mode line. A row that does not fit
entirely is not laid out at all, which shows one line fewer than Emacs at
the boundary.

## 2. A row is as tall as the frame's font, because that is what is drawn

`pgtk-ensure-font!` is one font per frame, and a *documented* departure:
`text-scale-mode` resizes the frame's font from the current buffer's
default face, where Emacs gives every row its own height and leaves other
windows alone. What did not follow that departure was `face-metrics`: it
answered each face's own `:height`, so the window next door - whose buffer
is not scaled - laid its rows out at the *unscaled* 21 pixels while
`pgtk-show-text!` drew its glyphs with the frame's font at 60. Rows 21
pixels apart, glyphs 60 pixels tall: each line was painted over the one
above it, which is the "large font and small font at once" in the
screenshot.

`face-metrics` now answers the frame's font, which is what the renderer
draws. Emacs measures per face because it opens a font per face; per-face
fonts are the renderer this file has not written yet (see
`pgtk-ensure-font!`), and until it is, a row's height has to be the height
of what is drawn. The *width* stays the frame's one cell for the same
reason `text-scale` cannot widen it: the column arithmetic assumes one
pitch.

## Tests

`pgtk-tests.scm` +1: row metrics equal the drawn cell, unscaled and at
scale 3 - the invariant the old code broke. Verified failing before the
change (21 against 60).

## Recorded, not fixed

- The blank rows below a buffer's end take their metrics from the frame's
  font as well now, so a scaled frame's blank rows are the scaled height,
  which is what is drawn but not what Emacs's per-buffer metrics would
  give for an unscaled buffer in the same frame.
- `:height` on a face that is not the default (a mode line's `0.9`, say)
  is likewise drawn at the frame's size, and its row is now that size too.
  Consistent, and still not Emacs's per-face model.

## `C-x C-+` rescales the frame, and Emacs's rescales a buffer (2026-11-13)

Chris: *"if I zoom it until the text is very tiny, and then go C-x C-f the
entire screen jumps to a bigger zoom level. That's weird. Also I just
noticed that the C-x C-+ in emacs does not zoom the mode line, only the
text. C-x C-M-x zooms the text and the mode line."*

### The jump: fixed

`pgtk-ensure-font!` reads the *default face's* height to choose the frame's
font, because this renderer is one font per frame. It read it from
`(current-buffer)`, and a prompt makes the minibuffer buffer current - so
the first keystroke of a `C-x C-f` in a zoomed buffer dropped the whole
frame back to the normal size for the length of the prompt.

The buffer it reads is now *the window being edited*:
`minibuffer-selected-window` (`minibuf.c`'s `Vminibuffer_selected_window`),
which `read-minibuffer-1` records when a prompt begins and which falls back
to the selected window when there is no prompt. That is a faithful port of
a C variable this tree did not have; measuring the frame from
`(current-buffer)` was the departure.

### The mode line: not fixed, and what it would take

In Emacs `text-scale-increase` remaps `default` *for the buffer*, and the
mode line is looked up as a named face on the frame, never through that
remapping - so the text grows and the mode line does not.
`global-text-scale-adjust` (`C-x C-M-+`) changes the frame's `default` face
itself, which is why that one scales the mode line too.

Reaching that here needs two things this renderer does not have:

1. **Per-face fonts.** `pgtk-show-text!` draws every run at
   `*font-pixel-size*`; the one-font-per-frame rule above is the same
   fact. Drawing a run at its own face's height, and measuring the row
   from it, is what `face-metrics` used to do before the other half was
   written - the two disagreeing was the "rows on top of each other" bug
   above.
2. **A pixel-based horizontal grid.** A scaled font is wider as well as
   taller. This renderer places glyphs on one column pitch per frame
   (`*cell-width*`), so a run drawn at twice the size would be twice as
   wide as its cells and overlap its neighbours. Emacs's `display_line`
   advances by each glyph's own width and wraps at `last_visible_x` in
   pixels; this one counts cells.

Until both are done, `C-x C-+` scales the frame (text *and* mode line, in
both windows), which is a visible departure from Emacs rather than a
hidden one. `C-x C-M-+` already behaves like Emacs's, because it changes
the face the frame font is read from.

# Menus on both front ends — the bar, the drop-downs, and what a hack looked like
# (2026-11-14)

`term.c`'s `tty_menu_*`, `menu.c`'s `x_popup_menu_1`/`x-popup-menu`,
`xdisp.c`'s `display_menu_bar`/`display_tty_menu_item`, `menu-bar.el`'s
navigation map/`popup-menu`/`menu-bar-open`, and `pgtkmenu.c`'s
`pgtk_menu_show` are ported. F10 opens the bar's first menu on both front
ends, arrows move, RET runs the command, left/right move between
menu-bar menus, and C-g pops down.

## Where each piece is

| Emacs | here |
|---|---|
| `tty_menu_*` (`term.c:3228-4300`) | `ui/tty/term.scm` |
| `tty-menu-navigation-map`, `popup-menu`, `menu-bar-open`, `menu-bar-menu-at-x-y`, `menu-bar-define-mouse-key` (`menu-bar.el:2690-3060`) | `editor/menu-bar.scm` |
| `x_popup_menu_1`, `x-popup-menu` (`menu.c:1111`, `:1433`) | `editor/menu.scm` |
| `display_menu_bar` (`xdisp.c:27756`), `display_tty_menu_item` (`:28003`) | `editor/xdisp.scm` |
| `read_menu_command` (`keyboard.c:1691`) | `editor/keyboard.scm` |
| `substitute-key-definition[ -key]` (`subr.el:1642`, `:1675`) | `editor/subr.scm` |
| `FRAME_TOP_MARGIN` (`frame.h:1132`), `f->menu_bar_vector` | `editor/frame.scm` |
| `pgtk_menu_show` (`pgtkmenu.c:588`), `create_and_show_popup_menu` (`:528`), `popup_widget_loop` (`:613`) | `ui/gtk/pgtk.scm` |
| `pgtk-menu-bar-open`/`accelerate-menu` (`term/pgtk-win.el:339`, `xmenu.c:579`) | `ui/gtk/pgtk.scm` |

## The screen is ours, so `screen_update` restores rows, not a matrix

Emacs builds a menu into the frame's desired glyph matrix and stashes the
current matrix; `screen_update` restores the desired matrix from it and
`update_frame_with_menu` diffs, rewriting only the cells the menu covered.
A terminal here *is* the screen, so the rows are written with
`write-glyphs!`'s primitives and "put it back" is a redisplay.

**Garbaging the frame was the first fix and it was wrong**: it clears the
whole screen and repaints it, a visible flash and not what Emacs does. The
restore is now `invalidate-frame-rows!` (`xdisp.scm`): the menu records the
frame rows each pane writes over, and those rows are marked disabled in
each overlapping window's *current* matrix (`!current_row->enabled_p`, the
diff's own test) with the window marked inaccurate so the rebuild runs.
`update_window` then rewrites exactly those rows and skips every other one.
Measured: an F10 + C-g cycle costs 3.5 KB and performs **no** screen
clear; the single `ESC[2J` in the stream is the startup repaint.

**Row granularity, not cell**: `update_text_area` is still not ported, so a
row is the smallest unit this redisplay diffs. That is the existing
departure, not a new one.

## `popup-menu` runs a plain procedure, because the buffer menu is one

Emacs's buffer entries are anonymous closures -
`(lambda () (interactive) (switch-to-buffer ...))` - and `popup-menu` ends
with `(call-interactively cmd)`. This tree's `dispatch-action` already ran
a plain procedure, but `popup-menu` required a command record, so every
Buffers entry did nothing when chosen from a terminal menu. It now runs a
plain procedure the same way the command loop does. `commandp` has no
counterpart for an anonymous lambda here, which is the reason the closure
is run directly rather than being passed through an interactive spec.

## `menu-bar-open`'s two arguments are optional

Emacs's is `(&optional frame initial-x)`; ours was a fixed two-argument
`define-command`, so `(menu-bar-open)` from Lisp was "Wrong number of
arguments". It is variadic now, with the interactive form still supplying
both.

## The GTK half

`menu-bar-open` dispatches on the frame's *display* - Emacs dispatches on
`(framep frame)` - through `*menu-bar-open-function*`, which the Gtk front
end installs in `with-gtk-display`. `pgtk-menu-bar-open` is
`pgtk-menu-bar-open`/`accelerate-menu`: rebuild the bar
(`set_frame_menubar (f, true)`) and `g_signal_emit_by_name` "activate-item"
on its first child; GTK then owns the arrows, Return and Escape.

`x-popup-menu` on a Gtk frame is `pgtk_menu_show`: a `widget_value` tree
built by pgtkmenu.c's own loop (a pane is a submenu only when it has a
name and the menu is not a keymap menu; the title is prepended with two
separators), a `GtkMenu` built from it by the existing `create_menus`
port, `gtk_menu_popup_at_pointer`/`_at_rect`, and `popup_widget_loop` - a
nested turn of the `gtk_main` the editor already runs inside - until the
selection or deactivate callback clears the flag. The selected item's
`call_data` is its index in `menu_items`; the walk back to the entry (with
the `MENU_KEYMAPS` prefixing) is ported line for line.

**Two FFI calls, and why.** `gtk_main_iteration` and the
`gtk_menu_popup_at_*` pair are not in the bindings guile-gi generated for
this typelib - its own `menu:popup-at-*` generics take a `GdkRectangle`
it made, and the rectangle here is a C struct - so they go through
`dynamic-func`, as the selections already do. The widget pointer comes
from the proxy's `value` slot (`<GFundamental>`), which is what
`(gi oop)`'s own commented-out `type-peek-object` reads.

**The popup's widgets are held, like the bar's.** `pgtk-create-menus`
holds every widget proxy for the display's life (guile-gi proxies own
their GObject through a toggle ref). The popup is destroyed after the
loop (`pop_down_menu`), so its proxies point at destroyed objects; they
are not dropped from the hold list. Same named departure as the bar's
rebuild.

## The measurement that says the GTK popup is real

Under `broadway`, a timer calling `(x-popup-menu '((10 . 10) FRAME) MAP)`
does not return: it is inside `popup_widget_loop`, and a second timer
fired from inside that loop is what ends the run. Before the port the
same call answered `#f` at once (`menu-show`'s `<display>` default).

**The walk back from the index to the entry is measured too**, because
that is the half a screenshot cannot see. `popup_selection_callback`
sets `menu_item_selection` to the clicked item's index; a timer running
inside `popup_widget_loop` sets the same variable and clears
`popup_activated_flag`, which is the whole of what the callback does,
and the menu then answers. Measured on a keymap menu of two items
(`define-key` prepends, so the array holds them in reverse definition
order - `menu_items` itself was dumped to check that):

| index chosen | `menu_items` at that index | answer |
|---|---|---|
| 3 | `Banana`, key `#(98)` | `(98)` |
| 11 | `Apple`, key `#(97)` | `(97)` |

So the answer is the item's key sequence as a proper list - which is
`entry = list1 (AREF (...))` and then `Fcons (prefix, entry)` - and
`popup-menu`'s `(list->vector event)` looks it up. An index off by one
would answer the other item's key; a wrong list shape would fail the
lookup rather than answer wrongly.

The *tree building* is a pure function of `menu_items` and the flags,
so it is a unit test rather than a broadway run:
`pgtk-tests.scm` pins the pane-is-a-submenu rule (`pgtkmenu.c:659`),
the lone-pane flattening (`:653`), the title's two separators
(`:745-760`), the `call_data` index (3 for a one-pane list's first item,
14 for the second pane's, from 3-slot panes and 8-slot items), and that
a bare string in the old list form is a *disabled* item rather than a
missing one (`list_of_items`, `menu.c:470`).

## Deliberately not carried

- **The terminal mouse**: no GPM and no `xterm-mouse-mode`, so
  `mouse_get_xy`, the mouse branches of `read_menu_input`, and the
  `S-mouse`/`wheel`/`C-down-mouse` behaviour cannot be reached. The
  bindings are made as the C makes them anyway.
- **`tmm-menubar`**: `tty-menu-open-use-tmm` non-nil says it is not
  ported rather than opening nothing.
- **`newline-and-indent` (C-j)** and `keyboard-escape-quit`: the missing
  primitives are `indent-according-to-mode` and the command itself; the
  navigation map's entries for them are symbols that can never match a
  procedure, so they are no-ops rather than wrong.
- **The help echo**: `tty_menu_help_callback` exists and does nothing -
  there is no `show_help_echo` here - but the pane/item bookkeeping the C
  does for it is ported.
- **`x-menu-bar-open-internal`'s X-toolkit (non-GTK) branch**, the
  Motif/XI2 grab dance: it is the Lucid toolkit's, and this tree has Gtk.

## The window is below the bar

`FRAME_TOP_MARGIN` is menu-bar-lines + tab-bar-lines **for a terminal
only**. A Gtk frame's bar is a widget stacked above the drawing area, so
its text area already begins below it and `FRAME_MENU_BAR_LINES` is 0 in
Emacs - `frame-top-margin` returns 0 for a window-system display and the
tty rows otherwise. Windows are tiled from the margin (`new-frame-on`,
`resize-frame-windows!`, `delete-other-windows`), and `set-frame-parameter
'menu-bar-lines` re-tiles, which is what `menu-bar-mode -1` needs to give
the row back.

## The arrows

Emacs binds `[left]`/`[right]` to `left-char`/`right-char`
(`bindings.el:1412-1415`), and `tty-menu-navigation-map` substitutes
those commands for `tty-menu-prev-menu`/`next-menu`. This tree bound the
arrows to `backward-char`/`forward-char` and had neither command, so the
arrows did nothing in a menu. `right-char`/`left-char` are ported
(`simple.scm`; `bindings.el` has no library here) with the bidi branch
degenerate - no bidi text, so they are `forward-char`/`backward-char` -
and the arrows are bound to them.

## The rest of the navigation map

`C-r` selects, `wheel-left`/`wheel-right` move between menus,
`S-mouse-1`/`S-drag-mouse-1` step forward and the `S-mouse-2`/`3` pair
step back, `C-down-mouse-1/2/3` ignore, and `mouse-movement` is bound to
`tty-menu-mouse-movement`, all as `menu-bar.el:3030-3077` has them.

## `MENU_FOR_CLICK`, and the quit that killed the editor

The event path through `x_popup_menu_1` sets `MENU_FOR_CLICK`, which is
what makes cancelling a menu-bar menu pop it down silently
(`term.c:4257`); without it every C-g signalled quit. Two more things had
to be right for C-g in a menu to behave:

- **`read-menu-command` hands a pending quit back as the quit *key***,
  as `read_char` does (`keyboard.c:2806`), and clears the flag the way
  `read_char` clears it. Without the clear the flag leaked past the menu
  and fired as a quit at the next command, which killed the editor.
- **`read-menu-command` reads with a 100 ms deadline.** Emacs's `pselect`
  is interrupted by SIGINT (its handlers are installed without
  `SA_RESTART`); Guile's `select` is restarted across it, so a blocking
  read never returned and C-g was invisible. The deadline makes the read
  finite, and `read-key-event`'s `maybe-quit` then runs. This is a poll
  where Emacs has a signal; it exists only while a menu is open.

## Tests

`menu-tests` 16, `menu-bar-tests` 28, `menu-bar-menus-tests` 7,
`subr-tests`, `keymap-tests` 89, `tty-editor-tests` 304, `pgtk-tests`
106, `mouse-tests` 43. The pgtk suite's nine new ones are the popup's
tree, above. The unit fixtures run with the bar off, as Emacs's own
tests do.

`tools/pty-check.py` has a `tty-menu` check, the one that runs with the
bar *on*: the bar is the first row, F10 drops File, the right arrow
leaves File for Edit (asserting File's items are *gone* from the composed
screen), and C-g pops down without "Quit". Every other check has the bar
off through its init file, because the bar is the frame's first row and
most checks measure text from row 0.
