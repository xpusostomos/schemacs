# The indentation differential

Compares this tree's `c-guess-basic-syntax' + `c-get-syntactic-indentation'
- the two halves of `c-indent-line' below the line shifting - with GNU
Emacs 31.1's, line by line, on the same text under the same style. Both
sides print `(POSITION COLUMN)` at every line start; `diff` them.

    emacs -Q --batch -l tools/cc-indent-diff/emacs-indent.el STYLE FILE > /tmp/em.out
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
      -s tools/cc-indent-diff/ours-indent.scm STYLE FILE > /tmp/our.out
    diff /tmp/em.out /tmp/our.out

For C++ use `emacs-indent-cpp.el` and add `cpp` as the third argument on
our side (it opens the file in `c++-mode` and marks the `<>` pairs as
`c-common-init` does).

STYLE is any of the built-in styles (`gnu`, `k&r`, `bsd`, `stroustrup`,
`whitesmith`, `ellemtel`, `linux`). Because a style selects the line-up
functions an offset names, a run over the styles is what exercises
`cc-align.el`; the gnu style alone uses about half of it.

Fixtures: `tools/cc-cgbs-diff/fixture-cgbs.c` and everything under
`tools/cc-decl-diff/`. The harnesses replay `c-common-init` as the other
differentials do.
