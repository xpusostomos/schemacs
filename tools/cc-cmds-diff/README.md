# cc-cmds differential: `c-indent-region` against Emacs

This harness runs the same whole-buffer `c-indent-region` on both sides
and compares the resulting text byte for byte:

    emacs -Q --batch -l tools/cc-cmds-diff/emacs-cmds.el STYLE FILE OUT [cpp]
    guile --no-auto-compile -L . -L "$SITE" -s tools/cc-cmds-diff/ours-cmds.scm STYLE FILE OUT [cpp]

`cpp` selects `c++-mode` on both sides; without it both use `c-mode`.
Run it over the fixtures in `tools/cc-decl-diff/`,
`tools/cc-cgbs-diff/` and `tools/cc-align-diff/` under the style list
the cc-align differential uses (gnu, linux, k&r, bsd, stroustrup,
whitesmith, ellemtel, java, python).

## Where it stands (2026-11-23)

**75 of 99 fixture/style pairs are identical.** The 24 that differ are
all on `fixture-align.c`, `fixture-align.cpp` and `fixture-qt.cpp`, and
the cause is not the indentation arithmetic: `c-indent-line` computes
the same indentation as Emacs (the `tools/cc-indent-diff/` per-line
table agrees on every line), and the divergence appears only where a
line's **reindentation feeds the next line's parse**.

`c-indent-line` edits the buffer, and cc-mode keeps caches that those
edits invalidate - the literal-position cache (`c-lit-pos-cache`), the
parse-state cache (`c-state-cache`) and the syntactic-whitespace
properties. The functions that invalidate them are `cc-mode.el`'s
`c-before-change` and `c-after-change`, put on
`before-change-functions`/`after-change-functions` by
`c-basic-common-init`; **neither is ported yet**, so a replay that
indents line after line reads the caches the previous edit left.

The diagnosis was confirmed by simulation: a per-line loop that calls
`c-truncate-lit-pos/state-cache` and `c-invalidate-state-cache` after
each `c-indent-line` makes `fixture-align.c` identical, and the same
loop still differs on `fixture-qt.cpp`'s access labels - which is
expected, because cc-mode's invalidation runs *before* the change
(`c-before-change`, with the change's BEG) as well as after, and the
order matters to the syntactic-whitespace ladder.

So the gate for the rest of cc-cmds' indentation verification is the
`cc-mode.el` change-function tranche. Until it lands, `cc-cmds-tests.scm`
tests one edit per fresh buffer, which is the case the caches cannot
get wrong.
