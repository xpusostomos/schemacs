# The `save-excursion` audit — and the departure it turned up

Chris, 2026-10-13: *"for all the functions we have that emacs also has, do
we have the same number of calls to save-excursion? If there are functions
where emacs calls save-excursion and we don't that's an important diversion
we should fix."*

`save-excursion` is the .el idiom for "point comes back", so a port that
drops it moves point where Emacs does not — exactly the kind of subtle
departure that shows up three screens away from its cause.

## Method

`tools/save-excursion-audit.py` (moved there from `/tmp`; see "Re-running"
below). For each `schemacs/editor/X.scm`, the `.el` it mirrors is found by
basename (`lisp/**.el`), and the two sides are matched by function name.

**Both sides are parsed by their own reader** — Emacs `read`s the `.el`,
Guile `read`s the `.scm`. A first pass used a hand-rolled paren matcher and
was wrong: it reported 31 `save-excursion`s in `query-replace-descr`, which
has none, because its span ran past the defun's end. The reader has no such
failure mode.

Libraries whose Emacs side is a `.c` file are skipped: the C idiom there is
specpdl (`record_unwind_current_buffer` / `unbind_to`), not `save-excursion`.

## Result

- **22** functions Emacs guards with `save-excursion` that we have and do
  not.
- **10** more where the counts differ.
- **156** Emacs functions using `save-excursion` that are not ported at all
  (not a departure — they simply do not exist yet).

### The 22, and why none of them is a dropped guard

Every structural case was read on both sides. They fall into two groups.

**The guard sits inside a branch we never ported:**

| function | branch |
|---|---|
| `Buffer-menu-{mark,delete,save,unmark}` | `outline-minor-mode` (`outline-end-of-subtree`) |
| `kill-region` | `kill-region-dwim` (the word branch) |
| `next-line` | `next-line-add-newlines` |
| `mouse-start-end` (9) | the double/triple-click modes; ours is mode 0 only |
| `minibuffer-completion-help` | the `field-end` computation (already a named deviation) |
| `split-window-below` | the thin split port (already named) |
| `dired-mode` (2) | `window-point-context-use-function` |
| `font-lock-default-fontify-buffer` | `(save-restriction (widen) …)`; nothing is narrowed here |
| `dired-{revert,clean-up-after-deletion,readin-insert}`, `find-auto-coding`, `auto-coding-regexp-alist-lookup`, `query-replace-read-from`/`-to` | a minibuffer read or a scan done elsewhere |

**A different strategy that does not move point, so needs no guard:**

- `Buffer-menu-execute`, `Buffer-menu-marked-buffers`, `Buffer-menu-bury` —
  ours walk a **marks alist** keyed by buffer, not the list buffer's text.
- `isearch-lazy-highlight-update` — ours scans a **copy** of the window
  text (`make-buffer-string`) and never moves point; Emacs `goto-char`s
  through the buffer.

## The real departure underneath the Buffer Menu rows

The "different strategy" group is not innocent. Emacs has **no marks
store at all** — the mark is a *character in the row's text*:

```elisp
(defvar Buffer-menu-marker-char ?>)          ; buff-menu.el:39
(defvar Buffer-menu-del-char    ?D)          ; :42
(tabulated-list-set-col 0 (char-to-string Buffer-menu-del-char) t)
(eq (char-after) ?D)
(re-search-forward "^>" nil t)
```

and every command reads and writes it through `tabulated-list-set-col` /
`char-after`. Ours keeps `*Buffer-menu-marks*`, an alist keyed by buffer,
and the redraw *generates* the mark character from it.

That is not merely "state Emacs does not have" — it is **observable
behaviour that differs**, measured on Emacs 31.1:

```
--- after d on the 3rd entry ---      --- after g (revert-buffer) ---
  "."                                   " "
  " "                                   " "
  "D"                                   " "     <- gone
  " "                                   " "
  " "                                   " "
```

**Emacs discards `d`/`s` marks on revert.** Only `>` survives, and only
because `list-buffers--refresh` re-reads those out of the text
(`Buffer-menu-marked-buffers` scans for `^>`) and rebuilds them into the
entry vector; the rest are text, and the redraw rewrites the lines.

Ours never clears the alist — nothing writes `*Buffer-menu-marks*` except
`Buffer-menu--set-mark!`, in no refresh, no `list-buffers-noselect`, no
redraw — so our `d`/`s` marks survive `g`, and even a fresh `C-x C-b`.

So there are **two** departures, and the second is the significant one:

1. the marks live in a table instead of in the text; and
2. **marks Emacs throws away on refresh, we keep.**

### Why the commands cannot be written Emacs's way *as things stand*

Not a missing capability — the tree has text properties, and
`tabulated-list-print` already inserts each row at a known range. It is
that our `tabulated-list.scm` (211 lines, a subset of `tabulated-list.el`)
skips the two things Emacs's commands rest on:

- a row carries no `tabulated-list-id` property, so `tabulated-list-get-id`
  **counts lines** instead of reading the text. Emacs's loop opens
  `(let ((buffer (tabulated-list-get-id)))`; here that yields a line
  number, not a buffer.
- no `tabulated-list-set-col` / `-delete-entry`, and `tabulated-list-print`
  unconditionally `(erase-buffer)`s and re-inserts every row — where
  Emacs's `tabulated-list-print-entries` does an id-keyed in-place merge:

```elisp
(cond ((equal id local-id) (forward-line 1) nil)   ; same entry: keep the line
```

That merge is why Emacs's text can carry state across a redraw at all.

## The plan

**Option A — behaviour only, small.** Make the refresh keep only `>` marks
(clear `d`/`s` from `*Buffer-menu-marks*` on refresh), matching Emacs's
rule without touching the representation. Cheap; makes `g` agree.

**Option B — the proper fix.** Port `tabulated-list.el` onto the existing
text-property layer:

- `tabulated-list-print-entry` puts `tabulated-list-id` (and the entry) on
  the row it inserts;
- `tabulated-list-get-id` / `-get-entry` read it back off the line;
- `tabulated-list-set-col`, `tabulated-list-delete-entry`;
- `tabulated-list-print-entries`' id-keyed in-place merge, with the
  `update` / sorter rules (`(when (and update (not sorter)) (setq update nil))`).

Then rewrite the Buffer Menu onto it. That **deletes `*Buffer-menu-marks*`
outright**, makes all seven commands Emacs-shaped (walk the buffer,
`forward-line`, `char-after`, `tabulated-list-set-col`), brings their
`save-excursion`s back as a consequence rather than as an edit, and gives
departure (2) for free — the merge preserves `>` and loses `d`/`s` exactly
as Emacs does.

Recommended: **B**. It is one library plus one caller, and it removes a
parallel store instead of adding a rule to keep it honest.

## Re-running the audit

    python3 tools/save-excursion-audit.py .

Two traps for anyone editing it: Guile's `simple-format` has no `~d`
(`(use-modules (ice-9 format))`), and `.el` files contain forms `read`
cannot handle (`#<…>`, `#N=`), so the form loop needs a `condition-case`
per form, not one around the loop.

## The ten count-differences, read one by one

These are the functions we *have* where the counts differ — not missing
guards but different numbers of them. Read on both sides, none is a
departure; they are the same effect reached with a primitive that does not
move point.

| function | emacs | ours | what the difference is |
|---|---|---|---|
| `kill-line` | 2 | 1 | Emacs finds the line end with `(save-excursion (end-of-visible-line) (point))`; we use `line-end-position`, which does not move point. |
| `fixup-whitespace` | 2 | 1 | Ours has the outer guard. Emacs's inner one is `(save-excursion (forward-char -1) (looking-at "\s(\|\s'"))` — the syntax-class clause the file already records as not ported. |
| `dired-mark` | 3 | 1 | Two of Emacs's three are `dired-mark-subdir-files` (an unported branch) and a position computation. |
| `perform-replace` | 5 | 2 | The three extras wrap `match-data` restores around `replace-match` (which moves point) and `(save-excursion (recursive-edit))` for reading the answer. We move point for neither. |
| `dired-goto-file` | 3 | 2 | position computations; not read in full |
| `dired-insert-directory` | 4 | 2 | as above - one is `(unless (save-excursion …))`, a test rather than a guard |
| `dired-insert-set-properties` | 3 | 2 | as above; two are in `let` bindings |
| `dired-log` | 0 | 1 | **ours adds one** - not a dropped guard |
| `indent-rigidly` | 2 | 3 | ours adds one |
| `query-replace-read-args` | 0 | 1 | ours adds one |

`kill-line` is worth recording in full because it *looks* like a departure
and is the opposite of one. Emacs deliberately moves point before killing,
and says why in the source:

```elisp
(kill-region (point)
  ;; It is better to move point to the other end of the kill
  ;; before killing.  That way, in a read-only buffer, point
  ;; moves across the text that is copied to the kill ring. ...
  (progn ... (point)))
```

Ours has the same shape — `(kill-region (point) (begin … (point)))` — and
the extra Emacs guard is only the non-moving line-end computation.

**The three where we have more** (`dired-log`, `indent-rigidly`,
`query-replace-read-args`) cannot be dropped guards by construction: they
are guards we added.

**Not read in full**: the three `dired` position computations above were
classified by where their guards sit, not by reading both bodies.
