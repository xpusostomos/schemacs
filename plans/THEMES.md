# Omarchy themes: how they are made, and what is still not ported

Recorded 2026-11-09, after re-porting the theme set from a fresh
omarchy.el pull and adding a converter for the themes omarchy.el does not
ship.

## What Omarchy ships

`/usr/share/omarchy/themes/<slug>/` holds either

- a full theme, with `colors.toml` **and** a `neovim.lua` naming its own
  Neovim colorscheme (14 of the 24 on this machine), or
- a palette only, `colors.toml` and no Neovim scheme (10, including
  `jade-horse` and `starship`).

`colors.toml` is the canonical colour vocabulary - 25 keys: `mode`,
`accent`, `selection`, `muted`, the four backgrounds, the four
foregrounds, `red`/`yellow`/`orange`/`green`/`cyan`/`blue`/`magenta`/
`brown`, and the six `bright_*`. Omarchy hands those keys straight to
`aether.nvim` in `default/themed/neovim.lua.tpl`; the template is the
**fallback** for a palette-only theme, not a generator, and aether is one
fixed scheme whose palette is parameterised. A theme that ships its own
`neovim.lua` never uses the template.

So Omarchy has two things, and so does this tree:

| Omarchy | here |
|---|---|
| a per-theme Neovim scheme | `themes/<name>-theme.scm` produced from omarchy.el's hand-tuned palette |
| `aether.nvim` + `colors.toml` | `tools/convert-omarchy-colors.scm` + `colors.toml` |

## How omarchy.el gets its colours

omarchy.el **does not read `colors.toml` at run time**. Each
`themes/<name>-theme.el` hard-codes a Modus *palette partial* and a
*semantic mapping* and calls `modus-themes-theme`, which expands them
through `modus-themes-generate-palette` and `modus-themes-faces` into
~2,355 `custom-theme-set-faces` entries.

For a palette-only theme the partial is mostly a literal transcription of
the `colors.toml` values (ristretto's `red`/`yellow`/`green`/`cyan`/
`blue`/`magenta` and all six `bright_*` match the file exactly), but the
surface shades and the diff tints are hand-derived, because `colors.toml`
has no `bg-alt`/`bg-active`/`bg-inactive` and no diff colours at all.

The mapping is mostly mechanical; the majority answer across omarchy.el's
22 themes (counts in brackets) is:

| slot | colors.toml key |
|---|---|
| `bg-main` | `background` (19) |
| `bg-active` | `selection` (12) |
| `bg-alt`, `bg-completion`, `bg-hl-line`, `bg-hover-secondary` | `lighter_background` (10) |
| `bg-dim` | `dark_background` (4) / `darker_background` (7) |
| `bg-inactive` | `darker_background` (10) |
| `border` | `muted` (13) |
| `fg-main`, `operator`, `variable`, `identifier` | `bright_foreground` (11) |
| `fg-alt` | `light_foreground` (12) |
| `fg-dim`, `comment`, `fg-mode-line-inactive` | `dark_foreground` (6-11) |
| `keyword`, `rx-construct` | `bright_magenta` (8) |
| `fnname`, `name` | `bright_blue` (7) |
| `type`, `constant` | `bright_yellow` (8-9) |
| `number`, `builtin` | `orange` (5) |
| `string`, `docstring`, `success` | `bright_green` (9) |
| `property`, `note` | `bright_cyan` (7) |
| `punctuation` | `light_foreground` (8) |
| `err` | `bright_red` (14) |
| `warning` | `bright_yellow` (10) |
| `info`, `link`, `prompt` | `blue`/`bright_blue` (7-9) |
| `link-symbolic` | `cyan`/`bright_cyan` (6) |
| `bg-region`, `bg-paren-match`, `bg-hover`, `bg-search-lazy` | `selection` (10-12) |
| `bg-search-current` | `yellow` (6) |
| `bg-mode-line-active` | `selection` (7) |
| `bg-mode-line-inactive` | `background` (5) |
| `fg-line-number-inactive` | `muted` (10) |
| `bg-line-number-active` | `lighter_background` (10) |

Where the themes disagree, a single rule cannot match any of them: the
hand-tuned files encode each scheme's own choices (gruvbox maps
`keyword` to its red and `function` to its green; ristretto's "blue" key
is really its orange accent).

**Measured**, ristretto generated from this table against omarchy.el's
hand-tuned file: 2,355 faces in both, 1,332 identical specs, **1,023
different**; even `default :foreground` differs (`#e6d9db` from
`colors.toml` vs `#fff1f3`, a value not in the file). The generic route
is an approximation, by design.

## The two converters

- `tools/convert-omarchy-themes.py` - omarchy.el's `themes/*.el` to this
  tree's expanded `.scm`. It runs a real Emacs (which needs
  `modus-themes` on the load path) and transcribes the `theme-settings`
  that `modus-themes-theme` produced. Run after pulling omarchy.el; all
  22 files are its output.
- `tools/convert-omarchy-colors.scm` - one Omarchy theme, named on the
  command line, from `colors.toml` to this tree's `.scm`:

      guile -L . -s tools/convert-omarchy-colors.scm jade-horse
      guile -L . -s tools/convert-omarchy-colors.scm starship --out DIR

  It builds the palette and mappings from the table above, writes a
  temporary `-theme.el`, expands it through Modus in a real Emacs, and
  reads the result back as Scheme syntax. Diff backgrounds are blended
  from the theme's own green/red/yellow and its background; light themes
  use `modus-themes-operandi-palette` (omarchy.el's flexoki-light uses
  the *tinted* base instead).

  After generating a theme, add its display name to `omarchy-theme-map`
  in `schemacs/external/omarchy/omarchy.scm`, or `omarchy-init` cannot
  resolve it from `omarchy-theme-current` (the hook passes the slug and
  would work without the entry; startup passes the display name).

## What is generated today

All 24 system themes are covered:

- 22 from omarchy.el, re-generated from the 2026-11-09 pull (syntax
  colours aligned with Omarchy 4's Neovim schemes, numbers coloured,
  `fg-added` no longer the string green);
- `jade-horse` and `starship` from `convert-omarchy-colors.scm` - the two
  Omarchy themes omarchy.el does not ship;
- the system's `catppuccin` is the Mocha palette, and maps to the
  bundled `catppuccin-mocha`.

## The unported primitive: modus-themes

`modus-themes-theme` / `modus-themes-generate-palette` are **not
ported**. This is a departure from the tree's bottom-up rule: omarchy.el
calls them, so porting omarchy.el strictly means porting them first. The
theme files are the generator's *output*, checked in as data, and every
file header says so. The scope question ("port 3.8k lines, or transcribe
the output?") was never put to the user at the time.

What the port would take, measured from `etc/themes/modus-themes.el`
(7,791 lines):

| part | lines |
|---|---|
| `modus-themes-generate-palette` | 216 |
| `modus-themes-theme` driver | ~50 |
| colour arithmetic (`adjust-value`, `contrast`, `blend`, warmer/cooler, dark/warm predicates, palette lookup) | ~150, 10 defuns |
| `modus-themes-faces` | 2,752 (2,223 `,c` display-class refs, 48 `modus-themes--` calls) |
| base palettes (operandi/vivendi, ± tinted) | 326 each |

`modus-themes` is not in Emacs's `lisp/`; it is a package bundled in
`etc/themes` (Version 5.3.0 here, upstream protesilaos/modus-themes).
Porting it would let each theme file shrink from **228 KB / ~2,360
lines** to its upstream shape - **~150 lines** of palette partial and
mappings - and generate at load, with no Emacs needed for a new theme.
The existing converter then becomes the golden-output test: our
generator's settings compared against Emacs's, per theme.

That is the recommended next step if the bottom-up rule is to be
applied here; it is a bounded project (~800 lines of logic plus the
transliterated face catalogue and palette data), not the "tens of
thousands of lines" an earlier note claimed.
