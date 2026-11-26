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

## Results on the settled tree (2026-11-26)

**The schemacs replay now installs the mode's change hooks and (for C++)
the `<>' properties**, which is what `(funcall mode)' does on the Emacs
side through `c-common-init`. Without them a command that edits twice
sees stale cc-mode caches and the multi-line `#define' transient came
out differently (the earlier README listed positions 949-950 and
953-954 among the differences; they match now).

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
  `c-context-open-line` on `fixture-fill.cpp`: **identical at every
  position** (the two `c-context-open-line` positions the earlier
  README listed, 108 and 158, are gone - the change-hook install and
  the `<>'-property restore fixed them; `fixture-transient108.cpp' and
  the indentation differential are green too).
* … on `fixture-fill.c`: identical except three positions inside the
  multi-line `#define`'s braced body (955, 956 and 968), where
  `c-indent-new-comment-line`'s "temporarily insert another line break"
  state leaves the continuation line at column 2 where Emacs puts it
  at 6. The two runs' **buffer text, point, narrowing, text
  properties, `c-parse-state`, `c-macro-start`/`c-macro-cache` and the
  literal cache are identical at the guess** (dumped and compared),
  but `c-guess-basic-syntax` answers `((topmost-intro-cont 951))' here
  where Emacs answers `((statement 955))'; a *fresh* buffer holding
  the same text answers `((statement-block-intro 951))' in **both**
  editors, so the difference depends on state the command has built up
  before the guess. Clearing our `c-macro-cache', `c-state-cache' and
  the `syntax-ppss' cache does not change either answer. This is the
  one remaining fill difference and is recorded as open.
* Return values: after `c-indent-new-comment-line`'s tail `if` grew an
  explicit `#f` else, no nil/unspecified differences remain; the two
  sides print markers differently (`#<marker (moves after insertion)
  in no buffer>' versus the record's fields - same object), which the
  comparison script normalises.

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
