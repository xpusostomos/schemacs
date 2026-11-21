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

# The tab bar's departure: `get_keyelt`'s `:filter` (2026-11-16)

GNU Emacs binds the tab bar's keymap as a *filtered* menu item:

```elisp
(global-set-key [tab-bar]
                `(menu-item "tab bar" ,(make-sparse-keymap)
                            :filter tab-bar-make-keymap))
```

and `get_keyelt` (`keymap.c:700`) applies `:filter` on every lookup:

```c
	      /* If there's a `:filter FILTER', apply FILTER to the
		 menu-item's definition to get the real definition to
		 use.  */
	      for (; CONSP (tem) && CONSP (XCDR (tem)); tem = XCDR (tem))
		if (EQ (XCAR (tem), QCfilter) && autoload)
		  {
		    Lisp_Object filter = XCAR (XCDR (tem));
		    filter = list2 (filter, list2 (Qquote, object));
		    object = menu_item_eval_property (filter);
		    break;
		  }
```

`menu_item_eval_property` is `keyboard.c`'s, and `keymap.scm` is below
`keyboard.scm` in this tree's import graph, so `get-keyelt` cannot call
it: its `autoload` parameter is documented and never set. `tab-bar-items`
does the filter's work itself - it calls `tab-bar-make-keymap` before it
walks the maps - so the *observable* result is the C's and the departure
is where the call happens, not what it produces. The same shape as
`locate-file-internal` in `fileio.scm` and `read-buffer-to-switch` in
`minibuffer.scm`.

# `window-set-configuration`'s frame resize (2026-11-16)

`Fset_window_configuration` ends with

```c
      f->can_set_window_size = true;
      adjust_frame_size (f, -1, -1, 4, false, Qset_window_configuration);
```

which asks for *no* change to the frame's size - `-1`/`-1` - and only
re-lays the windows out. This tree's `set-window-configuration` restores
the geometry it saved and does not call `resize-frame-windows!`, because
the saved rectangles are the ones the configuration was recorded with and
the frame cannot change size in this editor except by a terminal resize,
which re-runs the layout anyway.

# `parse_tab_bar_item`'s `:enable` (2026-11-16)

The C evaluates an `:enable` form on every parse and skips a disabled item
**only in a menu bar** (`if (inmenubar && NILP (tem)) return 0;`). For the
tab bar it stores the evaluated value in `TAB_BAR_ITEM_ENABLED_P` and
keeps the item; `display_tab_bar` draws every item it is given, enabled or
not. This port stores the value the same way and draws every item, so an
`:enable` in a tab's item has no visible effect - which is also what
Emacs's terminal tab bar does, since `display_tab_bar` never asks.

# `tab-bar-history-mode`'s change detection, ported (2026-11-17)

GNU Emacs notices that a command changed the window configuration through
the frame's `FRAME_WINDOW_CHANGE` flag, which these sites set -

```c
  FRAME_WINDOW_CHANGE (f) = true;   /* window.c:3715  Fdelete_other_windows_internal */
                                    /* :4427  set_window_buffer (if !samebuf,
                                       and neither a mini nor a pseudo window) */
                                    /* :4896  window_resize_apply              */
                                    /* :5681  Fsplit_window_internal           */
                                    /* :5828  Fdelete_window_internal          */
                                    /* :8082  Fset_window_configuration        */
```

- and `run_window_change_functions` (`window.c:4111`), called from
`redisplay_internal` (`xdisp.c:17588`), decides whether anything really
changed: for a frame whose flag is set it walks the live windows and asks
whether any changed its buffer, its pixel or body-pixel size, or was
newly created (`w->change_stamp != f->change_stamp`), and whether the
frame now has fewer live windows than at the last run. **Only then** does
`window-configuration-change-hook` run (`window.c:4308`) - and
`tab-bar--history-change` is on that hook.

This port now has all of it: `<frame>`'s `change-stamp`/`window-change`/
`old-selected-window`/`number-of-windows`, `<window>`'s `change-stamp`/
`old-buffer`/the four old sizes (`window.h`'s fields), `window-sub-list`,
`window-change-record-windows`, `window_change_record` and
`run_window_change_functions` (`window.c:4111`), with the last called
from `redisplay-frames!` in the place the C calls it. Measured against
Emacs 31.1 in an `emacs -nw` pty, counting the hook's calls:

| event | Emacs | here |
|---|---|---|
| split | 1 | 1 |
| `set-window-configuration` of the same layout | 0 | 0 |
| `set-window-configuration` of a different layout | 1 | 1 |
| `select-window` on the selected window | 0 | 0 |
| `set-window-buffer` to a different buffer | 1 | 1 |
| `set-window-buffer` to the same buffer | 0 | 0 |

`window-tests.scm` pins every row.

## This replaces a fingerprint, and an account of its differences that was wrong

The previous version compared a *fingerprint* of the window tree at the
next command's `pre-command-hook`. Two differences were claimed for it;
one was real and one was not.

**Real**: the push was one command late, which no command could see but a
non-command reader could - a timer, or the REPL back door.

**Not real, and measured**: the note said `Fset_window_configuration` sets
the flag unconditionally "so restoring a configuration identical to the
current one pushes a history entry in Emacs and not here". It does not
push. The flag is only the first gate; the per-window comparison above is
what runs the hook, and a restore of the layout the frame already has
changes no window's buffer or size and deletes nothing. Measured on Emacs
31.1: `ran=0`. A port that took the flag as the answer would push where
Emacs does not - exactly the wrong correction, from reasoning about the
C instead of asking it.

## Where the flag is set here, and the two places it is set by hand

The six C sites are ported as they stand. Two more places need it
because this tree reaches the same result by a different route than the
C's:

* **`delete-other-windows`** (`window.scm`). The C's
  `Fdelete_other_windows_internal` sets the flag itself (`window.c:3715`);
  this port's version of the function is a rebuild of the tree rather than
  the C's resize walk, and had no such statement.
* **`resize-frame-windows!`** (`frame.scm`). The C's
  `resize_frame_windows` ends in `window_resize_apply`, which sets the
  flag (`:4896`); this function scales the rectangles itself. This is the
  terminal-resize path, so without it a resized frame runs no
  `window-configuration-change-hook` at all.

Both are marked at the line.

## Not carried, and what each needs

* **The three per-window hook families** -
  `window-buffer-change-functions`, `window-size-change-functions`,
  `window-selection-change-functions`, local and default - and
  `window-state-change-hook`. Their arguments and their buffer-local
  machinery are a whole notification surface with no consumer here. The
  *inputs* they need are kept, since they are what decides the
  configuration hook.
* **`FRAME_WINDOW_STATE_CHANGE`.** Only the Lisp function
  `set-frame-window-state-change` (`frame.c:5047`) ever sets it, and
  nothing here calls one.
* **The buffer-local half of `window-configuration-change-hook`**
  (`window.c:3810`): a buffer-local hook slot is a thing this tree's
  parameters do not have. Only the global value runs.
* **`specbind (Qinhibit_redisplay, Qt)`** around the run (`:4121`):
  `*inhibit-redisplay*` is `xdisp.scm`'s and that library is above this
  one. A hook that calls `redisplay` would recurse where Emacs suppresses
  it.
* **`f->can_set_window_size` / `f->after_make_frame`**, Gtk sizing state.
  Emacs skips a frame that is not yet fully made; here a frame is fully
  made when the constructor returns.
* **`report_selected_window_change`** (the input method).

# `tab-bar-auto-width`, and `string-pixel-width` in a cell renderer
# (2026-11-17)

`tab-bar-auto-width` (`tab-bar.el:1288`) is ported: every tab's name is
padded or truncated to `(frame-inner-width - the non-tab items) / the tab
count` pixels, clamped by `tab-bar-auto-width-min`/`-max`, and the
padding is a space that carries the name's own text properties - which is
exactly what Emacs does, so a renderer that draws cells sizes the bar the
same way.

## What is not carried

* **The memoization** (`tab-bar--auto-width-hash`, keyed by
  `equal-including-properties`). It is a cache, not a rule: the names come
  out the same. This tree has no `equal-including-properties` to key it
  with, and what the cache saves is the padding loop's repeated
  measurement, which here is a `string-width` rather than a glyph walk.

## `string-pixel-width` is the cell model, and lives in `xdisp.scm`

`subr-x.el:389`'s function measures a string by filling a work buffer and
running the display iterator over it (`buffer-text-pixel-size`), which
asks the font. This tree has one cell size per frame, so the answer is
`(string-width STRING) × (frame-char-width)` - the same product
`window-pixel-width` is. A line's width is its cell width; a string with
newlines answers its widest line, as the C's docstring promises.

**Placement**: `xdisp.scm`, not a `subr-x` library, because it needs
`frame-char-width` and `subr.scm` is below `frame.scm` - the same seam
reasoning that put `locate-file-internal` in `fileio.scm`.

`buffer-text-pixel-size` itself is not ported: there is no font metric to
ask, so it would be a multiplication behind a glyph walk.

# The tab bar's drag, its right-click menu, and detaching a tab
# (2026-11-17)

The rest of `tab-bar.el`'s mouse surface and the two commands that move a
tab to another frame:

| Emacs | here |
|---|---|
| `tab-bar-mouse-move-tab` (`:473`) and the `<drag-mouse-1>` binding (`:566`) | same, `tab-bar-map` |
| `tab-bar-mouse-context-menu` (`:431`) and `<down-mouse-3>` (`:569`) | same, over `popup-menu` |
| `tab-bar-move-tab-to-frame` (`:1912`) | same |
| `tab-bar-detach-tab` (`:1949`) | same |

`tab-bar-move-tab-to-frame` keeps only the tab's window *state*: a saved
configuration holds window objects that belong to the frame it was made
on, so `(assq-delete-all 'wc ...)` drops it, exactly as the C does. The
source frame is left through `with-selected-frame`, with
`tab-bar-close-last-tab-choice` bound to `delete-frame` and
`tab-bar-closed-tabs` to nil - which is why moving the last tab is a
frame deletion and not an error.

**Not carried**: `tab-bar--dragging-in-progress`, which Emacs writes in
three places and reads nowhere.

## `make-frame` now applies its parameters

Emacs's `make-frame` hands the caller's alist to
`frame-creation-function`, which merges `window-system-default-frame-alist`
and `default-frame-alist` *under* it (`frame.el:1094`-`:1109`) so the
caller wins. This tree's creation functions take no arguments, so the
parameters are applied with `set-frame-parameter` after the frame is made
- which is what a front end would have done with them, `name` included.
`window-system-default-frame-alist` and `frame-inherited-parameters` are
still not carried, and a caller's value leaves the `default-frame-alist`
duplicate in the alist rather than replacing it.

## Two bugs underneath, both pre-existing

1. **`assoc-delete-all` was missing the C's `consp` guard in its skip
   loop.** `subr.el:1066`'s walk is `(while (and (consp (car alist))
   (funcall test (car (car alist)) key)) ...)`; the port tested
   `(car (car rest))` unguarded, so an alist whose first element is not a
   cons raised. A tab is `(tab (name . "x") ...)` - its head is the
   *symbol* `tab` - so `tab-bar-move-tab-to-frame` died on
   `(car 'tab)`. `subr-tests` has both functions on such an alist now.

2. **`tab-bar-new-tab-to` still named the history hash tables by the bare
   names** (`tab-bar-history-back`), which the *commands* of the same
   names later overwrite. Restoring a tab from a window state therefore
   died in `hashq-set!` on a procedure. The tables are
   `tab-bar-history-back-table`/`-forward-table`, and the two sites say so
   now.

# Narrowing, and the two bounds that were the whole buffer (2026-11-17)

`fill.el` needs `narrow-to-region`/`save-restriction`, which this tree had
never had, so the restriction came first. A buffer now carries Emacs's
`BEGV` and `ZV` (`buffer.h:1054`) beside its `PT`, and:

* `narrow-to-region` (`editfns.c:2948`) sorts the two ends, refuses
  anything outside `BEG..Z`, stores them, and pulls point inside the new
  range; `widen` (`:2901`) puts them back; `save-restriction` (`:3150`)
  saves a pair of *markers* - the end one with an insertion type of 1, so
  text inserted exactly at the end is inside the restored restriction -
  and puts them back on an abnormal exit too, because it is a
  `dynamic-wind`;
* `point-min` and `point-max` answer `BEGV`/`ZV`;
* `goto-char` clips to them (`clip_to_bounds (BEGV, ..., ZV)`);
* every insertion grows `ZV` with `Z` and every deletion shrinks it
  (`insdel.c:935`, `:1597`, and `replace_range`'s two writers).

**The change that made it work everywhere at once**: `buffer-beg` and
`buffer-z` in `buffer.scm` answer `BEGV`/`ZV` now. Their docstrings had
always *called* them `point-min`/`point-max` and their bodies returned the
text's `BEG`/`Z` - identical while nothing was ever narrowed. Every scanner
that asks those two where the text starts and ends (`search.scm`,
`syntax.scm`, `simple.scm`, `xdisp.scm`) therefore bounds itself by the
accessible portion without being touched, which is exactly what the C's
scanners do. The whole text keeps its own two reads -
`buffer-text-base`/`buffer-text-z` of `(text-editor-text b)` - for the
places that really mean it: `widen`, `narrow-to-region`'s range check,
`buffer-size` and `erase-buffer`.

## `buffer-size` is `Z - BEG`, not `ZV - BEGV`

`(buffer-size)` answers the whole text however narrow the restriction is;
`buffer-string` answers the accessible portion. The old docstring here
said the opposite ("Narrowing is in effect, this returns the size of the
accessible portion") - it was the *`buffer-string`* rule, not
`buffer-size`'s. Measured on Emacs 31.1: an 11-character buffer narrowed
to 1..5 answers 11, and its string is 4 characters.

## `validate_region` signals, it does not clip

`delete-region`'s range check is `buffer.c:2504`: sort the ends, then
`if (! (BEGV <= beg && end <= ZV)) args_out_of_range_3 (...)`. The first
version of this pass *clipped* instead, which reads as the kinder
behaviour and is not Emacs's: `(delete-region 1 12)` in a buffer narrowed
to 3..5 is "Args out of range" there, and now here.

## Every rule `BEGV`/`ZV` governs, checked against the C

| primitive | the rule | where |
|---|---|---|
| `goto-char` | clips to `[BEGV, ZV]` | `editfns.c` |
| insert / delete / `replace_range` | `ZV` moves with `Z` | `insdel.c:935`, `:1597` |
| `del_range_1` | clips FROM to `BEGV`, TO to `ZV`, then returns on an empty range | `insdel.c:1875` |
| `validate_region` | sorts, then **signals** outside `[BEGV, ZV]` - never clips | `buffer.c:2504` |
| `delete-region`, `buffer-substring`, `buffer-substring-no-properties`, `casify-region` | all open with it | `editfns.c:1674`, `casefiddle.c:534` |
| `char-after` | **nil**, not an error, outside the restriction | `editfns.c` |
| searches | nil bound is `ZV`/`BEGV`; an explicit one is side-checked then clipped | `search.c:1006` |
| `erase-buffer` | widens, then deletes `BEG..Z` | `buffer.c:2472` |
| `buffer-size` | `Z - BEG` - the whole text | `editfns.c` |
| `buffer-string` | the accessible portion | `editfns.c` |
| `set-marker` / `set_marker_restricted` | clip to `BEG`/`Z` and to `BEGV`/`ZV` | `marker.c:564` |

`buffer-substring` was the one still missing: ours had no
`validate_region`, so a range reaching outside a narrowing silently read
past it where Emacs signals. Measured: in a buffer narrowed to 3..5,
`(buffer-substring 1 12)` is "Args out of range" and `(char-after 1)` is
nil.

`validate_region` itself is `buffer.scm`'s and is shared now - the first
version of this pass wrote a second copy in `editfns.scm`, which is the
duplicate `current_column_1` lesson all over again.

## What is not carried

* **Labeled restrictions** (`with-restriction`, `without-restriction`,
  `narrow-to-region`'s label argument): they need a stack of labeled
  marker pairs per buffer.
* **`narrowing-locked`**: the buffer slot a mode sets to forbid narrowing;
  nothing here sets one.

`clip_changed` - the C's "the restriction moved, so the window start and
the recorded column mean nothing" - is `set-windows-or-buffers-changed!`
from `dispnew.scm`, the flag the renderer already reads.

# What narrowing now reaches that it did not before (2026-11-17)

Chris: "are there areas of the code that should use narrowing but don't
because it wasn't available before?" There are, and the tree says so
itself - a dozen comments read "there is no narrowing here". This is the
audit, what was corrected, and what is left.

## The C each of these was taken from

* **`search_command`'s bound rule** (`search.c:1006`), which every search
  entry point shares: a nil BOUND is `ZV` forward and `BEGV` backward; an
  explicit one is refused with "Invalid search bound (wrong side of
  point)" when it is on the wrong side of point, and then *clipped* to
  `[BEGV, ZV]`. The default bound had always been the whole buffer end;
  it is the accessible end now, which is what a search inside a
  `save-restriction` must see. (`%re-search` had the wrong-side check and
  nothing else; `search-forward`/`search-backward` had neither.)
* **`indent-according-to-mode`** (`indent.el`): the whole body is inside
  `(save-restriction (unless inhibit-widen (widen)) ...)`, so indenting a
  line in a narrowed buffer sees the text outside it. Ours had a comment
  saying the widen was not needed.
* **`line-number-at-pos`** (`fns.c`): with ABSOLUTE the count starts at
  `BEG` and POS is taken as it stands; without it POS is clipped to
  `[BEGV, ZV]` and the count starts at `BEGV`. The port accepted ABSOLUTE
  and ignored it.
* **`set_marker_internal`** (`marker.c:564`): the clip is
  `(restricted ? BUF_BEGV : BUF_BEG)` .. `(restricted ? BUF_ZV : BUF_Z)`,
  which is exactly `set_marker_restricted`'s flag.
* **`goto-line`** (`simple.el:1690`): the move is made in a widened
  buffer, the widening is undone unless `widen-automatically`, and a
  position outside what was visible widens for good.
* **`%n`** (`xdisp.c:29737`): `" Narrow"` when BEGV/ZV differ from BEG/Z.
* **`beginning-of-defun-raw`** (`lisp.el:465`): the scanner's branch runs
  inside `(save-restriction (widen))`, with `floor`/`ceiling` read from
  `point-min`/`point-max` *before* the widen and used to clamp the answer
  back into the restriction.
* **`looking-back`'s GREEDY** (`subr.el:5929`): the C extends the match
  backwards under `(save-restriction (narrow-to-region (point-min)
  start))` while the text still matches `\(?:REGEXP\)\''. This engine
  refuses `\=` and `\'' (`%emacs-ere`), so both halves are the same walk
  the other way up - try every start from point backwards, keep the match
  that ends at point, and GREEDY keeps the *furthest* one instead of the
  nearest. Two things fell out of porting it: the match data is now left
  at buffer positions (`%set-search-regs`), which is what `font-lock`
  reads from it, and a nil REGEXP is an *empty* one, because the C's
  `concat` drops nil - `(looking-back nil)` is t.

Also new, both because the above need them: `buffer-narrowed-p`
(`subr.el:4566`, `(/= (- (point-max) (point-min)) (buffer-size))`, placed
in `editfns.scm` because `subr.scm` is below it) and `widen-automatically`
(`simple.el:7691`, a plain variable - nothing `let`-binds it).

## Found, and still open

Each of these said in its own comment that it was waiting for narrowing.
The audit's verdict, one by one (2026-11-17):

* **`scheme-syntax-propertize-sexp-comment`** - ported: the C narrows to
  END around `forward-sexp` so that a sexp running past END is a
  `scan-error`, and that is what the code does now.
* **`up-list-default-function`**'s `no-syntax-crossing` arm - ported: the
  scan is restricted to the string or comment point is in. Measured
  against Emacs 31.1 on four cases (inside a string, an ordinary list,
  after a string, inside a comment): identical answers.
* **`dired-readin`**'s `widen` - ported.
* **`fill.el`** itself - ported (see the section below).
* **`elisp--preceding-sexp`, `lisp-comment-indent`,
  `lisp--el-funcall-position-p`** - **not narrowing issues after all**:
  none of the three narrows in Emacs either. The note that named them was
  a guess that came with the audit, and the guesses were not all right;
  this is the correction.
* **`simple.el`'s `count-lines`** - still not ported. It is a different
  function from the `xdisp.c` helper this tree has under that name (which
  Emacs calls `count_lines` and which has no Lisp name - the tree should
  probably spell it `%count-lines`), its default branch is
  `line-number-at-pos`, and the two branches this tree could not run are
  `selective-display` and `ignore-invisible-lines`. Nothing calls it:
  `count-lines-region` is not ported either. It is listed rather than
  done because it is the last item and nothing waits on it.
* **`eval-region`** reads the region as a string where the C narrows and
  reads from point. The docstring's "This function does not move point"
  comes free that way and the narrowing is not observable; left as it
  is.
* **`replace-string-in-region` / `replace-regexp-in-region`**
  (`subr.el:4961`, `:4990`) are not ported. They are small, but the
  first calls `replace-region-contents`, whose engine is the C's
  `replace-buffer-contents` - a diff-based replacement in `insdel.c`
  that is not ported. Porting them on `replace-match` instead would be
  the "paper over a missing primitive" this tree forbids, so they wait
  for that function.

# Window states: the size registers, and the pixel/total split
(2026-11-16)

`schemacs/editor/window.scm` now carries the whole of Emacs's window-size
chapter - `window-min-size`, `window-sizable`, `window-resizable`,
`window-resize` and the `window--resize-*` engine that applies it - and
with it the state format `window-state-get`/`window-state-put`, which a
tab now stores (`tab-bar--tab`'s `ws`). The C each was taken from is
named at the function. What follows is what was done differently, and
why.

## The registers are kept beside the window, not in it

`struct window` has `new_pixel`, `new_total`, `new_normal`,
`normal_lines`, `normal_cols`, `dedicated`, `combination_limit` and the
two margin widths. None of them is a field of `<window>` here; they live
in one vector per window in `*window-slots*` (`frame.scm`), a weak-key
hash table, exactly as `w->cursor_off_p` and the blink timers already do.

The reason is the one `frame.scm`'s own note gives: `<window>` is built
in five places and read by forty libraries, and a field added to it is a
change to every one of them - the AGENTS note about a stale `.go` reading
the wrong slots is what happens when that goes wrong. The registers are
also transient: `window-resize` sets them, `window-resize-apply` installs
them, and nothing else reads them.

`combination_limit` and `dedicated` are the exception in principle -
they are persistent, user-visible state - but they are here for the same
reason, and `window-dedicated-p`/`set-window-dedicated-p` are their only
readers.

## Pixel sizes are derived, not stored

The C stores `w->pixel_width` *and* `w->total_cols` and keeps them in
step by dividing by the frame's character size. Every rectangle in this
tree is already in canonical units (rows and columns), so:

    (window-pixel-height w)  = (* (window-height w) (frame-char-height f))
    (window-pixel-width w)   = (* (window-width w)  (frame-char-width f))
    (window-pixel-left w)    = (* (window-left w)   (frame-char-width f))
    (window-pixel-top w)     = (* (window-top w)    (frame-char-height f))

which is exact on a terminal (character size 1) and exact on Gtk, where
a cell is a whole number of pixels because that is the unit the renderer
draws in. `window-resize-apply` divides back, as `window_resize_apply`
does.

The one place the difference shows is a `window-state-get` from a Gtk
frame put back into a frame whose font size changed: Emacs's state
carries the pixel size and restores it exactly, and this tree's does too
- the state's `pixel-width` is the same number Emacs would record.

## `window-normal-size` is derived from the geometry

`w->normal_lines` and `w->normal_cols` exist so that a window shrunk to
its minimum remembers its share of the parent when the frame grows
again. This tree computes the share from the current rectangles
(`window-normal-size`), which is the same number whenever the window is
at its normal size - and a state is recorded and restored at a normal
size. The difference appears only after a shrink-then-grow cycle within
one session, where Emacs would restore the pre-shrink proportions and
this tree the shrunken ones. `resize-frame-windows!` scales rectangles
proportionally, so in practice they agree.

## `window-wants-mode-line` does not read `mode-line-format`

The C's test is a leaf, not the mini window, with a `mode-line-format`
that is neither nil nor `none` - the buffer's, unless the window
parameter overrides it. The buffer's variables are `buffer.scm`'s and
`frame.scm` is below it, so the test here is "a live window that is not
the minibuffer window", which is what the renderer draws. A window whose
`mode-line-format` a user set to nil still gets a mode line here.

## No fringes, margins or scroll bars are drawn

`window-fringes` and `window-scroll-bars` answer what Emacs answers on a
*terminal* (`(0 0 nil nil)` and `(nil 0 t nil 0 t nil)`) on both front
ends, and their setters are no-ops - which is what `set_window_fringes`
does on a tty ("Do nothing on a tty"). `window-margins` and
`set-window-margins` *do* store the widths, as Emacs on a tty does
(measured: `(set-window-margins nil 5 3)` reads back `(5 . 3)`), but
nothing draws them. `window-vscroll` is 0 and its setter answers 0, as on
a tty.

`window-mode-line-height`, `window-tab-line-height` and the rest answer
**rows** where the C answers pixels; `window--min-size-1` multiplies by
the character height once, where the C's arithmetic is already in pixels.

## `window-combination-limit` and `window-combination-resize` are parameters

**Superseded 2026-11-16.** This section used to say that
`window-combination-limit` was a variable this tree did not have,
because `split-window` always made a new parent and the variable would
have been dead. That was true of the old `split-window`; both are
ported now (see "Splitting a window into an existing combination"
below), and both variables are here - as parameters, because Emacs
`let`-binds them around code that reads them several frames down
(`window--state-put-1` binds `window-combination-limit`,
`delete-window` binds `window-combination-resize`), and a Scheme `let`
would be invisible to those callees. `window-combination-resize` was a
plain variable here until this change; its name carries the asterisks
now, and `window-absorb!` - the function the old `delete-window` used -
is gone with it.

## `window-deletable-p` is reduced

The tab branch (`'tab`), the atomic-window branch and
`window-deletable-functions` are not carried - there are no atomic
windows here, this tree's tab bar does not close windows a tab at a
time, and nothing runs that hook. What is left is Emacs's own shape: a
leaf is deletable, the root is `frame` only while another frame exists,
and a minibuffer window is never deletable.

`frame-deletable-p` is reduced to "more than one frame is live", which is
Emacs's first condition; the minibuffer-ownership and child-frame
conditions have no counterpart here.

## `window--check` does nothing

It checks side and atomic windows on the frame; this tree has neither, so
it answers `#t`. It is ported as the end of `window-state-put` because
that is where Emacs calls it.

## `get-buffer` took a name and answered nil for a buffer

`(get-buffer BUFFER-OR-NAME)`'s docstring has two sentences, and the
port implemented the first: "If BUFFER-OR-NAME is a string and a live
buffer with that name exists, return that buffer. **If BUFFER-OR-NAME is
a buffer instead of a string, return it as is, even if it has been
killed.**" The second is the C's `(BUFFERP (buffer-or-name) ?
buffer-or-name : ...)` arm (`buffer.c:5043`), and its absence was
invisible until a window state named its buffers as *objects* -
`window-state-get` does that whenever WRITABLE is nil, which is every
state a tab records - and `window-state-put` found nothing, took its
"the buffer was killed" branch for every window, and restored the
layout with the wrong buffer in it. Fixed in `buffer.scm`.

## The side windows and the minibuffer in `window-state-put`

`window-state-put`'s "not live" path finds the first live window of the
subtree and makes a fresh window beside it, as the C does. Its first
step in Emacs is `delete-other-windows-internal (window root)`; the tree
calls `delete-other-windows`, which does the same thing for a frame with
no side windows. `tab-bar-select-tab-internal`'s "select the mru window
if the minibuffer is selected" is not carried: there is no separate
minibuffer window to be selected here.

## Splitting a window into an existing combination

**Fixed 2026-11-16.** `split-window` used to make a new internal window
on *every* split, whatever the window's parent was. That is not what the
C does: `Fsplit_window_internal` (`window.c:5427`) computes

```c
  bool combination_limit
    = (EQ (Vwindow_combination_limit, Qt)
       || NILP (o->parent)
       || (horflag ? WINDOW_VERTICAL_COMBINATION_P (XWINDOW (o->parent))
                   : WINDOW_HORIZONTAL_COMBINATION_P (XWINDOW (o->parent))));
```

and when it is false the new window becomes OLD's **next sibling** in
the combination OLD is already in. So three `C-x 2`s on the same window
make *one* combination of three in Emacs, and a chain of three nested
pairs here - the same picture on the screen, a different tree. It
mattered as soon as anything read the tree: `window-child-count`,
`other-window`'s ordering, `window-state-get`'s shape, and
`tab-bar-split-tab`'s ARG, which counts children.

The port keeps the rule and its two escape hatches: `t` in
`*window-combination-limit*`, a window with no parent, and an
ortho-combined split (splitting a window vertically inside a horizontal
combination) each still make a new parent. The C tests only for `Qt`;
`nil` and the default `window-size` behave the same way there, and they
do here.

`window--state-put-1`'s binding of `window-combination-limit` is ported
with it (`window.el:6552`, Bug#50867/Bug#64405): without it a restored
state's nested combinations would be flattened into their parent by the
sibling rule, and the shape read back would not be the shape saved.

**An internal window's children give up the new window's share in
proportion**, as `split-window-internal`'s closing
`window_resize_apply (p, horflag)` and the wrapper's
`window--resize-this-window window (- new-pixel-size)` do in the C. They
did not until 2026-11-16, and it went unseen while the only internal
splits were `window-state-put`'s (which resizes everything immediately
after). The completion list splits the frame's *root*, and with the
delete on the resize engine the two rules disagreed: a 12/11 frame came
back 18/5 after the list was closed (`pty-check.py`'s
`completion-resize`).

**`split-main-window-below` is a thin `split-window` call now**, with
the size negated: Emacs's positive SIZE is the rows the *upper* window
keeps, and this helper's SIZE is the new window's. It exists because
this tree's `display-buffer` has no `display-buffer-at-bottom` to call;
its old body, which shrank only the child touching the bottom edge,
went with the flat-list model.

**Departure**: `split-window` here takes the new window's buffer, point
and start from a *reference window* - OLD when OLD is live, the frame's
selected window when OLD is internal, which is the C's own rule
(`window.c:5443`). The C's `set_window_buffer` would put the new
window's start at `b->last_window_start`, which this tree does not
store (see the window-start section above), so the new window starts
where the reference window starts.

## `delete-window` gives the space to one sibling

**Fixed 2026-11-16.** The old `delete-window` gave the deleted window's
space to *every* sibling in turn - right while every combination had two
children, wrong the moment a combination of three can exist (which the
split rule above makes possible): two siblings would each grow by the
deleted window's size and the frame would grow with them.

It is `window.el:4318`'s body now, over the resize engine that was
already ported: `window--resize-reset`, `window--resize-this-window`
on the previous sibling (or the next when there is none), and
`window--pixel-to-total`. The C's `delete-window-internal`
(`window.c:5691`) is ported under its own name, with `recombine_windows`
(`window.c:2612`) under it: a delete that leaves a combination of one
kind nested in another of the same kind collapses it.

**Read the combination's axis before unlinking it**: a combination left
with one child has no axis to read off the rectangles -
`windows-stacked?` needs two children - and `window-left-child` calls a
one-child list horizontal. The C reads
`WINDOW_HORIZONTAL_COMBINATION_P (p)` before it touches the tree
(`window.c:5717`) for the same reason.

**Not carried**, each for want of what it reads: the `delete-window`
window parameter and `ignore-window-parameters` (no side windows), the
atomic-window handling, the "Attempt to delete main window of frame"
check (with no side windows the main window *is* the root, which the
parentless test already refuses), and `delete-window-choose-selected`
(there is no MRU list here; the frame's first window is chosen, as
`delete-window-internal`'s own fallback does).

## `combine-windows`, and the normal sizes it does not write

`combine-windows` (`window.c:5213`) is ported in full, including the
two-direction search for FIRST..LAST and "Cannot combine a window with
itself". Two departures of the representation: the C splices with four
`w->next`/`w->prev` pointer writes where a combination here is a list,
so the splice is one list rebuild; and the C ends with
`window_set_parent_and_normal_sizes` on the new parent and on its
parent, which this tree does not need - normal sizes are derived from
the rectangles (`window-normal-size`), and the rectangles are what the
function sets.

## `window-get-split-combination` is `window-x.el`'s, and only it

`schemacs/editor/window-x.scm` is new and mirrors
`lisp/window-x.el`. Only `window-get-split-combination` is carried: it
is what `tab-bar-split-tab` needs. Not carried from that file, with
what each waits for: `split-frame` and `merge-frames` (a `make-frame`
that can be handed a window configuration), `window-make-frame`, the
side-window placement functions and the atomic-window ones.

**It really does combine**: `window-get-split-combination` calls
`combine-windows`, which rewrites the frame's tree, so calling it twice
on one frame gives the second call the tree the first one made. That is
Emacs's behaviour too - the function exists to be followed by
`delete-window` - and it is why the test gives each call a frame of its
own.

## `tab-bar-split-tab`, `tab-bar-merge-tabs` and ARG

`tab-bar-split-tab` (`tab-bar.el:1978`) is ported as it stands,
including its three refusals and the `_` binding that selects the tab
being split. **ARG counts the main window's children**, so with the old
nested-pair trees "ARG 3 exceeds number of windows 1" was the answer for
a three-window tab; with the split rule fixed the count is Emacs's. The
part that moves is "the part which does not include TAB's selected
window" - `window-get-split-combination`'s rule - whichever side of the
pivot that is.

`tab-bar-merge-tabs` (`:2014`) binds `tab-bar-close-tab-select` to
`recent` and `tab-bar-closed-tabs` to nil around the close, so the tab
being merged is not recorded for `tab-bar-undo-close-tab` - the merge is
one operation, not a close followed by an insert.

`tab-bar-move-window-to-tab` is ported too; Emacs binds
`ignore-window-parameters` around its `delete-window`, which has nothing
to bind here (no window parameter stops a delete in this tree, there
being no side windows).

## `defalias` is `define-alias`, and it had to do more than `defalias`

**GNU Emacs's `defalias`** (`eval.c`) writes a function object into a
second symbol's function cell. One object, two names, and `M-x` finds
either because `M-x` looks a symbol up in the one obarray.

**A `define` is only half of that here.** `(define tab-new
tab-bar-new-tab)` makes the name callable and a key bound to it works -
key dispatch finds a command by its *procedure* (`command-record-of`),
not its name. But `M-x` resolves a name through `*command-table*`, an
alist of name string to command record that only `define-command` writes
to, so `M-x tab-new` answered "No match" while `M-x tab-bar-new-tab`
worked. `define-alias` (`command.scm`) does both: the `define`, and the filing
of the second *name* against the target's **own** record - which is what
keeps `this-command`, `called-interactively-p` and the docstring
identical through either name.

**That filing is not a separate mechanism.** It was `register-command-
alias!`, which named an object the table does not have: the table is one
thing, name to record, so a command and a second name for that command
are the same operation. There is one way in - `%file-command-name!
(name record)` - called by `register-command!` and by `define-alias`, and
a nil record files nothing, which is `defalias` of a non-command being a
non-command.

**Not carried**: `defalias`'s third argument, a DOCSTRING for the alias
name. Nothing here reads a docstring off a name -
`procedure-documentation` is the only reader - and an alias's
documentation is the target's.

**The alias block had three defects, all fixed 2026-11-16**: it invented
four names Emacs does not have (`tab-select-tab-by-name`,
`tab-close-by-name`, `tab-rename-by-name`, `tab-move-backward` - the
*commands* `tab-bar-close-tab-by-name` and `tab-bar-rename-tab-by-name`
are Emacs's, their short aliases are not), it was missing `tab-list`
(`:3197`, aliasing `tab-switcher`), and none of the names were in the
obarray or exported from the library. The block is now Emacs's list in
Emacs's order, `define-alias`'d, and exported.

## The `*` interactive code, and the seam it needs

`callint.c` peels five leading markers off an interactive specification
before it reads any code - `+`, `*`, `-`, `@`, `^` (`:362`) - and `*`
is "an error is signaled if the buffer is read-only" (`:98`). It is a
*check*, not an argument code, so it contributes nothing to the
argument list. `interactive-proc` in `command.scm` reads `*` and `^`
(the other three are `+`'s user extension error, `-`'s
semi-compatibility no-op and `@`'s window selection, none carried) and
strips one marker per recursion, which is the C's loop.

**What remains of the string decides the entry's call shape**, not the
marker: `"*"` alone leaves the empty specification, whose entry is a
thunk, while `"*P"` leaves one that takes the prefix - and the command
loop calls either by the record's `uarg` flag, which any non-#f
specification sets.

**The check arrives through a seam.** `barf-if-buffer-read-only` is
`buffer.c`'s and lives in `(schemacs editor buffer)`, which cannot
import `(schemacs editor command)` (the command library is a leaf
everything above it uses). `command.scm` therefore declares
`*barf-if-buffer-read-only-function*` and `(schemacs editor keyboard)`
installs it as it loads - the same pattern
`*record-window-buffer-function*` and `*frame-creation-function*` take.
The check is read at *call* time, because the seam is installed when the
command loop's library loads and command entries are built when their
own library does.

Consequence to know: a library that defines a `*`-marked command and is
loaded **without** a command loop never checks. Nothing in the editor
runs that way, and the `command-tests` suite loads `keyboard` for
exactly that reason.

## `comment-indent` is a command, and `indent-for-comment` is its alias

`newcomment.el` has `(defun comment-indent (&optional continue) ...
(interactive "*"))` and `(defalias 'indent-for-comment #'comment-indent)`
(`:75`). Ported as neither was a command, so `M-x comment-indent` and
`M-x indent-for-comment` both answered "No match", and any key binding
worked only because dispatch finds a command by its procedure.

The C's `&optional` is a **rest parameter** here - `(define-command
(comment-indent . rest) ...)` - because the procedure is called with no
argument from `indent-for-comment` and from Lisp modes, and a Scheme
command with a required parameter could not be. The body reads
`(and (pair? rest) (car rest))`, which is the C's nil CONTINUE.
`indent-for-comment` is `(define-alias indent-for-comment
comment-indent)`, which is `defalias` in this tree.

## `interactive-proc` is a code loop now, and the region codes are in

`callint.c`'s `Fcall_interactively` reads a specification as a *sequence*
of code characters, each contributing no argument, one, or two (`r`).
This tree read the string as a *single* code - `string=? spec "p"` and
friends - so `"r\nP"` (`indent-region`, `indent.el:567`) could not be
written at all and every region command spelled its spec as an
expression: `(interactive (list (region-beginning) (region-end)))` in
five places.

It is the C's loop now (`%interactive-args`): `p`, `P`, `e`, `i`, `r`,
`R`, with `\n` and `-` as separators that contribute nothing, and the
leading markers (`*`, `^`, `-`, `+`, `@`) peeled before any code is read
(`:362`) - `*` runs the read-only check, `+` errors, `^` and `@` are
recognised and do nothing (no shift-select, no mouse-event window). A
code that is not read is an error naming the *character*, where the old
code named the whole string.

**Codes not carried, and why**: `b`/`B` (buffer name), `f`/`F`/`G`
(file), `D` (directory), `n`/`N` (number), `s`/`S`/`M` (string), `c`
(character), `k`/`K`/`U` (key sequence), `x`/`X` (a Lisp expression),
`z`/`Z` (a coding system) and `a`/`C`/`v` (a function, command or
variable name). Every one of them reads the minibuffer, which
`command.scm` is below. **There are 30 letters and no `l`** - an earlier
version of this paragraph listed one, which is an Emacs 30 memory and
not in the C: `callint.c`'s switch has those 30 `case` labels and one
`+` beside them, and nothing else.

**The seams the region codes need** are `*check-mark-function*`,
`*region-beginning-function*`, `*region-end-function*` and
`*use-region-p-function*`, installed by `simple.scm` - it is the library
that has all four, and the editor always loads it.

**`check_mark`'s body is in `simple.scm`**, not `command.scm`, though it
is `callint.c:156`'s: the state it reads (`mark-marker`,
`transient-mark-mode`, `mark-active`) is there and above. **Its order is
the C's and not `region_limit`'s**: it asks whether the mark is *set*
before whether it is *active*, the other way round from
`region-beginning` (`editfns.c:232`), so `M-x kill-region` in Transient
Mark mode with no mark set says "The mark is not set now, so there is no
region" rather than "The mark is not active now". `command-tests` pins
both orders.

**A test was pinning the old message.** `tty-editor-tests.scm` expected
`C-w` on a fresh buffer to answer "The mark is not active now" - which
was what the expression spec produced, and not what Emacs says. Measured
with `emacs -Q --batch`, both with and without `transient-mark-mode`:
"The mark is not set now, so there is no region". The expectation is
corrected. This is the file's own warning about a passing test pinning a
departure, caught by porting the primitive rather than the symptom.

**The `e` code does not repeat.** The C walks to the next *parameterized*
event for a second `e`; this tree's `last-command-event` is one value,
so a repeated `e` answers the same one.

**Converted to their Emacs specs**: `kill-region`, `upcase-region`,
`downcase-region` (`"r"`), `eval-region` (`"r"`, with a rest parameter
for the PRINTFLAG the C's two-argument interactive form leaves nil), and
`indent-region` (`"r\nP"`).

## The `d` and `m` interactive codes, and the marker `d` hands you

`callint.c:502`'s `d` - "Value of point. Does not do I/O" - and `:623`'s
`m` - "Value of mark" - are the last two codes that read nothing, so
they were the two that could be ported without a minibuffer seam. Both
hand the command a **marker**, not a position, and that is the part
worth getting right: a command may keep it.

`m` is exact. The C is `check_mark (false)` and then
`BVAR (current_buffer, mark)` - the buffer's **own** mark marker, not a
copy - so moving the argument moves the mark. `command-tests` pins the
identity with `eq?` against `mark-marker`. The check is
`check_mark`'s `false` arm, so the message is "The mark is not set now",
*not* the region's "...so there is no region" - the same two-question
order the `r` code's note is about.

**`d` departs in one field, and it is `marker-buffer`.** The C's is

```c
set_marker_both (point_marker, Qnil, PT, PT_BYTE);
args[i] = point_marker;
```

and `point_marker` is `callint.c`'s **static**, made once with
`Fmake_marker` and repositioned on the next call. `Fmake_marker` makes a
marker with no buffer, and `set_marker_both` with `Qnil` does not give
it one - so the C's `d` argument is a *bufferless* marker, shared
between every `d` in every specification, and it would be **frozen**:
a bufferless marker does not move with edits. `point-marker`
(`editfns.c:198`) is `build_marker (current_buffer, PT, PT_BYTE)`.

So the argument here answers the same number at the same moment, is
attached to the buffer, and moves with the buffer's text. Three
answers differ: `marker-buffer` (a buffer rather than nil), whether a
later edit moves it, and whether two `d` codes in one specification
give the same object. The first is the one a command could read;
`callint.c`'s static is a convenience for the C, not a rule - no Emacs
command in `lisp/` asks `marker-buffer` of a `d` argument.

**The seam shape, again.** `command.scm` is a leaf: `editfns.c`'s
`point-marker` and `mark-marker` are both in `(schemacs editor
editfns)`, which imports this library. They arrive as
`*point-marker-function*` and `*mark-marker-function*`, installed at the
bottom of `editfns.scm` beside the functions, which is `simple.scm`'s
arrangement for the region seams.

**A missing install is an error here, not a silent `#f`.**
`%interactive-seam` reports "Interactive specification needs `point-marker',
which is not installed". The four region seams skip a missing install
because `#f` is a value they can mean; `d` has no such value, and a
silent nil would fail inside the command several frames away.

**The invalid-code message is the C's now**, with the C's padding:

```
Invalid control letter `q' (#o161, #x0071) in interactive calling string
```

where the tree said "Unsupported interactive specification character".
Measured on Emacs 31.1, which renders the two quotes as `‘’` on a
terminal (`text-quoting-style`); the C's format string, and this, have
`` ` `` and `'`. The two numbers are zero-padded by a local helper
rather than a `~3,'0o` directive because an error in this tree carries a
*template and irritants* and the receiver does the formatting - which is
what makes the message readable at the echo area and in `command-tests`
alike.

## A specification's prompts, and the five codes that read one

Every remaining interactive code is a minibuffer read, and all of them
are prompted. The prompt is not a separate argument: **each code owns
the text after it up to the next newline**, and that text *is* the
prompt -

```c
    char const *pnl = memchr (tem + 1, '\n', string_len - (tem + 1 - string));
    ptrdiff_t sz = pnl ? pnl - (tem + 1) : string_end - (tem + 1);
    visargs[1] = make_string (tem + 1, sz);
    callint_message = Fformat_message (i - 1, visargs + 1);
```

(`callint.c:441`) - so `"sSearch: \nrRegion: "` gives `s` the prompt
"Search: " and `r` the prompt "Region: ". This tree had no such
splitting: `interactive-proc` walked single characters and treated `\n`
as a separator that contributed nothing, so the text of a specification
was unreachable and every prompted command spelled its spec as an
expression.

`%interactive-segments` is that walk now, and it answers a list of
(CODE . PROMPT). `\n` stops being a code of its own - the segment walk
consumes it - which is the same behaviour seen from the other side.

**`-` in the middle of a specification is an error, and always was.**
The peel loop at `:362` handles the *starting* characters only - "Ignore
this for semi-compatibility with Lucid" is `else if (*string == '-')`
with no `continue` past the next character - and the switch has no
`case '-'`, so `"p-s"` is "Invalid control letter `-' ...". The loop
this port had skipped `-` anywhere in the string; it no longer does.

### The prompt is formatted with the arguments so far

`Fformat_message (i - 1, visargs + 1)`: the prompt goes through `format`
with the arguments already read, which is how `"sQuery replace %s with:
"` shows what the `s` before it read. That needs `format-message`, which
is `editfns.c`'s and above this library, so it is the seam
`*format-message-function*` - a third seam for the codes, installed by
`editfns.scm` beside `point-marker`.

`visargs` is the C's second array: the *visible* form of each argument,
which is what a later prompt can see. The port carries it as a second
accumulator, with the C's closing "if visargs[i] is nil and args[i] is
a string, use it" applied as each argument is pushed. `n` sets it
explicitly with `Fnumber_to_string`; everything else either is a string
already or contributes nothing.

**Measured, not assumed**: a `%` in the *first* code's prompt is
"Not enough arguments for format string" in Emacs 31.1 - the C formats
unconditionally, not only when there are arguments - so this formats
unconditionally too.

### The five codes

| code | what it reads | note |
|---|---|---|
| `s` | `read-string` | |
| `M` | `read-string` | `INHERIT-INPUT-METHOD` is not carried; `read-string`'s own docstring already says so - there is no input method here |
| `S` | `read-string`, then interned | the *string* is the visible form, not the symbol |
| `n` | `read-number` | visible form is `number->string`, the C's `Fnumber_to_string` |
| `N` | the prefix when there is one, else `read-number` | the C's `goto have_prefix_arg`, so with a prefix it is exactly `p` |

**Two departures, both small and both named rather than hidden:**

1. **`%s` of an argument that is not a string.** `visargs` holds Elisp
   nil for the codes that contribute no string, and `(format "%s" nil)`
   is `"nil"` in Emacs. This tree has no nil object here, so the entry
   is `#f` and `%s` prints `"#f"`. Reachable only from a spec like
   `"p\nsWidth (%s): "` with no prefix, and nothing in `lisp/` has one.
2. **`read-number`'s `read` of the typed string** is `string->number`,
   already recorded on that function.

**`*read-string-function*` and `*read-number-function*`** are installed
by `minibuffer.scm` as it loads. **A seam no library installs is an
error naming it**, so a specification that reads without a minibuffer
says "Interactive specification needs `read-string', which is not
installed" rather than answering nil.

**`command-tests.scm` stubs both readers**, because what it tests is the
machinery - the prompt a code is given, the order the arguments arrive
in, and the formatting of a later prompt by an earlier answer - and
`tty-editor-tests.scm` asserts that a *real* editor has the *real* two,
which a stub cannot show.

**Nothing in the tree uses these codes yet.** Every prompted command
here spells its spec as an expression, and so does Emacs for the ones
this tree has (`find-file`, `switch-to-buffer`, `kill-buffer`,
`query-replace`). They are carried because `callint.c` has them and
because a spec quoted from Emacs's own source - `(interactive "sSearch:
")` - is now readable as written.

## The file codes, and the rule a seam's name follows

`f` (existing file), `F` (possibly nonexistent), `G` (the same, initial
"") and `D` (a directory) - `callint.c:509`, `:514`, `:518`, `:522`.
All four are the one C helper:

```c
static Lisp_Object
read_file_name (Lisp_Object default_filename, Lisp_Object mustmatch,
                Lisp_Object initial, Lisp_Object predicate)
{
  return calln (Qread_file_name,
                callint_message, Qnil, default_filename,
                mustmatch, initial, predicate);
}
```

### The naming rule, settled here

A seam takes the plain `<function>-function` name **unless Emacs has a
*variable* of that name** - then it is `interactive-`-prefixed. So
`*read-string-function*` and `*read-number-function*` keep the plain
spelling (nothing in Emacs is called either), while these two are
`*interactive-read-file-name-function*` and
`*interactive-read-directory-name-function*`, because
`read-file-name-function` is a defcustom in `minibuffer.el` and a seam
that squatted on the name would collide with the day it is ported.
`*read-buffer-function*` is the other case waiting: `read-buffer-function`
is `minibuf.c:2544` and is *already* in this tree, in `minibuf.scm`.

### Three codes are one seam, and the fourth is not

`f`, `F` and `G` differ only in the *constants* they pass - `Qlambda`,
`Qnil` and `""` - so one seam `(prompt must-match initial)` serves all
three and the C's constants are written at the call sites in
`command.scm`, where the switch is.

`D` passes `BVAR (current_buffer, directory)` as DEFAULT and
`Qfile_directory_p` as PREDICATE. Neither is nameable from
`command.scm` - one is buffer state, the other is a function in
`files.scm` - so the *whole call* is the seam and it takes the prompt
alone.

**MUSTMATCH is the symbol `lambda`, not `t`.** The C passes `Qlambda`,
and the difference is observable: `completing-read` binds
`minibuffer-completion-confirm` to anything that is not `t`
(`minibuffer.el:5243`), so `t` means "must match, no question" and
`lambda` means "must match, and the confirm machinery sees `lambda`".
The seam is handed `'lambda` for `f` and `D`, and `#f` for `F` and `G`.

**`D`'s PREDICATE was a departure and is closed (2026-11-19).** This
note used to say `read-file-name` took no predicate, so a `D` prompt
completed *files* as well as directories and accepted a file name. The
graphical file dialog work gave `read-file-name` its sixth argument,
with the completion table filtering each candidate by the predicate as
`completion-file-name-table` does (`minibuffer.el:3730-3760`), and the
seam now passes `file-directory-p` - so a `D` prompt completes only
directories, refuses a file name as Emacs does, and asks the dialog for
a folder chooser rather than a file chooser.

Both seams are installed by `files.scm` as it loads, beside
`read-file-name` itself.

`command-tests.scm` 45 -> 51, with `files.scm` **not** in that suite's
graph: the stubs record the whole call, which is what pins the six
constants per code. `tty-editor-tests.scm` asserts that a real editor
has the real two.

## The buffer codes, and MUSTMATCH the third way

`b` ("Name of existing buffer", `callint.c:468`) and `B` ("Name of
buffer, possibly nonexistent", `:475`). Both reach `Fread_buffer`
(`minibuf.c:1522`), which is already here as `read-buffer`; what is not
nameable from a leaf library is the **default**.

```c
/* b */
args[i] = Fcurrent_buffer ();
if (BASE_EQ (selected_window, minibuf_window))
    args[i] = Fother_buffer (args[i], Qnil, Qnil);
args[i] = Fread_buffer (callint_message, args[i], Qt, Qnil);

/* B */
args[i] = Fread_buffer (callint_message,
                        Fother_buffer (Fcurrent_buffer (), Qnil, Qnil),
                        Qnil, Qnil);
```

`b`'s default is the current buffer *unless the selected window is the
minibuffer window*, in which case it is `other-buffer` of it - and that
condition is what makes prompting from the minibuffer default to the
buffer you came from. `B`'s is `other-buffer` unconditionally, which is
why `C-x b` starts on the buffer you were in before.

Both are buffer state, so, as with `D`, **the whole call is the seam**
and it takes the prompt alone:

| seam | installed as |
|---|---|
| `*interactive-read-existing-buffer-function*` | `b`: the conditional default, MUSTMATCH `t` |
| `*interactive-read-buffer-function*` | `B`: `other-buffer`, MUSTMATCH `#f` |

Both are installed by `minibuffer.scm`, beside `read-buffer`, and they
take the `interactive-` prefix under the rule the file codes set -
`read-buffer-function` is `minibuf.c:2544` and is *already* in this
tree, as `*read-buffer-function*` in `minibuf.scm`, so the plain name
was not free.

**MUSTMATCH now has three spellings in these codes, and all three are
the C's**:

| code | MUSTMATCH | what it means here |
|---|---|---|
| `f` | `Qlambda` | the *symbol*, which `completing-read` passes into `minibuffer-completion-confirm` |
| `b` | `Qt` | `t` - must match, no confirmation question |
| `F`, `G`, `B` | `Qnil` | a name that exists nowhere yet is accepted |

They are not interchangeable and the difference is reachable: `C-x b` is
`B` (nil), `b` refuses a name with no buffer behind it, and `f` is the
one that reaches the confirm machinery.

`command-tests.scm` 51 -> 54 (`b` and `B` read with the prompt alone, and
the command receives what was read), and `tty-editor-tests.scm` asserts
that a real editor has both seams installed.

## The coding-system codes, and a seam whose library is not always loaded

`z` ("Coding-system symbol or nil", `callint.c:724`) and `Z`
("Coding-system symbol, or ignore the argument if no prefix", `:709`).

`z` always reads: `Fread_coding_system (callint_message, Qnil)`, which is
already here as `read-coding-system` in `mule-cmds.scm`.

`Z` **reads only when there is a prefix** - the C's

```c
      if (NILP (prefix_arg))
	{
	  /* args[i] = Qnil; */
	  varies[i] = -1;
	}
      else
	args[i] = Fread_non_nil_coding_system (callint_message);
```

so with no prefix the minibuffer is not touched at all and the argument
is nil. That needed **`read-non-nil-coding-system`** (`coding.c:8646`),
which did not exist here:

```c
  do
    {
      val = Fcompleting_read (prompt, Vcoding_system_alist, Qnil,
                              Qt, Qnil, Qcoding_system_history, Qnil, Qnil);
    }
  while (SCHARS (val) == 0);
  return (Fintern (val, Qnil));
```

The loop is the whole difference from `read-coding-system`: RET on an
empty minibuffer asks again rather than answering nil. It is ported into
`mule-cmds.scm` beside `read-coding-system`, for that one's reason - it
prompts, and `coding.scm` is below the minibuffer.

**The visible form is the string read.** The C sets `visargs[i] =
last_minibuf_string`; here the reader answers a *symbol*, so the visible
form is `(symbol->string answer)`, and nil stays nil.

### A seam is only installed when its library loads

`read-coding-system` is `mule-cmds.scm`'s, so that is where the two seams
are installed - and `mule-cmds` is **not** a library the editor core
loads: it is imported by the two front ends (`ui/tty/tty-main.scm`,
`ui/gtk/gtk-main.scm`), which is what a running editor is.

That is a departure the other seams do not have. `*barf-if-buffer-read-
only-function*` (keyboard), the four region seams (simple) and the two
marker seams (editfns) are installed by libraries every editor loads, so
they are always there; these two are there once the front end has loaded,
which it does before any key is read. A `z` specification evaluated in a
session that has loaded neither errors "Interactive specification needs
`read-coding-system', which is not installed" - which is the honest
report, and better than silently answering nil.

**This was found by an assertion, and the assertion was in the wrong
suite.** The first version added it to `tty-editor-tests.scm`, which
fails - because that suite is not a front end and never imports
`mule-cmds`. It is in `mule-cmds-tests.scm` now, which is the suite that
loads this library; `command-tests.scm` stubs both seams, because what it
tests is the machinery.

`command-tests.scm` 54 -> 60: `z` reads, `Z` answers nil and calls no
reader without a prefix, and both read with a prefix.

## The command, variable and expression codes; and where the obarray went

`C` (a command, by name), `v` (a custom variable's name), `x` (a form,
unevaluated) and `X` (a form, evaluated). The first two are `minibuf.c`
DEFUNs that had no counterpart here, so each needed its function ported
first.

**`C` -> `read-command`** (`minibuf.c:1457`). The C completes over
`Vobarray` with `Qcommandp` as the predicate and `Qt` as MUSTMATCH, then
interns. **This tree has no obarray, but it has something better for this
one case**: `command-completion-table` is the command table asked the
completion-table way, and every name in it *is* a command - so the
predicate the C passes has nothing left to reject. `read-command` lives
in `minibuffer.scm` because it prompts.

**`v` -> `read-variable`** (`minibuf.c:1496`), and this one is the
honest obarray problem. It completes over `Vobarray` with
`Qcustom_variable_p`. There is no obarray here to filter, and
`custom-variable-p` (`custom.scm`) only answers *about a symbol you
already have* - it cannot enumerate. So `custom.scm` gained a
**registry**:

```scheme
(define custom-variable-names '())
```

which `custom-declare-variable` pushes onto as it runs (a plain variable
with no stars: it is a process-global registry, not something anything
`let`-binds). That list is what `read-variable` completes over, with
`custom-variable-p` still the predicate - so the answers are the same as
the C's, arrived at from a list rather than a hash table.
`custom-variable-history` came with it.

**`x` -> `read-minibuffer`** (`simple.el`) is
`read-from-minibuffer (prompt, initial, minibuffer-local-map, t,
minibuffer-history)` - where that fourth argument means "read it for
me". **`read-from-minibuffer`'s READ argument is not carried here**, so
the string is read afterwards on a string port. The reader is Scheme's,
which is the departure `eval-expression` already carries.

**`X` -> `eval-minibuffer`** (`simple.el:1999`), whose body is
`(eval (read--expression prompt initial-contents))`. The environment is
`%eval-expression-environment` - the user environment, where the names a
user types are bound, which is `eval-expression`'s for the same reason.

**One departure they share**: `x` and `X` answer the *form*, where the
C's `visargs[i]` is `last_minibuf_string` - the text that was typed. So a
later prompt's `%s` shows nil where Emacs would show the expression. It
would be reachable only from a spec like `"x\nsValue of %s: "`.

All four seams are installed by `minibuffer.scm` as it loads, beside the
functions - which is the library every front end has loaded before a key
is read.

`command-tests.scm` 60 -> 66 and `tty-editor-tests.scm`'s installation
group covers all four.

## The `c` code, and a name Guile already had

`c` ("Character", `callint.c:482`) needed `read-char` (`keyboard.c:11240`),
which did not exist.

The C is

```c
args[i] = Fread_char (callint_message, Qnil, Qnil);
message1_nolog (0);
if (! CHARACTERP (args[i]))
    error ("Non-character input-event");
visargs[i] = Fchar_to_string (args[i]);
```

and `Fread_char` is `read_filtered_event (1, 1, 1, INHERIT, SECONDS)`
then `!FIXNUMP (val) ? Qnil : char_resolve_modifier_mask (XFIXNUM (val))`.

**`read-char` is named `read-char-event` here, and the compiler is why:**

```
warning: non-idempotent binding for `read-char`.  When first loaded,
value for `read-char` comes from imported binding, but later module-local
definition overrides it; any module reload would capture module-local
binding rather than import.
```

`read-char` is **Guile's**: it reads a character from a *port*, and
`coding.scm`, `theme.scm` and two test files all use it that way.
Defining Emacs's would shadow that inside `keyboard.scm` and, exporting
it, over the core binding for every importer. This is the same collision
that took `insert-newline`'s name from Emacs's `newline`. The seam is
`*read-char-event-function*` to match.

**`char_resolve_modifier_mask` is not carried, because this tree's events
never hold a modifier mask.** `read-key-event` folds them - its own
docstring says so, and calls it the one thing a reader must do so nothing
above it asks where a key came from - so `C-s` arrives as 19, not as `s`
with a control bit. What is left of `read_filtered_event`'s three flags
is the type test: there are no switch-frame events to defer, and
`ascii_required`/`error_nonascii` are about the same folding.

**`message1_nolog (0)`** is the echo-area clear straight after the read,
which the C does so that the prompt does not stay up while the command
runs. It is `*message-clear-function*`, installed by `editfns.scm` beside
`message-clear` - which does not log, as `message1_nolog` does not.

**"Non-character input-event"** is `callint.c`'s own error and is raised
in `command.scm`, not in the reader: the C's `Fread_char` answers nil for
a function key and the *caller* complains. The reader here answers `#f`
for the same reason.

`command-tests.scm` 66 -> 69: `c` reads a character code with its prompt,
and a reader that answers no character is the C's error.

## The key-sequence codes, and the thousand lines that were not needed

`k` ("Key sequence", `callint.c:531`), `K` ("Key sequence to be
defined", `:562`) and `U` ("Up event from last k or K", `:593`).

`k` and `K` reach `Fread_key_sequence` / `Fread_key_sequence_vector`
(`keyboard.c:12501`, `:12562`), and the real work is
**`read_key_sequence` (`keyboard.c:11441`-`:12444`)** - one function of
about a thousand lines. Sizing it before starting was the point: those
lines are *not* sequence assembly in the abstract, they are **the whole
input pipeline** - `input-decode-map` and `function-key-map` chains,
`key-translation-map`, the echo of the partial sequence, mouse prefixes,
switch-frame deferral, discarded input.

**This tree already has that pipeline**, spread across `read-key-event`
(which normalises the two displays' events and applies the decode maps),
`function-key-translate`, and the *modal lookup* the command loop runs
for a chord (`new-modal-lookup-state` / `modal-lookup-state-step!`). So
the port is the assembly only - read an event, step the lookup, go round
again while what was found is a prefix keymap:

```scheme
(modal-lookup-state-step!
 state event
 (lambda (full-path action) (%read-key-sequence-answer events vector?))   ; a command
 (lambda (full-path action) (loop))                                       ; a prefix
 (lambda (full-path) (%read-key-sequence-answer events vector?)))         ; nothing bound
```

`%read-key-sequence-answer` is the C's answer rule: a **string when every
event is a character, a vector otherwise**, and `K` forces the vector.
"Nothing bound" answers the sequence too, because an unbound key is still
a key sequence and it is the *caller* that reports it - Emacs's `k`
commands do.

**Three departures, and one of them is why `U` is empty:**

1. **The down-event/up-event discard is not carried.** Emacs reads the
   `mouse-1` that follows a `down-mouse-1` and throws it away, and saves
   it for `U`. Nothing here does, so **`U` answers nil always** - which is
   what Emacs answers unless a `k` read a sequence ending in a `down-`
   event. Measured: **no `"U` spec exists in all of `lisp/`**; the code
   exists for `k`/`K`'s own use.
2. **The partial sequence is not echoed** as it is typed (`C-x-` in the
   echo area).
3. **`k`'s visible form is nil.** The C puts
   `Fkey_description (args[i], Qnil)` in `visargs[i]`; `key-description`
   is `keymap.scm`'s and `command.scm` is below it. Reachable only from a
   `%s` in a *later* prompt, and none of the 15 `k` specs in `lisp/` has
   one.

`command-tests.scm` 69 -> 72: `k` reads a sequence, `K` one as a vector,
`U` answers nil and reads nothing.

## The `a` code, and the obarray this tree never needed

`a` ("Symbol defined as a function", `callint.c:461`):

```c
visargs[i] = Fcompleting_read (callint_message, Vobarray, Qfboundp, Qt, ...);
args[i] = Fintern (visargs[i], Qnil);
```

Three things in one line, and this tree has none of them the same way.
`Vobarray` is one global collection filtered per reader; here there is no
such collection, and Chris pressed on whether one is needed at all. It is
not:

* **Completion over the obarray** is what enumeration exists for, and
  enumeration exists for **TAB**. A universal registry buys a keystroke
  saving, not a functionality.
* **Name to procedure** is `eval` (`(eval sym (%eval-expression-environment))`)
  - the direction that actually *does* anything.

So `a` is carried **without completion**: the name is typed, and the
C's `Qfboundp` predicate becomes a **resolution** - the name must exist
in the user environment and be a procedure. `symbol-function` on an
unbound name is an error in Emacs, so the check is a guard, not a nil
test.

The whole call is the seam (`*interactive-read-function-name-function*`),
installed by `minibuffer.scm` - the library that has both the reader and
the environment - for the reason `b` and `D` are whole-call seams.

**Two departures, and both are only reachable from an `a` spec:**

1. **No completion.** Emacs offers every `fboundp` symbol; here the name
   is typed in full.
2. **A name that resolves to a non-procedure is an error** ("X is not a
   function") rather than simply not being offered.

Both are cheap because **almost nothing uses `a`**: measured, it appears
in **5** interactive specs in all of `lisp/` - `elp` twice, `edebug`,
`timer`, `5x5` - and the first three are the host's job in a Scheme
editor (Guile's `statprof` profiles; Guile's traps and `,trace` step).
The code is carried because `callint.c` has it and a spec quoted from
Emacs now reads as written.

`command-tests.scm` 72 -> 74: `a` reads a function name as a symbol, from
its prompt.

**With this, all 30 letters of `callint.c`'s switch and its `+` are
carried.**

## `suppress-keymap`, and the dead `[remap ...]` path under it

`special-mode-map` is declared `:suppress t` (`simple.el:580`). Without
`suppress-keymap` the printing characters fell through to the global
self-insert in **every** special mode - dired, the Buffer Menu, the
backtrace buffer, `*Tabs*` - so typing `x` in `*Tabs*` inserted an `x`.

`suppress-keymap` is `subr.el:1316`'s, not `keymap.c`'s, and its body is
three statements:

```elisp
(define-key map [remap self-insert-command] #'undefined)
(or nodigits
    (progn (define-key map "-" #'negative-argument)
           ...digits -> #'digit-argument...))
```

**It is one remap, not ninety-five bindings.** Every key that would have
run `self-insert` runs `undefined` instead. Measured on Emacs 31.1 in a
`special-mode` buffer: `(key-binding (vector ?a))` is `undefined`, `?5` is
`digit-argument` and `?-` is `negative-argument` - the digits keep their
prefix-argument meaning, which the direct-binding version got wrong.

### The bug underneath: every `[remap ...]` binding was dead

The first attempt at this bound characters 32..126 directly and **the
battery failed one check**, which is what sent me back to the C. Doing it
properly needed `[remap ...]`, and that did not work:

```scheme
(define (command-remapping command)
  (and (symbol? command) ...))          ; the C's `if (!SYMBOLP (command))`
```

`remapped-command` passes `(command-name record)`, and `new-command` takes
that name from **`symbol->string`** - so it is a *string*, the guard
always failed, and **no `[remap ...]` binding in this tree had ever been
reachable**. `command-remapping` now interns a string first. That is the
`keyboard.h`-level fix; the visible one is `special-mode-map`.

### `undefined` is a command, and it lives in `keyboard.scm`

Emacs's `undefined` (`subr.el:1297`) says "%s is undefined" from
`this-single-command-keys`. That is this tree's `*this-command-keys*`, a
`keyboard.scm` variable, so the command lives there rather than in
`subr.scm` - the same accommodation `abort-recursive-edit` already has.
Not carried: the `ding` (no bell anywhere in the tree) and the
`prefix-arg` reset for a non-mouse event.

### The pty check was pinning the old behaviour, and is corrected

`eval-expression`'s check asserted that typing in `*Backtrace*` says
"Buffer is read-only" - which is what a tree *without* `suppress-keymap`
says, because the letter reaches `self-insert` and the buffer refuses it.
With the remap the letter never reaches the buffer: Emacs says
"z is undefined". The check now asserts that, with the measurement from
Emacs 31.1 in its comment.

# fill.el, and the primitives under it (2026-11-17)

`schemacs/editor/fill.scm` is `lisp/textmodes/fill.el` ported whole, on
top of the primitives it needed: `char-equal` and `subst-char-in-region`
(`editfns.c:4418`, `:2294`), `insert-before-markers` and
`insert-before-markers-and-inherit` (`editfns.c:1388`, `:1422`),
`fix-position` (`editfns.c:2281`), `buffer-hash` (`fns.c:6454`),
`string-to-list` (`subr.el:4739`), `indent.el`'s margin family
(`current-left-margin`, `move-to-left-margin`, `indent-to-left-margin`),
`back-to-indentation`, `beginning-of-line-text` (`indent.el:519`),
`paragraphs.el`'s real `forward-paragraph`/`backward-paragraph` and
`sentence-end` with their variables, and the sentence motions.

## The measurements the port was checked against

Every expectation in `fill-tests.scm` is Emacs 31.1's own answer for the
same bytes: the fixture text is filled on both sides and the outputs are
compared with `diff`. Seven whole-paragraph cases - a plain paragraph, an
indented one (the fill-prefix path), a line whose every space follows a
period (`sentence-end-double-space`), full justification, centring,
`fill-individual-paragraphs`, and `unfill-paragraph` - plus a comment
filled in `scheme-mode` (the `;;` prefix kept on every line) and four
piece-level ones (`current-fill-column`, `canonically-space-region`,
`fill-context-prefix`, `fill-nobreak-p`).

## Departures, each named where it happens in the source

### `fill-column` is buffer-local, with one dynamic override

Emacs's `fill-column` is a `DEFVAR_PER_BUFFER` **and** `fill.el`
`let`-binds it in two places (`unfill-paragraph`, `fill.el:966`;
`fill-region-as-paragraph-semlf`, `:1743`). This tree keeps the
buffer-local value (`buffer-fill-column`, `buffer.scm`) and adds
`*fill-column-override*` for the two rebindings, because a Scheme `let`
cannot reach a per-buffer table several frames down. `(fill-column)` is
the reader and answers the override when it is bound.

`fill-prefix` itself is `fill.el`'s defcustom and lives in
`indent.scm`; see the note under "The left margin and `fill-prefix`"
below.

### `default-justification` is a parameter, not buffer-local

Emacs declares it `:local t`. Nothing in this tree sets it per buffer, so
it is a plain parameter and the per-buffer arm is absent.

### There are no character categories

`char-script-table`, `char-category-set` and the category `|` are
`charset.c`'s, and `charset.scm` here carries only the metadata. The
consequences, all of them in `fill.scm`:

* `fill-move-to-break-point`'s regexp `"[ \t]\\|\\c|.\\|.\\c|"` is
  `"[ \t]"` (the engine rejects `\c` outright), and the two `\c|`
  branches inside its "keep at least one word" loop are omitted.
* `fill-newline`'s `\c|` test and its `(aref (char-category-set ...) ?|)`
  conjunct are omitted; only `fill-prefix` decides what is inserted.
* `fill-delete-newlines`'s "delete a newline between two words of a
  script that does not use spaces" walk is omitted entirely; Emacs
  deletes nothing between Latin words, so for the text this editor can
  serve the result is the same.
* `fill-find-break-point-function-table` and
  `fill-nospace-between-words-table` exist and are empty, so
  `fill-find-break-point` does nothing - which is Emacs's answer for a
  character with no entry.
* `charset-after`, which `fill-move-to-break-point`'s last arm calls, is
  not ported; the arm is a no-op instead of an ASCII test.

### `invisible-p` is not ported

`fill-nobreak-invisible` is declared and read, but the question it asks -
"is the text at point invisible" - has no reader here, so it always
answers "visible". Named in `fill-nobreak-p`'s comment.

### `with-buffer-unmodified-if-unchanged` hashes code points, not SHA-1

`subr-x.el:678`. Emacs's `buffer-hash` is a SHA-1 over the buffer's bytes
answered as a 40-character hex digest; Guile's core has no SHA-1. The
tree's `buffer-hash` folds FNV-1a over the code points and answers the
integer. Its one caller compares two hashes of the same buffer, which is
the whole contract - and Emacs's own docstring says the value is not
stable between versions. Guile's `hash` is **not** usable here: measured,
`(hash (u32vector 1 2) N)` and `(hash (u32vector 1 3) N)` answer the same
number, because a uniform vector is hashed by identity.

### Markers do not do arithmetic

Where Emacs compares a position with a marker (`(< (point) to)` with `to`
a marker), Scheme cannot, so `%pos` in `fill.scm` reads `marker-position`
at each comparison. It is the read-side spelling of `fix-position`. The
markers themselves are kept exactly where Emacs keeps them
(`canonically-space-region`'s `end`, `fill-region-as-paragraph-default`'s
`to`, `fill-region`'s `max`) because they must move as the text shrinks.

### `fill-move-to-break-point`'s fallback condition

The C's `(if (>= linebeg (point)) ...)` is a proxy for "no break point was
accepted". In the C, a refused candidate sends point back to the bound and
the following search fails, leaving point at LINEBEG; here
`skip-chars-backward` stops at the first non-space, so point can end a
little past it and the fallback ("keep at least one word, walking to the
line end") would not be taken. Measured against Emacs 31.1 on
`"One. Two. Three. ..."` at fill-column 70: Emacs walks to the line end
and breaks nothing. `fill-move-to-break-point` records whether a candidate
was refused (`rejected`) and takes the fallback when the last one was.

### Elisp's `if` takes several ELSE forms

`(if COND THEN ELSE...)`. Every arm of the C that carries several forms is
written as a `begin` here; the ones that matter are `fill-newline`'s,
`fill-paragraph`'s four-strategy `or` chain and `justify-current-line`'s
`nil` after its `if`.

### `M-k` was bound to the wrong command

`paragraphs.scm` bound `M-k` to `kill-paragraph` and `M-C-k` to
`backward-kill-paragraph`. Measured: `(key-binding "\M-k")` is
`kill-sentence`, `M-C-k` is `kill-sexp` (which `lisp.scm` already binds,
so the two files were fighting over one key), and `kill-paragraph` is
bound to nothing at all. Corrected, and `C-x DEL`, `M-e`, `M-a`, `M-{`
and `M-}` bound to what `bindings.el` binds.

## Not carried, each with what it waits for

* `use-hard-newlines`' **mode command** - the variable is here and every
  branch that reads it is ported; the mode needs `:extra-args`, which
  this tree's `define-minor-mode` does not carry, and
  `set-hard-newline-properties`. A buffer therefore never has a `hard`
  newline and the branches are dead until that changes.
* `paragraph-indent-minor-mode` and its abbrev table.
* `transpose-paragraphs`, `transpose-sentences`, `count-sentences`,
  `repunctuate-sentences`, `mark-end-of-sentence` - each needs a piece
  this tree does not have (`transpose-subr` over a motion function,
  `isearch-filter-predicate`, `push-mark`'s ACTIVATE).
* `fill-paragraph`'s `C-u` "insert the value" arm and the minibuffer's
  prompt-width accounting: `fill-minibuffer-function` is carried, and
  `minibufferp` answers for the active minibuffer.

## The left margin and `fill-prefix` (2026-11-17)

`indent.el`'s margin family is ported (`current-left-margin`,
`move-to-left-margin`, `indent-to-left-margin`, and the `left-margin`
buffer-local in `buffer.scm`, default 0), and with it `indent-region`'s
first branch - "If a fill-prefix is specified, use it" - which had been
a named gap in `indent.scm` since the file was written.

`fill-prefix` is `fill.el`'s defcustom and it lives in `indent.scm`. The
reason is the import graph, and it is the same shape as
`*minor-mode-alist*`'s move to `subr.scm`: three libraries read it -
`indent-region` (`indent.el:552`), `forward-paragraph`
(`paragraphs.el:229`) and `beginning-of-line-text` (`indent.el:531`) -
and `paragraphs.scm` already imports `indent.scm` for the margins, so
keeping it in a `fill.scm` would make `indent -> paragraphs -> indent` a
cycle. `indent.scm` is the lowest of the three.

`move-to-left-margin`'s `minibufferp` branch is **not** carried: Emacs
sends the minibuffer either to the prompt end or to the line beginning so
that a margin never eats the prompt, and this tree's prompt is buffer
text whose `field` already constrains `beginning-of-line` (2026-11-15) -
`fill-minibuffer-function` narrows to the prompt end before it fills. The
branch is named in the source.

# Auto Fill mode (2026-11-17)

`do-auto-fill`, `auto-fill-mode`, `internal-auto-fill`,
`default-indent-new-line`, `turn-on/off-auto-fill`,
`auto-fill-inhibit-regexp`, `inhibit-auto-fill`,
`normal-auto-fill-function`, `comment-line-break-function`, and the
buffer's `auto-fill-function` slot. Measured against Emacs 31.1 by
typing the same text with `self-insert-command` one character at a time
at `fill-column` 20: identical output, and the tests in
`fill-tests.scm` pin it.

## Placements, both forced by the import graph

* **The auto-fill half of `simple.el` lives in `fill.scm`.**
  `do-auto-fill` is written in this file's functions, and `simple.scm`
  is *below* `paragraphs.scm`, which `fill.scm` imports - so
  `simple -> fill` would be a cycle, and a seam for each of the eight
  functions `do-auto-fill` calls would be more departure, not less.
* **`auto-fill-chars` is `character.c`'s and lives in `cmds.scm**. Its
  only reader is `internal_self_insert`'s test, and `character.scm`
  cannot hold it: a char-table brings `chartab.scm`, which brings
  `intervals.scm`, which imports `buffer.scm`, whose `buffer-text`
  imports `character.scm` - a cycle. `cmds.c` is where the test is.

## Departures

* **`comment-line-break-function` has no default.**
  Emacs's is `comment-indent-new-line`, which needs `comment-beginning`,
  `comment-valid-prefix-p`, `comment-forward`, `comment-enter-backward`
  and `comment-styles` - the comment-continuation half of
  `newcomment.el`, not ported. With the variable nil,
  `default-indent-new-line` takes its non-comment path inside a comment
  too: it breaks the line and indents it, but does not repeat the `;;`
  starter. **Worth fixing** when that half is ported.
* **A typed RET does not auto-fill.** Emacs's `newline` sets
  `last-command-event` and calls `self-insert-command`, so a line break
  goes through `internal_self_insert` like any character. This tree's
  `insert-newline` inlines the insert (its own docstring already named
  that), so auto-fill happens on a typed space but not on RET.
* **`post-self-insert-hook` is still not run**, which is now the only
  thing `internal_self_insert` does not do.
* `inhibit-auto-fill` is a parameter (`*inhibit-auto-fill*`): `newline`
  `let`-binds it in Emacs and the binding must reach `internal-auto-fill`
  several frames down. Nothing here binds it yet, which is the RET gap
  above.

## The bug the auto-fill tests found

`fill-comment-paragraph` **leaked the fill prefix for the whole editor**.
The C's `let*` starts with `(fill-prefix fill-prefix)` - a binding the
body then *sets*, first to the adaptive prefix and then to the comment's
own - and the port had dropped it, so `(*fill-prefix* ";; ")` was a
permanent write to the parameter. The symptom was three tests away and
looked nothing like a comment: after filling a comment in a `scheme-mode`
buffer, the *next* buffer's auto-fill continued its lines with `;;`
because `default-indent-new-line` inserted the leftover prefix. It is a
`parameterize` now, and the auto-fill tests are what caught it.

## `define-minor-mode`'s ARG was required, and the generated form
## named two imports (2026-11-17)

Two departures found by asking a generated command what it does, and
both are `easy-mmode.el`'s own rules that the port had bent.

**1. ARG is optional.** Emacs generates `(defun ,mode (&optional arg
...))`; this macro generated a *required* parameter, so `(auto-fill-mode)`
- a call Emacs accepts and every user types - raised "Wrong number of
arguments to `#<procedure auto-fill-mode (arg)>`". Measured on Emacs
31.1, the semantics of a bare call are **enable, not toggle**: nil is
not the symbol `'toggle`, so it takes the `(t ...)` arm -
`(auto-fill-mode)` twice leaves the mode on, `(auto-fill-mode nil)` also
enables, and only the *interactive* form's `'toggle` (what it supplies
when there is no prefix) toggles. The generated command is
`(define-command (#,mode-id . rest)` with ARG taken from REST now, which
is the optional parameter Emacs writes.

**2. The interactive form's two names have to be imported by the
*calling* library.** The generated `(interactive (list (if
(current-prefix-arg) (uarg->integer 1 (current-prefix-arg)) 'toggle)))`
is evaluated in the command's *defining* module, and three libraries
that call `define-minor-mode` did not import `current-prefix-arg` or
`uarg->integer`: `font-core.scm`, `face-remap.scm` and `fill.scm`. So
`M-x font-lock-mode` - or any key bound to `font-lock-mode`,
`text-scale-mode` or the new `auto-fill-mode` - raised "Unbound
variable: current-prefix-arg" the moment it was reached, and the command
loop's guard turned that into a key that did nothing. Emacs has one
obarray and needs nothing. All three import both now, and the macro's
comment says why; `easy-mmode-tests.scm` drives the interactive entry
for real, which is the only way to see it (a direct call to the command
bypasses the specification entirely).

**3. `normal-auto-fill-function` was a forward reference.** Emacs's
`defvar` holds the quoted *symbol* `do-auto-fill`, which needs no
function to exist yet; here the variable holds the procedure, so
`(define normal-auto-fill-function do-auto-fill)` above the definition
of `do-auto-fill` made the library unloadable *interpreted* - the
compiled `.go` resolves it, so only a run with no compiled cache showed
"Unbound variable: do-auto-fill". The variable is `#f` where Emacs
declares it and `set!` to `do-auto-fill` after the definition, which
also marks it mutable for the compiler's constant folding.

# The comment continuation, and the parameter that was always true
# (2026-11-17)

`comment-indent-new-line` (`newcomment.el:1465`) and its helpers, so that
auto-fill inside a comment repeats the `;;` and `comment-line-break-function`
has its real default. Verified against Emacs 31.1 on ten fixtures - a
comment continued at its end, split in the middle, with `comment-multi-line`
on, a `;;;` doc comment, a comment after code, one in an indented body, and
the three auto-fill cases - all byte-identical.

## What landed, and where

| Emacs | here |
|---|---|
| `newcomment.el:537` `comment-search-backward` | `newcomment.scm` |
| `:567` `comment-beginning`, `:606` `comment-forward`, `:622` `comment-enter-backward` | `newcomment.scm` |
| `:226` `comment-styles`, `:285` `comment-style`, `:313` `comment-multi-line` | `newcomment.scm` |
| `subr.el:6563` `syntax-after` | `syntax.scm` - it reads the `syntax-table` text property through `get-char-property`, which lives next door |
| `:1424` `comment-valid-prefix-p`, `:1465` `comment-indent-new-line` | **`fill.scm`** |

**The placement is forced by the import graph and named in both files.**
`comment-indent-new-line` reads `adaptive-fill-mode`, which is `fill.el`'s
and lives in `fill.scm`, and `fill.scm` imports `newcomment` - so the
function's Emacs home would close the cycle `fill -> newcomment -> fill`
for that one variable. Its only caller is `default-indent-new-line`, in
`fill.scm`, and it is `comment-line-break-function`'s default.

## The bug: a parameter used as a variable, so `comment-auto-fill-only-comments` was always on

The port's first version wrote the guard as

    (and (comment-start) *comment-auto-fill-only-comments* ...)

`*comment-auto-fill-only-comments*` is a **parameter**, and an uncalled
parameter is a *procedure*, which is true - so the `and` never short-
circuited, and the `save-excursion` that follows (`comment-beginning`, then
`(point)` into COMIM) ran on **every** call. That set COMIM from inside
the comment, one character further right than the C's, and COMTART came
out as `";;\n"` instead of `";;"` - one byte too many, which showed up as
an extra newline: `";;\n;;\naaa bbb"` where Emacs has `";;\n;;aaa bbb"`.

It is the same class as the `M-p`/`kbd` and `*tab-bar-auto-width*` bugs:
**a parameter read without its parentheses**, which compiles, reads as
plausible, and is always true. The test that caught it was the fixture
with point in the *middle* of a comment; the end-of-line fixture passes
either way, because there COMIM is already right.

## `comment-enter-backward` and `(car nil)`

`syntax-after` answers nil outside the accessible portion, and Elisp's
`(car nil)` is nil which `logand` reads as zero. Scheme's `(car #f)` is an
error, so the two `logand` tests go through `%syntax-code-or-0`. The case
is point at `point-min + 1` with a two-character comment ender.

## Two Elisp-isms the function needed

* **`let*` over buffer-local variables.** The C binds `comment-start`,
  `comment-end`, `comment-column`, `comment-indent-function` and
  `comment-continue` around `(comment-indent continuep)` so that
  `comment-indent` reads *those* values. In this tree the five are
  buffer-locals read through accessor functions, so the port sets them in
  the current buffer and puts them back in a `dynamic-wind` - which is
  what Emacs's `specbind` does for a buffer-local `let`. One observable
  difference, named in the source: a variable that was not locally bound
  is restored to the value every reader here reads it with, because there
  is no way to *un-bind* a slot in this tree.
* **`called-interactively-p 'interactive`** is
  `(called-interactively? comment-indent-new-line)` - the command named,
  as `define-minor-mode` does.

## Still not carried from this half of `newcomment.el`

`comment-dwim`, `comment-region`, `comment-or-uncomment-region`,
`uncomment-region`, the quoting machinery (`comment-quote-nested`),
`comment-set-column`, `comment-line`, `comment-kill`, `comment-box` and
`comment-search-forward`'s `comment-use-syntax`'s `undecided` probe.

## `syntax-ppss`'s cache: two cells, buffer-local (2026-11-17)

`M-j` in a fresh `scheme-mode` buffer raised "Wrong type argument in
position 2: #f" and left a bare newline behind. The error was three
functions from the cause: a **stale `syntax-ppss` cache entry**.

## What Emacs has, and what this tree had

`syntax-ppss` caches parse states so the scanner does not re-parse from
`point-min` every call. Emacs keeps **two `defvar-local` cells**
(`syntax.el:530-540`): `syntax-ppss-wide` for a buffer at its full
extent, and `syntax-ppss-narrow` for one inside a `save-restriction`,
reset whenever the narrowing's start moves. `syntax-ppss--data`
(`:595`) picks between them by `(point-min)`, and the comment there says
why: "we need either to empty the cache when we narrow the buffer, which
is suboptimal, or we need to use several caches. We use two of them."

This tree had **one `make-parameter` cell**, global to the whole editor
thread and blind to narrowing, and `pt-min` was hard-coded to `1` where
Emacs uses `(point-min)`. So:

* a parse done inside `scheme-syntax-propertize`'s narrowing could store
  a state that the unnarrowed parse then read;
* a state cached at position 12 could be read back at position 1, and
  with the empty buffer's state stored there - `(nth 2 ppss)` nil and no
  toplevel position - Emacs's own `(<= pt-min pos)` test is then
  `(<= nil pos)`, which raises. (Emacs would raise the same; it never
  gets there because the cells are separate.)

## What landed

* `%syntax-ppss-data` is Emacs's `syntax-ppss--data` over two
  **buffer-local slots**, `syntax-ppss-wide`/`syntax-ppss-narrow`, with
  `syntax-ppss-narrow-start`.
* `pt-min`/`pt-best` are `(point-min)` in both branches.
* `syntax-ppss-flush-cache` is `syntax.el:544`'s: it flushes **both**
  cells, drops entries with `(> (caar cache) beg)` (strictly greater -
  the port had `>=`), and throws away `last` with the C's own condition
  rather than always. Emacs's `syntax-propertize--in-process-p` guard is
  not carried; without it the flush can only make the propertizer redo
  work, never do less.
* `%point-min` sits beside the existing `%point-max`, because
  `editfns.scm` imports this library and a local `point-min` was
  otherwise unbound - which `syntax-after` (`subr.el:6563`) had been
  since it was written.

Regression tests: `syntax-tests.scm`'s `ppss_cache` group - the
high-then-low sequence that raised, a second buffer not reading the
first's cache, and a narrowed parse not displacing the unnarrowed state.
Every expectation is Emacs 31.1's, measured with the comment syntax set
(`;` starter, newline ender), which matters: without those entries `;`
is punctuation and every state says "not in a comment".

# Narrowing's commands, and the redisplay a narrowing needs (2026-11-17)

Chris: "I thought you said narrowing was done, but C-x n n seems to do
nothing." The primitive and the call sites were done; **the commands and
the keys were not**. `narrow-to-region` and `widen` were plain functions
with no interactive spec, and nothing had ever bound `C-x n n`, so the
key was undefined.

## What landed

| Emacs | here |
|---|---|
| `editfns.c:2948` `narrow-to-region`, spec `"r"`; `:2901` `widen`, spec `()` | `editfns.scm`, as `define-command`s (the interactive specs are in the DEFUNs) |
| `bindings.el:1214` `narrow-map` (`n`, `w`, `g`) and `(define-key ctl-x-map "n" narrow-map)` | `narrow-map`, made in `editfns.scm` beside its two commands; `g` added by `minibuffer.scm` |
| `lisp.el:742` `narrow-to-defun` (`C-x n d`, `bindings.el:1669`) | `lisp.scm`, with `narrow-to-defun-include-comments` |
| `page.el:88` `narrow-to-page` (`C-x n p`, `bindings.el:1729`) | `pages.scm` |
| `simple.el:1703` `goto-line-relative` (`C-x n g`) | `minibuffer.scm`, beside `goto-line` |

**A departure, the same one `mule-keymap` records**: this tree's key
lookup does not descend into a submap, so `C-x n n`, `C-x n w`, `C-x n d`,
`C-x n p` and `C-x n g` are bound **flat**, and `narrow-map` exists as
Emacs's object beside them (for `where-is-internal` and for tests).

**`(put 'narrow-to-region 'disabled t)` (`bindings.el:1111`) and the
`page.el` equivalent are not carried**: Emacs asks "Use this command?"
before narrowing, and the disabled-command machinery (`simple.el:2811`,
`novice.el`) needs `substitute-command-keys` - `help.el:1435` in
Emacs 31, not `doc.c` - beside `key-valid-p`, `documentation` and a
`\={MAPVAR}` keymap summary, none of which is ported. So `C-x n n`
narrows at once here where Emacs prompts. Worth closing when that
machinery is ported; named rather than faked.

## `clip_changed` is a full repaint, and the renderer did not know it

`narrow_to_region` and `Fwiden` set `current_buffer->clip_changed`
(`editfns.c:2989`), and `redisplay_internal` answers it by invalidating
every window's glyph matrix and redisplaying the frame - which is *why*
the C can skip rows in `update_window` and still be right.

This tree sets `windows-or-buffers-changed` there (`%clip-changed!`), and
`render!` used that flag only to re-read the menu and tab bars. The row
diff then skipped every row a narrowing left unchanged, and the terminal
kept whatever it had - for `C-x n n` and `C-x n d` that was *nothing*,
because ncurses had been asked to repaint. **The fix is one `or`**: a
frame is treated as garbaged when `windows-or-buffers-changed?` is set,
so its matrices are invalidated and its surface cleared exactly as a
resize's are. Measured before/after at a pty: the screen kept only the
mode line; it now shows the narrowed text, and `tools/pty-check.py`'s
`narrow` check passes (it failed before, with three assertions naming the
stale text).

The walk to that fix also established, by querying a live editor, that
the desired matrix *was* right (`(defun foo` in row 0's glyphs) while the
screen was blank - the diff, not the row builder.

## Two search departures this exposed

1. **`match-beginning`/`match-end` signal where Emacs answers nil.**
   `match_limit` (`search.c:2776`) is
   `if (n < 0 || n >= num_regs || start[n] < 0) return Qnil;` - all three
   nil, including "no match data at all". This port raised "Args out of
   range" for a negative N and "No match data, because no search
   succeeded" with no registers. `narrow-to-page` calls
   `(set-match-data nil)` and then `(match-beginning 0)` to ask whether
   `forward-page` matched, so the error was on its ordinary path.
2. **`(set-match-data nil)` did not clear the registers.** The C's final
   loop (`for (i = length; i < num_regs; i++) start[i] = -1;`) clears
   every register when the list is nil - measured: search, then
   `(set-match-data nil)`, then `(match-beginning 0)` is nil. Ours left
   the old registers readable, and `narrow-to-page` then read a *previous*
   page's match position (a stale 5 instead of the page at 9).

Both have regression tests in `search-tests.scm`; the test that had
pinned the error is now the Emacs answer.

# `inhibit-modification-hooks`, and the `syntax-propertize` sentinel (2026-11-17)

Found while making `narrow-to-defun` work; both are primitives the
syntax layer had been doing without.

**`inhibit-modification-hooks` was not carried** - `with-silent-modifications`'s
own comment said so. The C tests it twice: `prepare_to_modify_buffer_1`
returns before `signal_before_change` (`insdel.c:2167`) and
`signal_after_change` returns at its first line (`:2387`). It is an
`insdel.c` parameter here now, bound by `with-silent-modifications` and by
`syntax-propertize` (which Emacs wraps in that macro and this library
cannot import - `subr.scm` is above it).

Without it, every property write during propertizing ran the change
hooks - font-lock's after-change *and* `syntax-ppss-flush-cache`, which
drops the parse state the propertizer itself is computing.

**`syntax-propertize` had no in-process sentinel.** Emacs binds
`syntax-propertize--done` to `most-positive-fixnum` around the mode's
function (`syntax.el:457`), and `syntax-ppss-flush-cache` checks for that
value before lowering the limit (`:547`) - `syntax-propertize--in-process-p`
(`:384`) is exactly that test. Without it every `syntax-ppss` inside a
propertize re-entered the propertizer and re-flushed the cache. Ported
whole, with the extend-region walk's own binding of the sentinel and
`syntax-ppss--updated-cache` (the flush that follows a parse made while
propertizing).

**`syntax-ppss`'s `last` entry is stored by two of three branches.**
Measured on Emacs 31.1: `(syntax-ppss 10)` then `(syntax-ppss 13)` leaves
`last` at 10 (the OLD-POS branch updates neither `last` nor the cache -
"Don't update the `last' cache", `syntax.el:632`); `(syntax-ppss 15)`
then `(syntax-ppss 6)` leaves it at 6 (OLD-PPSS stores). The port stored
only in the `else` branch, so a state computed by either of the other two
was never remembered and a flushed entry could be read back as if it
belonged to the new position.

All three together are what `M-j` and `narrow-to-defun` were failing on
("Wrong type argument in position 2: #f" from `(<= #f pos)` in
`syntax-ppss`'s OLD-PPSS branch).

# A typed RET: `newline`, and the hook under it (2026-11-17)

`newline` is `simple.el:621`'s in Emacs 31 - it moved out of `cmds.c`.
It is not a loop over `insert`: it sets `last-command-event` to the line
break and calls `self-insert-command`, so the break goes through
`internal_self_insert` like any typed character - property inheritance,
the `auto-fill-chars` branch (`internal-auto-fill` fills the line the
break ended), and `post-self-insert-hook`.

## `post-self-insert-hook` (`cmds.c:524`, run at `:498`)

Ported as a parameter and run at the end of `internal-self-insert` - the
C's `run_hook (Qpost_self_insert_hook)` is its last act, after the
auto-fill branch. It is run with a plain `for-each`, as the change hooks
are in `insdel.scm`: `(schemacs editor subr)` is above `buffer.scm`,
which `cmds.scm` imports, so `run-hooks` is not reachable from there.
That is the same reason `auto-fill-chars` lives in `cmds.scm`.

## `newline`'s post-processing is a hook entry, and first on it

Emacs conses a closure onto `post-self-insert-hook` so that the hard
newline, the blank line's lost margin and the new line's
`move-to-left-margin` all happen *before* any other hook function. Two
spellings are this tree's:

- **`parameterize`, not `add-hook`/`remove-hook`.** Emacs's comment at
  bug#46326 explains why it does not let-bind the hook: `add-hook`
  affects the symbol-default value while a let-binding may protect only
  the buffer-local one. A parameter has no such split - everything that
  runs the hook reads the parameter - so binding it around the call is
  the same extent Emacs's add/remove gives, and the `unwind-protect`
  has nothing to do.
- **The entry still removes itself** from the parameterized list before
  its work, as the C's `(remove-hook 'post-self-insert-hook procsym t)`
  does: a nested self-insert (from some other hook function) then does
  not run this one twice. It is a `letrec` lambda rather than an `fset`
  on a gensym, because a hook list here holds procedures.

The two branches are kept separate, as the C keeps them: a
**non-interactive** `(newline)` binds the hook to `(list postproc)`, so
only `newline`'s own entry runs - "for non-interactive uses ... avoid
the risk of filling or running abbrevs unexpectedly" - while an
interactive RET conses its entry in front of the caller's functions.
Measured on Emacs 31.1: with a `(lambda () (insert "|"))` on the hook,
`(newline)` gives `"ab\n"` and `(call-interactively 'newline)` gives
`"ab\n|"`. Both pinned in `fill-tests.scm`.

## Three options moved down, because `newline` is their lowest reader

`newline` reads three variables that Emacs declares above this tree's
`simple.scm`:

| variable | Emacs | here |
|---|---|---|
| `inhibit-auto-fill` | `simple.el:9247` | `simple.scm` (was `fill.scm`) |
| `page-delimiter` | `paragraphs.el:213` | `simple.scm` (was `paragraphs.scm`) |
| `use-hard-newlines` | `paragraphs.el:37` (a `define-minor-mode`) | `simple.scm` (was `paragraphs.scm`) |

They moved rather than being reached through a seam because Emacs has no
layering to cross: the variable belongs where its lowest reader is, and
`newline` is in `simple.el`'s own file. `fill.scm` and `paragraphs.scm`
import and re-export them, so nothing above either library changed -
the move `*minor-mode-alist*` made into `subr.scm`.

`use-hard-newlines`' **mode** is still not ported; the variable is a
`define-custom` here, with the mode's own docstring. `set-hard-newline-
properties` (`simple.el:692`) is ported with it: Emacs's `'t` is `#t`
here, and its nil - which `listp` accepts - is `'()` for the
`rear-nonsticky` test.

## Not carried

- **`electric-indent-mode`**, so `newline` binds nothing around the
  self-insert and `C-j` is bound to `insert-newline` where Emacs 31 has
  `electric-newline-and-maybe-indent` (`bindings.el`; measured in a
  fundamental-mode buffer).
- **The abbrev expansion** at the top of `internal_self_insert`
  (`abbrev-mode` is not ported).

## Two pre-existing bugs fixed on the way

- **`fill.scm` called `equal`, which nothing in the tree defines.** It
  is Emacs's `equal` on two strings; Scheme's `equal?` is the answer.
  The compiler had said "possibly unbound"; the comment-fill path that
  reads it was never taken by a test.
- **`newcomment.scm`'s `comment-enter-backward` called `logand` without
  importing it, and `(char-after)` with no argument** - this tree's
  `char-after` requires its position (Emacs's defaults to point). Both
  on the two-character-comment-ender branch.
- `custom-tests.scm` referenced `custom-theme-recalc-variable` through a
  *prefixed* import's back door (Guile's `module-ref` reaches the
  unprefixed name even though the compiler cannot see it). It is
  imported plainly now.

# `prog-fill-reindent-defun`, and the two position primitives under it
# (2026-11-17)

`prog-mode.el`'s two map entries are carried: `prog-indent-sexp`
(`prog-mode.el:131`, `C-M-q`) and `prog-fill-reindent-defun`
(`:194`, `M-q`), with `prog--text-at-point-p` (`:144`),
`prog--text-at-point-or-region-p` (`:169`), the
`prog-fill-reindent-defun-function` seam (`:177`) and its default
(`:182`). In a `prog-mode`-derived buffer, `M-q` in code reindents the
defun, and `M-q` in a comment or string fills the paragraph - which is
the behaviour the mode's empty keymap had been naming as a gap.

## `pos-bol` and `pos-eol` (`editfns.c:684`, `:740`)

`prog--text-at-point-p` asks `pos-eol` where the line ends *ignoring
fields*; the tree only had `line-end-position`, which constrains. Both
C functions are now ported beside their constrained twins, in the C's
order:

| | C body | here |
|---|---|---|
| `pos-bol` | `(make_fixnum (bol (n, NULL)))` | `(bol ed n)` |
| `line-beginning-position` | `constrain_to_field (bol ...)` | the same |
| `pos-eol` | `(make_fixnum (eol (n)))` | `(eol ed n)` |
| `line-end-position` | `constrain_to_field (eol ...)` | the same |

The difference is the field machinery, so a test for a field boundary
cannot use the `pos-` pair and a test of the pair must not sit in a
minibuffer prompt.

## The layering move, named

`prog-mode.scm` now imports `fill`, `lisp`, `indent`, `newcomment`,
`syntax`, `search`, `cmds` and `editfns`, where Emacs's `prog-mode.el`
needs nothing at load time. Two of its rules force it: a binding must
come *after* the command it binds (so the map's two `define-key`s sit
at the bottom of the file), and the commands call `fill-paragraph`,
`forward-sexp` and `indent-region`.

It is safe because **nothing the new imports reach imports `prog-mode`,
`lisp-mode` or `scheme`** - those are the only two importers of this
library, and the `files.scm` hit on `lisp-mode` is the auto-mode
autoload table, not an import. (The one real importer of `scheme` is
`scheme` itself; `lisp.scm`'s hit is a comment.)

`prog-fill-reindent-defun-function` is a **plain variable**, not a
parameter: Emacs declares it with `defvar`, nothing `let`-binds it, and
it is set with `(set! ...)` after the function it names exists - the
`normal-auto-fill-function` shape, forward reference and compiler
mutation marker included. Its default is set below the definition
because a `set!` above it would read the name before it is bound.

## The measured answers

Every expectation in `prog-mode-tests.scm` is Emacs 31.1's own output
for the same text in `emacs-lisp-mode`:

- `C-M-q` at point 1 of a badly indented defun produces the fully
  indented one, and `C-u C-M-q` from inside the defun the same;
- `M-q` in code reindents the defun;
- `M-q` in a comment at `fill-column` 30 fills it and continues the
  `;;`;
- `prog--text-at-point-p` answers **positions, not `t`**: nil in code
  and at a bare `(`, `1` at a `;;` start and inside a comment, `4` at a
  string's opening quote. The first test run compared against booleans
  and failed against the port's correct answers - the measurement, not
  the port, is what the expectation must copy.

# `simple.el`'s `count-lines`, and the `assq` under it (2026-11-18)

## The name: `%count-lines` is the C helper, `count-lines` is the Lisp one

Emacs has two functions that both count lines between two positions, and
only one of them has a Lisp name:

- `count_lines` (`xdisp.c:29903`) - a C function declared in `lisp.h`
  (`:4409`) and DEFUN'd nowhere, counting line breaks with
  `display_count_lines`. It lives in `fns.scm` in this tree because its
  only real caller is `fns.c`'s `line-number-at-pos` (`xdisp.c`'s line
  number for the `%l` cache reaches it through `fns` from below).
- `count-lines` (`simple.el:1800`) - the Lisp function, which narrows to
  START..END and adds one when the range does not end at the start of a
  line. Measured on Emacs 31.1: over `"a\nb\nc"`, `(count-lines 1 6)` is
  **3**, where the C walk answers **2**.

The tree had given the C helper the plain name, with a comment saying the
Lisp function was not ported and the name must not be read as it. That
stopped being tenable once the Lisp function was ported: both cannot
carry one name, and the user-visible one is `simple.el`'s. So the C
helper is **`%count-lines`** now, the `%kill-buffer` treatment (the
mechanism takes the mark; the Lisp-visible name is Emacs's), and the
Lisp function is `count-lines` in `simple.scm`, exported to the user
environment through `imports.scm`.

## What the port carries, and the two things it cannot

The body is Emacs's in its order: `save-excursion` over
`save-restriction` over `narrow-to-region`, then the branches.

- **The default branch** - `point-max`, `bolp`, `line-number-at-pos` -
  is whole. `narrow-to-region` sorts its arguments itself (the C's
  `if (e < s)` swap, `editfns.c:2974`), which is how a reversed range
  counts the same as the sorted one: measured, `(count-lines 6 1)` is 3.
- **`ignore-invisible-lines` is whole**, including the
  `buffer-invisibility-spec` test in both shapes (`t` means any non-nil
  `invisible` property hides; a list means `memq` for the symbols and
  `assq` for the `(SYMBOL . BOOL)` pairs). Two readings are this tree's:
  - `buffer-invisibility-spec` is `buffer.c`'s per-buffer variable with
    no definition site here, so it is read with `buffer-local-value` and
    Emacs's **default `t`** (measured: `(with-temp-buffer
    buffer-invisibility-spec)` is `t`). With the default, a buffer whose
    lines carry `invisible` answers the reduced count - measured 2 for a
    four-line buffer with two invisible lines, which is Emacs's answer
    too.
  - **The renderer does not honour `invisible`** (`indentc.scm` and
    `xdisp.scm` both say so where the C reads it). So the branch's count
    is Emacs's answer *about the buffer's text properties*, not about
    what this screen shows; dired does write the property, so the
    difference is reachable. When the redisplay learns invisibility the
    two agree again without a change here.
- **`selective-display` is not carried, and that is a named gap.**
  Emacs's first branch counts with a `\r` ending a line when the
  variable is `t`. The variable's default is nil, so the branch is dead
  for every buffer state this tree can produce - and it would stay
  *wrong* if a user set it, because the redisplay has no selective
  display to agree with. `%count-lines` carries the same omission for
  its C walk. Closing it means the redisplay's `\r` handling first.

## `%assq`: Emacs's `assq` cannot be called `assq` here

The invisible-lines branch needs Emacs's `assq`, whose docstring ends
"Elements of ALIST that are not conses are ignored" (`fns.c:1967`).
Measured on Emacs 31.1: `(assq 'bar '(foo))` is nil and
`(assq 'bar '(foo (bar . 2)))` is `(bar . 2)`. R7RS's `assq` - and
Guile's - raises on a non-pair element, which is exactly the shape
`buffer-invisibility-spec` has (symbols and conses in one list).

**A library in this Guile cannot shadow the core `assq`.** Measured
three ways with a clean `~/.cache/guile/ccache`: a library that
`(except (scheme base) assq)`s and imports another library's `assq`
still calls the core one at run time; the module's `assq` is
`not eq?` to the imported procedure; and reordering the imports changes
nothing. So Emacs's `assq` is ported into its Emacs file, `fns.c`'s
`fns.scm`, as **`%assq`** - the `%` because the host claims the plain
name, the mirror image of `%kill-buffer`'s case.

It also keeps the C's tail rule: `FOR_EACH_TAIL` then `CHECK_LIST_END`,
measured as `(wrong-type-argument listp (a . b))`. That raises the
tree's ordinary type error with the whole ALIST as the irritant, and
reads Elisp's nil as either of the tree's two spellings (`#f` or `()`).

**The rest of the tree still calls the core `assq`** - 37 files - and
`assoc` has the identical tolerance gap. Converting them is the
follow-up this pass did not do: it is one import line per caller
(`(only (schemacs editor fns) %assq)`) and a careful read of the ones
where a non-cons element is possible. `window.scm`'s
`window--state-assq` and `tab-bar.scm`'s `tab-bar--assq` are two
hand-written copies of exactly this C behaviour, written because it was
missing; they are where that work starts.

## `count-lines-page`'s note, corrected

`pages.scm` listed `count-lines-page` as blocked on `count-lines`' "Lisp
half, which is not ported". It is ported now, and the note says what is
actually left: `page--count-lines-page` is portable, but the command's
`message` is Emacs's `ngettext` call (the C library's plural selection,
libintl.c), and this tree has no message catalogs. Same rule as the
overstated gap notes before it: say what remains and what it takes,
rather than leaving a reason that has expired.

## The measured table

Every expectation in `fns-tests.scm`'s two new groups is
`emacs -Q --batch`'s answer, measured first:

| | Emacs 31.1 | port |
|---|---|---|
| `(count-lines 1 6)` over `"a\nb\nc"` | 3 | same |
| `(1 1)` `(1 4)` `(1 5)` `(2 6)` | 0 2 2 3 | same |
| `(2 2)` `(4 4)` `(2 3)` `(5 6)` `(6 6)` `(1 2)` `(1 3)` | 0 0 1 1 0 1 1 | same |
| reversed `(6 1)` `(4 2)` | 3 2 | same |
| point after the call | unmoved | same |
| markers as START and END | works | same |
| empty buffer | 0 0 | same |
| inside a narrowing: `(2 6)` `(3 5)` | 3 1 | same |
| ... and `(1 7)` | args-out-of-range | same message |
| invisible "a\n" "b\n", flag given, spec default/`'(foo)`/`'(bar)`/nil/`'()` | 2 3 3 4 4 | same |
| the same without the flag | 4 | same |
| `(assq 'bar '(foo (bar . 2)))` | `(bar . 2)` | same |
| `(assq 'bar '(foo))` | nil | `#f` |
| `(assq 'x '(a . b))` | wrong-type-argument | same message |

One expectation in the suite is Emacs's *default* invisibility spec
(`t`) rather than a measured varietal: the suite measures it through
the port, and Emacs's own default was measured separately
(`(with-temp-buffer buffer-invisibility-spec)` is `t`).

# Labeled restrictions (2026-11-18)

`with-restriction` / `without-restriction` and the `editfns.c` stack
under them are ported. The AGENTS.md list that named this work also
named `narrowing-locked`, **which does not exist in Emacs 31.1**: `(fboundp
'narrowing-locked)` and `(boundp 'narrowing-locked)` are both nil, and
nothing in `lisp/` or `src/` mentions it. The claim was wrong in the
overstating direction the earlier gap notes were wrong in, and the note
is corrected rather than ported.

## What the C does, and where each piece lives

`editfns.c:2716-2900` keeps `static Lisp_Object labeled_restrictions`:
an alist of `(BUFFER . TRIPLETS)`, each triplet `(LABEL BEGV-MARKER
ZV-MARKER)`, innermost first. The last triplet is always labelled with
the uninterned `Qoutermost_restriction` and records the bounds that were
current when the first labeled restriction was entered - so leaving the
last one goes back to the user's own narrowing, not to nothing.

Ported into `editfns.scm` beside `widen`, under the C's names:
`%labeled-restrictions-add`, `-remove`, `-get-bound`, `-peek-label`,
`-push`, `-pop`, `-save`, `-restore`, `%unwind-reset-outermost-restriction`.

- **`widen`** (`editfns.c:2901`): no label means the whole text, as
  before; a label means the innermost label's bounds, and popping the
  stack when the label *is* the outermost's.
- **`narrow-to-region`** (`:2974`): when a label is in effect, START and
  END are clipped to its bounds - *after* the `BEG..Z` validation, so a
  range outside the text is still args-out-of-range (measured; the
  position of the block in the C is the reason).
- **`internal--labeled-narrow-to-region`** (`:3008`) and
  **`internal--labeled-widen`** (`:3023`), under Emacs's names. The
  outermost triplet is built *before* the narrow, so its markers hold
  the pre-narrowing bounds.
- **`save-restriction`** (`:3150`) saves and restores the labels beside
  the bounds - `save_restriction_save` is now the pair, and
  `save_restriction_restore` puts the labels back first, then the
  bounds, in the C's two-statement order.
- **`point-min-marker` / `point-max-marker`** (`:887`, `:906`), which
  the internals need and the tree did not have.

## The redisplay bracket

`reset_outermost_restrictions` (`editfns.c:2840`, called from
`xdisp.c:17440`) makes every active labeled restriction invisible for
the duration of a redisplay - "if a Lisp function executed during
redisplay calls (redisplay) while labeled restrictions are in effect,
these restrictions will not become visible on display". The C bounds it
with a specpdl unwind; the port is `%with-outermost-restrictions`, a
`dynamic-wind` around `redisplay-frames!`'s body, and it restores from
the *current* innermost markers on the way out (a hook run during the
redisplay may have pushed or popped one), not from what was saved.

## The two macros are a placement departure

`with-restriction` and `without-restriction` are `subr.el:4571`/`:4590`,
but their bodies call `editfns.c`'s two `internal--labeled-*` DEFUNs and
`subr.scm` is *below* `editfns.scm`. They live in `editfns.scm`, beside
the functions they call, with the departure named in the source. The
`:label` keyword is a `syntax-rules` literal, matching the Elisp macro's
`(eq (car rest) :label)` test.

## The cleanup seam

`Ferase_buffer` calls `labeled_restrictions_remove_in_current_buffer`
*before* `Fwiden` (`buffer.c:2490`) - the labels must go first, because
with one in effect "widen" means the label's bounds, not the text's.
`erase-buffer` is `buffer.scm`, below `editfns.scm`, so the call comes
through `*labeled-restrictions-remove-function*`, a seam `editfns.scm`
installs at load. Its default does nothing: a session that never loads
`editfns` has no labeled restrictions either, so the default is the
right answer rather than a silenced failure.

**The other C call sites are not applicable here**: `fileio.c:5601` is
`write-region` (this tree writes a buffer's whole text and never widens
to do it), `lread.c:2250` is `readevalloop` (this tree's `eval-region`
reads from a string), `indent.c:2130` is `display-line-numbers`' widened
count (not carried), and `callproc.c`/`treesit.c` have no counterpart.

## The measured table

Every row is `emacs -Q --batch`'s answer on `"a\nb\nc"` (point-max 6):

| | Emacs 31.1 | port |
|---|---|---|
| `(with-restriction 2 6 ...)`, then after | (2 6), (1 6) | same |
| `narrow-to-region 1 5` inside a 2..6 label | (2 5) | same |
| `narrow-to-region 1 7` inside it | args-out-of-range | same |
| `(widen)` inside the label | (2 6) | same |
| `without-restriction` same label / other label | (1 6) / (2 6) | same |
| nested 3..5 inside 2..6, inside then after | (3 5), (2 6) | same |
| `save-restriction` + `widen` inside, inside/after | (2 6), (2 6) | same |
| `erase-buffer` inside, then min/max/narrowed-p | (1 1 nil) | same |
| point at 6 pulled into 2..4 | (4 2 4) | same |
| plain form + `widen` | (1 6) | same |
| label inside a user narrowing | (3 5), (2 6) | same |
| after `without-restriction` pops the outermost, `widen` | (1 6) | same |

`editfns-tests.scm` has all of them (`schemacs_editor_editfns_labeled`,
15 tests), plus the redisplay bracket's contract - which has no
Emacs-level test because only redisplay runs the C.

# The difference engine, `lib/diffseq.h' (2026-11-18)

`schemacs/editor/diffseq.scm` ports gnulib's `lib/diffseq.h` - the Myers
O(ND) engine `editfns.c` includes for `replace-region-contents`. **This
is the engine only**; the DEFUN over it, the `replace_range` extension
it needs and the `subr.el` callers are the next step (AGENTS.md has
their recon).

## The shape, and the one representation decision

`diffseq.h` is a header parameterised by seven macros. Each becomes an
explicit parameter:

| the C | here |
|---|---|
| `ELEMENT`/`EQUAL` | `equal` field: a procedure `(x y) -> boolean` |
| `NOTE_DELETE`/`NOTE_INSERT` | `note-delete`/`note-insert` procedures |
| `EARLY_ABORT` | `early-abort`: a thunk |
| `OFFSET`/`OFFSET_MAX` | exact integers (`offset-max` is `PTRDIFF_MAX`) |
| `EXTRA_CONTEXT_FIELDS` | not in the engine: the caller closes over its own state in the four procedures |
| `fdiag`/`bdiag` arrays | scheme vectors plus the index of diagonal 0, since the C indexes the middle of an allocation with negative diagonal numbers |

**The C's `sys_setjmp`/`sys_longjmp` early abort is the caller's
`call/cc`.** `editfns.c`'s `buffer_chars_equal` escapes to it when the
time limit passes; the engine only observes that EQUAL did not return.
`%diag` also uses a one-shot continuation for the C's `return` from
inside its two nested loops - once per partition, not per character.

Character equality that is **not** `equal?`-shaped (Emacs compares
already-extracted code points) stays the caller's business: the engine
never looks into the vectors itself.

## The trap, recorded before it could be repeated

The C's two "best diagonal" searches declare `fxybest`/`fxbest` and
`bxybest`/`bxbest` in the *same* enclosing block, and the final `if`
reads all four. In Scheme that is one `let` with four bindings. Three
attempts failed on this: two `let`s read as siblings still leave the
second's `let`-bound names invisible to the `if`, and the parens of the
first version were laid out for the wrong nesting. The method that
worked, and the one the next session should use for anything of this
size: **write the two functions to a scratch file with stub accessors,
compile and run them there, and only then assemble the library** - the
library file is the verified block plus the record definitions, joined
by script, not retyped.

## Verification

The engine's contract is checked without Emacs, because it has no Lisp
interface:

- **apply-equality**: the recorded script, applied exactly as
  `replace-region-contents`' loop applies it (walk backwards, replace
  each run, keep every unmatched character - including the one the C's
  post-run `--i; --j` steps past), rebuilds the second vector.
- **minimality**: with the default `too-expensive` no heuristic fires
  at these sizes, so the script's cost must equal the textbook DP
  edit distance.

Eight fixed pairs and **400 seeded random pairs** over a three-letter
alphabet pass both. Two further cases force the heuristic paths: a
`too-expensive` of 5, and a 250-character pair sharing a 40-character
tail (the `big_snake` search); both must still apply. `diffseq-tests.scm`
is in `tools/run-suites.py`.

# `replace-region-contents`, and the `replace-match` bug under it (2026-11-18)

The DEFUN is in `editfns.scm`, over the `diffseq.scm` engine landed
before it; `replace_range` grew the C's buffer and `[BUFFER BEG END]`
NEW forms; and `replace-buffer-contents`, `replace-string-in-region`
and `replace-regexp-in-region` (`subr.el:4948-5040`) are in
`replace.scm`.

## What the DEFUN does, and the readings it takes

- **SOURCE** is a string, a buffer, a `[BUFFER BEG END]` vector, or a
  function called with the buffer narrowed to BEG..END. A string's
  characters are read straight from the string, a buffer's with
  `buffer-text-ref` from its accessible portion, and a vector's after
  `validate-region` in that buffer's own context (`parameterize` on
  `*current-buffer*`, the C's temporary `set_buffer_internal`).
- **The trivial paths** - either side empty, `MAX-SECS 0`, `MAX-COSTS
  0` - are the C's: one `replace_range` of the source, answer t.
- **The diff** compares two vectors of code points (properties ignored,
  as the C's `buffer_chars_equal` ignores them), records deletions and
  insertions in two bytevectors with the C's bit arithmetic
  (`set_bit`/`bit_is_set`), and the escape out of the engine is
  `call/cc` - taken every 65536 comparisons after `maybe-quit`, and at
  each `EARLY_ABORT` check, when the `MAX-SECS` deadline passes.
- **The apply phase** walks backwards as the C does, replacing each run
  with a `replace_range` of the source slice, inside one
  `prepare_to_modify_buffer`/`inhibit_modification_hooks` bracket with
  one `signal_after_change` at the end - unless the caller had already
  inhibited the hooks. `Fundo_boundary` is the
  `text-editor-undo-boundary!` call before it.
- **A string source's slice** is `(substring source j (1- end-b))`:
  `j`/`end-b` are Emacs buffer positions (1-based), `substring` counts
  from 0. The first probe used `end-b` as it stood and asked for one
  character past the source; the fix is the `1-`.

## The `replace_match` bug this exposed

`replace-regexp-in-region` with `\2\1` answered `b1` where Emacs
answers `1a` for the first match of `a1`: `%substitute-replacement` -
`replace-match`'s **buffer** path - added one to every register before
slicing (`(+ 1 (car pair))`), a leftover from before the 2026-10-05
conversion to Emacs's one-based coordinates. The string path was
already right (its registers are zero-based), which is why nothing had
noticed: the tree's own replace tests exercised the string path and
`perform-replace`'s typed replacements, not a buffer `\N`.

Fixed at the source (the C hands `Fbuffer_substring` the registers as
they stand), with two `search-tests` regressions - `\&` and `\2\1` -
whose expectations are `emacs -Q --batch`'s. This is the file's oldest
lesson again: the new caller was a correct port, and it failed because a
primitive underneath did not do what the C does.

## The measured table

Every expectation in `replace-tests.scm`'s new block is
`emacs -Q --batch`'s own, measured first:

| case | Emacs 31.1 | port |
|---|---|---|
| point at END / before BEG / inside, replacing 7..12 with "there" | (t "hello there" 12) / (t ... 1) / (t ... 7) / (t ... 10) | same |
| buffer source / `[buf 3 5]` vector | (t "xxAAbbCCxx" 11) / (t "xxbbxx" 7) | same |
| empty replacement / `MAX-SECS 0` / `MAX-COSTS 0` | (t "abc" 2) / (t "aXYc" 2) / (t "aXYc" 2) | same |
| two hunks / function source | (t "abc123def456ghi" 16) / (t "aQc" 4) | same |
| buffer as its own source | error "Cannot replace a buffer with itself" | same |
| `replace-string-in-region` | (2 "XX"), (nil "abcabc"), (1 "ABCX"), the two range errors | same |
| `replace-regexp-in-region` | (2 "a#b#c"), (2 "1a2b2c"), (nil "xyz") | same |
| `replace-buffer-contents` | (t "axc") | same |

## Named gaps

- A **byte character** in a buffer source renders as U+FFFD through
  `buffer-text-substring` (the tree's named departure) when it is
  inserted; nothing replaced here holds one yet.
- The C's temporary work buffer for a string source is not made - the
  string's characters are read directly, which is the same comparison
  and the same insertions.
- `MAX-SECS` is compared as a floating-point deadline
  (`float-time (current-time)` against `lisp_time_arguments`), where
  the C compares timespecs exactly.
- `replace_range`'s vector form checks nothing of its own beyond the
  buffer's type; its only maker is the DEFUN, which validated the range.

# `substitute-command-keys`, `key-valid-p` and `documentation` (2026-11-18)

The help primitives the disabled-command prompt stands on, in two new
libraries: `help.scm` (help.el's) and `doc.scm` (doc.c's reader half).

## What is carried

- **`substitute-command-keys`** (`help.el:1435`), cases 1A-1D and the
  quote rules, with the C's in-place buffer walk (a temporary buffer,
  every branch editing it) rather than a string accumulator - a `\=`
  deletes two characters and a failed ``\`KEY'`` substitution has to
  leave the backtick for the quote rule on the next pass, and a string
  walk would re-implement that bookkeeping. `\[COMMAND]` resolves
  through `where-is-internal` in the *user's* buffer (remembered as
  `orig-buf`, as the C's `with-current-buffer` does), and both
  substituted forms get the `face` **and** `font-lock-face`
  `help-key-binding` properties, as the C adds both.
- **`substitute-quotes`** (`help.el:1578`) and the two faces it and the
  key substitution use: `help-key-binding` and its `:inherit` target
  `fixed-pitch`, both from faces.el.
- **`key-valid-p`** (`keymap.el:328`) - **a placement departure**: it is
  `keymap.el`'s, but it is a string matcher (`string-match-p`,
  `split-string`), and both live above `keymap.scm`; `help.scm` is the
  first library that wants it. Every string here is multibyte, so the
  C's `multibyte-string-p` arm is always true.
- **`documentation`** and **`documentation-property`** (`doc.c:333`,
  `:430`), including `documentation`'s `substitute-command-keys` run
  unless RAW. A command's docstring is the record's
  (`command-doc-string`), where `define-command` stores it; a symbol
  that names nothing is `void-function` and a non-function is
  `invalid-function`, both measured on Emacs.

## Not carried, named

- **`\{MAPVAR}` and `\<MAPVAR>`** - the keymap summary and the "use
  this map" form. The summary is `help--describe-map-tree`, the
  describe-bindings machinery (`C-h b`'s), which this tree has not; the
  forms are left standing, and the walk moves past them as it does past
  an unquoted non-key.
- `help-link-key-to-documentation` / `help-mode--add-function-link` -
  both gated on `help-buffer-under-preparation`, which nothing sets, so
  Emacs takes the same fallback (the plain fontified key).
- doc.c's DOC file (`get_doc_string`, `Snarf-documentation`): a
  docstring lives on its procedure here, and a variable's on its
  `variable-documentation` property (where `define-custom` puts it).

## The measured table

Every expectation in `help-tests.scm` (16) is `emacs -Q --batch`'s own:
the thirteen-string `key-valid-p` table; `"abc"` unchanged;
`\[narrow-to-region]` → `"C-x n n"`; `\[no-such-command]` →
`"M-x no-such-command"`; ``\`C-x'`` → `"C-x"` with both face properties
at the key's offset; the invalid ``\`not-a-key'`` → `"x\‘not-a-key’"`
under `curve` (the backslash stands, the quotes convert - the C's walk
leaves the backtick for the quote rule); a trailing backslash stands;
`\=` at end stands; `a\=b` → `"ab"`; `\=\[` → `"\["`; the three quoting
styles; `substitute-quotes`; and `documentation`'s substituted-vs-RAW
pair on `narrow-to-region`'s own docstring.

# The disabled-command machinery (2026-11-18)

`novice.scm` (novice.el), the check in `command.scm`'s `run-command`
(the tree's `command-execute`, `simple.el:2811`), the
`command-query`/`command-execute--query` pair, and rmc.el's
`read-multiple-choice--from-minibuffer` - the arm Emacs actually takes
for `novice.el`'s prompt. `C-x n n` now asks "Use this command?" before
it narrows, and `C-x n p` likewise.

## The shape

- **The check** is `run-command`'s first act: a command whose `disabled`
  property is set is handed to `disabled-command-function` (plain t) or
  asked about (`(query VERBOSE PROMPT)`), and only then run - through
  `%run-command`, which `novice.scm` calls back through as Emacs's
  `call-interactively` does, so the command the user just approved does
  not ask again.
- **Both halves are seams**, because the askers (`y-or-n-p`,
  `yes-or-no-p`) live above `command.scm`: `*disabled-command-function*`
  and `*command-execute--query-function*` are parameters there, and
  `novice.scm` installs both as it loads. With neither installed the
  machinery is off - Emacs's own `disabled-command-function` of nil.
- **`commmand-query` is a placement departure**: `simple.el`'s, beside
  the `run-command` check that reads it.
- **The markers**: `(put 'narrow-to-region 'disabled #t)` in
  `editfns.scm`'s narrow-map section (bindings.el:1111's home here) and
  `(put 'narrow-to-page 'disabled #t)` in `pages.scm` (page.el:127).

## rmc.el's minibuffer arm, and the bug it found

`novice.el` passes HELP-STRING and SHOW-HELP but no LONG-FORM, so
Emacs takes `read-multiple-choice--from-minibuffer` (its
`read-char-choice-use-read-key` and `use-dialog-box-p` are both nil).
That arm is ported: a keymap built from the shared minibuffer
bindings, each choice's key bound to a command that records
`last-command-event` and exits, `?`/C-h for the help, `[remap
self-insert-command]` for the refusal.

**The bug it exposed**: the choices hold *characters* in this tree
(the callers write `(list #\y "yes")`) where Emacs holds `?\y`
integers, so the command must convert `last-command-event` with
`integer->char` before `assq`ing it - without that every answer looked
like a refusal (`(assq 32 '(#\space ...))` is false), and the first
"refusal" that seemed to work was an error in the caller's `char=?`
taking the error path. Measured, then fixed; the pty check pins SPC,
n and `!`.

## Not carried, each named

- **`en/disable-command`'s init-file write.** Emacs edits the
  `(put 'CMD 'disabled X)` line out of `user-init-file` and appends a
  new one. This tree's init file is Scheme, so the line would also need
  an `(import (schemacs editor intervals))`, and finding the file is
  `startup.scm`'s path discovery - the *session* effect (the `put`) is
  carried, which is what the user sees; `startup.scm` gained
  `*user-init-file*` for the day the write half is done.
- **`ding`** (rmc's wrong-key bell): the "Invalid choice" message is
  the report.
- **The help buffer is not killed on the way out** (`rmc.el:384`'s
  `unwind-protect`): the next prompt of the same name empties and
  reuses it.
- **The modal/dialog arm** (`--short-answers`), for the two switches
  above that have no counterpart here.
- `enable-recursive-minibuffers` and the text-conversion style in the
  minibuffer arm - neither exists.

## Verification

`novice-tests.scm` (7): the property both ways, an unknown name's
error, the hook path, hook-nil-means-off, the query form's two
answers, and `%run-command`'s bypass. The pty battery gained
`disabled-command` (n refuses, SPC runs once, `!` enables for the
session) and `narrow` now answers the prompt it pins.

# `C-h b`: `describe-bindings` and the tree beneath it (2026-11-18)

GNU Emacs's chain for the first of the help commands is
`describe-bindings` (help.el:849) -> `describe-buffer-bindings`
(keymap.c:2834) -> `help--describe-map-tree` (help.el:1638) ->
`describe-map` (help.el:1770) -> `help--describe-vector`
(keymap.c:3074) -> the static `describe_vector` (keymap.c:3147). What
is ported, and the departures it carries, in the order a reader meets
them.

## `lookup-key` and `keymapp` (keymap.c:1264, :3012)

`lookup-key` is `lookup_key_1`'s walk, with ACCEPT-DEFAULT's rule:
a specific binding wins, and `(t . DEF)` is the fallback - but the
`t` entry is the *specific* binding when the event asked for is the
symbol `t` (`EQ (key, idx)` comes before `(t_ok && EQ (key, Qt))` in
`access_keymap_1`). Measured in a probe, all four cases:

| call | answer |
|---|---|
| event `f1` without ACCEPT-DEFAULT | nil |
| event `f1` with ACCEPT-DEFAULT | the `(t . DEF)` binding |
| event `t` without ACCEPT-DEFAULT | the `(t . DEF)` binding |
| a map with no default, ACCEPT-DEFAULT | nil |

**KEYMAP as a list of maps** is supported (the docstring's "KEYMAP can
also be a list of keymaps"), in the C's order: a specific binding in
any map wins, the *earliest* map's default is the fallback.

**Not carried**: `possibly_translate_key_sequence` (there is no
keyboard-translate-table here) and the menu-bar case-folding
compatibility below the DEFUN (nothing here builds mixed-case menu
symbols).

`keymapp` is the record test. The C also answers t for a *symbol*
whose function definition is a keymap; a symbol has no function here
(`access-keymap`'s note says the same).

## `get-local-map` (intervals.c:2176)

Ported into `editfns.scm` - a **placement departure**: its two readers
are `get-char-property` (`textprop.scm`) and `get-pos-property` (this
library), and `intervals.scm` is below both. The C's widening around
the two lookups is not carried because this tree's property readers
take an absolute position and do not consult BEGV/ZV, so there is
nothing to widen around.

## `describe-map` has no vector half

Emacs keeps ordinary-character bindings in a keymap's char-table or
vector and walks them with `help--describe-vector`; every binding,
character events included, is a sparse entry in this tree's keymap
record, so the sparse walk covers them all. The vector half's own
rules - the suppress test, the shadow test, the range merge - are the
same rules the sparse walk applies.

**The visible cost**: the char-table slot here is a *procedure* (the
self-insert fallback), which nothing can enumerate. So `C-h b` lacks
Emacs's `SPC .. ~  self-insert-command` row. This is the same
deviation `map_keymap_internal` records, showing through the help
buffer; closing it means giving `<keymap-type>` a describable
representation for its fallback range, which is the representation
change that note has always been about.

`(eq definition (lookup-key map (vector event) t))` - the C's "ignore
this definition if it is shadowed by an earlier one in the same
keymap" - is carried but is vacuous for a hash-keyed map: an event
appears once.

## `describe-buffer-bindings` is in `help.scm` (keymap.c:2834)

**A placement departure**: its whole body is calls to
`help--describe-map-tree` plus the buffer state each section shows.

The sections this tree can back: `overriding-terminal-local-map`,
`overriding-local-map`, the `keymap` text property, each minor mode's
map (`*minor-mode-map-alist*` with `buffer-local-value`), the buffer's
own map (headed by the major mode's name), and `Global Bindings`.

**Not carried, and why**:

- the **keyboard-translate-table report** - there is no such table;
- the **`key-translation-map` section** - no such variable here;
- the **`input-decode-map` section** - it is the *terminal's*
  (`xterm.scm`), which no editor library may import;
- **`local-function-key-map`** - this tree's counterpart is
  `*function-key-map*`, an alist of translations, not a keymap, so
  there is nothing `help--describe-map-tree` can walk.

Measured against Emacs 31.1 for the same crafted local map, the local
section is character for character the same (entries, order, tab
padding, the `C-c x` sub-entry in its own block). The separator line is
the blank-line form on both: `emacs -nw` answers t to
`(display-supports-face-attributes-p '(:underline t))` (measured in a
pty), where `--batch` answers nil and prints dashes - which is why a
batch differential shows dashes in Emacs's output and not here.

A map with **no bindings** gets no section, in Emacs and here: a `.txt`
buffer's text-mode map contributes no heading (measured on Emacs).

## `help--describe-command`'s translation branch writes ASCII only

`char-to-name` (`mule-cmds.el`) needs the Unicode name table, which is
not carried, so the translation branch prints the key description
alone where Emacs adds a tab and the character's name. Nothing in this
tree reaches that branch yet (it needs a key-translation map).

## `help-fns-function-name` without buttons

Emacs's returns a *buttonized* string (an xref). The xref machinery is
not carried, so the answer is the plain name: a symbol's name, a
command's name from its record, `#<procedure NAME>` for a named
procedure, `#<procedure>` for an anonymous one - this tree's shapes,
since a keymap's binding is a procedure or a command record here and
never a subr.

## `with-help-window`, `help-buffer`, `help-setup-xref`

`help--window-setup` carries the C's nesting including
`inhibit-read-only` around the body (a help command inserts into a
read-only buffer), and `temp-buffer-window-show`'s tail
(`window.el:113`): unmodified and read-only, point at `point-min`
*before* the display, then `display-buffer` and the window's hscroll
reset to 0. The point-before-display step is what makes the help
window open at the top; without it the window showed the buffer's end
(the point the inserts left).

**Not carried**: `help-window-point-marker`, the
`temp-buffer-window-setup-hook` run, `help-make-xrefs` (no buttons),
`buffer-disable-undo` (undo is not on in a fresh buffer here),
`help-window-setup`'s reselect rules, and the xref stack in
`help-setup-xref` (the item is recorded; there is nowhere to push a
stack). `describe-bindings-outline` and its outline-mode setup are not
carried either, and with them the hiding of the ^L separators.

`help-buffer`'s `help-xref-following` is a **plain variable** here
(Emacs `setq`s it; nothing `let`-binds it) - and reading it as a
parameter cost a round of "Wrong type to apply: #f".

## `help-mode`

The mode and its map only: `special-mode`'s parent map gives `q`,
SPC/DEL, `<`/`>` and `g`. Emacs's own entries (n/p/l/r, C-c C-b/f,
s/I/i/c) name the xref, info and customize commands that are not
carried, as are the context menu, the tool bar, bookmarks, the
composite `:parent` (no `make-composed-keymap` here) and
`help-mode-revert-buffer`.

**The seam**: `help-mode` is installed into `*help-mode-function*` as
`help-mode.scm` loads, because help-mode.el requires help.el and the
mode is above it. **A front end must import `(schemacs editor
help-mode)` for `C-h b` to land in the mode** - both do now - which is
Emacs's autoload in this tree's spelling. A unit test that imports
only `help` gets an unmoded `*Help*`, correctly.

## `make-separator-line` (simple.el:760)

Ported into `simple.scm`. Its terminal branch pads to `(window-width)`,
which here is `window-body-width` - **this tree's `window-width` is the
window record's slot accessor**, not window.c's DEFUN, so the Elisp's
call has to be spelled differently in both this function and
`describe-map--align-section`. A naming collision worth knowing about.

## The `C-h b` key is flat

`help-map` exists as Emacs's object with `b` in it, and the key the
command loop finds is the flat `C-h b` - the standing submap
departure (`narrow-map`, `mule-keymap`). The rest of `help-map`'s
entries name commands this tree does not have yet.

## Verification

`help-tests.scm` grew 8 checks (23 passes): the comparator's six cases,
`help-fns-function-name`'s two shapes, `describe-map`'s exact text, the
local section character for character, `describe-bindings`'s `*Help*`
in help-mode and read-only, the window it goes to, and `C-h b`'s
binding. The pty battery gained **`help-bindings`**: `C-h b` shows
`Global Bindings`, the column heading and the first sorted rows, gives
no section to an empty map (Emacs's own answer), and `C-x o q` closes
the help window.

Probe traps this pass paid for: `*overriding-terminal-local-map*` is a
plain variable (calling it applies a list); `(not '())` is false, so
every Elisp `(null x)` must be `null?` in this tree - a `(not shadow)`
test silently skipped every section; and `(/=` does not exist in this
Guile at all.

# `C-h k`, `C-h f`, `C-h v` - describe-key and the describe-fns half (2026-11-18)

## The bug this pass found in `read-key-sequence`

`%read-key-sequence` (`keyboard.scm`, the body behind the `k`/`K`
interactive codes) **answered `#f` for every call**: the sequence is
built inside the three callbacks it hands `modal-lookup-state-step!`,
and their return values are discarded - the step answers only "was the
chord finished?". `C-h k` is the first caller that used the answer, and
it described `#f runs the command ...`. The sequence now goes in a
variable the callbacks set and the procedure answers. Anything else
using the `k` code was silently getting `#f` too.

## `describe-key` (help.el:1197)

Ported: `help--binding-undefined-p`, `help-key-description`,
`help--analyze-key`, `help--filter-info-list` and the command, with the
C's "several key-sequences" header and the per-key description.

**Not carried**:

- `help--read-key-sequence`'s menu/mouse reading with disabled items
  enabled; the interactive spec reads one sequence with
  `read-key-sequence`, which is this tree's whole input pipeline.
- the `(found in global-map)` locus (`help--binding-locus`), and the
  `mouse-on-link-p`/`mouse-1-click-follows-link` note - there are no
  link properties here.
- `char-to-name`'s "(translated from ...)" character-name branch.
- the C's surgery on a string *event* (`(any string)`) - this tree's
  menus have no such entries.
- `describe-key-briefly` (`C-h c`) and `help--describe-command`'s
  command branch for keyboard macros' key descriptions: `c` is not
  bound and not ported.

`describe-function-1` is reached through `*describe-function-1-function*`
- help-fns.el is above help.el, exactly as in Emacs, where the call is
an autoload.

## `describe-function` (help-fns.el:298, :1228)

**The data model blocks three of Emacs's sections**, and each is named
in the library header:

1. **the usage line** `(forward-char &optional N)` - from
   `help-function-arglist`. A Scheme procedure has no arglist to read:
   its name is all Guile keeps. `help-split-fundoc`,
   `help--make-usage-docstring` and `help-highlight-arguments` are not
   carried. This is the largest visible difference: Emacs's
   describe-function output has the usage line between the binding and
   the docstring.
2. **the file/line xref** - `find-lisp-object-file-name` has no
   counterpart, so the header says "is an interactive command" where
   Emacs says "is an interactive primitive-function in ‘C source
   code’".
3. **aliases, autoloads, macros, advised functions, subrs** - none of
   these shapes exist here, so `help-fns--analyze-function` answers the
   definition alone where Emacs answers
   `(REAL-FUNCTION DEF ALIASED REAL-DEF)`, and the header's arms are
   keymap / keyboard macro / interactive command / function.

Carried whole: `help-fns--key-bindings` (all-keys through
`where-is-internal`, the menu split, the ten-non-modified-keys rule,
the `self-insert-command` special case, filling), `help-fns--obsolete`
(reading `byte-obsolete-info`, which nothing sets yet),
`help-fns--ensure-empty-line`, `help-fns--insert-bindings`, and
`ensure-empty-lines` (`subr.el:7914`, placed in help-fns.scm because
its `re-search-backward` is above subr.scm).

**Not carried**: `help-fns--insert-menu-bindings` (the menu walk; the
sentence "It can also be invoked from the menu." stands in),
`help-fns-describe-function-functions` hooks and the
parent-mode/compiler-macro/generalized-variable entries, the
`help-enable-autoload` docstring scan, the type inference, and
`help-fns--setup-xref-backend`.

`key-binding` grew its ACCEPT-DEFAULT argument (and so now answers the
"too long" number, as the C's `Flookup_key` does) so
`help--analyze-key`'s `(key-binding key t)` is the C's call.

## `describe-variable` (help-fns.el:1356)

**Only custom variables can be described.** A variable here is a Scheme
binding; a symbol reaches only the ones `custom-declare-variable`
recorded, and they carry their docstring, standard value and reader on
the symbol. What is printed is Emacs's shape - "NAME's value is VALUE",
"Documentation:", "You can customize this variable." - with
`(format "%S" value)` as the prin1.

Note that the *symbol* carries the asterisks this tree's convention puts
on parameters (`*search-ring-max*`), so the prompt and the printed name
differ from Emacs's for every custom option - a departure of the custom
machinery, not of describe-variable.

**Not carried**: buffer-local and frame-local values (no such bindings
here), `variable-binding-locus`/`find-lisp-object-file-name`, the
`:risky`/`:safe` confirmation, the "saved value" section (nothing
writes `saved-value` yet), customize buttons, `describe-symbol`,
`describe-command`, `variable-at-point` and the default at the prompt
(they need elisp-mode's `function-called-at-point`, which needs the
reader).

## Keys

`C-h k`, `C-h f`, `C-h v` are flat bindings on `*default-keymap*` and
entries in `help-map`, as `C-h b` is. Both front ends import
`(schemacs editor help-fns)` - the library binds the keys and installs
the `describe-key` seam.

## Verification

`help-tests.scm` 29 (the describe-function phrases, describe-variable's
value/doc/customize lines, describe-key's "runs the command", the
undefined-key analysis, the filter, and the five key bindings). The pty
battery gained **`help-describe`**, which drives all three keys through
the real command loop. One trap in writing it: `C-f` in the output is
fontified with `help-key-binding`, so the raw byte stream has escape
sequences *inside* "It is bound to C-f." - assert on the plain runs.

# `\{MAPVAR}`, `C-h c`, `C-h w` - the rest of substitute-command-keys and two echo commands (2026-11-18)

## `\{NAME}` and `\<NAME>` are carried, with a named stand-in for `symbol-value`

The 1E form needs Emacs's `(symbol-value NAME)` - and this tree has no
variable namespace, by decision (`command.scm`'s note: "There is no
universal registry here, and none is wanted"; each subsystem keeps an
index and hands the reader out - `custom-declare-variable` keeps
`custom-reader` on the symbol for exactly this reason).

So the index is the **keymap's own label**: `make-sparse-keymap` already
takes a name, every library keymap in this tree is made with the
symbol `'*name-map*`, and the record's own comment calls the label "the
name `define-key` and the mode machinery use to tell one map from
another". `keymap.scm` now registers each labelled map in
`*keymap-name-table*`, **under the label and under its star-stripped
spelling** - because Emacs's docstrings name the *variable*
(`\{help-mode-map}`) and this tree's labels carry the parameter
convention's stars. `keymap-by-name` answers the map.

Consequences, named:

- `\{special-mode-map}` substitutes the same table `C-h b` shows for
  that map, range merging included - measured in help-tests.
- A map whose label is a *string* (`help-map`'s "Help", the menu maps)
  is not reachable by a `\{name}`; Emacs's variables would be. Nothing
  in this tree's ported docstrings names one.
- Nothing sets a label after construction (`set!keymap-label` has no
  caller), so nothing can miss the registry.

The unresolved message is Emacs's own:
"Uses keymap \`NAME', which is not currently defined."
(`substitute-quotes` applied, as the C applies it).

`\<NAME>` sets the map `\[COMMAND]` is looked up in, and `\[` now
consults it first - `where-is-internal fun (and keymap (list keymap)) t`,
then a second pass without the keymap when that finds nothing -
`override-local-map` initialises it, as the Elisp's `let` does.
Measured: `\<test-map>\[cmd]` answers the key in that map even though
the global map binds the command elsewhere.

## `C-h c` `describe-key-briefly` (help.el:1029)

A direct port over `help--analyze-key` and `help--filter-info-list`.
**The C's `INSERT` argument is `insert-flag` here**: a parameter named
`insert` shadows `editfns.scm`'s `insert` in a Lisp-1, the same
renaming `minibuffer-message`'s TEXT took. Measured outputs:
"C-f runs the command forward-char" and the insert form the same.

**Not carried**: `help--read-key-sequence`'s mouse-movement filter (the
read cannot produce one without `track-mouse`).

## `C-h w` `where-is` (help.el:897)

Ported: `where-is-internal` over `overriding-local-map`, the
"(KEYS)" / "is not on any key"'s replacement "M-x NAME RET" lines, the
remapping sentence, and the insert form.

**Not carried**: the alias scan (`mapatoms` over the obarray - the
command table's second names share the record; they will come back the
day an alias list is exposed), and `function-called-at-point`'s default
at the prompt (needs elisp-mode's reader). The interactive prompt is
`read-command`'s.

## Two bugs this increment found, both the tree's old hazards

1. **The missing-import class, again**: `where-is`'s interactive
   expression is evaluated in *its defining library's module*
   (`help.scm`), which did not import `read-command` - so `C-h w` raised
   "Unbound variable: read-command" into the echo area, the command did
   nothing, and a pty check's keys went into the buffer. This is the
   third time the rule has bitten: **a command's interactive expression
   can only use names its own library imports**.
2. **`(insert ...)` shadowed by a parameter named `insert`** - the
   Lisp-1 wall, fixed by the rename above.

## Verification

`help-tests.scm` 35 (the 1E substitution of `special-mode-map` including
`0 .. 9`, the unresolved-map message, `\<map>\[cmd]`, the star stripping,
and the two commands' exact strings and five bindings). The pty
`help-describe` check now drives `C-h k`, `C-h c` and `C-h w` too, with
Emacs's long read prompt ("Describe the following key, mouse click, or
menu item: ") which `C-h k` shares.

# `C-h m` `describe-mode`, and the minor-mode lists under it (2026-11-18)

## `local-minor-modes` and `global-minor-modes`

`describe-mode` reads the two lists Emacs keeps of the enabled minor
modes: `local-minor-modes` is `DEFVAR_PER_BUFFER` (`buffer.c:5249`) and
`global-minor-modes` a `defvar` (`subr.el:3200`), and **the generated
command of `define-minor-mode` is what maintains them**
(`easy-mmode.el:368-376`: an `add-to-list` when on, a `delq` when off).
The tree had neither list; `define-minor-mode` now keeps them, in the
C's shape - the buffer's slots for a local mode, `*global-minor-modes*`
(a parameter, like its sibling `*minor-mode-list*`) for a `:global`
one.

**One spelling difference**: the C stores the mode's *function* symbol;
here the list holds the mode's *symbol*, because that is what
`minor-mode-alist` is keyed by and what `documentation` finds the
mode's command record from.

## `describe-mode` (help-fns.el:2223, :2312)

Ported: the local-minor-modes line, the major mode's name and
documentation (its `\{mode-map}` now substitutes - the 1E form is what
this needed), the global-minor-modes section, and
`describe-mode--minor-modes` with the C's pretty-name rule, the
form-feed page breaks, the indicator line (through xdisp's two
evaluation steps, now exported) and the final paragraph fill.

**`describe-mode-outline` is t, Emacs 31's default** (`help-fns.el:2216`),
so the default output is the outline variant: a "Major mode %S"
heading, "The major mode is NAME mode:", and a "Local minor mode %S"
heading per minor mode - carried as text and with the heading's
`outline-level` property. What is *not* carried is `outline-minor-mode`
itself (the folding), because there is no outline mode here; the
properties are inert data. With the option off, the C's other layout
(the "Minor mode enabled in this buffer:" sentence and the `` page
breaks) is the one printed.

**Also not carried**: the file/line clause, `help-fns--list-local-commands`
(it needs `mapatoms` and `command-modes`), buttons, and
`help-split-fundoc` (no usage lines here).

Measured: a text-mode buffer with `auto-fill-mode` on describes as
"The major mode is Text mode:" plus the mode's documentation, and
"Minor mode enabled in this buffer: Auto Fill minor mode (indicator
Fill):\n..." - the same sentences Emacs prints.

## The two environment traps this cost

1. **`delq` was not imported into `easy-mmode.scm`.** The macro's
   template resolves identifiers in the *expanding* library, and under
   interpretation an unimported core binding is "Unbound variable:
   delq" - while the same tree with a warm compile cache ran fine
   (psyntax had resolved it in the compiled image). The suite runner
   uses a fresh `XDG_CACHE_HOME`, so it runs everything interpreted and
   caught what a direct `guile -s` did not. **When the runner and a
   direct run disagree, believe the runner: it is the source build.**
2. **A macro change needs every *user* of the macro recompiled.** After
   `define-minor-mode` gained the list maintenance, `auto-fill-mode`
   still behaved the old way because `fill.scm`'s `.go` had the old
   expansion baked in - the source was unchanged, so `--no-auto-compile`
   happily loaded the stale image. The cure is the tree-wide sweep
   (`find schemacs -name '*.scm'` through `compile-file`), not deleting
   the cache.

# `C-h s` describe-syntax, and describe-vector over a char-table (2026-11-18)

## `describe-vector` is in `help.scm`

**A placement departure**: the C DEFUN is `keymap.c:3042`, but its body
inserts into the current buffer and walks the char-table with this
tree's `chartab.scm`, so it lives beside the other describers. It
carries the C's static `describe_vector`'s **char-table path**: the
two-pass walk (`MAX_5_BYTE_CHAR` then the eight-bit range),
`char_table_ref_and_range` for each run, the `" .. "` range rows, the
`indent_to (16, 1)` + describer + newline, and the final `default` row.

**Only the char-table path is carried.** The C's vector path is for
Lisp-visible plain vectors used as keymaps; this tree's keymaps are
records and its key walk already covers them (`describe-map`'s sparse
walk).

**The C's `Findent_to (16, 1)` is `indent-to`** (`indentc.scm`), which
means the padding is a *column* count - and that is where one of the
two measured differences in `C-h s`'s output comes from: for the raw
C1 characters Emacs counts them two columns wide and this tree one, so
one row's tab count differs. A width question in the column machinery,
not in the describer.

## `internal-describe-syntax-value` is in `help-fns.scm`

**A placement departure**: `syntax.c:1305`'s DEFUN, but it inserts into
the current buffer and its last line calls `substitute-command-keys` -
both above `syntax.scm`. The flag readers it needs
(`SYNTAX_FLAGS_*`, `syntax.c:61`) are exported from `syntax.scm` for it.

## `describe-syntax` (help-fns.el:2027)

A direct port: the buffer's `syntax-table`, `describe-vector` with the
describer, then each parent table under "The parent syntax table is:".

Measured against Emacs 31.1 on the standard table: **the first three
dozen rows are byte-identical**, including the range merging
(`C-@ .. C-h`), the tab padding and the `( )` matches text. Two
classes of difference remain, and neither is the walk:

1. **The high planes are one run where Emacs has script runs.** This
   tree's `standard-syntax-runs` (`characters.scm`, transcribed from
   Emacs's `char-syntax` answers) stop around U+1F3FF, so every
   character above that falls to the table default and the walk
   correctly reports one long run. **A data gap worth closing** by
   re-running the transcription over the whole character space - the
   walk will show it the moment the table has it.
2. **Eight-bit characters print as `[N]`** in the row's key
   description, where Emacs writes the raw bytes - the standing
   byte-character display departure, not this command's.

Nothing else in `describe-syntax` is scoped down: the parent-table loop
and the describer's every arm (default / deeper char-table / invalid /
the class letter and flags, the "which means:" words, matches, the
comment-start/end sentences, the style and nestable notes and the
prefix line) are the C's.

## The bug this cost: `(vector starting)` applied the *parameter*

`describe-vector`'s first argument is named `vector`, as Emacs names
it - and the body builds a one-element key with `(vector starting)`.
In a Lisp-1 that applies the char-table. The key is built as a *list*
now (`keymark-index` reads a list of events as well as a vector), with
a note; the same wall as `insert` in `describe-key-briefly` and
`minibuffer-message`'s TEXT.

## Verification

`help-tests.scm` 41 (the exact rows, the describer's three arms, the
binding). The pty `help-describe` check drives `C-h s` too.

# `C-h o` describe-symbol (2026-11-18)

`describe-symbol` (help-fns.el:1957) with this tree's two backends - a
name is a command (and its record) or a custom variable. The C's
four-backend registry also has face and cl-type arms; neither type
exists here, and `describe-symbol-backends`' face entry would need
`facep`, which is `faces.scm`'s - not imported by help-fns, and there
are no cl structs.

**The multi-backend assembly is carried but unreachable**: Emacs's two
docs for one symbol exist because a symbol has a function cell and a
value cell; in this tree a command is a procedure binding and a custom
is a parameter binding, so one name is one or the other. The
separator-and-"also" loop stays for the day that changes.

**The prompt completes over this tree's two indexes** - the command
table and `custom-variable-names` - where Emacs filters its obarray
through the backends.

## The trap that cost this one: `(scheme base)` owns `read-string`

The first spec was `(read-string "Describe symbol: ")`. That called
**Guile's port reader** - `(scheme base)` exports a `read-string` of
its own, `(len #:optional port)`, and it wins the import against
`(schemacs editor minibuffer)`'s prompt reader without a word. The
echo area said "Wrong type (expecting exact integer): \"Describe
symbol: \"", which is `make-string` getting the prompt as its length.

Two ways out, and the second is the one taken: `(except (scheme base)
read-string)` **did not work** (measured: the arity of the binding was
still the port reader's), and the command uses `completing-read`
instead - which is what Emacs's own spec calls anyway. **No library in
this tree can call `read-string` and get the prompt reader unless its
`(scheme base)` import is narrowed; prefer `completing-read`, or the
seam `*read-string-function*` the `s` interactive code uses.**

## Verification

`help-tests.scm` 45 (a command, a custom variable, the unknown-symbol
message, the binding); the pty `help-describe` check drives `C-h o`
too - all nine keys (`b f v k c w m s o`) through the real command
loop now.

# `posn-at-point`, `event--posn-at-point`, `call-interactively` (2026-11-18)

`event-start`/`event-end` for a non-mouse event now answer the position
of point, as `subr.el:1907`/`:1946` do (`(event--posn-at-point)`). Three
representational departures come with it.

1. **`event--posn-at-point` is `subr.el`'s function, placed in
   `xdisp.scm`.** It reads `window-point` and calls `posn-at-point`, and
   both live above `subr.scm`; `event-start` reaches it through the seam
   `*event--posn-at-point-function*`. The body is Emacs's - the
   `(window-point)` read, the `(list (selected-window) POS '(0 . 0) 0)`
   fallback for an off-screen position - minus its minibuffer-window arm
   (the echo area is an ordinary window here) and its
   `(setf (nth 5 posn) pos)` correction (the posn below has no OBJECT
   field).

2. **`posn-at-point` (`keyboard.c:13594`) is rebuilt from cells, not
   from glyphs.** The C asks `pos_visible_in_window_p` for the glyph's
   pixel position and hands it to `posn_at_x_y`; this asks the same row
   walk the cursor is placed with (`rows-above-in-window`, the row
   slices, `current-line-display-column`) for the position's screen row
   and column, converts those to pixels and calls `posn-at-x-y` - the
   same two steps. Consequences, all on the returned list's *shape*:
   the posn has the four fields `posn-at-x-y` builds rather than
   Emacs's eleven, so there is no OBJECT/POS/(COL . ROW)/IMAGE; a
   position inside a `display` string or an invisible run is answered as
   the cell it is drawn on, not as the string; and with **no display
   object** (the help suites run headless) it answers nil, where Emacs's
   would still answer from its frame. nil is the "not on screen" answer
   and is what those callers handle.

3. **`call-interactively` (`callint.c:253`) does not carry
   RECORD-FLAG or KEYS** - nothing here records a command's arguments
   for `repeat-complex-command` - and it reads `current-prefix-arg`,
   which this tree binds only while an interactive specification is
   evaluated, not for the whole command. A `call-interactively` made
   from inside a command body therefore passes the prefix nil; the one
   caller that needs it (`tab-bar-mouse-1`) is a mouse click, for which
   nil is right.

`*tab-line-tabs-buffer-groups*` is a **parameter** where Emacs has a
`defvar` (`tab-line.el:499`): `tab-line-new-tab` `let`-binds it, and
that is the tree's test for which one a variable is. Its default is
`mouse-buffer-menu-mode-groups`' value, which is a plain variable in
`mouse.scm` despite its stars.

## `%substring`, because Scheme's `substring` drops text properties (2026-11-18)

GNU Emacs's `substring` is `substring_both` (`fns.c:1579`) followed by
`copy_text_properties`: the result keeps the source range's faces,
keymaps and every other property. `(scheme base)`'s `substring` is, in
Emacs's vocabulary, `substring-no-properties` (`fns.c:1610`) - and with
this tree's string intervals held in a side table keyed by the string
object, a new string from `substring` has none.

Measured: `(get-text-property 0 'close-tab (substring s 3))` is `#f` for
`s` propertized over its whole length.

`%substring` is Emacs's in `fns.scm`, with the whole string's interval
tree copied through `copy-intervals`. **The `%` is forced**: a library
cannot shadow a core binding (the `%assq` rule). The rest of the tree
still calls Guile's `substring`; the ones that matter are those where
Emacs's source says `substring` on a string that may carry properties.

## `equal-including-properties`, and the redisplay's row caches (2026-11-18)

Ported in `fns.scm` (`fns.c:2823`) over `compare-string-intervals`
(`intervals.scm`, `intervals.c`). `equal?` is its character-only half;
the C is `internal_equal` with `EQUAL_INCLUDING_PROPERTIES`, which
recurses through conses and vectors. The vector arm is carried; the
hash-table, char-table and record arms answer `equal?`, nothing in this
tree asking for their properties.

The **mode-line and tab-line row caches are this tree's own** - the C has
no such fields; `w->last_mode_line` does not exist, because Emacs rebuilds
the glyph matrix row and skips only on `w->update_mode_line`/garbaged
frames. Ours compares the formatted string, so the comparison has to see
everything the row does: characters *and* properties. With `equal?` a
window cycling between two buffers formatted the same characters with a
different current-tab face, the skip fired, and the wiped row stayed
blank. Both skips use `equal-including-properties` now, and
`mark-window-display-accurate-1` clears `last-tab-line` as it already
cleared `last-mode-line`.

## `*set-buffer-major-mode-function*` - a seam for `buffer.c`'s caller (2026-11-18)

`set-buffer-major-mode` is `buffer.c:2283`'s and its port is in
`files.scm` (it calls a mode *command*, which only the command table
above `window.scm` can resolve). Its caller
`window-normalize-buffer-to-switch-to` is `window.el:9519`'s and lives in
`window.scm`, so the call is a seam, as `*read-buffer-to-switch*` is:
`window.scm` holds the parameter, `files.scm` installs the function as it
loads. Emacs's other two callers (`other_buffer_safely`, `shell-command`)
are not wired - nothing here creates the scratch buffer through that path
yet.

## The Gtk popup's root was passed as an item (2026-11-18) - fixed

`create_menus (val->contents, ...)` (`gtkutil.c:3575`) is how
`xg_create_widget` opens a popup: the root `widget_value` is the GtkMenu
and its *children* are the first level. `pgtk-create-and-show-popup-menu`
passed the root, so every popup began with one item named "menu" - the
root's own name (`menu.c:619`). Fixed to `(widget-value-contents tree)`
and verified live (the two-pane probe above). No Emacs-side departure
remains; this entry is here because the symptom ("a menu containing only
the word 'menu'") named nothing recognisable in the source.

## `set-buffer-major-mode` reads the default mode (2026-11-18)

The C takes `BVAR (&buffer_defaults, major_mode)` - the *default* value
of `major-mode`, `fundamental-mode` - and only when that is nil does it
fall back to the current buffer's mode. The port read the *target*
buffer's own `major-mode` and then the current buffer's, so `C-x b fresh`
from a Scheme buffer produced a Scheme buffer where Emacs produces a
Fundamental one (measured: `(window-normalize-buffer-to-switch-to
"fresh")` from a `text-mode` buffer answers `fundamental-mode`).

There is no buffer-defaults table in this tree - readers spell the
default out (`buffer.scm`'s `major-mode` accessor passes
`'fundamental-mode`) - so this does too. The C's nil-default fallback is
carried and is unreachable here, as it is in Emacs. Also faithful now:
`*initial-major-mode*` is `lisp-interaction-mode` (`startup.el`), which
is what a *created* `*scratch*` buffer takes. Nothing creates one through
`get-scratch-buffer-create` yet, which is why this changes no behaviour
today.

## The line-break cache speaks text coordinates, not `BEGV`/`ZV` (2026-11-18)

`find_newline` consults `buf->newline_cache`, and every entry point of
that cache in the C reads `BUF_BEG`/`BUF_Z` - the *text*'s ends
(`region-cache.c`'s `region_cache_forward`/`_backward`/`know_region_cache`/
`revalidate_region_cache`), and `invalidate_region_cache` is given the
same pair by `invalidate_buffer_caches` (`insdel.c:2206`). That is
correct by the cache's contract: it stores facts about characters - "this
stretch holds no line break" - and a narrowing changes no characters.

This tree passed `(buffer-beg ed)`/`(buffer-z ed)`, which are `BEGV`/`ZV`.
While nothing narrowed the two agreed, so every test passed. With
`C-x n n` they do not: the cache's stored basis stayed the whole text
while every query and invalidation spoke of the accessible range, so an
insertion while narrowed (the user typed one character) shifted the
basis, and after `C-x n w` a "no line break here" run covered text the
cache had never scanned. The rest of the file was drawn as one line with
`^J` where its newlines were.

Three call sites, all now in text coordinates:
`new-region-cache` takes both ends (`BEG` and `Z` at creation, as the C's
initialises `buffer_beg`/`buffer_end`); `find-newline-forward`/`-backward`
pass the text's ends to the cache while their *scan* still stops at the
caller's END (ZV forward, BEGV back); and `invalidate-buffer-caches`
computes `beg_unchanged` and the head/tail in text coordinates, which is
what `buffer-text-beg-unchanged` already counts in.

The regression is at the render level (`tty-editor-tests.scm`'s
`schemacs_ncurses_editor_narrow_cache`): show, narrow, edit, redraw,
widen, redraw. The redisplay is part of the reproduction - it is the scan
that records the narrowed knowledge - which is why a direct
`find-newline` test did not see it. `tools/pty-check.py`'s `narrow` check
gained the typed character and asserts no `^J` and no joined lines.

## The comment commands' departures (2026-11-18)

* **`comment-add` the function is `comment-add-count`** (Lisp-2: the
  variable's accessor keeps the name).
* **`combine-change-calls` is not called**: `comment-region-default` and
  `uncomment-region-default` do their work directly, and
  `comment-combine-change-calls` exists and is read nowhere. Emacs wraps
  the region pass in `combine-change-calls` (`replace.el`), which is not
  ported.
* **`comment-setup-function` is not carried** - it is `ignore` by default
  and nothing here sets one; `comment-normalize-vars` therefore does not
  call it.
* **`comment-use-syntax`'s `undecided` resolves to "not by syntax"** (the
  C tries `forward-comment` in a temp buffer); a programming mode sets it
  to t, which is where it matters.
* **`comment-with-narrowing` is a macro here as there**, but its temporary
  is a `syntax-case`-built identifier rather than a `make-symbol` gensym.
* **`comment-line`'s backward marker**: Emacs sets `this-command` to the
  symbol `comment-line-backward`; here the symbol is stored in
  `*this-command*` directly (nothing applies it - the loop only rotates it
  into `last-command`), because the command *is* the procedure
  `comment-line`.
* **`(string c)` for a code point** needed `%char-string` at two sites in
  `comment-padright`; Elisp's `string` accepts integers, Scheme's does not.
* **`comment-padright`'s duplicate character** is captured before the
  MULTI test: a failed `string-match` preserves the previous match data in
  Emacs (measured) and clears it here, and the captured character is the
  same answer.

## The redisplay after an error is the command loop's (2026-11-18)

`command_loop_1` (`keyboard.c:1637`) runs one command inside
`internal_condition_case_1 (command_loop_1_body, Qerror, cmd_error)` and
then falls through to the redisplay at the bottom of the loop - so an
error a command raises is *reported* and the screen is brought into
agreement with the editor's state before the next key is read. `cmd_error`
itself only reports: it prints the message and returns.

This tree's loop reported the error inside its `guard` and returned to
the read without redisplaying, so a command that raised *part-way* left
the screen showing what the aborted command had drawn. Measured with
`C-x 2`, `C-x C-f`, a path, `?` (which pops `*Completions*`) and then
`C-g`: the aborted completing-read's window stayed on screen until the
next keypress, three mode lines where the editor's window list had two.

`keyboard.scm`'s guard now calls `redisplay-frames!` after
`report-command-error!`, which is the C's fall-through. Verified
load-bearing: with the redisplay reverted, 1 run in 20 of the probe shows
the stale window (`[2 2 ... 3 ... 2]`); with it, 15/15 clean, and the
`completion-window` pty check passes repeatedly.

## The startup hooks and the *scratch* buffer (2026-11-18)

**`term-setup-hook` is not carried.** Emacs 31 still declares it and runs
it beside `emacs-startup-hook` (`startup.el:283-334`, `:807`, `:3094`),
but marks it obsolete: "In new code, there is no reason to use this
instead of `emacs-startup-hook'". Every site that runs the pair here runs
`emacs-startup-hook` alone, and a hook added to `term-setup-hook` in an
init file is simply absent rather than silently skipped.

**Where the startup hooks run.** In Emacs they run at one of two sites,
whichever comes first: `command-line-1`'s startup-screen branch
(`:3094`, `:3115`), which then sets `inhibit-startup-hooks` (`:3117`);
or, when no screen is displayed, `normal-top-level`'s tail (`:807`,
`:848`). **Measured on Emacs 31.1** with an init file that adds a logging
function to each hook: with `inhibit-startup-screen` set, both hooks
still run (`emacs-startup-hook`, then `window-setup-hook`). This tree has
no `normal-top-level`, so `command-line-1`'s `else` is that tail: the
splash branch runs them before the screen is displayed and sets
`inhibit-startup-hooks`; the else runs them at the end of
`command-line-1`.

**`get-scratch-buffer-create` is a placement departure.** It is
`simple.el:11553`'s, and `simple.scm` is below `files.scm` (which holds
`initial-major-mode`) and below this library. It lives in `startup.scm`,
where both are reachable, as `locate-file-internal` lives in
`fileio.scm`; `window.scm` calls it through
`*get-scratch-buffer-create-function*`, which startup installs at load.
Its `(funcall initial-major-mode)` is spelled `(set-buffer-major-mode
scratch)`, this tree's resolution of the mode command by name.

**Emacs 31's `trusted-content` slot is not carried.** `:11564` sets it
to `:all` for `lisp-interaction-mode`; the content-trust machinery is not
ported and nothing here reads the slot.

**The two `command-line`/`command-line-1` `*scratch*` blocks are ported
separately, as Emacs has them**: `:1723-1727` initializes the mode of a
`*scratch*` that exists after the init file, and `:3015-3021` fills an
empty one with `initial-scratch-message` before display. The front ends
make the buffer before `command-line-1`, so the second block is the one
that fills it in a real run; `get-scratch-buffer-create` is the lazy
path. `initial-scratch-message` is a `define-custom` because Emacs
declares it with `defcustom` (`startup.el:1841`).

## Running a lisp-family mode makes every later fontification 40x
## slower - a bug, named (2026-11-18)

Found when Emacs's `initial-major-mode` was applied to `*scratch*`: the
`help-bindings` and `help-describe` pty checks went red, and both failed
identically - `C-h b` did nothing in the screen they captured.

**Measured.** `(describe-bindings)` in a fresh editor takes **12-14 ms**
until a `lisp-interaction-mode`/`emacs-lisp-mode` has *run* somewhere in
the session, and **~510 ms** for ever after. The mode need not be in the
buffer being described, and changing that buffer's mode back does not
undo it: in one editor, `(f) (run lisp-interaction-mode somewhere) (f)`
gave `(14 507 514)`.

The time is inside `font-lock-after-change-function` →
`font-lock-default-fontify-region` → `parse-partial-sexp` →
`%scan-sexps-forward`, i.e. the *syntactic* pass over the text being
inserted into `*Help*` (~5 KB of bindings listing). `describe-bindings`
is silent while it fills and fontifies `*Help*`, which is why the checks
saw nothing: their settle waits for quiet, and quiet is what a 500 ms
compute looks like.

**Ruled out, each measured:**

* the global `before-change-functions` flush hook - it is installed
  globally where Emacs installs it buffer-locally
  (`syntax-ppss-flush-cache`, `syntax.el:679`'s final `t`), but clearing
  it changes nothing (`(516 … 514)`);
* the `%syntax-propertize-done` cache - forcing the Help buffer's
  `syntax-propertize--done` to the sentinel changes nothing
  (`(512 513)`);
* the described buffer's mode, the current buffer, and the content of
  the listing - identical in both cases;
* Help's own state (`help-mode`, standard syntax table, no buffer-local
  `font-lock-mode`) - identical in both cases, and turning Help's
  font-lock *off* before the call does not help: `(20 #t 518 #t 530)` is
  fast, Help's font-lock on, then slow, then still slow with it off.

**The mechanism, found by bisecting the mode chain** (`prog-mode` does
not flip it, `lisp-data-mode` and `emacs-lisp-mode` do, and replaying
their steps one at a time shows it is none of the buffer-locals):

1. Running a lisp-family mode turns font-lock on in that buffer, and
   `font-lock-mode-internal` conses `font-lock-after-change-function`
   onto the **one global `*after-change-functions*` list** (the C adds it
   buffer-locally, `font-lock.el:703`'s `t t`). Every buffer's edits then
   go through it, gated per buffer by `font-lock-mode-on?` - which is
   exactly what the C's buffer-local hook does, so the gate is right and
   the list is not the problem.
2. What it costs is **eager fontification**: ours fontifies the changed
   chunk inside `after-change`, where Emacs only *marks* it and lets
   `jit-lock` fontify at display time. Measured on a plain buffer with
   font-lock on and 200 line-inserts: **1 ms** with no fontification
   running, **95 ms** with it - and the cost is
   `syntax-ppss(start)` re-parsing from the last cache position, which
   for a growing buffer is thousands of characters per chunk (a full
   `parse-partial-sexp` over the 5 KB listing is only 2-3 ms, so the
   total is the sum of the warm starts). That is the whole 40x.
3. A normal session always has the hook installed - the `*scratch*`
   buffer's mode runs at startup - which is why the slowdown looked like
   a property of the mode rather than of the fill.

**The missing primitive is `jit-lock`** (`lisp/jit-lock.el`, 761 lines;
the core - `jit-lock-register`, `jit-lock-function`,
`jit-lock-fontify-now`, `jit-lock-after-change`, `jit-lock-refontify`,
`jit-lock--run-functions` - is about half of it) **plus the redisplay
hook it stands on**: `fontification-functions`, which `xdisp.c`'s
`handle_fontified_prop` runs for text whose `fontified` property is nil.
Neither is ported. It is pre-existing, and its blast radius is every
mode that fills a fontified buffer in many chunks: Help (`C-h b`,
`C-h s`), and Dired/Buffer-Menu refreshes the same way.

**The harness change this forced**: `help-bindings` and `help-describe`
now say `WAIT` for the text they assert on (`Global Bindings`,
`which means:`) instead of relying on a quiet window - the rule this file
already carries - and both assert the absence of the `gave up waiting`
marker, since the marker's own text contains what they wait for.

## jit-lock ported: the fontification stall closed at its root
## (2026-11-18/19)

The section above ("Running a lisp-family mode makes every later
fontification 40x slower") named the missing primitive. This is it:
`schemacs/editor/jit-lock.scm` (a port of `lisp/jit-lock.el`'s core),
`fontification-functions` with the redisplay hook it stands on, and
`font-lock.el`'s `font-lock-support-mode` / `font-lock-turn-on-thing-lock`
wiring so `font-lock-mode` registers with jit-lock instead of fontifying
in `after-change`.

**Measured, same harness as the section above:**

| | before | after |
|---|---|---|
| 200 line-inserts into a fontified buffer | **95 ms** | **1 ms** |
| `(describe-bindings)` in a normal session | **~510 ms** | **17 ms** |

**What is ported, and from where:**

* `jit-lock.el`'s core - `jit-lock-mode`, `jit-lock-register`/
  `-unregister`, `jit-lock-refontify`, `jit-lock-function`,
  `jit-lock--run-functions`, `jit-lock-fontify-now`,
  `jit-lock-force-redisplay`, `jit-lock-after-change` - with
  `jit-lock-start`/`jit-lock-end` as parameters (the C's "dynamically
  scoped variables", `jit-lock.el:667`) and
  `jit-lock-after-change-extend-region-functions` as a hook parameter.
* `fontification-functions` (`xdisp.c:39022`) and the redisplay hook
  (`handle_fontified_prop`, `xdisp.c:4667`) in `xdisp.scm`'s row
  builder: a row whose first position is not `fontified` is fontified
  before it is built.
* `font-lock-support-mode` - **onto the `*font-lock-support-mode*`
  parameter this file already had** (it existed as #f "because jit-lock
  is not ported"; a second plain variable was written first and then
  consolidated away, because two spellings of one option is the class of
  bug `loadup-tests`' clash census exists for) - `font-lock-turn-on-thing-lock`,
  `font-lock-turn-off-thing-lock`, the four function variables
  (`font-lock-flush-function`, `-ensure-function`,
  `-fontify-buffer-function`, `-extend-after-change-region-function`),
  `font-lock-extend-jit-lock-region-after-change`, and
  `font-lock-extend-region-wholelines` (its `syntax-propertize-wholelines`
  had been ported all along; the note claiming otherwise was stale).

**The bug this shook out, worth knowing before touching the extend
loop**: `font-lock-extend-region-wholelines` answers non-nil on *every*
call (`syntax-propertize-wholelines` always conses), so the
extend-region loop's `(eq funs font-lock-extend-region-functions)`
guard is load-bearing - it stops the restart when a function returned
true at the *start* of a pass. The loop here had been written without
it (harmless while wholelines did not exist) and the dired suite hung
on the first run: an infinite restart.

**Not carried, each named in `jit-lock.scm`'s header or the source:**

* stealth fontification (`jit-lock-stealth-*`, idle timers over every
  buffer);
* deferred fontification (`jit-lock-defer-time`, nil by default);
* contextual fontification (`jit-lock-contextually` defaults to
  `syntax-driven`; the variable is carried so a user setting it sees no
  error, the pass is not ported);
* the antiblink `post-command-hook` pair, `jit-lock-debug-mode`,
  indirect-buffer refusal (`buffer-base-buffer` is not carried), the
  `memory-full` guard, `run-hook-wrapped` (a plain `for-each` - nothing
  returns early), and `redisplay-skip-fontification-on-input`.

**Departures in shape, each named in the source:**

* the buffer-local hooks (`jit-lock-functions`,
  `fontification-functions`) are per-buffer *list entries* read through
  accessors, because this tree's hook machinery is parameters and a
  parameter is not per buffer; `jit-lock-after-change` is on the one
  global `after-change-functions` list, gated on the buffer's
  `jit-lock-mode` - the compromise `font-lock-after-change-function`
  already documented;
* the C's `specbind (Qfontification_functions, Qnil)` is a separate
  `*in-fontification-functions*` flag, because a buffer's own list would
  win over a rebound parameter;
* `font-lock-extend-jit-lock-region-after-change` is gated on
  `font-lock-mode` because its hook is global here and buffer-local in
  Emacs.

**Tests**: `jit-lock-tests.scm` (14) - the register/refontify cycle, the
after-change mark-only rule, `font-lock-ensure` as the demand path, and
the property at `point-max` staying nil (Emacs's special case).
`font-lock-tests`, `lisp-mode-tests` and `dired-mode-tests` now call
`font-lock-ensure` before asserting faces - which is what Emacs's own
callers do once jit-lock is in play, and is why their expectations did
not have to change. The pty battery's `font-lock-scheme` check is the
end-to-end proof that the redisplay hook fontifies what it draws.

**Verified end to end:** all 73 suites pass (jit-lock-tests 14), the tree
compiles with no new warnings, and `tools/pty-check.py` is **97/97**
(battery #14). Two earlier runs of the same tree gave 95/97 with
`query-replace-quit` and, once each, `redisplay` and `completion-ui` -
the battery's documented load-flake class: each passed 3/3 when run
alone, and the clean run was taken with the machine quiet.
## `lookup-key` inherits, and the keymap list `access_keymap` builds
## (2026-11-19)

`access-keymap` here was the C's `noinherit` half of `access_keymap`
(`keymap.c:491`) and nothing else: own bindings and char-table, never a
parent. That is right for `define-key`, whose `Fdefine_key` walk calls
`access_keymap (map, c, 0, 1)` and documents why - "a *parent's* `C-x`
does not count - a child is free to make its own" - and wrong for
`lookup-key`, whose `lookup_key_1` (`keymap.c:1210`) calls
`access_keymap (map, c, t_ok, 0)` and therefore inherits.

Measured on Emacs 31.1, fresh maps:

| maps | answer |
|---|---|
| child has none, parent binds `b` | `(lookup-key child "b")` is the parent's command |
| child defines `C-c x`, parent `C-c y` | both found through the child |
| both bind `C-c` to prefixes | the prefix answers `(keymap CHILD-PREFIX PARENT-PREFIX)` |
| child defines `C-c x`, parent binds `C-c` to a command | the child gets its own prefix; **no error** |

Ported to the C's shape:

* `access-keymap` takes the optional NOINHERIT. With it false, a miss in
  the map asks the parent; when the event is a keymap both in the map
  and in the parent the answer is a **keymap list** `(keymap OWN
  INHERITED)` (`access_keymap_1`, `keymap.c:402-420`), and a KEYMAP that
  is itself such a list is walked element by element, with an earlier
  keymap binding beating a later command, as the C's loop does.
* `keymapp` is `KEYMAPP` = `get_keymap` non-nil, and `get_keymap`
  answers a keymap list as a keymap (`keymap.c:197`): `(keymapp '(keymap
  A B))` is t.
* `lookup-key`'s prefix test is `keymapp` (the C's `get_keymap (cmd, 0,
  1)`), and `keymap-lookup`'s is too; its old manual parent walk is
  gone, since the inheritance now happens inside `access-keymap` where
  the C has it.
* The `(t . DEF)` default is `%keymap-t-default-chain`: the C records
  the first default and clears `t_ok` as it walks (`keymap.c:411-414`),
  so the **nearest** default applies, and only if no specific binding
  exists anywhere in the chain.

Departures left standing, named in the source:

* **nil versus unbound.** The C tells an explicit nil binding (`Qnil`,
  which shadows the parent) from no binding (`Qunbound`); this tree's
  hash answers #f for both, so a nil binding inherits where Emacs
  shadows. Pre-existing, and now reachable through inheritance - no
  caller here defines a key to nil deliberately.
* A list whose leading symbol is not `keymap` is still walked as a list
  of maps; Emacs's `get_keymap` requires the leading `Qkeymap`.
* **`keymap-lookup`'s "too long" answer is the command, not a
  count.** `lookup-key` has the C's (`keymap.c:1289': a number when the
  sequence runs into a non-prefix before its last event), and
  `keymap-lookup` - which shares its docstring - answers the command it
  found. Reachable only for a key sequence *longer* than its binding;
  its one reader that cares, `%shadow-lookup' in `keyboard.scm', is
  written around it (its comment says so). Porting it means giving
  `keymap-lookup' a counter and giving `%shadow-lookup' the C's
  `FIXNATP' guard (`shadow_lookup', `keymap.c:2464'). Named, not done:
  nothing here binds a command mid-sequence.
* A keymap named by a *symbol* (a function definition) is not carried,
  as `keymapp`'s note says.

Found by `C-h ?`: `help--help-screen` looks its option up with
`(lookup-key local-map key)`, and the options live in `local-map`'s
parent `help-map`, so every option answered "No help command is bound to
`b'". `subr-tests` pins the four measured cases; `tools/pty-check.py`'s
`metahelp` check is the end-to-end one.

## `C-h ?` — `help-for-help` and `help--help-screen` (2026-11-19)

`help-macro.el`'s macro and `help.el`'s screen and option table are
ported (described in AGENTS.md); the departures:

* **`unwind-protect` is unbound at runtime in a library.** `(only
  (guile) unwind-protect)` has no binding, and an unqualified
  `unwind-protect` in a library body *compiles* with a "possibly
  unbound" warning and raises when the form runs. The C's frame is
  `(dynamic-wind (lambda () #f) body cleanup)` here - the same shape
  `save-excursion` uses.
* **The option table is trimmed**, not a faithful subset: every entry
  whose command this tree does not have is gone, and the help line
  says `[bcfkmoqsvw]` to match. Omitted, with what each waits for:
  `apropos-command`/`apropos-documentation` (apropos.el),
  `describe-command`, `help-find-source`, the whole Manuals section
  (info.el), `view-emacs-*`/`view-hello-file`/`view-lossage`/
  `view-echo-area-messages`/`describe-package`/`help-with-tutorial`/
  `display-local-help`/`help-quick-toggle`, and
  `describe-input-method`/`describe-language-environment`.
* `variable-pitch-mode` (the `help-for-help-use-variable-pitch` branch;
  the option is carried so a user setting it sees no error), the frame
  operations `iconify-frame`/`handle-switch-frame`/
  `frame-toggle-on-screen-keyboard`, and `ding` are not carried.
  `vertical-scroll-bar` is in the C's key list and never arises - no
  front end here has scroll bars.
* **`[t] -> undefined` is not bound.** The C binds it so every key in
  the metahelp is "defined"; the else branch's `(lookup-key local-map
  key)` passes no ACCEPT-DEFAULT, so the C's own `t` entry is invisible
  to it too - an unbound option answers #f and the "No help command is
  bound to" branch reports it either way. What the binding changes is
  `read-key-sequence`'s behaviour over `overriding-local-map`, which
  this tree's reader does not model.
* The scroll keys call `scroll-up-command`/`scroll-down-command` where
  the C calls the `scroll-up`/`scroll-down` primitives
  (`scroll_command`, `window.c:6975`, is not ported).
* **The prompt's page keys are `<PageDown>`/`<PageUp>`**, the C's own
  spelling (`help-macro.el:190`). `(kbd "next")` - which this port first
  used - reads as the four characters, and Emacs itself answers
  `(key-description (kbd "next"))` = `"n e x t"`, so the prompt rendered
  "n e x t".
* The mouse arm of the C's `(not (or (integerp char) (symbolp char)))`
  is carried; the `switch-frame` arm is not, since a `switch-frame`
  event does not exist here.
* `make-help-screen`'s generated command takes its **`interactive`
  form** as a syntax object built with the call site's context - see
  AGENTS.md for why a literal one resolves in `help-macro` and is
  refused.

**The read-path redisplay is a separate departure, and it was the
screen being blank**: `read_char` redisplays before it waits
(`keyboard.c:2718-2723`), and this tree's `read-key-event` did not, so
every read outside the minibuffer left the screen stale. Ported in
`keyboard.scm`; see AGENTS.md.

## `C-h k M-:`: the read's answer rule, and the ESC meta prefix
## (2026-11-19)

Reported from a live editor: `C-h k M-:` answered "Value out of range -1
to <1114111>: 134217786". Two departures, both in `read-key-sequence`.

**1. String or vector was decided by "are all events integers?".**
`make_event_array` (`alloc.c:3691`) is the C's rule: a string only when
every event is "a character in 0...127, after discarding the meta bit
and all the bits above it"; anything else a vector - and for a *meta*
character Emacs makes a unibyte string with the meta moved into the
byte's high bit (`SSET ... | 0x80`), so `M-:` is the byte 0xBA. This
tree cannot carry that byte in a string (Guile strings are Unicode, and
0xBA would read back as `º`), so a meta event answers a vector here.
The port's test called `integer->char` on 134217786, which is above
Guile's character range - the reported error. `%read-key-sequence-answer`
is `make_event_array`'s rule now, with `0..127` standing for "fits in a
string". **A meta event answered as a vector is the named departure**;
every consumer reads either form through `keymap-index`.

**2. The ESC prefix was not folded in the read.** A terminal sends `M-:`
as ESC then `:`, and `read_key_sequence` turns that into the meta event
itself (`meta_prefix_char`, `keyboard.c:11829`). The command loop had
that state machine already (`*esc-pending*`, `dispatch-key-event`), but
the read `C-h k` and the `k`/`K` interactive codes use did not: a pty
run of `C-h k ESC :` answered "ESC is undefined" (measured before the
fix). The fold is in `%read-key-sequence` now, unconditionally, matching
the command loop: a two-event `ESC KEY` binding is not a spelling this
tree uses - meta is one event here, as it is in Emacs.

**Also corrected**: `characterp`'s comment said Emacs answers t for
`M-x`. Measured, `(characterp ?\M-:)` is nil - the modifier bits are
above `MAX_CHAR` - and that wrong note is the likely origin of the
"all integers" test.

**Tests**: `tty-editor-tests`' new `read_key_sequence` group (4):
ESC+`:` is the meta event and answers a vector, a plain character and
control characters answer strings (`make_event_array`'s rule), and
`read-key-sequence-vector` always answers a vector. The pty battery's
new `describe-key-meta` check drives `C-h k ESC :` end to end and
asserts the *Help* text.

## `help-fns--insert-menu-bindings`, and the comparison it needed
## (2026-11-19)

The help pass's last named gap is ported: a command's "It can also be
invoked from the menu: File → Save" paragraph (`help-fns.el:663`), called
where Emacs calls it (`:636`), with the heading, the remap suffix, the
`(= (point) start)` punctuation test and the closing `ensure-empty-lines`
(`:649`) that our `help-fns--key-bindings` had also been missing.

**Two primitive fixes were underneath, and neither showed until menus
were finally looked for.**

1. **`where-is-internal` never found a menu sequence.** A keyboard
   binding in this tree is the command's *value*; a menu item is written
   `(menu-item "Save" save-buffer)`, and `get_keyelt` answers the
   *symbol* `save-buffer`. The walk compared symbol against value and
   the shadow check did the same, so every menu binding was rejected in
   both passes. `%where-is-value` resolves a symbol naming a command
   through the command table, and both comparisons go through it.
   Measured: `(where-is-internal 'save-buffer)` was `([24 19])` and is
   now `([24 19] [menu-bar file save-buffer])`, Emacs's own answer.

2. **A `string-join` separator.** Emacs's `(string-join SEQ)` uses `""`,
   measured; Guile's uses `" "`. The push-and-join idiom Emacs uses to
   build "File → Save" came out "File  →  Save" until `""` was passed
   explicitly.

**Representation notes, named in the source:**

* Emacs's `(assq entry (cdr map))` is a hash lookup of the *raw* binding
  here (`keymap-bindings`), because `access-keymap` coerces a
  `menu-item` to its command and the label lives in the list. The walk
  reads `(menu-item NAME DEF ...)` from the raw list's cadr/caddr - the
  C's `(nth 2 elem)`/`(cadddr elem)` over `(entry . raw)`.
* Emacs's `proper-list-p` guard is replaced by the two shapes' own
  tests: the old `(STRING . SUBMAP)` spelling is *improper* here (its cdr
  is a keymap record), where Emacs's cons onto a list is proper.
* **Not carried**: the `(symbolp map)` arm, which resolves a menu bound
  by a symbol through `symbol-function` - a menu value here is a keymap
  record or a command, never a symbol naming a keymap.
* The remap sentences now name the command ("Its keys are remapped to
  `X'." and ", but that was remapped to `X' as well."), which the C
  prints only when its remapping answered a *symbol*; ours answers the
  binding, so the name comes from `help-fns-function-name`.
* `char-displayable-p` of `→` is #t here (the terminal coding system is
  `utf-8-unix`), so the separator is ` → `, not the ` => ` fallback.

**An order difference, not a content one**: `where-is-internal` lists a
menu sequence *before* a chord where Emacs lists the chord first - for
`delete-frame`, Emacs gives `([24 53 48] [menu-bar file delete-this-frame])`
and this tree gives the reverse. Emacs's `menu-bar.el` is loaded before
the key libraries that bind `C-x`; this tree's `menu-bar.scm` is loaded
after every one of them, and both keymaps put a new binding at the front
(measured in Emacs: `a`, `b`, `c` defined in order read `(99 98 97)`).
Only the order of `where-is`'s output and, for a command on *two*
menus, the order of the menu clause are affected; `describe-function`
splits keys from menus, so its sentences are unaffected.

**Tests**: `menu-bar-menus-tests` +2 (9): the walk's "File → Save", and
`describe-function 'save-buffer`'s whole menu sentence - the line Emacs
31.1 prints there, measured.

## The read-path detector, and `fetch-char` on a byte character
## (2026-11-19)

The 2026-10-06 handoff said `detect_coding` (`coding.c:6501`) was not
ported; it had been ported later, as `detect-coding-bytes`, and the note
was stale. Verified against Emacs 31.1 with `tools/coding-diff.py` (after
repairing the tool - see AGENTS.md): **20 of 21 corpus cases identical**,
the remaining one `iso-2022-jp`.

**The rule it reproduces, and the one departure-shaped thing about it.**
`detect_coding` does *not* set `CODING_MODE_LAST_BLOCK` (unlike
`detect_coding_system`, `coding.c:8743`), because `decode_coding_gap` -
the file-visit path - never sets it before detection. A UTF-8 sequence
cut off by end of file is therefore *inconclusive* rather than invalid,
and the bytes are named UTF-8:

| bytes | `find-file` | `detect-coding-region` |
|---|---|---|
| `2D 4E 87` | `utf-8-unix` (the `87` becomes a byte character) | `raw-text` |
| `2D 4E 87 41` | `japanese-shift-jis-unix` | `japanese-shift-jis` |

The port has both doors, with `last-block?` as the argument that tells
them apart. The *inconsistency* is Emacs's, not a departure here.

**One departure made less bad, not new.** A *byte character*
(`#x3FFF00 + byte`) has no Scheme character to be. `fetch-char`
(`buffer.scm:2488`) called `integer->char` on the store's code point and
raised "Value out of range -1 to <1114111>: 4194178" - so visiting any
file whose first line began with such a character died in
`set-auto-mode`'s `skip-chars-forward`. It now answers U+FFFD through
`code-point->char`, the same rule `buffer-text-substring` and the
search's folding already use; the departure that a byte character cannot
be displayed as itself stands, but it no longer crashes a scan.

**Named, not carried**: iconv's `SHIFT-JIS` is not Emacs's charset
table. `87 41` decodes in Emacs to its internal JIS X 0208 code
(measured 1311849) and iconv answers U+FFFD, so a buffer read as
`japanese-shift-jis` can differ in that character while the *coding
system* agrees. Closing it means the charset registry
(`charset.scm`, metadata only) and its map files.

## The charset registry's map data and unification (2026-11-19)

`charset.scm` had the registry's *metadata* - ids, dimensions, ISO final
chars - and no conversion. It now has `charset.c`'s map machinery
(`load_charset_map_from_file` and its `read_hex` parser, control flags
0/1/2, the 190-byte fast-map, `CODE_POINT_TO_INDEX`), all four methods
(MAP, OFFSET, SUBSET, SUPERSET), `decode-char`/`encode-char`, and
`unify-charset` with the global unify table.

**Departures, named:**

* **The map data ships in the tree** (`schemacs/etc/charsets/`, 3.1 MB,
  Emacs 31.1's 131 generated files). Emacs generates them at build time
  from glibc's charmaps (`admin/charsets/Makefile`) and ships them in
  its install's `etc/charsets`; `*charset-map-path*` here defaults to
  this tree's copy, located on the load path, where Emacs's default is
  its installation directory.
* **The 27 `unify-charset` calls are in `charset.scm`**, at the end of
  the data. Emacs makes them in `mule-conf.el`, which is not ported, and
  the `:unify-map` attribute each needs travels with the data.
* **The data section was re-emitted with every attribute Emacs's
  registry holds.** The first transcription kept the code space, ISO
  final char, and *some* offsets and maps; it had no `:subset`,
  `:superset`, `:min-code`/`:max-code` or `:ascii-compatible-p`, so
  `gb18030` (a superset, 4 dimensions) was defined as an offset charset
  and crashed the fast-map, and the `latin-iso8859-*` family got the
  wrong method. A charset registry without its methods is not a subset
  of Emacs's - it is a different registry.
* **`emacs`'s `:max-code` is hand-written**: it is one of the five
  charsets the C defines in `init_charset_once`, and its bound
  (`MAX_5_BYTE_CHAR`, 0x3FFF7F) is not in its plist.

**Verified against Emacs** with a differential over every charset and
ten sampled code points each: **2148 decode answers and 1812 encode
answers, zero differences**. It found the two data bugs and the ASCII
shortcut of `DECODE_CHAR`/`ENCODE_CHAR` (`charset.h:427`, `:443`): an
ASCII code through an ASCII-compatible charset is itself, before the map
is consulted - MIK's map starts at 0x20, so codes 0 and 21 would
otherwise have no answer.

**Not done yet (2026-11-19).** The registry is complete; the ISO-2022
codec and its dependent subsystems are not ported, and the "~1400
lines" the 2026-10-06 reconnaissance gave was `coding.c` alone. Reading
the C found three subsystems under it that this tree does not have:

* **`char_charset`** (`charset.c:1961`), with `Vcharset_ordered_list`
  and `charset_non_preferred_head`. The encoder cannot choose a charset
  for a character without it. ~60 lines plus an ordered list that has
  to be measured from a running Emacs the way the registry data was.
* **Composition** (`CODING_ANNOTATE_COMPOSITION_MASK`, the
  `DECODE_COMPOSITION_*`/`STORE_COMPOSITION_*` state machine in the
  decoder, `composition.c`). Four systems declare `composition` in
  their flags (`iso-2022-7bit`, `-ss2`, `-lock`, `-8bit-ss2`) and so
  does `compound-text`; `iso-2022-jp` does not. Emacs decodes the
  escapes to component characters *plus* a composition annotation and
  composes via `composition.c`, which is not ported. The decoded text
  is the same either way - the grouping is a property - and that
  grouping is what is missing.
* **Charset annotations** (`ADD_CHARSET_DATA` in the decoder, the
  `charset` text property it sets on decoded text, and
  `CODING_ANNOTATE_CHARSET_MASK`/`preferred_charset_id` in the
  encoder). The encoder reads them back to reproduce the input file's
  designations; without them it picks charsets by priority. This is
  what keeps a multi-charset ISO-2022 file byte-identical round-trip in
  Emacs.

Also required and not in that estimate: the coding-system attributes
(`:coding-type 'iso-2022`, the 15 flag bits, `:designation`,
`:iso-request`/`:iso-usage`, `setup_iso_safe_charsets` at
`coding.c:2855`), the detector (`detect_coding_iso_2022`, `:2923`), and
`iso_code_class`'s 256-byte classification table, which the decoder
switches on.

**Scope decision (Chris, 2026-11-19): deferred, not half-built;
`implement the gtk tabs` was taken instead.** Nothing of ISO-2022 is
written - there is no partial codec in the tree. When it is taken up
the options are: (a) the codec core with the two departures above
(composition escapes decode to their component characters, no `charset`
property), still including `char_charset`; (b) full fidelity, adding
`composition.c` and the `charset` property - a project of its own;
(c) detector and naming only, for a correct mode line and priority
without a codec.

## Contextual fontification: a "not carried" note that had its reason
## backwards (2026-11-19)

`jit-lock-contextually` was carried as a defcustom whose note read
"Not carried: fontification is line-by-line here; the variable is so a
user setting it sees no error." **The reason is backwards.**
Line-by-line fontification is exactly why the sweep exists:
`jit-lock-after-change` marks only the changed text `fontified` nil
(`jit-lock.el:701`), and a line the redisplay has already drawn keeps
its `fontified` t - so when an edit above it changes its syntactic
context (a string or comment opened two lines up), it keeps its old
faces indefinitely. Emacs's context pass marks everything after the
change unfontified once the editor has been idle for
`jit-lock-context-time`, and the redisplay refontifies what it draws.

Ported from `jit-lock.el`:

* `jit-lock-context-unfontify-pos` (`:154`): the buffer-local position
  after which text is contextually unfontified; nil means off.
* `jit-lock-context-timer` (`:171`): one timer for the editor.
* `jit-lock-context--update` (`:181`) and `jit-lock-context-fontify`
  (`:636`): on a repeating idle timer, for every buffer on
  `(buffer-list)`, mark `pos .. point-max` unfontified and seat the
  position at `point-max`.
* `jit-lock-mode`'s on branch (`:258-265`): when the buffer's
  `jit-lock-contextually` is `t`, arm the timer if it is not already
  and seat the position at `point-max` (`(or pos (point-max))`).
* `jit-lock-mode`'s off branch (`:286-302`): cancel the timer, but
  only if no buffer on `(buffer-list)` still has the mode on - the C's
  `(catch 'found (dolist ...))` walk.
* `jit-lock-register` (`:338`): `(when (and CONTEXTUAL
  jit-lock-contextually) (setq-local jit-lock-contextually t))`. The
  test is on the *dynamic* value, which this tree's
  `(jit-lock-contextually)` reproduces (the buffer-local when one has
  been set, the custom's value otherwise). `font-lock` passes
  `(not font-lock-keywords-only)`, so registering from a mode with
  syntactic fontification is what turns the sweep on for that buffer.
* `jit-lock-after-change` (`:701-708`): the sweep position becomes
  `(min jit-lock-context-unfontify-pos jit-lock-start)` - the
  possibly-extended start, not the raw argument - and the update sits
  *outside* `with-silent-modifications`, as the C has it.

Named departures, all unobservable here:

* The sweep uses `put-text-property ... 'fontified #f` where the C
  uses `remove-text-properties ... '(fontified nil
  jit-lock-defer-multiline nil)`; nothing sets `jit-lock-defer-multiline`
  because deferred fontification is not carried, and `get-text-property`
  answers nil either way.
* The `jit-lock-defer-multiline` branch of `jit-lock-context-fontify`
  that walks the position back with
  `previous-single-property-change` is therefore not carried.
* The antiblink grace timer and its `post-command-hook` pair
  (`jit-lock-antiblink-grace`, `jit-lock--antiblink-*`, `:710-762`)
  are not carried; they *delay* the sweep while an unterminated string
  has just been opened. Without them the sweep runs at
  `jit-lock-context-time` as Emacs's does with `jit-lock-antiblink-grace`
  nil.
* `memory-full` (`:640`) has no counterpart; there is no low-memory
  flag here.

Tests: `jit-lock-tests.scm`'s `schemacs_editor_jit_lock_context` group
(7), on a `get-buffer-create` buffer because `jit-lock-context-fontify`
walks `(buffer-list)` and an `allocate-buffer` buffer is not on it. The
after-change test ("a change moves the sweep position...") and the two
sweep tests were each seen failing with their mechanism removed.

## Every Gtk click was button 1, so the tab bar had no context menu
## (2026-11-19)

Chris: *"in real emacs I can right click a tab and a menu pops up, we
don't have that."* The tab-bar command was there -
`tab-bar-mouse-context-menu` and its `[tab-bar down-mouse-3]` binding
(`tab-bar.el:569`) - and it could never run on Gtk.

**The front end decoded every button as button 1.** `pgtk.scm`'s
`pgtk-item->event` spelled the event symbol literally:
`'down-mouse-1` for every press, `'mouse-1` for every release,
`'drag-mouse-1` for every drag. GNU Emacs names the symbol from the
button number: `make_lispy_event`'s button branch (`keyboard.c:6590`)
takes `event->code` and calls `modify_event_symbol`, which folds the
`down_modifier`/`drag_modifier` into `down-mouse-N`, `mouse-N`,
`drag-mouse-N` (`keyboard.c:6760`). A backend that reports the wrong
number makes a right-click indistinguishable from a left one.

Fixed where the C has it - the front end's event decode:

* `event:get-button` (`gdk_event_get_button`) imported into
  `pgtk.scm`, and `pgtk-event-button` reads it (the same two-value
  out-parameter shape as `event:get-coords`).
* `pgtk-mouse-button-symbol kind button` builds the three names.
* the press/release/drag branches use it. `down-mouse-3` now reaches
  `tab-bar-map`'s `[tab-bar down-mouse-3]` and the menu pops;
  `mouse-2` reaches `[tab-bar mouse-2]` and closes a tab, which is
  Emacs's middle-click.

**How the tab is identified from the click** is the existing text-mode
emulation in `tab-bar--event-to-item`: our `posn-at-x-y` answers the
tab-bar *area* with a cell position and no drawn string, so the tab is
found by walking the items' caption lengths against the column. That is
the terminal's path and it is why the command works here without the
`tab_bar_window` object.

Not carried, all pre-existing and named:

* **`double-mouse-N`/`triple-mouse-N`** - a click count needs a clock
  in the event decode (`mouse-start-end` mode 0 only).
* **Wheel events** (`mouse-4`/`mouse-5`): Gdk sends `scroll-event`, a
  different event type, and the area asks for no scroll mask.
* **The tty has no mouse at all** (`term.scm` says so: no GPM, no
  `xterm-mouse-mode`), so the tab bar's context menu is reachable on a
  terminal only after mouse reporting is ported.

Tests: `pgtk-tests.scm`'s `schemacs_pgtk_mouse_buttons` group (3) pins
the naming half for buttons 1, 2 and 3 - the half that was wrong. A
Gdk button event cannot be synthesized in this environment
(`gdk_test_simulate_button` is not in the typelib surface), so the
`event:get-button` half is exercised by a real click; the import is
proven by the library loading at all.

## Emacs's Gtk build has no tab-bar widget (2026-11-19)

Three files said it had one - `frame.scm`'s `frame-top-margin`,
`xdisp.scm`'s `update-tab-bar`, and `tab-bar.scm`'s header - and
AGENTS.md repeated it, calling our first-row-of-the-text-area drawing
a named departure. **It is wrong.** `gtkutil.c` and `xmenu.c` build the
*menu* bar's widget and contain no tab-bar code at all; the redisplay
draws the tab bar into `f->tab_bar_window` (`xdisp.c:14696`,
`redisplay_tab_bar`), `pgtkterm.c` reads `FRAME_TAB_BAR_LINES` for its
height and hit-tests clicks against that window, and `FRAME_TOP_MARGIN`
counts the bar's rows on a window-system frame exactly as on a tty.
Our in-text-area row is Emacs's architecture, not a departure; what is
missing is the dedicated window *object*, so a click's `posn-window`
answers the frame where Emacs answers `tab_bar_window`. All four notes
are corrected in place, and the correction is the reason the "implement
the gtk tabs" suggestion existed at all.

### ...and the popup path had two more bugs under it (2026-11-19)

Reporting the button decode as the whole fix was wrong: with
`down-mouse-3` finally reaching the command, the menu still did not
pop, and the release still errored. The command itself signalled
`Wrong type argument: windowp (#f)`.

**`popup-menu-normalize-position` was missing its `posnp` branch**
(`menu-bar.el:2788`). Emacs turns a posn that names a *window* into
`((X Y) WINDOW)`; ours had only the nil, event and pass-through
branches, so a tab-line click's posn reached `x-popup-menu` as if it
were an event. The C's own `posnp` docstring is the reason a *frame*
posn - the tab bar's - is deliberately not normalized: `posnp` answers
nil when the posn's first element is a frame rather than a window.

**`x_popup_menu_1`'s decode was missing its tab-bar arm**
(`menu.c:1135`). A position whose second element is `tab-bar` means
"use the current mouse position" - the C's
`(EQ (XCAR (XCDR (position)), Qtab_bar))`. Ours fell through to the
event branch, `event-start` answered the posn's `tab-bar` part (the
C's `EVENT_START` macro is `CAR_SAFE (CDR_SAFE (...))`, which on a
*posn* is its second element), and `posn-window` of the symbol
`tab-bar` is nil - hence "windowp (#f)". Ported with the C's other arm
as well: when `x` and `y` are nil ("a click in an external tool bar"),
use the current mouse position, which is also what `(menu-bar)`
positions do.

**The `((X Y) WINDOW)` form is a two-element list.** The C reads
`y = Fcar (XCDR (tem))`; our decode had read the cdr of a dotted pair.
`popup-menu-normalize-position` builds the list form, so the old
reading produced `(+ ypos '(0))` - "Wrong type argument in position 2:
(0)".

Verified live on Gtk (broadway): both `tab-bar-mouse-context-menu` and
`tab-line-tab-context-menu` now block in the Gtk menu loop with the
menu up - Emacs's `popup_widget_loop` - where before they either
signalled or returned with no menu. `tab-bar-tests`'
`schemacs_editor_tab_bar_context_menu` (2) and `tab-line-tests`'
`schemacs_editor_tab_line_context_menu` (2) pin the menu's items, that
`menu-show` receives them, and the flags (the tab bar's position is
the "current mouse position", carrying no `MENU_FOR_CLICK`).

Not carried, named: `mouse-position` answers cells here where Emacs's
`Fmouse_position` answers pixels; a mouseless terminal's
`(FRAME #f . #f)` uses the C's x=0, y=0 fallback; and the
`last_nonmenu_event` half of the keyboard-navigation test (the
part-of-window alone decides it here, as it did before).

One bug in that port itself, found by the battery: the
keyboard-navigation test. The C's is `CONSP (tem2) && EQ (XCAR (tem2),
Qmenu_bar)` - the part-of-window of an F10 position is the *list*
`(menu-bar)`, and it takes its car. Comparing the area itself with the
symbol `menu-bar` matched nothing, so `tty_menu_activate` was handed a
menu with no `MENU_KBD_NAVIGATION` and the right arrow no longer moved
between top-level menus (the `tty-menu` check's last two assertions).
Fixed, and the check passes.

### The context menus were only half fixed: `split-window` lacked SIDE and PIXELWISE (2026-11-19)

Chris, once the menus popped: the first item is "Context Menu"; Duplicate
gives "Wrong type argument in position 1 (expecting struct): #f";
Detach gives "Wrong type argument: frame-live-p". Three departures.

**1. `split-window` was `(window size horizontal)`.** Emacs's is
`(window size side pixelwise)` (`window.el:2833`): SIDE nil/`below`,
`above`, `left`, `right`, with `up`/`down` aliases and - the clause that
kept the tree's callers working - *any other non-nil value, `t`
included, is `right`*. `split-window-no-error` translated SIDE to the
old boolean and dropped PIXELWISE, and that translation is why the gap
survived: every call site inside the tree went through it. Ported
whole: SIDE with all five values and the fallback, `above`/`left`
placing the new window *first* (it takes the second share; the old
window keeps its SIZE and moves after it - the first version of this
port wrongly swapped the sizes too, which the `window-resize` tests
caught at 10/10), the children order in the combination
(`list-insert-before`, and the order `make-window-parent` builds), and
PIXELWISE - whose SIZE is pixels, converted to the tree's cells at the
edge by the frame's character size.

The failure it caused is exactly the Duplicate report:
`window--state-put-1` splits with **pixel** sizes
(`(split-window-no-error window size horizontal pixelwise)`), every
such call raised a wrong-number-of-arguments inside the guard and
answered #f, `window` in `window--state-put-1` became #f for the last
child, and `window--state-put-2` called `window-parameters` on #f -
"expecting struct: #f". Duplicate's clone *is* `(window-state-put
(window-state-get))` (`tab-bar.el:2085`), so it took exactly that path.

**2. Detach's `frame-live-p` did not reproduce once the split was
fixed** - a clean editor detaches a tab into a new frame correctly
(2 frames, the source keeps its remaining tabs). The reported error
came after a failed Duplicate in the same session: the failed put had
left the window tree half-built (the #f `window` above), and the next
`select-frame` was handed a frame that was no longer live. Named rather
than called fixed-by-itself.

**3. The `hide` prompt rule was missing from `x_popup_menu_1`.** On a
window system "a prompt whose first character has the `hide` text
property is not a title" (`menu.c:1305`, the USE_GTK/NS arm) - which is
precisely what `(propertize "Context Menu" 'hide t)` on the tab bar's
and tab line's context menus is for. The port took the prompt as the
title unconditionally, and the Gtk popup path draws a non-nil title as
a disabled item, so the menu's first line read "Context Menu". The
*pane name* keeps the prompt, as the C's `ASET` does, and on a terminal
the prompt is still the title.

**Named, not fixed**: the tab commands keep Emacs's optional arities
inconsistently - `tab-bar-new-tab`, `tab-bar-duplicate-tab`,
`tab-bar-detach-tab` and `tab-bar-close-tab` are `(&optional ...)` in
Emacs and take every argument as required here, so only the
interactive and menu paths (which pass all of them) work. Nothing the
reported path uses.

Tests: `schemacs_editor_tab_bar_context_menu` grew the two title cases;
`window-state-tests`, `window-config-tests`, `tab-bar-tests` and
`tab-line-tests` are green; the live Gtk run clones a tab and detaches
one into a new frame.

### The tab bar kept its width across a frame resize (2026-11-19)

Chris: *"it starts off with a very wide 1st tab... If I full screen and
duplicate the 1st tab bar then shrink it again, the tab bar size doesn't
change. In real emacs it does shrink it. ... if I right click the 2nd tab
it gives the menu prompt new tab, which is the wrong menu, it's as if it
thinks it shrunk the tabs, but didn't render it."*

One cause, both halves. `tab-bar-auto-width` distributes the tabs across
`frame-inner-width`, and Emacs's docstring is explicit that the widths
"change only when tabs are added or deleted, **or when the frame's
dimensions change**" (`tab-bar.el:1288`). Our `update-tab-bar` is gated
on `update-mode-lines?` (as Emacs's `update_tab_bar` is gated on the
same flags), and **nothing set it on a resize**: the items kept the width
they were first built at. The drawn bar came from those cached items,
while `tab-bar--event-to-item` recomputes the layout at click time -
so the bar drew wide, the hit test was narrow, and a right-click on the
second tab landed past the last one and answered "New tab".

`resize-frame-windows!` now sets `update-mode-lines?` beside the
`FRAME_WINDOW_CHANGE` flag it already set by hand (departed from the C,
which reaches the flag through `window_resize_apply`). That is the
resize's own meaning: the mode line and the tab bar both depend on the
frame's dimensions.

Verified live on a Gtk frame under broadway: resizing the real window
from 80 columns to 26 changed `frame-width` and the cached tab caption
from 32 to 20 characters; before the fix the caption stayed 32.

Tests: `tab-bar-tests`' `schemacs_editor_tab_bar_resize` (3) - the flag
a resize sets, and the caption rebuilt at the new width. **The unit test
calls `update-tab-bar` directly rather than `render!`**, because the
test display's screen size is a fixed 80x24 and a `render!` re-derives
the frame's size from it; the real front ends report the window's own
size.

Also exported on the way: `tab-bar-auto-width-max` (a defcustom) and
`tab-bar-auto-width-min` (a defvar) were carried but unreachable - not
in the export list. The `*`-name the first version of this export gave
the second was wrong twice: Emacs's min is a plain `defvar`.

## The Gtk front end was blurry on a HiDPI display (2026-11-19)

Chris: *"why does schemacs look blurry? Do we somehow render our
graphics at low resolution?... Other apps, terminals, real emacs look
sharp, but schemacs looks fuzzy."*

**It rendered a logical-resolution image and let Cairo upscale it.**
The Gtk front end owns an ARGB32 image surface and paints it into the
cairo context Gtk hands the draw signal. The surface was created at the
widget's *allocation*, which Gtk reports in logical pixels, and painted
1:1 - but on a window whose scale factor is 2 (the measured value on
this machine: `gtk_widget_get_scale_factor` = 2, with Hyprland outputs
at 1.25 and 1.6), a user unit maps to two device pixels, so every
keystroke's pixels were drawn at half the display's resolution and
upscaled 2x. Emacs's own pgtk backend rasterizes glyphs at the device
resolution, which is why it looked sharp beside us.

Fixed by making the surface device-resolution:

* the surface is `allocation x scale` device pixels, and the context it
  is drawn through is scaled by the factor (`cairo-scale cr s s`), so
  every coordinate the renderer hands it stays logical while glyphs are
  rasterized at 2x - Pango goes through the same CTM and hints at the
  device size;
* `pgtk-present!` divides the Gtk context's own scale back out
  (`cairo-scale cr 1/s 1/s`) so the device-sized surface is one source
  pixel per device pixel - without it the corrected surface would be
  *downscaled* instead;
* the factor is read from `gtk_widget_get_scale_factor` (via
  `dynamic-func`, the tree's established FFI) every redisplay, and the
  surface is remade when it changes, so moving the window between
  outputs of different scales is handled.

Measured on the real display: the surface went from 1536x837 to
**3072x1674** device pixels, and a 1:1 crop of the screen shows crisp
glyphs beside the same crop of an editor running the old code, which is
visibly soft.

Notes:

* the grid, `*cell-width*`/`*cell-height*`, `screen-size`, the font
  size and all mouse coordinates stay **logical** - only the surface
  and the drawing context are device pixels; `gtk_widget_get_scale_factor`
  is an integer, so a fractional output (1.25/1.6) renders at 2x and
  the compositor scales down, which is what a GTK3 application can do;
* `pgtk-write-screenshot!` now writes a device-resolution PNG on such a
  display (a sharper screenshot; a display a test made has no widget,
  so its scale is 1 and the pixel tests are unchanged);
* `<pgtk-display>` gained a `scale` slot - a record change, so the
  Guile cache must be cleared.

# The tool bar (2026-11-19)

`tool-bar.el`, `keyboard.c`'s tool bar half, and a real `GtkToolbar`
in the Gtk front end. The user's first question was whether Gtk has a
suitable widget, and the answer corrected an earlier note in this
file: **GNU Emacs's Gtk build does use one.** `gtkutil.c:5524`
`xg_create_tool_bar` calls `gtk_toolbar_new ()`, names it
`"emacs-toolbar"`, sets `GTK_TOOLBAR_ICONS` and the
`primary-toolbar` style class, and connects `size-allocate` to
`tb_size_cb`. The glyph-drawing tool bar in `xdisp.c`
(`display_tool_bar`, `redisplay_tool_bar`) is compiled only under
`#ifndef HAVE_EXT_TOOL_BAR`, i.e. for builds with no toolkit bar - so
`emacs -nw` on a Gtk build shows **no tool bar at all**, and this
tree's terminal front end shows none either. That is a match, not a
departure.

## What is where

| Emacs | here |
|---|---|
| `keyboard.c:10135` `tool_bar_items`, `process_tool_bar_item`, `parse_tool_bar_item`, the `TOOL_BAR_ITEM_*` enum | `keyboard.scm`, a section beside the menu bar's; the slot indices are exported for the front end |
| `tool-bar.el` (mode, map, cache, add-item helpers, setup) | `tool-bar.scm` (new) |
| `image.el:813` `find-image`, `image-search-load-path`, `image-property`, `create-image`, `image-mask-p`; `frame.el:2717` `display-images-p` | `image.scm` (new) |
| `faces.el:1967` `display-color-p` | `faces.scm` |
| `xdisp.c:15673` `update_tool_bar` | `xdisp.scm` `update-tool-bar` |
| `xdisp.c:39003` `tool-bar-style`; `xsettings.c:1348` `tool-bar-get-system-style` | `xdisp.scm` |
| `gtkutil.c:5524` `xg_create_tool_bar`, `:5468` `xg_pack_tool_bar`, `:5600` `xg_make_tool_item`, `:5843` `update_frame_tool_bar`, `:5508` `tb_size_cb`, `:5962` `find_icon_from_name` | `pgtk.scm`, the tool bar section |
| `x-win.el:1377` `x-gtk-stock-map`, `:1473` `icon-map-list`, `:1508` `x-gtk-map-stock` (`term/pgtk-win.el`) | `schemacs/ui/gtk/pgtk-win.scm` (new) |
| `menu-bar.el:253` `menu-find-file-existing` | `menu-bar.scm` |
| `dired.el:1251` `dired-from-menubar` | `dired.scm` |
| `files.el:2016` `find-file-read-args`, `:2130` `find-file-existing` | `files.scm` |

**The icons are the theme's, and the bundled XPMs are only the
fallback** - which is the difference a user sees between this tree's
bar and real Emacs's. `update_frame_tool_bar` (`gtkutil.c:5904`) calls
`x_gtk_map_stock` on each image's file name, `find_icon_from_name`
(`:5962`) tests the mapped names with `gtk_icon_theme_has_icon`, and
the button is made with `gtk_image_new_from_icon_name`; the XPM is
loaded only when the theme has none of them. So `new.xpm` is drawn as
the desktop's `document-new`, `save.xpm` as `document-save`, and so
on. `schemacs/ui/gtk/pgtk-win.scm` ports `x-gtk-stock-map` (the whole
`x-win.el:1377` alist), `icon-map-list` and `x-gtk-map-stock`, and
`schemacs/ui/gtk/pgtk.scm`'s `pgtk-icon-from-theme` is
`find_icon_from_name`. Emacs's own XPMs are still copied to
`schemacs/etc/images/` and are the fallback; GdkPixbuf loads them
natively - measured - so no parser was written.

The tool bar is **coloured with the mode line's pair**, like the menu
bar (`pgtk-theme-menubar!`): the toolbar widget gets the
`schemacs-toolbar` class and the same CSS provider, whose text now
carries rules for `toolbar.schemacs-toolbar`, its buttons, a hover and
its separators. This is a deliberate departure from Emacs - whose Gtk
tool bar takes the desktop theme's toolbar colours - asked for so the
bar reads as one band with the menu bar and mode line; it shares the
provider, so a theme change repaints both.

## Departures, each named where it lives

1. **`[tool-bar]`'s `:filter` is applied by calling the builder**, not
   by the keymap lookup. `tool-bar-items` calls
   `tool-bar-make-keymap` through `*tool-bar-keymap-function*` before it
   walks the maps, and the builder binds the built map at `[tool-bar]`;
   this tree's `get-keyelt` does not apply filters, the same departure
   `tab-bar.el`'s port records. The C reaches `tool-bar-map` through
   the binding's `:filter` inside `access_keymap`.
2. **`tool-bar-map` is the global map only.** Emacs reads a
   buffer-local binding first; this tree has one keymap and no
   buffer-local map lookup for it. A mode that `setq-local`s
   `tool-bar-map` is not honoured.
3. **The cache key is `(cons (current-display) (object-address
   tool-bar-map))`** where Emacs uses `(cons (frame-terminal)
   (sxhash-eq ...))`: Guile has no `sxhash-eq`, and an object's address
   is its identity. `hashq` takes a bucket count and cannot stand in.
4. **"Not yet set up" is a flag**, not Emacs's `(= 1 (length
   (default-value 'tool-bar-map)))` - a keymap here is a record with no
   list length.
5. **`modifier-bar-mode` and the secondary tool bar are not carried.**
   They exist for an on-screen modifier keyboard (no touch input here),
   and Emacs's merge appends keymap *lists*, which a keymap record
   cannot do. `secondary-tool-bar-map` is a variable so a user setting
   it sees no error.
6. **The Gtk buttons are rebuilt when the item vector changes**, where
   the C keeps a widget per item and replaces only the stale ones. The
   comparison that decides *when* is the C's (`tbinfo->last_tool_bar`),
   so the work happens at the same moments; per-item reuse is a
   micro-optimisation the rebuild makes unnecessary.
7. **`tool-bar-position` `left` and `right` fall back to the top.**
   Emacs packs them into an inner horizontal box (`x->hbox_widget`)
   that this front end's window does not have.
8. **The button press's modifier mask is not applied** to the key the
   click stands for; Emacs stores it and folds it into the event.
9. **`image-mask-p` answers nil**, and the spec then gets `:mask
   heuristic` - Emacs's own answer for an image whose mask it has not
   computed. Nothing loads a bitmap here; the toolkit's pixbuf keeps
   the alpha. `:data` images, `:scale` and `:rotation` are not carried;
   `image-load-path` elements are strings only (Emacs also accepts
   variable symbols); `find-image` returns the spec
   `(image :type ... :file ...)`, not an image struct, because there is
   no `image.c` here.
10. **`display-color-p` ignores its DISPLAY argument** and answers from
    the current display's `*display-color-cells*`; every caller here
    asks about that one.
11. **`menu-find-file-existing`'s MUSTMATCH is always t.** The C asks
    `x-uses-old-gtk-dialog`, which is nil unless a pre-3.10 Gtk dialog
    is in use; there is no such dialog here. `menu-find-file-existing`
    and `dired-from-menubar` *are* ported, so the File menu's two
    entries and the tool bar's two buttons now name the commands the C
    names - the earlier `find-file`/`dired` stand-ins are gone.
12. **`tool-bar-style`'s system half is not read.** Emacs asks
    GSettings/GConf; with no setting there the answer is `tool-bar-style`
    or `image`, which is what this tree answers. The default style
    therefore shows images only, as an unconfigured Gtk Emacs does.
13. **`tool-bar-setup` is called from each front end after the first
    frame is made**, where `startup.el:1626` calls it. On the terminal
    front end it builds the keymap and the mode and nothing draws -
    the same state `emacs -nw` is in on a Gtk build.
14. **A tool bar item's image expression is `eval`ed in the tool-bar
    library's module**, where Emacs `eval`s in the global obarray. The
    expression names `find-image` and the display predicates, both
    imported there.
15. **`icon-map-list` holds `*x-gtk-stock-map*` where Emacs's default
    holds the bare symbol `x-gtk-stock-map`**: a defcustom's name here
    carries the parameter convention's asterisks, and `%icon-map-alist`
    resolves that one name (the only symbol this tree can turn into an
    alist). The map lookup is `assoc` with `equal?`, which is
    `assoc-string`'s answer for these plain string keys.
16. **The tool bar's colours are the mode line's**, by the CSS provider
    the menu bar uses. That is a departure from Emacs, whose Gtk tool
    bar is coloured by the desktop theme, and it was asked for: the bar,
    the menu bar and the mode line read as one band. Emacs's
    `primary-toolbar` style class is not added - the class this tree
    adds is `schemacs-toolbar`, which is what its rules select.

## The loop that looked like a Gtk hang

The first live run sat at 99% CPU and never answered. The cause was
not Gtk and not the widget tree: `pgtk-fill-toolbar!`'s named loop had
its recursive call *outside* the `when`, so after the last item it
recurred for ever doing nothing. The debugging path is worth
remembering: prints to stderr looked absent because `current-error-port`
was block-buffered, so `(setvbuf (current-error-port) 'none)` had to
come first; the trace then showed the loop's counter in the millions.
While bisecting, a `container:get-children` on a `GtkToolbar` from the
*user* module raised "Too few in arguments" - guile-gi's generics
resolve per module, so a REPL probe cannot test what `pgtk.scm` can do.

## The cost that was one Gtk call per redisplay

`pgtk-set-frame-toolbar` called `widget:get-allocated-height` on every
redisplay to decide whether to grow the window, and on a toolbar that
call measured **9.5 ms** (a generic `get_allocated_height` on a plain
widget is ~10 µs). Each cursor-blink redisplay therefore burned a
keystroke's worth of CPU. Emacs's `tb_size_cb` is the answer and is now
ported: the toolbar's own `size-allocate` signal calls
`pgtk-grow-by-toolbar!`, and the explicit grow runs only when the bar
was built or shown. Idle CPU with the bar on is 0.0-0.3% again,
measured over `/proc/PID/stat` time deltas.

## Verification

- `tool-bar-tests.scm` (31): the setup's item order (Emacs 31.1's:
  new open diropen close save | undo | cut copy paste | search), the
  captions and the label rule, the twelve slots, the parser's arms
  (`:visible`, `:wrap`, `:label`, `:enable`, `:button`, old-style
  separators), `find-image`/`image-property` against the shipped XPMs,
  the built `[tool-bar]` map and an item's command through it, and the
  mode's frame parameter.
- Live on Gtk under broadway: the bar is packed after the menu bar,
  `(pgtk-toolbar d)` holds it, its children are the items, and
  emitting a probe item's button `clicked` signal put `"TB-CLICK-OK"`
  in the echo area - the whole path, Gtk signal -> queued
  `[tool-bar KEY]` -> keymap lookup -> command.
- The full suite set and the pty battery; the battery's editors run the
  terminal front end with `tool-bar-setup` called, which must change
  nothing on screen.

# The graphical file dialog: `x-file-dialog`, and what makes a command a
# "menu command" (2026-11-19)

Chris: *"can you change it so open from the menu or toolbar has a
graphical open dialog, like real emacs"*. The chooser is Emacs's
`GtkFileChooserDialog`; the interesting half is the rule that decides
*when* to use it, because it is not "from a menu" in so many words - it
is a test on the last input event.

## The chain, from the Lisp down

1. **`read-file-name`** (`minibuffer.el:4001`) calls
   **`next-read-file-uses-dialog-p`** (`fileio.c:6574`), and only when
   that answers yes - and the name is not remote ("Graphical file
   dialogs can't handle remote files (Bug#99)") - does it take the
   dialog branch instead of `completing-read`.

2. **`next-read-file-uses-dialog-p`** is

   ```c
   if ((NILP (last_nonmenu_event) || CONSP (last_nonmenu_event))
       && use_dialog_box
       && use_file_dialog
       && window_system_available (SELECTED_FRAME ()))
     return Qt;
   ```

   `CONSP (last_nonmenu_event)` is the whole trick. `read_key_sequence`
   sets `last_nonmenu_event = key` for every key it reads
   (`keyboard.c:12216`), except when a mouse menu is in use - and a
   menu's own keys are made conses (`keyboard.c:10673`: "(KEY .
   disabled)"). So a command invoked by a keyboard chord has a plain
   event there (not a cons) and gets the minibuffer, while a command
   invoked by a mouse click or a menu selection has a cons and gets the
   dialog. nil ("no event at all", i.e. a call from Lisp) counts as a
   mouse event too.

3. The branch itself (`minibuffer.el:4148-4172`) translates MUSTMATCH
   for the dialog - `nil`, `confirm` and `confirm-after-completion` all
   mean "a name that need not exist", "otherwise it is impossible to
   create new files using dialogs with the default settings" - splits a
   file name out of DIR when no DEFAULT-FILENAME was given, and calls
   `(x-file-dialog prompt dir default dialog-mustmatch (eq predicate
   'file-directory-p))`.

4. **`x-file-dialog`** (`pgtkfns.c:3625`) calls `xg_get_file_name`
   (`gtkutil.c:2804`), which builds the chooser
   (`xg_get_file_with_chooser`, `:2632`) and runs it
   (`xg_dialog_run`, `:2513` - "We don't use gtk_dialog_run because we
   want to process emacs timers"), then makes Cancel "equivalent to
   C-g" with `quit ()`.

## Where each piece lives here

| Emacs | here |
|---|---|
| `last-nonmenu-event` (`keyboard.c`), and the record `read_key_sequence` makes of it | `keyboard.scm`'s `*last-nonmenu-event*` (a parameter: Emacs's Lisp `let`-binds it, e.g. `gud.el:3037`, `ediff-ptch.el:547`) and `record-nonmenu-event!` |
| `use-dialog-box`, `use-file-dialog` (`fns.c:6850`) | `fns.scm` - a parameter and a plain variable, respectively, and the difference is the convention: the first is `let`-bound by Emacs's own Lisp, the second only `setq`-ed |
| `use-dialog-box-override` (`subr.el:4118`) | `subr.scm`, a parameter (Emacs `let`-binds it in `server.el`/`nsm.el`) |
| `next-read-file-uses-dialog-p` (`fileio.c`) | `files.scm`, **a placement departure**: `fileio.scm` is below `keyboard.scm` (keyboard imports simple, which imports fileio), `fns.scm` and `frame.scm`, so it cannot reach the variable or the two switches; it lives beside its only caller, as `locate-file-internal` lives in `fileio.scm` for the mirror of that reason |
| `use-dialog-box-p` (`subr.el:4121`) | `files.scm`, where it already was (defined there for `kill-buffer--possibly-save`); its body is now Emacs's rather than a `#f` with a note saying there were no popup menus |
| `x-file-dialog` (`pgtkfns.c` + `gtkutil.c`) | a `dispnew.scm` generic named after the C function, with the Gtk method in `pgtk.scm`; the `<display>` default is the C's `check_window_system` ("Window system frame should be used") |
| `xg_get_file_with_chooser`, `xg_toggle_visibility_cb`, `xg_dialog_run` | `pgtk.scm`'s `pgtk-build-file-dialog`, `pgtk-toggle-dialog-visibility!`, `pgtk-get-file-name` |
| `x-gtk-show-hidden-files`, `x-gtk-file-dialog-help-text` (`pgtkfns.c:3891`, `:3895`) | plain variables in `pgtk.scm` (Emacs only reads and `setq`s them; they carry the self-assignment that marks them mutable against the compiler) |

## The event-provenance change, and why it is in three places

**A front end has more than one way to hand a key to the command
loop.** `read-key-event` is the read; `dispatch-input-event` is the
hand-over path; and the Gtk front end's `pgtk-drain-queue!` dispatches
queued keys directly when no read is outstanding (its outermost loop
does not read). `last_nonmenu_event` is per key *read*, in the C's
`read_key_sequence`, so all three call `record-nonmenu-event!` now:

- a raw event that is a **cons** - a mouse posn list, or the front
  ends' `(menu-bar-event . KEY)` / `(tool-bar-event . KEY)` tags - is
  recorded as itself, which is the analogue of Emacs's conses;
- anything else is recorded as the key, which is Emacs's
  `last_nonmenu_event = key` for a keyboard chord.

**A departure in the value's shape, not in its rule**: Emacs's menu
selection records the *mouse event that led to the menu*; this tree's
Gtk menu bar never sees that Gdk click (Gtk's widget consumes it), so
what is recorded is the synthetic tagged key. Both are conses and both
answer "this command came from a menu", which is all the two predicates
test. A `<test-display>`-based unit test pins the three shapes.

Also not carried: `from--tty-menu-p` (`subr.el:4110`), which
`use-dialog-box-p` also reads. A terminal menu's command is
indistinguishable here, and a terminal has no dialogs to show anyway.

## The Gtk dialog's own departures

- **`pgtk_menu_set_in_use`** (the C's guard against opening a dialog
  from inside a menu entry) is not carried; the `popup_activated ()`
  check - "Trying to use a menu from within a menu-entry" - is.
- **`inhibit_redisplay`** around the dialog is not carried: this front
  end does not redisplay from inside a nested loop.
- **`minibuffer-maybe-quote-filename`** is not ported, so the dialog
  branch files the chosen name in `file-name-history` as the chooser
  answered it. (The minibuffer branch has never quoted its history
  entry either; the omission is pre-existing, not new.)
- **The `notify::show-hidden` sync** from `xg_toggle_notify_cb` is not
  carried - guile-gi's `<signal>` takes no detail name, and the
  right-click-in-the-file-list path that needs the sync is a Gtk
  internal. The toggle itself still drives the dialog
  (`xg_toggle_visibility_cb` is ported).
- The chooser is made with `(make <GtkFileChooserDialog>)` and given
  its action and buttons afterwards: the typelib exports no
  `file-chooser-dialog-new`, because the C constructor is variadic with
  button strings. The result is what `gtk_file_chooser_dialog_new` with
  those two buttons is - measured under broadway, not inferred.

## Verification

- `tools/pty-check.py` stands; `C-x C-f` still prompts in the
  minibuffer on a terminal (where the predicate is false for two
  reasons: the last event is a key, and there is no window system).
- `tty-editor-tests.scm`'s `file_dialog` group (12): a stub chooser on
  a `<test-display>` that answers `window-system-display?` true records
  `read-file-name`'s five arguments; a menu's cons takes it and a typed
  key does not; `confirm`/`confirm-after-completion` become nil;
  `read-directory-name` passes `file-directory-p` and so asks for a
  folder chooser; the chosen name lands in `file-name-history`; and
  `record-nonmenu-event!`'s three shapes (menu cons, mouse posn list,
  keyboard key).
- **Live, on a Gtk editor under broadway**, the whole chain: a
  `GtkFileChooserDialog` titled with the prompt appeared, accepted a
  file name and answered OK, and `read-file-name` returned it - then
  the real menu path: `(menu-bar-event . menu-bar)`, `(file)`,
  `(open-file)` enqueued through `pgtk-enqueue!` made the drain record
  the cons, `menu-find-file-existing` ran, the dialog opened, and the
  chosen file became the current buffer's. The Gtk widget itself has no
  unit test (constructing widgets needs a display, which the suite
  runner has not).

## The two ownership bugs the dialog crashed on (2026-11-19)

Chris, after using it: *"I clicked open in toobar, cancel. open, cancel.
Open, cancel. It core dumped."* - with four `g_object_unref:
assertion 'G_IS_OBJECT (object)' failed` criticals at one instant, and
then a later run with `g_main_loop_unref: assertion
'g_atomic_int_get (&loop->ref_count) > 0' failed` lines and a SIGSEGV.
Both are guile-gi ownership, and both were mine.

1. **The dialog's widget proxies must be held, as the menu bar's are.**
   `(make <GtkFileChooserDialog>)` and the three widgets of its extra
   widget are proxies; the dialog is destroyed after it closes, and
   when the proxy is collected guile-gi releases its toggle reference
   and *then* calls `g_object_unref` on the object it has just released
   - the double release this tree already documents for a closed
   window (`*pgtk-destroyed-displays*`' note). Four widgets, four
   criticals, one per dialog's worth of collected proxies. Fixed by
   `pgtk-hold-widget!`-ing all four, the same rule and the same cost
   (the proxies stay in the display's list) as the menu and tool bars.

2. **`g_main_loop_new`'s reference belongs to guile-gi, so an explicit
   `main-loop:unref` is a second unref.** Emacs's `xg_dialog_run`
   unrefs its own loop because the C owns it; here the proxy does.
   Calling `g_main_loop_unref` ourselves put the count at zero, the
   finalizer then unref'd freed memory - GLib's assertion, and after a
   few cycles a SIGSEGV inside `g_malloc` while the *next* dialog was
   being built from its template (the core dump's stack:
   `gtk_widget_init_template` -> `gtk_builder_extend_with_template` ->
   `g_markup_parse_context_parse` -> `g_malloc`). Dropping the explicit
   unref fixed it: five open/OK cycles and three open/Cancel cycles,
   each followed by `(gc)`, ran with zero criticals and the editor
   alive.

   **The same unref was in `pgtk-wait!`** for a nested loop - the
   first instance of the bug, and the reason to look there was this
   one. It is removed too. It was reachable only by a read nested
   inside another read (an isearch key, a REPL expression evaluated
   from the wait), which is why it had survived.

Not a bug in this code, and worth recognising so it is not chased:
`gtk_tree_drag_source_drag_data_delete: assertion
'iface->drag_data_delete != NULL' failed` is a GTK3 file-chooser
internal (the tree view's drag source) and is a critical line, not a
crash. It comes from interacting with the chooser's file list, not from
the dialog's construction or teardown.

## dired's prompt, and the arm a dialog changes (2026-11-19)

`dired-read-dir-and-switches` (`dired.el:1124`) had been ported with
one arm always taken, under a note saying "there is no dialog here".
There is: the menu's and the tool bar's Dired go through
`x-file-dialog`, and the C's rule is

```elisp
(if (next-read-file-uses-dialog-p)
    (read-directory-name ...)   ; the dialog must ask for a directory
  (read-file-name ...))         ; typed: wildcard completion wanted
```

Ported as it stands. A typed `C-x d` is unchanged (the predicate is
false for a key), and a menu's Dired now gets the folder chooser.
`tty-editor-tests.scm`'s dialog group pins the dialog arm with the
stub chooser.

# The search's tool bar, and the buffer-local `tool-bar-map` (2026-11-19)

Chris: *"our toolbar is different to emacs in that hitting search in
real emacs brings up a sub toolbar."* It does, and the mechanism is a
buffer-local variable:

```elisp
;; isearch-mode, isearch.el:1309
(if (local-variable-p 'tool-bar-map)
    (setq isearch-tool-bar-old-map tool-bar-map))
(setq-local tool-bar-map isearch-tool-bar-map)
...
;; isearch-done, isearch.el:1507
(if isearch-tool-bar-old-map
    (progn (setq-local tool-bar-map isearch-tool-bar-old-map)
           (setq isearch-tool-bar-old-map nil))
  (kill-local-variable 'tool-bar-map))
```

Emacs's `tool-bar-map` is buffer-local-aware, and `tool-bar-make-keymap`
reads the current buffer's value. **This tree's was one global map** -
the tool bar library's header said so by name ("a buffer-local
`tool-bar-map` is not carried") - which is exactly what made the search
bar impossible. Now:

- `%tool-bar-map` answers the buffer's own value when it has one
  (`local-variable-p` + `buffer-local-value`), or the global map; and
  `tool-bar-always-show-default` asks for the global map, as Emacs's
  `tool-bar--cache-key` does.
- **`local-variable-p` is new** (`data.c:2416`), in `buffer.scm` beside
  `kill-local-variable`, whose store it reads. `isearch-mode` is its
  first caller.
- **`isearch-tool-bar-map`** is `isearch.scm`'s, with Emacs's six
  reachable items - Repeat backward, Repeat forward, Abort, Finish,
  Undo, Help - in Emacs's definition order. The two omitted:
  **"Show hits"** is `isearch-occur`, which needs `occur` (replace.el's
  second half); **"Replace"** is `isearch-query-replace`, which is
  replace.el's and not ported. Their icons are in
  `schemacs/etc/images` for when they come.
- **`:visible`/`:filter` on the items are not carried**:
  `menu-item-eval-property` evaluates in the *current* module, which
  during a redisplay is not this library, so a form naming
  `isearch-string` would fail to evaluate; the bar is always shown and
  "Abort" does what C-g does (`isearch-abort`), which is what Emacs's
  filter picks while the search is failing.
- **A tool-bar click is two events.** The command loop's modal lookup
  walks `tool-bar` then the item's key; the search reads its own keys
  and has no lookup, so `isearch` pairs the two itself, and each item's
  key is translated to the code of the key it stands for (C-s, C-r,
  RET, C-g, DEL). `isearch-describe-mode` is a real command and runs.
- `isearch-tool-bar-image` is Emacs's function; `tool-bar--image-expression`
  **moved to `image.scm`** (a placement departure): `tool-bar.scm`
  imports `isearch.scm` for `isearch-forward`, so an import in the other
  direction would be a cycle, and both need the builder. `tool-bar.scm`
  imports `isearch-tool-bar-image` by name because the item's `:image`
  form is evaluated *in tool-bar.scm's module*.

## The icons that disappeared, and why

Moving `tool-bar--image-expression` to `image.scm` also removed the
`face-attribute`/`display-color-p`/`*display-color-cells*` import from
`tool-bar.scm` - its own code no longer called them. **But the image
*forms* do**: `%tool-bar-eval-image` evaluates
`(find-image (cond ((not (display-color-p)) ...)
((< (*display-color-cells*) 256) ...)))` in tool-bar.scm's module, and
with the names unbound the evaluator's guard answered nil and every
icon silently vanished, leaving the text labels. Chris saw it as "the
icons have disappeared from the toolbar". The import is restored, with
a comment saying it is there for the forms, not for the code.
`tool-bar-tests.scm`'s isearch group pins it: every item's image slot
is `(:mask heuristic)` on a non-graphic display, which it can only be
if the expression evaluated.

## Verified

- `tool-bar-tests.scm` +3 (34): the search bar's items in Emacs's order,
  a buffer-local `tool-bar-map` being what the bar is built from, and
  the images being evaluated.
- `tty-editor-tests.scm` +3 (344): a scripted `tool-bar` + `isearch-exit`
  leaves the search with the RET branch's effects; `isearch-cancel`
  quits; and the buffer has no local `tool-bar-map` before or after a
  search.
- Live on a Gtk editor under broadway, by REPL: entering a search sets
  the buffer-local map to `isearch-tool-bar-map` (recorded from inside
  the search), the frame's built `tool-bar-items` are the six search
  items with their XPMs resolved, a queued `tool-bar` + `isearch-exit`
  click ends the search through the RET branch, and the search's exit
  removes the local binding.

# The tool bar's style, labels and greying, and the Replace button
# (2026-11-20)

Chris: *"search toolbar doesn't look fully implemented, we have 6 icons,
emacs has 7. And the 4th icon seems wrong... emacs has an icon labeled
undo in the 4th slot. Also why do some emacs icons have labels and ours
never do? And if that's customisable, do we have the same customs? also
real emacs greys out toolbar items that are not applicable like save and
undo when there are no changes."* Four questions, three of them
departures and one a missing subsystem.

## 1. The labels: `tool-bar-get-system-style` was not asking the desktop

GNU Emacs's Gtk build draws icon+text bars because it asks the *desktop*
what style it wants: `Ftool_bar_get_system_style` (`xdisp.c`) reads
`tool-bar-style` (nil here) and falls back to the toolkit's answer -
`xg_get_tool_bar_style` in `xsettings.c`, which reads GSettings schema
`org.gnome.desktop.interface`, key `toolbar-style` (`xsettings.c:227`),
mapping `"both"`/`"both-horiz"`/`"icons"`/`"text"` to
`both`/`both-horiz`/`image`/`text` (`map_tool_bar_style`, `:150`). A
GNOME-style desktop sets `both-horiz`; measured on this machine,
`(settings:get-string ... "toolbar-style")` is `"both-horiz"`, and a real
Emacs 31.1 here shows icon+label bars.

The tree's `tool-bar-get-system-style` fell straight to `image`, so ours
never had labels. Ported:

- **`tool-bar-get-system-style`** has the C's rule now: the four
  explicit styles pass through, anything else asks the front end through
  the seam **`*tool-bar-system-style-function*`** and falls back to
  `image`.
- **`pgtk-tool-bar-system-style`** is the Gtk method: GSettings read
  through the Gio typelib (loaded by `pgtk-names.scm`), with
  `xg_settings_key_valid_p`'s schema/key check first - `g_settings_new`
  *aborts* on an uninstalled schema - and a `changed` signal that does
  what `dynamic-setting.el:85` does, `(force-mode-line-update t)`.
  **The answer is cached** in `%pgtk-tool-bar-style`, which is Emacs's
  `current_tool_bar_style` (`xsettings.c:1005`): reading it crosses
  guile-gi (~3.5 ms, the cost the menu-bar note measured) and the bar
  is rebuilt on every keystroke that forces the mode line - a search
  does that on every key. The `changed` handler is the cache's refresh,
  as `store_tool_bar_style_changed` (`xsettings.c:176`) is Emacs's.
  **And the up-to-date test compares it**: `update_frame_tool_bar`'s
  "Are we up to date?" (`gtkutil.c:5919`) tests `Fequal (tbinfo->style,
  style)` beside the item vector, and that is what makes a live
  `toolbar-style` change rebuild the bar - the labels and the box
  orientation are decided at fill time, not in the vector.
  `pgtk-toolbar-items` caches `(STYLE . ITEMS)` so one `equal?` covers
  both; verified live by setting `tool-bar-style` to `image` and back
  (the cache follows, so the bar refilled).
- **`xg_make_tool_item` (`gtkutil.c:5594`) is ported whole** in
  `pgtk-make-tool-item`: a `GtkToolItem` around an event box ("here so we
  can have tooltips on disabled items"), a relief-less button, and a box
  oriented horizontal for `both-horiz`/`text-image-horiz` and vertical
  otherwise, image before label except for `text-image-horiz`, every
  pack `TRUE TRUE`. The label rule is the C's
  (`update_frame_tool_bar:5948`): none for `image` style or for a
  `:vert-only` item when the layout is horizontal.
- **The label text** was already derived in `parse-tool-bar-item`
  (`:label`, else the caption with trailing dots dropped and `-` as
  space, `upcase-initials`, dropped past `tool-bar-max-label-size`), so
  nothing else was needed.

Verified live under broadway: `(tool-bar-get-system-style)` answers
`both-horiz` in the editor; the frame's item vector carries the labels
("New File", "Open", "Save", "Undo", "Search", ...); the bar rebuilt
with the new item layout and its allocated height changed with the
label rows (41 px). **The widget-level look is the one thing not
automated**: guile-gi's generics cannot be called from the REPL session
module (the documented "Too few in arguments" family), so the
introspection was done by reading the item vector and the code.

## 2. The 4th button: `:visible` was supported, the form was missing

Emacs's `isearch-tool-bar-map` (`isearch.el:807`) has eight items;
"Finish" carries `:visible '(not (string-equal isearch-string ""))`
(`:829`), so at rest Emacs shows seven with **Undo fourth**. Ours showed
six with Finish fourth, which is what Chris saw ("the 4th icon is
visually a repeat of icon 3").

`:visible` was already read by both `parse_menu_item` and
`parse_tool_bar_item` (it evaluates the form through
`menu-item-eval-property` and drops the item). What was missing was the
*state* and the form:

- **The search publishes its state as Emacs's globals**
  (`isearch-string`, `isearch-success`, `isearch-case-fold-search`,
  `isearch-other-end`, `isearch-regexp`) at the point each loop
  iteration corresponds to Emacs's `isearch-update`. They are plain
  variables with the double-assignment against constant folding, as
  `menu-bar`'s `(set! *x* *x*)` rule requires.
- **The loop calls `force-mode-line-update` each iteration**, which is
  Emacs's `isearch-update` line: it is what makes the bar re-parse the
  map, so Finish appears with the first character and goes with the last.
  The state variables are plain variables, not parameters: Emacs
  `defvar`s them and `setq`s them.
- **`string-equal`** (`fns.c:339`) is ported to `fns.scm`: the form is
  Emacs's own text, so the function it names has to exist.
- **`isearch-forward` (the variable) is NOT carried**: it shares its
  name with the command C-s runs and a Lisp-1 has one binding
  (`isearch-forward` is the command; nothing in the query-replace path
  reads the direction - BACKWARD comes from the prefix argument). This
  is the `comment-add`/`tab-bar-separator` collision class.

Verified live on Gtk: with "888" typed the built bar is
`(repeat-backward repeat-forward Abort Finish Undo Replace Help)` - the
same positions as Emacs; deleting the string rebuilds it as
`(repeat-backward repeat-forward Abort Undo Replace Help)`.

## 3. The greying: the menu items' `:enable` forms, and the undo table

The tool bar's Save/Cut/Copy/Paste/Undo items are *copies of the Edit
menu's* (`tool-bar-add-item-from-menu` appends the menu item's
properties, `:enable` included), so the fix is at the menu:

- **Undo** (`menu-bar.el:611`): `(and (not buffer-read-only) (not (eq t
  buffer-undo-list)) (if (eq last-command 'undo) (listp
  pending-undo-list) (consp buffer-undo-list)))` - ported literally,
  with `#t` the `t` sentinel and `*pending-undo-list*` using `t`'s
  spelling at exhaustion.
- **Redo** (`:600`): `(and (not buffer-read-only)
  (undo--last-change-was-undo-p buffer-undo-list))` - which needed the
  machinery under it: **`undo-equiv-table` (`simple.el:3422`)** and
  **`undo--last-change-was-undo-p` (`:3466`)** are ported, the table
  filled where Emacs fills it (after the undo, from the leading
  boundary-stripped front of the buffer's undo list to the new pending
  list, with the C's `'empty` identity guard), and `undo-redo`'s three
  assignments (`this-command`, `pending-undo-list`, `buffer-undo-list`)
  are the Lisp's. **The `*last-change-was-undo*` flag is gone** - it
  was this tree's stand-in for the table, and Emacs has no such
  variable; the command loop no longer clears anything.
- **`*pending-undo-list*` now holds the `t` sentinel at exhaustion**,
  as Emacs's does (`undo-more`'s `(setq pending-undo-list t)`); the
  old `#f` was a named departure with an inverted sense.
- **Paste** (`:556`): `(and (not buffer-read-only) (or
  (gui-backend-selection-exists-p 'CLIPBOARD) kill-ring))` - the ring
  arm is `(pair? (*kill-ring*))`, because Elisp's empty ring is nil and
  Scheme's `()` is true.

**`selection-exists?` on Gtk was blocking**, and that is a departure
Emacs does not have: the C's `pgtk-selection-exists-p`
(`pgtkselect.c:1747`) asks `gdk_selection_owner_get_for_display` - a
property of the display, answered at once - where the port asked
`gtk_clipboard_wait_is_text_available`, which asks the owner and waits
for the answer, inside a redisplay path. Ported with the C function
through FFI (`gdk_window_get_display` beside it). **Measured: a real
Emacs 31.1 on this desktop answers nil for both CLIPBOARD and PRIMARY
even with `wl-copy` owning the clipboard** - GDK's Wayland backend does
not report selection owners - so Paste is enabled here by the kill ring
alone, which is exactly what Emacs shows in the same seat. That is why
the answer looked "wrong" against the old blocking check: the old one
was the departure.

Verified live: the frame's built item vector shows Save/Undo/Paste
disabled on an unmodified buffer with an empty ring, and
`menu-bar-menus-tests` pins the three forms against the states a user
moves through (fresh `#f #f`, edited `#t #f`, undone with
`last-command` still `undo` `#f #t`, settled `#t #t`, and Paste
`#f`/`#t` across a ring push) - the expectations taken from Emacs 31.1.

## 4. The Replace button: `isearch-query-replace`

**A placement departure**: Emacs's command is `isearch.el:2399` and
lives in `replace.scm` here, because `perform-replace` and
`query-replace-read-to` are there and `replace.scm` is the library that
*imports* `isearch.scm` - the other file order is a cycle.

**The search exits before the command runs**, which is Emacs's own
order (`isearch-query-replace` begins `(isearch-done nil t)`): the
button's branch calls `isearch-done` (a function now, factored out of
the RET branch - it is what the RET branch *was*) and answers a thunk;
`isearch` runs the thunk after its `dynamic-wind`, so the buffer's own
tool bar is back before `perform-replace`'s prompt loop and the TO
minibuffer read. `isearch-done` no longer clears `isearch-other-end` -
Emacs's does not, and the command reads it to put point at the match's
beginning.

Not carried from the command, each named in its source: the
`(if regexp-flag (setq isearch-regexp t))` arm and
`isearch-query-replace-regexp` (the search is literal-only);
`search-invisible`/`isearch-invisible` (nothing makes text invisible);
`replace-lax-whitespace`/`replace-regexp-lax-whitespace` (lax
whitespace is not ported); `isearch-recursive-edit` (the search is a
loop, not a recursive edit, so there is no `exit-recursive-edit` tail);
and `query-replace-read-to`'s DELIMITED/BACKWARD arguments, which this
tree's reader does not take.

**Not the seventh button**: "Show hits" is `isearch-occur`, which runs
`occur` - replace.el's second half, ~1500 lines (`occur`, `occur-1`,
`occur-engine`, `occur-mode`, `occur-edit-mode`,
`occur-after-change-function`, the target text properties), which is
not ported. That is why the bar has six buttons at rest where Emacs has
seven.

## Found under it: `force-mode-line-update` set the *strong* flag

The search now calls `force-mode-line-update` on every key - Emacs's
`isearch-update` line, and what makes the tool bar re-read
`isearch-string` - and `tools/pty-check.py`'s `isearch-multiline`
immediately went red: the search's own match highlight stopped being
drawn.

The cause was in `force-mode-line-update` itself, not in the search.
Its body set **both** `windows-or-buffers-changed?` and
`update-mode-lines?`; the C (`buffer.c:1543`) sets only
`update_mode_lines` - `update_mode_lines = 10` for ALL, the window's
`update_mode_line` otherwise - and never the strong flag. Here the
strong flag is read by `render!` as "the frame is garbaged" (clear the
surface, throw the matrices away; the narrowing fix made that
connection), so every search key retired the whole frame and the
match overlay's paint went with it. Fixed at that level: the function
sets `update-mode-lines?` alone, which is what the mode lines and both
bars read, and the two flags mean what they mean in the C. The
comment it carried ("It sets `windows_or_buffers_changed`, which is
what Emacs's does") was wrong about the C; the corrected one cites the
body.

This is a departure the tree had since the narrowing work: nothing
before the search called this function *during* a redisplay-heavy
command, so only the pty check could see it. The check existed for the
overlay mechanism and caught a flag overreach three layers away.

## The thing this pass adds to the environment lesson

An item's `:enable`, `:visible` and `:filter` forms are evaluated in
`(current-module)` - the ambient module, which in a running editor is
`(guile-user)` after `open-user-environment!` has given it the editor's
names. That is the obarray stand-in and it works, but it means **a
user's `imports.scm` that omits `(schemacs editor imports)` greys the
menu bar's items out**, because their forms' names stop resolving and
`menu-item-eval-property`'s guard reads an unbound variable as nil.
Named here rather than fixed: Emacs's obarray has no such failure mode,
and the nearest honest fix is the one already written down - the item
evaluator should use the *default* editor environment, not the user's.
The same rule caught two of this pass's own tests: a suite's module has
to import `string-equal` and `isearch-string` for the Finish button's
form to resolve, exactly as the editor's environment does.

# Occur, `isearch-occur`, and the tool bar's Show hits item (2026-11-20)

The C source each rule was taken from, and every place this tree differs.

## `replace.el`'s Occur

| Emacs | here |
|---|---|
| `regexp-history`, `occur-collect-regexp-history`, `occur-highlight-overlays` (`:1085-1094`) | `replace.scm`, history *records* rather than lists (see below) |
| `read-regexp` (`:1165`) | `replace.scm`, reduced - see the departures |
| `defface match`, `list-matching-lines-*`, `occur-excluded-properties` (`:1960-2024`) | `replace.scm`, `define-custom` (parameters) |
| `occur-read-primary-args` (`:2026`) | same |
| `occur-rename-buffer` (`:2061`) | same |
| `occur` (`:2078`) | same, REGION in a rest parameter |
| `occur-regexp-descr` (`:2233`) | same |
| `occur-1` (`:2242`) | same |
| `occur-engine` (`:2325`), `occur-engine-line`, `-add-prefix`, `occur-accumulate-lines`, `occur-context-lines` | same |
| `occur--garbage-collect-revert-args` (`:1660`), `occur-mode` (`:1666`), `occur-revert-function` (`:1712`), `occur-mode--find-occurrences`, `occur-mode-goto-occurrence(-other-window)`, `occur-mode-display-occurrence`, `occur--set-arrow`, `occur--highlight-occurrences`, `occur-find-match`, `occur-next`, `occur-prev`, `occur-next-error`, `occur-mode-map` | same |
| `isearch-occur` (`isearch.el:2475`) | `replace.scm`, see the placement note |

### The shape departures

1. **Histories are records, not lists.** `regexp-history` and
   `occur-collect-regexp-history` are `<history>` records because that is
   what this tree's `read-from-minibuffer` takes; Emacs passes a *symbol*
   naming a variable, and `read-regexp` reads it with `symbol-value`.
   `occur-collect-regexp-history`'s default `("\\1")` is the record's
   first entry.
2. **`occur-revert-arguments` is a buffer-local slot**, read through a
   procedure of that name and written with `set-buffer-local-value!`.
   `occur--garbage-collect-revert-args` is on the *global*
   `kill-buffer-hook` (the LOCAL argument of `add-hook` is not carried)
   and guards itself; `%kill-buffer` runs the hook with the dying buffer
   current, as `set_buffer_internal` does (`buffer.c:1946`).
3. **The occur buffer's coding system** is written to the buffer-local
   slot directly where `occur-engine` calls
   `set-buffer-file-coding-system` (`replace.el:2707`): that function is
   `mule-cmds.scm`, a front-end library, and `replace.scm` importing it
   would drag the front ends into the core. The slot is what the C sets;
   the validation and `last-coding-system-used` half of
   `set-buffer-file-coding-system` are skipped.
4. **`buffer-undo-list`** is bound to t around the initial erase in
   Emacs (`replace.el:2290`); there is no per-buffer undo-list variable
   to bind here, and the buffer is made read-only and regenerated, so
   its inserts were never meant to be undoable.
5. **`occur` takes REGION as a rest parameter.** Emacs's interactive
   form appends the region only when one is active, and this tree's
   `define-command` passes the interactive expression's list to a
   procedure of fixed arity - so a 3-required-parameter `occur` was an
   arity error at M-x. `occur-next-error`'s optional RESET is the same.
6. **`occur-mode` is defined after its commands.** Emacs's `occur-mode`
   body names `occur-revert-function` and `occur-next-error`, which are
   defined later in the file; `derive-mode` is a Scheme procedure whose
   body looks the names up when it runs, so the definition order is
   moved to where the references resolve, as every `define-key` in this
   tree is.
7. **`occur-mode-hook` is a plain list**, not a `define-custom`
   parameter: `define-derived-mode` hands the hook to `run-mode-hooks`
   as a value, and a parameter there would be applied. Its default is
   set to `(turn-on-font-lock)` after the definition, which is also what
   marks it mutable against the compiler's constant folding.
8. **The map's missing keys.** `n`/`p` (`next-error-no-select`/
   `previous-error-no-select`), `l` (`recenter-current-error`),
   `C-c C-f` (`next-error-follow-minor-mode`), `c` (`clone-buffer`) and
   `e` (`occur-edit-mode`) are not bound because those commands are not
   ported; the `[menu-bar occur]` entry waits on `easy-menu`.

### `read-regexp`

Ported with `regexp-history-last`, a string default, a list default's
first element and a function default; **not carried**: `read-regexp-map`
and its `M-s c` toggle (so the answer carries no `case-fold` text
property and `read-regexp-case-fold-search` is not here);
`read-regexp-suggestions` and the `M-n` list of standard suggestions
(this tree's `read-from-minibuffer` takes one DEFAULT where Emacs takes a
default *list*); and the `history-add-new-input` binding is a
`parameterize` over the same variable.

### `isearch-occur`, and the property Emacs does not set

Emacs 31.1's command exits the search first only when the *symbol
property* `isearch-exit` is non-nil on it, and **nothing in Emacs 31.1
puts that property on `isearch-occur`** - measured,
`(get 'isearch-occur 'isearch-exit)` is nil in `emacs -Q --batch`, and
`git log -S` shows the property-handling commit (`4ad8bd9b483`) added the
test and no `put`. The commit message says how it is *meant* to be used;
nothing uses it. So the search is still running when `occur` displays
its buffer, and the next key continues the search. This tree's loop
copies that: the item's key runs the command through
`call-interactively` and the loop goes on. `isearch-occur` lives in
`replace.scm` because it calls `occur` and `region-bounds`, and
`replace.scm` is the library that imports `isearch.scm` - the same
placement departure `isearch-query-replace` carries.

Not carried in it: `with-isearch-suspended` around the collect prompt,
and the two `isearch-regexp-function` arms of the regexp conversion
(this tree's search is literal and `isearch-regexp-function` does not
exist).

## The tool bar item, and the label question

`isearch-tool-bar-map` gains Emacs's `[isearch-occur]` item -
`(menu-item "Show hits" isearch-occur :help "Show each search hit"
:image '(isearch-tool-bar-image "index"))` - between Help and Replace in
the definition order (the bar displays in reverse), and
`schemacs/etc/images/index.xpm`/`.pbm` are copied from Emacs's
`etc/images` beside `search-replace.xpm`/`.pbm`, which were missing too
and had left the Replace button without its icon.

"Why does real Emacs show `Repeat forward` as text?" has two halves, and
the second was a real bug here:

1. `xg_make_tool_item` (`gtkutil.c:5594`):

       Lisp_Object label = (EQ (style, Qimage) || (vert_only && horiz))
                           ? Qnil : PROP (TOOL_BAR_ITEM_LABEL);

   with this desktop's GSettings `toolbar-style` both-horiz. The main
   bar's items are all `:vert-only t` (`tool-bar.el:330-348`), so their
   labels are hidden on a horizontal bar; the isearch bar's are not
   `:vert-only` (`isearch.el:807-844`), so each draws its label.

2. The label must survive `parse_tool_bar_item`'s cut: longer than
   `tool-bar-max-label-size` and the slot is set to the empty string
   (`keyboard.c:10555`). **Emacs's default is 14**
   (`DEFAULT_TOOL_BAR_LABEL_SIZE`, `dispextern.h:3510`); this tree had
   10. "Repeat Forward" - `upcase-initials` of the caption - is exactly
   14, so Emacs draws it and we dropped it; "Repeat Backward" is 15 and
   neither shows it. The default is 14 now, and `tool-bar-tests.scm`
   pins the search bar's label list and the main bar's "Open Directory"
   (also 14 characters, also previously dropped).

## The primitives added for occur, and their own departures

- **`rename-buffer`** is now `(rename-buffer NEWNAME &optional UNIQUE)`
  acting on the current buffer, as `buffer.c`'s DEFUN is. It took a
  BUFFER first until this pass; the callers in `files.scm` and the tests
  are updated. Still not a command: its interactive spec reads with
  `read-string`, which is the minibuffer's, above `buffer.scm`.
- **`ngettext`** (`editfns.c:3180`): the C's body is its own placeholder
  (`(if (= n 1) msgid msgid-plural)`).
- **`kill-buffer-hook`** (`buffer.c:4953`) is a parameter, run at
  `buffer.c:1999`'s place with the dying buffer current. The buffer-local
  half of the hook is not carried (`add-hook`'s LOCAL needs a hook to be
  a buffer-local variable).
- **`get-buffer-window`** takes Emacs's optional BUFFER-OR-NAME and
  ALL-FRAMES. `'visible` and 0 are every frame because every frame here
  is visible.
- **`save-selected-window`** saves and restores the selected window
  only; `select-window` does not switch frames here (its own departure),
  so the per-frame half of Emacs's save has nothing to restore.
- **`region-bounds`**: the default `region-extract-function`'s single
  pair. Rectangular regions and the function itself are not carried.
- **`next-error`'s variables and `next-error-found`** are in
  `simple.scm`, with the `next-error`/`next-error-message` faces; the
  command is not ported. `next-error-message-highlight` writes its
  overlay into a buffer-local slot read the same way.
- **`face-differs-from-default-p`** (`faces.el:304`) is in `faces.scm`;
  it passes the attributes alone to
  `display-supports-face-attributes-p`, which takes one argument here
  where Emacs's takes FRAME too.
- **`overlay-arrow-position`/`overlay-arrow-string`** are plain variables
  in `xdisp.scm` (`xdisp.c:38716`); `display_line`'s walk of
  `overlay-arrow-variable-list` that draws the arrow is not ported, so
  `occur--set-arrow` sets the marker and nothing draws it.

# The mouse-1 follow-link path, and `char-property-alias-alist`
# (2026-11-20)

Chris: *"in real emacs the show hits *occur* window is clickable with
the mouse to take you to the occurance. Also the 'xxx matches' line is
shown underlined and the linenumbers are shown in a different color."*
Each of the three needed something the tree did not have; this is what
each was measured against.

## The symbolic mouse modifiers - `termhooks.h`, `keyboard.c:6760`

Emacs's event symbols carry the modifiers `click`, `down`, `drag`,
`double`, `triple`, `up` (`termhooks.h`'s `CHAR_CLICK` and the five
beside it), and `make_lispy_event` adds `click` **implicitly**: a
release is `mouse-N` and its modifiers are `(click)`, unless the
symbol already names `down`, `drag`, `double` or `triple`.
`parse_modifiers` (`keyboard.c:6827`) reads the words out of the name.

Measured on `emacs -Q --batch` (every one is now a test in
`character-tests.scm`):

    (event-modifiers 'mouse-1)        => (click)
    (event-modifiers 'down-mouse-1)   => (down)
    (event-modifiers 'C-down-mouse-1) => (control down)
    (event-modifiers 'up-mouse-1)     => (click up)
    (event-modifiers 'wheel-up)       => (click)
    (event-modifiers 'mouse-movement) => nil
    (event-convert-list '(down click mouse-1)) => down-mouse-1

**`event-convert-list` never writes `click`**: it is implicit in
`mouse-N`, so the way back is not a round trip through the text. That
is Emacs's rule, not a departure.

The bits are `(up 1, down 2, drag 4, click 8, double 16, triple 32)`
above the six named modifiers, in `character.scm`; `event-modifiers`
answers them in descending bit order, which is what Emacs prints.

## The follow-link path - `mouse.el:67-206`

`mouse-1-click-follows-link` (450 ms), `mouse-1-click-in-non-selected-
windows` (t), `mouse--last-down`, `mouse--down-1-maybe-follows-link`,
`mouse--click-1-maybe-follows-link`, `mouse-posn-property`,
`mouse-on-link-p` and the four `key-translation-map` bindings are in
`mouse.scm`. The observable rule: a mouse-1 release inside the time
limit, over text whose `follow-link` property (or `[follow-link]`
binding, or `mouse-face`) says so, is translated into a `mouse-2` event
**at the same position**; a longer press, a drag (`drag-mouse-1`, which
the map does not bind) and a click off a link keep the ordinary
mouse-1 binding.

### The departures, and one bug they hid

- **`mouse-double-click-time` and the click count are not carried**:
  neither front end makes double- or triple-click events (the GTK
  backend has no click clock), so `mouse--click-1-maybe-follows-link`'s
  `'double` branch can never see a `double-mouse-1` from the display.
  The branch is ported because the variable is Emacs's; the event is
  not made.
- **`mouse-1-double-click-prefer-symbols`** (`mouse.el:101`) is not
  carried; it is read only by `mouse-skip-word`, which this tree does
  not have.
- **`mouse-posn-property`'s `follow-link` *key-binding* arms are called
  without a POSITION** (`(key-binding [follow-link] #f)`), because this
  tree's `key-binding` has no POS argument and no `keymap` text-property
  lookup of its own. A position-specific map would not be consulted;
  nothing here makes one.
- **The keyboard path is `dispatch-key`, event by event.**
  `key-translation-map` in the C is consulted by `read_key_sequence`
  while assembling a sequence; here one read is one event, so
  `function-key-translate` applies `function-key-map` and then
  `key-translation-map` to that event. A translator's answer is read as
  a key sequence whose **first** event is the key - which is all any
  translator here answers.
- **A translated event that is a cons replaces `*last-read-event*`.**
  Emacs's translator *mutates* `last-input-event`'s car
  (`(setf (car last-input-event) newup)`, `mouse.el:193`) so the
  position it carried survives the translation; here the answer
  `(mouse-2 POSITION)` becomes `*last-read-event*` and its car is the
  key the modal lookup uses. Without that the command ran with no
  position and acted on point instead of the clicked line.
- **A `when`-as-value bug this path found**: the click translator's
  final form was `(when action ...)`, and a `when` whose test fails
  answers the *unspecified* value - true in Scheme - so an ordinary
  click off a link came back as `#<unspecified>` and the dispatcher
  raised "a key is a string or a vector of events". It is
  `(if action ... #f)` now.

## `char-property-alias-alist` - `textprop.c:2403`, `intervals.c:1733`

`font-lock-default-function` (`font-core.el:162`) makes `font-lock-face`
a second name for `face` in every buffer where Font Lock is on: the
buffer gets `(copy-tree char-property-alias-alist)` and `(face
font-lock-face)` is pushed onto *its* list. `lookup_char_property`
consults the alist after a direct miss, which is how a mode that
fontifies with `font-lock-face` - Occur's line numbers, dired, every
`font-lock-defaults` mode - is drawn by a renderer that asks only for
`face`.

The tree had no alias list, so `list-matching-lines-prefix-face` was
dead: the property was written and nothing read it. Ported:

- `intervals.scm` has the global `*char-property-alias-alist*` and a
  seam, `*char-property-alias-alist-function*`, because the reader must
  see the *current buffer's* list and this library is below the buffer's
  slots.
- `textprop.scm` installs the reader, and **it answers
  `(current-buffer)`, not `(*current-buffer*)`**: the parameter is #f
  whenever no `set-buffer` has pinned a buffer, which is the ordinary
  case (the current buffer falls back to the selected window's), and
  the first version answered the *global* list for every such buffer -
  so the alias never resolved in a live editor while a unit test that
  pinned the buffer passed.
- `font-core.scm` is the C's edit, character for character, including
  the `copy-tree` and the `remq`/`delq` on turn-off.
- The primitives underneath: **`copy-tree`** (`subr.el:1002`) and
  **`remq`** (`subr.el:1157`) in `subr.scm`, **`nreverse`**
  (`fns.c:2269`) and **`nconc`** (`fns.c:3390`) in `fns.scm`.
  `nreverse`'s string arm is `Freverse`'s; the C's bool-vector arm has
  no counterpart here. `copy-tree`'s record arm is not carried (Emacs's
  `recordp` names its own records; Guile's are opaque to
  `copy-sequence`) - nothing passes VECTORS-AND-RECORDS.

## The underline - `pgtkterm.c:2662-2714`

`realize-face-token` interned `:underline` from the start and nothing
drew it, so the Occur header (the `underline` face), and every
`header-line`, came out plain on a GTK frame. The terminal always drew
it (`term.scm` emits the terminfo `us`/`ue`).

`%pgtk-write-run` now draws one line: thickness 1, at
`(font->descent + 1) / 2` below the baseline with a minimum of 1, and
the C's two sanity checks that clamp it to the row. **`:underline` is
`t` *or a colour*** - omarchy's themes say `:underline "#3f8f8a"`, and
Emacs keeps that colour beside the flag (`underline_color`,
`underline_defaulted_p`). The token now carries whatever the face says
and the drawing picks the ink from its type; the first version tested
`(eq? #t ...)`, which drew nothing under a themed editor.

Not carried: the second line of `:underline` double, the wave style,
the `(:style ...)` plist spelling, and
`x-use-underline-position-properties`' font-provided position - the
position comes from the frame font's metrics, which is what
`font_for_underline_metrics` falls back to.

## Occur itself

`occur-mode-goto-occurrence` already had Emacs 31's shape - the mouse
go-between is the `defalias`, the interactive spec is `(list
last-nonmenu-event)`, and a keyboard key's `event-end` is the position
at point (`subr.el:1938`). The lines' `follow-link`, `help-echo` and
`occur-target` properties were already written by `occur-engine`. So
nothing in `replace.scm` changed but its header comment.

## Verified live on Gtk (broadway :5)

- `(get-text-property 49 'face)` on the *Occur* buffer answers
  `shadow`, through `font-lock-face` - and the property itself is
  `(font-lock-face shadow)`, `follow-link t`, `help-echo "mouse-2: go
  to this occurrence"`.
- A mouse-1 press + release driven through `dispatch-key` at the first
  occurrence line answered buffer `occur-vis.txt`, point 7 (the `888`),
  and `*last-read-event*`'s car `mouse-2`.
- A screenshot scanned for the theme's underline colour found two solid
  runs - 702 device px and 90 - under the two wrapped header rows, and
  the occurrence rows carried that colour **only on the prefix
  glyphs**, the body text in the default foreground.

## Tests

`character-tests.scm` +2 (the modifier tables), `mouse-tests.scm` +6
(51: `mouse-on-link-p` at a posn and at a position, the translated event
carrying its posn, `key-translation-translate`, off-link, and the two
time rules), `font-lock-tests.scm` +2 (15: the alias resolving through
`get-text-property`, and the global list never being moved),
`pgtk-tests.scm`'s new `schemacs_pgtk_underline` group (a pixel in a
*space* cell is inked only with the face on - the one check that can see
the underline at all).

## The click-or-drag test was quantized to cells (2026-11-20, same day)

The follow-up to the follow-link pass: Chris reported that clicking an
Occur line still did nothing. The translation was correct; the front
end's **click-or-drag decision** was not.

GNU Emacs makes that decision at the button release
(`keyboard.c:6668-6682`):

```c
	intmax_t xdiff = double_click_fuzz, ydiff = double_click_fuzz;
	xdiff = XFIXNUM (event->x) - XCAR (frame_relative_event_pos);
	ydiff = XFIXNUM (event->y) - XCDR (frame_relative_event_pos);
	if (! (0 < double_click_fuzz
	       && - double_click_fuzz < xdiff
	       && xdiff < double_click_fuzz
	       && - double_click_fuzz < ydiff
	       && ydiff < double_click_fuzz
	       && ...))
	  click_or_drag_modifier = drag_modifier;
```

— a **pixel** comparison with `double-click-fuzz` (a DEFVAR_INT,
default 3, `keyboard.c:14449`), strict on both sides, and requiring a
positive fuzz. The port compared `(pgtk-event-cell release)` against
`(pgtk-event-cell press)` — cell equality — so a click whose pointer
moved one or two pixels across a 9x20-pixel cell boundary was decoded
as `drag-mouse-1`, which ran `mouse-set-region`; `drag-mouse-1` is not
in `key-translation-map` ("dragging never follows the link"), so a
mouse-1 click on a link did nothing. It was named in the source as a
deliberate approximation ("measured in *cells* here... named rather
than guessed at") and it was wrong.

Fixed: `double-click-fuzz` in `keyboard.scm`, `pgtk-event-pixel` in
`pgtk.scm`, the press stores its pixel coordinate, and the release
handler is the C's four comparisons. The stored press is consumed by
the release that reads it and a release without a press is dropped
("If we did not see a down before this up, ignore the up",
`keyboard.c:6649`; one press is kept rather than the C's one per
button). Measured: a 2-pixel release across
a cell boundary is a click now and follows the link; a 10-pixel one is
still a drag.

**And the mouse event is now built in the signal handler**, not when
the queue is drained. The old shape queued the `GdkEvent` proxy and
read `event:get-coords` at drain time, which for a click made while a
nested read is outstanding happens after the handler has returned — a
use-after-free with a silently wrong position as its symptom. The tag
is `event-item` for a key and a mouse event alike, which is Emacs's
shape: `kbd_buffer_store_event` stores the Lisp event for every kind.

The `double_click_fuzz / 8` branch for non-window-system frames has no
counterpart (Gtk frames are window-system frames), and
`ignore_mouse_drag_p` is not carried — nothing here sets it.

# The mark in `*Messages*`, and the mouse face (2026-11-20)

Two reports from using the editor, two primitive departures under the
first, and one new subsystem for the second.

## 1. A message logged into the buffer being edited killed its region

Chris: *"the Messages buffer is still broken in that you can't highlight
a region and copy it. Mark and copy has no effect in that buffer."*

It is the one buffer that is both the buffer being edited and the buffer
every message is logged into. `C-SPC` runs `set-mark-command`, which
calls `(message "Mark set")`, which runs `message_dolog`, which inserts
into `*Messages*` — the current buffer. The insert called
`prepare-to-modify-buffer-1`, and that set the buffer's
`deactivate-mark`, so the command loop's post-command block
(`keyboard.scm`, `keyboard.c:1615`) deactivated the region the command
had just made. Every `C-SPC` in `*Messages*` did nothing visible.

The C avoids it twice, and this tree did neither:

* **`message_dolog` inserts with `prepare = false`** (`xdisp.c:12406`,
  `insert_1_both (…, true, false, false)`), which "prevents
  insert_1_both from calling prepare_to_modify_buffer". No read-only
  check, no before/after-change hooks, and no `deactivate_mark` write.
  This tree stood in for it with `*inhibit-read-only*` alone; it binds
  `*inhibit-modification-hooks*` beside it now, which is the same
  switch one level down.
* **`message_dolog` saves and restores `Vdeactivate_mark`** around its
  work (`xdisp.c:12359` and `:12526`, `old_deactivate_mark`). Ported:
  `message-dolog` reads the edited buffer's flag before the switch and
  writes it back after `set_buffer_internal (oldbuf)`.

And one primitive was wrong in the same area:

* **`prepare_to_modify_buffer_1`'s `deactivate_mark` write is inside
  the `inhibit_modification_hooks` gate.** `insdel.c:2167` is
  `if (inhibit_modification_hooks) return;` and `Fset (Qdeactivate_mark,
  Qt)` is at `:2189`, *after* it. This tree wrote the flag outside the
  `unless`, so a modification with hooks inhibited still deactivated
  the region — which is what made the `message_dolog` fix necessary in
  two places instead of one. (`insdel.scm`, `prepare-to-modify-buffer-1`.)

Regression tests: `editfns-tests.scm`'s
`schemacs_editor_editfns_message_mark` (log into the current buffer,
flag stays `#f`, `mark-active` stays true), and the pty run
`C-x b *Messages* RET`, `C-SPC`, `C-n C-n`, `M-w` — the region stays
active and the kill ring gets the text, where before the region died at
the `C-SPC`.

## 2. `make-overlay` took positions only

The other pasted error — `Wrong type argument in position 1:
#<marker buffer: #<buffer READMEmd> charpos 153>` — is a click on an
Occur line:

    occur-mode-goto-occurrence → occur--highlight-occurrences
      → (make-overlay (car target) (cdr target))

and `target`'s two ends are **markers**, as `occur-target` values are.
`make-overlay` handed them to `min`. GNU Emacs's `Fmake_overlay`
(`buffer.c:3650`) says "BEG and END may be integers or markers", checks
each marker's buffer (`:3672`, "Marker points into wrong buffer"), and
then coerces (`CHECK_FIXNUM_COERCE_MARKER`). The port had documented the
omission as safe because "every caller here passes an integer"; the
first caller that did not was the highlight overlay of an Occur click.

Ported through a seam — `*check-fixnum-coerce-marker-function*`, declared
in `buffer.scm` and installed by `marker.scm`, because `marker.scm` is
above `buffer.scm` and the coercion is `marker.c`'s. A marker in another
buffer (or in none) raises "Marker points into wrong buffer: …", the
C's message. `buffer-tests.scm` has both cases.

## 3. The mouse face — `note_mouse_highlight`

Chris: *"in real emacs as I hover over each occurance with the mouse it
gets highlighted"*. Emacs highlights any run carrying a `mouse-face`
property — Occur's lines, Dired's file names — by painting it with that
face while the pointer is on it. It is `note_mouse_highlight`
(`xdisp.c:37061`), called from the toolkit's motion handler on every
movement (`pgtkterm.c:5945`), *not* gated on `track-mouse`.

### What is carried, and where

| Emacs | here |
|---|---|
| `Mouse_HLInfo` (`xdisp.c`) | `%mouse-face-window`/`-beg`/`-end`/`-attrs` in `xdisp.scm` |
| `mouse-highlight` (`frame.c:7592`) | `mouse-highlight` (`xdisp.scm`, a plain variable — `defvar`, `setq`-ed by users) |
| `note_mouse_highlight` (`:37061`) | `note-mouse-highlight` / `mouse-face-at` / `clear-mouse-face!` |
| `face_at_buffer_position` with MOUSE true (`xfaces.c:6955`) | `attrs-at-buffer-position`'s mouse branch |
| `show_mouse_face`'s painting (`xdisp.c:35502`) | the mouse branch plus the run split in `face-change-limit` |
| `note_mouse_movement`'s call (`pgtkterm.c:5945`) | `note-mouse-movement` (`pgtk.scm`), every report |
| `note_mouse_highlight (frame, -1, -1)` on leaving | a `leave-notify-event` handler |

### The departures, each named in the source

* **Painting is in the face computation, not a second pass.**
  `show_mouse_face` draws the run into the current output after the
  rows are built; this renderer resolves a face per run while building
  the row, so the mouse face is answered from
  `attrs-at-buffer-position` when `*drawing-window*` — bound around
  `display-window!` — is the window the pointer is over. Same face,
  same run, same pixels.
* **The run's edges must split the face runs.** `line-face-runs` walks
  by `face-change-limit`, which in Emacs splits on the `face` property,
  overlays and the region. Emacs never needs the `mouse-face` edges
  because its highlight is a separate drawing pass; here a run inside a
  longer face run would take the *run's* token. `face-change-limit`
  consults the mouse run too — without it a `mouse-face` run in the
  middle of a line (Dired's name, the shape that was not Occur's) is
  never painted.
* **The state is one set, not one per display.** Emacs's `Mouse_HLInfo`
  hangs off the display; this tree's front end is one display, so
  `xdisp.scm` holds one set.
* **Coordinates are cells.** `note-mouse-highlight` takes the same unit
  as `posn-at-x-y` — cells, since a Gtk cell is the display's unit —
  where the C takes pixels.
* **The redisplay is the frame's.** `note-mouse-highlight` marks the
  window's matrix stale and calls `redisplay-frames!`; Emacs draws the
  run synchronously in `show_mouse_face`.
* **`track-mouse` gates only the Lisp event.** The Gtk motion handler
  now calls `note-mouse-movement` on every report; the
  `mouse-movement` marker is queued only while `track-mouse` is set,
  which is Emacs's `some_mouse_moved` (`keyboard.c:1290`).
* **Not carried**: `help-echo` and the pointer shape (`set_cursor`), the
  overlay `before-string`/`after-string` arms of
  `mouse_face_from_string_pos`, `mouse-face` on display strings,
  `mouse-face` overlay *priority among overlays* beyond "highest
  priority wins" (the C's `sort_overlays` walk is matched), the
  integer-valued `mouse-highlight` rule (keyboard input hiding the
  highlight), `mouse-face` on the mode line/tab line (a Gtk widget or a
  string there), and the terminal — ncurses has no mouse reporting here
  at all (`term.scm` names that), so this whole feature is Gtk-only
  until a terminal reports motion.
* **A position below the last line answers that line's end**, as
  `buffer_posn_from_coords` does, so a run ending at `point-max` stays
  lit while the pointer is on the blank rows under it. Emacs finds no
  glyph there and clears.

Tests: `mouse-tests.scm`'s `schemacs_editor_mouse_face` (the run the
primitive finds, the face-token split with and without the drawing
window, entering/staying/leaving, the row's glyph carrying the mouse
token and going back to the plain one, and the `mouse-highlight` off
switch). Verified live on a Gtk editor under `broadway`: with the
pointer over an Occur line the screenshot shows the `highlight` face's
`#B4EEB4` over the whole line and the state names the Occur window and
the run `[47, 69)`.

# The mode line as a mouse handle (2026-11-20)

`[mode-line down-mouse-1]` drags a window's bottom edge, `[mode-line
mouse-1]` selects the window it belongs to, mouse-2 deletes the other
windows, mouse-3 deletes that one; `[vertical-line ...]` is the same
pair for side-by-side windows (`mouse.el:3818-3826`). All of it is in
now, and the parts of the pipeline it needed that were missing:

* **`posn-at-x-y`'s mode-line branch carries the drawn string** as
  `(STRING . CHARPOS)` - GNU Emacs's `store_mode_line_string` - which is
  what makes the string's `keymap`/`local-map` properties reachable at
  all.
* **`lookup-keymaps` is `current_active_maps (Qt, POSITION)`**
  (`keymap.c:1649-1788`): the click's *window's buffer* is made current
  for the lookup, the string's `keymap` property goes above the minor
  modes, its `local-map` between them and the buffer's own map, and the
  buffer position's `local-map`/`keymap` properties are read through
  `get_local_map` (the new seam `*get-local-map-function*`, installed by
  `editfns.scm`) with the C's "a position outside the buffer asks about
  PT" rule.
* **`adjust-window-trailing-edge`** (`window.el:3528`) in `window.scm`,
  with `window-at-side-p`, `one-window-p` and `window-resize-pixelwise`.
* **`mouse-drag-line`/`mouse-drag-mode-line`/`mouse-drag-vertical-line`,
  `mouse-select-window`, `mouse-delete-window`,
  `mouse-delete-other-windows`** (`mouse.el:775-1180`), the drag as a
  transient map exactly as the tree already does region drags.
* frame.c's **`mouse-absolute-pixel-position`**, **`set-mouse-position`**,
  **`set-mouse-pixel-position`**, **`raise-frame`**, plus `minibuffer-window`,
  `tty-type` and `mouse-position-in-root-frame`, with three display
  generics (`display-mouse-absolute-pixel-position`,
  `display-set-mouse-pixel-position`, `display-raise-frame`) and their
  pgtk methods (Gdk warp and `gtk_window_present`).
* **`%`-construct output inherits the format string's properties**
  (`inherit-mode-line-properties`), because `bindings.el` propertizes
  `"%1*"` itself - Emacs's `display_mode_element` applies a string's
  properties to the copy it expands (`xdisp.c:28520`).

Departures, each named at the site: window.el's `window-right`/`window-left`
are `window-right-sibling`/`window-left-sibling` here (the names are taken
by the column accessors); `frame-width`/`frame-height` are record
accessors, so `(frame-width (selected-frame))` is spelled out where
Emacs's DEFUN takes an optional frame; `mouse-absolute-pixel-position`
answers *frame*-relative pixels (the display query `mouse-position` also
makes) rather than Gdk's screen-absolute position - the drag subtracts
two of them, so the constant cancels; `one-window-p` counts
`window-list`s rather than walking `next-window`, which is not ported;
`mouse-drag-line`'s `header`/`tab` arms have their shape but
`window-in-direction` is not ported and nothing binds those line types in
Emacs 31 either; the file-drag arm of `mouse-drag-mode-line`
(`mouse-drag-mode-line-buffer`, dnd) and the frame-drag arms
(`drag-with-mode-line`, `mouse-drag-frame-move`) are not carried; the
`track-mouse 'dragging` *pointer-shape freeze* is not carried (the value
is set, the shape is not changed); `echo-keystrokes` is not bound around
the drag (no keystroke echo here).

Tests: `mouse-tests.scm`'s `schemacs_editor_mouse_mode_line` - the mode
line posn's string and area, `mouse-1` selecting the clicked window, a
two-row down drag resizing both windows (`(2 -2)`), the transient map
popping on the next unbound key with `track-mouse` restored, and
`mouse-3` deleting the clicked window.

**Not yet done from "more functionality in the mode line"**: the item
`local-map`s of `bindings.el` (the modified/read-only flags, the coding
system and eol parts, the major-mode and minor-mode menus, `%n`'s widen
key), `help-echo` display, and the mode-line `mouse-face` hover paint.
The key-reading and lookup halves they need are in place (above); the
maps and commands are the remaining work, and the coding-system/eol ones
also need `mule-cmds.scm`'s `set-buffer-file-coding-system` and
`describe-coding-system` reachable from the mode line's library.

# The scroll bars' box, the pointer's shape, and the separators
# (2026-11-20)

## The bar is the text area's box, not the window's rectangle

`pgtk_set_vertical_scroll_bar` (`pgtkterm.c:4238`) takes the bar's
geometry from `window_box (w, ANY_AREA, 0, &window_y, 0, &window_height)`
(`xdisp.c:1463`): the height is `window_box_height`, which excludes the
mode line (and the tab and header lines), and Y is the window top plus
those lines. Sizing the bar to `window_height` made two stacked windows'
bars meet across the mode line row - the mode line was interrupted at
the frame's right edge. It is the body now, so the bars stop at the mode
line on both sides of it.

## The mode line runs the window's whole width

`display_mode_line` builds its row with `full_width_p` set, so the mode
line's face covers the scroll bar area and the fringes; and
`coordinates_in_window` tests `ON_MODE_LINE` **before** the scroll bar
columns (`window.c:1396-1418`), so a click in the bar columns on the mode
line row is a mode-line click. This tree drew the mode line across the
body width only, leaving the bar columns blank at the right edge. Both
the mode line and the tab line are drawn from `window-left` for
`window-width` now, and `posn-at-x-y`'s scroll-bar test comes *after*
the tab-line and mode-line tests.

## A minibuffer window has no bar

`redisplay_window` leaves early for a mini window - `if (MINI_WINDOW_P
(w)) ... goto finish_menu_bars` (`xdisp.c:20532`) - and `finish_menu_bars`
is past `finish_scroll_bars` (`:21616`), so `set_vertical_scroll_bar` is
never called for it. The renderer skips the minibuffer window when it
updates bars. `window-scroll-bars` still reports the frame's two columns
for it (measured on GNU Emacs 31.1 in a Gtk frame:
`(nil 2 t nil 0 nil nil)`; a normal window is `(nil 2 t nil 0 t nil)`),
which `frame.scm` already answered.

## The separator between side-by-side windows - `gui_draw_vertical_border`

`gui_draw_vertical_border` (`xdisp.c:37917`) has three cases and this
tree had one:

* **A window-system frame with vertical scroll bars draws nothing** -
  "Don't do it for frames with vertical scroll bars because either the
  right scroll bar of a window, or the left scroll bar of its neighbor
  will suffice as a border" (`:37932`). The bars are the separator. This
  renderer painted a column of `|` glyphs beside them, which is not
  Emacs's drawing at all.
* **A window-system frame without them draws a one-pixel line** in the
  `vertical-border` face's foreground, at the window's edge, from the top
  of the text area to its bottom (`window_box_edges`, `y1 -= 1`), through
  `FRAME_RIF (f)->draw_vertical_window_border` - `pgtkterm.c:3386` fills a
  1x`(y1-y0)` rectangle with that face. It stops above the mode line.
* **A terminal draws the `|` glyph in the window's last cell**, on every
  row including the mode line row - and that is not this hook: it is
  `build_frame_matrix_from_leaf_window` replacing each row's last glyph
  with `right_border_glyph` (`dispnew.c:2574-2599`).

The new display generic `display-draw-vertical-border` is the GUI hook;
the terminal keeps the renderer's glyph column. Both of the C's branches
(the right border of a non-rightmost window, the left border of a
non-leftmost one) land on the same column in this model, where the column
belongs to the window on the left, so one call draws what the two would.

## `ON_VERTICAL_BORDER`, and the horizontal-drag cursor

`coordinates_in_window` answers `ON_VERTICAL_BORDER` for two strips, and
`note_mouse_highlight` turns that into `horizontal_drag_cursor` plus the
help string "drag-mouse-1: resize" (`xdisp.c:37257`). Both were missing,
so the pointer never changed for a horizontal drag:

* **On a mode, header or tab line row**: the one-column strip at the
  window's edge - `|x - right_x| < grabbable_width` for a right bar or
  none, `|x - left_x|` for a left bar (`window.c:1411-1418`). That is the
  part of the line that sits over a toolkit scroll bar.
* **On a text row** of a frame with **no** scroll bars: the border column
  itself (`window.c:1448-1453`).

`posn-at-x-y` answers a `vertical-line` area for both, and
`frame-cursor-for-posn` already mapped it to the horizontal-drag cursor.
`[vertical-line down-mouse-1]` is `mouse-drag-vertical-line`, bound as in
`mouse.el:3812-3826`.

## The pointer's shape - `note_mouse_highlight` and `set_cursor`

`set_cursor:` (`xdisp.c:36592`) answers a cursor for the area and the
text properties under the pointer, and `fr->define_frame_cursor` (the
`pgtk_define_frame_cursor` hook, `pgtkterm.c:2853`) asks Gdk for it. The
implementation is `pointer-kind` / `frame-cursor-for-posn` /
`note-frame-cursor` in `xdisp.scm` and a `display-define-frame-cursor`
method in `pgtk.scm`:

* a `pointer` text property wins over everything (`arrow`, `hand`,
  `text`, `hdrag`, `nhdrag`, `vdrag`, `hourglass`, `modeline`); an
  unknown value is the nontext cursor;
* the menu bar, tab bar and the scroll bar columns are nontext; the
  vertical line is horizontal-drag;
* a mode or tab line is the vertical-drag cursor when its window edge can
  be dragged - `!WINDOW_BOTTOMMOST_P (w) || minibuf_level ||
  NILP (resize_mini_windows)` for the mode line, `!WINDOW_TOPMOST_P` for
  the tab line (`xdisp.c:36777`) - **unless** the string there carries a
  `keymap`/`local-map` property, which keeps it nontext so the item stays
  clickable (`:36802`);
* a `mouse-face` run in the text is the hand cursor.

Per-frame cursors are made once (`INSTALL_CURSOR`, `pgtkfns.c:1573`) and
held for the display's life, like the other guile-gi widgets: `text` is
XTERM, `nontext` LEFT_PTR, `hand` HAND2, `hourglass` WATCH,
`horizontal-drag` SB_H_DOUBLE_ARROW, `vertical-drag` and `scrollbar`
SB_V_DOUBLE_ARROW, `modeline` XTERM. The C's `x->cursor_pixel` frame
parameter path is not carried; the face is read where the pixel is used.

## `w->force_start`

`set-window-start` sets `w->force_start = true` (`window.c:1968`) and
`redisplay_window`'s `force_start:` label (`xdisp.c:20746`) lays out from
that start without asking whether point is in view - moving *point* into
the window when it is not (`:20823`). `set_window_buffer` explicitly
clears it (`window.c:4381`). Two departures came out of porting it:

* `set-window-buffer!` had written the new start with the *DEFUN*, which
  set the flag. In this tree the start decision runs only for the
  selected window, so the flag survived on a minibuffer window whose
  buffer is swapped in and out by the composite redisplay, and the next
  redisplay moved the prompt's point into the read-only prompt field:
  every typed key signalled "Text is read-only" and the answer came back
  as the default. It writes the start with `%window-start-set!` and
  clears the flag now, as the C does.
* The renderer clears `force_start` on every window it draws that is not
  the selected one. The C clears it per window in `redisplay_window`;
  this renderer's start decision (`scroll-to-cursor!`) is sound only for
  the selected window, because its force branch moves the buffer's point
  - which is the displayed point only there. Clearing the flag for the
  rest keeps it from being honoured stale.
* The completion display called `set-window-start!` where Emacs's
  `temp-buffer-window-show` (`window.el:138`) does not. The flag then
  made the first `M-<down>` in the completions window keep the start and
  move point into the middle of the list - the selection landed on the
  help line and the wrap never happened (`tools/pty-check.py`'s
  `completion-scroll`). The call is gone.

## A pre-existing bug this pass fixed

`window-move-screen-lines`'s backward branch computed the previous line
twice per iteration (`bol` then its own previous), so **every backward
scroll moved two lines for one**. Measured: `(window-scroll w -6)` moved
twelve lines. It steps one line per iteration now.

## Named departures, not fixed

* The bar's width is whole columns: a Gtk theme's 16-pixel slider is
  laid out on a 9-pixel cell grid as 18 pixels. Emacs is pixel-native.
* `frame-width` here is the grid's width *including* the bar columns
  (Emacs's `FRAME_COLS` is the text width), so a Gtk window asked for 80
  text columns opens 82 grid columns and toggling bars keeps the text
  width by moving the grid.
* `display-mouse-absolute-pixel-position` answers `pgtk-pointer-cell`
  scaled back to pixels, so the drag samples in whole cells; Emacs's
  `gdk_device_get_position` is pixels. `mouse-drag-line`'s arithmetic is
  pixel-based and cancels the cell size for a vertical drag, but a
  horizontal drag on a 9-pixel cell moves in 9-pixel steps.
* The mode-line drag's `drag-with-mode-line` / `drag-with-header-line` /
  `drag-with-tab-line` frame-parameter branches (dragging the *frame*)
  are not carried.
* `help-echo` "drag-mouse-1: resize" is not shown - there is no tooltip
  or echo-area help display for a posn yet - only the cursor changes.
* `[vertical-line C-mouse-2]` (`mouse-split-window-vertically`),
  `[right-divider ...]` and `[bottom-divider ...]` are not bound: the
  first needs `mouse-split-window-*` ported, the other two need window
  dividers.
* Horizontal scroll bars are not carried.
* The scroll-bar *drag* options (`scroll-bar-drag`,
  `scroll-bar-maybe-set-window-start`) are ported but untaken: they read
  `scroll-bar-movement` events, which no front end here makes.

## Verified live, and what could not be

On a Gtk editor under broadway, driven through the REPL:

* the bar widgets' allocated geometry is the body's: a 16-row body gives
  a 336-pixel bar at the window's top, not 357 for the whole window;
* the rendered surface's mode-line row is painted across the bar columns
  to the frame's right edge, and with bars on there is no `|` glyph in
  the border column;
* a synthetic `GdkEventButton` press on an **upper** window's mode line
  (posted with `gdk_display_put_event` through the FFI) starts the drag:
  `track-mouse` becomes `dragging`. A press on the frame's **bottom**
  mode line does nothing, as in Emacs (`mouse-drag-mode-line`'s
  `window-at-side-p` guard, `mouse.el:1088`).

**The drag's motion could not be exercised on broadway**: the display has
no pointer, so `gdk_window_get_device_position` answers (0,0) and every
motion sample is zero. The resize path itself is pinned headlessly by
`mouse-tests.scm`'s `schemacs_editor_mouse_mode_line` (a two-row drag
resizes both windows by `(2 -2)`).

`pgtk-write-screenshot!` writes the editor's cairo *surface*: toolkit
widgets - the menu bar, the tool bar and the scroll bars - are not in it,
which is why a bar's pixels cannot be read back from a screenshot.

## The separator column after the mode line grew - the `resize` check's catch

Making the mode line span `window-width` left the border's column
computed from the *same* `x0`/`width` bindings - `x0 + width` - which had
been the body's right edge and is now one past the window's last column.
The separator was drawn in column `width` instead of `width - 1`: a
60-column terminal split in two put `|` in column 30 instead of 29, and
`tools/pty-check.py`'s `resize` check failed deterministically at every
width (100 -> 50, 60 -> 30, 80 -> 40). It is
`(window-left w) + (window-width w) - 1` now - the window's last cell,
the one `window-body-width` leaves out of the body. A width that is right
for one span does not follow for another: the two numbers happened to be
the same while the mode line was the body's width.

## The pointer queries were dead generics - why dragging never resized

`pgtk.scm` defined `display-mouse-absolute-pixel-position` and
`display-set-mouse-pixel-position` with `define-method`, but neither name
was in its `(schemacs editor dispnew)` import list. **`define-method` on
an unimported name silently makes a new generic in the defining module**,
so the methods were attached to generics that nothing calls: the real
dispnew generics kept only their default `#f`, and `frame.scm`'s
`mouse-absolute-pixel-position` answered `(0 . 0)` on every call. A mode
line drag started (`track-mouse` became `dragging`, the cursor changed),
and every sample it took was zero, so `growth` was always zero and no
window ever moved. Measured live: `(mouse-absolute-pixel-position)` gave
`(0 . 0)` while the underlying `pgtk-pointer-cell` answered a real
position.

The two names are imported now, and `pgtk-tests.scm` has a regression
test that asks the *real* generics which methods are applicable to a
`<pgtk-display>` - two, the display's and the default - because a test
that merely calls the function cannot tell a registered method from the
default. `compute-applicable-methods` decides applicability for the
arguments given, so the four-argument setter is asked with four.

## The combination axis is stored now, not guessed - "Failed adjusting window"
## (2026-11-20)

Chris's report: dragging a vertical line horizontally raised "Failed
adjusting window #<<window> ...>". The message is Emacs's own
(`window.el:3712`): `window-resize-apply` ran and refused the sizes the
engine had computed, because they did not sum to the tree.

**The axis was inferred from the children's rectangles**, where Emacs
stores it in `w->vchild` / `w->hchild` and `WINDOW_VERTICAL_COMBINATION_P`
(`window.h`) reads that field. With two children the geometry happens to
agree; **a combination down to one child has no geometry to infer from**,
and `windows-stacked?` answered "not stacked" - so the one-child vertical
combination looked *horizontal*. `adjust-window-trailing-edge`'s walk then
stopped at it instead of climbing to the real horizontal combination
above, and the resize tried to widen a frame-wide window; the apply
check's rule for a vertical combination - every child's new width equals
the parent's - failed, exactly as the C's `window_resize_check`
(`window.c:4716`) says it must.

The axis is now a stored slot (`window-combination-axis`, on the window's
slot vector), set where Emacs sets `vchild`/`hchild`: by the split that
makes a combination (`%split-window-install!`, both the new-parent and
the reuse paths) and by `combine-windows`. `window-stacked?` reads it;
`window-combined-p`, `window-top-child`, `window-left-child`,
`%window-resize-check`, `%window-resize-apply-1` and `scale-window!` all
pass the parent window now instead of a children list. A window with no
stored axis and two or more children - a state put without one - still
falls back to the geometry, so nothing that predates the field breaks.

Verified by fuzzing: `tools/window-resize-fuzz.scm` builds 300 random
trees (0-3 splits over a 120x40 Gtk-like display) and calls
`adjust-window-trailing-edge` on every window in both directions with
deltas ±1 and ±2. **Before: 1508 "Failed adjusting window" failures;
after: 0.** The "No window on the right/below" and "No resizable window"
errors are Emacs's own refusals and are not counted.

## `(not (set! ...))` is never true - the set!-in-value-position trap

`adjust-window-trailing-edge`'s guard against a window with no sibling:

```elisp
((or (not (setq left right)) (not (setq right (window-right right))))
 (user-error "No window on the right of this one"))
```

was ported as `(or (not (set! left right)) (not (set! right ...)))`. A
Scheme `set!` answers the *unspecified* value, which is true, so both
`not`s were false and the guard never fired: a nil window went on to
`window-min-size` ("Wrong type argument ... #f"), or from a drag a window
with no right sibling raised where Emacs says "No window on the right of
this one". The guard is a `let` now. This is the same class as the
`when`-in-value-position and `(when (or (not shadow) ...))` notes already
in this file - **`setq` returns the value it set and `set!` does not**.

The walk-up loop before it got the matching guard: Emacs's
`(window-parent nil)` is `decode_any_window`, the *selected* window, and
this tree's is a record accessor that raises; the loop stops on a nil
right, which is what its `(setq right (window-parent right))` did in
Elisp when the parent chain ran out.

Tests: `window-tests.scm` 18 - a split below stores `vertical`, a split
on the right stores `horizontal` and leaves the outer axis alone, and a
horizontal drag on the lower pair changes the pair's widths while the
frame-wide window above keeps its width.

# The mode line as a set of buttons (2026-11-20)

`bindings.el`'s clickable mode-line items are ported: the two flags
(`mode-line-modified`), the remote flag (`mode-line-remote`), the EOL
mnemonic (`mode-line-eol-desc`), the narrowing indicator (`%n`) and the
buffer name (`mode-line-buffer-identification`), with the four commands
they name (`mode-line-toggle-read-only`, `mode-line-toggle-modified`,
`mode-line-widen`, `mode-line-change-eol`) and the buffer-name pair
(`mode-line-previous-buffer`, `mode-line-next-buffer`). The C each was
taken from is in the source; this is what departs.

## The items are plain variables, not buffer-locals

`mode-line-modified`, `mode-line-remote` and
`mode-line-buffer-identification` are `defvar-local` in `bindings.el`.
Here they are one binding each in `xdisp.scm`, because this tree has no
way to make a *variable that holds a construct* buffer-local without a
buffer slot, and nothing in the tree changes them per buffer. The
observable difference is a user in one buffer `setq`-ing one of them
(the binding would have to be `set!` in that library); no command here
does.

## The hover face on a string is found by content, not by row/column

`note_line_or_margin_highlight` records the highlighted run as
`mouse_face_beg_col`/`_end_col` of the *glyph row*, and `show_mouse_face`
repaints from the matrix. This renderer has no glyph row for a mode
line; it records the run as character positions in the drawn string and,
at the next redraw, applies it only if the freshly formatted line is
`equal-including-properties` to the string the pointer found. A
consequence: if the mode line's text changes under a stationary pointer
(a buffer edited with the pointer on the flag), the highlight is dropped
until the pointer moves again, where Emacs would repaint it over the
same columns with whatever text is there now.

**The run itself is the C's**: `previous_single_property_change (pos + 1)`
backward and `next_single_property_change (pos)` forward, and the lit
characters are drawn with the `mouse-face` value merged over the glyph's
own face - `face_at_string_position` with MOUSE true and `glyph->face_id`
as the base (`xdisp.c:36955`), which is *not* the buffer-text rule
(merge over `default`, `xfaces.c:6955`).

**Tab lines and tab bars are not hover-highlighted.** A tab line's posn
carries the `%tab-line-string-at` *segment*, not the whole drawn line, so
the run cannot be mapped back to the line the renderer holds; Emacs's
glyphs carry the original string object and charpos and need no mapping.
The mode line's posn *is* the whole drawn line, which is why it works
there.

## `help-echo` is carried and never shown

The items carry Emacs's `help-echo` strings and functions
(`mode-line-read-only-help-echo` and friends). Nothing displays them:
Emacs shows a help-echo through `show_help_echo` (`keyboard.c:2259`) and
`show-help-function`, which is `tooltip.el`'s - `tooltip-show-help` with
a delayed toolkit tip on a window system and `tooltip-show-help-non-mode`
in the echo area otherwise. `tooltip.el` and `x-show-tip` are not ported.
The property values are Emacs's, so that pass gets them for free.

## `display-supports-face-attributes-p` answers `:box` now, and only that

The function answers yes for `:box` on a window-system frame and no on a
terminal - which is what sends `mode-line-highlight`'s spec to its
rosette branch on Gtk and to `:inherit highlight` on a tty, as in Emacs.
The C's `Fdisplay_supports_face_attributes_p` asks about many more
attributes (`:family`, `:height`, `:width`, `:strike-through`, ...);
those still answer no everywhere, and have since the function was
written. Nothing in the tree asks for them yet except `italic`'s
`(supports :slant italic)` and `underline`'s `(supports :underline t)`,
which the allowed list already covers.

## The EOL mnemonic is not cached

`mode-line-eol-desc-cache` is not carried: the string is built per
redisplay. It is six characters and the cache is keyed on the eol type,
so this is a constant factor, not a behaviour difference.

## `coding-system-eol-type` speaks symbols, and the EOL cycle follows

Emacs's `coding-system-eol-type` answers an integer (0, 1, 2) or a
vector; this tree has always answered `unix`/`dos`/`mac` (named at that
function). `mode-line-change-eol`'s C is
`(cond ((eq eol 0) 'dos) ((eq eol 1) 'mac) (t 'unix))`; here it is the
same three cases on the symbols, and an unsettled eol (`#f`) takes the
same `unix` arm the C's `t` does.

## Coding-system aliases, and what they changed

`define-coding-system-alias` (`coding.c:11612`) is now ported, and
`mule-conf.el`'s four aliases are defined beside this tree's coding
table: `binary` -> `no-conversion`, `unix` -> `undecided-unix`, `dos` ->
`undecided-dos`, `mac` -> `undecided-mac`. An alias shares its target's
record - as the C shares the *spec* - so every accessor answers for it
what it answers for the target; the alias list is a side table keyed by
the canonical name, because the record has no name of its own. A child
alias of a *base* coding system gets the three `-unix`/`-dos`/`-mac`
subsidiaries, as `make_subsidiaries` does.

`coding-system-change-text-conversion` (`mule-cmds.el:213`) and the real
`coding-system-change-eol-conversion` (`:182`, whose three branches
replace a name-rebuild) are in `coding.scm` - a named placement
departure, as the eol one already was. `merge-coding-systems` carries
both of the C's branches now: the text conversion when FIRST is
`undecided`-based, then the eol. That is what makes
`(set-buffer-file-coding-system 'dos)` set `utf-8-dos` rather than the
bare `dos`.

Not carried, and named before: `iso-8859-1` remains a coding system of
its own here where Emacs aliases it to `iso-latin-1`.

## The menus are not ported - here is everything they need

`mode-line-major-mode-keymap`, `mode-line-minor-mode-keymap`,
`mode-line-mode-menu`, `mouse-minor-mode-menu`,
`minor-mode-menu-from-indicator`, `mouse-menu-major-mode-map`,
`mouse-menu-non-singleton`, `bindings--sort-menu-keymap`,
`lookup-minor-mode-from-indicator` and `posn-object` are not written,
and `read_char_x_menu_prompt` (`keyboard.c:10637`) - the rule that a
mouse event whose binding is a keymap pops that keymap as a menu - is
not in the dispatcher. The pieces exist except for two:

- **`get_keyelt`'s autoload arm.** The C's `access_keymap` evaluates a
  menu item's `:filter` while looking a key up
  (`menu_item_eval_property`), which is how
  `[mode-line down-mouse-1]`'s `(menu-item "Menu Bar" ignore :filter
  (lambda (_) (mouse-menu-major-mode-map)))` becomes a keymap to pop.
  `keymap.scm`'s `get-keyelt` takes AUTOLOAD and documents that every
  caller passes `#f`; giving it a real `:filter` evaluator needs an
  evaluator seam (the tab bar works around the same gap by calling
  `tab-bar-make-keymap` itself).
- **`mouse-menu-non-singleton`** reads a keymap's bindings through
  `keymap-canonicalize` and `map-keymap` - both ported - so it is small
  once the filter arm exists.

The dispatcher half is small on top of what is here: on the wait for the
next event, when `menu-prompting` is non-nil, the event that opened the
prefix was a mouse event with parameters and no unread input is pending,
call `x-popup-menu` with that event and the keymap, unread the events
after the first of its answer, and look the first one up in the same
map. `x-popup-menu`, the event-to-position decode and `popup-menu` are
all ported.

**`menu-prompting`** is a parameter when this is taken up
(`*menu-prompting*`, default `#t`): `subr.el`'s `global-set-key` and
`local-set-key` `let`-bind it to nil around their key read, which is
this tree's test for a dynamically bound variable.

## The unbound-mouse-event fallback (fixed 2026-11-20, Chris's report)

Chris: *"Wrong type argument in position 2: #f"*, then *"when clicking
mode"* and *"and when clicking buffer name"*. The press of every click on
a mode-line item raised it.

**The cause was the dispatcher's fallback, not the items.** A mode-line
item's map binds `[mode-line mouse-1]` and nothing else, so the *press*
(`down-mouse-1`) is unbound in it. Our `fail` arm applied the "last event
alone" rule to that press, looked `down-mouse-1` up in the whole map
list, found the *text* binding `mouse-drag-region`, and ran it on a
mode-line position - `mouse-drag-track`'s `(posn-point ...)` is nil
there.

GNU Emacs does not retry that event. Once the event that failed is a
mouse click, `read_key_sequence` reduces it instead
(`keyboard.c:12100-12210`): "Drags reduce to clicks. Double-clicks
reduce to clicks. Triple-clicks reduce to double-clicks, then to
clicks. Up/Down-clicks are eliminated." An eliminated event is read past
and nothing runs; a reduced one is looked up in the *same* map.

`%unbound-mouse-reduction` and `%run-reduced-click` in `keyboard.scm`
are that rule, applied before the last-event-alone arm - which still
belongs to keyboard prefixes, and is what makes `C-x C-g` quit.

The observable consequences, all Emacs's:

- a press on a mode-line item does nothing at all (no drag, no message);
- a *no-motion* `mouse-1` release does not end a mode-line drag either -
  the drag map's exit is `[drag-mouse-1]`, which is what a release after
  motion is - so `track-mouse` stays `dragging` until the next key;
- a `drag-mouse-1` on a mode-line item reduces to its click and runs the
  item's command.

Two corners are named rather than carried: when the *reduced* click is
itself a prefix keymap, the C continues the sequence with it
(`current_binding = new_binding`), and this dispatcher cannot - the
state a fail answers with is discarded, so the reduced prefix's next
event would start a fresh lookup; and the command a reduced click runs
has `this-command-keys` of the *reduced* event alone, where the C's key
buffer still holds the click it came from. Nothing in the tree binds a
`drag-mouse-N` or `double-mouse-N` to a keymap, and nothing reads
`this-command-keys` of a mode-line item.

The dispatcher's binding list became a `letrec*` for this: the `fail`
closure calls `fail-alone` and reads `prefix-maps`, both bound after it,
and a `let*` left them unbound inside the closure - which only shows on
the path the fallback exists for. `mouse-tests`' drag test now ends the
drag with `drag-mouse-1`, as a real drag does, and `mode-line-tests` has
the press/release cases.

## The hover box and the element a run belongs to (2026-11-20, Chris's report)

Chris: *"mouse over in real emacs mode line draws a box around it, not
just lines top and bottom. also each character in the left mode section
is a separately highlighting target, whereas you have 3 characters
highlighting at once."* Both were real, and both were pieces of the C
this renderer had left out.

### The box's vertical edges

`pgtk_draw_glyph_string` (`pgtkterm.c:2048`) does not take the box's
vertical edges only from `left_box_line_p`/`right_box_line_p`:

```c
left_p = (s->first_glyph->left_box_line_p
          || (s->hl == DRAW_MOUSE_FACE
              && (s->prev == NULL || s->prev->hl != s->hl)));
right_p = (last_glyph->right_box_line_p
           || (s->hl == DRAW_MOUSE_FACE
               && (s->next == NULL || s->next->hl != s->hl)));
```

**A mouse-face run always gets them**, where it begins and ends. That
second rule is the whole of the hover box: the mode line's own face has
a box (`:line-width -1 :style released-button`), so under the first rule
alone every neighbouring run is "boxed" too, the highlight is one more
boxed run in a boxed row, and only its top and bottom sides are drawn.
`draw-mode-line!` now passes `(or start-of-box-run (and lit? (not
prev-lit?)))` and its mirror on the right.

### `mode-line-elt-no`: the element a character came from

Emacs's `format-mode-line` puts a **`mode-line-elt-no`** property on
every literal run and every `%`-construct's output - `mode_line_elt_no`,
incremented on entry to `display_mode_element` (`xdisp.c:28500`, and the
`src` list at `:28600`, `:28656`, `:28739`). Measured on 31.1:

```elisp
(format-mode-line '("%z" "%1*" "%1+"))
=> #("UUU--" 0 3 (mode-line-elt-no 2) 3 4 (mode-line-elt-no 3) 4 5 (mode-line-elt-no 4))
```

The number is what the redisplay uses to keep a hover run within one
element: the glyphs of a mode-line element carry that element's *string
object*, and `note_line_or_margin_highlight` computes the run with
`previous_single_property_change`/`next_single_property_change` over that
string, so it cannot cross into the next element. `mode_line_compact`'s
path says why in a comment: it displays the formatted string "one
element by one element ... to make the ranges of mouse highlighting
correct" (`xdisp.c:28280`).

This tree's line is one flattened string, so adjacent elements with the
same `mouse-face` value (`:`, both flags and the remote flag, all
`mode-line-highlight`) merged into one run and lit together. The fix is
the C's property: `format-mode-line` tags each element's output, and
`string-mouse-face-at` clips the property run to the `mode-line-elt-no`
run around the pointer. That makes each of those four items its own
target, as in Emacs.

One property-placement detail came with it: the properties a `%`
construct inherits from its format string now go on the *constructed*
text and not on the field's padding. Emacs's `store_mode_line_string`
adds them to the string it was given and appends the padding spaces with
only the elt-no marker (`xdisp.c:29075-29090`), which is why `%12b`'s
padding is neither part of the name's hover run nor clickable.

**Not carried**: `mode-line-compact` itself. The property makes it
possible; the compressing display path is not written.

# The help echo and tooltips (2026-11-20)

## What landed

The chain that turns a `help-echo` property into a tooltip, each piece in
the library its Emacs file names:

| Emacs | here |
|---|---|
| `show_help_echo` (`keyboard.c:2259`) | `keyboard.scm` |
| `help_echo_substitute_command_keys` (`keyboard.c:2219`) | `keyboard.scm`, with the substitution installed by `help.scm` |
| `show-help-function` (`keyboard.c:14824`) | `keyboard.scm`, as `*show-help-function*` |
| `note_mouse_highlight`'s help-echo half (`xdisp.c:36749-37660`) | `xdisp.scm` - `help-echo-at`, `text-help-echo-at`, `string-help-echo-at`, wired at the end of `note-mouse-highlight` |
| `mode-line-default-help-echo` (`bindings.el:128`) | `xdisp.scm`, with `*mode-line-default-help-echo*` |
| `tooltip.el` (the whole file) | `tooltip.scm` (new) |
| `x-show-tip` / `x-hide-tip` (`xfns.c`, `pgtkfns.c:3077`) | `tooltip.scm`, over `display-show-tip` / `display-hide-tip` (`dispnew.scm`) |
| `qttip_cb` / `xg_prepare_tooltip` / `xg_show_tooltip` (`gtkutil.c:837`, `:890`, `:997`) | `pgtk.scm` |
| `mouse-fixup-help-message` (`mouse.el:1894`) | `mouse.scm`, installed through a seam |
| `mouse-pixel-position` (`frame.c:3325`) | `frame.scm` |
| `time-since` (`time-date.el:192`) | `timefns.scm` (placement noted there) |

## Departures

1. **The help echo is delivered synchronously.** The C's motion handler
   stores `help_echo_string`/`_window`/`_object`/`_pos` and generates a
   `HELP_EVENT`; `read_char` calls `show_help_echo` when it dequeues one,
   so a help function runs in the command loop. This front end's pointer
   events arrive as Gtk signals and there is no read to carry the event,
   so `note_mouse_highlight` calls `show-help-echo` itself - the same
   arrangement it already has for the mouse face. Errors are swallowed
   like `safe_calln`/`safe_eval`, so what runs where is the only
   difference. The "either the new or the previous value is non-nil"
   rule is ported, so moving off a help item sends the nil that hides the
   tip.

2. **A function-valued `help-echo` holds the procedure.** `bindings.el`
   writes `'help-echo 'mode-line-read-only-help-echo`, and Emacs resolves
   that symbol through its obarray because `FUNCTIONP` is true for a
   symbol with a function definition. This tree has no function obarray,
   so `mode-line-modified` and `mode-line-remote` store the procedure
   itself - the same choice a keymap here makes when it holds a command.
   `show_help_echo` calls a procedure value; anything else is evaluated
   as the form arm. `mode-line-tests.scm` pins the representation.
   A related difference follows from the flattened line: the OBJECT a
   mode-line help function receives is this renderer's whole mode-line
   string with POS an index into it, where Emacs passes the *element's*
   own string. The functions `bindings.el` installs ignore both
   arguments; a user function that inspected them would see the
   difference.

3. **The mode-line fallback help is computed at hover time.** The C
   computes `w->mode_line_help_echo` when the mode line is formatted
   (`display_mode_lines`, `xdisp.c:28141`), calling the buffer-local
   option as a function of the window. Here `window-mode-line-help-echo`
   reads `buffer-local-value` and calls it with the window at the moment
   the pointer is over it. Same function, same argument, same answers; a
   mode line formatted under one value and hovered under another would
   differ, and nothing does that.

4. **`tooltip-mode` is switched on by a call at the end of
   `tooltip.scm`.** Emacs reaches the mode's body through `defcustom`'s
   `:set` function (`custom-set-minor-mode`) when
   `:initialize #'custom-initialize-after-file-load` sets the variable
   during the load. `define-minor-mode` here accepts and drops
   `:set`/`:initialize`, so the call the setter would make is written
   out. Without it the variable would read t and `show-help-function`
   would stay nil.

5. **The Gtk tooltip is a custom label on Gtk's tooltip object, not the
   plain text tooltip.** Emacs's PGTK path sets the text with
   `gtk_widget_set_tooltip_text` (`gtkutil.c:997`). Gtk's default
   tooltip label *wraps* its text, and a wrapped multi-line tooltip is
   sized before the wrap is measured - the reported symptom was a
   multi-line help with its last line cut off. Emacs met this long
   before: its non-PGTK Gtk path builds its own label
   (`"Change stupid Gtk+ default line wrapping"` -
   `gtk_label_set_line_wrap (…, FALSE)`, `gtkutil.c:864`) and hands it to
   the tooltip object with `gtk_tooltip_set_custom` in `qttip_cb`. That
   is what `pgtk.scm` does: a `GtkLabel` with wrapping off and xalign 0,
   returned from a `query-tooltip` handler. Gtk still owns the popup and
   its placement, which is what keeps a tooltip working on Wayland,
   where a plain window cannot move itself.
   The label is pinned with `g_object_ref` (`qttip_cb`'s own line,
   `gtkutil.c:861`), called through the `dynamic-func` FFI because
   guile-gi exposes no ref. Without it Gtk's tooltip window owns the only
   reference and the label is freed when the window goes; the proxy then
   points at freed memory and the next query raises
   `gtk_label_set_text: assertion GTK_IS_LABEL (label) failed`,
   `gtk_tooltip_set_custom: ...`, and finally `g_object_unref`/`instance
   with invalid (NULL) class pointer` - which took the editor down on the
   first few hovers. One ref per display is never dropped, as Emacs never
   drops its own.

6. **`gtk_widget_trigger_tooltip_query` is called after the text is
   set**, which Emacs does not do. Gtk runs its own hover timer and
   queries while the pointer moves; Emacs decides at its 0.7s delay,
   after the pointer has usually stopped, so without the trigger the
   tooltip would wait for the next pixel of movement.

7. **`x-show-tip`/`x-hide-tip` are `tooltip.scm`'s, not a window-system
   file's.** The display half is a pair of `dispnew` generics; the
   Lisp-visible functions take Emacs's six arguments but pass only the
   frame, string and timeout down, because the Gtk build's system path
   ignores `PARMS`, `DX` and `DY` too (`pgtkfns.c:3097` goes straight to
   `xg_show_tooltip`). The tip's frame is remembered in `x-tip-frame`,
   the C's `tip_last_frame`. The Lisp-level checks (a string, the empty
   string becoming a space, the default timeout) are the C's.

8. **`mouse-fixup-help-message` uses `(mouse-position)`**, whose answers
   are cells, rather than `mouse-pixel-position`, whose answers are
   pixels: this tree's `posn-at-x-y` counts cells. The position the two
   name is the same.

9. **The substitution and its inhibit test split across a seam.**
   `help_echo_substitute_command_keys` runs `substitute-command-keys`
   unless the string's first character has
   `help-echo-inhibit-substitution`. Reading a string's text property is
   `textprop.scm`'s and `keyboard.scm` is below it, so `keyboard.scm`
   holds the seam (`*help-echo-substitute-function*`, default identity)
   and `help.scm` installs the function that does both.

10. **`current-message` answers nil once the echo area is cleared.**
    `Fcurrent_message` returns nil when there is no message; the frame's
    message slot holds the empty string after `(message "")`, so the
    seam translates an empty message to nil. `tooltip-show-help-non-mode`
    depends on the distinction (`(stringp tooltip-previous-message)`).

11. **`lisp-time-arguments` converts a non-integer time to exact
    seconds+picoseconds.** `(float-time)` is what `tooltip-hide-time`
    stores and `time-since` subtracts; `(cons time 0)` left the fraction
    in the seconds field and the exact `floor-quotient`/`ash` arithmetic
    raised "Wrong type argument ... -37.0".

## Not carried, named

- `x-pre-popup-menu-hook`: the hook does not exist in this tree, so a
  tooltip is not hidden when a menu pops up.
- `menu-or-popup-active-p`, the NS-only guard in `tooltip-show-help`:
  there is no NS front end.
- `tooltip-process-prompt-regexp` and `tooltip-strip-prompt`: they read
  a process's buffer, and there are no subprocesses here.
- `tooltip-reuse-hidden-frame` and the tooltip *frame* of Emacs's
  non-system path: Gtk owns the tooltip window here.
- `message-truncate-lines`: the echo area's own truncation is the
  renderer's.
- `help-echo` on images and fringes (`:map` hotspots,
  `left-fringe-help`/`right-fringe-help`): no images or fringes.
- The menu bar's and tool bar's items were already widget tooltips
  (`gtk_widget_set_tooltip_text` at build time) and are unchanged.

## Tests

- `tooltip-tests.scm` (new, 29): `show_help_echo`'s four value kinds; the
  fixup-then-substitute order; the mode's installed state
  (`show-help-function`, the two hook entries); the delay machine (first
  delay, short delay after a recent hide, same-help dedupe, replacement,
  cancel); `tooltip-show` through a recording display, including that
  the text carries the `tooltip` face; `x-show-tip`'s empty-string rule;
  the echo-area half (newline folding, clearing, restoring the previous
  message); and hovering the mode line - a function-valued item and the
  buffer-local default fallback.
- `mode-line-tests.scm`: the help-echo expectation is the procedure now
  (departure 2).
- All 79 suites pass.

# The mode line's menus (2026-11-20)

`bindings.el:571-596`'s two keymaps, `mouse.el:222-330`'s menu builders,
`help.el:1293-1400`'s `describe-minor-mode` family, and
`bindings.el:956`'s `mode-line-minor-mode-help`. This is the C and the
measured Emacs each rule was taken from, and every place this tree spells
something differently.

## What Emacs does, and what is done here

| Emacs | here |
|---|---|
| `mode-line-major-mode-keymap` (`bindings.el:571`): down-mouse-1 a `menu-item` whose `:filter` is `mouse-menu-major-mode-map`; mouse-2 `describe-mode`; down-mouse-3 a `menu-item` whose `:filter` is `bindings--sort-menu-keymap` | the same map, with the two presses bound to **commands** - `mouse-menu-major-mode-menu` and `mode-line-minor-mode-menu` - that build the same menus and pop them |
| `mode-line-minor-mode-keymap` (`:584`): down-mouse-1 `mouse-minor-mode-menu`; mouse-2 `mode-line-minor-mode-help`; down-mouse-3 the filtered toggles menu; the header-line press (no header line here) | the same, less the header line |
| `mode-line-mode-menu` (`:404-953`) | the three entries whose modes this tree has: `overwrite-mode`, `font-lock-mode`, `auto-fill-mode` |
| `bindings--sort-menu-keymap` (`:410`) | ported; the answer is a **record** keymap, where Emacs `nconc`s a list keymap |
| `bindings--menu-item-string` (`:404`) | ported for string item names (the menus here) |
| `mouse-menu-major-mode-map`, `mouse-menu-non-singleton`, `minor-mode-menu-from-indicator`, `mouse-minor-mode-menu` | `mouse.scm`, as in Emacs |
| `describe-minor-mode`, `-from-symbol`, `-from-indicator`, `-completion-table-for-symbol` | `help-fns.scm` |
| `describe-minor-mode-completion-table-for-indicator`, `lookup-minor-mode-from-indicator` | `mouse.scm` |
| `mode-line-minor-mode-help` (`bindings.el:956`) | `help-fns.scm`, and the map names it as a symbol |

## Departures

1. **`:filter` is not evaluated by the key lookup.** Emacs's menu items
   answer a *keymap* from a filter at lookup time and `read_char` pops
   it. This tree's lookup has no filter arm and no menu-prompting path,
   so the two presses name commands. `mouse-menu-major-mode-map` and
   `bindings--sort-menu-keymap` are still the C's functions - the
   commands call them - so the menus themselves are Emacs's.
2. **`mode-line-lighter` is this tree's property.** Emacs's redisplay
   keeps each mode-line element as its own string object, so
   `posn-object` over a lighter answers that lighter alone (measured on
   Emacs 31.1 in a pty: a click on the third lighter of
   `(Fundamental Ovwrt Fill)` answers `" Fill"`). This renderer
   flattens the line, so each lighter's run carries an index under
   `mode-line-lighter`, and both `string-property-run-at` (the click)
   and `string-mouse-face-at` (the hover) stop at its boundary - the
   same stand-in `mode-line-elt-no` is for an element.
3. **`describe-minor-mode`'s family is in `help-fns.scm`, not
   `help.scm`.** The mirror order would put it in `help.scm`, but
   `describe-minor-mode-from-symbol` calls `describe-function` and
   `describe-variable`, which are defined there; Emacs resolves the
   names through one obarray and this tree cannot.
4. **The two completion/lookup functions are in `mouse.scm`, not
   `help.el`.** They are built from the two steps the mode line
   evaluates a lighter with (`minor-mode-variable-true?`,
   `minor-mode-indicator-value`/`minor-mode-lighter`), so they live
   beside the mode-line machinery that uses them, and `help-fns.scm`
   imports them.
5. **`mode-line-minor-mode-help` is in `help-fns.scm`.** It is
   `bindings.el`'s, but it calls `describe-minor-mode-from-indicator`,
   which is above `xdisp.scm` - the map binds the symbol.
6. **`minor-mode-menu-from-indicator`'s generated menu is a record
   keymap.** Emacs builds `(keymap TITLE (turn-off menu-item ...)
   (help menu-item ...))`; `x-popup-menu` here takes a record, so the
   same two items are defined into a sparse map (back to front, because
   `define-key` prepends).
7. **`:minor-mode-function` is read, and nothing sets it here.**
   `add-minor-mode` records it only when TOGGLE-FUN differs from
   TOGGLE; no mode here passes one, so `(get minor-mode
   ':minor-mode-function)` is nil and `mm-fun` is the mode symbol -
   which is Emacs's answer for every mode in this tree.
8. **`fboundp mm-fun` is the command table.** The generated menu is
   skipped when the name does not name a command, which is Emacs's
   bug#20201 guard.
9. **The "Help" item is present only when a help library is loaded** -
   the seam `*describe-function-function*`, installed by
   `help-fns.scm`. Emacs preloads help, so this is invisible in a real
   editor and shows in a test process that does not.
10. **`mode-line-compact`'s disambiguation arm is not carried.** The
    option is not ported; measured, Emacs without it compares the whole
    lighter string `lookup-minor-mode-from-indicator` is given, which is
    what this does.
11. **The `:button` expressions name this tree's readers.**
    `buffer-overwrite-mode`, `font-lock-mode-on?`,
    `buffer-auto-fill-function` stand where Emacs writes the variable's
    own symbol - the variable and the command share a name in Emacs and
    cannot here.
12. **`*minor-mode-alist*`'s default is `bindings.el`'s whole list
    again** - `(abbrev-mode " Abbrev")`, `(overwrite-mode
    overwrite-mode)`, `(auto-fill-function " Fill")`,
    `(defining-kbd-macro mode-line-defining-kbd-macro)`. The last two
    name state that is not ported; a variable with no value reads false,
    which is Emacs's answer for a mode that is off. The ` Fill` lighter
    had never appeared because the entry was missing.

## Bugs this found

- **`apply string-append` dropped every per-lighter property.** The
  lighters were one propertized string before, so it did not matter;
  making each lighter its own run exposed it - `string-append` builds a
  fresh string, while `concat` (fns.c's) keeps text properties. The
  click answered the whole group and the menu could not find a mode.
- **`(cdr (assq minor-mode minor-mode-map-alist))`** raised on a mode
  with no map - Elisp's `(cdr-safe ...)` is the C's. A mode with no
  `minor-mode-map-alist` entry is the ordinary case.

# `mode-line-position`, the percentage constructs and symbol resolution
# (2026-11-20)

The last of the mode line's clickable items, and the machinery it needed.
Emacs's `mode-line-position` (`bindings.el:727`) is what decides what the
position looks like; porting it meant porting the four percentage
constructs, the three visibility modes and - the interesting one - the
mode line's own evaluation of a *symbol*.

## What landed

| Emacs | here |
|---|---|
| `%o`, `%p`, `%P`, `%q` (`xdisp.c:29757-29809`) | `mode-line-construct`'s four cases, `percent99` (`:29432`), `window-bottom-position` (`BUF_Z (b) - w->window_end_pos`) |
| `line-number-mode`, `column-number-mode`, `size-indication-mode` (`simple.el:9420-9437`) | `simple.scm`, all three `:global t`, line numbers on by default |
| `mode-line-percent-position`, `mode-line-position-line-format`, `-column-format`, `-column-line-format`, `column-number-indicator-zero-based` | `define-custom`s in `xdisp.scm` |
| `mode-line-column-line-number-mode-map` (`:620`) and its `menu-map` (`:621-636`) | the keymap and `line-column-mode-menu` |
| `mode-line-position` (`:727`) | `*mode-line-position*`, Emacs's tree of conditionals |
| `display_mode_element`'s symbol and conditional forms | `mode-line-symbol-value` and the fixed conditional branch of `format-mode-line` |

## Departures

1. **The mode-line variables are `define-custom` parameters.** Emacs has
   `defvar`s/`defcustom`s reachable through one obarray; a construct
   names the variable by symbol and `symbol-value` finds it. This tree
   keeps variables in three places - the buffer's slots, the global
   default table (`define-minor-mode`'s `:global`), and a custom
   variable's reader on the symbol - and **no single place holds a plain
   `define`d variable**, which is the same gap `describe-variable` has.
   The five position variables are therefore customizable variables, so
   their readers are reachable; a plain `define` would make
   `mode-line-position` an empty construct.
2. **`mode-line-symbol-value` maps the starred spelling.** `define-custom`
   records its reader under the name written - `*mode-line-position*` -
   and a construct says `mode-line-position`, so the lookup tries the
   bare symbol and then `*NAME*`. That is the parameter convention
   reaching the construct language; it is the only place a construct
   resolves a name.
3. **The line/column menu's press is a command.** Emacs binds
   `[mode-line down-mouse-1]` to the menu keymap itself and `read_char`'s
   menu prompting pops it; this tree has no menu-prompt path, so
   `mouse.scm`'s `mode-line-line-column-menu` pops the same map - the
   shape the mode name's and the lighters' menus already use.
4. **`:type 'sexp` for `mode-line-position`**; Emacs's `risky-local-
   variable` marking is not carried (there is no `risky-local-variable-p`
   here).
5. **`column-number-indicator-zero-based` is carried as a plain
   defcustom**; `make-obsolete-variable` is not ported, so the warning
   Emacs prints for it does not appear.

## `popup-menu`'s optional arguments were required

`popup-menu` is `(menu &optional position prefix from-menu-bar)`
(`menu-bar.el:2682`); this tree defined it with all four **required**,
so a caller passing one or two - the mode-line menus' seam calls
`(popup-menu menu event)` - raised "Wrong number of arguments to
#<procedure popup-menu (menu position prefix from-menu-bar)>" on every
press. It takes a rest parameter now (this tree's `&optional` spelling
for a procedure called from Lisp as well as from an interactive form),
and `menu-bar-menus-tests` pins the one-, two- and four-argument calls.

## The bug this found: a conditional construct always took the else

`format-mode-line`'s `(SYMBOL THEN ELSE)` branch read

    (process (if (and (pair? (cdr construct)) (pair? (cddr construct)))
                 (caddr construct)
                 #f))

- the test's *value* was never consulted, so every conditional took its
  ELSE arm. Nothing showed it because no format in the tree used one;
  `mode-line-position` is built out of them, and the first run drew no
  position at all. It now reads the symbol through
  `mode-line-symbol-value`, exactly as Emacs's `display_mode_element`
  evaluates the car.

## `define-minor-mode` now initialises a global mode's default

Emacs's `defvar` binds the variable at definition time; this macro
generated accessors with an *initial-value fallback* and left the global
default table unbound, so `(default-boundp 'line-number-mode)` was false
and the construct's conditional read it as off. The expansion now emits

    (unless (default-boundp MODE) (set-default MODE INIT))

- the `defvar` rule, including "do not overwrite an existing value", so a
  reload cannot clobber what a user set. **It is a macro change: every
  library that uses `define-minor-mode` has to be recompiled**, or its
  stale `.go` keeps the old expansion.

## What the default mode line reads now

`-UUU:**- alpha.txt   All L1     (Fundamental)` - the percentage and the
line, which is Emacs 31.1's default. The column appears only when Column
Number mode is turned on, in Emacs's combined form `(1,0)`; the pty
battery turns that mode on in its init so its column-based position
oracle keeps working, and `tty-editor-tests`'s two column tests do the
same around their assertions.

# The popup's position, the rows' right edge, the scroll bar's, and the
# coding-system item (2026-11-20)

Four reports from using the editor, and the C each was read from.

## The popup opened at the top-left

`x_popup_menu_1` works in *pixels* (`menu.c:1111`); this tree's display
interface works in cells, and `gtk_menu_popup_at_rect` was handed the
cell numbers as pixels - so a menu asked for at the mode line (column 40,
row 20) opened at 40,20 pixels. `menu-show`'s Gtk method now maps cells
to pixels with the same `cell-x`/`cell-y` the renderer draws with.

## The mode line stopped a few pixels short of the frame edge

`display_mode_line` (`xdisp.c:28220`) ends with "Fill up with spaces" -
`display_string (" ", ..., 10000, -1, -1, 0)` - and the row is clipped at
the window's pixel width, so the last, partly visible cell's background
reaches the frame edge (`extend_face_to_end_of_line` then handles the
`:extend` rule). This renderer's grid is `floor (pixels / cell width)`
cells, and the leftover strip kept the frame's background under every
full-width row: the mode line, the tab bar and the tab line stopped a
few pixels early. `%pgtk-write-run` and `clear-end-of-line!` now extend
the last cell of a run that ends at the grid's last column by those
pixels - the clipped final cell - and only there.

## The scroll bar was inset

`pgtk_set_vertical_scroll_bar` (`pgtkterm.c:4238`) places a right-hand
bar at `WINDOW_SCROLL_BAR_AREA_X (w) = WINDOW_BOX_RIGHT_EDGE_X`, the
window's *pixel* right edge, with its configured pixel width
(`window.h:983`): the bar's right edge is the window's, and the pixels
the frame does not divide into columns are between the text and the bar
(Emacs's right fringe, which this tree does not have), not beyond it.
Our bar was placed at the last *column* edge and stopped at the grid's
right edge, leaving the frame background visible past it - which the
mode-line extension above then filled in behind it. The Gtk method now
moves a right-hand bar whose right edge is the frame's last cell edge to
the frame's pixel edge.

## The coding-system item - `bindings.el:74-88`, `:188-226`

`%z` is a button: mouse-1 describes the buffer's coding system, mouse-3
sets it, and hovering shows `mode-line-mule-info-help-echo`.

- `mode-line-coding-system-map` and the two commands are in `xdisp.scm`
  (Emacs binds two anonymous `(lambda (e) (interactive "e") ...)`
  values; a binding here is a procedure and only a command has an
  interactive specification, so they are named).
- `mode-line-mule-info-help-echo` is bindings.el's, ported as written.
- Both commands read `buffer-file-coding-system` **raw**, with the same
  `utf-8-unix` literal `%z` uses, because `files.scm` is above
  `xdisp.scm`.
- `mule-diag.scm` (NEW) is `lisp/international/mule-diag.el`'s
  coding-system half: `describe-coding-system`,
  `describe-current-coding-system`, `print-coding-system-briefly` and
  `coding-system-type`. Its output is byte-for-byte Emacs 31.1's for
  `utf-8-unix`, `no-conversion` and `utf-8` (the last's charset-list
  block excepted).
- **Departures**: `princ`/`standard-output`/`with-output-to-temp-buffer`
  are not ported, so the printers `insert` into the help buffer where
  the C `princ`s (`%princ` is the one place it differs from Emacs's
  shape); `coding-system-type` is derived from the base name because the
  record does not carry `:coding-type`; the charset-list block, the
  ISO-2022 branch and the process/selection blocks of
  `describe-current-coding-system` are not carried, each named in the
  library header.
- The `mule-conf.el` aliases whose targets exist were added
  (`latin-1`, `mule-utf-8`, `cp65001`, `utf-16-le`, `utf-16-be`,
  `ascii`, `iso-safe`), which is what makes the help text's alias list
  match Emacs's.

# `map-y-or-n-p`, and the save prompt it was hiding (2026-11-21)

Chris, from the editor: *"in real emacs when I try and quit with C-x C-c
it says Save file... with a flashing cursor at the end of the line. In
schemacs it appears like a non-flashing cursor at teh beginning of the
line. (BTW the options available look different to real emacs). If I hit
then say "n", the prompt doesn't change, but the cursor moves to the
middle of the line expecting the "modified buffers exist; exit anyway"
prompt, however you don't get to see that prompt until you press the
first key."*

Every one of the three was a departure, and they had one cause:
`save-some-buffers` asked its own question with
`read-char-from-minibuffer` instead of asking through
`map-y-or-n-p` - which was not ported at all.

## What landed

- **`map-y-or-n-p` (`map-ynp.el:43`)** in `schemacs/map-ynp.scm`, the
  minibuffer arm (Emacs's default; `y-or-n-p-use-read-key` is nil): the
  C's prompt format, `user-keys` built from the action alist, the
  answers map (`query-replace-map` as parent, each action key bound to
  `(vector FN)`), the remap minibuffer map (`cmd-char` for every answer
  key, `[remap self-insert-command]` -> "Type `C-h' for help"), the
  answer echoed as `"%s%s"`, and the C's whole `cond` - exit, act,
  skip, act-and-exit, quit/exit-prefix, automatic, help, a command
  symbol, a user-key vector, switch-frame, random char. The final
  "restore the previous message" binds `message-log-max` nil.
- **`y-or-n-p-use-read-key` and `y-or-n-p-history-variable`** are
  `subr.el` defvars (`:4038`, `:4102`) and live in `subr.scm` as plain
  variables (nothing `let`-binds them), with the self-assignment the
  compiler's constant folding needs. Emacs's `HIST` `t` means "do not
  record this answer": it is stored as `#t` and the four readers ask
  `history?` - Emacs's own `(listp history)` test - before touching it.
- **`help-key`** (`help.el:58`), `(key-description (vector help-char))`,
  in `help.scm`; it is what the prompt uses for the help key.
- **`save-some-buffers` is `files.el:6569`'s**: `ARG`/`PRED` (not a
  frame), `save-some-buffers-default-predicate`, the
  `buffer-save-without-query` pre-pass, `save-some-buffers-functions`,
  `map-y-or-n-p` with the C's prompter (the buffer-name/file-name
  comparison and the "(buffer NAME)" form), the action alist,
  `save-window-excursion` around the whole body, the `(No files need
  saving)`/`(Saved ...)` messages, and the `C-f` switched-buffer
  `pop-to-buffer-same-window` in an unwind.
- **`save-some-buffers-action-alist`**: `M-~` (skip and mark unmodified),
  `C-r` (view), `C-f` (view and quit). `d` (diff) is not carried -
  `diff-no-select` needs subprocesses - and `C-r`'s recursive arm is
  not either (`view-mode-enter`/`enable-recursive-minibuffers`); the
  non-recursive `display-buffer` arm is what is written, and
  `other-window-scroll-buffer` is not set. The keys are *events* (the
  one element inside `(kbd "M-~")` and friends) because
  `map-y-or-n-p` wraps them in a vector, as the C wraps a character.
- **`save-buffers-kill-emacs` (`files.el:8666`)** and
  `save-buffers-kill-terminal` as a thin wrapper: the C's
  `files--buffers-needing-to-be-saved t` guard, `save-some-buffers arg
  t`, the modified-file-buffer scan, `Modified buffers exist; exit
  anyway? `, `kill-emacs-query-functions`
  (`run-hook-with-args-until-failure`, newly ported, `eval.c:2908`'s
  `funcall_not`) and `confirm-kill-emacs`. **`kill-emacs` itself has
  no counterpart** - "kill this Emacs process" is the front end's quit
  continuation - and `kill-emacs-hook` is not run (named). The
  dialog-box arm of the unsaved-buffers question and the whole
  active-process question are not carried (no subprocesses).
  Both commands take Emacs's `&optional arg restart` as a rest
  parameter.
- **`yes-or-no-p` re-ported** (`fns.c:3613`): one argument (it took a
  *frame* and a prompt, a departure), `yes-or-no-prompt` (a plain
  variable, default `"(yes or no) "`), the C's "append a space unless
  the prompt ends in one", the answer read through `yes-or-no-p-history`
  (a history record here), and "Please answer yes or no." on anything
  else. Not carried: `use-short-answers`' `y-or-n-p` arm, the dialog
  arm, `ding`/`discard-input`/`sleep-for` (the pause is `sit-for`).
- **`save-window-excursion` (`subr.el:5304`)** in `window.scm`, a named
  placement departure: a `subr.scm` macro cannot reach
  `current-window-configuration`. `dynamic-wind` is the C's
  `unwind-protect`.
- `M-~`'s action marks the buffer unmodified with
  `set-buffer-modified-p`; `@@ (schemacs map-ynp)` is not in the
  generated `imports.scm` (that list is the `(schemacs editor ...)`
  libraries only), which is why M-: cannot see `map-y-or-n-p` - named,
  not fixed: it is a question-asker for commands, and every command that
  uses it imports it.

## The bug C-g exposed: Emacs's evaluator checks the quit flag

`map-y-or-n-p`'s `quit` answer is the C's `(setq quit-flag t)` followed
by `try-again`, and the quit is raised by **`maybe_quit` in `eval_sub`**
on the next function call - before the prompt's own `(setq quit-flag
nil)` can clear it. Scheme has no such check, so the re-ask cleared the
flag and C-g asked again for ever (a hang, measured). `step` calls
`(maybe-quit)` at its top, which is that evaluator check made by hand
where the loop re-enters.

The `C-f` action's `(setq quit-flag t)` is the same rule seen from the
other side: the parameter write answers the *unspecified* value, so the
lambda says `#t` out loud, which is what the C's `setq` answers.

## The two answer-map rules that are Emacs's

- `query-replace-map` is a **plain variable** in this tree, not a
  parameter: the stars are Emacs's name's (the tree spells the Emacs
  name with stars because `define-custom` names do) and reading it as
  `(*query-replace-map*)` applies the keymap - "Wrong type to apply",
  reported from the live editor.
- `unread-command-events` **is** a parameter, so a queued
  switch-frame event is appended with `(*unread-command-events* (cons
  ...))`.

## Verified

- `schemacs/map-ynp-tests.scm` (NEW, 8 tests): `y`/`SPC` act and `n`/DEL
  skip with the action count, the exact Emacs 31.1 prompt string (`Save
  a? (y, n, !, ., q, or C-h) y` - measured on Emacs first), `q`, `!`,
  `.`, a non-string prompter acting without asking, an `M-~` action
  alist entry, and C-g raising out.
- `tools/pty-check.py`'s `save-y-n` now pins the prompt
  (`(y, n, !, ., q` and no stray backquotes) and the exit-anyway
  prompt's `(yes or no)` text. **The full battery is 100/100** on this
  tree.
- Driven at a pty: `y` saves and exits, `n` shows the exit-anyway
  question at once (the `read_minibuf` `clear_message` fix from the
  earlier session is what makes it visible) and "no" stays, `q`, `!`,
  `.`, `M-~`, `C-r`, `C-f` and `C-g` each behave as Emacs's.

**The regression the first battery run found**: two more
`(yes-or-no-p (*current-frame*) PROMPT)` call sites -
`find-alternate-file` and `revert-buffer` - kept the old two-argument
shape, so both passed the frame as the prompt and signalled inside
`string-length`; the command loop's guard turned each into a command
that did nothing, and `revert-buffer`'s check caught it. Both take one
argument now. This is the "a signature change has every caller updated
or the key silently dies" class, with the pty battery as the net.

# The region is an overlay per window; the row's tail is `:extend`
# (2026-11-21)

Chris, using the editor: a region that crosses a line break stopped at
the end of the line instead of reaching the screen edge, a blank line
inside a region was not painted at all, a region in one of several
side-by-side windows leaked past that window's right edge, and "in real
emacs it remembers the different regions in the different windows
holding the buffer, but in schemacs it forgets the other regions that
are highlighted". All four are one departure: **the region was a face
merged by the run walk from the buffer's point and mark**, where GNU
Emacs 29+ makes an *overlay per window* and lets the overlay machinery
carry it. The old shape could only know one region (the current
buffer's point/mark, the same in every window), had no `:extend` rule
for the line break, and its fill painted from the first window's row
arithmetic across the neighbour.

## What is ported, and the C it came from

- `redisplay--update-region-highlight` (`simple.el:7332`),
  `redisplay--highlight-overlay-function` (`:7294`),
  `redisplay--unhighlight-overlay-function` (`:7285`),
  `redisplay-highlight-region-function` (`:7324`),
  `redisplay-unhighlight-region-function` (`:7296`) and
  `pre-redisplay-functions` (`:7376`) are `simple.scm`'s. The overlay
  is stored in **`window-parameter 'internal-region-overlay`**, carries
  `face region`, `priority (nil . 100)` and the `window` property, and
  is moved to `[min(window-point, mark), max(...)]` on each redisplay.
  `highlight-nonselected-windows` (`xdisp.c:38830`) is a plain
  variable, nil as in Emacs; while a prompt is up the window the
  minibuffer was entered from keeps its region through
  `minibuffer-selected-window` - a seam, because `simple.scm` is below
  `minibuffer.scm`.
- `overlay_matches_window` (`buffer.c:3367`) is the overlay walk's
  filter: a region overlay belongs to one window and is invisible in
  every other, in `attrs-at-buffer-position` **and** in the
  before/after-string walk (`load_overlay_strings`, `xdisp.c:7158`).
  This is what stops the leak between side-by-side windows: the
  renderer asks `*drawing-window*` for each overlay.
- `window_outdated?` (`window.c:231`) reads `OVERLAY_MODIFF`, and moving
  the overlay raises it, so `window-matrix-valid?` needs no region
  question of its own - the C's own comment says it.
- `extend_face_to_end_of_line` (`xdisp.c:24379`) and `extend_face_id`
  (`:24429`): the row's tail is filled with the face at the line's
  **end** when that face says `:extend`, with the last glyph's face
  when the last glyph is not the default, and with the default face at
  `ZV`. A row with no glyphs - a blank line - still extends, because
  `it->face_id` at the call is the *newline's* face. That is what makes
  a blank line inside a region paint to the edge.

## Measured on Emacs 31.1 first, then matched

A pty run of `emacs -Q -nw` with three side-by-side windows on one
buffer, the region set in each in turn and the window parameters dumped
(through a file port, so the dump itself could not disturb the buffer
list):

| step | window 1 | window 2 | window 3 |
|---|---|---|---|
| region set in w1 | live `[1,24]` | none | none |
| region set in w2 | **deleted** | live `[20,34]` | none |
| region set in w3 | deleted | deleted | live `[40,55]` |
| back to w1 | live `[24,40]` | deleted | deleted |

So the default really is "the selected window only", and returning to a
window recomputes the region from **that window's point and the shared
mark** (`[24,40]`, not the remembered `[1,24]`). With
`highlight-nonselected-windows` t, all three windows' overlays are live
at once, each `[window-point, mark]`. The screens were captured through
tmux (`capture-pane -e`) and the region background counted per window:
it is painted in exactly the windows whose overlay is live.

Our tree reproduces both rows of behaviour: the overlay dump across the
same sequence gives live/deleted in the same pattern, the return to w1
gives `[window-point, mark]`, and a Gtk screenshot with the variable
bound t shows each window's region clipped at its own right edge
(pixel runs end at 341 for a 38-column left window, resume at 369 in
the right window).

## Departures this work names

1. **`pre-redisplay-functions` runs from `render!` for every window.**
   `prepare_menu_bars` (`xdisp.c:14267`) calls it with all windows when a
   global redisplay is due, and `redisplay--pre-redisplay-functions`
   (`simple.el:7391`) walks them; `redisplay--update-region-highlight`
   (`simple.el:7332`) keeps WINDOW's overlay only when

       (or highlight-nonselected-windows
           (eq window (selected-window))
           (and (window-minibuffer-p)
                (eq window (minibuffer-selected-window))))

   and otherwise calls the unhighlight function, which deletes it. **So
   only the selected window's region is highlighted by default, and
   moving to another window removes the highlight from the window left
   behind.** This renderer repaints every window every frame, so it is
   always in the C's "all windows" case and runs the hook for every
   window; a hook run only for the selected window would leave the
   other windows' overlays alive and paint stale regions, which is what
   the previous pass's "remembered regions" policy did. That policy was
   wrong: the code is the authority, and it is reverted. With
   `highlight-nonselected-windows` true the hook keeps every window's
   overlay, each at `[window-point, mark]`.
2. **The backends clip a row to its window's body rectangle.**
   `write-glyphs!` and `clear-end-of-line!` in both `term.scm` and
   `pgtk.scm` stop at `window-body-left + window-body-width` (the frame's
   last column when the window is #f - `update-window!` writes a frame
   matrix row with no window). Emacs never needs this because it writes
   a composed frame matrix whose window rows are already the window's
   box; this renderer hands rows straight to the backend, and a row
   wider than its window - a long line whose slice was not cut to the
   window, a `display` string wider than the cells left on the row, or
   an hscrolled row whose `x0 + width` reaches one cell past the body -
   painted into the window beside it. That is the user's "the drawing
   routine doesn't understand it's truncated, it keeps painting the
   region highlight into the next window". The row builder also clamps
   `draw-glyph-row!`'s clear limit to the body edge now. The terminal
   `ce` (clear-to-end-of-line) capability is used only when the clear
   reaches the frame's last column: `ce` clears the whole terminal line,
   which in a split frame is the neighbour's text as well, and Emacs can
   use it only because it writes a composed frame matrix.
3. **The GUI fill is space glyphs in the row, not a stretch glyph.**
   Emacs appends one stretch glyph over `last_visible_x - current_x`;
   this tree's glyph is a cell, so the row is padded with cells carrying
   the extend face, for both front ends. The row's own vector is reused,
   so a keystroke still allocates no glyph records.
4. **The GUI skip test is "the extend token is the default face's".**
   Emacs skips the fill when the extend face's background equals the
   frame's and it has no box, underline or overline. A face with the
   frame's background but a box would be skipped here and drawn by
   Emacs; no face in this tree does that today. Named rather than
   modelled.
5. **The mono inverse-video allowance is gone.** The previous
   `line-end-fill-attribute` extended a region on a monochrome terminal
   because the region's mono defface branch is `:inverse-video t` with
   no `:extend`. Emacs has no such allowance (`face_at_pos` with
   `LFACE_EXTEND_INDEX` asks `:extend` only), and measured on a vt100
   it paints only the region's characters and the newline's own cell:
   `alpha alpha alpha ` inverse, the padding after it not. The tests
   that need an extension therefore ask an **8-colour** display, whose
   region spec carries `:extend t`.
6. **`w->last_mark` is recorded, not read.** `mark_window_display_accurate_1`
   (`xdisp.c:18359`) stores the mark while it is active; this tree
   stores it with the C's condition (`mark-active` and the buffer's mark
   set, no transient-mark-mode question) and nothing reads it yet -
   text-conversion is not ported.

One more, small and only reachable without a frame: `deactivate-mark`'s
call to `redisplay--update-region-highlight` is guarded on
`(*current-frame*)`. Emacs always has a selected window there; this
tree's headless tests and batch scripts have no frame at all, and
`selected-window` signals - which made `command-tests.scm` abort at its
first `deactivate-mark`. With no frame there is no window whose overlay
could be painted, so the call has nothing to do.

## The Gtk popup unmapping warning

Chris saw `Gdk-WARNING: Tried to unmap the parent of a popup` after
choosing Undo from the mode popup menu. Two pieces of `xmenu.c` /
`pgtkmenu.c` were missing:

- **`popup_activated_flag`** (`pgtkmenu.c:100`) is
  `*pgtk-popup-depth*` here, a counter held by a `dynamic-wind` around
  `pgtk-create-and-show-popup-menu`. The after-redisplay drain
  (`pgtk-drain-queue!`) must not dispatch queued keys while it is
  non-zero: selecting an item enqueues the item's keys, the command
  loop's reader is what runs them, and here a timer's repaint *can*
  drain them inside the popup's own Gtk loop - running a command that
  rebuilt the menu bar, the parent of the popup being unmapped, under
  Gtk's unmap. Emacs's reader cannot run there (`popup_widget_loop`
  pumps Gtk itself), so it has no such guard.
- **`menubar_selection_callback`'s flush** (`xmenu.c:819`): "When a menu
  is popped down, X generates a focus event ... Since GTK buffers
  events, we force it out here before the menu selection event."
  `pgtk-menu-selection!` spins `gtk_events_pending`/`gtk_main_iteration`
  before it queues the item's keys, which is the C's loop verbatim.

The depth is released **after** `gtk-widget-destroy`, the order the C's
`record_unwind_protect_ptr (pop_down_menu)` gives: nothing the destroy
causes can dispatch a queued command in the middle of it. Not
reproduced deterministically (it needs a real menu click), so the
verification is structural - the port of the two C mechanisms - plus
the live editor exercising the popup path.

## The start after a narrowing goes to `recenter:` (2026-11-21)

Chris: *"in real emacs if I have different windows on the same buffer
but much different locations, and then I do C-x n n narrow in one of
them, all windows showing that buffer scroll so the narrowed text is
visible. We leave the window blank because we didn't scroll it to the
visible text. Are you copying real emacs code..."*

The rule, read out of `redisplay_window`:

- **Markers are not clipped by narrowing.** Measured on Emacs 31.1:
  `window-start` is still 1 after narrowing to 9..15.
- Every optimization `redisplay_window` tries for a window whose start
  is on screen is guarded on the start lying inside `[BEGV, ZV]` (the
  `try_window_id` / `try_window_reusing_current_matrix` /
  `try_cursor_movement` guards). A start outside the restriction fails
  them all and control falls through to the `recenter:` label
  (`xdisp.c:21158`).
- `recenter:` seats the iterator on **PT** - the *buffer's* point, not
  the window's point marker - with `init_iterator (&it, w, PT,
  PT_BYTE, NULL, DEFAULT_FACE_ID)` (`:21165`), sets `it.current_y =
  it.last_visible_y`, centers with `centering_position =
  window_box_height (w) / 2` (`:21238`), walks back with
  `move_it_vertically_backward` (`:21253`) never past BEGV (`:21248`),
  and writes the result into `w->start` (`:21274`). `narrow_to_region`
  has already clipped PT into the restriction (`editfns.c`), so every
  window showing the buffer is seated around the buffer's point, on
  the narrowed text.
- The `force_start` clamp (`xdisp.c:20781`) is the **other** branch -
  it belongs to a window whose start is `w->start` and forced, and is
  what `scroll-to-cursor!` ports. It is not the ordinary case.

`display-window!` used to clamp the window's start into
`[point-min, point-max]` and lay rows out from there, so a window whose
start was past ZV drew rows from ZV and the text area came out blank.
It now asks the C's question and takes the C's fall-through:
`recenter-window-on-cursor!` at the buffer's point, clamped into the
restriction.

The regression test is `tty-editor-tests.scm`'s *"narrowing brings
every window on the buffer to the text"*: two windows on one buffer at
distant positions, `narrow-to-region` `[800,900]` in the selected one,
`render!`, and the other window's start is 800 with position 800
visible in it. Seen failing under the old clamp (its rows blank).

## Truncation vs wrapping, and the `$` marker, are `xdisp.c`'s

Chris, the same day: *"Also why are we using a $ dollar sign as a marker
that the line is long? Also, how come gtk schemacs is showing the line
truncated, whereas tty schemacs is showing the line wrapped?"*

- **The wrap rule is `init_iterator`'s** (`xdisp.c:3413`): a text row
  wraps when the face is the default, the window is not horizontally
  scrolled, the window is full-frame width **or**
  `truncate-partial-width-windows` allows it (nil, or an integer not
  greater than the window's total columns), and `truncate-lines` is
  nil; otherwise it truncates. `truncate-partial-width-windows`
  defaults to **50** (`:38779`), so a full-width window always wraps
  and a partial one narrower than 50 columns truncates.
- Both front ends draw text through `window-truncates-lines?`
  (`indentc.scm`), which is that condition verbatim - there is no
  per-front-end wrapping code. The difference the user saw was
  geometry: a full-width 80-column terminal window wraps, and the
  ~39-column windows after `C-x 3` truncate. Verified live on both.
- **`$` is `produce_special_glyphs`'s IT_TRUNCATION glyph** and `\` its
  IT_CONTINUATION glyph. `insert_left_trunc_glyphs` sets
  `truncate_it.face_id = DEFAULT_FACE_ID` before asking for them
  (`xdisp.c:23923`), so those cells carry the **default face**, not the
  face of the line they mark - a `$` on a region row is *not*
  region-coloured in Emacs. The left `$` that marks a horizontally
  scrolled row is the same glyph in the same face, and our renderer
  draws both with `(face->attribute 'default)`.

## A blank line's first cell in a region

Measured three ways - the desired matrix (`glyph-row-glyphs` gives the
region face on glyph 0 of a blank row), a tty capture (the row begins
with the region SGR at column 0), and a Gtk screenshot (the region band
starts at x=0) - a blank line inside a region is filled from column 0.
The only cells on such a row that are not region-coloured are Emacs's
own: the **cursor's cell** (cursor face) and, when the window is
horizontally scrolled, the **left `$`** at column 0 (default face, per
`insert_left_trunc_glyphs` above - Emacs leaves that cell the frame's
background too).

## The cursor's cell came from the buffer, not the row (2026-11-21)

The paragraph above was measured on a *fresh* frame. On a steady one it
was wrong: the cursor's cell went to the frame background, and only
when the cursor had been on a blank line - "moving up through a
document, the first character on an empty line isn't painted" - while
moving down looked right. Two omissions in the row and cursor model,
both of them in `xdisp.c`:

1. **`append_space_for_newline`** (`xdisp.c:24191`, called at `:26597`)
   was not ported: "Add a space at the end of the line that is used to
   display the cursor there." A row had no glyph at its newline at all;
   a blank line's row was empty and only `extend_face_to_end_of_line`
   painted anything. Emacs gives that space the **newline's face**
   (`it->face_id`), so a blank line inside the region carries the
   region face at column 0. `build-row!` appends it now when the row
   reaches the end of its line (not `more?`, not `truncated?`), with
   the newline's face - and the default face at `ZV`, which is the C's
   `append_space_for_newline (it, true)` call at `:26083`.
2. **The cursor's glyph came from the buffer.** `cursor-glyph` read the
   line's string and the face at point; at the end of a line there is
   no character in that string, so it answered `" "` with the
   **default** face. `*phys-cursor*` recorded that, and the next
   redisplay's `erase_phys_cursor` repainted the cell from it. GNU
   Emacs's `get_phys_cursor_glyph` (`xdisp.c:37894`) takes the glyph
   from the **row** the cursor is on, and `draw_phys_cursor_glyph`
   (`:35105`) redraws *that* glyph with its own face - so a blank line
   in the region keeps its colour under and after the cursor. The
   renderer's cursor block is now `phys-cursor-glyph (row column)`: the
   glyph at `column - (glyph-row-x row)`, the left `$` for the one cell
   an hscrolled row gave up, and a default space past the row's glyphs.

Why the two directions differ, and why the bug is invisible on a
*fresh* frame: the region overlay's move raises `OVERLAY_MODIFF`, so the
redisplay that changes the region rebuilds every row - the erase's
paint is overwritten and the frame is right. The damage shows on the
**next** redisplay with nothing changed (`redisplay--highlight-overlay-function`
does not move an overlay whose bounds are unchanged, `simple.el:7294`,
so the window is fresh, the row diff skips every row, and the cursor's
erase is the only paint). Moving up, the blank line at the region's
start is where the cursor was, so the erase hits the cell that matters;
moving down, the blank lines the cursor passes are at the region's end
or outside it, where a default cell is invisible.

**Regression tests**: `pgtk-tests.scm`'s "the cursor on a blank line
keeps the region in its cell" - a Gtk frame, two renders, the strong
redisplay flag cleared before the second so the rows are skipped as in
the steady state, and a pixel read from the cell's interior (it fails
with `(255 255 255)` under the old glyph source); and
`tty-editor-tests.scm`'s "a blank line's row carries the newline in the
region's face", which pins the row's first glyph and the fill to the
window's edge.

# The category table and bool vectors — step 1 of the regexp engine
# (2026-11-21)

The regexp engine Emacs compiles into `regex-emacs.c` reads the syntax
table (`\s`, `\w`, `\b`) and the category table (`\c`), and
`word_boundary_p` (`category.c:376`) reads both the category table and
the script table. So the full port of the engine starts below it, with
the two objects that did not exist here: Emacs's **bool vector** and its
**category table**.

## What landed

- `(schemacs editor data)` now carries `alloc.c`'s `make-bool-vector`
  (`:2080`) and `bool-vector` (`:2093`) and `data.c`'s predicate and
  bitwise operations (`:454`, `:3824`-`:3995`): `bool-vector-p`,
  `bool-vector-ref`/`-set!`, the union/intersection/difference/xor
  family with the C's optional destination and "the destination if it
  changed, nil otherwise" answer, `bool-vector-not`, `subsetp`,
  `count-population` and `count-consecutive`. The C's machine-word
  `bits_word` implementation is not carried: the bits are one exact
  integer, bit I being element I. That is the same sequence with the
  same answers, without a length limit; a Word of `eql` for `equal?` is
  what `copy-sequence` needs.
- `(schemacs editor category)` is `category.c` whole - the category set
  (`make-category-set`), the category (`define-category`,
  `category-docstring`, `get-unused-category`), the category table
  (`category-table-p`, `category-table`, `standard-category-table`,
  `copy-category-table`, `make-category-table`, `set-category-table`,
  `char-category-set`, `category-set-mnemonics`,
  `modify-category-entry`) and `word-boundary-p`.
- `copy-sequence` grew the bool-vector arm `fns.c` has.
- `category-tests.scm` (20, Emacs 31.1's own answers, measured first)
  is in `tools/run-suites.py`; all 82 suites pass.

## Departures, all named in `category.scm`

1. **`make-category-table` shares one empty set** across the default and
   every top-level slot, where the C makes a separate set for each. The
   sets are immutable in use - `modify-category-entry` copies before
   changing - so no caller can observe it; only `eq` on two never-written
   sets could.
2. **`map-char-table` is not ported**, so `copy-category-table` walks the
   table's runs with `char-table-ref-and-range` instead of
   `map_char_table`'s recursion. Same runs, same order.
3. **`char-script-table` is empty** - `characters.el` fills it and that
   file is not ported yet. With the default nil every character has the
   same script, which is Emacs's answer for the ASCII repertoire; the
   `word-combining-categories`/`word-separating-categories` lists are
   plain variables with Emacs's nil defaults.
4. **Errors are templates plus irritants**, as everywhere in this tree:
   `(error "Undefined category: ~a" c)` carries the C's message text and
   the character; the reporter formats it. Emacs's printed message also
   passes through `text-quoting-style`, which this tree does not
   substitute in `error`.
5. **A character argument may be a Guile character or its code point**;
   Emacs's DEFUNs take the code point. Both are accepted because the
   ported `characters.el` call sites will write character literals and
   the tests write code points.

## Case tables — step 2 of the regexp engine (2026-11-21)

`(schemacs editor casetab)` is `src/casetab.c`: `case-table-p`,
`current-case-table`, `standard-case-table`, `set-case-table`,
`set-standard-case-table`, the three derivations (`set_identity`,
`shuffle`, `set_canon`) and `init_casetab_once`'s ASCII table. The
regexp engine's `translate` is the buffer's CANON slot and reads EQV
from CANON's extra slot 2, exactly as `search.c` and
`set_image_of_range` do. The derivation was checked against Emacs 31.1
on a hand-made table where the answer is not obvious (down 65->97,
97->97 gives up 65->97, up 97->65) and matches.

Departures, also in the file: `map_char_table` is still not ported, so
the three builders walk the table's runs with
`char-table-ref-and-range`; a buffer's four case slots are buffer-local
values here rather than `struct buffer` fields; and the standard table
is ASCII only - `characters.el`'s Unicode extension is not ported yet,
so a character with no entry translates to itself, which is
`char_table_translate`'s fallback.

# The Emacs regexp engine: compiler, fastmap, matcher (2026-11-21)

**Not wired in yet.** `(schemacs editor regex-emacs)` compiles and
matches Emacs's dialect, and nothing in the editor imports it: it is
excluded from `loadup.scm`'s session list until `search.sld` is moved
onto it. Everything below is the engine's own state.

## The representation, restated

The library's header has the full account. In one line each: an
instruction is `#(OPCODE ARG1 ARG2)`, jumps are absolute instruction
indexes where the C stores relative byte offsets, `exactn`'s characters
are a list, and a charset is a `<re-charset>` (256-bit map, inclusive
code-point range vector, `RECC_*` class bits) instead of the C's
bitmap+range-table bytes. The text is a `<re-text>` of code points, so
the C's whole UTF-8 decode layer (`STRING_CHAR`, `CHAR_LEADING_CODE`,
`BYTE8_TO_CHAR`) is absent and the fastmap is 256 code-point bits plus
one "some code point above 255" flag where the C uses leading bytes.

## The compiler

`regex-compile` is `regex_compile`'s whole switch: whitespace-regexp
substitution, `^`/`$`, `* + ?` with the smart/keep-string/prememo
choice and the `P+` → `PP*` rewrite, `.`, bracket expressions with the
C's range-continuity work area, every backslash escape (shy and
numbered groups, intervals, back references, syntax/category/symbol
classes, `\=`, the buffer anchors), and the exactn coalescing. Three
things had to be *derived* from the C's pointer arithmetic and are the
places a later reader should look first:

1. **`%insert-at!` shifts the *instructions that moved*, not the
   targets.** A jump's stored target is relative in the C, so when an
   insertion moves an instruction by one slot its target moves by one
   slot too, whatever the target was. The new instruction's own
   arguments are supplied in the post-insertion numbering. The
   compiler's saved indexes (beginning/end of alternative, pending
   exactn) are C pointers and are *not* adjusted by an insertion.
2. **`on_failure_jump_smart` writes back to the instruction at
   TARGET-1.** Our jump arguments name the instruction after the jump,
   as the C's addresses do, so the trailing `jump` is one before the
   smart's target; the smart rewrites *that* instruction's target to
   `PAT-INDEX + 1` (the C's `STORE_NUMBER (p2 - 2, mcnt + 3)`).
   Writing to TARGET itself corrupts whatever instruction follows the
   loop - it turned a `stop_memory`'s register number into 3 here.
3. **The compile stack's saved `laststart` is `b`, not the current
   laststart** (`regex-emacs.c:2310`): it is the position where the
   group's own code begins, which is what a following quantifier
   repeats. Saving the *previous* laststart makes `\(?:a\|b\)+` treat
   the `+` as a literal.

## The matcher

`re-match-2` carries the failure stack (registers, counters, and the
NULL-string marker of the keep-string jump), the best-match registers,
the infinite-loop check, the nasty-loop no_op frame, back references,
every assertion, and the success/backtracking block at the end of the
pattern. `re-search` is `re_search_2` over one text: the anchored and
`\=` pre-checks, the fastmap skip in both directions, `can_be_null`,
and the start-position advance. The smart opcode decides keep-string
vs. ordinary loop with `mutually_exclusive_p` ported whole, including
`forall_firstchar`'s two-destination walk.

Departures, all named in the source:

1. **Memoization is indexed by instruction index.** The C divides a
   byte offset by `MEMO_BYTES_PER_COUNTER` (3); instructions here have
   no fixed width. The adaptive counters, the bitset growth, the
   promotion of a `prememo` opcode to `memo`, and the `inhibit` flag
   for back references and counted repetitions are the C's. Only the
   key's granularity differs, and the feature cannot change an answer -
   only which failing states are remembered.
2. **No `nchars` redisplay accounting.** The C's `update_redisplay_ticks
   (nchars / 50 + 1)` is for the redisplay's "a regexp is taking too
   long" watchdog, which this tree does not have.
3. **`at_dot` matches only in a buffer.** `PTR_BYTE_POS (d)` is
   defined for buffer text; a string match has no buffer position to
   compare, and here it answers false rather than comparing against
   the current buffer's point.
4. **The standard syntax table, not the property-resolved one, for
   `mutually_exclusive_p`.** The C's `execute_charset` there calls
   `ISWORD` with the plain syntax table; this does the same through a
   reader over `(syntax-table)`.
5. **`match-data`'s trailing-nil trimming is the caller's.** The
   matcher answers -1 for an unset register, as the C does; Emacs's
   Lisp `match-data` trims trailing unset pairs (`(string-match
   "\\(a\\)?" "b")` gives `(0 0)`, not `(0 0 nil nil)`), and that
   belongs to the `match-data` port in `search.sld`, not here.
6. **No unibyte patterns.** Scheme strings hold code points; the C's
   `!multibyte` arms and every `CHAR_BYTE8_P` branch are marked in the
   compiler where they would be.

## The standard category table is still empty, and `\c` sees it

`(schemacs editor category)` has the category *machinery* but not
`characters.el`'s data. Emacs's standard table gives `x` the set
`".Lalr"`; here every set is empty. So `\c.` (category `.`) matches
everything in Emacs and nothing here, and `\C.` the other way round:
`(string-match "\\C.+" "xxcc")` is nil in Emacs and 0 here. That is the
one differing case in the engine's differential, and it is a data
transcription job (`characters.el`'s `modify-category-entry` calls and
`char-script-table`), not an engine defect.

## Guile's optimizer miscompiles the big function at its default level

Compiled with `compile-file`'s default optimization, `regex-compile`
segfaults on its first call before executing a single form - interpreted
it is fine, and `#:optimization-level 0` is fine. The trigger is the
optimizer inlining the internal helpers into `main-loop`. Marking them
as assigned (`(set! main-loop main-loop)` and the six beside it) stops
the inliner and the compiled library is correct. The self-assignments
are in the source with that note; they are the same trick the tree
already uses against constant folding. If this function is ever split
or the helpers move, re-check the compiled build first.

## Verified

A differential harness (`/tmp/cases.txt` + `emacs -Q --batch`) over 49
cases - literals, `.`, every quantifier including non-greedy, both
alternation directions, groups, shy and numbered groups, back
references, charsets and classes, ranges, intervals, syntax/word/
symbol assertions, anchors, `\=`, and the empty pattern - matches
Emacs 31.1 except the category-data case above, once the harness
applies Emacs's own trailing-nil trim. A second eight-case harness with
`translate` set to the buffer's CANON table matches with case folding
on. The syntax class letters come from `syntax.scm`'s `%spec-code`,
which is now exported rather than duplicated.

# The standard category, script and case data (2026-11-21, later)

The previous section's "the standard category table is still empty" is
superseded: `characters.el`'s data is in the tree now, dumped from a
running Emacs 31.1 the way the charset maps and the xterm decode map
were, under `schemacs/etc/`:

| file | lines | what it is |
|---|---|---|
| `categories.txt` | 19,229 | one run per line: FROM, TO, the run's `category-set-mnemonics` string |
| `scripts.txt` | 448 | `char-script-table` runs: FROM, TO, script symbol |
| `case-table.txt` | 1,511 | the standard case table's DOWN slot, non-identity runs |
| `case-up.txt` | 1,527 | its UPCASE slot |
| `case-canon.txt` | 1,531 | its CANON slot |
| `case-eqv.txt` | 3,044 | its EQV slot |

`category.sld` finds them through `%load-path` (the `charset.sld` rule),
defines every category in the standard table with Emacs's own docstring
(43 of them, embedded in the library because they are a page of text,
not table data), and sets each run's interned category set with one
`char-table-set-range` per run. `casetab.sld` loads the four case slots
the same way before `set_case_table` runs.

## The C's `WORD_BOUNDARY_P` is a NAND, not an AND

Comparing `\b` across scripts found the first real engine bug the data
exposed: the matcher had

    (and (> c1 255) (> c2 255) (word-boundary-p c1 c2))

from the docstring's "there is no word boundary between two
word-constituent ASCII and Latin-1 characters". The macro
(`category.h:116`) is

    (!(SINGLE_BYTE_CHAR_P (c1) && SINGLE_BYTE_CHAR_P (c2))
     && word_boundary_p (c1, c2))

- *either* character being multibyte is enough to ask
`word_boundary_p`. Measured: `(string-match "a\\bα" "aα")` is 0 in
Emacs, and was nil here; `中\ba` likewise. Fixed in all three assertion
sites (`wordbound`, `wordbeg`, `wordend`), and the five measured pairs
now agree.

## The case slots are dumped, not derived

Emacs's standard UPCASE slot is **not** what `set_case_table` derives
for the same DOWN table: `up[65]` is 65 in the standard table, where
the derivation gives 97 (the hand-made-table test in
`casetab-tests.scm` documents the derivation's 65 -> 97 as Emacs's
answer for a *user* table). So the four slots are dumped separately and
loaded as data; `set_case_table` then has nothing to derive and only
hangs EQV from CANON's extra slot 2.

## Departures that remain

1. **Identity entries are not stored.** Emacs's standard tables hold an
   explicit entry for characters that map to themselves after a run
   boundary (`aref standard-case-table 233` is 233); the dump omits
   them, so `char-table-ref` answers the table's default (`#f`).
   `char_table_translate` treats a non-character value as the character
   itself, which is why matching, folding and translation agree; only
   reading a slot directly can see the difference.
2. **Sets are interned, not structurally shared across equal
   mnemonic strings from different runs** beyond
   `hash_get_category_set`'s hash - the same rule the C has.
3. The category data is read at load time (about 0.1 s here for 340
   KB), where Emacs has it pre-dumped. A tree without
   `schemacs/etc/categories.txt` loads with an empty standard table
   rather than failing, which is also what a source checkout without
   the installed file would want.

## Verified

- `char-category-set` mnemonics match Emacs on ASCII, Latin-1, Greek
  and Han samples.
- The five script-boundary `\b` cases match Emacs.
- Case-insensitive matching of `É/é`, `Σ/σ` in both directions, and
  ASCII folding, match Emacs.
- The 49-case regexp differential now differs only in the harness's
  formatting of trailing unset match-data pairs, which is Emacs's
  `match-data` trimming, not the engine.
- `category-tests` 20/20 and `casetab-tests` 13/13.

# The engine under `search.c`, and the performance pass (2026-11-21)

`(schemacs editor search)` is on the ported engine now - `string-match`,
`looking-at`, `re-search-forward`, `re-search-backward` and the searches
they stand on call `re-search`/`re-match-2` of
`(schemacs editor regex-emacs)`. The old `%emacs-ere` translation,
its 512-character copy window and the `\_<`/`\_>` assertion simulation
are **deleted**, with the `(ice-9 regex)` / `make-regexp` imports and
the syntax/chartab names only they used.

## Correctness found by the swap

1. **`buffer->re-text` was handed buffer positions where it wants
   store indices.** The class stores positions one-based
   (`buffer-text-base`, Emacs's `BEG = 1`) and `buffer->re-text`'s
   `base`/`z` are store indices (`BEG_ADDR` and `Z_ADDR`-style). Every
   buffer match was one character early and one short of the last
   character until the three ends were converted by `- base`.
2. **A nested shy group was `Invalid regular expression`.**
   `(if regnum ...)` in the group parser is true for Scheme's `0`,
   where the C's `else if (regnum)` is false; a `\(?:` group at
   `re_nsub` 0 got regnum 0, took the explicitly-numbered branch, and a
   group inside it found the outer frame's 0 in the compile stack and
   raised `badpat`. `(> regnum 0)` is the C's test. The whole
   alternation of `scheme-font-lock-keywords` was affected.
3. **`match-data`'s nil handling** was compacting - an unmatched
   register in the middle vanished and shifted the pairs after it.
   It now emits `#f` for an interior unmatched register and elides
   only the trailing ones, as `Fmatch_data` does with `len = 2*i+2`;
   the no-search answer is `nil` even when REUSE is given, and REUSE
   longer than the values is filled with nil to its end.

## Why it was slow

Measured, not guessed. A single failing search over a 32-character
line allocated **283,680 bytes**, and under `statprof` the run spent
**19.5 of 21.4 seconds in GC**. The non-GC profile was the matcher
itself. Three representation departures, all against the C, in the
order they were fixed:

1. **The failure stack started at 800 entries.** `INIT_FAIL_STACK`
   (`regex-emacs.c:934`) uses `INIT_FAILURE_ALLOC` = **20**
   (`:900`), and the storage is `SAFE_ALLOCA` - no GC. One 800-entry
   vector per start position was ~190 KB of the 283 KB. It is 20 now
   and the stack is **reused across the attempts of one search**
   (`%fail-stack-reset!`); the C's storage dies with each
   `re_match_2`, so the lifetime differs, but nothing can observe it.
2. **Charset and fastmap tests allocated a bignum per character.**
   `(logand map (ash 1 c))` over a 256-bit integer allocates on both
   sides. `logbit?` tests the limb in place. The C tests a word of a
   bitmap (`BITMAP_BIT_P`/`BITMAP_WORD`); this is that test.
3. **The matcher returned through an exception.** `done!` raised a
   `<match-result>` and the whole loop sat in a `guard`, once per
   start position. The C's `succeed_label` does `return dcnt`
   (`regex-emacs.c:4763`). A `%match-done` sentinel and a `result`
   variable now thread the answer back through the frames. That was
   ~40% of the post-allocation profile.

## The matcher is an attempt object, not a call stack

`re_match_2` in C is one stack frame; the port's helpers were
internal procedures, so every `re-match-2` call made ~16 closures,
four register vectors, a failure stack and a memo. `make-match-attempt`
builds them **once per search**, and its returned procedure resets the
mutable attempt state for each start position (the C's prologue).
`re-search` creates one attempt outside its loop; `re-match-2` remains
for a single anchored attempt (`looking-at`). This is a representation
departure only: the matcher's opcode switch, failure stack algorithm
and backtracking are the C's.

The failure stack's entries were `(tag . value)` conses - three conses
per push, and a push on every attempt plus pops on every backtrack.
They are one flat vector with two slots per entry, the C's flat array
of unions; the pushes and pops write and read the slots directly
(`%push-failure-point!` etc. inline what `%push-elt!`/`%pop-elt!` did),
and `%fail-stack-ensure!` is `GROW_FAIL_STACK`. `%pop-failure-point!`
answers `(values PAT STR)` rather than a cons.

`%execute-charset` tests the bitmap before reading the class bits (a
hit is decisive), and the `charset` opcode tests it once more for a
non-negated set before calling out - most characters of most patterns
are ASCII bitmap hits.

## Numbers

Compiled, same benchmark (`/tmp/bench/bench.scm`), microseconds per
search:

| pattern | before | after | Emacs |
|---|---|---|---|
| `[a-zA-Z_][a-zA-Z0-9_]*` | 9.14 | **1.94** | 0.185 |
| failing `[ \t]*\(...\)[ \t]*(` | 267.8 | **35.0** | 3.71 |
| `\(foo\|bar\)baz` on 200 chars | 35.8 | **5.4** | 0.184 |
| `\_<[a-z]+\_>` | 11.0 | **2.7** | 0.259 |

Emacs is `string-match-p` in a byte-compiled loop on the same
patterns and texts; the ratios are **10.5x / 9.4x / 29x / 10.4x**.

Allocation per search: **232 KB -> 1.4 KB** steady state. The
intermediate steps were 46.8 KB (small fixes), 32.7 KB (direct
return), 12.3 KB (attempt object) and 1.4 KB (flat stack). The final
figures are three runs at load average 1.1; the `\(foo\|bar\)baz` row
had one 17.3 µs outlier, the other two 8.6.

**Caveat**: the later timings were taken with the machine at load
average 6-15 (the user's own processes). Two "regressions" chased
during the pass were the load, not the code: repeated runs of an
unchanged build differed by 10x, and the interpreted run of the same
build moved with them. The table's "after" figures are the quiet-run
values from each step; the structural evidence (allocation counts,
`statprof` shares, the A/B of the failure-stack inlining) is
load-independent.

## The second wave: the fastmap loop and the text substrate

Three more changes, all measured:

1. **`<re-text>` records its substrate.** It now carries either the
   Scheme string or `#(STORE GPT GAP BASE)` for a buffer, in addition
   to the closure. `%re-text-ref` reads `string-ref` or the store
   directly; `make-re-text` (the exported two-argument constructor)
   still makes a closure-only text. This is the representation change
   the first pass said character reads would need.
2. **The fastmap skip loop is specialized by substrate.** It hoists
   the map's bits and `any-nonascii` flag, and reads the string or
   buffer store directly - no `%re-text-ref`, no `re-fastmap-ref`, no
   `%translate-code` call per skipped character in the common
   `translate = #f` case. `\(foo\|bar\)baz` over 200 `x`s went from
   8.6 to **5.4 µs** (29x Emacs's 0.184, from 46x). The remaining cost
   is a Scheme loop iteration per character; Emacs scans bytes in C.
3. **`jump` first in the opcode `cond`** (it was 23 comparisons down,
   where the C's switch is one branch): ~3% on the failing pattern.
   The push capacity check is inline as well, as the C's
   PUSH_FAILURE_ITEM macro is.

## The third wave: bitmap tables and the failure path (2026-11-21)

Four more changes, each A/B'd by CPU time (see the measurement note
below), on the same bench as the earlier waves:

1. **The charset bitmap is a 256-entry boolean vector.** `<re-charset>`
   gains `table`, built once from the integer bitmap when the charset
   is made, and the matcher's inline test is `(vector-ref table c)`.
   Compiled microbenchmark: **11 ns against `logbit?`'s 20 ns** on the
   256-bit integer. The integer `map` stays because
   `mutually_exclusive_p` compares two charsets with `logand`.
2. **A bitmap-only set settles a miss without `%execute-charset`**
   (`simple?` = no ranges, no class bits). Every failing test of
   `[ \t]*` or `[a-zA-Z_]` used to pay a procedure call to learn what
   the bitmap already said. A/B on the failing-bracket row: **15-18%
   faster** (6.3e10 -> 5.4e10 CPU-ns per 50k searches). **This has no
   counterpart in the C** - `execute_charset` always runs its (empty)
   range and class tests there and recovers the cost by being inlined -
   so `simple?` is a host-compensation, recorded as such in the source
   too, not an Emacs algorithm.
3. **The fastmap skip loop reads a boolean table**, built at the end of
   `re-compile-fastmap`; the integer `bits` stays as the accumulator
   because `analyze_first` adds bits over time, and the table is built
   even when no bit is set (an `any-nonascii`-only map is usable and
   the loop indexes the table for every character below 256). A/B on
   the 200-character skip row: **20-25% faster** (1.35e10 -> 1.05e10);
   wall time 5.35 -> 4.05 µs at higher load than the quiet run above.
4. **The failure path lost its wrappers and its multiple values.**
   `fail!` no longer boxes a `values` pair per backtrack - the pop
   leaves the saved position in a `<failure-stack>` field, as the C
   passes both to POP_FAILURE_POINT by address - and no longer
   allocates a fresh `(list ...)` for `memv` per backtrack; the
   three-way test is an `or` of `=`s. The one-line local wrappers
   (`push-failure-point!`, `memo-failed?`, `translate-code`,
   `check-infinite-loop`, the pop) are gone, so an instruction no
   longer pays a closure hop to reach the global procedure. With 1-3
   this took the failing-bracket row from 35.0-35.5 to 32.5-33.1 µs
   at *higher* load than the earlier quiet measurement; allocation per
   search is unchanged at ~3.1 KB.

**Measurement note.** This machine reports user CPU time (`(times)`,
`get-internal-run-time`) at about **2.2x wall time** for a
single-threaded Guile loop - measured against bash's `time`: real
3.25 s, user 7.0 s, sys 0.8 s - and the factor is stable between runs,
so CPU-time A/B is the load-robust comparator while absolute
microseconds must come from wall-clock runs on a quiet machine. The
leave-one-out A/Bs above reverted one change at a time in the same
tree and recompiled `regex-emacs.scm` alone; the first attempt at a
"before" build also renamed the global `%push-failure-point!` by
matching its own definition line, which is why the reverse patterns
were afterwards scoped to the matcher region.

## The fourth wave: the ASCII translate cache, and two things that did not work (2026-11-21)

1. **The compiled pattern caches its translate table for characters
   0..255** (`translate-vec` on `<re-pattern-buffer>`, filled lazily by
   `re-translate-vector`). `char-table-ref` on the case-canon table
   measured **64 ns** per lookup against a vector's **11 ns**, and a
   folded match asks it once per character - in the skip loop and in
   the charset/exactn/anychar/duplicate arms. Folded rows: failing
   bracket 5.5-5.6e10 -> **4.9-5.1e10** CPU-ns, `\_<[A-Za-z_]...\_>`
   8.8-10.0e9 -> **7.1-7.2e9**, `\_<[0-9]+\_>` 1.05e10 -> **7.5-8.0e9**;
   unfolded rows unchanged. **No C counterpart**: the C's `TRANSLATE`
   is a C-level `char_table_translate` tree walk, which gcc inlines;
   this is a host-compensation, and it is recorded here as one. The
   answers are `%translate-code`'s exactly; characters above 255 still
   go through the table.
2. **The regexp cache key now holds the translate table itself**
   (`search.scm`), not the boolean `icase?`. Emacs compares
   `cp->buf.translate` (`search.c:220`), so a buffer with its own case
   table cannot reuse an entry compiled with another's; ours could.
   `(PATTERN ICASE TABLE)` -> `(PATTERN TRANSLATE TABLE)`, with the
   translate chosen before the lookup. A correctness fix, not a
   performance one.

**Two things that did not work, and why they are recorded:**

- **Reordering the opcode `cond` is a loss.** Moving
  `on_failure_jump_loop/memo/prememo/smart` from below `begbuf`/`endbuf`
  to just after `charset` made the failing-bracket row **15-25%
  slower** (5.3e10 -> 6.2-6.3e10), because `start_memory`/`stop_memory`
  and the other arms that then sit later in the chain outnumber the
  loop arms in that pattern. Reverted; the C's `switch` does not have
  this trade-off because it is a jump table.
- **Hoisting the failure stack's `entries`/`avail` into attempt locals
  would buy almost nothing.** Record accessors measure 11.5 ns against
  `vector-ref`'s 9.2 ns compiled, so the four accessor calls a push
  makes are ~9 ns of a ~120 ns push. Rejected on measurement, before
  writing the refactor.

**The profile after the four waves** (failing bracket, `statprof`):
the match loop's self time is 40.7%, `%pop-failure-point!` 13.9%,
`%re-text-ref` 10.3%, `%push-failure-point!` 9.0%, `fail!` 6.8%,
`%push-failure-reg!` 4.2%, `re-search` 3.6%. `logbit?` and
`%execute-charset` no longer appear on this pattern. What is left is
the per-instruction Scheme loop and the stack's vector accesses - the
structural floor named above.

## The final numbers, Emacs and the engine interleaved (2026-11-21)

Wall-clock, three interleaved rounds (Emacs, engine, Emacs, engine,
Emacs, engine) on the same four patterns and texts, the
machine at load average 1.8. Emacs 31.1 is `string-match-p` in a
byte-compiled loop; the engine is `re-search` in a compiled library.
Both case folding off (`case-fold-search` nil / `translate` #f) and on
(the editor's default), the latter with upper-case text so the folds
are exercised:

| pattern | fold | Emacs µs | engine µs | ratio |
|---|---|---|---|---|
| `[a-zA-Z_][a-zA-Z0-9_]*` | off | 0.185-0.189 | 2.11-2.23 | 11.4-11.8x |
| failing `[ \t]*\(...\)[ \t]*(` | off | 3.72-3.75 | 29.9-30.4 | **8.0-8.1x** |
| `\(foo\|bar\)baz` over 200 chars | off | 0.181-0.186 | 3.84-4.07 | 21-22x |
| `\_<[a-z]+\_>` | off | 0.257-0.263 | 2.74-2.82 | 10.5-10.7x |
| failing `[ \t]*\(...\)[ \t]*(` | on | 4.40-4.57 | 32.4-32.7 | **7.2-7.3x** |
| `\(foo\|bar\)baz` over 200 chars | on | 0.614-0.635 | 9.52-9.67 | 15.2-15.7x |
| `\_<[A-Za-z_][A-Za-z0-9_]*\_>` | on | 0.278-0.286 | 2.33-2.44 | 8.3-8.6x |
| `\_<[0-9]+\_>` | on | 0.385-0.392 | 3.13-3.27 | 8.1-8.5x |

Against the second wave's table (35.0 / 5.4 / 2.7 / 1.94 µs), the
failing bracket is 8.0x Emacs instead of 9.4x, and the folded rows
(the editor's default) sit at 7-9x except the long skip. Emacs pays
for folding too - its own folded bracket is 4.4 µs against 3.7 - which
is why the folded ratios are *lower* than the unfolded ones. The ratios
this engine cannot close without leaving Scheme: the 200-character skip
is one Scheme loop iteration per skipped character (15-22x), and the
dispatch loop is one `cond` comparison per arm where the C's `switch`
is a jump table.


## What is left, and what did not work

- **Dispatch:** the attempt lambda - the inlined `match-loop` and its
  `cond` - is now ~41% of the matcher's self-time. Guile's `case`
  expands to `memv` over literal lists, which would be slower than the
  `=` chain, so it was not converted; a handler vector trades the
  comparisons for an indirect call and has not been measured as a win.
- **Failure-stack walk and pushes**: ~19% combined even after the
  slot inlining.
- **`%re-text-ref`**: ~10%, one procedure call per character. The
  direct read is in place; going further means duplicating the matcher
  per substrate, which is a large change for the last 10%.
- **Charset tests and `%execute-charset`**: the bitmap hits are inline,
  and a bitmap-only set no longer calls out on a miss (third wave); the
  range scan on a miss of a *complex* set is still a procedure call.
- The charset fast path and the class-bits reordering were first made
  as machine load rose; the final quiet run includes them, but there
  is no isolated A/B for those two.

## The `set! main-loop main-loop` workaround, re-measured

Removing all eight self-assignments in `regex-compile` segfaults on
the first call when the library is compiled - and **at O0 and O1 as
well as O2**, so it is not the inliner. The module loads; the crash is
inside `scm_call_n` executing the compiled procedure. Only the
`main-loop` assignment matters: each of the other seven, alone, still
crashes, and an unrelated self-assignment does not help. Making the
call non-tail, a lambda indirection, a top-level `%call0` caller and
reordering `finish` before it all still crash, so the trigger is in
main-loop's own compiled form. The workaround can be reduced to
`(set! main-loop main-loop)`; the other seven lines are cargo.

## Verified

- `search-tests` 88/88, the 49-case differential (the one known
  difference is the harness printing raw registers where Emacs's
  `match-data` trims trailing unset ones), `replace`, `font-lock`,
  `lisp-mode`, `dired-mode`, `coding` suites.
- Full suite: 83 suites, with `syntax-tests` and `mouse-tests` once
  failing under load average 14 and passing individually on the same
  tree immediately after (84/84 for mouse; 65 passes for syntax). The
  final runner pass on the settled tree was clean.
- `tools/pty-check.py`: **100/100** on the final tree. A first run
  failed every check because a comment-only edit to `loadup.scm` after
  the compile sweep left a "source file newer than compiled" note on
  the terminal; recompiling the tree fixed it.
- A compiled-vs-interpreted check: the matcher is 7.8x faster
  compiled, so the library is genuinely compiled despite the
  `main-loop` workaround.
