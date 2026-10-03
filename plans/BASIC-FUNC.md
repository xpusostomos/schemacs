# BASIC-FUNC.md — schemacs vs mg: coverage of basic editor functionality

**What this is.** mg (OpenBSD's micro-Emacs, in `../mg`) is a good
datapoint for what a *small* editor still needs to be a real editor:
~150 commands and one line for "basic functionality". We are
reimplementing Emacs proper, so our target is Emacs — but if mg has
something we do not, it is a hole a user will hit on day one. This file
is the gap list, from comparing mg's function table (`mg/src/funmap.c`)
against our command table (`schemacs/editor/**`, the `new-command` /
`new-count-command` names).

Statuses used:

* `have`  — the command exists (function or bound command).
* `bound` — it is on a default key.
* `gap`   — mg has it, we do not.

The line groups are mg's own (with the Emacs name mg calls it).

---

## Where we already stand

What mg has, and we have too (the groups that are *not* the problem):

* Character/line/word motion: `forward-char`, `backward-char`,
  `next-line`, `previous-line`, `forward-word`, `backward-word`,
  `beginning-of-line`, `end-of-line`, `beginning-of-buffer`,
  `end-of-buffer`.
* Basic editing: `self-insert-command`, `newline`, `delete-char`,
  `delete-backward-char`, `kill-line`, `kill-word`, `backward-kill-word`.
* Kill/yank/region: `kill-region`, `copy-region-as-kill` (M-w),
  `yank` (C-y), `yank-pop` (M-y), `set-mark-command` (C-SPC),
  `exchange-point-and-mark`, `mark-whole-buffer` (C-x h).
* Incremental search: `isearch-forward`, `isearch-backward` (C-s, C-r).
* Undo: `undo` **and** `undo-redo` (mg only has undo).
* Files/buffers: `find-file` (C-x C-f), `save-buffer` (C-x C-s),
  `save-buffers-kill-terminal` (C-x C-c), `kill-buffer`, `list-buffers`
  (C-x C-b), `switch-to-buffer`, `switch-to-buffer-other-window`.
* Windows: `split-window-below` (C-x 2), `split-window-right` (C-x 3),
  `delete-window` (C-x 0), `delete-other-windows` (C-x 1),
  `other-window` (C-x o).
* Prefix arguments: `universal-argument` (C-u), `digit-argument`,
  `negative-argument`, `keyboard-quit` (C-g).
* Page scrolling: `scroll-up-command`, `scroll-down-command`.
* `suspend-frame` (C-z).

Things we have that mg does **not** (worth remembering while reading the
gap list — we are ahead in these): the whole minibuffer completion UI
(TAB, `?`, M-<down>/M-<up> through the candidates, the *Completions*
window laid out in columns in a fresh bottom window with the terminal's
width); transient-mark region highlight (white on blue); replaceable
undo *and* redo; the buffer menu (`C-x C-b` list with marking, saving,
deleting); a status line with Emacs's exact format and the buffer's own
`(DOS)`/`(Mac)` line-ending mnemonic; incremental search highlighting;
management of multiple buffers with `default-directory` and
`buffer-file-coding-system`.

---

## The gaps that matter for day-one use

Ordered by how quickly a newcomer hits them.

### 1. `execute-extended-command` (M-x)  —  gap, and the big one

mg: `extend` "execute-extended-command". We define ~74 commands and have
a minibuffer, a complete history system, and a command table — but no M-x
to *run a command by name*. This is also the door to everything else in
the list: once M-x exists, `goto-line`, `zap-to-char`, `fill-paragraph`
& co. stop needing their own evening of work (they still need their
keybindings, but are reachable).

### 2. `what-cursor-position` (C-x =)  —  gap

mg: `showcpos`. Trivial here (the mode line already computes L and C).

### 3. `recenter` (C-l)  —  gap

mg: `reposition`. Needed the moment a long line pushes point off-screen —
and it is the canonical "get me back to centre" key. Our display has no
scrolling-to-point command at all.

### 4. `goto-line` (M-g g / Esc g g)  —  gap

mg: `gotoline`. One prompt, one minibuffer read — we have both.

### 5. `write-file` (C-x C-w)  —  gap

mg: `filewrite`. "Save this buffer *as*…". `save-buffer` prompts for a
name only when none is set; there is no way to save under a new name
when one already is.

### 6. Line surgery: `open-line`, `join-line`, `just-one-space`,
    `delete-blank-lines`, `delete-horizontal-space`,
    `delete-leading-space`, `delete-trailing-space`  —  gap

mg: `openline` (C-o), `joinline` (M-^), `justone` (M-SPC),
`deblank`, `delwhite`, `delleadwhite`, `deltrailwhite`.
All of them are pure buffer edits — no new machinery.

### 7. `zap-to-char` (M-z) and `kill-paragraph` (M-k)  —  gap

mg: `zaptochar`, `killpara`.

### 8. Word/region case: `upcase-word`, `downcase-word`,
    `capitalize-word` (M-u, M-l, M-c), `upcase-region`,
    `downcase-region` (C-x C-u, C-x C-l)  —  gap

mg: `upperword`, `lowerword`, `capword`, `upperregion`, `lowerregion`.

### 9. `transpose-chars` (C-t), `transpose-words` (M-t)  —  gap

mg: `twiddle`, `transposeword`.

### 10. Plain search: `search-forward`, `search-backward`,
     `search-again` (C-s C-s / C-r C-r)  —  gap

mg: `forwsearch`, `backsearch`, `searchagain`. We only have *incremental*
search; a repeated C-s uses whatever the previous search was — there is
no plain "jump to the next instance".

### 11. `query-replace` (M-%)  —  DONE (2026-10-02)

`replace.sld` mirrors replace.el: full `perform-replace' with the y/n/
Y/N/!/./,/q/RET/DEL/^/u/U/C-r/C-w/e/E/C-l/C-v/M-v/C-g answers and the
stack the `^'/`u'/`U' answers walk back to; `query-replace-map' is a
real keymap of answer symbols; `replace-string' and `replace-regexp'
fall out of it with `query-flag' nil. On top of the regexp layer
(`search.sld', below). Named out: `d' (diff), multi-buffer,
`region-noncontiguous-p', lazy-highlight timers, `\,'/`\#' eval in
replacements. `query-replace-regexp' (C-M-%) is in.

### 12. Paragraphs and filling —  partial (2026-10-02)

`forward-paragraph'/`backward-paragraph' (M-}/M-{) and
`kill-paragraph'/`backward-kill-paragraph' were already in
(paragraphs.sld); this pass added `mark-paragraph' (M-h) and
`set-fill-column' (C-x f) with the `fill-column' buffer-local
(default 70) and `current-column' (the new indent.sld).
`fill-paragraph' (M-q), justification and auto-fill are still open -
fill.el's chain needs a regexp substrate for its walks; deferred to
its own pass.

### 13. `quoted-insert` (C-q)  —  DONE (2026-10-02)

`keyboard.sld' (simple.sld is below the key reader): `quoted-insert'
and `read-quoted-char' with the octal input (radix 8, the
`read-quoted-char-radix' parameter), the RET terminator discarded
after the first digit, other non-digit terminators pushed back raw,
and the C's first-character-quit inhibition (C-q C-g inserts ^G).

### 14. `insert-file` (C-x i), `find-alternate-file` (C-x C-v),
     `find-file-read-only` (C-x C-r), `find-file-other-window`
     (C-x 4 f), `revert-buffer`  —  DONE (2026-10-02)

All five in files.sld, over the new `insert-file-contents' (fileio.c's
visit/replace semantics). `revert-buffer' now runs the buffer-local
`revert-buffer-function' as Emacs's does - and the Buffer List's `g'
runs the global one, whose dispatch is the refresh (the old
buffer-menu-local command is gone). Named out: auto-save offers,
wildcards, indirect buffers.

### 15. `not-modified` (M-~), `toggle-read-only`  —  DONE (2026-10-02)

`not-modified' (M-~) in files.sld, with the C's exact messages. The
`read-only-mode' binding moved to C-x C-q (files.el:9330); `C-x q' is
kbd-macro-query's key, not ported.

### 16. Window geometry: `previous-window`, `enlarge-window`,
     `shrink-window`, `enlarge-window-horizontally`,
     `shrink-window-horizontally`, `resize-window-*`, `windmove-*`,
     `scroll-other-window`  —  gap

mg: `prevwind`, `enlargewind`/`shrinkwind`, `enlargewindh`/`shrinkwindh`,
`resizewind*`, `windmove*`, `pagenext`. We only have split/delete/other.

### 17. Keyboard macros: `start-kbd-macro` (C-x (),
     `end-kbd-macro` (C-x )), `call-last-kbd-macro` (C-x e)  —  gap

mg: `definemacro`, `finishmacro`, `executemacro`. A macro recorder needs
the key-reading loop's events recorded and replayed — new machinery, but
the classic "basic" feature.

### 18. Shell: `shell-command` (M-!), `shell-command-on-region` (M-|),
     `push-shell` (M-x shell)  —  gap

mg: `shellcommand`, `piperegion`, `spawncli`.

### 19. Help: `quick-help`, `describe-bindings` (C-h b),
     `describe-key-briefly` (C-h c), `help-help`  —  gap

mg: `quickhelp`, `wallchart`, `desckey`, `help_help`. We have no C-h at
all. `describe-bindings` in particular is cheap: walk our keymap and
print it to a `*Help*` buffer.

### 20. Tabs: `set-tab-width`, `no-tab-mode`, `space-to-tabstop`  —  gap

mg: `settabw`, `notabmode`, `space_to_tabstop`.

---

## Not in the gap list — mg features we deliberately don't chase (yet)

These are mg modules that are *not* "basic editing coverage":

* **Language modes** (`c-mode`, `python-mode`, `shell-mode`, `sh-mode`,
  `cmode.c`, `pymode.c`, …) — mg's whole `modes.c` machinery. We have no
  major-mode system at all; this is a structural piece, not a command gap.
* **`dired`, `cscope`, `grep`, `diff-buffer-with-file`, tags** — mg
  ships them conditionally (`ENABLE_DIRED`, `CSCOPE`, …). Beyond basic.
* **`eval-current-buffer`, `eval-expression`, the interpreter** — quirky
  mg features; we will get `eval-expression` from Emacs proper.
* **Backup files, visible bell, `meta-key-mode`, `bsmap-mode`,
  global wd, auto-execute** — mg configuration toggles.

---

## Suggested order of attack

Shortest path to "a stranger can edit" (each line is roughly its cost):

1. M-x `execute-extended-command` (unlocks everything's reachability)
2. `recenter` (C-l), `what-cursor-position` (C-x =), `goto-line`
3. `write-file` (C-x C-w)
4. the line-surgery six (C-o, M-^, M-SPC, deletes)
5. `zap-to-char`, `transpose-chars`, the case commands
6. plain `search-forward`/`search-again`, then `query-replace` (M-%)
7. `fill-paragraph` + paragraphs + `set-fill-column`
8. `quoted-insert`, `insert-file`, `find-alternate-file`,
   `not-modified`
9. keyboard macros
10. help: `describe-bindings`, `describe-key-briefly`, `quick-help`
11. window geometry (enlarge/shrink, previous-window,
    scroll-other-window)
12. shell commands