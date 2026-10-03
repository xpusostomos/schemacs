# Faces: what it takes to support them

Written 2026-09-27, companion to LAYOUT-PLAN.txt, NCURSES-PLAN.txt and
MG-PLAN.txt.

## Context

Nothing in this editor is highlighted except two things that were
special-cased into the renderer: the mode line is drawn in reverse video,
and a running search draws its match in reverse video and the other
matches in bold. Both are faces — `mode-line` and `isearch` /
`lazy-highlight` — written in by hand as terminal attributes.

That is the whole of what the code admits about faces, and it admits it in
several places. `buff-menu.sld`'s header says "There are no faces, so
`Buffer-menu--pretty-name` is the name itself". `tabulated-list.sld` puts
its column titles in the buffer's *text* because there is no header line,
and a header line is a face plus a place to draw it.

This plan is the ladder from where we are to `faces.el` working, in the
order the layers depend on each other.

## What a face is

Three things stacked, and only the last of them is a renderer's problem:

1. **A named spec.** `defface` gives a face a list of `(DISPLAY . ATTRS)`
   pairs, where DISPLAY is a condition on the display: `(type tty)`,
   `(class color)`, `(min-colors 8)`, `(background dark)`,
   `(supports :box t)`. The first matching condition supplies the
   attributes. Five of `faces.el`'s specs are `(type tty)` conditions, so
   that branch is not a corner.

2. **A realization, per frame.** The spec is evaluated against a *frame*
   into a set of concrete attributes, because the same face has to be able
   to look different on a terminal and on a window system. Emacs keeps
   this per frame and recomputes it when the frame or the spec changes.

3. **A property on text.** A face reaches characters as the `face` text
   property — a face name, a face, or a *list* of them, which merge.

### On a terminal, layer 2 is a fold-down, not a renderer

This is the part worth stating before any code, because it sets the
expectation. A terminal can express very little:

| attribute | on a tty |
| --- | --- |
| `:weight bold` | the terminal's bold |
| `:underline t` | underline |
| `:inverse-video t` | reverse |
| `:slant italic` | only where terminfo has `sitm`/`ritm` |
| `:foreground` / `:background` | a *colour index*, if the terminal has colours at all |
| `:family`, `:foundry`, `:width`, `:height`, `:box`, `:stipple` | ignored |

So distinct faces collapse. On a monochrome terminal
`font-lock-keyword-face` and `font-lock-function-name-face` are both just
"bold". That is not a limitation of our port — it is what Emacs does, and
it is why the standard specs are written with `(min-colors N)` branches
picking different attributes per terminal. Emacs asks the terminal what it
can do (its `tty_capable_p`); the answer decides which spec branch applies.

## What is already here

Two face-shaped holes, already cut:

- **The mode line is the `mode-line` face.** `xdisp.sld` wraps it in
  `A_REVERSE`. That is exactly `mode-line`'s tty spec — the `(t
  :inverse-video t)` branch, `faces.el:2729-2730`. The hardcoded attribute
  and the face's default say the same thing.
- **A search highlight is the `isearch` face.** `*search-highlight*`
  (`xdisp.sld:72`) is one parameter carrying a match's start and end,
  drawn reverse/bold at `xdisp.sld:386-404`. `isearch.el:313` defines the
  `isearch` face and `lazy-highlight` its neighbours; the parameter is
  standing in for "these characters have the `face` property
  `isearch`".

And one false start worth naming so it is not mistaken for a foundation:
the engine **reserves** storage for text properties —
`text-line-props` on each `<text-line-type>` (`engine.sld:381`, "arbitrary
information about the text properties of the string") and
`text-editor-text-props` on the editor (`engine.sld:621`, "a VBAL that
contains text properties for ranges of text that span multiple
`<text-line-type>` values ... useful for syntax coloring"). Nothing reads
or writes either: two references each, both the slot definition. There is
no API, no splitting or merging, no stickiness, and nothing shifts them
when text is inserted or deleted. The slots are a placeholder.

## Step A is done (2026-09-28)

Two libraries, both translated from the C and both under test:

- **`editor/intervals.sld`** (from `intervals.c`) — the tree: the
  `<interval>` node, `find`/`next`/`previous`/`update-interval`, the
  splits and merges, `delete-interval`, the weight-balancing with its
  rotations, `interval-deletion-adjustment`, `offset-intervals`,
  `create-root-interval`, `textget`/`lookup-char-property`,
  `intervals-equal?` and `merge-properties-sticky`. 14 tests in
  `intervals-tests.scm`.
- **`editor/textprop.sld`** (from `textprop.c`) — the API:
  `put-text-property`, `get-text-property`, `add-text-properties`,
  `set-text-properties`, `remove-text-properties`, `text-properties-at`,
  `get-char-property`, `next-`/`previous-single-property-change`. 17
  tests in `textprop-tests.scm`.

The engine calls `offset-intervals` on every insert and delete, from
beside `adjust-markers-for-insertion!` and `adjust-markers-for-deletion!`
— which is where `insdel.c` calls it, and for the same reason: once for
the whole edit, so that every way text gets in is covered. There is a
seam to make that call possible, `*text-property-offset-function*`, and it
is there because of how the halves split *here*: the engine holds the
tree's root and `intervals.sld` reaches it through the engine's accessors,
so the engine cannot import `intervals.sld` — a dependency the C does not
have. The parameter is #f until `intervals.sld` loads, and the engine
checks.

Three deviations, all in the two libraries' headers: positions are 0-based
(Emacs's *string* convention, because this engine indexes from 0
everywhere); the sticky bits and `write_protect`/`visible` are read from
the plist rather than cached on the node; and there are no string
intervals, so everything acts on a buffer — which is what blocks
`propertize`. Property changes are also not yet in the undo list.

## Step B is done (2026-09-28)

**`editor/faces.sld`** (from `faces.el`) — the face table, the spec
machinery (`defface`/`custom-declare-face`, `face-spec-set`,
`face-spec-choose`, `face-spec-recalc`, `face-spec-set-2`,
`face-spec-reset-face`, `face-spec-set-match-display`), reading
(`face-attribute`, `face-all-attributes`, `face_attribute_relative_p`,
`merge-face-attribute`) and writing (`set-face-attribute`,
`internal-set-lisp-face-attribute`). 14 tests in `faces-tests.scm`.

The **standard faces are Emacs's own specs**, converted mechanically from
`faces.el` and `isearch.el` rather than retyped - `default`, `bold`,
`italic`, `underline`, `mode-line`, `mode-line-inactive`, `header-line`,
`region`, `highlight`, `minibuffer-prompt`, `error`, `warning`, `success`,
`shadow`, `link`, `trailing-whitespace`, `show-paren-match`, `isearch` and
`lazy-highlight`. That matters more than it sounds: most of those specs are
written for a graphical display, so on a terminal it is their `(t ...)`
branches that apply, and `mode-line` comes out `:inverse-video t` - which
is exactly what the renderer hardcodes today. The tests pin that down.

**One finding that changes step C.** `face-attribute` is *not* what the
display reads faces with. Its INHERIT argument merges only for attributes
that are *relative* (`face_attribute_relative_p`), and the C's
`merge_face_attribute` turns out to resolve almost nothing - only
`:height`. `mode-line-inactive` inheriting `:inherit mode-line` still
answers `unspecified` for `:inverse-video` through `face-attribute`. The
display uses a different function, `merge_face_vectors` in `xfaces.c`,
which resolves `:inherit` for every attribute as it walks. So step C needs
`merge_face_vectors`, and `face-attribute` is the wrong thing to call for
it.

Three deviations, in the header: one frame (so one set of realized
attributes, and the FRAME argument is accepted and not consulted); no
Custom, themes or X resources, so `face-spec-recalc` is reset + defface
spec + override spec with nothing in between; and attribute values are
recorded as the spec gives them, not resolved against a terminal - that is
step C's fold-down.

## Step C is done (2026-09-28)

**`editor/xfaces.sld`** (from `xfaces.c`) — the merging and the fold-down:

- `merge-face-vectors` / `merge-face-ref`, with the `:inherit` recursion.
  This is the function the display reads faces with, and it exists because
  `face-attribute` does *not* resolve `:inherit` for absolute attributes
  (see step B). Tests confirm `mode-line-inactive` picking up
  `mode-line`'s `:inverse-video` through it, and a list of references
  merging left to right so the last wins.
- `realize-tty-face` — the fold-down. Weight and slant from Emacs's own
  `font-weight-table` / `font-slant-table` (bold is 200, `> 100` is bold;
  italic is 110, `!= 100` is italic), inverse-video and strike-through and
  overline as switches, and the two colours as indices. Family, foundry,
  width, height, box and stipple are dropped, so two faces differing only
  in their font are one face on a terminal.
- `map-tty-color` and `tty-capable-p`, plus the ANSI colour table.

12 tests in `xfaces-tests.scm`.

Not ported, and named in the header: the colour tables Emacs builds from
terminfo at startup (`init_tty`) and the fallback `tty-color-approximate`
needs them; the face cache (`lookup_face`); and the whole X and
window-system half of the file.

## Step D is done (2026-09-28)

The two hardcoded highlights are gone and are now the faces they always
were:

- the **mode line** is `mode-line` when its window is selected and
  `mode-line-inactive` otherwise. On a terminal `mode-line` is
  `:inverse-video t`, which is exactly what `xdisp.sld` used to hardcode -
  so this is a replacement, not a change of appearance.
- a **search** is the `isearch` face on the match point and
  `lazy-highlight` on the others, in place of the hardcoded A_REVERSE and
  A_BOLD. On an 8-colour terminal `isearch` is cyan on magenta and
  `lazy-highlight` has a turquoise background, so the *appearance* did
  change - it is now Emacs's, from Emacs's own specs.

Reaching the screen needed two more libraries and one fix, none of which
the plan anticipated:

- **`editor/tty-colors.sld`** (from `term/tty-colors.el`) — what a colour
  *name* means. This was the surprise: almost nothing a face spec names is
  an ANSI colour (`mode-line` asks for `grey75`, `isearch` for `magenta4`
  and `lightskyblue1`), so without a name->RGB table and a nearest-colour
  approximation a face that asked for a colour was drawn with **nothing at
  all** - worse than the wrong colour, and it is what happened when this
  library was missing. The table is Emacs's `color-name-rgb-alist` (657
  names) converted mechanically, and the metric is Emacs's `color_distance`
  from `xfaces.c` - the Riemersma formula, which weights by the mean of the
  two reds. That weighting is not decoration: by plain sum of squares a
  dark magenta is nearer a grey than it is to magenta.
- **Colour pairs.** `xdisp.sld` makes one per foreground/background the
  faces ask for, as `tty_face_1` does, and `with-terminal` now calls
  `start-color!` - without which ncurses ignores `init-pair!` entirely and
  every coloured face silently draws as nothing.
- **`screen_of` in `tools/pty-check.py`** had to learn the *relative*
  cursor moves (`ESC [ n B` and friends) that ncurses emits whenever it
  can; a reader that only understood absolute addressing drifted a row and
  lost the mode line.

**The run walk has landed too.** `draw-line!` draws a line in *runs*:
`line-face-runs` cuts the line at face changes, and each run is emitted
with one attribute around it, rather than a terminal being told per
character. Two things about it are worth keeping:

- the runs are cut in *screen cells*, not buffer characters, because a tab
  before a run has already moved the text along - which is why
  `line-display-offsets` was added to `disp-table.sld` (where
  `current-line-display-column` answers the same question for one column
  at a time);
- a buffer with no property tree takes the old single-`addstr` path. That
  is almost every buffer almost all the time, and it keeps the common case
  as fast as it was.

6 more tests in `faces-tests.scm` cover the run computation. What is *not*
yet covered end to end is a face on buffer text reaching the screen,
because nothing in the editor puts a face on text yet: that needs isearch
to set the `isearch` face property instead of publishing
`*search-highlight*`, or font-lock. Until then the run walk is exercised
by its unit tests and the attribute emission by the mode line and the
search, which the pty battery covers.

## The layers

Each is named for the Emacs file whose role it fills, per LAYOUT-PLAN.txt —
which already lists `faces.el`/`face.c` among the base names that exist on
both sides of Emacs's tree.

### A. Text properties — `intervals.c` + `textprop.c` → two libraries

**Done — see the section above.**

The long pole, and nothing else works without it, because a face reaches
text *as a property*.

Emacs splits this across two files, so this does too, per LAYOUT-PLAN's
rule:

- **`intervals.c` → `editor/intervals.sld`** — the interval tree itself:
  `find_interval`, `next_interval`, `previous_interval`, `update_interval`,
  `split_interval_right`, `split_interval_left`, `merge_interval_left`,
  `merge_interval_right`, `copy_properties`, the balancing
  (`balance_an_interval`, `balance_possible_root_interval`, the rotations),
  and `offset_intervals` with `adjust_intervals_for_insertion` /
  `adjust_intervals_for_deletion`. `<interval>` is `struct interval`:
  `total_length`, `position`, `left`, `right`, `up`, `plist`.
- **`textprop.c` → `editor/textprop.sld`** — the API over it: the functions
  below, plus `textget`/`property_value` (plist lookup honouring
  `category`), `add_properties` (which *merges*), `set_properties`,
  `remove_properties`, `validate_interval_range`, `validate_plist`, and
  `verify_interval_modification` / `report_interval_modification`, which is
  where the read-only property and the sticky rules are enforced.

**The engine's hook points are already there.** `text-editor-insert`
(`engine.sld:1701`) calls `adjust-markers-for-insertion!` once for the
whole insertion, with the comment that doing it there "covers every way
text gets in: characters, strings, whole lines, a line break typed or
forced by the line-break state machine, and an insertion replayed by
undo". `text-editor-delete-from-cursor` (`engine.sld:1878`) does the same
with `adjust-markers-for-deletion!`. Those two calls are exactly where
Emacs's `insdel.c` calls `offset_intervals`, and that is where
`offset-intervals` goes — the interval shift and the marker shift are the
same fact about the same edit.

**Positions are 0-based.** Emacs's interval positions are 1-based for a
buffer (`create_root_interval` sets `new->position = BEG`, which is 1) and
0-based for a string, because they are Lisp buffer positions. This
engine's character indices are 0-based everywhere, so our interval
positions are 0-based too — Emacs's *string* convention. The 1-based
buffer-position conversion belongs in the elisp layer, the same way
`point` does, and the library should say so in its header rather than
convert silently.

**What it owes.** Emacs's API and, more importantly, its semantics:

- `put-text-property`, `get-text-property`, `add-text-properties`,
  `set-text-properties`, `remove-text-properties`, `text-properties-at`,
  `get-char-property`, `next-single-property-change`,
  `previous-single-property-change`, `next-property-change`, and the
  `(properties ...)` / `propertize` path that constructs them.
- A property is a *plist* over a *range*. Writing splits the range;
  `add-text-properties` **merges** a plist into the existing one rather
  than replacing it; `set-text-properties` replaces.
- Insertion and deletion **move** properties with the text.
- Inserted text **inherits** the properties of the neighbouring character,
  except where `front-sticky` and `rear-nonsticky` say otherwise. This is
  the rule that `field` properties in the minibuffer and `read-only`
  properties on text depend on. It is not optional decoration; getting it
  wrong shows up as text that "loses" its read-only-ness when edited.

**Where the root lives.** The buffer holds the root of the tree
(`BVAR (buf, intervals)`) and `insdel.c` shifts it as text moves — so the
root is a slot on `<text-editor-type>`, and the two `offset-intervals`
calls above are the engine's part of this. That keeps the engine's stated
scope — "mirrors `buffer.c` + `insdel.c` + `marker.c` + `search.c`" —
honest, since the shift-on-edit half is `insdel.c`'s.

**Decision to make here.** The engine already has two property slots and
neither is the right shape: the per-line one cannot hold a range that
crosses a line break (which is why the buffer-level VBAL was added), and a
line's own props would go stale the moment a line is split or joined.
Recommendation: the buffer-level slot becomes the interval root, and the
per-line slot goes. It is unused, so nothing is lost.

**What it retires.** Once properties exist, three substitutions documented
in `buff-menu.sld` and `tabulated-list.sld` are no longer needed: the
marks-as-a-table (Emacs puts a tag character in the text and reads it back
with `tabulated-list-put-tag`), the line-counting in place of
`tabulated-list-id` / `tabulated-list-get-entry`, and the titles-in-text
in place of a header line. They should be retired *after* faces work, not
before — each is currently correct and tested.

### B. The face object — `faces.el` → `editor/faces.sld`

**Done — see the section above.**

**What it owes.**

- `defface` / `custom-declare-face`, and the spec evaluator that picks the
  branch matching the frame's display.
- `face-attribute`, `set-face-attribute`, `face-all-attributes`,
  `face-list`, `facep`, `internal-make-lisp-face`,
  `internal-set-lisp-face-attribute`, `face-spec-set`.
- `:inherit`, taking a face or a *list* of them, resolved transitively; and
  the rule that setting an attribute on `default` reaches every face that
  inherits it — because they inherit it lazily, not by copying.
- The standard faces, under Emacs's names, because ported Elisp refers to
  them by name and not by shape: `default`, `bold`, `italic`,
  `underline`, `fixed-pitch`, `variable-pitch`, `mode-line`,
  `mode-line-active`, `mode-line-inactive`, `mode-line-highlight`,
  `mode-line-buffer-id`, `header-line`, `region`, `highlight`, `isearch`,
  `isearch-fail`, `lazy-highlight`, `minibuffer-prompt`, `error`,
  `warning`, `success`, `shadow`, `link`, `trailing-whitespace`,
  `show-paren-match`, and the `font-lock-*` family. Every name in that
  list is `faces.el`'s or `isearch.el`'s and can be checked against them;
  the `font-lock-*` family is named here because ported Elisp refers to
  it, and defined in the plan that does font-lock.

**Where the realization lives.** Emacs realizes per frame. Our frame record
has no slot for it, and the choice is between a slot and a table keyed by
frame, the way buffer-local slots are a weak table beside the buffer
(`buffer.sld`'s note about `buffer-slots-table`). A table is the smaller change and
the same precedent; a slot is what Emacs has. Decide in this step and
write the reason down.

**Not parameters.** `*tab-width*` and `*search-highlight*` are parameters
standing in for buffer-local and frame-local state, which was the
convention before `buffer.sld` existed. Faces should not add more: the
`face` property is text state and the realization is frame state, and both
now have somewhere proper to live.

### C. Realizing a face on a terminal — `xfaces.c` → `editor/xfaces.sld`

**Done — see the section above.**

The smallest layer, and mostly a table.

**What it owes.** The mapping from a face's attributes onto what the
terminal can show — bold, underline, reverse, italic-if-available, and a
colour pair — dropping everything else. Emacs's `xfaces.c` does this in
`tty_face_1` / `realize_tty_face`, and asks the terminal in
`tty_capable_p`; the C is worth reading before writing this, but it is not
in this repo, so read it from the installed Emacs's source if available
and otherwise from the behaviour of `tty-type` / `tty-display-color-p` in
a real Emacs.

**The half ncurses already answers.** "What can this terminal do" is
largely `has_colors`, `COLORS`, `can_change_color`, and `tigetstr` for
italics — ncurses reads terminfo for us. So this layer is the fold-down
rule plus a cache, not a terminal interrogation.

**Colours.** A colour attribute has to become a `COLOR_PAIR` index, so
this layer owns `init_pair` and the pair cache. The `default` face's
`:background` / `:foreground` are the frame's colours: on a terminal
either the terminal's own default, or a pair applied to the whole frame.

### D. The display — `xdisp.c`'s face lookup + `term.c`'s `turn_on_face`

**Done but for the run walk — see the section above.**

**What it owes.**

- `face_at_buffer_position`: at a buffer position, merge into one realized
  face the `face` property (a name, a face, or a list of faces), any
  overlays, and `default`, resolving `:inherit`. Cached, because it runs
  per character.
- Emit attributes around each run of characters sharing a face. The
  primitives exist — `attr-on!` / `attr-off!` with `A_BOLD` / `A_REVERSE`
  (`xdisp.sld:396-404`, `500-505`) — so what is missing is *deriving* them
  from a face instead of from a special case, plus `COLOR_PAIR` for
  colour.
- Faces for the chrome: the mode line (`mode-line` when its window is
  selected, `mode-line-inactive` otherwise), the echo area
  (`minibuffer-prompt`, `error`), and the region.

## Order

1. **A** — text properties, engine root and shift-on-edit, `textprop.sld`,
   with the interval semantics above under test. Nothing else can start.
2. **B** — `faces.sld`: the registry, the spec evaluator, `:inherit`, and
   the standard faces, with a test that an inherited attribute tracks a
   change to the inherited-from face.
3. **C** — the tty fold-down and the colour-pair cache.
4. **D** — `face_at_buffer_position`, then the two existing hardcoded
   highlights become real faces: `*search-highlight*` becomes the `isearch`
   and `lazy-highlight` faces, and the mode line's `A_REVERSE` becomes
   `mode-line` / `mode-line-inactive`.

Step 4 is the smallest end-to-end slice that exercises the whole stack —
property → face → realization → attribute — and it is a *replacement* of
two things that already work, so a regression is visible immediately.

Then, in order of what they unblock: `Buffer-menu--pretty-name` and the
tabulated-list row faces; `region` and the mark; `minibuffer-prompt`; the
header line, which retires the titles-in-text substitution; and the faces
that belong to a mode rather than to `faces.el`, such as `hl-line.el`'s
`hl-line`.

## Not in this plan

**`font-lock`.** It is the biggest consumer of faces and the obvious thing
to want, but faces are necessary and not sufficient: it needs syntax
tables and `parse-partial-sexp` (`syntax.c`), plus `font-lock.el`'s own
keyword machinery and `jit-lock`. It gets its own plan after this one.

**Overlays.** `overlays.c` is a second source of the `face` property, and
`face_at_buffer_position` merges from both. Step D should be written so
that adding overlays later is a second source in one function rather than
a rewrite, but overlays themselves are not in this plan.

**`display` properties, `:box` on a tty, `:height`, custom themes.**
Out of scope; noted so that their absence is a decision rather than an
oversight.

## Verification

The habits that have been finding the real bugs on this project, applied
here:

- `tools/syntax-check.scm` after every scripted edit to a `.sld`.
- `tools/check-missing-imports.py` after any edit that adds a name — the
  unbound-variable-at-run-time class, which has recurred repeatedly and
  which faces will trigger (many small names, several libraries).
- A unit test for the interval semantics that are easy to get wrong and
  invisible until later: `add-text-properties` merging rather than
  replacing; properties surviving an insert in the middle; insertion
  inheritance; `rear-nonsticky`.
- A pty check, because the unit suites never render. This is the project's
  established split and faces are entirely a rendering feature: the check
  should assert on the *screen's* attributes, not on the face object —
  the existing `isearch-highlight` check already sets the precedent by
  asserting on bold and reverse in the output.
- The whole battery before calling a step done: the two suites,
  `run-tests.scm`, `build.scm`, the pty battery, and the three Python
  checks.
