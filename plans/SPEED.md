Now I have enough to answer properly, from the code.

## Why Emacs isn't slow

**1. It doesn't redraw. It diffs.** Every window keeps *two* glyph matrices: `w->current_matrix` (what is on the screen) and `w->desired_matrix` (what should be). `redisplay` builds the desired one and then `update_window` compares cell by cell, emitting only the glyph runs that differ. A cursor move changes one cell.

**2. The row is the unit, and a row is precomputed.** `struct glyph` (`dispextern.h:472`) is a packed record — `charpos`, `object`, `face_id`, `pixel_width`, ascent/descent, and a handful of bitfields, all fixed-size. A row is an array of those, built once by `display_line`. Comparing two rows is `memcmp` over a contiguous block; no allocation, no dispatch, no string building.

**3. Scrolling is a whole-row block move.** `scrolling_window` (`xdisp.c`) finds that the new desired matrix equals the old one shifted by N rows and then just *scrolls the pixels* — `scroll_run_hook` — instead of drawing anything. Scrolling a long file is a blit, not a repaint.

**4. The frame isn't cleared.** `update_window` writes into the existing window surface and Gtk composites it. **There is no `clear_frame` in the per-keystroke path at all.** Our `render!` starts with `clear-frame-area!` and repaints every row — that is the single biggest structural difference, and it's why my redraw-skip couldn't work.

**5. Only the glyphs that changed reach the toolkit.** Emacs emits a `glyph_string` per *run* of same-face glyphs and hands each to the backend once. We hand Pango a string per run too, but we call `write-glyphs!` for every run of every row on every frame — `~100` guile-gi crossings per keystroke, each ~0.06 ms, which matches the 6 ms measured.

**6. GOOPS is not the reason, but it's not free either.** 64% of samples in `class-precedence-list` is generic dispatch — but in Emacs the equivalent discipline is a **`face_id`, an integer**, precomputed per glyph at matrix-build time (`glyph->face_id`), and the backend looks up `face_cache->faces[face_id]` with an array index. We do the merge-and-realize per run per frame, through a generic. That's a design choice we can fix without touching GOOPS: realize once per (face, attributes) and cache the integer, exactly as Emacs does.

So the gap is not "C vs Scheme". It's four structural things: **no glyph matrix, a frame clear per keystroke, per-run toolkit calls on unchanged content, and face realization on the draw path instead of an id.** Three of those are fixable in this tree with the same algorithm Emacs uses; the first is the real work item — a `current_matrix`/`desired_matrix` pair per window with `memcmp`-style row comparison.


Now I can answer precisely.

## The dispatch is per *run*, and the run boundary is a face change

**The interface is a struct of function pointers**, `struct redisplay_interface` (`dispextern.h:3069`) — one vtable per backend (`x_redisplay_interface`, `tty_redisplay_interface`, `pgtk_redisplay_interface`, …). The entry points that matter are:

```c
void (*draw_glyphs) (struct window *w, int x, struct glyph_row *row, ...);
void (*write_glyphs)(struct window *w, struct glyph_row *row,
                     struct glyph *string, enum glyph_row_area area, int len);
void (*clear_end_of_line)(...);
void (*scroll_run_hook)(struct window *w, struct run *run);
```

`draw_glyphs` (`xdisp.c:31977`) is the shared driver: it turns a **row's glyph array** into **glyph strings**, then calls the backend's `draw_glyphs` once per glyph string. So there are three levels, and none of them is per character:

| level     | unit                   | decided by                                            |
| --------- | ---------------------- | ----------------------------------------------------- |
| redisplay | **window**             | `w->redisplay`, `window_outdated`, mode-line flags    |
| driver    | **row**                | `update_window` comparing current vs desired matrices |
| backend   | **glyph string = run** | `fill_glyph_string` (`xdisp.c:31157`)                 |

**Where a run breaks** is `fill_glyph_string`'s loop condition, literally:

```c
while (glyph < last
       && glyph->type == CHAR_GLYPH
       && glyph->voffset == voffset
       /* Same face id implies same font, nowadays.  */
       && glyph->face_id == face_id
       && glyph->glyph_not_available_p == glyph_not_available_p)
```

**`&& glyph->face_id == face_id`** — that, and the type/voffset/availability tests, is the whole rule. So a run is a maximal stretch of one row with the same face, the same vertical offset and the same font. A row of plain text in one face is **one** glyph string; a mode line with four propertized runs is four.

And `face_id` is **an integer index** into `f->face_cache->faces[]`. That's the other half of why Emacs is fast: the face is resolved when the *matrix row* is built, not when it is drawn. `draw_glyphs` never merges attributes; it does `FACE_FROM_ID`.

So: not per character, and not per line either — **per run, where a run is a same-face stretch, and rows are the unit of comparison**. We already have the run concept (`line-face-runs`), but we compute it *at draw time*, per frame, and call `write-glyphs!` (a GOOPS generic) per run per frame — where Emacs computed it once into the row and calls a C function pointer.

---

## Where the crash left the tree, and the paren state (2026-11-10)

The session died mid-splice while moving `render!` onto glyph matrices. Three
files were added and `xdisp.scm` was left unbalanced, so **the editor does not
start**. `glyph.scm` and `matrix.scm` read and compile clean.

The defect is localised to `schemacs/xdisp.scm`, in the new
row-building block (`line-slice-glyphs`, `text-cells-width`, `build-row!`,
`display-window!`, `update-window!`, `draw-glyph-row!`), between the last
statement of `render-window!` (line 2677) and `render-window-mode-line!`
(2679). The crashed splice removed exactly one `)` on the old
`(update-window-end! (current-display)))` line while splitting
`render-window!` in two (mode line + border moved out into
`render-window-mode-line!`).

Structural facts established with a depth walk (comments and strings
skipped), current working tree:

| line | function | ends at depth | should end at |
|---|---|---|---|
| 2258 | `display-window!` | 1 | 2 |
| 2331 | `draw-glyph-row!` | 2 | 3 |
| 2311 | `update-window!` | 1 | 2 |
| EOF 3412 | library close | 0 with a spare `)` | — |

Overall the file is balanced and the *reader* accepts it, but the extra `)`
that closes the library early means the tail (`update-window!` … `log-message`)
is parsed as siblings of the `begin` rather than members of it — which is why
`compile-file` reports `source expression failed to match any pattern in form
((define (update-window! …`.

**Do not keep hand-counting parens on this.** AGENTS.md says stop after a few
attempts. The clean recovery is to rebuild the region from `render-window!`
through `display-window!` in one file, verify it with the reader *and* a
compile, then splice the whole block — the method that worked for
`%transpose-subr` on 2026-10-02.

---

## Recovered after the session crash (2026-11-10)

The session that wrote `glyph.scm`/`matrix.scm` and rewired `render!` died
mid-splice. The tree it left **did not start**. Everything below was found
and fixed by driving the code, not by reading it; both files compile and
the suites are green except for a handful of pixel/geometry tests.

### The paren damage

`xdisp.scm` was unbalanced with **two** defects, not one:

1. `display-window!` and `draw-glyph-row!` each ended one `)` short, so the
   following `define`s were absorbed into their bodies.
2. A stray `)` on a line of its own closed the library early, so everything
   from `update-window!` onward - including the two menu-bar hook
   `define`s - was parsed *outside* the `begin`. That is what made
   `*menu-bar-update-hook*` "unbound" in `menu-bar.scm` while being
   perfectly well defined.

**The method that worked**, after hand-counting failed repeatedly: rewrite
`(define-library (NAME)` as `(begin` in a copy, read the result with
Guile's reader, and walk the parsed forms. A file whose *top level* has
more than `begin`/`import`/`export` is broken, and the extra children name
the damage. `grep -n '^)'`-style checks and a running paren counter both
missed it; the parsed structure did not.

### Three real bugs in the new code, each found by running it

- **`face-at-buffer-position` was asked about position 0.** `line-slice-glyphs`
  took `from`/`to` as *column offsets* into the line and used `(+ from i)`
  as a buffer position. Position 0 is out of range: "Args out of range (0)".
  The absolute position is `(+ line-start from i)`, which is what
  `build-row!` already computes for `glyph-row-start`.
- **Six record fields were named with a `?`.** `define-record-type` derives
  the setter by appending `!`, so a field `enabled?` generates
  `set-glyph-row-enabled?!` - not the `set-glyph-row-enabled!` everything
  calls. The reader accepted it and the failure was an unbound variable at
  the first *write*. The fields are `enabled`, `mode-line`,
  `truncated-on-right`, `continued`, `displays-text`, `ends-at-zv` and
  `fill-line` now; the `?` is on the accessor, spelled out in the field
  spec.
- **`row-hash` added the glyph's text with `+`.** This tree's `glyph-char`
  holds a *string* (a cell's whole text, for a `display` property), where
  the C's holds a character code. Adding a string is "Wrong type argument
  in position 2". `glyph-text-hash` folds the string to an integer first.

### The departure `C-x C-f` exposed

`render!` raised **"Args out of range (2)"** when the current buffer was
not the window's - which is every prompt, because `read_minibuffer-1` makes
the minibuffer current. `display-window!` had lost the
`with-current-buffer` that the old `render-window!` had, and
`line-slice-glyphs` asks `(current-buffer)` for the face at a position. GNU
Emacs's `redisplay_window` does `set_buffer_internal (XBUFFER (w->contents))`
for exactly this reason. Restored; the `minibuffer` pty check passes and
the typed path no longer leaks into the file buffer.

**Worth knowing**: the old `render-window!` was the *only* thing that
established the window's buffer, so splitting it moved that guarantee out
of a function that no longer draws rows. Any future split has to carry it.

### Still failing

- `mouse-tests` 1, `pgtk-tests` 6 - pixel and geometry expectations. Not
  yet diagnosed; they are the first things the new row path changes the
  look of, so they are where to look next.

---

## The migration finished, and where the time actually went (2026-11-10)

Measured with `render!` over 200 lines, 24x80, compiled:

| | before | after |
|---|---|---|
| `render!` | **19.8 ms** | **1.06 ms** |
| `display-window!` (row building) | 15.2 ms | 0.74 ms |
| `update-window!` (the diff) | 0.5 ms | 0.03 ms |
| mode line | 2.2 ms | 0.15 ms |

**The glyph matrices were never the problem; face realization was.** Every
number below is one bug found by measuring, and none of them would have
been found by reading.

### The five bugs

1. **A realize per glyph.** `line-slice-glyphs` called
   `face-at-buffer-position` - which *realizes* - once for every cell. That
   is 24 x 80 = 1920 realizes a keystroke, and the tree already had the
   note saying why that is wrong (`line-face-runs`: "realizing per
   character is 15us on GTK against 1.2us for the attribute lookup...
   which is what made isearch look like it had hung"). It now compares
   *unrealized* attributes and realizes once per run, which is exactly
   `line-face-runs`' shape. **15.2 -> 0.74 ms on its own.**

2. **`assign-row` copied `used` where the C swaps it.** Emacs's
   `swap_glyph_pointers` exchanges `glyphs`, `used` and `hash` together
   and `copy_row_except_pointers` then copies from `x` onward, so those
   three are never re-copied. Ours swapped the vector and then set `used`
   from the desired row - leaving the desired row claiming a count for a
   vector it had given away. `row_equal?` then walked `used` entries of an
   empty vector: "Argument 2 out of range", raised inside
   `update-window!`, which runs in the command loop - **a redisplay that
   quietly stopped.**

3. **`draw-glyph-row!` painted every run at the window's first column.**
   It passed the row's `x0` to `write-glyphs!` for every run instead of
   advancing the column, so each run overwrote the last and only the final
   (default-faced) one survived. That is why the region looked unpainted:
   the row had the right face ids, and they were drawn on top of each
   other.

4. **`display-window!` hardcoded `x0 = 0`.** Every window drew its text in
   the leftmost column, whatever `window-left` said.

5. **`w->window_end_pos` was written only by the dead code.**
   `render-window-rows!` recorded it; the glyph-matrix path replaced the
   caller but not the recording, so nothing set it and `window-end` fell
   back to its own scan. `mouse-scroll-subr` measures from `(window-end)`,
   so a drag past the window's edge left point a row too high -
   `mouse-tests`' 156-against-201. `display-window!` records it now, as
   `display_line` does.

### Dead code

`render-window!` and `render-window-rows!` are no longer called by
anything. They are left in place for now: `render-window-rows!` still has
the `window-end` computation that was just ported into `display-window!`,
and deleting the pair is a separate, safe change once this has been used
for a while.

### The measurement trap, again

The first reading after the fixes said 19.3 ms - the *pre-fix* number -
because `--no-auto-compile` loaded the stale `.go` files. Recompiling
took it to 1.06 ms. **`rm -rf ~/.cache/guile/ccache` before believing any
performance number**, which this file already says and which still cost a
round.

---

## The three bugs Chris hit by using it (2026-11-10)

Each was reported from the running editor, and each was a thing the migration
had left half-done rather than a new invention.

### "Paging down to the bottom flashes between two screens"

**`render!` still called `clear-frame-area!` on the every-keystroke path**,
while `update-window!` draws only the rows its diff calls changed. So most of
the frame was erased and never repainted, and the scroll decision - which reads
`window-end`, computed from the row walk - was made about a picture that no
longer existed. The comment *below* the call already said the frame must not be
cleared; the call was above it.

The fix is Emacs's, and its own comment is the argument:

    The call to clear_frame was a source of flickering.  I believe a
    clear_frame is not necessary.  It should suffice in the new redisplay
    to invalidate all current matrices, and ensure a complete redisplay
    of all windows.                                -- xdisp.c:13686

So `struct frame` gained **`garbaged`** (`frame.h:1172`) with
`FRAME_GARBAGED_P` / `SET_FRAME_GARBAGED`'s spellings, and `render!` runs
`clear-garbaged-frames!` (`xdisp.c:13699`): invalidate every current matrix,
which makes the diff select every row, and clear the surface only when the
frame was garbaged.

**A terminal still clears every frame**, and that is `FRAME_WINDOW_P`'s branch
in `redraw_frame` (`dispnew.c:3212`) rather than a shortcut: this tree's tty
`clear-frame-area!` says why - "the partial-update optimizations (scroll
regions, insert/delete character) desync the physical terminal when lines
merge". `clear-garbaged-frames!` therefore treats a non-graphical frame as
always garbaged. Getting this wrong was measured: with the clear removed for
the terminal too, `scroll` and `pagedown` went from failing to failing
*differently*, with the old screen's text showing through the new one.

### "Resize the window bigger and it only scrolls the top half"

`sync-frame-size!` re-tiled the windows and told nobody the surface was gone.
It now sets `garbaged`, which is Emacs's `f->resized_p` path into
`clear_garbaged_frames` ("has been resized (probably due to a window manager
resize)").

### "Loading a file writes it over the other file without clearing"

The rows of the *old* buffer were still in the matrix, so `row-equal?` matched
them, the diff drew nothing, and the previous file's lines stayed on screen
under the new file's. Fixed on both sides:

- **`set-window-buffer!` garbages the frame** when the buffer really changes.
  GNU Emacs reaches the same place without the flag - `set_window_buffer` ends
  with `w->window_end_valid = false` and `redisplay_window`'s
  `try_window_reusing` then fails into a redraw - but this tree compares
  matrices rather than checking that flag, and the rows it compared were the
  old buffer's.
- **`clear-end-of-line!`** is a new display generic, `dispnew.c`'s
  `clear_end_of_line`. A terminal's `addstr` writes only the cells it is
  handed, so a row that got shorter kept the old row's tail. The GUI gets it
  free from its rectangle fill; the terminal needs it, and it was missing
  entirely. `draw-glyph-row!` calls it past the end of the text, which is the
  C's "the new row is shorter than the old one" case (`dispnew.c:4960`).

### Two things this shook out that were not on the list

- **`ensure-surface!`** is now its own generic. `pgtk-ensure-surface!` was
  called only from `clear-frame-area!`, so a redisplay that legitimately stops
  clearing had no surface to draw into and `pgtk-write-screenshot!` silently
  wrote nothing. A new surface is also *filled* with the default background
  now: `cairo-image-surface-create` makes a transparent one, which no longer
  mattered while every frame was cleared.
- **The truncation and continuation markers were never drawn.** `build-row!`
  recorded `truncated-on-right?`/`continued?` and `draw-glyph-row!` ignored
  them, so a wrapped or cut-off line showed no `\` or `$`. Both are drawn now,
  in the default face (`produce_special_glyphs`), and the right-hand one is
  placed from the *window's* last cell rather than the row's width - a row
  that made room for the left `$` is one cell narrower and put its marker in
  the wrong place. The hscrolled line's left `$` is drawn too, and its
  truncation test uses the C's `hscroll + width - 1`.

---

## The click on the minibuffer row (2026-11-10)

Chris, clicking the minibuffer:

    Wrong type argument: #<<frame> windows: (...) selected-window: ...>

The chain, each link checked against the source:

1. `posn-at-x-y` walks `(window-list frame)` and, when no window's rectangle
   holds the cell, answers **the frame** - "Outside every window: Emacs
   answers the frame, and the position of a frame is the frame"
   (`keyboard.c:13009`, `make_lispy_position`).
2. The echo area is a **row of the frame**, not a window, so a click there is
   exactly that case.
3. `posn-set-point` (`subr.el:2013`) takes the frame branch, asks
   `frame-selected-window`, and calls `select-window` - which cannot take a
   frame. That is the wrong-type-argument, naming the frame.

**Emacs never reaches step 3.** Its `posn-at-x-y` finds the *minibuffer
window*, because `window_from_coordinates` walks every window in the frame's
tree and the minibuffer window is one (`window.c:1686`,
`check_window_containing`). And `mouse-set-point` calls
`mouse-minibuffer-check` before `posn-set-point`:

    (let ((w (posn-window (event-start event))))
      (and (windowp w)
           (window-minibuffer-p w)
           (not (minibuffer-window-active-p w))
           (user-error "Minibuffer window is not active")))
                                    -- mouse.el:768

`mouse.scm` said this was "not carried: it refuses an event inside a
minibuffer-only frame, and this tree has no such frame". That was true and
was the bug: the *condition* is reachable without a minibuffer window,
because the echo area is the thing that stands in for one. So
`mouse-minibuffer-check` is ported, with the C-shaped window test replaced by
its equivalent here - a frame position on the frame's last row.

- **Not active** (no prompt): refused, "Minibuffer window is not active".
- **Active** (`*echo-area-buffer*` is a live read): allowed, because the
  event is already inside that recursive edit.

It is called where Emacs calls it: `mouse-set-point`'s first line and
`mouse-drag-track`'s. `posn-set-point` keeps its faithful shape and now has a
comment saying why the frame branch is unreachable in Emacs and reachable
here.

**Two missing imports found on the way**, both the usual class: `mouse.scm`
used `*echo-area-buffer*` and `inexact->exact` without importing them. The
first is why the guard silently did nothing at first, the second why it then
raised "Unbound variable: ~S" naming a name instead of the message it meant
to raise.

`mouse-tests` has four cases: the position names the frame, the check refuses
it, the check allows it while a prompt is up, and a click in the text area
still selects.
