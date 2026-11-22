# The cc-engine declarator differential

Compares the declarator tranche of `schemacs/editor/cc-engine.scm` with
Emacs 31.1 at every position of three fixtures.

    # C++ (both the older fixture and the requires/lambda one), in C++ mode
    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl.el \
        emacs-fixture.cpp.out tools/cc-decl-diff/fixture.cpp
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl.scm ours-fixture.cpp.out tools/cc-decl-diff/fixture.cpp
    diff emacs-fixture.cpp.out ours-fixture.cpp.out

    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl.el \
        emacs-decl.cpp.out tools/cc-decl-diff/fixture-decl.cpp
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl.scm ours-decl.cpp.out tools/cc-decl-diff/fixture-decl.cpp

    # C, in C mode (the -c files are the same harness with c-mode/c++)
    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl-c.el \
        emacs-fixture.c.out tools/cc-decl-diff/fixture.c
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl-c.scm ours-fixture.c.out tools/cc-decl-diff/fixture.c

Twenty-five probes per position, `c-found-types` cleared before each:
the eleven declarator probes (`c-forward-declarator` with no arguments
and with `(point-max) t t`, `c-forward-decl-arglist` with both argument
shapes at every `(`, `c-forward-primary-expression` in both shapes,
`c-forward-constraint-clause`, `c-forward-c++-requires-clause`,
`c-in-id-arglist`, `c-forward-class-decl`,
`c-back-over-member-initializer-braces`) and fourteen declaration
probes: `c-forward-decl-or-cast-1` (context `top`, PRECEDING-TOKEN-END
`(max point-min (1- pos))`), `c-at-toplevel-p`,
`c-just-after-func-arglist-p`, `c-looking-at-c++-lambda-expression`,
`c-backward-over-lambda-expression`, `c-looking-at-statement-block-1`,
`c-looking-at-statement-block`, `c-looking-at-decl-block`,
`c-directly-in-class-called-p` (with the name "C"),
`c-search-uplist-for-classkey` of `(c-parse-state)`,
`c-back-over-member-initializers`, `c-do-declarators`,
`c-forward-objc-directive`, and `c-parse-state`'s caller above.

**The five probes whose functions document a precondition are guarded
on it**, on both sides and in the same way: `c-looking-at-statement-
block(-1)`, `c-looking-at-decl-block` and
`c-backward-over-lambda-expression` run only at a `{`, and
`c-looking-at-c++-lambda-expression` only at a `[`. Their docstrings
say "point is at an opening brace" (or the `[` of a capture list) and
Emacs's own callers never call them elsewhere; probing other
characters tests unspecified behaviour and the two sides may diverge
there for reasons that are not departures. `c-forward-decl-or-cast-1`
and `c-do-declarators` have no such precondition and are probed
everywhere.

A probe that signals is recorded as `error` and its position, so an
error must happen at the same positions on both sides - the C-mode
inputs rely on it (Emacs signals in `c-forward-primary-expression`
there, and the port must too).

Each line is `TAG POS RESULT POINT`. The dumps agree **byte for byte**
with no normalisation: the Scheme printer renders `#t` as `t`, `#f` and
`'()` as `nil`, and characters as their code points, which is how
Elisp's `prin1` renders them. Current result: all three fixtures
identical - 6,480 answers for the C fixture, 10,944 for the old C++
fixture and 14,208 for `fixture-decl.cpp`, 31,632 in all.

**A test that probes one long-lived buffer is not measuring this.**
cc-mode caches in text properties (`c-is-sws`, `c-in-sws`, the
`<>`-as-paren markers), so an answer can depend on what was probed
before it; both sides here see the same history, and the expectations in
`cc-engine-tests.scm` are Emacs's one-probe-per-fresh-buffer answers
instead.
