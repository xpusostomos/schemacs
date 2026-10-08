# GTK-PLAN — a pixel-based display interface, and a GTK/Pango backend

## Context

The ncurses reorganisation succeeded: `(schemacs editor term)` is the only curses
code, no core library imports it, and every input path goes through the display
interface. The seam is real — a second backend can be written without touching
the editor. That work is committed (`2e7aa62 final ncurses reorg`), green at
339 unit tests and a 27/28 pty battery.

But the seam is shaped like a *terminal*. Our display interface is
**cell-based**: `write-glyphs!` takes row and column, `screen-size` answers
`(rows . cols)`, and `xdisp` derives every width by counting characters (tab
expansion and caret notation live in `disp-table.sld`). A GUI backend can only
obey that grid.

Emacs does the opposite, and that is the decisive evidence:

- `src/xdisp.c` produces glyphs in **pixels** — `struct glyph` carries
  `short pixel_width` / `ascent` / `descent` (dispextern.h:503-506), and
  `struct glyph_row` carries `int x, y` plus `pixel_width`/`ascent`/`height`
  (dispextern.h:950-964).
- A terminal is the *degenerate* case, not the other way round:

  ```c
  /* src/frame.c:1182 */
  f->column_width = 1;  /* !FRAME_WINDOW_P value.  */
  f->line_height  = 1;  /* !FRAME_WINDOW_P value.  */
  ```

  One tty character **is** one pixel unit, so one redisplay serves both.
- Even Lisp's character-unit coordinates are derived: canonical x/y values are
  fractions of `FRAME_COLUMN_WIDTH` / `FRAME_LINE_HEIGHT` (frame.h:1690-1704).

So the faithful design makes the **pixel** fundamental and the terminal's unit 1.
Our interface makes the cell fundamental, which is the deviation — and it is the
single thing standing between us and a real GUI (proportional fonts, images,
variable line height, a real cursor, smooth scrolling).

**Goal:** make the interface pixel-based (Stages 1–2), then write a GTK/Pango
backend that slots into it with **zero core edits** (Stage 3). The terminal must
not change behaviour at any point — that is the fidelity test.

## Evidence gathered already

Interface contract facts any backend must satisfy (verified in the code):

- **Face tokens must be integers with 0 meaning "plain".** `xdisp.sld:569` does
  `(not (= attribute 0))` on a `realize-face` result in `line-end-fill-attribute`.
  A GUI cannot return an opaque record; it must intern realized faces to integer
  ids. Invisible from the docstrings — you only find it when the region is active.
- **`read-input-event` must return a char or integer, or `#f`; and must never
  return `#f` on a blocking (`-1`) read**, because `keyboard.sld:437` treats that
  as end-of-input and quits the editor.
- **Writes are last-write-wins over cells already drawn this frame** — search
  highlights, the region fill and the continuation `\` are painted over text.
- **The display must clip**; the fast path deliberately overruns the window edge.
- **Two full frames render before any input is read**, so drawing must work with
  an unmapped window. `screen-size` is asked *before* the window exists
  (`new-frame`, `frame.sld:446`).
- `update-window-begin!`/`end!` take no window argument — they can only bracket.
- `suspend-display!`/`resume-display!` are only reached from C-z
  (`frame.sld:614`); for a GUI they are no-ops.

Emacs grounding for the GTK key handling — mirror these, **not** the retired
in-repo backend (whose translation has no named keys at all, so arrows and F-keys
come out as `#\null`, never sets `super`, and mishandles Shift):

- `src/pgtkterm.c` — `pgtk_gtk_to_emacs_modifiers` (:5157), `get_modifier_values` (:5128)
- `src/gtkutil.c` — `xg_widget_key_press_event_cb` (:6449), `gdk_keyval_to_unicode` (:6600)

Environment, verified: guile-gi installed; typelibs `Gtk-3.0`, `Gdk-3.0`,
`Pango-1.0`, `PangoCairo-1.0`, `cairo-1.0` all present; a display is available
(`DISPLAY=:0`).

**The retired backend's guile-gi idiom is wrong for the installed version.**
Measured: `(gi:use-typelibs (("Gtk" "3.0") #:prefix gtk:))` — the form in
`schemacs/backend/guile-gi/gtk3-init.sld:36-90` — binds **nothing** (introspecting
the module after it gives 0 bindings). The installed guile-gi (git
`1231.388653a`) uses `(gi repository)`'s `require` / `load-by-name` /
`typelib->module`:

```scheme
(define-module (pgtk-names)
  #:use-module (gi)
  #:use-module (gi repository))
(typelib->module (resolve-module '(pgtk-names)) "Gtk" "3.0")
```

- `typelib->module` needs an **explicit module reference**: `(current-module)`
  bound 0 names from a load/`-c` context, while
  `(resolve-module '(pgtk-names))` gave **9,659** Gtk bindings.
- Names are **idiomatic GOOPS, not C**: `<GtkWidget>`, `(make <GtkWindow> ...)`,
  and `class:method` (`widget:show`, `application:run`) — *not*
  `gtk_window_new`. So the driver cannot be a transliteration of `pgtkterm.c`;
  only its semantics port.
- **Blanket-importing the typelib is hazardous.** Loading Gtk into a module and
  then `(use-modules that-module)` shadows core bindings — in testing it
  shadowed `begin` and broke unrelated code ("No applicable method for
  `begin`"). The driver must keep typelib names in a private namespace and
  import `only` what it needs, as the rest of this repo does. This is why the
  driver and the editor must not share a namespace.
- `load-by-name` takes **C names with underscores** (`"keyval_name"`, not
  `"keyval-name"`), and loads a named *type*, not loose global functions.

## Stage 1 — make the contract pixel-typed (no behaviour change)

The terminal answers `column_width = 1`, `line_height = 1`, exactly as Emacs's
does, so **every number the tty sees stays the same** and the pty battery must
stay byte-identical. This stage buys the shape a GUI needs.

- `dispnew.sld`: coordinates of `write-glyphs!` and `draw-window-cursor!` are
  documented as pixels (keep the existing `(y x)` argument order — Emacs's
  `write_glyphs` carries positions in the glyph string, so there is no signature
  to mirror, and reordering is gratuitous churn).
- `dispnew.sld`: add the two frame metrics Emacs keeps on the frame —
  `column-width` and `line-height` — as display operations. Terminal: 1 and 1.
- `screen-size` becomes **pixel** dimensions. Rows and columns are then *derived*
  (`pixel-width / column-width`), as Emacs derives a frame's `total_cols`. This
  flips the current sense of `screen-size` (`(rows . cols)` today) — the hazard
  in this stage. Its only consumers are `frame.sld:446` (`new-frame`) and
  `frame.sld:476` (`sync-frame-size!`), so audit those two and the window
  rectangles they derive.

`xdisp` keeps its cell arithmetic in this stage and passes those numbers through
as pixels — valid because the terminal's unit is 1.

## Stage 2 — `xdisp` measures instead of counting

This is the bulk of the work, and it is what a GUI actually needs.

- Add measurement to the interface — roughly "width of this text" and "line
  height". This mirrors Emacs asking a font for glyph metrics.
- `disp-table.sld`'s character-width logic (`char-display-glyph`,
  `expand-line-display`, `line-display-offsets`, `current-line-display-column`,
  `line-display-width`) becomes the **terminal's implementation** of those
  operations rather than a core service. Blast radius is contained: `xdisp.sld`
  is its only importer.
- `xdisp.sld` calls the display instead of `disp-table` directly throughout
  (`expand-line-display` at :427/:751, `line-display-offsets` at :479,
  `line-display-width` at :512/:528, `current-line-display-column`, and
  `char-display-glyph` at :519).
- Measurement runs per character via `face-at-buffer-position`, so the results
  need caching. Emacs has a whole glyph cache for this reason; a simple
  per-(string, font) memo is the starting point.
- Wrapping stays out of scope (there is none today; the pixel interface makes it
  *possible*, not required).

## Stage 3 — the GTK/Pango backend

Files, mirroring the Emacs split:

- **`schemacs/editor/pgtk.sld`** → `(schemacs editor pgtk)`. Mirrors
  `pgtkterm.c`'s role beside `term.sld` (`term.c`). A `<pgtk-display>` class,
  methods for every generic, and `with-gtk-display` as the analogue of
  `with-terminal` (sets `current-display`, initialises faces, `dynamic-wind`
  teardown).
- **`schemacs/ui/platform/gtk.sld`** → `(schemacs ui platform gtk)`. `main-gtk`,
  structured from `main-ncurses`: scratch buffer, open display, `new-frame`,
  `command-line-1`, `note-file-read-only!`, `event-loop`. Must also import the
  four binding-carrying libraries (`simple`, `isearch`, `window`, `buff-menu`)
  that `ncurses.sld` imports purely so their `define-key` forms run.
- **`main-gtk.scm`** — thin entry, as `main-ncurses.scm`.
- **Retire** `schemacs/ui/platform/guile-gi-gtk3.sld` and
  `schemacs/backend/guile-gi/` — replaced, not kept alongside. (Nothing in them
  is reusable: no cairo, no Pango, no main-loop pumping, and its key code is
  broken.)

Implementation notes that carry real risk:

- **Blocking read — DONE, prototyped and measured.** Collect key events into a
  queue from the `key-press-event` signal; `read-input-event` pumps with
  `main-iteration-do?` until the queue is non-empty, with the deadline
  implemented as a GLib timeout pushing a sentinel event (not a clock). Verified
  accurate to a few milliseconds. See "The guile-gi recipe, as measured" below.
- **Drawing.** A `GtkDrawingArea` and its `draw` signal, with cairo/Pango. Keep a
  cell-free model: `xdisp` now supplies pixels, so draw runs at their pixel
  positions with Pango attributes (weight, underline, colour). Honour
  last-write-wins and clip to the window.
- **Face tokens.** `realize-face` interns realized faces to **integer** ids with
  0 = plain (see the constraint above); `write-glyphs!` looks them up.
- **Keys.** Mirror `pgtk_gtk_to_emacs_modifiers` / `xg_widget_key_press_event_cb`.
  Events must be a char or an integer; use integer codes for named keys and decode
  them in `key-event->keymap-path`.
- **suspend/resume.** No-ops, or window hide/show.

### Rendering: guile-gi's cairo gap, and the GdkPixbuf bridge

Chris asked whether `gdk_pixbuf_new_from_data` was really unavailable, and it was
not — an earlier conclusion here that the cairo path was blocked was **wrong**.
What follows is what survived checking.

**guile-gi's cairo coverage is insufficient for drawing.** The Gtk typelib binds
only Gdk's cairo *helpers* — `cairo-set-source-rgba`, `cairo-rectangle` — plus
PangoCairo's `show-layout` (which really is `pango_cairo_show_layout`, method
`(<CairoContext> <PangoLayout>)`). None of cairo's own primitives are bound:
`move_to`, `fill`, `paint`, `set_source_rgb`, `translate`, `save`, `restore` are
all missing, and `load-by-name "cairo" "move_to"` fails outright. So a
`GtkDrawingArea` cannot be drawn into — there is no way to move the cairo point
to a cell, and no way to fill or paint. `show-layout` is bound but unusable
without a way to position it.

**guile-cairo has all of it** (1.11.2, installed at Chris's initiative):
`cairo-move-to`, `cairo-fill`, `cairo-paint`, `cairo-set-source-rgb`,
`cairo-translate`, `cairo-save`/`restore`, `cairo-select-font-face`,
`cairo-set-font-size`, `cairo-show-text`, and the full image-surface API
(`cairo-image-surface-create`, `-get-data`, `-get-stride`, `-set-data`,
`cairo-surface-write-to-png`).

**The two ARE bridged, via GdkPixbuf — an earlier claim here that they were not
was wrong.** `gdk_pixbuf_new_from_data` is exposed, as **`pixbuf:new-from-data`**
(guile-gi's `class:method` convention, not C names), together with 71 pixbuf
bindings: `pixbuf:new-from-bytes`, `pixbuf:get-pixels`, `pixbuf:get-rowstride`,
`pixbuf:new`, `pixbuf:new-from-stream`. It lives in the **GdkPixbuf** typelib
(`GdkPixbuf-2.0`, package `gdk-pixbuf2`), which is *separate from Gtk and Gdk*.
Two mistakes produced the wrong conclusion: GdkPixbuf was never `require`d, so
only its *types* appeared (pulled in by Gdk) while its functions did not; and the
search used C-style names. **Load every typelib explicitly and search for
`class:method`, not C names.**

So the cairo route is open: guile-cairo draws the frame (owning the pixels, via
`cairo-image-surface-create-for-data` over a bytevector of our own, or
`cairo-image-surface-get-data`), the bytes become a `GdkPixbuf` with
`pixbuf:new-from-data`, and GTK shows it — `image:new-from-pixbuf` /
`image:set-from-pixbuf` are bound, and `image:new-from-surface` for a guile-gi
surface. Only the exact argument list of `pixbuf:new-from-data` remains to be
confirmed (its arity/order, and whether the destroy-notify is elided).

**The routes, in order of viability:**

1. **cairo offscreen -> `GdkPixbuf` -> `GtkImage` — recommended.** guile-cairo
   draws the whole frame into a buffer we own; the bytes become a pixbuf with
   `pixbuf:new-from-data`; a `GtkImage` shows it. This is the real pixel path, so
   it is what makes proportional fonts and the Stage 2 measurement interface
   worth anything, and it needs no C and no extra installs. It also keeps our
   model honest: we own the framebuffer, so clipping and last-write-wins are
   ours, not the toolkit's. `cairo-surface-write-to-png` gives a screenshot for
   free.
2. **Widget/markup rendering — pure Gtk widgets.** One `GtkLabel` per screen row
   in a `GtkBox`/`GtkGrid`, with Pango *markup* for the faces. Verified bound:
   `<GtkLabel>`, `label:set-markup`, `<GtkBox>`, `<GtkGrid>`, `box:pack-start`,
   `grid:attach`, `widget:set-size-request`, `widget:override-font`,
   `font-description-from-string`. Simpler and needs no cairo, but it is the
   toolkit drawing our text, so a cell grid and per-cell clipping become
   approximations, and there is no path to proportional fonts. A fallback.
3. **Draw directly into GTK's cairo context.** Would need guile-cairo and
   guile-gi to share a `cairo_t`; neither exposes a pointer conversion. Route 1
   achieves the same result without this.

### The driver works - and the "guile-gi mystery" was ours

`schemacs/editor/pgtk.sld` + `schemacs/editor/pgtk-names.scm` now run: the
display opens, answers `screen-size`, draws a frame, and the blocking read
returns `#f` on its deadline. Key translation is verified: `(0 . 97)` -> `(#\a)`,
`(4 . 97)` -> `(ctrl #\a)`, `(8 . 120)` -> `(meta #\x)`, `(0 . 65362)` ->
`("up")`. **Zero core files changed**; 339 unit tests still pass.

The long debugging detour had a mundane cause worth recording, because it is
easy to repeat:

**`define-method` on a name that is not imported silently creates a NEW
generic.** `clear-frame-area!` was missing from the driver's `only` list from
`dispnew`, so `(define-method (clear-frame-area! (d <pgtk-display>)) ...)` built
a *phantom* generic rather than adding a method to the real one. The visible
effect was not "no method" at the point of the mistake - it was `clear-frame-area!`
having 0 methods on the real generic, and then **segfaults in unrelated calls**
(`connect`, `container:add`) whose dispatch went through the corrupted state.
That is why every hypothesis I formed from the symptom was wrong. Lesson: when a
GOOPS method seems not to apply, check `(generic-function-methods g)` and
`(eq? (module-ref A n) (module-ref B n))` before theorising about the FFI.

Two further traps found on the way:

- **The typelib surface must not live in the driver's module.** An R7RS
  `define-library` cannot export typelib names at all (`%load-info` fails), and a
  module holding the surface misbehaved. The working arrangement is
  `pgtk-names.scm`, a Guile-native `define-module` holding the surface, with the
  driver importing `only` from it.
- **GDK modifier masks**: SHIFT 1, CONTROL 4, MOD1 8, SUPER `1<<26`, HYPER
  `1<<27`, META `1<<28`. MOD1 means **meta**, as Emacs has it. Using small
  integers for SUPER/HYPER (as a first draft did) silently produces wrong
  modifier lists.

### Drawing: faces, and the window's size

Two more found by looking at it.

**Faces are not just a foreground colour.** The terminal draws the mode line, the
region and the search match with `:inverse-video` or `:background`, and a first
draft that read only `:foreground` rendered the mode line in ordinary positive
video. `realize-face-token` now keeps `(FOREGROUND BACKGROUND BOLD UNDERLINE)`
and swaps the pair for `:inverse-video` — with neither set that is white on
black, which is the mode line. A `:background` may be a **colour name**
(`region`'s is the string `"gray"`), resolved through
`tty-color-standard-values` from `tty-colors.sld` rather than parsed here:
`tty-color-values` would give the *terminal's* rendering of the name, which maps
`gray` to the palette's white. `write-glyphs!` paints the run's background
rectangle before the glyphs.

**The window must be told the frame's size, and told about resizes.** A
`GtkWindow` made with no size takes Gtk's default, so the 80x24 grid was not what
the window was, and the content was the wrong shape. It is now made with
`window:set-default-size` from the grid, and a `size-allocate` handler turns the
allocation back into columns and rows, drops the surface (it is the wrong shape
now) and enqueues a resize. That reuses the terminal's own mechanism: a resize is
reported as a *code* - `*resize-code*`, a single integer, since that is all
`read-input-event` may answer - which `key-event->keymap-path` decodes to
`(resize)`, exactly as `term.sld` turns `KEY_RESIZE` into it. The command loop
then re-renders, and `sync-frame-size!` re-tiles the frame.

**The display must ASK the widget its size, never remember it.** This is the fix
that finally stopped the text stretching, and the earlier attempts were symptoms.
A display that keeps a size in a slot - filled from a `size-allocate` signal - is
wrong whenever the window and the slot disagree: between the window changing and
the signal being handled, or when no signal comes at all. Gtk scales a pixbuf to
fill the widget it is in, so any disagreement is a stretch. `screen-size` and the
surface now both call the widget for its allocation at the moment they need it, so
they cannot disagree, and whatever a compositor does to the window the display
follows. The `size-allocate` handler now only asks the command loop to redraw.
Verified on a 344x778 tiled window - 38 columns, no distortion.

**And the surface must be the widget's size, not the grid's.** This is what made the
text stretch: a `GtkImage` is allocated the whole window and Gtk scales the pixbuf
to fill it, so any mismatch between the pixbuf and the widget is a stretch. The
grid is `floor(allocation / cell)`, which is *always* up to a cell narrower and
shorter than the allocation, so the pixbuf was permanently slightly too small and
permanently stretched. A diagnostic printing both sizes side by side showed it at
once: `(win 1430 787 img 1430 787 grid 80 24)` - the widget is the window, the
grid is not. The display now keeps the allocation in **pixels** as well as the
grid in cells, and makes the surface, and so the pixbuf, the pixel size. The pixbuf
and the widget then agree exactly and there is nothing to scale.

**The cell metrics were right all along.** "Stretched letters" looked like a font
problem; measuring showed the monospace font at size 15 has an advance of exactly
`9.0` and a height of `18.0`, which is what the driver assumed. The distortion was
the window, not the cells. `cairo-text-extents`/`cairo-font-extents` are the way
to confirm this rather than guess.

### Six input bugs, all found by trying it

Both were invisible until a real key was pressed, and both are easy to repeat.

**1. `read-input-event` must answer a character or an integer - never a pair.**
The driver's read was returning `(MODIFIER-STATE . KEYSYM)`, which is the natural
thing for a GTK key to be. But `keyboard.sld`'s `key-event?` is
`(or (char? ev) (integer? ev))`, and on a *blocking* read anything else is taken
for the end of input, so the editor quit on every keystroke. The interface cannot
carry a compound event, which is why a terminal folds modifiers into the byte and
why its keypad codes are single integers. This driver now encodes
`(state, keysym)` into one integer - state in the high bits, keysym in the low
ones - and `key-event->keymap-path` decodes it. Verified: `97` -> `(#\a)`,
`4<<32 + 97` -> `(ctrl #\a)`, `8<<32 + 120` -> `(meta #\x)`, `65362` -> `("up")`.

**2. The Gdk accessors answer TWO values.** `event:get-state` and
`event:get-keyval` are `gdk_event_get_state (event, &state)` and
`gdk_event_get_keyval (event, &keyval)`: an out-parameter plus a success flag, so
guile-gi returns the flag *and* the value. Taking one value yields the boolean and
fails later with `+: Wrong type argument: #t`. Use `let*-values` - which is what
the retired backend did, at `gtk3-init.sld:186`.

**3. The modifier state is a `<GdkModifierType>`, not an integer.**
`event:get-state` answers the enum, so an `(integer? state)` test — or any
arithmetic on it — silently yields 0 and **every modifier is lost**. The symptom
is precise: `C-x` types `x`. Convert with `modifier-type->number` (which is what
the retired backend did at `gtk3-init.sld:190`).

**4. A control character must fold to `C-<letter>`.** Emacs's ASCII protocol
says a control character *is* `C-<letter>`, and `ncurses-key->keymap-path` folds
it that way. A GTK `GDK_KEY_Return` carries no modifier, so it arrives as
Unicode 13; emitting that as a bare character gives a literal carriage return —
which the editor then renders as `^M` and does not treat as RET. The driver now
runs the character through the same fold the terminal uses, so RET -> `(ctrl #\m)`
(which the keymap binds to `newline`), TAB -> `(ctrl #\i)`, ESC -> `(ctrl #\[)`.

**5. `shift` is not a modifier this keymap knows.** `(schemacs keymap)`'s
`modifier->integer` accepts only ctrl/control, meta, super, hyper and alt, so a
path containing `shift` raises **"unknown keymap-index modifier symbol"** — which
is what any *shifted* key produced (typing a capital letter is enough). Shift
must be dropped, exactly as the terminal drops it: `named-key-modifiers` in
`term.sld` answers `#f` for the shift variants. Nothing is lost, because Gdk
already gives the shifted keysym (`shift+a` arrives as `#\A`).

**6. Modifier keys are delivered as key presses, and must be dropped.**
Emacs never sees a modifier press - a terminal and a window system consume them -
but Gtk delivers one, and a modifier keysym has no keymap path, so it surfaced as
`"; unhandled event: 65515"` (`0xffeb`, Shift_L) in the echo area. On a Wayland
compositor it appears unprompted at startup, because sending shift is how the
compositor hands focus over. The read now drops any event whose keysym is a
modifier (`0xffe1`-`0xffee`, caps/shift lock, num lock, ISO_Level3_Shift) and
keeps reading, so the caller is never handed a key it cannot act on. The retired
backend did the same, as "modifier-only key press: ignore".

### The guile-gi recipe, as measured

All of this was established by running it, so it need not be rediscovered.

**Initialising Gtk.** `gtk_init` and `application:run` are *not bound* — both take
`(int *argc, char ***argv)`, which is not introspectable, so guile-gi skips them.
The initialiser is the bare name **`init-check!`** (`(init-check!)` answers `#t`).
Do not build a widget before it: doing so segfaults with only `Gtk-CRITICAL`
warnings as a clue.

**Loading the names.** Load the typelibs into a **private** module and import
`#:select`-ed names from it:

```scheme
(define-module (pgtk-names)
  #:use-module (gi)
  #:use-module (gi repository))
(typelib->module (resolve-module '(pgtk-names)) "Gtk" "3.0")
```

Importing that module wholesale shadows core bindings — it shadowed `begin` — so
only ever `#:select`. This is why the driver cannot share a namespace with the
editor.

**The names are GOOPS-idiomatic, not C**, and boolean-returning functions take a
`?`:

| what | bound as |
|---|---|
| make a widget | `(make <GtkWindow>)`, `(make <GtkDrawingArea>)` |
| show | `widget:show-all` |
| event mask | `(set! (widget:events w) (list->event-mask '(key-press-mask)))` |
| a signal | `(connect w (make <signal> #:name "key-press-event") handler)` |
| pump the loop | `main-iteration-do?` |
| drop a source | `source-remove?` |
| a key | `event:get-keyval`, `keyval-to-unicode` |

A bare `connect` resolves to Guile's *socket* `connect`; the `<signal>` form (or
an explicit import) is required.

**`timeout-add` takes the priority first**: `(timeout-add PRIORITY INTERVAL PROC
[DATA [NOTIFY]])`, which is `g_timeout_add_full`'s shape — `(timeout-add 0 200
proc #f)`. A wrong guess reports only "no applicable method".

**The blocking read works — this was the plan's biggest risk, now retired.**
Pump `(main-iteration-do? #t)` until the event queue is non-empty, and implement
the deadline as a GLib timeout that pushes a sentinel event, so a bounded read is
woken by the loop rather than by a clock. Measured on a standalone prototype: a
blocking read returned an event due at 250ms after **253ms**; bounded reads of
200ms and 500ms returned `#f` after **203ms** and **506ms**. So deadlines are
honoured to within a few milliseconds, and a blocking read never returns `#f` —
which is exactly what `keyboard.sld:437` requires.

### The rendering pipeline, working and measured

Verified end to end: guile-cairo drew a frame, it became a pixbuf, it showed in a
real GTK window, and the frame was written to a PNG and inspected. Nothing needs
installing.

    (init-check!)                                   ; Gtk first, always
    ;; draw the frame with guile-cairo into a surface, then:
    (pixbuf:new-from-data (cairo-image-surface-get-data surf)
                          (symbol->colorspace 'rgb) #t 8 w h (* w 4))
    (image:new-from-pixbuf pb)                      ; -> GtkImage
    (container:add win img)                         ; -> window
    (widget:show-all win)

**The one thing that cost the most, and is easy to miss:**
`(push-duplicate-handler! 'merge-generics)` and
`(push-duplicate-handler! 'shrug-equals)` must be called (they come from
`(gi util)`). Without them, typelib GOOPS generics misresolve and every such call
fails with a wildly misleading `Too few "in" arguments (handling in)` — which
looks like an arity bug, reproduces on calls that are demonstrably correct, and
varies with which names happen to be imported. The retired backend did this
(`gtk3-init.sld:71-72`) and it was overlooked here.

Other specifics, each of which cost a wrong guess:

- **`pixbuf:new-from-data`** is
  `(data colorspace has-alpha bits width height rowstride [destroy-data destroy-fn])`.
  The colourspace must be a real `<GdkColorspace>` — `(symbol->colorspace 'rgb)`,
  not `'rgb` and not `0`, either of which fails dispatch.
- **`init-check!` must precede any widget.** Creating a widget first segfaults,
  with only `Gtk-CRITICAL` warnings as a clue.
- **`main-quit` does nothing here**, because `gtk_main` is never called — the
  driver pumps with `main-iteration-do?` itself. Exit must be driven by the
  driver (a repeating `timeout-add` that sets a flag works; a one-shot timeout
  does not, because after it fires a blocking iteration waits forever).
- **`GdkPixbuf` must be `require`d explicitly.** Gdk pulls in its *types*, so a
  survey looks complete while its functions are absent.
- **`container:add`** wants `<GtkContainer>`/`<GtkWidget>` reachable — a
  consequence of the duplicate-handler problem above, not a separate issue.

### Key translation, from Emacs's own GTK backend

Mirror `xg_widget_key_press_event_cb` (`gtkutil.c:6520-6613`) and
`pgtk_gtk_to_emacs_modifiers` (`pgtkterm.c:5157`); do **not** port the retired
in-repo translation, which has no named keys at all and mishandles Shift.

**Modifiers.** Shift -> `shift`; Control -> `ctrl`; **Meta or Mod1 -> `meta`**;
Super -> `super`; Hyper -> `hyper`. Note Mod1 maps to *meta*, not alt.

**The key.** Emacs's rule, which suits our interface exactly, since our events must
be a character or an integer:

- a keysym that yields a Unicode character — `gdk_keyval_to_unicode` non-zero —
  becomes a **character** event, and that is our event;
- anything else — the cursor keys, function keys, the keypad, the
  BackSpace..Escape range, Delete, dead keys, vendor-specific keysyms — becomes a
  keystroke event whose code is the **keysym integer**, which
  `key-event->keymap-path` decodes into a named key path (`("up")` and so on);
- keysyms in `0x01000000..0x0110FFFF` carry a Unicode character in their low 24
  bits and are taken as that character.

So the driver's `read-input-event` returns a char for text keys and a keysym
integer for the rest, and `key-event->keymap-path` owns the keysym -> name table.

## Verification

The terminal is the invariant, and it is a strong one.

- **Stages 1–2:** `python3 tools/run-suites.py` stays at **339 passed**
  (113 + 29 + 197), and `python3 tools/pty-check.py` stays at **27/28**
  (`kill-ring` is the pre-existing failure, confirmed to fail at committed HEAD).
  Because a terminal's pixel *is* its cell, any layout drift — splits, resize,
  scrolling, the echo area, continuation — must show up here. Treat a change in
  these numbers as a bug in the refactor, never as a new baseline.
- `guile -s tools/syntax-check.scm` on every file touched, a load check on each
  changed library, and `tools/check-exports.scm`.
- **Stage 3:** unit-test the parts that need no display — `key-event->keymap-path`
  (a pure function of a keyval plus modifiers) and `realize-face`'s integer
  interning (e.g. that plain maps to 0, the constraint `xdisp.sld:569` imposes).
  Follow `faces-tests.scm`'s headless `<test-display>` pattern.
- **Stage 3 end-to-end:** run it for real (`DISPLAY=:0` is available) and check
  the editor works: typing, mode line, echo area, `C-x C-f`, `C-x C-b`, isearch
  highlighting, a split, a resize. Capture a screenshot as the proof.

## Risks / open questions

- **`screen-size`'s sense flip** is the sharpest edge in Stage 1, because
  `frame.sld` derives every window rectangle from it. Check this first; it
  determines whether Stage 1 is as small as it looks.
- **Measurement performance.** Per-character measurement with Pango will need
  caching before it is usable on large buffers.
- **guile-gi name binding** — *de-risked, and this plan's original
  assumption was wrong*. See "The retired backend's guile-gi idiom is wrong"
  above: use `typelib->module` with an explicit module reference, expect
  GOOPS-style names rather than C ones, and keep the typelib out of any
  namespace shared with editor code.
- **GTK3, not GTK4.** `pgtkterm.c` is GTK3; both typelibs are installed, so pick
  `Gtk-3.0` deliberately.
- **Stage 2 is the largest piece** and touches the most-tested code. It may be
  worth stopping after Stage 1 and reassessing.

## Out of scope

Wrapping and horizontal scrolling; proportional-font *modes* (the interface will
allow them, the Lisp will not exist yet); images and other non-character glyphs;
toolbars and menus; and the retired div-tree UI framework, which stays retired.

## The alternative, recorded

Keep the cell grid and accept a monospace GTK window. Cheaper, purely additive,
and it would prove the seam admits a second backend — but it enshrines the
deviation and looks like a terminal in a window. Rejected because Emacs puts the
pixel at the bottom, so the cell-based interface is the thing to fix.


## Where this stands (2026-09-30, end of session) and what is next

### It works

The backend renders correctly, resizes correctly, and is correct under Hyprland's
fractional monitor scaling. `schemacs/editor/pgtk.sld` now draws into a
`GtkDrawingArea`: Gtk asks for a repaint, we paint our own drawing into the
context it hands us, and Gtk owns the buffer, the size and the scale. **No core
file changed.**

### The conclusion that matters

**The pixbuf/`GtkImage` handoff was the fault all along**, exactly as the plan
said, and every symptom of the evening — stretching, clipping, the vanishing mode
line, the redraw loop — was that workaround's own invariant: a pixbuf must match
the widget at every instant, through every resize, at every scale.

Worse: **the workaround was unnecessary.** guile-cairo has had the bridge since
commit `5cb9691` (2023-03-10, David Pirotte) — `cairo-pointer->context` wraps the
pointer inside guile-gi's `<CairoContext>` (its `value` slot) as a guile-cairo
context, after which all of cairo is usable. **It has never been in a release**:
the newest tag is v1.11.2, which predates it, so everybody on the packaged version
is missing it. Hence the rule that cost this evening: **before building around a
gap, check the library's own source — not the installed module's exported names.**

### How to run it

    ./se GTK-PLAN.md         # or any file; *scratch* if none

`se` puts `.guile-cairo/share/guile/site/3.0` **first** on the load path. That
directory is a *built copy* of the newer guile-cairo, not committed. It used to
fall back to the system guile-cairo silently and die with an unbound
`cairo-pointer->context` at the first repaint — three frames away from the cause;
`se` now imports `(cairo)` from exactly that path before starting, and refuses to
start with a message naming the directory if the bridge is not there. (The probe
costs 25 ms.)

### Owed cleanup in `pgtk.sld` — DONE (2026-09-30)

Five `pgtk-trace` calls and `pgtk-now-ms`'s trace file, the `pgtk-shot-maybe!`
hook (dead: it referenced two parameters that were never defined, and nothing
called it), the `scale`/`pgtk-scale` slot, `pgtk-buffer`, `pgtk-surface-size`, and
the imports they alone used (`open-file`, `call-with-port`, `getenv`,
`force-output`, `resolve-module`, `image:pixel-size`, `symbol->colorspace`,
`widget:get-scale-factor`). The `image` slot is renamed `area` — it has been a
`GtkDrawingArea` since the pixbuf was retired, and the comments around it still
spoke of a pixbuf and a stretched GtkImage.

### 1. Region and colour — DONE (2026-09-30)

**The region was being drawn. It was being drawn the wrong colour.** The fault was
one word in `initialize-pgtk-faces!`, and it was not where the plan looked.

`schemacs/editor/pgtk.sld` told the face machinery `(*display-type* 'pgtk)`. But
`display-type` is not the window system's name — it is a *frame parameter* whose
value is `color`, `grayscale` or `mono`, and `pgtkfns.c:2781` is explicit about it:

```c
    disptype = Qcolor;
```

It is what a spec's `(class color)` conjunct is tested against
(`faces.el:1592`, `(memq (frame-parameter frame 'display-type) options)`). So with
`'pgtk` there, **every `(class color)` branch of every standard face failed**, and
the specs fell through to their last-resort branches:

- `region` took `(#t :background "gray" :extend #t)`. `gray` is `#bfbfbf` — on a
  white background that is a highlight you have to look for. It reads as "the
  region is not drawn", which is exactly what it was reported as. The branch it
  should take — `((class color) (min-colors 88) (background light))` — is
  `lightgoldenrod2`, a colour you cannot miss.
- `mode-line` "worked" only by accident: it took `(#t :inverse-video #t)` and
  happened to look right. It now takes its real branch, `grey75` on black.

and `(*window-system*)` was left `#f`, which is *a terminal*. Every `(type tty)`
branch therefore matched on a graphical frame — `header-line` came out underlined
and in positive video rather than `grey90`/`grey20`.

Both are now what the pgtk backend sets: `window-system` is `pgtk` (as `xfns.c`
sets `x`) and `display-type` is `color`.

**How it was found, and how it is now tested.** Not by reading the face table —
the table was right; the *branch chosen from it* was wrong. It was found by
rendering a frame and reading the pixels, so that is what
`schemacs/editor/pgtk-tests.scm` does: it builds a `<pgtk-display>` with no window,
lets `initialize-pgtk-faces!` set it up exactly as opening one does, renders
`"hello world"` with the region `[2,5)` through the real `render!`, writes the
surface to a PNG, reads it back and samples the background under the glyphs.
Reverting the one word fails three of those checks with `(190 190 190)` where
`(238 220 130)` was expected. The suite also covers `key-event->keymap-path`
(including that a named key's path element is a *string* — `'(ctrl left)` and
`(list 'ctrl "left")` print identically and are not `equal?`) and the integer
interning `xdisp.sld:569` requires.

`initialize-pgtk-faces!` is exported for this, as the one thing a test needs to
set a display up the way opening one does; `term.sld`'s counterpart stays private
for the same reason.

**The count.** `tools/run-suites.py` is now **361 passed** (113 + 29 + 22 + 197) —
the 339 of stages 1–2 plus the 22 here. That is a new suite, not drift; the
terminal invariant for those numbers is otherwise unchanged, and the pty battery
is still **27/28** with `kill-ring` the known failure.

#### And a third: C-SPC was never bound, so the mark could not be set at all

The plan's first candidate was "*the region is never active*, so xdisp never asks
for the region token". It was half right, and the half it was wrong about is the
one that mattered to Chris, who reported after all of the above that the region
*still* did not work while the completion colours did.

`schemacs/editor/simple.sld` bound `set-mark-command` to `C-@` and nothing else,
with a comment saying "C-SPC and C-@ are the *same* key event on a terminal".
True - **on a terminal**, which sends the NUL byte for either key. A GTK window
does not: C-SPC arrives as a `space` keysym with the control modifier and C-@ as
an `at` keysym, two different events, so on GTK the binding never fired and
pressing C-SPC did nothing whatever. Emacs binds both, in `bindings.el`:

```elisp
(define-key global-map "\C-@" 'set-mark-command)
(define-key global-map [?\C- ] 'set-mark-command)
(put 'set-mark-command :advertised-binding [?\C- ])
```

and folds a terminal's byte the *other* way, with
`(define-key function-key-map [?\C-@] [?\C-\s])`, calling C-SPC the canonical
one. Both are bound now. The fix is in the *keymap* - the core, shared by both
front ends, which is where Emacs puts it - and not in either backend: a terminal
still sends NUL and still reaches `C-@`, so nothing about the terminal changed,
which the unchanged pty battery confirms.

**Why my own GTK screenshots had "proved" the region worked:** they were driven
with `wtype -M ctrl -k at`, which is C-@. That is the key the binding had. See
AGENTS.md's "Driving a running editor" for what replaced that method, and why.

### 2. Wide characters — DONE (2026-09-30)

The item was written as "cursor over wide characters — it is a solid block, so it
will be wrong on a double-width character". **The premise was wrong**: wide
characters were not modelled at all, and the cursor was the least of it.

`schemacs/editor/disp-table.sld` drew every ordinary character as `(string c)` and
advanced the display column by `(string-length glyph)`. So a CJK ideograph — one
character, **two** columns — counted as one cell, and so did every loop built on
it. Emacs's answers, from `emacs -Q --batch`:

    (char-width ?中) => 2     (char-width ?\t) => 8     (char-width ?\n) => 0
    (char-width #x301) => 0   (char-width ?a) => 1      (char-width 1) => 2

Nothing *looks* wrong: the text is drawn correctly, because the terminal and the
font both know the real width. What is wrong is every **position** after a wide
character — the cursor, the region fill, the search highlight, the mode line's
column, the continuation glyph — each one cell out per wide character. That is why
it went unnoticed for so long and why the unit suites could not see it.

**What was added**, in Emacs's own file layout:

- **`schemacs/editor/characters.sld`** — `lisp/international/characters.el`'s
  `char-width-table`: 295 zero-width ranges and 133 double-width ones. It is
  **generated** by `tools/gen-char-width-table.py`, not transcribed — a table that
  large is exactly the kind that is plausible and wrong, and the generator can be
  re-run against a newer Emacs.
- **`schemacs/editor/character.sld`** — `src/character.c`'s `char-width`, branch
  for branch as `CHARACTER_WIDTH` (`buffer.h`) writes it, plus
  `sanitize-char-width` and the table's default of 1. Checked against
  `emacs -Q --batch` over a 424-code-point sample: **no mismatches**.
- **`disp-table.sld`** — the distinction the whole thing turns on:
  `char-display-width` is how many cells a glyph takes (its *length* is not its
  width), `char-display-cursor-width` is the width of its *first* glyph, and
  `expand-line-glyphs` is the line as one glyph per character — because a face run
  is a range of *characters* and `substring` indexes a *string*.
- **`xdisp.sld`** — the run walk and the search-match walk cut the line by
  character and place it by column; `line-display-width` and `display-column-of`
  measure instead of counting; and `%c`/`%C` are screen columns, which is what
  Emacs's `(current-column)` is.
- **`draw-window-cursor!` gains the width** — the cursor sits on the glyph at
  point, so it is two cells over a wide character. The terminal ignores it (its
  cursor is the terminal's own, and a terminal draws a wide cursor itself); pgtk
  draws a block that many cells wide.
- **`pgtk.sld`** — `write-glyphs!` now places each *cluster* at its own cell
  column rather than handing the whole run to `cairo-show-text`, whose advance is
  the font's, not ours; and the run's background is measured in cells. A cluster is
  a character plus the zero-width characters after it, so a combining accent lands
  on its letter.

`*tab-width*` moved from `disp-table.sld` to `character.sld`, because
`CHARACTER_WIDTH` reads it and `char-width` of a tab is `tab-width`. There is
exactly one; the import graph is what chooses its home (`buffer.sld` is downstream
of `disp-table.sld`, so `buffer.c`'s own home for it is unreachable).

**Verified the way the plan asks** — each check seen to fail with its fix reverted:

- `character-tests.scm` (**33**) — the table, `sanitize-char-width`, and the
  width-aware arithmetic, with every expected number taken from `emacs --batch`.
- `pgtk-tests.scm`'s wide-character case: the region over `"x中y"` is **four**
  cells, and reverting the one expression to `string-length` leaves the fourth
  white (`255 255 255` where `238 220 130` was expected).
- a new pty check **`wide-columns`**: after a wide character the mode line reads
  `L1 C3`, and reverting makes it `L1 C2`.

**The count.** `tools/run-suites.py` is now **403 passed** (33 + 113 + 29 + 31 +
197), and the pty battery is **28/29** — the 27/28 above plus `wide-columns`, with
`kill-ring` still the one failure.

**The battery is timing-sensitive, and a single run is not evidence.** Run under
load it will fail a check that passes alone: `split` failed once with "the mode
line is not on the screen at all" while a unit suite and a second editor were
running, and passes on its own. Re-run a failure on a quiet machine before
believing it - either direction. (`kill-ring` is the opposite case: it fails
alone and has failed since before this work.)

**Still counting characters, and named rather than changed**, because each is a
narrower case than the ones above and none of them is what the item was about:

- `truncate-line` / `pad-line` (`xdisp.sld`) and the `%N<spec>` field padding in
  `pad-mode-line-field` cut and pad by `string-length`. Emacs measures a
  mode-line element's precision in *columns* (`display_mode_element` decrements
  it by each glyph's `pixel_width`), so a buffer name holding a wide character
  pads one cell per wide character out. Nothing in this tree has such a name
  yet, and the fix is the same measurement applied one layer up.
- `char-display-glyph` still draws a **newline** as the two-cell `^J`, where
  Emacs's `CHARACTER_WIDTH` gives a newline width 0 - it ends a line rather than
  occupying a cell. It cannot arise today, because a line is drawn without its
  line break, but it is a trap for whoever draws one.
- The **display table** (`buffer-display-table`) and **`ctl-arrow`** do not
  exist here, so `char-width` is `CHARACTER_WIDTH` with `ctl-arrow` non-nil and
  no display table to apply. Both are named at their definitions.
- **`pgtk.sld` draws text with cairo's *toy* API** (`cairo-select-font-face` +
  `cairo-show-text`), which does no font fallback: a character the monospace
  font does not have is drawn as tofu. Seen in the end-to-end check - a CJK
  character renders as a box with a question mark in it, *at the right place and
  the right width*, which is why the positioning tests pass while the glyph is
  wrong. Emacs's `pgtkterm.c` lays text out with **Pango**
  (`pango_layout_set_attributes`, `pango_cairo_show_layout`), and guile-gi does
  bind `PangoCairo`'s `show-layout` - but guile-cairo has no `cairo_t` from a
  Pango layout here, so this wants the same pointer bridge the draw signal
  needed. It is the natural first piece of Stage 2's "real fonts".

### 3. The cursor — mostly DONE (2026-09-30)

Chris's ask: "a proper cursor instead of a black box". The shape was not the
fault - Emacs's default `cursor-type` *is* a filled box. The fault was that ours
**covered** the character instead of **inverting** it. `xterm.c:26066`:

```c
case FILLED_BOX_CURSOR:
  draw_phys_cursor_glyph (w, glyph_row, DRAW_CURSOR);
```

and the file header says why: a temporary GC is built so "the cursor can be
distinguished from its surroundings and that **the text inside the cursor stays
visible**". Ours painted a solid black rectangle over the cell, which is why the
character under point vanished. On a terminal this never showed, because ncurses'
hardware cursor inverts by itself - a GTK-side defect in `draw-window-cursor!`.

**Ported, and where Emacs has it:**

- `cursor-type` — buffer-local (`buffer.c:5893`), with the whole value grammar
  (`t`, nil, `box`, `hollow`, `bar`, `hbar`, `(bar . W)`, `(hbar . H)`, anything
  else -> hollow box) — `buffer.sld`.
- `cursor-in-non-selected-windows` — buffer-local (`buffer.c:5927`) — and the
  rule it drives: a non-selected window turns a filled box *hollow* and a bar one
  pixel narrower.
- `get-specified-cursor-type` and `get-window-cursor-type` — `xdisp.c:34726` and
  `:34813` — `xdisp.sld`. Including the surprising one: the C sets the width from
  the cdr *before* it looks at the car, so `(hollow . 5)` is a hollow box five
  wide. That is Emacs, not a slip, and there is a test for it.
- `internal-show-cursor` / `internal-show-cursor-p` and the `cursor_off_p` flag
  they write (`dispnew.c:7428`) — the state blinking needs. The functions are in
  `window.sld` and not `dispnew.sld` because of the import graph: they set a
  field of a *window*, and `frame.sld` imports `dispnew.sld`, so the other
  direction is a cycle. The flag is kept beside the window in a weak table, as
  `buffer.sld` keeps its slots, so adding it does not change a record every
  library makes windows with.
- The frame's cursor (`desired_cursor` / `cursor_width`, set by
  `x_set_cursor_type` from the frame's `cursor-type` parameter) — a parameter
  `*frame-cursor-type*` in `frame.sld`, since this tree has no frame parameters.

**The interface grew again**, and for the same reason as the width: to invert a
glyph a display needs the glyph. `draw-window-cursor!` is now
`(display row column cells type width text token)` — CELLS is the glyph's width,
WIDTH is the cursor's own (a bar's thickness), and TEXT and TOKEN are what is
under it. A terminal ignores everything but the position and `no-cursor`.

**pgtk** draws all five: filled (box + the glyph in the frame's background -
`x_set_cursor_color`'s pair, black on this frame's white), hollow (outline), bar
(a 2-pixel strip, as Emacs's default is *pixels*), hbar (a strip at the cell's
foot) and none. Verified in the *live* editor through the REPL back door, by
pixels: a white `M` on a black box where a solid block used to be, and the other
four sampled at their edges.

**Two pieces are named rather than done:**

- **Blinking.** `blink-cursor-mode` (`frame.el`) needs `run-with-timer`,
  `run-with-idle-timer` and `cancel-timer` (`timer.el`, plus `timer_check` in the
  command loop), `pre-command-hook` (which `blink-cursor-start` installs
  `blink-cursor-end` into), and a minor mode to be. **None of the three exists
  in this tree** - `frame.sld` says so in as many words, and the message timeout
  is a hand-rolled stand-in for the timer it needs. The *state* is done
  (`internal-show-cursor` and `cursor_off_p`); only the clock is missing. This is
  a port of `timer.el` plus a hook plus a mode, and it is the next piece.
- **Cursors in non-selected windows.** The *type* rule is in place, but the
  renderer still places one cursor - the selected window's, plus the echo area's.
  Doing the rest needs the cursor's position to be *window*-aware: everything in
  `xdisp.sld` that finds it (`cursor-screen-position`, `cursor-glyph`) reads
  `text-editor-cursor-line`/`-column` of the buffer, which is the buffer's own
  point and so only right for the selected window. `text-editor-get-line-column`
  against `window-point` is the way in, and then the renderer draws a cursor per
  window - which a terminal must not do, it having one cursor, so the interface
  will need to say which displays draw their own.

**The count.** `tools/run-suites.py` is now **419 passed** (33 + 113 + 29 + 31 +
213) - the 16 new ones being the cursor-type rules in
`ncurses-editor-tests.scm`.

### 4. Timers, and the blinking cursor — DONE (2026-10-01)

Blinking needed three subsystems this tree did not have. Rather than fake one,
they were ported:

- **`schemacs/editor/timer.sld`** — `emacs-lisp/timer.el`'s `run-at-time`,
  `run-with-timer`, `run-with-idle-timer`, `cancel-timer` and `timerp`. A timer
  is data in a list, not a thread and not a signal: the *command loop's* read is
  what makes "later" arrive, by asking how long it may sleep
  (`read-timeout-or`) and running what is due when it wakes. That is Emacs's
  shape - its `read_char` computes its wait from `timer_check` - and it is why a
  timer fires while the editor sits still.
- **`timer_check` is `keyboard.c`'s and lives in `keyboard.sld`**, as
  `timer-check!` and `timer-next-delay`. It was written in `timer.sld` first,
  because the timer lists were private variables there and the walk has to
  reschedule them - which is a fact about how it was written, not a reason.
  Emacs's `timer-list` and `timer-idle-list` are *public* variables that any C
  file reads and writes, so they are parameters here and the check sits where
  Emacs has it. (`timer-check!` answers whether anything ran rather than the
  time of the next timer, because this editor's redisplay is the command loop's
  and so it has to be told to draw again; that difference is named at the
  definition.)
- **`*pre-command-hook*`** — `keyboard.c`'s, run by `dispatch-action` after
  `this-command` is set, as `command_loop_1` runs it. The variable lives in
  `frame.sld` because the blink writes it and `keyboard.sld` reads it, and
  `keyboard.sld` already imports `frame.sld` - the same import-graph reason as
  `internal-show-cursor`.
- **`blink-cursor-mode`** and the rest of `frame.el`'s blink code -
  `blink-cursor-start`, `blink-cursor-timer-function`, `blink-cursor-end`,
  `blink-cursor-suspend`, `blink-cursor-check`, `blink-cursor--should-blink`,
  `blink-cursor--rescan-frames`, and the two timers. `define-minor-mode` does not
  exist here, so the mode is a command that toggles a variable, as
  `read-only-mode` is; what that costs is named at its definition.

**Two of `pgtk.sld`'s own bugs came out of trying to watch it, and both are worth
more than the blinking:**

- **The read's deadline was a clock it watched, not a GLib timeout** — so a
  timed read called `main-iteration-do?` in its non-blocking form and went round
  until the time was up. That is a **busy-wait**, and it burned 43-57% of a
  processor for the length of every timed read. The plan said the deadline was
  "a GLib timeout pushing a sentinel event (not a clock)" and the `'pgtk-deadline`
  sentinel was *handled* in the read loop - but nothing ever enqueued it. It does
  now, and the wait blocks. **Idle CPU went from 43% to 0.5%**, and Chris's
  report of the editor being "totally frozen" was this.
- **`timeout-add`'s callback is called with its data argument**, so the
  zero-argument lambda there raised *every time the timeout fired*. The sentinel
  was therefore never enqueued, the read blocked for ever, no timer ever ran, and
  the cursor never blinked. This is why "it doesn't blink" and "the REPL never
  answers" were the same bug: both need the read to wake up.

  The lesson is the one from `internal-show-cursor`: **an exception inside a
  `catch` that returns `#f` is invisible.** Both of these were caught by
  `(catch #t ... (lambda args #f))` around `main-iteration-do?` and read as
  ordinary timeouts.

**Focus** (Chris: "with real emacs it only blinks when the window has focus",
and then "if it loses focus when the cursor is unblinked the cursor is
invisible. What should happen is when it loses focus the cursor is reverse").
Both are Emacs's, and `get_window_cursor_type` is why the second one works: its
`non_selected` branch - taken for a window that is not selected *or* a frame that
is not the display's highlight frame - **returns before the `cursor_off_p`
check**, so a blinked-off cursor in an unfocused frame is still drawn, as a
hollow box. Ours does the same now:

- `*frame-focus*` (Emacs's `frame-focus-state`), set by `pgtk.sld` from Gtk's
  `focus-in-event`/`focus-out-event`;
- `blink-cursor--should-blink` requires a focused graphical frame, and
  `blink-cursor--rescan-frames` suspends the blink when the focus goes;
- `get-window-cursor-type` treats an unfocused frame as non-selected;
- and a new **`*redraw-code*`** (beside `*resize-code*`) is what the focus
  handlers enqueue, because the editor is sitting still and nothing else would
  ask for the redisplay that shows the new shape. The focus handlers also ignore
  a focus change while the window is being destroyed - the teardown takes the
  focus away, and acting on it there took the editor down.

**The development REPL got a cap.** With the read now *blocking*, `poll-repl!`
would only run when some other event woke the loop, so the back door hung. The
command loop caps its read at 100 ms **only when the door is open**
(`repl-open?`), so a session that has opened it answers promptly and a normal run
is not slowed at all.

**Still not done:** cursors in non-selected windows (the rule is in, the renderer
still places one), and `blink-cursor-blinks`' post-command re-arm is approximated
by the next idle period rather than by a `post-command-hook`.

**The count.** `tools/run-suites.py` is now **439 passed** (33 + 113 + 29 + 31 +
20 + 213) and the pty battery is still **28/29**.

### 5. Long lines: the continuation marker, and what wrapping is not (2026-10-01)

Chris: "the continuation marker \ appears, but it doesn't wrap anymore. And in
gtk the continuation marker overwrites a letter as well."

**The overlap was a real bug, and its cause is general.** A *terminal* replaces a
cell when you write to it - a cell holds one character and one set of attributes
- and `pgtk.sld`'s `write-glyphs!` **painted over** instead. So the continuation
glyph landed on top of the last character of the line, and what you saw was a
mangled letter rather than a marker. The terminal showed a clean `\` all along,
which is why it read as a GTK-only symptom. Every caller of `write-glyphs!`
already assumed replacement, so it now fills the run's cells first - the face's
own background, or the display's when the face names none. **A written cell shows
only what was written.**

**Wrapping, though, was never there, and that was checked rather than assumed.**
Chris thought it used to work; it did not, in this tree:

- no commit ever added or removed `wrap-line`, `continuation-line`, `word-wrap`,
  `line-wrap` or `visual-line` (`git log --all -S`);
- the *oldest* ncurses editor in the history (`fb6436b`, which added
  `apps/ncurses-editor.sld`) contains the string `wrap` zero times;
- the commits matching `truncate` are all `truncate-line`, which is the mode
  line's and the echo area's string truncation, not line wrapping;
- and the long-line probe gives byte-identical output at the commit from before
  the cursor and blink work as it does now (79 `X` and a `\`).

So the editor has always truncated, and `\` is Emacs's *truncation* marker. The
deviation is against Emacs's **default**: `truncate-lines` is nil, so Emacs wraps
a long line onto continuation rows, and `\` is what it draws when truncation is
turned on. This tree has no `truncate-lines` at all.

**That makes continuation lines a feature, not a repair** - which is good news,
but it is not small: the renderer's central assumption is that **one screen row
is one buffer line** (`render-window!` walks rows with `buffer-line-string` per
row). Continuation rows break that, and it reaches `scroll-to-cursor!`,
`window-top-line`, the mode line's row arithmetic, `%c` (a continuation row
starts part-way into a line), and the pty battery's `continuation` check, which
currently *asserts* the `\` and so encodes truncation. Emacs's own knobs are
`truncate-lines`, `truncate-partial-width-windows` (50 by default, so a narrow
split window truncates even when wrapping is on) and `word-wrap`.

### 6. Two bugs from using it: the one-key question, and the window manager (2026-10-01)

Chris: "the `Save file` prompt does not accept input. Hitting `n` does nothing."
and "quiting the window from the window manager doesn't exit the program. I
presume real emacs has some logic along the lines of when the last frame is
closed to exit."

**The prompt: `read-char-from-minibuffer' assumed a character.** It read a key
and branched on `(char? ev)` - which is true for a *terminal*, whose
`read-input-event` hands back the character a key is. A window system hands back
an *integer* to be decoded, so `(char? ev)` was false for every key and the
question asked again for ever: hitting `n` did nothing. The fix is the
translation the command loop already uses - `key-event->keymap-path`, which is
what `read-key` goes through in Emacs - and one path handles both front ends:
C-g abandons, a one-character path answers, anything else asks again.

**The window manager: `handle-delete-frame'** (`frame.el:265`), which Chris
presumed - "real emacs has some logic along the lines of when the last frame is
closed to exit". It is exactly that:

```elisp
(defun handle-delete-frame (event)
  (let* ((frame (posn-window (event-start event))))
    (if (catch 'other-frame (dolist (frame-1 (frame-list)) ...))
        (delete-frame frame t)
      ;; Gildea@x.org says it is ok to ask questions before terminating.
      (save-buffers-kill-emacs))))
```

and the X side is `delete_event' (`pgtkterm.c:5683'), which queues
`DELETE_WINDOW_EVENT` and `return TRUE` - Gtk is told *not* to destroy the
window, and whether to save and exit is the command loop's decision. Ported as
`handle-delete-frame' in `files.sld' (it hands off to
`save-buffers-kill-terminal', which is there, and which *does* exit - verified)
bound to the path `"delete-frame"`, which `pgtk.sld' emits from Gtk's
`delete-event' signal.

**Two more of `pgtk.sld`'s own bugs came out of the same work:**

- **The read's deadline source was removed twice.** A GLib timeout whose
  callback answers `#f` removes itself; removing it again in the read's
  `dynamic-wind` after-thunk is the GLib-CRITICAL "Source ID ... was not found"
  the terminal was filling with, once a blink. The callback now answers `#t`
  and the after-thunk does the removing.
- and the paren damage the fixes left behind is the reason
  `tools/syntax-check.scm` exists, and the reason a form is written to a file
  and *checked alone* before it is spliced: `pgtk-read-event' was rewritten
  three times because the splices kept shifting the close that
  `with-gtk-display''s tail needed.

### 7. The key vocabulary, and `kbd` (2026-10-01)

Chris: "C-/ and C-_ don't work in gtk. Did we lose a lot of bindings somehow in
gtk?" and then "what do you mean `mirroring bindings`? That sounds worrying.
What happens when the user starts to bind these keys to things, is our strategy
going to work? Are we using emacs' strategy?" and "OK go fix the key tables to
be like emacs".

**Nothing was lost, and the four bindings are Emacs's own** -
`bindings.el:1234-1248`:

```elisp
(define-key ctl-x-map "u" 'undo)
(define-key global-map [?\C-/] 'undo)      ; a keysym
(define-key global-map "\C-_" 'undo)       ; a byte
(define-key global-map '[(control ??)] 'undo-redo)
(define-key global-map [?\C-\M-_] 'undo-redo)
```

- **What the bug was.** The undo binding was written as the *byte* spelling -
  `(ctrl (integer->char 31))` - and its comment said "C-/ and C-_ are the same
  byte (31) in a terminal, so one binding serves both". True in a terminal and
  false in a window system, which sends two different keysyms; so C-/ and C-_
  were dead there. The same sentence was over the C-@ binding, and the same
  sentence is the one this tree has been writing per binding - which is why the
  question "is our strategy going to work?" has the answer it does.

- **What `mirroring bindings` should have said**, and why it sounded worrying:
  the four bindings above are Emacs's, and ours now are too. But that is a patch
  per key, and the thing it patches is real.

- **The gap, named.** There was no `kbd`. Emacs's `kbd` (`subr.el:1258`,
  `key-parse` in `keymap.el:235`) is how a user writes a key: `(kbd "C-/")`,
  `(kbd "C-x C-f")`. It is the one place the key vocabulary is written down, and
  every binding ends up in the same representation. Without it the only way to
  write a binding here was a raw path list, and the path each *front end*
  produces for a key is not the same - so a user binding written against one
  front end's spelling matched only that front end. **That is the answer to "is
  our strategy going to work?": it was not, because there was no way to name a
  key at all.**

**`kbd` is now in `subr.sld'**, where Emacs's is, porting `key-parse`'s core: the
`C-`/`M-`/`A-`/`H-`/`S-` prefixes, the `^X` form, the named keys (`SPC`, `RET`,
`TAB`, `ESC`, `DEL`, `NUL`, `LFD`), and `<...>` for a keyboard key. The result is
this tree's key path - a list of keys, each a character, a string naming a
keyboard key, or the chord's modifier symbols followed by the character or
string - so `(kbd "C-x C-f")` is `((ctrl #\x) (ctrl #\f))` and `(kbd "C-/")` is
`((ctrl #\/))`. `define-key' takes it, so

```scheme
    (define-key *default-keymap* (kbd "C-/") undo)
```

is `(define-key global-map [?\C-/] 'undo)` written the Emacs way.

**And the byte spelling stays**, because it is not redundant: `kbd "C-_"' names
the *keysym*, and a terminal's byte 31 is a different key that only the byte
spelling reaches. Emacs has the two for exactly that reason, and the first
version of this change left the byte one out - which broke the terminal's undo,
and the pty battery caught it (`undefined key: (ctrl #\us)`).

**What is still missing, and is the thing to do next**: the bindings are written
with `kbd` one at a time as they are touched; they are not all converted, so a
user reading `simple.sld' sees both spellings. And `key-translation-map' /
`function-key-map' - Emacs's way of saying "this key *is* that key" rather than
binding both - does not exist here, which is why C-@ and C-SPC need two bindings
where Emacs's has the translation.

**The count.** `tools/run-suites.py` is **459 passed** (33 + 113 + 29 + 31 + 24 +
229) and the pty battery is still **28/29**.

### 8. The window system's events, and `(interactive "e")` (2026-10-01)

Chris: "why do I see a lot of code with cond and keys as if you are special
casing keys? Sounds like some kind of disgusting hack youve hatched", "Is this
code in emacs?", and "why do I keep having to tell you the same thing over and
over. Stop hacking around stupid ideas and just do what emacs does... period".

**No, that code is not in Emacs, and it was a hack I hatched.** The dispatch had

```scheme
    ((and path (memq (car path) '(resize redraw)))
     (set!frame-message frame "")
     (*esc-pending* #f))
```

- a `cond' arm per window-system event, each one a key that cannot be rebound
  and does not go through the keymap at all. And the same shape was in
  `pgtk.sld''s read loop, which turned an *integer code* into a path before
  the lookup ever saw it.

**What Emacs does** (`keyboard.c`) is the thing to copy, and it is three steps:

- the window system's event arrives and `make_lispy_event' turns it into a
  *key event* - `(delete-frame (FRAME))` (`keyboard.c:6238`),
  `(focus-in (FRAME))` and `(focus-out (FRAME))` (`keyboard.c:6281`) - which
  is an ordinary key, not a special case;
- `special-event-map' (`keyboard.c:14153') is consulted *before* the ordinary
  lookup (`keyboard.c:3113') and binds those named keys to their handlers -
  `delete-frame' to `handle-delete-frame' (`keyboard.c:14550') and
  `focus-in'/`focus-out' to theirs (`keyboard.c:14620');
- the handlers are the commands `frame.el' owns (`frame.el:353' and `:369'),
  and a user can rebind them like any key.

**Ours now does the same**: `*special-event-map*' is in `keymap.sld' - beside
`*default-keymap*', which Emacs also creates in `keymap.c' and which this tree
put in the leaf for the same reason (the libraries that own the commands bind
into it, and they cannot import the command loop). `lookup-keymaps' consults it
first, the named keys are bound where their commands are, and the hack `cond'
arm is gone.

Two things the porting surfaced, and both were fixed:

- **`read-input-event''s answer is an integer and must be *decoded* into the
  path**, and the decode had been emitting `(resize)' - a bare symbol, which
  `keymap-index' reads as a *modifier* and rejects with "unknown keymap-index
  modifier symbol". A named key is a *string* in a key path - the arrows are
  `(list "up")' - so the events name themselves that way.
- **`(interactive "e")'** - Emacs's way of handing the command its event -
  was not ported, so the handlers were written to take nothing and the
  dispatch called them without one: the echo area said "Wrong number of
  arguments to handle-focus-out". `*this-event*' is in `command.sld', beside
  `current-prefix-arg' - both are `callint.c''s - and `interactive-proc''s
  `"e"' case hands the command it. `dispatch-input-event' binds it: a
  window-system event is built as Emacs's, its name and the frame it is for
  (`keyboard.c:6238' and `:6281'), and an ordinary key's event is the key
  itself. The commands take the event and read the frame from it -
  `(car (list-ref event 1))' - the way Emacs's reads it from `(nth 1 event)'.

**Verified live**: focus-in, focus-out, resize and delete-frame dispatched
through the real key path, the frame read from the event, and the editor
exiting on the close. **The count.** `tools/run-suites.py` is **459 passed**
and the pty battery is still **28/29**.

### 9. The command-name audit (2026-10-01)

Chris: "for some reason we have M-x scroll-down-command when it should be just
M-x scroll-down. Do an audit of every command ending in `-command`, they
probably are all misnamed."

**The audit checked every command name in the tree against Emacs 31** -
`(fboundp sym)` and `(commandp sym)` for the full list, 63 names:

- **61 are Emacs's own.** Everything except the two below is a command Emacs
  has, including `scroll-down-command' and `scroll-up-command', which
  `window.el:10953' and `:11007' define and `bindings.el:1404-1405' bind to
  `[prior]' and `[next]'.
- **`insert-newline'** is not Emacs's: Emacs's `newline' is the name, and it
  clashes with `(scheme base)''s output procedure - named at the definition,
  and the reason is unchanged.
- **`self-insert-tab'** is not Emacs's: Emacs's TAB is
  `self-insert-command' (`bindings.el' binds `"\t"' to it). It exists here
  because `self-insert-command' is the one legacy record left from the
  `define-command' conversion, which cannot say which character to insert -
  the note at its definition. With that record converted, the TAB binding
  becomes `self-insert-command' and `self-insert-tab' goes.

**And the scroll commands were swapped, which is what Chris saw.** Emacs's
`scroll-up-command' (`window.el:10953') is "Scroll text of selected window
upward" - the text moves up, which is toward the *end* of the buffer - and
`scroll-down-command' (`:11007') is downward, toward the beginning. Emacs binds
C-v to the first and M-v to the second. This tree had the *names* the other way
round from the behaviour: the command bound to C-v - which scrolls toward the
end - was named `scroll-down-command', so M-x offered the name Emacs gives the
*other* key. The names are swapped to match, and the bindings follow Emacs's
keys: C-v → `scroll-up-command' and M-v → `scroll-down-command'.

**The count.** `tools/run-suites.py` is **459 passed** and the pty battery is
still **28/29**.

### 10. The scroll amount (2026-10-01)

Chris: "the number of lines that scroll up or down does seems wrong. Of course
it is dynamically affected by window size .. or it should be anyway... more
lines for bigger windows. Audit the algorithm against real emacs", and "it
could be related to line wrap, who knows".

**The audit is `scroll_command' (`window.c:6975') and
`window_scroll_line_based' (`window.c:6153'), and the amount is not one rule
but two, because Emacs distinguishes the two ways the command is called:**

```c
  if (NILP (n))
    window_scroll (window, direction, true, false);      /* whole = true  */
  else if (EQ (n, Qminus))
    window_scroll (window, -direction, true, false);     /* whole = true  */
  else
    {
      n = Fprefix_numeric_value (n);
      window_scroll (window, XFIXNUM (n) * direction, false, false);  /* false */
    }
```

and `window_scroll_line_based' multiplies only when `whole' is true:

```c
  int ht = window_internal_height (w);
  ...
  if (whole)
    {
      int nscls = sanitize_next_screen_context_lines ();
      n *= max (1, ht - nscls);
    }
```

So:

- **with no prefix**, the near-full-screen amount - and
  `window_scroll_line_based' multiplies it out from the window's height: `n
  *= max (1, ht - nscls)', where `ht' is `window_internal_height' - the
  window's height less its mode line (and header and tab lines), which is
  `window-body-height' here - and `nscls' is `next-screen-context-lines'.
  **The amount is the window's height less two, and grows with the window.**
  (`window.c:9302' declares `next-screen-context-lines' as a DEFVAR_INT
  defaulting to 2, not 5.)
- **with a numeric prefix**, `whole' is false and the multiplication is not
  done: the command scrolls exactly that many lines.

**Our tree multiplied in both cases** - `(n (* count (max 1 (- vheight 2))))'
with `(interactive "p")', whose count is 1 when no prefix was typed - so
`C-u 3 M-v' scrolled three *screenfuls* where Emacs scrolls three *lines*.

**Fixed**: the commands now take `(interactive "P")' - the raw prefix, which
is nil when none was typed, `-' for a bare `M--', and the number otherwise -
and `scroll-amount' answers the number of lines for the three cases in
`scroll_command''s order. `*next-screen-context-lines*' is a parameter in
`simple.sld', where the commands are, so a user can set it as
`next-screen-context-lines' can be set.

**And the wrap question, which is fair:** `window_scroll_line_based' works on
*buffer* lines, and with wrapping a screen row is not a buffer line - so a
scroll of N screen lines is N buffer lines only for unwrapped text. Emacs's
line-based scroll is used on non-GUI frames and has the same property; the
pixel-based one (`window_scroll_pixel_based') is what a GUI frame uses, and
this tree's GTK front end has no pixel-based scroll yet.

**The count.** `tools/run-suites.py` is **459 passed** and the pty battery is
still **28/29**.

### 11. Horizontal scrolling (`hscroll`) (2026-10-01)

With `truncate-lines' on, the part of a long line beyond the window was
unreachable - there was no `hscroll' at all. The work is Emacs's whole
horizontal-scrolling story, at the level this renderer has:

**What was measured on `emacs -nw' first**, because the C leaves these open:

- **The row.** With `hscroll' = H in a WIDTH-column window, the row is `$' in
  its first cell - the left truncation glyph *overwrites* the character at
  the hscroll column (`insert_left_trunc_glyphs', `xdisp.c:23884'; there is
  no `<', `produce_special_glyphs' always makes `$'), then the characters
  whose display columns lie in [H+1, H+WIDTH-1), then `$' in the last cell
  when the line runs past the view. `emacs -nw' with `hscroll' = 100 in an
  80-column window drew `$' plus characters 101..178 plus `$'.
- **The amount auto hscrolling picks.** `hscroll-step' is 0 by default,
  which does *not* mean no scrolling - it means put point at the window's
  horizontal centre (`hscroll_window_tree', `xdisp.c:16851': `hscroll = max
  (0, it.current_x - text_area_width / 2)'). Point at column 239 of an
  80-column window gave `window-hscroll' 199 and the cursor in column 40.
  The C's at-end-of-line variant (`text_area_width - 4 * column_width') is
  not ported: the iterator stops on the character at point, never on the
  line break, and a point placed on the break was measured centring anyway.
- **When it moves.** Point entering the `hscroll-margin' (5) at either
  edge - the left one only while already hscrolled, the right one while the
  row is truncated there (`xdisp.c:16791-16800'). Moving point down to a
  short line scrolls back to 0 - measured, h went 199 then 0.
- **The pin.** An *interactive* `scroll-left'/`scroll-right' always sets
  `w->min_hscroll' (the spec `^P\np' gives SET-MINIMUM the *count*, which is
  always a number - 1 when no prefix was typed - so every interactive call
  pins, and a Lisp call, whose SET-MINIMUM is nil, does not). Measured: C-x
  < then C-n left the window at 78; `(scroll-left)' then C-n reset it to 0;
  C-u C-x < pinned 4. `C-x <' is a *disabled* command in Emacs 31; this
  tree has no disabled-command machinery, so the key runs it.
- **Suspension.** `scroll-left'/`scroll-right'/`set-window-hscroll' set
  `w->suspend_auto_hscroll', which clears when the window's point moves
  (`xdisp.c:16756', against `old_pointm').

**Ported:**

- `<window>' carries `hscroll', `min-hscroll', `suspend-auto-hscroll?' and
  `old-point' (frame.sld) - `w->hscroll' and friends are window-local
  there; `window-hscroll'/`set-window-hscroll!' (window.c:1289, the setter
  clips and suspends) and `scroll-left'/`scroll-right' (window.c:7101 and
  :7127, bound to C-x < and C-x >) are in `window.sld', where window.c's
  commands live. Their interactive expression reads `current-prefix-arg'
  for ARG and the count for SET-MINIMUM, which is the `^P\np' spec without
  the shift-select.
- `auto-hscroll-mode' (t), `hscroll-margin' (5) and `hscroll-step' (0) are
  buffer-locals in `buffer.sld'. Only nil, the default and 0 are ported;
  `current-line' mode and a non-zero `hscroll-step' act as their defaults.
- `hscroll-window!' (xdisp.sld) is the `hscroll_window_tree' pass, run for
  every window before any is drawn. One knowing deviation: the C measures
  point's position from the *previous* redisplay's cursor row and converges
  over two redisplays; here the position is the point's own line's, so the
  steady state is reached in one.
- The display: a window with an `hscroll' cannot wrap (`init_iterator''s
  second `line_wrap' condition, `window-truncates-lines?' now has it), and
  the hscrolled row is the slice of buffer columns whose display columns
  are in [H+1, H+WIDTH-1) - `hscroll-line-slice' cuts at a character
  boundary by display column, the way `line-glyph-run' does. `draw-line!'
  is handed the row minus its marker cells, so its own right `$' lands on
  the last column; the left `$' is written directly, because
  `draw-special-glyph!' is the *last* cell's glyph and three `$'s landed
  three columns short of being right the first time.
- `cursor-screen-position' computes the cursor's column as its display
  column less the `hscroll', never before the row's first cell - which is
  `w->cursor.x'.
- `toggle-truncate-lines' (simple.el:9341, M-x only in Emacs) came with
  this: the battery needs to turn `truncate-lines' on, and it is the real
  command for it. It resets the `hscroll' of every window showing the
  buffer when it turns folding back on, as its `walk-windows' loop does.

**The count.** `tools/run-suites.py` is **459 passed**; the pty battery has
the new `hscroll` check (verified to fail with the auto-hscroll pass
commented out) and is at **29/30**, `kill-ring` still the pre-existing
failure. The work also survived its own debugging: an `isearch-scroll`
failure that appeared mid-way was chased through three wrong conclusions
before the real story came out - a `highlight-matches` arity mismatch
swallowed by the render path, and then a *stale `xdisp.sld.go`* that made
three bisect steps test the same old binary (see the new AGENTS.md
gotcha). The GTK side was re-verified after the restore: `scroll-left`
pinned 78 in an 80-column window, the row drew `$`, characters 79..156
and `$`, and the cursor clamped onto the `$` cell with point left of
view.

**Not ported, named:** `auto-hscroll-mode' = `current-line' (`hscrolling_current_line_p',
`w->last_cursor_vpos'), a non-zero `hscroll-step' (its integer and float
forms, `xdisp.c:16862-16875'), `truncate-partial-width-windows'' effect on
`scroll-left' and the disabled-command machinery that would make C-x < and
C-x > ask "Do you want to use this command anyway?".

### Next, in order

1. **Scrolling** — redraw-only today; no smooth scroll.
2. **Performance** — the whole surface is redrawn and blitted every frame.
3. **Stage 2** of this plan (pixel-based interface) now buys something concrete:
   cairo can express real colours and, next, real fonts. The wide-character work
   also leaves the pixel interface better placed: a glyph now carries a width that
   is not its length, which is the same separation Emacs's `struct glyph` makes.
4. Then the feature-gap lists: `MG-PLAN.txt`, `BASIC-FUNC.md`.
