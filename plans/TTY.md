# Leaving ncurses: the terminal backend written the way `term.c` is

Chris, 2026-11-11: *"ok, write down that plan and start work on option D to
get rid of ncurses"*.

The goal is not speed by itself. It is that **the terminal is ours**, so the
glyph matrices and the terminal agree, so the row diff is trustworthy, and so
a keystroke stops costing a whole screen.

## Why ncurses is being removed, and what Emacs actually links

Emacs links ncurses **for `tputs`**. `configure.ac:6100` names the probe by
that function and prints, when nothing has it:

> The required function **'tputs'** was not found in any library.
> The following libraries were tried (in order):
> **libtinfo, libncurses, libterminfo, libcurses, libtermcap**

`libtinfo` is tried *first*, and on GNU/Linux it is what gets linked; the
`-lncurses` cases are overrides for Darwin (an old Terminal.app crash),
Hurd, and old FreeBSD. On this machine `libtinfo.so.6` is a symlink to
`libncursesw.so.6` - one library, split by packaging.

What that means, in one table:

| | who provides it |
|---|---|
| the terminal database (2,900 terminfo entries) | the filesystem |
| `setupterm`, `tigetstr`, `tigetnum`, `tigetflag` (readers) | libtinfo |
| `tparm` (parameter expansion) | libtinfo |
| `tputs` (the writer, with padding) | libtinfo |
| **the virtual screen, the diff, the scroll optimisation, cursor tracking** | **Emacs writes it** (`dispnew.c`, `cm.c`, `term.c`) |
| `initscr`, `refresh`, `waddstr`, `doupdate`, `getch` | **never called** - zero hits in `src/*.c` |

So Emacs uses ncurses as a **terminfo client library**, the way it uses
libpng. We, by contrast, call `addstr`/`refresh`/`erase` - we have borrowed
ncurses's *screen management*, which Emacs owns. That is the departure, and
it is what makes the row diff fight ncurses's virtual screen (see
DEPARTURES.md, "The terminal still repaints its whole frame").

## What Emacs's terminal redisplay is

```
redisplay_internal
  └ redisplay_window (per window)        ← each window's desired matrix (we have this)
  └ update_frame (f)
      └ update_tty_frame (f)             → build_frame_matrix (f)
      └ update_begin (root)
      └ write_matrix (root, ...)          ← the tick
          ├ scrolling (f)                 ← I/D lines, only if FRAME_LINE_INS_DEL_OK
          └ write_row (f, i) per enabled row
              ├ cursor_to         → tty_cursor_to → cmgoto
              ├ write_glyphs      → tty_write_glyphs
              └ clear_end_of_line → tty_clear_end_of_line
      └ make_matrix_current (root)
      └ update_end (root)
      └ tty_set_cursor
```

**The terminal redisplay has ONE matrix for the whole frame**, and
`write_matrix` walks it row by row calling the terminal's hooks. It diffs
against `f->current_matrix` itself. There is no third-party screen buffer.

Sizes, for reference (all `src/`): `write_row` 304 lines, `scrolling` 97,
`write_matrix` 25, `build_frame_matrix_from_leaf_window` 130,
`make_matrix_current` 7, `clear_desired_matrices` 23, `cm.c` 467,
`term.c` 5,479 of which the redisplay-facing hooks are ~600,
`lisp/term/*.el` 10,573 across 33 files.

## The plan

Three phases. **Each phase ends with all 76 pty checks green**, which is the
only thing that makes a change this structural safe to do at all.

### Phase 1 - the terminfo layer, with ncurses still drawing (~400 lines)

The point of this phase is that it is **observably a no-op**: same screens,
ncurses still drawing every cell, every check still passing. It exists so
the layer can be verified before anything depends on it.

- `schemacs/ui/ncurses/tinfo.scm`, a new library mirroring the *interface*
  of `termcap.c`: `setupterm`, `tigetstr`, `tigetnum`, `tigetflag`, `tparm`,
  `tputs`.
  All six are in `libncursesw.so.6` (verified with `nm -D`), reached through
  `dynamic-func` as `pgtk.scm`'s `pango-foreign-fn` does it.
  - `tparm` takes nine `long` parameters and returns a pointer into a static
    buffer. The portable declaration in modern ncurses is
    `char *tparm(const char *, long, long, long, long, long, long, long,
    long, long)`.
  - `tputs(const char *str, int affcnt, int (*putc)(int))`: the callback is
    a Scheme procedure wrapped with `procedure->pointer`, which allocates on
    every call - so `tputs` is used only for strings carrying padding
    (`$<n>`), and everything else is written straight to the port, which is
    what `cmputc` amounts to.
- Terminal modes from terminfo rather than `initscr`: `smcup`/`rmcup`
  (alternate screen), `smkx`/`rmkx` (keypad transmit), and `tcsetattr` via
  FFI of `libc` for raw mode (`termios` - we already FFI `statvfs` in
  `fileio.scm`, so the idiom is in the tree).
- **The key decoder**, replacing `getch`'s decoding: Emacs's
  `static const struct fkey_table keys[]` (`term.c`) is **58 entries** of
  `{"kh", "home"}, {"ku", "up"}, …`. Each is `tigetstr(cap)` → the sequence
  → `define-key input-decode-map`. We already have `*input-decode-map*`
  (255 entries from `xterm.el`) and `%sequence->event`; this replaces the
  terminfo round-trip through `keyname`, which is the hack that produced the
  dotted-pair bug.
- Keep ncurses for `getch` (raw key bytes), colours, and `tiget` - so this
  phase changes *nothing* a user sees.

### Phase 2a - re-shape the interface to Emacs's signatures (~200 lines, no behaviour change)

Chris, 2026-11-11: *"It's ok that we use GOOPs instead of a vtable, however
the shape of the functions themselves should aim to be emacs shaped in
names and arguments."*

**This has to come before the tty work**, because the terminal hooks cannot
be written correctly against the current shape: we pass what Emacs's
redisplay computes *for* the backend, so a backend that wants to decide for
itself has nothing to decide with.

Emacs's signatures, verbatim (`dispextern.h`):

```c
void (*write_glyphs) (struct window *w, struct glyph_row *row,
                      struct glyph *string, enum glyph_row_area area,
                      int len);
void (*clear_end_of_line) (struct window *w, struct glyph_row *row,
                           enum glyph_row_area area, int x);
void (*update_window_begin_hook) (struct window *w);
void (*update_window_end_hook) (struct window *w, bool cursor_on_p,
                                bool mouse_face_overwritten_p);
void (*flush_display) (struct frame *f);
void (*clear_frame_area) (struct frame *f, int x, int y,
                          int width, int height);
void (*draw_window_cursor) (struct window *w, struct glyph_row *glyph_row,
                            int x, int y, enum text_cursor_kinds cursor_type,
                            int cursor_width, bool on_p, bool active_p);
```

Ours today, and the three departures:

| Emacs | ours | departure |
|---|---|---|
| `(w, row, string, area, len)` | `(d, glyphs, y, x, attribute)` | **y and x passed at all**, where Emacs reads them off `row`; **an already-realized attribute**, where Emacs passes `area` and the backend looks up `glyph->face_id` |
| `(w, row, area, x)` | `(d, y, x, width, token)` | the backend derives y from `row` and width from `window_box_width (w, area)`; we compute all three above the line |
| one call per row, run-split by the backend | one call per *run*, split by `draw-glyph-row!` | the splitting (`fill_glyph_string`'s job) sits *above* the interface instead of below it |

**The work**, all renames and argument re-plumbing, no output change:

1. `write-glyphs!` → `(d window row area glyphs len)`, reading `row`'s x/y
   and each glyph's face id. The run split moves into each backend: the GUI
   backend keeps `fill_glyph_string`'s rule (`fill_glyph_string`,
   `xdisp.c:31157` - "same `face_id`"), the tty backend gets its own.
2. `clear-end-of-line!` → `(d window row area x)`.
3. `update-window-end!` gains Emacs's two flags.
4. Add the terminal hooks under Emacs's names, unimplemented where nothing
   can answer yet: `cursor-to`, `raw-cursor-to`, `clear-to-end`,
   `clear-frame`, `update-begin`, `update-end`, `set-terminal-modes`,
   `reset-terminal-modes`.

**The gate**: all 76 pty checks green, and `pgtk-tests`' pixel checks green -
they are what proves the run split still produces the same pixels.

### Phase 2 - the screen is ours (~900 lines)

- **`build_frame_matrix`** and friends (`dispnew.c:2521`): one matrix for
  the frame, each window's rows copied in at its offset. ~150 lines.
  `build_frame_matrix_from_window_tree` 11, `..._from_leaf_window` 130,
  `make_matrix_current` 7, `clear_desired_matrices` 23.
- **`write_matrix` + `write_row`**: the tick. Compare the desired frame row
  against the current one and emit the differing cells. 25 + 304 lines.
  `scrolling` (97) comes in Phase 3 or never - see below.
- **`cmgoto`** (`cm.c`, 467 lines): the cursor-motion cost model that picks
  `cup` vs `hpa`/`vpa` vs relative moves, and only pays for what it must.
  This is what makes Emacs's tty output short, and it is pure logic over
  terminfo strings. ~250 lines in Scheme.
- **The `tty_*` hooks** (`term.c`): `tty_cursor_to` 408, `tty_raw_cursor_to`
  430, `tty_write_glyphs_1` 760, `tty_clear_end_of_line` 494,
  `tty_clear_to_end` 449, `tty_clear_frame` 472, hide/show cursor 346/363,
  highlight on/off 318-395. ~400 lines.
- Then, and only then: delete `addstr`, `attr-on!`/`attr-off!`, `erase`,
  `refresh`, `clearok!` from the drawing path, and **delete the
  `(not (graphical-frame?))` branch** from `clear-garbaged-frames!` - the
  departure disappears rather than being worked around.

### Phase 3 - colours, and ncurses leaves the tree (~300 lines)

- Colour emission: we already compute OSC 4 for truecolor and use
  `init-pair!` for the palette. The pairs become direct `setaf`/`setab`
  emission from the same computed values, and the palette-slot cache stops
  being an ncurses workaround and becomes the design (`DEPARTURES.md`,
  "Direct colour is carried in redefined palette slots").
- `init_pair`/`color_pair`/`start_color`/`use_default_colors` all go; the
  pair table is ours, which is what Emacs's `tty_face_1` already is.
- Remove `(ncurses curses)` from `term.scm` entirely. The library becomes
  `tinfo.scm` + the screen, and the dependency list loses its toolkit.

## What this buys

- A keystroke stops writing the whole screen: measured today at **425 bytes
  and ~13 ms** for a plain `C-n` on a 40-row terminal, because every row is
  erased and rewritten - the `ESC[H ESC[2J` at the head of the stream.
- The glyph matrices and the terminal agree, so **the row diff becomes
  trustworthy on a tty** and the corruption class (`C-x i` drawing over the
  echo row, Dired's marks vanishing) goes away by construction.
- Both front ends then take the same `update-window!` path, and the terminal
  stops being a special case in `xdisp.scm`.

## Deliberately deferred: `try_window_id`

`try_window_id` (`xdisp.c:22583`, 793 lines) and
`try_window_reusing_current_matrix` (`:21788`, 446) are **not part of this**,
for a reason found by reading:

```c
/* xdisp.c:22650 */
if (!FRAME_WINDOW_P (f)
    && (FRAME_INITIAL_P (f) || !FRAME_LINE_INS_DEL_OK (f)
        || !WINDOW_FULL_WIDTH_P (w)))
  GIVE_UP (4);
```

`try_window_id` **gives up on a terminal that cannot insert and delete
lines** - which is exactly what we switch off. So it is not a fix for the
tty today, and it would only become one after Phase 3 gives us the ability
to emit `il`/`dl` ourselves. It is a GUI-scroll optimisation and a separate
project (~2,300 C lines, and it needs `struct it`).

`scrolling` (`dispnew.c`, 97 lines) is the same story: it is the I/D-line
optimisation, gated on `FRAME_LINE_INS_DEL_OK`, and it belongs with
`try_window_id` rather than with Phase 2.

## Risks, and how each is handled

- **Per-terminal quirks.** Emacs has `lisp/term/*.el` (10,573 lines) and its
  own `cm.c` fudges. We are targeting xterm-family terminals, which is what
  `xterm.sld` already covers, and `$TERM` handling stays as it is. A
  terminal Emacs works on and we do not is a bug report, not a silent
  regression.
- **Raw mode and signal handling.** `initscr` currently does `tcsetattr`
  and `endwin` restores it. Doing it ourselves means getting
  `dynamic-wind`/`C-z` suspension right - `suspend-display!` /
  `resume-display!` already exist and would become `rmcup`/`smcup` pairs.
- **The pty battery is the gate, not the goal.** It has already been shown
  to be a fallible oracle (five harness reader bugs and two check bugs found
  in one day), so a phase is not "done" on a green battery alone: it also
  gets a `tmux capture-pane` comparison for the drawing.
