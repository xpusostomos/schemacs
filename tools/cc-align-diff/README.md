# The line-up function differential

Calls each `cc-align.el` function **directly** - the way a line-up
function is called, at a position with `c-syntactic-element' and
`c-syntactic-context` bound - in GNU Emacs 31.1 and in this tree, on the
same fixtures, and diffs the answers. It covers what the style sweeps in
`tools/cc-indent-diff/` do not reach: assignments, ternary bodies,
cascaded calls, string continuation, `c-lineup-argcont`, the gcc-asm
register, the one/multi-line blocks, the brace-list functions, the
templates and lambda, the Objective-C four, the semi&comma criteria and
`c-gnu-impose-minimum`.

    emacs -Q --batch -l tools/cc-align-diff/emacs-align.el \
      tools/cc-align-diff/fixture-align.c c > /tmp/em.out
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
      -s tools/cc-align-diff/ours-align.scm tools/cc-align-diff/fixture-align.c c > /tmp/our.out
    diff /tmp/em.out /tmp/our.out

For C++ use `fixture-align.cpp` with `cpp` as the second argument on
both sides.

A case is `(NAME FUNCTION SYM AT ANCHOR SECOND CTX...)`. Every position
is a **needle** - a substring of the fixture plus a character delta -
found in both buffers, so the two case tables are the same data without
position bookkeeping. `SYM`/`ANCHOR`/`SECOND` become the langelem
argument and `c-syntactic-element`: `(SYM . ANCHOR)` and
`(SYM ANCHOR SECOND)` - the second position is the arglist's open paren,
which is what `c-langelem-2nd-pos` reads. `CTX...` are `(SYMSYM NEEDLE
DELTA)` entries for `c-syntactic-context`. The contexts are the ones a
running Emacs's own `c-guess-basic-syntax` gives at those positions; a
few are deliberately synthetic (the semi&comma criteria take no
langelem), and where Emacs raises on the synthetic call both sides
print `error`.

`schemacs/editor/cc-align-tests.scm` pins these answers in the suite
runner.
