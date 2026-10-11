The part I'd call the real win: **`define-key` is `Fdefine_key`'s loop now** — it builds genuine prefix maps, descends into keymap-valued bindings, and refuses a non-prefix *by name*. That's what let both flat spellings go, and it's why `C-x RET` and `C-x 4` are submaps rather than sequences that happened to work.

## Not finished, each a decision rather than an oversight

1. **`t_ok` — the `t` default binding.** `access_keymap_1` keeps a `t_binding` so `(define-key map [t] 'foo)` gives a default for any key. My `access-keymap` is the *`noinherit`* half only. Nothing here binds `[t]` so it's unreachable — but by your own rule (*Emacs has it, so keep it*) it should be ported rather than dropped, and it's small: one more slot consulted after the table.

2. **Char tables proper.** The char-table slot holds a *procedure* with the range test inside it. Emacs has a real char table — ranges, `set-char-table-range`, `map-char-table`, inheritance. That's the one structural stand-in left in the keymap, and it's exactly why `self-insert-char-table` looks the way it does.

3. **`where-is-internal`** — mine is the reduced question (`keymap-lookup-binding-key`), not the full walk with `nomenu`/`firstonly`/`noindirect` and menu-binding dropping.

4. **Never ported, and still not:** `copy-keymap`, `keymap-canonicalize`, `map-keymap`, `describe-buffer-bindings`, the menu machinery, `key-translation-map` as a keymap walk, and `keymap.el` proper (`keymap-set`, `key-valid-p`, `key-parse`).

5. **`single-key-description`'s interval case** (a cons of two integers, what `map-char-table` produces) — named in the source as not ported.

