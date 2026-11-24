# The filling differential

Compares the filling half of `(schemacs progmodes cc-cmds)` -
`c-guess-fill-prefix`, `c-mask-paragraph`'s callers `c-fill-paragraph`
and `c-do-auto-fill`, `c-indent-new-comment-line`,
`c-context-line-break` and `c-context-open-line` - with GNU Emacs
31.1's, command by command, at **every position** of a fixture, in a
fresh `c-mode`/`c++-mode` buffer per position (these commands edit).
Both sides print `(POINT RET TEXT)` per command, with `|` standing for
a newline; `diff` them (normalize tabs first, Emacs prints a literal
tab where Scheme's writer prints `\t`).

Two pairs of harnesses:

    # c-guess-fill-prefix, four ways (plain, fill-prefix bound,
    # c-block-comment-prefix bound nonempty and empty)
    emacs -Q --batch -l tools/cc-fill-diff/emacs-guess.el FILE OUT [cpp]
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
      -s tools/cc-fill-diff/ours-guess.scm FILE OUT [cpp]

    # the four editing commands
    emacs -Q --batch -l tools/cc-fill-diff/emacs-fill.el FILE OUT [cpp]
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
      -s tools/cc-fill-diff/ours-fill.scm FILE OUT [cpp]

"cpp" as the third argument opens the fixture in `c++-mode` on both
sides. `fixture-guess.c`, `fixture-guess.cpp`, `fixture-fill.c` and
`fixture-fill.cpp` are the fixtures.

## Results on the settled tree (2026-11-24)

* `c-guess-fill-prefix`: identical at every position of all four
  fixtures, all four probes.
* `c-fill-paragraph`: text and return value identical at every
  position of both fill fixtures. Point differs at three positions of
  `fixture-fill.c` (794-796, the tail of a short `//` comment):
  Emacs leaves point at 797, the end of the refilled line, ours leaves
  it where it was. `fill-paragraph` called directly shows the same
  difference (Emacs at 787 on the same buffer, point moved to the end
  of the filled paragraph), so it is the tree's `fill-paragraph` point
  handling, not `c-mask-paragraph`.
* `c-indent-new-comment-line`, `c-context-line-break`,
  `c-context-open-line` on `fixture-fill.cpp`: identical except four
  `c-context-open-line` positions (101, 108, 158, 190), all where the
  command's inserted `x` splits a comment starter after the
  `c-lit-limits` snapshot, so the command's transient `c-indent-line`
  sees `/x` and `* block` text Emacs then classifies differently;
  `fixture-transient108.cpp` is the static state, and the indentation
  differential (`tools/cc-indent-diff/`) differs on it at position 110
  - Emacs `((topmost-intro-cont 107))` column 4, ours
  `((defun-block-intro 93) (statement-cont 93))` column 7.
* … on `fixture-fill.c`: identical text except the multi-line
  `#define`'s broken body lines (positions 946-970; 11-12 per command),
  where `c-indent-new-comment-line`'s "temporarily insert another line
  break" state makes Emacs's `c-guess-basic-syntax` answer
  `((cpp-define-intro) (statement 1))` and ours `((cpp-macro-cont 1))`.
  The command leaves the continuation line at column 2 where Emacs
  aligns it to the macro body. The backslash insertion/alignment
  itself matches (the `#define M(x) \` fixture lines are byte-identical
  once the break point is not inside the braced body), and
  `c-fill-paragraph` over the same lines is identical.
* Return values: after `c-indent-new-comment-line`'s tail `if` grew an
  explicit `#f` else, the remaining differences are nil/unspecified in
  the `#define` positions above (6 per run) and the two sides' *printed
  forms* of the markers both commands return (Emacs prints
  `#<marker (moves after insertion) in no buffer>`, Guile's record
  printer prints its fields - same object, same insertion type).

## Traps the harnesses paid for

* **Normalize tabs before diffing.** Emacs's `%S` prints a literal tab;
  Guile's `write` prints `\t`. `sed 's/\t/\\t/g'` both sides.
* **A fresh buffer per probe, not per position.** The commands edit;
  a second command at the same point would see the first one's text.
* **`*c-macro-start*` is a cache, and its kind is a trap.** It is a
  plain global in Emacs too (`(defvar c-macro-start 'unknown)`), and
  `c-query-and-set-macro-start` answers the stale value unless it is
  nil or a symbol - and `(symbolp nil)` is true in Elisp, so a nil
  cache is recomputed while a number is returned. The replay's
  `fresh-buffer` must not need to reset it for the differential to be
  meaningful, but a *unit test* that runs the plain-code case after the
  macro case has to reset it (`(parameterize ((*c-macro-start*
  'unknown)) ...)`) or it is testing Emacs's staleness, which is the
  same on both sides.
* **The fill differential needs `comment-multi-line` t.** `c-mode`
  sets it buffer-locally; ours is a parameter, so `ours-fill.scm`
  parameterizes it around each command.
