# The cc-langs constant differential

Compares every language constant of `schemacs/progmodes/cc-langs.scm`
against Emacs 31.1, for all seven languages.

    emacs -Q --batch -l tools/cc-langs-diff/ccdiff.el     # -> emacs-vals.txt
    guile --no-auto-compile -L . -s tools/cc-langs-diff/ours-dump.scm
                                                          # -> ours-vals.txt
    python3 tools/cc-langs-diff/compare.py

`ccnames.txt` is the constant list (our registry's names). The dumps
print a canonical form per answer; `compare.py` normalises characters
and code points to one integer class and compares lists **without regard
to order, recursively** - Emacs's own `c-kwds-lang-consts` is an obarray
walk, so keyword-list order is Emacs internals, not meaning. Strings -
which is what every regexp-valued constant is - are compared byte for
byte.

`ccdiff.el` reloads `cc-langs` after an error: Emacs's
`c-get-lang-constant` `makunbound`s a constant's symbol when a VAL
fails, which discards the source definitions for *every* language, so
without the reload one failure makes all later languages read as
failures too.

Current result: **2472 of 2478 identical; the 6 remaining are order-only
differences in `c-pre-lambda-tokens`** (set-equal). `compare.py` exits
0 for exactly that state.
