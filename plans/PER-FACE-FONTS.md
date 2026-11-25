# Per-face fonts in the Gtk backend — project plan

Written 2026-11-25. This is the plan the row-clipping work (commits
`15786b2`, `e500aad`) deliberately stopped short of: the renderer now
lays out and clips a row taller than a character cell, but on Gtk no
row can be taller, because the whole frame is drawn at one font.

**Decided order (Chris, same day): write this plan now, but finish
cc-mode before implementing it.**

## The departure this removes

GNU Emacs gives every realized face its own font. A glyph's advance,
ascent and descent come from its face's font, a row is as tall as the
tallest face on it, and lines wrap at pixel widths. This tree has one
font per *frame*:

- `pgtk-realize-font!` opens one Pango font and records
  `*font-description*`, `*font-ascent*`, `*cell-width*`,
  `*cell-height*`;
- `pgtk-ensure-font!` re-opens it from the *selected window's buffer's*
  realized `default` face, so `text-scale-mode` scales the whole frame
  and switching buffers scales it back;
- `face-metrics` (the display method `row-metrics` asks per face)
  ignores the face it is given and answers the frame font's metrics;
- `pgtk-show-text!` draws every run through one layout with that one
  description;
- the renderer's horizontal layout is one cell pitch: `char-display-width`
  and `texts-width` count character cells, `line-texts-rows` wraps at
  `window-body-width` cells, `draw-glyph-row!`/`write-glyphs!` pass a
  cell column, and the cursor and mouse coordinates are cells.

The named consequences in the tree today: `pgtk-ensure-font!`'s
"one grid per display" note, `face-metrics`'s "the answer is the
frame's font" note, and `DEPARTURES.md`'s row-clipping section ("what is
still missing is the reason a row would be taller at all").

## Emacs, as the reference

Read these before writing code; line numbers are Emacs 32 master at the
time of the plan and are checked again at implementation.

- `xfaces.c`: `realize_x_face` / its helpers choose the face's font
  (`font_load_for_lface`, fontsets) and fill `struct face` - `font`,
  `ascent`, `descent`, `space_width`, `underline_position`,
  `underline_thickness`. `struct face` is the per-frame realization the
  redisplay draws with.
- `xdisp.c`: for a normal character the display iterator gets
  `it->pixel_width` from the face font's text extents (the
  `gui_produce_glyphs` / `font->driver->text_extents` path) and
  `it->ascent`/`it->descent` from the font's ascent/descent (plus
  overline/box adjustments).
- `xdisp.c`: `compute_line_metrics` reduces a row to
  `row->ascent = max ascent` and `row->height = ascent + descent` over
  its glyphs; that is `row-metrics`, which this tree already has.
- `xdisp.c`: `init_iterator` sets `first_visible_x = hscroll *
  FRAME_COLUMN_WIDTH` and `last_visible_x = first_visible_x +
  window_box_width`; `display_line` advances `it->current_x` by
  `it->pixel_width` and wraps when the glyph would pass
  `last_visible_x`. Glyph x positions are pixels; hscroll stays a
  column count of the frame's font.
- `pgtkterm.c`: `pgtk_draw_glyph_string` takes the glyph string's face
  font, draws its background over the row's height, draws the text on
  the row's baseline, and derives the underline from the font's
  descent; `pgtk_draw_glyph_string_box` uses the row geometry.

Our Pango equivalents already exist in `pgtk.scm`: `pango-font-
description-from-string`, `pango_font_description_set_absolute_size`,
`pango_context_load_font`, `pango_font_get_metrics` (ascent, descent,
approximate char width), `pango_layout_set_font_description`, and the
`pango_layout_get_baseline` that `pgtk-show-text!` uses. There is no
guile-gi path to a layout with our cairo context (the file says why),
so the layout/drawing calls stay the FFI ones.

## Staged implementation, bottom up

Each step is independently testable; do not start the next until the
previous is green and its tests are in `tools/run-suites.py`.

### 1. The measurement interface

- Extend the display interface with the two questions the layout needs
  per face: **the metrics of a face's font** (ascent . descent, in
  pixels) and **the advance of a piece of text in a face** (pixels).
  `face-metrics` already has the first signature but ignores its attrs;
  give it the real per-face answer on Gtk. Add the second (working name
  `face-text-width`, `(display attrs text)`), cached per attrs/text the
  way `*face-metrics-cache*` is now.
- Tty and the test display keep the cell model: one ascent and
  descent, width = display cells × frame column width.
- Parse the face's font request the way `font_load_for_lface` does, as
  far as Pango can: `:family`/`:foundry`, `:weight`, `:slant`,
  `:width`, `:height` resolved to an absolute size
  (`merge_face_heights`: a float is relative to the face's absolute
  height; a number is tenths of a point; `point->pixel`). The frame's
  default face may still open the base font; a face with a relative
  height must resolve against the *frame's* absolute default, not the
  last scaled size (the existing `pgtk-ensure-font!` has that rule).
- Tests: Pango-measured widths for the default face and a scaled one
  at the pixel level (the pgtk test display can open fonts with no
  window); the tty/test-display cell answers; a face with `:weight
  bold`/`:slant italic` gets a different font description (where the
  font family has those faces).

### 2. Face tokens carry their font

- `realize-face-token` already interns a token per merged attribute
  set. Give the token's record its realized Pango description (or a
  cache the drawing looks up by token) beside the colours, underline
  and box it already keeps.
- `pgtk-show-text!` takes the description; `%pgtk-write-run` sets the
  layout's description before drawing, so a run is drawn in its own
  face's font, not the frame's.
- The run is placed on the **row's baseline**: pass the row's ascent
  (and height) from `write-glyphs!` into `%pgtk-write-run`; baseline =
  row top + `glyph-row-ascent`. The background fill spans the row's
  height, not `*cell-height*`; the underline's descent/thickness come
  from the face's font.
- Tests: a `:height 1.5` face inside a line draws visibly taller ink
  (screenshot scan), a row's `glyph-row-height`/ascent come from the
  tallest face (`row-metrics` already does this once `face-metrics`
  answers per face), and a small face on the same row sits on the
  shared baseline.

### 3. The frame font is the frame's again

- `pgtk-ensure-font!` must not re-open the frame font from the
  selected buffer's realized `default` face. The frame font comes from
  the frame's `default` face (`set-frame-font` semantics); a buffer's
  `text-scale` is a relative `:height` realized in that buffer's face.
- `*cell-width*`/`*cell-height*` remain the frame's default font
  metrics for the column-based parts (frame size in cells, hscroll
  units, tab bars); row heights stop coming from them.
- This step removes the `text-scale` frame-resizing departure and the
  test that pins it (`pgtk-test.scm`'s "row metrics are the drawn
  font's, unscaled and scaled" and the `ink-rows-scaled` family are
  rewritten to assert a *window-local* scaled row and an unscaled
  neighbour in the same frame).

### 4. The row layout measures in pixels

- `line-texts-rows` (and the slice walk it feeds) currently counts
  cells. It must measure each entry with its face's font advance and
  wrap at the window's **pixel** width. The face at a buffer position
  is `attrs-at-buffer-position` over the line's text; the layout needs
  a display and face resolution, which today it does not have
  (`indentc.scm` sits below the face layer). Decide the seam: either
  the row builder precomputes a per-column (width, face-token) vector
  and hands it to the layout, or the layout gets a measurement
  callback. Keep one walk - do not make a second one that can disagree
  with the built glyphs.
- `window-body-width` gains a pixel twin; wrapping compares pixel
  sums; `line-texts-offsets` answer pixel offsets for the drawing and
  for the cursor's x. Display-property strings are measured with
  `string_width`'s rule (the string's own faces) where Emacs does.
- Cache measurements per (text, face description), as Emacs' glyph
  cache does; a redisplay must not open a font per character.

### 5. Glyph and run geometry is pixels

- Glyph x positions and widths become pixels: `glyph-pixel-width` is
  the face font's advance, `glyph-row-x`/run x are pixel offsets, and
  `write-glyphs!`'s x is a pixel column for the Gtk backend. The
  terminal still writes in character columns because that is its
  device; consider adopting Emacs's `write_glyphs (window, row, glyphs,
  area, len)` shape (no x; the backend derives it from the glyphs'
  widths) so the interface has one meaning.
- `draw-glyph-row!` splits runs by face as now and passes each run's
  first glyph; `$`/`\` markers, the fill to the edge and box drawing use
  pixel widths.
- The cursor (`cursor-screen-position`, `draw-window-cursor!`) returns
  and draws pixel x/y; `posn-at-x-y` and `buffer-posn-from-coords` take
  the mouse's pixel x/y (the Gtk front end already has pixels); the
  terminal keeps its cell conversion at the boundary.

### 6. The callers that measure text

- `string-pixel-width` must measure with real fonts (tab bars, tab
  line, mode line widths); `window-text-pixel-size` if/when something
  needs it. `tab-bar-auto-width`'s results change with proportional
  face fonts and its tests need Emacs-measured expectations.
- Scroll bars keep their pixel widths (already named as a column-
  quantized departure); no change expected here.

### 7. Clean-up of the departures

- Remove the global-font notes in `pgtk.scm` (`face-metrics`,
  `pgtk-ensure-font!`, `pgtk-realize-font!`) and replace them with the
  per-face rules; update `DEPARTURES.md`'s row-clipping section ("the
  reason a row would be taller at all") and the Gtk notes.
- Rewrite or delete the tests that pin the old behavior; add pixel and
  font-metric tests as above. The full suite and pty battery gates
  apply (the Gtk suite is in `tools/run-suites.py`; the pty battery
  exercises the terminal, whose face model is unchanged).

## What stays unfixed, and why

- **One font per tty face is Emacs's own answer**: `tty_capable_p` folds
  colour/weight/underline onto terminal attributes; there is no font.
  The terminal's `face-metrics` is the cell's (0 . 1) and stays.
- **Images, fringes, display margins, composition/ligatures, and
  variable-width scroll bars** are not in this project; each is its own
  display feature. Per-face *widths* do not require them.
- **Proportional default fonts**: the editor's cell grid (frame width in
  columns, tab/menu bars, scroll bar columns) assumes a fixed pitch for
  the frame's font. Emacs's `FRAME_COLUMN_WIDTH` is also the default
  font's, so that stays; what changes is that glyphs within rows are
  placed by their own advances.

## Method notes carried forward

- The row walk and the drawing must share one measurement; two walks can
  disagree (the row-clipping work found the same class in
  `window-line-slices-at` vs `%row-of-line-rows`).
- A record change means clearing `~/.cache/guile/ccache` before
  believing a test.
- Measure on the real Gtk display under broadway and read pixels
  (`pgtk-write-screenshot!` + the PNG reader in `pgtk-test.scm`);
  measure Emacs's own answers with `string-pixel-width` /
  `window-text-pixel-size` where a batch or pgtk Emacs can answer, and
  record which Emacs binary and feature set gave them.
- Time-scale performance: a redisplay must not open a font per
  character. The face realization cache and a (text, description)
  measurement cache are the starting points; measure a keystroke the
  way `pgtk` measurements in this tree always are.
