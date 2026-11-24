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

## The defun-movement differential (2026-11-24)

A second pair of harnesses covers `cc-cmds.el:1569'-`:2426' and
`c-indent-defun':

    emacs -Q --batch -l tools/cc-cmds-diff/emacs-defuns.el FILE OUT [cpp]
    guile --no-auto-compile -L . -L "$SITE" \
        -s tools/cc-cmds-diff/ours-defuns.scm FILE OUT [cpp]

At **every position** of FILE it records
`c-where-wrt-brace-construct', `c-in-function-trailer-p',
`c-defun-name', `c-cpp-define-name', `c-declaration-limits' (NEAR nil
and t), `c-defun-name-and-limits', `c-beginning-of-defun' and
`c-end-of-defun' (final point and return), and `c-indent-defun'
(the whole resulting text, newlines written as `|'). It is identical
on `fixture-defuns.c', `fixture-defuns.cpp', `fixture-indent.c',
`fixture.c', `fixture-knr.c', `fixture-label.c', `fixture-brace.c',
`fixture-brace.cpp', `fixture.cpp' and
`../cc-cgbs-diff/fixture-cgbs.c' - every position, both languages.

Two things the schemacs side must do that are not obvious:

* **import `(schemacs progmodes cc-align)`** - the gnu style's
  `c-gnu-impose-minimum' lives there, and without it labels stay in
  column 0 where Emacs moves them to 1;
* **`c-indent-defun` runs in a fresh buffer per position**, because it
  edits and the change hooks that invalidate cc's caches arrive with
  `cc-mode.el'; the read-only probes share one buffer, as they can.

## The statement/sentence/conditional differential (2026-11-24)

A third pair covers `cc-cmds.el:2429'-`:3531':

    emacs -Q --batch -l tools/cc-cmds-diff/emacs-stmt.el FILE OUT [cpp]
    guile --no-auto-compile -L . -L "$SITE" \
        -s tools/cc-cmds-diff/ours-stmt.scm FILE OUT [cpp]

Twenty-two probes at every position: `c-beginning-of-statement` and
`c-end-of-statement` (count 1, sentence-flag nil and t),
`c-back-over-illiterals`, `c-forward-over-illiterals` (both
ALLOW-EARLY-STOP values), `c-ascertain-preceding/following-literal`,
`c-after-statement-terminator-p`, `c-one-line-string-p`, the four
sentence movers (when `c-literal-limits` names a literal),
`c-comment-indent`, `c-outline-level`, `c-in-comment-line-prefix-p`,
and `c-scan-conditionals` in four shapes.

It is identical on `fixture-stmt.c`, `fixture-stmt.cpp`,
`fixture-defuns.c`, `fixture-knr.c`, `fixture-label.c`,
`fixture-brace.c`, `fixture-brace.cpp` and `fixture.cpp`, every
position, both languages.

Two things about it:

* **the record layout is `FIELD=VALUE` pairs, not lists**; compare with
  `diff` after both sides have written `nil` for Emacs's nil;
* **the `c-scan-conditionals` fields are order-dependent** - Emacs
  itself errors on some of them when they run after the other probes
  where a fresh Emacs returns a position. Both sides agree on every
  record, and the clean scanner table is pinned separately in
  `test/progmodes/cc-cmds-test.scm`.

The Emacs harness's `lit-probe` wrapper must not name its thunk
parameter `thunk` when `probe` also has a parameter of that name: with
dynamic binding the wrapper's `thunk` becomes the wrapper itself and
the call is a wrong-number-of-arguments error. It is `fun` in
`emacs-stmt.el`.
