# The easymenu conversion differential

Compares `easy-menu-convert-item` - the function every `easy-menu-define`
item goes through - plus `easy-menu-always-true-p` and
`easy-menu-name-match`, with GNU Emacs 31.1's, on the same 18 item
specs: simple items, `:keys` (with and without the `\[cmd]` markup),
`:active`/`:enable`, `:visible` nil and t, `:style toggle`/`radio`/
`button` with `:selected`, `:label` as a string and as a form, `:suffix`
as a string and as a symbol, `:help`, `:key-sequence`, separators and
plain strings.

    emacs -Q --batch -l tools/easymenu-diff/emacs-easymenu.el > /tmp/em.out
    guile --no-auto-compile -L . -L "${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0" \
      -s tools/easymenu-diff/ours-easymenu.scm > /tmp/our.out
    diff /tmp/em.out /tmp/our.out

Both sides print the conversion with the same canon: symbols by name,
strings with `prin1`/`write`, vectors as `[...]`, improper tails shown
(`(:toggle . my-var)`), procedures as `proc`. The printed forms are
compared rather than the values because Elisp's nil is both `#f` and
`'()` here, and `(cons key nil)` is `(key)` there but `(key . #f)` here.

`schemacs/editor/easymenu-tests.scm` pins these answers in the suite
runner.
