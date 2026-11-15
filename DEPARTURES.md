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

## Arrowing past the end ran the last item (Chris found it)

Chris: *"if you arrow down past the end it executes the last command in
the menu whereas it should wrap back to the top"* - and on the File menu
the last command is Quit, so the editor also left.

`tty_menu_activate`'s loop sets `leave = 1` as soon as `read_menu_input`
answers anything but `MI_CONTINUE`, and the navigation cases put it back
with `leave = 0`. Three do (`MI_NEXT_ITEM`/`MI_PREV_ITEM` when not
`kbd_navigation`, and both scroll cases). **The port restored it for the
first two and not for `MI_SCROLL_FORWARD`/`MI_SCROLL_BACK`**
(`term.c:3751`, `:3764`). So a scroll past the end *ended* the loop with
`result`, `pane` and `selidx` still holding whatever the last hit test
found - the item under the cursor, which is the one at the end of the
menu - and `tty_menu_show` mapped that to an entry, so the command ran.
The wrap arithmetic itself was right: `y = min_y; first_item = 0`.

This is the same shape as the note above it - a C statement whose
absence leaves a variable holding a stale-but-plausible value - and it
is only visible by *using* the menu: every in-range arrow press behaved.

`tools/pty-check.py`'s `tty-menu` check pins both directions now: 18
downs (the File menu's 18 entries) then RET must prompt `Find file: `,
and one up from the top must reach the bottom item, which is Quit, so
the editor leaves. Both were seen failing with the two lines removed.

## The second half of that bug: a scroll was not "usable input"

Chris, after the `leave = 0` fix: *"it takes 2 down arrows to arrive at
the top, and when it does, it arrives at the 2nd top one, not the top"*
- and *"if the menu is too big for the terminal, real emacs scrolls, ours
sort of scrolls, but it's just a mess"*. Both were one line, and they
were the same line.

`read_menu_input` answers a status **and** whether the input "moved" the
menu (`usable_input`, which becomes `sf->mouse_moved`). The caller
redraws the pane only when it did. In the C `usable_input` starts at 1
and is cleared in exactly two places: `tty_menu_next_menu`/
`prev_menu`, and a command that is not a menu command at all. **Every
scroll, and `tty_menu_ignore`, leave it 1.** The port answered #f for
all three.

So a scroll changed `first_item` and never repainted: a menu taller than
the screen scrolled "in the dark" (the mess), and at the bottom the
first down scrolled the list by one without drawing it, the second
wrapped, and the *next* down was the first thing to repaint - which put
the highlight on the second item. Exactly what Chris described.

Fixed in `read-menu-input`'s two scroll arms and the ignore arm.

## The key equivalents were never computed at all

Chris: *"why don't we have the menu showing the key combos like emacs?"*
Because `parse_menu_item`'s last step was skipped: the note in
`keyboard.sld` said so ("the key-equivalent computation is not carried")
and named the reason - `where-is-internal` "exists here only in the
reduced `keymap-lookup-binding-key` form". That was a placeholder that
had no business surviving a pass that called itself a port.

The whole chain is ported now, in the C's own decomposition:

| Emacs | here |
|---|---|
| `get_keyelt` (`keymap.c:681`) | `get-keyelt` in `keymap.sld` - it was inline in `access-keymap`, and `where_is_internal_1` and `accessible_keymaps_1` both need it |
| `accessible-keymaps` (`:2010`) | `accessible-keymaps`, breadth-first, grown in place with `set-cdr!` so the order is the C's |
| `append_key` (`:1456`) | `append-key` - `(vconcat seq (list key))` |
| `vconcat` (`fns.c:750`) | `vconcat` in `fns.sld`; the primitive was missing outright |
| `where_is_internal` (`:2496`) and `where_is_internal_1` (`:2787`) | `where-is-internal-walk`, `where-is-internal-1` |
| `where-is-internal` (`:2588`) | `where-is-internal` |
| the KEYEQ block (`keyboard.c:9095`) | the same block in `parse-menu-item` |

**Placement**: all of it is `keymap.c`'s, and the DEFUN's default for its
KEYMAP argument is `current-active-maps`, which is `keyboard.c`'s - in
this tree `lookup-keymaps`. `keymap.sld` sits under `keyboard.sld`, so
the DEFUN is there and the two walkers are in `keymap.sld`.

**The one bridge the tree needs and Emacs does not**: Elisp's keymaps
hold the command *symbol*, so the C's `EQ (binding, definition)`
compares like with like. This tree's keymaps hold the value
`define-command` made, while a menu item may still name its command as
the symbol the C would - `(menu-item "Save" save-buffer)` - which is
what `dispatch-action` exists for. `where-is-internal` resolves a symbol
through the obarray with `command-value-of` before searching. Without
it, every menu item that names a symbol found no key at all, which is
what the first version did.

**Not carried**, each because the feature it consults does not exist
here: command remapping (`[remap ...]`, so `remapped` is always false),
`:advertised-binding`, `where_is_cache` (it exists for the menu bar's
many calls per redisplay; this tree rebuilds a menu only when its
`menu_items` change), and `substitute-command-keys` for a `:keys`
*string* (the string is used as it stands - the same departure
`help-echo-substitute-command-keys` already carries). A `menu_item`'s
`:filter` is likewise not applied by `get_keyelt` (`autoload` is #f from
every caller here).

Measured, the File menu against Emacs 31.1's on the same terminal:

```
Visit New File...     C-x C-f     Emacs: same
Open Directory...     C-x d       Emacs: same
Save                  C-x C-s     Emacs: same
Save As...            C-x C-w     Emacs: same
Remove Other Windows  C-x 1       Emacs: same
New Frame             C-x 5 2     Emacs: same
Delete Frame          C-x 5 0     Emacs: same
Quit                  C-x C-c     Emacs: same
```

and the ones with no key ("Close", "Revert Buffer") have none in either,
which is `preferred-sequence_p` doing its job - a sequence carrying a
modifier is not preferred, and `(car found)` is the fallback.

`keymap-tests` 98 (9 new: the empty prefix first, keymaps only, the
cycle break, `get_keyelt`'s two coercions, `append-key`, `vconcat`), and
the `tty-menu` pty check asserts the keys beside three items and was
seen failing with the KEYEQ block removed.

## Tests

`menu-tests` 16, `menu-bar-tests` 28, `menu-bar-menus-tests` 7,
`subr-tests`, `keymap-tests` 98, `tty-editor-tests` 304, `pgtk-tests`
106, `mouse-tests` 43. The pgtk suite's nine new ones are the popup's
tree, above. The unit fixtures run with the bar off, as Emacs's own
tests do.

`tools/pty-check.py` has a `tty-menu` check, the one that runs with the
bar *on*: the bar is the first row, F10 drops File, the right arrow
leaves File for Edit (asserting File's items are *gone* from the composed
screen), and C-g pops down without "Quit". Every other check has the bar
off through its init file, because the bar is the frame's first row and
most checks measure text from row 0.

# The overlays are an interval tree, as Emacs 29.1 made them

This is the fix for the `C-s` slowness, and it is Emacs's own fix rather
than a new one: `src/itree.c` and `src/itree.h` are ported into
`schemacs/editor/itree.scm`, and `buffer.c`'s overlay half is rewritten
onto them.

## What was wrong

The overlays were a **plain list per buffer, in order by start**, with
the two ends of an overlay being markers. `make-overlay` inserted into
the list with a linear walk, `delete-overlay` removed with another,
and `overlays-at` walked the whole list - and isearch's lazy highlight
makes one overlay per match on *every* keystroke. The splash buffer is
998 bytes and holds 270 `8`s, so each `C-s 8` was ~36,000 list
rebuilds for the 270 insertions plus a walk of all 270 for every face
run the redisplay drew.

That is the model GNU Emacs used *before 29.1*. Emacs replaced it, and
`etc/NEWS.29` says why in one line: "speed up all the operations that
involve overlays, especially when there are lots of them in a buffer."
The structure that replaced it is what is ported here.

## Measured

One keystroke's worth of work, with the 270 matches the splash buffer
really has, on the compiled tree - the new path and a reconstruction of
the old list algorithm (`HEAD`'s `add-buffer-overlay!` and
`overlays-at`) in the same process, so both see the same clock:

| | old list | interval tree |
|---|---|---|
| make 270 overlays (and give each its two properties) | 11-13 ms | **0.71-0.74 ms** |
| `overlays-at` at each of the 270 positions | 22.7 ms | **0.27 ms** |
| delete 270 overlays | another O(n) walk per overlay | **0.6-1.1 ms** |

and the renderer's half: `render!` on the splash is ~1-2 ms whether
there are 0, 100 or 270 overlays, where before each face run walked the
whole list. So the keystroke cost went from tens of milliseconds, most
of it in the overlay structure, to about 2 ms plus the draw.

**The old numbers are a reconstruction, not a checkout.** The list
functions were copied into the benchmark from `git show
HEAD:schemacs/editor/buffer.scm`; the tree was not reverted to measure
it, because the same algorithm is a dozen lines and identical either
way.

## What landed

`itree.scm` is `itree.c` function for function, with the C's comments
that state the algorithms kept beside them:

| `src/itree.c` | here |
|---|---|
| `struct itree_node`, `struct itree_tree`, `struct itree_iterator` | the three records, same fields |
| `itree_insert_node`, `itree_insert_fix`, the two rotations | same names, `-` for `_` |
| `itree_remove`, `itree_remove_fix`, `itree_replace_child`, `itree_transplant` | same |
| `itree_insert_gap`, `itree_delete_gap` | same, including the `saved` stack and the `before_markers` flag |
| `itree_iterator_start/next/narrow`, `itree_iter_next_in_subtree` | same, with the four orders as symbols |
| `check_subtree`, `check_tree` | `itree-check-tree`, exported for the tests - the C runs it only under `--enable-checking=overlays` |

`buffer.scm` is `buffer.c`'s overlay section onto it: `<overlay-type>` is
`struct Lisp_Overlay` (`buffer`, `interval`, `plist`), the `<buffer>`
record gained the `overlays` field (`buffer.h:718`), and `make-overlay`,
`move-overlay`, `delete-overlay`, `delete-all-overlays`,
`overlays-at`, `overlays-in`, `next-overlay-change`,
`previous-overlay-change`, `overlay-lists` and `overlay-recenter` are
the C's. `insdel.scm` calls `adjust_overlays_for_insert` and
`adjust_overlays_for_delete` at the end of its three marker functions,
where `insdel.c` calls them.

## Departures this fixed, not introduced

- **`make-overlay` now clips to the buffer.** The old version kept
  whatever was passed, so `(make-overlay 0 5)` on a buffer whose first
  position is 1 made an overlay starting outside the text. Emacs:
  `obeg = clip_to_bounds (BUF_BEG (b), XFIXNUM (beg), BUF_Z (b))`.
  Three `buffer-tests` cases had encoded the old answer; they are
  Emacs 31.1's answers now.
- **`previous-overlay-change` starts at `BEGV`**, not 0.
- **`overlays-in` includes empty overlays** as `overlays_in` says:
  at BEG, between BEG and END, or at END when END is `point-max`.
- **`evaporate` is implemented** in `overlay-put` and `move-overlay`,
  which it was not at all.
- **`overlay-lists` and `overlay-recenter` exist**; the latter is the
  no-op Emacs 29.1 made it, kept because ported Lisp still calls it
  (`simple.el:1431`, `subr.el:4514`).
- **`overlay-put`'s ordering when the property is `evaporate`**: the C
  checks after `modify_overlay`, and so does this.

## Departures that remain, each named at its site

- **The overlay modification hooks** (`buffer.c`'s
  `report_overlay_modification`, the `modification-hooks`,
  `insert-in-front-hooks` and `insert-behind-hooks` properties) are not
  carried - they were not before either.
- **The `window` property** is not carried, and `overlays-at`'s SORTED
  argument does not filter by window; there are no window-specific
  overlays here.
- **A marker as BEG or END** to `make-overlay`/`move-overlay` is not
  carried: every caller passes an integer.
- **There are no indirect buffers**, so the C's indirection branch of
  `adjust_overlays_for_insert`/`_delete` has no counterpart.
- **`itree_stack_destroy`** is Guile's collector; the stack itself is
  ported because `itree_insert_gap` indexes `saved->nodes[i]`.
- **`eassert` is not carried** into the running code (Emacs compiles its
  own out by default); `itree-check-tree` is where that class lives.

## Tests

- `schemacs/editor/itree-tests.scm` (new, 37): the C's
  `test/manual/noverlay/itree-tests.c` cases - the insert rotations,
  the eleven gap-insert and eight gap-delete cases with every
  combination of the advance flags, `itree-node-set-region`, the four
  iterator orders - plus a **randomised model test**: 400 operations of
  insert/remove/insert-gap/delete-gap against an independent
  list-of-intervals model, with `itree-check-tree` after every
  operation. The model's gap rules are written out independently of
  `itree.c`, so a shared misreading shows up as a mismatch.
- `buffer-tests.scm` 28: the three cases that had encoded the
  unclipped answers are Emacs 31.1's.
- The pty battery covers what the Lisp-level tests cannot: isearch's
  overlays, the region highlight, dired's `dired-remove-entry` (a
  `delete-overlay` caller), the Buffer Menu's marks, and the whole
  editor starting.

## Found on the way: `buffer-live-p` is the name, not the list

The C's `make-overlay` and `move-overlay` ask `BUFFER_LIVE_P (b)`
(`buffer.h:1143`), which is `!NILP (BVAR (b, name))` - the buffer has a
name. This tree's `buffer-live-p` instead answers "is it in
`*buffer-list*`", and the two are not the same thing: a buffer made by
`allocate-buffer` directly (as `buffer-tests` and the benchmark harness
do) has a name and behaves like a live buffer, but is not in the list
until `get-buffer-create` registers it.

The two overlay functions now test the **name**, which is the C's rule,
so they are right either way. `buffer-live-p` itself still tests the
list, which is a departure from the Lisp function: Emacs's
`Fbuffer_live_p` is the same `BUFFER_LIVE_P`. It is not fixed here
because its callers are the kill/display paths (`kill-buffer`,
`window.scm`'s buffer records, the Buffer Menu), and changing what
"live" means under them wants its own pass and its own battery.

# C-g during a search killed the tty editor

Chris: *"if I hit C-g in the middle of a search the edit dies"* - and
*"it's only the tty editor that dies on C-g"*. Both true, and the death
was `exit 1` with `%quit-condition` on the terminal.

## The chain, and the three C lines that are each half of it

1. **A terminal turns C-g into SIGINT.** `init_sys_modes` keeps `ISIG`
   on (`sysdep.c:1147`: "Enable signals"), so the byte never reaches the
   read; `handle_interrupt_signal` records the request in `Vquit_flag`.
2. **The interrupted read answers the C-g *key*, not a quit.**
   `read_char`'s `sys_setjmp` branch (`keyboard.c:2806`) does
   `XSETINT (c, quit_char)` and returns it as the event, which is how
   isearch sees the `C-g` its map binds.
3. **The flag is cleared after the key is read.** `read_key_sequence`
   does `Vquit_flag = Qnil;` for every event it reads (`:11892`), and
   `read_char` does it for the interrupt when `Vinhibit_quit` is set.

This tree had (1) and (2) and not (3): the tty's `read-input-event`
answered `quit_char` for the flag (`term.scm`), and its comment said
"the flag is left for `read-key-event`, which is what clears it" - but
`read-key-event` never did. So isearch aborted correctly, and then the
*next* `maybe-quit` - at the top of the next read - raised a quit
condition. That read is the command loop's own, and it was outside the
loop's `guard`, so the condition reached the top level and the editor
exited.

Two more details were wrong in the same direction: `%wait-and-read`
preferred a ready byte to the quit flag (the C's longjmp prefers the
quit, and the byte is read next time), and `read-input-event` preferred
pushed-back query bytes and a read byte to the flag.

## Fixed

- `read-key-event` clears `*quit-flag*` when it answers `quit-char`,
  which is `read_key_sequence`'s line.
- The tty wait and read answer `quit_char` **before** any byte, so a key
  that arrived with the signal is not swallowed (`%wait-and-read` returns
  without consuming it).
- **The command loop's read is inside the error guard**, as
  `command_loop_1`'s `condition-case` wraps `read_key_sequence`. A quit
  raised there is now reported as "Quit" and the loop goes on reading,
  which is `cmd_error`'s answer; before, it exited the editor.

`tools/pty-check.py`'s `quit-signal` grew the isearch leg: C-s, 8, C-g,
then a key that only a live editor can insert - and asserts the mode
line's `**` and that no `%quit-condition` reached the screen. Verified
failing with the flag-clearing line removed (the editor exits 1).

# isearch copied the rest of the buffer on every keystroke

`text-editor-search-forward` built `(make-buffer-string ed start
(buffer-z ed))` and searched *that*. On the splash (998 bytes) the copy
is nothing, which is why the overlay cost was what showed there; on a
240 KB file it measured **9.3 ms per keystroke at the top of the file**,
linear in the size of everything after point - and a C-s repeat, a C-r,
or a failing search all pay it too.

Emacs's `search_buffer` (`search.c`) scans the buffer from point and
stops at the first match. `text-editor-search-forward`/`-backward` are
that scan now: read the character at P, and only when it matches the
pattern's first character compare the rest. Measured on the same file:
**0.005-0.045 ms**. The matching rule is unchanged - `code-point->char`
and `%fold`, which is what `string-search-forward` applied to the copy,
so byte characters and case folding behave exactly as before.

The copy remains the right tool where the range is known and small -
`looking-at`, `re-search-forward` - and those were not changed.

# The test suite was deleting the developer's compiled files

`tools/run-suites.py` deleted this tree's entries out of
`~/.cache/guile/ccache` before running, so that a stale `.go` could not
be loaded. The effect of that is that **the next editor started was
interpreted**. Measured, one C-s keystroke on the 240 KB file: **25 ms
compiled, 430 ms interpreted** - and which one you got depended on
whether a test had been run since the last compile. That is a
performance bug in the harness, not the editor.

The suites now get `XDG_CACHE_HOME` pointed at a fresh temporary
directory: nothing cached can be stale, and the developer's cache is
never touched. `drop_tree_ccache` is deleted with it.

# The failing scan, and the hoisted store

The scan above still called `buffer-text-ref` per character - `%at`'s
two record reads and the base subtraction - and converted every
character to a `#\char` to fold it. A failing search in a 240 KB file
therefore cost **92 ms case-sensitively and 94 ms folded**, which is what
an isearch keystroke that extends the pattern into "not found" spent.

Two changes, both of them things `search.c` does that the port did not:

1. **The store is read directly.** `search_buffer` reads through the
   `BUF_BEG_ADDR`/`GPT` macros, which the C compiler expands *into* the
   loop; here the accessors were called, which is the same algorithm at
   an interpreted-accessor price. `buffer-text-store` and
   `buffer-text-gpt` are exported for exactly this - they are Emacs's
   `BEG_ADDR` and `GPT` - and the scan hoists them, testing the gap once
   per character with a fixnum compare. Editing still goes through the
   primitives; these two are read-only.

2. **The first-character prefilter compares code points.** `FETCH_CHAR`
   and `trt`-lookup are integer work in the C. Here every character was
   turned into a character and folded before it was compared, so the
   prefilter - the thing that exists to make the scan cheap - cost as
   much as the match test it was avoiding. The needle's first character
   is converted once (`first-cp`, its downcase and its upcase, and its
   folded form) and the per-character test is integer compares.

Measured on the same 240 KB file, 240,000 characters scanned with no
match:

| | before | after |
|---|---|---|
| failing forward scan | 92.1 ms | **4.9 ms** |
| failing forward scan, case folding | 93.9 ms | **5.7 ms** |
| failing backward scan | 89.6 ms | **4.9 ms** |
| a match on the first line | 0.012 ms | 0.003 ms |
| four isearch keystrokes (three found, one failing) | 158 ms | **22.9 ms** |

In a live editor the scan is ~8 ms of a ~14 ms keystroke (render 0.7 ms,
lazy highlight 0.1 ms; the rest is the command loop and the terminal).
`boyer_moore` (`search.c:1746`) is the C's other half of literal search
and is deliberately **not** ported: for a repeated-character pattern
every character of the pattern has shift 1, so the skip table degenerates
to the naive scan, and that is the workload this measurement was taken
on.

## A departure this found, and fixed

The first version of the prefilter compared folding by `char-upcase`
alone. `char-upcase` of an uppercase needle is itself, so an uppercase
needle ("BETA") never compared equal to the lowercase text it folds
against - `search-forward` with `case-fold-search` on and an uppercase
pattern silently found nothing. Both casings are compared now, and
`engine-tests.scm` has the uppercase-needle case.

## The gap is now genuinely exercised

`engine-tests.scm`'s search group inserted at the end of the buffer, so
the scan never read a position *past* the gap - the after-gap branch of
the hoisted access was untested. Six cases added: a match wholly past
the gap, one that starts before it and ends after it, the backward
versions, and the folded one; `split-searchable` puts the gap in the
middle with an insertion at point 6.

# The row's glyphs are written over, not made again

`line-slice-glyphs` made a fresh `<glyph>` record per cell on every
redisplay - 1,920 of them for an 80x24 frame - and
`extend-face-to-end-of-line` made a second 80-slot vector and up to 80
more records per row for the padding. GNU Emacs builds a window's rows
into a **glyph pool allocated once** and writes them over
(`append_glyph` fills `row->glyphs[area][row->used[area]++]`), so a
redisplay's only allocation is the matrix a window does not have yet.

The rows now keep their vectors across redisplays (`prepare_desired_row`'s
"row->enabled_p = true; row->used = 0"), those vectors are written
through by `%reset-glyph!`, and the padding is appended into the same
storage. `build-blank-row!` keeps its storage too instead of resetting
it to `(vector)`. Measured allocation for one 24x80 render: **433 KB ->
332 KB**, and the row's glyph objects are proven reused - a probe holds
the object in a slot across three renders and gets `eq?` (#t), which a
copy-based allocator could not.

**The remaining 332 KB is not the glyphs**; it is the per-row lists
`line-texts-glyphs`/`line-texts-offsets` and the face runs, which are
still built per redisplay. Emacs's `display_line` appends glyphs
directly from its iterator and builds none of them; walking the line
into the row in one pass is the next step, and it is a rewrite of the
row builder rather than a change inside it.

## The one-character strings, which Emacs does not make

A `CHAR_GLYPH` in the C carries the character itself (`glyph->u.ch`), and
the string for a run is built once when the run is written. Here a glyph
carries a *string*, so `(string c)` was one allocation per cell per
keystroke. `disp-table.scm` keeps a 256-entry cache of the one-character
strings for code points below 256 (ASCII and Latin-1: drawn as
themselves), and the else branch still makes a fresh string for wide
characters, tabs and caret notations, whose text depends on the column.
This is a representation departure - Emacs has no such table - and it is
2 KB against 1,920 allocations a redisplay.

# The search ring, and why the first C-s after a search did nothing

## `C-s C-s` searches the last search

`search-ring` and `isearch-error` are `isearch.el`'s (`:253`, `:210`),
with `search-ring-max` a defcustom, `isearch-update-ring` over
`add-to-history` (propertizing the string with its case folding, which
comes back out when it is reused), `isearch-ring-adjust1`'s pointer walk,
and `M-n`/`M-p` (`isearch-ring-advance`/`-retreat`) bound as
`isearch.el:639-640` bind them. The empty-repeat rule is Emacs's, at
`isearch-repeat` (`:1953`): "If search string is empty, use last one" -
so `C-s C-s` searches what the last search ended on, and an empty ring
says `[No previous search string]`.

**A departure, named**: Emacs's `isearch-ring-adjust` only searches when
`search-ring-update` is non-nil and otherwise calls `isearch-edit-string`,
which moves the string into the minibuffer for editing. There is no
isearch minibuffer edit here, so the ring always searches; that variable
is not carried.

**`M-s` is not history in Emacs** - it is the `isearch-toggle-*` prefix
(`isearch.el:630-684`) - so the ring keys are `M-n`/`M-p`. Measured on
Emacs 31.1 in a pty: `C-s M-s C-g` says "M-s C-g is undefined".

## The repeat searches from point, not from the match's start

`isearch-find` backs up by the pattern's length, which is the rule a
*typed* character needs: an extended pattern must retry where the current
match began. A *repeat* has no match to retry, and with the backup
`C-s C-s` re-found the very match point had just left. `isearch-repeat`'s
ring branches and `M-n`/`M-p` now call `isearch-search-from-point`, which
is `isearch-search` launched from `isearch-repeat`'s barrier - from
point, inclusive. Measured: in "one 111 two 111 three", a search for
"111" ends at C7, and the old `C-s C-s` stayed there instead of moving to
the second 111 (C15).

## Gtk stranded every key that arrived while it was busy

The outermost command loop of this front end **does not read**: Gtk hands
each event straight to `command-loop-key!` (`*dispatch-event*`). But
`pgtk-enqueue!` queued an event whenever it could not dispatch it then -
a command running, or a redisplay in progress - and **only a read drains
the queue**. At the outermost level there is no read, so a key that
arrived in either window sat in the queue until the next prompt or
isearch consumed it, late and out of order, or for ever.

Measured with the display's own queue: three keys queued, then one
delivered while the editor was idle; the idle key ran (self-insert), the
three were still queued afterwards, and the next key to arrive
dispatched itself ahead of them. `pgtk-drain-queue!` is the missing
read: the queue's items are dispatched oldest first, through the same
two decodes a read uses, until it empties or a command leaves a read
outstanding (which then owns the rest). This is Emacs's `kbd_buffer`
order, and the fix makes the three queued keys run first, in order.

**This is not what "C-s broken for ever after the first search" was** -
that is the section after this one. A stranded key waits for the next
key; Chris's C-s never came back.

**And the drain has to happen when a redisplay ends, not only when the
next event arrives.** The cursor-blink timer repaints straight from a
Gtk source (`gtk-main.scm`), with no read anywhere; a key pressed during
that repaint is queued by the branch above, and until the next key there
was nothing to collect it. `redisplay-frames!` runs
`*after-redisplay-hook*` once every frame is drawn (Emacs has no such
hook because its command loop reads again the moment redisplay returns;
the terminal front end has no queue, so the hook is `#f` there), and the
Gtk front end installs the drain there. `pgtk-drain-queue!` guards
itself against re-entry: the hook can fire inside a dispatch's own
redisplay, and running a command from inside another command's redisplay
is what `*redisplay-in-progress*` exists to stop.

*(A first version tried to arm an idle or timeout source from
`pgtk-enqueue!` instead. Both wedged the REPL session that ran them and
the source never fired - measured: the client expression timed out while
the editor kept serving new sessions - so the hook is the mechanism that
works.)*

# The row is filled only where the face says `:extend`

Chris: *"If I'm searching for 888 in the splash screen when it gets to a
line that ends in 888 ... it paints it to the end of the line."* Right,
and it is the departure the row-filling pass left standing: the padding
used the last glyph's face unconditionally.

GNU Emacs's `extend_face_id` (`xdisp.c:24429`) is

    (it->face_id == default_face->id || it->s != NULL)
    ? it->face_id
    : (row->ends_at_zv_p ? default_face->id
       : face_at_pos (it, LFACE_EXTEND_INDEX));

and `face_at_pos` with the EXTEND filter merges only the faces at the
position that **specify** `:extend` (`merge_named_face`,
`xfaces.c:2527`). `isearch` and `lazy-highlight` do not specify it, so a
match at the end of a line stops at the match; `region` does
(`faces.el:2559`), so a region reaches the edge. Measured on Emacs 31.1
in a pty, the match is written as `\e[36m\e[45m888\e[39;49m` - three
cells, the padding back in the default face - where this port painted
the highlight to column 80. `extend-fill-token` is that rule, and
`tools/pty-check.py`'s `isearch-line-end` is the check (it fails with
the old code).

**Departure still standing**: when the merged `:extend` is true, Emacs's
fill face is the merge of the *extending* faces alone - a font-locked
word inside the region fills with the region's background and the
default foreground. This port fills with the last glyph's token, which
also carries the font-locked word's colours. The colours differ only
when two faces overlap at a line's end.

## The region is an overlay in Emacs, and a special case here

GNU Emacs 29+ highlights the active region with an **overlay** made by
Lisp (`redisplay--highlight-overlay-function`, `simple.el:7300`), so the
region face is merged like any other overlay's and its `:extend t`
reaches `extend_face_id` through the normal route. This tree merges the
region in `attrs-at-buffer-position` instead (there is no
`pre-redisplay-functions` machinery), which is observable in one place:
an *empty* region - point equal to mark - must cover no characters, and
`face-change-limit` split a run at its position anyway. It does not now.

# The row builder builds no lists

`line-slice-glyphs` built two lists per row - `line-texts-glyphs` and
`line-texts-offsets` - and walked them. Emacs's `display_line` appends
each glyph as its iterator produces it and builds neither. The walk is
now one pass: for each column, `texts-glyph`/`texts-width` give the
string and the width, the runs are consumed in step, and the glyph is
written into the row's own storage. Allocation for 50 keystrokes on a
240 KB file: **10.3 MB -> 8.4 MB**. Wall time on a loaded machine was
the same for both (the two accessors are cross-library calls either
way); the saving is the garbage.

The dead `text-cells-width`, whose only caller was the old last-glyph
width, is gone, and `line-texts-offsets`/`line-texts-glyphs` are no
longer imported here (they remain `indentc`'s, where the hscroll
arithmetic uses them).

# A suite that crashed in its second group was scored green

`tools/run-suites.py` treated a run as finished if the text "Test suite
finished" appeared anywhere. `srfi 64` prints that at the end of **each**
group, so `faces-tests.scm` - whose second group crashed with "Wrong type
argument ... expecting struct: #f" - was reported green on every run for
months. The check is now that every `Entering test group` has a `Leaving
test group`, and `faces-tests` is 35 passing tests where it was 16.

Four things were under the crash, each now fixed:

1. **The tests called the row walk without the buffer current.**
   `line-face-runs` asks the *current* buffer for overlay changes, as the
   C does; `display-window!` binds the window's buffer for that reason.
   In a fresh process the current buffer was `#f`, so
   `next-overlay-change` raised. The tests bind `*current-buffer*` now
   (`runs-for`).
2. **An empty region split a run** - see above.
3. **Three background-mode tests were outside any group**, and this
   Guile's `srfi 64` raises "expecting struct: #f" for a test evaluated
   outside a group once a group has ended (measured with a two-group
   scratch file). They could never have run; they are in a group now.
4. **One of them expected the symbol `cyan`** where a colour attribute
   holds the string `"cyan"` (Emacs's `(face-attribute 'minibuffer-prompt
   :foreground)` is a string). It had never run, so nobody had seen it.


# `C-s` broken for ever on Gtk: Return was a symbol, and the pushed-back
# key had no reader

Chris: *"If I press C-s 8 RET C-s, the last C-s does nothing, no visible
prompt, no sign that it registered at all"*, then *"it's not like another
C-s will work, C-s is broken forever after the first one works. C-g
doesn't fix it. Other commands continue to work."*

Every detail follows from two departures meeting.

1. **A Gtk Return is the *symbol* `return`, not 13.** `keysym-event`
   builds the key event from the keysym, and `function-key-map`
   (`keyboard.scm`, `Return` -> 13, `TAB` -> 9, `escape` -> 27) is what
   `read_key_sequence` applies before anything is looked up - here
   `dispatch-key`'s `function-key-translate`. **The search reads its own
   keys below `dispatch-key`**, so it had no translation at all: the RET
   branch (`(eqv? code 13)`) never matched on Gtk, and RET fell into the
   other-key branch, which puts the key back on
   `unread-command-events` and exits. A terminal was unaffected -
   ncurses gives 13 - which is why only Gtk showed this, and why the
   search looked like it exited normally. TAB was the same bug one key
   over: a Gtk `tab` symbol never became `#\tab` for
   `isearch-printing-char`.

2. **`*unread-command-events*` is only consumed by a *read*.** In Emacs
   every `read_char` starts by taking that list. This front end's
   outermost loop does not read at all, so the `return` the search put
   back was never taken up at top level. It stayed there, and **every
   later search's first read answered it**, exited and put it back again:
   an infinite pushback. `C-s` was dead for ever, `C-g` could not help
   (the stale key is read before anything typed), and other commands
   went on working because commands do not read - the stale key only
   bites whoever reads next, which is the search.

The two fixes:

- `isearch-read-key` applies `function-key-translate` to what it reads,
  as `read_key_sequence` does - the RET branch matches, RET is not
  pushed back, and TAB is searchable. Measured with the actual keysym
  encoding (Return `0xff0d`) through `pgtk-enqueue!`: five searches in a
  row, every one starting; before the fix, 1 worked and 2-5 did nothing.
- `pgtk-drain-queue!` dispatches `*unread-command-events*` first, before
  the display queue, so a key the command loop hands back - an isearch's
  other-meta/other-control exit, which re-executes the key - runs at once
  instead of waiting for the next prompt. Measured: `C-y` typed inside a
  search now runs `yank` ("Kill ring is empty") where before it sat
  unread.

`tty-editor-tests` has the regression test: a test display feeds the
symbol `return`, and the search must exit through the RET branch
("Mark saved where search started") with `*unread-command-events*`
empty. Without the translation the test sees `(() (return))` - the
other-key exit and the stale key - which is the bug exactly.

# The keystroke was two guile-gi crossings (2026-11-15)

Chris had said the editor was "dog slow" in Gtk. This pass measured where a
keystroke goes on a *live* window (a Broadway display and a real one agree),
with a 240 KB file of 20,000-character wrapped lines, by driving
`dispatch-input-event` and `redisplay-frames!` from the back door:

| key | before | after |
|---|---|---|
| `C-n` | **10.30 ms** | **3.19 ms** |
| `C-f` | **9.85 ms** | **2.84 ms** |
| self-insert `a` | **38.50 ms** | **5.12 ms** |

Every number is the mean of 50 keys, measured A/B on the same tree by
stashing this pass's changes and compiling both sides.

## What the time was

`flush-display!` - the last statement of every redisplay - cost **7.1 ms per
call**. It is two guile-gi crossings:

- `widget:queue-draw` (`gtk_widget_queue_draw`): **3.6 ms per call.**
  The C function, called through `dynamic-func` on the pointer the proxy
  already holds, costs **0.0003 ms** - four orders of magnitude. The pointer
  is the one `pgtk-widget-pointer` has been handing to `gtk_widget_destroy`
  and the popup functions all along, so `flush-display!` calls the C
  function now. Nothing about the call is a marshalling problem: it takes
  the widget and returns `void`.

- `pgtk-set-frame-menubar`: **3.0 ms per call**, of which 2.6 ms was the
  `menu_items` parse (`init-menu-items` / `parse-single-submenu` /
  `finish-menu-items` over three menus) - and it ran on *every* redisplay.
  GNU Emacs reaches `set_frame_menubar` only when the display's
  `update_mode_line` says so (`xdisp.c:21522`) and guards `update_menu_bar`
  with `windows_or_buffers_changed || update_mode_lines ||
  window_buffer_changed (w)` (`:14449`). This tree had collapsed the two
  flags into `windows-or-buffers-changed?` and never set it on a buffer or
  window switch, so the guard could not be ported without the flag.

## `update_mode_lines`, ported

`(schemacs editor dispnew)` now has Emacs's `update_mode_lines`
(`xdisp.c:775`) beside `windows_or_buffers_changed`, reader and setter, and
for the same layering reason. It is the *cheap* flag: a mode line, a frame
title and a menu bar can change because of it, where the strong one says no
glyph matrix may be trusted. `redisplay-frames!` clears both together,
which is `xdisp.c:18166`.

Set where Emacs sets one of the two:

- `set-window-buffer!` (`wset_update_mode_line`, `window.c:4387`) - this is
  what makes `C-x b` show the new buffer's menus;
- `select-window` - Emacs gets there by a stronger route,
  `redisplay_other_windows()` setting `windows_or_buffers_changed`; this
  tree needs only the cheap half, the mode lines being compared by content
  and face when they are drawn;
- `set-frame-parameter` for `menu-bar-lines` - Emacs's `x_set_menu_bar_lines`
  is a frame *parameter handler*, and without this `(menu-bar-mode 1)` after
  `(menu-bar-mode -1)` left the bar down (measured; "hidden" is also the
  state of a bar with no items);
- `force-mode-line-update`, whose docstring says it "also forces
  recomputation of the menu bar menus" (`buffer.c:1543`).

## `set-window-start!` was two functions

`Fset_window_start` (`window.c:1969`) is the marker pair **plus**
`wset_update_mode_line`. The redisplay's own scrolling writes `w->start`
directly and sets neither. This tree had one function used by both, and
folding the flag into it made every recentring `C-n` re-parse the menu bar.
It is now `set-window-start!` (the DEFUN: pair + flag) and
`%window-start-set!` (the pair), and `scroll-to-cursor!` /
`window-move-screen-lines` use the second - which is what the C's
`redisplay_window` does.

## The cursor's row from the glyph matrix

Moving point cost 1.3 ms more than not moving it, because
`cursor-screen-position` asked `rows-above` how many screen rows were above
the cursor, and that **lays out every line between the window start and the
cursor** (`line-display-texts` + `line-texts-rows` per line). GNU Emacs asks
the glyph matrix the same question: `try_cursor_movement` steps through
`w->current_matrix` comparing each row's `start` charpos
(`xdisp.c:19961`), and a row *carries* the position it was laid out from.

`rows-above-in-window` is that walk over this tree's rows (which have had
`start`/`end` since the glyph matrix landed). It answers `#f` when the
matrix is not what the screen holds, and `cursor-screen-position` falls back
to counting lines - so the change can only ever be a speed-up.

## Verified

All 50 suites pass, and `tools/pty-check.py` is **82/82** - a full green
battery, where the previous two runs were 80/82 and 61/62 with the
load-sensitive flakes this file has a section about. The checks that would
catch a redisplay regression (`scroll`, `hscroll`, `recenter`, `split`,
`wide-columns`, `isearch-scroll`, `redisplay`) all pass.

## What is still slow, and what it needs

A self-insert is 5.1 ms: the insert is 0.004 ms and the redisplay is the
rest, because **an edit invalidates the window and every row is rebuilt**.
GNU Emacs' `try_window_id` (`xdisp.c:22603`, ~790 lines) reuses the rows
above the change, shifts the ones below when a line count changed, and
rebuilds only what differs. That is the next step and it is a port of its
own: it needs `beg_unchanged`/`end_unchanged` bookkeeping kept up to date
(only `beg_unchanged` is carried), `row_containing_pos`, the matrix row
shift, and the `GIVE_UP` conditions that decide when it cannot be used. It
was not started here rather than half-done.

# A retheme left the blank rows their old colour (2026-11-15)

Chris: *"when I retheme schemacs via omarchy, blank lines don't get
rethemed, they stay the old color... until I redraw, anyway."*

## The departure

GNU Emacs's `realize_face` ends its "remove the former face" branch with

```c
      free_realized_face (cache->f, former_face);
      SET_FRAME_GARBAGED (cache->f);          /* xfaces.c:6252 */
```

- replacing a face's realization means **every pixel the old one put on
the screen is stale**. `set-face-attribute` sets
`windows_or_buffers_changed` too (`xfaces.c:801`), and that is all this
tree did.

**Why only the blank rows showed it.** On a window-system frame a blank row
carries *no glyphs*: `build-blank-row!` fills them on a terminal only, and
the GUI row's remainder is painted by `clear-end-of-line-row!` at draw
time. So an unchanged blank row compares equal in the window's row diff and
is skipped, and its old background pixels stay on the surface. A text row
*is* redrawn (its glyphs' face tokens change), and its tail is repainted
with the new default - so text lines retheme and blank lines do not.

Measured offscreen on a Gtk display, one line of text in a 24x80 frame:

| | text row, past the text | blank row 10 |
|---|---|---|
| before the fix, after `default`'s background := black | `(0 0 0)` | **`(255 255 255)`** |
| after the fix | `(0 0 0)` | `(0 0 0)` |

and through the real `load-theme` path (which is what omarchy drives):
`wombat` gives `(36 36 36)` on both, `tsdh-light` puts both back to
`(255 255 255)`.

## The fix

`faces.scm` gained `*frame-garbage-function*` and `set-face-attribute`
calls it after the attribute write. The seam exists because `faces.scm` is
below the library that owns `<frame>`, the same arrangement
`*frame-background-mode-function*` already has; `frame.scm` installs it and
garbages every frame (or the one named), which is `SET_FRAME_GARBAGED` with
`FRAME = nil`.

**Placement departure**: Emacs garbages at *realization* time, when the face
cache replaces a realized face. This tree has no per-face realized cache -
a display token is interned from the attributes on demand (`realize-face`
in the Gtk backend) - so the event "the former realization is replaced" is
the attribute write itself. Same moment from the user's side, one hop
earlier in the code.

## Test

`pgtk-tests`' *"a face change repaints the blank rows as well"* renders a
one-line buffer, reads a pixel in a blank row, sets `default`'s background
to black, renders again and reads it again. Seen failing without the fix
(`actual-value: (255 255 255)`) and passing with it.

# C-g during a burst of keys quit the editor (2026-11-15)

Chris: *"in tty editor, in dired, if I hold arrow down a while then quickly
hit C-g, the editor dies."*

## What was happening

The terminal turns C-g into SIGINT (`init_sys_modes` makes it VINTR), and
the kernel raises it **when the byte arrives** - so holding an arrow down
and then pressing C-g leaves `quit-flag` set while the queued keys are
still being read. The quit is then raised by the read's own
`maybe-quit` (`read_key_sequence`'s opening call, `keyboard.c:11917`),
which is *inside* the command loop's error guard and outside the
per-command one.

GNU Emacs's `command_loop_2` (`keyboard.c:1159`) is

```c
  do
    val = internal_condition_case (command_loop_1, handlers, cmd_error);
  while (!NILP (val));
```

- the loop is **outside** the guard, so `cmd_error` reports the quit and
  the loop reads again.

This tree had the loop as the *last form of the guarded body*:

```scheme
(guard (ex (else (report-command-error! frame ex)))
  (let ((ev (read-key-event want))) ...)
  (loop))
```

so when the handler ran, its own value - the `"Quit"` message - **became
the value of the iteration**, the `let loop` returned it, `command-loop`
returned, and `event-loop`'s `call/cc` returned: the editor exited, with
status 0 and nothing printed but its terminal teardown. Measured: 500 ×
Down on an 800-file Dired directory, then C-g - process gone.

The same shape is why *any* error raised by the read (not just a quit)
ended the editor instead of being reported.

## The fix

`(loop)` is now the loop body's last form, a sibling of the guard and not
a member of its body - `command_loop_2`'s `do ... while`. An exception
leaves the guard (reporting), the value is discarded, and the loop reads
again; end of input still leaves the editor through `frame-quit-cont`.

## Verified

- `tty-editor-tests.scm` gained a deterministic case: a `<quitting-display>`
  whose `read-input-event` raises `<quit-condition>` on the first read and
  answers the script after it. The key scripted *after* the quit must run.
  **Failing without the fix with `actual-value: abc`** (the loop returned
  before the key) and passing with it.
- `tools/pty-check.py` gained `quit-during-burst`: 500 Down keys written as
  a burst with the C-g behind them, then M-x - the prompt is the proof the
  editor is still there. Seen failing without the fix ("the editor did not
  answer M-x - it is gone") and passing with it.

Both tests needed one subtlety to reproduce: **the C-g has to arrive while
the keys are still queued.** A single write of burst+C-g raises SIGINT
before the editor has read anything (the read then answers `quit_char`
immediately, which is the harmless path), and a settled burst drains the
queue first. The pty check writes the burst in two `nowait` chunks with a
`("sleep", 0.08)` between them, which is what holding the key down does.

# The echo row was redrawn on every redisplay (2026-11-15)

Chris: *"dired is dog slow in tty as well as gtk."* Measuring a bare
`redisplay-frames!` (nothing changed at all) on an offscreen Gtk frame over
an 810-line Dired buffer: **2.1-2.3 ms and ~238 KB of allocation**.

The departure: **GNU Emacs's echo area is a window** - `echo_area_window`
is `FRAME_MINIBUF_WINDOW` and its row is drawn into that window's glyph
matrix and diffed by `update_window` - so an unchanged message costs it
nothing. This tree draws the echo row directly, outside the matrices, and
drew it on **every** redisplay: the message string, a run write, and the
rest of the row filled with 80 space cells (one `<glyph>` per cell), even
when neither the message nor the prompt had changed.

`render!` compared a record of what the row would be drawn with - the
mode, the prompt, the echo buffer's modified tick, the message, the height
and the width - and drew only when it differed or the frame had been
garbaged. **That was a stopgap and it is gone**: the echo area is a real
window now and its row goes through the glyph matrix like any other. See
"the echo area is a window" below.

Measured, same bench: **1.40 ms and 205 KB** per no-change redisplay
(1.17 ms with the mode line also stubbed out). The echo row was 0.5-0.7 ms
and 30-50 KB of it.

## What is still in that 1.4 ms / 205 KB

Attributed so far: the echo row (now skipped), the mode line (measured at
~200 bytes a build - it is *built* every redisplay and compared, which is
its own small departure), the cursor (`cursor-screen-position`, 11 KB) and
the glyph-matrix diff (empty - checked: `matrix-diff-rows` answers `()`
after a redisplay). The window itself is skipped (`window-matrix-valid?`
is `#t`). The rest is `render!`'s fixed path and is not yet attributed;
the next step there is the one this file has named for two years,
incremental redraw: the frame's row list, the window walk and the echo
area are all rebuilt into lists every time.

## Dired's own numbers, for the record

Terminal, 800-file directory, `dispatch-input-event` C-n + redisplay from
the back door: **0.25-0.9 ms per key** in sustained scrolling (200 keys at
0.25 ms each), and the same order in a normal text buffer. The 6 ms figure
an earlier run of the same harness printed was a GC-heavy sample: at
~150-200 KB of allocation per redisplay the GC lands inside some of the
50-key batches, which is exactly what "slow in bursts" feels like.

# The echo area is a window (2026-11-15)

Chris: *"did I hear you say we draw to the echo area directly whereas
emacs uses a window?"*, then *"Fix it properly, like emacs"*. He did, and
it was the root of more than the row's cost.

## The departure

GNU Emacs's echo area is **a window showing a buffer**:

- `FRAME_MINIBUF_WINDOW (f)` is a real window - the frame's last row - and
  it is drawn by `redisplay_window` into its glyph matrix and diffed by
  `update_window`, like any other.
- When no prompt is being read it shows the frame's **echo buffer**,
  `" *Echo Area 0*"` (`ensure_echo_area_buffers`, `xdisp.c:12919`), which
  `set_message_1` (`:13624`) writes the message into: `TEMP_SET_PT_BOTH
  (BEG, BEG_BYTE)` and insert.
- When a prompt is being read the same window shows the minibuffer buffer
  instead (`read_minibuf`'s `set_window_buffer (minibuf_window,
  Fcurrent_buffer ())`, `minibuf.c:840`), and `minibuffer_unwind`
  (`:1231`) puts the previous buffer back on the way out.
- **The prompt is text in that buffer**, inserted with the `field`,
  `front-sticky`, `rear-nonsticky`, `read-only` and `face
  minibuffer-prompt` properties (`minibuf.c:858`), and
  `minibuffer-prompt-end` (`:505`) finds its end by scanning for the
  `field` property.

This tree painted the echo row by hand, outside the matrices, from two
parameters (`*echo-area-buffer*`, `*echo-area-prompt*`). Everything that
followed from that was a departure:

1. the row was redrawn on every redisplay (0.5-0.7 ms and 30-50 KB of a
   no-change redisplay, until a record comparison papered over it);
2. the prompt was not in the buffer, so `minibuffer-prompt-end` was
   `(point-min)` and `minibuffer-cursor-column` had to add the prompt's
   *string length* to the buffer's column - two spellings of one fact;
3. a message during a prompt had nowhere to go but over the prompt.
   Emacs shows it as an **overlay `after-string` at the end of the
   minibuffer buffer** (`minibuffer-message`, `minibuffer.el:812`), which
   is why `[No match]` appears after what you typed rather than replacing
   it - and why a `message` during a prompt is routed to the same place by
   `set-message-function` (`set-minibuffer-message`, `:899`).

## What was done

- **The prompt goes into the minibuffer buffer** in `read-minibuffer-1`,
  with the C's properties and point arithmetic.
  `minibuffer-prompt-end` scans for `field`; `minibuffer-contents`,
  `-no-properties`, `minibuffer-set-contents!` and `completion--replace`
  start at it; `minibuffer-cursor-column` is `current-line-display-column`
  and adds nothing.
- **`<frame>` has an `echo-buffer`**, made with the frame, and the
  minibuffer window shows it. `set!frame-message` writes the message into
  it (`set_message_1`) and keeps the `message` slot, which is
  `FRAME_MESSAGE_BUF` - Emacs has both, the buffer that is drawn and the
  string `current-message` answers.
- **`render!` draws the minibuffer window in the ordinary window loop.**
  The hand-drawn echo block, its record table (`*frame-last-echo-row*`)
  and the special case in the cursor placement are all deleted; the
  cursor is the selected window's, and while a prompt is read that window
  *is* the selected one.
- **`minibuffer-message` is Emacs's**, overlay and all, and
  `set-minibuffer-message` / `clear-minibuffer-message` are installed as
  `set-message-function` / `clear-message-function`. A `message` during a
  prompt no longer hides what is being typed.
- **`read-quoted-char`'s prompt and digit echo are messages** - they were
  painted through `*echo-area-prompt*` - and `read-char-from-minibuffer`'s
  is a message with `cursor-in-echo-area`, which is what `read-key` does.
- **`*echo-area-prompt*` is deleted.** `*echo-area-buffer*` stays as the
  tree's stand-in for `(minibuffer-depth) > 0` - the question libraries
  below the minibuffer can still ask.

`*cursor-in-echo-area*` moved from `window.scm` to `dispnew.scm`, where
Emacs declares it (`DEFVAR_BOOL`, `dispnew.c:7538`), and `window.scm`
re-exports it.

## Departures that remain, and whether to fix them

1. ~~**One echo buffer per frame**, where Emacs has two global ones.~~
   **Fixed**: the two ` *Echo Area 0*`/` *Echo Area 1*` buffers are
   global and alternate, as the C's do (`with_echo_area_buffer`, WHICH =
   -1), and the renderer swaps the current one into the *selected*
   frame's minibuffer window for the display - `with_echo_area_buffer`'s
   `wset_buffer` - so a frame that is not selected shows its own
   ` *Minibuf-0*`, which is what Emacs's `redisplay_window` does with
   every mini window that is not `echo_area_window`.
2. ~~**The minibuffer window does not grow.**~~ **Fixed**:
   `resize_mini_window` (`xdisp.c:13310`), `grow_mini_window` /
   `shrink_mini_window` (`window.c:5901`, `:5943`), `resize-mini-windows`
   (`grow-only`) and `max-mini-window-height` (0.25) are ported. The text
   is measured in *rows* rather than pixels, so the resize quantises to
   the frame's grid - which is what a tty frame does anyway.
3. **`clear-message-function` is reached from `set!frame-message` with an
   empty string**, which this tree uses for `(message nil)`. Emacs has a
   separate `clear_message`. The observable is the same.
4. **`cursor-in-echo-area` is read by the cursor placement only.** Emacs
   also uses it in `update_frame` and in `read_char`'s echo handling.
5. `minibuffer-message`'s `(put-text-property 0 1 'cursor t message)` -
   the property that tells the C cursor code where to put the cursor
   relative to an overlay string - has no counterpart, because a Scheme
   string cannot carry properties and the overlay is drawn by the row
   builder, which has no cursor decision to make.
6. `minibuffer-message-properties` is carried as a variable but nothing
   applies it: it would need string properties (`propertize`).

## The unwind runs twice, which is why it captures instead of pops

Found the hard way: the echo row showed the *prompt* after every read.
`%minibuffer-unwind` was a port of `minibuffer_unwind`'s pop of
`w->prev_buffers`, and the `dynamic-wind` after thunk in
`read-minibuffer-1` **runs twice per prompt**. Traced:

    BEFORE 1
    UNWIND 1 prev=() cur=Untitled          <- the body escaped
    BEFORE 2
    BODY-DONE 2 => "ab"
    UNWIND 2 prev=(Untitled) cur= *Echo Area 0*

The C's `record_unwind_protect` runs once, so a pop is safe there; a pop
here restores the *dead prompt* the first run recorded. The restore now
captures the window's `(BUFFER START POINT)` before the read and sets it
again, which is the same restore and is idempotent.

**The double run is a departure in its own right** and is not fixed: it
comes from `command-loop`'s `call/cc` exit (a full continuation, where
Emacs's `throw`/`Fthrow` is an escape), and it means
`minibuffer-exit-hook` also runs twice per prompt. Everything currently
on that hook is idempotent, so nothing shows - but a hook with a side
effect would fire twice. Worth fixing in the loop, not here.

## The prompt is a field, and field motion had to be ported with it

Putting the prompt in the buffer made `C-a` break, and the break is the
kind that only shows in a command: `beginning-of-line` computes the line's
start - position 1, the start of the *prompt* - and `C-k` from there kills
the prompt text. Emacs's answer is a **field**: `read_minibuf` puts
`field t` on the prompt (`minibuf.c:858`), and

```c
DEFUN ("line-beginning-position", ...)
  ptrdiff_t count, charpos = bol (n, &count);
  return Fconstrain_to_field (make_fixnum (charpos), make_fixnum (PT),
			      count != 0 ? Qt : Qnil, Qt, Qnil);
```

so `C-a` is pulled back to the field boundary. This tree had `bol` and no
constraint, and its own docstring said so ("The field constraint is not
carried: there are no fields here"). There are now.

Ported, bottom up:

| Emacs | here |
|---|---|
| `text_property_stickiness` (`textprop.c`) | `text-property-stickiness` |
| `next-property-change` / `previous-` (any property) | the same |
| `next-char-property-change` / `previous-` (property or overlay) | the same |
| `next-single-char-property-change` / `previous-` | the same |
| `get-pos-property` (`editfns.c:275`) | the same |
| `find_field` (`:374`) | `find-field` |
| `field-beginning` / `field-end` | the same |
| `constrain-to-field` (`:551`) | the same |
| `inhibit-field-text-motion` | `*inhibit-field-text-motion*` |
| `text-property-default-nonsticky` | `*text-property-default-nonsticky*` |
| `OVERLAY_FRONT_ADVANCE_P` / `OVERLAY_REAR_ADVANCE_P` | `overlay-front-advance` / `-rear-advance` |

**The subtlety is `count != 0`, not `n` non-zero.** `bol`'s COUNT is
`n - 1` for a number and 0 for a nil N (`editfns.c:665`), so
`(beginning-of-line 1)` - the ordinary key - passes ESCAPE-FROM-EDGE nil
and `(beginning-of-line 0)` passes t. Using "N is non-zero" made `C-a`
answer 1 again, which looks like the constraint not working at all.
Measured on Emacs 31.1 with a `Find file: ` field at 1..11 and "abc" at
12..14:

    (line-beginning-position)    -> 12    (ours: 12)
    (line-beginning-position 1)  -> 12    (ours: 12)
    (line-beginning-position 2)  -> 15    (ours: 15)
    (line-beginning-position 0)  ->  1    (ours:  1)
    (line-end-position)          -> 15    (ours: 15)
    (line-end-position 0)        -> 12    (ours: 12)

Tests: `editfns-tests.scm` gained a `schemacs_editor_editfns_fields` group
(4), and `tty-editor-tests.scm` a group that presses `C-a`, `C-A C-k` and
`C-e C-b` in a prompt whose buffer really holds the prompt (3).

## Verified

All 50 suites pass (`tty-editor-tests` 309, `pgtk-tests` 110,
`editfns-tests` 46), and `tools/pty-check.py` is **83/83** - the whole
battery, which had never been fully green before this pass (the best had
been 82/82, and several checks had been failing since the prompt moved
into the buffer).

## Also fixed on the way

`other-buffer` did not skip hidden buffers. Emacs's `candidate_buffer`
(`buffer.c:1748`) tests `BUFFER_HIDDEN_P` - "its name starts with a
space" (`buffer.h:1152`) - and this tree's did not, which nothing noticed
until a frame started making ` *Echo Area 0*`: killing the last visible
buffer then put an internal buffer on screen. `(%buffer-hidden?)` is the
C's macro and `other-buffer` asks it now.

## Overlay strings had never been drawn

`build-row!` carried a note saying that overlay `before-string` and
`after-string` belong there as *glyphs* - which is what GNU Emacs makes
of them (`get_overlay_strings`, `xdisp.c:6920`) - but that they were
absent "because nothing in this tree can make one yet". `minibuffer-message`
makes one now, and the note's premise was the only thing holding it back.

`overlay-strings-at` (a faithful `load_overlay_strings`) and
`row-overlay-strings` were already ported; `line-slice-glyphs-with-strings`
is the missing third piece. A row with no strings still goes through the
pool-reusing walk, so the keystroke path is unchanged.

The strings' characters advance the screen column as they are appended,
so a tab after one expands from where the string left off, as it does in
the C.

# `called-interactively-p` asked the wrong question (2026-11-15)

Chris, opening a directory: *"I get a minibuffer message 'font lock mode
enabled'. That's odd you don't get that in emacs."*

`dired-mode` ends with `(when (font-lock-defaults) (font-lock-mode #t))`
(`dired.scm:1387`), and `font-lock-mode` is a `define-minor-mode` whose
generated command echoes "Font-Lock mode enabled" when
`(called-interactively-p 'any)` says it was reached from a key. In GNU
Emacs that call is **not** interactive and stays quiet. Here it was
interactive, because `called-interactively-p` was
`(*called-interactively*)` - one dynamic flag bound around the whole
command - so everything a command calls, however deep, counted.

Emacs asks the *stack*: `(backtrace-frame i ...)` walks outward and
answers t only if the frame that called **the function the question is
asked in** is `funcall-interactively` (`subr.el:6944`). A Scheme binding
cannot ask what function it is in, and this Guile has no
`frame-procedure` (`(system vm frames)` does not exist in 3.0.11, and
`frame-procedure-name` answers #f for the unnamed frame `apply` makes).
So the parameter holds **the command procedure being invoked**, and:

- `(called-interactively? CMD)` - the exact answer, true only while CMD
  is the command being run. `define-minor-mode` emits it with the mode's
  own command, and `menu-bar-mode` with its own;
- `(called-interactively?)` - "some command is running", the old
  approximation, kept for callers that cannot name themselves. Nothing a
  user sees depends on it.

`interactive-proc`'s branches now all call the command through a new
`funcall-interactively` (`callint.c`), which is the frame the C looks
for, so the shape is the C's even though the test is not.

## ...and `font-lock-mode` was a hand-written mode

The message came from `font-core.scm`, which had `font-lock-mode` as a
hand-written `define-command` ending in

    (set!frame-message (*current-frame*)
                       (if on? "Font-Lock mode enabled" "Font-Lock mode disabled"))

- it echoed on **every** call, so the `called-interactively-p` fix alone
would not have silenced it. In Emacs it is a `define-minor-mode`
(`font-core.el:83`), and it is one here now: the same `:after-hook
(font-lock-initial-fontify)`, the `" FL"` lighter, and the generated
message. Not carried, both for want of primitives: `noninteractive` (the
`(or noninteractive ...)` half of the name test) and the
`change-major-mode-hook` add/remove, which needs `add-hook`/`remove-hook`.

## A compiled library folds its own `defvar`s

Found while checking the menu-bar suites: three `menu-bar-tests` failed on
a tree whose sources had not changed, and passed when `keyboard.scm`
happened to be interpreted. Measured - `module-set!` on
`*enable-disabled-menus-and-buttons*` reads back #t, and a compiled
`parse-menu-item` still takes the #f branch.

Guile's compiler treats a top-level binding that its module never assigns
as a **constant** and folds the reads, so a `setq` from another module -
a user's init file, or a test - is invisible in a compiled build. Every
variable this tree keeps as a plain `define` *because Emacs's is a
`defvar` somebody `setq`s* is in that class.

Fixed for the three variables the menu code exposes, by one assignment in
the defining library (`(set! x x)`), which marks the binding mutable.
**The rest of the tree has not been swept**, and that is worth doing: the
symptom is a setting that works in a fresh checkout and does nothing
after `guile -c "(compile-file ...)"`.

# The syntax engine and the syntactic pass (2026-11-15)

Where `(schemacs editor syntax)` and font-lock's syntactic half depart
from `syntax.c`/`syntax.el`/`font-lock.el`, and whether each should be
fixed.

1. **`char-syntax` answers a character, not the integer Emacs prints**
   (119 for `a`). This is this tree's spelling of a character, and
   `matching-paren` answers an integer like the C's. Consistent with
   `char-after`'s answer everywhere else. *No fix needed; a caller
   comparing with `char=?` is the tree's spelling of `eq ?w`.*
2. **Byte positions are gone.** The scanner has no `from_byte`
   parameters. *By design - the store has no bytes.*
3. **The `syntax-table` property is read with `get-text-property`, with a
   one-interval cache**, not `gl_state`'s interval walk. Same answers;
   `%prop-at` rebuilds the cache at each `SETUP_SYNTAX_TABLE`, as the C
   invalidates its own. *Keep.*
4. **`word_boundary_p` always false** - it compares
   `char-script-table`, which this tree has not got, so two characters
   of different scripts that Emacs splits into two words are one word
   here. *Fix when a Unicode script table exists; nothing here produces
   the case yet.*
5. **`back_comment`, `find_defun_start`, `forward-comment`,
   `scan-lists`, `scan-sexps` are not ported.** They are the half that
   `forward-sexp` and `comment-dwim` stand on; the syntactic pass does
   not call them. *Port with the sexp commands.*
6. **`syntax-propertize-rules` (the macro) is not carried**, and
   `syntax-propertize` calls the mode's function over the extended
   region without the `syntax-multiline` walk. *Port with the first mode
   that needs it (lisp-mode's `#;` and `#|` will).*
7. **The delimiter-face branch is skipped**: `font-lock-comment-start-skip`
   and `-end-skip` are false and `comment-start-skip` is not ported
   (newcomment.el), so a comment gets one face from its first character
   and `font-lock-comment-delimiter-face` is unused. *Port with
   newcomment.el.*
8. **`syntax-ppss`'s near-position heuristic uses a fixed 2000-character
   span** where the C reads its statistics ratio; the stats vector is
   kept but not consulted. Performance only, and the cache is the same.
   *Keep unless a profile says otherwise.*
9. **`font-lock-syntactic-keywords`** (the pre-syntax-propertize
   mechanism) is still not carried; the syntactic pass runs
   `syntax-propertize` and `syntax-table` properties only.
10. **`font-lock-defaults`' SYNTAX-ALIST** (fourth element) is not read.
    No mode in this tree sets it; *port with the first that does.*

# The modes, and the regexp engine's syntax classes (2026-11-15)

The pass that made the syntax engine do something: `prog-mode`,
`emacs-lisp-mode`, `lisp-mode` and `scheme-mode`, `auto-mode-alist` with
`set-auto-mode`, and `global-font-lock-mode`. It found four things in the
layers below the modes, and three of them were departures that had to be
fixed before a single keyword could be matched.

## 1. `\w`, `\W`, `\sC` and `\SC` were glibc's, not the syntax table's

GNU Emacs's `\w` is `SYNTAX (c) == Sword` - `regex-emacs.c` asks the table
for every character. glibc's `\w` is the locale's `[[:alnum:]_]`, and the
difference is not academic: the standard syntax table gives `_` *symbol*
syntax, so Emacs's `\w` does **not** match `_` and glibc's does. Every
Lisp keyword regexp is built from `\(\w\|\s_\|\\\\.\)`, so the port could
not match a symbol at all.

`\sC` and `\SC` were *rejected* outright ("this engine does not implement
it"), which is why no Lisp mode could use its own keyword table.

Now `%syntax-class-ere` (`search.sld`) enumerates the current syntax
table's ASCII characters and spells the class as a glibc bracket
expression, cached per `(table . class)`:

* **ASCII only.** A class a table gives to a character above 127 cannot be
  spelled: glibc reads a bracket range in the *locale's collation*, and
  `[À-ÿ]` is "Invalid range end" here. The classes the Lisp modes use have
  no such member - every character above 127 has word syntax in their
  tables, and glibc's own `\w` matches the letters among them. *Fix with a
  regexp substrate that takes characters, not locales.*
* **NUL is dropped from a class**, because the pattern goes to `regcomp`
  as a C string - the same wall `%without-nul` meets.
* **One member per character, never a range**: a range is the locale's
  collation again, and `[<-_]` is "Invalid range end" in en_US.UTF-8.
* `]` is written first and `-` last, where POSIX makes them literal;
  `\-` is *not* an escape glibc honours (`[a\-c]` is the range `\`..`c`,
  measured).

## 2. `\_<` and `\_>` are approximated by `\<` and `\>`

glibc has no zero-width test of the syntax table's symbol class, and ERE
has no lookahead to build one from. The **word** boundary stands in, and
the two agree wherever the symbol's own edge is a word constituent -
every `def...\_>` and `define\_>` the Lisp tables test. They differ for a
symbol ending in symbol-syntax punctuation (`foo?\_>`). *Fix only with a
different regexp engine.*

## 3. Match-data groups are renumbered through a mapping

Emacs's `\(?:...\)` takes no match-data slot and `\(?N:...\)` chooses its
number; glibc has neither, so the translator emits a capturing group for
both. Every keyword entry that names a subexpression would then point at
the wrong group. `%translate-emacs-regexp` now answers the ERE **and a
mapping** from Emacs group number to glibc group, and
`%string-match-into-regs` renumbers through it. Verified against Emacs:
`a\(?:b\|c\)d\(e\)` gives group 1 = "e", `\(a\)\(?:b\)\(c\)` gives 1="a"
and 2="c", and `\(?1:\(?:x\)ab\|cd\)` gives 1="cd" - all three Emacs's own
answers. This *removes* a departure the library's header used to name.

## 4. `make-syntax-table` was missing, and `define-derived-mode` never
## installed a syntax table

`make-syntax-table` is `subr.el`'s in Emacs 31 (five lines: a syntax
char-table whose parent is the argument or the standard table), and this
tree had no such function - modes made tables with `copy-syntax-table`.
Ported to `subr.sld`.

`define-derived-mode` in Emacs also installs `CHILD-syntax-table`, before
the mode's body. Ours did not, which is why `emacs-lisp-mode` came up with
the *standard* table (`[` as a paren is Emacs's answer there too, by luck,
but `#` was punctuation instead of a quote). The macro now takes the
table as a sixth element, because it cannot invent the name - see the
library comment.

## The modes themselves: what is not carried

Each library's header names these; the list here is for the next session:

* **`prog-mode`**: keymap empty (`C-M-q`/`M-q` need `forward-sexp`,
  `beginning-of-defun` and `fill-paragraph`), no context menu, no
  prettify-symbols, `text-conversion-style`/`bidi-paragraph-direction` not
  stored (nothing reads them).
* **`lisp-mode`/`elisp-mode`**: keyword regexps are **transcribed** from a
  running Emacs 31.1 rather than rebuilt with `rx` (rx is a macro DSL this
  tree has not got); the four level-2 *function* matchers are absent; no
  `syntax-propertize` (needs `syntax-propertize-rules`); no
  `lisp-font-lock-syntactic-face-function` (needs `forward-sexp`), so a
  docstring gets `font-lock-string-face` where Emacs names
  `font-lock-doc-face` - the same colour, since doc-face inherits
  string-face; no indentation or filling.
* **`scheme.el`**: same list, plus `scheme-indent-function` and the imenu
  variables.
* **`font-lock-set-defaults`** now sets its four variables *buffer-locally*
  (they are `defvar-local` in Emacs), honours **SYNTAX-ALIST** (the
  fourth element; scheme's `+-*/.<>=!?$%_&~^:` become word syntax for
  fontification) and the **variable alist** after it, and is guarded by
  "already set up for this mode", which is what keeps a
  `font-lock-add-keywords` made before the mode came on. That guard is
  Emacs's; the *test* in this tree had been written without it and now
  resets the flag, as a fresh buffer would.
* **`font-lock-register-keyword-variable!`** is this tree's one new seam:
  Emacs's defaults name their keyword levels with *symbols* and
  `symbol-value` resolves them; a symbol has no value here, so the mode
  library registers its keyword lists in a table `font-lock-eval-keywords`
  reads. The `font-lock-defaults` list keeps Emacs's exact shape.
* **`global-font-lock-mode`** is a plain command, not a
  `define-globalized-minor-mode` (that macro is not ported); its body is
  the macro's expansion for this mode, and `font-lock-mode-hook` carries
  the `--set-explicitly` marker as the macro's expansion does.

## `auto-mode-alist` and `set-auto-mode`

* The four alists (`auto-mode-alist`, `magic-mode-alist`,
  `magic-fallback-mode-alist`, `interpreter-mode-alist`) are **Emacs
  31.1's runtime values**, emitted from a running Emacs - the method the
  charset registry and xterm's decode map were transcribed by. Entries
  naming modes this tree has not ported are kept, and `set-auto-mode-0`
  says "Ignoring unknown mode" for them, which is Emacs's own message for
  a binding that is not a function.
* **Dropped from the data**: the entries whose value is a file-name
  *handler* list (`(nil jka-compr)` and its kin - there are no handlers
  here), and `magic-fallback-mode-alist`'s `doc-view` entry, whose PDF
  signature is raw bytes no Scheme source file can hold.
* **Not carried from `set-auto-mode`**: the `.dir-locals.el` entry (no
  directory-local variables), the `Local Variables:` block (needs a Lisp
  value reader; a `-*- mode: ... -*-` tag *is* carried), and the
  `narrow-to-region` around the magic alists' scan (there is no
  narrowing; `looking-at` would read past the limit).
* **`set-buffer-major-mode`** is placed in `files.sld` rather than
  `buffer.sld`, because it calls a mode *command* by name and the command
  table is above the buffer library. Same placement note as
  `locate-file-internal`.
* **`normal-mode`'s `hack-local-variables` step** is named and absent -
  the same value-reader wall.

## The two bugs the work found, both the tree's oldest kind

1. **`(when TEST BODY)` as an expression answers the *unspecified* value,
   which is true in Scheme.** `set-auto-mode--from-matching-alist-entry`
   computes `mode-t` with a `when`; on the first plain `(REGEXP . MODE)`
   entry the test failed, `mode-t` was unspecified, and
   `(if mode-t (loop) ...)` looped for ever. The C's `when` answers nil.
   Rewritten as `and`.
2. **`(cdr #f)` is an error** where Elisp's `(cdr nil)` is nil.
   `major-mode-remap`'s `(or (cdr (or (assq ...) (assq ...))) mode)` had to
   test the cell first.

And one in the passing-under-its-own-test class: the port's
`font-lock-add-keywords` had no `font-lock-set-defaults` call, so a
keyword list added before `font-lock-mode` was thrown away by the mode's
own setup. Emacs's does the call first and marks the setup done - the
tests that had been written around the departure now exercise the C's
order.

## Two bugs found the moment it was used (2026-11-15)

### 1. `C-x 1` deleted the minibuffer window (Chris's report)

"if I start schemacs ... C-x 1, then C-x C-f ... the 'Theme set to
osaka-jade' remains there and the cursor jumps to after that message,
and if I type into it the characters seem invisible."

`delete-other-windows` rebuilt the frame's window list as

```scheme
(set!frame-windows frame (list window))
```

**and this tree keeps the minibuffer window in that list** -
`new-frame-on` makes the frame's windows deliberately, the echo area
being an ordinary window showing an ordinary buffer since 2026-11-15.
GNU Emacs's frame has a root window holding the ordinary windows and a
*separate* `f->minibuffer_window` (`frame.h`), which `window-list`'s
MINIBUF argument is what includes; deleting the other windows leaves it
alone. So after a `C-x 1` this frame had no window to draw the echo area
or a prompt in: `render!` walks `(window-list frame #t)`, the row kept
whatever was last painted there (his theme message), and the cursor -
placed from that window's stale matrix - sat at the end of it. Typing
went into the minibuffer buffer, which nothing drew.

**The first fix was a hack** - `delete-other-windows` rebuilding the
list as `(list window mini)` - and Chris called it: it papered over the
representation instead of following the C. The frame record already has
Emacs's two fields (`windows` and `minibuffer-window`); the departure
was that `new-frame-on` put the minibuffer window in *both*. Now
`frame-windows` holds the body tree only and `window-list` composes the
minibuffer window in, by `window_list_1`'s MINIBUF rule
(`candidate_window_p`, `window.c:3024`); `delete-other-windows` is
Emacs's body with no special case. `tools/pty-check.py` has
`prompt-after-delete-other-windows`, which starts on a file with the
splash below it, does `C-x 1`, `C-x C-f`, types `abc`, and requires the
last row to show the prompt *and* the typed letters - seen failing on
the old code with the mode line on the last row.

### 2. `auto-mode-alist`, autoloads, and two messages too many

Emacs's `auto-mode-alist` is a list of names, and every one of them is
autoloadable: the mode file carries `;;;###autoload`, `loaddefs.el`
turns it into an `autoload` form, and `(functionp mode)` is true before
the mode is loaded. This tree has no autoloads - a library is reachable
only by importing it - so:

* **`%mode-autoloads`** (`files.sld`) names the six modes this tree has
  with the library their Emacs file became, and `%mode-function` loads
  one with `resolve-module` on first use, which is the moment Emacs's
  autoload fires. *This is a stand-in for `loaddefs.el`, not a port of
  it; an `autoload` cookie mechanism is the real fix when there are
  enough modes to matter.*
* **"Ignoring unknown mode" is Emacs's message and is said exactly
  where Emacs says it** - for a name with no function. With the autoload
  table in place it fires only for a mode this tree has not ported
  (`.c`, `.py`, ...), which is the truth about this tree rather than
  about Emacs. It was briefly suppressed while the autoloads were
  missing; that hid a real gap (a `.txt` staying in fundamental-mode)
  behind silence, and it is back.
* **A magic-alist entry whose matcher is a symbol** (`(image-type-auto-
  detected-p . image-mode)` is in Emacs 31's default fallback list)
  resolves through the same name-to-procedure path; an unported matcher
  matches nothing instead of erroring. This crashed `find-file` on every
  `.bin` file.

### 3. `text-mode` landed, so `.txt` is a text buffer

`text-mode.sld` (`lisp/textmodes/text-mode.el`): the syntax table
(`'` is a word constituent, so `M-c` on `'hello'` gives `'Hello'`), the
mode, `text-mode-hook-identify` and `text-mode-variant`. Its one
behavioural point here is `(setq-local require-final-newline
mode-require-final-newline)` - a `.txt` buffer gets the final newline on
saving whatever the global says, which is Emacs's rule and is now tested
both ways (`tty-editor-tests`' final-newline group uses `.bin` files for
the global's values and a `.txt` file for the mode's).

## Small seams this pass added, named

* **`add-hook`/`remove-hook` take the hook's *parameter*, not a symbol.**
  Emacs names a hook with a symbol and reads its value; a symbol has no
  value here, and every hook in this tree is an SRFI-39 parameter
  (`run-hooks` already took the value). DEPTH is the C's rule; LOCAL is
  not carried, because a hook's buffer-local half needs a hook to be a
  buffer-local *variable* and a parameter cannot be. Nothing in the tree
  passes LOCAL.
* **`%mode-autoloads`** stands in for `loaddefs.el`'s autoload forms -
  six names, one library each.
* **`font-lock-register-keyword-variable!`** stands in for
  `symbol-value` when `font-lock-defaults` names its keyword levels with
  symbols.
* **`setq-local`** is a procedure taking `(NAME VALUE)`, not a macro -
  the buffer-local store is keyed by a plain symbol either way.

## The scanner and the sexp commands (2026-11-15)

* **`scan-error` is a record, not a condition type.** The C's
  `xsignal3 (Qscan_error, MSG, START, END)` carries three data fields and
  `condition-case` matches on the symbol; this tree's errors are Guile
  error objects, so `<scan-error>` is a record and `error-message-string`
  and the command loop's reporter both know it. `guard` + `scan-error?` is
  the port of `(condition-case _ ... (scan-error ...))`.
* **`user-error` is an alias for `error`.** Emacs gives it its own
  condition type (`subr.el`); nothing here catches the two apart, and the
  echo-area text is the same.
* **`skip_chars`' `fastmap`/`char_ranges` are not carried** — the
  membership test one character at a time is the same test, and the maps
  are an optimisation. The `[:class:]` vocabulary is `re_wctype_parse`'s,
  with Guile's character predicates standing in for the wide-character
  tables (`iswalpha` and its like).
* **No narrowing** in `beginning-of-defun-raw` (the C's
  `save-restriction`/`widen`) or in `up-list-default-function` (the
  `narrow-to-region` arm `no-syntax-crossing` uses).
* **`beginning-of-defun-raw`'s `wrong-number-of-arguments` fallback
  catches every error**, because this tree has one error condition type.
* **`beginning-of-defun`'s `this-command`/`last-command` test is against
  the command *procedures*** (`*this-command*`), not symbols: a command is
  its procedure here. `mark-defun-back` therefore cannot exist.
* **`transpose-sexps` lives in `lisp.scm`, not `simple.scm`** where Emacs
  has it: it needs `forward-sexp`, and `lisp.scm` is the library above
  `simple.scm` that holds it.
* **`eval-last-sexp` and `eval-defun` evaluate Scheme**, the departure
  `eval-expression` and `eval-region` already carry. `elisp--preceding-sexp`
  is `forward-sexp -1` plus `read`: the Emacs reader's quote stripping,
  `?\e`, `#s` and `#N=` have nothing to skip here. `elisp--eval-defun-1`,
  `eval-sexp-add-defvars` and `lexical-binding` exist to re-run a
  `defvar`/`defcustom`/`defface` initializer and Scheme has no such thing.
* **`eval-print-last-sexp` inserts its newlines with `insert`** where the
  C binds `standard-output` to the buffer and calls `terpri`: this tree has
  no `standard-output`, and the buffer is where they would have gone.
* **`eval-last-sexp`'s `last-sexp-setup-props`** (the text properties that
  make the echoed value clickable) is not carried.

## The syntax-table cache, and C-g inside a long command (2026-11-15)

Chris: *"I tried a big file, schemacs/editor/xdisp.scm and did a C-M-f to
go to the end... works, that's good. Then I did a C-M-b which should go
back to the beginning.. it gets stuck, at that point nothing can recover,
not even C-g"* - and then *"Even given a problem with the scanner, I'm
curious why C-g can't recover"*.

Two independent faults, and the second is why the first was
unrecoverable.

### 1. `gl_state` was not ported, and the cache beside it was forward-only

`syntax.h`'s `struct gl_state_s` (`:66`) is where `syntax.c` keeps the
`syntax-table` text-property lookup. `SYNTAX(c)` reads a property, the
property belongs to an *interval*, and `update_syntax_table`
(`syntax.c:336`) caches the interval and the run `b_property'..
`e_property` over which its table applies, walking one interval per
boundary crossed. A scan is therefore linear in the text.

What stood here was a one-run cache built on `next-single-property-change`,
and it is wrong in both directions:

* `next-single-property-change` walks intervals forward until the property
  *it was asked about* changes. On a buffer that font-lock has given
  `face` runs to and whose text carries no `syntax-table` property, that
  walk goes to the end of the buffer - once per lookup;
* a backward scan never hits a forward run cache at all: the cached run
  always began at the position just asked about, so the next character
  back was always a miss.

Measured: `C-M-b` from the end of `xdisp.scm` (257 KB, and the whole file
is one `define-library`, so one sexp) took **144 s** in the editor and
11.9 s on a 40 000-character synthetic buffer - the cost grows with the
square of the buffer. With `gl_state` ported the same key is **0.92 s**
headless and **1.17 s** in the live editor, and the synthetic case is
21 ms. What is left is the constant cost of a Scheme syntax lookup per
character, not a blow-up.

The departures inside the port:
* `gl_state` is a vector of the C's fields in the C's order rather than a
  struct, and its object slot is always the current buffer: Emacs's Qnil
  object means exactly that, and nothing scans a string through this.
* the `UPDATE_SYNTAX_TABLE_FORWARD`/`_BACKWARD` pair is applied inside
  `%syntax-entry-in` - the one place a character is read - rather than at
  every move in every loop. The state it maintains, the interval walk, the
  `old_prop` invalidation rule and the INTERVALS_AT_ONCE lookahead are
  the C's.
* `update_syntax_table_forward`'s `e_property_truncated` /
  `parse_sexp_propertize` bookkeeping is not carried: this tree's
  `syntax-propertize` is not called from the scanner.
* **`scan_words` gained the `SETUP_SYNTAX_TABLE` the C has at
  `syntax.c:1473`** and this tree never had. Four word-motion tests failed
  the moment the cache became long-lived, which is what an absent setup
  looks like once there is something to invalidate.

### 2. C-g was only ever looked at by the read

`maybe_quit` (`lisp.h:3897`) is the function every long loop calls;
Emacs's `syntax.c` calls `rarely_quit` (`lisp.h:3914`, once every 65 536
characters) from `scan_lists`, `back_comment`, `scan_sexps_forward`,
`forw_comment`, `scan_words` and both `skip_*` loops. Here `maybe-quit`
lived in `keyboard.scm` and **its only caller was the read** - so a C-g
pressed while a command was running set `quit-flag` and nothing ever
looked at it. A slow scan was therefore also an unrecoverable one, which
is the half of the report that was not about speed at all.

`maybe-quit` and `rarely-quit` are `command.scm`'s now (it already owns
`quit-flag`, `inhibit-quit` and `signal-quit`; `keyboard.scm` imports and
re-exports them, so every existing caller is unchanged), and the scans
call `rarely-quit` where the C does. Verified in a live editor: a C-g
during a 3 000 000-character scan draws "Quit" and the next key is
answered in 0.25 s.

### Tests

`syntax-tests.scm` grew four cases, each of which fails on the code that
shipped:
* a `syntax-table` text property is what the scan reads (Emacs 31.1's
  answers: 4 plain, 3 forward and 2 backward once `(` and `)` are made
  punctuation by the property);
* a backward scan over 40 000 characters carrying 4 000 `face` intervals
  lands where the forward one started **and takes under 2 s** - it took
  11.9 s before, and the bound is a hundred times the measured 21 ms;
* a scan of 70 000 characters with `quit-flag` set signals `quit` and
  clears the flag.

`tools/gen-imports.scm` was re-run: `rarely-quit` is reachable from the
back door and from `M-:` (`maybe-quit` is already, through `keyboard`).

## Opening a big file burned 23 s of CPU, and `regexp-exec` was why
## (2026-11-15)

Chris, while the above was being tested: *"do you realise just opening
xdisp.scm hangs the editor? and makes the CPU go into overload"*. It did:
23 s at ~140 % CPU before it settled, and the scanner was not the cause.
`font-lock-fontify-keywords-region` alone was 13.5 s of it.

The keyword pass is one search per match per keyword, and the search text
was a copy of the stretch from point to the *bound* - a bound that, for a
font-lock keyword, is the end of the file. O(buffer) per match.

**The first fix made it look better and was still wrong**, and the reason
is a Guile fact worth writing down: **`regexp-exec` costs time
proportional to the length of the string it is handed, not to how far it
scans.** Measured:

| string | one `regexp-exec` |
|---|---|
| 257 chars | 0.9 µs |
| 2 570 | 10 µs |
| 25 700 | 93 µs |
| 257 000 | 920 µs |
| 257 000, with the match at offset 0 | **6.4 ms** |

So handing the engine the whole buffer (cached by
`buffer-chars-modified-tick`, so that a fontification builds it once) is
5.7 s for 6 200 searches. There is no C equivalent of this cost to copy:
`re_search_2` is handed *pointers into the buffer* and copies nothing.

What is there now is a **window that doubles**: 512 characters to begin
with, doubled when the match is not found inside it, or when it ends
exactly at the window's edge (a `$` or a `\b` judged against a copied edge
is not the one the buffer has), or when the answer depends on a bound
beyond it. Measured on `xdisp.scm`:

| | before | whole-buffer string | windowed |
|---|---|---|---|
| keyword pass | 13 455 ms | 5 753 ms | **227 ms** |
| opening the file, live editor | 23 s at 140 % CPU | ~7 s | **under 1 s** |

Departures, both named in the source:
* the window is not the C's shape - the C scans the buffer directly and
  this cannot, because the engine wants a string;
* the edge rule is what makes a windowed answer the same as the whole
  text's. `\=` and `\'` - the two constructs that *could* tell a window
  from the buffer - are already refused by `%emacs-ere`, which is what
  makes the window sound rather than a guess.

`search-tests.scm` is 66/66 through all of this, and the font-lock,
replace, lisp and dired suites are unchanged.

## The windowed search, checked against Emacs on 500 random searches

The window above is a copy the C does not make, so it was checked rather
than reasoned about: **500 random buffers** (2 to 60 characters of
`a b c d ( ) space newline`), a random point, a random bound, one of 20
patterns including `^`, `$`, `\b`, `[abc]`, `a\{1,2\}`, `\(a\|b\)c?`, and
a random direction, run through this `re-search-forward`/
`re-search-backward` and through `emacs -Q --batch` on the same inputs.

| | mismatches of 500 |
|---|---|
| this tree, before the window work (`HEAD`) | **13** |
| the windowed search, before the two fixes below | 3 |
| the windowed search, now | **0** |

All 13 were one bug, and it was not the window's: **a `$` (or a `\b`)
judged against the edge of the copied text is not the buffer's.**
`(re-search-forward "$" 4 t)` on `"abcdef"` answered `4`; Emacs answers
nil, because position 4 is not a line end. `(re-search-backward "$" 2 t)`
from the middle of a line answered *point* for the same reason. The window
now runs one character past the bound in both directions, so `$` and `\b`
see the character the buffer really has, and a match is still refused when
it ends past the bound. Three of the six new `search-tests.scm` cases fail
on `HEAD`.

The other three mismatches were the opposite corner: the C's engine
matches *against* `stop`, so a pattern whose longest match would run past
point still matches shorter - `(re-search-backward "c*" 1 t)` at point 3
of `"abc"` is the empty match at 3, not the earlier one. Guile's
`regexp-exec` returns the longest match and takes no `stop`, so when the
match runs past point the backward search now **asks again with the text
ending at point**.

**The one departure that is left, named where it is:** the same retry is
*not* done for a forward search whose match runs past the bound. Doing it
needs the text truncated at the bound, and a truncated copy makes `$`
match an end of string the buffer has not got - measured, it fabricated
two `$` matches in the same 500-case corpus, so the forward path answers
nil there where Emacs would find a shorter match at the same start. None
of the 500 cases reaches it.

### `looking-at` was the same cost, and took the same fix

`looking-at` is `re_match_2` handed the whole accessible portion, and the
port copied the whole buffer on every call. Measured: **300 calls on a
257 KB buffer were 7.7 s** (26 ms each), which is what every dired line
and every `looking-at`-based scanner pays. It reads the same kind of
window now - one character before point, doubling until the match ends
inside it - and the same 300 calls are 19 ms. Checked the same way:
**500 random (text, point, pattern) cases against `emacs -Q --batch`,
0 mismatches.**

`search-tests.scm` pins the cost: a hundred `looking-at`s on a
200 000-character buffer must take under a second (they take 6 ms; they
took 2 s before), and the test fails on the old code.

# The Lisp indentation engine, and the primitives under it (2026-11-15)

The three commands that were waiting on `calculate-lisp-indent` -
`indent-sexp` (`lisp-mode.el:1449`), `indent-region` (`indent.el:559`)
and `move-past-close-and-reindent` (`lisp.el:969`) - are in, with the
engine they sit on: `lisp-ppss`, the `lisp-indent-state` record,
`lisp-indent-calc-next`, `lisp-indent-region`, `lisp-indent-line`,
`calculate-lisp-indent`, `lisp-indent-function`, `lisp-indent-specform`,
`lisp-indent-defform`, `lisp-comment-indent` and the `lisp-indent-function`
property table.

**The measure of it is a differential against Emacs's own
`indent-region`**: take an `.el` file, indent it with `emacs -Q --batch`
and with this tree, diff. Before the work below, `lisp.el` differed by
1 048 lines and `pp.el` by 396; the remaining differences are the
departures named at the end.

## Four departures in the engine itself, all found by that diff

1. **The final `cond` is not inside `(if retry ...)`.** Emacs's C is a
   *statement* followed by the `let`/`cond` that always runs; the port
   had the `let` as the else branch, so a line whose state had no
   containing sexp answered `#f` where Emacs answers `0`. Every
   top-level line was affected.
2. **`lisp-indent-function` (the variable) defaults to the procedure.**
   It is a `defcustom` whose initial value is `#'lisp-indent-function`
   (`lisp-mode.el:904`); the port read the buffer-local with a `#f`
   default, so the hook was never called and every form fell back to
   "align under the first element" - a `defun` body indented to 7 instead
   of 2.
3. **`(set! x v)` answers the OLD value in this Guile**, so the C's
   `(and (looking-at ":") (setq indent (current-column)))` cannot be an
   `and` over a `set!`: it answers `#f` on the first match and the
   alignment is lost. Written as an `if`.
4. **`(elt nil 3)` is nil in Elisp and an error for `list-ref`**, so
   every state read is `(and state (list-ref state N))`.

## The property table is data, transcribed

Emacs has no table of `lisp-indent-function` properties: `defmacro` reads
each macro's `(declare (indent N))` and `function-put`s it onto the
symbol (`byte-run.el`), and `lisp-indent-function` reads it back with
`(function-get SYMBOL 'lisp-indent-function 'macro)`. This tree has no
`defmacro`, so the properties of 303 symbols are written out in
`lisp-mode.scm`, transcribed from a running Emacs 31.1 **with that exact
call** - `function-get`'s `'macro` argument is what loads an autoloaded
macro's library, and it is why `pcase`, `cl-callf2`, `dolist` and
`with-temp-buffer` are in the list.

**The transcription has to ask one symbol at a time.** A first attempt
loaded every library under `lisp/` and took the properties afterwards:
that also gives `inline--letlisteval`, a macro defined *in* `inline.el`,
and a fresh Emacs indenting `inline.el` itself has no such property
(measured: the continuation line goes to 24; with the property, 27).
`emacs -Q` answers 160 properties; the autoload-walking dump answers 303;
the load-everything dump answered 386, of which some are wrong.

## `newcomment.scm` - and the three `when`s that answer true

`indent-for-comment` is `(defalias 'indent-for-comment 'comment-indent)`
(`newcomment.el:75`), so `lisp-indent-line`'s single-`;` branch needs the
comment engine. Ported as far as that needs: the variables,
`comment-normalize-vars`, `comment-search-forward`,
`comment-indent-default`, `comment-choose-indent`, `comment-indent`.

**Elisp's `when` answers nil when its test fails; Scheme's answers the
unspecified value, which is true.** Three sites read the answer as a
value - `comment-indent-default`'s return, `comment-search-forward`'s
NOERROR path, and the `and` inside `comment-choose-indent`'s forward
scan - and each turned "no" into "yes". The first surfaced as
`In procedure =: Wrong type argument in position 1: #<unspecified>`
three functions later. `comment-indent-function`'s default is
`comment-indent-default` (the C's `(defvar comment-indent-function
#'comment-indent-default)`), not `#f`.

## `fixup-whitespace` had lost its parenthesis classes

`simple.el:1123`'s `(or (looking-at "^\\|$\\|\\s)") (save-excursion
(forward-char -1) (looking-at "$\\|\\s(\\|\\s'")))` was ported as
bolp/eolp alone, with a note saying a syntax class was not expressible
in a regexp here. It is now (2026-11-15), and the difference shows the
moment `M-)` joins a line to a closing paren: `(a b )` where Emacs gives
`(a b)`.

**The escapes matter**: `"^\|$\|\s)"` (single backslashes) is a
different regexp from `"^\\|$\\|\\s)"`. Guile reads `\|` as a literal
`|`, and `%emacs-ere` then escapes that literal, so the alternation
disappears. Measured both ways.

## The scanner: `Sescape` has to consume the quoted character

`scan_sexps_forward`'s `case Sescape: ... goto startquoted` does
**`INC_FROM`** and then goes to `symstarted` - the quoted character is
consumed. The port went straight to `symstarted`, leaving the character
to the main loop, which read a `"` as a **string opener**. The symptom
was `pp.el`'s lines 216-238 answering `nil` ("inside a string") where
Emacs answers 22: line 218 holds `\"` - an escaped quote in a character
literal - and everything after it was scanned as string.

## `syntax-ppss-toplevel-pos` had drifted into a `cond`

The C is two lines: `(or (car (nth 9 ppss)) (nth 8 ppss))`. The port had
a `cond` over the depth that also asked `(> (nth 4 ppss) 0)` - and
element 4 is `t` for a non-nestable comment, so `>` raised
"Wrong type argument" the first time a scan asked it about a state
outside a comment.

## `syntax-propertize`: three things it was missing

1. **`save-excursion`.** The mode's function is free to move point and
   does (`(goto-char start)`); the port called it bare, so every reparse
   left point at 1. Found as "newline-and-indent ends at point 1".
2. **`syntax-propertize--done` is set BEFORE the function runs**
   (`syntax.el:452`), which is what makes the `syntax-ppss` call inside
   the rules terminate instead of recursing.
3. **`syntax-propertize-function` is buffer-local**
   (`setq-local` in every mode). It was a parameter here, so one mode's
   function applied to every buffer in the editor.

And `parse-partial-sexp` propertizes as it scans: the C's
`update_syntax_table_forward` calls `parse_sexp_propertize` whenever the
known run reaches past `syntax-propertize--done` (`syntax.c:516`). That
is ported, with `%syntax-propertize-done` cached because the C reads a
global on every character.

**Two details that only showed once a whole file was indented.** The
check has to run on **every character**, as `UPDATE_SYNTAX_TABLE_FORWARD`
does; checking it only when the interval run changes left the buffer
half propertized, because the last run reaches to `ZV` and no change is
ever seen again - `vtable.el` line 208 indented to 8 where Emacs says 6,
and `syntax-propertize--done` stuck 300 characters behind the scan. And
the truncation branch needs its `e_property_truncated` flag: when
`e_property` is cut back to `--done` the cached interval is a belief no
longer, and the next walk off it says "Error in syntax_table logic for
to-the-end intervals". Both fixed, and the whole-file indent is then
~350 ms per 170 KB (it was 5 s while half-propertized).

## `syntax-ppss`'s cache had lost its ordering, and `pt-min`

Found by running `calculate-lisp-indent` line by line over `subr-x.el`,
where it raised "End position is smaller than start position". Three
things, all in `syntax.el`'s cache:

1. **The cache list is kept in decreasing position order**, and the
   scan's `(while (and cache (< pos (caar cache))) ...)` depends on it.
   The port pushed every new entry at the front regardless; Emacs
   replaces or inserts by gap (`(if (> (- (caar cache-pred) pos)
   syntax-ppss-max-span) (push ...) (setcar ...))`) and writes the list
   back with `(setcdr cell ppss-cache)`.
2. **`(setq pt-min (or ...))` inside the `and`** - `set!` answers the old
   value here, so the `(<= pt-min pos)` test used the *previous* value.
3. **The `else` branch rebinds `pt-min` to `(point-min)`.** Without it,
   the OLD-PPSS branch's `set!` (which runs even when its test then
   fails) left `pt-min` at a position after POS, and the parse got
   FROM > TO.

## `parse-partial-sexp` accepts a short OLDSTATE

`move-past-close-and-reindent` passes a **nine**-element state
(`lisp.el:985`) and the C reads it with `Fcar`/`Fcdr`, which answer nil
past the end. `list-ref` raised "Argument 2 out of range: 9" instead;
`%oldstate-ref` walks the list.

## `move-past-close-and-reindent`, and the seam it needed

`lisp.el`'s function calls `calculate-lisp-indent`, which is
`lisp-mode.el`s - and `lisp-mode.scm` imports `lisp.scm`, so the call
comes back through `*calculate-lisp-indent-function*`, filled by
`lisp-mode.scm` at load, the way `simple.scm` fills
`*delete-horizontal-space-function*`. Bound to `M-)` (`bindings.el:1671`);
`C-M-q` is `indent-sexp` in `lisp-mode-shared-map` (`lisp-mode.el:818`)
and `C-M-\` is `indent-region` (`indent.el:811`).

## Still departures, and what each waits for

* **`syntax-propertize-rules`, the macro.** `elisp-mode-syntax-propertize`
  is written out as one scan over the four rules' alternation - the
  shape the macro produces - because the macro itself needs
  `regexp-opt-depth`, `subregexp-context-p` and match-data shifting. The
  `?\N{...}` rule is included. `lisp-mode-syntax-propertize` (the `|...|`
  multi-escape and `#` dispatch rules, `lisp-mode.el:106`) is *not*
  carried: it belongs to Common Lisp mode, whose indentation table is
  missing anyway.
* **`cl-indent.el`'s `common-lisp-indent-function`** (~900 lines of
  table) and **`scheme.el`'s `scheme-indent-function`**: not ported. A
  CL or Scheme buffer therefore indents with the default
  `lisp-indent-function`, and `lisp-mode-variables`/`scheme-mode-variables`
  do not store the symbol - a symbol is not callable here, so storing it
  would raise "Wrong type to apply" on the first indent.
* **`lisp--local-defform-body-p`** (`lisp-mode.el:1197`) **is** carried
  now - it was the difference between matching and not on `cl-extra.el`,
  `ert.el`, `eldoc.el`, `generator.el` and `comp.el`, all of which indent
  their `cl-flet`/`cl-labels` bodies as definitions. Two things had to be
  right: its `when`s must answer `#f` (Scheme's answer the unspecified
  value, which the caller reads as true), and Emacs's
  `(read (current-buffer))` leaves point **past the symbol**, which a
  string-port read does not - so the port does `(forward-sexp 1)` after
  reading the head.
* **`indent-pp-sexp`** (Emacs's `C-M-q` in `emacs-lisp-mode`) is
  `indent-sexp` plus `pp-buffer`, and `pp` is not ported; the mode keeps
  the shared map's `indent-sexp`.
* **`function-get`'s alias-following** is not carried - ours is `get`.
* The `function-get ... 'macro` table cannot see a macro from a library
  that neither is dumped nor autoloaded, which in practice means a
  *user's* library.

## The one remaining corpus difference: `icons.el`'s `define-icon`

Of the 110 files under `lisp/emacs-lisp/`, five still differ:
`cl-macs.el` (71 lines), `ewoc.el` (157), `icons.el` (6), `lisp-mode.el`
(2) and `warnings.el` (10). `icons.el`'s is understood and measured -
Emacs's `indent-region` gives column 13 where its own
`calculate-lisp-indent` gives 2 - and it is the same `define-icon`
shape in `warnings.el`. Its `(define-icon button nil '(...) ...)` form is
indented to column 13 by Emacs's `indent-region` - aligned under the
first argument, i.e. as if `define-icon` had no `lisp-indent-function`
property - while **Emacs's own `calculate-lisp-indent` at that line
answers 2** in the same session (measured directly, and `(get
'define-icon 'lisp-indent-function)` is 2 there too; `icons` is
preloaded). Emacs's `indent-region-line-by-line` gives 13 as well, so it
is not the fast path's cache. Ours answers what `calculate-lisp-indent`
answers, which is the function the engine is defined by. Emacs's two
paths disagree here and the port follows the documented one.

# The colourising pass: `\_<' in the engine, and the syntax table's Unicode blocks
# (2026-11-15)

`lisp-el-font-lock-keywords-2` is now the whole of Emacs's list, and its
faces match Emacs's run for run on 22 of 24 files under
`lisp/emacs-lisp/`. Five engine departures came out of it, four of them
in `search.c`'s territory.

## `\_<` and `\_>` are assertions now, not `\<`/`\>`

`symbeg`/`symend` (`regex-emacs.c:5508`, `:5549`) are zero-width tests of
the **syntax table** - the char at the position must be `Sword` or
`Ssymbol`, and the char before must not be - and no regexp substrate can
make one. The old translation replaced them with glibc's *word* boundary,
which is a different test: `&optional` and `:keyword` are `Ssymbol`, not
`Sword`, so `\<&` never matched, and both of those font-lock entries
(`lisp-mode--search-key`) silently did nothing.

The ERE now gets an **empty group** `\(\)` where the assertion goes, and
`%translate-emacs-regexp` records `(GLIBC-GROUP . symbeg-or-symend)`; each
search checks the assertions against the buffer's (or the current
buffer's table, for a string) syntax after a match, refuses the match and
**asks again from the next position** - which is what the C's
backtracking does, one layer up. `looking-at` and `string-match` do the
same. An assertion in an alternative that did not match has no position
and is skipped.

Two named limits: a pattern whose assertion is not at a fixed place under
glibc's leftmost-LONGEST parse may refuse a match the C's leftmost-FIRST
parse would have taken; and the retry restarts one character later, which
cannot reconsider alternative parses at the same start.

## One Emacs group may be several glibc groups

`\(?N:` is how a Lisp keyword regexp shares a group number between the
alternatives of a `\|`: `\(?1:a\)\|\(?1:b\)` is Emacs group 1 either way,
and glibc cannot make two groups one register. The mapping used to keep
the *last* one, so a match on the other alternative answered no group 1 -
font-lock's "No match %s in highlight" on `easy-mmode.el`. The mapping
now holds a list per Emacs group and the first that participated is the
register.

## `internal--syntax-propertize`'s `save-match-data`

The C calls the mode's propertize function **from inside a regexp match**
(`UPDATE_SYNTAX_TABLE` -> `parse_sexp_propertize`), and Emacs keeps that
safe with `(save-match-data (syntax-propertize ...))`
(`syntax.el:481`). The port called `syntax-propertize` bare, so the
function's own searches overwrote the match data of the match in flight -
the same "No match %s in highlight", and the same file. `save-match-data`
is `search.c`'s and `(schemacs editor syntax)` is *below* that library,
so the save is a seam: `*internal-syntax-propertize-function*`, installed
by `(schemacs editor search)`, which also saves `%current-group-map` and
`%current-assertions` - a nested search compiles patterns too.

A `syntax-propertize-chunks` (`syntax.el:473`, 2000) came with it.

## Getting there bit again: the first failure was arithmetic on `#f`

`(match:start m GROUP)` answers `#f` for a group that did not participate.
The assertion check did `(+ base #f)` on it, which raises three frames
from the cause.

## `%syntax-class-runs` must resolve parents

`char_table_ref_and_range` (`chartab.c:320`) narrows to a run of the
table's **own** values and does not consult the parent - its own comment
says so - and a syntax table is *always* inherited: `copy-syntax-table`
clears the default and sets the standard table as the parent, the C's own
line. So every character above ASCII was one run classified by the class
at its first position, i.e. word. `%char-table-runs` descends into the
parent where the child answers nil.

## The standard syntax table had none of `characters.el`

`init_syntax_once` gives every multibyte character `word` and stops;
`characters.el` then walks the Unicode blocks - general punctuation to
`.`, arrows and mathematical operators to `_`, the CJK bracket pairs to
`(`/`)` - and *that* is what makes `‘` punctuation and `→` a symbol in a
real Emacs. None of it was here, so every character above ASCII was word
syntax, and the keyword entries that match `` `word' `` and the
typographic quotes matched inside strings where Emacs matches nothing
(`checkdoc.el`, `chart.el`, `cl-print.el`).

`schemacs/editor/characters.scm` - the existing char-width library, which
is `characters.el`'s other half - now also carries
`standard-syntax-runs`: **Emacs 31.1's own answers**, 234 runs emitted by
a script that walked the standard table from `#x80` to `#x10FFFF` and kept
the runs that are not `word` (the method the charset registry and the
xterm decode map were transcribed by). `%standard-syntax-table` applies
them; `map-charset-chars` is not ported and is not needed, because the
answers are data.

## Bracket classes above ASCII are enumerated, not ranged

A range in a glibc bracket expression is read in the locale's
**collation**, not in code-point order. Measured here: `[\x7f-\xa0]` and
`[←-ⱏ]` are both "Invalid range end". The non-`word` runs of a syntax
table are 2344 code points in all, so `%ere-class-runs-text` enumerates
them one at a time. It also has to place the ASCII part's trailing `-`
*after* the enumeration (`%ere-class-join`), or glibc reads `-¤` as a
range.

## The syntactic pass's delimiter-face branch, ported

`font-lock.el:1612-1627` paints the comment's opening delimiter with
`font-lock-comment-delimiter-face` using `font-lock-comment-start-skip`
or `comment-start-skip`, and its closing one with `comment-end-skip` -
only when the face is exactly `font-lock-comment-face`, so a doc string
keeps `font-lock-doc-face` throughout. The port had it named as "not
carried" because newcomment.el was not ported; it is, so it is.

## Three transcription bugs in the Lisp keyword tables

* **`lisp--el-funcall-position-p` used `(car (last (cdr paren-posns)))`**
  where the C has `(car (last paren-posns 2))` - the *second-to-last*
  opener, the form the enclosing paren belongs to. Ours took the
  enclosing paren itself, so the `let` test never fired and
  `(interactive t)` in a `let*` binding list was coloured a keyword.
* **The "Erroneous structures" entry came after "Control structures"**;
  the C has it before. A face already set is not overwritten without an
  override, so `(cl-assert ...)` must keep the warning face.
* **`cl-defmethod`'s `doc-string-elt` held the symbol
  `cl--defmethod-doc-pos`**; there is no obarray here, so `functionp` was
  false and the numeric compare raised. The table holds the procedure,
  the same spelling the keyword tables use for their matchers.

## The last two files, and the spurious backslash

`check-declare.el` and `cl-print.el` differed by a `` `...' `` span our
engine matched inside a string where Emacs's matched nothing; the span
ended at a backslash-escaped quote. The cause was `%ere-class-escape`:
it wrote `^` as `\^`, and **glibc gives backslash no meaning inside a
bracket expression**, so that is the two characters `\` *and* `^` -
every class silently gained a backslash member, and the symbol class
therefore accepted `\'` as a symbol character. Measured, `[\^]` matches
both. `%ere-class-body` now places `^` anywhere but first instead of
escaping it, and nothing is escaped in a bracket at all.

With that, the face-run differential is **24 of 24 files under
`lisp/emacs-lisp/` exact**.

## `scheme-mode`: `define-library`'s second half

`(define-library ...)` comes out `define` keyword-face, `-library`
function-name; Emacs paints 2..16 all keyword-face. Emacs's
`scheme-font-lock-keywords-1` matches only `(define` there (its second
group is unset), so the rest of the run comes from a level-2 entry this
pass did not chase - scheme-mode was the *previous* pass's subject and
its face runs were not part of this differential. Named rather than
guessed at: the harness is `/tmp/faces-scheme.el` and
`/tmp/ours-scheme.scm`, and it is a two-line reproduction.

# The departures this round of "fix those departures" closed
# (2026-11-16)

## `\<`, `\>`, `\b` and `\B` were glibc's word class, not the table's

`%pass-through-escape` handed all four to glibc, whose word class is the
locale's `[[:alnum:]_]`. Emacs's are `SYNTAX (c) == Sword` tests
(`regex-emacs.c:5379`, `:5424`, `:5465`), and the two disagree wherever
a table says `$` or `%` is a word constituent - and in **scheme-mode's
font-lock table**, where `+-*/.<>=!?$%_&~^:` are `w` for fontification.
That is why `(define-library ...)` painted `define` keyword and
`-library` function-name: our `\>` held after `define` where Emacs's did
not, so the level-1 entry matched a form Emacs leaves to the
control-structures entry. All four are assertions now, like `\_<`, with
the C's edge cases (`\b` at the buffer's ends is a boundary; `\B` there
is not).

## `syntax-propertize-rules` (`syntax.el:223`) - the engine, not the scan

The macro compiles its rules into **one scan**: the regexps are joined
with `\|` and the groups say which rule matched. Ported, as a
**procedure** (Scheme has no macro-expansion-time `eval`, so a rule's
REGEXP is a string and an ACTION is a procedure of no arguments); the
engine's offset accounting, group-0 wrapping,
`syntax-propertize--shift-groups-and-backrefs` and the match-data shift
for code actions are the C's.

Two bugs found in the porting: `offset` was rebound in a `let*` instead
of `set!`-ed, so every rule after the first saw offset 0 and the
`\(?1:` groups of rule 4 collided with the wrapper groups; and
`%shift-match-data` used `list-tail` on a list that `match-data`
legitimately shortens (it elides registers that did not match -
`(match-data)` for `\(a\)\(b\)?' on "a" is `(0 1 0 1)` there too).

**Placement**: the engine is in `(schemacs editor search)`, not
`syntax.scm`, because the scan needs `re-search-forward`,
`match-beginning` and `set-match-data`, and `syntax.scm` is below that
library. `subregexp-context-p` (`subr.el`) and `regexp-opt-depth`
(`regexp-opt.el`) moved with it - `(schemacs regexp-opt)` already
imports `search`, so importing it back would be a cycle; they live there
as `locate-file-internal` lives in `fileio`.

`regexp-opt-depth` is a scanner rather than the C's
`(string-match regexp "")` + `subregexp-context-p` pair (that library is
below `string-match`); checked against Emacs on thirteen patterns,
identical answers. `subregexp-context-p` is a scanner too, for the
reason its comment gives: our engine words two of the three
"non-context" parse errors differently, so the state is decided rather
than diagnosed.

Wired: `elisp-mode-syntax-propertize` is Emacs's four rules now (it was
a hand-written single alternation) and `lisp-mode-syntax-propertize` is
new, from `lisp-mode.el:106`.

## `scheme-indent-function`, and the table behind it

`scheme.el:562-760` is ported: the two functions and all 59
`scheme-indent-function` properties (including the MIT-dialect block,
which is gated on `scheme-mit-dialect` - default `t`), plus the nine
`scheme-doc-string-elt` properties. `lisp-doc-string-elt-property` is a
`defvar-local` in Emacs and was a plain variable here; it is read per
buffer now, so `scheme-mode` can name its own property.

Measured against `emacs -Q --batch`: `let` body 2, `lambda` body 2,
`define` body 2, `if` continuation 4, `begin` body 2, and `do`'s body
line answering **the pair `(4 1)`** - which is what
`lisp-indent-specform` answers there.

## `scheme-syntax-propertize`, and the narrowing it needs

`scheme.el:684-760` is ported - `#;` datum comments get a comment
delimiter pair around the commented sexp, `#/.../` gets a string end.
**`save-restriction`/`narrow-to-region` are not ported**, so the C's
narrowed `forward-sexp` is emulated by checking where the sexp landed: a
sexp that runs past END is the C's `scan-error`.

One real scanner bug came out of driving it: `%forw-comment` used
`(set! nesting (- nesting 1))` **in value position**. `set!` answers
*specified-or-unspecified* and here answered the unspecified value,
so a nested `#|` comment made the nesting count `#<unspecified>` and
`=` raised. It reads the new count through a `let` now.

Two residual differences, both measured and both on the record:

- A `#;` **inside a commented sexp** gets `< cn` but not the matching
  `> cn` markers Emacs puts on the inner one, and ours writes a `> cn`
  further along. The restart recursion (`(loop (point))` inside the
  C's `while`, then continue) is ported; where it goes wrong is not
  diagnosed.
- Scheme indentation on two of the tree's own test files now differs
  from Emacs's `indent-region` by a few levels - in the same place
  `calculate-lisp-indent` and `indent-region` **disagree with each
  other in Emacs itself** (the `icons.el` finding from the indentation
  pass). Ours answers what `calculate-lisp-indent` answers.

## The Common Lisp indentation engine (`cl-indent.el`)

`(schemacs editor cl-indent)` is a port of `lisp/emacs-lisp/cl-indent.el`:
`common-lisp-indent-function`, its specform walk (`lisp-indent-259`), the
lambda-list aligner, the tagbody/do/defmethod helpers, and the whole
method table. `lisp-mode` installs it as `lisp-indent-function`, as
`lisp-mode.el:866` does. What follows is what the port reads differently.

### A function in a method is a procedure, not a symbol

- **Emacs**: a method entry may be a *symbol* -
  `(defmethod lisp-indent-defmethod)`, `(lambda (&lambda &rest
  lisp-indent-function-lambda-hack))` - and `(funcall tem ...)` calls it.
  Elisp is a Lisp-2.
- **Here**: a Scheme symbol is not callable, so an entry that names a
  function holds the *procedure* (`(defmethod ,lisp-indent-defmethod)`,
  quasiquoted). `lisp-indent-259`'s validation and dispatch test
  `procedure?` where the C tests `symbolp`, and `common-lisp-indent-call-method`
  does the same. Everything else - integers, `defun`, `&lambda`, `&body`,
  `&rest`, `&whole`, the specform lists - is the C's data verbatim.

### `lisp-mode` reaches the engine through a `resolve-module` seam

- **Emacs**: `common-lisp-indent-function` carries `;;;###autoload`, so
  `(setq-local lisp-indent-function #'common-lisp-indent-function)` names
  a symbol that loads `cl-indent.el` when it is first called.
- **Here**: `cl-indent.scm` imports `lisp-mode.scm` (it needs
  `lisp-body-indent` and `lisp-indent-local-overrides`), so an import back
  would be a cycle. `lisp-mode`'s body calls `%cl-indent-function`, which
  does `(resolve-module '(schemacs editor cl-indent) #t)` and
  `module-ref`s the procedure - the same seam `files.scm`'s
  `%mode-autoloads` uses for a mode. The extent is Emacs's; the spelling is
  the tree's.

### The property table is static data, and Emacs's is not

- **Emacs**: a macro's `lisp-indent-function` property exists only after
  the library defining it has been loaded (`defmacro` reads the macro's
  `(declare (indent N))` at definition time). `lisp-indent-function` uses
  `(function-get SYMBOL 'lisp-indent-function 'macro)`, which *loads* an
  autoloaded macro's file; `common-lisp-indent-function` - the one
  `lisp-mode` installs - uses a plain `get` and so sees only what is
  already loaded.
- **Here**: `lisp-mode.scm` holds the properties as data, transcribed from
  a running Emacs that had been asked about every interned symbol and had
  `function-get`'s autoloads forced. So a symbol whose defining library is
  *not* autoloadable (`ad-do-advised-functions`, `iter-defun`) has no
  entry, and Emacs would have one after loading that library.
- **Consequences, measured** - a differential over the first forty
  `lisp/emacs-lisp/*.el` files, `lisp-mode` + `indent-region` on both
  sides:
  - against an Emacs with `function-get`'s autoloads forced (which is
    what `emacs-lisp-mode`'s `lisp-indent-function` consults), **32
    identical, 8 different**, and every difference is one of these
    symbols (`ad-do-advised-functions` in `advice.el`, `iter-defun` in
    `avl-tree.el`, ...). Supplying
    `(put 'ad-do-advised-functions 'lisp-indent-function 1)` to this
    tree makes `advice.el` byte-identical, so the engine is not the
    difference.
  - against a plain `emacs -Q --batch`, **13 identical, 27 different** -
    because `common-lisp-indent-function` uses a plain `get`, so there
    Emacs sees only the properties whose libraries happen to be loaded,
    and this tree's data always answers with the autoload-forced value.
- So the table is the right answer for `emacs-lisp-mode` (where Emacs's
  own answer comes through `function-get`) and the "too complete" answer
  for `lisp-mode`. Closing it fully needs a notion of which Emacs
  libraries are loaded, which this tree has not got; closing it by
  dropping entries would make `emacs-lisp-mode` wrong instead. The
  table's own comment records why the transcription is not simply
  extended either: loading one library perturbs the answer for symbols
  asked about later.

### `derived-mode-p` lives in `derived.scm`, not `subr.scm`

- **Emacs**: `derived-mode-p`, `provided-mode-derived-p`,
  `derived-mode-all-parents`, `derived-mode-set-parent`,
  `derived-mode-add-parents` and `derived-mode--flush` are `subr.el`'s
  (`:2984-3160`), and `merge-ordered-lists` with them.
- **Here**: they are in `(schemacs editor derived)`, because `subr` cannot
  see a buffer and `major-mode` is `buffer.c`'s. `merge-ordered-lists` is
  in `subr.scm` (it needs nothing from a buffer) and `intern-soft` beside
  `intern`. The same seam `locate-file-internal` took into `fileio.sld`.
- **Also**: `derived-mode-all-parents`'s alias branch -
  `(let ((alias (symbol-function mode))) (and (symbolp alias) alias))` -
  is not carried; there are no function cells here, so a mode is never an
  alias. `define-derived-mode` now `put`s `derived-mode-parent` and
  normalises a `fundamental-mode` parent to nil, as `derived.el:186` does -
  which is what makes `(derived-mode-all-parents 'prog-mode)` answer
  `(prog-mode)` and not `(prog-mode fundamental-mode)`.

### `intern-soft` always answers a symbol

`intern-soft` is `string->symbol` for a string and identity for a symbol;
every Scheme symbol is interned. `common-lisp-indent-function-1`'s
"pleblisp package feature" branch - `(when (and (null tem)
(string-match ":[^:]+" function)) ...)`, which strips a `package:` prefix
from a name no obarray entry matches - is carried as the C has it and can
never fire here.

## `min' and `max' are `min-col' and `max-col' in `comment-choose-indent'

- **Emacs**: `(let ((min ...) (max ...)) ... (max min (min max indent)))`
  binds two *variables* called `min`/`max` and calls the two *functions*
  of the same name from the same form. Elisp is a Lisp-2, so that is legal
  and clear.
- **Here**: a Scheme binding shadows the procedure of the same name, so
  the C's names cannot be kept - `(max min (min max indent))` applied the
  integer `min` ("Wrong type to apply: 57"). The locals are `min-col` and
  `max-col`, and the procedure calls keep the core names.
- Found by `indent-region` over a file with right-hand-side comments;
  nothing had ever reached `comment-choose-indent` before.

## The tab line: `icon-preference`, `icons--create` and touch

- **Emacs**: an icon's specification lists forms in the user's preference
  order (`icon-preference`: image, emoji, symbol, text) and
  `icons--create` answers one only if the display can show it - an image
  needs `display-images-p`, an emoji needs a colour font.
- **Here**: `icons--create` answers #f for `image` and `emoji` (this tree
  has no image display and no `internal-char-font`), so the preference
  falls to `symbol`/`text`. That is Emacs's own answer on a text
  terminal; it differs only on a graphical frame, where this tree draws
  no images either. Closing it means image support in the Gtk front end
  first.
- `tab-line-track-tap` and `touch-screen-track-tap` have nothing to run
  on - this tree has no touch input - and are named rather than carried
  in `tab-line.scm`.

## The tab line, part 2: the Lisp half, and the five primitives under it

`tab-line.scm` is in. The display half landed in `afddbbf`; this pass is
the format, the tab list, the commands, `tab-line-mode` and
`global-tab-line-mode`, and the primitives each of them needed. The
departures are the tree's, and the bugs worth naming were all
Elisp-nil-versus-Scheme-`'()` or a function that had never had a caller.

### `:global` in `define-minor-mode`, and where a global value lives

- **Emacs**: a `:global` minor mode's variable is not buffer-local; the
  command does `(setq-default ,mode)` and the getter is
  `(default-value ',mode)`, i.e. the symbol's own value cell.
- **Here**: the value cell is `(schemacs editor data)`'s
  `*default-values*`, keyed by symbol, with `default-value`,
  `set-default` and `default-boundp` - `data.c`'s three, since the tree
  has no obarray. `default-value` takes an optional default where Emacs
  signals `void-variable`, because naming the symbol in that error needs
  the registry this tree deliberately does not have; every caller here
  has a default to offer.
- `minor-mode-variable-true?` and `minor-mode-indicator-value`
  (`xdisp.scm`) now read `(buffer-local-value buf var (default-value var
  #f))`, which is `symbol-value`'s rule - a buffer's own value if it has
  one, the default otherwise. Without that a global mode's lighter would
  never show.
- The *variable* is not a `defcustom`, so the customize keywords
  (`:group`, `:version`, `:set`, `:initialize`, `:type`) are accepted and
  dropped by `define-minor-mode`. That is the same wall a buffer-local
  minor mode's variable has always been behind.

### `define-globalized-minor-mode`: `:predicate`, and the places it can't take

- **Emacs**: `:predicate` makes a `MODE-modes` defcustom and a turn-on
  that consults `easy-mmode--globalized-predicate-p`; `:variable` may be
  any `(GET . SET)` place; the generated command's `bound-and-true-p`
  reads a symbol's value.
- **Here**: `:predicate` is refused at expansion with a message (a mode
  that wants one can test `derived-mode-p` in its own TURN-ON);
  `:variable` is a symbol only; and "is the mode's variable true in this
  buffer" is `buffer-local-value` with a #f default, which is this
  tree's spelling of `bound-and-true-p` for a variable the mode's own
  accessors set. The macro's five generated names keep Emacs's spelling
  without asterisks, like `MODE-hook`, because they are generated from
  Emacs's own names rather than read by a user.

### `:eval` holds a procedure, not a form

- **Emacs**: `(:eval FORM)` in `mode-line-format` is `(eval FORM)`, which
  is why `tab-line-format` is `(:eval (tab-line-format))`.
- **Here**: `format-mode-line`'s `:eval` construct holds a *procedure and
  calls it* (`xdisp.scm`), so `tab-line-mode` installs
  `(:eval tab-line-format)`. This is a pre-existing departure of the
  mode-line formatter, found by `tab-line-mode` being the first caller
  that writes the Emacs shape. Closing it means giving `format-mode-line`
  an evaluator and an environment, and converting the three constructs
  `bindings.el`'s variables already use.

### Five primitives that had never had a caller, and what each was hiding

Each of these was written and never exercised; the tab line is the first
caller of all five.

1. **`define-icon`'s keyword plist was unquoted.**
   `(list (quote keyword) value ...)` put each value in *expression*
   position, so a two-pair list - `:version "30.1" :help-echo "New tab"` -
   evaluated `:help-echo` and reported it unbound. A single string value
   worked by being self-evaluating, which is why nothing had noticed. The
   expansion is `(quote (keyword value ...))`, which is Emacs's
   `',keywords`.
2. **`copy-sequence` had only its string arm.** It refused a list with
   "Wrong type argument: sequencep", and `icons--copy-spec` is
   `(map #'copy-sequence spec)` over lists - so *every* icon failed
   before `icon-string` could pick a form. The list, empty-list and
   vector arms are Scheme calls (`list-copy`, `vector-copy`) and are now
   there.
3. **`icon-string` tested `(null? (and type-spec ...))`.** Elisp's nil is
   both #f and `'()`; here `(and ...)` answers #f and `(null? #f)` is
   false, so an absent `symbol` or `text` section fell into `(car #f)`.
4. **`get-pos-property` had no string arm.** The C's first act for a
   non-buffer object is `return Fget_text_property (...)` - strings have
   no overlays and no notion of insertion - and ours fell through to
   `buffer-beg`, i.e. "Wrong type argument: struct" on a string.
   `tab-line--get-tab-property` asks it about the tab string, which is
   how a click finds its tab.
5. **`posn-string` was missing** and is `subr.el`'s: the object slot,
   `(nth 4 position)`, when it is a cons. It is what a click on a display
   string reports, and it is how the tab commands learn which tab was
   clicked.

### `seq.el` is lists only

`seq.scm`'s own departure, extended: the tab line needed `seq-uniq`,
`seq-difference`, `seq-sort`, `seq-sort-by`, `seq-position`, `seq-keep`,
`seq-subseq`, `seq-take`, `seq-drop`, `seq-group-by`, `seq-do-indexed`
and `seq-copy`, and each is written over lists. `cl-position` and
`evenp` are `seq-position` and `even?`.

### `walk-windows`, and the tab line's cache flush

- **Emacs**: `tab-line-force-update`'s ALL branch is
  `(walk-windows (lambda (w) ...) 'no-mini t)`.
- **Here**: `walk-windows` is `window.el`'s and needs `next-window`,
  which is not ported; the ALL branch walks each frame's `window-list`
  with `'nomini`, which is the same set for those two arguments.
  `force-mode-line-update`'s ALL argument already marks one flag, so
  nothing else about the walk matters.

### The click on a tab reaches `tab-line-select-tab` now

- **Emacs**: `make_lispy_event` prefixes a click whose position has a
  *symbol* area with that symbol, so the key looked up is
  `[tab-line down-mouse-1]`; and `current_active_maps`
  (`keymap.c:1649`) adds the `keymap` text property of the posn's
  *string* to the active maps. That pair is the whole of "a tab is a
  button".
- **Here**: both are ported (`dispatch-key-event`'s fake prefix and
  `lookup-keymaps`' position argument) and a click on a tab runs
  `tab-line-select-tab`. Three things had to come with them, and each
  is Emacs's own rule rather than a workaround:
  `format-mode-line` keeps text properties now (its `%`-expansion used
  to rebuild the string in a port, which threw away the `keymap` the
  tab carries); `draw-mode-line!` resolves an anonymous face
  (`(:inherit (FACES))`) through `merge_face_ref`; and the redisplay
  rebinds `selected_window` around a window's mode/tab line
  (`display_mode_lines`), which is what makes each window's tab line
  describe its own window.
- **Still not carried**: the string's `local-map` property, and
  `read_key_sequence`'s switch to the clicked window's buffer before the
  lookup - `lookup-keymaps` reads the current buffer's map. Neither is
  reachable from a tab click.

### `vertical-motion` reads the current buffer, and now says so

- **Emacs**: `vertical-motion` has no buffer argument. Its iterator takes
  the width, the wrapping and the hscroll from the window and the
  *characters* from `current_buffer`, which is why
  `tab-line-auto-hscroll` can measure a tab line in a scratch buffer no
  window shows.
- **Here**: the row helpers were window-first - `buffer-line-texts-at`
  read `(window-buffer window)` - so `vertical-motion` measured the shown
  buffer's lines whatever the current buffer was. `tab-line-auto-hscroll`
  therefore answered "the tabs wrapped" for every tab line: a stray `>`
  button on a row whose tabs fit, and no way to reach the ones that did
  not. The helpers take an optional buffer now (defaulting to the
  window's) and `vertical-motion` passes the current one. The fallback to
  the window's buffer when there is *no* current buffer is this tree's:
  a live editor always has one, a test may not.

### Named, not carried, in `tab-line.scm`'s header

The buffer menu behind `tab-line-new-tab-choice`'s `t` (`mouse-buffer-menu`
and `tmm-prompt` do not exist); the two context menus (`popup-menu` is
`menu-bar.el`'s; `x-popup-menu` is ported); touch; `project.el`'s
group-by-project; `mouse-buffer-menu-mode-groups` (nil here, which is
Emacs's documented fallback - one group per major mode);
`tab-line-tab-name-truncated-buffer` (`truncate-string-to-width`,
`mule-util.el`); `window-persistent-parameters`;
`switch-to-buffer-obey-display-actions`; and `repeat-mode`.

### `font-core.scm` onto the macro, and a `let` that bound nothing

`global-font-lock-mode` was the hand-written copy of
`define-globalized-minor-mode` this file's own header apologised for; it
is the macro call now, which is the proof that the macro works and
removes the duplicate. Its `turn-on-font-lock-if-desired` bound
`(let ((*inhibit-quit* #t)) ...)` - a `let` over a *parameter's name*,
which creates a new local variable and rebinds nothing - so the C's
`(let (inhibit-quit) ...)` is now `parameterize`, with Emacs's nil.

## Still not ported

- `elisp-fontify-symbols` and the semantic-highlighting engine it
  drives (`elisp-scope.el`, **2,868 lines**). Both are off by default
  (`elisp-fontify-semantically` is `nil`), so no default session sees
  them.
