# The electric-command differential

The gate for the electric-key tranche of `cc-cmds.el` (`:409-:1568`):
every `c-electric-*` command, the `c-hanging-*` machinery they drive
(`c-point-syntax`, `c-brace-newlines`, `c-try-one-liner`,
`c-do-brace-electrics`) and the two hungry deletes. Each scenario runs
one command in a real `c-mode`/`c++-mode` buffer on both sides and
compares the whole buffer text and point.

## Running it

From the tree root:

    SITE=${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0
    cd tools/cc-electric-diff
    emacs -Q --batch -l emacs-electric.el -- scenarios.tsv > /tmp/em-electric.out
    guile --no-auto-compile -L ../.. -L "$SITE" -s ours-electric.scm \
        scenarios.tsv > /tmp/ours-electric.out
    python3 compare.py /tmp/em-electric.out /tmp/ours-electric.out

`compare.py` exits 0 when every difference is in `known.txt`.

## The result

**60 scenarios, 0 different, 1 known.** The scenarios cover:

- `c-electric-brace`: a defun, an `if`, a `struct`, auto-newline on
  and off, a numeric ARG, `c-electric-flag` off, every applicable
  `c-cleanup-list` entry (`empty-defun-braces`, `one-liner-defun`,
  `brace-elseif-brace`, `brace-catch-brace`, `brace-else-brace`,
  `defun-close-semi`, `compact-empty-funcall` and their neighbours),
  the `c-hanging-braces-alist` customizations, an unclosed string, and
  C++ variants;
- `c-electric-semi&comma` in code, inside a paren list, with a numeric
  ARG and with `list-close-comma`;
- `c-electric-colon`: labels, the scope operator, a bitfield,
  `c-hanging-colons-alist`, C++ `namespace`/`class`;
- `c-electric-slash`/`c-electric-star` in comments and code;
- `c-electric-pound` with `alignleft`;
- `c-electric-paren` with `space-before-funcall` and
  `compact-empty-funcall`;
- `c-electric-backspace`/`c-electric-delete-forward` with and without
  `c-hungry-delete-key` (and the two hungry commands directly);
- `c-electric-lt-gt` on `#include` delimiters and in expressions;
- `c-electric-continued-statement` with `else`, `do`, `while` and a
  macro tail.

## The scenario format

One tab-separated row, twelve columns:

    name  lang  command  key  arg  auto  hungry  electric  synind  point  cleanups  text

- `lang` - `c` or `cpp` (the fixture is opened in `c-mode`/`c++-mode`);
- `command` - the procedure name, one of the thirteen in
  `commands` in `ours-electric.scm`;
- `key` - `last-command-event`, as the integer the keyboard produces;
- `arg` - `nil`, `none` (the command is called with no argument) or an
  integer;
- `auto`/`hungry`/`electric`/`synind` - the four state variables,
  1/0;
- `point` - `end` or a buffer position;
- `cleanups` - `default` (the global `c-cleanup-list` is left alone)
  or a comma-separated list of symbols;
- `text` - the buffer, with `\n`, `\t` and `\\` escapes.

## The mode replay, on our side

`cc-mode.el` is not ported yet, so `fresh` does what
`c-basic-common-init` will: allocate a buffer, set `major-mode` and
`parse-sexp-ignore-comments`, run `c-init-language-vars` with the
literal mode symbol, install `(c-lang-const c-make-mode-syntax-table
...)`, `c-set-style "gnu"`, `c-clear-found-types`,
`c-make-noise-macro-regexps`, `c-make-macro-with-semi-re`, the
block-comment flag and `indent-line-function`. When cc-mode.el lands,
the harness should be re-pointed at the real mode and re-run.

## The change hooks are deliberately not installed

Emacs's `c-mode` runs `c-before-change`/`c-after-change` on every edit;
the port's are written and tested (see `cc-mode.scm`), but installing
them in this harness is something else:

- with them installed, the C++ brace scenarios raise inside
  `c-laomib-fix-elt` (`(cdr '())` where Emacs's `(cdr nil)` is nil) -
  a bug in the already-ported bracelist machinery that the electric
  path exercises but nothing had before. That is a separate cc-engine
  fix (its own tranche, with the differential re-run), and mixing it
  into this harness would make an electric bug indistinguishable from
  it;
- the one known difference below is *caused* by not installing them,
  so its status changes on the day they are installed.

## The one known difference: `brace-elseif`

`if (x) {\n  y;\n}\nelse if (z)\n` + `{`, with `c-auto-newline` on and
the `brace-elseif-brace` cleanup enabled: Emacs leaves the cursor at
column 3 (indentation 2 plus point one past the `{` position), ours at
2. **A static `c-indent-line` on the post-cleanup text gives 2 in both
editors** - Emacs's 3 comes from its `c-after-change` hooks running
between the cleanup's delete and its insert, while this harness's fresh
parse after the whole command gives the settled answer. So the
disagreement is the harness's missing hooks, not the command; it is
listed in `known.txt` with that reason, and it is the first scenario to
re-check when the hooks are installed.
