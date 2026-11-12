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
