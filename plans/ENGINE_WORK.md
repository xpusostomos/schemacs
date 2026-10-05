# Engine work: the remaining gaps in Emacs fidelity

Written 2026-10-06, after the `buffer-text`, window-marker and region-cache
work, and revised the same day after Chris pushed back on the first draft.
This is where the engine departs from Emacs's *shape*, what each departure
costs, and what closing it would take.

It is not a list of bugs. The one bug found while writing it — the `%l`
cache's missing freshness rule — is fixed in `198f460` and recorded in
AGENTS.md. These are departs that were never ported at all.

In the order I would do them.

---

## 1. modiff — the modification counters

**Emacs.** `struct buffer_text` carries two counters (`buffer.h`):

```c
modiff_count modiff;        /* counts buffer-modification events ... */
modiff_count chars_modiff;  /* set to modiff for character changes */
```

bumped by `modiff_incr` (`lisp.h:4142`), which raises the counter by
`len == 0 ? 1 : elogb (len) + 1` — logarithmically in the size of the
change, so a large edit does not race the counter away — with
`CHARS_MODIFF = MODIFF` on a character change (`insdel.c:929`).

`BUF_MODIFF` is read all over: whether a window's display is still valid,
whether the mode line needs redrawing (`mode_line_update_needed`),
`buffer-modified-p` (`BUF_MODIFF != BUF_SAVE_MODIFF`), undo boundaries,
and redisplay's "nothing changed at all" shortcut. Its Lisp faces are
`buffer-modified-tick` and `buffer-chars-modified-tick` (`buffer.c:6107`,
`:6109`).

**Ours.** `text-editor-modified?` is a **boolean**, plus a `save-token`
standing in for `BUF_SAVE_MODIFF`. That answers *"changed since the last
save"* and nothing else; it cannot answer *"changed since this other
moment?"*, which is what the caches and any redisplay freshness check need.

**Do this first.** `beg_unchanged` (added in `198f460` for the `%l` fix)
is the *companion* to these counters — Emacs derives "is this fact still
true" from modiff plus the unchanged-prefix together. With only a boolean
there was nothing to derive from, which is exactly why that cache had no
way to know it had gone stale. Do this before the next thing that needs
freshness, or it grows another hand-rolled counter beside it.

**Cost:** small. Two counters on `buffer-text`, bumped in the three writers
in `engine.sld` by `modiff_incr`'s rule.

---

## 2. `width_run_cache` — **not worth porting; corrected 2026-10-06**

I first listed this as "now cheap" on the grounds that the mechanism
(`region-cache.sld`) exists so it is only "apply it to another property".
That was wrong, and the source says so plainly.

**Emacs disables it in every normal buffer.** `width_run_cache_on_off`
(`indent.c:145`):

```c
  if (NILP (BVAR (current_buffer, cache_long_scans))
      /* And, for the moment, this feature doesn't work on multibyte
         characters.  */
      || !NILP (BVAR (current_buffer, enable_multibyte_characters)))
    { free_region_cache (...); return NULL; }
```

`enable-multibyte-characters` is **t** by default (`emacs -Q --batch`:
`(buffer-local-value 'enable-multibyte-characters (current-buffer))` →
`t`), so the cache is freed and off. It only runs for a *unibyte* buffer
- one explicitly made so with `set-buffer-multibyte nil`.

**And even then it is narrow.** `compute_motion` reads `FETCH_BYTE`
(`indent.c:1671`) - bytes, not characters - and the fill site says
"Currently, we only cache runs of width == 1" (`:1686`). So its whole
benefit is skipping a run of ASCII in a buffer that has been declared
byte-oriented.

**So the faithful port is "do not port it".** Our store is code points;
there is no unibyte/multibyte distinction to test, so the C's condition
would translate to "always off" and the code would be dead.

The tempting thing - which is *not* what Emacs does - would be to cache
runs of width-1 characters in our code-point buffers, where
`current-line-display-column` (`disp-table.sld:185`) walks every
character summing `char-display-width`. That would help ASCII-heavy lines,
which is the common case, and unlike Emacs we have no multibyte obstacle.
But it is an invention, not a port, and Emacs explicitly declines to do it.
**Chris's call**, not mine.

**What item 6 actually came to: `cache-long-scans`.** The buffer-local both
caches hang on (`buffer.c:5786`, default **true**, "There is no reason to
set this to nil except for debugging purposes"). **Added**: it is now a
field of the buffer, and `find-newline` consults it before making a cache,
exactly as `search.c:618` does. Behaviourally neutral at the default, but
our line-break cache was ungated where Emacs's is gated, and that was a
real if small departure.

`bidi_paragraph_cache` needs the bidi algorithm, which is not ported.

## 3. Indirect buffers — `base_buffer`

**Emacs.** `struct buffer` has `base_buffer` and `indirections`
(`buffer.h:628-635`), and `text` is a *pointer* to a `buffer_text`
(`buffer.h:608`) — for an ordinary buffer it points at its own `own_text`,
for an indirect one at another buffer's. Two buffers therefore share one
text object; edits through either are visible in both, while each keeps its
own point, mark, narrowing and buffer-locals.

**Ours.** One `<text-editor_type>` owns one `<buffer-text>`. `files.sld`
says it outright: *"Not ported: `buffer-base-buffer` (there are no indirect
buffers)."*

**Wanted** (Chris, 2026-10-06). What needs it: `clone-indirect-buffer`
(C-x 4 c — two views of one file, each with its own point and narrowing;
`simple.el:11028` is its implementation and it narrows the clone to a
region), and much more **org-mode's `org-tree-to-indirect-buffer`**
(C-c C-x b), which edits one subtree in a buffer of its own while the base
buffer still shows the file.

**Cost.** `<text-editor-type>`'s `text` becomes a pointer it may share,
plus `base-buffer`/`indirections`, plus the `set-buffer` plumbing Emacs has
in `set_buffer_internal`. Then `make-indirect-buffer` and
`clone-indirect-buffer`.

**One thing it simplifies:** `invalidate_buffer_caches` opens with
"Indirect buffers usually have their caches set to NULL, but we need to
consider the caches of their base buffer" — a branch we do not currently
need and would have to add.

**Note the coupling with item 5:** `clone-indirect-buffer` narrows the
clone to the region it shows. Indirect buffers are much more useful with
narrowing than without.

---

## 4. Narrowing — `begv` / `zv`

**What it is.** A buffer has **two** coordinate ranges, not one
(`buffer.h:617-626`): `BEG`/`Z` are the whole text; `BEGV`/`ZV` are the
part currently *accessible*. `narrow-to-region` moves the second pair,
`widen` puts it back. `point-min`/`point-max` answer the second pair, and
every operation is bounded by it — `count_lines` counts from `BEGV`,
`find_newline` stops at `ZV`.

**What it is for.** It is a way to say "the buffer is now just this part"
*once*, instead of passing a bound to every operation inside. It is a
lexical/dynamic scope for buffer bounds.

**Where it is used.** Not mainly the user command `C-x n n` — mostly as an
implementation technique, and heavily:

| file | mentions |
|---|---|
| `gnus/message.el` | 94 |
| `gnus/gnus-art.el` | 77 |
| `progmodes/cc-engine.el` | 54 |
| `mail/rmail.el` | 48 |
| `org/org.el` | 37 |
| `simple.el`, `subr.el`, `dired.el`, `replace.el`, ... | throughout |

Two unmistakable examples:

```elisp
;; simple.el:1749 - count-words-region. Note the loop takes no bound:
;; with the buffer narrowed, forward-word simply cannot leave the region.
(save-restriction
  (narrow-to-region start end)
  (goto-char (point-min))
  (while (forward-word-strictly 1) (setq words (1+ words))))

;; subr.el:4976 - count-matches. Same shape: search-forward with a nil
;; bound, because the region IS the buffer now.
(save-restriction
  (narrow-to-region start end)
  (while (search-forward string nil t) ...))
```

**Ours.** One pair. `text-editor-point-min` is literally
`(buffer-text-base (text-editor-text ed))` — always 1 — so there is nowhere
to put a narrowed bound. `buffer.sld`'s `erase-buffer` notes "there is no
narrowing, so the widen is a no-op".

**Consequences.** (a) `C-x n n` / `C-x n w` do not exist; (b) every
algorithm ported from Emacs that uses the idiom has to be rewritten to pass
explicit bounds — verbose, and easy to get subtly wrong; (c)
`line-number-at-pos`'s `ABSOLUTE` argument is meaningless here (it exists
only because narrowing moves the count start); (d) `save-restriction` has
nothing to save.

**Cost.** Add `begv`/`zv` (Emacs puts them on `struct buffer`, not
`buffer_text`, because an indirect buffer narrows independently), then
thread them through every scan: `find-newline`'s `END` default,
`count-lines`, `bol`, `eol`, `find_before_next_newline`,
`text-editor-point-min`/`-max`, and every caller that assumed `point-min`
is 1. Mechanical and wide rather than deep. Then `narrow-to-region`,
`widen`, `save-restriction`.

---

## 5. Overlay storage — `itree`

**Emacs.** Each buffer's overlays are an interval tree
(`struct itree_tree *overlays`, `buffer.h:719`), in `itree.c` — **1,435
lines**. A red-black tree with *lazy offsets*: each node carries
`begin`/`end`/`limit`/`offset`/`otick`, and an edit marks nodes dirty and
bumps the tree's tick rather than moving them, so an insertion shifts the
whole tree in O(log n). That is why overlays are cheap in modern Emacs.

**Ours.** `buffer.sld` has the whole overlay *API* — `make-overlay`,
`delete-overlay`, `move-overlay`, `overlay-start`/`end`/`get`/`put`/
`priority`, `overlays-at`, `overlays-in`, `next-overlay-change`,
`previous-overlay-change` — and the two ends are markers, so they follow
edits exactly as Emacs's do, `front-advance`/`rear-advance` included. The
*storage* is a flat list per buffer (`buffer-overlays-table`, kept in order
by start by `add-buffer-overlay!`), so `overlays-at`/`overlays-in` walk the
whole list — O(n) per query, and the redisplay asks on every line.

Also not ported, per the module's own header: `before-string` /
`after-string`, `evaporate`, `overlay-recenter`, the modification hooks,
the `window` property. Missing from the API: `delete-all-overlays`,
`overlay-buffer`, `overlay-lists`, `overlay-tree`.

**Before doing it, weigh this.** `itree` has exactly one consumer here:
text properties — where our font-lock and completion live — use the *older*
weight-balanced tree, and Emacs 31 still uses it too (`intervals.h` is
unchanged). So this is 1,435 lines of C for overlays alone. If overlay
counts stay modest, the list may be adequate. **Measure before porting.**

---

## 6. The renderer, and the display iterator

**The claim I got wrong the first time.** I said materialising a line as a
string was "a simplification of the data format". That is not the reason
and Chris was right to be sceptical. Here is the real picture.

**What `struct it` actually is.** `dispextern.h:2430`, 506 lines of
declaration, **86 fields**. Roughly ten of them are the walk:

```
current, position, start, stop_charpos, end_charpos, prev_stop,
nglyphs, hpos, vpos, lnum
```

The other ~75 are everything else redisplay has to handle *while* walking:

- **bidi**: `bidi_it` (a whole nested iterator), `base_level_stop`
- **compositions**: `cmp_it`, `char_to_display`
- **images**: `image_id`, `slice`, `object`
- **faces**: `face_id`, `base_face_id`, `saved_face_id`, `dpvec_face_id`
- **display properties**: `dpvec_char_len`, `glyphless_method`, `object`
- **overlay strings**: `overlay_strings`, `n_overlay_strings`, `from_overlay`, `string_overlays`
- **pixel layout**: `current_x`, `current_y`, `pixel_width`, `last_visible_y`, `voffset`, `space_width`, `font_height`, `extra_line_spacing*`, `tab_width`, `wrap_prefix_width`, `continuation_lines_width`, `stretch_adjust`
- **line numbers and tab stops**: `lnum`, `lnum_width`, `lnum_pixel_width`, `pt_lnum`
- **selective display**: `selective`, `ctl_chars`
- and even **narrowing for long lines**: `medium_narrowing_begv`, `min_width_property`

**So yes — a basic iterator is easy, and we already have one.**
`line-display-texts` (`xdisp.sld`) walks a line's characters one at a time
and produces a glyph/face per column. That *is* a basic display iterator.
What Emacs's has that ours does not is not iteration; it is the ~75 fields
of feature state and pixel precision.

**Why it is an *iterator* rather than a per-line function.** Resumability.
Redisplay must be able to stop in the middle of a line and resume exactly
where it was, because a line can wrap across several calls to
`display_line`, a window can be redisplayed on its own, a partial update
redraws part of a row, and a `display` property, image or overlay string
can interrupt. Resuming needs all that state intact — which is why the
state is in the struct.

**What ours costs**, stated honestly:

- a string per line per redraw, plus the `line-display-texts` vector;
- "buffer column" (a string index) leaking into the layout code, where the
  C uses iterator positions;
- **no partial redisplay** — a wrapped line is always re-rendered whole;
- no glyph-level hit-testing, no pixel-exact cursor placement;
- **nowhere for `before-string`/`after-string` overlays to live** — text
  drawn that is not in the buffer has no representation when the unit of
  drawing is a string *of the buffer's characters*.

That last one is the important link: **item 6 and the overlay gaps in item
5 are one decision, not two.** I presented them as separate gaps in the
first draft; they are not.

**Verdict.** Not to be undone as it stands. But a "basic `struct it`" is
not the missing piece — the missing piece is what the extra 75 fields mean,
and each of those (bidi, images, compositions, overlay strings, partial
redisplay) is its own project. Reaching for `before-string` is asking for
the iterator **and** the glyph matrix, not for a small feature.

---

## Also on the record, smaller

- **`last_window_start`** (`buffer.h:676`) — the start a buffer had in the
  last window disconnected from it, so switching away and back finds it
  where it was left. A buffer-local slot; `scroll-to-cursor!` recomputes a
  window's start each redisplay, so it would have no effect today.
- **`w->force_start`, `w->optional_new_start`, `w->column_number_displayed`**
  — read by redisplay's start decision and the mode-line-update decision.
  `scroll-to-cursor!` stands in for the first; this renderer redraws
  unconditionally, so the third has no reader.
- **`end_unchanged`** — Emacs keeps it beside `beg_unchanged`; its readers
  (`window_outdated`, `redisplay_internal`) are not ported.
- **The byte twins** (`gpt_byte`, `z_byte`, `PT_BYTE`, `BYTE_POS_ADDR`) —
  deleted by departure #3, the `u32vector` of code points. A decision, not
  a gap.
- **`BUF_BYTES_MAX`** — no analogue, not applied.
- **The regexp engine** is Guile's, not Emacs's: leftmost-longest (POSIX)
  rather than leftmost-first, shy groups renumber, `\sX`/`\cX` rejected.
- **`long-line-threshold`** (`buffer.c:6022`, default 50000) and the
  `long-line-optimizations-*` variables — Emacs switches redisplay to
  narrowed, shortcut behaviour for buffers with very long lines. Not
  ported; note our *renderer* is already flat in buffer position since the
  2026-10-05 work, which is a different and cruder answer to the same
  problem.
