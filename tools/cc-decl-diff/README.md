# The cc-engine differential

Compares the ported tranches of `schemacs/editor/cc-engine.scm` with
Emacs 31.1 at every position of seven fixtures.

    # C++ (the older fixture, the requires/lambda one), in C++ mode
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

    # labels and K&R argument declarations (C mode)
    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl-c.el \
        emacs-label.c.out tools/cc-decl-diff/fixture-label.c
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl-c.scm ours-label.c.out tools/cc-decl-diff/fixture-label.c

    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl-c.el \
        emacs-knr.c.out tools/cc-decl-diff/fixture-knr.c
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl-c.scm ours-knr.c.out tools/cc-decl-diff/fixture-knr.c

    # Qt-style labels ("public slots:", "signals:"), C++ mode
    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl.el \
        emacs-qt.cpp.out tools/cc-decl-diff/fixture-qt.cpp
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl.scm ours-qt.cpp.out tools/cc-decl-diff/fixture-qt.cpp

    # brace lists and enums, both languages
    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl-c.el \
        emacs-brace.c.out tools/cc-decl-diff/fixture-brace.c
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl-c.scm ours-brace.c.out tools/cc-decl-diff/fixture-brace.c

    emacs -Q --batch -l tools/cc-decl-diff/emacs-decl.el \
        emacs-brace.cpp.out tools/cc-decl-diff/fixture-brace.cpp
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
        -s tools/cc-decl-diff/ours-decl.scm ours-brace.cpp.out tools/cc-decl-diff/fixture-brace.cpp

Thirty-five probes per position, `c-found-types` cleared before each:
the eleven declarator probes (`c-forward-declarator` with no arguments
and with `(point-max) t t`, `c-forward-decl-arglist` with both argument
shapes at every `(`, `c-forward-primary-expression` in both shapes,
`c-forward-constraint-clause`, `c-forward-c++-requires-clause`,
`c-in-id-arglist`, `c-forward-class-decl`,
`c-back-over-member-initializer-braces`), fourteen declaration
probes: `c-forward-decl-or-cast-1` (context `top`, PRECEDING-TOKEN-END
`(max point-min (1- pos))`), `c-at-toplevel-p`,
`c-just-after-func-arglist-p`, `c-looking-at-c++-lambda-expression`,
`c-backward-over-lambda-expression`, `c-looking-at-statement-block-1`,
`c-looking-at-statement-block`, `c-looking-at-decl-block`,
`c-directly-in-class-called-p` (with the name "C"),
`c-search-uplist-for-classkey` of `(c-parse-state)`,
`c-back-over-member-initializers`, `c-do-declarators`,
`c-forward-objc-directive`, and `c-parse-state`'s caller above - and ten
from the label/K&R tranche: `c-forward-label`, `c-in-knr-argdecl`,
`c-skip-conditional`, `c-after-conditional`,
`c-after-special-operator-id`, `c-backward-to-block-anchor`,
`c-backward-to-decl-anchor`, `c-search-decl-header-end`,
`c-beginning-of-decl-1` and `c-end-of-decl-1` - plus
`c-forward-decl-or-cast-1` again with PRECEDING-TOKEN-END
`(c-point 'bosws)`, which is the call `c-just-after-func-arglist-p`
makes - and nine from the bracelist tranche, the enum probes guarded on
a `{` as their docstrings require: `c-most-enclosing-decl-block`,
`c-cheap-inside-bracelist-p`, `c-backward-typed-enum-colon`,
`c-backward-over-enum-header`, `c-at-enum-brace`, `c-laomib-loop`,
`c-looking-at-or-maybe-in-bracelist`, `c-strip-conses` (of
`(c-parse-state)`) and `c-at-bracelist-p` at the brace
`c-most-enclosing-brace` finds.

**The probes whose functions document a precondition are guarded on
it**, on both sides and in the same way: `c-looking-at-statement-
block(-1)`, `c-looking-at-decl-block` and
`c-backward-over-lambda-expression` run only at a `{`,
`c-looking-at-c++-lambda-expression` only at a `[`, and the two anchors
only at a `{`. Their docstrings say "point is at an opening brace" (or
the `[` of a capture list) and Emacs's own callers never call them
elsewhere; probing other characters tests unspecified behaviour and the
two sides may diverge there for reasons that are not departures.
`c-forward-decl-or-cast-1`, `c-do-declarators`, `c-forward-label`,
`c-in-knr-argdecl` and the rest have no such precondition and are
probed everywhere.

A probe that signals is recorded as `error` and its position, so an
error must happen at the same positions on both sides - the C-mode
inputs rely on it (Emacs signals in `c-forward-primary-expression`
there, and the port must too).

Each line is `TAG POS RESULT POINT`. The dumps agree **byte for byte**
with no normalisation: the Scheme printer renders `#t` as `t`, `#f` and
`'()` as `nil`, characters as their code points, and a cons whose cdr is
`#f` as Elisp's proper list (`(cons 'same #f)` prints `(same)`), which
is how Elisp's `prin1` renders them. Current result: all eight
fixtures identical - 11,880 answers for the C fixture, 20,064 for the
old C++ fixture, 26,048 for `fixture-decl.cpp`, 6,952 for
`fixture-label.c`, 9,504 for `fixture-knr.c`, 4,708 for
`fixture-qt.cpp`, 10,472 for `fixture-brace.c` and 11,044 for
`fixture-brace.cpp`, 100,672 in all.

**A test that probes one long-lived buffer is not measuring this.**
cc-mode caches in text properties (`c-is-sws`, `c-in-sws`, the
`<>`-as-paren markers), so an answer can depend on what was probed
before it; both sides here see the same history, and the expectations in
`cc-engine-tests.scm` are Emacs's one-probe-per-fresh-buffer answers
instead.

The port side calls `c-make-macro-with-semi-re' after
`c-init-language-vars', as a real mode's init does; without it
`c-at-vsemi-p' is false for every `Q_OBJECT'-style line (the Qt fixture
catches this).

The harnesses have found three departures worth knowing about before
reading a diff: the `<>` category properties must be stripped from
Emacs's side (`remove-text-properties ... '(category nil syntax-table
nil)` with `inhibit-modification-hooks`), `find-file-noselect` puts a C
file in c-mode (use `fundamental-mode`-safe text or `c-mode`/`c++-mode`
explicitly), and `c-cast-parens` holds Emacs characters as integers, so
a comparison against `char-before` needs `char->integer` on our side.
