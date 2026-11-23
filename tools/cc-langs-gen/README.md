# Generating `cc-langs.scm` from Emacs's `cc-langs.el`

`schemacs/progmodes/cc-langs.scm`'s language-data block is Emacs's own
`c-lang-defconst`/`c-lang-defvar`/`c-lang-setvar` sequence translated
form for form, in file order. These scripts do that translation.

    CC_LANGS_SRC=/path/to/lisp/progmodes/cc-langs.el \
      python3 tools/cc-langs-gen/translate.py      # -> $CCGEN_WORK/out.scm
    CC_LANGS_SRC=... \
      python3 tools/cc-langs-gen/assemble2.py      # -> $CCGEN_WORK/block.scm

`CCGEN_WORK` defaults to `/tmp/ccgen` (create it first). The result is
the block to paste into `cc-langs.scm` after the hand-written
`c-mode-syntax-table` constant; the six forms `translate.py` reports as
`UNSUPPORTED` are hand-written in `handports.py` and placed by
`assemble2.py` at their own point in the file order.

- `sexp.py` - an Elisp reader: strings and characters are decoded,
  `?x` literals handled, symbols may contain reader escapes
  (`c-per-\(-match`).
- `translate.py` - Elisp expression -> Scheme source. The rules are
  documented in the header comment it writes into the block (nil is
  `#f`, tests are `%c-true`, `:test 'string-equal` becomes
  `:test string-equal`, `substring`/`length`/`string` are the `%`
  spellings, `1+` is `(+ x 1)`, ...).
- `handports.py` - the six imperative forms, plus the `c-filter-ops`
  procedure and `c-kwds-lang-consts`, as Scheme source text.
- `assemble2.py` - interleaves generated text and hand ports in the
  original file order and skips the forms already hand-ported in
  `cc-langs.scm` (`c-mode-syntax-table`, `c-make-mode-syntax-table`)
  and the two that are not carried (`c-mode-menu`, `c-keywords-obarray`).

After regenerating, run the differential in `tools/cc-langs-diff/`.
