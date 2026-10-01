This project is taking the schemacs emacs editor project, and trying to turn
that half done project into a real editor. When I picked it up a lot of the 
machinery was in place, but it wasn't actually an editor. It would start
up a gtk window with a couple of GtkTextAreas, but didn't actually do anything.

We are reimplementing emacs in guile scheme. The general plan is to plan new features,
translate real emacs source code into scheme, and put that ported code into
files with the same name as in emacs. e.g. intervals.c in emacs became intervals.sld
in this project. Each function in emacs should be ported with the same name to the 
same file here, generally with the same parameters too. 
We are working on exact emacs replication, right down to the
exact functionality, messages, layout, everything. So it's important that you
read emacs source code before implementing, are replicating it as close as possible
in scheme, and of course, following the style and conventions you find already
in this project.

When there is a bug, and the user complains about the behavior, never just put in
what you think the fix should be, what you should do is find out how our implementation
departed from real emacs, and fix that departure. If you start improvising fixes,
you'll get subtley different behavior that will manifest itself later down the track. 
That's not good. 

There are two front ends, the ncurses one and the gtk one. That makes it 
necessary to be very careful when you are fixing a bug to make sure you fix it
at the right level of abstraction or you risk fixing one front end and breaking
the other one, or at least only fixing one when maybe it should have been both.


- `tools/syntax-check.scm` — after ANY scripted edit to a machinery
  `.scm` file, run `guile -s tools/syntax-check.scm <files>`: it runs
  Guile's own reader over the files and reports read errors with the
  reader's file:line:col (exit 1 on failure). Catches the
  paren/quote/docstring-corruption class of bug at the edit site.

# Handoff — state of the buffer-menu work (2026-09-27)

## Where we are

The layout plan (LAYOUT-PLAN.txt) is essentially executed: `apps/ncurses-editor.sld`
(3,471 lines) has dissolved into `schemacs/editor/*.sld` plus
`schemacs/ui/platform/ncurses.sld`. One library per mirrored Emacs file:

- `engine.sld` — buffer.c + insdel.c + marker.c + search.c (pre-existing; ~57% ours
  by `git diff main`; Chris decided to leave it whole)
- `frame.sld`, `window.sld`, `xdisp.sld`, `keymap.sld`, `keyboard.sld`,
  `minibuffer.sld`, `files.sld`, `simple.sld`, `isearch.sld`, `disp-table.sld`
- `buffer.sld` — NEW, mirrors buffer.c's management half
- `tabulated-list.sld` — NEW, subset of tabulated-list.el
- `buff-menu.sld` — NEW, port of buff-menu.el (`C-x C-b`)

## The feature in flight: the visual buffer list

`C-x C-b` → `list-buffers` → `list-buffers-noselect` → sets the list buffer's
`buffer-local-keymap` to `buffer-menu-mode-map` → `list-buffers--refresh` →
`tabulated-list-print`.

Wiring already done:
1. `(schemacs editor buffer)` registry (buffer-list, get-buffer-create, kill-buffer, …)
2. `keyboard.sld`'s `lookup-keymaps` consults the buffer-local keymap before the global
3. `ncurses.sld` imports the binding-carrying libraries

**The RET binding** stays as it is: RET is the key path `(list 'ctrl #\m)`, not
the character `#\return` — a terminal sends byte 13 and
`ncurses-key->keymap-path` turns that into `(ctrl #\m)`, which is exactly Emacs's
binding (in Emacs `(kbd "RET")` and `(kbd "C-m")` are the same key event).

## The buffer list is done (2026-09-27, second pass)

`unbound variable: Buffer-menu--line-entries` is fixed, along with three more
bugs that testing turned up underneath it. All four are the same shape:
something assumed *the current buffer* while something else meant *the frame's
buffer*, and nothing ever asked which buffer a line was.

1. **`Buffer-menu--line-entries` never existed.** The invented helper is gone;
   `buff-menu.sld` calls `tabulated-list-get-id`, which is where Emacs has it
   (a `defsubst` over the `tabulated-list-id` text property; here the line is
   counted, there being no text properties). Ported into `tabulated-list.sld`
   with the row counting.
2. **`Buffer-menu-beginning` moved the wrong buffer's point.** It used the
   frame's `current-editor`, which ignores `with-current-buffer` — and
   `list-buffers-noselect` draws inside a `with-current-buffer`. The old
   `(max 0 row)` clamp hid the result. `buff-menu.sld` uses `(current-buffer)`
   now, which is Emacs's function and honours `set-buffer`.
3. **`display-buffer` reset the new window's point to 0.** Emacs's
   `set_window_buffer` takes the buffer's own point. So `C-x C-b` then `C-x o`
   left point on the titles, where `m`/`d`/RET did nothing.
4. **`tabulated-list-print` appended instead of replacing.** It deleted forward
   from point, so a redraw with point down the list drew a second copy onto the
   end of the first. It empties from the beginning now (`erase-buffer`).

### Function-level fidelity: `save-buffer`

`save-buffer` took a `frame`. GNU Emacs's takes **nothing** and acts on
`(current-buffer)` — `(save-buffer &optional arg)`, `files.el:5993`, where ARG
only picks backup behaviour. Two of the three things read off the frame were the
frame standing in for the current buffer, including the file name: the accessor's
own docstring already said it was the buffer's.

The third was a real bug. **The line-break convention was a slot on the frame**;
in Emacs it is `buffer-file-coding-system`, buffer-local. One frame-wide answer
for every buffer meant: visit a CRLF file, visit an LF file, `C-x b` back, save —
and the CRLF file was rewritten with LF. Fixed:

- the frame's `crlf?` slot is **deleted** (Emacs has no frame-level coding
  system), and `ncurses-frame-file-path` with it;
- `find-file` records the convention as a buffer-local value and returns just the
  buffer, as `find-file-noselect` does — no more `(values ed crlf?)`;
- `save-buffer` takes no argument, writes the buffer's own file and convention,
  and prompts for a name only when the buffer visits none (`basic-save-buffer`);
- `Buffer-menu-execute` saves marked buffers with
  `(with-current-buffer buffer (save-buffer))`, as Emacs's loop does, so `x`
  really saves. `>` marks are left alone, and the buffer the list is used from is
  not killed;
- `default-directory` answers from the buffer too, which `buffer.sld` had already
  recorded as a deviation waiting for this work.

Also bound, having been implemented but unreachable: `%`
(`Buffer-menu-toggle-read-only`), `e`, `C-k`.

### Deliberately still not ported

`t`, the other-window and view commands, `1`/`2`/`v` (they arrange the frame's
windows, and `2` and `v` need `switch-to-buffer-other-window`), unmark-all and
mark-backwards, the files-only and show-internal toggles, the filter regexps, and
isearch/multi-occur over marked buffers. The file header lists them with what each
would need.

### Tests

Five new unit tests press **real keys** in the list — the gap that let the unbound
variable through, since every earlier test reached the commands directly or
through their marks. Two compare the whole redrawn list rather than a substring,
which is what catches bug 4. `tools/pty-check.py` gained RET coverage in
`buffer-menu` and a new `crlf` check (11 checks now); each new check was verified
to fail with its fix reverted.

### Open, Chris's call

`buffer-menu` (shows the list *and* selects it) is implemented but unbound,
matching Emacs 31, where it is M-x only.

Then, per the plan: `*Messages*`, `eval-expression`, retiring the original
author's dead GTK line, and the two pre-existing import clashes in `eval.sld`
and `sequence.sld`.

## The completion UI (2026-09-28)

Chris used the minibuffer completion and listed six ways it differs from
Emacs 31, plus a seventh while the work was in progress. All seven are
fixed; COMPLETION-PLAN.txt's "Step H" records each with the Emacs it was
taken from. In one line each:

1. leaving the minibuffer takes the completions window with it (RET, C-g
   and a successful completion alike - one `minibuffer-exit-hook');
2. and so does a successful completion, for the same reason;
3. messages are `" [No match]"` - `minibuffer-message`'s enclosing;
4. and they time out after `minibuffer-message-timeout` (2 seconds);
5. `M-<up>`/`M-<down>` move through the candidates and RET takes the one
   moved to - which needed the arrow keys to stop being aliases of C-p and
   friends, and the selection to be drawn;
6. `M-6` is `digit-argument`, not an undefined key - as are C-6, C-M-6,
   `M--` and the rest;
7. SPC inserts a space in a file name (`minibuffer-local-filename-completion-map`).

Three bugs fell out of it, all worth knowing about: `minibuffer-set-contents!`
*prepended* to the minibuffer instead of replacing (its deletion ran before
its move to the beginning, and the engine deletes forward), `read-file-name`
answered with a *relative* name where Emacs's answer is absolute (so a bare
name typed at `C-x C-f` only worked by luck - there is an `expand-file-name`
in `files.sld` now), and `M-RET` was spelled as a two-key chord in the
completion map, which made it shadow RET.

Still diverging, and named rather than fixed: the candidates come out in
`readdir` order - Emacs sorts them (`completions-sort`, alphabetical by
default) - and `completion-in-region`/`completion-at-point` do not exist
yet (step G of the plan).

### And three more from his third pass (2026-09-29)

* **`C-x C-f` did not prompt with the directory** in a buffer that had
  been started on a file, only in one that had not. `find-file` used the
  name it was given as it stood, and the *directory part* of a bare name
  is the empty string - so `emacs foo` then `C-x C-f` prompted with
  nothing. Emacs expands the name first thing in `find-file-noselect`;
  so does this now. The pty battery gained a `default-directory` check.
  (`abbreviate-file-name`, the other half of that line, is not
  implemented - there is no home directory here to shorten against.)
* **`default-directory` needed a global default.** It is a buffer-local
  variable, and it has to answer when there is no current buffer at all -
  a `find-file` from a script or a test - with the process's directory,
  which is Emacs's global value of it. It also now says so, rather than
  falling through to the frame's selected window and failing there.
* The heading line, the help lines, "[Sole completion]" vs "Complete, but
  not unique", and creating a file with `C-x C-f` are all in
  COMPLETION-PLAN.txt's "Step I".

## Method that works for repairs here

Paren-hunting from Python-assembled nested code caused the two destructive
splices. The working method: write the form to a file, verify it with Guile's own
reader (`guile -s tools/syntax-check.scm <file>`), then splice. That tool existed
in `../Hyprscheme` but was missing here; it is restored.

Name note: the capital `B` is right. `lisp/buff-menu.el` names everything
`Buffer-menu-*`, unlike the lowercase prefix nearly every other Emacs file uses.
Our library mirrors it on purpose.

## Driving a running editor: the REPL back door

**Use this before reaching for a keyboard.** A running editor can be read and
poked from outside, in its own thread, with its own state:

    SCHEMACS_REPL=37146 ./seg FILE &
    tools/repl.py -m '(schemacs editor xdisp)' '(render! (*current-frame*))'

`SCHEMACS_REPL` names a port; `main-gtk.scm` / `main-ncurses.scm` open Guile's
REPL server there if it is set, and nothing in the editor proper knows the back
door exists. `tools/repl.py` speaks to it (`-m MODULE` imports first;
expressions evaluate in `(guile-user)`). It answers with the process's *real*
state, so `(buffer-list)`, `(*current-frame*)`, a buffer's text and its mark are
all the live values, and `(render! f)` redraws for real. `pgtk-write-screenshot!`
writes what the window is showing to a PNG, so pixels can be checked too.

It is the **cooperative** server (`(system repl coop-server)`), not
`guile --listen`, and that is not a detail: `--listen` runs the REPL in a thread
of its own, `make-parameter` makes a fluid, and **a fluid binding is
thread-local** - so that thread sees the *default* of everything the editor set
with `parameterize`. Through `--listen`, `(*current-frame*)` is `#f` and
`(buffer-list)` is empty, which is no use at all. The cooperative server
evaluates in the thread that polls it, and the editor polls where it waits:
`pgtk-read-event`'s loop (so a windowed editor answers while idle) and the
command loop in `keyboard.sld` (so a terminal one answers between keys - its
read blocks in `getch` and there is nothing else to hang it on). Both calls are
no-ops until `start-repl!` has run.

**Why not drive the GTK backend with `wtype` and `grim`.** A keyed run goes to
whichever window the compositor has focused, and that is not necessarily the
editor. This was tried here: a run "proved" the region worked, and a later run
showed the focused window was a terminal - the keys had gone to the terminal and
the screenshot was of something else. A screenshot of the wrong window looks
exactly like evidence, which makes the whole method worse than useless. The
compositor is also unnecessary: `dispatch-input-event` takes the very integer
the backend produces for a key, so the key path can be driven exactly, with no
compositor in it at all:

    (dispatch-input-event f (+ #x20 (* 4 (expt 2 32))))   ; the GTK C-SPC

A `,q` recovers from an error's nested prompt; `tools/repl.py` does that
automatically on the next call.

## Environment gotchas that keep biting

- A missing import reports as an **unbound variable at run time, never at load**.
  This class of bug has recurred five times. After any edit that adds a name, run
  `tools/check-missing-imports.py`.
- `text-editor-char-count` is the buffer size in characters and **every position
  is an index into it**, so anything that leaves it out of step with the text
  corrupts every later edit. It is maintained by hand, and the engine's own line
  merges used to inflate it (see the `%text-editor-move-char` comment and the
  `schemacs_editor_engine_char_count` tests). The symptom was three screens away
  from the cause: a `*Completions*` redraw that died in the interval tree with
  "Wrong type argument in position 1 (expecting struct): #f", because the tree
  was built from the true sizes and the range was computed from the wrong count.
  When a failure looks like corrupted structure, print both counts before
  hunting the structure. Watch for it inside a `guard`: a swallowed
  exception reads as a command that quietly did nothing — which is how the
  `x`-saves path hid a missing `save-buffer` import.
- **Inserting in the *middle* of a buffer whose text carries properties**
  used to come apart silently: `adjust_intervals_for_insertion` grew every
  interval above the insertion point and *then* merged the runs either
  side to decide the new text's properties, but the merge - and the split
  it can ask for - was nested inside the growing walk, so it ran **once per
  ancestor** instead of once. At position 0 of a two-level tree it ran
  twice, and the second time split the interval the first had already
  moved, leaving it with a negative length and a position past the end of
  the buffer; the next reader walked off the tree with "Wrong type
  argument in position 1 (expecting struct): #f". The C has the walk and
  the merge as sequential statements, which is what it is now. Found by
  driving `*Completions*' (whose help lines are inserted at `point-min')
  and then printing `(interval-position i)`/`(interval-length i)` from
  inside the branch where it died - the raise surfaced three frames away
  and the record printer for `<text-editor-type>` failed while Guile was
  printing the backtrace, which hid the location. Named-step tracing is
  what got there in the end; splicing an instrumented *copy* of the
  function is not a valid experiment unless the parens are unchanged, and
  twice they were not.
- A guarded `(guard (e (else ...)))` is the only way to catch these: a
  `with-exception-handler` whose handler *returns* re-raises the
  non-continuable exception, so the handler appears to do nothing and the
  error escapes anyway. Two of the probes written during this work died
  that way before it was noticed.
- **Changing a record type silently breaks every *other* library that
  uses it**, under `--no-auto-compile`. Guile reads the `.go` files in
  `~/.cache/guile/ccache`, and a library whose source did not change keeps
  the one compiled against the *old* layout - so its accessors read and
  write the wrong slots while the library that defines the record works
  perfectly. The symptom is bizarre and misleading: `get-buffer-create`
  returning a buffer with no name, 24 unrelated test failures. When a
  record's fields change, `rm -rf ~/.cache/guile/ccache` before believing
  anything. (Adding a field to `<text-editor-type>` is what found this.)
- **A bare `C-u` is the list `(4)`, not the number 4.** That is GNU
  Emacs's raw prefix argument - `universal-argument` sets `prefix-arg` to
  `(list 4)` - and commands ask *which kind* it is: `yank` takes the
  latest kill for a list and the Nth for a number, and `set-mark-command`
  pops the mark ring only for `C-u C-u`. `pending-uarg` answers the list,
  and `uarg->integer` reads the number out of it. Anything asking
  `integer?` to mean "was there a prefix at all" is asking the wrong
  question.
- **Inserting text at the end of a propertized run lets the run's
  property extend over the new text** - `adjust-intervals-for-insertion`
  grows the interval across the insertion, where Emacs's newline and
  padding between propertized cells stay unpropertized. The symptom is a
  *scan by property presence* failing to find the following cell: in
  `*Completions*` the newline after `apple.txt` carried `apple.txt`'s
  `completion--string` too, so "the next cell starts where the previous
  character has no property" stopped at the end of the row. Emacs's
  buffer shape is restored by taking the property back off the separator
  when it is inserted (`insert-completion-separator!`).
- **A face with only one colour needs `use-default-colors`.** Emacs's
  `region` on a 16+/88+-colour dark display is `:background "blue3"` with
  no foreground; `term.c` just sends no `setaf` for the default colour.
  ncurses spells "the terminal's default" as `-1`, and `init-pair!` with
  `-1` *fails* (returns `#f`, silently ignored) unless `use-default-colors`
  has been called after `start-color!` - the pair stays 0/0 and the region
  draws black on black. `with-terminal` calls it now. And the background
  mode is not a guess from `$TERM`: `term/xterm.el` (`xterm.sld`) asks the
  terminal (`\e]11;?`) and the answer picks the `(background dark)` branch;
  `tools/pty-check.py`'s `drive` answers those queries as an xterm would.
- A timed `getch` comes back as **`#f`**, not as the `ERR` integer. The
  command loop's test for end of input had tested for `ERR` since it was
  written and had therefore never fired; it is the *timeout* that tells the
  two apart now (a blocking read only comes back empty at end of input).
- `check-missing-imports.py` is a crude scan that reports ~43 files; most are
  false positives (`char`, `format`, `t` read out of comments and identifiers).
  Compare it against its baseline rather than treating it as a gate.
- `srfi 64`'s `test-equal` uses `equal?`: `'(a.txt)` is symbols, `'("a.txt")` is
  strings, and the failure prints two values that look identical.
- Guile: `(scheme base)` exports `newline`, so a library cannot define it — use
  `(export (rename (internal external)))`.
- `(scheme base)`'s `raise` shadows Guile's signal `raise`.
- Run with `guile --no-auto-compile --r7rs -L . -s <file>`, `GUILE_WARN_DEPRECATED=no`.
- A suite that dies at load prints "0 FAIL"; `tools/run-suites.py` requires at least
  one expected pass so that cannot pass silently.


## The `define-command` conversion is complete (2026-09-29)

Every command is now a `define-command` whose name is the command's Emacs
name, bound to a plain callable procedure; the `-command` suffixes are
gone (undo, split-window-below, find-file, save-buffer, kill-buffer,
Buffer-menu-*, ...). `define-command` is spelled as a Scheme procedure
definition - `(define-command (name args ...) docstring (interactive ...)
body ...)` - with `defun`'s *field order* kept (Emacs is the reference
for behavior, not for Lisp's spelling). The one legacy record left is
`self-insert-command` (simple.sld), documented there: the character it
inserts is re-derived from keymap lookup state, which an
`(interactive ...)` cannot say yet. Two names deviate because the host
language took them, with the why on each definition:

- `insert-newline` — Emacs's `newline` clashes with `(scheme base)`'s
  output procedure.
- keyboard.sld's `abort-recursive-edit` — the minibuffer's C-g binds
  this directly (it is buffer.c's command), which is why it lives in
  `(schemacs editor keyboard)` and not in minibuffer.sld.

Mechanics added to `command.sld` for this:

- `current-prefix-arg` — callint.c's variable, a parameter bound to the
  pending prefix while a command's interactive *expression* is
  evaluated; `split-window-below`'s `(interactive (list ...))` reads it
  for its size, exactly as Emacs's backquote form reads the variable
  (it needs `(scheme eval)` in the import).
- An interactive expression evaluates in the command's *defining*
  module, which `register-command!` captures at `define-command` expansion
  time (`current-module` there is the defining module — it is dynamic).
  Evaluating it at keypress time would be the command loop's module
  and fail to find the command's helpers.
- The obarray (`*command-table*`) name comes from `procedure-name`, so
  define-command keeps the name you see in M-x.

Reference hazards while converting: `define-key` must come *after* the
`define-command`s it binds (Guile resolves a binding when the form is
evaluated); and a define-command being a procedure means call sites switch
from `(run-command NAME)` to a plain `(NAME)` call. `read-elem`-style
sliding on a balanced form is the reliable way to convert a
`new-command` block in bulk; the lambda's closing paren must be dropped
and the define-command's own added back.
