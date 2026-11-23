# The `c-guess-basic-syntax' differential

Compares this tree's syntactic analysis with GNU Emacs 31.1's, line by
line, on the same text. Both sides print `(POSITION SYNTAX)` per line
start; `diff` them.

    emacs -Q --batch -l tools/cc-cgbs-diff/emacs-dump.el FILE > /tmp/em.out
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
      -s tools/cc-cgbs-diff/ours-dump.scm FILE > /tmp/our.out
    diff /tmp/em.out /tmp/our.out

For C++ use `emacs-dump-cpp.el` and `ours-dump-cpp.scm` (they open the
file in `c++-mode' and, on our side, mark the `<`/`>` pairs with
`c-restore-<>-properties' as `c-common-init' does).

The harnesses replay what `c-mode' does in `c-common-init': the language
variables, the syntax table, the gnu style, `c-clear-found-types' and the
two noise-macro regexp builders (the mode's `:after-hook'). They do
**not** need the `<>` category properties stripped, unlike
`tools/cc-decl-diff/`: `c-guess-basic-syntax` runs after the mode's
font-lock preprocessing on both sides.

Fixtures: `fixture-cgbs.c` here, plus the C and C++ fixtures under
`tools/cc-decl-diff/`. All of them are identical at the time of
writing.
