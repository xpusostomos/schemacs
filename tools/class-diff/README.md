# The character-class differential

`regex-emacs.c`'s class macros (`regex-emacs.c:107-153`) are what decide
`[[:alpha:]]`, `[[:space:]]`, `[[:word:]]` and the rest. They are not
Unicode predicates: several read the current buffer's case tables or
its syntax table, and the rest have their own rules. This directory
compares every class on a boundary set of characters between Emacs 31.1
and this tree.

## Running it

From this directory (both scripts read `chars.txt`):

    emacs -Q --batch -l emacs-classes.el > emacs.txt
    guile --no-auto-compile -L ../.. -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
          -s ours-classes.scm > ours.txt
    diff emacs.txt ours.txt

The answer is **zero differences** on the tree that ported the macros
(2026-11-26): 43 characters x 17 classes x case folding on and off =
1,462 answers.

## What each side does

Both sides match each character as a **multibyte string** with
`string-match`, with `case-fold-search` bound on and off. The Emacs
side does it inside `with-temp-buffer`, because `string-match` reads
the *current buffer's* syntax table for `[[:space:]]`, `[[:word:]]`
and `[[:punct:]]` - and in batch Emacs the current buffer is
`*scratch*`, whose lisp-interaction-mode makes newline a comment ender
rather than whitespace, which is a harness difference and not an
engine one. This tree has no current buffer in a bare script and
falls back to its standard syntax table, which is what a fresh buffer
has.

The characters are the boundaries where the rules change: ASCII
letters/digits/punctuation, tab, newline, CR, FF, space, DEL, 0x80,
0x9F, no-break space, soft hyphen, Latin-1 e-acute, a combining mark,
category representatives (`Lm`, `Lo`, `Lt`, `Nl`, `Nd`, `No`, `Sc`,
`Sm`, `Pi`, `Pf`, `Cf`, `Zl`, `Zp`, `Zs`), private use, noncharacters,
U+10FFFF, supplementary-plane letters and digits, and an emoji.
