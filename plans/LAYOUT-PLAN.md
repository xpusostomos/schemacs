# Laying our code out the way GNU Emacs lays out its own

Written 2026-09-27, companion to NCURSES-PLAN.txt and MG-PLAN.txt.

## The idea

Mirror GNU Emacs's file layout in our Scheme, so that a chunk of
functionality has the same *name and place* as the Emacs code it
corresponds to: `minibuffer.el`'s function is in `minibuffer`. That is
what makes cross-matching easy enough to do routinely — "where is
`kill-region`?" answered the same way in both trees.

## The rule

- **One library per mirrored file**, base name identical to Emacs's,
  library name `(schemacs editor <name>)`: `editor/simple.sld` mirrors
  `simple.el`, `editor/isearch.sld` mirrors `isearch.el`, and so on.
- **One directory holds both sides of Emacs's tree.** Emacs has the same
  base name on both sides — `window.el`/`window.c`, `indent.el`/`indent.c`,
  `faces.el`/`face.c`, `term.el`/`term.c` — so the path cannot say which
  side a file mirrors. Resolution: the base name mirrors the Emacs file
  whose *role* the library fills, and the library's header comment states
  the correspondence, e.g. `editor/frame.sld` — "mirrors `frame.c` and the
  part of `window.c` that holds a window"; `editor/engine.sld` — "mirrors
  `buffer.c` + `insdel.c` + `marker.c` + `search.c`".
- **Names keep Emacs's spelling.** Emacs's `t`/`nil` are Scheme's `#t`/`#f`
  (the Elisp spelling is real Elisp objects, which the elisp layer already
  has); a shared name must mean what Emacs means by it, or say in its
  docstring that it is a subset.
- **Moves change no names.** Each step is a move, plus the hook it is
  triggered by, plus tests — verified by the suites that already exist,
  which is why they must stay green throughout.

## Where the terminal goes

`schemacs/ui/platform/ncurses.sld` — `(schemacs ui platform ncurses)`. This
is what NCURSES-PLAN.txt's "Architecture decision" said in the first place;
the frontend ended up in `apps/ncurses-editor.sld` instead, which is where
the terminal and the editing code currently share one library.

## The mapping

Line ranges are from `apps/ncurses-editor.sld` as it was before the first
move (3,471 lines, 20 banner sections). "Emacs" was resolved with
`symbol-file` against the installed Emacs 31.1 rather than guessed — which
is why `keyboard-quit` and `universal-argument` are listed under
`simple.el` (they are Lisp commands, not C, though the command *loop* is C).

| section | lines | → library | Emacs counterpart | moved? |
|---|---|---|---|---|
| Windows (record + geometry) | 180–304 | `editor/frame.sld` | `window.c` | **done** |
| Editor state (`<ncurses-frame>`, selection) | 305–437 | `editor/frame.sld` | `frame.c` / `frame.el` | **done** |
| Terminal setup | 438–465 | `ui/platform/ncurses.sld` | `term.c` / `lisp/term/*.el` | |
| Display expansion (glyphs, tab stops) | 466–520 | `editor/disp-table.sld` | `disp-table.el` | |
| Rendering (line assembly, mode line, echo, cursor) | 521–841 | `editor/xdisp.sld` | `xdisp.c` | |
| Commands (core editing set) | 842–1209 | `editor/simple.sld` | `simple.el` | |
| Windows (tree surgery + window commands) | 1210–1635 | `editor/window.sld` | `window.el` | |
| Kill ring and word motion | 1636–1821 | `editor/simple.sld` | `simple.el` | |
| Undo frontend | 1822–1929 | `editor/simple.sld` | `simple.el` | |
| Incremental search | 1930–2249 | `editor/isearch.sld` | `isearch.el` | |
| Prefix arguments | 2250–2325 | `editor/simple.sld` | `simple.el` | |
| Keymaps (the global map) | 2326–2389 | `editor/keymap.sld` | `keymap.c` | |
| Key events (dispatch, error reporting) | 2390–2569 | `editor/keyboard.sld` | `keyboard.c` | |
| The minibuffer | 2570–2798 | `editor/minibuffer.sld` | `minibuffer.el` | |
| Completion | 2799–2987 | `editor/minibuffer.sld` | `minibuffer.el` (+ `minibuffer.c` for matching) | |
| File names | 2988–3078 | `editor/files.sld` | `files.el` | |
| The command loop, recursive edits | 3079–3190 | `editor/keyboard.sld` | `keyboard.c` | |
| File I/O (line breaks, write protect) | 3191–3263 | `editor/files.sld` | `files.el` / `coding.c` | |
| Final newlines, find-file, save-buffer | 3264–3440 | `editor/files.sld` | `files.el` | |
| Main entry | 3441–3471 | `ui/platform/ncurses.sld` + `main-ncurses.scm` | `emacs.c` / `startup.el` | |

End state: `apps/ncurses-editor.sld` dissolves — the editing half into
`editor/*.sld`, the terminal half into `ui/platform/ncurses.sld`, and
`main-ncurses.scm` stays the entry point.

## Procedure for each move

1. Create `schemacs/editor/<name>.sld`, importing only what the section
   needs. **A missing `(scheme case-lambda)` import reports as an unbound
   variable at run time, not a syntax error** — the same trap recorded in
   ENGINE-FINDINGS.txt.
2. Move the section verbatim: same names, no behaviour change, except where
   the step also hooks in one of the designs below.
3. Export what the rest needs. Shared state is `make-parameter` objects, and
   a parameter is a single object, so exporting it and importing it
   elsewhere keeps one instance — the same for records' `set!`-accessors,
   which are procedures. **Generate the export/import lists from the
   definitions, not by hand, and let the suites verify before believing
   them**: a loose first attempt picked up record *field* names, and a
   missing `selected-window` made the window commands error into the echo
   area, where only the tests noticed.
4. Re-export the moved names from `apps/ncurses-editor.sld` so that the code
   and tests that reach them through that library keep working while it
   shrinks. That plumbing is transient.
5. The four hand-maintained file lists to keep in sync: `run-tests.scm`,
   `build.scm`, `Makefile`, and `platform/guile/main.scm`'s `load` sequence.
6. Run `tools/syntax-check.scm`, both test suites, the pty battery for
   anything user-visible, and a paired check against real Emacs for anything
   with Emacs semantics (a move needs no such check; a hook does).

## Order, driven by the next feature

- **The completion port** (next): `editor/frame.sld` (done), then
  `editor/minibuffer.sld` and `editor/files.sld` — and **per-buffer local
  keymaps** hooked in, because a `*Completions*` buffer wants its own
  keymap.
- **isearch**, when it is next reworked: `editor/isearch.sld`.
- **The window tree**, when windows are next touched: it removes the
  row-band/column-band/adjacency heuristic that `delete-window` needs today
  only because we keep a flat list, and that heuristic is documented as a
  deviation in NCURSES-PLAN.txt.
- **`mode-line-format` / `header-line-format`**, when the mode line is next
  touched: retires our hand-rolled `mode-line-string` and adds header lines.
  In Emacs the evaluation is `xdisp.c` and the default value is
  `bindings.el`.
- **`*Messages*`**, when message handling is next touched: a
  `messages-buffer` (Emacs keeps it in `simple.el`), so messages stop
  vanishing with the echo area.
- **`eval-expression`**, when the elisp bridge is next worked on.

## The reference to read, not to revive

`schemacs/apps/emacs.sld` (1,463 lines) contains all six of those designs —
`*mode-line-format*`, `window-parent-frame`, `*default-buffer-local-keymap*`,
`messages-buffer`, `eval-expression`, and the `impl/*` + view-constructor
seam. It is an unfinished API migration (commits Nov 2025 – Aug 2026) whose
only consumers were last updated 2026-02-08 and reference names that no
longer exist, so it cannot be inherited as code. It is the design reference
for every hook above.

## Progress

| step | library | state |
|---|---|---|
| 1 | `editor/frame.sld` (window record, geometry, frame state) | **done** |
| 2 | command substrate: `new-count-command` → `editor/command.sld` | **done** |
| 3 | `current-editor` → `editor/frame.sld` | **done** |
| 4 | `editor/disp-table.sld` (glyphs, tab stops) | **done** |
| 5 | `editor/files.sld` (file I/O half: line breaks, write protect, `switch-to-buffer!`) | **done** |
| 6 | `editor/simple.sld` (commands, kill ring, undo, prefix argument) | **done** |
| 7 | `editor/xdisp.sld` (the redisplay) | **done** |
| 8 | `editor/isearch.sld` (the incremental search) | **done** |
| 9 | `editor/window.sld` (the window commands) | **done** |
| 10 | `editor/keymap.sld` (the global map, `define-key`) | **done** |
| 11 | `editor/keyboard.sld` (key events, dispatch, the command loop) | **done** |
| 12 | `editor/minibuffer.sld` (the minibuffer, completion, the y/n readers) | **done** |
| 13 | `editor/files.sld` completed (file names, final newlines, the commands) | **done** |
| 14 | `ui/platform/ncurses.sld` (the terminal and the entry point) - and `apps/ncurses-editor.sld` is deleted | **done** |

### The dependency analysis, and the four knots in it

`tools/section-deps.py` reports, for each banner section, the names it uses
that some *other* section defines. Run it on
`apps/ncurses-editor.sld` after any move. What it showed is that the file
is not a chain but four cycles, and no move can be a leaf until each cycle
is cut. The cuts are all "make it match Emacs" changes, which is why they
are worth making:

1. **`current-editor`** — Commands, Kill ring, Undo, isearch and Windows all
   reach into the *minibuffer* section for it, while the minibuffer reaches
   back for `new-count-command`. Emacs has no such knot: `current-buffer` is
   a buffer.c primitive returning the selected window's buffer, and while a
   minibuffer is read its *window* is selected, so nothing special-cases it.
   **Cut:** it moved to `editor/frame.sld`, reading a parameter
   `*minibuffer-editor*` that `read-from-minibuffer` binds - the buffer the
   minibuffer window would be showing, which is the one thing we lack until
   the minibuffer is a real window. Done.
2. **`new-count-command`** — the minibuffer, Windows, Kill ring and Undo all
   need it, and it was in Commands. It is the `(interactive "p")` machinery,
   which is callint.c's in Emacs, not any .el file's. **Cut:** it moved to
   `(schemacs editor command)`, beside `new-command`. Done.
3. **`render!` against the minibuffer** — Rendering reads
   `minibuffer-prompt`, `minibuffer-contents`, `minibufferp` and
   `minibuffer-cursor-column`, while the command loop (which the minibuffer
   needs for its recursive edit) needs `render!`. In Emacs the dependency
   runs one way because the prompt and the typed text are in the *buffer*,
   and the echo area (xdisp.c) draws a buffer. **Cut when Rendering moves:**
   put the echo area's state on the frame - which buffer is being read and
   its prompt, Emacs's `echo_area_buffer` and `current_message`, both of
   which are frame facts - and let the renderer draw from there.
4. **`*default-keymap*` against everything** - Keymaps binds commands from
   Commands, isearch, Kill ring, Undo and Windows, so it must come after all
   of them, while the command loop, the minibuffer and dispatch all need it
   first. In Emacs `global-map` is created *empty* in keymap.c and each file
   adds its own bindings to it as it loads. **Cut when Keymaps moves:** the
   same - `*default-keymap*` becomes an empty keymap in `editor/keymap.sld`,
   and each command library installs its own bindings at load time.

Two smaller ones, both already listed as cleanups: `find-file-command` and
`save-buffer-command` sit in the Commands section but are files.el's and
must move to `editor/files.sld` (they are the only Commands-section code
that reaches into File names and Final newlines); and the four commands
misfiled under the second *Windows* banner belong to `simple.sld`
(`keyboard-quit`, `read-only-mode`), `files.sld`
(`save-buffers-kill-terminal`) and the buffer layer (`kill-buffer-command`).

### The order the analysis gives

Topological, leaves first. Each line is one move; a move keeps the names
and re-exports them from `apps/ncurses-editor.sld` so the suites stay green
throughout.

1. `editor/command.sld` — `new-count-command`. **done**
2. `editor/frame.sld` — `current-editor`, `*minibuffer-editor*`. **done**
3. `editor/disp-table.sld` — Display expansion (glyphs, tab stops). A leaf.
4. `editor/files.sld` — File I/O (line-break detection, write protection,
   `switch-to-buffer!`). A leaf.
5. `editor/simple.sld` — Commands + Kill ring + Undo + Prefix arguments.
   They are one file in Emacs and they reference each other (`kill-range`).
   Move `exchange-point-and-mark` here from the isearch section, and the two
   files.el commands out to `files.sld`.
6. `editor/xdisp.sld` — Rendering, with knot 3 cut and `disp-table` below
   it. **Both** cuts had to happen here, because either one alone would
   leave xdisp importing the minibuffer or the search: the echo area's
   buffer and prompt moved to the frame (`*echo-area-buffer*`,
   `*echo-area-prompt*`), and the search highlight inverted into
   `*search-highlight*`, which xdisp defines and the search sets. Done.
7. `editor/isearch.sld` — needs Rendering for `render!`, which it can now
   import, and must keep `*search-highlight*` in step with its pattern.
   `exchange-point-and-mark` has already gone to `simple.sld`. Done: the
   library is a leaf (engine, frame, command, simple, xdisp, ncurses).
8. `editor/window.sld` — the window commands.
9. `editor/keyboard.sld` — quits + Key events + the command loop and
   recursive edits. Needs Rendering and Keymaps.
10. `editor/keymap.sld` — with knot 4 cut; each library above installs its
    own bindings, so this must come after them.
11. `editor/minibuffer.sld` — the minibuffer, history, completion, prompts,
    the y/n readers. Needs `keyboard` for the recursive edit.
12. `editor/files.sld` again — File names, Final newlines, `find-file`,
    `save-buffer`, `save-some-buffers`, `save-buffers-kill-terminal`. Needs
    the minibuffer.
13. `ui/platform/ncurses.sld` — Terminal setup + main entry, with
    `main-ncurses.scm` staying the entry point.

### A rule the moves forced: a name that is also imported cannot be defined

`newline` broke this step, and the way it broke is worth stating as a rule
because it will recur.

Every one of our editor libraries imports `(scheme base)`, and **Guile's
`(scheme base)` exports `newline`** (R7RS-small says it should not; Guile's
does). So `(define newline ...)` in `editor/simple.sld` was a definition over
an *imported* binding, which R7RS forbids, and Guile resolved it by keeping
the import: the definition was dropped, the library exported Scheme's output
procedure, and the keymap bound `(ctrl #\m)` to it. Pressing RET then called
`(newline)` — which writes a newline to standard output — so the editor
inserted nothing, cleared the echo area as if a command had run, and printed
a stray blank line to the terminal. **Both suites stayed green**: no unit
test presses RET on a real screen.

The fix is R7RS's own: give the definition a different spelling and export
the Emacs name by `rename`:

```scheme
(define newline-command (new-count-command "newline" ...))
(export ... (rename (newline-command newline)) ...)
```

Every use site still says `newline`, which is what Emacs calls it, and
`command-name` is still `"newline"` for the Elisp layer. Only the definition
site carries the `-command` suffix - which is already this project's
convention for commands whose Lisp name is taken (`find-file-command`,
`kill-line-command`, `scroll-up-command`).

`tools/check-name-clashes.py` checks the whole tree for this and is verified
against the bug itself. Names that will need it as more Emacs code moves in -
this is the set of Emacs names that Guile's `(scheme base)`, `(scheme char)`
and `(scheme write)` also export:

    newline  error  read  write  display  load  apply  exit  list
    values   vector string append length reverse member assoc
    delete-file  file-exists?

(`format`, `signal`, `catch`, `throw`, `rename-file`, `copy-file`,
`make-directory` and `current-time` are Guile *core* names rather than
imported ones, and a definition does shadow those - but importing
`(ice-9 format)` or `(guile)` wholesale would make `format` a clash too, so
keep those imports narrow, as they are.)

### `editor/buffer.sld`: the buffer list, written fresh (NEW)

`(schemacs editor buffer)` mirrors `buffer.c`'s *collection* half: which
buffers exist, what they are called, which is current, making one and
killing one. It is new code, not a move - written from the C and the Lisp
rather than lifted from anywhere, because the existing buffer machinery is
in three unwired places:

  * `(schemacs ui text-buffer)` + `text-buffer-impl` - a buffer API of 27
    operations, every one of which forwards to a parameter that defaults to
    `(error "... not defined")`. It is a *plugin seam*; the backend was the
    GTK line, so `(new-buffer)` fails today.
  * `(schemacs editor-impl)` - 28 more hooks of the same kind.
  * `apps/emacs.sld` - an actual name->buffer table with a counter and a
    `messages` slot, but its values are that file's own `<buffer>` view
    wrappers around `GtkTextBuffer`s, its `get-buffer` is exported and never
    defined, and it has no order, no `buffer-list`, no `other-buffer`, no
    `kill-buffer`.

Emacs keeps almost all of this in C (`buffer.c`), so there was little to
transcribe: `with-current-buffer`, `generate-new-buffer` and `bury-buffer`
are the only Lisp, and `generate-new-buffer-name` - which `apps/emacs.sld`
already ported - is the one fiddly algorithm. What was worth *copying* is a
design fact rather than code: the buffer list is an association list of
(name . buffer) in most-recently-used order, which is simultaneously the
name lookup, the order `other-buffer` means, and what `bury-buffer` moves.
A hash table keyed by name would be faster and lose the order, which is why
Emacs does not use one.

Two decisions, both stated in the file's header:

  * **A buffer here *is* the engine's `<text-editor>`** - no wrapper record,
    as there is no second struct in Emacs. `bufferp` is
    `text-editor-type?`.
  * **The buffer-local slots are a weak table beside the buffer, not fields
    of it.** Emacs keeps `keymap` and `local_var_alist` in the struct; the
    engine is large and tested and a keymap is a management concern, so they
    live in a table keyed by the buffer - weak, because a table holding its
    keys strongly would keep every killed buffer alive. `(schemacs weak)`
    gained `new-weak-table` and its accessors for this.

`buffer-tests.scm` is the only check the library has, because nothing uses
it yet; 16 tests, each stating what Emacs answers for the same call. It
found two mistakes in my own test file (`set!` on a *parameter object*,
which stopped it being a procedure, and two expectations I had reasoned
rather than measured).

Not wired, and named in the file: `record-buffer!` - the display hook that
promotes a buffer to the front of the list when it is shown, which Emacs
calls from `window.c` and our renderer does not know about yet; buffer
hooks; and `files.sld`'s `default-directory`, which is a *frame* fact today
where Emacs's is buffer-local, so two windows on two files share one answer.

### Keymaps: the existing work, adopted where it was right

Ramin's low-level `(schemacs keymap)` we already use and barely changed (21
lines). His *higher-level* design - keymaps attached per buffer, per window
and per frame, with a default at each level, which is GNU Emacs's model and
better than the single global map we had - is in `apps/emacs.sld`, and its
key dispatch does not work: `new-modal-lookup-state` documents that it takes
"a `<keymap-type>` argument or a list of `<keymap-type>` arguments" and its
code accepted only the single keymap, so the callers that pass a list (the
frame key dispatchers) would error. **Fixed**: the list case is implemented,
and `editor/keyboard.sld` now passes `(list local global)` through that API
instead of hand-building a combined keymap out of the two maps' layers.

Four behaviours are now in `keymap-tests.scm` as
`schemacs_keymap_precedence`, and two of them were measured from a terminal
Emacs with `(key-binding ...)` for the same pair of maps: a key bound in
both maps is the first map's, a key the first map does not bind is found in
the next, and - the one worth stating - a *prefix* in the first map does not
stop a longer sequence being found in the next, so a local `C-x` prefix
still reaches the global `C-x C-f`. That last one is why the layers of one
keymap, tried in order, are the right implementation rather than a list of
separate maps consulted one at a time.

Per-buffer and per-window local maps themselves are still to come: we have
one `*current-keymap*` that only the minibuffer binds. The API now takes the
list that would carry them.

### `editor/buffer.sld`: the buffer facility, built on the evidence

Written to the shape the evidence pointed at, not to the shape of the code
that happened to be lying around:

  * **The buffer is the engine's `<text-editor>`** - there is no wrapper
    record, because Emacs has no second struct. `bufferp` is
    `text-editor-type?`.
  * **One structure for the list** - an association list of (NAME . BUFFER)
    ordered most-recently-used first, which is Emacs's `Vbuffer-alist`.
    Emacs uses it for three jobs at once (find a buffer by name, list the
    buffers, define the order `other-buffer` means) and a hash table would
    have done the first and lost the other two. `emacs.sld`'s dead
    `*buffer-table*` used a hash table; its `generate-new-buffer-name` was
    the only part worth keeping, and the format it produced was not
    Emacs's (`name-1` where Emacs gives `name<2>`).
  * **The buffer-local slots are a weak table beside the buffer**, not
    fields of it - Emacs keeps `keymap` and `local_var_alist` in the
    struct; the engine is large and tested and a keymap is a management
    concern. `(schemacs weak)` gained a *table* for this: a set would not
    do, and a table holding its keys strongly would keep every killed
    buffer alive.
  * **Emacs's names where Emacs has a function** (`get-buffer`,
    `kill-buffer`, `set-buffer`, `other-buffer`, `with-current-buffer`,
    `generate-new-buffer-name`, `rename-buffer`, `bury-buffer`), and the
    tree's `?`/`set!` spelling where Emacs has only a variable
    (`buffer-read-only?`, `buffer-default-directory`). The file states
    which is which.
  * `with-current-buffer` is a **macro**, as it is in Emacs, so a body
    reads as if the buffer were simply current - `(with-current-buffer
    "*Completions*" (erase-buffer) (insert ...))`.

16 tests in `editor/buffer-tests.scm`, registered in `run-tests.scm`, each
stating what Emacs answers for the same call. They earned their place
immediately: they caught `set!` applied to a *parameter object* in the test
file itself (which turned the parameter into a list and made the next call
apply `'()`), and two expectations of mine that were guesses rather than
measurements.

Nothing uses the library yet. The completions port is its first consumer,
and `record-buffer!` - the MRU promotion Emacs does from the display code -
is written but uncalled, because the renderer does not know about the
buffer list yet. Two deviations are recorded in the file: the
buffer-local slots being a side table rather than struct fields, and
`(schemacs editor files)`'s `default-directory` still answering from the
frame's file path rather than from the buffer.

### `editor/buffer.sld`: the buffer facility, built for the completions port

Written 2026-09-27 on request, from Emacs's `buffer.c` and its C, because the
completions port needs named buffers and `*Messages*` needs one too. It is a
new library rather than a move: `(schemacs editor engine)` is `buffer.c`'s
*text* (`insdel.c`), and this is `buffer.c`'s *management* - which buffers
exist, what they are called, which is current, making one and killing one.

A buffer here **is** the engine's `<text-editor>`: no wrapper record, as
there is no second struct in Emacs. `bufferp` is `text-editor-type?`.

What it provides, with Emacs's names where Emacs has a function of that name:
`get-buffer`, `get-buffer-create`, `generate-new-buffer`,
`generate-new-buffer-name` (Emacs's `<N>` format, from 2),
`rename-buffer`, `buffer-list`, `other-buffer`, `bury-buffer`,
`set-buffer`, `save-current-buffer`, `with-current-buffer` (a macro, as it
is in Emacs), `current-buffer`, `kill-buffer`, `buffer-live-p`, `bufferp`,
`buffer-modified-p`/`set-buffer-modified-p`, and the buffer-local slots -
`buffer-local-keymap`, `buffer-local-value`, `set-buffer-local-value!`,
`buffer-default-directory`. Plus `*buffer-list*` (Emacs's `Vbuffer-alist`,
one association list serving lookup, order and MRU), `*current-buffer*`,
`*buffer-list-update-hook*` and `*kill-buffer-query-functions*`.

Two decisions stated in the file's header, because Emacs decides them
differently:

- **The buffer-local slots are a weak table beside the buffer, not fields of
  it.** Emacs keeps `keymap` and `local_var_alist` in the struct. The engine
  is large and tested and a keymap is a management concern, so they live in a
  weak table keyed by the buffer - weak so that a killed buffer is not kept
  alive by its own slots. This needed a weak *table* (as against the weak
  *set* `(schemacs weak)` already had), which was added there.
- **`current-buffer` is maintained elsewhere, as it is in Emacs.** In Emacs
  `window.c` sets `current_buffer`; here `(schemacs editor frame)`'s
  `current-editor` answers, and `*current-buffer*` is only the dynamic
  override `set-buffer` needs.

Deviations and gaps, recorded so they are not rediscovered:

- `(schemacs editor files)`'s `default-directory` still answers from the
  *frame*'s file path, so two windows showing two files have one answer
  between them. Emacs's is buffer-local; the slot exists here
  (`buffer-default-directory`) and files.el should use it.
- `record-buffer!` (Emacs's `record_buffer`) exists and is called by nothing:
  the renderer does not know about this library yet, so the MRU order is only
  what making, killing and burying make it.
- `kill-buffer` does not run `kill-buffer-hook` (buffer-local variables are
  only the slot mechanism so far), and does not consider
  `buffer-offer-save` - the saving question is files.el's.
- Nothing in the editor uses the library yet. `buffer-tests.scm` (16 tests)
  is its only check.

### `editor/buffer.sld`: the buffer list (NEW)

Written on request, mirroring `buffer.c`'s *collection* half: which buffers
exist, their names, which is current, making and killing, and the slots a
buffer has besides its text. A buffer *is* a `<text-editor>` - no wrapper
record, as there is no second struct in Emacs - and the text, markers,
undo and search stay in the engine.

It exists because the completions port needs `(get-buffer-create
"*Completions*")`: a name two pieces of code can agree on, and the same
buffer back every time. `*Messages*` needs the same thing.

Decisions, all recorded in the file's header:

  * **The buffer-local slots are a weak table beside the buffer**, not
    fields of the engine's record. Emacs keeps `keymap' and
    `local_var_alist' *in* the struct; the engine is large and tested, and
    a keymap is a management concern rather than a text one, so they live
    in a table keyed by the buffer - weak, or it would keep every killed
    buffer alive. This is the one place the library knowingly departs, and
    it is where `(schemacs weak)`'s new **weak table** comes from
    (`new-weak-table`, `weak-table-ref`, `weak-table-set!`,
    `weak-table-delete!`, `weak-table-keys` - the library had a weak *set*
    and needed a table with values).
  * **Names**: Emacs's own function names where Emacs has a function
    (`get-buffer`, `kill-buffer`, `set-buffer`, `other-buffer`, ...), and
    this tree's `?'/`SET!' spelling where Emacs has only a variable
    (`buffer-read-only?`, `buffer-default-directory`), each docstring
    saying which variable it stands for.
  * **`with-current-buffer` is a macro**, as in Emacs, so the body reads
    as if the buffer were simply current.

Emacs's C was read for the semantics, not copied: the list is an alist
ordered most-recently-used first (Emacs's `Vbuffer-alist`, which serves as
the name lookup, the list and the order at once - a hash table would lose
the order), and `generate-new-buffer-name` appends `<N>` counting from 2.

**Nothing uses it yet.** `record-buffer!` - the MRU promotion Emacs does
from its display code - is written and not called, because our renderer
does not know about this library; the order is only what making, killing
and burying make it. And `(schemacs editor files)`'s `default-directory`
still answers from the *frame*'s file path rather than from the buffer,
which is a deviation the library's own docstring records.

Sixteen tests in `schemacs/editor/buffer-tests.scm`, registered.

### Is the reorganisation finished?

The *dissolution* is: `apps/ncurses-editor.sld` is gone, every banner
section of it is in a library named after the Emacs file it mirrors, and
every one of those declares the correspondence in its header - including
three that predated the rule and now do too (`engine.sld`, which stands for
four Emacs files and says so; `command.sld`; and `cdf.sld`, which mirrors
no Emacs file and says that instead).

Finished is not the same as nothing left. What is *not* reorganised:

1. **`editor/engine.sld` is four Emacs files in one library** - 2,473
   lines for `buffer.c' + `insdel.c' + `marker.c' + `search.c'. The rule
   says one library per mirrored file. Splitting it is work with no
   feature behind it yet; the plan's sequencing is "moved only when a
   feature forces us to touch it", and nothing has. `marker.sld` is the
   first split when markers are next worked on.
2. **The dead line is still in the tree**: `apps/emacs.sld`,
   `apps/debugui.sld`, `ui/platform/guile-gi-gtk3.sld` and
   `backend/guile-gi/*` - about 3,000 lines that nothing running imports.
   Deleting it is a decision to take deliberately, not a byproduct of a
   move; it is also the design reference for the hooks still outstanding.
3. **`schemacs_keymap` has one failing test**, on the baseline the whole
   suite has been measured against: a `keymap-layer-print` expectation
   whose text no longer matches what the printer emits. It is not from the
   precedence work - that added a passing group beside it - and it is not
   something I have looked into.
4. **Four libraries do not load**, all of them predating this work and
   none of them used by the editor:
   `(schemacs backend guile elisp)` (imports `(schemacs elisp-eval spec)`,
   which does not exist), `(schemacs elisp-eval buffer)` (a syntax error),
   `(schemacs sim-agent)` (imports `update!` from `(schemacs lens)`, which
   no longer exports it), and `(schemacs ui main)` (the library name in
   the file is not the name its path gives). 56 of the tree's 60 libraries
   load.
5. **The remaining items are features, not layout**: `header-line-format`,
   `*Messages*`, `eval-expression`, and the two import clashes in
   `eval.sld` and `sequence.sld`.

### Done: the end state

`apps/ncurses-editor.sld` is deleted. It was 3,471 lines; what came out of it
is fourteen libraries under `schemacs/editor/` plus
`schemacs/ui/platform/ncurses.sld`, and `main-ncurses.scm` stays the entry
point. The banner sections it was divided by are gone with it - there is no
"next move" table any more, because there is no file left to move out of.

| library | mirrors | lines |
|---|---|---|
| `editor/engine.sld` | `buffer.c` `insdel.c` `marker.c` `search.c` | 2,500 |
| `editor/command.sld` | `command.c` `callint.c` | 190 |
| `editor/frame.sld` | `frame.c` + `window.c`'s window | 371 |
| `editor/disp-table.sld` | `disp-table.el` | 85 |
| `editor/simple.sld` | `simple.el` | 805 |
| `editor/xdisp.sld` | `xdisp.c` | 402 |
| `editor/isearch.sld` | `isearch.el` | 370 |
| `editor/window.sld` | `window.el` | 414 |
| `editor/keymap.sld` | `keymap.c` | 86 |
| `editor/keyboard.sld` | `keyboard.c` | 362 |
| `editor/minibuffer.sld` | `minibuffer.el` `minibuffer.c` | 468 |
| `editor/files.sld` | `files.el` `coding.c` | 635 |
| `ui/platform/ncurses.sld` | `term.c` + `emacs.c`'s main | 100 |

What is left, in the order the plan set:

1. ~~The window tree~~ **done**. `frame.sld` holds it - a window has a
   `parent` and `children`, `window-list` walks to the leaves, and a
   lookup that walks it in order visits the windows in the order they are
   arranged on the screen. `window.sld`'s `delete-window` asks the parent
   for the sibling instead of inferring it from row and column bands, and
   the bands and the adjacency search are gone. Details below.
2. ~~The lookup that tries the local map and then the global one~~
   **done**: `LOOKUP-KEYMAP' in `editor/keyboard.sld' searches the local
   map's layers and then the global map's, as `read_key_sequence' does, and
   `minibuffer-local-map' holds only its own bindings.
3. ~~`mode-line-format`~~ **done**; `header-line-format` is not. The
   evaluator is `FORMAT-MODE-LINE` in `editor/xdisp.sld`, `*mode-line-format*`
   is the template (`bindings.el`'s default for the parts this editor can
   show), and `mode-line-string` is one call to it - the hand-rolled string
   is gone. Implementing it faithfully fixed two display bugs our own code
   had; they are in ENGINE-FINDINGS.txt with the measurements. Header lines
   are still to do: they need a row reserved at the top of a window, which
   reaches `window-body-height` and the geometry tests.
4. **`*Messages*`** - a `messages-buffer` in `simple.sld`, where Emacs keeps
   it - so messages stop vanishing with the echo area.
5. **`eval-expression`**, when the elisp bridge is next worked on.
6. **`apps/emacs.sld`** and the GTK line: still there, still dead, still the
   design reference. Nothing imports it that runs.
7. The two pre-existing clashes in `eval.sld` and `sequence.sld` (below).

### A deviation created and then removed: the eager copy of the global map

Worth keeping as a note, because the reasoning is what the fix came from.
When `minibuffer-local-map` was first moved into its own library it was
built by copying the global map's layers - `(km:keymap '*minibuffer-local-map*
own-layer (km:keymap->layers-list *default-keymap*))' - because our lookup
picked *one* keymap (`(or (*current-keymap*) *default-keymap*)') where GNU
Emacs's searches the local map and then the global one. That copy was taken
when the library loaded, so a global binding made after that was not in the
minibuffer's map. It happened to be complete, because the layers are shared
objects that `define-key' mutates and the libraries that add whole new
layers load first - which is ordering luck, not a property.

The fix is the faithful one and it is in: the lookup combines the local
map's layers with the global map's, per lookup, so the inheritance is live
and the copy is gone. The test that asserted the copy
(`C-f` resolved *in* `minibuffer-local-map`) now asserts the behaviour
instead: C-f is not bound in the map, and dispatching it while a minibuffer
is being read moves point in the minibuffer's buffer.

### `mode-line-format`: what it cost, and what it found

The plan called this "retire our hand-rolled `mode-line-string`". It is a
little more than that, and the reason is worth keeping: a hand-rolled string
can be *wrong* in ways a format cannot, because the format is the thing
GNU Emacs is defined by. Two of our values disagreed with Emacs, and both
had been that way since they were written:

  * the modification indicator showed `%%` for a buffer that was modified
    *and* read-only, where Emacs shows `%*';
  * the column counted from one where Emacs's `%c` counts from zero.

Neither was visible to a unit test, because a unit test asserts what the
code does. They were visible immediately once the constructs had to mean
what Emacs means by them - and only the *terminal* Emacs could answer,
since `format-mode-line` returns "" in batch. Both are now measured and
recorded in ENGINE-FINDINGS.txt, and the tests carry the numbers.

The lesson generalises: when a piece of display is hand-rolled, porting it
to Emacs's mechanism is not a refactor. It is a check.

### Load-time bindings have a cost, and it has to be paid in one place

Cutting knot 4 the way Emacs does - an empty global map, each library
installing its own keys as it loads - means a library's keys exist only once
that library is loaded. The editor stopped responding to C-s and C-x 3 the
moment the frontend was deleted, because `ui/platform/ncurses.sld` imports
only what `MAIN-NCURSES` calls: `find-file`, `event-loop`, `new-frame`. The
bindings of `simple`, `isearch` and `window` were never installed, and the
suites did not notice (they import the libraries themselves) - the pty
checks did, which is what they are for.

GNU Emacs has the same requirement and meets it the same way: `loadup.el`
loads simple.el, files.el, window.el and the rest before the first command
runs. So the entry point names them, with a comment saying that anything
adding bindings must be named there too. The alternative - a registry the
command loop walks - would be less faithful and would not remove the
requirement, only move it.

### The window tree (DONE)

The deviation NCURSES-PLAN.txt recorded is removed. A window is either a
leaf, which shows a buffer, or an internal window, which holds two or more
children; `split-window` inserts a *new* internal window in the split
window's place - so the split window stays a leaf, stays selected, and a
command holding it across a split still holds a window - and
`delete-window` gives a removed leaf's space to its sibling and splices the
parent out when one child is left. `window-list` walks the tree, and the
renderer iterates what it returns, because an internal window shows nothing
and has no mode line of its own.

Measured against GNU Emacs for the same sequences, in `emacs --batch` with
`window-edges` (its rows being one more than ours, its frame having a line
above the first window):

| sequence | Emacs | ours |
|---|---|---|
| C-x 2 C-x 2 | (0 1 80 7) (0 7 80 13) (0 13 80 24) | (0 6) (6 6) (12 11) |
| C-x 2 C-x 2 C-x o C-x 0 | (0 1 80 13) (0 13 80 24) | (0 12) (12 11) |
| then C-x o, C-x o | (0 13 80 24), (0 1 80 13) | (12 11), (0 12) |

The middle row is the case the tree exists for. Deleting the *middle* of
three: the old code looked for windows sharing the removed window's row
band, found none (the three have different bands), fell back to adjacency,
and found both the window above and the window below adjacent - so it grew
both, which overlapped them. The tree names the sibling, and one grows.
Two tests now pin these, with those Emacs numbers in their comments.

What is still not Emacs's: our splits always *nest* - splitting a window
twice below puts the second split's internal window inside the first's -
where Emacs, when the parent already divides along the same axis, adds a
sibling to that parent instead (`window-combination-limit`). The layouts
are the same; the trees are deeper, so `window-list` order agrees but the
shape of the tree does not. That matters for `balance-windows` and for
resizing, not for anything here yet.

### The window tree, as it was deferred

The plan above says the window-tree hook belongs with the `window.sld` move.
It did not happen, and the split is deliberate: the tree changes the window
*record* in `editor/frame.sld` (`window.c`), the renderer's traversal, and
every command's geometry, which is a session's work on its own rather than a
move. Nothing is forcing it yet - splits work, and the completion port needs
no more than they give - so `window.sld` carries the flat-list heuristic for
now with the deviation documented at the top of the file. It goes when
windows are next worked on, and it will be a change confined to
`frame.sld` + `window.sld`, which is what the move bought.

### What the moves taught

- A move that changes *which* parameter carries a fact needs the tests to
  bind the same parameters production binds. `with-minibuffer` in the
  frontend tests builds a minibuffer by hand; it needed
  `(*minibuffer-editor* mb-ed)` added, and the four
  `schemacs_ncurses_editor_minibuffer_dispatch` tests failed loudly until it
  did - which is that group doing its job.
- **A move must bring its imports, and the unit suites do not catch a
  missing one.** `editor/disp-table.sld` was moved with `(scheme base)` and
  `(scheme char)` but not `(scheme write)`, so `display` was unbound. Both
  suites stayed green because they never render; the editor died on its
  first redisplay, in a real terminal. This is the same failure shape as the
  missing `(scheme case-lambda)` recorded in ENGINE-FINDINGS.txt, and it is
  why the pty check is not optional for a move with a rendering half.
  `tools/pty-check.py` is now that check, kept in the repo: it was verified
  against this exact bug (it fails with the import removed and passes with
  it restored), so it is not a vacuous test. Run it, plus
  `guile --no-auto-compile -L . -c '(import (<the new library>))'`,
  after every move.
- The three hand-maintained lists were already missing `editor/engine.sld`,
  so the Gambit/MIT/STklos builds had a hole predating these moves. `build.scm`
  is checkable here (`guile -L . -c '(load "./build.scm")'`, which is
  what `make schemacs-guile` runs); the Makefile's `SCHEME_LIBRARIES` and
  `platform/guile/main.scm` are not.
- The pty check for this area: `C-x C-f`, then `C-a`, `C-k`, a path, RET.
  It fails if a command run with a minibuffer active acts on the wrong
  buffer, and it is the only check that sees the terminal's own echo.
- **A move can break a name for a reason no test can see.** The
  `newline` failure above came out of a *move* - the definition had been a
  `define` in the frontend, where it shadowed the import, and moving it
  into a library turned it into an import in the frontend, where it lost to
  `(scheme base)`. So a move is not always behaviour-preserving in Scheme
  the way it is in a single flat namespace, and `tools/check-name-clashes.py`
  is the guard.
- **The tools, and which are safe to keep.** `section-imports.py`,
  `section-deps.py`, `check-name-clashes.py`, `check-import-clashes.py`,
  `check-missing-imports.py`, `run-suites.py` and `pty-check.py` are all
  *reporters* or *runners*: none writes source, so any can be re-run at any
  time. The three generators were each deleted after one use, because
  re-running one after a move undoes the hooks that move needed.
  `import_sets.py` is the shared R7RS import-set parser the clash checkers
  and the missing-import checker use - it has to be exact, because treating
  a selective import as "the module is imported" is what made
  `set!ncurses-frame-crlf?' look present when it was not.
- **`:eval` is a symbol in Scheme and self-evaluating in Elisp.**
  `(memq (car construct) '(:eval :propertize))` is fine, but the comparison
  beside it - `(eq? (car construct) :eval)` - is an unbound variable, and
  it failed only when a test exercised the branch. The same shape of
  mistake as `t` for `#t` and `nil` for `#f`: Elisp's vocabulary is not
  Scheme's, and a keyword is the subtlest case of it.
- **Two false positives to expect from `check-missing-imports.py`.**
  It reports a name that is bound as a *local* where a library of that
  name exports it: `keymap` (the argument of `define-key`), `t`, `char`,
  `location`, `take`, `eof`, `form`. In our own code the current reports
  are all of those and none is a real missing import; the ones in
  `apps/emacs.sld`, `apps/debugui.sld` and `backend/guile-gi/*` are on the
  dead line.
- **The checkers needed checking.** Three of them were wrong in ways that
  made them report clean on real bugs, and each was only found by using it
  on a case whose answer was already known:
  `check-missing-imports.py` treated an `(only (lib) a b c)` import as
  providing everything the library exports, and separately read the export
  lists without `--r7rs` so it got nothing at all; `section-imports.py`
  treated Guile's names as free. A checker that cannot fail is worse than
  none, so each is now verified against a case it must reject.
- **What the missing-import checker found once it worked** - three real
  bugs, live in the editor, that no test had caught:
  `set!window-top-line` in `editor/xdisp.sld` (the renderer's scrolling
  called a name it never imported, so scrolling a long file reported an
  unbound variable in the echo area and left the view where it was);
  `set!ncurses-frame-message` in `editor/minibuffer.sld` (completion's "No
  match" and the y/n reader's retry); and `save-answer-char->decision` in
  the test file. `tools/pty-check.py scroll` is the check for the first.
- **A tool that assumes too much about what is free is worse than no tool.**
  `tools/section-imports.py` treated Guile's own names as needing no import,
  so it reported `editor/minibuffer.sld` as needing nothing beyond the
  libraries - and `string-prefix?`, which is Guile's and not R7RS's,
  reported as an unbound variable the first time a completion ran. The test
  suite caught that one (seven failures); the same flaw in `disp-table.sld`
  (`display`) only the terminal caught. The tool now asks Guile what R7RS
  exports and prints everything else it binds as `(only (guile) ...)`, so a
  Guile-only name cannot hide.
- **Counting failures cannot tell "all passed" from "never ran".** A suite
  that dies while loading prints no test output, so it counts zero `FAIL`
  lines and looks green - which is what happened when a library stopped
  exporting a name the frontend imported: both suites died at load and the
  sweep that counted `FAIL` reported 0 for both. `tools/run-suites.py` now
  runs them and requires at least one expected pass, printing the load error
  when there is none. Verified against that failure by re-introducing it.
- The pty checks in `tools/pty-check.py` now number six, and each was
  verified against the failure it exists for - by removing the fix and
  watching the check fail - so none is vacuous. `newline` needed straight
  RET and a read of the file back; the search highlight needs a terminal,
  because isearch reads its own keys through `getch` and cannot be driven
  from a unit test at all, and its failure is silent (point still moves,
  the search still works, the matches are simply not drawn).
- A hook that *inverts* a dependency needs a check of its own, because
  both halves look fine alone. `*search-highlight*` is set by the search
  and read by the display; if either half stops, nothing errors.
- A section can be moved *minus* the definitions that are not really its
  own. Four commands now sit in the frontend waiting for the minibuffer
  because they ask a question, and each of them is another file's in the
  end (`find-file', `save-buffer`, `save-buffers-kill-terminal' are
  files.el's; `kill-buffer' is the buffer layer's). Leaving them behind
  costs nothing and keeps every move a leaf.
- **An import can be shadowed by another import, and the winner is the
  order of the list.** The frontend imported `newline` from both
  `(scheme base)` and `(schemacs editor simple)`, and Guile warned
  "imported from both" and let the later one win. That is the same
  mechanism that had already cost a session, so it is no longer left to
  order: the frontend takes `newline' by `rename' as `newline-command'
  (which cannot clash) and exports it as `newline'. A warning that a real
  bug once hid behind is not noise to be ignored.

